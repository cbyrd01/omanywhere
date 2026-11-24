#!/bin/bash
# Desktop test: omanywhere-session.service runs Omarchy's Hyprland for the
# owner under uwsm, headless, on the DRM card the container is given, and never
# turns on a connector that belongs to the host.
#
# Usage: tests/desktop.sh (IMAGE defaults to omanywhere:dev).
#
# OMANYWHERE_TEST_DEVICES holds extra docker run arguments, split on
# whitespace, that give the container its DRM card, so one test covers every
# leg:
#   (unset)                    no device: the session is skipped, and says why
#   --device /dev/dri/card0    a vkms card, the CPU-only leg (run in a KVM
#                              guest by tests/vm/run, never on a desktop host)
#   --device nvidia.com/gpu=all  an NVIDIA GPU through CDI (the host needs
#                              nvidia-container-toolkit and its spec in
#                              /var/run/cdi); safe on a desktop host, whose
#                              displays the test checks are never turned on
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib.sh
source "$here/lib.sh"

name=omanywhere-test-desktop-$$
tmp=$(mktemp -d)
trap 'cleanup "$name"; rm -rf "$tmp"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE not found (run make image)"

read -ra devices <<<"${OMANYWHERE_TEST_DEVICES:-}"
user=omarchy
uid=1000

# as_owner CMD...: run CMD in the container as the owner, with the session's
# runtime directory, where Hyprland's and Wayland's sockets are.
as_owner() {
  cexec "$name" runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"
}

# allowed_check KIND FAILED LIST: every unit in FAILED must be in LIST (one per
# line, each with a reason as a comment).
allowed_check() {
  local kind=$1 failed=$2 list=$3 allowed unexpected
  allowed=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list" | sort)
  unexpected=$(comm -13 <(echo "$allowed") <(echo "$failed" | sort) | sed '/^$/d')
  [[ -z $unexpected ]] || fail "$kind units failed that $(basename "$list") does not allow: ${unexpected//$'\n'/ }"
  if [[ -n $failed ]]; then
    pass "failed $kind units are all allowed: ${failed//$'\n'/ }"
  else
    pass "no failed $kind units"
  fi
}

# physical_connectors: the connectors, as Hyprland names them, of every DRM
# card the container can see in sysfs (the host's, all of them) that is not
# virtual: vkms is a platform driver up to Linux 6.14 and a faux device after.
# None may ever be an enabled monitor of the container's Hyprland.
physical_connectors() {
  # shellcheck disable=SC2016 # the script runs, and expands, in the container
  cexec "$name" bash -c '
    shopt -s nullglob
    for connector in /sys/class/drm/card*-*; do
      card=${connector##*/}
      card=${card%%-*}
      driver=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver")")
      bus=$(basename "$(readlink -f "/sys/class/drm/$card/device/subsystem")")
      [[ $driver == vkms || $bus == faux ]] && continue
      echo "${connector##*/"$card"-}"
    done'
}

# hyprctl ARGS...: hyprctl as the owner, on the session's Hyprland. Outside
# the session HYPRLAND_INSTANCE_SIGNATURE isn't set, and hyprctl then needs
# --instance (0: the first in hyprctl instances, the only one here).
hyprctl() {
  as_owner hyprctl --instance 0 "$@"
}

# hypr_json QUERY FILTER: hyprctl -j QUERY as the owner, through jq FILTER.
hypr_json() {
  # shellcheck disable=SC2016 # the script expands its own $1 and $2
  as_owner bash -c 'hyprctl --instance 0 -j "$1" | jq -r "$2"' bash "$1" "$2"
}

# check_no_physical WHEN: Hyprland's enabled monitors include no physical
# connector.
check_no_physical() {
  local monitors enabled_physical
  monitors=$(hypr_json monitors '.[].name') || fail "hyprctl -j monitors failed ($1)"
  enabled_physical=$(comm -12 <(sort <<<"$monitors") <(physical_connectors | sort) | sed '/^$/d')
  [[ -z $enabled_physical ]] || fail "SAFETY: the container's Hyprland enabled a physical connector: ${enabled_physical//$'\n'/ }"
  pass "$1: no physical connector enabled (monitors: ${monitors//$'\n'/ }; physical, all off: $(physical_connectors | paste -sd ' '))"
}

test_key "$tmp"
start_container "$name" -e OMANYWHERE_AUTHORIZED_KEYS="$(cat "$tmp/id_ed25519.pub")" "${devices[@]}"
wait_running "$name" 120 >/dev/null || fail "systemd did not finish booting"
wait_settled "$name" 60 || fail "systemd still had jobs queued 60 s after boot"
cexec "$name" systemctl is-active --quiet omanywhere-owner.service || fail "omanywhere-owner.service is not active"

# Omarchy's display manager has no place here: the session unit replaces it.
[[ $(cexec "$name" systemctl show -P ConditionResult sddm.service) == no ]] ||
  fail "sddm.service was not skipped by its container condition"
pass "sddm.service skipped in the container"

cards=$(cexec "$name" bash -c 'shopt -s nullglob; echo /dev/dri/card*')

