# shellcheck shell=bash
# shellcheck disable=SC2016  # the texts hold backticks on purpose
# Tests for sniff.sh: a fixture repo with two commits, events files through STATS_EVENTS_FILE, and a stub
# `claude` on PATH that records any call (sniff.sh must never start one).
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

unset PR_QUEUE_DIR XDG_STATE_HOME STATS_EVENTS SNIFF_IN_SESSION
mkdir -p "$TMP/bin" "$TMP/ev"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
echo called >> "$TMP/claude-calls"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" STATS_EVENTS_FILE="$TMP/ev/none.jsonl"

# The fixture: a.js (120 lines) defines load(); tests/test_x.sh has test_bar; .github/workflows/ci.yml,
# pkg/__init__.py, _config.yml, README.md, lib/x.js and src/x.js. The second commit adds later.sh and
# nonl.txt (3 lines, no final newline).
R="$TMP/repo"; git init -q -b main "$R"; mkdir -p "$R/tests" "$R/scripts/queue" "$R/.github/workflows"
echo 'on: push' > "$R/.github/workflows/ci.yml"
mkdir -p "$R/pkg"; touch "$R/pkg/__init__.py" "$R/_config.yml"; echo '# readme' > "$R/README.md"
# Two files named x.js: lib/x.js (10 lines) comes first in the tree, src/x.js has 60.
mkdir -p "$R/lib" "$R/src"; seq 10 > "$R/lib/x.js"; seq 60 > "$R/src/x.js"
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
# A sniff never starts another: inside a sniff session (SNIFF_IN_SESSION=1) it exits 4 before it checks anything,
# also with --session (no claude call); the same input sniffs as before without it, or with another value.
rm -f "$TMP/claude-calls"
err="$(SNIFF_IN_SESSION=1 bash "$S" "$TMP/in.md" --repo "$R" --session --author developer 2>&1 >"$TMP/nested.out")"; rc=$?
assert "A11 (4a): SNIFF_IN_SESSION=1: exit 4" test "$rc" = 4
assert "A11 (4a): SNIFF_IN_SESSION=1: says why" test "$err" = "sniff: a sniff doesn't start another sniff"
assert "A11 (4a): SNIFF_IN_SESSION=1: no flags printed" test ! -s "$TMP/nested.out"
assert "A11 (4a): SNIFF_IN_SESSION=1: the stub claude isn't called" test ! -e "$TMP/claude-calls"
err="$(SNIFF_IN_SESSION=1 bash "$S" --bogus 2>&1)"
assert "A11 (4a): the guard comes before the arguments" test "$err" = "sniff: a sniff doesn't start another sniff"
sn $'See a.js:500 and a.js:100.'
assert "A11 (4a): without it, the same input: exit 2, as before" test "$rc" = 2
SNIFF_IN_SESSION=0 sn $'See a.js:500 and a.js:100.'
assert "A11 (4a): SNIFF_IN_SESSION=0 sniffs as before" test "$rc" = 2
assert_contains "A11 (4a): SNIFF_IN_SESSION=0: the flag" "$out" "a.js:500, but a.js has 120 lines"
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
sn 'See a.js:500 and a.js:500 and `save()` `save()`'
assert_contains "the same flag twice on a line is one flag" "$out" "Flags: 2 hard, 0 soft"
sn 'Changed scripts/queue and scripts/nope.'
assert_not_contains "a folder at the commit isn't flagged" "$out" "scripts/queue —"
assert_contains "a folder that isn't there is flagged" "$out" "hard missing reference (line 1): scripts/nope — scripts/nope isn't in the tree"
assert_contains "folders: one flag" "$out" "Flags: 1 hard, 0 soft"
sn 'Changed `__init__.py`, pkg/__init__.py, `_config.yml` and _config.yml.'
assert_contains "names with leading underscores keep them: no flag" "$out" "Flags: 0 hard, 0 soft"
sn 'Edited *a.js*, _a.js_, **a.js**, __a.js__ and ~~gone.js~~.'
assert_contains "Markdown emphasis around a path is dropped; struck-out text isn't checked" "$out" "Flags: 0 hard, 0 soft"
sn 'Edited _gone.js_ and **gone2.js**.'
assert_contains "a path in _emphasis_ is still checked" "$out" "hard missing reference (line 1): gone.js"
assert_contains "a path in **bold** is still checked" "$out" "hard missing reference (line 1): gone2.js"
sn 'See [the readme](README.md), [x](gone.md), [y](https://x.y/a.md) and [z](#anchor).'
assert_contains "a link's target is checked" "$out" "hard missing reference (line 1): gone.md"
assert_contains "links: only the missing target is flagged" "$out" "Flags: 1 hard, 0 soft"
sn 'See README.md#use and gone2.md#x and #123.'
assert_contains "path#anchor: the path is checked" "$out" "hard missing reference (line 1): gone2.md — gone2.md isn't in the tree"
assert_contains "path#anchor: only the missing path is flagged" "$out" "Flags: 1 hard, 0 soft"
sn 'Ran `tool --config=README.md` and `tool --out=gone.txt` and key=a.js.'
assert_contains "--flag=path: the path is checked" "$out" "hard missing reference (line 1): gone.txt"
assert_contains "--flag=path, key=value: only the missing path is flagged" "$out" "Flags: 1 hard, 0 soft"
sn 'Ran git log origin/main..HEAD, `git diff main...feat` and `git log a8ec..bb25`.'
assert_contains "git ranges aren't paths: no flag" "$out" "Flags: 0 hard, 0 soft"
sn 'Compared HEAD~1, HEAD^, origin/main~2, v1.2.3, 24.11.0, python3.11, @scope/pkg and @types/node.'
assert_contains "revs, versions and npm scopes aren't paths: no flag" "$out" "Flags: 0 hard, 0 soft"
sn 'Wrote C:\Users\x\gone.txt and C:/Users/x/gone.txt.'
assert_contains "Windows paths aren't checked" "$out" "Flags: 0 hard, 0 soft"
sn 'Covered by test_barba here, by test_ba, and `loa()`.'
assert_contains "a test name that starts with a real one isn't found" "$out" "hard missing reference (line 1): test_barba — git grep doesn't find test_barba"
assert_contains "a test name that a real one starts with isn't found (whole words)" "$out" "hard missing reference (line 1): test_ba — git grep doesn't find test_ba "
assert_contains "a name() that a real one starts with isn't found (whole words)" "$out" "hard missing reference (line 1): loa() — git grep doesn't find loa"
sn 'See x.js:50.'
assert_contains "two files with the same name: the longest one counts" "$out" "Flags: 0 hard, 0 soft"
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
sn 'Changed scripts/new_thing.sh and scripts/add/x.sh.'
assert_contains "a marker word inside a path doesn't count: new_thing.sh flagged" "$out" "hard missing reference (line 1): scripts/new_thing.sh"
assert_contains "a marker word inside a path doesn't count: add/x.sh flagged" "$out" "hard missing reference (line 1): scripts/add/x.sh"
assert_contains "a marker word inside a path: two flags" "$out" "Flags: 2 hard, 0 soft"
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
sn $'- A1: parses flags, proven by tests/test_x.sh:1'
assert_contains "a file:line proof within the file: no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: parses flags, proven by tests/test_x.sh:42'
assert_contains "a file:line proof past the end: hard missing proof" "$out" "hard missing proof (line 1): - A1: parses flags, proven by tests/test_x.sh:42 — A1's proof tests/test_x.sh:42, but tests/test_x.sh has 1 lines"
assert_contains "a file:line proof past the end: one flag" "$out" "Flags: 1 hard, 0 soft"
sn $'- A1: proven by tests/test_x.sh:1-3'
assert_contains "a file:line-range proof past the end: hard missing proof" "$out" "A1's proof tests/test_x.sh:1-3, but tests/test_x.sh has 1 lines"
sn $'- A1: proven by tests/gone.sh:1'
assert_contains "a file:line proof in a file that isn't there: hard missing proof" "$out" "A1's proof tests/gone.sh isn't in the tree"
sn $'- A2: add stdin support, proven by the test test_nonexistent'
assert_contains "proven by the test test_x: the test name is the proof" "$out" "hard missing proof (line 1): - A2: add stdin support, proven by the test test_nonexistent — A2's proof test_nonexistent isn't found"
sn $'- A2: proven by the test test_bar'
assert_contains "proven by the test test_bar (found): no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by test_bar and test_gone'
assert_contains "a proof list: each is checked" "$out" "A1's proof test_gone isn't found"
assert_contains "a proof list: only the missing one is flagged" "$out" "Flags: 1 hard, 0 soft"
sn $'- A1: proven by: **test_bar** (tests/test_x.sh).'
assert_contains "proof with a colon, emphasis, parentheses and a full stop: no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by: test_gone.'
assert_contains "proof after a colon, with a full stop: checked" "$out" "A1's proof test_gone isn't found"
sn $'- A1: proven by “no such line anywhere”'
assert_contains "a proof in curly quotes is a quoted name" "$out" "A1's proof no such line anywhere isn't found"
sn $'- A1: proven by “line 7”'
assert_contains "a proof in curly quotes, found: no flag" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by e.g. test_gone'
assert_contains "e.g. doesn't end the proof" "$out" "hard missing proof (line 1): - A1: proven by e.g. test_gone — A1's proof test_gone isn't found"
assert_contains "e.g.: one flag" "$out" "Flags: 1 hard, 0 soft"
sn $'- A1: proven by `npm test`'
assert_contains "a command proof with no test file or name: nothing to check" "$out" "Flags: 0 hard, 0 soft"
sn $'- A1: proven by test_bar; it also renames test_gone'
assert_contains "after the proof's clause: a reference, not a proof" "$out" "hard missing reference (line 1): test_gone"
assert_not_contains "after the proof's clause: not a missing proof" "$out" "missing proof"
sn $'- A1: proven by hand'
assert_contains "a plain word proof is checked" "$out" "A1's proof hand isn't found"
sn $'- A1: proven by a manual run'
assert_contains "filler words before a plain word proof are skipped" "$out" "A1's proof manual isn't found"
sn $'- A1: adds a flag, proven by test_missing'
assert_contains "a criterion with a marker word: its proof is still checked" "$out" "hard missing proof (line 1): - A1: adds a flag, proven by test_missing — A1's proof test_missing isn't found"
sn $'- A1: covered in test_missing.'
assert_contains "a criterion's test_<word> at the end of a sentence is checked" "$out" "hard missing proof (line 1): - A1: covered in test_missing. — A1's proof test_missing isn't found"
sn $'- A1: done\n\n**Not proven:** none'
assert_contains "a bold **Not proven:** none is read" "$out" "hard missing proof (line 1): - A1: done — Not proven: none (line 3), but A1 names no test"
sn $'- A1: done\n\n__Not proven:__ none'
assert_contains "a bold __Not proven:__ none is read" "$out" "hard missing proof (line 1): - A1: done — Not proven: none (line 3), but A1 names no test"
sn $'**A1:** proven by test_gone'
assert_contains "a bold **A1:** label is a criterion" "$out" "hard missing proof (line 1): **A1:** proven by test_gone — A1's proof test_gone isn't found"
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
STATS_EVENTS_FILE="$(ev e2e-prefix.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"${SHA:0:12}\", $J, \"rc\": 1}" "{\"event\": \"e2e_finished\", \"sha\": \"${SHA}0\", $J, \"rc\": 1}" "{\"event\": \"e2e_finished\", \"sha\": \"${SHA^^}\", $J, \"rc\": 1}")" sn 'I ran the e2e suite.'
assert_contains "a record at a short, longer or upper-case sha doesn't count: soft no record" "$out" "soft run that didn't happen (line 1): I ran the e2e suite. — no record of the run"
assert "a record at a near-match sha: exit 1" test "$rc" = 1
E2E_PASS="$(ev e2e-pass.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 0}" "{\"event\": \"merged\", \"sha\": \"$SHA\", $J}")"
STATS_EVENTS_FILE="$E2E_PASS" sn 'I ran the e2e suite.'
assert_contains "A7: e2e rc 0 with no later failure: no flag" "$out" "Flags: 0 hard, 0 soft"
STATS_EVENTS_FILE="$(ev checks-fail.jsonl "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", $J, \"result\": \"fail\"}")" sn 'All tests pass.'
assert_contains "A8: checks fail: hard" "$out" "hard run that didn't happen (line 1): All tests pass. — checks_finished result=fail"
E2E_OK_CHECKS_FAIL="$(ev e2e-ok-checks-fail.jsonl "{\"event\": \"e2e_finished\", \"sha\": \"$SHA\", $J, \"rc\": 0}" "{\"event\": \"checks_finished\", \"sha\": \"$SHA\", $J, \"result\": \"fail\"}")"
STATS_EVENTS_FILE="$E2E_OK_CHECKS_FAIL" sn 'e2e passed and all tests pass'
assert_contains "e2e and tests-pass claims on one line are both checked" "$out" "hard run that didn't happen (line 1): e2e passed and all tests pass — checks_finished result=fail"
assert_contains "e2e and tests-pass on one line: one flag" "$out" "Flags: 1 hard, 0 soft"
STATS_EVENTS_FILE="$E2E_OK_CHECKS_FAIL" sn 'The e2e tests pass.'
assert_contains "\"e2e tests pass\" is an e2e claim only" "$out" "Flags: 0 hard, 0 soft"
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

