#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
S=$XDG_STATE_HOME/forge/p

fresh
stub_run_claude
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S"/features/crm-export
jq -n '{phases: [{slug: "export-core", goal: "g", spec: [], requirements: ["EXP-01"], depends: []}]}' >"$S"/features/crm-export/split.json
jq -n '{requirements: [{id: "EXP-01", text: "export", done: false}]}' >"$S"/features/crm-export/requirements.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
git add -A && git commit -q -m init
d5="$S"/phases/05-export-core w5=.claude/worktrees/crm-export-05 fd="$S"/features/crm-export
idof() { printf %s "$1" | md5sum | cut -c1-8; }
agents() { jq -n '[$ARGS.positional[] | split("|") | {id: .[0], name: .[1], state: .[2]}]' --args "$@" >"$CLAUDE_AGENTS"; }
reset() { : >"$CLAUDE_LOG"; : >"$NOTIFY_LOG"; }
bgs() { grep -c -- "${1:- --bg }" "$CLAUDE_LOG" || true; }
refused() { grep "^forge: $1 not started: " "$tmp/out" || true; }
notes() { wc -l <"$NOTIFY_LOG"; }
loud() {
  local kind=$1 target=$2 live=$3 line
  line=$(refused "$kind $target")
  [ -n "$line" ] && [ "$(wc -l <<<"$line")" = 1 ] || fail "the refusal prints one 'forge: $kind $target not started: <reason>' line on stderr: $(cat "$tmp/out")"
  [[ $line == *"$live"* ]] || fail "the $kind refusal keeps its reason naming the live session $live: $line"
  [ "$(notes)" = 1 ] || fail "the $kind refusal sends one notification: $(cat "$NOTIFY_LOG")"
  [ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p $kind $target: ${line#"forge: $kind $target not started: "}" ] ||
    fail "the notification is titled 'forge: launch refused' with body '<root basename> $kind $target: <reason>': $(cat "$NOTIFY_LOG")"
}

if want capacity; then
agents "q1|q P03 crm/auth|working"
reset
s=$(code env FORGE_MAX_SESSIONS=1 "$forge" implement crm/export)
[ "$s" = 0 ] || fail "a hold at FORGE_MAX_SESSIONS stays exit 0: $s $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "a hold at FORGE_MAX_SESSIONS starts nothing: $(cat "$CLAUDE_LOG")"
grep -qxF "forge: recorded the held phase 05; forge watchdog starts it once room frees" "$tmp/out" || fail "the capacity hold is recorded as before: $(cat "$tmp/out")"
[ -z "$(refused "phase 05")" ] || fail "a capacity hold prints no refusal: $(cat "$tmp/out")"
[ "$(notes)" = 0 ] || fail "a capacity hold sends no notification: $(cat "$NOTIFY_LOG")"
ok capacity
fi

if want resume-live; then
agents
reset
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement with room starts phase 05: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P05 crm/export ")" = 1 ] || fail "implement starts phase 05: $(cat "$CLAUDE_LOG")"
agents "$(idof "p P05 crm/export")|p P05 crm/export|working"
reset
s=$(code "$forge" resume 05)
[ "$s" = 8 ] || fail "resume of a phase with a live session exits 8: $s $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "a refused resume launches nothing: $(cat "$CLAUDE_LOG")"
loud phase 05 "p P05 crm/export"
ok resume-live
fi

if want verify-live; then
agents
reset
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement starts phase 05: $(cat "$tmp/out")"
echo a >"$w5/a.txt" && git -C "$w5" add a.txt && git -C "$w5" commit -q -m a
"$forge" test "$w5" >"$tmp/out" 2>&1 || fail "forge test $w5: $(cat "$tmp/out")"
echo '{"status": "done", "summary": "g"}' >$d5/result.json
echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
agents
reset
[ "$(code "$forge" done 05)" = 0 ] || fail "done 05 starts Verify: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p verify crm/export ")" = 1 ] || fail "done 05 starts Verify: $(cat "$CLAUDE_LOG")"
agents "$(idof "p verify crm/export")|p verify crm/export|working"
reset
s=$(code "$forge" done 05)
[ "$s" = 8 ] || fail "a rerun done with a live Verify session exits 8: $s $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "a rerun done starts no second Verify: $(cat "$CLAUDE_LOG")"
loud verify crm/export "p verify crm/export"
ok verify-live
fi

