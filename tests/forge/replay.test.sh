#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

j=$tmp/judge
mk() { cat >"$tmp/$1" && chmod +x "$tmp/$1"; }
svc() {
  mk "$1" <<EOF
#!/usr/bin/env bash
jq -c --arg id "\$RANDOM\$RANDOM" '{total: (.price * .qty), suggested_tip: ((.price * .qty * 0.15 * 100 | $2) / 100), request_id: \$id, lines: [{name: .name}]}'
EOF
}
svc old floor
svc broken ceil
mk pen <<EOF
#!/usr/bin/env bash
"$tmp/old" | jq -c 'if .lines[0].name == "pen" then .total = 0 end'
EOF
mk sub <<'EOF'
#!/usr/bin/env bash
sed -e 's/{"id":"x1","v":1 }/{"v":1 }/' -e 's/1\.0/1/' -e 's/caf\\u00e9/café/' -e 's/551617/551616/' -e 's/{"a":1,"b":2}/{"b":2,"a":1}/' -e 's/{"a": 1}/{"a":1}/' -e 's/"id":"x1"/"id":"x2"/' \
  -e 's/{"a": 1,"b":2}/{"a":1,"b": 2}/' -e 's/{"a":1,"a":2}/{"a":3,"a":2}/' -e 's/"x y":"p1"/"x y":"p2"/' \
  -e 's/{"a":1, "b":2,"c":3}/{"a":1,"b":2, "c":3}/'
EOF
mk sub2 <<'EOF'
#!/usr/bin/env bash
sed -e 's/"y":{"b":{"c":1}},//' -e 's/"a"/"A"/; s/"b"/"B"/; s/"x":1/"x":2/' -e 's/^plain text$/other/' -e 's/"a\.b":1/"a.b":2/' -e 's/\[\]/[1]/'
EOF
mk spaced <<'EOF'
#!/usr/bin/env bash
jq -c --arg id "$RANDOM$RANDOM" '{("request id"): $id, v: 1}'
EOF
mk flip <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/count" 2>/dev/null || echo 0) + 1 ))
echo \$n >"$tmp/count"
if (( n % 2 )); then echo '{"a":1,"b":2}'; else echo '{"b":2,"a":1}'; fi
EOF
seed() {
  rm -rf "$j"
  mkdir -p "$j/requests" "$j/holdout"
  printf '{"name":"linen towel","price":0.30,"qty":1}\n' >"$j/requests/towel"
  printf '{"name":"café mug","price":20,"qty":1}\n' >"$j/requests/mug"
  printf '{"name":"pen","price":2,"qty":3}\n' >"$j/holdout/pen"
  printf 'ignore .request_id random per request\n' >"$j/rules"
}
texts() {
  rm -rf "$j"
  mkdir -p "$j/requests" "$j/holdout"
  printf '%s\n' "$@" >"$tmp/texts"
  local i=0 l
  while IFS= read -r l; do i=$((i + 1)); printf '%s\n' "$l" >"$j/requests/t$i"; done <"$tmp/texts"
  printf '{"z":0}\n' >"$j/holdout/h"
  : >"$j/rules"
  "$forge" replay record "$j" cat >/dev/null
}
class() { jq -r --arg id "$1" 'select(.id == $id) | .class' "$j/report.jsonl"; }

if want record; then
seed
[ "$(code "$forge" replay record "$j" "$tmp/old")" = 0 ] || fail "record runs the old command on each request: $(cat "$tmp/out")"
[ "$(jq -r .suggested_tip "$j/answers/towel")" = 0.04 ] || fail "record writes the old answer of each request: $(cat "$j/answers/towel")"
[ -s "$j/answers/mug" ] && [ -s "$j/answers/pen" ] || fail "record answers every request, holdout included"
[ -s "$j/noise/towel" ] && [ -s "$j/noise/pen" ] || fail "record runs the old command a second time into noise/"
[ "$(jq -r .request_id "$j/answers/towel")" != "$(jq -r .request_id "$j/noise/towel")" ] || fail "the second recording is a separate run"
grep -q 'forge: recorded 3 answers twice' "$tmp/out" || fail "record names how many answers it wrote: $(cat "$tmp/out")"
grep -qx 'noise .request_id 3 mug' "$tmp/out" || fail "record derives the noisy field from where the two old runs disagree: $(cat "$tmp/out")"
[ "$(grep -c '^noise ' "$tmp/out")" = 1 ] || fail "only the field the two old runs disagree on is a candidate: $(cat "$tmp/out")"
"$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" replay record "$j" "$tmp/old")" = 3 ] || fail "record refuses a locked judge"
grep -q 'locked' "$tmp/out" || fail "record says the judge is locked: $(cat "$tmp/out")"
seed
[ "$(code "$forge" replay record "$j" cat)" = 0 ] && grep -qx 'noise none' "$tmp/out" || fail "a deterministic old command has no noise: $(cat "$tmp/out")"
seed
[ "$(code "$forge" replay record "$j" "$tmp/spaced")" = 0 ] && grep -qx 'noise \["request id"\] 3 mug' "$tmp/out" || fail "a noise path with a space in its key stays whole: $(cat "$tmp/out")"
seed
[ "$(code "$forge" replay record "$j" "$tmp/flip")" = 0 ] && grep -qx 'noise order 3 mug' "$tmp/out" || fail "old runs that differ only in key order give an order candidate: $(cat "$tmp/out")"
seed
printf '#!/usr/bin/env bash\nexit 1\n' | mk false
[ "$(code "$forge" replay record "$j" "$tmp/false")" = 1 ] && grep -q 'the old command failed on' "$tmp/out" || fail "record stops on a failing old command: $(cat "$tmp/out")"
ok record
fi