echo "-- brief mode (--brief)"
# The brief fixture: commit C1 has a.js (defines export(), line 3 is "return 1") and b.js (calls it at lines 12
# and 14). HEAD adds a test, a doc and migrations that use them, a bash caller (lib.sh, run.sh), tests/run.sh,
# and m0.js (defines many()) with 12 files that call it.
BR="$TMP/brepo"; git init -q -b main "$BR"
printf 'function export() {\n  // body\n  return 1\n}\n' > "$BR/a.js"
{ for i in $(seq 11); do echo "// line $i"; done; echo "export();"; echo "// 13"; echo "export();"; } > "$BR/b.js"
git -C "$BR" add -A; git -C "$BR" commit -q -m one; C1="$(git -C "$BR" rev-parse HEAD)"
mkdir -p "$BR/tests/migrations" "$BR/db/migrations" "$BR/spec"
printf '#!/usr/bin/env bash\nnode a.js\n' > "$BR/tests/test_a.sh"; echo 'echo ALL PASSED' > "$BR/tests/run.sh"
printf '# Docs\nCall export() to export.\n' > "$BR/README.md"
echo 'select export();' > "$BR/db/migrations/001.sql"; echo 'select export();' > "$BR/tests/migrations/002.sql"
echo 'export();' > "$BR/spec/test_e.js"; printf '# notes\nexport() in tests\n' > "$BR/tests/notes.md"
printf 'load_it() { :; }\n' > "$BR/lib.sh"; printf '#!/usr/bin/env bash\n. ./lib.sh\nload_it\nload_it\n' > "$BR/run.sh"
echo 'function many() {}' > "$BR/m0.js"; for i in $(seq 12); do echo 'many();' > "$BR/m$i.js"; done
git -C "$BR" add -A; git -C "$BR" commit -q -m two; BSHA="$(git -C "$BR" rev-parse HEAD)"
# bs <text> [args...]: sniffs the text in brief mode at the brief fixture's HEAD (or --commit); out, rc.
bs() { local t="$1"; shift; printf '%s\n' "$t" > "$TMP/brief.md"; out="$(bash "$S" "$TMP/brief.md" --brief --repo "$BR" "$@" 2>&1)"; rc=$?; }
# brief <requirements> <criteria> [out of scope]: a brief with those sections (from lines 7, 10, 13 of it)
brief() { printf '# Brief: x\n\n## Request\nDo x.\n\n## Requirements\n%s\n\n## Acceptance criteria\n%s\n\n## Out of scope\n%s\n' "$1" "$2" "${3:-- nothing}"; }
OK_CRIT='- A1: it runs. Check: `tests/test_a.sh`'

T="$(brief '- Add `tests/test_new.sh`.' '- A1: it runs. Check: `tests/test_new.sh`')"
bs "$T"; brief_out="$out"; brief_rc="$rc"
printf '%s\n' "$T" > "$TMP/brief.md"; plain_out="$(bash "$S" "$TMP/brief.md" --repo "$BR" 2>&1)"
assert "A1: --brief: no flag" test "$brief_out" = "Flags: 0 hard, 0 soft"
assert "A1: --brief: exit 0" test "$brief_rc" = 0
assert "A1: without --brief: part 1's flags" test "$plain_out" = "hard missing proof (line 10): - A1: it runs. Check: \`tests/test_new.sh\` — A1's proof tests/test_new.sh isn't found at ${BSHA:0:12}
Flags: 1 hard, 0 soft"
err="$(bash "$S" "$TMP/brief.md" --nope --repo "$BR" 2>&1 >/dev/null)"; rc=$?
assert "A1: an unknown option: exit 4" test "$rc" = 4
assert_contains "A1: the usage names --brief" "$err" "sniff: unknown option --nope. usage: sniff.sh <file or -> [--brief] [--repo <checkout>] [--commit <rev>]"
from_stdin="$(printf '%s\n' "$T" | bash "$S" - --brief --repo "$BR" 2>&1)"
assert "brief mode reads stdin too" test "$from_stdin" = "$brief_out"

bs "$(brief '- `gone.js` exists and is changed.' "$OK_CRIT")"
assert_contains "A2: a file the Requirements say exists, not at the commit" "$out" "hard missing reference (line 7): gone.js — gone.js isn't in the tree at ${BSHA:0:12}"
assert "A2: exit 2" test "$rc" = 2

ADDS='- Add `tests/test_new.sh`, `sniff.md` and `sniff.conf`.'
USES='- `sniff.md` holds the flags; `sniff.conf` holds the limits.'
bs "$(brief "$ADDS"$'\n'"$USES" '- A1: it runs. Check: `tests/test_new.sh`')"
assert "A3: files the brief adds: no flag on any line, a Check included" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief "$USES" '- A1: it runs. Check: `tests/test_new.sh`')"
assert_contains "A3: without the line that adds them: sniff.md" "$out" "hard missing reference (line 7): sniff.md — sniff.md isn't in the tree"
assert_contains "A3: without it: sniff.conf" "$out" "hard missing reference (line 7): sniff.conf — sniff.conf isn't in the tree"
assert_contains "A3: without it: tests/test_new.sh in the Check" "$out" "hard missing reference (line 10): tests/test_new.sh — tests/test_new.sh isn't in the tree"
assert_contains "A3: without it: the Check can't run" "$out" "hard no real check (line 10): - A1: it runs. Check: \`tests/test_new.sh\` — A1's Check names nothing that can run"
bs "$(brief '- `sniff.md` holds the flags.' '- A1: adds a new check. Check: `tests/gone_new.sh`')"
assert_contains "a marker word before a criterion's Check doesn't make the Check's names known" "$out" "hard missing reference (line 10): tests/gone_new.sh"
# A Check that says it adds a test file, as plan.md asks ("name these tests to add, each with its test file").
bs "$(brief '- Nothing.' $'- A1: the hint shows. Check: add `tests/test_hint.sh`, asserting the text "gh not found".\n- A2: the limit holds. Check: `tests/test_a.sh`; and\n  - add tests/test_limit.sh: a test on each side of the limit')"
assert "a Check that adds a test file: no flag, the file runs" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Then `tests/test_hint.sh` is run by `tests/run.sh`.' '- A1: the hint shows. Check: add tests/test_hint.sh, asserting the message.')"
assert "a file a Check adds is known on every line" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' '- A1: the hint shows. Check: tests/test_hint.sh asserts the message.')"
assert_contains "a Check that doesn't say it adds the file: flagged" "$out" "hard missing reference (line 10): tests/test_hint.sh"
assert_contains "a Check that doesn't say it adds the file: can't run" "$out" "hard no real check (line 10)"
# Check (...): and Checks:
bs "$(brief '- Nothing.' '- A1: CI uses smoke. Check (manual, after the PR opens): the log shows the notice.')"
assert_contains "Check (manual, ...): is a manual Check" "$out" "soft manual check (line 10): - A1: CI uses smoke. Check (manual, after the PR opens): the log shows the notice. — A1's Check is manual: nothing runs it"
assert_contains "Check (manual, ...): soft only" "$out" "Flags: 0 hard, 1 soft"
bs "$(brief '- Nothing.' $'- A1: x. Check (in CI): `tests/test_a.sh`\n- A2: y. Checks: `tests/run.sh`')"
assert "Check (in CI): and Checks: are Checks" test "$out" = "Flags: 0 hard, 0 soft"

FIX='- The test uses fixture files `c.js`, `d.js:12` and `db/migrations/009.sql`.'
bs "$(brief "$FIX"$'\n''- `c.js` and `d.js:12` show the left-out check.' '- A1: `test_old` becomes `test_new` in `c.js`, from `save()`. Check: `tests/test_a.sh`')"
assert "A4: fixture and planned names: no flag" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Change `c.js`, `d.js:12`, `db/migrations/009.sql`, test_old and test_new.' "$OK_CRIT")"
for n in "c.js — c.js isn't in the tree" "d.js:12 — d.js isn't in the tree" "db/migrations/009.sql —" "test_old — git grep doesn't find test_old" "test_new — git grep doesn't find test_new"; do
  assert_contains "A4: given as existing code in Requirements: ${n%% *} flagged" "$out" "hard missing reference (line 7): $n"
