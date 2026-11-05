#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
vars=$(jq -r '@sh "cwd=\(.cwd // "") sid=\(.session_id // "") skip=\((.prompt // "" | test("^\\s*<[A-Za-z][A-Za-z0-9_-]*(\\s[^>]*)?/?>") or test("^forge watchdog: ")) or (.session_title // "" | test("^[^ ]+ (P[0-9]+(R[0-9]+)?|verify|ship) [^ /]+/[^ /]+$")))"' <<<"$input")
eval "$vars"
[ "$skip" = false ] || exit 0

base=${cwd%%/.claude/worktrees/*}
while [[ $base == */ ]]; do base=${base%/}; done
[ -n "$base" ] || exit 0
dir=$base
while [ -n "$dir" ] && [ ! -e "$dir/.forge/PROJECT.md" ]; do
  case $dir in */.git) dir= ;; */*) dir=${dir%/*} ;; *) dir= ;; esac
done
project=${dir:-$base}
project=${project##*/}

first=false
if [ -n "$sid" ]; then
  marks=${XDG_STATE_HOME:-$HOME/.local/state}/forge-session-title
  if mkdir -p -m 700 "$marks" 2>/dev/null && (set -C; : >"$marks/${sid//[^A-Za-z0-9_-]/_}") 2>/dev/null; then
    first=true
  fi
fi

jq -c --arg p "$project" --argjson first "$first" '
  def cut: if length > 40 then .[0:41] | sub("\\s+\\S*$"; "") | .[0:40] else . end;
  def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  def tail: if length > 0 then " \(cut)" else "" end;
  (.prompt // "")
  | if test("^/forge-(phase|verify|ship)(\\s|$)") then empty
    elif test("^/forge-discuss(\\s|$)") then
      "\($p) discuss" + ((sub("^/forge-discuss\\s+--auto(?=\\s|$)"; "/forge-discuss") | capture("^/forge-discuss\\s+(?<f>\\S+)") | " \(.f)") // "")
    elif test("^/forge-(quick|fast|new|debug|port)(\\s|$)") then
      capture("^/forge-(?<s>[a-z]+)(?<a>[\\s\\S]*)")
      | .s as $s
      | .a
      | if $s == "quick" then sub("^(\\s*--(discuss|research|verify)(?=\\s|$))+"; "") else . end
      | if $s == "debug" then sub("^\\s*--diagnose-only(?=\\s|$)"; "") else . end
      | norm
      | "\($p) \($s)\(tail)"
    elif $first then norm | cut | select(length > 0 and (test("^(P[0-9]+(R[0-9]+)?|verify|ship) [^ /]+/[^ /]+$") | not)) | "\($p) \(.)"
    else empty end
  | {hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: .}}' <<<"$input"
