records() {
  local x
  fs=()
  for x in "$1"/review.json "$1"/review/*.json; do
    case ${x##*/} in reviewer.json | reviewer-*.json | audit.json | detect.json) continue ;; esac
    [ ! -f "$x" ] || fs+=("$x")
  done
}

pending() {
  local -a fs
  if [ -n "${2:-}" ]; then fs=("$2"); else records "$1"; fi
  [ ${#fs[@]} -eq 0 ] || jq -r '(.pending // [])[] | "  review: pending \(.) in \(input_filename)"' "${fs[@]}"
}

review_defs='def title: (.summary // "") | split(": ")[0];
def secclass($c): (title | test("^\\[(security|pii|auth)\\]")) or any($c.focus[]; . == "security" or . == "pii");
def highsec($c): .severity == "high" and secclass($c);
def owner_why($c): (.deferred.owner // "") as $o
  | if $o == "todo" then (if highsec($c) then "todo is not allowed on a high security-class finding" else "" end)
    elif ($o | test("^phase [0-9]{2,}$")) then $o[6:] as $n
      | if $c.phase == null then "no later phase for a feature or quick review"
        elif $n == $c.phase then "the current phase"
        elif any($c.split[]; . == $n) | not then "not a phase of \($c.pair)"
        elif any($c.undone[]; . == $n) | not then "phase \($n) is done"
        else "" end
    else "not phase <N> or todo" end;
def deferred_ok($c): .deferred != null and owner_why($c) == "";
def dismissed_ok($c): ((.dismissed // "") | IN("", [], {}) | not)
  and ((highsec($c) | not) or ((.dismissed | type) == "string" and (.dismissed | startswith("settled: "))));
def closed($c): .fixed == true or deferred_ok($c) or dismissed_ok($c);
def advisory: all(.[]; .source == "codex" and .severity == "medium");
'

undone_phases() {
  local fd=$state/features/${1/\//-} x
  [ -f "$fd/split.json" ] || return 0
  for x in $(jq -r '.phases[] | select(.number) | "\(.number)-\(.slug)"' "$fd/split.json"); do
    [ "${x%%-*}" != "${2:-}" ] || continue
    [ -f "$state/phases/$x/result.json" ] && jq -e '.status == "done"' "$state/phases/$x/result.json" >/dev/null && continue
    echo "$x"
  done
}

review_ctx() {
  local d=${1%/} n= tf= u= sp=null s='[]' fd
  [ ! -f "$d/spec.json" ] || sp=$(jq -c . "$d/spec.json") || return 1
  if [[ $d =~ (^|/)phases/([0-9]{2,})-[^/]+$ ]] && [ "$sp" != null ]; then
    n=${BASH_REMATCH[2]}
    tf=$(jq -r '"\(.track)/\(.feature)"' <<<"$sp") || return 1
    fd=$state/features/${tf/\//-}
    [ ! -f "$fd/split.json" ] || s=$(jq -c '[.phases[].number // empty]' "$fd/split.json") || return 1
    u=$(undone_phases "$tf" "$n") || return 1
  fi
  jq -nc --arg n "$n" --arg tf "$tf" --arg u "$u" --argjson sp "$sp" --argjson s "$s" \
    '{pair: $tf, phase: (if $n == "" then null else $n end), focus: ($sp.focus // []), split: $s, undone: ($u | split("\n") | map(select(. != "") | split("-")[0]))}'
}

open_findings() {
  local -a fs
  local c
  if [ -n "${2:-}" ]; then fs=("$2"); else records "$1"; fi
  [ ${#fs[@]} -gt 0 ] || { echo '[]'; return; }
  c=$(review_ctx "$1") || exit 1
  local raw
  raw=$(jq -c '(input_filename | (capture("/review/(?<r>[^/]+)\\.json$") | .r) // null) as $repo
    | .findings | to_entries[] | .value + {review: input_filename, index: .key, repo: $repo}' "${fs[@]}") ||
    { echo "forge: cannot read the review record(s) ${fs[*]}; nothing passes until they are valid" >&2; exit 1; }
  jq -sc --argjson c "$c" "$review_defs"'group_by([.repo, .file, .line, .summary])
      | map(select(any(.[]; closed($c)) | not)
        | (.[0] | {review, index, repo, file, line, severity, summary, security: secclass($c)}) + {advisory: advisory})' <<<"$raw"
}

blocking() {
  local x
  x=$(open_findings "$1") || exit 1
  pending "$1" || exit 1
  jq -r 'map(select(.severity != "low" and (.advisory | not)))[] | "  review: \(.file):\(.line) \(.severity): \(.summary)"' <<<"$x"
}

phase_gate() {
  local n=$1 d=$2 out= x id r
  [ -f "$d/plan.json" ] || return 0
  x=$(jq -r '.tasks[].id' "$d/plan.json") || die "cannot read $d/plan.json"
  for id in $x; do
    r=1
    [ ! -f "$d/tasks/$id.json" ] || { r=0; jq -e '.status == "done" or .status == "unmet"' "$d/tasks/$id.json" >/dev/null || r=$?; }
    [ $r -le 1 ] || die "cannot read $d/tasks/$id.json"
    [ $r -eq 0 ] || out+=$'\n'"  tasks: $id not committed through forge task-done: no $d/tasks/$id.json at status done"
  done
  [ -n "$out" ] || return 0
  die "phase $n is not done:$out
Commit each planned task without a done record through forge task-done, then rerun forge done $n."
}

landed() {
  local r b rs=("$root")
  [ ! -f "$fd/split.json" ] || phase_repos
  for r in "${rs[@]}"; do
    b=$(branch_of "$t/$f")
    git -C "$r" show-ref -q --verify "refs/heads/$b" || b=forge/$f
    if ! git -C "$r" show-ref -q --verify "refs/heads/$b"; then
      git -C "$r" log main --merges --format=%s | grep -xF "Merge branch '$(branch_of "$t/$f")'" >/dev/null ||
        die "$r has no branch forge/$t-$f or forge/$f and no land merge of forge/$t-$f on main; archive runs after land"
      continue
    fi
    git -C "$r" merge-base --is-ancestor "$b" main ||
      die "$b is not merged into main in $r; archive runs after land, and after its PR merges when ship opened one"
  done
}

fixes() {
  local x rec=${2:-}
  pair "$1"
  [ -d "$fd" ] || die "no $fd"
  [ -z "$rec" ] || [ -f "$rec" ] || die "no review record $rec"
  x=$(pending "$fd" "$rec") || exit 1
  [ -z "$x" ] || die "the review of $1 is not finished:
$x
For each pending part run its fallback forge-reviewer, append its findings to the review record and delete pending, then rerun forge fixes $1${rec:+ --record $rec}."
  x=$(open_findings "$fd" "$rec") || exit 1
  jq -c 'map(select(.advisory | not)) | group_by([.repo, .file])[] | {repo: .[0].repo, file: .[0].file, findings: map({index, severity, line, summary, review, security})}' <<<"$x"
}

branch_read() {
  local e s=0
  bx= be=
  [ -e "$1" ] || return 2
  e=$(mktemp)
  bx=$(cat -- "$1" 2>"$e") || s=1
  be=$(<"$e")
  rm -f "$e"
  return $s
}