done
for m in "e.g." "for example" "a stub" "an example" "a fixture"; do
  bs "$(brief "- Names $m \`c.js\`."$'\n''- `c.js` again.' "$OK_CRIT")"
  assert "fixture marker \"$m\": the name is known on every line" test "$out" = "Flags: 0 hard, 0 soft"
done
# Only the approved markers count (fixture, stub, example, for example, e.g.): not like, such as, stubbed, examples.
for m in "like" "such as" "stubbed" "examples"; do
  bs "$(brief "- Names $m \`c.js\`." "$OK_CRIT")"
  assert_contains "\"$m\" isn't a fixture marker: the name is checked" "$out" "hard missing reference (line 7): c.js — c.js isn't in the tree"
done
bs "$(brief '- Change `export()` in `a.js`, like before.' '- A1: ok. Check: `git grep -n export`')" --commit "$C1"
assert_contains "\"like\" doesn't turn off the left-out check of its line" "$out" "hard left out (line 7): \`export()\` — \`export()\` is also called from \`b.js:12\`"
bs "$(brief '- Nothing.' '- A1: in a fixture where `c.js` calls it. Check: `tests/test_a.sh`')"
assert "a fixture marker before a criterion's Check: its names are known" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' '- A1: in a fixture where `c.js` calls it. Check: `tests/test_a.sh` runs on `c.js`')"
assert "a fixture marker before a criterion's Check: its names are known in the Check too" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' '- A1: adds `tests/test_new2.sh`. Check: `tests/test_new2.sh`')"
assert "a file a criterion adds before its Check is known, in the Check too" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' '- A1: it runs. Check: the fixture `tests/gone.sh`')"
assert_contains "a fixture marker in the Check doesn't make the Check known" "$out" "hard no real check (line 10)"

bs "$(brief '- Nothing.' $'- A2: it works well\n- A3: the page renders. Check: the page looks right\n- A4: it runs. Check: `nosuchcmd x`')"
assert_contains "A5: no Check: hard, names A2" "$out" "hard no real check (line 10): - A2: it works well — A2 has no Check"
assert_contains "A5: a Check of prose: hard, names A3" "$out" "hard no real check (line 11): - A3: the page renders. Check: the page looks right — A3's Check names nothing that can run"
assert_contains "A5: a command no one has: hard" "$out" "hard no real check (line 12): - A4: it runs. Check: \`nosuchcmd x\` — A4's Check names nothing that can run"
assert_contains "A5: three hard flags" "$out" "Flags: 3 hard, 0 soft"
assert "A5: exit 2" test "$rc" = 2
bs "$(brief '- Nothing.' $'- A1: a list:\n  - one\n\n  Check: `tests/test_a.sh`')"
assert "a Check indented under a blank line is the criterion's" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' $'- A1: a list:\n  - one\n\nCheck: `tests/test_a.sh`')"
assert_contains "a line after a blank line, not indented, isn't the criterion's" "$out" "hard no real check (line 10): - A1: a list: — A1 has no Check"
bs "$(brief $'- Before:\n  ```bash\n  # old behaviour\n  ```\n- Change `export()` in `a.js`.' '- A1: ok. Check: `git grep -n export`')" --commit "$C1"
assert_contains "a # comment in a fenced block isn't a heading: Requirements go on after it" "$out" "hard left out (line 11): \`export()\` — \`export()\` is also called from \`b.js:12\`"
bs "$(brief $'~~~\n```\n# not a heading\n~~~\n- Change `export()` in `a.js`.' '- A1: ok. Check: `git grep -n export`')" --commit "$C1"
assert_contains "a ~~~ fence ends only at ~~~, not at \`\`\`" "$out" "hard left out (line 11): \`export()\`"
bs "$(brief '- Nothing.' $'- A1: a list:\n  ```\n  # a comment\n  ```\n  Check: `tests/test_a.sh`')"
assert "a # comment in a fenced block doesn't end a criterion" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' $'- A1: a list:\n## Out\nCheck: `tests/test_a.sh`')"
assert_contains "a heading ends the criterion" "$out" "A1 has no Check"
bs "$(brief '- Nothing.' $'- A1: a list:\n  - one\n\n\n  Check: `tests/test_a.sh`')"
assert_contains "two blank lines end the criterion" "$out" "A1 has no Check"

for c in '`tests/test_a.sh`' '`tests/run.sh`' '`git grep -n x`' '`a.js:3`' 'tests/test_a.sh' '**Check:** `tests/run.sh`'; do
  bs "$(brief '- Nothing.' "- A1: it runs. Check: $c")"
  assert "A6: a Check of $c: no flag" test "$out" = "Flags: 0 hard, 0 soft"
done
bs "$(brief '- Add `tests/test_new.sh`.' '- A1: it runs. Check: `bash tests/test_new.sh -v`')"
assert "A6: a command whose first word... a test the brief adds, as a command's argument" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Add `tests/test_new.sh`.' '- A1: it runs. Check: `tests/test_new.sh -v`')"
assert "A6: a command whose first word is a file the brief adds" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Nothing.' '- A1: it runs. Check: `a.js:99`')"
assert_contains "a file:line past the end can't run" "$out" "hard no real check (line 10)"
assert_contains "a file:line past the end: also a missing reference" "$out" "hard missing reference (line 10): a.js:99 — a.js:99, but a.js has 4 lines"
bs "$(brief '- Nothing.' '- A1: it runs. Check: `git grep -n "gone.md"`')"
assert "a command's arguments aren't checked in a Check" test "$out" = "Flags: 0 hard, 0 soft"

for m in "manual: open the page" "open it manually" "by hand: open the page"; do
  bs "$(brief '- Nothing.' "- A1: the page renders. Check: $m")"
  assert_contains "A7: an explicit manual Check ($m): soft" "$out" "soft manual check (line 10): - A1: the page renders. Check: $m — A1's Check is manual: nothing runs it"
  assert_contains "A7: soft only" "$out" "Flags: 0 hard, 1 soft"
  assert "A7: exit 1" test "$rc" = 1
done
bs "$(brief '- Nothing.' '- A1: the page renders. Check: by hand, and `tests/test_a.sh`')"
assert "a manual Check that also names a test: no flag" test "$out" = "Flags: 0 hard, 0 soft"

P1=$'- Fixed, it should work.\n- `tests/run.sh` ends with ALL PASSED.'
T8="$(brief "$P1" $'- A1: it runs. Check: `tests/run.sh`\n- A2: it is complete. Check: `tests/test_a.sh`\n\nNot proven: none\n- A3: e2e passed. Check: `tests/run.sh`')"
bs "$T8"
assert_not_contains "A8: --brief: no missing proof" "$out" "missing proof"
assert_not_contains "A8: --brief: no run that didn't happen" "$out" "run that didn't happen"
assert_not_contains "A8: --brief: no weasel words" "$out" "weasel words"
assert "A8: --brief: no flag at all" test "$out" = "Flags: 0 hard, 0 soft"
printf '%s\n' "${T8/it is complete. Check: \`tests\/test_a.sh\`/it is complete}" > "$TMP/brief.md"
plain="$(bash "$S" "$TMP/brief.md" --repo "$BR" 2>&1)"
assert_contains "A8: without --brief: missing proof (Not proven: none)" "$plain" "hard missing proof (line 12): - A2: it is complete — Not proven: none (line 14)"
assert_contains "A8: without --brief: run that didn't happen" "$plain" "soft run that didn't happen (line 8)"
assert_contains "A8: without --brief: weasel words" "$plain" "soft weasel words (line 7)"

LO="$(brief '- Change `export()` in `a.js`.' '- A1: ok. Check: `git grep -n export`')"
bs "$LO" --commit "$C1"
assert "A9: exactly one left-out flag, its text (and b.js:14, the same file, not flagged: A12)" test "$out" = "hard left out (line 7): \`export()\` — \`export()\` is also called from \`b.js:12\`: in scope or out?
Flags: 1 hard, 0 soft"
assert "A9: exit 2" test "$rc" = 2
bs "$(brief '- Change `export()` in `a.js`.' '- A1: ok. Check: `git grep -n export`' '- `b.js` stays as it is.')" --commit "$C1"
assert "A9: b.js named in Out of scope: no flag" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Change the docs.' '- A1: ok. Check: `git grep -n export`' '- `export()` in `a.js`.')" --commit "$C1"
assert "A9: export() only in Out of scope: no flag" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- Change `export()` in `a.js`, e.g. `b.js`.' '- A1: ok. Check: `git grep -n export`')" --commit "$C1"
assert "a file named on a fixture line counts as named" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- `export()`, for example.' '- A1: ok. Check: `git grep -n export`')" --commit "$C1"
assert "a name on a fixture line isn't a changed name" test "$out" = "Flags: 0 hard, 0 soft"

bs "$LO"
assert_contains "A10: a caller"    "$out" "hard left out (line 7): \`export()\` — \`export()\` is also called from \`b.js:12\`: in scope or out?"
assert_contains "A10: a test, under tests/" "$out" "hard left out (line 7): \`a.js\` — \`a.js\` is also used by the test \`tests/test_a.sh:2\`: in scope or out?"
assert_contains "A10: a test, named test_*" "$out" "\`export()\` is also used by the test \`spec/test_e.js:1\`"
assert_contains "A10: a doc"       "$out" "hard left out (line 7): \`export()\` — \`export()\` is also named in the doc \`README.md:2\`: in scope or out?"
assert_contains "A10: a migration" "$out" "hard left out (line 7): \`export()\` — \`export()\` is also used by the migration \`db/migrations/001.sql:1\`: in scope or out?"
assert_contains "a migration under tests/ is a migration (the first kind that fits)" "$out" "is also used by the migration \`tests/migrations/002.sql:1\`"
assert_contains "a .md under tests/ is a test" "$out" "is also used by the test \`tests/notes.md:2\`"
assert_contains "A10: seven left-out flags" "$out" "Flags: 7 hard, 0 soft"
bs "$(brief '- Change `a.js` and `a.js:1`.' '- A1: ok. Check: `git grep -n export`')"
assert "two spellings of a file are one changed name" test "$(grep -c 'tests/test_a.sh:2' <<<"$out")" = 1

bs "$(brief '- Change `load_it()` in `lib.sh`.' "$OK_CRIT")"
assert_contains "A11: a bash call without parentheses is a caller" "$out" "hard left out (line 7): \`load_it()\` — \`load_it()\` is also called from \`run.sh:3\`: in scope or out?"
assert_not_contains "A11: one flag per file, at the first line" "$out" "run.sh:4"
assert_contains "a changed file's caller" "$out" "\`lib.sh\` is also used by \`run.sh:2\`: in scope or out?"

MANY='- Change `many()` in `m0.js`.'
bs "$(brief "$MANY" "$OK_CRIT" '- `m11.js` and `m12.js`.')"
assert "A12: 10 left-out references: 10 flags" test "$(grep -c '^hard left out' <<<"$out")" = 10
assert_not_contains "A12: 10: no \"more\" line" "$out" "more left-out"
bs "$(brief "$MANY" "$OK_CRIT" '- `m12.js`.')"
assert "A12: 11: 10 flags" test "$(grep -c '^hard left out' <<<"$out")" = 10
assert_contains "A12: 11: one line says 1 more" "$out" "(1 more left-out reference was not listed)"
assert_contains "A12: 11: the Flags line counts the listed ones" "$out" "Flags: 10 hard, 0 soft"
bs "$(brief "$MANY" "$OK_CRIT")"
assert_contains "12: 2 more, plural" "$out" "(2 more left-out references were not listed)"

C1_CRIT='- A1: ok. Check: `git grep -n x`'
bs "$(brief '- `b.js:12` says `export()`, and `b.js:13`: `// 13`.' "$C1_CRIT")" --commit "$C1"
assert_not_contains "A13: the quoted text is on that line: no flag" "$out" "quoted line"
bs "$(brief '- `a.js:3` says `return 2`.' "$C1_CRIT")" --commit "$C1"
assert_contains "A13: the quoted text isn't on that line: hard" "$out" "hard quoted line (line 7): a.js:3 \`return 2\` — line 3 of a.js doesn't have \`return 2\` at ${C1:0:12}"
assert "A13: exit 2" test "$rc" = 2
bs "$(brief '- a.js:3 has `return 2`, and `a.js:1-3` holds `return 1`.' "$C1_CRIT")" --commit "$C1"
assert_contains "a bare file:line before a quote is checked" "$out" "hard quoted line (line 7): a.js:3 \`return 2\`"
assert_not_contains "a range holds the quote on one of its lines" "$out" "a.js:1-3"
bs "$(brief '- `a.js:3`, `return 2` and (`a.js:2`). Then `x`.' "$C1_CRIT")" --commit "$C1"
assert_not_contains "a quote after a comma, or after a closing bracket, isn't the line's" "$out" "quoted line"
bs "$(brief '- Add a guard where `a.js:3` reads `return 2`.' "$C1_CRIT")" --commit "$C1"
assert_contains "a line that adds names: its quoted lines are still checked" "$out" "hard quoted line (line 7): a.js:3 \`return 2\`"
bs "$(brief $'- Add a guard where `a.js:3` reads `return 1`.\n- `a.js:3` reads `return 2`.' "$C1_CRIT")" --commit "$C1"
assert_contains "a line that adds names doesn't exempt the same file:line elsewhere" "$out" "hard quoted line (line 8): a.js:3 \`return 2\`"
assert_contains "and the true quote on the adding line: no flag" "$out" "Flags: 1 hard, 0 soft"
bs "$(brief '- Add `new.js`; `new.js:1` reads `x`.' "$C1_CRIT")" --commit "$C1"
assert "a quote of a file the brief adds: no flag" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- In another repo, `a.js:3` reads `return 2`.' "$C1_CRIT")" --commit "$C1"
assert "a quote on a line in another repo: not checked here" test "$out" = "Flags: 0 hard, 0 soft"
bs "$(brief '- `a.js:9` says `return 2`.' "$C1_CRIT")" --commit "$C1"
assert_not_contains "a file:line past the end: a missing reference, not a quoted line" "$out" "quoted line"
assert_contains "a file:line past the end: missing reference" "$out" "hard missing reference (line 7): a.js:9"
assert "brief mode: the stub claude was never called" test ! -e "$TMP/claude-calls"

