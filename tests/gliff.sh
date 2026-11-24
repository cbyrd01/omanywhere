#!/bin/bash
# gliff test: a container made with bin/omanywhere serves its desktop to a
# plain gliff client over ssh, with no gliff flags, on whatever card it has.
#   1. ssh through the Host block `omanywhere ssh-config` prints, with a
#      throwaway key, gets the gliff environment the desktop's card needs;
#   2. `ssh omanywhere-NAME gliff-server --stdio --headless`, which is what
#      `gliff --headless omanywhere-NAME` runs, answers a client's hello with
#      a protocol message on stdout within 10 s;
#   3. `gliff-probe serve-test`, against a `gliff-server --listen ... --headless`
#      the owner starts over ssh, decodes frames; both run in the container;
#   4. ssh sessions get the gliff environment whichever of sshd and the
#      desktop session starts first.
# Every wait is bounded: by a count, by timeout, or by the process it waits
# on still running.
#
# Usage: tests/gliff.sh (IMAGE defaults to omanywhere:dev).
# OMANYWHERE_TEST_GPU (required) is bin/omanywhere up's --gpu: auto, nvidia
# or dri. Each leg needs a card the desktop can run on:
#   auto or nvidia on a host with NVIDIA's CDI spec (odyssey: the host's
#     Hyprland holds DRM master, so the container never takes it)
#   auto or dri in tests/vm's KVM guest, on its vkms card (the CPU-only leg)
# OMANYWHERE_TEST_EXPECT_VIDEO, when set (gpu or cpu), is the GLIFF_VIDEO the
# ssh session must get, and the video pipeline gliff-server must use.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cli=$here/../bin/omanywhere
name=test-gliff-$$
container=omanywhere-$name
check_name "$container"
tmp=$(mktemp -d)
export OMANYWHERE_IMAGE=$IMAGE OMANYWHERE_CONFIG_DIR=$tmp/config
trap '"$cli" down "$name" --purge --yes >/dev/null 2>&1 || true
  cleanup "$container"; remove_volumes "$container-home" "$container-state"; rm -rf "$tmp"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"
gpu=${OMANYWHERE_TEST_GPU:-}
[[ -n $gpu ]] || fail "OMANYWHERE_TEST_GPU is not set: auto, nvidia or dri (the desktop needs a card)"

test_key "$tmp"
"$cli" up "$name" --gpu "$gpu" --key "$tmp/id_ed25519.pub" 2>&1 | indent
status=$("$cli" status "$name") || fail "status failed"
grep -Eq '^desktop +running' <<<"$status" || fail "the desktop is not running: $status"
pass "omanywhere up --gpu $gpu: the desktop is running"

{
  "$cli" ssh-config "$name"
  cat <<EOF

Host *
  IdentityFile $tmp/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $tmp/known_hosts
  StrictHostKeyChecking accept-new
  BatchMode yes
  ConnectTimeout 10
  LogLevel ERROR
EOF
} >"$tmp/ssh_config"
ssh=(ssh -F "$tmp/ssh_config" "$container")
# gliff_env: GLIFF_VIDEO and GLIFF_CAPTURE in an ssh session ("-" for unset).
gliff_env() {
  # shellcheck disable=SC2016 # expanded by the owner's shell, in the container
  timeout 20 "${ssh[@]}" 'echo "${GLIFF_VIDEO:--} ${GLIFF_CAPTURE:--}"'
}

# Hyprland answers the owner within 60 s. Over ssh, HYPRLAND_INSTANCE_SIGNATURE
# isn't set; hyprctl takes the first instance with --instance 0.
for ((i = 0; i < 60; i++)); do
  count=$(timeout 15 "${ssh[@]}" 'hyprctl --instance 0 -j monitors | jq length' 2>/dev/null) || count=0
  ((count > 0)) && break
  sleep 1
done
((count > 0)) || fail "Hyprland did not answer the owner over ssh within 60 s"
pass "Hyprland answers over ssh with $count monitor(s)"

# 1. The gliff environment, from sshd (the desktop session wrote it for the card).
read -r video capture < <(gliff_env)
[[ $video != - && $capture != - ]] || fail "the ssh session has no GLIFF_VIDEO or GLIFF_CAPTURE"
[[ -z ${OMANYWHERE_TEST_EXPECT_VIDEO:-} || $video == "$OMANYWHERE_TEST_EXPECT_VIDEO" ]] ||
  fail "GLIFF_VIDEO is $video, not $OMANYWHERE_TEST_EXPECT_VIDEO"
pass "ssh session: GLIFF_VIDEO=$video GLIFF_CAPTURE=$capture"

# 2. What a plain `gliff --headless` client runs. The client speaks first:
# its hello carries the window size the headless output takes. Rather than
# hard-code gliff's wire format, take the hello the installed client sends:
# gliff-probe's serve-test, run in the container against a listener that
# keeps what it reads (as hex) and hangs up.
# shellcheck disable=SC2016 # the script runs, and expands, in the container
hello=$(timeout 60 "${ssh[@]}" bash -s <<'EOF'
python3 -I -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 7998))
s.listen(1)
s.settimeout(15)
c, _ = s.accept()
c.settimeout(2)
data = b""
try:
    while len(data) < 4096:
        chunk = c.recv(4096)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
print(data.hex())
' &
listener=$!
for ((i = 0; i < 100; i++)); do
  ss -Hltn 'sport = :7998' | grep -q . && break
  kill -0 "$listener" 2>/dev/null || exit 1
  sleep 0.1
