#!/usr/bin/env bash
set -euo pipefail
export FORGE_UNAME=Linux
. "$(dirname "$0")/forge-common.sh"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "forge-commit: FAIL $*" >&2; exit 1; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
ok() { echo "forge-commit $1: ok"; [ "$1" != "$only" ] || exit 0; }
code() { local s=0; "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
edit() { jq "$1" "$2" >"$tmp/edit" && mv "$tmp/edit" "$2"; }
S=$XDG_STATE_HOME/forge/p
repo() {
  rm -rf "$tmp/p" && project "$tmp/p" && cd "$tmp/p"
  git init -q -b main
  gcd=$(git rev-parse --path-format=absolute --git-common-dir)
  git config user.name forge && git config user.email forge@example.com
  git add -A && git commit -q -m init
}
real=$(sed -n '1s/^#!\([^ ]*\).*/\1/p' "$(readlink -f "$(command -v check-jsonschema)")")
mkdir -p "$tmp/slow"
cat >"$tmp/slow/python" <<EOF
#!/usr/bin/env bash
[ ! -f "\$SLOW_GATE" ] || sleep "\$(cat "\$SLOW_GATE")"
exec "$real" "\$@"
EOF
printf '#!%s\n' "$tmp/slow/python" >"$tmp/slow/check-jsonschema"
chmod +x "$tmp/slow/python" "$tmp/slow/check-jsonschema"
export SLOW_GATE=$tmp/slow-gate

if want lock; then
repo
edit '.goal = "Held"' .forge/tracks/crm.json
edit '.goal = "Waiter"' .forge/tracks/voice.json
echo 2 >"$SLOW_GATE"
PATH=$tmp/slow:$PATH "$forge" commit crm held >"$tmp/a" 2>&1 & a=$!
sleep 1
rm -f "$SLOW_GATE"
[ "$(code "$forge" commit voice waiter)" = 0 ] || fail "a waiting commit must succeed: $(cat "$tmp/err")"
wait $a || fail "the holding commit: $(cat "$tmp/a")"
[ "$(grep -c 'waiting for forge.lock' "$tmp/err")" = 1 ] || fail "a waiter prints one waiting line: $(cat "$tmp/err")"
grep -qE "^forge: waiting for forge.lock \(held by $a .*commit crm held.* since .+\)$" "$tmp/err" || fail "the waiting line names the holder: $(cat "$tmp/err")"
[ "$(git log --format=%s -2 | paste -sd,)" = "forge(voice): waiter,forge(crm): held" ] || fail "the waiter commits after the holder: $(git log --format=%s -3)"
[ -e "$gcd/forge.lock" ] || fail "forge.lock lives in the git common dir"
: >"$tmp/err"
"$forge" commit crm again >/dev/null 2>"$tmp/err"
! grep -q waiting "$tmp/err" || fail "an uncontended lock prints nothing: $(cat "$tmp/err")"
ok lock
fi

if want commit-staged; then
repo
mkdir -p "$tmp/late"
cat >"$tmp/late/python" <<EOF
#!/usr/bin/env bash
s=0; "$real" "\$@" || s=\$?
case " \$* " in *"/tracks/crm.json "*) [ ! -f "\$SLOW_GATE" ] || sleep "\$(cat "\$SLOW_GATE")" ;; esac
exit \$s
EOF
printf '#!%s\n' "$tmp/late/python" >"$tmp/late/check-jsonschema"
chmod +x "$tmp/late/python" "$tmp/late/check-jsonschema"
edit '.goal = "Valid"' .forge/tracks/crm.json
echo 2 >"$SLOW_GATE"
PATH=$tmp/late:$PATH "$forge" commit crm racy >"$tmp/a" 2>&1 & a=$!
sleep 1
edit '.extra = 1' .forge/tracks/crm.json
rm -f "$SLOW_GATE"
wait $a || true
! git show HEAD:.forge/tracks/crm.json | jq -e 'has("extra")' >/dev/null || fail "commit must not commit JSON written after its validation: $(cat "$tmp/a")"
ok commit-staged
fi

if want lock-alloc-archive; then
repo
edit '.phases |= map(del(.number))' "$S/features/crm-routing/split.json"
flock "$gcd/forge.lock" sleep 2 & a=$!
sleep 0.5
out=$("$forge" alloc crm/routing 2>"$tmp/err")
wait $a
grep -q '^forge: waiting for forge.lock' "$tmp/err" || fail "alloc waits on forge.lock: $(cat "$tmp/err")"
[ "$out" = "$(printf '%s\n' "$S/phases/05-routing-rules" "$S/phases/06-routing-ui")" ] || fail "alloc after the wait: $out"
[ -f "$S/phases/06-routing-ui/spec.json" ] && [ ! -e .forge/phases ] || fail "alloc writes the phase specs in the state dir: $(ls -A .forge)"
echo '{"final_review": ["No findings"], "pr": "https://example.com/pr/1", "date": "2026-09-25"}' >"$S/features/crm-intake/ship.json"
git branch forge/crm-intake main
head=$(git rev-parse HEAD)
flock "$gcd/forge.lock" sleep 2 & a=$!
sleep 0.5
"$forge" archive crm/intake 2>"$tmp/err"
wait $a
grep -q '^forge: waiting for forge.lock' "$tmp/err" || fail "archive waits on forge.lock: $(cat "$tmp/err")"
[ -d "$S/archive/crm-intake/phases/02-intake-form" ] && [ ! -e "$S/features/crm-intake" ] || fail "archive after the wait moves the feature inside the state dir"
[ ! -e .forge/archive ] || fail "archive writes nothing under .forge/archive"
[ "$(git rev-parse HEAD)" = "$head" ] && [ "$(git status --porcelain)" = " M .forge/tracks/crm.json" ] || fail "archive leaves only tracks/crm.json to commit: $(git status --porcelain)"
ok lock-alloc-archive
fi

