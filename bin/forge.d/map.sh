spawn() {
  (cd "$1" && claude --agent "$2" --effort "$3" --permission-mode "${FORGE_PERMISSION_MODE:-bypassPermissions}" -p "$4") >"$5" 2>&1
}

map() {
  repos
  local names=("$@") r d f doc docs pids=() rc=0 prompt out
  local paths=(.forge/{STACK,INTEGRATIONS,ARCHITECTURE,CONVENTIONS,TESTING,CONCERNS}.md .forge/concerns.json)
  [ $# -gt 0 ] || names=("${!dirs[@]}")
  for r in "${names[@]}"; do
    [ -n "${dirs[$r]:-}" ] || die "no repo $r under $root" 2
  done
  for r in "${names[@]}"; do
    d=${dirs[$r]}/.forge
    rm -rf "$d/map"
    mkdir -p "$d/map"
    for f in tech arch quality; do
      case $f in tech) docs="STACK INTEGRATIONS" ;; arch) docs=ARCHITECTURE ;; quality) docs="CONVENTIONS TESTING" ;; esac
      prompt="Repo root: ${dirs[$r]}"$'\n'"Focus: $f"$'\n'"Current docs:"
      for doc in $docs; do prompt+=" $d/$doc.md"; done
      spawn "${dirs[$r]}" forge-mapper medium "$prompt"$'\n'"Output: $d/map/$f.json" "$d/map/$f.log" &
      pids+=($!)
    done
    prompt="Repo root: ${dirs[$r]}"
    [ ! -f "$d/concerns.json" ] || prompt+=$'\n'"Current concerns: $d/concerns.json"
    spawn "${dirs[$r]}" forge-mapper-concerns high "$prompt"$'\n'"Output: $d/map/concerns.json" "$d/map/concerns.log" &
    pids+=($!)
  done
  for f in "${pids[@]}"; do wait "$f" || rc=1; done
  for r in "${names[@]}"; do
    d=${dirs[$r]}/.forge
    out=("$d/map/tech.json" "$d/map/arch.json" "$d/map/quality.json" "$d/map/concerns.json")
    [ $rc -ne 0 ] || { ls "${out[@]}" >/dev/null && validate "${out[@]}"; } || rc=1
  done
  [ $rc -eq 0 ] || die "mapping failed; logs in $(for r in "${names[@]}"; do printf '%s ' "${dirs[$r]}/.forge/map/"; done)"
  for r in "${names[@]}"; do
    d=${dirs[$r]}/.forge
    for f in tech arch quality; do
      for doc in $(jq -r '.docs[].doc' "$d/map/$f.json"); do
        jq -j -L "$D" --arg doc "$doc" --rawfile tpl "$T/$doc.md" \
          'include "forge"; .docs[] | select(.doc == $doc) | map_doc($tpl)' "$d/map/$f.json" >"$d/$doc.md"
      done
    done
    mv "$d/map/concerns.json" "$d/concerns.json"
    concerns_md "$d"
    rm -rf "$d/map"
    test_lint "${dirs[$r]}" || rc=1
    doc_lint "$d"/{STACK,INTEGRATIONS,ARCHITECTURE,CONVENTIONS,TESTING}.md
  done
  [ $rc -eq 0 ] || die "rendered docs failed the TESTING.md lint; docs not committed"
  for r in "${names[@]}"; do
    git -C "${dirs[$r]}" add -- "${paths[@]}"
    git -C "${dirs[$r]}" diff --cached --quiet -- "${paths[@]}" || git -C "${dirs[$r]}" commit -q -m "docs(map): map $r" -- "${paths[@]}"
  done
}

resolve() {
  if [ "$1" = --concern ]; then
    [[ ${2:-} =~ ^([^:=]+):(C-[0-9]{2,})$ ]] || die "expected <repo>:C-NN, got '${2:-}'" 2
    [ $# -le 3 ] || usage
    local r=${BASH_REMATCH[1]} id=${BASH_REMATCH[2]}
    repos
    repo_dirs "${@:3}"
    resolve_concern "$r" "$id"
    return
  fi
  pair "$1"
  shift
  [ -f "$fd/requirements.json" ] || die "no $fd/requirements.json"
  repos
  repo_dirs "$@"
  local r id
  jq -r '.requirements[] | select(.done and .concern) | .concern' "$fd/requirements.json" |
    while IFS=: read -r r id; do
      resolve_concern "$r" "$id"
    done
}

repo_dirs() {
  local a d
  for a; do
    [[ $a == *=* ]] || usage
    d=${a#*=}
    [[ $d == /* ]] || d=$start/$d
    dirs[${a%%=*}]=$d
  done
}

resolve_concern() {
  local d=${dirs[$1]:-} c
  [ -n "$d" ] || die "no repo $1 for $1:$2"
  c=$d/.forge/concerns.json
  jq -e --arg id "$2" 'any(.concerns[]; .id == $id)' "$c" >/dev/null 2>&1 || die "$1:$2 is not in $c"
  jq --arg id "$2" '(.concerns[] | select(.id == $id) | .status) = "resolved"' "$c" >"$c.new"
  mv "$c.new" "$c"
  concerns_md "$d/.forge"
  echo "resolved $1:$2"
}
