# shellcheck shell=bash
# Tests for apps/stats/report.py: a db made by stats.py ingest in the temp dir, filled with known rows, rendered
# to HTML there; --open with msedge.exe and wslpath stubbed (the real Edge never starts).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

RP="$ROOT/apps/stats/report.py"
ST="$ROOT/apps/stats/stats.py"
export TZ=UTC PR_QUEUE_DIR="$TMP/state" XDG_STATE_HOME="$TMP/xdg"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR CLAUDERAPTOR_WINDOWS_USER
# Never the real ~/.claude: stats.py ingest reads transcripts from $HOME/.claude/projects by default.
export HOME="$TMP/home"; unset CLAUDE_CONFIG_DIR
export STATS_EDGE="$TMP/no-edge/msedge.exe" STATS_WINDOWS_USERS_DIR="$TMP/users"  # never the real Edge
mkdir -p "$PR_QUEUE_DIR" "$TMP/out"

report() { python3 -I -B "$RP" "$@" 2>&1; }
# sql <db> <sql script>
sql() { python3 -I -B -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit()' "$1" "$2"; }
# text <html file>: the page's visible text (no tooltips), tags gone and entities decoded, on one line
text() { python3 -I -B -c 'import html, re, sys
s = re.sub(r"<(style|title)>.*?</\1>", "", open(sys.argv[1]).read(), flags=re.S)
print(html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s))))' "$1"; }
hints() { grep -o 'data-hint="[a-z-]*"' "$1" | sort | tr '\n' ' '; }

# An empty db: the schema and views of an ingest of an empty queue state.
EMPTY="$TMP/out/empty.db"
python3 -I -B "$ST" ingest --db "$EMPTY" --projects "$TMP/noprojects" >/dev/null 2>&1

# The fixture: 5 merged branches (rounds 1, 1, 2, 2, 3), 5 failed rounds (3 review_code, 1 conflict, 1 escalated),
# over 4 weeks; reviews: code medium 5 x $0.50 (1 ready), code high 5 x $1.20 (all ready), tests 5 x $0.40
# (10 mutants, 8 caught each), judge 2 x $0.30; the judge ruled on 10 findings: 3 confirmed, 5 downgraded,
# 2 rejected; code/test findings with a category: 6 mutation, 2 empty. A suite audit ($9, 100 mutants, none
# caught, 3 duplicate findings) is not part of the queue: left out of the queue's numbers.
FX="$TMP/out/fx.db"
cp "$EMPTY" "$FX"
sql "$FX" "
INSERT INTO jobs (job_id, repo, branch, round, ended, outcome, fail_reason) VALUES
 ('m1', 'app', 'feat/one', 1, '2026-10-05T10:00:00.000Z', 'merged', NULL),
 ('m2', 'app', 'feat/two', 1, '2026-10-12T10:00:00.000Z', 'merged', NULL),
 ('m3', 'tool', 'feat/three', 2, '2026-10-19T10:00:00.000Z', 'merged', NULL),
 ('f4a', 'app', 'feat/four', 1, '2026-10-26T09:00:00.000Z', 'failed', 'review_code'),
 ('m4', 'app', 'feat/four', 2, '2026-10-26T10:00:00.000Z', 'merged', NULL),
 ('f5a', 'tool', 'feat/five', 1, '2026-10-26T08:00:00.000Z', 'failed', 'review_code'),
 ('f5b', 'tool', 'feat/five', 2, '2026-10-26T09:00:00.000Z', 'failed', 'review_code'),
 ('m5', 'tool', 'feat/five', 3, '2026-10-26T11:00:00.000Z', 'merged', NULL),
 ('f6', 'app', 'feat/six', 1, '2026-10-27T09:00:00.000Z', 'failed', 'conflict'),
 ('e7', 'app', '<script>alert(1)</script>\"><img src=x onerror=alert(1)>', 1, '2026-10-27T10:00:00.000Z', 'escalated', 'judge'),
 ('r8', 'app', 'feat/six', NULL, '2026-10-27T11:00:00.000Z', 'replaced', 'replaced'),
 ('e9', 'app', 'feat/esc-old', 1, '2026-10-20T10:00:00.000Z', 'escalated', 'judge'),
 ('q10', 'app', 'feat/queued', 1, NULL, NULL, NULL);
WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 5)
INSERT INTO reviews (id, repo, kind, level, verdict, cost_usd, mut_tried, mut_caught, finished)
 SELECT 'cm' || n, 'app', 'code', 'medium', CASE n WHEN 1 THEN 'ready' ELSE 'needs changes' END, 0.5, NULL, NULL,
        '2026-10-26T10:00:00.000Z' FROM i
 UNION ALL SELECT 'ch' || n, 'tool', 'code', 'high', 'ready', 1.2, NULL, NULL, '2026-10-27T10:00:00.000Z' FROM i
 UNION ALL SELECT 't' || n, 'app', 'tests', NULL, 'needs changes', 0.4, 10, 8, '2026-10-27T10:00:00.000Z' FROM i;
INSERT INTO reviews (id, repo, kind, verdict, cost_usd, finished) VALUES
 ('j1', 'app', 'judge', 'needs changes', 0.3, '2026-10-27T10:00:00.000Z'),
 ('j2', 'app', 'judge', 'ready', 0.3, '2026-10-27T10:00:00.000Z'),
 ('s1', 'app', 'suite', NULL, 9.0, '2026-10-27T10:00:00.000Z');
UPDATE reviews SET mut_tried = 100, mut_caught = 0 WHERE id = 's1';
WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 10)
INSERT INTO findings (review_id, n, sev_norm, ruling)
 SELECT 'j1', n, 'blocker', CASE WHEN n <= 3 THEN 'confirmed' WHEN n <= 8 THEN 'downgraded' ELSE 'rejected' END FROM i;
WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 8)
INSERT INTO findings (review_id, n, sev_norm, category)
 SELECT 't1', n, CASE WHEN n <= 2 THEN 'blocker' ELSE 'major' END, CASE WHEN n <= 6 THEN 'mutation' ELSE 'empty' END FROM i;
