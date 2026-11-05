#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

if want merge-check; then
rm -rf "$tmp/mc" && mkdir -p "$tmp/mc/.forge" && cd "$tmp/mc"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo a >shared.txt
seq 20 >old.txt
echo state >.forge/NOTES.md
git add -A && git commit -q -m base
git branch theirs
printf '%s\n' ours-line '' '  indented' >>shared.txt
git mv old.txt new.txt && echo renamed-line >>new.txt
printf '%s\n' note moved >"ours notes.txt"
echo ours-state >>.forge/NOTES.md
git add -A && git commit -q -m ours
git checkout -q theirs
printf '%s\n' theirs-line theirs-drop >>shared.txt
echo theirs-state >>.forge/NOTES.md
git commit -q -am theirs
git checkout -q main
! git merge -q --no-commit theirs >/dev/null 2>&1 || fail "the merge-check scenario must conflict"
mc() {
  local want=$1 exp=$2
  shift 2
  [ "$(code "$forge" merge-check "$@")" = "$want" ] || fail "merge-check $* must exit $want: $(cat "$tmp/out")"
  [ "$(cat "$tmp/out")" = "$exp" ] || fail "merge-check $* output: $(cat "$tmp/out")"
}
mcdie() {
  [ "$(code "$forge" merge-check "$@")" = 1 ] || fail "merge-check $* must exit 1: $(cat "$tmp/out")"
  [ "$(wc -l <"$tmp/out")" = 1 ] && grep -q '^forge: ' "$tmp/out" || fail "merge-check $* prints only a forge: line: $(cat "$tmp/out")"
}
mc 1 "$(printf '%s\n' 'ours .forge/NOTES.md: ours-state' 'ours shared.txt: ours-line' 'ours shared.txt: indented' 'theirs .forge/NOTES.md: theirs-state' 'theirs shared.txt: theirs-line' 'theirs shared.txt: theirs-drop')"
printf '%s\n' a ours-line '    indented' theirs-line moved >shared.txt
printf '%s\n' state ours-state theirs-state >.forge/NOTES.md
echo note >"ours notes.txt"
seq 20 >new.txt
git add shared.txt .forge/NOTES.md "ours notes.txt" new.txt
lost=$(printf '%s\n' 'ours new.txt: renamed-line' 'ours ours notes.txt: moved' 'theirs shared.txt: theirs-drop')
mc 1 "$lost"
mkdir -p merge sub
full='{files: [{path: "new.txt", resolution: "kept the base file", dropped: [{side: "ours", line: "renamed-line", reason: "r"}]}, {path: "ours notes.txt", resolution: "moved a line out", dropped: [{side: "ours", line: "moved", reason: "r"}]}, {path: "shared.txt", resolution: "kept both sides", dropped: [{side: "theirs", line: " theirs-drop ", reason: "r"}]}]}'
jq -n "$full" >merge/M1.json
cd sub
FORGE_ROOT=$tmp/nowhere mc 1 "$lost"
FORGE_ROOT=$tmp/nowhere mc 0 "$lost" ../merge/M1.json
cd ..
mc 0 "$lost" merge/M1.json
jq -n "$full | del(.files[1].dropped[0])" >merge/M2.json
mc 1 "$lost" merge/M2.json
jq -n "$full | .files[2].dropped[0].side = \"ours\"" >merge/M3.json
mc 1 "$lost" merge/M3.json
jq -n "$full | .files[2].path = \"other.txt\"" >merge/M4.json
mc 1 "$lost" merge/M4.json
mcdie merge/none.json
echo '{"files": [' >merge/bad.json
mcdie merge/bad.json
[ "$(code "$forge" merge-check merge/M1.json merge/M2.json)" = 2 ] || fail "merge-check with two arguments must exit 2: $(cat "$tmp/out")"
git merge --abort
mcdie

