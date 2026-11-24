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
nvidia_gbm=$tmp/gbm/nvidia-drm_gbm.so
mkdir -p "$drm_class" "${nvidia_gbm%/*}"
touch "$nvidia_gbm"

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
# NVIDIA's GBM backend comes only with its CDI spec: a card passed as plain
# /dev/dri has none, and Hyprland can't allocate on it.
rm "$nvidia_gbm"
expect "nvidia without the GBM backend" "$(classify "$drm_class/card1")" \
  "ignored nvidia no GBM backend ($nvidia_gbm), which only NVIDIA's CDI spec adds: use --gpu nvidia (--device nvidia.com/gpu=all, from nvidia-container-toolkit); a Debian or Ubuntu host's spec puts it elsewhere and isn't supported yet"
echo Y >"$nvidia_modeset"
expect "nvidia, no connectors, modeset=Y, without the GBM backend" "$(classify "$drm_class/card2")" \
  "ignored nvidia no GBM backend ($nvidia_gbm), which only NVIDIA's CDI spec adds: use --gpu nvidia (--device nvidia.com/gpu=all, from nvidia-container-toolkit); a Debian or Ubuntu host's spec puts it elsewhere and isn't supported yet"
expect "amdgpu needs no NVIDIA GBM backend" "$(classify "$drm_class/card0")" "gpu amdgpu"
touch "$nvidia_gbm"
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

# How gliff-server captures and encodes over ssh: on the GPU only when the
# chosen card has a render node of its own in the container, on the CPU (with
# frames read back into shared memory) otherwise. gliff's default, gpu,
# errors rather than falls back without one.
expect "gliff: a GPU with its render node" "$(gliff_env gpu /dev/dri/renderD128)" "GLIFF_VIDEO=gpu GLIFF_CAPTURE=auto"
expect "gliff: a GPU without a render node" "$(gliff_env gpu '')" "GLIFF_VIDEO=cpu GLIFF_CAPTURE=shm"
expect "gliff: a virtual card" "$(gliff_env virtual '')" "GLIFF_VIDEO=cpu GLIFF_CAPTURE=shm"

# render_node finds the card's own render node in the container by device
# number. /dev/null stands in for a render node: a character device whose
# number the made-up sysfs gives.
dri_dir=$tmp/dri
mkdir -p "$dri_dir" "$tmp/devices/pci/0000:01:00.0/drm/renderD128"
echo 1:3 >"$tmp/devices/pci/0000:01:00.0/drm/renderD128/dev"
expect "render node: none in the container" "$(render_node "$drm_class/card0")" ""
touch "$dri_dir/renderD128"
expect "render node: not a device" "$(render_node "$drm_class/card0")" ""
ln -sfn /dev/zero "$dri_dir/renderD128"
expect "render node: another device's number" "$(render_node "$drm_class/card0")" ""
ln -sfn /dev/null "$dri_dir/renderD128"
expect "render node: the card's own" "$(render_node "$drm_class/card0")" "$dri_dir/renderD128"
expect "render node: a card without one" "$(render_node "$drm_class/card1")" ""

# The monitor rules for a GPU: the card's connectors at start, and any name
# the kernel gives a connector, are turned off; Hyprland's own outputs,
# HEADLESS-N and gliff's gliff-N, never are. prepare also writes the gliff
# environment sshd gives ssh sessions, for every kind of card, and has sshd
# read it again (reload_sshd).
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"
env_file=$tmp/session.env
rules=$tmp/container.lua
sshd_env=$tmp/sshd/gliff.conf
card_sysfs() {
  echo "$drm_class/${1##*/}"
}
# A stand-in that notes the reload: this runs on the test host, whose sshd
# must never be touched.
reload_sshd() {
  echo reload >>"$tmp/reloads"
}
# prepared CARD KIND DRIVER: run prepare for that choice; print the SetEnv
# line it wrote for sshd, once it has asked sshd to reload, and only then.
prepared() {
  rm -f "$sshd_env" "$tmp/reloads"
  printf '%s\n' "OMANYWHERE_CARD=/dev/dri/$1" "OMANYWHERE_CARD_KIND=$2" "OMANYWHERE_CARD_DRIVER=$3" >"$env_file"
  (prepare) 2>/dev/null || fail "prepare failed on $1 ($2, $3)"
  [[ $(cat "$tmp/reloads" 2>/dev/null) == reload ]] || fail "prepare on $1 did not reload sshd once"
  [[ $(stat -c %a "${sshd_env%/*}") == 755 ]] || fail "prepare left ${sshd_env%/*} other than 0755"
  grep -v '^#' "$sshd_env"
}
expect "sshd's gliff environment, virtual card" "$(prepared card3 virtual vkms)" "SetEnv GLIFF_VIDEO=cpu GLIFF_CAPTURE=shm"
expect "sshd's gliff environment, GPU with a render node" "$(prepared card0 gpu amdgpu)" "SetEnv GLIFF_VIDEO=gpu GLIFF_CAPTURE=auto"
# Last: the GPU whose monitor rules the Lua below runs.
expect "sshd's gliff environment, GPU without a render node" "$(prepared card1 gpu nvidia)" "SetEnv GLIFF_VIDEO=cpu GLIFF_CAPTURE=shm"
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
