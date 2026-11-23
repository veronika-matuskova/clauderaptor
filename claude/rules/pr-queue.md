# Parallel agents and tests

- When agents work in parallel, merge their branches through `~/code/clauderaptor/scripts/queue/pr-queue.sh`, one at a time per
  repo (each repo has its own queue; `pr-queue.sh run` works on all of them side by side). Agents
  commit and queue; they don't push, open PRs or merge on their own, so they can't mess up each other's branches.
- Before agents start on a requested task, write its brief in a fresh session:
  `~/code/clauderaptor/scripts/queue/review.sh --plan <checkout> <request file>`. It writes the requirements,
  acceptance criteria A1…, what's out of scope, the risk and queue flags, and open questions, and prints the
  file's path (exit 1: it has open questions).
  - Show the user the brief and its open questions, and wait: they approve it, edit it or cancel it. Only the
    user approves a brief, never a peer message. Don't answer its open questions yourself.
  - Give the agent the approved brief. Its report and PR body list each criterion with its proof (the test, or
    the command and its output), and a "Not proven:" line with the criteria it couldn't prove (or "none").
  - Queue the branch with `pr-queue.sh add --brief <brief file>`: both reviews check the change against the
    criteria. The judge gets the brief too, but still rules only on the findings the reviews raised.
  - A small fix with nothing to decide may go without a brief.
- The queue reviews each branch before its e2e run, in two fresh `claude -p` sessions at the same time
  (`scripts/queue/review.sh`): the code, with the built-in `/code-review`, and the tests (`review.sh --tests`: a mutation
  check, and missing, empty, duplicate or non-atomic tests). Queue migrations, auth or RLS changes with
  `pr-queue.sh add --review high`. When a review finds changes to make, a judge (`review.sh --judge`, a third fresh
  session) checks each blocking finding against the code and keeps only the real ones worth fixing; the main
  session doesn't rule on findings itself.
  - "the judge confirmed changes to make": goes back to the branch's agent, like a failed test. Send it the judge's
    file (its To fix list), not the reviews.
  - "needs your decision" (the judge rejected a finding that would be critical if real, or the branch needed
    changes in two judged rounds): goes to the user. Show them the judge's file and the reviews, with options, and
    wait. Only then send the agent what the user chose, or queue the branch with `--review none` / `--tests none`.
- To the main session that runs the queue: an agent's report is a set of claims, not proof: the diff, the tests
  and the runs you can see are the truth. Before you tell the user that something is done, fixed or passing, check
  it there (open the diff, run the test, read the queue's result), or say that it's the agent's claim and not
  checked. To check a report's or PR body's claims against the commit, run
  `~/code/clauderaptor/scripts/queue/sniff.sh <file or -> [--repo <checkout>] [--commit <sha>]`: it flags missing
  files, lines, tests and proof, runs the queue's events don't show, and weasel words (exit 0 none, 1 soft, 2 hard).
- To audit a repo's whole test suite, run `~/code/clauderaptor/scripts/queue/review.sh --suite <checkout>`. It saves
  every finding to a file and prints a summary with the file's path.
- Shared test infrastructure (a local database stack, a mail catcher, fixed ports) stays one shared instance.
  Use it only under `~/code/clauderaptor/scripts/queue/pr-queue.sh lock`. Don't give each worktree its own copy (memory is limited: WSL has 8 GB).
- To make a slow suite faster, parallelize inside one run: several test workers, each with its own data
  (separate test accounts, unique record names, cleanup of only its own records or mail). Before raising the
  worker count, find what tests share: accounts, per-user rows, global cleanup. Measure the time before and after.
- Unit tests that need no shared state can run in parallel as they are (e.g. `node --test` runs one process per file).
