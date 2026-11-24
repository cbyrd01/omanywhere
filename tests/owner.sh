#!/bin/bash
# Owner test: omanywhere-owner.service makes the owner from the container's
# inputs, ssh lets the owner in with a key and nothing else, the owner's
# pre-refresh-pacman hook keeps pacman working after Omarchy rewrites
# pacman.conf, and recreating the container over the same volumes keeps the
# account, its home, the ssh host key and the machine-id. Bad inputs fail the
# unit, and sshd with it, and so does a password in the environment: it is
# taken only as a file. Usage: tests/owner.sh (IMAGE defaults to
# omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

run=omanywhere-test-owner-$$
first=$run-first
second=$run-second
nokey=$run-nokey
envpw=$run-envpw
home_volume=$run-home
state_volume=$run-state
tmp=$(mktemp -d)
trap 'cleanup "$first" "$second" "$nokey" "$envpw"; remove_volumes "$home_volume" "$state_volume"; rm -rf "$tmp"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"

user=ada
uid=1500
tz=Europe/Paris
test_key "$tmp"
mkdir "$tmp/own"
test_key "$tmp/own" # a key the owner adds to ~/.ssh/authorized_keys themselves
password=$(head -c 18 /dev/urandom | base64)
nopasswd=/etc/sudoers.d/90-omanywhere-nopasswd
printf '%s\n' "$password" >"$tmp/password"
volumes=(-v "$home_volume:/home" -v "$state_volume:/var/lib/omanywhere")
marker=/home/$user/.local/state/omarchy/done/finalize-user
hook=/home/$user/.config/omarchy/hooks/pre-refresh-pacman.d/omanywhere-pacman-sandbox
# Each ssh adds the key it logs in with: -i "$tmp/id_ed25519" unless it says.
ssh_opts=(-F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes
  -o ConnectTimeout=10 -o LogLevel=ERROR)

# boot NAME: wait for the boot to finish and require the owner unit to be up.
boot() {
  wait_running "$1" 120 >/dev/null || fail "$1: systemd did not finish booting"
  wait_settled "$1" 60 || fail "$1: systemd still had jobs queued 60 s after boot"
  if ! cexec "$1" systemctl is-active --quiet omanywhere-owner.service; then
    cexec "$1" journalctl -b -u omanywhere-owner.service --no-pager >&2 || true
    fail "$1: omanywhere-owner.service is not active"
  fi
}

# sorted_groups NAME: the owner's groups in NAME, sorted, on one line.
sorted_groups() {
  cexec "$1" id -nG "$user" | tr ' ' '\n' | sort | paste -sd ' '
}

# check_ssh NAME: the owner gets in with the key, as themselves; the server
# offers no method but publickey; root can't log in.
check_ssh() {
  local ip out
  ip=$(container_ip "$1")
  local ssh=(ssh "${ssh_opts[@]}" -i "$tmp/id_ed25519")
  out=$("${ssh[@]}" "$user@$ip" 'id -un') || fail "$1: key login as $user failed"
  [[ $out == "$user" ]] || fail "$1: ssh ran as '$out', not $user"
  # With no method to try, the client prints the methods the server offers.
  out=$("${ssh[@]}" -o PreferredAuthentications=none "$user@$ip" true 2>&1) &&
    fail "$1: login with no authentication succeeded"
  [[ $out == *"Permission denied (publickey)."* ]] || fail "$1: the server offers more than publickey: $out"
  "${ssh[@]}" "root@$ip" true 2>/dev/null && fail "$1: root logged in over ssh"
  out=$(cexec "$1" sshd -T)
  grep -qix 'permitrootlogin no' <<<"$out" || fail "$1: sshd permits root login"
  grep -qix 'passwordauthentication no' <<<"$out" || fail "$1: sshd allows passwords"
  ssh-keyscan -T 5 -t ed25519 "$ip" 2>/dev/null | awk '{ print $3 }'
}

