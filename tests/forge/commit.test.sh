#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

S=$XDG_STATE_HOME/forge/p
edit() { jq "$1" "$2" >"$tmp/edit" && mv "$tmp/edit" "$2"; }
committed() { [ "$(git show --name-only --format= HEAD)" = "$(printf '%s\n' "$@")" ] || fail "commit files: $(git show --name-only --format= HEAD)"; }
modified() { local p; for p; do [ "$(git status --porcelain -- "$p")" = " M $p" ] || fail "$p must stay modified: $(git status --porcelain)"; done; }
staged() { [ "$(git diff --cached --name-only)" = other.txt ] || fail "other.txt must stay the only staged file: $(git diff --cached --name-only)"; }
init() { git init -q -b main && git config user.name forge && git config user.email forge@example.com && git add -A && git commit -q -m init; }
recorded() {
  local scope=$1 step=$2 head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit "$scope" "$step")" = 0 ] || fail "forge commit $scope $step with no in-repo change must exit 0: $(cat "$tmp/out")"
  grep -qxF "forge: recorded $scope $step" "$tmp/out" || fail "forge commit $scope $step with no in-repo change prints forge: recorded $scope $step: $(cat "$tmp/out")"
  ! grep -q "^forge: committed" "$tmp/out" || fail "forge commit $scope $step commits nothing: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "forge commit $scope $step with only state dir changes leaves HEAD unchanged: $(git log -1 --format=%s)"
}
archived() {
  edit '(.requirements[] | select(.id == "INT-02")).owed = {"kind": "deferred", "check": "The API returns the lead.", "owner": "crm/routing"}' "$S/features/crm-intake/requirements.json"
  echo '{"final_review": ["No findings"], "pr": "https://example.com/pr/1", "date": "2026-09-25"}' >"$S/features/crm-intake/ship.json"
  mv "$S/features/crm-intake" "$S/archive/crm-intake"
  mkdir "$S/archive/crm-intake/phases"
  mv "$S/phases/02-intake-form" "$S/phases/03-intake-api" "$S/archive/crm-intake/phases/"
  edit '.features |= map(select(.feature != "intake")) | .shipped += [{feature: "intake", phases: ["02", "03"], date: "2026-09-25"}]' .forge/tracks/crm.json
}

if want commit; then
fresh
init
echo staged >other.txt && git add other.txt
jq '.goal = "New goal"' .forge/tracks/crm.json >"$tmp/crm" && mv "$tmp/crm" .forge/tracks/crm.json
"$forge" commit crm "track goal" >/dev/null
[ "$(git log -1 --format=%s)" = "forge(crm): track goal" ] || fail "commit message"
[ -z "$(git status --porcelain -- .forge)" ] || fail "planning paths must be clean: $(git status --porcelain)"
[ ! -e .forge/tracks/crm.md ] && [ ! -e .forge/STATE.md ] || fail "commit must not render Markdown: $(ls .forge .forge/tracks)"
committed .forge/tracks/crm.json
[ "$(git diff --cached --name-only)" = other.txt ] || fail "other staged files must stay staged"
[ "$("$forge" commit crm again)" = "forge: recorded crm again" ] || fail "a scope with no in-repo change prints the recorded line: $("$forge" commit crm again 2>&1)"
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit crm a b)" = 2 ] || fail "commit takes exactly two arguments"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "extra commit arguments moved HEAD"
jq '.status = "maybe"' .forge/tracks/crm.json >"$tmp/crm" && mv "$tmp/crm" .forge/tracks/crm.json
[ "$(code "$forge" commit crm bad)" = 1 ] || fail "invalid JSON must block the commit"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved"
git checkout -q -- .forge/tracks/crm.json
mkdir -p "$tmp/empty" && git init -q -b main "$tmp/empty" && mkdir -p "$tmp/empty/.forge/archive" "$tmp/empty/.forge/tracks" "$XDG_STATE_HOME/forge/empty/archive"
cp .forge/tracks/crm.json "$tmp/empty/.forge/tracks/"
git -C "$tmp/empty" config user.name forge && git -C "$tmp/empty" config user.email forge@example.com
FORGE_ROOT=$tmp/empty "$forge" commit crm seed >/dev/null || fail "an empty archive dir in the repo or the state dir must not break commit"
[ "$(git -C "$tmp/empty" log -1 --format=%s)" = "forge(crm): seed" ] || fail "commit with an empty archive dir"
git checkout -q -b side
[ "$(code "$forge" commit crm side)" = 1 ] || fail "commit off main must fail"
git checkout -q main
[ -e "$(git rev-parse --git-common-dir)/forge.lock" ] || fail "lock file in the git dir"
ok commit
fi

