#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"
suite=forge-gates-setup
. "$(dirname "$0")/forge-gates-common.sh"

if want own-tiers; then
o=$tmp/own
mkdir -p "$o/.forge" "$o/tests" && gitinit "$o"
cp "$root/.forge/TESTING.md" "$o/.forge/"
cp "$root/tests/forge.test.sh" "$o/tests/"
printf '#!/usr/bin/env bash\nexit 1\n' >"$o/tests/a.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$o/tests/b.test.sh"
chmod +x "$o"/tests/*.sh
git -C "$o" add -A && git -C "$o" commit -q -m init
[ "$(code "$forge" test "$o")" != 0 ] && grep -q '^FAIL a (exit 1, ' "$o/.git/forge-test.log" || fail "forge's own All tests command fails when a suite fails: $(cat "$tmp/out" "$o/.git/forge-test.log")"
rm "$o"/tests/[ab].test.sh
cp "$root/tests/changed.sh" "$root/tests/forge.test.sh" "$o/tests/"
mkdir -p "$o/tests/forge"
stub() {
  sed "s|NAME|$1|g" >"$o/tests/$1.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "NAME${*:+ $*}" >>"$T_LOG"
echo "out NAME"
if [ -n "${T_RUN:-}" ]; then echo "+ NAME" >>"$T_RUN"; sleep "${T_SLEEP:-0}"; echo "- NAME" >>"$T_RUN"; fi
if [ "${T_HANG:-}" = NAME ]; then echo $$ >"$T_PID"; exec sleep 30; fi
rc=$(awk -v n=NAME '$1 == n { print $2 }' "${T_FAIL:-/dev/null}")
exit "${rc:-0}"
EOF
}
stubs=(forge-gates forge-gates-lint forge-gates-tiers forge-gates-resources forge-gates-setup forge-commit forge-land forge-review forge-watchdog forge-release forge-agent-write forge-init port forge/budget forge/commit forge/help forge/run forge/run-parallel forge/state)
for s in "${stubs[@]}"; do stub $s; done
common=(forge-gates forge-gates-lint forge-gates-tiers forge-gates-resources forge-gates-setup forge-commit forge/budget forge/commit forge/help forge/run forge/run-parallel forge/state)
for s in "${common[@]}"; do d=; [[ $s != forge/* ]] || d=/..; sed -i "1a . \"\$(dirname \"\$0\")$d/forge-common.sh\"" "$o/tests/$s.test.sh"; done
: >"$o/tests/forge-common.sh"
chmod +x "$o"/tests/*.sh "$o"/tests/forge/*.sh
git -C "$o" add -A && git -C "$o" commit -q -m suites && git -C "$o" checkout -q -b side
git -C "$o" worktree add -q --detach "$tmp/ownwt"
mkdir -p "$tmp/runbin" "$tmp/rl" "$tmp/tmpd"
printf '#!/usr/bin/env bash\necho "$NPROC"\n' >"$tmp/runbin/nproc" && chmod +x "$tmp/runbin/nproc"
sum=$o/.git/forge-test/suite-seconds
allstubs=$(printf '%s\n' "${stubs[@]}" | sort | paste -sd' ')
norm() { sed -E 's#^tests/##; s#\.test\.sh$##'; }
runner() { : >"$T_LOG"; rm -f "$tmp/rec"; code env PATH="$tmp/runbin:$PATH" NPROC=24 T_RUN="$tmp/rec" "$@" tests/forge.test.sh; }
lines() { grep -E '^(ok|FAIL) ' "$tmp/out" | sed -E 's#^(ok|FAIL) (tests/)?([^ ]+)#\1 \3#; s#^(ok|FAIL) ([^ ]+)\.test\.sh #\1 \2 #; s#\([0-9]+s\)$#(Ns)#; s#, [0-9]+s, #, Ns, #' || true; }
peak() { awk '$1 == "+" { c++; if (c > m) m = c } $1 == "-" { c-- } END { print m + 0 }' "$tmp/rec"; }
sec() { awk -v n="$1" '{ m = $2; sub(/^tests\//, "", m); sub(/\.test\.sh$/, "", m); if (m == n) print $1 }' "$sum"; }
seed() {
  local i=0 s
  : >"$tmp/seed"
  for s in $1; do echo "$s $((900 - i * 10))" >>"$tmp/seed"; i=$((i + 1)); done
  awk 'NR == FNR { t[$1] = $2; next } { n = $2; sub(/^tests\//, "", n); sub(/\.test\.sh$/, "", n); if (n in t) print t[n], $2 }' "$tmp/seed" "$sum" >"$sum.new" && mv "$sum.new" "$sum"
}
cd "$o"
[ "$(runner FORGE_TEST_CPUS=1 FORGE_TEST_LOG_DIR="$tmp/rl")" = 0 ] || fail "tests/forge.test.sh exits 0 when every suite passes: $(cat "$tmp/out")"
[ "$(ran | sort | paste -sd' ')" = "$allstubs" ] || fail "tests/forge.test.sh runs every top-level and per-command suite once: $(ran)"
[ "$(lines | grep -c '^ok [^ ]* (Ns)$')" = ${#stubs[@]} ] && [ "$(lines | cut -d' ' -f2 | sort | paste -sd' ')" = "$allstubs" ] || fail "tests/forge.test.sh prints one 'ok <suite> (<s>s)' line per suite: $(cat "$tmp/out")"
[ "$(ran | paste -sd' ')" = "$(grep -E '^(ok|FAIL) ' "$tmp/out" | cut -d' ' -f2 | sort | norm | paste -sd' ')" ] || fail "tests/forge.test.sh starts suites alphabetically without a previous summary: $(ran | paste -sd' ')"
[ -f "$sum" ] && [ "$(wc -l <"$sum")" = ${#stubs[@]} ] && ! grep -vqE '^[0-9]+ [^ ]+$' "$sum" && [ "$(cut -d' ' -f2 "$sum" | norm | sort | paste -sd' ')" = "$allstubs" ] ||
  fail "tests/forge.test.sh leaves one '<seconds> <suite>' line per suite in <git common dir>/forge-test/suite-seconds: $(cat "$sum" 2>/dev/null)"
order="port forge/run forge-gates forge-gates-lint forge-gates-tiers forge-gates-resources forge-gates-setup forge/budget forge-commit forge/help forge-land forge-review forge-watchdog forge-release forge/run-parallel forge-agent-write forge/commit forge-init"
seed "$order"
[ "$(wc -l <"$sum")" = 18 ] || fail "the seeded summary keeps 18 suites: $(cat "$sum")"
cd "$tmp/ownwt"
[ "$(runner FORGE_TEST_CPUS=1 FORGE_TEST_LOG_DIR="$tmp/rl")" = 0 ] || fail "tests/forge.test.sh passes in a linked worktree: $(cat "$tmp/out")"
[ "$(ran | grep -vx forge/state | paste -sd' ')" = "$order" ] || fail "tests/forge.test.sh starts the longest suite first from the common dir's previous summary: $(ran | paste -sd' ')"
[ "$(ran | grep -cx forge/state)" = 1 ] || fail "a suite missing from the previous summary still runs once: $(ran)"
[ ! -e "$o/.git/worktrees/ownwt/forge-test/suite-seconds" ] && [ "$(wc -l <"$sum")" = ${#stubs[@]} ] || fail "a linked worktree's run writes the summary to the common dir: $(cat "$sum")"
cd "$o"
seed "forge/budget forge-gates"
printf 'forge/budget 3\nforge-commit 4\n' >"$tmp/fails"
rm -rf "$tmp/rl" && mkdir -p "$tmp/rl"
[ "$(runner FORGE_TEST_CPUS=2 FORGE_TEST_LOG_DIR="$tmp/rl" T_SLEEP=0.2 T_FAIL="$tmp/fails")" = 1 ] || fail "tests/forge.test.sh exits 1 when a suite fails: $(cat "$tmp/out")"
[ "$(ran | sort | paste -sd' ')" = "$allstubs" ] || fail "tests/forge.test.sh runs every suite once after a failure: $(ran)"
[ "$(lines | grep -c '^FAIL ')" = 2 ] && lines | grep -qxF "FAIL forge/budget (exit 3, Ns, log $tmp/rl/forge/budget.log)" && lines | grep -qxF "FAIL forge-commit (exit 4, Ns, log $tmp/rl/forge-commit.log)" ||
  fail "tests/forge.test.sh prints one FAIL line per failing suite with its exit, seconds and log: $(cat "$tmp/out")"
[ "$(lines | grep -c '^ok [^ ]* (Ns)$')" = $((${#stubs[@]} - 2)) ] || fail "tests/forge.test.sh prints an ok line for every passing suite after a failure: $(cat "$tmp/out")"
[ "$(cat "$tmp/rl/forge-commit.log")" = "out forge-commit" ] && [ "$(cat "$tmp/rl/forge/commit.log")" = "out forge/commit" ] && [ "$(cat "$tmp/rl/port.log")" = "out port" ] ||
  fail "tests/forge.test.sh writes each suite's output to its own log under FORGE_TEST_LOG_DIR, forge-commit apart from forge/commit: $(cd "$tmp/rl" && find . -type f)"
[ "$(peak)" = 2 ] || fail "tests/forge.test.sh runs FORGE_TEST_CPUS=2 suites at once: $(peak) $(cat "$tmp/rec")"
[ "$(sec forge/budget)" = 900 ] || fail "a failed suite keeps its previous seconds in the summary: $(cat "$sum")"
[ -n "$(sec forge-gates)" ] && [ "$(sec forge-gates)" -lt 890 ] || fail "a passing suite's seconds are rewritten in the summary: $(cat "$sum")"
[ "$(runner NPROC=3 T_SLEEP=0.2 FORGE_TEST_LOG_DIR="$tmp/rl")" = 0 ] && [ "$(peak)" = 3 ] || fail "tests/forge.test.sh runs nproc suites at once when FORGE_TEST_CPUS is unset: $(peak) $(cat "$tmp/out")"
[ "$(runner NPROC=2 T_SLEEP=0.2 FORGE_TEST_CPUS=8 FORGE_TEST_LOG_DIR="$tmp/rl")" = 0 ] && [ "$(peak)" = 2 ] || fail "tests/forge.test.sh caps FORGE_TEST_CPUS at nproc: $(peak) $(cat "$tmp/out")"
for v in 0 x -1; do
  [ "$(runner FORGE_TEST_CPUS="$v" FORGE_TEST_LOG_DIR="$tmp/rl")" != 0 ] && [ -z "$(ran)" ] || fail "tests/forge.test.sh rejects FORGE_TEST_CPUS=$v before running a suite: $(cat "$tmp/out") $(ran)"
done
[ "$(runner FORGE_TEST_CPUS=2 TMPDIR="$tmp/tmpd" T_FAIL="$tmp/fails")" = 1 ] || fail "tests/forge.test.sh without FORGE_TEST_LOG_DIR exits 1 on a failure: $(cat "$tmp/out")"
tl=$(lines | sed -nE 's#^FAIL forge/budget \(exit 3, Ns, log (.*)\)$#\1#p')
[[ $tl == */forge/budget.log ]] && [ "$(cat "$tl")" = "out forge/budget" ] || fail "tests/forge.test.sh without FORGE_TEST_LOG_DIR logs each suite under a temp dir: $tl $(cat "$tmp/out")"
: >"$T_LOG" && rm -f "$tmp/hang.pid"
env PATH="$tmp/runbin:$PATH" NPROC=24 FORGE_TEST_CPUS=2 FORGE_TEST_LOG_DIR="$tmp/rl" T_HANG=forge/budget T_PID="$tmp/hang.pid" tests/forge.test.sh >"$tmp/out" 2>&1 &
rp=$!
for _ in $(seq 100); do [ ! -s "$tmp/hang.pid" ] || break; sleep 0.1; done
hp=$(cat "$tmp/hang.pid" 2>/dev/null || true)
[ -n "$hp" ] || { kill "$rp" 2>/dev/null || true; fail "tests/forge.test.sh starts the hanging suite: $(cat "$tmp/out")"; }
kill -TERM "$rp" 2>/dev/null || true
rs=0 && wait "$rp" || rs=$?
gone=
for _ in $(seq 50); do kill -0 "$hp" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
[ -n "$gone" ] || { kill "$hp" 2>/dev/null || true; fail "a TERM to tests/forge.test.sh TERMs its running suites"; }
[ "$rs" != 0 ] || fail "a TERMed tests/forge.test.sh exits nonzero"
git -C "$o" worktree remove --force "$tmp/ownwt"
mapped() { : >"$T_LOG"; tests/changed.sh "$@" >"$tmp/out" 2>&1 || fail "tests/changed.sh $*: $(cat "$tmp/out")"; ran | sort -u | paste -sd' '; }
[ "$(mapped bin/forge.d/budget.sh)" = forge/budget ] || fail "a command module maps to its own suite: $(ran)"
[ "$(mapped bin/forge.d/state.sh)" = "forge-commit forge-gates forge-gates-lint forge-gates-resources forge-gates-setup forge-gates-tiers forge-review forge-watchdog forge/state" ] || fail "a command module keeps every cross-command suite that exercises it: $(ran)"
[ "$(mapped bin/forge.d/land.sh)" = "forge-land forge-watchdog" ] || fail "the land module maps to the land suite and the watchdog suite that calls it: $(ran)"
[ "$(mapped bin/forge.d/watchdog.sh)" = forge-watchdog ] || fail "the watchdog module maps to the watchdog suite: $(ran)"
[ "$(mapped bin/forge.d/help/budget.txt)" = "forge/budget forge/help" ] || fail "a help text maps to the help suite and its command's suite: $(ran)"
[ "$(mapped bin/forge.d/help/watchdog.txt)" = "forge-watchdog forge/help" ] || fail "the watchdog help text maps to the help suite and the watchdog suite: $(ran)"
every="forge-agent-write forge-commit forge-gates forge-gates-lint forge-gates-resources forge-gates-setup forge-gates-tiers forge-init forge-land forge-release forge-review forge-watchdog forge/budget forge/commit forge/help forge/run forge/run-parallel forge/state port"
[ "$(mapped bin/forge)" = "$every" ] || fail "bin/forge maps to every suite: $(ran)"
[ "$(mapped tests/forge-common.sh)" = "$(printf '%s\n' "${common[@]}" | sort | paste -sd' ')" ] || fail "the shared helper maps to the suites that source it: $(ran)"
[ "$(mapped tests/changed.sh)" = "forge-gates-setup forge-watchdog" ] || fail "the changed-tests mapper maps to the suites that run a copy of it: $(ran)"
[ "$(mapped .forge/TESTING.md)" = "forge-gates-lint forge-gates-setup forge-watchdog" ] || fail "the testing doc maps to the suites that read it, skipping the missing check suite: $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test --one forge/budget:budget-quotas "$o")" = 0 ] && [ "$(ran)" = "forge/budget budget-quotas" ] || fail "forge's Test line runs one case of a per-command suite: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test --one forge-init "$o")" = 0 ] && [ "$(ran)" = forge-init ] || fail "forge's Test line runs a whole suite: $(cat "$tmp/out") $(ran)"
mkdir -p "$o/bin" && echo i >"$o/bin/forge-init" && echo a >"$o/.forge/ARCHITECTURE.md" && git -C "$o" add -A && git -C "$o" commit -q -m init
: >"$T_LOG"
[ "$(code "$forge" test --changed "$o")" = 0 ] && [ "$(ran)" = forge-init ] || fail "forge's Changed tests line runs the suites covering the changed files: $(cat "$tmp/out") $(ran)"
[ "$("$root/tests/forge/help.test.sh" help 2>&1)" = "forge help: ok" ] || fail "tests/forge/<cmd>.test.sh <case> stops after that case"
ok own-tiers
fi

