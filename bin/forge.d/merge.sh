trim() {
  t=${1#"${1%%[![:space:]]*}"}
  t=${t%"${t##*[![:space:]]}"}
}

unquote_path() {
  local s=$1 i=0 c c2 oct
  path=
  while [ $i -lt ${#s} ]; do
    c=${s:i:1}
    if [ "$c" = '\' ]; then
      c2=${s:i+1:1}
      case $c2 in
        t) path+=$'\t' ;;
        n) path+=$'\n' ;;
        r) path+=$'\r' ;;
        a) path+=$'\a' ;;
        b) path+=$'\b' ;;
        f) path+=$'\f' ;;
        v) path+=$'\v' ;;
        [0-7])
          oct=${s:i+1:3}
          path+=$(printf '%b' "\\0$oct")
          i=$((i + 4))
          continue
          ;;
        *) path+=$c2 ;;
      esac
      i=$((i + 2))
    else
      path+=$c
      i=$((i + 1))
    fi
  done
}

merge_check() {
  local base out side ref l path hdr key n s t line status=0 i q
  local -A cnt loaded dropped=()
  local -a d=()
  git -C "$start" rev-parse --verify -q MERGE_HEAD >/dev/null || die "no merge in progress in $start"
  if [ $# -eq 1 ]; then
    jq empty "$1" 2>/dev/null || die "cannot read resolution record $1"
    mapfile -d '' -t d < <(jq -j '.files[]? | .path as $p | .dropped[]? | .side, "\u0000", $p, "\u0000", .line, "\u0000"' "$1" 2>/dev/null)
    for ((i = 0; i + 2 < ${#d[@]}; i += 3)); do
      trim "${d[i + 2]}"
      dropped[${d[i]}$'\n'${d[i + 1]}$'\n'$t]=1
    done
  fi
  base=$(git -C "$start" merge-base HEAD MERGE_HEAD) || die "no merge base for HEAD and MERGE_HEAD in $start"
  for side in ours theirs; do
    ref=HEAD
    [ $side = ours ] || ref=MERGE_HEAD
    out=$(git -C "$start" -c core.quotePath=false diff -M --unified=0 --no-color --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ "$base" $ref) || die "git diff failed in $start"
    cnt=() loaded=() hdr=1 path=
    while IFS= read -r l; do
      case $l in
        'diff --git '*) hdr=1 path=; continue ;;
      esac
      if [ $hdr = 1 ]; then
        case $l in
          '+++ b/'*) path=${l#'+++ b/'} path=${path%$'\t'} ;;
          '+++ "b/'*) q=${l#'+++ "b/'}; q=${q%'"'}; unquote_path "$q" ;;
          '+++ /dev/null') path= ;;
          '@@'*) hdr=0 ;;
        esac
        continue
      fi
      case $l in '+'*) ;; *) continue ;; esac
      trim "${l:1}"
      [ -n "$t" ] && [ -n "$path" ] || continue
      if [ -z "${loaded[$path]:-}" ]; then
        loaded[$path]=1
        if [ "$(git -C "$start" ls-files -s -- "$path" 2>/dev/null | awk '{print $1; exit}')" = 160000 ]; then
          loaded[$path]=2
        elif git -C "$start" cat-file -e ":0:$path" 2>/dev/null; then
          line=$t
          while IFS= read -r s || [ -n "$s" ]; do
            trim "$s"
            key=$path$'\n'$t
            n=${cnt[$key]:-0}
            cnt[$key]=$((n + 1))
          done < <(git -C "$start" show ":0:$path")
          t=$line
        fi
      fi
      [ "${loaded[$path]}" != 2 ] || continue
      key=$path$'\n'$t
      n=${cnt[$key]:-0}
      if [ "$n" -gt 0 ]; then
        cnt[$key]=$((n - 1))
        continue
      fi
      printf '%s %s: %s\n' $side "$path" "$t"
      [ -n "${dropped[$side$'\n'$key]:-}" ] || status=1
    done <<<"$out"
  done
  return $status
}

