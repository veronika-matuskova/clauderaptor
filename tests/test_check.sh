# shellcheck shell=bash
# Tests for check.sh: runs a copy in a temp repo with stubbed tools, a fake /proc/meminfo, os-release and ~/.claude,
# so the result doesn't depend on this machine.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# setup <name>: a machine where every check passes. Change one thing, then run it.
# State next to the stubs: .cpus, .free (df's free KiB), .gh-out (gh logged out), .docker-err (docker info fails).
setup() {
  D="$TMP/$1"; BIN="$D/bin"; H="$D/home"; R="$D/repo"
  mkdir -p "$BIN" "$H/.ssh" "$R/scripts/setup" "$D/run/systemd" "$D/systemd" "$D/c" "$R/claude/rules" "$R/claude/skills" "$R/claude/agents"
  cp "$ROOT/scripts/setup/check.sh" "$R/scripts/setup/"
  git init -q "$R"; git -C "$R" config core.hooksPath .githooks
  for c in python3 curl shellcheck claude systemd-run systemctl; do printf '#!/usr/bin/env bash\n' > "$BIN/$c"; done
  printf '#!/usr/bin/env bash\necho v24.0.0\n' > "$BIN/node"
  printf '#!/usr/bin/env bash\necho 1000\n' > "$BIN/id"
  printf '#!/usr/bin/env bash\ncat "%s/.cpus"\n' "$BIN" > "$BIN/nproc"; echo 8 > "$BIN/.cpus"
  # df -Pk <dir>: a header, then the dir's free KiB in column 4 (.free.<dir name>, else .free)
  cat > "$BIN/df" <<EOF
#!/usr/bin/env bash
f="$BIN/.free.\${2##*/}"; [ -f "\$f" ] || f="$BIN/.free"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "x 0 0 \$(cat "\$f") 0% \$2"
EOF
  echo $((500 * 1048576)) > "$BIN/.free"
  printf '#!/usr/bin/env bash\n[ ! -f "%s/.gh-out" ]\n' "$BIN" > "$BIN/gh"
  cat > "$BIN/docker" <<EOF
#!/usr/bin/env bash
if [ -f "$BIN/.docker-err" ]; then cat "$BIN/.docker-err" >&2; exit 1; fi
echo 29.0.0
EOF
  chmod +x "$BIN"/*
  for c in bash awk cat dirname readlink git timeout; do ln -s "$(command -v "$c")" "$BIN/$c"; done
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$D/run/systemd/private"
  printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$D/os-release"
  printf 'MemTotal:       %s kB\nSwapTotal:       3145728 kB\n' $((12 * 1048576)) > "$D/meminfo"
  G="$D/gitconfig"
  git config --file "$G" user.name t; git config --file "$G" user.email t@t
  echo key > "$H/.ssh/k.pub"; git config --file "$G" user.signingkey "$H/.ssh/k.pub"; git config --file "$G" commit.gpgsign true; git config --file "$G" gpg.format ssh
  mkdir -p "$H/.claude"; touch "$R/claude/CLAUDE.md" "$R/claude/statusline.py" "$H/.claude/settings.json"
  for i in CLAUDE.md statusline.py rules skills agents; do ln -s "$R/claude/$i" "$H/.claude/$i"; done
}
# check [VAR=value...]: runs the copy; OUT gets its output, RC its exit code
check() {
  OUT="$(env -i PATH="$BIN" HOME="$H" GIT_CONFIG_GLOBAL="$G" GIT_CONFIG_NOSYSTEM=1 XDG_RUNTIME_DIR="$D/run" \
    WSL_DISTRO_NAME=Ubuntu CHECK_MEMINFO="$D/meminfo" CHECK_OS_RELEASE="$D/os-release" CHECK_SYSTEMD_DIR="$D/systemd" \
    CHECK_WINDOWS_DRIVE="$D/c" "$@" bash "$R/scripts/setup/check.sh" 2>&1)"; RC=$?
}

# Everything there: exit 0, every section, no FAIL or warn
setup good; check
assert "good: exits 0" [ "$RC" -eq 0 ]
assert_contains "good: summary" "$OUT" "== 0 failed, 0 warnings"
for s in system git tools install resources; do assert_contains "good: section $s" "$OUT" "== $s"; done
assert_not_contains "good: no FAIL" "$OUT" "FAIL"
assert_not_contains "good: no warn" "$OUT" "warn "
assert_contains "good: memory and swap" "$OUT" "ok    memory: 12.0 GiB, swap 3.0 GiB"
assert_contains "good: room left by the cap" "$OUT" "overall cap (5G) leaves 7.0 GiB for everything else"
assert_contains "good: CPUs" "$OUT" "ok    CPUs: 8"
assert_contains "good: Windows drive" "$OUT" "Windows drive $D/c"
assert_contains "good: docker version" "$OUT" "docker: server 29.0.0"
assert_contains "good: install dir" "$OUT" "links into $R/claude"

# Each FAIL: one line naming the fix, and the exit code counts it
setup root; printf '#!/usr/bin/env bash\necho 0\n' > "$BIN/id"; check
assert "root: exits 1" [ "$RC" -eq 1 ]
assert_contains "root: says why" "$OUT" "FAIL  running as root"

setup os; printf 'ID=debian\n' > "$D/os-release"; check
assert "os: exits 1" [ "$RC" -eq 1 ]
assert_contains "os: names the ID" "$OUT" "FAIL  not Ubuntu ($D/os-release says ID=debian)"

setup nosystemd; rmdir "$D/systemd"; check
assert "nosystemd: exits 1" [ "$RC" -eq 1 ]
assert_contains "nosystemd: says how" "$OUT" "FAIL  systemd isn't running: add '[boot] systemd=true'"

setup nouser; rm "$D/run/systemd/private"; check
assert "nouser: exits 1" [ "$RC" -eq 1 ]
assert_contains "nouser: no user instance" "$OUT" "FAIL  no systemd user instance"
setup norun; rm "$BIN/systemd-run"; check
assert_contains "norun: no systemd-run means no user instance" "$OUT" "FAIL  no systemd user instance"
setup nosystemctl; rm "$BIN/systemctl"; check
assert "nosystemctl: exits 1" [ "$RC" -eq 1 ]
assert_contains "nosystemctl: no systemctl means no user instance" "$OUT" "FAIL  no systemd user instance"

setup noemail; git config --file "$G" --unset user.email; check
assert "noemail: exits 1" [ "$RC" -eq 1 ]
assert_contains "noemail: says what to set" "$OUT" "FAIL  no git user.email: git config --global user.email"
assert_contains "noemail: name still ok" "$OUT" "ok    user.name: t"

setup nosign; git config --file "$G" commit.gpgsign false; check
assert_contains "nosign: signing off" "$OUT" "FAIL  commit signing isn't set up: run scripts/setup/setup.sh tools"
setup noformat; git config --file "$G" --unset gpg.format; check
assert "noformat: exits 1" [ "$RC" -eq 1 ]
assert_contains "noformat: a key without gpg.format=ssh isn't signing" "$OUT" "FAIL  commit signing isn't set up"
setup gpgformat; git config --file "$G" gpg.format openpgp; check
assert_contains "gpgformat: another format isn't SSH signing" "$OUT" "FAIL  commit signing isn't set up"
setup nokey; rm "$H/.ssh/k.pub"; check
assert "nokey: exits 1" [ "$RC" -eq 1 ]
assert_contains "nokey: a missing key file isn't signing" "$OUT" "FAIL  commit signing isn't set up"

setup nohook; git -C "$R" config --unset core.hooksPath; check
assert_contains "nohook: says how" "$OUT" "FAIL  pre-commit hook isn't on: run scripts/setup/install.sh"

# Missing tools: each named, with its fix; the count is the exit code
setup notools; rm "$BIN/python3" "$BIN/shellcheck" "$BIN/claude"; check
assert "notools: exits 3" [ "$RC" -eq 3 ]
assert_contains "notools: python3" "$OUT" "FAIL  python3 not found: sudo apt-get install python3"
assert_contains "notools: shellcheck" "$OUT" "FAIL  shellcheck not found: run scripts/setup/setup.sh tools"
assert_contains "notools: claude" "$OUT" "FAIL  claude not found"

setup nogh; rm "$BIN/gh"; check
assert "nogh: one FAIL, no login check" [ "$RC" -eq 1 ]
assert_contains "nogh: gh" "$OUT" "FAIL  gh not found"
setup ghout; : > "$BIN/.gh-out"; check
assert_contains "ghout: not logged in" "$OUT" "FAIL  gh isn't logged in: run scripts/setup/setup.sh tools"

setup nonode; rm "$BIN/node"; check
assert "nonode: only a warning" [ "$RC" -eq 0 ]
assert_contains "nonode: warns" "$OUT" "warn  node not found"

setup nodocker; rm "$BIN/docker"; check
assert_contains "nodocker: says how" "$OUT" "FAIL  docker not found: run scripts/setup/setup.sh docker"
setup dockerdown; printf 'Client: x\npermission denied while trying to connect\n' > "$BIN/.docker-err"; check
assert "dockerdown: exits 1" [ "$RC" -eq 1 ]
assert_contains "dockerdown: shows the error and a hint" "$OUT" \
  "FAIL  docker info failed: permission denied while trying to connect (new to the docker group? open a new terminal)"

# Install: wrong, broken or missing links are listed together
setup noinstall
rm "$H/.claude/rules"; mkdir "$H/.claude/rules"; rm "$R/claude/statusline.py"
ln -sfn "$D/elsewhere" "$H/.claude/agents"; rm "$H/.claude/settings.json"; check
assert "noinstall: exits 2" [ "$RC" -eq 2 ]
assert_contains "noinstall: lists each link" "$OUT" \
  "FAIL  in $H/.claude: statusline.py is a broken link; rules isn't a link; agents is a broken link: run scripts/setup/install.sh"
assert_contains "noinstall: settings" "$OUT" "FAIL  no $H/.claude/settings.json: run scripts/setup/install.sh"
setup otherlink; mkdir -p "$D/x/stuff"; ln -sfn "$D/x/stuff" "$H/.claude/skills"; check
assert_contains "otherlink: a link outside claude/" "$OUT" "skills links to $D/x/stuff"

# Resources only warn: low memory, with the .wslconfig hint on WSL only
setup lowmem; printf 'MemTotal: %s kB\n' $((7 * 1048576 - 1)) > "$D/meminfo"; check
assert "lowmem: exits 0" [ "$RC" -eq 0 ]
assert_contains "lowmem: warns" "$OUT" "warn  memory: 7.0 GiB, swap 0.0 GiB: under 7 GiB"
assert_contains "lowmem: .wslconfig hint" "$OUT" '%UserProfile%\.wslconfig'
assert_contains "lowmem: the cap leaves too little" "$OUT" "warn  capped.sh's overall cap (5G) leaves 2.0 GiB"
assert_contains "lowmem: 2 warnings" "$OUT" "0 failed, 2 warnings"
setup at7; printf 'MemTotal: %s kB\n' $((7 * 1048576)) > "$D/meminfo"; check
assert_contains "at7: exactly 7 GiB is ok" "$OUT" "ok    memory: 7.0 GiB"
assert_contains "at7: the cap leaves exactly 2 GiB" "$OUT" "ok    capped.sh's overall cap (5G) leaves 2.0 GiB"
setup notwsl; printf 'MemTotal: %s kB\n' 1048576 > "$D/meminfo"; check WSL_DISTRO_NAME=
assert_contains "notwsl: warns" "$OUT" "warn  not WSL"
assert_not_contains "notwsl: no .wslconfig hint" "$OUT" ".wslconfig"
assert_not_contains "notwsl: no Windows drive" "$OUT" "Windows drive"
assert_contains "notwsl: cap bigger than memory leaves 0" "$OUT" "leaves 0.0 GiB for everything else"
setup nomeminfo; rm "$D/meminfo"; check
assert_contains "nomeminfo: warns" "$OUT" "warn  memory: can't read $D/meminfo"

# CAP_TOTAL_MEMORY: read in systemd's units; other forms are shown as they are
setup capm; check CAP_TOTAL_MEMORY=11264M
assert_contains "capm: M units" "$OUT" "warn  capped.sh's overall cap (11264M) leaves 1.0 GiB"
setup capt; check CAP_TOTAL_MEMORY=1T
assert_contains "capt: T units" "$OUT" "leaves 0.0 GiB"
setup capb; check CAP_TOTAL_MEMORY=$((4 * 1073741824))
assert_contains "capb: bytes" "$OUT" "leaves 8.0 GiB"
setup capk; check CAP_TOTAL_MEMORY=$((4 * 1048576))K
assert_contains "capk: K units" "$OUT" "leaves 8.0 GiB"
setup capg; check CAP_TOTAL_MEMORY=10.5G
assert_contains "capg: decimals" "$OUT" "leaves 1.5 GiB"
setup cappct; check CAP_TOTAL_MEMORY=50%
assert_contains "cappct: shown as it is" "$OUT" "ok    capped.sh's overall cap: 50%"

setup fewcpus; echo 3 > "$BIN/.cpus"; check
assert_contains "fewcpus: warns" "$OUT" "warn  CPUs: 3, under 4"
setup cpus4; echo 4 > "$BIN/.cpus"; check
assert_contains "cpus4: 4 is ok" "$OUT" "ok    CPUs: 4"

setup lowdisk; echo $((20 * 1048576 - 1)) > "$BIN/.free.c"; echo $((20 * 1048576)) > "$BIN/.free.home"; check
assert "lowdisk: exits 0" [ "$RC" -eq 0 ]
assert_contains "lowdisk: Windows drive warns" "$OUT" "warn  Windows drive $D/c (WSL's virtual disk grows into it): 20.0 GiB free, under 20 GiB"
assert_contains "lowdisk: exactly 20 GiB is ok" "$OUT" "ok    disk ($H): 20.0 GiB free"
setup nodrive; rmdir "$D/c"; check
assert_not_contains "nodrive: skipped when missing" "$OUT" "Windows drive"

finish
