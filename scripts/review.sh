#!/usr/bin/env bash
# Reviews a worktree's branch in a new headless `claude -p` session every time, so the review never carries
# the calling session's context:
#   review.sh <worktree> [low|medium|high|xhigh]   the code, with Claude Code's built-in /code-review
#                                                  (default medium; use high for migrations, auth or RLS)
#   review.sh --tests <worktree>                   the tests of the branch's change (scripts/review-tests.md)
#   review.sh --suite <checkout>                   an audit of the checkout's whole test suite (same file)
# The session runs in the worktree, so it reads the branch's own files and its CLAUDE.md and rules (a change
# to those is part of the diff it reviews). It has no Edit or Write tools and no stdin, and the review fails
# if the worktree's files or either checkout's HEAD or branch changed meanwhile. (An audit reads only its
# pinned commit, so it may run in a checkout someone works in: a moved HEAD or branch only adds a note.)
# A test review or audit gets a scratch folder, removed afterwards: it runs the tests in a copy of the
# commit there, with the code broken on purpose, and e2e tests only under `pr-queue.sh lock`.
# It is stopped after $REVIEW_TIMEOUT seconds (1800 for the code, 3600 for the tests: e2e runs wait for the
# lock), and killed 30 s later if it is still running. A Ctrl-C or kill (TERM) of review.sh stops the session
# too, and waits for it to end. (Started by pr-queue.sh, review.sh ignores SIGINT as a background job: the queue
# sends it TERM.)
# REVIEW_SKIP_TESTS=1 tells /code-review to leave the quality of tests to the test review.
# Reviews are saved to $REVIEW_DIR (default $PR_QUEUE_DIR/reviews, the folder pr-queue.sh uses) as
# <branch>-<sha>-<level>.md (<level>-notests.md with REVIEW_SKIP_TESTS=1) or <branch>-<sha>-tests.md.
# A commit already reviewed as ready isn't reviewed again: for the code, at that level or a higher one, and
# a review that left out the tests counts only for another one that does. Prints the findings and a last
# line "Verdict: ready" or "Verdict: needs changes", then "(saved to <file>)".
# Exit 0 = ready, 1 = needs changes, 2 = the review didn't run.
# An audit is saved as <repo>-suite-<sha>.md with every finding. It prints only its summary and the file,
# and exits 0, or 2 if it didn't run.
set -uo pipefail
die() { echo "review: $*" >&2; exit 2; }
# verdict <file>: "ready", "needs changes" or "failed", from the last verdict line (markdown and case ignored).
verdict() {
  grep -oiE 'verdict:[[:space:]*_`]*(ready|needs changes|failed)' "$1" 2>/dev/null | tail -1 \
    | grep -oiE 'ready|needs changes|failed' | tr '[:upper:]' '[:lower:]'
}
# state: what must not change during a review: the worktree's HEAD and files, and where the main checkout is
# (its files may change: someone may be working there). An audit may run in a checkout someone works in.
state() {
  git -C "$wt" rev-parse HEAD; git -C "$wt" branch --show-current
  if [ "$mode" != suite ]; then git -C "$wt" status --porcelain; fi
  git -C "$main" rev-parse HEAD; git -C "$main" branch --show-current
}

usage="usage: review.sh <worktree> [low|medium|high|xhigh] | --tests <worktree> | --suite <checkout>"
mode=code; level=medium
case "${1:-}" in
  --tests|--suite) [ $# -eq 2 ] || die "$usage"; mode="${1#--}"; shift ;;
  *)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "$usage"; fi
    level="${2:-medium}"
    case "$level" in low|medium|high|xhigh) ;; *) die "level must be low, medium, high or xhigh, not $level" ;; esac
    ;;
esac
HERE="$(dirname "$(readlink -f "$0")")"
wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
branch="$(git -C "$wt" branch --show-current)"
if [ -z "$branch" ] && [ "$mode" != suite ]; then die "$wt is not on a branch"; fi
sha="$(git -C "$wt" rev-parse -q --verify --short=12 HEAD)" || die "$wt has no commits"
main="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
dir="${REVIEW_DIR:-${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/reviews}"
mkdir -p "$dir" || die "can't create $dir"
base="$dir/${branch//\//-}-$sha"

