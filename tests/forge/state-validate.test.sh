#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
sp=$XDG_STATE_HOME/forge/p
declare -A why=()
named() {
  local f
  for f in "${!why[@]}"; do
    grep -qF "  ${f#"$1"}::" "$tmp/out" || fail "${why[$f]} failure must name ${f#"$1"}: $(cat "$tmp/out")"
  done
}

if want validate; then
fresh

"$forge" validate || fail "fixture must validate"
"$forge" validate .forge/tracks/crm.json $sp/phases/02-intake-form/events.jsonl || fail "named files must validate"
jq '.tasks[0].files = []' $sp/phases/02-intake-form/plan.json >"$tmp/plan" && mv "$tmp/plan" $sp/phases/02-intake-form/plan.json
[ "$(code "$forge" validate)" = 1 ] || fail "plan task without files must fail"
grep -q "plan.json" "$tmp/out" || fail "failure must name plan.json: $(cat "$tmp/out")"
fresh
jq '.phases[0].slug = "routing-rules\n"' $sp/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" $sp/features/crm-routing/split.json
[ "$(code "$forge" validate)" = 1 ] || fail "slug with a trailing newline must fail its ^...$ pattern"
grep -q "split.json::\$.phases\[0\].slug" "$tmp/out" || fail "trailing newline failure must name split.json: $(cat "$tmp/out")"
fresh
echo '{' >$sp/phases/02-intake-form/events.jsonl
[ "$(code "$forge" validate $sp/phases/02-intake-form/events.jsonl)" = 1 ] || fail "events that are not JSON lines must fail"
[ "$(cat "$tmp/out")" = "$sp/phases/02-intake-form/events.jsonl: not JSON lines" ] || fail "names only the bad events file: $(cat "$tmp/out")"
fresh
py=$(sed -n '1s/^#!\([^ ]*\).*/\1/p' "$(readlink -f "$(command -v check-jsonschema)")")
mkdir -p "$tmp/cj"
printf '#!%s\n' "$tmp/cj/python" >"$tmp/cj/check-jsonschema"
printf '#!/usr/bin/env bash\necho "$*" >>%q\nexec %q "$@"\n' "$tmp/cj.log" "$py" >"$tmp/cj/python"
chmod +x "$tmp/cj/check-jsonschema" "$tmp/cj/python"
PATH=$tmp/cj:$PATH "$forge" validate || fail "fixture must validate through the located python"
[ "$(wc -l <"$tmp/cj.log")" = 1 ] || fail "forge validate checks every schema in one process: $(cat "$tmp/cj.log")"
jq '.tasks[0].files = []' $sp/phases/02-intake-form/plan.json >"$tmp/plan.json"
cp "$tmp/plan.json" $sp/phases/02-intake-form/plan.json
check-jsonschema --schemafile "$FORGE_SCHEMAS/plan.schema.json" $sp/phases/02-intake-form/plan.json >"$tmp/want" 2>&1 || true
[ "$(code "$forge" validate $sp/phases/02-intake-form/plan.json)" = 1 ] || fail "an invalid plan fails"
diff -u "$tmp/want" "$tmp/out" || fail "forge validate prints check-jsonschema's errors"
fresh
s=$sp/features/crm-routing/split.json
"$forge" validate $s || fail "split without creates or consumes must validate: $("$forge" validate $s 2>&1)"
jq '.phases[0].creates = ["schemas/lead.schema.json", "forge alloc"] | .phases[1].consumes = ["schemas/lead.schema.json", " forge alloc "]' $s >"$tmp/split" && mv "$tmp/split" $s
"$forge" validate || fail "split with creates and consumes must validate with no arguments: $("$forge" validate 2>&1)"
"$forge" validate $s || fail "split with creates and consumes must validate named: $("$forge" validate $s 2>&1)"
cp $s "$tmp/good"
why=() i=0
for key in creates consumes; do
  for item in 1 '""' '"   "' null; do
    printf -v d $sp/features/crm-split%02d $((i += 1))
    cp -r $sp/features/crm-routing $d
    jq ".phases[0].$key = [\"lead-api\", $item]" "$tmp/good" >$d/split.json
    why[$d/split.json]="split phase $key item $item"
  done
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "split phase creates and consumes bad items must fail named"
named ""
[ "$(code "$forge" validate)" = 1 ] || fail "split phase creates and consumes bad items must fail with no arguments"
named ""
fresh
mkdir -p Aerospace/.git web-2/.git
fs=()
for repo in Aerospace web-2; do
  cp -r $sp/features/crm-routing $sp/features/crm-repo-$repo
  cp -r $sp/phases/02-intake-form $sp/phases/02-repo-$repo
  jq --arg r $repo '.phases[0].repo = $r' $sp/features/crm-routing/split.json >$sp/features/crm-repo-$repo/split.json
  jq --arg r $repo '.repo = $r' $sp/phases/02-intake-form/spec.json >$sp/phases/02-repo-$repo/spec.json
  jq --arg r $repo '.tasks[0].repo = $r' $sp/phases/02-intake-form/plan.json >$sp/phases/02-repo-$repo/plan.json
  fs+=($sp/features/crm-repo-$repo/split.json $sp/phases/02-repo-$repo/spec.json $sp/phases/02-repo-$repo/plan.json)
