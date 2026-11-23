# shellcheck shell=bash
# Tests for apps/stats/dashboard.sh: ingest into the default db, the report written, then served by serve.py and
# opened, with msedge.exe and wslpath stubbed (the real Edge never starts). The server it starts is stopped at
# the end.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

DS="$ROOT/apps/stats/dashboard.sh"
export TZ=UTC PR_QUEUE_DIR="$TMP/state" XDG_STATE_HOME="$TMP/xdg" STATS_WINDOWS_USERS_DIR="$TMP/users"
export STATS_EDGE="$TMP/bin/msedge.exe" EDGE_ARGV="$TMP/edge.argv"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR CLAUDERAPTOR_WINDOWS_USER
# Never the real ~/.claude: the ingest reads transcripts from $HOME/.claude/projects.
export HOME="$TMP/home"; unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME"
# shellcheck disable=SC2329 # called by the trap
stop_servers() { local p; while read -r p; do kill -9 "$p" 2>/dev/null; done < <(cat "$TMP/pids" 2>/dev/null); rm -rf "$TMP"; }
trap stop_servers EXIT
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
# shellcheck disable=SC2329 # called through assert
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
assert_contains "the report written as a file" "$out" "report: $SD/report.html"
assert_contains "the file's Refresh button is hidden" "$(cat "$SD/report.html")" '<button id="refresh" type="button" hidden>'
pid="$(python3 -I -B -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$SD/serve.json" 2>/dev/null)"
port="$(python3 -I -B -c 'import json, sys; print(json.load(open(sys.argv[1]))["port"])' "$SD/serve.json" 2>/dev/null)"
echo "$pid" >> "$TMP/pids"
assert "a server runs" test -n "$pid" -a -e "/proc/$pid"
assert_contains "and says so" "$out" "report: serving it at http://127.0.0.1:$port/ (pid $pid;"
assert "Edge started" wait_argv
assert_contains "with the server's page as an app" "$(cat "$EDGE_ARGV")" "--app=http://127.0.0.1:$port/?k="
assert_contains "and bob's profile" "$(cat "$EDGE_ARGV")" "\\users\\bob\\AppData\\Local\\clauderaptor-stats\\stats-profile"
tk="$(sed -n 's/^--app=.*?k=//p' "$EDGE_ARGV")"
page="$(python3 -I -B -c 'import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=20); c.request("GET", "/?k=" + sys.argv[2])
r = c.getresponse(); print(r.status); print(r.read().decode())' "$port" "$tk" 2>&1)"
assert "the link opens the page" test "$(head -1 <<<"$page")" = 200
assert_contains "with the Refresh script" "$page" '<script nonce="'

rm -f "$EDGE_ARGV"
out="$(PATH="$TMP/bin:$PATH" bash "$DS" --windows-user bob 2>&1)"; rc=$?
assert "again: exit 0" test "$rc" -eq 0
assert_contains "reuses the server" "$out" "report: reusing the server at http://127.0.0.1:$port/ (pid $pid)"
assert "Edge started again" wait_argv
assert_contains "on the same port" "$(cat "$EDGE_ARGV")" "--app=http://127.0.0.1:$port/?k="
kill "$pid"

finish
