#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

S=$XDG_STATE_HOME/forge/p
fpl=$fx/state/phases/02-intake-form/plan.json fps=$fx/state/phases/02-intake-form/spec.json


if want check; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json
[ "$("$forge" check 02)" = "plan ok" ] || fail "fixture plan passes check"
jq '.tasks[].requirements = [] | .tasks[1].deps = ["T9"] | .tasks[1].dep_reasons = {T9: "symbol leads table"}' "$pl" >"$tmp/plan" && mv "$tmp/plan" "$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "uncovered requirement and unknown dep must fail"
grep -qxF "INT-01 maps to no task" "$tmp/out" || fail "check names the uncovered requirement: $(cat "$tmp/out")"
grep -qxF "T2 depends on unknown T9" "$tmp/out" || fail "check names the unknown dep: $(cat "$tmp/out")"
jq '.tasks[0].files = []' "$pl" >"$tmp/plan" && mv "$tmp/plan" "$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "task without files must fail"
grep -q "plan.json" "$tmp/out" || fail "schema failure names plan.json"
[ "$(code "$forge" check 03)" = 1 ] || fail "phase without plan must fail"
[ "$(code "$forge" check 99)" = 1 ] || fail "unknown phase must fail"
pt() { jq "$1" "$fpl" >"$tmp/plan" && mv "$tmp/plan" "$pl"; }
pt '.'
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "the fixture plan passes check: $(cat "$tmp/out")"
pt '.tasks += [{id: "T3", title: "Form copy", files: ["src/form.ts", "src/copy.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "glue", requirements: []}]'
[ "$(code "$forge" check 02)" = 1 ] || fail "independent tasks sharing a file must fail: $(cat "$tmp/out")"
[ "$(grep -c . "$tmp/out")" = 1 ] || fail "check prints one line per sharing pair: $(cat "$tmp/out")"
grep -w T2 "$tmp/out" | grep -w T3 | grep -F src/form.ts | grep -qvF src/copy.ts || fail "the sharing failure names both tasks and only the shared file: $(cat "$tmp/out")"
pt '.tasks += [{id: "T3", title: "Form copy", files: ["src/form.ts"], deps: ["T2"], dep_reasons: {T2: "file src/form.ts"}, test: "exempt", exempt_reason: "glue", requirements: []}]'
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "tasks linked by a dep may share a file: $(cat "$tmp/out")"
pt '.tasks += [{id: "T3", title: "Lead copy", files: ["db/leads.sql"], deps: ["T2"], dep_reasons: {T2: "symbol submitLead"}, test: "exempt", exempt_reason: "glue", requirements: []}]'
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "tasks linked transitively (T3 -> T2 -> T1) may share a file: $(cat "$tmp/out")"
pt '.tasks[1].repo = "web" | .tasks += [{id: "T3", title: "Form copy", repo: "api", files: ["src/form.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "glue", requirements: []}]'
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "the same path in two task repos is not shared: $(cat "$tmp/out")"
pt '.tasks[1].repo = "web" | .tasks += [{id: "T3", title: "Form copy", repo: "web", files: ["src/form.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "glue", requirements: []}]'
[ "$(code "$forge" check 02)" = 1 ] || fail "independent tasks sharing a file in one named repo must fail: $(cat "$tmp/out")"
grep -w T2 "$tmp/out" | grep -w T3 | grep -qF web:src/form.ts || fail "a shared file in a named repo prints as <repo>:<file>: $(cat "$tmp/out")"
"$forge" check --help | grep -qi "dependency path" || fail "check help describes the parallel-safety failure"
ok check
fi