files() { git show --name-only --format= "${1:-HEAD}" | sort | paste -sd' '; }
unrendered() {
  local x
  x=$(find .forge -path .forge/archive -prune -o \( -name STATE.md -o -name FEATURE.md -o -name PHASE.md -o -path '.forge/tracks/*.md' \) -print; git ls-tree -r --name-only HEAD -- .forge | grep -E '^\.forge/(STATE|tracks/[^/]+|features/[^/]+/FEATURE|phases/[^/]+/PHASE)\.md$' || true)
  [ -z "$x" ] || fail "no command renders planning Markdown: $x"
}
if want commit-output; then
repo
edit '.goal = "New goal"' .forge/tracks/crm.json
out=$("$forge" commit crm "track goal")
[[ $out =~ ^forge:\ committed\ ([0-9a-f]{7,})\ \(1\ files?\)\ forge\(crm\):\ track\ goal$ ]] || fail "success line: $out"
[ "${BASH_REMATCH[1]}" = "$(git rev-parse --short HEAD)" ] || fail "success line names HEAD: $out"
[ "$(files)" = ".forge/tracks/crm.json" ] || fail "track commit files: $(files)"
[ -z "$(git status --porcelain)" ] || fail "the shared index is synced: $(git status --porcelain)"
[ "$("$forge" commit crm again)" = "forge: recorded crm again" ] || fail "a scope with no in-repo change prints the recorded line naming the scope and step"
ok commit-output
fi

if want commit-isolation; then
repo
edit '.status = "maybe"' .forge/tracks/crm.json
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit crm bad)" = 1 ] || fail "invalid scope JSON must block the commit"
grep -qF "$PWD/.forge/tracks/crm.json" "$tmp/err" || fail "a schema failure names the absolute file: $(cat "$tmp/err")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a schema failure commits nothing"
git checkout -q -- .forge/tracks/crm.json
echo '{"phases": [' >"$S/features/crm-routing/split.json"
edit '.goal = "Changed voice goal"' .forge/tracks/voice.json
edit '.spec += ["Scoped."]' "$S/phases/03-intake-api/spec.json"
[ "$(code "$forge" commit 03 spec)" = 0 ] || fail "another feature's invalid state dir JSON must not block: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "forge: recorded 03 spec" ] || fail "a phase scope with only state dir changes prints the recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a phase scope commits nothing: $(git log -1 --format=%s)"
jq -e '.spec[-1] == "Scoped."' "$S/phases/03-intake-api/spec.json" >/dev/null || fail "the phase spec stays in the state dir as written"
[ "$(git status --porcelain | sort | paste -sd,)" = " M .forge/tracks/voice.json" ] || fail "out-of-scope files stay as they were: $(git status --porcelain)"
printf '{"questions": [' >"$S/phases/03-intake-api/research.json"
[ "$(code "$forge" commit 03 bad)" = 1 ] || fail "an unparsable state dir file in scope must block: $(cat "$tmp/out" "$tmp/err")"
grep -qF "$S/phases/03-intake-api/research.json" "$tmp/err" || fail "the refusal names the state dir file by its absolute path: $(cat "$tmp/err")"
grep -qF "forge: planning JSON of scope 03 fails its schema; nothing committed" "$tmp/err" || fail "the refusal says nothing is committed: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "a refused scope prints no recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused state dir file commits nothing"
unrendered
ok commit-isolation
fi

swept=(.forge/STATE.md .forge/tracks/crm.md .forge/tracks/voice.md)
keepers=(.forge/CONCERNS.md .forge/notes/FEATURE.md .forge/tracks/crm/x.md)
stale=(features/crm-routing/FEATURE.md features/crm-routing/procedure.md phases/03-intake-api/PHASE.md archive/crm-auth/FEATURE.md archive/crm-auth/phases/01-auth-login/PHASE.md)
sweeprepo() {
  local x
  repo
  for x in "${swept[@]}" "${keepers[@]}"; do
    mkdir -p "$(dirname "$x")" && echo "# $x" >"$x"
  done
  for x in "${stale[@]}"; do echo "# $x" >"$S/$x"; done
  git add -A && git commit -q -m "rendered"
}
swepttree() {
  local x
  for x in "${swept[@]}"; do
    [ ! -e "$x" ] || fail "$1: the rendered working copy $x is removed"
    [ -z "$(git ls-files -- "$x")" ] || fail "$1: the rendered $x is no longer tracked"
  done
  for x in "${keepers[@]}"; do
    [ -f "$x" ] || fail "$1: the keeper $x stays on disk"
    [ -n "$(git ls-files -- "$x")" ] || fail "$1: the keeper $x stays tracked"
  done
  for x in "${stale[@]}"; do
    [ "$(cat "$S/$x")" = "# $x" ] || fail "$1: the sweep never touches the state dir file $S/$x"
  done
  [ -z "$(git status --porcelain --untracked-files=all)" ] || fail "$1: the real index and working tree agree after publish: $(git status --porcelain --untracked-files=all)"
}
if want commit-sweep; then
sweeprepo
edit '.goal = "Swept voice goal"' .forge/tracks/voice.json
[ "$(code "$forge" commit voice goal)" = 0 ] || fail "an unrelated scope commits with the sweep: $(cat "$tmp/out" "$tmp/err")"
[ "$(git log -1 --format=%s)" = "forge(voice): goal" ] || fail "the sweep rides the scope's own commit: $(git log -1 --format=%s)"
exp=$(printf '%s\n' .forge/tracks/voice.json "${swept[@]}" | sort | paste -sd' ')
[ "$(files)" = "$exp" ] || fail "the voice commit carries voice.json and the rendered set's deletions: $(files)"
[ -z "$(git diff-tree -r --root --no-commit-id --diff-filter=d --name-only HEAD | grep -v '^\.forge/tracks/voice\.json$')" ] || fail "every swept file is a deletion: $(git diff-tree -r --root --no-commit-id --name-status HEAD)"
swepttree "after the voice commit"
[ "$("$forge" commit crm again)" = "forge: recorded crm again" ] || fail "a second commit adds no deletions and prints the recorded line"
swepttree "after the second commit"
sweeprepo
head=$(git rev-parse HEAD)
[ "$(code "$forge" commit crm x)" = 0 ] || fail "a scope with no change of its own commits the sweep: $(cat "$tmp/out" "$tmp/err")"
[ "$(git rev-parse HEAD^)" = "$head" ] || fail "the sweep-only commit sits on the previous HEAD"
[ "$(git log -1 --format=%s)" = "forge(crm): x" ] || fail "the sweep-only commit uses the scope's message: $(git log -1 --format=%s)"
exp=$(printf '%s\n' "${swept[@]}" | sort | paste -sd' ')
[ "$(files)" = "$exp" ] || fail "a scope with no change commits only the deletions: $(files)"
[ -z "$(git diff-tree -r --root --no-commit-id --diff-filter=d --name-only HEAD)" ] || fail "the sweep-only commit holds only deletions: $(git diff-tree -r --root --no-commit-id --name-status HEAD)"
swepttree "after the sweep-only commit"
ok commit-sweep
fi

