#!/usr/bin/env bash
# Sniffs a text (a PR body, an agent's report, a review, a brief) for claims that have no evidence at a commit:
#   sniff.sh <file or -> [--brief] [--repo <checkout>] [--commit <rev>] [--session] [--author planner|developer|reviewer]
#   sniff.sh <answer file> --answer <earlier sniff output> [--brief] [--repo <checkout>] [--commit <rev>] [--author ...]
# It reads the text from the file, or from stdin for -. --repo defaults to the checkout of the current folder,
# --commit to that checkout's HEAD (any rev that resolves to a commit). Without --session or --answer it is
# mechanical only: it starts no claude session and reads only the text, the repo's git objects at that commit
# (git ls-tree, cat-file, grep <sha>; never the working tree), the queue's events file ($STATS_EVENTS_FILE, else
# ${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/events.jsonl, as pr-queue.sh writes it), and,
# for a review, its sidecar and sniff.conf (below). It changes nothing: no checkout, no writes to the repo, no
# files left behind.
#
# What it checks, each flag with a severity (hard or soft) and a category:
# - missing reference (hard): a file reference that isn't in the commit's tree. That is a token with a slash
#   and an extension (dir/x.sh), a slash and a first folder that is at the commit's top level (scripts/queue),
#   or no slash and a common file extension (a.js, README.md; not Node.js and the like). A token without a slash
#   matches a file of that name anywhere in the tree, one with a slash a path that ends with it (of path#anchor,
#   the path; Markdown emphasis around a token is dropped). A file:line (a.js:120, a.js:10-20) past the file's
#   last line. A backticked `name()`, or a test_<word> token, that
#   git grep doesn't find at the commit.
# - missing proof (hard): a criterion line (A<n>: ... proven by X, or A<n>: ... X) whose proof X isn't found at
#   the commit: after "proven by", up to the end of its clause, every "quoted name", test_<word>, file:line (checked
#   like a reference) and file, also inside a `backticked command` (several are all checked); with none of them,
#   the first word that isn't a filler (the, a, test, ...). Without "proven by": the line's test_<word> tokens and
#   test files.
#   It is checked whatever marker words (below) the line has. And a "Not proven: none" line while a criterion (its line and
#   the lines under it, up to the next criterion or a blank line) names no test, no file:line and no backticked
#   command.
# - run that didn't happen: by the commit's full sha, exact match only (an agent's commit isn't mapped to the
#   queue's merge commit). An e2e claim ("ran the e2e suite", "e2e passed") is hard on an e2e_finished with
#   rc != 0, or a job_failed with step e2e (not reason moved), at that sha; not flagged on an e2e_finished rc 0
#   at that sha with no later e2e job_failed in the same job; else soft "no record of the run". A "tests pass"
#   claim ("all tests pass", "tests/run.sh passes", "CI is green") is hard on a checks_finished result=fail at
#   that sha, not flagged on result=pass, else soft "no record".
# - weasel words (soft): "should work", "probably", "seems to", "robust" or "comprehensive" in a line that
#   claims something is done, fixed, passing or proven.
# - too good to be true (soft), for a review: the input is a review file <branch>-<sha>-<low|medium|high|xhigh|
#   tests>[-notests].md with its sidecar <review>.json next to it (as review.sh writes them), of kind code or
#   tests, whose verdict is ready. It is flagged when its diff (added plus deleted lines of the sidecar's sha
#   against its merge-base with the default branch: origin/HEAD's, else origin/main, main, origin/master or
#   master) has more lines than max_diff_lines, or its session's duration_ms, cost_usd or num_turns is below that
#   kind's floor (<kind>_min_seconds, _min_cost, _min_turns; a value the sidecar lacks isn't compared). The
#   thresholds are in sniff.conf, next to this script ($SNIFF_CONFIG for another file), read only then: a missing
#   file or value, or a sidecar sha that isn't in the repo, exits 4.
# What it doesn't check mechanically: whether a claim is true beyond these, numbers, whether proof was added by
# the branch, and runs outside the queue (no record, soft).
#
# The session (--session): after the mechanical checks, exactly one fresh claude session, review.sh --sniff (next
# to this script; its model and effort are sniff_model and sniff_effort in review.conf), at the same repo and
# commit. It gets a bundle (in a temp folder, removed afterwards): the author, the text with its line numbers, the
# mechanical flags and the thresholds; its instructions are in sniff.md. It lists the claims, and each one it
# finds too good to be true is a soft "too good to be true" flag; its evidence requests are printed as
# "Request <n> to <author>: <claim> | missing: <...> | answer with: <...>" lines before the Flags line. Requests
# don't change the exit code. The author is --author, else from the input's sidecar (<input without .md>.json):
# kind code or tests is a reviewer, plan a planner. No author, or an unknown one, exits 4; so does a session that
# didn't run ("sniff: the session didn't run: <reason>" on stderr).
# One answer round (--answer <earlier output>): the input is the author's answer to the Request lines of an
# earlier --session output (none there exits 4). It is sniffed mechanically, then one session checks it (the
# author defaults as above, else to the one the requests name). Request <n> is cleared only if the answer has an
# "Answer <n>:" block (up to the next one), no line of that block has a hard flag, and the session says
# "Answered <n>: yes". Each one not cleared is a hard "unsupported after one round" flag naming its claim. It
# prints no Request lines: there is never a second round. sniff.sh doesn't deliver requests or collect answers.
# References it leaves alone (never flagged): absolute paths, ~/ paths, $VAR or ${...} paths, ../ paths, URLs;
# tokens with a placeholder or glob (<...>, ..., *); git ranges (main..HEAD); options (-x); ~~struck-out~~ text;
# and every reference on a line whose prose (not its code spans or paths) says it is new or to be added ("new",
# "add", "adds", "to add", "will add", "create", "creates"; not "added" or "created") or that it is in another repo
# ("another repo", "other repo", "target repo", "outside the repo"). A criterion's proof on such a line is still
# checked.
#
# Brief mode (--brief, for a brief that review.sh --plan wrote, or one edited by hand): a brief plans work and
# proves nothing yet, so it skips the missing proof, "Not proven: none", run and weasel checks, and checks:
# - missing reference (hard), as above, except that the names the brief adds or calls fixtures count as known on
#   every line: the references on a line whose prose has a marker word above ("add", "new", ...), or "fixture",
#   "stub", "example", "for example" or "e.g.". In a criterion, its text before "Check:" and its Check count
#   apart ("Check: add tests/test_x.sh, asserting ..." adds that file), and a fixture marker only before the
#   Check. A criterion (its line and the lines under it, also
#   indented ones after a blank line, up to the next criterion or heading; a "# line" in a ``` or ~~~ fenced code
#   block is no heading, there or for the sections), and the rest of Acceptance criteria,
#   are checked only in its Check: its files and file:lines, not its test names or name()s (planned tests).
# - no real check (hard): a criterion with no "Check:", or whose Check names nothing that can run: a file at the
#   commit or one the brief adds, a `command` whose first word is such a file or a program command -v finds, or
#   a file:line at the commit. A Check that says it is manual ("manual", "manually", "by hand") and names
#   nothing that can run is a soft "manual check" instead.
# - quoted line (hard): a `file:line` followed by a `snippet` (optionally after says, reads, has, holds,
#   contains, shows or is) whose line, at the commit, doesn't have the snippet. Checked on every line of a file
#   at the commit, also on a line that adds names; not on a line in another repo.
# - left out (hard): the changed names are the `name()`s and files at the commit named in the Requirements
#   section (not on a fixture line). For each, git grep -w at the commit finds its references (a file by its
#   path as written or its base name) in files the brief names nowhere (any section, Out of scope included).
#   Each hit's kind is the first that fits: migration (under a migrations/ folder), test (under tests/ or named
#   test_*), doc (*.md), caller (any other file). One flag per name and file, at its first line, worded as the
#   question to the planner ("`export()` is also called from `b.js:12`: in scope or out?"); at most 10 per
#   brief, then a line "(<n> more left-out reference(s) not listed)".
#
# Output: one line per flag, "<hard|soft> <category> (line <n>): <the claim> — <why>", <n> the line in the
# input, then "Flags: <h> hard, <s> soft". Exit 0 = no flags, 1 = soft flags only, 2 = a hard flag,
# 4 = the sniff didn't run (bad arguments, a missing file, not a checkout, an unknown commit, no author or a
# failed session, a missing threshold, or an error in the sniff itself; the reason on stderr).
set -uo pipefail
die() { echo "sniff: $*" >&2; exit 4; }
usage="usage: sniff.sh <file or -> [--brief] [--repo <checkout>] [--commit <rev>] [--session] [--author planner|developer|reviewer] [--answer <earlier sniff output>]"

