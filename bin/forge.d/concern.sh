concern() {
  [ "${1:-}" = add ] && [ $# -ge 7 ] && [ "${*: -2:1}" = -- ] || usage
  local r=$2 area=$3 sev=$4 text=${!#} files=("${@:5:$#-6}") f d m c id new b ix lost
  [ -n "$area" ] && [ -n "$text" ] || usage
  case $sev in high | medium | low) ;; *) usage ;; esac
  for f in "${files[@]}"; do
    [ -n "$f" ] && [ "$f" != -- ] || usage
  done
  repos
  d=${dirs[$r]:-}
  [ -n "$d" ] || die "no repo $r under $root" 2
  m=$(git -C "$d" worktree list --porcelain | sed -n '1s/^worktree //p') && [ -n "$m" ] || die "cannot find the main worktree of $d"
  m=$m/$(git -C "$d" rev-parse --show-prefix) || die "cannot locate $d in its repo"
  m=${m%/}
  concern_add "$m" "$area" "$sev" "$text" "${files[@]}"
  echo "added $r:$id"
}

concern_add() {
  local m=$1 area=$2 sev=$3 text=$4 r=${1##*/} f c new b ix lost
  shift 4
  lock "$m"
  c=$m/.forge/concerns.json
  if [ -f "$c" ]; then
    jq -e '.concerns | type == "array"' "$c" >/dev/null 2>&1 || die "cannot read $c: not valid concerns JSON"
  fi
  if [ -f "$m/.forge/CONCERNS.md" ]; then
    lost=$(comm -23 <(sed -n 's/^- \(C-[0-9]*\) — .*/\1/p' "$m/.forge/CONCERNS.md" | sort -u) \
      <(if [ -f "$c" ]; then jq -r '.concerns[].id' "$c"; fi | sort -u) | paste -sd, | sed 's/,/, /g') || die "cannot read $m/.forge/CONCERNS.md"
    [ -z "$lost" ] || die "$m/.forge/CONCERNS.md lists $lost missing from $c; add them to concerns.json first, or re-rendering would drop them"
  fi
  new=$( { if [ -f "$c" ]; then cat "$c"; else echo '{"concerns": []}'; fi; } |
    jq --arg area "$area" --arg sev "$sev" --arg text "$text" --arg date "$(date +%F)" '
      (([.concerns[].id | capture("^C-(?<n>[0-9]+)$").n | tonumber] | max // 0) + 1) as $n
      | .concerns += [{id: ("C-" + (if $n < 10 then "0" else "" end) + ($n | tostring)), area: $area, files: $ARGS.positional, severity: $sev, evidence: [], status: "open", text: $text, date: $date}]
    ' --args "$@") || die "cannot add a concern to $c"
  id=$(jq -r '.concerns[-1].id' <<<"$new")
  mkdir -p "$m/.forge" || die "cannot create $m/.forge"
  b=$(mktemp -d) || die "cannot back up the concerns in $m"
  trap "rm -rf $(printf %q "$b")" EXIT
  for f in concerns.json CONCERNS.md; do
    [ ! -e "$m/.forge/$f" ] || cp -p "$m/.forge/$f" "$b/$f" || die "cannot back up $m/.forge/$f"
  done
  ix=$(git -C "$m" ls-files -s -- .forge/concerns.json .forge/CONCERNS.md) || die "cannot read the index of $m"
  { printf '%s\n' "$new" >"$c.new" && mv "$c.new" "$c"; } || { rm -f "$c.new"; die "cannot write $c"; }
  concerns_md "$m/.forge" || concern_undo "cannot render $m/.forge/CONCERNS.md"
  git -C "$m" add -- .forge/concerns.json .forge/CONCERNS.md || concern_undo "cannot stage the concerns in $m"
  git -C "$m" commit -q -m "docs(concerns): add $r:$id" -- .forge/concerns.json .forge/CONCERNS.md || concern_undo "cannot commit the concerns in $m"
}

concern_undo() {
  local f
  git -C "$m" rm -q -f --cached --ignore-unmatch -- .forge/concerns.json .forge/CONCERNS.md &&
    { [ -z "$ix" ] || git -C "$m" update-index --index-info <<<"$ix"; } ||
    echo "forge: cannot restore the index of $m" >&2
  for f in concerns.json CONCERNS.md; do
    if [ -e "$b/$f" ]; then cp -p "$b/$f" "$m/.forge/$f"; else rm -f "$m/.forge/$f"; fi || echo "forge: cannot restore $m/.forge/$f" >&2
  done
  die "$1"
}