if want commit-release; then
repo
echo '{"repos": [{"window": {"tz": "America/Nowhere"}}]}' >.forge/release.json
edit '.goal = "Released goal"' .forge/tracks/crm.json
[ "$(code "$forge" commit crm goal)" = 0 ] || fail "a release.json with an unknown tz no longer blocks a commit: $(cat "$tmp/out" "$tmp/err")"
[ "$(files)" = ".forge/tracks/crm.json" ] || fail "the commit carries only the scope: $(files)"
ok commit-release
fi

if want feature-events; then
repo
fe=$S/features/crm-routing/events.jsonl
head=$(git rev-parse HEAD)
jq -cn '{time: "2026-09-30T00:00:00Z", step: "start", message: "p verify crm/routing", offset: 30}' >"$fe"
[ "$(code "$forge" commit crm/routing verify)" = 0 ] || fail "a feature start event with an integer offset must pass: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "forge: recorded crm/routing verify" ] || fail "a feature scope with only its state dir events.jsonl changed prints the recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "the feature events.jsonl stays out of the repo: $(files)"
jq -e '.step == "start" and .offset == 30' "$fe" >/dev/null || fail "the state dir events.jsonl stays as written: $(cat "$fe")"
cp "$fe" "$tmp/fe"
echo '{"time": "2026-09-30T00:01:00Z", "step": "start",' >>"$fe"
[ "$(code "$forge" commit crm/routing verify)" = 1 ] || fail "an unparsable feature event line must be refused: $(cat "$tmp/out" "$tmp/err")"
grep -qF "$fe" "$tmp/err" || fail "the refusal names the state dir feature events.jsonl: $(cat "$tmp/err")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused feature events.jsonl commits nothing"
cp "$tmp/fe" "$fe"
jq -cn '{time: "2026-09-30T00:02:00Z", step: "start", message: "p verify crm/routing", offset: 40, session: "a1b2c3d4"}' >>"$fe"
[ "$(code "$forge" validate "$fe")" = 0 ] || fail "forge validate must accept a start event with a string session: $(cat "$tmp/out" "$tmp/err")"
[ "$(code "$forge" commit crm/routing verify)" = 0 ] || fail "a feature start event with a string session must pass: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$tmp/out")" = "forge: recorded crm/routing verify" ] || fail "the session event is recorded: $(cat "$tmp/out")"
tail -1 "$fe" | jq -e '.step == "start" and .session == "a1b2c3d4" and .offset == 40' >/dev/null || fail "the start event keeps its session: $(cat "$fe")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "no feature event reaches HEAD"
ok feature-events
fi

names() { grep -F "$1" "$tmp/err" | grep -w "$2" | grep -qw "$3"; }
newtrack() { echo "{\"track\": \"$1\", \"goal\": \"Long\", \"status\": \"open\", \"notes\": [], \"features\": [], \"shipped\": []}" >".forge/tracks/$1.json"; }
if want name-limits; then
repo
head=$(git rev-parse HEAD)
edit '.features += [{"feature": "a-feature-name-over-20", "delivers": "Long", "depends": []}]' .forge/tracks/crm.json
[ "$(code "$forge" commit crm "long feature")" = 1 ] || fail "a new feature name over 20 characters must be refused: $(cat "$tmp/out" "$tmp/err")"
names a-feature-name-over-20 22 20 || fail "the refusal names the feature, its length and the limit: $(cat "$tmp/err")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused feature name commits nothing"
git checkout -q -- .forge/tracks/crm.json
newtrack a-track-name-over-16
[ "$(code "$forge" commit a-track-name-over-16 "open track")" = 1 ] || fail "a new track name over 16 characters must be refused: $(cat "$tmp/out" "$tmp/err")"
names a-track-name-over-16 20 16 || fail "the refusal names the track, its length and the limit: $(cat "$tmp/err")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused track name commits nothing"
edit '.features += [{"feature": "a-feature-name-over-20", "delivers": "Long", "depends": []}]' .forge/tracks/crm.json
git add -A && git commit -q -m "long names"
edit '.goal = "Kept long"' .forge/tracks/a-track-name-over-16.json
[ "$(code "$forge" commit a-track-name-over-16 "track goal")" = 0 ] || fail "a long track name already at HEAD must stay valid: $(cat "$tmp/err")"
edit '.goal = "Kept long"' .forge/tracks/crm.json
[ "$(code "$forge" commit crm "track goal")" = 0 ] || fail "a long feature name already at HEAD must stay valid: $(cat "$tmp/err")"
edit '.shipped += [{"feature": "a-shipped-name-over-twenty", "phases": ["09"], "date": "2026-09-20"}]' .forge/tracks/crm.json
[ "$(code "$forge" commit crm "long shipped")" = 0 ] || fail "a shipped entry is never length-checked: $(cat "$tmp/err")"
ok name-limits
fi

