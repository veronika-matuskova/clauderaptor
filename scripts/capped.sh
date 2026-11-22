#!/usr/bin/env bash
# Runs a command with a cap on its processes and memory, so that a runaway (a fork bomb, a leak) is stopped
# inside the cap instead of filling the machine (WSL has 8 GB):
#   capped.sh <command...>
# The command runs in a systemd user scope, which every process it starts stays in, setsid or not.
# TasksMax=$CAP_TASKS (default 2000) caps its processes and threads, MemoryMax=$CAP_MEMORY (default 4G) its
# memory, with no swap, so that it can't push the rest of the machine out to swap. At the cap, forks fail and
# the kernel kills processes of the scope only. When the command ends, or capped.sh is stopped, whatever is
# still running in the scope is stopped too (TERM, then KILL after 10 s).
# The command gets CAPPED=1: capped.sh inside it runs its command as it is, since a scope of its own would be
# outside this one's cap. Without a systemd user instance (e.g. in CI) the command runs uncapped, with a warning.
# Exit code: the command's; 2 if no command was given.
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: capped.sh <command...>" >&2; exit 2; }
if [ -n "${CAPPED:-}" ]; then exec "$@"; fi
export CAPPED=1
if ! systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  echo "capped: no systemd user instance, so $1 runs without a cap" >&2
  exec "$@"
fi
unit="capped-$$-$RANDOM"
trap 'systemctl --user stop "$unit.scope" >/dev/null 2>&1' EXIT
systemd-run --user --scope --quiet --collect --unit="$unit" -p TasksMax="${CAP_TASKS:-2000}" \
  -p MemoryMax="${CAP_MEMORY:-4G}" -p MemorySwapMax=0 -p TimeoutStopSec=10 -- "$@"
