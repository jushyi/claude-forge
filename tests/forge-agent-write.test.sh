#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/forge-agent-write.sh
export PATH=$root/bin:$PATH FORGE_SCHEMAS=$root/schemas LC_ALL=C
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state
sb=$XDG_STATE_HOME/forge

fail() { echo "forge-agent-write: FAIL $*" >&2; exit 1; }
only=${1:-}
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
ok() { echo "forge-agent-write $1: ok"; [ "$1" != "$only" ] || exit 0; }
run() { local s=0; jq -n --arg p "$2" '{tool_name: "Write", tool_input: {file_path: $p}}' | "$hook" "$1" >"$tmp/out" 2>&1 || s=$?; echo $s; }
runj() { local s=0; "$hook" "$1" <<<"$2" >"$tmp/out" 2>&1 || s=$?; echo $s; }
nb() { jq -nc --arg d "$1" --arg p "$2" '{tool_name: "NotebookEdit", cwd: $d, tool_input: {notebook_path: $p}}'; }
wr() { jq -nc --arg d "$1" --arg p "$2" '{tool_name: "Write", cwd: $d, tool_input: {file_path: $p}}'; }

p=$tmp/proj/.forge/phases/07-x
mkdir -p "$p" "$tmp/proj/src"

if want pre; then
[ "$(run pre "$p/scout.json")" = 0 ] || fail "pre must allow .forge/"
[ "$(run pre "$tmp/proj/src/a.ts")" = 2 ] || fail "pre must deny a path outside .forge/"
grep -q "$tmp/proj/src/a.ts" "$tmp/out" || fail "denial must name the path"
[ "$(run pre "$tmp/proj/.forged/a.json")" = 2 ] || fail "pre must deny a lookalike directory"
[ "$(run pre "$tmp/proj/.forge/../src/a.ts")" = 2 ] || fail "pre must deny a path that climbs out of .forge/"
mkdir -p "$tmp/repo/.git" "$tmp/repo/docs" "$tmp/wt/docs"
echo "gitdir: $tmp/repo/.git/worktrees/wt" >"$tmp/wt/.git"
for r in "$tmp/repo" "$tmp/wt"; do
  for f in PRODUCT.md DESIGN.md; do
    [ "$(run pre "$r/$f")" = 0 ] || fail "pre must allow $f at root $r: $(cat "$tmp/out")"
    [ "$(run pre "$r/docs/$f")" = 2 ] || fail "pre must deny $f in a subdirectory of $r"
  done
  for f in CLAUDE.md README.md; do
    [ "$(run pre "$r/$f")" = 2 ] || fail "pre must deny $f at root $r"
  done
done
[ "$(run pre "$tmp/proj/PRODUCT.md")" = 2 ] || fail "pre must deny PRODUCT.md in a directory without .git"
g=$tmp/g
git init -q -b main "$g"
git -C "$g" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$g" worktree add -q -b w "$g/.claude/worktrees/w-1"
[ "$(run pre "$g/.claude/worktrees/w-1/.forge/phases/07-x/scout.json")" = 2 ] || fail "pre must deny old-path planning JSON in a linked worktree"
grep -qF "$sb/g/phases/07-x/scout.json" "$tmp/out" || fail "pre must name the state-dir path: $(cat "$tmp/out")"
[ "$(run pre "$g/.claude/worktrees/w-1/tests/fixtures/p/.forge/phases/07-x/scout.json")" = 0 ] || fail "pre must allow a nested fixture .forge in a linked worktree: $(cat "$tmp/out")"
[ "$(run pre "$g/.forge/phases/07-x/scout.json")" = 2 ] || fail "pre must deny old-path planning JSON in the main worktree"
grep -qF "$sb/g/phases/07-x/scout.json" "$tmp/out" || fail "pre must name the state-dir path for the main worktree: $(cat "$tmp/out")"
[ "$(runj pre "$(nb "$tmp" "$tmp/proj/src/a.ipynb")")" = 2 ] || fail "pre must deny a notebook outside .forge/: $(cat "$tmp/out")"
grep -q "$tmp/proj/src/a.ipynb" "$tmp/out" || fail "notebook denial must name the path: $(cat "$tmp/out")"
[ "$(runj pre "$(nb "$tmp" "$p/a.ipynb")")" = 0 ] || fail "pre must allow a notebook under .forge/: $(cat "$tmp/out")"
[ "$(runj pre "$(wr "$tmp/proj" .forge/phases/07-x/scout.json)")" = 0 ] || fail "pre must resolve a relative path against the input cwd: $(cat "$tmp/out")"
[ "$(runj pre "$(wr "$tmp/proj/.forge" ../src/a.ts)")" = 2 ] || fail "pre must deny a relative path outside .forge/ from the input cwd"
[ "$(runj pre '{"tool_name": "Write", "tool_input": {}}')" = 2 ] || fail "pre must deny a write with no path: $(cat "$tmp/out")"
[ "$(runj pre 'not json')" = 2 ] || fail "pre must deny on an internal error: $(cat "$tmp/out")"
grep -q '^forge-agent-write: internal error (exit [0-9]*); denied$' "$tmp/out" || fail "internal error must leave a denial note: $(cat "$tmp/out")"
[ "$(runj pre "$(wr "$tmp/none" a.json)")" = 2 ] || fail "pre must deny when the input cwd is missing: $(cat "$tmp/out")"
ok pre
fi