if want commit-scope; then
fresh
jq -n '{track: "crm-x", goal: "Extra line", status: "open", notes: [], features: [{feature: "foo", delivers: "Foo", depends: []}], shipped: []}' >.forge/tracks/crm-x.json
mkdir -p "$S/features/crm-x-foo"
jq -n '{requirements: [{id: "FOO-01", text: "Foo works.", done: false}]}' >"$S/features/crm-x-foo/requirements.json"
init
echo staged >other.txt && git add other.txt
edit '.goal = "Crm goal"' .forge/tracks/crm.json
edit '.goal = "Voice goal"' .forge/tracks/voice.json
edit '.requirements[0].text = "Foo changed."' "$S/features/crm-x-foo/requirements.json"
"$forge" commit crm "track goal" >/dev/null
[ "$(git log -1 --format=%s)" = "forge(crm): track goal" ] || fail "track scope subject: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
modified .forge/tracks/voice.json
staged
[ "$(jq -r '.requirements[0].text' "$S/features/crm-x-foo/requirements.json")" = "Foo changed." ] || fail "a commit leaves another scope's state dir file as written"
[ -z "$(git ls-tree -r --name-only HEAD -- .forge/features .forge/phases .forge/archive)" ] || fail "no state dir record reaches HEAD: $(git ls-tree -r --name-only HEAD -- .forge)"
edit '.spec += ["Scoped."]' "$S/phases/03-intake-api/spec.json"
edit '.phases[0].spec += ["Scoped."]' "$S/features/crm-routing/split.json"
recorded crm/intake "api spec"
jq -e '.spec[-1] == "Scoped."' "$S/phases/03-intake-api/spec.json" >/dev/null || fail "the feature scope leaves its state dir files in place"
modified .forge/tracks/voice.json
staged
edit '.spec += ["Scoped."]' "$S/phases/02-intake-form/spec.json"
edit '.phases[0].spec += ["Scoped."]' "$S/features/crm-intake/split.json"
edit '.spec += ["Again."]' "$S/phases/03-intake-api/spec.json"
recorded 02 contracts
jq -e '.spec[-1] == "Scoped."' "$S/phases/02-intake-form/spec.json" >/dev/null && jq -e '.phases[0].spec[-1] == "Scoped."' "$S/features/crm-intake/split.json" >/dev/null || fail "the phase scope leaves its state dir files in place"
staged
edit '.spec += ["Scoped."]' "$S/archive/crm-auth/phases/01-auth-login/spec.json"
recorded 01 archived
staged
edit '.goal = "Crm both"' .forge/tracks/crm.json
edit '.spec += ["Both."]' "$S/phases/03-intake-api/spec.json"
[ "$(code "$forge" commit crm/intake both)" = 0 ] || fail "a feature scope with an in-repo change commits: $(cat "$tmp/out")"
grep -qE '^forge: committed [0-9a-f]{7,} \(1 files?\) forge\(crm/intake\): both$' "$tmp/out" || fail "the feature commit names one file: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm/intake): both" ] || fail "feature scope subject: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
jq -e '.spec[-1] == "Both."' "$S/phases/03-intake-api/spec.json" >/dev/null || fail "the feature commit leaves the state dir file in place"
staged
head=$(git rev-parse HEAD)
for scope in 99 nope crm/nope; do
  [ "$(code "$forge" commit "$scope" x)" = 1 ] || fail "unresolvable scope $scope must exit 1: $(cat "$tmp/out")"
  grep -q "^forge: .*$scope" "$tmp/out" || fail "error must name $scope: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on scope $scope"
  staged
done
ok commit-scope
fi

