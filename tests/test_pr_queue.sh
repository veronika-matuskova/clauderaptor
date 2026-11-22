# shellcheck shell=bash
# Tests for pr-queue.sh: a local bare origin, worktrees, and stub gh/node/npm (no network).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export TQ="$TMP/t" PR_QUEUE_DIR="$TMP/state" PR_QUEUE_CHECKS_WAIT=0 PR_QUEUE_POLL=0.2
# review.sh reads the user's rules: give it a stand-in for ~/.claude, which the tests never touch.
export CLAUDE_CONFIG_DIR="$TMP/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
echo "Stand-in user rule." > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
unset REVIEW_DIR REVIEW_TIMEOUT PR_QUEUE_REVIEW   # reviews go to $PR_QUEUE_DIR/reviews, not a real folder
mkdir -p "$TQ/bin" "$TQ/passed"
Q() { PATH="$TQ/bin:$PATH" bash "$ROOT/scripts/pr-queue.sh" "$@" </dev/null 2>&1; }

# gh: one PR, number 7. Its state, branch and body live in files under $TQ; its head is the branch on origin.
# $TQ/checks_seq: check results to report, one per call (the last repeats): pass, fail, pending, cancel, none.
# $TQ/head_lag: report a stale head this many times. $TQ/on_checks: a script run once, at the first checks call.
cat > "$TQ/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TQ/gh.log"
origin="$(dirname "$TQ")/origin.git"
case "$1 $2" in
  "pr view")
    [ -f "$TQ/pr_state" ] || exit 1
    case "$5" in
      number,state) [ "$(cat "$TQ/pr_state")" = OPEN ] && echo 7 ;;
      number) echo 7 ;;
      body) cat "$TQ/pr_body" ;;
      state) cat "$TQ/pr_state" ;;
      mergeCommit) echo 1234567890abcdef ;;
      headRefOid)
        n="$(cat "$TQ/head_lag" 2>/dev/null || echo 0)"
        if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$TQ/head_lag"; echo stale; exit 0; fi
        git --git-dir="$origin" rev-parse "refs/heads/$(cat "$TQ/pr_branch")" ;;
    esac ;;
  "pr create")
    shift 2; title=""; body=""; head=""
    while [ $# -gt 0 ]; do
      case "$1" in --title) title="$2" ;; --body-file) body="$2" ;; --head) head="$2" ;; esac; shift
    done
    [ -f "$body" ] || { echo "open $body: no such file or directory" >&2; exit 1; }
    echo "gh-create $title" >> "$TQ/created.log"
    cp "$body" "$TQ/pr_body"; echo OPEN > "$TQ/pr_state"; echo "$head" > "$TQ/pr_branch" ;;
  "pr edit") cp "$5" "$TQ/pr_body" ;;
  "pr checks")
    [ -f "$TQ/on_checks" ] && { bash "$TQ/on_checks"; rm -f "$TQ/on_checks"; }
    s=pass
    if [ -s "$TQ/checks_seq" ]; then
      s="$(head -1 "$TQ/checks_seq")"; [ "$(wc -l < "$TQ/checks_seq")" -gt 1 ] && sed -i 1d "$TQ/checks_seq"
    fi
    case "$s" in
      none) echo "no checks reported on the branch" >&2; exit 1 ;;
      pending) printf 'pass\tLint\npending\tChecks\n'; exit 8 ;;
      pass) printf 'pass\tLint\npass\tChecks\n' ;;
      *) printf 'pass\tLint\n%s\tChecks\n' "$s"; exit 1 ;;
    esac ;;
  "pr merge")
    [ -f "$TQ/merge_fail" ] && exit 1
    want="$(sed -n 's/.*--match-head-commit \([^ ]*\).*/\1/p' <<<"$*")"
    [ "$want" = "$(git --git-dir="$origin" rev-parse "refs/heads/$(cat "$TQ/pr_branch")")" ] || exit 1
    echo MERGED > "$TQ/pr_state" ;;
esac
EOF
# node: only `node scripts/e2e-gate.mjs pr-line`: prints the pass line when HEAD has a recorded pass, else fails.
cat > "$TQ/bin/node" <<'EOF'
#!/usr/bin/env bash
sha="$(git rev-parse HEAD)"
[ -f "$TQ/passed/$sha" ] || exit 1
printf 'Full end-to-end suite passed locally on `%s` (1 passed).\n' "$sha"
EOF
# npm run test:e2e:full: records whether it ran under the e2e lock (and if it got PR_QUEUE_CHILD), then passes
# unless $TQ/e2e_fail exists. $TQ/on_e2e: a script run once, first.
cat > "$TQ/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ -f "$TQ/on_e2e" ] && { bash "$TQ/on_e2e"; rm -f "$TQ/on_e2e"; }
if flock -n "$PR_QUEUE_DIR/e2e.lock" true; then echo "$* unlocked" >> "$TQ/npm.log"; else echo "$* locked" >> "$TQ/npm.log"; fi
if [ -n "${PR_QUEUE_CHILD+set}" ]; then echo "inherited PR_QUEUE_CHILD" >> "$TQ/npm.log"; fi
[ -f "$TQ/e2e_fail" ] && exit 1
touch "$TQ/passed/$(git rev-parse HEAD)"
EOF
# claude -p (run by review.sh): logs "code <prompt>" for a code review, "tests <first line>" for a test review,
# "judge <its reviews line>" for a judge, and reports the verdict in $TQ/verdict, $TQ/tests_verdict (default
# ready) or $TQ/judge_verdict (default needs changes). $TQ/claude_fail makes them all fail.
# With $TQ/sync, each session waits up to 5 s for the other one to start, and logs in sync.log if it did.
# With $TQ/hang, each session logs its pid in $TQ/hung and hangs for 30 s; on TERM it takes 0.5 s to end.
# $TQ/judge_hang does the same for a judge only.
cat > "$TQ/bin/claude" <<'EOF'
#!/usr/bin/env bash
prev=""; for a in "$@"; do [ "$prev" = --append-system-prompt-file ] && cp "$a" "$TQ/sysprompt"; prev="$a"; done
if [[ "$2" == *"code-review skill"* ]]; then
  kind=code other=tests; echo "code $2" >> "$TQ/claude.log"; v="$(cat "$TQ/verdict" 2>/dev/null || echo ready)"
elif [[ "$2" == "Judge the reviews of one change"* ]]; then
  kind=judge other=""; echo "judge $(grep -m1 '^- Reviews to judge' <<<"$2")" >> "$TQ/claude.log"
  v="$(cat "$TQ/judge_verdict" 2>/dev/null || echo "needs changes")"
else
  kind=tests other=code; echo "tests ${2%%$'\n'*}" >> "$TQ/claude.log"; v="$(cat "$TQ/tests_verdict" 2>/dev/null || echo ready)"
fi
[ -f "$TQ/claude_fail" ] && exit 1
if [ "$kind" = judge ] && [ -f "$TQ/judge_hang" ]; then trap 'sleep 0.5; exit 1' TERM; echo "$$" >> "$TQ/hung"; sleep 30; fi
if [ -f "$TQ/hang" ]; then trap 'sleep 0.5; exit 1' TERM; echo "$$" >> "$TQ/hung"; sleep 30; fi
if [ -f "$TQ/sync" ] && [ -n "$other" ]; then
  touch "$TQ/started-$kind"
  for _ in $(seq 50); do
    if [ -f "$TQ/started-$other" ]; then echo "$kind saw $other" >> "$TQ/sync.log"; break; fi
    sleep 0.1
  done
fi
python3 -I -c 'import json, sys; print(json.dumps({"result": "important: a.txt:1: broken\nVerdict: " + sys.argv[1], "total_cost_usd": 0.3, "duration_ms": 1000}))' "$v"
EOF
chmod +x "$TQ/bin/"*

