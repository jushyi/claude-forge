#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "forge-hook: FAIL $*" >&2; exit 1; }
[ -z "${1:-}" ] || fail "no case $1"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/hooks" "$tmp/old" "$tmp/new"
cp "$root/hooks/forge-hook.sh" "$tmp/hooks/"
printf 'echo guard ran: "$@"\nexit 7\n' >"$tmp/hooks/forge-guard.sh"
printf 'echo title ran\n' >"$tmp/hooks/forge-session-title.sh"
printf '#!/bin/sh\necho 3\n' >"$tmp/old/bash"
real=$(command -v bash)
printf '#!/bin/sh\nif [ "$1" = -c ]; then echo 5; exit 0; fi\nexec %s "$@"\n' "$real" >"$tmp/new/bash"
chmod +x "$tmp/old/bash" "$tmp/new/bash"
sys=$(dirname "$(command -v dirname)")
run() { local s=0 p=$1; shift; PATH=$p:$sys FORGE_HOOK_BASHES=${HB-} sh "$tmp/hooks/forge-hook.sh" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo "$s"; }
HB=
[ "$(run "$tmp/new" forge-guard.sh a b)" = 7 ] || fail "a modern bash on PATH runs the guard and keeps its exit: $(cat "$tmp/err")"
grep -qx 'guard ran: a b' "$tmp/out" || fail "the guard gets its arguments: $(cat "$tmp/out")"
[ "$(run "$tmp/old" forge-guard.sh)" = 2 ] || fail "with only Bash 3 the guard fails closed"
grep -q 'needs Bash 4' "$tmp/err" || fail "the closed guard names the fix: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "the guard must not run under Bash 3: $(cat "$tmp/out")"
[ "$(run "$tmp/old" forge-session-title.sh)" = 0 ] || fail "with only Bash 3 another hook exits 0"
grep -q 'needs Bash 4' "$tmp/err" || fail "the skipped hook says why: $(cat "$tmp/err")"
HB=$tmp/new/bash
[ "$(run "$tmp/old" forge-session-title.sh)" = 0 ] || fail "a modern bash outside PATH is found"
grep -qx 'title ran' "$tmp/out" || fail "a Homebrew-style bash runs the hook: $(cat "$tmp/out")"
echo "forge-hook: ok"