if want check-reasons; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json
pt() { jq "$1" "$fpl" >"$tmp/plan" && mv "$tmp/plan" "$pl"; }
ck() { s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?; }
pt '.tasks[1].dep_reasons = {}'
ck
[ $s = 1 ] || fail "a dep with no dep_reasons entry must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(grep -c . "$tmp/err")" = 1 ] || fail "a missing reason prints one stderr line: $(cat "$tmp/err")"
grep -w T2 "$tmp/err" | grep -qw T1 || fail "a missing reason names both tasks: $(cat "$tmp/err")"
! grep -qx "plan ok" "$tmp/out" || fail "a missing reason must not pass: $(cat "$tmp/out")"
pt '.tasks[1].dep_reasons = {} | .tasks += [{id: "T3", title: "Lead copy", files: ["src/copy.ts"], deps: ["T1", "T2"], dep_reasons: {T1: "symbol leads table"}, test: "exempt", exempt_reason: "glue", requirements: []}]'
ck
[ $s = 1 ] || fail "deps with no reasons must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(grep -c . "$tmp/err")" = 2 ] || fail "each dep without a reason prints its own line: $(cat "$tmp/err")"
grep -w T2 "$tmp/err" | grep -qw T1 || fail "T2's missing reason on T1 is named: $(cat "$tmp/err")"
grep -w T3 "$tmp/err" | grep -qw T2 || fail "T3's missing reason on T2 is named: $(cat "$tmp/err")"
pt 'del(.tasks[0].dep_reasons)'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "T1 has no dep_reasons" ] || fail "a task with no dep_reasons must fail naming it, got $s: $(cat "$tmp/out" "$tmp/err")"
pt '.tasks[1].deps = ["T9"] | .tasks[1].dep_reasons = {}'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "T2 depends on unknown T9" ] || fail "an unknown dep fails before the reason check: $(cat "$tmp/err")"
pt '.tasks[1].dep_reasons = {T1: "file src/form.ts"}'
ck
[ $s = 1 ] || fail "a file reason absent from the earlier task must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(grep -c . "$tmp/err")" = 1 ] || fail "a bad file reason prints one stderr line: $(cat "$tmp/err")"
grep -w T2 "$tmp/err" | grep -w T1 | grep -qF src/form.ts || fail "a bad file reason names both tasks and the file: $(cat "$tmp/err")"
pt '.tasks[1].dep_reasons = {T1: "file db/leads.sql"}'
ck
[ $s = 1 ] || fail "a file reason absent from the later task must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -w T2 "$tmp/err" | grep -w T1 | grep -qF db/leads.sql || fail "a bad file reason names both tasks and the file: $(cat "$tmp/err")"
pt '.tasks[0].repo = "api" | .tasks[1].repo = "web" | .tasks[0].files += ["src/form.ts"] | .tasks[1].dep_reasons = {T1: "file src/form.ts"}'
ck
[ $s = 1 ] || fail "a file reason naming the same path in two task repos must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -w T2 "$tmp/err" | grep -w T1 | grep -qF src/form.ts || fail "a cross-repo file reason names both tasks and the file: $(cat "$tmp/err")"
pt '.tasks[0].files += ["src/form.ts"] | .tasks[1].dep_reasons = {T1: "file src/form.ts"}'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a file reason both tasks plan passes: $(cat "$tmp/out" "$tmp/err")"
pt '.'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a symbol reason passes: $(cat "$tmp/out" "$tmp/err")"
pt '.tasks[1].deps = [] | .tasks[1].dep_reasons = {}'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "no deps with {} reasons passes: $(cat "$tmp/out" "$tmp/err")"
"$forge" check --help | grep -q "dep_reasons" || fail "check help describes the dep_reasons check"
ok check-reasons
fi

if want check-criteria; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json ps=$S/phases/02-intake-form/spec.json
cp "$pl" "$tmp/plan02"
jq '.tasks[0].criteria = ["PII-05"]' "$tmp/plan02" >"$pl"
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] || fail "an uncovered focus criterion must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -qxF "PII-03 maps to no task and is not n/a" "$tmp/err" || fail "check names the uncovered criterion on stderr: $(cat "$tmp/err")"
[ "$(grep -c "maps to no task and is not n/a" "$tmp/err")" = 1 ] || fail "check names only the uncovered criterion: $(cat "$tmp/err")"
jq '.tasks[0].criteria = [] | .na_criteria |= map(select(.criterion != "PII-07"))' "$tmp/plan02" >"$pl"
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] || fail "uncovered focus criteria must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
for id in PII-03 PII-05 PII-07; do
  grep -qxF "$id maps to no task and is not n/a" "$tmp/err" || fail "check prints one line for $id: $(cat "$tmp/err")"