rm -rf "$tmp/mcs" && mkdir -p "$tmp/mcs/subrepo" && cd "$tmp/mcs/subrepo"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo a >f.txt && git add -A && git commit -q -m c1
mkdir -p "$tmp/mcs/main" && cd "$tmp/mcs/main"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git -c protocol.file.allow=always submodule add -q ../subrepo sub
echo x >shared.txt
git add -A && git commit -q -m base
git branch theirs
(cd ../subrepo && echo b >f.txt && git add -A && git commit -q -m c2)
git -c protocol.file.allow=always -C sub fetch -q origin
git -C sub checkout -q origin/main
git add sub
git commit -q -m "bump submodule ours"
git checkout -q theirs
echo y >>shared.txt
git commit -q -am "theirs unrelated"
git checkout -q main
git merge -q --no-commit theirs >/dev/null 2>&1
mc 0 ""
git merge --abort
cd "$tmp/mc"
ok merge-check
fi

if want merge-check-quoted-path; then
rm -rf "$tmp/mcq" && mkdir -p "$tmp/mcq" && cd "$tmp/mcq"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
printf 'x\n' >'a"b\c.txt'
git add -A && git commit -q -m base
git branch theirs
printf 'x\nours-line\n' >'a"b\c.txt'
git commit -q -am ours
git checkout -q theirs
printf 'x\ntheirs-line\n' >'a"b\c.txt'
git commit -q -am theirs
git checkout -q main
! git merge -q --no-commit theirs >/dev/null 2>&1 || fail "the quoted-path merge-check scenario must conflict"
printf 'x\ntheirs-line\n' >'a"b\c.txt'
git add -A
[ "$(code "$forge" merge-check)" = 1 ] || fail "merge-check must catch a dropped line in a quoted diff-header path: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = 'ours a"b\c.txt: ours-line' ] || fail "merge-check must unquote the diff-header path: $(cat "$tmp/out")"
mkdir merge
jq -n '{files: [{path: "a\"b\\c.txt", resolution: "kept theirs", dropped: [{side: "ours", line: "ours-line", reason: "r"}]}]}' >merge/M1.json
[ "$(code "$forge" merge-check merge/M1.json)" = 0 ] || fail "merge-check must accept a resolution record naming the quoted path: $(cat "$tmp/out")"
git merge --abort
ok merge-check-quoted-path
fi

