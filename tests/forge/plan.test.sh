#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
S=$XDG_STATE_HOME/forge/p

if want ready; then
fresh
[ "$("$forge" ready crm/export)" = ready ] || fail "crm/export is ready"
[ "$(code "$forge" ready crm/routing)" = 1 ] || fail "crm/routing waits"
[ "$(cat "$tmp/out")" = "waiting on: intake" ] || fail "crm/routing waits on intake: $(cat "$tmp/out")"
[ "$(code "$forge" ready voice/capture)" = 0 ] || fail "voice/capture depends only on shipped crm/auth"
[ "$(code "$forge" ready crm/nope)" = 2 ] || fail "unknown feature must exit 2"
[ "$(code "$forge" ready old/legacy)" = 2 ] || fail "closed track must exit 2"
ok ready
fi

if want alloc; then
fresh
[ "$("$forge" alloc crm/routing)" = "$(printf "$S/phases/05-routing-rules\n$S/phases/06-routing-ui")" ] || fail "alloc must create 05 and 06"
[ "$(jq -c '[.phases[].number]' "$S"/features/crm-routing/split.json)" = '["05","06"]' ] || fail "split numbers"
[ "$(json "$S"/phases/06-routing-ui/spec.json)" = "$(json <<<'{"track":"crm","feature":"routing","number":"06","slug":"routing-ui","goal":"Owners see their leads","spec":[],"requirements":["ROUTE-01"],"depends":["05"]}')" ] || fail "derived phase spec"
[ -z "$("$forge" alloc crm/routing)" ] || fail "rerun must not allocate"
[ -z "$("$forge" alloc crm/intake)" ] || fail "numbered phases keep their numbers"
"$forge" validate || fail "allocated files must validate"
jq '.phases += [{"slug": "routing-audit", "goal": "Log moves", "spec": [], "requirements": [], "depends": ["routing-ui"]}]' "$S"/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-routing/split.json
[ "$("$forge" alloc crm/routing)" = "$S"/phases/07-routing-audit ] || fail "a new phase takes the next number"
[ "$(jq -c .depends "$S"/phases/07-routing-audit/spec.json)" = '["06"]' ] || fail "new phase depends on 06"
for d in 05-routing-rules 06-routing-ui; do
  cp "$S"/phases/02-intake-form/{research,scout,plan,review,result}.json "$S"/phases/$d/
  echo '{"questions": []}' >"$S"/phases/$d/gaps.json
  cp -r "$S"/phases/02-intake-form/tasks "$S"/phases/$d/
  mkdir "$S"/phases/$d/{tests,fixes,review,research}
  cp "$S"/phases/02-intake-form/research.json "$S"/phases/$d/research/R1.json
  echo '{"findings": []}' >"$S"/phases/$d/review/reviewer.json
