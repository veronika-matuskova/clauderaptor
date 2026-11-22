# shellcheck shell=bash
# Tests for scripts/stats/dashboard.sh: ingest into the default db, then the report opened, with msedge.exe and
# wslpath stubbed (the real Edge never starts).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

DS="$ROOT/scripts/stats/dashboard.sh"
export TZ=UTC PR_QUEUE_DIR="$TMP/state" XDG_STATE_HOME="$TMP/xdg" STATS_WINDOWS_USERS_DIR="$TMP/users"
export STATS_EDGE="$TMP/bin/msedge.exe" EDGE_ARGV="$TMP/edge.argv"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR CLAUDERAPTOR_WINDOWS_USER
mkdir -p "$PR_QUEUE_DIR/reviews" "$TMP/bin" "$TMP/users/alice/AppData/Local/Microsoft/Edge" \
  "$TMP/users/bob/AppData/Local/Microsoft/Edge"
printf '{"v":1,"ts":"2026-10-01T10:00:00.000Z","event":"merged","repo":"app","branch":"feat/a","job_id":"1-feat-a","pr":1}\n' \
  > "$PR_QUEUE_DIR/events.jsonl"
cat > "$TMP/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
p="$2"; printf '%s\n' "\\\\wsl.localhost\\Ubuntu${p//\//\\}"
EOF
cat > "$TMP/bin/msedge.exe" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$EDGE_ARGV"
EOF
chmod +x "$TMP/bin/wslpath" "$TMP/bin/msedge.exe"
wait_argv() { for _ in $(seq 50); do [ -f "$EDGE_ARGV" ] && return 0; sleep 0.1; done; return 1; }

SD="$XDG_STATE_HOME/clauderaptor-stats"
out="$(PATH="$TMP/bin:$PATH" bash "$DS" 2>&1)"; rc=$?
assert "two Windows users and no name: exit 2" test "$rc" -eq 2
assert_contains "report.py's refusal comes through" "$out" "several Windows users"
assert "the ingest ran first: the default db" test -f "$SD/stats.db"
out="$(PATH="$TMP/bin:$PATH" bash "$DS" --windows-user bob 2>&1)"; rc=$?
assert "with --windows-user: exit 0" test "$rc" -eq 0
assert_contains "ingest's counts" "$out" "1 jobs"
assert "the report next to the db" test -f "$SD/report.html"
assert_contains "the report has the ingested numbers" "$(cat "$SD/report.html")" "Merged branches</div><div class=\"tv\">1<"
assert "Edge started" wait_argv
assert_contains "with the report as an app" "$(cat "$EDGE_ARGV")" "--app=file://wsl.localhost/Ubuntu${XDG_STATE_HOME}/clauderaptor-stats/report.html"
assert_contains "and bob's profile" "$(cat "$EDGE_ARGV")" "\\users\\bob\\AppData\\Local\\clauderaptor-stats\\edge-profile"

finish
