td_say() { echo "forge: task-done $tn $ti: $1"; }

td_forge() { FORGE_ROOT=$root "$D/../forge" "$@" </dev/null; }

td_run() {
  td_s=0
  td_out=$(cd "$tW" && env -u FORGE_ROOT bash -c "$1" </dev/null 2>&1) || td_s=$?
}

td_log() {
  printf '%s\n' "$1" >"$tG/forge-$tn-$ti.log" || die "cannot write $tG/forge-$tn-$ti.log"
}

td_git() {
  local e
  e=$(git -C "$tW" --literal-pathspecs "$@" 2>&1) && return 0
  if [[ $e == *index.lock* ]]; then
    sleep 1
    e=$(git -C "$tW" --literal-pathspecs "$@" 2>&1) && return 0
  fi
  echo "$e" >&2
  return 1
}

td_porcelain() {
  local x skip=false
  git -C "$tW" --literal-pathspecs status --porcelain -z --untracked-files=all "$@" | while IFS= read -r -d '' x; do
    if [ "$skip" = true ]; then
      skip=false
      printf '%s\n' "$x"
      continue
    fi
    [[ ${x:0:2} != *[RC]* ]] || skip=true
    printf '%s\n' "${x:3}"
  done
}

td_list() {
  local p
  while IFS= read -r p; do
    [ -z "$p" ] || [[ $p == "$state"/* ]] || printf '%s\n' "$p"
  done <<<"$1"
}

td_commit() {
  local tr=$tP/tasks/$ti.json dev p x y sha tmpf cands=() files=() adds=()
  x=$(jq -r '.files[]?' <<<"$tplan") || die "cannot read the files of $ti in $tP/plan.json"
  dev=$(jq -r '.deviation // empty' "$tr") || die "cannot read $tr"
  if [ -n "$dev" ]; then
    y=$(td_porcelain) || die "cannot read the status of $tW"
    while IFS= read -r p; do
      [ -z "$p" ] || [[ $dev != *"$p"* ]] || x+=$'\n'$p
    done <<<"$y"
  fi
  mapfile -t cands < <(td_list "$x")
  if [ ${#cands[@]} -gt 0 ]; then
    y=$(td_porcelain -- "${cands[@]}") || die "cannot read the status of $tW"
    mapfile -t files < <(td_list "$y")
  fi
  if [ ${#files[@]} -gt 0 ]; then
    y=$(git -C "$tW" --literal-pathspecs ls-files -z -c -o -- "${files[@]}" | tr '\0' '\n') || die "cannot list the files of $tW"
    mapfile -t adds < <(td_list "$y")
    [ ${#adds[@]} -eq 0 ] || td_git add -- "${adds[@]}" || die "git add failed in $tW"
    td_git commit -q -m "feat($(jq -r '.slug' "$tP/spec.json")): $(jq -r '.title' <<<"$tplan")" -- "${files[@]}" || die "git commit failed in $tW"
  fi
  sha=$(git -C "$tW" rev-parse --short HEAD) || die "cannot read the HEAD of $tW"
  tmpf=$(mktemp "$tP/tasks/.$ti.XXXXXX") || die "cannot write $tr"
  jq --arg c "$sha" '.commit = $c' "$tr" >"$tmpf" && mv "$tmpf" "$tr" || { rm -f "$tmpf"; die "cannot write $tr"; }
  td_forge commit "$tn" "$ti" || die "forge commit $tn $ti failed"
  td_say "committed $sha"
  exit 0
}

td_implementer() {
  local rec=$tP/tasks/$ti.json st= e= c=
  if [ -f "$rec" ]; then
    st=$(jq -r '.status // empty' "$rec") && e=$(jq -r '.exit // empty' "$rec") && c=$(jq -r '.command // empty' "$rec") || die "cannot read $rec"
  fi
  if [ "$st" = failed ]; then
    td_log "$(cat "$rec")"
    td_say "respawn the implementer: it reported failed; log $tG/forge-$tn-$ti.log"
    exit 5
  fi
  [ "$st" = done ] && [ "$e" = 0 ] && td_commit
  if [ -z "$c" ]; then
    td_log "no test command: the task record $rec holds no command"
    td_say "respawn the implementer: no test command to run; log $tG/forge-$tn-$ti.log"
    exit 5
  fi
  td_run "$c"
  if [ "$td_s" != 0 ]; then
    td_log "$td_out"
    td_say "respawn the implementer: its test command failed (exit $td_s); log $tG/forge-$tn-$ti.log"
    exit 5
  fi
  td_commit
}

td_unmet() {
  local tmpf
  mkdir -p "$tP/tasks" || die "cannot write $tP/tasks"
  tmpf=$(mktemp "$tP/tasks/.$ti.XXXXXX") || die "cannot write $tP/tasks/$ti.json"
  jq -n --arg i "$ti" --arg r "$1" '{id: $i, status: "unmet", reason: $r}' >"$tmpf" && mv "$tmpf" "$tP/tasks/$ti.json" || { rm -f "$tmpf"; die "cannot write $tP/tasks/$ti.json"; }
  td_commit
}

task_done() {
  local x k v tR= tP= tW= tG= tplan
  tn=$1 ti=$2
  x=$(paths "$tn") || exit $?
  while IFS='=' read -r k v; do
    case $k in R) tR=$v ;; P) tP=$v ;; W) tW=$v ;; G) tG=$v ;; esac
  done <<<"$x"
  [ -n "$tP" ] && [ -n "$tR" ] || die "no phase $tn" 2
  [ -n "$tG" ] || die "no phase worktree $tW"
  tplan=$(jq -c --arg i "$ti" 'first(.tasks[] | select(.id == $i)) // empty' "$tP/plan.json") || die "cannot read $tP/plan.json"
  [ -n "$tplan" ] || die "no task $ti in $tP/plan.json" 2
  [ $# -lt 4 ] || td_unmet "$4"
  td_implementer
}
