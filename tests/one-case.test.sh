#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export LC_ALL=C
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "one-case: FAIL $*" >&2; exit 1; }
only=${1:-}
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
ok() { echo "one-case $1: ok"; [ "$1" != "$only" ] || exit 0; }

fx=$root/tests/fixtures/one-case/suite.sh
export ONE_CASE_LOG=$tmp/log
run() { local s=0; : >"$ONE_CASE_LOG"; bash "$fx" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
seen() { echo "out: $(cat "$tmp/out") err: $(cat "$tmp/err") log: $(cat "$ONE_CASE_LOG")"; }

if want later-alone; then
  [ "$(run late)" = 0 ] || fail "a later case selected alone passes though an earlier case fails: $(seen)"
  [ "$(cat "$tmp/out")" = "forge late: ok" ] || fail "a later case selected alone prints only its own ok line: $(seen)"
  ! grep -q 'early ran' "$tmp/err" || fail "a later case selected alone does not run the earlier case: $(seen)"
  ok later-alone
fi

if want unknown-case; then
  [ "$(run no-such-case)" = 1 ] || fail "an unknown case exits 1: $(seen)"
  grep -q 'no case no-such-case' "$tmp/err" || fail "an unknown case fails no case <case> on stderr: $(seen)"
  [ ! -s "$tmp/out" ] || fail "an unknown case runs no case: $(seen)"
  ok unknown-case
fi

if want no-case; then
  [ "$(run)" = 1 ] || fail "the fixture with no argument fails: $(seen)"
  grep -q 'forge: FAIL early ran' "$tmp/err" || fail "the fixture with no argument fails at the earlier case: $(seen)"
  [ ! -s "$tmp/out" ] || fail "the fixture with no argument stops at the earlier case: $(seen)"
  ok no-case
fi

if want want-any; then
  [ "$(run)" = 1 ] && [ "$(cat "$ONE_CASE_LOG")" = "any all" ] || fail "a want_any block runs for no case: $(seen)"
  [ "$(run late)" = 0 ] && [ "$(cat "$ONE_CASE_LOG")" = "any late" ] || fail "a want_any block runs for its first named case: $(seen)"
  [ "$(run extra)" = 0 ] && [ "$(cat "$tmp/out")" = "forge extra: ok" ] && [ "$(cat "$ONE_CASE_LOG")" = "any extra" ] || fail "a want_any block runs for its second named case: $(seen)"
  [ "$(run early)" = 1 ] && grep -q 'forge: FAIL early ran' "$tmp/err" && [ ! -s "$ONE_CASE_LOG" ] || fail "a want_any block skips a case it does not name: $(seen)"
  ok want-any
fi

[ -z "$only" ] || fail "no case $only"
