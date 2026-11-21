#!/usr/bin/env bash
# Reviews a worktree's branch with Claude Code's built-in /code-review, in a new headless session every time,
# so the review never carries the calling session's context:
#   review.sh <worktree> [low|medium|high|xhigh]     (default medium; use high for migrations, auth or RLS)
# Runs `claude -p` inside the worktree, without the Edit and Write tools, and saves the review to
# $REVIEW_DIR (default ${XDG_STATE_HOME:-~/.local/state}/reviews)/<branch>-<sha>.md.
# Prints the findings and a last line "Verdict: ready" or "Verdict: needs changes" (an important finding
# or a broken repo rule). Exit 0 = ready, 1 = needs changes, 2 = the review didn't run.
set -uo pipefail
die() { echo "review: $*" >&2; exit 2; }
if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: review.sh <worktree> [low|medium|high|xhigh]"; fi
level="${2:-medium}"
case "$level" in low|medium|high|xhigh) ;; *) die "level must be low, medium, high or xhigh, not $level" ;; esac
wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "$1 is not a git checkout"
branch="$(git -C "$wt" branch --show-current)"
[ -n "$branch" ] || die "$wt is not on a branch"
sha="$(git -C "$wt" rev-parse --short HEAD)"
dir="${REVIEW_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reviews}"
mkdir -p "$dir" || die "can't create $dir"
out="$dir/${branch//\//-}-$sha.md"

prompt="Invoke the code-review skill with the Skill tool, args \"$level $branch\". When it is done, print every \
finding as plain text (severity, file:line, summary, failure scenario). Then end with exactly one line: \
\"Verdict: needs changes\" if any finding is important or breaks a rule from CLAUDE.md or .claude/rules, \
otherwise \"Verdict: ready\". If the skill is not available, print \"Verdict: failed\" and stop without reviewing."
json="$(cd "$wt" && claude -p "$prompt" --output-format json --permission-mode auto \
  --disallowed-tools "Edit,Write,NotebookEdit")" || die "claude -p failed (exit $?)"

review="$(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
print("cost $%.2f, %.0f s" % (d.get("total_cost_usd") or 0, (d.get("duration_ms") or 0) / 1000))
print(d.get("result") or "")
' "$json")" || die "couldn't read claude's output"
printf '# Review of %s at %s (/code-review %s, %s)\n\n%s\n' "$branch" "$sha" "$level" "${review%%$'\n'*}" \
  "${review#*$'\n'}" > "$out"
cat "$out"
echo "(saved to $out)"
case "$(grep -o '^Verdict: .*' "$out" | tail -1)" in
  "Verdict: ready") exit 0 ;;
  "Verdict: needs changes") exit 1 ;;
  *) echo "review: no verdict in the review" >&2; exit 2 ;;
esac
