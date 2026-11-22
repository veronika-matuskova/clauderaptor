# shellcheck shell=bash
# shellcheck disable=SC2016  # the commands in single quotes expand in the shell that runs them
# Tests for capped.sh: stubs of systemd-run (logs, then runs the command after "--"), systemctl (logs) and
# sleep (logs capped.sh's 1 s between tries and returns at once; any other sleep is the real one).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"
# The caps of the caller's environment don't count here: the tests set them where they need them.
unset CAP_TASKS CAP_MEMORY CAP_TOTAL_TASKS CAP_TOTAL_MEMORY CAP_TOTAL_CPU

BIN="$TMP/bin"; mkdir -p "$BIN"
export NO_SYSTEMD="$TMP/no_systemd" NO_SWAP_CAP="$TMP/no_swap_cap" SLICE_FAILS="$TMP/slice_fails"
export EXPANDS="$TMP/expands"
# $NO_SYSTEMD: every call fails; $NO_SWAP_CAP: a call that sets MemorySwapMax fails, with two lines of error;
# $SLICE_FAILS: the number of calls that set capped.slice's cap that fail, as a call that times out does.
# $EXPANDS: a newer systemd-run, which has --expand-environment and, without --expand-environment=no, expands
# ${...} (to nothing here) and $$ in the command's arguments.
cat > "$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --help ]; then [ -f "$EXPANDS" ] && echo "  --expand-environment=BOOL"; exit 0; fi
echo "systemd-run $*" >> "$LOG"
[ -f "$NO_SYSTEMD" ] && exit 1
[ -f "$NO_SWAP_CAP" ] && [[ "$*" == *MemorySwapMax* ]] && { printf 'Setting MemorySwapMax\nUnknown assignment: MemorySwapMax=0\n' >&2; exit 1; }
[ -f "$EXPANDS" ] && [[ " $* " != *" --expand-environment=no "* ]] && expand=1
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
if [ -n "${expand:-}" ]; then
  shopt -s extglob; args=(); for a in "$@"; do a="${a//\$\{*([^\}])\}/}"; args+=("${a//\$\$/\$}"); done; set -- "${args[@]}"
fi
exec "$@"
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
[ -f "$NO_SYSTEMD" ] && exit 1
if [[ "$*" == *set-property* ]] && [ "$(cat "$SLICE_FAILS" 2>/dev/null || echo 0)" -gt 0 ]; then
  echo $(($(cat "$SLICE_FAILS") - 1)) > "$SLICE_FAILS"
  echo "Failed to set unit properties on capped.slice: Connection timed out" >&2; exit 1
