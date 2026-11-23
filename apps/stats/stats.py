#!/usr/bin/env python3
"""Local-only stats of the PR queue: how many rounds a branch takes, what reviews cost, what they find.

  stats.py ingest [--db PATH] [--projects DIR]   reads the queue's state and Claude Code's transcripts into a SQLite db

The db (default $CLAUDERAPTOR_STATS_DIR/stats.db, else ${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/stats.db)
stays on this machine: stats.py refuses (exit 2) to write it into a git work tree. Its folder is created 0700,
the db 0600.
Sources, all in $PR_QUEUE_DIR (default ${XDG_STATE_HOME:-~/.local/state}/pr-queue):
- events.jsonl (or $STATS_EVENTS_FILE), written by pr-queue.sh: read incrementally, from where the last run
  stopped. A last line without its newline is left for the next run; a new file (another inode) or a shorter
  one is read again from the start.
- the review files in $REVIEW_DIR (default reviews/): the numbers in each .md's header, its findings (number,
  severity, category, file and line, and a judge's ruling: confirmed, downgraded or rejected, with the review
  it rules on in findings.source: code for "[code review #N]", tests for "[test review #N]"; never their
  text), the mutation line and the verdict; the sidecar .json next to it, when there is one, has the
  authoritative numbers (and tests_skipped, else the -notests in a code review's name).
- the brief sidecars in $BRIEF_DIR (default briefs/), written by review.sh --plan: only their session id, which
  makes that session a planner. Briefs are not reviews: they stay out of the reviews table and its costs.
- results.log files (repos/*/results.log and the old single queue's): FAILED, MERGED and READY lines fill in
  the rounds of the time before a repo had events.
- Claude Code's transcripts in --projects DIR (default ${CLAUDE_CONFIG_DIR:-~/.claude}/projects): */*.jsonl, one
  session each, and */<session>/subagents/*.jsonl, its subagents. Read incrementally like events.jsonl. Only an
  allowlist of fields is read, and nothing else is stored: message.id, message.model, the token counts in
  message.usage, timestamp, entrypoint, gitBranch and cwd (stored only as a hash, plus the folder name the
  repo and worktree come from); the session id is the file's name. Never the messages' content, nor the
  account or organization ids.
  Streamed chunks repeat a message's usage: each message.id counts once.
- git, in each repo's main checkout (repos/<repo>/checkout): main's first-parent commits (sha, time, subject,
  the files changed, and the queue branch it merged, if known), and the commits that touched the rules
  (claude/rules/**, CLAUDE.md, scripts/queue/review.sh, claude/agents/**). Read again on every run.
- milestones.json, next to this script (or $STATS_MILESTONES_FILE, for tests): the milestones, moments that split
  the stats into before and after (report.py's "Before and after"). A JSON list of {"name": ..., "repo": ...,
  "commit": ...}; to add one, append an entry once its commit is on the repo's main. Read again on every run
  into milestones (name, repo, sha, ts): ts is that commit's time on main (main_commits), NULL while it isn't on
  main yet. A missing file means no milestones; a file that doesn't parse, or an entry without a name, repo or
  commit, is skipped with a "stats: milestones: ..." warning, and the rest of the ingest goes on.
meta's last_ingest is the time of the last ingest.
Ingesting the same files again changes nothing. A db of an older schema version gets the new columns, and its
review files are read again to fill them.
Views: v_rounds_per_branch, v_findings_by_severity (code and test reviews only), v_cost_by_kind_level,
v_failures_by_reason (failed and escalated rounds; a job replaced in the queue never ran, so it is no round)
and v_judge_rulings (reviewer_precision: the share of the blocking findings it judged that the judge confirmed).
From the transcripts: v_tokens_by_role (tokens and the estimated API-equivalent cost per role and repo),
v_subagent_share (the subagents' part of each role), v_cache_hit_rate (cache reads / all input tokens, per role)
and v_cost_per_merged_branch (the agents' estimated cost, from the transcripts, and the reviews' and judges'
cost, from the review files, per merged branch). These count a subagent toward its parent's role.
v_escaped_defects: each branch the queue merged, and the fix or revert within 14 days that touched its files.
v_flaky_checks: each failed CI check run, and when checks passed with no new commits (from the events).
Session roles: code review, test review, judge or suite for a session a review sidecar names; planner for a
session a brief sidecar names; subagent for a subagent's file
(sessions.role_eff rolls it up into its parent's role, and a subagent of the main session that worked in a
worktree into agent); for an sdk-cli session in a worktree without a sidecar, the review's kind if a review of
its branch without a sidecar was written within 5 minutes after the session ended (the reviews from before the
sidecars), else agent; main for a cli session in a checkout; other for anything else (cli in a worktree, a
session in a temp dir). A subagent's repo and branch are those of the worktree it spent the most lines in.
Sessions whose branch was never queued get one from the job files (see link_to_jobs): branch_eff, used by
v_cost_per_merged_branch.
"""
import argparse
import calendar
import datetime
import glob
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

SCHEMA_VERSION = 6

SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events_raw (hash TEXT PRIMARY KEY, ts TEXT, event TEXT, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (
  job_id TEXT PRIMARY KEY, repo TEXT, branch TEXT, round INTEGER, queued TEXT, started TEXT, ended TEXT,
  outcome TEXT, fail_reason TEXT, review_level TEXT, tests TEXT, source TEXT, found TEXT);
CREATE TABLE IF NOT EXISTS reviews (
  id TEXT PRIMARY KEY, job_id TEXT, repo TEXT, branch TEXT, kind TEXT, level TEXT, sha TEXT, verdict TEXT,
  cost_usd REAL, duration_s REAL, num_turns INTEGER, session_id TEXT,
  tokens_in INTEGER, tokens_out INTEGER, tokens_cache_w INTEGER, tokens_cache_r INTEGER,
  mut_tried INTEGER, mut_caught INTEGER, mut_survived INTEGER, cached INTEGER, finished TEXT, sidecar INTEGER,
  tests_skipped INTEGER);
CREATE TABLE IF NOT EXISTS findings (
  review_id TEXT NOT NULL, n INTEGER NOT NULL, sev_norm TEXT, sev_raw TEXT, category TEXT, path TEXT, line INTEGER,
  ruling TEXT, source TEXT, PRIMARY KEY (review_id, n));
CREATE TABLE IF NOT EXISTS ingest_state (path TEXT PRIMARY KEY, inode INTEGER, size INTEGER, offset INTEGER, mtime REAL);
CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY, role TEXT, repo TEXT, worktree TEXT, branch TEXT, cwd_hash TEXT, place TEXT,
  entrypoint TEXT, start TEXT, end TEXT, msgs INTEGER, parent_session TEXT, review_id TEXT, role_eff TEXT,
  link TEXT, branch_eff TEXT);
CREATE TABLE IF NOT EXISTS session_places (
  session_id TEXT NOT NULL, cwd_hash TEXT NOT NULL, branch TEXT NOT NULL, worktree TEXT, place TEXT, lines INTEGER,
  PRIMARY KEY (session_id, cwd_hash, branch));
CREATE TABLE IF NOT EXISTS usage_msgs (
  msg_id TEXT PRIMARY KEY, session_id TEXT, model TEXT, day TEXT,
  tokens_in INTEGER, tokens_out INTEGER, cache_w INTEGER, cache_w_1h INTEGER, cache_r INTEGER);
CREATE TABLE IF NOT EXISTS usage_daily (
  session_id TEXT NOT NULL, model TEXT NOT NULL, day TEXT NOT NULL, tokens_in INTEGER, tokens_out INTEGER,
  cache_w INTEGER, cache_w_1h INTEGER, cache_r INTEGER, msgs INTEGER, cost_usd_est REAL,
  PRIMARY KEY (session_id, model, day));
CREATE TABLE IF NOT EXISTS prices (
  model TEXT NOT NULL, effective_from TEXT NOT NULL, usd_in REAL, usd_out REAL, usd_cache_w REAL,
  usd_cache_w_1h REAL, usd_cache_r REAL, source TEXT, PRIMARY KEY (model, effective_from));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS checks (
  job_id TEXT, repo TEXT, branch TEXT, sha TEXT, queued_sha TEXT, ts TEXT, result TEXT);
CREATE TABLE IF NOT EXISTS main_commits (
  repo TEXT NOT NULL, sha TEXT NOT NULL, ts TEXT, subject TEXT, branch TEXT, kind TEXT, PRIMARY KEY (repo, sha));
CREATE TABLE IF NOT EXISTS main_commit_files (repo TEXT NOT NULL, sha TEXT NOT NULL, path TEXT NOT NULL,
  PRIMARY KEY (repo, sha, path));
CREATE TABLE IF NOT EXISTS rule_changes (
  repo TEXT NOT NULL, sha TEXT NOT NULL, ts TEXT, subject TEXT, PRIMARY KEY (repo, sha));
