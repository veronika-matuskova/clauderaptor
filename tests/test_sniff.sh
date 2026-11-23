# shellcheck shell=bash
# shellcheck disable=SC2016  # the texts hold backticks on purpose
# Tests for sniff.sh: a fixture repo with two commits, events files through STATS_EVENTS_FILE, and a stub
# `claude` on PATH that records any call (sniff.sh must never start one).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

unset PR_QUEUE_DIR XDG_STATE_HOME STATS_EVENTS
mkdir -p "$TMP/bin" "$TMP/ev"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
echo called >> "$TMP/claude-calls"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" STATS_EVENTS_FILE="$TMP/ev/none.jsonl"

# The fixture: a.js (120 lines) defines load(); tests/test_x.sh has test_bar; .github/workflows/ci.yml. The second commit adds later.sh and
# nonl.txt (3 lines, no final newline).
R="$TMP/repo"; git init -q -b main "$R"; mkdir -p "$R/tests" "$R/scripts/queue" "$R/.github/workflows"
echo 'on: push' > "$R/.github/workflows/ci.yml"
{ echo "function load() {}"; for i in $(seq 2 120); do echo "// line $i"; done; } > "$R/a.js"
printf 'test_bar() { :; }\n' > "$R/tests/test_x.sh"
echo 'echo x' > "$R/scripts/queue/kept.sh"
echo 'gone from the working tree' > "$R/deleted.txt"
git -C "$R" add -A; git -C "$R" commit -q -m one; OLD="$(git -C "$R" rev-parse HEAD)"
echo 'echo later' > "$R/later.sh"; printf 'one\ntwo\nthree' > "$R/nonl.txt"; git -C "$R" add -A; git -C "$R" commit -q -m two
SHA="$(git -C "$R" rev-parse HEAD)"
rm "$R/deleted.txt"; echo untracked > "$R/untracked.txt"   # the working tree differs from the commit

S="$ROOT/scripts/queue/sniff.sh"
# sn <text> [args...]: sniffs the text at the fixture's HEAD; out holds the output, rc the exit code.
sn() { local t="$1"; shift; printf '%s\n' "$t" > "$TMP/in.md"; out="$(bash "$S" "$TMP/in.md" --repo "$R" "$@" 2>&1)"; rc=$?; }
# ev <file> <json lines...>: writes an events file
ev() { local f="$TMP/ev/$1"; shift; printf '%s\n' "$@" > "$f"; echo "$f"; }

echo "-- missing references"
sn $'See a.js:500 and a.js:100.'
assert_contains "A1: a.js:500 flagged with the file's length" "$out" "hard missing reference (line 1): a.js:500 — a.js:500, but a.js has 120 lines at ${SHA:0:12}"
assert_not_contains "A1: a.js:100 not flagged" "$out" "a.js:100 —"
assert_contains "A1: one hard flag" "$out" "Flags: 1 hard, 0 soft"
assert "A1: exit 2" test "$rc" = 2
sn $'Last line a.js:120, one past it a.js:121, a range a.js:110-130.'
assert_not_contains "the last line isn't flagged" "$out" "a.js:120 —"
assert_contains "one past the last line is flagged" "$out" "a.js:121 — a.js:121, but a.js has 120 lines"
assert_contains "a range past the last line is flagged" "$out" "a.js:110-130 —"
sn $'Last line nonl.txt:3, one past it nonl.txt:4.'
assert_not_contains "no final newline: the last line isn't flagged" "$out" "nonl.txt:3 —"
assert_contains "no final newline: one past the last line is flagged" "$out" "nonl.txt:4 — nonl.txt:4, but nonl.txt has 3 lines"
sn 'Wrote `untracked.txt`.'
assert_contains "A2: untracked file is a missing reference" "$out" "hard missing reference (line 1): untracked.txt"
assert "A2: untracked: exit 2" test "$rc" = 2
sn 'Kept `deleted.txt` and scripts/queue/kept.sh.'
assert_contains "A2: file in the commit but deleted from the working tree not flagged" "$out" "Flags: 0 hard, 0 soft"
sn 'Changed `scripts/queue/gone.sh`.'
assert_contains "A6: a changed file that isn't there is flagged" "$out" "hard missing reference (line 1): scripts/queue/gone.sh"
assert "A6: gone.sh: exit 2" test "$rc" = 2
sn $'Calls `save()`.\nCalls `load()`.'
assert_contains "A4: save() not found is flagged" "$out" "hard missing reference (line 1): save() — git grep doesn't find save"
assert_not_contains "A4: load() not flagged" "$out" "load()"
assert_contains "A4: one hard flag" "$out" "Flags: 1 hard, 0 soft"
sn 'Changed .github/workflows/ci.yml, `.github/workflows/ci.yml` and ./a.js.'
assert_contains "a dotfolder path and ./x that exist: no flag" "$out" "Flags: 0 hard, 0 soft"
sn 'Wrote ./missing/x.sh.'
assert_contains "./x that isn't there is flagged" "$out" "hard missing reference (line 1): missing/x.sh — missing/x.sh isn't in the tree"
sn 'Covered by test_missing.'
assert_contains "a test_<word> at the end of a sentence is checked" "$out" "hard missing reference (line 1): test_missing — git grep doesn't find test_missing"
sn 'Proof in test_nothere and test_bar.'
assert_contains "test_<word> not found is flagged" "$out" "hard missing reference (line 1): test_nothere"
assert_not_contains "test_<word> found isn't flagged" "$out" "test_bar —"

