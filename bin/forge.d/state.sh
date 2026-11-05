die() { echo "forge: $1" >&2; exit "${2:-1}"; }

usage() { help >&2; exit 2; }

pair() {
  [[ ${1:-} == */* ]] || die "expected <track>/<feature>, got '${1:-}'" 2
  t=${1%%/*} f=${1#*/} fd=$state/features/$t-$f
}

state_dir() {
  local r c d
  r=$(cd "$1" && pwd) || die "cannot resolve the root $1"
  if [ "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" -ef "$r" ] &&
    c=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [[ $c == */.git ]]; then
    r=$(cd "${c%/.git}" && pwd) || die "cannot resolve the main checkout of $1"
  fi
  d=${XDG_STATE_HOME:-$HOME/.local/state}/forge/${r##*/}
  if [ ! -f "$d/root" ]; then
    mkdir -p "$d" && echo "$r" >"$d/root.$$" || die "cannot write $d/root"
    ln "$d/root.$$" "$d/root" 2>/dev/null || [ -f "$d/root" ] || { rm -f "$d/root.$$"; die "cannot write $d/root"; }
    rm -f "$d/root.$$"
  fi
  c=$(cat "$d/root") || die "cannot read $d/root"
  [ "$c" -ef "$r" ] || die "state dir $d belongs to root $c, not $r"
  echo "$d"
}

planfiles() {
  files=(tracks/*.json "$state"/features/*/*.json "$state"/phases/*/*.json "$state"/phases/*/tasks/*.json "$state"/phases/*/events.jsonl)
}

project() {
  local prog=$1
  shift
  planfiles
  jq -n -r "$@" -L "$D" --arg state_dir "$state" --arg repo_dir "$root/.forge" "include \"forge\"; load(\$state_dir; \$repo_dir) as \$p | $prog" "${files[@]}" </dev/null
}

schema_for() {
  case $1 in
    */.forge/debug/*/probe/* | */merge/*.json) return 1 ;;
    */.forge/quick/*/spec.json) echo feature-spec ;;
    */.forge/quick/*/plan.json | */.forge/debug/*/plan.json) echo plan ;;
    */.forge/quick/*/tasks/*.json) echo task ;;
    */.forge/quick/*/review.json | */.forge/debug/*/review.json) echo review ;;
    tracks/*.json | .forge/tracks/*.json | */.forge/tracks/*.json) echo track ;;
    *features/*/requirements.json | *archive/*/requirements.json) echo requirements ;;
    *features/*/spec.json) echo feature-spec ;;
    *features/*/split.json) echo split ;;
    *features/*/verify.json) echo feature-verify ;;
    *features/*/ship.json) echo ship ;;
    *phases/*/tasks/*.json) echo task ;;
    *phases/*/plan.json) echo plan ;;
    *phases/*/review.json | *phases/*/review.prev.json) echo review ;;
    *phases/*/result.json) echo result ;;
    *features/*/review.json) echo review ;;
    *features/*/review/*.json | *phases/*/review/*.json) echo review ;;
    *) return 1 ;;
  esac
}

validate() {
  local x rc=0
  local -a md=() js=()
  for x; do
    case $x in
      .forge/PROJECT.md | .forge/RULES.md | .forge/REJECTED.md | .forge/ARCHITECTURE.md | .forge/STACK.md | .forge/CONVENTIONS.md | .forge/TESTING.md | .forge/INTEGRATIONS.md) md+=("$x") ;;
      */.forge/PROJECT.md | */.forge/RULES.md | */.forge/REJECTED.md | */.forge/ARCHITECTURE.md | */.forge/STACK.md | */.forge/CONVENTIONS.md | */.forge/TESTING.md | */.forge/INTEGRATIONS.md) md+=("$x") ;;
      *) js+=("$x") ;;
    esac
  done
  [ ${#md[@]} -eq 0 ] || doc_lint "${md[@]}" || rc=1
  [ $# -gt 0 ] && [ ${#js[@]} -eq 0 ] && return $rc
  schemas "${js[@]}" || rc=1
  for x in "${js[@]}"; do links "$x" || rc=1; done
  return $rc
}

doc_lint() {
  local x n rc=0
  for x; do
    n=$(wc -c <"$x") || { rc=1; continue; }
    [ "$n" -le 8192 ] || echo "forge: warning: $x:1: over 8 KB ($n bytes)" >&2
    FORGE_LINT_PATH=$x LC_ALL=C awk '
      function code(s,   o, m, r, t, off, k) {
        o = ""
        while (match(s, /`+/)) {
          o = o substr(s, 1, RSTART - 1)
          m = substr(s, RSTART, RLENGTH)
          r = substr(s, RSTART + RLENGTH)
          t = r
          off = 0
          k = 0
          while (match(t, /`+/)) {
            if (RLENGTH == length(m)) { k = off + RSTART; break }
            off += RSTART + RLENGTH - 1
            t = substr(t, RSTART + RLENGTH)
          }
          if (k) { o = o " "; s = substr(r, k + length(m)) } else { o = o m; s = r }
        }
        return o s
      }
      function flush(   c, t) {
        if (!on) return
        on = 0
        c = text
        gsub(/[\200-\277]/, "", c)
        if (length(c) > 300) print "forge: warning: " p ":" at ": bullet over 300 characters (" length(c) ")"
        t = " " tolower(code(text))
        if (match(t, /[^a-z0-9_](now |no longer|was |previously|used to)/)) print "forge: warning: " p ":" at ": history phrase \"" substr(t, RSTART + 1, RLENGTH - 1) "\""
      }
      BEGIN { p = ENVIRON["FORGE_LINT_PATH"] }
      {
        match($0, /^[ \t]*/)
        ind = RLENGTH
        body = substr($0, ind + 1)
        if (on && body != "" && ind > lvl && substr(body, 1, 2) != "- ") { text = text " " body; next }
        flush()
        if (substr(body, 1, 2) == "- ") { on = 1; lvl = ind; at = NR; text = body }
      }
      END { flush() }
    ' <"$x" >&2 || rc=1
  done
  return $rc
}

schemas() {
  local -A by=()
  local x s rc=0 out list py
  local -a args=()
  for x; do
    if s=$(schema_for "$x"); then
      by[$s]+=$x$'\n'
    elif [[ $x == *.jsonl ]]; then
      jq -nR '[inputs | fromjson]' "$x" >/dev/null 2>&1 || { echo "$x: not JSON lines" >&2; rc=1; }
    else
      jq -se 'length == 1' "$x" >/dev/null 2>&1 || { echo "$x: not JSON" >&2; rc=1; }
    fi
  done
  for s in "${!by[@]}"; do
    mapfile -t list <<<"${by[$s]%$'\n'}"
    args+=(--schemafile "$S/$s.schema.json" "${list[@]}")
  done
  if [ ${#args[@]} -gt 0 ]; then
    py=$(validator) || exit
    out=$("$py" "$D/validate.py" "${args[@]}" 2>&1) || { echo "$out" >&2; rc=1; }
  fi
  return $rc
}

validator() {
  local cj py
  cj=$(command -v check-jsonschema) && cj=$(readlink -f "$cj") || die "check-jsonschema is not on PATH"
  py=$(sed -n '1{s/^#! *//;s/^[^ ]*\/env  *//;s/ .*//;p}' "$cj")
  [ -n "$py" ] || die "no interpreter line in $cj"
  echo "$py"
}

namelimit() {
  local m=20
  [ "$1" = feature ] || m=16
  [ ${#2} -le $m ] || { echo "$1 name $2 is ${#2} characters, over the limit of $m"; return 1; }
}

state_of() {
  local x=${1%/}
  while [ -n "$x" ]; do
    x=${x%/*}
    case ${1#"$x"/} in
      phases/* | features/* | archive/*) [ ! -f "$x/root" ] || { echo "$x"; return 0; } ;;
    esac
  done
  return 1
}

links() {
  local d r b n f a k err rc=0 t
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/ || return 0
  if b=$(state_of "$d"); then
    r=$(<"$b/root") || { echo "$1: cannot read $b/root" >&2; return 1; }
  else
    r=${d%/.forge/*}
    [ "$r" != "$d" ] || return 0
    b=$r/.forge
  fi
  k=$(schema_for "$1") || case $1 in
    repos.json | .forge/repos.json | */.forge/repos.json) k=repos ;;
    *phases/*/spec.json) k=phase-spec ;;
  esac
  case $k in
    track)
      [ -z "${FORGE_NO_NAMELIMIT:-}" ] || return 0
      a=$(git -C "$r" show "HEAD:./.forge/tracks/${1##*/}" 2>/dev/null | jq -c . 2>/dev/null) || a=
      while read -r t n; do
        err=$(namelimit "$t" "$n") || { echo "$1: $err" >&2; rc=1; }
      done < <(jq -r --argjson h "${a:-null}" '($h // {}) as $h |
        (select(.track != $h.track) | "track \(.track)"),
        (.features[]?.feature | select(. as $f | [$h.features[]?.feature] | index($f) | not) | "feature \(.)")' "$1" 2>/dev/null) ;;
    repos)
      while read -r n; do
        echo "$1: more than one entry has the basename $n" >&2
        rc=1
      done < <(jq -r '.repos[] | rtrimstr("/") | split("/") | last' "$1" 2>/dev/null | sort | uniq -d) ;;
    split)
      while read -r n; do
        err=$(root=$r; repo_path "$n" 2>&1 >/dev/null) || { echo "$1: ${err#forge: }" >&2; rc=1; }
      done < <(jq -r '.phases[].repo // empty' "$1" 2>/dev/null | sort -u)
      f=$(dirname "$1")/spec.json
      a=$(jq -c '.focus // []' "$f" 2>/dev/null) || a=
      while read -r n; do
        echo "$1: phase $n not in the focus of $f" >&2
        rc=1
      done < <(jq -r --argjson a "${a:-[]}" '.phases[] | ((.focus // []) - $a) as $x | select($x | length > 0) | "\(.slug) focus \($x | join(", "))"' "$1" 2>/dev/null) ;;
    requirements)
      [ -f "$(dirname "$1")/ship.json" ] || return 0
      while read -r n; do
        echo "$1: $n" >&2
        rc=1
      done < <(jq -r '.requirements[]? |
        if .done == false and .owed == null then "requirement \(.id) is not done and has no owed"
        elif .done == true and .owed != null then "requirement \(.id) is done and has an owed"
        else empty end' "$1" 2>/dev/null) ;;
    phase-spec)
      n=$(jq -r '.focus // [] | join(", ")' "$1" 2>/dev/null)
      [ -n "$n" ] || return 0
      a=features
      case $d in "$b"/archive/*) a=archive ;; esac
      f=$b/$a/$(jq -r '"\(.track)-\(.feature)"' "$1")/spec.json
      if [ ! -f "$f" ]; then
        echo "$1: focus $n has no feature spec at $f" >&2
        rc=1
      else
        a=$(jq -c '.focus // []' "$f" 2>/dev/null) || a=
        n=$(jq -r --argjson a "${a:-[]}" '(.focus // []) - $a | join(", ")' "$1")
        [ -z "$n" ] || { echo "$1: focus $n not in the focus of $f" >&2; rc=1; }
      fi ;;
    feature-verify)
      n=$(jq -r '((.gaps // []) | length) as $n |
        if .result == "pass" and $n > 0 then "result pass with \($n) gaps"
        elif .result == "gaps" and $n == 0 then "result gaps with no gaps"
        else empty end' "$1" 2>/dev/null) || n=
      [ -z "$n" ] || { echo "$1: $n" >&2; rc=1; } ;;
  esac
  return $rc
}

feature_view() {
  local s
  pair "$1"
  s=$(jq -r --arg t "$t" --arg f "$f" 'select(.track == $t)
    | if any(.features[]; .feature == $f) then "open" elif any(.shipped[]; .feature == $f) then "shipped" else "none" end' tracks/*.json </dev/null) ||
    die "cannot read tracks/*.json"
  case $s in
    "") die "unknown track '$t' in $1" ;;
    none) die "unknown feature '$f' in track $t: $1" ;;
  esac
  planfiles
  [ -d "$fd" ] || files+=("$state/archive/$t-$f"/*.json)
  jq -n -r -L "$D" --arg t "$t" --arg f "$f" --arg state_dir "$state" --arg repo_dir "$root/.forge" \
    'include "forge"; load($state_dir; $repo_dir) as $p | feature_view($p; $t; $f)' "${files[@]}" </dev/null
}

status() {
  local g
  if [[ ${1:-} == */* ]]; then
    feature_view "$1"
    g=$(status_unmet "$1") || exit 1
    [ -z "$g" ] || printf '\n## Unmet tasks\n%s\n' "$g"
    return
  fi
  if [ "${1:-}" = --json ]; then
    status_json
    return
  fi
  local in= now d
  now=$(now_epoch) || now=null
  repos
  for d in "${!dirs[@]}"; do
    intake_add "$d" "${dirs[$d]}/.forge/todo.md" '{repo: $r, todos: todo_items}' -R -s
    intake_add "$d" "${dirs[$d]}/.forge/seeds.md" '{repo: $r, seeds: todo_items}' -R -s
    intake_add "$d" "${dirs[$d]}/.forge/concerns.json" '{repo: $r, concerns: [.concerns[] | select(.status == "open") | {date}]}'
  done
  if [ "${dirs[${root##*/}]:-}" != "$root" ]; then
    intake_add "${root##*/}" "$root/.forge/todo.md" '{repo: $r, todos: todo_items}' -R -s
    intake_add "${root##*/}" "$root/.forge/seeds.md" '{repo: $r, seeds: todo_items}' -R -s
  fi
  project 'status($p; $in; $now)' --slurpfile in <(printf '%s' "$in") --argjson now "$now"
  conflicts
  sessions_line
  port_warn
}

