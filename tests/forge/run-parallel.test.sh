#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
S=$XDG_STATE_HOME/forge/p

fresh
stub_run_claude
alltests() { printf -- '- All tests: `true`\n' >"${1:-.}/.forge/TESTING.md"; }
tested() { "$forge" test "$1" >"$tmp/out" 2>&1 || fail "forge test $1: $(cat "$tmp/out")"; }
pid() { printf %s "p P$1 crm/export" | md5sum | cut -c1-8; }
idle() { local n; for n; do jq -n --arg i "$(pid "$n")" --arg n "$n" '{id: $i, name: "p P\($n) crm/export", state: "done", status: "idle"}'; done | jq -s . >"$CLAUDE_AGENTS"; }
recorded() { echo '{"findings": []}' >"$1/review.json"; echo '{"command": "true", "passed": true, "criteria": []}' >"$1/verify.json"; }
repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}
: >"$CLAUDE_LOG"
echo '[]' >"$CLAUDE_AGENTS"
p=$PWD
last() { tail -n1 "$CLAUDE_LOG"; }
opts="--model opus --effort medium --permission-mode"
s5="--settings {\"env\":{\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_TEST_DB\":\"p_test_05\",\"FORGE_ROOT\":\"$p\",\"FORGE_PHASE\":\"05\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}}"
sv="--settings {\"disableBundledSkills\":true,\"env\":{\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\",\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_ROOT\":\"$p\"},\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"baseRef\":\"head\",\"bgIsolation\":\"none\"}}"
norm() { [[ $1 =~ ^(.*)\ --settings\ (\{[^ ]*\})\ (.*)$ ]] && echo "${BASH_REMATCH[1]} --settings $(jq -cS . <<<"${BASH_REMATCH[2]}") ${BASH_REMATCH[3]}"; }
work() {
  local w=.claude/worktrees/crm-export-$1 d=("$S"/phases/"$1"-*)
  echo "$1" >"$w/$1.txt" && git -C "$w" add "$1.txt" && git -C "$w" commit -q -m "$1"
  "$forge" test "$w" >/dev/null
  echo '{"status": "done", "summary": "x"}' >"${d[0]}/result.json"
  recorded "${d[0]}"
}


bgs() { grep -- ' --bg ' "$CLAUDE_LOG" | sed -E 's/.* --bg -n p (P[0-9]+(R[0-9]+)?|verify) crm\/export .*/\1/' | paste -sd, || true; }
if want concurrency; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api", "ui", "cli") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
git add -A && git commit -q -m init
export FORGE_CONCURRENCY=2
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
[ "$(bgs)" = "P05,P06" ] || fail "a cap of 2 launches 05 then 06: $(bgs)"
idle 05 06
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
[ -z "$(bgs)" ] || fail "idle phase sessions keep their slots: $(bgs)"
idle 05 06
jq '.[0].state = "crashed"' "$CLAUDE_AGENTS" >"$tmp/agents" && mv "$tmp/agents" "$CLAUDE_AGENTS"
"$forge" implement crm/export >/dev/null 2>"$tmp/err"
[ "$(bgs)" = "P05" ] || fail "a crashed phase session is relaunched in its slot: $(bgs)"
grep -qxF "forge: phase 05's session p P05 crm/export is gone; relaunching it" "$tmp/err" || fail "the relaunch says why: $(cat "$tmp/err")"
grep -q " | rm $(pid 05)$" "$CLAUDE_LOG" || fail "the relaunch removes the crashed session: $(cat "$CLAUDE_LOG")"
echo '[]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null 2>&1
[ "$(bgs)" = "P05,P06" ] || fail "phase sessions missing from claude agents are relaunched: $(bgs)"
idle 05 06 07 08
: >"$CLAUDE_LOG"
"$forge" resume 05 >/dev/null
[ "$(bgs)" = "P05" ] || fail "resume relaunches only the crashed phase: $(bgs)"
work 05
: >"$CLAUDE_LOG"
"$forge" done 05 >/dev/null
[ "$(bgs)" = "P07" ] || fail "done of 05 frees a slot for 07: $(bgs)"
idle 06 07 08
work 06
echo '{"status": "blocked", "summary": "stuck"}' >"$S"/phases/06-export-api/result.json
: >"$CLAUDE_LOG"
"$forge" done 06 >/dev/null
! git merge-base --is-ancestor forge/crm-export-06 forge/crm-export || fail "a blocked result must not merge"
[ "$(bgs)" = "P08" ] || fail "a blocked result frees its slot for 08: $(bgs)"
idle 06 07 08
jq '(.phases[] | select(.slug == "export-ui") | .goal) = "UI2"' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
[ "$("$forge" alloc crm/export)" = "replan $S/phases/07-export-ui" ] || fail "alloc replans the changed phase"
[ "$(jq -sr 'last.step' "$S"/phases/07-export-ui/events.jsonl)" = replan ] || fail "alloc logs a replan event: $(cat "$S"/phases/07-export-ui/events.jsonl)"
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
[ "$(bgs)" = "P07" ] || fail "a replanned phase relaunches: $(bgs)"
export FORGE_CONCURRENCY=10
ok concurrency
fi

verifies() { grep -c -- '--bg -n p verify crm/export ' "$CLAUDE_LOG" || true; }
many() {
  fresh
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  echo '[]' >"$CLAUDE_AGENTS"
  mkdir -p "$S"/features/crm-export
  jq -n --argjson k "$1" '{phases: [range($k) | {slug: "export-\(.)", goal: "g", spec: [], requirements: (if . == 0 then ["EXP-01"] else [] end), depends: []}]}' >"$S"/features/crm-export/split.json
  jq -n '{requirements: [{id: "EXP-01", text: "export", done: false}]}' >"$S"/features/crm-export/requirements.json
  "$forge" alloc crm/export >/dev/null
  alltests
  git add -A && git commit -q -m init
  : >"$CLAUDE_LOG"
  "$forge" implement crm/export >/dev/null
}
others='[{"id": "q1", "name": "q P03 crm/auth", "state": "working"}, {"id": "q2", "name": "q verify crm/auth", "state": "working"},
  {"id": "q3", "name": "q P04R1 crm/auth", "state": "working"}, {"id": "q4", "name": "q ship crm/auth", "state": "working"},
  {"id": "q13", "name": "q crm-intake Phase 10", "state": "working"}, {"id": "q14", "name": "q crm-intake Phase 11 retry 1", "state": "working"},
  {"id": "q15", "name": "q crm-intake Verify", "state": "working"}, {"id": "q16", "name": "q crm-intake Ship", "state": "working"},
  {"id": "q17", "name": "q discuss crm/auth", "state": "working"}, {"id": "q18", "name": "q discuss crm/intake", "state": "working"},
  {"id": "q19", "name": "q quick fix the login", "state": "working"}, {"id": "q20", "name": "q fast bump the version", "state": "working"},
  {"id": "q21", "name": "q debug login loops", "state": "working"}, {"id": "q22", "name": "q new crm app", "state": "working"},
  {"id": "q23", "name": "q fix the flaky test", "state": "working"}, {"id": "q24", "name": "q crm-intake Phase 12", "state": "blocked"},
  {"id": "q5", "name": "q Discuss crm/auth", "state": "working"}, {"id": "q6", "name": "q Quick fix the login", "state": "working"},
  {"id": "q7", "name": "q Debug login loops", "state": "working"}, {"id": "q8", "name": "q P05 crm/auth", "state": "blocked"},
  {"id": "q9", "name": "q P06 crm/auth", "state": "done"}, {"id": "q10", "name": "q P07 crm/auth", "state": "failed"},
  {"id": "q11", "name": "q P08 crm/auth", "state": "stopped"}, {"id": "q12", "name": "q P09 crm/auth", "state": "crashed"},
  {"id": "q25", "name": "q ship crm/billing", "state": "done"}, {"id": "q26", "name": "q discuss crm/billing", "state": "stopped"},
  {"id": "q27", "name": "q quick tidy the readme", "state": "crashed"}, {"id": "q28", "name": "q debug slow page", "state": "failed"},
  {"id": "q29", "name": "q crm-intake Ship", "state": "blocked"}, {"id": "q30", "name": "q build crm/auth", "state": "working"},
  {"id": "q31", "name": "q audit the deps", "state": "working"}]'