done
jq '(.phases[] | select(.slug == "routing-ui") | .goal) = "Owners see and sort their leads"' "$S"/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-routing/split.json
[ "$("$forge" alloc crm/routing)" = "replan "$S"/phases/06-routing-ui" ] || fail "a changed phase is reset for replan"
[ "$(jq -r .goal "$S"/phases/06-routing-ui/spec.json)" = "Owners see and sort their leads" ] || fail "reset phase gets the new spec"
[ "$(ls "$S"/phases/06-routing-ui | paste -sd ' ')" = "fixes review review.json spec.json" ] || fail "a spec change removes plan.json, tasks/, tests/, result.json and the legacy research, scout and gaps records, leaving the spec and legacy review records: $(ls "$S"/phases/06-routing-ui)"
[ "$(ls "$S"/phases/05-routing-rules | wc -l)" = 12 ] || fail "an unchanged phase keeps its files"
[ -f "$S"/phases/05-routing-rules/review/reviewer.json ] || fail "an unchanged phase keeps review/"
[ -z "$("$forge" alloc crm/routing)" ] || fail "rerun after a reset changes nothing"
[ "$(code "$forge" alloc crm/export)" = 1 ] || fail "alloc without split must fail"
mkdir -p api/.forge && git -C api init -q
jq '.phases += [{"slug": "routing-sync", "repo": "api", "goal": "Sync", "spec": [], "requirements": [], "depends": []}]' "$S"/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-routing/split.json
"$forge" alloc crm/routing >/dev/null
[ "$(jq -r .repo "$S"/phases/08-routing-sync/spec.json)" = api ] || fail "alloc copies the phase repo"
[ "$(jq -r '.repo // "none"' "$S"/phases/07-routing-audit/spec.json)" = none ] || fail "no repo without one in the split"
[ ! -e .forge/phases ] && [ ! -e .forge/features ] && [ ! -e .forge/archive ] || fail "alloc writes no phase or feature record under .forge: $(ls -A .forge)"
jq '.phases += [{"number": "01", "slug": "auth-login", "goal": "Log in", "spec": [], "requirements": [], "depends": []}]' "$S"/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-routing/split.json
[ -z "$("$forge" alloc crm/routing)" ] || fail "a phase archived in the state dir is not allocated again"
[ ! -e "$S"/phases/01-auth-login ] && [ ! -e .forge/phases ] || fail "a phase archived in the state dir gets no new directory"
ok alloc
fi

if want alloc-focus; then
fresh
s="$S"/features/crm-intake/split.json
jq '(.phases[] | select(.slug == "intake-api") | .focus) = ["security"]' $s >"$tmp/split" && mv "$tmp/split" $s
out=$("$forge" alloc crm/intake)
[ "$out" = "replan "$S"/phases/03-intake-api" ] || fail "a focus change replans only its phase: $out"
[ "$(jq -c .focus "$S"/phases/03-intake-api/spec.json)" = '["security"]' ] || fail "alloc copies the split phase focus"
[ "$(jq -c .focus "$S"/phases/02-intake-form/spec.json)" = '["pii"]' ] || fail "an unchanged phase keeps its focus"
"$forge" validate || fail "copied focus must validate: $("$forge" validate 2>&1)"
[ -z "$("$forge" alloc crm/intake)" ] || fail "rerun after a focus change changes nothing"
jq '(.phases[] | select(.slug == "intake-api") | .focus) = ["security", "pii"]' $s >"$tmp/split" && mv "$tmp/split" $s
"$forge" alloc crm/intake >/dev/null
jq '(.phases[] | select(.slug == "intake-api") | .focus) = ["pii", "security"]' $s >"$tmp/split" && mv "$tmp/split" $s
out=$("$forge" alloc crm/intake)
[ -z "$out" ] || fail "reordering the focus tags does not replan: $out"
"$forge" alloc --help | grep -q "focus" || fail "alloc help says a derived spec carries the focus"
ok alloc-focus
fi