if want ship-unmapped; then
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >$fd/verify.json
cp $fd/requirements.json "$tmp/req"
jq '.requirements += [{id: "EXP-03", text: "csv", done: false}, {id: "EXP-02", text: "pdf", done: false}]' "$tmp/req" >$fd/requirements.json
agents
reset
s=$(code "$forge" next crm/export)
[ "$s" = 8 ] || fail "next with a requirement no split phase maps exits 8: $s $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "next with an unmapped requirement starts no Ship: $(cat "$CLAUDE_LOG")"
[ "$(refused "ship crm/export")" = "forge: ship crm/export not started: requirement(s) EXP-03 EXP-02 map to no phase" ] ||
  fail "the refusal names the unmapped requirement IDs space-separated in file order: $(cat "$tmp/out")"
[ "$(notes)" = 1 ] || fail "the unmapped-requirement refusal sends one notification: $(cat "$NOTIFY_LOG")"
[ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p ship crm/export: requirement(s) EXP-03 EXP-02 map to no phase" ] ||
  fail "the notification is titled 'forge: launch refused' naming the unmapped requirements: $(cat "$NOTIFY_LOG")"
[ -f $fd/verify.json ] || fail "the unmapped-requirement refusal keeps verify.json"
[ ! -f "$XDG_STATE_HOME/forge/held.jsonl" ] || ! grep -q '"ship"' "$XDG_STATE_HOME/forge/held.jsonl" ||
  fail "the unmapped-requirement refusal is not held: $(cat "$XDG_STATE_HOME/forge/held.jsonl")"
mv $fd/requirements.json "$tmp/req2"
reset
s=$(code "$forge" next crm/export)
[ "$s" = 1 ] || fail "next with no requirements.json dies: $s $(cat "$tmp/out")"
grep -qF "$fd/requirements.json" "$tmp/out" || fail "next with no requirements.json names it: $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "next with no requirements.json starts no Ship: $(cat "$CLAUDE_LOG")"
mv "$tmp/req2" $fd/requirements.json
jq '.phases[0].requirements += ["EXP-02", "EXP-03"]' $fd/split.json >"$tmp/split" && cp "$tmp/split" $fd/split.json
agents
reset
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next once every requirement maps starts Ship: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p ship crm/export ")" = 1 ] || fail "next once every requirement maps starts Ship: $(cat "$CLAUDE_LOG")"
[ "$(notes)" = 0 ] || fail "a mapped Ship start sends no notification: $(cat "$NOTIFY_LOG")"
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >$fd/verify.json
jq '.phases[0].requirements = ["EXP-01"]' $fd/split.json >"$tmp/split" && cp "$tmp/split" $fd/split.json
jq '.requirements[1].owner = "post-ship" | .requirements[2].owner = "operator"' $fd/requirements.json >"$tmp/req" && cp "$tmp/req" $fd/requirements.json
agents
reset
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next skips unmapped operator and post-ship requirements: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p ship crm/export ")" = 1 ] || fail "next with only operator and post-ship requirements unmapped starts Ship: $(cat "$CLAUDE_LOG")"
[ "$(notes)" = 0 ] || fail "skipped operator and post-ship requirements send no notification: $(cat "$NOTIFY_LOG")"
grep -q 'operator\|post-ship' <<<"$("$forge" next --help)" || fail "next help says operator and post-ship requirements are skipped"
ok ship-unmapped
fi

if want ship-live; then
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >$fd/verify.json
agents
reset
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next on a passed verify starts Ship: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p ship crm/export ")" = 1 ] || fail "next starts Ship: $(cat "$CLAUDE_LOG")"
agents "s1|p ship crm/export|working"
reset
s=$(code "$forge" next crm/export)
[ "$s" = 8 ] || fail "a rerun next with a live Ship session exits 8: $s $(cat "$tmp/out")"
[ "$(bgs)" = 0 ] || fail "a rerun next starts no second Ship: $(cat "$CLAUDE_LOG")"
loud ship crm/export "p ship crm/export"
ok ship-live
fi