done
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "repos Aerospace and web-2 in split.json, spec.json and plan.json must validate: $(cat "$tmp/out")"
fresh
rj=$sp/phases/02-intake-form/result.json
cp $rj "$tmp/result.json"
fs=() i=0
for filter in '.deferred = [{check: "Tap Save on a phone and see the toast", reason: "needs a device"}]' '.deferred = []'; do
  printf -v d $sp/phases/02-rdef%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq "$filter" "$tmp/result.json" >$d/result.json
  fs+=($d/result.json)
done
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "result.json with each deferred list must validate: $(cat "$tmp/out")"
why=() i=0
for filter in '.deferred = [{check: "Tap Save"}]' '.deferred = [{reason: "needs a device"}]' \
  '.deferred = [{check: "", reason: "needs a device"}]' '.deferred = [{check: "Tap Save", reason: "needs a device", by: "operator"}]' \
  '.deferred = {check: "Tap Save", reason: "needs a device"}'; do
  printf -v d $sp/phases/02-rbad%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq "$filter" "$tmp/result.json" >$d/result.json
  why[$d/result.json]="result.json with $filter"
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "result.json with each bad deferred must fail"
named ""
jq '.perf = {metric: "intake-save", unit: "ms", kind: "time", before: 240, after: 90.5, hotspot: "renderForm", next_hotspot: "fetchLeads", next_share: 0.4, path_ms: 88}' "$tmp/result.json" >$rj
[ "$(code "$forge" validate $rj)" = 1 ] || fail "result.json with perf must fail"
grep -qF "result.json::" "$tmp/out" || fail "perf failure must name result.json: $(cat "$tmp/out")"
fresh
tj=.forge/tracks/crm.json
jq '.triaged = {date: "2026-10-12", report: "/tmp/report.md"}' $tj >"$tmp/crm" && mv "$tmp/crm" $tj
[ "$(code "$forge" validate $tj)" = 1 ] || fail "track with triaged must fail"
grep -qF "crm.json::" "$tmp/out" || fail "triaged failure must name crm.json: $(cat "$tmp/out")"
fresh
jq '.gate = {tag: "v1-gate"}' $tj >"$tmp/crm" && mv "$tmp/crm" $tj
[ "$(code "$forge" validate $tj)" = 1 ] || fail "track with gate must fail"
grep -qF "crm.json::" "$tmp/out" || fail "gate failure must name crm.json: $(cat "$tmp/out")"
fresh
ok validate
fi
if want dep-reasons; then
fresh
pj=$sp/phases/02-intake-form/plan.json
jq '.tasks[0].dep_reasons = {} | .tasks[1].dep_reasons = {T1: "symbol leads table"}' $pj >"$tmp/plan.json"
cp "$tmp/plan.json" $pj
fs=($pj) i=0
for filter in '.tasks[1].dep_reasons = {T1: "file db/leads.sql"}' 'del(.tasks[].dep_reasons)'; do
  printf -v d $sp/phases/02-dok%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq "$filter" "$tmp/plan.json" >$d/plan.json
  fs+=($d/plan.json)
