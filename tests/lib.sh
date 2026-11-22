# shellcheck shell=bash
# Tiny assert helpers, sourced by tests/test_*.sh. Each test file runs in its own process.
set -uo pipefail
# Each test file runs under scripts/capped.sh, also when run by itself (e.g. a mutation loop), so that a script
# under test that starts processes without end is stopped by the cap instead of filling the machine. Started
# again once, with bash's -x and -v: TESTS_CAPPED marks the re-run, so it never loops. A test file that a test
# runs inherits it, and runs inside this cap.
if [ -z "${TESTS_CAPPED:-}" ] && [ "${BASH_SOURCE[1]:-}" = "$0" ]; then
  opts="${-//[^xv]/}"
  TESTS_CAPPED=1 exec "$(dirname "${BASH_SOURCE[0]}")/../scripts/capped.sh" bash ${opts:+"-$opts"} "$0" "$@"
fi
# The scripts under test run capped.sh's command as it is: this file's cap covers them, and tests start no
# real scopes.
export CAP_OFF=1
# Run from a git hook (pre-commit), git exports GIT_INDEX_FILE, GIT_DIR, ...; drop them so git in a test
# repo never reads or writes this repo's index.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
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

# finish: the last line, which tests/run.sh checks: a file that stops early, or never runs, has none.
finish() { echo "  finished: $FAILS failed"; exit "$FAILS"; }