if want lock; then
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
for r in 'ignore .request_id' 'drop .request_id random' 'ignore request_id random' 'normalize case names differ' 'normalize keys'; do
  printf '%s\n' "$r" >"$j/rules"
  [ "$(code "$forge" replay lock "$j")" = 1 ] && [ ! -e "$j/lock" ] || fail "lock refuses the rule '$r': $(cat "$tmp/out")"
  grep -q "rule line 1" "$tmp/out" || fail "lock names the bad rule line: $(cat "$tmp/out")"
done
printf 'ignore .request_id\n' >"$j/rules"
grep -q 'needs a reason' <("$forge" replay lock "$j" 2>&1) || fail "lock says every rule needs a reason"
printf 'ignore .request_id random per request\nignore .lines[].id["x.y"] keyed by id\nignore ["request id"] random\nnormalize keys dict order\nnormalize numbers 1.0 is 1\nnormalize space pretty printer\n' >"$j/rules"
[ "$(code "$forge" replay lock "$j")" = 0 ] || fail "lock accepts every rule form: $(cat "$tmp/out")"
grep -q 'forge: locked .*: 2 requests, 1 holdout, 6 rules' "$tmp/out" || fail "lock counts requests, holdout and rules: $(cat "$tmp/out")"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
rm "$j/answers/mug"
[ "$(code "$forge" replay lock "$j")" = 1 ] && grep -q 'mug has no answer' "$tmp/out" && [ ! -e "$j/lock" ] || fail "lock refuses a request with no answer: $(cat "$tmp/out")"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
rm "$j/holdout/pen"
[ "$(code "$forge" replay lock "$j")" = 1 ] && grep -q 'holdout' "$tmp/out" && [ ! -e "$j/lock" ] || fail "lock refuses a judge with no holdout request: $(cat "$tmp/out")"
seed
cp "$j/requests/towel" "$j/holdout/towel"
"$forge" replay record "$j" "$tmp/old" >/dev/null
[ "$(code "$forge" replay lock "$j")" = 1 ] && grep -q 'towel is in both requests/ and holdout/' "$tmp/out" || fail "lock refuses an id in both sets: $(cat "$tmp/out")"
ok lock
fi