done
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "plans with dep_reasons, a file reason and none written before dep_reasons must validate: $(cat "$tmp/out")"
why=() i=0
for filter in '.tasks[1].dep_reasons = {X1: "symbol leads table"}' \
  '.tasks[1].dep_reasons = {T1: "uses the leads table"}' '.tasks[1].dep_reasons = {T1: "file "}' '.tasks[1].dep_reasons = {T1: "symbol "}' \
  '.tasks[1].dep_reasons = ["T1"]'; do
  printf -v d $sp/phases/02-dbad%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq "$filter" "$tmp/plan.json" >$d/plan.json
  why[$d/plan.json]=$filter
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "plans with each bad dep_reasons must fail"
named ""
fresh
ok dep-reasons
fi
if want review-deferred; then
fresh
rv=$sp/phases/02-intake-form/review.json
cp $rv "$tmp/review.json"
fs=() i=0
for owner in 'phase 07' 'phase 315' todo; do
  printf -v d $sp/phases/02-owner%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq --arg o "$owner" '.findings[0] += {fixed: false, deferred: {owner: $o, reason: "touches the router phase 07 rewrites"}}' "$tmp/review.json" >$d/review.json
  fs+=($d/review.json)
done
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "review findings deferred to phase 07, phase 315 and todo must validate: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "review findings deferred to phase 07, phase 315 and todo must validate with no arguments: $(cat "$tmp/out")"
why=() i=0
for filter in '.deferred = {owner: "phase 7", reason: "later"}' '.deferred = {owner: "Phase 07", reason: "later"}' \
  '.deferred = {owner: "later", reason: "later"}' '.deferred = {owner: "phase 07 ", reason: "later"}' \
  '.deferred = {owner: "todo ", reason: "later"}' '.deferred = {owner: "", reason: "later"}' '.deferred = {owner: 7, reason: "later"}' \
  '.deferred = {owner: "todo", reason: ""}' '.deferred = {owner: "todo"}' '.deferred = {reason: "later"}' \
  '.deferred = {owner: "todo", reason: "later", by: "operator"}' '.deferred = "phase 07"' '.deferred = [{owner: "todo", reason: "later"}]'; do
  printf -v d $sp/phases/02-defer%02d $((i += 1))
  cp -r $sp/phases/02-intake-form $d
  jq ".findings[0] |= ($filter)" "$tmp/review.json" >$d/review.json
  why[$d/review.json]="review finding with $filter"
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "review findings with each bad deferred must fail"
named ""
fresh
ok review-deferred
fi
if want requirement-owner; then
fresh
rq=$sp/features/crm-routing/requirements.json
"$forge" validate $rq || fail "a requirement without owner must validate"
for o in agent operator post-ship; do
  jq --arg o "$o" '.requirements[0].owner = $o' $rq >"$tmp/req" && cp "$tmp/req" $rq
  "$forge" validate $rq || fail "a requirement with owner $o must validate: $(cat "$tmp/out")"
done
for o in '"later"' '""' null; do
  jq ".requirements[0].owner = $o" $rq >"$tmp/req" && cp "$tmp/req" $rq
  [ "$(code "$forge" validate $rq)" = 1 ] || fail "a requirement with owner $o must fail"
  grep -q "requirements.json::\$.requirements\[0\].owner" "$tmp/out" || fail "the owner failure names the field: $(cat "$tmp/out")"
done
ok requirement-owner
fi
if want requirement-accepted; then
fresh
rq=$sp/features/crm-routing/requirements.json
jq '.requirements[0] += {done: true, accepted: "fine without the toast"}' $rq >"$tmp/req" && cp "$tmp/req" $rq
"$forge" validate $rq || fail "a requirement with accepted must validate: $(cat "$tmp/out")"
for a in '""' 7 null; do
  jq ".requirements[0].accepted = $a" $rq >"$tmp/req" && cp "$tmp/req" $rq
  [ "$(code "$forge" validate $rq)" = 1 ] || fail "a requirement with accepted $a must fail"
  grep -q "requirements.json::\$.requirements\[0\].accepted" "$tmp/out" || fail "the accepted failure names the field: $(cat "$tmp/out")"
done
ok requirement-accepted
fi
if want owed; then
fresh
rq=$sp/features/crm-routing/requirements.json
cp $rq "$tmp/requirements.json"
owed='.requirements[0].owed = {kind: "deferred", check: "Tap Save on a phone and see the toast", owner: "operator"}'
fs=() i=0
for filter in "$owed" "$owed | .requirements[0].owed.until = \"release\"" \
  "$owed | .requirements[0].owed.kind = \"bookkeeping\"" "$owed | .requirements[0].owed.kind = \"moved\"" \
  "$owed | .requirements[0].owed.kind = \"broken\" | .requirements[0].owed.owner = \"crm-intake\"" \
  "$owed | .requirements[0].concern = \"crm:C-03\""; do
  printf -v d $sp/features/crm-owok%02d $((i += 1))
  cp -r $sp/features/crm-routing $d
  jq "$filter" "$tmp/requirements.json" >$d/requirements.json
  fs+=($d/requirements.json)
