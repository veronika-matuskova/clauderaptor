# shellcheck shell=bash
# Tests for .githooks/pre-commit: commit allowed when tests pass, blocked when they fail.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

R="$TMP/r"; mkdir -p "$R/.githooks" "$R/tests"
cp "$ROOT/.githooks/pre-commit" "$R/.githooks/"
git init -q -b main "$R"; git -C "$R" config core.hooksPath .githooks
printf '#!/usr/bin/env bash\necho "suite output"\nexit 0\n' > "$R/tests/run.sh"; chmod +x "$R/tests/run.sh"

out="$(git -C "$R" commit --allow-empty -m ok 2>&1)"; rc=$?
assert "passing tests: commit made" test "$rc" -eq 0
assert_contains "passing tests: message" "$out" "pre-commit: all tests passed"

printf '#!/usr/bin/env bash\necho "  FAIL something"\nexit 1\n' > "$R/tests/run.sh"
out="$(git -C "$R" commit --allow-empty -m bad 2>&1)"; rc=$?
assert "failing tests: commit blocked" test "$rc" -ne 0
assert_contains "failing tests: shows output" "$out" "FAIL something"
assert_contains "failing tests: message" "$out" "commit aborted"
assert "failing tests: only 1 commit" test "$(git -C "$R" rev-list --count HEAD)" = 1

finish
