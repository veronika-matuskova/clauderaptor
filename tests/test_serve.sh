# shellcheck shell=bash
# Tests for apps/stats/serve.py: servers on 127.0.0.1 port 0 over a stats db in the temp dir, talked to with
# python's http.client; open with msedge.exe and wslpath stubbed (the real Edge never starts). Every server the
# tests start is stopped at the end.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

SV="$ROOT/apps/stats/serve.py"
ST="$ROOT/apps/stats/stats.py"
RP="$ROOT/apps/stats/report.py"
export TZ=UTC PR_QUEUE_DIR="$TMP/state" XDG_STATE_HOME="$TMP/xdg"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR CLAUDERAPTOR_WINDOWS_USER
# Never the real ~/.claude: the ingest reads transcripts from --projects, and $HOME is in the temp dir.
export HOME="$TMP/home"; unset CLAUDE_CONFIG_DIR
export STATS_EDGE="$TMP/no-edge/msedge.exe" STATS_WINDOWS_USERS_DIR="$TMP/users"  # never the real Edge
mkdir -p "$PR_QUEUE_DIR/reviews" "$HOME" "$TMP/projects/p" "$TMP/bin" "$TMP/users/alice/AppData/Local/Microsoft/Edge"
# git, as the ingest runs it in the queue's checkouts: it waits while $HOLD is a fifo, until the test writes to it.
mkdir -p "$TMP/gitbin" "$TMP/checkout" "$PR_QUEUE_DIR/repos/app"
cat > "$TMP/gitbin/git" <<EOF
#!/bin/sh
if [ -p "\$HOLD" ]; then cat "\$HOLD" >/dev/null; fi
exec $(command -v git) "\$@"
EOF
chmod +x "$TMP/gitbin/git"
echo "$TMP/checkout" > "$PR_QUEUE_DIR/repos/app/checkout"
export PATH="$TMP/gitbin:$PATH" HOLD="$TMP/hold"
# shellcheck disable=SC2329 # called by the trap
stop_servers() { local p; while read -r p; do kill -9 "$p" 2>/dev/null; done < <(cat "$TMP/pids" 2>/dev/null); rm -rf "$TMP"; }
trap stop_servers EXIT

SD="$XDG_STATE_HOME/clauderaptor-stats"; DB="$SD/stats.db"; OUT="$SD/report.html"
# event <n>: a merged branch feat/b<n>
event() { printf '{"v":1,"ts":"2026-10-0%dT10:00:00.000Z","event":"merged","repo":"app","branch":"feat/b%d","job_id":"%d-feat-b%d","pr":%d}\n' \
  "$1" "$1" "$1" "$1" "$1" >> "$PR_QUEUE_DIR/events.jsonl"; }
event 1
python3 -I -B "$ST" ingest --db "$DB" --projects "$TMP/projects" >/dev/null 2>&1
python3 -I -B "$RP" --db "$DB" --out "$OUT" >/dev/null 2>&1

# req <port> <method> <path> [Name: value]...: the status, the headers and the body. The Host is 127.0.0.1:<port>
# unless one is given; "Host:" alone sends none.
cat > "$TMP/req.py" <<'EOF'
import http.client, sys
port, method, path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
hdrs = [(h.split(":", 1)[0], h.split(":", 1)[1].strip()) for h in sys.argv[4:]]
c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
if not any(k.lower() == "host" for k, _ in hdrs):
    c.putheader("Host", "127.0.0.1:%d" % port)
for k, v in hdrs:
    if v:
        c.putheader(k, v)
c.endheaders()
r = c.getresponse()
print(r.status)
for k, v in r.getheaders():
    print("%s: %s" % (k, v))
