#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/output-style-reinforce.sh

fail() { echo "output-style-reinforce: FAIL $*" >&2; exit 1; }
[ -z "${1:-}" ] || fail "no case $1"
tmp=$(mktemp -d -p /tmp)
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR=$tmp/claude
mkdir -p "$CLAUDE_CONFIG_DIR/output-styles"
printf '{"outputStyle": "google-dev-docs"}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
printf -- '---\nname: google-dev-docs\nreminder: "Keep it short and \\"plain\\"."\n---\nBody\n' >"$CLAUDE_CONFIG_DIR/output-styles/google-dev-docs.md"
unset FORGE_ROOT

input() { jq -n --arg p "$1" '{hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: "/home/u/Projects/acme", prompt: $p}'; }

out=$(input 'hello there' | "$hook") || fail "a plain prompt must exit 0"
[ "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" = UserPromptSubmit ] || fail "a plain prompt must name the event, got: $out"
[ "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" = 'Keep it short and "plain".' ] || fail "a plain prompt must get the reminder, got: $out"

out=$(input '<scheduled-task name="x">run</scheduled-task>' | "$hook") || fail "a scheduled task must exit 0"
[ -z "$out" ] || fail "a scheduled task must get no output, got: $out"

out=$(input '<task-notification><task-id>a1</task-id><status>completed</status></task-notification>' | "$hook") || fail "a task notification must exit 0"
[ -z "$out" ] || fail "a task-notification prompt must get no output, got: $out"

out=$(input 'hello there' | FORGE_ROOT=/home/u/Projects/acme "$hook") || fail "a forge session must exit 0"
[ -z "$out" ] || fail "a non-empty FORGE_ROOT must get no output, got: $out"

out=$(input 'hello there' | FORGE_ROOT= "$hook") || fail "an empty FORGE_ROOT must exit 0"
[ "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" = 'Keep it short and "plain".' ] || fail "an empty FORGE_ROOT must still get the reminder, got: $out"

echo "output-style-reinforce: ok"
