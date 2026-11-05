#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

mk() { cat >"$tmp/$1" && chmod +x "$tmp/$1"; }
mk old <<'EOF2'
#!/usr/bin/env bash
jq -c --arg id "$RANDOM$RANDOM" '{tip: .tip, receipt_id: $id}'
EOF2
judge() {
  fresh
  j=$XDG_STATE_HOME/forge/p/port/towel
  rm -rf "$j"
  mkdir -p "$j/requests" "$j/holdout"
  echo '{"tip":0.04}' >"$j/requests/r1"
  echo '{"tip":1}' >"$j/holdout/h1"
  echo 'ignore .receipt_id uuid4 per receipt' >"$j/rules"
  echo '2 3' >"$j/cutover"
  "$forge" replay record "$j" "$tmp/old" >/dev/null
  "$forge" replay lock "$j" >/dev/null
}
line() { jq -nc --arg id "$1" --arg at "$2" --arg old "$3" --arg new "$4" '{id: $id, at: $at, request: "{\"tip\":0.04}", old: $old, new: $new}'; }
ok1='{"tip":0.04,"receipt_id":"a"}'
ok2='{"tip":0.04,"receipt_id":"b"}'
bad='{"tip":0.05,"receipt_id":"c"}'

if want refuse; then
judge
line q1 2026-11-01T00:00:00Z "$ok1" "$ok2" >"$tmp/feed"
[ "$(code "$forge" shadow nope "$tmp/feed")" = 1 ] && grep -q 'no /forge-port judge nope' "$tmp/out" || fail "shadow names a missing judge: $(cat "$tmp/out")"
rm "$j/lock"
[ "$(code "$forge" shadow towel "$tmp/feed")" = 3 ] || fail "shadow refuses an unlocked judge: $(cat "$tmp/out")"
[ "$(code "$forge" cutover towel)" = 3 ] || fail "cutover refuses an unlocked judge: $(cat "$tmp/out")"
judge
echo '1 1' >"$j/cutover"
[ "$(code "$forge" shadow towel "$tmp/feed")" = 3 ] && grep -q 'changed since it was locked' "$tmp/out" || fail "shadow refuses a gate changed after lock: $(cat "$tmp/out")"
judge
rm "$j/cutover" && "$forge" replay lock "$j" >/dev/null
[ "$(code "$forge" shadow towel "$tmp/feed")" = 1 ] && grep -q 'no cutover gate' "$tmp/out" || fail "shadow needs a locked cutover gate: $(cat "$tmp/out")"
judge
echo 'soon' >"$j/cutover"
[ "$(code "$forge" replay lock "$j")" = 1 ] && grep -q 'cutover' "$tmp/out" || fail "lock refuses a bad cutover gate: $(cat "$tmp/out")"
judge
{ line q1 2026-11-01T00:00:00Z "$ok1" "$ok2"; echo '{"id":"q2","old":"x","new":"x"}'; } >"$tmp/feed"
[ "$(code "$forge" shadow towel "$tmp/feed")" = 1 ] && grep -q 'feed line 2' "$tmp/out" || fail "shadow names a feed line missing a field: $(cat "$tmp/out")"
[ ! -s "$j/shadow.jsonl" ] || fail "a bad feed records nothing"
ok refuse
fi

if want shadow; then
judge
{ line q1 2026-11-01T00:00:00Z "$ok1" "$ok2"; line q2 2026-11-01T00:10:00Z "$ok1" "$bad"; line q3 2026-11-01T00:20:00+00:00 "$ok1" "$ok2"; } >"$tmp/feed"
[ "$(code "$forge" shadow towel "$tmp/feed")" = 1 ] || fail "a live mismatch fails shadow: $(cat "$tmp/out")"
grep -qx 'shadow: 3 compared, 1 mismatches, 0 already seen' "$tmp/out" || fail "shadow counts the batch: $(cat "$tmp/out")"
grep -qx 'class .tip 1 q2' "$tmp/out" || fail "shadow prints each class with the judge's rules applied: $(cat "$tmp/out")"
[ "$(wc -l <"$j/shadow.jsonl")" = 3 ] || fail "shadow records every compared line"
[ "$(jq -r 'select(.id == "q2") | .new' "$j/shadow.jsonl")" = "$bad" ] || fail "a mismatch keeps both answers for the operator: $(cat "$j/shadow.jsonl")"
[ "$(jq -r 'select(.id == "q1") | has("new")' "$j/shadow.jsonl")" = false ] || fail "a match keeps no payload"
[ "$(code "$forge" shadow towel "$tmp/feed")" = 0 ] && grep -qx 'shadow: 0 compared, 0 mismatches, 3 already seen' "$tmp/out" || fail "shadow skips ids it has seen: $(cat "$tmp/out")"
line q4 2026-11-01T00:30:00Z "$ok1" "$ok2" | "$forge" shadow towel - >"$tmp/out" || fail "shadow reads a feed on stdin: $(cat "$tmp/out")"
grep -qx 'shadow: 1 compared, 0 mismatches, 0 already seen' "$tmp/out" || fail "stdin feed counted: $(cat "$tmp/out")"
ok shadow
fi