# --- First boot, over empty volumes: key in the environment, password as a
# secret file.
start_container "$first" "${volumes[@]}" \
  -e OMANYWHERE_USER="$user" -e OMANYWHERE_UID="$uid" -e TZ="$tz" \
  -e OMANYWHERE_AUTHORIZED_KEYS="$(cat "$tmp/id_ed25519.pub")" \
  -v "$tmp/password:/run/secrets/password:ro"
boot "$first"
pass "first boot: omanywhere-owner.service is active"

[[ $(cexec "$first" cat /run/omanywhere/owner) == "$user" ]] || fail "/run/omanywhere/owner does not name $user"
[[ $(cexec "$first" id -u "$user") == "$uid" && $(cexec "$first" id -g "$user") == "$uid" ]] ||
  fail "$user does not have uid and gid $uid"
# x86 system setup records no groups, so the owner gets wheel alone.
groups=$(sorted_groups "$first")
[[ $groups == "$user wheel" ]] || fail "$user's groups are '$groups', not '$user wheel'"
pass "$user exists with uid $uid, gid $uid and groups $groups"

cexec "$first" test -f "$marker" || fail "Omarchy's user setup did not run: no $marker"
marker_time=$(cexec "$first" stat -c %.9Y "$marker")
pass "Omarchy's user setup ran ($marker)"

[[ $(cexec "$first" stat -c '%a %U' /run/omanywhere/authorized_keys "/run/omanywhere/authorized_keys/$user") == \
  $'755 root\n644 root' ]] || fail "/run/omanywhere/authorized_keys/$user is not root's, 0644, in a 0755 directory"
cexec "$first" test ! -e "/home/$user/.ssh/authorized_keys" || fail "the owner script wrote ~/.ssh/authorized_keys"
[[ $(cexec "$first" readlink -f /etc/localtime) == "/usr/share/zoneinfo/$tz" ]] || fail "/etc/localtime is not $tz"
pass "input keys in /run/omanywhere/authorized_keys/$user (root, 0644), ~/.ssh untouched; timezone $tz"

log=$(cexec "$first" journalctl -b --no-pager)
[[ $log != *"$password"* ]] || fail "the password is in the journal"
out=$(docker exec -i "$first" runuser -u "$user" -- sudo -S -p '' true 2>&1 <<<"$password") ||
  fail "sudo with the owner's password failed: $out"
out=$(cexec "$first" runuser -u "$user" -- sudo -n true 2>&1) && fail "sudo ran without a password, with no OMANYWHERE_SUDO"
cexec "$first" test ! -e "$nopasswd" || fail "$nopasswd exists, with no OMANYWHERE_SUDO"
pass "sudo works with the password from /run/secrets/password, which the journal doesn't contain, and asks for it"

# lib/seccomp.json allows the namespaces Chromium's sandbox makes; with
# Docker's default profile it crashes at start.
out=$(cexec "$first" runuser -u "$user" -- env HOME=/tmp/chromium-test \
  chromium --headless=new --dump-dom 'data:text/html,<p>sandboxed</p>' 2>&1) ||
  fail "Chromium failed in the container: $out"
