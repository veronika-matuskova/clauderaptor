#!/usr/bin/env bash
# Reviews a worktree's branch with Claude Code's built-in /code-review, in a new headless session every time,
# so the review never carries the calling session's context:
#   review.sh <worktree> [low|medium|high|xhigh]     (default medium; use high for migrations, auth or RLS)
# The session runs in the repo's main checkout, so the base branch's CLAUDE.md, rules and settings apply, not
# the ones the reviewed branch may change. It has no Edit or Write tools, and the review fails if the session
# changes the worktree or the main checkout anyway.
# The review is saved to $REVIEW_DIR (default $PR_QUEUE_DIR/reviews, the folder pr-queue.sh uses) as
# <branch>-<sha>-<level>.md. A commit already reviewed as ready at that level isn't reviewed again.
# Prints the findings and a last line "Verdict: ready" or "Verdict: needs changes" (an important finding
# or a broken repo rule), then "(saved to <file>)". Exit 0 = ready, 1 = needs changes, 2 = the review didn't run.
set -uo pipefail
die() { echo "review: $*" >&2; exit 2; }
# verdict <file>: "ready", "needs changes" or "failed", from the last verdict line (markdown and case ignored).
verdict() {
  grep -oiE 'verdict:[[:space:]*_`]*(ready|needs changes|failed)' "$1" 2>/dev/null | tail -1 \
    | grep -oiE 'ready|needs changes|failed' | tr '[:upper:]' '[:lower:]'
}
# state: what a review must not change (the worktree's HEAD and files, the main checkout's tracked files).
state() { git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain; git -C "$main" status --porcelain --untracked-files=no; }

if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: review.sh <worktree> [low|medium|high|xhigh]"; fi
level="${2:-medium}"
case "$level" in low|medium|high|xhigh) ;; *) die "level must be low, medium, high or xhigh, not $level" ;; esac
wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
branch="$(git -C "$wt" branch --show-current)"
[ -n "$branch" ] || die "$wt is not on a branch"
sha="$(git -C "$wt" rev-parse --short HEAD)"
main="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
dir="${REVIEW_DIR:-${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/reviews}"
mkdir -p "$dir" || die "can't create $dir"
out="$dir/${branch//\//-}-$sha-$level.md"
if [ "$(verdict "$out")" = ready ]; then
  cat "$out"; echo "already reviewed as ready"; echo "(saved to $out)"; exit 0
fi

prompt="Invoke the code-review skill with the Skill tool, args \"$level $branch\". When it is done, print every \
finding as plain text (severity, file:line, summary, failure scenario). Then end with exactly one line: \
\"Verdict: needs changes\" if any finding is important or breaks a rule from CLAUDE.md or .claude/rules, \
otherwise \"Verdict: ready\". If the skill is not available, print \"Verdict: failed\" and stop without reviewing."
before="$(state)"
json="$(cd "$main" && claude -p "$prompt" --output-format json --permission-mode auto \
  --disallowed-tools "Edit,Write,NotebookEdit")" || die "claude -p failed (exit $?)"
[ "$(state)" = "$before" ] || die "the review session changed $wt or $main; check them before going on"

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
