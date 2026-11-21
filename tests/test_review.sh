# shellcheck shell=bash
# Tests for review.sh: a stub `claude` that records how it was called and prints a canned JSON result.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

mkdir -p "$TMP/bin"
unset REVIEW_TIMEOUT
export REVIEW_DIR="$TMP/reviews" STUB="$TMP/stub"
mkdir -p "$STUB"
# $STUB/result: the review text to return; $STUB/fail: exit 1 instead; $STUB/hook: a script to run first.
# Logs its cwd and args (and removes neither, so a test can tell whether it ran).
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
pwd > "$STUB/cwd"; printf '%s\n' "$@" > "$STUB/args"; readlink /proc/$$/fd/0 > "$STUB/stdin"
[ -f "$STUB/fail" ] && exit 1
[ -f "$STUB/hook" ] && bash "$STUB/hook"
python3 -I -c 'import json, sys; print(json.dumps({"result": open(sys.argv[1]).read(), "total_cost_usd": 0.42, "duration_ms": 61000}))' "$STUB/result"
EOF
# timeout: logs the limit it was given ($STUB/timeout), then runs the real one.
REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT
cat > "$TMP/bin/timeout" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2 $3" > "$STUB/timeout"
exec "$REAL_TIMEOUT" "$@"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/timeout"
rv() { rm -f "$STUB/args"; PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/review.sh" "$@" 2>&1; echo "exit=$?"; }
# commit: a new commit on the worktree's branch, so the next review isn't a cached one
commit() { git -C "$W" commit -q --allow-empty -m "change $1"; sha="$(git -C "$W" rev-parse --short=12 HEAD)"; }

git init -q -b main "$TMP/repo"
echo base > "$TMP/repo/tracked.txt"; git -C "$TMP/repo" add -A; git -C "$TMP/repo" commit -q -m base
W="$TMP/wt"; git -C "$TMP/repo" worktree add -q -b feat/notes "$W"
mkdir "$W/sub"; commit 1

printf 'important: js/a.js:3: the save is not awaited.\nVerdict: needs changes\n' > "$STUB/result"
out="$(rv "$W/sub" high)"   # a folder inside the worktree works too
assert_contains "needs changes -> exit 1" "$out" "exit=1"
assert_contains "prints the findings"     "$out" "the save is not awaited"
assert_contains "prints cost and time"    "$out" "/code-review high, cost \$0.42, 61 s"
assert_contains "names the saved file"    "$out" "(saved to $REVIEW_DIR/feat-notes-$sha-high.md)"
assert_contains "runs in the worktree"    "$(cat "$STUB/cwd")" "$W"
args="$(cat "$STUB/args")"
assert_contains "asks for the level and branch" "$args" 'args "high feat/notes"'
assert_contains "headless JSON"           "$args" "--output-format"
assert_contains "no edit tools"           "$args" "Edit,Write,NotebookEdit"
assert_not_contains "loads the repo's CLAUDE.md (default setting sources)" "$args" "--setting-sources"
echo x | rv "$W" high >/dev/null
assert_contains "no stdin, even from a pipe" "$(cat "$STUB/stdin")" "/dev/null"
assert "saves the review"                 grep -q "the save is not awaited" "$REVIEW_DIR/feat-notes-$sha-high.md"
out="$(rv "$W" high)"
assert "needs changes is reviewed again"  test -f "$STUB/args"

printf 'No findings.\nVerdict: ready\n' > "$STUB/result"
out="$(rv "$W")"
assert_contains "ready -> exit 0"         "$out" "exit=0"
assert_contains "default level medium"    "$(cat "$STUB/args")" 'args "medium feat/notes"'
out="$(rv "$W")"
assert_contains "ready commit not reviewed again" "$out" "already reviewed as ready"
assert "no second session"                test ! -f "$STUB/args"
assert_contains "cached: still exit 0"    "$out" "exit=0"
out="$(rv "$W" high)"
assert "another level is a new review"    test -f "$STUB/args"
out="$(rv "$W" low)"
assert_contains "a ready higher level counts" "$out" "already reviewed as ready"

# The verdict is read from the last verdict line, with markdown and case ignored.
commit 2; printf 'No findings.\n**Verdict: Ready.**\n' > "$STUB/result"
assert_contains "markdown verdict -> exit 0" "$(rv "$W")" "exit=0"
commit 3; printf 'Rule: end with Verdict: ready if clean.\n1. important: x\nVerdict: needs changes\n' > "$STUB/result"
assert_contains "last verdict wins"       "$(rv "$W")" "exit=1"
assert "a quoted ready is not cached"     test -z "$(rv "$W" | grep 'already reviewed')"

commit 4; printf 'Verdict: failed\n' > "$STUB/result"
assert_contains "skill missing -> exit 2" "$(rv "$W")" "exit=2"
commit 5; printf 'Some text without a verdict\n' > "$STUB/result"
assert_contains "no verdict -> exit 2"    "$(rv "$W")" "no verdict in the review"
commit 6; : > "$STUB/result"
out="$(rv "$W")"
assert_contains "empty result -> no verdict" "$out" "no verdict in the review"
assert "empty result: cost line once"     test "$(grep -cF "cost \$0.42" "$REVIEW_DIR/feat-notes-$sha-medium.md")" = 1
touch "$STUB/fail"
assert_contains "claude fails -> exit 2"  "$(rv "$W")" "claude -p failed"
rm "$STUB/fail"

# A review fails, even with "ready", if the worktree changes or either checkout moves meanwhile;
# editing files in the main checkout is fine. A review that hangs is stopped.
printf 'Verdict: ready\n' > "$STUB/result"
commit 7; echo "echo x >> '$W/new.txt'" > "$STUB/hook"
out="$(rv "$W")"
assert_contains "changed worktree -> exit 2" "$out" "exit=2"
assert_contains "says what changed"       "$out" "moved or changed during the review"
assert "not saved as ready"               test ! -f "$REVIEW_DIR/feat-notes-$sha-medium.md"
rm "$W/new.txt"; commit 8; echo "git -C '$TMP/repo' checkout -q -b other" > "$STUB/hook"
assert_contains "main checkout switched -> exit 2" "$(rv "$W")" "moved or changed during the review"
git -C "$TMP/repo" checkout -q main; commit 9; echo "git -C '$W' switch -q -c other-wt" > "$STUB/hook"
assert_contains "worktree switched branch -> exit 2" "$(rv "$W")" "moved or changed during the review"
git -C "$W" switch -q feat/notes; echo "echo x >> '$TMP/repo/tracked.txt'" > "$STUB/hook"
assert_contains "edits in the main checkout are fine" "$(rv "$W")" "exit=0"
git -C "$TMP/repo" checkout -q -- tracked.txt
commit 10; echo "sleep 5" > "$STUB/hook"
out="$(REVIEW_TIMEOUT=1 rv "$W")"
assert_contains "hung review stopped"     "$out" "took longer than 1s"
assert_contains "hung review -> exit 2"   "$out" "exit=2"
rm "$STUB/hook"

# A review longer than one command-line argument may be (128 KiB) is still read.
commit 11; python3 -I -c 'print("x" * 200000); print("Verdict: ready")' > "$STUB/result"
assert_contains "long review read"        "$(rv "$W")" "exit=0"

# Without REVIEW_DIR, reviews go where pr-queue.sh keeps them.
commit 12; out="$(REVIEW_DIR='' PR_QUEUE_DIR="$TMP/queue" rv "$W")"
assert "default folder is \$PR_QUEUE_DIR/reviews" test -f "$TMP/queue/reviews/feat-notes-$sha-medium.md"

# --- the test review (--tests): the change, the instructions file, a scratch folder removed afterwards ---
commit 13; printf 'Reviewed: feat/notes.\n1. [must-fix] [mutation] a.js:3: no test fails.\nVerdict: needs changes\n' > "$STUB/result"
cat > "$STUB/hook" <<'EOF'
s="$(sed -n 's/^- Scratch folder (yours, removed afterwards): //p' "$STUB/args")"
if [ -d "$s" ]; then echo "$s" > "$STUB/scratch"; mkdir "$s/copy"; fi
EOF
out="$(rv --tests "$W/sub")"
assert_contains "tests: needs changes -> exit 1" "$out" "exit=1"
assert_contains "tests: prints the findings"  "$out" "no test fails"
assert_contains "tests: names the saved file" "$out" "(saved to $REVIEW_DIR/feat-notes-$sha-tests.md)"
assert_contains "tests: title, cost and time" "$(head -1 "$REVIEW_DIR/feat-notes-$sha-tests.md")" \
  "# Test review of feat/notes at $sha (cost \$0.42, 61 s)"
assert_contains "tests: runs in the worktree" "$(cat "$STUB/cwd")" "$W"
args="$(cat "$STUB/args")"; mb="$(git -C "$W" merge-base main HEAD)"
assert_contains "tests: names the change"     "$args" "git diff ${mb:0:12} $sha (against main)"
assert_contains "tests: gives the instructions" "$args" "Mutation: break the code on purpose"
assert_contains "tests: gives the lock command" "$args" "$ROOT/scripts/pr-queue.sh lock <command>"
assert_contains "tests: no edit tools"        "$args" "Edit,Write,NotebookEdit"
assert "tests: got a scratch folder"          test -s "$STUB/scratch"
assert "tests: scratch folder removed after"  test ! -e "$(cat "$STUB/scratch")"
assert_contains "tests: stopped after 1800 s" "$(cat "$STUB/timeout")" "-k 30 1800"
rm "$STUB/hook"; printf 'No findings.\nVerdict: ready\n' > "$STUB/result"
assert_contains "tests: ready -> exit 0"      "$(rv --tests "$W")" "exit=0"
assert "tests: needs changes is reviewed again" test -f "$STUB/args"
out="$(rv --tests "$W")"
assert_contains "tests: ready commit not reviewed again" "$out" "already reviewed as ready"
assert "tests: no second session"             test ! -f "$STUB/args"
rv "$W" >/dev/null
assert "tests: a ready test review is not a ready code review" test -f "$STUB/args"
commit 14; git -C "$TMP/repo" update-ref refs/remotes/origin/main main
rv --tests "$W" >/dev/null
assert_contains "tests: against origin/main when there is one" "$(cat "$STUB/args")" "(against origin/main)"
git -C "$TMP/repo" update-ref -d refs/remotes/origin/main
commit 15; echo "echo x >> '$W/new.txt'" > "$STUB/hook"
assert_contains "tests: changed worktree -> exit 2" "$(rv --tests "$W")" "moved or changed during the review"
rm "$W/new.txt" "$STUB/hook"
commit 16; mkdir "$TMP/bare"; cp "$ROOT/scripts/review.sh" "$TMP/bare/"
out="$(PATH="$TMP/bin:$PATH" bash "$TMP/bare/review.sh" --tests "$W" 2>&1)"
assert_contains "tests: instructions file missing" "$out" "missing $TMP/bare/review-tests.md"
assert_contains "tests: needs a worktree"     "$(rv --tests)" "usage: review.sh"
assert_contains "tests: takes no level"       "$(rv --tests "$W" high)" "usage: review.sh"
git -C "$TMP/repo" checkout -q --orphan lonely; git -C "$TMP/repo" commit -q -m lonely
out="$(rv --tests "$TMP/repo")"
assert_contains "tests: no common history with main" "$out" "lonely has no common history with main"
assert_contains "tests: no common history -> exit 2" "$out" "exit=2"
git -C "$TMP/repo" checkout -q main

# The code review leaves the quality of tests to the test review only when asked to.
commit 17; REVIEW_SKIP_TESTS=1 rv "$W" >/dev/null
assert_contains "REVIEW_SKIP_TESTS=1: tests left out" "$(cat "$STUB/args")" "a separate test review covers them"
commit 18; rv "$W" >/dev/null
assert_not_contains "by default: tests kept"  "$(cat "$STUB/args")" "a separate test review"

# --- the suite audit (--suite): any checkout; the whole report saved, the summary printed ---
M="$TMP/repo"; msha="$(git -C "$M" rev-parse --short=12 HEAD)"
printf '%s\n' "Suite audit: repo at $msha: 2 test files, 9 tests. Tests run: tests/run.sh, passed" \
  "Counts: mutation 1, missing 0, empty 1, duplicate 0, not atomic 0, rule 0" "Not checked: e2e" "" \
  "1. [mutation] a.js:3: no test fails." "2. [empty] t.sh:9: asserts nothing." > "$STUB/result"
echo "echo x >> '$M/tracked.txt'" > "$STUB/hook"
out="$(rv --suite "$M")"
assert_contains "suite: exit 0, edits in the checkout are fine" "$out" "exit=0"
assert_contains "suite: prints the summary line" "$out" "Suite audit: repo at $msha: 2 test files"
assert_contains "suite: prints the counts"    "$out" "Counts: mutation 1, missing 0, empty 1"
assert_contains "suite: prints what it didn't check" "$out" "Not checked: e2e"
assert_not_contains "suite: not the findings" "$out" "asserts nothing"
assert_contains "suite: names the file"       "$out" "(saved to $REVIEW_DIR/repo-suite-$msha.md)"
assert "suite: every finding saved"           grep -q "asserts nothing" "$REVIEW_DIR/repo-suite-$msha.md"
assert_contains "suite: the task"             "$(cat "$STUB/args")" "Audit the whole test suite of one repo"
assert_contains "suite: the instructions"     "$(cat "$STUB/args")" "## Suite audit"
assert_contains "suite: stopped after 3600 s" "$(cat "$STUB/timeout")" "-k 30 3600"
git -C "$M" checkout -q -- tracked.txt
echo "git -C '$M' commit -q --allow-empty -m moved" > "$STUB/hook"
assert_contains "suite: a moved HEAD -> exit 2" "$(rv --suite "$M")" "moved or changed during the review"
rm "$STUB/hook"; printf 'I looked around.\n' > "$STUB/result"
out="$(rv --suite "$M")"
assert_contains "suite: no Counts line -> exit 2" "$out" "exit=2"
assert_contains "suite: says why"             "$out" "no Counts line in the audit"
git init -q "$TMP/empty"
out="$(rv --suite "$TMP/empty")"
assert_contains "suite: a repo with no commits" "$out" "has no commits"
assert_contains "suite: no commits -> exit 2" "$out" "exit=2"

printf 'Counts: mutation 0, missing 0, empty 0, duplicate 0, not atomic 0, rule 0\nVerdict: ready\n' > "$STUB/result"
assert_contains "bad level"       "$(rv "$W" max)" "level must be low, medium, high or xhigh"
assert_contains "not a checkout"  "$(rv "$TMP")" "is not a git checkout"
git -C "$W" checkout -q --detach
assert_contains "detached HEAD"   "$(rv "$W")" "is not on a branch"
assert_contains "detached HEAD: --tests too" "$(rv --tests "$W")" "is not on a branch"
assert_contains "detached HEAD: an audit is fine" "$(rv --suite "$W")" "exit=0"
assert_contains "usage"           "$(rv)" "usage: review.sh"

finish
