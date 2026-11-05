perf_metric='def metric: (try fromjson catch null) | select(type == "object" and (.metric | type == "string" and length > 0) and (.value | type == "number" and . >= 0) and (.unit | type == "string" and length > 0) and (.kind == "count" or .kind == "time"));'

perf() {
  local w=${FORGE_PERF_WINDOW:-7} names n
  [ $# -eq 1 ] && [ "$1" = pull ] || usage
  posint FORGE_PERF_WINDOW "$w"
  repos
  mapfile -t names < <(printf '%s\n' "${!dirs[@]}" | sort)
  for n in "${names[@]}"; do
    perf_pull "$n" "${dirs[$n]}" "$w"
  done
}

perf_pull() {
  local name=$1 d=$2 w=$3 cmd out ms new seeds l s=0 k=0 today from old='{}' led=$2/.forge/perf.json sf=$2/.forge/seeds.md paths=(.forge/perf.json)
  cmd=$(test_line "$d" "Perf log") || exit
  if [ -z "$cmd" ]; then
    grep -q '^- Perf log:' "$d/.forge/TESTING.md" 2>/dev/null || return 0
    echo "forge: perf pull: $name: its - Perf log: line has no backticked command; skipped" >&2
    return 0
  fi
  out=$(cd "$d" && FORGE_PERF_WINDOW=$w bash -c "$cmd" </dev/null) || s=$?
  if [ $s -ne 0 ]; then
    echo "forge: perf pull: $name: the Perf log command exited $s; skipped" >&2
    return 0
  fi
  ms=$(jq -Rnc --arg p "forge: perf pull: $name: " "$perf_metric"'
    [inputs] | to_entries | map(select(.value | startswith("{")))
    | map(.key as $k | .value as $l | ($l | metric) // ("\($p)bad metric line \($k + 1): \($l); skipped\n" | halt_error(1)))' <<<"$out") || return 0
  if [ "$ms" = "[]" ]; then
    echo "forge: perf pull: $name: the Perf log command printed no metric lines; skipped" >&2
    return 0
  fi
  today=$(date +%F) && from=$(date -d "-$w days" +%F) || die "perf pull: cannot compute the $w-day window"
  lock "$d"
  if [ -e "$led" ]; then old=$(jq -c '.metrics // {}' "$led") || die "cannot read $led"; fi
  new=$(jq -cn --argjson ms "$ms" --argjson old "$old" --arg f "$from" --arg t "$today" '
    def pct($p): .[(length * $p / 100 | ceil) - 1];
    {metrics: ($ms | group_by(.metric) | map(.[0] as $x | (map(.value) | sort) as $vs | $old[$x.metric] as $e
      | {($x.metric): {kind: $x.kind, unit: $x.unit, n: ($vs | length), p50: ($vs | pct(50)), p95: ($vs | pct(95)), window: {from: $f, to: $t},
          prev: (if ($e | type) == "object" and ($e.p50 | type) == "number" and ($e.p95 | type) == "number" then {n: $e.n, p50: $e.p50, p95: $e.p95} else null end)}})
      | add)}') || die "perf pull: $name: cannot aggregate the metric lines"
  seeds=$(jq -r --arg d "$today" '.metrics | to_entries[] | .key as $m | .value
    | select(.prev != null and ((.p95 - .prev.p95) | fabs) > 0.2 * .prev.p95)
    | "- \($d) perf metric `\($m)`: p95 \(.prev.p95) -> \(.p95) \(.unit) over \(.window.from)..\(.window.to)"' <<<"$new") || die "perf pull: $name: cannot list the seeds"
  jq . <<<"$new" >"$led" || die "cannot write $led"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ -f "$sf" ] && grep -qxF -- "$l" "$sf"; then continue; fi
    if [ -s "$sf" ] && [ -n "$(tail -c 1 "$sf")" ]; then echo >>"$sf" || die "cannot write $sf"; fi
    printf '%s\n' "$l" >>"$sf" || die "cannot write $sf"
    k=$((k + 1))
  done <<<"$seeds"
  [ $k -eq 0 ] || paths+=(.forge/seeds.md)
  git -C "$d" add -- "${paths[@]}" || die "perf pull: $name: cannot stage ${paths[*]}"
  if ! git -C "$d" diff --cached --quiet -- "${paths[@]}"; then
    git -C "$d" commit -q -m "docs(perf): pull $today" -- "${paths[@]}" || die "perf pull: $name: cannot commit ${paths[*]}"
  fi
  exec 9>&-
  locked=
  echo "perf pull: $name: $(jq '.metrics | length' <<<"$new") metrics, $k seeds"
}
