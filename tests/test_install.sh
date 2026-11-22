# shellcheck shell=bash
# Tests for install.sh, run against a copy of the repo layout so the real config is untouched.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

SRC="$TMP/repo"; DEST="$TMP/home/.claude"
mkdir -p "$SRC/scripts/setup" "$SRC/claude/rules" "$SRC/claude/skills" "$SRC/claude/agents"
cp "$ROOT/scripts/setup/install.sh" "$SRC/scripts/setup/"
echo "# g" > "$SRC/claude/CLAUDE.md"; echo "x" > "$SRC/claude/statusline.py"
cat > "$SRC/claude/settings.json" <<'EOF'
{"theme": "dark", "permissions": {"deny": ["a", "b"]}, "items": [{"x": 1, "y": 2}],
 "modelSettings": {"a": {"effortLevel": "low"}, "b": {"effortLevel": "low"}}}
EOF
cat > "$SRC/claude/settings.local.json" <<'EOF'
{"permissions": {"deny": ["b", "c"]}, "items": [{"y": 2, "x": 1}, {"z": 3}],
 "modelSettings": {"a": {"effortLevel": "xhigh"}}, "extra": true}
EOF
run() { CLAUDE_CONFIG_DIR="$DEST" bash "$SRC/scripts/setup/install.sh" 2>&1; }
get() { python3 -c "import json,sys; d=json.load(open('$DEST/settings.json')); print(eval(sys.argv[1]))" "$1"; }
# edit <python statement on d>: changes the live settings.json, as another tool or /config would
edit() { python3 -c "import json,sys; p='$DEST/settings.json'; d=json.load(open(p)); exec(sys.argv[1]); json.dump(d, open(p, 'w'), indent=2)" "$1"; }
hook='d["hooks"]["SessionStart"][0]["hooks"][0]["command"]'

# Pre-existing regular file and a link to somewhere else are backed up, not lost
mkdir -p "$DEST" "$TMP/other-agents"; echo "old" > "$DEST/CLAUDE.md"; ln -s "$TMP/other-agents" "$DEST/agents"
out="$(run)"
assert "existing CLAUDE.md backed up" bash -c "grep -q old '$DEST'/CLAUDE.md.bak.*"
assert "foreign link backed up as a link" bash -c "test \"\$(readlink '$DEST'/agents.bak.*)\" = '$TMP/other-agents'"
assert_contains "foreign link: says where it pointed" "$out" "backed up $DEST/agents (it linked to $TMP/other-agents)"
for item in CLAUDE.md statusline.py rules skills agents; do
  assert "$item is a symlink into the repo" test "$(readlink "$DEST/$item")" = "$SRC/claude/$item"
done
assert "commands/ is no longer linked" test ! -e "$DEST/commands"

# settings.json: generated regular file, local merged over shared, lists combined
assert "settings.json is a regular file" test -f "$DEST/settings.json" -a ! -L "$DEST/settings.json"
assert "shared key kept" test "$(get "d['theme']")" = dark
assert "local overrides nested key" test "$(get "d['modelSettings']['a']['effortLevel']")" = xhigh
assert "sibling nested key kept" test "$(get "d['modelSettings']['b']['effortLevel']")" = low
assert "local-only key added" test "$(get "d['extra']")" = True
assert "lists combine, duplicates dropped" test "$(get "d['permissions']['deny']")" = "['a', 'b', 'c']"
assert "list items compared by value" test "$(get "d['items']")" = "[{'x': 1, 'y': 2}, {'z': 3}]"
assert_not_contains "fresh install keeps nothing" "$out" "kept keys"

# Re-run with no changes: idempotent, no settings backup
rm -f "$DEST"/*.bak.*
run >/dev/null
assert "re-run makes no backups" bash -c "! ls '$DEST'/*.bak.* 2>/dev/null"

# Keys another tool added that the repo doesn't set (top-level or under a repo dict) are kept and listed
edit 'd["hooks"] = {"SessionStart": [{"hooks": [{"type": "command", "command": "skydeck-hook"}]}]}; d["modelSettings"]["c"] = {"effortLevel": "high"}'
out="$(run)"
assert "foreign: top-level key kept" test "$(get "$hook")" = skydeck-hook
assert "foreign: nested key kept" test "$(get "d['modelSettings']['c']['effortLevel']")" = high
assert "foreign: repo keys still set" test "$(get "d['modelSettings']['a']['effortLevel']")" = xhigh
assert_contains "foreign: lists them" "$out" "kept keys not set in the repo: hooks, modelSettings.c"
assert_contains "foreign: says how to keep them" "$out" "add them to claude/settings.local.json"
rm -f "$DEST"/*.bak.*; cp "$DEST/settings.json" "$TMP/settings.before"
run >/dev/null
assert "foreign: re-run makes no backup" bash -c "! ls '$DEST'/*.bak.* 2>/dev/null"
assert "foreign: re-run leaves the file as is" cmp -s "$TMP/settings.before" "$DEST/settings.json"

# A runtime change to a key the repo sets (/config theme) is reset to the repo's value and backed up
edit 'd["theme"] = "light"'
out="$(run)"
assert_contains "warns about runtime changes" "$out" "had changes not in the repo"
assert "runtime settings backed up" bash -c "grep -q light '$DEST'/settings.json.bak.*"
assert "repo value restored" test "$(get "d['theme']")" = dark
assert "foreign keys survive the reset" test "$(get "$hook")" = skydeck-hook

# Old install where settings.json was a symlink gets replaced by a generated file
rm "$DEST/settings.json"; ln -s "$SRC/claude/settings.json" "$DEST/settings.json"
run >/dev/null
assert "symlinked settings.json replaced" test -f "$DEST/settings.json" -a ! -L "$DEST/settings.json"
assert "repo settings.json not overwritten" grep -q '"low"' "$SRC/claude/settings.json"

# A settings.json that isn't valid JSON: backed up, nothing kept from it, a new one written
rm -f "$DEST"/*.bak.*; echo '{"broken": ' > "$DEST/settings.json"
out="$(run)"; rc=$?
assert "invalid: install still succeeds" test "$rc" -eq 0
assert_contains "invalid: warns" "$out" "is not valid JSON"
assert "invalid: backed up" bash -c "grep -q broken '$DEST'/settings.json.bak.*"
assert "invalid: new file written" test "$(get "d['theme']")" = dark

# Missing settings.local.json is fine; a key only it set is no longer the repo's, so it stays and is listed
rm "$SRC/claude/settings.local.json"
out="$(run)"
assert "works without settings.local.json" test "$(get "d['modelSettings']['a']['effortLevel']")" = low
assert "repo-owned list follows the repo" test "$(get "d['permissions']['deny']")" = "['a', 'b']"
assert_contains "key the repo stopped setting: kept and listed" "$out" "kept keys not set in the repo: extra"

# Pre-commit hook: not configured outside a git checkout, configured inside one
mkdir -p "$SRC/.githooks"
assert_not_contains "no hook setup outside git" "$(run)" "pre-commit"
git init -q "$SRC"
assert_contains "announces pre-commit hook" "$(run)" "enabled pre-commit tests"
assert "core.hooksPath set" test "$(git -C "$SRC" config core.hooksPath)" = .githooks

finish