if want alloc-targets; then
fresh
s="$S"/features/crm-intake/split.json
fs="$S"/features/crm-intake/spec.json
jq '.focus += ["scaling"] | .targets = {"rps": 100, "max_rows": 200}' $fs >"$tmp/spec" && mv "$tmp/spec" $fs
jq '(.phases[] | select(.slug == "intake-api") | .focus) = ["scaling"]' $s >"$tmp/split" && mv "$tmp/split" $s
out=$("$forge" alloc crm/intake)
[ "$out" = "replan "$S"/phases/03-intake-api" ] || fail "only the refocused phase replans: $out"
[ "$(jq -c .targets "$S"/phases/03-intake-api/spec.json)" = '{"max_rows":200,"rps":100}' ] || fail "alloc copies targets into a scaling phase: $(json "$S"/phases/03-intake-api/spec.json)"
[ "$(jq -c '.pii_fields // "none"' "$S"/phases/03-intake-api/spec.json)" = '"none"' ] || fail "alloc copies no pii_fields into a phase without pii focus"
[ "$(jq -c .pii_fields "$S"/phases/02-intake-form/spec.json)" = '["name","email"]' ] || fail "alloc copies pii_fields into a pii phase: $(json "$S"/phases/02-intake-form/spec.json)"
[ "$(jq -c '.targets // "none"' "$S"/phases/02-intake-form/spec.json)" = '"none"' ] || fail "alloc copies no targets into a phase without scaling or performance focus"
"$forge" validate || fail "copied targets and pii_fields must validate: $("$forge" validate 2>&1)"
[ -z "$("$forge" alloc crm/intake)" ] || fail "rerun after copying targets changes nothing"
jq '.targets.rps = 250' $fs >"$tmp/spec" && mv "$tmp/spec" $fs
out=$("$forge" alloc crm/intake)
[ "$out" = "replan "$S"/phases/03-intake-api" ] || fail "a changed feature targets replans the scaling phase only: $out"
[ "$(jq -c .targets "$S"/phases/03-intake-api/spec.json)" = '{"max_rows":200,"rps":250}' ] || fail "replanned phase gets the new targets"
jq '(.phases[] | select(.slug == "intake-api") | .focus) = ["performance", "pii"] | (.phases[] | select(.slug == "intake-form") | .focus) = ["pii", "scaling"]' $s >"$tmp/split" && mv "$tmp/split" $s
"$forge" alloc crm/intake >/dev/null
[ "$(jq -c '[.targets // "none", .pii_fields]' "$S"/phases/03-intake-api/spec.json)" = '["none",["name","email"]]' ] || fail "a performance and pii phase gets pii_fields and no targets: $(json "$S"/phases/03-intake-api/spec.json)"
[ "$(jq -c '[.targets, .pii_fields]' "$S"/phases/02-intake-form/spec.json)" = '[{"max_rows":200,"rps":250},["name","email"]]' ] || fail "a scaling and pii phase still gets both: $(json "$S"/phases/02-intake-form/spec.json)"
jq '.pii_fields = ["email"]' $fs >"$tmp/spec" && mv "$tmp/spec" $fs
out=$("$forge" alloc crm/intake)
[ "$out" = "$(printf "replan $S/phases/02-intake-form\nreplan $S/phases/03-intake-api")" ] || fail "a changed feature pii_fields replans the pii phases: $out"
h=$("$forge" alloc --help)
for x in targets pii_fields; do grep -qF -- "$x" <<<"$h" || fail "alloc help says a derived spec carries $x"; done
! grep -qF performance <<<"$h" || fail "alloc help says targets reach scaling phases only"
ok alloc-targets
fi

