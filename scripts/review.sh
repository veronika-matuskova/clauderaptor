#!/usr/bin/env bash
# Reviews a worktree's branch with Claude Code's built-in /code-review, in a new headless session every time,
# so the review never carries the calling session's context:
#   review.sh <worktree> [low|medium|high|xhigh]     (default medium; use high for migrations, auth or RLS)
# The session runs in the repo's main checkout, so the base branch's CLAUDE.md, rules and settings apply, not
# the ones the reviewed branch may change. It has no Edit or Write tools, and the review fails if the worktree's
# files or either checkout's HEAD or branch changed meanwhile. It is stopped after $REVIEW_TIMEOUT seconds (1800).
# The review is saved to $REVIEW_DIR (default $PR_QUEUE_DIR/reviews, the folder pr-queue.sh uses) as
# <branch>-<sha>-<level>.md. A commit already reviewed as ready at that level or a higher one isn't reviewed again.
# Prints the findings and a last line "Verdict: ready" or "Verdict: needs changes" (an important finding
# or a broken repo rule), then "(saved to <file>)". Exit 0 = ready, 1 = needs changes, 2 = the review didn't run.
set -uo pipefail
die() { echo "review: $*" >&2; exit 2; }
# verdict <file>: "ready", "needs changes" or "failed", from the last verdict line (markdown and case ignored).
verdict() {
  grep -oiE 'verdict:[[:space:]*_`]*(ready|needs changes|failed)' "$1" 2>/dev/null | tail -1 \
    | grep -oiE 'ready|needs changes|failed' | tr '[:upper:]' '[:lower:]'
}
# state: what must not change during a review: the worktree's HEAD and files, and where the main checkout is.
# (Its files may change: someone may be working there.)
state() {
  git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain
  git -C "$main" rev-parse HEAD; git -C "$main" branch --show-current
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: review.sh <worktree> [low|medium|high|xhigh]"; fi
level="${2:-medium}"
case "$level" in low|medium|high|xhigh) ;; *) die "level must be low, medium, high or xhigh, not $level" ;; esac
wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
branch="$(git -C "$wt" branch --show-current)"
[ -n "$branch" ] || die "$wt is not on a branch"
sha="$(git -C "$wt" rev-parse --short=12 HEAD)"
main="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
dir="${REVIEW_DIR:-${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/reviews}"
mkdir -p "$dir" || die "can't create $dir"
base="$dir/${branch//\//-}-$sha"; out="$base-$level.md"
higher=""
for l in low medium high xhigh; do
  if [ "$l" = "$level" ]; then higher=1; fi
  if [ -n "$higher" ] && [ "$(verdict "$base-$l.md")" = ready ]; then
    cat "$base-$l.md"; echo "already reviewed as ready"; echo "(saved to $base-$l.md)"; exit 0
  fi
done

prompt="Invoke the code-review skill with the Skill tool, args \"$level $branch\". When it is done, print every \
finding as plain text (severity, file:line, summary, failure scenario). Then end with exactly one line: \
\"Verdict: needs changes\" if any finding is important or breaks a rule from CLAUDE.md or .claude/rules, \
otherwise \"Verdict: ready\". If the skill is not available, print \"Verdict: failed\" and stop without reviewing."
before="$(state)"
limit="${REVIEW_TIMEOUT:-1800}"
json="$(cd "$main" && timeout "$limit" claude -p "$prompt" --output-format json --permission-mode auto \
  --disallowed-tools "Edit,Write,NotebookEdit")"
rc=$?
if [ "$rc" -eq 124 ]; then die "the review took longer than ${limit}s (REVIEW_TIMEOUT) and was stopped"; fi
[ "$rc" -eq 0 ] || die "claude -p failed (exit $rc)"
[ "$(state)" = "$before" ] || die "$wt or the main checkout $main moved or changed during the review; check them and queue it again"

review="$(printf '%s' "$json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print("cost $%.2f, %.0f s" % (d.get("total_cost_usd") or 0, (d.get("duration_ms") or 0) / 1000))
print(d.get("result") or "")
')" || die "couldn't read claude's output"
printf '# Review of %s at %s (/code-review %s, %s)\n\n%s\n' "$branch" "$sha" "$level" "${review%%$'\n'*}" \
  "${review#*$'\n'}" > "$out"
cat "$out"
echo "(saved to $out)"
case "$(verdict "$out")" in
  ready) exit 0 ;;
  "needs changes") exit 1 ;;
  *) echo "review: no verdict in the review" >&2; exit 2 ;;
esac