input="" repo="" rev="" have_input="" brief=0 session=0 author="" answer=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief=1; shift ;;
    --session) session=1; shift ;;
    --author)
      [ $# -ge 2 ] || die "--author needs planner, developer or reviewer. $usage"
      case "$2" in planner|developer|reviewer) author="$2" ;; *) die "unknown author '$2': --author takes planner, developer or reviewer" ;; esac
      shift 2 ;;
    --answer) [ $# -ge 2 ] || die "--answer needs the earlier sniff output. $usage"; answer="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a checkout. $usage"; repo="$2"; shift 2 ;;
    --commit) [ $# -ge 2 ] || die "--commit needs a rev. $usage"; rev="$2"; shift 2 ;;
    -) [ -z "$have_input" ] || die "one input only. $usage"; input=-; have_input=1; shift ;;
    -*) die "unknown option $1. $usage" ;;
    *) [ -z "$have_input" ] || die "one input only. $usage"; input="$1"; have_input=1; shift ;;
  esac
done
[ -n "$have_input" ] || die "$usage"
if [ "$input" != - ] && { [ ! -f "$input" ] || [ ! -r "$input" ]; }; then die "no such file: $input"; fi
if [ -n "$answer" ] && { [ ! -f "$answer" ] || [ ! -r "$answer" ]; }; then die "no such file: $answer"; fi
top="$(git -C "${repo:-.}" rev-parse --show-toplevel 2>/dev/null)" || die "not a git checkout: ${repo:-$PWD}"
sha="$(git -C "$top" rev-parse -q --verify "${rev:-HEAD}^{commit}" 2>/dev/null)" || die "no such commit in $top: ${rev:-HEAD}"
events="${STATS_EVENTS_FILE:-${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/events.jsonl}"
HERE="$(dirname "$(readlink -f "$0")")"

code="$(cat <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile, traceback

# An error in the sniff must never pass for a result: Python exits 1 on an uncaught exception, which is
# "soft flags only" here. Exit 5 instead, which the shell turns into 4 ("the sniff didn't run").
def crashed(kind, value, tb):
    traceback.print_exception(kind, value, tb)
    sys.stderr.flush()
    os._exit(5)
sys.excepthook = crashed

top, sha, events_file, input_path = sys.argv[1:5]
brief = sys.argv[5] == "1"
answer_path, here, conf_path = sys.argv[8], sys.argv[9], sys.argv[10]
session = sys.argv[6] == "1" or bool(answer_path)   # an answer round always runs one session
author = sys.argv[7]
short = sha[:12]
env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")

def stop(why):
    """The sniff didn't run: the reason on stderr, and exit 6, which the shell turns into 4."""
    print(f"sniff: {why}", file=sys.stderr)
    sys.exit(6)

# The input's sidecar (<input without .md>.json, as review.sh writes it), if there is one that is a JSON object.
sidecar_path = "" if input_path == "-" else (input_path[:-3] if input_path.endswith(".md") else input_path) + ".json"
sidecar = None
if sidecar_path and os.path.isfile(sidecar_path):
    try:
        with open(sidecar_path, encoding="utf-8") as f:
            sidecar = json.load(f)
    except (OSError, ValueError):
        sidecar = None
    if not isinstance(sidecar, dict):
        sidecar = None
side_kind = sidecar.get("kind") if sidecar else None

# The earlier round's requests, for --answer: (n, author, the text after "to <author>:").
REQUEST_RE = re.compile(r"^Request (\d+) to (planner|developer|reviewer): (.*)$")
requests = []
if answer_path:
    with open(answer_path, "rb") as f:
        for raw in f.read().decode("utf-8", "replace").splitlines():
            m = REQUEST_RE.match(raw.strip())
            if m:
                requests.append((int(m.group(1)), m.group(2), m.group(3)))
    if not requests:
        stop(f"no Request lines in {answer_path}: an answer round needs the output of a sniff.sh --session run")

