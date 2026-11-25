#!/bin/bash
# Boot test: the image is sealed, boots systemd with Omarchy installed to
# `running` with no failed unit, and stops cleanly. Usage: tests/boot.sh
# (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

name=omanywhere-test-boot-$$
seal=$name-seal
check_name "$seal"
tmp=$(mktemp -d)
trap 'cleanup "$name" "$seal"; rm -rf "$tmp"' EXIT

# The fingerprint of Omarchy's package signing key (image/keys/README.md).
omarchy_fpr=40DFB630FF42BCFFB047046CF0134EE680CAC571

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"

# The image as shipped, before anything boots it: no per-machine identity, no
# pacman keyring, no package cache, and no hardware steps queued for the first
# boot. The machine-id lives in the state volume, through a symlink.
docker run --rm --name "$seal" --network none --entrypoint /bin/bash "$IMAGE" -c '
  set -e
  shopt -s nullglob
  keys=(/etc/ssh/ssh_host_* /var/lib/omanywhere/ssh/ssh_host_*)
  if (( ${#keys[@]} )); then echo "ssh host keys in the image: ${keys[*]}"; exit 1; fi
  if [[ $(readlink /etc/machine-id) != /var/lib/omanywhere/machine-id ]]; then
    echo "/etc/machine-id is not a symlink to /var/lib/omanywhere/machine-id"; exit 1
  fi
  if [[ ! -f /etc/machine-id || -s /etc/machine-id ]]; then echo "the machine-id is missing or not empty"; exit 1; fi
  if [[ -e /etc/pacman.d/gnupg ]]; then echo "a pacman keyring is in the image"; exit 1; fi
  pkgs=(/var/cache/pacman/pkg/*)
  if (( ${#pkgs[@]} )); then echo "${#pkgs[@]} files in the package cache"; exit 1; fi
  if [[ -s /var/lib/omarchy/image/deferred-steps ]]; then echo "hardware steps are queued for the first boot"; exit 1; fi
' || fail "the image is not sealed"
pass "sealed: no ssh host keys, empty machine-id, no keyring, no package cache, no hardware steps queued"

# omanywhere-owner.service fails without a key (tests/owner.sh checks that).
test_key "$tmp"
start_container "$name" -e OMANYWHERE_AUTHORIZED_KEYS="$(cat "$tmp/id_ed25519.pub")"
state=$(wait_running "$name" 120) || fail "systemd did not reach running or degraded in 120 s"
wait_settled "$name" 60 || fail "systemd still had jobs queued 60 s after boot"
pass "systemd finished booting: $state"

# Omarchy 4.5 is built for Hyprland 0.56, which Omarchy's stable mirror serves.
# Anything else means the build drifted back to Arch's live mirrors.
packages=$(cexec "$name" pacman -Q omarchy hyprland 2>/dev/null) || fail "omarchy or hyprland is not installed: $packages"
{ read -r _ omarchy_version && read -r _ hyprland_version; } <<<"$packages"
[[ $hyprland_version == 0.56.* ]] || fail "expected Hyprland 0.56.x from Omarchy's stable mirror, got $hyprland_version"
pass "omarchy $omarchy_version, hyprland $hyprland_version"

# omarchy-provision-hardware retires the build manifest on the first boot,
# then makes the pacman keyring the image asked for, finds no hardware step
# queued, and is done.
cexec "$name" test ! -e /var/lib/omarchy/image/target -a -f /var/lib/omarchy/image/target.booted ||
  fail "the image-target manifest was not retired to target.booted at boot"
pass "image-target manifest retired to target.booted"
cexec "$name" test ! -e /var/lib/omarchy/image/deferred-steps ||
  fail "omarchy-provision-hardware did not finish: the deferred-steps queue is still there"
pass "deferred hardware setup finished with nothing to run"
cexec "$name" test ! -e /var/lib/omarchy/image/pacman-keyring ||
  fail "the pacman keyring request is still pending (no keyring made at first boot)"
cexec "$name" pacman-key --list-keys "$omarchy_fpr" >/dev/null 2>&1 ||
  fail "the first-boot pacman keyring lacks Omarchy's key $omarchy_fpr"
pass "first-boot pacman keyring made, with Omarchy's key"

# The desktop: Omarchy's display manager has no place here, the session unit
# replaces it, and with no DRM card (none is given here) the session is
# skipped, not failed, and says which device is missing in the journal and in
# docker logs. tests/desktop.sh runs it on a card.
[[ $(cexec "$name" systemctl show -P ConditionResult sddm.service) == no ]] ||
  fail "sddm.service was not skipped by its container condition"
pass "sddm.service skipped in the container"
session=$(cexec "$name" systemctl show -P ActiveState,Result omanywhere-session.service | paste -sd ' ')
[[ $session == "inactive exec-condition" ]] ||
  fail "with no DRM card, omanywhere-session.service is '$session', not 'inactive exec-condition'"
missing='omanywhere-session: no DRM card (/dev/dri/card*) in the container'
cexec "$name" journalctl -b -u omanywhere-session.service --no-pager | grep -F "$missing" >/dev/null ||
  fail "the journal does not say the DRM card is missing"
docker logs "$name" 2>&1 | grep -F "$missing" >/dev/null || fail "docker logs does not say the DRM card is missing"
pass "no DRM card: omanywhere-session.service skipped, and the journal and docker logs say why"

# The image's HEALTHCHECK: with no card there is no desktop, and that passes;
# sshd down fails it. Docker runs it every 5 s in the start period.
out=$(cexec "$name" /usr/lib/omanywhere/health) || fail "the healthcheck failed with no card: $out"
[[ $out == "ok: no DRM card, so no desktop" ]] || fail "the healthcheck said: $out"
health=$(wait_healthy "$name" 30) || fail "docker reports the container $health, not healthy, 30 s after boot"
cexec "$name" systemctl stop sshd.service
out=$(cexec "$name" /usr/lib/omanywhere/health) && fail "the healthcheck passed with sshd stopped: $out"
[[ $out == "sshd is inactive" ]] || fail "the healthcheck said, with sshd stopped: $out"
cexec "$name" systemctl start sshd.service
cexec "$name" systemd-run -q --wait --unit=omanywhere-test-fail.service false || true
out=$(cexec "$name" /usr/lib/omanywhere/health) && fail "the healthcheck passed with a failed unit: $out"
[[ $out == "systemd is degraded: omanywhere-test-fail.service failed" ]] ||
  fail "the healthcheck said, with a failed unit: $out"
cexec "$name" systemctl reset-failed omanywhere-test-fail.service
pass "healthcheck: healthy with no card, fails when sshd stops or a unit fails, naming it"

# journald forwards warnings, not info, to the console, which is docker logs.
cexec "$name" logger -t omanywhere-test -p user.warning "forwarded warning $$"
cexec "$name" logger -t omanywhere-test -p user.info "kept info $$"
for _ in {1..20}; do
  logs=$(docker logs "$name" 2>&1)
  [[ $logs == *"forwarded warning $$"* ]] && break
  sleep 0.5
done
[[ $logs == *"forwarded warning $$"* ]] || fail "a journal warning is not in docker logs"
[[ $logs != *"kept info $$"* ]] || fail "a journal info line is in docker logs"
pass "docker logs carries the journal's warnings, not its info lines"

# The owner script's warnings and failures carry journald's <4> or <3>
# prefix under systemd, so they reach docker logs too. In a unit without the
# container's environment it finds no key and fails.
cexec "$name" systemd-run -q --wait --unit=omanywhere-test-owner.service /usr/lib/omanywhere/owner &&
  fail "the owner script succeeded with no key and no password"
cexec "$name" systemctl reset-failed omanywhere-test-owner.service
for _ in {1..20}; do
  logs=$(docker logs "$name" 2>&1)
  [[ $logs == *"no authorized key and no password"* ]] && break
  sleep 0.5
done
[[ $logs == *"no authorized key and no password"* ]] || fail "the owner's failure is not in docker logs"
[[ $logs != *"<3>"* ]] || fail "docker logs shows journald's <3> prefix"
pass "docker logs carries the owner's failures"

# Every failed (or restart-looping) unit must be in the allow list, which
# carries a reason for each.
check_failed "$name" "$here/allowed-failed.txt"
# A clean boot is `running`; only a failed unit may leave it degraded.
[[ $state == running || -n $(failed_units "$name") ]] || fail "no unit failed, yet systemd is $state, not running"

# A clean systemd shutdown, not the SIGKILL docker sends after the timeout.
start=$(date +%s%N)
docker stop -t 10 "$name" >/dev/null
elapsed_ms=$((($(date +%s%N) - start) / 1000000))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
((elapsed_ms < 10000)) || fail "docker stop took ${elapsed_ms} ms"
((exit_code != 137)) || fail "the container was killed (exit 137), not shut down"
pass "docker stop took ${elapsed_ms} ms (exit code $exit_code)"

echo "boot test passed"