if want archive; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo a >app.txt
git add -A && git commit -q -m init && git branch forge/crm-intake
git branch forge/crm-intake-02 && git branch forge/crm-intakes && git branch forge/crm-intake-v2
git worktree add -q -b forge/crm-intake-03 .claude/worktrees/crm-intake-03 main
echo b >app.txt && echo u >untracked.txt
[ "$(code "$forge" archive crm/routing)" = 1 ] || fail "archive without ship.json must fail"
jq '(.requirements[] | select(.id == "INT-02")).owed = {"kind": "deferred", "check": "The API returns the lead.", "owner": "crm/routing"}' "$S/features/crm-intake/requirements.json" >"$tmp/req" && mv "$tmp/req" "$S/features/crm-intake/requirements.json"
echo '{"final_review": ["No findings"], "pr": "https://example.com/pr/1", "date": "2026-09-25"}' >"$S"/features/crm-intake/ship.json
head=$(git rev-parse HEAD)
[ "$(code "$forge" archive crm/intake)" = 0 ] || fail "archive with leftovers must still exit 0: $(cat "$tmp/out")"
printf 'forge: leftover: %s\n' "branch forge/crm-intake-02 in $PWD" "branch forge/crm-intake-03 in $PWD" "worktree $PWD/.claude/worktrees/crm-intake-03" "uncommitted app.txt in $PWD" >"$tmp/want"
echo "forge: nothing to collect" >>"$tmp/want"
diff -u "$tmp/want" "$tmp/out" || fail "archive prints each leftover branch, worktree and uncommitted tracked file outside .forge/"
! git show-ref -q --verify refs/heads/forge/crm-intake || fail "archive deletes the merged feature branch"
[ ! -e "$S"/features/crm-intake ] || fail "feature dir must move"
[ ! -e .forge/archive ] && [ ! -e .forge/features ] && [ ! -e .forge/phases ] || fail "archive moves the feature and its phases inside the state dir, never into .forge: $(ls .forge)"
[ ! -e "$S/archive/crm-intake/FEATURE.md" ] || fail "archive writes no FEATURE.md"
[ "$(jq -r .pr "$S/archive/crm-intake/ship.json")" = "https://example.com/pr/1" ] || fail "archived ship.json keeps the PR"
[ -d "$S/archive/crm-intake/phases/02-intake-form" ] && [ -d "$S/archive/crm-intake/phases/03-intake-api" ] || fail "phases must move to the state dir archive: $(find "$S" -maxdepth 4 -type d | sort)"
[ -f "$S/archive/crm-intake/phases/02-intake-form/plan.json" ] || fail "an archived phase keeps its records"
[ -d "$S/archive/crm-auth/phases/01-auth-login" ] || fail "earlier archives stay"
[ -z "$(ls -d "$S"/phases/0[23]-* 2>/dev/null)" ] || fail "phases dir still holds 02 or 03"
[ "$(jq -c '[.features[].feature]' .forge/tracks/crm.json)" = '["routing","export","audit"]' ] || fail "track features"
[ "$(jq -c '.shipped[-1]' .forge/tracks/crm.json)" = '{"feature":"intake","phases":["02","03"],"date":"2026-09-25"}' ] || fail "track shipped line"
[ -z "$(find .forge "$S" -name '*.md' ! -name 04-hand.md ! -name todo.md)" ] || fail "archive moves only JSON and writes no Markdown: $(find .forge "$S" -name '*.md' ! -name 04-hand.md ! -name todo.md)"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "archive commits nothing itself"
[ "$(git status --porcelain -- .forge)" = " M .forge/tracks/crm.json" ] || fail "archive leaves only tracks/crm.json to commit: $(git status --porcelain -- .forge)"
[ "$(code "$forge" commit crm/intake archive)" = 0 ] || fail "the archive commit: $(cat "$tmp/out")"
grep -qx "forge: committed [0-9a-f]* (1 files) forge(crm/intake): archive" "$tmp/out" || fail "the archive commit commits one file: $(cat "$tmp/out")"
[ "$(git show --name-only --format= HEAD)" = .forge/tracks/crm.json ] || fail "the archive commit holds only tracks/crm.json: $(git show --name-only --format= HEAD)"
[ -z "$(git status --porcelain -- .forge)" ] || fail "the archive commit leaves .forge clean: $(git status --porcelain -- .forge)"
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit crm/intake archive)" = 0 ] && grep -qxF "forge: recorded crm/intake archive" "$tmp/out" || fail "a rerun archive commit prints the recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a recorded archive step commits nothing"
[ "$("$forge" ready crm/routing)" = ready ] || fail "routing is ready once intake ships"
[ "$("$forge" alloc crm/routing)" = "$(printf "$S/phases/05-routing-rules\n$S/phases/06-routing-ui")" ] || fail "numbers continue past archived phases"
[ ! -e .forge/phases ] || fail "alloc after archive writes no phase under .forge"
ok archive
fi