done
[ "$(grep -c "maps to no task and is not n/a" "$tmp/err")" = 3 ] || fail "check prints one line per uncovered criterion: $(cat "$tmp/err")"
jq '.tasks[0].criteria = [] | .na_criteria += [{"criterion": "PII-03", "reason": "x"}, {"criterion": "PII-05", "reason": "y"}]' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "criteria covered or n/a must pass: $(cat "$tmp/out")"
jq '.tasks[1].criteria += ["PII-99"]' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "a task criterion outside the focus criteria must fail: $(cat "$tmp/out")"
grep -q "PII-99" "$tmp/out" || fail "check names the unknown task criterion: $(cat "$tmp/out")"
jq '.na_criteria += [{"criterion": "SEC-01", "reason": "x"}]' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "an na_criteria ID outside the phase's focus criteria must fail: $(cat "$tmp/out")"
grep -q "SEC-01" "$tmp/out" || fail "check names the unknown n/a criterion: $(cat "$tmp/out")"
cp "$tmp/plan02" "$pl"
cp -r "$root/templates" "$tmp/tpl"
rm "$tmp/tpl/checks/pii.md"
[ "$(FORGE_TEMPLATES=$tmp/tpl code "$forge" check 02)" = 1 ] || fail "a focus tag with no criteria file must fail: $(cat "$tmp/out")"
grep -qF "$tmp/tpl/checks/pii.md" "$tmp/out" || fail "a missing criteria file failure names its path: $(cat "$tmp/out")"
! grep -qx "plan ok" "$tmp/out" || fail "a missing criteria file must not pass: $(cat "$tmp/out")"
jq 'del(.focus, .pii_fields)' "$ps" >"$tmp/spec" && mv "$tmp/spec" "$ps"
jq 'del(.na_criteria) | .tasks[] |= del(.criteria)' "$tmp/plan02" >"$pl"
[ "$(FORGE_TEMPLATES=$tmp/tpl code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a phase with no focus checks as before: $(cat "$tmp/out")"
ok check-criteria
fi

repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}

