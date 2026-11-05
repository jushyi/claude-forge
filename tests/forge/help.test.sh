#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

if want help; then
"$forge" --help >"$tmp/help"
for c in status ready implement resume map validate alloc paths commit archive resolve check done next clean repos event review push pr merge-check merge land golive gc test fixes ui discuss concern launch perf owed plan-done task-done finish replay shadow cutover; do
  grep -qE "^  $c( |$)" "$tmp/help" || fail "forge --help lists $c"
  [ "$("$forge" "$c" --help | head -1 | cut -d' ' -f1-3)" = "Usage: forge $c" ] || fail "forge $c --help prints its usage"
done
"$forge" discuss --help >"$tmp/discuss-help"
for s in '^Usage: forge discuss <track>/<feature>$' 'forge discuss --auto <track>/<feature>\.\.\.$' requirements.json unshipped /forge-discuss FORGE_ROOT 'claude agents --json' '^Reads:' '^Writes:' '^Example:' '^  forge discuss [a-z]'; do
  grep -q -- "$s" "$tmp/discuss-help" || fail "forge discuss --help names $s"
done
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/discuss-help" >"$tmp/discuss-flat"
for s in '/forge-discuss --auto <track>/<feature>' 'waits for' 'exits 0' FORGE_MAX_SESSIONS; do
  grep -q -- "$s" "$tmp/discuss-flat" || fail "forge discuss --help names $s"
done
! grep -qi 'never count' "$tmp/discuss-flat" || fail "forge discuss --help no longer says discuss sessions never count toward FORGE_MAX_SESSIONS"
awk '/^  discuss( |$)/ { p = 1; print; next } p && /^   +/ { print; next } { p = 0 }' "$tmp/help" | grep -q -- --auto || fail "forge --help's discuss line names --auto"
"$forge" launch --help >"$tmp/launch-help"
for s in '^Usage: forge launch \[--auto\] <track>$' --auto '^Reads:' '^Writes:' '^Example:'; do
  grep -q -- "$s" "$tmp/launch-help" || fail "forge launch --help names $s"
done
"$forge" perf --help >"$tmp/perf-help"
[ "$(head -1 "$tmp/perf-help")" = "Usage: forge perf pull" ] || fail "forge perf --help prints its usage line: $(head -1 "$tmp/perf-help")"
for s in '- Perf log:' FORGE_PERF_WINDOW '\.forge/perf\.json' '\.forge/TESTING\.md' '\.forge/seeds\.md' 'forge\.lock' 'docs(perf): pull <date>' '"prev"' '^Reads:' '^Writes:' '^Environment:' '^Example:' '^  forge perf pull$'; do
  grep -q -- "$s" "$tmp/perf-help" || fail "forge perf --help names $s"
done
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/perf-help" >"$tmp/perf-flat"
for s in 'exits 2' 'default 7' p50 p95 '20%' stderr 'perf metric `<name>`: p95 <prev> -> <now> <unit> over <window>'; do
  grep -qiF -- "$s" "$tmp/perf-flat" || fail "forge perf --help names $s"
done
for s in 'Perf tests' 'Perf baseline' FORGE_PERF_REPEATS 'forge perf check' 'perf record' 'perf ab' 'perf stop' --out --base median 'over by' ratio; do
  ! grep -qiF -- "$s" "$tmp/perf-flat" || fail "forge perf --help no longer names $s"
done
awk '/^  perf( |$)/ { p = 1; print; next } p && /^   +/ { print; next } { p = 0 }' "$tmp/help" | grep -q -- 'perf pull' || fail "forge --help's perf line names perf pull"
"$forge" test --help >"$tmp/test-help"
! grep -n -- --perf "$tmp/test-help" >"$tmp/test-perf" || fail "forge test --help names no --perf: $(head -3 "$tmp/test-perf" | tr '\n' ' ')"
awk '/^  - Perf log:/ { p = 1; print; next } p && /^    +/ { print; next } { p = 0 }' "$tmp/test-help" | tr -s ' \n' ' ' >"$tmp/test-perf-line"
grep -q 'forge perf' "$tmp/test-perf-line" || fail "forge test --help's Perf log line names forge perf: $(cat "$tmp/test-perf-line")"
grep -q 'usage-log' "$tmp/test-perf-line" || fail "forge test --help's Perf log line names the usage-log metrics: $(cat "$tmp/test-perf-line")"
"$forge" owed --help >"$tmp/owed-help"
[ "$(head -1 "$tmp/owed-help")" = "Usage: forge owed <track>/<feature>" ] || fail "forge owed --help prints its usage line: $(head -1 "$tmp/owed-help")"
for s in 'verify\.json' 'requirements\.json' '\.forge/todo\.md' '^Reads:' '^Writes:' '^Exit codes:' '^Example:' '^  forge owed [a-z0-9-]+/[a-z0-9-]+$'; do
  grep -qE -- "$s" "$tmp/owed-help" || fail "forge owed --help names $s"