if session and not author:
    author = {"code": "reviewer", "tests": "reviewer", "plan": "planner"}.get(side_kind, "")
    if not author and requests:
        author = requests[0][1]
    if not author:
        where = f"no sidecar {sidecar_path} of kind code, tests or plan" if sidecar_path else "the text is from stdin"
        stop(f"no author for the session: give --author planner, developer or reviewer ({where})")

def git(*args):
    return subprocess.run(["git", "-C", top, *args], capture_output=True, env=env)

if input_path == "-":
    text = sys.stdin.buffer.read().decode("utf-8", "replace")
else:
    with open(input_path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
lines = text.splitlines()

files = [p for p in git("ls-tree", "-r", "--name-only", "-z", sha).stdout.decode("utf-8", "replace").split("\0") if p]
fileset = set(files)
dirs = set()
for p in files:
    parts = p.split("/")
    for i in range(1, len(parts)):
        dirs.add("/".join(parts[:i]))
top_entries = {p.split("/")[0] for p in files}

def matches(path):
    """The tracked files (or folders) that a reference names: the exact path, or one ending in /path."""
    path = path.rstrip("/")
    if path in fileset or path in dirs:
        return [path]
    suffix = "/" + path
    return [p for p in files if p.endswith(suffix)] + [d for d in dirs if d.endswith(suffix)]

line_counts = {}
def count_lines(path):
    if path not in line_counts:
        data = git("cat-file", "blob", f"{sha}:{path}").stdout
        n = data.count(b"\n")
        if data and not data.endswith(b"\n"):
            n += 1
        line_counts[path] = n
    return line_counts[path]

grep_cache = {}
def found(word, fixed=False):
    key = (word, fixed)
    if key not in grep_cache:
        args = ["grep", "-q", "-F", "-e", word, sha, "--"] if fixed else ["grep", "-q", "-w", "-F", "-e", word, sha, "--"]
        grep_cache[key] = git(*args).returncode == 0
    return grep_cache[key]

EXTS = set("""sh bash zsh py js mjs cjs ts tsx jsx json jsonl md mdx txt yml yaml toml conf cfg ini env html htm css
scss sql rb go rs java kt c h cc cpp hpp cs php swift lua pl r lock log xml csv tsv svg png jpg jpeg gif webp pdf
vue svelte astro gradle properties service timer desktop ps1 bat cmd mk dockerfile gitignore""".split())
NEW_RE = re.compile(r"\b(new|add|adds|create|creates)\b", re.I)
ELSEWHERE_RE = re.compile(r"\b(another|other|target) repo\b|\boutside the repo\b", re.I)
SPLIT_RE = re.compile(r"[\s\[\]()\"',|=]+")
FILELINE_RE = re.compile(r"^(.+?):(\d+)(?:-(\d+)|:\d+)?$")
TEST_RE = re.compile(r"(?<![\w/.\-])test_\w+(?![\w/\-]|\.\w)")
FUNC_RE = re.compile(r"^(?:[A-Za-z_][\w$]*(?:\.|::))*([A-Za-z_][\w$]*)\(\)$")
CRIT_RE = re.compile(r"^[\s>*+\-]*[*_`]*A(\d+)[*_`]*\s*:")
NOT_PROVEN_NONE_RE = re.compile(r"not proven\s*[*_`]*\s*:\s*[*_`]*\s*none\b", re.I)
PROVEN_BY_RE = re.compile(r"proven by\b(.*)", re.I)
# The end of the proof after "proven by": a ;, a sentence's full stop (not e.g. or i.e.), or a dash between clauses.
PROOF_END_RE = re.compile(r";|(?<!\be\.g)(?<!\bi\.e)\.(?:\s|$)| [—–-] ")
FILLER = {"the", "a", "an", "test", "tests", "unit", "case", "cases", "file", "script", "function", "in", "and", "or",
          "plus", "with", "its", "my", "our", "both", "named", "called"}
E2E_RE = re.compile(r"\b(?:ran|has run|have run|passed)\s+(?:the\s+)?(?:full\s+)?(?:local\s+)?(?:e2e|end-to-end)\b"
                    r"|\b(?:e2e|end-to-end)(?:\s+(?:suite|tests?|run))?\s+(?:passed|passes|pass|is green|are green|succeeded|ran)\b", re.I)
TESTS_PASS_RE = re.compile(r"(?<!e2e\s)(?<!end-to-end\s)\btests?\s+(?:all\s+)?(?:pass|passes|passed|are passing|are green)\b|tests/run\.sh\s+(?:pass|passes|passed)\b"
                           r"|\bCI\s+(?:is\s+|was\s+)?(?:green|passes|passed)\b|\bALL PASSED\b", re.I)
WEASEL_RE = re.compile(r"\b(should work|probably|seems to|robust|comprehensive)\b", re.I)
CLAIM_RE = re.compile(r"\b(done|fixed|fixes|works|working|passing|passes|passed|proven|complete|completed|implemented|resolved)\b", re.I)

def clean(word, code=False):
    """A word without its sentence punctuation and Markdown: trailing .,;:!?, quotes, * and ~~ on either side,
    and _ only in a pair around the word (_a.js_; __init__.py and _config.yml keep theirs). A leading dot stays
    (.github/x, ../x). In a code span only trailing .,;: go. Then ./x is x, and path#anchor is path."""
    if code:
        word = word.strip().rstrip(".,;:")
    else:
        while True:
            before = word
            word = word.strip().rstrip(".,;:!?\"'").lstrip("\"'").strip("*")
            if word.startswith("~~") or word.endswith("~~"):
                word = word.removeprefix("~~").removesuffix("~~")
            for mark in ("__", "_"):
                if len(word) > 2 * len(mark) and word.startswith(mark) and word.endswith(mark):
                    word = word[len(mark):-len(mark)]
                    break
            if word == before:
                break
    if "#" in word[1:]:
        word = word.split("#", 1)[0]
    return word[2:] if word.startswith("./") else word

def skipped(tok):
    return (not tok or tok.startswith(("/", "~", "$", "-", "../")) or "$" in tok or "://" in tok
            or any(c in tok for c in "<>*…") or ".." in tok)

def file_like(tok):
    """A path (without :line) that is meant as a file in the repo."""
    tok = tok[2:] if tok.startswith("./") else tok
    if not re.fullmatch(r"[\w.@+\-/]+", tok) or tok.startswith(".") and "/" not in tok and tok[1:] not in EXTS:
        return None
    base = tok.rstrip("/").split("/")[-1]
    ext = base.rsplit(".", 1)[1] if "." in base[1:] else ""
    if "/" in tok.rstrip("/"):
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9]{0,9}", ext) or tok.split("/")[0] in top_entries:
            return tok
        return None
    if ext.lower() in EXTS and not (ext == "js" and base[:1].isupper()):
        return tok
    return None

