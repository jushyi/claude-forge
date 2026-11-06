#!/usr/bin/env bash
set -euo pipefail
export FORGE_UNAME=Linux
. "$(dirname "$0")/../forge-common.sh"
mkdir -p "$tmp/bin"
stub_systemd "$tmp/bin"
export PATH=$tmp/bin:$PATH
claude_home
S=$XDG_STATE_HOME/forge/p

if want session-re; then
re=$(bash -c '. "$1"; printf %s "${forge_session_re:-}"' _ "$root/bin/forge.d/run.sh") || fail "bin/forge.d/run.sh must source cleanly"
[ -n "$re" ] || fail "run.sh defines forge_session_re"
jq -en --arg re "$re" '("proj P12 tr/feat" | test($re)) and ("refactor the parser" | test($re) | not)' >/dev/null || fail "forge_session_re is a jq test() regex matching forge names only: $re"
for n in "proj P12 tr/feat" "proj P12R2 tr/feat" "proj verify tr/feat" "proj ship tr/feat" \
  "proj/sub P5 t/f" "proj/sub P5R2 t/f" "proj/sub verify t/f" "proj/sub ship t/f" \
  "my proj P5 t/f" "my proj/sub P5 t/f" "my proj verify t/f" "my proj/my sub ship t/f" \
  "q crm-intake Phase 10" "q crm-intake Phase 11 retry 1" "q crm-intake Verify" "q crm-intake Ship" \
  "q discuss crm/auth" "q discuss" "q quick fix the login" "q fast bump the version" "q debug login loops" "q new crm app" "q port receipts to Rust"; do
  jq -en --arg re "$re" --arg n "$n" '$n | test($re)' >/dev/null || fail "forge_session_re matches '$n': $re"
done
for n in "refactor the parser" "hello" "proj P12 tr/feat extra" "proj/sub P5 t/f extra" "" \
  "q build crm/auth" "q build" "q audit" "q audit the deps"; do
  jq -en --arg re "$re" --arg n "$n" '$n | test($re) | not' >/dev/null || fail "forge_session_re rejects '$n': $re"
done
[[ $re == *'^([^/]+(/[^/]+)? (P[0-9]+(R[0-9]+)?|verify|ship) [^ /]+/[^ /]+|'* ]] || fail "forge_session_re names the phase, verify and ship root part explicitly as [^/]+(/[^/]+)? : $re"
ok session-re
fi

