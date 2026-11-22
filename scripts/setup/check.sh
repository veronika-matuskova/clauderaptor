#!/usr/bin/env bash
# Checks that this machine has what clauderaptor needs. It only looks: no sudo, nothing installed or changed.
#   scripts/setup/check.sh
# One line per check: ok; warn (works, but may cause trouble); FAIL (missing, with what to run).
#   system     not root, Ubuntu, WSL, systemd, a systemd user instance (capped.sh needs it for its caps), and
#              the cpu controller in it (warn: without it, capped.sh's overall CPU cap isn't enforced)
#   git        your git identity, SSH commit signing, the pre-commit hook
#   tools      git python3 curl gh shellcheck claude docker (FAIL) and node (warn); gh logged in; docker info
#   install    ~/.claude links into claude/, settings.json is built
#   resources  warns below 7 GiB of memory (WSL set to 8 GB shows 7.6), when capped.sh's overall cap
#              (CAP_TOTAL_MEMORY, default 5G) leaves under 2 GiB for the rest, below 4 CPUs, and below 20 GiB free
#              in $HOME and, on WSL, on the Windows drive (/mnt/c), where WSL's virtual disk usually is
# Exit code: the number of FAILs; warnings don't count.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# The tests point these at their own files
MEMINFO="${CHECK_MEMINFO:-/proc/meminfo}"
OS_RELEASE="${CHECK_OS_RELEASE:-/etc/os-release}"
SYSTEMD_DIR="${CHECK_SYSTEMD_DIR:-/run/systemd/system}"
CONTROLLERS="${CHECK_CGROUP_CONTROLLERS:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers}"
WIN_DRIVE="${CHECK_WINDOWS_DRIVE:-/mnt/c}"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GIB=1048576  # KiB
fails=0; warns=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
has()  { command -v "$1" >/dev/null 2>&1; }
# gib <KiB>: the size in GiB, with one decimal
gib() { awk -v k="$1" 'BEGIN { printf "%.1f GiB", k / 1048576 }'; }
# kib <size>: a systemd size (5G, 512M, 4096K, or bytes) in KiB; prints nothing for other forms (e.g. 50%)
kib() {
  awk -v s="$1" 'BEGIN { if (s !~ /^[0-9]+(\.[0-9]+)?[KMGT]?$/) exit
    u = substr(s, length(s)); m = u == "K" ? 1 : u == "M" ? 1024 : u == "G" ? 1048576 : u == "T" ? 1073741824 : 1 / 1024
    printf "%d", (s + 0) * m }'
}
on_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ]; }

echo "== system"
if [ "$(id -u)" -eq 0 ]; then fail "running as root: run it as your user, not with sudo"; else ok "not root"; fi
# shellcheck source=/dev/null
os="$(. "$OS_RELEASE" 2>/dev/null && echo "${ID:-} ${PRETTY_NAME:-}")"
if [ "${os%% *}" = ubuntu ]; then ok "${os#* }"; else fail "not Ubuntu ($OS_RELEASE says ID=${os%% *}): the setup scripts support Ubuntu only"; fi
if on_wsl; then ok "WSL ($WSL_DISTRO_NAME)"; else warn "not WSL: the setup scripts and rules are made for WSL"; fi
if [ -d "$SYSTEMD_DIR" ]; then ok "systemd is running"; else
  fail "systemd isn't running: add '[boot] systemd=true' to /etc/wsl.conf, then 'wsl --shutdown' in PowerShell"
fi
# The same test as capped.sh's: without one, capped.sh runs commands without a cap
if has systemd-run && has systemctl && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/systemd/private" ]; then
  ok "systemd user instance (capped.sh can apply its caps)"
  if [[ " $(cat "$CONTROLLERS" 2>/dev/null) " == *" cpu "* ]]; then ok "cpu controller (capped.sh's CPU cap applies)"
  else warn "no cpu controller in the user manager: capped.sh's CPU cap isn't enforced: run scripts/setup/setup.sh caps"; fi
else
  fail "no systemd user instance: capped.sh would run mutation loops and tests without a cap"
fi

echo "== git"
for k in user.name user.email; do
  if v="$(git config --global "$k")" && [ -n "$v" ]; then ok "$k: $v"; else
    fail "no git $k: git config --global $k \"<your ${k#user.} on GitHub>\""
  fi
done
# As setup-tools.sh sets it up: an SSH key (without gpg.format=ssh, git hands the key to gpg and commits fail)
key="$(git config --global user.signingkey)"
if [ "$(git config --global commit.gpgsign)" = true ] && [ "$(git config --global gpg.format)" = ssh ] &&
   [ -n "$key" ] && [ -f "$key" ]; then
  ok "commits are signed with $key"
