# shellcheck shell=bash
# Stats events: sourced by pr-queue.sh. Each event is one JSON object on one line of the events file, for the
# local stats collector. It holds ids, names and numbers only, never review text or prompts.
#
#   emit <event> [key=value | key:int=value | key:list=value | key:opt=value | key:bool=value ...]
#
# Values are strings as they are; :int a whole number (null if it isn't one); :list a list of strings, one
# per line of the value (an empty value is []); :opt a string, null if empty; :bool true for 1 or true, else
# false. Every event also has v, ts (UTC, with ms), event, pid ($$), and repo, branch, job_id and sha from
# $EV_REPO, $EV_BRANCH, $EV_JOB_ID and $EV_SHA (null when empty). A field given twice keeps the last value.
# The line is built by python3 -I (json.dumps, so quotes, backslashes, newlines and any bytes are safe) and
# written with one append write. A line over 4 KB has its strings shortened and lists cut, so that the write
# stays one piece that concurrent writers can't interleave.
# The file is $STATS_EVENTS_FILE, else $STATE/events.jsonl, made 0600. Only a regular file is written: a
# directory, a FIFO or a missing folder is skipped. STATS_EVENTS=0 turns events off.
# emit never fails its caller and never prints: any error is ignored, and it returns 0.

emit() {
  [ "${STATS_EVENTS:-1}" != 0 ] || return 0
  local file="${STATS_EVENTS_FILE:-${STATE:-}/events.jsonl}"
  [ -n "$file" ] && [ "$file" != /events.jsonl ] || return 0
  python3 -I -c '
import datetime, json, os, stat, sys
file, pid, repo, branch, job, sha, event = sys.argv[1:8]
now = datetime.datetime.now(datetime.timezone.utc)
rec = {"v": 1, "ts": now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000), "event": event,
       "repo": repo or None, "branch": branch or None, "job_id": job or None, "sha": sha or None,
       "pid": int(pid) if pid.isdigit() else None}
fixed = set(rec)
for arg in sys.argv[8:]:
    key, eq, val = arg.partition("=")
    if not eq:
        continue
    key, _, kind = key.partition(":")
    if not key or key in fixed:
        continue
    if kind == "int":
        try:
            rec[key] = int(val.strip())
        except ValueError:
            rec[key] = None
    elif kind == "list":
        rec[key] = val.split("\n") if val else []
    elif kind == "opt":
        rec[key] = val or None
    elif kind == "bool":
        rec[key] = val in ("1", "true")
    else:
        rec[key] = val
def line():
    return (json.dumps(rec, separators=(",", ":")) + "\n").encode()
out = line()
for cut in (256, 64):
    if len(out) <= 4000:
        break
    for k, val in rec.items():
        if isinstance(val, str) and len(val) > cut:
            rec[k] = val[:cut]
        elif isinstance(val, list):
            rec[k] = [x[:cut] for x in val[:20]]
    rec["truncated"] = True
    out = line()
if len(out) > 4000:
    sys.exit(0)
fd = os.open(file, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
try:
    if stat.S_ISREG(os.fstat(fd).st_mode):
        os.write(fd, out)
finally:
    os.close(fd)
' "$file" "$$" "${EV_REPO:-}" "${EV_BRANCH:-}" "${EV_JOB_ID:-}" "${EV_SHA:-}" "$@" </dev/null >/dev/null 2>&1 || true
  return 0
}
