#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

bad() {
  local file=$1 filter=$2
  cp "$file" "$tmp/good"
  jq "$filter" "$tmp/good" >"$file"
  [ "$(code "$forge" validate "$file")" = 1 ] || fail "$file with $filter must fail"
  cp "$tmp/good" "$file"
}

loose() {
  local file=$1 filter=$2
  cp "$file" "$tmp/good"
  jq "$filter" "$tmp/good" >"$file"
  [ "$(code "$forge" validate "$file")" = 0 ] || fail "$file with $filter must pass the parse-only check: $(cat "$tmp/out")"
  printf '{' >"$file"
  [ "$(code "$forge" validate "$file")" = 1 ] || fail "unparsable $file must fail"
  grep -qF "$file: not JSON" "$tmp/out" || fail "unparsable $file must fail as not JSON: $(cat "$tmp/out")"
  cp "$tmp/good" "$file"
}

if want outputs; then
fresh
sp=$XDG_STATE_HOME/forge/p
p=$sp/phases/02-intake-form f=$sp/features/crm-intake
mkdir -p $p/research $p/tests $p/fixes $f/research .forge/map
echo '{"questions": [{"question": "Which queue?", "answer": "SQS", "sources": ["docs/queue.md"]}]}' >$p/research/Q1.json
cp $p/research/Q1.json $f/research/Q1.json
echo '{"questions": ["Which queue does intake use?"]}' >$p/gaps.json
echo '{"task": "T1", "files": ["tests/intake.test.ts"], "command": "npm test -- intake", "failure": "expected 201, got 404"}' >$p/tests/T1.json
echo '{"file": "src/intake.ts", "line": 12, "status": "fixed", "summary": "trim the email"}' >$p/fixes/F1.json
esc='{"questions": [{"question": "Queue or cron?", "header": "Trigger", "multiSelect": false, "options": [{"label": "Queue", "description": "Runs per lead"}, {"label": "Cron", "description": "Runs hourly"}]}]}'
echo "$esc" >$p/escalation.json
echo "$esc" >$f/escalation.json
echo '{"focus": "tech", "docs": [{"doc": "STACK", "sections": [{"heading": "Languages and frameworks", "bullets": ["TypeScript"]}]}]}' >.forge/map/tech.json
echo '{"docs": [{"path": "web/.forge/STACK.md", "change": "adds the queue client"}]}' >$f/docs.json
"$forge" validate $p/research/Q1.json $f/research/Q1.json $p/tests/T1.json $p/fixes/F1.json .forge/map/tech.json \
  || fail "agent outputs must validate"