if want run; then
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
[ "$(code "$forge" replay run "$j" "$tmp/old")" = 3 ] || fail "run refuses an unlocked judge"
"$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" replay run "$j" "$tmp/old")" = 0 ] || fail "the old command against its own answers passes once request_id is ignored: $(cat "$tmp/out")"
grep -qx 'requests=2 mismatches=0 classes=0 holdout=1 holdout_mismatches=0' "$tmp/out" || fail "run prints the summary line: $(cat "$tmp/out")"
[ "$(code "$forge" replay run "$j" "$tmp/broken")" = 1 ] || fail "a broken port fails the run"
grep -q '^requests=2 mismatches=1 classes=1 holdout=1 ' "$tmp/out" || fail "only the towel differs among visible requests: $(cat "$tmp/out")"
grep -qx 'class .suggested_tip 1 towel' "$tmp/out" || fail "run prints each class with its count and first request: $(cat "$tmp/out")"
r=$(jq -c 'select(.id == "towel")' "$j/report.jsonl")
[ "$(jq -r .class <<<"$r")" = .suggested_tip ] || fail "the report names the differing fields: $r"
[ "$(jq -r .want <<<"$r" | jq .suggested_tip)" = 0.04 ] && [ "$(jq -r .got <<<"$r" | jq .suggested_tip)" = 0.05 ] || fail "the report holds both answers: $r"
[ "$(jq -r .request <<<"$r")" = "$(cat "$j/requests/towel")" ] || fail "the report holds the request: $r"
[ "$(bash -c "$(jq -r .repro <<<"$r")" </dev/null | jq .suggested_tip)" = 0.05 ] || fail "the report holds one command that reproduces the answer: $r"
mkdir -p "$tmp/a b" && cp -r "$j" "$tmp/a b/judge"
"$forge" replay run "$tmp/a b/judge" "$tmp/broken | cat" >/dev/null || true
r=$(jq -c 'select(.id == "towel")' "$tmp/a b/judge/report.jsonl")
[ "$(bash -c "$(jq -r .repro <<<"$r")" </dev/null | jq .suggested_tip)" = 0.05 ] || fail "repro feeds a pipeline as run does, from a path with a space: $r"
[ "$(wc -l <"$j/report.jsonl")" = 1 ] || fail "the report holds only mismatches"
ok run
fi

if want holdout; then
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
"$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" replay run "$j" "$tmp/pen")" = 1 ] || fail "a mismatch on the holdout alone fails the run: $(cat "$tmp/out")"
grep -qx 'requests=2 mismatches=0 classes=0 holdout=1 holdout_mismatches=1' "$tmp/out" || fail "run counts holdout mismatches apart: $(cat "$tmp/out")"
! grep -q pen "$tmp/out" || fail "run prints nothing of a holdout request: $(cat "$tmp/out")"
[ ! -s "$j/report.jsonl" ] || fail "the report a fixer sees holds no holdout mismatch: $(cat "$j/report.jsonl")"
[ "$(jq -r .id "$j/holdout.jsonl")" = pen ] && [ "$(jq -r .class "$j/holdout.jsonl")" = .total ] || fail "holdout.jsonl holds the holdout mismatch for the operator: $(cat "$j/holdout.jsonl")"
"$forge" replay run "$j" "$tmp/old" >/dev/null || fail "a matching port passes"
[ ! -s "$j/holdout.jsonl" ] || fail "a passing run empties holdout.jsonl"
ok holdout
fi

if want bytes; then
texts '{"a":1.0}' '{"name":"caf\u00e9"}' '{"n":18446744073709551617}' '{"a":1,"b":2}' '{"a": 1}' '{"id":"x1","name":"caf\u00e9"}' '{"id":"x1"}' '{"id":"x1","v":[NaN,Infinity,-Infinity]}' \
  '{"a": 1,"b":2}' '{"a":1,"a":2}' '{"x y":"p1","v":1}' '{"a":1, "b":2,"c":3}' '{"id":"x1","v":1 }'
"$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" replay run "$j" cat)" = 0 ] || fail "identical bytes match: $(cat "$tmp/out")"
[ "$(code "$forge" replay run "$j" "$tmp/sub")" = 1 ] || fail "changed bytes fail: $(cat "$tmp/out")"
[ "$(class t1)" = .a ] || fail "1.0 and 1 differ by default: $(class t1)"
[ "$(class t2)" = .name ] || fail "an escaped and a literal é differ by default: $(class t2)"
[ "$(class t3)" = .n ] || fail "integers past 64 bits compare exactly: $(class t3)"
[ "$(class t4)" = order ] || fail "key order differs by default: $(class t4)"
[ "$(class t5)" = space ] || fail "whitespace differs by default: $(class t5)"
[ "$(class t9)" = space ] || fail "whitespace moved to another token differs: $(class t9)"
[ "$(class t12)" = space ] || fail "whitespace moved to another key differs: $(class t12)"
[ "$(class t10)" = body ] || fail "an answer with a duplicate key compares as bytes: $(class t10)"
printf 'ignore .id ids are random\nignore ["x y"] keyed with a space\n' >"$j/rules"
"$forge" replay lock "$j" >/dev/null
"$forge" replay run "$j" "$tmp/sub" >/dev/null || true
[ "$(class t6)" = .name ] || fail "an ignored field leaves the rest byte-exact: $(class t6)"
[ -z "$(class t7)" ] || fail "an ignored field alone matches"
[ -z "$(class t13)" ] || fail "an ignored member missing on one side moves no whitespace: $(class t13)"
[ -z "$(class t11)" ] || fail "a quoted path with a space in its key is ignored: $(class t11)"
[ -z "$(class t8)" ] || fail "an ignored field matches in an answer holding NaN or Infinity, as Python's json writes them: $(class t8)"
printf 'normalize numbers formatting only\nnormalize keys dict order\nnormalize space pretty printing\n' >"$j/rules"
"$forge" replay lock "$j" >/dev/null
"$forge" replay run "$j" "$tmp/sub" >/dev/null || true
[ -z "$(class t1)$(class t4)$(class t5)" ] || fail "normalize rules allow number format, key order and whitespace: $(cat "$j/report.jsonl")"
[ "$(class t2)" = .name ] && [ "$(class t3)" = .n ] || fail "normalize rules keep string escapes and number values: $(cat "$j/report.jsonl")"
ok bytes
fi

