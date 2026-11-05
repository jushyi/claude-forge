#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

R=$tmp/p
P=$XDG_STATE_HOME/forge/p/phases/03-intake-api
W=$R/.claude/worktrees/crm-intake-03

setup() {
  fresh
  jq -n '{tasks: [
    {id: "T1", title: "Lead endpoint", files: ["src/api.ts", "tests/api.test.sh"], deps: [], test: "test-first"},
    {id: "T2", title: "Other side", files: ["src/other.ts"], deps: [], test: "exempt", exempt_reason: "glue"}]}' >"$P/plan.json"
  mkdir -p src tests && echo base >src/other.ts && echo keep >tests/keep.sh && echo readme >README.md
  git init -q -b main
  git config user.name forge && git config user.email forge@example.com
  echo .claude/worktrees/ >>.git/info/exclude
  git add -A && git commit -q -m init
  git branch forge/crm-intake
  git worktree add -q -b forge/crm-intake-03 "$W" forge/crm-intake
  G=$(git -C "$W" rev-parse --absolute-git-dir)
  whead=$(git -C "$W" rev-parse HEAD)
  mhead=$(git -C "$R" rev-parse main)
}
td() { (cd "$R" && FORGE_ROOT=$R "$forge" task-done 03 "$@" </dev/null); }
ev() { jq -cn --arg s "$1" --arg m "$2" '{time: "2026-10-21T00:00:00Z", step: $s, message: $m}' >>"$P/events.jsonl"; }
irec() { mkdir -p "$P/tasks"; jq -n --arg i "${2:-T1}" "{id: \$i} + $1" >"$P/tasks/${2:-T1}.json"; }
last() { tail -n 1 "$tmp/out"; }
wkept() { [ "$(git -C "$W" rev-parse HEAD)" = "$whead" ] || fail "$1 must not commit in W: $(git -C "$W" log --oneline -3)"; }
mkept() { [ "$(git -C "$R" rev-parse main)" = "$mhead" ] && ! grep -q '^forge: recorded ' "$tmp/out" || fail "$1 must not run forge commit: $(git -C "$R" log --oneline -3 main) $(cat "$tmp/out")"; }
recorded() { grep -qxF "forge: recorded 03 $1" "$tmp/out" && [ "$(git -C "$R" rev-parse main)" = "$mhead" ] && [ ! -e "$R/.forge/phases" ] || fail "forge commit 03 $1 must run and record in the state dir, main unchanged: $(cat "$tmp/out") $(git -C "$R" log --oneline -3 main)"; }
shows() { git -C "$1" show --name-only --format= "$2" | sort; }

if want replan-pass; then
setup
ev replan "new plan"
echo api >"$W/src/api.ts"
irec '{status: "done", exit: 0}'
[ "$(code td T1)" = 0 ] || fail "a done task record after a replan must commit: $(cat "$tmp/out")"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" rev-parse HEAD^)" = "$whead" ] || fail "a pass after a replan commits once in W"
[ "$(git -C "$W" log -1 --format=%s)" = "feat(intake-api): Lead endpoint" ] || fail "W commit subject: $(git -C "$W" log -1 --format=%s)"
[ "$(shows "$W" HEAD)" = src/api.ts ] || fail "W commit files: $(shows "$W" HEAD)"
[ "$(jq -cS . "$P/tasks/T1.json")" = "$(jq -cnS --arg c "$sha" '{id: "T1", status: "done", exit: 0, commit: $c}')" ] || fail "task record after a replan pass: $(cat "$P/tasks/T1.json")"
recorded T1
last | grep -qF "$sha" || fail "the final line names the commit: $(last)"
ok replan-pass
fi

if want legacy-test-first; then
setup
[ "$(jq -r '.tasks[0].test' "$P/plan.json")" = test-first ] || fail "the plan's T1 stays marked test-first"
echo api >"$W/src/api.ts"
irec '{status: "done", exit: 0, command: "touch rerun; exit 1"}'
[ "$(code td T1)" = 0 ] || fail "a test-first task done with exit 0, no must-fail event and no test record must commit: $(cat "$tmp/out")"
[ ! -e "$W/rerun" ] || fail "done with exit 0 passes without a rerun"
[ ! -e "$P/events.jsonl" ] || [ "$(jq -s '[.[] | select(.step == "must-fail")] | length' "$P/events.jsonl")" = 0 ] || fail "task-done logs no must-fail: $(cat "$P/events.jsonl")"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" rev-parse HEAD^)" = "$whead" ] || fail "the task commits once in W"
[ "$(shows "$W" HEAD)" = src/api.ts ] || fail "W commit files: $(shows "$W" HEAD)"
[ "$(jq -r .commit "$P/tasks/T1.json")" = "$sha" ] || fail "the task record's commit: $(cat "$P/tasks/T1.json")"
recorded T1
last | grep -qF "$sha" || fail "the final line names the commit: $(last)"
ok legacy-test-first
fi

