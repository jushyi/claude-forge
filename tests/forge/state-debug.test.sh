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

login500() {
  fresh
  s=$tmp/p/.forge/debug/login-500
  mkdir -p $s/tests $s/fixes
  cat >$s/session.json <<'EOF'
{
  "symptom": "login returns 500",
  "symptoms": {"expected": "200 OK", "actual": "500 Internal Server Error", "errors": ["TypeError: email.trim is not a function"], "reproduction": "npm test -- intake"},
  "hypotheses": [
    {"hypothesis": "the email arrives as null", "test": "log the email in src/intake.ts; a string eliminates it", "evidence": [], "verdict": "open"},
    {"hypothesis": "the form posts the email as an array", "test": "inspect the request body; a string eliminates it", "evidence": ["src/form.ts:8 sends [email]"], "verdict": "confirmed"},
    {"hypothesis": "the session expired", "test": "retry with a fresh session; a 500 again eliminates it", "evidence": ["operator: still 500 after a fresh login"], "verdict": "eliminated"}
  ],
  "checkpoints": [{"question": "Does a fresh login still fail?", "type": "verify", "options": ["yes", "no"], "answer": "yes"}],
  "outcome": "root-cause",
  "root_cause": {"summary": "the form posts the email as an array", "locations": [{"repo": "p", "file": "src/form.ts", "line": 8}], "reproduction": "npm test -- intake"}
}
EOF
}

if want debug-validate; then
login500
sp=$XDG_STATE_HOME/forge/p
p=$sp/phases/02-intake-form f=$sp/features/crm-intake
cp $p/plan.json $s/plan.json
echo '{"task": "T1", "files": ["tests/intake.test.ts"], "command": "npm test -- intake", "failure": "expected 200, got 500"}' >$s/tests/T1.json
cp $p/review.json $s/review.json
echo '{"file": "src/form.ts", "line": 8, "status": "fixed", "summary": "post the email as a string"}' >$s/fixes/F1.json
for x in session plan tests/T1 review fixes/F1; do
  "$forge" validate $s/$x.json || fail "debug scratch $x.json must validate: $("$forge" validate $s/$x.json 2>&1)"
done
for x in plan review; do
  bad $s/$x.json '. + {"bogus": 1}'
done
for x in session tests/T1 fixes/F1; do
  loose $s/$x.json '. + {"bogus": 1}'
done
loose $s/session.json 'del(.root_cause)'
loose $s/session.json '.hypotheses[0].verdict = "maybe"'
cp $s/session.json "$tmp/session"
echo '{"symptom": "x"}' >$s/session.json
"$forge" validate $s/session.json || fail "a session with only a symptom must validate: $("$forge" validate $s/session.json 2>&1)"
cp "$tmp/session" $s/session.json
mkdir -p $s/probe/tests
for x in out session tests/a; do
  echo '{}' >$s/probe/$x.json
  loose $s/probe/$x.json '. + {"bogus": 1}'
done
rm -rf $s/probe
cp -r $s $tmp/p/.forge/debug/stale-tracks
mkdir -p "$tmp/phases/tracks"
cp -r "$tmp/p" "$tmp/phases/tracks/features"
for x in session plan tests/T1 review fixes/F1; do
  "$forge" validate $tmp/p/.forge/debug/stale-tracks/$x.json \
    || fail "debug scratch stale-tracks/$x.json must validate: $("$forge" validate $tmp/p/.forge/debug/stale-tracks/$x.json 2>&1)"
  (cd "$tmp/phases/tracks/features" && "$forge" validate "$PWD/.forge/debug/login-500/$x.json") \
    || fail "debug scratch $x.json under a root with phases/ must validate"
done
rm -rf "$tmp/phases" $tmp/p/.forge/debug/stale-tracks
echo '{"bogus": 1}' >$s/session.json
"$forge" validate || fail "validate with no files must ignore debug scratch: $("$forge" validate 2>&1)"
a=$sp/features/adhoc-debug
mkdir -p $a/research
cp $f/spec.json $a/spec.json
cp $f/research.json $a/research/R1.json
"$forge" validate $a/spec.json $a/research/R1.json || fail "adhoc-debug feature files must validate"
cp $f/research.json $a/spec.json
[ "$(code "$forge" validate $a/spec.json)" = 1 ] || fail "adhoc-debug spec.json must be checked as feature-spec"
cp $f/spec.json $a/research/R1.json
loose $a/research/R1.json '. + {"bogus": 1}'
ok debug-validate
fi

if want debugs-validate; then
login500
sp=$XDG_STATE_HOME/forge/p
d=$sp/debugs.json
cat >$d <<'EOF'
{
  "debugs": [
    {"slug": "login-500", "symptom": "login returns 500", "cause": "the form posts the email as an array", "repos": ["p"], "date": "2026-10-19"},
    {"slug": "login-500-2", "symptom": "signup hangs", "cause": "the mailer retries forever", "repos": ["p", "mailer"], "date": "2026-10-20"}
  ]
}
EOF
cp $d $s/debugs.json
for x in $d $s/debugs.json; do
  [ "$(code "$forge" validate $x)" = 0 ] || fail "$x must validate: $(cat "$tmp/out")"
done
(cd "$sp" && "$forge" validate debugs.json) || fail "debugs.json from inside the state dir must validate"
for x in $d $s/debugs.json; do
  loose $x '. + {"bogus": 1}'
  loose $x 'del(.debugs[0].slug)'
  loose $x '.debugs[0].date = "19/10/2026"'
  loose $x '.debugs[0].source = "forge"'
  loose $x 'del(.debugs)'
done
echo '{"debugs": []}' >$d
"$forge" validate $d || fail "an empty debugs list must validate: $("$forge" validate $d 2>&1)"
ok debugs-validate
fi
finish
