#!/usr/bin/env bash
# A queue that turns finished branches into merged PRs, one at a time, so agents can build in parallel
# without testing against a main that moves under them.
#
#   pr-queue.sh add [--review <level>] [--tests on|none] [--brief <file>|none] <worktree> <type> "<description>" [body-file]   queue a committed branch
#   pr-queue.sh run [<checkout>]                                     work through the queues until they are empty
#   pr-queue.sh status                                               show the queues and their last results
#   pr-queue.sh lock <command...>                                    run a command holding the e2e lock
#
# For each job, `run` does, in order:
#   1. merge origin/main into the branch (a conflict fails the job and is aborted);
#   2. review it with scripts/queue/review.sh, in two fresh `claude -p` sessions at the same time:
#      - the code, with the built-in /code-review at the job's level (add --review low|medium|high|xhigh, or
#        none to skip it for that job. Else $PR_QUEUE_REVIEW, else medium). PR_QUEUE_REVIEW=0 skips it (only
#        the code review), except for jobs queued with --review;
#      - the tests (review.sh --tests: mutation check, missing, empty, duplicate and non-atomic tests).
#        add --tests none skips it for that job. PR_QUEUE_TEST_REVIEW=0 skips it, except for jobs queued with
#        --tests on.
#      add --brief <file> (a brief from review.sh --plan, approved by the user) gives both reviews the change's
#      requirements and acceptance criteria, which they check it against, and the judge, which checks the
#      findings that name a criterion (REVIEW_BRIEF). A re-queue of the branch keeps its --review, --tests and
#      --brief: the brief only from its latest job, if that one didn't merge (--brief none drops it). The job waits for both reviews, even when one
#      fails early, so the branch's agent gets all the findings in one round. A review that didn't run fails
#      the job. "Needs changes" from either one goes to a judge (review.sh --judge, a third fresh session),
#      which keeps only the findings that are real and worth fixing:
#      - ready: nothing to fix, the job goes on;
#      - needs changes: fails the job with "the judge confirmed changes to make (judge: <file>)", the agent's
#        To fix list;
#      - escalate (it rejected a finding that would be critical if real), or a second judged round with changes
#        to make: fails the job with "needs your decision", for the user, not the agent.
#      PR_QUEUE_JUDGE=0 skips the judge: "needs changes" then fails the job as it is. The reviews and the
#      judgements are saved in $REVIEW_DIR (default $PR_QUEUE_DIR/reviews), and the failure names them. A
#      commit already reviewed (the code: at that level) or judged as ready isn't reviewed or judged again.
#      A review may ask for a sniff of a claim it doubts: a line "Sniff: <claim> | <where> | <why>" (a list or
#      emphasis prefix allowed). After both reviews end (a cached ready one too), before the judge, the queue
#      checks them with sniff.sh at the reviewed commit, mechanically (no session; line k of its input is the k-th
#      request's "<claim> | <where>"), and appends each review's accepted, refused and already-sniffed requests and
#      the flags to $REVIEW_DIR/<branch>-<sha>-sniff.md, which the judge (REVIEW_SNIFF) and the branch's next
#      reviews get. A line without three non-empty parts, or one past max_sniff_requests per review (in sniff.conf,
#      or $SNIFF_CONFIG; a missing or invalid value: no line runs, a note says why), is refused, with a log line; a
#      claim already sniffed at that commit isn't sniffed again, but the hard flags of every sniff in that file count
#      (a re-queue of the same commit fails on them again). The judge's and the sniff's own output are never
#      read for Sniff: lines. A hard flag fails the job (step review, reason sniff: "the sniff of the reviews'
#      requests has <n> hard flag(s) (sniff: <file>)") if the judge lets it go on, and ends the message of any
#      other failure of this step ("; the sniff has <n> hard flag(s) ..."); soft flags only add a line to the log,
#      and a sniff that didn't run (sniff.sh exit 4) only "the sniff didn't run: <reason>". No Sniff: line: no sniff.
#      A Ctrl-C of the runner, a hangup, or a TERM to its whole process group (kill -- -<pgid>), stops the
#      reviews, the judge and their sessions; a kill of the runner's pid alone leaves its job running;
#   3. if the repo has scripts/e2e-gate.mjs and the commit has no local pass: `npm run test:e2e:full`, under the lock.
#      First, under the lock, a speed check: a fixed CPU benchmark (the fastest of 3 runs of a python3 loop, in
#      CPU-seconds, which a normal load hardly changes but a throttled machine raises many times), or the command
#      $PR_QUEUE_BENCH (on PATH, prints one number). Its result against the median of the last 20 accepted ones,
#      kept in $PR_QUEUE_DIR/speed-baseline (shared by all repos: it describes the machine; the first one, or a
#      file without a valid number, starts it anew):
#      - at most $PR_QUEUE_SPEED_MAX (default 4) times the baseline: it is added to the file, and e2e runs;
#      - above: it waits $PR_QUEUE_SPEED_WAIT seconds (default 300), still holding the lock, and checks again, up
#        to 6 times; still slow after that fails the job (slow_machine): the machine, not the branch. A slow
#        result is never stored.
#      A benchmark that fails or prints no number leaves e2e to run without it. PR_QUEUE_SPEED_MAX=0 turns it off;
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
# Each repo has its own queue, so one repo's jobs never wait for another's: `run` starts a runner for every
# repo with jobs, side by side, and while any works, one for each repo that gets jobs (it looks every
# PR_QUEUE_POLL seconds, default 5) until no repo has any. A repo whose queue another runner has is looked at
# again each time, so it gets a runner once that one ends. `run <checkout>` works only on that checkout's
# repo. Neither starts while a runner of the old version holds its lock. A repo is its main checkout; it is
# named after that folder. Only the e2e lock (`lock`, step 3) is shared by all repos: it
# guards the machine's one local test stack.
# State lives in $PR_QUEUE_DIR (default ${XDG_STATE_HOME:-~/.local/state}/pr-queue): repos/<repo>/ holds a
# repo's jobs (queue, running, done, failed), logs, results.log and run.lock; e2e.lock and reviews/ are shared.
# Jobs of the old single queue ($PR_QUEUE_DIR/queue, ...) move to their repo's queue once no runner of the
# old version holds $PR_QUEUE_DIR/run.lock.
# Each step also appends a stats event (scripts/queue/events.sh: one JSON line, ids and numbers only) to
# $STATS_EVENTS_FILE (default $PR_QUEUE_DIR/events.jsonl), for the local stats collector; STATS_EVENTS=0 turns
# them off. An event that can't be written is skipped, and never changes what the queue does. A job ends with
# merged, job_ready (PR_QUEUE_MERGE=0) or job_failed {step, reason} (the reasons: see failjob); job_failed of a
# review or a judge also has found, the reviews that found changes (code, tests).
# While a repo's runner works on a job, it keeps Windows from sleeping or throttling the WSL VM: just before the
# job it starts a helper, `powershell.exe -NoProfile -NonInteractive -Command <script>`, that holds a "system
# required" request (SetThreadExecutionState(0x80000001): ES_CONTINUOUS | ES_SYSTEM_REQUIRED, not the display),
# one per job. It holds it until its stdin reaches EOF, or for 12 hours (43200 s) at most, then exits, and
# Windows drops the request. Its stdin is a pipe only the runner holds (not the job), so the helper ends when the
# job does, and with the runner however that ends (a signal, a crash, kill -9). The idle time between jobs isn't
# covered. Its output goes to $PR_QUEUE_DIR/repos/<repo>/awake.log; a helper that fails changes no job. Without
# powershell.exe on PATH (also off WSL), the runner says once, before its first job,
# "pr-queue: <repo>: powershell.exe not found; Windows is not kept awake while the queue runs", and runs its
# jobs as before. PR_QUEUE_AWAKE=0 turns it off (default 1).
set -uo pipefail

