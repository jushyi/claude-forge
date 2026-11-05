#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

stub_map_claude
repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}

if want map; then
fresh
repo web && repo api
stubbed "$forge" map
[ "$(ls "$STUB_LOG" | wc -l)" = 8 ] || fail "map must spawn four mappers per repo: $(ls "$STUB_LOG")"
for r in web api; do
  for d in STACK INTEGRATIONS ARCHITECTURE CONVENTIONS TESTING CONCERNS; do
    diff -u "$fx/expected/map/$d.md" "$r/.forge/$d.md" || fail "$r $d.md"
  done
  [ "$(json "$r/.forge/concerns.json")" = "$(json "$fx/map/concerns.json")" ] || fail "$r concerns.json"
  [ ! -e "$r/.forge/map" ] || fail "$r/.forge/map must be removed"
  [ "$(git -C "$r" log -1 --format=%s)" = "docs(map): map $r" ] || fail "$r commit"
  [ -z "$(git -C "$r" status --porcelain)" ] || fail "$r must be clean: $(git -C "$r" status --porcelain)"
done
[ "$(calls | grep -c "^cwd: $PWD/web$")" = 4 ] || fail "web mappers run in web"
[ "$(calls | grep -c -- "--agent forge-mapper --effort medium --permission-mode bypassPermissions -p")" = 6 ] || fail "mapper args: $(calls | grep ^args)"
[ "$(calls | grep -c -- "--agent forge-mapper-concerns --effort high --permission-mode bypassPermissions -p")" = 2 ] || fail "concerns args"
grep -qxF "Output: $PWD/web/.forge/map/tech.json" "$STUB_LOG"/call.* || fail "tech output path"
grep -qxF "Current docs: $PWD/web/.forge/STACK.md $PWD/web/.forge/INTEGRATIONS.md" "$STUB_LOG"/call.* || fail "tech gets its current docs"
grep -qxF "Output: $PWD/api/.forge/map/concerns.json" "$STUB_LOG"/call.* || fail "concerns output path"
grep -q "^Current concerns:" "$STUB_LOG"/call.* && fail "no current concerns on a first map"
stubbed "$forge" map web
[ "$(ls "$STUB_LOG" | wc -l)" = 4 ] || fail "map web spawns four"
grep -q -- '--permission-mode bypassPermissions -p' "$STUB_LOG"/call.* || fail "map defaults to bypassPermissions"
FORGE_PERMISSION_MODE=acceptEdits stubbed "$forge" map web
grep -q -- '--permission-mode acceptEdits -p' "$STUB_LOG"/call.* || fail "map honors FORGE_PERMISSION_MODE"
stubbed "$forge" map web
grep -qxF "Current concerns: $PWD/web/.forge/concerns.json" "$STUB_LOG"/call.* || fail "a rerun passes the current concerns"
[ "$(git -C web rev-list --count HEAD)" = 2 ] || fail "an unchanged rerun commits nothing"
echo "- hand" >>web/.forge/STACK.md
jq '.concerns[0].status = "resolved"' web/.forge/concerns.json >"$tmp/c" && mv "$tmp/c" web/.forge/concerns.json
[ "$(STUB_FAIL=arch stubbed code "$forge" map web)" = 1 ] || fail "a failed mapper must fail map"
grep -q "web/.forge/map" "$tmp/out" || fail "failure names the map dir: $(cat "$tmp/out")"
[ -f web/.forge/map/arch.log ] || fail "failure keeps the logs"
[ "$(tail -1 web/.forge/STACK.md)" = "- hand" ] || fail "failure renders nothing"
[ "$(jq -r '.concerns[0].status' web/.forge/concerns.json)" = resolved ] || fail "failure keeps concerns.json"
[ "$(stubbed code "$forge" map nope)" = 2 ] || fail "unknown repo must exit 2"
ok map
fi

if want map-single; then
fresh
repo .
stubbed "$forge" map
[ "$(ls "$STUB_LOG" | wc -l)" = 4 ] || fail "single repo spawns four"
diff -u "$fx/expected/map/STACK.md" .forge/STACK.md || fail "single repo STACK.md"
[ "$(git log -1 --format=%s)" = "docs(map): map p" ] || fail "single repo commit is named for its directory"
[ -z "$(git status --porcelain -- .forge/STACK.md .forge/CONCERNS.md .forge/concerns.json)" ] || fail "single repo docs committed"
ok map-single
fi