# Origin, the main checkout R (with the repo's scripts), and a second clone O that moves main.
git init -q --bare -b main "$TMP/origin.git"
R="$TMP/repo"; git clone -q "$TMP/origin.git" "$R" 2>/dev/null
RQ="$PR_QUEUE_DIR/repos/repo"   # the queue of R's repo
mkdir -p "$R/scripts"; touch "$R/scripts/e2e-gate.mjs"
cat > "$R/scripts/create-pr.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TQ/created.log"
git push -q -u origin HEAD 2>/dev/null
echo OPEN > "$TQ/pr_state"; git branch --show-current > "$TQ/pr_branch"
printf 'template\n\n## Local end-to-end run\n\n%s\n' "$(node scripts/e2e-gate.mjs pr-line)" > "$TQ/pr_body"
EOF
chmod +x "$R/scripts/create-pr.sh"
git -C "$R" add -A && git -C "$R" commit -q -m init && git -C "$R" push -q origin main 2>/dev/null
O="$TMP/other"; git clone -q "$TMP/origin.git" "$O" 2>/dev/null
advance() { echo "$2" > "$O/$1"; git -C "$O" add -A; git -C "$O" commit -q -m "main: $1"; git -C "$O" push -q origin main 2>/dev/null; }
# mkwt <name> [file] [content] [branch]: a worktree on branch fix/<name> from the current origin/main, with one commit.
mkwt() {
  git -C "$R" fetch -q origin
  git -C "$R" worktree add -q "$TMP/wt-$1" -b "${4:-fix/$1}" origin/main 2>/dev/null
  echo "${3:-$1}" > "$TMP/wt-$1/${2:-$1.txt}"
  git -C "$TMP/wt-$1" add -A && git -C "$TMP/wt-$1" commit -q -m "$1"
}
reset_pr() {
  rm -f "$TQ/pr_state" "$TQ/pr_body" "$TQ/pr_branch" "$TQ/checks_seq" "$TQ/e2e_fail" "$TQ/merge_fail" "$TQ/head_lag" "$TQ/on_checks" \
    "$TQ/verdict" "$TQ/tests_verdict" "$TQ/judge_verdict" "$TQ/judge_hang" "$TQ/claude_fail" "$TQ/sync" "$TQ"/started-* "$TQ/sync.log"
  : > "$TQ/gh.log"; : > "$TQ/created.log"; : > "$TQ/npm.log"; : > "$TQ/claude.log"
}
# code_reviews / test_reviews: the review sessions claude.log shows since the last reset
code_reviews() { grep '^code ' "$TQ/claude.log"; }
test_reviews() { grep '^tests ' "$TQ/claude.log"; }
# called through assert
# shellcheck disable=SC2329
in_done() { test -n "$(find "$RQ/done" -name "*$1.job")"; }
# shellcheck disable=SC2329
in_failed() { test -n "$(find "$RQ/failed" -name "*$1.job")"; }

# --- add ---
out="$(Q add "$TMP/nope" fix x)";            assert_contains "add: missing dir refused"   "$out" "no such directory"
mkdir "$TMP/plain"
out="$(Q add "$TMP/plain" fix x)";           assert_contains "add: non-git dir refused"   "$out" "is not a git checkout"
git -C "$R" pull -q --ff-only 2>/dev/null
out="$(Q add "$R" fix x)";                   assert_contains "add: main refused"          "$out" "is on main"
mkwt dirty; echo x >> "$TMP/wt-dirty/dirty.txt"
out="$(Q add "$TMP/wt-dirty" fix x)";        assert_contains "add: dirty tree refused"    "$out" "uncommitted changes"
git -C "$R" worktree add -q "$TMP/wt-empty" -b fix/empty origin/main 2>/dev/null
out="$(Q add "$TMP/wt-empty" fix x)";        assert_contains "add: no commits refused"    "$out" "no commits ahead"

# --- happy path: behind main, needs e2e, gets a body ---
reset_pr; mkwt happy; advance unrelated.txt main
out="$(Q add "$TMP/wt-happy" fix x "$TMP/nobody.md")"; assert_contains "add: missing body refused" "$out" "no such body file"
echo "My summary" > "$TQ/body.md"
out="$(Q add "$TMP/wt-happy" fix "Happy thing" "$TQ/body.md")"; assert_contains "add: queued" "$out" "queued fix/happy"
out="$(Q status)";                           assert_contains "status lists the job"       "$out" "fix/happy"
out="$(Q run)"
assert_contains "happy: merged main in"      "$out" "merged origin/main"
assert_contains "happy: reviewed at medium"  "$out" "(/code-review medium)"
assert_contains "happy: fresh claude -p review" "$(cat "$TQ/claude.log")" 'args "medium fix/happy"'
assert "happy: review saved, without the tests" test -n "$(find "$PR_QUEUE_DIR/reviews" -name 'fix-happy-*-medium-notests.md')"
assert_contains "happy: tests reviewed too"  "$out" "reviewing the tests of"
assert_contains "happy: a test review session" "$(test_reviews)" "Review the tests of one change"
assert "happy: test review saved"            test -n "$(find "$PR_QUEUE_DIR/reviews" -name 'fix-happy-*-tests.md')"
assert_contains "happy: the user's rules from the stand-in, not ~/.claude" "$(cat "$TQ/sysprompt")" "Stand-in user rule."
assert_contains "happy: the code review leaves tests to it" "$(code_reviews)" "a separate test review covers them"
assert_contains "happy: ran e2e"             "$out" "running the full e2e suite"
assert_contains "happy: merged"              "$out" "MERGED fix/happy: #7 as 1234567"
assert_contains "happy: e2e under the lock"  "$(cat "$TQ/npm.log")" "run test:e2e:full locked"
assert_contains "happy: create-pr args"      "$(cat "$TQ/created.log")" "fix Happy thing"
assert_contains "happy: body from the file"  "$(cat "$TQ/pr_body")" "My summary"
assert_contains "happy: pass line kept"      "$(cat "$TQ/pr_body")" "Full end-to-end suite passed locally on"
assert_not_contains "happy: template replaced" "$(cat "$TQ/pr_body")" "template"
assert_contains "happy: merged the tested commit" "$(cat "$TQ/gh.log")" "--match-head-commit"
assert "happy: worktree removed"             test ! -d "$TMP/wt-happy"
assert "happy: local branch deleted"         test -z "$(git -C "$R" branch --list fix/happy)"
assert "happy: remote branch deleted"        test -z "$(git --git-dir="$TMP/origin.git" branch --list fix/happy)"
assert "happy: main checkout pulled"         test -f "$R/unrelated.txt"
assert "happy: job moved to done"            in_done happy
assert "happy: nothing left running"         test -z "$(find "$RQ/running" -type f)"
assert_contains "empty queue says so"        "$out" "the queue is empty"

# --- merge conflict: aborted, no PR ---
reset_pr
mkwt conflict shared.txt branch; advance shared.txt main
Q add "$TMP/wt-conflict" fix "Conflict" >/dev/null; out="$(Q run)"
assert_contains "conflict: failed with files" "$out" "merge conflict with origin/main in: shared.txt"
assert "conflict: merge aborted"             test -z "$(git -C "$TMP/wt-conflict" status --porcelain)"
assert "conflict: no PR opened"              test ! -s "$TQ/created.log"
assert "conflict: job in failed/"            in_failed conflict
assert_contains "results log has it"         "$(Q status)" "FAILED fix/conflict"

