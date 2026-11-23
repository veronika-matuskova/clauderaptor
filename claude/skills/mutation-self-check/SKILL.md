---
name: mutation-self-check
description: Run a small mutation check of your own changed code, in this session, before `pr-queue.sh add`. Use it every time you are about to queue a branch.
---

Check that the tests of your change catch real bugs, before the queue's test review does. Do it yourself, in
this session, one step at a time. The machine is WSL with 8 GB and other agents run at the same time.

## 1. Start clean

Commit all your work first. Then check that `git status --porcelain` prints nothing. If it prints anything,
commit or stop: `git restore` below would also wipe uncommitted work.

## 2. Pick a small budget

- List the functions your branch changed: `git diff main...HEAD` (or the branch's base).
- One mutation per changed function, of one of these kinds:
  - a condition (negate it, `&&` to `||`, drop a clause);
  - a boundary (`<` to `<=`, a limit off by one);
  - an error path (skip the error, return success, drop the message);
  - a fallback (remove the `|| default`, the guard or the early return).
- At most 5 mutations per branch. Pick the riskiest functions first.
- Skip test files, and skip mutations that don't change behaviour (e.g. reworded comments, renamed locals).
- This is not the full check: the queue's test review still does that.

## 3. Fast tests only

- Run only unit tests and the repo's shell tests, and only the ones that cover the mutated code (one test
  file, or a name filter).
- Never run e2e tests (Playwright, a browser, a database stack). Code that only e2e tests cover is reported
  as not checked, and left to the queue's review.

## 4. One test run at a time on the machine

Create the folder of `selfcheck.lock` first, because it may not exist yet: `mkdir -p ~/.local/state/pr-queue`

Run every test run like this, with a timeout in seconds that fits the tests (e.g. 300):

    flock ~/.local/state/pr-queue/selfcheck.lock ~/code/clauderaptor/scripts/capped.sh timeout <s> <test command>

This lock is only for self-checks, so it doesn't hold up the queue's e2e runs. Run the tests once without a
mutation first: they must pass, or the check means nothing.

## 5. One mutation at a time

Never run mutations in parallel: no `&`, no `xargs -P`, no parallel loops. For each mutation:

1. Edit one place in one file.
2. Run its tests as in step 4 and note the exit code.
3. Run `git restore <path>` on the file, before anything else.

Read the result:

- The tests fail (a test assertion failed): caught.
- The tests pass: not caught (see step 6).
- The run was stopped: not checked, never caught. Exit 137 or out of memory, a timeout (124), and `capped.sh` refusing to run (125) are all not checked.
  Say so in the report; don't retry in a loop.

## 6. A mutation no test catches

1. Restore the file (`git restore <path>`).
2. Add a test, or fix the one that should have caught it.
3. Make the same mutation again and run the tests: the new test must fail. If it doesn't, fix the test.
4. Restore the file again (`git restore <path>`), run the tests: they pass.
5. Commit the test.

## 7. Finish clean

`git status --porcelain` prints nothing, and no mutation is left in a file or a commit.

## 8. Report

Add this to your report:

- Tried: each mutation, as file, function and what changed.
- Caught: which mutations, and by which test.
- Tests added: the tests you added or fixed, for the mutations that weren't caught.
- Not checked: the mutations or functions you didn't check, and why (only e2e covers it, over the budget,
  or the run was stopped: not checked with 137 / out of memory / 124 / 125).