if want map-lint; then
fresh
repo web
[ "$(stubbed code "$forge" map web)" = 0 ] || fail "map with the golden TESTING.md must exit 0: $(cat "$tmp/out")"
diff -u "$fx/expected/map/TESTING.md" web/.forge/TESTING.md || fail "golden TESTING.md"
grep -q "TESTING.md" "$tmp/out" && fail "the golden TESTING.md lints clean: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = "docs(map): map web" ] || fail "a clean lint commits the docs"
fresh
repo web
cp -r "$fx/map" "$tmp/badmap"
jq '(.docs[] | select(.doc == "TESTING") | .sections[0].bullets) = ["All tests: `npm test`", "Test: `npm test`", "Changed tests: `npm test`"]' "$fx/map/quality.json" >"$tmp/badmap/quality.json"
[ "$(STUB_FX=$tmp/badmap stubbed code "$forge" map web)" = 1 ] || fail "a TESTING.md failing the lint must fail map: $(cat "$tmp/out")"
grep -qxF "forge: $PWD/web/.forge/TESTING.md: - Test: \`npm test\`: no {test} placeholder" "$tmp/out" || fail "map names the TESTING.md, the Test line and the missing {test}: $(cat "$tmp/out")"
grep -qxF "forge: $PWD/web/.forge/TESTING.md: - Changed tests: \`npm test\`: no {files} placeholder" "$tmp/out" || fail "map prints every lint failure: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = init ] || fail "a failed lint leaves no docs(map) commit: $(git -C web log --format=%s)"
ok map-lint
fi

if want map-doc-lint; then
fresh
repo web
[ "$(stubbed code "$forge" map web)" = 0 ] || fail "map with the golden docs must exit 0: $(cat "$tmp/out")"
grep -q "web/.forge/" "$tmp/out" && fail "the golden docs pass doc_lint: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = "docs(map): map web" ] || fail "golden docs are committed"
fresh
repo web
rm -rf "$tmp/longmap" && cp -r "$fx/map" "$tmp/longmap"
jq --arg b "$(printf '%299s' | tr ' ' x)" '.docs[0].sections[0].bullets[0] = $b' "$fx/map/tech.json" >"$tmp/longmap/tech.json"
[ "$(STUB_FX=$tmp/longmap stubbed code "$forge" map web)" = 0 ] || fail "a rendered bullet over 300 characters only warns: $(cat "$tmp/out")"
grep -qxF "forge: warning: $PWD/web/.forge/STACK.md:7: bullet over 300 characters (301)" "$tmp/out" || fail "map warns with STACK.md, the line and the rule: $(cat "$tmp/out")"
grep -q "docs not committed" "$tmp/out" && fail "a doc-limit warning refuses nothing: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = "docs(map): map web" ] || fail "an over-long bullet still commits the docs: $(git -C web log --format=%s)"
grep -q "^- x\{299\}$" web/.forge/STACK.md || fail "the warned STACK.md is rendered"
[ -z "$(git -C web status --porcelain -- .forge/STACK.md)" ] || fail "the warned STACK.md is committed"
fresh
repo web
rm -rf "$tmp/histmap" && cp -r "$fx/map" "$tmp/histmap"
jq '.docs[0].sections[0].bullets[0] = "`src/server.ts` previously served the intake API"' "$fx/map/arch.json" >"$tmp/histmap/arch.json"
[ "$(STUB_FX=$tmp/histmap stubbed code "$forge" map web)" = 0 ] || fail "a rendered history phrase only warns: $(cat "$tmp/out")"
grep -qxF "forge: warning: $PWD/web/.forge/ARCHITECTURE.md:7: history phrase \"previously\"" "$tmp/out" || fail "map warns with ARCHITECTURE.md, the line and the phrase: $(cat "$tmp/out")"
grep -q "docs not committed" "$tmp/out" && fail "a history warning refuses nothing: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = "docs(map): map web" ] || fail "a history phrase still commits the docs: $(git -C web log --format=%s)"
fresh
repo web
rm -rf "$tmp/concmap" && cp -r "$fx/map" "$tmp/concmap"
jq --arg t "Intake no longer checks the email $(printf '%400s' | tr ' ' y)" '.concerns[0].text = $t' "$fx/map/concerns.json" >"$tmp/concmap/concerns.json"
[ "$(STUB_FX=$tmp/concmap stubbed code "$forge" map web)" = 0 ] || fail "CONCERNS.md over the limits must not fail map: $(cat "$tmp/out")"
grep -q "CONCERNS.md" "$tmp/out" && fail "map does not lint CONCERNS.md: $(cat "$tmp/out")"
[ "$(git -C web log -1 --format=%s)" = "docs(map): map web" ] || fail "an over-limit CONCERNS.md still commits"
ok map-doc-lint
fi

if want resolve; then
fresh
req=$XDG_STATE_HOME/forge/p/features/crm-intake/requirements.json
repo web && mkdir -p web/.forge && cp "$fx/map/concerns.json" web/.forge/
jq '.requirements[0].concern = "web:C-02" | .requirements[1].concern = "web:C-01"' $req >"$tmp/req" \
  && mv "$tmp/req" $req
