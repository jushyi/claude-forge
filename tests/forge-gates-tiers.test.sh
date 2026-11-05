#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"
suite=forge-gates-tiers
. "$(dirname "$0")/forge-gates-common.sh"
mkdir -p "$tmp/psleep"
rs=$(command -v sleep)
cat >"$tmp/psleep/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$tmp/sleeps"
exec "$rs" "\$@"
EOF
chmod +x "$tmp/psleep/sleep"
pset() { if [ "$1" = unset ]; then pa=(-u FORGE_TEST_POLL_SECS); else pa=("FORGE_TEST_POLL_SECS=$1"); fi; : >"$tmp/sleeps"; rm -f "$tmp/now"; }
polled() { local w=$2 o=0.02; [ "$1" = unset ] || [ -z "$1" ] || { w=$1; o=$2; }; grep -qxF -- "$w" "$tmp/sleeps" && ! grep -qxF -- "$o" "$tmp/sleeps"; }

if want test-tiers; then
cd "$x"
[ "$(code "$forge" test --changed)" = 0 ] || fail "--changed with no changed files passes: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests passed ($(xshort)), no changed files" ] || fail "--changed names the empty change: $(lastline)"
[ -z "$(ran)" ] || fail "--changed with no changed files runs nothing: $(ran)"
[ -f "$st/$hid/changed/$(xtree)" ] && [ ! -e "$st/$hid/$(xtree)" ] || fail "--changed records a changed stamp only"
[ "$(code "$forge" test --passed --changed)" = 0 ] || fail "--passed --changed accepts a changed stamp: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed needs a full pass"
rm "$st/$hid/changed/$(xtree)"
echo b >>"$x/a.txt" && echo c >"$x/b c.txt" && git -C "$x" add -A && git -C "$x" commit -q -m b
echo u >"$x/u.txt" && echo i >"$x/i.log"
[ "$(code "$forge" test --changed)" = 0 ] || fail "--changed runs the Changed tests line: $(cat "$tmp/out")"
[ "$(ran)" = "[changed][a.txt][b c.txt][u.txt]" ] || fail "--changed passes each changed, uncommitted and untracked path quoted, never an ignored one: $(ran)"
grep -qxF "ran changed a.txt b c.txt u.txt" "$x/.git/forge-test.log" || fail "--changed logs to the git dir: $(cat "$x/.git/forge-test.log")"
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 0 ] || fail "a cached --changed passes: $(cat "$tmp/out")"
[[ "$(lastline)" == "forge: tests passed ("*"), cached" ]] || fail "a cached run says so: $(lastline)"
[ -z "$(ran)" ] || fail "a cached --changed runs nothing: $(ran)"
[ "$(code "$forge" test --changed --force)" = 0 ] && [ -n "$(ran)" ] || fail "--force reruns: $(ran)"
git -C "$x" add u.txt && git -C "$x" commit -q -m u
[ "$(code "$forge" test --passed --changed)" = 0 ] || fail "the changed stamp covers the untracked file once committed: $(cat "$tmp/out")"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force --base side~1)" = 0 ] && [ "$(ran)" = "[changed][u.txt]" ] || fail "--base diffs against its merge base: $(ran)"
echo e >>"$x/a.txt" && echo s >"$x/s.txt" && git -C "$x" add s.txt && rm "$x/b c.txt" && echo n >"$x/n.txt"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force --base side~1)" = 0 ] && [ "$(ran | tr '[]' '\n\n' | sed '/^$/d' | sort | paste -sd'|')" = "a.txt|b c.txt|changed|n.txt|s.txt|u.txt" ] || fail "--changed passes the unstaged edit, the staged file, the deleted file and the untracked file, never an ignored one: $(ran)"
git -C "$x" reset -q --hard && rm -f "$x/n.txt"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force --base nope)" = 1 ] && [ -z "$(ran)" ] || fail "an unknown base exits 1: $(cat "$tmp/out")"
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force)" = 3 ] || fail "a failing changed run exits with its code"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "forge test runs the full suite: $(ran)"
[ -f "$st/$hid/$(xtree)" ] || fail "a full pass records a full stamp"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ -z "$(ran)" ] || fail "a full stamp caches the full suite: $(ran)"
echo d >"$x/d.txt" && git -C "$x" add d.txt && git -C "$x" commit -q -m d
"$forge" test >/dev/null
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 0 ] && [ -z "$(ran)" ] || fail "a full pass satisfies --changed: $(ran)"
[ "$(code "$forge" test --passed --changed)" = 0 ] || fail "--passed --changed accepts a full stamp: $(cat "$tmp/out")"
n=$(find "$st" -type f | wc -l)
[ "$(T_ENV=$tmp/env code "$forge" test --one 'x y')" = 0 ] && [ "$(ran)" = "[one][x y]" ] || fail "--one runs the Test line with the quoted id: $(ran)"
grep -qxF "ran one x y" "$tmp/out" || fail "--one prints the test's output: $(cat "$tmp/out")"
[[ $(cat "$tmp/env") == "$XDG_RUNTIME_DIR"/forge/test-runs/[1-9]* ]] || fail "--one takes a run slot and exports it as FORGE_TEST_SLOT_HELD: $(cat "$tmp/env")"
[ "$(find "$st" -type f | wc -l)" = "$n" ] || fail "--one records no stamp"
echo 3 >"$T_EXIT"
[ "$(code "$forge" test --one a)" = 3 ] || fail "a failing --one exits with its code"
echo 5 >"$T_EXIT"
[ "$(code "$forge" test --one a)" = 1 ] || fail "a --one exiting 5 exits 1"
echo 75 >"$T_EXIT"
[ "$(code "$forge" test --one a)" = 1 ] || fail "a --one exiting 75 exits 1, since 75 means a resource exit: $(cat "$tmp/out")"
echo 0 >"$T_EXIT"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "no Test line"
: >"$T_LOG"
[ "$(T_ENV=$tmp/env code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[changed][.forge/TESTING.md][a.txt][b c.txt][d.txt][u.txt]" ] || fail "--one without a Test line runs the changed tests: $(ran)"
[[ $(cat "$tmp/env") == "$XDG_RUNTIME_DIR"/forge/test-runs/[1-9]* ]] || fail "the --one fallback exports its run slot as FORGE_TEST_SLOT_HELD: $(cat "$tmp/env")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "no Changed line"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "--changed without a Changed tests line runs the full suite: $(ran)"
[ -f "$st/$hid/$(xtree)" ] || fail "the full fallback records a full stamp"
git -C "$x" commit -q --allow-empty -m e
echo x >"$x/e.txt"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "--one without Test and Changed lines runs the full suite: $(ran)"
for a in --one "--base" "--bogus" "--passed --one a" "a b"; do
  [ "$(code "$forge" test $a)" = 2 ] || fail "forge test $a is a usage error"
done
ok test-tiers
fi

