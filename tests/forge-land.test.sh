#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
forge=$root/bin/forge
export FORGE_TEMPLATES=$root/templates FORGE_SCHEMAS=$root/schemas LC_ALL=C GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=forge GIT_AUTHOR_EMAIL=forge@example.com GIT_COMMITTER_NAME=forge GIT_COMMITTER_EMAIL=forge@example.com
unset FORGE_ROOT FORGE_TEST_SLOTS FORGE_TEST_SLOT_HELD FORGE_TEST_SLOT_WAIT FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_NOW
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export HOME=$tmp/home XDG_RUNTIME_DIR=$tmp/run XDG_STATE_HOME=$tmp/state
export FORGE_PROC_ROOT=$tmp/proc FORGE_SYS_ROOT=$tmp/sys
mkdir -p "$FORGE_PROC_ROOT" "$FORGE_SYS_ROOT" && printf 'MemTotal: 33554432 kB\nMemAvailable: 16777216 kB\n' >"$FORGE_PROC_ROOT/meminfo"
mkdir -p "$HOME" "$tmp/bin"

only=${1:-}
fail() { echo "forge-land: FAIL $*" >&2; exit 1; }
ok() { echo "forge-land $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() { local c; [ -n "$only" ] || return 0; for c; do [ "$only" != "$c" ] || return 0; done; return 1; }

cat >"$tmp/bin/landtest" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "$LAND_LOG" 2>/dev/null | wc -l) + 1))
echo "$1 $(git -C "$1" rev-parse HEAD)" >>"$LAND_LOG"
[ -z "${LAND_HOOK:-}" ] || "$LAND_HOOK" "$n"
exit "${LAND_EXIT:-0}"
EOF
cat >"$tmp/bin/disjoint" <<'EOF'
#!/usr/bin/env bash
[ "$1" = 1 ] || exit 0
f=${LAND_FILE:-other.txt}
mkdir -p "$(dirname "$LAND_R/$f")"
echo o >"$LAND_R/$f"
git -C "$LAND_R" add "$f"
git -C "$LAND_R" commit -q -m other -- "$f"
EOF
cat >"$tmp/bin/overlap" <<'EOF'
#!/usr/bin/env bash
[ -n "${LAND_ALWAYS:-}" ] || [ "$1" = 1 ] || exit 0
sed -i "s/^6.*/6main$1-$$/" "$LAND_R/ov.txt"
git -C "$LAND_R" commit -q -m "ov $1" -- ov.txt
EOF
cat >"$tmp/bin/slowland" <<'EOF'
#!/usr/bin/env bash
a=$(git -C "$1" rev-parse HEAD)
touch "$LAND_LOG.started"
sleep 2
echo "$a $(git -C "$1" rev-parse HEAD)" >>"$LAND_LOG"
EOF
cat >"$tmp/bin/late" <<'EOF'
#!/usr/bin/env bash
[ "$1" = 1 ] || exit 0
c=$(git -C "$LAND_R" commit-tree "late^{tree}" -p late -m late) && git -C "$LAND_R" update-ref refs/heads/late "$c"
LAND_FILE=.forge/late.json "$(dirname "$0")/disjoint" 1
EOF
chmod +x "$tmp/bin/landtest" "$tmp/bin/disjoint" "$tmp/bin/overlap" "$tmp/bin/slowland" "$tmp/bin/late"
export FORGE_LAND_TEST=$tmp/bin/landtest LAND_LOG=$tmp/land.log

ld() { local s=0; rm -f "$LAND_LOG"; "$forge" land "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
calls() { cat "$LAND_LOG" 2>/dev/null | wc -l; }
short() { git -C "$1" rev-parse --short "$2"; }
nomerge() {
  local d
  for d in "$R" "$R/.claude/worktrees/_land"; do
    [ ! -d "$d" ] || ! git -C "$d" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "$1: no merge may stay in progress in $d"
  done
}
mkrepo() {
  rm -rf "$1"
  git init -q -b main "$1"
  echo a >"$1/shared.txt"
  printf '1\n2\n3\n4\n5\n6\n' >"$1/ov.txt"
  echo n >"$1/notes.txt"
  echo .claude/ >"$1/.gitignore"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
}
topic() {
  local r=$1 b=$2 f=$3 c=$4
  git -C "$r" checkout -q -b "$b" "${5:-main}"
  if [ "$f" = ov.txt ]; then sed -i "s/^$c\$/${c}$b/" "$r/ov.txt"; else echo "$c" >"$r/$f"; fi
  git -C "$r" add -A
  git -C "$r" commit -q -m "$b"
  git -C "$r" checkout -q main
}
hid=$(tr -d '[:space:]' </etc/machine-id 2>/dev/null) || hid=
[ -n "$hid" ] || { hid=0123456789abcdef0123456789abcde0; export FORGE_MACHINE_ID=$hid; }
oid=0123456789abcdef0123456789abcdef
[ "$oid" != "$hid" ] || oid=fedcba9876543210fedcba9876543210
put() { topic "$C" "$1" "$1.txt" s && mkdir -p "$C/.git/forge-test/$2" && : >"$C/.git/forge-test/$2/$(git -C "$C" rev-parse "$1^{tree}")"; }
stamp() { put "$1" "$hid/$2"; }
ci() { topic "$E" "$1" "$1.txt" c && mkdir -p "$ehs" && : >"$ehs/$(git -C "$E" rev-parse "$1^{tree}")"; }
fcommit() { mkdir -p "$T/.forge" && echo "$1" >"$T/.forge/$1.json" && git -C "$T" add ".forge/$1.json" && git -C "$T" commit -q -m "plan $1"; }
otree() {
  local b=$1; shift
  git -C "$T" checkout -q -b "$b" origin/main
  for c in "$@"; do git -C "$T" merge -q --no-ff -m "$b $c" "$c"; done
  git -C "$T" checkout -q main
}

R=$tmp/r W=$tmp/r/.claude/worktrees/_land
export LAND_R=$R
mkR() {
  mkrepo "$R"
  topic "$R" feat feat.txt f
  topic "$R" feat2 feat2.txt f2
  topic "$R" clash shared.txt theirs
  topic "$R" dis dis.txt d
  topic "$R" dis2 dis2.txt d
  topic "$R" late late.txt l
  topic "$R" ovb ov.txt 1
  topic "$R" ovc ov.txt 3
  topic "$R" loc notes.txt branch
  topic "$R" unt new.txt branch
  topic "$R" c1 c1.txt c
  topic "$R" nt1 nt1.txt n
  topic "$R" nt2 nt2.txt n
  topic "$R" c2 c2.txt c
  topic "$R" orph orph.txt o
  echo ours >"$R/shared.txt" && git -C "$R" commit -q -am ours
  echo dirty >>"$R/notes.txt"
  echo staged >"$R/staged.txt" && git -C "$R" add staged.txt
  echo u >"$R/u.txt"
  oldmain=$(git -C "$R" rev-parse main)
}
land_feat() {
  mkR
  [ "$(ld "$R" feat)" = 0 ] || fail "the replayed land of feat must exit 0: $(cat "$tmp/out" "$tmp/err")"
}
T=$tmp/t TO=$tmp/t.git
ths=$T/.git/forge-test/$hid
mkT() {
  git init -q --bare -b main "$TO"
  mkrepo "$T"
  git -C "$T" remote add origin "$TO"
  git -C "$T" push -q origin main
  git -C "$T" config forge.pushMain true
  mkdir -p "$ths/changed"
  topic "$T" k1 k1.txt k
  topic "$T" k2 k2.txt k
  topic "$T" k5 k5.txt k
}
mkP() {
  O=$tmp/origin.git P=$tmp/p Q=$tmp/q
  git init -q --bare -b main "$O"
  mkrepo "$P"
  git -C "$P" remote add origin "$O"
  git -C "$P" push -q origin main
  topic "$P" pf pf.txt p
  git -C "$P" push -q origin pf
  git clone -q "$O" "$Q"
  echo q >"$Q/remote.txt" && git -C "$Q" add -A && git -C "$Q" commit -q -m remote && git -C "$Q" push -q origin main
  remote=$(git -C "$Q" rev-parse HEAD)
  before=$(git -C "$P" rev-parse main)
}

if want land; then
  mkR
  cd "$R"
  for a in "" x "a b c"; do
    s=0; "$forge" land $a >/dev/null 2>&1 || s=$?
    [ "$s" = 2 ] || fail "land $a must exit 2, got $s"
  done
  cd "$tmp"
  [ "$(FORGE_ROOT=$tmp/nowhere ld r feat)" = 0 ] || fail "land r feat must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ ! -s "$tmp/err" ] || fail "land r feat prints nothing on stderr: $(cat "$tmp/err")"
  [ "$(cat "$tmp/out")" = "forge: landed feat as $(short "$R" main) on main" ] || fail "land prints the landed line: $(cat "$tmp/out")"
  [ "$(git -C "$R" log -1 --format=%s main)" = "Merge branch 'feat'" ] || fail "land's merge commit subject: $(git -C "$R" log -1 --format=%s main)"
  [ "$(git -C "$R" rev-parse main^1)" = "$oldmain" ] || fail "land's merge keeps the old main as its first parent"
  [ "$(git -C "$R" rev-parse main^2)" = "$(git -C "$R" rev-parse feat)" ] || fail "land's merge's second parent is the branch"
  [ "$(git -C "$R" branch --show-current)" = main ] || fail "R stays on main"
  [ -f "$R/feat.txt" ] || fail "the advance brings the branch's files into R"
  [ "$(cat "$R/notes.txt")" = "$(printf 'n\ndirty')" ] || fail "R's unrelated uncommitted edit stays"
  [ "$(git -C "$R" diff --cached --name-only)" = staged.txt ] || fail "R's unrelated staged file stays staged: $(git -C "$R" status --porcelain)"
  [ -f "$R/u.txt" ] || fail "R's untracked file stays"
  [ "$(git -C "$W" rev-parse --show-toplevel)" = "$W" ] || fail "land creates the _land worktree"
  ! git -C "$W" symbolic-ref -q HEAD >/dev/null || fail "_land is detached"
  [ "$(cat "$LAND_LOG")" = "$W $(git -C "$R" rev-parse main)" ] || fail "land tests the merge commit in _land once: $(cat "$LAND_LOG")"
  [ -e "$R/.git/forge.lock" ] || fail "land takes forge.lock"
  [ ! -e "$R/.git/forge-main.lock" ] || fail "land must not create forge-main.lock"
  nomerge "a land"
  ok land
fi

if want "reuse _land"; then
  cd "$tmp"
  [ -z "$only" ] || land_feat
  mkdir -p "$W/.claude" && echo stale >"$W/.claude/build.out"
  [ "$(ld "$R" feat2)" = 0 ] || fail "a second land reuses _land: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$W/.claude/build.out")" = stale ] || fail "land keeps _land's ignored files"
  [ "$(git -C "$R" rev-parse main^2)" = "$(git -C "$R" rev-parse feat2)" ] || fail "the second land merges feat2"
  ok "reuse _land"
fi

if want "orphan _land"; then
  cd "$tmp"
  [ -z "$only" ] || land_feat
  rm -rf "$R/.git/worktrees/_land"
  echo "gitdir: $tmp/moved/.git/worktrees/_land" >"$W/.git"
  [ "$(ld "$R" orph)" = 0 ] || fail "land replaces an _land whose gitdir is gone: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git -C "$W" rev-parse --show-toplevel)" = "$W" ] || fail "the replaced _land is a worktree of R"
  [ "$(git -C "$R" rev-parse main^2)" = "$(git -C "$R" rev-parse orph)" ] || fail "the land after the orphan merges orph"
  ok "orphan _land"
fi

if want "worktree ignore"; then
  cd "$tmp"
  [ -z "$only" ] || land_feat
  N=$tmp/n
  mkrepo "$N"
  git -C "$N" rm -q .gitignore && git -C "$N" commit -q -m unignore
  topic "$N" ni ni.txt n
  topic "$N" ni2 ni2.txt n
  [ "$(ld "$N" ni)" = 0 ] || fail "land in a repo not ignoring .claude/worktrees/ must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ -z "$(git -C "$N" status --porcelain)" ] || fail "land leaves a repo not ignoring .claude/worktrees/ clean: $(git -C "$N" status --porcelain)"
  [ "$(ld "$N" ni2)" = 0 ] || fail "a second land in that repo must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(grep -cxF .claude/worktrees/ "$N/.git/info/exclude")" = 1 ] || fail "land adds .claude/worktrees/ to info/exclude once: $(cat "$N/.git/info/exclude")"
  ! grep -qF .claude/worktrees "$R/.git/info/exclude" || fail "land leaves info/exclude alone where .gitignore covers .claude/worktrees/"
  ok "worktree ignore"
fi

