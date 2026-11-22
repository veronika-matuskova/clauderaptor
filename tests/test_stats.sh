# shellcheck shell=bash
# Tests for scripts/stats/stats.py ingest: synthetic queue state (events, review files, sidecars, results.log) made in
# the temp dir, ingested into a db there.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

ST="$ROOT/scripts/stats/stats.py"
export TZ=UTC PR_QUEUE_DIR="$TMP/state"
unset REVIEW_DIR STATS_EVENTS_FILE CLAUDERAPTOR_STATS_DIR
export XDG_STATE_HOME="$TMP/xdg" HOME="$TMP/home"
unset CLAUDE_CONFIG_DIR
R="$PR_QUEUE_DIR/reviews"; EV="$PR_QUEUE_DIR/events.jsonl"
mkdir -p "$R" "$PR_QUEUE_DIR/repos/app" "$PR_QUEUE_DIR/repos/tool/failed" "$TMP/out"
DB="$TMP/out/stats.db"

# Transcripts from $PROJ (an empty folder unless a test sets it), never the real ~/.claude.
ingest() { python3 -I -B "$ST" ingest --db "${1:-$DB}" --projects "${PROJ:-$TMP/noprojects}" 2>&1; }
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
out="$(py 'print(" ".join(s.fail_reason(x) for x in ["the test review found changes to make (test review: f)", "the review found changes to make; the test review found changes to make", "the review didn'"'"'t run: x", "git push failed", "checks failed on #1: t", "no checks reported on #5 after 600s", "#4 does not show abc as its head", "the full e2e suite failed", "no local e2e pass recorded for a", "f got commits after the review; queue it again", "worktree /w is gone", "/w is no longer on feat/x", "uncommitted changes in /w", "merging #2 failed", "something new"]))')"
assert_contains "failure texts map to the events' reasons" "$out" \
  "review_tests review_code review_error push checks_failed checks_timeout head e2e no_e2e_pass moved not_ready not_ready not_ready merge other"

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
assert "schema version recorded once" test "$(q "SELECT COUNT(*) || ':' || MAX(version) FROM schema_version")" = "1:4"

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
assert "migrated: version 4" test "$(q "SELECT group_concat(version) FROM schema_version")" = 4
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
  ev2 2026-05-01T11:30:00.000Z merged r3 feat/rp '"pr":1'
  ev2 2026-05-01T12:00:00.000Z escalated e1 feat/esc '"reason":"judge rejected a critical finding"'
  ev2 2026-05-01T12:00:01.000Z job_failed e1 feat/esc '"step":"judge","reason":"judge"'; } > "$S3/events.jsonl"
PR_QUEUE_DIR="$S3" ingest "$DB2" >/dev/null
P="SELECT ifnull(round,'none'), outcome FROM jobs WHERE job_id"
assert_contains "the real rounds are 1 and 2: first" "$(q "$P = 'r1'")" "1|failed"
assert_contains "the replaced job keeps its row, with no round" "$(q "$P = 'r2'")" "none|replaced"
assert_contains "the real rounds are 1 and 2: merged" "$(q "$P = 'r3'")" "2|merged"
assert_contains "rounds to merge leave it out" "$(q "SELECT rounds FROM v_rounds_per_branch")" "2"
F3="$(q "SELECT group_concat(fail_reason || ':' || failures) FROM (SELECT * FROM v_failures_by_reason ORDER BY fail_reason)")"
assert "failure counts leave it out, and count an escalated job" test "$F3" = "judge:1,review_code:1"
unset DB2

