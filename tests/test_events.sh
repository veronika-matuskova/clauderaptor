# shellcheck shell=bash
# Tests for events.sh: emit's JSON lines, its typed values, and that it never fails or blocks its caller.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/queue/events.sh
source "$ROOT/scripts/queue/events.sh"

unset STATS_EVENTS STATS_EVENTS_FILE
STATE="$TMP/state"; mkdir -p "$STATE"
EV="$STATE/events.jsonl"
# jq_py <file> <python expression over `recs`, the parsed lines>: prints its value; fails if a line isn't JSON.
jq_py() { python3 -I -c 'import json, sys; recs = [json.loads(l) for l in open(sys.argv[1])]; print(eval(sys.argv[2]))' "$@"; }

# --- the common fields, and typed values ---
EV_REPO=myrepo EV_BRANCH=fix/a EV_JOB_ID=123-fix-a EV_SHA=abc123 emit job_queued review:opt= tests:opt=on type=fix \
  n:int=42 bad:int=x5 l:list=$'one\ntwo' e:list= yes:bool=1 no:bool=
assert "common: one line"                    test "$(wc -l < "$EV")" = 1
got="$(jq_py "$EV" 'recs[0]["v"], recs[0]["event"], recs[0]["repo"], recs[0]["branch"], recs[0]["job_id"], recs[0]["sha"], recs[0]["pid"] == int(sys.argv[3])' "$$")"
assert_contains "common: v, event, repo, branch, job_id, sha, pid" "$got" "(1, 'job_queued', 'myrepo', 'fix/a', '123-fix-a', 'abc123', True)"
assert "common: ts is UTC ISO 8601 with ms"  python3 -I -c 'import json, re, sys; t = json.loads(open(sys.argv[1]).readline())["ts"]; sys.exit(not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", t))' "$EV"
got="$(jq_py "$EV" '[recs[0][k] for k in ("review", "tests", "type", "n", "bad", "l", "e", "yes", "no")]')"
assert_contains "typed: opt, str, int, bad int, list, empty list, bool" "$got" "[None, 'on', 'fix', 42, None, ['one', 'two'], [], True, False]"
assert "file: made 0600"                     test "$(stat -c %a "$EV")" = 600
rm -f "$EV"; emit job_started
assert_contains "common: empty ids are null" "$(jq_py "$EV" '[recs[0][k] for k in ("repo", "branch", "job_id", "sha")]')" "[None, None, None, None]"
rm -f "$EV"; EV_BRANCH=b emit job_started event=other v:int=9 branch=x
assert_contains "common: extra fields can't overwrite them" "$(jq_py "$EV" '[recs[0][k] for k in ("event", "v", "branch")]')" "['job_started', 1, 'b']"

# --- hostile values: parsed back equal ---
# shellcheck disable=SC2016  # meant literally: they must not run
hostile=(
  'quote"d' 'back\slash' $'new\nline' $'tab\tand\rcr' 'uni ž 日本 🦖' '{"json":1}' '$(touch pwned)' '`touch pwned`'
  "it's" '-n' '%s%n' '\u0000' $'\x01\x1f' 'a=b=c'
)
rm -f "$EV"
for h in "${hostile[@]}"; do EV_BRANCH="$h" emit job_started note="$h" items:list="$h"; done
assert "hostile: one line each"              test "$(wc -l < "$EV")" = "${#hostile[@]}"
assert "hostile: every line is JSON"         jq_py "$EV" 'len(recs)'
printf '%s\0' "${hostile[@]}" > "$TMP/expected"
assert "hostile: branch and note parsed back equal" python3 -I -c '
import json, sys
want = open(sys.argv[2], "rb").read().split(b"\0")[:-1]
recs = [json.loads(l) for l in open(sys.argv[1])]
enc = lambda s: s.encode("utf-8", "surrogateescape")
sys.exit(not all(enc(r["branch"]) == w and enc(r["note"]) == w and r["items"] == [x for x in r["note"].split("\n")] for r, w in zip(recs, want)))
' "$EV" "$TMP/expected"
assert "hostile: nothing ran"                test ! -e pwned -a ! -e "$TMP/pwned"
rm -f "$EV"; EV_BRANCH=$'\xff\xfe not utf-8' emit job_started
assert "hostile: bytes that aren't UTF-8 still give JSON" jq_py "$EV" 'len(recs)'