mg() { local s=0; "$forge" merge "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
quiet() { [ ! -s "$tmp/out" ] && [ ! -s "$tmp/err" ] || fail "merge $* must print nothing: $(cat "$tmp/out" "$tmp/err")"; }
nomerge() { ! git rev-parse -q --verify MERGE_HEAD >/dev/null || fail "$1 must leave no merge in progress"; }
trk=.forge/tracks/crm.json req=.forge/features/crm-intake/requirements.json
jed() { local f=$1; shift; jq "$@" "$f" >"$tmp/jed" && mv "$tmp/jed" "$f"; }
side() { git checkout -q -b "$1" main; }
done_side() { git add -A && git commit -q -m "$1"; }
stages() { git ls-files -u -- "$1" | awk '{print $3}' | paste -sd' '; }
markers() { grep -qE '^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)' "$1"; }
feat='{feature: $n, delivers: ($n | ascii_upcase), depends: []}'
rq='{id: $n, text: ("Req " + $n + "."), done: false}'
rside() { local b=$1; side "$b"; shift; jed "$@"; done_side "$b"; }
reqrepo() { fresh; mkdir -p "${req%/*}" && cp "$fx/state/features/crm-intake/requirements.json" $req; }
arch=.forge/ARCHITECTURE.md
dside() { git checkout -q -b "$1" main; sed -i "s/^- a\$/- a\n- $2/" $arch; [ -z "${3:-}" ] || sed -i "s/^- x\$/- $3/" $arch; git commit -q -am "$1"; }
listedrepo() {
reqrepo
git init -q -b main
git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
rside listed-ours $req '(.requirements[] | select(.id == "INT-02") | .text) = "A"'
rside listed-theirs $req '(.requirements[] | select(.id == "INT-02") | .text) = "B"'
git checkout -q listed-ours
}
docrepo() {
rm -rf "$tmp/md" && mkdir -p "$tmp/md/.forge" && cd "$tmp/md"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
printf '%s\n' '# Architecture' '' '## Components' '- a' '' '## Boundaries' '- x' >$arch
git add -A && git commit -q -m base
dside ch-ours ours-bullet x1
dside ch-theirs theirs-bullet x2
git checkout -q ch-ours
}

if want merge; then
rm -rf "$tmp/mg" && mkdir -p "$tmp/mg" && cd "$tmp/mg"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
echo a >shared.txt
git add -A && git commit -q -m base
git checkout -q -b theirs
echo t >theirs.txt && git add -A && git commit -q -m theirs
git checkout -q main
echo o >ours.txt && git add -A && git commit -q -m ours
mkdir sub && cd sub
[ "$(FORGE_ROOT=$tmp/nowhere mg theirs)" = 0 ] || fail "merge theirs must exit 0: $(cat "$tmp/out" "$tmp/err")"
quiet theirs
[ "$(git log -1 --format=%s)" = "Merge branch 'theirs' into main" ] || fail "merge commit subject: $(git log -1 --format=%s)"
[ "$(git rev-parse HEAD^2)" = "$(git rev-parse theirs)" ] || fail "the merge commit's second parent must be theirs"
nomerge "a clean merge"
head=$(git rev-parse HEAD)
[ "$(FORGE_ROOT=$tmp/nowhere mg theirs)" = 0 ] || fail "an up-to-date merge must exit 0: $(cat "$tmp/out" "$tmp/err")"
quiet theirs again
[ "$(git rev-parse HEAD)" = "$head" ] || fail "an up-to-date merge must leave HEAD unchanged"
[ "$(FORGE_ROOT=$tmp/nowhere mg nope)" = 1 ] || fail "merge of an unknown branch must exit 1: $(cat "$tmp/out" "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "merge nope prints nothing on stdout: $(cat "$tmp/out")"
[ "$(cat "$tmp/err")" = "merge: nope - not something we can merge" ] || fail "merge nope prints git's message on stderr: $(cat "$tmp/err")"
nomerge "merge nope"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "merge nope must leave HEAD unchanged"
cd ..
git checkout -q -b clash
echo c >shared.txt && git commit -q -am clash
git checkout -q main
echo m >shared.txt && git commit -q -am m
head=$(git rev-parse HEAD)
[ "$(mg clash)" = 4 ] || fail "a conflicting merge must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = shared.txt ] || fail "a conflicting merge lists its conflicted path on stdout: $(cat "$tmp/out")"
[ ! -s "$tmp/err" ] || fail "a conflicting merge prints nothing on stderr: $(cat "$tmp/err")"
[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$(git rev-parse clash)" ] || fail "a conflicting merge must stay in progress on clash"
[ "$(sed -n '/^|||||||/{n;p;}' shared.txt)" = a ] || fail "a conflicting merge writes diff3 markers: $(cat shared.txt)"
[ "$(mg theirs)" = 1 ] || fail "a merge during a merge must exit 1: $(cat "$tmp/out" "$tmp/err")"
[ ! -s "$tmp/out" ] && grep -q '^forge: ' "$tmp/err" || fail "a merge during a merge prints a forge: line on stderr: $(cat "$tmp/out" "$tmp/err")"
[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$(git rev-parse clash)" ] || fail "a merge during a merge must leave MERGE_HEAD at clash"
[ "$(mg --abort)" = 0 ] || fail "merge --abort must exit 0: $(cat "$tmp/out" "$tmp/err")"
quiet --abort
nomerge "merge --abort"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "merge --abort must leave HEAD unchanged"
[ "$(cat shared.txt)" = m ] || fail "merge --abort must restore shared.txt: $(cat shared.txt)"
[ "$(mg --abort)" = 1 ] || fail "merge --abort with no merge in progress must exit 1: $(cat "$tmp/out" "$tmp/err")"
[ ! -s "$tmp/out" ] && [ -s "$tmp/err" ] || fail "a failed merge --abort explains on stderr: $(cat "$tmp/out" "$tmp/err")"
for a in "" "a b" --continue --bogus; do
  [ "$(mg $a)" = 2 ] || fail "merge $a must exit 2: $(cat "$tmp/out" "$tmp/err")"
  nomerge "merge $a"
done
[ "$(git rev-parse HEAD)" = "$head" ] || fail "usage errors must leave HEAD unchanged"
mkdir -p "$tmp/nogit" && cd "$tmp/nogit"
[ "$(mg theirs)" = 1 ] || fail "merge outside a git repo must exit 1: $(cat "$tmp/out" "$tmp/err")"
[ ! -s "$tmp/out" ] && grep -q '^forge: ' "$tmp/err" || fail "merge outside a git repo prints a forge: line on stderr: $(cat "$tmp/out" "$tmp/err")"
cd "$tmp/mg"
ok merge
fi

if want merge-json; then
reqrepo
git init -q -b main
git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init

side union-ours
jed $trk --arg n c ".goal = \"G2\" | .features += [$feat]"
jed $req --arg n INT-03 ".requirements += [$rq] | (.requirements[] | select(.id == \"INT-02\") | .done) = true"
done_side ours
side union-theirs
jed $trk --arg n d "del(.features[] | select(.feature == \"intake\")) | .features += [$feat] | .shipped += [{feature: \"s\", phases: [\"09\"], date: \"2026-09-20\"}]"
jed $req --arg n INT-04 "del(.requirements[] | select(.id == \"INT-01\")) | .requirements += [$rq]"
done_side theirs
git checkout -q union-ours
[ "$(mg union-theirs)" = 0 ] || fail "a JSON merge the pass resolves must exit 0: $(cat "$tmp/out" "$tmp/err")"
quiet union-theirs
[ "$(git log -1 --format=%s)" = "Merge branch 'union-theirs' into union-ours" ] || fail "JSON merge commit subject: $(git log -1 --format=%s)"
[ "$(git rev-parse HEAD^2)" = "$(git rev-parse union-theirs)" ] || fail "the JSON merge commit's second parent must be union-theirs"
nomerge "a resolved JSON merge"
git show main:$trk | jq '.goal = "G2" | .features = .features[1:] + [{feature: "c", delivers: "C", depends: []}, {feature: "d", delivers: "D", depends: []}]
  | .shipped += [{feature: "s", phases: ["09"], date: "2026-09-20"}]' >"$tmp/want"
git show HEAD:$trk | diff -u "$tmp/want" - || fail "the track JSON must be the keyed union in ours' order then theirs' new records"
git show main:$req | jq '.requirements = [(.requirements[1] | .done = true), {id: "INT-03", text: "Req INT-03.", done: false}, {id: "INT-04", text: "Req INT-04.", done: false}]' >"$tmp/want"
git show HEAD:$req | diff -u "$tmp/want" - || fail "requirements.json must be the keyed union in ours' order then theirs' new records"

side clash-ours
jed $req --arg n INT-03 "(.requirements[] | select(.id == \"INT-02\") | .text) = \"A\" | .requirements += [$rq]"
done_side ours
side clash-theirs
jed $req '(.requirements[] | select(.id == "INT-02") | .text) = "B"'
done_side theirs
git checkout -q clash-ours
[ "$(mg clash-theirs)" = 4 ] || fail "a JSON record changed differently on both sides must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $req ] || fail "a JSON clash lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages $req)" = "1 2 3" ] || fail "a JSON clash stays unmerged: $(git ls-files -u)"
grep -q '^<<<<<<<' $req && grep -q '^|||||||' $req || fail "a JSON clash keeps git's diff3 markers: $(cat $req)"
git merge --abort

side addadd-ours
mkdir -p .forge/features/crm-new
jq -n --arg n NEW-01 "{requirements: [$rq]}" >.forge/features/crm-new/requirements.json
done_side ours
side addadd-theirs
mkdir -p .forge/features/crm-new
jq -n --arg n NEW-02 "{requirements: [$rq]}" >.forge/features/crm-new/requirements.json
done_side theirs
git checkout -q addadd-ours
[ "$(mg addadd-theirs)" = 4 ] || fail "an add/add JSON conflict must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = .forge/features/crm-new/requirements.json ] || fail "an add/add JSON conflict lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages .forge/features/crm-new/requirements.json)" = "2 3" ] || fail "an add/add JSON conflict stays unmerged: $(git ls-files -u)"
git merge --abort

side compact-ours
jq -c --arg n INT-03 ".requirements += [$rq]" $req >"$tmp/jed" && mv "$tmp/jed" $req
done_side ours
side compact-theirs
jed $req --arg n INT-04 ".requirements += [$rq]"
done_side theirs
git checkout -q compact-ours
head=$(git rev-parse HEAD)
line=$(git show compact-ours:$req)
[ "$(mg compact-theirs)" = 4 ] || fail "a JSON merge that loses a line to merge-check must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $req ] || fail "merge-check's path is listed on stdout: $(cat "$tmp/out")"
[ "$(cat "$tmp/err")" = "ours $req: $line" ] || fail "merge-check's output goes to stderr: $(cat "$tmp/err")"
[ -z "$(git ls-files -u)" ] || fail "the JSON pass must resolve the compacted file: $(git ls-files -u)"
[ "$(jq -c '[.requirements[].id]' $req)" = '["INT-01","INT-02","INT-03","INT-04"]' ] || fail "the JSON pass merges the compacted file: $(cat $req)"
! markers $req || fail "a JSON-merged file holds no conflict marker: $(cat $req)"
[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$(git rev-parse compact-theirs)" ] || fail "a merge-check failure leaves the merge in progress"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a merge-check failure must not commit"
git merge --abort

side invalid-ours
jed $trk '.goal = "G2"'
done_side ours
side invalid-theirs
jed $trk '.status = "maybe"'
done_side theirs
git checkout -q invalid-ours
[ "$(mg invalid-theirs)" = 4 ] || fail "a JSON merge that fails its schema must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $trk ] || fail "a schema-invalid JSON merge lists its path on stdout: $(cat "$tmp/out")"
grep -qF maybe "$tmp/err" || fail "a schema-invalid JSON merge leaves validate's message on stderr: $(cat "$tmp/err")"
[ "$(stages $trk)" = "1 2 3" ] || fail "a schema-invalid JSON merge is restored to unmerged: $(git ls-files -u)"
grep -q '^<<<<<<<' $trk && grep -q '^|||||||' $trk || fail "a schema-invalid JSON merge is restored with diff3 markers: $(cat $trk)"
git merge --abort

nt=.forge/notes.json lst=.forge/list.json
git checkout -q main
jq -n '{a: 1, b: 1}' >$nt
jq -n '{items: [{id: 1}]}' >$lst
git add -A && git commit -q -m unmapped
rside nt-ours $nt '.a = 2'
rside nt-theirs $nt '.b = 2 | .c = 3'
git checkout -q nt-ours
[ "$(mg nt-theirs)" = 0 ] || fail "a conflicted JSON with no schema is merged three-way and exits 0: $(cat "$tmp/out" "$tmp/err")"
quiet nt-theirs
[ -z "$(stages $nt)" ] || fail "an unmapped JSON merged three-way is staged: $(git ls-files -u)"
nomerge "an unmapped JSON merge"
git show HEAD:$nt | diff -u <(jq -n '{a: 2, b: 2, c: 3}') - || fail "an unmapped JSON takes each key changed on one side"

rside bad-ours $nt '.a = 2'
rside bad-theirs $nt '.b = 2 | .c = 3'
git checkout -q bad-ours
mkdir -p "$tmp/badjq"
printf '#!/usr/bin/env bash\nfor a; do [ "$a" != --slurpfile ] || { echo "{ not json"; exit 0; }; done\nexec %q "$@"\n' "$(command -v jq)" >"$tmp/badjq/jq" && chmod +x "$tmp/badjq/jq"
[ "$(PATH=$tmp/badjq:$PATH mg bad-theirs)" = 4 ] || fail "a merged JSON that does not parse must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $nt ] || fail "an unparsable JSON merge lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages $nt)" = "1 2 3" ] || fail "an unparsable JSON merge is restored to unmerged: $(git ls-files -u)"
grep -q '^<<<<<<<' $nt && grep -q '^|||||||' $nt || fail "an unparsable JSON merge is restored with diff3 markers: $(cat $nt)"
git merge --abort

rside lst-ours $lst '.items += [{id: 2}]'
rside lst-theirs $lst '.items += [{id: 3}]'
git checkout -q lst-ours
[ "$(mg lst-theirs)" = 4 ] || fail "an array of an unmapped JSON changed on both sides must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $lst ] || fail "an unmapped JSON array clash lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages $lst)" = "1 2 3" ] || fail "an unmapped JSON array clash stays unmerged: $(git ls-files -u)"
git merge --abort
ok merge-json
fi

