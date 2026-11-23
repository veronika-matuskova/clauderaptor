# Tests

Every test of a change covers:

- User-visible messages, hints and failure reasons, with an assert on the text (e.g. the "gh not found"
  hint, `failjob` reasons).
- Both sides of each boundary (e.g. the 12-hour expiry, the 5-minute window, `ago`'s unit boundaries).
- Options passed on arrive where they should (e.g. `--idle` / `--projects` to the server, `timeoutMs`).
- Fallbacks, guards and early returns are run (e.g. `nproc || echo 2`, `!saving`, a source guard).

Before `pr-queue.sh add`, run the `mutation-self-check` skill.