if want "concurrent lands"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  rm -f "$LAND_LOG" "$LAND_LOG.started"
  FORGE_LAND_TEST=$tmp/bin/slowland "$forge" land "$R" c1 >"$tmp/c1.out" 2>"$tmp/c1.err" & a=$!
  for i in $(seq 50); do [ ! -e "$LAND_LOG.started" ] || break; sleep 0.1; done
  s=0; FORGE_LAND_TEST=$tmp/bin/slowland "$forge" land "$R" c2 >"$tmp/c2.out" 2>"$tmp/c2.err" || s=$?
  wait $a || fail "the first concurrent land: $(cat "$tmp/c1.out" "$tmp/c1.err")"
  [ "$s" = 0 ] || fail "the second concurrent land: $(cat "$tmp/c2.out" "$tmp/c2.err")"
  git -C "$R" merge-base --is-ancestor c1 main && git -C "$R" merge-base --is-ancestor c2 main || fail "both concurrent lands reach main"
  [ "$(wc -l <"$LAND_LOG")" = 2 ] || fail "each concurrent land tests once: $(cat "$LAND_LOG")"
  while read -r x y; do [ "$x" = "$y" ] || fail "a land's tree changed under its tests: $(cat "$LAND_LOG")"; done <"$LAND_LOG"
  [ "$(cut -d' ' -f1 "$LAND_LOG" | sort | paste -sd' ')" = "$(git -C "$R" rev-parse main main^1 | sort | paste -sd' ')" ] || fail "each landed merge was the tested one: $(cat "$LAND_LOG")"
  grep -qE "^forge: waiting for forge-land.lock \(held by $a .*land .*c1.* since .+\)$" "$tmp/c2.err" || fail "the second land waits on forge-land.lock: $(cat "$tmp/c2.err")"
  [ "$(wc -l <"$tmp/c2.err")" = 1 ] || fail "the waiter prints one line: $(cat "$tmp/c2.err")"
  ok "concurrent lands"
fi

if want conflict; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  head=$(git -C "$R" rev-parse main)
  [ "$(ld "$R" clash)" = 4 ] || fail "a conflicting branch must exit 4: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "forge merge main" "$tmp/err" || fail "a conflict tells the caller to run forge merge main: $(cat "$tmp/err")"
  grep -qF shared.txt "$tmp/err" || fail "a conflict names the paths: $(cat "$tmp/err")"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "a conflict leaves main"
  [ "$(calls)" = 0 ] || fail "a conflict runs no tests"
  nomerge "a conflict"
  ok conflict
fi

if want "tests fail"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  head=$(git -C "$R" rev-parse main)
  [ "$(LAND_EXIT=1 ld "$R" dis)" = 7 ] || fail "failing tests must exit 7: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "failing tests leave main"
  grep -qF "tests failed" "$tmp/err" || fail "failing tests say so: $(cat "$tmp/err")"
  ok "tests fail"
fi

if want "tests not configured"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  head=$(git -C "$R" rev-parse main)
  [ "$(LAND_EXIT=5 ld "$R" nt1)" = 7 ] || fail "a FORGE_LAND_TEST stub exiting 5 without a none declaration must exit 7: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "tests failed in $R/.claude/worktrees/_land with nt1 merged into main" "$tmp/err" || fail "a stub exiting 5 without the declaration fails the tests: $(cat "$tmp/err")"
  ! grep -qF untested "$tmp/err" || fail "a stub exiting 5 without the declaration lands nothing untested: $(cat "$tmp/err")"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "a stub exiting 5 without the declaration leaves main"
  s=0; FORGE_LAND_TEST= "$forge" land "$R" nt2 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 7 ] || fail "land without a TESTING.md must exit 7: $s $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: no \"- All tests:\" line in $R/.claude/worktrees/_land/.forge/TESTING.md; add a command or \"- All tests: none\"" "$tmp/err" || fail "land without a TESTING.md names the fix: $(cat "$tmp/err")"
  grep -qF "tests failed in $R/.claude/worktrees/_land with nt2 merged into main" "$tmp/err" && grep -qF "nothing landed" "$tmp/err" || fail "land without a TESTING.md fails the tests: $(cat "$tmp/err")"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "land without a TESTING.md leaves main"
  nomerge "tests not configured"
  M=$tmp/m
  mkrepo "$M"
  mkdir -p "$M/.forge"
  printf -- '# Testing\n\n## Commands\n- Lint: `true`\n' >"$M/.forge/TESTING.md"
  git -C "$M" add -A && git -C "$M" commit -q -m testing
  topic "$M" m1 m1.txt m
  mh=$(git -C "$M" rev-parse main)
  [ "$(FORGE_LAND_TEST= ld "$M" m1)" = 7 ] || fail "land with no All tests line must exit 7: $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: no \"- All tests:\" line in $M/.claude/worktrees/_land/.forge/TESTING.md; add a command or \"- All tests: none\"" "$tmp/err" || fail "land with no All tests line names the fix: $(cat "$tmp/err")"
  grep -qF "nothing landed" "$tmp/err" && ! grep -qF untested "$tmp/err" || fail "land with no All tests line fails the tests: $(cat "$tmp/err")"
  [ "$(git -C "$M" rev-parse main)" = "$mh" ] || fail "land with no All tests line leaves main"
  Q=$tmp/q5
  mkrepo "$Q"
  mkdir -p "$Q/.forge"
  printf -- '# Testing\n\n## Commands\n- All tests: `exit 5`\n' >"$Q/.forge/TESTING.md"
  git -C "$Q" add -A && git -C "$Q" commit -q -m testing
  topic "$Q" q1 q1.txt q
  qh=$(git -C "$Q" rev-parse main)
  [ "$(FORGE_LAND_TEST= ld "$Q" q1)" = 7 ] || fail "an All tests command exiting 5 through forge test must exit 7: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "tests failed in $Q/.claude/worktrees/_land with q1 merged into main" "$tmp/err" && ! grep -qF untested "$tmp/err" || fail "an All tests command exiting 5 fails the tests: $(cat "$tmp/err")"
  [ "$(git -C "$Q" rev-parse main)" = "$qh" ] || fail "an All tests command exiting 5 leaves main"
  ! git -C "$Q" merge-base --is-ancestor q1 main || fail "an All tests command exiting 5 lands nothing"
  N=$tmp/n
  mkrepo "$N"
  mkdir -p "$N/.forge"
  printf -- '# Testing\n\n## Commands\n- All tests: none\n' >"$N/.forge/TESTING.md"
  git -C "$N" add -A && git -C "$N" commit -q -m testing
  topic "$N" n1 n1.txt n
  topic "$N" n2 n2.txt n
  topic "$N" n3 n3.txt n
  [ "$(FORGE_LAND_TEST= ld "$N" n1)" = 0 ] || fail "a repo declaring none lands untested: $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: warning: $N/.claude/worktrees/_land declares \"- All tests: none\"; landing n1 untested" "$tmp/err" || fail "an untested land under the none declaration warns: $(cat "$tmp/err")"
  git -C "$N" merge-base --is-ancestor n1 main || fail "the untested land under the none declaration reaches main"
  [ "$(LAND_EXIT=5 ld "$N" n2)" = 0 ] || fail "a stub exiting 5 under the none declaration lands untested: $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: warning: $N/.claude/worktrees/_land declares \"- All tests: none\"; landing n2 untested" "$tmp/err" || fail "a stub exiting 5 under the none declaration warns: $(cat "$tmp/err")"
  git -C "$N" merge-base --is-ancestor n2 main || fail "a stub exiting 5 under the none declaration reaches main"
  nh=$(git -C "$N" rev-parse main)
  [ "$(LAND_EXIT=6 ld "$N" n3)" = 7 ] || fail "exit 6 under the none declaration must exit 7: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "nothing landed" "$tmp/err" && ! grep -qF untested "$tmp/err" || fail "exit 6 under the none declaration fails the tests: $(cat "$tmp/err")"
  [ "$(git -C "$N" rev-parse main)" = "$nh" ] || fail "exit 6 under the none declaration leaves main"
  ok "tests not configured"
fi

if want "cached land"; then
  cd "$tmp"
  C=$tmp/c
  mkrepo "$C"
  put so "$oid"
  [ "$(ld "$C" so)" = 0 ] && [ "$(calls)" = 1 ] || fail "a stamp only under another host's id is absent for land: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF "forge: tests passed ($(git -C "$C" rev-parse --short "so^{tree}")), cached" "$tmp/err" || fail "another host's stamp prints no cached line: $(cat "$tmp/err")"
  put su .
  [ "$(ld "$C" su)" = 0 ] && [ "$(calls)" = 1 ] || fail "a stamp only at the old unkeyed path is absent for land: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF "forge: tests passed ($(git -C "$C" rev-parse --short "su^{tree}")), cached" "$tmp/err" || fail "an unkeyed stamp prints no cached line: $(cat "$tmp/err")"
  [ -f "$C/.git/forge-test/$(git -C "$C" rev-parse "su^{tree}")" ] || fail "land leaves the old unkeyed stamp on disk"
  stamp sf .
  [ "$(ld "$C" sf)" = 0 ] || fail "a stamped branch lands: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 0 ] || fail "a full pass of the branch tree lands without a rerun: $(cat "$LAND_LOG")"
  grep -qxF "forge: tests passed ($(git -C "$C" rev-parse --short "sf^{tree}")), cached" "$tmp/err" || fail "a cached land says so: $(cat "$tmp/err")"
  git -C "$C" merge-base --is-ancestor sf main || fail "the cached land reaches main"
  stamp sc changed
  [ "$(ld "$C" sc)" = 0 ] && [ "$(calls)" = 1 ] || fail "a changed-tests pass is no full pass for land: $(cat "$LAND_LOG" "$tmp/err")"
  stamp sp .
  mkdir -p "$C/.forge" && echo '{}' >"$C/.forge/p.json" && git -C "$C" add .forge/p.json && git -C "$C" commit -q -m planning
  [ "$(ld "$C" sp)" = 0 ] && [ "$(calls)" = 0 ] || fail "main moving only in .forge keeps the stamp: $(cat "$LAND_LOG" "$tmp/err")"
  stamp sm .
  echo o >"$C/other.txt" && git -C "$C" add other.txt && git -C "$C" commit -q -m other
  [ "$(ld "$C" sm)" = 0 ] && [ "$(calls)" = 1 ] || fail "main moving outside .forge since the stamp retests: $(cat "$LAND_LOG" "$tmp/err")"
  ok "cached land"
fi