CREATE TABLE IF NOT EXISTS milestones (name TEXT NOT NULL, repo TEXT NOT NULL, sha TEXT NOT NULL, ts TEXT);
"""

# Dropped and made again on every run, so that a new version's views replace an old db's.
VIEWS = """
DROP VIEW IF EXISTS v_rounds_per_branch;
DROP VIEW IF EXISTS v_findings_by_severity;
DROP VIEW IF EXISTS v_cost_by_kind_level;
DROP VIEW IF EXISTS v_judge_rulings;
DROP VIEW IF EXISTS v_failures_by_reason;
DROP VIEW IF EXISTS v_tokens_by_role;
DROP VIEW IF EXISTS v_cache_hit_rate;
DROP VIEW IF EXISTS v_cost_per_merged_branch;
DROP VIEW IF EXISTS v_subagent_share;
DROP VIEW IF EXISTS v_escaped_defects;
DROP VIEW IF EXISTS v_flaky_checks;
CREATE VIEW v_rounds_per_branch AS
  SELECT repo, branch, round AS rounds, ended AS merged_at, job_id FROM jobs WHERE outcome = 'merged';
-- The queue's reviewers' findings: not the judge's rulings, nor the suite audits (not part of the queue).
CREATE VIEW v_findings_by_severity AS
  SELECT r.kind AS kind, f.sev_norm AS sev_norm, COUNT(*) AS findings
  FROM findings f JOIN reviews r ON r.id = f.review_id WHERE r.kind IN ('code', 'tests') GROUP BY r.kind, f.sev_norm;
CREATE VIEW v_cost_by_kind_level AS
  SELECT kind, level, COUNT(*) AS reviews, ROUND(SUM(cost_usd), 4) AS cost_usd, ROUND(AVG(cost_usd), 4) AS avg_cost_usd,
         SUM(duration_s) AS duration_s, SUM(tokens_in) AS tokens_in, SUM(tokens_out) AS tokens_out,
         SUM(tokens_cache_w) AS tokens_cache_w, SUM(tokens_cache_r) AS tokens_cache_r
  FROM reviews GROUP BY kind, level;
-- Failed rounds by reason (a replaced job never ran: not a failure).
CREATE VIEW v_failures_by_reason AS
  SELECT repo, fail_reason, COUNT(*) AS failures FROM jobs WHERE outcome IN ('failed', 'escalated')
  GROUP BY repo, fail_reason;
-- The judge rules on the reviewers' blocking findings: reviewer_precision is the share it confirmed.
CREATE VIEW v_judge_rulings AS
  SELECT ruling, COUNT(*) AS findings,
         ROUND(1.0 * COUNT(*) / (SELECT COUNT(*) FROM findings WHERE ruling IS NOT NULL), 4) AS share,
         (SELECT ROUND(1.0 * SUM(ruling = 'confirmed') / COUNT(*), 4) FROM findings WHERE ruling IS NOT NULL)
           AS reviewer_precision
  FROM findings WHERE ruling IS NOT NULL GROUP BY ruling;
-- Tokens per role and repo, from the transcripts, with each subagent counted toward its parent's role
-- (sessions.role_eff); subagent_* is the subagents' part. cost_usd_est is what the tokens would cost at API
-- prices (an estimate: a subscription bills otherwise); unpriced_msgs counts the messages of models without a
-- price, left out of it. The reviews' own cost (review files, sidecars) is in v_cost_by_kind_level.
CREATE VIEW v_tokens_by_role AS
  SELECT s.role_eff AS role, s.repo AS repo, COUNT(DISTINCT s.session_id) AS sessions,
         COUNT(DISTINCT CASE WHEN s.parent_session IS NOT NULL THEN s.session_id END) AS subagent_sessions,
         SUM(u.msgs) AS msgs, SUM(u.tokens_in) AS tokens_in, SUM(u.tokens_out) AS tokens_out,
         SUM(u.cache_w) AS tokens_cache_w, SUM(u.cache_r) AS tokens_cache_r,
         ROUND(SUM(u.cost_usd_est), 4) AS cost_usd_est,
         ROUND(SUM(CASE WHEN s.parent_session IS NOT NULL THEN u.cost_usd_est END), 4) AS subagent_cost_usd_est,
         SUM(CASE WHEN u.cost_usd_est IS NULL THEN u.msgs ELSE 0 END) AS unpriced_msgs
  FROM sessions s JOIN usage_daily u ON u.session_id = s.session_id GROUP BY s.role_eff, s.repo;
-- The subagents' share of each rolled-up role's tokens (all four kinds) and estimated cost.
CREATE VIEW v_subagent_share AS
  SELECT s.role_eff AS role, COUNT(DISTINCT s.session_id) AS sessions,
         COUNT(DISTINCT CASE WHEN s.parent_session IS NOT NULL THEN s.session_id END) AS subagent_sessions,
         SUM(u.tokens_in + u.tokens_out + u.cache_w + u.cache_r) AS tokens,
         SUM(CASE WHEN s.parent_session IS NOT NULL THEN u.tokens_in + u.tokens_out + u.cache_w + u.cache_r ELSE 0 END)
           AS subagent_tokens,
         ROUND(1.0 * SUM(CASE WHEN s.parent_session IS NOT NULL THEN u.tokens_in + u.tokens_out + u.cache_w + u.cache_r
           ELSE 0 END) / NULLIF(SUM(u.tokens_in + u.tokens_out + u.cache_w + u.cache_r), 0), 4) AS subagent_token_share,
         ROUND(SUM(u.cost_usd_est), 4) AS cost_usd_est,
         ROUND(SUM(CASE WHEN s.parent_session IS NOT NULL THEN u.cost_usd_est END), 4) AS subagent_cost_usd_est,
         ROUND(SUM(CASE WHEN s.parent_session IS NOT NULL THEN u.cost_usd_est ELSE 0 END)
           / NULLIF(SUM(u.cost_usd_est), 0), 4) AS subagent_cost_share
  FROM sessions s JOIN usage_daily u ON u.session_id = s.session_id GROUP BY s.role_eff;
-- The share of the input tokens that came from the prompt cache, per rolled-up role.
CREATE VIEW v_cache_hit_rate AS
  SELECT s.role_eff AS role, SUM(u.cache_r) AS tokens_cache_r, SUM(u.tokens_in + u.cache_r + u.cache_w) AS tokens_input,
         ROUND(1.0 * SUM(u.cache_r) / NULLIF(SUM(u.tokens_in + u.cache_r + u.cache_w), 0), 4) AS cache_hit_rate
  FROM sessions s JOIN usage_daily u ON u.session_id = s.session_id GROUP BY s.role_eff;
-- Per merged branch, since its previous merge: the agents' estimated cost (agent sessions, their subagents, and
-- the main session's subagents that worked in the branch's worktree or were linked to its job; by the sessions'
-- repo and branch_eff: the transcripts' branch, or the one link_to_jobs found)
-- and the reviews' and judges' cost from the review files, which is authoritative.
CREATE VIEW v_cost_per_merged_branch AS
  WITH m AS (
    SELECT j.repo, j.branch, j.job_id, j.ended AS merged_at,
           (SELECT MAX(p.ended) FROM jobs p WHERE p.repo = j.repo AND p.branch = j.branch AND p.outcome = 'merged'
              AND p.ended < j.ended) AS since
    FROM jobs j WHERE j.outcome = 'merged' AND j.repo IS NOT NULL AND j.branch IS NOT NULL),
  a AS (
    SELECT s.session_id, s.repo, COALESCE(s.branch_eff, s.branch) AS branch, s.start, SUM(u.cost_usd_est) AS cost
    FROM sessions s JOIN usage_daily u ON u.session_id = s.session_id
    WHERE s.role_eff = 'agent' GROUP BY s.session_id)
  SELECT m.repo AS repo, m.branch AS branch, m.merged_at AS merged_at, m.job_id AS job_id,
         (SELECT COUNT(*) FROM a WHERE a.repo = m.repo AND a.branch = m.branch AND a.start <= m.merged_at
            AND (m.since IS NULL OR a.start > m.since)) AS agent_sessions,
         (SELECT ROUND(SUM(a.cost), 4) FROM a WHERE a.repo = m.repo AND a.branch = m.branch AND a.start <= m.merged_at
            AND (m.since IS NULL OR a.start > m.since)) AS agent_cost_usd_est,
         (SELECT ROUND(SUM(r.cost_usd), 4) FROM reviews r WHERE r.repo = m.repo AND r.branch = m.branch
            AND r.kind IN ('code', 'tests') AND r.finished <= m.merged_at AND (m.since IS NULL OR r.finished > m.since))
           AS review_cost_usd,
         (SELECT ROUND(SUM(r.cost_usd), 4) FROM reviews r WHERE r.repo = m.repo AND r.branch = m.branch
            AND r.kind = 'judge' AND r.finished <= m.merged_at AND (m.since IS NULL OR r.finished > m.since))
           AS judge_cost_usd
  FROM m;
-- Each branch the queue merged (a main commit whose branch has a merged job), escaped if a later fix (a fix/
-- branch, or a "fix:" commit of no known branch) or revert merged into main within 14 days touches one of its
-- files.
CREATE VIEW v_escaped_defects AS
  SELECT c.repo AS repo, c.branch AS branch, c.sha AS sha, c.ts AS merged_at,
         (SELECT x.sha FROM main_commits x WHERE x.repo = c.repo AND x.sha <> c.sha AND x.kind IN ('fix', 'revert')
            AND x.ts > c.ts AND julianday(x.ts) <= julianday(c.ts) + 14
            AND EXISTS (SELECT 1 FROM main_commit_files a JOIN main_commit_files b ON b.path = a.path
                        WHERE a.repo = c.repo AND a.sha = c.sha AND b.repo = x.repo AND b.sha = x.sha)
            ORDER BY x.ts LIMIT 1) AS fixed_by
  FROM main_commits c WHERE c.branch IS NOT NULL
    AND EXISTS (SELECT 1 FROM jobs j WHERE j.repo = c.repo AND j.branch = c.branch AND j.outcome = 'merged');