if want check-lint; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json ps=$S/phases/02-intake-form/spec.json
cp "$pl" "$tmp/plan02" && cp "$ps" "$tmp/spec02"
printf -- '- All tests: `npm test`\n- Test: `npm test -- {test}`\n- Changed tests: `npm test -- {files}`\n' >.forge/TESTING.md
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a clean TESTING.md in the project root passes check: $(cat "$tmp/out")"
checks=$(jq -s 'map(select(.step == "check")) | length' "$S/phases/02-intake-form/events.jsonl")
printf -- "- All tests: \`echo 'x\`\n- Test: \`npm test\`\n- Changed tests: \`npm test -- {files}\`\n" >.forge/TESTING.md
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] || fail "a malformed TESTING.md in the project root must fail check with exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -qxF "forge: $PWD/.forge/TESTING.md: - Test: \`npm test\`: no {test} placeholder" "$tmp/err" || fail "check names the TESTING.md, the Test line and the missing {test} on stderr: $(cat "$tmp/err")"
grep -qF "forge: $PWD/.forge/TESTING.md: - All tests: \`echo 'x\`: " "$tmp/err" && grep -q "unexpected EOF" "$tmp/err" || fail "check prints every lint failure, the bash -n error included: $(cat "$tmp/err")"
! grep -qx "plan ok" "$tmp/out" || fail "a failed lint must not pass: $(cat "$tmp/out")"
[ "$(jq -s 'map(select(.step == "check")) | length' "$S/phases/02-intake-form/events.jsonl")" = "$checks" ] || fail "a failed lint exits before logging a check event: $(cat "$S/phases/02-intake-form/events.jsonl")"
rm .forge/TESTING.md
repo web && repo api
mkdir -p web/.forge && printf -- '- All tests: `npm test`\n- Test: `npm test`\n' >web/.forge/TESTING.md
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a malformed TESTING.md in a repo the plan does not touch is not linted: $(cat "$tmp/out")"
jq '.tasks[1].repo = "web"' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "a malformed TESTING.md in a task's repo must fail check: $(cat "$tmp/out")"
grep -qxF "forge: $PWD/web/.forge/TESTING.md: - Test: \`npm test\`: no {test} placeholder" "$tmp/out" || fail "check names the task repo's TESTING.md, line and reason: $(cat "$tmp/out")"
cp "$tmp/plan02" "$pl"
jq '.repo = "web"' "$tmp/spec02" >"$ps"
[ "$(code "$forge" check 02)" = 1 ] || fail "a malformed TESTING.md in the phase spec's repo must fail check: $(cat "$tmp/out")"
grep -qxF "forge: $PWD/web/.forge/TESTING.md: - Test: \`npm test\`: no {test} placeholder" "$tmp/out" || fail "check names the spec repo's TESTING.md, line and reason: $(cat "$tmp/out")"
jq '.tasks[] |= (.repo = "api")' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a task's repo overrides the spec repo, and a touched repo with no TESTING.md passes: $(cat "$tmp/out")"
cp "$tmp/plan02" "$pl" && cp "$tmp/spec02" "$ps"
ok check-lint
fi

if want check-coverage; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
pl=$S/phases/02-intake-form/plan.json
cp "$pl" "$tmp/plan02"
tl() { mkdir -p "$1/.forge" "$1/lib" && printf '#!/bin/sh\n' >"$1/lib/run.sh" && printf -- '- All tests: `%s`\n- Test: `%s`\n- Changed tests: `%s`\n' "$2" "$3" "$4" >"$1/.forge/TESTING.md"; }
newt() { jq '.tasks[1].files += $ARGS.positional' "$tmp/plan02" --args "$@" >"$pl"; }
passes() { [ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "$1: $(cat "$tmp/out")"; }
tl . 'lib/run.sh lib/' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "a plan creating no test file passes coverage"
newt tests/new.test.sh
[ "$(code "$forge" check 02)" = 1 ] || fail "a new test file no TESTING.md command covers must fail check with exit 1: $(cat "$tmp/out")"
grep -qF tests/new.test.sh "$tmp/out" || fail "check names the uncovered test file: $(cat "$tmp/out")"
! grep -qx "plan ok" "$tmp/out" || fail "an uncovered test file must not pass: $(cat "$tmp/out")"
newt src/form.spec.ts pkg/queue_test.go py/test_intake.py src/__tests__/intake.ts
[ "$(code "$forge" check 02)" = 1 ] || fail "uncovered *.spec.*, *_test.*, test_*.py and __tests__/ files must fail check: $(cat "$tmp/out")"
for x in src/form.spec.ts pkg/queue_test.go py/test_intake.py src/__tests__/intake.ts; do
  grep -qF "$x" "$tmp/out" || fail "check names the uncovered test file $x: $(cat "$tmp/out")"
done
newt tests/fixtures/intake/new.test.sh
passes "a new fixture is not checked for coverage"
mkdir -p tests && printf '#!/bin/sh\n' >tests/old.test.sh && git add tests/old.test.sh && git commit -q -m old
newt tests/old.test.sh
passes "an existing test file is not checked for coverage"
jq '.tasks[1].files += ["tests/new.test.sh"] | .tasks[0].files += [".forge/TESTING.md"]' "$tmp/plan02" >"$pl"
passes "a plan task listing the repo's .forge/TESTING.md passes coverage"
newt tests/new.test.sh
tl . 'lib/run.sh tests' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "an All tests command naming the parent directory covers the test file"
tl . 'lib/run.sh tests/*.test.sh' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "an All tests command naming a matching glob covers the test file"
tl . 'lib/run.sh lib/none/*.test.sh' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
[ "$(code "$forge" check 02)" = 1 ] || fail "a command naming a path glob with no match yet is not a whole-repo runner: $(cat "$tmp/out")"
grep -qF tests/new.test.sh "$tmp/out" || fail "check names the test file an unmatched path glob does not cover: $(cat "$tmp/out")"
tl . 'lib/run.sh tests/new.test.sh' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "an All tests command naming the path covers the test file"
for c in 'bash tests/old.test.sh' 'tests/old.test.sh' 'lib/run.sh tests/unit/' 'lib/run.sh tests/unit' 'cd lib && lib/run.sh tests/unit'; do
  tl . "$c" 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
  [ "$(code "$forge" check 02)" = 1 ] || fail "'$c' names another test file or a directory not created yet, so it is not a whole-repo runner: $(cat "$tmp/out")"
  grep -qF tests/new.test.sh "$tmp/out" || fail "check names the test file '$c' does not cover: $(cat "$tmp/out")"
done
for c in 'node_modules/.bin/jest' 'cd lib && ./node_modules/.bin/jest --ci' 'lib/run.sh'; do
  tl . "$c" 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
  passes "a command word naming a runner that is not a test file names no path, so '$c' covers the test file"
done
tl . 'lib/run.sh lib/' 'lib/run.sh tests {test}' 'lib/run.sh lib/ {files}'
passes "a Test command naming the parent directory covers the test file"
tl . 'lib/run.sh lib/' 'lib/run.sh lib/ {test}' 'lib/run.sh tests {files}'
passes "a Changed tests command naming the parent directory covers the test file"
newt tests/new.test.sh
tl . 'lib/run.sh lib/' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
printf -- '- Perf log: `lib/run.sh tests`\n' >>.forge/TESTING.md
passes "a Perf log command covers a new test file no other command covers"
newt tests/new.test.sh
tl . 'npm test' 'npm test -- {test}' 'npm test -- {files}'
passes "commands naming no repo path are whole-repo runners"
tl . 'go test ./...' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "an All tests command naming ./... is a whole-repo runner"
tl . 'pytest .' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "an All tests command naming . is a whole-repo runner"
tl . 'lib/run.sh lib' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "a bare directory word names no path, so the command is a whole-repo runner"
tl . 'lib/run.sh --dir=lib/' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
[ "$(code "$forge" check 02)" = 1 ] || fail "a flag value naming a directory is not a whole-repo runner: $(cat "$tmp/out")"
grep -qF tests/new.test.sh "$tmp/out" || fail "check names the test file a --dir=lib/ command does not cover: $(cat "$tmp/out")"
mkdir -p test src/lib e2e
newt src/x.test.ts
for c in 'npm test' 'cargo test' 'pnpm run e2e'; do
  tl . "$c" 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
  passes "a runner word matching a directory does not name it, so '$c' covers src/x.test.ts"
done
newt tests/test_x.py
for c in 'PYTHONPATH=src pytest' 'PYTHONPATH=src/lib pytest'; do
  tl . "$c" 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
  passes "an assignment word names no path, so '$c' covers tests/test_x.py"
done
rm -r test src e2e
newt tests/new.test.sh
printf -- '- Setup: `npm ci`\n' >.forge/TESTING.md
passes "a TESTING.md with no command line skips coverage"
rm .forge/TESTING.md
passes "a repo with no TESTING.md skips coverage"
cp "$root/.forge/TESTING.md" .forge/TESTING.md
newt tests/newsuite.test.sh
passes "forge's own All tests line covers a new tests/<name>.test.sh"
tl . 'npm test' 'npm test -- {test}' 'npm test -- {files}'
repo web
tl web 'lib/run.sh lib/' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
jq '.tasks[1].repo = "web" | .tasks[1].files += ["tests/new.test.sh"]' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "an uncovered new test file in a task's repo must fail check: $(cat "$tmp/out")"
grep -qF "web:tests/new.test.sh" "$tmp/out" || fail "check names a named repo's test file as <repo>:<file>: $(cat "$tmp/out")"
jq '.tasks[1].repo = "web" | .tasks[1].files += ["tests/new.test.sh"] | .tasks[0].files += [".forge/TESTING.md"]' "$tmp/plan02" >"$pl"
[ "$(code "$forge" check 02)" = 1 ] || fail "listing another repo's TESTING.md does not cover web's test file: $(cat "$tmp/out")"
grep -qF "web:tests/new.test.sh" "$tmp/out" || fail "check still names web:tests/new.test.sh: $(cat "$tmp/out")"
jq '.tasks[1].repo = "web" | .tasks[1].files += ["tests/new.test.sh", ".forge/TESTING.md"]' "$tmp/plan02" >"$pl"
passes "a task listing its own repo's .forge/TESTING.md passes coverage"
jq '.tasks[1].repo = "web" | .tasks[1].files += ["tests/new.test.sh"]' "$tmp/plan02" >"$pl"
tl web 'lib/run.sh tests' 'lib/run.sh lib/ {test}' 'lib/run.sh lib/ {files}'
passes "a named repo's covering command passes coverage"
cp "$tmp/plan02" "$pl"
ok check-coverage
fi

if want check-exempt; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json
pt() { jq "$1" "$fpl" >"$tmp/plan" && mv "$tmp/plan" "$pl"; }
ck() { s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?; }
passes() { ck; [ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "$1 passes check, got $s: $(cat "$tmp/out" "$tmp/err")"; }
pt '.'
passes "the fixture plan"
pt 'del(.tasks[].test, .tasks[].exempt_reason)'
passes "a plan whose tasks have no test field"
pt '.tasks[1] |= del(.exempt_reason)'
passes "an exempt task with no exempt_reason"
pt '.tasks[1].exempt_reason = ""'
passes "an exempt task with an empty exempt_reason"
pt '.tasks[0].files = ["tests/leads.test.sh"]'
passes "a test-first task planning only a test file"
pt '.tasks[0].files = ["tests/leads.test.sh", "CMakeLists.txt"]'
passes "a test-first task planning only a test and CMakeLists.txt"
"$forge" check --help >"$tmp/help"
! grep -qF "plans only configuration or registration files" "$tmp/help" || fail "check help names no config-only refusal"
! grep -qF "plans only test files" "$tmp/help" || fail "check help names no test-only refusal"
! grep -qF exempt_reason "$tmp/help" || fail "check help notes no exempt_reason rule"
ok check-exempt
fi

if want check-files; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json ps=$S/phases/02-intake-form/spec.json
pt() { jq "$1" "$fpl" >"$tmp/plan" && mv "$tmp/plan" "$pl"; }
st() { jq --arg b "$1" '.spec += [$b]' "$fps" >"$tmp/spec" && mv "$tmp/spec" "$ps"; }
ck() { s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?; }
miss() { echo "$1 is named in the phase spec Files but in no task's files and not in na_files"; }
pt '.'
st 'Files: db/leads.sql, src/form.ts, docs/intake.md'
ck
[ $s = 1 ] || fail "a phase spec Files path no task plans must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/err")" = "$(miss docs/intake.md)" ] || fail "check names only the uncovered Files path on stderr: $(cat "$tmp/err")"
! grep -qx "plan ok" "$tmp/out" || fail "an uncovered Files path must not pass: $(cat "$tmp/out")"
st 'Files: db/leads.sql, docs/intake.md, docs/notes.md (read only).'
ck
[ $s = 1 ] && [ "$(grep -c "is named in the phase spec Files" "$tmp/err")" = 2 ] || fail "each uncovered Files path prints its own line, got $s: $(cat "$tmp/err")"
grep -qxF "$(miss docs/intake.md)" "$tmp/err" && grep -qxF "$(miss docs/notes.md)" "$tmp/err" || fail "check names every uncovered Files path, notes and trailing dot stripped: $(cat "$tmp/err")"
st 'Files: db/leads.sql, src/form.ts:12, src/api.ts:3-9'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a Files entry path:line covered by a task passes, got $s: $(cat "$tmp/out" "$tmp/err")"
st 'Files: db/, src'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a Files directory entry covered by a file under it passes, got $s: $(cat "$tmp/out" "$tmp/err")"
st 'Files: sr'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "$(miss sr)" ] || fail "a Files entry that is only a name prefix of a planned path is not covered, got $s: $(cat "$tmp/err")"
st 'Files: edit `src/form.ts` and `docs/intake.md`, then README, guide and docs/other.md'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "$(miss docs/intake.md)" ] || fail "a prose Files bullet parses only its backticked paths, got $s: $(cat "$tmp/err")"
st 'Files: edit `src/form.ts` and `db/leads.sql`, then README and docs/other.md'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a prose Files bullet whose backticked paths are covered passes, got $s: $(cat "$tmp/out" "$tmp/err")"
st 'Files: db/leads.sql, docs/intake.md'
pt '.na_files = [{file: "docs/intake.md", reason: "read-only reference"}]'
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "an na_files entry covers a Files path no task plans, got $s: $(cat "$tmp/out" "$tmp/err")"
pt '.na_files = [{file: "docs/intake.md", reason: "read-only reference"}, {file: "src/other.ts", reason: "owned by another phase"}]'
ck
[ $s = 1 ] || fail "an na_files entry the phase spec Files does not name must exit 1, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/err")" = "src/other.ts in na_files is not named in the phase spec" ] || fail "check names the unnamed na_files entry on stderr: $(cat "$tmp/err")"
! grep -qx "plan ok" "$tmp/out" || fail "an unnamed na_files entry must not pass: $(cat "$tmp/out")"
pt '.na_files = [{file: "docs/intake.md"}]'
ck
[ $s = 1 ] && grep -qF plan.json "$tmp/out" "$tmp/err" || fail "an na_files entry with no reason fails the plan schema, got $s: $(cat "$tmp/out" "$tmp/err")"
pt '.na_files = [{file: "docs/intake.md", reason: "x", note: "y"}]'
ck
[ $s = 1 ] && grep -qF plan.json "$tmp/out" "$tmp/err" || fail "an na_files entry with an extra key fails the plan schema, got $s: $(cat "$tmp/out" "$tmp/err")"
pt '.'
jq '.spec += ["Files: db/leads.sql, docs/intake.md", "Gap: docs/intake.md was not written"]' "$fps" >"$tmp/spec" && mv "$tmp/spec" "$ps"
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a phase spec with a Gap: bullet skips the Files coverage rule, got $s: $(cat "$tmp/out" "$tmp/err")"
jq '.repo = "web" | .spec += ["Files: web:src/form.ts, web:db/leads.sql"]' "$fps" >"$tmp/spec" && mv "$tmp/spec" "$ps"
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a <repo>: Files entry is covered by a task in the spec repo, got $s: $(cat "$tmp/out" "$tmp/err")"
pt '.tasks[1].repo = "api"'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "$(miss src/form.ts)" ] || fail "a task in another repo does not cover a Files path, got $s: $(cat "$tmp/err")"
jq '.spec += ["Files: api:src/form.ts, db/leads.sql"]' "$fps" >"$tmp/spec" && mv "$tmp/spec" "$ps"
ck
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a root phase Files entry <repo>:path is covered by a task in that repo, got $s: $(cat "$tmp/out" "$tmp/err")"
jq '.repo = "web" | .spec += ["Files: api:src/form.ts, api:src/x.ts, web:db/leads.sql"]' "$fps" >"$tmp/spec" && mv "$tmp/spec" "$ps"
pt '.tasks[0].repo = "web" | .tasks[1].repo = "api"'
ck
[ $s = 1 ] && [ "$(cat "$tmp/err")" = "$(miss api:src/x.ts)" ] || fail "a Files entry <repo>:path in another repo is matched only against that repo's tasks, got $s: $(cat "$tmp/err")"
ok check-files
fi
if want check-state; then
fresh
git init -q -b main
pl=$S/phases/02-intake-form/plan.json ev=$S/phases/02-intake-form/events.jsonl
sha() { sha256sum "$1" | cut -d' ' -f1; }
lastcheck() { jq -sc 'map(select(.step == "check")) | last' "$1"; }
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "the state dir plan passes check: $(cat "$tmp/out")"
[ "$(lastcheck "$ev" | jq -r .message)" = "plan ok" ] || fail "check logs its event in the state dir events.jsonl: $(cat "$ev")"
[ "$(lastcheck "$ev" | jq -r .plan)" = "$(sha "$pl")" ] || fail "the check event logs the sha256 of plan.json as its plan key: $(lastcheck "$ev")"
jq '.tasks[0].title = "Lead table v2"' "$fpl" >"$pl"
[ "$(code "$forge" check 02)" = 0 ] || fail "the edited plan passes check: $(cat "$tmp/out")"
[ "$(lastcheck "$ev" | jq -r .plan)" = "$(sha "$pl")" ] || fail "each check event logs the sha256 of plan.json as it is then: $(lastcheck "$ev")"
o=$S/phases/07-routing-rules
mkdir -p "$o"
jq -n '{track: "crm", feature: "routing", number: "07", slug: "routing-rules", goal: "Rules", spec: [], requirements: [], depends: []}' >"$o/spec.json"
jq -n '{tasks: [{id: "T1", title: "Rules", files: ["src/form.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "glue", requirements: []}]}' >"$o/plan.json"
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "an overlap with another feature's phase only warns, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -qxF "forge: warning: phase 02 plans files that phase 07 (crm/routing) also plans: src/form.ts" "$tmp/err" || fail "check warns of a state dir phase of another feature planning the same file: $(cat "$tmp/err")"
jq -se 'map(select(.step == "overlap")) | last.message == "phase 07 (crm/routing): src/form.ts"' "$ev" >/dev/null || fail "the overlap event lands in the state dir events.jsonl: $(cat "$ev")"
rm -rf "$o"
d=$S/phases/03-intake-api
jq '.depends = []' "$d/spec.json" >"$tmp/spec" && mv "$tmp/spec" "$d/spec.json"
jq '.phases[1].depends = []' "$S/features/crm-intake/split.json" >"$tmp/split" && mv "$tmp/split" "$S/features/crm-intake/split.json"
jq -n '{tasks: [{id: "T1", title: "Api", files: ["src/form.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "glue", requirements: ["INT-02"]}]}' >"$d/plan.json"
[ "$(code "$forge" check 03)" = 3 ] && [ "$(cat "$tmp/out")" = "waits on 02" ] || fail "a checked state dir phase of the same feature planning the same file makes check wait: $(cat "$tmp/out")"
jq -e '.depends == ["02"]' "$d/spec.json" >/dev/null || fail "check adds the wait to the state dir spec.json: $(cat "$d/spec.json")"
jq -e '.phases[1].depends == ["intake-form"]' "$S/features/crm-intake/split.json" >/dev/null || fail "check adds the wait to the state dir split.json: $(cat "$S/features/crm-intake/split.json")"
jq -se 'map(select(.step == "wait")) | last.message == "files overlap phase 02"' "$d/events.jsonl" >/dev/null || fail "the wait event lands in the state dir events.jsonl: $(cat "$d/events.jsonl")"
[ "$(lastcheck "$d/events.jsonl" | jq -r .plan)" = "$(sha "$d/plan.json")" ] || fail "a waiting check event logs the plan sha256 too: $(lastcheck "$d/events.jsonl")"
[ ! -e .forge/phases ] && [ ! -e .forge/features ] || fail "check writes nothing under the repo's .forge: $(ls .forge)"
ok check-state
fi

if want check-quarantine; then
fresh
git init -q -b main
git config user.name t && git config user.email t@t
old=$(date -u -d '10 days ago' +%F)
qline="- Quarantine (added $old): \`npm test -- flaky\` runs the flaky tests."
printf -- '- All tests: `npm test`\n- Test: `npm test -- {test}`\n- Changed tests: `npm test -- {files}`\n%s\n' "$qline" >.forge/TESTING.md
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a Quarantine line over 7 days old passes check, got $s: $(cat "$tmp/out" "$tmp/err")"
grep -qF "forge: $PWD/.forge/TESTING.md: line 4: $qline: added $old, over 7 days ago; recorded as concern $(basename "$PWD"):C-01" "$tmp/err" ||
  fail "check names the old Quarantine line and the concern it recorded on stderr: $(cat "$tmp/err")"
want=$(jq -cnS --arg d "$(date +%F)" --arg t "Quarantine line 4 of .forge/TESTING.md, added $old, is over 7 days old; lift it or fix the tests: $qline" \
  '{concerns: [{id: "C-01", area: "quarantine", files: [".forge/TESTING.md"], severity: "low", evidence: [], status: "open", text: $t, date: $d}]}')
[ "$(jq -cS . .forge/concerns.json)" = "$want" ] || fail "check appends one dated quarantine concern naming the line to .forge/concerns.json: $(cat .forge/concerns.json)"
"$forge" validate .forge/concerns.json || fail "the written concerns.json validates"
grep -qF 'C-01 — quarantine — .forge/TESTING.md — low' .forge/CONCERNS.md || fail "check renders CONCERNS.md with the concern: $(cat .forge/CONCERNS.md)"
[ "$(git log -1 --format=%s)" = "docs(concerns): add $(basename "$PWD"):C-01" ] || fail "the concern is committed as forge concern add commits it: $(git log --oneline)"
[ "$(code "$forge" check 02)" = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a second check with the concern open passes quietly: $(cat "$tmp/out")"
[ "$(jq '.concerns | length' .forge/concerns.json)" = 1 ] || fail "a second check adds no second concern for the same line: $(cat .forge/concerns.json)"
jq '.concerns[0].status = "resolved"' .forge/concerns.json >"$tmp/c" && mv "$tmp/c" .forge/concerns.json
[ "$(code "$forge" check 02)" = 0 ] || fail "check passes once the concern is resolved: $(cat "$tmp/out")"
[ "$(jq -r '.concerns | length, .[1].id, .[1].status' .forge/concerns.json | paste -sd' ')" = "2 C-02 open" ] || fail "a resolved concern for the line lets check record a new open one: $(cat .forge/concerns.json)"
printf -- '- All tests: `npm test`\n- Test: `npm test -- {test}`\n- Changed tests: `npm test -- {files}`\n- Quarantine (added %s): `npm test -- flaky` runs the flaky tests.\n' "$(date -u +%F)" >.forge/TESTING.md
[ "$(code "$forge" check 02)" = 0 ] && [ "$(jq '.concerns | length' .forge/concerns.json)" = 2 ] || fail "a fresh Quarantine line records no concern: $(cat "$tmp/out" .forge/concerns.json)"
printf -- '- All tests: `npm test`\n- Test: `npm test -- {test}`\n- Changed tests: `npm test -- {files}`\n- Quarantine (added 2026-13-40): `npm test -- flaky`\n' >.forge/TESTING.md
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] && grep -q 'is not an (added YYYY-MM-DD) date' "$tmp/err" || fail "a Quarantine line with a bad date still fails check, got $s: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq '.concerns | length' .forge/concerns.json)" = 2 ] || fail "a failing lint records no concern: $(cat .forge/concerns.json)"
printf -- '- All tests: `npm test`\n- Test: `npm test`\n- Quarantine (added %s): `npm test -- flaky`\n' "$old" >.forge/TESTING.md
s=0; "$forge" check 02 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 1 ] && grep -q 'no {test} placeholder' "$tmp/err" || fail "an old Quarantine line beside another lint failure still fails check, got $s: $(cat "$tmp/out" "$tmp/err")"
"$forge" check --help | grep -qi 'concern' || fail "check help describes the quarantine concern"
ok check-quarantine
fi
finish
