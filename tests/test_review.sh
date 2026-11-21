# shellcheck shell=bash
# Tests for review.sh: a stub `claude` that records how it was called and prints a canned JSON result.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

mkdir -p "$TMP/bin"
export REVIEW_DIR="$TMP/reviews" STUB="$TMP/stub"
mkdir -p "$STUB"
# $STUB/result: the review text to return; $STUB/fail: exit 1 instead. Logs its cwd and args.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
pwd > "$STUB/cwd"; printf '%s\n' "$@" > "$STUB/args"
[ -f "$STUB/fail" ] && exit 1
python3 -I -c 'import json, sys; print(json.dumps({"result": open(sys.argv[1]).read(), "total_cost_usd": 0.42, "duration_ms": 61000}))' "$STUB/result"
EOF
chmod +x "$TMP/bin/claude"
rv() { PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/review.sh" "$@" 2>&1; echo "exit=$?"; }

git init -q -b main "$TMP/repo"
git -C "$TMP/repo" commit -q --allow-empty -m base
W="$TMP/wt"; git -C "$TMP/repo" worktree add -q -b feat/notes "$W"
git -C "$W" commit -q --allow-empty -m change
sha="$(git -C "$W" rev-parse --short HEAD)"; mkdir "$W/sub"

printf 'important: js/a.js:3: the save is not awaited.\nVerdict: needs changes\n' > "$STUB/result"
out="$(rv "$W/sub" high)"   # a folder inside the worktree works too
assert_contains "needs changes -> exit 1" "$out" "exit=1"
assert_contains "prints the findings"     "$out" "the save is not awaited"
assert_contains "prints cost and time"    "$out" "/code-review high, cost \$0.42, 61 s"
assert_contains "runs in the worktree"    "$(cat "$STUB/cwd")" "$W"
args="$(cat "$STUB/args")"
assert_contains "asks for the level and branch" "$args" 'args "high feat/notes"'
assert_contains "headless JSON"           "$args" "--output-format"
assert_contains "no edit tools"           "$args" "Edit,Write,NotebookEdit"
assert "saves the review"                 grep -q "the save is not awaited" "$REVIEW_DIR/feat-notes-$sha.md"

printf 'No findings.\nVerdict: ready\n' > "$STUB/result"
out="$(rv "$W")"
assert_contains "ready -> exit 0"         "$out" "exit=0"
assert_contains "default level medium"    "$(cat "$STUB/args")" 'args "medium feat/notes"'

printf 'Verdict: failed\n' > "$STUB/result"
assert_contains "skill missing -> exit 2" "$(rv "$W")" "exit=2"
printf 'Some text without a verdict\n' > "$STUB/result"
out="$(rv "$W")"
assert_contains "no verdict -> exit 2"    "$out" "no verdict in the review"
touch "$STUB/fail"
assert_contains "claude fails -> exit 2"  "$(rv "$W")" "claude -p failed"
rm "$STUB/fail"

assert_contains "bad level"       "$(rv "$W" max)" "level must be low, medium, high or xhigh"
assert_contains "not a checkout"  "$(rv "$TMP")" "is not a git checkout"
git -C "$W" checkout -q --detach
assert_contains "detached HEAD"   "$(rv "$W")" "is not on a branch"
assert_contains "usage"           "$(rv)" "usage: review.sh"

finish