if want merge-docs; then
docrepo

dside ap-ours ours-bullet
dside ap-theirs theirs-bullet
git checkout -q ap-ours
[ "$(mg ap-theirs)" = 0 ] || fail "an insert-only doc conflict must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "a doc-merged merge prints nothing on stdout: $(cat "$tmp/out")"
[ "$(git log -1 --format=%s)" = "Merge branch 'ap-theirs' into ap-ours" ] || fail "doc merge commit subject: $(git log -1 --format=%s)"
nomerge "a doc-merged merge"
printf '%s\n' '# Architecture' '' '## Components' '- a' '- ours-bullet' '- theirs-bullet' '' '## Boundaries' '- x' >"$tmp/want"
git show HEAD:$arch | diff -u "$tmp/want" - || fail "an insert-only doc hunk becomes ours' lines then theirs'"
[ -z "$(git status --porcelain)" ] || fail "a doc-merged merge leaves a clean worktree: $(git status --porcelain)"

git checkout -q ch-ours
[ "$(mg ch-theirs)" = 4 ] || fail "a doc conflict with a changed line must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $arch ] || fail "a doc conflict lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages $arch)" = "1 2 3" ] || fail "a doc with a kept hunk stays unmerged: $(git ls-files -u)"
printf '%s\n' '# Architecture' '' '## Components' '- a' '- ours-bullet' '- theirs-bullet' '' '## Boundaries' \
  '<<<<<<<' '- x1' '|||||||' '- x' '=======' '- x2' '>>>>>>>' >"$tmp/want"
