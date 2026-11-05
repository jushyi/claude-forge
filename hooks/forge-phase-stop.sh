#!/usr/bin/env bash
set -euo pipefail
msg=$(jq -r 'if .stop_hook_active == true then "" else .last_assistant_message // "" end') || exit 0
[ -n "$msg" ] || exit 0
if printf '%s\n' "$msg" | awk '
  /^result:/ { r = 1 }
  /^[ \t]*```/ {
    s = $0; sub(/^[ \t]*/, "", s); n = match(s, /[^`]/) ? RSTART - 1 : length(s)
    if (!f) f = n; else if (n >= f && substr(s, n + 1) ~ /^[ \t\r]*$/) f = 0
    next
  }
  f { next }
  { l = $0; gsub(/`[^`]*`/, "", l); sub(/[ \t\r]+$/, "", l); if (l ~ /\?$/) q = 1 }
  END { exit !(q && !r) }'; then
  echo '{"decision":"block","reason":"forge-phase: ask with AskUserQuestion, never in plain text"}'
fi
