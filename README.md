# clauderaptor

Shared Claude Code CLI config (global instructions, rules, skills, agents, slash commands, settings) used across all repos.

## Layout
- `claude/CLAUDE.md` – global instructions
- `claude/rules/*.md` – rule files, loaded automatically (scope one to files with `paths:` frontmatter)
- `claude/skills/<name>/SKILL.md` – skills (also used as slash commands); `templates/skill/` is a starter to copy
- `claude/agents/*.md` – subagents
- `claude/settings.json` – shared user settings (committed)
- `claude/settings.local.json` – this machine's settings, merged over the shared ones (gitignored)
- `claude/statusline.py` – status line script

## Install
    ./install.sh

Symlinks everything into `~/.claude`, so edits here take effect immediately. Existing non-symlinked files are backed up as `*.bak.<timestamp>`.

`~/.claude/settings.json` is the exception: it's generated from `settings.json` + `settings.local.json`, so re-run `./install.sh` after editing either. Changes Claude Code makes itself (`/effort`, `/config`) land only in the generated file; copy the ones you want to keep into one of the two files here. Skills synced from claude.ai (`claude/skills/synced/`) are gitignored.

Per-repo overrides still go in each repo's own `CLAUDE.md` / `.claude/`.

## CLI tools
    ./setup-tools.sh

Installs the GitHub CLI (`gh`) from its official apt repo, runs `gh auth login` (browser/device-code flow) if needed, and sets `gh` as git's credential helper for github.com. It also sets up commit/tag signing: creates a passphrase-less signing-only key `~/.ssh/id_ed25519_signing`, adds the `admin:ssh_signing_key` scope to gh (`gh auth refresh`) and uploads the key as a GitHub signing key, then sets `gpg.format=ssh`, `commit.gpgsign`, `tag.gpgsign` and `~/.config/git/allowed_signers` in your global git config. It's interactive (sudo password + login), so run it yourself in a terminal, or from Claude Code with `! ./setup-tools.sh`. Safe to re-run.

## Docker
    ./setup-docker.sh

Installs Docker Engine inside WSL from Docker's official apt repo (no Docker Desktop), adds you to the `docker` group and enables `docker.socket`, so systemd starts the daemon on the first `docker` command. Agents never need to start it, and nothing needs sudo after setup. It needs systemd (`[boot] systemd=true` in `/etc/wsl.conf`). If Docker Desktop's WSL integration is on, the script stops and says how to turn it off (Settings > Resources > WSL integration, quit Desktop, `wsl --shutdown`). It also removes the `"credsStore": "desktop.exe"` that Desktop leaves in `~/.docker/config.json`, which would break every pull. Images and volumes from Docker Desktop don't carry over. Run it yourself (sudo password), or with `! ./setup-docker.sh`. Safe to re-run.

## PR queue (parallel agents)
    ./pr-queue.sh add <worktree> <type> "<description>" [body-file]
    ./pr-queue.sh run | status | lock <command...>

Lets several agents build PRs in parallel without testing against a `main` that moves under them. An agent commits in its own worktree and queues the branch with `add`; it doesn't push. `run` takes one branch at a time:
1. merges `origin/main` in (a conflict fails the job);
2. runs `npm run test:e2e:full` if the repo has `scripts/e2e-gate.mjs` and the commit has no local pass;
3. opens the PR with the repo's `scripts/create-pr.sh` (or `gh pr create`), or pushes to the open one. The body is the body file (or the PR's current body) with a "Local end-to-end run" line for the commit being pushed, set before the push so CI sees it;
4. waits until the PR shows that commit as its head, then for its checks (a failed or cancelled check fails the job);
5. squash-merges exactly that commit, removes the worktree, the branch and the remote branch, and pulls the main checkout if it's a clean `main`. If the branch got new commits while the job ran, the worktree and branch are kept.

`main` only moves when the queue merges, so each branch is tested once, on the commit that gets merged. A failed job goes to `failed/`, with the reason in `status`; fix the branch and `add` it again. `lock` runs a command holding the same e2e lock, for an agent's targeted test run while the queue may be using the local stack. `PR_QUEUE_MERGE=0` stops before the merge. State is in `$PR_QUEUE_DIR` (default `${XDG_STATE_HOME:-~/.local/state}/pr-queue`).

## Tests
    tests/run.sh

Tests for every script (`install.sh`, `check-repos.sh`, `setup-tools.sh`, `setup-docker.sh`, `pr-queue.sh`, `statusline.py`), plus shellcheck when it's installed. They run in temp dirs with stubbed `gh`/`docker`/`sudo`/`apt`/`npm`, so they're safe to run anytime. `./install.sh` enables a pre-commit hook (`.githooks/pre-commit`) that runs them and blocks the commit if any fail (`git commit --no-verify` skips it once).

## Workspace (not committed)
- `repos/` – clone the repos you work on here (`git clone <url> repos/<name>`). Each keeps its own git history and remote. Run `./check-repos.sh` to see each repo's status with push/pull suggestions (it asks what to clone if `repos/` is empty).
- `tasks/` – one folder per task (notes, scratch files, plans).

Both are gitignored; only the Claude config is tracked.