"$forge" validate || fail "gaps, escalation and docs must validate as planning files"
loose $p/research/Q1.json '.questions = [1]'
loose $f/research/Q1.json 'del(.questions)'
loose $p/gaps.json '.questions = [1]'
loose $p/tests/T1.json 'del(.failure)'
mkdir -p $p/tasks
echo '{"id": "T1", "status": "done", "commit": "abc1234"}' >$p/tasks/T1.json
"$forge" validate $p/tasks/T1.json || fail "task record without command, exit and tree must validate: $("$forge" validate $p/tasks/T1.json 2>&1)"
tree=0123456789abcdef0123456789abcdef01234567
cp $p/tests/T1.json "$tmp/test-T1"
cp $p/tasks/T1.json "$tmp/task-T1"
echo "{\"task\": \"T1\", \"files\": [\"tests/intake.test.ts\"], \"command\": \"npm test -- intake\", \"failure\": \"expected 201, got 404\", \"exit\": 1, \"tree\": \"$tree\"}" >$p/tests/T1.json
echo "{\"id\": \"T1\", \"status\": \"done\", \"commit\": \"abc1234\", \"command\": \"npm test -- intake\", \"exit\": 0, \"tree\": \"$tree\"}" >$p/tasks/T1.json
"$forge" validate $p/tests/T1.json $p/tasks/T1.json || fail "test and task records with exit and tree must validate: $("$forge" validate $p/tests/T1.json $p/tasks/T1.json 2>&1)"
bad $p/tasks/T1.json '.tree = "ghijklmnopqrstuvwxyzghijklmnopqrstuvwxyz"'
bad $p/tasks/T1.json '.exit = "1"'
bad $p/tasks/T1.json '.extra = 1'
loose $p/tests/T1.json '.tree = "ghijklmnopqrstuvwxyzghijklmnopqrstuvwxyz"'
loose $p/tests/T1.json '.exit = "1"'
loose $p/tests/T1.json '.extra = 1'
cp "$tmp/test-T1" $p/tests/T1.json
cp "$tmp/task-T1" $p/tasks/T1.json
loose $p/fixes/F1.json '.status = "maybe"'
loose $p/escalation.json '.questions[0].header = "a header too long"'
loose $f/escalation.json '.questions = []'
"$forge" validate $p/escalation.json || fail "escalation without procedure must validate: $("$forge" validate $p/escalation.json 2>&1)"
cp $p/escalation.json "$tmp/esc"
jq '.stakes = "high" | .procedure = ["Open the AWS console", "Create the queue `leads`", "Copy its URL", "Run `forge resume`"]' "$tmp/esc" >$p/escalation.json
"$forge" validate $p/escalation.json || fail "escalation with procedure must validate: $("$forge" validate $p/escalation.json 2>&1)"
loose $p/escalation.json '.procedure = ["Open the AWS console", 1]'
cp "$tmp/esc" $p/escalation.json
loose .forge/map/tech.json '.focus = "concerns"'
loose .forge/map/tech.json '.docs[0].doc = "CONCERNS"'
echo '{"concerns": [{"id": "C-01", "area": "intake", "files": ["src/intake.ts"], "severity": "high", "evidence": ["src/intake.ts:12"], "status": "open", "focus": ["security", "pii"]}]}' >.forge/map/concerns.json
"$forge" validate .forge/map/concerns.json || fail "concern with focus [security, pii] must validate: $("$forge" validate .forge/map/concerns.json 2>&1)"
loose .forge/map/concerns.json '.concerns[0].focus = ["cost"]'
loose $f/docs.json '.docs[0] = {"path": "x"}'
bad $p/plan.json '.tasks[0].requirements = ["x"]'
mkdir -p $f/fixes
echo '{"findings": [{"file": "src/intake.ts", "line": 3, "severity": "medium", "summary": "unchecked null", "fixed": true}]}' >$f/review.json
cp $p/fixes/F1.json $f/fixes/F1.json
"$forge" validate $f/review.json $f/fixes/F1.json || fail "final review and its fixes must validate"
loose $f/fixes/F1.json '.status = "maybe"'
bad $f/review.json '.findings[0].severity = "huge"'
echo '{"brief": ["Owners triage new leads fast", "Dense table, no cards"], "mockups": [{"surface": "intake-form", "path": "mockups/intake-form.html", "approved": true, "notes": ["Larger submit button"]}]}' >$f/design.json
"$forge" validate $f/design.json || fail "design.json must validate named"
"$forge" validate || fail "design.json must validate as a planning file"
loose $f/design.json '.brief = []'
loose $f/design.json '.extra = 1'
loose $f/design.json 'del(.mockups[0].approved)'
mkdir -p $p/review $f/review
echo '{"findings": [{"file": "src/intake.ts", "line": 3, "severity": "high", "summary": "unchecked null", "fixed": false, "source": "reviewer"}]}' >$p/review/reviewer.json
echo '{"findings": [{"file": "src/form.css", "line": 8, "severity": "medium", "summary": "low contrast", "fixed": false, "source": "audit"}]}' >$f/review/audit.json
"$forge" validate $p/review/reviewer.json $f/review/audit.json || fail "fallback review files with a source must validate"
bad $p/review/reviewer.json '.findings[0].source = "sonnet"'
echo '{"manual_test": ["Submit the form"], "result": "gaps", "gaps": [{"phase": "02", "gap": "Email is not trimmed"}]}' >$f/verify.json
"$forge" validate $f/verify.json || fail "verify gaps tagged with a phase must validate"
bad $f/verify.json '.gaps = ["Email is not trimmed"]'
cp $f/verify.json "$tmp/verify"
for filter in '.operator_ran = true' '.operator_ran = false' '.stack_tests = [{"repo": "crm", "command": "npm run test:stack", "passed": true}]' \
  '.review_trees = {"crm": "0123456789abcdef0123456789abcdef01234567", "web": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' \
  '.fixed = [{"phase": "02", "gap": "Phone is not normalized", "fix": "fixes/V1.json"}]'; do
  jq "$filter" "$tmp/verify" >$f/verify.json
  "$forge" validate $f/verify.json || fail "verify.json with $filter must validate: $("$forge" validate $f/verify.json 2>&1)"
