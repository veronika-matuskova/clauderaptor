# clauderaptor (this repo)

- Every committed script (`*.sh`, `claude/statusline.py`) must have tests in `tests/test_<name>.sh`. When adding or changing a script, add or update its tests in the same commit.
- Tests use the helpers in `tests/lib.sh`, run in a temp dir, and never touch the network, the real `~/.claude`, or need sudo. Stub external commands via `PATH`.
- Run `tests/run.sh` before committing and only commit when it passes. The pre-commit hook (`.githooks/pre-commit`, enabled by `./install.sh`) enforces this; don't bypass it with `--no-verify`.