done
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "requirements.json with each owed must validate: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "requirements.json with each owed must validate with no arguments: $(cat "$tmp/out")"
why=() i=0
for filter in "$owed | del(.requirements[0].owed.kind)" "$owed | del(.requirements[0].owed.check)" \
  "$owed | del(.requirements[0].owed.owner)" "$owed | .requirements[0].owed.check = \"\"" \
  "$owed | .requirements[0].owed.owner = \"\"" "$owed | .requirements[0].owed.kind = \"later\"" \
  "$owed | .requirements[0].owed.until = \"deploy\"" "$owed | .requirements[0].owed.until = \"\"" \
  "$owed | .requirements[0].owed.reason = \"needs a device\"" '.requirements[0].owed = "deferred"'; do
  printf -v d $sp/features/crm-owbad%02d $((i += 1))
  cp -r $sp/features/crm-routing $d
  jq "$filter" "$tmp/requirements.json" >$d/requirements.json
  why[$d/requirements.json]="requirements.json with $filter"
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "requirements.json with each bad owed must fail"
named ""
[ "$(code "$forge" validate)" = 1 ] || fail "requirements.json with each bad owed must fail with no arguments"
named ""
fresh
lr=$sp/features/crm-owed/requirements.json
ar=$sp/archive/crm-gone/requirements.json
mkdir -p $sp/features/crm-owed $sp/archive/crm-gone
owed='{kind: "deferred", check: "Tap Save on a phone and see the toast", owner: "operator"}'
for r in $lr $ar; do
  jq -n '{final_review: [], pr: null, date: "2026-10-01"}' >"${r%/*}/ship.json"
  jq -n '{requirements: [{id: "OWE-01", text: "Ran.", done: true}, {id: "OWE-02", text: "Not run.", done: false}]}' >$r
  [ "$(code "$forge" validate $r)" = 1 ] || fail "shipped $r with a not-done requirement and no owed must fail: $(cat "$tmp/out")"
  grep -q "^$r: .*OWE-02" "$tmp/out" || fail "not-done failure must name $r and OWE-02: $(cat "$tmp/out")"
  ! grep -q "OWE-01" "$tmp/out" || fail "a done requirement without owed must pass in $r: $(cat "$tmp/out")"
  jq -n "{requirements: [{id: \"OWE-01\", text: \"Ran.\", done: true, owed: $owed}, {id: \"OWE-02\", text: \"Ran.\", done: true}]}" >$r
  [ "$(code "$forge" validate $r)" = 1 ] || fail "shipped $r with a done requirement that has an owed must fail: $(cat "$tmp/out")"
  grep -q "^$r: .*OWE-01" "$tmp/out" || fail "done-with-owed failure must name $r and OWE-01: $(cat "$tmp/out")"
  ! grep -q "OWE-02" "$tmp/out" || fail "a done requirement without owed must pass in $r: $(cat "$tmp/out")"
  jq -n "{requirements: [{id: \"OWE-01\", text: \"Not run.\", done: false, owed: $owed}, {id: \"OWE-02\", text: \"Ran.\", done: true}]}" >$r
  [ "$(code "$forge" validate $r)" = 0 ] || fail "shipped $r with a not-done requirement that has an owed must pass: $(cat "$tmp/out")"
  rm "${r%/*}/ship.json"
  jq -n "{requirements: [{id: \"OWE-01\", text: \"Not run.\", done: false}, {id: \"OWE-02\", text: \"Ran.\", done: true, owed: $owed}]}" >$r
  [ "$(code "$forge" validate $r)" = 0 ] || fail "unshipped $r must pass whatever its owed: $(cat "$tmp/out")"
