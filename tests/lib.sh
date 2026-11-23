#!/bin/bash
# Helpers for the container tests. Source it; it runs nothing by itself.
#
# Containers are always named omanywhere-test-*: the host is shared with other
# work, so these helpers refuse to start or remove anything else.

IMAGE=${IMAGE:-omanywhere:dev}

# How systemd runs as PID 1 under Docker 29 with no privilege: a private cgroup
# namespace made writable (only the container's own subtree), and tmpfs where
# systemd expects one. The image sets container=docker and STOPSIGNAL itself.
RUN_FLAGS=(
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
  [[ $1 == omanywhere-test-* ]] || fail "refusing to touch container '$1': test containers are named omanywhere-test-*"
}

# start_container NAME [docker-args...]: boot $IMAGE detached with the run flags.
start_container() {
  local name=$1
  shift
  check_name "$name"
  docker run -d --name "$name" "${RUN_FLAGS[@]}" "$@" "$IMAGE" >/dev/null
}

# wait_running NAME TIMEOUT: wait until systemd has finished booting, which
# `systemctl is-system-running` reports as running or degraded.
wait_running() {
  local name=$1 timeout=$2 state="" deadline
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) != true ]]; then
      echo "container $name is not running" >&2
      docker logs --tail 30 "$name" >&2 || true
      return 1
    fi
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null) || true
    case $state in
      running | degraded) return 0 ;;
    esac
    sleep 1
  done
  echo "systemd in $name did not finish booting in ${timeout}s (last state: ${state:-none})" >&2
  docker exec "$name" systemctl list-jobs --no-pager >&2 || true
  return 1
}

# wait_settled NAME TIMEOUT: wait until systemd's job queue has stayed empty
# for 3 s. Units started on demand after boot (over D-Bus, or by a restart)
# queue jobs of their own after the boot transaction is done.
wait_settled() {
  local name=$1 timeout=$2 deadline quiet=0
  deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if [[ -z $(docker exec "$name" systemctl list-jobs --no-legend 2>/dev/null) ]]; then
      ((++quiet >= 3)) && return 0
    else
      quiet=0
    fi
    sleep 1
  done
  echo "jobs in $name kept being queued for ${timeout}s:" >&2
  docker exec "$name" systemctl list-jobs --no-pager >&2 || true
  return 1
}

# failed_units NAME: the units that failed, and the units caught in a restart
# loop. A unit with Restart= sits in auto-restart between attempts and never
# shows as failed if its RestartSec outlasts the start rate limit.
failed_units() {
  docker exec "$1" systemctl list-units --all --plain --no-legend --full |
    awk '$3 == "failed" || $4 == "auto-restart" { print $1 }'
}

# cexec NAME CMD...: run CMD as root in the container.
cexec() {
  local name=$1
  shift
  docker exec "$name" "$@"
}

# cleanup NAME: remove the container if it exists.
cleanup() {
  check_name "$1"
  docker rm -f "$1" >/dev/null 2>&1 || true
}
