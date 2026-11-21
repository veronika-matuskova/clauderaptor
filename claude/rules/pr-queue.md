# Parallel agents and tests

- When agents work in parallel, merge their branches through clauderaptor's `pr-queue.sh`, one at a time. Agents
  commit and queue; they don't push, open PRs or merge on their own, so they can't mess up each other's branches.
- Shared test infrastructure (a local database stack, a mail catcher, fixed ports) stays one shared instance.
  Use it only under `pr-queue.sh lock`. Don't give each worktree its own copy (memory is limited: WSL has 8 GB).
- To make a slow suite faster, parallelize inside one run: several test workers, each with its own data
  (separate test accounts, unique record names, cleanup of only its own records or mail). Before raising the
  worker count, find what tests share: accounts, per-user rows, global cleanup. Measure the time before and after.
- Unit tests that need no shared state can run in parallel as they are (e.g. `node --test` runs one process per file).
