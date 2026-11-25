#!/bin/bash
# CLI test: bin/omanywhere's up, status, ssh-config and down, with no device.
#   - up refuses a bad name or --gpu, and fails before it creates anything when
#     it has no ssh key, including a --github user with none (GitHub stood in
#     for by a curl on PATH that serves files);
#   - the docker run arguments for each --gpu, and the warning for an NVIDIA
#     card without NVIDIA's CDI device, from bin/omanywhere's own gpu_args
#     against a made-up /dev/dri and sysfs (no desktop runs on a card here);
#   - a key the container rejects fails the owner unit: up fails loudly with
#     the unit's journal and leaves the container stopped, and up --key with a
#     good key starts it again;
#   - up --password with no key makes a password-only desktop, and a key added
#     later replaces the password for ssh; with neither a key nor a password,
#     up refuses and names both ways in; --no-password deletes the password;
#   - up runs the container with the run flags and nothing more, ssh on
#     127.0.0.1 only, no password (sudo asks for none), and is idempotent;
#     up --password makes the container with a password as a read-only secret
#     file it made (never in argv or the environment, and only root can read
#     it);
#   - status and ssh-config describe it, and the owner gets in with ssh through
#     the printed Host block;
#   - down keeps the volumes and the config, so a new up keeps the port, the
#     password (when it has one) and the host key;
#   - up fails, and stops the container, when sshd isn't running after boot;
#   - down --purge asks first, and --yes removes everything; a volume it
#     can't remove is named, and the config is kept.
# The config directory is a temporary one (OMANYWHERE_CONFIG_DIR), never
# ~/.config. Usage: tests/cli.sh (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

cli=$here/../bin/omanywhere
name=test-$$
container=omanywhere-$name
home_volume=$container-home
state_volume=$container-state
check_name "$container"
tmp=$(mktemp -d)
export OMANYWHERE_IMAGE=$IMAGE OMANYWHERE_CONFIG_DIR=$tmp/config
config=$OMANYWHERE_CONFIG_DIR/$name
# down --purge --yes is the cleanup; the helpers after it catch whatever it
# leaves if the CLI itself is broken.
# up --data leaves files root owns in $tmp/data, which a container removes.
trap '"$cli" down "$name" --purge --yes >/dev/null 2>&1 || true
  "$cli" down "$name-pw" --purge --yes >/dev/null 2>&1 || true
  "$cli" down "$name-data" --purge --yes >/dev/null 2>&1 || true
  cleanup "$container" "$container-pw" "$container-holder" "$container-blocker" "$container-port"
  remove_volumes "$home_volume" "$state_volume" "$container-data-home" "$container-data-state" "$container-store-home"
  [[ ! -d $tmp/data ]] || docker run --rm --network none -v "$tmp:/t" --entrypoint rm "$IMAGE" -rf /t/data
  rm -rf "$tmp"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"
[[ -x $cli ]] || fail "$cli is missing or not executable"

# exists KIND NAME: docker has a container (or volume) of that name.
exists() {
  docker "$1" inspect "$2" >/dev/null 2>&1
}

# fails EXPECTED ARGS...: bin/omanywhere ARGS fails and says EXPECTED.
fails() {
  local expected=$1 out
  shift
  out=$("$cli" "$@" 2>&1) && fail "omanywhere $* succeeded: $out"
  [[ $out == *"$expected"* ]] || fail "omanywhere $* failed without saying '$expected': $out"
}

test_key "$tmp"
user=omarchy

# --- Arguments: checked before anything is made.
fails "not a valid name" up 'Bad_Name' --key "$tmp/id_ed25519.pub"
fails "not a valid name" up '../x' --key "$tmp/id_ed25519.pub"
fails "not a valid name" up "$(printf 'a%.0s' {1..40})" --key "$tmp/id_ed25519.pub"
fails "--gpu" up "$name" --gpu sometimes --key "$tmp/id_ed25519.pub"
for bad in vkms: vkms:desk dri: dri:card1 dri:/dev/dri/card dri:/dev/dri/renderD128 dri:/dev/dri/card1x dri:/dev/dri/../dri/card1 'dri:/dev/dri/card1 '; do
  fails "--gpu" up "$name" --gpu "$bad" --key "$tmp/id_ed25519.pub"