if want test-chain; then
c=$tmp/chain
gitinit "$c" && mkdir -p "$c/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$c/.forge/TESTING.md"
cp "$x/t.sh" "$c/t.sh" && echo a >"$c/a.txt"
git -C "$c" add -A && git -C "$c" commit -q -m init && git -C "$c" checkout -q -b side
cs=$c/.git/forge-test/$hid/changed
ctree() { git -C "$c" rev-parse HEAD^{tree}; }
cshort() { git -C "$c" rev-parse --short HEAD^{tree}; }
cnext() { echo "$1" >>"$c/a.txt" && git -C "$c" commit -q -am "$1"; }
echo 0 >"$T_EXIT"
cnext prefix
pc=$(git -C "$c" rev-parse HEAD) pt=$(ctree)
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$c")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "the pre-fix tree passes --changed --base main: $(cat "$tmp/out") $(ran)"
[ "$(cat "$cs/$pt")" = "$(git -C "$c" rev-parse main)" ] || fail "a scoped pass over an unstamped merge-base tree records the bare merge base: $(cat "$cs/$pt")"
cnext fix
fc=$(git -C "$c" rev-parse HEAD) ft=$(ctree)
: >"$T_LOG"
[ "$(code "$forge" test --changed --base "$pc" "$c")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "--changed --base <pre-fix commit> runs the fix's files: $(cat "$tmp/out") $(ran)"
[ "$(cat "$cs/$ft")" = "chain $pt" ] || fail "a scoped pass whose merge-base tree is stamped on this host records chain <merge-base tree>: $(cat "$cs/$ft")"
[ "$(code "$forge" test --passed --changed "$c")" = 0 ] || fail "--passed --changed accepts a chain whose tree is stamped on this host: $(cat "$tmp/out")"
cnext fix2
gt=$(ctree) gs=$(cshort)
[ "$(code "$forge" test --changed --base "$fc" "$c")" = 0 ] || fail "a second fix round passes --changed --base <first fix commit>: $(cat "$tmp/out")"
[ "$(cat "$cs/$gt")" = "chain $ft" ] || fail "a scoped pass over a chained tree records chain <that tree>: $(cat "$cs/$gt")"
[ "$(code "$forge" test --passed --changed "$c")" = 0 ] || fail "--passed --changed follows a two-link chain to a stamped tree: $(cat "$tmp/out")"
: >"$T_LOG"
[ "$(code "$forge" test --changed --base "$fc" "$c")" = 0 ] && [ -z "$(ran)" ] && [ "$(lastline)" = "forge: tests passed ($gs), cached" ] || fail "a chain line equal to what a pass would write now for this base caches --changed --base <first fix commit> with nothing run: $(cat "$tmp/out") $(ran)"
rm "$cs/$pt"
[ "$(code "$forge" test --passed --changed "$c")" = 1 ] || fail "--passed --changed rejects a chain whose end is no longer stamped: $(cat "$tmp/out")"
grep -qF "no test pass for tree $gs" "$tmp/out" || fail "a broken chain gives the no-test-pass message: $(cat "$tmp/out")"
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$c")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "a chain line never caches --changed --base main on the final tree: $(cat "$tmp/out") $(ran)"
grep -qxF "chain $ft" "$cs/$gt" && grep -qxF "$(git -C "$c" rev-parse main)" "$cs/$gt" || fail "a later --changed --base main pass appends the bare merge base beside the broken chain line: $(cat "$cs/$gt")"
[ "$(code "$forge" test --passed --changed "$c")" = 0 ] || fail "--passed --changed accepts a changed stamp holding a bare merge-base line beside a broken chain line: $(cat "$tmp/out")"
cnext other-host
oc=$(git -C "$c" rev-parse HEAD)
mkdir -p "$c/.git/forge-test/$hk/changed" && : >"$c/.git/forge-test/$hk/changed/$(ctree)"
cnext after-other-host
ot=$(ctree)
[ "$(code "$forge" test --changed --base "$oc" "$c")" = 0 ] || fail "a scoped pass over a tree stamped only under another host passes: $(cat "$tmp/out")"
if grep -q '^chain ' "$cs/$ot"; then
  [ "$(code "$forge" test --passed --changed "$c")" = 1 ] || fail "a chain to a tree stamped only under another host's id never validates: $(cat "$cs/$ot")"
else
  [ "$(cat "$cs/$ot")" = "$oc" ] || fail "a scoped pass over a tree stamped only under another host records the bare merge base: $(cat "$cs/$ot")"
fi
cnext failed
echo 3 >"$T_EXIT"
[ "$(code "$forge" test --changed --base "$(git -C "$c" rev-parse HEAD~1)" "$c")" = 3 ] || fail "a failing scoped run exits with its code: $(cat "$tmp/out")"
[ ! -e "$cs/$(ctree)" ] && [ ! -e "$c/.git/forge-test/$hid/$(ctree)" ] || fail "a failing scoped run leaves no stamp for its tree: $(find "$c/.git/forge-test" -type f)"
echo 0 >"$T_EXIT"
cnext cycle
yt=$(ctree)
echo "chain $yt" >"$cs/$yt"
[ "$(code timeout 20 "$forge" test --passed --changed "$c")" = 1 ] || fail "a self-chained stamp is rejected and the check terminates: $(cat "$tmp/out")"
zt=$(git -C "$c" rev-parse HEAD~1^{tree})
echo "chain $zt" >"$cs/$yt" && echo "chain $yt" >"$cs/$zt"
[ "$(code timeout 20 "$forge" test --passed --changed "$c")" = 1 ] || fail "a two-tree chain cycle is rejected and the check terminates: $(cat "$tmp/out")"
for _ in 1 2 3 4 5 6; do echo "chain $zt"; done >"$cs/$yt" && for _ in 1 2 3 4 5 6; do echo "chain $yt"; done >"$cs/$zt"
[ "$(code timeout 20 "$forge" test --passed --changed "$c")" = 1 ] || fail "a two-tree chain cycle with duplicate chain lines is rejected and the check terminates: $(cat "$tmp/out")"
: >"$cs/$yt"
[ "$(code "$forge" test --passed --changed "$c")" = 0 ] || fail "an empty changed stamp is still accepted: $(cat "$tmp/out")"
cnext race
rt=$(ctree)
rm -f "$tmp/go" && : >"$T_LOG"
T_HOLD=$tmp/go "$forge" test --changed --base HEAD~1 "$c" >"$tmp/race.out" 2>&1 & rp=$!
for _ in $(seq 50); do [ -n "$(ran)" ] && break; sleep 0.1; done
rm "$cs/$yt" && : >"$tmp/go"
rs=0 && wait $rp || rs=$?
rm -f "$tmp/go"
[ $rs = 1 ] && [ ! -e "$cs/$rt" ] && grep -qF "lost its test pass while tests ran; no pass recorded" "$tmp/race.out" || fail "a scoped run whose pre-fix tree loses its stamp while tests run records no pass: $rs $(cat "$tmp/race.out") $(cat "$cs/$rt" 2>/dev/null)"
[ "$(code "$forge" test --passed --changed "$c")" = 1 ] || fail "--passed --changed rejects a tree whose scoped pass lost its pre-fix pass mid-run: $(cat "$tmp/out")"
ok test-chain
fi

if want test-full-chain; then
k=$tmp/kchain
gitinit "$k" && mkdir -p "$k/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$k/.forge/TESTING.md"
cp "$x/t.sh" "$k/t.sh" && echo a >"$k/a.txt"
git -C "$k" add -A && git -C "$k" commit -q -m init && git -C "$k" checkout -q -b side
ks=$k/.git/forge-test/$hid
ktree() { git -C "$k" rev-parse HEAD^{tree}; }
kshort() { git -C "$k" rev-parse --short HEAD^{tree}; }
knext() { echo "$1" >>"$k/a.txt" && git -C "$k" commit -q -am "$1"; }
kfull() {
  : >"$T_LOG"
  [ "$(code "$forge" test --passed "$k")" = 1 ] || fail "--passed rejects $1: $(cat "$tmp/out")"
  [ "$(code "$forge" test "$k")" = 0 ] && [ "$(ran)" = "[all]" ] && [ "$(lastline)" = "forge: tests passed ($(kshort))" ] || fail "a full run runs the suite with $1: $(cat "$tmp/out") $(ran)"
}
echo 0 >"$T_EXIT"
mkdir -p "$ks/changed"
knext base
bc=$(git -C "$k" rev-parse HEAD) bt=$(ktree)
: >"$ks/$bt"
knext mid
mt=$(ktree)
echo "chain $bt" >"$ks/changed/$mt"
knext verified
vt=$(ktree) vs=$(kshort)
echo "chain $mt" >"$ks/changed/$vt"
: >"$T_LOG"
[ "$(code "$forge" test "$k")" = 0 ] && [ -z "$(ran)" ] && [ "$(lastline)" = "forge: tests passed ($vs), cached" ] || fail "a changed stamp chaining to a full stamp of a tree in HEAD's history caches a full run: $(cat "$tmp/out") $(ran)"
[ ! -e "$ks/$vt" ] || fail "a chained cache hit records no full stamp"
[ "$(code "$forge" test --passed "$k")" = 0 ] && [ "$(cat "$tmp/out")" = "forge: tests passed ($vs)" ] || fail "--passed accepts a chained changed stamp for a full check: $(cat "$tmp/out")"
mkdir -p "$k/docs" && echo g >"$k/docs/guide.md" && git -C "$k" add -A && git -C "$k" commit -q -m docs
: >"$T_LOG"
[ "$(code "$forge" test "$k")" = 0 ] && [ -z "$(ran)" ] && [ "$(lastline)" = "forge: tests passed ($(kshort)), cached from $vs (docs-only change)" ] || fail "a docs-only child of a chained tree carries a full run: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --passed "$k")" = 0 ] && [ "$(cat "$tmp/out")" = "forge: tests passed ($(kshort)), cached from $vs (docs-only change)" ] || fail "--passed carries a docs-only child of a chained tree: $(cat "$tmp/out")"
knext bare
echo "$bc" >"$ks/changed/$(ktree)"
kfull "a bare merge-base line"
knext gap
gt=$(ktree)
knext broken
echo "chain $gt" >"$ks/changed/$(ktree)"
kfull "a chain to an unstamped tree"
knext gap-bare
gt=$(ktree)
echo "$bc" >"$ks/changed/$gt"
knext broken-bare
echo "chain $gt" >"$ks/changed/$(ktree)"
kfull "a chain ending at a bare merge-base line"
git -C "$k" checkout -q -b off && knext off && ot=$(ktree) && git -C "$k" checkout -q side
: >"$ks/$ot"
knext outside
echo "chain $ot" >"$ks/changed/$(ktree)"
kfull "a chain to a full stamp of a tree outside HEAD's history"
hks=$k/.git/forge-test/$hk
knext host-base
ht=$(ktree)
knext host
mkdir -p "$hks/changed" && : >"$hks/$ht" && echo "chain $ht" >"$hks/changed/$(ktree)"
kfull "a chain only under another host's id"
knext fail-base
ft=$(ktree)
: >"$ks/$ft"
knext fail
echo "chain $ft" >"$ks/changed/$(ktree)"
[ "$(code "$forge" test --passed "$k")" = 0 ] || fail "--passed accepts the chained stamp before the failed run: $(cat "$tmp/out")"
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --force "$k")" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a failing forced full run exits with its code: $(cat "$tmp/out") $(ran)"
echo 0 >"$T_EXIT"
[ ! -e "$ks/changed/$(ktree)" ] && [ ! -e "$ks/$(ktree)" ] || fail "a failed full run removes the chained stamp: $(find "$ks" -type f)"
[ "$(code "$forge" test --passed "$k")" = 1 ] || fail "--passed rejects a tree whose full run failed after its chained pass: $(cat "$tmp/out")"
ok test-full-chain
fi

