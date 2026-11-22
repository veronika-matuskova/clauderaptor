#!/usr/bin/env bash
# Sets up a machine in one go: runs the setup steps in order and stops at the first one that fails.
#
#   scripts/setup/setup.sh                all steps: install tools docker caps
#   scripts/setup/setup.sh tools docker   only the named steps
#   scripts/setup/setup.sh --list         print each step and its script
#
#   install   install.sh        link claude/ into ~/.claude, build settings.json, enable the pre-commit hook
#   tools     setup-tools.sh    gh + login, shellcheck, SSH commit signing (interactive, sudo)
#   docker    setup-docker.sh   Docker Engine in WSL (sudo)
#   caps      setup-caps.sh     let capped.sh cap CPU: delegate the cpu controller to user managers (sudo)
#
# The tools step needs your git identity: git config --global user.name / user.email.
# Run it as your user, not with sudo. Every step is safe to re-run, so after a failure fix the cause and run it again.
# No `set -e`: every step's failure is handled below, so it can say which step failed and how to retry.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ALL=(install tools docker caps)
declare -A SCRIPT=([install]=install.sh [tools]=setup-tools.sh [docker]=setup-docker.sh [caps]=setup-caps.sh)

usage() { sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p}' "$0"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "run this as your user, not as root or with sudo: the steps set up \$HOME and ask for sudo themselves" >&2; exit 1
fi

[ $# -eq 0 ] && set -- "${ALL[@]}"
steps=()
for s in "$@"; do
  case "$s" in
    -h|--help) usage; exit 0 ;;
    --list)    for a in "${ALL[@]}"; do echo "$a ${SCRIPT[$a]}"; done; exit 0 ;;
  esac
  if [ -z "$s" ] || [ -z "${SCRIPT[$s]:-}" ]; then
    echo "unknown step '$s' (steps: ${ALL[*]}; -h for help)" >&2; exit 2
  fi
  [[ " ${steps[*]} " == *" $s "* ]] || steps+=("$s")
done

# Check the tools step's prerequisite up front, so a fresh machine doesn't stop halfway through
if [[ " ${steps[*]} " == *" tools "* ]]; then
  for k in user.name user.email; do
    if [ -z "$(git config --global "$k" 2>/dev/null)" ]; then
      echo "set your git $k first: git config --global $k \"<your ${k#user.} on GitHub>\"" >&2; exit 1
    fi
  done
fi

for s in "${steps[@]}"; do
  echo "=== $s (${SCRIPT[$s]})"
  bash "$DIR/${SCRIPT[$s]}"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "=== $s failed; fix it and re-run: $0 ${steps[*]}" >&2
    exit "$rc"
  fi
done
echo "=== setup done: ${steps[*]}"
