#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'launchctl bootout "gui/$(id -u)/com.github.claude-forge.watchdog" 2>/dev/null || true; rm -rf "$tmp"' EXIT
jsonschema=$(dirname "$(command -v check-jsonschema)")
mkdir -p "$tmp/stub" "$tmp/home/.claude" "$tmp/proj"
printf '#!/bin/sh\ncase $1 in agents) echo "[]" ;; esac\nexit 0\n' >"$tmp/stub/claude"
chmod +x "$tmp/stub/claude"
printf '# mine\n' >"$tmp/home/.claude/CLAUDE.md"
printf '# project\n' >"$tmp/proj/CLAUDE.md"
echo '{"model":"sonnet","env":{"MY_VAR":"1"}}' >"$tmp/home/.claude/settings.json"
cp "$tmp/home/.claude/settings.json" "$tmp/settings"
git clone -q "$root" "$tmp/src"
git -C "$tmp/src" checkout -q -B main
export HOME=$tmp/home PATH=$tmp/stub:$jsonschema:/usr/bin:/bin
git config --global user.name ci
git config --global user.email ci@example.com
cd "$tmp/src"
./port --apply | tail -4
plist=$HOME/Library/LaunchAgents/com.github.claude-forge.watchdog.plist
[ -f "$plist" ] && ! grep -q __HOME__ "$plist" || { echo "the launchd agent must be installed with the real home"; exit 1; }
[ ! -e "$HOME/.config/systemd/user/forge-watchdog.timer" ] || { echo "macOS must not get systemd units"; exit 1; }
jq -e '.model == "sonnet" and .env.MY_VAR == "1" and (.hooks.PreToolUse | length) == 1' "$HOME/.claude/settings.json" >/dev/null
forge=$HOME/.local/bin/forge
"$forge" limits
"$forge" doctor
input='{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"true"},"hook_event_name":"PreToolUse","session_id":"s"}'
PATH=/usr/bin:/bin sh "$HOME/.claude/hooks/forge-hook.sh" forge-guard.sh <<<"$input"
"$forge" bg forge-mac-check -- /bin/sh -c "touch '$tmp/bg-ran'"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$tmp/bg-ran" ] && break; sleep 1; done
[ -e "$tmp/bg-ran" ] || { echo "forge bg must start a real launchd job"; exit 1; }
"$forge" bg --stop forge-mac-check
"$forge" notify "forge CI" "macOS notification check" || echo "osascript notification failed on this runner"
cd "$tmp/proj"
git init -q -b main
PATH=$HOME/.local/bin:$PATH forge-init proj "A project."
mkdir -p "$tmp/bg"
"$forge" limits | grep -q '^load=[0-9]' || { echo "forge limits must read the load"; exit 1; }
[ -f .claude/rules/forge.md ] || { echo "forge-init must write .claude/rules/forge.md"; exit 1; }
[ "$(cat CLAUDE.md)" = '# project' ] && [ "$(cat "$HOME/.claude/CLAUDE.md")" = '# mine' ] || { echo "CLAUDE.md files must not change"; exit 1; }
cd "$tmp/src"
./port --uninstall
cmp "$tmp/settings" "$HOME/.claude/settings.json"
[ ! -e "$plist" ] && [ ! -e "$forge" ] || { echo "uninstall must remove forge"; exit 1; }
echo "mac-install: ok"