if want test-changed-full; then
f=$tmp/full
gitinit "$f" && mkdir -p "$f/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$f/.forge/TESTING.md"
cp "$x/t.sh" "$f/t.sh" && echo a >"$f/a.txt"
git -C "$f" add -A && git -C "$f" commit -q -m init && git -C "$f" checkout -q -b side
fs=$f/.git/forge-test/$hid
ftree() { git -C "$f" rev-parse HEAD^{tree}; }
fshort() { git -C "$f" rev-parse --short HEAD^{tree}; }
fnext() { echo "$1" >>"$f/a.txt" && git -C "$f" commit -q -am "$1"; }
echo 0 >"$T_EXIT"
fnext marked
: >"$T_LOG"
[ "$(T_FULL=1 code "$forge" test --changed --base main "$f")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "a changed run whose command writes the .full marker passes: $(cat "$tmp/out") $(ran)"
[ -f "$fs/$(ftree)" ] || fail "a clean changed pass whose command wrote \$FORGE_TEST_LOG_DIR/.full records the full stamp: $(find "$f/.git/forge-test" -type f)"
[ -f "$fs/changed/$(ftree)" ] || fail "a marker-promoted changed pass still records its changed stamp: $(find "$f/.git/forge-test" -type f)"
: >"$T_LOG"
[ "$(code "$forge" test "$f")" = 0 ] || fail "forge test after a marker-promoted changed pass passes: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests passed ($(fshort)), cached" ] || fail "forge test after a marker-promoted changed pass reports cached: $(lastline)"
[ -z "$(ran)" ] || fail "forge test after a marker-promoted changed pass runs nothing: $(ran)"
fnext unmarked
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$f")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "a changed run without the .full marker passes: $(cat "$tmp/out") $(ran)"
[ ! -e "$fs/$(ftree)" ] || fail "a changed pass without the .full marker records no full stamp"
[ -f "$fs/changed/$(ftree)" ] || fail "a changed pass without the .full marker records a changed stamp: $(find "$f/.git/forge-test" -type f)"
: >"$T_LOG"
[ "$(code "$forge" test "$f")" = 0 ] && [ "$(ran)" = "[all]" ] || fail "forge test after an unmarked changed pass runs the full suite: $(cat "$tmp/out") $(ran)"
fnext failing
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(T_FULL=1 code "$forge" test --changed --base main "$f")" = 3 ] || fail "a failing changed run that wrote the .full marker exits with its code: $(cat "$tmp/out")"
[ ! -e "$fs/$(ftree)" ] && [ ! -e "$fs/changed/$(ftree)" ] || fail "a failing changed run that wrote the .full marker leaves neither stamp: $(find "$f/.git/forge-test" -type f)"
echo 0 >"$T_EXIT"
ok test-changed-full
fi

if want test-sync-carry; then
sy=$tmp/sync
gitinit "$sy" && mkdir -p "$sy/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$sy/.forge/TESTING.md"
cp "$x/t.sh" "$sy/t.sh" && echo a >"$sy/a.txt"
git -C "$sy" add -A && git -C "$sy" commit -q -m init
sys=$sy/.git/forge-test/$hid
sytree() { git -C "$sy" rev-parse HEAD^{tree}; }
syshort() { git -C "$sy" rev-parse --short HEAD^{tree}; }
symerge() { git -C "$sy" checkout -q main && echo "$2" >>"$sy/$1" && git -C "$sy" add -A && git -C "$sy" commit -q -m sync && git -C "$sy" checkout -q w && git -C "$sy" merge -q --no-ff --no-edit main; }
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test "$sy")" = 0 ] && [ "$(ran)" = "[all]" ] && [ -f "$sys/$(sytree)" ] || fail "the base branch's tree passes a full run and is full-stamped: $(cat "$tmp/out") $(ran)"
sybt=$(sytree)
git -C "$sy" checkout -q -b w && echo w >>"$sy/a.txt" && git -C "$sy" commit -q -am w
sywt=$(sytree) syws=$(git -C "$sy" rev-parse --short "$(sytree)")
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$sy")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] || fail "the branch passes --changed --base main: $(cat "$tmp/out") $(ran)"
[ "$(cat "$sys/changed/$sywt")" = "chain $sybt" ] || fail "the branch's changed stamp is a chain line to the full-stamped base tree: $(cat "$sys/changed/$sywt")"
symerge .forge/notes.md n
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$sy")" = 0 ] && [ -z "$(ran)" ] && [ "$(lastline)" = "forge: tests passed ($(syshort)), cached from $syws (docs-only change)" ] || fail "a .forge/-only sync merge carries a chain-stamped tree's pass to --changed --base main with nothing run: $(cat "$tmp/out") $(ran)"
[ ! -e "$sys/$(sytree)" ] && [ ! -e "$sys/changed/$(sytree)" ] || fail "a chain-aware docs-only carry-over records no stamp: $(find "$sy/.git/forge-test" -type f)"
: >"$T_LOG"
[ "$(code "$forge" test "$sy")" = 0 ] && [ -z "$(ran)" ] && [ "$(lastline)" = "forge: tests passed ($(syshort)), cached from $syws (docs-only change)" ] || fail "a full run on a .forge/-only merge whose ancestor's changed stamp chains to a full stamp in HEAD's history carries with nothing run: $(cat "$tmp/out") $(ran)"
symerge b.txt b
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$sy")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] && ! grep -qF "cached from" "$tmp/out" || fail "a sync merge that brings a code file from the base reruns: $(cat "$tmp/out") $(ran)"
symerge .forge/TESTING.md notes
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main "$sy")" = 0 ] && [ "$(ran)" = "[changed][a.txt]" ] && ! grep -qF "cached from" "$tmp/out" || fail "a sync merge of a .forge/TESTING.md change reruns: $(cat "$tmp/out") $(ran)"
ok test-sync-carry
fi

