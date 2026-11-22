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
    scripts/setup.sh

`scripts/setup.sh` runs these steps in order and stops at the first failure (`scripts/setup.sh tools docker` runs only the named ones, `-h` shows help):
- `install` – `scripts/install.sh`: link `claude/` into `~/.claude` (existing files are backed up as `*.bak.<timestamp>`), build `settings.json`, enable the pre-commit hook
- `tools` – `scripts/setup-tools.sh`: `gh` + login, shellcheck, SSH commit signing (with a new passphrase-less, signing-only key `~/.ssh/id_ed25519_signing`)
- `docker` – `scripts/setup-docker.sh`: Docker Engine in WSL instead of Docker Desktop (Desktop's images and volumes don't carry over). After it, open a new terminal so the `docker` group applies.

It's interactive (sudo password, GitHub login), so run it yourself in a terminal as your user, not with `sudo`. Every step is safe to re-run.

## Use
- Config lives in `claude/`: `CLAUDE.md` (global instructions), `rules/*.md`, `skills/<name>/SKILL.md` (starter in `templates/skill/`), `agents/*.md`, `statusline.py`. It's symlinked, so edits apply immediately. Per-repo overrides go in each repo's own `CLAUDE.md` / `.claude/`.
- Settings: `claude/settings.json` (shared) + `claude/settings.local.json` (this machine, gitignored) are merged into `~/.claude/settings.json` (lists combine, as in Claude Code); re-run `scripts/install.sh` after editing either. The repo owns the keys it sets: changes Claude Code makes to them (`/effort`, `/config`) are backed up and reset on install, so copy the ones you want to keep into one of these. Keys the repo doesn't set (e.g. hooks another tool added) are kept, and the install lists them.
- Clone repos you work on into `repos/` and keep task notes in `tasks/` (both gitignored). `scripts/check-repos.sh` shows each repo's status, or offers to clone when `repos/` is empty.
- Parallel agents: an agent commits in its worktree and runs `~/code/clauderaptor/scripts/pr-queue.sh add [--review high] [--tests none] <worktree> <type> "<description>"`; the main session runs `scripts/pr-queue.sh run` to merge main, review the branch's code and tests (two fresh `claude -p` sessions at the same time, `scripts/review.sh`: the built-in `/code-review`, and a test review with a mutation check), test, open the PR, wait for CI and merge, one branch at a time. `status` shows the queue. Details are in the script header.
- Test suite audit: `scripts/review.sh --suite <checkout>` checks a repo's whole test suite (mutations, missing, empty, duplicate and non-atomic tests) and saves every finding to a file. The checks are in `scripts/review-tests.md`.
- Caps: `scripts/capped.sh <command...>` runs a command in a systemd user scope that caps its processes and memory (`CAP_TASKS`, default 2000; `CAP_MEMORY`, default 4G; no swap), so a runaway such as a fork bomb is stopped there instead of freezing WSL. Each call gets a cap of its own, also inside another capped command, and what it leaves running is stopped when it ends. All of them share `capped.slice`, which caps them together (`CAP_TOTAL_TASKS`, default 4000; `CAP_TOTAL_MEMORY`, default 5G), so capped commands that call `capped.sh` again, or run at the same time, stay inside it too. The review sessions, each test command they run, and every test file run under it; run mutation loops under it too. Without a systemd user instance (no `systemd-run` or `systemctl`, or no user manager's socket in `$XDG_RUNTIME_DIR`), the command runs uncapped, with a warning. If there is one but it can't apply the caps (3 tries, 1 s apart), the command doesn't run and `capped.sh` exits 125; `CAP_OFF=1` runs it without a cap, on purpose.

## Tests
    tests/run.sh

Runs before every commit via the pre-commit hook. Every script needs tests in `tests/test_<name>.sh`.
