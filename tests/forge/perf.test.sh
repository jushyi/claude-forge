#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

export PERF_STUB=$tmp/stub.sh PERF_FX=$tmp/fx PERF_LOG=$tmp/calls
cat >"$PERF_STUB" <<'EOF'
#!/usr/bin/env bash
echo "$1 $FORGE_PERF_WINDOW $(pwd -P)" >>"$PERF_LOG"
cat "$PERF_FX/$1" 2>/dev/null || true
echo "stub stderr $1" >&2
exit "$(cat "$PERF_FX/$1.exit" 2>/dev/null || echo 0)"
EOF
chmod +x "$PERF_STUB"

today=$(date +%F)
from=$(date -d "-7 days" +%F)

mkrepo() {
  mkdir -p "$1/.forge" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  printf '# Testing\n\n## Commands\n%s\n' "$2" >"$1/.forge/TESTING.md"
  git -C "$1" add -A && git -C "$1" commit -qm init
}
logline() { echo "- Perf log: \`\"\$PERF_STUB\" $1\`"; }
s() { jq -cn --arg m "$1" --argjson v "$2" --arg u "$3" --arg k "$4" '{metric: $m, value: $v, unit: $u, kind: $k, at: "2026-10-28T12:00:00Z"}'; }
samples() { local n=$1; shift; rm -f "$PERF_FX/$n" "$PERF_FX/$n.exit"; mkdir -p "$PERF_FX"; printf '%s\n' "$@" >"$PERF_FX/$n"; }
pl() { local s=0; (cd "$1" && FORGE_ROOT=$1 "$forge" perf pull) >"$tmp/o" 2>"$tmp/e" || s=$?; echo $s; }
said() { echo "stdout: $(cat "$tmp/o") stderr: $(cat "$tmp/e")"; }
snap() { git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain --ignored; cat "$1/.forge/perf.json" 2>/dev/null || echo none; cat "$1/.forge/seeds.md" 2>/dev/null || echo none; }
entry() { jq -cn --arg k "$1" --arg u "$2" --argjson n "$3" --argjson p50 "$4" --argjson p95 "$5" --arg f "$6" --arg t "$today" --argjson prev "$7" '{kind: $k, unit: $u, n: $n, p50: $p50, p95: $p95, window: {from: $f, to: $t}, prev: $prev}'; }
ledger() { jq -n '{metrics: $ARGS.named}' "$@" >"$tmp/ledger"; }
commit_ledger() { cp "$tmp/ledger" "$1/.forge/perf.json" && git -C "$1" add .forge/perf.json && git -C "$1" commit -qm ledger; }

if want pull; then
rm -rf "$tmp/ws" "$PERF_FX" "$PERF_LOG"; mkdir -p "$tmp/ws"
a=$tmp/ws/a c=$tmp/ws/c
mkrepo "$a" "$(logline a)"
mkrepo "$c" '- All tests: `true`'
load=()
for v in 20 3 7 1 15 9 11 2 19 4 18 5 17 6 16 8 14 10 13 12; do load+=("$(s load "$v" ms time)"); done
samples a "warming up" "${load[@]}" "$(s calls 3 n count)" "$(s calls 1 n count)" "$(s calls 2 n count)"
cb=$(snap "$c")
[ "$(pl "$tmp/ws")" = 0 ] || fail "a pull exits 0: $(said)"
[ "$(cat "$PERF_LOG")" = "a 7 $a" ] || fail "the pull runs a's Perf log command once from its top with FORGE_PERF_WINDOW=7 and runs nothing for a repo with no Perf log line: $(cat "$PERF_LOG")"
grep -qxF "stub stderr a" "$tmp/e" || fail "the Perf log command's stderr passes through: $(said)"
grep -q '^perf pull: a: ' "$tmp/o" || fail "the pull prints a line for repo a: $(said)"
want_json=$(ledger --argjson calls "$(entry count n 3 2 3 "$from" null)" --argjson load "$(entry time ms 20 10 19 "$from" null)"; json "$tmp/ledger")
[ "$(json "$a/.forge/perf.json")" = "$want_json" ] || fail "the pull writes n, nearest-rank p50 and p95, the window and a null prev per metric: $(cat "$a/.forge/perf.json")"
[ "$(git -C "$a" log -1 --format=%s)" = "docs(perf): pull $today" ] || fail "the pull commits docs(perf): pull <date>: $(git -C "$a" log -1 --format=%s)"
[ "$(git -C "$a" diff-tree --no-commit-id --name-only -r HEAD)" = .forge/perf.json ] || fail "a pull with no seed commits only .forge/perf.json"
[ ! -e "$a/.forge/seeds.md" ] || fail "a first pull with no prev writes no seed: $(cat "$a/.forge/seeds.md")"
[ -z "$(git -C "$a" status --porcelain)" ] || fail "the pull leaves a's tree clean: $(git -C "$a" status --porcelain)"
[ -f "$a/.git/forge.lock.holder" ] || fail "the pull commits under a's forge.lock"
[ "$(snap "$c")" = "$cb" ] || fail "a repo with no Perf log line is left untouched"