if want commit-concurrent; then
repo
edit '.goal = "Crm"' .forge/tracks/crm.json
edit '.goal = "Voice"' .forge/tracks/voice.json
realgit=$(command -v git)
mkdir -p "$tmp/gw"
cat >"$tmp/gw/git" <<EOF
#!/usr/bin/env bash
raw() {
  echo "\$1" >"$tmp/p/\$1.txt"
  env -u GIT_INDEX_FILE "$realgit" -C "$tmp/p" add "\$1.txt" 2>/dev/null && env -u GIT_INDEX_FILE "$realgit" -C "$tmp/p" commit -q -m "feat: \$1" 2>/dev/null
}
if [[ " \$* " == *" commit-tree "* ]] && mkdir "$tmp/once-ct" 2>/dev/null; then
  raw raw1 || exit 9
fi
if [[ " \$* " == *" update-ref "* ]]; then
  "$realgit" "\$@" || exit
  if mkdir "$tmp/once-ur" 2>/dev/null; then
    if raw raw2; then
      touch "$tmp/raw2.done"
    else
      (for i in \$(seq 100); do raw raw2 && break; sleep 0.1; done; touch "$tmp/raw2.done") >/dev/null 2>&1 &
    fi
  fi
  exit 0
fi
exec "$realgit" "\$@"
EOF
chmod +x "$tmp/gw/git"
PATH=$tmp/gw:$PATH "$forge" commit crm goal >"$tmp/a" 2>&1 & a=$!
PATH=$tmp/gw:$PATH "$forge" commit voice goal >"$tmp/b" 2>&1 & b=$!
wait $a || fail "concurrent commit crm: $(cat "$tmp/a")"
wait $b || fail "concurrent commit voice: $(cat "$tmp/b")"
for i in $(seq 100); do [ ! -e "$tmp/raw2.done" ] || break; sleep 0.1; done
[ -e "$tmp/raw2.done" ] || fail "the raw commit after the ref move never ran"
[ "$(git log --format=%s | sort | paste -sd,)" = "feat: raw1,feat: raw2,forge(crm): goal,forge(voice): goal,init" ] || fail "no commit is lost: $(git log --format=%s)"
for c in $(git rev-list HEAD~4..HEAD); do
  case $(git log -1 --format=%s "$c") in
    "forge(crm): goal") [ "$(files "$c")" = ".forge/tracks/crm.json" ] || fail "concurrent crm commit files: $(files "$c")" ;;
    "forge(voice): goal") [ "$(files "$c")" = ".forge/tracks/voice.json" ] || fail "concurrent voice commit files: $(files "$c")" ;;
    "feat: raw1") [ "$(files "$c")" = raw1.txt ] || fail "the raw commit before the ref move holds only its file: $(files "$c")" ;;
    "feat: raw2") [ "$(files "$c")" = raw2.txt ] || fail "the raw commit after the ref move holds only its file: $(files "$c")" ;;
  esac
done
[ "$(git show HEAD:.forge/tracks/crm.json | jq -r .goal)" = Crm ] || fail "main keeps the crm goal"
[ "$(git show HEAD:.forge/tracks/voice.json | jq -r .goal)" = Voice ] || fail "main keeps the voice goal"
[ -z "$(git status --porcelain)" ] || fail "both scopes committed and synced: $(git status --porcelain)"
[ ! -e .git/index.lock ] || fail "commit leaves no index.lock"
ok commit-concurrent
fi

if want commit-ref-lock; then
for l in HEAD.lock refs/heads/main.lock index.lock; do
  repo
  edit ".goal = \"$l\"" .forge/tracks/crm.json
  : >".git/$l"
  (sleep 1; rm -f ".git/$l") &
  [ "$(code "$forge" commit crm goal)" = 0 ] || fail "commit must wait out a held $l: $(cat "$tmp/err")"
  wait
  [ "$(git show HEAD:.forge/tracks/crm.json | jq -r .goal)" = "$l" ] || fail "commit lands after $l frees"
  [ -z "$(git status --porcelain)" ] || fail "the index is synced after $l frees: $(git status --porcelain)"
done
ok commit-ref-lock
fi

if want commit-mid-merge; then
repo
echo base >code.txt && git add code.txt && git commit -q -m base
git checkout -q -b side && echo side >code.txt && git commit -q -am side && git checkout -q main
echo main >code.txt && git commit -q -am main
! git merge -q side >/dev/null 2>&1 || fail "the merge scenario must conflict"
echo extra >extra.txt && git add extra.txt
edit '.goal = "Mid-merge"' .forge/tracks/voice.json
[ "$(code "$forge" commit voice goal)" = 0 ] || fail "commit during a merge: $(cat "$tmp/err")"
[ "$(git log -1 --format=%s)" = "forge(voice): goal" ] || fail "the scope commit lands on main"
[ "$(git rev-list --parents -1 HEAD | wc -w)" = 2 ] || fail "the scope commit has one parent"
[ "$(files)" = ".forge/tracks/voice.json" ] || fail "mid-merge commit files: $(files)"
[ "$(git rev-parse MERGE_HEAD)" = "$(git rev-parse side)" ] || fail "MERGE_HEAD stays"
[ "$(git diff --name-only --diff-filter=U)" = code.txt ] || fail "the conflict stays: $(git diff --name-only --diff-filter=U)"
[ "$(git diff --cached --name-only --diff-filter=A)" = extra.txt ] || fail "extra.txt stays staged: $(git diff --cached --name-only)"
[ -z "$(git status --porcelain -- .forge)" ] || fail "the scope is synced in the shared index: $(git status --porcelain -- .forge)"
echo merged >code.txt && git add code.txt && git commit -q --no-edit
[ "$(git show HEAD:.forge/tracks/voice.json | jq -r .goal)" = Mid-merge ] || fail "concluding the merge keeps the scope commit"
[ "$(git show HEAD:extra.txt)" = extra ] || fail "the merge carries the staged extra.txt"
ok commit-mid-merge
fi