if want test-carry; then
cd "$x"
rm -f "$x/e.txt"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
echo f >"$x/f.txt" && git -C "$x" add -A && git -C "$x" commit -q -m carry
"$forge" test >/dev/null
xs=$(xshort)
mkdir -p "$x/sub" "$x/docs"
echo n >"$x/.forge/notes.txt" && echo r >"$x/sub/README.md" && echo g >"$x/docs/guide.txt"
git -C "$x" add -A && git -C "$x" commit -q -m docs
cp "$x/.git/forge-test.log" "$tmp/carry.log"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] || fail "a docs-only commit after a full pass passes: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests passed ($(xshort)), cached from $xs (docs-only change)" ] || fail "a docs-only carry-over names both trees: $(lastline)"
[ -z "$(ran)" ] || fail "a docs-only carry-over runs nothing: $(ran)"
cmp -s "$x/.git/forge-test.log" "$tmp/carry.log" || fail "a docs-only carry-over leaves the log alone: $(cat "$x/.git/forge-test.log")"
[ ! -e "$st/$hid/$(xtree)" ] && [ ! -e "$st/$hid/changed/$(xtree)" ] || fail "a docs-only carry-over records no stamp"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "--force skips the docs-only carry-over: $(cat "$tmp/out") $(ran)"
[ -f "$st/$hid/$(xtree)" ] || fail "--force records a full stamp"
xs=$(xshort)
echo more >>"$x/sub/README.md"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ -z "$(ran)" ] || fail "an uncommitted docs-only edit carries over: $(cat "$tmp/out") $(ran)"
l=$(lastline)
git -C "$x" commit -q -am readme
[ "$l" = "forge: tests passed ($(xshort)), cached from $xs (docs-only change)" ] || fail "an uncommitted docs-only edit carries from HEAD's stamped tree: $l"
[ ! -e "$st/$hid/$(xtree)" ] && [ ! -e "$st/$hid/changed/$(xtree)" ] || fail "an uncommitted carry-over records no stamp"
for m in "" " --changed"; do
  [ "$(code "$forge" test --passed$m)" = 0 ] || fail "--passed$m accepts a docs-only carry-over: $(cat "$tmp/out")"
  [ "$(cat "$tmp/out")" = "forge: tests passed ($(xshort)), cached from $xs (docs-only change)" ] || fail "--passed$m names the carry-over: $(cat "$tmp/out")"
done
echo m >>"$x/sub/README.md" && echo m >>"$x/a.txt"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a change that also touches a non-doc file runs the suite: $(ran)"
git -C "$x" checkout -q -- .
for f in sub/docs/x.txt docs2/x x.mdx; do
  mkdir -p "$x/$(dirname "$f")" && echo x >"$x/$f"
  : >"$T_LOG"
  [ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "$f is not docs-only, so the suite runs: $(ran)"
  rm "$x/$f"
done
rmdir "$x/sub/docs" "$x/docs2"
echo c >>"$x/a.txt" && git -C "$x" commit -q -am c
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 0 ] && [ -n "$(ran)" ] || fail "--changed runs a new non-doc change: $(ran)"
xs=$(xshort)
echo g >>"$x/docs/guide.txt" && git -C "$x" commit -q -am guide
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 0 ] && [ -z "$(ran)" ] || fail "a changed stamp carries to --changed: $(cat "$tmp/out") $(ran)"
[ "$(lastline)" = "forge: tests passed ($(xshort)), cached from $xs (docs-only change)" ] || fail "a --changed carry-over names both trees: $(lastline)"
[ ! -e "$st/$hid/changed/$(xtree)" ] || fail "a --changed carry-over records no stamp"
[ "$(code "$forge" test --passed --changed)" = 0 ] || fail "--passed --changed accepts a changed stamp's carry-over: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed needs a full stamp to carry from: $(cat "$tmp/out")"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a full run with only a changed stamp runs the full suite: $(ran)"
for i in $(seq 19); do echo "$i" >"$x/.forge/n$i.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "n$i"; done
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ -z "$(ran)" ] || fail "a stamp 19 commits back carries over: $(cat "$tmp/out") $(ran)"
for i in 20 21; do echo "$i" >"$x/.forge/n$i.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "n$i"; done
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a stamp 21 commits back is not found, so the suite runs: $(cat "$tmp/out") $(ran)"
sed -i 's/`\.\/t\.sh all`/`.\/t.sh all new`/' "$x/.forge/TESTING.md" && git -C "$x" commit -q -am testing
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed never carries over a TESTING.md change: $(cat "$tmp/out")"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all][new]" ] || fail "a TESTING.md change never carries over, so the suite runs: $(cat "$tmp/out") $(ran)"
echo z >>"$x/a.txt" && git -C "$x" commit -q -am z
: >"$T_LOG"
[ "$(code "$forge" test --changed --base HEAD)" = 0 ] && [ -z "$(ran)" ] || fail "--changed against HEAD has no changed files: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --changed --base main)" = 0 ] && [ -n "$(ran)" ] || fail "a changed stamp of another base never caches: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test --changed --base main)" = 0 ] && [ -z "$(ran)" ] || fail "a changed stamp caches its own base: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --changed --base HEAD)" = 0 ] && [ -z "$(ran)" ] || fail "a changed stamp caches each base it passed: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --passed --changed)" = 0 ] || fail "--passed --changed takes a changed stamp of any base: $(cat "$tmp/out")"
ok test-carry
fi

if want test-runs; then
cd "$x"
rn=$XDG_RUNTIME_DIR/forge/test-runs
rk=
rfail() { touch "$tmp/go"; [ -z "$rk" ] || kill $rk 2>/dev/null || :; exec 7>&- 8>&-; fail "$@"; }
rwait() { local i; for i in $(seq 100); do grep -q '^forge: waiting for a test run slot' "$1" 2>/dev/null && return 0; kill -0 "$2" 2>/dev/null || return 1; sleep 0.1; done; return 1; }
rstop() { kill -TERM "$1" 2>/dev/null || :; wait "$1" 2>/dev/null || :; rk=; }
rbg() { local o=$1; shift; "$@" >"$o" 2>&1 & rp=$!; rk="$rk $rp"; }
rm -f "$x/e.txt" "$tmp/go"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am runs
rm -rf "$rn"
for w in a b c; do git -C "$x" worktree add -q "$tmp/wt-$w" -b "runs-$w"; done
: >"$T_LOG"
rm -f "$tmp/env-a" "$tmp/env-b" "$tmp/fds"
rbg "$tmp/ra.out" env T_HOLD="$tmp/go" T_ENV="$tmp/env-a" T_FDS="$tmp/fds" "$forge" test --force "$tmp/wt-a"
ra=$rp
for _ in $(seq 100); do [ -s "$tmp/env-a" ] && break; sleep 0.1; done
rbg "$tmp/rb.out" env T_HOLD="$tmp/go" T_ENV="$tmp/env-b" "$forge" test --one a "$tmp/wt-b"
rb=$rp
for _ in $(seq 100); do [ -s "$tmp/env-b" ] && break; sleep 0.1; done
[ "$(ran | sort | paste -sd,)" = "[all],[one][a]" ] || rfail "under the default FORGE_TEST_RUNS of 2 a full run and a --one run in two worktrees run at once: $(ran) $(cat "$tmp/ra.out" "$tmp/rb.out")"
! grep -q waiting "$tmp/ra.out" "$tmp/rb.out" || rfail "the first two runs print no wait line: $(cat "$tmp/ra.out" "$tmp/rb.out")"
[ "$(cat "$tmp/env-a" "$tmp/env-b" | sort | paste -sd' ')" = "$rn/1 $rn/2" ] || rfail "the two runs hold slots 1 and 2 under $rn, shared by the machine, and export them as FORGE_TEST_SLOT_HELD: $(cat "$tmp/env-a" "$tmp/env-b")"
ha=$(cat "$tmp/env-a")
grep -qwF "$ra" "$ha" && grep -qF " in $tmp/wt-a since " "$ha" || rfail "a held run slot names its holder's pid and worktree: $(cat "$ha")"
! grep -qE 'test-runs|test-slots|test-admit|forge-test\.lock' "$tmp/fds" || rfail "the command holds no run slot, lock or worktree lock fd: $(cat "$tmp/fds")"
rbg "$tmp/rc.out" env PATH="$tmp/fake:$PATH" FORGE_TEST_SLOT_WAIT=1 "$forge" test --force "$tmp/wt-c"
rc=$rp
rwait "$tmp/rc.out" "$rc" || rfail "a third run waits for a test run slot: $(cat "$tmp/rc.out")"
wl=$(grep '^forge: waiting for a test run slot' "$tmp/rc.out")
[[ $wl == "forge: waiting for a test run slot (2 in use: "*")" ]] && grep -qF "$tmp/wt-a" <<<"$wl" && grep -qF "$tmp/wt-b" <<<"$wl" ||
  rfail "the wait line reads 'forge: waiting for a test run slot (2 in use: <holders>)', naming both holders' worktrees: $wl"
