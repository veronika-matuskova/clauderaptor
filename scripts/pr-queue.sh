#!/usr/bin/env bash
# A queue that turns finished branches into merged PRs, one at a time, so agents can build in parallel
# without testing against a main that moves under them.
#
#   pr-queue.sh add [--review <level>] <worktree> <type> "<description>" [body-file]   queue a committed branch
#   pr-queue.sh run                                                  work through the queue until it is empty
#   pr-queue.sh status                                               show the queue and the last results
#   pr-queue.sh lock <command...>                                    run a command holding the e2e lock
#
# For each job, `run` does, in order:
#   1. merge origin/main into the branch (a conflict fails the job and is aborted);
#   2. review it with scripts/review.sh: the built-in /code-review in a fresh `claude -p` session, at the job's
#      level (add --review low|medium|high|xhigh, else $PR_QUEUE_REVIEW, else medium). "Needs changes" fails the
#      job; the review is saved in $REVIEW_DIR (default $PR_QUEUE_DIR/reviews). A commit already reviewed as
#      ready at that level isn't reviewed again. PR_QUEUE_REVIEW=0 skips this step, except for jobs queued
#      with --review;
#   3. if the repo has scripts/e2e-gate.mjs and the commit has no local pass: `npm run test:e2e:full`, under the lock;
#   4. open the PR (scripts/create-pr.sh <type> "<description>" if the repo has it, else gh pr create), or push to
#      the open one; the body is the body file (else the current one) with a "Local end-to-end run" section for
#      the commit being pushed, set before the push because CI reads it;
#   5. wait until GitHub shows that commit as the PR's head, then until its checks are done (a failed or
#      cancelled check fails the job);
#   6. squash-merge exactly that commit, then remove the worktree and branch (kept if the branch has newer
#      commits), delete the remote branch and pull the main checkout.
# Main only moves when the queue merges, so each branch is tested once, on the commit that gets merged.
# PR_QUEUE_MERGE=0 stops after the checks pass and leaves the PR open.
# PR_QUEUE_CHECKS_TIMEOUT (seconds, default 3600) fails the job when checks are still pending after that long.
# State (jobs, logs, results, the locks) lives in $PR_QUEUE_DIR (default ${XDG_STATE_HOME:-~/.local/state}/pr-queue).
set -uo pipefail

STATE="${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}"
QUEUE="$STATE/queue"; RUNNING="$STATE/running"; LOGS="$STATE/logs"; RESULTS="$STATE/results.log"
mkdir -p "$QUEUE" "$RUNNING" "$LOGS" "$STATE/done" "$STATE/failed"
PASS_HEADING='## Local end-to-end run'
CHECKS_WAIT="${PR_QUEUE_CHECKS_WAIT:-30}"
REVIEWS="${REVIEW_DIR:-$STATE/reviews}"
HERE="$(dirname "$(readlink -f "$0")")"
CHECKS_TIMEOUT="${PR_QUEUE_CHECKS_TIMEOUT:-3600}"

die() { echo "pr-queue: $*" >&2; exit 1; }
usage() { sed -n 's/^#   \(pr-queue\.sh .*\)/  \1/p' "$0"; exit 1; }

