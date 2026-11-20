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

Installs the GitHub CLI (`gh`) from its official apt repo, runs `gh auth login` (browser/device-code flow) if needed, and sets `gh` as git's credential helper for github.com. It's interactive (sudo password + login), so run it yourself in a terminal, or from Claude Code with `! ./setup-tools.sh`. Safe to re-run.

## Tests
    tests/run.sh

Tests for every script (`install.sh`, `check-repos.sh`, `setup-tools.sh`, `statusline.py`), plus shellcheck when it's installed. They run in temp dirs with stubbed `gh`/`sudo`/`apt`, so they're safe to run anytime. `./install.sh` enables a pre-commit hook (`.githooks/pre-commit`) that runs them and blocks the commit if any fail (`git commit --no-verify` skips it once).

## Workspace (not committed)
- `repos/` – clone the repos you work on here (`git clone <url> repos/<name>`). Each keeps its own git history and remote. Run `./check-repos.sh` to see each repo's status with push/pull suggestions (it asks what to clone if `repos/` is empty).
- `tasks/` – one folder per task (notes, scratch files, plans).

Both are gitignored; only the Claude config is tracked.
