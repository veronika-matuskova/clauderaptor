#!/usr/bin/env bash
# Symlinks this repo's claude/ contents into ~/.claude (backs up existing files).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/claude"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$DEST"
for item in CLAUDE.md settings.json rules skills agents commands; do
  target="$DEST/$item"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mv "$target" "$target.bak.$(date +%Y%m%d%H%M%S)"
    echo "backed up $target"
  fi
  ln -sfn "$SRC/$item" "$target"
  echo "linked $target -> $SRC/$item"
done