if want commit-resolve; then
fresh
jq -n '{track: "hardening", goal: "Harden forge", status: "open", notes: [], features: [{feature: "commit-scope", delivers: "Scoped commits", depends: []}], shipped: []}' >.forge/tracks/hardening.json
mkdir -p "$S/features/hardening-commit-scope"
jq -n '{requirements: [{id: "CMT-01", text: "Commits are scoped.", done: false}]}' >"$S/features/hardening-commit-scope/requirements.json"
init
echo staged >other.txt && git add other.txt
req=$S/features/hardening-commit-scope/requirements.json
edit '.requirements[0].text = "Commits are scoped by slug."' "$req"
edit '.phases[0].spec += ["Scoped."]' "$S/features/crm-routing/split.json"
recorded hardening-commit-scope x
staged
edit '.requirements[0].text = "Commits are scoped by bare slug."' "$req"
recorded commit-scope y
staged
printf '{"requirements": [' >"$req"
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit commit-scope z)" = 1 ] || fail "an unparsable state dir file of a bare slug scope must be refused: $(cat "$tmp/out")"
grep -qF "$req" "$tmp/out" || fail "the refusal names the state dir file by its absolute path: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on a refused bare slug scope"
jq -n '{requirements: [{id: "CMT-01", text: "Commits are scoped.", done: false}]}' >"$req"
refused() {
  local scope=$1 head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit "$scope" x)" = 1 ] || fail "scope $scope must exit 1: $(cat "$tmp/out")"
  grep "^forge: .*$scope" "$tmp/out" >"$tmp/err" || fail "error must name $scope: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on scope $scope"
  staged
}
refused scope
mkdir -p "$S/features/voice-intake"
jq -n '{requirements: [{id: "VINT-01", text: "Voice intake.", done: false}]}' >"$S/features/voice-intake/requirements.json"
refused intake
grep -q "crm/intake" "$tmp/err" && grep -q "voice/intake" "$tmp/err" || fail "ambiguous slug must name crm/intake and voice/intake: $(cat "$tmp/out")"
mkdir -p "$S/features/crm-voice"
jq -n '{requirements: [{id: "CVOX-01", text: "Crm voice.", done: false}]}' >"$S/features/crm-voice/requirements.json"
refused voice
grep -q "track" "$tmp/err" && grep -q "feature" "$tmp/err" || fail "voice must be refused as both a track and a feature: $(cat "$tmp/out")"
jq -n '{track: "crm-x", goal: "Extra line", status: "open", notes: [], features: [{feature: "foo", delivers: "Foo", depends: []}], shipped: []}' >.forge/tracks/crm-x.json
mkdir -p "$S/features/crm-x-foo"
jq -n '{requirements: [{id: "FOO-01", text: "Foo works.", done: false}]}' >"$S/features/crm-x-foo/requirements.json"
refused crm-x-foo
grep -q "crm/x-foo" "$tmp/err" && grep -q "crm-x/foo" "$tmp/err" || fail "ambiguous prefix must name crm/x-foo and crm-x/foo: $(cat "$tmp/out")"
rm -rf "$S/features/crm-x-foo"
mkdir -p "$S/archive/crm-x-foo"
jq -n '{requirements: [{id: "FOO-01", text: "Foo works.", done: true}]}' >"$S/archive/crm-x-foo/requirements.json"
refused crm-x-foo
grep -q "crm/x-foo" "$tmp/err" && grep -q "crm-x/foo" "$tmp/err" || fail "an archived state dir feature counts toward the ambiguous prefix: $(cat "$tmp/out")"
ok commit-resolve
fi

if want commit-archive; then
fresh
init
names() { git show --name-status --no-renames --format= HEAD | sort; }
archived
edit '.phases[0].spec += ["Scoped."]' "$S/features/crm-routing/split.json"
[ "$(code "$forge" commit crm/intake archive)" = 0 ] || fail "archived feature scope must commit: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm/intake): archive" ] || fail "archived feature scope subject: $(git log -1 --format=%s)"
printf 'M\t.forge/tracks/crm.json\n' | diff -u - <(names) || fail "the archive commit carries only the track change"
[ -z "$(git ls-tree -r --name-only HEAD -- .forge/features .forge/phases .forge/archive)" ] || fail "the archive commit puts no record in the repo: $(git ls-tree -r --name-only HEAD -- .forge)"
[ -f "$S/archive/crm-intake/phases/02-intake-form/spec.json" ] && [ -f "$S/archive/crm-intake/ship.json" ] || fail "the archived records stay in the state dir: $(find "$S/archive" -type f)"
[ ! -e .forge/STATE.md ] || fail "archive commit must not render STATE.md"
[ -z "$(git status --porcelain --untracked-files=all -- .forge)" ] || fail "archived scope paths must be clean: $(git status --porcelain)"
jq -e '.phases[0].spec[-1] == "Scoped."' "$S/features/crm-routing/split.json" >/dev/null || fail "another feature's state dir file stays as written"
edit '.spec += ["Archived."]' "$S/archive/crm-intake/phases/03-intake-api/spec.json"
recorded 03 archived
jq -e '.spec[-1] == "Archived."' "$S/archive/crm-intake/phases/03-intake-api/spec.json" >/dev/null || fail "an archived phase scope keeps its state dir edit"
fresh
init
rm -rf "$S/phases/03-intake-api"
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit 03 drop)" = 1 ] || fail "a phase gone from the state dir resolves to nothing: $(cat "$tmp/out")"
grep -q "^forge: .*03" "$tmp/out" || fail "the error names scope 03: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a removed phase commits nothing"
mkdir "$S/phases/05-scratch" && echo scratch >"$S/phases/05-scratch/notes.md"
[ "$(echo garbage | code "$forge" commit 05 scratch)" = 0 ] || fail "spec-less phase scope must not read stdin: $(cat "$tmp/out")"
grep -qxF "forge: recorded 05 scratch" "$tmp/out" || fail "a spec-less phase scope prints the recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a spec-less phase scope commits nothing"
ok commit-archive
fi