done
fresh
mkdir -p $sp/archive/crm-gone
jq -n '{final_review: [], pr: null, date: "2026-10-01"}' >$sp/archive/crm-gone/ship.json
jq -n '{requirements: [{id: "OWE-01", text: "Not run.", done: false}]}' >$ar
git init -q -b main
git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
jq '.goal = "New goal"' .forge/tracks/crm.json >"$tmp/crm" && mv "$tmp/crm" .forge/tracks/crm.json
[ "$(code "$forge" commit crm "track goal")" = 0 ] || fail "an archived shipped feature failing the owed check must not block an unrelated commit: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm): track goal" ] || fail "the unrelated commit must land: $(git log -1 --format=%s)"
[ "$(code "$forge" validate $ar)" = 1 ] || fail "the archived shipped feature must still fail the owed check: $(cat "$tmp/out")"
grep -q "^$ar: .*OWE-01" "$tmp/out" || fail "archived failure must name $ar and OWE-01: $(cat "$tmp/out")"
fresh
ok owed
fi
if want prev-records; then
fresh
pd=$sp/phases/02-intake-form
cp $pd/review.json $pd/review.prev.json
[ "$(code "$forge" validate $pd/review.prev.json)" = 0 ] || fail "a valid review.prev.json must validate named: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "a valid review.prev.json must validate with no arguments: $(cat "$tmp/out")"
cp $pd/review.json $pd/verify.prev.json
[ "$(code "$forge" validate $pd/verify.prev.json)" = 0 ] || fail "verify.prev.json has no schema, so any parsable record must pass: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "a parsable verify.prev.json must print nothing: $(cat "$tmp/out")"
echo '{' >$pd/verify.prev.json
[ "$(code "$forge" validate $pd/verify.prev.json)" = 1 ] || fail "an unparsable verify.prev.json must fail named"
grep -qF verify.prev.json "$tmp/out" || fail "the unparsable failure must name verify.prev.json: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 1 ] || fail "an unparsable verify.prev.json must fail with no arguments"
grep -qF verify.prev.json "$tmp/out" || fail "the unparsable failure with no arguments must name verify.prev.json: $(cat "$tmp/out")"
rm $pd/verify.prev.json
why=() i=0
for filter in 'del(.findings)' '.findings = [{file: "src/form.ts"}]' '.findings = "none"'; do
  printf -v d $sp/phases/02-rprev%02d $((i += 1))
  cp -r $pd $d
  jq "$filter" $pd/review.json >$d/review.prev.json
  why[$d/review.prev.json]="review.prev.json with $filter"
