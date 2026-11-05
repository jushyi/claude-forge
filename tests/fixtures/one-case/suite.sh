#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../forge-common.sh"

twice() { printf '%s%s' "$1" "$1"; }
shared=$(twice ab)

if want_any late extra; then
  echo "any ${only:-all}" >>"$ONE_CASE_LOG"
fi

if want early; then
  fail "early ran"
  ok early
fi

if want late; then
  [ "$shared" = abab ] && [ "$(twice cd)" = cdcd ] || fail "late sees the helper and shared setup"
  ok late
fi

if want extra; then
  ok extra
fi

finish