re=()
[ -f "$rn/wait/$rc" ] && read -ra re <"$rn/wait/$rc" || rfail "the waiting run writes its entry $rn/wait/$rc: $(ls -A "$rn/wait" 2>&1)"
[ "${#re[@]}" = 3 ] && [ "${re[0]}" = "$rc" ] && [ "${re[1]}" = "$(pstart "$rc")" ] && [[ ${re[2]} =~ ^[0-9]+$ ]] || rfail "the waiter entry reads '<pid> <proc start> <arrival>': ${re[*]}"
sleep 2
kill -0 "$rc" 2>/dev/null && [ "$(grep -c '^forge: waiting' "$tmp/rc.out")" = 1 ] && [ "$(ran | wc -l)" = 2 ] && ! grep -q 'gave up' "$tmp/rc.out" ||
  rfail "the third run keeps waiting past FORGE_TEST_SLOT_WAIT=1 under a clock running 61 s a poll, never giving up, its wait line printed once and nothing run: $(cat "$tmp/rc.out") $(ran)"
touch "$tmp/go"
wait "$ra" && wait "$rb" || rfail "both holders pass: $(cat "$tmp/ra.out" "$tmp/rb.out")"
s=0
wait "$rc" || s=$?
rk=
[ "$s" = 0 ] && [ "$(ran | grep -cxF '[all]')" = 2 ] && [ ! -e "$rn/wait/$rc" ] || rfail "the waiting run passes once a slot frees, runs and removes its waiter entry (exit $s): $(cat "$tmp/rc.out") $(ran) $(ls -A "$rn/wait")"
rm -f "$tmp/go"
sleep 300 </dev/null >/dev/null 2>&1 &
ow=$!
rk=$ow
echo "$ow $(pstart "$ow") 1" >"$rn/wait/$ow"
: >"$T_LOG"
rbg "$tmp/ro.out" "$forge" test --force "$tmp/wt-a"
ro=$rp
rwait "$tmp/ro.out" "$ro" && [ -z "$(ran)" ] || rfail "with both slots free a run behind a live older waiter waits: $(cat "$tmp/ro.out") $(ran)"
grep -q '^forge: waiting for a test run slot (0 in use' "$tmp/ro.out" || rfail "the run behind an older waiter names 0 slots in use: $(cat "$tmp/ro.out")"
sleep 1
[ -z "$(ran)" ] && [ -f "$rn/wait/$ow" ] && [ -f "$rn/wait/$ro" ] || rfail "the run still waits behind the live older waiter, both entries kept: $(ran) $(ls -A "$rn/wait")"
rm -f "$rn/wait/$ow"
s=0
wait "$ro" || s=$?
rk=$ow
[ "$s" = 0 ] && [ "$(ran)" = "[all]" ] && [ ! -e "$rn/wait/$ro" ] || rfail "once the older waiter's entry goes the run takes a slot and passes (exit $s): $(cat "$tmp/ro.out") $(ran)"
echo "$ow $(pstart "$ow") 99999999999999999" >"$rn/wait/$ow"
: >"$T_LOG"
[ "$(code timeout 20 "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] && ! grep -q waiting "$tmp/out" && [ -f "$rn/wait/$ow" ] || rfail "a live younger waiter never holds back a run, and its entry stays: $(cat "$tmp/out") $(ran)"
os=$(pstart "$ow")
kill "$ow" 2>/dev/null || :
wait "$ow" 2>/dev/null || :
rk=
echo "$ow $os 1" >"$rn/wait/$ow"
sh -c : &
od=$!
wait "$od" || :
echo "$od 12345 1" >"$rn/wait/$od"
echo junk >"$rn/wait/junk"
: >"$T_LOG"
[ "$(code timeout 20 "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] && ! grep -q waiting "$tmp/out" || fail "an older entry of a dead waiter holds back no run: $(cat "$tmp/out") $(ran)"
[ -z "$(ls -A "$rn/wait")" ] || fail "the run drops the dead and malformed waiter entries: $(ls -A "$rn/wait")"
for v in 0 x -1 1.5 ''; do
  : >"$T_LOG"
  [ "$(FORGE_TEST_RUNS=$v code timeout 20 "$forge" test --force)" = 2 ] && grep -qxF "forge: FORGE_TEST_RUNS must be a whole number of at least 1, got '$v'" "$tmp/out" && [ -z "$(ran)" ] ||
    fail "a FORGE_TEST_RUNS of '$v' is a usage error naming it, running nothing: $(cat "$tmp/out") $(ran)"
done
[ "$(FORGE_TEST_RUNS=x code timeout 20 "$forge" test --one a)" = 2 ] && grep -qxF "forge: FORGE_TEST_RUNS must be a whole number of at least 1, got 'x'" "$tmp/out" && [ -z "$(ran)" ] ||
  fail "a --one run with FORGE_TEST_RUNS=x is a usage error too: $(cat "$tmp/out") $(ran)"
exec 7>>"$rn/1"
flock 7
echo "pid 1 in /elsewhere since now" >"$rn/1"
: >"$T_LOG"
[ "$(code timeout 20 "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] && ! grep -q waiting "$tmp/out" || rfail "with slot 1 held the default second slot runs at once: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
rbg "$tmp/r1.out" env FORGE_TEST_RUNS=1 "$forge" test --one a
r1=$rp
rwait "$tmp/r1.out" "$r1" && [ -z "$(ran)" ] || rfail "under FORGE_TEST_RUNS=1 with slot 1 held a --one run waits: $(cat "$tmp/r1.out") $(ran)"
grep -qxF "forge: waiting for a test run slot (1 in use: /elsewhere)" "$tmp/r1.out" || rfail "the wait line names the one slot in use and its holder's worktree: $(cat "$tmp/r1.out")"
exec 7>&-
s=0
wait "$r1" || s=$?
rk=
[ "$s" = 0 ] && [ "$(ran)" = "[one][a]" ] || rfail "the waiting --one run passes once slot 1 frees (exit $s): $(cat "$tmp/r1.out") $(ran)"
exec 7>>"$rn/1"
flock 7
echo "pid $$ in $x since now" >"$rn/1"
hd=$(cat "$rn/1")
for a in --force "--one a"; do
  read -ra av <<<"$a"
  : >"$T_LOG"
  rm -f "$tmp/env"
  [ "$(FORGE_TEST_SLOT_HELD=$rn/1 FORGE_TEST_RUNS=1 T_ENV=$tmp/env code timeout 20 "$forge" test "${av[@]}")" = 0 ] && [ -n "$(ran)" ] && ! grep -q waiting "$tmp/out" ||
    rfail "forge test $a under FORGE_TEST_SLOT_HELD naming a slot an ancestor holds proceeds with every slot held: $(cat "$tmp/out") $(ran)"
  [ "$(cat "$rn/1")" = "$hd" ] && [ "$(cat "$tmp/env")" = "$rn/1" ] || rfail "forge test $a under FORGE_TEST_SLOT_HELD takes no slot: $(cat "$rn/1") $(cat "$tmp/env")"
done
for h in /x "$rn/2" "$rn/1x"; do
  : >"$T_LOG"
  rbg "$tmp/rh.out" env FORGE_TEST_SLOT_HELD="$h" FORGE_TEST_RUNS=1 "$forge" test --force
  rh=$rp
  rwait "$tmp/rh.out" "$rh" && [ -z "$(ran)" ] || rfail "FORGE_TEST_SLOT_HELD=$h, not a held run slot, takes a slot and waits: $(cat "$tmp/rh.out") $(ran)"
  rstop "$rh"
  [ ! -e "$rn/wait/$rh" ] || fail "a waiting run stopped with TERM removes its waiter entry: $(ls -A "$rn/wait")"
