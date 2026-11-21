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

# The hook exports GIT_INDEX_FILE; tests/lib.sh must drop it, or git in a test repo writes this repo's index.
cp "$ROOT/tests/lib.sh" "$R/tests/"
cat > "$R/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook=${GIT_INDEX_FILE-unset}"
source tests/lib.sh
echo "lib=${GIT_INDEX_FILE-unset}"
exit 1
EOF
out="$(git -C "$R" commit --allow-empty -m env 2>&1)"
assert "hook: git sets GIT_INDEX_FILE" grep -qE '^hook=[./]' <<<"$out"
assert_contains "hook: lib.sh unsets GIT_INDEX_FILE" "$out" "lib=unset"

finish
