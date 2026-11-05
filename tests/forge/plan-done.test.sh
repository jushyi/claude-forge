#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

fresh
S=$XDG_STATE_HOME/forge/p
git init -q -b main && git config user.name forge && git config user.email forge@example.com
mkdir -p "$S/features/crm-export"
jq -n '{phases: [("core", "api", "ui") | {slug: "export-\(.)", goal: ., spec: [], requirements: [], depends: []}]}' >"$S/features/crm-export/split.json"
"$forge" alloc crm/export >/dev/null
for d in "$S"/phases/0[567]-*; do cp "$fx/state/phases/02-intake-form/"{research,scout}.json "$d/"; done
git add -A && git commit -q -m init
d5=$S/phases/05-export-core d6=$S/phases/06-export-api d7=$S/phases/07-export-ui
untouched() { [ "$(git rev-parse HEAD)" = "$1" ] && [ -z "$(git status --porcelain --untracked-files=all)" ] && [ ! -e .forge/phases ] || fail "$2 leaves HEAD and the repo untouched: $(git log -1 --format=%s) $(git status --porcelain --untracked-files=all)"; }
mkplan() {
  local d=$1 x=$2
  shift 2
  jq -n --argjson x "$x" '{tasks: [{id: "T1", title: "x", files: $ARGS.positional, deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"}]} + $x' --args "$@" >"$d/plan.json"
}
deferred() { jq -sr --arg c "$2" '[.[] | select(.step == "deferred") | .message | fromjson? | select(.check == $c)] | length' "$1/events.jsonl"; }
defs='{"deferred": [{"check": "a", "reason": "ra"}, {"check": "b", "reason": "needs \"real\" db"}]}'
"$forge" event 05 deferred "$(jq -cn '{check: "a", reason: "ra"}')"

if want plan-done-fail; then
head=$(git rev-parse HEAD)
mkplan $d5 "$defs" src/a.ts
jq '.tasks[0].deps = ["T9"] | .tasks[0].dep_reasons = {T9: "symbol x"}' $d5/plan.json >"$tmp/plan" && mv "$tmp/plan" $d5/plan.json
cp $d5/events.jsonl "$tmp/ev"
[ "$(code "$forge" plan-done 05)" = 1 ] || fail "a failing check exits 1: $(cat "$tmp/out")"
grep -qxF "T1 depends on unknown T9" "$tmp/out" || fail "a failing check prints its failures: $(cat "$tmp/out")"
cmp -s $d5/events.jsonl "$tmp/ev" || fail "a failing check logs no deferred event: $(cat $d5/events.jsonl)"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a failing check commits nothing: $(git log -1 --format=%s)"
[ "$(code "$forge" plan-done 99)" = 1 ] || fail "an unknown phase exits 1: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "an unknown phase commits nothing"
ok plan-done-fail
fi

if want plan-done; then
head=$(git rev-parse HEAD)
mkplan $d5 "$defs" src/a.ts
[ "$(code "$forge" plan-done 05)" = 0 ] || fail "a passing check exits 0: $(cat "$tmp/out")"
[ "$(deferred $d5 a)" = 1 ] || fail "an already logged deferred entry is skipped: $(cat $d5/events.jsonl)"
! jq -se 'any(.[]; .step == "deferred" and (.message | fromjson? | .check == "a" and .plan == true))' $d5/events.jsonl >/dev/null ||
  fail "an already logged deferred entry gets no plan: true event: $(cat $d5/events.jsonl)"
[ "$(deferred $d5 b)" = 1 ] || fail "an unlogged deferred entry is logged once: $(cat $d5/events.jsonl)"
[ "$(jq -sr 'map(select(.step == "deferred") | .message) | last' $d5/events.jsonl)" = "$(jq -cn --arg check b --arg reason 'needs "real" db' '{$check, $reason, plan: true}')" ] ||
  fail "the deferred event carries check, reason and plan: true as compact JSON: $(cat $d5/events.jsonl)"
grep -qxF "forge: recorded 05 plan" "$tmp/out" || fail "a passing check records the plan: $(cat "$tmp/out")"
[ "$(jq -sr '[.[] | select(.step == "deferred")] | length' $d5/events.jsonl)" = 2 ] ||
  fail "the state dir events.jsonl holds the deferred events: $(cat $d5/events.jsonl)"
untouched "$head" "the plan step"
tail -n 1 "$tmp/out" | grep -q '^forge: .*05' || fail "plan-done ends with one status line naming the phase: $(cat "$tmp/out")"
ok plan-done
fi

if want plan-done-rerun; then
mkplan $d5 "$defs" src/a.ts
"$forge" plan-done 05 >/dev/null
[ "$(code "$forge" plan-done 05)" = 0 ] || fail "a rerun exits 0: $(cat "$tmp/out")"
[ "$(deferred $d5 a)/$(deferred $d5 b)" = 1/1 ] || fail "a rerun logs no deferred entry twice: $(cat $d5/events.jsonl)"
ok plan-done-rerun
fi

if want plan-done-wait; then
head=$(git rev-parse HEAD)
mkplan $d5 "$defs" src/a.ts
"$forge" plan-done 05 >/dev/null
mkplan $d6 '{}' src/a.ts src/b.ts
[ "$(code "$forge" plan-done 06)" = 3 ] || fail "a waiting check exits 3: $(cat "$tmp/out")"
grep -qxF "waits on 05" "$tmp/out" || fail "a waiting check prints its waits-on line: $(cat "$tmp/out")"
grep -qxF "forge: recorded 06 plan" "$tmp/out" || fail "a waiting check still records the plan: $(cat "$tmp/out")"
untouched "$head" "a waiting plan step"
[ "$(jq -s 'map(select(.step == "deferred")) | length' $d6/events.jsonl)" = 0 ] || fail "a plan without deferred logs no deferred event: $(cat $d6/events.jsonl)"
ok plan-done-wait
fi

if want plan-done-refused; then
head=$(git rev-parse HEAD)
mkplan $d7 '{}' src/c.ts
echo '{"status": "nope"}' >$d7/result.json
[ "$(code "$forge" plan-done 07)" = 1 ] || fail "a refused commit exits 1: $(cat "$tmp/out")"
grep -qF "fails its schema" "$tmp/out" || fail "a refused commit prints why: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused commit moves no HEAD: $(git log -1 --format=%s)"
! grep -qF "forge: recorded 07" "$tmp/out" || fail "a refused commit records nothing: $(cat "$tmp/out")"
rm $d7/result.json
ok plan-done-refused
fi

if want plan-done-help; then
h=$("$forge" plan-done --help)
grep -qxF "Usage: forge plan-done <N>" <<<"$h" || fail "help keeps the usage line: $h"
grep -q '^Exit codes:' <<<"$h" || fail "help lists exit codes: $h"
grep -qF 'P/events.jsonl' <<<"$h" && grep -qF 'P/plan.json' <<<"$h" || fail "help names what it reads and writes: $h"
grep -qF 'STATE/phases/NN-slug/plan.json' <<<"$h" && ! grep -qF '.forge/phases' <<<"$h" || fail "help names the records in STATE, not under .forge: $h"
ok plan-done-help
fi

finish
