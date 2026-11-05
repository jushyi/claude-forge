#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"

fail() { echo "forge-quick-log: FAIL $*" >&2; exit 1; }
ok() { echo "forge-quick-log $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
code() { local s=0; "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
st=$XDG_STATE_HOME/forge/p
q=$st/quicks.json
repo() {
  rm -rf "$tmp/p" && project "$tmp/p" && cd "$tmp/p"
  rm -f "$q"
  git init -q -b main
  git config user.name forge && git config user.email forge@example.com
  git add -A && git commit -q -m init
}
recorded() {
  [ "$(cat "$tmp/out")" = "forge: recorded quick $1" ] || fail "quick-log prints the recorded line for $1: $(cat "$tmp/out")"
  [ ! -e "$q.new" ] || fail "quick-log leaves no $q.new"
  [ ! -e .forge/quicks.json ] || fail "quick-log writes no .forge/quicks.json in the repo: $(cat .forge/quicks.json)"
}
today=$(date +%F)
refused() {
  local what=$1 head before
  shift
  head=$(git rev-parse HEAD)
  before=$(cat "$q" 2>/dev/null || echo absent)
  [ "$(code "$forge" quick-log "$@")" != 0 ] || fail "$what must be refused: $(cat "$tmp/out" "$tmp/err")"
  [ -s "$tmp/err" ] || fail "$what prints a message on stderr"
  [ "$(cat "$q" 2>/dev/null || echo absent)" = "$before" ] || fail "$what writes nothing: $(cat "$q" 2>/dev/null)"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "$what commits nothing: $(git log --format=%s -1)"
}
seed() {
  repo
  [ "$(code "$forge" quick-log fix-login "Fix the login redirect" forge)" = 0 ] || fail "seeding fix-login: $(cat "$tmp/out" "$tmp/err")"
  [ "${1:-1}" != 2 ] || [ "$(code "$forge" quick-log add-export "Add CSV export" forge ACME)" = 0 ] || fail "seeding add-export: $(cat "$tmp/out" "$tmp/err")"
}

if want first; then
  repo
  [ ! -e "$q" ] || fail "the fixture holds no quicks.json"
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" quick-log fix-login "Fix the login redirect" forge)" = 0 ] || fail "the first entry on a missing file: $(cat "$tmp/out" "$tmp/err")"
  [ -f "$q" ] || fail "the first entry goes to the state dir's quicks.json $q: $(ls -A "$st" .forge)"
  [ "$(jq -cS . "$q")" = "$(jq -cnS --arg d "$today" '{quicks: [{slug: "fix-login", task: "Fix the login redirect", repos: ["forge"], date: $d}]}')" ] || fail "the first entry: $(cat "$q")"
  recorded fix-login
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "quick-log commits nothing: $(git log --format=%s -1)"
  [ -z "$(git status --porcelain)" ] || fail "quick-log leaves the repo untouched: $(git status --porcelain)"
  ok first
fi

if want append; then
  seed
  echo "- unrelated edit" >>.forge/todo.md
  git add .forge/todo.md
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" quick-log add-export "Add CSV export" forge ACME)" = 0 ] || fail "the second entry: $(cat "$tmp/out" "$tmp/err")"
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["fix-login","add-export"]' ] || fail "entries keep append order: $(cat "$q")"
  [ "$(jq -cS '.quicks[1]' "$q")" = "$(jq -cnS --arg d "$today" '{slug: "add-export", task: "Add CSV export", repos: ["forge", "ACME"], date: $d}')" ] || fail "the appended entry: $(cat "$q")"
  recorded add-export
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "the append commits nothing: $(git log --format=%s -1)"
  [ "$(git status --porcelain | paste -sd,)" = "M  .forge/todo.md" ] || fail "staged changes stay as they were: $(git status --porcelain)"
  git reset -q && git checkout -q -- .forge/todo.md
  ok append
fi

if want duplicate; then
  seed
  refused "a duplicate slug" fix-login "Another task" forge
  ok duplicate
fi

if want invalid; then
  seed 2
  refused "an empty task" new-thing "" forge
  refused "no repos" new-thing "A task"
  refused "a non-kebab slug" Fix_Login "A task" forge
  refused "duplicate repos" new-thing "A task" forge forge
  refused "no arguments"
  [ "$(jq '.quicks | length' "$q")" = 2 ] || fail "refusals leave the two entries: $(cat "$q")"
  repo
  refused "an empty task on a missing file" new-thing "" forge
  refused "duplicate repos on a missing file" new-thing "A task" ACME ACME
  [ ! -e "$q" ] || fail "a refusal on a missing file creates no file"
  ok invalid