# --- a long value: the line stays under 4 KB, one line ---
rm -f "$EV"; long="$(printf 'x%.0s' $(seq 20000))"
emit checks_finished failed:list="$(seq 5000)" detail="$long"
assert "long: one line"                      test "$(wc -l < "$EV")" = 1
assert "long: under 4 KB"                    test "$(wc -c < "$EV")" -lt 4096
assert_contains "long: marked truncated"     "$(jq_py "$EV" 'recs[0]["truncated"], recs[0]["event"]')" "(True, 'checks_finished')"
# Too many fields to cut under 4 KB: no line rather than one that a concurrent write could split.
rm -f "$EV"; many=(); for i in $(seq 300); do many+=("field$i=${long:0:64}"); done
emit job_started "${many[@]}"
assert "too many fields: nothing written"    test ! -s "$EV"

# --- concurrent emitters: only whole, valid lines ---
rm -f "$EV"
for w in $(seq 10); do
  ( for i in $(seq 20); do EV_BRANCH="w$w" emit job_started i:int="$i" pad="$(printf 'p%.0s' $(seq 1500))"; done ) &
done
wait
assert "concurrent: every line"              test "$(wc -l < "$EV")" = 200
assert "concurrent: every line is JSON, none lost" test "$(jq_py "$EV" 'len({(r["branch"], r["i"]) for r in recs})')" = 200

# --- errors never reach the caller ---
# check <name> <events path>: emit returns 0, prints nothing, and the caller's next command still runs.
check() {
  local out rc
  # shellcheck disable=SC2016  # expands in the inner bash
  out="$(STATS_EVENTS_FILE="$2" timeout 10 bash -c 'set -euo pipefail; source "$1"; emit job_started x=1; echo after' _ "$ROOT/scripts/queue/events.sh" 2>&1)"; rc=$?
  assert "$1: exit 0"                        test "$rc" = 0
  assert "$1: prints nothing, the caller goes on" test "$out" = after
}
check "missing folder" "$TMP/no/such/dir/events.jsonl"
mkdir "$TMP/adir"; check "a directory" "$TMP/adir"
touch "$TMP/ro"; chmod 000 "$TMP/ro"; check "unwritable" "$TMP/ro"
assert "unwritable: left empty"              test ! -s "$TMP/ro"
mkfifo "$TMP/fifo"; check "a FIFO nobody reads (doesn't block)" "$TMP/fifo"
check "an empty path" ""
# shellcheck disable=SC2123  # on purpose: no python3 to find
out="$(PATH=/nonexistent; emit job_started; echo "rc=$?")"
assert_contains "no python3: returns 0"      "$out" "rc=0"
out="$(emit; echo "rc=$?")";                 assert_contains "no event name: returns 0" "$out" "rc=0"
out="$(unset STATE; STATS_EVENTS_FILE=; emit job_started; echo "rc=$?")"
assert_contains "no STATE, no file: returns 0" "$out" "rc=0"
assert "no STATE, no file: nothing at /events.jsonl" test ! -e /events.jsonl

# --- STATS_EVENTS=0 writes nothing; STATS_EVENTS_FILE overrides the path ---
rm -f "$EV"; STATS_EVENTS=0 emit job_started
assert "STATS_EVENTS=0: nothing written"     test ! -e "$EV"
STATS_EVENTS_FILE="$TMP/other.jsonl" emit job_started
assert "STATS_EVENTS_FILE: written there"    test -s "$TMP/other.jsonl"
assert "STATS_EVENTS_FILE: not to the default" test ! -e "$EV"

finish