echo "-- transcripts: synthetic sessions of each role"
S4="$TMP/state4"; R4="$S4/reviews"; PROJ="$TMP/projects"; DB2="$TMP/out/tokens.db"
mkdir -p "$R4" "$S4/repos/app" "$PROJ/-home-u-code-app" "$PROJ/-home-u-code-other-repos-wrong/s-agent/subagents"
CANARY="CANARY-SECRET-7f3a91"
WT=/home/u/code/app/repos/app-feat-x
# line <ts> [<msg_id> <model> <in> <out> <cache_w> <cache_w_1h> <cache_r>]: a transcript line of session $SID
# with $EP, $CWD and $BR; with a message id, an assistant message with that usage and secret content.
line() {
  if [ $# -eq 1 ]; then
    printf '{"type":"user","sessionId":"%s","timestamp":"%s","entrypoint":"%s","cwd":"%s","gitBranch":"%s","message":{"role":"user","content":"%s prompt"}}\n' \
      "$SID" "$1" "$EP" "$CWD" "$BR" "$CANARY"
  else
    printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","entrypoint":"%s","cwd":"%s","gitBranch":"%s","isSidechain":false,"message":{"id":"%s","model":"%s","role":"assistant","content":[{"type":"text","text":"%s answer"}],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":%s},"service_tier":"standard"}}}\n' \
      "$SID" "$1" "$EP" "$CWD" "$BR" "$2" "$3" "$CANARY" "$4" "$5" "$6" "$8" "$7"
  fi
}
O=claude-opus-5-5
# The agent, in a worktree, though its transcripts' folder name points elsewhere: linked by cwd, not that name.
SID=s-agent EP=sdk-cli CWD="$WT/src" BR=feat/x
{ line 2026-11-10T10:00:00.000Z
  # one message streamed in three chunks that repeat its usage: counted once
  line 2026-11-10T10:00:01.000Z m1 $O 1000000 100000 200000 100000 1000000
  line 2026-11-10T10:00:02.000Z m1 $O 1000000 100000 200000 100000 1000000
  line 2026-11-10T10:00:03.000Z m1 $O 1000000 100000 200000 100000 1000000
  printf '{"type":"session-owner","sessionId":"s-agent","accountUuid":"CANARY-ACCT-1111","organizationUuid":"CANARY-ORG-2222"}\n'
  line 2026-11-10T10:30:00.000Z; } > "$PROJ/-home-u-code-other-repos-wrong/s-agent.jsonl"
SID=s-agent EP=sdk-cli CWD="$WT" BR=feat/x
{ line 2026-11-10T10:05:00.000Z m2 claude-haiku-5-5 1000000 0 0 0 0; } \
  > "$PROJ/-home-u-code-other-repos-wrong/s-agent/subagents/agent-a1.jsonl"
