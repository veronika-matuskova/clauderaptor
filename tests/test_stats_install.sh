# shellcheck shell=bash
# Tests for apps/stats/install.sh: the raptor-stats link in a temp bin folder ($XDG_BIN_HOME, else $HOME/.local/bin).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

IN="$ROOT/apps/stats/install.sh"
DS="$ROOT/apps/stats/dashboard.sh"
export HOME="$TMP/home"
unset XDG_BIN_HOME
BIN="$TMP/bin"
mkdir -p "$HOME"

echo "-- install"
out="$(XDG_BIN_HOME="$BIN" PATH="$BIN:$PATH" bash "$IN" 2>&1)"; rc=$?
assert "exit 0" test "$rc" -eq 0
assert "raptor-stats links to dashboard.sh" test "$(readlink "$BIN/raptor-stats")" = "$DS"
assert_contains "says what it linked" "$out" "installed: $BIN/raptor-stats -> $DS"
assert_contains "on the PATH: says how to run it" "$out" "run: raptor-stats"
assert_not_contains "on the PATH: no PATH note" "$out" "not on your PATH"

out="$(XDG_BIN_HOME="$BIN" PATH="$BIN:$PATH" bash "$IN" 2>&1)"; rc=$?
assert "again: exit 0" test "$rc" -eq 0
assert "again: still the link" test "$(readlink "$BIN/raptor-stats")" = "$DS"

echo "-- default folder, not on the PATH"
out="$(bash "$IN" 2>&1)"; rc=$?
assert "exit 0" test "$rc" -eq 0
assert "the link in ~/.local/bin" test "$(readlink "$HOME/.local/bin/raptor-stats")" = "$DS"
assert_contains "notes the folder is not on the PATH" "$out" "$HOME/.local/bin is not on your PATH"

echo "-- a file in the way"
B2="$TMP/bin2"; mkdir -p "$B2"; echo mine > "$B2/raptor-stats"
out="$(XDG_BIN_HOME="$B2" bash "$IN" 2>&1)"; rc=$?
assert "exit 1" test "$rc" -eq 1
assert_contains "says why" "$out" "exists and is not a link"
assert "the file is kept" test "$(cat "$B2/raptor-stats")" = mine

echo "-- the link runs the app (from another folder)"
# dashboard.sh finds stats.py and report.py through the link: stub python3 to record what it runs.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/python3" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PY_ARGV"
EOF
chmod +x "$TMP/stub/python3"
export PY_ARGV="$TMP/py.argv"
(cd "$TMP" && PATH="$TMP/stub:$PATH" "$BIN/raptor-stats" --windows-user bob >/dev/null 2>&1); rc=$?
assert "exit 0" test "$rc" -eq 0
assert_contains "ingest from the app's folder" "$(cat "$PY_ARGV")" "-I -B $ROOT/apps/stats/stats.py ingest"
assert_contains "then the report, with the arguments" "$(cat "$PY_ARGV")" \
  "-I -B $ROOT/apps/stats/report.py --open --windows-user bob"

echo "-- uninstall"
out="$(XDG_BIN_HOME="$B2" bash "$IN" --uninstall 2>&1)"; rc=$?
assert "not this app's link: exit 1" test "$rc" -eq 1
assert_contains "says so" "$out" "is not this app's link"
assert "and keeps it" test -f "$B2/raptor-stats"
ln -s /elsewhere "$TMP/bin3-link"; mkdir -p "$TMP/bin3"; mv "$TMP/bin3-link" "$TMP/bin3/raptor-stats"
out="$(XDG_BIN_HOME="$TMP/bin3" bash "$IN" --uninstall 2>&1)"; rc=$?
assert "another link: exit 1" test "$rc" -eq 1
assert "and keeps it" test -L "$TMP/bin3/raptor-stats"
out="$(XDG_BIN_HOME="$BIN" bash "$IN" --uninstall 2>&1)"; rc=$?
assert "this app's link: exit 0" test "$rc" -eq 0
assert "removed" test ! -e "$BIN/raptor-stats"
assert_contains "says so" "$out" "removed: $BIN/raptor-stats"
out="$(XDG_BIN_HOME="$BIN" bash "$IN" --uninstall 2>&1)"; rc=$?
assert "nothing installed: exit 0" test "$rc" -eq 0
assert_contains "says so" "$out" "not installed"

echo "-- arguments"
out="$(bash "$IN" --help 2>&1)"; rc=$?
assert "--help: exit 0" test "$rc" -eq 0
assert_contains "--help shows the usage" "$out" "install.sh --uninstall"
out="$(bash "$IN" --bogus 2>&1)"; rc=$?
assert "unknown argument: exit 2" test "$rc" -eq 2
assert_contains "says which" "$out" "unknown argument: --bogus"

finish
