# Tests for setup-tools.sh with stubbed sudo/apt/curl/gh, so nothing is installed for real.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# Minimal PATH: only these real tools + stubs, so "already installed" is under our control.
setup_bin() {
  BIN="$TMP/bin.$1"; LOG="$TMP/log.$1"; mkdir -p "$BIN"; : > "$LOG"
  for c in bash head cat; do ln -s "$(command -v "$c")" "$BIN/$c"; done
  # sudo: logs, swallows stdin for tee (like the real tee), and "installs" apt packages as gh stubs
  cat > "$BIN/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$LOG"
[ "\$1" = tee ] && cat >/dev/null
if [ "\$1 \$2" = "apt-get install" ]; then for p in "\${@:4}"; do $(command -v ln) -sf "$BIN/gh-stub" "$BIN/\$p"; done; fi
exit 0
EOF
  for c in curl dpkg; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$c" "$LOG" > "$BIN/$c"; done
  chmod +x "$BIN/sudo" "$BIN/curl" "$BIN/dpkg"
  # gh stub: 'auth status' fails until 'auth login' has run
  cat > "$BIN/gh-stub" <<EOF
#!/usr/bin/env bash
echo "\${0##*/} \$*" >> "$LOG"
case "\$1 \$2" in
  "auth status") [ -f "$BIN/.loggedin" ] ;;
  "auth login")  : > "$BIN/.loggedin" ;;
  "--version ")  echo "gh version 9.9" ;;
esac
EOF
  chmod +x "$BIN/gh-stub"
}
run() { PATH="$BIN" bash "$ROOT/setup-tools.sh"; }

# Fresh machine: installs gh and shellcheck, logs in, sets git helper
setup_bin fresh
run >/dev/null 2>&1; rc=$?
log="$(cat "$LOG")"
assert "fresh: exits 0" test "$rc" -eq 0
assert_contains "fresh: adds gh apt repo"   "$log" "sudo tee /etc/apt/sources.list.d/github-cli.list"
assert_contains "fresh: installs gh"        "$log" "sudo apt-get install -y gh"
assert_contains "fresh: installs shellcheck" "$log" "sudo apt-get install -y shellcheck"
assert_contains "fresh: logs in"            "$log" "gh auth login --hostname github.com --git-protocol https --web"
assert_contains "fresh: sets git helper"    "$log" "gh auth setup-git"

# Re-run on a set-up machine: no installs, no login
: > "$LOG"
out="$(run 2>&1)"
log="$(cat "$LOG")"
assert_not_contains "rerun: no apt"   "$log" "apt-get"
assert_not_contains "rerun: no login" "$log" "auth login"
assert_contains "rerun: reports gh"   "$out" "gh already installed: gh version 9.9"
assert_contains "rerun: reports auth" "$out" "gh already authenticated"
assert_contains "rerun: still sets git helper" "$log" "gh auth setup-git"

finish