# --- review: "needs changes" or no review -> no e2e, no PR; --review sets the level; a ready commit isn't reviewed twice ---
reset_pr; echo "needs changes" > "$TQ/verdict"; mkwt bad
Q add --review high "$TMP/wt-bad" fix "Bad" >/dev/null; out="$(Q run)"
assert_contains "review: needs changes fails the job" "$out" "FAILED fix/bad: the review found changes to make (review: $PR_QUEUE_DIR/reviews/fix-bad-"
assert_contains "review: --review high"      "$(cat "$TQ/claude.log")" 'args "high fix/bad"'
assert "review: no e2e run"                  test ! -s "$TQ/npm.log"
assert "review: no PR opened"                test ! -s "$TQ/created.log"
assert "review: job in failed/"              in_failed bad
rm -f "$TQ/verdict"; : > "$TQ/claude.log"
out="$(Q add "$TMP/wt-bad" fix "Bad")";      assert_contains "re-queue keeps --review" "$out" "keeping --review high"
out="$(Q run)"
assert_contains "re-queue: reviewed at high again" "$(cat "$TQ/claude.log")" 'args "high fix/bad"'
assert_contains "re-queue: then merged"      "$out" "MERGED fix/bad"
reset_pr; touch "$TQ/claude_fail"; mkwt noreview
Q add "$TMP/wt-noreview" fix "No review" >/dev/null; out="$(Q run)"
assert_contains "review: claude fails"       "$out" "FAILED fix/noreview: the review didn't run"
assert_contains "review: claude fails, the test review too" "$out" "; the test review didn't run: review: claude -p failed"
reset_pr; echo fail > "$TQ/checks_seq"; mkwt again
Q add "$TMP/wt-again" fix "Again" >/dev/null; Q run >/dev/null
rm -f "$TQ/checks_seq"; : > "$TQ/claude.log"
Q add "$TMP/wt-again" fix "Again" >/dev/null; out="$(Q run)"
assert_contains "review: same commit not reviewed again" "$out" "already reviewed"
assert "review: no second claude run"        test ! -s "$TQ/claude.log"
assert_contains "review: then merged"        "$out" "MERGED fix/again"
reset_pr; mkwt late2
echo "echo more >> '$TMP/wt-late2/late2.txt'; git -C '$TMP/wt-late2' commit -qam more" > "$TQ/on_e2e"
Q add "$TMP/wt-late2" fix "Late commit" >/dev/null; out="$(Q run)"
assert_contains "review: a commit after the review fails the job" "$out" "fix/late2 got commits after the review"
assert "review: so no PR"                    test ! -s "$TQ/created.log"
reset_pr; mkwt skip
Q add "$TMP/wt-skip" fix "Skip" >/dev/null; out="$(PR_QUEUE_REVIEW=0 Q run)"
assert "review: PR_QUEUE_REVIEW=0 skips it"  test -z "$(code_reviews)"
assert_contains "review: skipped, still merged" "$out" "MERGED fix/skip"
reset_pr; mkwt skip2
Q add --review high "$TMP/wt-skip2" fix "Skip 2" >/dev/null; out="$(PR_QUEUE_REVIEW=0 Q run)"
assert_contains "review: --review high still reviewed with PR_QUEUE_REVIEW=0" "$(cat "$TQ/claude.log")" 'args "high fix/skip2"'
reset_pr; mkwt none
Q add --review none "$TMP/wt-none" fix "None" >/dev/null; out="$(Q run)"
assert "review: --review none skips it"      test -z "$(code_reviews)"
assert_contains "review: --review none says so" "$out" "not reviewed (queued with --review none)"
assert_contains "review: --review none merged" "$out" "MERGED fix/none"
out="$(Q add --review max "$TMP/wt-skip" fix x)"; assert_contains "add: bad review level refused" "$out" "--review takes none, low, medium, high or xhigh"
out="$(Q add --review)";                     assert_contains "add: --review needs a level" "$out" "pr-queue.sh add"
out="$(PR_QUEUE_REVIEW=off Q run)";         assert_contains "run: bad PR_QUEUE_REVIEW refused" "$out" "PR_QUEUE_REVIEW must be 0 (no code reviews), low"

# --- the test review: at the same time as the code review; either one's "needs changes" fails the job ---
reset_pr; touch "$TQ/sync"; mkwt both
Q add "$TMP/wt-both" fix "Both" >/dev/null; out="$(Q run)"
assert_contains "tests: the code review saw the test review start" "$(cat "$TQ/sync.log")" "code saw tests"
assert_contains "tests: the test review saw the code review start" "$(cat "$TQ/sync.log")" "tests saw code"
assert_contains "tests: both ready, merged"  "$out" "MERGED fix/both"
reset_pr; echo "needs changes" > "$TQ/tests_verdict"; mkwt weak
Q add "$TMP/wt-weak" fix "Weak" >/dev/null; out="$(Q run)"
assert_contains "tests: needs changes fails the job" "$out" \
  "FAILED fix/weak: the test review found changes to make (test review: $PR_QUEUE_DIR/reviews/fix-weak-"
assert_contains "tests: names the saved test review" "$out" "-tests.md)"
assert "tests: no e2e run"                   test ! -s "$TQ/npm.log"
assert "tests: no PR opened"                 test ! -s "$TQ/created.log"
reset_pr; echo "needs changes" > "$TQ/verdict"; echo "needs changes" > "$TQ/tests_verdict"; mkwt worse
Q add "$TMP/wt-worse" fix "Worse" >/dev/null; out="$(Q run)"
assert_contains "tests: both need changes, both named" "$out" \
  "-medium-notests.md); the test review found changes to make (test review: $PR_QUEUE_DIR/reviews/fix-worse-"

# --- the test review's own switches: --tests none|on (kept on a re-queue), PR_QUEUE_TEST_REVIEW=0 ---
reset_pr; echo "needs changes" > "$TQ/verdict"; mkwt notests
Q add --tests none --review high "$TMP/wt-notests" fix "No tests" >/dev/null; out="$(Q run)"
assert_contains "--tests none: says so"      "$out" "tests not reviewed (queued with --tests none)"
assert "--tests none: no test review"        test -z "$(test_reviews)"
assert_contains "--tests none: options in any order" "$(code_reviews)" 'args "high fix/notests"'
assert_not_contains "--tests none: the code review keeps the tests" "$(code_reviews)" "a separate test review"
assert "--tests none: saved as a full code review" test -n "$(find "$PR_QUEUE_DIR/reviews" -name 'fix-notests-*-high.md')"
rm -f "$TQ/verdict"; : > "$TQ/claude.log"
out="$(Q add "$TMP/wt-notests" fix "No tests")"; assert_contains "re-queue keeps --tests" "$out" "keeping --tests none"
out="$(Q run)"
assert "re-queue: still no test review"      test -z "$(test_reviews)"
assert_contains "re-queue: --tests none merged" "$out" "MERGED fix/notests"
reset_pr; echo "needs changes" > "$TQ/verdict"; mkwt flags
Q add --tests none --review high "$TMP/wt-flags" fix "Flags" >/dev/null; Q run >/dev/null
rm -f "$TQ/verdict"; : > "$TQ/claude.log"
Q add --review none --tests on "$TMP/wt-flags" fix "Flags" >/dev/null; out="$(Q run)"
assert "re-queue: a new --review beats the kept one" test -z "$(code_reviews)"
assert "re-queue: a new --tests beats the kept one" test -n "$(test_reviews)"
assert_contains "re-queue: new flags, merged" "$out" "MERGED fix/flags"
reset_pr; mkwt late3
echo "echo more >> '$TMP/wt-late3/late3.txt'; git -C '$TMP/wt-late3' commit -qam more" > "$TQ/on_e2e"
Q add --review none "$TMP/wt-late3" fix "Late commit" >/dev/null; out="$(Q run)"
assert_contains "tests: a commit after only the test review fails the job" "$out" "fix/late3 got commits after the review"
reset_pr; mkwt tskip
Q add "$TMP/wt-tskip" fix "Tests skip" >/dev/null; out="$(PR_QUEUE_TEST_REVIEW=0 Q run)"
assert "PR_QUEUE_TEST_REVIEW=0 skips the test review" test -z "$(test_reviews)"
assert "PR_QUEUE_TEST_REVIEW=0: the code review runs" test -n "$(code_reviews)"
assert_contains "PR_QUEUE_TEST_REVIEW=0: merged" "$out" "MERGED fix/tskip"
reset_pr; mkwt ton
Q add --tests on "$TMP/wt-ton" fix "Tests on" >/dev/null; PR_QUEUE_TEST_REVIEW=0 Q run >/dev/null
assert "--tests on: reviewed with PR_QUEUE_TEST_REVIEW=0" test -n "$(test_reviews)"
out="$(Q add --tests maybe "$TMP/wt-ton" fix x)"; assert_contains "add: bad --tests refused" "$out" "--tests takes on or none"
out="$(Q add --tests)";                      assert_contains "add: --tests needs a value" "$out" "pr-queue.sh add"
out="$(PR_QUEUE_TEST_REVIEW=yes Q run)";    assert_contains "run: bad PR_QUEUE_TEST_REVIEW refused" "$out" "PR_QUEUE_TEST_REVIEW must be 0"
for poll in 0 0.0 x 1.2.3; do
  out="$(PR_QUEUE_POLL=$poll Q run)";       assert_contains "run: PR_QUEUE_POLL=$poll refused" "$out" "PR_QUEUE_POLL must be a number of seconds above 0"
