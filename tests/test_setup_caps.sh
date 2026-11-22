# shellcheck shell=bash
# Tests for setup-caps.sh with stubbed sudo and id, a fake cgroup.controllers and a drop-in path in the temp dir.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

CONF=$'[Service]\nDelegate=cpu cpuset io memory pids'
# setup <name> <controllers>: a machine whose user manager has these controllers, no drop-in yet.
# sudo logs its command and runs it (mkdir, tee, systemctl), so the drop-in lands in the temp dir.
setup() {
  D="$TMP/$1"; BIN="$D/bin"; LOG="$D/log"; mkdir -p "$BIN" "$D/systemd"; : > "$LOG"
  echo "$2" > "$D/controllers"
  cat > "$BIN/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$LOG"
[ "\$1" = systemctl ] && exit 0
exec "\$@"
EOF
  printf '#!/usr/bin/env bash\necho 1000\n' > "$BIN/id"
  chmod +x "$BIN/sudo" "$BIN/id"
  for c in bash cat mkdir dirname tee; do ln -s "$(command -v "$c")" "$BIN/$c"; done
}
run() {
  OUT="$(env -i PATH="$BIN" SETUP_SYSTEMD_DIR="$D/systemd" SETUP_CGROUP_CONTROLLERS="$D/controllers" \
    SETUP_DELEGATE_DROPIN="$D/etc/user@.service.d/delegate.conf" bash "$ROOT/scripts/setup/setup-caps.sh" 2>&1)"; RC=$?
}

# Only memory and pids (systemd 249's default): writes the drop-in, reloads, says how to apply it
setup fresh "memory pids"; run
assert "fresh: exits 0" [ "$RC" -eq 0 ]
assert "fresh: writes the drop-in" [ "$(cat "$D/etc/user@.service.d/delegate.conf")" = "$CONF" ]
assert "fresh: with sudo, then reloads" [ "$(cut -d' ' -f1-2 "$LOG" | paste -sd,)" = "sudo mkdir,sudo tee,sudo systemctl" ]
assert_contains "fresh: reloads systemd" "$(cat "$LOG")" "sudo systemctl daemon-reload"
assert_contains "fresh: says how to apply it" "$OUT" "run 'wsl --shutdown' in PowerShell"

# Drop-in written, user manager not restarted yet: no sudo, says to restart
run
assert "again: exits 0" [ "$RC" -eq 0 ]
assert "again: no sudo" [ "$(grep -c . "$LOG")" = 3 ]
assert_contains "again: says to restart" "$OUT" "started before it"

# A different drop-in there: replaced with ours
setup other "memory pids"; mkdir -p "$D/etc/user@.service.d"; printf '[Service]\nDelegate=memory pids\n' > "$D/etc/user@.service.d/delegate.conf"; run
assert "other drop-in: replaced" [ "$(cat "$D/etc/user@.service.d/delegate.conf")" = "$CONF" ]

# cpu already delegated: nothing to do, no sudo
setup delegated "cpuset cpu io memory pids"; run
assert "delegated: exits 0" [ "$RC" -eq 0 ]
assert "delegated: no sudo" [ ! -s "$LOG" ]
assert_contains "delegated: says the cap applies" "$OUT" "the cpu controller is delegated"
# cpuset alone isn't cpu
setup cpuset "cpuset memory pids"; run
assert "cpuset only: writes the drop-in" [ -f "$D/etc/user@.service.d/delegate.conf" ]

# No systemd: fails before any sudo
setup nosystemd "memory pids"; rmdir "$D/systemd"; run
assert "nosystemd: exits 1" [ "$RC" -eq 1 ]
assert "nosystemd: no sudo" [ ! -s "$LOG" ]
assert_contains "nosystemd: says how" "$OUT" "systemd isn't running"

# A failing sudo: stops with its exit code
setup sudofails "memory pids"; printf '#!/usr/bin/env bash\nexit 4\n' > "$BIN/sudo"; run
assert "sudo fails: exits non-zero" [ "$RC" -ne 0 ]
assert_not_contains "sudo fails: doesn't say it wrote it" "$OUT" "wrote"

finish