if want "chain stamp"; then
  cd "$tmp"
  C=$tmp/c
  mkrepo "$C"
  chs=$C/.git/forge-test/$hid
  mkdir -p "$chs/changed"
  ct() { git -C "$C" rev-parse "$1^{tree}"; }
  chn() { printf 'chain %s\n' "$2" >"$1/changed/$3"; }
  topic "$C" ch1a ch1a.txt s && topic "$C" ch1 ch1.txt s ch1a
  : >"$chs/$(ct ch1a)" && chn "$chs" "$(ct ch1a)" "$(ct ch1)"
  [ "$(ld "$C" ch1)" = 0 ] && [ "$(calls)" = 0 ] || fail "a changed stamp chaining to a full stamp of an ancestor branch commit's tree lands with no suite run: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$C" "ch1^{tree}")), cached" "$tmp/err" || fail "a chained land prints the cached line: $(cat "$tmp/err")"
  git -C "$C" merge-base --is-ancestor ch1 main || fail "the chained land reaches main"
  topic "$C" chs2 chs2.txt s && topic "$C" ch2 ch2.txt s
  : >"$chs/$(ct chs2)" && chn "$chs" "$(ct chs2)" "$(ct ch2)"
  [ "$(ld "$C" ch2)" = 0 ] && [ "$(calls)" = 1 ] || fail "a chain to a full stamp of a side-branch tree outside the landed history runs the suite: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF ", cached" "$tmp/err" || fail "a chain outside the landed history prints no cached line: $(cat "$tmp/err")"
  topic "$C" ch3a ch3a.txt s && topic "$C" ch3 ch3.txt s ch3a
  chn "$chs" "$(ct ch3a)" "$(ct ch3)"
  [ "$(ld "$C" ch3)" = 0 ] && [ "$(calls)" = 1 ] || fail "a chain to a tree with no full stamp runs the suite: $(cat "$LAND_LOG" "$tmp/err")"
  topic "$C" ch8a ch8a.txt s && topic "$C" ch8 ch8.txt s ch8a
  : >"$chs/$(ct ch8a)" && git -C "$C" rev-parse ch8a >"$chs/changed/$(ct ch8)"
  [ "$(ld "$C" ch8)" = 0 ] && [ "$(calls)" = 1 ] || fail "a bare-sha changed stamp is no chain for land: $(cat "$LAND_LOG" "$tmp/err")"
  topic "$C" ch4a ch4a.txt s && topic "$C" ch4 ch4.txt s ch4a
  : >"$chs/$(ct ch4a)" && chn "$chs" "$(ct ch4a)" "$(ct ch4)"
  mkdir -p "$C/.forge" && echo '{}' >"$C/.forge/ch4.json" && git -C "$C" add .forge/ch4.json && git -C "$C" commit -q -m planning
  [ "$(ld "$C" ch4)" = 0 ] && [ "$(calls)" = 0 ] || fail "a .forge-only main commit after a chained changed stamp lands with no suite run: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$C" "ch4^{tree}")), cached" "$tmp/err" || fail "the scan's chained hit prints the cached line: $(cat "$tmp/err")"
  git -C "$C" merge-base --is-ancestor ch4 main || fail "the scan's chained land reaches main"
  topic "$C" ch5a ch5a.txt s && topic "$C" ch5 ch5.txt s ch5a
  mkdir -p "$C/.git/forge-test/$oid/changed" && : >"$C/.git/forge-test/$oid/$(ct ch5a)" && chn "$C/.git/forge-test/$oid" "$(ct ch5a)" "$(ct ch5)"
  [ "$(ld "$C" ch5)" = 0 ] && [ "$(calls)" = 1 ] || fail "a chain only under another host's id runs the suite: $(cat "$LAND_LOG" "$tmp/err")"
  topic "$C" ch6a ch6a.txt s && topic "$C" ch6b ch6b.txt s ch6a && topic "$C" ch6 ch6.txt s ch6b
  : >"$chs/$(ct ch6a)" && chn "$chs" "$(ct ch6a)" "$(ct ch6b)" && chn "$chs" "$(ct ch6b)" "$(ct ch6)"
  [ "$(ld "$C" ch6)" = 0 ] && [ "$(calls)" = 0 ] || fail "a two-hop chain to a full stamp in the landed history lands with no suite run: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$C" "ch6^{tree}")), cached" "$tmp/err" || fail "a two-hop chained land prints the cached line: $(cat "$tmp/err")"
  topic "$C" ch7a ch7a.txt s && topic "$C" ch7 ch7.txt s ch7a
  chn "$chs" "$(ct ch7a)" "$(ct ch7)" && chn "$chs" "$(ct ch7)" "$(ct ch7a)"
  [ "$(ld "$C" ch7)" = 0 ] && [ "$(calls)" = 1 ] || fail "a chain cycle with no full stamp runs the suite: $(cat "$LAND_LOG" "$tmp/err")"
  L=$tmp/lp
  mkrepo "$L"
  for i in $(seq 5000); do
    printf 'commit refs/heads/main\ncommitter forge <forge@example.com> %d +0000\ndata 1\nh\n' $((1700000000 + i))
    [ "$i" != 1 ] || printf 'from refs/heads/main^0\n'
    printf 'M 644 inline h.txt\ndata %d\n%s\n\n' $((${#i} + 1)) "$i"
  done | git -C "$L" fast-import --quiet
  git -C "$L" reset -q --hard main
  [ "$(git -C "$L" rev-list --count main)" -gt 5000 ] || fail "the long history holds over 5000 commits"
  topic "$L" lpa lpa.txt s && topic "$L" lp lp.txt s lpa
  lhs=$L/.git/forge-test/$hid
  mkdir -p "$lhs/changed" && : >"$lhs/$(git -C "$L" rev-parse "lpa^{tree}")" && chn "$lhs" "$(git -C "$L" rev-parse "lpa^{tree}")" "$(git -C "$L" rev-parse "lp^{tree}")"
  [ "$(ld "$L" lp)" = 0 ] && [ "$(calls)" = 0 ] || fail "a chained full stamp near the top of a long history lands with no suite run under pipefail: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$L" "lp^{tree}")), cached" "$tmp/err" || fail "the long-history chained land prints the cached line: $(cat "$tmp/err")"
  ok "chain stamp"
fi

if want "ci stamp"; then
  cd "$tmp"
  E=$tmp/e
  mkrepo "$E"
  ehs=$(git -C "$E" rev-parse --path-format=absolute --git-common-dir)/forge-test/$hid
  ci ci1
  [ "$(ld "$E" ci1)" = 0 ] || fail "a CI-stamped branch lands: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 0 ] || fail "a CI pass stamp of the branch tip tree with main unchanged lands with no test run: $(cat "$LAND_LOG")"
  grep -qxF "forge: tests passed ($(short "$E" "ci1^{tree}")), cached" "$tmp/err" || fail "a CI-stamped land prints the cached line: $(cat "$tmp/err")"
  git -C "$E" merge-base --is-ancestor ci1 main || fail "the CI-stamped land reaches main"
  ci ci2
  mkdir -p "$E/.forge" && echo '{}' >"$E/.forge/ci.json" && git -C "$E" add .forge/ci.json && git -C "$E" commit -q -m planning
  [ "$(ld "$E" ci2)" = 0 ] && [ "$(calls)" = 0 ] || fail "main gaining a .forge-only commit after the CI stamp lands with no test run: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$E" "ci2^{tree}")), cached" "$tmp/err" || fail "the CI stamp hit across a .forge-only main commit prints the cached line: $(cat "$tmp/err")"
  git -C "$E" merge-base --is-ancestor ci2 main || fail "the CI-stamped land across a .forge-only main commit reaches main"
  ci ci3
  printf -- '- All tests: `ci`\n' >"$E/.forge/TESTING.md" && git -C "$E" add .forge/TESTING.md && git -C "$E" commit -q -m suite
  [ "$(ld "$E" ci3)" = 0 ] && [ "$(calls)" = 1 ] || fail "main changing .forge/TESTING.md after the CI stamp runs land_test: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF ", cached" "$tmp/err" || fail "a CI stamp before a .forge/TESTING.md change prints no cached line: $(cat "$tmp/err")"
  ci ci4
  echo o >"$E/code.txt" && git -C "$E" add code.txt && git -C "$E" commit -q -m code
  [ "$(ld "$E" ci4)" = 0 ] && [ "$(calls)" = 1 ] || fail "main moving outside .forge after the CI stamp runs land_test: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF ", cached" "$tmp/err" || fail "a CI stamp before a code change on main prints no cached line: $(cat "$tmp/err")"
  [ "$(cat "$LAND_LOG")" = "$E/.claude/worktrees/_land $(git -C "$E" rev-parse main)" ] || fail "land_test runs on the merged tree: $(cat "$LAND_LOG")"
  [ "$(git -C "$E" rev-parse "main^{tree}")" != "$(git -C "$E" rev-parse "ci4^{tree}")" ] || fail "the merged tree carries main's code change"
  ok "ci stamp"
fi

if want "stamp scan origin tree"; then
  cd "$tmp"
  mkT
  fcommit x
  otree tr k1 k2
  ttree=$(git -C "$T" rev-parse "tr^{tree}")
  : >"$ths/$ttree"
  : >"$ths/ffffffffffffffffffffffffffffffffffffffff"
  : >"$ths/notes"
  otree om k1 k2
  git -C "$T" push -q origin om:main
  [ "$(git -C "$T" rev-parse "om^{tree}")" = "$ttree" ] || fail "origin/main's tree is the stamped tree"
  [ "$(ld "$T" k2)" = 0 ] || fail "a branch whose origin tree is stamped lands: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 0 ] || fail "a branch whose integrated tree differs from an origin-tree stamp only under .forge lands with no suite run: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$T" "$ttree")), cached" "$tmp/err" || fail "the origin-tree stamp hit prints the cached line: $(cat "$tmp/err")"
  ! grep -qiE 'fatal|error' "$tmp/err" || fail "a stamp whose tree object is absent is skipped silently: $(cat "$tmp/err")"
  git -C "$T" merge-base --is-ancestor k2 main && git -C "$T" merge-base --is-ancestor k1 main || fail "the stamp-tested land reaches main"
  [ "$(git -C "$TO" rev-parse main)" = "$(git -C "$T" rev-parse main)" ] || fail "the stamp-tested land pushes main"
  ok "stamp scan origin tree"
fi

if want "stamp scan code drift"; then
  cd "$tmp"
  [ -z "$only" ] || mkT
  topic "$T" k3 k3.txt k
  topic "$T" k4 k4.txt k
  fcommit y
  otree tr2 k3 k4
  : >"$ths/$(git -C "$T" rev-parse "tr2^{tree}")"
  otree om2 k3 k4
  git -C "$T" checkout -q om2 && echo e >"$T/extra.txt" && git -C "$T" add extra.txt && git -C "$T" commit -q -m extra && git -C "$T" checkout -q main
  git -C "$T" push -q origin om2:main
  [ "$(ld "$T" k4)" = 0 ] && [ "$(calls)" = 1 ] || fail "origin/main carrying a code file the stamped origin tree lacks retests: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF ", cached" "$tmp/err" || fail "a stamp differing outside .forge prints no cached line: $(cat "$tmp/err")"
  ok "stamp scan code drift"
fi

if want "stamp scan dangling"; then
  cd "$tmp"
  [ -z "$only" ] || mkT
  git -C "$T" checkout -q -b dm main
  git -C "$T" merge -q --no-ff -m dangling k5
  dtree=$(git -C "$T" rev-parse "dm^{tree}")
  : >"$ths/$dtree"
  git -C "$T" checkout -q main
  git -C "$T" branch -q -D dm
  fcommit z
  [ "$(ld "$T" k5)" = 0 ] || fail "a land after a dangling stamped merge lands: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 0 ] || fail "a stamp of an earlier, dangling merge differing only under .forge is reused: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$T" "$dtree")), cached" "$tmp/err" || fail "the dangling stamp hit prints the cached line: $(cat "$tmp/err")"
  ! grep -qiE 'fatal|error' "$tmp/err" || fail "the scan prints no error: $(cat "$tmp/err")"
  ok "stamp scan dangling"
fi

if want "stamp scan host"; then
  cd "$tmp"
  [ -z "$only" ] || mkT
  topic "$T" k6 k6.txt k
  fcommit w
  : >"$ths/$(git -C "$T" rev-parse "k6^{tree}")"
  [ "$(ld "$T" k6)" = 0 ] && [ "$(calls)" = 0 ] || fail "a branch-tip stamp still hits through the scan: $(cat "$LAND_LOG" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$T" "k6^{tree}")), cached" "$tmp/err" || fail "the branch-tip hit prints the cached line: $(cat "$tmp/err")"
  topic "$T" k7 k7.txt k
  git -C "$T" checkout -q -b ot main && git -C "$T" merge -q --no-ff -m other k7 && git -C "$T" checkout -q main
  mkdir -p "$T/.git/forge-test/$oid" && : >"$T/.git/forge-test/$oid/$(git -C "$T" rev-parse "ot^{tree}")"
  fcommit v
  [ "$(ld "$T" k7)" = 0 ] && [ "$(calls)" = 1 ] || fail "a matching stamp only under another host's id is never read by the scan: $(cat "$LAND_LOG" "$tmp/err")"
  ok "stamp scan host"
fi

if want "stamp scan testing doc"; then
  cd "$tmp"
  [ -z "$only" ] || mkT
  topic "$T" k8 k8.txt k
  git -C "$T" checkout -q -b ts main && git -C "$T" merge -q --no-ff -m old k8 && git -C "$T" checkout -q main
  : >"$ths/$(git -C "$T" rev-parse "ts^{tree}")"
  mkdir -p "$T/.forge" && printf -- '- All tests: `new`\n' >"$T/.forge/TESTING.md" && git -C "$T" add .forge/TESTING.md && git -C "$T" commit -q -m suite
  [ "$(ld "$T" k8)" = 0 ] && [ "$(calls)" = 1 ] || fail "a stamp from before main changed .forge/TESTING.md retests: $(cat "$LAND_LOG" "$tmp/err")"
  ! grep -qF ", cached" "$tmp/err" || fail "a stamp differing in .forge/TESTING.md prints no cached line: $(cat "$tmp/err")"
  ok "stamp scan testing doc"
fi

