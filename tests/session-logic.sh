#!/bin/bash
# Unit test of the desktop session's decisions (package/omanywhere/session),
# with no device: how it classifies a card from sysfs (against a made-up sysfs
# tree), when it refuses a GPU's DRM master, and which outputs the monitor
# rules it writes for a GPU turn off (run with the image's Lua, against a
# stand-in for Hyprland's hl API). Nothing here opens a DRM node.
# Usage: tests/session-logic.sh (IMAGE defaults to omanywhere:dev).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"
# shellcheck source=package/omanywhere/session
source "$here/../package/omanywhere/session"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
drm_class=$tmp/class/drm
nvidia_modeset=$tmp/nvidia_drm_modeset
mkdir -p "$drm_class"

# card NAME DEVICE_DIR DRIVER BUS [CONNECTOR...]: a card in the made-up sysfs,
# its device at DEVICE_DIR (bound to DRIVER on BUS), with these connectors.
card() {
  local name=$1 device=$tmp/devices/$2 driver=$3 bus=$4 connector
  shift 4
  mkdir -p "$device/drm/$name" "$tmp/drivers/$driver" "$tmp/bus/$bus"
  ln -sfn "$tmp/drivers/$driver" "$device/driver"
  ln -sfn "$tmp/bus/$bus" "$device/subsystem"
  ln -sfn "$device" "$device/drm/$name/device"
  ln -sfn "$device/drm/$name" "$drm_class/$name"
  for connector; do
    mkdir -p "$device/drm/$name/$name-$connector"
    ln -sfn "$device/drm/$name/$name-$connector" "$drm_class/$name-$connector"
  done
}

# expect WHAT GOT WANT
expect() {
  [[ $2 == "$3" ]] || fail "$1: got '$2', want '$3'"
  pass "$1: $2"
}

card card0 pci/0000:01:00.0 amdgpu pci DP-1 HDMI-A-1
card card1 pci/0000:02:00.0 nvidia pci DP-1 DP-2 DP-3
card card2 pci/0000:03:00.0 nvidia pci
card card3 faux/vkms faux_driver faux Virtual-1 Writeback-1
card card4 platform/vkms vkms platform Virtual-1
card card5 platform/simple-framebuffer.0 simple-framebuffer platform Unknown-1
card card6 faux/vgem faux_driver faux
card card7 pci/0000:04:00.0 virtio_gpu pci Virtual-1
card card8 platform/display-subsystem msm_drm platform

expect "amdgpu with connectors" "$(classify "$drm_class/card0")" "gpu amdgpu"
expect "connector names" "$(connectors "$drm_class/card1" | paste -sd ' ')" "DP-1 DP-2 DP-3"
expect "nvidia with connectors" "$(classify "$drm_class/card1")" "gpu nvidia"
echo N >"$nvidia_modeset"
expect "nvidia, no connectors, modeset=N" "$(classify "$drm_class/card2")" \
  "ignored nvidia no KMS: the host loads nvidia_drm with modeset=N"
echo Y >"$nvidia_modeset"
expect "nvidia, no connectors, modeset=Y" "$(classify "$drm_class/card2")" "gpu nvidia"
expect "vkms as a faux device (Linux 6.15 on)" "$(classify "$drm_class/card3")" "virtual vkms"
expect "vkms as a platform device" "$(classify "$drm_class/card4")" "virtual vkms"
expect "simpledrm" "$(classify "$drm_class/card5")" "ignored simple-framebuffer a firmware framebuffer"
expect "a faux card without connectors (vgem)" "$(classify "$drm_class/card6")" \
  "ignored faux_driver a faux device without connectors"
expect "a GPU of a vendor no list names" "$(classify "$drm_class/card7")" "gpu virtio_gpu"
expect "a card without connectors" "$(classify "$drm_class/card8")" \
  "ignored msm_drm no KMS: the card has no connectors"

