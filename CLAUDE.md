# clauderaptor (this repo)

- Every committed script (`scripts/**/*.sh`, `claude/statusline.py`) must have tests in `tests/test_<name>.sh`. When adding or changing a script, add or update its tests in the same commit.
- Tests use the helpers in `tests/lib.sh`, run in a temp dir, and never touch the network, the real `~/.claude`, or need sudo. Stub external commands via `PATH`. The exception is the user's systemd: `tests/lib.sh` runs each test file under `scripts/capped.sh`, in a short-lived user scope (no sudo), so that a runaway in a test is stopped there, and `tests/test_capped.sh` checks the real caps.
- Run `tests/run.sh` before committing and only commit when it passes. The pre-commit hook (`.githooks/pre-commit`, enabled by `scripts/setup/install.sh`) enforces this; don't bypass it with `--no-verify`.
