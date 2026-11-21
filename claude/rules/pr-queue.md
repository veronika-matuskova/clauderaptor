# Parallel agents and tests

- When agents work in parallel, merge their branches through `~/code/clauderaptor/scripts/pr-queue.sh`, one at a time. Agents
  commit and queue; they don't push, open PRs or merge on their own, so they can't mess up each other's branches.
- The queue reviews each branch before its e2e run: the built-in `/code-review` in a fresh `claude -p` session
  (`scripts/review.sh`). Queue migrations, auth or RLS changes with `pr-queue.sh add --review high`. A failed
  review goes back to the branch's agent, like a failed test; its findings are in the file the failure names.
  When a branch fails its second review, the main session reads the findings and decides instead: it sends the
  agent only what is worth fixing, or queues the branch with `--review none` to merge it without another review.
- Shared test infrastructure (a local database stack, a mail catcher, fixed ports) stays one shared instance.
  Use it only under `~/code/clauderaptor/scripts/pr-queue.sh lock`. Don't give each worktree its own copy (memory is limited: WSL has 8 GB).
- To make a slow suite faster, parallelize inside one run: several test workers, each with its own data
  (separate test accounts, unique record names, cleanup of only its own records or mail). Before raising the
  worker count, find what tests share: accounts, per-user rows, global cleanup. Measure the time before and after.
- Unit tests that need no shared state can run in parallel as they are (e.g. `node --test` runs one process per file).
