#!/usr/bin/env python3
"""The stats db as one static, local HTML report: how effective the PR queue is.

  report.py [--db PATH] [--out PATH] [--open [--windows-user NAME]]

--db defaults to stats.py's db ($CLAUDERAPTOR_STATS_DIR/stats.db, else
${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/stats.db), --out to report.html next to it. The page is
self-contained (inline CSS and SVG, the logo and icon inlined as data: PNGs, no script, no fonts, no links to
anything), so opening it makes no network requests. Like the db it stays on this machine: report.py refuses (exit 2) to write it into a git work tree,
and writes it 0600, atomically.
--open then opens it in an Edge app window with its own profile (under WSL: msedge.exe through interop, the
Windows user's %LOCALAPPDATA%\\clauderaptor-stats\\edge-profile). The Windows user is the only one under
/mnt/c/Users with an Edge folder; with several, name yours (--windows-user or $CLAUDERAPTOR_WINDOWS_USER).
Outside WSL it prints the report's path instead. $STATS_EDGE overrides msedge.exe's path and
$STATS_WINDOWS_USERS_DIR /mnt/c/Users (for tests).
The cost-and-tokens section reads stats.py's transcript views (v_tokens_by_role, v_cache_hit_rate,
v_subagent_share, v_cost_per_merged_branch) and says "no data yet" while a db doesn't have them.
"""
import argparse
import base64
import datetime
import html
import importlib.util
import os
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import urllib.parse

sys.dont_write_bytecode = True  # importing stats.py leaves no __pycache__ in the checkout
_spec = importlib.util.spec_from_file_location("clauderaptor_stats", os.path.join(os.path.dirname(
    os.path.realpath(__file__)), "stats.py"))
stats = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stats)

MIN_N = 5  # below this many, a share is "not enough data"
WEEKS_FOR_TRENDS = 4
# "What to change" thresholds
PRECISION_LOW = 0.60  # judge-confirmed share of blocking findings
CATEGORY_MIN = 5  # findings of one category...
CATEGORY_SHARE = 0.30  # ...and this share of the findings with a category
READY_SHARE_HIGH = 0.70  # a review kind/level that mostly says ready...
AVG_COST_HIGH = 1.00  # ...at this average cost ($) or more
FIRST_PASS_LOW = 0.50
TOP_REASON_SHARE = 0.40

EDGE = "/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
EDGE_FOLDER = ("AppData", "Local", "Microsoft", "Edge")
PROFILE_FOLDER = ("AppData", "Local", "clauderaptor-stats", "edge-profile")
HERE = os.path.dirname(os.path.realpath(__file__))


def png_data(name):
    """A PNG next to this script as a data: URI, so the page stays self-contained."""
    with open(os.path.join(HERE, name), "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")


def die(msg, code=2):
    print("report: " + msg, file=sys.stderr)
    sys.exit(code)


def e(v):
    """Every string that goes into the page, escaped (db values are untrusted)."""
    return html.escape("" if v is None else str(v), quote=True)


# --- db -------------------------------------------------------------------------------------------------------

class Db:
    def __init__(self, path):
        self.c = sqlite3.connect(urllib.parse.urljoin("file:", urllib.parse.quote(os.path.abspath(path)))
                                 + "?mode=ro", uri=True)
        self.names = {r[0] for r in self.c.execute("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")}

    def has(self, name):
        return name in self.names

    def q(self, sql, args=()):
        """The rows, or none when a table or view isn't there (an older or empty db)."""
        try:
            return self.c.execute(sql, args).fetchall()
        except sqlite3.OperationalError as ex:
            if "no such" in str(ex):
                return []
            raise

    def one(self, sql, args=()):
        rows = self.q(sql, args)
        return rows[0] if rows else None


# --- formatting -----------------------------------------------------------------------------------------------

def money(v):
    if v is None:
        return "–"
    return "$%s" % format(v, ",.2f")


def compact(v):
    if v is None:
        return "–"
    if isinstance(v, float) and not v.is_integer():
        return format(v, ",.2f")
    v = int(v)
    for div, suf in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        # in full under 10,000; 999,950 is 1M, not 1000K
        if abs(v) >= max(div, 1e4) or (div > 1e3 and abs(v) >= div * 0.99995):
            return ("%.1f" % (v / div)).rstrip("0").rstrip(".") + suf
    return format(v, ",")


def share(num, den):
    """'38% (n=148)', or 'not enough data (n=3)' below MIN_N."""
    if not den or den < MIN_N:
        return "not enough data (n=%d)" % (den or 0)
    return "%.0f%% (n=%d)" % (100.0 * num / den, den)


def ratio(num, den):
    return None if not den or den < MIN_N else num / den


# --- charts (inline SVG; each mark's <title> is its hover tooltip) ----------------------------------------------

def bar_path(x, y, w, h, r=4, horizontal=True):
    """A bar with a 4px rounded data end, square at the baseline."""
    r = min(r, w if horizontal else h, (h if horizontal else w) / 2)
    if horizontal:
        return ("M%.1f %.1fH%.1fA%.1f %.1f 0 0 1 %.1f %.1fV%.1fA%.1f %.1f 0 0 1 %.1f %.1fH%.1fZ"
                % (x, y, x + w - r, r, r, x + w, y + r, y + h - r, r, r, x + w - r, y + h, x))
    return ("M%.1f %.1fV%.1fA%.1f %.1f 0 0 1 %.1f %.1fH%.1fA%.1f %.1f 0 0 1 %.1f %.1fV%.1fZ"
            % (x, y + h, y + r, r, r, x + r, y, x + w - r, r, r, x + w, y + r, y + h))