done

# --- e2e fails: no PR ---
reset_pr; touch "$TQ/e2e_fail"; mkwt e2efail
Q add "$TMP/wt-e2efail" fix "E2e fail" >/dev/null; out="$(Q run)"
assert_contains "e2e fail: job failed"       "$out" "FAILED fix/e2efail: the full e2e suite failed"
assert "e2e fail: no PR opened"              test ! -s "$TQ/created.log"

# --- checks fail: PR left open, not merged; a fix is re-queued, pushed to the same PR with a fresh pass line ---
reset_pr; echo fail > "$TQ/checks_seq"; mkwt ci
old="$(git -C "$TMP/wt-ci" rev-parse HEAD)"
Q add "$TMP/wt-ci" fix "Ci" >/dev/null; out="$(Q run)"
assert_contains "checks fail: names the check" "$out" "checks failed on #7: Checks"
assert_not_contains "checks fail: not merged" "$(cat "$TQ/gh.log")" "pr merge"
rm -f "$TQ/checks_seq"; echo fix >> "$TMP/wt-ci/ci.txt"; git -C "$TMP/wt-ci" commit -qam fix
new="$(git -C "$TMP/wt-ci" rev-parse HEAD)"
Q add "$TMP/wt-ci" fix "Ci" >/dev/null; out="$(Q run)"
assert_contains "requeue: merged"            "$out" "MERGED fix/ci: #7"
assert "requeue: pushed, not a second PR"    test "$(grep -c '^fix Ci$' "$TQ/created.log")" = 1
assert_contains "requeue: pass line for the new commit" "$(cat "$TQ/pr_body")" "$new"
assert_not_contains "requeue: old pass line gone" "$(cat "$TQ/pr_body")" "$old"
assert "requeue: one pass section"           test "$(grep -c '^## Local end-to-end run' "$TQ/pr_body")" = 1

# --- checks: none yet, then pending, then pass; a cancelled check fails ---
reset_pr; printf 'none\npending\npass\n' > "$TQ/checks_seq"; mkwt slow
Q add "$TMP/wt-slow" fix "Slow" >/dev/null; out="$(Q run)"
assert_contains "slow checks: merged"        "$out" "MERGED fix/slow"
assert "slow checks: polled until done"      test "$(grep -c '^pr checks' "$TQ/gh.log")" -ge 4
reset_pr; printf 'pass\npending\npass\n' > "$TQ/checks_seq"; mkwt late
Q add "$TMP/wt-late" fix "Late" >/dev/null; out="$(Q run)"
assert_contains "late check: waited for it"  "$out" "MERGED fix/late"
assert "late check: polled after the pending" test "$(grep -c '^pr checks' "$TQ/gh.log")" -ge 4
reset_pr; echo cancel > "$TQ/checks_seq"; mkwt cancel
Q add "$TMP/wt-cancel" fix "Cancel" >/dev/null; out="$(Q run)"
assert_contains "cancelled check: failed"    "$out" "checks failed on #7: Checks"
reset_pr; echo none > "$TQ/checks_seq"; mkwt nochecks
Q add "$TMP/wt-nochecks" fix "No checks" >/dev/null; out="$(Q run)"
assert_contains "no checks: gives up"        "$out" "no checks reported on #7"
# A check that never leaves pending fails the job at PR_QUEUE_CHECKS_TIMEOUT (timeout 30 guards against a hang)
reset_pr; echo pending > "$TQ/checks_seq"; mkwt hang
Q add "$TMP/wt-hang" fix "Hang" >/dev/null
out="$(PR_QUEUE_CHECKS_TIMEOUT=1 PATH="$TQ/bin:$PATH" timeout 30 bash "$ROOT/scripts/pr-queue.sh" run </dev/null 2>&1)"; rc=$?
assert "stuck pending: runner exits"         test "$rc" -ne 124
assert_contains "stuck pending: gives up, names the check" "$out" "checks still pending on #7 after 1s: Checks"
assert "stuck pending: job in failed/"       in_failed hang
assert_not_contains "stuck pending: not merged" "$(cat "$TQ/gh.log")" "pr merge"

# --- the PR's head lags behind the push: checks are read only once it shows the pushed commit ---
reset_pr; echo 2 > "$TQ/head_lag"; mkwt lag
Q add "$TMP/wt-lag" fix "Lag" >/dev/null; out="$(Q run)"
assert_contains "head lag: merged"           "$out" "MERGED fix/lag"
last_head="$(grep -n 'headRefOid' "$TQ/gh.log" | tail -1 | cut -d: -f1)"
first_checks="$(grep -n '^pr checks' "$TQ/gh.log" | head -1 | cut -d: -f1)"
assert "head lag: checks after the head moved" test "$last_head" -lt "$first_checks"
reset_pr; echo 99 > "$TQ/head_lag"; mkwt stuck
Q add "$TMP/wt-stuck" fix "Stuck" >/dev/null; out="$(Q run)"
assert_contains "head never moves: fails"    "$out" "does not show"

# --- a commit made while the job runs is kept, not deleted with the branch ---
reset_pr; mkwt busy; sha="$(git -C "$TMP/wt-busy" rev-parse HEAD)"
echo "echo more >> '$TMP/wt-busy/busy.txt'; git -C '$TMP/wt-busy' commit -qam more" > "$TQ/on_checks"
Q add "$TMP/wt-busy" fix "Busy" >/dev/null; out="$(Q run)"
assert_contains "busy: merged the tested commit" "$(cat "$TQ/gh.log")" "--match-head-commit $sha"
assert_contains "busy: says it kept them"    "$out" "kept the worktree and branch"
assert "busy: worktree kept"                 test -d "$TMP/wt-busy"
assert "busy: new commit still on the branch" test "$(git -C "$R" rev-list --count "$sha..fix/busy")" = 1

# --- the main checkout is pulled despite untracked files; a change to a tracked file blocks the pull, and it says so ---
reset_pr; mkwt untracked; advance pulled.txt main; touch "$R/untracked.txt"
Q add "$TMP/wt-untracked" fix "Untracked" >/dev/null; out="$(Q run)"
assert "untracked file: main checkout pulled" test -f "$R/pulled.txt"
assert_not_contains "untracked file: no warning" "$out" "did not pull"
reset_pr; mkwt tracked; advance pulled2.txt main; echo local >> "$R/pulled.txt"
Q add "$TMP/wt-tracked" fix "Tracked" >/dev/null; out="$(Q run)"
assert "tracked change: not pulled"          test ! -f "$R/pulled2.txt"
assert_contains "tracked change: says so"    "$out" "has changes to tracked files"
git -C "$R" checkout -q -- pulled.txt; rm -f "$R/untracked.txt"; git -C "$R" pull -q --ff-only