done
fails "--drm-master" up "$name" --drm-master yes --key "$tmp/id_ed25519.pub"
fails "usage" up "$name" --sudo nopasswd --key "$tmp/id_ed25519.pub"
fails "--listen" up "$name" --listen 'not an address' --key "$tmp/id_ed25519.pub"
fails "usage" frobnicate "$name"
fails "usage" ssh_config "$name"
# A settings file is checked as the options are.
(umask 077 && mkdir -p "$OMANYWHERE_CONFIG_DIR/$name-x")
printf 'listen=127.0.0.1\nport=2222\ngpu=sometimes\n' >"$OMANYWHERE_CONFIG_DIR/$name-x/settings"
fails "gpu" ssh-config "$name-x"
# An older settings file's sudo= line still loads, and is ignored.
printf 'listen=127.0.0.1\nport=2222\ngpu=none\ndrm_master=\nsudo=nopasswd\n' >"$OMANYWHERE_CONFIG_DIR/$name-x/settings"
"$cli" ssh-config "$name-x" >/dev/null || fail "ssh-config refused a settings file with an old sudo=nopasswd line"
printf 'listen=127.0.0.1\nport=99999\n' >"$OMANYWHERE_CONFIG_DIR/$name-x/settings"
fails "port" ssh-config "$name-x"
printf 'listen=127.0.0.1\nport=2222\ngpu=dri:/tmp/card1\n' >"$OMANYWHERE_CONFIG_DIR/$name-x/settings"
fails "gpu" ssh-config "$name-x"
# A card that has gone (vkms not loaded after a reboot, say) doesn't stop
# ssh-config: only the up that makes the container needs it.
printf 'listen=127.0.0.1\nport=2222\ngpu=dri:/dev/dri/card97\n' >"$OMANYWHERE_CONFIG_DIR/$name-x/settings"
"$cli" ssh-config "$name-x" >/dev/null || fail "ssh-config refused gpu=dri:/dev/dri/card97 in the settings"
rm -rf "${OMANYWHERE_CONFIG_DIR:?}/$name-x"
# No key: no --key, and no agent to ask.
out=$(SSH_AUTH_SOCK=$tmp/no-agent "$cli" up "$name" --gpu none 2>&1) && fail "up without a key succeeded: $out"
[[ $out == *"no ssh key"* ]] || fail "up without a key did not say 'no ssh key': $out"
[[ $out == *"--password"* && $out == *"--key"* && $out == *"--github"* ]] ||
  fail "up without a key or a password did not name the ways in: $out"
printf '# only a comment\n\n' >"$tmp/empty.pub"
fails "no ssh key" up "$name" --gpu none --key "$tmp/empty.pub"
# --github: a user name GitHub allows, one of --key and --github, and a
# fetch that gives keys.
mkdir "$tmp/gh"
: >"$tmp/gh/nokeys.keys"
printf '<html>Not Found</html>\n' >"$tmp/gh/junk.keys"
# The CLI's curl, on PATH, serves https://github.com/USER.keys from
# $tmp/gh/USER.keys, and fails as curl --fail does for a missing one.
mkdir "$tmp/bin"
# shellcheck disable=SC2016 # the stand-in's own code, expanded when it runs
printf '%s\n' '#!/bin/bash' 'url=${*: -1}' '[[ $url == https://github.com/*.keys ]] || exit 3' \
  "cat \"$tmp/gh/\${url#https://github.com/}\" 2>/dev/null || exit 22" >"$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
for bad in '' ../x a/b -lead trail- 'a--b' 'a b' "$(printf 'a%.0s' {1..40})"; do
  fails "takes a GitHub user name" up "$name" --gpu none --github "$bad"
done
fails "--key and --github" up "$name" --gpu none --key "$tmp/id_ed25519.pub" --github octo-cat
fails "pass it with --github" up "$name" --gpu none --key "$tmp/id_ed25519.pub" --yes
PATH=$tmp/bin:$PATH fails "couldn't fetch https://github.com/nobody.keys" up "$name" --gpu none --github nobody --yes
PATH=$tmp/bin:$PATH fails "no ssh key for GitHub user nokeys" up "$name" --gpu none --github nokeys --yes
PATH=$tmp/bin:$PATH fails "isn't a list of public keys" up "$name" --gpu none --github junk --yes
# Keys that would let a stranger in are confirmed: with no terminal, only
# with --yes.
cp "$tmp/id_ed25519.pub" "$tmp/gh/octo-cat.keys"
PATH=$tmp/bin:$PATH fails "pass --yes to confirm" up "$name" --gpu none --github octo-cat </dev/null
exists container "$container" && fail "a failed up left a container"
exists volume "$home_volume" && fail "a failed up left a volume"
[[ ! -e $config ]] || fail "a failed up left $config"
pass "bad names, flags and no key are refused before anything is made"

# --- The device arguments for each --gpu: bin/omanywhere's gpu_args, sourced,
# against a made-up /dev/dri and sysfs. /dev/null stands in for each node: a
# character device. card0 is vkms (no render node), card1 amdgpu with
# renderD128, card2 nvidia with renderD129.
fake=$tmp/fake
for card in card0:vkms card1:amdgpu:renderD128 card2:nvidia:renderD129; do
  IFS=: read -r node driver render <<<"$card"
  mkdir -p "$fake/dri" "$fake/drivers/$driver" "$fake/devices/$node/drm"
  ln -s /dev/null "$fake/dri/$node"
  ln -s "$fake/drivers/$driver" "$fake/devices/$node/driver"
  mkdir -p "$fake/class/drm/$node"
  ln -s "$fake/devices/$node" "$fake/class/drm/$node/device"
  [[ -z $render ]] || {
    mkdir "$fake/devices/$node/drm/$render"
    ln -s /dev/null "$fake/dri/$render"
  }