echo "-- the rule and the README"
assert_contains "A15: the rule in claude/rules/pr-queue.md: a set of claims" "$(grep -n "set of claims" "$ROOT/claude/rules/pr-queue.md")" "main session that runs the queue: an agent's report is a set of claims"
assert_contains "A15: the rule names sniff.sh" "$(grep -n "sniff.sh" "$ROOT/claude/rules/pr-queue.md")" "scripts/queue/sniff.sh"
readme="$(grep -n "sniff.sh" "$ROOT/README.md")"
assert_contains "A17: README.md documents sniff.sh's arguments" "$readme" "sniff.sh <file or -> [--repo <checkout>] [--commit <rev>]"
assert_contains "A17: README.md documents sniff.sh's exit codes" "$readme" "exits 0 for no flags, 1 for soft flags only, 2 for a hard flag, and 4 when it couldn't run"
assert_contains "README.md documents --brief" "$readme" "With \`--brief\`, it sniffs a brief instead"
assert_contains "README.md's Planner item names the brief's sniff" "$(grep -n "^- Planner:" "$ROOT/README.md")" "saved next to the brief as \`<brief>-sniff.md\`"
assert_contains "the rule: show the sniff flags with the brief" "$(grep -n "sniff flags" "$ROOT/claude/rules/pr-queue.md")" "Show the user the brief, its open questions and its sniff flags"
sniff_head="$(sed -n '2,/^set -uo pipefail/p' "$ROOT/scripts/queue/sniff.sh")"
assert_contains "A17 (4b): the sniff.sh header: the --findings usage line" "$sniff_head" "sniff.sh <review file> --findings [--repo <checkout>] [--commit <rev>]"
assert_contains "A17 (4b): the sniff.sh header: the --findings paragraph" "$sniff_head" "# Findings mode (--findings, for a code or test review that needs changes"
assert_contains "A17 (4b): the sniff.sh header: the mark" "$sniff_head" '"<ref> — reference not found:'
step2="$(sed -n '/^#   2\. /,/^#   3\. /p' "$ROOT/scripts/queue/pr-queue.sh")"
assert_contains "A17 (4b): pr-queue.sh's step 2 header: sniff.sh --findings" "$step2" "(sniff.sh --findings, mechanically"
assert_contains "A17 (4b): pr-queue.sh's step 2 header: the marks" "$step2" 'the marks, "reference not found", to'
assert_contains "A17 (4b): README.md's queue line: --findings and the marks" "$(grep "^- Parallel agents:" "$ROOT/README.md")" \
  "checks the file references of each review that needs changes with \`sniff.sh --findings\` and adds the ones that aren't at the reviewed commit or its base to that file, marked \`reference not found\`"
assert_contains "A17 (4b): README.md's sniffer line: --findings" "$(grep "^- Sniffer:" "$ROOT/README.md")" \
  "With \`--findings\`, for a review that needs changes, it checks only the file references"
assert_contains "A17 (4b): README.md's sniffer line: the mark" "$(grep "^- Sniffer:" "$ROOT/README.md")" "as a soft \`reference not found\` flag"
assert_contains "A17 (4b): review.sh's REVIEW_SNIFF comment" "$(grep -A2 '^# REVIEW_SNIFF=' "$ROOT/scripts/queue/review.sh")" \
  'file references that sniff.sh --findings marked
# "reference not found")'

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


echo "-- too good to be true: a ready review, against sniff.conf"
# RV: main has a base commit; each fixture commit adds a file of <n> lines on top of it, off main.
RV="$TMP/rvrepo"; git init -q -b main "$RV"; echo base > "$RV/base.txt"; git -C "$RV" add -A; git -C "$RV" commit -q -m base
# cm <lines>: a commit off main whose diff has that many added lines; prints its sha
cm() { git -C "$RV" checkout -q -B "b$1" main; seq "$1" > "$RV/f$1.txt"; git -C "$RV" add -A; git -C "$RV" commit -q -m "f$1"; git -C "$RV" rev-parse HEAD; git -C "$RV" checkout -q main; }
C900="$(cm 900)"; C300="$(cm 300)"; C301="$(cm 301)"
# CB: 300 lines and a binary file, which has no lines
git -C "$RV" checkout -q -B bbin main; seq 300 > "$RV/t.txt"; printf '\0\1\2' > "$RV/b.bin"; git -C "$RV" add -A; git -C "$RV" commit -q -m bin
CB="$(git -C "$RV" rev-parse HEAD)"; git -C "$RV" checkout -q main
mkdir -p "$TMP/rv"
printf 'max_diff_lines=300\ncode_min_seconds=30\ncode_min_cost=0.20\ncode_min_turns=5\ntests_min_seconds=30\ntests_min_cost=0.20\ntests_min_turns=5\n' > "$TMP/th.conf"
export SNIFF_CONFIG="$TMP/th.conf"
# review <sha> <ms> <cost> <turns> [verdict] [kind] [name]: a review file and its sidecar; prints the review's path
review() {
  local f="$TMP/rv/${7:-feat-x-${1:0:12}-high}.md"
  printf '# Review of feat/x\n\nNo findings.\n\nVerdict: %s\n' "${5:-ready}" > "$f"
  python3 -I -c 'import json, sys
sha, ms, cost, turns, verdict, kind = sys.argv[1:7]
n = lambda v, t: None if v == "null" else t(v)
print(json.dumps({"v": 1, "kind": kind, "sha": sha, "duration_ms": n(ms, int), "cost_usd": n(cost, float),
                  "num_turns": n(turns, int), "verdict": verdict}))' "$1" "$2" "$3" "$4" "${5:-ready}" "${6:-code}" > "${f%.md}.json"
  echo "$f"
}
# sf <file> [args...]: sniffs a file at RV; out and rc
sf() { local f="$1"; shift; out="$(bash "$S" "$f" --repo "$RV" "$@" 2>&1)"; rc=$?; }
sf "$(review "$C900" 4000 0.05 3)"
assert_contains "A12: a too-good review is flagged, with its numbers and the thresholds" "$out" \
  "soft too good to be true (line 5): Verdict: ready — no findings on a 900-line diff in 4 s, \$0.05, 3 turns; thresholds: 300 lines, 30 s, \$0.20, 5 turns (code review)"
assert "A12: exactly one too-good flag" test "$(grep -c 'too good to be true' <<<"$out")" = 1
assert_contains "A12: soft only" "$out" "Flags: 0 hard, 1 soft"
assert "A12: exit 1" test "$rc" = 1
assert "A12: no session" test ! -e "$TMP/claude-calls"
assert "A9: a review without --session: claude never called" test ! -e "$TMP/claude-calls"
sf "$(review "$C300" 30000 0.20 5)"
assert_contains "A13: 300 lines, 30000 ms, \$0.20, 5 turns: not flagged" "$out" "Flags: 0 hard, 0 soft"
assert "A13: not flagged: exit 0" test "$rc" = 0
sf "$(review "$C301" 30000 0.20 5)"
assert_contains "A13: 301 lines: flagged" "$out" "no findings on a 301-line diff in 30 s, \$0.20, 5 turns"
sf "$(review "$C300" 29999 0.20 5)"
assert_contains "A13: 29999 ms: flagged" "$out" "no findings on a 300-line diff in 29.999 s"
sf "$(review "$C300" 30000 0.19 5)"
assert_contains "A13: \$0.19: flagged" "$out" "in 30 s, \$0.19, 5 turns"
sf "$(review "$C300" 30000 0.20 4)"
assert_contains "A13: 4 turns: flagged" "$out" "\$0.20, 4 turns; thresholds"
sf "$(review "$C900" 4000 0.05 3 "needs changes")"
assert_contains "A13: a needs-changes review on 900 lines: not flagged" "$out" "Flags: 0 hard, 0 soft"
sf "$(review "$CB" 30000 0.20 5)"
assert_contains "a binary file in the diff counts no lines" "$out" "Flags: 0 hard, 0 soft"
assert "a binary file: exit 0" test "$rc" = 0
sf "$(review "$C300" 30000 0.123 1)"
assert_contains "a cost with more digits, and 1 turn" "$out" "in 30 s, \$0.123, 1 turn;"
sf "$(review "$C900" null null null)"
assert_contains "a sidecar without numbers: only the diff, the rest unknown" "$out" "no findings on a 900-line diff in ? s, \$?, ? turns"
sf "$(review "$C300" null null null)"
assert_contains "a sidecar without numbers on a small diff: not flagged" "$out" "Flags: 0 hard, 0 soft"
printf 'max_diff_lines=300\ncode_min_seconds=1\ncode_min_cost=0.01\ncode_min_turns=1\ntests_min_seconds=30\ntests_min_cost=0.20\ntests_min_turns=5\n' > "$TMP/th2.conf"
SNIFF_CONFIG="$TMP/th2.conf" sf "$(review "$C300" 4000 0.05 3)"
assert_contains "the code review's floors apply to a code review" "$out" "Flags: 0 hard, 0 soft"
SNIFF_CONFIG="$TMP/th2.conf" sf "$(review "$C300" 4000 0.05 3 ready tests "feat-x-${C300:0:12}-tests")"
assert_contains "the test review's floors apply to a test review" "$out" "thresholds: 300 lines, 30 s, \$0.20, 5 turns (tests review)"
sf "$(review "$C900" 4000 0.05 3 ready code notes)"
assert_contains "a file not named like a review: not checked" "$out" "Flags: 0 hard, 0 soft"
sf "$(review "$C900" 4000 0.05 3 ready judge "feat-x-${C900:0:12}-judge")"
assert_contains "a judge's file: not checked" "$out" "Flags: 0 hard, 0 soft"
sf "$(review "$C900" 4000 0.05 3 ready judge "feat-x-${C900:0:12}-medium")"
assert_contains "a review's name with a sidecar of another kind (judge): not checked" "$out" "Flags: 0 hard, 0 soft"
assert "another kind: exit 0" test "$rc" = 0
f="$(review "$C900" 4000 0.05 3 ready code "feat-x-${C900:0:12}-low-notests")"
sf "$f"; assert_contains "a -notests review is checked" "$out" "900-line diff"
echo '[1, 2]' > "${f%.md}.json"; sf "$f"
assert_contains "a sidecar that isn't an object: not checked" "$out" "Flags: 0 hard, 0 soft"
echo 'not json' > "${f%.md}.json"; sf "$f"
assert_contains "a sidecar that isn't JSON: not checked" "$out" "Flags: 0 hard, 0 soft"
rm "${f%.md}.json"; sf "$f"
assert_contains "no sidecar: not checked" "$out" "Flags: 0 hard, 0 soft"
f="$(review "$C900" 4000 0.05 3)"; printf 'No findings.\n' > "$f"; sf "$f"
assert_contains "no verdict line: the flag is on line 1" "$out" "soft too good to be true (line 1): No findings."

