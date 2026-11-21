# shellcheck shell=bash
# Tests for pr-queue.sh: a local bare origin, worktrees, and stub gh/node/npm (no network).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export TQ="$TMP/t" PR_QUEUE_DIR="$TMP/state" PR_QUEUE_CHECKS_WAIT=0
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
cat > "$TQ/bin/npm" <<'EOF'
#!/usr/bin/env bash
if flock -n "$PR_QUEUE_DIR/e2e.lock" true; then echo "$* unlocked" >> "$TQ/npm.log"; else echo "$* locked" >> "$TQ/npm.log"; fi
[ -f "$TQ/e2e_fail" ] && exit 1
touch "$TQ/passed/$(git rev-parse HEAD)"
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
  rm -f "$TQ/pr_state" "$TQ/pr_body" "$TQ/pr_branch" "$TQ/checks_seq" "$TQ/e2e_fail" "$TQ/merge_fail" "$TQ/head_lag" "$TQ/on_checks"
  : > "$TQ/gh.log"; : > "$TQ/created.log"; : > "$TQ/npm.log"
}
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

# Old root path still works (compat link for agents prompted with it)
assert "root pr-queue.sh links to scripts/" test "$(readlink -f "$ROOT/pr-queue.sh")" = "$ROOT/scripts/pr-queue.sh"

finish