SID=s-review EP=sdk-cli CWD="$WT" BR=feat/x
line 2026-11-10T11:00:00.000Z r1 $O 10 20 30 0 40 > "$PROJ/-home-u-code-app/s-review.jsonl"
SID=s-judge; line 2026-11-10T11:10:00.000Z j1 $O 1 2 3 0 4 > "$PROJ/-home-u-code-app/s-judge.jsonl"
SID=s-suite; line 2026-11-10T11:20:00.000Z u1 $O 1 1 1 0 1 > "$PROJ/-home-u-code-app/s-suite.jsonl"
# A review from before the sidecars: the sdk-cli session in a worktree that ended as it was written.
SID=s-oldrev; { line 2026-11-10T12:00:00.000Z o1 $O 5 5 5 0 5; line 2026-11-10T12:04:00.000Z; } > "$PROJ/-home-u-code-app/s-oldrev.jsonl"
SID=s-main EP=cli CWD=/home/u/code/app BR=main
line 2026-11-10T09:00:00.000Z x1 claude-mystery-9 100 100 0 0 0 > "$PROJ/-home-u-code-app/s-main.jsonl"
SID=s-main2 EP=cli CWD=/home/u/code/app/repos/app BR=main
line 2026-11-10T09:00:00.000Z x2 $O 0 0 0 0 0 > "$PROJ/-home-u-code-app/s-main2.jsonl"
SID=s-cliwt EP=cli CWD="$WT" BR=feat/x; line 2026-11-10T09:00:00.000Z > "$PROJ/-home-u-code-app/s-cliwt.jsonl"
SID=s-tmp EP=sdk-cli CWD=/tmp/x/eval BR=main; line 2026-11-10T09:00:00.000Z > "$PROJ/-home-u-code-app/s-tmp.jsonl"
# A worktree outside repos/, named <repo>-*.
SID=s-side EP=sdk-cli CWD=/home/u/code/app-side BR=feat/z; line 2026-11-10T09:00:00.000Z > "$PROJ/-home-u-code-app/s-side.jsonl"
# A session that moves on: its first cwd and branch count.
SID=s-move EP=sdk-cli CWD="$WT" BR=feat/x
{ line 2026-11-10T09:00:00.000Z; CWD=/tmp/z BR=main EP=cli line 2026-11-10T09:10:00.000Z; } > "$PROJ/-home-u-code-app/s-move.jsonl"
# Subagents: a review's; one of the main session that cd's into a worktree (most of its lines there, in two
# folders, each with fewer lines than another worktree's); one that stays in the main checkout; one whose parent has no transcript.
mkdir -p "$PROJ/-home-u-code-app/s-review/subagents" "$PROJ/-home-u-code-app/s-main/subagents" "$PROJ/-home-u-code-app/s-ghost/subagents"
SID=s-review EP=sdk-cli CWD="$WT" BR=feat/x
line 2026-11-10T11:00:10.000Z r2 $O 100 0 0 0 0 > "$PROJ/-home-u-code-app/s-review/subagents/agent-r2.jsonl"
SID=s-main EP=cli CWD=/home/u/code/app BR=main
SM1="$PROJ/-home-u-code-app/s-main/subagents/agent-m1.jsonl"
{ line 2026-11-10T10:10:00.000Z
  CWD=/home/u/code/app/repos/app-feat-q BR=feat/q line 2026-11-10T10:11:00.000Z
  CWD=/home/u/code/app/repos/app-feat-q BR=feat/q line 2026-11-10T10:11:30.000Z
  CWD="$WT" BR=feat/x line 2026-11-10T10:12:00.000Z m3 $O 1000000 0 0 0 0
  CWD="$WT/src" BR=feat/x line 2026-11-10T10:14:00.000Z
  CWD="$WT" BR=feat/x line 2026-11-10T10:15:00.000Z; } > "$SM1"
line 2026-11-10T10:20:00.000Z m4 $O 0 0 0 0 10 > "$PROJ/-home-u-code-app/s-main/subagents/agent-m2.jsonl"
line 2026-11-10T10:20:00.000Z > "$PROJ/-home-u-code-app/s-ghost/subagents/agent-g.jsonl"
# Only a line still being written: no session yet.
SID=s-partial; line 2026-11-10T09:00:00.000Z | head -c 40 > "$PROJ/-home-u-code-app/s-partial.jsonl"
printf '{"v":1,"kind":"tests","branch":"feat/x","file":"feat-x-abcabcabcabc-tests.md","session_id":"s-review","cost_usd":0.5,"finished":"2026-11-10T11:00:30.000Z"}\n' \
  > "$R4/feat-x-abcabcabcabc-tests.json"
printf '{"v":1,"kind":"judge","branch":"feat/x","file":"feat-x-abcabcabcabc-judge.md","session_id":"s-judge","cost_usd":0.25,"finished":"2026-11-10T11:10:30.000Z"}\n' \
  > "$R4/feat-x-abcabcabcabc-judge.json"
printf '{"v":1,"kind":"suite","file":"app-suite-abcabcabcabc.md","session_id":"s-suite","cost_usd":2,"finished":"2026-11-10T11:20:30.000Z"}\n' \
  > "$R4/app-suite-abcabcabcabc.json"
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
printf '# Review of feat/x at abcabcabcabc (/code-review medium, cost $1.00, 60 s)\nVerdict: ready\n' > "$R4/feat-x-abcabcabcabc-medium.md"
touch -d '2026-11-10 12:04:30' "$R4/feat-x-abcabcabcabc-medium.md"
ev2 2026-11-10T13:00:00.000Z merged mx feat/x '"pr":1' | sed 's/"repo":"one"/"repo":"app"/' > "$S4/events.jsonl"
out="$(PR_QUEUE_DIR="$S4" ingest "$DB2")"; rc=$?
assert "ingest with transcripts exits 0" test "$rc" -eq 0
assert_contains "the summary counts the transcripts" "$out" "17 transcripts read, 11 new messages"
assert_contains "the summary names the model with no price" "$out" "no price for claude-mystery-9"
assert_not_contains "a model with no tokens is not unpriced" "$out" "$O:"

