#!/bin/bash
# Host test: bin/omanywhere-host on an Arch host, and bin/omanywhere up --gpu
# vkms. It changes the host it runs on (packages, /etc, kernel modules), so it
# runs only as root in tests/vm's KVM guest, over two boots:
#   first   setup picks vkms on a host whose only GPU is QEMU's bochs-display,
#           installs its files and loads vkms, and a second run changes
#           nothing. vkms add makes a card per container; up --gpu vkms runs a
#           desktop on it. When the card comes back under another number (as
#           after a reboot), up makes the container again on the new card.
#   second  after a reboot: the boot unit made both cards again, off the
#           host's seat, and vkms remove takes one away.
# Usage: tests/host.sh first|second (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

phase=${1:-}
[[ $phase == first || $phase == second ]] || fail "usage: tests/host.sh first|second"
((EUID == 0)) || fail "tests/host.sh runs as root"
if [[ ${OMANYWHERE_HOST_TEST:-} != guest ]] || ! systemd-detect-virt -q --vm; then
  fail "tests/host.sh changes the host it runs on: it runs only in tests/vm's guest (make test-host-vm)"
fi

host=$here/../bin/omanywhere-host
cli=$here/../bin/omanywhere
export OMANYWHERE_IMAGE=$IMAGE OMANYWHERE_CONFIG_DIR=/root/omanywhere-config

# node NAME: the /dev/dri node of the vkms card for omanywhere-NAME.
node() {
  local sys
  for sys in "/sys/devices/faux/omanywhere-$1/drm/card"*; do
    [[ -e $sys ]] && echo "/dev/dri/${sys##*/}" && return
  done
  return 1
}

if [[ $phase == first ]]; then
  out=$("$host" setup --yes 2>&1) || fail "setup failed: $out"
  echo "$out"
  [[ $out == *"no GPU in use: vkms"* ]] || fail "setup did not pick vkms on a host with only bochs-display"
  for file in /usr/local/bin/omanywhere-host /etc/udev/rules.d/72-omanywhere-vkms.rules \
    /etc/modules-load.d/omanywhere-vkms.conf /etc/systemd/system/omanywhere-vkms@.service; do
    [[ -f $file ]] || fail "setup did not install $file"
  done
  [[ -d /sys/module/vkms && -d /sys/kernel/config/vkms ]] || fail "vkms, with its configfs, is not loaded"
  out=$("$host" setup --yes 2>&1) || fail "setup failed the second time: $out"
  [[ $out == *"nothing to change"* ]] || fail "setup changed things the second time: $out"
  pass "setup: vkms, its udev rule, modules-load file and boot unit; a second run changes nothing"

  out=$("$host" vkms add 'Bad_Name' 2>&1) && fail "vkms add took a bad name: $out"
  "$host" vkms add desk
  first=$(node desk) || fail "vkms add desk made no card"
  pass "vkms add desk: $first"

  test_key /root
  "$cli" up desk --gpu vkms --key /root/id_ed25519.pub
  out=$("$cli" status desk)
  echo "$out"
  grep -Eq "^desktop +running on $first," <<<"$out" || fail "the desktop is not running on $first"
  pass "up desk --gpu vkms: the desktop runs on $first"

  # The card comes back under another number: another container's card takes
  # its old one first.
  docker stop omanywhere-desk >/dev/null
  systemctl stop omanywhere-vkms@desk.service
  [[ ! -e /sys/kernel/config/vkms/omanywhere-desk ]] || fail "stopping omanywhere-vkms@desk left its card"
  "$host" vkms add other
  systemctl start omanywhere-vkms@desk.service
  second=$(node desk) || fail "omanywhere-vkms@desk made no card when started again"
  [[ $second != "$first" ]] || fail "the card did not move (still $first): the test can't check up"
  out=$("$cli" up desk 2>&1) || fail "up after the card moved failed: $out"
  echo "$out"
  [[ $out == *"vkms card is now $second"* ]] || fail "up did not say the card moved to $second"
  out=$("$cli" status desk)
  grep -Eq "^desktop +running on $second," <<<"$out" || fail "the desktop is not running on $second after up: $out"
  pass "the card moved from $first to $second: up made the container again on it"
  out=$("$host" vkms remove desk 2>&1) && fail "vkms remove took the card of a running container: $out"
  [[ -e /sys/kernel/config/vkms/omanywhere-desk ]] || fail "a refused vkms remove still removed the card"
  "$cli" down desk
  echo "host test (first boot) passed"
  exit 0
fi

# second: the boot unit made both cards again.
for name in desk other; do
  systemctl -q is-active "omanywhere-vkms@$name.service" || fail "omanywhere-vkms@$name is not active after the reboot"
  card=$(node "$name") || fail "no vkms card for $name after the reboot"
  seat=$(udevadm info -q property -n "$card" | sed -n 's/^ID_SEAT=//p')
  [[ $seat == omanywhere ]] || fail "$card is on seat '${seat:-seat0}', not off the host's seat"
done
pass "after the reboot: omanywhere-vkms@desk and @other made their cards, off the host's seat"
out=$("$host" setup --yes 2>&1) || fail "setup failed after the reboot: $out"
[[ $out == *"nothing to change"* ]] || fail "setup changed things after the reboot: $out"
"$host" vkms remove other
[[ ! -e /sys/kernel/config/vkms/omanywhere-other ]] || fail "vkms remove other left its card"
! systemctl -q is-enabled omanywhere-vkms@other.service || fail "vkms remove other left its unit enabled"
pass "vkms remove other: the card and its unit are gone"
echo "host test (second boot) passed"