if want commit-stray; then
repo
git worktree add -q "$tmp/wt" -b side
head=$(git rev-parse HEAD)
edit '.goal = "Wrong copy"' "$tmp/wt/.forge/tracks/crm.json"
edit '.goal = "Elsewhere"' "$tmp/wt/.forge/tracks/voice.json"
mkdir -p "$tmp/wt/.forge/features/crm-intake"
echo '{"questions": []}' >"$tmp/wt/.forge/features/crm-intake/gaps.json"
(cd "$tmp/wt" && FORGE_ROOT=$tmp/p "$forge" commit crm x >"$tmp/out" 2>"$tmp/err") || fail "a track scope with no change in the root exits 0: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "forge: recorded crm x" ] || fail "a track scope with no change in the root prints the recorded line: $(cat "$tmp/out")"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "a stray worktree track change commits nothing"
grep -qF "$tmp/wt/.forge/tracks/crm.json" "$tmp/err" || fail "the warning names the stray track file: $(cat "$tmp/err")"
grep -qF "$tmp/p/.forge" "$tmp/err" || fail "the warning names the root .forge: $(cat "$tmp/err")"
! grep -q voice "$tmp/err" || fail "the warning names only the scope's track files: $(cat "$tmp/err")"
! grep -q features "$tmp/err" || fail "the warning names no feature file, which lives in the state dir: $(cat "$tmp/err")"
(cd "$tmp/wt" && FORGE_ROOT=$tmp/p "$forge" commit crm/intake x >"$tmp/out" 2>"$tmp/err") || fail "a feature scope with no change in the root exits 0: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "forge: recorded crm/intake x" ] || fail "a feature scope with no change in the root prints the recorded line: $(cat "$tmp/out")"
grep -qF "$tmp/wt/.forge/tracks/crm.json" "$tmp/err" || fail "a feature scope warns of its stray track file: $(cat "$tmp/err")"
! grep -q gaps.json "$tmp/err" || fail "a feature scope warns of no worktree feature file: $(cat "$tmp/err")"
(cd "$tmp/wt" && FORGE_ROOT=$tmp/p "$forge" commit old x >"$tmp/out" 2>"$tmp/err") || fail "a recorded old scope exits 0: $(cat "$tmp/err")"
[ ! -s "$tmp/err" ] || fail "no warning without stray scope track files: $(cat "$tmp/err")"
ok commit-stray
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) printf 'backgrounded · %s · %s\n' "$(printf %s "$3" | md5sum | cut -c1-8)" "$3"; exit "${CLAUDE_BG_EXIT:-0}" ;;
  agents) cat "$CLAUDE_AGENTS" ;;
esac
STUB
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SYSTEMD_LOG"
STUB
cat >"$tmp/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$SYSTEMD_LOG"
for a; do shift; [ "$a" != -- ] || exec "$@"; done
[ -z "${SYSTEMD_RUN_FAIL:-}" ] || { echo "$SYSTEMD_RUN_FAIL" >&2; exit 1; }
STUB
cat >"$tmp/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" != -- ] || shift
printf '%s | %s\n' "$1" "$2" >>"$NOTIFY_LOG"
STUB
chmod +x "$tmp/bin/claude" "$tmp/bin/systemctl" "$tmp/bin/systemd-run" "$tmp/bin/notify-send"
export PATH=$tmp/bin:$PATH CLAUDE_LOG=$tmp/claude.log CLAUDE_AGENTS=$tmp/agents.json SYSTEMD_LOG=$tmp/systemd.log NOTIFY_LOG=$tmp/notify.log
claude_home
p5=$S/phases/05-export-core
feature() {
  rm -rf "$tmp/p" && project "$tmp/p" && cd "$tmp/p"
  git init -q -b main && git config user.name forge && git config user.email forge@example.com
  : >"$CLAUDE_LOG"
  echo '[]' >"$CLAUDE_AGENTS"
  mkdir -p "$S/features/crm-export"
  echo '{"requirements": [{"id": "EXP-01", "text": "Export leads", "done": false}]}' >"$S/features/crm-export/requirements.json"
  echo "{\"phases\": [{\"slug\": \"export-core\", \"goal\": \"Core\", \"spec\": [], \"requirements\": [\"EXP-01\"], \"depends\": []}, {\"slug\": \"export-api\", \"goal\": \"API\", \"spec\": [], \"requirements\": [\"EXP-01\"], \"depends\": ${1:-[]}}]}" >"$S/features/crm-export/split.json"
  "$forge" alloc crm/export >/dev/null
  printf -- '- All tests: `true`\n' >.forge/TESTING.md
  git add -A && git commit -q -m init
  [ -n "${NOIMPL:-}" ] || "$forge" implement crm/export >/dev/null
}

if want done-no-recommit; then
feature '["export-core"]'
w=.claude/worktrees/crm-export-05
echo a >"$w/a.txt" && git -C "$w" add a.txt && git -C "$w" commit -q -m a
"$forge" test "$w" >/dev/null
echo '{"status": "done", "summary": "core"}' >"$p5/result.json"
head=$(git rev-parse HEAD)
[ "$("$forge" commit 05 result)" = "forge: recorded 05 result" ] || fail "the result step is recorded in the state dir"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "the recorded result commits nothing: $(git log -1 --format=%s)"
out=$("$forge" done 05 2>&1) || fail "done 05: $out"
! grep -q "nothing to commit\|forge: committed" <<<"$out" || fail "done makes no redundant commit: $out"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "done without replans commits nothing: $(git log -1 --format=%s)"
git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "done still merges the phase"
ok done-no-recommit
fi

