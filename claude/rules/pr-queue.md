# Parallel agents and tests

- When agents work in parallel, merge their branches through `~/code/clauderaptor/scripts/pr-queue.sh`, one at a time per
  repo (each repo has its own queue; `pr-queue.sh run` works on all of them side by side). Agents
  commit and queue; they don't push, open PRs or merge on their own, so they can't mess up each other's branches.
- The queue reviews each branch before its e2e run, in two fresh `claude -p` sessions at the same time
  (`scripts/review.sh`): the code, with the built-in `/code-review`, and the tests (`review.sh --tests`: a mutation
  check, and missing, empty, duplicate or non-atomic tests). Queue migrations, auth or RLS changes with
  `pr-queue.sh add --review high`. A failed review goes back to the branch's agent, like a failed test; its
  findings are in the files the failure names. When a branch fails its second review, the main session reads the
  findings and decides instead: it sends the agent only what is worth fixing, or queues the branch with
  `--review none` or `--tests none` to merge it without another review of that kind.
- To audit a repo's whole test suite, run `~/code/clauderaptor/scripts/review.sh --suite <checkout>`. It saves
  every finding to a file and prints a summary with the file's path.
- Shared test infrastructure (a local database stack, a mail catcher, fixed ports) stays one shared instance.
  Use it only under `~/code/clauderaptor/scripts/pr-queue.sh lock`. Don't give each worktree its own copy (memory is limited: WSL has 8 GB).
- To make a slow suite faster, parallelize inside one run: several test workers, each with its own data
  (separate test accounts, unique record names, cleanup of only its own records or mail). Before raising the
  worker count, find what tests share: accounts, per-user rows, global cleanup. Measure the time before and after.
- Unit tests that need no shared state can run in parallel as they are (e.g. `node --test` runs one process per file).