done
awk '/^Writes:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/owed-help" | tr -s ' \n' ' ' >"$tmp/owed-writes"
for s in 'requirements\.json' '\.forge/todo\.md'; do
  grep -qE -- "$s" "$tmp/owed-writes" || fail "forge owed --help's Writes names $s: $(cat "$tmp/owed-writes")"
done
[ "$(code "$forge")" = 2 ] || fail "no arguments must exit 2"
[ "$(code "$forge" bogus)" = 2 ] || fail "unknown command must exit 2"
grep -q "^Operator commands:" "$tmp/out" || fail "unknown command must print the command list"
! grep -qE "^  render( |$)" "$tmp/help" || fail "forge --help no longer lists render"
[ ! -e "$root/bin/forge.d/help/render.txt" ] || fail "bin/forge.d/help/render.txt is gone"
[ "$(code "$forge" render)" = 2 ] && grep -qF "forge: unknown command 'render'" "$tmp/out" || fail "forge render is an unknown command: $(cat "$tmp/out")"
[ "$(code "$forge" render --help)" = 2 ] && grep -qF "forge: unknown command 'render'" "$tmp/out" || fail "forge render --help is an unknown command: $(cat "$tmp/out")"
! grep -qE "^  heavy( |$)" "$tmp/help" || fail "forge --help no longer lists heavy"
[ ! -e "$root/bin/forge.d/heavy.sh" ] || fail "bin/forge.d/heavy.sh is gone"
[ ! -e "$root/bin/forge.d/help/heavy.txt" ] || fail "bin/forge.d/help/heavy.txt is gone"
[ "$(code "$forge" heavy)" = 2 ] && grep -qF "forge: unknown command 'heavy'" "$tmp/out" || fail "forge heavy is an unknown command: $(cat "$tmp/out")"
[ "$(code "$forge" heavy --help)" = 2 ] && grep -qF "forge: unknown command 'heavy'" "$tmp/out" || fail "forge heavy --help is an unknown command: $(cat "$tmp/out")"
! grep -nF 'forge heavy' "$tmp/test-help" >"$tmp/test-heavy" || fail "forge test --help names no forge heavy: $(head -3 "$tmp/test-heavy" | tr '\n' ' ')"
for x in render.jq track.md FEATURE.md PHASE.md STATE.md procedure.md build.md; do
  [ ! -e "$root/templates/$x" ] || fail "templates/$x is gone"
done
for x in CONCERNS.md ARCHITECTURE.md STACK.md CONVENTIONS.md TESTING.md INTEGRATIONS.md CLAUDE.md; do
  [ -f "$root/templates/$x" ] || fail "templates/$x stays"
done
ok help
fi

if want test-snapshot; then
"$forge" test --help >"$tmp/test-help"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/test-help" >"$tmp/test-flat"
for s in forge-test.lock FORGE_TEST_WT_HELD 'forge: waiting for the test run in <worktree> (pid '; do
  grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help names $s"
done
awk '/^Environment:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/test-help" >"$tmp/test-env"
grep -qE '^  FORGE_TEST_WT_HELD( |$)' "$tmp/test-env" || fail "forge test --help's Environment lists FORGE_TEST_WT_HELD"
for s in 'runs in the worktree top, reading the live worktree' 'the pass is stamped for the start tree' 'GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and GIT_COMMON_DIR unset' 'in <git common dir>/forge-test/base itself' 'Setup runs only in the worktree top' 'tracked and untracked, not ignored' 'the sha256 of its bytes'; do
  grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help names $s"
done
for s in 'Snapshot files' '_snap' 'snap-owner' 'never reaches the run' 'no .git component' 'run snapshot' 'reflink' 'deps stamp' 'build cold in each snapshot' 'forge land removes the setup stamp'; do
  ! grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help no longer names $s"