# A14: the thresholds' error paths
f="$(review "$C900" 4000 0.05 3)"
SNIFF_CONFIG="$TMP/none.conf" sf "$f"
assert_contains "A14: a missing SNIFF_CONFIG is named" "$out" "sniff: no thresholds file: $TMP/none.conf"
assert "A14: a missing SNIFF_CONFIG: exit 4" test "$rc" = 4
grep -v '^tests_min_turns=' "$TMP/th.conf" > "$TMP/th-lack.conf"
SNIFF_CONFIG="$TMP/th-lack.conf" sf "$f"
assert_contains "A14: a missing value is named" "$out" "sniff: no tests_min_turns in $TMP/th-lack.conf"
assert "A14: a missing value: exit 4" test "$rc" = 4
tests_min_turns=1 SNIFF_CONFIG="$TMP/th-lack.conf" sf "$f"
assert_contains "a value from the environment doesn't count" "$out" "sniff: no tests_min_turns in"
sed 's/^code_min_cost=.*/code_min_cost=cheap/' "$TMP/th.conf" > "$TMP/th-nan.conf"
SNIFF_CONFIG="$TMP/th-nan.conf" sf "$f"
assert_contains "a value that isn't a number is named" "$out" "sniff: code_min_cost in $TMP/th-nan.conf must be a number, not 'cheap'"
assert "a value that isn't a number: exit 4" test "$rc" = 4
echo 'max_diff_lines=(' > "$TMP/th-bad.conf"; SNIFF_CONFIG="$TMP/th-bad.conf" sf "$f"
assert_contains "a config that bash can't read" "$out" "sniff: can't read $TMP/th-bad.conf"
assert "a config that bash can't read: exit 4" test "$rc" = 4
GONE="0123456789abcdef0123456789abcdef01234567"
sf "$(review "$GONE" 4000 0.05 3 ready code "feat-x-${GONE:0:12}-high")"
assert_contains "A14: a sidecar sha that isn't in the repo is named" "$out" "sniff: the review's commit isn't in $RV: $GONE"
assert "A14: a sidecar sha that isn't in the repo: exit 4" test "$rc" = 4
f="$(review "$C900" 4000 0.05 3)"; python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); del d["sha"]; json.dump(d, open(sys.argv[1], "w"))' "${f%.md}.json"; sf "$f"
assert_contains "a sidecar with no sha" "$out" "sniff: the review's sidecar ${f%.md}.json has no sha"
assert "a sidecar with no sha: exit 4" test "$rc" = 4
SNIFF_CONFIG="$TMP/none.conf" sn 'Plain text.'
assert "A14: plain text with a missing SNIFF_CONFIG sniffs as before" test "$out" = "Flags: 0 hard, 0 soft"
assert "A14: plain text: exit 0" test "$rc" = 0
# the default branch: master when there is no main, and none at all
RM="$TMP/rvmaster"; git init -q -b master "$RM"; echo b > "$RM/b"; git -C "$RM" add -A; git -C "$RM" commit -q -m b
git -C "$RM" checkout -q -b feat; seq 400 > "$RM/f"; git -C "$RM" add -A; git -C "$RM" commit -q -m f; CM="$(git -C "$RM" rev-parse HEAD)"
f="$(review "$CM" 40000 0.5 9)"; out="$(bash "$S" "$f" --repo "$RM" 2>&1)"
assert_contains "the default branch: master, if there is no main" "$out" "no findings on a 400-line diff"
git -C "$RM" branch -q -m master old; out="$(bash "$S" "$f" --repo "$RM" 2>&1)"; rc=$?
assert_contains "no default branch: says so" "$out" "sniff: no default branch (origin/HEAD, main or master) in $RM"
assert "no default branch: exit 4" test "$rc" = 4
git -C "$RM" checkout -q --orphan main; git -C "$RM" rm -rfq .; echo o > "$RM/o"; git -C "$RM" add -A; git -C "$RM" commit -q -m orphan
out="$(bash "$S" "$f" --repo "$RM" 2>&1)"; rc=$?
assert_contains "no common history with the default branch" "$out" "sniff: the review's commit ${CM:0:12} has no common history with main"
assert "no common history: exit 4" test "$rc" = 4
git -C "$RM" update-ref refs/remotes/origin/main "$(git -C "$RM" rev-parse old)"
git -C "$RM" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
out="$(bash "$S" "$f" --repo "$RM" 2>&1)"
assert_contains "the default branch: origin/HEAD's first" "$out" "no findings on a 400-line diff"
unset SNIFF_CONFIG

echo "-- the committed sniff.conf"
conf_vals="$(bash -c '. "$1"; for k in max_diff_lines code_min_seconds code_min_cost code_min_turns tests_min_seconds tests_min_cost tests_min_turns; do printf "%s=%s\n" "$k" "${!k-}"; done' _ "$ROOT/scripts/queue/sniff.conf")"
for k in max_diff_lines code_min_seconds code_min_cost code_min_turns tests_min_seconds tests_min_cost tests_min_turns; do
  assert "A15: sniff.conf sets $k to a number" grep -qE "^$k=[0-9]+(\.[0-9]+)?\$" <<<"$conf_vals"
done
assert_contains "A15: sniff.conf names its query" "$(grep -n 'SELECT' "$ROOT/scripts/queue/sniff.conf")" "FROM reviews WHERE kind = ? AND verdict = 'ready'"

echo "-- the session (--session): one review.sh --sniff, through a stub claude"
# A stub claude for the session: counts its calls ($TMP/session-calls), keeps its -p prompt, returns
# $TMP/session-result, or exits 1 with $TMP/session-fail. The rules come from a stand-in for ~/.claude.
mkdir -p "$TMP/sbin" "$TMP/cc" "$TMP/tmpd"
cat > "$TMP/sbin/claude" <<EOF
#!/usr/bin/env bash
echo called >> "$TMP/session-calls"
prev=""; for a in "\$@"; do [ "\$prev" = -p ] && printf '%s' "\$a" > "$TMP/session-prompt"; prev="\$a"; done
[ -f "$TMP/session-fail" ] && exit 1
python3 -I -c 'import json, sys; print(json.dumps({"result": open(sys.argv[1]).read(), "session_id": "s1"}))' "$TMP/session-result"
EOF
chmod +x "$TMP/sbin/claude"
unset REVIEW_CONFIG REVIEW_MODEL REVIEW_EFFORT REVIEW_TIMEOUT
export CLAUDE_CONFIG_DIR="$TMP/cc" REVIEW_DIR="$TMP/reviews" BRIEF_DIR="$TMP/briefs"
# ss <text> [args...]: sniffs the text at R with the session stub; out, rc, err (stderr alone)
ss() {
  local t="$1"; shift; rm -f "$TMP/session-calls" "$TMP/session-prompt"; printf '%s\n' "$t" > "$TMP/in.md"
  out="$(TMPDIR="$TMP/tmpd" PATH="$TMP/sbin:$PATH" bash "$S" "$TMP/in.md" --repo "$R" "$@" 2>"$TMP/err")"; rc=$?; err="$(cat "$TMP/err")"
}
calls() { if [ -f "$TMP/session-calls" ]; then wc -l < "$TMP/session-calls"; else echo 0; fi; }
printf '%s\n' 'Claim (line 2): Made it 10x faster. | evidence named: none | found: no | too good to be true: no measurement' \
  'Claim (line 1): See a.js:500. | evidence named: a.js:500 | found: no | too good to be true: no' \
  'Request to reviewer: Made it 10x faster. | missing: a measurement before and after | answer with: a measurement' 'Claims: 2' 'Requests: 1' > "$TMP/session-result"
TG=$'See a.js:500.\nMade it 10x faster.'
ss "$TG" --session --author reviewer --commit HEAD~1
assert "A8: exactly one session" test "$(calls)" = 1
assert_contains "A8: the session gets the checkout and the resolved commit" "$(cat "$TMP/session-prompt")" "Repo: $R, commit $OLD."
assert_contains "A8: the mechanical flags stay" "$out" "hard missing reference (line 1): a.js:500"
assert_contains "A8: a too-good claim is a soft flag" "$out" "soft too good to be true (line 2): Made it 10x faster. — no measurement"
assert_not_contains "A8: a claim marked 'no' isn't flagged" "$out" "too good to be true (line 1)"
assert_contains "A8: the request, numbered, to its author" "$out" "Request 1 to reviewer: Made it 10x faster. | missing: a measurement before and after | answer with: a measurement"
assert "A8: the request comes before the Flags line" test "$(tail -2 <<<"$out")" = "Request 1 to reviewer: Made it 10x faster. | missing: a measurement before and after | answer with: a measurement
Flags: 1 hard, 1 soft"
assert "A8: the exit code follows the flags (a hard one: 2)" test "$rc" = 2
assert_contains "the bundle has the author" "$(cat "$TMP/session-prompt")" "Author: reviewer"
assert_contains "the bundle has the text with line numbers" "$(cat "$TMP/session-prompt")" "2: Made it 10x faster."
assert_contains "the bundle has the mechanical flags" "$(cat "$TMP/session-prompt")" "## The mechanical flags (sniff.sh)

hard missing reference (line 1): a.js:500"
assert_contains "the bundle has the thresholds" "$(cat "$TMP/session-prompt")" "max_diff_lines=1039"
assert_contains "the bundle's mode" "$(cat "$TMP/session-prompt")" "Mode: claims"
assert "the bundle's temp folder and the session's scratch are removed" test -z "$(ls -A "$TMP/tmpd")"
SNIFF_CONFIG="$TMP/none.conf" ss "$TG" --session --author reviewer
assert_contains "no thresholds file: the bundle says so, and the session runs" "$(cat "$TMP/session-prompt")" "Thresholds ($TMP/none.conf): none ($TMP/none.conf not read)"
printf '%s\n' 'Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: No.' 'Request to reviewer: Plain. | missing: x | answer with: a file:line' 'Request to reviewer: Two. | missing: y | answer with: a command and its output' 'Claims: 1' 'Requests: 2' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert "A8: requests don't change the exit code (no flags: 0)" test "$rc" = 0
assert_contains "A8: requests are numbered in order" "$out" "Request 2 to reviewer: Two. | missing: y"
assert_contains "'No.' is no too-good flag" "$out" "Flags: 0 hard, 0 soft"
for v in 'no — just a rename' 'no: n/a' 'no, a rename' 'no - a rename' 'no; a rename' 'no – a rename'; do
  printf '%s\n' "Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: $v" 'Claims: 1' 'Requests: 0' > "$TMP/session-result"
  ss 'Plain.' --session --author reviewer
  assert "A12: 'too good to be true: $v' is no flag" test "$out" = "Flags: 0 hard, 0 soft"
done
for v in 'no measurement' 'nothing counted' 'no-op claimed as a 10x gain'; do
  printf '%s\n' "Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: $v" 'Claims: 1' 'Requests: 0' > "$TMP/session-result"
  ss 'Plain.' --session --author reviewer
  assert_contains "A12: 'too good to be true: $v' is still a soft flag" "$out" "soft too good to be true (line 1): Plain. — $v"
  assert_contains "A12: '$v': one soft flag" "$out" "Flags: 0 hard, 1 soft"
