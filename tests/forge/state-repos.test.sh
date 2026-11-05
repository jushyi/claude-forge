#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
sp=$XDG_STATE_HOME/forge/p

if want split-contracts; then
fresh
s=$sp/features/crm-routing/split.json
jq '.phases[0].contracts = ["lead-api"]' $s >"$tmp/split" && mv "$tmp/split" $s
[ "$(code "$forge" validate $s)" = 1 ] || fail "a split phase with contracts must fail"
ok split-contracts
fi

if want repos-validate; then
fresh
rm -rf "$tmp/lumen" "$tmp/x" "$tmp/api"
mkdir -p "$tmp/lumen/.forge" "$tmp/x/lumen/.forge" api/.forge
git -C "$tmp/lumen" init -q && git -C "$tmp/x/lumen" init -q && git -C api init -q
s=$sp/features/crm-routing/split.json
echo '{"repos": ["../lumen", "../x/lumen/"]}' >.forge/repos.json
[ "$(code "$forge" validate)" = 1 ] || fail "repos.json entries sharing a basename must fail with no arguments"
grep -q "repos.json" "$tmp/out" && grep -q "lumen" "$tmp/out" || fail "shared basename failure must name repos.json and the basename: $(cat "$tmp/out")"
[ "$(cd "$tmp" && code "$forge" validate p/.forge/repos.json)" = 1 ] || fail "repos.json entries sharing a basename must fail named from another cwd"
grep -q "repos.json" "$tmp/out" && grep -q "lumen" "$tmp/out" || fail "named shared basename failure must name repos.json and the basename: $(cat "$tmp/out")"
echo '{"repos": ["../lumen"]}' >.forge/repos.json
for r in lumen api; do
  jq --arg r $r '.phases[0].repo = $r' $s >"$tmp/split" && mv "$tmp/split" $s
  "$forge" validate || fail "split phase repo $r must validate with no arguments: $("$forge" validate 2>&1)"
  (cd "$tmp" && "$forge" validate $s) || fail "split phase repo $r must validate named from another cwd: $(cd "$tmp" && "$forge" validate $s 2>&1)"
done
jq '.phases[0].repo = "nowhere"' $s >"$tmp/split" && mv "$tmp/split" $s
[ "$(code "$forge" validate)" = 1 ] || fail "split phase repo resolving to nothing must fail with no arguments"
grep -q "split.json" "$tmp/out" && grep -q "nowhere" "$tmp/out" || fail "unknown repo failure must name split.json and the repo: $(cat "$tmp/out")"
[ "$(cd "$tmp" && code "$forge" validate $s)" = 1 ] || fail "split phase repo resolving to nothing must fail named from another cwd"
grep -q "split.json" "$tmp/out" && grep -q "nowhere" "$tmp/out" || fail "named unknown repo failure must name split.json and the repo: $(cat "$tmp/out")"
"$forge" validate --help | grep -q "basename" || fail "validate help describes the shared basename check"
ok repos-validate
fi
finish
