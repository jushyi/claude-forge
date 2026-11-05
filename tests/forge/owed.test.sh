#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

f=$XDG_STATE_HOME/forge/p/features/crm-intake
todo=.forge/todo.md
load() { fresh; cp "$fx/owed/$1/verify.json" "$fx/owed/$1/requirements.json" $f/; }
owed() {
  local s=0
  "$forge" owed "$@" >"$tmp/out" 2>"$tmp/err" || s=$?
  [ $s = 0 ] || fail "forge owed $* must exit 0, got $s: $(cat "$tmp/out" "$tmp/err")"
}
refused() {
  cp $f/requirements.json "$tmp/req.before"
  cp $todo "$tmp/todo.before"
  local s=0
  "$forge" owed crm/intake >"$tmp/out" 2>"$tmp/err" || s=$?
  [ $s != 0 ] || fail "$1: forge owed must exit non-zero: $(cat "$tmp/out")"
  grep -q crm-intake/verify.json "$tmp/err" || fail "$1: the message names F/verify.json: $(cat "$tmp/err")"
  [ ! -s "$tmp/out" ] || fail "$1: forge owed prints no requirement lines: $(cat "$tmp/out")"
  cmp -s $f/requirements.json "$tmp/req.before" || fail "$1: requirements.json is left unchanged: $(cat $f/requirements.json)"
  cmp -s $todo "$tmp/todo.before" || fail "$1: todo.md is left unchanged: $(cat $todo)"
}
reqs() { jq -cS . $f/requirements.json; }
expect_reqs() { [ "$(reqs)" = "$(jq -cS . <<<"$1")" ] || fail "$2: $(reqs)"; }
expect_out() { [ "$(cat "$tmp/out")" = "$1" ] || fail "$2: $(cat "$tmp/out")"; }

s5='[skipped] INT-05 run the leads migration on staging (deferred by phase 02: needs the staging database)'
s7='[skipped] INT-07 the confirmation email reaches a real inbox (deferred by phase 03: needs the mail provider)'
tags_reqs=$(jq -n --arg s5 "$s5" --arg s7 "$s7" '{requirements: [
  {id: "INT-01", text: "The form saves a lead.", done: true},
  {id: "INT-02", text: "The API returns the lead.", done: true},
  {id: "INT-03", text: "The lead list shows the new lead.", done: true},
  {id: "INT-04", text: "The intake page renders on mobile.", done: true, concern: "crm:C-03"},
  {id: "INT-05", text: "The leads migration runs.", done: false, owed: {kind: "deferred", check: $s5, owner: "operator"}},
  {id: "INT-06", text: "Duplicate leads merge.", done: false, owed: {kind: "bookkeeping", check: "no manual-test step names INT-06", owner: "operator"}},
  {id: "INT-07", text: "The confirmation email sends.", done: false, owed: {kind: "deferred", check: $s7, owner: "operator"}}]}')
tags_out="INT-01 done
INT-02 done
INT-03 done
INT-04 done
INT-05 owed deferred: $s5
INT-06 owed bookkeeping: no manual-test step names INT-06
INT-07 owed deferred: $s7"
tags_todo="- crm/intake INT-05 owes deferred: $s5
- crm/intake INT-06 owes bookkeeping: no manual-test step names INT-06
- crm/intake INT-07 owes deferred: $s7"

if want owed-usage; then
fresh
for a in "" "crm/intake extra" "crm" "list crm" "list crm/intake extra"; do
  read -ra args <<<"$a"
  s=0
  "$forge" owed "${args[@]}" >"$tmp/out" 2>&1 || s=$?
  [ $s = 2 ] || fail "forge owed $a must print usage and exit 2, got $s: $(cat "$tmp/out")"
done
ok owed-usage
fi

if want owed-missing; then
load tags
rm $f/verify.json
refused "a missing verify.json"
ok owed-missing
fi

if want owed-gaps; then
load gaps
refused "a verify.json with result gaps"
ok owed-gaps
fi

