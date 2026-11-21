# shellcheck shell=bash
# Tiny assert helpers, sourced by tests/test_*.sh. Each test file runs in its own process.
set -uo pipefail
# shellcheck disable=SC2034  # ROOT is used by the test files that source this
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }

# assert <name> <command...>: passes if the command succeeds
assert() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
# assert_contains <name> <haystack> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"; echo "       expected to contain: $3"; printf '       | %s\n' "${2//$'\n'/$'\n       | '}"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1"; echo "       expected NOT to contain: $3"; fi
}

finish() { exit "$FAILS"; }
