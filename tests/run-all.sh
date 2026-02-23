#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

for test_file in "$TESTS_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  name="$(basename "$test_file" .sh)"
  if bash "$test_file"; then
    echo "  PASS  $name"
    ((PASS++))
  else
    echo "  FAIL  $name"
    ((FAIL++))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