else
  fail "commit signing isn't set up: run scripts/setup/setup.sh tools"
fi
if [ "$(git -C "$REPO" config core.hooksPath)" = .githooks ]; then ok "pre-commit hook runs tests/run.sh"; else
  fail "pre-commit hook isn't on: run scripts/setup/install.sh"
fi

echo "== tools"
for c in git python3 curl; do
  if has "$c"; then ok "$c"; else fail "$c not found: sudo apt-get install $c"; fi
done
for c in gh shellcheck; do
  if has "$c"; then ok "$c"; else fail "$c not found: run scripts/setup/setup.sh tools"; fi
done
if has claude; then ok "claude"; else fail "claude not found: install Claude Code (review.sh runs claude -p)"; fi
if has node; then ok "node $(node --version 2>/dev/null)"; else
  warn "node not found: the queue needs it for repos with scripts/e2e-gate.mjs"
fi
if has gh; then
  if gh auth status >/dev/null 2>&1; then ok "gh is logged in"; else fail "gh isn't logged in: run scripts/setup/setup.sh tools"; fi
fi
if ! has docker; then fail "docker not found: run scripts/setup/setup.sh docker"
elif out="$(timeout 60 docker info --format '{{.ServerVersion}}' 2>&1)"; then ok "docker: server $out"
else
  hint=""; [[ "$out" == *"permission denied"* ]] && hint=" (new to the docker group? open a new terminal)"
  fail "docker info failed: ${out##*$'\n'}$hint"
fi

echo "== install"
bad=()
for item in CLAUDE.md statusline.py rules skills agents; do
  t="$DEST/$item"
  if [ ! -L "$t" ]; then bad+=("$item isn't a link")
  elif [ ! -e "$t" ]; then bad+=("$item is a broken link")
  elif [[ "$(readlink "$t")" != */claude/"$item" ]]; then bad+=("$item links to $(readlink "$t")")
  fi
done
if [ ${#bad[@]} -eq 0 ]; then ok "$DEST links into $(dirname "$(readlink "$DEST/CLAUDE.md")")"; else
  list="$(printf '%s; ' "${bad[@]}")"
  fail "in $DEST: ${list%; }: run scripts/setup/install.sh"
fi
if [ -f "$DEST/settings.json" ]; then ok "settings.json is built"; else fail "no $DEST/settings.json: run scripts/setup/install.sh"; fi

echo "== resources"
mem="$(awk '/^MemTotal:/ { print $2 }' "$MEMINFO" 2>/dev/null)"
swap="$(awk '/^SwapTotal:/ { print $2 }' "$MEMINFO" 2>/dev/null)"
if [ -z "$mem" ]; then warn "memory: can't read $MEMINFO"
else
  line="memory: $(gib "$mem"), swap $(gib "${swap:-0}")"
  raise=""; on_wsl && raise="; raise it with memory= under [wsl2] in %UserProfile%\\.wslconfig, then wsl --shutdown"
  if [ "$mem" -lt $((7 * GIB)) ]; then warn "$line: under 7 GiB, Docker, reviews and test runs may not fit side by side$raise"
  else ok "$line"; fi
  cap="${CAP_TOTAL_MEMORY:-5G}"; capk="$(kib "$cap")"
  if [ -z "$capk" ]; then ok "capped.sh's overall cap: $cap"
  elif [ $((mem - capk)) -lt $((2 * GIB)) ]; then
    warn "capped.sh's overall cap ($cap) leaves $(gib $((mem > capk ? mem - capk : 0))) for everything else: lower CAP_TOTAL_MEMORY$raise"
  else ok "capped.sh's overall cap ($cap) leaves $(gib $((mem - capk))) for everything else"; fi
fi
cpus="$(nproc)"
if [ "$cpus" -lt 4 ]; then warn "CPUs: $cpus, under 4: parallel agents and test workers will be slow"; else ok "CPUs: $cpus"; fi
# disk <what> <dir>: its free space
disk() {
  local free; free="$(df -Pk "$2" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [ -z "$free" ]; then warn "$1: can't read its free space"
  elif [ "$free" -lt $((20 * GIB)) ]; then warn "$1: $(gib "$free") free, under 20 GiB"
  else ok "$1: $(gib "$free") free"; fi
}
disk "disk ($HOME)" "$HOME"
if on_wsl && [ -d "$WIN_DRIVE" ]; then disk "Windows drive $WIN_DRIVE (WSL's virtual disk grows into it)" "$WIN_DRIVE"; fi

echo "== $fails failed, $warns warnings"
exit "$fails"
