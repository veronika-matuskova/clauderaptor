#!/usr/bin/env bash
# Runs every tests/test_*.sh (plus shellcheck if installed). Exit code = number of failing files. A file passes
# if it exits 0 and its last line is lib.sh's finish() line with no failures.
cd "$(dirname "$0")/.." || exit 1
failed=0
log="$(mktemp)"; trap 'rm -f "$log"' EXIT
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  # Passed only if it got to finish() with no failures: a file that stopped early, or that a broken capped.sh
  # never ran, fails even with exit 0.
  if [ "$rc" -ne 0 ] || [ "$(tail -1 "$log")" != "  finished: 0 failed" ]; then failed=$((failed + 1)); fi
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  if shellcheck -x scripts/*.sh scripts/*/*.sh tests/*.sh .githooks/pre-commit; then echo "  ok   no warnings"; else failed=$((failed + 1)); fi
else
  echo "== shellcheck not installed, skipped (run scripts/setup/setup-tools.sh)"
fi
[ "$failed" -eq 0 ] && echo "ALL PASSED" || echo "$failed test file(s) failed"
exit "$failed"
