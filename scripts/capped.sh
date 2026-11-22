#!/usr/bin/env bash
# Runs a command with a cap on its processes and memory, so that a runaway (a fork bomb, a leak) is stopped
# inside the cap instead of filling the machine (WSL has 8 GB):
#   capped.sh <command...>
# The command runs in a systemd user scope of its own, which every process it starts stays in, setsid or not.
# TasksMax=$CAP_TASKS (default 2000) caps its processes and threads, MemoryMax=$CAP_MEMORY (default 4G) its
# memory, with no swap, so that it can't push the rest of the machine out to swap. At the cap, forks fail and
# the kernel kills processes of the scope only.
# Each call gets a scope of its own, also inside another capped command (e.g. a mutation loop in a capped
# review session): a runaway in it fills only its own cap, so the caller keeps running and can report it.
# All the scopes are in capped.slice, which caps them together: TasksMax=$CAP_TOTAL_TASKS (default 4000),
# MemoryMax=$CAP_TOTAL_MEMORY (default 5G), no swap. So capped commands that call capped.sh again, even
# without end, stay inside that cap, and so do several capped commands at the same time.
# When capped.sh ends, also by a SIGKILL, whatever is still running in the scope is stopped (TERM, then KILL
# after 10 s): a watcher outside its process group stops the scope if capped.sh dies without cleaning up.
# CAP_OFF=1 runs the command as it is (the tests set it: each test file already runs under a cap of its own).
# Without a systemd user instance that can apply the caps (e.g. in CI), the command runs uncapped, with a warning.
# Exit code: the command's; 2 if no command was given.
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: capped.sh <command...>" >&2; exit 2; }
if [ -n "${CAP_OFF:-}" ]; then exec "$@"; fi
caps=(-p TasksMax="${CAP_TASKS:-2000}" -p MemoryMax="${CAP_MEMORY:-4G}" -p MemorySwapMax=0 -p TimeoutStopSec=10)
total=(TasksMax="${CAP_TOTAL_TASKS:-4000}" MemoryMax="${CAP_TOTAL_MEMORY:-5G}" MemorySwapMax=0)
# The check sets the overall cap and applies the same caps, so a cap systemd can't set means no cap rather
# than no command.
if ! systemctl --user set-property --runtime capped.slice "${total[@]}" >/dev/null 2>&1 ||
   ! systemd-run --user --scope --quiet --slice=capped.slice "${caps[@]}" -- true >/dev/null 2>&1; then
  echo "capped: no systemd user instance that can apply the caps, so '${*:1:2}' runs without a cap" >&2
  exec "$@"
fi
unit="capped-$$-$RANDOM"
trap 'systemctl --user stop "$unit.scope" >/dev/null 2>&1' EXIT
# shellcheck disable=SC2016  # $1 and $2 expand in the watcher
setsid bash -c 'tail --pid="$1" -f /dev/null; systemctl --user stop "$2.scope"' _ "$$" "$unit" \
  </dev/null >/dev/null 2>&1 &
systemd-run --user --scope --quiet --collect --slice=capped.slice --unit="$unit" "${caps[@]}" -- "$@"
