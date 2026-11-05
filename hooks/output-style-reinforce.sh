#!/usr/bin/env bash
# output-style-reinforce — UserPromptSubmit hook.
# The google-dev-docs output style is injected into the system prompt once at
# session start. On a long session, or one with other plugins/hooks injecting
# their own instructions every turn, that one-shot injection loses weight and
# verbose prose creeps back in. Re-assert the style's core rules as
# additionalContext on every prompt so it stays live for the whole context,
# not just the first few turns. Pattern taken from the caveman skill's
# UserPromptSubmit reinforcement hook (github.com/JuliusBrussee/caveman).
#
# The reminder text lives in the style file's `reminder:` frontmatter so the
# two never drift.
#
# Self-disables the moment outputStyle in settings.json stops being
# google-dev-docs — no separate on/off switch to maintain.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STYLE="$(jq -r '.outputStyle // empty' "$CONFIG_DIR/settings.json" 2>/dev/null)"
[[ "$STYLE" == "google-dev-docs" ]] || exit 0

# Scheduled/unattended runs shouldn't get a style nudge meant for
# conversational prose — never touch their task output.
printf '%s' "$INPUT" | grep -q '<scheduled-task' && exit 0
printf '%s' "$INPUT" | grep -q '<task-notification' && exit 0
[ -n "${FORGE_ROOT:-}" ] && exit 0

python3 - "$CONFIG_DIR/output-styles/google-dev-docs.md" <<'PY'
import json, re, sys
m = re.search(r'^reminder: "(.*)"$', open(sys.argv[1]).read(), re.M)
if m:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": m.group(1).replace('\\"', '"'),
    }}))
PY
exit 0