echo "-- transcripts: nothing but the allowlist is stored"
dump="$(python3 -I -B -c 'import sqlite3, sys
print("\n".join(sqlite3.connect(sys.argv[1]).iterdump()))' "$DB2")"
assert_not_contains "no message content" "$dump" "$CANARY"
assert_not_contains "no account or organization id" "$dump" "CANARY-ACCT"
assert_not_contains "no organization id" "$dump" "CANARY-ORG"
assert_not_contains "no cwd path" "$dump" "/home/u/code"
assert_not_contains "no transcript folder name (it is the cwd)" "$dump" "-home-u-code"
assert_contains "the cwd as a hash" "$(q "SELECT cwd_hash FROM sessions WHERE session_id = 's-main'")" \
  "$(printf %s /home/u/code/app | sha256sum | cut -c1-16)"

echo "-- transcripts: roles, repo and branch"
SQ="SELECT role, ifnull(repo,''), ifnull(worktree,''), ifnull(branch,''), ifnull(parent_session,''), msgs FROM sessions WHERE session_id"
assert_contains "sdk-cli in a worktree: agent, linked by cwd and gitBranch" "$(q "$SQ = 's-agent'")" "agent|app|app-feat-x|feat/x||1"
assert_contains "a subagent's file: subagent, linked to its parent" "$(q "$SQ = 's-agent:agent-a1'")" "subagent|app|app-feat-x|feat/x|s-agent|1"
assert_contains "a test review's sidecar session: review" "$(q "$SQ = 's-review'")" "review|app"
assert_contains "a judge's sidecar session: judge" "$(q "$SQ = 's-judge'")" "judge|app"
assert_contains "a suite audit's sidecar session: suite" "$(q "$SQ = 's-suite'")" "suite|app"
assert_contains "no sidecar, ended as a review of its branch was written: review" \
  "$(q "SELECT role, review_id FROM sessions WHERE session_id = 's-oldrev'")" "review|feat-x-abcabcabcabc-medium.md"
assert_contains "cli in the main checkout: main" "$(q "$SQ = 's-main'")" "main|app|app|main"
assert_contains "cli in a main checkout under repos/: main" "$(q "$SQ = 's-main2'")" "main|app|app|main"
assert_contains "cli in a worktree: other" "$(q "$SQ = 's-cliwt'")" "other|app"
assert_contains "sdk-cli in a temp dir: other" "$(q "$SQ = 's-tmp'")" "other|||main"
assert_contains "sdk-cli in a <repo>-* folder outside repos/: agent" "$(q "$SQ = 's-side'")" "agent|app|app-side|feat/z"
assert_contains "the first cwd, branch and entrypoint count" "$(q "$SQ = 's-move'")" "agent|app|app-feat-x|feat/x"
RE="SELECT role, role_eff, ifnull(repo,''), ifnull(worktree,''), ifnull(branch,''), link FROM sessions WHERE session_id"
assert_contains "a review's subagent rolls up into review" "$(q "$RE = 's-review:agent-r2'")" "subagent|review|app|app-feat-x|feat/x|worktree"
assert_contains "a main session's subagent in a worktree: its most frequent worktree and branch, rolled up into agent" \
  "$(q "$RE = 's-main:agent-m1'")" "subagent|agent|app|app-feat-x|feat/x|worktree"
assert_contains "a main session's subagent in the main checkout stays main" "$(q "$RE = 's-main:agent-m2'")" "subagent|main|app|app|main|cwd"
assert_contains "a subagent whose parent has no transcript stays subagent" "$(q "$RE = 's-ghost:agent-g'")" "subagent|subagent|app|app|main|cwd"
assert_contains "an agent's subagent rolls up into agent" "$(q "$RE = 's-agent:agent-a1'")" "subagent|agent|app|app-feat-x|feat/x"
assert_contains "the lines per place of a subagent" "$(q "SELECT group_concat(worktree || ':' || branch || ':' || lines, ',') FROM (SELECT * FROM session_places WHERE session_id = 's-main:agent-m1' ORDER BY worktree, lines)")" \
  "app:main:1,app-feat-q:feat/q:2,app-feat-x:feat/x:1,app-feat-x:feat/x:2"
