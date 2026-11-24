#!/bin/bash
# CLI test: bin/omanywhere's up, status, ssh-config and down, with no device.
#   - up refuses a bad name or --gpu, and fails before it creates anything when
#     it has no ssh key;
#   - a key the container rejects fails the owner unit: up fails loudly with
#     the unit's journal and leaves the container stopped, and up --key with a
#     good key starts it again;
#   - up runs the container with the run flags and nothing more, ssh on
#     127.0.0.1 only, the password as a read-only secret file it made (never
#     in argv or the environment), and is idempotent;
#   - status and ssh-config describe it, and the owner gets in with ssh through
#     the printed Host block;
#   - down keeps the volumes and the config, so a new up keeps the port, the
#     password and the host key; down --purge asks first, and --yes removes
#     everything.
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
trap '"$cli" down "$name" --purge --yes >/dev/null 2>&1 || true
  cleanup "$container"; remove_volumes "$home_volume" "$state_volume"; rm -rf "$tmp"' EXIT

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
fails "--drm-master" up "$name" --drm-master yes --key "$tmp/id_ed25519.pub"
fails "--listen" up "$name" --listen 'not an address' --key "$tmp/id_ed25519.pub"
fails "usage" frobnicate "$name"
# No key: no --key, and no agent to ask.
out=$(SSH_AUTH_SOCK=$tmp/no-agent "$cli" up "$name" --gpu none 2>&1) && fail "up without a key succeeded: $out"
[[ $out == *"no ssh key"* ]] || fail "up without a key did not say 'no ssh key': $out"
printf '# only a comment\n\n' >"$tmp/empty.pub"
fails "no ssh key" up "$name" --gpu none --key "$tmp/empty.pub"
exists container "$container" && fail "a failed up left a container"
exists volume "$home_volume" && fail "a failed up left a volume"
[[ ! -e $config ]] || fail "a failed up left $config"
pass "bad names, flags and no key are refused before anything is made"

# --- A key line the owner unit rejects: up fails loudly, with the unit's own
# words, and the container is left stopped, not running without a way in.
printf 'ssh-ed25519 not-a-key\n' >"$tmp/bad.pub"
out=$("$cli" up "$name" --gpu none --key "$tmp/bad.pub" 2>&1) && fail "up with a bad key succeeded: $out"
[[ $out == *"line 1 is not an ssh public key"* ]] || fail "up did not show the owner unit's journal: $out"
[[ $(docker inspect -f '{{.State.Running}}' "$container") == false ]] || fail "the container still runs after the owner unit failed"
pass "a rejected key: up failed with the owner unit's journal, and the container is stopped"

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
[[ $(inspect '{{json .HostConfig.SecurityOpt}}') == '["writable-cgroups=true"]' ]] ||
  fail "security options are not just writable-cgroups=true: $(inspect '{{json .HostConfig.SecurityOpt}}')"
pass "run flags: unprivileged, no capabilities added, private cgroup namespace, a tty, no restart policy, no device"

mounts=$(inspect '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}{{"\n"}}{{end}}' | sort)
grep -qx "volume $home_volume /home true" <<<"$mounts" || fail "no $home_volume on /home: $mounts"
grep -qx "volume $state_volume /var/lib/omanywhere true" <<<"$mounts" || fail "no $state_volume on /var/lib/omanywhere: $mounts"
grep -qx "bind  /run/secrets/password false" <<<"$mounts" || fail "the password is not a read-only secret file: $mounts"
grep -qx "bind  /run/secrets/authorized_keys false" <<<"$mounts" || fail "the keys are not a read-only secret file: $mounts"
pass "named volumes on /home and /var/lib/omanywhere; password and keys as read-only files"