done
ok test-snapshot
fi

if want test-cpu; then
"$forge" test --help >"$tmp/test-help"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/test-help" >"$tmp/test-flat"
for s in '${FORGE_PROC_ROOT:-/proc}/pressure/cpu' 'some avg10' 'cpu=' 'nproc' '- CPUs one:' '- CPUs all:' 'MemoryMax' 'MemoryHigh' 'MemorySwapMax' FORGE_TEST_CPUS CARGO_BUILD_JOBS FORGE_PROC_ROOT; do
  grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help names $s"
done
grep -F 'runs.log' -A3 "$tmp/test-help" | grep -qE '^  <date> <time> .* peak=<KiB> cpu=' || fail "forge test --help's runs.log line ends in a twelfth cpu= field"
for s in 'waiting for test CPUs' 'nproc - held' 'max(2, min(want' 'the CPU rule' 'test_room and slot_grant' '<n> CPUs, <m> min' FORGE_TEST_CPU_PRESSURE 'waiting for CPU pressure' 'cannot read CPU pressure' CPUWeight 'held by <worktree> (<size>, <m> min)'; do
  ! grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help no longer names $s"
done
ok test-cpu
fi

if want test-runs; then
"$forge" test --help >"$tmp/test-help"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/test-help" >"$tmp/test-flat"
for s in 'forge: waiting for a test run slot (<n> in use: <holders>)' '${XDG_RUNTIME_DIR:-$HOME/.local/state}/forge/test-runs/' FORGE_TEST_RUNS FORGE_TEST_SLOT_HELD 'arrival' 'timeout -k 10s <n>m' 'forge: tests timed out after <n> min (limit from <source>), log <log>' '- Timeout: in <path' 'the 60 min default' 'forge: waiting for the test run in <worktree> (pid '; do
  grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help names $s"
done
awk '/^Environment:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/test-help" >"$tmp/test-env"
grep -qE '^  FORGE_TEST_RUNS( |$)' "$tmp/test-env" || fail "forge test --help's Environment lists FORGE_TEST_RUNS"
awk '/^  FORGE_TEST_RUNS / { p = 1; print; next } p && /^  [A-Z]/ { p = 0 } p' "$tmp/test-env" | tr -s ' \n' '  ' >"$tmp/test-env-runs"
grep -qE 'default 2\b' "$tmp/test-env-runs" || fail "forge test --help's FORGE_TEST_RUNS entry names its default 2: $(cat "$tmp/test-env-runs")"
awk -v RS= '{ gsub(/[ \n]+/, " ") } /waiting for a test run slot/' "$tmp/test-help" >"$tmp/test-sem"
grep -qF -- '--stack' "$tmp/test-sem" || fail "forge test --help's run slot paragraph says --stack takes no slot: $(cat "$tmp/test-sem")"
grep -qiE 'never gives up|no give-up' "$tmp/test-sem" || fail "forge test --help's run slot paragraph says the wait never gives up: $(cat "$tmp/test-sem")"
sed -n '/^Exit codes:/,/^Reads:/p' "$tmp/test-help" >"$tmp/test-exits"
sed -n '/^  75 /,/^  124 /p' "$tmp/test-exits" | sed '$d' | tr -s ' \n' '  ' >"$tmp/test-75"
grep -qF 'memory kill' "$tmp/test-75" && grep -qF 'worktree lock' "$tmp/test-75" || fail "forge test --help's exit 75 names a repeated memory kill and the worktree-lock give-up: $(cat "$tmp/test-75")"
! grep -qwiE 'slot|admission|pressure' "$tmp/test-75" || fail "forge test --help's exit 75 names no slot, admission or pressure wait: $(cat "$tmp/test-75")"
grep -qE '^  124 ' "$tmp/test-exits" || fail "forge test --help lists exit 124 for a timeout"
for s in FORGE_TEST_SLOTS FORGE_TEST_CPU_PRESSURE test-slots/ test-admit 'gave up waiting' RuntimeMaxSec '3x' '3 times the longest' 'waiting for test memory' 'waiting for a test slot (' 'never uses coreutils timeout'; do
  ! grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help no longer names $s"
done
ok test-runs
fi