if want implementer-done; then
setup
echo api >"$W/src/api.ts"
echo 'test -f src/api.ts' >"$W/tests/api.test.sh"
echo 'readme and api' >"$W/README.md"
echo t2 >>"$W/src/other.ts"
echo scratch >"$W/scratch.txt"
irec '{status: "done", exit: 0, command: "touch rerun; exit 1", deviation: "Also updated README.md to list the endpoint."}'
[ "$(code td T1)" = 0 ] || fail "an implementer done with exit 0 must commit: $(cat "$tmp/out")"
[ ! -e "$W/rerun" ] || fail "done with exit 0 passes without a rerun"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" rev-parse HEAD^)" = "$whead" ] || fail "the implementer commits once in W"
[ "$(git -C "$W" log -1 --format=%s)" = "feat(intake-api): Lead endpoint" ] || fail "W commit subject: $(git -C "$W" log -1 --format=%s)"
[ "$(shows "$W" HEAD)" = "$(printf '%s\n' README.md src/api.ts tests/api.test.sh)" ] || fail "only plan and deviation files are committed: $(shows "$W" HEAD)"
[ "$(git -C "$W" status --porcelain -- src/other.ts)" = " M src/other.ts" ] || fail "another task's dirty file stays unstaged: $(git -C "$W" status --porcelain)"
[ "$(git -C "$W" status --porcelain -- scratch.txt)" = "?? scratch.txt" ] || fail "an unnamed file stays untracked: $(git -C "$W" status --porcelain)"
[ -z "$(git -C "$W" diff --cached --name-only)" ] || fail "nothing stays staged: $(git -C "$W" diff --cached --name-only)"
[ "$(jq -r .commit "$P/tasks/T1.json")" = "$sha" ] || fail "the task record's commit: $(cat "$P/tasks/T1.json")"
[ "$(jq -r .deviation "$P/tasks/T1.json")" = "Also updated README.md to list the endpoint." ] || fail "the task record keeps its fields"
recorded T1
last | grep -qF "$sha" || fail "the final line names the commit: $(last)"
ok implementer-done
fi

if want failed-rerun; then
setup
echo api >"$W/src/api.ts"
irec '{status: "done", exit: 1, command: "echo still red; exit 1"}'
[ "$(code td T1)" = 5 ] || fail "a failed rerun must exit 5: $(cat "$tmp/out")"
grep -q 'still red' "$G/forge-03-T1.log" || fail "a failed rerun saves its output to G/forge-03-T1.log"
last | grep -qF "$G/forge-03-T1.log" || fail "the final line names the log: $(last)"
wkept failed-rerun; mkept failed-rerun
[ "$(git -C "$W" status --porcelain -- src/api.ts)" = "?? src/api.ts" ] || fail "a failed rerun stages nothing"
rm "$P/tasks/T1.json" "$G/forge-03-T1.log"
[ "$(code td T1)" = 5 ] || fail "a missing record has no test command and must exit 5: $(cat "$tmp/out")"
grep -q 'no test command' "$G/forge-03-T1.log" || fail "no test command is saved to G/forge-03-T1.log"
! grep -q 'tests/T1.json' "$G/forge-03-T1.log" || fail "the no-command log names only the task record: $(cat "$G/forge-03-T1.log")"
[ ! -e "$P/tasks/T1.json" ] || fail "a missing record stays missing"
wkept no-command; mkept no-command
irec '{status: "done", command: "test -f src/api.ts"}'
[ "$(code td T1)" = 0 ] || fail "a record whose test command passes must commit: $(cat "$tmp/out")"
[ "$(jq -r .commit "$P/tasks/T1.json")" = "$(git -C "$W" rev-parse --short HEAD)" ] || fail "the record's commit: $(cat "$P/tasks/T1.json")"
ok failed-rerun
fi

if want status-failed; then
setup
irec '{status: "failed", deviation: "cannot reach the db"}'
[ "$(code td T1)" = 5 ] || fail "status failed must exit 5: $(cat "$tmp/out")"
grep -q 'cannot reach the db' "$G/forge-03-T1.log" || fail "status failed saves the record to G/forge-03-T1.log"
last | grep -qF "$G/forge-03-T1.log" || fail "the final line names the log: $(last)"
wkept status-failed; mkept status-failed
ok status-failed
fi