merge() {
  local top out current s=0 ms=0 p l paths=()
  local -A seen=()
  top=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $start"
  cd "$top"
  start=$top
  if [ "$1" = --abort ]; then
    git merge --abort || exit 1
    return 0
  fi
  if [ "$1" = --continue ]; then
    merge_continue "$2"
    return 0
  fi
  ! git rev-parse -q --verify MERGE_HEAD >/dev/null || die "a merge is already in progress in $top"
  out=$(git -c merge.conflictStyle=diff3 merge --no-ff --no-commit "$1" 2>&1) || s=$?
  if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    [ $s -ne 0 ] || return 0
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if [ $s -ne 0 ]; then
    mapfile -d '' -t paths < <(git diff --name-only -z --diff-filter=U)
    for p in "${paths[@]}"; do merge_json "$p"; done
    for p in "${paths[@]}"; do merge_docs "$p"; done
    out=$(git -c core.quotePath=false diff --name-only --diff-filter=U)
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      exit 4
    fi
    out=$(merge_check) || ms=$?
    if [ $ms -ne 0 ]; then
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      while IFS= read -r l; do
        p=${l#* } p=${p%%: *}
        [ -n "${seen[$p]:-}" ] || { seen[$p]=1; printf '%s\n' "$p"; }
      done <<<"$out"
      exit 4
    fi
  fi
  current=$(git branch --show-current)
  git commit -q -m "Merge branch '$1' into $current"
}

merge_continue() {
  local p l s=0 current
  git rev-parse -q --verify MERGE_HEAD >/dev/null || die "no merge in progress in $start"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "forge: unmerged $p" >&2
    s=1
  done < <(git -c core.quotePath=false diff --name-only --diff-filter=U)
  [ $s -eq 0 ] || exit 1
  merge_check "$1" || exit 1
  p=$(git rev-parse --git-path MERGE_MSG)
  IFS= read -r l <"$p" || die "cannot read $p"
  l=${l#*\'}
  current=$(git branch --show-current)
  git commit -q -m "Merge branch '${l%%\'*}' into $current"
}

merge_docs() {
  local p=$1 nl=1
  [[ $p == .forge/*.md && $p != .forge/*/* ]] || return 0
  git ls-files -u -- "$p" | awk '{n[$3] = 1} END {exit !(n[1] && n[2] && n[3])}' || return 0
  [ -z "$(tail -c1 "$p")" ] || nl=0
  awk -v nl=$nl '
    function flush(from, to,   i) { for (i = from; i <= to; i++) out[++n] = h[i] }
    s == 0 && /^<<<<<<<( |$)/ { s = 1; m = 0; h[++m] = $0; next }
    s == 1 && /^\|\|\|\|\|\|\|( |$)/ { s = 2; o = m; h[++m] = $0; b = m; next }
    s == 2 && /^=======( |$)/ { s = 3; e = m; h[++m] = $0; next }
    s == 3 && /^>>>>>>>( |$)/ {
      h[++m] = $0; s = 0
      if (e == b) { flush(2, o); flush(e + 2, m - 1) } else { flush(1, m); kept = 1 }
      next
    }
    s { h[++m] = $0; next }
    { out[++n] = $0 }
    END {
      if (s) { flush(1, m); kept = 1 }
      printf "" > FILENAME
      for (i = 1; i <= n; i++) printf "%s%s", out[i], (i < n || nl ? "\n" : "") > FILENAME
      exit kept
    }' "$p" || return 0
  git add -- "$p"
}

merge_json() {
  local p=$1 s keys m
  [[ $p == .forge/*.json ]] || return 0
  s=$(schema_for "$p") || s=
  git ls-files -u -- "$p" | awk '{n[$3] = 1} END {exit !(n[1] && n[2] && n[3])}' || return 0
  case $s in
    track) keys='{"features": "feature", "shipped": "feature"}' ;;
    requirements) keys='{"requirements": "id"}' ;;
    *) keys='{}' ;;
  esac
  m=$(jq -n --argjson keys "$keys" --slurpfile b <(git show ":1:$p") --slurpfile o <(git show ":2:$p") --slurpfile t <(git show ":3:$p") '
    def clash: error("forge:conflict");
    def pick($x; $y; $z): if $y == $z then $y elif $y == $x then $z elif $z == $x then $y else clash end;
    def opt($m; $k): if $m | has($k) then [$m[$k]] else [] end;
    def union($x; $y): $x + ($y - $x);
    def byid($a; $f):
      if all($a[]; type == "object" and has($f)) and ($a | map(.[$f]) | unique | length) == ($a | length)
      then reduce $a[] as $r ({}; .[$r[$f] | tojson] = $r) else clash end;
    def records($x; $y; $z; $f):
      byid($x; $f) as $X | byid($y; $f) as $Y | byid($z; $f) as $Z
      | [union($y | map(.[$f] | tojson); $z | map(.[$f] | tojson))[] as $k | pick(opt($X; $k); opt($Y; $k); opt($Z; $k))[]];
    def value($x; $y; $z; $f):
      if $f != null and ([$x, $y, $z] | all(length == 1 and (.[0] | type) == "array"))
      then [records($x[0]; $y[0]; $z[0]; $f)] else pick($x; $y; $z) end;
    try (
      if [$b, $o, $t] | all(length == 1 and (.[0] | type) == "object") then . else clash end
      | $b[0] as $B | $o[0] as $O | $t[0] as $T
      | reduce union($O | keys_unsorted; $T | keys_unsorted)[] as $k ({};
          value(opt($B; $k); opt($O; $k); opt($T; $k); $keys[$k]) as $v
          | if $v == [] then . else .[$k] = $v[0] end)
    ) catch (if . == "forge:conflict" then empty else error end)') || return 0
  [ -n "$m" ] || return 0
  printf '%s\n' "$m" >"$p"
  if jq -se 'length == 1' "$p" >/dev/null 2>&1 && { [ -z "$s" ] || validate "$p"; }; then
    git add -- "$p"
  else
    git -c merge.conflictStyle=diff3 checkout -m -- "$p"
  fi
}
