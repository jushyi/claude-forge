#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LC_ALL=C

only=${1:-}
fail() { echo "mods: FAIL $*" >&2; exit 1; }
ok() { echo "mods $1: ok"; [ "$only" != "$1" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

mods=()
for d in "$root"/mods/*/; do
  mods+=("$(basename "$d")")
done
[ ${#mods[@]} -gt 0 ] || fail "no mods under mods/"

if want settings; then
  dirs=$(printf '~/.claude/forge/mods/%s\n' "${mods[@]}" | paste -sd :)
  got=$(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$root/global/settings.json")
  [ "$got" = "$dirs" ] || fail "global/settings.json env.CLAUDE_CODE_PLUGIN_DIRS must list every mod: want $dirs, got ${got:-nothing}"
  grep -qF '"mods/:$HOME/.claude/forge/mods/"' "$root/port" || fail "port must map mods/ to ~/.claude/forge/mods/"
  ok settings
fi

for m in "${mods[@]}"; do
  if want "$m"; then
    dir=$root/mods/$m
    [ "$(jq -r .name "$dir/.claude-plugin/plugin.json")" = "$m" ] || fail "$m: plugin.json name must be the folder name"
    if [ -n "${FORGE_CLAUDE_STUB:-}" ] || ! command -v claude >/dev/null; then
      echo "SKIP mods $m: claude is not installed; claude plugin validate and test need it"
      ok "$m"
      continue
    fi
    claude plugin validate "$dir" >"$tmp/validate" 2>&1 || fail "$m: claude plugin validate failed: $(cat "$tmp/validate")"
    (cd "$dir" && claude plugin test .) >"$tmp/test" 2>&1 || fail "$m: claude plugin test failed: $(cat "$tmp/test")"
    ok "$m"
  fi
done

[ -z "$only" ] || fail "no case $only"