print()
print(r.read().decode("utf-8", "replace"))
EOF
req() { python3 -I -B "$TMP/req.py" "$@" 2>&1; }
code() { req "$@" | head -1; }
body() { req "$@" | sed '1,/^$/d'; }
# state <stats dir> <key>: serve.json's pid, port or token
state() { python3 -I -B -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1/serve.json" "$2" 2>/dev/null; }
# shellcheck disable=SC2329 # called through assert
gone() { for _ in $(seq 150); do
  [ -e "/proc/$1" ] && ! grep -q '^[0-9]* ([^)]*) Z' "/proc/$1/stat" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
alive() { [ -e "/proc/$1" ] && ! grep -q '^[0-9]* ([^)]*) Z' "/proc/$1/stat" 2>/dev/null; }
# start_server <stats dir> [serve.py run args...]: a server in the background; sets PID, PORT and TOKEN
start_server() {
  local sd="$1"; shift
  python3 -I -B "$SV" run --db "$sd/stats.db" "$@" >"$sd.hs" 2>>"$sd.log" &
  PID=$!; echo "$PID" >> "$TMP/pids"
  for _ in $(seq 150); do grep -q '^ready ' "$sd.hs" 2>/dev/null && break; sleep 0.1; done
  PORT="$(state "$sd" port)"; TOKEN="$(state "$sd" token)"
}

echo "-- a server"
start_server "$SD" --projects "$TMP/projects" --idle 120
assert "says it is ready, with its port" test "$(cat "$SD.hs")" = "ready $PORT"
assert "serve.json has its pid" test "$(state "$SD" pid)" = "$PID"
assert "serve.json is 0600" test "$(stat -c %a "$SD/serve.json")" = 600
assert "a long token" test "${#TOKEN}" -ge 40
assert_not_contains "the token is not in the server's arguments" "$(tr '\0' ' ' < "/proc/$PID/cmdline")" "$TOKEN"
listen="$(python3 -I -B -c 'import sys
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    for l in open(f).readlines()[1:]:
        a = l.split()
        if a[3] == "0A" and int(a[1].split(":")[1], 16) == int(sys.argv[1]):
            print(a[1].split(":")[0])' "$PORT")"
assert "listens on 127.0.0.1 only" test "$listen" = 0100007F

echo "-- the page"
R="$(req "$PORT" GET "/?t=$TOKEN")"
assert "the right token: 200" test "$(head -1 <<<"$R")" = 200
csp="$(grep -i '^Content-Security-Policy:' <<<"$R")"
nonce="$(sed -n "s/.*'nonce-\([A-Za-z0-9_-]*\)'.*/\1/p" <<<"$csp")"
assert "the CSP header has a nonce" test "${#nonce}" -ge 16
assert_contains "and allows nothing else but inline styles, data: images and the server" "$csp" \
  "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; script-src 'nonce-$nonce'; connect-src 'self'; frame-ancestors 'none'"
assert_contains "the meta CSP has the same nonce" "$R" \
  "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; script-src 'nonce-$nonce'; connect-src 'self'\">"
assert "one script" test "$(grep -o '<script' <<<"$R" | wc -l)" -eq 1
assert_contains "and it carries the nonce" "$R" "<script nonce=\"$nonce\">(function () {"
assert_contains "with the token" "$R" "var T = \"$TOKEN\""
assert_contains "it posts /refresh" "$R" 'post("/refresh")'
assert_contains "and a heartbeat every 60 s" "$R" 'post("/heartbeat").catch(function () {}); }, 60000)'
assert_contains "the button, which the script shows" "$R" '<button id="refresh" type="button" hidden>Refresh</button>'
assert_contains "the script shows it" "$R" "b.hidden = false;"
assert_contains "Last ingested in the header" "$R" '<span class="sub">Last ingested: '
assert_not_contains "no inline handlers" "$R" " onclick="
assert_contains "not cached" "$R" "Cache-Control: no-store"
nonce2="$(req "$PORT" GET "/?t=$TOKEN" | sed -n "s/^Content-Security-Policy:.*'nonce-\([A-Za-z0-9_-]*\)'.*/\1/p")"
assert "a new nonce for each page" test -n "$nonce2" -a "$nonce2" != "$nonce"
assert_contains "the page has the db's numbers" "$R" 'Merged branches</div><div class="tv">1<'

echo "-- the token"
assert "no token: 403" test "$(code "$PORT" GET /)" = 403
assert "a wrong token: 403" test "$(code "$PORT" GET "/?t=${TOKEN%?}x")" = 403
assert "an empty token: 403" test "$(code "$PORT" GET "/?t=")" = 403
assert "the token twice: 403" test "$(code "$PORT" GET "/?t=$TOKEN&t=$TOKEN")" = 403
assert "the token in a header doesn't open the page: 403" test "$(code "$PORT" GET / "X-Raptor-Token: $TOKEN")" = 403
assert "POST without a token: 403" test "$(code "$PORT" POST /refresh)" = 403
assert "POST with a wrong token: 403" test "$(code "$PORT" POST /refresh "X-Raptor-Token: x$TOKEN")" = 403
assert "POST with a query (the token in it): 404" test "$(code "$PORT" POST "/heartbeat?t=$TOKEN")" = 404
assert_contains "a 403 says only forbidden" "$(body "$PORT" GET /)" '{"ok": false, "error": "forbidden"}'

echo "-- the Host"
assert "localhost:<port>: 200" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: localhost:$PORT")" = 200
assert "another host name: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: evil.example:$PORT")" = 403
assert "a rebinding name: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: 127.0.0.1.evil.example:$PORT")" = 403
assert "another port: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: 127.0.0.1:1")" = 403
assert "no port: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: 127.0.0.1")" = 403
assert "no Host: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host:")" = 403
assert "two Hosts: 403" test "$(code "$PORT" GET "/?t=$TOKEN" "Host: 127.0.0.1:$PORT" "Host: evil.example")" = 403
assert "POST, another host: 403" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Host: evil.example:$PORT")" = 403

