#!/usr/bin/env bash
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/forge-hook.sh
input='{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"true"},"hook_event_name":"PreToolUse","session_id":"s"}'
echo "bash on PATH: $(/bin/bash --version | head -1)"
s=0
out=$(PATH=/bin:/usr/bin FORGE_HOOK_BASHES='' FORGE_HOOK_BREW='' sh "$hook" forge-guard.sh <<<"$input" 2>&1) || s=$?
echo "no modern bash: exit $s: $out"
[ "$s" = 2 ] || { echo "the guard must fail closed with exit 2 without a modern bash"; exit 1; }
case $out in *"Bash 4 or newer"*) ;; *) echo "the guard must say why"; exit 1 ;; esac
s=0
out=$(PATH=/bin:/usr/bin:$(brew --prefix)/bin sh "$hook" forge-guard.sh <<<"$input" 2>&1) || s=$?
echo "modern bash found by the wrapper: exit $s: $out"
[ "$s" = 0 ] || { echo "the guard must run under the Homebrew bash with /bin first"; exit 1; }
if /bin/bash -c "$(sed -n '1,/declare -A/p' "$root/hooks/forge-guard.sh" | grep -m1 'declare -A')" 2>/dev/null; then
  echo "/bin/bash accepts declare -A; it is not 3.2"
fi
echo "hook-bash32: ok"
