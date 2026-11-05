#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
logs=$(mktemp -d)
if ! command -v claude >/dev/null; then
  mkdir "$logs/.bin"
  printf '#!/bin/sh\ncase $1 in agents) echo "[]" ;; esac\nexit 0\n' >"$logs/.bin/claude"
  chmod +x "$logs/.bin/claude"
  export PATH=$PATH:$logs/.bin FORGE_CLAUDE_STUB=1
fi
s=0
FORGE_TEST_LOG_DIR=$logs tests/forge.test.sh || s=$?
echo "--- skipped"
grep -rh '^SKIP' "$logs" | sort -u || true
if [ "$s" != 0 ]; then
  echo "--- failures"
  find "$logs" -name '*.log' -print0 | xargs -0 grep -aE ': FAIL ' | cut -c1-600
  grep -rLa ': FAIL ' "$logs" --include='*.log' | while read -r f; do
    tail -n 1 "$f" | grep -qaE ': ok$' || { echo "--- tail of $f"; tail -n 25 "$f" | cut -c1-300; }
  done
fi
exit "$s"