held=$XDG_STATE_HOME/forge/held.jsonl i5="$S"/phases/05-export-core i6="$S"/phases/06-export-api
holds() { [ ! -f "$held" ] || jq -r '"\(.kind) \(.target)"' "$held" | paste -sd, -; }
starts() { [ ! -f "$1/events.jsonl" ] || jq -s 'map(select(.step == "start")) | length' "$1/events.jsonl"; }
if want held-start; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
git add -A && git commit -q -m init
rm -f "$held"
agents "q1|q P03 crm/auth|working"
reset
export CLAUDE_BG_FAIL="p P05 crm/export"
s=$(code env FORGE_MAX_SESSIONS=2 FORGE_CONCURRENCY=1 CLAUDE_BG_ERR=$'Starting claude daemon\nError: dispatch failed' "$forge" implement crm/export)
[ "$s" = 8 ] || fail "a failed claude --bg start exits 8 after the other launches: $s $(cat "$tmp/out")"
grep -qxF "Starting claude daemon" "$tmp/out" && grep -qxF "Error: dispatch failed" "$tmp/out" ||
  fail "claude --bg's stderr still passes through: $(cat "$tmp/out")"
! grep -q "claude --bg failed to start" "$tmp/out" || fail "a failed start no longer dies: $(cat "$tmp/out")"
[ "$(refused "phase 05")" = "forge: phase 05 not started: claude --bg exited 1: Error: dispatch failed" ] ||
  fail "a failed start is refused with 'claude --bg exited <s>: <last stderr line>': $(cat "$tmp/out")"
[ "$(holds)" = "phase 05" ] || fail "the failed start of phase 05 is recorded in held.jsonl: $(holds)"
jq -se --arg r "$PWD" 'length == 1 and (.[0] | .root == $r and .kind == "phase" and .target == "05")' "$held" >/dev/null ||
  fail "the held failed start keeps the record format: $(cat "$held")"
grep -qxF "forge: recorded the held phase 05; forge watchdog starts it once room frees" "$tmp/out" ||
  fail "the held failed start prints the unchanged recorded line: $(cat "$tmp/out")"
[ "$(starts $i5)" = "" ] || [ "$(starts $i5)" = 0 ] || fail "a failed start logs no start event: $(cat $i5/events.jsonl)"
[ "$(bgs "--bg -n p P06 crm/export ")" = 1 ] ||
  fail "advance goes on and starts phase 06, the failed start not counted against FORGE_MAX_SESSIONS or FORGE_CONCURRENCY: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
[ "$(starts $i6)" = 1 ] || fail "phase 06 logs its start: $(cat $i6/events.jsonl 2>/dev/null)"
[ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p phase 05: claude --bg exited 1: Error: dispatch failed" ] ||
  fail "a held failed start sends one notification: $(cat "$NOTIFY_LOG")"
agents "q1|q P03 crm/auth|working" "$(idof "p P06 crm/export")|p P06 crm/export|done"
reset
s=$(code env FORGE_MAX_SESSIONS=2 CLAUDE_BG_ERR=$'Starting claude daemon\nError: dispatch failed' "$forge" implement crm/export)
[ "$s" = 8 ] || fail "a rerun whose start fails again still exits 8: $s $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P05 crm/export ")" = 1 ] || fail "the rerun tries phase 05 again: $(cat "$CLAUDE_LOG")"
[ "$(bgs "--bg -n p P06 crm/export ")" = 0 ] || fail "the rerun starts no second phase 06: $(cat "$CLAUDE_LOG")"
[ -n "$(refused "phase 05")" ] || fail "the rerun still prints the refusal: $(cat "$tmp/out")"
[ "$(holds)" = "phase 05" ] || fail "the rerun adds no second record: $(cat "$held")"
[ "$(notes)" = 0 ] || fail "a rerun with the record already queued sends no second notification: $(cat "$NOTIFY_LOG")"
unset CLAUDE_BG_FAIL
ok held-start
fi

