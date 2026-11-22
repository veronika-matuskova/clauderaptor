# General rules

- Keep changes minimal and focused on the request.
- Never commit secrets (.env, credentials).
- Run mutation loops, and anything else that may start processes or use memory without end, under
  `~/code/clauderaptor/scripts/capped.sh <command...>`: it caps their processes and memory, so a runaway is
  stopped there instead of freezing WSL (8 GB). Without the cap, a fork-bombing mutant once forced a restart.