def words(line):
    """(word, in a code span) for each word of the line, and the line's code spans."""
    out, spans = [], []
    for i, seg in enumerate(line.split("`")):
        code = i % 2 == 1
        if code:
            spans.append(seg)
        else:
            seg = re.sub(r"~~.*?~~", " ", seg)   # struck-out text is no claim
        for w in SPLIT_RE.split(seg):
            w = clean(w, code)
            if w:
                out.append((w, code))
    return out, spans

def fileline_problem(w):
    """Why a file:line (a.js:120, a.js:10-20) is wrong at the commit, or "" if it is fine."""
    m = FILELINE_RE.match(w)
    path, last = m.group(1), int(m.group(3) or m.group(2))
    cands = [p for p in matches(path) if p in fileset]
    if not cands:
        return f"{path} isn't in the tree at {short}"
    longest = max(cands, key=count_lines)
    if last > count_lines(longest):
        return f"{w}, but {path} has {count_lines(longest)} lines at {short}"
    return ""

def proofs_after(tail):
    """The proofs named after "proven by", up to the end of its clause: "quoted names", test_<word>s, file:lines
    and files (also inside `backticked commands`). Several (test_a and test_b) are all checked. With none of
    those, the first word that isn't a filler (the, a, test, ...) is the proof; a command with none has none."""
    end = PROOF_END_RE.search(tail.lstrip(" :"))
    tail = tail.lstrip(" :")
    tail = tail[:end.start()] if end else tail
    quoted = r'"([^"]+)"|“([^”]+)”'
    proofs = [("quoted", a or b) for a, b in re.findall(quoted, tail)]
    tail = re.sub(quoted, " ", tail)
    first_word = None
    for i, seg in enumerate(tail.split("`")):
        code = i % 2 == 1
        for w in (clean(x, code) for x in SPLIT_RE.split(seg)):
            if not w or skipped(w):
                continue
            fm = FILELINE_RE.match(w)
            if fm and file_like(fm.group(1)):
                proofs.append(("fileline", w))
            elif TEST_RE.fullmatch(w):
                proofs.append(("test", w))
            elif file_like(w):
                proofs.append(("file", w))
            elif first_word is None and w.lower() not in FILLER:
                first_word = "" if code and len(seg.split()) > 1 else w
    if not proofs and first_word:
        proofs.append(("word", first_word))
    return proofs

def is_test_file(tok):
    return bool(re.search(r"(^|/)(tests?|spec|__tests__)/|(^|/)test_[^/]*$|[._-](test|spec)\.\w+$|_test\.\w+$", tok))

def has_evidence(block):
    for line in block:
        if TEST_RE.search(line) or re.search(r"proven by", line, re.I):
            return True
        ws, spans = words(line)
        for w, _ in ws:
            m = FILELINE_RE.match(w)
            if m and file_like(m.group(1)):
                return True
            if file_like(w) and is_test_file(w):
                return True
        if any(" " in s.strip() or re.search(r"\.(sh|py|mjs|js|ts)$", s.strip()) for s in spans):
            return True
    return False

flags = []
def flag(sev, cat, n, claim, why):
    item = (sev, cat, n, claim, why)
    if item not in flags:
        flags.append(item)

def claim_of(line):
    s = line.strip()
    return s if len(s) <= 120 else s[:117] + "..."

# Run records at the commit, from the queue's events file (one JSON object per line).
records = []
try:
    with open(events_file, encoding="utf-8", errors="replace") as f:
        for raw in f:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if isinstance(ev, dict) and ev.get("sha") == sha:
                records.append(ev)
except OSError:
    pass

def e2e_state():
    for ev in records:
        if ev.get("event") == "e2e_finished" and ev.get("rc") != 0:
            return "fail", f"e2e_finished rc {ev.get('rc')} at {short}"
        if ev.get("event") == "job_failed" and ev.get("step") == "e2e" and ev.get("reason") != "moved":
            return "fail", f"job_failed e2e/{ev.get('reason')} at {short}"
    for ev in records:
        if ev.get("event") == "e2e_finished" and ev.get("rc") == 0:
            return "pass", ""
    return "none", f"no record of the run at {short} in the queue's events"

def checks_state():
    results = [ev.get("result") for ev in records if ev.get("event") == "checks_finished"]
    if "fail" in results:
        return "fail", f"checks_finished result=fail at {short}"
    if "pass" in results:
        return "pass", ""
    return "none", f"no record of the checks at {short} in the queue's events"

# Criteria blocks, for "Not proven: none".
crit_blocks = []
for n, line in enumerate(lines):
    m = CRIT_RE.match(line)
    if m:
        crit_blocks.append([m.group(1), n, [line]])
    elif (crit_blocks and line.strip() and not line.lstrip().startswith("#") and not NOT_PROVEN_NONE_RE.search(line)
          and crit_blocks[-1][1] + len(crit_blocks[-1][2]) == n):
        crit_blocks[-1][2].append(line)
not_proven_none = [n for n, line in enumerate(lines) if NOT_PROVEN_NONE_RE.search(line)]


# --- brief mode (--brief) ---
FIXTURE_RE = re.compile(r"\b(fixture|stub|example|for example)\b", re.I)
FENCE_RE = re.compile(r"^\s*(```|~~~)")
EG_RE = re.compile(r"(?<!\w)e\.g\.", re.I)
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*$")
# "Check:", "Checks:", or "Check (manual, after the PR opens):": the parenthetical is part of the Check's text.
CHECK_RE = re.compile(r"[*_`]*\bchecks?\s*(\([^)\n]*\))?\s*[*_`]*\s*:[*_`]*", re.I)
MANUAL_RE = re.compile(r"\b(manual|manually|by hand)\b", re.I)
CONNECT = r"\s*(?:(?:says|reads|has|holds|contains|shows|is)\s*)?:?\s*"
CONNECT_RE = re.compile(rf"^{CONNECT}$")
LOC_TAIL_RE = re.compile(rf"(?:^|[\s(\[])([\w./@+\-]+:\d+(?:-\d+)?){CONNECT}$")
LOC_RE = re.compile(r"^(.+?):(\d+)(?:-(\d+))?$")
LEFT_OUT_CAP = 10

