# clauderaptor

Shared Claude Code CLI config (global instructions, rules, skills, agents, slash commands, settings) used across all repos.

## Layout
- `claude/CLAUDE.md` – global instructions (imports `rules/*.md`)
- `claude/rules/` – rule files, imported from CLAUDE.md with `@rules/<file>.md`
- `claude/skills/<name>/SKILL.md` – skills
- `claude/agents/*.md` – subagents
- `claude/commands/*.md` – slash commands
- `claude/settings.json` – user settings
- `claude/statusline.py` – status line script

## Install
    ./install.sh

Symlinks everything into `~/.claude`, so edits here take effect immediately. Existing non-symlinked files are backed up as `*.bak.<timestamp>`.

Per-repo overrides still go in each repo's own `CLAUDE.md` / `.claude/`.

## CLI tools
    ./setup-tools.sh

Installs the GitHub CLI (`gh`) from its official apt repo, runs `gh auth login` (browser/device-code flow) if needed, and sets `gh` as git's credential helper for github.com. It's interactive (sudo password + login), so run it yourself in a terminal, or from Claude Code with `! ./setup-tools.sh`. Safe to re-run.

## Workspace (not committed)
- `repos/` – clone the repos you work on here (`git clone <url> repos/<name>`). Each keeps its own git history and remote. Run `./check-repos.sh` to see each repo's status with push/pull suggestions (it asks what to clone if `repos/` is empty).
- `tasks/` – one folder per task (notes, scratch files, plans).

Both are gitignored; only the Claude config is tracked.