INSERT INTO findings (review_id, n, sev_norm) VALUES ('cm1', 1, 'blocker'), ('cm1', 2, 'minor'), ('cm1', 3, 'minor');
INSERT INTO findings (review_id, n, sev_norm, category) VALUES ('s1', 1, 'blocker', 'duplicate'), ('s1', 2, 'blocker', 'duplicate'), ('s1', 3, 'blocker', 'duplicate');
"

echo "-- the fixture's numbers"
OUT="$TMP/out/fx.html"
out="$(report --db "$FX" --out "$OUT")"; rc=$?
assert "exits 0" test "$rc" -eq 0
assert_contains "prints where it wrote" "$out" "report: $OUT"
T="$(text "$OUT")"
assert_contains "merged branches" "$T" "Merged branches 5 from 17 review runs"
assert_contains "first-pass yield with its n" "$T" "First-pass yield 40% merged in 1 round, n=5"
assert_contains "median rounds" "$T" "Median rounds to merge 2 n=5"
assert_contains "review cost (queue reviews, no suite) and per merged branch" "$T" "Review cost \$11.10 \$2.22 per merged branch"
assert_contains "reviewer precision" "$T" "Reviewer precision 30% judge-confirmed blocking findings, n=10"
assert_contains "rounds distribution, a share with its n" "$T" "Rounds Branches Share 1 2 40% (n=5) 2 2 40% (n=5) 3 1 20% (n=5)"
assert_contains "failure reasons ranked, the replaced job left out" "$T" "review_code 3 judge 2 conflict 1"
assert_contains "failure share with n" "$T" "review_code 3 50% (n=6)"
assert_contains "escalations listed, newest first" "$T" "Escalations to you n=2 Repo Branch When Reason app <script>alert(1)</script>\"><img src=x onerror=alert(1)> 2026-10-27 10:00 judge app feat/esc-old 2026-10-20 10:00 judge"
assert_contains "findings by severity: tests" "$T" "Test review findings n=8 blocker 2 major 6 minor 0 other 0"
assert_contains "findings by severity: code" "$T" "Code review findings n=3 blocker 1 major 0 minor 2"
assert_contains "judge rulings" "$T" "confirmed 3 downgraded 5 rejected 2"
assert_contains "judge ruling share with n" "$T" "downgraded 5 50% (n=10)"
assert_contains "mutation kill rate" "$T" "40 of 50 mutants caught: 80% (n=50)"
assert_contains "cost per kind/level and per ready verdict" "$T" "code high 5 \$6.00 \$1.20 100% (n=5) \$1.20"
assert_contains "cost per ready: few ready, high cost each" "$T" "code medium 5 \$2.50 \$0.50 20% (n=5) \$2.50"
assert_contains "a share below $((5)) is not enough data" "$T" "suite – 1 \$9.00 \$9.00 not enough data (n=1)"
assert_contains "by repo: finished rounds only, not the queued job" "$T" "app 7 3 not enough data (n=3) 1 4 \$5.10"
assert_contains "the timeline counts the same finished rounds" "$T" "Rounds per day n=11"
assert_contains "weekly trends with 4 weeks" "$T" "Week of Rounds Merged First-pass yield Review cost Rule changes 2026-10-05 1 1 not enough data (n=1) – 0 2026-10-12 1 1 not enough data (n=1) – 0 2026-10-19 2 1 not enough data (n=1) – 0 2026-10-26 7 2 not enough data (n=2) \$11.10 0"
assert_contains "rounds per day" "$T" "2026-10-26 5 2"
assert_contains "queue review cost per day, no suite audits" "$T" "2026-10-27 \$8.60 12"
assert_contains "data note: row counts" "$T" "jobs 13 reviews 18 findings 24"
assert_contains "data note: stays on this machine" "$T" "The data stays on this machine"
assert_contains "transcript tables, no transcripts ingested: empty" "$T" "sessions 0 usage_daily 0"