done
sleep 60 </dev/null >/dev/null 2>&1 &
np=$!
echo "pid $np in $x since now" >"$rn/1"
: >"$T_LOG"
rbg "$tmp/rh.out" env FORGE_TEST_SLOT_HELD="$rn/1" FORGE_TEST_RUNS=1 "$forge" test --force
rh=$rp
rwait "$tmp/rh.out" "$rh" && [ -z "$(ran)" ] || { kill "$np"; rfail "FORGE_TEST_SLOT_HELD naming a slot whose holder is no ancestor takes a slot and waits: $(cat "$tmp/rh.out") $(ran)"; }
rstop "$rh"
kill "$np" 2>/dev/null || :
wait "$np" 2>/dev/null || :
sk=$tmp/runs-stack
gitinit "$sk"
mkdir -p "$sk/.forge"
cp "$x/t.sh" "$sk/t.sh"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Local stack: `true`\n- Stack tests: `./t.sh stack`\n' >"$sk/.forge/TESTING.md"
git -C "$sk" add -A && git -C "$sk" commit -q -m stack
exec 8>>"$rn/2"
flock 8
: >"$T_LOG"
rm -f "$tmp/env"
[ "$(T_ENV=$tmp/env code timeout 20 env PATH="$tmp/sbin:$PATH" "$forge" test --stack "$sk")" = 0 ] && [ "$(ran)" = "[stack]" ] && ! grep -q waiting "$tmp/out" && [ "$(cat "$tmp/env")" = unset ] ||
  rfail "--stack takes no run slot, running at once with every slot held and no FORGE_TEST_SLOT_HELD: $(cat "$tmp/out") $(ran) $(cat "$tmp/env" 2>&1)"
exec 7>&- 8>&-
for w in a b c; do git -C "$x" worktree remove --force "$tmp/wt-$w" && git -C "$x" branch -q -D "runs-$w"; done
ok test-runs
fi

if want test-wt-lock; then
cd "$x"
lk=$x/.git/forge-test.lock
wl() { grep -cxF "forge: waiting for the test run in $x (pid $1)" "$2" || true; }
lfail() { touch "$tmp/go"; fail "$@"; }
rm -f "$tmp/go" "$tmp/now"
echo w >"$x/w.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "worktree lock"
: >"$T_LOG"
T_HOLD=$tmp/go "$forge" test --force >"$tmp/hold.out" 2>&1 & hp=$!
for _ in $(seq 50); do [ -n "$(ran)" ] && break; sleep 0.1; done
[ "$(ran)" = "[all]" ] || lfail "the worktree lock holder runs: $(cat "$tmp/hold.out")"
cp "$x/.git/forge-test.log" "$tmp/wlock.log"
touch "$x/.git/forge-test.d/mark"
for pv in 0.02 unset ""; do
  pset "$pv"
  : >"$T_LOG"
  [ "$(PATH=$tmp/psleep:$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code env "${pa[@]}" timeout 20 "$forge" test --force)" = 75 ] && [ -z "$(ran)" ] || lfail "a second forge test in the worktree of a running one waits for it and exits 75 past FORGE_TEST_SLOT_WAIT, running nothing, with FORGE_TEST_POLL_SECS '$pv': $(cat "$tmp/out") $(ran)"
  [ "$(wl "$hp" "$tmp/out")" = 1 ] || lfail "the waiting run prints the wait line once, naming the worktree and the holder's pid: $(cat "$tmp/out")"
  cmp -s "$x/.git/forge-test.log" "$tmp/wlock.log" && [ -f "$x/.git/forge-test.d/mark" ] || lfail "a run that gives up waiting for the worktree lock leaves forge-test.log and forge-test.d untouched: $(cat "$x/.git/forge-test.log") $(ls -A "$x/.git/forge-test.d" 2>&1)"
  polled "$pv" 1 || lfail "the worktree-lock wait polls at FORGE_TEST_POLL_SECS '$pv', 1 s when unset or empty: sleeps $(paste -sd, "$tmp/sleeps")"
done
rm -f "$tmp/now"
[ "$(PATH=$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test --one a)" = 75 ] && [ -z "$(ran)" ] && [ "$(wl "$hp" "$tmp/out")" = 1 ] || lfail "a --one run in the worktree of a running forge test waits once and exits 75, running nothing: $(cat "$tmp/out") $(ran)"
cmp -s "$x/.git/forge-test.log" "$tmp/wlock.log" && [ -f "$x/.git/forge-test.d/mark" ] || lfail "a --one run that gives up waiting leaves forge-test.log and forge-test.d untouched: $(cat "$x/.git/forge-test.log")"
grep -qxF "pid $hp in $x" "$lk" 2>/dev/null || lfail "a running forge test holds $lk naming its pid and worktree: $(cat "$lk" 2>&1)"
"$forge" test >"$tmp/wait.out" 2>&1 & wp=$!
for _ in $(seq 50); do grep -q waiting "$tmp/wait.out" && break; sleep 0.1; done
[ "$(wl "$hp" "$tmp/wait.out")" = 1 ] && [ -z "$(ran)" ] || lfail "a forge test of the same tree waits for the running one: $(cat "$tmp/wait.out") $(ran)"
touch "$tmp/go"
wait $hp || fail "the worktree lock holder passes: $(cat "$tmp/hold.out")"
wait $wp || fail "the waiting forge test passes once the holder ends: $(cat "$tmp/wait.out")"
[ "$(tail -n1 "$tmp/wait.out")" = "forge: tests passed ($(xshort)), cached" ] && [ -z "$(ran)" ] || fail "a run that waited and finds its tree passed returns cached, running nothing: $(cat "$tmp/wait.out") $(ran)"
rm -f "$tmp/go"
echo s >"$x/w2.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "worktree lock slot"
: >"$T_LOG"
FORGE_TEST_RUNS=1 T_HOLD=$tmp/go "$forge" test --force >"$tmp/hold.out" 2>&1 & hp=$!
for _ in $(seq 50); do [ -n "$(ran)" ] && break; sleep 0.1; done
[ "$(ran)" = "[all]" ] || lfail "the capped worktree lock holder runs: $(cat "$tmp/hold.out")"
: >"$T_LOG"
FORGE_TEST_RUNS=1 "$forge" test >"$tmp/wait.out" 2>&1 & wp=$!
for _ in $(seq 50); do grep -q waiting "$tmp/wait.out" && break; sleep 0.1; done
grep -q "^forge: waiting for a test run slot" "$tmp/wait.out" && [ -z "$(ran)" ] || lfail "under FORGE_TEST_RUNS=1 a forge test of the same tree waits for the running one's run slot: $(cat "$tmp/wait.out") $(ran)"
touch "$tmp/go"
wait $hp || fail "the capped worktree lock holder passes: $(cat "$tmp/hold.out")"
wait $wp || fail "the run waiting for the run slot passes once the holder ends: $(cat "$tmp/wait.out")"
[ "$(tail -n1 "$tmp/wait.out")" = "forge: tests passed ($(xshort)), cached" ] && [ -z "$(ran)" ] && [ "$(wl "$hp" "$tmp/wait.out")" = 0 ] || fail "a run that waited only for the run slot and finds its tree passed returns cached, running nothing: $(cat "$tmp/wait.out") $(ran)"
rm -f "$tmp/go"
sleep 60 & np=$!
exec 4>>"$lk"
flock -n 4 || fail "the finished holder released $lk"
echo "pid $np in $x" >"$lk"
for m in "" " --changed"; do
  : >"$T_LOG" && rm -f "$tmp/now"
  [ "$(PATH=$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test$m)" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(xshort)), cached" ] && [ -z "$(ran)" ] || fail "a cached forge test$m returns while the worktree lock is held: $(cat "$tmp/out") $(ran)"
  ! grep -q waiting "$tmp/out" || fail "a cached forge test$m never waits: $(cat "$tmp/out")"
done
xs=$(xshort)
echo n >"$x/.forge/wlock.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "worktree lock docs"
: >"$T_LOG" && rm -f "$tmp/now"
[ "$(PATH=$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test)" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(xshort)), cached from $xs (docs-only change)" ] && [ -z "$(ran)" ] || fail "a docs-only forge test returns while the worktree lock is held: $(cat "$tmp/out") $(ran)"
! grep -q waiting "$tmp/out" || fail "a docs-only forge test never waits: $(cat "$tmp/out")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
echo v >"$x/v.txt" && git -C "$x" add -A && git -C "$x" commit -q -m "worktree lock change"
: >"$T_LOG" && rm -f "$tmp/now"
[ "$(PATH=$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test --changed --base HEAD)" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(xshort)), no changed files" ] && [ -z "$(ran)" ] || fail "a forge test --changed with no changed files returns while the worktree lock is held: $(cat "$tmp/out") $(ran)"
! grep -q waiting "$tmp/out" || fail "a forge test with no changed files never waits: $(cat "$tmp/out")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "worktree lock change done"
for h in "" /x "$lk"; do
  : >"$T_LOG" && rm -f "$tmp/now"
  [ "$(PATH=$tmp/fake:$PATH FORGE_TEST_WT_HELD=$h FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test --force)" = 75 ] && [ "$(wl "$np" "$tmp/out")" = 1 ] && [ -z "$(ran)" ] || fail "under FORGE_TEST_WT_HELD='$h' a forge test whose worktree lock is held by a pid that is no ancestor waits and exits 75, running nothing: $(cat "$tmp/out") $(ran)"
