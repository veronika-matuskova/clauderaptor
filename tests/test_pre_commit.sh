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
for f in x.db x.db-journal x.db-wal x.db-shm x.sqlite x.sqlite-journal x.sqlite-wal x.sqlite-shm \
  x.sqlite3 x.sqlite3-journal x.sqlite3-wal x.sqlite3-shm events.jsonl events-old.jsonl sub/report.html; do
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

# Every staged file is checked, not only the first; only the stats files are named.
echo a > "$R/a.txt"; echo d > "$R/y.db"; echo e > "$R/events.jsonl"
git -C "$R" add a.txt; git -C "$R" add -f y.db events.jsonl
out="$(git -C "$R" commit -m mixed 2>&1)"; rc=$?
assert "mixed: commit blocked" test "$rc" -ne 0
assert_contains "mixed: names y.db" "$out" "  y.db"
assert_contains "mixed: names events.jsonl" "$out" "  events.jsonl"
assert_not_contains "mixed: doesn't name a.txt" "$out" "  a.txt"
git -C "$R" rm -q --cached y.db events.jsonl; rm -f "$R/y.db" "$R/events.jsonl"
git -C "$R" commit -q -m a.txt >/dev/null 2>&1
assert "mixed: a.txt alone commits" test "$(git -C "$R" rev-list --count HEAD)" = 3

# A stats file tracked from before (committed with --no-verify): changing it is refused, removing it is allowed.
echo old > "$R/x.db"; git -C "$R" add -f x.db; git -C "$R" commit -q --no-verify -m "tracked x.db"
echo new > "$R/x.db"; git -C "$R" add x.db
out="$(git -C "$R" commit -m "change x.db" 2>&1)"; rc=$?
assert "tracked x.db: change blocked" test "$rc" -ne 0
assert_contains "tracked x.db: change names it" "$out" "  x.db"
git -C "$R" rm -q --cached x.db
out="$(git -C "$R" commit -m "untrack x.db" 2>&1)"; rc=$?
assert "tracked x.db: removal commits" test "$rc" -eq 0
assert_contains "tracked x.db: removal ran the suite" "$out" "pre-commit: all tests passed"
rm -f "$R/x.db"

# Renaming a file into a stats name is refused.
git -C "$R" mv notes.txt report.html
out="$(git -C "$R" commit -m rename 2>&1)"; rc=$?
assert "rename into report.html: blocked" test "$rc" -ne 0
assert_contains "rename into report.html: names it" "$out" "  report.html"
git -C "$R" reset -q --hard

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