fi

if want lock; then
  repo
  gcd=$(git rev-parse --path-format=absolute --git-common-dir)
  flock "$gcd/forge.lock" sleep 2 & a=$!
  sleep 0.5
  [ "$(code "$forge" quick-log locked-one "Wait for the lock" forge)" = 0 ] || fail "a waiting quick-log must succeed: $(cat "$tmp/err")"
  wait $a
  grep -q '^forge: waiting for forge.lock' "$tmp/err" || fail "quick-log waits on the repo forge.lock: $(cat "$tmp/err")"
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["locked-one"]' ] || fail "the entry after the wait: $(cat "$q")"
  [ "$(cat "$tmp/out")" = "forge: recorded quick locked-one" ] || fail "the recorded line after the wait: $(cat "$tmp/out")"
  ok lock
fi

if want no-commit; then
  seed
  head=$(git rev-parse HEAD)
  printf '#!/bin/sh\nexit 1\n' >.git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
  [ "$(code "$forge" quick-log hooked "Never commits" forge)" = 0 ] || fail "quick-log runs no git commit, so a failing pre-commit hook does not stop it: $(cat "$tmp/out" "$tmp/err")"
  recorded hooked
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["fix-login","hooked"]' ] || fail "the entry is recorded: $(cat "$q")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "quick-log commits nothing: $(git log --format=%s -1)"
  rm .git/hooks/pre-commit
  ok no-commit
fi

gitrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}
merged() {
  local r=$1 d="$2 12:00:00" s=$3 b=${4:-main}
  git -C "$r" checkout -q -b side "$b"
  echo "$s" >>"$r/work.txt"
  git -C "$r" add work.txt && git -C "$r" commit -q -m "work for $s"
  git -C "$r" checkout -q "$b"
  GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git -C "$r" merge -q --no-ff -m "$s" side
  git -C "$r" branch -q -D side
  git -C "$r" checkout -q main
}
refs() { local r; for r in "$@"; do git -C "$r" symbolic-ref HEAD; git -C "$r" for-each-ref --format='%(refname) %(objectname)'; done; }
mkdir -p "$tmp/qbin"
cat >"$tmp/qbin/gh" <<'EOF'
#!/usr/bin/env bash
b=$(basename "$(git rev-parse --show-toplevel)")
printf '%s %s\n' "$b" "$*" >>"$GH_QLOG"
if [ -f "${GH_QRACE:-}" ]; then bash "$GH_QRACE" >&2 || exit 3; rm -f "$GH_QRACE"; fi
[ -z "${GH_QFAIL:-}" ] || { echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1; }
[ "${1:-} ${2:-}" = "pr view" ] || { echo "gh stub: unexpected gh $*" >&2; exit 2; }
n= q= prev=
for a in "${@:3}"; do
  case $prev in --jq | -q) q=$a ;; esac
  case $a in --jq=* | -q=*) q=${a#*=} ;; [0-9]*) [ -n "$n" ] || n=$a ;; esac
  prev=$a
done
v=$(jq -cn --arg t "Task $b #$n" '{title: $t}')
if [ -n "$q" ]; then jq -r "$q" <<<"$v"; else printf '%s\n' "$v"; fi
EOF
chmod +x "$tmp/qbin/gh"
export GH_QLOG=$tmp/gh.log PATH=$tmp/qbin:$PATH

if want import; then
  repo
  gitrepo app
  gitrepo "$tmp/linked"
  printf '{"repos": ["../linked"]}\n' >.forge/repos.json
  git add .forge/repos.json && git commit -q -m "chore: link repo"
  [ "$(code "$forge" quick-log zeta "Zeta task" p)" = 0 ] || fail "seeding zeta: $(cat "$tmp/out" "$tmp/err")"
  merged . 2026-03-05 "Merge pull request #6 from octo/forge/quick-zeta"
  merged app 2026-03-08 "Merge pull request #4 from octo/forge/quick-gamma"
  merged app 2026-03-09 "Merge branch 'forge/quick-beta'"
  merged app 2026-03-10 "Merge pull request #3 from octo/forge/quick-alpha"
  merged app 2026-03-11 "Merge pull request #2 from octo/forge/roadmap-thing-12"
  merged . 2026-03-12 "Merge pull request #5 from octo/forge/quick-alpha"
  git -C app branch -q other main
  merged app 2026-03-13 "Merge pull request #12 from octo/forge/quick-theta" other
  merged "$tmp/linked" 2026-03-14 "Merge pull request #9 from octo/forge/quick-delta"
  merged app 2026-03-15 "Merge pull request #17 from octo/forge/quick-gamma"
  merged . 2026-03-16 "Merge pull request #18 from octo/forge/quick-alpha"
  merged app 2026-03-17 "Merge pull request #19 from octo/forge/quick-gamma-2"
  merged "$tmp/linked" 2026-03-20 "Merge pull request #10 from octo/forge/quick-epsilon"
  merged . 2026-03-21 "Merge pull request #11 from octo/forge/quick-epsilon"
  merged app 2026-03-21 "Merge pull request #15 from octo/forge/quick-Fix_Login"
  merged . 2026-03-21 "Merge pull request #16 from octo/forge/quick-a/b"
  seeded=$(cat "$q")
  head=$(git rev-parse HEAD)
  subrefs=$(refs app "$tmp/linked")

  export GH_QFAIL=1
  s=$(code "$forge" quick-log --import)
  unset GH_QFAIL
  [ "$s" != 0 ] || fail "an import whose gh fails must fail: $(cat "$tmp/out" "$tmp/err")"
  grep -q "Bad credentials" "$tmp/err" || fail "a gh failure prints gh's message: $(cat "$tmp/err")"
  [ "$(cat "$q")" = "$seeded" ] || fail "a gh failure writes nothing: $(cat "$q")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a gh failure commits nothing: $(git log --format=%s -1)"

  : >"$GH_QLOG"
  [ "$(code "$forge" quick-log --import)" = 0 ] || fail "the import: $(cat "$tmp/out" "$tmp/err")"
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["zeta","gamma","alpha","gamma-3","alpha-2","gamma-2","epsilon"]' ] || fail "the import appends new PR-merged quicks of main in date order, naming a slug merged again in a repo -2, -3 past merged slugs and skipping logged, Merge branch, non-quick, non-kebab, off-main and linked-only slugs: $(cat "$q")"
  [ "$(jq -cS '.quicks[0]' "$q")" = "$(jq -cS '.quicks[0]' <<<"$seeded")" ] || fail "the logged entry stays as it was: $(cat "$q")"
  want=$(jq -cnS '[
    {slug: "gamma", task: "Task app #4", repos: ["app"], date: "2026-03-08"},
    {slug: "alpha", task: "Task app #3", repos: ["app", "p"], date: "2026-03-10"},
    {slug: "gamma-3", task: "Task app #17", repos: ["app"], date: "2026-03-15"},
    {slug: "alpha-2", task: "Task p #18", repos: ["p"], date: "2026-03-16"},
    {slug: "gamma-2", task: "Task app #19", repos: ["app"], date: "2026-03-17"},
    {slug: "epsilon", task: "Task linked #10", repos: ["linked", "p"], date: "2026-03-20"}]')
  [ "$(jq -cS '.quicks[1:] | map(.repos |= sort)' "$q")" = "$want" ] || fail "imported entries take the earliest merge's PR title and date and every merging repo: $(cat "$q")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "the import commits nothing: $(git log --format=%s -3)"
  [ -z "$(git status --porcelain -- . ':!app')" ] || fail "the import leaves the repo untouched: $(git status --porcelain)"
  [ ! -e "$q.new" ] || fail "the import leaves no $q.new"
  [ "$(git symbolic-ref HEAD)" = refs/heads/main ] || fail "the import leaves the root on main"
  [ "$(refs app "$tmp/linked")" = "$subrefs" ] || fail "the import moves no branch: $(refs app "$tmp/linked")"

  imported=$(cat "$q")
  head=$(git rev-parse HEAD)
  [ "$(code "$forge" quick-log --import)" = 0 ] || fail "a second import exits 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$q")" = "$imported" ] || fail "a second import adds nothing: $(cat "$q")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a second import commits nothing: $(git log --format=%s -1)"

  merged app 2026-03-22 "Merge pull request #13 from octo/forge/quick-eta"
  merged . 2026-03-23 "Merge pull request #14 from octo/forge/quick-iota"
  head=$(git rev-parse HEAD)
  printf 'cd %q && %q quick-log eta "Eta raced" p\n' "$tmp/p" "$forge" >"$tmp/race.sh"
  [ "$(GH_QRACE=$tmp/race.sh code "$forge" quick-log --import)" = 0 ] || fail "an import racing a log of one of its slugs: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$tmp/race.sh" ] || fail "the racing log ran during the import"
  [ "$(jq -c '.quicks[-2:] | map([.slug, .task])' "$q")" = '[["eta","Eta raced"],["iota","Task p #14"]]' ] || fail "an import skips a slug logged while it ran and still adds the rest: $(cat "$q")"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "the raced log and the import commit nothing: $(git log --format=%s -3)"

  "$forge" quick-log --help | grep -q -- --import || fail "the quick-log help documents --import"
  "$forge" --help | grep -q -- 'quick-log.*--import' || fail "the forge help lists quick-log --import"
  "$forge" quick-log --help | grep -qE '(STATE|S)/quicks\.json' || fail "the quick-log help names the state dir's quicks.json: $("$forge" quick-log --help)"
  ! "$forge" quick-log --help | grep -qF .forge/quicks.json || fail "the quick-log help names no .forge/quicks.json: $("$forge" quick-log --help | grep -F .forge/quicks.json)"
  ! "$forge" --help | grep -qF .forge/quicks.json || fail "the forge help names no .forge/quicks.json: $("$forge" --help | grep -F .forge/quicks.json)"
  ok import
