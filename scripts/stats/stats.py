#!/usr/bin/env python3
"""Local-only stats of the PR queue: how many rounds a branch takes, what reviews cost, what they find.

  stats.py ingest [--db PATH]   reads the queue's state into a SQLite db

The db (default $CLAUDERAPTOR_STATS_DIR/stats.db, else ${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/stats.db)
stays on this machine: stats.py refuses (exit 2) to write it into a git work tree. Its folder is created 0700,
the db 0600.
Sources, all in $PR_QUEUE_DIR (default ${XDG_STATE_HOME:-~/.local/state}/pr-queue):
- events.jsonl (or $STATS_EVENTS_FILE), written by pr-queue.sh: read incrementally, from where the last run
  stopped. A last line without its newline is left for the next run; a new file (another inode) or a shorter
  one is read again from the start.
- the review files in $REVIEW_DIR (default reviews/): the numbers in each .md's header, its findings (number,
  severity, category, file and line, and a judge's ruling: confirmed, downgraded or rejected; never their
  text), the mutation line and the verdict; the sidecar .json next to it, when there is one, has the
  authoritative numbers (and tests_skipped, else the -notests in a code review's name).
- results.log files (repos/*/results.log and the old single queue's): FAILED, MERGED and READY lines fill in
  the rounds of the time before a repo had events.
Ingesting the same files again changes nothing. A db of an older schema version gets the new columns, and its
review files are read again to fill them.
Views: v_rounds_per_branch, v_findings_by_severity (code and test reviews only), v_cost_by_kind_level and
v_judge_rulings (reviewer_precision: the share of the blocking findings it judged that the judge confirmed).
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
import sys
import time

SCHEMA_VERSION = 3

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
  ruling TEXT, PRIMARY KEY (review_id, n));
CREATE TABLE IF NOT EXISTS ingest_state (path TEXT PRIMARY KEY, inode INTEGER, size INTEGER, offset INTEGER, mtime REAL);
"""