if want "land setup"; then
  cd "$tmp"
  D=$tmp/d
  mkrepo "$D"
  mkdir -p "$D/.forge"
  printf -- '- Setup: `mkdir -p deps && echo s >>"$SETUP_LOG"`\n- All tests: `test -d deps`\n' >"$D/.forge/TESTING.md"
  echo deps/ >>"$D/.gitignore"
  git -C "$D" add -A && git -C "$D" commit -q -m testing
  topic "$D" d1 d1.txt d
  topic "$D" d2 d2.txt d
  export SETUP_LOG=$tmp/setup.log
  s=0; FORGE_LAND_TEST= "$forge" land "$D" d1 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] && [ "$(wc -l <"$SETUP_LOG")" = 1 ] || fail "land runs the Setup line in _land before the tests: $s $(cat "$tmp/out" "$tmp/err")"
  : >"$D/.claude/worktrees/_land/deps/kept"
  st=$(git -C "$D/.claude/worktrees/_land" rev-parse --absolute-git-dir)/forge-setup
  [ -s "$st" ] || fail "land writes _land's Setup stamp: $(ls -A "${st%/*}")"
  s=0; FORGE_LAND_TEST= "$forge" land "$D" d2 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] && [ "$(wc -l <"$SETUP_LOG")" = 1 ] || fail "a second land keeps _land warm and does not rerun Setup: $s $(cat "$tmp/out" "$tmp/err")"
  [ -e "$D/.claude/worktrees/_land/deps/kept" ] || fail "land keeps _land's ignored deps dir"
  [ -s "$st" ] || fail "land keeps _land's Setup stamp"
  topic "$D" d3 d3.txt d
  mkdir -p "$D/.git/forge-test/$hid" && : >"$D/.git/forge-test/$hid/$(git -C "$D" rev-parse "d3^{tree}")"
  echo r >"$D/README.md" && git -C "$D" add README.md && git -C "$D" commit -q -m readme
  s=0; FORGE_LAND_TEST= "$forge" land "$D" d3 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] && [ "$(wc -l <"$SETUP_LOG")" = 1 ] || fail "land runs the full suite when the merge adds only docs to a stamped tip: $s $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: tests passed ($(short "$D" "main^{tree}"))" "$tmp/err" || fail "land takes no docs-only carry-over: $(cat "$tmp/err")"
  ok "land setup"
fi

cat >"$tmp/bin/rerunland" <<'EOF'
#!/usr/bin/env bash
echo "${FORGE_TEST_RERUN-unset}" >"$LAND_RERUN"
EOF
chmod +x "$tmp/bin/rerunland"
if want "land rerun"; then
  cd "$tmp"
  V=$tmp/v
  mkrepo "$V"
  mkdir -p "$V/.forge"
  printf -- '- All tests: `test ! -e "$LAND_FAIL"`\n' >"$V/.forge/TESTING.md"
  git -C "$V" add -A && git -C "$V" commit -q -m testing
  topic "$V" v1 v1.txt v
  topic "$V" v2 v2.txt v
  s=0; LAND_RERUN=$tmp/rerun FORGE_LAND_TEST=$tmp/bin/rerunland env -u FORGE_TEST_RERUN "$forge" land "$V" v1 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "a land through a FORGE_LAND_TEST stub lands: $s $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$tmp/rerun" 2>/dev/null)" = unset ] || fail "land_test passes no FORGE_TEST_RERUN to FORGE_LAND_TEST: $(cat "$tmp/rerun" 2>/dev/null)"
  s=0; LAND_FAIL=$tmp FORGE_LAND_TEST= "$forge" land "$V" v2 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 7 ] || fail "a land whose tests fail exits 7: $s $(cat "$tmp/out" "$tmp/err")"
  ls "$V/.git/forge-test/failed/"*-all.log >/dev/null 2>&1 || fail "the failed land test leaves a fresh failed log: $(ls -R "$V/.git/forge-test" 2>&1)"
  s=0; FORGE_LAND_TEST= env -u FORGE_TEST_RERUN "$forge" land "$V" v2 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "a land retried on a tree with a fresh failed log is not refused: $s $(cat "$tmp/out" "$tmp/err")"
  ! grep -qF "rerun with --force" "$tmp/err" || fail "a retried land prints no refusal: $(cat "$tmp/err")"
  git -C "$V" merge-base --is-ancestor v2 main || fail "the retried land reaches main"
  ok "land rerun"
fi

if want "planning re-merge"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  [ "$(LAND_FILE=.forge/tracks/x.json LAND_HOOK=$tmp/bin/disjoint ld "$R" dis)" = 0 ] || fail "main moving in .forge must still land: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 1 ] || fail "main moving only in .forge re-merges without retest: $(cat "$LAND_LOG")"
  [ "$(git -C "$R" log -1 --format=%s main^1)" = other ] || fail "the re-merge sits on the new main tip"
  [ "$(git -C "$R" rev-parse main^2)" = "$(git -C "$R" rev-parse dis)" ] || fail "the re-merge merges dis"
  [ "$(git -C "$R" rev-parse main^2)" = "$(git -C "$R" rev-parse "$(cut -d' ' -f2 "$LAND_LOG")^2")" ] || fail "the re-merge merges the tested branch commit"
  [ "$(cat "$tmp/out")" = "forge: landed dis as $(short "$R" main) on main" ] || fail "the re-merge prints its sha: $(cat "$tmp/out")"
  ok "planning re-merge"
fi

if want "branch moved during test"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  tip=$(git -C "$R" rev-parse late)
  [ "$(LAND_HOOK=$tmp/bin/late ld "$R" late)" = 0 ] || fail "a branch moving during the test must still land: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 1 ] || fail "main moving only in .forge re-merges without retest: $(cat "$LAND_LOG")"
  [ "$(git -C "$R" rev-parse "$(cut -d' ' -f2 "$LAND_LOG")^2")" = "$tip" ] || fail "the test ran on the branch tip at land time"
  [ "$(git -C "$R" rev-parse main^2)" = "$tip" ] || fail "the re-merge lands the tested branch commit, not one made during the test"
  [ "$(git -C "$R" log -1 --format=%s main)" = "Merge branch 'late'" ] || fail "the re-merge keeps the branch name in its subject: $(git -C "$R" log -1 --format=%s main)"
  ok "branch moved during test"
fi

if want "disjoint retest"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  [ "$(LAND_HOOK=$tmp/bin/disjoint ld "$R" dis2)" = 0 ] || fail "main moving in other files must land after a retest: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 2 ] || fail "main moving outside .forge retests, even in disjoint files: $(cat "$LAND_LOG")"
  [ "$(sed -n 2p "$LAND_LOG" | cut -d' ' -f2)" = "$(git -C "$R" rev-parse main)" ] || fail "the retest ran on the landed commit"
  [ "$(git -C "$R" log -1 --format=%s main^1)" = other ] || fail "the retested merge sits on the new main tip"
  ok "disjoint retest"
fi

if want "overlap retest"; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  [ "$(LAND_HOOK=$tmp/bin/overlap ld "$R" ovb)" = 0 ] || fail "main moving in the branch's files must land after a retest: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 2 ] || fail "main moving in the branch's files retests: $(cat "$LAND_LOG")"
  [ "$(sed -n 2p "$LAND_LOG" | cut -d' ' -f2)" = "$(git -C "$R" rev-parse main)" ] || fail "the retest ran on the landed commit"
  [[ "$(sed -n "1p;6p" "$R/ov.txt" | paste -sd " ")" == "1ovb 6main1-"* ]] || fail "main holds both edits: $(cat "$R/ov.txt")"
  ok "overlap retest"
fi

if want bounded; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  head=$(git -C "$R" rev-parse main)
  [ "$(LAND_ALWAYS=1 LAND_HOOK=$tmp/bin/overlap ld "$R" ovc)" = 5 ] || fail "main moving every time must exit 5: $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 5 ] || fail "the loop is bounded at 5 tests: $(cat "$LAND_LOG")"
  ! git -C "$R" merge-base --is-ancestor ovc main || fail "exit 5 lands nothing"
  grep -qF "main kept moving" "$tmp/err" || fail "exit 5 says why: $(cat "$tmp/err")"
  nomerge "exit 5"
  ok bounded
fi

if want "R conflicts"; then
  cd "$tmp"
  if [ -n "$only" ]; then mkR; head=$(git -C "$R" rev-parse main); fi
  git -C "$R" reset -q --hard "$head"
  echo dirty >>"$R/notes.txt"
  [ "$(ld "$R" loc)" = 6 ] || fail "R's local edit to a merged file must exit 6: $(cat "$tmp/out" "$tmp/err")"
  grep -qF notes.txt "$tmp/err" || fail "exit 6 names the path: $(cat "$tmp/err")"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "exit 6 leaves main"
  [ "$(cat "$R/notes.txt")" = "$(printf 'n\ndirty')" ] || fail "exit 6 keeps R's edit"
  git -C "$R" checkout -q -- notes.txt
  echo mine >"$R/new.txt"
  [ "$(ld "$R" unt)" = 6 ] || fail "R's untracked file in the merge's way must exit 6: $(cat "$tmp/out" "$tmp/err")"
  grep -qF new.txt "$tmp/err" || fail "exit 6 names the untracked path: $(cat "$tmp/err")"
  [ "$(cat "$R/new.txt")" = mine ] || fail "exit 6 keeps R's untracked file"
  rm "$R/new.txt"
  ok "R conflicts"
fi

if want lock; then
  cd "$tmp"
  if [ -n "$only" ]; then mkR; head=$(git -C "$R" rev-parse main); fi
  exec 7>"$R/.git/forge.lock"
  flock 7
  rm -f "$LAND_LOG"
  s=0; timeout 2 "$forge" land "$R" unt >"$tmp/out" 2>"$tmp/err" || s=$?
  [ "$s" = 124 ] || fail "land under a held forge.lock must block: $s $(cat "$tmp/out" "$tmp/err")"
  [ "$(calls)" = 1 ] || fail "land runs the tests outside the lock"
  [ "$(git -C "$R" rev-parse main)" = "$head" ] || fail "land under a held lock leaves main"
  exec 7>&-
  ok lock
fi

if want refusals; then
  cd "$tmp"
  [ -z "$only" ] || mkR
  [ "$(ld "$R" nope)" = 1 ] || fail "an unknown branch must exit 1"
  grep -q nope "$tmp/err" || fail "an unknown branch is named: $(cat "$tmp/err")"
  git -C "$R" checkout -q feat
  [ "$(ld "$R" dis)" = 1 ] || fail "R off main must exit 1"
  [ "$(cat "$tmp/err")" = "forge: $R is on feat, not main" ] || fail "R off main: $(cat "$tmp/err")"
  git -C "$R" checkout -q main
  mkdir -p "$tmp/nogit"
  [ "$(ld "$tmp/nogit" feat)" = 1 ] || fail "a non-repo must exit 1"
  [ "$(cat "$tmp/err")" = "forge: not a git repository: $tmp/nogit" ] || fail "a non-repo: $(cat "$tmp/err")"
  ok refusals
fi

if want_any "no push refuses a diverged origin" push; then mkP; fi
if want "no push refuses a diverged origin"; then
  cd "$tmp"
  [ "$(ld "$P" pf)" = 1 ] || fail "land without pushMain must refuse while origin/main has commits local main lacks: $(cat "$tmp/out" "$tmp/err")"
  grep -q "origin/main has commits" "$tmp/err" && grep -q "forge.pushMain" "$tmp/err" || fail "the refusal names origin/main and forge.pushMain: $(cat "$tmp/err")"
  [ "$(git -C "$P" rev-parse main)" = "$before" ] || fail "a refused land moves nothing"
  [ "$(git -C "$O" rev-parse main)" = "$remote" ] || fail "a refused land leaves origin"
  ok "no push refuses a diverged origin"
fi

if want push; then
  cd "$tmp"
  git -C "$P" config forge.pushMain true
  [ "$(ld "$P" pf)" = 0 ] || fail "land with pushMain must exit 0: $(cat "$tmp/out" "$tmp/err")"
  git -C "$P" merge-base --is-ancestor "$remote" main || fail "land merges origin's commits first"
  tested=$(cut -d' ' -f2 "$LAND_LOG")
  git -C "$P" merge-base --is-ancestor "$remote" "$tested" || fail "the tested tree holds origin's commits"
  [ "$(git -C "$O" rev-parse main)" = "$(git -C "$P" rev-parse main)" ] || fail "land pushes main to origin"
  git -C "$O" merge-base --is-ancestor "$(git -C "$P" rev-parse pf)" main || fail "the pushed branch head is on origin's main"
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed pf as %s on main\nforge: pushed %s to origin\nforge: deleted origin/pf' "$(short "$P" main)" "$(short "$P" main)")" ] \
    || fail "land with pushMain prints the landed, pushed and deleted lines: $(cat "$tmp/out")"
  ! git -C "$O" show-ref -q --verify refs/heads/pf || fail "land deletes the landed branch on origin"
  topic "$P" pk pk.txt k
  git -C "$P" push -q origin pk
  git -C "$Q" fetch -q origin && git -C "$Q" checkout -q -b pk origin/pk && echo more >>"$Q/pk.txt" && git -C "$Q" commit -q -am more && git -C "$Q" push -q origin pk
  [ "$(ld "$P" pk)" = 0 ] || fail "land of a branch moved on origin must still land: $(cat "$tmp/out" "$tmp/err")"
  grep -q "kept origin/pk" "$tmp/err" || fail "land keeps an origin branch with commits main lacks, with a warning: $(cat "$tmp/err")"
  git -C "$O" show-ref -q --verify refs/heads/pk || fail "land keeps origin/pk"
  [ "$(ld "$P" main)" = 1 ] && grep -q "cannot land main" "$tmp/err" || fail "land refuses to land main onto itself: $(cat "$tmp/out" "$tmp/err")"
  git -C "$O" show-ref -q --verify refs/heads/main || fail "origin keeps main"
  ok push
fi

gl() { local s=0; rm -f "$LAND_LOG" "$tmp/port.log"; "$forge" golive "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
cat >"$tmp/bin/claude" <<'EOF2'
#!/usr/bin/env bash
[ "$*" = "agents --json" ] || exit 1
[ -z "${CLAUDE_AGENTS_SLEEP:-}" ] || sleep "$CLAUDE_AGENTS_SLEEP"
cat "$CLAUDE_AGENTS"
exit "${CLAUDE_AGENTS_EXIT:-0}"
EOF2
chmod +x "$tmp/bin/claude"
export PATH=$tmp/bin:$PATH CLAUDE_AGENTS=$tmp/agents.json CLAUDE_CODE_SESSION_ID=caller-0001
echo '[]' >"$CLAUDE_AGENTS"
pending=$HOME/.local/state/forge/port.pending
G=$tmp/g
mkG() {
  mkrepo "$G"
  topic "$G" g1 g1.txt g
  topic "$G" g2 g2.txt g
  topic "$G" g3 g3.txt g
  topic "$G" gx shared.txt theirs
  echo ours >"$G/shared.txt" && git -C "$G" commit -q -am ours
}
gport() {
  cat >"$1/port" <<'EOF2'
#!/usr/bin/env bash
echo "$PWD $*" >>"$PORT_LOG"
echo ">f+++++++++ skills/x"
echo "ported $(git rev-parse --short HEAD)"
exit "${PORT_EXIT:-0}"
EOF2
  chmod +x "$1/port"
}
addport() { gport "$G" && git -C "$G" add port && git -C "$G" commit -q -m port; }
mkGp() { mkG; addport; }
dtopics() { for b in d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d13; do topic "$G" "$b" "$b.txt" d; done; }
mkGd() { mkGp; dtopics; }

if want "golive no port"; then
  mkG
  cd "$G"
  for a in "" x "a b main" "a b b" "a b c main"; do
    s=0; "$forge" golive $a >/dev/null 2>&1 || s=$?
    [ "$s" = 2 ] || fail "golive $a must exit 2, got $s"
  done
  cd "$tmp"
  [ "$(gl "$G" g1)" = 0 ] || fail "golive without port must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed g1 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: no port' "$(short "$G" main)")" ] \
    || fail "golive without port prints landed, not pushed, no port: $(cat "$tmp/out")"
  ok "golive no port"
fi

export PORT_LOG=$tmp/port.log
if want "golive port"; then
  cd "$tmp"
  [ -z "$only" ] || mkG
  addport
  [ "$(gl "$G" g2)" = 0 ] || fail "golive with port must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$G" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed g2 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: ported %s' "$sha" "$sha")" ] \
    || fail "golive with port prints landed, not pushed, ported: $(cat "$tmp/out")"
  [ "$(cat "$PORT_LOG")" = "$G --apply" ] || fail "golive runs ./port --apply from R: $(cat "$PORT_LOG")"
  grep -qF ">f+++++++++ skills/x" "$tmp/err" || fail "port's itemized output goes to stderr: $(cat "$tmp/err")"
  ok "golive port"
fi

if want "golive failures"; then
  cd "$tmp"
  [ -z "$only" ] || mkGp
  [ "$(PORT_EXIT=1 gl "$G" g3)" = 1 ] || fail "a failing port must exit 1: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "port --apply failed" "$tmp/err" || fail "a failing port says so: $(cat "$tmp/err")"
  git -C "$G" merge-base --is-ancestor g3 main || fail "a failing port keeps the landing"
  [ "$(gl "$G" gx)" = 4 ] || fail "golive of a conflicting branch exits 4: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$PORT_LOG" ] || fail "a failed land runs no port"
  ok "golive failures"
fi

agents() { jq -n "$1" >"$CLAUDE_AGENTS"; }
queued() {
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed %s as %s on main\nforge: not pushed: forge.pushMain unset\nforge: port queued: %s' "$2" "$(short "$1" main)" "$3")" ] \
    || fail "$4 queues the port: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$PORT_LOG" ] || fail "$4 runs no port: $(cat "$PORT_LOG")"
  git -C "$1" merge-base --is-ancestor "$2" main || fail "$4 keeps the landing"
}
if want "golive defer runs port"; then
  cd "$tmp"
  [ -z "$only" ] || mkGp
  dtopics
  agents '[{sessionId: "caller-0001", name: "throughput ship-train Phase 133", state: "working"},
    {sessionId: "s-b", name: "Discuss throughput", state: "blocked"},
    {sessionId: "s-c", name: "forge ship throughput/ship-train", state: "done"},
    {sessionId: "s-d", name: "fix the readme", state: "working"},
    {sessionId: "s-e", name: "Discussion of plans", state: "working"},
    {sessionId: "s-f", name: "a b Phase 3 later", state: "working"},
    {sessionId: "s-g", name: "forge P12 throughput", state: "working"},
    {sessionId: "s-h", state: "working"},
    {name: "forge build x", state: "blocked"}]'
  [ "$(gl "$G" d0)" = 0 ] || fail "golive with only the caller, blocked, done and non-forge sessions must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$G" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed d0 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: ported %s' "$sha" "$sha")" ] \
    || fail "golive ports when no other forge session is working: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG")" = "$G --apply" ] || fail "golive with no other working forge session runs ./port --apply: $(cat "$PORT_LOG" 2>/dev/null)"
  [ ! -e "$pending" ] || fail "a ported golive writes no pending line: $(cat "$pending")"
  ok "golive defer runs port"
fi

if want "golive defer same project"; then
  cd "$tmp"
  [ -z "$only" ] || mkGp
  gtop=$(git -C "$G" rev-parse --show-toplevel)
  gup=$(dirname "$gtop")
  for b in s1 s2 s3 s4 s5; do topic "$G" "$b" "$b.txt" s; done
  agents "[{sessionId: \"s-1\", name: \"Quick other project\", state: \"working\", cwd: \"$gup/elsewhere\"},
    {sessionId: \"s-2\", name: \"Debug sibling\", state: \"working\", cwd: \"${gtop}x\"}]"
  [ "$(gl "$G" s1)" = 0 ] || fail "golive with forge sessions only in other projects must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$G" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed s1 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: ported %s' "$sha" "$sha")" ] \
    || fail "golive ports when forge sessions work only in other projects: $(cat "$tmp/out" "$tmp/err")"
  agents "[{sessionId: \"s-1\", name: \"Quick same project\", state: \"working\", cwd: \"$gtop/.claude/worktrees/quick-x\"},
    {sessionId: \"s-2\", name: \"Quick other project\", state: \"working\", cwd: \"$gup/elsewhere\"}]"
  [ "$(gl "$G" s2)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" s2 "1 forge sessions working" "golive with a forge session in the repo's worktree"
  agents "[{sessionId: \"s-1\", name: \"Discuss parent\", state: \"working\", cwd: \"$gup\"}]"
  [ "$(gl "$G" s3)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" s3 "1 forge sessions working" "golive with a forge session in a parent of the repo"
  agents "[{sessionId: \"s-1\", name: \"Discuss here\", state: \"working\", cwd: \"$gtop\"}]"
  [ "$(gl "$G" s4)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" s4 "1 forge sessions working" "golive with a forge session in the repo"
  git -C "$G" config forge.liveInstall true
  agents "[{sessionId: \"s-1\", name: \"Quick other project\", state: \"working\", cwd: \"$gup/elsewhere\"}]"
  [ "$(gl "$G" s5)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" s5 "1 forge sessions working" "golive of a forge.liveInstall repo with a forge session in another project"
  git -C "$G" config --unset forge.liveInstall
  rm -f "$pending"
  ok "golive defer same project"
fi

if want "golive defer queues"; then
  cd "$tmp"
  [ -z "$only" ] || mkGd
  agents '[{sessionId: "s-1", name: "Discuss throughput", state: "working"},
    {sessionId: "s-2", name: "Quick fix the parser", state: "working"},
    {sessionId: "s-3", name: "Debug login", state: "working"},
    {sessionId: "s-4", name: "Fast thing", state: "working"},
    {sessionId: "s-5", name: "New project", state: "working"},
    {sessionId: "caller-0001", name: "Discuss mine", state: "working"}]'
  [ "$(gl "$G" d1)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d1 "5 forge sessions working" "golive with interactive forge sessions working"
  agents '[{sessionId: "s-1", name: "throughput ship-train Phase 133", state: "working"},
    {sessionId: "s-2", name: "throughput ship-train Phase 7 retry 2", state: "working"},
    {sessionId: "s-3", name: "throughput ship-train Verify", state: "working"},
    {sessionId: "s-4", name: "throughput ship-train Ship", state: "working"}]'
  [ "$(gl "$G" d2)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d2 "4 forge sessions working" "golive with track-feature forge sessions working"
  agents '[{sessionId: "s-1", name: "forge discuss", state: "working"},
    {sessionId: "s-2", name: "forge build throughput/ship-train", state: "working"},
    {sessionId: "s-3", name: "forge quick fix", state: "working"},
    {sessionId: "s-4", name: "forge fast", state: "working"},
    {sessionId: "s-5", name: "forge debug the land", state: "working"},
    {sessionId: "s-6", name: "forge new", state: "working"},
    {sessionId: "s-7", name: "forge audit the land", state: "working"}]'
  [ "$(gl "$G" d3)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d3 "5 forge sessions working" "golive with project-command forge sessions working, forge build and forge audit not counted"
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"},
    {sessionId: "s-2", name: "forge P133R2 throughput/ship-train", state: "working"},
    {sessionId: "s-3", name: "forge verify throughput/ship-train", state: "working"},
    {sessionId: "s-4", name: "forge ship throughput/ship-train", state: "working"},
    {name: "forge ship throughput/admission", state: "working"}]'
  [ "$(gl "$G" d4)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d4 "5 forge sessions working" "golive with phase forge sessions working"
  agents '[{sessionId: "caller-0001", name: "forge ship throughput/ship-train", state: "working"}]'
  [ "$(CLAUDE_CODE_SESSION_ID= gl "$G" d5)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d5 "1 forge sessions working" "golive with an empty session id"
  [ "$(unset CLAUDE_CODE_SESSION_ID; gl "$G" d6)" = 0 ] || fail "a queued golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d6 "1 forge sessions working" "golive without a session id"
  ok "golive defer queues"
fi

if want "golive defer cannot list"; then
  cd "$tmp"
  [ -z "$only" ] || mkGd
  agents '[]'
  [ "$(CLAUDE_AGENTS_EXIT=1 gl "$G" d7)" = 0 ] || fail "golive with a failing claude agents must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d7 "cannot list Claude sessions" "golive with a failing claude agents"
  echo 'the background service did not respond' >"$CLAUDE_AGENTS"
  [ "$(gl "$G" d8)" = 0 ] || fail "golive with non-JSON claude agents must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d8 "cannot list Claude sessions" "golive with non-JSON claude agents"
  echo '{"sessions": []}' >"$CLAUDE_AGENTS"
  [ "$(gl "$G" d9)" = 0 ] || fail "golive with a non-array claude agents must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d9 "cannot list Claude sessions" "golive with a non-array claude agents"
  agents '[]'
  [ "$(CLAUDE_AGENTS_SLEEP=10 FORGE_AGENTS_TIMEOUT=1 gl "$G" d13)" = 0 ] || fail "golive with a stalled claude agents must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d13 "cannot list Claude sessions" "golive with a stalled claude agents"
  ok "golive defer cannot list"
fi

if want "golive defer pending"; then
  cd "$tmp"
  if [ -n "$only" ]; then
    mkGd
    agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
    [ "$(gl "$G" d13)" = 0 ] || fail "the replayed queued golive of d13 must exit 0: $(cat "$tmp/out" "$tmp/err")"
  fi
  gtop=$(git -C "$G" rev-parse --show-toplevel)
  [ "$(wc -l <"$pending")" = 1 ] || fail "the pending file holds one line per repo: $(cat "$pending")"
  jq -e --arg r "$gtop" --arg c "$(git -C "$G" rev-parse main)" \
    'keys == ["branches", "commit", "repo", "root", "time"] and (.branches | index("d13")) != null and .repo == $r and .commit == $c and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    "$pending" >/dev/null || fail "the pending line names the repo, main's full sha and the UTC time: $(cat "$pending")"
  H=$tmp/h
  mkrepo "$H"
  gport "$H"
  git -C "$H" add port && git -C "$H" commit -q -m port
  topic "$H" h1 h1.txt h
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
  [ "$(gl "$H" h1)" = 0 ] || fail "a queued golive of a second repo must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$H" h1 "1 forge sessions working" "golive of a second repo"
  htop=$(git -C "$H" rev-parse --show-toplevel)
  hline=$(jq -c --arg r "$htop" 'select(.repo == $r)' "$pending")
  [ "$(wc -l <"$pending")" = 2 ] && [ -n "$hline" ] || fail "a second repo adds its own pending line: $(cat "$pending")"
  jq -c --arg r "$gtop" 'if .repo == $r then .time = "2026-01-02T03:04:05Z" | .alerted = true else . end' "$pending" >"$tmp/pending"
  mv "$tmp/pending" "$pending"
  [ "$(gl "$G" d10)" = 0 ] || fail "a second queued golive of a repo must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d10 "1 forge sessions working" "a second queued golive of a repo"
  [ "$(wc -l <"$pending")" = 2 ] || fail "a newer queued golive replaces its repo's line: $(cat "$pending")"
  [ "$(jq -r --arg r "$gtop" 'select(.repo == $r) | .commit' "$pending")" = "$(git -C "$G" rev-parse main)" ] \
    || fail "the replaced line names main after the newer land: $(cat "$pending")"
  jq -e --arg r "$gtop" 'select(.repo == $r) | keys == ["branches", "commit", "repo", "root", "time"] and (.branches | index("d10") and index("d13")) and .time == "2026-01-02T03:04:05Z"' "$pending" >/dev/null \
    || fail "a second queued golive of a repo keeps the first time and its branches and drops alerted: $(cat "$pending")"
  [ "$(jq -c --arg r "$htop" 'select(.repo == $r)' "$pending")" = "$hline" ] || fail "another repo's pending line stays: $(cat "$pending")"
  [ -z "$(find "$(dirname "$pending")" -mindepth 1 ! -name port.pending ! -name port.pending.lock)" ] || fail "the pending rewrite leaves no temp file: $(ls -a "$(dirname "$pending")")"
  topic "$G" d12 d12.txt d
  exec 7>"$pending.lock"
  flock 7
  (gl "$G" d12 >"$tmp/gl.s") 7>&- &
  gpid=$!
  for i in $(seq 300); do grep -q "landed d12" "$tmp/out" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
  kill -0 "$gpid" 2>/dev/null || fail "a queued golive waits for port.pending.lock: $(cat "$tmp/out" "$tmp/err")"
  echo '{"repo":"/elsewhere","commit":"c","time":"t"}' >>"$pending"
  exec 7>&-
  wait "$gpid"
  [ "$(cat "$tmp/gl.s")" = 0 ] || fail "a golive queued behind the lock must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d12 "1 forge sessions working" "a golive queued behind the lock"
  [ "$(jq -r 'select(.repo == "/elsewhere") | .commit' "$pending")" = c ] || fail "a line written under the lock stays: $(cat "$pending")"
  [ "$(jq -r --arg r "$gtop" 'select(.repo == $r) | .commit' "$pending")" = "$(git -C "$G" rev-parse main)" ] \
    || fail "a golive queued behind the lock writes its line: $(cat "$pending")"
  agents '[]'
  [ "$(gl "$G" d11)" = 0 ] || fail "golive with no working forge session must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG")" = "$G --apply" ] || fail "golive ports again once no other forge session is working: $(cat "$PORT_LOG" 2>/dev/null)"
  ok "golive defer pending"
fi

BN=$tmp/bn
bport() {
  cat >"$1/port" <<'EOF2'
#!/usr/bin/env bash
echo "$PWD $*" >>"$PORT_LOG"
echo ">f+++++++++ bin/tool"
echo "ported $(git rev-parse --short HEAD)"
[ "$*" != "--apply --only bin" ] || exit "${PORT_BIN_EXIT:-0}"
exit "${PORT_EXIT:-0}"
EOF2
  chmod +x "$1/port"
}
mkBN() {
  mkrepo "$BN"
  mkdir "$BN/bin" && echo t >"$BN/bin/tool"
  bport "$BN"
  git -C "$BN" add -A && git -C "$BN" commit -q -m port
  btop=$(git -C "$BN" rev-parse --show-toplevel)
}
binq() {
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed %s as %s on main\nforge: not pushed: forge.pushMain unset\nforge: ported bin %s\nforge: port queued: %s' "$1" "$(short "$BN" main)" "$(short "$BN" main)" "$2")" ] \
    || fail "$3 ports bin then queues: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG" 2>/dev/null)" = "$BN --apply --only bin" ] || fail "$3 runs ./port --apply --only bin once from the repo top: $(cat "$PORT_LOG" 2>/dev/null)"
  grep -qF ">f+++++++++ bin/tool" "$tmp/err" || fail "$3 sends the bin port's output to stderr: $(cat "$tmp/err")"
  [ "$(jq -r --arg r "$btop" 'select(.repo == $r) | .commit' "$pending")" = "$(git -C "$BN" rev-parse main)" ] \
    || fail "$3 queues the repo's line at main: $(cat "$pending")"
  git -C "$BN" merge-base --is-ancestor "$1" main || fail "$3 keeps the landing"
}
if want "golive bin part"; then
  cd "$tmp"
  [ -z "$only" ] || mkGp
  mkBN
  for b in b1 b2 b3 b4; do topic "$BN" "$b" "$b.txt" b; done
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
  [ "$(gl "$BN" b1)" = 0 ] || fail "a golive porting bin and queuing must exit 0: $(cat "$tmp/out" "$tmp/err")"
  binq b1 "1 forge sessions working" "golive with a forge session working"
  [ "$(CLAUDE_AGENTS_EXIT=1 gl "$BN" b2)" = 0 ] || fail "a golive porting bin with a failing claude agents must exit 0: $(cat "$tmp/out" "$tmp/err")"
  binq b2 "cannot list Claude sessions" "golive with a failing claude agents"
  [ "$(PORT_BIN_EXIT=1 gl "$BN" b3)" = 1 ] || fail "a failing ./port --apply --only bin must exit 1: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed b3 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: port queued: 1 forge sessions working' "$(short "$BN" main)")" ] \
    || fail "a failing bin port prints no ported bin line and still queues: $(cat "$tmp/out" "$tmp/err")"
  grep -qxF "forge: ./port --apply --only bin failed in $btop; port queued" "$tmp/err" || fail "a failing bin port says so: $(cat "$tmp/err")"
  [ "$(cat "$PORT_LOG" 2>/dev/null)" = "$BN --apply --only bin" ] || fail "a failing bin port runs only the bin part: $(cat "$PORT_LOG" 2>/dev/null)"
  [ "$(jq -r --arg r "$btop" 'select(.repo == $r) | .commit' "$pending")" = "$(git -C "$BN" rev-parse main)" ] \
    || fail "a failing bin port still queues the repo's line at main: $(cat "$pending")"
  git -C "$BN" merge-base --is-ancestor b3 main || fail "a failing bin port keeps the landing"
  topic "$BN" b5 b5.txt b
  mv "$pending.lock" "$tmp/lock.saved" && mkdir "$pending.lock"
  [ "$(gl "$BN" b5)" = 1 ] || fail "a golive that cannot queue must exit 1: $(cat "$tmp/out" "$tmp/err")"
  rmdir "$pending.lock" && mv "$tmp/lock.saved" "$pending.lock"
  grep -qF "cannot queue the port in $pending; landed, not ported" "$tmp/err" || fail "a golive that cannot queue says so: $(cat "$tmp/err")"
  [ ! -e "$PORT_LOG" ] || fail "a golive that cannot queue ports no bin: $(cat "$PORT_LOG")"
  git -C "$BN" merge-base --is-ancestor b5 main || fail "a golive that cannot queue keeps the landing"
  agents '[]'
  [ "$(gl "$BN" b4)" = 0 ] || fail "golive of a bin repo with no working session must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$BN" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed b4 as %s on main\nforge: not pushed: forge.pushMain unset\nforge: ported %s' "$sha" "$sha")" ] \
    || fail "golive of a bin repo with no working session ports in full: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG")" = "$BN --apply" ] || fail "golive with no working session runs one full ./port --apply and no --only: $(cat "$PORT_LOG" 2>/dev/null)"
  topic "$G" d14 d14.txt d
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
  [ ! -e "$G/bin" ] || fail "the repo G has no bin/"
  [ "$(gl "$G" d14)" = 0 ] || fail "a queued golive of a repo without bin/ must exit 0: $(cat "$tmp/out" "$tmp/err")"
  queued "$G" d14 "1 forge sessions working" "golive of a repo without bin/"
  agents '[]'
  ok "golive bin part"
fi

BT=$tmp/bt
pjson=$HOME/.local/state/forge/port.json
restat() { jq -n --arg c "$(git -C "$BT" rev-parse "$1")" '{commit: $c, time: "t", bin: {commit: $c, time: "t"}, rest: {commit: $c, time: "t"}}' >"$pjson"; }
held() {
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed %s as %s on main\nforge: not pushed: forge.pushMain unset\nforge: bin held: templates/ or schemas/ changed since the last full port\nforge: port queued: 1 forge sessions working' "$1" "$(short "$BT" main)")" ] \
    || fail "$2 holds bin and queues: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$PORT_LOG" ] || fail "$2 runs no port: $(cat "$PORT_LOG")"
  [ "$(jq -r --arg r "$(git -C "$BT" rev-parse --show-toplevel)" 'select(.repo == $r) | .commit' "$pending")" = "$(git -C "$BT" rev-parse main)" ] \
    || fail "$2 queues the repo's line at main: $(cat "$pending")"
}
if want "golive bin held"; then
  cd "$tmp"
  mkrepo "$BT"
  mkdir "$BT/bin" "$BT/templates" "$BT/schemas"
  echo t >"$BT/bin/tool" && echo r >"$BT/templates/render.jq" && echo s >"$BT/schemas/x.json"
  bport "$BT"
  git -C "$BT" add -A && git -C "$BT" commit -q -m port
  mkdir -p "$(dirname "$pjson")"
  topic "$BT" t1 bin/tool t1
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
  restat main
  [ "$(gl "$BT" t1)" = 0 ] || fail "a bin-only golive must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG" 2>/dev/null)" = "$BT --apply --only bin" ] || fail "a golive changing only bin/ ports bin: $(cat "$tmp/out" "$tmp/err")"
  topic "$BT" t2 templates/render.jq u
  [ "$(gl "$BT" t2)" = 0 ] || fail "a golive changing templates/ must exit 0: $(cat "$tmp/out" "$tmp/err")"
  held t2 "a golive changing templates/"
  topic "$BT" t3 bin/tool v
  [ "$(gl "$BT" t3)" = 0 ] || fail "a bin-only golive after a held templates/ change must exit 0: $(cat "$tmp/out" "$tmp/err")"
  held t3 "a bin-only golive after a held templates/ change"
  restat main
  topic "$BT" t4 bin/tool t4
  [ "$(gl "$BT" t4)" = 0 ] || fail "a bin-only golive after a full port must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG" 2>/dev/null)" = "$BT --apply --only bin" ] || fail "a bin-only golive after a full port ports bin: $(cat "$tmp/out" "$tmp/err")"
  topic "$BT" t5 schemas/x.json w
  [ "$(gl "$BT" t5)" = 0 ] || fail "a golive changing schemas/ must exit 0: $(cat "$tmp/out" "$tmp/err")"
  held t5 "a golive changing schemas/"
  restat main
  rm -f "$pjson"
  topic "$BT" t6 bin/tool x
  [ "$(gl "$BT" t6)" = 0 ] || fail "a golive with no port.json must exit 0: $(cat "$tmp/out" "$tmp/err")"
  held t6 "a golive with no port.json"
  agents '[]'
  ok "golive bin held"
fi

gboth() { local s=0; rm -f "$LAND_LOG" "$tmp/port.log"; "$forge" golive "$@" >"$tmp/both" 2>&1 || s=$?; echo $s; }
once() {
  [ "$(grep -acxF -- "$1" "$tmp/both")" = 1 ] || fail "$2 holds '$1' exactly once in a file taking both stdout and stderr: $(cat -v "$tmp/both")"
}
whole() {
  [ "$(tr -d '\000' <"$tmp/both" | wc -c)" = "$(wc -c <"$tmp/both")" ] || fail "$1 leaves no truncated hole in a file taking both stdout and stderr: $(cat -v "$tmp/both")"
}
before() {
  local a b
  a=$(grep -anxF -- "$1" "$tmp/both" | cut -d: -f1 || true) b=$(grep -anxF -- "$2" "$tmp/both" | cut -d: -f1 || true)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$3 prints '$1' before '$2': $(cat -v "$tmp/both")"
}
if want "golive shared output file"; then
  cd "$tmp"
  if [ -n "$only" ]; then mkGp; mkBN; fi
  topic "$G" o1 o1.txt o
  [ "$(gboth "$G" o1)" = 0 ] || fail "golive into one shared file must exit 0: $(cat -v "$tmp/both")"
  sha=$(short "$G" main)
  whole "golive with port"
  once "forge: landed o1 as $sha on main" "golive with port"
  once "forge: not pushed: forge.pushMain unset" "golive with port"
  once ">f+++++++++ skills/x" "golive with port"
  once "ported $sha" "golive with port"
  once "forge: ported $sha" "golive with port"
  before "forge: landed o1 as $sha on main" "forge: not pushed: forge.pushMain unset" "golive with port"
  before "forge: not pushed: forge.pushMain unset" "forge: ported $sha" "golive with port"
  topic "$BN" o2 o2.txt o
  agents '[{sessionId: "s-1", name: "forge P133 throughput/ship-train", state: "working"}]'
  [ "$(gboth "$BN" o2)" = 0 ] || fail "a queued golive into one shared file must exit 0: $(cat -v "$tmp/both")"
  agents '[]'
  sha=$(short "$BN" main)
  whole "a queued golive porting bin"
  once "forge: landed o2 as $sha on main" "a queued golive porting bin"
  once "forge: not pushed: forge.pushMain unset" "a queued golive porting bin"
  once ">f+++++++++ bin/tool" "a queued golive porting bin"
  once "ported $sha" "a queued golive porting bin"
  once "forge: ported bin $sha" "a queued golive porting bin"
  once "forge: port queued: 1 forge sessions working" "a queued golive porting bin"
  before "forge: landed o2 as $sha on main" "forge: not pushed: forge.pushMain unset" "a queued golive porting bin"
  before "forge: ported bin $sha" "forge: port queued: 1 forge sessions working" "a queued golive porting bin"
  ok "golive shared output file"
fi

pushP() { mkP; git -C "$P" config forge.pushMain true; }
if want "golive push"; then
  cd "$tmp"
  [ -z "$only" ] || pushP
  topic "$P" pg pg.txt p
  [ "$(gl "$P" pg)" = 0 ] || fail "golive with pushMain must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$P" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed pg as %s on main\nforge: pushed %s to origin\nforge: no port' "$sha" "$sha")" ] \
    || fail "golive with pushMain prints landed, pushed, no port: $(cat "$tmp/out")"
  ok "golive push"
fi

prmerge() {
  git -C "$Q" fetch -q origin
  git -C "$Q" checkout -q main
  git -C "$Q" reset -q --hard origin/main
  git -C "$Q" merge -q --no-ff -m "Merge pull request from $1" "origin/$1"
  git -C "$Q" push -q origin main
}
if want "land fast-forward"; then
  cd "$tmp"
  [ -z "$only" ] || pushP
  topic "$P" pm pm.txt m
  git -C "$P" push -q origin pm
  prmerge pm
  om=$(git -C "$O" rev-parse main) before=$(git -C "$P" rev-parse main)
  [ "$(ld "$P" pm)" = 0 ] || fail "land of a branch merged on origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git -C "$P" rev-parse main)" = "$om" ] || fail "land fast-forwards main to origin/main with no new commit: $(git -C "$P" log --format=%s "$om..main")"
  ! git -C "$P" log --format=%s "$before..main" | grep -q "Merge origin/main" || fail "a fast-forward land makes no Merge origin/main commit"
  ! git -C "$P" log --format=%s "$before..main" | grep -q "Merge branch 'pm'" || fail "a fast-forward land makes no branch merge commit"
  [ "$(git -C "$O" rev-parse main)" = "$om" ] || fail "land pushes nothing when origin already has main"
  grep -qx "forge: landed pm as $(short "$P" "$om") on main" "$tmp/out" || fail "a fast-forward land prints the landed line: $(cat "$tmp/out")"
  ! grep -q "^forge: pushed" "$tmp/out" || fail "a fast-forward land prints no pushed line: $(cat "$tmp/out")"
  grep -q "nothing to push" "$tmp/out" || fail "a fast-forward land says there is nothing to push: $(cat "$tmp/out")"
  grep -qx "forge: deleted origin/pm" "$tmp/out" || fail "a fast-forward land still deletes the merged branch on origin: $(cat "$tmp/out" "$tmp/err")"
  ! git -C "$O" show-ref -q --verify refs/heads/pm || fail "a fast-forward land deletes origin/pm"
  ok "land fast-forward"
fi

if want "land ahead of origin"; then
  cd "$tmp"
  [ -z "$only" ] || pushP
  topic "$P" pn pn.txt n
  git -C "$P" push -q origin pn
  prmerge pn
  echo l >"$P/local.txt" && git -C "$P" add local.txt && git -C "$P" commit -q -m local
  om=$(git -C "$O" rev-parse main) before=$(git -C "$P" rev-parse main)
  [ "$(ld "$P" pn)" = 0 ] || fail "land of a merged branch with local main ahead must exit 0: $(cat "$tmp/out" "$tmp/err")"
  git -C "$P" merge-base --is-ancestor "$om" main && git -C "$P" merge-base --is-ancestor "$before" main || fail "land merges origin/main into a main that is ahead"
  ! git -C "$P" log --format=%s "$before..main" | grep -q "Merge branch 'pn'" || fail "land makes no branch merge commit for a branch origin/main holds"
  [ "$(git -C "$O" rev-parse main)" = "$(git -C "$P" rev-parse main)" ] || fail "land pushes main when local main is ahead of origin/main"
  grep -qx "forge: pushed $(short "$P" main) to origin" "$tmp/out" || fail "land with local main ahead prints the pushed line: $(cat "$tmp/out")"
  grep -qx "forge: deleted origin/pn" "$tmp/out" || fail "land with local main ahead deletes origin/pn: $(cat "$tmp/out" "$tmp/err")"
  ok "land ahead of origin"
fi

if want "golive nothing to push"; then
  cd "$tmp"
  [ -z "$only" ] || pushP
  topic "$P" po po.txt o
  git -C "$P" push -q origin po
  prmerge po
  om=$(git -C "$O" rev-parse main)
  [ "$(gl "$P" po)" = 0 ] || fail "golive of a branch merged on origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git -C "$P" rev-parse main)" = "$om" ] && [ "$(git -C "$O" rev-parse main)" = "$om" ] || fail "golive fast-forwards main and pushes nothing"
  grep -qx "forge: not pushed: nothing to push" "$tmp/out" || fail "golive prints not pushed: nothing to push: $(cat "$tmp/out" "$tmp/err")"
  ! grep -q "pushing main to origin failed" "$tmp/out" "$tmp/err" || fail "golive with nothing to push reports no push failure: $(cat "$tmp/out" "$tmp/err")"
  grep -qx "forge: no port" "$tmp/out" || fail "golive with nothing to push still reaches port: $(cat "$tmp/out")"
  ! git -C "$O" show-ref -q --verify refs/heads/po || fail "golive deletes origin/po"
  ok "golive nothing to push"
fi

if want "golive car refusals"; then
  cd "$tmp"
  [ -z "$only" ] || mkP
  for a in "land $P a b" "golive $P a b" "golive $P a b c"; do
    s=0; "$forge" $a >/dev/null 2>&1 || s=$?
    [ "$s" = 2 ] || fail "$a must exit 2, got $s"
  done
  ok "golive car refusals"
fi

onorigin() {
  git -C "$Q" fetch -q origin && git -C "$Q" checkout -q main && git -C "$Q" reset -q --hard origin/main
  echo "$1" >"$Q/$1.txt" && git -C "$Q" add -A && git -C "$Q" commit -q -m "$1" && git -C "$Q" push -q origin main
}
if want "landed tree stamp"; then
  cd "$tmp"
  if [ -n "$only" ]; then pushP; C=$tmp/c; mkrepo "$C"; fi
  topic "$P" ps ps.txt s
  git -C "$P" push -q origin ps
  onorigin ps-other
  prmerge ps
  om=$(git -C "$O" rev-parse main) tree=$(git -C "$O" rev-parse "main^{tree}")
  mkdir -p "$P/.git/forge-test/$hid" && : >"$P/.git/forge-test/$hid/$tree"
  [ "$(ld "$P" ps)" = 0 ] || fail "land to a stamped landed tree must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git -C "$P" rev-parse main)" = "$om" ] || fail "land to a stamped landed tree fast-forwards main"
  [ "$(calls)" = 0 ] || fail "a full pass of the landed tree from another commit skips land's tests: $(cat "$LAND_LOG")"
  grep -qxF "forge: tests passed ($(git -C "$P" rev-parse --short "$tree")), cached" "$tmp/err" || fail "a landed-tree cached land says so: $(cat "$tmp/err")"
  topic "$P" pu pu.txt u
  git -C "$P" push -q origin pu
  onorigin pu-other
  prmerge pu
  tree=$(git -C "$O" rev-parse "main^{tree}")
  mkdir -p "$P/.git/forge-test/$hid/changed" && : >"$P/.git/forge-test/$hid/changed/$tree"
  [ "$(ld "$P" pu)" = 0 ] && [ "$(calls)" = 1 ] || fail "a changed-tests pass of the landed tree is no full pass for land: $(cat "$LAND_LOG" "$tmp/err")"
  stamp sn .
  echo o >"$C/other2.txt" && git -C "$C" add other2.txt && git -C "$C" commit -q -m other2
  tree=$(git -C "$C" merge-tree --write-tree main sn)
  : >"$C/.git/forge-test/$hid/$tree"
  [ "$(ld "$C" sn)" = 0 ] && [ "$(calls)" = 0 ] || fail "a full pass of the merge's tree skips land's tests though main moved outside .forge: $(cat "$LAND_LOG" "$tmp/err")"
  [ "$(git -C "$C" rev-parse "main^{tree}")" = "$tree" ] || fail "the landed merge has the stamped tree"
  ok "landed tree stamp"
fi

RP=$tmp/rp
A=$RP/app
if want "golive ports directly"; then
  cd "$tmp"
  mkdir -p "$RP/.forge/tracks" "$RP/.forge/features/aa-one"
  git init -q --bare -b main "$tmp/app-origin.git"
  mkrepo "$A"
  gport "$A"
  git -C "$A" add port && git -C "$A" commit -q -m port
  git -C "$A" remote add origin "$tmp/app-origin.git"
  git -C "$A" push -q -u origin main
  git -C "$A" config forge.pushMain true
  jq -n '{repos: [{repo: "app", workflow: "deploy.yml", window: {days: ["mon", "tue", "wed", "thu", "fri"], start: "09:00", end: "17:00", tz: "UTC"}, live_sha: "cat live.txt"}]}' >"$RP/.forge/release.json"
  jq -n '{track: "aa", goal: "g", status: "open", notes: [], features: [{feature: "one", delivers: "d", depends: []}], shipped: []}' >"$RP/.forge/tracks/aa.json"
  reqs='{"requirements": [{"id": "AAA-01", "text": "one ships", "done": false, "owed": {"kind": "deferred", "check": "prod serves one", "owner": "aa/one", "until": "release"}}]}'
  jq . <<<"$reqs" >"$RP/.forge/features/aa-one/requirements.json"
  printf '%s\n' '# Todo' '' '- aa/one AAA-01 owes deferred: prod serves one' >"$RP/.forge/todo.md"
  todo=$(cat "$RP/.forge/todo.md")
  topic "$A" forge/aa-one aa.txt a
  cd "$RP"
  [ "$(FORGE_NOW="2026-09-30 12:00 UTC" gl app forge/aa-one)" = 0 ] || fail "golive with a release.json entry inside its window must exit 0: $(cat "$tmp/out" "$tmp/err")"
  sha=$(short "$A" main)
  [ "$(cat "$tmp/out")" = "$(printf 'forge: landed forge/aa-one as %s on main\nforge: pushed %s to origin\nforge: ported %s' "$sha" "$sha" "$sha")" ] \
    || fail "golive ports directly, naming no release window: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$PORT_LOG")" = "$A --apply" ] || fail "golive inside a release.json window runs ./port --apply: $(cat "$PORT_LOG" 2>/dev/null)"
  jq -e --argjson w "$reqs" '. == $w' "$RP/.forge/features/aa-one/requirements.json" >/dev/null \
    || fail "golive leaves until: release requirements owed: $(cat "$RP/.forge/features/aa-one/requirements.json")"
  [ "$(cat "$RP/.forge/todo.md")" = "$todo" ] || fail "golive leaves todo.md unchanged: $(cat "$RP/.forge/todo.md")"
  for w in release.json 'until: release' 'queued for the' 'working hours' FORGE_NOW; do
    ! grep -qF -- "$w" "$root/bin/forge.d/help/golive.txt" || fail "help/golive.txt still names $w"
  done
  ok "golive ports directly"
fi
cd "$tmp"

cat >"$tmp/bin/claude" <<'EOF2'
#!/usr/bin/env bash
case $1 in
  agents) cat "$CLAUDE_AGENTS"; [ -z "${AGENTS_HOOK:-}" ] || "$AGENTS_HOOK" ;;
  rm)
    echo "$2" >>"$CLAUDE_RM_LOG"
    jq --arg i "$2" 'map(select(.id != $i))' "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.new" && mv "$CLAUDE_AGENTS.new" "$CLAUDE_AGENTS" ;;
  *) exit 1 ;;
esac
EOF2
chmod +x "$tmp/bin/claude"
export PATH=$tmp/bin:$PATH CLAUDE_AGENTS=$tmp/agents.json CLAUDE_RM_LOG=$tmp/rm.log
Z=$tmp/z
wts=$Z/.claude/worktrees jobs=$HOME/.claude/jobs/abc/tmp elsewhere=$tmp/elsewhere
wt() {
  local name=$1 path=$2 how=$3
  git -C "$Z" worktree add -q -b "forge/$name" "$path" main
  [ "$how" = fresh ] && return
  echo "$name" >"$path/$name.txt"
  git -C "$path" add -A && git -C "$path" commit -q -m "$name"
  [ "$how" = merged ] && git -C "$Z" merge -q --no-ff -m "merge $name" "forge/$name"
  return 0
}
mkZ() {
  mkrepo "$Z"
  wt m1 "$wts/m1" merged
  wt u1 "$wts/u1" unmerged
  wt d1 "$wts/d1" merged && echo dirty >>"$wts/d1/d1.txt"
  wt n1 "$wts/n1" merged && echo new >"$wts/n1/untracked.txt"
  wt fr "$wts/fr" fresh
  git -C "$Z" worktree add -q --detach "$wts/_land" main
  wt job "$jobs/job" merged
  wt out "$elsewhere" merged
  wt live "$wts/live" merged
  wt gone "$wts/gone" unmerged && rm -rf "$wts/gone"
  wt b1 "$tmp/b1" merged && git -C "$Z" worktree remove "$tmp/b1"
  wt b2 "$tmp/b2" unmerged && git -C "$Z" worktree remove "$tmp/b2"
  git -C "$Z" branch forge/bfresh main
  printf '.env\nnode_modules/\n.serena/\n.impeccable/\n' >>"$Z/.git/info/exclude"
  wt ig "$wts/ig" merged && echo secret >"$wts/ig/.env"
  wt tc "$wts/tc" merged && mkdir -p "$wts/tc/node_modules/x" "$wts/tc/web/node_modules" "$wts/tc/.serena" "$wts/tc/.impeccable" && touch "$wts/tc/node_modules/x/a" "$wts/tc/web/node_modules/b" "$wts/tc/.serena/c" "$wts/tc/.impeccable/d"
  wt crm-open "$tmp/co" merged && git -C "$Z" worktree remove "$tmp/co"
  wt crm-wip "$wts/crm-wip" merged
  rm -rf "$XDG_STATE_HOME/forge/z"
  mkdir -p "$Z/.forge" "$XDG_STATE_HOME/forge/z/features/crm-open" "$XDG_STATE_HOME/forge/z/features/crm-wip" "$XDG_STATE_HOME/forge/z/archive/crm-old"
  git -C "$Z" branch feature/x forge/m1
  jq -n --arg cwd "$wts/live/sub" '[{id: "l1", name: "z P01 crm/live", state: "working", cwd: $cwd},
    {id: "s1", name: "z ship crm/old", state: "done", status: "idle"}, {id: "s2", name: "z P03R1 crm/old", state: "crashed"},
    {id: "s3", name: "z verify crm/old", state: "blocked"}, {id: "s4", name: "z P04 crm/old", state: "working"},
    {id: "s5", name: "z ship crm/wip", state: "done"}, {id: "s6", name: "zz ship crm/old", state: "done"},
    {id: "s7", name: "z crm-old Review", state: "done"}, {id: "s8", name: "z ship crm/never", state: "done"}, {id: "s10", name: "z ship crm/old"},
    {id: "s11", name: "z crm-old Phase 05", state: "done", status: "idle"}, {id: "s12", name: "z crm-old Verify", state: "working"},
    {id: "s13", name: "z crm-wip Ship", state: "done"}, {id: "s14", name: "zz crm-old Phase 05", state: "done"}]' >"$CLAUDE_AGENTS"
}
snapshot() { { git -C "$Z" worktree list --porcelain; git -C "$Z" branch --format='%(refname)'; } >"$tmp/$1"; }
gc() { local s=0; (cd "$Z" && "$forge" gc "$@") >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }

if want_any "gc dry run" "gc apply" "gc confirmed"; then mkZ; fi

if want "gc dry run"; then
  cd "$tmp"
  snapshot before
  [ "$(gc)" = 0 ] || fail "gc dry run must exit 0: $(cat "$tmp/out" "$tmp/err")"
  snapshot after
  cmp -s "$tmp/before" "$tmp/after" || fail "gc dry run must change nothing"
  [ ! -e "$CLAUDE_RM_LOG" ] || fail "gc dry run removes no session: $(cat "$CLAUDE_RM_LOG")"
  want=$(printf '%s\n' "prune gone" "worktree $wts/m1 forge/m1" "worktree $jobs/job forge/job" "worktree $wts/tc forge/tc" "branch forge/b1" "branch forge/job" "branch forge/m1" "branch forge/tc" "session s1 z ship crm/old" "session s2 z P03R1 crm/old" "session s11 z crm-old Phase 05" | sort)
  [ "$(grep -v '^(dry run' "$tmp/out" | sed 's/^\(prune [^ :]*\).*/\1/' | sort)" = "$want" ] || fail "gc dry run lists exactly the collectable targets: $(cat "$tmp/out")"
  ok "gc dry run"
fi

if want "gc apply"; then
  cd "$tmp"
  [ "$(gc --apply)" = 0 ] || fail "gc --apply removes its targets and exits 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$CLAUDE_RM_LOG")" = "$(printf 's1\ns2\ns11')" ] || fail "gc removes only the idle sessions of archived features of this project, legacy-named ones included: $(cat "$CLAUDE_RM_LOG")"
  for p in "$wts/m1" "$jobs/job" "$wts/tc"; do [ ! -e "$p" ] || fail "gc removes $p"; done
  for p in "$wts/u1" "$wts/d1" "$wts/n1" "$wts/fr" "$wts/_land" "$tmp/elsewhere" "$wts/live" "$wts/crm-wip"; do [ -d "$p" ] || fail "gc keeps $p"; done
  [ "$(cat "$wts/d1/d1.txt")" = "$(printf 'd1\ndirty')" ] || fail "gc keeps dirty work"
  [ "$(cat "$wts/ig/.env")" = secret ] || fail "gc keeps a worktree holding ignored files other than tool caches"
  [ "$(git -C "$Z" branch --format='%(refname:short)' | sort | paste -sd ' ')" = "feature/x forge/b2 forge/bfresh forge/crm-open forge/crm-wip forge/d1 forge/fr forge/gone forge/ig forge/live forge/n1 forge/out forge/u1 main" ] \
    || fail "gc deletes only merged forge branches with no worktree: $(git -C "$Z" branch --format='%(refname:short)' | paste -sd ' ')"
  ! git -C "$Z" worktree list --porcelain | grep -q "$wts/gone" || fail "gc prunes a missing worktree"
  [ "$(gc)" = 0 ] && [ "$(cat "$tmp/out")" = "forge: nothing to collect" ] || fail "a second gc finds nothing: $(cat "$tmp/out" "$tmp/err")"
  ok "gc apply"
