#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
root=$(cd "$(dirname "$0")/.." && pwd)

fail() { echo "forge-phase-parallel: FAIL $*" >&2; exit 1; }
[ -z "${1:-}" ] || fail "no case $1"
skill_text() {
  awk -v root="$root" '
    { print }
    match($0, /Read ~\/\.claude\/skills\/[a-z0-9-]+\/[a-z0-9-]+\.md and follow it\./) {
      p = root "/" substr($0, RSTART + 15, RLENGTH - 30)
      while ((r = (getline l < p)) > 0) print l
      close(p)
      if (r < 0) { print "forge-phase-parallel: FAIL " FILENAME ":" FNR ": pointer file " p " is missing" > "/dev/stderr"; bad = 1 }
    }
    END { exit bad }
  ' "$1"
}
skill=$(skill_text "$root/skills/forge-phase/SKILL.md" | tr '\n' ' ' | tr -s ' ')
has() { grep -qiE -- "$1" <<<"$skill"; }

has 'never two test-writers or implementers at once' && fail "forge-phase must drop the one-at-a-time task wording"
has 'in dependency order, one at a time' && fail "forge-phase must drop the one-at-a-time task wording"
has '`FORGE_TASK_CONCURRENCY`' || fail "forge-phase must name FORGE_TASK_CONCURRENCY"
has 'FORGE_TASK_CONCURRENCY`[^.]*default 3[^0-9]' || fail "forge-phase must give FORGE_TASK_CONCURRENCY a default of 3"
has 'FORGE_TASK_CONCURRENCY`[^.]*above 20[^0-9][^.]*counts as 20[^0-9]' || fail "forge-phase must cap FORGE_TASK_CONCURRENCY at 20"
has 'ready tasks? in one message' || fail "forge-phase must spawn the ready tasks' agents in one message"
has 'respawns only that task' || fail "forge-phase must respawn only the failed task's agent"
has 'with no result line' || fail "forge-phase must wait for in-flight agents by ending the turn with no result line"
has 'recompute the ready set' || fail "forge-phase must recompute the ready set on resume"

whole=$(grep -oiE '(GIT_INDEX_FILE=[^ ]+ )?git (-C [^ ]+ )?(add|commit) (-A|-a|-u|\.)([ `]|$)' <<<"$skill" | grep -v '^GIT_INDEX_FILE=' || true)
[ -z "$whole" ] || fail "forge-phase must never stage the whole tree: $whole"
has 'only its own files by path' || fail "forge-phase's commit rule must stage only each commit's own files by path"
has 'one task at a time after its agent completes' || fail "forge-phase's test-command rule must run task tests one task at a time after its agent completes"

for g in forge-test-writer test-writer must-fail test-first 'P/tests/'; do
  grep -qiF -- "$g" <<<"$skill" && fail "forge-phase must no longer name $g"
done
"$root/bin/forge" event --help | grep -qiF 'must-fail' && fail "forge event --help must no longer list the must-fail step"
records=$(grep -oE "never edit an agent's record \([^)]*\)" <<<"$skill" || true)
[ -n "$records" ] || fail "forge-phase must keep the agent-record list in its forge-guard rule"
grep -qF 'tests/' <<<"$records" && fail "the agent-record list must drop tests/"