if want archive-push; then
fresh
init
rm -rf "$tmp/origin.git" && git init -q --bare -b main "$tmp/origin.git"
git remote add origin "$tmp/origin.git" && git push -q origin main && git config forge.pushMain true
origin() { git --git-dir="$tmp/origin.git" rev-parse main; }
edit '(.requirements[] | select(.id == "INT-02")).owed = {"kind": "deferred", "check": "The API returns the lead.", "owner": "crm/routing"}' "$S/features/crm-intake/requirements.json"
echo '{"final_review": ["No findings"], "pr": null, "date": "2026-09-25"}' >"$S/features/crm-intake/ship.json"
recorded crm/intake ship
edit '.goal = "Shipped goal"' .forge/tracks/voice.json
"$forge" commit voice goal >/dev/null
[ "$(origin)" != "$(git rev-parse main)" ] || fail "a track commit does not push main"
archived
[ "$(code "$forge" commit crm/intake archive)" = 0 ] || fail "archive commit with pushMain must exit 0: $(cat "$tmp/out")"
[ "$(origin)" = "$(git rev-parse main)" ] || fail "the archive commit pushes main, the earlier commit included, to origin"
[ "$(tail -n1 "$tmp/out")" = "forge: pushed $(git rev-parse --short main) to origin" ] || fail "the archive commit prints the pushed line: $(cat "$tmp/out")"
edit '.goal = "Pushed goal"' .forge/tracks/crm.json
"$forge" commit crm goal >/dev/null
[ "$(code "$forge" commit crm/intake archive)" = 0 ] && grep -qxF "forge: recorded crm/intake archive" "$tmp/out" || fail "a rerun archive commit with no in-repo change prints the recorded line: $(cat "$tmp/out")"
[ "$(origin)" = "$(git rev-parse main)" ] || fail "a recorded archive step still pushes main"
git remote set-url origin "$tmp/nowhere.git"
edit '.goal = "Unpushed goal"' .forge/tracks/crm.json
"$forge" commit crm goal >/dev/null
[ "$(code "$forge" commit crm/intake archive)" = 0 ] || fail "a failed push only warns: $(cat "$tmp/out")"
grep -qF "forge: warning: pushing main to origin failed in $PWD" "$tmp/out" || fail "a failed push warns: $(cat "$tmp/out")"
ok archive-push
fi