fi

if want "gc confirmed"; then
  cd "$tmp"
  if [ -n "$only" ]; then [ "$(gc --apply)" = 0 ] || fail "the replayed gc --apply must exit 0: $(cat "$tmp/out" "$tmp/err")"; fi
  wt c1 "$wts/c1" merged
  jq '. + [{id: "s9", name: "z ship crm/old", state: "done"}, {id: "s15", name: "z P02 crm/old", state: "done"}]' "$CLAUDE_AGENTS" >"$tmp/a" && mv "$tmp/a" "$CLAUDE_AGENTS"
  printf '#!/usr/bin/env bash\njq %s "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.new" && mv "$CLAUDE_AGENTS.new" "$CLAUDE_AGENTS"\n' "'map(if .id == \"s9\" then .state = \"working\" end)'" >"$tmp/bin/wake"
  chmod +x "$tmp/bin/wake"
  rm -f "$CLAUDE_RM_LOG"
  [ "$(AGENTS_HOOK=$tmp/bin/wake gc --confirmed)" = 0 ] || fail "gc --confirmed must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$wts/c1" ] && ! git -C "$Z" show-ref -q --verify refs/heads/forge/c1 || fail "gc --confirmed removes the merged worktree and its branch as --apply does"
  grep -qxF "session s9 z ship crm/old" "$tmp/out" && [ "$(cat "$CLAUDE_RM_LOG")" = s15 ] || fail "gc keeps a session that started working since the scan and removes the rest: $(cat "$tmp/out") rm: $(cat "$CLAUDE_RM_LOG")"
  grep -qF "forge: session z ship crm/old changed since the scan; kept" "$tmp/err" || fail "gc says it kept the session: $(cat "$tmp/err")"
  ok "gc confirmed"