echo "-- the Origin"
assert "POST, no Origin: 200" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN")" = 200
assert "POST, the same origin: 200" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Origin: http://127.0.0.1:$PORT")" = 200
assert "localhost's own origin: 200" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Host: localhost:$PORT" "Origin: http://localhost:$PORT")" = 200
assert "another origin: 403" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Origin: http://evil.example")" = 403
assert "Origin null: 403" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Origin: null")" = 403
assert "the other name of the server: 403" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Origin: http://localhost:$PORT")" = 403
assert "https: 403" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Origin: https://127.0.0.1:$PORT")" = 403
assert "POST /refresh, another origin: 403" test "$(code "$PORT" POST /refresh "X-Raptor-Token: $TOKEN" "Origin: http://evil.example")" = 403

echo "-- other methods and paths"
for m in PUT DELETE PATCH HEAD OPTIONS; do
  assert "$m: 501" test "$(code "$PORT" "$m" "/?t=$TOKEN")" = 501
done
assert "POST /: 404" test "$(code "$PORT" POST / "X-Raptor-Token: $TOKEN")" = 404
assert "POST /other: 404" test "$(code "$PORT" POST /report.html "X-Raptor-Token: $TOKEN")" = 404
assert "GET /refresh: 404" test "$(code "$PORT" GET "/refresh?t=$TOKEN")" = 404
assert "GET /report.html: 404" test "$(code "$PORT" GET "/report.html?t=$TOKEN")" = 404
assert "GET /../stats.db: 404" test "$(code "$PORT" GET "/../stats.db?t=$TOKEN")" = 404
assert "a large body: 413" test "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN" "Content-Length: 5000")" = 413

echo "-- tickets"
tk="$(body "$PORT" POST /ticket "X-Raptor-Token: $TOKEN" | python3 -I -B -c 'import json, sys; print(json.load(sys.stdin)["ticket"])')"
assert "a ticket" test "${#tk}" -ge 40 -a "$tk" != "$TOKEN"
assert "no ticket without the token: 403" test "$(code "$PORT" POST /ticket)" = 403
assert "a ticket opens the page: 200" test "$(code "$PORT" GET "/?k=$tk")" = 200
assert "only once: 403" test "$(code "$PORT" GET "/?k=$tk")" = 403
assert "a made-up ticket: 403" test "$(code "$PORT" GET "/?k=${tk%?}x")" = 403
assert "the token as a ticket: 403" test "$(code "$PORT" GET "/?k=$TOKEN")" = 403

echo "-- refresh picks up new data"
assert_contains "no sessions yet" "$(body "$PORT" GET "/?t=$TOKEN")" '<tr><td>sessions</td><td class="num">0</td></tr>'
event 2
# a transcript in --projects: the ingest reads it from there ($HOME/.claude/projects stays empty)
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-02T10:00:00.000Z","sessionId":"s1","cwd":"/x","message":{"id":"m1","model":"claude-opus-4-1","usage":{"input_tokens":5,"output_tokens":7}}}' \
  > "$TMP/projects/p/s1.jsonl"
