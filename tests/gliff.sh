#!/bin/bash
# gliff test: a container made with bin/omanywhere serves its desktop to a
# plain gliff client over ssh, with no gliff flags, on whatever card it has.
#   1. ssh through the Host block `omanywhere ssh-config` prints, with a
#      throwaway key, gets the gliff environment the desktop's card needs;
#   2. `ssh omanywhere-NAME gliff-server --stdio --headless`, which is what
#      `gliff --headless omanywhere-NAME` runs, answers a client's hello with
#      a protocol message on stdout within 10 s;
#   3. `gliff-probe serve-test`, against a `gliff-server --listen ... --headless`
#      the owner starts over ssh, decodes frames; both run in the container.
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

# Hyprland answers the owner within 60 s. Over ssh, HYPRLAND_INSTANCE_SIGNATURE
# isn't set; hyprctl takes the first instance with --instance 0.
for ((i = 0; i < 60; i++)); do
  count=$("${ssh[@]}" 'hyprctl --instance 0 -j monitors | jq length' 2>/dev/null) || count=0
  ((count > 0)) && break
  sleep 1
done
((count > 0)) || fail "Hyprland did not answer the owner over ssh within 60 s"
pass "Hyprland answers over ssh with $count monitor(s)"

# 1. The gliff environment, from sshd (the desktop session wrote it for the card).
# shellcheck disable=SC2016 # expanded by the owner's shell, in the container
read -r video capture < <("${ssh[@]}" 'echo "${GLIFF_VIDEO:--} ${GLIFF_CAPTURE:--}"')
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
hello=$("${ssh[@]}" bash -s <<'EOF'
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
until ss -Hltn 'sport = :7998' | grep -q .; do sleep 0.1; done
timeout 10 gliff-probe serve-test --connect 127.0.0.1:7998 --frames 1 >/dev/null 2>&1
wait "$listener"
EOF
) || fail "could not capture gliff-probe's hello"
[[ $hello =~ ^([0-9a-f]{2})+$ ]] || fail "gliff-probe sent no hello: '$hello'"
# Sent on stdin, which then stays open (a client that hung up would end the
# session); the reader notes when the server's first message is complete.
# Every message is framed by its length, 8 bytes, little-endian.
start=$(date +%s%N)
{
  # shellcheck disable=SC2001 # each pair of hex digits becomes \xHH
  printf '%b' "$(sed 's/../\\x&/g' <<<"$hello")"
  sleep 12
} | { timeout 10 "${ssh[@]}" gliff-server --stdio --headless 2>"$tmp/stdio.err" || true; } |
  { head -c 512 >"$tmp/stdio.out"; date +%s%N >"$tmp/stdio.time"; } || true
bytes=$(stat -c %s "$tmp/stdio.out")
if ((bytes < 8)); then
  indent <"$tmp/stdio.err" >&2
  fail "ssh $container gliff-server --stdio --headless wrote $bytes bytes to stdout in 10 s, not a message"
fi
length=$(od -An -tu8 -N8 "$tmp/stdio.out" | tr -d ' ')
((length > 0 && bytes >= 8 + length)) || fail "stdout's first $bytes bytes are not a complete message (length $length)"
elapsed_ms=$((($(<"$tmp/stdio.time") - start) / 1000000))
((elapsed_ms <= 10000)) || fail "the first message took ${elapsed_ms} ms"
pass "ssh $container gliff-server --stdio --headless: a ${length}-byte message on stdout (${bytes} bytes read) within ${elapsed_ms} ms"

# 3. Frames decode: gliff-server listening on the container's loopback, and
# gliff-probe serve-test against it, both started by the owner over ssh with
# no gliff flags. The listener serves one client, then exits.
# shellcheck disable=SC2016 # the script runs, and expands, in the container
out=$("${ssh[@]}" bash -s <<'EOF' 2>&1
RUST_LOG=info gliff-server --listen 127.0.0.1:7999 --headless >/tmp/gliff-server.log 2>&1 &
server=$!
until ss -Hltn 'sport = :7999' | grep -q .; do sleep 0.1; done
timeout 60 gliff-probe serve-test --connect 127.0.0.1:7999 --frames 30
status=$?
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

echo "gliff test passed ($gpu: GLIFF_VIDEO=$video GLIFF_CAPTURE=$capture)"