if want gave-up; then
setup
echo api >"$W/src/api.ts"
for g in 'forge: gave up waiting for a test slot' 'forge: gave up waiting for test memory' 'forge: gave up waiting for CPU pressure after 3 min (72.50)' 'forge: gave up waiting for test CPUs after 3 min (03 T2)'; do
  rm -f "$G/forge-03-T1.log"
  irec "{status: \"done\", exit: 75, command: \"echo '$g' >&2; exit 75\"}"
  [ "$(code td T1)" = 5 ] || fail "a test run that prints $g fails like any test, exit 5: $(cat "$tmp/out")"
  ! grep -qi 'park' "$tmp/out" || fail "task-done prints no park advice for $g: $(cat "$tmp/out")"
  grep -qF "$g" "$G/forge-03-T1.log" || fail "the give-up output $g is saved to G/forge-03-T1.log"
  last | grep -qF 'respawn the implementer: its test command failed (exit 75)' || fail "the final line names the respawn for $g: $(last)"
done
wkept gave-up; mkept gave-up
! grep -qiE '^  7 |park|gave up' "$root/bin/forge.d/help/task-done.txt" || fail "task-done help names no exit 7, slot park or give-up: $(grep -niE '^  7 |park|gave up' "$root/bin/forge.d/help/task-done.txt")"
ok gave-up
fi

if want commit-set; then
setup
echo api >"$W/src/api.ts"
echo t2 >>"$W/src/other.ts"
irec '{status: "done", exit: 0}' T2
[ "$(code td T2)" = 0 ] || fail "an exempt task done with exit 0 must commit: $(cat "$tmp/out")"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" log -1 --format=%s)" = "feat(intake-api): Other side" ] || fail "W commit subject: $(git -C "$W" log -1 --format=%s)"
[ "$(shows "$W" HEAD)" = src/other.ts ] || fail "T2 commits only its own file: $(shows "$W" HEAD)"
[ "$(git -C "$W" status --porcelain -- src/api.ts)" = "?? src/api.ts" ] || fail "T1's file stays untracked"
[ "$(jq -cS . "$P/tasks/T2.json")" = "$(jq -cnS --arg c "$sha" '{id: "T2", status: "done", exit: 0, commit: $c}')" ] || fail "T2 record: $(cat "$P/tasks/T2.json")"
recorded T2
rm "$W/src/api.ts"
irec '{status: "done", exit: 0}' T2
whead=$(git -C "$W" rev-parse HEAD)
[ "$(code td T2)" = 0 ] || fail "a done task with nothing to commit must exit 0: $(cat "$tmp/out")"
wkept nothing-listed
[ "$(jq -r .commit "$P/tasks/T2.json")" = "$sha" ] || fail "with no listed files the commit is W's HEAD: $(cat "$P/tasks/T2.json")"
ok commit-set
fi

if want state-file; then
setup
S=$XDG_STATE_HOME/forge/p
sp=$S/features/crm-routing/procedure.json
jq --arg s "$sp" '.tasks += [
  {id: "T3", title: "Procedure", files: [$s], deps: [], test: "exempt", exempt_reason: "configuration"},
  {id: "T4", title: "Mixed", files: [$s, "src/api.ts"], deps: [], test: "exempt", exempt_reason: "glue"}]' "$P/plan.json" >"$tmp/plan" && mv "$tmp/plan" "$P/plan.json"
jq . "$sp" >"$tmp/sproc" && mv "$tmp/sproc" "$sp"
irec '{status: "done", exit: 0}' T3
[ "$(code td T3)" = 0 ] || fail "a task whose only file is under S must exit 0: $(cat "$tmp/out")"
wkept state-only
[ "$(jq -r .commit "$P/tasks/T3.json")" = "$(git -C "$W" rev-parse --short HEAD)" ] || fail "an S-only task records W's HEAD: $(cat "$P/tasks/T3.json")"
recorded T3
[ -f "$sp" ] || fail "the S file stays in place"
echo api >"$W/src/api.ts"
irec '{status: "done", exit: 0}' T4
[ "$(code td T4)" = 0 ] || fail "a task with S and W files must commit: $(cat "$tmp/out")"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" rev-parse HEAD^)" = "$whead" ] || fail "the mixed task commits once in W"
[ "$(shows "$W" HEAD)" = src/api.ts ] || fail "the mixed task commits only its W file: $(shows "$W" HEAD)"
[ "$(jq -r .commit "$P/tasks/T4.json")" = "$sha" ] || fail "the mixed task record's commit: $(cat "$P/tasks/T4.json")"
recorded T4
ok state-file
fi

