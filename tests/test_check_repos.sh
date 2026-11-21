# shellcheck shell=bash
# Tests for check-repos.sh using local bare remotes (no network) and a stub gh.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

W="$TMP/ws"; mkdir -p "$W/repos"
cp "$ROOT/check-repos.sh" "$W/"
run() { bash "$W/check-repos.sh" </dev/null; }

# Remote with one commit; make a clone per scenario
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" commit -q --allow-empty -m init && git -C "$TMP/seed" push -q origin main
clone() { git clone -q "$TMP/remote.git" "$W/repos/$1"; }

clone clean
clone ahead;    git -C "$W/repos/ahead" commit -q --allow-empty -m local
clone dirty;    echo x > "$W/repos/dirty/file.txt"
clone behind
clone diverged; git -C "$W/repos/diverged" commit -q --allow-empty -m local
clone nobranch; git -C "$W/repos/nobranch" checkout -q -b feature
clone other;    git -C "$W/repos/other" branch -q wip
mkdir "$W/repos/notgit"
# Advance the remote so 'behind' and 'diverged' are behind it (they fetch it)
git -C "$TMP/seed" commit -q --allow-empty -m remote && git -C "$TMP/seed" push -q origin main
git -C "$W/repos/clean" pull -q --ff-only
git -C "$W/repos/ahead" pull -q --rebase
git -C "$W/repos/dirty" pull -q --ff-only
git -C "$W/repos/other" pull -q --ff-only

out="$(run)"
assert_contains "clean repo"        "$out" "branch main: clean, up to date with origin/main"
assert_contains "ahead -> push"     "$out" "1 commit(s) ahead of origin/main"
assert_contains "ahead suggestion"  "$out" "cd repos/ahead && git push"
assert_contains "behind -> pull"    "$out" "1 commit(s) behind origin/main"
assert_contains "behind suggestion" "$out" "cd repos/behind && git pull --ff-only"
assert_contains "diverged"          "$out" "diverged (1 ahead, 1 behind origin/main)"
assert_contains "dirty count"       "$out" "branch main: 1 uncommitted change(s)"
assert_contains "dirty file listed" "$out" "file.txt"
assert_contains "no upstream"       "$out" "git push -u origin feature"
assert_contains "other branch"      "$out" "other branch wip: not pushed (no upstream)"
assert_contains "non-git skipped"   "$out" "not a git repo, skipping"
assert "never pushes by itself" test "$(git -C "$TMP/remote.git" rev-list --count main)" = 2

# Empty repos/: lists GitHub repos via gh and clones what the user types
E="$TMP/empty"; mkdir -p "$E/bin"; cp "$ROOT/check-repos.sh" "$E/"
cat > "$E/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$E/gh.log"
case "\$1 \$2" in
  "repo list")  echo "me/one"; echo "me/two" ;;
  "repo clone") git clone -q "$TMP/remote.git" "\$4" ;;
esac
EOF
chmod +x "$E/bin/gh"
out="$(printf 'me/one\nhttps://github.com/me/two.git\nme/one\n\n' | PATH="$E/bin:$PATH" bash "$E/check-repos.sh")"
assert_contains "prompts when empty" "$out" "No repos cloned in repos/ yet."
assert_contains "lists GitHub repos" "$out" "  me/two"
assert "cloned owner/name"           test -d "$E/repos/one/.git"
assert "cloned URL (strips .git)"    test -d "$E/repos/two/.git"
assert_contains "skips existing"     "$out" "repos/one already exists, skipping"
assert_contains "checks new clones"  "$out" "== one"
assert "clone called twice" test "$(grep -c '^repo clone' "$E/gh.log")" = 2

# Empty repos/ without gh: clear error
M="$TMP/nogh"; mkdir -p "$M/bin"; cp "$ROOT/check-repos.sh" "$M/"
for c in bash dirname mkdir; do ln -s "$(command -v "$c")" "$M/bin/$c"; done
out="$(PATH="$M/bin" bash "$M/check-repos.sh" </dev/null)"
assert_contains "asks to run setup-tools without gh" "$out" "run ./setup-tools.sh first"

finish