sed -E 's/^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>) .*/\1/' $arch | diff -u "$tmp/want" - || fail "a doc keeps only its changed hunk, with markers"
[ "$(mg --abort)" = 0 ] || fail "merge --abort after a doc conflict must exit 0: $(cat "$tmp/out" "$tmp/err")"
ok merge-docs
fi

if want merge-state; then
st=.forge/STATE.md
rm -rf "$tmp/ms" && mkdir -p "$tmp/ms/.forge" && cd "$tmp/ms"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
printf '%s\n' '# State' '' '## Shipped' '- a' '' '## Notes' '- x' >$st
git add -A && git commit -q -m base
sside() { git checkout -q -b "$1" main; sed -i "s/^- a\$/- a\n- $2/" $st; [ -z "${3:-}" ] || sed -i "s/^- x\$/- $3/" $st; git commit -q -am "$1"; }
sside st-ours ours-bullet
sside st-theirs theirs-bullet
sside sc-ours ours-bullet x1
sside sc-theirs theirs-bullet x2
git checkout -q st-ours
[ "$(mg st-theirs)" = 0 ] || fail "an insert-only conflict in .forge/STATE.md merges as a hand doc and exits 0: $(cat "$tmp/out" "$tmp/err")"
quiet st-theirs
[ "$(git log -1 --format=%s)" = "Merge branch 'st-theirs' into st-ours" ] || fail "STATE.md hand-doc merge commit subject: $(git log -1 --format=%s)"
nomerge "a STATE.md hand-doc merge"
printf '%s\n' '# State' '' '## Shipped' '- a' '- ours-bullet' '- theirs-bullet' '' '## Notes' '- x' >"$tmp/want"
git show HEAD:$st | diff -u "$tmp/want" - || fail "an insert-only STATE.md hunk becomes ours' lines then theirs', not a render or one side"
[ -z "$(git status --porcelain)" ] || fail "a STATE.md hand-doc merge leaves a clean worktree with no rendered file: $(git status --porcelain)"