if want lean; then
rm -rf "$tmp/ln" && mkdir -p "$tmp/ln/bin" "$tmp/ln/w"
cat >"$tmp/ln/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$@" >"$LEAN_LOG"
echo "backgrounded · 0123abcd · x"
EOF
chmod +x "$tmp/ln/bin/claude"
lean='{"env":{"CLAUDE_CODE_FORK_SUBAGENT":"0"},"disableBundledSkills":true,"skillListingBudgetFraction":0.0001,"worktree":{"bgIsolation":"none","baseRef":"head"}}'
lsess() { rm -f "$tmp/ln/log"; PATH=$tmp/ln/bin:$PATH LEAN_LOG=$tmp/ln/log bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; shift; session "$@"' _ "$root" "$@" >/dev/null || fail "session $*: exit $?"; mapfile -t la <"$tmp/ln/log"; }
lset() { local i; for ((i = 0; i < ${#la[@]}; i++)); do [ "${la[$i]}" != --settings ] || { echo "${la[$((i + 1))]}"; return; }; done; echo none; }
same() { jq -e --argjson w "$2" '. == $w' <<<"$1" >/dev/null 2>&1; }
lsess "$tmp/ln/w" "p P05 crm/x" "/forge-phase /r 05" ""
same "$(lset)" "$lean" || fail "a caller that passes no settings launches with the lean settings alone: $(lset) in ${la[*]}"
[ "${la[0]}/${la[1]}/${la[2]}/${la[3]}/${la[$((${#la[@]} - 1))]}" = "$tmp/ln/w/--bg/-n/p P05 crm/x//forge-phase /r 05" ] || fail "the no-settings launch keeps its cwd, name and prompt: ${la[*]}"
caller='{"env":{"FORGE_PORT_OFFSET":"10","FORGE_TEST_DB":"p_test_05","FORGE_ROOT":"/r","FORGE_PHASE":"05","FORGE_EXTRA":"x"}}'
lsess "$tmp/ln/w" "p P05 crm/x" "/forge-phase /r 05" "$caller"
same "$(lset)" '{"env":{"FORGE_PORT_OFFSET":"10","FORGE_TEST_DB":"p_test_05","FORGE_ROOT":"/r","FORGE_PHASE":"05","FORGE_EXTRA":"x","CLAUDE_CODE_FORK_SUBAGENT":"0"},"disableBundledSkills":true,"skillListingBudgetFraction":0.0001,"worktree":{"bgIsolation":"none","baseRef":"head"}}' ||
  fail "the lean keys merge into the caller's settings, every caller env key kept: $(lset)"
lsess "$tmp/ln/w" "p P05 crm/x" "continue" "" "0123abcd-full-id"
[ "${#la[@]}" = 9 ] && [ "${la[0]}/${la[1]}/${la[2]}/${la[3]}/${la[4]}/${la[5]}/${la[6]}/${la[8]}" = "$tmp/ln/w/--bg/--resume/0123abcd-full-id/-n/p P05 crm/x/--settings/continue" ] ||
  fail "a --resume launch is claude --bg --resume <id> -n <name> --settings <lean> <prompt>: ${la[*]}"
same "$(lset)" "$lean" || fail "a --resume launch carries --settings with the lean keys: $(lset)"
ok lean
fi

if want foreground-env; then
rm -rf "$tmp/fg" && mkdir -p "$tmp/fg/bin" "$tmp/fg/w"
cat >"$tmp/fg/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$@" >"$FG_LOG"
echo "backgrounded · 0123abcd · x"
EOF
chmod +x "$tmp/fg/bin/claude"
fsess() {
  local v=$1 i
  shift
  rm -f "$tmp/fg/log"
  if [ "$v" = unset ]; then
    env -u FORGE_FOREGROUND_TASKS PATH="$tmp/fg/bin:$PATH" FG_LOG="$tmp/fg/log" bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; shift; session "$@"' _ "$root" "$@" >/dev/null || fail "session $*: exit $?"
  else
    FORGE_FOREGROUND_TASKS=$v PATH="$tmp/fg/bin:$PATH" FG_LOG="$tmp/fg/log" bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; shift; session "$@"' _ "$root" "$@" >/dev/null || fail "session $*: exit $?"
  fi
  mapfile -t fa <"$tmp/fg/log"
  fs=none
  for ((i = 0; i < ${#fa[@]}; i++)); do [ "${fa[$i]}" != --settings ] || fs=${fa[$((i + 1))]}; done
}
fkey() { jq -r '.env.FORGE_FOREGROUND_TASKS // "none"' <<<"$fs"; }
phase='{"env":{"FORGE_PORT_OFFSET":"10","FORGE_TEST_DB":"p_test_05","FORGE_ROOT":"/r","FORGE_PHASE":"05"}}'
fsess 1 "$tmp/fg/w" "p P05 crm/x" "/forge-phase /r 05" "$phase"
[ "$(fkey)" = 1 ] || fail "a fresh phase launch from a forge process with FORGE_FOREGROUND_TASKS=1 carries it in the --settings env: $fs in ${fa[*]}"
jq -e '.env.FORGE_PHASE == "05" and .env.FORGE_ROOT == "/r" and .env.CLAUDE_CODE_FORK_SUBAGENT == "0" and .disableBundledSkills == true' <<<"$fs" >/dev/null ||
  fail "FORGE_FOREGROUND_TASKS joins the caller's and the lean env keys without dropping any: $fs"
fsess 1 "$tmp/fg/w" "p P05 crm/x" "continue" "" "0123abcd-full-id"
[ "${fa[2]}/${fa[3]}" = "--resume/0123abcd-full-id" ] || fail "the resume launch passes --resume <id>: ${fa[*]}"
[ "$(fkey)" = 1 ] || fail "a --resume launch (the watchdog's, no caller settings) from a forge process with FORGE_FOREGROUND_TASKS=1 carries it in the --settings env: $fs in ${fa[*]}"
fsess unset "$tmp/fg/w" "p P05 crm/x" "/forge-phase /r 05" "$phase"
[ "$(fkey)" = none ] || fail "a fresh phase launch with FORGE_FOREGROUND_TASKS unset carries no FORGE_FOREGROUND_TASKS key: $fs"
fsess unset "$tmp/fg/w" "p P05 crm/x" "continue" "" "0123abcd-full-id"
[ "$(fkey)" = none ] || fail "a --resume launch with FORGE_FOREGROUND_TASKS unset carries no FORGE_FOREGROUND_TASKS key: $fs"
ok foreground-env
fi

if want refused-event; then
rm -rf "$tmp/rf" && mkdir -p "$tmp/rf/bin"
(
  export PATH=$tmp/rf/bin:$PATH CLAUDE_LOG=$tmp/rf/claude.log CLAUDE_AGENTS=$tmp/rf/agents.json NOTIFY_LOG=$tmp/rf/notify.log
  cat >"$tmp/rf/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) [ "$3" != "${CLAUDE_BG_FAIL:-}" ] || exit 1
    printf 'backgrounded · %s · %s\n' "$(printf %s "$3" | md5sum | cut -c1-8)" "$3" ;;
  agents) cat "$CLAUDE_AGENTS" ;;
esac
EOF
  cat >"$tmp/rf/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != -- ] || shift
printf '%s | %s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF
  chmod +x "$tmp/rf/bin/claude" "$tmp/rf/bin/notify-send"
  p=$tmp/rf/p d5=$S/phases/05-export-core fd=$S/features/crm-export held=$XDG_STATE_HOME/forge/held.jsonl
  refusals() { if [ -f "$1/events.jsonl" ]; then jq -sc '[.[] | select(.step == "refused") | .message]' "$1/events.jsonl"; else echo '[]'; fi; }
  project "$p" && cd "$p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  mkdir -p $fd
  jq -n '{phases: [{slug: "export-core", goal: "g", spec: [], requirements: ["EXP-01"], depends: []}]}' >$fd/split.json
  jq -n '{requirements: [{id: "EXP-01", text: "export", done: false}]}' >$fd/requirements.json
  "$forge" alloc crm/export >/dev/null
  printf -- '- All tests: `true`\n' >.forge/TESTING.md
  git add -A && git commit -q -m init
  echo '[]' >"$CLAUDE_AGENTS"
  "$forge" implement crm/export >/dev/null 2>"$tmp/rf/err" || fail "implement starts phase 05: $(cat "$tmp/rf/err")"

  jq -n --arg i "$(printf %s "p P05 crm/export" | md5sum | cut -c1-8)" '[{id: $i, name: "p P05 crm/export", state: "working"}]' >"$CLAUDE_AGENTS"
  : >"$NOTIFY_LOG"
  s=0; "$forge" resume 05 >/dev/null 2>"$tmp/rf/err" || s=$?
  [ "$s" = 8 ] || fail "resume of a phase with a live session exits 8: $s $(cat "$tmp/rf/err")"
  r=$(grep "^forge: phase 05 not started: " "$tmp/rf/err") || fail "the phase refusal prints its line: $(cat "$tmp/rf/err")"
  [ "$(refusals $d5)" = "$(jq -nc --arg m "${r#forge: }" '[$m]')" ] ||
    fail "a non-held phase refusal appends one refused event to the phase dir's events.jsonl with message '<kind> <target> not started: <reason>': $(cat $d5/events.jsonl)"
  [ "$(refusals $fd)" = '[]' ] || fail "a phase refusal logs no refused event in the feature dir: $(cat $fd/events.jsonl)"
  [ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "the refused phase still sends one notification: $(cat "$NOTIFY_LOG")"

  echo '[]' >"$CLAUDE_AGENTS"
  echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >$fd/verify.json
  jq '.requirements += [{id: "EXP-03", text: "csv", done: false}, {id: "EXP-02", text: "pdf", done: false}]' $fd/requirements.json >"$tmp/rf/req" && cp "$tmp/rf/req" $fd/requirements.json
  : >"$NOTIFY_LOG"
  : >"$CLAUDE_LOG"
  m="ship crm/export not started: requirement(s) EXP-03 EXP-02 map to no phase"
  s=0; "$forge" next crm/export >/dev/null 2>"$tmp/rf/err" || s=$?
  [ "$s" = 8 ] || fail "next with unmapped requirements exits 8: $s $(cat "$tmp/rf/err")"
  grep -qxF "forge: $m" "$tmp/rf/err" || fail "the unmapped-requirement refusal prints its line: $(cat "$tmp/rf/err")"
  ! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "the unmapped-requirement refusal starts no Ship: $(cat "$CLAUDE_LOG")"
  [ "$(refusals $fd)" = "$(jq -nc --arg m "$m" '[$m]')" ] ||
    fail "the unmapped-requirement ship refusal appends one refused event with message '$m' to $fd/events.jsonl: $(cat $fd/events.jsonl 2>&1)"
  jq -se 'map(select(.step == "refused")) | length == 1 and (.[0].time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' $fd/events.jsonl >/dev/null ||
    fail "the refused event carries a UTC time: $(cat $fd/events.jsonl)"
  [ "$(cat "$NOTIFY_LOG")" = "forge: launch refused | p ship crm/export: requirement(s) EXP-03 EXP-02 map to no phase" ] ||
    fail "the unmapped-requirement refusal still calls notify once: $(cat "$NOTIFY_LOG")"
  [ "$(refusals $d5)" = "$(jq -nc --arg m "${r#forge: }" '[$m]')" ] || fail "a ship refusal logs nothing in a phase dir: $(cat $d5/events.jsonl)"

  jq '.phases[0].requirements += ["EXP-02", "EXP-03"]' $fd/split.json >"$tmp/rf/split" && cp "$tmp/rf/split" $fd/split.json
  : >"$NOTIFY_LOG"
  s=0; CLAUDE_BG_FAIL="p ship crm/export" "$forge" next crm/export >/dev/null 2>"$tmp/rf/err" || s=$?
  [ "$s" = 8 ] || fail "a held Ship start exits 8: $s $(cat "$tmp/rf/err")"
  grep -q "^forge: ship crm/export not started: claude --bg exited 1" "$tmp/rf/err" || fail "the held Ship start prints its refusal: $(cat "$tmp/rf/err")"
  [ -f "$held" ] && jq -se 'any(.[]; .kind == "ship" and .target == "crm/export")' "$held" >/dev/null || fail "the held Ship start is recorded in held.jsonl: $(cat "$held" 2>&1)"
  [ "$(refusals $fd)" = "$(jq -nc --arg m "$m" '[$m]')" ] || fail "a held refusal logs no refused event: $(cat $fd/events.jsonl)"
  [ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "the held Ship start still sends one notification: $(cat "$NOTIFY_LOG")"
)
rm -rf "$tmp/rf"
ok refused-event
fi

if want offsets; then
rm -rf "$tmp/o" && mkdir -p "$tmp/o/bin"
(
  export PATH=$tmp/o/bin:$PATH CLAUDE_LOG=$tmp/o/claude.log CLAUDE_AGENTS=$tmp/o/agents.json
  cat >"$tmp/o/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) printf 'backgrounded · %s · %s\n' "$(printf %s "$3" | md5sum | cut -c1-8)" "$3" ;;
  agents) cat "$CLAUDE_AGENTS" ;;
esac
EOF
  chmod +x "$tmp/o/bin/claude"
  q=$tmp/o/q qS=$XDG_STATE_HOME/forge/q wS=$XDG_STATE_HOME/forge/web
  rm -rf "$qS" "$wS" && mkdir -p "$q/.forge" "$qS" && echo "$q" >"$qS/root"
  started() { local d=${5:-$qS}; mkdir -p "$d/$1" && jq -cn --arg m "q $2" --arg o "${3:-}" --arg s "${4:-}" '{time: "2026-09-30T00:00:00Z", step: "start", message: $m} + if $o == "" then {} else {offset: ($o | tonumber)} end + if $s == "" then {} else {session: $s} end' >>"$d/$1/events.jsonl"; }
  started phases/05-auth-core "P05R1 crm/auth" 60
  started phases/05-auth-core "P05R1 crm/auth" 10
  started features/crm-auth "verify crm/auth" 30
  started phases/104-auth-ui "crm-auth Phase 104"
  started phases/07-auth-api "P07 crm/auth" 20
  started phases/09-auth-cli "P09 crm/auth" 50
  started phases/11-auth-sib "crm-auth Phase 11 retry 1" 20
  started features/crm-intake "crm-intake Verify" 50
  started phases/13-auth-ren "P13 crm/auth" 110 q13a
  started phases/17-auth-ids "P17 crm/auth" 100 q17a
  started phases/17-auth-ids "P17 crm/auth" 120 q17b
  qs=$(jq -n --arg w "$q/.claude/worktrees" --arg s "$tmp/o/qsib/.claude/worktrees" '[{id: "q1", name: "q P05R1 crm/auth", state: "working", cwd: "\($w)/crm-auth-05"},
    {id: "q2", name: "q verify crm/auth", state: "blocked", cwd: "\($w)/crm-auth"}, {id: "q3", name: "q crm-auth Phase 104", state: "done", cwd: "\($w)/crm-auth-104"},
    {id: "q4", name: "q P07 crm/auth", state: "crashed", cwd: "\($w)/crm-auth-07"}, {id: "q5", name: "q P09 crm/auth", state: "stopped", cwd: "\($w)/crm-auth-09"},
    {id: "q6", name: "q ship crm/auth", state: "working", cwd: $w}, {id: "q7", name: "q crm-auth Phase 11 retry 1", state: "working", cwd: "\($s)/crm-auth-11"},
    {id: "q8", name: "q P12 crm/auth", state: "working"}, {id: "q9", name: "q crm-intake Verify", state: "working", cwd: "\($w)/crm-intake"},
    {id: "q13b", name: "ACME <task-notification>", state: "working", cwd: "\($w)/crm-auth-13"}, {id: "q17a", name: "q P17 crm/auth", state: "working", cwd: "\($w)/crm-auth-17"},
    {id: "qx", name: "ACME <task-notification>", state: "working", cwd: "\($w | rtrimstr("/q/.claude/worktrees"))/elsewhere"}]')
  mkdir -p "$q/.claude/worktrees"/crm-auth{,-05,-104,-07,-09,-13,-17} "$q/.claude/worktrees/crm-intake" "$tmp/o/qsib/.claude/worktrees/crm-auth-11" "$tmp/o/elsewhere"
  live() { local n; for n; do jq -n --arg w "$tmp/o/p/.claude/worktrees" --arg n "$n" --arg i "$(printf %s "p P$n crm/export" | md5sum | cut -c1-8)" '{id: $i, name: "p P\($n) crm/export", state: "done", cwd: "\($w)/crm-export-\($n)"}'; done | jq -s --argjson q "$qs" '. + $q' >"$CLAUDE_AGENTS"; }
  renamed() { local n; for n; do jq --arg n "p $n crm/export" 'map(if .name == $n then .name = "ACME <task-notification>" else . end)' "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.new" && mv "$CLAUDE_AGENTS.new" "$CLAUDE_AGENTS"; done; }
  off() { grep -F -- "--bg -n p $1 crm/export " "$CLAUDE_LOG" | tail -n1 | grep -o -- '--settings [^ ]*' | cut -d' ' -f2- | jq -r ".env.$2 // \"none\""; }
  logged() { jq -sr --arg n "p $2 crm/export" 'map(select(.step == "start" and .message == $n)) | last | .offset // "none"' "$1/events.jsonl"; }
  project "$tmp/o/p" && cd "$tmp/o/p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  mkdir -p $S/features/crm-export
  jq -n '{phases: [{slug: "export-core", goal: "g", spec: [], requirements: [], depends: []}, {slug: "export-api", goal: "g", spec: [], requirements: [], depends: []},
    {slug: "export-ui", goal: "g", spec: [], requirements: [], depends: ["export-core"]}]}' >$S/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  git add -A && git commit -q -m init
  live
  : >"$CLAUDE_LOG"
  st=0; timeout 30 "$forge" implement crm/export >/dev/null 2>"$tmp/o/err" || st=$?
  [ "$st" != 124 ] || fail "offset allocation hangs on a listed forge session without a cwd"
  [ "$st" = 0 ] || fail "implement with other projects' sessions live: $(cat "$tmp/o/err")"
  [ "$(off P05 FORGE_PORT_OFFSET)" = 60 ] || fail "phase 05 takes the lowest multiple of 10 no live session holds (q's P05R1 holds 10 by its last start event, q's legacy-named phase 11 retry in the sibling linked repo qsib 20, q's blocked verify 30, q's legacy phase 104 40, q's legacy-named crm-intake Verify 50; crashed and stopped sessions hold none): $(off P05 FORGE_PORT_OFFSET)"
  [ "$(off P06 FORGE_PORT_OFFSET)" = 70 ] || fail "phase 06 skips the offset given to 05 earlier in the run: $(off P06 FORGE_PORT_OFFSET)"
  [ "$(logged $S/phases/05-export-core P05)/$(logged $S/phases/06-export-api P06)" = 60/70 ] || fail "the start events log the offsets: $(cat $S/phases/0[56]-*/events.jsonl)"
  echo '{"status": "done", "summary": "g"}' >$S/phases/05-export-core/result.json
  live 05 06
  renamed P06
  : >"$CLAUDE_LOG"
  "$forge" implement crm/export >/dev/null 2>"$tmp/o/err" || fail "implement of phase 07: $(cat "$tmp/o/err")"
  [ "$(off P07 FORGE_PORT_OFFSET)" = 80 ] || fail "phase 07 skips the offsets in this project's live start events, phase 06's renamed session holding 70 by its id, and takes 80: $(off P07 FORGE_PORT_OFFSET)"
  [ "$(logged $S/phases/07-export-ui P07)" = 80 ] || fail "phase 07's start event logs 80: $(cat $S/phases/07-export-ui/events.jsonl)"
  echo '{"status": "done", "summary": "g"}' >$S/phases/06-export-api/result.json
  echo '{"status": "done", "summary": "g"}' >$S/phases/07-export-ui/result.json
  live 05 06 07
  renamed P06 P07
  : >"$CLAUDE_LOG"
  "$forge" implement crm/export >/dev/null 2>"$tmp/o/err" || fail "implement of Verify: $(cat "$tmp/o/err")"
  [ "$(off verify FORGE_PORT_OFFSET)" = 90 ] || fail "verify gets the lowest free offset in its settings, the renamed sessions of phases 06 and 07 holding 70 and 80: $(cat "$CLAUDE_LOG")"
  [ "$(off verify FORGE_ROOT)" = "$tmp/o/p" ] || fail "verify keeps FORGE_ROOT: $(cat "$CLAUDE_LOG")"
  [ "$(logged $S/features/crm-export verify)" = 90 ] || fail "Verify logs a start event with its offset in the feature's events.jsonl: $(cat $S/features/crm-export/events.jsonl 2>&1)"
  live 05 06 07
  jq --arg w "$tmp/o/p/.claude/worktrees" --arg i "$(printf %s "p verify crm/export" | md5sum | cut -c1-8)" '. + [{id: $i, name: "ACME <task-notification>", state: "done", cwd: "\($w)/crm-export"}]' "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.new" && mv "$CLAUDE_AGENTS.new" "$CLAUDE_AGENTS"
  renamed P06 P07
  rm $S/phases/07-export-ui/result.json
  : >"$CLAUDE_LOG"
  "$forge" resume 07 >/dev/null 2>"$tmp/o/err" || fail "resume of phase 07: $(cat "$tmp/o/err")"
  [ "$(off P07 FORGE_PORT_OFFSET)" = 110 ] || fail "resumed phase 07 takes 110: the renamed Verify session holds 90 by its id, q's P17 holds 100 by the start event of its id (not 120 by its name), q's renamed session whose id matches no start event holds nothing (not 110), and a renamed session outside any forge worktree holds nothing: $(off P07 FORGE_PORT_OFFSET)"
  started phases/15-auth-web "P15 crm/auth" 10 q15a
  mkdir -p "$q/web/.claude/worktrees/crm-auth-15"
  jq -n --arg c "$q/web/.claude/worktrees/crm-auth-15" '[{id: "q15a", name: "ACME <task-notification>", state: "working", cwd: $c}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  "$forge" resume 07 >/dev/null 2>"$tmp/o/err" || fail "resume of phase 07 beside a child repo's session: $(cat "$tmp/o/err")"
  [ "$(off P07 FORGE_PORT_OFFSET)" = 20 ] || fail "q's renamed session in its child repo web holds 10 by the start event of its id in q's events, so resumed phase 07 takes 20: $(off P07 FORGE_PORT_OFFSET)"
  mkdir -p "$wS" "$q/web/.claude/worktrees/web-api-21" && echo "$q/web" >"$wS/root"
  started phases/21-web-api "P21 web/api" 10 w21a "$wS"
  jq -n --arg c "$q/web/.claude/worktrees/web-api-21" '[{id: "w21a", name: "ACME <task-notification>", state: "working", cwd: $c}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  "$forge" resume 07 >/dev/null 2>"$tmp/o/err" || fail "resume of phase 07 beside a session of the child repo's own phase: $(cat "$tmp/o/err")"
  [ "$(off P07 FORGE_PORT_OFFSET)" = 20 ] || fail "the child repo web's renamed session holds 10 by the start event of its id in web's own state dir, so resumed phase 07 takes 20: $(off P07 FORGE_PORT_OFFSET)"
  started phases/19-auth-lib "P19 crm/auth" 10 q19a
  mkdir -p "$q/web/.claude/worktrees/crm-auth-19"
  jq -n --arg c "$q/web/.claude/worktrees/crm-auth-19" '[{id: "q19a", name: "q/web P19 crm/auth", state: "working", cwd: $c}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  "$forge" resume 07 >/dev/null 2>"$tmp/o/err" || fail "resume of phase 07 beside a repo-qualified session: $(cat "$tmp/o/err")"
  [ "$(off P07 FORGE_PORT_OFFSET)" = 20 ] || fail "q's live session q/web P19 crm/auth resolves to project q through its root part and holds 10 by its start event, so resumed phase 07 takes 20: $(off P07 FORGE_PORT_OFFSET)"
  [ ! -e "$q/.forge/phases" ] && [ ! -e "$q/.forge/features" ] || fail "offset writes nothing under q's .forge: $(ls -A "$q/.forge")"
  for x in o elsewhere qsib .claude crm-auth-11 crm-auth-13 web-api-21; do
    [ ! -e "$XDG_STATE_HOME/forge/$x" ] || fail "offset creates no state dir for the scanned dir $x: $(ls "$XDG_STATE_HOME/forge")"
  done
)
rm -rf "$tmp/o" "$XDG_STATE_HOME/forge/q" "$XDG_STATE_HOME/forge/web"
ok offsets
fi

if want session-id; then
rm -rf "$tmp/s" && mkdir -p "$tmp/s/bin"
(
  export PATH=$tmp/s/bin:$PATH CLAUDE_LOG=$tmp/s/claude.log CLAUDE_AGENTS=$tmp/s/agents.json
  cat >"$tmp/s/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg)
    case $CLAUDE_BG_OUT in
      plain) printf 'backgrounded · %s · %s\n  claude agents             list sessions\n' "$CLAUDE_BG_ID" "$3" ;;
      ansi) printf 'backgrounded · \e[36m%s\e[39m · %s\n\e[2m  claude agents             list sessions\e[22m\n\e[2m  claude attach %s\e[22m\n' "$CLAUDE_BG_ID" "$3" "$CLAUDE_BG_ID" ;;
      cold) printf 'Starting background service…\nbackgrounded · %s · %s\n' "$CLAUDE_BG_ID" "$3" ;;
      none) echo "session started" ;;
    esac
    [ "${CLAUDE_BG_LIST:-1}" = 0 ] || { jq --arg i "$CLAUDE_BG_ID" --arg n "$3" --arg c "$PWD" --argjson s "$(date +%s%3N)" '. + [{id: $i, name: $n, cwd: $c, startedAt: $s, state: "working"}]' \
      "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.new" && mv "$CLAUDE_AGENTS.new" "$CLAUDE_AGENTS"; } ;;
  agents) cat "$CLAUDE_AGENTS" ;;
esac
EOF
  chmod +x "$tmp/s/bin/claude"
  p=$tmp/s/p w5=$tmp/s/p/.claude/worktrees/crm-export-05 d5=$S/phases/05-export-core fd=$S/features/crm-export
  setup() {
    rm -rf "$p" && project "$p" && cd "$p"
    git init -q -b main && git config user.name forge && git config user.email forge@example.com
    mkdir -p $fd
    echo '{"phases": [{"slug": "export-core", "goal": "g", "spec": [], "requirements": [], "depends": []}]}' >$fd/split.json
    "$forge" alloc crm/export >/dev/null
    printf -- '- All tests: `true`\n' >.forge/TESTING.md
    git add -A && git commit -q -m init
    jq -n --argjson d "${1:-[]}" '$d' >"$CLAUDE_AGENTS"
  }
  sid() { jq -sr 'map(select(.step == "start")) | last | if . == null then "no start" else .session // "none" end' "$1/events.jsonl" 2>/dev/null || echo "no events"; }
  decoys=$(jq -n --arg w "$w5" '[{id: "dddd9999", name: "p P05 crm/export", cwd: "/elsewhere/.claude/worktrees/crm-export-05", startedAt: 9999999999999, state: "done"},
    {id: "eeee0000", name: "p P05 crm/export", cwd: $w, startedAt: 1, state: "done"}]')

  setup
  CLAUDE_BG_OUT=plain CLAUDE_BG_ID=1a2b3c4d "$forge" implement crm/export >/dev/null 2>"$tmp/s/err" || fail "implement: $(cat "$tmp/s/err")"
  [ "$(sid $d5)" = 1a2b3c4d ] || fail "the phase start event carries the id after 'backgrounded · ' as session: $(cat $d5/events.jsonl 2>&1)"
  echo a >"$w5/a.txt" && git -C "$w5" add a.txt && git -C "$w5" commit -q -m a
  "$forge" test "$w5" >"$tmp/s/out" 2>&1 || fail "forge test $w5: $(cat "$tmp/s/out")"
  echo '{"status": "done", "summary": "g"}' >$d5/result.json
  echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
  echo '[]' >"$CLAUDE_AGENTS"
  CLAUDE_BG_OUT=ansi CLAUDE_BG_ID=0badc0de "$forge" done 05 >/dev/null 2>"$tmp/s/err" || fail "done 05: $(cat "$tmp/s/err")"
  grep -qF -- "--bg -n p verify crm/export " "$CLAUDE_LOG" || fail "done 05 starts verify: $(cat "$CLAUDE_LOG")"
  [ "$(sid $fd)" = 0badc0de ] || fail "the Verify start event carries the id parsed after stripping ANSI escapes: $(cat $fd/events.jsonl 2>&1)"

  setup
  CLAUDE_BG_OUT=cold CLAUDE_BG_ID=c0ffee05 "$forge" implement crm/export >/dev/null 2>"$tmp/s/err" || fail "implement after a cold start: $(cat "$tmp/s/err")"
  [ "$(sid $d5)" = c0ffee05 ] || fail "a leading 'Starting background service…' line still parses: $(cat $d5/events.jsonl 2>&1)"

  setup "$decoys"
  CLAUDE_BG_OUT=none CLAUDE_BG_ID=f00d0005 "$forge" implement crm/export >/dev/null 2>"$tmp/s/err" || fail "implement without a backgrounded line: $(cat "$tmp/s/err")"
  [ "$(sid $d5)" = f00d0005 ] || fail "with no backgrounded line the newest agents entry with the name, the launch dir and a startedAt at or after the launch gives the id (not one in another cwd or started before): $(cat $d5/events.jsonl 2>&1)"

  setup "$decoys"
  CLAUDE_BG_OUT=none CLAUDE_BG_LIST=0 CLAUDE_BG_ID=f00d0006 "$forge" implement crm/export >/dev/null 2>"$tmp/s/err" || fail "implement with no id anywhere: $(cat "$tmp/s/err")"
  [ "$(sid $d5)" = none ] || fail "with neither a backgrounded line nor a matching agents entry the start is logged without session: $(cat $d5/events.jsonl 2>&1)"
)
rm -rf "$tmp/s"
ok session-id
fi

if want session-match; then
rm -rf "$tmp/m" && mkdir -p "$tmp/m/bin"
(
  export PATH=$tmp/m/bin:$PATH CLAUDE_LOG=$tmp/m/claude.log CLAUDE_AGENTS=$tmp/m/agents.json NOTIFY_LOG=$tmp/m/notify.log
  cat >"$tmp/m/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) printf 'backgrounded · %s · %s\n' "$(printf %s "$3" | md5sum | cut -c1-8)" "$3" ;;
  agents) cat "$CLAUDE_AGENTS" ;;
esac
EOF
  cat >"$tmp/m/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != -- ] || shift
printf '%s | %s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF
  chmod +x "$tmp/m/bin/claude" "$tmp/m/bin/notify-send"
  idof() { printf %s "$1" | md5sum | cut -c1-8; }
  agents() { jq -n '[$ARGS.positional[] | split("|") | {id: .[0], name: .[1], state: .[2]}]' --args "$@" >"$CLAUDE_AGENTS"; }
  bgs() { grep -c -- "--bg -n p $1 crm/export " "$CLAUDE_LOG" || true; }
  sid() { jq -sr 'map(select(.step == "start")) | last | .session // "none"' "$1/events.jsonl"; }
  work() { echo "$1" >"$2/$1.txt" && git -C "$2" add "$1.txt" && git -C "$2" commit -q -m "$1" && "$forge" test "$2" >/dev/null 2>&1 || fail "forge test $2"; }
  p=$tmp/m/p d5=$S/phases/05-export-core d6=$S/phases/06-export-api fd=$S/features/crm-export
  w5=$tmp/m/p/.claude/worktrees/crm-export-05 w6=$tmp/m/p/.claude/worktrees/crm-export-06
  i5=$(idof "p P05 crm/export") i6=$(idof "p P06 crm/export") iv=$(idof "p verify crm/export") acme="ACME <task-notification>"
  project "$p" && cd "$p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  mkdir -p $fd
  jq -n '{phases: [{slug: "export-core", goal: "g", spec: [], requirements: [], depends: []}, {slug: "export-api", goal: "g", spec: [], requirements: [], depends: []}]}' >$fd/split.json
  "$forge" alloc crm/export >/dev/null
  printf -- '- All tests: `true`\n' >.forge/TESTING.md
  git add -A && git commit -q -m init
  agents
  : >"$CLAUDE_LOG"
  "$forge" implement crm/export >/dev/null 2>"$tmp/m/err" || fail "implement: $(cat "$tmp/m/err")"
  [ "$(sid $d5)/$(sid $d6)" = "$i5/$i6" ] || fail "both phase start events carry their session ids: $(cat $d5/events.jsonl $d6/events.jsonl)"

  agents "$i5|$acme|working"
  : >"$CLAUDE_LOG"
  [ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement refuses while phase 05's session, renamed after launch, is live: $(cat "$tmp/out")"
  [ "$(bgs P05)" = 0 ] || fail "a refused implement starts no second phase 05 session: $(cat "$CLAUDE_LOG")"
  [ "$(code "$forge" resume 05)" != 0 ] || fail "resume refuses a phase whose renamed session is live: $(cat "$tmp/out")"
  [ "$(bgs P05)" = 0 ] || fail "a refused resume starts no second phase 05 session: $(cat "$CLAUDE_LOG")"

  work 6 "$w6"
  echo '{"status": "done", "summary": "g"}' >$d6/result.json
  echo '{"findings": []}' >$d6/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d6/verify.json
  for st in working blocked; do
    agents "$i5|$acme|$st" "$i6|p P06 crm/export|done"
    : >"$CLAUDE_LOG"
    "$forge" done 06 >/dev/null 2>"$tmp/m/err" || fail "done 06 beside a renamed $st phase 05 session: $(cat "$tmp/m/err")"
    ! grep -q "is gone" "$tmp/m/err" || fail "a renamed $st phase 05 session is matched by its id, not gone: $(cat "$tmp/m/err")"
    [ "$(bgs P05)" = 0 ] || fail "a renamed $st phase 05 session is not relaunched: $(cat "$CLAUDE_LOG")"
  done

  jq -c 'del(.session)' $d5/events.jsonl >$d5/events.new && mv $d5/events.new $d5/events.jsonl
  agents "x5|p P05 crm/export|working" "$i6|p P06 crm/export|done"
  : >"$CLAUDE_LOG"
  "$forge" done 06 >/dev/null 2>"$tmp/m/err" || fail "done 06 beside a legacy phase 05 start: $(cat "$tmp/m/err")"
  ! grep -q "is gone" "$tmp/m/err" && [ "$(bgs P05)" = 0 ] || fail "a start event without session still matches its live session by name: $(cat "$tmp/m/err" "$CLAUDE_LOG")"

  work 5 "$w5"
  echo '{"status": "done", "summary": "g"}' >$d5/result.json
  echo '{"findings": []}' >$d5/review.json && echo '{"command": "true", "passed": true, "criteria": []}' >$d5/verify.json
  agents
  : >"$CLAUDE_LOG"
  "$forge" done 05 >/dev/null 2>"$tmp/m/err" || fail "done 05: $(cat "$tmp/m/err")"
  [ "$(bgs verify)" = 1 ] && [ "$(sid $fd)" = "$iv" ] || fail "done 05 starts Verify and logs its session id: $(cat "$CLAUDE_LOG" $fd/events.jsonl)"
  agents "$i5|p P05 crm/export|done" "$i6|p P06 crm/export|done" "$iv|$acme|working"
  : >"$CLAUDE_LOG"
  : >"$NOTIFY_LOG"
  s=0; "$forge" done 05 >/dev/null 2>"$tmp/m/err" || s=$?
  [ "$s" = 8 ] || fail "a rerun done 05 beside a renamed live Verify session exits 8: $s $(cat "$tmp/m/err")"
  [ "$(bgs verify)" = 0 ] || fail "a renamed live Verify session starts no second Verify: $(cat "$CLAUDE_LOG")"
  grep -q "^forge: verify crm/export not started: .*already has a live session" "$tmp/m/err" || fail "the rerun says Verify is live: $(cat "$tmp/m/err")"
  [ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "the refused Verify sends one notification: $(cat "$NOTIFY_LOG")"
  [ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement refuses while the renamed Verify session is live: $(cat "$tmp/out")"
  [ "$(bgs verify)" = 0 ] || fail "a refused implement starts no second Verify: $(cat "$CLAUDE_LOG")"
)
rm -rf "$tmp/m"
ok session-match
fi

"$forge" --help >"$tmp/help"
stub_run_claude

if want discuss; then
rm -rf "$tmp/d" && mkdir -p "$tmp/d/bin"
(
  p=$tmp/d/p
  project "$p" && cd "$p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  git add -A && git commit -q -m init
  echo '[]' >"$CLAUDE_AGENTS"
  bgs() { grep -c -- " --bg " "$CLAUDE_LOG" || true; }
  : >"$CLAUDE_LOG"
  for a in "" "crm/intake crm/routing"; do
    [ "$(code "$forge" discuss $a)" = 2 ] && ! grep -q "unknown command" "$tmp/out" || fail "discuss with args '$a' fails with usage: $(cat "$tmp/out")"
  done
  [ "$(code "$forge" discuss crm)" = 2 ] && grep -qF "expected <track>/<feature>, got 'crm'" "$tmp/out" || fail "discuss with a malformed argument fails like implement: $(cat "$tmp/out")"
  [ "$(code "$forge" discuss crm/export)" = 1 ] && grep -qF "features/crm-export/requirements.json" "$tmp/out" || fail "discuss of a feature without requirements.json fails naming it: $(cat "$tmp/out")"
  [ "$(code "$forge" discuss crm/routing)" = 1 ] && grep -qxF "forge: crm/routing waits on unshipped features" "$tmp/out" || fail "discuss of a feature with unshipped dependencies fails: $(cat "$tmp/out")"
  [ "$(bgs)" = 0 ] || fail "a failed discuss starts no session: $(cat "$CLAUDE_LOG")"
  for st in working blocked; do
    echo "[{\"id\": \"d1\", \"name\": \"p discuss crm/intake\", \"state\": \"$st\"}]" >"$CLAUDE_AGENTS"
    s=0; "$forge" discuss crm/intake >"$tmp/d/out" 2>"$tmp/d/err" || s=$?
    [ "$s" = 0 ] || fail "discuss beside a $st discuss session exits 0: $s $(cat "$tmp/d/err")"
    [ "$(cat "$tmp/d/err")" = "forge: crm/intake already has a live session p discuss crm/intake; not starting another" ] || fail "discuss beside a $st discuss session says so: $(cat "$tmp/d/err")"
    [ "$(bgs)" = 0 ] || fail "discuss beside a $st discuss session starts no second one: $(cat "$CLAUDE_LOG")"
  done
  echo '[{"id": "d1", "name": "p discuss crm/intake", "state": "done"}, {"id": "d2", "name": "p discuss crm/export", "state": "working"}, {"id": "d3", "name": "q discuss crm/intake", "state": "working"}]' >"$CLAUDE_AGENTS"
  flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" sleep 5 & lk=$!
  sleep 0.5
  s=0; timeout 3 "$forge" discuss crm/intake >"$tmp/d/out" 2>"$tmp/d/err" || s=$?
  wait $lk
  [ "$s" = 0 ] || fail "discuss beside a done session, another feature's and another project's live ones, with forge.lock held, starts: $s $(cat "$tmp/d/err")"
  [ "$(bgs)" = 1 ] || fail "discuss starts one session: $(cat "$CLAUDE_LOG")"
  [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$p | --bg -n p discuss crm/intake --model opus --effort medium --permission-mode bypassPermissions --settings {\"env\":{\"FORGE_ROOT\":\"$p\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}} /forge-discuss crm/intake" ] ||
    fail "discuss session at the root with its name, prompt and FORGE_ROOT settings: $(cat "$CLAUDE_LOG")"
  grep -qF "backgrounded · $(printf %s "p discuss crm/intake" | md5sum | cut -c1-8) · p discuss crm/intake" "$tmp/d/out" || fail "discuss prints claude --bg's output: $(cat "$tmp/d/out")"
  : >"$CLAUDE_LOG"
  : >"$tmp/d/stdin"
  CLAUDE_STDIN=$tmp/d/stdin "$forge" discuss crm/intake <<<$'junk one\njunk two' >"$tmp/d/out" 2>"$tmp/d/err" || fail "discuss with lines on stdin: $(cat "$tmp/d/err")"
  [ "$(bgs)" = 1 ] || fail "discuss with lines on stdin starts one session: $(cat "$CLAUDE_LOG")"
  [ ! -s "$tmp/d/stdin" ] || fail "discuss's claude --bg reads its stdin from /dev/null, not the caller's: $(cat "$tmp/d/stdin")"
  printf '#!/usr/bin/env bash\n[ "$1" != --bg ] || exit 1\nexec "%s" "$@"\n' "$tmp/bin/claude" >"$tmp/d/bin/claude" && chmod +x "$tmp/d/bin/claude"
  echo '[]' >"$CLAUDE_AGENTS"
  s=0; PATH=$tmp/d/bin:$PATH "$forge" discuss crm/intake >"$tmp/d/out" 2>"$tmp/d/err" || s=$?
  [ "$s" != 0 ] && grep -qF "p discuss crm/intake" "$tmp/d/err" || fail "a claude --bg failure fails naming the session: $s $(cat "$tmp/d/err")"
)
rm -rf "$tmp/d"
ok discuss
fi

if want discuss-auto; then
rm -rf "$tmp/da" && mkdir -p "$tmp/da/bin" "$tmp/da/proc"
(
  p=$tmp/da/p
  project "$p" && cd "$p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  git add -A && git commit -q -m init
  bgs() { grep -c -- " --bg " "$CLAUDE_LOG" || true; }
  want() { printf '%s | --bg -n p discuss %s --model opus --effort medium --permission-mode bypassPermissions --settings {"env":{"FORGE_ROOT":"%s","CLAUDE_CODE_FORK_SUBAGENT":"0"},"disableBundledSkills":true,"skillListingBudgetFraction":0.0001,"worktree":{"bgIsolation":"none","baseRef":"head"}} /forge-discuss %s\n' "$p" "$1" "$p" "$2"; }
  run() { s=0; "$@" >"$tmp/da/out" 2>"$tmp/da/err" || s=$?; }
  echo '[]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  [ "$(code "$forge" discuss --auto)" != 0 ] || fail "discuss --auto without a feature fails: $(cat "$tmp/out")"
  [ "$(code "$forge" discuss --auto crm/intake crm)" != 0 ] && grep -qF "expected <track>/<feature>, got 'crm'" "$tmp/out" ||
    fail "discuss --auto with a malformed second argument fails naming it: $(cat "$tmp/out")"
  [ "$(code "$forge" discuss --auto crm/intake crm/export)" = 1 ] && grep -qF "features/crm-export/requirements.json" "$tmp/out" ||
    fail "discuss --auto with a second feature lacking requirements.json exits 1 naming it: $(cat "$tmp/out")"
  [ "$(code "$forge" discuss --auto crm/intake crm/routing)" = 1 ] && grep -qxF "forge: crm/routing waits on unshipped features" "$tmp/out" ||
    fail "discuss --auto with a second feature waiting on unshipped ones exits 1 naming it: $(cat "$tmp/out")"
  [ "$(bgs)" = 0 ] || fail "a failed check on any listed feature starts no session, not even the first: $(cat "$CLAUDE_LOG")"

  mkdir -p $S/features/voice-capture $S/features/crm-export
  cp $S/features/crm-intake/requirements.json $S/features/crm-export/requirements.json
  cp $S/features/crm-intake/requirements.json $S/features/voice-capture/requirements.json
  flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" sleep 5 & lk=$!
  sleep 0.5
  s=0; timeout 3 "$forge" discuss --auto crm/intake crm/export >"$tmp/da/out" 2>"$tmp/da/err" || s=$?
  wait $lk
  [ "$s" = 0 ] || fail "discuss --auto of two ready features, with forge.lock held, starts: $s $(cat "$tmp/da/err")"
  [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/intake "--auto crm/intake"; want crm/export "--auto crm/export")" ] ||
    fail "discuss --auto starts one session per feature in order, titled like plain discuss, at the root with the --auto prompt and FORGE_ROOT settings: $(cat "$CLAUDE_LOG")"
  for x in crm/intake crm/export; do
    grep -qF "backgrounded · $(printf %s "p discuss $x" | md5sum | cut -c1-8) · p discuss $x" "$tmp/da/out" || fail "discuss --auto prints claude --bg's output for $x: $(cat "$tmp/da/out")"
  done

  for st in working blocked; do
    echo "[{\"id\": \"d1\", \"name\": \"p discuss crm/intake\", \"state\": \"$st\"}]" >"$CLAUDE_AGENTS"
    : >"$CLAUDE_LOG"
    run "$forge" discuss --auto crm/intake crm/export
    [ "$s" = 0 ] || fail "discuss --auto beside a $st discuss session of the first feature exits 0: $s $(cat "$tmp/da/err")"
    grep -qxF "forge: crm/intake already has a live session p discuss crm/intake; not starting another" "$tmp/da/err" ||
      fail "discuss --auto beside a $st discuss session says so: $(cat "$tmp/da/err")"
    [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/export "--auto crm/export")" ] ||
      fail "discuss --auto skips the $st feature and starts the next: $(cat "$CLAUDE_LOG")"
  done

  echo '[]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  run env FORGE_MAX_SESSIONS=1 "$forge" discuss --auto crm/intake crm/export voice/capture
  [ "$s" = 0 ] || fail "a discuss --auto held at FORGE_MAX_SESSIONS exits 0: $s $(cat "$tmp/da/err")"
  grep -qxF "forge: 1 forge sessions live; crm/export discuss waits for a free session" "$tmp/da/err" ||
    fail "the second feature waits for a free session, counting the first one started: $(cat "$tmp/da/err")"
  [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/intake "--auto crm/intake")" ] ||
    fail "a hold at FORGE_MAX_SESSIONS starts no later feature: $(cat "$CLAUDE_LOG")"

  for n in "p discuss voice/capture" "p voice-capture discuss" "q discuss voice/capture" "p discuss"; do
    echo "[{\"id\": \"b1\", \"name\": \"$n\", \"state\": \"blocked\"}]" >"$CLAUDE_AGENTS"
    : >"$CLAUDE_LOG"
    run env FORGE_MAX_SESSIONS=1 "$forge" discuss --auto crm/intake crm/export
    [ "$s" = 0 ] || fail "a discuss --auto held by a blocked discuss session $n exits 0: $s $(cat "$tmp/da/err")"
    grep -qxF "forge: 1 forge sessions live; crm/intake discuss waits for a free session" "$tmp/da/err" ||
      fail "discuss --auto counts a blocked discuss session $n toward FORGE_MAX_SESSIONS: $(cat "$tmp/da/err")"
    [ "$(bgs)" = 0 ] || fail "a discuss --auto held by a blocked discuss session $n starts nothing: $(cat "$CLAUDE_LOG")"
  done
  echo '[{"id": "b1", "name": "p P05 crm/export", "state": "blocked"}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  run env FORGE_MAX_SESSIONS=1 "$forge" discuss --auto crm/intake crm/export
  [ "$s" = 0 ] && grep -qxF "forge: 1 forge sessions live; crm/export discuss waits for a free session" "$tmp/da/err" ||
    fail "a blocked phase session does not count toward a discuss --auto start: $s $(cat "$tmp/da/err")"
  [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/intake "--auto crm/intake")" ] ||
    fail "discuss --auto beside a blocked phase session starts the first feature: $(cat "$CLAUDE_LOG")"

  mi=$tmp/da/proc/meminfo
  printf 'MemTotal: 33554432 kB\nMemAvailable: 4718592 kB\n' >"$mi"
  : >"$CLAUDE_LOG"
  run env FORGE_PROC_ROOT="$tmp/da/proc" "$forge" discuss --auto crm/intake crm/export voice/capture
  [ "$s" = 0 ] || fail "a discuss --auto held for memory exits 0: $s $(cat "$tmp/da/err")"
  grep -qxF "forge: MemAvailable 4.5 GiB; crm/export discuss waits for memory" "$tmp/da/err" ||
    fail "the second feature waits for memory, counting the first one started: $(cat "$tmp/da/err")"
  [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/intake "--auto crm/intake")" ] ||
    fail "a hold for memory starts no later feature: $(cat "$CLAUDE_LOG")"

  echo '[{"id": "x1", "name": "p P05 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
  run env FORGE_MAX_SESSIONS=1 "$forge" discuss crm/intake
  [ "$s" = 0 ] && [ "$(grep -F -- " --bg " "$CLAUDE_LOG")" = "$(want crm/intake crm/intake)" ] ||
    fail "plain discuss keeps its prompt and never goes through room: $s $(cat "$tmp/da/err" "$CLAUDE_LOG")"
  [ "$(code "$forge" discuss crm/intake crm/export)" = 2 ] || fail "plain discuss still takes one feature: $(cat "$tmp/out")"

  printf '#!/usr/bin/env bash\n[ "$1" != --bg ] || exit 1\nexec "%s" "$@"\n' "$tmp/bin/claude" >"$tmp/da/bin/claude" && chmod +x "$tmp/da/bin/claude"
  echo '[]' >"$CLAUDE_AGENTS"
  run env PATH="$tmp/da/bin:$PATH" "$forge" discuss --auto crm/intake crm/export
  [ "$s" = 1 ] && grep -qF "p discuss crm/intake" "$tmp/da/err" || fail "a claude --bg failure under --auto exits 1 naming the session: $s $(cat "$tmp/da/err")"
)
rm -rf "$tmp/da"
ok discuss-auto
fi

if want launch; then
rm -rf "$tmp/l" && mkdir -p "$tmp/l/bin"
(
  p=$tmp/l/p
  mk() {
    cd "$tmp/l" && rm -rf "$p" && project "$p" && cd "$p"
    git init -q -b main && git config user.name forge && git config user.email forge@example.com
    "$forge" alloc crm/intake >/dev/null
    rm $S/phases/02-intake-form/result.json
    mkdir -p $S/features/crm-export
    cp $S/features/crm-intake/requirements.json $S/features/crm-export/requirements.json
    git add -A && git commit -q -m init
    echo '[]' >"$CLAUDE_AGENTS"
    : >"$CLAUDE_LOG"
  }
  run() { s=0; "$@" >"$tmp/l/out" 2>"$tmp/l/err" || s=$?; }
  bgs() { grep -F -- " --bg " "$CLAUDE_LOG" | sed -E 's/^(.*) \| --bg -n (.*) --model .* --settings [^ ]+ (.*)$/\1 | \2 | \3/' || true; }
  p02="$p/.claude/worktrees/crm-intake-02 | p P02 crm/intake | /forge-phase $p 02"
  p03="$p/.claude/worktrees/crm-intake-03 | p P03 crm/intake | /forge-phase $p 03"
  dx="$p | p discuss crm/export | /forge-discuss crm/export"
  live() { printf '%s\n' "forge: $1 already has a live session $2; not starting another"; }

  mk
  for a in "" "crm voice" "--bogus crm"; do
    [ "$(code "$forge" launch $a)" = 2 ] && ! grep -q "unknown command" "$tmp/out" || fail "launch with args '$a' fails with usage: $(cat "$tmp/out")"
  done
  for x in nope old; do
    [ "$(code "$forge" launch $x)" = 1 ] && grep -qE "(^|[^a-z])$x([^a-z]|$)" "$tmp/out" && ! grep -q "unknown command" "$tmp/out" || fail "launch of the unknown or closed track $x exits 1 naming it: $(cat "$tmp/out")"
  done
  [ -z "$(bgs)" ] || fail "a refused launch starts no session: $(cat "$CLAUDE_LOG")"

  run "$forge" launch crm
  [ "$s" = 0 ] || fail "launch crm exits 0: $s $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$(printf '%s\n' "$p02" "$dx")" ] ||
    fail "launch crm implements the discussed crm/intake, starting its due phase, then discusses the todo crm/export with the plain prompt, in track order, and starts nothing for crm/routing or crm/audit: $(cat "$CLAUDE_LOG")"
  for x in crm/routing crm/audit; do
    grep -qF "forge: $x waits on unshipped features" "$tmp/l/err" || fail "launch says $x waits on unshipped features: $(cat "$tmp/l/err")"
  done
  ! grep -qE "forge: crm/(intake|export) waits" "$tmp/l/err" || fail "launch reports no wait for a ready feature: $(cat "$tmp/l/err")"

  mk
  run "$forge" launch --auto crm
  [ "$s" = 0 ] || fail "launch --auto crm exits 0: $s $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$(printf '%s\n' "$p02" "$p | p discuss crm/export | /forge-discuss --auto crm/export")" ] ||
    fail "launch --auto passes --auto to discuss: $(cat "$CLAUDE_LOG")"

  for c in "working|p discuss crm/export|crm/export|$p02" "blocked|p crm-export discuss|crm/export|$p02" "blocked|p P02 crm/intake|crm/intake|$dx" \
    "working|p crm-intake Phase 03|crm/intake|$dx" "working|p ship crm/intake|crm/intake|$dx" "blocked|p verify crm/intake|crm/intake|$dx"; do
    IFS='|' read -r st n x want <<<"$c"
    mk
    jq -n --arg n "$n" --arg s "$st" '[{id: "l1", name: $n, state: $s}, {id: "l2", name: "q discuss crm/intake", state: "working"}, {id: "l3", name: "p discuss crm/intake", state: "done"}]' >"$CLAUDE_AGENTS"
    run "$forge" launch crm
    [ "$s" = 0 ] || fail "launch beside a $st session $n exits 0: $s $(cat "$tmp/l/err")"
    grep -qxF "$(live "$x" "$n")" "$tmp/l/err" || fail "launch beside a $st session $n skips $x with the live-session line: $(cat "$tmp/l/err")"
    [ "$(bgs)" = "$want" ] || fail "launch beside a $st session $n starts only the other feature: $(cat "$CLAUDE_LOG")"
  done

  mk
  jq -nc '{time: "2026-09-30T00:00:00Z", step: "start", message: "p P02 crm/intake", session: "s0000002"}' >>$S/phases/02-intake-form/events.jsonl
  echo '[{"id": "s0000002", "name": "ACME <task-notification>", "state": "working"}]' >"$CLAUDE_AGENTS"
  run "$forge" launch crm
  [ "$s" = 0 ] && grep -qxF "$(live crm/intake "ACME <task-notification>")" "$tmp/l/err" ||
    fail "launch finds a renamed live phase session by its start-event id and skips its feature: $s $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$dx" ] || fail "launch beside a renamed live phase session starts only crm/export: $(cat "$CLAUDE_LOG")"

  mk
  echo '{"result": "pass", "gaps": []}' >$S/features/crm-intake/verify.json
  run "$forge" launch crm
  [ "$s" = 0 ] || fail "launch with crm/intake at ship exits 0: $s $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$(printf '%s\n' "$p | p ship crm/intake | /forge-ship $p crm/intake" "$dx")" ] ||
    fail "launch takes a feature with verify.json through next, starting Ship: $(cat "$CLAUDE_LOG")"

  mk
  echo '{"status": "blocked", "summary": "x"}' >$S/phases/03-intake-api/result.json
  run "$forge" launch crm
  [ "$s" = 0 ] || fail "launch with a blocked phase exits 0: $s $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$(printf '%s\n' "$p02" "$p03" "$dx")" ] || fail "launch resumes a blocked phase after implement: $(cat "$CLAUDE_LOG")"
  [ ! -f $S/phases/03-intake-api/result.json ] || fail "the resume of the blocked phase clears its result.json"

  mk
  rm $S/features/crm-export/requirements.json
  run "$forge" launch crm
  [ "$s" = 1 ] || fail "launch with a failing start exits 1: $s $(cat "$tmp/l/err")"
  grep -qE "^forge: crm/export: (forge )?discuss crm/export failed \(exit 1\)$" "$tmp/l/err" || fail "launch reports the failed discuss of crm/export: $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$p02" ] || fail "a failed start of crm/export keeps the start of crm/intake: $(cat "$CLAUDE_LOG")"
  grep -qF "forge: crm/audit waits on unshipped features" "$tmp/l/err" || fail "launch goes on to the features after a failed start: $(cat "$tmp/l/err")"

  mk
  printf '#!/usr/bin/env bash\n[ "$1 $3" != "--bg p P02 crm/intake" ] || exit 1\nexec "%s" "$@"\n' "$tmp/bin/claude" >"$tmp/l/bin/claude" && chmod +x "$tmp/l/bin/claude"
  run env PATH="$tmp/l/bin:$PATH" "$forge" launch crm
  [ "$s" = 0 ] || fail "launch with a held implement start exits 0: $s $(cat "$tmp/l/err")"
  grep -qxF "forge: phase 02 not started: claude --bg exited 1" "$tmp/l/err" || fail "launch reports the held start of phase 02: $(cat "$tmp/l/err")"
  ! grep -qF "failed (exit" "$tmp/l/err" || fail "launch does not count implement's exit 8 as a failure: $(cat "$tmp/l/err")"
  [ "$(bgs)" = "$dx" ] || fail "a failed implement of crm/intake still lets the later crm/export start: $(cat "$CLAUDE_LOG")"
)
rm -rf "$tmp/l"
ok launch
fi

if want reap; then
rm -rf "$tmp/r" && mkdir -p "$tmp/r"
(
  export HOME=$tmp/r/home
  p=$tmp/r/p w=$tmp/r/p/.claude/worktrees
  mkdir -p "$HOME"
  project "$p" && cd "$p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  git init -q -b main "$tmp/r/lib"
  mkdir -p $S/features/crm-export
  echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >$S/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  echo '{"repos": ["../lib"]}' >.forge/repos.json
  echo app >app.txt
  git add -A && git commit -q -m init
  for d in qa qb qc qd qe da db; do git worktree add -q "$w/$d" -b "r-$d"; done
  mkdir -p "$w/da/.forge/features/crm-x" && echo x >"$w/da/.forge/features/crm-x/notes.md" && git -C "$w/da" add .forge/features && git -C "$w/da" commit -q -m notes
  echo new >"$w/qa/untracked.txt"
  echo dirty >>"$w/qb/app.txt"
  echo >>"$w/qc/.forge/tracks/crm.json"
  echo dirty >>"$w/da/.forge/features/crm-x/notes.md"
  echo dirty >>"$w/db/.forge/todo.md"
  for n in 90 91 92 93 94; do mkdir -p "$S/phases/$n-x$n"; done
  jq -n '{track: "crm", feature: "x", number: "90", slug: "x90", goal: "x", spec: [], requirements: [], depends: []}' >$S/phases/90-x90/spec.json
  jq -n '{track: "crm", feature: "x", number: "94", slug: "x94", goal: "x", spec: [], requirements: [], depends: [], repo: "lib"}' >$S/phases/94-x94/spec.json
  echo '{"status": "done", "summary": "x"}' >$S/phases/90-x90/result.json
  echo '{"status": "done", "summary": "x"}' >$S/phases/94-x94/result.json
  echo '{"status": "blocked", "summary": "x"}' >$S/phases/91-x91/result.json
  echo '{"status": "failed", "summary": "x"}' >$S/phases/92-x92/result.json
  sid() { echo "5e55100d-0000-4000-8000-${1}0000"; }
  tx() {
    local d=$HOME/.claude/projects/${1//[^a-zA-Z0-9]/-} s=$2
    shift 2
    mkdir -p "$d"
    { jq -nc '{type: "user", message: {role: "user", content: "go"}}'
      for m in "$@"; do jq -nc --arg t "$m" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {}}, {type: "text", text: $t}]}}'; done
    } >"$d/$(sid "$s").jsonl"
  }
  printf '%s\t%s\t%s\t%s\t%s\n' \
    a0000001 "p P90 crm/x" done background "$w/crm-x-90" \
    a0000002 "p crm-x Phase 90 retry 1" done background "$w/crm-x-90" \
    a0000003 "p P94 crm/x" done background "$tmp/r/lib/.claude/worktrees/crm-x-94" \
    a0000004 "p quick fix the login" done background "$w/qa" \
    a0000005 "p quick tidy forge notes" done background "$w/qc" \
    a0000006 "p debug the export crash" done background "$w/qd" \
    a0000007 "p discuss crm/z" done background "$w/db" \
    a0000008 "p ship crm/auth" done background "$p" \
    a0000009 "p P90R3 crm/x" done background "$w/crm-x-90" \
    a000000a "p quick at the root" done background "$p" \
    a000000b "p/lib P94 crm/x" done background "$tmp/r/lib/.claude/worktrees/crm-x-94" \
    a000000c "p discuss crm/x" done background "$w/da" \
    b0000001 "p P91 crm/x" done background "$w/crm-x-91" \
    b0000002 "p P92 crm/x" done background "$w/crm-x-92" \
    b0000003 "p P93 crm/x" done background "$w/crm-x-93" \
    b0000004 "p P90R4 crm/x" working background "$w/crm-x-90" \
    b0000005 "p P90R5 crm/x" blocked background "$w/crm-x-90" \
    b0000006 "p P90R6 crm/x" stopped background "$w/crm-x-90" \
    b0000007 "p P90R7 crm/x" done interactive "$w/crm-x-90" \
    b0000008 "q P90 crm/x" done background "$tmp/r/q/.claude/worktrees/crm-x-90" \
    b0000009 "p P90R8 crm/x" done background "$tmp/r/pp/.claude/worktrees/crm-x-90" \
    b000000a "p quick fenced result" done background "$w/qe" \
    b000000b "p quick no result" done background "$w/qa" \
    b000000c "p quick earlier result" done background "$w/qa" \
    b000000d "p quick missing transcript" done background "$w/qa" \
    b000000e "p quick dirty tree" done background "$w/qb" \
    b000000f "p quick stopped mid-turn" stopped background "$w/qa" \
    b0000010 "p quick gone worktree" done background "$w/gone" \
    b0000011 "p discuss crm/y" done background "$w/qb" \
    b0000012 "p quick still working" working background "$w/qa" \
    b0000013 "p verify crm/x" done background "$w/crm-x" \
    b0000014 "p quick interactive" done interactive "$w/qa" \
    b0000015 "p P90R9 crm/x" done background "$w/crm-x-90" \
    b0000016 "p P90 crm/y" done background "$tmp/r/lib/.claude/worktrees/crm-y-90" \
    b0000017 "p P90R2 crm/x" done background "$tmp/r/lib/.claude/worktrees/crm-x-90" \
    b0000018 "p P94 crm/x" done background "$w/crm-x-94" |
    jq -Rn '[inputs | split("\t") | {id: .[0], sessionId: ("5e55100d-0000-4000-8000-" + .[0] + "0000"), name: .[1], state: .[2], kind: .[3], cwd: .[4]}
      + if .[2] == "done" then {status: "idle"} else {} end]' >"$CLAUDE_AGENTS"
  tx "$w/qa" a0000004 "Fixed the login." $'Committed it.\nresult: fixed the login'
  tx "$w/qc" a0000005 $'Tidied.\nresult: tidied'
  tx "$w/qd" a0000006 $'Found it.\nresult: fixed the crash'
  tx "$w/db" a0000007 $'Wrote the split.\nresult: split crm/z'
  tx "$p" a000000a $'result: done at the root'
  tx "$w/qe" b000000a $'Here is the format:\n```\nresult: <summary>\n```\nStill going.'
  tx "$w/qa" b000000b "All done, nothing to report."
  tx "$w/qa" b000000c $'result: first pass' "Now reworking the second pass."
  tx "$w/qb" b000000e $'result: fixed but not committed'
  tx "$w/qa" b000000f $'result: fixed'
  tx "$w/gone" b0000010 $'result: fixed'
  tx "$w/da" a000000c $'result: discussed crm/x'
  tx "$w/qb" b0000011 $'result: discussed crm/y'
  tx "$w/qa" b0000012 $'result: fixed'
  tx "$w/qa" b0000014 $'result: fixed'
  jq 'map(if .id == "b0000015" then .state = "working" | del(.status) else . end)' "$CLAUDE_AGENTS" >"$tmp/r/resumed.json"
  mkdir -p "$tmp/r/bin"
  printf '#!/usr/bin/env bash\n[ "$1" != rm ] || [ ! -f "%s" ] || mv "%s" "$CLAUDE_AGENTS"\nexec "%s" "$@"\n' "$tmp/r/resumed.json" "$tmp/r/resumed.json" "$tmp/bin/claude" >"$tmp/r/bin/claude"
  chmod +x "$tmp/r/bin/claude"
  : >"$CLAUDE_LOG"
  st=0
  PATH=$tmp/r/bin:$PATH CLAUDE_RM_FAIL=a0000009 CLAUDE_RM_LOCK=$XDG_RUNTIME_DIR/forge/sessions.lock "$forge" implement crm/export >"$tmp/r/out" 2>&1 || st=$?
  [ "$st" = 0 ] || fail "implement with a failing claude rm still exits 0: $st $(cat "$tmp/r/out")"
  grep -q -- "--bg -n p P05 crm/export " "$CLAUDE_LOG" || fail "implement still launches phase 05 after the reap: $(cat "$CLAUDE_LOG")"
  rmd=$(grep -F " | rm " "$CLAUDE_LOG" | sed 's/.* | rm //' | sort -u | paste -sd ' ')
  [ "$rmd" = "a0000001 a0000002 a0000003 a0000004 a0000005 a0000006 a0000007 a0000008 a0000009 a000000a a000000b a000000c" ] ||
    fail "the reap removes only this project's finished background phase sessions with a done result (read from the state dir's phases) and its done Quick/Debug/Discuss sessions with a result: line and committed work outside .forge/ (a discuss session's own .forge/features/<track>-<feature>/ changes included), plus stale's archived-feature sessions from the state dir's archive, and none resumed since the listing: $rmd $(cat "$tmp/r/out")"
  ! grep -q "^unlocked " "$CLAUDE_LOG" || fail "every removal runs under sessions.lock: $(grep "^unlocked " "$CLAUDE_LOG")"
  log=$p/.git/forge-reaped.log
  [ -f "$log" ] || fail "the reap logs to the git common dir's forge-reaped.log: $(cat "$tmp/r/out")"
  ! grep -qvP '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\t[0-9a-f]{8}\t[^\t]+$' "$log" || fail "each log line is <UTC time>\\t<id>\\t<name>: $(cat "$log")"
  [ "$(cut -f2,3 "$log" | sort -u)" = "$(printf '%s\t%s\n' a0000001 "p P90 crm/x" a0000002 "p crm-x Phase 90 retry 1" a0000003 "p P94 crm/x" \
    a0000004 "p quick fix the login" a0000005 "p quick tidy forge notes" a0000006 "p debug the export crash" a0000007 "p discuss crm/z" \
    a0000008 "p ship crm/auth" a000000a "p quick at the root" a000000b "p/lib P94 crm/x" a000000c "p discuss crm/x")" ] || fail "the log holds one line per successful removal, stale's included, and none for a failed rm: $(cat "$log")"
  for x in "p P90 crm/x (a0000001)" "p crm-x Phase 90 retry 1 (a0000002)" "p quick fix the login (a0000004)" "p discuss crm/z (a0000007)" "p ship crm/auth (a0000008)"; do
    grep -qxF "forge: removed $x" "$tmp/r/out" || fail "each removal prints forge: removed $x: $(cat "$tmp/r/out")"
  done
  ! grep -qF "(a0000009)" "$tmp/r/out" || fail "a failed rm prints no removal: $(cat "$tmp/r/out")"
  grep -qxF "forge: warning: cannot remove session a0000009" "$tmp/r/out" || fail "a failed rm warns: $(cat "$tmp/r/out")"
  grep -qE "warning.*(b000000d|p quick missing transcript)" "$tmp/r/out" || fail "a missing transcript warns: $(cat "$tmp/r/out")"
  grep -qE "warning.*(b0000010|p quick gone worktree)" "$tmp/r/out" || fail "a git failure warns: $(cat "$tmp/r/out")"
)
rm -rf "$tmp/r"
ok reap
fi

