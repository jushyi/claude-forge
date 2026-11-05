#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/tests/fixtures/forge-init
init=$root/bin/forge-init
[ -z "${1:-}" ] || { echo "forge-init.test.sh: no case $1" >&2; exit 1; }
export FORGE_TEMPLATES=$root/templates LC_ALL=C PATH=$root/bin:$PATH
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state HOME=$tmp/home
unset FORGE_ROOT
mkdir "$HOME"

dump() {
  find . -name .git -prune -o -print | sort
  find . -name .git -prune -o \( -name forge.md -o -name .gitignore \) -print | sort | while read -r f; do
    echo "== $f"
    cat "$f"
  done
}
check() { diff -u "$fx/$1" - && echo "forge-init $1: ok"; }
run() { local s=0; "$init" "$@" >"$tmp/out" 2>&1 || s=$?; echo "exit $s"; cat "$tmp/out"; }

mkdir "$tmp/single" && cd "$tmp/single"
git init -q && mkdir vault && touch main.sh PRODUCT.md DESIGN.md vault/Index.md
"$init" app "An app."
dump | check single.txt
[ ! -e .forge/STATE.md ] || { echo "forge-init: STATE.md is rendered" >&2; exit 1; }
printf '# Seeds\n\n%s\n\n- \n' "<!-- one idea per line, today's date first: - YYYY-MM-DD <text>; undated - <text> lines stay valid -->" | diff -u - .forge/seeds.md || { echo "forge-init: seeds.md is not the seeds template" >&2; exit 1; }

mkdir "$tmp/ws" && cd "$tmp/ws"
git init -q api && git init -q web && touch web/PRODUCT.md web/DESIGN.md && printf web/ > .gitignore
mkdir vault api/vault web/vault && touch vault/Index.md web/vault/Index.md
"$init" ws "A workspace." api="The API." web="The web app."
[ "$(git rev-parse --show-toplevel)" = "$PWD" ] || { echo "forge-init: workspace root is not a git repo" >&2; exit 1; }
dump | check workspace.txt

git init -q cli && echo kept >> .forge/PROJECT.md
printf '# Seeds\n\n- 2026-10-19 custom idea\n' > .forge/seeds.md && cp .forge/seeds.md "$tmp/seeds.md"
touch api/PRODUCT.md api/DESIGN.md api/vault/Index.md && rm web/DESIGN.md web/vault/Index.md
"$init" ws "A workspace." cli="The CLI."
[ "$(tail -n1 .forge/PROJECT.md)" = kept ] || { echo "forge-init: rerun overwrote PROJECT.md" >&2; exit 1; }
cmp -s .forge/seeds.md "$tmp/seeds.md" || { echo "forge-init: rerun overwrote seeds.md" >&2; exit 1; }
dump | check rerun.txt

git init -q lib
{
  run ws "A workspace."
  run ws "A workspace." nope=x lib="The lib."
  run ws "A workspace." lib="The lib."
  [ -e lib/.forge ] && echo "lib added"
  run
  run --bogus
  run ws
  run --help
} | check errors.txt

{
  mkdir "$tmp/hand" && cd "$tmp/hand" && git init -q && echo "# hand-written" > CLAUDE.md
  sum=$(cksum <CLAUDE.md)
  run hand "Hand."
  [ "$(cksum <CLAUDE.md)" = "$sum" ] && echo "root CLAUDE.md byte-identical"
  [ -f .claude/rules/forge.md ] && echo "router in .claude/rules/forge.md"
  ls -A
  mkdir "$tmp/handws" && cd "$tmp/handws" && git init -q api && echo "# mine" > api/CLAUDE.md && echo "# root" > CLAUDE.md
  run ws "A workspace." api="The API."
  [ "$(cat api/CLAUDE.md)/$(cat CLAUDE.md)" = "# mine/# root" ] && echo "workspace CLAUDE.md files kept"
  [ -f api/.claude/rules/forge.md ] && echo "child router written"
  run ws "A workspace."
  sed -n 3p api/.claude/rules/forge.md
  mkdir "$tmp/ign" && cd "$tmp/ign" && git init -q && echo .claude/ > .gitignore
  run ign "Ignored."
  [ ! -e CLAUDE.md ] && echo "no CLAUDE.md created"
  cd "$tmp/single" && cp .claude/rules/forge.md "$tmp/single.md" && mkdir "$tmp/none"
  FORGE_TEMPLATES=$tmp/none run app "An app."
  cmp -s .claude/rules/forge.md "$tmp/single.md" && echo "router kept"
  ls .claude/rules/forge.md*
} 2>&1 | sed "s|$tmp|<tmp>|g" | check root.txt