if want test-setup; then
y=$tmp/y
gitinit "$y"
mkdir -p "$y/.forge" "$y/web"
printf '# Testing\n\n## Commands\n- Setup: `./setup.sh`\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$y/.forge/TESTING.md"
cp "$x/t.sh" "$y/t.sh"
cat >"$y/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo setup >>"$T_LOG"
echo "$PWD" >>"$S_PWD"
echo "installing deps"
sleep "${S_SLEEP:-0}"
mkdir -p deps
exit "$(cat "$S_EXIT")"
EOF
chmod +x "$y/setup.sh"
printf 'deps/\n*.log\n' >"$y/.gitignore" && echo '{}' >"$y/web/package.json" && echo a >"$y/a.txt"
git -C "$y" add -A && git -C "$y" commit -q -m init
export S_EXIT=$tmp/sexit S_PWD=$tmp/spwd
echo 0 >"$S_EXIT"
yst=$y/.git/forge-setup
spwd() { sed -e "s#^$y\$#W#" "$S_PWD" | paste -sd,; }
cd "$y"
: >"$T_LOG" && : >"$S_PWD"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[all]" ] || fail "forge test runs Setup before the tests: $(cat "$tmp/out") $(ran)"
[ "$(spwd)" = W ] || fail "with no setup stamp Setup runs once with cwd the worktree top $y: $(cat "$S_PWD")"
[ -d "$y/deps" ] || fail "a Setup in the worktree installs into the worktree: $(ls -A "$y")"
h="$hid $(shash "$y" ./setup.sh)"
[ "$(cat "$yst")" = "$h" ] || fail "a worktree Setup writes the setup stamp, this host's id and the manifests hash: $(cat "$yst" 2>&1)"
[ -e "$y/.git/forge-setup.lock" ] || fail "the setup hash is compared under a lock in the worktree's own git dir: $(ls -A "$y/.git")"
grep -qxF "installing deps" "$y/.git/forge-test.log" && grep -qxF "ran all" "$y/.git/forge-test.log" || fail "Setup and the tests log to one file: $(cat "$y/.git/forge-test.log")"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "the stamp a worktree Setup wrote skips Setup in the next run: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "--one skips Setup on a matching stamp: $(ran)"
echo '{"a": 1}' >"$y/web/package.json"
: >"$T_LOG" && : >"$S_PWD"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[one][a]" ] && [ "$(spwd)" = W ] || fail "--one runs Setup in the worktree when an unstaged nested package.json edit changes the manifests hash: $(cat "$tmp/out") $(ran) $(cat "$S_PWD")"
h1=$(cat "$yst")
[ "$h1" != "$h" ] && [ "$h1" = "$hid $(shash "$y" ./setup.sh)" ] || fail "a worktree Setup on an unstaged manifest edit stamps the hash of the worktree's manifest bytes: $h1"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a full run on the same unstaged edit skips Setup: $(ran)"
git -C "$y" checkout -q -- web/package.json
: >"$T_LOG" && : >"$S_PWD"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[one][a]" ] && [ "$(spwd)" = W ] && [ "$(cat "$yst")" = "$h" ] || fail "reverting the edit runs Setup in the worktree once more and stamps the reverted hash: $(ran) $(cat "$S_PWD") $(cat "$yst")"
mkdir -p "$y/api" && echo '{}' >"$y/api/package.json"
: >"$T_LOG" && : >"$S_PWD"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[one][a]" ] && [ "$(spwd)" = W ] || fail "a new untracked package.json reruns Setup in the worktree: $(cat "$tmp/out") $(ran) $(cat "$S_PWD")"
h2=$(cat "$yst")
[ "$h2" != "$h" ] && [ "$h2" = "$hid $(shash "$y" ./setup.sh)" ] || fail "a Setup on a new untracked manifest stamps a hash covering it: $h2"
mkdir -p "$y/deps/x" && echo '{"b": 1}' >"$y/deps/x/package.json"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] && [ "$(cat "$yst")" = "$h2" ] || fail "an ignored package.json keeps the setup stamp matching and skips Setup: $(ran) $(cat "$yst")"
rm "$y/api/package.json"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[one][a]" ] && [ "$(cat "$yst")" = "$h" ] || fail "removing the untracked manifest reruns Setup and stamps the hash without it: $(ran) $(cat "$yst")"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "an unchanged worktree skips Setup: $(ran)"
echo '{"a": 1}' >"$y/web/package.json" && git -C "$y" commit -q -am manifest
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[one][a]" ] && [ "$(cat "$yst")" = "$h1" ] || fail "--one runs Setup after a committed nested package.json change and stamps its hash: $(ran) $(cat "$yst")"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a committed manifest change runs Setup once, not in every run: $(ran)"
echo b >>"$y/a.txt" && git -C "$y" commit -q -am other
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a non-manifest change keeps the setup stamp matching: $(ran)"
sed -i 's/`\.\/setup\.sh`/`.\/setup.sh --again`/' "$y/.forge/TESTING.md" && git -C "$y" commit -q -am cmd
echo 4 >"$S_EXIT"
: >"$T_LOG" && : >"$S_PWD"
[ "$(code "$forge" test --force)" = 1 ] && [ "$(ran)" = setup ] && [ "$(spwd)" = W ] || fail "a changed Setup command reruns Setup in the worktree and a failed Setup exits 1 before the tests: $(cat "$tmp/out") $(ran) $(cat "$S_PWD")"
[ "$(lastline)" = "forge: setup failed, log $y/.git/forge-test.log" ] || fail "a failed Setup says so: $(lastline)"
[ "$(cat "$yst")" = "$h1" ] || fail "a failed worktree Setup leaves the stamp as it was: $(cat "$yst")"
[ ! -e "$y/.git/forge-test/$hid/$(git -C "$y" rev-parse HEAD^{tree})" ] || fail "a failed Setup records no test stamp"
[ "$(code "$forge" test --one a)" = 1 ] && grep -qxF "forge: setup failed, log $y/.git/forge-test.log" "$tmp/out" || fail "a failed Setup fails --one: $(cat "$tmp/out")"
echo 0 >"$S_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran | paste -sd,)" = "setup,[all]" ] && [ "$(cat "$yst")" = "$hid $(shash "$y" './setup.sh --again')" ] || fail "a passing worktree Setup under a changed command stamps that command's hash: $(ran) $(cat "$yst")"
echo '{"a": 2}' >"$y/web/package.json" && git -C "$y" commit -q -am manifest2
: >"$T_LOG" && : >"$S_PWD"
S_SLEEP=1 "$forge" test --one a >"$tmp/o1" 2>&1 & p1=$!
S_SLEEP=1 "$forge" test --one b >"$tmp/o2" 2>&1 || fail "a concurrent --one passes: $(cat "$tmp/o2")"
wait "$p1" || fail "a concurrent --one passes: $(cat "$tmp/o1")"
[ "$(grep -cx setup "$T_LOG")" = 1 ] && [ "$(spwd)" = W ] && [ "$(cat "$yst")" = "$hid $(shash "$y" './setup.sh --again')" ] || fail "concurrent forge test --one calls on one manifest change run Setup once, in the worktree under the setup lock, and stamp it: $(ran | paste -sd,) $(cat "$S_PWD") $(cat "$yst")"
yt=$tmp/yt
gitinit "$yt"
mkdir -p "$yt/.forge"
printf '# Testing\n\n## Commands\n- Setup: `sleep 30`\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Timeout: `1`\n' >"$yt/.forge/TESTING.md"
cp "$x/t.sh" "$yt/t.sh"
git -C "$yt" add -A && git -C "$yt" commit -q -m init
ytline="forge: tests timed out after 1 min (limit from - Timeout: in $yt/.forge/TESTING.md), log $yt/.git/forge-test.log"
for a in --force "--one a"; do
  : >"$T_LOG"
  t0=$SECONDS
  [ "$(FORGE_TEST_MIN_SECS=1 code timeout 30 "$forge" test $a "$yt")" = 124 ] && [ "$(lastline)" = "$ytline" ] && [ -z "$(ran)" ] && [ $((SECONDS - t0)) -lt 15 ] ||
    fail "forge test $a stops a Setup past its 1 s limit under the timeout and exits 124 with the timeout line, running no test: $(cat "$tmp/out") $(ran)"
  ! grep -qF "setup failed" "$tmp/out" && [ ! -e "$yt/.git/forge-setup" ] && [ ! -e "$yt/.git/forge-test/$hid/$(git -C "$yt" rev-parse HEAD^{tree})" ] ||
    fail "a timed-out Setup ($a) prints no setup failed line and writes no setup or test stamp: $(cat "$tmp/out")"
