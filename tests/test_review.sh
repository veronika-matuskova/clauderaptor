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
pwd > "$STUB/cwd"; printf '%s\n' "$@" > "$STUB/args"
[ -f "$STUB/fail" ] && exit 1
[ -f "$STUB/hook" ] && bash "$STUB/hook"
python3 -I -c 'import json, sys; print(json.dumps({"result": open(sys.argv[1]).read(), "total_cost_usd": 0.42, "duration_ms": 61000}))' "$STUB/result"
EOF
chmod +x "$TMP/bin/claude"
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
assert_contains "user settings only"      "$args" "--setting-sources"$'\n'"user"
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
git -C "$TMP/repo" checkout -q main; commit 9; echo "echo x >> '$TMP/repo/tracked.txt'" > "$STUB/hook"
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

assert_contains "bad level"       "$(rv "$W" max)" "level must be low, medium, high or xhigh"
assert_contains "not a checkout"  "$(rv "$TMP")" "is not a git checkout"
git -C "$W" checkout -q --detach
assert_contains "detached HEAD"   "$(rv "$W")" "is not on a branch"
assert_contains "usage"           "$(rv)" "usage: review.sh"

finish