if want commit-verify; then
fresh
rm -rf "$tmp/lumen" && git init -q -b main "$tmp/lumen"
echo '{"repos": ["../lumen"]}' >.forge/repos.json
edit '.phases[1].repo = "lumen"' "$S/features/crm-intake/split.json"
init
[ "$("$forge" repos crm/intake | cut -d' ' -f1 | paste -sd' ')" = "p lumen" ] || fail "the verify fixture spans repos p and lumen: $("$forge" repos crm/intake)"
v=$S/features/crm-intake/verify.json
tree=$(git rev-parse 'HEAD^{tree}')
init_head=$(git rev-parse HEAD)
unreviewed() {
  local why=$1 head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit crm/intake verify)" = 1 ] || fail "a pass verify.json with $why must be refused: $(cat "$tmp/out")"
  grep -q "^forge: .*lumen" "$tmp/out" || fail "the refusal of a pass verify.json with $why must name the unreviewed repo lumen: $(cat "$tmp/out")"
  grep -qF "forge-reviewer" "$tmp/out" && grep -q "final review" "$tmp/out" || fail "the refusal of a pass verify.json with $why must say to run the final review or its forge-reviewer fallback: $(cat "$tmp/out")"
  ! grep -q "^forge: recorded" "$tmp/out" || fail "a refused pass verify.json with $why is not recorded: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on a pass verify.json with $why"
}
mismatch() {
  local line=$1 head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit crm/intake verify)" = 1 ] || fail "a verify.json with $line must be refused: $(cat "$tmp/out")"
  grep -qF "$v: $line" "$tmp/out" || fail "stderr must name the state dir verify.json and the mismatch $line: $(cat "$tmp/out")"
  grep -qF "forge: planning JSON of scope crm/intake fails its schema; nothing committed" "$tmp/out" || fail "a mismatched verify.json commits nothing: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on a verify.json with $line"
}
jq -n '{manual_test: ["Open the intake form."], result: "pass", gaps: [{phase: "02", gap: "Form misses a field."}]}' >"$v"
mismatch "result pass with 1 gaps"
jq -n '{manual_test: ["Open the intake form."], result: "gaps", gaps: []}' >"$v"
mismatch "result gaps with no gaps"
jq -n '{manual_test: ["Open the intake form."], result: "pass", gaps: []}' >"$v"
unreviewed "no review_trees"
jq -n --arg t "$tree" '{manual_test: ["Open the intake form."], result: "pass", gaps: [], review_trees: {p: $t}}' >"$v"
unreviewed "a review_trees entry for p only"
jq -n --arg t "$tree" '{manual_test: ["Open the intake form."], result: "pass", gaps: [], review_trees: {p: $t, lumen: $t}}' >"$v"
recorded crm/intake verify
[ "$(jq -r '.review_trees | keys | join(" ")' "$v")" = "lumen p" ] || fail "the pass verify.json stays in the state dir with its review_trees: $(cat "$v")"
jq -n '{manual_test: ["Open the intake form."], result: "gaps", gaps: [{phase: "02", gap: "Form misses a field."}]}' >"$v"
recorded crm/intake verify
[ "$(jq -r .result "$v")" = gaps ] || fail "the gaps verify.json stays in the state dir"
jq -n '{manual_test: ["Open the intake form."], result: "pass", gaps: []}' >"$v"
for scope in "crm goal" "crm/intake settle" "02 settle"; do
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit $scope)" = 1 ] || fail "forge commit $scope with an unreviewed pass verify.json in the state dir must be refused: $(cat "$tmp/out")"
  grep -q "^forge: .*verify.json has result pass but no review_trees entry for p lumen" "$tmp/out" || fail "the refusal of forge commit $scope must name the unreviewed repos: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on forge commit $scope with an unreviewed pass verify.json"
done
jq -n --arg t "$tree" '{manual_test: ["Open the intake form."], result: "pass", gaps: [], review_trees: {p: $t, lumen: $t}}' >"$v"
recorded crm verify
[ "$(git rev-parse HEAD)" = "$init_head" ] || fail "no verify step put a commit on main: $(git log --format=%s "$init_head"..HEAD)"
edit '.goal = "Reviewed goal"' .forge/tracks/crm.json
[ "$(code "$forge" commit crm goal)" = 0 ] || fail "a track commit with a reviewed pass verify.json must commit: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm): goal" ] || fail "the track commit lands: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
rm -rf "$tmp/marrow" && git init -q -b main "$tmp/marrow"
echo '{"repos": ["../lumen", "../marrow"]}' >.forge/repos.json
edit '.phases[0].repo = "marrow"' "$S/features/crm-intake/split.json"
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit crm/intake verify)" = 1 ] || fail "a verify commit adding a repo to split.json under an unchanged pass verify.json must be refused: $(cat "$tmp/out")"
grep -q "^forge: .*verify.json has result pass but no review_trees entry for marrow" "$tmp/out" || fail "the refusal must name the new repo marrow: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on a verify commit adding an unreviewed repo"
[ "$(code "$forge" commit 02 split)" = 1 ] || fail "a phase commit adding a repo to split.json under an unchanged pass verify.json must be refused: $(cat "$tmp/out")"
grep -q "^forge: .*verify.json has result pass but no review_trees entry for marrow" "$tmp/out" || fail "the phase commit refusal must name the new repo marrow: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on a phase commit adding an unreviewed repo"
ok commit-verify
fi