done
ok test-setup
fi

if want test-quarantine; then
q=$tmp/quar qr=$tmp/qroot qs=$XDG_STATE_HOME/forge/qroot
gitinit "$q"
mkdir -p "$q/.forge" "$qr/.forge/tracks" "$qs/phases/07-flaky" "$qs/phases/02-other" "$qs/features/flaky-lane-2"
qnow=$(date -u +%F)
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n- Quarantine (added %s): `./t.sh quarantine` runs the flaky tests.\n' "$qnow" >"$q/.forge/TESTING.md"
cat >"$q/t.sh" <<'EOF'
#!/usr/bin/env bash
printf '[%s]' "$@" >>"$T_LOG"
echo >>"$T_LOG"
[ -z "${Q_SLOTS:-}" ] || echo "$1 ${FORGE_TEST_SLOT_HELD-unset}" >>"$Q_SLOTS"
echo "ran $*"
[ "$1" = quarantine ] || exit "$(cat "$T_EXIT")"
[ -z "${Q_SLOTS:-}" ] || ls -l /proc/$$/fd >"$Q_SLOTS.fds"
[ -z "${Q_HOLD:-}" ] || until [ -f "$Q_HOLD" ]; do sleep 0.1; done
exit "$(cat "$Q_EXIT")"
EOF
chmod +x "$q/t.sh"
echo a >"$q/a.txt" && echo '*.log' >"$q/.gitignore"
git -C "$q" add -A && git -C "$q" commit -q -m init
export Q_EXIT=$tmp/qexit
echo 0 >"$Q_EXIT"
echo 0 >"$T_EXIT"
qlog=$q/.git/forge-test.log qst=$q/.git/forge-test
qrl=$qst/runs.log pe=$qs/phases/07-flaky/events.jsonl fe=$qs/features/flaky-lane-2/events.jsonl
qtree() { git -C "$q" rev-parse HEAD^{tree}; }
qshort() { git -C "$q" rev-parse --short HEAD^{tree}; }
qruns() { [ -f "$qrl" ] && wc -l <"$qrl" || echo 0; }
qexit() { local -a f; read -ra f <<<"$(tail -n1 "$qrl")"; echo "${f[6]}"; }
qlogged() { grep '^ran ' "$qlog" | paste -sd,; }
qevents() { { cat "$qs"/phases/*/events.jsonl "$qs"/features/*/events.jsonl "$qr"/.forge/*/*/events.jsonl 2>/dev/null || :; } | wc -l; }
qevent() { [ "$(wc -l <"$1")" = "$2" ] && tail -n1 "$1" | jq -e --arg m "exit 3, log $qlog" 'keys == ["message", "step", "time"] and .step == "quarantine" and .message == $m and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' >/dev/null; }
notgating="forge: quarantine failed (exit 3); not gating"
cd "$tmp"
: >"$T_LOG"
[ "$(code "$forge" test "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] || fail "a passing full run then runs the Quarantine command: $(cat "$tmp/out") $(ran)"
[ "$(cat "$tmp/out")" = "forge: tests passed ($(qshort))" ] || fail "a passing quarantine prints nothing extra: $(cat "$tmp/out")"
[ "$(qlogged)" = "ran all,ran quarantine" ] || fail "the quarantine appends to the full run's log: $(cat "$qlog")"
[ -f "$qst/$hid/$(qtree)" ] || fail "a full pass with a quarantine records a full stamp"
[ "$(qruns)" = 1 ] && [ "$(qexit)" = 0 ] || fail "a full run with a quarantine appends one runs.log line: $(cat "$qrl" 2>/dev/null)"
echo u >"$q/u.txt"
: >"$T_LOG"
[ "$(code "$forge" test --changed "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[changed][u.txt]" ] || fail "a passing changed run runs no Quarantine command: $(cat "$tmp/out") $(ran)"
[ "$(qlogged)" = "ran changed u.txt" ] && ! grep -q quarantine "$tmp/out" || fail "a passing changed run logs no quarantine: $(cat "$qlog") $(cat "$tmp/out")"
[ "$(qruns)" = 2 ] || fail "a changed run with a quarantine line appends one runs.log line: $(cat "$qrl")"
git -C "$q" add u.txt && git -C "$q" commit -q -m u
[ "$(code "$forge" test --passed --changed "$q")" = 0 ] || fail "a changed pass with a quarantine records a changed stamp: $(cat "$tmp/out")"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] || fail "a capped run runs the quarantine: $(cat "$tmp/out") $(ran)"
[ "$(scopes | wc -l)" = 3 ] && [[ $(scopes | sed -n 3p) =~ ^--user\ --scope\ --quiet\ --unit=[^\ ]+\ --expand-environment=no\ -p\ MemoryMax=4G\ -p\ MemoryHigh=3774873K\ -p\ MemorySwapMax=0\ --\ . ]] && ! grep -qF CPUWeight "$SD_LOG" ||
  fail "a capped run runs the quarantine in a memory-capped scope with no CPUWeight: $(cat "$SD_LOG")"
[ "$(qlogged)" = "ran all,ran quarantine" ] && [ "$(qruns)" = 3 ] || fail "a capped quarantine logs to the run's log and adds no runs.log line: $(cat "$qlog") $(cat "$qrl")"
mem 0 "" 1
[ "$(PATH=$sd:$PATH SC_OOM_UNIT='*-q.scope' FORGE_ROOT=$qr FORGE_PHASE=07 code "$forge" test --force "$q")" = 0 ] &&
  grep -qxF "forge: quarantine failed (exit 137); not gating" "$tmp/out" || fail "a capped quarantine whose scope Result is oom-kill fails with exit 137: $(cat "$tmp/out")"
[ "$(wc -l <"$pe")" = 1 ] && tail -n1 "$pe" | jq -e --arg m "exit 137, log $qlog" '.step == "quarantine" and .message == $m' >/dev/null &&
  q7=$(units | grep -- '-q$') && grep -qxF -- "--user show -p Result --value $q7.scope" "$SC_LOG" && reset ||
  fail "a quarantine oom-kill appends its event and reads the Result before resetting the scope: $(cat "$pe" 2>/dev/null) $(cat "$SC_LOG")"
rm -f "$pe"
rm -f "$tmp/qgo" "$tmp/qslots" "$tmp/qslots.fds"
: >"$T_LOG"
FORGE_TEST_RUNS=1 Q_HOLD=$tmp/qgo Q_SLOTS=$tmp/qslots "$forge" test --force "$q" >"$tmp/qhold.out" 2>&1 & qp=$!
for _ in $(seq 100); do grep -q '^quarantine ' "$tmp/qslots" 2>/dev/null && break; sleep 0.1; done
as=$(sed -n 's/^all //p' "$tmp/qslots" 2>/dev/null || true)
free=
[ -n "$as" ] && [ -f "$as" ] && flock -n "$as" true && free=1
touch "$tmp/qgo"
wait $qp || fail "a held quarantine run passes once released: $(cat "$tmp/qhold.out")"
[ -n "$free" ] && [ "$(sed -n 's/^quarantine //p' "$tmp/qslots")" = unset ] ||
  fail "the quarantine runs after the gated run releases its run slot: $(cat "$tmp/qslots" 2>/dev/null) $(cat "$tmp/qhold.out")"
! grep -q waiting "$tmp/qhold.out" || fail "the quarantine takes no second slot: $(cat "$tmp/qhold.out")"
! grep -q test-runs "$tmp/qslots.fds" || fail "the quarantine command holds no run slot fd: $(cat "$tmp/qslots.fds")"
echo 3 >"$Q_EXIT"
rm -f "$qst/$hid/$(qtree)"
n=$(qruns)
: >"$T_LOG"
s=0
FORGE_PHASE=07 "$forge" test --force "$q" >"$tmp/qstdout" 2>"$tmp/qerr" || s=$?
[ "$s" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] || fail "a failing quarantine never fails the run: $s $(cat "$tmp/qstdout" "$tmp/qerr") $(ran)"
grep -qxF "$notgating" "$tmp/qerr" || fail "a failing quarantine prints the not-gating line on stderr: $(cat "$tmp/qerr")"
[ "$(cat "$tmp/qstdout")" = "forge: tests passed ($(qshort))" ] || fail "a failing quarantine keeps the pass line: $(cat "$tmp/qstdout")"
[ -f "$qst/$hid/$(qtree)" ] || fail "a failing quarantine still records the stamp"
[ "$(qruns)" = $((n + 1)) ] && [ "$(qexit)" = 0 ] || fail "a failing quarantine adds no runs.log line and never logs its exit code: $(cat "$qrl")"
[ "$(qevents)" = 0 ] && [ -z "$(find "$q" "$tmp" -maxdepth 1 -name events.jsonl)" ] || fail "a failing quarantine outside a forge session writes no event"
git -C "$q" checkout -q -b forge/flaky-lane-2
[ "$(FORGE_ROOT=$qr FORGE_PHASE=07 code "$forge" test --force "$q")" = 0 ] && grep -qxF "$notgating" "$tmp/out" || fail "a failing quarantine in a phase session passes and says so: $(cat "$tmp/out")"
qevent "$pe" 1 || fail "a failing quarantine in a phase session appends a quarantine event with its exit and log to the phase: $(cat "$pe" 2>/dev/null)"
[ ! -e "$fe" ] && [ ! -e "$qs/phases/02-other/events.jsonl" ] || fail "a phase session's event goes only to its phase"
[ "$(FORGE_ROOT=$qr code "$forge" test --force "$q")" = 0 ] && grep -qxF "$notgating" "$tmp/out" || fail "a failing quarantine on a feature branch passes and says so: $(cat "$tmp/out")"
qevent "$fe" 1 || fail "a failing quarantine on a forge/<t>-<f> branch appends a quarantine event to the feature: $(cat "$fe" 2>/dev/null)"
[ "$(wc -l <"$pe")" = 1 ] && [ ! -e "$qs/phases/02-other/events.jsonl" ] || fail "a feature run derives no phase from the branch name"
[ "$(FORGE_ROOT=$qr FORGE_PHASE=99 code "$forge" test --force "$q")" = 0 ] && qevent "$fe" 2 ||
  fail "a FORGE_PHASE with no phase dir falls back to the feature: $(cat "$tmp/out") $(cat "$fe")"
n=$(qevents)
[ "$(FORGE_PHASE=07 code "$forge" test --force "$q")" = 0 ] && grep -qxF "$notgating" "$tmp/out" && [ "$(qevents)" = "$n" ] ||
  fail "a forge branch without FORGE_ROOT writes no event: $(cat "$tmp/out")"
git -C "$q" checkout -q -b forge/no-feature
[ "$(FORGE_ROOT=$qr code "$forge" test --force "$q")" = 0 ] && grep -qxF "$notgating" "$tmp/out" && [ "$(qevents)" = "$n" ] ||
  fail "a forge branch without a feature dir writes no event: $(cat "$tmp/out")"
git -C "$q" checkout -q main
[ "$(FORGE_ROOT=$qr code "$forge" test --force "$q")" = 0 ] && grep -qxF "$notgating" "$tmp/out" && [ "$(qevents)" = "$n" ] ||
  fail "a non-forge branch writes no event: $(cat "$tmp/out")"