# --- merging fails: job failed, nothing removed ---
reset_pr; touch "$TQ/merge_fail"; mkwt nomerge
Q add "$TMP/wt-nomerge" fix "No merge" >/dev/null; out="$(Q run)"
assert_contains "merge fails: job failed"    "$out" "merging #7 failed"
assert "merge fails: worktree kept"          test -d "$TMP/wt-nomerge"
assert "merge fails: job in failed/"         in_failed nomerge

# --- no scripts/create-pr.sh: gh pr create, with or without a body file ---
reset_pr; mkwt nocreate; git -C "$TMP/wt-nocreate" rm -q scripts/create-pr.sh; git -C "$TMP/wt-nocreate" commit -qm rm
Q add "$TMP/wt-nocreate" fix "No create" >/dev/null; out="$(Q run)"
assert_contains "gh create: merged"          "$out" "MERGED fix/nocreate"
assert_contains "gh create: title"           "$(cat "$TQ/created.log")" "gh-create fix: No create"
assert_contains "gh create: pass line in body" "$(cat "$TQ/pr_body")" "Full end-to-end suite passed locally on"
reset_pr; mkwt nocreate2; git -C "$TMP/wt-nocreate2" rm -q scripts/create-pr.sh; git -C "$TMP/wt-nocreate2" commit -qm rm
Q add "$TMP/wt-nocreate2" fix "No create" "$TQ/body.md" >/dev/null; out="$(Q run)"
assert_contains "gh create + body: merged"   "$out" "MERGED fix/nocreate2"
assert_contains "gh create + body: body"     "$(cat "$TQ/pr_body")" "My summary"

# --- add from a subdirectory queues the worktree's root ---
reset_pr; mkwt sub; mkdir "$TMP/wt-sub/src"
Q add "$TMP/wt-sub/src" fix "Sub" >/dev/null; out="$(Q run)"
assert_contains "subdir: e2e still runs"     "$out" "running the full e2e suite"
assert_contains "subdir: create-pr.sh used"  "$(cat "$TQ/created.log")" "fix Sub"
assert "subdir: worktree removed"            test ! -d "$TMP/wt-sub"