grep -F '<p>sandboxed</p>' >/dev/null <<<"$out" || fail "Chromium did not render the page: $out"
pass "Chromium runs with its sandbox (lib/seccomp.json)"
# The namespaces it allows don't reach netfilter: in a user and network
# namespace of its own, the owner gets a route netlink socket but no
# NETLINK_NETFILTER one, even with the protocol's upper 32 bits set.
out=$(cexec "$first" runuser -u "$user" -- unshare -Urn python3 -I -c '
import ctypes, errno
libc = ctypes.CDLL(None, use_errno=True)
for protocol in 0, 12, 1 << 32 | 12:
    fd = libc.syscall(41, 16, 3, ctypes.c_long(protocol))  # x86_64 socket(AF_NETLINK, SOCK_RAW, ...)
    print("ok" if fd >= 0 else errno.errorcode[ctypes.get_errno()], end=" ")' 2>&1)
[[ $out == "ok EPERM EPERM " ]] ||
  fail "netlink sockets in a user and network namespace (route, netfilter, netfilter with high bits): $out, not ok EPERM EPERM"
pass "netfilter is out of reach from a user namespace (lib/seccomp.json)"

# Omarchy's refresh puts its own pacman.conf back; pacman then can't download
# in a container until the owner's hook, run by omarchy-hook as Omarchy's
# refresh does, adds the line again. Its sudo needs the owner's password: on
# one terminal (script makes it), sudo -v takes it from the secret first, and
# the hook's sudo reuses that terminal's cached credential.
cexec "$first" test -f "$hook" || fail "the owner unit did not install $hook"
cexec "$first" cp /usr/share/omarchy/default/pacman/pacman-stable.conf /etc/pacman.conf
cexec "$first" pacman -Sy --noconfirm >/dev/null 2>&1 &&
  fail "pacman -Sy worked without DisableSandboxFilesystem: is the line still needed?"
# /run/secrets is root's alone, so the test hands the owner a copy for this.
cexec "$first" install -m 0400 -o "$user" /run/secrets/password /tmp/test-password
out=$(cexec "$first" runuser -u "$user" -- script -qec \
  'sudo -S -p "" -v </tmp/test-password && omarchy-hook pre-refresh-pacman' /dev/null 2>&1) ||
  fail "omarchy-hook pre-refresh-pacman failed: $out"
cexec "$first" rm -f /tmp/test-password
[[ $out != *"Hook failed"* ]] || fail "the pacman hook failed: $out"
out=$(cexec "$first" pacman -Sy --noconfirm 2>&1) || fail "pacman -Sy failed after the hook: $out"
pass "after Omarchy's pacman.conf is restored, the owner's hook makes pacman -Sy work again"
# The hook is the owner's now: a change to it must survive the recreate.
cexec "$first" runuser -u "$user" -- sh -c "echo '# changed by the owner' >>'$hook'"
# A key the owner adds themselves.
docker exec -i "$first" runuser -u "$user" -- sh -c 'umask 077 && mkdir -p ~/.ssh && cat >>~/.ssh/authorized_keys' \
  <"$tmp/own/id_ed25519.pub"

host_key=$(check_ssh "$first")
[[ -n $host_key ]] || fail "no ed25519 host key from sshd"
cexec "$first" grep -qF "$host_key" /var/lib/omanywhere/ssh/ssh_host_ed25519_key.pub ||
  fail "sshd's host key is not the one in /var/lib/omanywhere"
[[ -z $(cexec "$first" find /etc/ssh -maxdepth 1 -name 'ssh_host_*') ]] || fail "host keys were made in /etc/ssh as well"
pass "ssh: key login works, publickey is the only method, no root; host key in the state volume"

machine_id=$(cexec "$first" cat /etc/machine-id)
[[ $machine_id =~ ^[0-9a-f]{32}$ ]] || fail "no machine-id: '$machine_id'"
[[ $(cexec "$first" cat /var/lib/omanywhere/machine-id) == "$machine_id" ]] ||
  fail "the machine-id is not kept in /var/lib/omanywhere/machine-id"
pass "machine-id $machine_id, kept in the state volume"

# --- Recreate over the same volumes. This time the key comes as a secret
# file, there is no password, and Omarchy has (as far as this container knows)
# recorded groups, mounted in to exercise that path.
cleanup "$first"
printf '%s\n' video docker no-such-group >"$tmp/groups"
start_container "$second" "${volumes[@]}" \
  -e OMANYWHERE_USER="$user" -e OMANYWHERE_UID="$uid" -e OMANYWHERE_SUDO=nopasswd \
  -v "$tmp/id_ed25519.pub:/run/secrets/authorized_keys:ro" \
  -v "$tmp/groups:/var/lib/omarchy/provisioning/groups:ro"
boot "$second"
pass "recreated: omanywhere-owner.service is active"

[[ $(cexec "$second" id -u "$user") == "$uid" ]] || fail "$user's uid changed on recreate"
[[ $(cexec "$second" stat -c %.9Y "$marker") == "$marker_time" ]] ||
  fail "Omarchy's first-install user setup ran again (the marker's mtime changed)"
log=$(cexec "$second" journalctl -b -u omanywhere-owner.service --no-pager)
grep -q 'already ran' <<<"$log" ||
  fail "the owner unit's journal does not say the user setup was skipped"
pass "uid $uid kept; first-install user setup not run again (marker mtime $marker_time)"

# Recorded video, docker and no-such-group: video is added; docker never is,
# and no-such-group doesn't exist.
groups=$(sorted_groups "$second")
[[ $groups == "$user video wheel" ]] || fail "$user's groups are '$groups', not '$user video wheel'"
pass "recorded groups applied, docker and the missing group left out: $groups"
cexec "$second" grep -qx '# changed by the owner' "$hook" || fail "the owner's change to $hook was overwritten"
pass "the owner's pre-refresh-pacman hook kept as they left it"

cexec "$second" bash -c "getent shadow $user | cut -d: -f2 | grep -q '^!'" || fail "$user's password is not locked"
grep -qF "password is locked, so the lock screen can't be used" <<<"$log" ||
  fail "the journal does not say that the lock screen needs a password"
pass "no password given: the password is locked, and the journal says so"

# OMANYWHERE_SUDO=nopasswd: sudo asks for no password, though there is none.
# Without it, on the next run, the rule is gone.
grep -qF "sudo asks $user for no password" <<<"$log" || fail "the journal does not say that sudo asks for no password"
[[ $(cexec "$second" stat -c '%a %U' "$nopasswd") == "440 root" ]] || fail "$nopasswd is not root's, mode 0440"
out=$(cexec "$second" runuser -u "$user" -- sudo -n true 2>&1) || fail "sudo asked for a password with OMANYWHERE_SUDO=nopasswd: $out"
pass "OMANYWHERE_SUDO=nopasswd: sudo asks for no password ($nopasswd, root's, 0440)"

second_key=$(check_ssh "$second")
[[ $second_key == "$host_key" ]] || fail "the ssh host key changed on recreate"
[[ $(cexec "$second" cat /etc/machine-id) == "$machine_id" ]] || fail "the machine-id changed on recreate"
pass "ssh key login works; host key and machine-id kept"
out=$(ssh "${ssh_opts[@]}" -i "$tmp/own/id_ed25519" "$user@$(container_ip "$second")" 'id -un') ||
  fail "the key the owner added to ~/.ssh/authorized_keys no longer logs in"
pass "the owner's own key in ~/.ssh/authorized_keys still logs in"

# Run again without OMANYWHERE_SUDO, last, as a boot of this container would:
# the rule is removed.
out=$(docker exec -e OMANYWHERE_SUDO= "$second" /usr/lib/omanywhere/owner 2>&1) || fail "the owner script failed with OMANYWHERE_SUDO unset: $out"
cexec "$second" test ! -e "$nopasswd" || fail "$nopasswd is still there with OMANYWHERE_SUDO unset"
out=$(cexec "$second" runuser -u "$user" -- sudo -n true 2>&1) && fail "sudo still ran without a password, with OMANYWHERE_SUDO unset"
pass "OMANYWHERE_SUDO unset: the rule is removed, and sudo asks for the password again"

# A DRM node in host gid 997, which is empower here, goes to video instead.
cexec "$second" bash -c 'mkdir -p /dev/dri && mknod -m 0660 /dev/dri/card9 c 226 9 && chgrp 997 /dev/dri/card9' ||
  fail "can't make a test DRM node in gid 997"
[[ $(cexec "$second" getent group 997 | cut -d: -f1) == empower ]] ||
  fail "gid 997 is not empower in the image; pick another polkit-trusted gid for this test"
out=$(docker exec -e OMANYWHERE_SUDO= "$second" /usr/lib/omanywhere/owner 2>&1) || fail "the owner script failed with a DRM node in gid 997: $out"
node_group=$(cexec "$second" bash -c 'stat -c %G /dev/dri/card9; rm -f /dev/dri/card9')
[[ $node_group == video ]] || fail "the DRM node in gid 997 is in group $node_group, not video"
groups=" $(cexec "$second" id -nG "$user") "
[[ $groups == *" video "* && $groups != *" empower "* ]] || fail "$user's groups with a DRM node in gid 997:$groups"
pass "a DRM node in host gid 997 (empower here): moved to video, and $user is not in empower"

# --- No key at all: the unit fails and says why, and sshd stays down.
start_container "$nokey"
wait_running "$nokey" 120 >/dev/null || fail "$nokey: systemd did not finish booting"
cexec "$nokey" systemctl is-failed --quiet omanywhere-owner.service || fail "the owner unit did not fail with no key"
log=$(cexec "$nokey" journalctl -b -u omanywhere-owner.service --no-pager)
grep -q 'no authorized key' <<<"$log" ||
  fail "the journal does not say 'no authorized key'"
cexec "$nokey" systemctl is-active --quiet sshd.service && fail "sshd is active although the owner unit failed"
pass "no key: omanywhere-owner.service failed with 'no authorized key', and sshd is not active"

# --- A password in the environment, where docker inspect and the host's
# process list show it: refused, even beside a good key, so the unit fails
# and sshd stays down.
start_container "$envpw" -e OMANYWHERE_AUTHORIZED_KEYS="$(cat "$tmp/id_ed25519.pub")" -e OMANYWHERE_PASSWORD=not-this-way
wait_running "$envpw" 120 >/dev/null || fail "$envpw: systemd did not finish booting"
cexec "$envpw" systemctl is-failed --quiet omanywhere-owner.service ||
  fail "the owner unit did not fail with OMANYWHERE_PASSWORD in the environment"
log=$(cexec "$envpw" journalctl -b -u omanywhere-owner.service --no-pager)
grep -q 'OMANYWHERE_PASSWORD is in the environment' <<<"$log" ||
  fail "the journal does not say the password must not come from the environment: $log"
grep -q '/run/secrets/password' <<<"$log" || fail "the journal does not name /run/secrets/password: $log"
[[ $log != *not-this-way* ]] || fail "the journal shows the password"
cexec "$envpw" systemctl is-active --quiet sshd.service && fail "sshd is active although the owner unit failed"
cleanup "$envpw"
pass "OMANYWHERE_PASSWORD in the environment: refused, naming /run/secrets/password; sshd is not active"

# Bad inputs, run straight in the same container: each fails before it
# changes anything, and names what is wrong.
# owner_fails EXPECTED VAR=VALUE...: the owner script fails, saying EXPECTED.
owner_fails() {
  local expected=$1 out
  shift
  local env=()
  for assignment in "$@"; do env+=(-e "$assignment"); done
  out=$(docker exec "${env[@]}" "$nokey" /usr/lib/omanywhere/owner 2>&1) &&
    fail "the owner script accepted $*"
  [[ $out == *"$expected"* ]] || fail "the owner script failed without saying '$expected': $out"
}
good_key=$(cat "$tmp/id_ed25519.pub")
owner_fails "OMANYWHERE_AUTHORIZED_KEYS line 3 is not an ssh public key" \
  "OMANYWHERE_AUTHORIZED_KEYS=$good_key"$'\n# a comment\nnot a key'
cexec "$nokey" groupadd -g 2000 bob
owner_fails "group bob exists with gid 2000, not 2001" \
  OMANYWHERE_USER=bob OMANYWHERE_UID=2001 "OMANYWHERE_AUTHORIZED_KEYS=$good_key"
owner_fails "OMANYWHERE_PASSWORD is in the environment" \
  OMANYWHERE_PASSWORD= "OMANYWHERE_AUTHORIZED_KEYS=$good_key"
owner_fails "OMANYWHERE_SUDO 'yes' is not nopasswd" \
  OMANYWHERE_SUDO=yes "OMANYWHERE_AUTHORIZED_KEYS=$good_key"
pass "a bad key line is named by number; a group named after the user with another gid is refused; an empty OMANYWHERE_PASSWORD in the environment is refused too; so is OMANYWHERE_SUDO=yes"

echo "owner test passed"
