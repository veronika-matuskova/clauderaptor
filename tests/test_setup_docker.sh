# shellcheck shell=bash
# Tests for setup-docker.sh with stubbed sudo/apt/curl/systemctl/id/docker, so nothing is installed for real.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# Minimal PATH: only these real tools + stubs. State lives in files next to the stubs:
# .groups (user's groups), .socket (docker.socket enabled), .down (docker info fails).
setup_bin() {
  BIN="$TMP/bin.$1"; LOG="$TMP/log.$1"; H="$TMP/home.$1"; mkdir -p "$BIN" "$H"; : > "$LOG"
  for c in bash cat grep readlink python3; do ln -s "$(command -v "$c")" "$BIN/$c"; done
  echo "t adm" > "$BIN/.groups"
  # sudo: logs, swallows stdin for tee, and fakes apt-get install / usermod / systemctl enable
  cat > "$BIN/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$LOG"
case "\$1 \$2" in
  "tee "*)              cat >/dev/null ;;
  "apt-get install")    for c in docker dockerd; do $(command -v cp) "$BIN/docker-stub" "$BIN/\$c"; done ;;
  "usermod -aG")        echo "\$(cat "$BIN/.groups") \$3" > "$BIN/.groups" ;;
  "systemctl enable")   : > "$BIN/.socket" ;;
esac
exit 0
EOF
  for c in curl dpkg; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$c" "$LOG" > "$BIN/$c"; done
  cat > "$BIN/id" <<EOF
#!/usr/bin/env bash
case "\$1" in -un) echo t ;; -nG) cat "$BIN/.groups" ;; esac
EOF
  cat > "$BIN/systemctl" <<EOF
#!/usr/bin/env bash
[ "\$1" = is-enabled ] && [ -f "$BIN/.socket" ]
EOF
  cat > "$BIN/docker-stub" <<EOF
#!/usr/bin/env bash
echo "\${0##*/} \$*" >> "$LOG"
case "\$1" in
  info)      [ -f "$BIN/.down" ] && { echo "permission denied while trying to connect" >&2; exit 1; }; echo ok ;;
  version)   echo 29.0 ;;
  --version) echo "Docker version 29.0" ;;
esac
EOF
  chmod +x "$BIN/sudo" "$BIN/curl" "$BIN/dpkg" "$BIN/id" "$BIN/systemctl" "$BIN/docker-stub"
}
run() { PATH="$BIN" HOME="$H" bash "$ROOT/setup-docker.sh"; }

# Fresh machine with Docker Desktop's leftover config: installs, joins group, enables socket, cleans config
setup_bin fresh
mkdir -p "$H/.docker"
printf '{\n  "auths": {},\n  "credsStore": "desktop.exe"\n}\n' > "$H/.docker/config.json"
out="$(run 2>&1)"; rc=$?
log="$(cat "$LOG")"
assert "fresh: exits 0" test "$rc" -eq 0
assert_contains "fresh: adds docker apt repo" "$log" "sudo tee /etc/apt/sources.list.d/docker.list"
assert_contains "fresh: fetches docker key"   "$log" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg"
assert_contains "fresh: installs engine"      "$log" "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
assert_contains "fresh: joins docker group"   "$log" "sudo usermod -aG docker t"
assert_contains "fresh: enables socket"       "$log" "sudo systemctl enable --now docker.socket"
assert "fresh: credsStore removed" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])))' "$H/.docker/config.json")" = "{'auths': {}}"
assert_contains "fresh: reports ready" "$out" "docker is ready: server 29.0"

# Re-run on a set-up machine: no sudo at all, config untouched
: > "$LOG"
cp "$H/.docker/config.json" "$TMP/config.before"
out="$(run 2>&1)"; rc=$?
log="$(cat "$LOG")"
assert "rerun: exits 0" test "$rc" -eq 0
assert_not_contains "rerun: no sudo" "$log" "sudo"
assert_contains "rerun: reports engine" "$out" "Docker Engine already installed: Docker version 29.0"
assert "rerun: config untouched" cmp -s "$TMP/config.before" "$H/.docker/config.json"
assert_contains "rerun: reports ready" "$out" "docker is ready"

# Daemon unreachable (e.g. group not applied yet): shows docker's error and a hint, exits non-zero
: > "$BIN/.down"
out="$(run 2>&1)"; rc=$?
assert "down: exits non-zero" test "$rc" -ne 0
assert_contains "down: shows docker error" "$out" "permission denied while trying to connect"
assert_contains "down: hints at new terminal" "$out" "open a new terminal so the docker group applies"

# Docker Desktop's integration is on: stops before installing anything
setup_bin desktop
desk="$TMP/mnt/wsl/docker-desktop/cli-tools/usr/bin"; mkdir -p "$desk"
cp "$BIN/docker-stub" "$desk/docker"; ln -s "$desk/docker" "$BIN/docker"
out="$(run 2>&1)"; rc=$?
assert "desktop: exits non-zero" test "$rc" -ne 0
assert_contains "desktop: explains" "$out" "Turn its WSL integration off first"
assert_not_contains "desktop: no sudo" "$(cat "$LOG")" "sudo"

finish
