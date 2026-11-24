#!/bin/bash
# The docker run flags every Omanywhere container gets, from bin/omanywhere
# and the tests (tests/lib.sh) alike. Source it; it only sets run_flags.
# docs/usage.md ("The run flags") says what each one is for.
# shellcheck disable=SC2034 # used by the scripts that source it
run_flags=(
  --tty
  --cgroupns=private
  --security-opt writable-cgroups=true
  --tmpfs /run
  --tmpfs /run/lock
  --tmpfs /tmp
  --tmpfs /run/secrets:mode=0700
)