done
printf '%s\n' 'Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: no' 'Request to reviewer:' '**Request to reviewer: **' 'Claims: 1' 'Requests: 2' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_not_contains "a Request line with no text isn't printed" "$out" "Request"
assert "an empty Request line: only the Flags line" test "$out" = "Flags: 0 hard, 0 soft"
assert "an empty Request line: exit 0" test "$rc" = 0
printf '%s\n' '- **Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: "100 %" with nothing counted**' 'Claim (line 1): Plain. | evidence named: none' 'Claims: 2' 'Requests: 0' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_contains "a Claim line in Markdown is read" "$out" "soft too good to be true (line 1): Plain. — \"100 %\" with nothing counted"
assert_contains "a Claim line without the too-good field: no flag" "$out" "Flags: 0 hard, 1 soft"
assert "soft only: exit 1" test "$rc" = 1
printf '%s\n' '1. Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: no measurement' '2) **Request to reviewer: Plain. | missing: m | answer with: a measurement**' '**Claims: 1**' '**Requests: 1**' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_contains "a numbered Claim line is read" "$out" "soft too good to be true (line 1): Plain. — no measurement"
assert_contains "a numbered Request line in bold is read, without the bold" "$out" "Request 1 to reviewer: Plain. | missing: m | answer with: a measurement
Flags:"
ss "$TG"
assert "A9: without --session no session" test "$(calls)" = 0
assert "A9: and the never-called stub wasn't called" test ! -e "$TMP/claude-calls"

echo "-- the count line (Claims: <n>)"
printf 'Claims: 0\nRequests: 0\n' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert "Claims: 0 with no Claim lines: a text with no claims, no flag" test "$out" = "Flags: 0 hard, 0 soft"
assert "Claims: 0: exit 0" test "$rc" = 0
: > "$TMP/session-result"; ss 'Plain.' --session --author reviewer
assert_contains "an empty result: the session didn't run" "$err" 'sniff: the session didn'"'"'t run: its result has no "Claims: <n>" line (empty or cut off)'
assert "an empty result: exit 4" test "$rc" = 4
assert "an empty result: nothing on stdout" test -z "$out"
printf '%s\n' 'Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: no measurement' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_contains "a result cut off before the count line: didn't run" "$err" 'its result has no "Claims: <n>" line (empty or cut off)'
assert "cut off: exit 4" test "$rc" = 4
printf '%s\n' 'Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: no' 'Claims: 2' 'Requests: 0' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_contains "a count over the Claim lines read: didn't run" "$err" 'sniff: the session didn'"'"'t run: its result says "Claims: 2" but has 1 Claim line'
assert "a count over: exit 4" test "$rc" = 4
assert "a count of one line: singular, and the whole message" test "$err" = 'sniff: the session didn'"'"'t run: its result says "Claims: 2" but has 1 Claim line'
printf '%s\n' 'Claim (line 1): A. | too good to be true: no' 'Claim (line 1): B. | too good to be true: no' 'Claims: 1' 'Requests: 0' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert_contains "a count under the Claim lines read: didn't run" "$err" 'its result says "Claims: 1" but has 2 Claim lines'
assert "a count under: exit 4" test "$rc" = 4
assert "a count of two lines: plural, and the whole message" test "$err" = 'sniff: the session didn'"'"'t run: its result says "Claims: 1" but has 2 Claim lines'
printf '%s\n' 'Claims: 5' 'Claim (line 1): A. | too good to be true: no' 'Claims: 1' 'Requests: 0' > "$TMP/session-result"
ss 'Plain.' --session --author reviewer
assert "the last count line counts" test "$rc" = 0
printf 'Answered: 0\n' > "$TMP/session-result"; ss 'Plain.' --session --author reviewer
assert_contains "an Answered count in a claims run is no Claims line" "$err" 'its result has no "Claims: <n>" line'
echo "-- the count line (Requests: <n>)"
printf '%s\n' 'Claim (line 1): Plain. | evidence named: none | found: no | too good to be true: no' 'Request 1 to developer: Plain. | missing: m | answer with: a file:line' 'Claims: 1' 'Requests: 1' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert "a numbered Request line from the session is read: the request, then Flags" test "$out" = "Request 1 to developer: Plain. | missing: m | answer with: a file:line
Flags: 0 hard, 0 soft"
assert "a numbered Request line: exit 0" test "$rc" = 0
printf '%s\n' 'Request to developer: Plain. | missing: m | answer with: a file:line' 'Claims: 0' 'Requests: 1' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert_contains "an unnumbered Request line still works" "$out" "Request 1 to developer: Plain. | missing: m | answer with: a file:line"
printf 'Claims: 0\nRequests: 0\n' > "$TMP/session-result"; ss 'Plain.' --session --author developer
assert "Requests: 0 with no requests: no flag" test "$out" = "Flags: 0 hard, 0 soft"
assert "Requests: 0: exit 0" test "$rc" = 0
printf '%s\n' 'Request 1 to developer: Plain. | missing: m | answer with: a file:line' 'Claims: 0' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert "no Requests line: didn't run, the whole message" test "$err" = 'sniff: the session didn'"'"'t run: its result has no "Requests: <n>" line (empty or cut off)'
assert "no Requests line: exit 4" test "$rc" = 4
assert "no Requests line: nothing on stdout" test -z "$out"
printf '%s\n' 'Request 1 to developer: Plain. | missing: m | answer with: a file:line' 'Claims: 0' 'Requests: 0' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert "a Requests count under the lines read: didn't run, the whole message" test "$err" = 'sniff: the session didn'"'"'t run: its result says "Requests: 0" but has 1 Request line'
assert "a Requests count under: exit 4" test "$rc" = 4
printf '%s\n' 'Request to developer: A. | missing: m | answer with: a file:line' 'Request 2 to developer: B. | missing: m | answer with: a file:line' 'Claims: 0' 'Requests: 3' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert "a Requests count over the lines read: didn't run, the whole message" test "$err" = 'sniff: the session didn'"'"'t run: its result says "Requests: 3" but has 2 Request lines'
assert "a Requests count over: exit 4" test "$rc" = 4

echo "-- the author"
printf 'Claim (line 1): x | evidence named: none | found: no | too good to be true: no\nClaims: 1\nRequests: 0\n' > "$TMP/session-result"
ss 'Plain.' --session --author developer
assert_contains "A10: --author developer reaches the session's prompt" "$(cat "$TMP/session-prompt")" "Author: developer"
mkdir -p "$TMP/au"; echo 'Plain.' > "$TMP/au/r.md"
sa() { rm -f "$TMP/session-prompt"; out="$(PATH="$TMP/sbin:$PATH" bash "$S" "$@" --repo "$R" 2>&1)"; rc=$?; }
echo '{"kind": "tests"}' > "$TMP/au/r.json"; sa "$TMP/au/r.md" --session
assert_contains "A10: a sidecar of kind tests gives reviewer" "$(cat "$TMP/session-prompt")" "Author: reviewer"
echo '{"kind": "code"}' > "$TMP/au/r.json"; sa "$TMP/au/r.md" --session
assert_contains "a sidecar of kind code gives reviewer" "$(cat "$TMP/session-prompt")" "Author: reviewer"
echo '{"kind": "plan"}' > "$TMP/au/r.json"; sa "$TMP/au/r.md" --session
assert_contains "A10: a sidecar of kind plan gives planner" "$(cat "$TMP/session-prompt")" "Author: planner"
sa "$TMP/au/r.md" --session --author developer
assert_contains "--author wins over the sidecar" "$(cat "$TMP/session-prompt")" "Author: developer"
echo '{"kind": "judge"}' > "$TMP/au/r.json"; sa "$TMP/au/r.md" --session
assert_contains "A10: a sidecar of another kind: no author, and --author named" "$out" "sniff: no author for the session: give --author planner, developer or reviewer (no sidecar $TMP/au/r.json of kind code, tests or plan)"
assert "A10: no author: exit 4" test "$rc" = 4
assert "A10: no author: no session" test ! -e "$TMP/session-prompt"
rm "$TMP/au/r.json"; sa "$TMP/au/r.md" --session
assert_contains "A10: no author and no sidecar: --author named" "$out" "give --author planner, developer or reviewer"
assert "A10: no author and no sidecar: exit 4" test "$rc" = 4
echo 'x' > "$TMP/au/plain"; echo '{"kind": "plan"}' > "$TMP/au/plain.json"; sa "$TMP/au/plain" --session
assert_contains "a sidecar next to a file without .md: <file>.json" "$(cat "$TMP/session-prompt")" "Author: planner"
out="$(echo x | PATH="$TMP/sbin:$PATH" bash "$S" - --session --repo "$R" 2>&1)"; rc=$?
assert_contains "stdin: no author" "$out" "give --author planner, developer or reviewer (the text is from stdin)"
assert "stdin: exit 4" test "$rc" = 4
sn 'Plain.' --session --author boss
assert_contains "A10: --author boss is named" "$out" "sniff: unknown author 'boss': --author takes planner, developer or reviewer"
assert "A10: --author boss: exit 4" test "$rc" = 4
sn 'Plain.' --author
assert_contains "--author with no value" "$out" "sniff: --author needs planner, developer or reviewer"
assert "--author with no value: exit 4" test "$rc" = 4
sn 'Plain.' --author planner
assert "--author without --session: no session, as before" test "$out" = "Flags: 0 hard, 0 soft"

echo "-- a failed session"
touch "$TMP/session-fail"; ss 'Plain.' --session --author reviewer; rm "$TMP/session-fail"
assert_contains "A11: a failed session: the reason on stderr" "$err" "sniff: the session didn't run: claude -p failed (exit 1)"
assert "A11: a failed session: exit 4" test "$rc" = 4
assert_not_contains "A11: a failed session isn't an error in the sniff" "$err" "the sniff failed"
assert "A11: a failed session: nothing on stdout" test -z "$out"
assert "a failed session: no temp folder left" test -z "$(ls -A "$TMP/tmpd")"
REVIEW_CONFIG="$TMP/none.conf" ss 'Plain.' --session --author reviewer
assert_contains "a session that doesn't start: review.sh's reason" "$err" "sniff: the session didn't run: missing $TMP/none.conf"
assert "a session that doesn't start: exit 4" test "$rc" = 4

echo "-- one answer round (--answer)"
printf '%s\n' 'soft too good to be true (line 2): Made it 10x faster. — no measurement' \
  'Request 1 to reviewer: Made it 10x faster. | missing: a measurement before and after | answer with: a file:line' 'Flags: 0 hard, 1 soft' > "$TMP/earlier.txt"
