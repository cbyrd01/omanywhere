#!/bin/bash
# Helpers for the container tests. Source it; it runs nothing by itself.
#
# Containers and volumes are always named omanywhere-test-*: the host is shared
# with other work, so these helpers refuse to start or remove anything else.

IMAGE=${IMAGE:-omanywhere:dev}

# How systemd runs as PID 1 under Docker 29 with no privilege: a private cgroup
# namespace made writable (only the container's own subtree), and tmpfs where
# systemd expects one. The image sets container=docker and STOPSIGNAL itself.
# --tty gives systemd a console (/dev/console), as systemd's container
# interface asks: without one, systemd sends its own output and the units'
# console output to /dev/null, and docker logs is empty. With it, docker logs
# shows the boot and the desktop session's skip or refusal messages (and the
# stock console getty's login prompt, which Task 5 deals with).
RUN_FLAGS=(
  --tty
  --cgroupns=private
  --security-opt writable-cgroups=true
  --tmpfs /run
  --tmpfs /run/lock
  --tmpfs /tmp
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok: $*"
}

check_name() {
  [[ $1 == omanywhere-test-* ]] || fail "refusing to touch '$1': test containers and volumes are named omanywhere-test-*"
}

# cexec NAME CMD...: run CMD as root in the container.
cexec() {
  local name=$1
  shift
  docker exec "$name" "$@"
}

# start_container NAME [docker-args...]: boot $IMAGE detached with the run flags.
start_container() {
  local name=$1
  shift
  check_name "$name"
  docker run -d --name "$name" "${RUN_FLAGS[@]}" "$@" "$IMAGE" >/dev/null
}

# container_ip NAME: the container's address on its Docker network.
container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

# test_key DIR: make a throwaway ed25519 key pair, DIR/id_ed25519{,.pub}.
test_key() {
  ssh-keygen -q -t ed25519 -N '' -C omanywhere-test -f "$1/id_ed25519"
}

# wait_running NAME TIMEOUT: wait until systemd has finished booting and print
# the state it reports then. Succeeds when that is running or degraded.
wait_running() {
  local name=$1 timeout=$2 state
  # --wait blocks until the boot transaction is done, but needs systemd's bus,
  # which isn't up the moment the container starts: retry until it answers.
  # shellcheck disable=SC2016 # the script expands its own $1, in its own shell
  state=$(timeout "$timeout" bash -c '
    while :; do
      state=$(docker exec "$1" systemctl is-system-running --wait 2>/dev/null)
      [[ -n $state && $state != offline && $state != unknown ]] && { echo "$state"; exit; }
      [[ $(docker inspect -f "{{.State.Running}}" "$1" 2>/dev/null) == true ]] || exit 1
      sleep 0.5
    done' bash "$name") || true
  case $state in
    running | degraded)
      echo "$state"
      return 0
      ;;
  esac
  echo "systemd in $name did not finish booting in ${timeout}s (last state: ${state:-none})" >&2
  if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then
    cexec "$name" systemctl list-jobs --no-pager >&2 || true
  else
    echo "container $name is not running" >&2
    docker logs --tail 30 "$name" >&2 || true
  fi
  return 1
}

# wait_settled NAME TIMEOUT: wait until systemd's job queue has stayed empty for
# 3 s (six polls in a row, 0.5 s apart). Units started on demand after boot (over
# D-Bus, or by a restart) queue jobs of their own after the boot transaction.
wait_settled() {
  # shellcheck disable=SC2016 # the script runs, and expands, in the container
  cexec "$1" timeout "$2" bash -c '
    quiet=0
    while ((quiet < 6)); do
      if [[ -z $(systemctl list-jobs --no-legend) ]]; then ((++quiet)); else quiet=0; fi
      sleep 0.5
    done' || {
    echo "jobs in $1 kept being queued for $2 s:" >&2
    cexec "$1" systemctl list-jobs --no-pager >&2 || true
    return 1
  }
}

# failed_units NAME: the units that failed, and the units caught in a restart
# loop. A unit with Restart= sits in auto-restart between attempts and never
# shows as failed if its RestartSec outlasts the start rate limit.
failed_units() {
  cexec "$1" systemctl list-units --all --plain --no-legend --full --state=failed,auto-restart |
    awk '{ print $1 }'
}

# check_failed NAME LIST: every failed (or restart-looping) unit in container
# NAME must be in LIST, one unit per line with its reason as a comment. Notes
# the units LIST allows that did not fail, and shows the status of any it
# doesn't allow before failing.
check_failed() {
  local name=$1 list=$2 failed allowed unexpected unit
  failed=$(failed_units "$name" | sort)
  allowed=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$list" | sort)
  # An empty list still echoes one blank line, which comm would report.
  unexpected=$(comm -13 <(echo "$allowed") <(echo "$failed") | sed '/^$/d')
  comm -23 <(echo "$allowed") <(echo "$failed") | sed -e '/^$/d' -e 's/^/note: allowed to fail but did not: /'
  if [[ -n $unexpected ]]; then
    while read -r unit; do
      echo "--- $unit" >&2
      cexec "$name" systemctl status --no-pager --lines 10 "$unit" >&2 || true
    done <<<"$unexpected"
    fail "units failed that tests/$(basename "$list") does not allow: ${unexpected//$'\n'/ }"
  fi
  if [[ -n $failed ]]; then
    pass "failed units are all allowed ($(grep -c . <<<"$failed"): ${failed//$'\n'/ })"
  else
    pass "no failed units"
  fi
}

# cleanup NAME...: remove each container that exists.
cleanup() {
  local name
  for name in "$@"; do
    check_name "$name"
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}

# remove_volumes NAME...: remove each volume that exists.
remove_volumes() {
  local name
  for name in "$@"; do
    check_name "$name"
    docker volume rm -f "$name" >/dev/null 2>&1 || true
  done
}