alltests() { printf -- '- All tests: `true`\n' >"${1:-.}/.forge/TESTING.md"; }
tested() { "$forge" test "$1" >"$tmp/out" 2>&1 || fail "forge test $1: $(cat "$tmp/out")"; }
pid() { printf %s "p P$1 crm/export" | md5sum | cut -c1-8; }
idle() { local n; for n; do jq -n --arg i "$(pid "$n")" --arg n "$n" '{id: $i, name: "p P\($n) crm/export", state: "done", status: "idle"}'; done | jq -s . >"$CLAUDE_AGENTS"; }
recorded() { echo '{"findings": []}' >"$1/review.json"; echo '{"command": "true", "passed": true, "criteria": []}' >"$1/verify.json"; }
p=$tmp/p fx5=$S/phases/05-export-core fx6=$S/phases/06-export-api
last() { tail -n1 "$CLAUDE_LOG"; }
opts="--model opus --effort medium --permission-mode"
s5="--settings {\"env\":{\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_TEST_DB\":\"p_test_05\",\"FORGE_ROOT\":\"$p\",\"FORGE_PHASE\":\"05\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}}"
s6="--settings {\"env\":{\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_TEST_DB\":\"p_test_06\",\"FORGE_ROOT\":\"$p\",\"FORGE_PHASE\":\"06\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}}"
sr="--settings {\"env\":{\"FORGE_ROOT\":\"$p\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}}"
sv="--settings {\"disableBundledSkills\":true,\"env\":{\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\",\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_ROOT\":\"$p\"},\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"baseRef\":\"head\",\"bgIsolation\":\"none\"}}"
norm() { [[ $1 =~ ^(.*)\ --settings\ (\{[^ ]*\})\ (.*)$ ]] && echo "${BASH_REMATCH[1]} --settings $(jq -cS . <<<"${BASH_REMATCH[2]}") ${BASH_REMATCH[3]}"; }