status_unmet() {
  local d l ts
  pair "$1"
  while IFS= read -r d; do
    d=${d%/spec.json}
    if [ -f "$d/result.json" ]; then
      l=$(jq -r --arg p "${d#"$state"/phases/}" '.unmet[]? | "\($p): unmet \(.task): \(.reason)"' "$d/result.json") || die "cannot read $d/result.json"
    else
      ts=("$d"/tasks/*.json)
      [ ${#ts[@]} -gt 0 ] || continue
      l=$(jq -rs --arg p "${d#"$state"/phases/}" 'map(select(.status == "unmet")) | sort_by(.id | ltrimstr("T") | tonumber? // .)[] | "\($p): unmet \(.id): \(.reason)"' "${ts[@]}") || die "cannot read the task records of $d"
    fi
    [ -z "$l" ] || printf '%s\n' "$l"
  done < <(jq -rn --arg t "$t" --arg f "$f" '[inputs | select(.track == $t and .feature == $f) | {n: (.number | tonumber? // .), p: input_filename}] | sort_by(.n)[] | .p' "$state"/phases/*/spec.json </dev/null)
}

now_epoch() {
  if [ -n "${FORGE_NOW:-}" ]; then
    date -d "$FORGE_NOW" +%s || die "cannot read FORGE_NOW '$FORGE_NOW'"
  else
    date +%s
  fi
}