def prose_of(line):
    """The line's prose: no code spans, no paths (scripts/new.sh isn't "new")."""
    return re.sub(r"\S*[./]\w\S*", " ", re.sub(r"`[^`]*`", " ", line))

def is_fixture_line(line):
    return bool(FIXTURE_RE.search(prose_of(line)) or EG_RE.search(re.sub(r"`[^`]*`", " ", line)))

def names_on(line):
    """The names a line gives: files and file:lines (as written), test_<word>s, and fn:<name> for a `name()`."""
    ws, spans = words(line)
    out = set()
    for w, _ in ws:
        if skipped(w):
            continue
        m = FILELINE_RE.match(w)
        if (m and file_like(m.group(1))) or file_like(w):
            out.add(w)
    out.update(TEST_RE.findall(line))
    for sp in spans:
        fm = FUNC_RE.match(sp.strip())
        if fm:
            out.add("fn:" + fm.group(1))
    return out

def quoted_pairs(text):
    """(file:line, snippet) for each `snippet` right after a file:line (a code span or not), maybe after says,
    reads, has, holds, contains, shows or is, or a colon."""
    segs, out = text.split("`"), []
    last = len(segs) - 1   # a code span at index j (odd) is closed when j < last
    for j, seg in enumerate(segs):
        if j % 2 and j + 2 < last and LOC_RE.match(seg.strip()) and CONNECT_RE.match(segs[j + 1]):
            out.append((seg.strip(), segs[j + 2]))
        elif not j % 2 and j + 1 < last:
            m = LOC_TAIL_RE.search(seg)
            if m:
                out.append((m.group(1), segs[j + 1]))
    return out

def command_heads(text):
    """The text with each `command` (a code span with spaces) cut to its first word: in a Check, a command's
    target is what runs, not its arguments."""
    return re.sub(r"`([^`]*)`", lambda m: "`" + (m.group(1).split() or [""])[0] + "`", text)

def tracked(path):
    return [p for p in matches(path) if p in fileset]

blob_cache = {}
def blob_lines(path):
    if path not in blob_cache:
        blob_cache[path] = git("cat-file", "blob", f"{sha}:{path}").stdout.decode("utf-8", "replace").splitlines()
    return blob_cache[path]