printf 'Answered 1: yes — a.js:100 has the measurement\nAnswered: 1\n' > "$TMP/session-result"
ss $'Answer 1: the measurement is at a.js:100.' --answer "$TMP/earlier.txt"
assert "A16: an answer with evidence the session confirms: no flag" test "$out" = "Flags: 0 hard, 0 soft"
assert "A16: answered: exit 0" test "$rc" = 0
assert "A16: one session" test "$(calls)" = 1
assert_contains "the answer's bundle: mode answer" "$(cat "$TMP/session-prompt")" "Mode: answer"
assert_contains "the answer's bundle: the earlier requests" "$(cat "$TMP/session-prompt")" "Request 1 to reviewer: Made it 10x faster."
assert_contains "the answer's author defaults to the requests' author" "$(cat "$TMP/session-prompt")" "Author: reviewer"
ss $'Intro.\nAnswer 1: the measurement is at a.js:500.' --answer "$TMP/earlier.txt"
assert_contains "A16: an answer citing a line past the end: hard, naming the claim" "$out" "hard unsupported after one round (line 2): Made it 10x faster. — Answer 1 has a hard flag (line 2)"
assert "A16: past the end: exit 2" test "$rc" = 2
ss 'No answers here.' --answer "$TMP/earlier.txt"
assert_contains "A16: no Answer 1: hard, naming the claim" "$out" "hard unsupported after one round (line 1): Made it 10x faster. — Request 1 has no Answer 1: block"
assert "A16: no Answer 1: exit 2" test "$rc" = 2
printf 'Answered 1: no — it argues, with no measurement\nAnswered: 1\n' > "$TMP/session-result"
ss 'Answer 1: trust me.' --answer "$TMP/earlier.txt"
assert_contains "the session says no: hard, with its reason" "$out" "hard unsupported after one round (line 1): Made it 10x faster. — the session found the evidence missing in Answer 1: it argues, with no measurement"
assert "the session says no: exit 2" test "$rc" = 2
printf 'Nothing about it.\nAnswered: 0\n' > "$TMP/session-result"
ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "the session doesn't answer for it: hard" "$out" "the session found the evidence missing in Answer 1: the session didn't answer for it"
printf '**Answered 1: yes**\nAnswered: 1\n' > "$TMP/session-result"
ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert "an Answered line in Markdown is read" test "$out" = "Flags: 0 hard, 0 soft"
printf '1. Answered 1: yes — ok\nAnswered: 1\n' > "$TMP/session-result"
ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert "a numbered Answered line is read" test "$out" = "Flags: 0 hard, 0 soft"
printf 'Answered 1: yes — a.js:100 has it\nAnswered: 1\n' > "$TMP/session-result"
for a in '**Answer 1**: the measurement is at a.js:100.' '**Answer 1:** the measurement is at a.js:100.' '1. Answer 1: the measurement is at a.js:100.' '1) Answer 1: the measurement is at a.js:100.'; do
  ss "$a" --answer "$TMP/earlier.txt"
  assert "A13: an answer block that starts '${a%%:*}…' is read: no flag" test "$out" = "Flags: 0 hard, 0 soft"
  assert "A13: '${a%%:*}…': exit 0" test "$rc" = 0
done
ss 'Answers 1: the measurement is at a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "A13: 'Answers 1:' is no answer block" "$out" "Request 1 has no Answer 1: block"
assert "A13: 'Answers 1:': exit 2" test "$rc" = 2
printf '%s\n' 'Request 1 to reviewer: A. | missing: a | answer with: a file:line' 'Request 2 to reviewer: B. | missing: b | answer with: a file:line' > "$TMP/earlier2.txt"
printf 'Answered 1: yes — ok\nAnswered 2: yes — ok\nAnswered: 2\n' > "$TMP/session-result"
ss $'Answer 1: a.js:100.\nAnswer 2: a.js:500.' --answer "$TMP/earlier2.txt"
assert_not_contains "a block ends at the next one: Answer 1 is clear" "$out" "(line 1): A."
assert_contains "and Answer 2 has its own hard flag" "$out" "hard unsupported after one round (line 2): B. — Answer 2 has a hard flag (line 2)"
printf 'Answered 1: yes — ok\nAnswered: 1\n' > "$TMP/session-result"
ss $'Answer 1: the measurement is below.\nIt is at a.js:500.' --answer "$TMP/earlier.txt"
assert_contains "a hard flag on a later line of the block counts" "$out" "hard unsupported after one round (line 1): Made it 10x faster. — Answer 1 has a hard flag (line 2)"
printf 'Answered 1: yes — ok\nRequest to reviewer: More? | missing: m | answer with: a file:line\nAnswered: 1\n' > "$TMP/session-result"
ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt" --author developer
assert_not_contains "A17: an answer run prints no Request line" "$out" "Request"
assert "A17: an answer run: one session" test "$(calls)" = 1
assert_contains "--author wins in an answer run" "$(cat "$TMP/session-prompt")" "Author: developer"
: > "$TMP/session-result"; ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "--answer: an empty result: didn't run" "$err" 'sniff: the session didn'"'"'t run: its result has no "Answered: <n>" line (empty or cut off)'
assert "--answer: an empty result: exit 4" test "$rc" = 4
assert "--answer: an empty result: nothing on stdout" test -z "$out"
printf 'Answered 1: yes — ok\n' > "$TMP/session-result"; ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "--answer: cut off before the count line: didn't run" "$err" 'its result has no "Answered: <n>" line (empty or cut off)'
assert "--answer: cut off: exit 4" test "$rc" = 4
printf 'Answered 1: yes — ok\nAnswered: 2\n' > "$TMP/session-result"; ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "--answer: a count that disagrees: didn't run" "$err" 'its result says "Answered: 2" but has 1 Answered line'
assert "--answer: a count that disagrees: exit 4" test "$rc" = 4
printf 'Claims: 0\n' > "$TMP/session-result"; ss 'Answer 1: a.js:100.' --answer "$TMP/earlier.txt"
assert_contains "--answer: a Claims count is no Answered line" "$err" 'its result has no "Answered: <n>" line'
printf 'Flags: 0 hard, 0 soft\n' > "$TMP/norequests.txt"
ss 'Answer 1: a.js:100.' --answer "$TMP/norequests.txt"
assert_contains "A17: an earlier output with no Request lines" "$err" "sniff: no Request lines in $TMP/norequests.txt"
assert "A17: no Request lines: exit 4" test "$rc" = 4
assert "A17: no Request lines: no session" test "$(calls)" = 0
sn 'Plain.' --answer "$TMP/nope.txt"
assert_contains "--answer: a missing earlier output is named" "$out" "sniff: no such file: $TMP/nope.txt"
assert "--answer: a missing file: exit 4" test "$rc" = 4
sn 'Plain.' --answer
assert_contains "--answer with no value" "$out" "sniff: --answer needs the earlier sniff output"

echo "-- findings mode (--findings): a review's file references, at the commit or its base"
# FR: main has long.txt (10 lines), gone.txt (5), lib/old.js (5) and keep.sh; the branch feat shortens long.txt
# to 4 lines, deletes gone.txt and lib/old.js and adds new.txt (2 lines). HEAD stays on main.
FR="$TMP/frepo"; git init -q -b main "$FR"; seq 10 > "$FR/long.txt"; seq 5 > "$FR/gone.txt"; echo 'echo keep' > "$FR/keep.sh"
mkdir -p "$FR/lib"; seq 5 > "$FR/lib/old.js"
git -C "$FR" add -A; git -C "$FR" commit -q -m base; FB="$(git -C "$FR" rev-parse --short=12 HEAD)"
git -C "$FR" checkout -q -b feat; seq 4 > "$FR/long.txt"; git -C "$FR" rm -q gone.txt lib/old.js; seq 2 > "$FR/new.txt"
git -C "$FR" add -A; git -C "$FR" commit -q -m feat; FC="$(git -C "$FR" rev-parse HEAD)"; FS="${FC:0:12}"; git -C "$FR" checkout -q main
rm -f "$TMP/claude-calls" "$TMP/session-calls"
# fs <text> [args...]: --findings on the text, at feat in FR (both stub claudes on PATH); out, rc, err (stderr)
fs() {
  local t="$1"; shift; printf '%s\n' "$t" > "$TMP/review.md"
  out="$(PATH="$TMP/sbin:$PATH" bash "$S" "$TMP/review.md" --findings --repo "$FR" --commit feat "$@" 2>"$TMP/err")"; rc=$?; err="$(cat "$TMP/err")"
}
fs 'important: long.txt:20 is where the bug is.'
assert "A1 (4b): past the end at both: the mark, with both lengths" test "$out" = \
  "soft missing reference (line 1): long.txt:20 — reference not found: long.txt:20, but long.txt has 4 lines at $FS and 10 at the base $FB
Flags: 0 hard, 1 soft"
assert "A1 (4b): a mark: exit 1" test "$rc" = 1
fs $'Intro.\nnew.txt:9 and gone.txt:9.'
assert_contains "A1 (4b): a file only at the commit: isn't at the base" "$out" \
  "soft missing reference (line 2): new.txt:9 — reference not found: new.txt:9, but new.txt has 2 lines at $FS and isn't at the base $FB"
assert_contains "A1 (4b): a file only at the base: isn't at the commit" "$out" \
  "soft missing reference (line 2): gone.txt:9 — reference not found: gone.txt:9, but gone.txt isn't at $FS and has 5 lines at the base $FB"
assert_contains "A1 (4b): two marks, soft" "$out" "Flags: 0 hard, 2 soft"
fs 'Last line new.txt:2, one past it new.txt:3.'
assert_not_contains "A2 (4b): the last line at the commit isn't marked" "$out" "new.txt:2 —"
assert_contains "A2 (4b): one past the last line is marked" "$out" \
  "soft missing reference (line 1): new.txt:3 — reference not found: new.txt:3, but new.txt has 2 lines at $FS and isn't at the base $FB"
assert_contains "A2 (4b): the line boundary: one mark" "$out" "Flags: 0 hard, 1 soft"
fs 'Ranges new.txt:1-2 and new.txt:1-3.'
assert_not_contains "A2 (4b): a range ending on the last line isn't marked" "$out" "new.txt:1-2 —"
assert_contains "A2 (4b): a range ending one past it is marked" "$out" "soft missing reference (line 1): new.txt:1-3 — reference not found: new.txt:1-3, but new.txt has 2 lines at $FS"
assert_contains "A2 (4b): ranges: one mark" "$out" "Flags: 0 hard, 1 soft"
fs 'Columns new.txt:2:7 and new.txt:3:1.'
assert_not_contains "A2 (4b): file:line:col on the last line isn't marked (the column isn't the line)" "$out" "new.txt:2:7 —"
assert_contains "A2 (4b): file:line:col counts as its line" "$out" "soft missing reference (line 1): new.txt:3:1 — reference not found: new.txt:3:1, but new.txt has 2 lines at $FS"
assert_contains "A2 (4b): columns: one mark" "$out" "Flags: 0 hard, 1 soft"
fs 'At the base: long.txt:10, one past it long.txt:11.'
assert_not_contains "A3 (4b): the base's last line isn't marked" "$out" "long.txt:10 —"
assert_contains "A3 (4b): one past the base's last line is marked" "$out" "soft missing reference (line 1): long.txt:11 — reference not found: long.txt:11, but long.txt has 4 lines at $FS and 10 at the base $FB"
fs 'The old side: long.txt:8, gone.txt:3, gone.txt and `gone.txt`.'
assert "A3 (4b): a line or a file only on the old side isn't marked" test "$out" = "Flags: 0 hard, 0 soft"
assert "A3 (4b): the old side: exit 0" test "$rc" = 0
fs 'In a folder, only at the base: old.js, old.js:3 and lib/old.js:5.'
assert "A3 (4b): a file in a folder, only at the base, by its base name or path: not marked" test "$out" = "Flags: 0 hard, 0 soft"
fs 'Past its end at the base: old.js:6.'
assert_contains "A3 (4b): a file in a folder, only at the base: past its end there is marked" "$out" \
  "soft missing reference (line 1): old.js:6 — reference not found: old.js:6, but old.js isn't at $FS and has 5 lines at the base $FB"
