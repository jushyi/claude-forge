#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob nullglob
cd "$(dirname "$0")/.."
export FORGE_HOST_ENV=${FORGE_ENV:-} FORGE_ENV=/dev/null

declare -a name=() began=()
declare -A prev=() secs=() known=() want=()
stop() {
  trap - TERM INT HUP
  [ ${#name[@]} -eq 0 ] || kill -TERM "${!name[@]}" 2>/dev/null || true
  exit "$1"
}
die() { echo "tests/forge.test.sh: $*" >&2; stop 1; }
trap 'stop 143' TERM
trap 'stop 130' INT
trap 'stop 129' HUP

cpus=$(nproc)
cap=${FORGE_TEST_CPUS:-$cpus}
[[ $cap =~ ^[1-9][0-9]*$ ]] || die "FORGE_TEST_CPUS must be a positive integer, got '$cap'"
if [ ${#cap} -gt 9 ] || [ "$cap" -gt "$cpus" ]; then cap=$cpus; fi

all=(tests/!(forge).test.sh tests/forge/*.test.sh)
[ ${#all[@]} -gt 0 ] || die "no suites under tests/"
mapfile -t names < <(printf '%s\n' "${all[@]}" | sed -E 's#^tests/##; s#\.test\.sh$##' | LC_ALL=C sort)
for n in "${names[@]}"; do known[$n]=1; done
run=("${names[@]}")
if [ $# -gt 0 ]; then
  run=()
  for p in "$@"; do
    n=${p#tests/}
    n=${n%.test.sh}
    [ "tests/$n.test.sh" = "$p" ] && [ -n "${known[$n]:-}" ] || die "not a suite: '$p'"
    [ -n "${want[$n]:-}" ] || run+=("$n")
    want[$n]=1
  done
fi

sd=$(git rev-parse --path-format=absolute --git-common-dir)/forge-test
sum=$sd/suite-seconds
if [ -f "$sum" ]; then
  while read -r s n; do
    if [[ $s =~ ^[0-9]+$ ]] && [ -n "$n" ]; then prev[$n]=$s; fi
  done <"$sum"
fi
order=()
for n in "${run[@]}"; do [ -n "${prev[$n]:-}" ] || order+=("$n"); done
while read -r _ n; do order+=("$n"); done < <(
  for n in "${run[@]}"; do [ -z "${prev[$n]:-}" ] || echo "${prev[$n]} $n"; done | LC_ALL=C sort -k1,1nr -k2,2
)

tmpd=
dir=${FORGE_TEST_LOG_DIR:-}
if [ -z "$dir" ]; then dir=$(mktemp -d) && tmpd=$dir; fi
dir=${dir%/}
failed=0

reap() {
  local pid='' s=0 n t
  wait -n -p pid "${!name[@]}" || s=$?
  [ -n "$pid" ] || die "wait -n named no finished suite (status $s)"
  n=${name[$pid]}
  t=$((SECONDS - began[pid]))
  unset "name[$pid]" "began[$pid]"
  if [ "$s" = 0 ]; then
    echo "ok $n (${t}s)"
    secs[$n]=$t
  else
    echo "FAIL $n (exit $s, ${t}s, log $dir/$n.log)"
    failed=1
    [ -z "${prev[$n]:-}" ] || secs[$n]=${prev[$n]}
  fi
}

for n in "${order[@]}"; do
  [ ${#name[@]} -lt "$cap" ] || reap
  mkdir -p "$(dirname "$dir/$n.log")"
  "tests/$n.test.sh" >"$dir/$n.log" 2>&1 &
  name[$!]=$n
  began[$!]=$SECONDS
done
while [ ${#name[@]} -gt 0 ]; do reap; done

mkdir -p "$sd"
new=$(mktemp "$sd/suite-seconds.XXXXXX")
keep=("${names[@]}")
[ $# -eq 0 ] || mapfile -t keep < <(printf '%s\n' "${names[@]}" "${!prev[@]}" | LC_ALL=C sort -u)
for n in "${keep[@]}"; do
  if [ $# -gt 0 ] && [ -z "${want[$n]:-}" ]; then t=${prev[$n]:-}; else t=${secs[$n]:-}; fi
  [ -z "$t" ] || echo "$t $n"
done >"$new"
mv "$new" "$sum"

[ "$failed" = 0 ] || exit 1
[ -z "$tmpd" ] || rm -rf "$tmpd"