if want archive-push; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
rm -rf "$tmp/origin.git" && git init -q --bare -b main "$tmp/origin.git"
git remote add origin "$tmp/origin.git" && git push -q origin main && git config forge.pushMain true
git branch forge/crm-intake && git push -q origin forge/crm-intake
jq '(.requirements[] | select(.id == "INT-02")).owed = {"kind": "deferred", "check": "The API returns the lead.", "owner": "crm/routing"}' "$S/features/crm-intake/requirements.json" >"$tmp/req" && mv "$tmp/req" "$S/features/crm-intake/requirements.json"
echo '{"final_review": ["No findings"], "pr": null, "date": "2026-09-25"}' >"$S/features/crm-intake/ship.json"
[ "$(code "$forge" archive crm/intake)" = 0 ] || fail "archive with pushMain: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf 'forge: leftover: origin branch forge/crm-intake in %s\nforge: nothing to collect' "$PWD")" ] || fail "archive with pushMain prints a feature branch left on origin: $(cat "$tmp/out")"
[ -d "$S/archive/crm-intake/phases/03-intake-api" ] || fail "archive with pushMain moves the feature inside the state dir"
[ "$(code "$forge" commit crm/intake archive)" = 0 ] || fail "archive commit with pushMain must exit 0: $(cat "$tmp/out")"
[ "$(git --git-dir="$tmp/origin.git" rev-parse main)" = "$(git rev-parse main)" ] || fail "the archive commit pushes main to origin"
ok archive-push
fi

repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}
stub_run_claude
ph() { jq -cn --arg slug "$1" --arg repo "$2" --argjson depends "$3" '{$slug} + (if $repo == "" then {} else {$repo} end) + {goal: $slug, spec: [], requirements: [], $depends}'; }

if want alloc-live; then
fresh
echo '{"time": "2026-09-21T10:00:00Z", "step": "start", "message": "P02"}' >>"$S/phases/02-intake-form/events.jsonl"
echo '[{"id": "a1", "name": "p P02 crm/intake", "state": "working"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" alloc crm/intake)" = 1 ] || fail "alloc must refuse while a started phase of the feature in the state dir has a live session: $(cat "$tmp/out")"
grep -qxF "forge: crm/intake has a live session p P02 crm/intake; alloc after it ends" "$tmp/out" || fail "the refusal names the live session: $(cat "$tmp/out")"
echo '[{"id": "a1", "name": "p P02 crm/intake", "state": "idle"}]' >"$CLAUDE_AGENTS"
[ "$(code "$forge" alloc crm/intake)" = 0 ] || fail "alloc runs once the session is idle: $(cat "$tmp/out")"
ok alloc-live
fi

if want plan-help; then
for c in alloc archive; do
  "$forge" "$c" --help >"$tmp/help"
  ! grep -nE '\.forge/(phases|features|archive)' "$tmp/help" || fail "forge $c --help names no in-repo phase, feature or archive path"
  grep -qE 'STATE/(phases|features|archive)' "$tmp/help" || fail "forge $c --help names the state dir records as STATE/...: $(cat "$tmp/help")"
done
ok plan-help
fi

refuseset() {
  fresh
  rm -rf "$tmp/atlas" "$tmp/cold" && repo "$tmp/atlas" && repo "$tmp/cold" && mkdir -p "$tmp/atlas/.forge"
  repo web && mkdir -p web/.forge && repo api
  echo '{"repos": ["../atlas", "../cold"]}' >.forge/repos.json
  mkdir -p "$S"/features/crm-export
  echo "{\"phases\": $1}" >"$S"/features/crm-export/split.json
}
snap() { { cat "$S"/features/crm-export/split.json; find .forge "$S/phases" ! -name 'forge.lock*' | sort; } | md5sum; }
refused() {
  local why=$1 before
  shift
  before=$(snap)
  [ "$(code "$forge" alloc crm/export)" = 1 ] || fail "alloc must refuse $why: $(cat "$tmp/out")"
  [ "$(snap)" = "$before" ] || fail "alloc refusing $why must leave split.json and phases/ unchanged"
  for x in "$@"; do grep -qF -- "$x" "$tmp/out" || fail "alloc refusing $why must name $x: $(cat "$tmp/out")"; done
}
if want alloc-refusals; then
refuseset "[$(ph export-core nowhere '[]')]"
refused "a repo resolving to nothing" export-core nowhere
refuseset "[$(ph export-core '' '[]'), $(ph export-api api '["export-core"]')]"
refused "a child repo without .forge/" export-api api .forge
refuseset "[$(ph export-core cold '[]')]"
refused "a linked repo without .forge/" export-core cold .forge
refuseset "[$(ph export-ui web '["export-core"]'), $(ph export-core atlas '["export-form"]'), $(ph export-form web '[]')]"
refused "a cycle between repos" cycle web atlas
refuseset "[$(ph export-core atlas '[]'), $(ph export-mid '' '["export-core"]'), $(ph export-ui web '["export-mid"]')]"
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a split across repos with transitive dependencies must allocate: $(cat "$tmp/out")"
[ -d "$S"/phases/07-export-ui ] || fail "an accepted split is numbered and allocated"
h=$("$forge" alloc --help)
for x in refuse cycle; do grep -qi -- "$x" <<<"$h" || fail "alloc help lists the refusals: missing $x"; done
! grep -qi contract <<<"$h" || fail "alloc help names no contract"
ok alloc-refusals
fi