if want untrusted-start; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
git add -A && git commit -q -m init
rm -f "$held"
agents
reset
export CLAUDE_BG_FAIL="p P05 crm/export"
s=$(code env CLAUDE_BG_ERR="Workspace not trusted. Run \`claude\` in $PWD/.claude/worktrees/crm-export-05 once and accept the trust prompt, then retry." "$forge" implement crm/export)
[ "$s" = 8 ] || fail "an untrusted start exits 8: $s $(cat "$tmp/out")"
[ "$(refused "phase 05")" = "forge: phase 05 not started: root $PWD is not trusted by Claude Code" ] ||
  fail "a 'Workspace not trusted' stderr names the main checkout as the untrusted root: $(cat "$tmp/out")"
[ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p phase 05: root $PWD is not trusted by Claude Code" ] ||
  fail "an untrusted start sends one notification naming the root: $(cat "$NOTIFY_LOG")"
[ "$(holds)" = "phase 05" ] || fail "an untrusted start is held in held.jsonl: $(holds)"
[ "$(starts $i5)" = "" ] || [ "$(starts $i5)" = 0 ] || fail "an untrusted start logs no start event: $(cat $i5/events.jsonl)"
unset CLAUDE_BG_FAIL
ok untrusted-start
fi

if want dirty; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S"/features/crm-export
jq -n '{phases: ([{slug: "export-core", goal: "core", spec: [], requirements: [], depends: []}]
  + [("api", "cli") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: ["export-core"]}])}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
echo base >a.txt
git add -A && git commit -q -m init
d5="$S"/phases/05-export-core i6="$S"/phases/06-export-api w5=.claude/worktrees/crm-export-05 w6=.claude/worktrees/crm-export-06
rm -f "$held"
agents
reset
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement starts phase 05: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P05 crm/export ")" = 1 ] || fail "implement starts phase 05: $(cat "$CLAUDE_LOG")"
echo core >"$w5/a.txt" && git -C "$w5" commit -q -am core
"$forge" test "$w5" >"$tmp/out" 2>&1 || fail "forge test $w5: $(cat "$tmp/out")"
echo '{"status": "done", "summary": "g"}' >$d5/result.json
echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
git worktree add -q -b forge/crm-export-06 "$w6" forge/crm-export
echo dirty >"$w6/a.txt"
agents
reset
s=$(code "$forge" done 05)
[ "$s" = 8 ] || fail "done 05 with a dirty sibling worktree exits 8 after launching the other due phases: $s $(cat "$tmp/out")"
git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "done 05 still merges phase 05 into the feature branch"
grep -q "would be overwritten by merge" "$tmp/out" || fail "git's refusal of the merge is printed on stderr: $(cat "$tmp/out")"
[ "$(refused "phase 06")" = "forge: phase 06 not started: worktree $PWD/$w6 has uncommitted changes" ] ||
  fail "the dirty sibling is refused with 'worktree <w> has uncommitted changes': $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P06 crm/export ")" = 0 ] || fail "the dirty phase 06 is not started: $(cat "$CLAUDE_LOG")"