# The DRM master ruling: a GPU nobody is master of is refused unless allowed;
# a virtual card is never probed.
expect "GPU, master held by the host" "$(verdict gpu held '')" use
expect "GPU, no master" "$(verdict gpu free '')" refuse
expect "GPU, no master, a wrong value" "$(verdict gpu free yes)" refuse
expect "GPU, no master, OMANYWHERE_DRM_MASTER=allow" "$(verdict gpu free allow)" use
expect "virtual card" "$(verdict virtual n/a '')" use

# guard_master, with probe_master stood in for (it answers $probe): it probes
# a GPU only, and refuses one nobody is master of unless allowed, saying why.
probe=
probe_master() {
  [[ $probe != never ]] || return 1 # a probe that must not happen fails
  echo "$probe"
}
# guarded KIND PROBE ALLOW: guard_master's exit status and message.
guarded() {
  local status=0 message
  message=$(probe=$2 OMANYWHERE_DRM_MASTER=$3 guard_master /dev/dri/card9 "$1" 2>&1) || status=$?
  echo "$status ${message:-(nothing)}"
}
refusal="omanywhere-session: no display server holds DRM master on /dev/dri/card9; refusing to take it (it would blank the host's outputs). On a host with no display of its own, set OMANYWHERE_DRM_MASTER=allow"
expect "guard: GPU, master held" "$(guarded gpu held '')" "0 (nothing)"
expect "guard: GPU, no master" "$(guarded gpu free '')" "1 $refusal"
expect "guard: GPU, no master, allowed" "$(guarded gpu free allow)" \
  "0 omanywhere-session: no display server holds DRM master on /dev/dri/card9; taking it, as OMANYWHERE_DRM_MASTER=allow says"
expect "guard: virtual card, never probed" "$(guarded virtual never '')" "0 (nothing)"

# The monitor rules for a GPU: the card's connectors at start, and any name
# the kernel gives a connector, are turned off; Hyprland's own outputs,
# HEADLESS-N and gliff's gliff-N, never are.
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"
env_file=$tmp/session.env
rules=$tmp/container.lua
printf '%s\n' OMANYWHERE_CARD=/dev/dri/card1 OMANYWHERE_CARD_KIND=gpu OMANYWHERE_CARD_DRIVER=nvidia >"$env_file"
card_sysfs() {
  echo "$drm_class/card1"
}
(prepare) 2>/dev/null || fail "prepare failed"
cat >"$tmp/before.lua" <<'LUA'
local off, handlers = {}, {}
hl = {
  monitor = function(rule) if rule.disabled then off[rule.output] = true end end,
  get_monitors = function()
    -- At a reload: one of the card's, one plugged in since, and Hyprland's.
    return { { name = "DP-2" }, { name = "DP-9" }, { name = "HEADLESS-1" }, { name = "gliff-1525562" } }
  end,
  on = function(event, handler) handlers[event] = handler end,
  exec_cmd = function() end,
}
LUA
cat >"$tmp/after.lua" <<'LUA'
for _, name in ipairs({ "DP-4", "HDMI-A-2", "eDP-1", "DVI-I-1", "DIN-1", "Virtual-3", "Writeback-1",
  "HEADLESS-2", "gliff-7", "gliff-test", "DP", "DPX-1", "DP-1a", "HDMI-A-" }) do
  handlers["monitor.added"]({ name = name })
end
assert(handlers["hyprland.start"], "no headless output made at start")
local names = {}
for name in pairs(off) do names[#names + 1] = name end
table.sort(names)
print(table.concat(names, " "))
LUA
turned_off=$(cat "$tmp/before.lua" "$rules" "$tmp/after.lua" |
  docker run --rm -i --network none --entrypoint lua "$IMAGE" -) || fail "the monitor rules don't run in Lua"
expect "outputs the GPU rules turn off" "$turned_off" "DIN-1 DP-1 DP-2 DP-3 DP-4 DP-9 DVI-I-1 HDMI-A-2 Virtual-3 Writeback-1 eDP-1"

echo "session logic test passed"