intake_add() {
  [ -f "$2" ] || return 0
  local e
  e=$(jq -c -L "$D" --arg r "$1" "${@:4}" "include \"forge\"; $3" "$2" </dev/null 2>&1) || die "cannot read $2: $e"
  in+=$e$'\n'
}

status_json() {
  local d f c e h s= cf=() hf=() ta=(--arg todo "") q='[inputs | (input_filename | split("/") | .[-3]) as $r | .concerns[] | select(.status == "open")
    | {repo: $r, id, area, severity, focus: (.focus // [])}]'
  repos
  while IFS= read -r d; do
    f=${dirs[$d]}/.forge/concerns.json
    [ ! -e "$f" ] || cf+=("$f")
  done < <(printf '%s\n' "${!dirs[@]}" | sort)
  c=$(jq -n -c "$q" "${cf[@]}" </dev/null 2>/dev/null) || {
    for f in "${cf[@]}"; do
      e=$(jq -n "$q" "$f" 2>&1 >/dev/null </dev/null) || die "cannot read $f: $e"
    done
    die "cannot read concerns.json"
  }
  [ ! -f todo.md ] || ta=(--rawfile todo todo.md)
  [ ! -f seeds.md ] || s=$(cat seeds.md 2>&1) || die "cannot read $PWD/seeds.md: $s"
  for f in quicks debugs history; do
    [ ! -e "$state/$f.json" ] || hf+=("$state/$f.json")
  done
  h=$(jq -n -c '{quicks: [], debugs: [], repos: []} + ([inputs] | add // {})' "${hf[@]}" </dev/null 2>/dev/null) &&
    { [ ${#hf[@]} -eq 0 ] || e=$(schemas "${hf[@]}" 2>&1); } || {
    for f in "${hf[@]}"; do
      e=$(jq empty "$f" 2>&1 </dev/null) && e=$(schemas "$f" 2>&1) || die "cannot read $f: $e"
    done
    die "cannot read quicks.json, debugs.json or history.json"
  }
  planfiles
  files+=("$state"/features/*/events.jsonl)
  while IFS= read -r d; do
    [ ! -f "$state/archive/$d/requirements.json" ] || files+=("$state/archive/$d/requirements.json")
  done < <(jq -r 'select(.status == "open" or .status == "closed") | .track as $t | .shipped[] | "\($t)-\(.feature)"' tracks/*.json </dev/null)
  jq -n -L "$D" "${ta[@]}" --arg seeds "$s" --argjson c "$c" --argjson h "$h" --arg state_dir "$state" --arg repo_dir "$root/.forge" \
    'include "forge"; load($state_dir; $repo_dir) as $p | status_json($p; $todo; $seeds; $c; $h)' "${files[@]}" </dev/null
}

sessions_line() {
  local now log n=0 m e d agents dirs=("$root" "$(cd "$root" && pwd -P)")
  log=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/forge-reaped.log || log=
  if ! now=$(now_epoch); then
    echo "forge: warning: cannot read the time; removed unknown" >&2
    n=unknown
  elif [ -n "$log" ] && [ -f "$log" ]; then
    n=$(jq -nR --argjson now "$now" '[inputs | split("\t") | select(length == 3) | (try (.[0] | fromdate) catch null)
      | select(. != null and . > $now - 86400 and . <= $now)] | length' "$log") || { echo "forge: warning: cannot read $log" >&2; n=unknown; }
  fi
  if [ -f "$root/.forge/repos.json" ]; then
    e=$(jq -r '.repos[]' "$root/.forge/repos.json" 2>&1) || die "repos.json: $e"
    while IFS= read -r d; do
      [ -n "$d" ] && [ -d "$root/$d" ] || continue
      dirs+=("$(cd "$root/$d" && pwd)" "$(cd "$root/$d" && pwd -P)")
    done <<<"$e"
  fi
  if agents=$(claude agents --json --all </dev/null) && m=$(jq --arg r "${root##*/}" '[.[] | select(.kind == "background" and .state == "done")
    | select((.name // "") | if startswith($r + " ") then ltrimstr($r + " ")
      elif startswith($r + "/") and (ltrimstr($r + "/") | test("^[^ /]+ ")) then ltrimstr($r + "/") | sub("^[^ /]+ "; "")
      else null end
      | . != null and test("^((P[0-9]+(R[0-9]+)?|verify|ship|discuss) [^ /]+/[^ /]+|(quick|debug) .+|[^ /]+ (Phase [0-9]+( retry [0-9]+)?|Verify|Ship))$"))
    | (.cwd // "" | rtrimstr("/")) as $c | select(any($ARGS.positional[]; . as $d | $c == $d or ($c | startswith($d + "/"))))] | length' \
    --args "${dirs[@]}" <<<"$agents"); then
    m="$m idle"
  else
    echo "forge: warning: cannot list Claude sessions; idle unknown" >&2
    m="idle unknown"
  fi
  printf '\n## Sessions\n\n'
  echo "$n forge sessions removed in the last 24 h, $m"
}

port_warn() {
  local p=$HOME/.local/state/forge/port.pending now x r c age s bad= first=1
  [ -e "$p" ] || return 0
  now=$(now_epoch) || return 0
  x=$(jq -r --argjson now "$now" '[.repo // "", .commit // "", (try ($now - (.time | fromdate)) catch "bad")] | map(tostring) | join("\u001f")' "$p" 2>/dev/null) ||
    { echo "forge: warning: cannot read $p" >&2; return 0; }
  while IFS=$'\x1f' read -r r c age; do
    [ -n "$r$c$age" ] || continue
    [ "$age" != bad ] || { bad=1; continue; }
    [ "$age" -gt 3600 ] || continue
    { [ -n "$r" ] && s=$(git -C "$r" rev-parse -q --verify --short "$c^{commit}" 2>/dev/null); } || s=${c:0:7}
    [ -z "$first" ] || echo
    first=
    echo "warning: forge port $s queued $((age / 3600))h$((age % 3600 / 60))m"
  done <<<"$x"
  [ -z "$bad" ] || echo "forge: warning: cannot read $p" >&2
}

conflicts() {
  local d p b e out rc cands=("$root" "$root"/*/) lines=() branches
  local -A seen=()
  if [ -f "$root/.forge/repos.json" ]; then
    e=$(jq -r '.repos[]' "$root/.forge/repos.json" 2>&1) || die "repos.json: $e"
    while IFS= read -r d; do [ -z "$d" ] || cands+=("$root/$d"); done <<<"$e"
  fi
  for d in "${cands[@]}"; do
    p=$(cd "$d" 2>/dev/null && pwd -P) || continue
    [ -z "${seen[$p]:-}" ] || continue
    seen[$p]=1
    [ "$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" = "$p" ] || continue
    git -C "$p" rev-parse -q --verify refs/heads/main >/dev/null || continue
    mapfile -t branches < <(git -C "$p" for-each-ref --format='%(refname:short)' refs/heads/forge/)
    for b in "${branches[@]}"; do
      [ "$(git -C "$p" rev-list --count "main..$b")" -gt 0 ] || continue
      rc=0
      out=$(git -C "$p" merge-tree --write-tree --name-only --no-messages main "$b") || rc=$?
      case $rc in
        0) ;;
        1) lines+=("$(basename "$p") $b: $(sed 1d <<<"$out" | sed ':a;N;$!ba;s/\n/, /g')") ;;
        *) lines+=("$(basename "$p") $b: merge-tree failed") ;;
      esac
    done
  done
  [ ${#lines[@]} -gt 0 ] || return 0
  printf '\n## Conflicts\n\n'
  printf '%s\n' "${lines[@]}"
}