[ "$(starts $i6)" = "" ] || [ "$(starts $i6)" = 0 ] || fail "the dirty phase 06 logs no start event: $(cat $i6/events.jsonl)"
[ "$(bgs "--bg -n p P07 crm/export ")" = 1 ] || fail "advance goes on and starts phase 07 after skipping the dirty 06: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
[ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p phase 06: worktree $PWD/$w6 has uncommitted changes" ] ||
  fail "the dirty sibling sends one notification: $(cat "$NOTIFY_LOG")"
[ -z "$(holds)" ] || fail "a dirty sibling is not held in held.jsonl: $(holds)"
[ "$(cat "$w6/a.txt")" = dirty ] || fail "the uncommitted change in $w6 is kept"
! git -C "$w6" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "no merge is left in progress in $w6"
ok dirty
fi

lk=$XDG_RUNTIME_DIR/forge/sessions.lock
rows() { printf '%s\n' "$@" | jq -Rn '[inputs | split("|") | {id: .[0], name: .[1], state: .[2], kind: "background", cwd: .[3], sessionId: ("5e55100d-0000-4000-8000-" + .[0] + "0000")}]' >"$CLAUDE_AGENTS"; }
tx() {
  local d=$HOME/.claude/projects/${1//[^a-zA-Z0-9]/-}
  mkdir -p "$d"
  { jq -nc '{type: "user", message: {role: "user", content: "go"}}'
    jq -nc --arg t "$3" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {}}, {type: "text", text: $t}]}}'
  } >"$d/5e55100d-0000-4000-8000-${2}0000.jsonl"
}
gaps() { jq -n --arg g "$1" '{manual_test: ["GET /export"], result: "gaps", gaps: [{phase: "05", gap: $g}]}' >$fd/verify.json; }
at() { grep -nE -- "$1" "$CLAUDE_LOG" | head -n1 | cut -d: -f1; }
rmd() { grep -cE " \| rm $1$" "$CLAUDE_LOG" || true; }
before() {
  local a b
  a=$(at " \| rm $1$") b=$(at "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$3 runs claude rm $1 before $2: $(cat "$CLAUDE_LOG")"
}
if want reap; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S"/features/crm-export
jq -n '{phases: [{slug: "export-core", goal: "core", spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
git add -A && git commit -q -m init
d5="$S"/phases/05-export-core fd="$S"/features/crm-export w5=$PWD/.claude/worktrees/crm-export-05 wf=$PWD/.claude/worktrees/crm-export
rm -f "$held"
agents
reset
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement starts phase 05: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P05 crm/export ")" = 1 ] || fail "implement starts phase 05: $(cat "$CLAUDE_LOG")"

i0=$(idof "p P05 crm/export") il=$(idof "p crm-export Phase 05") iq=$(idof "q P05 crm/export") wq=$tmp/q/.claude/worktrees/crm-export-05
rows "$i0|p P05 crm/export|working|$w5" "$il|p crm-export Phase 05|blocked|$w5" "$iq|q P05 crm/export|working|$wq"
tx "$w5" "$i0" $'Built the export core.\nresult: built the export core'
tx "$w5" "$il" $'result: done'
tx "$wq" "$iq" $'result: done'
gaps "Core is slow"
reset
s=$(code env CLAUDE_RM_LOCK="$lk" "$forge" next crm/export)
[ "$s" = 0 ] || fail "a retry whose earlier sessions are finished but still working reaps them and starts, exit 0: $s $(cat "$tmp/out")"
[ "$(rmd "$i0")" -ge 1 ] || fail "the retry removes the finished working session p P05 crm/export ($i0) with claude rm: $(cat "$CLAUDE_LOG")"
[ "$(rmd "$il")" -ge 1 ] || fail "the retry removes the finished blocked legacy session p crm-export Phase 05 ($il) with claude rm: $(cat "$CLAUDE_LOG")"
[ "$(rmd "$iq")" = 0 ] || fail "the retry leaves another project's session alone: $(cat "$CLAUDE_LOG")"
! grep -qE ' \| stop( |$)' "$CLAUDE_LOG" || fail "the reap never runs claude stop: $(cat "$CLAUDE_LOG")"
! grep -q "^unlocked " "$CLAUDE_LOG" || fail "the reap runs claude rm under sessions.lock: $(cat "$CLAUDE_LOG")"
[ "$(bgs "--bg -n p P05R1 crm/export ")" = 1 ] && [ "$(bgs)" = 1 ] || fail "the retry starts P05R1 once the old sessions are reaped: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
before "$i0" "--bg -n p P05R1 crm/export " "the retry"
before "$il" "--bg -n p P05R1 crm/export " "the retry"
[ "$(jq -sr 'map(select(.step == "start")) | last.message' $d5/events.jsonl)" = "p P05R1 crm/export" ] || fail "the retry logs its start: $(cat $d5/events.jsonl)"
[ -z "$(refused "phase 05")" ] && [ "$(notes)" = 0 ] || fail "a reaped retry prints no refusal and sends no notification: $(cat "$tmp/out") $(cat "$NOTIFY_LOG")"
[ -z "$(holds)" ] || fail "a reaped retry holds nothing: $(holds)"