assert "a file with only a partial line makes no session yet" test "$(q "SELECT COUNT(*) FROM sessions WHERE session_id = 's-partial'")" -eq 0
assert_contains "start and end of a session" "$(q "SELECT start, end, entrypoint FROM sessions WHERE session_id = 's-agent'")" \
  "2026-11-10T10:00:00.000Z|2026-11-10T10:30:00.000Z|sdk-cli"

echo "-- transcripts: usage, dedupe and prices"
U="SELECT model, day, tokens_in, tokens_out, cache_w, cache_w_1h, cache_r, msgs, ifnull(cost_usd_est,'null') FROM usage_daily WHERE session_id"
assert_contains "a message's repeated usage counts once, priced by its parts" "$(q "$U = 's-agent'")" \
  "$O|2026-11-10|1000000|100000|200000|100000|1000000|1|7.5"
assert_contains "a subagent's usage, at its model's price" "$(q "$U = 's-agent:agent-a1'")" "claude-haiku-5-5|2026-11-10|1000000|0|0|0|0|1|0.1"
assert_contains "an unknown model: null cost" "$(q "$U = 's-main'")" "claude-mystery-9|2026-11-10|100|100|0|0|0|1|null"
assert_contains "the prices table, with its source" "$(q "SELECT usd_in, usd_out, usd_cache_w, usd_cache_w_1h, usd_cache_r, source FROM prices WHERE model = '$O'")" "4.0|20.0|5.0|8.0|0.2|Claude API"
out="$(py 'print(s.price_for("claude-opus-5-5", "2026-11-02"), s.price_for("claude-opus-5-5", "2026-11-03"), s.price_for("nope", "2026-12-01"))
s.PRICES.append(("claude-opus-5-5", "2027-01-01", 1, 2, 3, 4, 5))
print(s.price_for("claude-opus-5-5", "2026-12-31")[0], s.price_for("claude-opus-5-5", "2027-01-01")[0], s.price_for("claude-opus-5-5", "2027-06-01")[0])
print(s.cost_est("claude-opus-5-5", "2026-11-02", 1, 0, 0, 0, 0), s.cost_est("x", "2026-11-10", 0, 0, 0, 0, 0))')"
assert_contains "no price before a model's first effective date" "$out" "None (4.0, 20.0, 5.0, 8.0, 0.2) None"
assert_contains "the price in effect on the day" "$out" $'\n4.0 1 1\n'
assert_contains "cost: null without a price, 0 without tokens" "$out" "None 0.0"

echo "-- transcripts: views"
assert_contains "tokens by role: agent, with its subagent and the main session's subagent in a worktree" \
  "$(q "SELECT sessions, subagent_sessions, msgs, tokens_in, tokens_out, tokens_cache_w, tokens_cache_r, cost_usd_est, subagent_cost_usd_est, unpriced_msgs FROM v_tokens_by_role WHERE role = 'agent' AND repo = 'app'")" \
  "3|2|3|3000000|100000|200000|1000000|11.6|4.1|0"
assert "tokens by role: no subagent row once rolled up" test "$(q "SELECT COUNT(*) FROM v_tokens_by_role WHERE role = 'subagent'")" -eq 0
got="$(q "SELECT role, sessions, subagent_sessions, tokens, subagent_tokens, subagent_token_share, subagent_cost_usd_est FROM v_subagent_share WHERE role = 'review'")"
assert_contains "subagent share of a role" "$got" "review|3|1|220|100|0.4545|0.0004"
assert_contains "tokens by role: unpriced messages counted" "$(q "SELECT ifnull(cost_usd_est,'null'), unpriced_msgs FROM v_tokens_by_role WHERE role = 'main'")" "0.0|1"
assert_contains "cache hit rate: cache reads / all input" "$(q "SELECT tokens_cache_r, tokens_input, cache_hit_rate FROM v_cache_hit_rate WHERE role = 'agent'")" \
  "1000000|4200000|0.2381"