load2=()
for v in "${load[@]}"; do load2+=("$(jq -c '.value *= 2' <<<"$v")"); done
samples a "${load2[@]}" "$(s calls 3 n count)"
rm -f "$PERF_LOG"
w3=$(date -d "-3 days" +%F)
[ "$(cd "$tmp/ws" && FORGE_ROOT=$tmp/ws FORGE_PERF_WINDOW=3 code "$forge" perf pull)" = 0 ] || fail "a second pull exits 0: $(cat "$tmp/out")"
[ "$(cat "$PERF_LOG")" = "a 3 $a" ] || fail "FORGE_PERF_WINDOW passes through to the command: $(cat "$PERF_LOG")"
want_json=$(ledger --argjson calls "$(entry count n 1 3 3 "$w3" '{"n":3,"p50":2,"p95":3}')" --argjson load "$(entry time ms 20 20 38 "$w3" '{"n":20,"p50":10,"p95":19}')"; json "$tmp/ledger")
[ "$(json "$a/.forge/perf.json")" = "$want_json" ] || fail "a second pull carries the previous entry's numbers as prev: $(cat "$a/.forge/perf.json")"
[ "$(cat "$a/.forge/seeds.md")" = "- $today perf metric \`load\`: p95 19 -> 38 ms over $w3..$today" ] || fail "a p95 move over 20% appends one dated seed line and an unmoved p95 none: $(cat "$a/.forge/seeds.md")"
ok pull
fi

if want old-ledger; then
rm -rf "$tmp/one" "$PERF_FX" "$PERF_LOG"
o=$tmp/one
mkrepo "$o" "$(logline one)"
jq -n '{metrics: {load: {kind: "time", unit: "ms", baseline: 5, noise: 1.2, commit: "abc", date: "2026-10-01"}, gone: {kind: "count", unit: "n", baseline: 4, tolerance: 0, commit: "abc", date: "2026-10-01"}}}' >"$tmp/ledger"
commit_ledger "$o"
samples one "$(s load 50 ms time)"
[ "$(pl "$o")" = 0 ] || fail "a pull over an old ledger exits 0: $(said)"
[ "$(cat "$PERF_LOG")" = "one 7 $o" ] || fail "a root that is itself a repo is pulled: $(cat "$PERF_LOG")"
want_json=$(ledger --argjson load "$(entry time ms 1 50 50 "$from" null)"; json "$tmp/ledger")
[ "$(json "$o/.forge/perf.json")" = "$want_json" ] || fail "an old-ledger entry counts as no prev and the file is overwritten in the new shape: $(cat "$o/.forge/perf.json")"
[ ! -e "$o/.forge/seeds.md" ] || fail "an old-ledger entry seeds nothing: $(cat "$o/.forge/seeds.md")"
[ "$(git -C "$o" log -1 --format=%s)" = "docs(perf): pull $today" ] && [ -z "$(git -C "$o" status --porcelain)" ] || fail "the overwrite is committed: $(git -C "$o" log -1 --format=%s) $(git -C "$o" status --porcelain)"
ok old-ledger
fi

seedrepo() {
  rm -rf "$tmp/sd" "$PERF_FX" "$PERF_LOG"
  sd=$tmp/sd
  mkrepo "$sd" "$(logline sd)"
  ledger --argjson up "$(entry time ms 1 10 10 "$from" null)" --argjson edge "$(entry time ms 1 10 10 "$from" null)" \
    --argjson down "$(entry count n 1 10 10 "$from" null)" --argjson flat "$(entry time ms 1 10 10 "$from" null)"
  commit_ledger "$sd"
  samples sd "$(s up 13 ms time)" "$(s edge 12 ms time)" "$(s down 7 n count)" "$(s flat 10.5 ms time)" "$(s new 99 ms time)"
}