def hbars(rows, fmt=compact, label_w=180, aria="", W=640):
    """Ranked horizontal bars, one hue: rows of (label, value, tooltip)."""
    if not rows:
        return '<p class="empty">no data yet</p>'
    top = max(v for _, v, _ in rows) or 1
    bw, row_h = W - label_w - 120, 28
    out = ['<svg class="chart" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, row_h * len(rows) + 4, e(aria))]
    for i, (label, v, tip) in enumerate(rows):
        y = i * row_h + 4
        w = max(bw * v / top, 0)
        out.append('<text class="lbl" x="%d" y="%d" text-anchor="end">%s</text>' % (label_w - 10, y + 13, e(label)))
        out.append('<g class="mark"><title>%s</title><rect class="hit" x="%d" y="%d" width="%d" height="%d"/>'
                   % (e(tip), label_w, y - 4, bw + 100, row_h))
        if w > 0:
            out.append('<path class="s1" d="%s"/>' % bar_path(label_w, y, w, 16))
        out.append('<text class="val" x="%.1f" y="%d">%s</text></g>' % (label_w + w + 6, y + 13, e(fmt(v))))
    out.append('<line class="axis" x1="%d" x2="%d" y1="0" y2="%d"/></svg>' % (label_w, label_w, row_h * len(rows) + 4))
    return "".join(out)


def nice_ticks(top, whole=False):
    """Clean axis ticks from 0 to at least top; whole numbers only for counts."""
    if top <= 0:
        return [0, 1]
    raw = max(top / 4, 1) if whole else top / 4
    mag = 10 ** len(str(int(raw))) / 10 if raw >= 1 else 1
    step = next(s * mag for s in (1, 2, 5, 10) if s * mag >= raw) if raw >= 1 else (0.25 if top <= 1 else 0.5)
    ticks, t = [], 0
    while t < top + step:
        ticks.append(t)
        t += step
    return ticks


def columns(rows, fmt=compact, aria="", whole=True, marks=None, keys=None):
    """Columns on one baseline with one y axis: rows of (x label, value, tooltip). marks: {key: tooltip}, a
    dashed line over each column whose key (keys[i], default its label) is one (e.g. a rule change that day)."""
    if not rows:
        return '<p class="empty">no data yet</p>'
    W, H, left, bottom, top_pad = 640, 200, 48, 28, 10
    ticks = nice_ticks(max(v for _, v, _ in rows), whole)
    ymax = ticks[-1] or 1
    plot_h = H - bottom - top_pad
    slot = (W - left - 8) / len(rows)
    bw = min(24, slot - 2)
    every = max(1, int(len(rows) / 10 + 0.999))
    out = ['<svg class="chart" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, e(aria))]
    for t in ticks:
        y = top_pad + plot_h * (1 - t / ymax)
        out.append('<line class="grid" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (left, W - 8, y, y))
        out.append('<text class="tick" x="%d" y="%.1f" text-anchor="end">%s</text>' % (left - 6, y + 4, e(fmt(t))))
    for i, (label, v, tip) in enumerate(rows):
        x = left + i * slot + (slot - bw) / 2
        h = plot_h * v / ymax
        out.append('<g class="mark"><title>%s</title><rect class="hit" x="%.1f" y="%d" width="%.1f" height="%d"/>'
                   % (e(tip), left + i * slot, top_pad, slot, plot_h))
        if h > 0:
            out.append('<path class="s1" d="%s"/>' % bar_path(x, top_pad + plot_h - h, bw, h, horizontal=False))
        out.append('</g>')
        key = keys[i] if keys else label
        if marks and key in marks:
            cx = x + bw / 2
            out.append('<g class="mark rule"><title>%s</title><line class="rule-mark" x1="%.1f" x2="%.1f" y1="%d" '
                       'y2="%d"/><rect class="hit" x="%.1f" y="%d" width="8" height="%d"/></g>'
                       % (e(marks[key]), cx, cx, top_pad, top_pad + plot_h, cx - 4, top_pad, plot_h))
        if i % every == 0:
            out.append('<text class="tick" x="%.1f" y="%d" text-anchor="middle">%s</text>'
                       % (x + bw / 2, H - 10, e(label)))
    out.append('<line class="axis" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/></svg>'
               % (left, W - 8, top_pad + plot_h, top_pad + plot_h))
    return "".join(out)


def segbar(parts, aria=""):
    """A tall segmented bar of one whole (<= 3 parts, categorical slots 1-3), share printed where it fits."""
    total = sum(v for _, v in parts)
    if not total:
        return '<p class="empty">no data yet</p>'
    W, H = 640, 28
    out = ['<svg class="chart seg" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, e(aria))]
    x = 0.0
    shown = [(n, v) for n, v in parts if v]
    for i, (name, v) in enumerate(shown):
        w = W * v / total
        gap = 2 if i < len(shown) - 1 else 0
        pct = "%.0f%%" % (100.0 * v / total)
        out.append('<g class="mark"><title>%s: %d of %d (%s)</title><rect class="s%d" x="%.1f" y="0" width="%.1f" '
                   'height="%d" rx="4"/>' % (e(name), v, total, pct, i + 1, x, max(w - gap, 0.5), H))
        if w > 44:
            out.append('<text class="inside" x="%.1f" y="18">%s</text>' % (x + 8, pct))
        out.append('</g>')
        x += w
    out.append('</svg><p class="legend">%s</p>' % " ".join(
        '<span><i class="sw s%d"></i>%s %d</span>' % (i + 1, e(n), v) for i, (n, v) in enumerate(shown)))
    return "".join(out)


def meter(value, label):
    if value is None:
        return '<p class="empty">%s</p>' % e(label)
    w = max(0.0, min(1.0, value)) * 640
    return ('<svg class="chart meter" viewBox="0 0 640 12" role="img" aria-label="%s"><title>%s</title>'
            '<rect class="track" x="0" y="0" width="640" height="12" rx="6"/>'
            '<rect class="s1" x="0" y="0" width="%.1f" height="12" rx="6"/></svg><p class="sub">%s</p>'
            % (e(label), e(label), w, e(label)))


def table(head, rows, num_cols=()):
    out = ['<table><thead><tr>%s</tr></thead><tbody>' % "".join("<th>%s</th>" % e(h) for h in head)]
    for r in rows:
        out.append("<tr>%s</tr>" % "".join(
            '<td%s>%s</td>' % (' class="num"' if i in num_cols else "", e(c)) for i, c in enumerate(r)))
    out.append("</tbody></table>")
    return "".join(out) if rows else '<p class="empty">no data yet</p>'


def details(inner, summary="Table"):
    return "<details><summary>%s</summary>%s</details>" % (e(summary), inner)


def tile(label, value, sub):
    return ('<div class="tile"><div class="tl">%s</div><div class="tv">%s</div><div class="ts">%s</div></div>'
            % (e(label), e(value), e(sub)))


# --- the numbers ----------------------------------------------------------------------------------------------

QUEUE_KINDS = "('code', 'tests', 'judge')"


def metrics(db):
    m = {}
    merged = db.q("SELECT repo, branch, rounds, merged_at FROM v_rounds_per_branch ORDER BY merged_at")
    m["merged"] = merged
    rounds = [r[2] for r in merged if r[2] is not None]
    m["n_merged"] = len(merged)
    m["first_pass"] = sum(1 for r in rounds if r == 1)
    m["median_rounds"] = statistics.median(rounds) if rounds else None
    cost = db.one("SELECT SUM(cost_usd), COUNT(*) FROM reviews WHERE kind IN %s" % QUEUE_KINDS) or (None, 0)
    m["review_cost"], m["n_reviews"] = cost[0] or 0.0, cost[1]
    rul = dict((r[0], r[1]) for r in db.q("SELECT ruling, findings FROM v_judge_rulings"))
    m["rulings"] = rul
    m["n_ruled"] = sum(rul.values())
    m["confirmed"] = rul.get("confirmed", 0)
    m["failures"] = db.q("SELECT fail_reason, SUM(failures) FROM v_failures_by_reason GROUP BY fail_reason "
                         "ORDER BY 2 DESC, 1")
    m["n_failed"] = sum(r[1] for r in m["failures"])
    m["escalations"] = db.q("SELECT repo, branch, ended, fail_reason FROM jobs WHERE outcome = 'escalated' "
                            "ORDER BY ended DESC")
    m["categories"] = db.q("SELECT f.category, COUNT(*) FROM findings f JOIN reviews r ON r.id = f.review_id "
                           "WHERE r.kind IN ('code', 'tests') AND f.category IS NOT NULL GROUP BY f.category "
                           "ORDER BY 2 DESC, 1")
    m["levels"] = db.q("SELECT kind, level, COUNT(*), SUM(cost_usd), AVG(cost_usd), SUM(verdict = 'ready') "
                       "FROM reviews GROUP BY kind, level ORDER BY kind, level")
    return m


REASON_ADVICE = {
    "review_code": "the code review keeps finding changes: have agents run /code-review on their branch before "
                   "they queue it",
    "review_tests": "the test review keeps finding changes: add the test review's checks (mutations, missing or "
                    "empty tests) to the agents' instructions",
    "judge": "many rounds end at the judge: look at what it confirms and turn the repeats into agent instructions",
    "conflict": "merge conflicts are common: keep branches small and short-lived, and queue them sooner",
    "checks_failed": "CI checks fail after the PR opens: run the same checks locally before queueing",
    "e2e": "the e2e suite fails in the queue: run the full suite locally before queueing",
    "review_error": "reviews fail to run: look at the review logs (limits, timeouts) before they cost more rounds",
}


def hints(m):
    """Plain-language suggestions from the thresholds above: [(id, text)]."""
    out = []
    if m["n_ruled"] >= MIN_N and m["confirmed"] / m["n_ruled"] < PRECISION_LOW:
        out.append(("precision", "Most blocking findings are downgraded or rejected by the judge (reviewer "
                    "precision %s): tighten what the code review marks important." % share(m["confirmed"], m["n_ruled"])))
    n_cat = sum(c for _, c in m["categories"])
    if m["categories"]:
        cat, c = m["categories"][0]
        if c >= CATEGORY_MIN and c / n_cat >= CATEGORY_SHARE:
            out.append(("category", "[%s] findings keep coming back (%d of %d findings with a category): add a "
                        "rule or agent instruction so branches get it right the first time." % (cat, c, n_cat)))
    for kind, level, n, total, avg, ready in m["levels"]:
        if kind in ("code", "tests") and n >= MIN_N and avg is not None and avg >= AVG_COST_HIGH \
                and (ready or 0) / n >= READY_SHARE_HIGH:
            out.append(("costly-ready", "%s reviews%s cost %s on average and mostly say ready (%s): a lower level "
                        "could do for these branches." % (kind, " at " + level if level else "", money(avg),
                                                          share(ready or 0, n))))
    if m["n_merged"] >= MIN_N and m["first_pass"] / m["n_merged"] < FIRST_PASS_LOW:
        out.append(("first-pass", "Fewer than half of the merged branches got through in their first round "
                    "(first-pass yield %s)." % share(m["first_pass"], m["n_merged"])))
    if m["n_failed"] >= MIN_N and m["failures"]:
        reason, c = m["failures"][0]
        if c / m["n_failed"] >= TOP_REASON_SHARE:
            advice = REASON_ADVICE.get(reason, "look at those rounds for what they have in common")
            out.append(("top-reason", "%s ends %s of the failed rounds: %s." % (reason or "unknown", share(
                c, m["n_failed"]), advice)))
    return out


# --- sections -------------------------------------------------------------------------------------------------

def section(title, body, sid):
    return '<section id="%s"><h2>%s</h2>%s</section>' % (e(sid), e(title), body)


def s_headline(m):
    n = m["n_merged"]
    per = m["review_cost"] / n if n else None
    tiles = [
        tile("Merged branches", compact(n), "from %d review runs" % m["n_reviews"]),
        tile("First-pass yield", share(m["first_pass"], n).split(" (")[0], "merged in 1 round, n=%d" % n),
        tile("Median rounds to merge", "–" if m["median_rounds"] is None else "%g" % m["median_rounds"],
             "n=%d" % n),
        tile("Review cost", money(m["review_cost"]), "%s per merged branch" % money(per)),
        tile("Reviewer precision", share(m["confirmed"], m["n_ruled"]).split(" (")[0],
             "judge-confirmed blocking findings, n=%d" % m["n_ruled"]),
    ]
    return section("Headline", '<div class="tiles">%s</div>' % "".join(tiles), "headline")


def s_rework(db, m):
    dist = {}
    for r in m["merged"]:
        if r[2] is not None:
            dist[r[2]] = dist.get(r[2], 0) + 1
    n = m["n_merged"]
    rows = [(str(k), dist.get(k, 0), "%d round%s: %d branches" % (k, "" if k == 1 else "s", dist.get(k, 0)))
            for k in range(1, max(dist) + 1)] if dist else []
    body = ['<h3>Rounds to merge <span class="n">n=%d</span></h3>' % n,
            '<p class="sub">How many queue rounds each merged branch took.</p>' if n >= MIN_N else
            '<p class="sub">not enough data (n=%d)</p>' % n,
            columns(rows, aria="rounds to merge"),
            details(table(["Rounds", "Branches", "Share"], [(k, v, share(v, n)) for k, v, _ in rows], (0, 1)))]
    nf = m["n_failed"]
    frows = [(r or "unknown", c, "%s: %d (%s)" % (r or "unknown", c, share(c, nf))) for r, c in m["failures"]]
    body += ['<h3>Why rounds failed <span class="n">n=%d</span></h3>' % nf, hbars(frows, aria="failure reasons"),
             details(table(["Reason", "Failed rounds", "Share"], [(r, c, share(c, nf)) for r, c, _ in frows], (1,)))]
    esc = db.q("SELECT repo, branch, merged_at, fixed_by FROM v_escaped_defects ORDER BY merged_at DESC")
    n_esc = sum(1 for r in esc if r[3])
    body += ['<h3>Escaped defects <span class="n">n=%d</span></h3>' % len(esc),
             '<p data-metric="escaped">Escaped rate: %s</p><p class="sub">A merged branch escaped when a fix/ '
             'branch or a revert merged into main within 14 days touches one of its files (from git; a branch merged '
             'less than 14 days ago can still escape).</p>' % e(share(n_esc, len(esc))),
             details(table(["Repo", "Branch", "Merged", "Fixed by"], [(a, b, (c or "")[:10], (d or "")[:12])
                                                                     for a, b, c, d in esc if d]),
                     "Escaped branches (%d)" % n_esc)]
    flaky = db.q("SELECT repo, branch, failed_at, passed_at FROM v_flaky_checks ORDER BY failed_at DESC")
    n_flaky = sum(1 for r in flaky if r[3])
    body += ['<h3>Flaky CI <span class="n">n=%d</span></h3>' % len(flaky),
             '<p data-metric="flaky">Flaky rate: %s</p><p class="sub">A failed CI check run is flaky when the '
             'checks passed later with no new commits: on the same commit, or with the branch queued again at the '
             'same commit.</p>' % e(share(n_flaky, len(flaky))),
             details(table(["Repo", "Branch", "Failed", "Passed"], [(a or "–", b, (c or "")[:16].replace("T", " "),
                                                                    (d or "")[:16].replace("T", " "))
                                                                   for a, b, c, d in flaky if d]),
                     "Flaky runs (%d)" % n_flaky)]
    body += ['<h3>Escalations to you <span class="n">n=%d</span></h3>' % len(m["escalations"]),
             table(["Repo", "Branch", "When", "Reason"], [(a or "–", b, (c or "")[:16].replace("T", " "), d or "–")
                                                          for a, b, c, d in m["escalations"]])]
    return section("Rework", "".join(body), "rework")


SEVERITIES = ("blocker", "major", "minor", "other")


def s_review_value(db, m):
    body = ['<div class="pair">']
    sev = {(k, s): c for k, s, c in db.q("SELECT kind, sev_norm, findings FROM v_findings_by_severity")}
    for kind in ("code", "tests"):
        n = sum(c for (k, _), c in sev.items() if k == kind)
        rows = [(s, sev.get((kind, s), 0), "%s %s findings: %d (%s)" % (kind, s, sev.get((kind, s), 0),
                                                                       share(sev.get((kind, s), 0), n)))
                for s in SEVERITIES] if n else []
        body.append('<div><h3>%s review findings <span class="n">n=%d</span></h3>%s</div>'
                    % ("Code" if kind == "code" else "Test", n, hbars(rows, label_w=70, aria=kind + " findings", W=340)))
    body.append("</div>")
    body.append(details(table(["Kind", "Severity", "Findings"], [(k, s, c) for (k, s), c in sorted(sev.items())], (2,))))
    nr = m["n_ruled"]
    parts = [(r, m["rulings"].get(r, 0)) for r in ("confirmed", "downgraded", "rejected")]
    body += ['<h3>Judge rulings on blocking findings <span class="n">n=%d</span></h3>' % nr,
             segbar(parts, aria="judge rulings") if nr >= MIN_N else '<p class="empty">not enough data (n=%d)</p>' % nr,
             details(table(["Ruling", "Findings", "Share"], [(r, c, share(c, nr)) for r, c in parts], (1,)))]
    mut = db.one("SELECT SUM(mut_tried), SUM(mut_caught), COUNT(mut_tried) FROM reviews WHERE kind = 'tests'") or (0, 0, 0)
    tried, caught = mut[0] or 0, mut[1] or 0
    body += ['<h3>Mutation kill rate <span class="n">n=%d mutants in %d test reviews</span></h3>' % (tried, mut[2] or 0),
             meter(ratio(caught, tried), "%d of %d mutants caught: %s" % (caught, tried, share(caught, tried)))]
    lrows, bars = [], []
    for kind, level, n, total, avg, ready in m["levels"]:
        lrows.append((kind or "–", level or "–", n, money(total), money(avg), share(ready or 0, n),
                      money(total / ready) if ready and total is not None else "–"))
        if total is not None:
            name = " ".join(x for x in (kind, level) if x)
            bars.append((name, total, "%s: %s in %d reviews" % (name, money(total), n)))
    body += ['<h3>Cost per review kind and level</h3>',
             '<p class="sub">Cost per ready verdict: the kind/level\'s whole cost over the reviews that said ready.</p>',
             hbars(sorted(bars, key=lambda b: -b[1]), fmt=money, label_w=120, aria="cost by kind and level"),
             table(["Kind", "Level", "Reviews", "Cost", "Avg", "Said ready", "Cost per ready"], lrows, (2, 3, 4, 6))]
    return section("Review value", "".join(body), "review-value")


def pct(v):
    return "%.0f%%" % (100.0 * v)


def s_tokens(db):
    """stats.py's transcript views: est. $ by role, cache hit rate, subagent share, cost per merged branch."""
    body = ['<p class="sub">From the session transcripts (numbers only). Agent $ is an estimate: tokens at list '
            'prices, not a bill. Roles: main, agent, review, judge, other; subagents count toward their parent.</p>']
    roles = db.q("SELECT role, repo, sessions, subagent_sessions, msgs, tokens_in, tokens_out, tokens_cache_w, "
                 "tokens_cache_r, cost_usd_est, subagent_cost_usd_est, unpriced_msgs FROM v_tokens_by_role "
                 "ORDER BY role, repo")
    body.append("<h3>Estimated $ by role (estimate)</h3>")
    if roles:
        by = {}
        for r in roles:
            b = by.setdefault(r[0], [0.0, 0, 0])
            b[0] += r[9] or 0
            b[1] += r[2] or 0
            b[2] += sum(x or 0 for x in r[5:9])
        body.append(hbars([(k, v[0], "%s: %s estimate, %d sessions, %s tokens" % (k, money(v[0]), v[1], compact(v[2])))
                           for k, v in sorted(by.items(), key=lambda kv: -kv[1][0])],
                          fmt=lambda v: money(v) + " est.", aria="estimated cost by role"))
        unpriced = sum(r[11] or 0 for r in roles)
        if unpriced:
            body.append('<p class="sub">%d messages had no known price and are not in the estimate.</p>' % unpriced)
        body.append(details(table(
            ["Role", "Repo", "Sessions", "Subagent sessions", "Messages", "Tokens in", "Tokens out", "Cache writes",
             "Cache reads", "Est. $ (estimate)", "Subagent est. $ (estimate)", "Unpriced messages"],
            [(r[0], r[1] or "–", r[2], r[3], compact(r[4]), compact(r[5]), compact(r[6]), compact(r[7]),
              compact(r[8]), money(r[9]), money(r[10]), r[11]) for r in roles], set(range(2, 12)))))
    else:
        body.append('<p class="empty">no data yet</p>')
    cache = db.q("SELECT role, tokens_cache_r, tokens_input, cache_hit_rate FROM v_cache_hit_rate ORDER BY role")
    body.append("<h3>Cache hit rate by role</h3>")
    if cache:
        body.append('<p class="sub">Cache reads over all input tokens (fresh, cache writes and cache reads).</p>')
        body.append(hbars([(r[0], 100.0 * (r[3] or 0), "%s: %s of %s input tokens" % (
            r[0], pct(r[3] or 0), compact(r[2]))) for r in cache], fmt=lambda v: "%.0f%%" % v, aria="cache hit rate"))
        body.append(details(table(["Role", "Cache reads", "Input tokens", "Hit rate"],
                                  [(r[0], compact(r[1]), compact(r[2]), "–" if r[3] is None else pct(r[3]))
                                   for r in cache], (1, 2, 3))))
    else:
        body.append('<p class="empty">no data yet</p>')
    sub = db.q("SELECT role, sessions, subagent_sessions, tokens, subagent_token_share, cost_usd_est, "
               "subagent_cost_usd_est, subagent_cost_share FROM v_subagent_share ORDER BY role")
    body.append("<h3>Subagent share</h3>")
    if sub:
        body.append(table(["Role", "Sessions", "Subagent sessions", "Share of tokens", "Share of est. $ (estimate)"],
                          [(r[0], r[1], r[2], "–" if r[4] is None else "%s of %s" % (pct(r[4]), compact(r[3])),
                            "–" if r[7] is None else "%s of %s" % (pct(r[7]), money(r[5]))) for r in sub], (1, 2, 3, 4)))
    else:
        body.append('<p class="empty">no data yet</p>')
    per = db.q("SELECT repo, branch, merged_at, agent_sessions, agent_cost_usd_est, review_cost_usd, judge_cost_usd "
               "FROM v_cost_per_merged_branch ORDER BY merged_at DESC")
    body.append("<h3>Cost per merged branch</h3>")
    if per:
        with_agent = sum(1 for r in per if r[3])
        body.append('<p class="sub">Agent cost found for %d of %d merged branches. A session is linked to a branch by '
                    'its transcript\'s worktree and branch, by a job file\'s worktree, or by the job queued within 10 '
                    'minutes after it ended; the rest can\'t be linked.</p>' % (with_agent, len(per)))
        body.append(details(table(["Repo", "Branch", "Merged", "Agent sessions", "Agent est. $ (estimate)",
                                   "Review $", "Judge $", "Total"],
                          [(r[0], r[1], (r[2] or "")[:10], r[3] or 0,
                            money(r[4]), money(r[5]), money(r[6]),
                            "–" if all(x is None for x in r[4:7]) else money(sum(x or 0 for x in r[4:7])))
                           for r in per], (3, 4, 5, 6, 7)), "Per branch (%d)" % len(per)))
    else:
        body.append('<p class="empty">no data yet</p>')
    return section("Cost and tokens", "".join(body), "tokens")


def s_timeline(db):
    rounds = db.q("SELECT substr(ended, 1, 10), COUNT(*), SUM(outcome = 'merged') FROM jobs WHERE round IS NOT NULL "
                  "AND ended IS NOT NULL GROUP BY 1 ORDER BY 1")
    cost = db.q("SELECT substr(finished, 1, 10), SUM(cost_usd), COUNT(*) FROM reviews WHERE finished IS NOT NULL "
                "AND kind IN %s GROUP BY 1 ORDER BY 1" % QUEUE_KINDS)
    rules = db.q("SELECT substr(ts, 1, 10), repo, sha, subject FROM rule_changes WHERE ts IS NOT NULL ORDER BY ts, repo, sha")
    marks = {}
    for d, repo, sha, subject in rules:
        marks[d] = (marks[d] + "; " if d in marks else "rule change %s: " % d) + "%s %s %s" % (repo, sha, subject)
    body = ['<h3>Rounds per day <span class="n">n=%d</span></h3>' % sum(r[1] for r in rounds),
            '<p class="sub">A dashed line marks a day the rules changed (claude/rules, CLAUDE.md, review.sh, '
            'claude/agents): compare first-pass yield and precision before and after.</p>' if rules else "",
            columns([(d[5:], c, "%s: %d rounds, %d merged" % (d, c, mg or 0)) for d, c, mg in rounds], aria="rounds per day",
                    marks=marks, keys=[d for d, _, _ in rounds]),
            '<h3>Queue review cost per day <span class="n">n=%d reviews (code, tests, judge)</span></h3>' % sum(r[2] for r in cost),
            columns([(d[5:], c or 0, "%s: %s in %d reviews" % (d, money(c), n)) for d, c, n in cost], fmt=money,
                    aria="review cost per day", whole=False),
            details(table(["Day", "Rounds", "Merged"], [(d, c, mg or 0) for d, c, mg in rounds], (1, 2)), "Rounds table"),
            details(table(["Day", "Review cost", "Reviews"], [(d, money(c), n) for d, c, n in cost], (1, 2)), "Cost table"),
            '<h3>Rule changes <span class="n">n=%d</span></h3>' % len(rules),
            details(table(["Day", "Repo", "Commit", "Subject"], rules), "Rule changes (%d)" % len(rules))]
    # A week is the date of its Monday: one row even when it runs into the new year.
    weeks = db.q("SELECT date(ended, 'weekday 0', '-6 days'), COUNT(*), SUM(outcome = 'merged'), "
                 "SUM(outcome = 'merged' AND round = 1) FROM jobs WHERE round IS NOT NULL AND ended IS NOT NULL "
                 "GROUP BY 1 ORDER BY 1")
    wcost = dict(db.q("SELECT date(finished, 'weekday 0', '-6 days'), SUM(cost_usd) FROM reviews WHERE finished IS NOT NULL "
                      "AND kind IN %s GROUP BY 1" % QUEUE_KINDS))
    wrules = dict(db.q("SELECT date(ts, 'weekday 0', '-6 days'), COUNT(*) FROM rule_changes WHERE ts IS NOT NULL "
                       "GROUP BY 1"))
    body.append("<h3>Weekly trend</h3>")
    if len(weeks) >= WEEKS_FOR_TRENDS:
        body.append(table(["Week of", "Rounds", "Merged", "First-pass yield", "Review cost", "Rule changes"],
                          [(w, c, mg or 0, share(fp or 0, mg or 0), money(wcost.get(w)), wrules.get(w, 0))
                           for w, c, mg, fp in weeks], (1, 2, 4, 5)))
    else:
        body.append('<p class="empty">not enough data: weekly trends need %d weeks, there %s %d</p>'
                    % (WEEKS_FOR_TRENDS, "is" if len(weeks) == 1 else "are", len(weeks)))
    return section("Timeline", "".join(body), "timeline")


def s_repos(db):
    rows = db.q("SELECT ifnull(repo, '(unknown)'), COUNT(*), SUM(outcome = 'merged'), "
                "SUM(outcome = 'merged' AND round = 1), SUM(outcome IN ('failed', 'escalated')) "
                "FROM jobs WHERE round IS NOT NULL AND ended IS NOT NULL GROUP BY 1 ORDER BY 1")  # finished rounds
    cost = dict(db.q("SELECT ifnull(repo, '(unknown)'), SUM(cost_usd) FROM reviews WHERE kind IN %s GROUP BY 1"
                     % QUEUE_KINDS))
    med = {}
    for repo, r in db.q("SELECT ifnull(repo, '(unknown)'), rounds FROM v_rounds_per_branch"):
        med.setdefault(repo, []).append(r)
    out = [(repo, n, mg or 0, share(fp or 0, mg or 0), "%g" % statistics.median(med[repo]) if med.get(repo) else "–",
            f or 0, money(cost.get(repo))) for repo, n, mg, fp, f in rows]
    return section("By repo", table(["Repo", "Rounds", "Merged", "First-pass yield", "Median rounds", "Failed rounds",
                                     "Review cost"], out, (1, 2, 4, 5, 6)), "repos")


def s_hints(m):
    hs = hints(m)
    if hs:
        body = '<ul class="hints">%s</ul>' % "".join('<li data-hint="%s">%s</li>' % (e(i), e(t)) for i, t in hs)
    else:
        body = '<p class="empty">Nothing stands out yet (or there is not enough data for the thresholds).</p>'
    return section("What to change", body, "hints")


def s_data(db, path):
    last = db.one("SELECT value FROM meta WHERE key = 'last_ingest'")
    ts = stats.norm_ts(last[0]) if last and isinstance(last[0], str) else None
    if ts:
        when = datetime.datetime.fromtimestamp(stats.epoch(ts)).strftime("%Y-%m-%d %H:%M")
    else:
        try:
            when = datetime.datetime.fromtimestamp(os.stat(path).st_mtime).strftime("%Y-%m-%d %H:%M") + \
                " (the db file's time)"
        except OSError:
            when = "unknown"
    counts = []
    for t in ("jobs", "reviews", "findings", "events_raw", "sessions", "usage_daily", "checks", "main_commits",
              "rule_changes"):
        r = db.one("SELECT COUNT(*) FROM %s" % t) if db.has(t) else None
        counts.append((t, r[0] if r else "no table yet"))
    body = ('<p>Last ingested: %s. Generated %s.</p>%s<p class="sub">The data stays on this '
            'machine: the db and this page live outside any git checkout, and this page loads nothing from the '
            'network.</p>' % (e(when), e(datetime.datetime.now().strftime("%Y-%m-%d %H:%M")),
                              table(["Table", "Rows"], counts, (1,))))
    return section("Data", body, "data")


CSS = """
.viz-root{color-scheme:light;--surface-1:#fcfcfb;--page:#f9f9f7;--text-primary:#0b0b0b;--text-secondary:#52514e;
--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);--series-1:#2a78d6;--series-2:#eb6834;
--series-3:#1baf7a;--track:#cde2fb}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])) .viz-root{color-scheme:dark;
--surface-1:#1a1a19;--page:#0d0d0d;--text-primary:#f0efec;--text-secondary:#c3c2b7;--grid:#2c2c2a;--axis:#383835;
--border:rgba(255,255,255,.10);--series-1:#3987e5;--series-2:#d95926;--series-3:#199e70;--track:#184f95}}
:root[data-theme="dark"] .viz-root{color-scheme:dark;--surface-1:#1a1a19;--page:#0d0d0d;--text-primary:#f0efec;
--text-secondary:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--series-1:#3987e5;
--series-2:#d95926;--series-3:#199e70;--track:#184f95}
body{margin:0;background:var(--page);color:var(--text-primary);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:760px;margin:0 auto;padding:24px 16px 48px}
header{display:flex;align-items:center;gap:14px}.logo{width:96px;height:96px;flex:none}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:0 0 12px}h3{font-size:14px;margin:18px 0 6px}
section{background:var(--surface-1);border:1px solid var(--border);border-radius:8px;padding:16px 18px;margin:16px 0}
.sub,.n,.empty,.legend{color:var(--text-secondary)}.n{font-weight:400;font-size:12px;margin-left:6px}
.empty{font-style:italic}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px}
.tile{border:1px solid var(--border);border-radius:8px;padding:10px 12px}
.tl{color:var(--text-secondary);font-size:12px}.tv{font-size:24px;font-weight:600;margin:2px 0}
.ts{color:var(--muted);font-size:12px}
.chart{width:100%;height:auto;display:block}.chart text{font:12px system-ui,-apple-system,"Segoe UI",sans-serif}
.lbl,.val{fill:var(--text-primary)}.tick{fill:var(--muted);font-variant-numeric:tabular-nums}
.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--axis);stroke-width:1}
.s1{fill:var(--series-1)}.s2{fill:var(--series-2)}.s3{fill:var(--series-3)}.track{fill:var(--track)}
.inside{fill:#fff;font-weight:600}.hit{fill:transparent}.mark:hover path,.mark:hover rect:not(.hit){opacity:.8}
.legend span{margin-right:14px;white-space:nowrap}
.rule-mark{stroke:var(--series-2);stroke-width:2;stroke-dasharray:4 3}
.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
i.s1{background:var(--series-1)}i.s2{background:var(--series-2)}i.s3{background:var(--series-3)}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}@media (max-width:640px){.pair{grid-template-columns:1fr}}
table{border-collapse:collapse;width:100%;margin:6px 0;font-size:13px}
th,td{text-align:left;padding:4px 8px;border-bottom:1px solid var(--grid);overflow-wrap:anywhere}
th{color:var(--text-secondary);font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;overflow-wrap:normal}
details{margin:6px 0}summary{cursor:pointer;color:var(--text-secondary);font-size:12px}
.hints li{margin:6px 0}
@media (forced-colors:active){.s1,.s2,.s3{fill:CanvasText}}
"""


def render(dbpath):
    db = Db(dbpath)
    m = metrics(db)
    parts = [s_headline(m), s_rework(db, m), s_review_value(db, m), s_tokens(db), s_timeline(db), s_repos(db),
             s_hints(m), s_data(db, dbpath)]
    return ('<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; '
            'img-src data:">'
            '<link rel="icon" type="image/png" href="%s">'
            '<title>clauderaptor stats</title><style>%s</style></head><body class="viz-root"><main><header>'
            '<img class="logo" src="%s" alt=""><div>'
            '<h1>clauderaptor: how the PR queue is doing</h1><p class="sub">A round is one run of a branch through '
            'the queue. Shares show their n; below %d they say "not enough data".</p></div></header>%s</main>'
            '</body></html>\n'
            % (png_data("icon.png"), CSS, png_data("logo.png"), MIN_N, "".join(parts)))


def refuse_work_tree(path):
    tree = stats.work_tree_of(path)
    if tree:
        die("refusing to write %s: it is inside the git work tree %s, and the stats never go into a repo. "
            "Use a path outside any checkout (--out or CLAUDERAPTOR_STATS_DIR)." % (path, tree))


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700)
        os.chmod(d, 0o700)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".report-", suffix=".tmp")  # 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# --- --open: an Edge app window -------------------------------------------------------------------------------

def file_url(win):
    r"""A Windows path as a file URL: \\wsl.localhost\Ubuntu\home\a b.html -> file://wsl.localhost/Ubuntu/home/a%20b.html,
    C:\x\y.html -> file:///C:/x/y.html."""
    q = lambda p: urllib.parse.quote(p, safe="")  # noqa: E731
    if win.startswith("\\\\"):
        host, *rest = win[2:].split("\\")
        return "file://%s/%s" % (urllib.parse.quote(host, safe="$"), "/".join(q(p) for p in rest))
    m = re.match(r"^([A-Za-z]):\\(.*)$", win)
    if m:
        return "file:///%s:/%s" % (m.group(1), "/".join(q(p) for p in m.group(2).split("\\")))
    die("cannot make a file URL of the Windows path %r" % win)


def wslpath_w(wslpath, path):
    try:
        out = subprocess.run([wslpath, "-w", path], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as ex:
        die("wslpath -w %s failed: %s" % (path, ex))
    if not out:
        die("wslpath -w %s printed nothing" % path)
    return out


def windows_home(users_root, user):
    if user:
        home = os.path.join(users_root, user)
        if not os.path.isdir(os.path.join(home, *EDGE_FOLDER)):
            die("no Edge folder at %s" % os.path.join(home, *EDGE_FOLDER))
        return home
    try:
        names = sorted(os.listdir(users_root))
    except OSError:
        names = []
    found = [n for n in names if os.path.isdir(os.path.join(users_root, n, *EDGE_FOLDER))]
    if not found:
        die("cannot find your Windows user: no %s/<user>/%s; name it with --windows-user NAME"
            % (users_root, "/".join(EDGE_FOLDER)))
    if len(found) > 1:
        die("several Windows users have an Edge folder (%s); name yours with --windows-user NAME or "
            "CLAUDERAPTOR_WINDOWS_USER=NAME" % ", ".join(found))
    return os.path.join(users_root, found[0])


def open_in_edge(report, user):
    edge = os.environ.get("STATS_EDGE") or EDGE
    wslpath = shutil.which("wslpath")
    if not os.path.isfile(edge) or not wslpath:
        print("report: %s\nreport: open it in a browser (--open starts an Edge app window only under WSL: %s not "
              "found)" % (report, "wslpath" if not wslpath else edge))
        return
    home = windows_home(os.environ.get("STATS_WINDOWS_USERS_DIR") or "/mnt/c/Users", user)
    prof = os.path.join(home, *PROFILE_FOLDER)
    os.makedirs(prof, exist_ok=True)
    args = [edge, "--app=" + file_url(wslpath_w(wslpath, os.path.abspath(report))),
            "--user-data-dir=" + wslpath_w(wslpath, prof), "--no-first-run", "--no-default-browser-check"]
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)
    print("report: %s, opening it in an Edge app window" % report)


def main(argv):
    ap = argparse.ArgumentParser(prog="report.py", description="The stats db as a local, static HTML report.")
    ap.add_argument("--db", default=None, help="the stats db (default: %s)" % stats.default_db())
    ap.add_argument("--out", default=None, help="the HTML file (default: report.html next to the default db)")
    ap.add_argument("--open", action="store_true", help="then open it in an Edge app window (WSL)")
    ap.add_argument("--windows-user", default=os.environ.get("CLAUDERAPTOR_WINDOWS_USER") or None,
                    help="the Windows user whose Edge profile folder to use, when several have one")
    a = ap.parse_args(argv)
    os.umask(0o077)
    dbpath = a.db or stats.default_db()
    out = a.out or os.path.join(os.path.dirname(stats.default_db()), "report.html")
    if not os.path.isfile(dbpath):
        die("no stats db at %s: run apps/stats/stats.py ingest first" % dbpath)
    refuse_work_tree(out)
    write_atomic(out, render(dbpath))
    if a.open:
        open_in_edge(out, a.windows_user)
    else:
        print("report: %s" % out)


if __name__ == "__main__":
    main(sys.argv[1:])