echo 4 >"$T_EXIT"
n=$(qruns)
: >"$T_LOG"
[ "$(code "$forge" test --force "$q")" = 4 ] && [ "$(ran)" = "[all]" ] || fail "a failed gated run runs no quarantine: $(cat "$tmp/out") $(ran)"
! grep -q quarantine "$tmp/out" && [ "$(qruns)" = $((n + 1)) ] && [ "$(qexit)" = 4 ] || fail "a failed gated run logs only its own exit: $(cat "$tmp/out") $(cat "$qrl")"
echo 0 >"$T_EXIT"
"$forge" test --force "$q" >/dev/null 2>&1
n=$(qruns)
: >"$T_LOG"
[ "$(code "$forge" test "$q")" = 0 ] && [[ $(lastline) == *", cached" ]] && [ -z "$(ran)" ] || fail "a cached run runs no quarantine: $(cat "$tmp/out") $(ran)"
echo n >"$q/.forge/notes.txt" && git -C "$q" add -A && git -C "$q" commit -q -m notes
[ "$(code "$forge" test "$q")" = 0 ] && [[ $(lastline) == *"(docs-only change)" ]] && [ -z "$(ran)" ] || fail "a docs-only carry-over runs no quarantine: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --changed --force --base HEAD "$q")" = 0 ] && [[ $(lastline) == *", no changed files" ]] && [ -z "$(ran)" ] ||
  fail "a run with no changed files runs no quarantine: $(cat "$tmp/out") $(ran)"