-- Each failed CI check run of a job, flaky if checks then passed with no new commits: on the same sha, or in a
-- later job of the branch queued at the same commit (the queue's merge of main gives it another sha).
CREATE VIEW v_flaky_checks AS
  SELECT c.job_id AS job_id, c.repo AS repo, c.branch AS branch, c.sha AS sha, c.ts AS failed_at,
         (SELECT MIN(p.ts) FROM checks p WHERE p.result = 'pass' AND p.ts > c.ts AND p.repo IS c.repo
            AND (p.sha = c.sha OR (p.branch = c.branch AND p.queued_sha = c.queued_sha))) AS passed_at
  FROM checks c WHERE c.result = 'fail';
"""


def die(msg, code=2):
    print("stats: " + msg, file=sys.stderr)
    sys.exit(code)


# --- severity -------------------------------------------------------------------------------------------------

SEV_MAP = {"must-fix": "blocker", "important": "blocker", "critical": "blocker", "should-fix": "major", "nit": "minor"}
SEV_WORDS = (r"must[- ]fix|should[- ]fix|important|nit|pre[_-]existing|critical|blocker|major|minor"
             r"|breaks (?:a|the) (?:repo )?rule")


def sev_norm(raw):
    """must-fix / important / critical -> blocker, should-fix -> major, nit -> minor, anything else -> other."""
    key = re.sub(r"[\s_]+", "-", (raw or "").strip().lower())
    return SEV_MAP.get(key, "other")


# --- review files ---------------------------------------------------------------------------------------------

HEADER_RE = re.compile(r"^#\s+(Review|Test review|Judgement|Test suite audit) of (\S+) at ([0-9a-f]{7,40}) \((.*)\)\s*$")
KIND_BY_TITLE = {"Review": "code", "Test review": "tests", "Judgement": "judge", "Test suite audit": "suite"}
FILE_RE = re.compile(r"^(?P<b>.+)-(?P<sha>[0-9a-f]{7,40})(?:-(?P<sfx>low|medium|high|xhigh|tests|judge)(?P<nt>-notests)?)?\.md$")
SUITE_RE = re.compile(r"^(?P<repo>.+)-suite-(?P<sha>[0-9a-f]{7,40})\.md$")
VERDICT_RE = re.compile(r"verdict:[\s*_`]*(ready|needs changes|escalate|failed)", re.I)
MUT_RE = re.compile(r"mutations?[\s*_`]*:[\s*_`]*(\d+) tried,\s*(\d+) caught,\s*(\d+) survived", re.I)
PATH_RE = re.compile(r"((?:[\w.-]+/)*[\w-][\w.-]*\.\w+|(?:[\w.-]+/)+[\w.-]+):(\d+)")
NUM_RE = re.compile(r"^\s?(?:\*\*)?(\d+)[.)]\s+(.*)$")
TAGS_RE = re.compile(r"^((?:\[[^\]]+\]\s*)+)")
CODE_SEV_RE = re.compile(r"^[\s*_]*(?:severity:\s*)?[\s*_]*(" + SEV_WORDS + r")\b", re.I)
JUDGE_TAG_RE = re.compile(r"^(confirmed|downgraded|rejected)\b\s*(.*)$", re.I)
SOURCE_TAG_RE = re.compile(r"^(code|test) review #\d+$", re.I)  # a judge's "[code review #1]": the finding's source


def finding_from(rest, numbered):
    """(sev_raw, category, judge ruling, path, line, source) of a finding line's text after its number, or None if it
    isn't one. source: code or tests, from a judge's "[code review #N]" or "[test review #N]" tag, else None."""
    path = line = None
    pm = PATH_RE.search(rest)
    if pm:
        path, line = pm.group(1), int(pm.group(2))
    tm = TAGS_RE.match(rest)
    if tm:  # test-review / judge style: "[must-fix] [mutation] path:line: ..."
        tags = re.findall(r"\[([^\]]+)\]", tm.group(1))
        sev = cat = ruling = source = None
        for t in tags:
            j = JUDGE_TAG_RE.match(t.strip())
            sm = SOURCE_TAG_RE.match(t.strip())
            if source is None and sm:
                source = "code" if sm.group(1).lower() == "code" else "tests"
            if ruling is None and sev is None and j:
                ruling, sev = j.group(1).lower(), j.group(2).strip().lower() or None
            elif sev is None and re.fullmatch(SEV_WORDS, t.strip(), re.I):
                sev = t.strip().lower()
            elif cat is None and not re.search(r"#\d", t):  # "[code review #1]" names a source, not a category
                cat = t.strip().lower()
        if sev is None and cat is None and ruling is None:
            return None
        return sev, cat, ruling, path, line, source
    cm = CODE_SEV_RE.match(rest)
    if not cm:
        return None
    if not numbered and not pm:
        return None  # an unnumbered "nit, path:line" needs its path
    sev = re.sub(r"\s+", " ", cm.group(1).lower())
    cat = None
    if sev.startswith("breaks") or re.search(r"breaks (?:a|the) (?:repo )?rule", rest[:80], re.I):
        cat = "rule"
    return sev, cat, None, path, line, None


def parse_review_md(path):
    """The numbers and findings of a review file, read line by line."""
    r = {"title": None, "branch": None, "sha": None, "cost_usd": None, "duration_s": None, "level": None,
         "verdict": None, "mut": None, "findings": []}
    seen = set()
    fence = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, raw in enumerate(fh):
            ln = raw.rstrip("\n")
            if i == 0:
                m = HEADER_RE.match(ln)
                if m:
                    r["title"], r["branch"], r["sha"] = m.group(1), m.group(2), m.group(3)
                    info = m.group(4)
                    c = re.search(r"cost \$([0-9.]+)", info)
                    s = re.search(r"([0-9.]+) s\b", info)
                    lv = re.search(r"/code-review (\w+)", info)
                    r["cost_usd"] = float(c.group(1)) if c else None
                    r["duration_s"] = float(s.group(1)) if s else None
                    r["level"] = lv.group(1) if lv else None
                    continue
            if ln.lstrip().startswith("```"):
                fence = not fence
                continue
            if fence:
                continue
            for v in VERDICT_RE.findall(ln):
                r["verdict"] = v.lower()
            if r["mut"] is None:
                mm = MUT_RE.search(ln)
                if mm:
                    r["mut"] = tuple(int(x) for x in mm.groups())
            nm = NUM_RE.match(ln)
            if nm:
                num, rest = int(nm.group(1)), nm.group(2)
                f = finding_from(rest, True)
                if f and num not in seen:
                    seen.add(num)
                    r["findings"].append(f)
            elif not ln.startswith((" ", "\t")):
                f = finding_from(ln, False)
                if f:
                    r["findings"].append(f)
    return r


def load_sidecar(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def num(v, typ=float):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return typ(v)


def review_row(md, sidecar):
    """The reviews row (without job_id, repo, cached) and findings of one review, from its .md and sidecar."""
    name = os.path.basename(md) if md else (sidecar or {}).get("file")
    row = {"id": name, "branch": None, "kind": None, "level": None, "sha": None, "verdict": None, "cost_usd": None,
           "duration_s": None, "num_turns": None, "session_id": None, "tokens_in": None, "tokens_out": None,
           "tokens_cache_w": None, "tokens_cache_r": None, "mut_tried": None, "mut_caught": None,
           "mut_survived": None, "finished": None, "sidecar": 1 if sidecar else 0, "tests_skipped": None,
           "suite_repo": None}
    findings = []
    sm = SUITE_RE.match(name or "")
    fm = FILE_RE.match(name or "")
    if sm:
        row["kind"], row["sha"], row["suite_repo"] = "suite", sm.group("sha"), sm.group("repo")
    elif fm:
        sfx = fm.group("sfx")
        row["sha"] = fm.group("sha")
        row["kind"] = {"tests": "tests", "judge": "judge"}.get(sfx, "code")
        if row["kind"] == "code":
            row["level"] = sfx
            row["tests_skipped"] = 1 if fm.group("nt") else 0
    if md and os.path.isfile(md):
        p = parse_review_md(md)
        if p["title"]:
            row["kind"] = KIND_BY_TITLE[p["title"]]
            if row["kind"] == "suite":
                row["suite_repo"] = row["suite_repo"] or p["branch"]
            else:
                row["branch"] = p["branch"]
            row["sha"] = row["sha"] or p["sha"]
        row["level"] = row["level"] or p["level"]
        row["cost_usd"], row["duration_s"], row["verdict"] = p["cost_usd"], p["duration_s"], p["verdict"]
        if p["mut"]:
            row["mut_tried"], row["mut_caught"], row["mut_survived"] = p["mut"]
        findings = p["findings"]
        row["finished"] = iso(os.stat(md).st_mtime)
    if sidecar:
        s = sidecar
        for k in ("kind", "branch", "sha", "level", "verdict", "session_id"):
            if isinstance(s.get(k), str) and s[k]:
                row[k] = s[k].lower() if k == "verdict" else s[k]
        if num(s.get("cost_usd")) is not None:
            row["cost_usd"] = num(s["cost_usd"])
        if num(s.get("duration_ms")) is not None:
            row["duration_s"] = num(s["duration_ms"]) / 1000
        if isinstance(s.get("tests_skipped"), bool):
            row["tests_skipped"] = int(s["tests_skipped"])
        row["num_turns"] = num(s.get("num_turns"), int)
        u = s.get("usage") if isinstance(s.get("usage"), dict) else {}
        row["tokens_in"] = num(u.get("input_tokens"), int)
        row["tokens_out"] = num(u.get("output_tokens"), int)
        row["tokens_cache_w"] = num(u.get("cache_creation_input_tokens"), int)
        row["tokens_cache_r"] = num(u.get("cache_read_input_tokens"), int)
        if isinstance(s.get("finished"), str):
            row["finished"] = norm_ts(s["finished"]) or row["finished"]
    return row, findings


# --- time -----------------------------------------------------------------------------------------------------

def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def norm_ts(s):
    """An ISO 8601 time as UTC "YYYY-MM-DDTHH:MM:SS.mmmZ", or None."""
    try:
        d = datetime.datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return iso(d.timestamp())


def local_ts(s):
    """results.log's local "YYYY-MM-DD HH:MM:SS" as UTC ISO, or None."""
    try:
        return iso(time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S")))
    except (ValueError, OverflowError):
        return None


def epoch(ts):
    return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))