fresh
if want_any implement done next clean; then
: >"$CLAUDE_LOG"
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p $S/features/crm-export
echo '{"requirements": [{"id": "EXP-01", "text": "Export leads", "done": false}]}' >$S/features/crm-export/requirements.json
echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": ["EXP-01"], "depends": []}, {"slug": "export-api", "goal": "API", "spec": ["Serve JSON."], "requirements": ["EXP-01"], "depends": ["export-core"]}]}' >$S/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
git init -q -b main
git config user.name forge && git config user.email forge@example.com
alltests
echo '{"questions": []}' >$fx6/research.json
git add -A && git commit -q -m init

jq -n '[{id: "o1", name: "p ship crm/auth", state: "done", status: "idle"}, {id: "o2", name: "p P01 crm/auth", state: "stopped"},
  {id: "o3", name: "p verify crm/auth", state: "working"}, {id: "o4", name: "p P02R1 crm/auth", state: "blocked"},
  {id: "o5", name: "p ship crm/routing", state: "done"}, {id: "o6", name: "q ship crm/auth", state: "done"},
  {id: "o7", name: "p crm-auth Phase 03 retry 1", state: "done", status: "idle"}, {id: "o8", name: "p crm-auth Verify", state: "working"},
  {id: "o9", name: "p crm-auth Ship", state: "done"}, {id: "o10", name: "p crm-routing Ship", state: "done"},
  {id: "o11", name: "p/lib P04 crm/auth", state: "done", status: "idle"}, {id: "o12", name: "p/lib verify crm/auth", state: "working"},
  {id: "o13", name: "p/lib P04 crm/routing", state: "done"}, {id: "o14", name: "q/lib P04 crm/auth", state: "done"}]' >"$CLAUDE_AGENTS"
