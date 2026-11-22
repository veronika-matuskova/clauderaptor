# shellcheck shell=bash
# shellcheck disable=SC2016  # the commands in single quotes expand in the shell that runs them
# Tests for capped.sh: stubs of systemd-run (logs, then runs the command after "--") and systemctl (logs).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

BIN="$TMP/bin"; mkdir -p "$BIN"
export LOG="$TMP/log"
cat > "$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$LOG"
[ -f "$LOG.no_systemd" ] && exit 1
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift; exec "$@"
EOF
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$LOG"\n' > "$BIN/systemctl"
chmod +x "$BIN/systemd-run" "$BIN/systemctl"
# C <command...>: capped.sh outside any cap, with the stubs.
C() { env -u CAPPED PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" "$@"; }
unit() { sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$LOG"; }

assert "lib.sh: this test file runs under capped.sh" test "${CAPPED:-}" = 1

# In a scope with the default caps; the command's exit code; then the scope is stopped.
: > "$LOG"
C bash -c 'echo "ran CAPPED=$CAPPED" >> "$LOG"; exit 3'; rc=$?
assert "the command's exit code"            test "$rc" = 3
assert_contains "a scope with the default caps" "$(cat "$LOG")" \
  "--scope --quiet --collect --unit=capped-"
assert_contains "the default caps"          "$(cat "$LOG")" "-p TasksMax=2000 -p MemoryMax=4G -p MemorySwapMax=0"
assert "the command gets CAPPED=1"          grep -qx "ran CAPPED=1" "$LOG"
assert "a unit name"                        test -n "$(unit)"
assert "then its scope is stopped"          test "$(tail -1 "$LOG")" = "systemctl --user stop $(unit).scope"

: > "$LOG"
CAP_TASKS=7 CAP_MEMORY=100M C true
assert_contains "CAP_TASKS and CAP_MEMORY"  "$(cat "$LOG")" "-p TasksMax=7 -p MemoryMax=100M"
assert_contains "arguments kept as they are" "$(C printf '%s|' 'a b' '' c)" "a b||c|"

# capped.sh stopped while the command runs: the scope is stopped too.
: > "$LOG"
env -u CAPPED PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" bash -c 'echo $$ > "$LOG.pid"; exec sleep 30' & p=$!
for _ in $(seq 50); do [ -s "$LOG.pid" ] && break; sleep 0.1; done
kill -TERM "$p"; wait "$p" 2>/dev/null
assert "stopped: its scope is stopped"      grep -qx "systemctl --user stop $(unit).scope" "$LOG"
kill "$(cat "$LOG.pid")" 2>/dev/null

# Inside a cap already: the command runs as it is, without a scope of its own.
: > "$LOG"
out="$(CAPPED=1 PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" bash -c 'echo ran; exit 4')"; rc=$?
assert_contains "nested: the command runs"  "$out" "ran"
assert "nested: its exit code"              test "$rc" = 4
assert "nested: no scope"                   test ! -s "$LOG"

# No systemd user instance: uncapped, with a warning.
: > "$LOG"; touch "$LOG.no_systemd"
out="$(C bash -c 'echo "ran CAPPED=$CAPPED"; exit 5' 2>&1)"; rc=$?
rm -f "$LOG.no_systemd"
assert_contains "no systemd: a warning"     "$out" "capped: no systemd user instance, so bash runs without a cap"
assert_contains "no systemd: the command runs, marked" "$out" "ran CAPPED=1"
assert "no systemd: its exit code"          test "$rc" = 5
assert "no systemd: no scope to stop"       test -z "$(grep systemctl "$LOG")"

out="$(C 2>&1)"; rc=$?
assert_contains "no command: usage"         "$out" "usage: capped.sh <command...>"
assert "no command: exit 2"                 test "$rc" = 2

# With a real systemd user instance: the caps apply, a setsid child stays in the scope, and what the command
# leaves running is stopped.
if env -u CAPPED systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  m="600.$$"
  out="$(env -u CAPPED CAP_TASKS=30 CAP_MEMORY=300M bash "$ROOT/scripts/capped.sh" bash -c '
    cg="$(cut -d: -f3 /proc/self/cgroup)"; d="/sys/fs/cgroup$cg"
    echo "pids.max=$(cat "$d/pids.max") memory.max=$(cat "$d/memory.max") swap.max=$(cat "$d/memory.swap.max")"
    setsid sleep '"$m"' </dev/null >/dev/null 2>&1 & sleep 0.2
    [ "$(cut -d: -f3 /proc/$!/cgroup)" = "$cg" ] && echo "setsid child in the scope"')"
  assert_contains "real: the caps apply"      "$out" "pids.max=30 memory.max=314572800 swap.max=0"
  assert_contains "real: a setsid child stays in the scope" "$out" "setsid child in the scope"
  assert "real: nothing left running"         test -z "$(pgrep -f "sleep $m")"
  pkill -f "sleep $m" 2>/dev/null
else
  echo "  --   no systemd user instance: the real caps not checked"
fi

finish
