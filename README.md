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
- Settings: `claude/settings.json` (shared) + `claude/settings.local.json` (this machine, gitignored) are merged into `~/.claude/settings.json`; re-run `scripts/install.sh` after editing either. Changes Claude Code makes itself (`/effort`, `/config`) land only in the generated file, so copy the ones you want to keep into one of these.
- Clone repos you work on into `repos/` and keep task notes in `tasks/` (both gitignored). `scripts/check-repos.sh` shows each repo's status, or offers to clone when `repos/` is empty.
- Parallel agents: an agent commits in its worktree and runs `~/code/clauderaptor/scripts/pr-queue.sh add <worktree> <type> "<description>"`; the main session runs `scripts/pr-queue.sh run` to merge main, test, open the PR, wait for CI and merge, one branch at a time. `status` shows the queue. Details are in the script header. (`pr-queue.sh` in the repo root is a temporary link to the old path; delete it once no running agent uses that path.)

## Tests
    tests/run.sh

Runs before every commit via the pre-commit hook. Every script needs tests in `tests/test_<name>.sh`.