R="$(req "$PORT" POST /refresh "X-Raptor-Token: $TOKEN" "Origin: http://127.0.0.1:$PORT")"
assert "200" test "$(head -1 <<<"$R")" = 200
assert_contains "ok" "$R" '{"ok": true, "message": "refreshed"}'
assert_contains "the page has the new numbers" "$(body "$PORT" GET "/?t=$TOKEN")" 'Merged branches</div><div class="tv">2<'
assert_contains "and so does the file" "$(cat "$OUT")" 'Merged branches</div><div class="tv">2<'
assert_not_contains "which has no script" "$(cat "$OUT")" "<script"
assert "and stays 0600" test "$(stat -c %a "$OUT")" = 600
assert_contains "the ingest read --projects" "$(body "$PORT" GET "/?t=$TOKEN")" '<tr><td>sessions</td><td class="num">1</td></tr>'
assert_contains "the page shows a failed refresh's error, and reloads only on ok" "$(body "$PORT" GET "/?t=$TOKEN")" \
  'if (r.ok && j.ok) { location.reload(); return; }
        say("Refresh failed: " + (j.error || "HTTP " + r.status));'

echo "-- a failed refresh"
cp "$DB" "$TMP/db.bak"
echo "not a db" > "$DB"
R="$(req "$PORT" POST /refresh "X-Raptor-Token: $TOKEN")"
assert "500" test "$(head -1 <<<"$R")" = 500
assert_contains "a short error" "$R" '{"ok": false, "error": "the ingest failed (exit 1); see serve.log in the stats folder"}'
assert_not_contains "no traceback" "$R" "Traceback"
assert_not_contains "no path" "$(sed '1,/^$/d' <<<"$R")" "/"
assert_contains "the log has the details" "$(cat "$SD.log")" "Traceback"
cp "$TMP/db.bak" "$DB"
assert "and the next refresh works" test "$(code "$PORT" POST /refresh "X-Raptor-Token: $TOKEN")" = 200

echo "-- a failed rebuild, a missing report, a file that is not a report"
mv "$OUT" "$TMP/report.bak"; mkdir "$OUT"  # report.py can't replace a folder
R="$(req "$PORT" POST /refresh "X-Raptor-Token: $TOKEN")"
assert "a failed rebuild: 500" test "$(head -1 <<<"$R")" = 500
assert_contains "says so" "$R" '{"ok": false, "error": "the rebuild failed (exit 1); see serve.log in the stats folder"}'
rmdir "$OUT"
R="$(req "$PORT" GET "/?t=$TOKEN")"
assert "no report file: 503" test "$(head -1 <<<"$R")" = 503
assert_contains "says to run raptor-stats" "$R" "no report yet: run raptor-stats"
echo '<html><body>not the report</body></html>' > "$OUT"
R="$(req "$PORT" GET "/?t=$TOKEN")"
assert "a file that is not a report page: 500" test "$(head -1 <<<"$R")" = 500
assert_contains "says so" "$R" "the report file is not a report page"
assert_not_contains "and doesn't serve it" "$R" "not the report"
mv "$TMP/report.bak" "$OUT"
assert "the report again: 200" test "$(code "$PORT" GET "/?t=$TOKEN")" = 200

echo "-- one refresh at a time"
mkfifo "$HOLD"  # the ingest's git waits on it until the test writes
cat > "$TMP/conc.py" <<'EOF'
import errno, http.client, os, sys, threading, time
port, token, fifo = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def req(method, path, **kw):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    c.request(method, path, **kw)
    r = c.getresponse()
    return r.status, r.read().decode()
first = {}
t = threading.Thread(target=lambda: first.update(r=req("POST", "/refresh", headers={"X-Raptor-Token": token})))
t.start()
fd, deadline = None, time.monotonic() + 30
while fd is None and time.monotonic() < deadline:  # opens once the ingest's git waits on it
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno != errno.ENXIO:
            raise
        time.sleep(0.05)
if fd is None:
    sys.exit("the ingest never ran git")