# --- files and their state ------------------------------------------------------------------------------------

def file_changed(db, path):
    """(changed, stat) for a whole-file source: changed if its inode, size or mtime differ from the last run."""
    try:
        st = os.stat(path)
    except OSError:
        return False, None
    row = db.execute("SELECT inode, size, mtime FROM ingest_state WHERE path = ?", (path,)).fetchone()
    return row != (st.st_ino, st.st_size, st.st_mtime), st


def save_state(db, path, st, offset):
    db.execute("INSERT OR REPLACE INTO ingest_state (path, inode, size, offset, mtime) VALUES (?, ?, ?, ?, ?)",
               (path, st.st_ino, st.st_size, offset, st.st_mtime))


def tail_jsonl(db, path, handle, key=None, restart=None):
    """Calls handle(text, obj) for each new complete line of a JSON-lines file that holds an object, from where
    the last run stopped (from the start if the file is another inode or shorter), and saves where it stopped,
    in ingest_state under key (default: the path). A last line without its newline is left for the next run.
    restart() is called first when the file is read from its start again. Returns False if the file is missing."""
    key = key or path
    try:
        st = os.stat(path)
    except OSError:
        return False
    row = db.execute("SELECT inode, offset FROM ingest_state WHERE path = ?", (key,)).fetchone()
    offset = 0
    if row and row[0] == st.st_ino and row[1] <= st.st_size:
        offset = row[1]
    if row and offset == 0 and restart:
        restart()
    with open(path, "rb") as fh:
        fh.seek(offset)
        for raw in fh:
            if not raw.endswith(b"\n"):
                break  # a line still being written: the next run reads it whole
            offset += len(raw)
            text = raw.rstrip(b"\r\n")
            if not text.strip():
                continue
            try:
                d = json.loads(text.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(d, dict):
                handle(text, d)
    save_state(db, key, st, offset)
    return True


def ingest_events(db, path):
    """New complete lines of events.jsonl into events_raw. Returns how many were new."""
    new = [0]

    def add(text, d):
        h = hashlib.sha256(text).hexdigest()
        cur = db.execute("INSERT OR IGNORE INTO events_raw (hash, ts, event, json) VALUES (?, ?, ?, ?)",
                         (h, norm_ts(str(d.get("ts", ""))), d.get("event"), text.decode("utf-8")))
        new[0] += cur.rowcount

    tail_jsonl(db, path, add)
    return new[0]


def ingest_reviews(db, rdir):
    """Each review whose .md or sidecar changed since the last run, with its findings. Returns how many."""
    names = set()
    for p in glob.glob(os.path.join(glob.escape(rdir), "*.md")) + glob.glob(os.path.join(glob.escape(rdir), "*.json")):
        names.add(p[:-3] if p.endswith(".md") else p[:-5])
    done = 0
    for base in sorted(names):
        md, sc = base + ".md", base + ".json"
        ch_md, st_md = file_changed(db, md)
        ch_sc, st_sc = file_changed(db, sc)
        if not (ch_md or ch_sc):
            continue
        sidecar = load_sidecar(sc) if st_sc else None
        if not st_md and not sidecar:
            continue
        row, findings = review_row(md if st_md else None, sidecar)
        if not row["id"]:
            continue
        suite_repo = row.pop("suite_repo")
        old = db.execute("SELECT job_id, repo, cached FROM reviews WHERE id = ?", (row["id"],)).fetchone()
        row["job_id"], row["repo"], row["cached"] = old if old else (None, None, None)
        row["repo"] = row["repo"] or suite_repo
        cols = list(row)
        db.execute("INSERT OR REPLACE INTO reviews (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
                   [row[c] for c in cols])
        db.execute("DELETE FROM findings WHERE review_id = ?", (row["id"],))
        for n, (sev, cat, ruling, fpath, fline, source) in enumerate(findings, 1):
            db.execute("INSERT INTO findings (review_id, n, sev_norm, sev_raw, category, ruling, path, line, source) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       (row["id"], n, sev_norm(sev), sev, cat, ruling, fpath, fline, source))
        for p, st in ((md, st_md), (sc, st_sc)):
            if st:
                save_state(db, p, st, st.st_size)
        done += 1
    return done


# --- transcripts ----------------------------------------------------------------------------------------------

# USD per million tokens, by the date they apply from. cache_w is a 5-minute cache write, cache_w_1h a 1-hour one.
# A day before a model's first row, or a model with no row, has no price: its cost is null and the ingest
# summary names it.
PRICE_SOURCE = ("Claude API list prices (first party) from the claude-api skill's model table, cached 2026-11-03: "
                "cache writes 1.25x input (5 minutes) and 2x (1 hour); Haiku 5.5 at its rate for prompts up to "
                "100K tokens")
PRICES = [  # (model, effective_from, in, out, cache_w, cache_w_1h, cache_r)
    ("claude-opus-5-5", "2026-11-03", 4.00, 20.00, 5.00, 8.00, 0.20),
    ("claude-sonnet-5-5", "2026-11-03", 2.00, 10.00, 2.50, 4.00, 0.10),
    ("claude-haiku-5-5", "2026-11-03", 0.10, 0.50, 0.125, 0.20, 0.01),
]


def price_for(model, day):
    """(in, out, cache_w, cache_w_1h, cache_r) USD per MTok for the model on the day ("YYYY-MM-DD"), or None."""
    rows = [p for p in PRICES if p[0] == model and p[1] <= (day or "")]
    return max(rows, key=lambda p: p[1])[2:] if rows else None


def cost_est(model, day, tin, tout, cw, cw1h, cr):
    """The API-equivalent cost of the tokens in USD, or None without a price (0 with no tokens at all)."""
    if not (tin or tout or cw or cr):
        return 0.0
    p = price_for(model, day)
    if p is None:
        return None
    usd_in, usd_out, usd_w, usd_w1h, usd_r = p
    cw1h = min(cw1h or 0, cw or 0)
    return ((tin or 0) * usd_in + (tout or 0) * usd_out + ((cw or 0) - cw1h) * usd_w + cw1h * usd_w1h
            + (cr or 0) * usd_r) / 1e6


def default_projects():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"),
                        "projects")


def transcript_files(projects):
    """(path, session_id, parent session id or None) of each transcript: a session's, then its subagents'. A
    session's file is named by its sessionId; a subagent's session is "<parent>:agent-<agentId>"."""
    out = []
    root = glob.escape(projects)
    for p in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        out.append((p, os.path.basename(p)[:-6], None))
    for p in sorted(glob.glob(os.path.join(root, "*", "*", "subagents", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(p)))
        out.append((p, parent + ":" + os.path.basename(p)[:-6], parent))
    return out


def transcript_key(path):
    """A transcript's ingest_state key: a hash, since its folder's name is its session's cwd."""
    return "transcript:" + hashlib.sha256(path.encode("utf-8", "replace")).hexdigest()[:32]


def tmp_dirs():
    import tempfile
    return {d.rstrip("/") + "/" for d in ("/tmp", "/var/tmp", tempfile.gettempdir())}


def cwd_facts(cwd):
    """(sha256 of the cwd, its folder name, place) of a session's cwd: place is repos (a folder under a repos/),
    tmp (a temp dir) or dir. Only these are stored, never the path."""
    if not isinstance(cwd, str) or not cwd:
        return None, None, None
    h = hashlib.sha256(cwd.encode("utf-8", "replace")).hexdigest()[:16]
    parts = cwd.rstrip("/").split("/")
    if "repos" in parts[:-1]:  # the last repos/ that has a folder after it
        i = len(parts) - 2 - parts[-2::-1].index("repos")
        return h, parts[i + 1], "repos"
    if any((cwd.rstrip("/") + "/").startswith(t) for t in tmp_dirs()):
        return h, None, "tmp"
    return h, parts[-1] or None, "dir"


def num_tok(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def ingest_transcripts(db, projects):
    """New lines of every transcript (see ingest_transcript). A transcript that can't be read is skipped, its
    changes undone, and the rest are read. Returns (files read, new msgs, {error name: files skipped})."""
    files = new = 0
    skipped = {}
    for path, sid, parent in transcript_files(projects):
        db.execute("SAVEPOINT transcript")
        try:
            n = ingest_transcript(db, path, sid, parent)
        except Exception as e:  # noqa: BLE001 -- one bad transcript never stops the ingest
            db.execute("ROLLBACK TO transcript")
            skipped[type(e).__name__] = skipped.get(type(e).__name__, 0) + 1
            n = None
        db.execute("RELEASE transcript")
        if n is not None:
            files += 1
            new += n
    return files, new, skipped


def ingest_transcript(db, path, sid, parent):
    """New lines of one transcript: each message's usage once (by message.id), its session's entrypoint, first
    cwd and branch, first and last time, and its lines per cwd and branch. Reads only the allowlisted fields.
    Returns how many messages were new, or None if the file is missing."""
    facts = {"entrypoint": None, "cwd": None, "branch": None, "start": None, "end": None, "lines": 0,
             "restart": False}
    msgs = []
    places = {}  # (cwd, branch) -> lines: where the session's lines were, also after it cd's elsewhere

    def take(text, d):
        facts["lines"] += 1
        ts = norm_ts(d["timestamp"]) if isinstance(d.get("timestamp"), str) else None
        if ts:
            facts["start"] = min(facts["start"] or ts, ts)
            facts["end"] = max(facts["end"] or ts, ts)
        for k, f in (("entrypoint", "entrypoint"), ("cwd", "cwd"), ("branch", "gitBranch")):
            if facts[k] is None and isinstance(d.get(f), str) and d[f]:
                facts[k] = d[f]
        if isinstance(d.get("cwd"), str) and d["cwd"]:
            pk = (d["cwd"], d["gitBranch"] if isinstance(d.get("gitBranch"), str) else "")
            places[pk] = places.get(pk, 0) + 1
        m = d.get("message")
        if not isinstance(m, dict) or not isinstance(m.get("usage"), dict) or not isinstance(m.get("id"), str):
            return
        u = m["usage"]
        cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
        model = m.get("model") if isinstance(m.get("model"), str) else None
        msgs.append((m["id"], sid, model,
                     ts[:10] if ts else None, num_tok(u.get("input_tokens")), num_tok(u.get("output_tokens")),
                     num_tok(u.get("cache_creation_input_tokens")), num_tok(cc.get("ephemeral_1h_input_tokens")),
                     num_tok(u.get("cache_read_input_tokens"))))

    if not tail_jsonl(db, path, take, transcript_key(path), lambda: facts.update(restart=True)):
        return None
    if facts["restart"]:  # read again from the start: its places are counted again
        db.execute("DELETE FROM session_places WHERE session_id = ?", (sid,))
    if not facts["lines"]:
        return 0
    new = 0
    for (cwd, branch), n in places.items():
        h, name, place = cwd_facts(cwd)
        db.execute("INSERT INTO session_places VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (session_id, cwd_hash, branch) "
                   "DO UPDATE SET lines = session_places.lines + excluded.lines", (sid, h, branch, name, place, n))
    for row in msgs:
        new += db.execute("INSERT OR IGNORE INTO usage_msgs (msg_id, session_id, model, day, tokens_in, tokens_out, "
                          "cache_w, cache_w_1h, cache_r) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", row).rowcount
    h, name, place = cwd_facts(facts["cwd"])
    db.execute(
        "INSERT INTO sessions (session_id, worktree, branch, cwd_hash, place, entrypoint, start, end, parent_session) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (session_id) DO UPDATE SET "
        "worktree = CASE WHEN sessions.cwd_hash IS NULL THEN excluded.worktree ELSE sessions.worktree END, "
        "place = CASE WHEN sessions.cwd_hash IS NULL THEN excluded.place ELSE sessions.place END, "
        "cwd_hash = COALESCE(sessions.cwd_hash, excluded.cwd_hash), "
        "branch = COALESCE(sessions.branch, excluded.branch), "
        "entrypoint = COALESCE(sessions.entrypoint, excluded.entrypoint), "
        "start = MIN(COALESCE(sessions.start, excluded.start), COALESCE(excluded.start, sessions.start)), "
        "end = MAX(COALESCE(sessions.end, excluded.end), COALESCE(excluded.end, sessions.end)), "
        "parent_session = COALESCE(sessions.parent_session, excluded.parent_session)",
        (sid, name, facts["branch"], h, place, facts["entrypoint"], facts["start"], facts["end"], parent))
    return new


ROLE_BY_KIND = {"code": "code review", "tests": "test review", "judge": "judge", "suite": "suite"}


def repo_of_name(name, known):
    """The repo a checkout or worktree folder belongs to: the longest known repo it is or starts with "<repo>-"."""
    if not name:
        return None
    return next((k for k in known if name == k or name.startswith(k + "-")), name)


def where(name, place, known):
    """(repo, in a worktree?) of a session's folder name and place."""
    repo = repo_of_name(name, known) if place in ("repos", "dir") else None
    if place == "repos":
        return repo, name not in known
    return repo, place == "dir" and repo != name


def plan_sessions(state):
    """The session ids the brief sidecars (review.sh --plan) name."""
    bdir = os.environ.get("BRIEF_DIR") or os.path.join(state, "briefs")
    out = set()
    for p in glob.glob(os.path.join(glob.escape(bdir), "*.json")):
        d = load_sidecar(p)
        if d and d.get("kind") == "plan" and isinstance(d.get("session_id"), str):
            out.add(d["session_id"])
    return out


def classify_sessions(db, state):
    """Every session's repo, role, rolled-up role and message count, again. Roles: a session a review sidecar
    names gets that review's kind; one a brief sidecar names, planner; a subagent's file, subagent; an sdk-cli
    session in a worktree that has no sidecar, and ended at most 5 minutes before a review of its branch without one was written, that review's
    kind (each review goes to the session that ended last before it, each session takes one; a session still
    running when the review was written is no review); else an sdk-cli session in a worktree, agent; a cli session in a checkout, main; anything else
    (cli in a worktree, a temp dir), other.
    A subagent's repo and branch are those of the worktree it spent the most lines in (link = worktree: an agent
    the main session started cd's into its worktree), else of its first cwd (link = cwd). Its rolled-up role
    (role_eff) is its parent's, except that a subagent of a main session that worked in a worktree is an agent."""
    known = known_repos(state)
    planners = plan_sessions(state)
    by_session = {}
    unnamed = []  # (branch, finished epoch, review id, kind) of the reviews no sidecar ties to a session
    for rid, kind, sess, branch, finished in db.execute(
            "SELECT id, kind, session_id, branch, finished FROM reviews"):
        if sess:
            by_session.setdefault(sess, (rid, kind))
        elif branch and finished and kind in ROLE_BY_KIND:
            unnamed.append((branch, epoch(finished), rid, kind))
    msgs = dict(db.execute("SELECT session_id, COUNT(*) FROM usage_msgs GROUP BY session_id"))
    updates = []
    candidates = []  # (session, branch, end epoch) of the sdk-cli worktree sessions no sidecar names
    rows = db.execute("SELECT session_id, worktree, place, branch, entrypoint, start, end, parent_session "
                      "FROM sessions ORDER BY end, session_id").fetchall()
    best = {}  # subagent -> (worktree, branch, repo) of the worktree it has the most lines in, any subfolder
    for sid, name, place, branch, n in db.execute(
            "SELECT p.session_id, p.worktree, p.place, p.branch, SUM(p.lines) AS n FROM session_places p "
            "JOIN sessions s ON s.session_id = p.session_id WHERE s.parent_session IS NOT NULL "
            "GROUP BY p.session_id, p.worktree, p.place, p.branch ORDER BY p.session_id, n DESC, p.worktree, p.branch"):
        repo, wt = where(name, place, known)
        if wt and sid not in best:
            best[sid] = (name, branch or None, repo)
    for sid, name, place, branch, entry, start, end, parent in rows:
        repo, in_worktree = where(name, place, known)
        link = "cwd"
        if sid in best:
            name, branch, repo = best[sid]
            link = "worktree"
        review_id = role = None
        if sid in by_session:
            review_id, kind = by_session[sid]
            role = ROLE_BY_KIND.get(kind, "review")
        elif sid in planners:
            role = "planner"
        elif parent:
            role = "subagent"
        elif entry == "sdk-cli" and in_worktree:
            role = "agent"
            if end and branch:
                candidates.append((sid, branch, epoch(end)))
        elif entry == "cli" and place in ("repos", "dir") and not in_worktree:
            role = "main"
        else:
            role = "other"
        updates.append((role, repo, name, branch, link, msgs.get(sid, 0), review_id, sid))
    # Each review without a sidecar, in the order they were written, goes to the free session of its branch that
    # ended last at most 5 minutes before it was written; each session takes at most one review.
    used = {}
    for b, f, rid, kind in sorted(unnamed, key=lambda r: (r[1], r[2])):
        near = [(e0, sid) for sid, cb, e0 in candidates if cb == b and sid not in used and e0 <= f <= e0 + 300]
        if near:
            used[max(near)[1]] = (rid, kind)
    updates = [(ROLE_BY_KIND[used[u[-1]][1]],) + u[1:6] + (used[u[-1]][0], u[-1]) if u[-1] in used else u
               for u in updates]
    db.executemany("UPDATE sessions SET role = ?, repo = ?, worktree = ?, branch = ?, link = ?, msgs = ?, review_id = ? "
                   "WHERE session_id = ?", updates)
    # Rolled up: a subagent counts toward its parent's role (subagent if its parent has no transcript).
    db.execute("UPDATE sessions SET role_eff = role, branch_eff = branch")
    db.execute("UPDATE sessions SET role_eff = COALESCE((SELECT CASE WHEN p.role = 'main' AND sessions.link = 'worktree' "
               "THEN 'agent' ELSE p.role END FROM sessions p WHERE p.session_id = sessions.parent_session), 'subagent') "
               "WHERE parent_session IS NOT NULL")
    link_to_jobs(db, state, known)


LINK_WINDOW = 600  # seconds from a session's end to the job queued after it


def link_to_jobs(db, state, known):
    """The branch of each agent-like session whose own branch was never queued (main, none, another): the
    main session's subagents, and the agents' sessions and subagents. Their transcripts often don't show the
    branch: an agent that works with git -C and absolute paths stays in the main checkout, and a worktree's
    lines can carry the main checkout's branch.
    1. A session in a worktree a job file names, for one branch only, gets that branch (link = job_worktree).
    2. Else a subagent, or an agent session, that ended at most LINK_WINDOW before a job of its repo was queued
       (job_queued events, and the times in the job files' names) gets the branch of the nearest such job
       (link = queued). A subagent of the main session linked so counts as an agent (role_eff)."""
    jobs = job_files(state)
    wt_branches = {}
    queued = {}  # job_id -> (repo, branch, queued epoch)
    for j in jobs:
        if j["repo"] and j["branch"] and j["worktree"] and j["worktree"] not in known:
            wt_branches.setdefault((j["repo"], j["worktree"]), set()).add(j["branch"])
        if j["repo"] and j["branch"] and j["queued"]:
            queued[j["job_id"]] = (j["repo"], j["branch"], j["queued"])
    for jid, repo, branch, ts in db.execute("SELECT job_id, repo, branch, queued FROM jobs WHERE queued IS NOT NULL"):
        if repo and branch:
            queued[jid] = (repo, branch, epoch(ts))
    branches = {(r, b) for r, b, _ in queued.values()}
    branches |= {(r, b) for (r, _), bs in wt_branches.items() for b in bs}
    updates = []
    for sid, repo, wt, branch, end, role, role_eff, parent in db.execute(
            "SELECT session_id, repo, worktree, branch, end, role, role_eff, parent_session FROM sessions "
            "WHERE repo IS NOT NULL AND (role = 'agent' OR (parent_session IS NOT NULL AND role_eff IN ('agent', 'main')))"
            ).fetchall():
        if (repo, branch) in branches:
            continue
        new = None
        bs = wt_branches.get((repo, wt), set())
        if len(bs) == 1:
            new = (next(iter(bs)), "job_worktree")
        elif end:
            e0 = epoch(end)
            near = sorted((q - e0, b) for r, b, q in queued.values() if r == repo and 0 <= q - e0 <= LINK_WINDOW)
            if near:
                new = (near[0][1], "queued")
        if new:
            updates.append((new[0], new[1], "agent" if parent else role_eff, sid))
    db.executemany("UPDATE sessions SET branch_eff = ?, link = ?, role_eff = ? WHERE session_id = ?", updates)


def rebuild_usage(db):
    """usage_daily, again from the messages, with each day's estimated cost; prices from PRICES. Returns the
    models that have tokens but no price."""
    db.execute("DELETE FROM prices")
    db.executemany("INSERT INTO prices VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [p + (PRICE_SOURCE,) for p in PRICES])
    db.execute("DELETE FROM usage_daily")
    unpriced = set()
    rows = []
    for sid, model, day, tin, tout, cw, cw1h, cr, n in db.execute(
            "SELECT session_id, COALESCE(model, ''), COALESCE(day, ''), SUM(tokens_in), SUM(tokens_out), "
            "SUM(cache_w), SUM(cache_w_1h), SUM(cache_r), COUNT(*) FROM usage_msgs GROUP BY 1, 2, 3"):
        c = cost_est(model, day, tin, tout, cw, cw1h, cr)
        if c is None:
            unpriced.add(model or "(none)")
        rows.append((sid, model, day, tin, tout, cw, cw1h, cr, n, c))
    db.executemany("INSERT INTO usage_daily VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    return sorted(unpriced)


# --- jobs -----------------------------------------------------------------------------------------------------

RESULT_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (FAILED|MERGED|READY) (\S+?): (.*)$")
REASONS = [  # results.log's failure text -> the events' job_failed reason; the first match wins
    (r"needs your decision", "judge"),
    (r"the judge confirmed", "judge"),
    (r"didn't run", "review_error"),
    (r"(^|; )the review found changes", "review_code"),
    (r"the test review found changes", "review_tests"),
    (r"git fetch failed", "fetch"),
    (r"merge conflict", "conflict"),
    (r"the full e2e suite failed", "e2e"),
    (r"no local e2e pass", "no_e2e_pass"),
    (r"got commits after the review", "moved"),
    (r"is gone|is no longer on|uncommitted changes", "not_ready"),  # before the job started
    (r"git push failed", "push"),
    (r"create-pr\.sh failed|gh pr create failed|no PR found", "pr"),
    (r"as its head", "head"),
    (r"checks failed on", "checks_failed"),
    (r"no checks reported", "checks_timeout"),  # as pr-queue.sh's job_failed reason
    (r"checks still pending", "checks_timeout"),
    (r"merging #\d+ failed", "merge"),
]


def fail_reason(text):
    for pat, reason in REASONS:
        if re.search(pat, text):
            return reason
    return "other"


def known_repos(state):
    """The repos the queue knows (its repos/ folders), longest name first."""
    return sorted((os.path.basename(p) for p in glob.glob(os.path.join(glob.escape(state), "repos", "*"))
                   if os.path.isdir(p)), key=len, reverse=True)


def job_files(state):
    """Every job file the queue kept (queued, running, done, failed; per repo, and the old single queue's), as
    {job_id, repo, branch, worktree (its folder name), type, description, queued (epoch, from the file's
    name, or None)}. An old job's repo is the known repo its worktree's folder is or starts with "<repo>-"."""
    known = known_repos(state)
    out = []
    paths = [(job, repo) for repo in known
             for job in glob.glob(os.path.join(glob.escape(state), "repos", glob.escape(repo), "*", "*.job"))]
    paths += [(job, None) for job in (glob.glob(os.path.join(glob.escape(state), "legacy", "*", "*.job"))
                                      + glob.glob(os.path.join(glob.escape(state), "*", "*.job")))]
    for job, repo in sorted(paths):
        wt = os.path.basename((job_field(job, "worktree") or "").rstrip("/")) or None
        if repo is None and wt:
            repo = next((k for k in known if wt == k or wt.startswith(k + "-")), None)
        name = os.path.basename(job)[:-4]
        ns = name.split("-", 1)[0]
        out.append({"job_id": name, "repo": repo, "branch": job_field(job, "branch") or None, "worktree": wt,
                    "type": job_field(job, "type"), "description": job_field(job, "description"),
                    "queued": int(ns) / 1e9 if ns.isdigit() and len(ns) >= 16 else None})
    return out


def job_repos(state):
    """branch -> repo, from the job files (a branch found in two repos maps to none)."""
    found = {}
    for j in job_files(state):
        if j["branch"] and j["repo"]:
            found.setdefault(j["branch"], set()).add(j["repo"])
    return {b: next(iter(r)) for b, r in found.items() if len(r) == 1}


def job_field(path, name):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                if ln.startswith(name + "="):
                    return ln[len(name) + 1:].rstrip("\n")
    except OSError:
        pass
    return None


def results_logs(state):
    """(path, repo or None) of every results.log: per repo, and the old single queue's."""
    out = [(p, os.path.basename(os.path.dirname(p)))
           for p in sorted(glob.glob(os.path.join(glob.escape(state), "repos", "*", "results.log")))]
    if os.path.isfile(os.path.join(state, "results.log")):
        out.append((os.path.join(state, "results.log"), None))
    return out


def rebuild_jobs(db, state):
    """jobs, again from scratch: from the events, then the results.log rounds from before any event of the repo.
    Returns {review file basename: job_id} of the reviews that results.log lines name."""
    jobs = {}
    first_event = {}  # repo -> the time of its first event
    review_events = {}  # review basename -> (ts, job_id, repo) of each of its review_finished events
    checks = []  # (job_id, repo, branch, sha, ts, result) of each checks_finished that passed or failed
    queued_sha = {}  # job_id -> the commit it was queued at
    for ts, ev, js in db.execute("SELECT ts, event, json FROM events_raw ORDER BY ts, hash"):
        try:
            d = json.loads(js)
        except ValueError:
            continue
        jid, repo = d.get("job_id"), d.get("repo")
        if repo and ts and repo not in first_event:
            first_event[repo] = ts
        if None not in first_event and ts:
            first_event[None] = ts
        if not isinstance(jid, str) or not jid:
            continue
        j = jobs.setdefault(jid, {"job_id": jid, "repo": None, "branch": None, "queued": None, "started": None,
                                  "ended": None, "outcome": None, "fail_reason": None, "review_level": None,
                                  "tests": None, "source": "events", "found": None, "_first": ts})
        j["repo"] = j["repo"] or repo
        j["branch"] = j["branch"] or d.get("branch")
        if ev == "job_queued":
            j["queued"] = ts
            queued_sha[jid] = d.get("sha") if isinstance(d.get("sha"), str) else None
            j["review_level"] = d.get("review") if d.get("review") not in ("", None) else j["review_level"]
            j["tests"] = d.get("tests") if d.get("tests") not in ("", None) else j["tests"]
        elif ev == "job_started":
            j["started"] = j["started"] or ts
        elif ev == "merged":
            j["ended"], j["outcome"] = ts, "merged"
        elif ev == "job_ready":  # finished with PR_QUEUE_MERGE=0: the PR is left open
            j["ended"], j["outcome"] = ts, "ready"
        elif ev == "job_failed":
            j["ended"] = ts
            j["outcome"] = "escalated" if j["outcome"] == "escalated" else "failed"
            j["fail_reason"] = d.get("reason")
            if j["fail_reason"] == "replaced":  # removed from the queue by a re-queue of its branch: never ran
                j["outcome"] = "replaced"
            if isinstance(d.get("found"), list):  # the reviews that found changes to make: code, tests
                j["found"] = ",".join(sorted({k for k in d["found"] if isinstance(k, str) and k})) or None
        elif ev == "escalated":
            j["outcome"] = "escalated"
            j["fail_reason"] = j["fail_reason"] or d.get("reason")
        elif ev == "checks_finished" and d.get("result") in ("pass", "fail"):
            checks.append((jid, repo, d.get("branch"), d.get("sha") if isinstance(d.get("sha"), str) else None,
                           ts, d["result"]))
        elif ev == "review_finished" and isinstance(d.get("review_file"), str):
            name = os.path.basename(d["review_file"])
            review_events.setdefault(name, []).append((ts, jid, repo))
    named = {}
    branch_repo = job_repos(state)
    for path, repo in results_logs(state):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                m = RESULT_RE.match(ln.rstrip("\n"))
                if not m:
                    continue
                ts = local_ts(m.group(1))
                kind, branch, text = m.group(2), m.group(3), m.group(4)
                r = repo or branch_repo.get(branch)
                since = first_event.get(r) if r else first_event.get(None)
                if ts is None or (since and ts >= since):
                    continue  # the events cover this period
                jid = "log-" + hashlib.sha256((path + "\n" + ln).encode()).hexdigest()[:16]
                j = {"job_id": jid, "repo": r, "branch": branch, "queued": None, "started": None, "ended": ts,
                     "outcome": {"MERGED": "merged", "READY": "ready"}.get(kind, "failed"), "fail_reason": None,
                     "review_level": None, "tests": None, "source": "results", "found": None, "_first": ts}
                if kind == "FAILED":
                    j["fail_reason"] = fail_reason(text)
                    if "needs your decision" in text:
                        j["outcome"] = "escalated"
                    found = [k for k, pat in (("code", r"(^|; )the review found changes"),
                                              ("tests", r"the test review found changes")) if re.search(pat, text)]
                    j["found"] = ",".join(found) or None
                    for f in re.findall(r"\((?:review|test review|judge): ([^)]+)\)", text):
                        named.setdefault(os.path.basename(f.strip()), jid)
                jobs[jid] = j
    # round: the job's number among its branch's jobs since the branch last merged (a branch merged and made
    # again under the same name starts at 1).
    rounds = {}
    for j in sorted(jobs.values(), key=lambda j: (j["queued"] or j["started"] or j["_first"] or "", j["job_id"])):
        key = (j["repo"], j["branch"])
        if j["outcome"] == "replaced":
            j["round"] = None  # never ran, so not a round
            continue
        rounds[key] = rounds.get(key, 0) + 1
        j["round"] = rounds[key]
        if j["outcome"] == "merged":
            rounds[key] = 0
    db.execute("DELETE FROM jobs")
    cols = ["job_id", "repo", "branch", "round", "queued", "started", "ended", "outcome", "fail_reason",
            "review_level", "tests", "source", "found"]
    db.executemany("INSERT INTO jobs (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
                   [[j[c] for c in cols] for j in jobs.values()])
    db.execute("DELETE FROM checks")
    db.executemany("INSERT INTO checks (job_id, repo, branch, sha, queued_sha, ts, result) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [(c[0], c[1], c[2], c[3], queued_sha.get(c[0]), c[4], c[5]) for c in checks])
    return review_events, named, branch_repo


def link_reviews(db, review_events, named, branch_repo):
    """Each review's job, repo and cache hits: from its review_finished events (the one nearest the time the
    file was written: a review run again at the same commit overwrites it), else from the results.log line that
    names it, else the first job of its branch that ended after it and started before it."""
    jobs_by_branch = {}
    for jid, repo, branch, started, ended in db.execute(
            "SELECT job_id, repo, branch, started, ended FROM jobs WHERE ended IS NOT NULL ORDER BY ended"):
        jobs_by_branch.setdefault(branch, []).append((ended, started, jid, repo))
    repo_of = dict(db.execute("SELECT job_id, repo FROM jobs"))
    updates = []
    for rid, branch, kind, finished, sidecar, repo in db.execute(
            "SELECT id, branch, kind, finished, sidecar, repo FROM reviews").fetchall():
        jid = cached = None
        evs = review_events.get(rid)
        ev_repo = None
        if evs:
            if finished:
                near = min(evs, key=lambda e: (abs(epoch(e[0]) - epoch(finished)) if e[0] else float("inf"), e[0] or ""))
                # a review_finished well after the review was written is a cached "already reviewed as ready"
                cached = sum(1 for t, _, _ in evs if t and epoch(t) - epoch(finished) > 120)
            else:
                near = evs[0]
            jid, ev_repo = near[1], near[2]
        elif rid in named:
            jid = named[rid]
        elif finished and branch in jobs_by_branch:
            for ended, started, cand, _ in jobs_by_branch[branch]:
                if ended >= finished and (not started or started <= finished):
                    jid = cand
                    break
        r = repo_of.get(jid) or ev_repo or repo or branch_repo.get(branch)
        updates.append((jid, r, cached, rid))
    db.executemany("UPDATE reviews SET job_id = ?, repo = ?, cached = ? WHERE id = ?", updates)


# --- git: what merged into main, and when the rules changed ----------------------------------------------------

RULE_PATHS = (":(glob)claude/rules/**", ":(glob)**/CLAUDE.md", "scripts/queue/review.sh", ":(glob)claude/agents/**")
FIX_RE = re.compile(r"^fix(\([^)]*\))?!?:", re.I)
REVERT_RE = re.compile(r'^(revert "|revert(\([^)]*\))?!?:)', re.I)
PR_SUFFIX_RE = re.compile(r"^(.*?)\s*\(#\d+\)$")
MERGE_PR_RE = re.compile(r"^Merge pull request #\d+ from [^/\s]+/(\S+)")


def checkouts(state):
    """(repo, main checkout) of each repo the queue knows, from repos/<repo>/checkout."""
    out = []
    for repo in sorted(known_repos(state)):
        try:
            with open(os.path.join(state, "repos", repo, "checkout"), encoding="utf-8") as fh:
                path = fh.read().strip()
        except OSError:
            continue
        if path and os.path.isdir(path):
            out.append((repo, path))
    return out


def git(path, *args):
    """git's output in the checkout, or None if it fails."""
    try:
        return subprocess.run(["git", "-C", path, "-c", "core.quotePath=false"] + list(args), capture_output=True,
                              text=True, errors="replace", check=True, stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def git_log(path, *args):
    """[(sha, short sha, UTC time, subject, [files])] of git log's commits."""
    out = git(path, "log", "--format=%x00%H%x09%h%x09%cI%x09%s", *args)
    if out is None:
        return None
    commits = []
    for chunk in out.split("\0")[1:]:
        lines = chunk.split("\n")
        parts = lines[0].split("\t", 3)
        if len(parts) == 4:
            commits.append((parts[0], parts[1], norm_ts(parts[2]), parts[3], [f for f in lines[1:] if f]))
    return commits


def ingest_git(db, state):
    """main_commits, main_commit_files and rule_changes, again, from each known repo's main checkout (origin/main,
    else its HEAD): main's first-parent commits with the files each changed, and the commits that touched the
    rules (RULE_PATHS). A commit's branch: the merged event's merge_sha, else a "Merge pull request ... from
    <owner>/<branch>" subject, else a squash merge's "<type>: <description> (#N)" that one branch's job files
    have. Its kind: revert, fix (a fix/ branch, or a "fix:" commit of no queue branch) or other. A repo whose
    git fails keeps its rows. Returns (repos read, main commits, rule changes)."""
    by_title = {}
    for j in job_files(state):
        if j["repo"] and j["branch"] and j["type"] and j["description"]:
            by_title.setdefault((j["repo"], "%s: %s" % (j["type"], j["description"])), set()).add(j["branch"])
    by_sha = {}
    for (js,) in db.execute("SELECT json FROM events_raw WHERE event = 'merged'"):
        try:
            d = json.loads(js)
        except ValueError:
            continue
        if isinstance(d.get("merge_sha"), str) and d["merge_sha"] and d.get("branch"):
            by_sha[d["merge_sha"]] = d["branch"]
    done = n_commits = n_rules = 0
    for repo, path in checkouts(state):
        ref = next((r for r in ("origin/main", "HEAD") if git(path, "rev-parse", "--verify", "-q", r + "^{commit}")),
                   None)
        commits = git_log(path, "--first-parent", "--name-only", ref) if ref else None
        rules = git_log(path, "--first-parent", ref, "--", *RULE_PATHS) if ref else None
        if commits is None or rules is None:
            continue
        db.execute("DELETE FROM main_commits WHERE repo = ?", (repo,))
        db.execute("DELETE FROM main_commit_files WHERE repo = ?", (repo,))
        db.execute("DELETE FROM rule_changes WHERE repo = ?", (repo,))
        for sha, _, ts, subject, files in commits:
            branch = by_sha.get(sha)
            m = MERGE_PR_RE.match(subject)
            if not branch and m:
                branch = m.group(1)
            t = PR_SUFFIX_RE.match(subject)
            if not branch and t and len(by_title.get((repo, t.group(1)), ())) == 1:
                branch = next(iter(by_title[(repo, t.group(1))]))
            kind = "other"
            if REVERT_RE.match(subject):
                kind = "revert"
            elif (branch or "").startswith("fix/") or (not branch and FIX_RE.match(subject)):
                kind = "fix"
            db.execute("INSERT OR REPLACE INTO main_commits VALUES (?, ?, ?, ?, ?, ?)",
                       (repo, sha, ts, subject, branch, kind))
            db.executemany("INSERT OR IGNORE INTO main_commit_files VALUES (?, ?, ?)", [(repo, sha, f) for f in files])
        db.executemany("INSERT OR REPLACE INTO rule_changes VALUES (?, ?, ?, ?)",
                       [(repo, short, ts, subject) for _, short, ts, subject, _ in rules])
        done += 1
        n_commits += len(commits)
        n_rules += len(rules)
    return done, n_commits, n_rules


# --- milestones: moments that split the stats into before and after ------------------------------------------

def milestones_file():
    return os.environ.get("STATS_MILESTONES_FILE") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "milestones.json")


def ingest_milestones(db, path):
    """milestones, again, from the milestones file: a JSON list of {"name", "repo", "commit"}. Each one's ts is
    the time of that commit on the repo's main (main_commits, from ingest_git; a commit may be a unique prefix of
    at least 7 hex digits), or NULL while it isn't on main. A missing file means none. Returns the warnings: a
    file that doesn't parse, or isn't a list, is skipped; so is an entry without a name, repo or commit."""
    db.execute("DELETE FROM milestones")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return []
    except OSError as ex:
        return ["cannot read %s: %s" % (path, ex.strerror or ex)]
    try:
        items = json.loads(text)
    except ValueError as ex:
        return ["%s does not parse, skipped: %s" % (path, ex)]
    if not isinstance(items, list):
        return ["%s is not a list of milestones, skipped" % path]
    warnings = []
    for i, m in enumerate(items):
        fields = [m.get(k) if isinstance(m, dict) else None for k in ("name", "repo", "commit")]
        if not all(isinstance(f, str) and f.strip() for f in fields):
            warnings.append("entry %d of %s has no name, repo or commit, skipped" % (i + 1, path))
            continue
        name, repo, commit = (f.strip() for f in fields)
        commit = commit.lower()
        if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
            warnings.append("entry %d of %s: commit %r is not a commit sha, skipped" % (i + 1, path, commit))
            continue
        found = db.execute("SELECT ts FROM main_commits WHERE repo = ? AND substr(sha, 1, ?) = ?",
                           (repo, len(commit), commit)).fetchall()
        db.execute("INSERT INTO milestones (name, repo, sha, ts) VALUES (?, ?, ?, ?)",
                   (name, repo, commit, found[0][0] if len(found) == 1 else None))
    return warnings


# --- db -------------------------------------------------------------------------------------------------------

def default_db():
    d = os.environ.get("CLAUDERAPTOR_STATS_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
        "clauderaptor-stats")
    return os.path.join(d, "stats.db")


def work_tree_of(path):
    """The git work tree the path is (or would be) in, or None: the nearest folder up with a .git."""
    p = os.path.dirname(os.path.realpath(path))
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        up = os.path.dirname(p)
        if up == p:
            return None
        p = up


MIGRATIONS = {2: [("reviews", "tests_skipped", "INTEGER"), ("findings", "ruling", "TEXT")],
              3: [("jobs", "found", "TEXT")],
              5: [("sessions", "branch_eff", "TEXT")],
              6: [("findings", "source", "TEXT")]}
# Version 4 adds tables only (sessions, usage_msgs, usage_daily, prices): SCHEMA makes them. Version 5 also adds
# meta, checks, main_commits, main_commit_files and rule_changes; version 6 milestones.


def migrate(db):
    """An older db up to SCHEMA_VERSION: the new columns, and every review file read again to fill them."""
    row = db.execute("SELECT MAX(version) FROM schema_version").fetchone()
    old = row[0] if row[0] is not None else SCHEMA_VERSION
    with db:
        for v in range(old + 1, SCHEMA_VERSION + 1):
            for table, col, typ in MIGRATIONS.get(v, []):
                if col not in [c[1] for c in db.execute("PRAGMA table_info(%s)" % table)]:
                    db.execute("ALTER TABLE %s ADD COLUMN %s %s" % (table, col, typ))
        if old < SCHEMA_VERSION:
            db.execute("DELETE FROM ingest_state WHERE path LIKE '%.md' OR path LIKE '%.json'")
        db.execute("DELETE FROM schema_version")
        db.execute("INSERT INTO schema_version (version) VALUES (?)", (SCHEMA_VERSION,))


def open_db(path):
    tree = work_tree_of(path)
    if tree:
        die("refusing to write %s: it is inside the git work tree %s, and the stats never go into a repo. "
            "Use a path outside any checkout (--db or CLAUDERAPTOR_STATS_DIR)." % (path, tree))
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700)
        os.chmod(d, 0o700)
    os.close(os.open(path, os.O_CREAT | os.O_RDWR, 0o600))
    os.chmod(path, 0o600)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    migrate(db)
    db.executescript(VIEWS)
    return db


def ingest(dbpath, projects=None):
    state = os.environ.get("PR_QUEUE_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "pr-queue")
    events = os.environ.get("STATS_EVENTS_FILE") or os.path.join(state, "events.jsonl")
    rdir = os.environ.get("REVIEW_DIR") or os.path.join(state, "reviews")
    db = open_db(dbpath)
    with db:
        new = ingest_events(db, events)
        changed = ingest_reviews(db, rdir)
        link_reviews(db, *rebuild_jobs(db, state))
        files, new_msgs, skipped = ingest_transcripts(db, projects or default_projects())
        classify_sessions(db, state)
        unpriced = rebuild_usage(db)
        git_repos, git_commits, git_rules = ingest_git(db, state)
        milestone_warnings = ingest_milestones(db, milestones_file())
        db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_ingest', ?)", (iso(time.time()),))
    counts = {t: db.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
              for t in ("events_raw", "jobs", "reviews", "findings", "sessions", "usage_msgs")}
    roles = db.execute("SELECT group_concat(role || ' ' || n, ', ') FROM "
                       "(SELECT role, COUNT(*) AS n FROM sessions GROUP BY role ORDER BY role)").fetchone()[0]
    db.close()
    print("stats: %d new events, %d reviews read; db has %d events, %d jobs, %d reviews, %d findings (%s)"
          % (new, changed, counts["events_raw"], counts["jobs"], counts["reviews"], counts["findings"], dbpath))
    print("stats: %d transcripts read, %d new messages; db has %d sessions (%s), %d messages"
          % (files, new_msgs, counts["sessions"], roles or "none", counts["usage_msgs"]))
    print("stats: git: %d main commits and %d rule changes from %d repos" % (git_commits, git_rules, git_repos))
    if unpriced:
        print("stats: no price for %s: their cost is null" % ", ".join(unpriced))
    for w in milestone_warnings:
        print("stats: milestones: " + w, file=sys.stderr)
    if skipped:
        print("stats: skipped %d transcripts that could not be read (%s)"
              % (sum(skipped.values()), ", ".join("%s %d" % kv for kv in sorted(skipped.items()))))


def main(argv):
    ap = argparse.ArgumentParser(prog="stats.py", description="Local-only stats of the PR queue.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ingest", help="read the queue's events, reviews and results into the db")
    p.add_argument("--db", default=None, help="the db file (default: %s)" % default_db())
    p.add_argument("--projects", default=None, help="Claude Code's transcripts (default: %s)" % default_projects())
    a = ap.parse_args(argv)
    os.umask(0o077)
    if a.cmd == "ingest":
        ingest(a.db or default_db(), a.projects)


if __name__ == "__main__":
    main(sys.argv[1:])