fi

ng() { local s=0; (cd "$jobs/job" && FORGE_ROOT=$Z "$forge" gc "$@") >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
if want "gc no origin"; then
  cd "$tmp"
  Z=$tmp/no/z wts=$tmp/no/z/.claude/worktrees jobs=$HOME/.claude/jobs/no/tmp elsewhere=$tmp/no/elsewhere
  mkdir -p "$tmp/no"
  mkZ
  ! git -C "$Z" remote get-url origin >/dev/null 2>&1 || fail "gc no origin: the repo has no origin remote"
  rm -f "$CLAUDE_RM_LOG"
  snapshot before
  [ "$(ng)" = 0 ] || fail "gc dry run with no origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  snapshot after
  cmp -s "$tmp/before" "$tmp/after" || fail "gc dry run with no origin must change nothing"
  want=$(printf '%s\n' "prune gone" "worktree $wts/m1 forge/m1" "worktree $wts/tc forge/tc" "branch forge/b1" "branch forge/m1" "branch forge/tc" "session s1 z ship crm/old" "session s2 z P03R1 crm/old" "session s11 z crm-old Phase 05" | sort)
  [ "$(grep -v '^(dry run' "$tmp/out" | sed 's/^\(prune [^ :]*\).*/\1/' | sort)" = "$want" ] || fail "gc with no origin lists the local targets against local main and keeps the start dir worktree: $(cat "$tmp/out")"
  ! grep -qE '^(remote|stale) ' "$tmp/out" || fail "gc with no origin lists no remote or stale target: $(cat "$tmp/out")"
  ! grep -qE 'cannot fetch origin|^forge: warning' "$tmp/err" || fail "gc dry run with no origin prints no remote warning: $(cat "$tmp/err")"
  [ "$(ng --apply)" = 0 ] || fail "gc --apply with no origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  ! grep -qE 'cannot fetch origin|^forge: warning' "$tmp/err" || fail "gc --apply with no origin prints no remote warning: $(cat "$tmp/err")"
  ! grep -qE '^(remote|stale) ' "$tmp/out" || fail "gc --apply with no origin lists no remote or stale target: $(cat "$tmp/out")"
  [ "$(cat "$CLAUDE_RM_LOG")" = "$(printf 's1\ns2\ns11')" ] || fail "gc with no origin removes the idle sessions of archived features: $(cat "$CLAUDE_RM_LOG")"
  for p in "$wts/m1" "$wts/tc"; do [ ! -e "$p" ] || fail "gc with no origin removes $p"; done
  for p in "$jobs/job" "$wts/u1" "$wts/d1" "$wts/n1" "$wts/fr" "$wts/_land" "$elsewhere" "$wts/live" "$wts/crm-wip" "$wts/ig"; do [ -d "$p" ] || fail "gc with no origin keeps $p"; done
  [ "$(cat "$wts/d1/d1.txt")" = "$(printf 'd1\ndirty')" ] || fail "gc with no origin keeps dirty work"
  [ "$(git -C "$Z" branch --format='%(refname:short)' | sort | paste -sd ' ')" = "feature/x forge/b2 forge/bfresh forge/crm-open forge/crm-wip forge/d1 forge/fr forge/gone forge/ig forge/job forge/live forge/n1 forge/out forge/u1 main" ] \
    || fail "gc with no origin deletes only merged forge branches against local main: $(git -C "$Z" branch --format='%(refname:short)' | paste -sd ' ')"
  ! git -C "$Z" worktree list --porcelain | grep -q "$wts/gone" || fail "gc with no origin prunes a missing worktree"
  [ "$(ng)" = 0 ] && [ "$(cat "$tmp/out")" = "forge: nothing to collect" ] && [ ! -s "$tmp/err" ] || fail "a second gc with no origin finds nothing and warns nothing: $(cat "$tmp/out" "$tmp/err")"
  ok "gc no origin"
fi

Y=$tmp/y YO=$tmp/y.git
yg() { local s=0; (cd "$Y" && "$forge" gc "$@") >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
if want "gc remote"; then
  cd "$tmp"
  git init -q --bare -b main "$YO"
  mkrepo "$Y"
  git -C "$Y" remote add origin "$YO"
  topic "$Y" forge/rm1 rm1.txt r1
  topic "$Y" forge/rm2 rm2.txt r2
  topic "$Y" forge/crm-open co.txt co
  git -C "$Y" merge -q --no-ff -m m1 forge/rm1
  git -C "$Y" merge -q --no-ff -m m2 forge/crm-open
  git -C "$Y" push -q origin main forge/rm1 forge/rm2 forge/crm-open forge/rm1:refs/heads/forge/gone
  git -C "$Y" branch -D -q forge/rm1 forge/rm2 forge/crm-open
  topic "$Y" forge/rm3 rm3.txt r3
  git -C "$Y" push -q origin forge/rm3 main:refs/heads/forge/fresh
  git -C "$Y" merge -q --no-ff -m m3 forge/rm3
  git -C "$Y" branch -D -q forge/rm3
  git -C "$Y" fetch -q origin
  git --git-dir="$YO" branch -D -q forge/gone
  rm -rf "$XDG_STATE_HOME/forge/y"
  mkdir -p "$Y/.forge" "$XDG_STATE_HOME/forge/y/features/crm-open"
  git -C "$Y" config fetch.prune true
  [ "$(yg)" = 0 ] || fail "gc dry run with an origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(grep -v '^(dry run' "$tmp/out" | sort)" = "$(printf 'remote forge/rm1\nstale origin/forge/gone')" ] || fail "gc lists merged origin branches and stale tracking refs: $(cat "$tmp/out")"
  [ "$(git --git-dir="$YO" for-each-ref --format='%(refname:short)' refs/heads/forge | sort | paste -sd ' ')" = "forge/crm-open forge/fresh forge/rm1 forge/rm2 forge/rm3" ] || fail "gc dry run deletes nothing on origin"
  git -C "$Y" show-ref -q --verify refs/remotes/origin/forge/gone || fail "gc dry run keeps the stale tracking ref"
  [ "$(yg --apply)" = 0 ] || fail "gc --apply with an origin must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(git --git-dir="$YO" for-each-ref --format='%(refname:short)' refs/heads/forge | sort | paste -sd ' ')" = "forge/crm-open forge/fresh forge/rm2 forge/rm3" ] \
    || fail "gc deletes only origin branches merged into origin/main, not fresh ones, of no open feature: $(git --git-dir="$YO" for-each-ref --format='%(refname:short)' refs/heads/forge)"
  ! git -C "$Y" show-ref -q --verify refs/remotes/origin/forge/gone || fail "gc prunes the stale tracking ref"
  git -C "$Y" remote set-url origin "$tmp/nowhere.git"
  [ "$(yg)" = 0 ] || fail "gc with an unreachable origin must still exit 0: $(cat "$tmp/out" "$tmp/err")"
  grep -q "cannot fetch origin" "$tmp/err" || fail "gc warns when origin is unreachable: $(cat "$tmp/err")"
  ok "gc remote"