fi
exit 0
EOF
cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = 1 ]; then echo "sleep 1" >> "$LOG"; exit 0; fi
exec "$(command -pv sleep)" "$@"
EOF
chmod +x "$BIN/systemd-run" "$BIN/systemctl" "$BIN/sleep"
# $TMP/run: the runtime dir of a user manager, with the socket systemctl --user and systemd-run --user connect
# to (capped.sh only looks for it); $TMP/norun: one without.
# sock <path>: a socket file, bound in its folder (a long $TMP is too long for a socket's path), not listening.
sock() { (cd "$(dirname "$1")" && python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$(basename "$1")"); }
mkdir -p "$TMP/run/systemd" "$TMP/norun"; sock "$TMP/run/systemd/private"
# C <command...>: capped.sh with the stubs, not turned off by CAP_OFF (which lib.sh sets for the tests), with a
# user manager's socket ($XDG instead, if set).
C() { env -u CAP_OFF PATH="$BIN:$PATH" XDG_RUNTIME_DIR="${XDG-$TMP/run}" bash "$ROOT/scripts/capped.sh" "$@"; }
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
newlog libv
env -u TESTS_CAPPED -u CAP_OFF PATH="$BIN:$PATH" bash -v "$TMP/r/tests/test_tiny.sh" >/dev/null 2>&1
assert "lib.sh: keeps -v"                   grep -q -- "-- bash -v $TMP/r/tests/test_tiny.sh\$" "$LOG"
# Sourced from a shell that isn't a test file (bash -c): no re-run, and what follows runs.
newlog sourced
out="$(env -u TESTS_CAPPED -u CAP_OFF PATH="$BIN:$PATH" bash -c 'source "$1"; echo "after lib.sh"' _ "$TMP/r/tests/lib.sh" 2>&1)"
assert_contains "lib.sh sourced by bash -c: what follows runs" "$out" "after lib.sh"
assert "lib.sh sourced by bash -c: no re-run" test ! -s "$LOG"
# A file whose re-run can't get the caps fails, with capped.sh's message, and doesn't run.
newlog libclosed; echo 99 > "$SLICE_FAILS"
out="$(env -u TESTS_CAPPED -u CAP_OFF PATH="$BIN:$PATH" XDG_RUNTIME_DIR="$TMP/run" bash "$TMP/r/tests/test_tiny.sh" 2>&1)"; rc=$?
rm -f "$SLICE_FAILS"
assert "lib.sh, no cap: the file fails (125)" test "$rc" = 125
assert_not_contains "lib.sh, no cap: the file doesn't run" "$out" "tiny ran"
assert_contains "lib.sh, no cap: capped.sh's message" "$out" "CAP_OFF=1 runs it without a cap"

# A scope with the caps; the command's exit code; then the scope is stopped.
newlog run
C bash -c 'echo ran >> "$LOG"; exit 3'; rc=$?
assert "the command's exit code"            test "$rc" = 3
assert_contains "a scope of its own, in capped.slice" "$(cat "$LOG")" \
  "--scope --quiet --collect --slice=capped.slice --unit=capped-"
assert_contains "the overall cap on capped.slice" "$(cat "$LOG")" \
  "systemctl --user set-property --runtime capped.slice TasksMax=4000 MemoryMax=5G MemorySwapMax=0 CPUQuota=$(($(nproc --all) * 60))%"
assert_contains "the default caps"          "$(cat "$LOG")" \
  "-p TasksMax=2000 -p MemoryMax=4G -p MemorySwapMax=0 -p TimeoutStopSec=10 -- bash -c"
assert_contains "the check: the same caps, in capped.slice" "$(cat "$LOG")" \
  "--scope --quiet --slice=capped.slice -p TasksMax=2000 -p MemoryMax=4G -p MemorySwapMax=0 -p TimeoutStopSec=10 -- true"
assert "then the scope is stopped"          test "$(sed -n '/^ran$/{n;p;}' "$LOG")" = "systemctl --user stop $(unit).scope"
u1="$(unit)"; newlog run2; C true
assert "each call: a unit of its own"       test -n "$u1" -a -n "$(unit)" -a "$u1" != "$(unit)"

newlog caps
CAP_TASKS=7 CAP_MEMORY=100M CAP_TOTAL_TASKS=9 CAP_TOTAL_MEMORY=1G CAP_TOTAL_CPU=150% C true
assert_contains "CAP_TASKS and CAP_MEMORY"  "$(cat "$LOG")" "-p TasksMax=7 -p MemoryMax=100M"
assert_contains "CAP_TOTAL_TASKS, CAP_TOTAL_MEMORY and CAP_TOTAL_CPU" "$(cat "$LOG")" \
  "capped.slice TasksMax=9 MemoryMax=1G MemorySwapMax=0 CPUQuota=150%"
# The default CPU cap: 60% of all the CPUs (nproc --all: OMP_NUM_THREADS and taskset don't count), 2 if
# nproc fails. The stub prints 3 for --all, 1 without it.
printf '#!/usr/bin/env bash\nif [ "$*" = --all ]; then echo 3; else echo 1; fi\n' > "$BIN/nproc"; chmod +x "$BIN/nproc"
newlog cpus; C true
assert_contains "default CPU cap: 60% of all the CPUs" "$(cat "$LOG")" "MemorySwapMax=0 CPUQuota=180%"
newlog cpusomp; OMP_NUM_THREADS=1 C true
assert_contains "default CPU cap: OMP_NUM_THREADS doesn't lower it" "$(cat "$LOG")" "MemorySwapMax=0 CPUQuota=180%"
newlog cpusfail; printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/nproc"
C true; rm "$BIN/nproc"
assert_contains "default CPU cap: nproc fails, 2 CPUs" "$(cat "$LOG")" "MemorySwapMax=0 CPUQuota=120%"
assert_contains "arguments kept as they are" "$(C printf '%s|' 'a b' '' c)" "a b||c|"
# A newer systemd-run: --expand-environment=no, in the check and the real call, so ${...} and $$ stay as they are.
newlog expand; touch "$EXPANDS"
out="$(C printf '%s|' '${HOME}' 'a$$b')"
rm -f "$EXPANDS"
assert_contains "newer systemd-run: \${...} and \$\$ kept" "$out" '${HOME}|a$$b|'
assert "newer systemd-run: the check and the call" test "$(grep -c -- 'TimeoutStopSec=10 --expand-environment=no -- ' "$LOG")" = 2

# Inside another capped command, a scope of its own too.
newlog nested
C bash -c 'bash "$1" true' _ "$ROOT/scripts/capped.sh"
assert "nested: a scope of its own"         test "$(sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$LOG" | sort -u | wc -l)" = 2
assert "nested: in capped.slice too"        test "$(grep -c -- '--slice=capped.slice --unit=' "$LOG")" = 2

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

# CAP_OFF=1: the command runs as it is, also where the caps can't be applied.
newlog off; echo 99 > "$SLICE_FAILS"
out="$(CAP_OFF=1 PATH="$BIN:$PATH" XDG_RUNTIME_DIR="$TMP/run" bash "$ROOT/scripts/capped.sh" bash -c 'echo ran; exit 4')"; rc=$?
rm -f "$SLICE_FAILS"
assert_contains "CAP_OFF: the command runs" "$out" "ran"
assert "CAP_OFF: its exit code"             test "$rc" = 4
assert "CAP_OFF: no scope"                  test ! -s "$LOG"

# No systemd user instance (no socket of a user manager, no XDG_RUNTIME_DIR, no systemd-run or systemctl):
# uncapped, with a warning, after one try.
newlog nosys; touch "$NO_SYSTEMD"
out="$(XDG="$TMP/norun" C bash -c 'echo cmd-ran; exit 5' 2>&1)"; rc=$?
rm -f "$NO_SYSTEMD"
assert_contains "no systemd: a warning"     "$out" "capped: no systemd user instance to apply the caps, so 'bash -c' runs without a cap"
assert_contains "no systemd: the command runs" "$out" "cmd-ran"
assert "no systemd: its exit code"          test "$rc" = 5
assert "no systemd: one try, no wait"       test "$(grep -cE 'set-property|^sleep' "$LOG")" = 1
assert "no systemd: no scope to stop"       test -z "$(grep "systemctl --user stop" "$LOG")"
newlog noxdg; touch "$NO_SYSTEMD"
out="$(env -u CAP_OFF -u XDG_RUNTIME_DIR PATH="$BIN:$PATH" bash "$ROOT/scripts/capped.sh" bash -c 'echo cmd-ran; exit 5' 2>&1)"; rc=$?
rm -f "$NO_SYSTEMD"
assert_contains "no XDG_RUNTIME_DIR: the command runs, with a warning" "$out" "runs without a cap"$'\n'"cmd-ran"
assert "no XDG_RUNTIME_DIR: its exit code"  test "$rc" = 5
# A regular file where the manager's socket would be: no user manager either.
mkdir -p "$TMP/filerun/systemd"; : > "$TMP/filerun/systemd/private"
newlog notsock; touch "$NO_SYSTEMD"
out="$(XDG="$TMP/filerun" C bash -c 'echo cmd-ran; exit 5' 2>&1)"; rc=$?
rm -f "$NO_SYSTEMD"
assert_contains "a file, not a socket: the command runs, with a warning" "$out" "runs without a cap"$'\n'"cmd-ran"
assert "a file, not a socket: its exit code" test "$rc" = 5
# Without systemd-run or systemctl (a PATH of bash and the other stub), even with a user manager's socket.
for missing in systemd-run systemctl; do
  d="$TMP/no-$missing"; mkdir -p "$d"; ln -s "$(command -v bash)" "$d/bash"
  for s in systemd-run systemctl; do [ "$s" = "$missing" ] || cp "$BIN/$s" "$d/"; done
  newlog "no-$missing"
  out="$(env -u CAP_OFF PATH="$d" XDG_RUNTIME_DIR="$TMP/run" "$d/bash" "$ROOT/scripts/capped.sh" bash -c 'echo cmd-ran; exit 6' 2>&1)"; rc=$?
  assert_contains "no $missing: the command runs, with a warning" "$out" "runs without a cap"$'\n'"cmd-ran"
  assert "no $missing: its exit code"       test "$rc" = 6
done
# No socket, but the check passes (e.g. over $DBUS_SESSION_BUS_ADDRESS): capped, as before.
newlog nosock
out="$(XDG="$TMP/norun" C bash -c 'echo cmd-ran' 2>&1)"
assert "no socket, the check passes: capped" test "$out" = cmd-ran -a -n "$(unit)"

# With a user manager's socket, a check that fails every try (a call that times out, a cap it can't set):
# 3 tries, 1 s apart, then no command, exit 125, and a message that names CAP_OFF=1.
newlog closed; echo 99 > "$SLICE_FAILS"
out="$(C bash -c 'echo cmd-ran; echo cmd-ran >> "$LOG"' 2>&1)"; rc=$?
rm -f "$SLICE_FAILS"
assert "no cap: exit 125"                   test "$rc" = 125
assert_not_contains "no cap: the command doesn't run" "$out$(cat "$LOG")" "cmd-ran"
assert "no cap: no scope"                   test -z "$(unit)"
assert "no cap: 3 tries, 1 s apart"         test "$(grep -oE '^(systemctl --user set-property|sleep 1)' "$LOG" | paste -sd,)" = \
  "systemctl --user set-property,sleep 1,systemctl --user set-property,sleep 1,systemctl --user set-property"
assert_contains "no cap: says so"           "$out" "capped: systemd couldn't apply the caps (3 tries; last: Failed to set unit properties on capped.slice: Connection timed out), so 'bash -c' didn't run."
assert_contains "no cap: names CAP_OFF=1"   "$out" "CAP_OFF=1 runs it without a cap, on purpose."
newlog noswap; touch "$NO_SWAP_CAP"
out="$(C bash -c 'echo cmd-ran' 2>&1)"; rc=$?
rm -f "$NO_SWAP_CAP"
assert "a cap it can't apply: exit 125"     test "$rc" = 125
assert_not_contains "a cap it can't apply: the command doesn't run" "$out" "cmd-ran"
assert_contains "a cap it can't apply: what systemd said last" "$out" "(3 tries; last: Unknown assignment: MemorySwapMax=0)"
assert_not_contains "a cap it can't apply: only its last line" "$out" "Setting MemorySwapMax"
# A check that fails, then passes: capped as usual.
for n in 1 2; do
  newlog "flaky$n"; echo "$n" > "$SLICE_FAILS"
  out="$(C bash -c 'echo cmd-ran; exit 7' 2>&1)"; rc=$?
  rm -f "$SLICE_FAILS"
  assert "fails $n time(s), then passes: the command runs, without a message" test "$out" = cmd-ran
  assert "fails $n time(s), then passes: its exit code" test "$rc" = 7
  assert "fails $n time(s), then passes: in a scope of its own" grep -q -- "--unit=$(unit) .* -- bash -c" "$LOG"
  assert "fails $n time(s), then passes: $((n + 1)) tries" test "$(grep -c set-property "$LOG")" = $((n + 1))
done

out="$(C 2>&1)"; rc=$?
assert_contains "no command: usage"         "$out" "usage: capped.sh <command...>"
assert "no command: exit 2"                 test "$rc" = 2

# With a real systemd user instance that can apply the caps (capped.sh runs without its warning): this file
# runs in a scope of its own in capped.slice (from lib.sh), the caps apply, a nested call's scope is in
# capped.slice too, a setsid child stays in the scope, and what is left running is stopped, also when
# capped.sh is killed.
if [ -z "$(env -u CAP_OFF bash "$ROOT/scripts/capped.sh" true 2>&1)" ]; then
  cg="$(cut -d: -f3 /proc/self/cgroup)"
  assert "real: this file runs in a scope of its own" test "${cg##*/capped-}" != "$cg" -a "$cg" != "$(cut -d: -f3 "/proc/$PPID/cgroup")"
  assert "real: in capped.slice"              test "$(basename "$(dirname "$cg")")" = capped.slice
  m="600.$$"
  out="$(env -u CAP_OFF CAP_TASKS=30 CAP_MEMORY=300M bash "$ROOT/scripts/capped.sh" bash -c '
    cg="$(cut -d: -f3 /proc/self/cgroup)"; d="/sys/fs/cgroup$cg"
    echo "pids.max=$(cat "$d/pids.max") memory.max=$(cat "$d/memory.max") swap.max=$(cat "$d/memory.swap.max")"
    s="$(dirname "$d")"
    echo "slice=${s##*/} pids.max=$(cat "$s/pids.max") memory.max=$(cat "$s/memory.max") swap.max=$(cat "$s/memory.swap.max")"
    if [ -f "$s/cpu.max" ]; then echo "slice cpu.max=$(cat "$s/cpu.max")"; else echo "slice: no cpu controller"; fi
    n="$(bash "$1" bash -c "cut -d: -f3 /proc/self/cgroup")"
    [ "$(dirname "$n")" = "$(dirname "$cg")" ] && [ "$n" != "$cg" ] && echo "nested: a scope of its own in capped.slice"
    setsid sleep '"$m"' </dev/null >/dev/null 2>&1 & sleep 0.2
    [ "$(cut -d: -f3 /proc/$!/cgroup)" = "$cg" ] && echo "setsid child in the scope"' _ "$ROOT/scripts/capped.sh")"
  assert_contains "real: the caps apply"      "$out" "pids.max=30 memory.max=314572800 swap.max=0"
  assert_contains "real: the overall cap applies" "$out" "slice=capped.slice pids.max=4000 memory.max=5368709120 swap.max=0"
  # With the cpu controller delegated (setup.sh caps), the overall CPU cap applies: 60% of the CPUs per 100 ms
  if [[ "$out" != *"slice: no cpu controller"* ]]; then
    assert_contains "real: the overall CPU cap applies" "$out" "slice cpu.max=$(($(nproc --all) * 60000)) 100000"
  fi
  assert_contains "real: a nested call, in capped.slice too" "$out" "nested: a scope of its own in capped.slice"
  assert_contains "real: \${...} and \$\$ kept"  "$(env -u CAP_OFF bash "$ROOT/scripts/capped.sh" printf '%s|' '${HOME}' 'a$$b')" '${HOME}|a$$b|'
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
  # The real systemctl and systemd-run with no user manager to reach: uncapped, with the warning. With the
  # socket of one that doesn't answer (bound, not listening; a relative path, for a long $TMP): no command.
  out="$(env -u CAP_OFF -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS bash "$ROOT/scripts/capped.sh" bash -c 'echo cmd-ran' 2>&1)"
  assert_contains "real: no user manager to reach: uncapped, with the warning" "$out" "runs without a cap"$'\n'"cmd-ran"
  mkdir -p "$TMP/dead/systemd"; sock "$TMP/dead/systemd/private"
  out="$(cd "$TMP" && env -u CAP_OFF -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR=dead bash "$ROOT/scripts/capped.sh" bash -c 'echo cmd-ran' 2>&1)"; rc=$?
  assert "real: a manager that doesn't answer: exit 125" test "$rc" = 125
  assert_not_contains "real: a manager that doesn't answer: the command doesn't run" "$out" "cmd-ran"
  assert_contains "real: a manager that doesn't answer: the message" "$out" "didn't run. CAP_OFF=1"
else
  echo "  --   no systemd user instance: the real caps not checked"
fi

finish