: >"$tmp/stdin"
CLAUDE_STDIN=$tmp/stdin "$forge" implement crm/export <<<$'junk one\njunk two' >/dev/null
[ "$(grep -F "| rm " "$CLAUDE_LOG" | sed 's/.*| rm //' | sort -u | paste -sd ' ')" = "o1 o11 o2 o7 o9" ] || fail "launch removes only the idle sessions of archived features of this project, legacy-named and repo-qualified ones included: $(cat "$CLAUDE_LOG")"
echo '[]' >"$CLAUDE_AGENTS"
[ "$(git -C .claude/worktrees/crm-export branch --show-current)" = forge/crm-export ] || fail "feature worktree on forge/crm-export"
[ "$(git -C .claude/worktrees/crm-export-05 branch --show-current)" = forge/crm-export-05 ] || fail "phase worktree on forge/crm-export-05"
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "phase 05 session: $(last)"
[ "$(grep -c -- " --bg " "$CLAUDE_LOG")" = 1 ] || fail "implement starts one session"
[ ! -s "$tmp/stdin" ] || fail "the phase launch's claude --bg reads its stdin from /dev/null, not the caller's: $(cat "$tmp/stdin")"
[ -z "$(git status --porcelain -- .claude)" ] || fail "implement in a repo not ignoring .claude/worktrees/ leaves no untracked .claude/: $(git status --porcelain)"
starts() { jq -sr 'map(select(.step == "start") | .message) | join(",")' "$1/events.jsonl"; }
[ "$(starts $fx5)" = "p P05 crm/export" ] || fail "launch logs a start event: $(cat $fx5/events.jsonl)"
echo '[{"id": "a1", "name": "p P05 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a working phase session must fail"
echo '[{"id": "a1", "name": "p P05 crm/export", "state": "blocked"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a blocked phase session must fail"
echo '[{"id": "a1", "name": "p verify crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a working verify session must fail"
echo '[{"id": "a1", "name": "p crm-export Phase 05", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a working legacy-named phase session must fail"
echo '[{"id": "a1", "name": "p crm-export Phase 05 retry 2", "state": "blocked"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a blocked legacy-named retry session must fail"
echo '[{"id": "a1", "name": "p crm-export Verify", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] || fail "implement with a working legacy-named verify session must fail"
echo '[{"id": "a1", "name": "p/lib P05 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] && grep -qF "already has a live session p/lib P05 crm/export" "$tmp/out" ||
  fail "implement with a working repo-qualified phase session must refuse: $(cat "$tmp/out")"
[ "$(code "$forge" resume 05)" = 8 ] && grep -qF "phase 05 has a live session p/lib P05 crm/export" "$tmp/out" ||
  fail "resume with a working repo-qualified phase session must refuse: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p/lib P05 crm/export", "state": "blocked"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 1 ] && grep -qF "already has a live session p/lib P05 crm/export" "$tmp/out" ||
  fail "implement with a blocked repo-qualified phase session must refuse: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p P05 crm/export", "state": "done"}, {"id": "a2", "name": "p verify crm/export", "state": "done"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" implement crm/export)" = 0 ] || fail "done sessions must not block implement: $(cat "$tmp/out")"