assert "cache hit rate: per rolled-up role, no subagent row" \
  test "$(q "SELECT group_concat(role) FROM (SELECT role FROM v_cache_hit_rate ORDER BY role)")" = "agent,judge,main,review,suite"
assert_contains "cost per merged branch: agent and its subagent (est.), review and judge from the review files" \
  "$(q "SELECT repo, branch, job_id, agent_sessions, agent_cost_usd_est, review_cost_usd, judge_cost_usd FROM v_cost_per_merged_branch")" \
  "app|feat/x|mx|3|11.6|1.5|0.25"

# A role whose tokens all come from subagents is still that role in each view.
P5="$TMP/projects5"; mkdir -p "$P5/p/s-boss/subagents"
SID=s-boss EP=cli CWD=/home/u/code/app BR=main; line 2026-11-10T09:00:00.000Z > "$P5/p/s-boss.jsonl"
CWD="$WT" BR=feat/x line 2026-11-10T09:01:00.000Z b1 $O 10 0 0 0 30 > "$P5/p/s-boss/subagents/agent-b.jsonl"
PROJ="$P5" PR_QUEUE_DIR="$S4" ingest "$TMP/out/boss.db" >/dev/null
got="$(DB2="$TMP/out/boss.db" q "SELECT (SELECT group_concat(role) FROM v_tokens_by_role), (SELECT group_concat(role) FROM v_cache_hit_rate), (SELECT group_concat(role) FROM v_subagent_share)")"
assert "only a subagent's tokens: the views name its rolled-up role" test "$got" = "agent|agent|agent"
assert_contains "and its subagent share is all of it" "$(DB2="$TMP/out/boss.db" q "SELECT subagent_token_share, cache_hit_rate FROM v_subagent_share, v_cache_hit_rate")" "1.0|0.75"

echo "-- transcripts: incremental, partial line, reread"
M="$PROJ/-home-u-code-app/s-main.jsonl"
nm() { q "SELECT COUNT(*) FROM usage_msgs WHERE session_id = 's-main'"; }
MK="$(py "print(s.transcript_key('$M'))")"
SID=s-main EP=cli CWD=/home/u/code/app BR=main
line 2026-11-11T09:00:00.000Z x3 $O 1 1 0 0 0 >> "$M"
line 2026-11-11T09:01:00.000Z x4 $O 1 1 0 0 0 | head -c 50 >> "$M"
out="$(PR_QUEUE_DIR="$S4" ingest "$DB2")"
assert "an appended message is read" test "$(nm)" -eq 2
assert_contains "only the new message is new" "$out" "1 new messages"
assert "the offset stops before the partial line" test "$(q "SELECT offset FROM ingest_state WHERE path = '$MK'")" -lt "$(stat -c %s "$M")"
line 2026-11-11T09:01:00.000Z x4 $O 1 1 0 0 0 | tail -c +51 >> "$M"
PR_QUEUE_DIR="$S4" ingest "$DB2" >/dev/null
assert "the completed line is read on the next run" test "$(nm)" -eq 3
assert_contains "and the session's end and days follow" "$(q "SELECT end, (SELECT COUNT(*) FROM usage_daily WHERE session_id = 's-main') FROM sessions WHERE session_id = 's-main'")" "2026-11-11T09:01:00.000Z|2"
SID=s-main EP=sdk-cli CWD=/tmp/q BR=hotfix; line 2026-11-11T08:00:00.000Z >> "$M"
PR_QUEUE_DIR="$S4" ingest "$DB2" >/dev/null
assert_contains "a later run keeps the session's first branch, earliest start and latest end" \
  "$(q "SELECT role, branch, start, end FROM sessions WHERE session_id = 's-main'")" "main|main|2026-11-10T09:00:00.000Z|2026-11-11T09:01:00.000Z"