fs 'Neither: nothere.txt:1 and nothere.sh.'
assert_contains "A3 (4b): a file:line at neither" "$out" "soft missing reference (line 1): nothere.txt:1 — reference not found: nothere.txt isn't in the tree at $FS or at the base $FB"
assert_contains "A3 (4b): a file at neither" "$out" "soft missing reference (line 1): nothere.sh — reference not found: nothere.sh isn't in the tree at $FS or at the base $FB"
fs $'important: x is broken. Fix: add missing4b.txt and gone4b.sh:3\nThen missing4b.txt is cited.'
assert_not_contains "A4 (4b): a file after Fix: isn't checked" "$out" "(line 1)"
assert_contains "A4 (4b): the same file before a Fix: (on another line) is marked" "$out" \
  "soft missing reference (line 2): missing4b.txt — reference not found: missing4b.txt isn't in the tree at $FS or at the base $FB"
assert_contains "A4 (4b): Fix: one mark" "$out" "Flags: 0 hard, 1 soft"
fs 'See nothere.txt:1. suggested fix: create missing4b.txt'
assert_contains "A4 (4b): the text before a fix: (any case) is checked" "$out" "(line 1): nothere.txt:1 —"
assert_not_contains "A4 (4b): the text after a fix: (any case) isn't" "$out" "missing4b.txt"
fs '- **Fix:** add missing4b.txt'
assert "A4 (4b): a bold **Fix:** label" test "$out" = "Flags: 0 hard, 0 soft"
fs 'The prefix: missing4b.txt'
assert_contains "A4 (4b): fix: inside a word is no Fix:" "$out" "(line 1): missing4b.txt —"
fs $'Sniff: x.txt:99 | x.txt:99 | y\n- **Sniff:** y.txt:9 | y.txt:9 | z\n1. Sniff: z.txt:9 | z.txt:9 | z'
assert "A4 (4b): Sniff: request lines aren't checked" test "$out" = "Flags: 0 hard, 0 soft"
fs 'the docs say Sniff: x.txt:99 | x.txt:99 | y'
assert_contains "A4 (4b): a Sniff: in the middle of a line is no request: checked" "$out" "(line 1): x.txt:99 —"
CLAIMS=$'Covered by test_nothere and `gone()`.\nAll tests pass, the e2e suite passed.\nProbably fixed now.'
fs "$CLAIMS"
assert "A4 (4b): test_<word>s, name()s, runs and weasel words aren't checked" test "$out" = "Flags: 0 hard, 0 soft"
fs $'- A1: it works\n\nNot proven: none'
assert "A4 (4b): proof (Not proven: none) isn't checked" test "$out" = "Flags: 0 hard, 0 soft"
out="$(bash "$S" "$TMP/review.md" --repo "$FR" --commit feat 2>&1)"
assert_contains "the same text in the default mode: Not proven: none" "$out" "hard missing proof (line 1): - A1: it works — Not proven: none (line 3)"
fs "$CLAIMS"
out="$(bash "$S" "$TMP/review.md" --repo "$FR" --commit feat 2>&1)"
assert_contains "the same text in the default mode: test_nothere" "$out" "hard missing reference (line 1): test_nothere"
assert_contains "the same text in the default mode: gone()" "$out" "hard missing reference (line 1): gone()"
assert_contains "the same text in the default mode: the run" "$out" "soft run that didn't happen (line 2)"
assert_contains "the same text in the default mode: the weasel word" "$out" "soft weasel words (line 3)"
fs 'Logs in /tmp/x4b.txt and ~/x4b.md, the file `<branch>-<sha>-sniff.md`, $STATE/x4b.txt and ../x4b.sh.'
assert "A4 (4b): absolute, ~/, placeholder, \$VAR and ../ paths aren't checked" test "$out" = "Flags: 0 hard, 0 soft"
fs 'Served on localhost:3000 at 10:30, in step:4 of v1.2:3.'
assert "A4 (4b): a word:<n> that isn't a file isn't checked" test "$out" = "Flags: 0 hard, 0 soft"
fs 'This adds a new file, nothere4b.sh.'
assert_contains "A4 (4b): marker words don't leave a line alone" "$out" "(line 1): nothere4b.sh —"
# A ready review with a sidecar past sniff.conf's thresholds: too good to be true in the default mode, not here.
mkdir -p "$TMP/rv4b"; RVF="$TMP/rv4b/feat-$FS-high.md"; printf '# Review of feat\n\nNo findings.\n\nVerdict: ready\n' > "$RVF"
printf '{"v": 1, "kind": "code", "sha": "%s", "duration_ms": 1000, "cost_usd": 0.01, "num_turns": 1, "verdict": "ready"}\n' "$FC" > "${RVF%.md}.json"
out="$(SNIFF_CONFIG="$TMP/th.conf" bash "$S" "$RVF" --repo "$FR" --commit feat 2>&1)"
assert_contains "the ready review in the default mode: too good to be true" "$out" "soft too good to be true (line 5)"
out="$(SNIFF_CONFIG="$TMP/th.conf" PATH="$TMP/sbin:$PATH" bash "$S" "$RVF" --findings --repo "$FR" --commit feat 2>&1)"; rc=$?
assert "A4 (4b): --findings ignores the sidecar: no too good to be true" test "$out" = "Flags: 0 hard, 0 soft"
assert "A4 (4b): the sidecar ignored: exit 0" test "$rc" = 0
out="$(SNIFF_CONFIG="$TMP/none.conf" bash "$S" "$RVF" --repo "$FR" --commit feat 2>&1)"
assert_contains "the ready review in the default mode, with no sniff.conf: didn't run" "$out" "sniff: no thresholds file: $TMP/none.conf"
out="$(SNIFF_CONFIG="$TMP/none.conf" bash "$S" "$RVF" --findings --repo "$FR" --commit feat 2>&1)"
assert "--findings reads no sniff.conf" test "$out" = "Flags: 0 hard, 0 soft"
# The events file isn't opened: a FIFO with no writer would block an open.
mkfifo "$TMP/ev/fifo.jsonl"
out="$(STATS_EVENTS_FILE="$TMP/ev/fifo.jsonl" timeout 20 bash "$S" "$RVF" --findings --repo "$FR" --commit feat 2>&1)"; rc=$?
assert "--findings opens no events file" test "$rc $out" = "0 Flags: 0 hard, 0 soft"
fs $'# Review of feat at x (/code-review high, cost $0.30, 1 s, opus at high effort)\n\nimportant: long.txt:4, new.txt:2, keep.sh and `long.txt:1-4`: broken\n\nVerdict: needs changes'
assert "A5 (4b): only valid references: only the Flags line" test "$out" = "Flags: 0 hard, 0 soft"
assert "A5 (4b): only valid references: exit 0" test "$rc" = 0
# --commit and --repo arrive: without --commit, the checkout's HEAD (main), where new.txt isn't.
printf '%s\n' 'See new.txt:1.' > "$TMP/review.md"
out="$(cd "$FR" && bash "$S" "$TMP/review.md" --findings 2>&1)"
assert_contains "no --commit: at HEAD, with HEAD as its own base" "$out" \
  "soft missing reference (line 1): new.txt:1 — reference not found: new.txt isn't in the tree at $FB or at the base $FB"
fs 'See new.txt:1.'
assert "--commit feat: new.txt:1 is there" test "$out" = "Flags: 0 hard, 0 soft"
# main moves on after feat branched (long.txt down to 2 lines): the base is still the merge-base, not main's tip.
seq 2 > "$FR/long.txt"; git -C "$FR" commit -qam "main: shorter"; FM="$(git -C "$FR" rev-parse --short=12 main)"
fs 'Old side: long.txt:10, past it long.txt:20.'
assert_not_contains "A3 (4b): main moved: a line at the merge-base isn't marked" "$out" "long.txt:10 —"
assert_contains "A3 (4b): main moved: the reason names the merge-base" "$out" \
  "soft missing reference (line 1): long.txt:20 — reference not found: long.txt:20, but long.txt has 4 lines at $FS and 10 at the base $FB"
assert_not_contains "A3 (4b): main moved: not main's tip" "$out" "$FM"
# The guards.
fs 'See long.txt:20.' --brief
assert "A6 (4b): --findings --brief: exit 4" test "$rc" = 4
assert "A6 (4b): --findings --brief: says why" test "$err" = "sniff: --findings takes no --brief, --session or --answer"
fs 'See long.txt:20.' --session --author reviewer
assert "A6 (4b): --findings --session: exit 4" test "$rc" = 4
assert "A6 (4b): --findings --session: says why" test "$err" = "sniff: --findings takes no --brief, --session or --answer"
assert "A6 (4b): --findings --session: nothing on stdout" test -z "$out"
fs 'See long.txt:20.' --answer "$TMP/earlier.txt"
assert "A6 (4b): --findings --answer: exit 4" test "$rc" = 4
assert "A6 (4b): --findings --answer: says why" test "$err" = "sniff: --findings takes no --brief, --session or --answer"
err="$(bash "$S" "$TMP/review.md" --session --findings --repo "$FR" 2>&1 >/dev/null)"; rc=$?
assert "A6 (4b): --session before --findings: exit 4" test "$rc" = 4
assert "A6 (4b): --session before --findings: says why" test "$err" = "sniff: --findings takes no --brief, --session or --answer"
err="$(SNIFF_IN_SESSION=1 bash "$S" "$TMP/review.md" --findings --repo "$FR" 2>&1 >"$TMP/nested.out")"; rc=$?
assert "A6 (4b): SNIFF_IN_SESSION=1 --findings: exit 4" test "$rc" = 4
assert "A6 (4b): SNIFF_IN_SESSION=1 --findings: says why" test "$err" = "sniff: a sniff doesn't start another sniff"
assert "A6 (4b): SNIFF_IN_SESSION=1 --findings: nothing printed" test ! -s "$TMP/nested.out"
# No default branch (only trunk), then no merge-base (an unrelated main): the commit only.
NB="$TMP/nobase"; git init -q -b trunk "$NB"; seq 3 > "$NB/one.txt"; git -C "$NB" add -A; git -C "$NB" commit -q -m one
NS="$(git -C "$NB" rev-parse --short=12 HEAD)"
printf '%s\n' 'See one.txt:3, one.txt:4 and gone.txt.' > "$TMP/review.md"
out="$(bash "$S" "$TMP/review.md" --findings --repo "$NB" 2>&1)"; rc=$?
assert_contains "A6 (4b): no default branch: a line past the end, at the commit only" "$out" \
  "soft missing reference (line 1): one.txt:4 — reference not found: one.txt:4, but one.txt has 3 lines at $NS (no base: no default branch)"
assert_contains "A6 (4b): no default branch: a file, at the commit only" "$out" \
  "soft missing reference (line 1): gone.txt — reference not found: gone.txt isn't in the tree at $NS (no base: no default branch)"
assert_not_contains "A6 (4b): no default branch: the last line isn't marked" "$out" "one.txt:3 —"
assert_contains "A6 (4b): no default branch: two marks" "$out" "Flags: 0 hard, 2 soft"
assert "A6 (4b): no default branch: exit 1" test "$rc" = 1
git -C "$NB" checkout -q --orphan main; git -C "$NB" rm -rfq .; seq 9 > "$NB/one.txt"; git -C "$NB" add -A; git -C "$NB" commit -q -m unrelated
out="$(bash "$S" "$TMP/review.md" --findings --repo "$NB" --commit trunk 2>&1)"
assert_contains "no merge-base with main: at the commit only" "$out" \
  "soft missing reference (line 1): one.txt:4 — reference not found: one.txt:4, but one.txt has 3 lines at $NS (no base: no default branch)"
assert "A6 (4b): no --findings run called claude" test ! -e "$TMP/claude-calls"
assert "A6 (4b): no --findings run called the session stub" test ! -e "$TMP/session-calls"

finish
