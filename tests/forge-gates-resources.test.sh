#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"
suite=forge-gates-resources
. "$(dirname "$0")/forge-gates-common.sh"

if want_any test-cpus test-cpus-all; then
cr=$tmp/cpus
gitinit "$cr"
mkdir -p "$cr/.forge" "$tmp/cpubin"
cat >"$cr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1 ${FORGE_TEST_CPUS-unset}" >>"$C_LOG"
echo "$1 ${CARGO_BUILD_JOBS-unset}" >>"$C_LOG.jobs"
EOF
chmod +x "$cr/t.sh"
export C_LOG=$tmp/cpus.log
cdoc() { { printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n'; printf '%s\n' "$@"; } >"$cr/.forge/TESTING.md"; git -C "$cr" add -A && git -C "$cr" commit -q --allow-empty -m "cpus doc"; }
cpus() { local s=0; : >"$C_LOG"; PATH=$tmp/cpubin:$PATH "$@" >"$tmp/out" 2>&1 || s=$?; echo $s; }
got() { paste -sd, "$C_LOG"; }
lines=('- Test: `./t.sh one {test}`' '- Changed tests: `./t.sh changed {files}`' '- Quarantine: `./t.sh q`' '- Perf log: `./t.sh perf`')
echo a >"$cr/a.txt"
cdoc "${lines[@]}"
git -C "$cr" checkout -q -b side
echo b >"$cr/b.txt" && git -C "$cr" add -A && git -C "$cr" commit -q -m change
fi

if want test-cpus; then
cd "$x"
mkdir -p "$tmp/small" "$tmp/tiny"
printf 'MemTotal: 6291456 kB\nMemAvailable: 16777216 kB\n' >"$tmp/small/meminfo"
printf 'MemTotal: 3145728 kB\nMemAvailable: 16777216 kB\n' >"$tmp/tiny/meminfo"
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "a full run and its quarantine get FORGE_TEST_CPUS=6, max(2, floor(nproc / 4)) on nproc 24 with no - CPUs all: line: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --changed --force "$cr")" = 0 ] && [ "$(got)" = "changed 6" ] || fail "a changed run gets the all-tier FORGE_TEST_CPUS=6 on nproc 24 and runs no quarantine: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a --one run on nproc 24 gets the one-tier default FORGE_TEST_CPUS=2 with no - CPUs one: line: $(got) $(cat "$tmp/out")"
[ "$(NPROC=48 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 12,q 12" ] || fail "nproc 48 gives a full run FORGE_TEST_CPUS=12, max(2, floor(48 / 4)): $(got) $(cat "$tmp/out")"
[ "$(NPROC=4 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 2,q 2" ] || fail "nproc 4 gives a full run FORGE_TEST_CPUS=2, max(2, floor(4 / 4)): $(got) $(cat "$tmp/out")"
[ "$(NPROC=3 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 2,q 2" ] || fail "nproc 3 gives a full run FORGE_TEST_CPUS=2, the all-tier floor of 2: $(got) $(cat "$tmp/out")"
[ "$(NPROC=2 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "nproc 2 gives --one FORGE_TEST_CPUS=2, the one-tier default: $(got) $(cat "$tmp/out")"
[ "$(FORGE_TEST_CPUS=99 NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "a preset FORGE_TEST_CPUS=99 is overwritten with the all-tier 6 on nproc 24: $(got) $(cat "$tmp/out")"
[ "$(FORGE_TEST_CPUS=99 NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a preset FORGE_TEST_CPUS=99 is overwritten with the one-tier 2 for --one: $(got) $(cat "$tmp/out")"
[ "$(FORGE_PROC_ROOT=$tmp/small NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "a 6 GiB MemTotal does not size the CPUs, so nproc 24 gives FORGE_TEST_CPUS=6: $(got) $(cat "$tmp/out")"
[ "$(FORGE_PROC_ROOT=$tmp/tiny NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a 3 GiB MemTotal does not size the CPUs, so --one gets FORGE_TEST_CPUS=2: $(got) $(cat "$tmp/out")"
mkdir -p "$tmp/bigmem"
printf 'MemTotal: 100663296 kB\nMemAvailable: 90177536 kB\n' >"$tmp/bigmem/meminfo"
[ "$(FORGE_PROC_ROOT=$tmp/bigmem NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "a 96 GiB MemTotal does not size the CPUs, so nproc 24 gives FORGE_TEST_CPUS=6: $(got) $(cat "$tmp/out")"
[ "$(NPROC=1 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 1" ] || fail "nproc 1 gives --one FORGE_TEST_CPUS=1, the default 2 capped at nproc: $(got) $(cat "$tmp/out")"
[ "$(NPROC=1 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 1,q 1" ] || fail "nproc 1 gives a full run FORGE_TEST_CPUS=1, the all-tier floor of 2 capped at nproc: $(got) $(cat "$tmp/out")"
: >"$C_LOG.jobs"
[ "$(CARGO_BUILD_JOBS=99 NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(paste -sd, "$C_LOG.jobs")" = "all 6,q 6" ] || fail "a full run exports CARGO_BUILD_JOBS equal to FORGE_TEST_CPUS, 6 on nproc 24, overwriting a preset 99: $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
: >"$C_LOG.jobs"
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(paste -sd, "$C_LOG.jobs")" = "one 2" ] || fail "a --one run exports CARGO_BUILD_JOBS=2 on nproc 24: $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
cdoc "${lines[@]}" '- Memory: `12G`'
mkdir -p "$tmp/mem93"
printf 'MemTotal: 97517568 kB\nMemAvailable: 90177536 kB\n' >"$tmp/mem93/meminfo"
[ "$(FORGE_PROC_ROOT=$tmp/mem93 NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "nproc 24 with a 12G Memory line in a 93 GiB MemTotal gives FORGE_TEST_CPUS=6, the budget not dividing the CPUs: $(got) $(cat "$tmp/out")"
[ "$(FORGE_PROC_ROOT=$tmp/mem93 NPROC=48 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "--one with a 12G Memory line and nproc 48 gets the one-tier FORGE_TEST_CPUS=2: $(got) $(cat "$tmp/out")"
cdoc "${lines[@]}" '- Memory: `12950M`'
[ "$(FORGE_PROC_ROOT=$tmp/mem93 NPROC=96 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a 12950M budget does not divide the CPUs, so nproc 96 gives --one FORGE_TEST_CPUS=2: $(got) $(cat "$tmp/out")"
cdoc
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "all 2" ] || fail "the --one fallback to the full command is sized on the one tier, FORGE_TEST_CPUS=2 on nproc 24: $(got) $(cat "$tmp/out")"
printf '#!/usr/bin/env bash\necho "setup ${FORGE_TEST_CPUS-unset}" >>"$C_LOG"\necho "setup ${CARGO_BUILD_JOBS-unset}" >>"$C_LOG.jobs"\n' >"$cr/setup.sh"
chmod +x "$cr/setup.sh"
cdoc "${lines[@]}" '- Setup: `./setup.sh`'
setups() { grep '^setup ' "$C_LOG" | sort -u | paste -sd,; }
stests() { grep -v '^setup ' "$C_LOG" | paste -sd,; }
rm -f "$cr/.git/forge-setup"
: >"$C_LOG.jobs"
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(setups)" = "setup 6" ] && [ "$(stests)" = "all 6,q 6" ] && [ "$(grep '^setup ' "$C_LOG.jobs" | sort -u)" = "setup 6" ] || fail "a full run's Setup sees the run's FORGE_TEST_CPUS=6 and CARGO_BUILD_JOBS=6: $(got) $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
rm -f "$cr/.git/forge-setup"
: >"$C_LOG.jobs"
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(setups)" = "setup 2" ] && [ "$(stests)" = "one 2" ] && [ "$(grep '^setup ' "$C_LOG.jobs" | sort -u)" = "setup 2" ] || fail "a --one run's Setup sees the run's FORGE_TEST_CPUS=2 and CARGO_BUILD_JOBS=2: $(got) $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
rm -f "$cr/.git/forge-setup"
[ "$(FORGE_TEST_CPUS=99 NPROC=6 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(setups)" = "setup 2" ] && [ "$(stests)" = "one 2" ] || fail "a --one run's Setup sees its FORGE_TEST_CPUS=2 on nproc 6, not a preset 99: $(got) $(cat "$tmp/out")"
cdoc "${lines[@]}" '- CPUs one: `8`'
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 8" ] || fail "a - CPUs one: 8 line gives a --one run on nproc 24 FORGE_TEST_CPUS=8, raised above the default 2: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --repeat 2 --one a "$cr")" = 0 ] && [ "$(got)" = "one 8,one 8" ] || fail "a - CPUs one: 8 line gives each --repeat iteration FORGE_TEST_CPUS=8: $(got) $(cat "$tmp/out")"
[ "$(NPROC=4 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 4" ] || fail "a - CPUs one: 8 line on nproc 4 gives --one min(nproc, 8), FORGE_TEST_CPUS=4: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 6,q 6" ] || fail "a - CPUs one: 8 line leaves a full run at the all-tier 6 on nproc 24: $(got) $(cat "$tmp/out")"
for v in 1 x; do
  cdoc "${lines[@]}" "- CPUs one: \`$v\`"
  cm="forge: $(git -C "$cr" rev-parse --show-toplevel)/.forge/TESTING.md: - CPUs one: \`$v\`: not a whole number of CPUs of at least 2"
  [ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 1 ] && grep -qxF "$cm" "$tmp/out" && [ -z "$(got)" ] || fail "a - CPUs one: line of '$v' fails --one with exit 1 and $cm, running nothing: $(got) $(cat "$tmp/out")"
done
cdoc "${lines[@]}"
ok test-cpus
fi

if want test-cpus-all; then
cd "$x"
cat >"$cr/t.sh" <<'EOS'
#!/usr/bin/env bash
echo "$1 ${FORGE_TEST_CPUS-unset}" >>"$C_LOG"
echo "$1 ${CARGO_BUILD_JOBS-unset}" >>"$C_LOG.jobs"
EOS
git -C "$cr" commit -q --allow-empty -am "cpus all"
cdoc "${lines[@]}" '- CPUs all: `2`'
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 2,q 2" ] || fail "a - CPUs all: 2 line gives a full run and its quarantine on nproc 24 FORGE_TEST_CPUS=2, lowered from the default 6: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --changed --force "$cr")" = 0 ] && [ "$(got)" = "changed 2" ] || fail "a - CPUs all: 2 line gives a changed run on nproc 24 FORGE_TEST_CPUS=2: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a - CPUs all: 2 line leaves a --one run at the one-tier default 2: $(got) $(cat "$tmp/out")"
cdoc "${lines[@]}" '- CPUs all: `12`'
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 12,q 12" ] || fail "a - CPUs all: 12 line gives a full run on nproc 24 FORGE_TEST_CPUS=12, raised above the default 6: $(got) $(cat "$tmp/out")"
[ "$(NPROC=8 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 8,q 8" ] || fail "a - CPUs all: 12 line on nproc 8 gives a full run min(nproc, 12), FORGE_TEST_CPUS=8: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --one a "$cr")" = 0 ] && [ "$(got)" = "one 2" ] || fail "a - CPUs all: 12 line leaves a --one run at the one-tier default 2: $(got) $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --changed --force "$cr")" = 0 ] && [ "$(got)" = "changed 12" ] || fail "a - CPUs all: 12 line gives a changed run on nproc 24 FORGE_TEST_CPUS=12: $(got) $(cat "$tmp/out")"
cdoc "${lines[@]}" '- CPUs all: `3`'
: >"$C_LOG.jobs"
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 3,q 3" ] && [ "$(paste -sd, "$C_LOG.jobs")" = "all 3,q 3" ] || fail "a - CPUs all: 3 line lowers a full run on nproc 24 from the default 6 to FORGE_TEST_CPUS=3 and CARGO_BUILD_JOBS=3: $(got) $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
cdoc "${lines[@]}" '- CPUs all: `32`'
: >"$C_LOG.jobs"
[ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 24,q 24" ] && [ "$(paste -sd, "$C_LOG.jobs")" = "all 24,q 24" ] || fail "a - CPUs all: 32 line on nproc 24 is capped at nproc, FORGE_TEST_CPUS=24 and CARGO_BUILD_JOBS=24: $(got) $(paste -sd, "$C_LOG.jobs") $(cat "$tmp/out")"
[ "$(NPROC=24 cpus "$forge" test --changed --force "$cr")" = 0 ] && [ "$(got)" = "changed 24" ] || fail "a - CPUs all: 32 line caps a changed run on nproc 24 at FORGE_TEST_CPUS=24: $(got) $(cat "$tmp/out")"
[ "$(NPROC=4 cpus "$forge" test --force "$cr")" = 0 ] && [ "$(got)" = "all 4,q 4" ] || fail "a - CPUs all: 32 line on nproc 4 gives a full run min(nproc, 32), FORGE_TEST_CPUS=4: $(got) $(cat "$tmp/out")"
for v in 1 x; do
  cdoc "${lines[@]}" "- CPUs all: \`$v\`"
  cm="forge: $(git -C "$cr" rev-parse --show-toplevel)/.forge/TESTING.md: - CPUs all: \`$v\`: not a whole number of CPUs of at least 2"
  [ "$(NPROC=24 cpus "$forge" test --force "$cr")" = 1 ] && grep -qxF "$cm" "$tmp/out" && [ -z "$(got)" ] || fail "a - CPUs all: line of '$v' fails a full run with exit 1 and $cm, running nothing: $(got) $(cat "$tmp/out")"
done
cdoc "${lines[@]}"
ok test-cpus-all
fi

if want test-memory; then
xlog=$x/.git/forge-test.log
cd "$x"
echo 0 >"$T_EXIT"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a capped run passes: $(cat "$tmp/out") $(ran)"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0 -- true" ] || fail "a capped run without a Memory line first probes a 4G scope with a 90% MemoryHigh and no swap: $(cat "$SD_LOG")"
[ "$(scopes | wc -l)" = 2 ] && [[ $(scopes | sed -n 2p) =~ ^--user\ --scope\ --quiet\ --unit=forge-test-[0-9]+-[0-9]+\ --expand-environment=no\ -p\ MemoryMax=4G\ -p\ MemoryHigh=3774873K\ -p\ MemorySwapMax=0\ --\ . ]] || fail "the suite runs in a named scope at the default 4G budget with a 90% MemoryHigh and no swap: $(cat "$SD_LOG")"
[ "$(units | wc -l)" = 1 ] && reset || fail "the scope unit is reset afterwards: $(cat "$SC_LOG")"
grep -qxF "ran all" "$xlog" || fail "a capped run logs to the git dir: $(cat "$xlog")"
[ "$(lastline)" = "forge: tests passed ($(xshort))" ] || fail "a capped pass line: $(lastline)"
! grep -q "memory" "$tmp/out" || fail "a capped pass says nothing about memory: $(cat "$tmp/out")"
mem
[ "$(PATH=$sd:$PATH FORGE_TEST_MEMORY=2G code "$forge" test --force)" = 0 ] || fail "a run with the removed FORGE_TEST_MEMORY set passes: $(cat "$tmp/out")"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0 -- true" ] && [[ $(scopes | sed -n 2p) == *" -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0 -- "* ]] || fail "FORGE_TEST_MEMORY no longer sets MemoryMax: $(cat "$SD_LOG")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Memory: `2G` per run.\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "memory budget"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] || fail "a run with a Memory line passes: $(cat "$tmp/out")"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=2G -p MemoryHigh=1887436K -p MemorySwapMax=0 -- true" ] && [[ $(scopes | sed -n 2p) == *" -p MemoryMax=2G -p MemoryHigh=1887436K -p MemorySwapMax=0 -- "* ]] || fail "the Memory line sets MemoryMax and a 90% MemoryHigh of the probe and the run scope: $(cat "$SD_LOG")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Memory: `4GB` per run.\n' >"$x/.forge/TESTING.md"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 1 ] && grep -qF '`4GB`: not a size' "$tmp/out" && [ ! -s "$SD_LOG" ] && [ -z "$(ran)" ] && ! grep -q "cap unavailable" "$tmp/out" || fail "a bad Memory line fails before the probe: $(cat "$tmp/out") $(cat "$SD_LOG")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Memory: `2G` per run.\n' >"$x/.forge/TESTING.md"
mem 0 137
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "an exit-137 kill is retried once and then passes: $(cat "$tmp/out") $(ran)"
[ "$(units | wc -l)" = 2 ] && [ "$(units | sort -u | wc -l)" = 2 ] && reset || fail "each attempt runs in its own scope unit, reset afterwards: $(cat "$SD_LOG") $(cat "$SC_LOG")"
[ "$(scopes | wc -l)" = 3 ] && [ "$(scopes | grep -cF -- " -p MemorySwapMax=0 -")" = 3 ] && ! grep -qE 'CPUWeight|CPUQuota|AllowedCPUs' "$SD_LOG" || fail "the probe and both full attempts, the retry included, carry MemorySwapMax=0 and no CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
[ "$(lastline)" = "forge: tests passed ($(xshort))" ] || fail "a retried pass line: $(lastline)"
mem 0 1 1
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "a scope Result of oom-kill is retried once and then passes: $(cat "$tmp/out") $(ran)"
u=$(units | head -n1)
grep -qxF -- "--user show -p Result --value $u.scope" "$SC_LOG" || fail "the scope Result is read: $(cat "$SC_LOG")"
[ "$(grep -nxF -- "--user show -p Result --value $u.scope" "$SC_LOG" | cut -d: -f1)" -lt "$(grep -nxF -- "--user reset-failed $u.scope" "$SC_LOG" | cut -d: -f1)" ] || fail "the Result is read before reset-failed: $(cat "$SC_LOG")"
echo 137 >"$T_EXIT"
mem
s=$(PATH=$sd:$PATH code "$forge" test --force)
[ "$s" = 75 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "a second memory kill exits 75 after one retry: $s $(cat "$tmp/out") $(ran)"
grep "^forge: tests killed for memory" "$tmp/out" | grep -qwF 2G && grep "^forge: tests killed for memory" "$tmp/out" | grep -qF "$xlog" || fail "a second kill names the Memory budget and log: $(cat "$tmp/out")"
reset || fail "killed scopes are reset: $(cat "$SC_LOG")"
echo 3 >"$T_EXIT"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "another failure is never retried: $(cat "$tmp/out") $(ran)"
[ "$(lastline)" = "forge: tests failed, log $xlog" ] || fail "a capped failure line: $(lastline)"
mem
[ "$(PATH=$sd:$PATH SC_FAIL=1 code "$forge" test --force)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a systemctl error is no kill: $(cat "$tmp/out") $(ran)"
echo 0 >"$T_EXIT"
mem
[ "$(PATH=$sd:$PATH SC_FAIL=1 code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a systemctl error never fails a passing run: $(cat "$tmp/out") $(ran)"
mem 1
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a failed probe runs the suite: $(cat "$tmp/out") $(ran)"
grep -qxF "forge: memory cap unavailable, running uncapped" "$tmp/out" || fail "a failed probe says it runs uncapped: $(cat "$tmp/out")"
[ "$(wc -l <"$SD_LOG")" = 1 ] || fail "a failed probe runs the suite outside a scope: $(cat "$SD_LOG")"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=2G -p MemoryHigh=1887436K -p MemorySwapMax=0 -- true" ] && ! grep -qF CPUWeight "$SD_LOG" "$SC_LOG" ||
  fail "a failed probe carries no CPUWeight and then starts no scope: $(cat "$SD_LOG") $(cat "$SC_LOG")"
ns=$(find "$st" -type f ! -name runs.log | wc -l)
mrl=$st/runs.log
mn=$(if [ -f "$mrl" ]; then wc -l <"$mrl"; else echo 0; fi)
mem
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "a capped --one run passes: $(cat "$tmp/out") $(ran)"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=1048576K -p MemoryHigh=943718K -p MemorySwapMax=0 -- true" ] && [ "$(scopes | wc -l)" = 2 ] && [[ $(scopes | sed -n 2p) == "--user --scope --quiet --unit=forge-test-"*" -p MemoryMax=1048576K -p MemoryHigh=943718K -p MemorySwapMax=0 -- "* ]] || fail "--one probes and runs in a named scope with the narrow budget, half the 2G Memory line, as MemoryMax=1048576K, MemoryHigh=943718K and MemorySwapMax: $(cat "$SD_LOG")"
[ "$(units | wc -l)" = 1 ] && reset || fail "the --one scope unit is reset afterwards: $(cat "$SC_LOG")"
grep -qxF "ran one a" "$tmp/out" && ! grep -qxF "ran one a" "$xlog" || fail "a capped --one prints the test's output to the terminal, not the log: $(cat "$tmp/out")"
mem 0 137
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] || fail "a memory-killed --one is retried once and then passes: $(cat "$tmp/out") $(ran)"
[ "$(units | wc -l)" = 2 ] && [ "$(units | sort -u | wc -l)" = 2 ] && reset || fail "each --one attempt runs in its own scope unit, reset afterwards: $(cat "$SD_LOG") $(cat "$SC_LOG")"
[ "$(scopes | wc -l)" = 3 ] && [ "$(scopes | grep -cF -- " -p MemorySwapMax=0 -")" = 3 ] && ! grep -qE 'CPUWeight|CPUQuota|AllowedCPUs' "$SD_LOG" || fail "the --one probe and both attempts, the retry included, carry no CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
mem 0 "" 1
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] || fail "a --one scope Result of oom-kill is retried once and then passes: $(cat "$tmp/out") $(ran)"
echo 137 >"$T_EXIT"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 75 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] || fail "a second memory kill of --one exits 75 after one retry: $(cat "$tmp/out") $(ran)"
for c in 3:3 5:1 75:1; do
  echo "${c%:*}" >"$T_EXIT"
  mem
  [ "$(PATH=$sd:$PATH code "$forge" test --one a)" = "${c#*:}" ] && [ "$(ran)" = "[one][a]" ] || fail "a capped --one exiting ${c%:*} exits ${c#*:} without a retry: $(cat "$tmp/out") $(ran)"
done
echo 0 >"$T_EXIT"
mem 1
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] && grep -qxF "forge: memory cap unavailable, running uncapped" "$tmp/out" && [ "$(wc -l <"$SD_LOG")" = 1 ] || fail "a --one run with a failed probe runs uncapped with the notice: $(cat "$tmp/out") $(cat "$SD_LOG")"
[[ $(sed -n 1p "$SD_LOG") == *" -p MemorySwapMax=0"*" -- true" ]] && ! grep -qF CPUWeight "$SD_LOG" "$SC_LOG" || fail "a --one failed probe carries no CPUWeight: $(cat "$SD_LOG") $(cat "$SC_LOG")"
[ "$(find "$st" -type f ! -name runs.log | wc -l)" = "$ns" ] || fail "a capped --one records no stamp: $(find "$st" -type f)"
[ "$(tail -n +$((mn + 1)) "$mrl" 2>/dev/null | cut -d' ' -f3,7 | paste -sd,)" = "one 0,one 0,one 0,one 75,one 3,one 1,one 1,one 0" ] && tail -n +$((mn + 1)) "$mrl" | awk 'NF != 12 || $(NF - 1) !~ /^peak=/ || $NF != "cpu=0.00" { b = 1 } END { exit b }' ||
  fail "each capped --one appends exactly one 12-field runs.log line with tier one and its returned exit, 75 for the memory kill, peak= second to last and cpu=0.00 last: $(tail -n +$((mn + 1)) "$mrl" 2>/dev/null)"
mem
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] && [ ! -s "$SC_LOG" ] && [ ! -s "$SD_LOG" ] || fail "no systemd-run on PATH runs as today, starting no scope: $(cat "$tmp/out") $(cat "$SD_LOG")"
! grep -q "memory" "$tmp/out" || fail "no systemd-run prints nothing about memory: $(cat "$tmp/out")"
echo 137 >"$T_EXIT"
mem
[ "$(code "$forge" test --force)" = 137 ] && [ "$(ran)" = "[all]" ] || fail "no systemd-run never retries an exit 137: $(cat "$tmp/out") $(ran)"
echo 0 >"$T_EXIT"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "no Test line again"
mem
[ "$(PATH=$sd:$PATH code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a capped --one fallback passes: $(cat "$tmp/out") $(ran)"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet --expand-environment=no -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0 -- true" ] && [ "$(scopes | wc -l)" = 2 ] && [[ $(scopes | sed -n 2p) == "--user --scope --quiet --unit=forge-test-"*" -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0 -- "* ]] || fail "the --one fallback runs in a capped scope at the 4G budget: $(cat "$tmp/out") $(cat "$SD_LOG")"
! grep -qF FORGE_TEST_MEMORY "$root/global/settings.json" || fail "global settings no longer set the removed FORGE_TEST_MEMORY"
ok test-memory
fi

if want test-scope; then
cd "$x"
sr=$tmp/scope
gitinit "$sr"
mkdir -p "$sr/.forge" "$tmp/sdrej"
cat >"$sr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1 $(ulimit -c) $(ulimit -H -c)" >>"$T_LOG"
EOF
chmod +x "$sr/t.sh"
cat >"$tmp/sdrej/systemd-run" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ $a != MemorySwapMax=* ]] || { echo "$*" >>"$SD_LOG"; echo "Unknown assignment: $a" >&2; exit 1; }; done
exec "${0%/*}/../sd/systemd-run" "$@"
EOF
chmod +x "$tmp/sdrej/systemd-run"
echo a >"$sr/a.txt"
sdoc() { { printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Quarantine: `./t.sh q`\n- Perf log: `./t.sh perf`\n'; printf '%s\n' "$@"; } >"$sr/.forge/TESTING.md"; git -C "$sr" add -A && git -C "$sr" commit -q --allow-empty -m "scope doc"; }
core() { (ulimit -S -c unlimited 2>/dev/null || :; code "$@"); }
tiers() { cut -d' ' -f1 "$T_LOG" | paste -sd,; }
uncored() { [ -s "$T_LOG" ] && [ "$(cut -d' ' -f2- "$T_LOG" | sort -u)" = "0 0" ]; }
props() { echo "--expand-environment=no -p MemoryMax=$1 -p MemoryHigh=$2 -p MemorySwapMax=0"; }
inscope() {
  local i
  [ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet $1 -- true" ] && [ "$(scopes | wc -l)" = "$2" ] && ! grep -qF LimitCORE "$SD_LOG" && ! grep -qE 'CPUWeight|CPUQuota|AllowedCPUs' "$SD_LOG" || return 1
  for i in $(seq 2 "$2"); do [[ $(scopes | sed -n "${i}p") == "--user --scope --quiet --unit=forge-test-"*" $1 -- "* ]] || return 1; done
}
pa=$(props 4G 3774873K)
sdoc
mem
[ "$(PATH=$sd:$PATH core "$forge" test --force "$sr")" = 0 ] && [ "$(tiers)" = all,q ] || fail "a capped run and its quarantine pass: $(cat "$tmp/out") $(cat "$T_LOG")"
inscope "$pa" 3 || fail "the probe, the full scope and the quarantine scope each set MemoryMax=4G, MemoryHigh=3774873K, MemorySwapMax=0, never LimitCORE, CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
uncored || fail "a capped run and its quarantine run with soft and hard core limits of 0: $(cat "$T_LOG")"
mem 0 137
[ "$(PATH=$sd:$PATH core "$forge" test --force "$sr")" = 0 ] && [ "$(tiers)" = all,all,q ] || fail "a memory-killed capped run is retried and passes: $(cat "$tmp/out") $(cat "$T_LOG")"
inscope "$pa" 4 && [ "$(units | sort -u | wc -l)" = 3 ] || fail "the retry scope and the quarantine scope set the same MemoryMax, MemoryHigh and MemorySwapMax: $(cat "$SD_LOG")"
uncored || fail "both attempts and the quarantine run with core dumps off: $(cat "$T_LOG")"
mem
[ "$(PATH=$sd:$PATH core "$forge" test --one a "$sr")" = 0 ] && [ "$(tiers)" = one ] && uncored || fail "--one runs with soft and hard core limits of 0: $(cat "$tmp/out") $(cat "$T_LOG")"
inscope "$(props 2097152K 1887436K)" 2 || fail "the --one probe and scope set the narrow MemoryMax=2097152K, MemoryHigh=1887436K and MemorySwapMax=0, never LimitCORE, CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
mem
[ "$(PATH=$tmp/sdrej:$PATH core "$forge" test --one a "$sr")" = 0 ] && [ "$(tiers)" = one ] && uncored && grep -qxF "forge: memory cap unavailable, running uncapped" "$tmp/out" && [ "$(scopes | wc -l)" = 1 ] || fail "a --one probe rejected for MemorySwapMax runs uncapped with core dumps off and the notice: $(cat "$tmp/out") $(cat "$SD_LOG")"
mem
[ "$(core "$forge" test --force "$sr")" = 0 ] && [ "$(tiers)" = all,q ] && [ ! -s "$SD_LOG" ] && [ ! -s "$SC_LOG" ] && uncored || fail "an uncapped run and its quarantine run with core dumps off, starting no scope: $(cat "$tmp/out") $(cat "$T_LOG")"
mem
[ "$(PATH=$tmp/sdrej:$PATH core "$forge" test --force "$sr")" = 0 ] && [ "$(tiers)" = all,q ] || fail "a host rejecting MemorySwapMax still runs the suite and its quarantine: $(cat "$tmp/out") $(cat "$T_LOG")"
grep -qxF "forge: memory cap unavailable, running uncapped" "$tmp/out" && [ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet $pa -- true" ] && [ "$(scopes | wc -l)" = 1 ] && ! grep -qF CPUWeight "$SD_LOG" ||
  fail "a probe rejected for MemorySwapMax falls back to uncapped with its notice and starts no scope: $(cat "$tmp/out") $(cat "$SD_LOG")"
uncored || fail "the uncapped fallback runs with core dumps off: $(cat "$T_LOG")"
sdoc '- Memory: `512M`'
mem
[ "$(PATH=$sd:$PATH core "$forge" test --force "$sr")" = 0 ] && inscope "$(props 512M 471859K)" 3 || fail "a 512M Memory line sets MemoryHigh=471859K on the probe and every scope: $(cat "$tmp/out") $(cat "$SD_LOG")"
sdoc '- Changed tests: `./t.sh changed {files}`'
mem
[ "$(PATH=$sd:$PATH core "$forge" test --changed --force --base HEAD~1 "$sr")" = 0 ] && [ "$(tiers)" = changed ] || fail "a capped changed run passes: $(cat "$tmp/out") $(cat "$T_LOG")"
inscope "$(props 4G 3774873K)" 2 || fail "a capped changed run's probe and scope carry MemoryMax=4G, MemoryHigh=3774873K and MemorySwapMax=0, never CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
mem 0 137
[ "$(PATH=$sd:$PATH core "$forge" test --changed --force --base HEAD~1 "$sr")" = 0 ] && [ "$(tiers)" = changed,changed ] && inscope "$(props 4G 3774873K)" 3 || fail "a memory-killed changed run's retry scope carries the same properties: $(cat "$tmp/out") $(cat "$SD_LOG")"
mem
[ "$(core "$forge" test --changed --force --base HEAD~1 "$sr")" = 0 ] && [ "$(tiers)" = changed ] && [ ! -s "$SD_LOG" ] && [ ! -s "$SC_LOG" ] || fail "an uncapped changed run starts no scope: $(cat "$tmp/out") $(cat "$SD_LOG")"
sdoc '- Setup: `./t.sh setup`'
mem
[ "$(PATH=$sd:$PATH core "$forge" test --force "$sr")" = 0 ] && [[ $(tiers) == setup,*all,q ]] && inscope "$pa" 3 && ! grep -qF setup "$SD_LOG" || fail "Setup stays unscoped while the probe, the full scope and the quarantine scope are capped: $(cat "$tmp/out") $(cat "$T_LOG") $(cat "$SD_LOG")"
mkdir -p "$tmp/sdold"
cat >"$tmp/sdold/systemd-run" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" != --expand-environment=no ] || { echo "$*" >>"$SD_LOG"; echo "systemd-run: unrecognized option '$a'" >&2; exit 1; }; done
exec "${0%/*}/../sd/systemd-run" "$@"
EOF
chmod +x "$tmp/sdold/systemd-run"
printf '%s\n' '# Testing' '' '## Commands' '- All tests: `a=all; ./t.sh "$a"`' '- Test: `t={test}; s=${t%%:*}; ./t.sh "${t:${#s}+1}"`' '- Quarantine: `q=q; ./t.sh "${q}"`' >"$sr/.forge/TESTING.md"
git -C "$sr" commit -q -am "dollar commands"
mem
[ "$(PATH=$sd:$PATH core "$forge" test --force "$sr")" = 0 ] && [ "$(tiers)" = all,q ] && [ "$(scopes | wc -l)" = 3 ] || fail "a capped run and its quarantine hand their \$-bearing commands to bash verbatim: $(cat "$tmp/out") $(cat "$T_LOG") $(cat "$SD_LOG")"
mem
[ "$(PATH=$sd:$PATH core "$forge" test --one x:y "$sr")" = 0 ] && [ "$(tiers)" = y ] && [ "$(scopes | wc -l)" = 2 ] || fail "a capped --one hands its \$-bearing Test command to bash verbatim: $(cat "$tmp/out") $(cat "$T_LOG") $(cat "$SD_LOG")"
mem
[ "$(PATH=$tmp/sdold:$PATH core "$forge" test --one x:y "$sr")" = 0 ] && [ "$(tiers)" = y ] && [ "$(scopes | wc -l)" = 1 ] && grep -qxF "forge: memory cap unavailable, running uncapped" "$tmp/out" || fail "a systemd-run that rejects --expand-environment=no fails the probe and runs uncapped with the notice: $(cat "$tmp/out") $(cat "$T_LOG") $(cat "$SD_LOG")"
ok test-scope
fi

if want test-repeat; then
cd "$x"
rp=$tmp/repeat
gitinit "$rp"
mkdir -p "$rp/.forge"
cat >"$rp/t.sh" <<'EOF'
#!/usr/bin/env bash
h=0
for f in "$XDG_RUNTIME_DIR"/forge/test-runs/*; do [ -f "$f" ] && ! flock -n "$f" true && h=$((h + 1)); done
echo "$1 ${FORGE_TEST_SLOT_HELD-unset} ${FORGE_TEST_CPUS-unset} $h" >>"$R_LOG"
echo "ran $*"
c=$(sed -n "$(wc -l <"$R_LOG")p" "$R_CODES" 2>/dev/null)
exit "${c:-0}"
EOF
chmod +x "$rp/t.sh"
echo a >"$rp/a.txt"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$rp/.forge/TESTING.md"
git -C "$rp" add -A && git -C "$rp" commit -q -m init && git -C "$rp" checkout -q -b side
export R_LOG=$tmp/repeat.log R_CODES=$tmp/repeat.codes
rep() { local s=0 p=$tmp/cpubin:$PATH; [ -n "${NOSD:-}" ] || p=$sd:$p; : >"$R_LOG"; printf '%s' "${RC:-}" >"$R_CODES"; PATH=$p NPROC=24 timeout 60 "$forge" test "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
rcol() { cut -d' ' -f"$1" "$R_LOG" | paste -sd,; }
rall() { cat "$tmp/out" "$tmp/err"; }
mem
[ "$(rep --repeat 3 --one a "$rp")" = 0 ] && [ "$(rcol 1)" = one,one,one ] || fail "--repeat 3 --one runs the Test command 3 times and exits 0: $(rall) $(cat "$R_LOG")"
grep -qxF "forge: repeat passed 3/3" <(rall) || fail "3 passing iterations print forge: repeat passed 3/3: $(rall)"
[ "$(grep -cxF "ran one a" "$tmp/out")" = 3 ] || fail "each iteration's output reaches the terminal: $(cat "$tmp/out")"
[ "$(cut -d' ' -f2 "$R_LOG" | sort -u | wc -l)" = 1 ] && [[ $(cut -d' ' -f2 "$R_LOG" | head -n1) == "$XDG_RUNTIME_DIR"/forge/test-runs/[1-9]* ]] && [ "$(rcol 4)" = 1,1,1 ] || fail "one run slot is held across every iteration: $(cat "$R_LOG")"
[ "$(rcol 3)" = 2,2,2 ] || fail "each iteration gets the one-tier FORGE_TEST_CPUS=2 on nproc 24 with no - CPUs one: line: $(cat "$R_LOG")"
p8="--expand-environment=no -p MemoryMax=4G -p MemoryHigh=3774873K -p MemorySwapMax=0"
[ "$(sed -n 1p "$SD_LOG")" = "--user --scope --quiet $p8 -- true" ] && [ "$(scopes | wc -l)" = 4 ] && [ "$(units | wc -l)" = 3 ] && [ "$(units | sort -u | wc -l)" = 3 ] && reset || fail "one probe, then each iteration in its own capped scope with a unique unit name, reset afterwards: $(cat "$SD_LOG") $(cat "$SC_LOG")"
for i in 2 3 4; do [[ $(scopes | sed -n "${i}p") == "--user --scope --quiet --unit=forge-test-"*" $p8 -- "* ]] || fail "iteration scope $i carries the full property set: $(cat "$SD_LOG")"; done
! grep -qE 'CPUWeight|CPUQuota|AllowedCPUs' "$SD_LOG" || fail "a --repeat passes no CPUWeight, CPUQuota or AllowedCPUs: $(cat "$SD_LOG")"
mem 0 $'\n137'
[ "$(rep --repeat 3 --one a "$rp")" = 0 ] && [ "$(rcol 1)" = one,one,one,one ] && grep -qxF "forge: repeat passed 3/3" <(rall) || fail "a memory-killed iteration is retried once and the repeat passes 3/3: $(rall) $(cat "$R_LOG")"
[ "$(units | wc -l)" = 4 ] && [ "$(units | sort -u | wc -l)" = 4 ] && reset || fail "unit names are unique per iteration and retry: $(cat "$SD_LOG")"
[ "$(scopes | wc -l)" = 5 ] && [ "$(scopes | grep -cF -- " -p MemorySwapMax=0 -")" = 5 ] || fail "the probe, every iteration and the retried one carry the memory properties: $(cat "$SD_LOG")"
mem
[ "$(RC=$'0\n4\n0\n' rep --repeat 3 --one a "$rp")" = 4 ] && [ "$(rcol 1)" = one,one ] || fail "a failure on iteration 2 stops there with its exit code: $(rall) $(cat "$R_LOG")"
grep -qxF "forge: repeat failed on iteration 2/3" "$tmp/err" || fail "a failure on iteration 2 prints forge: repeat failed on iteration 2/3 on stderr: $(rall)"
! grep -qF "repeat passed" <(rall) || fail "a failed repeat prints no pass line: $(rall)"
for c in 5 75; do
  mem
  [ "$(RC=$'0\n'"$c"$'\n0\n' rep --repeat 3 --one a "$rp")" = 1 ] && [ "$(rcol 1)" = one,one ] && grep -qxF "forge: repeat failed on iteration 2/3" "$tmp/err" || fail "an iteration exiting $c stops the repeat with exit 1: $(rall) $(cat "$R_LOG")"
done
mem
[ "$(NOSD=1 rep --repeat 2 --one a "$rp")" = 0 ] && [ "$(rcol 1)" = one,one ] && grep -qxF "forge: repeat passed 2/2" <(rall) && [ ! -s "$SD_LOG" ] || fail "--repeat without systemd-run runs every iteration uncapped: $(rall) $(cat "$R_LOG")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$rp/.forge/TESTING.md"
echo b >"$rp/b.txt"
git -C "$rp" add -A && git -C "$rp" commit -q -m "no Test line"
mem
[ "$(rep --repeat 2 --one a "$rp")" = 0 ] && [ "$(rcol 1)" = changed,changed ] && grep -qxF "forge: repeat passed 2/2" <(rall) || fail "--repeat without a Test line repeats the changed tier's command: $(rall) $(cat "$R_LOG")"
[ "$(scopes | wc -l)" = 3 ] && [ "$(units | sort -u | wc -l)" = 2 ] && [ "$(scopes | grep -cF -- " -p MemorySwapMax=0 -")" = 3 ] || fail "each fallback iteration runs in its own capped scope: $(cat "$SD_LOG")"
mem
[ "$(RC=$'0\n3\n' rep --repeat 3 --one a "$rp")" = 3 ] && [ "$(rcol 1)" = changed,changed ] && grep -qxF "forge: repeat failed on iteration 2/3" "$tmp/err" || fail "a fallback iteration failing stops the repeat: $(rall) $(cat "$R_LOG")"
for a in "--repeat 0 --one a" "--repeat x --one a" "--repeat -1 --one a" "--repeat 9223372036854775808 --one a" "--repeat 18446744073709551617 --one a"; do
  mem
  s=$(rep $a "$rp")
  [[ $s == [12] ]] && [ ! -s "$R_LOG" ] || fail "forge test $a is rejected, running nothing: $s $(rall)"
done
mem
[ "$(rep --repeat)" = 2 ] && [ ! -s "$R_LOG" ] || fail "forge test --repeat without a count is a usage error: $(rall)"
for a in "--repeat 2" "--repeat 2 --changed" "--repeat 2 --stack" "--repeat 2 --one a --stack" "--repeat 2 --passed" "--repeat 2 --one a --passed"; do
  mem
  [ "$(rep $a "$rp")" = 2 ] && [ ! -s "$R_LOG" ] || fail "forge test $a is a usage error: $(rall)"
done
ok test-repeat
fi

if want test-log-dir; then
cd "$x"
lg=$tmp/logdir
gitinit "$lg"
mkdir -p "$lg/.forge"
cat >"$lg/t.sh" <<'EOF'
#!/usr/bin/env bash
d=${FORGE_TEST_LOG_DIR-unset}
c=missing
[ "$d" = unset ] || [ ! -d "$d" ] || c=$(ls -A "$d" | paste -sd,)
echo "$1|$d|$c" >>"$L_LOG"
if [ "$d" != unset ] && [ -d "$d" ]; then mkdir -p "$d/forge" && echo old >"$d/forge/commit.log" && echo old >"$d/$1.log"; fi
EOF
chmod +x "$lg/t.sh"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n- Perf log: `./t.sh perf`\n' >"$lg/.forge/TESTING.md"
echo a >"$lg/a.txt"
git -C "$lg" add -A && git -C "$lg" commit -q -m init && git -C "$lg" checkout -q -b side
echo b >"$lg/b.txt" && git -C "$lg" add -A && git -C "$lg" commit -q -m change
export L_LOG=$tmp/logdir.log
lgd=$(git -C "$lg" rev-parse --absolute-git-dir)/forge-test.d
ldir() { local s=0 t=$SECONDS p=$tmp/cpubin:$PATH; [ -z "${CAP:-}" ] || p=$sd:$p; : >"$L_LOG"; PATH=$p NPROC=24 timeout 300 "$forge" test "$@" >"$tmp/out" 2>&1 || s=$?; echo "exit $s after $((SECONDS - t))s" >"$tmp/lrc"; echo $s; }
lrec() { cat "$L_LOG"; }
stale() { mkdir -p "$1/forge" && echo stale >"$1/stale.log" && echo stale >"$1/forge/old.log"; }
for lm in "all --force" "changed --changed --force"; do
  read -r lt la <<<"$lm"
  for lcap in "" 1; do
    mem
    stale "$lgd"
    [ "$(CAP=$lcap ldir $la "$lg")" = 0 ] || fail "forge test $la${lcap:+ capped} passes, got $(cat "$tmp/lrc"): $(cat "$tmp/out")"
    IFS='|' read -r lw lv lc <<<"$(lrec)"
    [ "$lw" = "$lt" ] && [ "$(wc -l <"$L_LOG")" = 1 ] || fail "forge test $la${lcap:+ capped} runs the $lt command once: $(lrec) $(cat "$tmp/out")"
    [ "${lv%/}" = "$lgd" ] || fail "forge test $la${lcap:+ capped} exports FORGE_TEST_LOG_DIR=$lgd/ to the command: $(lrec)"
    [ -z "$lc" ] || fail "forge test $la${lcap:+ capped} empties $lgd before the command runs, removing a previous run's logs: $(lrec)"
    [ ! -e "$lgd/stale.log" ] && [ ! -e "$lgd/forge/old.log" ] || fail "forge test $la${lcap:+ capped} removes the stale logs in $lgd: $(find "$lgd" 2>/dev/null)"
  done
done
mem
[ "$(ldir --force "$lg")" = 0 ] && [ "$(ldir --force "$lg")" = 0 ] && [ "$(lrec)" = "all|$(cut -d'|' -f2 "$L_LOG")|" ] || fail "a second full run finds the first run's logs removed: $(lrec)"
mem
stale "$lgd"
[ "$(FORGE_TEST_LOG_DIR=$tmp/elsewhere ldir --force "$lg")" = 0 ] && [ "$(cut -d'|' -f2 "$L_LOG" | sed 's:/$::')" = "$lgd" ] || fail "a preset FORGE_TEST_LOG_DIR is overwritten for a full run: $(lrec)"
git -C "$lg" worktree add -q "$tmp/logdir-wt" -b wt
wgd=$(git -C "$tmp/logdir-wt" rev-parse --absolute-git-dir)/forge-test.d
mem
[ "$(ldir --force "$tmp/logdir-wt")" = 0 ] && [ "$(cut -d'|' -f2 "$L_LOG" | sed 's:/$::')" = "$wgd" ] || fail "a linked worktree's full run sets FORGE_TEST_LOG_DIR under its own git dir $wgd: $(lrec)"
for la in "--one a" "--repeat 2 --one a"; do
  for lcap in "" 1; do
    mem
    [ "$(CAP=$lcap ldir $la "$lg")" = 0 ] || fail "forge test $la${lcap:+ capped} passes, got $(cat "$tmp/lrc"): $(cat "$tmp/out")"
    [ -s "$L_LOG" ] && ! grep -qv '^one|unset|missing$' "$L_LOG" || fail "forge test $la${lcap:+ capped} leaves FORGE_TEST_LOG_DIR unset: $(lrec)"
  done
done
ok test-log-dir
fi

if want test-runs-log; then
cd "$x"
rlog=$st/runs.log
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
echo side >"$x/side.txt" && git -C "$x" add side.txt
git -C "$x" commit -q --allow-empty -am "runs log"
rm -f "$rlog"
runs() { [ -f "$rlog" ] && wc -l <"$rlog" || echo 0; }
fields() { local -a f; read -ra f <<<"$(tail -n1 "$rlog" 2>/dev/null)"; [ ${#f[@]} -ge 10 ] && echo "${f[@]: -10}"; }
logged() {
  local t tr w d e la ma b pk cp
  [ "$(tail -n1 "$rlog" | wc -w)" = 12 ] && read -r t tr w d e la ma b pk cp <<<"$(fields)" || return 1
  [[ $t =~ ^($1)$ ]] && [ ${#tr} -ge 7 ] && [[ $(xtree) == "$tr"* ]] && [[ $w =~ ^[0-9]+$ ]] && [[ $d =~ ^[0-9]+$ ]] &&
    [ "$e" = "$2" ] && [[ $la =~ ^[0-9]+\.[0-9]+$ ]] && [[ $ma =~ ^[0-9]+$ ]] && [ "$b" = "${3:-4G}" ] && [ "$pk" = "peak=${4:--}" ] && [ "$cp" = "cpu=${5:-0.00}" ]
}
field() { local -a f; read -ra f <<<"$(fields)"; echo "${f[$1]}"; }
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a full run passes: $(cat "$tmp/out")"
[ "$(runs)" = 1 ] || fail "a full run appends one line to <git common dir>/forge-test/runs.log: $(cat "$rlog" 2>/dev/null)"
logged 'all|full' 0 || fail "a full run's 12-field line ends with tier, tree, slot wait s, run s, exit code, 1-min load, MemAvailable, Memory budget (default 4G), peak=- uncapped and cpu=0.00 from the fixture's some avg10: $(cat "$rlog")"
: >"$T_LOG"
[ "$(code "$forge" test --changed --force)" = 0 ] && [[ $(ran) == "[changed]"* ]] || fail "a changed run passes: $(cat "$tmp/out") $(ran)"
[ "$(runs)" = 2 ] || fail "a changed run appends one line: $(cat "$rlog")"
logged changed 0 || fail "a changed run's line ends with tier changed, tree, slot wait s, run s, exit code, load, MemAvailable, Memory budget: $(cat "$rlog")"
echo 42 >"$T_EXIT"
[ "$(code "$forge" test --force)" = 42 ] || fail "a failing run exits with its code: $(cat "$tmp/out")"
[ "$(runs)" = 3 ] && logged 'all|full' 42 || fail "a failing run logs its exit code: $(cat "$rlog")"
echo 0 >"$T_EXIT"
"$forge" test --force >/dev/null
n=$(runs)
[ "$(code "$forge" test)" = 0 ] && [[ $(lastline) == *", cached" ]] || fail "a cached run passes: $(cat "$tmp/out")"
[ "$(code "$forge" test --changed)" = 0 ] && [[ $(lastline) == *", cached" ]] || fail "a cached changed run passes: $(cat "$tmp/out")"
[ "$(runs)" = "$n" ] || fail "a cached run appends nothing: $(cat "$rlog")"
[ "$(code "$forge" test --changed --force --base HEAD)" = 0 ] && [[ $(lastline) == *", no changed files" ]] || fail "a no-changed-files run passes: $(cat "$tmp/out")"
[ "$(runs)" = "$n" ] || fail "the no-changed-files case appends nothing: $(cat "$rlog")"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(runs)" = $((n + 1)) ] || fail "a --one run appends one runs.log line: $(cat "$rlog")"
[ "$(tail -n1 "$rlog" | wc -w)" = 12 ] && logged one 0 2097152K || fail "a --one run's line has 12 fields, cpu= last, tier one, its tree, numeric waited and run seconds, exit 0 and its narrow budget: $(tail -n1 "$rlog")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "runs log fallback"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [[ $(ran) == "[changed]"* ]] && [ "$(runs)" = $((n + 2)) ] && [ "$(tail -n1 "$rlog" | wc -w)" = 12 ] && logged one 0 ||
  fail "the --one fallback appends one runs.log line with tier one, never a passing all or changed line: $(cat "$tmp/out") $(cat "$rlog")"
n=$(runs)
mem 0 137
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "a memory-killed run is retried: $(cat "$tmp/out")"
[ "$(runs)" = $((n + 1)) ] && logged 'all|full' 0 || fail "a retried run appends one line with its final exit code: $(cat "$rlog")"
mem 0 "" 2
[ "$(PATH=$sd:$PATH code "$forge" test --force)" = 75 ] && grep -q "^forge: tests killed for memory" "$tmp/out" || fail "two oom-kill Results with exit 0 exit 75 for memory: $(cat "$tmp/out")"
[ "$(runs)" = $((n + 2)) ] && logged 'all|full' 137 || fail "a memory failure never logs exit code 0: $(cat "$rlog")"
rn=$XDG_RUNTIME_DIR/forge/test-runs
mkdir -p "$rn"
: >>"$rn/1"
flock "$rn/1" sleep 3 & fp=$!
until ! flock -n "$rn/1" true; do sleep 0.05; done
[ "$(FORGE_TEST_RUNS=1 FORGE_TEST_POLL_SECS= code timeout 20 "$forge" test --force)" = 0 ] && grep -q "^forge: waiting for a test run slot" "$tmp/out" || fail "a run waits for a held run slot: $(cat "$tmp/out")"
wait $fp
logged 'all|full' 0 && [ "$(field 2)" -ge 1 ] || fail "a run that waited logs its run slot wait seconds: $(cat "$rlog")"
flock "$rn/1" sleep 4 & fp=$!
until ! flock -n "$rn/1" true; do sleep 0.05; done
echo "pid $$ in $x since now" >"$rn/1"
rm -f "$tmp/go2"
(sleep 2 && touch "$tmp/go2") &
[ "$(T_HOLD=$tmp/go2 FORGE_TEST_SLOT_HELD=$rn/1 FORGE_TEST_RUNS=1 code timeout 20 "$forge" test --force)" = 0 ] && ! grep -q waiting "$tmp/out" || fail "a run under FORGE_TEST_SLOT_HELD proceeds: $(cat "$tmp/out")"
logged 'all|full' 0 && [ "$(field 2)" = 0 ] || fail "a run under FORGE_TEST_SLOT_HELD logs a run slot wait of 0: $(cat "$rlog")"
[ "$(field 3)" -ge 1 ] || fail "a run logs its run seconds: $(cat "$rlog")"
wait $fp
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Memory: `512M`\n' >"$x/.forge/TESTING.md"
git -C "$x" commit -q -am "runs log budget"
n=$(runs)
[ "$(code "$forge" test --force)" = 0 ] && [ "$(runs)" = $((n + 1)) ] && logged 'all|full' 0 512M || fail "a run logs its Memory line's budget before an uncapped run's peak=-: $(cat "$rlog")"
pkp=$tmp/peakproc pks=$tmp/peaksys
mkdir -p "$pkp/self" "$pks/fs/cgroup/fake.scope" "$tmp/sdoom"
cp "$FORGE_PROC_ROOT/meminfo" "$pkp/meminfo"
cp -r "$FORGE_PROC_ROOT/pressure" "$pkp/"
echo 0::/fake.scope >"$pkp/self/cgroup"
cat >"$tmp/sdoom/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SD_LOG"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
[ "$*" != true ] || exit 0
n=$(wc -l <"$T_LOG")
set -m
"$@" &
c=$!
set +m
until [ "$(wc -l <"$T_LOG")" -gt "$n" ]; do sleep 0.05; done
kill -KILL -- "-$c"
wait "$c" || :
exit 137
EOF
chmod +x "$tmp/sdoom/systemd-run"
cat >"$x/pk.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${T_PEAKS:-}" ] || { head -n1 "$T_PEAKS" >"$T_PEAKF"; sed -i 1d "$T_PEAKS"; }
exec ./t.sh "$@"
EOF
chmod +x "$x/pk.sh"
pdoc() { printf '# Testing\n\n## Commands\n- All tests: `%s`\n- Test: `./pk.sh one {test}`\n- Changed tests: `./pk.sh changed {files}`\n' "${1:-./pk.sh all}" >"$x/.forge/TESTING.md"; git -C "$x" add -A && git -C "$x" commit -q -m "peak doc"; }
peak() { if [ -n "$1" ]; then echo "$1" >"$pks/fs/cgroup/fake.scope/memory.peak"; else rm -f "$pks/fs/cgroup/fake.scope/memory.peak"; fi; }
pk() { local s=0; : >"$T_LOG"; PATH=${PKP:-$sd}:$PATH FORGE_PROC_ROOT=$pkp FORGE_SYS_ROOT=$pks timeout 60 "$forge" test "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
pall() { cat "$tmp/out" "$tmp/err"; }
hint="forge: memory peak 3.5G of 4G budget; set - Memory: 5G in $(git -C "$x" rev-parse --show-toplevel)/.forge/TESTING.md"
onehint="forge: memory peak 3.5G of 2097152K budget; set - Memory one: 5G in $(git -C "$x" rev-parse --show-toplevel)/.forge/TESTING.md"
pdoc
echo 0 >"$T_EXIT"
mem
peak 3758096384
n=$(runs)
[ "$(pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a capped run with a readable memory.peak passes: $(pall) $(ran)"
[ "$(runs)" = $((n + 1)) ] && logged 'all|full' 0 4G 3670016 || fail "a capped run appends peak=<memory.peak bytes / 1024> as the last runs.log field, read via \$FORGE_PROC_ROOT/self/cgroup and \$FORGE_SYS_ROOT/fs/cgroup<path>/memory.peak: $(tail -n1 "$rlog")"
[ "$(grep -cF "memory peak" "$tmp/err")" = 1 ] && grep -qxF "$hint" "$tmp/err" || fail "a peak of 3.5 GiB of a 4G budget prints the hint on stderr: $hint, got: $(pall)"
! grep -qF "memory peak" "$tmp/out" || fail "the memory hint goes to stderr only: $(cat "$tmp/out")"
mem
peak 3758096384
[ "$(pk --changed --force)" = 0 ] && logged changed 0 4G 3670016 && grep -qxF "$hint" "$tmp/err" || fail "a capped changed run logs its peak and prints the hint: $(pall) $(tail -n1 "$rlog")"
mem
peak 3435973836
[ "$(pk --force)" = 0 ] && logged 'all|full' 0 4G 3355443 || fail "a peak of 3.2 GiB is logged as peak=3355443: $(tail -n1 "$rlog")"
! grep -qF "memory peak" <(pall) || fail "a peak at or below 80% of the budget prints no hint: $(pall)"
mem
peak 1073741824
[ "$(pk --force)" = 0 ] && logged 'all|full' 0 4G 1048576 && ! grep -qF "memory peak" <(pall) || fail "a 1 GiB peak is logged with no hint: $(pall) $(tail -n1 "$rlog")"
mem
peak ""
[ "$(pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] && logged 'all|full' 0 4G - && ! grep -qF "memory peak" <(pall) || fail "a capped run with no memory.peak file logs peak=- and prints no hint, its previous run's peak gone: $(pall) $(tail -n1 "$rlog")"
mem
peak x
[ "$(pk --force)" = 0 ] && logged 'all|full' 0 4G - || fail "a non-numeric memory.peak logs peak=-: $(pall) $(tail -n1 "$rlog")"
mem 1
peak 3758096384
[ "$(pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] && logged 'all|full' 0 4G - && ! grep -qF "memory peak" <(pall) || fail "a failed probe runs uncapped with peak=- and no hint: $(pall) $(tail -n1 "$rlog")"
mem
[ "$(PKP=$tmp/path pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] && logged 'all|full' 0 4G - && ! grep -qF "memory peak" <(pall) || fail "a run without systemd-run logs peak=- and prints no hint: $(pall) $(tail -n1 "$rlog")"
mem 0 "" 2
n=$(runs)
[ "$(PKP=$tmp/sdoom:$sd T_HOLD=$tmp/never pk --force)" = 75 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] && grep -q "^forge: tests killed for memory" "$tmp/err" || fail "a run killed for memory in both attempts exits 75: $(pall) $(ran)"
[ "$(runs)" = $((n + 1)) ] && logged 'all|full' 137 4G - || fail "a run whose wrapper dies with its oom-killed scope logs peak=- on capped's exit-75 line: $(cat "$rlog")"
! grep -qF "memory peak" <(pall) || fail "an oom-killed run prints no memory hint: $(pall)"
pdoc './pk.sh all; exit 3'
mem
peak 3758096384
[ "$(pk --force)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a command calling exit 3 keeps exit 3 inside the peak wrapper: $(pall) $(ran)"
logged 'all|full' 3 4G 3670016 || fail "a command calling exit 3 still records its peak: $(tail -n1 "$rlog")"
pdoc
mem
peak 3758096384
n=$(runs)
[ "$(pk --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] || fail "a capped --one with a peak passes: $(pall) $(ran)"
[ "$(grep -cF "memory peak" "$tmp/err")" = 1 ] && grep -qxF "$onehint" "$tmp/err" || fail "a capped --one prints the memory hint for its narrow budget, naming - Memory one:, on stderr: $(pall)"
[ "$(runs)" = $((n + 1)) ] && [ "$(tail -n1 "$rlog" | wc -w)" = 12 ] && logged one 0 2097152K 3670016 || fail "a --one run with a peak appends one runs.log line with tier one, exit 0 and its peak: $(tail -n2 "$rlog")"
mem
peak 1073741824
[ "$(pk --one a)" = 0 ] && ! grep -qF "memory peak" <(pall) || fail "a --one run at a 1 GiB peak prints no hint: $(pall)"
mem
peak 3758096384
echo 1073741824 >"$x/.git/forge-test-1.peak"
[ "$(pk --one a)" = 0 ] && grep -qxF "$onehint" "$tmp/err" || fail "a --one run beside another run's peak file reads its own peak: $(pall)"
[ "$(cd "$x/.git" && echo forge-test*.peak)" = forge-test-1.peak ] && [ "$(cat "$x/.git/forge-test-1.peak")" = 1073741824 ] || fail "a run removes its own per-run peak file once read and leaves a concurrent run's alone: $(ls "$x/.git")"
rm -f "$x/.git/forge-test-1.peak"
mem 0 "" 2
peak 3758096384
[ "$(pk --one a)" = 75 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] && grep -q "^forge: tests killed for memory" "$tmp/err" && [ "$(grep -cF "memory peak" "$tmp/err")" = 1 ] && grep -qxF "$onehint" "$tmp/err" || fail "a --one killed for memory twice whose scope still wrote a peak prints the hint before exit 75: $(pall) $(ran)"
mem
peak ""
printf '%s\n' 1073741824 3758096384 2147483648 >"$tmp/peaks"
n=$(runs)
[ "$(T_PEAKS=$tmp/peaks T_PEAKF=$pks/fs/cgroup/fake.scope/memory.peak pk --repeat 3 --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a],[one][a]" ] || fail "a capped --repeat 3 passes: $(pall) $(ran)"
[ "$(grep -cF "memory peak" "$tmp/err")" = 1 ] && grep -qxF "$hint" "$tmp/err" || fail "--repeat prints one hint for its highest iteration's peak, 3.5 GiB of 1, 3.5 and 2 GiB: $(pall)"
[ "$(runs)" = $((n + 1)) ] && [ "$(tail -n1 "$rlog" | wc -w)" = 12 ] && [ "$(field 0)" = repeat ] && [ "$(field 9)" = cpu=0.00 ] && [ "$(field 4)" = 0 ] && [ "$(field 7)" = 4G ] ||
  fail "--repeat appends one runs.log line per invocation with tier repeat, exit 0, its budget and cpu=0.00 last: $(tail -n2 "$rlog")"
pres() { if [ -n "$1" ]; then printf 'some avg10=%s avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$1" >"$pkp/pressure/cpu"; else rm -f "$pkp/pressure/cpu"; fi; }
mem
peak ""
pres 12.34
n=$(runs)
[ "$(pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] && [ "$(runs)" = $((n + 1)) ] && logged 'all|full' 0 4G - 12.34 && ! grep -qF "CPU pressure" <(pall) ||
  fail "a full run under CPU pressure some avg10 12.34 runs at once and ends its runs.log line with cpu=12.34 after peak=-: $(pall) $(tail -n1 "$rlog")"
mem
peak ""
[ "$(pk --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] && [ "$(runs)" = $((n + 2)) ] && logged one 0 2097152K - 12.34 && ! grep -qF "CPU pressure" <(pall) ||
  fail "a --one run under CPU pressure 12.34 ends its runs.log line with cpu=12.34 after peak=-: $(pall) $(tail -n1 "$rlog")"
pres ""
mem
peak ""
[ "$(pk --force)" = 0 ] && [ "$(ran)" = "[all]" ] && [ "$(runs)" = $((n + 3)) ] && logged 'all|full' 0 4G - - && ! grep -qF "CPU pressure" <(pall) ||
  fail "a full run with no pressure file logs cpu=- after peak=- and prints no pressure warning: $(pall) $(tail -n1 "$rlog")"
mem
peak ""
[ "$(pk --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] && [ "$(runs)" = $((n + 4)) ] && logged one 0 2097152K - - && ! grep -qF "CPU pressure" <(pall) ||
  fail "a --one run with no pressure file logs cpu=- after peak=- and prints no pressure warning: $(pall) $(tail -n1 "$rlog")"
pres 0.00
ok test-runs-log
fi

if want test-halve; then
cd "$x"
pkp=$tmp/peakproc pks=$tmp/peaksys
mkdir -p "$pkp/self" "$pks/fs/cgroup/fake.scope"
cp "$FORGE_PROC_ROOT/meminfo" "$pkp/meminfo"
echo 0::/fake.scope >"$pkp/self/cgroup"
peak() { if [ -n "$1" ]; then echo "$1" >"$pks/fs/cgroup/fake.scope/memory.peak"; else rm -f "$pks/fs/cgroup/fake.scope/memory.peak"; fi; }
pall() { cat "$tmp/out" "$tmp/err"; }
hr=$tmp/halve
gitinit "$hr"
mkdir -p "$hr/.forge" "$tmp/sdpk"
cat >"$hr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1 ${FORGE_TEST_CPUS-unset} ${CARGO_BUILD_JOBS-unset}" >>"$HL_LOG"
EOF
chmod +x "$hr/t.sh"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n' >"$hr/.forge/TESTING.md"
git -C "$hr" add -A && git -C "$hr" commit -q -m init && git -C "$hr" checkout -q -b side
cat >"$tmp/sdpk/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$2 $3 $4" = "show -p MemoryPeak" ] || exec "${0%/*}/../sd/systemctl" "$@"
echo "$*" >>"$SC_LOG"
[ -z "${SC_FAIL:-}" ] || { echo "Failed to connect to bus" >&2; exit 1; }
echo "${SC_PEAK:-[not set]}"
EOF
chmod +x "$tmp/sdpk/systemctl"
export HL_LOG=$tmp/halve.log
hl() { local s=0; : >"$HL_LOG"; PATH=$tmp/sdpk:$sd:$tmp/cpubin:$PATH NPROC=${HN:-24} FORGE_PROC_ROOT=$pkp FORGE_SYS_ROOT=$pks timeout 60 "$forge" test "$@" "$hr" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
hlog() { paste -sd, "$HL_LOG"; }
retrying() { grep -c "retrying with" "$tmp/err" || true; }
rline() { echo "forge: tests killed for memory: peak $1 of ${3:-4G} budget; retrying with $2 jobs"; }
mem 0 137
peak 3758096384
[ "$(hl --force)" = 0 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] || fail "a full run killed with 137 reruns with FORGE_TEST_CPUS and CARGO_BUILD_JOBS halved from the all-tier 6 on nproc 24 to 3: $(hlog) $(pall)"
grep -qxF "$(rline 3.5G 3)" "$tmp/err" && [ "$(retrying)" = 1 ] || fail "a 137 kill prints on stderr once: $(rline 3.5G 3), the peak read from the attempt's peak file: $(pall)"
! grep -qF "retrying with" "$tmp/out" || fail "the retry line goes to stderr only: $(cat "$tmp/out")"
mem 0 137
peak 3758096384
[ "$(FORGE_TEST_RUNS=3 hl --force)" = 0 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] || fail "FORGE_TEST_RUNS=3 changes nothing: a 137 kill reruns with FORGE_TEST_CPUS and CARGO_BUILD_JOBS halved from the all-tier 6 on nproc 24 to 3: $(hlog) $(pall)"
grep -qxF "$(rline 3.5G 3)" "$tmp/err" && [ "$(retrying)" = 1 ] || fail "a halved 6-job run prints $(rline 3.5G 3): $(pall)"
mem 0 "" 1
peak 3758096384
[ "$(hl --force)" = 0 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] && grep -qxF "$(rline 3.5G 3)" "$tmp/err" || fail "a scope Result of oom-kill with exit 0 also reruns with 3 jobs and prints the peak line: $(hlog) $(pall)"
mem 0 "" 1
peak ""
[ "$(SC_PEAK=2684354560 hl --force)" = 0 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] && grep -qxF "$(rline 2.5G 3)" "$tmp/err" || fail "a scope Result of oom-kill with exit 0 and no peak file takes its peak from systemctl MemoryPeak, 2684354560 bytes as 2.5G: $(hlog) $(pall)"
mem 0 137
peak ""
[ "$(SC_PEAK=2684354560 hl --one a)" = 0 ] && [ "$(hlog)" = "one 2 2,one 1 1" ] || fail "a --one killed with 137 reruns with FORGE_TEST_CPUS halved from the one-tier 2 to 1: $(hlog) $(pall)"
grep -qxF "$(rline 2.5G 1 2097152K)" "$tmp/err" && [ "$(retrying)" = 1 ] || fail "without a peak file the peak comes from systemctl MemoryPeak, 2684354560 bytes as 2.5G: $(pall)"
u=$(units | head -n1)
mp=$(grep -nxF -- "--user show -p MemoryPeak --value $u.scope" "$SC_LOG" | head -n1 | cut -d: -f1)
rf=$(grep -nxF -- "--user reset-failed $u.scope" "$SC_LOG" | head -n1 | cut -d: -f1)
[ -n "$mp" ] && [ -n "$rf" ] && [ "$mp" -lt "$rf" ] || fail "MemoryPeak of the first attempt's scope is read before its reset-failed: $(cat "$SC_LOG")"
mem 0 137
peak 3758096384
[ "$(SC_PEAK=2684354560 hl --one a)" = 0 ] && grep -qxF "$(rline 3.5G 1 2097152K)" "$tmp/err" || fail "the attempt's peak file wins over systemctl MemoryPeak: $(pall)"
mem 0 137
peak ""
[ "$(hl --force)" = 0 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] && grep -qxF "$(rline unknown 3)" "$tmp/err" || fail "a MemoryPeak of [not set] and no peak file print peak unknown: $(hlog) $(pall)"
mem 0 137
peak ""
[ "$(SC_PEAK=infinity hl --one a)" = 0 ] && grep -qxF "$(rline unknown 1 2097152K)" "$tmp/err" || fail "a non-numeric MemoryPeak prints peak unknown: $(pall)"
mem 0 137
peak ""
[ "$(SC_FAIL=1 hl --one a)" = 0 ] && [ "$(hlog)" = "one 2 2,one 1 1" ] && grep -qxF "$(rline unknown 1 2097152K)" "$tmp/err" || fail "a failing systemctl still reruns a 137 kill with 1 job and prints peak unknown: $(hlog) $(pall)"
mem 0 $'137\n137'
peak 3758096384
[ "$(hl --force)" = 75 ] && [ "$(hlog)" = "all 6 6,all 3 3" ] || fail "a second kill after the halved retry exits 75: $(hlog) $(pall)"
[ "$(retrying)" = 1 ] && grep -qxF "$(rline 3.5G 3)" "$tmp/err" && grep -q "^forge: tests killed for memory (budget 4G), log " "$tmp/err" || fail "a second kill prints the retry line once and keeps the exit-75 message: $(pall)"
mem 0 137
peak ""
[ "$(hl --repeat 2 --one a)" = 0 ] && [ "$(sed -n 1,2p "$HL_LOG" | paste -sd,)" = "one 2 2,one 1 1" ] && [ "$(wc -l <"$HL_LOG")" = 3 ] && grep -qxF "forge: repeat passed 2/2" <(pall) || fail "a --repeat iteration killed with 137 reruns with 1 job: $(hlog) $(pall)"
grep -qxF "$(rline unknown 1)" "$tmp/err" && [ "$(retrying)" = 1 ] || fail "a killed --repeat iteration prints the retry line once: $(pall)"
mem 0 3
peak 3758096384
[ "$(hl --force)" = 3 ] && [ "$(hlog)" = "all 6 6" ] && [ "$(retrying)" = 0 ] || fail "another failure is never halved or retried: $(hlog) $(pall)"
mem 0 137
peak ""
[ "$(HN=3 hl --one a)" = 0 ] && [ "$(hlog)" = "one 2 2,one 1 1" ] && grep -qxF "$(rline unknown 1 2097152K)" "$tmp/err" || fail "a --one on nproc 3 killed with 137 reruns with FORGE_TEST_CPUS halved from the one-tier 2 to 1: $(hlog) $(pall)"
mem 0 137
peak ""
[ "$(HN=1 hl --one a)" = 0 ] && [ "$(hlog)" = "one 1 1,one 1 1" ] && grep -qxF "$(rline unknown 1 2097152K)" "$tmp/err" || fail "a --one on nproc 1 killed with 137 reruns with FORGE_TEST_CPUS halved to at least 1: $(hlog) $(pall)"
ok test-halve
fi

if want test-failed; then
fr=$tmp/failed
gitinit "$fr"
mkdir -p "$fr/.forge"
cat >"$fr/t.sh" <<'EOF'
#!/usr/bin/env bash
printf '[%s]' "$@" >>"$T_LOG"
echo >>"$T_LOG"
echo "ran $* ${F_TAG:-}"
if [ -n "${F_RMD:-}" ]; then
  rm -rf "${FORGE_TEST_LOG_DIR:-/nonexistent}"
elif [ -n "${FORGE_TEST_LOG_DIR:-}" ]; then
  mkdir -p "$FORGE_TEST_LOG_DIR/forge" && echo "suite $* ${F_TAG:-}" >"$FORGE_TEST_LOG_DIR/forge/s.log"
  [ -z "${F_LD:-}" ] || echo "$F_LD" >"$FORGE_TEST_LOG_DIR/forge/q.log"
fi
[ -z "${F_SLEEP:-}" ] || sleep "$F_SLEEP"
[ -z "${F_LOAD:-}" ] || echo "$F_LOAD 0.00 0.00 1/100 1" >"$FORGE_PROC_ROOT/loadavg"
if [ -n "${F_SEQ:-}" ]; then
  e=$(head -n1 "$F_SEQ")
  sed -i 1d "$F_SEQ"
  exit "$e"
fi
exit "$(cat "$T_EXIT")"
EOF
chmod +x "$fr/t.sh"
fdoc() { printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh all`' '- Test: `./t.sh one {test}`' "$@" '- Perf log: `./t.sh perf`' >"$fr/.forge/TESTING.md"; }
fdoc '- Changed tests: `./t.sh changed {files}`'
echo a >"$fr/a.txt" && echo '*.log' >"$fr/.gitignore"
git -C "$fr" add -A && git -C "$fr" commit -q -m init && git -C "$fr" checkout -q -b side
fst=$fr/.git/forge-test
fdir=$fst/failed
frlog=$fr/.git/forge-test.log
bump() { echo "$1" >"$fr/n.txt" && git -C "$fr" add -A && git -C "$fr" commit -q -m "$1"; }
frtree() { git -C "$fr" rev-parse HEAD^{tree}; }
frshort() { git -C "$fr" rev-parse --short HEAD^{tree}; }
flog() { echo "$fdir/$(frtree)-$1.log"; }
fdd() { echo "$fdir/$(frtree)-$1.d"; }
fruns() { [ -f "$fst/runs.log" ] && wc -l <"$fst/runs.log" || echo 0; }
loadf() { echo "$1 0.00 0.00 1/100 1" >"$FORGE_PROC_ROOT/loadavg"; }
reruns() { grep -c '^forge: rerun: ' "$tmp/out" || true; }
hot() { PATH=$tmp/cpubin:$PATH NPROC=4 "$@"; }
cd "$fr"
mem
bump one
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a failing full run exits with its code: $(cat "$tmp/out") $(ran)"
[ "$(lastline)" = "forge: tests failed, log $frlog" ] || fail "a failing full run still prints the fail line: $(lastline)"
[ -f "$(flog all)" ] && cmp -s "$(flog all)" "$frlog" || fail "a failing full run copies forge-test.log to <git common dir>/forge-test/failed/<tree>-all.log: $(find "$fst" 2>/dev/null)"
[ -f "$(fdd all)/forge/s.log" ] && cmp -s "$(fdd all)/forge/s.log" "$fr/.git/forge-test.d/forge/s.log" || fail "a failing full run copies forge-test.d/ to failed/<tree>-all.d/: $(find "$fst" 2>/dev/null)"
[ "$(reruns)" = 0 ] || fail "a failing run at load 0.00 does not rerun: $(cat "$tmp/out")"
echo 0 >"$T_EXIT"
n=$(fruns)
touch -d '7 minutes ago' "$(flog all)"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] && [ "$(lastline)" = "forge: tests passed ($(frshort))" ] || fail "a rerun of a tree whose full run failed 7 min ago runs at once: $(cat "$tmp/out") $(ran)"
! grep -qF "rerun with --force" "$tmp/out" && [ "$(fruns)" = $((n + 1)) ] && [ -f "$fst/$hid/$(frtree)" ] || fail "a rerun of a failed tree is never refused, appends its runs.log line and records its stamp: $(cat "$tmp/out") $(cat "$fst/runs.log")"
[ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a pass removes the tree's failed log and .d copy: $(find "$fdir")"
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(F_TAG=forced code "$forge" test --force)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "--force reruns a stamped tree: $(cat "$tmp/out") $(ran)"
cmp -s "$(flog all)" "$frlog" && grep -qxF "ran all forced" "$(flog all)" && [ ! -e "$fst/$hid/$(frtree)" ] || fail "a failing --force run of a stamped tree writes a failed log and drops the pass stamp: $(cat "$(flog all)") $(find "$fst")"
echo stale >"$(fdd all)/stale.log"
: >"$T_LOG"
[ "$(F_TAG=again code "$forge" test)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a plain run of a tree that just failed reruns it, not refused or cached: $(cat "$tmp/out") $(ran)"
cmp -s "$(flog all)" "$frlog" && grep -qxF "ran all again" "$(flog all)" || fail "a failing rerun replaces the failed log: $(cat "$(flog all)")"
[ ! -e "$(fdd all)/stale.log" ] && [ "$(cat "$(fdd all)/forge/s.log")" = "suite all again" ] || fail "a failing rerun replaces the older failed/<tree>-all.d/ copy: $(find "$(fdd all)")"
bump endload
printf '3\n0\n' >"$tmp/seq"
n=$(fruns)
: >"$T_LOG"
[ "$(F_SEQ=$tmp/seq F_LOAD=4.00 hot code "$forge" test)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "a failing full run whose end load 4.00 is at nproc 4 reruns once and passes: $(cat "$tmp/out") $(ran)"
grep -qxF "forge: rerun: load 4.00 >= nproc 4" "$tmp/out" && [ "$(reruns)" = 1 ] && [ "$(lastline)" = "forge: tests passed ($(frshort))" ] && [ -f "$fst/$hid/$(frtree)" ] || fail "a passing rerun prints the rerun line, stamps the tree and ends with the pass line: $(cat "$tmp/out")"
[ "$(grep -c '^ran all' "$frlog")" = 2 ] && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "the rerun appends to the same forge-test.log and its pass leaves no failed log: $(cat "$frlog") $(find "$fdir" 2>/dev/null)"
[ "$(fruns)" = $((n + 2)) ] && [ "$(tail -n2 "$fst/runs.log" | awk '{print $3, $4, $7}' | paste -sd,)" = "all $(frtree) 3,all $(frtree) 0" ] || fail "runs.log holds one line per attempt: $(cat "$fst/runs.log")"
bump startload
loadf 9.00
printf '3\n0\n' >"$tmp/seq"
: >"$T_LOG"
[ "$(F_SEQ=$tmp/seq F_LOAD=0.00 hot code "$forge" test)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] && grep -qxF "forge: rerun: load 9.00 >= nproc 4" "$tmp/out" || fail "a failing run whose start load 9.00 is above nproc 4 reruns, naming the higher load: $(cat "$tmp/out") $(ran)"
bump bothload
loadf 9.00
echo 3 >"$T_EXIT"
n=$(fruns)
: >"$T_LOG"
[ "$(F_TAG=hot hot code "$forge" test)" = 3 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] && [ "$(reruns)" = 1 ] || fail "a failing rerun never reruns, even at load 9.00: $(cat "$tmp/out") $(ran)"
[ "$(lastline)" = "forge: tests failed, log $frlog" ] && [ "$(grep -c '^ran all hot' "$(flog all)")" = 2 ] && [ ! -e "$fst/$hid/$(frtree)" ] || fail "a failing rerun fails as before with the failed log copy of both attempts: $(cat "$tmp/out") $(cat "$(flog all)" 2>&1)"
[ "$(fruns)" = $((n + 2)) ] || fail "a failing rerun writes one runs.log line per attempt: $(cat "$fst/runs.log")"
bump lowload
loadf 3.99
: >"$T_LOG"
[ "$(hot code "$forge" test)" = 3 ] && [ "$(ran)" = "[all]" ] && [ "$(reruns)" = 0 ] || fail "a failure at load 3.99 below nproc 4 does not rerun: $(cat "$tmp/out") $(ran)"
for v in 9.0 x9.00 ''; do
  bump "badload $v"
  if [ -n "$v" ]; then loadf "$v"; else rm -f "$FORGE_PROC_ROOT/loadavg"; fi
  : >"$T_LOG"
  [ "$(hot code "$forge" test)" = 3 ] && [ "$(ran)" = "[all]" ] && [ "$(reruns)" = 0 ] || fail "a malformed or missing loadavg '$v' counts as below nproc, so no rerun: $(cat "$tmp/out") $(ran)"
done
bump timeout
loadf 9.00
fdoc '- Changed tests: `./t.sh changed {files}`' '- Timeout: `1`'
: >"$T_LOG"
[ "$(F_SLEEP=5 FORGE_TEST_MIN_SECS=1 hot code "$forge" test)" = 124 ] && [ "$(ran)" = "[all]" ] && [ "$(reruns)" = 0 ] || fail "a 124 timeout at load 9.00 does not rerun: $(cat "$tmp/out") $(ran)"
fdoc '- Changed tests: `./t.sh changed {files}`'
: >"$T_LOG"
[ "$(hot code "$forge" test --one a)" = 3 ] && [ "$(ran)" = "[one][a]" ] && [ "$(reruns)" = 0 ] || fail "a failing --one at load 9.00 never reruns: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(hot code "$forge" test --repeat 2 --one a)" = 3 ] && [ "$(ran)" = "[one][a]" ] && [ "$(reruns)" = 0 ] || fail "a failing --repeat at load 9.00 never reruns: $(cat "$tmp/out") $(ran)"
loadf 0.00
bump five
echo 5 >"$T_EXIT"
[ "$(code "$forge" test)" = 1 ] && [ -f "$(flog all)" ] || fail "a command exiting 5 exits 1 and writes a failed log: $(cat "$tmp/out") $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose command exited 5 reruns at once: $(cat "$tmp/out") $(ran)"
bump resource
echo 75 >"$T_EXIT"
[ "$(code "$forge" test)" = 1 ] && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a command exiting 75 writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose command exited 75 is rerun: $(cat "$tmp/out") $(ran)"
bump killed
echo 137 >"$T_EXIT"
mem
loadf 9.00
[ "$(PATH=$sd:$PATH hot code "$forge" test)" = 75 ] && grep -q "^forge: tests killed for memory" "$tmp/out" && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a memory kill writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
[ "$(reruns)" = 0 ] && [ "$(ran | paste -sd,)" = "[all],[all]" ] || fail "a memory kill at load 9.00 does not rerun beyond its halved retry: $(cat "$tmp/out") $(ran)"
loadf 0.00
echo 0 >"$T_EXIT"
mem
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a memory-killed tree is rerun: $(cat "$tmp/out") $(ran)"
bump nocmd
echo 127 >"$T_EXIT"
[ "$(code "$forge" test)" = 127 ] && [ "$(lastline)" = "forge: tests failed, log $frlog" ] && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a command exiting 127 writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose command exited 127 is rerun: $(cat "$tmp/out") $(ran)"
bump signal
[ "$(code "$forge" test)" = 0 ] && [ -f "$fst/$hid/$(frtree)" ] || fail "a pass stamps the tree before its signal kill: $(cat "$tmp/out")"
echo 137 >"$T_EXIT"
loadf 9.00
: >"$T_LOG"
[ "$(hot code "$forge" test --force)" = 137 ] && [ "$(lastline)" = "forge: tests failed, log $frlog" ] && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "an uncapped command exiting 137 writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
[ "$(reruns)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "an uncapped command exiting 137 at load 9.00 does not rerun: $(cat "$tmp/out") $(ran)"
loadf 0.00
[ ! -e "$fst/$hid/$(frtree)" ] || fail "an environment failure still removes the tree's pass stamp: $(find "$fst")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose command exited 137 is rerun, not cached: $(cat "$tmp/out") $(ran)"
bump enospc
echo 1 >"$T_EXIT"
[ "$(F_TAG='No space left on device' code "$forge" test)" = 1 ] && grep -qF 'No space left on device' "$frlog" && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a failure whose log shows No space left on device writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose run hit ENOSPC is rerun: $(cat "$tmp/out") $(ran)"
bump edquot
echo 1 >"$T_EXIT"
[ "$(F_LD='Disk quota exceeded' code "$forge" test)" = 1 ] && ! grep -qF 'Disk quota exceeded' "$frlog" && grep -qF 'Disk quota exceeded' "$fr/.git/forge-test.d/forge/q.log" && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a failure with Disk quota exceeded in a FORGE_TEST_LOG_DIR file writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a tree whose run hit EDQUOT is rerun: $(cat "$tmp/out") $(ran)"
bump plain
echo 1 >"$T_EXIT"
[ "$(code "$forge" test)" = 1 ] && [ -f "$(flog all)" ] && cmp -s "$(flog all)" "$frlog" || fail "a plain failure exiting 1 writes a failed log: $(cat "$tmp/out") $(find "$fdir")"
cp "$(flog all)" "$tmp/plain.log" && cp "$(fdd all)/forge/s.log" "$tmp/plain-s.log"
echo 127 >"$T_EXIT"
[ "$(F_TAG=env code "$forge" test --force)" = 127 ] && cmp -s "$(flog all)" "$tmp/plain.log" && cmp -s "$(fdd all)/forge/s.log" "$tmp/plain-s.log" || fail "an environment failure leaves an older failed log of the same tree as it is: $(cat "$tmp/out") $(cat "$(flog all)")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] && [ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a tree whose plain run exited 1 reruns at once and its pass removes the failed log: $(cat "$tmp/out") $(ran) $(find "$fdir")"
bump slot
exec 4>>"$fr/.git/forge-test.lock"
flock 4
echo "pid 1 in $fr" >"$fr/.git/forge-test.lock"
echo 3 >"$T_EXIT"
: >"$T_LOG"
rm -f "$tmp/now"
[ "$(PATH=$tmp/fake:$PATH FORGE_TEST_SLOT_WAIT=1 code timeout 20 "$forge" test)" = 75 ] && grep -q "^forge: gave up waiting for the test run in " "$tmp/out" && [ -z "$(ran)" ] || fail "a worktree-lock wait past FORGE_TEST_SLOT_WAIT exits 75: $(cat "$tmp/out") $(ran)"
exec 4>&-
[ ! -e "$(flog all)" ] && [ ! -e "$(fdd all)" ] || fail "a worktree-lock give-up writes no failed log: $(find "$fdir")"
fdoc '- Changed tests: `./t.sh changed {files}`'
git -C "$fr" commit -q --allow-empty -am "changed tier"
: >"$T_LOG"
[ "$(F_RMD=1 code "$forge" test --changed)" = 3 ] && [[ $(ran) == "[changed]"* ]] || fail "a failing changed run exits with its code: $(cat "$tmp/out") $(ran)"
[ -f "$(flog changed)" ] && cmp -s "$(flog changed)" "$frlog" && [ ! -e "$(flog all)" ] || fail "a failing changed run writes failed/<tree>-changed.log: $(find "$fdir")"
[ ! -e "$(fdd changed)" ] || fail "a failing run without a forge-test.d/ writes no .d copy: $(find "$fdir")"
echo 0 >"$T_EXIT"
touch -d '12 minutes ago' "$(flog changed)"
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 0 ] && [[ $(ran) == "[changed]"* ]] && [ ! -e "$(flog changed)" ] || fail "a changed rerun of a tree whose changed run failed 12 min ago runs at once: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(ran)" = "[all]" ] || fail "a changed pass leaves the full tier to run: $(cat "$tmp/out") $(ran)"
fdoc
git -C "$fr" commit -q -am "no Changed line"
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --changed)" = 3 ] && [ "$(ran)" = "[all]" ] && [ -f "$(flog all)" ] && [ ! -e "$(flog changed)" ] || fail "a failing --changed run without a Changed tests line is keyed all: $(cat "$tmp/out") $(ran) $(find "$fdir")"
echo 0 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --one a)" = 0 ] && [ "$(ran)" = "[one][a]" ] && [ -f "$(flog all)" ] || fail "--one runs on a tree with an all-keyed failure and leaves its failed log: $(cat "$tmp/out") $(ran)"
: >"$T_LOG"
[ "$(code "$forge" test --repeat 2 --one a)" = 0 ] && [ "$(ran | paste -sd,)" = "[one][a],[one][a]" ] || fail "--repeat runs on a tree with an all-keyed failure: $(cat "$tmp/out") $(ran)"
nf=$(find "$fdir" | wc -l)
echo 3 >"$T_EXIT"
[ "$(code "$forge" test --one a)" = 3 ] && [ "$(code "$forge" test --repeat 2 --one a)" = 3 ] && [ "$(find "$fdir" | wc -l)" = "$nf" ] && [ ! -e "$(flog one)" ] || fail "a failing --one or --repeat writes no failed log: $(cat "$tmp/out") $(find "$fdir")"
old=$fdir/$(printf 'a%.0s' {1..40})-all
new=$fdir/$(printf 'b%.0s' {1..40})-all
mkdir -p "$old.d" "$new.d" && echo old >"$old.log" && echo old >"$old.d/s.log" && echo new >"$new.log" && echo new >"$new.d/s.log"
touch -d '40 minutes ago' "$old.log" "$old.d/s.log" "$old.d" "$(flog all)"
: >"$T_LOG"
[ "$(code "$forge" test)" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a failing run of a tree with an old failed log exits with its code: $(cat "$tmp/out") $(ran)"
[ ! -e "$old.log" ] && [ ! -e "$old.d" ] || fail "failed logs and .d copies older than 30 min are pruned: $(find "$fdir")"
[ -f "$new.log" ] && [ -f "$new.d/s.log" ] || fail "failed logs younger than 30 min are kept: $(find "$fdir")"
[ -n "$(find "$(flog all)" -mmin -5)" ] && cmp -s "$(flog all)" "$frlog" || fail "the rerun's failure writes a fresh failed log: $(find "$fdir")"
git -C "$fr" worktree add -q "$tmp/failed-wt" -b failed-wt
echo w >"$tmp/failed-wt/w.txt" && git -C "$tmp/failed-wt" add -A && git -C "$tmp/failed-wt" commit -q -m wt
wtree=$(git -C "$tmp/failed-wt" rev-parse HEAD^{tree})
: >"$T_LOG"
[ "$(code "$forge" test "$tmp/failed-wt")" = 3 ] && [ "$(ran)" = "[all]" ] || fail "a failing run in a linked worktree exits with its code: $(cat "$tmp/out") $(ran)"
[ -f "$fdir/$wtree-all.log" ] && cmp -s "$fdir/$wtree-all.log" "$fr/.git/worktrees/failed-wt/forge-test.log" || fail "a linked worktree's failure writes its failed log under the common dir: $(find "$fdir")"
git -C "$fr" worktree remove --force "$tmp/failed-wt"
echo 0 >"$T_EXIT"
bump carry
[ "$(code "$forge" test)" = 0 ] && [ -f "$fst/$hid/$(frtree)" ] || fail "a pass stamps the tree a docs-only change carries from: $(cat "$tmp/out")"
echo d >"$fr/notes.md" && git -C "$fr" add -A && git -C "$fr" commit -q -m docs
echo 3 >"$T_EXIT"
: >"$T_LOG"
[ "$(code "$forge" test --force)" = 3 ] && [ "$(ran)" = "[all]" ] && [ -f "$(flog all)" ] || fail "a failing --force run of a docs-only child of a stamped tree writes a failed log: $(cat "$tmp/out") $(ran) $(find "$fdir")"
echo 0 >"$T_EXIT"
n=$(fruns)
: >"$T_LOG"
[ "$(code "$forge" test)" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(frshort)), cached from $(git -C "$fr" rev-parse --short HEAD~1^{tree}) (docs-only change)" ] || fail "a plain run of a docs-only child after its failing --force run is carried, not refused: $(cat "$tmp/out")"
[ -z "$(ran)" ] && [ "$(fruns)" = "$n" ] || fail "a carried docs-only run runs nothing and appends no runs.log line: $(cat "$tmp/out") $(ran)"
mem
cd "$x"
ok test-failed
fi

if want_any test-base test-base-pass; then
bb=$tmp/base
gitinit "$bb"
mkdir -p "$bb/.forge" "$bb/tests" "$bb/fails"
cat >"$bb/t.sh" <<'EOF'
#!/usr/bin/env bash
case $1 in
  one)
    echo "one $2 $(pwd -P)" >>"$BT_LOG"
    echo "ran one $2"
    [ "${BT_SLOW:-}" != "$2" ] || exec sleep 600
    [ -f "tests/$2.t" ] && [ ! -f "fails/$2" ]
    ;;
  *)
    echo "$1 $(pwd -P)" >>"$BT_LOG"
    [ -z "${BT_SLEEP:-}" ] || exec sleep 600
    [ -z "${BT_EDIT:-}" ] || sed -i 's#^- Failed tests:.*#- Failed tests: `false`#' "$BT_EDIT"
    for i in ${BT_FAIL:-}; do echo "FAIL $i tests/$i.t"; done
    [ -z "${BT_FAIL:-}" ] || exit "${BT_EXIT:-3}"
    ;;
esac
EOF
cat >"$bb/ft.sh" <<'EOF'
#!/usr/bin/env bash
echo "ft $(pwd -P) $1 ${FORGE_TEST_LOG_DIR:-}" >>"$BT_LOG"
if [ -n "${BT_FT_OUT+x}" ]; then printf '%s' "$BT_FT_OUT"; else awk '$1=="FAIL"{print $2, $3}' "$1"; fi
exit "${BT_FT_EXIT:-0}"
EOF
chmod +x "$bb/t.sh" "$bb/ft.sh"
bdoc() { printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh all`' '- Test: `./t.sh one {test}`' '- Timeout: `1`' "$@" >"$bb/.forge/TESTING.md"; git -C "$bb" add -A && git -C "$bb" commit -q --allow-empty -m doc; }
bch='- Changed tests: `./t.sh changed {files}`'
bft='- Failed tests: `./ft.sh {log}`'
echo a >"$bb/tests/a.t" && echo b >"$bb/tests/b.t" && : >"$bb/fails/a" && printf '%s\n' '*.log' '*.ign' >"$bb/.gitignore"
bdoc "$bch" "$bft"
git -C "$bb" checkout -q -b base2 && : >"$bb/fails/b" && git -C "$bb" add -A && git -C "$bb" commit -q -m "b fails"
git -C "$bb" checkout -q -b side && echo c >"$bb/tests/c.t" && echo s >"$bb/src.txt" && git -C "$bb" add -A && git -C "$bb" commit -q -m head
export BT_LOG=$tmp/bt.log
bw=$bb/.git/forge-test/base
bfd=$bb/.git/forge-test/failed
bfl=$bb/.git/forge-test/base-fails
blog=$bb/.git/forge-test.log
bline="forge: tests failed, log $blog"
brun() { local s=0; : >"$BT_LOG"; timeout -k 5 120 "$forge" test --changed --force "$@" "$bb" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
ball() { echo "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err") ran: $(paste -sd, "$BT_LOG") base-fails: $(ls "$bfl" 2>/dev/null | paste -sd,)"; }
btree() { git -C "$bb" rev-parse HEAD^{tree}; }
fi

if want test-base; then
cd "$x"
bones() { { grep '^one ' "$BT_LOG" || true; } | cut -d' ' -f2 | paste -sd' '; }
bnfl() { find "$bfl" -type f 2>/dev/null | wc -l; }
bpre() {
  local l
  l=$(tail -n2 "$tmp/err" | head -n1)
  [ "$(tail -n1 "$tmp/err")" = "$bline" ] && { [ "$l" = "forge: pre-existing failures on $(git -C "$bb" rev-parse --short "$1"): $2" ] || [ "$l" = "forge: pre-existing failures on $(git -C "$bb" rev-parse --short "$1^{tree}"): $2" ]; }
}
bnone() { [ "$(tail -n1 "$tmp/err")" = "${1:-$bline}" ] && ! grep -qF "pre-existing" "$tmp/out" "$tmp/err" && [ -z "$(bones)" ]; }
[ "$(BT_FAIL='a b' brun --base main)" = 3 ] && bpre main a || fail "a --changed run failing on a and b, where only a fails on the merge base, exits 3 and prints the pre-existing failures line naming a right before the failure line: $(ball)"
[ "$(bones)" = "a b" ] && [ -z "$(awk -v w="$bw" '$1=="one" && $3 != w' "$BT_LOG")" ] && [ ! -e "$bb/.claude" ] || fail "the base check runs each failing id through the Test line in the base worktree $bw itself, with no _snap snapshot: $(ball)"
[ "$(git -C "$bw" rev-parse HEAD 2>/dev/null)" = "$(git -C "$bb" rev-parse main)" ] && ! git -C "$bw" symbolic-ref -q HEAD >/dev/null 2>&1 || fail "the base worktree is detached at the merge base: $(git -C "$bb" worktree list)"
sed 's#/$##' "$BT_LOG" | grep -qxF "ft $bb $bfd/$(btree)-changed.log $bfd/$(btree)-changed.d" || fail "the Failed tests command runs from the worktree top $bb over failed/<tree>-changed.log with FORGE_TEST_LOG_DIR=failed/<tree>-changed.d: $(ball)"
[ ! -e "$bb/.git/forge-test/$hid/changed/$(btree)" ] && [ ! -e "$bb/.git/forge-test/$hid/$(btree)" ] || fail "a run with a head failure records no stamp: $(find "$bb/.git/forge-test/$hid" -type f 2>/dev/null)"
[ -f "$bfd/$(btree)-changed.log" ] && [ -d "$bfd/$(btree)-changed.d" ] || fail "a run with a head failure keeps the failed-rerun record: $(find "$bfd" 2>/dev/null)"
bf1=$(ls "$bfl" 2>/dev/null || true)
[[ $bf1 =~ ^[0-9a-f]{7,64}-1\.log$ ]] && grep -qxF "ran one a" "$bfl/$bf1" && grep -qxF "ran one b" "$bfl/$bf1" || fail "the base runs' output is copied to <git common dir>/forge-test/base-fails/<base tree>-1.log: $(ball)"
[ "$(BT_FAIL='a c' brun --base main)" = 3 ] && bpre main a || fail "an id whose file is missing at the merge base is a head failure, so a run failing on a and c lists only a: $(ball)"
[ "$(bones)" = a ] || fail "an id whose file is missing at the merge base is not run there: $(ball)"
[ "$(bnfl)" = 2 ] && [ -f "$bfl/${bf1%-1.log}-2.log" ] || fail "a second base check on the same base writes base-fails/<base tree>-2.log: $(ball)"
: >"$bw/keep.ign" && echo junk >"$bw/junk.txt" && rm -f "$bw/fails/a"
[ "$(BT_FAIL='a b c' brun --base base2)" = 3 ] && bpre base2 'a b' || fail "a run against another merge base reuses the base worktree, restores its tracked files and lists a and b: $(ball)"
[ "$(git -C "$bw" rev-parse HEAD)" = "$(git -C "$bb" rev-parse base2)" ] || fail "the reused base worktree is detached at the new merge base: $(git -C "$bb" worktree list)"
[ -e "$bw/keep.ign" ] && [ ! -e "$bw/junk.txt" ] && [ -f "$bw/fails/a" ] || fail "the base worktree is reused with checkout --force and clean -fd, not re-added: $(ls -a "$bw")"
[ "$(git -C "$bb" worktree list --porcelain | grep -cxF "worktree $bw")" = 1 ] && [ "$(bones)" = "a b" ] || fail "one base worktree serves both runs: $(git -C "$bb" worktree list) $(ball)"
[ "$(BT_FAIL='a b' BT_SLOW=b FORGE_TEST_MIN_SECS=2 brun --base base2)" = 3 ] && bpre base2 a || fail "an id whose base run timed out is unjudged, so the run stays failed with exit 3 listing only a: $(ball)"
n=$(bnfl)
for c in 5:1 127:127; do
  [ "$(BT_FAIL='a b' BT_EXIT=${c%:*} brun --base main)" = "${c#*:}" ] && bnone || fail "a changed run exiting ${c%:*} skips the base check and exits ${c#*:} as today: $(ball)"
done
[ "$(BT_FAIL='a b' BT_SLEEP=1 FORGE_TEST_MIN_SECS=2 brun --base main)" = 124 ] && bnone "forge: tests timed out after 1 min (limit from - Timeout: in $bb/.forge/TESTING.md), log $blog" || fail "a timed-out changed run skips the base check and exits 124 as today: $(ball)"
mem
[ "$(BT_FAIL='a b' BT_EXIT=137 PATH=$sd:$PATH brun --base main)" = 75 ] && [[ $(tail -n1 "$tmp/err") == "forge: tests killed for memory (budget "*"), log $blog" ]] && ! grep -qF "pre-existing" "$tmp/err" && [ -z "$(bones)" ] || fail "a memory-killed changed run skips the base check and exits 75 as today: $(ball)"
mem
[ "$(BT_FAIL='a b' BT_FT_EXIT=2 brun --base main)" = 3 ] && bnone || fail "a failing Failed tests command skips the base check: $(ball)"
[ "$(BT_FAIL='a b' BT_FT_OUT= brun --base main)" = 3 ] && bnone || fail "an empty Failed tests output skips the base check: $(ball)"
[ "$(BT_FAIL='a b' BT_FT_OUT=$'a tests/a.t\nb\n' brun --base main)" = 3 ] && bnone || fail "a Failed tests line without a space skips the base check: $(ball)"
[ "$(BT_FAIL='a b x1 x2 x3 x4 x5 x6 x7 x8 x9' brun --base main)" = 3 ] && bnone || fail "more than 10 failing ids skip the base check: $(ball)"
bdoc "$bch"
[ "$(BT_FAIL='a b' brun --base main)" = 3 ] && bnone || fail "a repo without a Failed tests line skips the base check: $(ball)"
bdoc "$bft"
[ "$(BT_FAIL='a b' brun --base main)" = 3 ] && bnone && [ -f "$bfd/$(btree)-all.log" ] || fail "a --changed run that fell back to All tests skips the base check: $(ball)"
[ "$(bnfl)" = "$n" ] || fail "a skipped base check writes no base-fails log: $(ball)"
[ ! -e "$bb/.forge/concerns.json" ] || fail "a failed run opens no concern: $(cat "$bb/.forge/concerns.json")"
bdoc "$bch" "$bft"
git -C "$bb" checkout -q -b case && echo new >>"$bb/tests/a.t" && git -C "$bb" commit -q -am "new case in a" || fail "cannot add a case to tests/a.t"
[ "$(BT_FAIL=a:new BT_FT_OUT='a:new tests/a.t' brun --base main)" = 3 ] && bnone || fail "an id whose file the branch changed, such as a case it added to an existing file, is a head failure, never run on the merge base: $(ball)"
[ "$(bnfl)" = "$n" ] || fail "a base check with only changed-file ids writes no base-fails log: $(ball)"
git -C "$bb" checkout -q side || fail "cannot return to side"
echo "9.00 0.00 0.00 1/100 1" >"$FORGE_PROC_ROOT/loadavg"
[ "$(BT_FAIL='a b' PATH=$tmp/cpubin:$PATH NPROC=4 brun --base main)" = 3 ] && bpre main a || fail "a failing changed run at load 9.00 whose rerun fails runs the base check and exits 3: $(ball)"
[ "$(cut -d' ' -f1 "$BT_LOG" | paste -sd,)" = "changed,changed,ft,one,one" ] && [ "$(grep -cxF "forge: rerun: load 9.00 >= nproc 4" "$tmp/err")" = 1 ] || fail "a failing changed run at load 9.00 reruns once and runs the base check after the rerun: $(ball)"
echo "0.00 0.00 0.00 1/100 1" >"$FORGE_PROC_ROOT/loadavg"
ok test-base
fi

if want test-base-pass; then
cd "$x"
bdoc "$bch" "$bft"
bfr=$tmp/bfr bfs=$XDG_STATE_HOME/forge/bfr
mkdir -p "$bfr/.forge/tracks" "$bfs/phases/07-base" "$bfs/phases/08-base/events.jsonl"
bev=$bfs/phases/07-base/events.jsonl
bshort() { git -C "$bb" rev-parse --short "$1"; }
bfls() { ls "$bfl" 2>/dev/null || true; }
bf0=$(bfls)
bt0=$(btree)
[ "$(BT_FAIL='a b' FORGE_ROOT=$bfr FORGE_PHASE=07 brun --base base2)" = 0 ] || fail "a --changed run whose every failing id also fails on the merge base exits 0: $(ball)"
pl="forge: tests passed ($(git -C "$bb" rev-parse --short "$bt0")), pre-existing failures on"
[ "$(tail -n1 "$tmp/out")" = "$pl $(bshort base2): a b" ] || [ "$(tail -n1 "$tmp/out")" = "$pl $(bshort "base2^{tree}"): a b" ] || fail "the all-pre-existing pass prints the pass line naming the ids in Failed tests order: $(ball)"
! grep -qF "tests failed" "$tmp/err" || fail "the all-pre-existing pass prints no failure line: $(ball)"
grep -qxF "$(git -C "$bb" rev-parse base2)" "$bb/.git/forge-test/$hid/changed/$bt0" && [ ! -e "$bb/.git/forge-test/$hid/$bt0" ] || fail "the all-pre-existing pass writes the changed stamp for the head tree keyed by the merge base: $(find "$bb/.git/forge-test/$hid" -type f 2>/dev/null)"
[ "$(code "$forge" test --passed --changed "$bb")" = 0 ] || fail "forge test --passed --changed accepts the all-pre-existing pass: $(cat "$tmp/out")"
[ ! -e "$bfd/$bt0-changed.log" ] && [ ! -e "$bfd/$bt0-changed.d" ] || fail "the all-pre-existing pass removes the failed-rerun record: $(find "$bfd" 2>/dev/null)"
bdl=$(comm -13 <(printf '%s\n' "$bf0" | sort) <(bfls | sort))
[ "$(wc -l <<<"$bdl")" = 1 ] && [[ $bdl == "$(git -C "$bb" rev-parse "base2^{tree}")-"*.log ]] && grep -qxF "ran one a" "$bfl/$bdl" && grep -qxF "ran one b" "$bfl/$bdl" || fail "the all-pre-existing pass keeps its base runs in a durable base-fails/<base tree>-<n>.log: $(ball)"
[ -f "$bev" ] && [ "$(wc -l <"$bev")" = 1 ] || fail "the all-pre-existing pass appends one event to the FORGE_PHASE phase's events.jsonl: $(cat "$bev" 2>/dev/null) $(ball)"
jq -e --arg p "$bfl/$bdl" --arg c "$(bshort base2)" --arg t "$(bshort "base2^{tree}")" '.step == "base-fails" and (.message | test("(^|[ :])a[ ,]+b($|[ ,;.)])")) and (.message | contains($p)) and (.message | contains("base2")) and ((.message | contains($c)) or (.message | contains($t)))' "$bev" >/dev/null ||
  fail "the base-fails event names the ids, the base short and ref and the durable log path: $(cat "$bev")"
bc=$bb/.forge/concerns.json
bpc() { jq -c --arg p "Pre-existing test failure: $1" '[.concerns[] | select(.status == "open" and (.text | startswith($p)))]' "$bc"; }
bopen() { jq '[.concerns[] | select(.status == "open")] | length' "$bc"; }
bcon() {
  local x
  x=$(bpc "$1") && [ "$(jq length <<<"$x")" = 1 ] &&
    jq -e --arg f "tests/$1.t" --arg c "Pre-existing test failure: $1 fails on base tree $(bshort "$2") ($2); log $3" --arg t "Pre-existing test failure: $1 fails on base tree $(bshort "$2^{tree}") ($2); log $3" \
      '.[0] | .area == "test" and .severity == "medium" and .files == [$f] and (.text == $c or .text == $t)' <<<"$x" >/dev/null
}
bcall() { echo "concerns: $(cat "$bc" 2>/dev/null) $(ball)"; }
for i in a b; do
  bcon "$i" base2 "$bfl/$bdl" || fail "the all-pre-existing pass opens one concern for $i in the main checkout's concerns.json, area test, severity medium, file tests/$i.t, text naming $i, the base tree, base2 and the durable log: $(bcall)"
done
[ "$(bopen)" = 2 ] || fail "the all-pre-existing pass opens exactly one concern per pre-existing id: $(bcall)"
bt1=$(btree)
[ "$(BT_FAIL=a FORGE_ROOT=$bfr FORGE_PHASE=08 brun --base main)" = 0 ] && grep -qF "$bfs/phases/08-base/events.jsonl" "$tmp/err" && [[ $(tail -n1 "$tmp/out") == "forge: tests passed ("*"), pre-existing failures on "*": a" ]] || fail "an event write failure warns on stderr and the all-pre-existing pass stands: $(ball)"
grep -qxF "$(git -C "$bb" rev-parse main)" "$bb/.git/forge-test/$hid/changed/$bt1" || fail "the pass after an event write failure still writes the changed stamp: $(find "$bb/.git/forge-test/$hid" -type f 2>/dev/null)"
[ "$(bopen)" = 2 ] && [ "$(jq '.concerns | length' "$bc")" = 2 ] || fail "a pass against another base with a open concern for a adds no second concern: $(bcall)"
[ "$(BT_FAIL='a b' FORGE_ROOT=$bfr FORGE_PHASE=07 brun --base base2)" = 0 ] || fail "a second all-pre-existing pass on the same failures exits 0: $(bcall)"
[ "$(jq '.concerns | length' "$bc")" = 2 ] && bcon a base2 "$bfl/$bdl" && bcon b base2 "$bfl/$bdl" || fail "a second run on the same failures adds no second concern: $(bcall)"
jq '(.concerns[] | select(.text | startswith("Pre-existing test failure: a"))).status = "resolved"' "$bc" >"$bc.new" && mv "$bc.new" "$bc" && git -C "$bb" commit -q -m resolve -- "$bc" || fail "cannot resolve the concern for a"
bf0=$(bfls)
[ "$(BT_FAIL='a b' FORGE_ROOT=$bfr FORGE_PHASE=07 brun --base base2)" = 0 ] || fail "an all-pre-existing pass after resolving the concern for a exits 0: $(bcall)"
bdl2=$(comm -13 <(printf '%s\n' "$bf0" | sort) <(bfls | sort))
[ "$(jq '.concerns | length' "$bc")" = 3 ] && bcon a base2 "$bfl/$bdl2" && bcon b base2 "$bfl/$bdl" && [ "$(bopen)" = 2 ] || fail "a resolved concern for a does not suppress a new open one, and b keeps its single open concern: $(bcall)"
printf '{\n' >"$bc" && git -C "$bb" commit -q -m broken -- "$bc" || fail "cannot break concerns.json"
bt2=$(btree)
nev=$(wc -l <"$bev")
[ "$(BT_FAIL='a b' FORGE_ROOT=$bfr FORGE_PHASE=07 brun --base base2)" = 0 ] || fail "a failing concern add leaves the all-pre-existing pass exiting 0: $(bcall)"
[ "$(tail -n1 "$tmp/out")" = "forge: tests passed ($(bshort "$bt2")), pre-existing failures on $(bshort base2): a b" ] || [ "$(tail -n1 "$tmp/out")" = "forge: tests passed ($(bshort "$bt2")), pre-existing failures on $(bshort "base2^{tree}"): a b" ] || fail "a failing concern add leaves the pass line: $(bcall)"
grep -qxF "$(git -C "$bb" rev-parse base2)" "$bb/.git/forge-test/$hid/changed/$bt2" || fail "a failing concern add leaves the changed stamp: $(find "$bb/.git/forge-test/$hid" -type f 2>/dev/null)"
[ "$(wc -l <"$bev")" = $((nev + 1)) ] && [ "$(tail -n1 "$bev" | jq -r .step)" = base-fails ] || fail "a failing concern add leaves the base-fails event: $(cat "$bev")"
for i in a b; do
  grep -E "^forge: warning: (.*[^[:alnum:]_])?$i([^[:alnum:]_]|$)" "$tmp/err" >/dev/null || fail "a failing concern add prints a forge: warning: line on stderr naming $i: $(bcall)"
done
[ "$(cat "$bc")" = "{" ] || fail "a failing concern add leaves the invalid concerns.json as it was: $(bcall)"
pfc=$(git -C "$bb" rev-parse HEAD)
echo fix >>"$bb/src.txt" && git -C "$bb" commit -q -am fix || fail "cannot commit a fix"
bt3=$(btree)
[ "$(BT_FAIL='a b' brun --base "$pfc")" = 0 ] || fail "a scoped fix rerun whose every failing id also fails on the pre-fix commit exits 0: $(bcall)"
[ "$(cat "$bb/.git/forge-test/$hid/changed/$bt3")" = "chain $bt2" ] || fail "an all-pre-existing pass over a stamped pre-fix tree records chain <pre-fix tree>: $(cat "$bb/.git/forge-test/$hid/changed/$bt3" 2>/dev/null)"
rm "$bb/.git/forge-test/$hid/changed/$bt2"
[ "$(code "$forge" test --passed --changed "$bb")" = 1 ] || fail "--passed --changed rejects an all-pre-existing chained pass once the pre-fix stamp is gone: $(cat "$tmp/out")"
cp "$bb/.forge/TESTING.md" "$tmp/bdoc.md"
[ "$(BT_FAIL='a b' BT_EDIT=$bb/.forge/TESTING.md brun --base "$pfc")" = 3 ] && grep -qxF -- '- Failed tests: `false`' "$bb/.forge/TESTING.md" || fail "a run whose suite rewrites W's Failed tests line to false reads the live line, so its failures stay unjudged and it exits 3: $(ball)"
! grep -q -e "^ft " -e "^one " "$BT_LOG" || fail "the base check reads the live Failed tests line in the worktree top, so the rewritten false runs no ft.sh and no base run: $(ball)"
cp "$tmp/bdoc.md" "$bb/.forge/TESTING.md"
ok test-base-pass
fi

finish
