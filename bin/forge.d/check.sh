phase() {
  [[ ${1:-} =~ ^[0-9]{2,}$ ]] || die "expected a phase number, got '${1:-}'" 2
  local x=("$state"/phases/"$1"-*/)
  [ ${#x[@]} -eq 1 ] || die "no phase $1"
  pd=${x[0]%/}
}

check_lint() {
  local r=$1 err rest= l n line q id
  err=$(test_lint "$r" 2>&1 >/dev/null) && return 0
  while IFS= read -r l; do
    if [[ $l =~ ^forge:\ (.+/\.forge/TESTING\.md):\ line\ ([0-9]+):\ (.*):\ (added\ [0-9]{4}-[0-9]{2}-[0-9]{2}),\ over\ 7\ days\ ago\;\ lift\ it\ or\ fix\ the\ tests$ ]]; then
      n=${BASH_REMATCH[2]} line=${BASH_REMATCH[3]} q=${BASH_REMATCH[4]} id=
      quarantine_concern "$r" "$n" "$line" "$q" || return 1
      [ -z "$id" ] || echo "forge: $r/.forge/TESTING.md: line $n: $line: $q, over 7 days ago; recorded as concern ${r##*/}:$id" >&2
    else
      rest+=$l$'\n'
    fi
  done <<<"$err"
  [ -z "$rest" ] || { printf '%s' "$rest" >&2; return 1; }
}

quarantine_concern() {
  local m c
  m=$(git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p') && [ -n "$m" ] || die "cannot find the main worktree of $1"
  m=$m/$(git -C "$1" rev-parse --show-prefix) || die "cannot locate $1 in its repo"
  m=${m%/}
  c=$m/.forge/concerns.json
  if [ -f "$c" ]; then
    ! jq -e --arg l "$3" 'any(.concerns[]; .area == "quarantine" and .status == "open" and (.text | endswith(": " + $l)))' "$c" >/dev/null 2>&1 || return 0
  fi
  concern_add "$m" quarantine low "Quarantine line $2 of .forge/TESTING.md, $4, is over 7 days old; lift it or fix the tests: $3" .forge/TESTING.md
}

depends_on() {
  local from=$1 to=$2 stack=("$1") seen=() cur x dep
  while [ ${#stack[@]} -gt 0 ]; do
    cur=${stack[-1]}
    unset 'stack[-1]'
    [[ " ${seen[*]-} " == *" $cur "* ]] && continue
    seen+=("$cur")
    x=("$state"/phases/"$cur"-*/)
    [ ${#x[@]} -eq 1 ] && [ -f "${x[0]}spec.json" ] || continue
    for dep in $(jq -r '.depends[]?' "${x[0]}spec.json"); do
      [ "$dep" = "$to" ] && return 0
      stack+=("$dep")
    done
  done
  return 1
}

criteria_path() {
  local file=$T/checks/$1.md
  [ -f "$file" ] || die "no $file"
  echo "$file"
}

criteria_ids() {
  local file
  file=$(criteria_path "$1") || exit 1
  sed -n '/^## Criteria/,$p' "$file" | grep '^- ' | sed -E 's/^- ([^:]+):.*/\1/'
}

focus_text() {
  local spec=$1 tag file targets fields
  ft=$ftext
  for tag in $(jq -r '.focus[]?' "$spec"); do
    file=$(criteria_path "$tag") || exit 1
    ft+=$'\n\n'"$(cat "$file")"
  done
  [ "$ft" != "$ftext" ] || return 0
  targets=$(jq -c '.targets // empty' "$spec")
  [ -z "$targets" ] || ft+=$'\n\n'"Targets: $targets."
  fields=$(jq -c '.pii_fields // empty' "$spec")
  [ -z "$fields" ] || ft+=$'\n\n'"PII fields: $fields."
  ft+=$'\n\n'"Treat a violation of any criterion above as a high-severity finding whose summary starts \"[<focus> <ID>]\", e.g. \"[pii PII-01]\"."
}

check() {
  phase "$@"
  [ -f "$pd/plan.json" ] || die "no $pd/plan.json"
  validate "$pd/plan.json" || exit 1
  local n=$1 d=$pd out m ms=()
  out=$(jq -r -n --slurpfile s "$pd/spec.json" --slurpfile p "$pd/plan.json" '
    ($p[0].tasks | map(.id)) as $ids
    | ($s[0].requirements - [$p[0].tasks[].requirements[]?] | map("\(.) maps to no task")[]),
      ($p[0].tasks[] | .id as $t | .deps[] | select(IN($ids[]) | not) | "\($t) depends on unknown \(.)")')
  [ -z "$out" ] || { echo "$out" >&2; exit 1; }
  out=$(jq -r -n -L "$D" --argjson t "$(task_claims "$d")" --slurpfile s "$pd/spec.json" --slurpfile p "$pd/plan.json" 'include "forge";
    $s[0] as $s | ($s.repo // "") as $r
    | select(any($s.spec[]; startswith("Gap:")) | not)
    | [$s.spec[] | select(startswith("Files: ")) | entries($s.repo)[]] as $fs
    | [$t[].claims[]] as $c
    | ($c | map(.[0]) | unique) as $rs
    | ($p[0].na_files // [] | map(.file)) as $na
    | ($fs | unique[] | . as $x
        | ((capture("^(?<r>[^/:\\s]+):(?<f>.+)$") | select(IN($rs[]; .r)) | [.r, .f]) // [$r, $x]) as [$kr, $kf]
        | select((any($c[]; .[0] == $kr and (.[1] == $kf or (.[1] | startswith($kf + "/")))) or IN($na[]; $x)) | not)
        | "\(.) is named in the phase spec Files but in no task'"'"'s files and not in na_files"),
      ($na[] | select(IN($fs[]; .) | not) | "\(.) in na_files is not named in the phase spec")')
  [ -z "$out" ] || { echo "$out" >&2; exit 1; }
  out=$(jq -r --argjson t "$(task_claims "$d")" -n '
    ($t | map({(.id): .deps}) | add) as $d
    | def reach: {seen: [], todo: [.]}
        | until(.todo == []; .todo[0] as $c | .todo |= .[1:]
            | if IN(.seen[]; $c) then . else .seen += [$c] | .todo += ($d[$c] // []) end)
        | .seen;
    ($t | map({(.id): (.id | reach)}) | add) as $r
    | range(0; $t | length) as $i | range($i + 1; $t | length) as $j
    | $t[$i] as $a | $t[$j] as $b
    | select((IN($r[$a.id][]; $b.id) or IN($r[$b.id][]; $a.id)) | not)
    | [$a.claims[] | select(IN($b.claims[]))] | unique
    | select(length > 0)
    | map(if .[0] == "" then .[1] else "\(.[0]):\(.[1])" end) | join(", ")
    | "\($a.id) and \($b.id) have no dependency path but both plan \(.)"')
  [ -z "$out" ] || { echo "$out" >&2; exit 1; }
  out=$(jq -r -n --argjson t "$(task_claims "$d")" --slurpfile p "$d/plan.json" '
    ($t | map({(.id): .claims}) | add) as $f
    | $p[0].tasks[] | .id as $a | .dep_reasons as $r
    | if $r == null then "\($a) has no dep_reasons" else .deps[] as $b | $r[$b] as $why
    | if $why == null then "\($a) depends on \($b) with no dep_reasons entry"
      elif ($why | startswith("file ")) then $why[5:] as $x
        | select(any($f[$a][]; .[1] == $x and IN($f[$b][]; .)) | not)
        | "\($a) depends on \($b) for file \($x), which \($a) and \($b) do not both plan"
      else empty end end')
  [ -z "$out" ] || { echo "$out" >&2; exit 1; }
  local focus tag cids=() ids
  focus=$(jq -r '.focus[]?' "$pd/spec.json")
  if [ -n "$focus" ]; then
    for tag in $focus; do
      ids=$(criteria_ids "$tag") || exit 1
      cids+=($ids)
    done
    out=$(jq -r -n --slurpfile p "$pd/plan.json" '
      ($p[0].tasks | map(.criteria[]?)) as $tc
      | ($p[0].na_criteria // [] | map(.criterion)) as $na
      | $ARGS.positional as $ids
      | ($ids - ($tc + $na) | map("\(.) maps to no task and is not n/a")[]),
        (($tc + $na) - $ids | unique | map("\(.) is not a criterion of the phase focus")[])
      ' --args "${cids[@]}")
    [ -z "$out" ] || { echo "$out" >&2; exit 1; }
  fi
  local r rc=0
  while IFS= read -r r; do
    r=$(repo_path "$r" 2>/dev/null) || continue
    check_lint "$r" || rc=1
  done < <(claims "$d" | jq -r 'map(.[0]) | unique[]')
  [ $rc -eq 0 ] || exit 1
  local cl rn c cs x
  cl=$(claims "$d")
  while IFS= read -r rn; do
    ! jq -e --arg r "$rn" 'IN(.[]; [$r, ".forge/TESTING.md"])' <<<"$cl" >/dev/null || continue
    r=$(repo_path "$rn" 2>/dev/null) || continue
    cs=()
    for x in "All tests" Test "Changed tests" "Perf log"; do
      c=$(test_line "$r" "$x") || exit 1
      [ -z "$c" ] || cs+=("$c")
    done
    [ ${#cs[@]} -gt 0 ] || continue
    while IFS= read -r x; do
      test_file "$x" && [ ! -e "$r/$x" ] || continue
      for c in "${cs[@]}"; do ! covers "$r" "$c" "$x" || continue 2; done
      echo "forge: ${rn:+$rn:}$x is a new test file no command of $r/.forge/TESTING.md covers" >&2
      rc=1
    done < <(jq -r --arg r "$rn" '[.[] | select(.[0] == $r) | .[1]] | unique[]' <<<"$cl")
  done < <(jq -r 'map(.[0]) | unique[]' <<<"$cl")
  [ $rc -eq 0 ] || exit 1
  t=$(jq -r .track "$d/spec.json") f=$(jq -r .feature "$d/spec.json") fd=$state/features/$t-$f
  lock
  local a
  a=$(drop_union "$(claims "$d")")
  for m in $(numbers); do
    [ "$m" != "$n" ] || continue
    phase "$m"
    [ -f "$pd/plan.json" ] && [ -f "$pd/events.jsonl" ] || continue
    jq -se 'map(select(.step == "check" or .step == "replan" or .step == "retry")) | last.step == "check"' "$pd/events.jsonl" >/dev/null || continue
    ! jq -e --arg m "$m" 'IN(.depends[]; $m)' "$d/spec.json" >/dev/null || continue
    ! depends_on "$m" "$n" || continue
    ! merged "$m" 2>/dev/null || continue
    jq -ne --argjson a "$a" --argjson b "$(claims "$pd")" 'any($a[]; IN($b[]))' >/dev/null || continue
    ms+=("$m")
  done
  local x o
  for x in "$state"/phases/*/; do
    x=${x%/}
    [ "$x" != "$d" ] && [ -f "$x/plan.json" ] && ! passed "$x" || continue
    o=$(jq -r '"\(.track)/\(.feature)"' "$x/spec.json")
    [ "$o" != "$t/$f" ] || continue
    m=${x#"$state"/phases/} m=${m%%-*}
    x=$(jq -nr --argjson a "$a" --argjson b "$(claims "$x")" \
      '[$a[] | select(IN($b[]))] | unique | map(if .[0] == "" then .[1] else "\(.[0]):\(.[1])" end) | join(", ")')
    [ -n "$x" ] || continue
    echo "forge: warning: phase $n plans files that phase $m ($o) also plans: $x" >&2
    event "$d" overlap "phase $m ($o): $x"
  done
  if [ ${#ms[@]} -eq 0 ]; then
    checklog "$d" "plan ok"
    echo "plan ok"
    return
  fi
  jq '.depends += $ARGS.positional' "$d/spec.json" --args "${ms[@]}" >"$d/spec.json.new"
  mv "$d/spec.json.new" "$d/spec.json"
  jq --arg n "$n" '(.phases | map({(.number): .slug}) | add) as $s
    | .phases |= map(if .number == $n then .depends += [$ARGS.positional[] | $s[.]] else . end)' \
    "$fd/split.json" --args "${ms[@]}" >"$fd/split.json.new"
  mv "$fd/split.json.new" "$fd/split.json"
  for m in "${ms[@]}"; do event "$d" wait "files overlap phase $m"; done
  printf -v out '%s, ' "${ms[@]}"
  out="waits on ${out%, }"
  checklog "$d" "$out"
  echo "$out"
  exit 3
}

checklog() {
  jq -cn --arg time "$(date -u +%FT%TZ)" --arg message "$2" --arg plan "$(plansum "$1")" '{$time, step: "check", $message, $plan}' >>"$1/events.jsonl"
}

test_file() {
  local b=${1##*/}
  [[ /$1/ != */fixtures/* && /$1/ != */__fixtures__/* ]] || return 1
  [[ $b == *.test.* || $b == *.spec.* || $b == *_test.* || $b == test_*.py || /$1 == */__tests__/* ]]
}

covers() {
  local c=$2 p=$3 s w x a cmd named= seg=$';|&()`' sep=$'<>"\''
  local -a ws
  c=${c//\{test\}/} c=${c//\{files\}/}
  while [[ $c =~ \$\{[^{}]*\} ]]; do c=${c//"${BASH_REMATCH[0]}"/*}; done
  while [[ $c =~ \$([A-Za-z_][A-Za-z0-9_]*|[0-9@#?*!$-]) ]]; do c=${c//"${BASH_REMATCH[0]}"/*}; done
  while IFS= read -r s; do
    read -ra ws <<<"${s//[$sep]/ }"
    cmd=1
    for w in "${ws[@]}"; do
      case $w in do | then | else | elif | if | while | until | ! | time | \{ | \}) continue ;; esac
      [[ ! $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      a=$cmd cmd=
      w=${w##*=}
      [ -n "$w" ] || continue
      x=$w
      while [[ $x == ./* ]]; do x=${x#./}; done
      x=${x%/...} x=${x%/}
      case $x in "" | . | ...) return 0 ;; esac
      [[ $x != /* ]] || continue
      [[ $p != $x && $p != $x/* ]] || return 0
      if [[ $x == *[*?[]* ]]; then
        [[ $x != */* ]] && ! compgen -G "$1/$x" >/dev/null || named=1
      elif test_file "$x"; then
        named=1
      elif [[ $w == */* && -z $a ]] && [ ! -f "$1/$x" ]; then
        named=1
      fi
    done
  done <<<"${c//[$seg]/$'\n'}"
  [ -z "$named" ]
}

task_claims() {
  jq -c --slurpfile s "$1/spec.json" '[.tasks[] | (.repo // $s[0].repo // "") as $r | {id, deps, claims: [.files[] | [$r, .]]}]' "$1/plan.json"
}

claims() {
  task_claims "$1" | jq -c 'map(.claims[])'
}

drop_union() {
  local cl=$1 b rn r i v fs s u=()
  b=$(branch_of "$t/$f")
  while IFS= read -r rn; do
    r=$(repo_path "$rn" 2>/dev/null) || continue
    s=()
    ! git -C "$r" rev-parse -q --verify "$b^{commit}" >/dev/null || s=(--source "$b")
    mapfile -t fs < <(jq -r --arg r "$rn" '[.[] | select(.[0] == $r) | .[1]] | unique[]' <<<"$cl")
    i=0
    while IFS= read -r -d '' _ && IFS= read -r -d '' _ && IFS= read -r -d '' v; do
      [ "$v" != union ] || u+=("$rn" "${fs[i]}")
      i=$((i + 1))
    done < <(git -C "$r" check-attr "${s[@]}" -z merge -- "${fs[@]}" 2>/dev/null)
  done < <(jq -r 'map(.[0]) | unique[]' <<<"$cl")
  jq -c --argjson u "$(jq -nc '$ARGS.positional as $p | [range(0; $p | length; 2) as $i | $p[$i:$i + 2]]' --args "${u[@]}")" '. - $u' <<<"$cl"
}
