#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/forge-phase-stop.sh
export LC_ALL=C
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "forge-phase-stop: FAIL $*" >&2; exit 1; }
only=${1:-}
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
ok() { echo "forge-phase-stop $1: ok"; [ "$1" != "$only" ] || exit 0; }
block='{"decision":"block","reason":"forge-phase: ask with AskUserQuestion, never in plain text"}'
runj() { local s=0; "$hook" <<<"$1" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
msg() { jq -nc --arg m "$1" '{session_id: "s", transcript_path: "/nonexistent", cwd: "/tmp", permission_mode: "default", hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: $m}'; }
blocks() { [ "$(runj "$1")" = 0 ] || fail "$2: must exit 0: $(cat "$tmp/out" "$tmp/err")"; [ "$(jq -c . "$tmp/out")" = "$block" ] || fail "$2: must print the block decision: $(cat "$tmp/out" "$tmp/err")"; }
allows() { [ "$(runj "$1")" = 0 ] || fail "$2: must exit 0: $(cat "$tmp/out" "$tmp/err")"; [ ! -s "$tmp/out" ] || fail "$2: must print nothing on stdout: $(cat "$tmp/out")"; }

[ -x "$hook" ] || fail "hooks/forge-phase-stop.sh must exist and be executable"
grep -q '^set -euo pipefail$' "$hook" || fail "hook must set -euo pipefail"

if want block; then
blocks "$(msg $'I ran the tests.\nShould I proceed?')" "a trailing question line"
grep -qxF "$block" "$tmp/out" || fail "block JSON must match the exact reason: $(cat "$tmp/out")"
blocks "$(msg $'Should I proceed?   \t')" "a question with trailing whitespace"
blocks "$(msg $'Which option?\nI will wait for your answer.')" "a question line followed by more text"
blocks "$(msg $'```\nx = a ? b : c\n```\nShould I proceed?')" "a question after a closed fence"
blocks "$(msg $'````md\n```\n````\nShould I proceed?')" "a question after a longer fence holding a shorter one"
blocks "$(msg 'Is `a` the right one?')" "a question ending outside an inline code span"
ok block
fi

if want allow; then
allows "$(msg $'Should I proceed?\nresult: done')" "a result: line"
allows "$(msg $'result: blocked on X\nShould I proceed?')" "a result: line before the question"
allows "$(msg $'Here is the code:\n```\nwhat?\n```\nDone.')" "a ? only inside a fence"
allows "$(msg $'Here is the code:\n```bash\necho what?\n```')" "a ? only inside a tagged fence"
allows "$(msg $'````md\n```\nwhat?\n````\nDone.')" "a ? only inside a longer fence after a shorter fence line"
allows "$(msg 'Run `echo what?` next.')" "a ? only inside an inline code span"
allows "$(msg 'Ran `jq .a?`')" "an inline code span ending the line with a ?"
allows "$(msg 'Why? Because the spec says so.')" "a question mark mid-line"
allows "$(msg 'All tasks done.')" "a message without a question"
ok allow
fi

if want guard; then
allows "$(jq -nc '{hook_event_name: "Stop", stop_hook_active: true, last_assistant_message: "Should I proceed?"}')" "stop_hook_active true"
allows "$(jq -nc '{hook_event_name: "Stop", stop_hook_active: false}')" "a missing last_assistant_message"
allows "$(jq -nc '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: ""}')" "an empty last_assistant_message"
allows "$(jq -nc '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: null}')" "a null last_assistant_message"
ok guard
fi

if want error; then
allows 'not json' "unparseable input"
[ -s "$tmp/err" ] || fail "unparseable input must print the error on stderr"
ok error
fi

[ -z "$only" ] || fail "no case $only"