STATE="${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}"
mkdir -p "$STATE/repos"
# Set for the runner `run` starts per repo, which must never start runners itself: one that did would start
# runners without end. Unset at once, so that its jobs (their reviews and tests) don't inherit it.
CHILD="${PR_QUEUE_CHILD:-}"; unset PR_QUEUE_CHILD
PASS_HEADING='## Local end-to-end run'
CHECKS_WAIT="${PR_QUEUE_CHECKS_WAIT:-30}"
REVIEWS="${REVIEW_DIR:-$STATE/reviews}"
HERE="$(dirname "$(readlink -f "$0")")"
CHECKS_TIMEOUT="${PR_QUEUE_CHECKS_TIMEOUT:-3600}"
# Stats events (emit), for the local stats collector; without events.sh, emit does nothing.
EV_REPO=""; EV_BRANCH=""; EV_JOB_ID=""; EV_SHA=""
# shellcheck source=scripts/queue/events.sh
source "$HERE/events.sh" 2>/dev/null || emit() { :; }

die() { echo "pr-queue: $*" >&2; exit 1; }
usage() { sed -n 's/^#   \(pr-queue\.sh .*\)/  \1/p' "$0"; exit 1; }

field() { sed -n "s/^$1=//p" "$2" | head -1; }
# set_repo <repo folder>: work on that repo's queue.
RQ=""; REPO=""; QUEUE=""; RUNNING=""; LOGS=""; RESULTS=""
set_repo() {
  RQ="$1"; REPO="$(basename "$1")"
  QUEUE="$RQ/queue"; RUNNING="$RQ/running"; LOGS="$RQ/logs"; RESULTS="$RQ/results.log"
  mkdir -p "$QUEUE" "$RUNNING" "$LOGS" "$RQ/done" "$RQ/failed"
}
# use_repo <dir>: work on the queue of the repo that dir is a checkout of (a worktree counts as its main
# checkout). Two repos whose folders have the same name get different queues.
use_repo() {
  local main name
  main="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  main="$(dirname "$main")"; name="$(basename "$main")"
  if [ -f "$STATE/repos/$name/checkout" ] && [ "$(cat "$STATE/repos/$name/checkout")" != "$main" ]; then
    name="$name-$(printf '%s' "$main" | cksum | cut -d' ' -f1)"
  fi
  set_repo "$STATE/repos/$name"
  echo "$main" > "$RQ/checkout"
}
# migrate: moves the jobs of the old single queue to their repos' queues (a job of a runner that died to
# failed/), unless a runner of the old version still holds its lock. A job whose worktree is gone, so its repo
# is unknown, goes to $STATE/legacy/.
migrate() {
  local d job dest
  [ -d "$STATE/queue" ] || [ -d "$STATE/running" ] || [ -d "$STATE/failed" ] || [ -d "$STATE/done" ] || return 0
  if ! flock -n -s "$STATE/run.lock" true; then
    echo "pr-queue: a runner of the old version still works on $STATE/queue; its jobs move to their repos' queues when it is done"
    return 0
  fi
  for d in queue running failed "done"; do
    for job in "$STATE/$d"/*.job; do
      [ -f "$job" ] || continue
      if ( use_repo "$(field worktree "$job")" ); then
        use_repo "$(field worktree "$job")"; dest="$RQ/$d"
        if [ "$d" = running ]; then dest="$RQ/failed"; fi
      else
        dest="$STATE/legacy/$d"; mkdir -p "$dest"
      fi
      mv "${job%.job}".* "$dest/"
    done
    rmdir "$STATE/$d" 2>/dev/null
  done
  RQ=""; REPO=""
}
# jobs_for <dir> <branch>: the job files in dir for exactly that branch.
jobs_for() {
  local job
  for job in "$1"/*.job; do
    if [ -f "$job" ] && [ "$(field branch "$job")" = "$2" ]; then echo "$job"; fi
  done
}

add() {
  local review="" tests="" brief=""
  while :; do
    case "${1:-}" in
      --review)
        review="${2:-}"; shift 2 || usage
        case "$review" in none|low|medium|high|xhigh) ;; *) die "--review takes none, low, medium, high or xhigh, not '$review'" ;; esac ;;
      --tests)
        tests="${2:-}"; shift 2 || usage
        case "$tests" in on|none) ;; *) die "--tests takes on or none, not '$tests'" ;; esac ;;
      --brief)
        brief="${2:-}"; shift 2 || usage
        if [ "$brief" != none ] && { [ ! -f "$brief" ] || [ ! -s "$brief" ]; }; then
          die "no such brief, or it's empty: '$brief'"
        fi ;;
      *) break ;;
    esac
  done
  [ $# -ge 3 ] || usage
  local wt type="$2" desc="$3" body="${4:-}" branch job file
  [ -d "$1" ] || die "no such directory: $1"
  wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
  migrate; use_repo "$wt" || die "$1 is not a git checkout"
  branch="$(git -C "$wt" branch --show-current)"
  [ -n "$branch" ] || die "$wt is not on a branch"
  [ "$branch" != main ] || die "$wt is on main; queue a feature branch"
  [ -z "$(git -C "$wt" status --porcelain)" ] || die "$wt has uncommitted changes; commit them first"
  [ -n "$(git -C "$wt" log --oneline origin/main..HEAD 2>/dev/null)" ] || die "$branch has no commits ahead of origin/main"
  if [ -z "$type" ] || [ -z "$desc" ]; then die "type and description must not be empty"; fi
  if [ -n "$body" ]; then [ -f "$body" ] || die "no such body file: $body"; fi
  # Without --review or --tests, keep what the branch's latest earlier job asked for (a fix after a failed review).
  local d old_review="" old_tests="" old_brief=""
  for d in "$RQ/failed" "$RUNNING" "$QUEUE"; do
    while read -r job; do
      [ -n "$job" ] || continue
      if [ -n "$(field review "$job")" ]; then old_review="$(field review "$job")"; fi
      if [ -n "$(field tests "$job")" ]; then old_tests="$(field tests "$job")"; fi
    done < <(jobs_for "$d" "$branch")
  done
  if [ -z "$review" ] && [ -n "$old_review" ]; then
    review="$old_review"; echo "pr-queue: keeping --review $review from the earlier job"
  fi
  if [ -z "$tests" ] && [ -n "$old_tests" ]; then
    tests="$old_tests"; echo "pr-queue: keeping --tests $tests from the earlier job"
  fi
  # The brief: only the branch's latest job's (by its name, which starts with the time it was queued), and
  # not when that one merged, so that a later branch of the same name never gets an old brief.
  local latest=""
  for d in "$RQ/failed" "$RUNNING" "$QUEUE" "$RQ/done"; do
    while read -r job; do
      if [ -n "$job" ] && [[ "$(basename "$job")" > "$(basename "$latest")" ]]; then latest="$job"; fi
    done < <(jobs_for "$d" "$branch")
  done
  if [ -n "$latest" ] && [ "$(dirname "$latest")" != "$RQ/done" ] && [ -f "${latest%.job}.brief" ]; then
    old_brief="${latest%.job}.brief"
  fi
  if [ "$brief" = none ]; then
    brief=""; old_brief=""; echo "pr-queue: no brief for this job"
  fi
  # A copy: the earlier job's files may be removed below, before the new job is written.
  local kept=""
  if [ -z "$brief" ] && [ -n "$old_brief" ]; then
    if ! kept="$(mktemp)" || ! cp "$old_brief" "$kept"; then die "can't keep the brief of the earlier job"; fi
    brief="$kept"; echo "pr-queue: keeping the brief from the earlier job"
  fi
  # Re-queueing a branch (after a fix) replaces its old job.
  # Its event: job_failed, replaced (no sha: the job file doesn't keep its commit; its job_queued has it).
  while read -r job; do
    EV_REPO="$REPO" EV_BRANCH="$branch" EV_JOB_ID="$(basename "${job%.job}")" EV_SHA="" emit job_failed step=queue reason=replaced
    rm -f "$job" "${job%.job}.body" "${job%.job}.brief"
  done < <(jobs_for "$QUEUE" "$branch")
  if [ -n "$(jobs_for "$RUNNING" "$branch")" ]; then
    echo "pr-queue: $branch is being processed now; this commit is queued to follow (its worktree and branch are kept)"
  fi
  file="$QUEUE/$(date +%s%N)-${branch//\//-}"
  if [ -n "$body" ]; then cp "$body" "$file.body"; fi
  if [ -n "$brief" ]; then cp "$brief" "$file.brief" || die "can't store the brief"; fi
  if [ -n "$kept" ]; then rm -f "$kept"; fi
  printf 'worktree=%s\nbranch=%s\ntype=%s\ndescription=%s\nreview=%s\ntests=%s\n' "$wt" "$branch" "$type" "$desc" "$review" "$tests" > "$file.job"
  EV_REPO="$REPO" EV_BRANCH="$branch" EV_JOB_ID="$(basename "$file")" EV_SHA="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" \
    emit job_queued review:opt="$review" tests:opt="$tests" type="$type"
  echo "pr-queue: queued $branch ($(find "$QUEUE" -name '*.job' | wc -l) in the queue of $REPO)"
}

# with_line <body-file> <line>: the body without its old "Local end-to-end run" section, plus one for the line.
with_line() {
  awk -v h="$PASS_HEADING" '$0 == h { skip = 1; next } skip && /^## / { skip = 0 } !skip { out[++n] = $0 }
    END { while (n > 0 && out[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print out[i] }' "$1"
  if [ -n "$2" ]; then printf '\n%s\n\n%s\n' "$PASS_HEADING" "$2"; fi
}

# failjob <step> <reason> <message> [<emit field>...]: records the message, moves the job to failed/ and
# returns 1. The step, the reason and the fields go to the job_failed event. Reasons: not_ready (the worktree is
# gone, off the branch or dirty), fetch, conflict, review_code, review_tests, review_error, judge, sniff (a hard
# flag in the sniff of the reviews' Sniff: requests), e2e,
# slow_machine (the speed check before e2e), no_e2e_pass, moved (commits after the review), push, pr, head, checks_failed, checks_timeout, merge; and
# abandoned, for a job a dead runner left in running/ (step start) or whose process ended without failjob (step
# unknown), both in run_repo; and replaced (step queue), for a queued job that a re-queue of its branch replaces
# (add).
JOB=""; LOG=""; BRANCH=""
failjob() {
  emit job_failed step="$1" reason="$2" "${@:4}"
  echo "$(date '+%F %T') FAILED $BRANCH: $3 (log: $LOG)" | tee -a "$RESULTS"
  mv "$JOB.job" "$RQ/failed/" 2>/dev/null
  if [ -f "$JOB.body" ]; then mv "$JOB.body" "$RQ/failed/"; fi
  if [ -f "$JOB.brief" ]; then mv "$JOB.brief" "$RQ/failed/"; fi
  return 1
}
finishjob() { mv "$JOB.job" "$RQ/done/"; rm -f "$JOB.body"; if [ -f "$JOB.brief" ]; then mv "$JOB.brief" "$RQ/done/"; fi; }
# review_result <name> <output file> <exit code> <kind> <level>: logs a review.sh run, and adds to $problems why it failed.
review_result() {
  local out file
  out="$(cat "$2")"; printf '%s\n' "$out" >> "$LOG"
  if grep -qx 'already reviewed as ready' <<<"$out"; then echo "   $1: already reviewed as ready" | tee -a "$LOG"; fi
  file="$(sed -n 's/^(saved to \(.*\))$/\1/p' <<<"$out" | tail -1)"
  review_finished "$4" "$5" "$3" "$out"
  # A ready review's file too (also a cached one): its Sniff: lines are read (sniff_reviews).
  if [ "$3" -le 1 ] && [ -n "$file" ]; then
    if [ "$4" = code ]; then asked+=("code review"$'\t'"$file"); else asked+=("test review"$'\t'"$file"); fi
  fi
  if [ "$3" -eq 1 ] && [ -n "$file" ]; then found+=("$file"); findings+="; the $1 found changes to make ($1: $file)"; found_kinds+="$4"$'\n'
  elif [ "$3" -ne 0 ]; then problems+="; the $1 didn't run: $(tail -1 <<<"$out")"; fi
}
# review_finished <kind> <level> <exit code> <review.sh output>: the review_finished event. The verdict is the
# exit code's: 0 ready, 1 needs changes, 3 escalate, else error.
review_finished() {
  local verdict file
  case "$3" in 0) verdict=ready ;; 1) verdict="needs changes" ;; 3) verdict=escalate ;; *) verdict=error ;; esac
  file="$(sed -n 's/^(saved to \(.*\))$/\1/p' <<<"$4" | tail -1)"
  emit review_finished kind="$1" level:opt="$2" exit:int="$3" verdict="$verdict" review_file:opt="${file##*/}" \
    cached:bool="$(grep -qx 'already \(reviewed\|judged\) as ready' <<<"$4" && echo 1)"
}
# stop_reviews <signal>: a Ctrl-C, hangup or TERM to the process group during step 2 stops both reviews
# (review.sh then stops its claude -p session and waits for it) and removes their output files. Then this job's
# process ends by the same signal, so the runner does too. It stops this shell's jobs, not the saved pids: a
# review started just before the signal has no saved pid yet, and a reaped one's pid may belong to another process.
stop_reviews() {
  local pid
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null; done
  wait
  rm -f "$code_out" "$tests_out" "$judge_out"; rm -rf "${sniff_tmp:-}"
  trap - "$1"; kill -"$1" "$BASHPID"
}

