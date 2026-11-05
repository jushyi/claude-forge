#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
sp=$XDG_STATE_HOME/forge/p

setfocus() { jq "$2" "$1" >"$tmp/focus" && mv "$tmp/focus" "$1"; }
if want focus-validate; then
fresh
fs=$sp/features/crm-intake/spec.json s=$sp/features/crm-intake/split.json ps=$sp/phases/02-intake-form/spec.json
rs=$sp/features/crm-routing/split.json as=$sp/archive/crm-auth/phases/01-auth-login/spec.json
setfocus $s '(.phases[] | select(.number == "02") | .focus) = ["pii"]'
setfocus $ps '.focus = ["pii"]'
"$forge" validate || fail "focus subsets must validate with no arguments: $("$forge" validate 2>&1)"
"$forge" validate $fs $s $ps || fail "focus subsets must validate named: $("$forge" validate $fs $s $ps 2>&1)"
for v in '["speed"]:speed' '["pii", "pii"]:pii' '"pii":pii'; do
  focus=${v%:*} tag=${v##*:} pairs=("$fs:.focus" "$s:.phases[0].focus")
  [ "$tag" != speed ] || pairs+=("$ps:.focus")
  for pair in "${pairs[@]}"; do
    f=${pair%%:*} path=${pair#*:}
    cp $f "$tmp/good"
    setfocus $f "$path = $focus"
    [ "$(code "$forge" validate $f)" = 1 ] || fail "$f with focus $focus must fail named"
    grep -q "$f" "$tmp/out" && grep -q "$tag" "$tmp/out" || fail "focus $focus failure must name $f and $tag: $(cat "$tmp/out")"
    cp "$tmp/good" $f
  done
done
setfocus $s '(.phases[] | select(.number == "02") | .focus) = ["rate-limit"]'
[ "$(code "$forge" validate)" = 1 ] || fail "split phase focus outside the feature focus must fail with no arguments"
grep -q "split.json" "$tmp/out" && grep -q "rate-limit" "$tmp/out" || fail "split focus failure must name split.json and rate-limit: $(cat "$tmp/out")"
[ "$(cd "$tmp" && code "$forge" validate $s)" = 1 ] || fail "split phase focus outside the feature focus must fail named from another cwd"
grep -q "split.json" "$tmp/out" && grep -q "rate-limit" "$tmp/out" || fail "named split focus failure must name split.json and rate-limit: $(cat "$tmp/out")"
setfocus $s '(.phases[] | select(.number == "02") | .focus) = ["pii"]'
"$forge" validate || fail "restored split focus must validate: $("$forge" validate 2>&1)"
setfocus $rs '.phases[0].focus = ["security"]'
[ "$(code "$forge" validate)" = 1 ] || fail "split phase focus without a sibling spec.json must fail with no arguments"
grep -q "split.json" "$tmp/out" && grep -q "security" "$tmp/out" || fail "focus without a feature spec failure must name split.json and security: $(cat "$tmp/out")"
[ "$(code "$forge" validate $rs)" = 1 ] || fail "split phase focus without a sibling spec.json must fail named"
grep -q "split.json" "$tmp/out" && grep -q "security" "$tmp/out" || fail "named focus without a feature spec failure must name split.json and security: $(cat "$tmp/out")"
setfocus $rs 'del(.phases[0].focus)'
setfocus $ps '.focus = ["rate-limit"]'
[ "$(code "$forge" validate)" = 1 ] || fail "phase spec focus outside the feature focus must fail with no arguments"
grep -q "spec.json" "$tmp/out" && grep -q "rate-limit" "$tmp/out" || fail "phase spec focus failure must name spec.json and rate-limit: $(cat "$tmp/out")"
[ "$(cd "$tmp" && code "$forge" validate $ps)" = 1 ] || fail "phase spec focus outside the feature focus must fail named from another cwd"
grep -q "02-intake-form/spec.json" "$tmp/out" && grep -q "rate-limit" "$tmp/out" || fail "named phase spec focus failure must name spec.json and rate-limit: $(cat "$tmp/out")"
setfocus $ps '.focus = ["pii"]'
"$forge" validate $as || fail "archived phase spec without focus must validate named: $("$forge" validate $as 2>&1)"
setfocus $as '.focus = ["pii"]'
[ "$(code "$forge" validate $as)" = 1 ] || fail "archived phase spec focus without a feature spec must fail named"
grep -q "$as" "$tmp/out" && grep -q "pii" "$tmp/out" || fail "archived focus failure must name the file and pii: $(cat "$tmp/out")"
echo '{"focus": ["pii"]}' >$sp/archive/crm-auth/spec.json
"$forge" validate $as || fail "archived phase spec focus within the archived feature focus must validate named: $("$forge" validate $as 2>&1)"
"$forge" validate --help | grep -q "focus" || fail "validate help describes the focus checks"
ok focus-validate
fi

if want budget-dropped; then
fresh
fs=$sp/features/crm-intake/spec.json s=$sp/features/crm-intake/split.json
entry='{"provider":"gcloud","service":"Vertex AI","monthly_usd":100,"thresholds":[50,90],"service_id":"services/1234-5678-9ABC","billing_account":"123456-789ABC-DEF012","project":"my-project"}'
cp $fs "$tmp/good"
setfocus $fs '.focus += ["budget"]'
[ "$(code "$forge" validate $fs)" = 1 ] || fail "feature spec with focus budget must fail"
grep -q "budget" "$tmp/out" || fail "focus budget failure must name budget: $(cat "$tmp/out")"
jq --argjson e "$entry" '.budget = [$e]' $fs >"$tmp/focus" && mv "$tmp/focus" $fs
[ "$(code "$forge" validate $fs)" = 1 ] || fail "feature spec with focus budget and a budget entry must fail"
cp "$tmp/good" $fs
jq --argjson e "$entry" '.budget = [$e]' $fs >"$tmp/focus" && mv "$tmp/focus" $fs
[ "$(code "$forge" validate $fs)" = 1 ] || fail "feature spec with a budget key must fail"
grep -q "budget" "$tmp/out" || fail "budget key failure must name budget: $(cat "$tmp/out")"
cp "$tmp/good" $fs
setfocus $fs '.focus += ["budget"]'
setfocus $s '(.phases[] | select(.number == "02") | .focus) = ["budget"]'
[ "$(code "$forge" validate $s)" = 1 ] || fail "split phase with focus budget must fail even when the feature focus holds budget"
grep -q "split.json" "$tmp/out" || fail "split focus budget failure must name split.json: $(cat "$tmp/out")"
ok budget-dropped
fi

if want targets-validate; then
fresh
es=$sp/features/crm-export/spec.json
mkdir -p $sp/features/crm-export
echo '{"decisions": [], "spec": [], "focus": ["scaling"]}' >$es
[ "$(code "$forge" validate $es)" = 1 ] || fail "feature spec with scaling focus and no targets must fail"
grep -q "$es" "$tmp/out" && grep -q "targets" "$tmp/out" || fail "scaling without targets failure must name $es and targets: $(cat "$tmp/out")"
echo '{"decisions": [], "spec": [], "focus": ["performance"]}' >$es
"$forge" validate $es || fail "feature spec with performance focus and no targets must validate: $("$forge" validate $es 2>&1)"
echo '{"decisions": [], "spec": [], "focus": ["performance"], "targets": {"p95_ms": 200}}' >$es
[ "$(code "$forge" validate $es)" = 1 ] || fail "feature spec with p95_ms targets must fail"
grep -q "$es" "$tmp/out" && grep -qE "p95_ms|targets" "$tmp/out" || fail "p95_ms targets failure must name $es and p95_ms or targets: $(cat "$tmp/out")"
ps=$sp/phases/02-intake-form/spec.json
cp $ps "$tmp/good"
jq '.targets = {"rps": 100}' "$tmp/good" >$ps
"$forge" validate $ps || fail "phase spec with rps targets must validate: $("$forge" validate $ps 2>&1)"
cp "$tmp/good" $ps
echo '{"decisions": [], "spec": [], "focus": ["pii"]}' >$es
[ "$(code "$forge" validate $es)" = 1 ] || fail "feature spec with pii focus and no pii_fields must fail"
grep -q "$es" "$tmp/out" && grep -q "pii_fields" "$tmp/out" || fail "pii without pii_fields failure must name $es and pii_fields: $(cat "$tmp/out")"
echo '{"decisions": [], "spec": [], "focus": ["scaling", "pii"], "targets": {"rps": 100}, "pii_fields": ["name", "email"]}' >$es
"$forge" validate $es || fail "feature spec with targets and pii_fields must validate: $("$forge" validate $es 2>&1)"
for v in 'targets:{}' 'targets:{"rps": 100, "qps": 5}' 'targets:{"rps": 1.5}' 'targets:{"rps": "100"}' 'pii_fields:[]' 'pii_fields:["name", "name"]'; do
  field=${v%%:*} val=${v#*:}
  echo "{\"decisions\": [], \"spec\": [], \"$field\": $val}" >$es
  [ "$(code "$forge" validate $es)" = 1 ] || fail "feature spec with $field $val must fail"
  grep -q "$es" "$tmp/out" && grep -q "$field" "$tmp/out" || fail "$field $val failure must name $es and $field: $(cat "$tmp/out")"
done
echo '{"decisions": [], "spec": []}' >$es
"$forge" validate $es || fail "untagged feature spec with neither field must validate: $("$forge" validate $es 2>&1)"
ok targets-validate
fi
finish
