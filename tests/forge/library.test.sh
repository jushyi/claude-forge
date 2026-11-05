#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
unset COLUMNS

repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m init
}
stub_map_claude
mkdir -p "$tmp/cbin"
printf '#!/usr/bin/env bash\n[ "$*" = "agents --json --all" ] || exit 64\necho "[]"\n' >"$tmp/cbin/claude" && chmod +x "$tmp/cbin/claude"
export HOME=$tmp/home
mkdir -p "$HOME"
cp -r "$root/templates" "$tmp/tpl" && rm -f "$tmp/tpl/render.jq"

sp=$XDG_STATE_HOME/forge/p
run_in() {
  local s=0
  rm -rf "$sp" && cp -a "$tmp/snap" "$sp" && echo "$tmp/$1/p" >"$sp/root"
  (cd "$tmp/$1/p" && FORGE_TEMPLATES=$2 PATH=$tmp/cbin:$PATH "${@:3}") >"$tmp/$1.out" 2>&1 || s=$?
  echo "exit $s" >>"$tmp/$1.out"
  sed -i "s#$tmp/$1/p#<root>#g" "$tmp/$1.out"
  rm -rf "$tmp/$1/state" && mv "$sp" "$tmp/$1/state"
}
same() {
  local want=$1 d
  shift
  for d in a b; do rm -rf "${tmp:?}/$d" && mkdir "$tmp/$d" && cp -a "$tmp/p" "$tmp/$d/p"; done
  [ -d "$tmp/snap" ] || cp -a "$sp" "$tmp/snap"
  run_in a "$root/templates" "$@"
  run_in b "$tmp/tpl" "$@"
  [ "$(tail -1 "$tmp/b.out")" = "exit $want" ] || fail "${*:2} exits $want with no render.jq in FORGE_TEMPLATES: $(cat "$tmp/b.out")"
  diff -u "$tmp/a.out" "$tmp/b.out" || fail "${*:2} prints the same with no render.jq in FORGE_TEMPLATES"
  diff -r -x .git "$tmp/a/p" "$tmp/b/p" || fail "${*:2} writes the same files with no render.jq in FORGE_TEMPLATES"
  diff -r -x root "$tmp/a/state" "$tmp/b/state" || fail "${*:2} writes the same state records with no render.jq in FORGE_TEMPLATES"
}

if want forge-jq; then
lib=$root/bin/forge.d/forge.jq
[ -f "$lib" ] || fail "bin/forge.d/forge.jq holds the jq library"
for d in load status open fdir shipped qual pdone progress fstatus stalled unmet fcell intake day \
  status_json reqs cphase lastact shipped_json todo_items todo_line strip clean entries sentences sentence_lines sentence_bullet \
  map_doc concerns_doc dash bullets csv first_more pad grid cell paras research table; do
  grep -qE "^def $d[:(]" "$lib" || fail "forge.jq defines $d"
done
for d in fill track_doc feature_doc procedure_doc build_doc phase_doc state_doc docs steps stage next_step reflow; do
  ! grep -qE "^\s*def $d[:(]" "$lib" || fail "forge.jq drops $d, which only builds planning Markdown or reflows docs"
done
[ "$(jq -n -c -L "$root/bin/forge.d" 'include "forge"; "One. Two? Three! Four", "See e.g. Foo. Bar" | [sentences]' 2>&1)" = '["One.","Two?","Three!","Four"]
["See e.g. Foo.","Bar"]' ] || fail "include \"forge\" from bin/forge.d gives sentences"

fresh
jq '.requirements[0].text = "The form in `src/form.ts` saves a lead."' $sp/features/crm-intake/requirements.json >"$tmp/r" && mv "$tmp/r" $sp/features/crm-intake/requirements.json
jq '.spec += ["Files: db/leads.sql, src/form.ts:12, src/other.ts (new)."]' $sp/phases/02-intake-form/spec.json >"$tmp/s" && mv "$tmp/s" $sp/phases/02-intake-form/spec.json
echo '{"concerns": [{"id": "C-01", "area": "intake", "files": ["src/form.ts"], "severity": "high", "evidence": [], "status": "open", "text": "Form trusts the email", "date": "2026-09-30"}]}' >.forge/concerns.json
printf -- '- 2026-10-01 Old idea\n' >.forge/seeds.md
mkdir -p $sp/features/crm-export && cp "$fx/alloc-deps/files-shared.split.json" $sp/features/crm-export/split.json
repo .
rm -rf "$tmp/snap"
same 0 "$forge" status
same 0 "$forge" status --json
same 1 "$forge" check 02
grep -qxF "src/other.ts is named in the phase spec Files but in no task's files and not in na_files" "$tmp/b.out" || fail "check reads the spec Files entries through forge.jq: $(cat "$tmp/b.out")"
same 1 "$forge" alloc crm/export
grep -qF "phase export-core and phase export-ui both plan src/export.ts with no dependency path" "$tmp/b.out" || fail "alloc refuses overlapping files through forge.jq: $(cat "$tmp/b.out")"
same 0 "$forge" concern add p perf low src/a.ts src/b.ts -- 'Lookups scan every lead'
grep -qxF "added p:C-02" "$tmp/b.out" || fail "concern add renders CONCERNS.md through forge.jq: $(cat "$tmp/b.out")"

fresh
repo .
[ "$(FORGE_TEMPLATES=$tmp/tpl stubbed code "$forge" map)" = 0 ] || fail "map with no render.jq in FORGE_TEMPLATES must exit 0: $(cat "$tmp/out")"
for d in STACK INTEGRATIONS ARCHITECTURE CONVENTIONS TESTING CONCERNS; do
  diff -u "$fx/expected/map/$d.md" ".forge/$d.md" || fail "map renders $d.md through forge.jq"
done

for c in check map; do
  h=$("$forge" "$c" --help)
  grep -qF 'bin/forge.d/forge.jq' <<<"$h" || fail "forge $c --help names bin/forge.d/forge.jq"
  ! grep -qi 'render' <<<"$h" || fail "forge $c --help drops render.jq and rendered-file wording: $(grep -i render <<<"$h")"
done

for t in concern; do
  ! grep -qF 'include "render"' "$root/tests/forge/$t.test.sh" || fail "tests/forge/$t.test.sh includes forge, not render"
  grep -qF -- '-L "$root/bin/forge.d"' "$root/tests/forge/$t.test.sh" || fail "tests/forge/$t.test.sh loads the library from bin/forge.d"
done
ok forge-jq
fi

finish