step() {
  local s
  [[ $skill == *"$1"* ]] || fail "forge-phase has no step '$1'"
  s=${skill#*"$1"}
  printf '%s' "${s%%"$2"*}"
}
at() { { grep -oibE -- "$1" <<<"$2" || true; } | head -1 | cut -d: -f1; }
before() {
  local a b
  a=$(at "$1" "$3")
  b=$(at "$2" "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
has 'Run the steps in order' || fail "forge-phase must keep the steps-in-order Rule"
has 'except where a step starts jobs together' && fail "forge-phase's steps-in-order Rule must drop its Research and Verify exceptions"
has 'forge verify-tests' && fail "forge-phase must run no forge verify-tests: feature verify judges the requirements"
has 'forge test --passed' && fail "forge-phase must run no forge test --passed check"
has 'forge test --changed --base' && fail "forge-phase must run no forge test --changed --base: feature verify runs the changed tests"
late=${skill#*"3. Sync."}
grep -qF 'forge test --changed' <<<"$late" && fail "Sync, Perf, Result and Finish must run no forge test --changed"
grep -qF 'forge test --changed' "$root/skills/forge-phase/resolver-loop.md" && fail "resolver-loop.md must run no forge test --changed before forge merge --continue"
grep -qiF 'test failure' "$root/skills/forge-phase/resolver-loop.md" && fail "resolver-loop.md must give the merger no test failure"
grep -qF "Read ~/.claude/skills/forge-phase/resolver-loop.md and follow it." "$root/skills/forge-phase/SKILL.md" || fail "SKILL.md must keep its pointer line to resolver-loop.md"
grep -qF "skills/forge-phase/perf.md" "$root/skills/forge-phase/SKILL.md" && fail "SKILL.md must drop its pointer line to the removed perf.md"
[ ! -e "$root/skills/forge-phase/perf.md" ] || fail "skills/forge-phase/perf.md must be deleted: phases no longer handle Perf"
has 'Perf:' && fail "forge-phase must drop its Perf handling and result.json perf object"
has 'forge jev|forge-jev' && fail "forge-phase must drop the forge jev rule"
for f in contracts fix-recording; do
  grep -qF "skills/forge-phase/$f.md" "$root/skills/forge-phase/SKILL.md" && fail "SKILL.md must drop its pointer line to the removed $f.md"
  [ ! -e "$root/skills/forge-phase/$f.md" ] || fail "skills/forge-phase/$f.md must be deleted with its step"
done
has "tasks'? own test commands" || fail "the Rules test bullet must name the tasks' own test commands as a phase's only tests"
has 'feature verify.{0,40}changed tests' || fail "the Rules test bullet must say feature verify runs the changed tests"
has 'Retest:' || fail "forge-phase must keep the Retest rule"
has 'Failed tree:' && fail "forge-phase must drop the Failed tree rule: forge test never refuses a tree that failed"
[[ $skill == *'Pre-existing failures:'* ]] && fail "forge-phase must drop the Pre-existing failures rule"
has "Verify's test run" && fail "the steps-in-order exceptions must drop Verify's test run"
has "Fix's test" && fail "the steps-in-order exceptions must drop Fix's test rerun"

for g in '[0-9]+\. Research\.' '[0-9]+\. Scout\.' '[0-9]+\. Verify\.' '[0-9]+\. Contracts\.' '[0-9]+\. Review\.' '[0-9]+\. Fix\.'; do
  has "$g" && fail "forge-phase must have no step matching $g"
done
for g in forge-gap-finder forge-scout forge-verifier forge-researcher forge-fixer FORGE_PHASE_STAGE 'forge wait N' \
  'forge verify-start' 'forge verify-finish' 'forge contracts N' 'forge fixes N' 'forge review N' 'forge ui N' \
  'P/verify.json' 'P/scout.json' 'P/research.json' 'P/gaps.json' 'pre-fix'; do
  grep -qiF -- "$g" <<<"$skill" && fail "forge-phase must no longer name $g"
done

plan=$(step '1. Plan.' '2. Tasks.')
deny='jq -r '\''(.permissions.deny // [])[] | select(startswith("Bash("))'\'' ~/.claude/settings.json'
grep -qF -- "$deny" <<<"$plan" || fail "Plan must read the Bash deny patterns with $deny"
grep -qiE 'before spawning `forge-planner`' <<<"$plan" || before 'permissions\.deny' 'spawn `forge-planner`' "$plan" ||
  fail "Plan must read the deny patterns before spawning forge-planner"
grep -qF '`Denied Bash patterns:`' <<<"$plan" || fail "Plan must pass the patterns as Denied Bash patterns: lines"
grep -qiE 'Denied Bash patterns:`[^.]{0,80}`none`' <<<"$plan" || fail "Plan must pass Denied Bash patterns: none when there are none"
grep -qiE 'missing[^.]{0,80}(means|is) no patterns|missing[^.]{0,80}`none`' <<<"$plan" ||
  fail "Plan must treat a missing settings file as no patterns"
grep -qiE '(other|any other)[^.]{0,60}(read|jq)[^.]{0,80}decide it yourself \(the no-ask Rules bullet\)[^.]{0,40}stderr' <<<"$plan" ||
  fail "Plan must decide it yourself (the no-ask Rules bullet) from its stderr on any other read or jq failure"
grep -qiE 'replans?[^.]{0,80}(them|the patterns|Denied Bash patterns)|(patterns|Denied Bash patterns:?`?)[^.]{0,120}replans?' <<<"$plan" ||
  fail "Plan must pass the deny patterns on replans too"
grep -qF '`FORGE_ROOT=R forge plan-done N`' <<<"$plan" || fail "Plan must run FORGE_ROOT=R forge plan-done N"
before 'spawn `forge-planner`' 'forge plan-done N' "$plan" || fail "Plan must run forge plan-done N after spawning forge-planner"
grep -qF 'forge check N' <<<"$plan" && fail "Plan must leave forge check N to forge plan-done"
has 'FORGE_ROOT=R forge check N' && fail "forge-phase must no longer run FORGE_ROOT=R forge check N itself"
grep -qiE '`P/plan\.json`[^.]{0,40}`deferred`' <<<"$plan" && fail "Plan must leave logging the P/plan.json deferred entries to forge plan-done"
grep -qiF 'commit `plan`' <<<"$plan" && fail "Plan must leave committing plan to forge plan-done"
pd=${plan#*"forge plan-done N"}
grep -qiE 'exit 1[^.]{0,60}replan[^.]{0,120}failures' <<<"$pd" || fail "forge plan-done exit 1 must replan with the printed failures"
grep -qiE 'replans?.{0,200}rerun|rerun.{0,200}replans?' <<<"$plan" || fail "Plan's replans must rerun forge plan-done N"
grep -qiE 'exit 0.{0,300}resolver loop with `BASE`' <<<"$pd" || fail "forge plan-done exit 0 must go on to the resolver loop with BASE before the first task"
grep -qiE 'exit 3.{0,300}`result: Phase N waits on <M>, (…|\.\.\.)`' <<<"$pd" || fail "forge plan-done exit 3 must end the turn with result: Phase N waits on <M>, ... as printed"
grep -qiE 'waits on <M>, (…|\.\.\.)`.{0,100}no `P/result\.json`' <<<"$pd" || fail "forge plan-done exit 3 must write no P/result.json"
grep -qF 'already holds this phase' <<<"$plan" || fail "Plan must keep the retry and replan prompt"
grep -qiE 'spawn `forge-planner`[^.]*`P/spec\.json`' <<<"$plan" || fail "Plan must spawn forge-planner with P/spec.json"
grep -qF 'Handshake' <<<"$plan" && fail "Plan must drop the sibling interface Handshake"
has 'Append a sibling' && fail "Rules must drop the sibling interface message rule"
has 'Interface: ' && fail "forge-phase must send and append no Interface: lines"

tasks=$(step '2. Tasks.' '3. Sync.')
grep -qF '`FORGE_ROOT=R forge task-done N <id>`' <<<"$tasks" || fail "Tasks must run FORGE_ROOT=R forge task-done N <id>"
grep -qiE '(after|once|when) (each|an?) agent completes.{0,300}forge task-done N <id>' <<<"$tasks" ||
  fail "Tasks must run forge task-done N <id> after each agent completes"
grep -qiE 'that task only' <<<"$tasks" || fail "Tasks must run forge task-done for that task only"
grep -qiE "verify step.s changed tests" <<<"$tasks" && fail "Tasks' note must name feature verify's changed tests, not the verify step's"
grep -qiE "feature verify.{0,10}changed tests" <<<"$tasks" || fail "Tasks' note must say feature verify's changed tests catch a sibling task's later edit"
for g in 'git -C W add' 'git -C W commit' 'git -C W status'; do
  grep -qF -- "$g" <<<"$tasks" && fail "Tasks must leave $g to forge task-done"
done
td=${tasks#*"forge task-done N <id>"}
grep -qiE '\b0\b.{0,200}newly ready' <<<"$td" || fail "forge task-done exit 0 must commit the task and spawn the newly ready tasks"
grep -qE '(^| )- [34]: ' <<<"$td" && fail "forge task-done has no exits 3 and 4; Tasks must drop their cases"
grep -qiE 'respawn on 4' <<<"$td" && fail "Tasks must drop the respawn on exit 4"
grep -qiE 'respawn on 5 respawns only that task' <<<"$td" || fail "Tasks must say a respawn on 5 respawns only that task's agent"
grep -qiE '\b5\b.{0,120}respawn.{0,60}implementer.{0,200}`G/forge-N-<id>\.log`' <<<"$td" ||
  fail "forge task-done exit 5 must respawn the implementer with the printed G/forge-N-<id>.log"
grep -qiE 'park.{0,60}slot' <<<"$td" && fail "Tasks must drop forge task-done's slot park: a test run slot wait never gives up"
grep -qiE '\b1\b.{0,200}Budgets' <<<"$td" || fail "forge task-done exit 1 must run the Budgets path"
grep -qiE 'spawn `forge-implementer`[^.]*`P/plan\.json`, the task ID,[^.]*`P/spec\.json`[^.]*the doc paths[^.]*`P/tasks/<id>\.json`' <<<"$tasks" ||
  fail "Tasks must spawn forge-implementer with P/plan.json, the task ID, P/spec.json, the doc paths and P/tasks/<id>.json"
grep -qiE '(every|each) ready task' <<<"$tasks" || fail "Tasks must spawn forge-implementer for every ready task"
grep -qiE 'recompute the ready set from `P/tasks/`' <<<"$tasks" || fail "Tasks must recompute the ready set from P/tasks/ on resume"
has 'Implementer:? 2 attempts per task' || fail "forge-phase must keep the implementer's 2-attempt budget"
has 'one task at a time after its agent completes.{0,300}forge task-done|forge task-done.{0,300}one task at a time after its agent completes' ||
  fail "the Rules' task test-command rule must run task tests through forge task-done"

fin=${skill#*"## Finish "}
grep -qF 'FORGE_ROOT=R forge finish N' <<<"$fin" || fail "Finish must run FORGE_ROOT=R forge finish N"
grep -qF -- '--accept' <<<"$fin" && fail "Finish must pass forge finish N no --accept"
for g in 'forge test --passed --changed' 'forge commit N result' '`FORGE_ROOT=R forge done N`' 'forge done N --accept'; do
  grep -qF -- "$g" <<<"$fin" && fail "Finish must leave $g to forge finish"
done
grep -qiE 'exit 4' <<<"$fin" && fail "forge finish has no exit 4; Finish must drop its case"
grep -qiE 'test pass' <<<"$fin" && fail "Finish must check no test pass: forge finish has none to check"
grep -qiE 'Exit 1.{0,200}decide it yourself \(the no-ask Rules bullet\)' <<<"$fin" || fail "Finish's exit 1 must decide it yourself (the no-ask Rules bullet) with the list"
grep -qE 'Exit 1[^.]{0,200}Fix' <<<"$fin" && fail "Finish's exit 1 must not go back to the removed Fix step"
grep -qiE 'Exit 2' <<<"$fin" && fail "forge finish N with no --accept has no exit 2; Finish must drop its case"
grep -qiE 'Exit 6.{0,200}Sync again' <<<"$fin" || fail "Finish's exit 6 must run Sync again"

fm='(foreground mode|`?FORGE_FOREGROUND_TASKS`?)'
rules=$(awk '
  /^## / { r = ($0 ~ /^## Rules[[:space:]]*$/); next }
  r && /^- / { if (b != "") print b; b = $0; next }
  r { b = b " " $0 }
  END { if (b != "") print b }
' "$root/skills/forge-phase/SKILL.md" | tr -s ' \t' ' ')
fgt=$(grep -F '`FORGE_FOREGROUND_TASKS`' <<<"$rules" | head -1 || true)
[ -n "$fgt" ] || fail "forge-phase must name \`FORGE_FOREGROUND_TASKS\` in a Rules bullet"
grep -qF 'echo "${FORGE_FOREGROUND_TASKS:-}"' <<<"$fgt" || fail "the foreground-mode rule must read the mode with echo \"\${FORGE_FOREGROUND_TASKS:-}\""
grep -qiE '(every|each) (wake|resume)' <<<"$fgt" || fail "the foreground-mode rule must read the mode on every wake"
grep -qE '(^|[^0-9])1([^0-9]|$)' <<<"$fgt" || fail "the foreground-mode rule must turn on at the value 1"
grep -qF '`run_in_background: false`' <<<"$fgt" || fail "the foreground-mode rule must spawn with run_in_background: false"
grep -qF '`forge-implementer`' <<<"$fgt" || fail "the foreground-mode rule must name forge-implementer"
grep -qiE 'ready tasks?[^.]{0,40}in one message' <<<"$fgt" || fail "the foreground-mode rule must spawn every ready task in one message"
grep -qiE 'message returns[^.]{0,200}task-done|task-done[^.]{0,200}message returns' <<<"$fgt" ||
  fail "the foreground-mode rule must run forge task-done after the message returns"
grep -qiE 'one (task )?at a time' <<<"$fgt" || fail "the foreground-mode rule must run forge task-done one task at a time"
grep -qiE 'respawns?[^.]{0,200}next message' <<<"$fgt" || fail "the foreground-mode rule must put respawns in the next message"
grep -qiE 'newly ready[^.]{0,200}next message' <<<"$fgt" || fail "the foreground-mode rule must put newly ready tasks in the next message"
grep -qiE 'never end(s|ing)? the turn|(do|does) not end the turn' <<<"$fgt" || fail "the foreground-mode rule must never end the turn to wait"
grep -qiE 'foreground mode' <<<"$skill" && ! grep -qiE 'foreground mode' <<<"$fgt" &&
  fail "the foreground-mode rule must name the foreground mode it defines"
grep -F '`run_in_background: true`' <<<"$rules" | grep -F '`forge-implementer`' |
  grep -iE 'end the turn' | grep -qvF 'FORGE_FOREGROUND_TASKS' ||
  fail "forge-phase must keep the default run_in_background: true rule as its own bullet"

grep -qiE "spawn \`forge-implementer\`.{0,120}$fm" <<<"$tasks" || fail "Tasks' implementer spawn must say it runs in the foreground in foreground mode"
grep -qiE "$fm[^.]{0,200}message returns|message returns[^.]{0,200}$fm" <<<"$tasks" ||
  fail "Tasks must run forge task-done after the message returns in foreground mode"
grep -qiE "next message" <<<"$td" || fail "forge task-done's exits must spawn in the next message in foreground mode"
grep -qiE '(background mode|otherwise|outside foreground mode|not in foreground mode)[^.]{0,80}ending the turn with no result line' <<<"$tasks" ||
  fail "Tasks' wait by ending the turn must apply to background mode only"

grep -qE '^ *skills/\*\).*tests/forge-phase-parallel\.test\.sh' "$root/tests/changed.sh" ||
  fail "tests/changed.sh must run forge-phase-parallel for skills/*"
echo "forge-phase-parallel: ok"