field() { sed -n "s/^$1=//p" "$2" | head -1; }
# jobs_for <dir> <branch>: the job files in dir for exactly that branch.
jobs_for() {
  local job
  for job in "$1"/*.job; do
    if [ -f "$job" ] && [ "$(field branch "$job")" = "$2" ]; then echo "$job"; fi
  done
}

add() {
  local review=""
  if [ "${1:-}" = --review ]; then
    review="${2:-}"; shift 2 || usage
    case "$review" in low|medium|high|xhigh) ;; *) die "--review takes low, medium, high or xhigh, not '$review'" ;; esac
  fi
  [ $# -ge 3 ] || usage
  local wt type="$2" desc="$3" body="${4:-}" branch job file
  [ -d "$1" ] || die "no such directory: $1"
  wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
  branch="$(git -C "$wt" branch --show-current)"
  [ -n "$branch" ] || die "$wt is not on a branch"
  [ "$branch" != main ] || die "$wt is on main; queue a feature branch"
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "$wt has uncommitted changes; commit them first"
  [ -n "$(git -C "$wt" log --oneline origin/main..HEAD 2>/dev/null)" ] || die "$branch has no commits ahead of origin/main"
  if [ -z "$type" ] || [ -z "$desc" ]; then die "type and description must not be empty"; fi
  if [ -n "$body" ]; then [ -f "$body" ] || die "no such body file: $body"; fi
  # Re-queueing a branch (after a fix) replaces its old job.
  while read -r job; do rm -f "$job" "${job%.job}.body"; done < <(jobs_for "$QUEUE" "$branch")
  if [ -n "$(jobs_for "$RUNNING" "$branch")" ]; then
    echo "pr-queue: $branch is being processed now; this commit is queued to follow (its worktree and branch are kept)"
  fi
  file="$QUEUE/$(date +%s%N)-${branch//\//-}"
  if [ -n "$body" ]; then cp "$body" "$file.body"; fi
  printf 'worktree=%s\nbranch=%s\ntype=%s\ndescription=%s\nreview=%s\n' "$wt" "$branch" "$type" "$desc" "$review" > "$file.job"
  echo "pr-queue: queued $branch ($(find "$QUEUE" -name '*.job' | wc -l) in the queue)"
}

# with_line <body-file> <line>: the body without its old "Local end-to-end run" section, plus one for the line.
with_line() {
  awk -v h="$PASS_HEADING" '$0 == h { skip = 1; next } skip && /^## / { skip = 0 } !skip { out[++n] = $0 }
    END { while (n > 0 && out[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print out[i] }' "$1"
  if [ -n "$2" ]; then printf '\n%s\n\n%s\n' "$PASS_HEADING" "$2"; fi
}

# Logs a step's output; on failure records the reason, moves the job to failed/ and returns 1.
JOB=""; LOG=""; BRANCH=""
failjob() {
  echo "$(date '+%F %T') FAILED $BRANCH: $1 (log: $LOG)" | tee -a "$RESULTS"
  mv "$JOB.job" "$STATE/failed/" 2>/dev/null
  if [ -f "$JOB.body" ]; then mv "$JOB.body" "$STATE/failed/"; fi
  return 1
}
finishjob() { mv "$JOB.job" "$STATE/done/"; rm -f "$JOB.body"; }

process() {
  JOB="${1%.job}"
  local wt type desc pr sha line main_dir merged level review review_rc reviewed="" file tries=0
  wt="$(field worktree "$1")"; BRANCH="$(field branch "$1")"; type="$(field type "$1")"; desc="$(field description "$1")"
  LOG="$LOGS/$BRANCH.log"; mkdir -p "$(dirname "$LOG")"
  echo "== $(date '+%F %T') $BRANCH" | tee -a "$LOG"
  cd "$wt" 2>/dev/null || { failjob "worktree $wt is gone"; return; }
  [ "$(git branch --show-current)" = "$BRANCH" ] || { failjob "$wt is no longer on $BRANCH"; return; }
  [ -z "$(git status --porcelain)" ] || { failjob "uncommitted changes in $wt"; return; }

  # 1. Up to date with main.
  git fetch -q origin >>"$LOG" 2>&1 || { failjob "git fetch failed"; return; }
  if ! git merge-base --is-ancestor origin/main HEAD; then
    if ! git merge --no-edit -q origin/main >>"$LOG" 2>&1; then
      local files; files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git merge --abort >>"$LOG" 2>&1
      failjob "merge conflict with origin/main in: ${files% }"; return
    fi
    echo "   merged origin/main" | tee -a "$LOG"
  fi

  # 2. Review, in a fresh session, before the e2e run is spent on it.
  level="$(field review "$1")"
  if [ "${PR_QUEUE_REVIEW:-}" != 0 ] || [ -n "$level" ]; then
    level="${level:-${PR_QUEUE_REVIEW:-medium}}"
    reviewed="$(git rev-parse HEAD)"
    echo "   reviewing $(git rev-parse --short HEAD) (/code-review $level)" | tee -a "$LOG"
    review="$(REVIEW_DIR="$REVIEWS" "$HERE/review.sh" "$wt" "$level" 2>&1)"; review_rc=$?
    printf '%s\n' "$review" >> "$LOG"
    if grep -qx 'already reviewed as ready' <<<"$review"; then echo "   already reviewed as ready" | tee -a "$LOG"; fi
    file="$(sed -n 's/^(saved to \(.*\))$/\1/p' <<<"$review" | tail -1)"
    if [ "$review_rc" -eq 1 ] && [ -n "$file" ]; then failjob "the review found changes to make (review: $file)"; return; fi
    [ "$review_rc" -eq 0 ] || { failjob "the review didn't run: $(tail -1 <<<"$review")"; return; }
  fi

  # 3. The full local suite, once, on this exact commit.
  line=""
  if [ -f scripts/e2e-gate.mjs ]; then
    if ! node scripts/e2e-gate.mjs pr-line >/dev/null 2>&1; then
      echo "   running the full e2e suite on $(git rev-parse --short HEAD)" | tee -a "$LOG"
      flock "$STATE/e2e.lock" npm run test:e2e:full >>"$LOG" 2>&1 || { failjob "the full e2e suite failed"; return; }
    fi
    line="$(node scripts/e2e-gate.mjs pr-line 2>>"$LOG")" || { failjob "no local e2e pass recorded for $(git rev-parse --short HEAD)"; return; }
  fi
  sha="$(git rev-parse HEAD)"
  if [ -n "$reviewed" ] && [ "$sha" != "$reviewed" ]; then
    failjob "$BRANCH got commits after the review; queue it again to review them"; return
  fi

  # 4. Open the PR, or update the open one. The body goes first: CI reads it when the push arrives.
  pr="$(gh pr view "$BRANCH" --json number,state -q 'select(.state=="OPEN") | .number' 2>/dev/null)"
  if [ -n "$pr" ]; then
    if [ -f "$JOB.body" ]; then cp "$JOB.body" "$JOB.base"; else gh pr view "$pr" --json body -q .body > "$JOB.base" 2>>"$LOG"; fi
    with_line "$JOB.base" "$line" > "$JOB.newbody"
    gh pr edit "$pr" --body-file "$JOB.newbody" >>"$LOG" 2>&1 || echo "   could not set the body of #$pr" | tee -a "$LOG"
    rm -f "$JOB.base" "$JOB.newbody"
    git push -q origin "HEAD:$BRANCH" >>"$LOG" 2>&1 || { failjob "git push failed"; return; }
  elif [ -x scripts/create-pr.sh ]; then
    GH_BROWSER=true BROWSER=true scripts/create-pr.sh "$type" "$desc" </dev/null >>"$LOG" 2>&1 \
      || { failjob "scripts/create-pr.sh failed"; return; }
    pr="$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null)"
    if [ -n "$pr" ] && [ -f "$JOB.body" ]; then
      with_line "$JOB.body" "$line" > "$JOB.newbody"
      gh pr edit "$pr" --body-file "$JOB.newbody" >>"$LOG" 2>&1 || echo "   could not set the body of #$pr" | tee -a "$LOG"
      rm -f "$JOB.newbody"
    fi
  else
    git push -q -u origin "HEAD:$BRANCH" >>"$LOG" 2>&1 || { failjob "git push failed"; return; }
    if [ -f "$JOB.body" ]; then with_line "$JOB.body" "$line"; else with_line /dev/null "$line"; fi > "$JOB.newbody"
    gh pr create --base main --head "$BRANCH" --title "$type: $desc" --body-file "$JOB.newbody" >>"$LOG" 2>&1
    local rc=$?; rm -f "$JOB.newbody"
    [ $rc -eq 0 ] || { failjob "gh pr create failed"; return; }
  fi
  pr="$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null)"
  [ -n "$pr" ] || { failjob "no PR found for $BRANCH"; return; }

  # 5. Checks of this commit, not of the PR's previous head.
  until [ "$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)" = "$sha" ]; do
    tries=$((tries + 1)); [ $tries -lt 10 ] || { failjob "#$pr does not show $sha as its head"; return; }
    sleep "$CHECKS_WAIT"
  done
  echo "   PR #$pr, waiting for the checks" | tee -a "$LOG"
  # Done when some are reported and none is pending, twice in a row (a workflow can start late).
  # A check that stays pending (a stuck runner, a workflow that never starts) fails the job at the deadline,
  # so it can't block the queue.
  local checks bad pending passes=0 deadline=$((SECONDS + CHECKS_TIMEOUT)) waited; tries=0
  if [ $((CHECKS_TIMEOUT % 60)) -eq 0 ]; then waited="$((CHECKS_TIMEOUT / 60))m"; else waited="${CHECKS_TIMEOUT}s"; fi
  while :; do
    checks="$(gh pr checks "$pr" --json name,bucket -q '.[] | "\(.bucket)\t\(.name)"' 2>>"$LOG")"
    [ -n "$checks" ] && echo "$checks" >> "$LOG"
    bad="$(awk -F'\t' '$1 == "fail" || $1 == "cancel" { print $2 }' <<<"$checks" | sort -u | paste -sd, -)"
    [ -z "$bad" ] || { failjob "checks failed on #$pr: $bad"; return; }
    if [ -z "$checks" ]; then
      passes=0; tries=$((tries + 1))
      [ $tries -lt 10 ] || { failjob "no checks reported on #$pr"; return; }
    elif grep -q '^pending' <<<"$checks"; then
      passes=0
      if [ "$SECONDS" -ge "$deadline" ]; then
        pending="$(awk -F'\t' '$1 == "pending" { print $2 }' <<<"$checks" | sort -u | paste -sd, -)"
        failjob "checks still pending on #$pr after $waited: $pending"; return
      fi
    else
      passes=$((passes + 1)); [ $passes -lt 2 ] || break
    fi
    sleep "$CHECKS_WAIT"
  done

  # 6. Merge exactly the tested commit, and clean up.
  if [ "${PR_QUEUE_MERGE:-1}" = 0 ]; then
    echo "$(date '+%F %T') READY $BRANCH: #$pr passed, left open (PR_QUEUE_MERGE=0)" | tee -a "$RESULTS"
    finishjob; return
  fi
  gh pr merge "$pr" --squash --match-head-commit "$sha" >>"$LOG" 2>&1
  [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ] || { failjob "merging #$pr failed"; return; }
  merged="$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)"
  main_dir="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
  cd "$main_dir" || return
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    git worktree remove "$wt" >>"$LOG" 2>&1 || echo "   left the worktree $wt (not clean)" | tee -a "$LOG"
    git branch -D -q "$BRANCH" >>"$LOG" 2>&1
    git push -q origin --delete "$BRANCH" >>"$LOG" 2>&1 || true
  else
    echo "   $BRANCH has commits after the merged $(git rev-parse --short "$sha"); kept the worktree and branch" | tee -a "$LOG"
  fi
  # Untracked files don't block the pull (a fast-forward refuses to overwrite them); changes to tracked files do.
  if [ "$(git branch --show-current)" = main ] && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
    git pull -q --ff-only >>"$LOG" 2>&1 || echo "   could not pull $main_dir" | tee -a "$LOG"
  else
    echo "   did not pull $main_dir: it is not on main or has changes to tracked files" | tee -a "$LOG"
  fi
  echo "$(date '+%F %T') MERGED $BRANCH: #$pr as ${merged:0:7}" | tee -a "$RESULTS"
  finishjob
}

run() {
  case "${PR_QUEUE_REVIEW:-medium}" in
    0|low|medium|high|xhigh) ;;
    *) die "PR_QUEUE_REVIEW must be 0 (no reviews), low, medium, high or xhigh, not '$PR_QUEUE_REVIEW'" ;;
  esac
  exec 9>"$STATE/run.lock"
  flock -n 9 || { echo "pr-queue: a runner is already working on the queue"; exit 0; }
  local job name
  # Jobs left in running/ belong to a runner that died (we hold the lock).
  for job in "$RUNNING"/*.job; do
    [ -f "$job" ] || continue
    echo "pr-queue: $(field branch "$job") was left unfinished by an earlier runner; moved to failed/"
    mv "${job%.job}".* "$STATE/failed/"
  done
  while job="$(find "$QUEUE" -name '*.job' | sort | head -1)"; [ -n "$job" ]; do
    name="$(basename "${job%.job}")"
    mv "${job%.job}".* "$RUNNING/"
    ( process "$RUNNING/$name.job" ) || true
    # A job that left its file behind (a crash) must not loop forever.
    if [ -f "$RUNNING/$name.job" ]; then
      echo "pr-queue: $name did not finish; moved to failed/"; mv "$RUNNING/$name".* "$STATE/failed/"
    fi
  done
  echo "pr-queue: the queue is empty"
}

status() {
  local job
  echo "Running:"; for job in "$RUNNING"/*.job; do [ -f "$job" ] && echo "  $(field branch "$job")"; done
  echo "Queued:"; find "$QUEUE" -name '*.job' | sort | while read -r job; do echo "  $(field branch "$job")"; done
  echo "Last results:"; tail -n "${1:-10}" "$RESULTS" 2>/dev/null | sed 's/^/  /'
}

case "${1:-}" in
  add) shift; add "$@" ;;
  run) run ;;
  status) shift; status "$@" ;;
  lock) shift; [ $# -ge 1 ] || usage; exec flock "$STATE/e2e.lock" "$@" ;;
  *) usage ;;
esac
