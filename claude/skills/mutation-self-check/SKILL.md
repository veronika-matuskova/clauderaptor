---
name: mutation-self-check
description: Run a mutation check of your own changed code, in this session, before `pr-queue.sh add`. Use it every time you are about to queue a branch.
---

Check that the tests of your change catch real bugs, before the queue's test review does. Do it yourself, in
this session, one step at a time. The machine is WSL with 8 GB and other agents run at the same time.

## 1. Start clean

Commit all your work first. Then check that `git status --porcelain` prints nothing. If it prints anything,
commit or stop: `git restore` below would also wipe uncommitted work.

## 2. List the places and pick the budget

- Read what your branch changed: `git diff main...HEAD` (or the branch's base).
- List every place in the changed non-test code that changes behaviour. Each of these is a place to mutate,
  and one function can have several:
  - a condition (negate it, `&&` to `||`, drop a clause);
  - a boundary (`<` to `<=`, a limit off by one);
  - an error path (skip the error, return success, drop the message);
  - a fallback (remove the `|| default`);
  - a guard (drop the check, so the code below it always runs);
  - an early return (remove it, so the code goes on).
- Budget: one mutation per place, at least 11 and at most 29 per branch. With fewer than 11 places, try every
  one of them. With more than 29, try the 29 riskiest; the rest go under "Not checked" as over the budget.
- Try them riskiest first.
- Time limit: 20 minutes of the self-check's own run time, from the start of this step to the end of step 7.
  Time spent waiting for `selfcheck.lock` doesn't count. Note the time (`date +%s`) when you start and check it
  before each mutation; to see a run's wait, put `--verbose` after `flock` in step 4's command, and it prints
  `getting lock took <n> seconds`. When the 20 minutes are up, finish the mutation you're on and stop: the
  mutations left go under "Not checked: over the time limit".
- Skip test files, and skip mutations that don't change behaviour (e.g. reworded comments, renamed locals).
- This is not the full check: the queue's test review still does that.

## 3. Fast tests only

- Run only unit tests and the repo's shell tests. Each run uses the smallest test set that covers the mutated
  code (one test file, or a name filter), so a run takes seconds: the machine is WSL with 8 GB, and while your
  runs hold `selfcheck.lock` (step 4), the other agents' self-checks wait.
- Never run e2e tests (Playwright, a browser, a database stack). Code that only e2e tests cover is reported
  as not checked, and left to the queue's review.

## 4. One test run at a time on the machine

Create the folder of `selfcheck.lock` first, because it may not exist yet: `mkdir -p ~/.local/state/pr-queue`

Run every test run like this, with a timeout in seconds that fits the tests (e.g. 300):

    flock ~/.local/state/pr-queue/selfcheck.lock ~/code/clauderaptor/scripts/capped.sh timeout <s> <test command>

300 is the upper example: use a smaller timeout for one fast test file.

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
2. Add a test, or fix the one that should have caught it. Run the tests: they pass. Commit the test now, before
   the next mutation: the test may live in the same file as the code (e.g. Rust `#[cfg(test)]`, doctests), and
   `git restore` would wipe it if it weren't committed.
3. Make the same mutation again and run the tests: the new test must fail. If it doesn't, restore the file
   (`git restore <path>`), fix the test, commit it, and try again.
4. Restore the file again (`git restore <path>`): it goes back to the commit with the test.

## 7. Finish clean

`git status --porcelain` prints nothing, and no mutation is left in a file or a commit.

## 8. Report

Add this to your report:

- Places: how many places step 2 found and how many you tried, e.g. `34 places, 29 tried`. When you tried
  every one (e.g. a change with fewer than 11), write `N places, all tried`, e.g. `7 places, all tried`.
- Tried: each mutation, as file, function and what changed.
- Caught: which mutations, and by which test.
- Tests added: the tests you added or fixed, for the mutations that weren't caught.
- Not checked: the mutations or functions you didn't check, and why (only e2e covers it, over the budget,
  over the time limit, or the run was stopped: not checked with 137 / out of memory / 124 / 125).
