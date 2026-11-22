# shellcheck shell=bash
# Tests for scripts/stats/stats.py ingest: synthetic queue state (events, review files, sidecars, results.log) made in
# the temp dir, ingested into a db there.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

ST="$ROOT/scripts/stats/stats.py"
export TZ=UTC PR_QUEUE_DIR="$TMP/state"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR
export XDG_STATE_HOME="$TMP/xdg"
R="$PR_QUEUE_DIR/reviews"; EV="$PR_QUEUE_DIR/events.jsonl"
mkdir -p "$R" "$PR_QUEUE_DIR/repos/app" "$PR_QUEUE_DIR/repos/tool/failed" "$TMP/out"
DB="$TMP/out/stats.db"

ingest() { python3 -I -B "$ST" ingest --db "${1:-$DB}" 2>&1; }
# q <sql>: the rows, one per line, columns joined by |
q() {
  python3 -I -B -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in r))
c.commit()' "${DB2:-$DB}" "$1"
}
# py <code>: runs code with the stats module imported as s
py() { python3 -I -B -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("s", sys.argv[1]); s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
exec(sys.argv[2])' "$ST" "$1"; }
ev() {  # ev <ts> <event> <job_id> <extra json fields>
  printf '{"v":1,"ts":"%s","event":"%s","repo":"app","branch":"feat/a","job_id":"%s","sha":"abc","pid":1%s}\n' \
    "$1" "$2" "$3" "${4:+,$4}"
}

echo "-- severity map"
out="$(py 'print(" ".join(s.sev_norm(x) for x in ["must-fix", "important", "should-fix", "nit", "Nit", "pre_existing", "critical", None]))')"
assert_contains "must-fix, important, critical -> blocker; should-fix -> major; nit -> minor; else other" "$out" \
  "blocker blocker major minor minor other blocker other"

echo "-- code-review styles"
cat > "$R/feat-a-111111111111-medium-notests.md" <<'EOF'
# Review of feat/a at 111111111111 (/code-review medium, cost $0.56, 87 s)

Some prose about 3 findings. A nit: in passing. A quoted `Verdict: ready` is not the last one.

1. **important**, `src/a.js:10`
   - **Summary:** synthetic.
   1. A sub-step that is not a finding.
2. **nit**: src/b.js:20
**3. important — `lib/c.py:30`**
4. **Severity: nit.** `d.sh:4`
5. **pre_existing**, `e.md:5`
6. **nit (breaks a repo rule)**: `f.md:6`
2. **nit**, `src/b.js:20` repeated in a summary
```
7. **important**, `in/fence.js:1`
```

Verdict: **needs changes**
EOF
cat > "$R/feat-b-222222222222-high.md" <<'EOF'
# Review of feat/b at 222222222222 (/code-review high, cost $1.20, 300 s, opus at high effort)
important, scripts/x.sh:15
Summary: synthetic.
nit, tests/y.sh:8
important, but this line has no path
Verdict: ready
EOF
echo "-- test-review and judge styles"
cat > "$R/feat-a-111111111111-tests.md" <<'EOF'
# Test review of feat/a at 111111111111 (cost $0.86, 183 s)

Mutations: 7 tried, 4 caught, 3 survived

1. [must-fix] [empty] tests/t.js:104: synthetic.
2. [should-fix] [mutation] cfg/r.yml:73-75: synthetic.
3. [should-fix] lib/z.js:9: no category.
   - Mutation: a sub line, not the count.

Verdict: needs changes
EOF
cat > "$R/feat-a-111111111111-judge.md" <<'EOF'
# Judgement of feat/a at 111111111111 (cost $0.26, 271 s)
1. [CONFIRMED important] [code review #1] src/a.js:10: synthetic.
2. [DOWNGRADED minor] [test review #2] cfg/r.yml:73: synthetic.
3. [REJECTED] [code review #3] `lib/c.py:30`: synthetic.
4. [CONFIRMED critical] [test review #1] tests/t.js:104: synthetic.
Verdict: needs changes
Judged reviews: x y
EOF
cat > "$R/app-suite-333333333333.md" <<'EOF'
# Test suite audit of app at 333333333333 (cost $2.00, 900 s)
**Mutations:** 10 tried, 9 caught, 1 survived.
1. [must-fix] [duplicate] t/a.js:1: synthetic.
Counts: 1
EOF
# A code review whose sidecar says it left out the tests, though its name doesn't.
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
printf '# Review of feat/c at 444444444444 (/code-review low, cost $0.10, 5 s)\nVerdict: ready\n' > "$R/feat-c-444444444444-low.md"
printf '{"v":1,"kind":"code","file":"feat-c-444444444444-low.md","tests_skipped":true}\n' > "$R/feat-c-444444444444-low.json"
# The sidecar is authoritative: its numbers replace the header's.
cat > "$R/feat-a-111111111111-tests.json" <<'EOF'
{"v":1,"kind":"tests","branch":"feat/a","sha":"1111111111112222","level":null,"file":"feat-a-111111111111-tests.md",
 "session_id":"sess-1","cost_usd":0.8712,"duration_ms":183500,"num_turns":12,"verdict":"needs changes","exit":1,
 "usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":300,"cache_read_input_tokens":400},
 "finished":"2026-02-01T10:09:30.000Z"}
EOF
touch -d '2026-01-01 09:00:00' "$R"/*.md
# Written after the rounds that ended at 10:00 and 11:00 (the times link a review to the next round of its
# branch); the medium review's round is the one whose results.log line names it, not the one its time gives.
touch -d '2026-01-01 10:30:00' "$R/feat-a-111111111111-judge.md"
touch -d '2026-01-01 11:30:00' "$R/feat-a-111111111111-medium-notests.md"

out="$(ingest)"; rc=$?
assert "ingest exits 0" test "$rc" -eq 0
assert_contains "ingest prints its counts" "$out" "reviews read"

F="SELECT n, sev_raw, sev_norm, ifnull(category,''), ifnull(path,''), ifnull(line,'') FROM findings WHERE review_id"
got="$(q "$F = 'feat-a-111111111111-medium-notests.md' ORDER BY n")"
assert_contains "numbered, bold severity, comma" "$got" "1|important|blocker||src/a.js|10"
assert_contains "colon, path without backticks" "$got" "2|nit|minor||src/b.js|20"
assert_contains "bold number, dash separator" "$got" "3|important|blocker||lib/c.py|30"
assert_contains "Severity: label" "$got" "4|nit|minor||d.sh|4"
assert_contains "other severity kept raw" "$got" "5|pre_existing|other||e.md|5"
assert_contains "a broken rule is category rule" "$got" "6|nit|minor|rule|f.md|6"
assert "a repeated number, sub-steps, prose and fenced lines are no findings" test "$(wc -l <<<"$got")" -eq 6
assert_not_contains "nothing from inside a code fence" "$got" "fence"
got="$(q "$F = 'feat-b-222222222222-high.md' ORDER BY n")"
assert_contains "unnumbered style" "$got" "1|important|blocker||scripts/x.sh|15"
assert_contains "unnumbered style, nit" "$got" "2|nit|minor||tests/y.sh|8"
assert "unnumbered needs a path" test "$(wc -l <<<"$got")" -eq 2
got="$(q "$F = 'feat-a-111111111111-tests.md' ORDER BY n")"
assert_contains "test review: severity and category tags" "$got" "1|must-fix|blocker|empty|tests/t.js|104"
assert_contains "test review: should-fix, a line range" "$got" "2|should-fix|major|mutation|cfg/r.yml|73"
assert_contains "test review: no category" "$got" "3|should-fix|major||lib/z.js|9"
assert "test review: three findings" test "$(wc -l <<<"$got")" -eq 3
got="$(q "SELECT n, ifnull(sev_raw,''), sev_norm, ifnull(category,''), ruling, path, line FROM findings WHERE review_id = 'feat-a-111111111111-judge.md' ORDER BY n")"
assert_contains "judge: confirmed, its severity" "$got" "1|important|blocker||confirmed|src/a.js|10"
assert_contains "judge: downgraded" "$got" "2|minor|other||downgraded|cfg/r.yml|73"
assert_contains "judge: rejected, no severity" "$got" "3||other||rejected|lib/c.py|30"
assert_contains "judge: critical is a blocker" "$got" "4|critical|blocker||confirmed|tests/t.js|104"
assert "reviewers' findings have no ruling" test "$(q "SELECT COUNT(*) FROM findings f JOIN reviews r ON r.id = f.review_id WHERE r.kind != 'judge' AND f.ruling IS NOT NULL")" -eq 0

C="SELECT kind, ifnull(level,''), verdict, cost_usd, duration_s, ifnull(mut_tried,''), ifnull(mut_caught,''), ifnull(mut_survived,'') FROM reviews WHERE id"
assert_contains "code review: header numbers, level, verdict through markdown" \
  "$(q "$C = 'feat-a-111111111111-medium-notests.md'")" "code|medium|needs changes|0.56|87.0|||"
assert_contains "level from the file name and header" "$(q "$C = 'feat-b-222222222222-high.md'")" "code|high|ready|1.2|300.0"
assert_contains "judge kind" "$(q "$C = 'feat-a-111111111111-judge.md'")" "judge||needs changes|0.26|271.0"
assert_contains "suite audit: mutation line in bold" "$(q "$C = 'app-suite-333333333333.md'")" "suite|||2.0|900.0|10|9|1"
assert_contains "suite audit: repo from its name" "$(q "SELECT repo FROM reviews WHERE id = 'app-suite-333333333333.md'")" "app"
got="$(q "SELECT cost_usd, duration_s, num_turns, session_id, tokens_in, tokens_out, tokens_cache_w, tokens_cache_r, sha, mut_tried, mut_caught, mut_survived, sidecar, finished FROM reviews WHERE id = 'feat-a-111111111111-tests.md'")"
assert_contains "sidecar numbers override the .md's" "$got" "0.8712|183.5|12|sess-1|100|200|300|400|1111111111112222|7|4|3|1|2026-02-01T10:09:30.000Z"
assert_contains "without a sidecar: the .md's mtime as finished" \
  "$(q "SELECT sidecar, finished FROM reviews WHERE id = 'feat-b-222222222222-high.md'")" "0|2026-01-01T09:00:00.000Z"

T="SELECT ifnull(tests_skipped, 'null') FROM reviews WHERE id"
assert "tests skipped: from the -notests name" test "$(q "$T = 'feat-a-111111111111-medium-notests.md'")" = 1
assert "tests not skipped: a code review without -notests" test "$(q "$T = 'feat-b-222222222222-high.md'")" = 0
assert "tests skipped: the sidecar's tests_skipped wins" test "$(q "$T = 'feat-c-444444444444-low.md'")" = 1
assert "tests skipped: null for other kinds" test "$(q "$T = 'feat-a-111111111111-tests.md'")" = null
echo "-- file modes and the default db"
assert "db is 0600" test "$(stat -c %a "$DB")" = 600
python3 -I -B "$ST" ingest >/dev/null 2>&1
SD="$XDG_STATE_HOME/clauderaptor-stats"
assert "default db in \$XDG_STATE_HOME/clauderaptor-stats" test -f "$SD/stats.db"
assert "stats dir created 0700" test "$(stat -c %a "$SD")" = 700
assert "default db 0600" test "$(stat -c %a "$SD/stats.db")" = 600
CLAUDERAPTOR_STATS_DIR="$TMP/custom/stats" python3 -I -B "$ST" ingest >/dev/null 2>&1
assert "CLAUDERAPTOR_STATS_DIR wins" test -f "$TMP/custom/stats/stats.db"
assert "custom stats dir 0700" test "$(stat -c %a "$TMP/custom/stats")" = 700

echo "-- refuses a db inside a git work tree"
git init -q "$TMP/repo"; mkdir -p "$TMP/repo/sub"
out="$(ingest "$TMP/repo/sub/new/stats.db")"; rc=$?
assert "exit 2 inside a repo" test "$rc" -eq 2
assert_contains "says why" "$out" "inside the git work tree $TMP/repo"
assert "no db or folder made there" test ! -e "$TMP/repo/sub/new"
git -C "$TMP/repo" commit -q --allow-empty -m i; git -C "$TMP/repo" worktree add -q "$TMP/wt" 2>/dev/null
out="$(ingest "$TMP/wt/stats.db")"; rc=$?
assert "exit 2 inside a linked worktree (.git file)" test "$rc" -eq 2
ln -s "$TMP/repo/sub" "$TMP/link"
out="$(ingest "$TMP/link/stats.db")"; rc=$?
assert "exit 2 through a symlink into a repo" test "$rc" -eq 2
assert "no db through the link" test ! -e "$TMP/repo/sub/stats.db"

echo "-- events: incremental, partial last line, reread"
evs() { q "SELECT COUNT(*) FROM events_raw"; }
{ ev 2026-02-01T10:00:00.000Z job_queued 100-feat-a '"review":"medium","tests":"on","type":"feat"'
  ev 2026-02-01T10:00:01.000Z job_started 100-feat-a
  ev 2026-02-01T10:10:00.000Z review_finished 100-feat-a '"kind":"tests","level":null,"exit":1,"verdict":"needs changes","review_file":"feat-a-111111111111-tests.md"'
  ev 2026-02-01T10:11:00.000Z job_failed 100-feat-a '"step":"review","reason":"review_tests"'; } > "$EV"
ingest >/dev/null
assert "four events" test "$(evs)" -eq 4
ev 2026-02-01T11:00:00.000Z job_queued 200-feat-a '"review":"medium","tests":"on"' >> "$EV"
printf '{"v":1,"ts":"2026-02-01T11:00:01.000Z","event":"job_started","repo":"app","branch":"feat/a","job_id":"200-feat-a"' >> "$EV"
ingest >/dev/null
assert "an appended line is read" test "$(evs)" -eq 5
assert "a partial last line is not" test "$(q "SELECT COUNT(*) FROM events_raw WHERE event = 'job_started'")" -eq 1
off="$(q "SELECT offset FROM ingest_state WHERE path = '$EV'")"
assert "the offset stops before the partial line" test "$off" -lt "$(stat -c %s "$EV")"
printf ',"sha":"abc","pid":1}\n' >> "$EV"
{ ev 2026-02-01T11:20:00.000Z pr_opened 200-feat-a '"pr":7'
  ev 2026-02-01T11:30:00.000Z merged 200-feat-a '"pr":7,"merge_sha":"def"'; } >> "$EV"
ingest >/dev/null
assert "the completed line is read on the next run" test "$(q "SELECT COUNT(*) FROM events_raw WHERE event = 'job_started'")" -eq 2
assert "and the lines after it" test "$(evs)" -eq 8
echo "not json" >> "$EV"; ingest >/dev/null
assert "a bad line is skipped" test "$(evs)" -eq 8
# A new file (another inode) of the same size: read again from the start.
cp "$EV" "$TMP/ev.tmp"; sed -i 's/"pid":1/"pid":2/' "$TMP/ev.tmp"; mv "$TMP/ev.tmp" "$EV"
ingest >/dev/null
assert "another inode is read again from the start" test "$(evs)" -eq 16
# Shorter than the offset (truncated in place): read again from the start.
ev 2026-02-01T12:00:00.000Z job_queued 300-feat-a > "$EV"
ingest >/dev/null
assert "a shrunk file is read again" test "$(q "SELECT COUNT(*) FROM events_raw WHERE json LIKE '%300-feat-a%'")" -eq 1
assert "and its offset is the new size" test "$(q "SELECT offset FROM ingest_state WHERE path = '$EV'")" -eq "$(stat -c %s "$EV")"
STATS_EVENTS_FILE="$TMP/other-events" ingest >/dev/null
assert "STATS_EVENTS_FILE: a missing file is fine" test "$(evs)" -eq 17
{ ev 2026-03-01T10:00:00.000Z escalated 400-feat-a '"reason":"judge rejected a critical finding"'
  ev 2026-03-01T10:00:01.000Z job_failed 400-feat-a '"step":"judge","reason":"judge"'
  ev 2026-03-01T11:00:00.000Z job_queued 500-feat-a '"review":"medium","tests":"on"'
  ev 2026-03-01T11:30:00.000Z job_ready 500-feat-a '"pr":9'
  ev 2026-03-01T12:00:00.000Z job_queued 600-feat-a
  ev 2026-03-01T12:10:00.000Z job_failed 600-feat-a '"step":"review","reason":"review_code","found":["tests","code"]'
  ev 2026-03-01T13:00:00.000Z job_queued 700-feat-a
  ev 2026-03-01T13:10:00.000Z job_failed 700-feat-a '"step":"start","reason":"not_ready"'
  ev 2026-03-01T14:00:00.000Z job_queued 800-feat-a
  ev 2026-03-01T14:10:00.000Z job_failed 800-feat-a '"step":"e2e","reason":"abandoned"'; } >> "$EV"
ingest >/dev/null

echo "-- jobs from events"
J="SELECT repo, branch, round, ifnull(outcome,''), ifnull(fail_reason,''), ifnull(review_level,''), ifnull(tests,''), source FROM jobs WHERE job_id"
assert_contains "failed round 1" "$(q "$J = '100-feat-a'")" "app|feat/a|1|failed|review_tests|medium|on|events"
assert_contains "merged round 2" "$(q "$J = '200-feat-a'")" "app|feat/a|2|merged||medium|on|events"
assert_contains "the view: rounds to merge" "$(q "SELECT repo, branch, rounds FROM v_rounds_per_branch")" "app|feat/a|2"
assert_contains "job times" "$(q "SELECT queued, started, ended FROM jobs WHERE job_id = '100-feat-a'")" \
  "2026-02-01T10:00:00.000Z|2026-02-01T10:00:01.000Z|2026-02-01T10:11:00.000Z"
assert_contains "a review linked to its job by review_finished" \
  "$(q "SELECT job_id, repo, cached FROM reviews WHERE id = 'feat-a-111111111111-tests.md'")" "100-feat-a|app|0"

# (round 2: the job 300-feat-a, queued after the merge, is round 1)
assert_contains "escalated, then failed: escalated" "$(q "$J = '400-feat-a'")" "app|feat/a|2|escalated|judge|"
assert_contains "job_ready: outcome ready, ended" "$(q "SELECT outcome, ended, ifnull(fail_reason,'') FROM jobs WHERE job_id = '500-feat-a'")" "ready|2026-03-01T11:30:00.000Z|"
assert_contains "job_failed's found list, sorted" "$(q "SELECT fail_reason, found FROM jobs WHERE job_id = '600-feat-a'")" "review_code|code,tests"
assert_contains "not_ready kept as the reason" "$(q "SELECT outcome, fail_reason, ifnull(found,'none') FROM jobs WHERE job_id = '700-feat-a'")" "failed|not_ready|none"
assert_contains "abandoned kept as the reason" "$(q "SELECT outcome, fail_reason FROM jobs WHERE job_id = '800-feat-a'")" "failed|abandoned"
echo "-- results.log backfill before the first event of the repo"
cat > "$PR_QUEUE_DIR/repos/app/results.log" <<EOF
2026-01-01 10:00:00 FAILED feat/a: the review found changes to make (review: $R/feat-a-111111111111-medium-notests.md) (log: x)
2026-01-01 11:00:00 FAILED feat/a: merge conflict with origin/main in: a.txt (log: x)
2026-01-01 12:00:00 MERGED feat/a: #5 as abc1234
2026-01-01 12:30:00 FAILED feat/b: the review found changes to make (review: x); the test review found changes to make (test review: y) (log: x)
2026-01-01 13:00:00 FAILED feat/b: needs your decision: the judge rejected a finding (judge: $R/x-judge.md) (log: x)
2026-01-01 14:00:00 READY feat/b: #6 passed, left open (PR_QUEUE_MERGE=0)
2026-02-01 10:11:00 FAILED feat/a: covered by the events (log: x)
garbage line
EOF
# The old single queue's results.log: its repo comes from the job files.
printf 'worktree=/x/tool-wt\nbranch=feat/t\n' > "$PR_QUEUE_DIR/repos/tool/failed/1-feat-t.job"
# A job of the old queue whose worktree is gone: the repo whose name its folder starts with.
mkdir -p "$PR_QUEUE_DIR/legacy/done"; printf 'worktree=/gone/app-legacy\nbranch=feat/l\n' > "$PR_QUEUE_DIR/legacy/done/2-feat-l.job"
cat > "$PR_QUEUE_DIR/results.log" <<'EOF'
2026-01-01 08:00:00 FAILED feat/t: checks still pending on #3 after 3600s: test (log: x)
2026-01-01 08:30:00 MERGED feat/t: #3 as 1234567
2026-01-01 08:40:00 MERGED feat/l: #4 as 7654321
EOF
ingest >/dev/null
B="SELECT branch, round, outcome, ifnull(fail_reason,''), ended, ifnull(found,'') FROM jobs WHERE source = 'results' AND repo"
got="$(q "$B = 'app' ORDER BY ended")"
assert_contains "backfill: review_code reason" "$got" "feat/a|1|failed|review_code|2026-01-01T10:00:00.000Z|code"
assert_contains "backfill: conflict reason, nothing found" "$got" "feat/a|2|failed|conflict|2026-01-01T11:00:00.000Z|"
assert_contains "backfill: both reviews found changes" "$got" "feat/b|1|failed|review_code|2026-01-01T12:30:00.000Z|code,tests"
assert_contains "backfill: merged in round 3" "$got" "feat/a|3|merged||2026-01-01T12:00:00.000Z"
assert_contains "backfill: needs your decision is escalated" "$got" "feat/b|2|escalated|judge|"
assert_contains "backfill: READY" "$got" "feat/b|3|ready||"
assert "lines from the period with events are left out" test "$(q "SELECT COUNT(*) FROM jobs WHERE source = 'results' AND ended >= '2026-02'")" -eq 0
assert "the lines before it are all in" test "$(q "SELECT COUNT(*) FROM jobs WHERE source = 'results'")" -eq 9
assert_contains "after a merge, the branch's next round is 1 again" "$(q "$J = '100-feat-a'")" "app|feat/a|1|failed"
assert_contains "old results.log: repo from the job files" "$(q "$B = 'tool' ORDER BY ended")" "feat/t|1|failed|checks_timeout|"
assert_contains "old results.log: repo from a gone worktree's folder name" "$(q "SELECT repo FROM jobs WHERE branch = 'feat/l'")" "app"
assert_contains "a review is linked to the next round of its branch after it" \
  "$(q "SELECT j.fail_reason FROM reviews r JOIN jobs j ON j.job_id = r.job_id WHERE r.id = 'feat-a-111111111111-judge.md'")" "conflict"
assert_contains "results.log times are local" "$(TZ=Europe/Prague py 'print(s.local_ts("2026-01-01 10:00:00"))')" "2026-01-01T09:00:00.000Z"
assert_contains "a review named in a FAILED line is linked to that round" \
  "$(q "SELECT r.repo, j.fail_reason FROM reviews r JOIN jobs j ON j.job_id = r.job_id WHERE r.id = 'feat-a-111111111111-medium-notests.md'")" "app|review_code"
out="$(py 'print(" ".join(s.fail_reason(x) for x in ["the test review found changes to make (test review: f)", "the review found changes to make; the test review found changes to make", "the review didn'"'"'t run: x", "git push failed", "checks failed on #1: t", "#4 does not show abc as its head", "the full e2e suite failed", "no local e2e pass recorded for a", "f got commits after the review; queue it again", "worktree /w is gone", "/w is no longer on feat/x", "uncommitted changes in /w", "merging #2 failed", "something new"]))')"
assert_contains "failure texts map to the events' reasons" "$out" \
  "review_tests review_code review_error push checks_failed head e2e no_e2e_pass moved not_ready not_ready not_ready merge other"

echo "-- idempotent"
snap() { q "SELECT (SELECT COUNT(*) FROM events_raw), (SELECT COUNT(*) FROM jobs), (SELECT COUNT(*) FROM reviews), (SELECT COUNT(*) FROM findings), (SELECT group_concat(job_id || round || ifnull(outcome,''), ',') FROM (SELECT * FROM jobs ORDER BY job_id)), (SELECT group_concat(id || ifnull(job_id,'') || ifnull(cost_usd,''), ',') FROM (SELECT * FROM reviews ORDER BY id))"; }
a="$(snap)"; ingest >/dev/null; b="$(snap)"
assert "a second run changes nothing" test "$a" = "$b"
q "DELETE FROM ingest_state WHERE path NOT LIKE '%events%'" >/dev/null; ingest >/dev/null; c="$(snap)"
assert "reading every review file again changes nothing" test "$a" = "$c"
DB2="$TMP/out/fresh.db"; ingest "$DB2" >/dev/null; ingest "$DB2" >/dev/null
d="$(snap)"; unset DB2
assert "a fresh db has the same reviews and findings" test "$(cut -d'|' -f3-4 <<<"$d")" = "$(cut -d'|' -f3-4 <<<"$a")"
# A review file that changes is read again, its findings replaced.
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
printf '# Review of feat/b at 222222222222 (/code-review high, cost $1.30, 10 s)\nVerdict: ready\n' > "$R/feat-b-222222222222-high.md"
ingest >/dev/null
assert "a changed review is read again" test "$(q "SELECT cost_usd FROM reviews WHERE id = 'feat-b-222222222222-high.md'")" = 1.3
assert "its old findings are gone" test "$(q "SELECT COUNT(*) FROM findings WHERE review_id = 'feat-b-222222222222-high.md'")" -eq 0

echo "-- views"
assert_contains "findings by severity" "$(q "SELECT kind, sev_norm, findings FROM v_findings_by_severity WHERE kind = 'tests' AND sev_norm = 'major'")" "tests|major|2"
assert "findings by severity: code and test reviews only" test "$(q "SELECT group_concat(DISTINCT kind) FROM v_findings_by_severity")" = "code,tests"
got="$(q "SELECT ruling, findings, share, reviewer_precision FROM v_judge_rulings ORDER BY ruling")"
assert_contains "judge rulings: confirmed" "$got" "confirmed|2|0.5|0.5"
assert_contains "judge rulings: downgraded" "$got" "downgraded|1|0.25|0.5"
assert_contains "judge rulings: rejected" "$got" "rejected|1|0.25|0.5"
assert_contains "cost by kind and level" "$(q "SELECT kind, level, reviews, cost_usd FROM v_cost_by_kind_level WHERE kind = 'code' AND level = 'high'")" "code|high|1|1.3"
assert "schema version recorded once" test "$(q "SELECT COUNT(*) || ':' || MAX(version) FROM schema_version")" = "1:3"

echo "-- a version 1 db is migrated"
DB2="$TMP/out/v1.db"
python3 -I -B -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE schema_version (version INTEGER NOT NULL); INSERT INTO schema_version VALUES (1);
CREATE TABLE reviews (id TEXT PRIMARY KEY, job_id TEXT, repo TEXT, branch TEXT, kind TEXT, level TEXT, sha TEXT,
  verdict TEXT, cost_usd REAL, duration_s REAL, num_turns INTEGER, session_id TEXT, tokens_in INTEGER,
  tokens_out INTEGER, tokens_cache_w INTEGER, tokens_cache_r INTEGER, mut_tried INTEGER, mut_caught INTEGER,
  mut_survived INTEGER, cached INTEGER, finished TEXT, sidecar INTEGER);
CREATE TABLE findings (review_id TEXT NOT NULL, n INTEGER NOT NULL, sev_norm TEXT, sev_raw TEXT, category TEXT,
  path TEXT, line INTEGER, PRIMARY KEY (review_id, n));
CREATE TABLE ingest_state (path TEXT PRIMARY KEY, inode INTEGER, size INTEGER, offset INTEGER, mtime REAL);
CREATE TABLE jobs (job_id TEXT PRIMARY KEY, repo TEXT, branch TEXT, round INTEGER, queued TEXT, started TEXT,
  ended TEXT, outcome TEXT, fail_reason TEXT, review_level TEXT, tests TEXT, source TEXT);
CREATE VIEW v_findings_by_severity AS SELECT 1 AS old;
""")
d = sqlite3.connect(sys.argv[2])
c.executemany("INSERT INTO ingest_state VALUES (?, ?, ?, ?, ?)", d.execute("SELECT * FROM ingest_state"))
c.commit()' "$DB2" "$DB"
ingest "$DB2" >/dev/null
assert "migrated: version 3" test "$(q "SELECT group_concat(version) FROM schema_version")" = 3
assert "migrated: jobs.found added and filled" test "$(q "SELECT COUNT(*) FROM jobs WHERE found = 'code,tests'")" -eq 1
assert "migrated: review files read again, rulings filled" test "$(q "SELECT COUNT(*) FROM findings WHERE ruling = 'confirmed'")" -eq 2
assert "migrated: tests_skipped filled" test "$(q "SELECT tests_skipped FROM reviews WHERE id = 'feat-c-444444444444-low.md'")" = 1
assert "migrated: the views are the new ones" test "$(q "SELECT group_concat(DISTINCT kind) FROM v_findings_by_severity")" = "code,tests"
unset DB2

echo "-- linking reviews to jobs, sidecar-only reviews, a branch in two repos"
S2="$TMP/state2"; R2="$S2/reviews"; DB2="$TMP/out/links.db"
mkdir -p "$R2" "$S2/repos/one/failed" "$S2/repos/two/failed"
ev2() {  # ev2 <ts> <event> <job_id> <branch> <extra json fields>
  printf '{"v":1,"ts":"%s","event":"%s","repo":"one","branch":"%s","job_id":"%s","sha":"abc","pid":1%s}\n' \
    "$1" "$2" "$4" "$3" "${5:+,$5}"
}
# feat/r's test review ran in j100 and failed, ran again in j200 (which wrote the file), and j300 got it cached.
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
printf '# Test review of feat/r at aaaaaaaaaaaa (cost $0.50, 60 s)\nVerdict: ready\n' > "$R2/feat-r-aaaaaaaaaaaa-tests.md"
printf '{"v":1,"kind":"tests","file":"feat-r-aaaaaaaaaaaa-tests.md","cost_usd":0.5,"finished":"2026-04-01T11:04:59.000Z"}\n' \
  > "$R2/feat-r-aaaaaaaaaaaa-tests.json"
F2='"kind":"tests","review_file":"feat-r-aaaaaaaaaaaa-tests.md"'
# feat/s's review, written at 10:45: j-late started after it (10:50) and ended first, j-cover started before it.
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
printf '# Review of feat/s at bbbbbbbbbbbb (/code-review medium, cost $0.20, 30 s)\nVerdict: ready\n' > "$R2/feat-s-bbbbbbbbbbbb-medium.md"
touch -d '2026-04-01 10:45:00' "$R2/feat-s-bbbbbbbbbbbb-medium.md"
{ ev2 2026-04-01T10:00:00.000Z job_started j100 feat/r
  ev2 2026-04-01T10:30:00.000Z review_finished j100 feat/r "$F2"
  ev2 2026-04-01T11:00:00.000Z job_started j200 feat/r
  ev2 2026-04-01T11:05:00.000Z review_finished j200 feat/r "$F2"
  ev2 2026-04-01T12:00:00.000Z review_finished j300 feat/r "$F2"
  ev2 2026-04-01T10:30:00.000Z job_started j-cover feat/s
  ev2 2026-04-01T11:00:00.000Z job_failed j-cover feat/s '"reason":"review_code"'
  ev2 2026-04-01T10:50:00.000Z job_started j-late feat/s
  ev2 2026-04-01T10:55:00.000Z job_failed j-late feat/s '"reason":"review_code"'; } > "$S2/events.jsonl"
# A review with only its sidecar (no .md).
printf '{"v":1,"kind":"code","branch":"feat/q","level":"low","file":"feat-q-cccccccccccc-low.md","cost_usd":0.33}\n' \
  > "$R2/feat-q-cccccccccccc-low.json"
# feat/dup has job files in two repos, so its old results.log line can't name one.
printf 'worktree=/x/one-wt\nbranch=feat/dup\n' > "$S2/repos/one/failed/1-feat-dup.job"
printf 'worktree=/x/two-wt\nbranch=feat/dup\n' > "$S2/repos/two/failed/2-feat-dup.job"
printf 'worktree=/x/one-wt2\nbranch=feat/solo\n' > "$S2/repos/one/failed/3-feat-solo.job"
printf '2026-01-01 10:00:00 FAILED feat/dup: git fetch failed (log: x)\n2026-01-01 10:05:00 FAILED feat/solo: git fetch failed (log: x)\n' \
  > "$S2/results.log"
PR_QUEUE_DIR="$S2" ingest "$DB2" >/dev/null
L="SELECT ifnull(job_id,''), ifnull(cached,'') FROM reviews WHERE id"
assert_contains "a review run again: linked to the run that wrote the file" "$(q "$L = 'feat-r-aaaaaaaaaaaa-tests.md'")" "j200|"
assert_contains "a review_finished > 120 s after it is a cache hit" "$(q "$L = 'feat-r-aaaaaaaaaaaa-tests.md'")" "|1"
assert_contains "by time: the job that covers the review, not one started after it" \
  "$(q "$L = 'feat-s-bbbbbbbbbbbb-medium.md'")" "j-cover|"
assert_contains "a review with only a sidecar is stored" \
  "$(q "SELECT kind, level, branch, cost_usd, sidecar FROM reviews WHERE id = 'feat-q-cccccccccccc-low.md'")" "code|low|feat/q|0.33|1"
assert_contains "a branch in two repos' job files: no repo" "$(q "SELECT ifnull(repo,'none') FROM jobs WHERE branch = 'feat/dup'")" "none"
assert_contains "a branch in one repo's job files: that repo" "$(q "SELECT ifnull(repo,'none') FROM jobs WHERE branch = 'feat/solo'")" "one"
unset DB2

echo "-- a job replaced in the queue is no round"
S3="$TMP/state3"; mkdir -p "$S3/reviews"; DB2="$TMP/out/replaced.db"
{ ev2 2026-05-01T10:00:00.000Z job_queued r1 feat/rp
  ev2 2026-05-01T10:10:00.000Z job_failed r1 feat/rp '"step":"review","reason":"review_code"'
  ev2 2026-05-01T11:00:00.000Z job_queued r2 feat/rp
  ev2 2026-05-01T11:05:00.000Z job_failed r2 feat/rp '"step":"queue","reason":"replaced"'
  ev2 2026-05-01T11:06:00.000Z job_queued r3 feat/rp
  ev2 2026-05-01T11:30:00.000Z merged r3 feat/rp '"pr":1'; } > "$S3/events.jsonl"
PR_QUEUE_DIR="$S3" ingest "$DB2" >/dev/null
P="SELECT ifnull(round,'none'), outcome FROM jobs WHERE job_id"
assert_contains "the real rounds are 1 and 2: first" "$(q "$P = 'r1'")" "1|failed"
assert_contains "the replaced job keeps its row, with no round" "$(q "$P = 'r2'")" "none|replaced"
assert_contains "the real rounds are 1 and 2: merged" "$(q "$P = 'r3'")" "2|merged"
assert_contains "rounds to merge leave it out" "$(q "SELECT rounds FROM v_rounds_per_branch")" "2"
assert "failure counts leave it out" test "$(q "SELECT group_concat(fail_reason || ':' || failures) FROM v_failures_by_reason")" = "review_code:1"
unset DB2

echo "-- no bytecode in the checkout"
# Run as a script and imported (the py helper), stats.py leaves no __pycache__ next to it.
assert "no __pycache__ in scripts/" test -z "$(find "$ROOT/scripts" -name __pycache__)"

finish
