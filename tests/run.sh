#!/usr/bin/env bash
# Runs every tests/test_*.sh (plus shellcheck if installed). Exit code = number of failing files.
cd "$(dirname "$0")/.." || exit 1
failed=0
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" || failed=$((failed + 1))
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  if shellcheck -x scripts/*.sh tests/*.sh .githooks/pre-commit; then echo "  ok   no warnings"; else failed=$((failed + 1)); fi
else
  echo "== shellcheck not installed, skipped (run scripts/setup-tools.sh)"
fi
[ "$failed" -eq 0 ] && echo "ALL PASSED" || echo "$failed test file(s) failed"
exit "$failed"