cp $S/features/crm-export/split.json "$tmp/split.keep"
jq '.phases[1].spec += ["Page it."]' "$tmp/split.keep" >$S/features/crm-export/split.json
echo '[{"id": "a1", "name": "p P05 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" alloc crm/export)" = 1 ] && grep -qF "p P05 crm/export" "$tmp/out" || fail "alloc must refuse while a phase session is live: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p crm-export Phase 05", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" alloc crm/export)" = 1 ] && grep -qF "p crm-export Phase 05" "$tmp/out" || fail "alloc must refuse while a legacy-named phase session is live: $(cat "$tmp/out")"
[ "$(jq -r '.spec[-1]' $fx6/spec.json)" = "Serve JSON." ] || fail "a refused alloc writes no phase spec"
cp "$tmp/split.keep" $S/features/crm-export/split.json
echo '[]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" alloc crm/export)" = 0 ] || fail "alloc runs once no session is live: $(cat "$tmp/out")"
[ "$(code "$forge" implement crm/routing)" = 1 ] || fail "implement waits on unshipped dependencies"
echo phase >.claude/worktrees/crm-export-05/c.txt
git -C .claude/worktrees/crm-export-05 add c.txt && git -C .claude/worktrees/crm-export-05 commit -q -m phase
echo feature >.claude/worktrees/crm-export/c.txt
git -C .claude/worktrees/crm-export add c.txt && git -C .claude/worktrees/crm-export commit -q -m feature
h5=$(git rev-parse forge/crm-export-05)
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 0 ] || fail "launch on a conflicting phase branch must still start the session: $(cat "$tmp/out")"
! git -C .claude/worktrees/crm-export-05 rev-parse -q --verify MERGE_HEAD >/dev/null || fail "launch aborts a conflicting pre-merge"
[ "$(git rev-parse forge/crm-export-05)" = "$h5" ] || fail "an aborted pre-merge leaves forge/crm-export-05 unchanged"
[ -z "$(git -C .claude/worktrees/crm-export-05 status --porcelain)" ] || fail "an aborted pre-merge leaves the phase worktree clean: $(git -C .claude/worktrees/crm-export-05 status --porcelain)"
[ "$(jq -sc '.[-2:] | map({step, message})' $fx5/events.jsonl)" = '[{"step":"sync","message":"conflict merging forge/crm-export into forge/crm-export-05: c.txt"},{"step":"start","message":"p P05 crm/export"}]' ] || fail "launch logs sync, then start: $(cat $fx5/events.jsonl)"
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "phase 05 session after a conflict: $(last)"
ok implement

echo a >.claude/worktrees/crm-export-05/a.txt
git -C .claude/worktrees/crm-export-05 add a.txt && git -C .claude/worktrees/crm-export-05 commit -q -m a
mkdir -p $fx5/tasks
echo '{"id": "T1", "status": "done", "deviation": "renamed the route", "deviation_kind": "interface"}' >$fx5/tasks/T1.json
echo '{"tasks": [{"id": "T1", "title": "x", "requirements": ["EXP-01"], "files": ["b"], "deps": [], "dep_reasons": {}, "test": "exempt", "exempt_reason": "x"}]}' >$fx5/plan.json
echo '{"status": "done", "summary": "core"}' >$fx5/result.json && recorded $fx5
echo '{"files": []}' >$fx6/scout.json
echo '{"tasks": [{"id": "T1", "title": "x", "requirements": ["EXP-01"], "files": ["b"], "deps": [], "dep_reasons": {}, "test": "exempt", "exempt_reason": "x"}]}' >$fx6/plan.json
hm=$(git rev-parse main) hf=$(git rev-parse forge/crm-export)
: >"$CLAUDE_LOG"
tested .claude/worktrees/crm-export-05
[ "$(code "$forge" done 05)" = 6 ] || fail "done on a conflicting phase branch must exit 6: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "forge: forge/crm-export-05 conflicts with forge/crm-export in c.txt; merge forge/crm-export into forge/crm-export-05 and rerun forge done 05" ] || fail "done conflict message: $(cat "$tmp/out")"
! git -C .claude/worktrees/crm-export rev-parse -q --verify MERGE_HEAD >/dev/null || fail "done aborts the conflicting merge"
[ -z "$(git -C .claude/worktrees/crm-export status --porcelain)" ] || fail "an aborted done leaves the feature worktree clean: $(git -C .claude/worktrees/crm-export status --porcelain)"
[ "$(git rev-parse main)" = "$hm" ] && [ "$(git rev-parse forge/crm-export)" = "$hf" ] || fail "an aborted done commits nothing"
[ "$(jq -sc 'last | {step, message}' $fx5/events.jsonl)" = '{"step":"sync","message":"conflict merging forge/crm-export-05 into forge/crm-export: c.txt"}' ] || fail "done logs a sync event: $(cat $fx5/events.jsonl)"
[ -f $fx6/plan.json ] || fail "an aborted done replans nothing"
[ ! -f $fx6/events.jsonl ] || ! jq -e 'select(.step == "replan" or .step == "start")' $fx6/events.jsonl >/dev/null || fail "an aborted done logs no replan or start: $(cat $fx6/events.jsonl)"
! grep -q -- " --bg " "$CLAUDE_LOG" || fail "an aborted done starts no session: $(cat "$CLAUDE_LOG")"
! git -C .claude/worktrees/crm-export-05 merge -q forge/crm-export >/dev/null 2>&1 || fail "the phase branch must conflict with forge/crm-export"
echo both >.claude/worktrees/crm-export-05/c.txt
git -C .claude/worktrees/crm-export-05 add c.txt && git -C .claude/worktrees/crm-export-05 commit -q --no-edit
tested .claude/worktrees/crm-export-05
FORGE_PERMISSION_MODE=acceptEdits "$forge" done 05 >"$tmp/done.out"
[ -f .claude/worktrees/crm-export/a.txt ] || fail "done merges the phase branch into forge/crm-export"
[ ! -e $fx6/plan.json ] && [ -f $fx6/scout.json ] || fail "a deviation replans dependents with a plan"
[ "$(jq -sr 'map(.step) | join(",")' $fx6/events.jsonl)" = replan,start ] || fail "replan event, then start: $(cat $fx6/events.jsonl)"
[ -f .claude/worktrees/crm-export-06/a.txt ] || fail "phase 06 branches from the merged feature branch"
[ "$(last)" = "$p/.claude/worktrees/crm-export-06 | --bg -n p P06 crm/export $opts acceptEdits $s6 /forge-phase $p 06" ] || fail "phase 06 session: $(last)"
grep -qxF "forge: recorded 05 done" "$tmp/done.out" && [ "$(git rev-parse main)" = "$hm" ] || fail "done records the replanned dependent in the state dir and commits nothing: $(cat "$tmp/done.out") $(git log -1 --format=%s)"
echo '{"tasks": [{"id": "T1", "title": "x", "requirements": ["EXP-01"], "files": ["b"], "deps": [], "dep_reasons": {}, "test": "exempt", "exempt_reason": "x"}]}' >$fx6/plan.json
hm=$(git rev-parse main)
idle 06
"$forge" done 05 >/dev/null
echo '[]' >"$CLAUDE_AGENTS"
[ -f $fx6/plan.json ] || fail "rerunning done on a deviated phase must not replan its dependents again"
[ "$(jq -sr 'map(.step) | join(",")' $fx6/events.jsonl)" = replan,start ] || fail "a rerun done logs no second replan: $(cat $fx6/events.jsonl)"
[ "$(git rev-parse main)" = "$hm" ] || fail "a rerun done commits nothing"
rm $fx6/plan.json
ok done