echo "-- references left alone"
sn $'Rules in ~/.claude/rules and logs in /tmp/x.log.\nEvents: $STATE/events.jsonl and ${PR_QUEUE_DIR}/x.\nSee https://example.com/a.js and `<branch>-<sha>-sniff.md`.\nTests: tests/test_*.sh\nNew script `scripts/queue/new.sh`.\n`skills/x/SKILL.md` is in another repo.'
assert_contains "A6: references not meant to be in the tree: no flags" "$out" "Flags: 0 hard, 0 soft"
assert "A6: exit 0" test "$rc" = 0
for m in "Will add" "This adds" "To create" "It creates" "A new file:" "Lives in the other repo:" "Kept in the target repo:" "Lives outside the repo:" "We add"; do
  sn "$m \`scripts/queue/nothere.sh\`."
  assert_contains "marker \"$m\": a missing file on that line isn't flagged" "$out" "Flags: 0 hard, 0 soft"
done
sn 'See ../other/missing.sh and `../x/y.sh`.'
assert_contains "../ paths aren't flagged" "$out" "Flags: 0 hard, 0 soft"
sn 'Added `scripts/queue/new.sh`.'
assert_contains "\"added\" isn't a marker: still checked" "$out" "hard missing reference (line 1): scripts/queue/new.sh"

echo "-- missing proof"
sn $'- A1: proven by test_bar\n- A2: proven by test_foo'
assert_contains "A3: missing proof names A2 and test_foo" "$out" "hard missing proof (line 2): - A2: proven by test_foo — A2's proof test_foo isn't found"
assert_not_contains "A3: A1's proof found: no flag" "$out" "(line 1)"
assert_contains "A3: one hard flag" "$out" "Flags: 1 hard, 0 soft"
assert "A3: exit 2" test "$rc" = 2
sn $'- A1: proven by "line 7"\n- A2: proven by "no such line anywhere"'
assert_not_contains "a quoted proof found at the commit: no flag" "$out" "(line 1)"
assert_contains "a quoted proof not at the commit: hard missing proof" "$out" "hard missing proof (line 2): - A2: proven by \"no such line anywhere\" — A2's proof no such line anywhere isn't found"
sn $'- A1: proven by `bash tests/test_x.sh`'
assert_contains "a backticked command as proof: its test file is checked, found: no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by `bash tests/test_gone.sh -v`'
assert_contains "a backticked command as proof: its test file missing: hard missing proof" "$out" "hard missing proof (line 1): - A1: proven by \`bash tests/test_gone.sh -v\` — A1's proof tests/test_gone.sh isn't found"
assert_contains "a backticked command as proof: one flag" "$out" "Flags: 1 hard, 0 soft"
sn $'- A1: adds a flag, proven by test_missing'
assert_contains "a criterion with a marker word: its proof is still checked" "$out" "hard missing proof (line 1): - A1: adds a flag, proven by test_missing — A1's proof test_missing isn't found"
sn $'- A1: covered in test_missing.'
assert_contains "a criterion's test_<word> at the end of a sentence is checked" "$out" "hard missing proof (line 1): - A1: covered in test_missing. — A1's proof test_missing isn't found"
sn $'Not proven: none\n- A1: did a thing\n  see test_bar'
assert_contains "Not proven: none: the proof on a continuation line counts" "$out" "Flags: 0 hard, 0 soft"
sn $'Not proven: none\n- A1: did a thing\n\n  see test_bar'
assert_contains "Not proven: none: a line after a blank line isn't part of the criterion" "$out" "hard missing proof (line 2): - A1: did a thing — Not proven: none (line 1), but A1 names no test"
sn $'- A1: the gate, in tests/nothere.sh'
assert_contains "a criterion's test file that isn't there is missing proof" "$out" "hard missing proof (line 1)"
sn $'- A1: proven by test_bar\n- A3: it works\n\nNot proven: none'
assert_contains "A5: Not proven: none with an unproven A3" "$out" "hard missing proof (line 2): - A3: it works — Not proven: none (line 4), but A3 names no test"
assert "A5: exit 2" test "$rc" = 2
sn $'- A1: proven by test_bar\n- A3: test_bar in tests/test_x.sh\n\nNot proven: none'
assert_contains "A5: A3 names a test: no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by test_bar\n- A3: it works\n\nNot proven: A3'
assert_contains "Not proven names A3: no flag" "$out" "Flags: 0 hard, 0 soft"

