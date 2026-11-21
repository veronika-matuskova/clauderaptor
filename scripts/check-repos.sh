#!/usr/bin/env bash
# Checks repos cloned under repos/.
# - None cloned yet: asks which GitHub repos to clone (owner/name or URL).
# - Otherwise: fetches each one, shows its status and suggests push/pull.
set -uo pipefail
REPOS="$(cd "$(dirname "$0")/.." && pwd)/repos"
mkdir -p "$REPOS"

clone_prompt() {
  command -v gh >/dev/null 2>&1 || { echo "gh not found; run scripts/setup-tools.sh first"; exit 1; }
  echo "Your GitHub repos:"
  gh repo list --limit 50 --json nameWithOwner -q '.[].nameWithOwner' | sed 's/^/  /'
  while true; do
    read -rp "Repo to clone (owner/name or URL, empty to stop): " repo
    [ -z "$repo" ] && break
    name="$(basename "${repo%.git}")"
    if [ -e "$REPOS/$name" ]; then
      echo "  repos/$name already exists, skipping"
      continue
    fi
    gh repo clone "$repo" "$REPOS/$name" || echo "  clone of $repo failed"
  done
}

check_repo() {
  local dir="$1" name branch upstream ahead behind dirty
  name="$(basename "$dir")"
  echo "== $name"
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "   not a git repo, skipping"; return
  fi
  git -C "$dir" fetch --quiet --all --prune 2>/dev/null || echo "   (fetch failed; remote info may be stale)"

  branch="$(git -C "$dir" symbolic-ref --short -q HEAD)"
  if [ -z "$branch" ]; then
    echo "   detached HEAD at $(git -C "$dir" rev-parse --short HEAD)"; return
  fi

  dirty="$(git -C "$dir" status --porcelain | wc -l)"
  if [ "$dirty" -gt 0 ]; then
    echo "   branch $branch: $dirty uncommitted change(s)"
    git -C "$dir" status --short | head -10 | sed 's/^/     /'
    echo "   -> commit or stash them: cd repos/$name && git add -p && git commit"
  fi

  # for-each-ref is empty when there's no upstream (newer git's rev-parse prints '@{upstream}' instead)
  upstream="$(git -C "$dir" for-each-ref --format='%(upstream:short)' "refs/heads/$branch")"
  if [ -z "$upstream" ]; then
    echo "   branch $branch has no upstream"
    echo "   -> publish it: cd repos/$name && git push -u origin $branch"
    return
  fi

  read -r ahead behind < <(git -C "$dir" rev-list --left-right --count "HEAD...$upstream")
  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
    [ "$dirty" -eq 0 ] && echo "   branch $branch: clean, up to date with $upstream"
    [ "$dirty" -gt 0 ] && echo "   branch $branch: in sync with $upstream (apart from local changes)"
  elif [ "$behind" -eq 0 ]; then
    echo "   branch $branch: $ahead commit(s) ahead of $upstream"
    echo "   -> push: cd repos/$name && git push"
  elif [ "$ahead" -eq 0 ]; then
    echo "   branch $branch: $behind commit(s) behind $upstream"
    echo "   -> pull: cd repos/$name && git pull --ff-only"
  else
    echo "   branch $branch: diverged ($ahead ahead, $behind behind $upstream)"
    echo "   -> pull --rebase then push: cd repos/$name && git pull --rebase && git push"
  fi

  # Other local branches with unpushed commits
  git -C "$dir" for-each-ref --format='%(refname:short) %(upstream:short) %(upstream:track)' refs/heads \
    | while read -r b up track; do
        [ "$b" = "$branch" ] && continue
        if [ -z "$up" ]; then echo "   other branch $b: not pushed (no upstream)"
        elif [ -n "$track" ]; then echo "   other branch $b: $track vs $up"
        fi
      done
}

shopt -s nullglob
dirs=("$REPOS"/*/)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No repos cloned in repos/ yet."
  clone_prompt
  dirs=("$REPOS"/*/)
fi

for d in "${dirs[@]}"; do check_repo "${d%/}"; done
