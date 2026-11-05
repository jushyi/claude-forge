#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
logs=$(mktemp -d)
s=0
FORGE_TEST_LOG_DIR=$logs tests/forge.test.sh || s=$?
echo "--- skipped"
grep -rh '^SKIP' "$logs" | sort -u || true
if [ "$s" != 0 ]; then
  echo "--- failures"
  find "$logs" -name '*.log' -print0 | xargs -0 grep -aE ': FAIL ' | cut -c1-600
fi
exit "$s"