git checkout -q sc-ours
[ "$(mg sc-theirs)" = 4 ] || fail "a STATE.md conflict with a changed line must exit 4 like a hand doc: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = $st ] || fail "a STATE.md hand-doc conflict lists its path on stdout: $(cat "$tmp/out")"
[ "$(stages $st)" = "1 2 3" ] || fail "a STATE.md hand doc with a kept hunk stays unmerged, not checked out as one side: $(git ls-files -u)"
printf '%s\n' '# State' '' '## Shipped' '- a' '- ours-bullet' '- theirs-bullet' '' '## Notes' \
  '<<<<<<<' '- x1' '|||||||' '- x' '=======' '- x2' '>>>>>>>' >"$tmp/want"
sed -E 's/^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>) .*/\1/' $st | diff -u "$tmp/want" - || fail "a STATE.md hand doc keeps only its changed hunk, with markers"
printf '%s\n' '# State' '' '## Shipped' '- a' '- ours-bullet' '- theirs-bullet' '' '## Notes' '- x1' >$st
git add $st
[ "$(code "$forge" merge-check)" = 1 ] || fail "merge-check must check .forge/STATE.md like any hand doc: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "theirs $st: - x2" ] || fail "merge-check reports the line dropped from .forge/STATE.md: $(cat "$tmp/out")"
git merge --abort
ok merge-state
fi

