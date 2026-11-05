#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export LC_ALL=C
unset FORGE_TEST_SLOTS FORGE_TEST_SLOT_HELD FORGE_TEST_SLOT_WAIT FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "changed: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "changed $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
code() { local s=0; "$@" >"$tmp/out" 2>&1 || s=$?; echo $s; }

o=$tmp/o
git init -q -b main "$o"
mkdir -p "$o/tests/forge" "$tmp/bin" "$tmp/rl"
cp "$root/tests/forge.test.sh" "$root/tests/changed.sh" "$o/tests/"
stub() {
  sed "s|NAME|$1|g" >"$o/tests/$1.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "NAME" >>"$T_LOG"
echo "out NAME"
if [ -n "${T_RUN:-}" ]; then echo "+ NAME" >>"$T_RUN"; sleep "${T_SLEEP:-0}"; echo "- NAME" >>"$T_RUN"; fi
rc=$(awk -v n=NAME '$1 == n { print $2 }' "${T_FAIL:-/dev/null}")
exit "${rc:-0}"
EOF
  chmod +x "$o/tests/$1.test.sh"
}
stubs=(a b c d forge/a forge/b)
for s in "${stubs[@]}"; do stub "$s"; done
printf '#!/usr/bin/env bash\necho "$NPROC"\n' >"$tmp/bin/nproc" && chmod +x "$tmp/bin/nproc"
export T_LOG=$tmp/log
sum=$o/.git/forge-test/suite-seconds
ran() { cat "$T_LOG"; }
runner() { : >"$T_LOG"; rm -f "$tmp/rec"; code env PATH="$tmp/bin:$PATH" NPROC=24 T_RUN="$tmp/rec" FORGE_TEST_LOG_DIR="$tmp/rl" "$@"; }
lines() { grep -E '^(ok|FAIL) ' "$tmp/out" | sed -E 's#^(ok|FAIL) (tests/)?([^ ]+)#\1 \3#; s#^(ok|FAIL) ([^ ]+)\.test\.sh #\1 \2 #; s#\([0-9]+s\)$#(Ns)#; s#, [0-9]+s, #, Ns, #' || true; }
peak() { awk '$1 == "+" { c++; if (c > m) m = c } $1 == "-" { c-- } END { print m + 0 }' "$tmp/rec"; }
sec() { awk -v n="$1" '$2 == n { print $1 }' "$sum"; }
printf 'b 3\n' >"$tmp/fails"