second = req("POST", "/refresh", headers={"X-Raptor-Token": token})
page = req("GET", "/?t=" + token)[0]
beat = req("POST", "/heartbeat", headers={"X-Raptor-Token": token})[0]
os.unlink(fifo)  # the ingest's next git calls don't wait
os.write(fd, b"go\n")
os.close(fd)
t.join(60)
print("first %s / second %s %s / page %s / heartbeat %s" % (first.get("r", ("none",))[0], second[0], second[1], page, beat))
EOF
out="$(timeout 90 python3 -I -B "$TMP/conc.py" "$PORT" "$TOKEN" "$HOLD" 2>&1)"
assert_contains "a second refresh while one runs: 409, and the first one finishes" "$out" \
  'first 200 / second 409 {"ok": false, "error": "a refresh is already running"} / page 200 / heartbeat 200'
rm -f "$HOLD"
assert "after it, a refresh runs again" test "$(code "$PORT" POST /refresh "X-Raptor-Token: $TOKEN")" = 200

echo "-- the log"
assert_not_contains "no token in the log" "$(cat "$SD.log")" "$TOKEN"
assert_not_contains "no ticket in the log" "$(cat "$SD.log")" "$tk"
assert_contains "but the requests" "$(cat "$SD.log")" "GET / 200"

echo "-- stops"
kill "$PID"
assert "on SIGTERM" gone "$PID"
assert "and removes serve.json" test ! -e "$SD/serve.json"

echo "-- idle timeout"
SD2="$TMP/xdg2/clauderaptor-stats"; mkdir -p "$SD2"; cp "$DB" "$OUT" "$SD2/"
start_server "$SD2" --idle 1
assert "it starts" alive "$PID"
assert "it stops after --idle seconds without a request" gone "$PID"
assert "and removes serve.json" test ! -e "$SD2/serve.json"
assert_contains "and says why" "$(cat "$SD2.log")" "idle for 1 s: stopping"
start_server "$SD2" --idle 2
end=$(($(date +%s%N) + 6000000000)); beats=0; up=1
while [ "$(date +%s%N)" -lt "$end" ]; do  # 3 times --idle, a heartbeat every 0.5 s
  [ "$(code "$PORT" POST /heartbeat "X-Raptor-Token: $TOKEN")" = 200 ] || { up=0; break; }
  beats=$((beats + 1)); sleep 0.5
done
assert "heartbeats keep it up past --idle" test "$up" -eq 1 -a "$beats" -ge 4
assert "and it is still up" alive "$PID"
assert "then it stops" gone "$PID"
start_server "$SD2" --idle 2
end=$(($(date +%s%N) + 8000000000))
while [ "$(date +%s%N)" -lt "$end" ] && alive "$PID"; do  # requests that fail the token check don't count
  code "$PORT" POST /heartbeat "X-Raptor-Token: wrong" >/dev/null; sleep 0.5
done
assert "requests without the token don't keep it up: it stops while they come" test -z "$(alive "$PID" && echo up)"
gone "$PID"

echo "-- a refresh longer than --idle"
: > "$SD2.log"
start_server "$SD2" --idle 2
mkfifo "$HOLD"
cat > "$TMP/long.py" <<'EOF'
import errno, http.client, os, sys, threading, time
port, token, fifo = int(sys.argv[1]), sys.argv[2], sys.argv[3]
res = {}
def refresh():
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    c.request("POST", "/refresh", headers={"X-Raptor-Token": token})
    res["status"] = c.getresponse().status
t = threading.Thread(target=refresh)
t.start()
fd, deadline = None, time.monotonic() + 30
while fd is None and time.monotonic() < deadline:
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno != errno.ENXIO:
            raise
        time.sleep(0.05)
if fd is None:
    sys.exit("the ingest never ran git")
time.sleep(5)  # the ingest is held for over twice --idle, with no other request
os.unlink(fifo)
os.write(fd, b"go\n")
os.close(fd)
t.join(60)
print("refresh", res.get("status"))
EOF
out="$(timeout 90 python3 -I -B "$TMP/long.py" "$PORT" "$TOKEN" "$HOLD" 2>&1)"
assert_contains "the refresh answers" "$out" "refresh 200"
assert_not_contains "the idle watch left the server alone while it ran" "$(cat "$SD2.log")" "stopping"
assert "the server is still up right after it" alive "$PID"
assert "and stops when idle after it" gone "$PID"
rm -f "$HOLD"