# --- re-queueing replaces only that branch's job ---
reset_pr; mkwt login; mkwt login2 login.txt x login
Q add "$TMP/wt-login" fix "Fix login" >/dev/null
Q add "$TMP/wt-login2" fix "Login" >/dev/null
Q add "$TMP/wt-login2" fix "Login again" >/dev/null
out="$(Q status)"
assert_contains "similar names: fix/login still queued" "$out" "fix/login"
assert "similar names: one job each"         test "$(find "$RQ/queue" -name '*.job' | wc -l)" = 2
rm -f "$RQ"/queue/*

# --- PR_QUEUE_MERGE=0 leaves the PR open ---
reset_pr; mkwt open
Q add "$TMP/wt-open" fix "Open" >/dev/null; out="$(PR_QUEUE_MERGE=0 Q run)"
assert_contains "no-merge: ready"            "$out" "READY fix/open: #7 passed, left open"
assert "no-merge: PR still open"             test "$(cat "$TQ/pr_state")" = OPEN
assert "no-merge: worktree kept"             test -d "$TMP/wt-open"

# --- a Ctrl-C of the runner, or a TERM to its process group, during the reviews stops both claude -p sessions
# and leaves no temp files; the job stays in running/, where the next run moves it to failed/ ---
# shellcheck disable=SC2329  # called through assert
gone() { ! kill -0 "$1" 2>/dev/null; }
# stop_runner <INT|TERM|HUP> <name>: runs the queue (branch fix/<name>) with both sessions hanging, then sends the signal to the runner's
# whole process group, as a terminal's Ctrl-C (INT), its closing (HUP) or `kill -- -<pgid>` (TERM) does. python
# gives the runner a group of its own, with SIGINT on (a background job's is off). Sets started, stop_rc, took,
# alive_at_exit (sessions still running when the runner ended) and alive.
stop_runner() {
  local rpid p _
  reset_pr; rm -rf "$TQ/hung" "$TQ/tmp"; mkdir -p "$TQ/tmp"; touch "$TQ/hang"; mkwt "$2"
  Q add "$TMP/wt-$2" fix "Stop" >/dev/null
  PATH="$TQ/bin:$PATH" TMPDIR="$TQ/tmp" python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$ROOT/scripts/pr-queue.sh" run </dev/null >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 100); do [ "$(wc -l 2>/dev/null < "$TQ/hung")" = 2 ] && break; sleep 0.1; done
  started="$(wc -l 2>/dev/null < "$TQ/hung")"
  local t0=$SECONDS; kill -"$1" -- "-$rpid"
  { wait "$rpid"; } 2>/dev/null; stop_rc=$?   # (no "Hangup" notice from bash)
  alive_at_exit=""; while read -r p; do gone "$p" || alive_at_exit=1; done < "$TQ/hung"
  # On TERM or HUP the runner ends at once, while its job is still stopping the reviews; the job holds the
  # runner's lock until it ends.
  for _ in $(seq 100); do
    alive=""; while read -r p; do gone "$p" || alive=1; done < "$TQ/hung"
    if [ -z "$alive" ] && [ -z "$(ls -A "$TQ/tmp")" ] && flock -n "$RQ/run.lock" true; then break; fi
    sleep 0.1
  done
  took=$((SECONDS - t0)); rm -f "$TQ/hang"
}
for sig in INT TERM HUP; do
  stop_runner "$sig" "stop$sig"
  case "$sig" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
  assert "$sig: both sessions started"           test "$started" = 2
  assert "$sig: the runner ends by SIG$sig"      test "$stop_rc" = "$code"
  assert "$sig: both claude -p sessions stopped" test -z "$alive"
  assert "$sig: no temp files left"              test -z "$(ls -A "$TQ/tmp")"
  assert "$sig: at once, not after the sessions' 30 s" test "$took" -lt 10
  assert "$sig: the job stayed in running/"      test -n "$(find "$RQ/running" -name "*stop$sig.job")"
  assert "$sig: the runner's lock is free again" flock -n "$RQ/run.lock" true
  rm -f "$RQ"/running/*
done
# A Ctrl-C reaches the job too, so the runner ends only once both sessions have.
stop_runner INT stopINT2
assert "INT: the sessions ended before the runner" test -z "$alive_at_exit"
rm -f "$RQ"/running/*

# --- the judge: rules on the reviews that need changes; only its confirmed findings go to the agent ---
# judge_line: what the judge session was given, since the last reset
judge_line() { grep '^judge ' "$TQ/claude.log"; }
reset_pr; echo "needs changes" > "$TQ/verdict"; echo ready > "$TQ/judge_verdict"; mkwt falsealarm
Q add "$TMP/wt-falsealarm" fix "False alarm" >/dev/null; out="$(Q run)"
assert_contains "judge: runs on a review that needs changes" "$(judge_line)" "Reviews to judge (read each with cat): $PR_QUEUE_DIR/reviews/fix-falsealarm-"
assert_not_contains "judge: not given the ready test review" "$(judge_line)" "-tests.md"
assert_contains "judge: nothing to fix, says so" "$out" "the judge found nothing to fix (judge: $PR_QUEUE_DIR/reviews/fix-falsealarm-"
assert "judge: nothing to fix, e2e runs"     test -s "$TQ/npm.log"
assert_contains "judge: nothing to fix, merged" "$out" "MERGED fix/falsealarm"

reset_pr; echo "needs changes" > "$TQ/verdict"; echo "needs changes" > "$TQ/tests_verdict"; mkwt real
Q add "$TMP/wt-real" fix "Real" >/dev/null; out="$(Q run)"
assert_contains "judge: given both reviews"  "$(judge_line)" "-medium-notests.md $PR_QUEUE_DIR/reviews/fix-real-"
assert_contains "judge: confirmed changes fail the job" "$out" "; the judge confirmed changes to make (judge: $PR_QUEUE_DIR/reviews/fix-real-"
assert_contains "judge: names its file"      "$out" "-judge.md)"
assert "judge: confirmed changes, no e2e"    test ! -s "$TQ/npm.log"
assert "judge: confirmed changes, no PR"     test ! -s "$TQ/created.log"
assert "judge: confirmed changes, job in failed/" in_failed real
# A second judged round with changes to make goes to the user.
echo second >> "$TMP/wt-real/real.txt"; git -C "$TMP/wt-real" commit -q -am second
: > "$TQ/claude.log"; Q add "$TMP/wt-real" fix "Real" >/dev/null; out="$(Q run)"
assert_contains "judge: two judged rounds need the user" "$out" \
  "FAILED fix/real: needs your decision: the branch still had changes to make after two judged rounds (judge: $PR_QUEUE_DIR/reviews/fix-real-"
assert "judge: two rounds, no PR"            test ! -s "$TQ/created.log"

reset_pr; echo "needs changes" > "$TQ/verdict"; echo escalate > "$TQ/judge_verdict"; mkwt critical
Q add "$TMP/wt-critical" fix "Critical" >/dev/null; out="$(Q run)"
assert_contains "judge: an escalation needs the user" "$out" \
  "FAILED fix/critical: needs your decision: the judge rejected a finding that would be critical if real (judge: $PR_QUEUE_DIR/reviews/fix-critical-"
assert "judge: escalation, no e2e"           test ! -s "$TQ/npm.log"
assert "judge: escalation, job in failed/"   in_failed critical

# No judge when a review didn't run, or with PR_QUEUE_JUDGE=0.
reset_pr; echo garbage > "$TQ/verdict"; echo "needs changes" > "$TQ/tests_verdict"; mkwt halfrun
Q add "$TMP/wt-halfrun" fix "Half run" >/dev/null; out="$(Q run)"
assert "judge: not when a review didn't run" test -z "$(judge_line)"
assert_contains "judge: that review named"   "$out" "FAILED fix/halfrun: the review didn't run"
assert_contains "judge: and the other's findings" "$out" "; the test review found changes to make (test review: $PR_QUEUE_DIR/reviews/fix-halfrun-"
reset_pr; echo "needs changes" > "$TQ/verdict"; mkwt plain
Q add "$TMP/wt-plain" fix "Plain" >/dev/null; out="$(PR_QUEUE_JUDGE=0 Q run)"
assert "PR_QUEUE_JUDGE=0: no judge"          test -z "$(judge_line)"
assert_contains "PR_QUEUE_JUDGE=0: the review fails the job" "$out" "FAILED fix/plain: the review found changes to make (review: "
assert_not_contains "PR_QUEUE_JUDGE=0: no judging" "$out" "judging"
assert_not_contains "PR_QUEUE_JUDGE=0: no judgement named" "$out" "judge:"
out="$(PR_QUEUE_JUDGE=maybe Q run)";         assert_contains "run: bad PR_QUEUE_JUDGE refused" "$out" "PR_QUEUE_JUDGE must be 0"

# A TERM to the runner's process group while the judge works stops the judge's session too.
reset_pr; rm -rf "$TQ/hung" "$TQ/tmp"; mkdir -p "$TQ/tmp"; echo "needs changes" > "$TQ/verdict"; touch "$TQ/judge_hang"; mkwt stopjudge
Q add "$TMP/wt-stopjudge" fix "Stop judge" >/dev/null
PATH="$TQ/bin:$PATH" TMPDIR="$TQ/tmp" python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  bash "$ROOT/scripts/pr-queue.sh" run </dev/null >/dev/null 2>&1 &
rpid=$!
for _ in $(seq 100); do [ -s "$TQ/hung" ] && break; sleep 0.1; done
assert "judge stopped: the judge's session started" test -s "$TQ/hung"
t0=$SECONDS; kill -TERM -- "-$rpid"; { wait "$rpid"; } 2>/dev/null
for _ in $(seq 100); do
  if gone "$(cat "$TQ/hung")" && [ -z "$(ls -A "$TQ/tmp")" ] && flock -n "$RQ/run.lock" true; then break; fi
  sleep 0.1
done
assert "judge stopped: its session ended"    gone "$(cat "$TQ/hung")"
assert "judge stopped: at once, not after the session's 30 s" test $((SECONDS - t0)) -lt 10
assert "judge stopped: no temp files left"   test -z "$(ls -A "$TQ/tmp")"
assert "judge stopped: the job stayed in running/" test -n "$(find "$RQ/running" -name '*stopjudge.job')"
rm -f "$TQ/judge_hang" "$RQ"/running/*

# --- a job left in running/ by a dead runner goes to failed/ ---
printf 'worktree=/x\nbranch=fix/dead\n' > "$RQ/running/1-fix-dead.job"
out="$(Q run)";                              assert_contains "dead runner: reported" "$out" "fix/dead was left unfinished"
assert "dead runner: job in failed/"         in_failed dead

# --- one runner at a time per repo, and the lock command ---
reset_pr; mkwt busy2; Q add "$TMP/wt-busy2" fix "Busy" >/dev/null
flock "$RQ/run.lock" sleep 2 & sleep 0.3
out="$(Q run)";                              assert_contains "second runner exits" "$out" "repo: a runner is already working on the queue"
assert "second runner: the job stays queued" test -n "$(find "$RQ/queue" -name '*busy2.job')"
wait; rm -f "$RQ"/queue/*

# --- each repo has its own queue ---
# R2: a second main checkout (a clone of the same origin, so the stubs work), with its own queue. Its jobs fail at
# the e2e run, before any PR, so both repos' jobs can run at the same time.
R2="$TMP/repo2"; git clone -q "$TMP/origin.git" "$R2" 2>/dev/null; RQ2="$PR_QUEUE_DIR/repos/repo2"
mkwt2() {
  git -C "$R2" worktree add -q "$TMP/wt2-$1" -b "fix/$1" origin/main 2>/dev/null
  echo "$1" > "$TMP/wt2-$1/$1.txt"; git -C "$TMP/wt2-$1" add -A && git -C "$TMP/wt2-$1" commit -q -m "$1"
}
reset_pr; mkwt one; mkwt2 two
out="$(Q add "$TMP/wt2-two" fix "Two")"
assert_contains "repos: add names the repo's queue" "$out" "in the queue of repo2"
assert "repos: queued in its repo's queue"   test -n "$(find "$RQ2/queue" -name '*two.job')"
assert "repos: not in the other repo's"      test -z "$(find "$RQ/queue" -name '*two.job')"
assert "repos: the repo's checkout recorded" test "$(cat "$RQ2/checkout")" = "$R2"
Q add "$TMP/wt-one" fix "One" >/dev/null
out="$(Q status)"
assert_contains "repos: status shows each repo" "$out" "repo2 ($R2):"
assert_contains "repos: and its jobs"        "$out" "fix/two"
# A runner busy on one repo doesn't hold up another repo's jobs.
flock "$RQ/run.lock" sleep 3 & sleep 0.3
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"; touch "$TQ/e2e_fail"
wait
assert_contains "repos: the busy repo is skipped" "$out" "repo: a runner is already working on the queue"
assert_contains "repos: and named at the end" "$out" "jobs left in the queue of: repo (see above)"
assert_contains "repos: the other repo's job ran" "$out" "fix/two"
assert "repos: its result in its own log"    grep -q "fix/two" "$RQ2/results.log"
assert "repos: not in the other repo's log"  test -z "$(grep "fix/two" "$RQ/results.log")"
assert "repos: the busy repo's job still queued" test -n "$(find "$RQ/queue" -name '*one.job')"
# `run <checkout>` works on that checkout's repo only.
reset_pr; touch "$TQ/e2e_fail"; mkwt2 three; Q add "$TMP/wt2-three" fix "Three" >/dev/null
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run "$TMP/wt-one")"
assert_contains "run <checkout>: that repo's job" "$out" "fix/one"
assert_not_contains "run <checkout>: not another repo's" "$out" "fix/three"
assert "run <checkout>: the other job still queued" test -n "$(find "$RQ2/queue" -name '*three.job')"
out="$(Q run "$TMP/plain")";                 assert_contains "run <checkout>: not a checkout" "$out" "is not a git checkout"
# Both repos at once: each runner gets its job, and the e2e runs still take turns under the shared lock.
# A setsid stub records PR_QUEUE_CHILD for each repo's runner, then runs the real setsid.
reset_pr; rm -f "$TQ/e2e_fail"; mkwt four
Q add "$TMP/wt-four" fix "Four" >/dev/null
# shellcheck disable=SC2016  # expands in the stub
printf '#!/usr/bin/env bash\necho "child=${PR_QUEUE_CHILD:-}" >> "$TQ/setsid.log"\nexec %q "$@"\n' "$(command -v setsid)" > "$TQ/bin/setsid"
chmod +x "$TQ/bin/setsid"; : > "$TQ/setsid.log"
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 PR_QUEUE_MERGE=0 Q run)"
rm -f "$TQ/bin/setsid"
assert_contains "both repos: one ran"        "$out" "fix/four"
assert_contains "both repos: the other ran"  "$out" "fix/three"
assert "both repos: every e2e run under the lock" test -z "$(grep unlocked "$TQ/npm.log")"
assert "both repos: queues empty"            test -z "$(find "$RQ/queue" "$RQ2/queue" -name '*.job')"
assert "both repos: each runner marked as a repo's runner" test "$(grep -cx 'child=1' "$TQ/setsid.log")" = 2
assert "both repos: the jobs don't inherit the mark" test -z "$(grep PR_QUEUE_CHILD "$TQ/npm.log")"
# A repo's runner that gets to the every-repo path stops there instead of starting runners of its own.
reset_pr; mkwt child; Q add "$TMP/wt-child" fix "Child" >/dev/null
out="$(PR_QUEUE_CHILD=1 PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"; rc=$?
assert_contains "repo's runner: refuses to start runners" "$out" "a repo's runner must not start runners for every repo"
assert "repo's runner: exits with an error"  test "$rc" = 1
assert "repo's runner: the job stays queued" test -n "$(find "$RQ/queue" -name '*child.job')"
rm -f "$RQ"/queue/*
# A job queued to another repo while one repo's runner works starts at once, not after that repo's queue: the
# first job's e2e run queues it, then waits (up to 10 s) until it is running before it ends.
reset_pr; rm -f "$TQ/next_started"; touch "$TQ/e2e_fail"; mkwt first; mkwt second; mkwt2 next
{ printf 'PATH=%q bash %q add %q fix Next >/dev/null\n' "$TQ/bin:$PATH" "$ROOT/scripts/pr-queue.sh" "$TMP/wt2-next"
  # shellcheck disable=SC2016  # expands when on_e2e runs
  printf 'for _ in $(seq 100); do [ -n "$(find %q -name "*next.job")" ] && { touch %q; break; }; sleep 0.1; done\n' \
    "$RQ2/running" "$TQ/next_started"; } > "$TQ/on_e2e"
Q add "$TMP/wt-first" fix "First" >/dev/null; Q add "$TMP/wt-second" fix "Second" >/dev/null
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"
assert "no wait: the other repo's job started during the first job's e2e" test -f "$TQ/next_started"
assert_contains "no wait: it ran"            "$out" "FAILED fix/next"
assert_contains "no wait: the first repo's jobs ran" "$out" "FAILED fix/second"
assert "no wait: no job left queued"         test -z "$(find "$RQ/queue" "$RQ2/queue" -name '*.job')"
# A repo whose runner has ended gets a new one for a job queued to it later, while another repo's runner still
# works (its review sessions hang). The first job's e2e run (1 s) outlasts several polls: a repo whose runner
# still works isn't taken for one that another runner holds, and so isn't left out.
reset_pr; rm -rf "$TQ/hung"; touch "$TQ/e2e_fail" "$TQ/hang"; mkwt slow; mkwt2 b1; mkwt2 b2
echo 'sleep 1' > "$TQ/on_e2e"
Q add "$TMP/wt-slow" fix "Slow" >/dev/null
Q add --review none --tests none "$TMP/wt2-b1" fix "B1" >/dev/null
PATH="$TQ/bin:$PATH" bash "$ROOT/scripts/pr-queue.sh" run </dev/null >"$TQ/ended.out" 2>&1 & rpid=$!
for _ in $(seq 100); do grep -q "fix/b1" "$RQ2/results.log" 2>/dev/null && flock -n "$RQ2/run.lock" true && break; sleep 0.1; done
Q add --review none --tests none "$TMP/wt2-b2" fix "B2" >/dev/null
for _ in $(seq 100); do grep -q "fix/b2" "$RQ2/results.log" 2>/dev/null && break; sleep 0.1; done
assert "ended runner: a job queued to its repo later runs" grep -q "fix/b2" "$RQ2/results.log"
assert "ended runner: while the other repo's job still works" test -n "$(find "$RQ/running" -name '*slow.job')"
assert_not_contains "ended runner: no working repo left out" "$(cat "$TQ/ended.out")" "a runner is already working"
kill -TERM "$rpid"; { wait "$rpid"; } 2>/dev/null
rm -f "$TQ/hang" "$RQ"/running/*
# A job queued in another repo while the runner works is run too.
reset_pr; touch "$TQ/e2e_fail"; mkwt early; mkwt2 late
printf 'PATH=%q bash %q add %q fix Late >/dev/null\n' "$TQ/bin:$PATH" "$ROOT/scripts/pr-queue.sh" "$TMP/wt2-late" > "$TQ/on_e2e"
Q add "$TMP/wt-early" fix "Early" >/dev/null
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"
assert_contains "late job: the first job ran" "$out" "FAILED fix/early"
assert_contains "late job: the one queued meanwhile ran too" "$out" "FAILED fix/late"
assert "late job: no job left queued"        test -z "$(find "$RQ/queue" "$RQ2/queue" -name '*.job')"
assert_contains "late job: then the queues are empty" "$out" "pr-queue: the queues are empty"
# A job queued in a third repo while two repos' runners work is run too, in a round after theirs.
R3="$TMP/repo3"; git clone -q "$TMP/origin.git" "$R3" 2>/dev/null; RQ3="$PR_QUEUE_DIR/repos/repo3"
git -C "$R3" worktree add -q "$TMP/wt3-later" -b fix/later origin/main 2>/dev/null
echo later > "$TMP/wt3-later/later.txt"; git -C "$TMP/wt3-later" add -A; git -C "$TMP/wt3-later" commit -q -m later
reset_pr; touch "$TQ/e2e_fail"; mkwt both1; mkwt2 both2
printf 'PATH=%q bash %q add %q fix Later >/dev/null\n' "$TQ/bin:$PATH" "$ROOT/scripts/pr-queue.sh" "$TMP/wt3-later" > "$TQ/on_e2e"
Q add "$TMP/wt-both1" fix "Both 1" >/dev/null; Q add "$TMP/wt2-both2" fix "Both 2" >/dev/null
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"
assert_contains "late job after two repos: one ran" "$out" "FAILED fix/both1"
assert_contains "late job after two repos: the other ran" "$out" "FAILED fix/both2"
assert_contains "late job after two repos: the third repo's ran too" "$out" "FAILED fix/later"
assert "late job after two repos: no job left queued" test -z "$(find "$RQ3/queue" -name '*.job')"
rm -rf "$RQ3"
# A repo whose runner fails is left out of the next rounds, so the runner ends, and the end says so.
reset_pr; touch "$TQ/e2e_fail"; mkwt live; mkwt2 orphaned
Q add "$TMP/wt-live" fix "Live" >/dev/null; Q add "$TMP/wt2-orphaned" fix "Orphaned" >/dev/null
echo "$TMP/no-such-checkout" > "$RQ2/checkout"
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 PATH="$TQ/bin:$PATH" timeout 120 bash "$ROOT/scripts/pr-queue.sh" run </dev/null 2>&1)"; rc=$?
assert "given up: the runner ends"           test "$rc" != 124
assert_contains "given up: the other repo's job ran" "$out" "FAILED fix/live"
assert_contains "given up: says why"         "$out" "$TMP/no-such-checkout is not a git checkout"
assert_contains "given up: says which queue has jobs left" "$out" "jobs left in the queue of: repo2 (see above)"
assert "given up: its job still queued"      test -n "$(find "$RQ2/queue" -name '*orphaned.job')"
echo "$R2" > "$RQ2/checkout"; rm -f "$RQ2"/queue/*
# A repo whose folder has the same name as another repo's gets a queue of its own.
mkdir -p "$TMP/elsewhere"; git clone -q "$TMP/origin.git" "$TMP/elsewhere/repo" 2>/dev/null
git -C "$TMP/elsewhere/repo" worktree add -q "$TMP/wt3-same" -b fix/same origin/main 2>/dev/null
echo same > "$TMP/wt3-same/same.txt"; git -C "$TMP/wt3-same" add -A; git -C "$TMP/wt3-same" commit -q -m same
out="$(Q add "$TMP/wt3-same" fix "Same")"
assert_contains "same name: a queue of its own" "$out" "in the queue of repo-"
assert "same name: not in the first repo's"  test -z "$(find "$RQ/queue" -name '*same.job')"
rm -rf "$PR_QUEUE_DIR"/repos/repo-*

# A signal to the runner of several repos stops each repo's runner, its job and its review sessions before it
# ends itself: a Ctrl-C (INT to its process group), a kill (TERM) or a hangup (HUP) of its pid.
for sig in INT TERM HUP; do
  reset_pr; rm -rf "$TQ/hung" "$TQ/tmp"; mkdir -p "$TQ/tmp"; touch "$TQ/hang"; mkwt "sig$sig"; mkwt2 "sig2$sig"
  Q add "$TMP/wt-sig$sig" fix "A" >/dev/null; Q add "$TMP/wt2-sig2$sig" fix "B" >/dev/null
  # A long poll: the signal must end the runner's sleep, not wait for it.
  PR_QUEUE_POLL=30 PATH="$TQ/bin:$PATH" TMPDIR="$TQ/tmp" python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$ROOT/scripts/pr-queue.sh" run </dev/null >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 100); do [ "$(wc -l 2>/dev/null < "$TQ/hung")" = 4 ] && break; sleep 0.1; done
  assert "several repos, $sig: all four sessions started" test "$(wc -l < "$TQ/hung")" = 4
  t0=$SECONDS
  if [ "$sig" = INT ]; then kill -INT -- "-$rpid"; else kill -"$sig" "$rpid"; fi
  { wait "$rpid"; } 2>/dev/null; rc=$?
  took=$((SECONDS - t0))
  alive_at_exit=""; while read -r p; do gone "$p" || alive_at_exit=1; done < "$TQ/hung"
  case "$sig" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
  assert "several repos, $sig: ends by SIG$sig" test "$rc" = "$code"
  assert "several repos, $sig: every session stopped before it ended" test -z "$alive_at_exit"
  assert "several repos, $sig: at once, not after the sessions' 30 s" test "$took" -lt 10
  assert "several repos, $sig: no temp files left" test -z "$(ls -A "$TQ/tmp")"
  assert "several repos, $sig: both runners' locks free" flock -n "$RQ/run.lock" flock -n "$RQ2/run.lock" true
  rm -f "$TQ/hang" "$RQ"/running/* "$RQ2"/running/*
done

# --- jobs of the old single queue move to their repos' queues ---
reset_pr; mkwt old; old_branch_job() { printf 'worktree=%s\nbranch=%s\ntype=fix\ndescription=x\nreview=\ntests=\n' "$1" "$2"; }
mkdir -p "$PR_QUEUE_DIR/queue" "$PR_QUEUE_DIR/running" "$PR_QUEUE_DIR/failed" "$PR_QUEUE_DIR/done"
old_branch_job "$TMP/wt-old" fix/old > "$PR_QUEUE_DIR/queue/1-fix-old.job"; echo body > "$PR_QUEUE_DIR/queue/1-fix-old.body"
old_branch_job "$TMP/wt-old" fix/old > "$PR_QUEUE_DIR/running/2-fix-old.job"
old_branch_job "$TMP/gone" fix/gone > "$PR_QUEUE_DIR/failed/3-fix-gone.job"
flock "$PR_QUEUE_DIR/run.lock" sleep 2 & sleep 0.3
out="$(Q status)"
assert_contains "old queue: kept while an old runner works on it" "$out" "a runner of the old version still works"
assert "old queue: not moved yet"            test -f "$PR_QUEUE_DIR/queue/1-fix-old.job"
wait
out="$(Q status)"
assert "old queue: a job to its repo's queue" test -f "$RQ/queue/1-fix-old.job"
assert "old queue: with its body"            test -f "$RQ/queue/1-fix-old.body"
assert "old queue: an unfinished job to failed/" test -f "$RQ/failed/2-fix-old.job"
assert "old queue: an unknown repo's job kept apart" test -f "$PR_QUEUE_DIR/legacy/failed/3-fix-gone.job"
assert "old queue: its folders removed"      test ! -e "$PR_QUEUE_DIR/queue" -a ! -e "$PR_QUEUE_DIR/running"
assert_not_contains "old queue: no notice after" "$out" "old version"
rm -f "$RQ"/queue/* "$RQ/failed/2-fix-old.job"
# `add` and `run` move the old queue's jobs too: a re-queue keeps the --review of its job in the old failed/.
reset_pr; mkwt oldflags; mkdir -p "$PR_QUEUE_DIR/failed"
printf 'worktree=%s\nbranch=fix/oldflags\ntype=fix\ndescription=x\nreview=high\ntests=\n' "$TMP/wt-oldflags" \
  > "$PR_QUEUE_DIR/failed/4-fix-oldflags.job"
out="$(Q add "$TMP/wt-oldflags" fix "Old flags")"
assert_contains "old queue: add moves it, so the re-queue keeps --review" "$out" "keeping --review high from the earlier job"
assert "old queue: add moved it"             test ! -e "$PR_QUEUE_DIR/failed"
rm -f "$RQ"/queue/* "$RQ"/failed/*oldflags*
reset_pr; touch "$TQ/e2e_fail"; mkwt oldrun; mkdir -p "$PR_QUEUE_DIR/queue"
old_branch_job "$TMP/wt-oldrun" fix/oldrun > "$PR_QUEUE_DIR/queue/5-fix-oldrun.job"
out="$(PR_QUEUE_REVIEW=0 PR_QUEUE_TEST_REVIEW=0 Q run)"
assert_contains "old queue: run moves its jobs and runs them" "$out" "FAILED fix/oldrun"
assert "old queue: run moved it"             test ! -e "$PR_QUEUE_DIR/queue"
# While a runner of the old version holds the old lock, `run` refuses: it could run a second job of a repo.
reset_pr; mkwt oldlock; Q add "$TMP/wt-oldlock" fix "Old lock" >/dev/null
flock "$PR_QUEUE_DIR/run.lock" sleep 2 & sleep 0.3
out="$(Q run)"; rc=$?
assert_contains "old runner: run refuses"    "$out" "a runner of the old version (one queue for all repos) is still working"
assert "old runner: exits with an error"     test "$rc" = 1
assert "old runner: the job stays queued"    test -n "$(find "$RQ/queue" -name '*oldlock.job')"
wait; rm -f "$RQ"/queue/*
out="$(Q lock echo hi)";                     assert_contains "lock runs the command" "$out" "hi"
out="$(Q bogus)";                            assert_contains "usage on a bad command" "$out" "pr-queue.sh add"

finish
