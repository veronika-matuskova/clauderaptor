# shellcheck shell=bash
# Tests for pr-queue.sh: a local bare origin, worktrees, and stub gh/node/npm (no network).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export TQ="$TMP/t" PR_QUEUE_DIR="$TMP/state" PR_QUEUE_CHECKS_WAIT=0
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
# npm run test:e2e:full: records whether it ran under the e2e lock, then passes unless $TQ/e2e_fail exists.
# $TQ/on_e2e: a script run once, first.
cat > "$TQ/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ -f "$TQ/on_e2e" ] && { bash "$TQ/on_e2e"; rm -f "$TQ/on_e2e"; }
if flock -n "$PR_QUEUE_DIR/e2e.lock" true; then echo "$* unlocked" >> "$TQ/npm.log"; else echo "$* locked" >> "$TQ/npm.log"; fi
[ -f "$TQ/e2e_fail" ] && exit 1
touch "$TQ/passed/$(git rev-parse HEAD)"
EOF
# claude -p (run by review.sh): logs "code <prompt>" for a code review, "tests <first line>" for a test review,
# and reports the verdict in $TQ/verdict or $TQ/tests_verdict (default ready). $TQ/claude_fail makes both fail.
# With $TQ/sync, each session waits up to 5 s for the other one to start, and logs in sync.log if it did.
# With $TQ/hang, each session logs its pid in $TQ/hung and hangs for 30 s; on TERM it takes 0.5 s to end.
cat > "$TQ/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$2" == *"code-review skill"* ]]; then
  kind=code other=tests; echo "code $2" >> "$TQ/claude.log"; v="$(cat "$TQ/verdict" 2>/dev/null || echo ready)"
else
  kind=tests other=code; echo "tests ${2%%$'\n'*}" >> "$TQ/claude.log"; v="$(cat "$TQ/tests_verdict" 2>/dev/null || echo ready)"
fi
[ -f "$TQ/claude_fail" ] && exit 1
if [ -f "$TQ/hang" ]; then trap 'sleep 0.5; exit 1' TERM; echo "$$" >> "$TQ/hung"; sleep 30; fi
if [ -f "$TQ/sync" ]; then
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
    "$TQ/verdict" "$TQ/tests_verdict" "$TQ/claude_fail" "$TQ/sync" "$TQ"/started-* "$TQ/sync.log"
  : > "$TQ/gh.log"; : > "$TQ/created.log"; : > "$TQ/npm.log"; : > "$TQ/claude.log"
}
# code_reviews / test_reviews: the review sessions claude.log shows since the last reset
code_reviews() { grep '^code ' "$TQ/claude.log"; }
test_reviews() { grep '^tests ' "$TQ/claude.log"; }
# called through assert
# shellcheck disable=SC2329
in_done() { test -n "$(find "$PR_QUEUE_DIR/done" -name "*$1.job")"; }
# shellcheck disable=SC2329
in_failed() { test -n "$(find "$PR_QUEUE_DIR/failed" -name "*$1.job")"; }

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
assert "happy: nothing left running"         test -z "$(find "$PR_QUEUE_DIR/running" -type f)"
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
assert "similar names: one job each"         test "$(find "$PR_QUEUE_DIR/queue" -name '*.job' | wc -l)" = 2
rm -f "$PR_QUEUE_DIR"/queue/*

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
    if [ -z "$alive" ] && [ -z "$(ls -A "$TQ/tmp")" ] && flock -n "$PR_QUEUE_DIR/run.lock" true; then break; fi
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
  assert "$sig: the job stayed in running/"      test -n "$(find "$PR_QUEUE_DIR/running" -name "*stop$sig.job")"
  assert "$sig: the runner's lock is free again" flock -n "$PR_QUEUE_DIR/run.lock" true
  rm -f "$PR_QUEUE_DIR"/running/*
done
# A Ctrl-C reaches the job too, so the runner ends only once both sessions have.
stop_runner INT stopINT2
assert "INT: the sessions ended before the runner" test -z "$alive_at_exit"
rm -f "$PR_QUEUE_DIR"/running/*

# --- a job left in running/ by a dead runner goes to failed/ ---
printf 'worktree=/x\nbranch=fix/dead\n' > "$PR_QUEUE_DIR/running/1-fix-dead.job"
out="$(Q run)";                              assert_contains "dead runner: reported" "$out" "fix/dead was left unfinished"
assert "dead runner: job in failed/"         in_failed dead

# --- one runner at a time, and the lock command ---
flock "$PR_QUEUE_DIR/run.lock" sleep 2 & sleep 0.3
out="$(Q run)";                              assert_contains "second runner exits" "$out" "already working on the queue"
wait
out="$(Q lock echo hi)";                     assert_contains "lock runs the command" "$out" "hi"
out="$(Q bogus)";                            assert_contains "usage on a bad command" "$out" "pr-queue.sh add"

finish
