# shellcheck shell=bash
# shellcheck disable=SC2016  # the commands in single quotes expand in the shell that runs them
# Tests for capped.sh: stubs of systemd-run (logs, then runs the command after "--") and systemctl (logs).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

BIN="$TMP/bin"; mkdir -p "$BIN"
export NO_SYSTEMD="$TMP/no_systemd" NO_SWAP_CAP="$TMP/no_swap_cap"
# $NO_SYSTEMD: every call fails; $NO_SWAP_CAP: a call that sets MemorySwapMax fails.
cat > "$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$LOG"
[ -f "$NO_SYSTEMD" ] && exit 1
[ -f "$NO_SWAP_CAP" ] && [[ "$*" == *MemorySwapMax* ]] && exit 1
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift; exec "$@"
EOF
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$LOG"\n' > "$BIN/systemctl"
chmod +x "$BIN/systemd-run" "$BIN/systemctl"
# C <command...>: capped.sh with the stubs, not turned off by CAP_OFF (which lib.sh sets for the tests).
C() { env -u CAP_OFF PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" "$@"; }
# newlog <name>: a log of its own for each test, since a watcher may still write to the last one.
newlog() { export LOG="$TMP/log.$1"; : > "$LOG"; }
unit() { sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$LOG" | head -1; }

# lib.sh runs a test file again under capped.sh, once, with bash's -x; the scripts it tests get CAP_OFF=1.
mkdir -p "$TMP/r/tests" "$TMP/r/scripts"; cp "$ROOT/tests/lib.sh" "$TMP/r/tests/"; cp "$ROOT/scripts/capped.sh" "$TMP/r/scripts/"
printf 'source "$(dirname "$0")/lib.sh"\necho "tiny ran, CAP_OFF=$CAP_OFF"\nfinish\n' > "$TMP/r/tests/test_tiny.sh"
newlog lib
out="$(env -u TESTS_CAPPED -u CAP_OFF PATH="$BIN:$PATH" bash -x "$TMP/r/tests/test_tiny.sh" 2>/dev/null)"
assert "lib.sh: runs the file under capped.sh, with -x" grep -q -- "-- bash -x $TMP/r/tests/test_tiny.sh\$" "$LOG"
assert "lib.sh: the file runs once"         test "$(grep -c "tiny ran" <<<"$out")" = 1
assert_contains "lib.sh: the tested scripts get CAP_OFF=1" "$out" "tiny ran, CAP_OFF=1"
assert "lib.sh: finish() is the last line"  test "$(tail -1 <<<"$out")" = "  finished: 0 failed"

# A scope with the caps; the command's exit code; then the scope is stopped.
newlog run
C bash -c 'echo ran >> "$LOG"; exit 3'; rc=$?
assert "the command's exit code"            test "$rc" = 3
assert_contains "a scope of its own"        "$(cat "$LOG")" "--scope --quiet --collect --unit=capped-"
assert_contains "the default caps"          "$(cat "$LOG")" \
  "-p TasksMax=2000 -p MemoryMax=4G -p MemorySwapMax=0 -p TimeoutStopSec=10 -- bash -c"
assert "then the scope is stopped"          test "$(sed -n '/^ran$/{n;p;}' "$LOG")" = "systemctl --user stop $(unit).scope"
u1="$(unit)"; newlog run2; C true
assert "each call: a unit of its own"       test -n "$u1" -a -n "$(unit)" -a "$u1" != "$(unit)"

newlog caps
CAP_TASKS=7 CAP_MEMORY=100M C true
assert_contains "CAP_TASKS and CAP_MEMORY"  "$(cat "$LOG")" "-p TasksMax=7 -p MemoryMax=100M"
assert_contains "arguments kept as they are" "$(C printf '%s|' 'a b' '' c)" "a b||c|"

# Inside another capped command, a scope of its own too.
newlog nested
C bash -c 'bash "$1" true' _ "$ROOT/scripts/capped.sh"
assert "nested: a scope of its own"         test "$(sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$LOG" | sort -u | wc -l)" = 2

# capped.sh stopped (TERM) or killed (KILL, which skips its EXIT trap) while the command runs: the scope is stopped.
for sig in TERM KILL; do
  newlog "$sig"; rm -f "$TMP/pid"
  env -u CAP_OFF PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" bash -c 'echo $$ > "$1"; exec sleep 30' _ "$TMP/pid" &
  p=$!
  for _ in $(seq 50); do [ -s "$TMP/pid" ] && break; sleep 0.1; done
  kill -"$sig" "$p"; { wait "$p"; } 2>/dev/null
  for _ in $(seq 30); do grep -q "systemctl --user stop" "$LOG" && break; sleep 0.1; done
  assert "$sig: the scope is stopped"       grep -qx "systemctl --user stop $(unit).scope" "$LOG"
  kill "$(cat "$TMP/pid")" 2>/dev/null
done

# CAP_OFF=1: the command runs as it is.
newlog off
out="$(CAP_OFF=1 PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" bash -c 'echo ran; exit 4')"; rc=$?
assert_contains "CAP_OFF: the command runs" "$out" "ran"
assert "CAP_OFF: its exit code"             test "$rc" = 4
assert "CAP_OFF: no scope"                  test ! -s "$LOG"