# The reviews' Sniff: requests (step 2). A Sniff: line of a code or test review (a list or emphasis prefix
# allowed: "- **Sniff:** ...") asks the queue to check a claim: "Sniff: <claim> | <where> | <why>".
# sniff_parse <max> <conf> <sniff file> <short sha> <dir> <asker>\t<review file>...: reads the review files'
# Sniff: lines, prints what the log gets, and writes <dir>/in (line k: "<claim> | <where>" of the k-th request
# to sniff) and <dir>/block (each asker's accepted, refused and already-sniffed requests). <max> is the limit
# per review, empty if the config has no valid one. Exit 0: requests to sniff; 1: none to sniff; 3: no Sniff:
# line at all.
sniff_parse() {
  python3 -I - "$@" <<'PY'
import os, re, sys
mx, conf, sfile, short, tdir = sys.argv[1:6]
pat = re.compile(r'^\s*(?:[-*+]\s+|[0-9]+[.)]\s+)?([*_]*)Sniff[*_]*:[*_]*\s*(.*?)\s*$')
norm = lambda c: " ".join(c.split())
seen = set()
if os.path.isfile(sfile):
    for l in open(sfile, errors="replace"):
        m = re.match(r'^Sniffed [0-9]+: (.*?) \| ', l)
        if m:
            seen.add(norm(m.group(1)))
asked = []
for a in sys.argv[6:]:
    label, f = a.split("\t", 1)
    try:
        lines = open(f, errors="replace").read().splitlines()
    except OSError:
        continue
    reqs = []
    for l in lines:
        m = pat.match(l)
        if m:
            reqs.append(m.group(2).rstrip("*_").rstrip() if m.group(1) else m.group(2))
    if reqs:
        asked.append((label, f, reqs))
if not asked:
    sys.exit(3)
if not re.fullmatch(r'[0-9]+', mx):
    print("sniff: no valid max_sniff_requests (a whole number of 0 or more) in %s: the reviews' Sniff lines are not run" % conf)
    sys.exit(1)
mx = int(mx)
inputs, block = [], []
for label, f, reqs in asked:
    block.append("### The %s: %s\n" % (label, f))
    n = 0
    for k, r in enumerate(reqs, 1):
        parts = [p.strip() for p in r.split("|", 2)]
        if len(parts) < 3 or not all(parts):
            print("sniff: %s: Sniff line %d refused: give <claim> | <where> | <why>" % (f, k))
            block.append("Refused (Sniff line %d): %s — give <claim> | <where> | <why>" % (k, r))
            continue
        if n >= mx:
            print("sniff: %s: Sniff line %d refused: over the limit of %d per session" % (f, k, mx))
            block.append("Refused (Sniff line %d): %s — over the limit of %d per session" % (k, r, mx))
            continue
        n += 1
        claim = norm(parts[0])
        if claim in seen:
            print("sniff: %s: already sniffed at %s" % (claim, short))
            block.append("Already sniffed (Sniff line %d): %s — at %s" % (k, r, short))
            continue
        seen.add(claim)
        inputs.append("%s | %s" % (parts[0], parts[1]))
        block.append("Sniffed %d: %s | %s | %s" % (len(inputs), parts[0], parts[1], parts[2]))
    block.append("")
with open(os.path.join(tdir, "in"), "w") as o:
    o.write("".join(l + "\n" for l in inputs))
with open(os.path.join(tdir, "block"), "w") as o:
    o.write("\n".join(block) + "\n")
sys.exit(0 if inputs else 1)
PY
}
# sniff_reviews <sha> <asker>\t<review file>...: sniffs the reviews' Sniff: requests at the reviewed commit, once
# per claim and commit, mechanically (sniff.sh, no session), and appends the requests and the flags to the
# commit's sniff file, $sniff_file. Sets sniff_soft, the soft flags of this run (empty if nothing was sniffed now).
# A sniff that didn't run only adds a line to the log: it never stalls a branch. Without a Sniff: line, it does
# nothing. The hard flags count from the whole sniff file (sniff_hard_of), so a re-queue of the same commit, whose
# claims were already sniffed, still has them.
sniff_reviews() {
  local sha="$1" short max conf="${SNIFF_CONFIG:-$HERE/sniff.conf}" rc n flags reason; shift
  short="$(git rev-parse --short "$sha")"; sniff_soft=""
  # The limit, from the config: sourced in a subshell, so that only the file's value counts.
  # shellcheck source=/dev/null  # a config file, checked by the tests instead
  max="$(unset max_sniff_requests; . "$conf" >/dev/null 2>&1; echo "${max_sniff_requests:-}")"
  sniff_tmp="$(mktemp -d)" || { echo "   the sniff didn't run: can't create a temp folder" | tee -a "$LOG"; return 0; }
  sniff_parse "$max" "$conf" "$sniff_file" "$short" "$sniff_tmp" "$@" > "$sniff_tmp/log"; rc=$?
  sed 's/^/   /' "$sniff_tmp/log" | tee -a "$LOG"
  case "$rc" in
    0) ;;
    1|3) rm -rf "$sniff_tmp"; sniff_tmp=""; return 0 ;;
    *) echo "   the sniff didn't run: can't read the reviews' Sniff: lines" | tee -a "$LOG"; rm -rf "$sniff_tmp"; sniff_tmp=""; return 0 ;;
  esac
  n="$(wc -l < "$sniff_tmp/in")"
  echo "   sniffing $n request(s) of the reviews at $short (sniff.sh)" | tee -a "$LOG"
  bash "$HERE/sniff.sh" "$sniff_tmp/in" --repo "$PWD" --commit "$sha" </dev/null >"$sniff_tmp/out" 2>"$sniff_tmp/err"; rc=$?
  if [ "$rc" -gt 2 ]; then
    reason="$(head -1 "$sniff_tmp/err")"; reason="${reason#sniff: }"
    echo "   the sniff didn't run: ${reason:-sniff.sh exited $rc}" | tee -a "$LOG"
    rm -rf "$sniff_tmp"; sniff_tmp=""; return 0
  fi
  local new=""; if [ ! -s "$sniff_file" ]; then new=1; fi
  { if [ -n "$new" ]; then printf '# Sniff of the reviews'"'"' requests: %s at %s\n\n' "$BRANCH" "$sha"; fi
    printf '## Requests of %s (sniff.sh at %s)\n\n' "$(date '+%F %T')" "$sha"
    cat "$sniff_tmp/block"; printf '### Flags\n\n'; cat "$sniff_tmp/out"; echo; } >> "$sniff_file" 2>>"$LOG"
  flags="$(grep -m1 '^Flags: ' "$sniff_tmp/out")"
  sniff_soft="$(sed -n 's/.*, \([0-9]*\) soft$/\1/p' <<<"$flags")"; sniff_soft="${sniff_soft:-0}"
  rm -rf "$sniff_tmp"; sniff_tmp=""
}
# sniff_hard_of <sniff file>: the hard flags of every sniff in it (the sum of its Flags: lines), 0 without one.
sniff_hard_of() {
  if [ -f "$1" ]; then awk '/^Flags: [0-9]+ hard,/ { n += $2 } END { print n + 0 }' "$1"; else echo 0; fi
}