if want merge-continue; then
listedrepo
docrepo
rec=$tmp/rec/merge
rm -rf "$tmp/rec" && mkdir -p "$rec"
record() { local f=$rec/$1; shift; jq -n "$@" >"$f"; [ "$(code "$forge" validate "$f")" = 0 ] || fail "record $f must be valid: $(cat "$tmp/out")"; }
record M1.json --arg p $arch '{files: [{path: $p, resolution: "Kept both bullets and ours'"'"' x1.", dropped: []}]}'
record M2.json --arg p $arch '{files: [{path: $p, resolution: "Kept both bullets and ours'"'"' x1.", dropped: [{side: "theirs", line: "- x2", reason: "ours'"'"' x1 supersedes it"}]}]}'
cd "$tmp/md"
head=$(git rev-parse HEAD)
[ "$(mg --continue "$rec/M1.json")" = 1 ] || fail "merge --continue with no merge in progress must exit 1: $(cat "$tmp/out" "$tmp/err")"
grep -q '^forge: ' "$tmp/err" || fail "merge --continue with no merge in progress prints a forge: line on stderr: $(cat "$tmp/out" "$tmp/err")"
nomerge "merge --continue with no merge in progress"
[ "$(mg ch-theirs)" = 4 ] || fail "the doc conflict rerun must exit 4: $(cat "$tmp/out" "$tmp/err")"
[ "$(mg --continue "$rec/M1.json")" = 1 ] || fail "merge --continue with an unmerged path must exit 1: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/err")" = "forge: unmerged $arch" ] || fail "merge --continue names each unmerged path on stderr: $(cat "$tmp/err")"
[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$(git rev-parse ch-theirs)" ] || fail "merge --continue with an unmerged path leaves the merge in progress"
printf '%s\n' '# Architecture' '' '## Components' '- a' '- ours-bullet' '- theirs-bullet' '' '## Boundaries' '- x1' >$arch
git add $arch
[ "$(mg --continue "$rec/M1.json")" = 1 ] || fail "merge --continue with an unrecorded lost line must exit 1: $(cat "$tmp/out" "$tmp/err")"
grep -qxF "theirs $arch: - x2" "$tmp/out" || fail "merge --continue prints merge-check's output: $(cat "$tmp/out" "$tmp/err")"
[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$(git rev-parse ch-theirs)" ] || fail "a failed merge-check leaves the merge in progress"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a failed merge-check must not commit"
cd .forge
[ "$(mg --continue ../../rec/merge/M2.json)" = 0 ] || fail "merge --continue with a record giving the reason must exit 0: $(cat "$tmp/out" "$tmp/err")"
cd ..
[ "$(git log -1 --format=%s)" = "Merge branch 'ch-theirs' into ch-ours" ] || fail "merge --continue commit subject: $(git log -1 --format=%s)"
[ "$(git rev-parse HEAD^2)" = "$(git rev-parse ch-theirs)" ] || fail "the continued merge commit's second parent must be ch-theirs"
nomerge "a continued merge"

cd "$tmp/p"
[ "$(mg listed-theirs)" = 4 ] || fail "the planning JSON clash rerun must exit 4: $(cat "$tmp/out" "$tmp/err")"
git show HEAD:$req | jq '(.requirements[] | select(.id == "INT-02") | .text) = "A and B"' >$req
git add $req
record M3.json --arg p $req '{files: [{path: $p, resolution: "Joined both texts.", dropped: [{side: "ours", line: "\"text\": \"A\",", reason: "joined into A and B"}, {side: "theirs", line: "\"text\": \"B\",", reason: "joined into A and B"}]}]}'
[ "$(mg --continue "$rec/M3.json")" = 0 ] || fail "merge --continue after a resolved planning clash must exit 0: $(cat "$tmp/out" "$tmp/err")"
nomerge "a continued planning merge"
[ -z "$(git status --porcelain)" ] || fail "a continued planning merge leaves a clean worktree: $(git status --porcelain)"
ok merge-continue
fi
finish