cp "$M" "$TMP/m.tmp"; mv "$TMP/m.tmp" "$M"
SID=s-main EP=cli CWD="$WT" BR=feat/x; line 2026-11-11T10:00:00.000Z >> "$SM1"
PR_QUEUE_DIR="$S4" ingest "$DB2" >/dev/null
assert "a later run adds to a subagent's lines in a place" \
  test "$(q "SELECT lines FROM session_places WHERE session_id = 's-main:agent-m1' AND worktree = 'app-feat-x' ORDER BY lines DESC LIMIT 1")" -eq 3
cp "$SM1" "$TMP/m.tmp"; mv "$TMP/m.tmp" "$SM1"
out="$(PR_QUEUE_DIR="$S4" ingest "$DB2")"
assert_contains "another inode is read again, its messages not counted twice" "$out" "0 new messages"
assert "the same messages" test "$(nm)" -eq 3
assert "a subagent read again: its places are not counted twice" \
  test "$(q "SELECT SUM(lines) FROM session_places WHERE session_id = 's-main:agent-m1'")" -eq 7
assert "read from the start" test "$(q "SELECT offset FROM ingest_state WHERE path = '$MK'")" -eq "$(stat -c %s "$M")"
SID=s-main EP=cli CWD=/home/u/code/app BR=main; line 2026-11-12T09:00:00.000Z x5 $O 1 1 0 0 0 > "$M"
PR_QUEUE_DIR="$S4" ingest "$DB2" >/dev/null
assert "a shrunk file is read again from the start" test "$(nm)" -eq 4
assert "its offset is the new size" test "$(q "SELECT offset FROM ingest_state WHERE path = '$MK'")" -eq "$(stat -c %s "$M")"
a="$(q "SELECT group_concat(session_id || role || msgs, ',') FROM (SELECT * FROM sessions ORDER BY session_id)")"
PR_QUEUE_DIR="$S4" ingest "$DB2" >/dev/null
assert "a second run changes no session" test "$a" = "$(q "SELECT group_concat(session_id || role || msgs, ',') FROM (SELECT * FROM sessions ORDER BY session_id)")"

echo "-- transcripts: the default folder"
mkdir -p "$HOME/.claude/projects/p"; cp "$PROJ/-home-u-code-app/s-review.jsonl" "$HOME/.claude/projects/p/"
DB3="$TMP/out/default-projects.db"
out="$(PR_QUEUE_DIR="$S4" python3 -I -B "$ST" ingest --db "$DB3" 2>&1)"
assert_contains "\$HOME/.claude/projects without --projects" "$out" "1 transcripts read"
out="$(CLAUDE_CONFIG_DIR="$TMP/nowhere" PR_QUEUE_DIR="$S4" python3 -I -B "$ST" ingest --db "$TMP/out/cfg.db" 2>&1)"
assert_contains "\$CLAUDE_CONFIG_DIR/projects when it is set" "$out" "0 transcripts read"

echo "-- a version 3 db is migrated"
DB3="$TMP/out/v3.db"; cp "$DB2" "$DB3"
python3 -I -B -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("DROP VIEW v_tokens_by_role; DROP VIEW v_cache_hit_rate; DROP VIEW v_cost_per_merged_branch; "
  "DROP TABLE sessions; DROP TABLE session_places; DROP TABLE usage_msgs; DROP TABLE usage_daily; DROP TABLE prices; "
  "DELETE FROM schema_version; INSERT INTO schema_version VALUES (3);")
c.execute("DELETE FROM ingest_state WHERE path LIKE ?", ("transcript:%",))
c.commit()' "$DB3"
PR_QUEUE_DIR="$S4" ingest "$DB3" >/dev/null
DB2="$DB3"
assert "migrated: version 4" test "$(q "SELECT group_concat(version) FROM schema_version")" = 4
assert "migrated: the sessions are read" test "$(q "SELECT COUNT(*) FROM sessions")" -eq 16
assert_contains "migrated: the views work" "$(q "SELECT agent_cost_usd_est FROM v_cost_per_merged_branch")" "11.6"
unset DB2 PROJ

echo "-- no bytecode in the checkout"
# Run as a script and imported (the py helper), stats.py leaves no __pycache__ next to it.
assert "no __pycache__ in scripts/" test -z "$(find "$ROOT/scripts" -name __pycache__)"

finish