echo "-- no network, no script"
H="$(cat "$OUT")"
# The icon and the logo are the only images, inlined as data: PNGs; with them blanked out, nothing may link out.
png_re='data:image/png;base64,[A-Za-z0-9+/]*=*'
assert "the icon and the logo are inlined" test "$(grep -oE "$png_re" "$OUT" | wc -l)" -eq 2
while read -r uri; do
  assert "an inlined image decodes to a PNG" test "$(printf '%s' "${uri#*,}" | base64 -d | head -c 4 | tail -c 3)" = PNG
done < <(grep -oE "$png_re" "$OUT")
assert_contains "the icon link inlines icon.png" "$H" \
  "<link rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,$(base64 -w0 "$ROOT/apps/stats/icon.png")\">"
assert_contains "the logo img inlines logo.png" "$H" \
  "<img class=\"logo\" src=\"data:image/png;base64,$(base64 -w0 "$ROOT/apps/stats/logo.png")\" alt=\"\">"
B="$(sed -E "s#$png_re#PNG#g" "$OUT")"
assert_contains "the icon is a data: PNG" "$B" '<link rel="icon" type="image/png" href="PNG">'
assert_contains "the logo is a data: PNG" "$B" '<img class="logo" src="PNG" alt="">'
for bad in "//" "<script" "url(" "@import"; do
  assert_not_contains "no $bad in the page" "$B" "$bad"
done
tags="$(printf '%s' "$B" | grep -o '<[a-zA-Z][^>]*>' | grep -vxF -e '<link rel="icon" type="image/png" href="PNG">' \
  -e '<img class="logo" src="PNG" alt="">')"
assert_not_contains "no other link" "$tags" "<link"
assert_not_contains "no other img" "$tags" "<img"
assert_not_contains "no other tag with a src" "$tags" "src="
assert_not_contains "no other tag with an href" "$tags" "href="
assert_contains "a CSP that allows nothing but inline styles and data: images" "$H" \
  "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'\">"

echo "-- the Refresh button, as a file"
assert_contains "is hidden (no script shows it)" "$H" '<button id="refresh" type="button" hidden>Refresh</button>'
assert_contains "with a note to run raptor-stats" "$T" "Refresh Last ingested: "
assert_contains "the note" "$T" "Opened as a file: run raptor-stats to refresh."
assert_contains "the data note says it talks only to its local server" "$T" \
  "loads nothing from the network. Opened by raptor-stats, it talks only to its own local server (serve.py, on 127.0.0.1), for Refresh."

echo "-- escaping"
assert_contains "a hostile branch name is escaped" "$H" "&lt;script&gt;alert(1)&lt;/script&gt;"
assert_contains "a hostile branch's quote and tag are escaped" "$H" "&quot;&gt;&lt;img src=x onerror=alert(1)&gt;"
assert_contains "the escaped name shows as text" "$T" "<script>alert(1)</script>\"><img src=x onerror=alert(1)>"

echo "-- hints fire"
assert_contains "all hints fire on the fixture" "$(hints "$OUT")" \
  'data-hint="category" data-hint="costly-ready" data-hint="first-pass" data-hint="precision" data-hint="top-reason" '
assert_contains "precision hint, plain language" "$T" "Most blocking findings are downgraded or rejected by the judge (reviewer precision 30% (n=10))"
assert_contains "category hint names the category" "$T" "[mutation] findings keep coming back (6 of 8 findings with a category): add a rule or agent instruction"
assert_contains "costly-ready hint names the level" "$T" "code reviews at high cost \$1.20 on average and mostly say ready (100% (n=5))"
assert_contains "top reason hint advises" "$T" "review_code ends 50% (n=6) of the failed rounds: the code review keeps finding changes"
assert_not_contains "a cheap level that mostly says ready: no hint" "$T" "tests reviews cost"

echo "-- hints at their thresholds don't fire"
OK="$TMP/out/ok.db"; cp "$FX" "$OK"
# precision 6/10 = 60% (not below); mutation 4 of 8 (fewer than 5); high: avg exactly $1.00, ready 3 of 5 (60%);
# first-pass 3/5 = 60%; failures: 2 review_code of 5 (40% is the line: fires).
sql "$OK" "
DELETE FROM jobs WHERE job_id = 'e9';
UPDATE findings SET ruling = 'confirmed' WHERE review_id = 'j1' AND n <= 6;
UPDATE findings SET category = 'missing' WHERE review_id = 't1' AND n IN (5, 6);
UPDATE reviews SET cost_usd = 1.0, verdict = CASE WHEN id IN ('ch1', 'ch2') THEN 'needs changes' ELSE 'ready' END WHERE level = 'high';
UPDATE jobs SET fail_reason = 'e2e' WHERE job_id = 'f5b';
UPDATE jobs SET round = 1 WHERE job_id = 'm3';
UPDATE jobs SET ended = '2026-10-27T10:00:00.000Z' WHERE round IS NOT NULL;"
report --db "$OK" --out "$TMP/out/ok.html" >/dev/null
assert "no hint but top-reason (40% is its line)" test "$(hints "$TMP/out/ok.html")" = 'data-hint="top-reason" '
T2="$(text "$TMP/out/ok.html")"
assert_contains "weekly trends need 4 weeks" "$T2" "not enough data: weekly trends need 4 weeks, there is 1"
sql "$OK" "UPDATE jobs SET fail_reason = 'checks_failed' WHERE job_id = 'f4a';"
report --db "$OK" --out "$TMP/out/ok.html" >/dev/null
assert "below 40%: no top-reason hint" test -z "$(hints "$TMP/out/ok.html")"
assert_contains "no hint: says nothing stands out" "$(text "$TMP/out/ok.html")" "Nothing stands out yet"
cp "$OK" "$TMP/out/ok2.db"
sql "$TMP/out/ok2.db" "UPDATE reviews SET verdict = 'ready' WHERE id = 'ch1';
UPDATE findings SET ruling = 'rejected' WHERE review_id = 'j1' AND n = 6;"
report --db "$TMP/out/ok2.db" --out "$TMP/out/ok2.html" >/dev/null
assert "high at \$1.00 avg, 4 of 5 ready; precision 50%: both fire" test "$(hints "$TMP/out/ok2.html")" = 'data-hint="costly-ready" data-hint="precision" '
cp "$FX" "$TMP/out/few.db"
# 1 of 4 rulings confirmed; code high 3 reviews; judge 5 reviews at \$1.02 on average, 4 ready (not code or tests)
sql "$TMP/out/few.db" "DELETE FROM findings WHERE review_id = 'j1' AND n IN (2, 3, 7, 8, 9, 10);
DELETE FROM reviews WHERE id IN ('ch4', 'ch5');
INSERT INTO reviews (id, kind, verdict, cost_usd) VALUES ('j3', 'judge', 'ready', 1.5), ('j4', 'judge', 'ready', 1.5), ('j5', 'judge', 'ready', 1.5);
DELETE FROM jobs WHERE job_id IN ('m1', 'f6', 'e7');"
report --db "$TMP/out/few.db" --out "$TMP/out/few.html" >/dev/null
T3="$(text "$TMP/out/few.html")"
assert "small n: only the category hint" test "$(hints "$TMP/out/few.html")" = 'data-hint="category" '
assert_contains "small n: precision says not enough data" "$T3" "Reviewer precision not enough data judge-confirmed blocking findings, n=4"
assert_contains "small n: no ruling bar" "$T3" "Judge rulings on blocking findings n=4 not enough data (n=4)"

echo "-- hints at their exact thresholds"
# hint_case <name> <sql>: the empty db plus the rows, rendered; prints its hints
hint_case() { cp "$EMPTY" "$TMP/out/$1.db"; sql "$TMP/out/$1.db" "$2"
  python3 -I -B "$RP" --db "$TMP/out/$1.db" --out "$TMP/out/$1.html" >/dev/null 2>&1; hints "$TMP/out/$1.html"; }
# cat_rows <n mutation> <n other>: test-review findings with a category
cat_rows() { echo "INSERT INTO reviews (id, kind) VALUES ('t', 'tests');
WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < $(($1 + $2)))
INSERT INTO findings (review_id, n, sev_norm, category) SELECT 't', n, 'major', CASE WHEN n <= $1 THEN 'mutation' ELSE 'other-' || n END FROM i;"; }
assert "precision: exactly 5 ruled findings, 1 confirmed, fires" test "$(hint_case prec5 "INSERT INTO reviews (id, kind) VALUES ('j', 'judge');
INSERT INTO findings (review_id, n, sev_norm, ruling) VALUES ('j', 1, 'blocker', 'confirmed'), ('j', 2, 'blocker', 'rejected'),
  ('j', 3, 'blocker', 'rejected'), ('j', 4, 'blocker', 'downgraded'), ('j', 5, 'blocker', 'downgraded');")" = 'data-hint="precision" '
assert "category: exactly 5 findings fires" test "$(hint_case cat5 "$(cat_rows 5 0)")" = 'data-hint="category" '
assert "category: 4 findings doesn't" test -z "$(hint_case cat4 "$(cat_rows 4 0)")"
assert "category: exactly 30% (6 of 20) fires" test "$(hint_case cat30 "$(cat_rows 6 14)")" = 'data-hint="category" '
assert "category: just below 30% (6 of 21) doesn't" test -z "$(hint_case cat29 "$(cat_rows 6 15)")"
# ready_rows <ready of 10> <cost each>: code reviews at level high
ready_rows() { echo "WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 10)
INSERT INTO reviews (id, kind, level, verdict, cost_usd) SELECT 'c' || n, 'code', 'high',
  CASE WHEN n <= $1 THEN 'ready' ELSE 'needs changes' END, $2 FROM i;"; }
assert "costly-ready: exactly 70% ready at \$1.00 fires" test "$(hint_case ready70 "$(ready_rows 7 1.0)")" = 'data-hint="costly-ready" '
assert "costly-ready: 60% ready doesn't" test -z "$(hint_case ready60 "$(ready_rows 6 1.0)")"
assert "costly-ready: 70% ready at \$0.99 doesn't" test -z "$(hint_case ready70c "$(ready_rows 7 0.99)")"
# fp_rows <first-pass of 10>: merged branches, the rest in round 2
fp_rows() { echo "WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 10)
INSERT INTO jobs (job_id, repo, branch, round, ended, outcome) SELECT 'm' || n, 'app', 'b' || n,
  CASE WHEN n <= $1 THEN 1 ELSE 2 END, '2026-10-01T10:00:00.000Z', 'merged' FROM i;"; }
assert "first-pass: exactly 50% doesn't fire" test -z "$(hint_case fp50 "$(fp_rows 5)")"
assert "first-pass: 40% fires" test "$(hint_case fp40 "$(fp_rows 4)")" = 'data-hint="first-pass" '

echo "-- weeks across the new year"
ny_rows() { local d i=0; for d in 2025-12-15 2025-12-22 2025-12-29 2025-12-31 2026-01-01 2026-01-04 2026-01-05; do
  i=$((i + 1)); echo "INSERT INTO jobs (job_id, repo, branch, round, ended, outcome) VALUES ('n$i', 'app', 'b$i', 1, '${d}T12:00:00.000Z', 'merged');"
  done; }
hint_case newyear "$(ny_rows)" >/dev/null
T6="$(text "$TMP/out/newyear.html")"
assert_contains "Monday 29 Dec to Sunday 4 Jan is one week" "$T6" \
  "Week of Rounds Merged First-pass yield Review cost Rule changes 2025-12-15 1 1 not enough data (n=1) – 0 2025-12-22 1 1 not enough data (n=1) – 0 2025-12-29 4 4 not enough data (n=4) – 0 2026-01-05 1 1 not enough data (n=1) – 0"

echo "-- a review group without any cost"
out="$(hint_case nocost "INSERT INTO reviews (id, kind, verdict, cost_usd) VALUES ('j', 'judge', 'ready', NULL);")"
assert "a ready review with no cost: the report is written" test -f "$TMP/out/nocost.html"
assert_contains "its cost per ready is a dash" "$(text "$TMP/out/nocost.html")" "judge – 1 – – not enough data (n=1) –"

echo "-- the transcript views (stats.py's sessions and usage_daily)"
TK="$TMP/out/tokens.db"; cp "$FX" "$TK"
# Rows in stats.py's own sessions and usage_daily tables (role_eff is the rolled-up role the views group by),
# and reviews with a branch, for its views to sum. agent/app: a1, a2 and a1's subagent a3; agent/tool: t1, t2;
# review: r1 and r2 (3 messages without a price); a hostile role: m1 and its subagents m2, m3; judge: j1, j2 with
# messages of no tokens.
sql "$TK" "
INSERT INTO sessions (session_id, role, role_eff, repo, branch, start, parent_session) VALUES
 ('a1', 'agent', 'agent', 'app', 'feat/one', '2026-10-01T10:00:00.000Z', NULL),
 ('a2', 'agent', 'agent', 'app', 'feat/one', '2026-10-02T10:00:00.000Z', NULL),
 ('a3', 'subagent', 'agent', 'app', 'feat/four', '2026-10-20T10:00:00.000Z', 'a1'),
 ('t1', 'agent', 'agent', 'tool', 'feat/x', '2026-10-01T10:00:00.000Z', NULL),
 ('t2', 'agent', 'agent', 'tool', 'feat/x', '2026-10-01T11:00:00.000Z', NULL),
 ('r1', 'review', 'review', 'app', 'feat/one', '2026-10-04T10:00:00.000Z', NULL),
 ('r2', 'review', 'review', 'app', 'feat/one', '2026-10-04T11:00:00.000Z', NULL),
 ('m1', 'main', '<b>main</b>', NULL, 'main', '2026-10-01T09:00:00.000Z', NULL),
 ('m2', 'subagent', '<b>main</b>', NULL, 'main', '2026-10-01T09:10:00.000Z', 'm1'),
 ('m3', 'subagent', '<b>main</b>', NULL, 'main', '2026-10-01T09:20:00.000Z', 'm1'),
 ('j1', 'judge', 'judge', 'app', 'feat/one', '2026-10-04T12:00:00.000Z', NULL),
 ('j2', 'judge', 'judge', 'app', 'feat/one', '2026-10-04T13:00:00.000Z', NULL);
INSERT INTO usage_daily (session_id, model, day, tokens_in, tokens_out, cache_w, cache_w_1h, cache_r, msgs, cost_usd_est) VALUES
 ('a1', 'claude-opus-5-5', '2026-10-01', 600, 1200, 2000, 0, 300000, 60, 6.0),
 ('a2', 'claude-opus-5-5', '2026-10-02', 300, 600, 800, 0, 150000, 30, 4.0),
 ('a3', 'claude-opus-5-5', '2026-10-20', 100, 200, 200, 0, 50000, 10, 2.5),
 ('t1', 'claude-opus-5-5', '2026-10-01', 250, 500, 500, 0, 125000, 25, 3.75),
 ('t2', 'claude-opus-5-5', '2026-10-01', 250, 500, 500, 0, 125000, 25, 3.75),
 ('r1', 'claude-opus-5-5', '2026-10-04', 90, 180, 270, 0, 36000, 37, 1.25),
 ('r2', 'claude-mystery-9', '2026-10-04', 10, 20, 30, 0, 4000, 3, NULL),
 ('m1', 'claude-opus-5-5', '2026-10-01', 4, 8, 12, 0, 1600, 4, 0.25),
 ('m2', 'claude-opus-5-5', '2026-10-01', 3, 6, 9, 0, 1200, 3, 0.15),
 ('m3', 'claude-opus-5-5', '2026-10-01', 3, 6, 9, 0, 1200, 3, 0.10),
 ('j1', '<synthetic>', '2026-10-04', 0, 0, 0, 0, 0, 1, 0.0),
 ('j2', '<synthetic>', '2026-10-04', 0, 0, 0, 0, 0, 1, 0.0);
UPDATE jobs SET branch = '<i>feat/two</i>' WHERE job_id = 'm2';
INSERT INTO reviews (id, repo, branch, kind, verdict, cost_usd, finished) VALUES
 ('rv1', 'app', 'feat/one', 'code', 'ready', 1.0, '2026-10-04T10:00:00.000Z'),
 ('rj1', 'app', 'feat/one', 'judge', 'ready', 0.3, '2026-10-04T12:00:00.000Z'),
 ('rv2', 'app', '<i>feat/two</i>', 'tests', 'ready', 0.5, '2026-10-11T10:00:00.000Z');"
report --db "$TK" --out "$TMP/out/tokens.html" >/dev/null
T4="$(text "$TMP/out/tokens.html")"
assert_contains "est. \$ by role: summed over repos, ranked, each labelled estimate" "$T4" \
  "Estimated \$ by role (estimate) agent \$20.00 est. review \$1.25 est. <b>main</b> \$0.50 est. judge \$0.00 est."
assert_contains "unpriced messages noted" "$T4" "3 messages had no known price and are not in the estimate."
assert_contains "the role table, agent \$ labelled estimate" "$T4" \
  "Est. \$ (estimate) Subagent est. \$ (estimate) Unpriced messages <b>main</b> – 3 2 10 10 20 30 4,000 \$0.50 \$0.25 0 agent app 3 1 100 1,000 2,000 3,000 500K \$12.50 \$2.50 0 agent tool 2 0 50 500 1,000 1,000 250K \$7.50 – 0"
# agent: 750,000 cache reads of 1,500 + 4,000 + 750,000 input tokens; main: 4,000 of 4,040; judge: no input tokens
assert_contains "cache hit rate by role" "$T4" "Cache hit rate by role Cache reads over all input tokens (fresh, cache writes and cache reads). <b>main</b> 99% agent 99% judge 0% review 99%"
assert_contains "cache hit rate table: no rate is a dash" "$T4" "agent 750K 755.5K 99% judge 0 0 – review 40K 40.4K 99%"
# agent: a3's 50,500 of 758,500 tokens, \$2.50 of \$20.00; main: m2 and m3's 2,436 of 4,060, \$0.25 of \$0.50
assert_contains "subagent share" "$T4" "Subagent share Role Sessions Subagent sessions Share of tokens Share of est. \$ (estimate) <b>main</b> 3 2 60% of 4,060 50% of \$0.50 agent 5 1 7% of 758.5K 12% of \$20.00 judge 2 0 – – review 2 0 0% of 40.6K 0% of \$1.25"
assert_contains "cost per merged branch: how many have agent cost" "$T4" "Agent cost found for 2 of 5 merged branches. A session is linked to a branch by its transcript's worktree and branch, by a job file's worktree, or by the job queued within 10 minutes after it ended; the rest can't be linked. Per branch (5)"
assert_contains "cost per merged branch: newest first, agent est. + review + judge" "$T4" \
  "tool feat/five 2026-10-26 0 – – – – app feat/four 2026-10-26 1 \$2.50 – – \$2.50 tool feat/three 2026-10-19 0 – – – – app <i>feat/two</i> 2026-10-12 0 – \$0.50 – \$0.50 app feat/one 2026-10-05 2 \$10.00 \$1.00 \$0.30 \$11.30"
assert_contains "row counts of the new tables" "$T4" "sessions 12 usage_daily 12"
H4="$(cat "$TMP/out/tokens.html")"
assert_contains "a role name is escaped" "$H4" "&lt;b&gt;main&lt;/b&gt;"
assert_contains "a branch name is escaped" "$H4" "&lt;i&gt;feat/two&lt;/i&gt;"
assert_contains "no transcripts ingested: no data yet, but the merged branches are listed" "$(grep -o 'Cost and tokens.*Timeline' <<<"$T")" \
  "Estimated \$ by role (estimate) no data yet Cache hit rate by role no data yet Subagent share no data yet Cost per merged branch Agent cost found for 0 of 5 merged branches"
NV="$TMP/out/noviews.db"; cp "$FX" "$NV"
sql "$NV" "DROP VIEW v_tokens_by_role; DROP VIEW v_cache_hit_rate; DROP VIEW v_subagent_share; DROP VIEW v_cost_per_merged_branch;
DROP TABLE sessions; DROP TABLE usage_daily;"
report --db "$NV" --out "$TMP/out/noviews.html" >/dev/null
T6="$(text "$TMP/out/noviews.html")"
assert_contains "without the views (a db from before them): no data yet, four times" "$(grep -o 'Cost and tokens.*Timeline' <<<"$T6")" \
  "Estimated \$ by role (estimate) no data yet Cache hit rate by role no data yet Subagent share no data yet Cost per merged branch no data yet"
assert_contains "and the transcript tables have no table yet" "$T6" "sessions no table yet usage_daily no table yet"

echo "-- an empty db"
out="$(report --db "$EMPTY" --out "$TMP/out/empty.html")"; rc=$?
assert "renders an empty db" test "$rc" -eq 0
T5="$(text "$TMP/out/empty.html")"
assert_contains "empty: zero merged" "$T5" "Merged branches 0"
assert_contains "empty: not enough data" "$T5" "First-pass yield not enough data"
assert_contains "empty: no data yet" "$T5" "Why rounds failed n=0 no data yet"
assert_contains "empty: hints say nothing" "$T5" "Nothing stands out yet"
: > "$TMP/out/bare.db"
out="$(report --db "$TMP/out/bare.db" --out "$TMP/out/bare.html")"; rc=$?
assert "a db without any table renders too" test "$rc" -eq 0
assert_contains "and says no table yet" "$(text "$TMP/out/bare.html")" "jobs no table yet"
out="$(report --db "$TMP/out/missing.db" --out "$TMP/out/missing.html")"; rc=$?
assert "a missing db: exit 2" test "$rc" -eq 2
assert_contains "says to ingest first" "$out" "run apps/stats/stats.py ingest first"
assert "and writes nothing" test ! -e "$TMP/out/missing.html"
assert "nor makes a db" test ! -e "$TMP/out/missing.db"

echo "-- file mode, atomic, default paths"
assert "report is 0600" test "$(stat -c %a "$OUT")" = 600
chmod 644 "$OUT"; report --db "$FX" --out "$OUT" >/dev/null
assert "rewritten 0600" test "$(stat -c %a "$OUT")" = 600
assert "no temp file left" test -z "$(find "$TMP/out" -name '.report-*')"
SD="$XDG_STATE_HOME/clauderaptor-stats"
mkdir -p "$SD"; chmod 700 "$SD"; cp "$FX" "$SD/stats.db"
out="$(report)"; rc=$?
assert "defaults: exit 0" test "$rc" -eq 0
assert "defaults: report.html next to the default db" test -f "$SD/report.html"
assert_contains "defaults: the default db's numbers" "$(text "$SD/report.html")" "Merged branches 5"
CLAUDERAPTOR_STATS_DIR="$TMP/custom/st" report --db "$FX" >/dev/null
assert "CLAUDERAPTOR_STATS_DIR: report there" test -f "$TMP/custom/st/report.html"
assert "its folder made 0700" test "$(stat -c %a "$TMP/custom/st")" = 700

echo "-- refuses a report inside a git work tree"
git init -q "$TMP/repo"; mkdir -p "$TMP/repo/sub"
out="$(report --db "$FX" --out "$TMP/repo/sub/new/report.html")"; rc=$?
assert "exit 2 inside a repo" test "$rc" -eq 2
assert_contains "says why" "$out" "inside the git work tree $TMP/repo"
assert "nothing made there" test ! -e "$TMP/repo/sub/new"
out="$(CLAUDERAPTOR_STATS_DIR="$TMP/repo/st" report --db "$FX")"; rc=$?
assert "exit 2: a default out path inside a repo" test "$rc" -eq 2
assert "nothing made there either" test ! -e "$TMP/repo/st"

echo "-- --open: an Edge app window"
mkdir -p "$TMP/bin" "$TMP/users/alice/AppData/Local/Microsoft/Edge"
cat > "$TMP/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -w ] || exit 1
p="$2"; printf '%s\n' "\\\\wsl.localhost\\Ubuntu${p//\//\\}"
EOF
cat > "$TMP/bin/msedge.exe" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$EDGE_ARGV.tmp"; mv "$EDGE_ARGV.tmp" "$EDGE_ARGV"
sleep 5
EOF
chmod +x "$TMP/bin/wslpath" "$TMP/bin/msedge.exe"
export EDGE_ARGV="$TMP/edge.argv"
# shellcheck disable=SC2329 # called through assert
wait_argv() { for _ in $(seq 50); do [ -f "$EDGE_ARGV" ] && return 0; sleep 0.1; done; return 1; }
edge() { PATH="$TMP/bin:$PATH" STATS_EDGE="$TMP/bin/msedge.exe" python3 -I -B "$RP" --db "$FX" "$@" 2>&1; }
SP="$TMP/my stats"
t0=$(date +%s%N)
out="$(edge --out "$SP/report.html" --open)"; rc=$?
t1=$(date +%s%N)
assert "exit 0" test "$rc" -eq 0
assert "returns without waiting for Edge (it sleeps 5 s)" test $(((t1 - t0) / 1000000)) -lt 3000
assert_contains "says it opens it" "$out" "opening it in an Edge app window"
assert "Edge started" wait_argv
want="--app=file://wsl.localhost/Ubuntu${TMP}/my%20stats/report.html
--user-data-dir=\\\\wsl.localhost\\Ubuntu${TMP//\//\\}\\users\\alice\\AppData\\Local\\clauderaptor-stats\\edge-profile
--no-first-run
--no-default-browser-check"
got="$(cat "$EDGE_ARGV")"
assert "the exact argv: app URL (escaped), its own profile, the flags" test "$got" = "$want"
[ "$got" = "$want" ] || printf '       got:  %s\n       want: %s\n' "$got" "$want"
assert "the profile folder is made" test -d "$TMP/users/alice/AppData/Local/clauderaptor-stats/edge-profile"
assert "the report is written too" test -f "$SP/report.html"
rm -f "$EDGE_ARGV"
mkdir -p "$TMP/users/bob/AppData/Local/Microsoft/Edge" "$TMP/users/carol/Documents"
out="$(edge --out "$SP/report.html" --open)"; rc=$?
assert "several Windows users with Edge: exit 2" test "$rc" -eq 2
assert_contains "names them and the way out" "$out" "several Windows users have an Edge folder (alice, bob); name yours with --windows-user NAME"
sleep 0.3
assert "and starts no Edge" test ! -e "$EDGE_ARGV"
out="$(edge --out "$SP/report.html" --open --windows-user bob)"; rc=$?
assert "--windows-user picks one" test "$rc" -eq 0
assert "Edge started for bob" wait_argv
assert_contains "with bob's profile" "$(cat "$EDGE_ARGV")" "\\users\\bob\\AppData\\Local\\clauderaptor-stats\\edge-profile"
rm -f "$EDGE_ARGV"
out="$(CLAUDERAPTOR_WINDOWS_USER=alice edge --out "$SP/report.html" --open)"; rc=$?
assert "CLAUDERAPTOR_WINDOWS_USER picks one" test "$rc" -eq 0
assert "Edge started for alice" wait_argv
assert_contains "with alice's profile" "$(cat "$EDGE_ARGV")" "\\users\\alice\\AppData"
rm -f "$EDGE_ARGV"
out="$(edge --out "$SP/report.html" --open --windows-user carol)"; rc=$?
assert "a user without an Edge folder: exit 2" test "$rc" -eq 2
assert_contains "says where it looked" "$out" "no Edge folder at $TMP/users/carol/AppData/Local/Microsoft/Edge"
rm -rf "$TMP/users"/*
out="$(edge --out "$SP/report.html" --open)"; rc=$?
assert "no Windows user with Edge: exit 2" test "$rc" -eq 2
assert_contains "and says to name one" "$out" "cannot find your Windows user"

echo "-- --open outside WSL"
out="$(PATH="$TMP/bin:$PATH" python3 -I -B "$RP" --db "$FX" --out "$TMP/out/nowsl.html" --open 2>&1)"; rc=$?
assert "no msedge.exe: exit 0" test "$rc" -eq 0
assert_contains "prints the report's path" "$out" "report: $TMP/out/nowsl.html"
assert_contains "and a hint" "$out" "open it in a browser"
mkdir -p "$TMP/pyonly"; ln -s "$(command -v python3)" "$TMP/pyonly/python3"
out="$(PATH="$TMP/pyonly" STATS_EDGE="$TMP/bin/msedge.exe" "$TMP/pyonly/python3" -I -B "$RP" --db "$FX" --out "$TMP/out/nowsl.html" --open 2>&1)"; rc=$?
assert "no wslpath: exit 0" test "$rc" -eq 0
assert_contains "says wslpath is missing" "$out" "wslpath not found"
sleep 0.3
assert "and starts no Edge" test ! -e "$EDGE_ARGV"

echo "-- derived metrics: rule changes, escaped defects, flaky CI, last ingest"
DV="$TMP/out/derived.db"; cp "$FX" "$DV"
# The fixture's 5 merged branches on main; a fix/ commit 10 days after feat/one touches its file, one 20 days
# after feat/two touches its file; another file of feat/three. 5 failed check runs, 2 passed later. Two rule
# changes on 2026-10-26 (a day with rounds), one with a hostile subject, and one on a day without rounds.
sql "$DV" "
INSERT INTO main_commits (repo, sha, ts, subject, branch, kind) VALUES
 ('app', 'c1', '2026-10-05T10:00:00.000Z', 's', 'feat/one', 'other'),
 ('app', 'c2', '2026-10-12T10:00:00.000Z', 's', 'feat/two', 'other'),
 ('tool', 'c3', '2026-10-19T10:00:00.000Z', 's', 'feat/three', 'other'),
 ('app', 'c4', '2026-10-26T10:00:00.000Z', 's', 'feat/four', 'other'),
 ('tool', 'c5', '2026-10-26T11:00:00.000Z', 's', 'feat/five', 'other'),
 ('app', 'f1', '2026-10-15T10:00:00.000Z', 'fix: one', 'fix/one', 'fix'),
 ('app', 'f2', '2026-11-01T10:00:00.000Z', 'fix: two', NULL, 'fix'),
 ('tool', 'f3', '2026-10-20T10:00:00.000Z', 'fix: three', NULL, 'fix');
INSERT INTO main_commit_files (repo, sha, path) VALUES ('app', 'c1', 'a.js'), ('app', 'c2', 'b.js'), ('tool', 'c3', 'c.js'),
 ('app', 'f1', 'a.js'), ('app', 'f2', 'b.js'), ('tool', 'f3', 'other.js');
INSERT INTO checks (job_id, repo, branch, sha, queued_sha, ts, result) VALUES
 ('k1', 'app', '<b>flaky</b>', 's1', 'q1', '2026-10-26T10:00:00.000Z', 'fail'),
 ('k2', 'app', '<b>flaky</b>', 's1', 'q1', '2026-10-26T11:00:00.000Z', 'pass'),
 ('k3', 'app', 'feat/x', 's3', 'q3', '2026-10-26T09:30:00.000Z', 'fail'),
 ('k4', 'app', 'feat/x', 's4', 'q3', '2026-10-26T12:00:00.000Z', 'pass'),
 ('k5', 'app', 'feat/y', 's5', 'q5', '2026-10-26T10:00:00.000Z', 'fail'),
 ('k6', 'app', 'feat/z', 's6', 'q6', '2026-10-26T10:00:00.000Z', 'fail'),
 ('k7', 'app', 'feat/w', 's7', 'q7', '2026-10-26T10:00:00.000Z', 'fail');
INSERT INTO rule_changes (repo, sha, ts, subject) VALUES
 ('app', 'abc1234', '2026-10-26T08:00:00.000Z', 'docs: tighten the rules <script>x</script>'),
 ('app', 'def5678', '2026-10-26T09:00:00.000Z', 'chore: agents'),
 ('tool', '0123abc', '2026-10-28T09:00:00.000Z', 'docs: CLAUDE.md'),
 ('app', 'old1234', '2025-10-05T09:00:00.000Z', 'docs: a year earlier');
INSERT OR REPLACE INTO meta (key, value) VALUES ('last_ingest', '2026-11-01T08:30:00.000Z');"
report --db "$DV" --out "$TMP/out/derived.html" >/dev/null
TV="$(text "$TMP/out/derived.html")"; HV="$(cat "$TMP/out/derived.html")"
assert_contains "escaped rate with n: a fix within 14 days on the same files" "$TV" "Escaped defects n=5 Escaped rate: 20% (n=5)"
assert_contains "the escaped branch and its fix" "$TV" "Escaped branches (1) Repo Branch Merged Fixed by app feat/one 2026-10-05 f1"
assert_contains "flaky rate with n" "$TV" "Flaky CI n=5 Flaky rate: 40% (n=5)"
assert_contains "the flaky runs, newest first, the branch escaped" "$TV" "Flaky runs (2) Repo Branch Failed Passed app <b>flaky</b> 2026-10-26 10:00 2026-10-26 11:00 app feat/x 2026-10-26 09:30 2026-10-26 12:00"
assert_contains "a branch name in the flaky table is escaped" "$HV" "&lt;b&gt;flaky&lt;/b&gt;"
assert_contains "a dashed mark on a day with rounds and a rule change" "$HV" '<g class="mark rule"><title>rule change 2026-10-26: app abc1234 docs: tighten the rules &lt;script&gt;x&lt;/script&gt;; app def5678 chore: agents</title><line class="rule-mark"'
assert "one mark: the other change's day has no rounds, the same day a year earlier is another day" test "$(grep -o 'class="rule-mark"' <<<"$HV" | wc -l)" -eq 1
assert_not_contains "a subject is escaped" "$HV" "<script>x"
assert_contains "the rule changes listed" "$TV" "Rule changes n=4 Rule changes (4) Day Repo Commit Subject 2025-10-05 app old1234 docs: a year earlier 2026-10-26 app abc1234 docs: tighten the rules <script>x</script> 2026-10-26 app def5678 chore: agents 2026-10-28 tool 0123abc docs: CLAUDE.md"
assert_contains "the weekly trend counts them" "$TV" "2026-10-26 7 2 not enough data (n=2) \$11.10 3"
assert_contains "last ingested: meta's time, not the file's" "$TV" "Last ingested: 2026-11-01 08:30. Generated"
assert_contains "row counts of the git and checks tables" "$TV" "checks 7 main_commits 8 rule_changes 4"
TE="$(text "$OUT")"
assert_contains "no git rows: not enough data" "$TE" "Escaped defects n=0 Escaped rate: not enough data (n=0)"
assert_contains "no failed checks: not enough data" "$TE" "Flaky CI n=0 Flaky rate: not enough data (n=0)"
assert_not_contains "no rule changes: no marks" "$(cat "$OUT")" 'class="rule-mark"'
OLD="$TMP/out/old-meta.db"; cp "$FX" "$OLD"; sql "$OLD" "DROP TABLE meta;"
touch -d '2026-10-30 07:15' "$OLD"
report --db "$OLD" --out "$TMP/out/old-meta.html" >/dev/null
assert_contains "no meta table: the db file's time, said so" "$(text "$TMP/out/old-meta.html")" "Last ingested: 2026-10-30 07:15 (the db file's time)."

echo "-- file URLs"
py() { python3 -I -B -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", sys.argv[1]); r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
exec(sys.argv[2])' "$RP" "$1" 2>&1; }
assert_contains "a UNC path: host, escaped parts" "$(py 'print(r.file_url("\\\\wsl.localhost\\Ubuntu-24.04\\home\\a b\\x#1%.html"))')" \
  "file://wsl.localhost/Ubuntu-24.04/home/a%20b/x%231%25.html"
assert_contains "a drive path" "$(py 'print(r.file_url("C:\\Users\\a b\\r.html"))')" "file:///C:/Users/a%20b/r.html"

echo "-- a failed write"
cp "$OUT" "$TMP/before.html"
out="$(FX="$FX" OUTF="$OUT" py 'import os
def boom(*a):
    raise OSError("disk full")
r.os.replace = boom
r.main(["--db", os.environ["FX"], "--out", os.environ["OUTF"]])')"; rc=$?
assert "exits non-zero" test "$rc" -ne 0
assert_contains "with the error" "$out" "disk full"
assert "leaves no temp file" test -z "$(find "$TMP/out" -name '.report-*')"
assert "leaves the old report as it was" cmp -s "$OUT" "$TMP/before.html"

echo "-- served_page: the page as serve.py serves it"
N=nonceNONCEnonce1234; K=tokenTOKENtoken-_123456
out="$(N=$N K=$K OUTF="$OUT" py 'import os
print(r.served_page(open(os.environ["OUTF"]).read(), os.environ["N"], os.environ["K"]))')"
assert_contains "the meta CSP gets the nonce and the server" "$out" \
  "content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; script-src 'nonce-$N'; connect-src 'self'\">"
assert_not_contains "and no longer the file's" "$out" "form-action 'none'\">"
assert "one script" test "$(grep -o '<script' <<<"$out" | wc -l)" -eq 1
assert_contains "with the nonce, at the end of the body" "$out" "<script nonce=\"$N\">"
assert_contains "the token in it" "$out" "var T = \"$K\""
assert_contains "the script is last in the body" "$out" "})();</script></body></html>"
assert_contains "still escaped" "$out" "&lt;script&gt;alert(1)&lt;/script&gt;"
for bad in "x\"y-1234567890123456" "short"; do
  assert_contains "refuses a nonce like $bad" "$(B="$bad" OUTF="$OUT" py 'import os
try:
    r.served_page(open(os.environ["OUTF"]).read(), os.environ["B"], "tokenTOKENtoken-_123456")
except ValueError as ex:
    print("ValueError", ex)')" "ValueError"
done
for bad in 'tok"en</script><script>alert(1)//' "short"; do
  assert_contains "refuses a token like $bad" "$(B="$bad" OUTF="$OUT" py 'import os
try:
    print(r.served_page(open(os.environ["OUTF"]).read(), "nonceNONCEnonce1234", os.environ["B"])[-200:])
except ValueError as ex:
    print("ValueError", ex)')" "ValueError a nonce and a token are token_urlsafe strings"
done
assert_contains "refuses a page that is not a report" "$(py 'try:
    r.served_page("<html><body></body></html>", "nonceNONCEnonce1234", "tokenTOKENtoken-_123456")
except ValueError as ex:
    print("ValueError", ex)')" "ValueError not a report page"

echo "-- compact numbers"
assert_contains "in full under 10,000, compact from it" "$(py 'print(" ".join(r.compact(v) for v in (9999, 10000, 12345, 999949, 999950, 1000000, 2500000000, 1.5)))')" \
  "9,999 10K 12.3K 999.9K 1M 1M 2.5B 1.50"

echo "-- no bytecode in the checkout"
assert "no __pycache__ in scripts/" test -z "$(find "$ROOT/scripts" -name __pycache__)"

finish