def brief_sniff():
    # heading[i]: line i is a heading, not a "# comment" in a ``` or ~~~ fenced code block (fence lines included)
    heading, fence = [], None
    for line in lines:
        fm = FENCE_RE.match(line)
        if fence is None and fm:
            fence = fm.group(1); heading.append(False)
        elif fence is not None:
            if fm and fm.group(1) == fence:
                fence = None
            heading.append(False)
        else:
            heading.append(bool(HEADING_RE.match(line)))
    section, cur = [], ""
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line) if heading[i] else None
        if m:
            cur = m.group(1).strip("*_: ").lower()
        section.append(cur)

    # Criteria blocks: the A<n>: line, then the lines under it up to the next criterion or heading; after a blank
    # line, only an indented line goes on (e.g. a Check under a list of sub-points).
    blocks, block_of, cur, gap = [], {}, None, False
    for i, line in enumerate(lines):
        m = CRIT_RE.match(line)
        if m:
            cur = ["A" + m.group(1), i, [i]]; blocks.append(cur); block_of[i] = cur; gap = False
        elif cur is None:
            continue
        elif heading[i]:
            cur = None
        elif not line.strip():
            if gap:
                cur = None
            gap = True
        elif not gap or line[:1].isspace():
            cur[2].append(i); block_of[i] = cur; gap = False
        else:
            cur = None
    blocks_list = blocks

    # The Check text of each criterion line: from "Check:" on, and every line of the block after it.
    # pre_check: the text of a criterion's lines before its Check, where a fixture marker counts.
    check_text, block_check, pre_check = {}, {}, {}
    for b in blocks_list:
        crit, start, idx = b
        parts, started = [], False
        for i in idx:
            if started:
                check_text[i] = lines[i]; parts.append(lines[i]); continue
            m = CHECK_RE.search(lines[i])
            if m:
                started = True
                check_text[i] = (m.group(1) or "") + " " + lines[i][m.end():]
                parts.append(check_text[i]); pre_check[i] = lines[i][:m.start()]
            else:
                pre_check[i] = lines[i]
        block_check[start] = "\n".join(parts) if started else None

    in_crit = lambda i: i in block_of or section[i] == "acceptance criteria"

    # Known names: the ones a line says it adds, or calls fixtures, stubs or examples. In a criterion, its text
    # before the Check and its Check count apart: a marker in one makes only the names in that one known (a
    # fixture marker only before the Check), so "Check: add tests/test_x.sh, asserting ..." adds the file.
    known, fixture_lines = set(), set()
    for i, line in enumerate(lines):
        if in_crit(i):
            before = pre_check.get(i, "")
            if is_fixture_line(before) or NEW_RE.search(prose_of(before)):
                known.update(names_on(before))
            if i in check_text and NEW_RE.search(prose_of(check_text[i])):
                known.update(names_on(check_text[i]))
            continue
        fx = is_fixture_line(line)
        if fx:
            fixture_lines.add(i)
        if fx or NEW_RE.search(prose_of(line)):
            known.update(names_on(line))

    def can_run(text):
        ws, spans = words(text)
        for w, _ in ws:
            if skipped(w):
                continue
            m = FILELINE_RE.match(w)
            if m and file_like(m.group(1)):
                if not fileline_problem(w):
                    return True
            elif file_like(w) and (tracked(w) or w in known):
                return True
        for sp in spans:
            parts = sp.split()
            if not parts:
                continue
            first = clean(parts[0], True)
            if (file_like(first) and (tracked(first) or first in known)) or (not skipped(first) and shutil.which(first)):
                return True
        return False

    # missing reference and quoted line, line by line
    for i, line in enumerate(lines):
        n = i + 1
        if in_crit(i):
            if i not in check_text:
                continue
            text, crit_line = command_heads(check_text[i]), True
        else:
            # A line in another repo isn't checked here. A line that adds names isn't skipped: its names are
            # known, and its quoted lines of files at the commit are still checked.
            if ELSEWHERE_RE.search(prose_of(line)):
                continue
            text, crit_line = line, False
        ws, spans = words(text)
        for w, _ in ws:
            if skipped(w) or w in known:
                continue
            m = FILELINE_RE.match(w)
            if m and file_like(m.group(1)):
                why = fileline_problem(w)
                if why:
                    flag("hard", "missing reference", n, w, why)
                continue
            if file_like(w) and not matches(w):
                flag("hard", "missing reference", n, w, f"{w} isn't in the tree at {short}")
        if not crit_line:
            for t in TEST_RE.findall(text):
                if t not in known and not found(t):
                    flag("hard", "missing reference", n, t, f"git grep doesn't find {t} at {short}")
            for sp in spans:
                fm = FUNC_RE.match(sp.strip())
                if fm and "fn:" + fm.group(1) not in known and not found(fm.group(1)):
                    flag("hard", "missing reference", n, sp.strip(), f"git grep doesn't find {fm.group(1)} at {short}")
        for loc, snip in quoted_pairs(check_text[i] if crit_line else text):
            lm = LOC_RE.match(loc)
            path, a, b = lm.group(1), int(lm.group(2)), int(lm.group(3) or lm.group(2))
            if not file_like(path):
                continue  # ($VAR, ~/ and ../ paths have no tracked file either: left alone below, as a file the brief adds)
            cands = tracked(path)
            if not cands or b > max(len(blob_lines(c)) for c in cands):
                continue  # a missing reference, flagged above
            if not any(snip in l for c in cands for l in blob_lines(c)[a - 1:b]):
                where = f"line {a}" if a == b else f"lines {a}-{b}"
                flag("hard", "quoted line", n, f"{loc} `{snip}`", f"{where} of {path} doesn't have `{snip}` at {short}")

    # no real check
    for crit, start, idx in blocks_list:
        text = block_check[start]
        if text is None:
            flag("hard", "no real check", start + 1, claim_of(lines[start]), f"{crit} has no Check")
        elif not can_run(text):
            if MANUAL_RE.search(text):
                flag("soft", "manual check", start + 1, claim_of(lines[start]), f"{crit}'s Check is manual: nothing runs it")
            else:
                flag("hard", "no real check", start + 1, claim_of(lines[start]), f"{crit}'s Check names nothing that can run")

    # left out: references to the changed names in files the brief names nowhere
    named = set()
    for line in lines:
        ws, _ = words(line)
        for w, _ in ws:
            if skipped(w):
                continue
            m = FILELINE_RE.match(w)
            p = m.group(1) if m and file_like(m.group(1)) else w if file_like(w) else None
            if p:
                named.update(tracked(p))
    changed, seen = [], set()
    for i, line in enumerate(lines):
        if section[i] != "requirements" or i in fixture_lines or in_crit(i):
            continue
        ws, spans = words(line)
        for sp in spans:
            fm = FUNC_RE.match(sp.strip())
            if fm and ("fn", fm.group(1)) not in seen and found(fm.group(1)):
                seen.add(("fn", fm.group(1))); changed.append(("fn", fm.group(1), f"`{sp.strip()}`", i + 1))
        for w, _ in ws:
            if skipped(w):
                continue
            m = FILELINE_RE.match(w)
            p = m.group(1) if m and file_like(m.group(1)) else w if file_like(w) else None
            key = ("file", frozenset(tracked(p))) if p else None   # review.sh and scripts/queue/review.sh: one name
            if p and key[1] and key not in seen:
                seen.add(key); changed.append(("file", p, f"`{p}`", i + 1))
    left, hit_seen = [], set()
    for kind, name, disp, n in changed:
        pats = [name] if kind == "fn" else sorted({name, name.rstrip("/").split("/")[-1]})
        args = ["grep", "-n", "-w", "-F"]
        for pat in pats:
            args += ["-e", pat]
        first = {}
        for raw in git(*args, sha, "--").stdout.decode("utf-8", "replace").splitlines():
            rest = raw[len(sha) + 1:] if raw.startswith(sha + ":") else raw
            bits = rest.split(":", 2)
            if len(bits) < 3 or not bits[1].isdigit() or bits[0] in named:
                continue
            first.setdefault(bits[0], int(bits[1]))
        for path, ln in first.items():
            # one flag per name and file: two spellings of a file (review.sh, scripts/queue/review.sh) are one name
            key = (kind, name if kind == "fn" else name.rstrip("/").split("/")[-1], path)
            if key in hit_seen:
                continue
            hit_seen.add(key)
            parts = path.split("/")
            if "migrations" in parts[:-1]:
                what = "is also used by the migration"
            elif "tests" in parts[:-1] or parts[-1].startswith("test_"):
                what = "is also used by the test"
            elif path.endswith(".md"):
                what = "is also named in the doc"
            else:
                what = "is also called from" if kind == "fn" else "is also used by"
            left.append((n, disp, f"{disp} {what} `{path}:{ln}`: in scope or out?"))
    for n, disp, why in left[:LEFT_OUT_CAP]:
        flag("hard", "left out", n, disp, why)
    return max(0, len(left) - LEFT_OUT_CAP)

more = brief_sniff() if brief else 0

