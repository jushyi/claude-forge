plan_done() {
  local n=$1 f s=0 out x m
  phase "$n"
  f=$(readlink -f "$0")
  out=$(FORGE_ROOT=$root "$f" check "$n" </dev/null) || s=$?
  case $s in
    0 | 3) ;;
    1) exit 1 ;;
    *) die "forge check $n failed (exit $s)" ;;
  esac
  x=$(jq -cn --slurpfile p "$pd/plan.json" --slurpfile e "$pd/events.jsonl" '
    [$e[] | select(.step == "deferred") | .message | fromjson? | .check?] as $l
    | $p[0].deferred[]? | .check as $c | select(any($l[]; . == $c) | not)
    | {check, reason, plan: true}') || die "cannot read the deferred entries of $pd/plan.json"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    FORGE_ROOT=$root "$f" event "$n" deferred "$m" </dev/null || exit 1
  done <<<"$x"
  FORGE_ROOT=$root "$f" commit "$n" plan </dev/null || exit 1
  if [ $s = 3 ]; then
    echo "$out"
    echo "forge: plan committed for phase $n; it waits"
    exit 3
  fi
  echo "forge: plan committed for phase $n"
}
