#!/bin/bash
# Boot test: the image is sealed, boots systemd with Omarchy installed, and
# stops cleanly. Usage: tests/boot.sh (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

name=omanywhere-test-boot-$$
trap 'cleanup "$name"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"

# The image as shipped, before anything boots it: no per-machine identity, no
# pacman keyring and no package cache.
docker run --rm --network none --entrypoint /bin/bash "$IMAGE" -c '
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
wait_running "$name" 120 || fail "systemd did not reach running or degraded in 120 s"
wait_settled "$name" 60 || fail "systemd still had jobs queued 60 s after boot"
pass "systemd is $(cexec "$name" systemctl is-system-running || true)"

cexec "$name" pacman -Q omarchy >/dev/null 2>&1 || fail "omarchy is not installed"
pass "$(cexec "$name" pacman -Q omarchy 2>/dev/null)"

# Omarchy 4.5 is built for Hyprland 0.56, which Omarchy's stable mirror serves.
# Anything else means the build drifted back to Arch's live mirrors.
hyprland=$(cexec "$name" pacman -Q hyprland 2>/dev/null) || fail "hyprland is not installed"
[[ $hyprland == "hyprland 0.56."* ]] || fail "expected Hyprland 0.56.x from Omarchy's stable mirror, got: $hyprland"
pass "$hyprland"

# omarchy-provision-hardware retires the build manifest on the first boot.
cexec "$name" test ! -e /var/lib/omarchy/image/target || fail "the image-target manifest was not retired at boot"
cexec "$name" test -f /var/lib/omarchy/image/target.booted || fail "no retired manifest (target.booted)"
pass "image-target manifest retired to target.booted"

# Every failed (or restart-looping) unit must be in the allow list, which
# carries a reason for each.
mapfile -t allowed < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$here/allowed-failed.txt")
mapfile -t failed < <(failed_units "$name")
unexpected=()
for unit in "${failed[@]}"; do
  [[ " ${allowed[*]} " == *" $unit "* ]] || unexpected+=("$unit")
done
for unit in "${allowed[@]}"; do
  [[ " ${failed[*]} " == *" $unit "* ]] || echo "note: $unit is allowed to fail but did not"
done
if ((${#unexpected[@]})); then
  for unit in "${unexpected[@]}"; do
    echo "--- $unit" >&2
    cexec "$name" systemctl status --no-pager --lines 10 "$unit" >&2 || true
  done
  fail "units failed that tests/allowed-failed.txt does not allow: ${unexpected[*]}"
fi
pass "failed units are all allowed (${#failed[@]}: ${failed[*]:-none})"

# A clean systemd shutdown, not the SIGKILL docker sends after the timeout.
start=$(date +%s%N)
docker stop -t 10 "$name" >/dev/null
elapsed_ms=$((($(date +%s%N) - start) / 1000000))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
((elapsed_ms < 10000)) || fail "docker stop took ${elapsed_ms} ms"
((exit_code != 137)) || fail "the container was killed (exit 137), not shut down"
pass "docker stop took ${elapsed_ms} ms (exit code $exit_code)"

echo "boot test passed"