case "$mode" in
  code)
    kinds=".md"; suffix=""
    if [ "${REVIEW_SKIP_TESTS:-}" = 1 ]; then kinds=".md -notests.md"; suffix="-notests"; fi
    out="$base-$level$suffix.md"; higher=""
    for l in low medium high xhigh; do
      if [ "$l" = "$level" ]; then higher=1; fi
      [ -n "$higher" ] || continue
      for k in $kinds; do
        if [ "$(verdict "$base-$l$k")" = ready ]; then
          cat "$base-$l$k"; echo "already reviewed as ready"; echo "(saved to $base-$l$k)"; exit 0
        fi
      done
    done
    skip=""
    if [ -n "$suffix" ]; then
      skip=" Leave out findings that are only about the quality of tests (missing, weak, duplicate or \
non-atomic tests): a separate test review covers them. Keep findings that break a repo rule."
    fi
    prompt="Invoke the code-review skill with the Skill tool, args \"$level $branch\". When it is done, print every \
finding as plain text (severity, file:line, summary, failure scenario).$skip Then end with exactly one line: \
\"Verdict: needs changes\" if any finding is important or breaks a rule from CLAUDE.md or .claude/rules, \
otherwise \"Verdict: ready\". If the skill is not available, print \"Verdict: failed\" and stop without reviewing."
    title="Review of $branch at $sha (/code-review $level, "
    ;;
  tests)
    out="$base-tests.md"
    if [ "$(verdict "$out")" = ready ]; then
      cat "$out"; echo "already reviewed as ready"; echo "(saved to $out)"; exit 0
    fi
    against=origin/main
    git -C "$wt" rev-parse -q --verify "$against^{commit}" >/dev/null || against=main
    git -C "$wt" rev-parse -q --verify "$against^{commit}" >/dev/null || die "no origin/main or main to compare $branch with"
    mb="$(git -C "$wt" merge-base "$against" HEAD 2>/dev/null)" || die "$branch has no common history with $against"
    task="Review the tests of one change, following the instructions below (a change review).
- Repo: $wt, branch $branch. The change: git diff ${mb:0:12} $sha (against $against). Review exactly commit $sha."
    title="Test review of $branch at $sha ("
    ;;
  suite)
    name="$(basename "$wt")"; out="$dir/$name-suite-$sha.md"
    task="Audit the whole test suite of one repo, following the instructions below (a suite audit).
- Repo: $wt, commit $sha. Audit exactly that commit."
    title="Test suite audit of $name at $sha ("
    ;;
esac
json="$(mktemp)" || die "can't create a temp file"
trap 'rm -rf "$json" ${scratch:+"$scratch"}' EXIT
scratch=""
if [ "$mode" != code ]; then
  [ -f "$HERE/review-tests.md" ] || die "missing $HERE/review-tests.md"
  scratch="$(mktemp -d)" || die "can't create a scratch folder"
  prompt="$task
- Scratch folder (yours, removed afterwards): $scratch
- e2e lock command: $HERE/pr-queue.sh lock <command>

$(cat "$HERE/review-tests.md")"
fi

before="$(state)"
limit="${REVIEW_TIMEOUT:-1800}"
if [ "$mode" != code ]; then limit="${REVIEW_TIMEOUT:-3600}"; fi
cd "$wt" || die "can't enter $wt"
# In the background, so that a Ctrl-C or kill stops the session too: timeout runs it in a process group of
# its own, which neither signal reaches by itself. The trap waits for the session (at most 30 s, then timeout
# kills it) before the EXIT trap removes the folders it may still be using.
session=""
trap '[ -z "$session" ] || { kill "$session" 2>/dev/null; wait "$session"; }; die "stopped, and so was the claude -p session"' INT TERM
timeout -k 30 "$limit" claude -p "$prompt" --output-format json --permission-mode auto \
  --disallowed-tools "Edit,Write,NotebookEdit" </dev/null >"$json" &
session=$!
wait "$session"; rc=$?
trap - INT TERM
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then die "the review took longer than ${limit}s (REVIEW_TIMEOUT) and was stopped"; fi
[ "$rc" -eq 0 ] || die "claude -p failed (exit $rc)"
note=""
if [ "$(state)" != "$before" ]; then
  [ "$mode" = suite ] || die "$wt or the main checkout $main moved or changed during the review; check them and queue it again"
  note="note: $wt or the main checkout $main moved during the audit; the audit is of $sha"
fi

review="$(python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print("cost $%.2f, %.0f s" % (d.get("total_cost_usd") or 0, (d.get("duration_ms") or 0) / 1000))
print(d.get("result") or "")
' <"$json")" || die "couldn't read claude's output"
body=""
if [[ "$review" == *$'\n'* ]]; then body="${review#*$'\n'}"; fi
printf '# %s%s)\n\n%s\n' "$title" "${review%%$'\n'*}" "$body" > "$out"

if [ "$mode" = suite ]; then
  # A label line, with markdown around the label (**Counts**:, **Counts:**) or as a list item (- Counts:, 1. Counts:)
  md="[[:space:]*_\`]*"; lead="^[[:space:]>+-]*([0-9]+[.)])?$md"
  summary="$(grep -iE "$lead(suite audit|counts|not checked)$md:" "$out")"
  grep -qiE "${lead}counts$md:" <<<"$summary" || die "no Counts line in the audit (saved to $out)"
  head -1 "$out"; echo "$summary"
  if [ -n "$note" ]; then echo "$note"; fi
  echo "(saved to $out)"
  exit 0
fi
cat "$out"
echo "(saved to $out)"
case "$(verdict "$out")" in
  ready) exit 0 ;;
  "needs changes") exit 1 ;;
  *) echo "review: no verdict in the review" >&2; exit 2 ;;
esac