for n, line in enumerate(lines if not brief else [], 1):
    # The marker words count in the prose only: not in code spans or paths (scripts/new.sh isn't "new").
    prose = re.sub(r"\S*[./]\w\S*", " ", re.sub(r"`[^`]*`", " ", line))
    leave = bool(NEW_RE.search(prose) or ELSEWHERE_RE.search(prose))
    ws, spans = words(line)
    proof_flagged = set()

    # missing proof: a criterion's proof that isn't at the commit
    if CRIT_RE.match(line):
        crit = "A" + CRIT_RE.match(line).group(1)
        m = PROVEN_BY_RE.search(line)
        proofs = []
        if m:
            proofs = proofs_after(m.group(1))
        else:
            proofs += [("test", t) for t in TEST_RE.findall(line)]
            proofs += [("file", w) for w, _ in ws if not skipped(w) and file_like(w) and is_test_file(w)]
        for kind, p in proofs:
            if kind == "fileline":
                why = fileline_problem(p)
            elif (bool(matches(p)) if kind == "file" else found(p, fixed=True) if kind == "quoted" else found(p)):
                why = ""
            else:
                why = f"{p} isn't found at {short}"
            if why:
                flag("hard", "missing proof", n, claim_of(line), f"{crit}'s proof {why}")
                proof_flagged.add(p)

    # missing reference
    if not leave:
        for w, code in ws:
            if skipped(w) or w in proof_flagged:
                continue
            m = FILELINE_RE.match(w)
            if m and file_like(m.group(1)):
                why = fileline_problem(w)
                if why:
                    flag("hard", "missing reference", n, w, why)
                continue
            if file_like(w) and not matches(w):
                flag("hard", "missing reference", n, w, f"{w} isn't in the tree at {short}")
        for t in TEST_RE.findall(line):
            if t not in proof_flagged and not found(t):
                flag("hard", "missing reference", n, t, f"git grep doesn't find {t} at {short}")
        for s in spans:
            fm = FUNC_RE.match(s.strip())
            if fm and not found(fm.group(1)):
                flag("hard", "missing reference", n, s.strip(), f"git grep doesn't find {fm.group(1)} at {short}")

    # runs that didn't happen
    if E2E_RE.search(line):
        state, why = e2e_state()
        if state == "fail":
            flag("hard", "run that didn't happen", n, claim_of(line), why)
        elif state == "none":
            flag("soft", "run that didn't happen", n, claim_of(line), why)
    if TESTS_PASS_RE.search(line):
        state, why = checks_state()
        if state == "fail":
            flag("hard", "run that didn't happen", n, claim_of(line), why)
        elif state == "none":
            flag("soft", "run that didn't happen", n, claim_of(line), why)

    # weasel words in a line that claims something is done
    wm = WEASEL_RE.search(line)
    if wm and CLAIM_RE.search(line):
        flag("soft", "weasel words", n, claim_of(line), f'"{wm.group(1)}" in a claim that something is done')

# "Not proven: none" while a criterion names no proof
if not_proven_none and not brief:
    for crit, start, block in crit_blocks:
        if not has_evidence(block):
            flag("hard", "missing proof", start + 1, claim_of(block[0]),
                 f"Not proven: none (line {not_proven_none[0] + 1}), but A{crit} names no test, file:line or command")

# --- too good to be true: a ready review, against sniff.conf's thresholds ---
CONF_KEYS = ["max_diff_lines", "code_min_seconds", "code_min_cost", "code_min_turns",
             "tests_min_seconds", "tests_min_cost", "tests_min_turns"]
REVIEW_NAME_RE = re.compile(r"^.+-[0-9a-f]{7,40}-(?:low|medium|high|xhigh|tests)(?:-notests)?\.md$")
VERDICT_RE = re.compile(r"verdict:[\s*_`]*(ready|needs changes|escalate|questions|failed)", re.I)

def read_conf(strict):
    """sniff.conf's values, sourced in bash (only the file's values count, not the environment's). Strict: a
    missing file or value, or one that isn't a number, stops the sniff; else they are left out."""
    if not os.path.isfile(conf_path):
        if strict:
            stop(f"no thresholds file: {conf_path} (sniff.conf, or $SNIFF_CONFIG)")
        return {}
    script = 'for k in "${@:2}"; do unset "$k"; done; . "$1" >/dev/null || exit 3; for k in "${@:2}"; do printf "%s=%s\\n" "$k" "${!k-}"; done'
    r = subprocess.run(["bash", "-c", script, "_", conf_path, *CONF_KEYS], capture_output=True)
    if r.returncode != 0:
        if strict:
            stop(f"can't read {conf_path}")
        return {}
    vals = {}
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        k, _, v = line.partition("=")
        try:
            vals[k] = float(v)
        except ValueError:
            if strict:
                stop(f"no {k} in {conf_path}" if not v else f"{k} in {conf_path} must be a number, not '{v}'")
    return vals

def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

def plain(v):
    """A number as written: 4, 29.999, 1039."""
    return f"{v:g}"

def money(v):
    return f"${v:.2f}" if abs(v * 100 - round(v * 100)) < 1e-9 else f"${v:g}"

def plural(n, word):
    return f"{plain(n)} {word}{'' if n == 1 else 's'}"

def review_check():
    if (input_path == "-" or not REVIEW_NAME_RE.match(os.path.basename(input_path)) or not sidecar
            or side_kind not in ("code", "tests") or sidecar.get("verdict") != "ready"):
        return
    conf = read_conf(True)
    rsha = sidecar.get("sha")
    if not isinstance(rsha, str) or not rsha:
        stop(f"the review's sidecar {sidecar_path} has no sha")
    full = git("rev-parse", "-q", "--verify", f"{rsha}^{{commit}}")
    if full.returncode != 0:
        stop(f"the review's commit isn't in {top}: {rsha} (from {sidecar_path})")
    rsha = full.stdout.decode().strip()
    against = ""
    head = git("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD").stdout.decode().strip()
    for c in (head, "origin/main", "main", "origin/master", "master"):
        if c and git("rev-parse", "-q", "--verify", f"{c}^{{commit}}").returncode == 0:
            against = c
            break
    if not against:
        stop(f"no default branch (origin/HEAD, main or master) in {top} to measure the review's diff against")
    mb = git("merge-base", against, rsha)
    if mb.returncode != 0:
        stop(f"the review's commit {rsha[:12]} has no common history with {against}")
    size = 0
    for row in git("diff", "--numstat", mb.stdout.decode().strip(), rsha).stdout.decode("utf-8", "replace").splitlines():
        added, deleted = row.split("\t")[:2]
        if added != "-":   # a binary file has no lines
            size += int(added) + int(deleted)
    k = side_kind
    secs = num(sidecar.get("duration_ms"))
    secs = secs / 1000 if secs is not None else None
    cost, turns = num(sidecar.get("cost_usd")), num(sidecar.get("num_turns"))
    floor_s, floor_c, floor_t = conf[f"{k}_min_seconds"], conf[f"{k}_min_cost"], conf[f"{k}_min_turns"]
    if not (size > conf["max_diff_lines"] or (secs is not None and secs < floor_s)
            or (cost is not None and cost < floor_c) or (turns is not None and turns < floor_t)):
        return
    vn = [i for i, line in enumerate(lines) if VERDICT_RE.search(line)]
    n = vn[-1] + 1 if vn else 1
    claim = claim_of(lines[n - 1]) if lines else "(empty review)"
    flag("soft", "too good to be true", n, claim,
         f"no findings on a {size}-line diff in {plain(secs) if secs is not None else '?'} s, "
         f"{money(cost) if cost is not None else '$?'}, {plural(turns, 'turn') if turns is not None else '? turns'}; "
         f"thresholds: {plain(conf['max_diff_lines'])} lines, {plain(floor_s)} s, {money(floor_c)}, "
         f"{plural(floor_t, 'turn')} ({k} review)")