if want rename; then
setup
git -C "$W" mv src/other.ts src/side.ts
irec '{status: "done", exit: 0, deviation: "Renamed src/other.ts to src/side.ts."}' T2
[ "$(code td T2)" = 0 ] || fail "a done task with a staged rename must commit: $(cat "$tmp/out")"
[ "$(git -C "$W" diff --no-renames --name-status HEAD^ HEAD)" = "$(printf 'D\tsrc/other.ts\nA\tsrc/side.ts')" ] || fail "the commit holds both paths of the rename: $(git -C "$W" diff --no-renames --name-status HEAD^ HEAD)"
! git -C "$W" cat-file -e HEAD:src/other.ts 2>/dev/null || fail "the commit drops the rename's source"
[ -z "$(git -C "$W" status --porcelain)" ] || fail "nothing of the rename stays staged: $(git -C "$W" status --porcelain)"
ok rename
fi

if want unmet; then
setup
unrec() { jq -cS 'del(.commit)' "$P/tasks/$1.json"; }
echo api >"$W/src/api.ts"
echo t2 >>"$W/src/other.ts"
irec '{status: "failed", deviation: "cannot reach the db", command: "touch rerun; exit 1"}'
[ "$(code td T1 --unmet "attempts ran out")" = 0 ] || fail "task-done --unmet must exit 0: $(cat "$tmp/out")"
[ ! -e "$W/rerun" ] || fail "task-done --unmet runs no test"
[ "$(unrec T1)" = "$(jq -cnS '{id: "T1", status: "unmet", reason: "attempts ran out"}')" ] || fail "the unmet record replaces the old one: $(cat "$P/tasks/T1.json")"
sha=$(git -C "$W" rev-parse --short HEAD)
[ "$(git -C "$W" rev-parse HEAD^)" = "$whead" ] || fail "--unmet commits the changed planned files once in W"
[ "$(git -C "$W" log -1 --format=%s)" = "feat(intake-api): Lead endpoint" ] || fail "W commit subject: $(git -C "$W" log -1 --format=%s)"
[ "$(shows "$W" HEAD)" = src/api.ts ] || fail "--unmet commits only the task's changed planned files: $(shows "$W" HEAD)"
[ "$(git -C "$W" status --porcelain -- src/other.ts)" = " M src/other.ts" ] || fail "another task's dirty file stays unstaged: $(git -C "$W" status --porcelain)"
recorded T1
git -C "$W" checkout -q -- src/other.ts
whead=$(git -C "$W" rev-parse HEAD)
[ "$(code td T2 --unmet "no time left")" = 0 ] || fail "task-done --unmet with no changed files must exit 0: $(cat "$tmp/out")"
wkept unmet-none
[ "$(unrec T2)" = "$(jq -cnS '{id: "T2", status: "unmet", reason: "no time left"}')" ] || fail "the unmet record with no changed files: $(cat "$P/tasks/T2.json")"
recorded T2
[ "$(code td T1 --unmet "")" = 2 ] || fail "an empty --unmet reason is a usage error: $(cat "$tmp/out")"
[ "$(code td T1 --unmet)" = 2 ] || fail "a missing --unmet reason is a usage error: $(cat "$tmp/out")"
mkept unmet-usage
ok unmet
fi

if want unmet-done; then
setup
stub_run_claude
echo '[]' >"$CLAUDE_AGENTS"
git worktree add -q "$R/.claude/worktrees/crm-intake" forge/crm-intake
echo api >"$W/src/api.ts" && git -C "$W" add -A && git -C "$W" commit -q -m api
jq -n '{status: "done", summary: "api"}' >"$P/result.json"
irec '{status: "unmet", reason: "attempts ran out"}' T1
irec '{status: "done", exit: 0}' T2
s=0; (cd "$R" && FORGE_ROOT=$R "$forge" done 03 </dev/null) >"$tmp/out" 2>&1 || s=$?
[ $s = 0 ] || fail "forge done with one task unmet and the rest done must pass: $s $(cat "$tmp/out")"
! grep -qF "not committed through forge task-done" "$tmp/out" || fail "an unmet record counts as done: $(cat "$tmp/out")"
git -C "$R" merge-base --is-ancestor forge/crm-intake-03 forge/crm-intake || fail "forge done merges the phase with an unmet task"
ok unmet-done
fi

finish