if want commit-settled; then
fresh
init
echo staged >other.txt && git add other.txt
s=$S/features/crm-intake/settled.json
jq -n '{items: [{subject: {finding: "src/form.ts: Missing field"}, ruling: "Keep the field optional.", by: "operator", phase: "02", date: "2026-10-14"}]}' >"$s"
recorded 02 settle
[ "$(jq '.items | length' "$s")" = 1 ] || fail "the new settled.json stays in the state dir"
staged
edit '.items += [{subject: {requirement: "INT-01"}, ruling: "Defer to the next phase.", by: "escalator", phase: "02", date: "2026-10-14"}]' "$s"
recorded 02 "settle again"
[ "$(jq '.items | length' "$s")" = 2 ] || fail "the changed settled.json stays in the state dir: $(cat "$s")"
staged
head=$(git rev-parse HEAD)
printf '{"items": [' >"$s"
[ "$(code "$forge" commit 02 bad)" = 1 ] || fail "an unparsable settled.json must be refused: $(cat "$tmp/out")"
grep -qF "$s" "$tmp/out" || fail "stderr must name the state dir settled.json: $(cat "$tmp/out")"
grep -qF "forge: planning JSON of scope 02 fails its schema; nothing committed" "$tmp/out" || fail "an unparsable settled.json commits nothing: $(cat "$tmp/out")"
! grep -q "^forge: recorded" "$tmp/out" || fail "an unparsable settled.json is not recorded: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "HEAD moved on an unparsable settled.json"
staged
ok commit-settled
fi
if want commit-doc; then
fresh
echo "# Stack" >.forge/STACK.md
git init -q -b main
git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
echo staged >other.txt && git add other.txt
edit '.goal = "Doc goal"' .forge/tracks/crm.json
big() { head -c 8193 /dev/zero | tr '\0' x >.forge/STACK.md; }
big
[ "$(code "$forge" commit crm goal)" = 0 ] || fail "a changed oversized linked doc must only warn: $(cat "$tmp/out")"
grep -qxF "forge: warning: .forge/STACK.md:1: over 8 KB (8193 bytes)" "$tmp/out" || fail "the warning must name the doc line: $(cat "$tmp/out")"
! grep -qF "nothing committed" "$tmp/out" || fail "a lint warning must not refuse the commit: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm): goal" ] || fail "a changed oversized linked doc must not block the commit: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
[ "$(git status --porcelain -- .forge/STACK.md)" = " M .forge/STACK.md" ] || fail "the linked doc stays uncommitted: $(git status --porcelain)"
staged
edit '.goal = "Staged goal"' .forge/tracks/crm.json
git add .forge/STACK.md && git show HEAD:.forge/STACK.md >.forge/STACK.md
[ "$(code "$forge" commit crm staged)" = 0 ] || fail "a staged oversized linked doc must only warn: $(cat "$tmp/out")"
grep -qxF "forge: warning: .forge/STACK.md:1: over 8 KB (8193 bytes)" "$tmp/out" || fail "the staged warning must name the doc line: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm): staged" ] || fail "a staged oversized linked doc must not block the commit: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
[ "$(git diff --cached --name-only)" = "$(printf '.forge/STACK.md\nother.txt')" ] || fail "the staged doc and other.txt stay staged: $(git diff --cached --name-only)"
edit '.goal = "Doc goal"' .forge/tracks/crm.json
git reset -q -- .forge/STACK.md
big
git commit -q -m big -- .forge/STACK.md
[ "$(code "$forge" commit crm goal)" = 0 ] || fail "an unchanged oversized linked doc must not block the commit: $(cat "$tmp/out")"
! grep -qF "STACK.md" "$tmp/out" || fail "an unchanged linked doc is never checked: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "forge(crm): goal" ] || fail "doc scope subject: $(git log -1 --format=%s)"
committed .forge/tracks/crm.json
staged
ok commit-doc
fi

if want commit-help; then
for c in commit check; do
  "$forge" "$c" --help >"$tmp/help"
  ! grep -nE '\.forge/(phases|features|archive)' "$tmp/help" || fail "forge $c --help names no in-repo phase, feature or archive path"
  grep -qE 'STATE/(phases|features|archive)' "$tmp/help" || fail "forge $c --help names the state dir records as STATE/...: $(cat "$tmp/help")"
done
"$forge" commit --help | tr -s ' \n' '  ' >"$tmp/help"
grep -qF 'forge: recorded <scope> <step>' "$tmp/help" || fail "forge commit --help documents the recorded line: $(cat "$tmp/help")"
grep -qi sha256 "$tmp/help" || fail "forge commit --help documents the plan sha256 the plan gate compares: $(cat "$tmp/help")"
"$forge" check --help | grep -qi sha256 || fail "forge check --help documents the plan sha256 in each check event"
ok commit-help
fi
finish