if want cutover; then
judge
[ "$(code "$forge" cutover towel)" = 1 ] && grep -q '^cutover: wait: 0.0h and 0 requests clean' "$tmp/out" || fail "cutover waits with no shadow traffic: $(cat "$tmp/out")"
{ line q1 2026-11-01T00:00:00Z "$ok1" "$ok2"; line q2 2026-11-01T01:00:00Z "$ok1" "$bad"; line q3 2026-11-01T01:30:00Z "$ok1" "$ok2"; line q4 2026-11-01T02:00:00Z "$ok1" "$ok2"; } >"$tmp/feed"
"$forge" shadow towel "$tmp/feed" >/dev/null || true
[ "$(code "$forge" cutover towel)" = 1 ] || fail "a short window waits: $(cat "$tmp/out")"
grep -qx 'cutover: wait: 1.0h and 2 requests clean since 2026-11-01T01:00:00+00:00; needs 2h and 3' "$tmp/out" || fail "the window starts at the last mismatch: $(cat "$tmp/out")"
line q5 2026-11-01T03:00:00Z "$ok1" "$ok2" | "$forge" shadow towel - >/dev/null
[ "$(code "$forge" cutover towel)" = 0 ] || fail "a clean window long enough passes: $(cat "$tmp/out")"
grep -qx 'cutover: go: 2.0h and 3 requests clean since 2026-11-01T01:00:00+00:00; needs 2h and 3' "$tmp/out" || fail "cutover says go: $(cat "$tmp/out")"
line q6 2026-11-01T03:10:00Z "$ok1" "$bad" | "$forge" shadow towel - >/dev/null || true
[ "$(code "$forge" cutover towel)" = 1 ] && grep -q 'wait: 0.0h and 0 requests clean since 2026-11-01T03:10:00+00:00' "$tmp/out" || fail "a new mismatch restarts the window: $(cat "$tmp/out")"
judge
line q1 2026-11-01T00:00:00Z "$ok1" "$ok2" | "$forge" shadow towel - >/dev/null
echo 'normalize space pretty printer' >>"$j/rules" && "$forge" replay lock "$j" >/dev/null
"$forge" cutover towel >"$tmp/out" || true
grep -q 'wait: 0.0h and 0 requests' "$tmp/out" || fail "a relocked judge restarts the window: $(cat "$tmp/out")"
line q2 2026-11-01T00:00:00Z "$ok1" "$ok2" | "$forge" shadow towel - >/dev/null
"$forge" replay lock "$j" >/dev/null
"$forge" cutover towel >"$tmp/out" || true
grep -q 'wait: 0.0h and 0 requests' "$tmp/out" || fail "relocking an unchanged judge restarts the window: $(cat "$tmp/out")"
judge
for i in $(seq 1 300); do line "c$i" 2026-11-01T00:00:00Z "$ok1" "$ok2"; done >"$tmp/feed"
for k in 1 2 3 4; do "$forge" shadow towel "$tmp/feed" >/dev/null & done
wait
[ "$(jq -r .id "$j/shadow.jsonl" | sort | uniq -d | wc -l)" = 0 ] && [ "$(wc -l <"$j/shadow.jsonl")" = 300 ] || fail "overlapping shadow runs record each id once: $(wc -l <"$j/shadow.jsonl") lines"
ok cutover
fi

finish
