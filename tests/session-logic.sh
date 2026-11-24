#!/bin/bash
# Unit test of the desktop session's decisions (package/omanywhere/session),
# run on the host with no container and no device: how it classifies a card
# from sysfs (against a made-up sysfs tree), and when it refuses a GPU's DRM
# master. Nothing here opens a DRM node. Usage: tests/session-logic.sh.
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

echo "session logic test passed"