gated() {
  local step=$1 need=$2 head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit 03 "$step")" = 1 ] || fail "step $step must be refused: $(cat "$tmp/out")"
  grep -qF -- "$need" "$tmp/err" || fail "the refusal of $step names $need: $(cat "$tmp/err")"
  [ ! -s "$tmp/out" ] || fail "a refused $step prints no recorded line: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused $step commits nothing"
}
passes() {
  local head
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" commit 03 "$1")" = 0 ] || fail "step $1 must pass: $(cat "$tmp/err")"
  [ "$(cat "$tmp/out")" = "forge: recorded 03 $1" ] || fail "step $1 of a phase prints the recorded line: $(cat "$tmp/out")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "step $1 of a phase leaves HEAD unchanged"
}
if want commit-gates; then
repo
start=$(git rev-parse HEAD)
d=$S/phases/03-intake-api
sha() { sha256sum "$d/plan.json" | cut -d' ' -f1; }
rm "$d/research.json"
gated plan "$d/plan.json"
echo '{"tasks": [{"id": "T1", "title": "x", "requirements": ["INT-02"], "files": ["api.ts"], "deps": [], "dep_reasons": {}, "test": "exempt", "exempt_reason": "glue"}]}' >"$d/plan.json"
gated plan "forge check 03"
"$forge" check 03 >/dev/null
[ "$(jq -rs 'map(select(.step == "check")) | last.plan' "$d/events.jsonl")" = "$(sha)" ] || fail "forge check logs the sha256 of plan.json in its check event: $(cat "$d/events.jsonl")"
passes plan
edit '.tasks[0].files += ["b.ts"]' "$d/plan.json"
gated plan "forge check 03"
"$forge" check 03 >/dev/null
jq -cn '{time: "2026-09-27T00:00:00Z", step: "replan", message: "spec changed"}' >>"$d/events.jsonl"
gated plan "forge check 03"
"$forge" check 03 >/dev/null
passes plan
[ ! -e "$d/research.json" ] && [ ! -e "$d/scout.json" ] || fail "plan passes with no research.json or scout.json"
passes T1
passes escalate
cp "$d/plan.json" "$tmp/plan"
edit '.tasks[0].files += ["c.ts"]' "$d/plan.json"
gated T1 "forge check 03"
cp "$tmp/plan" "$d/plan.json"
passes T1
edit '.tasks[0].files += ["c.ts"]' "$d/plan.json"
"$forge" check 03 >/dev/null
passes T1
edit '.tasks[0].files += ["d.ts"]' "$d/plan.json"
gated T2 "forge check 03"
"$forge" check 03 >/dev/null
passes T2
jq -cn '{time: "2026-09-27T00:01:00Z", step: "check", message: "plan ok"}' >>"$d/events.jsonl"
gated plan "forge check 03"
gated T3 "forge check 03"
"$forge" check 03 >/dev/null
passes plan
for st in check start wait retry replan; do
  ev=$(cat "$d/events.jsonl")
  [ "$(code "$forge" event 03 $st forged)" = 1 ] && grep -qF "$st" "$tmp/err" || fail "forge event must refuse step $st: $(cat "$tmp/err")"
  [ "$(cat "$d/events.jsonl")" = "$ev" ] || fail "a refused event $st logs nothing"
done
"$forge" event --help >"$tmp/out"
sed -n '/^Refuses/,/^$/p' "$tmp/out" | tr -s ' \n' '  ' | grep -qF 'check, start, wait, retry and replan' || fail "event help lists check, start, wait, retry and replan as the refused steps: $(cat "$tmp/out")"
! sed -n '/^Refuses/,/^$/p' "$tmp/out" | grep -qw accept || fail "event help no longer lists accept among the refused steps: $(cat "$tmp/out")"
echo '{"status": "blocked", "summary": "stop"}' >"$d/result.json"
passes result
echo '{"status": "done", "summary": "api"}' >"$d/result.json"
[ ! -e "$d/verify.json" ] && [ ! -e "$d/review.json" ] || fail "the done result passes with no phase verify.json or review.json"
passes result
passes T1
echo '{"passed": "yes"}' >"$d/verify.json"
echo '{"status": "done", "summary": "api again"}' >"$d/result.json"
passes result
[ "$(git rev-parse HEAD)" = "$start" ] || fail "no phase step puts a commit on main: $(git log --format=%s "$start"..HEAD)"
[ -z "$(git status --porcelain --untracked-files=all)" ] && [ ! -e .forge/phases ] || fail "phase steps leave the repo untouched: $(git status --porcelain --untracked-files=all)"
"$forge" commit --help >"$tmp/out" && grep -q "forge check" "$tmp/out" || fail "commit help documents the step gates"
ok commit-gates
fi