agents() { local a; for a; do jq -n --arg i "$(pid "${a%%:*}")" --arg a "$a" '$a | split(":") | {id: $i, name: ("p P" + .[0] + " crm/export"), state: .[1]}'; done | jq -s --argjson o "$others" '. + $o' >"$CLAUDE_AGENTS"; }

if want caps; then
many 12
[ "$(bgs)" = "P05,P06,P07,P08,P09,P10,P11,P12,P13,P14" ] || fail "an explicit FORGE_CONCURRENCY of 10 caps a feature at 10: $(bgs)"
work 05
agents 05:done 06:blocked 07:blocked 08:blocked 09:blocked 10:working 11:working 12:working 13:working 14:working
export FORGE_MAX_SESSIONS=20
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done at the machine-wide cap exits 0: $(cat "$tmp/out")"
[ "$(bgs)" = "P15" ] || fail "19 live forge sessions (other projects' new and legacy-named phase, retry, verify and ship sessions and discuss, quick, fast, debug and new sessions counted; plain, capitalized, build, audit, blocked, done, failed, stopped, crashed not) leave room for one under a cap of 20, and blocked phases are not relaunched: $(bgs)"
grep -qxF "forge: 20 forge sessions live; phase 16 waits for a free session" "$tmp/out" || fail "the wait message counts the session just started: $(cat "$tmp/out")"
! grep -q "is gone" "$tmp/out" || fail "a blocked phase session is live, not gone: $(cat "$tmp/out")"
export FORGE_MAX_SESSIONS=12
cap=12
all=$others
others='[{"id": "q4", "name": "q ship crm/auth", "state": "working"}, {"id": "q16", "name": "q crm-intake Ship", "state": "working"},
  {"id": "q17", "name": "q discuss crm/auth", "state": "working"}, {"id": "q19", "name": "q quick fix the login", "state": "working"},
  {"id": "q21", "name": "q debug login loops", "state": "working"}, {"id": "q20", "name": "q fast bump the version", "state": "working"},
  {"id": "q25", "name": "q ship crm/billing", "state": "done"}]'
agents 05:done 06:blocked 07:blocked 08:blocked 09:blocked 10:working 11:working 12:working 13:working 14:working 15:working
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done at the default machine cap exits 0: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "with FORGE_MAX_SESSIONS at 12, 12 live forge sessions fill the default cap of $cap: $(bgs)"
grep -qxF "forge: $cap forge sessions live; phase 16 waits for a free session" "$tmp/out" || fail "the default machine cap is the code default $cap: $(cat "$tmp/out")"
others=$(jq -c 'map(select(.id != "q20"))' <<<"$others")
agents 05:done 06:blocked 07:blocked 08:blocked 09:blocked 10:working 11:working 12:working 13:working 14:working 15:working
others=$all
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "a later done exits 0: $(cat "$tmp/out")"
[ "$(bgs)" = "P16" ] || fail "with FORGE_MAX_SESSIONS at 12, 11 live forge sessions leave room for one under the default cap of $cap, blocked sessions holding no per-feature slot: $(bgs)"
ok caps
fi

if want caps-resume; then
many 2
echo '{"status": "blocked", "summary": "stuck"}' >"$S"/phases/06-export-1/result.json
agents 05:working 06:done
export FORGE_MAX_SESSIONS=15
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 06)" = 0 ] || fail "resume at the machine-wide cap exits 0: $(cat "$tmp/out")"
grep -qxF "forge: 15 forge sessions live; phase 06 waits for a free session" "$tmp/out" || fail "resume at the cap says why: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "resume at the cap starts no session: $(bgs)"
[ ! -f "$S"/phases/06-export-1/result.json ] || fail "resume at the cap leaves result.json removed"
work 05
agents 05:done 06:done
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with room: $(cat "$tmp/out")"
[ "$(bgs)" = "P06" ] || fail "a later advance with room starts the phase resume left due: $(bgs)"
export FORGE_MAX_SESSIONS=12
ok caps-resume
fi

if want caps-verify; then
many 1
work 05
agents 05:done
export FORGE_MAX_SESSIONS=14
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with Verify at the cap exits 0: $(cat "$tmp/out")"
grep -qxF "forge: 14 forge sessions live; crm/export Verify waits for a free session" "$tmp/out" || fail "Verify at the cap says why: $(cat "$tmp/out")"
[ "$(verifies)" = 0 ] || fail "Verify at the cap starts no session: $(cat "$CLAUDE_LOG")"
export FORGE_MAX_SESSIONS=15
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with room for Verify: $(cat "$tmp/out")"
[ "$(verifies)" = 1 ] || fail "a later done with room starts Verify: $(cat "$CLAUDE_LOG")"
export FORGE_MAX_SESSIONS=12
ok caps-verify
fi

if want sync-unmet; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: [{slug: "export-core", goal: "c", spec: [], requirements: [], depends: []}, {slug: "export-api", goal: "a", spec: [], requirements: [], depends: ["export-core"]}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
git add -A && git commit -q -m init
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
[ "$(bgs)" = "P05" ] || fail "only 05 starts before its dependent: $(bgs)"
work 05
jq '.unmet = [{task: "sync", reason: "merge conflict on 05.txt"}]' "$S"/phases/05-export-core/result.json >"$tmp/r" && mv "$tmp/r" "$S"/phases/05-export-core/result.json
idle 05
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "a sync-unmet done exits 0: $(cat "$tmp/out")"
! git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "a sync-unmet done leaves 05 unmerged"
[ "$(bgs)" = "P06" ] || fail "a sync-unmet done phase counts complete, so its dependent 06 starts: $(bgs)"
work 06
idle 05 06
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 06)" = 0 ] || fail "done of 06 exits 0: $(cat "$tmp/out")"
[ "$(verifies)" = 1 ] || fail "with 05 sync-unmet and 06 merged, feature verify starts: $(cat "$CLAUDE_LOG")"
ok sync-unmet
fi