mkdir -p "$tmp/r/tests/forge" "$tmp/rf"
for e in "$root"/tests/* "$root"/tests/forge/*; do
  case ${e#"$root"/tests/} in forge | forge.test.sh | changed.sh) ;; *) ln -s "$e" "$tmp/r/tests/${e#"$root"/tests/}" ;; esac
done
cp "$root/tests/changed.sh" "$tmp/r/tests/"
cat >"$tmp/r/tests/forge.test.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${T_STUB:-}" ] || : >"$T_STUB"
printf '%s\n' "$@"
EOF
chmod +x "$tmp/r/tests/forge.test.sh"
full=0
for e in "$root"/tests/*.test.sh "$root"/tests/forge/*.test.sh; do [ "$e" = "$root/tests/forge.test.sh" ] || full=$((full + 1)); done
sel() {
  rm -f "$tmp/rf/.full" "$tmp/stub"
  env FORGE_TEST_LOG_DIR="$tmp/rf" T_STUB="$tmp/stub" "$tmp/r/tests/changed.sh" "$@" >"$tmp/sel" </dev/null || fail "the copied tests/changed.sh exits 0 for $*: $(cat "$tmp/sel")"
  sort "$tmp/sel" | paste -sd' '
}
suites() { local s; for s; do echo "tests/$s.test.sh"; done | sort | paste -sd' '; }
gates="forge-gates forge-gates-lint forge-gates-resources forge-gates-setup forge-gates-tiers"
cd "$o"

if want runner-all; then
  [ "$(runner FORGE_TEST_CPUS=1 tests/forge.test.sh)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b c d forge/a forge/b" ] || fail "tests/forge.test.sh with no arguments runs every suite once: $(cat "$tmp/out") $(ran)"
  ok runner-all
fi

if want runner-paths; then
  [ "$(runner FORGE_TEST_CPUS=1 tests/forge.test.sh tests/a.test.sh tests/forge/b.test.sh)" = 0 ] || fail "tests/forge.test.sh with suite paths exits 0 when they pass: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a forge/b" ] || fail "tests/forge.test.sh with suite paths runs only those suites, each once: $(ran | paste -sd' ')"
  [ "$(lines | sort | paste -sd,)" = "ok a (Ns),ok forge/b (Ns)" ] || fail "tests/forge.test.sh with suite paths prints one ok line per given suite: $(cat "$tmp/out")"
  [ "$(cat "$tmp/rl/a.log")" = "out a" ] && [ "$(cat "$tmp/rl/forge/b.log")" = "out forge/b" ] || fail "tests/forge.test.sh with suite paths logs each under FORGE_TEST_LOG_DIR: $(cd "$tmp/rl" && find . -type f)"
  ok runner-paths
fi

if want runner-peak; then
  [ "$(runner FORGE_TEST_CPUS=2 T_SLEEP=0.3 tests/forge.test.sh tests/a.test.sh tests/c.test.sh tests/forge/a.test.sh)" = 0 ] || fail "tests/forge.test.sh over three paths exits 0: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a c forge/a" ] || fail "tests/forge.test.sh over three paths runs only those three once each: $(ran | paste -sd' ')"
  [ "$(peak)" = 2 ] || fail "tests/forge.test.sh runs FORGE_TEST_CPUS=2 of three given suites at once: $(peak) $(cat "$tmp/rec")"
  ok runner-peak
fi

if want runner-fail; then
  rm -rf "$tmp/rl" && mkdir -p "$tmp/rl"
  [ "$(runner FORGE_TEST_CPUS=1 T_FAIL="$tmp/fails" tests/forge.test.sh tests/a.test.sh tests/b.test.sh tests/c.test.sh)" = 1 ] || fail "tests/forge.test.sh exits 1 when a given suite fails: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a b c" ] || fail "tests/forge.test.sh runs the other given suites after a failure, and only those: $(ran | paste -sd' ')"
  [ "$(lines | sort | paste -sd,)" = "FAIL b (exit 3, Ns, log $tmp/rl/b.log),ok a (Ns),ok c (Ns)" ] || fail "tests/forge.test.sh prints the failing given suite's FAIL line and ok for the rest: $(cat "$tmp/out")"
  ok runner-fail
fi

if want runner-order; then
  mkdir -p "$(dirname "$sum")"
  printf '%s\n' '10 a' '50 c' '90 d' '30 forge/b' '70 gone' >"$sum"
  [ "$(runner FORGE_TEST_CPUS=1 tests/forge.test.sh tests/a.test.sh tests/forge/b.test.sh tests/c.test.sh)" = 0 ] || fail "tests/forge.test.sh over seeded paths exits 0: $(cat "$tmp/out")"
  [ "$(ran | paste -sd' ')" = "c forge/b a" ] || fail "tests/forge.test.sh starts the given suites longest first from suite-seconds: $(ran | paste -sd' ')"
  [ "$(sec d)" = 90 ] || fail "a subset run keeps an unrun suite's previous seconds in the summary: $(cat "$sum")"
  [ "$(sec gone)" = 70 ] || fail "a subset run keeps the previous seconds of a suite absent from this worktree: $(cat "$sum")"
  [ -n "$(sec c)" ] && [ "$(sec c)" -lt 50 ] && [ -n "$(sec a)" ] && [ -n "$(sec forge/b)" ] || fail "a subset run rewrites the seconds of the suites it ran: $(cat "$sum")"
  [ "$(wc -l <"$sum")" = 5 ] && [ -z "$(sec b)" ] && [ -z "$(sec forge/a)" ] || fail "a subset run adds no line for an unrun suite with no previous seconds: $(cat "$sum")"
  ok runner-order
fi

if want runner-cpus; then
  for v in 0 x; do
    [ "$(runner FORGE_TEST_CPUS="$v" tests/forge.test.sh tests/a.test.sh)" != 0 ] && [ -z "$(ran)" ] || fail "tests/forge.test.sh with suite paths rejects FORGE_TEST_CPUS=$v before running a suite: $(cat "$tmp/out") $(ran)"
  done
  ok runner-cpus
fi

if want changed-paths; then
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh tests/a.test.sh tests/forge/b.test.sh tests/a.test.sh tests/zz.test.sh .forge/STATE.md)" = 0 ] || fail "tests/changed.sh exits 0 when its selected suites pass: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a forge/b" ] || fail "tests/changed.sh runs the selected suites, and only they, once each: $(ran | paste -sd' ')"
  [ "$(lines | sort | paste -sd,)" = "ok a (Ns),ok forge/b (Ns)" ] || fail "tests/changed.sh runs its selection through tests/forge.test.sh, one ok line per selected suite: $(cat "$tmp/out")"
  ok changed-paths
fi

if want changed-full; then
  rm -f "$tmp/rl/.full"
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh zz/unknown.txt)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b c d forge/a forge/b" ] || fail "tests/changed.sh runs every suite for an unknown path: $(cat "$tmp/out") $(ran | paste -sd' ')"
  [ -f "$tmp/rl/.full" ] && [ ! -s "$tmp/rl/.full" ] || fail "tests/changed.sh writes an empty FORGE_TEST_LOG_DIR/.full when its selection is every suite: $(cd "$tmp/rl" && find . -type f)"
  rm -f "$tmp/rl/.full"
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh tests/a.test.sh tests/b.test.sh tests/c.test.sh tests/d.test.sh tests/forge/a.test.sh tests/a.test.sh)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b c d forge/a" ] || fail "tests/changed.sh runs a selection one suite short of every suite: $(cat "$tmp/out") $(ran | paste -sd' ')"
  [ ! -e "$tmp/rl/.full" ] || fail "tests/changed.sh writes no .full for a selection one suite short of every suite"
  rm -f "$tmp/rl/.full"
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh tests/b.test.sh)" = 0 ] && [ "$(ran)" = b ] && [ ! -e "$tmp/rl/.full" ] || fail "tests/changed.sh writes no .full for a single-suite selection: $(cat "$tmp/out") $(ran | paste -sd' ')"
  : >"$T_LOG"
  [ "$(code env -u FORGE_TEST_LOG_DIR PATH="$tmp/bin:$PATH" NPROC=24 FORGE_TEST_CPUS=1 tests/changed.sh zz/unknown.txt)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b c d forge/a forge/b" ] || fail "tests/changed.sh with FORGE_TEST_LOG_DIR unset runs every suite for an unknown path and exits 0: $(cat "$tmp/out") $(ran | paste -sd' ')"
  [ ! -e "$tmp/rl/.full" ] && [ ! -e "$o/.full" ] || fail "tests/changed.sh with FORGE_TEST_LOG_DIR unset writes no .full"
  ok changed-full
fi

if want changed-peak; then
  [ "$(runner FORGE_TEST_CPUS=2 T_SLEEP=0.3 tests/changed.sh tests/a.test.sh tests/c.test.sh tests/forge/a.test.sh)" = 0 ] || fail "tests/changed.sh over three selected suites exits 0: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a c forge/a" ] || fail "tests/changed.sh over three selected suites runs only those three once each: $(ran | paste -sd' ')"
  [ "$(peak)" = 2 ] || fail "tests/changed.sh runs FORGE_TEST_CPUS=2 of three selected suites at once: $(peak) $(cat "$tmp/rec")"
  ok changed-peak
fi

if want changed-fail; then
  rm -rf "$tmp/rl" && mkdir -p "$tmp/rl"
  [ "$(runner FORGE_TEST_CPUS=1 T_FAIL="$tmp/fails" tests/changed.sh tests/a.test.sh tests/b.test.sh tests/c.test.sh)" = 1 ] || fail "tests/changed.sh exits 1 when a selected suite fails: $(cat "$tmp/out")"
  [ "$(ran | sort | paste -sd' ')" = "a b c" ] || fail "tests/changed.sh runs the other selected suites after a failure, and only those: $(ran | paste -sd' ')"
  [ "$(lines | sort | paste -sd,)" = "FAIL b (exit 3, Ns, log $tmp/rl/b.log),ok a (Ns),ok c (Ns)" ] || fail "tests/changed.sh prints the failing selected suite's FAIL line and ok for the rest: $(cat "$tmp/out")"
  ok changed-fail
fi

if want changed-empty; then
  for sel in ".forge/STATE.md docs/x.md" "README.md CLAUDE.md" ""; do
    [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh $sel)" = 0 ] || fail "tests/changed.sh with an empty selection ($sel) exits 0: $(cat "$tmp/out")"
    [ -z "$(ran)" ] && [ -z "$(lines)" ] || fail "tests/changed.sh with an empty selection ($sel) runs no suite: $(cat "$tmp/out") $(ran | paste -sd' ')"
  done
  ok changed-empty
fi

if want changed-scripts; then
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh scripts/a.py scripts/b.sh)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b" ] || fail "tests/changed.sh maps scripts/<name>.<ext> to tests/<name>.test.sh alone: $(cat "$tmp/out") $(ran | paste -sd' ')"
  [ "$(runner FORGE_TEST_CPUS=1 tests/changed.sh scripts/zz.py)" = 0 ] && [ "$(ran | sort | paste -sd' ')" = "a b c d forge/a forge/b" ] || fail "tests/changed.sh runs every suite for a script with no suite of its own: $(cat "$tmp/out") $(ran | paste -sd' ')"
  ok changed-scripts
fi

if want changed-help; then
  [ "$(sel bin/forge.d/help/forge.txt)" = "$(suites forge-watchdog $gates forge-quick-log forge-commit forge/run forge/doctor forge/concern forge/help)" ] || fail "tests/changed.sh maps help/forge.txt to the 13 suites reading forge --help and the usage text: $(sort "$tmp/sel" | paste -sd' ')"
  [ ! -e "$tmp/rf/.full" ] || fail "tests/changed.sh writes no .full for help/forge.txt"
  [ "$(sel bin/forge.d/help/perf.txt)" = "$(suites forge/help forge/perf)" ] || fail "tests/changed.sh maps help/perf.txt to forge/help and the perf module's suite: $(sort "$tmp/sel" | paste -sd' ')"
  [ "$(sel bin/forge.d/help/watchdog.txt)" = "$(suites forge/help forge-watchdog)" ] || fail "tests/changed.sh maps another help/<name>.txt to forge/help plus the module's suites: $(sort "$tmp/sel" | paste -sd' ')"
  sel bin/forge >/dev/null
  [ "$(wc -l <"$tmp/sel")" = "$full" ] && [ -f "$tmp/rf/.full" ] || fail "tests/changed.sh still maps bin/forge to every suite and writes .full: $(wc -l <"$tmp/sel") of $full"
  sel zz/unknown.txt >/dev/null
  [ "$(wc -l <"$tmp/sel")" = "$full" ] && [ -f "$tmp/rf/.full" ] || fail "tests/changed.sh still maps an unknown path to every suite and writes .full: $(wc -l <"$tmp/sel") of $full"
  ok changed-help
fi

if want changed-self; then
  [ "$(sel tests/changed.sh)" = "$(suites changed forge-gates-setup forge-watchdog forge-phase-parallel)" ] || fail "tests/changed.sh maps itself to its four readers: $(sort "$tmp/sel" | paste -sd' ')"
  ok changed-self
fi

if want changed-common; then
  [ "$(sel tests/forge-common.sh)" = "$(suites $gates forge-commit forge-quick-log one-case $(cd "$root/tests" && for e in forge/*.test.sh; do echo "${e%.test.sh}"; done))" ] || fail "tests/changed.sh maps tests/forge-common.sh to the suites sourcing it plus one-case: $(sort "$tmp/sel" | paste -sd' ')"
  [ ! -e "$tmp/rf/.full" ] || fail "tests/changed.sh writes no .full for tests/forge-common.sh"
  ok changed-common
fi

if want changed-docs; then
  [ -z "$(sel docs/x.md docs/x/y.md)" ] && [ ! -e "$tmp/stub" ] && [ ! -e "$tmp/rf/.full" ] || fail "tests/changed.sh selects no suite for docs/, exits 0 without the runner and writes no .full: $(cat "$tmp/sel")"
  ok changed-docs
fi

if want changed-testing-doc; then
  [ "$(sel .forge/TESTING.md)" = "$(suites forge-gates-lint forge-gates-setup forge/check forge-watchdog)" ] || fail "tests/changed.sh maps .forge/TESTING.md to its four readers: $(sort "$tmp/sel" | paste -sd' ')"
  ok changed-testing-doc
fi

if want changed-fixtures; then
  [ "$(sel tests/fixtures/forge/project/x.json)" = "$(suites $gates forge-commit forge-review forge-quick-log $(cd "$root/tests" && for e in forge/*.test.sh; do echo "${e%.test.sh}"; done))" ] || fail "tests/changed.sh maps tests/fixtures/forge/ to the forge suites, the gates, commit, review and quick-log: $(sort "$tmp/sel" | paste -sd' ')"
  ok changed-fixtures
fi

if want changed-replay; then
  s0=$SECONDS
  n=0 runs=0
  while IFS= read -r l; do
    IFS=$'\t' read -ra p <<<"$l"
    runs=$((runs + 1))
    "$tmp/r/tests/changed.sh" "${p[@]}" >"$tmp/sel" </dev/null || fail "the copied tests/changed.sh exits 0 for replay line $runs: $(cat "$tmp/sel")"
    mapfile -t s <"$tmp/sel"
    [ ${#s[@]} -ne "$full" ] || n=$((n + 1))
  done <"$root/tests/fixtures/changed/replay.tsv"
  cap=56
  [ "$runs" -ge 462 ] || cap=$((56 * runs / 462))
  echo "changed changed-replay: $n of $runs runs select all $full suites, cap $cap ($((SECONDS - s0))s)"
  [ "$runs" -gt 0 ] && [ "$n" -le "$cap" ] || fail "the replayed changed runs select every suite at most $cap times: $n of $runs"
  ok changed-replay
fi
[ -z "$only" ] || fail "no case $only"