if want classes; then
texts '{"lines":[{"name":"a"},{"name":"b"}],"x":1}' 'plain text' '{"a.b":1}' '{"y":{"b":{"c":1}},"x":1}'
"$forge" replay lock "$j" >/dev/null
"$forge" replay run "$j" "$tmp/sub2" >"$tmp/out" || true
[ "$(class t1)" = '.lines[].name .x' ] || fail "a class joins every differing leaf with array indices folded: $(class t1)"
[ "$(class t2)" = body ] || fail "a non-JSON mismatch is class body: $(class t2)"
[ "$(class t3)" = '["a.b"]' ] || fail "a key that is no identifier is quoted: $(class t3)"
[ "$(class t4)" = '.x .y' ] || fail "a class names a missing subtree by its top path only: $(class t4)"
deep=$(printf '%*s' 200000 '' | tr ' ' '['; printf '%*s' 200000 '' | tr ' ' ']')
texts "$deep"
"$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" replay run "$j" cat)" = 0 ] || fail "deeply nested JSON compares: $(head -c 300 "$tmp/out")"
[ "$(code "$forge" replay run "$j" "$tmp/sub2")" = 1 ] && [ -n "$(class t1)" ] || fail "a change deep in nested JSON is a mismatch: $(head -c 300 "$tmp/out")"
[ "$(class t1 | wc -c)" -lt 300 ] || fail "a deep path is shortened in its class: $(class t1 | head -c 300)"
ok classes
fi

if want tamper; then
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
"$forge" replay lock "$j" >/dev/null
printf 'ignore .suggested_tip rounding differs\n' >>"$j/rules"
[ "$(code "$forge" replay run "$j" "$tmp/broken")" = 3 ] || fail "a rule added after lock refuses the run"
grep -q 'changed since it was locked' "$tmp/out" || fail "run says the judge changed: $(cat "$tmp/out")"
! grep -q '^requests=' "$tmp/out" || fail "a refused run replays nothing"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
"$forge" replay lock "$j" >/dev/null
"$tmp/broken" <"$j/requests/towel" >"$j/answers/towel"
[ "$(code "$forge" replay run "$j" "$tmp/broken")" = 3 ] || fail "an answer edited after lock refuses the run"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
"$forge" replay lock "$j" >/dev/null
rm "$j/requests/mug" "$j/answers/mug"
[ "$(code "$forge" replay run "$j" "$tmp/old")" = 3 ] || fail "a request removed after lock refuses the run"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
mv "$j/answers/towel" "$tmp/towel"
ln -s "$tmp/towel" "$j/answers/towel"
"$forge" replay lock "$j" >/dev/null
"$tmp/broken" <"$j/requests/towel" >"$tmp/towel"
[ "$(code "$forge" replay run "$j" "$tmp/broken")" = 3 ] || fail "a symlinked answer whose target changed after lock refuses the run"
seed
"$forge" replay record "$j" "$tmp/old" >/dev/null
"$forge" replay lock "$j" >/dev/null
mv "$j/holdout/pen" "$j/requests/pen"
[ "$(code "$forge" replay run "$j" "$tmp/old")" = 3 ] || fail "a holdout request moved after lock refuses the run"
ok tamper
fi

if want usage; then
[ "$(code "$forge" replay)" = 2 ] || fail "replay with no subcommand exits 2"
[ "$(code "$forge" replay run "$tmp/none" "$tmp/old")" = 1 ] || fail "a missing judge exits 1"
[ "$(code "$forge" replay bogus "$j")" = 2 ] || fail "an unknown subcommand exits 2"
mkdir -p "$tmp/plain" && (cd "$tmp/plain" && [ "$(code "$forge" replay lock "$tmp/none")" = 1 ]) || fail "replay runs outside a forge project"
ok usage
fi

finish
