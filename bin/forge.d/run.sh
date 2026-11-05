forge_session_re='^([^/]+(/[^/]+)? (P[0-9]+(R[0-9]+)?|verify|ship) [^ /]+/[^ /]+|.+ [^ /]+ (Phase [0-9]+( retry [0-9]+)?|Verify|Ship)|.+ discuss( [^ ]+)?|.+ (quick|fast|new|debug|port)( .+)?)$'

session() {
  local s a
  s=$(jq -cn --argjson c "${4:-null}" --arg f "${FORGE_FOREGROUND_TASKS:-}" '($c // {}) * {env: ({CLAUDE_CODE_FORK_SUBAGENT: "0"} + if $f == "" then {} else {FORGE_FOREGROUND_TASKS: $f} end), disableBundledSkills: true, skillListingBudgetFraction: 0.0001, worktree: {bgIsolation: "none", baseRef: "head"}}') || return
  a=(-n "$2" --model opus --effort medium --permission-mode "${FORGE_PERMISSION_MODE:-bypassPermissions}" --settings "$s")
  [ -z "${5:-}" ] || a=(--resume "$5" -n "$2" --settings "$s")
  (cd "$1" && claude --bg "${a[@]}" "$3" </dev/null 9>&- 6>&-)
}

started() {
  local t o e s=0 x
  t=$(date +%s%3N)
  e=$(mktemp) || die "cannot create a temp file for the stderr of claude --bg"
  o=$(session "$@" 2>"$e") || s=$?
  cat "$e" >&2
  if [ $s != 0 ]; then
    x=$(sed '/^[[:space:]]*$/d' "$e" | tail -n1)
    if grep -q '^Workspace not trusted' "$e"; then
      o=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && o=${o%/.git} || o=$1
      bgerr="root $o is not trusted by Claude Code"
    else
      bgerr="claude --bg exited $s${x:+: $x}"
    fi
    rm -f "$e"
    return $s
  fi
  rm -f "$e"
  printf '%s\n' "$o"
  sid=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$o" | sed -n 's/^backgrounded · \([0-9a-f]\{8\}\) · .*/\1/p' | head -n1)
  [ -z "$sid" ] || return 0
  sid=$(claude agents --json --all </dev/null | jq -r --arg n "$2" --arg c "$1" --argjson t "$t" \
    '[.[] | select(.name == $n and .cwd == $c and (.startedAt // 0) >= $t)] | max_by(.startedAt) | .id // empty') ||
    { sid=; echo "forge: warning: cannot list Claude sessions to find the id of $2" >&2; }
}

tally() {
  local d=${XDG_RUNTIME_DIR:-$HOME/.local/state}/forge
  [ -z "${tallied:-}" ] || return 0
  [[ ${FORGE_MAX_SESSIONS:-$lim_sessions} =~ ^[1-9][0-9]*$ ]] || die "FORGE_MAX_SESSIONS must be a positive integer, got '$FORGE_MAX_SESSIONS'"
  mkdir -p "$d" || die "cannot create $d"
  exec 6>"$d/sessions.lock" || die "cannot open $d/sessions.lock"
  flock 6 || die "cannot lock $d/sessions.lock"
  retire
  nlive=$(claude agents --json </dev/null | jq -r --arg re "$forge_session_re" '[.[] | select((.name // "") | test($re))
    | select(.state | IN("blocked", "done", "failed", "stopped", "crashed") | not)] | length') || die "cannot list Claude sessions"
  tallied=1 nstarted=0
}

room() {
  local x avail
  tally
  if [ "$nlive" -ge "${FORGE_MAX_SESSIONS:-$lim_sessions}" ]; then
    waits="waits for a free session"
    echo "forge: $nlive forge sessions live; $1 $waits" >&2
    return 1
  fi
  avail=$(forge_mem_available) || die "cannot read MemAvailable from ${FORGE_PROC_ROOT:-/proc}/meminfo"
  if [ "$avail" -lt $(((lim_reserve_gib + nstarted) * 1048576)) ]; then
    waits="waits for memory"
    x=$((avail * 10 / 1048576))
    echo "forge: MemAvailable $((x / 10)).$((x % 10)) GiB; $1 $waits" >&2
    return 1
  fi
}

