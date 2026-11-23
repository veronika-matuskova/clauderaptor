#!/usr/bin/env bash
# Sniffs a text (a PR body, an agent's report, a review, a brief) for claims that have no evidence at a commit:
#   sniff.sh <file or -> [--repo <checkout>] [--commit <rev>]
# It reads the text from the file, or from stdin for -. --repo defaults to the checkout of the current folder,
# --commit to that checkout's HEAD (any rev that resolves to a commit). Mechanical only: it starts no claude
# session and reads only three things: the text, the repo's git objects at that commit (git ls-tree, cat-file,
# grep <sha>; never the working tree), and the queue's events file ($STATS_EVENTS_FILE, else
# ${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/events.jsonl, as pr-queue.sh writes it). It
# changes nothing: no checkout, no writes to the repo, no files left behind.
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
# What it doesn't check: whether a claim is true beyond these (no session, no "too good to be true"), numbers,
# whether proof was added by the branch, and runs outside the queue (no record, soft).
# References it leaves alone (never flagged): absolute paths, ~/ paths, $VAR or ${...} paths, ../ paths, URLs;
# tokens with a placeholder or glob (<...>, ..., *); git ranges (main..HEAD); options (-x); ~~struck-out~~ text;
# and every reference on a line whose prose (not its code spans or paths) says it is new or to be added ("new",
# "add", "adds", "to add", "will add", "create", "creates"; not "added" or "created") or that it is in another repo
# ("another repo", "other repo", "target repo", "outside the repo"). A criterion's proof on such a line is still
# checked.
#
# Output: one line per flag, "<hard|soft> <category> (line <n>): <the claim> — <why>", <n> the line in the
# input, then "Flags: <h> hard, <s> soft". Exit 0 = no flags, 1 = soft flags only, 2 = a hard flag,
# 4 = the sniff didn't run (bad arguments, a missing file, not a checkout, an unknown commit, or an error in the
# sniff itself; the reason on stderr).
set -uo pipefail
die() { echo "sniff: $*" >&2; exit 4; }
usage="usage: sniff.sh <file or -> [--repo <checkout>] [--commit <rev>]"

input="" repo="" rev="" have_input=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs a checkout. $usage"; repo="$2"; shift 2 ;;
    --commit) [ $# -ge 2 ] || die "--commit needs a rev. $usage"; rev="$2"; shift 2 ;;
    -) [ -z "$have_input" ] || die "one input only. $usage"; input=-; have_input=1; shift ;;
    -*) die "unknown option $1. $usage" ;;
    *) [ -z "$have_input" ] || die "one input only. $usage"; input="$1"; have_input=1; shift ;;
  esac
done
[ -n "$have_input" ] || die "$usage"
if [ "$input" != - ] && { [ ! -f "$input" ] || [ ! -r "$input" ]; }; then die "no such file: $input"; fi
top="$(git -C "${repo:-.}" rev-parse --show-toplevel 2>/dev/null)" || die "not a git checkout: ${repo:-$PWD}"
sha="$(git -C "$top" rev-parse -q --verify "${rev:-HEAD}^{commit}" 2>/dev/null)" || die "no such commit in $top: ${rev:-HEAD}"
events="${STATS_EVENTS_FILE:-${PR_QUEUE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-queue}/events.jsonl}"

code="$(cat <<'PY'
import json, os, re, subprocess, sys, traceback

# An error in the sniff must never pass for a result: Python exits 1 on an uncaught exception, which is
# "soft flags only" here. Exit 5 instead, which the shell turns into 4 ("the sniff didn't run").
def crashed(kind, value, tb):
    traceback.print_exception(kind, value, tb)
    sys.stderr.flush()
    os._exit(5)
sys.excepthook = crashed

top, sha, events_file, input_path = sys.argv[1:5]
short = sha[:12]
env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")

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

for n, line in enumerate(lines, 1):
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
if not_proven_none:
    for crit, start, block in crit_blocks:
        if not has_evidence(block):
            flag("hard", "missing proof", start + 1, claim_of(block[0]),
                 f"Not proven: none (line {not_proven_none[0] + 1}), but A{crit} names no test, file:line or command")

flags.sort(key=lambda f: f[2])
for sev, cat, n, claim, why in flags:
    print(f"{sev} {cat} (line {n}): {claim} — {why}")
hard = sum(1 for f in flags if f[0] == "hard")
soft = len(flags) - hard
print(f"Flags: {hard} hard, {soft} soft")
sys.exit(2 if hard else 1 if soft else 0)
PY
)"
python3 -I -c "$code" "$top" "$sha" "$events" "$input"
rc=$?
case "$rc" in 0|1|2) exit "$rc" ;; *) die "the sniff failed (python exit $rc)" ;; esac