fi

X=$tmp/x xt=$tmp/x/.claude/worktrees
xg() { local s=0; (cd "$X" && "$forge" gc "$@") >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
if want "gc impeccable files"; then
  cd "$tmp"
  mkrepo "$X"
  printf '%s\n' .impeccable/hook.cache.json .impeccable/hook.pending.json web/.impeccable/hook.cache.json .serena/project.yml node_modules/a >>"$X/.git/info/exclude"
  for n in imp ser nm; do
    git -C "$X" worktree add -q -b "forge/$n" "$xt/$n" main
    echo "$n" >"$xt/$n/$n.txt"
    git -C "$xt/$n" add -A && git -C "$xt/$n" commit -q -m "$n"
    git -C "$X" merge -q --no-ff -m "merge $n" "forge/$n"
  done
  mkdir -p "$xt/imp/.impeccable" "$xt/imp/web/.impeccable" "$xt/ser/.serena" "$xt/nm/node_modules"
  echo '{}' >"$xt/imp/.impeccable/hook.cache.json"
  echo '{}' >"$xt/imp/.impeccable/hook.pending.json"
  echo '{}' >"$xt/imp/web/.impeccable/hook.cache.json"
  touch "$xt/ser/.serena/project.yml" "$xt/nm/node_modules/a"
  [ "$(xg)" = 0 ] || fail "gc dry run with ignored .impeccable/ files must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(grep -v '^(dry run' "$tmp/out" | sort)" = "$(printf '%s\n' "branch forge/imp" "worktree $xt/imp forge/imp" | sort)" ] \
    || fail "gc collects a merged worktree whose only ignored files are under .impeccable/ and keeps ones holding single ignored .serena/ or node_modules/ files: $(cat "$tmp/out")"
  [ "$(xg --confirmed)" = 0 ] || fail "gc --confirmed with ignored .impeccable/ files must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$xt/imp" ] || fail "gc removes $xt/imp"
  for p in "$xt/ser" "$xt/nm"; do [ -d "$p" ] || fail "gc keeps $p"; done
  ok "gc impeccable files"