mem() { printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\n' "$1" >"$FORGE_PROC_ROOT/meminfo"; }
live() { local a; for a; do jq -n --arg i "$(pid "${a%%:*}")" --arg a "$a" '$a | split(":") | {id: $i, name: ("p P" + .[0] + " crm/export"), state: .[1]}'; done | jq -s . >"$CLAUDE_AGENTS"; }
ships() { grep -c -- '--bg -n p ship crm/export ' "$CLAUDE_LOG" || true; }
if want memory; then
mem 3670016
many 3 2>"$tmp/err"
[ -z "$(bgs)" ] || fail "3.5 GiB MemAvailable, under 3 GiB plus 1 GiB for the first session, starts no phase: $(bgs)"
grep -qxE 'forge: MemAvailable 3\.50* GiB; phase 05 waits for memory' "$tmp/err" || fail "the first due phase says it waits for memory: $(cat "$tmp/err")"
! grep -q 'phase 0[67] waits' "$tmp/err" || fail "the call stops at the first phase that waits: $(cat "$tmp/err")"
mem 5242880
: >"$CLAUDE_LOG"
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement short of memory exits 0: $(cat "$tmp/out")"
[ "$(bgs)" = "P05,P06" ] || fail "5 GiB MemAvailable starts two of three due phases (3 GiB plus 1 GiB each): $(bgs)"
grep -qxE 'forge: MemAvailable 5(\.0+)? GiB; phase 07 waits for memory' "$tmp/out" || fail "the third due phase says it waits for memory: $(cat "$tmp/out")"
mem 16777216
work 05
live 05:done 06:working
mem 6291456
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "a later done with more memory exits 0: $(cat "$tmp/out")"
[ "$(bgs)" = "P07" ] || fail "a later call with memory for one more session launches the waiting phase: $(bgs) $(cat "$tmp/out")"
! grep -q 'waits for memory' "$tmp/out" || fail "nothing waits once memory allows: $(cat "$tmp/out")"

mem 16777216
many 2
echo '{"status": "blocked", "summary": "stuck"}' >"$S"/phases/06-export-1/result.json
live 05:working 06:done
mem 3670016
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 06)" = 0 ] || fail "resume short of memory exits 0: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "resume short of memory starts no session: $(bgs)"
grep -qxE 'forge: MemAvailable 3\.50* GiB; phase 06 waits for memory' "$tmp/out" || fail "resume short of memory says why: $(cat "$tmp/out")"
jq -se 'last | .step == "wait" and (.message | test("memory"))' "$S"/phases/06-export-1/events.jsonl >/dev/null ||
  fail "resume logs a wait event naming memory: $(cat "$S"/phases/06-export-1/events.jsonl)"
: >"$CLAUDE_LOG"
[ "$(FORGE_PROC_ROOT=$tmp/noproc code "$forge" resume 06)" = 1 ] || fail "an unreadable meminfo makes the launch die: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "an unreadable meminfo starts no session: $(bgs)"
grep -qiE 'meminfo|MemAvailable' "$tmp/out" || fail "an unreadable meminfo dies with a message naming it: $(cat "$tmp/out")"

mem 16777216
many 1
work 05
live 05:done
mem 3670016
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with Verify short of memory exits 0: $(cat "$tmp/out")"
[ "$(verifies)" = 0 ] || fail "Verify short of memory starts no session: $(cat "$CLAUDE_LOG")"
grep -qxE 'forge: MemAvailable 3\.50* GiB; crm/export Verify waits for memory' "$tmp/out" || fail "Verify short of memory says why: $(cat "$tmp/out")"
mem 16777216
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with memory for Verify: $(cat "$tmp/out")"
[ "$(verifies)" = 1 ] || fail "a later done with memory starts Verify: $(cat "$CLAUDE_LOG")"
live 05:done
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >"$S"/features/crm-export/verify.json
mem 3670016
: >"$CLAUDE_LOG"
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next with Ship short of memory exits 0: $(cat "$tmp/out")"
[ "$(ships)" = 0 ] || fail "Ship short of memory starts no session: $(cat "$CLAUDE_LOG")"
grep -qxE 'forge: MemAvailable 3\.50* GiB; crm/export Ship waits for memory' "$tmp/out" || fail "Ship short of memory says why: $(cat "$tmp/out")"
[ -f "$S"/features/crm-export/verify.json ] || fail "Ship short of memory keeps verify.json"
mem 16777216
: >"$CLAUDE_LOG"
[ "$(code "$forge" next crm/export)" = 0 ] || fail "a later next with memory exits 0: $(cat "$tmp/out")"
[ "$(ships)" = 1 ] || fail "a later next with memory starts Ship: $(cat "$CLAUDE_LOG")"
ok memory
fi

held=$XDG_STATE_HOME/forge/held.jsonl
holds() { [ ! -f "$held" ] || jq -r '"\(.kind) \(.target)"' "$held" | paste -sd, -; }
noted() { grep -qxF "forge: recorded the held $1; forge watchdog starts it once room frees" "$tmp/out" || fail "a recorded hold of $1 says so: $(cat "$tmp/out")"; }
timed() { jq -sr --arg t "$1" 'map(select(.target == $t)) | map(.time) | join(",")' "$held"; }
foreign='{"id": "q1", "name": "q P03 crm/auth", "state": "working"}'
if want held; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: ([("a", "b", "c", "d") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]
  + [{slug: "export-e", goal: "e", spec: [], requirements: [], depends: ["export-a"]}])}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
git add -A && git commit -q -m init
rm -f "$held"
: >"$CLAUDE_LOG"
[ "$(code env FORGE_CONCURRENCY=1 "$forge" implement crm/export)" = 0 ] || fail "implement under FORGE_CONCURRENCY=1: $(cat "$tmp/out")"
[ "$(bgs)" = P05 ] || fail "FORGE_CONCURRENCY=1 starts phase 05 only: $(bgs)"
[ -z "$(holds)" ] || fail "a FORGE_CONCURRENCY stop is not a hold and records nothing: $(cat "$held")"
idle 05 && jq --argjson q "$foreign" '. + [$q]' "$CLAUDE_AGENTS" >"$tmp/agents" && mv "$tmp/agents" "$CLAUDE_AGENTS"
export FORGE_MAX_SESSIONS=2
: >"$CLAUDE_LOG"
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement holding a phase at the cap exits 0: $(cat "$tmp/out")"
[ "$(bgs)" = P06 ] || fail "one place under the cap starts phase 06: $(bgs)"
[ "$(holds)" = "phase 07,phase 08" ] || fail "the held phase 07 and the later due 08 are recorded, not the launched 05 and 06: $(holds)"
jq -se --arg r "$PWD" 'map(select(.target == "07")) | length == 1 and (.[0] | keys == ["kind", "root", "target", "time"] and .root == $r and .kind == "phase"
  and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and ((.time | fromdateiso8601) - now | fabs) < 300)' "$held" >/dev/null ||
  fail "a phase held at the cap writes one record of the project root, kind phase, its number and the UTC time: $(cat "$held")"
noted "phase 07"
noted "phase 08"
jq -c 'if .target == "07" then .time = "2020-01-01T00:00:00Z" else . end' "$held" >"$tmp/held" && mv "$tmp/held" "$held"
idle 05 06 && jq --argjson q "$foreign" '. + [$q]' "$CLAUDE_AGENTS" >"$tmp/agents" && mv "$tmp/agents" "$CLAUDE_AGENTS"
export FORGE_MAX_SESSIONS=1
: >"$CLAUDE_LOG"
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "a rerun held again exits 0: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "a rerun at the cap starts nothing: $(bgs)"
[ "$(holds)" = "phase 07,phase 08" ] || fail "a rerun held again adds no second record: $(cat "$held")"
[ "$(timed 07)" = 2020-01-01T00:00:00Z ] || fail "a rerun held again keeps the first time: $(cat "$held")"
jq -c 'select(.target != "08")' "$held" >"$tmp/held" && mv "$tmp/held" "$held"
[ "$(code env FORGE_HELD_SINCE=2021-02-03T04:05:06Z "$forge" implement crm/export)" = 0 ] || fail "a held implement under FORGE_HELD_SINCE exits 0: $(cat "$tmp/out")"
[ "$(holds)" = "phase 07,phase 08" ] || fail "FORGE_HELD_SINCE re-adds only the missing record: $(cat "$held")"
[ "$(timed 08)" = 2021-02-03T04:05:06Z ] || fail "FORGE_HELD_SINCE sets the time of a new record: $(cat "$held")"
[ "$(timed 07)" = 2020-01-01T00:00:00Z ] || fail "FORGE_HELD_SINCE leaves an existing record's time: $(cat "$held")"
echo '{"status": "blocked", "summary": "stuck"}' >"$S"/phases/06-export-b/result.json
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 06)" = 0 ] || fail "resume at the cap exits 0: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "resume at the cap starts no session: $(bgs)"
[ "$(holds)" = "phase 07,phase 08,phase 06" ] || fail "resume at the cap records phase 06: $(cat "$held")"
noted "phase 06"
[ "$(jq -sr 'last.step' "$S"/phases/06-export-b/events.jsonl)" = wait ] || fail "resume at the cap still logs its wait event: $(cat "$S"/phases/06-export-b/events.jsonl)"
export FORGE_MAX_SESSIONS=12
rm -f "$held"
mem 3670016
: >"$CLAUDE_LOG"
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "implement short of memory exits 0: $(cat "$tmp/out")"
[ -z "$(bgs)" ] || fail "implement short of memory starts nothing: $(bgs)"
[ "$(holds)" = "phase 06,phase 07,phase 08" ] || fail "a memory hold records the held phase and the later due ones: $(holds)"
noted "phase 06"
mem 16777216