done
cp "$tmp/verify" $f/verify.json
bad $f/verify.json '.operator_ran = "true"'
bad $f/verify.json '.stack_tests = [{"repo": "crm", "command": "npm run test:stack"}]'
bad $f/verify.json '.stack_tests = [{"repo": "crm", "command": "npm run test:stack", "passed": true, "extra": 1}]'
bad $f/verify.json '.stack_tests = {"repo": "crm", "command": "npm run test:stack", "passed": true}'
bad $f/verify.json '.review_trees = ["0123456789abcdef0123456789abcdef01234567"]'
bad $f/verify.json '.review_trees = {"crm": 1}'
bad $f/verify.json '.review_trees = {"crm": "HEAD"}'
bad $f/verify.json '.fixed = [{"phase": "02", "gap": "Phone is not normalized"}]'
bad $f/verify.json '.fixed = [{"phase": "02", "gap": "Phone is not normalized", "fix": "fixes/V1.json", "extra": 1}]'
bad $f/verify.json '.fixed = [{"phase": "two", "gap": "Phone is not normalized", "fix": "fixes/V1.json"}]'
[ "$(jq -c .gaps $f/verify.json)" = '[{"phase":"02","gap":"Email is not trimmed"}]' ] || fail "verify.json keeps each gap with its phase: $(jq -c .gaps $f/verify.json)"
ok outputs
fi