done
# card0 is also the configfs vkms card of the container omanywhere-desk.
mkdir -p "$fake/faux/omanywhere-desk/drm/card0"
# built MODE CDI: gpu_args MODE's device arguments, then what it said, with
# Docker seeming to have NVIDIA's CDI device when CDI is yes. In a child
# bash, so the CLI's names (name, config, ...) stay apart from the test's.
built() {
  # shellcheck disable=SC2016 # the script expands its own variables
  bash -c '
    source "$1"
    dev_dri=$2/dri drm_class=$2/class/drm faux=$2/faux cdi=$3 name=desk container=omanywhere-desk
    cdi_gpu() { [[ $cdi == yes ]]; }
    gpu_args "$4"
    echo "devices: ${devices[*]}"' bash "$cli" "$fake" "$2" "$1" 2>&1 | sed '/^devices:/!s/^/said: /'
}
nvidia_warning="said: omanywhere: warning: /dev/dri/card2 is an NVIDIA card, and Docker has no NVIDIA CDI device (nvidia.com/gpu=all): the desktop can't use it, as NVIDIA's GBM backend comes only through CDI. Install nvidia-container-toolkit and use --gpu nvidia (see docs/usage.md)"
expect_built() {
  local got
  got=$(built "$1" "$2")
  [[ $got == "$3" ]] || fail "--gpu $1 (CDI: $2): got '$got', want '$3'"
}
expect_built dri:/dev/dri/card0 no "devices: --device /dev/dri/card0"
expect_built dri:/dev/dri/card1 no "devices: --device /dev/dri/card1 --device /dev/dri/renderD128"
expect_built dri:/dev/dri/card2 no "$nvidia_warning"$'\n'"devices: --device /dev/dri/card2 --device /dev/dri/renderD129"
expect_built dri:/dev/dri/card2 yes "devices: --device /dev/dri/card2 --device /dev/dri/renderD129"
expect_built dri no "$nvidia_warning"$'\n'"devices: --device /dev/dri"
expect_built auto no "$nvidia_warning"$'\n'"devices: --device /dev/dri"
expect_built auto yes "devices: --device nvidia.com/gpu=all"
expect_built none no "devices: "
out=$(built dri:/dev/dri/card9 no) || true
[[ $out == *"--gpu dri:/dev/dri/card9: this host has no character device /dev/dri/card9"* && $out != *devices:* ]] ||
  fail "--gpu dri:/dev/dri/card9, a card the host lacks, was not refused: $out"
expect_built vkms no "devices: --device /dev/dri/card0"
rm "$fake/dri/card2"
expect_built dri no "devices: --device /dev/dri"
rm -r "$fake/faux/omanywhere-desk"
out=$(built vkms no) || true
[[ $out == *"--gpu vkms: this host has no vkms card for omanywhere-desk: run sudo omanywhere-host vkms add desk"* && $out != *devices:* ]] ||
  fail "--gpu vkms with no vkms card for the container was not refused: $out"
