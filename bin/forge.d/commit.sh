wait_lock() {
  local h pid
  if ! flock -n "$1"; then
    h=$(cat "$2.holder" 2>/dev/null) || h=
    pid=${h%% *}
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || h="an unknown process"
    echo "forge: waiting for ${2##*/} (held by $h)" >&2
    flock "$1"
  fi
  echo "$$ $(ps -o args= -p $$) since $(date -u +%FT%TZ)" >"$2.holder"
}

lock() {
  local l
  [ -z "${locked:-}" ] || return 0
  if l=$(git -C "${1:-$root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    l+=/forge.lock
  else
    [ -d "${1:-$root}/.forge" ] || die "cannot lock ${1:-$root}: neither a git repo nor a .forge project"
    l=$(cd "${1:-$root}/.forge" && pwd)/forge.lock
  fi
  exec 9>"$l" || die "cannot open $l"
  wait_lock 9 "$l"
  locked=1
}

instate() {
  case $1 in
    features/* | phases/* | archive/*) ;;
    *) return 1 ;;
  esac
}

present() {
  if instate "$1"; then
    [ -f "$state/$1" ] || [ -n "$(ls -A "$state/$1" 2>/dev/null)" ]
  else
    [ -f "$1" ] || [ -n "$(ls -A "$1" 2>/dev/null)" ] || git -C "$root" cat-file -e "HEAD:.forge/$1" 2>/dev/null
  fi
}

phasedirs() {
  local d
  for d in "$state"/phases/*/ "$state"/archive/*/phases/*/; do
    d=${d%/}
    echo "${d#"$state"/}"
  done
}

owner() {
  local s
  s=$(cat "$state/$1/spec.json" 2>/dev/null) || return 0
  jq -r '"\(.track)/\(.feature)"' <<<"$s" 2>/dev/null | head -n1
}

scope() {
  local d o t= f= fd
  cands=()
  if [[ $1 =~ ^[0-9]+$ ]]; then
    for d in $(phasedirs); do
      [[ $d == phases/"$1"-* || $d == archive/*/phases/"$1"-* ]] || continue
      cands+=("$d")
      o=$(owner "$d")
      [ -z "$o" ] || { t=${o%%/*} f=${o#*/}; }
    done
    [ ${#cands[@]} -gt 0 ] || die "scope '$1' resolves to nothing"
    [ -z "$t" ] || { cands+=("features/$t-$f/split.json" "archive/$t-$f/split.json" "features/$t-$f/settled.json" "archive/$t-$f/settled.json"); feats=("$t/$f"); }
  elif [[ $1 == */* ]]; then
    pair "$1"
    feats=("$1")
    for d in $(phasedirs); do
      [ "$(owner "$d")" != "$t/$f" ] || cands+=("$d")
    done
    for d in "features/$t-$f" "archive/$t-$f"; do
      ! present "$d" || cands+=("$d")
    done
    [ ${#cands[@]} -gt 0 ] || die "scope '$1' resolves to nothing"
    cands+=("tracks/$t.json")
  else
    local m=() p
    for d in tracks/*.json; do
      t=${d#tracks/} t=${t%.json}
      for p in $(featscopes "$1" "$t"); do
        [[ " ${m[*]} " == *" $p "* ]] || m+=("$p")
      done
    done
    if [ -f "tracks/$1.json" ]; then
      [ ${#m[@]} -eq 0 ] || die "scope '$1' is both a track and a feature (${m[*]})"
      cands=("tracks/$1.json")
      for f in $(jq -r '.features[].feature, .shipped[].feature' "tracks/$1.json"); do
        cands+=("features/$1-$f")
        feats+=("$1/$f")
      done
    else
      [ ${#m[@]} -gt 0 ] || die "scope '$1' resolves to nothing"
      [ ${#m[@]} -eq 1 ] || die "scope '$1' is ambiguous: ${m[*]}"
      scope "${m[0]}"
    fi
  fi
}

featscopes() {
  local t
  for t in "${@:2}"; do
    if present "features/$t-$1" || present "archive/$t-$1"; then echo "$t/$1"; fi
    if [[ $1 == "$t"-* ]] && { present "features/$1" || present "archive/$1"; }; then echo "$t/${1#"$t"-}"; fi
  done
}

inscope() {
  local c
  for c in "${cands[@]}"; do
    [ "$1" != "$c" ] && [[ $1 != "$c"/* ]] || return 0
  done
  return 1
}

stage() {
  gi read-tree ${old:-"--empty"}
}

gi() { GIT_INDEX_FILE=$tmpd/index git -C "$root" "$@"; }

stray() {
  local wt x list=() ts=()
  wt=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$wt" != "$(cd "$root" && pwd -P)" ] && [ -d "$wt/.forge" ] || return 0
  for x in "${cands[@]}"; do
    [[ $x != tracks/* ]] || ts+=(".forge/$x")
  done
  [ ${#ts[@]} -gt 0 ] || return 0
  while IFS= read -r x; do
    list+=("$wt/${x:3}")
  done < <(git -C "$wt" -c core.quotePath=false status --porcelain --untracked-files=all -- "${ts[@]}")
  [ ${#list[@]} -eq 0 ] || echo "forge: warning: ${list[*]} changed in $wt/.forge, not in $root/.forge, so they are not committed; track files belong in $root/.forge" >&2
}

plansum() { sha256sum <"$1/plan.json" | cut -d' ' -f1; }

checked() {
  [ -f "$1/events.jsonl" ] && [ -f "$1/plan.json" ] || return 1
  jq -se --arg h "$(plansum "$1")" '(map(.step) | (rindex("check") // -1) > ([rindex("retry"), rindex("replan")] | map(. // -1) | max))
    and (map(select(.step == "check")) | last.plan == $h)' "$1/events.jsonl" >/dev/null
}

replanned() {
  [ -f "$1/events.jsonl" ] && [ -f "$1/plan.json" ] || return 1
  jq -se --arg h "$(plansum "$1")" 'map(select(.step == "check")) | length > 0 and last.plan != $h' "$1/events.jsonl" >/dev/null
}

gate() {
  local d x need=()
  d=("$state"/phases/"$1"-*/)
  [ ${#d[@]} -eq 1 ] || return 0
  d=${d[0]%/}
  case $2 in
    plan) need=(plan.json) ;;
    result) need=(result.json) ;;
  esac
  for x in "${need[@]}"; do
    [ -f "$d/$x" ] || die "step $2 of phase $1 needs $d/$x; nothing committed"
  done
  if [ "$2" = plan ]; then
    checked "$d" || die "step plan of phase $1 needs a passing forge check $1 after the last retry or replan whose plan sha256 matches $d/plan.json; nothing committed"
  elif replanned "$d"; then
    die "a changed plan.json of phase $1 needs a passing forge check $1 whose plan sha256 matches $d/plan.json; nothing committed"
  fi
}

reviewed() {
  local v=$state/features/${1%%/*}-${1#*/}/verify.json r p x miss=()
  [ "$(jq -r .result "$v" 2>/dev/null)" = pass ] || return 0
  r=$(feature_repos "$1") || die "cannot list the repos of $1; nothing committed"
  while read -r p x; do
    jq -e --arg r "$p" '.review_trees // {} | has($r)' "$v" >/dev/null 2>&1 || miss+=("$p")
  done <<<"$r"
  [ ${#miss[@]} -eq 0 ] || die "$v has result pass but no review_trees entry for ${miss[*]}; run the final review or its forge-reviewer fallback for ${miss[*]}; nothing committed"
}

differs() {
  [ -f "$1" ] && ! git -C "$root" cat-file -p "HEAD:.forge/$1" 2>/dev/null | cmp -s - "$1"
}

commit() {
  local branch p x d old new tmpd msg n i feats=() paths=() cands=() mine=() here=() staged=() swept=()
  branch=$(git -C "$root" branch --show-current)
  [ "$branch" = main ] || die "commit runs on main; $root is on '$branch'"
  lock
  scope "$1"
  [[ ! $1 =~ ^[0-9]+$ ]] || gate "$1" "$2"
  for x in "${@:3}"; do cands+=("${x#"$state"/}"); done
  planfiles
  files+=("$state"/features/*/events.jsonl)
  for x in "${files[@]}"; do
    p=${x#"$state"/}
    inscope "$p" || continue
    if [ "$p" = "$x" ]; then
      mine+=("$root/.forge/$x")
    else
      mine+=("$x")
      here+=("$x")
    fi
  done
  x=0
  [ ${#here[@]} -eq 0 ] || schemas "${here[@]}" || x=1
  for p in "${mine[@]}"; do links "$p" || x=1; done
  [ $x = 0 ] || die "planning JSON of scope $1 fails its schema; nothing committed"
  d=
  for p in PROJECT RULES REJECTED ARCHITECTURE STACK CONVENTIONS TESTING INTEGRATIONS; do
    if differs "$p.md"; then
      (cd "$root" && doc_lint ".forge/$p.md") || die "cannot read $root/.forge/$p.md; nothing committed"
      continue
    fi
    i=0
    git -C "$root" diff --cached --quiet HEAD -- ".forge/$p.md" 2>/dev/null || i=$?
    [ $i = 1 ] && git -C "$root" cat-file -e ":.forge/$p.md" 2>/dev/null || continue
    [ -n "$d" ] || d=$(mktemp -d)
    mkdir -p "$d/.forge"
    git -C "$root" cat-file blob ":.forge/$p.md" >"$d/.forge/$p.md" || { rm -rf "$d"; die "cannot read the index entry of $root/.forge/$p.md; nothing committed"; }
    (cd "$d" && doc_lint ".forge/$p.md") || { rm -rf "$d"; die "cannot read the index entry of $root/.forge/$p.md; nothing committed"; }
  done
  [ -z "$d" ] || rm -rf "$d"
  for p in "${feats[@]}"; do
    [ ! -f "$state/features/${p%%/*}-${p#*/}/verify.json" ] || reviewed "$p"
  done
  msg="forge($1): $2"
  tmpd=$(mktemp -d)
  trap "rm -rf '$tmpd'; [ -z \"\${held:-}\" ] || rm -f \"\$held\"" EXIT
  for i in 1 2 3; do
    old=$(git -C "$root" rev-parse -q --verify refs/heads/main) || old=
    stage
    paths=()
    swept=()
    for p in "${cands[@]}"; do
      instate "$p" || ! present "$p" || paths+=(".forge/$p")
    done
    while IFS= read -r -d '' x; do
      ! rendered "$x" || swept+=("$x")
    done < <(git -C "$root" ls-files -z -- .forge)
    paths+=("${swept[@]}")
    if [ ${#paths[@]} -gt 0 ]; then
      gi add -A -- "${paths[@]}"
      [ ${#swept[@]} = 0 ] || gi rm -q --cached --ignore-unmatch -- "${swept[@]}"
    fi
    if [ ${#paths[@]} -eq 0 ] || gi diff --cached --quiet ${old:+"$old"} -- "${paths[@]}"; then
      rm -rf "$tmpd"
      echo "forge: recorded $1 $2"
      stray
      [ "$2" != archive ] || push_main "$root"
      return 0
    fi
    rm -rf "$tmpd/v"
    staged=()
    while IFS= read -r -d '' x; do
      ! planning "$x" || ! inscope "${x#.forge/}" || staged+=("$x")
    done < <(gi ls-files -z -- "${paths[@]}")
    if [ ${#staged[@]} -gt 0 ]; then
      gi checkout-index --prefix="$tmpd/v/" -- "${staged[@]}"
      x=$(schemas "${staged[@]/#/$tmpd/v/}" 2>&1) || { echo "${x//"$tmpd/v/"/$root/}" >&2; die "planning JSON of scope $1 fails its schema; nothing committed"; }
    fi
    new=$(gi commit-tree "$(gi write-tree)" ${old:+-p "$old"} -m "$msg")
    publish "$1" && break
    new=
  done
  rm -rf "$tmpd"
  [ -n "$new" ] || die "main kept moving while committing $1; nothing committed"
  for x in "${swept[@]}"; do rm -f "$root/$x"; done
  n=$(git -C "$root" diff-tree -r --root --no-commit-id --name-only "$new" | wc -l)
  echo "forge: committed $(git -C "$root" rev-parse --short "$new") ($n files) $msg"
  [ "$2" != archive ] || push_main "$root"
}

commit_drop() {
  local branch msg=$1 old new tmpd tree i n paths=("${@:2}")
  branch=$(git -C "$root" branch --show-current)
  [ "$branch" = main ] || die "commit runs on main; $root is on '$branch'"
  lock
  tmpd=$(mktemp -d) || die "cannot make a temp dir; nothing committed"
  trap "rm -rf '$tmpd'; [ -z \"\${held:-}\" ] || rm -f \"\$held\"" EXIT
  for i in 1 2 3; do
    old=$(git -C "$root" rev-parse -q --verify refs/heads/main) || die "$root has no main commit; nothing committed"
    gi read-tree "$old" || die "cannot read main of $root; nothing committed"
    gi rm -r -q --cached --ignore-unmatch -- "${paths[@]}" || die "cannot drop ${paths[*]} from main of $root; nothing committed"
    tree=$(gi write-tree) || die "cannot write the tree of $root; nothing committed"
    if [ "$tree" = "$(git -C "$root" rev-parse "$old^{tree}")" ]; then
      rm -rf "$tmpd"
      return 0
    fi
    new=$(gi commit-tree "$tree" -p "$old" -m "$msg") || die "cannot commit in $root; nothing committed"
    publish "$msg" && break
    new=
  done
  rm -rf "$tmpd"
  [ -n "$new" ] || die "main kept moving while committing $msg; nothing committed"
  n=$(git -C "$root" diff-tree -r --no-commit-id --name-only "$new" | wc -l)
  echo "forge: committed $(git -C "$root" rev-parse --short "$new") ($n files) $msg"
}

publish() {
  local ix i x r=${ref:-refs/heads/main}
  ix=$(git -C "$root" rev-parse --path-format=absolute --git-path index) || die "cannot find the index of $root; nothing committed"
  for i in $(seq 50); do
    (set -C; : >"$ix.lock") 2>/dev/null && break
    [ "$i" -lt 50 ] || die "cannot lock the index of $root: $ix.lock exists; nothing committed"
    sleep 0.1
  done
  held=$ix.lock
  rm -f "$tmpd/sync"
  [ ! -f "$ix" ] || cp "$ix" "$tmpd/sync" || die "cannot copy the index of $root; nothing committed"
  x=$(GIT_INDEX_FILE=$tmpd/sync git -C "$root" reset -q "$new" -- "${paths[@]}" 2>&1) || die "cannot sync the index of $root ($x); nothing committed"
  for i in $(seq 50); do
    x=$(git -C "$root" update-ref -m "commit: $msg" "$r" "$new" "$old" 2>&1) && break
    if [ "$(git -C "$root" rev-parse -q --verify "$r")" != "$old" ]; then
      rm -f "$held"
      held=
      return 1
    fi
    [ "$i" -lt 50 ] || die "cannot move ${r#refs/heads/} to the commit of $1: $x"
    sleep 0.1
  done
  cat "$tmpd/sync" >"$held" && mv "$held" "$ix" ||
    die "committed $(git -C "$root" rev-parse --short "$new") but cannot write the index of $root; run: git -C $root reset -q -- ${paths[*]}"
  held=
}

rendered() {
  case $1 in
    .forge/tracks/*/*) return 1 ;;
    .forge/STATE.md | .forge/tracks/*.md) ;;
    *) return 1 ;;
  esac
}

planning() {
  case $1 in
    .forge/tracks/*/*) return 1 ;;
    .forge/tracks/*.json) ;;
    *) return 1 ;;
  esac
}