# No systemd user instance, or one that can't apply a cap: uncapped, with a warning.
newlog nosys; touch "$NO_SYSTEMD"
out="$(C bash -c 'echo ran; exit 5' 2>&1)"; rc=$?
rm -f "$NO_SYSTEMD"
assert_contains "no systemd: a warning"     "$out" "capped: no systemd user instance that can apply the caps, so 'bash -c' runs without a cap"
assert_contains "no systemd: the command runs" "$out" "ran"
assert "no systemd: its exit code"          test "$rc" = 5
assert "no systemd: no scope to stop"       test -z "$(grep systemctl "$LOG")"
newlog noswap; touch "$NO_SWAP_CAP"
out="$(C bash -c 'echo ran' 2>&1)"
rm -f "$NO_SWAP_CAP"
assert_contains "a cap it can't apply: the command runs" "$out" "ran"
assert_contains "a cap it can't apply: a warning" "$out" "runs without a cap"

out="$(C 2>&1)"; rc=$?
assert_contains "no command: usage"         "$out" "usage: capped.sh <command...>"
assert "no command: exit 2"                 test "$rc" = 2

# With a real systemd user instance: this file runs in a scope of its own (from lib.sh), the caps apply, a
# setsid child stays in the scope, and what is left running is stopped, also when capped.sh is killed.
if env -u CAP_OFF systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  cg="$(cut -d: -f3 /proc/self/cgroup)"
  assert "real: this file runs in a scope of its own" test "${cg##*/capped-}" != "$cg" -a "$cg" != "$(cut -d: -f3 "/proc/$PPID/cgroup")"
  m="600.$$"
  out="$(env -u CAP_OFF CAP_TASKS=30 CAP_MEMORY=300M bash "$ROOT/scripts/capped.sh" bash -c '
    cg="$(cut -d: -f3 /proc/self/cgroup)"; d="/sys/fs/cgroup$cg"
    echo "pids.max=$(cat "$d/pids.max") memory.max=$(cat "$d/memory.max") swap.max=$(cat "$d/memory.swap.max")"
    setsid sleep '"$m"' </dev/null >/dev/null 2>&1 & sleep 0.2
    [ "$(cut -d: -f3 /proc/$!/cgroup)" = "$cg" ] && echo "setsid child in the scope"')"
  assert_contains "real: the caps apply"      "$out" "pids.max=30 memory.max=314572800 swap.max=0"
  assert_contains "real: a setsid child stays in the scope" "$out" "setsid child in the scope"
  assert "real: nothing left running"         test -z "$(pgrep -f "^sleep $m")"
  m="601.$$"
  env -u CAP_OFF bash "$ROOT/scripts/capped.sh" bash -c 'setsid sleep '"$m"' </dev/null >/dev/null 2>&1 & sleep 30' &
  p=$!
  for _ in $(seq 50); do pgrep -f "^sleep $m" >/dev/null && break; sleep 0.1; done
  kill -KILL "$p"; { wait "$p"; } 2>/dev/null
  for _ in $(seq 50); do [ -z "$(pgrep -f "^sleep $m")" ] && break; sleep 0.1; done
  assert "real: killed, nothing left running" test -z "$(pgrep -f "^sleep $m")"
  pkill -f "^sleep 60[01].$$" 2>/dev/null
else
  echo "  --   no systemd user instance: the real caps not checked"
fi

finish
