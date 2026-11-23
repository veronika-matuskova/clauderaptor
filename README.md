<p align="center"><img src="docs/mascot.png" alt="clauderaptor mascot: a raptor in a safari hat and safety vest walking a pack of little raptors on leashes" width="520"></p>

# clauderaptor

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Shared Claude Code config (global instructions, rules, skills, agents, settings, status line) plus setup scripts for a WSL/Ubuntu machine.

## Setup
Prerequisites: systemd on in WSL (`[boot] systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`) and your git identity:

    git config --global user.name "<name>"
    git config --global user.email "<email on your GitHub account>"

Then:

    git clone <this repo> ~/code/clauderaptor && cd ~/code/clauderaptor
    scripts/setup/setup.sh

`scripts/setup/setup.sh` runs these steps in order and stops at the first failure (`scripts/setup/setup.sh tools docker` runs only the named ones, `-h` shows help):
- `install` – `scripts/setup/install.sh`: link `claude/` into `~/.claude` (existing files are backed up as `*.bak.<timestamp>`), build `settings.json`, enable the pre-commit hook
- `tools` – `scripts/setup/setup-tools.sh`: `gh` + login, shellcheck, SSH commit signing (with a new passphrase-less, signing-only key `~/.ssh/id_ed25519_signing`)
- `docker` – `scripts/setup/setup-docker.sh`: Docker Engine in WSL instead of Docker Desktop (Desktop's images and volumes don't carry over). After it, open a new terminal so the `docker` group applies.
- `caps` – `scripts/setup/setup-caps.sh`: delegate the cpu controller to systemd user managers, so `capped.sh`'s overall CPU cap applies (systemd 249 delegates only memory and pids). After it, run `wsl --shutdown` in PowerShell and open a new terminal.

It's interactive (sudo password, GitHub login), so run it yourself in a terminal as your user, not with `sudo`. Every step is safe to re-run.

Then `scripts/setup/check.sh` checks that everything is in place: the system (Ubuntu, WSL, systemd, a systemd user instance for `capped.sh`, and the cpu controller for its CPU cap, warn only), git (identity, SSH commit signing, the pre-commit hook), the tools, the `~/.claude` links, and the machine's resources. It only looks, without sudo, and prints `ok`, `warn` or `FAIL` with what to run for each check. Resources only warn: under 7 GiB of memory, when `capped.sh`'s overall cap leaves under 2 GiB for the rest, under 4 CPUs, or under 20 GiB free in `$HOME` or on the Windows drive. Its exit code is the number of FAILs.