i1=$(idof "p P05R1 crm/export")
rows "$i1|p P05R1 crm/export|working|$w5"
tx "$w5" "$i1" $'The format is:\n```\nresult: <summary>\n```\nStill going.'
gaps "Core is still slow"
reset
s=$(code "$forge" next crm/export)
[ "$s" = 8 ] || fail "a retry with an unfinished working session exits 8: $s $(cat "$tmp/out")"
[ "$(rmd "$i1")" = 0 ] || fail "an unfinished session, whose only result: line is fenced, is not removed: $(cat "$CLAUDE_LOG")"
[ "$(bgs)" = 0 ] || fail "a retry with an unfinished working session starts nothing: $(cat "$CLAUDE_LOG")"
loud phase 05 "p P05R1 crm/export"
[ -z "$(holds)" ] || fail "an unfinished live session is not held: $(holds)"

tx "$w5" "$i1" $'Built it.\nresult: built the export core'
gaps "Core is slow again"
reset
s=$(code env CLAUDE_RM_FAIL="$i1" "$forge" next crm/export)
[ "$s" = 8 ] || fail "a failed claude rm with the session still listed exits 8: $s $(cat "$tmp/out")"
[ "$(rmd "$i1")" -ge 1 ] || fail "the finished session is removed with claude rm: $(cat "$CLAUDE_LOG")"
[ "$(bgs)" = 0 ] || fail "a failed claude rm with the session still listed starts nothing: $(cat "$CLAUDE_LOG")"
loud phase 05 ""
[ -z "$(holds)" ] || fail "a failed claude rm is not held: $(holds)"

gaps "Core is slow once more"
reset
st=$(date +%s%3N)
s=$(code env CLAUDE_RM_KEEP="$i1" "$forge" next crm/export)
el=$(($(date +%s%3N) - st))
[ "$s" = 8 ] || fail "a session still working 5 s after claude rm exits 8: $s $(cat "$tmp/out")"
[ "$(rmd "$i1")" -ge 1 ] || fail "the finished session is removed with claude rm: $(cat "$CLAUDE_LOG")"
[ "$(bgs)" = 0 ] || fail "a session still working after claude rm starts nothing: $(cat "$CLAUDE_LOG")"
[ "$el" -ge 4500 ] && [ "$el" -lt 30000 ] || fail "forge re-lists the sessions for about 5 s after claude rm, took $el ms"
x=$(at " \| rm $i1$")
[ "$(tail -n +"$x" "$CLAUDE_LOG" | grep -c ' | agents --json --all')" -ge 5 ] ||
  fail "forge re-lists claude agents --json --all every 0.5 s after claude rm: $(cat "$CLAUDE_LOG")"
x=$(refused "phase 05")
[[ $x == *"p P05R1 crm/export"* && $x == *"$i1"* && $x == *"finished but still running after claude rm"* ]] ||
  fail "the refusal names the session, its id and that it is finished but still running after claude rm: $(cat "$tmp/out")"
loud phase 05 "finished but still running after claude rm"
[ -z "$(holds)" ] || fail "a session still running after claude rm is not held: $(holds)"

