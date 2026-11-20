#!/usr/bin/env bash
# Symlinks this repo's claude/ contents into ~/.claude (backs up existing files)
# and builds ~/.claude/settings.json from claude/settings.json (shared, committed)
# deep-merged with claude/settings.local.json (this machine only, gitignored).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/claude"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$DEST"
stamp="$(date +%Y%m%d%H%M%S)"

for item in CLAUDE.md statusline.py rules skills agents; do
  target="$DEST/$item"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.bak.$stamp"
    echo "backed up $target"
  fi
  ln -sfn "$SRC/$item" "$target"
  echo "linked $target -> $SRC/$item"
done

# settings.json is generated, not linked, so runtime changes (/effort, /config)
# stay out of the repo. Move the ones you want to keep into a settings file here.
target="$DEST/settings.json"
merged="$(python3 - "$SRC/settings.json" "$SRC/settings.local.json" <<'EOF'
import json, os, sys
def merge(a, b):
    for k, v in b.items():
        a[k] = merge(a[k], v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
out = {}
for p in sys.argv[1:]:
    if os.path.exists(p):
        with open(p) as f:
            out = merge(out, json.load(f))
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