fi

if want no-schema; then
  repo
  mkdir -p "$tmp/noschemas"
  [ "$(FORGE_SCHEMAS=$tmp/noschemas code "$forge" quick-log fix-login "Fix the login redirect" forge)" = 0 ] || fail "quick-log reads no schema: $(cat "$tmp/out" "$tmp/err")"
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["fix-login"]' ] || fail "quick-log with no schemas writes its entry: $(cat "$q")"
  recorded fix-login
  merged . 2026-03-05 "Merge pull request #7 from octo/forge/quick-kappa"
  [ "$(FORGE_SCHEMAS=$tmp/noschemas code "$forge" quick-log --import)" = 0 ] || fail "quick-log --import reads no schema: $(cat "$tmp/out" "$tmp/err")"
  [ "$(jq -c '[.quicks[].slug]' "$q")" = '["fix-login","kappa"]' ] || fail "quick-log --import with no schemas writes its entry: $(cat "$q")"
  [ -z "$(git status --porcelain)" ] || fail "quick-log --import leaves the repo untouched: $(git status --porcelain)"
  ok no-schema
fi

if want unparsable; then
  repo
  printf '{"quicks": [\n' >"$q"
  refused "an unparsable quicks.json" new-fix "A forge quick" forge
  grep -qF "$q" "$tmp/err" || fail "the refusal names $q: $(cat "$tmp/err")"
  merged . 2026-03-05 "Merge pull request #7 from octo/forge/quick-kappa"
  refused "an import onto an unparsable quicks.json" --import
  grep -qF "$q" "$tmp/err" || fail "the import refusal names $q: $(cat "$tmp/err")"
  [ "$(cat "$q")" = '{"quicks": [' ] || fail "$q stays as it was: $(cat "$q")"
  ok unparsable
fi

if want gsd; then
repo
gsd='{"slug": "old-fix", "task": "An old GSD quick", "repos": ["forge"], "date": "2025-11-02", "source": "gsd"}'
printf '{"quicks": [%s]}\n' "$gsd" >"$q"
[ "$(code "$forge" quick-log new-fix "A forge quick" forge)" = 0 ] || fail "quick-log appends to a file holding a gsd entry: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -c '[.quicks[].slug]' "$q")" = '["old-fix","new-fix"]' ] || fail "quick-log appends after the gsd entry: $(cat "$q")"
[ "$(jq -cS '.quicks[0]' "$q")" = "$(jq -cS . <<<"$gsd")" ] || fail "quick-log leaves the gsd entry unchanged: $(cat "$q")"
[ "$(jq -cS '.quicks[1]' "$q")" = "$(jq -cnS --arg d "$today" '{slug: "new-fix", task: "A forge quick", repos: ["forge"], date: $d}')" ] || fail "quick-log writes its entry without source: $(cat "$q")"
merged . 2026-03-05 "Merge pull request #7 from octo/forge/quick-kappa"
[ "$(code "$forge" quick-log --import)" = 0 ] || fail "--import appends to a file holding a gsd entry: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -c '[.quicks[].slug]' "$q")" = '["old-fix","new-fix","kappa"]' ] || fail "--import appends after the gsd entry: $(cat "$q")"
[ "$(jq -cS '.quicks[0]' "$q")" = "$(jq -cS . <<<"$gsd")" ] || fail "--import leaves the gsd entry unchanged: $(cat "$q")"
[ "$(jq -cS '.quicks[2]' "$q")" = "$(jq -cnS '{slug: "kappa", task: "Task p #7", repos: ["p"], date: "2026-03-05"}')" ] || fail "--import writes its entry without source: $(cat "$q")"
[ -z "$(git status --porcelain)" ] || fail "--import leaves the repo untouched: $(git status --porcelain)"
ok gsd
fi

finish