[ "$(code "$forge" test --one a "$q")" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "--one runs no quarantine: $(cat "$tmp/out") $(ran)"
! grep -q quarantine "$tmp/out" && [ "$(qruns)" = $((n + 1)) ] && [ "$(tail -n1 "$qrl" | cut -d' ' -f3)" = one ] && [ "$(qexit)" = 0 ] ||
  fail "runs without a gated pass print no quarantine line, and only the --one run adds a runs.log line, of tier one: $(cat "$tmp/out") $(cat "$qrl")"
echo 0 >"$Q_EXIT"
quardoc() { { printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n'; printf '%s\n' "$@"; } >"$q/.forge/TESTING.md"; git -C "$q" add .forge/TESTING.md && git -C "$q" commit -q -m "quarantine doc"; }
qrun() { local s=0; : >"$T_LOG"; "$forge" test "$@" >"$tmp/qstdout" 2>"$tmp/qerr" || s=$?; echo $s; }
qhours() { echo $((($(date +%s) - $(date -u -d "$1" +%s)) / 3600)); }
qwarned() {
  local n
  [ "$(grep -c '^forge: warning: quarantine' "$tmp/qerr")" = 1 ] && ! grep -q warning "$tmp/qstdout" || return 1
  n=$(sed -n "s/^forge: warning: quarantine added $qd3 (\([0-9]*\) h ago); lift it or fix the tests\$/\1/p" "$tmp/qerr")
  [ -n "$n" ] && [ "$n" -ge "$qh0" ] && [ "$n" -le "$(qhours "$qd3")" ]
}
qquiet() { ! grep -q 'warning: quarantine' "$tmp/qerr" "$tmp/qstdout"; }
qout() { cat "$tmp/qstdout" "$tmp/qerr"; }
qd3=$(date -u -d '3 days ago' +%F)
qh0=$(qhours "$qd3")
quardoc '- Changed tests: `./t.sh changed {files}`' "- Quarantine (added $qd3): \`./t.sh quarantine\` runs the flaky tests."
[ "$(qrun --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] && qwarned ||
  fail "a full run with a Quarantine line over 48 h old runs it and warns once on stderr with its date and hours: $(qout) $(ran)"
[ "$(qrun "$q")" = 0 ] && [[ $(tail -n1 "$tmp/qstdout") == *", cached" ]] && [ -z "$(ran)" ] && qwarned ||
  fail "a cached run warns of a Quarantine line over 48 h old: $(qout) $(ran)"
echo n2 >"$q/.forge/notes.txt" && git -C "$q" add -A && git -C "$q" commit -q -m notes2
[ "$(qrun "$q")" = 0 ] && [[ $(tail -n1 "$tmp/qstdout") == *"(docs-only change)" ]] && [ -z "$(ran)" ] && qwarned ||
  fail "a docs-only carry-over warns of a Quarantine line over 48 h old: $(qout) $(ran)"
echo c >"$q/c.txt"
[ "$(qrun --changed --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[changed][c.txt]" ] && qwarned ||
  fail "a changed run warns of a Quarantine line over 48 h old and runs no quarantine: $(qout) $(ran)"
[ "$(qrun --one a "$q")" = 0 ] && [ "$(ran)" = "[one][a]" ] && qwarned ||
  fail "a --one run warns of a Quarantine line over 48 h old and runs no quarantine: $(qout) $(ran)"
[ "$(qrun --repeat 2 --one a "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] && qwarned ||
  fail "a --repeat run warns once per invocation and runs no quarantine: $(qout) $(ran)"
rm "$q/c.txt"
[ "$(qrun --changed --force --base HEAD "$q")" = 0 ] && [[ $(tail -n1 "$tmp/qstdout") == *", no changed files" ]] && [ -z "$(ran)" ] && qwarned ||
  fail "a run with no changed files warns of a Quarantine line over 48 h old: $(qout) $(ran)"
qrun --passed "$q" >/dev/null
qquiet || fail "--passed prints no quarantine age warning: $(qout)"
quardoc '- Changed tests: `./t.sh changed {files}`' "- Quarantine (added $(date -u -d yesterday +%F)): \`./t.sh quarantine\`"
[ "$(qrun --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] && qquiet ||
  fail "a full run with a Quarantine line under 48 h old runs it with no warning: $(qout) $(ran)"
quardoc '- Changed tests: `./t.sh changed {files}`' '- Quarantine: `./t.sh quarantine`'
[ "$(qrun --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] && qquiet ||
  fail "a full run still runs an undated Quarantine line with no warning: $(qout) $(ran)"
echo c >"$q/c.txt"
[ "$(qrun --changed --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[changed][c.txt]" ] && qquiet ||
  fail "a changed run with an undated Quarantine line runs no quarantine and no warning: $(qout) $(ran)"
quardoc '- Quarantine (added): `./t.sh quarantine`'
[ "$(qrun --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] && qquiet ||
  fail "a full run still runs a Quarantine line with a malformed date with no warning: $(qout) $(ran)"
quardoc "- Quarantine (added $qnow): \`./t.sh quarantine\`"
[ "$(qrun --changed --force "$q")" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[quarantine]" ] && qquiet ||
  fail "a --changed run that falls back to the full tier runs the quarantine: $(qout) $(ran)"
rm "$q/c.txt"
ok test-quarantine
fi

if want changed-perf; then
if ! want own-tiers; then
o=$tmp/own
mkdir -p "$o/tests" && cp "$root/tests/changed.sh" "$o/tests/"
fi
cd "$o"
: >"$T_LOG"
[ "$(code tests/changed.sh tests/perf/forge-guard.test.sh)" = 0 ] && [ -z "$(ran)" ] || fail "tests/changed.sh runs no suite for a tests/perf/ path: $(cat "$tmp/out") $(ran)"
cd "$tmp"
ok changed-perf
fi

if want test-stack; then
s="$tmp/s k+1"
gitinit "$s"
mkdir -p "$s/.forge" "$s/sub" "$tmp/sbin"
printf '# Testing\n\n## Commands\n- Setup: `./setup.sh`\n- All tests: `false`\n- Local stack: `./stack.sh` on port 3000 plus the offset.\n- Stack tests: `./st.sh` against it.\n- Local stack: `false`\n' >"$s/.forge/TESTING.md"
cat >"$s/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "setup pwd=$PWD" >>"$K_LOG"
EOF
cat >"$s/st.sh" <<'EOF'
#!/usr/bin/env bash
echo "tests off=${FORGE_PORT_OFFSET-unset} pwd=$PWD" >>"$K_LOG"
echo "stack tests ran"
exit "$(cat "$ST_EXIT")"
EOF
chmod +x "$s"/*.sh
git -C "$s" add -A && git -C "$s" commit -q -m init
stack() { env -u FORGE_PORT_OFFSET PATH="$tmp/sbin:$PATH" ${OFF:+FORGE_PORT_OFFSET=$OFF} "$forge" test --stack "$@"; }
klog() { sed -E -e 's#(\[TMPDIR=/tmp/fg-)[0-9]+\]#\1PID]#' "$K_LOG" 2>/dev/null || true; }
slog=$s/.git/forge-stack.log
unit=forge-stack-s_k_1-$(git -C "$s" rev-parse --absolute-git-dir | tr -d '\n' | sha256sum | cut -c1-8)
stop="systemctl[--user][stop][$unit]"
start() { echo "systemd-run[--user][--collect][--unit][$unit][--working-directory][$s][--setenv][FORGE_PORT_OFFSET=$1][--setenv][PATH=$tmp/sbin:$PATH][--setenv][TMPDIR=/tmp/fg-PID][--setenv][GIT_CEILING_DIRECTORIES=$s/.git/forge-test/tmp${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}][bash][-c][./stack.sh]"; }
cd "$s/sub"
: >"$K_LOG"
[ "$(code stack)" = 0 ] || fail "a passing Stack tests command exits 0: $(cat "$tmp/out") $(klog)"
[ "$(lastline)" = "forge: stack tests passed" ] || fail "stack pass line: $(lastline)"
[ "$(klog | paste -sd'|')" = "$stop|setup pwd=$s|$(start 0)|tests off=0 pwd=$s|$stop" ] || fail "a leftover unit stops first, then with no setup stamp Setup runs in the worktree, the stack starts on offset 0 when unset in the worktree top $s, the tests run from it and the unit stops last: $(klog)"
[ "$(cat "$s/.git/forge-setup")" = "$hid $(shash "$s" ./setup.sh)" ] || fail "a --stack Setup in the worktree writes the setup stamp: $(cat "$s/.git/forge-setup" 2>&1)"
: >"$K_LOG"
[ "$(code stack)" = 0 ] && [ "$(klog | head -n1)" = "$stop" ] || fail "the stamp a --stack Setup wrote skips Setup in the next --stack run: $(cat "$tmp/out") $(klog)"
grep -qxF "systemd-run stub output" "$slog" && grep -qxF "stack tests ran" "$slog" || fail "the systemd-run and Stack tests output go to forge-stack.log: $(cat "$slog" 2>/dev/null)"
: >"$K_LOG"
[ "$(OFF=40 code stack "$s")" = 0 ] || fail "a dir argument runs the stack there: $(cat "$tmp/out")"
[ "$(klog | paste -sd'|')" = "$stop|$(start 40)|tests off=40 pwd=$s|$stop" ] || fail "FORGE_PORT_OFFSET reaches the unit and the tests, and a stamp equal to the manifests hash skips Setup: $(klog)"
for e in 2 3 5 75; do
  echo $e >"$ST_EXIT"
  : >"$K_LOG"
  x=$e
  [ $e -ne 5 ] && [ $e -ne 2 ] && [ $e -ne 75 ] || x=1
  [ "$(code stack "$s")" = $x ] || fail "Stack tests exiting $e exits $x: $(cat "$tmp/out")"
  [ "$(lastline)" = "forge: stack tests failed, log $slog" ] || fail "stack fail line: $(lastline)"
  [ "$(klog | tail -n1)" = "$stop" ] || fail "a failing Stack tests command still stops the unit: $(klog)"
done
echo 0 >"$ST_EXIT"
mkdir -p "$tmp/o" && cp -a "$s" "$tmp/o/"
: >"$K_LOG"
[ "$(code stack "$tmp/o/s k+1")" = 0 ] || fail "a second repo with the same worktree name passes: $(cat "$tmp/out")"
u2=$(klog | sed -n 's/^systemctl\[--user\]\[stop\]\[\(.*\)\]$/\1/p' | head -n1)
case $u2 in forge-stack-s_k_1-????????) [ "$u2" != "$unit" ] ;; *) false ;; esac || fail "worktrees of the same name in two repos get distinct units: $unit $u2"
echo 5 >"$SC_EXIT"
: >"$K_LOG"
[ "$(code stack "$s")" = 0 ] && [ "$(lastline)" = "forge: stack tests passed" ] || fail "an already-gone unit (stop exits 5) still passes: $(cat "$tmp/out")"
echo 1 >"$SC_EXIT"
: >"$K_LOG"
[ "$(code stack "$s")" = 1 ] || fail "a previous unit that fails to stop exits 1: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: cannot stop the previous stack unit $unit, log $slog" ] || fail "names the previous unit that did not stop: $(lastline)"
[ "$(klog)" = "$stop" ] || fail "a previous unit that fails to stop runs no Setup, stack or tests: $(klog)"
printf '0\n1\n' >"$SC_EXIT"
: >"$K_LOG"
[ "$(code stack "$s")" = 1 ] || fail "a unit that fails to stop exits 1: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: stack tests passed but unit $unit did not stop, log $slog" ] || fail "names the unit that did not stop: $(lastline)"
[ -n "$(ls -A "$s/.git/forge-test/tmp")" ] || fail "a unit that fails to stop keeps its TMPDIR"
echo 0 >"$SC_EXIT"
echo 0 >"$ST_EXIT" && echo 1 >"$SR_EXIT"
: >"$K_LOG"
[ "$(code stack "$s")" = 1 ] || fail "a failing systemd-run exits 1: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: local stack failed to start, log $slog" ] || fail "names the failed start: $(lastline)"
! klog | grep -q '^tests' || fail "a failed start runs no Stack tests: $(klog)"
echo 0 >"$SR_EXIT"
mkdir -p "$XDG_RUNTIME_DIR/forge/test-runs"
exec 7>"$XDG_RUNTIME_DIR/forge/test-runs/1"
flock 7
[ "$(FORGE_TEST_RUNS=1 code timeout 20 env PATH="$tmp/sbin:$PATH" "$forge" test --stack "$s")" = 0 ] && ! grep -q waiting "$tmp/out" || fail "--stack takes no run slot: $(cat "$tmp/out")"
exec 7>&-
[ -z "$(find "$s/.git/forge-test" -mindepth 1 ! -path "$s/.git/forge-test/tmp" 2>/dev/null)" ] && [ ! -e "$s/.claude" ] && [ "$(git -C "$s" worktree list --porcelain | grep -c '^worktree ')" = 1 ] || fail "--stack writes no stamp, leaves no TMPDIR and creates no _snap snapshot, snap-owner record or registered worktree: $(find "$s/.git/forge-test" "$s/.claude" -maxdepth 2 2>&1) $(git -C "$s" worktree list)"
for a in "--changed" "--one a" "--passed" "--base main" "--force" "--changed --stack"; do
  : >"$K_LOG"
  [ "$(code env PATH="$tmp/sbin:$PATH" "$forge" test --stack $a "$s")" = 2 ] || fail "forge test --stack $a is a usage error: $(cat "$tmp/out")"
  [ -z "$(klog)" ] || fail "forge test --stack $a starts nothing: $(klog)"
done
n=$tmp/s5
gitinit "$n" && mkdir -p "$n/.forge" && git -C "$n" commit -q --allow-empty -m init
for doc in "" '- Local stack: `./stack.sh`' '- Stack tests: `./st.sh`' '- All tests: `true`'; do
  rm -f "$n/.forge/TESTING.md"
  [ -z "$doc" ] || printf '# Testing\n\n## Commands\n%s\n' "$doc" >"$n/.forge/TESTING.md"
  : >"$K_LOG"
  [ "$(code stack "$n")" = 5 ] || fail "TESTING.md with ${doc:-no file} exits 5: $(cat "$tmp/out")"
  [ "$(cat "$tmp/out")" = "forge: no \"- Local stack:\" or \"- Stack tests:\" line in $n/.forge/TESTING.md; stack not run" ] || fail "names the missing stack line: $(cat "$tmp/out")"
  [ -z "$(klog)" ] || fail "a missing stack line starts nothing: $(klog)"
done
sx=$tmp/sx
gitinit "$sx" && mkdir -p "$sx/.forge"
sxdoc() { printf '# Testing\n\n## Commands\n- Setup: `%s`\n- All tests: `false`\n- Local stack: `./stack.sh`\n- Stack tests: `./st.sh`\n- Timeout: `1`\n' "$1" >"$sx/.forge/TESTING.md"; git -C "$sx" add -A && git -C "$sx" commit -q -m "$1"; }
printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'echo tests >>"$K_LOG"' >"$sx/st.sh"
chmod +x "$sx/st.sh"
sxdoc 'sleep 30'
: >"$K_LOG"
t0=$SECONDS
[ "$(FORGE_TEST_MIN_SECS=1 code stack "$sx")" = 124 ] && [ "$(lastline)" = "forge: tests timed out after 1 min (limit from - Timeout: in $sx/.forge/TESTING.md), log $sx/.git/forge-stack.log" ] && [ $((SECONDS - t0)) -lt 15 ] ||
  fail "a --stack Setup past its 1 s limit is stopped under the timeout and exits 124 with the timeout line naming forge-stack.log: $(cat "$tmp/out")"
! klog | grep -q -e '^systemd-run' -e '^tests' || fail "a timed-out --stack Setup starts no stack and runs no Stack tests: $(klog)"
sxdoc true
: >"$K_LOG"
[ "$(FORGE_TEST_MIN_SECS=1 code stack "$sx")" = 0 ] && [ "$(lastline)" = "forge: stack tests passed" ] && klog | grep -qx tests ||
  fail "--stack's Stack tests have no time limit, so a 2 s Stack tests command passes under a 1 s Timeout: $(cat "$tmp/out") $(klog)"
ok test-stack
fi

if want test-tmpdir; then
cd "$tmp"
td=$tmp/tmpdir tw=$tmp/tmpdir-wt
gitinit "$td"
mkdir -p "$td/.forge" "$tmp/outer"
cat >"$td/t.sh" <<'EOF'
#!/usr/bin/env bash
d=${TMPDIR-unset}
r=$(readlink "$d" 2>/dev/null) || r=none
c=missing
[ ! -d "$d" ] || c=$(ls -A "$d" | paste -sd,)
m=$(mktemp -d)
g=isolated
(cd "$m" && git rev-parse --git-dir) >/dev/null 2>&1 && g=in-repo
echo "$1|$d|$r|$c|$g|${GIT_CEILING_DIRECTORIES-unset}" >>"$TD_LOG"
echo junk >"$m/junk"
[ ! -d "$d" ] || echo junk >"$d/junk-$1-$$"
[ -z "${TD_DIRTY:-}" ] || echo dirty >dirty.txt
if [ -n "${TD_HOLD:-}" ] && [ "$1" != setup ]; then while [ ! -e "$TD_HOLD" ]; do sleep 0.1; done; fi
[ "$1" = setup ] || exit "$(cat "$TD_EXIT")"
exit "$(cat "$TD_SEXIT")"
EOF
chmod +x "$td/t.sh"
printf '# Testing\n\n## Commands\n- Setup: `./t.sh setup`\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n- Quarantine (added %s): `./t.sh q`\n- Perf log: `./t.sh perf`\n' "$(date -u +%F)" >"$td/.forge/TESTING.md"
echo a >"$td/a.txt"
git -C "$td" add -A && git -C "$td" commit -q -m init
git -C "$td" worktree add -q "$tw" -b side
echo b >"$tw/b.txt" && git -C "$tw" add -A && git -C "$tw" commit -q -m change
export TD_LOG=$tmp/td.log TD_EXIT=$tmp/td-exit TD_SEXIT=$tmp/td-sexit
echo 0 >"$TD_EXIT" && echo 0 >"$TD_SEXIT"
tst=$(git -C "$tw" rev-parse --path-format=absolute --git-common-dir)/forge-test
[ "$tst" = "$td/.git/forge-test" ] || fail "the linked worktree's common dir is the main repo's: $tst"
twst=$(git -C "$tw" rev-parse --absolute-git-dir)/forge-setup
tdrec() { cat "$TD_LOG" 2>/dev/null || true; }
tdrun() { tds=0; : >"$TD_LOG"; TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling "$forge" test "$@" >"$tmp/out" 2>&1 & tdp=$!; wait "$tdp" || tds=$?; }
tdsaw() {
  local w=/tmp/fg-$tdp rd=$tst/tmp/$tdp t d r c g e n=0
  [ "$(cut -d'|' -f1 "$TD_LOG" | paste -sd,)" = "$2" ] || fail "$1 runs $2: $(tdrec) $(cat "$tmp/out")"
  while IFS='|' read -r t d r c g e; do
    [ "$d" = "$w" ] || fail "$1 exports TMPDIR=$w, named for the forge test pid, to the $t command: $(tdrec)"
    [ "$r" = "$rd" ] || fail "$1 makes $w a symlink to $rd, under the git common dir, for the $t command: $(tdrec)"
    [ $n -gt 0 ] || [ -z "$c" ] || fail "$1 creates $w empty: $(tdrec)"
    [ "$g" = isolated ] || fail "$1: git rev-parse --git-dir fails in a mktemp -d dir made by the $t command: $(tdrec)"
    [ "$e" = "$tst/tmp:$tmp/ceiling" ] || fail "$1 exports GIT_CEILING_DIRECTORIES with $tst/tmp prepended to the inherited value: $(tdrec)"
    n=$((n + 1))
  done <"$TD_LOG"
  [ ! -e "$rd" ] || fail "$1 removes $rd when it ends: $(find "$rd")"
  [ ! -L "$w" ] || fail "$1 removes the symlink $w when it ends: $(ls -l "$w")"
}
tdrun --force "$tw"
[ "$tds" = 0 ] || fail "a full run with Setup and Quarantine passes: $(cat "$tmp/out")"
tdsaw "a full run in a linked worktree" setup,all,q
[ "$(cat "$twst")" = "$hid $(shash "$tw" './t.sh setup')" ] || fail "a Setup in a linked worktree writes the stamp in its own git dir: $(cat "$twst" 2>&1)"
[ -e "${twst%/*}/forge-setup.lock" ] || fail "a run in a linked worktree takes the setup lock in the worktree's own git dir ${twst%/*}: $(ls -A "${twst%/*}")"
tdrun --changed --force "$tw"
[ "$tds" = 0 ] || fail "a changed run passes: $(cat "$tmp/out")"
tdsaw "a changed run" changed
tdrun --one a "$tw"
[ "$tds" = 0 ] || fail "a --one run passes: $(cat "$tmp/out")"
tdsaw "a --one run on a matching setup stamp" one
tdrun --repeat 2 --one a "$tw"
[ "$tds" = 0 ] || fail "a --repeat run passes: $(cat "$tmp/out")"
tdsaw "a --repeat 2 run" one,one
tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run in the main checkout passes: $(cat "$tmp/out")"
tdsaw "a full run in the main checkout" setup,all,q
echo 3 >"$TD_EXIT"
tdrun --force "$tw"
[ "$tds" = 3 ] || fail "a failing full run exits 3: $(cat "$tmp/out")"
tdsaw "a failing full run" all
echo 0 >"$TD_EXIT"
tdt=$(git -C "$tw" rev-parse HEAD^{tree})
[ -z "$(git -C "$tw" status --porcelain)" ] && [ ! -e "$tst/$hid/$tdt" ] || fail "the worktree is clean and its tree unstamped before the run that dirties it: $(git -C "$tw" status --porcelain) $(ls -A "$tst/$hid")"
TD_DIRTY=1 tdrun --force "$tw"
[ "$tds" = 0 ] && ! grep -qF "the worktree changed while tests ran" "$tmp/out" || fail "a run whose worktree changes while it runs passes: $(cat "$tmp/out")"
grep -qxF "forge: tests passed ($(git -C "$tw" rev-parse --short "$tdt"))" "$tmp/out" || fail "a run whose worktree changes reports the start tree: $(cat "$tmp/out")"
[ -f "$tst/$hid/$tdt" ] || fail "a run whose worktree changes stamps the start tree $tdt: $(ls -A "$tst/$hid")"
tdsaw "a run whose worktree changes" all,q
[ "$(cat "$tw/dirty.txt" 2>/dev/null)" = dirty ] || fail "the suite runs in the worktree, so its write lands there: $(ls -A "$tw")"
rm -f "$tw/dirty.txt"
echo 4 >"$TD_SEXIT"
rm -f "$twst"
tdrun --force "$tw"
[ "$tds" = 1 ] && grep -qF "forge: setup failed" "$tmp/out" || fail "a failing Setup exits 1: $(cat "$tmp/out")"
tdsaw "a failing Setup" setup
echo 0 >"$TD_SEXIT"
rm -f "$tmp/td-go"
: >"$TD_LOG"
tds=0
TD_HOLD=$tmp/td-go TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling "$forge" test --force "$tw" >"$tmp/out" 2>&1 & tdp=$!
for _ in $(seq 100); do grep -q '^all|' "$TD_LOG" && break; sleep 0.1; done
grep -q '^all|' "$TD_LOG" || { touch "$tmp/td-go"; fail "the held run starts its tests: $(tdrec) $(cat "$tmp/out")"; }
[ -d "$tst/tmp/$tdp" ] && [ "$(readlink "/tmp/fg-$tdp")" = "$tst/tmp/$tdp" ] || { touch "$tmp/td-go"; fail "a running forge test holds $tst/tmp/$tdp and its symlink /tmp/fg-$tdp: $(tdrec)"; }
kill -TERM "$tdp"
wait "$tdp" || tds=$?
touch "$tmp/td-go"
[ "$tds" = 143 ] || fail "a TERMed run exits 143: $tds $(cat "$tmp/out")"
tdsaw "a TERMed run" setup,all
bash -c : & tdd=$!
wait "$tdd"
sleep 300 & tdl=$!
mkdir -p "$tst/tmp/$tdd/x" "$tst/tmp/$tdl/x"
tdrun --force "$tw"
[ "$tds" = 0 ] || fail "a full run passes beside sibling dirs: $(cat "$tmp/out")"
tdsaw "a full run beside sibling dirs" all,q
[ ! -e "$tst/tmp/$tdd" ] || fail "a run prunes the sibling dir of dead pid $tdd: $(ls -A "$tst/tmp")"
[ -d "$tst/tmp/$tdl/x" ] || fail "a run keeps the sibling dir of live pid $tdl: $(ls -A "$tst/tmp")"
kill "$tdl" && { wait "$tdl" 2>/dev/null || true; }
rm -rf "$tst/tmp/$tdl"
mkdir -p "$tst/tmp/$tdd/x"
for ta in "" "--passed" "--changed --force"; do
  tw2=$tw
  [ "$ta" != "--changed --force" ] || tw2=$td
  tdrun $ta "$tw2"
  [ "$tds" = 0 ] && [ -z "$(tdrec)" ] || fail "forge test $ta $tw2 passes without running a command: $(cat "$tmp/out") $(tdrec)"
  grep -qE 'cached|no changed files|tests passed' "$tmp/out" || fail "forge test $ta reports a cached pass: $(cat "$tmp/out")"
  [ "$(ls -A "$tst/tmp")" = "$tdd" ] && [ -d "$tst/tmp/$tdd/x" ] || fail "forge test $ta creates no TMPDIR: $(ls -A "$tst/tmp")"
done
rm -rf "$tst/tmp/$tdd"
printf -- '- Local stack: `./t.sh stack`\n- Stack tests: `./t.sh st`\n' >>"$tw/.forge/TESTING.md"
tdstack() { tds=0; : >"$TD_LOG"; : >"$K_LOG"; TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling PATH="$tmp/sbin:$PATH" "$forge" test --stack "$tw" >"$tmp/out" 2>&1 & tdp=$!; wait "$tdp" || tds=$?; }
tdenv() { grep -qF "[--setenv][TMPDIR=/tmp/fg-$tdp][--setenv][GIT_CEILING_DIRECTORIES=$tst/tmp:$tmp/ceiling][bash][-c][./t.sh stack]" "$K_LOG" || fail "$1 passes --setenv TMPDIR=/tmp/fg-$tdp and GIT_CEILING_DIRECTORIES=$tst/tmp:$tmp/ceiling to systemd-run: $(cat "$K_LOG")"; }
tdstack
[ "$tds" = 0 ] || fail "a passing --stack run exits 0: $(cat "$tmp/out") $(cat "$K_LOG")"
tdsaw "a passing --stack run" st
tdenv "a passing --stack run"
echo 3 >"$TD_EXIT"
tdstack
[ "$tds" = 3 ] || fail "a failing --stack run exits 3: $(cat "$tmp/out")"
tdsaw "a failing --stack run" st
tdenv "a failing --stack run"
echo 0 >"$TD_EXIT"
echo 1 >"$SR_EXIT"
tdstack
[ "$tds" = 1 ] && grep -qF "local stack failed to start" "$tmp/out" || fail "a --stack run whose stack fails to start exits 1: $(cat "$tmp/out")"
tdsaw "a --stack run whose stack fails to start" ""
tdenv "a --stack run whose stack fails to start"
echo 0 >"$SR_EXIT"
[ -z "$(ls -A "$tst/tmp")" ] || fail "no TMPDIR is left before the unstoppable --stack run: $(ls -A "$tst/tmp")"
tds=0; : >"$TD_LOG"; : >"$K_LOG"
TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling PATH="$tmp/tsbin:$tmp/sbin:$PATH" "$forge" test --stack "$tw" >"$tmp/out" 2>&1 & tdp=$!
wait "$tdp" || tds=$?
tsp=$tdp
tu=$(sed -n 's/.*\[--unit\]\[\([^]]*\)\].*/\1/p' "$K_LOG" | head -n1)
[ "$tds" = 1 ] && grep -qF "did not stop" "$tmp/out" || fail "a --stack run whose unit fails to stop exits 1: $tds $(cat "$tmp/out")"
[ -n "$tu" ] || fail "the --stack run starts a unit: $(cat "$K_LOG")"
[ -d "$tst/tmp/$tsp" ] || fail "a unit that fails to stop keeps its TMPDIR $tst/tmp/$tsp: $(ls -A "$tst/tmp")"
[ "$(readlink "/tmp/fg-$tsp")" = "$tst/tmp/$tsp" ] || fail "a unit that fails to stop keeps its TMPDIR symlink /tmp/fg-$tsp: $(ls -l "/tmp/fg-$tsp" 2>&1)"
[ -n "$(ls -A "$tst/tmp" | grep -vxF "$tsp")" ] || fail "a unit that fails to stop is recorded beside its kept TMPDIR: $(ls -A "$tst/tmp")"
echo 0 >"$TS_STOP"
echo "$tu" >"$TS_ACTIVE"
PATH="$tmp/tsbin:$PATH" tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run passes beside an active stack unit's TMPDIR: $(cat "$tmp/out")"
[ -d "$tst/tmp/$tsp" ] && [ -n "$(ls -A "$tst/tmp/$tsp")" ] || fail "a later forge test keeps the TMPDIR $tst/tmp/$tsp of dead pid $tsp while its recorded unit $tu is active: $(ls -A "$tst/tmp")"
[ -n "$(ls -A "$tst/tmp" | grep -vxF "$tsp")" ] || fail "a later forge test keeps the record of the still-active unit $tu: $(ls -A "$tst/tmp")"
echo 1 >"$TS_BUS"
PATH="$tmp/tsbin:$PATH" tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run passes when the user manager cannot be reached: $(cat "$tmp/out")"
[ -d "$tst/tmp/$tsp" ] && [ -n "$(ls -A "$tst/tmp/$tsp")" ] || fail "a later forge test keeps the TMPDIR $tst/tmp/$tsp of dead pid $tsp when systemctl is-active fails: $(ls -A "$tst/tmp")"
[ -n "$(ls -A "$tst/tmp" | grep -vxF "$tsp")" ] || fail "a later forge test keeps the record of unit $tu when systemctl is-active fails: $(ls -A "$tst/tmp")"
: >"$TS_BUS"
: >"$TS_ACTIVE"
PATH="$tmp/tsbin:$PATH" tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run passes once the stack unit is gone: $(cat "$tmp/out")"
[ -z "$(ls -A "$tst/tmp")" ] || fail "once its recorded unit $tu is inactive the next run prunes the TMPDIR of dead pid $tsp and its record: $(ls -A "$tst/tmp")"
tdreuse() { tds=0; : >"$TD_LOG"; TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling PATH="$tmp/tsbin:$PATH" bash -c 'mkdir -p "$1/$$" && echo keep >"$1/$$/keep" && echo "$2" >"$1/$$.unit" && exec "$3" test --force "$4"' _ "$tst/tmp" "$tu" "$forge" "$td" >"$tmp/out" 2>&1 & tdp=$!; wait "$tdp" || tds=$?; }
echo "$tu" >"$TS_ACTIVE"
tdreuse
[ "$tds" = 1 ] || fail "a forge test whose pid's tmp/$tdp.unit names the active unit $tu fails: $tds $(cat "$tmp/out")"
grep -qF "$tu" "$tmp/out" && grep -qF "systemctl --user stop $tu" "$tmp/out" || fail "a forge test refusing the kept TMPDIR of a reused pid names unit $tu and systemctl --user stop $tu: $(cat "$tmp/out")"
[ "$(cat "$tst/tmp/$tdp/keep" 2>/dev/null)" = keep ] || fail "a forge test under a reused pid $tdp keeps the TMPDIR and files of the active unit $tu: $(ls -A "$tst/tmp" "$tst/tmp/$tdp" 2>&1)"
[ "$(cat "$tst/tmp/$tdp.unit" 2>/dev/null)" = "$tu" ] || fail "a forge test under a reused pid $tdp keeps the record of the active unit $tu: $(ls -A "$tst/tmp")"
[ -z "$(tdrec)" ] || fail "a forge test refusing the kept TMPDIR of a reused pid runs no command: $(tdrec)"
rm -rf "$tst/tmp/$tdp" "$tst/tmp/$tdp.unit"
: >"$TS_ACTIVE"
tdreuse
[ "$tds" = 0 ] || fail "a forge test whose pid's tmp/$tdp.unit names an inactive unit passes: $tds $(cat "$tmp/out")"
tdsaw "a run under a reused pid whose recorded unit is inactive" all,q
[ ! -e "$tst/tmp/$tdp.unit" ] || fail "a forge test under a reused pid $tdp clears the record of the inactive unit $tu: $(ls -A "$tst/tmp")"
[ -z "$(ls -A "$tst/tmp")" ] || fail "a forge test under a reused pid leaves nothing in $tst/tmp: $(ls -A "$tst/tmp")"
tdpre() { tds=0; : >"$TD_LOG"; TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling PATH="$tmp/tsbin:$PATH" bash -c "$1"' && exec "$0" test --force "$1"' "$forge" "$td" "$2" >"$tmp/out" 2>&1 & tdp=$!; wait "$tdp" || tds=$?; }
tdpre 'ln -s "$2" "/tmp/fg-$$"' "$tmp/gone/1"
[ "$tds" = 0 ] || fail "a forge test whose pid has a stale symlink /tmp/fg-$tdp of the user passes: $tds $(cat "$tmp/out")"
tdsaw "a run replacing a stale symlink of its pid" all,q
mkdir -p "$tmp/kept/1" && echo "$tu" >"$tmp/kept/1.unit" && echo "$tu" >"$TS_ACTIVE"
tdpre 'ln -s "$2" "/tmp/fg-$$"' "$tmp/kept/1"
[ "$tds" = 1 ] && grep -qF "/tmp/fg-$tdp" "$tmp/out" && grep -qF "systemctl --user stop $tu" "$tmp/out" || fail "a forge test whose pid's symlink /tmp/fg-$tdp links to the TMPDIR of active unit $tu fails naming the link and unit: $tds $(cat "$tmp/out")"
[ "$(readlink "/tmp/fg-$tdp")" = "$tmp/kept/1" ] && [ -z "$(tdrec)" ] && [ ! -e "$tst/tmp/$tdp" ] || fail "a forge test refusing the symlink of a kept TMPDIR keeps it and runs no command: $(ls -l "/tmp/fg-$tdp" 2>&1) $(tdrec)"
rm -f "/tmp/fg-$tdp"
: >"$TS_ACTIVE"
tdpre ': >"/tmp/fg-$$"' ""
[ "$tds" = 1 ] && grep -qF "/tmp/fg-$tdp is not a symlink" "$tmp/out" || fail "a forge test whose /tmp/fg-$tdp is a plain file fails naming it: $tds $(cat "$tmp/out")"
[ -f "/tmp/fg-$tdp" ] && [ -z "$(tdrec)" ] && [ ! -e "$tst/tmp/$tdp" ] || fail "a forge test refusing a plain /tmp/fg-$tdp keeps it and runs no command: $(ls -l "/tmp/fg-$tdp" 2>&1) $(tdrec)"
rm -f "/tmp/fg-$tdp"
rm -f "$tmp/td-go"
tds=0; : >"$TD_LOG"; : >"$K_LOG"
TD_HOLD=$tmp/td-go TMPDIR=$tmp/outer GIT_CEILING_DIRECTORIES=$tmp/ceiling PATH="$tmp/tsbin:$tmp/sbin:$PATH" "$forge" test --stack "$tw" >"$tmp/out" 2>&1 & tdp=$!
for _ in $(seq 100); do grep -q '^st|' "$TD_LOG" && break; sleep 0.1; done
grep -q '^st|' "$TD_LOG" || { touch "$tmp/td-go"; fail "the held --stack run starts its stack tests: $(tdrec) $(cat "$tmp/out")"; }
echo "$tu" >"$TS_ACTIVE"
kill -KILL "$tdp"
{ wait "$tdp"; } 2>/dev/null || tds=$?
touch "$tmp/td-go"
tsp=$tdp
[ "$tds" = 137 ] || fail "a SIGKILLed --stack run exits 137: $tds $(cat "$tmp/out")"
PATH="$tmp/tsbin:$PATH" tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run passes beside a SIGKILLed --stack run's active unit: $(cat "$tmp/out")"
[ -d "$tst/tmp/$tsp" ] || fail "a later forge test keeps the TMPDIR $tst/tmp/$tsp of the SIGKILLed --stack run while its unit $tu is active: $(ls -A "$tst/tmp")"
[ "$(cat "$tst/tmp/$tsp.unit" 2>/dev/null)" = "$tu" ] || fail "a SIGKILLed --stack run leaves the record of its unit $tu: $(ls -A "$tst/tmp")"
: >"$TS_ACTIVE"
PATH="$tmp/tsbin:$PATH" tdrun --force "$td"
[ "$tds" = 0 ] || fail "a full run passes once the SIGKILLed --stack run's unit is gone: $(cat "$tmp/out")"
[ -z "$(ls -A "$tst/tmp")" ] || fail "once its unit $tu is inactive the next run prunes the TMPDIR of the SIGKILLed --stack run $tsp: $(ls -A "$tst/tmp")"
git -C "$tw" checkout -q -- .forge/TESTING.md
ok test-tmpdir
fi

if want_any test-in-place test-snap-prune; then
cd "$tmp"
sn=$tmp/snap
gitinit "$sn"
mkdir -p "$sn/.forge" && echo .claude/worktrees/ >>"$sn/.git/info/exclude"
cat >"$sn/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "suite $1 out"
echo "$1|$PWD|$(git rev-parse --show-toplevel 2>&1)|$(cat a.txt)|$(cat u.txt 2>/dev/null || echo none)|${GIT_DIR-unset},${GIT_WORK_TREE-unset},${GIT_INDEX_FILE-unset},${GIT_COMMON_DIR-unset}" >>"$SN_LOG"
if { [ "$1" = all ] || [ "$1" = st ]; } && [ -n "${SN_HOLD:-}" ]; then
  : >"$SN_HOLD.on"
  while [ ! -e "$SN_HOLD" ]; do sleep 0.1; done
  echo "after|$(cat a.txt)|$(cat new.txt 2>/dev/null || echo none)" >>"$SN_LOG"
fi
[ "$1" != setup ] || exit 0
exit "$(cat "$SN_EXIT")"
EOF
chmod +x "$sn/t.sh"
printf '# Testing\n\n## Commands\n- Setup: `./t.sh setup`\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n- Quarantine (added %s): `./t.sh q`\n- Perf log: `./t.sh perf`\n- Timeout: `1` minute.\n- Local stack: `./t.sh stack`\n- Stack tests: `./t.sh st`\n' "$(date -u +%F)" >"$sn/.forge/TESTING.md"
echo a1 >"$sn/a.txt"
git -C "$sn" add -A && git -C "$sn" commit -q -m init
git -C "$sn" checkout -q -b side
echo b >"$sn/b.txt" && git -C "$sn" add -A && git -C "$sn" commit -q -m b
echo a2 >"$sn/a.txt" && echo u >"$sn/u.txt"
export SN_LOG=$tmp/sn.log SN_EXIT=$tmp/sn-exit
echo 0 >"$SN_EXIT"
sst=$sn/.git/forge-test
ssn=$sn/.claude/worktrees/_snap
sne=()
snrec() { cat "$SN_LOG" 2>/dev/null || true; }
sntree() { local ix; ix=$(mktemp -d) && cp -p "$sn/.git/index" "$ix/index" && GIT_INDEX_FILE=$ix/index git -C "$sn" add -A && GIT_INDEX_FILE=$ix/index git -C "$sn" write-tree; rm -rf "$ix"; }
snwt() { git -C "$sn" worktree list --porcelain | sed -n 's/^worktree //p' | paste -sd' '; }
snrun() { sns=0; : >"$SN_LOG"; env "${sne[@]}" "$forge" test "$@" >"$tmp/out" 2>&1 & snp=$!; wait "$snp" || sns=$?; }
snhold() { sns=0; : >"$SN_LOG"; rm -f "$1" "$1.on"; env "${sne[@]}" SN_HOLD="$1" "$forge" test "${@:2}" >"$tmp/out" 2>&1 & snp=$!; }
snon() { for _ in $(seq 100); do [ ! -e "$1.on" ] || return 0; sleep 0.1; done; touch "$1"; fail "the held run starts its suite: $(snrec) $(cat "$tmp/out")"; }
snnone() {
  [ ! -e "$sn/.claude" ] || fail "$1 creates no .claude/worktrees/_snap snapshot: $(find "$sn/.claude" -maxdepth 3)"
  [ ! -e "$sst/snap-owner" ] || fail "$1 creates no snap-owner record or .deps stamp: $(ls -A "$sst/snap-owner")"
  [ "$(snwt)" = "$sn" ] && [ ! -e "$sn/.git/worktrees" ] || fail "$1 registers no worktree beside W: $(snwt)"
}
snsaw() {
  local t p g a u e
  [ "$(cut -d'|' -f1 "$SN_LOG" | paste -sd,)" = "$2" ] || fail "$1 runs $2: $(snrec) $(cat "$tmp/out")"
  [ "$(awk -F'|' '$1 != "after" { print $4 "|" $5 }' "$SN_LOG" | paste -sd,)" = "$3" ] || fail "$1: its commands read a.txt and u.txt as $3 from the live worktree: $(snrec)"
  while IFS='|' read -r t p g a u e; do
    [ "$t" != after ] || continue
    [ "$p" = "$sn" ] || fail "$1 runs the $t command with \$PWD the worktree top $sn: $p $(snrec)"
    [ "$g" = "$sn" ] || fail "$1: git rev-parse --show-toplevel in the $t command is the worktree top $sn: $(snrec)"
    [ "$e" = unset,unset,unset,unset ] || fail "$1 runs the $t command with GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and GIT_COMMON_DIR unset: $(snrec)"
  done <"$SN_LOG"
  snnone "$1"
}
fi

if want test-in-place; then
snt=$(sntree)
snh=$(git -C "$sn" rev-parse --short "$snt")
snhold "$tmp/sn-go" "$sn"
snon "$tmp/sn-go"
echo a3 >"$sn/a.txt" && git -C "$sn" commit -q -am mid && echo a4 >"$sn/a.txt" && echo new >"$sn/new.txt"
touch "$tmp/sn-go"
wait "$snp" || sns=$?
[ "$sns" = 0 ] || fail "a run whose worktree is committed, edited and given an untracked file while its suite runs passes: $sns $(cat "$tmp/out") $(snrec)"
[ "$(tail -n1 "$tmp/out")" = "forge: tests passed ($snh)" ] || fail "a run whose worktree changes while it runs reports the start tree $snh: $(cat "$tmp/out")"
[ -f "$sst/$hid/$snt" ] || fail "a run whose worktree changes while it runs stamps the start tree $snt: $(ls -A "$sst/$hid" 2>&1)"
[ "$(sed -n 's/^after|//p' "$SN_LOG")" = "a4|new" ] || fail "a suite still running after W is edited and given new.txt reads the live worktree, a4 and new.txt: $(snrec)"
snsaw "a run whose worktree changes while it runs" setup,all,after,q "a2|u,a2|u,a4|u"
[ "$(cat "$sn/.git/forge-setup" 2>/dev/null)" = "$hid $(shash "$sn" './t.sh setup')" ] || fail "a Setup in the worktree top writes the setup stamp: $(cat "$sn/.git/forge-setup" 2>&1)"
grep -qxF "suite all out" "$sn/.git/forge-test.log" || fail "the suite run in the worktree logs to W's git dir: $(cat "$sn/.git/forge-test.log")"
[ "$(cat "$sn/a.txt")" = a4 ] && [ -f "$sn/new.txt" ] && [ "$(git -C "$sn" log -1 --format=%s)" = mid ] || fail "the run leaves W's own commit, edit and untracked file alone: $(git -C "$sn" status --porcelain)"
[ ! -e "$sst/$hid/$(sntree)" ] || fail "a run whose worktree changes while it runs stamps no tree but the start tree"
[ "$(code "$forge" test --passed "$sn")" = 1 ] && grep -qF "has uncommitted changes or untracked files" "$tmp/out" || fail "--passed still refuses the dirty worktree after the run: $(cat "$tmp/out")"
snrun --force "$sn"
[ "$sns" = 0 ] || fail "a full run passes: $(cat "$tmp/out")"
snsaw "a full run" all,q "a4|u,a4|u"
snrun "$sn"
[ "$sns" = 0 ] && grep -qF cached "$tmp/out" && [ -z "$(snrec)" ] || fail "a run of a stamped tree passes cached without running a command: $(cat "$tmp/out") $(snrec)"
snnone "a cached run"
snrun --changed --force "$sn"
[ "$sns" = 0 ] || fail "a changed run passes: $(cat "$tmp/out")"
snsaw "a changed run" changed "a4|u"
snrun --one x "$sn"
[ "$sns" = 0 ] || fail "a --one run passes: $(cat "$tmp/out")"
snsaw "a --one run" one "a4|u"
snrun --repeat 2 --one x "$sn"
[ "$sns" = 0 ] || fail "a --repeat 2 run passes: $(cat "$tmp/out")"
snsaw "a --repeat 2 run" one,one "a4|u,a4|u"
echo 3 >"$SN_EXIT"
snrun --force "$sn"
[ "$sns" = 3 ] || fail "a failing run exits 3: $sns $(cat "$tmp/out")"
snsaw "a failing run" all "a4|u"
echo 0 >"$SN_EXIT"
sne=(FORGE_TEST_MIN_SECS=1)
snhold "$tmp/sn-never" --force "$sn"
wait "$snp" || sns=$?
sne=()
[ "$sns" = 124 ] && grep -qF "forge: tests timed out" "$tmp/out" || fail "a run past its 1 s limit times out with exit 124: $sns $(cat "$tmp/out")"
snsaw "a timed-out run" all "a4|u"
snhold "$tmp/sn-go" --force "$sn"
snon "$tmp/sn-go"
kill -TERM "$snp"
wait "$snp" || sns=$?
touch "$tmp/sn-go"
[ "$sns" = 143 ] || fail "a TERMed run exits 143: $sns $(cat "$tmp/out")"
snsaw "a TERMed run" all "a4|u"
snt=$(sntree)
sngit=(GIT_DIR="$sn/.git" GIT_WORK_TREE="$sn" GIT_INDEX_FILE="$sn/.git/index" GIT_COMMON_DIR="$sn/.git")
rm -f "$sn/.git/forge-setup"
sne=("${sngit[@]}")
snrun --force "$sn"
[ "$sns" = 0 ] || fail "a run launched with W's GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and GIT_COMMON_DIR exported, as from a git hook, passes: $sns $(cat "$tmp/out")"
snsaw "a run launched with W's git env exported, as from a git hook," setup,all,q "a4|u,a4|u,a4|u"
rm -f "$sn/.git/forge-setup"
snrun --one x "$sn"
[ "$sns" = 0 ] || fail "a --one run launched with W's git env exported passes: $sns $(cat "$tmp/out")"
snsaw "a --one run launched with W's git env exported" setup,one "a4|u,a4|u"
sne=()
[ "$(cat "$sn/a.txt")" = a4 ] && [ "$(sntree)" = "$snt" ] || fail "a run launched with W's git env exported leaves W's files alone: $(git -C "$sn" status --porcelain)"
sne=(PATH="$tmp/sbin:$PATH")
: >"$K_LOG"
snrun --stack "$sn"
[ "$sns" = 0 ] || fail "a passing --stack run exits 0: $sns $(cat "$tmp/out") $(cat "$K_LOG")"
grep -qF "[--working-directory][$sn][" "$K_LOG" || fail "a --stack run passes --working-directory $sn, the worktree top, to systemd-run: $(cat "$K_LOG")"
snsaw "a passing --stack run" st "a4|u"
rm -f "$sn/.git/forge-setup"
sne=(PATH="$tmp/sbin:$PATH" "${sngit[@]}")
: >"$K_LOG"
snrun --stack "$sn"
[ "$sns" = 0 ] || fail "a --stack run launched with W's git env exported passes: $sns $(cat "$tmp/out") $(cat "$K_LOG")"
snsaw "a --stack run launched with W's git env exported" setup,st "a4|u,a4|u"
sne=(PATH="$tmp/sbin:$PATH")
echo 3 >"$SN_EXIT"
: >"$K_LOG"
snrun --stack "$sn"
[ "$sns" = 3 ] || fail "a failing --stack run exits 3: $sns $(cat "$tmp/out")"
snsaw "a failing --stack run" st "a4|u"
echo 0 >"$SN_EXIT"
sne=()
git -C "$sn" add -A && git -C "$sn" commit -q -m all
snrun --changed --force --base HEAD "$sn"
[ "$sns" = 0 ] && grep -qF "no changed files" "$tmp/out" && [ -z "$(snrec)" ] || fail "a --changed run with no changed files passes without running a command: $(cat "$tmp/out") $(snrec)"
snnone "a no-changed-files run"
snhold "$tmp/sn-go" --force "$sn"
snon "$tmp/sn-go"
sed -i 's#`./t.sh q`#`./t.sh q2`#' "$sn/.forge/TESTING.md"
touch "$tmp/sn-go"
wait "$snp" || sns=$?
[ "$sns" = 0 ] && grep -qF '`./t.sh q2`' "$sn/.forge/TESTING.md" || fail "a run whose Quarantine line is edited in W while its suite runs passes: $sns $(cat "$tmp/out")"
snsaw "a run whose Quarantine line is edited in W while its suite runs reads the live line and" all,after,q2 "a4|u,a4|u"
sed -i 's#`./t.sh q2`#`./t.sh q`#' "$sn/.forge/TESTING.md"
ok test-in-place
fi

if want test-snap-prune; then
if ! want test-in-place; then
echo a4 >"$sn/a.txt" && echo new >"$sn/new.txt" && git -C "$sn" add -A && git -C "$sn" commit -q -m all
fi
snwts() { git -C "$sn" worktree list --porcelain | sed -n 's/^worktree //p' | sort | paste -sd' '; }
snadmin() { ls -A "$sn/.git/worktrees" 2>/dev/null | paste -sd' '; }
snprune() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; s=0; snap_prune "$2" || s=$?; echo "returned $s"' _ "$root" "$1" >"$tmp/out" 2>"$tmp/err"; }
snreuse() { sns=0; : >"$SN_LOG"; env "${sne[@]}" bash -c "$1"' && exec "$0" test --force "$1"' "$forge" "$sn" "${2:-}" >"$tmp/out" 2>&1 & snp=$!; wait "$snp" || sns=$?; }
bash -c : & snd=$!
wait "$snd"
git -C "$sn" worktree add -q --detach "$ssn/$snd" HEAD && echo initializing >"$sn/.git/worktrees/$snd/locked" || fail "a locked registration of dead pid $snd is set up: $(snadmin)"
bash -c : & snu=$!
wait "$snu"
snun=forge-stack-snap-kept.service
git -C "$sn" worktree add -q --detach "$ssn/$snu" HEAD && mkdir -p "$sst/tmp/$snu" && echo "$snun" >"$sst/tmp/$snu.unit" || fail "the snapshot of dead pid $snu with a stack unit is set up: $(snadmin)"
sleep 300 & snl=$!
git -C "$sn" worktree add -q --detach "$ssn/$snl" HEAD || fail "the snapshot of live pid $snl is set up: $(snadmin)"
echo "$snun" >"$TS_ACTIVE"
sne=(PATH="$tmp/tsbin:$PATH")
snrun --force "$sn"
[ "$sns" = 0 ] || { kill "$snl"; fail "a run beside dead and live snapshots passes: $sns $(cat "$tmp/out")"; }
[ "$(cut -d'|' -f2 "$SN_LOG" | sort -u)" = "$sn" ] || { kill "$snl"; fail "a run beside left-over snapshots runs in the worktree top $sn: $(snrec)"; }
[ ! -e "$ssn/$snd" ] && [ ! -e "$sn/.git/worktrees/$snd" ] || { kill "$snl"; fail "the next run removes the snapshot $ssn/$snd of dead pid $snd and its locked registration: $(ls -A "$ssn") admin: $(snadmin)"; }
[ -d "$ssn/$snl" ] && [ -f "$ssn/$snl/a.txt" ] && [ -d "$sn/.git/worktrees/$snl" ] || { kill "$snl"; fail "the next run keeps the snapshot $ssn/$snl of live pid $snl: $(ls -A "$ssn") admin: $(snadmin)"; }
[ -d "$ssn/$snu" ] && [ -f "$ssn/$snu/a.txt" ] && [ -d "$sn/.git/worktrees/$snu" ] && [ "$(cat "$sst/tmp/$snu.unit" 2>/dev/null)" = "$snun" ] || { kill "$snl"; fail "the next run keeps the snapshot $ssn/$snu of dead pid $snu while its stack unit $snun is active: $(ls -A "$ssn" "$sst/tmp") admin: $(snadmin)"; }
[ "$(snwts)" = "$(printf '%s\n' "$sn" "$ssn/$snl" "$ssn/$snu" | sort | paste -sd' ')" ] || { kill "$snl"; fail "after pruning only W and the kept pid snapshots stay registered: $(snwts)"; }
: >"$TS_ACTIVE"
snrun --force "$sn"
[ "$sns" = 0 ] || { kill "$snl"; fail "a run once the stack unit is inactive passes: $sns $(cat "$tmp/out")"; }
[ ! -e "$ssn/$snu" ] && [ ! -e "$sn/.git/worktrees/$snu" ] && [ ! -e "$sst/tmp/$snu" ] && [ ! -e "$sst/tmp/$snu.unit" ] || { kill "$snl"; fail "once its stack unit $snun is inactive the next run removes and unregisters the snapshot $ssn/$snu of dead pid $snu: $(ls -A "$ssn" "$sst/tmp") admin: $(snadmin)"; }
[ -d "$ssn/$snl" ] || { kill "$snl"; fail "a run keeps the snapshot of live pid $snl: $(ls -A "$ssn")"; }
kill "$snl" && { wait "$snl" 2>/dev/null || true; }
git -C "$sn" worktree remove --force "$ssn/$snl"
[ "$(snwts)" = "$sn" ] && [ -z "$(ls -A "$ssn")" ] && [ -z "$(snadmin)" ] || fail "no snapshot is left before the reused-pid runs: $(snwts) $(ls -A "$ssn") admin: $(snadmin)"
echo "$snun" >"$TS_ACTIVE"
snreuse 's=$1/.claude/worktrees/_snap/$$; git -C "$1" worktree add -q --detach "$s" HEAD && echo keep >"$s/keep" && mkdir -p "$1/.git/forge-test/tmp" && echo "$2" >"$1/.git/forge-test/tmp/$$.unit"' "$snun"
[ "$sns" = 1 ] || fail "a forge test whose reused pid $snp has the snapshot of the active stack unit $snun fails: $sns $(cat "$tmp/out")"
grep -qF "$snun" "$tmp/out" && grep -qF "systemctl --user stop $snun" "$tmp/out" || fail "a forge test refusing the kept snapshot of a reused pid names unit $snun and systemctl --user stop $snun: $(cat "$tmp/out")"
[ "$(cat "$ssn/$snp/keep" 2>/dev/null)" = keep ] && [[ " $(snwts) " == *" $ssn/$snp "* ]] || fail "a forge test under a reused pid $snp keeps the registered snapshot of the active unit $snun: $(snwts) $(ls -A "$ssn/$snp" 2>&1)"
[ -z "$(snrec)" ] || fail "a forge test refusing the kept snapshot of a reused pid runs no command: $(snrec)"
git -C "$sn" worktree remove --force "$ssn/$snp" && rm -rf "$sst/tmp/$snp" "$sst/tmp/$snp.unit"
: >"$TS_ACTIVE"
bash -c : & snd=$!
wait "$snd"
git -C "$sn" worktree add -q --detach "$ssn/$snd" HEAD || fail "the snapshot of dead pid $snd is set up"
snprune "$sn/.forge"
[ "$(cat "$tmp/out")" = "returned 0" ] || fail "snap_prune given a path in the repo returns 0 after removing a dead snapshot: $(cat "$tmp/out" "$tmp/err")"
[ ! -e "$ssn/$snd" ] && [ -z "$(snadmin)" ] && [ "$(snwts)" = "$sn" ] || fail "snap_prune removes and unregisters the snapshot $ssn/$snd of dead pid $snd: $(snwts) admin: $(snadmin)"
bash -c : & snd=$!
wait "$snd"
mkdir -p "$ssn/$snd/ro" && : >"$ssn/$snd/ro/f" && chmod 555 "$ssn/$snd/ro"
snprune "$sn"
chmod 755 "$ssn/$snd/ro" 2>/dev/null || :
[ "$(cat "$tmp/out")" = "returned 1" ] && grep -qF "forge: cannot remove $ssn/$snd" "$tmp/err" || fail "snap_prune that cannot remove $ssn/$snd prints forge: cannot remove <path> and returns 1 without exiting: $(cat "$tmp/out" "$tmp/err")"
[ -e "$ssn/$snd" ] || mkdir -p "$ssn/$snd/ro"
: >"$ssn/$snd/ro/f" && chmod 555 "$ssn/$snd/ro"
snrun --force "$sn"
chmod 755 "$ssn/$snd/ro" 2>/dev/null || :
[ "$sns" = 1 ] && grep -qF "forge: cannot remove $ssn/$snd" "$tmp/out" || fail "a forge test whose dead snapshot $ssn/$snd cannot be removed fails naming it: $sns $(cat "$tmp/out")"
[ -z "$(snrec)" ] || fail "a forge test that cannot remove a dead snapshot runs no command: $(snrec)"
rm -rf "$ssn/$snd"
bash -c : & snd=$!
wait "$snd"
git -C "$sn" worktree add -q --detach "$sst/snap/$snd" HEAD || fail "the legacy snapshot $sst/snap/$snd of dead pid $snd is set up"
snrun --force "$sn"
[ "$sns" = 0 ] || fail "a run beside a legacy snapshot of a dead pid passes: $sns $(cat "$tmp/out")"
[ ! -e "$sst/snap/$snd" ] && [ ! -e "$sn/.git/worktrees/$snd" ] && [ "$(snwts)" = "$sn" ] || fail "the next run removes and unregisters the legacy snapshot $sst/snap/$snd of dead pid $snd: $(snwts) admin: $(snadmin)"
sne=()
ok test-snap-prune
fi

finish