done
[ "$(code "$forge" validate "${!why[@]}")" = 1 ] || fail "review.prev.json with each bad record must fail"
named ""
cp $pd/plan.json $pd/review.prev.json
[ "$(code "$forge" validate $pd/review.prev.json)" = 1 ] || fail "review.prev.json holding a plan record must fail as review"
grep -qF "  $pd/review.prev.json::" "$tmp/out" || fail "review.prev.json must fail against the review schema: $(cat "$tmp/out")"
fresh
pd=$sp/phases/02-intake-form
echo '{"passed": "yes"}' >$pd/verify.json
echo '{"passed": "yes"}' >$pd/verify.prev.json
[ "$(code "$forge" validate $pd/verify.json $pd/verify.prev.json)" = 0 ] || fail "a legacy phase verify.json and verify.prev.json must not fail forge validate: $(cat "$tmp/out")"
! grep -q "no schema" "$tmp/out" || fail "a legacy phase verify record must not die with no schema: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "forge validate with no arguments must pass beside legacy phase verify records: $(cat "$tmp/out")"
! grep -q "no schema" "$tmp/out" || fail "forge validate with no arguments must not die with no schema: $(cat "$tmp/out")"
"$forge" validate --help >"$tmp/out"
! grep -q "phase-verify" "$tmp/out" || fail "validate help lists no phase-verify row: $(cat "$tmp/out")"
fresh
ok prev-records
fi
if want plan-test; then
fresh
pl=$sp/phases/02-intake-form/plan.json
jq 'del(.tasks[0].test)' $pl >"$tmp/plan" && mv "$tmp/plan" $pl
[ "$(code "$forge" validate $pl)" = 0 ] || fail "a plan task with no test must validate: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "a plan task with no test must validate with no arguments: $(cat "$tmp/out")"
jq '.tasks[1] |= del(.exempt_reason) | .tasks[1].test = "exempt"' $pl >"$tmp/plan" && mv "$tmp/plan" $pl
[ "$(code "$forge" validate $pl)" = 0 ] || fail "an exempt plan task with no exempt_reason must validate: $(cat "$tmp/out")"
jq '.tasks[1].test = "bogus"' $pl >"$tmp/plan" && mv "$tmp/plan" $pl
[ "$(code "$forge" validate $pl)" = 1 ] || fail "a plan task with test bogus must fail: $(cat "$tmp/out")"
grep -q "plan.json" "$tmp/out" || fail "the bogus test failure must name plan.json: $(cat "$tmp/out")"
fresh
ok plan-test
fi
if want parse-only; then
fresh
echo '{"a": 1}' >"$tmp/free.json"
[ "$(code "$forge" validate "$tmp/free.json")" = 0 ] || fail "a parsable JSON file with no schema must pass: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "a parsable JSON file with no schema must print nothing: $(cat "$tmp/out")"
echo '{' >"$tmp/broken.json"
[ "$(code "$forge" validate "$tmp/broken.json")" = 1 ] || fail "an unparsable JSON file with no schema must fail"
grep -qF "$tmp/broken.json" "$tmp/out" || fail "the parse failure must name the file: $(cat "$tmp/out")"
[ "$(code "$forge" validate "$tmp/nowhere.json")" = 1 ] || fail "a missing file must fail"
printf '{"a": 1}\n[2]\n"x"\n' >"$tmp/free.jsonl"
[ "$(code "$forge" validate "$tmp/free.jsonl")" = 0 ] || fail "a .jsonl whose every line is a JSON value must pass: $(cat "$tmp/out")"
printf '{"a": 1}\n{\n' >"$tmp/broken.jsonl"
[ "$(code "$forge" validate "$tmp/broken.jsonl")" = 1 ] || fail "a .jsonl with an unparsable line must fail"
grep -qF "$tmp/broken.jsonl" "$tmp/out" || fail "the .jsonl parse failure must name the file: $(cat "$tmp/out")"
printf '{}\n{\n{}\n' >"$tmp/midbroken.jsonl"
[ "$(code "$forge" validate "$tmp/midbroken.jsonl")" = 1 ] || fail "a .jsonl with an unparsable line before a parsable one must fail"
grep -qF "$tmp/midbroken.jsonl" "$tmp/out" || fail "the mid-file .jsonl parse failure must name the file: $(cat "$tmp/out")"
pd=$sp/phases/02-intake-form fd=$sp/features/crm-routing
echo '{"note": "no schema"}' >$pd/verify.json
echo '[]' >$pd/scout.json
echo '{"anything": 1}' >$pd/gaps.json
echo '{"anything": 1}' >$fd/settled.json
echo '{"anything": 1}' >$fd/docs.json
mkdir -p $pd/tests $pd/fixes $pd/diagnoses
echo '{"anything": 1}' >$pd/tests/T1.json
echo '{"anything": 1}' >$pd/fixes/F1.json
echo '{"anything": 1}' >$pd/diagnoses/D1.json
echo '{"time": "yesterday"}' >>$pd/events.jsonl
echo '1' >>$pd/events.jsonl
fs=($pd/verify.json $pd/scout.json $pd/gaps.json $fd/settled.json $fd/docs.json $pd/tests/T1.json $pd/fixes/F1.json $pd/diagnoses/D1.json $pd/events.jsonl)
[ "$(code "$forge" validate "${fs[@]}")" = 0 ] || fail "parsable records whose schema is gone must pass named: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "parsable records whose schema is gone must print nothing: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 0 ] || fail "parsable records whose schema is gone must pass with no arguments: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "parsable records whose schema is gone must print nothing with no arguments: $(cat "$tmp/out")"
echo '{' >$pd/verify.json
[ "$(code "$forge" validate $pd/verify.json)" = 1 ] || fail "an unparsable phase verify.json must fail named"
grep -qF "$pd/verify.json" "$tmp/out" || fail "the parse failure must name verify.json: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 1 ] || fail "an unparsable phase verify.json must fail with no arguments"
grep -qF verify.json "$tmp/out" || fail "the parse failure with no arguments must name verify.json: $(cat "$tmp/out")"
fresh
ev=$sp/phases/02-intake-form/events.jsonl
printf '{"time": "2026-09-20T12:00:00Z", "step": "x",\n"message": "y"}\n' >>$ev
[ "$(code "$forge" validate $ev)" = 1 ] || fail "an event split over two lines must fail, every line being checked on its own"
grep -qF "$ev" "$tmp/out" || fail "the split event failure must name events.jsonl: $(cat "$tmp/out")"
fresh
ok parse-only
fi
if want rekey-repos; then
fresh
echo '{"repos": ["../a/web", "../b/web/"], "note": "no schema"}' >.forge/repos.json
[ "$(code "$forge" validate .forge/repos.json)" = 1 ] || fail "repos.json entries sharing a basename must fail named"
[ "$(cat "$tmp/out")" = ".forge/repos.json: more than one entry has the basename web" ] || fail "repos.json is parse-checked and keeps its basename check: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 1 ] || fail "repos.json entries sharing a basename must fail with no arguments"
[ "$(cat "$tmp/out")" = "repos.json: more than one entry has the basename web" ] || fail "repos.json with no arguments keeps its basename check: $(cat "$tmp/out")"
echo '{"repos": ["../a/web", "../b/api"], "note": "no schema"}' >.forge/repos.json
[ "$(code "$forge" validate .forge/repos.json)" = 0 ] || fail "repos.json with distinct basenames must pass: $(cat "$tmp/out")"
fresh
ok rekey-repos
fi
if want rekey-dropped; then
fresh
echo '{"repos": [{"window": {"tz": "America/Nowhere"}}]}' >.forge/release.json
b=$sp/features/crm-routing/build.json
jq '.steps.S09 = {state: "done"} | .deviations = [] | .steps.S02.met = ["Ladder"] | .log[0].evidence = ["../out.jpg"]' $b >"$tmp/rk.json" && mv "$tmp/rk.json" $b
p=$sp/features/crm-routing/procedure.json
jq '.acceptance[0].requirements = ["ROUTE-09"] | .steps += [.steps[0]]' $p >"$tmp/rk.json" && mv "$tmp/rk.json" $p
[ "$(code "$forge" validate)" = 0 ] || fail "release.json with an unknown tz and build.json naming steps absent from procedure.json must validate with no arguments: $(cat "$tmp/out")"
w=$tmp/p/.claude/worktrees/crm-routing
mkdir -p "$w" && echo 'gitdir: /nowhere' >"$w/.git"
[ "$(code "$forge" validate .forge/release.json $b $p)" = 0 ] || fail "release.json with an unknown tz and build.json naming steps absent from procedure.json must validate named: $(cat "$tmp/out")"
echo '{' >$b
[ "$(code "$forge" validate $b)" = 1 ] || fail "build.json is still JSON-checked"
[ "$(cat "$tmp/out")" = "$b: not JSON" ] || fail "an unparsable build.json fails as not JSON: $(cat "$tmp/out")"
fresh
ok rekey-dropped
fi
if want rekey-focus; then
fresh
ps=$sp/phases/02-intake-form/spec.json
jq '.focus = ["rate-limit"] | .repo = "-web"' $ps >"$tmp/rk.json" && mv "$tmp/rk.json" $ps
[ "$(code "$forge" validate $ps)" = 1 ] || fail "a phase spec focus outside its feature focus must fail named"
[ "$(cat "$tmp/out")" = "$ps: focus rate-limit not in the focus of $sp/features/crm-intake/spec.json" ] || fail "a phase spec is parse-checked and keeps its focus check: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 1 ] || fail "a phase spec focus outside its feature focus must fail with no arguments"
[ "$(cat "$tmp/out")" = "$ps: focus rate-limit not in the focus of $sp/features/crm-intake/spec.json" ] || fail "a phase spec with no arguments keeps its focus check: $(cat "$tmp/out")"
jq '.focus = ["pii"]' $ps >"$tmp/rk.json" && mv "$tmp/rk.json" $ps
[ "$(code "$forge" validate $ps)" = 0 ] || fail "a phase spec focus inside its feature focus must pass: $(cat "$tmp/out")"
fresh
ok rekey-focus
fi
if want schema-set; then
for n in track requirements feature-spec split plan task result review feature-verify ship; do
  [ -f "$FORGE_SCHEMAS/$n.schema.json" ] || fail "kept schema $n.schema.json must remain"