echo b >.claude/worktrees/crm-export-06/b.txt
git -C .claude/worktrees/crm-export-06 add b.txt && git -C .claude/worktrees/crm-export-06 commit -q -m b
echo '{"status": "done", "summary": "api"}' >$fx6/result.json && recorded $fx6
tested .claude/worktrees/crm-export-06
"$forge" done 06 >/dev/null
[ "$(norm "$(last)")" = "$p/.claude/worktrees/crm-export | --bg -n p verify crm/export $opts bypassPermissions $sv /forge-verify $p crm/export" ] || fail "verify session: $(last)"
echo '[{"id": "v1", "name": "p verify crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
: >"$NOTIFY_LOG"
[ "$(code "$forge" done 06)" = 8 ] || fail "rerunning done with a live verify session exits 8: $(cat "$tmp/out")"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "rerunning done with a live verify session starts no second verify: $(cat "$CLAUDE_LOG")"
[ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "rerunning done with a live verify session sends one notification: $(cat "$NOTIFY_LOG")"
echo '[{"id": "v1", "name": "p crm-export Verify", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$NOTIFY_LOG"
[ "$(code "$forge" done 06)" = 8 ] || fail "rerunning done with a live legacy-named verify session exits 8: $(cat "$tmp/out")"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "rerunning done with a live legacy-named verify session starts no second verify: $(cat "$CLAUDE_LOG")"
[ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "rerunning done with a live legacy-named verify session sends one notification: $(cat "$NOTIFY_LOG")"
echo '[]' >"$CLAUDE_AGENTS"
echo '{"manual_test": ["GET /export"], "result": "gaps", "gaps": [{"phase": "06", "gap": "Late"}]}' >$S/features/crm-export/verify.json
"$forge" done 06 >/dev/null 2>&1
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "rerunning done after verify recorded its result starts no verify: $(cat "$CLAUDE_LOG")"
echo '{"manual_test": ["GET /export"], "result": "gaps", "gaps": [{"phase": "06", "gap": "Dates are not ISO"}, {"phase": "99", "gap": "Nowhere"}]}' >$S/features/crm-export/verify.json
[ "$(code "$forge" next crm/export)" = 1 ] || fail "a gap naming no phase must fail"
[ "$(jq -r '.spec[-1]' $fx6/spec.json)" = "Serve JSON." ] && [ -f $fx6/result.json ] || fail "a failed next changes nothing"
echo '{"manual_test": ["GET /export"], "result": "gaps", "gaps": [{"phase": "06", "gap": "Dates are not ISO"}, {"phase": "05", "gap": "Replan: Core is slow"}]}' >$S/features/crm-export/verify.json
flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" sleep 3 & a=$!
sleep 0.5
s=0; timeout 1 "$forge" next crm/export >/dev/null 2>&1 || s=$?
[ "$s" = 124 ] && [ "$(jq -r '.spec[-1]' $fx6/spec.json)" = "Serve JSON." ] && [ -f $fx6/result.json ] || fail "next edits nothing until it holds forge.lock: $s"
wait $a
mkdir -p $fx6/tasks $fx6/tests $fx6/review $fx6/fixes $fx5/tasks $fx5/tests $fx5/review $fx5/fixes
echo '{"tasks": [{"id": "T1", "title": "x", "requirements": ["EXP-01"], "files": ["b"], "deps": [], "dep_reasons": {}, "test": "exempt", "exempt_reason": "x"}]}' | tee $fx6/plan.json >$fx5/plan.json
echo '{"id": "T1", "status": "done"}' | tee $fx6/tasks/T1.json >$fx5/tasks/T1.json
echo '{"id": "T2", "status": "unmet", "reason": "attempts ran out"}' >$fx6/tasks/T2.json
echo '{"task": "T1", "files": ["b"], "command": "true", "failure": "x"}' | tee $fx6/tests/T1.json >$fx5/tests/T1.json
echo '{"findings": []}' | tee $fx6/review/r.json $fx5/review/r.json >$fx5/review.prev.json
echo '{"file": "b", "line": 1, "status": "fixed", "summary": "x"}' | tee $fx6/fixes/F1.json >$fx5/fixes/F1.json
echo '{"command": "old", "passed": false, "criteria": []}' >$fx5/verify.prev.json
echo '{"findings": [], "pending": ["stale"]}' >$fx6/review.prev.json
recs() { (cd "$1" && shift && md5sum "$@"); }
r6=$(recs $fx6 verify.json review.json review.prev.json review/r.json fixes/F1.json) || fail "fixture: phase 06 lacks a record: $(ls $fx6)"
r5=$(recs $fx5 verify.json review.json verify.prev.json review.prev.json review/r.json fixes/F1.json) || fail "fixture: phase 05 lacks a record: $(ls $fx5)"
[ -f $fx5/result.json ] || fail "fixture: phase 05 has a result.json"
"$forge" event 06 ui no
hn=$(git rev-parse main)
[ "$(code "$forge" next crm/export)" = 0 ] || fail "next with an additive gap for 06 and a Replan: gap for 05: $(cat "$tmp/out")"
[ "$(recs $fx6 verify.json review.json review.prev.json review/r.json fixes/F1.json 2>&1)" = "$r6" ] && [ ! -e $fx6/verify.prev.json ] || fail "an additive retry leaves verify.json, review.json, review/, fixes/ and .prev records byte-for-byte as they were and writes no verify.prev.json: $(ls $fx6)"
grep -qxF "forge: recorded crm/export retry" "$tmp/out" && [ "$(git rev-parse main)" = "$hn" ] || fail "next records under the feature scope and commits nothing: $(cat "$tmp/out") $(git log -1 --format=%s)"
[ "$(jq -r '.spec[-1]' $fx6/spec.json)" = "Gap: Dates are not ISO" ] || fail "gap appended to the phase spec"
[ "$(jq -r '.phases[1].spec[-1]' $S/features/crm-export/split.json)" = "Gap: Dates are not ISO" ] || fail "gap appended to the split"
[ ! -e $fx6/result.json ] && [ ! -e $fx5/result.json ] || fail "retry replans each phase with a gap"
[ "$(jq -sr 'map(.step) | join(",")' $fx6/events.jsonl)" = replan,start,ui,retry ] || fail "retry keeps the ui event and logs a retry event: $(cat $fx6/events.jsonl)"
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05R1 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "retry session: $(last)"
[ "$(jq -sr 'last | "\(.step) \(.message)"' $fx5/events.jsonl)" = "start p P05R1 crm/export" ] || fail "retry launch logs a start event: $(cat $fx5/events.jsonl)"
[ -f .claude/worktrees/crm-export-05/b.txt ] || fail "a retry brings its phase branch up to forge/crm-export"
[ -f $fx6/plan.json ] && [ -f $fx6/tasks/T1.json ] && [ -f $fx6/tests/T1.json ] && [ -f $fx6/scout.json ] || fail "a retry with only additive gaps keeps the phase plan.json, tasks/, tests/ and scout.json: $(ls $fx6)"
[ ! -e $fx6/tasks/T2.json ] || fail "a retry reopens an unmet task by removing its record, so the retry runs it again and its result drops the unmet entry"
for x in plan.json tasks tests result.json; do
  [ ! -e $fx5/$x ] || fail "a phase with a Replan: gap loses plan.json, tasks/, tests/ and result.json: $fx5/$x remains"
done
[ "$(recs $fx5 verify.json review.json verify.prev.json review.prev.json review/r.json fixes/F1.json 2>&1)" = "$r5" ] || fail "a Replan: gap removes only plan.json, tasks/, tests/ and result.json, leaving verify.json, review.json, review/, fixes/ and .prev records as they were: $(ls $fx5)"
rm -r $fx6/plan.json $fx6/tasks $fx6/tests
[ ! -e $S/features/crm-export/verify.json ] || fail "next consumes the gaps verify.json"
: >"$CLAUDE_LOG"
[ "$(code "$forge" next crm/export)" = 1 ] || fail "a rerun next without a new verify.json must fail: $(cat "$tmp/out")"
[ "$(jq '[.spec[] | select(. == "Gap: Dates are not ISO")] | length' $fx6/spec.json)" = 1 ] || fail "a rerun next adds no gap twice: $(jq -c .spec $fx6/spec.json)"
[ "$(jq -sr 'map(.step) | join(",")' $fx6/events.jsonl)" = replan,start,ui,retry ] || fail "a rerun next replans nothing: $(cat $fx6/events.jsonl)"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a rerun next starts nothing: $(cat "$CLAUDE_LOG")"
"$forge" resume 05 >/dev/null
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05R1 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "resume session: $(last)"
echo '[{"id": "a1", "name": "p P05R1 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" resume 05)" = 8 ] || fail "resume of a working phase exits 8: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p P05R1 crm/export", "state": "blocked"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" resume 05)" = 8 ] || fail "resume of a blocked phase exits 8: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p crm-export Phase 05 retry 1", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" resume 05)" = 8 ] && grep -qF "p crm-export Phase 05 retry 1" "$tmp/out" || fail "resume of a phase with a working legacy-named session exits 8 naming it: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p crm-export Phase 05", "state": "blocked"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" resume 05)" = 8 ] || fail "resume of a phase with a blocked legacy-named session exits 8: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p P05R1 crm/export", "state": "done"}, {"id": "a0", "name": "p P05 crm/export", "state": "done"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 0 ] || fail "a done session must not block resume: $(cat "$tmp/out")"
[ "$(grep -c ' rm ' "$CLAUDE_LOG")" = 1 ] && [[ "$(tail -n2 "$CLAUDE_LOG" | head -n1)" == *" | rm a1" ]] || fail "launch removes the idle same-named session before --bg: $(cat "$CLAUDE_LOG")"
echo '[{"id": "a2", "name": "p P06R1 crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 0 ] || fail "a live sibling phase must not block resume: $(cat "$tmp/out")"
! grep -q ' rm ' "$CLAUDE_LOG" || fail "launch removes only sessions of the same name: $(cat "$CLAUDE_LOG")"
echo '[]' >"$CLAUDE_AGENTS"
echo '{"status": "blocked", "summary": "stuck"}' >$fx5/result.json
"$forge" resume 05 >/dev/null
[ ! -e $fx5/result.json ] || fail "resume clears a blocked result"
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05R1 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "resume of a blocked phase: $(last)"
! git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "fixture: forge/crm-export-05 must not be merged into forge/crm-export yet"
echo '{"status": "done", "summary": "core"}' >$fx5/result.json
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 0 ] || fail "resume of an unmerged phase with a done result.json (parked after Result) must start it: $(cat "$tmp/out")"
[ ! -e $fx5/result.json ] || fail "resume of an unmerged phase removes its done result.json"
[ "$(last)" = "$p/.claude/worktrees/crm-export-05 | --bg -n p P05R1 crm/export $opts bypassPermissions $s5 /forge-phase $p 05" ] || fail "resume of an unmerged done phase: $(last)"
echo '{"status": "done", "summary": "core"}' >$fx5/result.json && recorded $fx5
tested .claude/worktrees/crm-export-05
"$forge" done 05 >/dev/null
[ "$(last)" = "$p/.claude/worktrees/crm-export-06 | --bg -n p P06R1 crm/export $opts bypassPermissions $s6 /forge-phase $p 06" ] || fail "retry of 06 after 05: $(last)"
git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "fixture: forge done 05 merges forge/crm-export-05 into forge/crm-export"
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 1 ] && grep -qF "phase 05 is done; nothing to resume" "$tmp/out" || fail "resume of a merged phase must fail naming it done: $(cat "$tmp/out")"
[ "$(jq -r .status $fx5/result.json)" = done ] || fail "a refused resume of a merged phase keeps its result.json"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a refused resume of a merged phase starts nothing: $(cat "$CLAUDE_LOG")"
echo '{"status": "done", "summary": "api"}' >$fx6/result.json && recorded $fx6
tested .claude/worktrees/crm-export-06
"$forge" done 06 >/dev/null
echo '{"manual_test": ["GET /export"], "result": "pass", "gaps": []}' >$S/features/crm-export/verify.json
"$forge" next crm/export >/dev/null
[ "$(last)" = "$p | --bg -n p ship crm/export $opts bypassPermissions $sr /forge-ship $p crm/export" ] || fail "ship session: $(last)"
echo '[{"id": "s1", "name": "p ship crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
: >"$NOTIFY_LOG"
[ "$(code "$forge" next crm/export)" = 8 ] || fail "rerunning next with a live ship session exits 8: $(cat "$tmp/out")"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "rerunning next with a live ship session starts no second ship: $(cat "$CLAUDE_LOG")"
[ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "rerunning next with a live ship session sends one notification: $(cat "$NOTIFY_LOG")"
echo '[{"id": "s1", "name": "p crm-export Ship", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$NOTIFY_LOG"
[ "$(code "$forge" next crm/export)" = 8 ] || fail "rerunning next with a live legacy-named ship session exits 8: $(cat "$tmp/out")"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "rerunning next with a live legacy-named ship session starts no second ship: $(cat "$CLAUDE_LOG")"
[ "$(wc -l <"$NOTIFY_LOG")" = 1 ] || fail "rerunning next with a live legacy-named ship session sends one notification: $(cat "$NOTIFY_LOG")"
echo '[]' >"$CLAUDE_AGENTS"
ok next

jq -n '[{id: "d1", name: "p P05 crm/export", state: "done", status: "idle"}, {id: "d2", name: "p P06R1 crm/export", state: "stopped"},
  {id: "d3", name: "p verify crm/export", state: "done", status: "idle"}, {id: "w1", name: "p P05R1 crm/export", state: "working"},
  {id: "w2", name: "p P06 crm/export", state: "blocked"}, {id: "w3", name: "p verify crm/export", state: "working"},
  {id: "w4", name: "p ship crm/export", state: "done", status: "idle"}, {id: "w5", name: "p ship crm/export", state: "working"},
  {id: "x1", name: "p P01 crm/exporter", state: "done"}, {id: "x2", name: "p verify crm/auth", state: "done"},
  {id: "x3", name: "q P05 crm/export", state: "done"}, {id: "d4", name: "p crm-export Phase 07 retry 1", state: "done", status: "idle"},
  {id: "d5", name: "p crm-export Verify", state: "done", status: "idle"}, {id: "w6", name: "p crm-export Phase 05", state: "working"},
  {id: "w7", name: "p crm-export Ship", state: "done", status: "idle"}, {id: "x4", name: "p crm-exporter Phase 01", state: "done"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
[ "$(code "$forge" clean --sessions crm/export)" = 0 ] || fail "clean --sessions must succeed: $(cat "$tmp/out")"
[ "$(grep -o ' rm .*' "$CLAUDE_LOG" | sort | tr '\n' ,)" = " rm d1, rm d2, rm d3, rm d4, rm d5," ] || fail "clean --sessions removes only the feature's idle phase and verify sessions, legacy-named ones included: $(cat "$CLAUDE_LOG")"
[ -d .claude/worktrees/crm-export ] && [ -d .claude/worktrees/crm-export-05 ] && [ -d .claude/worktrees/crm-export-06 ] || fail "clean --sessions keeps the worktrees"
[ "$(git branch --format='%(refname:short)' --list 'forge/*' | paste -sd ' ')" = "forge/crm-export forge/crm-export-05 forge/crm-export-06" ] || fail "clean --sessions keeps the branches: $(git branch --list 'forge/*')"
[ "$(code "$forge" clean --sessions)" = 2 ] || fail "clean --sessions without a feature must exit 2"
"$forge" clean --help | grep -qF -- "--sessions" || fail "forge clean --help documents --sessions"
grep -qE '^  clean .*--sessions' "$tmp/help" || fail "forge --help lists clean --sessions: $(grep -E '^  clean' "$tmp/help")"

echo '[{"id": "a1", "name": "p P05 crm/export", "state": "done"}, {"id": "a2", "name": "p P06R1 crm/export", "state": "working"}, {"id": "a3", "name": "p verify crm/export", "state": "blocked"}, {"id": "a4", "name": "p ship crm/export", "state": "working"}, {"id": "a5", "name": "p P01 crm/exporter", "state": "working"}, {"id": "a6", "name": "p crm-export Phase 06", "state": "done"}, {"id": "a7", "name": "p crm-export Ship", "state": "working"}, {"id": "a8", "name": "p crm-exporter Phase 01", "state": "done"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
mv $S/features/crm-export/split.json "$tmp/split"
[ "$(code "$forge" clean crm/export)" = 1 ] || fail "clean without a split must fail"
mv "$tmp/split" $S/features/crm-export/split.json
: >"$CLAUDE_LOG"
mkdir -p .claude/worktrees/crm-export-05/.serena && echo cache >.claude/worktrees/crm-export-05/.serena/cache
CLAUDE_RM_WT=$p/.claude/worktrees/crm-export-05 "$forge" clean --confirmed crm/export >/dev/null
[ "$(grep -c "^saw-worktree $p/.claude/worktrees/crm-export-05$" "$CLAUDE_LOG")" = 4 ] || fail "clean removes the sessions before the worktrees: $(cat "$CLAUDE_LOG")"
[ "$(grep -o ' rm .*' "$CLAUDE_LOG" | sort | tr '\n' ,)" = " rm a1, rm a2, rm a3, rm a6," ] || fail "clean removes the feature's sessions except ship, legacy-named ones included: $(cat "$CLAUDE_LOG")"
[ ! -e .claude/worktrees/crm-export ] && [ ! -e .claude/worktrees/crm-export-05 ] && [ ! -e .claude/worktrees/crm-export-06 ] || fail "clean removes the worktrees"
[ "$(git branch --format='%(refname:short)' --list 'forge/*')" = forge/crm-export ] || fail "clean keeps only the feature branch"
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p $S/features/crm-export
echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >$S/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
git add -A && git commit -q -m init
"$forge" implement crm/export >/dev/null
cp .forge/tracks/crm.json .claude/worktrees/crm-export-05/tracked.json && git -C .claude/worktrees/crm-export-05 add tracked.json && git -C .claude/worktrees/crm-export-05 commit -q -m t
git -C .claude/worktrees/crm-export merge -q forge/crm-export-05
echo changed >.claude/worktrees/crm-export-05/tracked.json
[ "$(code "$forge" clean --confirmed crm/export)" = 1 ] || fail "clean must refuse a worktree with uncommitted tracked changes"
[ -f .claude/worktrees/crm-export-05/tracked.json ] || fail "the changed worktree stays"
git -C .claude/worktrees/crm-export-05 checkout -q -- tracked.json
echo wip >.claude/worktrees/crm-export-05/notes.txt
[ "$(code "$forge" clean --confirmed crm/export)" = 1 ] && grep -qF "untracked" "$tmp/out" || fail "clean must refuse a worktree with untracked files: $(cat "$tmp/out")"
[ "$(cat .claude/worktrees/crm-export-05/notes.txt)" = wip ] || fail "the untracked file stays"
rm .claude/worktrees/crm-export-05/notes.txt
mkdir -p .claude/worktrees/crm-export-05/.impeccable && echo '{}' >.claude/worktrees/crm-export-05/.impeccable/config.json
git -C .claude/worktrees/crm-export-05 add .impeccable/config.json && git -C .claude/worktrees/crm-export-05 commit -q -m impeccable
git -C .claude/worktrees/crm-export merge -q forge/crm-export-05
echo '{}' >.claude/worktrees/crm-export-05/.impeccable/hook.cache.json
[ "$(git -C .claude/worktrees/crm-export-05 status --porcelain)" = "?? .impeccable/hook.cache.json" ] || fail "the impeccable cache is an untracked file beside a tracked config: $(git -C .claude/worktrees/crm-export-05 status --porcelain)"
[ "$(code "$forge" clean --confirmed crm/export)" = 0 ] || fail "clean must treat an untracked file under .impeccable/ as tool cache: $(cat "$tmp/out")"
[ ! -e .claude/worktrees/crm-export-05 ] && [ ! -e .claude/worktrees/crm-export ] || fail "clean removes the worktree holding only impeccable cache"
ok clean
fi

shipped() {
  fresh
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  echo '[]' >"$CLAUDE_AGENTS"
  mkdir -p $S/features/crm-export
  echo '{"phases": [{"slug": "export-core", "goal": "Core", "spec": [], "requirements": [], "depends": []}, {"slug": "export-api", "goal": "API", "spec": [], "requirements": [], "depends": []}]}' >$S/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  git add -A && git commit -q -m init
  "$forge" implement crm/export >/dev/null
  "$forge" resume 06 >/dev/null
  local n
  for n in 05 06; do
    echo "$n" >.claude/worktrees/crm-export-$n/$n.txt && git -C .claude/worktrees/crm-export-$n add $n.txt && git -C .claude/worktrees/crm-export-$n commit -q -m "$n"
    git -C .claude/worktrees/crm-export merge -q --no-edit forge/crm-export-$n
  done
  rm -rf "$tmp/origin.git" && git init -q --bare -b main "$tmp/origin.git"
  git remote add origin "$tmp/origin.git" && git push -q origin forge/crm-export:main && git fetch -q origin
  git merge-base --is-ancestor forge/crm-export refs/remotes/origin/main || fail "the shipped bed holds the feature branch in origin/main"
  echo '[{"id": "a1", "name": "p P05 crm/export", "state": "done"}, {"id": "a4", "name": "p ship crm/export", "state": "working"}]' >"$CLAUDE_AGENTS"
  : >"$CLAUDE_LOG"
}
kept() {
  [ -d .claude/worktrees/crm-export ] && [ -d .claude/worktrees/crm-export-05 ] && [ -d .claude/worktrees/crm-export-06 ] || fail "$1: the worktrees stay"
  [ "$(git branch --format='%(refname:lstrip=2)' --list 'forge/*' | paste -sd ' ')" = "forge/crm-export forge/crm-export-05 forge/crm-export-06" ] || fail "$1: the branches stay: $(git branch --list 'forge/*')"
  ! grep -q ' rm ' "$CLAUDE_LOG" || fail "$1: no session is removed: $(cat "$CLAUDE_LOG")"
}
gone() {
  [ ! -e .claude/worktrees/crm-export ] && [ ! -e .claude/worktrees/crm-export-05 ] && [ ! -e .claude/worktrees/crm-export-06 ] || fail "$1: clean removes the worktrees"
  [ "$(git branch --format='%(refname:short)' --list 'forge/*')" = forge/crm-export ] || fail "$1: clean keeps only the feature branch: $(git branch --list 'forge/*')"
  [ "$(grep -o ' rm .*' "$CLAUDE_LOG")" = " rm a1" ] || fail "$1: clean removes the phase session: $(cat "$CLAUDE_LOG")"
}
refused() {
  [ "$(code "$forge" clean crm/export)" = 3 ] || fail "$1: clean of a target not in origin/main removes nothing and exits 3: $(cat "$tmp/out")"
  grep -qF "branch $p:forge/crm-export-05" "$tmp/out" && grep -qF "worktree $p/.claude/worktrees/crm-export" "$tmp/out" && grep -qF "forge clean --confirmed crm/export" "$tmp/out" || fail "$1: the refusal names the targets and the override: $(cat "$tmp/out")"
  kept "$1"
}

if want clean-merged; then
shipped
[ "$(code "$forge" clean crm/export)" = 0 ] || fail "clean with every phase and the feature branch in origin/main exits 0: $(cat "$tmp/out")"
gone "every branch in origin/main"

shipped
echo more >.claude/worktrees/crm-export-06/more.txt && git -C .claude/worktrees/crm-export-06 add more.txt && git -C .claude/worktrees/crm-export-06 commit -q -m more
refused "a phase branch not in origin/main"
grep -qF "branch $p:forge/crm-export-06" "$tmp/out" || fail "the refusal names the unshipped phase branch: $(cat "$tmp/out")"

shipped
git tag forge/crm-export-06 refs/remotes/origin/main
echo more >.claude/worktrees/crm-export-06/more.txt && git -C .claude/worktrees/crm-export-06 add more.txt && git -C .claude/worktrees/crm-export-06 commit -q -m more
refused "a phase branch not in origin/main behind a same-named tag that is"
[ "$(code "$forge" clean --confirmed crm/export)" = 1 ] && grep -qF "forge/crm-export-06 is not merged into forge/crm-export" "$tmp/out" || fail "clean --confirmed refuses a phase branch not merged into the feature branch behind a same-named tag that is: $(cat "$tmp/out")"
git show-ref -q --verify refs/heads/forge/crm-export-06 || fail "the unmerged phase branch behind a same-named tag stays"

shipped
echo more >.claude/worktrees/crm-export-06/more.txt && git -C .claude/worktrees/crm-export-06 add more.txt && git -C .claude/worktrees/crm-export-06 commit -q -m more
git push -q origin "$(git commit-tree "forge/crm-export-06^{tree}" -p refs/remotes/origin/main -p forge/crm-export-06 -m merge):refs/heads/main" && git fetch -q origin
git merge-base --is-ancestor forge/crm-export-06 refs/remotes/origin/main && ! git merge-base --is-ancestor forge/crm-export-06 forge/crm-export || fail "the bed holds the phase branch in origin/main but not in the feature branch"
refused "a phase branch in origin/main but not in the feature branch"

shipped
echo more >.claude/worktrees/crm-export/more.txt && git -C .claude/worktrees/crm-export add more.txt && git -C .claude/worktrees/crm-export commit -q -m more
refused "the feature branch not in origin/main"
head -1 "$tmp/out" | grep -qF "forge: crm/export is not in origin/main; nothing removed. Targets:" || fail "the refusal of a repo with origin names origin/main: $(head -1 "$tmp/out")"

shipped
git remote remove origin
! git show-ref -q --verify refs/remotes/origin/main || fail "the bed without origin has no origin/main"
refused "a repo with no origin/main"
! head -1 "$tmp/out" | grep -qF "is not in origin/main; nothing removed" && head -1 "$tmp/out" | sed 's#origin/main##g' | grep -qw main || fail "the refusal of a repo with no origin names local main: $(head -1 "$tmp/out")"
[ "$(code "$forge" clean --confirmed crm/export)" = 0 ] || fail "--confirmed overrides the refusal of a repo with no origin/main: $(cat "$tmp/out")"
gone "--confirmed"

shipped
git merge -q --no-edit forge/crm-export
git remote remove origin
git merge-base --is-ancestor forge/crm-export refs/heads/main && ! git remote get-url origin >/dev/null 2>&1 || fail "the bed without origin holds the feature branch in local main"
[ "$(code "$forge" clean crm/export)" = 0 ] || fail "clean of a repo with no origin and the feature branch in local main exits 0: $(cat "$tmp/out")"
gone "no origin and the feature branch in local main"

shipped
git merge -q --no-edit forge/crm-export
echo more >.claude/worktrees/crm-export-06/more.txt && git -C .claude/worktrees/crm-export-06 add more.txt && git -C .claude/worktrees/crm-export-06 commit -q -m more
git remote remove origin
git merge-base --is-ancestor forge/crm-export refs/heads/main && ! git merge-base --is-ancestor forge/crm-export-06 forge/crm-export || fail "the bed holds the feature branch in local main but not the phase branch in the feature branch"
refused "no origin and a phase branch not in the feature branch"
grep -qF "branch $p:forge/crm-export-06" "$tmp/out" || fail "the no-origin refusal names the unmerged phase branch: $(cat "$tmp/out")"

shipped
echo changed >.claude/worktrees/crm-export-05/05.txt
[ "$(code "$forge" clean crm/export)" = 1 ] && grep -qF "uncommitted changes" "$tmp/out" || fail "clean with every branch in origin/main still refuses a worktree with uncommitted changes: $(cat "$tmp/out")"
[ "$(cat .claude/worktrees/crm-export-05/05.txt)" = changed ] || fail "the changed worktree stays"

shipped
git -C "$tmp/origin.git" fetch -q "$p" +forge/crm-export:refs/heads/extra
remotes=$(git for-each-ref refs/remotes/origin)
[ "$(code "$forge" clean crm/export)" = 0 ] || fail "clean with a remote main matching the local origin/main exits 0: $(cat "$tmp/out")"
[ "$(git for-each-ref refs/remotes/origin)" = "$remotes" ] || fail "clean does not fetch: $(git for-each-ref refs/remotes/origin)"
gone "a matching remote main"

shipped
local_main=$(git rev-parse refs/remotes/origin/main)
git -C "$tmp/origin.git" fetch -q "$p" +main:refs/heads/main
[ "$(git -C "$tmp/origin.git" rev-parse refs/heads/main)" = "$(git rev-parse main)" ] || fail "the remote main is rolled back"
refused "a remote main rolled back after the local origin/main was updated"
[ "$(git rev-parse refs/remotes/origin/main)" = "$local_main" ] || fail "clean does not fetch the rolled-back remote main"

shipped
rm -rf "$tmp/other.git" && git init -q --bare -b main "$tmp/other.git" && git -C "$tmp/other.git" fetch -q "$p" main:refs/heads/main
git remote set-url origin "$tmp/other.git"
git merge-base --is-ancestor forge/crm-export refs/remotes/origin/main || fail "the stale local origin/main still holds the feature branch"
refused "origin repointed to a repo whose main lacks the branches"

shipped
git remote set-url origin "$tmp/missing.git"
refused "origin pointing to a missing path"

shipped
mkdir -p "$tmp/lsfail" && printf '#!/usr/bin/env bash\ns=0\n"%s" "$@" || s=$?\n[[ " $* " != *" ls-remote "* ]] || exit 1\nexit $s\n' "$(command -v git)" >"$tmp/lsfail/git" && chmod +x "$tmp/lsfail/git"
[ "$(PATH=$tmp/lsfail:$PATH git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse refs/remotes/origin/main)" ] && ! PATH=$tmp/lsfail:$PATH git ls-remote origin refs/heads/main >/dev/null || fail "the ls-remote shim prints the matching main and fails"
PATH=$tmp/lsfail:$PATH refused "a remote query that prints the matching main and then fails"
"$forge" clean --help | grep -qF "origin/main" || fail "forge clean --help documents the origin/main skip"
"$forge" clean --help | grep -qF "ls-remote" || fail "forge clean --help documents the remote main query"
ok clean-merged
fi

if want settings; then
rm -rf "$tmp/my-app.x" && project "$tmp/my-app.x" && cd "$tmp/my-app.x"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
sm=$XDG_STATE_HOME/forge/my-app.x
mkdir -p "$sm/features/crm-export"
echo '{"phases": [{"slug": "export-core", "number": "08", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >"$sm/features/crm-export/split.json"
"$forge" alloc crm/export >/dev/null
git add -A && git commit -q -m init
"$forge" implement crm/export >/dev/null
[ "$(last)" = "$PWD/.claude/worktrees/crm-export-08 | --bg -n my-app.x P08 crm/export $opts bypassPermissions --settings {\"env\":{\"FORGE_PORT_OFFSET\":\"10\",\"FORGE_TEST_DB\":\"my_app_x_test_08\",\"FORGE_ROOT\":\"$PWD\",\"FORGE_PHASE\":\"08\",\"CLAUDE_CODE_FORK_SUBAGENT\":\"0\"},\"disableBundledSkills\":true,\"skillListingBudgetFraction\":0.0001,\"worktree\":{\"bgIsolation\":\"none\",\"baseRef\":\"head\"}} /forge-phase $PWD 08" ] || fail "phase 08 session: $(last)"
ok settings
fi

two() {
  fresh
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  echo '[]' >"$CLAUDE_AGENTS"
  mkdir -p $S/features/crm-export
  echo "{\"phases\": [{\"slug\": \"export-core\", \"goal\": \"Core\", \"spec\": [], \"requirements\": [], \"depends\": []}, {\"slug\": \"export-api\", \"goal\": \"API\", \"spec\": [], \"requirements\": [], \"depends\": $1}]}" >$S/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  alltests
  git add -A && git commit -q -m init
  "$forge" implement crm/export >/dev/null
  idle 05 06
}
work() {
  local w=.claude/worktrees/crm-export-$1 d=("$S"/phases/"$1"-*)
  echo "$1" >"$w/$1.txt" && git -C "$w" add "$1.txt" && git -C "$w" commit -q -m "$1"
  "$forge" test "$w" >/dev/null
  echo '{"status": "done", "summary": "x"}' >"${d[0]}/result.json"
  recorded "${d[0]}"
}
verifies() { grep -c -- '--bg -n p verify crm/export ' "$CLAUDE_LOG" || true; }

if want merged; then
two '["export-core"]'
work 05
: >"$CLAUDE_LOG"
"$forge" implement crm/export >/dev/null
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a done result not yet merged must not release its dependent: $(cat "$CLAUDE_LOG")"
echo '[{"id": "l6", "name": "p crm-export Phase 06", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" done 05)" = 8 ] || fail "done 05 beside a live legacy-named session of phase 06 exits 8: $(cat "$tmp/out")"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a live legacy-named session of phase 06 blocks its launch: $(cat "$CLAUDE_LOG")"
grep -qF "phase 06 already has a live session p crm-export Phase 06" "$tmp/out" || fail "the skipped launch names the legacy-named session: $(cat "$tmp/out")"
idle 05
"$forge" done 05 >/dev/null
[[ "$(last)" == *" | --bg -n p P06 crm/export "* ]] || fail "the merge of 05 releases 06: $(last)"

two '[]'
"$forge" resume 06 >/dev/null
work 05 && work 06
: >"$CLAUDE_LOG"
"$forge" done 05 >/dev/null
[ "$(verifies)" = 0 ] || fail "a done result not yet merged must not start verify: $(cat "$CLAUDE_LOG")"
"$forge" done 06 >/dev/null
[ "$(verifies)" = 1 ] || fail "the last merge starts verify: $(cat "$CLAUDE_LOG")"

two '[]'
"$forge" resume 06 >/dev/null
work 05 && work 06
: >"$CLAUDE_LOG"
"$forge" done 05 >"$tmp/d5" 2>&1 & a=$!
"$forge" done 06 >"$tmp/d6" 2>&1 & b=$!
wait $a || fail "simultaneous done 05: $(cat "$tmp/d5")"
wait $b || fail "simultaneous done 06: $(cat "$tmp/d6")"
git merge-base --is-ancestor forge/crm-export-05 forge/crm-export && git merge-base --is-ancestor forge/crm-export-06 forge/crm-export || fail "both phases merge"
[ "$(verifies)" = 1 ] || fail "two simultaneous done start exactly one verify: $(cat "$CLAUDE_LOG")"
ok merged
fi

bgs() { grep -o -- '--bg -n p P[0-9R]* ' "$CLAUDE_LOG" | sed 's/^--bg -n p //; s/ $//' | paste -sd ' '; }
launched() { : >"$CLAUDE_LOG"; "$@" >"$tmp/out" 2>&1 || fail "$*: $(cat "$tmp/out")"; }
fx5=$S/phases/05-export-core fx6=$S/phases/06-export-api fx7=$S/phases/07-export-web

if want depends; then
two '["export-core"]'
idle 05
launched "$forge" implement crm/export
[ -z "$(bgs)" ] || fail "a dependent of a running, unmerged phase does not start: $(cat "$CLAUDE_LOG")"
! grep -q FORGE_PHASE_STAGE "$CLAUDE_LOG" || fail "an advance with an unmerged dependency sets no FORGE_PHASE_STAGE: $(cat "$CLAUDE_LOG")"
[ ! -f $fx6/events.jsonl ] || ! jq -se 'any(.step == "start")' $fx6/events.jsonl >/dev/null || fail "a dependent of an unmerged phase logs no start event: $(cat $fx6/events.jsonl)"
[ "$(code "$forge" wait 06)" = 2 ] && grep -qxF "forge: unknown command 'wait'" "$tmp/out" || fail "forge wait 06 is an unknown command: $(cat "$tmp/out")"
work 05
launched "$forge" done 05
[ "$(bgs)" = P06 ] || fail "forge done of the last dependency starts the dependent: $(cat "$CLAUDE_LOG")"
! grep -q FORGE_PHASE_STAGE "$CLAUDE_LOG" || fail "the launch after the dependency merged sets no FORGE_PHASE_STAGE: $(cat "$CLAUDE_LOG")"
ok depends
fi

fx8=$S/phases/08-export-cli
planned() { local d=$1; shift; jq -n '{tasks: [$ARGS.positional[] | split("=") | {id: .[0], title: "x", files: (.[1] | split(",")), deps: [], test: "exempt", exempt_reason: "x"}]}' --args "$@" >"$d/plan.json"; }
replans() { jq -sr 'map(select(.step == "replan") | .message) | join(",")' "$1/events.jsonl" 2>/dev/null || true; }
if want replan; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo '[]' >"$CLAUDE_AGENTS"
mkdir -p $S/features/crm-export
jq -n '{phases: [{slug: "export-core", goal: "Core", spec: [], requirements: [], depends: []},
  {slug: "export-api", goal: "API", spec: [], requirements: [], depends: ["export-core"]},
  {slug: "export-web", goal: "Web", spec: [], requirements: [], depends: ["export-core"]},
  {slug: "export-cli", goal: "CLI", spec: [], requirements: [], depends: ["export-core"]}]}' >$S/features/crm-export/split.json