if want alloc-owner; then
refuseset "[$(ph export-core '' '[]' | jq -c '.requirements = ["EXP-01", "EXP-02"]'), $(ph export-ui web '["export-core"]' | jq -c '.requirements = ["EXP-01"]')]"
rq=$S/features/crm-export/requirements.json
jq -n '{requirements: [{id: "EXP-01", text: "a", done: false, owner: "agent"}, {id: "EXP-02", text: "b", done: false, owner: "operator"}, {id: "EXP-03", text: "c", done: false, owner: "post-ship"}]}' >"$rq"
refused "a phase listing an operator requirement" export-core EXP-02 operator
jq '.requirements[1].owner = "post-ship"' "$rq" >"$tmp/req" && cp "$tmp/req" "$rq"
refused "a phase listing a post-ship requirement" export-core EXP-02 post-ship
jq 'del(.requirements[1].owner)' "$rq" >"$tmp/req" && cp "$tmp/req" "$rq"
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a split listing only agent requirements must allocate, a post-ship one left unmapped: $(cat "$tmp/out")"
[ -d "$S"/phases/06-export-ui ] || fail "the accepted split is numbered and allocated"
h=$("$forge" alloc --help)
for x in owner operator post-ship; do grep -q -- "$x" <<<"$h" || fail "alloc help names the owner refusal: missing $x"; done
ok alloc-owner
fi

depset() { fresh; mkdir -p "$S"/features/crm-export; cp "$fx/alloc-deps/$1.split.json" "$S"/features/crm-export/split.json; }
if want alloc-deps; then
depset missing
refused "a phase consuming an interface another phase creates without depending on it" export-ui export-core lead-api
[ ! -e "$S"/phases/05-export-core ] && [ ! -e "$S"/phases/06-export-ui ] || fail "a refused alloc creates no phase directory"
[ "$(jq -c '[.phases[] | has("number")]' "$S"/features/crm-export/split.json)" = '[false,false]' ] || fail "a refused alloc numbers no phase"
depset trimmed
refused "an interface matching after trimming whitespace, with no dependency" export-ui export-core lead-api
depset direct
jq '.phases += [{slug: "export-api", goal: "Serve leads too", spec: [], requirements: [], depends: [], creates: ["lead-api "]}]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
refused "a consumer depending on only one of two phases creating its interface" export-ui export-api lead-api
depset direct
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a consumer depending directly on the creating phase, with a self-created and an uncreated interface, must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-ui")" ] || fail "an accepted dependency split is numbered and allocated: $(cat "$tmp/out")"
for d in 05-export-core 06-export-ui; do
  [ "$(jq -c '[has("creates"), has("consumes")]' "$S"/phases/$d/spec.json)" = '[false,false]' ] || fail "alloc copies neither creates nor consumes into $d/spec.json: $(json "$S"/phases/$d/spec.json)"