done
for n in build concerns debug debugs design diagnosis docs escalation events fix gaps history map merge perf phase-spec phase-verify procedure quicks release repos research scout settled test; do
  [ ! -e "$FORGE_SCHEMAS/$n.schema.json" ] || fail "schema $n.schema.json is read by no code and must be deleted"
done
ok schema-set
fi
if want tracks-anchor; then
fresh
mkdir $sp/phases/99-closed-tracks
cp $sp/phases/02-intake-form/spec.json $sp/phases/99-closed-tracks/spec.json
"$forge" validate $sp/phases/99-closed-tracks/spec.json || fail "a phase dir ending in tracks validates as a phase spec: $("$forge" validate $sp/phases/99-closed-tracks/spec.json 2>&1)"
(cd "$sp" && "$forge" validate phases/99-closed-tracks/spec.json) || fail "a phase dir ending in tracks named from inside the state dir validates as a phase spec"
"$forge" validate || fail "validate with no arguments checks a phase dir ending in tracks as a phase spec: $("$forge" validate 2>&1)"
"$forge" validate .forge/tracks/crm.json "$PWD/.forge/tracks/crm.json" || fail "track files still validate as tracks"
fresh
ok tracks-anchor
fi
if want validate-md; then
fresh
printf '# Rules\n\n- Keep each rule short.\n  Say it once.\n' >.forge/RULES.md
[ "$(code "$forge" validate .forge/RULES.md)" = 0 ] || fail "a passing linked doc must validate: $(cat "$tmp/out")"
[ ! -s "$tmp/out" ] || fail "a passing linked doc prints nothing: $(cat "$tmp/out")"
printf '# Stack\n\n- Bash runs every script.\n- Bash was the only shell.\n' >.forge/STACK.md
[ "$(code "$forge" validate .forge/STACK.md)" = 0 ] || fail "a linked doc over a limit only warns and exits 0: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = 'forge: warning: .forge/STACK.md:4: history phrase "was "' ] || fail "a linked doc over a limit prints the exact warning line: $(cat "$tmp/out")"
want=()
for n in PROJECT RULES REJECTED ARCHITECTURE STACK CONVENTIONS TESTING INTEGRATIONS; do
  printf '# %s\n\n- Short.\n- It used to be long.\n' $n >.forge/$n.md
  want+=("forge: warning: .forge/$n.md:4: history phrase \"used to\"")
