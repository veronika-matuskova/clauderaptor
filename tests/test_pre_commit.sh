# shellcheck shell=bash
# Tests for .githooks/pre-commit: commit allowed when tests pass, blocked when they fail
# or when stats data is staged.
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

# Stats data is refused, even when force-added, before the suite runs (its stub leaves a marker when run).
cp "$ROOT/.gitignore" "$R/"
printf '#!/usr/bin/env bash\ntouch ran\nexit 0\n' > "$R/tests/run.sh"
for f in x.db x.sqlite x.sqlite3 x.db-journal x.db-wal events.jsonl events-old.jsonl sub/report.html; do
  mkdir -p "$R/$(dirname "$f")"; echo data > "$R/$f"
  assert "$f: ignored by .gitignore" git -C "$R" check-ignore -q "$f"
  git -C "$R" add -f "$f"
  out="$(git -C "$R" commit -m "add $f" 2>&1)"; rc=$?
  assert "$f: commit blocked" test "$rc" -ne 0
  assert_contains "$f: names the file" "$out" "  $f"
  assert_contains "$f: says why" "$out" "refusing to commit stats data"
  assert "$f: suite not run" test ! -e "$R/ran"
  git -C "$R" rm -q --cached "$f"; rm -f "$R/$f"
done
assert "stats data: only 1 commit" test "$(git -C "$R" rev-list --count HEAD)" = 1

echo hi > "$R/notes.txt"; git -C "$R" add notes.txt
out="$(git -C "$R" commit -m notes 2>&1)"; rc=$?
assert "normal file: commit made" test "$rc" -eq 0
assert_contains "normal file: suite ran" "$out" "pre-commit: all tests passed"
assert "normal file: 2 commits" test "$(git -C "$R" rev-list --count HEAD)" = 2

# The hook exports GIT_INDEX_FILE; tests/lib.sh must drop it, or git in a test repo writes this repo's index.
# (lib.sh doesn't re-run here under capped.sh, which this copy lacks: TESTS_CAPPED, inherited from this test
# file, says it runs in a cap already.)
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