echo "-- open: a new server, then the same one again"
cat > "$TMP/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -w ] || exit 1
p="$2"; printf '%s\n' "\\\\wsl.localhost\\Ubuntu${p//\//\\}"
EOF
cat > "$TMP/bin/msedge.exe" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$EDGE_ARGV.tmp"; mv "$EDGE_ARGV.tmp" "$EDGE_ARGV"
EOF
chmod +x "$TMP/bin/wslpath" "$TMP/bin/msedge.exe"
export EDGE_ARGV="$TMP/edge.argv"
# shellcheck disable=SC2329 # called through assert
wait_argv() { for _ in $(seq 50); do [ -f "$EDGE_ARGV" ] && return 0; sleep 0.1; done; return 1; }
sopen() { PATH="$TMP/bin:$PATH" STATS_EDGE="$TMP/bin/msedge.exe" python3 -I -B "$SV" open --db "$DB" --idle 60 "$@" 2>&1; }
out="$(sopen)"; rc=$?
P1="$(state "$SD" pid)"; PORT="$(state "$SD" port)"; TOKEN="$(state "$SD" token)"; echo "$P1" >> "$TMP/pids"
assert "exit 0" test "$rc" -eq 0
assert_contains "starts a server" "$out" "report: serving it at http://127.0.0.1:$PORT/ (pid $P1; it stops 60 s after its last request)"
assert_contains "and opens Edge" "$out" "report: opening it in an Edge app window"
assert "the server runs" alive "$P1"
assert "Edge started" wait_argv
argv="$(cat "$EDGE_ARGV")"
assert_contains "with a ticket link to the server" "$argv" "--app=http://127.0.0.1:$PORT/?k="
assert_contains "and the app's profile" "$argv" "--user-data-dir=\\\\wsl.localhost\\Ubuntu${TMP//\//\\}\\users\\alice\\AppData\\Local\\clauderaptor-stats\\edge-profile"
assert_not_contains "never the token" "$argv" "$TOKEN"
assert_not_contains "nor in the output" "$out" "$TOKEN"
tk1="$(sed -n 's/^--app=.*?k=//p' "$EDGE_ARGV")"
assert "the ticket opens the page" test "$(code "$PORT" GET "/?k=$tk1")" = 200
assert "once" test "$(code "$PORT" GET "/?k=$tk1")" = 403
assert "serve.log is 0600" test "$(stat -c %a "$SD/serve.log")" = 600
assert "serve.lock is 0600" test "$(stat -c %a "$SD/serve.lock")" = 600
assert_not_contains "serve.log has no token" "$(cat "$SD/serve.log")" "$TOKEN"
assert_not_contains "nor the ticket" "$(cat "$SD/serve.log")" "$tk1"
rm -f "$EDGE_ARGV"
out="$(sopen)"; rc=$?
assert "again: exit 0" test "$rc" -eq 0
assert_contains "reuses the running server" "$out" "report: reusing the server at http://127.0.0.1:$PORT/ (pid $P1)"
assert "still one server" test "$(state "$SD" pid)" = "$P1"
assert "Edge started again" wait_argv
tk2="$(sed -n 's/^--app=.*?k=//p' "$EDGE_ARGV")"
assert_contains "on the same port" "$(cat "$EDGE_ARGV")" "--app=http://127.0.0.1:$PORT/?k="
assert "with a new ticket" test -n "$tk2" -a "$tk2" != "$tk1"
assert "which works" test "$(code "$PORT" GET "/?k=$tk2")" = 200