done
[ "$(code "$forge" validate .forge/{PROJECT,RULES,REJECTED,ARCHITECTURE,STACK,CONVENTIONS,TESTING,INTEGRATIONS}.md)" = 0 ] || fail "every linked doc name must be linted: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf '%s\n' "${want[@]}")" ] || fail "each linked doc name is linted in order: $(cat "$tmp/out")"
mkdir -p Aerospace/.forge
cp .forge/RULES.md Aerospace/.forge/TESTING.md
[ "$(code "$forge" validate "$PWD/.forge/RULES.md" Aerospace/.forge/TESTING.md)" = 0 ] || fail "linked docs under any .forge/ must be linted: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "forge: warning: $PWD/.forge/RULES.md:4: history phrase \"used to\""$'\n''forge: warning: Aerospace/.forge/TESTING.md:4: history phrase "used to"' ] || fail "the warning line names the path as passed: $(cat "$tmp/out")"
for x in .forge/STATE.md .forge/CONCERNS.md .forge/todo.md .forge/seeds.md docs/RULES.md; do
  mkdir -p "${x%/*}"
  printf -- '- It was long.\n' >$x
  [ "$(code "$forge" validate $x)" = 1 ] || fail "$x is not a linked doc and must fail: $(cat "$tmp/out")"
  [ "$(cat "$tmp/out")" = "$x: not JSON" ] || fail "$x is not a linked doc and is only parse-checked: $(cat "$tmp/out")"
done
printf '# Rules\n\n- Keep each rule short.\n' >.forge/RULES.md
printf '# Stack\n\n- Bash runs every script.\n- Bash was the only shell.\n' >.forge/STACK.md
[ "$(code "$forge" validate .forge/STACK.md .forge/tracks/crm.json)" = 0 ] || fail "a warned linked doc with a valid JSON path exits 0: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = 'forge: warning: .forge/STACK.md:4: history phrase "was "' ] || fail "a warned linked doc with a valid JSON path prints only the warning line: $(cat "$tmp/out")"
[ "$(code "$forge" validate .forge/STACK.md $sp/phases/02-intake-form/missing.json)" = 1 ] || fail "a warned linked doc with an unreadable JSON path still exits 1: $(cat "$tmp/out")"
pj=$sp/phases/02-intake-form/plan.json
jq '.tasks[0].files = []' $pj >"$tmp/plan.json"
cp "$tmp/plan.json" $pj
check-jsonschema --schemafile "$FORGE_SCHEMAS/plan.schema.json" $pj >"$tmp/want" 2>&1 || true
[ "$(code "$forge" validate .forge/RULES.md $pj)" = 1 ] || fail "a passing linked doc with a bad JSON path must exit 1: $(cat "$tmp/out")"
diff -u "$tmp/want" "$tmp/out" || fail "a passing linked doc with a bad JSON path prints only the schema errors"
"$forge" validate --help >"$tmp/help"
for s in 'forge: warning: <path>:<line>: <rule>' 'over 8 KB' 'bullet over 300 characters' 'history phrase' INTEGRATIONS; do
  grep -qF "$s" "$tmp/help" || fail "forge validate --help must name $s"
done
fresh
ok validate-md
fi
finish