if want owed-tags; then
load tags
cp $todo "$tmp/todo.orig"
cp $f/verify.json "$tmp/verify.orig"
owed crm/intake
expect_reqs "$tags_reqs" "[agent], [agent][carried], [operator] and [watched] steps set done, [skipped] gives deferred, no step (a [note] is not a step) gives bookkeeping, a forge-written owed is dropped on done, done: true with no step is reset"
expect_out "$tags_out" "forge owed prints one line per requirement in file order"
[ "$(cat $todo)" = "$(cat "$tmp/todo.orig")"$'\n'"$tags_todo" ] || fail "forge owed appends one todo line per owed requirement: $(cat $todo)"
cmp -s $f/verify.json "$tmp/verify.orig" || fail "forge owed leaves verify.json unchanged"
ok owed-tags
fi

if want owed-rerun; then
load tags
owed crm/intake
cp $f/requirements.json "$tmp/req.first"
cp $todo "$tmp/todo.first"
owed crm/intake
cmp -s $f/requirements.json "$tmp/req.first" || fail "a rerun leaves requirements.json the same: $(cat $f/requirements.json)"
cmp -s $todo "$tmp/todo.first" || fail "a rerun appends no todo line again: $(cat $todo)"
expect_out "$tags_out" "a rerun prints the same lines"
ok owed-rerun
fi

if want owed-todo-create; then
load tags
rm $todo
owed crm/intake
[ "$(cat $todo)" = "$tags_todo" ] || fail "forge owed creates a missing todo.md with the owed lines: $(cat $todo 2>&1)"
ok owed-todo-create
fi

if want owed-agent-run; then
load agent-run
s3='[skipped] INT-03 run the leads migration on staging (deferred by phase 02: needs the staging database)'
owed crm/intake
expect_reqs "$(jq -n --arg s3 "$s3" '{requirements: [
  {id: "INT-01", text: "The form saves a lead.", done: true},
  {id: "INT-02", text: "The API returns the lead.", done: true},
  {id: "INT-03", text: "The leads migration runs.", done: false, owed: {kind: "deferred", check: $s3, owner: "operator"}}]}')" "operator_ran: false still counts an accepted agent run's [agent] steps"
expect_out "INT-01 done
INT-02 done
INT-03 owed deferred: $s3" "the agent-run lines"
[ "$(tail -n 1 $todo)" = "- crm/intake INT-03 owes deferred: $s3" ] || fail "the agent-run todo line: $(cat $todo)"
ok owed-agent-run
fi

if want owed-kept; then
load kept
cp $todo "$tmp/todo.orig"
owed crm/intake
expect_reqs '{"requirements": [
  {"id": "INT-01", "text": "The form saves a lead.", "done": false, "owed": {"kind": "moved", "check": "lead save moved to crm/routing", "owner": "operator", "until": "release"}},
  {"id": "INT-02", "text": "The API returns the lead.", "done": false, "owed": {"kind": "broken", "check": "GET /leads/1 returns 500 on prod", "owner": "octo"}},
  {"id": "INT-03", "text": "The lead list shows the new lead.", "done": false, "owed": {"kind": "broken", "check": "lead list pagination", "owner": "operator"}},
  {"id": "INT-04", "text": "The intake page renders on mobile.", "done": true}]}' "a moved or broken owed is kept with its owner and until and never set done"