## Use
- Config lives in `claude/`: `CLAUDE.md` (global instructions), `rules/*.md`, `skills/<name>/SKILL.md` (starter in `templates/skill/`), `agents/*.md`, `statusline.py`. It's symlinked, so edits apply immediately. Per-repo overrides go in each repo's own `CLAUDE.md` / `.claude/`.
- Settings: `claude/settings.json` (shared) + `claude/settings.local.json` (this machine, gitignored) are merged into `~/.claude/settings.json` (lists combine, as in Claude Code); re-run `scripts/setup/install.sh` after editing either. The repo owns the keys it sets: changes Claude Code makes to them (`/effort`, `/config`) are backed up and reset on install, so copy the ones you want to keep into one of these. Keys the repo doesn't set (e.g. hooks another tool added) are kept, and the install lists them.
- Clone repos you work on into `repos/` and keep task notes in `tasks/` (both gitignored). `scripts/setup/check-repos.sh` shows each repo's status, or offers to clone when `repos/` is empty.
- Parallel agents: an agent commits in its worktree and runs `~/code/clauderaptor/scripts/queue/pr-queue.sh add [--review high] [--tests none] [--brief <file>] <worktree> <type> "<description>"`; the main session runs `scripts/queue/pr-queue.sh run` to merge main, review the branch's code and tests (two fresh `claude -p` sessions at the same time, `scripts/queue/review.sh`: the built-in `/code-review`, and a test review with a mutation check; when either needs changes, a judge in a third fresh session keeps only the findings that are real and worth fixing, and sends a finding it rejects that would be critical if real, or a second judged round, to you), test, open the PR, wait for CI and merge, one branch at a time. Each repo has its own queue: `run` starts a runner for every repo with jobs, side by side, and one for each repo that gets jobs while it works (`run <checkout>` runs one repo's), and only the e2e runs take turns. `status` shows every queue. Details are in the script header.
- Planner: `scripts/queue/review.sh --plan <checkout> <request file>` writes a brief for a requested task, before an agent starts on it, in a fresh `claude -p` session: the requirements, acceptance criteria A1…, what's out of scope, the risk and its queue flags, and open questions for you. The instructions are in `scripts/queue/plan.md`, and briefs are saved in `~/.local/state/pr-queue/briefs/`. Once you approve it, the agent gets it, and `pr-queue.sh add --brief <file>` gives it to both reviews, which check the change against its criteria, and to the judge, to rule on the findings that name one.
- Sniffer: `scripts/queue/sniff.sh <file or -> [--repo <checkout>] [--commit <rev>]` checks the claims in a text (a PR body, an agent's report, a review, a brief) against a repo at a commit (default: the current checkout's HEAD), mechanically, with no session: file references and `file:line`s that aren't in the commit's tree, `name()`s and `test_<word>`s that `git grep` doesn't find there, criteria (`A<n>:`) whose proof isn't found or a `Not proven: none` with an unproven criterion, e2e and "tests pass" claims that the queue's events show failed (or have no record of), and weasel words in a claim that something is done. Absolute, `~/` and `$VAR` paths, URLs, placeholders and globs, and files said to be new or in another repo are left alone. It prints one line per flag and `Flags: <h> hard, <s> soft`, and exits 0 for no flags, 1 for soft flags only, 2 for a hard flag, and 4 when it couldn't run. Details are in the script header.
- Test suite audit: `scripts/queue/review.sh --suite <checkout>` checks a repo's whole test suite (mutations, missing, empty, duplicate and non-atomic tests) and saves every finding to a file. The checks are in `scripts/queue/review-tests.md`. The model and effort of each kind of review (code, tests, audit, judge, plan) are set in `scripts/queue/review.conf`.
- Caps: `scripts/capped.sh <command...>` runs a command in a systemd user scope that caps its processes and memory (`CAP_TASKS`, default 2000; `CAP_MEMORY`, default 4G; no swap), so a runaway such as a fork bomb is stopped there instead of freezing WSL. Each call gets a cap of its own, also inside another capped command, and what it leaves running is stopped when it ends. All of them share `capped.slice`, which caps them together (`CAP_TOTAL_TASKS`, default 4000; `CAP_TOTAL_MEMORY`, default 5G; `CAP_TOTAL_CPU`, default 60% of all the CPUs (`nproc --all`), e.g. `480%` with 8, so they leave CPUs for e2e runs and your sessions; it applies once `setup.sh caps` has delegated the cpu controller), so capped commands that call `capped.sh` again, or run at the same time, stay inside it too. The review sessions, each test command they run, and every test file run under it; run mutation loops under it too. Without a systemd user instance (no `systemd-run` or `systemctl`, or no user manager's socket in `$XDG_RUNTIME_DIR`), the command runs uncapped, with a warning. If there is one but it can't apply the caps (3 tries, 1 s apart), the command doesn't run and `capped.sh` exits 125; `CAP_OFF=1` runs it without a cap, on purpose.

## Apps
Optional apps that live in `apps/`, each with its own install (`clauderaptor`'s setup doesn't install them):
- [stats](apps/stats/README.md): how effective the PR queue is (rounds to merge, review cost and precision, tokens), as a local report in its own Edge window. `apps/stats/install.sh` adds the `raptor-stats` command.

## Tests
    tests/run.sh

Runs before every commit via the pre-commit hook. Every script needs tests in `tests/test_<name>.sh`.