echo "-- open: a server that is gone"
kill -9 "$P1"; assert "killed" gone "$P1"
assert "leaves its serve.json" test -f "$SD/serve.json"
rm -f "$EDGE_ARGV"
out="$(sopen)"; rc=$?
P2="$(state "$SD" pid)"; echo "$P2" >> "$TMP/pids"
assert "exit 0" test "$rc" -eq 0
assert_contains "starts a new one" "$out" "report: serving it at"
assert "another pid" test -n "$P2" -a "$P2" != "$P1"
assert "it runs" alive "$P2"
echo '{"pid": '"$P2"', "port": '"$(state "$SD" port)"', "token": "wrong-token-wrong-token"}' > "$SD/serve.json"
out="$(sopen)"
P3="$(state "$SD" pid)"; echo "$P3" >> "$TMP/pids"
assert_contains "a server that doesn't take serve.json's token is not reused" "$out" "report: serving it at"
assert "another pid again" test -n "$P3" -a "$P3" != "$P2"
kill "$P2"; assert "the old one stops" gone "$P2"
assert "and leaves the new one's serve.json alone" test "$(state "$SD" pid)" = "$P3"
kill "$P3"; assert "the new one stops" gone "$P3"
assert "and removes its serve.json" test ! -e "$SD/serve.json"

echo "-- open: two at the same time"
STATS_EDGE="$TMP/no-edge/msedge.exe" python3 -I -B "$SV" open --db "$DB" --idle 60 >"$TMP/o1" 2>&1 &
o1=$!
STATS_EDGE="$TMP/no-edge/msedge.exe" python3 -I -B "$SV" open --db "$DB" --idle 60 >"$TMP/o2" 2>&1 &
o2=$!
wait "$o1" "$o2"
P4="$(state "$SD" pid)"; echo "$P4" >> "$TMP/pids"
both="$(cat "$TMP/o1" "$TMP/o2")"
assert "one server for both" test "$(grep -c '^report: serving it at' <<<"$both")" -eq 1 -a "$(grep -c "^report: reusing the server at .* (pid $P4)" <<<"$both")" -eq 1
url="$(sed -n 's/^report: open \(http:[^ ]*\) in a browser.*/\1/p' "$TMP/o1")"
assert_contains "outside WSL: a link to open" "$(cat "$TMP/o1")" "the link works once, for 120 s (an Edge app window opens only under WSL: $TMP/no-edge/msedge.exe not found)"
PORT="$(state "$SD" port)"
assert "which opens the page" test "$(code "$PORT" GET "${url#http://127.0.0.1:"$PORT"}")" = 200
kill "$P4"; assert "stops" gone "$P4"

echo "-- open: refusals start no server"
mkdir -p "$TMP/users/bob/AppData/Local/Microsoft/Edge"
rm -f "$EDGE_ARGV"
out="$(sopen)"; rc=$?
assert "several Windows users: exit 2" test "$rc" -eq 2
assert_contains "names them" "$out" "several Windows users have an Edge folder (alice, bob)"
assert "no server started" test ! -e "$SD/serve.json"
assert "and no Edge" test ! -e "$EDGE_ARGV"
out="$(sopen --windows-user bob --out "$TMP/none.html")"; rc=$?
assert "no report file: exit 2" test "$rc" -eq 2
assert_contains "says to make it" "$out" "no report at $TMP/none.html"
out="$(python3 -I -B "$SV" open --db "$TMP/nodb/stats.db" 2>&1)"; rc=$?
assert "no db: exit 2" test "$rc" -eq 2
assert_contains "says to ingest" "$out" "no stats db at $TMP/nodb/stats.db"
git init -q "$TMP/repo"; mkdir -p "$TMP/repo/st"; cp "$DB" "$TMP/repo/st/"
out="$(python3 -I -B "$SV" run --db "$TMP/repo/st/stats.db" 2>&1)"; rc=$?
assert "a stats folder inside a git work tree: exit 2" test "$rc" -eq 2
assert_contains "says why" "$out" "inside the git work tree $TMP/repo"
assert "and writes nothing there" test ! -e "$TMP/repo/st/serve.json"

echo "-- a ticket expires"
out="$(python3 -I -B -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("serve", sys.argv[1]); m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
m.TICKET_TTL = 0
srv = m.Server("db", "out", None, 60)
print(srv.use_ticket(srv.new_ticket()))
m.TICKET_TTL = 60
t = srv.new_ticket()
print(srv.use_ticket(t), srv.use_ticket(t))
srv.server_close()' "$SV" 2>&1)"
assert_contains "an expired ticket is refused; one in time works once" "$out" $'False\nTrue False'

echo "-- no bytecode in the checkout"
assert "no __pycache__ in apps/" test -z "$(find "$ROOT/apps" -name __pycache__)"

finish