"$forge" alloc crm/export >/dev/null
alltests
planned $fx5 T1=src/a.sh,src/b.sh T2=src/c.sh
planned $fx6 T1=src/x.sh,src/b.sh
planned $fx7 T1=src/c.sh,src/d.sh,src/e.sh
planned $fx8 T1=src/a.sh
for d in $fx6 $fx7 $fx8; do echo '{"questions": []}' >$d/research.json; done
git add -A && git commit -q -m init
launched "$forge" implement crm/export
idle 05
mkdir -p $fx5/tasks
echo '{"id": "T1", "status": "done", "deviation": "split the parser", "deviation_kind": "interface"}' >$fx5/tasks/T1.json
echo '{"id": "T2", "status": "done", "deviation": ""}' >$fx5/tasks/T2.json
echo '{"id": "T3", "status": "done", "deviation": "added src/e.sh", "deviation_kind": "interface"}' >$fx5/tasks/T3.json
echo '{"status": "done", "summary": "cli"}' >$fx8/result.json
work 05
hr=$(git rev-parse main)
launched "$forge" done 05
[ ! -e $fx6/plan.json ] && [ "$(replans $fx6)" = "phase 05 deviated" ] || fail "a deviation replans a not-done dependent whose plan names a file of the deviating task: $(cat $fx6/events.jsonl 2>&1)"
grep -qxF "forge: recorded 05 done" "$tmp/out" && [ "$(git rev-parse main)" = "$hr" ] || fail "done records the replanned dependent in the state dir and commits nothing: $(cat "$tmp/out") $(git log -1 --format=%s)"
[ -f $fx7/plan.json ] && [ -z "$(replans $fx7)" ] || fail "a dependent whose plan names only files of an empty-deviation task or none of 05's plan keeps its plan and logs no replan: $(cat $fx7/events.jsonl 2>&1)"
[ -f $fx8/plan.json ] && [ -f $fx8/result.json ] && [ -z "$(replans $fx8)" ] || fail "a done dependent is never replanned, even when its files overlap: $(cat $fx8/events.jsonl 2>&1)"

two '["export-core"]'
planned $fx5 T1=src/a.sh
planned $fx6 T1=src/a.sh
mkdir -p $fx5/tasks
echo '{"id": "T1", "status": "done"}' >$fx5/tasks/T1.json
work 05
launched "$forge" done 05
[ -f $fx6/plan.json ] && [ -z "$(replans $fx6)" ] || fail "a deviation-free phase replans nothing: $(cat $fx6/events.jsonl 2>&1)"
ok replan
fi

finish
