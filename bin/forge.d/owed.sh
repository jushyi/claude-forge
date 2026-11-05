owed() {
  local v r x d l rc=0 lines= todo=todo.md
  local -a add=()
  pair "$1"
  [ -d "$fd" ] || die "no $fd"
  v=$fd/verify.json r=$fd/requirements.json
  [ -f "$v" ] || die "no $v; nothing written"
  [ -f "$r" ] || die "no $r; nothing written"
  x=$(jq -er '.result' "$v") || die "cannot read result from $v; nothing written"
  [ "$x" = pass ] || die "$v has result '$x', not pass; nothing written"
  exec 8<"$fd" && flock 8 || die "cannot lock $fd; nothing written"
  lock "$root"
  d=$(mktemp -d "$fd/.owed.XXXXXX")
  jq --slurpfile v "$v" '
    ($v[0].manual_test | map(select(startswith("[note]") | not))) as $steps
    | .requirements |= map(
        .id as $id
        | [$steps[] | select(test("(^|[^A-Za-z0-9-])" + $id + "($|[^0-9])"))] as $named
        | ($named | map(select(test("^\\[(agent|operator|watched)\\]") | not))) as $open
        | if (.owed.kind | . == "moved" or . == "broken") then .done = false
          elif ($named | length) > 0 and ($open | length) == 0 then .done = true | del(.owed)
          else .done = false
            | .owed = ({
                kind: (if .owner == "post-ship" or $named != [] then "deferred" else "bookkeeping" end),
                check: (if .owner == "post-ship" then .text elif $named == [] then "no manual-test step names \($id)" else $open[0] end),
                owner: (.owed.owner // "operator")}
              + if .owed.until then {until: .owed.until} else {} end)
          end)' "$r" >"$d/requirements.json" || rc=1
  if [ $rc -eq 0 ]; then
    lines=$(jq -r '.requirements[] | if .done then "\(.id) done" else "\(.id) owed \(.owed.kind): \(.owed.check)" end' "$d/requirements.json") \
      && mapfile -t add < <(jq -r --arg tf "$1" '.requirements[] | select(.done | not) | "- \($tf) \(.id) owes \(.owed.kind): \(.owed.check)"' "$d/requirements.json") \
      && mv "$d/requirements.json" "$r" || rc=1
  fi
  rm -rf "$d"
  [ $rc -eq 0 ] || die "cannot settle $r, left unchanged"
  for l in "${add[@]}"; do
    [ -f "$todo" ] && grep -qxF -- "$l" "$todo" && continue
    { [ ! -s "$todo" ] || [ -z "$(tail -c 1 "$todo")" ] || echo; echo "$l"; } >>"$todo" || die "cannot append to .forge/$todo"
  done
  exec 8<&-
  [ -z "$lines" ] || echo "$lines"
}

owed_lines() {
  jq -r --arg p "$2" '.requirements[] | select(.owed)
    | "\($p)\(.id) (\(.owner // "agent")) owed \(.owed.kind) by \(.owed.owner): \(.owed.check)"' "$1" || die "cannot read $1"
}

owed_list() {
  local x r t f fd
  if [ $# -eq 1 ]; then
    pair "$1"
    for r in "$fd/requirements.json" "$state/archive/$t-$f/requirements.json"; do
      [ -f "$r" ] || continue
      owed_lines "$r" ""
      return
    done
    die "no requirements.json for $t/$f"
  fi
  for x in tracks/*.json; do
    [ -f "$x" ] || continue
    t=${x#tracks/} t=${t%.json}
    for f in $(jq -r '(.features[]?, .shipped[]?) | .feature' "$x"); do
      for r in "$state/features/$t-$f/requirements.json" "$state/archive/$t-$f/requirements.json"; do
        [ -f "$r" ] || continue
        owed_lines "$r" "$t/$f "
        break
      done
    done
  done
}
