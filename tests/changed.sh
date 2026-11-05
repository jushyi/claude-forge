#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob
cd "$(dirname "$0")/.."

suites=(tests/forge/*.test.sh)
all=(tests/!(forge).test.sh "${suites[@]}")
schemas=(tests/agents.test.sh "${suites[@]}" tests/forge-gates*.test.sh tests/forge-commit.test.sh tests/forge-land.test.sh tests/forge-review.test.sh tests/forge-agent-write.test.sh)
templates=("${suites[@]}" tests/forge-gates*.test.sh tests/forge-commit.test.sh tests/forge-land.test.sh tests/forge-review.test.sh tests/forge-init.test.sh)
fixtures=("${suites[@]}" tests/forge-gates*.test.sh tests/forge-commit.test.sh tests/forge-review.test.sh tests/forge-quick-log.test.sh)
declare -A uses=(
  [check]="tests/forge-gates*.test.sh tests/forge-commit.test.sh"
  [commit]="tests/forge-commit.test.sh"
  [gate]="tests/forge-gates*.test.sh tests/forge/review.test.sh"
  [gc]="tests/forge-land.test.sh"
  [land]="tests/forge-land.test.sh tests/forge-watchdog.test.sh"
  [notify]="tests/forge-watchdog.test.sh tests/forge/help.test.sh"
  [plan]="tests/forge-gates*.test.sh tests/forge-commit.test.sh"
  [quick-log]="tests/forge-quick-log.test.sh"
  [review]="tests/forge-review.test.sh tests/forge-commit.test.sh"
  [run]="tests/forge-gates*.test.sh tests/forge-commit.test.sh tests/forge-land.test.sh"
  [state]="tests/forge-gates*.test.sh tests/forge-commit.test.sh tests/forge-review.test.sh tests/forge-watchdog.test.sh"
  [test]="tests/forge-gates*.test.sh tests/forge-commit.test.sh"
  [watchdog]="tests/forge-watchdog.test.sh"
)
declare -A impl=(
  [alloc]=plan [archive]=plan [ready]=plan [fixes]=gate [golive]=land
  [resolve]=map [merge-check]=merge [status]=state [validate]=state [event]=review [ui]=review
  [clean]=run [discuss]=run [done]=run [implement]=run [next]=run [paths]=run [push]=run [repos]=run [resume]=run
)

own() { if [ -f "$1" ]; then run+=("$1"); else run+=("${all[@]}"); fi; }
module() {
  local s=() t
  for t in "tests/forge/$1.test.sh" "tests/forge/$1"-*.test.sh; do [ ! -f "$t" ] || s+=("$t"); done
  for t in ${uses[$1]:-}; do [ ! -f "$t" ] || s+=("$t"); done
  if [ ${#s[@]} -gt 0 ]; then run+=("${s[@]}"); else run+=("${all[@]}"); fi
}

run=()
for p; do
  case $p in
    tests/forge.test.sh) run+=("${all[@]}") ;;
    tests/*.test.sh) run+=("$p") ;;
    tests/forge-gates-common.sh) run+=(tests/forge-gates*.test.sh) ;;
    tests/changed.sh) run+=(tests/changed.test.sh tests/forge-gates-setup.test.sh tests/forge-watchdog.test.sh tests/forge-phase-parallel.test.sh) ;;
    tests/forge-common.sh) mapfile -t c < <(grep -lE '^\. .*/forge-common\.sh"$' "${all[@]}"); run+=("${c[@]}" tests/one-case.test.sh) ;;
    tests/fixtures/forge/*) run+=("${fixtures[@]}") ;;
    tests/fixtures/*) x=${p#tests/fixtures/}; own "tests/${x%%/*}.test.sh" ;;
    bin/forge.d/help/forge.txt) run+=(tests/forge-watchdog.test.sh tests/forge-gates*.test.sh tests/forge-quick-log.test.sh tests/forge-commit.test.sh tests/forge/{run,doctor,concern,help}.test.sh) ;;
    bin/forge.d/help/perf.txt) run+=(tests/forge/help.test.sh); module perf ;;
    bin/forge.d/help/*.txt) x=${p#bin/forge.d/help/}; x=${x%.txt}; run+=(tests/forge/help.test.sh); module "${impl[$x]:-$x}" ;;
    bin/forge.d/+([a-z-]).sh) x=${p#bin/forge.d/}; module "${x%.sh}" ;;
    bin/forge | bin/forge.d/*) run+=("${all[@]}") ;;
    bin/forge-*) own "tests/${p#bin/}.test.sh" ;;
    hooks/forge-guard.sh) run+=(tests/forge-guard.test.sh tests/forge-agent-write.test.sh) ;;
    hooks/forge-*.sh) x=${p#hooks/}; own "tests/${x%.sh}.test.sh" ;;
    scripts/*) x=${p#scripts/}; own "tests/${x%.*}.test.sh" ;;
    schemas/*) run+=("${schemas[@]}") ;;
    templates/*) run+=("${templates[@]}") ;;
    agents/*) run+=(tests/agents.test.sh) ;;
    mods/*) run+=(tests/mods.test.sh tests/port.test.sh) ;;
    skills/*) run+=(tests/forge-session-title.test.sh tests/skills.test.sh tests/forge-phase-parallel.test.sh) ;;
    global/settings.json) run+=(tests/forge-guard.test.sh tests/forge-gates*.test.sh tests/mods.test.sh tests/port.test.sh) ;;
    systemd/forge-watchdog.*) run+=(tests/forge-watchdog.test.sh tests/port.test.sh) ;;
    systemd/*) run+=(tests/port.test.sh) ;;
    port | global/* | hooks/* | bin/* | output-styles/*) run+=(tests/port.test.sh) ;;
    .forge/TESTING.md) run+=(tests/forge-gates-lint.test.sh tests/forge-gates-setup.test.sh tests/forge/check.test.sh tests/forge-watchdog.test.sh) ;;
    .forge/* | docs/* | README.md | CLAUDE.md) ;;
    *) run+=("${all[@]}") ;;
  esac
done

declare -A seen=()
list=()
for t in "${run[@]}"; do
  [ -z "${seen[$t]:-}" ] && [ -f "$t" ] || continue
  seen[$t]=1
  list+=("$t")
done
[ ${#list[@]} -gt 0 ] || exit 0
[ ${#list[@]} -ne ${#all[@]} ] || [ -z "${FORGE_TEST_LOG_DIR:-}" ] || : >"$FORGE_TEST_LOG_DIR/.full"
exec tests/forge.test.sh "${list[@]}"