# --- No DRM card: the session is skipped, not failed, and the journal says
# which device is missing.
if [[ -z $cards ]]; then
  session=$(cexec "$name" systemctl show -P ActiveState,Result omanywhere-session.service | paste -sd ' ')
  [[ $session == "inactive exec-condition" ]] ||
    fail "with no DRM card, omanywhere-session.service is '$session', not 'inactive exec-condition'"
  log=$(cexec "$name" journalctl -b -u omanywhere-session.service --no-pager)
  grep -qF 'no DRM card (/dev/dri/card*) in the container' <<<"$log" ||
    fail "the journal does not name the missing DRM card: $log"
  pass "no DRM card: omanywhere-session.service skipped; journal: $(grep -oF 'no DRM card' <<<"$log" | head -1) …"
  allowed_check system "$(failed_units "$name")" "$here/allowed-failed.txt"
  echo "desktop test passed (no device)"
  exit 0
fi
pass "DRM card(s) in the container: $cards"

# --- A card: the owner can open the DRM nodes through their own groups,
# whatever PID 1's groups are.
owner_gids=" $(cexec "$name" id -G "$user") "
for node in $(cexec "$name" bash -c 'shopt -s nullglob; echo /dev/dri/card* /dev/dri/renderD*'); do
  gid=$(cexec "$name" stat -c %g "$node")
  ((gid == 0)) && continue
  [[ $owner_gids == *" $gid "* ]] || fail "$user is not in gid $gid, the group of $node (groups:$owner_gids)"
done
pass "$user is in the group of every DRM node (gids:$owner_gids)"

# Hyprland answers as the owner within 60 s with at least one monitor, and
# never with a physical connector.
for ((i = 0; i < 120; i++)); do
  count=$(hypr_json monitors length 2>/dev/null) || count=0
  ((count > 0)) && break
  sleep 0.5
done
if ((count == 0)); then
  cexec "$name" systemctl status --no-pager --lines 30 omanywhere-session.service >&2 || true
  cexec "$name" journalctl -b --no-pager -n 60 _UID="$uid" >&2 || true
  fail "hyprctl -j monitors listed no monitor as $user within 60 s"
fi
pass "hyprctl -j monitors as $user: $count monitor(s) after $((i / 2)) s"
check_no_physical "at start"
cexec "$name" systemctl is-active --quiet omanywhere-session.service || fail "omanywhere-session.service is not active"

# What Hyprland renders with, for the record.
log=$(cexec "$name" bash -c "cat /run/user/$uid/hypr/*/hyprland.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') || log=
grep -E 'Starting backend for|\]: Renderer:' <<<"$log" | sed 's/^.*\] *: //' | sort -u | sed 's/^/info: /' || true

# A screenshot that isn't one flat colour: Omarchy's wallpaper or bar drew.
display=$(cexec "$name" bash -c "cd /run/user/$uid && ls wayland-[0-9]*" 2>/dev/null | grep -v lock | head -1) ||
  fail "no Wayland socket in /run/user/$uid"
for ((i = 0; i < 60; i++)); do
  colours=0
  if as_owner WAYLAND_DISPLAY="$display" grim /tmp/s.png 2>/dev/null; then
    colours=$(cexec "$name" magick /tmp/s.png -format %k info:)
  fi
  ((colours > 1)) && break
  sleep 1
done
((colours > 1)) || fail "grim's screenshot is one flat colour (or grim failed) after 60 s"
size=$(cexec "$name" magick /tmp/s.png -format '%wx%h' info:)
pass "grim: a ${size} PNG with $colours colours"

# Reloading keeps the container's monitor rules: the physical connectors stay
# off, and the desktop keeps a monitor.
hyprctl reload >/dev/null || fail "hyprctl reload failed"
sleep 2
count=$(hypr_json monitors length)
((count > 0)) || fail "no monitor after hyprctl reload"
check_no_physical "after hyprctl reload"
errors=$(hypr_json configerrors '.[]' | sed '/^$/d') || fail "hyprctl -j configerrors failed"
[[ -z $errors ]] || fail "Hyprland reports config errors: $errors"
pass "hyprctl reload: $count monitor(s), no config errors"

# The owner's user manager has no failed unit beyond the allowed ones, nor
# has the system.
cexec "$name" timeout 60 bash -c "until [[ -z \$(systemctl --user -M $user@ list-jobs --no-legend 2>/dev/null) ]]; do sleep 1; done" || true
failed=$(cexec "$name" systemctl --user -M "$user@" list-units --all --plain --no-legend --full --state=failed,auto-restart |
  awk '{ print $1 }')
allowed_check user "$failed" "$here/allowed-failed-user.txt"
allowed_check system "$(failed_units "$name")" "$here/allowed-failed.txt"
check_no_physical "at the end"

# The desktop shuts down cleanly with the container, before docker's SIGKILL.
start=$(date +%s%N)
docker stop -t 10 "$name" >/dev/null
elapsed_ms=$((($(date +%s%N) - start) / 1000000))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
((elapsed_ms < 10000)) || fail "docker stop with the desktop running took ${elapsed_ms} ms"
((exit_code != 137)) || fail "the container was killed (exit 137), not shut down"
pass "docker stop with the desktop running took ${elapsed_ms} ms (exit code $exit_code)"

echo "desktop test passed ($cards)"