review_check()

# --- the session (--session, --answer): one review.sh --sniff ---
CLAIM_RE_S = re.compile(r"^[\s>*_`\-]*Claim \(line (\d+)\):\s*(.*)$")
TOO_GOOD_RE = re.compile(r"\|\s*too good to be true:\s*(.*?)\s*[*_`]*$", re.I)
REQ_OUT_RE = re.compile(r"^[\s>*_`\-]*Request to [\w-]+:\s*(.*?)\s*$")
ANSWERED_RE = re.compile(r"^[\s>*_`\-]*Answered (\d+):[*_`\s]*(yes|no)\b[\s—–-]*(.*?)\s*$", re.I)
ANSWER_RE = re.compile(r"^[\s>*_`\-]*Answer (\d+)\s*:")

def run_session(bundle_text):
    """The session's result text. The bundle goes in a temp folder, removed afterwards."""
    tmp = tempfile.mkdtemp(prefix="sniff-")
    try:
        bundle = os.path.join(tmp, "bundle.md")
        with open(bundle, "w", encoding="utf-8") as f:
            f.write(bundle_text)
        r = subprocess.run(["bash", os.path.join(here, "review.sh"), "--sniff", top, sha, bundle],
                           stdin=subprocess.DEVNULL, capture_output=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode != 0:
        err = [l for l in r.stderr.decode("utf-8", "replace").splitlines() if l.strip()]
        reason = err[-1].removeprefix("review: ") if err else f"review.sh --sniff exited {r.returncode}"
        stop(f"the session didn't run: {reason}")
    return r.stdout.decode("utf-8", "replace")

def bundle_of(mode, text_lines, mech, extra=""):
    conf = read_conf(False)
    th = ", ".join(f"{k}={plain(conf[k])}" for k in CONF_KEYS if k in conf) or f"none ({conf_path} not read)"
    numbered = "\n".join(f"{i}: {l}" for i, l in enumerate(text_lines, 1))
    return (f"Mode: {mode}\nAuthor: {author}\nRepo: {top}, commit {sha}\n"
            f"Input: {'stdin' if input_path == '-' else input_path}\nThresholds ({conf_path}): {th}\n{extra}\n"
            f"## The text, with its line numbers\n\n{numbered}\n\n"
            f"## The mechanical flags (sniff.sh)\n\n{mech or 'none'}\n")

def flag_lines():
    return "\n".join(f"{sev} {cat} (line {n}): {claim} — {why}" for sev, cat, n, claim, why in sorted(flags, key=lambda f: f[2]))

out_requests = []
if session and not answer_path:
    result = run_session(bundle_of("claims", lines, flag_lines()))
    for raw in result.splitlines():
        m = CLAIM_RE_S.match(raw)
        if m:
            tg = TOO_GOOD_RE.search(m.group(2))
            why = tg.group(1).strip() if tg else ""
            if why and why.lower().rstrip(".") != "no":
                claim = m.group(2).split("|")[0].strip()
                flag("soft", "too good to be true", int(m.group(1)), claim_of(claim), why)
            continue
        m = REQ_OUT_RE.match(raw)
        if m and m.group(1):
            out_requests.append(m.group(1))
elif answer_path:
    reqs = "\n".join(f"Request {n} to {a}: {t}" for n, a, t in requests)
    result = run_session(bundle_of("answer", lines, flag_lines(), f"\n## The requests of the earlier round ({answer_path})\n\n{reqs}\n"))
    said = {}
    for raw in result.splitlines():
        m = ANSWERED_RE.match(raw)
        if m:
            said.setdefault(int(m.group(1)), (m.group(2).lower() == "yes", m.group(3)))
    # Answer <n>: blocks, from their line up to the next one; the lines with a hard flag.
    blocks, cur = {}, None
    for i, line in enumerate(lines, 1):
        m = ANSWER_RE.match(line)
        if m:
            cur = int(m.group(1))
            blocks.setdefault(cur, [i, i])
        if cur is not None:
            blocks[cur][1] = i
    hard_lines = {f[2] for f in flags if f[0] == "hard"}
    for n, a, text in requests:
        claim = claim_of(text.split(" | ")[0].strip())
        if n not in blocks:
            flag("hard", "unsupported after one round", 1, claim, f"Request {n} has no Answer {n}: block")
            continue
        start, end = blocks[n]
        bad = sorted(h for h in hard_lines if start <= h <= end)
        ok, why = said.get(n, (False, "the session didn't answer for it"))
        if bad:
            flag("hard", "unsupported after one round", start, claim,
                 f"Answer {n} has a hard flag (line {', line '.join(map(str, bad))})")
        elif not ok:
            flag("hard", "unsupported after one round", start, claim,
                 f"the session found the evidence missing in Answer {n}: {why or 'no reason given'}")

flags.sort(key=lambda f: f[2])
for sev, cat, n, claim, why in flags:
    print(f"{sev} {cat} (line {n}): {claim} — {why}")
if more:
    print(f"({more} more left-out reference{' was' if more == 1 else 's were'} not listed)")
for i, text in enumerate(out_requests, 1):
    print(f"Request {i} to {author}: {text}")
hard = sum(1 for f in flags if f[0] == "hard")
soft = len(flags) - hard
print(f"Flags: {hard} hard, {soft} soft")
sys.exit(2 if hard else 1 if soft else 0)
PY
)"
python3 -I -c "$code" "$top" "$sha" "$events" "$input" "$brief" "$session" "$author" "$answer" "$HERE" \
  "${SNIFF_CONFIG:-$HERE/sniff.conf}"
rc=$?
# 6: the sniff didn't run, and it said why on stderr
case "$rc" in 0|1|2) exit "$rc" ;; 6) exit 4 ;; *) die "the sniff failed (python exit $rc)" ;; esac
