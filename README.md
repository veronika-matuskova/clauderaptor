# clauderaptor

Shared Claude Code CLI config (global instructions, rules, skills, agents, slash commands, settings) used across all repos.

## Layout
- `claude/CLAUDE.md` – global instructions (imports `rules/*.md`)
- `claude/rules/` – rule files, imported from CLAUDE.md with `@rules/<file>.md`
- `claude/skills/<name>/SKILL.md` – skills
- `claude/agents/*.md` – subagents
- `claude/commands/*.md` – slash commands
- `claude/settings.json` – user settings

## Install
    ./install.sh

Symlinks everything into `~/.claude`, so edits here take effect immediately. Existing non-symlinked files are backed up as `*.bak.<timestamp>`.

Per-repo overrides still go in each repo's own `CLAUDE.md` / `.claude/`.

## Workspace (not committed)
- `repos/` – clone the repos you work on here (`git clone <url> repos/<name>`). Each keeps its own git history and remote.
- `tasks/` – one folder per task (notes, scratch files, plans).

Both are gitignored; only the Claude config is tracked.