done
"$forge" validate || fail "specs allocated from a split with creates and consumes must validate: $("$forge" validate 2>&1)"
[ -z "$("$forge" alloc crm/export)" ] || fail "a rerun of a split with creates and consumes changes nothing"
depset transitive
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a consumer depending transitively on the creating phase must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-mid\n$S/phases/07-export-ui")" ] || fail "an accepted transitive split is numbered and allocated: $(cat "$tmp/out")"
depset trimmed
jq '(.phases[] | select(.slug == "export-ui") | .depends) = ["export-core"]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a whitespace-differing interface with its dependency must allocate: $(cat "$tmp/out")"
h=$("$forge" alloc --help)
for x in creates consumes; do grep -qF -- "$x" <<<"$h" || fail "alloc help lists the creates/consumes refusal: missing $x"; done
ok alloc-deps
fi

if want alloc-overlap; then
later="add one to the later phase's depends"
union() { repo . && echo 'CHANGELOG.md merge=union' >.gitattributes && git add .gitattributes && git commit -q -m attrs; }
depset files-shared
repo .
refused "two parallel phases planning one file" "phase export-core and phase export-ui both plan src/export.ts with no dependency path; $later"
[ ! -e "$S"/phases/05-export-core ] && [ ! -e "$S"/phases/06-export-ui ] || fail "a refused file overlap creates no phase directory"
[ "$(jq -c '[.phases[] | has("number")]' "$S"/features/crm-export/split.json)" = '[false,false]' ] || fail "a refused file overlap numbers no phase"
jq '(.phases[] | select(.slug == "export-ui") | .depends) = ["export-core"]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "phases sharing a file with a dependency path must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-ui")" ] || fail "an accepted file-sharing split is numbered and allocated: $(cat "$tmp/out")"
depset files-shared
repo .
jq '.phases = [.phases[1], .phases[0]]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
refused "two parallel phases planning one file, named in split order" "phase export-ui and phase export-core both plan src/export.ts with no dependency path; $later"
depset files-union
union
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "parallel phases sharing only a merge=union file must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-ui")" ] || fail "an accepted union-sharing split is numbered and allocated: $(cat "$tmp/out")"
depset files-union
union
jq '.phases[].spec += ["Files: src/export.ts"]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
refused "parallel phases sharing a union file and a normal one" "phase export-core and phase export-ui both plan src/export.ts with no dependency path; $later"
! grep -qF CHANGELOG.md "$tmp/out" || fail "the union file is exempt from the overlap refusal: $(cat "$tmp/out")"
depset files-union
repo .
refused "parallel phases sharing a file with no merge attribute" "phase export-core and phase export-ui both plan CHANGELOG.md with no dependency path; $later"
depset creates-shared
refused "two parallel phases creating one interface" "phase export-core and phase export-ui both create lead-api with no dependency path"
[ ! -e "$S"/phases/05-export-core ] && [ ! -e "$S"/phases/06-export-ui ] || fail "a refused creates overlap creates no phase directory"
jq '(.phases[] | select(.slug == "export-ui") | .depends) = ["export-core"]' "$S"/features/crm-export/split.json >"$tmp/split" && mv "$tmp/split" "$S"/features/crm-export/split.json
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "phases creating one interface with a dependency path must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-ui")" ] || fail "an accepted creates-sharing split is numbered and allocated: $(cat "$tmp/out")"
refuseset "[$(ph export-form web '[]' | jq -c '.spec = ["Files: src/app.ts, src/form.ts"]'), $(ph export-ui web '[]' | jq -c '.spec = ["Files: web:src/app.ts"]')]"
repo .
refused "two parallel phases planning one file in a child repo" "phase export-form and phase export-ui both plan web:src/app.ts with no dependency path; $later"
refuseset "[$(ph export-core '' '[]' | jq -c '.spec = ["Files: src/app.ts"]'), $(ph export-ui web '[]' | jq -c '.spec = ["Files: src/app.ts"]')]"
repo .
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "one path planned in two different repos is no overlap: $(cat "$tmp/out")"
h=$("$forge" alloc --help)
for x in Files: union; do grep -qF -- "$x" <<<"$h" || fail "alloc help describes the overlap refusals and the union exemption: missing $x"; done
ok alloc-overlap
fi

