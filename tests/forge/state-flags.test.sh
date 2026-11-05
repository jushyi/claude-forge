#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
sp=$XDG_STATE_HOME/forge/p

if want build-flag; then
fresh
fs=$sp/features/crm-intake/spec.json s=$sp/features/crm-routing/split.json
for v in true false; do
  jq ".build = $v" $fs >"$tmp/spec" && mv "$tmp/spec" $fs
  "$forge" validate || fail "build $v must validate with no arguments: $("$forge" validate 2>&1)"
  "$forge" validate $fs || fail "build $v must validate named: $("$forge" validate $fs 2>&1)"
done
for v in '"yes"' 1 null '[true]'; do
  cp $fs "$tmp/good"
  jq ".build = $v" $fs >"$tmp/bad" && mv "$tmp/bad" $fs
  [ "$(code "$forge" validate $fs)" = 1 ] || fail "$fs with build $v must fail named"
  grep -qF "${fs##*/}" "$tmp/out" || fail "failure must name ${fs##*/}: $(cat "$tmp/out")"
  [ "$(code "$forge" validate)" = 1 ] || fail "$fs with build $v must fail with no arguments"
  grep -qF "${fs##*/}" "$tmp/out" || fail "failure must name ${fs##*/}: $(cat "$tmp/out")"
  cp "$tmp/good" $fs
done
for v in true false; do
  cp $s "$tmp/good"
  jq ".phases[0].procedure = $v" $s >"$tmp/bad" && mv "$tmp/bad" $s
  [ "$(code "$forge" validate $s)" = 1 ] || fail "a split phase with procedure $v must fail named"
  grep -qF "${s##*/}" "$tmp/out" || fail "failure must name ${s##*/}: $(cat "$tmp/out")"
  [ "$(code "$forge" validate)" = 1 ] || fail "a split phase with procedure $v must fail with no arguments"
  cp "$tmp/good" $s
done
ok build-flag
fi
finish