echo "-- runs that didn't happen"
J='"job_id": "j1"'
STATS_EVENTS_FILE="$(ev e2e-fail.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 1}")" sn 'I ran the e2e suite.'
assert_contains "A7: e2e rc 1: hard" "$out" "hard run that didn't happen (line 1): I ran the e2e suite. — e2e_finished rc 1"
assert "A7: e2e rc 1: exit 2" test "$rc" = 2
STATS_EVENTS_FILE="$(ev e2e-nopass.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 0}" "{\"event\": \"job_failed\", \"sha\": \"$SHA\", $J, \"step\": \"e2e\", \"reason\": \"no_e2e_pass\"}")" sn 'I ran the e2e suite.'
assert_contains "A7: rc 0 then no_e2e_pass: hard" "$out" "hard run that didn't happen (line 1): I ran the e2e suite. — job_failed e2e/no_e2e_pass"
STATS_EVENTS_FILE="$(ev e2e-moved.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 0}" "{\"event\": \"job_failed\", \"sha\": \"$SHA\", $J, \"step\": \"e2e\", \"reason\": \"moved\"}")" sn 'I ran the e2e suite.'
assert_contains "e2e rc 0 then job_failed e2e/moved (not a run's result): no flag" "$out" "Flags: 0 hard, 0 soft"
sn 'I ran the e2e suite.'
assert_contains "A7: no events file: soft no record" "$out" "soft run that didn't happen (line 1): I ran the e2e suite. — no record of the run"
assert "A7: no record: exit 1" test "$rc" = 1
STATS_EVENTS_FILE="$(ev e2e-other.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$OLD\", $J, \"rc\": 0}")" sn 'I ran the e2e suite.'
assert_contains "A7: a record only at another sha: soft no record" "$out" "soft run that didn't happen (line 1): I ran the e2e suite. — no record of the run"
assert "A7: other sha: exit 1" test "$rc" = 1
E2E_PASS="$(ev e2e-pass.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 0}" "{\"event\": \"merged\", \"sha\": \"$SHA\", $J}")"
STATS_EVENTS_FILE="$E2E_PASS" sn 'I ran the e2e suite.'
assert_contains "A7: e2e rc 0 with no later failure: no flag" "$out" "Flags: 0 hard, 0 soft"
STATS_EVENTS_FILE="$(ev checks-fail.jsonl "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", $J, \"result\": \"fail\"}")" sn 'All tests pass.'
assert_contains "A8: checks fail: hard" "$out" "hard run that didn't happen (line 1): All tests pass. — checks_finished result=fail"
STATS_EVENTS_FILE="$(ev checks-pass.jsonl "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", $J, \"result\": \"pass\"}")" sn 'All tests pass.'
assert_contains "A8: checks pass: no flag" "$out" "Flags: 0 hard, 0 soft"
STATS_EVENTS_FILE="$(ev checks-both.jsonl "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", $J, \"result\": \"fail\"}" "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", \"job_id\": \"j2\", \"result\": \"pass\"}")" sn 'All tests pass.'
assert_contains "checks fail and pass at the same sha: hard" "$out" "hard run that didn't happen (line 1): All tests pass. — checks_finished result=fail"
sn 'All tests pass.'
assert_contains "A8: no checks record: soft no record" "$out" "soft run that didn't happen (line 1): All tests pass. — no record of the checks"

echo "-- weasel words"
sn 'Fixed, should work now.'
assert_contains "A9: weasel words in a claim: soft" "$out" "soft weasel words (line 1): Fixed, should work now."
assert_contains "A9: no hard flag" "$out" "Flags: 0 hard, 1 soft"
assert "A9: exit 1" test "$rc" = 1
for w in "should work" "probably" "seems to" "robust" "comprehensive"; do
  sn "Done: the fix is $w here."
  assert_contains "weasel word \"$w\" in a done-claim: soft" "$out" "soft weasel words (line 1): Done: the fix is $w here. — \"$w\" in a claim"
done
sn 'this probably needs a cache later'
assert_contains "A9: weasel word in a line that claims nothing: no flag" "$out" "Flags: 0 hard, 0 soft"

echo "-- all true"
TRUE_TEXT=$'Changed a.js:100 and `load()` in a.js.\n- A1: proven by test_bar\n- A2: `tests/test_x.sh` runs it\nRan the e2e suite.\n\nNot proven: none'
STATS_EVENTS_FILE="$E2E_PASS" sn "$TRUE_TEXT"
assert_contains "A10: all true: Flags: 0 hard, 0 soft" "$out" "Flags: 0 hard, 0 soft"
assert "A10: only the Flags line" test "$out" = "Flags: 0 hard, 0 soft"
assert "A10: exit 0" test "$rc" = 0