rm -f "$HOME/.claude/projects/${w5//[^a-zA-Z0-9]/-}/5e55100d-0000-4000-8000-${i1}0000.jsonl"
echo '{"status": "blocked", "summary": "needs a key"}' >$d5/result.json
io=$(idof "o P05R1 crm/export") wo=$tmp/o/p/.claude/worktrees/crm-export-05
rows "$i1|p P05R1 crm/export|blocked|$w5" "$io|p P05R1 crm/export|working|$wo"
reset
s=$(code "$forge" resume 05)
[ "$s" = 8 ] || fail "resume with a same-named working session of another project named p exits 8: $s $(cat "$tmp/out")"
[ "$(rmd "$io")" = 0 ] && [ "$(rmd "$i1")" = 0 ] || fail "resume removes no session while another project's same-named session works, though result.json marks the phase finished: $(cat "$CLAUDE_LOG")"
[ "$(bgs)" = 0 ] || fail "resume with another project's same-named working session starts nothing: $(cat "$CLAUDE_LOG")"
[ -f $d5/result.json ] || fail "a refused resume keeps result.json"
loud phase 05 "p P05R1 crm/export"
rows "$i1|p P05R1 crm/export|blocked|$w5"
reset
s=$(code env CLAUDE_RM_LOCK="$lk" "$forge" resume 05)
[ "$s" = 0 ] || fail "resume reaps a session its phase's result.json marks finished and starts, exit 0: $s $(cat "$tmp/out")"
[ "$(rmd "$i1")" -ge 1 ] || fail "resume removes the blocked session that result.json marks finished, before it removes result.json: $(cat "$CLAUDE_LOG")"
! grep -q "^unlocked " "$CLAUDE_LOG" || fail "resume runs claude rm under sessions.lock: $(cat "$CLAUDE_LOG")"
[ "$(bgs "--bg -n p P05R4 crm/export ")" = 1 ] && [ "$(bgs)" = 1 ] || fail "resume starts P05R4 after the reap: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
before "$i1" "--bg -n p P05R4 crm/export " "resume"
[ ! -e $d5/result.json ] || fail "resume still removes result.json before the launch"
[ -z "$(refused "phase 05")" ] && [ "$(notes)" = 0 ] || fail "a reaped resume prints no refusal and sends no notification: $(cat "$tmp/out") $(cat "$NOTIFY_LOG")"

echo core >"$w5/a.txt" && git -C "$w5" add a.txt && git -C "$w5" commit -q -m core
"$forge" test "$w5" >"$tmp/out" 2>&1 || fail "forge test $w5: $(cat "$tmp/out")"
echo '{"status": "done", "summary": "g"}' >$d5/result.json
echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
iv=$(idof "p verify crm/export")
rows "$iv|p verify crm/export|working|$wf"
tx "$wf" "$iv" $'Checked the export.\nresult: verified crm/export'
reset
s=$(code env CLAUDE_RM_LOCK="$lk" "$forge" done 05)
[ "$s" = 0 ] || fail "done reaps a lingering finished verify session and starts Verify, exit 0: $s $(cat "$tmp/out")"
[ "$(rmd "$iv")" -ge 1 ] || fail "the lingering finished verify session is removed with claude rm: $(cat "$CLAUDE_LOG")"
! grep -q "^unlocked " "$CLAUDE_LOG" || fail "the verify reap runs claude rm under sessions.lock: $(cat "$CLAUDE_LOG")"
! grep -qE ' \| stop( |$)' "$CLAUDE_LOG" || fail "the verify reap never runs claude stop: $(cat "$CLAUDE_LOG")"
[ "$(bgs "--bg -n p verify crm/export ")" = 1 ] && [ "$(bgs)" = 1 ] || fail "done starts Verify after the reap: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
before "$iv" "--bg -n p verify crm/export " "the verify launch"
[ -z "$(refused "verify crm/export")" ] && [ "$(notes)" = 0 ] || fail "a reaped verify prints no refusal and sends no notification: $(cat "$tmp/out") $(cat "$NOTIFY_LOG")"
ok reap
fi