# Dropped and made again on every run, so that a new version's views replace an old db's.
VIEWS = """
DROP VIEW IF EXISTS v_rounds_per_branch;
DROP VIEW IF EXISTS v_findings_by_severity;
DROP VIEW IF EXISTS v_cost_by_kind_level;
DROP VIEW IF EXISTS v_judge_rulings;
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
-- The judge rules on the reviewers' blocking findings: reviewer_precision is the share it confirmed.
CREATE VIEW v_judge_rulings AS
  SELECT ruling, COUNT(*) AS findings,
         ROUND(1.0 * COUNT(*) / (SELECT COUNT(*) FROM findings WHERE ruling IS NOT NULL), 4) AS share,
         (SELECT ROUND(1.0 * SUM(ruling = 'confirmed') / COUNT(*), 4) FROM findings WHERE ruling IS NOT NULL)
           AS reviewer_precision
  FROM findings WHERE ruling IS NOT NULL GROUP BY ruling;
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


def finding_from(rest, numbered):
    """(sev_raw, category, judge ruling, path, line) of a finding line's text after its number, or None if it isn't one."""
    path = line = None
    pm = PATH_RE.search(rest)
    if pm:
        path, line = pm.group(1), int(pm.group(2))
    tm = TAGS_RE.match(rest)
    if tm:  # test-review / judge style: "[must-fix] [mutation] path:line: ..."
        tags = re.findall(r"\[([^\]]+)\]", tm.group(1))
        sev = cat = ruling = None
        for t in tags:
            j = JUDGE_TAG_RE.match(t.strip())
            if ruling is None and sev is None and j:
                ruling, sev = j.group(1).lower(), j.group(2).strip().lower() or None
            elif sev is None and re.fullmatch(SEV_WORDS, t.strip(), re.I):
                sev = t.strip().lower()
            elif cat is None and not re.search(r"#\d", t):  # "[code review #1]" names a source, not a category
                cat = t.strip().lower()
        if sev is None and cat is None and ruling is None:
            return None
        return sev, cat, ruling, path, line
    cm = CODE_SEV_RE.match(rest)
    if not cm:
        return None
    if not numbered and not pm:
        return None  # an unnumbered "nit, path:line" needs its path
    sev = re.sub(r"\s+", " ", cm.group(1).lower())
    cat = None
    if sev.startswith("breaks") or re.search(r"breaks (?:a|the) (?:repo )?rule", rest[:80], re.I):
        cat = "rule"
    return sev, cat, None, path, line


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


def ingest_events(db, path):
    """New complete lines of events.jsonl into events_raw. Returns how many were new."""
    try:
        st = os.stat(path)
    except OSError:
        return 0
    row = db.execute("SELECT inode, offset FROM ingest_state WHERE path = ?", (path,)).fetchone()
    offset = 0
    if row and row[0] == st.st_ino and row[1] <= st.st_size:
        offset = row[1]
    new = 0
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
            if not isinstance(d, dict):
                continue
            h = hashlib.sha256(text).hexdigest()
            cur = db.execute("INSERT OR IGNORE INTO events_raw (hash, ts, event, json) VALUES (?, ?, ?, ?)",
                             (h, norm_ts(str(d.get("ts", ""))), d.get("event"), text.decode("utf-8")))
            new += cur.rowcount
    save_state(db, path, st, offset)
    return new


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
        for n, (sev, cat, ruling, fpath, fline) in enumerate(findings, 1):
            db.execute("INSERT INTO findings (review_id, n, sev_norm, sev_raw, category, ruling, path, line) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (row["id"], n, sev_norm(sev), sev, cat, ruling, fpath, fline))
        for p, st in ((md, st_md), (sc, st_sc)):
            if st:
                save_state(db, p, st, st.st_size)
        done += 1
    return done


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
    (r"checks failed on|no checks reported", "checks_failed"),
    (r"checks still pending", "checks_timeout"),
    (r"merging #\d+ failed", "merge"),
]


def fail_reason(text):
    for pat, reason in REASONS:
        if re.search(pat, text):
            return reason
    return "other"


def job_repos(state):
    """branch -> repo, from the job files (a branch found in two repos maps to none)."""
    known = sorted((os.path.basename(p) for p in glob.glob(os.path.join(glob.escape(state), "repos", "*"))
                    if os.path.isdir(p)), key=len, reverse=True)
    found = {}

    def add(branch, repo):
        if branch and repo:
            found.setdefault(branch, set()).add(repo)

    for repo in known:
        for job in glob.glob(os.path.join(glob.escape(state), "repos", glob.escape(repo), "*", "*.job")):
            add(job_field(job, "branch"), repo)
    for job in (glob.glob(os.path.join(glob.escape(state), "legacy", "*", "*.job"))
                + glob.glob(os.path.join(glob.escape(state), "*", "*.job"))):
        wt = job_field(job, "worktree") or ""
        base = os.path.basename(wt.rstrip("/"))
        repo = next((k for k in known if base == k or base.startswith(k + "-")), None)
        add(job_field(job, "branch"), repo)
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
    review_job = {}   # review basename -> (ts, job_id, repo) of its first review_finished event
    finished_ts = {}  # review basename -> every review_finished time
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
            if isinstance(d.get("found"), list):  # the reviews that found changes to make: code, tests
                j["found"] = ",".join(sorted({k for k in d["found"] if isinstance(k, str) and k})) or None
        elif ev == "escalated":
            j["outcome"] = "escalated"
            j["fail_reason"] = j["fail_reason"] or d.get("reason")
        elif ev == "review_finished" and isinstance(d.get("review_file"), str):
            name = os.path.basename(d["review_file"])
            review_job.setdefault(name, (ts, jid, repo))
            finished_ts.setdefault(name, []).append(ts)
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
        rounds[key] = rounds.get(key, 0) + 1
        j["round"] = rounds[key]
        if j["outcome"] == "merged":
            rounds[key] = 0
    db.execute("DELETE FROM jobs")
    cols = ["job_id", "repo", "branch", "round", "queued", "started", "ended", "outcome", "fail_reason",
            "review_level", "tests", "source", "found"]
    db.executemany("INSERT INTO jobs (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
                   [[j[c] for c in cols] for j in jobs.values()])
    return review_job, finished_ts, named, branch_repo


def link_reviews(db, review_job, finished_ts, named, branch_repo):
    """Each review's job, repo and cache hits: from its review_finished events, else from the results.log line
    that names it, else the first job of its branch that ended after it."""
    jobs_by_branch = {}
    for jid, repo, branch, started, ended in db.execute(
            "SELECT job_id, repo, branch, started, ended FROM jobs WHERE ended IS NOT NULL ORDER BY ended"):
        jobs_by_branch.setdefault(branch, []).append((ended, started, jid, repo))
    repo_of = dict(db.execute("SELECT job_id, repo FROM jobs"))
    updates = []
    for rid, branch, kind, finished, sidecar, repo in db.execute(
            "SELECT id, branch, kind, finished, sidecar, repo FROM reviews").fetchall():
        jid = cached = None
        if rid in review_job:
            jid, jrepo = review_job[rid][1], review_job[rid][2]
            # a review_finished well after the review was written is a cached "already reviewed as ready"
            if finished:
                cached = sum(1 for t in finished_ts[rid] if t and epoch(t) - epoch(finished) > 120)
        elif rid in named:
            jid = named[rid]
        elif finished and branch in jobs_by_branch:
            for ended, started, cand, _ in jobs_by_branch[branch]:
                if ended >= finished and (not started or started <= finished):
                    jid = cand
                    break
        r = repo_of.get(jid) or (review_job[rid][2] if rid in review_job else None) or repo or branch_repo.get(branch)
        updates.append((jid, r, cached, rid))
    db.executemany("UPDATE reviews SET job_id = ?, repo = ?, cached = ? WHERE id = ?", updates)


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
              3: [("jobs", "found", "TEXT")]}


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


def ingest(dbpath):
    state = os.environ.get("PR_QUEUE_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "pr-queue")
    events = os.environ.get("STATS_EVENTS_FILE") or os.path.join(state, "events.jsonl")
    rdir = os.environ.get("REVIEW_DIR") or os.path.join(state, "reviews")
    db = open_db(dbpath)
    with db:
        new = ingest_events(db, events)
        changed = ingest_reviews(db, rdir)
        link_reviews(db, *rebuild_jobs(db, state))
    counts = {t: db.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
              for t in ("events_raw", "jobs", "reviews", "findings")}
    db.close()
    print("stats: %d new events, %d reviews read; db has %d events, %d jobs, %d reviews, %d findings (%s)"
          % (new, changed, counts["events_raw"], counts["jobs"], counts["reviews"], counts["findings"], dbpath))


def main(argv):
    ap = argparse.ArgumentParser(prog="stats.py", description="Local-only stats of the PR queue.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ingest", help="read the queue's events, reviews and results into the db")
    p.add_argument("--db", default=None, help="the db file (default: %s)" % default_db())
    a = ap.parse_args(argv)
    os.umask(0o077)
    if a.cmd == "ingest":
        ingest(a.db or default_db())


if __name__ == "__main__":
    main(sys.argv[1:])