offset() {
  local x name id p r s n e j o so
  tally
  if [ -z "${held:-}" ]; then
    held=" "
    x=$(claude agents --json --all </dev/null | jq -r '.[] | select(.state | IN("crashed", "stopped") | not)
      | (.name // "") as $n | (($n | capture("^(?<p>[^ /]+)(/[^ ]*)? (P(?<n>[0-9]+)(R[0-9]+)?|verify) (?<t>[^ /]+)/(?<f>[^ /]+)$") | {p, n, s: "\(.t)-\(.f)"})
        // ($n | capture("^(?<p>[^ /]+)(/[^ ]*)? (?<s>[^ ]+) (Phase (?<n>[0-9]+)( retry [0-9]+)?|Verify)$")) // {}) as $m
      | (.cwd // "" | rtrimstr("/")) as $c | select($c | startswith("/")) | [.id // "-", $c, $n, $m.p // "", $m.s // "", $m.n // ""] | @tsv') || die "cannot list Claude sessions"
    while IFS=$'\t' read -r id r name p s n; do
      [ -n "$r" ] || continue
      if [ -z "$p" ]; then
        [[ $r =~ ^(.+)/\.claude/worktrees/([^/]+)$ ]] || continue
        r=${BASH_REMATCH[1]} s=${BASH_REMATCH[2]} n= e=()
        [[ ! $s =~ -([0-9]+)$ ]] || n=${BASH_REMATCH[1]}
        while [ -n "$r" ] && [ ${#e[@]} = 0 ]; do
          for j in "$r" "$r"/*; do
            state_at "$j" || continue
            [ ! -f "$so/features/$s/events.jsonl" ] || e+=("$so/features/$s/events.jsonl")
            [ -z "$n" ] || e+=("$so"/phases/"$n"-*/events.jsonl)
          done
          r=${r%/*}
        done
        for j in "${e[@]}"; do
          [ -f "$j" ] || continue
          o=$(jq -sr --arg i "$id" 'map(select(.step == "start" and .session == $i)) | last | .offset // empty' "$j") || die "cannot read $j"
          [ -z "$o" ] || held+="$o "
        done
        continue
      fi
      while [ -n "$r" ] && [ "${r##*/}" != "$p" ] && [ ! -d "$r/$p/.forge" ]; do r=${r%/*}; done
      [ -n "$r" ] || continue
      [ "${r##*/}" = "$p" ] || r+=/$p
      e=()
      if state_at "$r"; then
        if [ -n "$n" ]; then e=("$so"/phases/"$n"-*/events.jsonl); else e=("$so/features/$s/events.jsonl"); fi
      fi
      o=
      if [ -f "${e[0]:-}" ]; then
        o=$(jq -sr --arg n "$name" --arg i "$id" '(map(select(.step == "start" and .session == $i)) | last)
          // (map(select(.step == "start" and .message == $n)) | last) | .offset // empty' "${e[0]}") || die "cannot read ${e[0]}"
      fi
      [ -n "$o" ] || [ -z "$n" ] || o=$((10#$n % 100 * 10))
      [ -z "$o" ] || held+="$o "
    done <<<"$x"
  fi
  off=10
  while [[ $held == *" $off "* ]]; do off=$((off + 10)); done
  held+="$off "
}

state_at() {
  local c
  so=${XDG_STATE_HOME:-$HOME/.local/state}/forge/${1##*/}
  [ -f "$so/root" ] && c=$(<"$so/root") && [ -n "$c" ] && [ "$c" -ef "$1" ]
}

branch_of() { echo "forge/${1%%/*}-${1#*/}${2:+-$2}"; }

wt_of() { echo "$1/.claude/worktrees/${2%%/*}-${2#*/}${3:+-$3}"; }

paths() {
  local r n w
  [ $# -gt 0 ] || { echo "R=$root"; echo "STATE=$state"; return; }
  if [[ $1 =~ ^[0-9]{2,}$ ]]; then
    phase "$1"
    n=$1 t=$(jq -r .track "$pd/spec.json") f=$(jq -r .feature "$pd/spec.json") r=$(repo "$pd")
  else
    pair "$1"
    r=$root
    n=$(jq -r '[.phases[].number // empty] | sort | first // empty' "$fd/split.json" 2>/dev/null) || n=
    if [ -n "$n" ]; then
      phase "$n"
      r=$(repo "$pd")
    fi
    n= pd=
  fi
  w=$(wt_of "$r" "$t/$f" "$n")
  echo "R=$root"
  echo "F=$state/features/$t-$f"
  [ -z "$pd" ] || echo "P=$pd"
  echo "STATE=$state"
  echo "W=$w"
  echo "B=$(branch_of "$t/$f" "$n")"
  if [ -n "$n" ]; then echo "BASE=$(branch_of "$t/$f")"; else echo BASE=main; fi
  [ ! -d "$w" ] || { real "$w"; echo "G=$(git -C "$w" rev-parse --absolute-git-dir)"; }
}

repo_path() {
  local e
  [ -n "$1" ] || { echo "$root"; return; }
  [ ! -e "$root/$1/.git" ] || { echo "$root/$1"; return; }
  if [ -f "$root/.forge/repos.json" ]; then
    e=$(jq -r --arg n "$1" '[.repos[] | select(rtrimstr("/") | split("/") | last == $n)][0] // empty' "$root/.forge/repos.json" 2>&1) \
      || die "repos.json: $e"
    if [ -n "$e" ] && [ -d "$root/$e" ]; then (cd "$root/$e" && pwd); return; fi
  fi
  die "repo $1 is neither a git repo in $root nor a .forge/repos.json entry"
}

repo() {
  repo_path "$(jq -r '.repo // empty' "$1/spec.json")"
}

real() {
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" && pwd -P)" ] || die "$1 is not a git worktree; move it aside and rerun"
}

exclude() {
  local top x
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $1"
  ! git -C "$top" check-ignore -q .claude/worktrees/ || return 0
  x=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/info
  mkdir -p "$x" && { [ ! -s "$x/exclude" ] || sed -i '$a\' "$x/exclude"; } && echo .claude/worktrees/ >>"$x/exclude" ||
    die "cannot add .claude/worktrees/ to $x/exclude"
}

worktree() {
  local r=$1 b=$2 dir=$3 base=$4
  exclude "$r"
  if [ -d "$dir" ]; then
    real "$dir"
    return
  fi
  git -C "$r" worktree prune || return
  if git -C "$r" show-ref -q --verify "refs/heads/$b"; then
    git -C "$r" worktree add -q "$dir" "$b"
  else
    git -C "$r" worktree add -q -b "$b" "$dir" "$base"
  fi
}

numbers() { [ ! -f "$fd/split.json" ] || jq -r '.phases[].number // empty' "$fd/split.json" | sort; }

passed() { [ "$(jq -r .status "$1/result.json" 2>/dev/null)" = done ]; }

merged() {
  phase "$1"
  passed "$pd" && git -C "$(repo "$pd")" merge-base --is-ancestor "$(branch_of "$t/$f" "$1")" "$(branch_of "$t/$f")"
}

settled() {
  merged "$1" || jq -e '.status == "done" and any(.unmet[]?; .task == "sync")' "$pd/result.json" >/dev/null 2>&1
}

absorb() {
  local out s=0 b
  real "$1"
  out=$(git -C "$1" merge -q --no-ff -m "$4" "$3" 2>&1) || s=$?
  [ $s != 0 ] || return 0
  if ! git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    [ -z "$out" ] || echo "$out" >&2
    [ -z "${5:-}" ] || return 2
    exit $s
  fi
  conflicts=$(git -C "$1" -c core.quotePath=false diff --name-only --diff-filter=U | paste -sd ' ') || die "cannot list conflicts in $1"
  b=$(git -C "$1" branch --show-current) || die "cannot read the branch of $1"
  git -C "$1" merge --abort || die "git merge --abort failed in $1"
  event "$2" sync "conflict merging $3 into $b: $conflicts" || die "cannot log sync in $2"
  return 1
}

stale() {
  local x id s name
  x=$(jq -r --arg p "$1" '.[] | select((.state == "working" or .state == "blocked") | not) | select(.id != null and .state != null)
    | (.name // "") as $n | select($n | startswith($p))
    | ($n | ltrimstr($p) | capture("^(/[^ /]+)? (?<r>.*)$").r | (capture("^(P[0-9]+(R[0-9]+)?|verify|ship) (?<t>[^ /]+)/(?<f>[^ /]+)$") | "\(.t)-\(.f)")
      // (capture("^(?<s>[^ /]+) (Phase [0-9]+( retry [0-9]+)?|Verify|Ship)$") | .s)) as $s
    | [.id, $s, $n] | @tsv') || return 1
  while IFS=$'\t' read -r id s name; do
    [ -n "$id" ] && [ ! -d "$2/features/$s" ] && [ -d "$2/archive/$s" ] || continue
    echo "$id $name"
  done <<<"$x"
}

finished() {
  local tx=$HOME/.claude/projects/${2//[^a-zA-Z0-9]/-}/$3.jsonl x
  [ -z "$1" ] || [ ! -f "$1" ] || return 0
  if [ -z "$3" ] || [ ! -f "$tx" ]; then
    [ -z "${4:-}" ] || echo "forge: warning: no transcript $tx; keeping $4" >&2
    return 1
  fi
  x=$(jq -rs 'map(select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text) | last // ""' "$tx") ||
    { echo "forge: warning: cannot read the transcript $tx${4:+; keeping $4}" >&2; return 1; }
  awk '/^```/ {f = !f; next} !f && /^result:/ {r = 1} END {exit !r}' <<<"$x"
}

unlive() {
  local rec=$1 msg=$2 skip=$3 w=$4 x id name c sid a ids= live= left i=0
  local -A nm=()
  shift 4
  x=$(sessions --rows "$@") || die "cannot list Claude sessions"
  while IFS=$'\x1f' read -r id name c sid; do
    [ -n "$id$name" ] && { [ -z "$skip" ] || [ "$name" != "$skip" ]; } || continue
    if [ "$c" = "$w" ] && [[ $id =~ ^[0-9a-f]{8}$ ]] && finished "$rec" "$c" "$sid"; then
      ids+=" $id" nm[$id]=$name
    else
      live+="${live:+, }$name"
    fi
  done <<<"$x"
  if [ -n "$live" ]; then
    lr="$msg $live; not starting another"
    return 1
  fi
  for id in $ids; do
    claude rm "$id" </dev/null && continue
    a=$(claude agents --json --all </dev/null | jq --arg i "$id" 'any(.[]; .id == $i)') || die "cannot list Claude sessions"
    if [ "$a" != false ]; then
      lr="cannot remove the finished session ${nm[$id]} ($id) with claude rm; not starting another"
      return 1
    fi
  done
  while [ -n "$ids" ]; do
    left=$(claude agents --json --all </dev/null | jq -r --arg ids "$ids" '.[] | select(.state == "working" or .state == "blocked")
      | select(IN(.id; $ids | splits(" +") | select(. != ""))) | .id') || die "cannot list Claude sessions"
    [ -n "$left" ] || break
    if [ $i -ge 10 ]; then
      id=${left%%$'\n'*}
      lr="session ${nm[$id]} ($id) is finished but still running after claude rm; not starting another"
      return 1
    fi
    sleep 0.5
    i=$((i + 1))
  done
  for id in $ids; do echo "forge: removed the finished session ${nm[$id]} ($id)" >&2; done
}

reap() {
  local x d id k v name c sid
  local -a r=("$1")
  if [ -f "$1/.forge/repos.json" ]; then
    x=$(jq -r '.repos[]' "$1/.forge/repos.json") || return 1
    while IFS= read -r d; do
      if [ -n "$d" ] && [ -d "$1/$d" ]; then r+=("$(cd "$1/$d" && pwd)"); fi
    done <<<"$x"
  fi
  x=$(jq -r --arg p "${1##*/}" '.[] | select(.kind == "background" and .state == "done" and .id != null)
    | (.name // "") as $n | select($n | startswith($p))
    | (.cwd // "" | rtrimstr("/")) as $c | select($c != "" and any($ARGS.positional[]; . as $r | $c == $r or ($c | startswith($r + "/"))))
    | ($n | ltrimstr($p) | capture("^(/[^ /]+)? (?<r>.*)$").r | ((capture("^P(?<n>[0-9]+)(R[0-9]+)? [^ /]+/[^ /]+$") // capture("^[^ /]+ Phase (?<n>[0-9]+)( retry [0-9]+)?$")) | ["phase", .n])
      // (capture("^discuss (?<t>[^ /]+)/(?<f>[^ /]+)$") | ["discuss", "\(.t)-\(.f)"]) // (select(test("^(quick|debug) ")) | ["work", "-"])) as $k
    | [.id, $k[0], $k[1], $n, $c, (.sessionId // "")] | @tsv' --args "${r[@]}") || return 1
  while IFS=$'\t' read -r id k v name c sid; do
    [ -n "$id" ] || continue
    if [ "$k" = phase ]; then
      d=("$2/phases/$v"-*/)
      if [ ${#d[@]} -eq 1 ] && passed "${d[0]%/}" &&
        [ "$c" = "$(wt_of "$(repo "${d[0]%/}")" "$(jq -r '"\(.track)/\(.feature)"' "${d[0]}spec.json")" "$v")" ]; then echo "$id $name"; fi
      continue
    fi
    finished "" "$c" "$sid" "$name ($id)" || continue
    x=$(git -C "$c" status --porcelain --no-renames --untracked-files=no) ||
      { echo "forge: warning: cannot read the git status of $c; keeping $name ($id)" >&2; continue; }
    awk '{p = substr($0, 4)} p != "" && index(p, ".forge/") != 1 {d = 1} END {exit d}' <<<"$x" || continue
    echo "$id $name"
  done <<<"$x"
}

retire() {
  local a x k id name log q
  a=$(claude agents --json --all </dev/null) && x=$(stale "${root##*/}" "$state" <<<"$a" | sed 's/^/s /') && x+=$'\n'$(reap "$root" "$state" <<<"$a" | sed 's/^/r /') ||
    die "cannot list Claude sessions"
  x=$(awk 'NF && !s[$2]++' <<<"$x")
  [ -z "$x" ] || log=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/forge-reaped.log || die "cannot find the git dir of $root"
  while read -r k id name; do
    [ -n "$id" ] || continue
    q='.kind == "background" and .state == "done"'
    [ "$k" = r ] || q='.state != "working" and .state != "blocked"'
    if ! a=$(claude agents --json --all </dev/null | jq --arg id "$id" "any(.[]; .id == \$id and ($q))"); then
      echo "forge: warning: cannot recheck session $id; keeping $name" >&2
      continue
    fi
    [ "$a" = true ] || continue
    if ! claude rm "$id" </dev/null; then
      echo "forge: warning: cannot remove session $id" >&2
      continue
    fi
    echo "forge: removed $name ($id)" >&2
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$name" >>"$log" || echo "forge: warning: cannot log the removal of $id to $log" >&2
  done <<<"$x"
}

launch() {
  local n=$1 d r k name db id env b bn w s x g= sid
  phase "$n"
  sid=$(sid_of "$pd") || exit
  if [ -f "$pd/events.jsonl" ]; then
    g=$(jq -sr 'if (map(.step) | (rindex("wait") // -1) > (rindex("start") // -1)) then map(select(.step == "start")) | last.message // empty else empty end' "$pd/events.jsonl") ||
      die "cannot read $pd/events.jsonl"
  fi
  r=$(repo "$pd") || exit
  w=$(wt_of "$r" "$t/$f" "$n")
  if [ -n "$g" ]; then
    x=$(claude agents --json --all </dev/null) || die "cannot list Claude sessions"
    s=$(jq -r --arg n "$g" --arg i "$sid" --arg w "$w" '.[] | select((.name == $n or .id == $i) and ((.cwd // "") | rtrimstr("/")) == $w) | .id' <<<"$x") || die "cannot list Claude sessions"
    for id in $s; do
      claude rm "$id" </dev/null || { launch_refused phase "$n" "cannot remove session $g of phase $n, which logged wait; not starting another"; return 10; }
    done
    x=$(jq -r --arg n "$g" --arg i "$sid" --arg w "$w" '.[] | select((.name == $n or .id == $i) and (.state == "working" or .state == "blocked") and ((.cwd // "") | rtrimstr("/")) != $w) | .id' <<<"$x") ||
      die "cannot list Claude sessions"
    if [ -n "$x" ]; then
      launch_refused phase "$n" "session $g of phase $n is also live outside $w; not starting another"
      return 10
    fi
  fi
  tally
  if ! unlive "$pd/result.json" "phase $n already has a live session" "$g" "$w" "P$n(R[0-9]+)?" "Phase $n( retry [0-9]+)?" "$sid"; then
    launch_refused phase "$n" "$lr"
    return 10
  fi
  room "phase $n" || return 11
  d=$pd b=$(branch_of "$t/$f") bn=$(branch_of "$t/$f" "$n")
  worktree "$r" "$b" "$(wt_of "$r" "$t/$f")" HEAD || die "cannot create the worktree of $b in $r"
  worktree "$r" "$bn" "$w" "$b" || die "cannot create the worktree of $bn in $r"
  s=0
  absorb "$w" "$d" "$b" "Merge branch '$b' into $bn" soft || s=$?
  if [ "$s" = 2 ]; then
    launch_refused phase "$n" "worktree $w has uncommitted changes"
    return 10
  fi
  k=0
  if [ -f "$d/events.jsonl" ]; then
    k=$(jq -s 'map(select(.step == "retry")) | length' "$d/events.jsonl") || die "cannot read $d/events.jsonl"
  fi
  name=${root##*/}
  [ "$r" = "$root" ] || name+="/${r##*/}"
  name+=" P$n"
  [ "$k" = 0 ] || name+="R$k"
  name+=" $t/$f"
  db=${root##*/} db=${db//[^a-zA-Z0-9]/_}_test_$n
  offset
  env=$(jq -nc --arg o "$off" --arg db "$db" --arg r "$root" --arg n "$n" \
    '{env: {FORGE_PORT_OFFSET: $o, FORGE_TEST_DB: $db, FORGE_ROOT: $r, FORGE_PHASE: $n}}') ||
    die "cannot build the settings of $name"
  s=$(claude agents --json --all | jq -r --arg n "$name" '.[] | select(.name == $n) | .id') || die "cannot list Claude sessions"
  for id in $s; do claude rm "$id" </dev/null || true; done
  if ! started "$w" "$name" "/forge-phase $root $n" "$env"; then
    launch_refused phase "$n" "$bgerr" held
    return 12
  fi
  nlive=$((nlive + 1)) nstarted=$((nstarted + 1))
  event "$d" start "$name" "$off" "$sid" || die "started $name but cannot log its start in $d/events.jsonl"
}

sid_of() {
  [ ! -f "$1/events.jsonl" ] || jq -sr 'map(select(.step == "start")) | last | .session // empty' "$1/events.jsonl" ||
    die "cannot read $1/events.jsonl"
}

running() {
  [ ! -f "$1/result.json" ] && [ -f "$1/events.jsonl" ] &&
    jq -se 'map(.step) | (rindex("start") // -1) > ([rindex("wait"), rindex("retry"), rindex("replan")] | map(. // -1) | max)' \
      "$1/events.jsonl" >/dev/null
}

held_add() {
  local d=${XDG_STATE_HOME:-$HOME/.local/state}/forge x tm=${FORGE_HELD_SINCE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  local h=$d/held.jsonl
  held_new=
  if mkdir -p "$d" && {
    flock 5 && x=false && { [ ! -f "$h" ] || x=$(jq -s --arg r "$root" --arg k "$1" --arg g "$2" 'any(.[]; .root == $r and .kind == $k and .target == $g)' "$h"); } &&
      { [ "$x" = true ] || { jq -nc --arg r "$root" --arg k "$1" --arg g "$2" --arg tm "$tm" '{root: $r, kind: $k, target: $g, time: $tm}' >>"$h" && held_new=1; }; }
  } 5>>"$h.lock"; then
    echo "forge: recorded the held $1 $2; forge watchdog starts it once room frees" >&2
  else
    echo "forge: warning: cannot record the held $1 $2 in $h" >&2
    held_new=1
  fi
}

launch_refused() {
  local new=1 d= x=()
  if [ -n "${4:-}" ]; then
    held_add "$1" "$2"
    new=$held_new
  fi
  echo "forge: $1 $2 not started: $3" >&2
  if [ -z "${4:-}" ]; then
    if [ "$1" = phase ]; then
      x=("$state"/phases/"$2"-*/)
      [ ${#x[@]} != 1 ] || d=${x[0]%/}
    else
      d=$state/features/${2/\//-}
    fi
    if [ -z "$d" ] || [ ! -d "$d" ]; then
      echo "forge: warning: cannot find the directory of $1 $2 to log its refused event" >&2
    elif ! event "$d" refused "$1 $2 not started: $3"; then
      echo "forge: warning: cannot log the refused event of $1 $2 in $d/events.jsonl" >&2
    fi
  fi
  refused=1
  [ -n "$new" ] && [[ ${notified:-} != *"|$1 $2|"* ]] || return 0
  notified="${notified:-|}$1 $2|"
  notify "forge: launch refused" "${root##*/} $1 $2: $3" || true
}

exit_refused() {
  [ -z "${refused:-}" ] || exit 8
}

advance() {
  local n x s k e live act sid all=1 run=0 i=0 due=()
  tally
  x=$(claude agents --json --all </dev/null) || die "cannot list Claude sessions"
  live=$(jq -r '.[] | select(.state | IN("crashed", "stopped") | not) | .id, .name' <<<"$x") || die "cannot list Claude sessions"
  act=$(jq -r '.[] | select(.state | IN("crashed", "stopped", "blocked") | not) | .id, .name' <<<"$x") || die "cannot list Claude sessions"
  for n in $(numbers); do
    settled "$n" && continue
    all=0
    if running "$pd"; then
      s=$(jq -sr 'map(select(.step == "start")) | last | "\(.session // .message)\t\(.message)"' "$pd/events.jsonl") || die "cannot read $pd/events.jsonl"
      k=${s%%$'\t'*} s=${s#*$'\t'}
      if grep -qxF "$k" <<<"$act"; then
        run=$((run + 1))
        continue
      fi
      grep -qxF "$k" <<<"$live" && continue
      echo "forge: phase $n's session $s is gone; relaunching it" >&2
    fi
    [ -f "$pd/result.json" ] && continue
    for x in $(jq -r '.depends[]' "$pd/spec.json"); do settled "$x" || continue 2; done
    due+=("$n")
  done
  if [ $all = 0 ]; then
    for n in "${due[@]}"; do
      [ $run -lt "${FORGE_CONCURRENCY:-$lim_concurrency}" ] || break
      launch $n || case $? in
        10) ;;
        11)
          for x in "${due[@]:i}"; do held_add phase "$x"; done
          break
          ;;
        12)
          i=$((i + 1))
          continue
          ;;
        *) exit 1 ;;
      esac
      run=$((run + 1)) i=$((i + 1))
    done
    return
  fi
  phase "$(numbers | head -n1)"
  x=$(repo "$pd")
  [ ! -f "$fd/verify.json" ] || return 0
  sid=$(sid_of "$fd") || exit
  if ! unlive "$fd/verify.json" "$t/$f already has a live session" "" "$(wt_of "$x" "$t/$f")" verify Verify "$sid"; then
    launch_refused verify "$t/$f" "$lr"
    return 0
  fi
  room "$t/$f Verify" || { held_add verify "$t/$f"; return 0; }
  s=${root##*/}
  [ "$x" = "$root" ] || s+="/${x##*/}"
  s+=" verify $t/$f"
  x=$(wt_of "$x" "$t/$f")
  offset
  started "$x" "$s" "/forge-verify $root $t/$f" "$(jq -nc --arg o "$off" --arg r "$root" '{env: {FORGE_PORT_OFFSET: $o, FORGE_ROOT: $r}}')" ||
    { launch_refused verify "$t/$f" "$bgerr" held; return 0; }
  event "$fd" start "$s" "$off" "$sid" || die "started $s but cannot log its start in $fd/events.jsonl"
}

implement() {
  pair "$@"
  [ -f "$fd/split.json" ] || die "no $fd/split.json"
  ready "$1" >/dev/null || die "$1 waits on unshipped features"
  local s
  s=$(sessions --names)
  [ -z "$s" ] || die "$1 already has a live session ${s//$'\n'/, }; not starting another"
  lock
  collision
  advance
  exit_refused
}

collision() {
  local n r b
  b=$(branch_of "$t/$f")
  for n in $(numbers); do
    phase "$n"
    [ ! -f "$pd/events.jsonl" ] && [ ! -f "$pd/result.json" ] || return 0
  done
  phase_repos
  for r in "${rs[@]}"; do
    ! git -C "$r" show-ref -q --verify "refs/heads/$b" || die "$r already has branch $b; delete it or pick another feature name"
  done
}

finish() {
  local n=$1 d r x ts b bn w=1 dv=[] re=()
  phase "$n"
  d=$pd
  [ -f "$d/result.json" ] || die "no $d/result.json"
  t=$(jq -r .track "$d/spec.json") f=$(jq -r .feature "$d/spec.json") fd=$state/features/$t-$f
  ! passed "$d" || phase_gate "$n" "$d" "$(wt_of "$(repo "$d")" "$t/$f" "$n")"
  lock
  if passed "$d"; then
    r=$(repo "$d") b=$(branch_of "$t/$f") bn=$(branch_of "$t/$f" "$n")
    ! merged "$n" || w=0
    if jq -e 'any(.unmet[]?; .task == "sync")' "$d/result.json" >/dev/null; then
      echo "forge: phase $n done with sync unmet"
    else
      absorb "$(wt_of "$r" "$t/$f")" "$d" "$bn" "Merge branch '$bn': phase $n ${d#"$state"/phases/*-}" ||
        die "$bn conflicts with $b in $conflicts; merge $b into $bn and rerun forge done $n" 6
    fi
    ts=("$d"/tasks/*.json)
    if [ $w = 1 ] && [ ${#ts[@]} -gt 0 ] && [ -f "$d/plan.json" ]; then
      dv=$(jq -sc --slurpfile p "$d/plan.json" '[.[] | select((.deviation // "") != "" and .deviation_kind == "interface") | .id] as $i | [$p[0].tasks[] | select(IN(.id; $i[])) | .files[]] | unique' "${ts[@]}")
    fi
    if [ "$dv" != "[]" ]; then
      for x in "$state"/phases/*/spec.json; do
        x=${x%/spec.json}
        [ -f "$x/plan.json" ] && jq -e --arg n "$n" 'IN(.depends[]; $n)' "$x/spec.json" >/dev/null || continue
        [ ! -f "$x/result.json" ] || [ "$(jq -r .status "$x/result.json")" != done ] || continue
        jq -e --argjson v "$dv" 'any(.tasks[].files[]; IN(.; $v[]))' "$x/plan.json" >/dev/null || continue
        replan "$x"
        event "$x" replan "phase $n deviated"
        re+=("$x")
      done
    fi
  fi
  [ ${#re[@]} -eq 0 ] || commit "$n" done "${re[@]}"
  advance
  exit_refused
}

next() {
  pair "$@"
  local v=$fd/verify.json n s k x
  lock
  [ -f "$v" ] || die "no $v"
  [ -f "$fd/split.json" ] || die "no $fd/split.json"
  for n in $(jq -r '.gaps[].phase' "$v"); do
    jq -e --arg n "$n" 'any(.phases[]; .number == $n)' "$fd/split.json" >/dev/null || die "gap names phase $n, not in $t/$f"
  done
  if [ "$(jq -r .result "$v")" = pass ]; then
    x=$(jq -r --slurpfile s "$fd/split.json" '[$s[0].phases[].requirements[]?] as $m | [.requirements[] | select((.owner // "agent") == "agent") | .id | select(IN($m[]) | not)] | join(" ")' \
      "$fd/requirements.json") || die "cannot read $fd/requirements.json"
    if [ -n "$x" ]; then
      launch_refused ship "$t/$f" "requirement(s) $x map to no phase"
      exit_refused
    fi
    s=$(sessions --names ship Ship) || die "cannot list the sessions of $t/$f"
    if [ -n "$s" ]; then
      launch_refused ship "$t/$f" "$t/$f already has a live session $s; not starting another"
      exit_refused
    fi
    room "$t/$f Ship" || { held_add ship "$t/$f"; return 0; }
    started "$root" "${root##*/} ship $t/$f" "/forge-ship $root $t/$f" "$(jq -nc --arg r "$root" '{env: {FORGE_ROOT: $r}}')" ||
      { launch_refused ship "$t/$f" "$bgerr" held; exit_refused; }
    return
  fi
  for n in $(jq -r '[.gaps[].phase] | unique[]' "$v"); do
    phase "$n"
    jq --slurpfile v "$v" --arg n "$n" '.spec += [$v[0].gaps[] | select(.phase == $n) | "Gap: " + .gap]' \
      "$pd/spec.json" >"$pd/spec.json.new"
    mv "$pd/spec.json.new" "$pd/spec.json"
    jq --slurpfile v "$v" --arg n "$n" '.phases |= map(if .number == $n
      then .spec += [$v[0].gaps[] | select(.phase == $n) | "Gap: " + .gap] else . end)' \
      "$fd/split.json" >"$fd/split.json.new"
    mv "$fd/split.json.new" "$fd/split.json"
    if jq -e --arg n "$n" 'any(.gaps[]; .phase == $n and (.gap | startswith("Replan: ")))' "$v" >/dev/null; then
      replan "$pd"
    else
      retry_keep "$pd"
    fi
    event "$pd" retry "gaps: $(jq --arg n "$n" '[.gaps[] | select(.phase == $n)] | length' "$v")"
  done
  rm "$v"
  commit "$t/$f" retry
  advance
  exit_refused
}

discussable() {
  pair "$1"
  [ -f "$fd/requirements.json" ] || die "no $fd/requirements.json"
  ready "$1" >/dev/null || die "$1 waits on unshipped features"
}

undiscussed() {
  local s
  pair "$1"
  s=$(sessions --names discuss discuss) || die "cannot list the sessions of $t/$f"
  [ -n "$s" ] || return 0
  echo "forge: $t/$f already has a live session $s; not starting another" >&2
  return 1
}

discussion() {
  local n="${root##*/} discuss $t/$f"
  session "$root" "$n" "/forge-discuss $1$t/$f" "$(jq -nc --arg r "$root" '{env: {FORGE_ROOT: $r}}')" || die "claude --bg failed to start $n"
}

discuss() {
  discussable "$1"
  undiscussed "$1" || return 0
  discussion ""
}

discuss_auto() {
  local a x
  for a; do discussable "$a"; done
  tally
  x=$(claude agents --json </dev/null | jq -r '[.[] | select(.state == "blocked" and ((.name // "") | test("^.+ discuss( [^ /]+/[^ /]+)?$")))] | length') ||
    die "cannot list Claude sessions"
  nlive=$((nlive + x))
  for a; do
    undiscussed "$a" || continue
    room "$t/$f discuss" || return 0
    discussion "--auto "
    nlive=$((nlive + 1)) nstarted=$((nstarted + 1))
  done
}

launch_start() {
  local s=0
  FORGE_ROOT=$root "$D/../forge" "$@" </dev/null || s=$?
  [ $s = 0 ] || [ $s = 8 ] && return 0
  echo "forge: $t/$f: forge $* failed (exit $s)" >&2
  return 1
}

launch_track() {
  local x ft st u s n bad=0
  [ -f "tracks/$1.json" ] || die "no track $1"
  x=$(jq -r .status "tracks/$1.json") || die "cannot read tracks/$1.json"
  [ "$x" = open ] || die "track $1 is not open"
  x=$(project '$p.tracks[$t].features[] | .feature as $f | [$f, fstatus($p; $t; $f), (unmet($p; $t; .) | join(" "))] | @tsv' --arg t "$1") ||
    die "cannot read the features of $1"
  while IFS=$'\t' read -r ft st u; do
    [ -n "$ft" ] && [ "$st" != shipped ] || continue
    pair "$1/$ft"
    if [ -n "$u" ]; then
      echo "forge: $t/$f waits on unshipped features" >&2
      continue
    fi
    s=$(sids) && s=$(sessions --names "P[0-9]+(R[0-9]+)?|verify|ship|discuss" "Phase [0-9]+( retry [0-9]+)?|Verify|Ship|discuss" "$s") ||
      die "cannot list the sessions of $t/$f"
    if [ -n "$s" ]; then
      echo "forge: $t/$f already has a live session ${s//$'\n'/, }; not starting another" >&2
      continue
    fi
    case $st in
      todo | discussing) launch_start discuss $2 "$t/$f" || bad=1 ;;
      discussed | verify)
        if launch_start implement "$t/$f"; then
          for n in $(numbers); do
            phase "$n"
            [ "$(jq -r .status "$pd/result.json" 2>/dev/null)" != blocked ] || launch_start resume "$n" || bad=1
          done
        else
          bad=1
        fi ;;
      ship) launch_start next "$t/$f" || bad=1 ;;
    esac
  done <<<"$x"
  return $bad
}

resume() {
  local s w
  phase "$@"
  t=$(jq -r .track "$pd/spec.json") f=$(jq -r .feature "$pd/spec.json") fd=$state/features/$t-$f
  ! merged "$1" || die "phase $1 is done; nothing to resume"
  lock
  s=$(sid_of "$pd") || exit
  w=$(repo "$pd") || exit
  tally
  if ! unlive "$pd/result.json" "phase $1 has a live session" "" "$(wt_of "$w" "$t/$f" "$1")" "P$1(R[0-9]+)?" "Phase $1( retry [0-9]+)?" "$s"; then
    launch_refused phase "$1" "$lr"
    exit_refused
  fi
  phase "$1"
  rm -f "$pd/result.json"
  launch "$1" || case $? in
    11)
      held_add phase "$1"
      event "$pd" wait "$waits" || die "cannot log the wait of phase $1 in $pd/events.jsonl"
      ;;
    10 | 12) exit_refused ;;
    *) exit 1 ;;
  esac
}

phase_repos() {
  local n
  rs=()
  for n in $(numbers); do
    phase "$n"
    n=$(repo "$pd")
    [[ " ${rs[*]} " == *" $n "* ]] || rs+=("$n")
  done
}

repo_order() {
  local ks k
  ks=$(jq -r --arg p "${root##*/}" '
    (.phases | to_entries | map(.value + {i: .key, r: (.value.repo // "")})) as $ps
    | ($ps | map({(.slug): .r}) | add) as $at
    | ($ps | group_by(.r) | map({key: .[0].r, value: (map([.number == null, (.number // "0" | tonumber), .i]) | min)}) | from_entries) as $low
    | ([$ps[] | .r as $c | .depends[] | $at[.] // empty | select(. != $c) | [., $c]] | unique) as $edges
    | {done: [], left: ($low | keys)}
    | until(.left == [] or .stuck;
        .done as $d
        | [.left[] as $r | select(all($edges[]; .[1] != $r or IN(.[0]; $d[]))) | $r] as $free
        | if $free == [] then .stuck = true
          else ($free | min_by($low[.])) as $n | .done += [$n] | .left -= [$n] end)
    | if .stuck then "forge: cycle between repos \(.left | map(if . == "" then $p end) | join(", "))\n" | halt_error(1)
      else .done[], "." end' "$fd/split.json") || exit 1
  os=()
  while IFS= read -r k; do
    os+=("$(repo_path "$k")")
  done <<<"${ks%$'\n'.}"
}

feature_repos() {
  pair "$@"
  [ -f "$fd/split.json" ] || die "no $fd/split.json"
  local r
  repo_order
  for r in "${os[@]}"; do echo "${r##*/} $r"; done
}

sids() {
  local n x ids=
  for n in $(numbers); do
    phase "$n"
    x=$(sid_of "$pd") || exit
    ids+=" $x"
  done
  x=$(sid_of "$fd") || exit
  echo "$ids $x"
}

sessions() {
  local names ids= args=() live='select(.state == "working" or .state == "blocked")' new='P[0-9]+(R[0-9]+)?|verify' old='Phase [0-9]+( retry [0-9]+)?|Verify' out=.id
  case ${1:-} in
    --names) out=.name; shift ;;
    --rows) out='[.id // "", .name // "", (.cwd // "" | rtrimstr("/")), .sessionId // ""] | join("\u001f")'; shift ;;
  esac
  case ${1:-} in
    --all) args=(--all) live=.; shift ;;
    --idle) args=(--all) live='select(.state != "working" and .state != "blocked")'; shift ;;
  esac
  phase_repos
  if [ $# -eq 0 ]; then
    ids=$(sids) || exit
  else
    new=$1 old=$2 ids=${3:-}
  fi
  names=$(printf '%s\n' "${rs[@]##*/}" "${root##*/}" | sort -u | paste -sd '|')
  claude agents --json "${args[@]}" |
    jq -r --arg re "^($names)(/[^ /]+)? (($new) $t/$f|$t-$f ($old))$" --arg ids "$ids" \
      ".[] | select((.name | test(\$re)) or IN(.id; \$ids | splits(\" +\") | select(. != \"\"))) | $live | $out"
}

unwork() {
  [ -d "$2" ] || return 0
  [ -z "$(git -C "$2" status --porcelain | grep -vE '^\?\? (.*/)?((\.serena|node_modules)/|\.impeccable/.*)$')" ] || die "$2 has uncommitted changes or untracked files"
  git -C "$1" worktree remove --force "$2"
}

unlanded() {
  local n r ws=() bs=() no=() base=origin/main
  phase_repos
  for r in "${rs[@]}"; do
    git -C "$r" remote get-url origin >/dev/null 2>&1 || no+=("${r##*/}")
    for n in $(numbers); do
      [ ! -d "$(wt_of "$r" "$t/$f" "$n")" ] || ws+=("$(wt_of "$r" "$t/$f" "$n")")
      ! git -C "$r" show-ref -q --verify "refs/heads/$(branch_of "$t/$f" "$n")" || bs+=("$r:$(branch_of "$t/$f" "$n")")
    done
    [ ! -d "$(wt_of "$r" "$t/$f")" ] || ws+=("$(wt_of "$r" "$t/$f")")
  done
  if [ ${#no[@]} -gt 0 ]; then
    base="main (no origin in $(printf '%s\n' "${no[@]}" | paste -sd ' '))"
    [ ${#no[@]} -eq ${#rs[@]} ] || base+=" or origin/main"
  fi
  {
    echo "forge: $t/$f is not in $base; nothing removed. Targets:"
    for r in "${ws[@]}"; do echo "  worktree $r"; done
    for r in "${bs[@]}"; do echo "  branch $r"; done
    sessions --all | sed 's/^/  session /'
    echo "Run 'forge clean --confirmed $t/$f' to override."
  } >&2
  exit 3
}

shipped() {
  local n r b m o
  phase_repos
  for r in "${rs[@]}"; do
    o=refs/heads/main
    if git -C "$r" remote get-url origin >/dev/null 2>&1; then
      o=refs/remotes/origin/main
      git -C "$r" show-ref -q --verify "$o" || return 1
      m=$(GIT_TERMINAL_PROMPT=0 git -C "$r" ls-remote --exit-code origin refs/heads/main 2>/dev/null) || return 1
      [ "${m%%$'\t'*}" = "$(git -C "$r" rev-parse "$o")" ] || return 1
    fi
    for n in $(numbers); do
      b=$(branch_of "$t/$f" "$n")
      ! git -C "$r" show-ref -q --verify "refs/heads/$b" || git -C "$r" merge-base --is-ancestor "refs/heads/$b" "refs/heads/$(branch_of "$t/$f")" || return 1
    done
    b=$(branch_of "$t/$f")
    ! git -C "$r" show-ref -q --verify "refs/heads/$b" || git -C "$r" merge-base --is-ancestor "refs/heads/$b" "$o" || return 1
  done
}

clean() {
  pair "$@"
  [ -f "$fd/split.json" ] || die "no $fd/split.json"
  local n r b
  if [ -n "$idle" ]; then
    sessions --idle | while read -r n; do claude rm "$n" </dev/null; done
    return
  fi
  [ -n "$confirmed" ] || shipped || unlanded
  sessions --all | while read -r n; do claude rm "$n" </dev/null; done
  phase_repos
  for r in "${rs[@]}"; do
    for n in $(numbers); do
      unwork "$r" "$(wt_of "$r" "$t/$f" "$n")"
      b=$(branch_of "$t/$f" "$n")
      git -C "$r" show-ref -q --verify "refs/heads/$b" || continue
      git -C "$r" merge-base --is-ancestor "refs/heads/$b" "refs/heads/$(branch_of "$t/$f")" || die "$b is not merged into $(branch_of "$t/$f")"
      git -C "$r" branch -q -D "$b"
    done
    unwork "$r" "$(wt_of "$r" "$t/$f")"
  done
}

push() {
  local repo=$1 conf branch out
  pushed=
  conf=$(git -C "$repo" config --bool forge.pushMain 2>/dev/null) || return 0
  [ "$conf" = true ] || return 0
  branch=$(git -C "$repo" branch --show-current 2>/dev/null) || return 0
  [ "$branch" = main ] || return 0
  out=$(GIT_TERMINAL_PROMPT=0 git -C "$repo" push origin main 2>&1) || {
    recover "$repo" && out=$(GIT_TERMINAL_PROMPT=0 git -C "$repo" push origin main 2>&1) || {
      echo "forge: warning: pushing main to origin failed in $repo:" >&2
      echo "$out" >&2
      return 0
    }
  }
  pushed=$(git -C "$repo" rev-parse --short main)
}

recover() {
  local repo=$1 x o tree mc paths rc=0
  GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null || return 1
  o=$(git -C "$repo" rev-parse --verify -q 'refs/remotes/origin/main^{commit}') || return 1
  git -C "$repo" merge-base --is-ancestor "$o" main || rc=$?
  [ $rc -eq 1 ] || return 1
  lock "$repo"
  x=$(git -C "$repo" diff --name-only --no-renames "$o"...main | sed '\#^\.forge/#d' | paste -sd ' ') || return 1
  if [ -n "$x" ]; then
    echo "forge: origin/main moved and local commits change $x outside .forge/; run forge land to retest" >&2
    return 1
  fi
  rc=0
  tree=$(git -C "$repo" merge-tree --write-tree --name-only --no-messages main "$o") || rc=$?
  if [ $rc -eq 1 ]; then
    x=$(sed 1d <<<"$tree" | paste -sd ' ')
    [[ ${tree%%$'\n'*} =~ ^[0-9a-f]{40,64}$ && -n $x ]] || return 1
    echo "forge: origin/main conflicts with main in: $x; reconcile by hand" >&2
    return 1
  fi
  [ $rc -eq 0 ] || return 1
  mc=$(git -C "$repo" commit-tree "$tree" -p main -p "$o" -m 'Merge origin/main') || return 1
  x=$(git -C "$repo" merge -q --ff-only "$mc" 2>&1) || {
    paths=$(sed -n 's/^\t//p' <<<"$x" | paste -sd ' ')
    if [ -n "$paths" ]; then
      echo "forge: origin/main moved; main has local changes to $paths; commit or move them, then push again" >&2
    else
      printf '%s\n' "$x" >&2
    fi
    return 1
  }
  echo "forge: origin/main moved; merged it into main as $(git -C "$repo" rev-parse --short "$mc")" >&2
}

push_main() {
  push "$1"
  [ -z "$pushed" ] || echo "forge: pushed $pushed to origin"
}