if want alloc-build; then
refuseset "[$(ph export-core '' '[]'), $(ph export-docs '' '["export-core"]')]"
echo '{"spec": ["Export as JSON."], "decisions": [], "build": true}' >"$S"/features/crm-export/spec.json
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "a build feature with no procedure phase must allocate: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$(printf "$S/phases/05-export-core\n$S/phases/06-export-docs")" ] || fail "a build split is numbered and allocated: $(cat "$tmp/out")"
want=$(jq -cS . <<<'{"track": "crm", "feature": "export", "number": "06", "slug": "export-docs", "goal": "export-docs", "spec": [], "requirements": [], "depends": ["05"]}')
[ "$(json "$S"/phases/06-export-docs/spec.json)" = "$want" ] || fail "a build feature phase spec carries no procedure: $(json "$S"/phases/06-export-docs/spec.json)"
"$forge" validate || fail "an allocated build feature must validate: $("$forge" validate 2>&1)"
! "$forge" alloc --help | grep -qF procedure || fail "alloc help names no procedure"
ok alloc-build
fi

if want alloc-reference; then
refuseset "[$(ph export-core atlas '[]'), $(ph export-form web '[]'), $(ph export-docs '' '[]'), $(ph export-ui web '["export-docs", "export-form", "export-core"]' | jq -c '.spec = ["Show the export."]'), $(ph export-tail web '["export-ui"]')]"
"$forge" alloc crm/export >"$tmp/out" 2>&1 || fail "alloc of a split with cross-repo dependencies: $(cat "$tmp/out")"
pr=$PWD br=$(cd "$tmp/atlas" && pwd)
want=$(jq -cS . <<<"{\"track\": \"crm\", \"feature\": \"export\", \"number\": \"08\", \"slug\": \"export-ui\", \"repo\": \"web\", \"goal\": \"export-ui\", \"spec\": [\"Reference (read-only): atlas feature worktree $br/.claude/worktrees/crm-export\", \"Reference (read-only): p feature worktree $pr/.claude/worktrees/crm-export\", \"Show the export.\"], \"requirements\": [], \"depends\": [\"07\", \"06\", \"05\"]}")
[ "$(json "$S"/phases/08-export-ui/spec.json)" = "$want" ] || fail "a consumer phase's spec starts with one reference line per producer repo it depends on directly, in producer order: $(json "$S"/phases/08-export-ui/spec.json)"
for d in 05-export-core 06-export-form 07-export-docs 09-export-tail; do
  [ "$(jq -c .spec "$S"/phases/$d/spec.json)" = '[]' ] || fail "$d depends directly on no other repo, so gets no reference line: $(json "$S"/phases/$d/spec.json)"
done
"$forge" validate || fail "allocated specs with reference lines must validate: $("$forge" validate 2>&1)"
"$forge" validate "$S"/phases/0[5-9]-*/spec.json || fail "allocated specs must validate named"
[ -z "$("$forge" alloc crm/export)" ] || fail "a rerun after reference lines changes nothing"
s="$S"/features/crm-export/split.json ps="$S"/phases/08-export-ui/spec.json
jq '(.phases[] | select(.slug == "export-ui") | .spec) += ["Gap: Dates are not ISO"]' $s >"$tmp/split" && mv "$tmp/split" $s
jq '.spec += ["Gap: Dates are not ISO"]' $ps >"$tmp/spec" && mv "$tmp/spec" $ps
[ -z "$("$forge" alloc crm/export)" ] || fail "a rerun after the same Gap: line is appended to spec.json and split.json reports no replan"
[ "$(jq -r '.spec[-1]' $ps)" = "Gap: Dates are not ISO" ] || fail "the appended Gap: line stays"
"$forge" alloc --help | grep -qF "Reference (read-only)" || fail "alloc help describes the reference line"
ok alloc-reference
fi
finish
