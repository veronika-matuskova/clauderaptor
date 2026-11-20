# Tests for install.sh, run against a copy of the repo layout so the real config is untouched.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

SRC="$TMP/repo"; DEST="$TMP/home/.claude"
mkdir -p "$SRC/claude/rules" "$SRC/claude/skills" "$SRC/claude/agents"
cp "$ROOT/install.sh" "$SRC/"
echo "# g" > "$SRC/claude/CLAUDE.md"; echo "x" > "$SRC/claude/statusline.py"
cat > "$SRC/claude/settings.json" <<'EOF'
{"theme": "dark", "modelSettings": {"a": {"effortLevel": "low"}, "b": {"effortLevel": "low"}}}
EOF
cat > "$SRC/claude/settings.local.json" <<'EOF'
{"modelSettings": {"a": {"effortLevel": "xhigh"}}, "extra": true}
EOF
run() { CLAUDE_CONFIG_DIR="$DEST" bash "$SRC/install.sh"; }
get() { python3 -c "import json,sys; d=json.load(open('$DEST/settings.json')); print(eval(sys.argv[1]))" "$1"; }

# Pre-existing regular file is backed up, not lost
mkdir -p "$DEST"; echo "old" > "$DEST/CLAUDE.md"
run >/dev/null
assert "existing CLAUDE.md backed up" bash -c "grep -q old '$DEST'/CLAUDE.md.bak.*"
for item in CLAUDE.md statusline.py rules skills agents; do
  assert "$item is a symlink into the repo" test "$(readlink "$DEST/$item")" = "$SRC/claude/$item"
done
assert "commands/ is no longer linked" test ! -e "$DEST/commands"

# settings.json: generated regular file, local deep-merged over shared
assert "settings.json is a regular file" test -f "$DEST/settings.json" -a ! -L "$DEST/settings.json"
assert "shared key kept" test "$(get "d['theme']")" = dark
assert "local overrides nested key" test "$(get "d['modelSettings']['a']['effortLevel']")" = xhigh
assert "sibling nested key kept" test "$(get "d['modelSettings']['b']['effortLevel']")" = low
assert "local-only key added" test "$(get "d['extra']")" = True

# Re-run with no changes: idempotent, no settings backup
rm -f "$DEST"/*.bak.*
run >/dev/null
assert "re-run makes no backups" bash -c "! ls '$DEST'/*.bak.* 2>/dev/null"

# Runtime change (e.g. /effort) is backed up before being overwritten
echo '{"changed": 1}' > "$DEST/settings.json"
out="$(run)"
assert_contains "warns about runtime changes" "$out" "had changes not in the repo"
assert "runtime settings backed up" bash -c "grep -q changed '$DEST'/settings.json.bak.*"

# Old install where settings.json was a symlink gets replaced by a generated file
rm "$DEST/settings.json"; ln -s "$SRC/claude/settings.json" "$DEST/settings.json"
run >/dev/null
assert "symlinked settings.json replaced" test -f "$DEST/settings.json" -a ! -L "$DEST/settings.json"
assert "repo settings.json not overwritten" grep -q '"low"' "$SRC/claude/settings.json"

# Missing settings.local.json is fine
rm "$SRC/claude/settings.local.json"
run >/dev/null
assert "works without settings.local.json" test "$(get "d['modelSettings']['a']['effortLevel']")" = low

# Pre-commit hook: not configured outside a git checkout, configured inside one
mkdir -p "$SRC/.githooks"
assert_not_contains "no hook setup outside git" "$(run)" "pre-commit"
git init -q "$SRC"
assert_contains "announces pre-commit hook" "$(run)" "enabled pre-commit tests"
assert "core.hooksPath set" test "$(git -C "$SRC" config core.hooksPath)" = .githooks

finish