split() { mkdir -p "$S/features/$1" && echo "{\"phases\": [{\"slug\": \"$2\", \"goal\": \"x\", \"spec\": [], \"requirements\": [], \"depends\": []}]}" >"$S/features/$1/split.json"; }
if want alloc-slug; then
repo
split voice-export vexport
[ "$(code "$forge" alloc voice/export)" = 1 ] || fail "alloc must refuse a slug open in another track: $(cat "$tmp/out")"
grep -qF "crm/export" "$tmp/err" || fail "the refusal names the other track's feature: $(cat "$tmp/err")"
[ ! -e "$S/phases/05-vexport" ] || fail "a refused alloc creates nothing"
split voice-auth vauth
[ "$(code "$forge" alloc voice/auth)" = 0 ] || fail "an archived slug whose branch is gone is free: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = "$S/phases/05-vauth" ] || fail "alloc numbers past the state dir phases: $(cat "$tmp/out")"
rm -rf "$S/phases/05-vauth"
git branch forge/crm-auth && git checkout -q forge/crm-auth && git commit -q --allow-empty -m wip && git checkout -q main
[ "$(code "$forge" alloc voice/auth)" = 1 ] || fail "alloc must refuse a slug archived in the state dir in another track with an unmerged branch"
grep -qF "forge/crm-auth" "$tmp/err" || fail "the refusal names the unmerged branch: $(cat "$tmp/err")"
git merge -q --no-edit forge/crm-auth
[ "$(code "$forge" alloc voice/auth)" = 0 ] || fail "a merged branch frees the slug: $(cat "$tmp/err")"
ok alloc-slug
fi

if want paths; then
feature '["export-core"]'
p=$(pwd)
w=$p/.claude/worktrees/crm-export-05
cat >"$tmp/want" <<WANT
R=$p
F=$S/features/crm-export
P=$S/phases/05-export-core
STATE=$S
W=$w
B=forge/crm-export-05
BASE=forge/crm-export
G=$(git -C "$w" rev-parse --absolute-git-dir)
WANT
(cd "$tmp" && FORGE_ROOT=$p "$forge" paths 05) | diff -u "$tmp/want" - || fail "paths of a phase"
cat >"$tmp/want" <<WANT
R=$p
F=$S/features/crm-export
STATE=$S
W=$p/.claude/worktrees/crm-export
B=forge/crm-export
BASE=main
G=$(git -C "$p/.claude/worktrees/crm-export" rev-parse --absolute-git-dir)
WANT
"$forge" paths crm/export | diff -u "$tmp/want" - || fail "paths of a feature"
[ ! -e .forge/phases ] && [ ! -e .forge/features ] || fail "paths puts no record in the repo: $(ls -A .forge)"
[ "$("$forge" paths 06 | grep -c '^G=')" = 0 ] || fail "paths omits G while the worktree is missing"
[ "$(code "$forge" paths 99)" = 1 ] || fail "paths of an unknown phase must fail"
[ "$(code "$forge" paths bogus)" = 2 ] || fail "paths of a malformed argument must exit 2"
"$forge" --help >"$tmp/out" && grep -qE '^  paths ' "$tmp/out" || fail "forge --help lists paths"
ok paths
fi

if want phase-owner; then
feature
live='[{"id": "a1", "name": "p P05R1 crm/export", "state": "working"}]'
echo "$live" >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 8 ] || fail "resume with a live phase session exits 8: $(cat "$tmp/err")"
grep -qF "p P05R1 crm/export" "$tmp/err" || fail "the refusal names the live session: $(cat "$tmp/err")"
! grep -q -- ' --bg \| rm ' "$CLAUDE_LOG" || fail "a refused resume starts and removes nothing: $(cat "$CLAUDE_LOG")"
jq -cn '{time: "2026-09-27T00:00:00Z", step: "wait", message: "files overlap phase 06"}' >>$p5/events.jsonl
w=.claude/worktrees/crm-export-06
echo b >"$w/b.txt" && git -C "$w" add b.txt && git -C "$w" commit -q -m b
"$forge" test "$w" >/dev/null
echo '{"status": "done", "summary": "api"}' >"$S/phases/06-export-api/result.json"
"$forge" commit 06 result >/dev/null
: >"$CLAUDE_LOG"
[ "$(code "$forge" done 06)" = 8 ] || fail "done with a live sibling session merges and exits 8 for the skipped relaunch: $(cat "$tmp/err")"
! grep -q -- ' --bg \| rm ' "$CLAUDE_LOG" || fail "an automatic relaunch must not start or remove a phase with a live session: $(cat "$CLAUDE_LOG")"
grep -qF "p P05R1 crm/export" "$tmp/err" || fail "the skipped relaunch names the live session: $(cat "$tmp/err")"
[ "$(jq -sr 'map(.step) | .[rindex("wait") + 1:] | unique | join(",")' $p5/events.jsonl)" = refused ] || fail "a skipped relaunch logs no start"
echo '[{"id": "a2", "name": "p crm-export Phase 05 retry 1", "state": "working"}]' >"$CLAUDE_AGENTS"
: >"$CLAUDE_LOG"
[ "$(code "$forge" resume 05)" = 8 ] || fail "resume with a live legacy-named phase session exits 8: $(cat "$tmp/err")"
grep -qF "p crm-export Phase 05 retry 1" "$tmp/err" || fail "the refusal names the legacy-named session: $(cat "$tmp/err")"
[ "$(code "$forge" done 06)" = 8 ] || fail "a rerun done with a live legacy-named sibling session exits 8: $(cat "$tmp/err")"
! grep -q -- ' --bg \| rm ' "$CLAUDE_LOG" || fail "an automatic relaunch must not start or remove a phase with a live legacy-named session: $(cat "$CLAUDE_LOG")"
grep -qF "p crm-export Phase 05 retry 1" "$tmp/err" || fail "the skipped relaunch names the legacy-named session: $(cat "$tmp/err")"
[ "$(jq -sr 'map(.step) | .[rindex("wait") + 1:] | unique | join(",")' $p5/events.jsonl)" = refused ] || fail "a relaunch skipped for a legacy-named session logs no start"
echo '[]' >"$CLAUDE_AGENTS"
"$forge" resume 05 >/dev/null || fail "resume once the session ended"
ok phase-owner
fi

