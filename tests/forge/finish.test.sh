#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

fresh
S=$XDG_STATE_HOME/forge/p
stub_run_claude
echo '[]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
mkdir -p "$S/features/crm-export"
echo '{"requirements": [{"id": "EXP-01", "text": "Export leads", "done": false}]}' >"$S/features/crm-export/requirements.json"
echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": ["EXP-01"], "depends": []}]}' >"$S/features/crm-export/split.json"
"$forge" alloc crm/export >/dev/null
git init -q -b main
git config user.name forge && git config user.email forge@example.com
printf -- '- All tests: `echo all >>%s`\n- Changed tests: `echo changed >>%s {files}`\n- Test: `echo one >>%s {test}`\n' "$tmp/runs" "$tmp/runs" "$tmp/runs" >.forge/TESTING.md
git add -A && git commit -q -m init
"$forge" implement crm/export >/dev/null 2>&1 || fail "implement crm/export"
d5=$S/phases/05-export-core w=.claude/worktrees/crm-export-05 fw=.claude/worktrees/crm-export
[ -d $w ] && [ -d $fw ] || fail "implement makes the feature and phase worktrees"

fin() { local s=0; "$forge" finish "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
outs() { echo "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"; }
wcommit() { echo "$2" >"$w/$1" && git -C $w add "$1" && git -C $w commit -q -m "$1"; }
result() { jq -n --arg s "$1" '{status: $s, summary: "core"}' >$d5/result.json; }
subject() { git log -1 --format=%s; }
recorded() { grep -qxF "forge: recorded 05 result" "$tmp/out"; }
planned() {
  jq -n '{tasks: [{id: "T1", title: "x", requirements: ["EXP-01"], files: ["a.txt"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"}]}' >$d5/plan.json
  mkdir -p $d5/tasks && jq -n '{id: "T1", status: "done"}' >$d5/tasks/T1.json
  "$forge" check 05 >"$tmp/c" 2>&1 || fail "check 05: $(cat "$tmp/c")"
}

if want finish-no-result; then
head=$(git rev-parse HEAD)
[ "$(fin 05)" = 1 ] || fail "no result.json exits 1: $(outs)"
grep -qF "no $d5/result.json; nothing committed" "$tmp/err" || fail "no result.json names the state dir phase dir: $(outs)"
! grep -qF "$PWD/.forge/" "$tmp/err" || fail "no result.json names no in-repo phase dir: $(outs)"
! recorded || fail "no result.json records nothing: $(outs)"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "no result.json commits nothing: $(subject)"
ok finish-no-result
fi

if want finish-blocked; then
head=$(git rev-parse HEAD)
result blocked
[ "$(fin 05)" = 0 ] || fail "a blocked result skips the test check and finishes: $(outs)"
recorded || fail "a blocked result is recorded: $(outs)"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a recorded result commits nothing: $(subject)"
[ "$(jq -r .status $d5/result.json)" = blocked ] && [ ! -e .forge/phases ] || fail "the blocked result.json stays in the state dir"
ok finish-blocked
fi

if want finish-refused; then
planned
wcommit a.txt a
result done
jq -n '{id: "T1", status: "failed"}' >$d5/tasks/T1.json
head=$(git rev-parse HEAD)
s=$(fin 05)
! grep -qF "no test pass" "$tmp/err" || fail "finish runs no test stamp check: $(outs)"
[ "$s" = 1 ] || fail "a refusing forge done exits 1: $(outs)"
grep -qF "forge: phase 05 is not done:" "$tmp/err" && grep -qF "  tasks: T1 not committed through forge task-done" "$tmp/err" || fail "forge done's refusal reaches stderr: $(outs)"
recorded || fail "result is recorded before forge done runs: $(outs)"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused finish commits nothing: $(subject)"
[ "$(jq -r .status $d5/result.json)" = done ] || fail "the done result.json stays in the state dir"
[ ! -e $fw/a.txt ] || fail "a refusing forge done merges nothing"
ok finish-refused
fi

if want finish-conflict; then
if [ -n "$only" ]; then
planned
result done
wcommit a.txt a
fi
jq -n '{id: "T1", status: "done"}' >$d5/tasks/T1.json
wcommit c.txt phase
echo feature >$fw/c.txt && git -C $fw add c.txt && git -C $fw commit -q -m feature
[ "$(fin 05)" = 6 ] || fail "a conflicting forge done exits 6: $(outs)"
grep -qF "forge/crm-export-05 conflicts with forge/crm-export in c.txt" "$tmp/err" || fail "forge done's conflict reaches stderr: $(outs)"
[ ! -e $fw/a.txt ] || fail "a conflicting forge done merges nothing"
ok finish-conflict
fi

if want finish-no-stamp; then
if [ -n "$only" ]; then
planned
result done
wcommit a.txt a
wcommit c.txt phase
echo feature >$fw/c.txt && git -C $fw add c.txt && git -C $fw commit -q -m feature
fi
! git -C $w merge -q forge/crm-export >/dev/null 2>&1 || fail "the phase branch must conflict with forge/crm-export"
echo both >$w/c.txt && git -C $w add c.txt && git -C $w commit -q --no-edit
tr=$(git -C $w rev-parse HEAD^{tree})
[ -z "$(find "$(git rev-parse --git-common-dir)" -path '*forge-test*' -name "$tr")" ] || fail "the phase has no test pass stamped for its HEAD tree"
: >"$tmp/runs"
[ "$(fin 05)" = 0 ] || fail "forge done finishes the phase: $(outs)"
[ -f $fw/a.txt ] && [ "$(cat $fw/c.txt)" = both ] || fail "forge done merges the phase branch"
tail -n 1 "$tmp/out" | grep -q '^forge: .*05' || fail "finish ends with one status line naming the phase: $(outs)"
[ ! -s "$tmp/runs" ] || fail "finish runs no test command: $(cat "$tmp/runs")"
ok finish-no-stamp
fi

if want finish-help; then
h=$("$forge" finish --help)
grep -qxF "Usage: forge finish <N>" <<<"$h" || fail "help gives the usage line with no --accept: $h"
grep -q '^Exit codes:' <<<"$h" || fail "help lists exit codes: $h"
! grep -qE '^ +4 ' <<<"$h" || fail "help gives no exit 4, finish checks no test stamp: $h"
! grep -qF -- '--passed' <<<"$h" && ! grep -qF 'forge-test/' <<<"$h" || fail "help names no forge test --passed call and no stamp read: $h"
! grep -qi "operator" <<<"$h" && ! grep -qF -- "--accept" <<<"$h" || fail "help names no operator words and no --accept: $h"
grep -q '^Reads:' <<<"$h" && grep -q '^Writes:' <<<"$h" && grep -q '^Example:' <<<"$h" || fail "help has Reads, Writes and Example: $h"
grep -qF 'STATE/phases/NN-slug/result.json' <<<"$h" && ! grep -qF '.forge/phases' <<<"$h" || fail "help names the result.json in STATE, not under .forge: $h"
! grep -qF 'result commit on main' <<<"$h" || fail "help names no result commit on main: $h"
ok finish-help
fi

finish