echo "-- input, repo and commit"
sn $'Wrote later.sh and a.js:500.'; from_file="$out"
from_stdin="$(printf '%s\n' 'Wrote later.sh and a.js:500.' | bash "$S" - --repo "$R" 2>&1)"
assert "A11: stdin gives the same output as a file" test "$from_stdin" = "$from_file"
in_repo="$(cd "$R" && printf '%s\n' 'See later.sh at HEAD.' | bash "$S" - 2>&1)"
assert_contains "A11: no --repo, no --commit: the checkout's HEAD" "$in_repo" "Flags: 0 hard, 0 soft"
sn 'See later.sh.' --commit "$OLD"
assert_contains "A11: --commit <older sha>: a file added later is flagged" "$out" "hard missing reference (line 1): later.sh — later.sh isn't in the tree at ${OLD:0:12}"
sn 'See later.sh.' --commit HEAD~1
assert_contains "--commit takes any rev" "$out" "isn't in the tree at ${OLD:0:12}"

err="$(bash "$S" "$TMP/no-such.md" --repo "$R" 2>&1 >/dev/null)"; rc=$?
assert "A12: missing input file: exit 4" test "$rc" = 4
assert_contains "A12: missing input file: message on stderr" "$err" "no such file"
mkdir -p "$TMP/plain"
err="$(bash "$S" "$TMP/in.md" --repo "$TMP/plain" 2>&1 >/dev/null)"; rc=$?
assert "A12: not a checkout: exit 4" test "$rc" = 4
assert_contains "A12: not a checkout: message on stderr" "$err" "not a git checkout"
err="$(bash "$S" "$TMP/in.md" --repo "$R" --commit deadbeef 2>&1 >/dev/null)"; rc=$?
assert "A12: unknown commit: exit 4" test "$rc" = 4
assert_contains "A12: unknown commit: message on stderr" "$err" "no such commit"
err="$(bash "$S" - --repo "$R" 2>&1 >/dev/null <&-)"; rc=$?
assert "an error in the sniff itself (stdin closed): exit 4, not 1" test "$rc" = 4
assert_contains "an error in the sniff itself: message on stderr" "$err" "the sniff failed"
err="$(bash "$S" --repo "$R" 2>&1 >/dev/null)"; rc=$?
assert "bad arguments: exit 4" test "$rc" = 4

echo "-- the rule and the README"
assert_contains "A15: the rule in claude/rules/pr-queue.md: a set of claims" "$(git -C "$ROOT" grep -n "set of claims" -- claude/rules/pr-queue.md)" "main session that runs the queue: an agent's report is a set of claims"
assert_contains "A15: the rule names sniff.sh" "$(git -C "$ROOT" grep -n "sniff.sh" -- claude/rules/pr-queue.md)" "scripts/queue/sniff.sh"
readme="$(git -C "$ROOT" grep -n "sniff.sh" -- README.md)"
assert_contains "A17: README.md documents sniff.sh's arguments" "$readme" "sniff.sh <file or -> [--repo <checkout>] [--commit <rev>]"
assert_contains "A17: README.md documents sniff.sh's exit codes" "$readme" "exits 0 for no flags, 1 for soft flags only, 2 for a hard flag, and 4 when it couldn't run"

echo "-- no session, no transcripts, no changes"
TEXT=$'See a.js:500, `save()`, later.sh.\n- A2: proven by test_foo\nFixed, should work.\nRan the e2e suite.'
sn "$TEXT"; normal_out="$out"; normal_rc="$rc"
mkdir -p "$TMP/locked"; chmod 000 "$TMP/locked"
locked_out="$(HOME="$TMP/locked" CLAUDE_CONFIG_DIR="$TMP/locked" bash "$S" "$TMP/in.md" --repo "$R" 2>&1)"; locked_rc=$?
chmod 755 "$TMP/locked"
assert "A13: HOME and CLAUDE_CONFIG_DIR unreadable: same output" test "$locked_out" = "$normal_out"
assert "A13: same exit code" test "$locked_rc" = "$normal_rc"
assert "A13: the stub claude was never called" test ! -e "$TMP/claude-calls"

state() { git -C "$R" rev-parse HEAD; git -C "$R" branch --show-current; git -C "$R" status --porcelain; git -C "$R" for-each-ref; ls -a "$R"; }
before="$(state)"; sn "$TEXT"; after="$(state)"
assert "A14: the run had flags" test "$rc" = 2
assert "A14: HEAD, branch, status and refs unchanged" test "$before" = "$after"

finish