many 1
work 05
jq -n --arg i "$(pid 05)" --argjson q "$foreign" '[{id: $i, name: "p P05 crm/export", state: "done"}, $q]' >"$CLAUDE_AGENTS"
rm -f "$held"
export FORGE_MAX_SESSIONS=1
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with Verify at the cap exits 0: $(cat "$tmp/out")"
[ "$(verifies)" = 0 ] || fail "Verify at the cap starts no session: $(cat "$CLAUDE_LOG")"
[ "$(holds)" = "verify crm/export" ] || fail "Verify at the cap records verify crm/export: $(holds)"
jq -se --arg r "$PWD" 'length == 1 and (.[0] | .root == $r and .kind == "verify" and .target == "crm/export")' "$held" >/dev/null ||
  fail "the Verify record names the project root: $(cat "$held")"
noted "verify crm/export"
rm -f "$held.lock" && mkdir "$held.lock"
[ "$(code "$forge" done 05)" = 0 ] || fail "an unwritable held.jsonl leaves done's exit 0: $(cat "$tmp/out")"
grep -qE "^forge: warning: cannot record the held verify crm/export in $held(\.lock)?$" "$tmp/out" ||
  fail "an unwritable held.jsonl warns naming the held start and the file: $(cat "$tmp/out")"
! grep -q "recorded the held" "$tmp/out" || fail "an unrecorded hold claims no record: $(cat "$tmp/out")"
[ "$(verifies)" = 0 ] || fail "an unwritable held.jsonl starts no Verify at the cap: $(cat "$CLAUDE_LOG")"
rmdir "$held.lock"
export FORGE_MAX_SESSIONS=2
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 05)" = 0 ] || fail "done with room for Verify: $(cat "$tmp/out")"
[ "$(verifies)" = 1 ] || fail "a later done with room starts Verify: $(cat "$CLAUDE_LOG")"
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >"$S"/features/crm-export/verify.json
export FORGE_MAX_SESSIONS=1
: >"$CLAUDE_LOG"
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next with Ship at the cap exits 0: $(cat "$tmp/out")"
[ "$(ships)" = 0 ] || fail "Ship at the cap starts no session: $(cat "$CLAUDE_LOG")"
[ "$(holds)" = "verify crm/export,ship crm/export" ] || fail "Ship at the cap records ship crm/export: $(holds)"
noted "ship crm/export"
[ -f "$S"/features/crm-export/verify.json ] || fail "a held Ship keeps verify.json"
export FORGE_MAX_SESSIONS=12
ok held
fi