[[ $(stat -c %a "$OMANYWHERE_CONFIG_DIR") == 700 && $(stat -c %a "$config") == 700 ]] || fail "the config directories are not 0700"
[[ $(stat -c %a "$config/password") == 600 ]] || fail "the password file is not 0600"
password=$(<"$config/password")
((${#password} >= 20)) || fail "the password is short: ${#password} characters"
[[ $(<"$config/authorized_keys") == "$(<"$tmp/id_ed25519.pub")" ]] || fail "authorized_keys is not the --key file"
inspect '{{json .Config.Env}} {{json .Args}} {{json .Config.Cmd}} {{json .Path}}' | grep -qF "$password" &&
  fail "the password is in the container's environment or arguments"
cexec "$container" journalctl -b --no-pager | grep -qF "$password" && fail "the password is in the journal"
out=$(docker exec -i "$container" runuser -u "$user" -- sudo -S -p '' true 2>&1 <"$config/password") ||
  fail "sudo with the generated password failed: $out"
pass "config 0700, password 0600 (${#password} characters), not in argv, env or journal; sudo takes it"

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

# --- status.
out=$("$cli" status "$name") || fail "status failed"
indent <<<"$out"
grep -Eq '^container +running' <<<"$out" || fail "status does not say the container is running"
grep -Eq '^systemd +running' <<<"$out" || fail "status does not say systemd is running"
grep -Eq "^owner +active \($user\)" <<<"$out" || fail "status does not show the owner unit active for $user"
grep -Eq '^desktop +skipped: .*no DRM card' <<<"$out" || fail "status does not say why the desktop was skipped"
grep -Eq "^ssh +127\.0\.0\.1:$port" <<<"$out" || fail "status does not show the ssh endpoint"
pass "status shows the container, systemd, owner, desktop and ssh"

# --- ssh-config, and ssh through it.
"$cli" ssh-config "$name" >"$tmp/ssh_config" || fail "ssh-config failed"
indent <"$tmp/ssh_config"
block=$(grep -v '^[[:space:]]*#' "$tmp/ssh_config" | sed 's/^[[:space:]]*//' | sed '/^$/d')
[[ $block == "Host $container"$'\n'"HostName 127.0.0.1"$'\n'"Port $port"$'\n'"User $user"$'\n'"HostKeyAlias $container" ]] ||
  fail "unexpected Host block: $block"
grep -q '^[[:space:]]*#.*ProxyJump' "$tmp/ssh_config" || fail "no ProxyJump hint for a loopback address"
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
pass "ssh -F <ssh-config> $container logs in as $user; known_hosts keeps the key under $container"

# --- down keeps the volumes and the config.
"$cli" down "$name" >/dev/null || fail "down failed"
exists container "$container" && fail "down left the container"
if ! exists volume "$home_volume" || ! exists volume "$state_volume"; then fail "down removed the volumes"; fi
[[ -f $config/password && -f $config/settings ]] || fail "down removed the config"
out=$("$cli" status "$name" 2>&1) && fail "status of a removed container succeeded: $out"
grep -Eq '^container +absent' <<<"$out" || fail "status does not say the container is absent: $out"
pass "down removed the container and kept the volumes and config; status says absent"

# --- up again: a new container with the same port, password and host key.
"$cli" up "$name" >/dev/null 2>&1 || fail "up after down failed"
[[ $(docker port "$container" 22/tcp) == "127.0.0.1:$port" ]] || fail "the new container is not on port $port"
[[ $(<"$config/password") == "$password" ]] || fail "the password changed"
out=$(ssh -F "$tmp/ssh_config" -o StrictHostKeyChecking=yes "$container" id -un) ||
  fail "ssh to the new container failed (host key changed?)"
# Only the second key: a command-line IdentityFile would add to the config's.
sed "s|IdentityFile $tmp/id_ed25519\$|IdentityFile $tmp/second/id_ed25519|" "$tmp/ssh_config" >"$tmp/ssh_config.second"
grep -q "IdentityFile $tmp/second/id_ed25519" "$tmp/ssh_config.second" || fail "could not make an ssh config for the second key"
out=$(ssh -F "$tmp/ssh_config.second" -o StrictHostKeyChecking=yes "$container" id -un) ||
  fail "the key added with up --key does not log in after the container was made again"
pass "up after down: port $port, password and host key kept; the key added with up --key logs in"

# --- down --purge: asks, and with no terminal refuses without --yes.
out=$("$cli" down "$name" --purge </dev/null 2>&1) && fail "down --purge without --yes or a terminal succeeded: $out"
exists container "$container" || fail "a refused purge removed the container"
[[ -d $config ]] || fail "a refused purge removed the config"
"$cli" down "$name" --purge --yes >/dev/null || fail "down --purge --yes failed"
exists container "$container" && fail "down --purge left the container"
exists volume "$home_volume" && fail "down --purge left $home_volume"
exists volume "$state_volume" && fail "down --purge left $state_volume"
[[ ! -e $config ]] || fail "down --purge left $config"
pass "down --purge refuses without --yes and no terminal; with --yes it removes container, volumes and config"

echo "cli test passed"