done
kill $np
echo "pid $$ in $x" >"$lk"
for h in /x "${lk%.lock}.other"; do
  : >"$T_LOG" && rm -f "$tmp/now"
  [ "$(PATH=$tmp/fake:$PATH FORGE_TEST_WT_HELD=$h FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test --force)" = 75 ] && [ "$(wl $$ "$tmp/out")" = 1 ] && [ -z "$(ran)" ] || fail "FORGE_TEST_WT_HELD=$h, not this worktree's lock, takes the lock and waits: $(cat "$tmp/out") $(ran)"
done
hd=$(cat "$lk")
for a in "--force" "--one a"; do
  read -ra av <<<"$a"
  : >"$T_LOG" && rm -f "$tmp/now"
  [ "$(PATH=$tmp/fake:$PATH FORGE_TEST_WT_HELD=$lk FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test "${av[@]}")" = 0 ] && [ -n "$(ran)" ] || fail "forge test $a under FORGE_TEST_WT_HELD naming this worktree's lock held by an ancestor proceeds: $(cat "$tmp/out") $(ran)"
  ! grep -q waiting "$tmp/out" || fail "forge test $a under FORGE_TEST_WT_HELD with an ancestor holder prints no wait line: $(cat "$tmp/out")"
  [ "$(cat "$lk")" = "$hd" ] || fail "forge test $a under FORGE_TEST_WT_HELD with an ancestor holder leaves the lock to it: $(cat "$lk")"
