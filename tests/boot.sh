#!/bin/bash
# Boot test: the image is sealed, boots systemd with Omarchy installed, and
# stops cleanly. Usage: tests/boot.sh (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

name=omanywhere-test-boot-$$
seal=$name-seal
check_name "$seal"
trap 'cleanup "$name" "$seal"' EXIT

# The fingerprint of Omarchy's package signing key (image/keys/README.md).
omarchy_fpr=40DFB630FF42BCFFB047046CF0134EE680CAC571

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"

# The image as shipped, before anything boots it: no per-machine identity, no
# pacman keyring and no package cache.
docker run --rm --name "$seal" --network none --entrypoint /bin/bash "$IMAGE" -c '
  set -e
  shopt -s nullglob
  keys=(/etc/ssh/ssh_host_*)
  if (( ${#keys[@]} )); then echo "ssh host keys in the image: ${keys[*]}"; exit 1; fi
  if [[ ! -f /etc/machine-id || -s /etc/machine-id ]]; then echo "/etc/machine-id is missing or not empty"; exit 1; fi
  if [[ -e /etc/pacman.d/gnupg ]]; then echo "a pacman keyring is in the image"; exit 1; fi
  pkgs=(/var/cache/pacman/pkg/*)
  if (( ${#pkgs[@]} )); then echo "${#pkgs[@]} files in the package cache"; exit 1; fi
' || fail "the image is not sealed"
pass "sealed: no ssh host keys, empty machine-id, no keyring, no package cache"

start_container "$name"
state=$(wait_running "$name" 120) || fail "systemd did not reach running or degraded in 120 s"
wait_settled "$name" 60 || fail "systemd still had jobs queued 60 s after boot"
pass "systemd is $state"

# Omarchy 4.5 is built for Hyprland 0.56, which Omarchy's stable mirror serves.
# Anything else means the build drifted back to Arch's live mirrors.
packages=$(cexec "$name" pacman -Q omarchy hyprland 2>/dev/null) || fail "omarchy or hyprland is not installed: $packages"
{ read -r _ omarchy_version && read -r _ hyprland_version; } <<<"$packages"
[[ $hyprland_version == 0.56.* ]] || fail "expected Hyprland 0.56.x from Omarchy's stable mirror, got $hyprland_version"
pass "omarchy $omarchy_version, hyprland $hyprland_version"

# omarchy-provision-hardware retires the build manifest on the first boot,
# then makes the pacman keyring the image asked for.
cexec "$name" test ! -e /var/lib/omarchy/image/target -a -f /var/lib/omarchy/image/target.booted ||
  fail "the image-target manifest was not retired to target.booted at boot"
pass "image-target manifest retired to target.booted"
# Checked on its own: omarchy-provision-hardware.service is allowed to fail
# (below), and a failed keyring exits 75 like a failed hardware step.
cexec "$name" test ! -e /var/lib/omarchy/image/pacman-keyring ||
  fail "the pacman keyring request is still pending (no keyring made at first boot)"
cexec "$name" pacman-key --list-keys "$omarchy_fpr" >/dev/null 2>&1 ||
  fail "the first-boot pacman keyring lacks Omarchy's key $omarchy_fpr"
pass "first-boot pacman keyring made, with Omarchy's key"

# Every failed (or restart-looping) unit must be in the allow list, which
# carries a reason for each.
failed=$(failed_units "$name" | sort)
allowed=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$here/allowed-failed.txt" | sort)
# An empty list still echoes one blank line, which comm would report.
unexpected=$(comm -13 <(echo "$allowed") <(echo "$failed") | sed '/^$/d')
comm -23 <(echo "$allowed") <(echo "$failed") | sed -e '/^$/d' -e 's/^/note: allowed to fail but did not: /'
if [[ -n $unexpected ]]; then
  while read -r unit; do
    echo "--- $unit" >&2
    cexec "$name" systemctl status --no-pager --lines 10 "$unit" >&2 || true
  done <<<"$unexpected"
  fail "units failed that tests/allowed-failed.txt does not allow: ${unexpected//$'\n'/ }"
fi
pass "failed units are all allowed ($(grep -c . <<<"$failed"): ${failed//$'\n'/ })"

# A clean systemd shutdown, not the SIGKILL docker sends after the timeout.
start=$(date +%s%N)
docker stop -t 10 "$name" >/dev/null
elapsed_ms=$((($(date +%s%N) - start) / 1000000))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
((elapsed_ms < 10000)) || fail "docker stop took ${elapsed_ms} ms"
((exit_code != 137)) || fail "the container was killed (exit 137), not shut down"
pass "docker stop took ${elapsed_ms} ms (exit code $exit_code)"

echo "boot test passed"