# The speed check before e2e (step 3). say <message>: to the log and the output (fd 7, in the e2e subshell).
SPEED_TRIES=6
say() { echo "   $*" | tee -a "$LOG" >&7; }
# number <value>: whether it is a number above 0.
number() { [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v v="$1" 'BEGIN { exit !(v + 0 > 0) }'; }
# speed_bench: one measurement, in CPU-seconds: $PR_QUEUE_BENCH's, else the fastest of 3 runs of a fixed loop (about
# 0.3 s each on this machine).
speed_bench() {
  if [ -n "${PR_QUEUE_BENCH:-}" ]; then command "$PR_QUEUE_BENCH" 2>/dev/null; return; fi
  python3 -I -c '
import time
def once():
    t = time.process_time(); x = 0
    for i in range(1000000): x += i * i % 7
    return time.process_time() - t
print("%.3f" % min(once() for _ in range(3)))'
}
# valid_lines <file>: its lines that are numbers above 0.
valid_lines() { awk '/^[0-9]*\.?[0-9]+$/ && $0 + 0 > 0' "$1"; }
# speed_check <file>: 0 when e2e may run; 75, with the last ratio in the file, when the machine stayed too slow.
speed_check() {
  local max="${PR_QUEUE_SPEED_MAX:-4}" wait="${PR_QUEUE_SPEED_WAIT:-300}" file="$STATE/speed-baseline" v base r n=0
  [ "$max" != 0 ] || return 0
  while :; do
    if ! v="$(speed_bench)" || ! number "$v"; then
      say "speed check failed (the benchmark printed no number); e2e runs without it"; return 0
    fi
    if [ ! -f "$file" ]; then
      echo "$v" > "$file"; say "speed baseline set: $v s CPU ($file)"; return 0
    fi
    base="$(valid_lines "$file" | sort -g | awk '{ a[NR] = $0 } END { if (NR) print (NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2) }')"
    if [ -z "$base" ]; then
      say "speed baseline unreadable ($file); starting a new one"; echo "$v" > "$file"; return 0
    fi
    r="$(awk -v v="$v" -v b="$base" 'BEGIN { printf "%.1f", v / b }')"
    if awk -v v="$v" -v b="$base" -v m="$max" 'BEGIN { exit !(v / b <= m) }'; then
      say "machine speed: ${r}× baseline"
      { valid_lines "$file"; echo "$v"; } | tail -n 20 > "$file.new" && mv "$file.new" "$file"
      return 0
    fi
    if [ "$n" -ge "$SPEED_TRIES" ]; then echo "$r" > "$1"; return 75; fi
    n=$((n + 1))
    say "machine slow: ${r}× baseline; checking again in $wait s ($n of $SPEED_TRIES)"
    sleep "$wait"
  done
}

process() {
  JOB="${1%.job}"
  local wt type desc pr sha line main_dir merged level review_rc reviewed="" tries=0
  wt="$(field worktree "$1")"; BRANCH="$(field branch "$1")"; type="$(field type "$1")"; desc="$(field description "$1")"
  LOG="$LOGS/$BRANCH.log"; mkdir -p "$(dirname "$LOG")"
  EV_REPO="$REPO"; EV_BRANCH="$BRANCH"; EV_JOB_ID="$(basename "$JOB")"; EV_SHA="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  emit job_started
  echo "== $(date '+%F %T') $BRANCH" | tee -a "$LOG"
  cd "$wt" 2>/dev/null || { failjob start not_ready "worktree $wt is gone"; return; }
  [ "$(git branch --show-current)" = "$BRANCH" ] || { failjob start not_ready "$wt is no longer on $BRANCH"; return; }
  [ -z "$(git status --porcelain)" ] || { failjob start not_ready "uncommitted changes in $wt"; return; }

  # 1. Up to date with main.
  git fetch -q origin >>"$LOG" 2>&1 || { failjob main fetch "git fetch failed"; return; }
  if ! git merge-base --is-ancestor origin/main HEAD; then
    if ! git merge --no-edit -q origin/main >>"$LOG" 2>&1; then
      local files; files="$(git diff --name-only --diff-filter=U)"
      git merge --abort >>"$LOG" 2>&1
      emit main_merged result=conflict files:list="$files"
      files="$(tr '\n' ' ' <<<"$files")"
      failjob main conflict "merge conflict with origin/main in: ${files% }"; return
    fi
    EV_SHA="$(git rev-parse HEAD)"; emit main_merged result=merged
    echo "   merged origin/main" | tee -a "$LOG"
  else
    emit main_merged result=clean
  fi

  # 2. Review the code and the tests, in fresh sessions at the same time, before the e2e run is spent on it.
  local tests code_pid="" tests_pid="" code_out="" tests_out="" judge_out="" problems="" findings="" found=() found_kinds="" judged
  local asked=() sniff_tmp="" sniff_file="" sniff_hard=0 sniff_soft="" stail="" sniff_env=()
  level="$(field review "$1")"; tests="$(field tests "$1")"
  local brief=""; if [ -f "$JOB.brief" ]; then brief="$JOB.brief"; fi
  if [ "$level" = none ]; then
    echo "   not reviewed (queued with --review none)" | tee -a "$LOG"; level=""
  elif [ "${PR_QUEUE_REVIEW:-}" != 0 ] || [ -n "$level" ]; then
    level="${level:-${PR_QUEUE_REVIEW:-medium}}"
  fi
  if [ "$tests" = none ]; then
    echo "   tests not reviewed (queued with --tests none)" | tee -a "$LOG"; tests=""
  elif [ "${PR_QUEUE_TEST_REVIEW:-}" != 0 ] || [ "$tests" = on ]; then
    tests=on
  else
    tests=""
  fi
  if [ -n "$level$tests" ]; then
    reviewed="$(git rev-parse HEAD)"
    code_out="$(mktemp)"; tests_out="$(mktemp)"
    trap 'stop_reviews INT' INT; trap 'stop_reviews TERM' TERM; trap 'stop_reviews HUP' HUP
    if [ -n "$level" ]; then
      echo "   reviewing $(git rev-parse --short HEAD) (/code-review $level)" | tee -a "$LOG"
      emit review_started kind=code level="$level"
      REVIEW_DIR="$REVIEWS" REVIEW_SKIP_TESTS="${tests:+1}" REVIEW_BRIEF="$brief" "$HERE/review.sh" "$wt" "$level" >"$code_out" 2>&1 &
      code_pid=$!
    fi
    if [ -n "$tests" ]; then
      echo "   reviewing the tests of $(git rev-parse --short HEAD)" | tee -a "$LOG"
      emit review_started kind=tests level:opt=
      REVIEW_DIR="$REVIEWS" REVIEW_BRIEF="$brief" "$HERE/review.sh" --tests "$wt" >"$tests_out" 2>&1 &
      tests_pid=$!
    fi
    if [ -n "$code_pid" ]; then wait "$code_pid"; review_rc=$?; review_result review "$code_out" "$review_rc" code "$level"; fi
    if [ -n "$tests_pid" ]; then wait "$tests_pid"; review_rc=$?; review_result "test review" "$tests_out" "$review_rc" tests ""; fi
    rm -f "$code_out" "$tests_out"
    # The reviews' Sniff: requests, before the judge, who gets the commit's sniff file.
    sniff_file="$REVIEWS/${BRANCH//\//-}-$(git rev-parse --short=12 "$reviewed")-sniff.md"
    sniff_reviews "$reviewed" "${asked[@]}"
    sniff_hard="$(sniff_hard_of "$sniff_file")"
    if [ "$sniff_hard" -gt 0 ]; then
      echo "   the sniff of the reviews' requests has $sniff_hard hard flag(s) (sniff: $sniff_file)" | tee -a "$LOG"
    elif [ -n "$sniff_soft" ]; then
      echo "   the sniff of the reviews' requests has $sniff_soft soft flag(s) (sniff: $sniff_file)" | tee -a "$LOG"
    fi
    if [ "$sniff_hard" -gt 0 ]; then stail="; the sniff has $sniff_hard hard flag(s) (sniff: $sniff_file)"; fi
    if [ -f "$sniff_file" ]; then sniff_env=(REVIEW_SNIFF="$sniff_file"); fi
    if [ -n "$problems" ]; then trap - INT TERM HUP; failjob review review_error "${problems#; }$findings$stail" found:list="${found_kinds%$'\n'}"; return; fi
    if [ ${#found[@]} -gt 0 ] && [ "${PR_QUEUE_JUDGE:-1}" = 0 ]; then
      # Both reviews' findings: the code's is named as the reason, and both kinds are in found.
      trap - INT TERM HUP
      local reason=review_tests; if grep -qx code <<<"$found_kinds"; then reason=review_code; fi
      failjob review "$reason" "${findings#; }$stail" found:list="${found_kinds%$'\n'}"; return
    fi
    if [ ${#found[@]} -gt 0 ]; then
      echo "   judging the findings (review.sh --judge)" | tee -a "$LOG"
      emit review_started kind=judge level:opt=
      judge_out="$(mktemp)"
      env ${sniff_env[@]+"${sniff_env[@]}"} REVIEW_DIR="$REVIEWS" REVIEW_BRIEF="$brief" "$HERE/review.sh" --judge "$wt" "${found[@]}" >"$judge_out" 2>&1 &
      wait $!; review_rc=$?
      trap - INT TERM HUP
      judged="$(cat "$judge_out")"; rm -f "$judge_out"; printf '%s\n' "$judged" >> "$LOG"
      review_finished judge "" "$review_rc" "$judged"
      local jfile; jfile="$(sed -n 's/^(saved to \(.*\))$/\1/p' <<<"$judged" | tail -1)"
      case "$review_rc" in
        0) echo "   the judge found nothing to fix (judge: $jfile)" | tee -a "$LOG" ;;
        1) failjob judge judge "${findings#; }; the judge confirmed changes to make (judge: $jfile)$stail" found:list="${found_kinds%$'\n'}"; return ;;
        3)
          if grep -q 'two judged rounds' <<<"$judged"; then
            emit escalated reason=two_rounds review_file:opt="${jfile##*/}"
            failjob judge judge "needs your decision: the branch still had changes to make after two judged rounds (judge: $jfile)$stail" \
              found:list="${found_kinds%$'\n'}"
          else
            emit escalated reason=critical_finding review_file:opt="${jfile##*/}"
            failjob judge judge "needs your decision: the judge rejected a finding that would be critical if real (judge: $jfile)$stail" \
              found:list="${found_kinds%$'\n'}"
          fi
          return ;;
        *) failjob judge review_error "${findings#; }; the judge didn't run: $(tail -1 <<<"$judged")$stail" found:list="${found_kinds%$'\n'}"; return ;;
      esac
    fi
    trap - INT TERM HUP
    if [ "$sniff_hard" -gt 0 ]; then
      failjob review sniff "the sniff of the reviews' requests has $sniff_hard hard flag(s) (sniff: $sniff_file)" \
        found:list="${found_kinds%$'\n'}"
      return
    fi
  fi

  # 3. The full local suite, once, on this exact commit.
  line=""
  if [ -f scripts/e2e-gate.mjs ]; then
    if ! node scripts/e2e-gate.mjs pr-line >/dev/null 2>&1; then
      echo "   running the full e2e suite on $(git rev-parse --short HEAD)" | tee -a "$LOG"
      # The e2e lock is held on fd 8 for the subshell, so that e2e_started is emitted once it is held.
      # The speed check runs under the lock too, so no other e2e run loads the machine while it measures. Its
      # messages go to fd 7, the output. A slow machine ends the subshell with 75 and its ratio in $slow:
      # failjob and its event only work out here.
      emit e2e_waiting
      local slow; slow="$(mktemp)"
      ( flock 8 || exit 1; speed_check "$slow" || exit 75; emit e2e_started; npm run test:e2e:full 7>&- ) \
        7>&1 8>"$STATE/e2e.lock" >>"$LOG" 2>&1
      local e2e_rc=$?
      if [ "$e2e_rc" -eq 75 ] && [ -s "$slow" ]; then
        local ratio; ratio="$(cat "$slow")"; rm -f "$slow"
        failjob e2e slow_machine "machine too slow: ${ratio}× baseline after $SPEED_TRIES re-checks; e2e not run, the branch was not tested"
        return
      fi
      rm -f "$slow"
      emit e2e_finished rc:int="$e2e_rc"
      [ "$e2e_rc" -eq 0 ] || { failjob e2e e2e "the full e2e suite failed"; return; }
    fi
    line="$(node scripts/e2e-gate.mjs pr-line 2>>"$LOG")" || { failjob e2e no_e2e_pass "no local e2e pass recorded for $(git rev-parse --short HEAD)"; return; }
  fi
  sha="$(git rev-parse HEAD)"
  if [ -n "$reviewed" ] && [ "$sha" != "$reviewed" ]; then
    EV_SHA="$sha"; failjob e2e moved "$BRANCH got commits after the review; queue it again to review them"; return
  fi
  EV_SHA="$sha"

  # 4. Open the PR, or update the open one. The body goes first: CI reads it when the push arrives.
  pr="$(gh pr view "$BRANCH" --json number,state -q 'select(.state=="OPEN") | .number' 2>/dev/null)"
  local new_pr=""; [ -n "$pr" ] || new_pr=1
  if [ -n "$pr" ]; then
    if [ -f "$JOB.body" ]; then cp "$JOB.body" "$JOB.base"; else gh pr view "$pr" --json body -q .body > "$JOB.base" 2>>"$LOG"; fi
    with_line "$JOB.base" "$line" > "$JOB.newbody"
    gh pr edit "$pr" --body-file "$JOB.newbody" >>"$LOG" 2>&1 || echo "   could not set the body of #$pr" | tee -a "$LOG"
    rm -f "$JOB.base" "$JOB.newbody"
    git push -q origin "$sha:refs/heads/$BRANCH" >>"$LOG" 2>&1 || { failjob pr push "git push failed"; return; }
  elif [ -x scripts/create-pr.sh ]; then
    GH_BROWSER=true BROWSER=true scripts/create-pr.sh "$type" "$desc" </dev/null >>"$LOG" 2>&1 \
      || { failjob pr pr "scripts/create-pr.sh failed"; return; }
    pr="$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null)"
    if [ -n "$pr" ] && [ -f "$JOB.body" ]; then
      with_line "$JOB.body" "$line" > "$JOB.newbody"
      gh pr edit "$pr" --body-file "$JOB.newbody" >>"$LOG" 2>&1 || echo "   could not set the body of #$pr" | tee -a "$LOG"
      rm -f "$JOB.newbody"
    fi
  else
    git push -q origin "$sha:refs/heads/$BRANCH" >>"$LOG" 2>&1 || { failjob pr push "git push failed"; return; }
    if [ -f "$JOB.body" ]; then with_line "$JOB.body" "$line"; else with_line /dev/null "$line"; fi > "$JOB.newbody"
    gh pr create --base main --head "$BRANCH" --title "$type: $desc" --body-file "$JOB.newbody" >>"$LOG" 2>&1
    local rc=$?; rm -f "$JOB.newbody"
    [ $rc -eq 0 ] || { failjob pr pr "gh pr create failed"; return; }
  fi
  pr="$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null)"
  [ -n "$pr" ] || { failjob pr pr "no PR found for $BRANCH"; return; }
  emit pr_opened pr:int="$pr" new:bool="$new_pr"

  # 5. Checks of this commit, not of the PR's previous head.
  until [ "$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)" = "$sha" ]; do
    tries=$((tries + 1)); [ $tries -lt 10 ] || { failjob checks head "#$pr does not show $sha as its head"; return; }
    sleep "$CHECKS_WAIT"
  done
  echo "   PR #$pr, waiting for the checks" | tee -a "$LOG"
  # Done when some are reported and none is pending, twice in a row (a workflow can start late).
  # A check that stays pending (a stuck runner, a workflow that never starts) fails the job at the deadline,
  # so it can't block the queue.
  local checks bad pending passes=0 deadline=$((SECONDS + CHECKS_TIMEOUT)) waited polls=0; tries=0
  if [ $((CHECKS_TIMEOUT % 60)) -eq 0 ]; then waited="$((CHECKS_TIMEOUT / 60))m"; else waited="${CHECKS_TIMEOUT}s"; fi
  while :; do
    checks="$(gh pr checks "$pr" --json name,bucket -q '.[] | "\(.bucket)\t\(.name)"' 2>>"$LOG")"; polls=$((polls + 1))
    [ -n "$checks" ] && echo "$checks" >> "$LOG"
    bad="$(awk -F'\t' '$1 == "fail" || $1 == "cancel" { print $2 }' <<<"$checks" | sort -u)"
    if [ -n "$bad" ]; then
      emit checks_finished result=fail failed:list="$bad" polls:int="$polls"
      bad="$(paste -sd, - <<<"$bad")"
      failjob checks checks_failed "checks failed on #$pr: $bad"; return
    fi
    if [ -z "$checks" ]; then
      passes=0; tries=$((tries + 1))
      if [ $tries -ge 10 ]; then
        emit checks_finished result=none failed:list= polls:int="$polls"
        failjob checks checks_timeout "no checks reported on #$pr"; return
      fi
    elif grep -q '^pending' <<<"$checks"; then
      passes=0
      if [ "$SECONDS" -ge "$deadline" ]; then
        pending="$(awk -F'\t' '$1 == "pending" { print $2 }' <<<"$checks" | sort -u)"
        emit checks_finished result=timeout failed:list= pending:list="$pending" polls:int="$polls"
        pending="$(paste -sd, - <<<"$pending")"
        failjob checks checks_timeout "checks still pending on #$pr after $waited: $pending"; return
      fi
    else
      passes=$((passes + 1))
      if [ $passes -ge 2 ]; then emit checks_finished result=pass failed:list= polls:int="$polls"; break; fi
    fi
    sleep "$CHECKS_WAIT"
  done

  # 6. Merge exactly the tested commit, and clean up.
  if [ "${PR_QUEUE_MERGE:-1}" = 0 ]; then
    emit job_ready pr:int="$pr"
    echo "$(date '+%F %T') READY $BRANCH: #$pr passed, left open (PR_QUEUE_MERGE=0)" | tee -a "$RESULTS"
    finishjob; return
  fi
  gh pr merge "$pr" --squash --match-head-commit "$sha" >>"$LOG" 2>&1
  [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = MERGED ] || { failjob merge merge "merging #$pr failed"; return; }
  merged="$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)"
  emit merged pr:int="$pr" merge_sha:opt="$merged"
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
    *) die "PR_QUEUE_REVIEW must be 0 (no code reviews), low, medium, high or xhigh, not '$PR_QUEUE_REVIEW'" ;;
  esac
  case "${PR_QUEUE_TEST_REVIEW:-1}" in
    0|1) ;;
    *) die "PR_QUEUE_TEST_REVIEW must be 0 (no test reviews) or 1, not '$PR_QUEUE_TEST_REVIEW'" ;;
  esac
  case "${PR_QUEUE_JUDGE:-1}" in
    0|1) ;;
    *) die "PR_QUEUE_JUDGE must be 0 (no judge: a review that needs changes fails the job) or 1, not '$PR_QUEUE_JUDGE'" ;;
  esac
  case "${PR_QUEUE_AWAKE:-1}" in
    0|1) ;;
    *) die "PR_QUEUE_AWAKE must be 0 (don't keep Windows awake) or 1, not '$PR_QUEUE_AWAKE'" ;;
  esac
  local speed="${PR_QUEUE_SPEED_MAX:-4}"
  if [ "$speed" != 0 ] && ! { [[ "$speed" =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v m="$speed" 'BEGIN { exit !(m + 0 > 1) }'; }; then
    die "PR_QUEUE_SPEED_MAX must be 0 (no speed check) or a number above 1, not '$speed'"
  fi
  [[ "${PR_QUEUE_SPEED_WAIT:-300}" =~ ^[0-9]+$ ]] || die "PR_QUEUE_SPEED_WAIT must be a whole number of seconds, not '$PR_QUEUE_SPEED_WAIT'"
  POLL="${PR_QUEUE_POLL:-5}"
  [[ "$POLL" =~ ^[0-9]*\.?[0-9]+$ && "$POLL" =~ [1-9] ]] || die "PR_QUEUE_POLL must be a number of seconds above 0, not '$POLL'"
  migrate
  # A runner of the old version works on all repos' jobs under the old lock; a new one beside it could run a
  # second job of the same repo. A shared lock to check: it fails only beside the old runner's exclusive one,
  # not beside another new runner checking at the same time.
  if ! flock -n -s "$STATE/run.lock" true; then
    die "a runner of the old version (one queue for all repos) is still working; run again when it is done"
  fi
  if [ $# -ge 1 ]; then
    use_repo "$1" || die "$1 is not a git checkout"; run_repo; return
  fi
  [ -z "$CHILD" ] || die "a repo's runner must not start runners for every repo"
  # A runner of its own for every repo with jobs, side by side, each in a process group of its own (so that a
  # TERM to it reaches its job and the job's reviews too). While any works, every $PR_QUEUE_POLL seconds, it
  # notes the ones that ended and starts one for each repo that has jobs by then (a job left in running/ too:
  # run_repo moves it to failed/), so a job queued to a repo never waits for another repo's queue. A repo whose
  # runner failed (it said why) is left out, so this ends. A repo whose queue another runner has is tried again
  # at each poll (said once), so a job queued to it after that runner ends still gets a runner while this one
  # works; when this one has nothing left to do, it ends and names the repos still busy with jobs.
  local d p sig given_up=" " active=" " busy=" "
  local -A repo_of=()  # pid of each repo's runner -> its repo folder
  # A Ctrl-C or kill of this runner stops them with a TERM to each one's process group, waits until each group
  # is gone (its job stopping its reviews too; at most 70 s: a review session gets 30 s to stop, then 30 s
  # more), then ends this one by the same signal.
  for sig in INT TERM HUP; do
    # shellcheck disable=SC2064,SC2154  # $sig now; the pids (and p) are expanded when the trap runs
    trap "for p in \"\${!repo_of[@]}\"; do kill -TERM -- -\$p 2>/dev/null; done
      for p in \"\${!repo_of[@]}\"; do for _ in \$(seq 700); do kill -0 -- -\$p 2>/dev/null || break; sleep 0.1; done; done
      trap - $sig; kill -$sig \$\$" "$sig"
  done
  while :; do
    for d in "$STATE"/repos/*/; do
      d="${d%/}"
      if [[ "$given_up$active" == *" $d "* ]] || [ -z "$(find "$d/queue" "$d/running" -name '*.job' 2>/dev/null | head -1)" ]; then
        continue
      fi
      if ! flock -n "$d/run.lock" true; then
        if [[ "$busy" != *" $d "* ]]; then
          echo "pr-queue: $(basename "$d"): a runner is already working on the queue"; busy+="$d "
        fi
        continue
      fi
      busy="${busy/" $d "/ }"
      PR_QUEUE_CHILD=1 setsid bash "$0" run "$(cat "$d/checkout")" &
      repo_of[$!]="$d"; active+="$d "
    done
    [ ${#repo_of[@]} -gt 0 ] || break
    # In the background, so that a signal is handled at once, not when the sleep ends.
    sleep "$POLL" & wait $!
    # An ended runner: bash has reaped it (kill -0 fails), and wait gives its exit status.
    for p in "${!repo_of[@]}"; do
      kill -0 "$p" 2>/dev/null && continue
      wait "$p" || given_up+="${repo_of[$p]} "
      active="${active/" ${repo_of[$p]} "/ }"; unset "repo_of[$p]"
    done
  done
  trap - INT TERM HUP
  for d in $busy; do
    [[ "$given_up" == *" $d "* ]] || [ -z "$(find "$d/queue" "$d/running" -name '*.job' 2>/dev/null | head -1)" ] ||
      given_up+="$d "
  done
  if [ "$given_up" = " " ]; then echo "pr-queue: the queues are empty"; return; fi
  echo "pr-queue: jobs left in the queue of:$(for d in $given_up; do printf " %s" "$(basename "$d")"; done) (see above)"
}

# The helper's PowerShell (see the header): the request for its thread, then a wait for stdin's EOF, at most
# 12 hours. It has no double quotes (the C# string's come from [char]34), which the way to Windows could mangle.
AWAKE_PS=$(cat <<'EOF'
$k = Add-Type -Name Awake -Namespace PrQueue -PassThru -MemberDefinition ('[DllImport(' + [char]34 + 'kernel32.dll' + [char]34 + ')] public static extern uint SetThreadExecutionState(int f);'); if (-not $k::SetThreadExecutionState(0x80000001)) { 'SetThreadExecutionState failed' }; [void][Console]::In.ReadToEndAsync().Wait([TimeSpan]::FromSeconds(43200))
EOF
)
# awake_start: starts the helper, its stdin the read end of a pipe whose write end is this shell's fd 7. The
# helper gets neither fd 7 nor the runner's lock (fd 9).
AWAKE_PID=""
awake_start() {
  exec 7> >(exec powershell.exe -NoProfile -NonInteractive -Command "$AWAKE_PS" >>"$RQ/awake.log" 2>&1 9>&-)
  AWAKE_PID=$!
}
# awake_stop: closes the pipe, so the helper ends, and waits for it (at most 10 s).
awake_stop() {
  [ -n "$AWAKE_PID" ] || return 0
  exec 7>&-
  for _ in $(seq 100); do kill -0 "$AWAKE_PID" 2>/dev/null || break; sleep 0.1; done
  AWAKE_PID=""
}

# run_repo: works through the queue of the current repo until it is empty.
run_repo() {
  exec 9>"$RQ/run.lock"
  flock -n 9 || { echo "pr-queue: $REPO: a runner is already working on the queue"; return 0; }
  local job name awake="${PR_QUEUE_AWAKE:-1}"
  # Jobs left in running/ belong to a runner that died (we hold the lock).
  for job in "$RUNNING"/*.job; do
    [ -f "$job" ] || continue
    echo "pr-queue: $REPO: $(field branch "$job") was left unfinished by an earlier runner; moved to failed/"
    EV_REPO="$REPO" EV_BRANCH="$(field branch "$job")" EV_JOB_ID="$(basename "${job%.job}")" \
      EV_SHA="$(git -C "$(field worktree "$job")" rev-parse HEAD 2>/dev/null)" emit job_failed step=start reason=abandoned
    mv "${job%.job}".* "$RQ/failed/"
  done
  while job="$(find "$QUEUE" -name '*.job' | sort | head -1)"; [ -n "$job" ]; do
    name="$(basename "${job%.job}")"
    mv "${job%.job}".* "$RUNNING/"
    if [ "$awake" = 1 ] && ! command -v powershell.exe >/dev/null; then
      echo "pr-queue: $REPO: powershell.exe not found; Windows is not kept awake while the queue runs"; awake=0
    fi
    if [ "$awake" = 1 ]; then awake_start; fi
    # The job doesn't get the helper's pipe (fd 7): only this shell's end closes it.
    ( process "$RUNNING/$name.job" ) 7>&- || true
    awake_stop
    # A job that left its file behind (a crash) must not loop forever.
    if [ -f "$RUNNING/$name.job" ]; then
      echo "pr-queue: $REPO: $name did not finish; moved to failed/"
      EV_REPO="$REPO" EV_BRANCH="$(field branch "$RUNNING/$name.job")" EV_JOB_ID="$name" \
        EV_SHA="$(git -C "$(field worktree "$RUNNING/$name.job")" rev-parse HEAD 2>/dev/null)" emit job_failed step=unknown reason=abandoned
      mv "$RUNNING/$name".* "$RQ/failed/"
    fi
  done
  exec 9>&-
  echo "pr-queue: $REPO: the queue is empty"
}

status() {
  local d job any=""
  migrate
  for d in "$STATE"/repos/*/; do
    [ -d "$d" ] || continue
    set_repo "${d%/}"; any=1
    echo "$REPO ($(cat "$RQ/checkout" 2>/dev/null)):"
    echo "  Running:"; for job in "$RUNNING"/*.job; do [ -f "$job" ] && echo "    $(field branch "$job")"; done
    echo "  Queued:"; find "$QUEUE" -name '*.job' | sort | while read -r job; do echo "    $(field branch "$job")"; done
    echo "  Last results:"; tail -n "${1:-10}" "$RESULTS" 2>/dev/null | sed 's/^/    /'
  done
  [ -n "$any" ] || echo "No jobs queued yet."
}

case "${1:-}" in
  add) shift; add "$@" ;;
  run) shift; run "$@" ;;
  status) shift; status "$@" ;;
  lock) shift; [ $# -ge 1 ] || usage; exec flock "$STATE/e2e.lock" "$@" ;;
  *) usage ;;
esac