fi

if want "land perf log no pull"; then
  cd "$tmp"
  for v in land golive; do
    r=$tmp/pl-$v b=pl l="$v in a repo with a Perf log line"
    mkrepo "$r"
    mkdir -p "$r/.forge"
    printf '# Testing\n\n- All tests: `true`\n- Perf tests: `true`\n- Perf log: `touch %s`\n' "$tmp/pl-$v.ran" >"$r/.forge/TESTING.md"
    git -C "$r" add .forge/TESTING.md && git -C "$r" commit -q -m testing
    topic "$r" "$b" "$b.txt" p
    s=0; rm -f "$LAND_LOG"; "$forge" "$v" "$r" "$b" >"$tmp/out" 2>"$tmp/err" || s=$?
    [ "$s" = 0 ] || fail "$l must exit 0: $(cat "$tmp/out" "$tmp/err")"
    [ "$(git -C "$r" log -1 --format=%s main)" = "Merge branch '$b'" ] || fail "$l: main ends at the merge of $b, with no perf commit: $(git -C "$r" log --oneline -3 main)"
    [ ! -e "$tmp/pl-$v.ran" ] || fail "$l runs no Perf log command"
    [ ! -e "$r/.forge/perf.json" ] || fail "$l writes no .forge/perf.json"
    ! grep -q 'perf' "$tmp/out" "$tmp/err" || fail "$l prints no perf pull line: $(cat "$tmp/out" "$tmp/err")"
    [ "$(head -n1 "$tmp/out")" = "forge: landed $b as $(short "$r" main) on main" ] || fail "$l: stdout starts with the landed line: $(cat "$tmp/out")"
    [ "$v" = land ] || [ "$(tail -n1 "$tmp/out")" = "forge: no port" ] || fail "$l: golive still reaches its port step: $(cat "$tmp/out")"
  done
  ok "land perf log no pull"
fi

[ -z "$only" ] || fail "no case $only"
