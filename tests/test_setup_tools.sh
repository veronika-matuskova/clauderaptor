# shellcheck shell=bash
# Tests for setup-tools.sh with stubbed sudo/apt/curl/gh/ssh-keygen, so nothing is installed for real.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# Minimal PATH: only these real tools + stubs, so "already installed" is under our control.
# HOME and the global git config are per-scenario temp dirs.
setup_bin() {
  BIN="$TMP/bin.$1"; LOG="$TMP/log.$1"; H="$TMP/home.$1"; mkdir -p "$BIN" "$H"; : > "$LOG"
  for c in bash head cat git grep mkdir; do ln -s "$(command -v "$c")" "$BIN/$c"; done
  git config --file "$H/.gitconfig" user.email t@t
  # sudo: logs, swallows stdin for tee (like the real tee), and "installs" apt packages as gh stubs
  cat > "$BIN/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$LOG"
[ "\$1" = tee ] && cat >/dev/null
if [ "\$1 \$2" = "apt-get install" ]; then for p in "\${@:4}"; do $(command -v ln) -sf "$BIN/gh-stub" "$BIN/\$p"; done; fi
exit 0
EOF
  for c in curl dpkg; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$c" "$LOG" > "$BIN/$c"; done
  # ssh-keygen: writes a fake key pair to the -f path
  cat > "$BIN/ssh-keygen" <<EOF
#!/usr/bin/env bash
echo "ssh-keygen \$*" >> "$LOG"
while [ \$# -gt 0 ]; do [ "\$1" = -f ] && f="\$2"; shift; done
echo private > "\$f"; echo "ssh-ed25519 AAAAtest t@t" > "\$f.pub"
EOF
  chmod +x "$BIN/sudo" "$BIN/curl" "$BIN/dpkg" "$BIN/ssh-keygen"
  # gh stub: 'auth status' fails until 'auth login' has run and lists the signing scope after
  # 'auth refresh'; 'api' lists keys added with 'ssh-key add'
  cat > "$BIN/gh-stub" <<EOF
#!/usr/bin/env bash
echo "\${0##*/} \$*" >> "$LOG"
case "\$1 \$2" in
  "auth status")  [ -f "$BIN/.loggedin" ] || exit 1
                  echo "Token scopes: 'repo'"; [ -f "$BIN/.scoped" ] && echo "'admin:ssh_signing_key'"; exit 0 ;;
  "auth login")   : > "$BIN/.loggedin" ;;
  "auth refresh") : > "$BIN/.scoped" ;;
  "api "*)        cat "$BIN/.keys" 2>/dev/null ;;
  "ssh-key add")  read -r t k _ < "\$3"; echo "\$t \$k" >> "$BIN/.keys" ;;
  "--version ")   echo "gh version 9.9" ;;
esac
exit 0
EOF
  chmod +x "$BIN/gh-stub"
}
run() { PATH="$BIN" HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" bash "$ROOT/setup-tools.sh"; }
gitcfg() { git config --file "$H/.gitconfig" "$1"; }

# Fresh machine: installs gh and shellcheck, logs in, sets git helper, sets up signing
setup_bin fresh
run >/dev/null 2>&1; rc=$?
log="$(cat "$LOG")"
assert "fresh: exits 0" test "$rc" -eq 0
assert_contains "fresh: adds gh apt repo"   "$log" "sudo tee /etc/apt/sources.list.d/github-cli.list"
assert_contains "fresh: installs gh"        "$log" "sudo apt-get install -y gh"
assert_contains "fresh: installs shellcheck" "$log" "sudo apt-get install -y shellcheck"
assert_contains "fresh: logs in"            "$log" "gh auth login --hostname github.com --git-protocol https --web"
assert_contains "fresh: sets git helper"    "$log" "gh auth setup-git"
assert_contains "fresh: creates signing key" "$log" "-t ed25519 -N  -C t@t -f $H/.ssh/id_ed25519_signing"
assert_contains "fresh: adds signing scope" "$log" "gh auth refresh --hostname github.com --scopes admin:ssh_signing_key"
assert_contains "fresh: uploads signing key" "$log" "gh ssh-key add $H/.ssh/id_ed25519_signing.pub --type signing"
assert "fresh: gpg.format ssh"     test "$(gitcfg gpg.format)" = ssh
assert "fresh: signingkey set"     test "$(gitcfg user.signingkey)" = "$H/.ssh/id_ed25519_signing.pub"
assert "fresh: commit.gpgsign"     test "$(gitcfg commit.gpgsign)" = true
assert "fresh: tag.gpgsign"        test "$(gitcfg tag.gpgsign)" = true
assert "fresh: allowedSignersFile" test "$(gitcfg gpg.ssh.allowedSignersFile)" = "$H/.config/git/allowed_signers"
assert "fresh: allowed_signers entry" test "$(cat "$H/.config/git/allowed_signers")" = "t@t ssh-ed25519 AAAAtest"

# Re-run on a set-up machine: no installs, no login, no new key/scope/upload
: > "$LOG"
out="$(run 2>&1)"
log="$(cat "$LOG")"
assert_not_contains "rerun: no apt"   "$log" "apt-get"
assert_not_contains "rerun: no login" "$log" "auth login"
assert_contains "rerun: reports gh"   "$out" "gh already installed: gh version 9.9"
assert_contains "rerun: reports auth" "$out" "gh already authenticated"
assert_contains "rerun: still sets git helper" "$log" "gh auth setup-git"
assert_not_contains "rerun: no new key"    "$log" "ssh-keygen"
assert_not_contains "rerun: no refresh"    "$log" "auth refresh"
assert_not_contains "rerun: no upload"     "$log" "ssh-key add"
assert_contains "rerun: reports key"       "$out" "signing key already on GitHub"
assert "rerun: one allowed_signers entry"  test "$(cat "$H/.config/git/allowed_signers")" = "t@t ssh-ed25519 AAAAtest"

# No commit email: stops before creating a key or touching git config
setup_bin noemail
git config --file "$H/.gitconfig" --unset user.email
out="$(run 2>&1)"; rc=$?
assert "noemail: exits non-zero" test "$rc" -ne 0
assert_contains "noemail: explains"  "$out" "set your commit email first"
assert_not_contains "noemail: no key" "$(cat "$LOG")" "ssh-keygen"
assert "noemail: no signing config" test -z "$(gitcfg gpg.format)"

finish