expect_out "INT-01 owed moved: lead save moved to crm/routing
INT-02 owed broken: GET /leads/1 returns 500 on prod
INT-03 owed broken: lead list pagination
INT-04 done" "the kept lines"
[ "$(cat $todo)" = "$(cat "$tmp/todo.orig")
- crm/intake INT-01 owes moved: lead save moved to crm/routing
- crm/intake INT-02 owes broken: GET /leads/1 returns 500 on prod
- crm/intake INT-03 owes broken: lead list pagination" ] || fail "kept owed requirements get todo lines: $(cat $todo)"
ok owed-kept
fi

if want owed-post-ship; then
load tags
jq '.requirements |= map(if IN(.id; "INT-02", "INT-05", "INT-06") then .owner = "post-ship" else . end)' $f/requirements.json >"$tmp/req" && cp "$tmp/req" $f/requirements.json
owed crm/intake
expect_reqs "$(jq '.requirements |= map(
  if .id == "INT-02" then .owner = "post-ship"
  elif .id == "INT-05" then .owner = "post-ship" | .owed = {kind: "deferred", check: "The leads migration runs.", owner: "operator"}
  elif .id == "INT-06" then .owner = "post-ship" | .owed = {kind: "deferred", check: "Duplicate leads merge.", owner: "operator"}
  else . end)' <<<"$tags_reqs")" "a not-done post-ship requirement is owed deferred with its text as the check and owner operator, whether or not a step names it; one whose steps all pass is done"
expect_out "INT-01 done
INT-02 done
INT-03 done
INT-04 done
INT-05 owed deferred: The leads migration runs.
INT-06 owed deferred: Duplicate leads merge.
INT-07 owed deferred: $s7" "post-ship owed lines carry the requirement text"
[ "$(tail -n 3 $todo)" = "- crm/intake INT-05 owes deferred: The leads migration runs.
- crm/intake INT-06 owes deferred: Duplicate leads merge.
- crm/intake INT-07 owes deferred: $s7" ] || fail "post-ship todo lines carry the requirement text: $(cat $todo)"
ok owed-post-ship
fi

if want owed-list; then
load tags
jq '.requirements[5].owner = "post-ship"' $f/requirements.json >"$tmp/req" && cp "$tmp/req" $f/requirements.json
owed crm/intake
list="INT-05 (agent) owed deferred by operator: $s5
INT-06 (post-ship) owed deferred by operator: Duplicate leads merge.
INT-07 (agent) owed deferred by operator: $s7"
"$forge" owed list crm/intake >"$tmp/out" 2>"$tmp/err" || fail "forge owed list crm/intake must exit 0: $(cat "$tmp/err")"
expect_out "$list" "forge owed list <track>/<feature> prints each owed requirement with its owner and the owed owner"
"$forge" owed list >"$tmp/out" 2>"$tmp/err" || fail "forge owed list must exit 0: $(cat "$tmp/err")"
expect_out "$(sed 's|^|crm/intake |' <<<"$list")" "forge owed list prints every feature's owed requirements prefixed with <track>/<feature>"
"$forge" owed list crm/auth >"$tmp/out" 2>"$tmp/err" || fail "forge owed list on a shipped feature reads its archive: $(cat "$tmp/err")"
expect_out "" "a shipped feature with no owed requirement prints nothing"
s=0
"$forge" owed list crm/nope >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] || fail "forge owed list on an unknown feature exits 1, got $s"
grep -q crm/nope "$tmp/err" || fail "the unknown-feature message names it: $(cat "$tmp/err")"
ok owed-list
fi

if want owed-todo-lock; then
load tags
cp $f/requirements.json "$tmp/req.before"
cp $todo "$tmp/todo.before"
l=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/forge.lock || l=$PWD/.forge/forge.lock
s=0
flock "$l" timeout 2 "$forge" owed crm/intake >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 124 ] || fail "forge owed waits for forge.lock, which release_flip holds while it rewrites todo.md: exit $s: $(cat "$tmp/out" "$tmp/err")"
grep -q "waiting for forge.lock" "$tmp/err" || fail "forge owed says it waits for forge.lock: $(cat "$tmp/err")"
cmp -s $f/requirements.json "$tmp/req.before" || fail "forge owed writes no requirements.json before it holds forge.lock: $(cat $f/requirements.json)"
cmp -s $todo "$tmp/todo.before" || fail "forge owed appends no todo line before it holds forge.lock: $(cat $todo)"
ok owed-todo-lock
fi
finish
