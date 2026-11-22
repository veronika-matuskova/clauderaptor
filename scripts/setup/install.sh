#!/usr/bin/env bash
# Symlinks this repo's claude/ contents into ~/.claude (backs up existing files and links to elsewhere)
# and builds ~/.claude/settings.json from claude/settings.json (shared, committed)
# merged with claude/settings.local.json (this machine only, gitignored): dicts merge,
# lists combine (as Claude Code combines them across its settings files), other values: local wins.
# Keys of the old settings.json that the repo doesn't set (e.g. another tool's hooks) are kept.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)/claude"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$DEST"
stamp="$(date +%Y%m%d%H%M%S)"

for item in CLAUDE.md statusline.py rules skills agents; do
  target="$DEST/$item"
  if [ -L "$target" ] && [ "$(readlink "$target")" != "$SRC/$item" ]; then
    # A link somewhere else (another config repo, an old checkout): keep it rather than replace it silently
    echo "backed up $target (it linked to $(readlink "$target"))"
    mv "$target" "$target.bak.$stamp"
  elif [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.bak.$stamp"
    echo "backed up $target"
  fi
  ln -sfn "$SRC/$item" "$target"
  echo "linked $target -> $SRC/$item"
done

# settings.json is generated, not linked, so runtime changes (/effort, /config)
# stay out of the repo. The repo owns every key it sets: a runtime change to one is backed
# up and reset, so move the ones you want to keep into a settings file here. Keys the repo
# doesn't set are kept from the old file and listed.
target="$DEST/settings.json"
merged="$(python3 - "$SRC/settings.json" "$SRC/settings.local.json" "$target" <<'EOF'
import json, os, sys
shared, local, live = sys.argv[1:]

def uniq(items):
    seen, out = set(), []
    for x in items:
        k = json.dumps(x, sort_keys=True)
        if k not in seen:
            seen.add(k)
            out.append(x)
    return out

def merge(a, b):
    """b over a: dicts merge, lists combine without duplicates, any other value: b wins."""
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            a[k] = merge(a[k], v)
        elif isinstance(v, list) and isinstance(a.get(k), list):
            a[k] = uniq(a[k] + v)
        else:
            a[k] = v
    return a

def keep(out, old, path=""):
    """Copies into out every key of old that out doesn't set; returns their dotted paths."""
    kept = []
    for k, v in old.items():
        if k not in out:
            out[k] = v
            kept.append(path + k)
        elif isinstance(out[k], dict) and isinstance(v, dict):
            kept += keep(out[k], v, path + k + ".")
    return kept

out = {}
for p in (shared, local):
    if os.path.exists(p):
        with open(p) as f:
            out = merge(out, json.load(f))
# The old file (not the symlink of old installs): keep the keys the repo doesn't set
if os.path.isfile(live) and not os.path.islink(live):
    try:
        with open(live) as f:
            old = json.load(f)
        if not isinstance(old, dict):
            raise ValueError("not a JSON object")
    except ValueError as e:
        print(f"{live} is not valid JSON ({e}); nothing is kept from it", file=sys.stderr)
        old = {}
    kept = keep(out, old)
    if kept:
        print(f"kept keys not set in the repo: {', '.join(sorted(kept))}\n"
              f"  add them to claude/settings.local.json to keep them in the repo, or delete them from {live}",
              file=sys.stderr)
print(json.dumps(out, indent=2))
EOF
)"
if [ -L "$target" ]; then
  rm "$target"
elif [ -f "$target" ] && [ "$(cat "$target")" != "$merged" ]; then
  mv "$target" "$target.bak.$stamp"
  echo "backed up $target (it had changes not in the repo; diff it against the new one)"
fi
printf '%s\n' "$merged" > "$target"
echo "wrote $target from settings.json + settings.local.json"

# Run tests/run.sh before every commit in this repo (only when installing from a git checkout)
REPO="$(dirname "$SRC")"
if [ -d "$REPO/.githooks" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" config core.hooksPath .githooks
  echo "enabled pre-commit tests (core.hooksPath=.githooks)"
fi
