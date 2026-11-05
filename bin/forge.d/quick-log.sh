quick_log() {
  local e dup
  [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "slug '$1' is not kebab-case; nothing written"
  [ -n "$2" ] || die "the task of $1 is empty; nothing written"
  dup=$(printf '%s\n' "${@:3}" | sort | uniq -d | paste -sd' ')
  [ -z "$dup" ] || die "repo $dup is named twice; nothing written"
  e=$(jq -nc --arg s "$1" --arg t "$2" --arg d "$(date +%F)" '{slug: $s, task: $t, repos: $ARGS.positional, date: $d}' --args "${@:3}") ||
    die "cannot build the quick entry for $1; nothing written"
  quicks_add "[$e]"
}

quick_import() {
  local q=$state/quicks.json have='[]' x d p l i m= g ts='[]' n path task
  local -a c=()
  local -A seen=()
  [ ! -f "$q" ] || have=$(jq -c '[.quicks[].slug]' "$q") || die "cannot read the slugs of $q; nothing written"
  for d in "$root" "$root"/*/; do c+=(0 "${d%/}"); done
  if [ -f "$root/.forge/repos.json" ]; then
    x=$(jq -r '.repos[]' "$root/.forge/repos.json") || die "cannot read $root/.forge/repos.json; nothing written"
    while IFS= read -r d; do
      [ -z "$d" ] || c+=(1 "$root/$d")
    done <<<"$x"
  fi
  for ((i = 0; i < ${#c[@]}; i += 2)); do
    l=${c[i]} d=${c[i + 1]}
    if ! p=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || [ ! "$p" -ef "$d" ]; then
      [ "$l" = 0 ] || die "$d, listed in $root/.forge/repos.json, is not a git repo; nothing written"
      continue
    fi
    [ -z "${seen[$p]:-}" ] || continue
    seen[$p]=1
    git -C "$p" rev-parse --verify -q refs/heads/main >/dev/null || continue
    x=$(git -C "$p" log refs/heads/main --format='%at%x09%ad%x09%s' --date=format-local:%F) || die "cannot read the history of $p; nothing written"
    m+=$(jq -cR --arg p "$p" --arg r "${p##*/}" --argjson l "$l" 'capture("^(?<at>[0-9]+)\t(?<date>[^\t]+)\tMerge pull request #(?<n>[0-9]+) from [^/ ]+/forge/quick-(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)$") | .at |= tonumber | . + {path: $p, repo: $r, linked: ($l == 1)}' <<<"$x")$'\n' ||
      die "cannot read the merges of $p; nothing written"
  done
  g=$(jq -cs --argjson have "$have" '(map(.slug) | unique) as $raw | group_by(.slug)
    | map(sort_by(.at) | reduce .[] as $q ([]; if length > 0 and (.[-1] | any(.[]; .path == $q.path) | not) then .[-1] += [$q] else . + [[$q]] end)
      | map(select(any(.[]; .linked | not))) | select(length > 0) | .[0][0].slug as $s
      | ([$s] + if length > 1 then [limit(length - 1; range(2; infinite) | "\($s)-\(.)" | select(IN($raw[]) | not))] else [] end) as $names
      | to_entries[] | .value[0] + {slug: $names[.key], repos: (.value | map(.repo) | unique)})
    | map(select(.slug as $s | any($have[]; . == $s) | not)) | sort_by(.at)' <<<"$m") || die "cannot group the merged quicks; nothing written"
  if [ "$g" = '[]' ]; then
    echo "forge: no new merged quicks to import"
    return 0
  fi
  x=$(jq -r '.[] | [.n, .path] | @tsv' <<<"$g") || die "cannot list the merged quicks; nothing written"
  while IFS=$'\t' read -r n path; do
    task=$(cd "$path" && gh pr view "$n" --json title -q .title </dev/null) || die "gh pr view $n failed in $path; nothing written"
    ts=$(jq -c --arg t "$task" '. + [$t]' <<<"$ts") || die "cannot record the title of PR #$n; nothing written"
  done <<<"$x"
  lock "$root"
  [ ! -f "$q" ] || have=$(jq -c '[.quicks[].slug]' "$q") || die "cannot read the slugs of $q; nothing written"
  g=$(jq -c --argjson t "$ts" --argjson have "$have" 'to_entries | map({slug: .value.slug, task: $t[.key], repos: .value.repos, date: .value.date})
    | map(select(.slug as $s | any($have[]; . == $s) | not))' <<<"$g") || die "cannot build the imported entries; nothing written"
  if [ "$g" = '[]' ]; then
    echo "forge: no new merged quicks to import"
    return 0
  fi
  quicks_add "$g"
}

quicks_add() {
  local q=$state/quicks.json new dup
  lock "$root"
  if [ -f "$q" ]; then
    new=$(jq --argjson n "$1" '.quicks += $n' "$q" 2>&1) || die "cannot append to $q ($new); nothing written"
  else
    new=$(jq -n --argjson n "$1" '{quicks: $n}') || die "cannot build $q; nothing written"
  fi
  dup=$(jq -r '[.quicks[].slug] | group_by(.) | map(select(length > 1)[0]) | join(", ")' <<<"$new") || die "cannot read the slugs of $q; nothing written"
  [ -z "$dup" ] || die "$q already holds slug $dup; nothing written"
  { printf '%s\n' "$new" >"$q.new" && mv "$q.new" "$q"; } || { rm -f "$q.new"; die "cannot write $q; nothing written"; }
  jq -r '.[] | "forge: recorded quick \(.slug)"' <<<"$1"
}
