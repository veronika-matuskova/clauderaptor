# shellcheck shell=bash
# Tests for setup.sh: runs a copy next to stub step scripts that only log their name.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# The tools step needs a git identity; tests get one from their own global config
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --global user.name t; git config --global user.email t@t

# Every step in --list points at a script that exists next to setup.sh
list="$(bash "$ROOT/scripts/setup/setup.sh" --list)"
assert "list: install tools docker, in order" [ "$(cut -d' ' -f1 <<<"$list" | tr '\n' ' ')" = "install tools docker " ]
while read -r step script; do
  assert "list: $step -> scripts/setup/$script exists" test -f "$ROOT/scripts/setup/$script"
done <<<"$list"

# setup_dir <name> [failing-script]: a dir with setup.sh and stub steps (not executable); the failing one exits 3
setup_dir() {
  D="$TMP/$1"; LOG="$D/log"; mkdir -p "$D"; : > "$LOG"
  cp "$ROOT/scripts/setup/setup.sh" "$D/"
  for s in install.sh setup-tools.sh setup-docker.sh; do
    rc=0; [ "$s" = "${2:-}" ] && rc=3
    printf '#!/usr/bin/env bash\necho %s >> "%s"\necho "output of %s"\nexit %s\n' "$s" "$LOG" "$s" "$rc" > "$D/$s"
    chmod -x "$D/$s"
  done
}

# No args: all steps, in order, even without the exec bit; their output reaches the user
setup_dir all
out="$(bash "$D/setup.sh" 2>&1)"; rc=$?
assert "all: exits 0" [ "$rc" -eq 0 ]
assert_contains "all: runs every step in order" "$(cat "$LOG")" $'install.sh\nsetup-tools.sh\nsetup-docker.sh'
assert_contains "all: shows step output" "$out" "output of setup-tools.sh"
assert_contains "all: reports done" "$out" "setup done: install tools docker"

# Named steps: only those, each once
setup_dir some
bash "$D/setup.sh" docker docker >/dev/null 2>&1; rc=$?
assert "some: exits 0" [ "$rc" -eq 0 ]
assert "some: runs only docker, once" [ "$(cat "$LOG")" = "setup-docker.sh" ]

# A failing step stops the run and says how to retry
setup_dir fail setup-tools.sh
out="$(bash "$D/setup.sh" 2>&1)"; rc=$?
assert "fail: exits with the step's code" [ "$rc" -eq 3 ]
assert_not_contains "fail: later steps don't run" "$(cat "$LOG")" "setup-docker.sh"
assert_contains "fail: names the step" "$out" "tools failed"
assert_contains "fail: shows the retry command" "$out" "re-run: $D/setup.sh install tools docker"

# Unknown or empty step: nothing runs
setup_dir unknown
out="$(bash "$D/setup.sh" install bogus 2>&1)"; rc=$?
assert "unknown: exits 2" [ "$rc" -eq 2 ]
assert "unknown: runs nothing" [ ! -s "$LOG" ]
assert_contains "unknown: lists steps" "$out" "unknown step 'bogus'"
out="$(bash "$D/setup.sh" "" 2>&1)"; rc=$?
assert "empty: exits 2" [ "$rc" -eq 2 ]
assert_not_contains "empty: no bash error" "$out" "bad array subscript"

# -h: usage from the header, nothing runs
setup_dir help
out="$(bash "$D/setup.sh" -h 2>&1)"; rc=$?
assert "help: exits 0" [ "$rc" -eq 0 ]
assert_contains "help: shows usage" "$out" "scripts/setup/setup.sh tools docker   only the named steps"
assert_not_contains "help: no shell code" "$out" "set -uo"
assert "help: runs nothing" [ ! -s "$LOG" ]

# No git email: stops before any step when tools is included, but not for other steps
setup_dir noemail
git config --global --unset user.email
out="$(bash "$D/setup.sh" 2>&1)"; rc=$?
assert "noemail: exits 1" [ "$rc" -eq 1 ]
assert "noemail: runs nothing" [ ! -s "$LOG" ]
assert_contains "noemail: says what to set" "$out" "git config --global user.email"
bash "$D/setup.sh" install docker >/dev/null 2>&1; rc=$?
assert "noemail: other steps still run" [ "$rc" -eq 0 ]

# No git name: same check
setup_dir noname
git config --global user.email t@t; git config --global --unset user.name
out="$(bash "$D/setup.sh" tools 2>&1)"; rc=$?
assert "noname: exits 1" [ "$rc" -eq 1 ]
assert "noname: runs nothing" [ ! -s "$LOG" ]
assert_contains "noname: says what to set" "$out" "git config --global user.name"
git config --global user.name t

# As root (sudo scripts/setup/setup.sh): refuses before any step
setup_dir root
# $1 below belongs to the stub, not this script
mkdir -p "$D/bin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && echo 0\n' > "$D/bin/id"; chmod +x "$D/bin/id"
out="$(PATH="$D/bin:$PATH" bash "$D/setup.sh" 2>&1)"; rc=$?
assert "root: exits 1" [ "$rc" -eq 1 ]
assert "root: runs nothing" [ ! -s "$LOG" ]
assert_contains "root: says why" "$out" "not as root or with sudo"

finish
