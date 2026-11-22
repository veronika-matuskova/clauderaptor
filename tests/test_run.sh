# shellcheck shell=bash
# Tests for tests/run.sh, on a copy with stand-in test files: a file passes only if it exits 0 and got to
# lib.sh's finish() with no failures.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

R="$TMP/r"; mkdir -p "$R/tests" "$TMP/bin"
cp "$ROOT/tests/run.sh" "$R/tests/"
printf '#!/usr/bin/env bash\n' > "$TMP/bin/shellcheck"; chmod +x "$TMP/bin/shellcheck"
# file <name> <body>: a stand-in test file; run: run.sh on the copy, then its exit code.
file() { printf '%s\n' "$2" > "$R/tests/test_$1.sh"; }
run() { (cd "$R" && PATH="$TMP/bin:$PATH" bash tests/run.sh 2>&1); echo "exit=$?"; }

file pass 'echo "  finished: 0 failed"'
out="$(run)"
assert_contains "finished: passes"          "$out" "ALL PASSED"
assert_contains "finished: exit 0"          "$out" "exit=0"
assert_contains "shows the file's output"   "$out" "  finished: 0 failed"

file early 'exit 0'
assert_contains "stopped before finish(): fails" "$(run)" "exit=1"
rm "$R/tests/test_early.sh"
file failed 'echo "  finished: 1 failed"; exit 0'
assert_contains "a failure, then exit 0: fails" "$(run)" "exit=1"
rm "$R/tests/test_failed.sh"
file exit1 'echo "  finished: 0 failed"; exit 1'
assert_contains "exit 1: fails"             "$(run)" "exit=1"

finish