if want cpu-defaults; then
"$forge" test --help >"$tmp/test-help"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/test-help" >"$tmp/test-flat"
all='max(2, floor(nproc / 4))'
grep -qF -- "$all" "$tmp/test-flat" || fail "forge test --help names the all-tier default $all"
for s in 'from nproc' 'lowers the job count' 'The job count is nproc' 'job count (nproc,' 'count, nproc, lowered'; do
  ! grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help no longer names $s"
done
awk -v RS= '{ gsub(/[ \n]+/, " ") } /On 24 CPUs/' "$tmp/test-help" >"$tmp/test-24"
grep -q 'no CPUs all line gets 6\b' "$tmp/test-24" || fail "forge test --help's 24-CPU example gives a full run with no CPUs all line 6: $(cat "$tmp/test-24")"
grep -q 'no CPUs one line gets 2\b' "$tmp/test-24" || fail "forge test --help's 24-CPU example gives a --one run with no CPUs one line 2: $(cat "$tmp/test-24")"
grep -qE -- 'CPUs all: .12.. gives (it )?12\b' "$tmp/test-24" || fail "forge test --help's 24-CPU example gives - CPUs all: 12 12"
grep -qE -- 'CPUs all: .32.. gives (it )?24\b' "$tmp/test-24" || fail "forge test --help's 24-CPU example caps - CPUs all: 32 at 24"
grep -qF -- "$all" "$tmp/test-24" || fail "forge test --help's job count section names the all-tier default $all"
awk -v RS= '{ gsub(/[ \n]+/, " ") } /[Rr]aise/ && /- Memory:/' "$tmp/test-help" | grep -q 'CPUs' || fail "forge test --help says a repo raises the job count with a CPUs line within its - Memory: budget"
awk '/^Environment:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/test-help" | awk '/^  FORGE_TEST_CPUS / { p = 1; print; next } p && /^  [A-Z]/ { p = 0 } p' | tr -s ' \n' '  ' >"$tmp/test-env-cpus"
grep -qF -- "$all" "$tmp/test-env-cpus" || fail "forge test --help's FORGE_TEST_CPUS entry names the all-tier default $all: $(cat "$tmp/test-env-cpus")"
sed "s|max(2, floor(nproc / 4))||g" "$tmp/test-env-cpus" | grep -qw 2 || fail "forge test --help's FORGE_TEST_CPUS entry names the one-tier default 2: $(cat "$tmp/test-env-cpus")"
ok cpu-defaults
fi

if want step-usage; then
fresh
cd "$tmp"
while IFS= read -r a; do
  s=0
  eval "FORGE_ROOT=\$tmp/p \"\$forge\" $a" </dev/null >"$tmp/o" 2>"$tmp/e" || s=$?
  [ "$s" = 2 ] || fail "forge $a exits 2 through usage: $s $(cat "$tmp/o" "$tmp/e")"
  [ ! -s "$tmp/o" ] || fail "forge $a prints nothing on stdout: $(cat "$tmp/o")"
  grep -q '^Usage: forge <command>' "$tmp/e" || fail "forge $a prints the usage on stderr: $(cat "$tmp/e")"
  ! grep -q 'unknown command' "$tmp/e" || fail "forge $a is a known command: $(cat "$tmp/e")"
done <<'ARGS'
plan-done
plan-done 05 x
task-done 05
task-done 05 X1
finish
finish 05 --accept only-one
finish 05 --bogus a b
done 05 --accept c w
finish 05 --accept c w
ARGS
ok step-usage
fi

if want removed-commands; then
fresh
for c in verify-tests verify-start verify-finish contracts owner deferred escalation settle; do
  [ "$(code env FORGE_ROOT="$tmp/p" "$forge" "$c" 05 </dev/null)" = 2 ] && grep -qxF "forge: unknown command '$c'" "$tmp/out" || fail "forge $c 05 is an unknown command: $(cat "$tmp/out")"
done
ok removed-commands
fi

if want pruned-commands; then
"$forge" --help >"$tmp/help"
for c in jev migrate perf-runner build build-gate hotfix release inhibit power rename reflow budget intake trust exclude contracts; do
  ! grep -qE "^  $c( |$)" "$tmp/help" || fail "forge --help no longer lists $c"
  [ ! -e "$root/bin/forge.d/help/$c.txt" ] || fail "bin/forge.d/help/$c.txt is gone"
  for a in "" --help; do
    [ "$(code "$forge" "$c" $a)" = 2 ] && grep -qxF "forge: unknown command '$c'" "$tmp/out" || fail "forge $c $a is an unknown command that exits 2: $(cat "$tmp/out")"
  done