done
timeout 10 gliff-probe serve-test --connect 127.0.0.1:7998 --frames 1 >/dev/null 2>&1
wait "$listener"
EOF
) || fail "could not capture gliff-probe's hello"
[[ $hello =~ ^([0-9a-f]{2})+$ ]] || fail "gliff-probe sent no hello: '$hello'"
# Sent on stdin, which then stays open (a client that hung up would end the
# session). Every message is framed by its length, 8 bytes, little-endian:
# the reader takes exactly the first message (dd bs=1 never reads past it),
# notes the time it was complete, and drains the rest until ssh is stopped.
start=$(date +%s%N)
{
  # shellcheck disable=SC2001 # each pair of hex digits becomes \xHH
  printf '%b' "$(sed 's/../\\x&/g' <<<"$hello")"
  sleep 12
} | { timeout 10 "${ssh[@]}" gliff-server --stdio --headless 2>"$tmp/stdio.err" || true; } | {
  dd bs=1 count=8 status=none >"$tmp/stdio.length"
  length=$(od -An -tu8 "$tmp/stdio.length" | tr -d ' ')
  if [[ $(stat -c %s "$tmp/stdio.length") == 8 ]] && ((length > 0 && length <= 65536)); then
    dd bs=1 count="$length" status=none >"$tmp/stdio.message"
    [[ $(stat -c %s "$tmp/stdio.message") == "$length" ]] && date +%s%N >"$tmp/stdio.time"
  fi
  cat >/dev/null
} || true
if [[ ! -s $tmp/stdio.time ]]; then
  indent <"$tmp/stdio.err" >&2
  fail "ssh $container gliff-server --stdio --headless wrote no complete protocol message to stdout in 10 s ($(stat -c %s "$tmp/stdio.length") length bytes)"
fi
length=$(od -An -tu8 "$tmp/stdio.length" | tr -d ' ')
elapsed_ms=$((($(<"$tmp/stdio.time") - start) / 1000000))
((elapsed_ms <= 10000)) || fail "the first message took ${elapsed_ms} ms"
pass "ssh $container gliff-server --stdio --headless: the first protocol message (${length} bytes) was complete on stdout ${elapsed_ms} ms after ssh started"

# 3. Frames decode: gliff-server listening on the container's loopback, and
# gliff-probe serve-test against it, both started by the owner over ssh with
# no gliff flags. The listener serves one client, then exits.
# shellcheck disable=SC2016 # the script runs, and expands, in the container
out=$(timeout 120 "${ssh[@]}" bash -s <<'EOF' 2>&1
RUST_LOG=info gliff-server --listen 127.0.0.1:7999 --headless >/tmp/gliff-server.log 2>&1 &
server=$!
for ((i = 0; i < 100; i++)); do
  ss -Hltn 'sport = :7999' | grep -q . && break
  kill -0 "$server" 2>/dev/null || {
    echo "gliff-server exited before it listened:"
    cat /tmp/gliff-server.log
    exit 1
  }
  sleep 0.1
done
timeout 60 gliff-probe serve-test --connect 127.0.0.1:7999 --frames 30
status=$?
echo "--- gliff-probe serve-test exit status: $status (124: timed out after 60 s)"
kill "$server" 2>/dev/null
wait "$server"
echo "--- gliff-server --listen, its choices:"
sed 's/\x1b\[[0-9;]*m//g' /tmp/gliff-server.log | grep -E 'using the|capture ring allocated|ERROR|WARN' | sed 's/^[^ ]* *//' | sort -u
exit "$status"
EOF
) || {
  indent <<<"$out" >&2
  fail "gliff-probe serve-test failed"
}
indent <<<"$out"
frames=$(sed -n 's/^RESULT decoded \([0-9]*\) frames.*/\1/p' <<<"$out")
((${frames:-0} > 0)) || fail "gliff-probe serve-test decoded no frames"
pipeline=$(grep -o 'using the [A-Z]* video pipeline' <<<"$out" | head -1) || pipeline=
case ${OMANYWHERE_TEST_EXPECT_VIDEO:-} in
  gpu) [[ $pipeline == *GPU* ]] || fail "gliff-server did not use the GPU video pipeline (${pipeline:-none logged})" ;;
  cpu) [[ $pipeline == *CPU* ]] || fail "gliff-server did not use the CPU video pipeline (${pipeline:-none logged})" ;;
esac
pass "gliff-probe serve-test decoded $frames frames from gliff-server --listen --headless (${pipeline:-pipeline not logged})"

# 4. Either order. sshd reads its config when it starts, and the session's
# prepare writes the gliff environment then reloads sshd if it runs.
want="$video $capture"
# sshd started after the session wrote it: sshd reads it at start.
cexec "$container" systemctl restart sshd.service
got=$(gliff_env) || fail "ssh after restarting sshd failed"
[[ $got == "$want" ]] || fail "sshd started after the session: the ssh session got '$got', not '$want'"
# sshd started before the session wrote it: no environment until the
# session's prepare writes it and reloads sshd.
cexec "$container" systemctl stop omanywhere-session.service
cexec "$container" rm -f /run/omanywhere/sshd/gliff.conf
cexec "$container" systemctl restart sshd.service
got=$(gliff_env) || fail "ssh with the session stopped failed"
[[ $got == "- -" ]] || fail "with no gliff.conf, the ssh session still got '$got'"
cexec "$container" systemctl start omanywhere-session.service
for ((i = 0; i < 20; i++)); do
  got=$(gliff_env) || got=
  [[ $got == "$want" ]] && break
  sleep 0.5
done
[[ $got == "$want" ]] || fail "sshd started before the session: the ssh session got '$got', not '$want', 10 s after the session started"
pass "sshd started after the session and before it: ssh sessions get GLIFF_VIDEO and GLIFF_CAPTURE either way"

echo "gliff test passed ($gpu: GLIFF_VIDEO=$video GLIFF_CAPTURE=$capture)"