if want plan-criteria; then
fresh
pl=$XDG_STATE_HOME/forge/p/phases/02-intake-form/plan.json
jq '.tasks[0].criteria = ["PII-01", "PII-02"] | .tasks[1].criteria = ["PII-03"] | .na_criteria = [{"criterion": "PII-07", "reason": "no third-party processor"}]' $pl >"$tmp/plan" && mv "$tmp/plan" $pl
"$forge" validate $pl || fail "plan with task criteria and na_criteria must validate: $("$forge" validate $pl 2>&1)"
bad $pl '.tasks[0].criteria = ["pii-01"]'
bad $pl '.tasks[0].criteria = ["PII-1"]'
bad $pl '.na_criteria[0].criterion = "PII1"'
bad $pl 'del(.na_criteria[0].reason)'
bad $pl 'del(.na_criteria[0].criterion)'
bad $pl '.na_criteria[0].extra = 1'
for pair in security:SEC rate-limit:RATE scaling:SCALE performance:PERF pii:PII; do
  prefix=${pair#*:} cf=$root/templates/checks/${pair%:*}.md
  [ -f "$cf" ] || fail "$cf must exist"
  grep '^- ' "$cf" | sed -E 's/^- ([^:]*): .*/\1/' >"$tmp/ids"
  [ -s "$tmp/ids" ] || fail "$cf must list criteria bullets"
  ! grep -vxE "$prefix-[0-9]{2}" "$tmp/ids" || fail "$cf bullet IDs must be $prefix-NN"
  if [ "$prefix" = PERF ]; then
    [ "$(cat "$tmp/ids")" = "$(printf 'PERF-%s\n' 01 02 03 04 06 07)" ] || fail "$cf must list exactly PERF-01..04, PERF-06 and PERF-07, PERF-05 retired"
  else
    [ "$(cat "$tmp/ids")" = "$(seq -f "$prefix-%02g" 1 "$(wc -l <"$tmp/ids")")" ] || fail "$cf bullet IDs must run contiguously from $prefix-01"
  fi
done
perf=$root/templates/checks/performance.md
! grep -q p95_ms "$perf" || fail "$perf must not mention p95_ms"
grep -E '^- PERF-06: ' "$perf" | grep -q 'wall-clock' || fail "PERF-06 must block wall-clock assertions"
grep -E '^- PERF-06: ' "$perf" | grep -q 'git hook' || fail "PERF-06 must cover git hooks"
grep -E '^- PERF-07: ' "$perf" | grep -qF -- '- Perf log:' || fail "PERF-07 must name the - Perf log: command"
! grep -qF -- '- Perf tests:' "$perf" || fail "$perf must not name the retired - Perf tests: command"
grep -E '^- PERF-07: ' "$perf" | grep -qF '{metric, value, unit, kind, at}' || fail "PERF-07 metric lines must carry at"
grep -E '^- PERF-07: ' "$perf" | grep -q 'usage log' || fail "PERF-07 metric lines must come from the app's usage logs"
grep -E '^- PERF-07: ' "$perf" | grep -q 'metric line' || fail "PERF-07 must require a metric line"
grep -E '^- PERF-07: ' "$perf" | grep -q 'count' || fail "PERF-07 must prefer a count metric"
ok plan-criteria
fi

if want plan-deferred; then
fresh
pl=$XDG_STATE_HOME/forge/p/phases/02-intake-form/plan.json
"$forge" validate $pl || fail "plan without deferred must validate: $("$forge" validate $pl 2>&1)"
jq '.deferred = [{"check": "Run `gcloud billing budgets list --billing-account=X` and see the 50 USD budget", "reason": "Bash(gcloud billing *)"}]' $pl >"$tmp/plan" && mv "$tmp/plan" $pl
"$forge" validate $pl || fail "plan with deferred must validate: $("$forge" validate $pl 2>&1)"
bad $pl 'del(.deferred[0].check)'
bad $pl 'del(.deferred[0].reason)'
bad $pl '.deferred[0].extra = 1'
bad $pl '.deferred[0].check = 1'
bad $pl '.deferred[0].reason = 1'
bad $pl '.deferred = {"check": "x", "reason": "y"}'
ok plan-deferred
fi

if want quick-validate; then
fresh
sp=$XDG_STATE_HOME/forge/p
q=$tmp/p/.forge/quick/fix-login p=$sp/phases/02-intake-form f=$sp/features/crm-intake
mkdir -p $q/research $q/tests $q/tasks $q/fixes
cp $f/spec.json $q/spec.json
cp $f/research.json $q/research.json
cp $f/research.json $q/research/R1.json
cp $p/plan.json $q/plan.json
echo '{"task": "T1", "files": ["tests/intake.test.ts"], "command": "npm test -- intake", "failure": "expected 201, got 404"}' >$q/tests/T1.json
cp $p/tasks/T1.json $q/tasks/T1.json
cp $p/review.json $q/review.json
echo '{"file": "src/intake.ts", "line": 12, "status": "fixed", "summary": "trim the email"}' >$q/fixes/F1.json
for x in spec research research/R1 plan tests/T1 tasks/T1 review fixes/F1; do
  "$forge" validate $q/$x.json || fail "quick scratch $x.json must validate: $("$forge" validate $q/$x.json 2>&1)"
done
for x in spec plan tasks/T1 review; do
  cp $q/$x.json "$tmp/good"
  jq '. + {"bogus": 1}' "$tmp/good" >$q/$x.json
  [ "$(code "$forge" validate $q/$x.json)" = 1 ] || fail "quick scratch $x.json with an extra key must fail"
  cp "$tmp/good" $q/$x.json
done
for x in research research/R1 tests/T1 fixes/F1; do
  loose $q/$x.json '. + {"bogus": 1}'
done
mkdir -p "$tmp/phases/tracks"
cp -r "$tmp/p" "$tmp/phases/tracks/features"
for x in spec research research/R1 plan tests/T1 tasks/T1 review fixes/F1; do
  (cd "$tmp/phases/tracks/features" && "$forge" validate "$PWD/.forge/quick/fix-login/$x.json") \
    || fail "quick scratch $x.json under a root with phases/ must validate"
done
rm -rf "$tmp/phases"
echo '{"bogus": 1}' >$q/plan.json
"$forge" validate || fail "validate with no files must ignore quick scratch: $("$forge" validate 2>&1)"
a=$sp/features/adhoc-quick
mkdir -p $a/research
cp $f/spec.json $a/spec.json
cp $f/research.json $a/research/R1.json
"$forge" validate $a/spec.json $a/research/R1.json || fail "adhoc-quick feature files must validate"
cp $f/research.json $a/spec.json
[ "$(code "$forge" validate $a/spec.json)" = 1 ] || fail "adhoc-quick spec.json must be checked as feature-spec"
cp $f/spec.json $a/research/R1.json
loose $a/research/R1.json '. + {"bogus": 1}'
ok quick-validate
fi
finish