cp -r web "$tmp/wt"
[ "$("$forge" resolve crm/intake)" = "resolved web:C-02" ] || fail "resolve prints what it resolved"
[ "$(jq -c '[.concerns[].status]' web/.forge/concerns.json)" = '["open","resolved"]' ] || fail "only the done requirement's concern resolves"
[ -f web/.forge/CONCERNS.md ] || fail "CONCERNS.md re-rendered"
! grep -q -- '^- C-02 ' web/.forge/CONCERNS.md || fail "a resolved concern is left out of CONCERNS.md: $(cat web/.forge/CONCERNS.md)"
mkdir -p "$tmp/cwd" && cd "$tmp/cwd"
FORGE_ROOT=$tmp/p "$forge" resolve crm/intake web=../wt >/dev/null
cd "$tmp/p"
[ "$(jq -r '.concerns[1].status' "$tmp/wt/.forge/concerns.json")" = resolved ] || fail "resolve writes the checkout given as <repo>=<dir>"
jq '.requirements[0].concern = "web:C-09"' $req >"$tmp/req" && mv "$tmp/req" $req
[ "$(code "$forge" resolve crm/intake)" = 1 ] || fail "unknown concern must fail"
grep -q "web:C-09" "$tmp/out" || fail "failure names the concern"
[ "$(code "$forge" resolve crm/nope)" = 1 ] || fail "unknown feature must fail"
ok resolve
fi

if want resolve-concern; then
fresh
repo web && mkdir -p web/.forge && cp "$fx/map/concerns.json" web/.forge/
rm -rf "$tmp/qwt" && cp -r web "$tmp/qwt"
[ "$("$forge" resolve --concern web:C-01)" = "resolved web:C-01" ] || fail "resolve --concern prints what it resolved: $("$forge" resolve --concern web:C-01 2>&1)"
[ "$(jq -c '[.concerns[].status]' web/.forge/concerns.json)" = '["resolved","open"]' ] || fail "resolve --concern resolves only the named concern"
[ -f web/.forge/CONCERNS.md ] || fail "resolve --concern re-renders CONCERNS.md"
! grep -q -- '^- C-01 ' web/.forge/CONCERNS.md || fail "resolve --concern leaves the resolved concern out of CONCERNS.md: $(cat web/.forge/CONCERNS.md)"
[ "$(git -C web rev-list --count HEAD)" = 1 ] || fail "resolve --concern commits nothing"
[ -n "$(git -C web status --porcelain -- .forge)" ] || fail "resolve --concern leaves its writes uncommitted"
mkdir -p "$tmp/qcwd" && cd "$tmp/qcwd"
FORGE_ROOT=$tmp/p "$forge" resolve --concern web:C-02 web=../qwt >/dev/null
cd "$tmp/p"
[ "$(jq -c '[.concerns[].status]' "$tmp/qwt/.forge/concerns.json")" = '["open","resolved"]' ] || fail "resolve --concern writes the checkout given as <repo>=<dir>"
[ -f "$tmp/qwt/.forge/CONCERNS.md" ] || fail "resolve --concern renders CONCERNS.md in the given checkout"
[ "$(jq -r '.concerns[1].status' web/.forge/concerns.json)" = open ] || fail "resolve --concern with <repo>=<dir> leaves the default checkout alone"
[ "$(git -C "$tmp/qwt" rev-list --count HEAD)" = 1 ] || fail "resolve --concern commits nothing in the given checkout"
[ "$(code "$forge" resolve --concern web:C-09)" = 1 ] || fail "resolve --concern with an unknown ID must exit 1"
grep -q "web:C-09" "$tmp/out" || fail "unknown ID failure names the concern: $(cat "$tmp/out")"
[ "$(code "$forge" resolve --concern api:C-01)" = 1 ] || fail "resolve --concern for a repo with no directory must exit 1"
grep -q "api:C-01" "$tmp/out" || fail "no-directory failure names the concern: $(cat "$tmp/out")"
[ "$(code "$forge" resolve --concern web-C-01)" = 2 ] || fail "resolve --concern with a malformed token must exit 2"
[ "$(code "$forge" resolve --concern web:C01)" = 2 ] || fail "resolve --concern web:C01 must exit 2"
[ "$(code "$forge" resolve --concern)" = 2 ] || fail "resolve --concern without a token must exit 2"
ok resolve-concern
fi

if want concern-text; then
fresh
repo web && mkdir -p web/.forge
jq '.concerns[0] += {"text": "Intake trusts the client email unchecked", "date": "2026-10-14"}' "$fx/map/concerns.json" >web/.forge/concerns.json
"$forge" validate web/.forge/concerns.json || fail "concern with text and date must validate: $("$forge" validate web/.forge/concerns.json 2>&1)"
cp web/.forge/concerns.json "$tmp/ct"
echo '{"concerns": [' >web/.forge/concerns.json
[ "$(code "$forge" validate web/.forge/concerns.json)" = 1 ] || fail "an unparsable concerns.json must fail validation"
cp "$tmp/ct" web/.forge/concerns.json
[ "$("$forge" resolve --concern web:C-02)" = "resolved web:C-02" ] || fail "resolve --concern on a concerns.json with text: $("$forge" resolve --concern web:C-02 2>&1)"
grep -q -- '^- C-01 — intake — .*Intake trusts the client email unchecked' web/.forge/CONCERNS.md || fail "CONCERNS.md line shows the concern's text: $(cat web/.forge/CONCERNS.md)"
! grep -q -- '^- C-02 ' web/.forge/CONCERNS.md || fail "a resolved concern is left out of CONCERNS.md: $(cat web/.forge/CONCERNS.md)"
ok concern-text
fi
finish