if want seed; then
seedrepo
[ "$(pl "$sd")" = 0 ] || fail "a seeding pull exits 0: $(said)"
[ "$(cat "$sd/.forge/seeds.md")" = "- $today perf metric \`down\`: p95 10 -> 7 n over $from..$today
- $today perf metric \`up\`: p95 10 -> 13 ms over $from..$today" ] || fail "only a p95 move over 20% either way seeds, not exactly 20%, 5% or a new metric: $(cat "$sd/.forge/seeds.md")"
[ "$(git -C "$sd" diff-tree --no-commit-id --name-only -r HEAD | sort | tr '\n' ' ')" = ".forge/perf.json .forge/seeds.md " ] || fail "the pull commits perf.json and seeds.md together: $(git -C "$sd" diff-tree --no-commit-id --name-only -r HEAD)"
[ -z "$(git -C "$sd" status --porcelain)" ] || fail "a seeding pull leaves the tree clean"
ok seed
fi

if want seed-dedupe; then
seedrepo
printf '# Seeds\n\n- 2026-10-01 an older idea\n- %s perf metric `up`: p95 10 -> 13 ms over %s..%s\n' "$today" "$from" "$today" >"$sd/.forge/seeds.md"
git -C "$sd" add .forge/seeds.md && git -C "$sd" commit -qm seeds
[ "$(pl "$sd")" = 0 ] || fail "a pull with an existing seed line exits 0: $(said)"
[ "$(cat "$sd/.forge/seeds.md")" = "# Seeds

- 2026-10-01 an older idea
- $today perf metric \`up\`: p95 10 -> 13 ms over $from..$today
- $today perf metric \`down\`: p95 10 -> 7 n over $from..$today" ] || fail "an identical seed line is not appended twice and new ones append at the end: $(cat "$sd/.forge/seeds.md")"
samples sd "$(s up 13 ms time)" "$(s edge 12 ms time)" "$(s down 7 n count)" "$(s flat 10.5 ms time)" "$(s new 99 ms time)"
[ "$(pl "$sd")" = 0 ] || fail "a pull with unchanged numbers exits 0: $(said)"
[ "$(grep -c 'perf metric' "$sd/.forge/seeds.md")" = 2 ] || fail "a rerun seeds nothing new: $(cat "$sd/.forge/seeds.md")"
ok seed-dedupe
fi

if want skip; then
rm -rf "$tmp/ws" "$PERF_FX" "$PERF_LOG"; mkdir -p "$tmp/ws"
for n in fails good bad empty; do mkrepo "$tmp/ws/$n" "$(logline "$n")"; done
mkrepo "$tmp/ws/nocmd" '- Perf log: none yet'
mkrepo "$tmp/ws/missing" '- Perf log: `./no-such-perf-log.sh`'
samples fails "$(s load 1 ms time)"; echo 3 >"$PERF_FX/fails.exit"
samples good "$(s load 4 ms time)"
samples bad "$(s load 4 ms time)" '{"metric":"load","value":-1,"unit":"ms","kind":"time"}'
samples empty "nothing here"
before=()
for n in fails nocmd missing bad empty; do before+=("$(snap "$tmp/ws/$n")"); done
[ "$(pl "$tmp/ws")" = 0 ] || fail "a failing or missing Perf log command never fails the pull: $(said)"
grep -q "^forge: perf pull: fails: .*exited 3.*skipped" "$tmp/e" || fail "a failing command is reported on stderr with its exit and skipped: $(said)"
grep -q "^forge: perf pull: nocmd: .*no backticked command.*skipped" "$tmp/e" || fail "a Perf log line with no command is reported on stderr and skipped: $(said)"
grep -q "^forge: perf pull: missing: .*exited 127.*skipped" "$tmp/e" || fail "a missing command is reported on stderr and skipped: $(said)"
grep -q "^forge: perf pull: bad: .*bad metric line 2.*skipped" "$tmp/e" || fail "a bad metric line is reported on stderr and skipped: $(said)"
grep -q "^forge: perf pull: empty: .*no metric lines.*skipped" "$tmp/e" || fail "a command printing no metric lines is reported on stderr and skipped: $(said)"
! grep -q '^forge: perf pull' "$tmp/o" || fail "skips are not on stdout: $(said)"
i=0
for n in fails nocmd missing bad empty; do
  [ "$(snap "$tmp/ws/$n")" = "${before[$i]}" ] || fail "a skipped repo $n is left untouched"
  i=$((i + 1))
done
[ "$(jq -c '.metrics.load | [.n, .p95]' "$tmp/ws/good/.forge/perf.json")" = "[1,4]" ] && [ "$(git -C "$tmp/ws/good" log -1 --format=%s)" = "docs(perf): pull $today" ] || fail "a good repo beside skipped ones is still pulled and committed"
ok skip
fi

if want usage; then
rm -rf "$tmp/one" "$PERF_FX" "$PERF_LOG"
o=$tmp/one
mkrepo "$o" "$(logline one)"
samples one "$(s load 50 ms time)"
before=$(snap "$o")
for args in "" bogus check record "ab $tmp" "stop 1" "pull extra"; do
  [ "$(cd "$o" && FORGE_ROOT=$o code "$forge" perf $args)" = 2 ] || fail "forge perf $args exits 2 through usage: $(cat "$tmp/out")"
done
for v in 0 -1 abc 1.5; do
  [ "$(cd "$o" && FORGE_ROOT=$o FORGE_PERF_WINDOW=$v code "$forge" perf pull)" != 0 ] || fail "FORGE_PERF_WINDOW='$v' fails: $(cat "$tmp/out")"
  grep -q FORGE_PERF_WINDOW "$tmp/out" || fail "a bad FORGE_PERF_WINDOW is named: $(cat "$tmp/out")"
done
[ ! -e "$PERF_LOG" ] || fail "a usage error runs nothing: $(cat "$PERF_LOG")"
[ "$(snap "$o")" = "$before" ] || fail "a usage error writes nothing"
ok usage
fi

finish