mkplan() {
  local d=("$S"/phases/"$1"-*) r=$2
  shift 2
  jq -n --arg r "$r" '{tasks: [{id: "T1", title: "x", files: $ARGS.positional, deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"} + (if $r == "" then {} else {repo: $r} end)]}' --args "$@" >"${d[0]}/plan.json"
  mkdir -p "${d[0]}/tasks" && jq -n '{id: "T1", status: "done"}' >"${d[0]}/tasks/T1.json"
}
evt() { local d=("$S"/phases/"$1"-*); jq -cn --arg t "$(date -u +%FT%TZ)" --arg s "$2" '{time: $t, step: $s, message: "x"}' >>"${d[0]}/events.jsonl"; }
steps() { jq -sr --arg s "$2" 'map(select(.step == $s)) | length' "$S"/phases/"$1"-*/events.jsonl; }
if want overlap; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api", "ui", "cli", "sync", "docs") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
git add -A && git commit -q -m init
export FORGE_CONCURRENCY=4
"$forge" implement crm/export >/dev/null
idle 05 06 07 08 09 10
head=$(git rev-parse HEAD)
mkplan 05 "" src/a.ts src/d.ts
[ "$(code "$forge" check 05)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a plan with no overlap passes check: $(cat "$tmp/out")"
[ "$(jq -sr 'last.step' "$S"/phases/05-export-core/events.jsonl)" = check ] || fail "check exit 0 logs a check event: $(cat "$S"/phases/05-export-core/events.jsonl)"
mkplan 06 "" src/a.ts src/b.ts
[ "$(code "$forge" check 06)" = 3 ] || fail "an overlap with a checked phase exits 3: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "waits on 05" ] || fail "check names the phase it waits on: $(cat "$tmp/out")"
[ "$(jq -c .depends "$S"/phases/06-export-api/spec.json)" = '["05"]' ] || fail "the overlap adds 05 to depends in spec.json: $(jq -c .depends "$S"/phases/06-export-api/spec.json)"
[ "$(jq -c '.phases[] | select(.slug == "export-api") | .depends' "$S"/features/crm-export/split.json)" = '["export-core"]' ] || fail "the overlap adds export-core to depends in split.json"
[ "$(steps 06 wait)" = 1 ] && jq -se 'map(select(.step == "wait")) | .[0].message | contains("05")' "$S"/phases/06-export-api/events.jsonl >/dev/null || fail "one wait event naming 05: $(cat "$S"/phases/06-export-api/events.jsonl)"
[ "$(steps 06 check)" = 1 ] || fail "check exit 3 logs a check event: $(cat "$S"/phases/06-export-api/events.jsonl)"
[ -z "$("$forge" alloc crm/export)" ] || fail "alloc after an overlap wait replans nothing"
[ -f "$S"/phases/06-export-api/plan.json ] || fail "alloc keeps the waiting plan"
mkplan 07 "" src/b.ts src/a.ts
[ "$(code "$forge" check 07)" = 3 ] && [ "$(cat "$tmp/out")" = "waits on 05, 06" ] || fail "a waiting plan still claims its files: $(cat "$tmp/out")"
[ "$(jq -c '.depends | sort' "$S"/phases/07-export-ui/spec.json)" = '["05","06"]' ] && [ "$(steps 07 wait)" = 2 ] || fail "one depends and wait per overlapping phase"
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
[ "$(bgs)" = "P09,P10" ] || fail "waiting phases free their slots: $(bgs)"
export FORGE_CONCURRENCY=10
mkplan 10 api src/a.ts
[ "$(code "$forge" check 10)" = 0 ] || fail "the same path in another repo causes no wait: $(cat "$tmp/out")"
mkplan 08 "" src/c.ts
[ "$(code "$forge" check 08)" = 0 ] || fail "check 08: $(cat "$tmp/out")"
evt 08 replan
mkplan 09 "" src/c.ts
[ "$(code "$forge" check 09)" = 0 ] || fail "a replanned phase causes no wait: $(cat "$tmp/out")"
evt 09 retry
[ "$(code "$forge" check 08)" = 0 ] || fail "a retried phase causes no wait: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] && git diff --cached --quiet || fail "check commits nothing"
work 05
: >"$CLAUDE_LOG"
"$forge" done 05 >/dev/null
[[ ",$(bgs)," == *",P06,"* ]] || fail "the waiting phase relaunches once 05 is done: $(bgs)"
[[ ",$(bgs)," != *",P07,"* ]] || fail "07 still waits on 06: $(bgs)"
mkplan 09 "" src/d.ts
[ "$(code "$forge" check 09)" = 0 ] || fail "a done phase causes no wait: $(cat "$tmp/out")"
ok overlap
fi

if want overlap-union; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api", "ui", "cli") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
printf 'CHANGELOG.md merge=union\nnotes.md merge=binary\n' >.gitattributes
git add -A && git commit -q -m init
head=$(git rev-parse HEAD)
mkplan 05 "" src/a.ts CHANGELOG.md notes.md
[ "$(code "$forge" check 05)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "05 has no overlap yet: $(cat "$tmp/out")"
mkplan 06 "" CHANGELOG.md
[ "$(code "$forge" check 06)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "sharing only a union-merged file passes check: $(cat "$tmp/out")"
[ "$(jq -c .depends "$S"/phases/06-export-api/spec.json)" = '[]' ] || fail "a union-only overlap adds no depends in spec.json: $(jq -c .depends "$S"/phases/06-export-api/spec.json)"
[ "$(jq -c '.phases[] | select(.slug == "export-api") | .depends' "$S"/features/crm-export/split.json)" = '[]' ] || fail "a union-only overlap adds no depends in split.json"
[ "$(steps 06 wait)" = 0 ] || fail "a union-only overlap logs no wait: $(cat "$S"/phases/06-export-api/events.jsonl)"
mkplan 07 "" CHANGELOG.md src/a.ts
[ "$(code "$forge" check 07)" = 3 ] && [ "$(cat "$tmp/out")" = "waits on 05" ] || fail "a union file plus a normal file waits only on the phase sharing the normal file: $(cat "$tmp/out")"
[ "$(jq -c .depends "$S"/phases/07-export-ui/spec.json)" = '["05"]' ] && [ "$(steps 07 wait)" = 1 ] || fail "one depends and wait for the normal-file overlap: $(cat "$S"/phases/07-export-ui/events.jsonl)"
mkplan 08 "" notes.md
[ "$(code "$forge" check 08)" = 3 ] && [ "$(cat "$tmp/out")" = "waits on 05" ] || fail "a merge driver other than union counts as a normal file: $(cat "$tmp/out")"
export GIT_INDEX_FILE=$tmp/feature-index
git read-tree HEAD
printf 'notes.md merge=union\n' | git hash-object -w --stdin | xargs -I{} git update-index --cacheinfo 100644,{},.gitattributes
git branch forge/crm-export "$(git commit-tree "$(git write-tree)" -p HEAD -m attributes)"
unset GIT_INDEX_FILE
mkplan 06 "" CHANGELOG.md notes.md
[ "$(code "$forge" check 06)" = 3 ] && [ "$(cat "$tmp/out")" = "waits on 05, 07" ] || fail "check reads merge attributes from the feature branch: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] && git diff --cached --quiet || fail "check commits nothing"
ok overlap-union
fi

if want no-cycle; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p "$S"/features/crm-export
jq -n '{phases: [("core", "api") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
git add -A && git commit -q -m init
"$forge" implement crm/export >/dev/null
mkplan 05 "" src/a.ts
[ "$(code "$forge" check 05)" = 0 ] || fail "05 has no overlap yet: $(cat "$tmp/out")"
mkplan 06 "" src/a.ts
[ "$(code "$forge" check 06)" = 3 ] || fail "06 overlaps 05: $(cat "$tmp/out")"
[ "$(jq -c .depends "$S"/phases/06-export-api/spec.json)" = '["05"]' ] || fail "06 depends on 05: $(jq -c .depends "$S"/phases/06-export-api/spec.json)"
mkplan 05 "" src/a.ts src/c.ts
[ "$(code "$forge" check 05)" = 0 ] || fail "05 must not wait on 06, which already depends on 05: $(cat "$tmp/out")"
[ "$(jq -c .depends "$S"/phases/05-export-core/spec.json)" = '[]' ] || fail "check must not make 05 depend on 06, which would cycle with 06's depends on 05: $(jq -c .depends "$S"/phases/05-export-core/spec.json)"
ok no-cycle
fi
if want linked; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
p=$PWD sib=$tmp/lumen
sr="--settings {\"env\":{\"FORGE_ROOT\":\"$p\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}}"
rm -rf "$sib" && repo "$sib"
mkdir -p "$sib/.forge/contracts" && touch "$sib/.forge/contracts/.keep"
alltests "$sib"
git -C "$sib" add -A && git -C "$sib" commit -q -m forge
echo '{"repos": ["../lumen"]}' >.forge/repos.json
mkdir -p "$S"/features/crm-export
echo '{"phases": [{"slug": "export-core", "repo": "lumen", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
git add -A && git commit -q -m init
"$forge" implement crm/export >/dev/null 2>"$tmp/err" || fail "implement of a phase in a linked repo: $(cat "$tmp/err")"
[ "$(git -C "$sib/.claude/worktrees/crm-export" branch --show-current)" = forge/crm-export ] || fail "linked repo feature worktree on forge/crm-export"
[ "$(git -C "$sib/.claude/worktrees/crm-export-05" branch --show-current)" = forge/crm-export-05 ] || fail "linked repo phase worktree on forge/crm-export-05"
[ ! -e .claude/worktrees/crm-export ] && [ ! -e .claude/worktrees/crm-export-05 ] || fail "a linked repo phase makes no worktrees in the project root"
[ "$(last)" = "$sib/.claude/worktrees/crm-export-05 | --bg -n p/lumen P05 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "a linked repo phase session is named <root>/<repo> P<n> <track>/<feature>: $(last)"
[ "$(jq -sr 'map(select(.step == "start")) | last.message' "$S"/phases/05-export-core/events.jsonl)" = "p/lumen P05 crm/export" ] || fail "the linked repo phase start event carries the repo-qualified name: $(cat "$S"/phases/05-export-core/events.jsonl)"
[ ! -e "$sib/.forge/features" ] && [ ! -e "$sib/.forge/phases" ] || fail "no planning state in a linked repo"
echo a >"$sib/.claude/worktrees/crm-export-05/a.txt"
git -C "$sib/.claude/worktrees/crm-export-05" add a.txt && git -C "$sib/.claude/worktrees/crm-export-05" commit -q -m a
echo '{"status": "done", "summary": "core"}' >"$S"/phases/05-export-core/result.json && recorded "$S"/phases/05-export-core
tested "$sib/.claude/worktrees/crm-export-05"
"$forge" done 05 >/dev/null
[ -f "$sib/.claude/worktrees/crm-export/a.txt" ] || fail "done merges the linked repo phase branch"
[ "$(norm "$(last)")" = "$sib/.claude/worktrees/crm-export | --bg -n p/lumen verify crm/export $opts bypassPermissions $sv /forge-verify $p crm/export" ] || fail "a Verify whose first phase is in the linked repo is named <root>/<repo> verify <track>/<feature>: $(last)"
[ "$(jq -sr 'map(select(.step == "start")) | last.message' "$S"/features/crm-export/events.jsonl)" = "p/lumen verify crm/export" ] || fail "the linked repo Verify start event carries the repo-qualified name: $(cat "$S"/features/crm-export/events.jsonl)"
echo '[{"id": "a1", "name": "lumen P05 crm/export"}, {"id": "a2", "name": "p verify crm/export"}, {"id": "a3", "name": "p ship crm/export"}, {"id": "a4", "name": "lumen P05 crm/exporter"}, {"id": "a5", "name": "p P05R1 crm/export"}, {"id": "a6", "name": "lumen crm-export Phase 05 retry 1"}, {"id": "a7", "name": "p crm-export Verify"}, {"id": "a8", "name": "lumen crm-exporter Phase 05"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
"$forge" clean --confirmed crm/export >/dev/null
[ "$(grep -o ' rm .*' "$CLAUDE_LOG" | sort | tr '\n' ,)" = " rm a1, rm a2, rm a5, rm a6, rm a7," ] || fail "clean removes the linked repo sessions, legacy-named ones included: $(cat "$CLAUDE_LOG")"
[ ! -e "$sib/.claude/worktrees/crm-export" ] && [ ! -e "$sib/.claude/worktrees/crm-export-05" ] || fail "clean removes the linked repo worktrees"
[ "$(git -C "$sib" branch --format='%(refname:short)' --list 'forge/*')" = forge/crm-export ] || fail "clean deletes the merged linked repo phase branch"
help=$("$forge" implement --help) || fail "forge implement --help exits 0"
grep -q "repos.json" <<<"$help" || fail "implement help describes linked repos"
ok linked
fi

if want collision; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
p=$PWD sib=$tmp/atlas
rm -rf "$sib" && repo "$sib"
mkdir -p "$sib/.forge/contracts" && touch "$sib/.forge/contracts/.keep"
git -C "$sib" add -A && git -C "$sib" commit -q -m forge
git -C "$sib" branch forge/crm-export
echo '{"repos": ["../atlas"]}' >.forge/repos.json
mkdir -p "$S"/features/crm-export
echo '{"phases": [{"slug": "export-core", "repo": "atlas", "goal": "Core", "spec": [], "requirements": [], "depends": []}, {"slug": "export-api", "goal": "API", "spec": [], "requirements": [], "depends": ["export-core"]}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
git add -A && git commit -q -m init
echo '[{"id": "a1", "name": "atlas P05 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] && grep -qF "already has a live session atlas P05 crm/export" "$tmp/out" || fail "the running-session check comes before the collision check: $(cat "$tmp/out")"
echo '[]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement of a fresh feature whose phase repo already has forge/crm-export must fail: $(cat "$tmp/out")"
grep -q "atlas" "$tmp/out" && grep -q "forge/crm-export" "$tmp/out" || fail "the collision refusal names the repo and the branch: $(cat "$tmp/out")"
[ ! -e "$sib/.claude/worktrees" ] && [ ! -e .claude/worktrees ] || fail "the collision refusal creates no worktree"
[ ! -s "$CLAUDE_LOG" ] || ! grep -q -- " --bg " "$CLAUDE_LOG" || fail "the collision refusal starts no session"
"$forge" resume 05 >/dev/null 2>"$tmp/err" || fail "resume of a crashed first phase skips the collision check: $(cat "$tmp/err")"
[ "$(git -C "$sib/.claude/worktrees/crm-export" branch --show-current)" = forge/crm-export ] || fail "resume uses the existing forge/crm-export"
[ "$(last)" = "$sib/.claude/worktrees/crm-export-05 | --bg -n p/atlas P05 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "resumed linked repo session: $(last)"
help=$("$forge" implement --help) || fail "forge implement --help exits 0"
grep -qi "already" <<<"$help" || fail "implement help describes the collision refusal"
ok collision
fi

if want repo-names; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
p=$PWD sib=$tmp/lumen d5="$S"/phases/05-export-core d6="$S"/phases/06-export-api
rm -rf "$sib" && repo "$sib"
mkdir -p "$sib/.forge/contracts" && touch "$sib/.forge/contracts/.keep"
alltests "$sib"
git -C "$sib" add -A && git -C "$sib" commit -q -m forge
echo '{"repos": ["../lumen"]}' >.forge/repos.json
mkdir -p "$S"/features/crm-export
echo '{"phases": [{"slug": "export-core", "repo": "lumen", "goal": "Core", "spec": [], "requirements": [], "depends": []}, {"slug": "export-api", "goal": "API", "spec": [], "requirements": [], "depends": []}]}' >"$S"/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
git add -A && git commit -q -m init
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null 2>"$tmp/err" || fail "implement of a linked repo phase beside a root phase: $(cat "$tmp/err")"
started_msg() { jq -sr 'map(select(.step == "start")) | last.message // "none"' "$1/events.jsonl"; }
grep -qF -- "$sib/.claude/worktrees/crm-export-05 | --bg -n p/lumen P05 crm/export " "$CLAUDE_LOG" || fail "the linked repo phase starts as p/lumen P05 crm/export: $(cat "$CLAUDE_LOG")"
grep -qF -- "$p/.claude/worktrees/crm-export-06 | --bg -n p P06 crm/export " "$CLAUDE_LOG" || fail "the root phase keeps p P06 crm/export: $(cat "$CLAUDE_LOG")"
! grep -qF -- "--bg -n p/p " "$CLAUDE_LOG" || fail "a root phase gets no /<repo> segment: $(cat "$CLAUDE_LOG")"
[ "$(started_msg $d5)/$(started_msg $d6)" = "p/lumen P05 crm/export/p P06 crm/export" ] || fail "the start events carry the session names: $(cat $d5/events.jsonl $d6/events.jsonl)"
echo '{"time": "2026-10-14T00:00:00Z", "step": "retry", "message": "gap"}' >>$d5/events.jsonl
jq -n '[{id: "z1", name: "p/lumen P05R1 crm/export", state: "done"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
"$forge" resume 05 >/dev/null 2>"$tmp/err" || fail "resume of a retried linked repo phase: $(cat "$tmp/err")"
[ "$(last)" = "$sib/.claude/worktrees/crm-export-05 | --bg -n p/lumen P05R1 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "a retry of the linked repo phase starts as p/lumen P05R1 crm/export: $(last)"
grep -q " | rm z1$" "$CLAUDE_LOG" || fail "the pre-clean removes the finished session of the same repo-qualified name: $(cat "$CLAUDE_LOG")"
[ "$(started_msg $d5)" = "p/lumen P05R1 crm/export" ] || fail "the retry start event carries p/lumen P05R1 crm/export: $(cat $d5/events.jsonl)"
ok repo-names
fi

linkset() {
  fresh
  rm -rf "$tmp/atlas" && repo "$tmp/atlas" && mkdir -p "$tmp/atlas/.forge"
  repo web && mkdir -p web/.forge
  echo '{"repos": ["../atlas"]}' >.forge/repos.json
  mkdir -p "$S"/features/crm-export
  echo "{\"phases\": $1}" >"$S"/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  pr=$PWD br=$(cd "$tmp/atlas" && pwd)
}
ph() { jq -cn --arg slug "$1" --arg repo "$2" --argjson depends "$3" '{$slug} + (if $repo == "" then {} else {$repo} end) + {goal: $slug, spec: [], requirements: [], $depends}'; }
repos_out() { (cd "$tmp" && FORGE_ROOT=$pr "$forge" repos crm/export) >"$tmp/out" 2>&1; }
if want repos; then
linkset "[$(ph export-ui web '["export-core"]'), $(ph export-core atlas '[]')]"
repos_out || fail "forge repos of a producer and a consumer: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf 'atlas %s\nweb %s' "$br" "$pr/web")" ] || fail "the producer repo prints before its consumer despite a higher phase number: $(cat "$tmp/out")"
linkset "[$(ph export-ui web '[]'), $(ph export-docs '' '[]'), $(ph export-form web '[]'), $(ph export-core atlas '[]')]"
repos_out || fail "forge repos of independent repos: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf 'web %s\np %s\nbrain %s' "$pr/web" "$pr" "$br")" ] || fail "independent repos order by their lowest phase number: $(cat "$tmp/out")"
linkset "[$(ph export-core atlas '[]'), $(ph export-docs '' '["export-core"]')]"
repos_out || fail "forge repos of a linked producer and a root consumer: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf 'atlas %s\np %s' "$br" "$pr")" ] || fail "the project root prints last when it consumes a linked repo: $(cat "$tmp/out")"
linkset "[$(ph export-ui web '["export-core"]'), $(ph export-core atlas '[]'), $(ph export-form web '[]')]"
s="$S"/features/crm-export/split.json
jq '(.phases[] | select(.slug == "export-core") | .depends) = ["export-form"]' $s >"$tmp/split" && mv "$tmp/split" $s
jq '.depends = ["07"]' "$S"/phases/06-export-core/spec.json >"$tmp/spec" && mv "$tmp/spec" "$S"/phases/06-export-core/spec.json
st=0; repos_out || st=$?
[ $st = 1 ] || fail "forge repos with a cycle between web and atlas must exit 1, got $st: $(cat "$tmp/out")"
ok repos
fi


bed() {
  fresh
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  echo '[]' >"$CLAUDE_AGENTS"
  mkdir -p "$S"/features/crm-export
  echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >"$S"/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  git add -A && git commit -q -m init
  rm -rf "$tmp/bed-origin.git" && git init -q --bare -b main "$tmp/bed-origin.git"
  git remote add origin "$tmp/bed-origin.git" && git push -q origin main && git fetch -q origin
  "$forge" implement crm/export >/dev/null
  git -C .claude/worktrees/crm-export commit -q --allow-empty -m feature
  echo '[{"id": "a1", "name": "p P05 crm/export"}, {"id": "a4", "name": "p ship crm/export"}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
}
intact() {
  [ -d .claude/worktrees/crm-export ] && [ -d .claude/worktrees/crm-export-05 ] || fail "$1: the worktrees must stay"
  git show-ref -q --verify refs/heads/forge/crm-export-05 || fail "$1: the phase branch must stay"
  ! grep -q ' rm ' "$CLAUDE_LOG" || fail "$1: no session may be removed: $(cat "$CLAUDE_LOG")"
}
cleaned() {
  [ ! -e .claude/worktrees/crm-export ] && [ ! -e .claude/worktrees/crm-export-05 ] || fail "$1: clean removes the worktrees"
  [ "$(git branch --format='%(refname:short)' --list 'forge/*')" = forge/crm-export ] || fail "$1: clean keeps only the feature branch"
  [ "$(grep -o ' rm .*' "$CLAUDE_LOG")" = " rm a1" ] || fail "$1: clean removes the phase session only: $(cat "$CLAUDE_LOG")"
}
if want clean-unlanded; then
bed
s=0; "$forge" clean crm/export >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 3 ] || fail "clean of a feature not in origin/main must remove nothing and exit 3, got $s: $(cat "$tmp/out" "$tmp/err")"
intact "a feature not in origin/main"
[ ! -s "$tmp/out" ] || fail "the refusal prints on stderr only: $(cat "$tmp/out")"
for t in .claude/worktrees/crm-export .claude/worktrees/crm-export-05 forge/crm-export-05 a1 "forge clean --confirmed crm/export"; do
  grep -qF -- "$t" "$tmp/err" || fail "the refusal's stderr names $t: $(cat "$tmp/err")"
done

bed
"$forge" clean --confirmed crm/export >/dev/null || fail "clean --confirmed must succeed"
cleaned "--confirmed"
ok clean-unlanded
fi

if want push; then
fresh
mkdir -p "$tmp/push"
origin=$tmp/push/origin.git repo=$tmp/push/repo
git init -q --bare -b main "$origin"
git clone -q "$origin" "$repo"
git -C "$repo" config user.name forge && git -C "$repo" config user.email forge@example.com
echo base >"$repo/file" && git -C "$repo" add -A && git -C "$repo" commit -q -m base && git -C "$repo" push -q origin main
before=$(git -C "$origin" rev-parse main)

echo one >"$repo/file" && git -C "$repo" add -A && git -C "$repo" commit -q -m one
s=0; (cd "$repo" && "$forge" push) >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "not opted in must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "not opted in must print nothing to stdout: $(cat "$tmp/out")"
[ ! -s "$tmp/err" ] || fail "not opted in must print nothing to stderr: $(cat "$tmp/err")"
[ "$(git -C "$origin" rev-parse main)" = "$before" ] || fail "not opted in must leave origin's main unchanged"

git -C "$repo" config forge.pushMain false
s=0; "$forge" push "$repo" >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "pushMain false must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "pushMain false must print nothing to stdout: $(cat "$tmp/out")"
[ "$(git -C "$origin" rev-parse main)" = "$before" ] || fail "pushMain false must leave origin's main unchanged"

git -C "$repo" config forge.pushMain true
git -C "$repo" checkout -q -b other
echo other >"$repo/file" && git -C "$repo" add -A && git -C "$repo" commit -q -m other
s=0; "$forge" push "$repo" >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "opted in on another branch must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "opted in on another branch must print nothing to stdout: $(cat "$tmp/out")"
[ "$(git -C "$origin" rev-parse main)" = "$before" ] || fail "opted in on another branch must leave origin's main unchanged"
git -C "$repo" checkout -q main

echo two >"$repo/file" && git -C "$repo" add -A && git -C "$repo" commit -q -m two
head=$(git -C "$repo" rev-parse HEAD)
s=0; "$forge" push "$repo" >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "opted in on main must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "a successful push prints nothing to stdout: $(cat "$tmp/out")"
[ ! -s "$tmp/err" ] || fail "a successful push prints nothing to stderr: $(cat "$tmp/err")"
[ "$(git -C "$origin" rev-parse main)" = "$head" ] || fail "a successful push updates origin's main to the clone's"

other=$tmp/push/other
git clone -q "$origin" "$other"
git -C "$other" config user.name forge && git -C "$other" config user.email forge@example.com
echo elsewhere >"$other/file" && git -C "$other" add -A && git -C "$other" commit -q -m elsewhere && git -C "$other" push -q origin main
diverged=$(git -C "$origin" rev-parse main)
echo three >"$repo/file" && git -C "$repo" add -A && git -C "$repo" commit -q -m three
head=$(git -C "$repo" rev-parse main)
s=0; "$forge" push "$repo" >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "a rejected push must still exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "a rejected push prints nothing to stdout: $(cat "$tmp/out")"
grep -qF "forge: warning: pushing main to origin failed in $repo:" "$tmp/err" || fail "a rejected push warns naming the repo: $(cat "$tmp/err")"
grep -qi "rejected\|fetch first\|non-fast-forward" "$tmp/err" || fail "a rejected push's warning carries git's error: $(cat "$tmp/err")"
grep -qxF "forge: origin/main moved and local commits change file outside .forge/; run forge land to retest" "$tmp/err" \
  || fail "a rejected push with a local code commit names the code paths: $(cat "$tmp/err")"
! grep -q "merged it into main" "$tmp/err" || fail "a local code commit must not be merged: $(cat "$tmp/err")"
[ "$(git -C "$repo" rev-parse main)" = "$head" ] || fail "a local code commit leaves main unchanged"
[ "$(git -C "$origin" rev-parse main)" = "$diverged" ] || fail "a rejected push must leave origin's main unchanged"

badrepo=$tmp/push/bad
mkdir -p "$badrepo"
git init -q -b main "$badrepo"
git -C "$badrepo" config user.name forge && git -C "$badrepo" config user.email forge@example.com
git -C "$badrepo" remote add origin "$tmp/push/no-such-remote"
echo x >"$badrepo/file" && git -C "$badrepo" add -A && git -C "$badrepo" commit -q -m x
git -C "$badrepo" config forge.pushMain true
mkdir -p "$tmp/push/noforge"
s=0; (cd "$tmp/push/noforge" && "$forge" push "$badrepo") >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "a push to an unreachable origin must still exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "a push to an unreachable origin prints nothing to stdout: $(cat "$tmp/out")"
grep -qF "forge: warning: pushing main to origin failed in $badrepo:" "$tmp/err" || fail "an unreachable origin warns naming the repo: $(cat "$tmp/err")"

[ "$(code "$forge" push "$repo" "$repo")" = 2 ] || fail "more than one argument must exit 2"
ok push
fi

ident() { git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com; }
hook() { printf '#!/bin/sh\nexit 1\n' >"$1/hooks/pre-receive" && chmod +x "$1/hooks/pre-receive"; }
pair() {
  G=$tmp/rec/$1/origin.git R=$tmp/rec/$1/r O=$tmp/rec/$1/o
  git init -q --bare -b main "$G"
  git clone -q "$G" "$R" && ident "$R"
  mkdir -p "$R/.forge" && echo base >"$R/.forge/NOTES.md" && echo base >"$R/file"
  git -C "$R" add -A && git -C "$R" commit -q -m base && git -C "$R" push -q origin main
  git -C "$R" config forge.pushMain true
  git clone -q "$G" "$O" && ident "$O"
}
mine() { echo "$2" >"$R/$1" && git -C "$R" add -A && git -C "$R" commit -q -m "mine $1"; }
up() { echo "$2" >"$O/$1" && git -C "$O" add -A && git -C "$O" commit -q -m "up $1" && git -C "$O" push -q origin main; }
try() {
  local s=0
  "$forge" push "$R" >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "$1 must exit 0, got $s: $(cat "$tmp/err")"
  [ ! -s "$tmp/out" ] || fail "$1 prints nothing to stdout: $(cat "$tmp/out")"
}
warned() { grep -c "^forge: warning: pushing main to origin failed in $R:\$" "$tmp/err" || true; }
if want push-recover; then
fresh

pair merge
mine .forge/NOTES.md local
up code.txt upstream
was=$(git -C "$R" rev-parse main) theirs=$(git -C "$G" rev-parse main)
try "a recovered push"
m=$(git -C "$R" rev-parse main)
grep -qxF "forge: origin/main moved; merged it into main as $(git -C "$R" rev-parse --short main)" "$tmp/err" \
  || fail "a .forge/-only divergence merges origin/main and says so: $(cat "$tmp/err")"
[ "$(warned)" = 0 ] || fail "a recovered push does not warn: $(cat "$tmp/err")"
[ "$(git -C "$R" rev-list --parents -n1 main)" = "$m $was $theirs" ] || fail "the merge commit has main then origin/main as parents: $(git -C "$R" log --format='%H %P' -n1 main)"
[ "$(git -C "$G" rev-parse main)" = "$m" ] || fail "a recovered push updates origin's main to the merge commit"
[ "$(git -C "$R" diff --name-only "$theirs" "$m")" = .forge/NOTES.md ] || fail "the merge differs from origin/main only under .forge/: $(git -C "$R" diff --name-only "$theirs" "$m")"
[ "$(cat "$R/code.txt")" = upstream ] || fail "the merge updates R's checkout"
[ -z "$(git -C "$R" status --porcelain)" ] || fail "the merge leaves R clean: $(git -C "$R" status --porcelain)"

pair conflict
mine .forge/NOTES.md mine
up .forge/NOTES.md theirs
was=$(git -C "$R" rev-parse main) theirs=$(git -C "$G" rev-parse main)
try "a conflicting .forge/ divergence"
grep -qxF "forge: origin/main conflicts with main in: .forge/NOTES.md; reconcile by hand" "$tmp/err" \
  || fail "a conflicting .forge/ divergence names the path: $(cat "$tmp/err")"
[ "$(warned)" = 1 ] || fail "a conflicting .forge/ divergence still warns: $(cat "$tmp/err")"
! grep -q "merged it into main" "$tmp/err" || fail "a conflict is not merged: $(cat "$tmp/err")"
[ "$(git -C "$R" rev-parse main)" = "$was" ] || fail "a conflict leaves main unchanged"
[ "$(git -C "$G" rev-parse main)" = "$theirs" ] || fail "a conflict leaves origin's main unchanged"
[ "$(cat "$R/.forge/NOTES.md")" = mine ] || fail "a conflict leaves R's checkout unchanged"

pair dirty
mine .forge/NOTES.md local
up file upstream
echo dirty >"$R/file"
was=$(git -C "$R" rev-parse main) theirs=$(git -C "$G" rev-parse main)
try "a divergence over a dirty file"
grep -qxF "forge: origin/main moved; main has local changes to file; commit or move them, then push again" "$tmp/err" \
  || fail "a dirty file the merge changes is named: $(cat "$tmp/err")"
! grep -q "merged it into main" "$tmp/err" || fail "a refused merge is not reported as merged: $(cat "$tmp/err")"
[ "$(git -C "$R" rev-parse main)" = "$was" ] || fail "a refused merge leaves main unchanged"
[ "$(git -C "$G" rev-parse main)" = "$theirs" ] || fail "a refused merge leaves origin's main unchanged"
[ "$(cat "$R/file")" = dirty ] || fail "a refused merge keeps R's local edit"

pair hook
mine .forge/NOTES.md local
hook "$G"
was=$(git -C "$R" rev-parse main) theirs=$(git -C "$G" rev-parse main)
try "a hook rejection"
[ "$(warned)" = 1 ] || fail "a hook rejection warns once: $(cat "$tmp/err")"
grep -q "pre-receive hook declined" "$tmp/err" || fail "a hook rejection carries git's error: $(cat "$tmp/err")"
! grep -q "merged it into main\|origin/main moved\|conflicts with main" "$tmp/err" || fail "a hook rejection is not recovered: $(cat "$tmp/err")"
[ "$(git -C "$R" rev-parse main)" = "$was" ] || fail "a hook rejection leaves main unchanged"
[ "$(git -C "$G" rev-parse main)" = "$theirs" ] || fail "a hook rejection leaves origin's main unchanged"

pair again
mine .forge/NOTES.md local
up code.txt upstream
hook "$G"
theirs=$(git -C "$G" rev-parse main)
try "a second rejection"
grep -qF "forge: origin/main moved; merged it into main as" "$tmp/err" || fail "a second rejection follows the merge: $(cat "$tmp/err")"
[ "$(warned)" = 1 ] || fail "a second rejection warns once: $(cat "$tmp/err")"
grep -q "pre-receive hook declined" "$tmp/err" || fail "a second rejection carries git's error: $(cat "$tmp/err")"
[ "$(git -C "$G" rev-parse main)" = "$theirs" ] || fail "a second rejection leaves origin's main unchanged"

G=$tmp/rec/empty/origin.git R=$tmp/rec/empty/r
git init -q --bare -b main "$G" && hook "$G"
git init -q -b main "$R" && ident "$R" && git -C "$R" remote add origin "$G"
mkdir -p "$R/.forge" && echo x >"$R/.forge/NOTES.md" && git -C "$R" add -A && git -C "$R" commit -q -m x
git -C "$R" config forge.pushMain true
was=$(git -C "$R" rev-parse main)
try "a rejection with no origin/main"
[ "$(warned)" = 1 ] || fail "a rejection with no origin/main warns once: $(cat "$tmp/err")"
! grep -q "merged it into main\|origin/main moved\|conflicts with main" "$tmp/err" || fail "a rejection with no origin/main is not recovered: $(cat "$tmp/err")"
[ "$(git -C "$R" rev-parse main)" = "$was" ] || fail "a rejection with no origin/main leaves main unchanged"
ok push-recover
fi

finish