pass "--gpu: dri:/dev/dri/cardN passes that card and its own render node; vkms the container's own vkms card; NVIDIA without CDI warns once; a missing card is refused"
# The form is kept in the settings like the others.
# shellcheck disable=SC2016 # the script expands its own variables
out=$(bash -c '
  source "$1"
  settings=$2 listen=127.0.0.1 port=2222 gpu=dri:/dev/dri/card1 drm_master=
  save_settings
  gpu=''
  load_settings
  echo "$gpu"' bash "$cli" "$tmp/settings") || fail "could not save and load the settings"
[[ $out == "dri:/dev/dri/card1" ]] || fail "gpu=dri:/dev/dri/card1 came back from the settings as '$out'"
pass "gpu=dri:/dev/dri/card1 is saved in the settings and read back"

# --- A key line the owner unit rejects: up fails loudly, with the unit's own
# words, and the container is left stopped, not running without a way in.
# A port-picking container left by an interrupted earlier up (under the
# name round 1 used) doesn't get in this up's way.
stale=$container-port
check_name "$stale"
docker create --name "$stale" --entrypoint true "$IMAGE" >/dev/null
printf 'ssh-ed25519 not-a-key\n' >"$tmp/bad.pub"
out=$("$cli" up "$name" --gpu none --key "$tmp/bad.pub" 2>&1) && fail "up with a bad key succeeded: $out"
cleanup "$stale"
[[ $out == *"line 1 is not an ssh public key"* ]] || fail "up did not show the owner unit's journal: $out"
[[ $(docker inspect -f '{{.State.Running}}' "$container") == false ]] || fail "the container still runs after the owner unit failed"
pass "a rejected key: up failed with the owner unit's journal, and the container is stopped (a stale port-picking container didn't matter)"

# up --key with a good key repairs it: the keys file is rewritten in place,
# and the stopped container starts with it.
out=$("$cli" up "$name" --key "$tmp/id_ed25519.pub" 2>&1) || fail "up after fixing the key failed: $out"
indent <<<"$out"
[[ $(docker inspect -f '{{.State.Running}}' "$container") == true ]] || fail "the container is not running after up"
grep -q 'no DRM card' <<<"$out" || fail "up did not say why the desktop was skipped"
pass "up --key started the stopped container, and said why the desktop was skipped"

# --- The container: the run flags and nothing more.
inspect() {
  docker inspect -f "$1" "$container"
}
[[ $(inspect '{{.HostConfig.Privileged}}') == false ]] || fail "the container is privileged"
[[ $(inspect '{{json .HostConfig.CapAdd}}') == null ]] || fail "capabilities were added: $(inspect '{{json .HostConfig.CapAdd}}')"
[[ $(inspect '{{.HostConfig.NetworkMode}}') != host ]] || fail "the container uses the host's network"
[[ $(inspect '{{.HostConfig.CgroupnsMode}}') == private ]] || fail "the cgroup namespace is not private"
[[ $(inspect '{{.Config.Tty}}') == true ]] || fail "the container has no tty"
[[ $(inspect '{{.HostConfig.RestartPolicy.Name}}') =~ ^(no|)$ ]] || fail "the container has a restart policy"
[[ $(inspect '{{json .HostConfig.Devices}}') =~ ^(null|\[\])$ ]] || fail "--gpu none passed devices"
# writable-cgroups, and lib/seccomp.json as the seccomp profile.
inspect '{{json .HostConfig.SecurityOpt}}' | python3 -I -c '
import json, sys
opts = json.load(sys.stdin)
ok = len(opts) == 2 and opts[0] == "writable-cgroups=true" and opts[1].startswith("seccomp=") \
  and json.loads(opts[1][len("seccomp="):]) == json.load(open(sys.argv[1]))
sys.exit(0 if ok else 1)' "$here/../lib/seccomp.json" ||
  fail "security options are not writable-cgroups=true and lib/seccomp.json"
[[ $(inspect '{{json .HostConfig.Tmpfs}}') == '{"/run":"","/run/lock":"","/run/secrets":"mode=0700","/tmp":""}' ]] ||
  fail "unexpected tmpfs mounts: $(inspect '{{json .HostConfig.Tmpfs}}')"
pass "run flags: unprivileged, no capabilities added, lib/seccomp.json, private cgroup namespace, a tty, no restart policy, no device, a root-only /run/secrets"

mounts=$(inspect '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}{{"\n"}}{{end}}' | sort)
grep -qx "volume $home_volume /home true" <<<"$mounts" || fail "no $home_volume on /home: $mounts"
grep -qx "volume $state_volume /var/lib/omanywhere true" <<<"$mounts" || fail "no $state_volume on /var/lib/omanywhere: $mounts"
grep -q " /run/secrets/password " <<<"$mounts" && fail "the default up mounted a password: $mounts"
grep -qx "bind  /run/secrets/authorized_keys false" <<<"$mounts" || fail "the keys are not a read-only secret file: $mounts"
pass "named volumes on /home and /var/lib/omanywhere; the keys as a read-only file, and no password"

[[ $(stat -c %a "$OMANYWHERE_CONFIG_DIR") == 700 && $(stat -c %a "$config") == 700 ]] || fail "the config directories are not 0700"
[[ ! -e $config/password ]] || fail "the default up made a password"
[[ $(<"$config/authorized_keys") == "$(<"$tmp/id_ed25519.pub")" ]] || fail "authorized_keys is not the --key file"
cexec "$container" test ! -e /run/secrets/password || fail "the container has /run/secrets/password"
out=$(cexec "$container" runuser -u "$user" -- sudo -n true 2>&1) || fail "sudo asks for a password, though the default up has none: $out"
cexec "$container" test -f /etc/polkit-1/rules.d/49-omanywhere-nopasswd.rules || fail "no polkit rule in the default up's container"
pass "config 0700, no password made or mounted by default; sudo asks for none"
# The bind-mounted files are the host user's (uid 1000, the owner's uid too),
# so only the root-only directory they sit in keeps the owner's programs out.
[[ $(cexec "$container" stat -c '%a %U' /run/secrets) == "700 root" ]] || fail "/run/secrets is not root's, mode 0700"
out=$(cexec "$container" runuser -u "$user" -- ls /run/secrets 2>&1) && fail "the owner can list /run/secrets: $out"
pass "/run/secrets is root's (0700): the owner can't list the secrets"

# ssh is published on loopback only, on the port the config keeps.
port=$(sed -n 's/^port=//p' "$config/settings")
[[ $port =~ ^[0-9]+$ ]] || fail "no port in $config/settings"
[[ $(docker port "$container" 22/tcp) == "127.0.0.1:$port" ]] || fail "ssh is not published on 127.0.0.1:$port only: $(docker port "$container")"
pass "ssh published on 127.0.0.1:$port only"

# --- up again: already running, and fast.
out=$("$cli" up "$name" 2>&1) || fail "a second up failed: $out"
[[ $out == *"already running"* ]] || fail "a second up did not say it is already running: $out"
pass "up on a running container: $out"
# --key on a running container rewrites the keys file in place (the
# container has it bind-mounted), for its next start; other options are
# ignored, and it says so.
mkdir "$tmp/second"
test_key "$tmp/second"
cat "$tmp/id_ed25519.pub" "$tmp/second/id_ed25519.pub" >"$tmp/both.pub"
inode=$(stat -c %i "$config/authorized_keys")
out=$("$cli" up "$name" --key "$tmp/both.pub" --gpu dri 2>&1) || fail "up --key on a running container failed: $out"
[[ $out == *"next starts"* && $out == *"ignoring --gpu"* ]] || fail "up --key on a running container did not say what it did: $out"
[[ $(<"$config/authorized_keys") == "$(<"$tmp/both.pub")" ]] || fail "up --key did not rewrite authorized_keys"
[[ $(stat -c %i "$config/authorized_keys") == "$inode" ]] || fail "authorized_keys was replaced, not rewritten in place"
[[ $(cexec "$container" cat /run/secrets/authorized_keys) == "$(<"$tmp/both.pub")" ]] ||
  fail "the container does not see the rewritten keys file"
pass "up --key on a running container rewrote the keys in place, for the next start"

# up --github does the same with the keys GitHub publishes, and shows them.
# Both keys, as the steps below log in with the second.
cp "$tmp/both.pub" "$tmp/gh/octo-cat.keys"
fingerprint=$(ssh-keygen -l -f "$tmp/id_ed25519.pub" | cut -d' ' -f2)
out=$(PATH=$tmp/bin:$PATH "$cli" up "$name" --github octo-cat --yes 2>&1) || fail "up --github on a running container failed: $out"
[[ $out == *"GitHub user octo-cat publishes"*"$fingerprint"* ]] || fail "up --github did not show the keys' fingerprints: $out"
[[ $(<"$config/authorized_keys") == "$(<"$tmp/gh/octo-cat.keys")" ]] || fail "up --github did not write GitHub's keys"
pass "up --github on a running container wrote the user's published keys, for the next start"

# --- status.
out=$("$cli" status "$name") || fail "status failed"
indent <<<"$out"
grep -Eq '^container +running' <<<"$out" || fail "status does not say the container is running"
grep -Eq '^systemd +running' <<<"$out" || fail "status does not say systemd is running"
grep -Eq "^owner +active \($user\)" <<<"$out" || fail "status does not show the owner unit active for $user"
grep -Eq '^desktop +skipped: .*no DRM card' <<<"$out" || fail "status does not say why the desktop was skipped"
grep -Eq "^ssh +127\.0\.0\.1:$port" <<<"$out" || fail "status does not show the ssh endpoint"
health=$(wait_healthy "$container" 30) || fail "docker reports $container $health, not healthy"
out=$("$cli" status "$name") || fail "status failed"
grep -Eq '^health +healthy$' <<<"$out" || fail "status does not say the container is healthy: $out"
pass "status shows the container, systemd, owner, desktop, health and ssh"

# --- ssh-config, and ssh through it.
"$cli" ssh-config "$name" >"$tmp/ssh_config" || fail "ssh-config failed"
indent <"$tmp/ssh_config"
block=$(grep -v '^[[:space:]]*#' "$tmp/ssh_config" | sed 's/^[[:space:]]*//' | sed '/^$/d')
[[ $block == "Host $container"$'\n'"HostName 127.0.0.1"$'\n'"Port $port"$'\n'"User $user"$'\n'"HostKeyAlias $container" ]] ||
  fail "unexpected Host block: $block"
grep -q 'ProxyJump' "$tmp/ssh_config" && fail "ssh-config guesses a ProxyJump (docs/usage.md says how)"
cat >>"$tmp/ssh_config" <<EOF

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
out=$(ssh -F "$tmp/ssh_config" "$container" id -un) || fail "ssh through the ssh-config block failed"
[[ $out == "$user" ]] || fail "ssh ran as '$out', not $user"
ssh-keygen -F "$container" -f "$tmp/known_hosts" >/dev/null || fail "known_hosts has no entry under the alias $container"
out=$(ssh -F "$tmp/ssh_config" "$container" ls /run/secrets 2>&1) && fail "the owner lists /run/secrets over ssh: $out"
pass "ssh -F <ssh-config> $container logs in as $user, who can't read /run/secrets; known_hosts keeps the key under $container"

# --- down keeps the volumes and the config.
"$cli" down "$name" >/dev/null || fail "down failed"
exists container "$container" && fail "down left the container"
if ! exists volume "$home_volume" || ! exists volume "$state_volume"; then fail "down removed the volumes"; fi
[[ -f $config/authorized_keys && -f $config/settings ]] || fail "down removed the config"
out=$("$cli" status "$name" 2>&1) && fail "status of a removed container succeeded: $out"
grep -Eq '^container +absent' <<<"$out" || fail "status does not say the container is absent: $out"
pass "down removed the container and kept the volumes and config; status says absent"

# --- up again, with the kept port taken: it fails, saying so, rather than
# move ssh to another port.
blocker=$container-blocker
check_name "$blocker"
docker run -d --name "$blocker" -p "127.0.0.1:$port:22" --entrypoint sleep "$IMAGE" infinity >/dev/null
fails "$port" up "$name"
exists container "$container" && fail "a failed up left a container"
cleanup "$blocker"
pass "up after down with port $port taken: failed, naming the port"

# --- up --password: a new container with the same port and host key, and a
# password for sudo.
"$cli" up "$name" --password >/dev/null 2>&1 || fail "up --password after down failed"
mounts=$(inspect '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}{{"\n"}}{{end}}' | sort)
grep -qx "bind  /run/secrets/password false" <<<"$mounts" || fail "the password is not a read-only secret file: $mounts"
[[ $(stat -c %a "$config/password") == 600 ]] || fail "the password file is not 0600"
password=$(<"$config/password")
((${#password} >= 20)) || fail "the password is short: ${#password} characters"
inspect '{{json .Config.Env}} {{json .Args}} {{json .Config.Cmd}} {{json .Path}}' | grep -F "$password" >/dev/null &&
  fail "the password is in the container's environment or arguments"
cexec "$container" journalctl -b --no-pager | grep -F "$password" >/dev/null && fail "the password is in the journal"
out=$(docker exec -i "$container" runuser -u "$user" -- sudo -S -p '' true 2>&1 <"$config/password") ||
  fail "sudo with the generated password failed: $out"
out=$(cexec "$container" runuser -u "$user" -- sudo -n true 2>&1) && fail "sudo ran without a password, with --password"
cexec "$container" test ! -e /etc/polkit-1/rules.d/49-omanywhere-nopasswd.rules || fail "the polkit rule exists with a password"
pass "up --password: password 0600 (${#password} characters), not in argv, env or journal; sudo takes it and asks for it"
[[ $(cexec "$container" stat -c '%a %U' /run/secrets) == "700 root" ]] || fail "/run/secrets is not root's, mode 0700"
out=$(cexec "$container" runuser -u "$user" -- cat /run/secrets/password 2>&1) && fail "the owner can read the password: $out"
out=$(cexec "$container" runuser -u "$user" -- ls /run/secrets 2>&1) && fail "the owner can list /run/secrets: $out"
pass "/run/secrets is root's (0700): the owner can neither read the password nor list the secrets"
[[ $(docker port "$container" 22/tcp) == "127.0.0.1:$port" ]] || fail "the new container is not on port $port"
[[ $(<"$config/password") == "$password" ]] || fail "the password changed"
out=$(ssh -F "$tmp/ssh_config" -o StrictHostKeyChecking=yes "$container" id -un) ||
  fail "ssh to the new container failed (host key changed?)"
# Only the second key: a command-line IdentityFile would add to the config's.
sed "s|IdentityFile $tmp/id_ed25519\$|IdentityFile $tmp/second/id_ed25519|" "$tmp/ssh_config" >"$tmp/ssh_config.second"
grep -q "IdentityFile $tmp/second/id_ed25519" "$tmp/ssh_config.second" || fail "could not make an ssh config for the second key"
out=$(ssh -F "$tmp/ssh_config.second" -o StrictHostKeyChecking=yes "$container" id -un) ||
  fail "the key added with up --key does not log in after the container was made again"
out=$(ssh -F "$tmp/ssh_config" "$container" cat /run/secrets/password 2>&1) && fail "the owner reads the password over ssh: $out"
pass "up after down: port $port, password and host key kept; the key added with up --key logs in; the owner can't read the password over ssh"

# --- No sshd after boot (masked here, which survives a restart): up fails
# as for the owner, with sshd's journal, and stops the container.
cexec "$container" systemctl mask sshd.service >/dev/null 2>&1 || fail "could not mask sshd"
docker stop -t 30 "$container" >/dev/null
out=$("$cli" up "$name" 2>&1) && fail "up with sshd masked succeeded: $out"
[[ $out == *"sshd.service"* ]] || fail "up did not say sshd failed: $out"
[[ $(docker inspect -f '{{.State.Running}}' "$container") == false ]] || fail "the container still runs without sshd"
pass "no sshd after boot: up failed, named sshd.service, and stopped the container"

# --- A password-only desktop: up --password with no key. The agent's keys are
# not taken for it, and ssh takes the password (tests/owner.sh checks the
# sshd settings; this is a real login). Then the key and password paths:
# a key added to the existing container, an old settings file with a
# password file beside it, and --no-password.
pwname=$name-pw
pwcontainer=omanywhere-$pwname
check_name "$pwcontainer"
pwconfig=$OMANYWHERE_CONFIG_DIR/$pwname
(umask 077 && mkdir -p "$pwconfig" && printf '  \n' >"$pwconfig/password")
out=$(SSH_AUTH_SOCK=$tmp/no-agent "$cli" up "$pwname" --gpu none --password 2>&1) && fail "up with a blank password file succeeded: $out"
[[ $out == *"$pwconfig/password is blank"* ]] || fail "up did not name the blank password file: $out"
exists container "$pwcontainer" && fail "a refused up made a container"
(umask 077 && printf '\nsecret\n' >"$pwconfig/password")
out=$(SSH_AUTH_SOCK=$tmp/no-agent "$cli" up "$pwname" --gpu none --password 2>&1) && fail "up with a two-line password file succeeded: $out"
[[ $out == *"more than one line"* ]] || fail "up did not refuse a two-line password file: $out"
(umask 077 && printf 'my-own-password-%s\n' "$$" >"$pwconfig/password")
out=$(SSH_AUTH_SOCK=$tmp/no-agent "$cli" up "$pwname" --gpu none --password 2>&1) || fail "up --password with no key failed: $out"
[[ -f $pwconfig/authorized_keys && ! -s $pwconfig/authorized_keys ]] || fail "the keys file is not empty with no key"
[[ $(<"$pwconfig/password") == "my-own-password-$$" ]] || fail "up --password replaced the password the user wrote"
cexec "$pwcontainer" test ! -s /run/secrets/authorized_keys || fail "the password-only container has a key"
pwport=$(sed -n 's/^port=//p' "$pwconfig/settings")
pw_login() {
  password_ssh "$pwconfig/password" -p "$pwport" -l "$1" 127.0.0.1 id -un
}
out=$(pw_login "$user") || fail "ssh with the password failed: $out"
[[ $out == "$user" ]] || fail "ssh with the password ran as '$out', not $user"
out=$(pw_login root) && fail "root logged in with the password: $out"
printf 'not-the-password\n' >"$tmp/wrong"
out=$(password_ssh "$tmp/wrong" -p "$pwport" -l "$user" 127.0.0.1 true 2>&1) && fail "a wrong password logged in"
pass "up --password with no key: an empty keys file, the user's own password kept, ssh takes the password for $user only (not a wrong one, not root)"
# A key added to the existing container applies at its next start, and then
# the password no longer logs in.
out=$("$cli" up "$pwname" --key "$tmp/id_ed25519.pub" 2>&1) || fail "up --key on the password-only container failed: $out"
docker stop -t 30 "$pwcontainer" >/dev/null
"$cli" up "$pwname" >/dev/null 2>&1 || fail "up after stop failed"
out=$(ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10 -i "$tmp/id_ed25519" -p "$pwport" "$user@127.0.0.1" 'id -un') ||
  fail "the added key does not log in after a restart: $out"
out=$(pw_login "$user" 2>&1) && fail "the password still logs in beside a key: $out"
pass "up --key on a password-only container: after a restart the key logs in and the password no longer does"
# An old settings file with a sudo= line, beside a password file: the
# container made again keeps the password.
"$cli" down "$pwname" >/dev/null || fail "down failed"
printf 'sudo=nopasswd\n' >>"$pwconfig/settings"
out=$("$cli" up "$pwname" 2>&1) || fail "up with an old settings file failed: $out"
[[ $out == *"sudo=nopasswd from an older omanywhere"* ]] || fail "up did not say the old sudo=nopasswd no longer applies: $out"
cexec "$pwcontainer" test -f /run/secrets/password || fail "the password was not mounted with an old sudo= line and a password file"
out=$(cexec "$pwcontainer" runuser -u "$user" -- sudo -n true 2>&1) && fail "sudo ran without a password, with a password file"
pass "an old settings file (sudo=nopasswd) with a password file: up keeps the password"
# A container made with a password doesn't start once the file is gone, and
# up says why.
docker stop -t 30 "$pwcontainer" >/dev/null
mv "$pwconfig/password" "$tmp/kept-password"
out=$("$cli" up "$pwname" 2>&1) && fail "up started a container made with a password whose file is gone: $out"
[[ $out == *"was made with a password"* ]] || fail "up did not say the password file is gone: $out"
mv "$tmp/kept-password" "$pwconfig/password"
pass "a container made with a password whose file is gone: up refuses and says why"
# --no-password deletes the file, and the next container has none.
"$cli" down "$pwname" >/dev/null || fail "down failed"
out=$("$cli" up "$pwname" --no-password 2>&1) || fail "up --no-password failed: $out"
[[ $out == *"deleted $pwconfig/password"* && ! -e $pwconfig/password ]] || fail "up --no-password did not delete the password file: $out"
cexec "$pwcontainer" test ! -e /run/secrets/password || fail "the container has a password after --no-password"
cexec "$pwcontainer" runuser -u "$user" -- sudo -n true || fail "sudo asks for a password after --no-password"
pass "up --no-password: the password file is deleted, and the new container has none"
"$cli" down "$pwname" --purge --yes >/dev/null || fail "down --purge of the second container failed"

# --- up --data: the volumes keep their files in DIR/home and DIR/state,
# which Docker fills from the image. down and up keep them there, a
# different --data is refused, and down --purge leaves the files.
dname=$name-data
dcontainer=omanywhere-$dname
check_name "$dcontainer"
data=$tmp/data
fails "takes a directory other than /, whose path has no comma" up "$dname" --gpu none --key "$tmp/id_ed25519.pub" --data "$tmp/a,b"
fails "takes a directory other than /" up "$dname" --gpu none --key "$tmp/id_ed25519.pub" --data /
exists volume "$dcontainer-home" && fail "a refused up --data made a volume"
out=$("$cli" up "$dname" --gpu none --key "$tmp/id_ed25519.pub" --data "$data" 2>&1) || fail "up --data failed: $out"
for sub in home state; do
  dir=$(docker volume inspect -f '{{index .Options "device"}}' "$dcontainer-$sub")
  [[ $dir == "$data/$sub" ]] || fail "$dcontainer-$sub keeps its files in '$dir', not $data/$sub"
done
[[ -d $data/home/$user && -e $data/state/ssh/ssh_host_ed25519_key.pub ]] ||
  fail "the image's home and the host key are not in $data: $(find "$data" -maxdepth 3 2>&1 | head -20)"
[[ $(stat -c %a "$data") == 700 ]] || fail "$data is $(stat -c %a "$data"), not 700"
[[ $("$cli" status "$dname") == *"data       $data/home and $data/state"* ]] || fail "status does not show the data directory"
key=$(cat "$data/state/ssh/ssh_host_ed25519_key.pub")
"$cli" down "$dname" >/dev/null || fail "down of the --data container failed"
fails "keeps its files in $data/home, not $tmp/other/home" up "$dname" --data "$tmp/other"
mv "$data" "$tmp/moved"
fails "keeps its files in $data/home, which is gone" up "$dname"
mv "$tmp/moved" "$data"
out=$("$cli" up "$dname" 2>&1) || fail "up again, without --data, failed: $out"
[[ $(cexec "$dcontainer" cat /var/lib/omanywhere/ssh/ssh_host_ed25519_key.pub) == "$key" ]] ||
  fail "the container made again has another host key"
out=$("$cli" down "$dname" --purge --yes 2>&1) || fail "down --purge of the --data container failed: $out"
[[ $out == *"the removed volumes' files stay in $data/home $data/state"* ]] || fail "down --purge did not say the files stay: $out"
exists volume "$dcontainer-home" && fail "down --purge left $dcontainer-home"
[[ $(cat "$data/state/ssh/ssh_host_ed25519_key.pub") == "$key" ]] || fail "down --purge removed the files in $data"
pass "up --data: Docker fills DIR/home and DIR/state from the image, down and up keep them, another DIR is refused, and down --purge leaves the files"
# --data on a volume in Docker's own store is refused.
sname=$name-store
check_name "omanywhere-$sname"
docker volume create "omanywhere-$sname-home" >/dev/null
fails "is in Docker's own volume store" up "$sname" --gpu none --key "$tmp/id_ed25519.pub" --data "$tmp/store"
exists container "omanywhere-$sname" && fail "a refused up --data made a container"
remove_volumes "omanywhere-$sname-home"
pass "up --data refuses a volume already in Docker's own store"

# --- down --purge: asks, and with no terminal refuses without --yes.
out=$("$cli" down "$name" --purge </dev/null 2>&1) && fail "down --purge without --yes or a terminal succeeded: $out"
exists container "$container" || fail "a refused purge removed the container"
[[ -d $config ]] || fail "a refused purge removed the config"
# A volume another container uses can't be removed: down --purge names it,
# keeps the config (the password, for the volume's owner), and fails.
holder=$container-holder
check_name "$holder"
docker create --name "$holder" -v "$home_volume:/x" "$IMAGE" >/dev/null
out=$("$cli" down "$name" --purge --yes 2>&1) && fail "down --purge with a volume in use succeeded: $out"
[[ $out == *"$home_volume"* ]] || fail "down --purge did not name the volume it could not remove: $out"
exists container "$container" && fail "down --purge left the container"
exists volume "$state_volume" && fail "down --purge left $state_volume, which nothing uses"
[[ -f $config/password ]] || fail "down --purge removed the config though a volume stayed"
cleanup "$holder"
pass "down --purge with a volume in use: named it, kept the config, failed"
"$cli" down "$name" --purge --yes >/dev/null || fail "down --purge --yes failed"
exists container "$container" && fail "down --purge left the container"
exists volume "$home_volume" && fail "down --purge left $home_volume"
exists volume "$state_volume" && fail "down --purge left $state_volume"
[[ ! -e $config ]] || fail "down --purge left $config"
pass "down --purge refuses without --yes and no terminal; with --yes it removes container, volumes and config"

echo "cli test passed"