if want stall; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git init -q -b main child && mkdir child/.forge && echo "# child" >child/.forge/PROJECT.md && git -C child add -A && git -C child commit -q -m init
echo child/ >>.git/info/exclude
mkdir -p "$S"/features/crm-export
jq -n '{phases: [{slug: "export-core", goal: "core", spec: [], requirements: [], depends: []},
  {slug: "export-lib", goal: "lib", spec: [], requirements: [], depends: ["export-core"], repo: "child"},
  {slug: "export-api", goal: "api", spec: [], requirements: [], depends: ["export-core"]},
  {slug: "export-cli", goal: "cli", spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
printf -- '- All tests: `true`\n' >.forge/TESTING.md
echo base >a.txt
git add -A && git commit -q -m init
d5="$S"/phases/05-export-core i6="$S"/phases/06-export-lib i7="$S"/phases/07-export-api d8="$S"/phases/08-export-cli
w5=$PWD/.claude/worktrees/crm-export-05 w6=$PWD/child/.claude/worktrees/crm-export-06 w7=$PWD/.claude/worktrees/crm-export-07 w8=$PWD/.claude/worktrees/crm-export-08
rm -f "$held"
agents
reset
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement starts phases 05 and 08: $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P05 crm/export ")" = 1 ] && [ "$(bgs "--bg -n p P08 crm/export ")" = 1 ] || fail "implement starts phases 05 and 08: $(cat "$CLAUDE_LOG")"
echo core >"$w5/a.txt" && git -C "$w5" commit -q -am core
"$forge" test "$w5" >"$tmp/out" 2>&1 || fail "forge test $w5: $(cat "$tmp/out")"
echo '{"status": "done", "summary": "g"}' >$d5/result.json
echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
git worktree add -q -b forge/crm-export-07 "$w7" forge/crm-export
echo dirty >"$w7/a.txt"
jq -nc '{time: "2026-10-15T00:00:00Z", step: "retry", message: "gaps: 1"}' >>$d8/events.jsonl
i8=$(idof "p P08 crm/export")
rows "$i8|p P08 crm/export|working|$w8"
tx "$w8" "$i8" $'Built the export cli.\nresult: built the export cli'
reset
s=$(code env CLAUDE_RM_LOCK="$lk" "$forge" done 05)
[ "$s" = 8 ] || fail "done 05 launches or refuses every due phase and exits 8 for the dirty sibling: $s $(cat "$tmp/out")"
git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "done 05 merges phase 05 into the feature branch"
grep -qF "$w6 | --bg -n p/child P06 crm/export " "$CLAUDE_LOG" || fail "the child repo phase 06 starts in its new worktree: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
[ "$(starts $i6)" = 1 ] || fail "phase 06 logs its start: $(cat $i6/events.jsonl 2>/dev/null)"
[ "$(rmd "$i8")" -ge 1 ] || fail "the retry removes its finished but working session p P08 crm/export ($i8) with claude rm: $(cat "$CLAUDE_LOG")"
! grep -qE ' \| stop( |$)' "$CLAUDE_LOG" || fail "the reap never runs claude stop: $(cat "$CLAUDE_LOG")"
! grep -q "^unlocked " "$CLAUDE_LOG" || fail "the reap runs claude rm under sessions.lock: $(cat "$CLAUDE_LOG")"
[ "$(bgs "--bg -n p P08R1 crm/export ")" = 1 ] || fail "the retry of phase 08 starts P08R1: $(cat "$CLAUDE_LOG") $(cat "$tmp/out")"
before "$i8" "--bg -n p P08R1 crm/export " "the retry of phase 08"
[ "$(jq -sr 'map(select(.step == "start")) | last.message' $d8/events.jsonl)" = "p P08R1 crm/export" ] || fail "the retry logs its start: $(cat $d8/events.jsonl)"
grep -q "would be overwritten by merge" "$tmp/out" || fail "git's refusal of the dirty sibling's merge is printed on stderr: $(cat "$tmp/out")"
[ "$(refused "phase 07")" = "forge: phase 07 not started: worktree $w7 has uncommitted changes" ] ||
  fail "the dirty sibling is refused with 'worktree <w> has uncommitted changes': $(cat "$tmp/out")"
[ "$(bgs "--bg -n p P07 crm/export ")" = 0 ] || fail "the dirty phase 07 is not started: $(cat "$CLAUDE_LOG")"
[ "$(starts $i7)" = "" ] || [ "$(starts $i7)" = 0 ] || fail "the dirty phase 07 logs no start event: $(cat $i7/events.jsonl)"
[ "$(cat "$w7/a.txt")" = dirty ] || fail "the uncommitted change in $w7 is kept"
[ "$(bgs)" = 2 ] || fail "done 05 starts exactly phase 06 and the retry of phase 08: $(cat "$CLAUDE_LOG")"
[ "$(grep -c " not started: " "$tmp/out")" = 1 ] || fail "only the dirty sibling is refused: $(cat "$tmp/out")"
[ -z "$(holds)" ] || fail "done 05 holds nothing: $(holds)"
[ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p phase 07: worktree $w7 has uncommitted changes" ] ||
  fail "\$NOTIFY_LOG holds exactly one notification, for the refused phase 07: $(cat "$NOTIFY_LOG")"
ok stall
fi

finish