starts() { cat $p5/events.jsonl 2>/dev/null | jq -s 'map(select(.step == "start")) | length'; }
held=$XDG_STATE_HOME/forge/held.jsonl
holds() { [ ! -f "$held" ] || jq -r '"\(.kind) \(.target)"' "$held" | paste -sd, -; }
if want launch-failure; then
NOIMPL=1 feature
rm -f "$held" && : >"$NOTIFY_LOG"
[ "$(CLAUDE_BG_EXIT=1 code "$forge" implement crm/export)" = 8 ] || fail "implement exits 8 when claude --bg fails: $(cat "$tmp/out" "$tmp/err")"
[ "$(starts)" = 0 ] || fail "a failed claude --bg logs no start"
grep -qxF "forge: phase 05 not started: claude --bg exited 1" "$tmp/err" || fail "the failure is refused with the exit status: $(cat "$tmp/err")"
[ "$(holds)" = "phase 05,phase 06" ] || fail "the failed starts are held in held.jsonl: $(holds)"
[ "$(wc -l <"$NOTIFY_LOG")" = 2 ] || fail "each failed start notifies once: $(cat "$NOTIFY_LOG")"
NOIMPL=1 feature
mkdir -p .claude/worktrees && : >.claude/worktrees/crm-export
[ "$(code "$forge" implement crm/export)" != 0 ] || fail "implement must fail when the worktree cannot be created: $(cat "$tmp/out" "$tmp/err")"
[ "$(starts)" = 0 ] || fail "a failed worktree add logs no start"
! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a failed worktree add starts no session: $(cat "$CLAUDE_LOG")"
feature
echo '{"status": "blocked", "summary": "stuck"}' >"$p5/result.json"
rm -f "$held"
[ "$(CLAUDE_BG_EXIT=1 code "$forge" resume 05)" = 8 ] || fail "resume exits 8 when claude --bg fails: $(cat "$tmp/out" "$tmp/err")"
[ "$(starts)" = 1 ] || fail "a failed resume logs no start"
grep -qxF "forge: phase 05 not started: claude --bg exited 1" "$tmp/err" || fail "the failed resume is refused with the exit status: $(cat "$tmp/err")"
[ "$(holds)" = "phase 05" ] || fail "the failed resume is held in held.jsonl: $(holds)"
rm -f "$held"
ok launch-failure
fi

if want not-a-worktree; then
NOIMPL=1 feature
mkdir -p .claude/worktrees/crm-export
notwt="forge: $PWD/.claude/worktrees/crm-export is not a git worktree; move it aside and rerun"
[ "$(code "$forge" implement crm/export)" = 1 ] && grep -qxF "$notwt" "$tmp/err" || fail "implement must refuse a plain directory at the worktree path: $(cat "$tmp/out" "$tmp/err")"
[ "$(starts)" = 0 ] && ! grep -q -- ' --bg ' "$CLAUDE_LOG" || fail "a refused implement starts nothing: $(cat "$CLAUDE_LOG")"
[ "$(code "$forge" paths crm/export)" = 1 ] && grep -qxF "$notwt" "$tmp/err" || fail "paths must refuse a plain directory at the worktree path: $(cat "$tmp/out" "$tmp/err")"
feature
w=.claude/worktrees/crm-export-05
echo a >"$w/a.txt" && git -C "$w" add a.txt && git -C "$w" commit -q -m a
"$forge" test "$w" >/dev/null
echo '{"status": "done", "summary": "core"}' >"$p5/result.json"
git worktree remove .claude/worktrees/crm-export && mkdir .claude/worktrees/crm-export
head=$(git rev-parse main)
[ "$(code "$forge" done 05)" = 1 ] && grep -qxF "$notwt" "$tmp/err" || fail "done must refuse a plain directory at the feature worktree path: $(cat "$tmp/out" "$tmp/err")"
[ "$(git rev-parse main)" = "$head" ] && ! git merge-base --is-ancestor forge/crm-export-05 main || fail "a refused done merges nothing into main"
ok not-a-worktree
fi

if want missing-worktree; then
feature
echo '{"status": "blocked", "summary": "stuck"}' >"$p5/result.json"
rm -rf .claude/worktrees/crm-export-05
[ "$(code "$forge" resume 05)" = 0 ] || fail "resume must recreate a registered but missing worktree: $(cat "$tmp/out" "$tmp/err")"
[ "$(git -C .claude/worktrees/crm-export-05 branch --show-current)" = forge/crm-export-05 ] || fail "the recreated worktree is on its phase branch"
ok missing-worktree
fi

if want lock-resume-nogit; then
feature
echo '{"status": "blocked", "summary": "stuck"}' >"$p5/result.json"
flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" sleep 2 & a=$!
sleep 0.5
[ "$(code "$forge" resume 05)" = 0 ] || fail "resume after the lock frees: $(cat "$tmp/err")"
wait $a
grep -q '^forge: waiting for forge.lock' "$tmp/err" || fail "resume waits on forge.lock: $(cat "$tmp/err")"
rm -rf "$tmp/nogit" && project "$tmp/nogit" && cd "$tmp/nogit"
ns=$XDG_STATE_HOME/forge/nogit
jq '.phases |= map(del(.number))' "$ns/features/crm-routing/split.json" >"$tmp/s" && mv "$tmp/s" "$ns/features/crm-routing/split.json"
flock .forge/forge.lock sleep 2 & a=$!
sleep 0.5
out=$("$forge" alloc crm/routing 2>"$tmp/err")
wait $a
grep -q '^forge: waiting for forge.lock' "$tmp/err" || fail "outside git, alloc locks .forge/forge.lock: $(cat "$tmp/err")"
[ "$out" = "$(printf '%s\n' "$ns/phases/05-routing-rules" "$ns/phases/06-routing-ui")" ] && [ ! -e .forge/phases ] || fail "outside git, alloc writes the phases in the state dir: $out"
ok lock-resume-nogit
fi

[ -z "$only" ] || fail "no case $only"