done
exec 4>&-
printf '# Testing\n\n## Commands\n- All tests: `"$NEST_FORGE" test --one a "$NEST_DIR"`\n- Test: `./t.sh one {test}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "worktree lock nest"
: >"$T_LOG" && rm -f "$tmp/now"
[ "$(PATH=$tmp/fake:$PATH NEST_FORGE=$forge NEST_DIR=$x FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test --force)" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "a forge test --one nested in a forge test of the same worktree proceeds without deadlock: $(cat "$tmp/out") $(cat "$x/.git/forge-test.log") $(ran)"
! grep -q waiting "$tmp/out" "$x/.git/forge-test.log" || fail "a nested run in the same worktree prints no wait line: $(cat "$x/.git/forge-test.log")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all && "$NEST_FORGE" test --one a "$NEST_DIR"`\n- Test: `./t.sh one {test}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "worktree lock nest other"
git -C "$x" worktree add -q "$tmp/wt-n" -b wt-nest
rm -f "$tmp/go" "$tmp/now"
: >"$T_LOG"
PATH=$tmp/fake:$PATH T_HOLD=$tmp/go FORGE_TEST_RUNS=1 FORGE_TEST_SLOT_WAIT=1 NEST_FORGE=$forge NEST_DIR=$tmp/wt-n timeout 20 "$forge" test --force >"$tmp/hold.out" 2>&1 & hp=$!
for _ in $(seq 50); do [ -n "$(ran)" ] && break; sleep 0.1; done
[ "$(ran)" = "[all]" ] || lfail "the nesting run holds the only run slot: $(cat "$tmp/hold.out")"
FORGE_TEST_RUNS=1 timeout 20 "$forge" test --one a "$tmp/wt-n" >"$tmp/slot.out" 2>&1 & sp=$!
for _ in $(seq 50); do grep -q waiting "$tmp/slot.out" && break; sleep 0.1; done
grep -q "^forge: waiting for a test run slot" "$tmp/slot.out" || lfail "a --one run in another worktree of the project waits for the nesting run's slot: $(cat "$tmp/slot.out")"
touch "$tmp/go"
wait $hp || fail "a forge test --one nested into a worktree whose own run waits for the nester's run slot proceeds without deadlock: $(cat "$tmp/hold.out") $(cat "$x/.git/forge-test.log") $(ran)"
wait $sp || fail "the run waiting for the run slot passes once the nester frees it: $(cat "$tmp/slot.out")"
grep -qxF "[one][a]" <<<"$(ran)" && [ "$(grep -c . "$T_LOG")" = 3 ] || fail "the nested --one and the waiting --one both run: $(ran)"
git -C "$x" worktree remove --force "$tmp/wt-n" && git -C "$x" branch -q -D wt-nest
rm -f "$tmp/go"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$x/.forge/TESTING.md"
git -C "$x" rm -q w.txt w2.txt v.txt .forge/wlock.txt && git -C "$x" commit -q -am "worktree lock done"
ok test-wt-lock
fi

if want test-narrow; then
nr=$tmp/narrow
gitinit "$nr"
mkdir -p "$nr/.forge" "$tmp/nsd" "$tmp/nproc/self" "$tmp/nsys/fs/cgroup/fake.scope"
cat >"$nr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1 ${FORGE_TEST_CPUS-unset}" >>"$N_LOG"
EOF
printf '#!/usr/bin/env bash\necho "$NPROC"\n' >"$tmp/nsd/nproc"
cat >"$tmp/nsd/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$N_SD"
[ -z "${N_SD_FAIL:-}" ] || exit 1
for a; do shift; [ "$a" != -- ] || exec "$@"; done
EOF
cat >"$tmp/nsd/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$N_SC"
EOF
chmod +x "$nr/t.sh" "$tmp/nsd"/*
printf 'MemTotal: 33554432 kB\nMemAvailable: 12582912 kB\n' >"$tmp/nproc/meminfo"
echo 0::/fake.scope >"$tmp/nproc/self/cgroup"
git -C "$nr" add -A && git -C "$nr" commit -q -m init
nrun() { local s=0; : >"$tmp/n.log"; : >"$tmp/n.sd"; : >"$tmp/n.sc"; rm -f "$tmp/now"; PATH=$tmp/nsd:$tmp/fake:$PATH NPROC=24 N_LOG=$tmp/n.log N_SD=$tmp/n.sd N_SC=$tmp/n.sc FORGE_PROC_ROOT=${N_PROC:-$tmp/nproc} FORGE_SYS_ROOT=$tmp/nsys FORGE_TEST_SLOT_WAIT=1 timeout 60 "$forge" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
nall() { echo "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err") ran: $(paste -sd, "$tmp/n.log") systemd-run: $(cat "$tmp/n.sd")"; }
nran() { paste -sd, "$tmp/n.log"; }
ndoc() { { printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n'; printf '%s\n' "$@"; } >"$nr/.forge/TESTING.md"; git -C "$nr" add -A && git -C "$nr" commit -q --allow-empty -m "narrow doc"; }
nscoped() { local u p=" -p MemoryMax=$1 -p MemoryHigh=$2 -p MemorySwapMax=0 "; u=$(grep -- '--unit=forge-test-' "$tmp/n.sd") && [ "$(wc -l <<<"$u")" = "${3:-1}" ] && [[ $(sed -n 1p "$tmp/n.sd") == *"$p"* ]] && ! grep -qvF -- "$p" <<<"$u" && ! grep -qE 'CPUWeight|AllowedCPUs|CPUQuota' "$tmp/n.sd"; }
nt='- Test: `./t.sh one {test}`'
ndoc "$nt" '- Memory: `12G`'
[ "$(nrun test --one a "$nr")" = 0 ] && [ "$(nran)" = "one 2" ] || fail "a --one run in a - Memory: 12G repo without - Memory one: gets the one-tier default FORGE_TEST_CPUS=2 on nproc 24 with no - CPUs one: line: $(nall)"
nscoped 6291456K 5662310K || fail "the --one probe and scope carry half the budget as MemoryMax=6291456K with MemoryHigh=5662310K, never CPUWeight, AllowedCPUs or CPUQuota: $(nall)"
ndoc "$nt" '- Memory: `12G`' '- Memory one: `1G` per test.'
[ "$(nrun test --one a "$nr")" = 0 ] && [ "$(nran)" = "one 2" ] || fail "a --one run under a - Memory one: 1G line passes with FORGE_TEST_CPUS=2: $(nall)"
nscoped 1G 943718K || fail "a - Memory one: 1G line wins over half the 12G budget, setting the --one scope's MemoryMax=1G and MemoryHigh=943718K: $(nall)"
ndoc "$nt" '- Memory: `768M`'
[ "$(nrun test --one a "$nr")" = 0 ] && [ "$(nran)" = "one 2" ] || fail "a --one run under a 768M budget passes: $(nall)"
nscoped 512M 471859K || nscoped 524288K 471859K || fail "half a 768M budget, 393216K, is floored at 512M, setting the --one scope's MemoryMax to 512M with MemoryHigh=471859K: $(nall)"
ndoc "$nt"
[ "$(nrun test --one a "$nr")" = 0 ] && [ "$(nran)" = "one 2" ] && nscoped 2097152K 1887436K || fail "without a Memory line a --one run's scope carries half the default 4G, MemoryMax=2097152K, and gets FORGE_TEST_CPUS=2: $(nall)"
ndoc "$nt" '- Memory: `12G`' '- Memory one: `1G`'
[ "$(N_PROC=$FORGE_PROC_ROOT nrun test --force "$nr")" = 0 ] && [ "$(nran)" = "all 6" ] && nscoped 12G 11324620K || fail "a full run's probe and scope keep the 12G Memory budget whatever - Memory one: says, with FORGE_TEST_CPUS=6 on nproc 24: $(nall)"
[ "$(N_PROC=$FORGE_PROC_ROOT nrun test --repeat 2 --one a "$nr")" = 0 ] && [ "$(nran)" = "one 2,one 2" ] && nscoped 12G 11324620K 2 || fail "a --repeat --one run's probe and both scopes keep the 12G Memory budget with FORGE_TEST_CPUS=2 on nproc 24: $(nall)"
ndoc '- Memory: `12G`' '- Memory one: `1G`'
[ "$(N_PROC=$FORGE_PROC_ROOT nrun test --one a "$nr")" = 0 ] && [ "$(nran)" = "all 2" ] && nscoped 12G 11324620K || fail "the --one fallback to the full tier keeps the 12G Memory budget and FORGE_TEST_CPUS=2 on nproc 24: $(nall)"
ndoc "$nt" '- Changed tests: `./t.sh changed {files}`'
[ "$(nrun test --changed --force --base HEAD~1 "$nr")" = 0 ] && [ "$(nran)" = "changed 6" ] && nscoped 4G 3774873K || fail "a capped --changed run's probe and scope carry the default MemoryMax=4G and MemoryHigh=3774873K, never CPUWeight, AllowedCPUs or CPUQuota: $(nall)"
ndoc "$nt" '- Memory: `12G`'
echo 5905580032 >"$tmp/nsys/fs/cgroup/fake.scope/memory.peak"
[ "$(nrun test --one a "$nr")" = 0 ] && grep -qxF "forge: memory peak 5.5G of 6291456K budget; set - Memory one: 7G in $(git -C "$nr" rev-parse --show-toplevel)/.forge/TESTING.md" "$tmp/err" && ! grep -qF -- "- Memory:" "$tmp/err" || fail "a --one peak above 80% of its narrow budget names - Memory one: in its hint: $(nall)"
rm -f "$tmp/nsys/fs/cgroup/fake.scope/memory.peak"
lintdoc oneok '- All tests: `pytest`.' '- Memory: `4G` per run.' '- Memory one: `1G` per test.'
[ "$(code lint "$lr/oneok")" = 0 ] || fail "lint passes a - Memory one: 1G line: $(cat "$tmp/out")"
for v in 4GB 1.5G 0G ''; do
  lintdoc onebad '- All tests: `pytest`.' '- Memory: `4G` per run.' "- Memory one: \`$v\` per test."
  [ "$(code lint "$lr/onebad")" != 0 ] || fail "lint fails a - Memory one: line of '$v': $(cat "$tmp/out")"
  grep -qF "$lr/onebad/.forge/TESTING.md" "$tmp/out" && grep -qF -- "- Memory one: \`$v\`: not a size such as 4G or 512M" "$tmp/out" || fail "a - Memory one: line of '$v' is reported like a malformed - Memory: line, naming the file and value: $(cat "$tmp/out")"
done
rm -f "$tmp/now"
ok test-narrow
fi

if want test-cpus-lint; then
lintdoc cpusok '- All tests: `pytest`.' '- CPUs all: `2` for the full suite.' '- CPUs one: `8` per test.'
[ "$(code lint "$lr/cpusok")" = 0 ] && [ ! -s "$tmp/out" ] || fail "lint passes a - CPUs all: 2 line beside a - CPUs one: 8 line: $(cat "$tmp/out")"
for n in "CPUs one" "CPUs all"; do
  for v in 1 x; do
    lintdoc cpusbad '- All tests: `pytest`.' "- $n: \`$v\` CPUs."
    [ "$(code lint "$lr/cpusbad")" = 1 ] || fail "lint returns 1 for a - $n: line of '$v': $(cat "$tmp/out")"
    grep -qxF -- "forge: $lr/cpusbad/.forge/TESTING.md: - $n: \`$v\`: not a whole number of CPUs of at least 2" "$tmp/out" || fail "lint reports a - $n: line of '$v' as forge: <doc>: - $n: \`$v\`: not a whole number of CPUs of at least 2: $(cat "$tmp/out")"
  done
done
ok test-cpus-lint
fi

if want test-slots-nested; then
[ -n "${FORGE_SYS_ROOT:-}" ] && [ -d "$FORGE_SYS_ROOT" ] && [ -z "$(ls -A "$FORGE_SYS_ROOT")" ] || fail "forge-gates points FORGE_SYS_ROOT at an empty dir: ${FORGE_SYS_ROOT:-unset}"
helper=$(sed -n '/^forge_unset_host_env() {$/,/^}$/p' "$root/tests/forge-common.sh")
[ -n "$helper" ] || fail "tests/forge-common.sh defines forge_unset_host_env"
grep -qE '^ +unset (.* )?FORGE_TEST_RUNS( |$)' <<<"$helper" || fail "tests/forge-common.sh unsets FORGE_TEST_RUNS"
! grep -qE '^ +unset (.* )?(FORGE_TEST_SLOTS|FORGE_TEST_CPU_PRESSURE)( |$)' <<<"$helper" || fail "tests/forge-common.sh no longer unsets the removed FORGE_TEST_SLOTS or FORGE_TEST_CPU_PRESSURE"
for t in "$root"/tests/*.test.sh "$root"/tests/forge/*.test.sh; do
  case ${t##*/} in
    forge-land.test.sh) ;;
    *) grep -qF '"$forge" test' "$t" || continue;;
  esac
  c=("$t")
  ! grep -qF '/forge-common.sh"' "$t" || c+=("$root/tests/forge-common.sh")
  h=
  ! grep -qx 'forge_unset_host_env' "${c[@]}" || h=$helper
  for v in FORGE_TEST_SLOT_HELD FORGE_TEST_SLOT_WAIT FORGE_TEST_CPUS FORGE_TEST_LOG_DIR; do
    grep -qE "^unset (.* )?$v( |\$)" "${c[@]}" || grep -qE "^ +unset (.* )?$v( |\$)" <<<"$h" || fail "${t##*/} runs forge test without unsetting $v"
  done
  for v in FORGE_TEST_SLOTS_MAX FORGE_TEST_MEMORY; do
    ! grep -qE "^unset (.* )?$v( |\$)" "${c[@]}" && ! grep -qE "^ +unset (.* )?$v( |\$)" <<<"$h" || fail "${t##*/} still unsets the removed $v"
  done
  for v in XDG_RUNTIME_DIR FORGE_PROC_ROOT FORGE_SYS_ROOT; do
    grep -qE "^export (.* )?$v=\\\$tmp/" "${c[@]}" || fail "${t##*/} runs forge test without exporting $v under its temp dir"
  done
done
w=$root/tests/forge-watchdog.test.sh
n=$(grep -cE '^unset (.* )?FORGE_TEST_SLOT_HELD( |$)' "$w" || true)
for v in FORGE_TEST_CPUS FORGE_TEST_LOG_DIR; do
  [ "$n" -ge 2 ] && [ "$(grep -E '^unset (.* )?FORGE_TEST_SLOT_HELD( |$)' "$w" | grep -cE " $v( |\$)" || true)" = "$n" ] || fail "forge-watchdog.test.sh unsets FORGE_TEST_SLOT_HELD without $v"
done
jq -e '.env | has("FORGE_MAX_SESSIONS") or has("FORGE_CONCURRENCY") | not' "$root/global/settings.json" >/dev/null || fail "global settings must leave the limits to code"
ok test-slots-nested
fi

finish