if want state; then
sd=$sb/proj
mkdir -p "$sd/phases/07-x" "$sd/features/thin-x/research"
for f in "$sd/phases/07-x/scout.json" "$sd/features/thin-x/research/a.json" "$sd/phases/07-x/tests/T1.json"; do
  [ "$(run pre "$f")" = 0 ] || fail "pre must allow $f under the state dir: $(cat "$tmp/out")"
done
for f in "$sd/root" "$sd/quicks.json" "$sd/debugs.json" "$sd/history.json" "$sd/archive/thin-x/docs.json" "$sb/port.json" "$sd/phases/../quicks.json" "$sd/notes.json"; do
  [ "$(run pre "$f")" = 2 ] || fail "pre must deny $f"
  grep -qF "writes only under .forge/ or the forge state dir" "$tmp/out" || fail "denial of $f must name both allowed places: $(cat "$tmp/out")"
done
echo '{"files": [{"path": "a.ts", "symbols": [], "why": "entry"}]}' >"$sd/phases/07-x/scout.json"
[ "$(run post "$sd/phases/07-x/scout.json")" = 0 ] || fail "post must pass valid JSON under the state dir: $(cat "$tmp/out")"
echo '{"files": [' >"$sd/phases/07-x/scout.json"
[ "$(run post "$sd/phases/07-x/scout.json")" = 2 ] || fail "post must block unparsable JSON under the state dir"
grep -q "scout.json" "$tmp/out" || fail "post must return the validate failure for a state-dir file: $(cat "$tmp/out")"
echo '{' >"$sd/features/thin-x/research/a.json"
[ "$(run post "$sd/features/thin-x/research/a.json")" = 2 ] || fail "post must block unparsable JSON in a state-dir feature"
echo '{' >"$sb/port.json"
[ "$(run post "$sb/port.json")" = 0 ] || fail "post must skip JSON directly in the forge state dir: $(cat "$tmp/out")"
ok state
fi

if want post; then
echo '{"files": [{"path": "a.ts", "symbols": [], "why": "entry"}]}' >"$p/scout.json"
[ "$(run post "$p/scout.json")" = 0 ] || fail "post must pass valid JSON: $(cat "$tmp/out")"
echo '{"files": [{"path": "a.ts"}]}' >"$p/scout.json"
[ "$(run post "$p/scout.json")" = 0 ] || fail "post must pass a parsable scout.json now that it is only parse-checked: $(cat "$tmp/out")"
echo '{"files": [' >"$p/scout.json"
[ "$(run post "$p/scout.json")" = 2 ] || fail "post must block an unparsable scout.json"
grep -q "scout.json" "$tmp/out" || fail "post must return the validate failure: $(cat "$tmp/out")"
echo '{}' >"$p/unknown.json"
[ "$(run post "$p/unknown.json")" = 0 ] || fail "post must pass parsable JSON with no schema: $(cat "$tmp/out")"
echo '{' >"$p/unknown.json"
[ "$(run post "$p/unknown.json")" = 2 ] || fail "post must block unparsable JSON with no schema"
grep -q "unknown.json" "$tmp/out" || fail "post must return the parse failure: $(cat "$tmp/out")"
echo '# notes' >"$tmp/proj/.forge/STACK.md"
[ "$(run post "$tmp/proj/.forge/STACK.md")" = 0 ] || fail "post must skip Markdown"
echo '{' >"$tmp/proj/src/a.json"
[ "$(run post "$tmp/proj/src/a.json")" = 0 ] || fail "post must skip JSON outside .forge/"
s=$tmp/proj/.forge/debug/x
mkdir -p "$p/tests" "$s/tests"
for f in "$p/tests/T1.json" "$s/tests/T1.json"; do
  jq -nc '{task: "T1", files: ["tests/a.test.sh"], command: "forge test --one a", failure: "forge test: gave up waiting for test memory", exit: 75}' >"$f"
  [ "$(run post "$f")" = 0 ] || fail "post must allow a test record holding exit 75 at $f: $(cat "$tmp/out")"
done
ok post
fi

if want mode; then
[ "$(run bogus "$p/scout.json")" = 1 ] || fail "unknown mode must exit 1"
ok mode
fi

[ -z "$only" ] || fail "no case $only"