done
awk '/^  perf( |$)/ { p = 1; print; next } p && /^   +/ { print; next } { p = 0 }' "$tmp/help" >"$tmp/perf-entry"
[ "$(grep -c '^  perf' "$tmp/perf-entry")" = 1 ] && grep -qE '^  perf pull( |$)' "$tmp/perf-entry" || fail "forge --help's perf entry is perf pull alone: $(cat "$tmp/perf-entry")"
for s in 'perf check' 'perf record' 'perf ab'; do
  ! grep -qF -- "$s" "$tmp/help" || fail "forge --help no longer names $s"
done
ok pruned-commands
fi

if want ship-queue-gone; then
"$forge" --help >"$tmp/help"
! grep -qE "^  ship-queue( |$)" "$tmp/help" || fail "forge --help no longer lists ship-queue"
[ ! -e "$root/bin/forge.d/help/ship-queue.txt" ] || fail "bin/forge.d/help/ship-queue.txt is gone"
for a in "" --help; do
  [ "$(code "$forge" ship-queue $a)" = 2 ] && grep -qxF "forge: unknown command 'ship-queue'" "$tmp/out" && grep -q "^Operator commands:" "$tmp/out" || fail "forge ship-queue $a is an unknown command that exits 2 with the command list: $(cat "$tmp/out")"
done
ok ship-queue-gone
fi

if want paths-help; then
"$forge" paths --help >"$tmp/paths-help"
grep -qE '^  STATE +' "$tmp/paths-help" || fail "forge paths --help lists the STATE key: $(cat "$tmp/paths-help")"
grep -E '^  (F|P) +' "$tmp/paths-help" >"$tmp/paths-fp"
[ "$(grep -c STATE/ "$tmp/paths-fp")" = 2 ] || fail "forge paths --help puts F and P under STATE: $(cat "$tmp/paths-fp")"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/paths-help" >"$tmp/paths-flat"
! grep -qF 'Planning JSON always goes under R/.forge' "$tmp/paths-flat" || fail "forge paths --help drops 'Planning JSON always goes under R/.forge'"
grep -qiF 'no argument' "$tmp/paths-flat" || fail "forge paths --help says what forge paths with no argument prints"
grep -qF R/.forge "$tmp/paths-flat" && grep -qF W/.forge "$tmp/paths-flat" || fail "forge paths --help says records go under STATE, never under R/.forge or W/.forge"
sed -n '/^Reads:/,/^$/p' "$tmp/paths-help" >"$tmp/paths-reads"
! grep -qE '\.forge/(phases|features)/' "$tmp/paths-reads" || fail "forge paths --help's Reads section names S records, not .forge/phases or .forge/features: $(cat "$tmp/paths-reads")"
ok paths-help
fi

if want test-rerun; then
"$forge" test --help >"$tmp/test-help"
awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/test-help" >"$tmp/test-flat"
for s in 'forge: rerun: load <l> >= nproc <n>' '${FORGE_PROC_ROOT:-/proc}/loadavg' 'reruns once' 'a rerun never reruns' '--one and --repeat never rerun'; do
  grep -qF -- "$s" "$tmp/test-flat" || fail "forge test --help names $s"
done
awk '/^Reads:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/test-help" | grep -qxF '  ${FORGE_PROC_ROOT:-/proc}/loadavg' || fail "forge test --help's Reads lists \${FORGE_PROC_ROOT:-/proc}/loadavg"
awk '/^Environment:/ { p = 1; next } /^[A-Z]/ { p = 0 } p' "$tmp/test-help" | awk '/^  FORGE_PROC_ROOT / { p = 1; print; next } p && /^  [A-Z]/ { p = 0 } p' | grep -q loadavg || fail "forge test --help's FORGE_PROC_ROOT entry names loadavg"
for c in test land; do
  "$forge" "$c" --help >"$tmp/$c-help"
  awk -v RS= '{ gsub(/[ \n]+/, " ") } 1' "$tmp/$c-help" >"$tmp/$c-flat"
  for s in FORGE_TEST_RERUN 'fix it or rerun with --force'; do
    ! grep -qF -- "$s" "$tmp/$c-flat" || fail "forge $c --help no longer names $s"
  done
done
ok test-rerun
fi

finish
