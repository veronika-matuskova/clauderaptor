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
assert_contains "a marker word in a criterion doesn't make its Check known" "$out" "hard missing reference (line 10): tests/gone_new.sh"

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
