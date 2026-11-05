pending_set() {
  local s=0 t
  exec 7>"$1.lock" && flock 7 && t=$(mktemp "$1.XXXXXX") || { exec 7>&-; return 1; }
  jq -c --arg r "$2" --arg c "$3" "if .repo == \$r and .commit == \$c then $4 else . end" "$1" >"$t" && if [ -s "$t" ]; then mv "$t" "$1"; else rm -f "$1"; fi || s=1
  rm -f "$t"
  exec 7>&-
  return "$s"
}

port_flip() {
  pending_set "$1" "$2" "$3" empty || echo "forge: cannot remove the ported $2 from $1" >&2
}

port_queued() {
  local p=$1 r=$2 f=${3:-} x c a o b out rc sha cause
  [ -f "$p" ] || return 0
  x=$(jq -rn --arg r "$r" 'first(inputs | select(.repo == $r) | [.commit, (.alerted // false), (.ported // false)] | map(tostring) | join("\u001f")) // empty' "$p") ||
    { echo "forge: cannot read $p; the queued port of $r waits" >&2; return 0; }
  [ -n "$x" ] || return 0
  IFS=$'\x1f' read -r c a o <<<"$x"
  [ "$o" != true ] || { port_flip "$p" "$r" "$c"; return 0; }
  b=$(git -C "$r" branch --show-current 2>/dev/null) || b=
  [ "$b" = main ] || { echo "forge: port still queued: $r is on ${b:-no branch}, not main"; return 0; }
  git -C "$r" merge-base --is-ancestor "$c" main 2>/dev/null || { echo "forge: port still queued: main in $r does not hold $c yet"; return 0; }
  if out=$( (cd "$r" && ./port --apply </dev/null 8>&-) 2>&1); then
    printf '%s\n' "$out"
    sha=$(sed -n 's/^ported //p' <<<"$out" | tail -n1)
    sha=${sha:-$(git -C "$r" rev-parse --short HEAD)}
    echo "forge: ported $sha from the queued golive of $r"
    [ -z "$f" ] || notify "forge: port applied" "$sha applied after 2 h queued with $f sessions working" ||
      echo "forge: cannot send the forced-port notice for $r through forge notify" >&2
    port_flip "$p" "$r" "$c"
    return 0
  fi
  rc=$?
  printf '%s\n' "$out" >&2
  cause="./port --apply exited $rc"
  [ -z "$out" ] || cause+=": $(tail -n1 <<<"$out")"
  echo "forge: queued port failed in $r: $cause; port still queued" >&2
  [ "$a" != true ] || { echo "forge: queued port of $r already alerted; no new alert until it is queued again" >&2; return 0; }
  if notify "forge: queued port failed" "$r: $cause"; then
    pending_set "$p" "$r" "$c" '.alerted = true' || echo "forge: cannot record the queued-port alert for $r in $p" >&2
  else
    echo "forge: cannot send the queued-port alert for $r through forge notify" >&2
  fi
}

watchdog_port() {
  local p=$HOME/.local/state/forge/port.pending x a n r age ll y=
  [ -s "$p" ] || return 0
  x=$(jq -r '[.repo, (try (if now - (.time | fromdate) >= 7200 then "old" else "young" end) catch "bad")] | @tsv' "$p") ||
    { echo "forge: cannot read $p; the queued ports wait" >&2; return 0; }
  a=$(forge_agents) || a=
  while IFS=$'\t' read -r r age; do
    [ -n "$r" ] || continue
    [ "$age" != bad ] || { echo "forge: cannot read the queue time of $r in $p" >&2; age=young; }
    n=unknown
    [ -z "$a" ] || n=$(forge_count "$a" "" "$(port_scope "$r")") || n=unknown
    [ "$n" = 0 ] || [ "$age" = old ] || { y=$n; continue; }
    ll=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/forge-land.lock && exec 8>"$ll" ||
      { echo "forge: cannot open the forge-land.lock of $r; port still queued" >&2; continue; }
    if flock -n 8; then
      wait_lock 8 "$ll"
      port_queued "$p" "$r" "${n#0}"
    else
      echo "forge: port still queued: a land or golive of $r holds $ll"
    fi
    exec 8>&-
  done <<<"$x"
  [ -z "$y" ] || [ "$y" != unknown ] || echo "forge: port still queued: cannot list Claude sessions"
  [ -z "$y" ] || [ "$y" = unknown ] || echo "forge: port still queued: $y forge sessions working"
}

scope_limit_us() {
  local t v=0 m ts
  [ -n "$1" ] && [ "$1" != infinity ] || return 1
  read -ra ts <<<"$1"
  for t in "${ts[@]}"; do
    [[ $t =~ ^([0-9]+)(us|ms|s|min|h|d|w)$ ]] || return 1
    case ${BASH_REMATCH[2]} in
      us) m=1 ;;
      ms) m=1000 ;;
      s) m=1000000 ;;
      min) m=60000000 ;;
      h) m=3600000000 ;;
      d) m=86400000000 ;;
      w) m=604800000000 ;;
    esac
    v=$((v + 10#${BASH_REMATCH[1]} * m))
  done
  echo "$v"
}

watchdog_test_limit() {
  local f=${XDG_STATE_HOME:-$HOME/.local/state}/forge/test-past-limit
  [ "$(forge_uname)" != Darwin ] || return 0
  mkdir -p "${f%/*}" || :
  { flock 9 || echo "forge: warning: cannot lock $f.lock; the test-past-limit alert may repeat" >&2; test_limit_alert "$f"; } 9>>"$f.lock" ||
    { echo "forge: warning: cannot open $f.lock; the test-past-limit alert may repeat" >&2; test_limit_alert "$f"; }
}

test_limit_alert() {
  local f=$1 x u l s r lim st now=$EPOCHSECONDS out=()
  local -A seen=() sent=()
  x=$(systemctl --user list-units --all --plain --no-legend 'forge-test-*.scope' </dev/null) ||
    { echo "forge: warning: cannot list the forge-test scopes; no test-past-limit alert this scan" >&2; return 0; }
  if [ -e "$f" ]; then
    while read -r u; do [ -z "$u" ] || sent[$u]=1; done <"$f" ||
      echo "forge: warning: cannot read $f; the test-past-limit alert may repeat" >&2
  fi
  while read -r u l s r; do
    [[ $u == forge-test-*.scope ]] || continue
    seen[$u]=1
    [ "$s" != inactive ] && [ "$s" != failed ] && [ -z "${sent[$u]:-}" ] || continue
    lim=$(systemctl --user show -p RuntimeMaxUSec --value "$u" </dev/null) && lim=$(scope_limit_us "$lim") || continue
    st=$(systemctl --user show -p ActiveEnterTimestamp --value --timestamp=unix "$u" </dev/null) || continue
    [[ $st =~ ^@([0-9]+)$ ]] && st=$((10#${BASH_REMATCH[1]})) && [ "$st" -gt 0 ] || continue
    [ $(((now - st) * 1000000)) -gt $((lim + 300000000)) ] || continue
    if notify "forge: test past limit" "$u running $(((now - st) / 60)) min"; then
      sent[$u]=1
    else
      echo "forge: cannot send the test-past-limit alert for $u through forge notify" >&2
    fi
  done <<<"$x"
  for u in "${!sent[@]}"; do [ -z "${seen[$u]:-}" ] || out+=("$u"); done
  if [ ${#out[@]} -eq 0 ]; then
    rm -f "$f" 2>/dev/null || echo "forge: warning: cannot remove $f" >&2
  else
    { printf '%s\n' "${out[@]}" | sort >"$f.new" && mv "$f.new" "$f"; } 2>/dev/null ||
      echo "forge: warning: cannot write $f; the test-past-limit alert may repeat" >&2
  fi
  return 0
}

watchdog_snaps() {
  local r c rc=0 to=${FORGE_SNAP_TIMEOUT:-60}
  local -a repos=() s=()
  doctor_repos
  for r in "${repos[@]}"; do
    git -C "$r" rev-parse --git-dir >/dev/null 2>&1 && c=$(snap_dir "$r" 2>/dev/null) && { [ -d "$c" ] || [ -d "$(stamps "$r")/snap" ] || [ -d "$(stamps "$r")/snap-owner" ]; } || continue
    s+=("$r")
  done
  [ ${#s[@]} -gt 0 ] || return 0
  timeout -k 5 "$to" bash -c 'shopt -s nullglob; . "$1/env.sh" && . "$1/test.sh" && shift && for r; do
    snap_prune "$r" || echo "forge: warning: cannot prune the forge test snapshots of $r; the next scan retries" >&2
  done' forge-snaps "$D" "${s[@]}" </dev/null 9>&- || rc=$?
  case $rc in
    0) ;;
    124 | 137) echo "forge: warning: the forge test snapshot prune timed out after $to s; the next scan retries" >&2 ;;
    *) echo "forge: warning: the forge test snapshot prune exited $rc; the next scan retries" >&2 ;;
  esac
  return 0
}

watchdog_path() {
  local fd=${FNM_DIR:-$HOME/.local/share/fnm} pre= d
  for d in "$fd/aliases/default/bin" "$fd" "$HOME/.cargo/bin"; do
    if [ -d "$d" ] && [[ :$PATH: != *":$d:"* ]]; then pre+=$d:; fi
  done
  export PATH=$pre$PATH
}

watchdog_doctor() {
  local df=$HOME/.local/state/forge/doctor-boot
  mkdir -p "${df%/*}" 2>/dev/null || :
  { if flock -n 9; then doctor_boot "$df"; else echo "forge: warning: cannot take $df.lock, another scan may hold it; forge doctor does not run this scan" >&2; fi; } 9>>"$df.lock" ||
    { echo "forge: warning: cannot open $df.lock; forge doctor may run twice this boot" >&2; doctor_boot "$df"; }
}

watchdog_perf() {
  local rf=$HOME/.local/state/forge/watchdog-roots sf=$HOME/.local/state/forge/perf-pull r t q rc now=$EPOCHSECONDS to=${FORGE_PERF_TIMEOUT:-60}
  local -A last=()
  [ -f "$rf" ] || return 0
  if [ -f "$sf" ]; then
    while IFS=$'\t' read -r r t; do [ -z "$r" ] || last[$r]=$t; done <"$sf" ||
      echo "forge: warning: cannot read $sf; forge perf pull may run again before 7 days" >&2
  fi
  while IFS= read -r r || [ -n "$r" ]; do
    [ -n "$r" ] && grep -q '^- Perf log:' "$r/.forge/TESTING.md" 2>/dev/null || continue
    t=${last[$r]:-0}
    [[ $t =~ ^[0-9]+$ ]] || t=0
    [ $((now - 10#$t)) -ge 604800 ] || continue
    rc=0
    FORGE_ROOT=$r timeout -k 5 "$to" forge perf pull </dev/null 8>&- 9>&- || rc=$?
    case $rc in
      0) ;;
      124 | 137) echo "forge: warning: forge perf pull in $r timed out after $to s; it runs again in 7 days" >&2 ;;
      *) echo "forge: warning: forge perf pull exited $rc in $r; it runs again in 7 days" >&2 ;;
    esac
    last[$r]=$now q=
    { q=$(mktemp "$sf.XXXXXX") && for t in "${!last[@]}"; do printf '%s\t%s\n' "$t" "${last[$t]}"; done >"$q" && mv "$q" "$sf"; } 2>/dev/null ||
      { [ -z "$q" ] || rm -f "$q"; echo "forge: warning: cannot write $sf; forge perf pull may run again before 7 days" >&2; }
  done <"$rf" || echo "forge: warning: cannot read $rf; forge perf pull skips this scan" >&2
  return 0
}

doctor_boot() {
  local bf=${FORGE_PROC_ROOT:-/proc}/sys/kernel/random/boot_id df=$1 b= o rc=0 n t to=${FORGE_DOCTOR_TIMEOUT:-120}
  b=$(forge_boot_id 2>/dev/null) || b=
  [ -n "$b" ] || { echo "forge: warning: cannot read the boot id from $bf; forge doctor does not run this scan" >&2; return 0; }
  [ "$(cat "$df" 2>/dev/null)" != "$b" ] || return 0
  o=$(timeout -k 5 "$to" "${D%/forge.d}/forge" doctor </dev/null 9>&-) || rc=$?
  { mkdir -p "${df%/*}" && t=$(mktemp "$df.XXXXXX") && printf '%s\n' "$b" >"$t" && mv "$t" "$df"; } 2>/dev/null ||
    { [ -z "${t:-}" ] || rm -f "$t"; echo "forge: warning: cannot write $df; forge doctor may run again this boot" >&2; }
  case $rc in
    0) ;;
    1 | 124 | 137)
      [ "$rc" = 1 ] || echo "forge: warning: forge doctor timed out after $to s; the stall scan goes on" >&2
      o=$(grep '^forge doctor: ' <<<"$o" | grep -v '^forge doctor: removed ') || o=
      n=$(grep -c . <<<"$o") || n=0
      [ "$rc" = 1 ] || [ "$n" -gt 0 ] || return 0
      t=${o%%$'\n'*}
      notify "forge: doctor" "$n problems: ${t#forge doctor: }" ||
        echo "forge: warning: cannot send the forge doctor alert through forge notify" >&2
      ;;
    *) echo "forge: warning: forge doctor exited $rc; the stall scan goes on" >&2 ;;
  esac
}

watchdog_gc() {
  local gf=$HOME/.local/state/forge/gc-week
  mkdir -p "${gf%/*}" 2>/dev/null || :
  { if flock -n 9; then gc_week "$gf"; else echo "forge: warning: cannot take $gf.lock, another scan may hold it; the weekly forge gc does not run this scan" >&2; fi; } 9>>"$gf.lock" ||
    { echo "forge: warning: cannot open $gf.lock; the weekly forge gc may run twice" >&2; gc_week "$gf"; }
  return 0
}

gc_week() {
  local gf=$1 rf=$HOME/.local/state/forge/watchdog-roots to=${FORGE_GC_TIMEOUT:-300} s now r rc t k
  local -A seen=()
  now=$(date +%s)
  s=$(cat "$gf" 2>/dev/null) || s=
  ! [[ $s =~ ^[0-9]+$ ]] || [ $((now - 10#$s)) -ge 604800 ] || return 0
  if [ -f "$rf" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] && [ -z "${seen[$r]+x}" ] && [ -d "$r" ] || continue
      seen[$r]=1
      k=$((285 - SECONDS))
      [ "$k" -gt 0 ] || { echo "forge: warning: the weekly forge gc reached the 5 min forge-watchdog.service deadline before $r; the roots it did not reach wait for next week's gc" >&2; break; }
      [ "$to" -ge "$k" ] 2>/dev/null || k=$to
      rc=0
      FORGE_ROOT=$r timeout -k 5 "$k" "${D%/forge.d}/forge" gc --apply </dev/null 9>&- || rc=$?
      case $rc in
        0) ;;
        124 | 137) echo "forge: warning: forge gc --apply in $r timed out after $k s; the scan goes on" >&2 ;;
        *) echo "forge: warning: forge gc --apply in $r exited $rc; the scan goes on" >&2 ;;
      esac
    done <"$rf" || echo "forge: warning: cannot read $rf; the weekly forge gc skips the roots it did not reach" >&2
  fi
  { t=$(mktemp "$gf.XXXXXX") && printf '%s\n' "$now" >"$t" && mv "$t" "$gf"; } 2>/dev/null ||
    { [ -z "${t:-}" ] || rm -f "$t"; echo "forge: warning: cannot write $gf; the weekly forge gc may run again next scan" >&2; }
  return 0
}

watchdog() {
  local lim=${FORGE_STALL_MIN:-20} bc=${FORGE_BG_CEIL_MIN:-120} a x id pd name sid cwd st p tf n r d ts last now m msg ph prev j s e f c k t w kd wh wf q h fin dt lt oc g ge sd rr cause rf=$HOME/.local/state/forge/watchdog-roots
  local -A roots=() tested=() sds=()
  local -a la=()
  watchdog_path
  [[ $lim =~ ^[0-9]+$ ]] && [ "$lim" -gt 0 ] || die "FORGE_STALL_MIN must be a whole number of minutes above 0, got '$lim'" 2
  if [[ $bc =~ ^[0-9]+$ ]] && [ "$bc" -gt 0 ]; then
    bc=$((10#$bc))
  else
    echo "forge: FORGE_BG_CEIL_MIN=$bc is not a positive integer; using 120" >&2
    bc=120
  fi
  watchdog_port
  watchdog_test_limit
  watchdog_snaps
  watchdog_doctor
  codex_quota 10 || :
  a=$(claude agents --json --all </dev/null) || die "cannot list Claude sessions"
  x=$(jq -r '.[] | select(.sessionId != null and .cwd != null and .state != null and (.name // "") != "")
    | .name as $n
    | (first(($n | capture("^(?<p>[^/]+?)(/[^ ]+)? (P(?<n>[0-9]+)(R[0-9]+)?|(?<k>verify|ship)) (?<t>[^ /]+)/(?<f>[^ /]+)$") | .s = "\(.t)-\(.f)"),
      ($n | capture("^(?<p>.+) (?<s>[^ /]+) (Phase (?<n>[0-9]+)( retry [0-9]+)?|(?<k>Verify|Ship))$"))) // {}) as $m
    | [.id // "-", (.pid // "-" | tostring), .sessionId, .cwd, .state, $n, ($m.k // "-" | ascii_downcase), (.waitingFor // "" | tostring | if . == "" then "-" else . end), $m.p // "", $m.s // "", $m.n // ""] | @tsv' <<<"$a") || die "cannot list Claude sessions"
  now=$(date +%s)
  while IFS=$'\t' read -r id pd sid cwd st name kd wf p tf n; do
    wh=
    d=$HOME/.claude/projects/${cwd//[^a-zA-Z0-9]/-}
    ts=("$d/$sid.jsonl" "$d/$sid"/subagents/agent-*.jsonl)
    [ -f "${ts[0]}" ] || { unseen "no transcript ${ts[0]}"; continue; }
    last=$(stat -c %Y "${ts[@]}" | sort -n | tail -n1) || { echo "forge: cannot read the transcripts of $name; skipping it" >&2; continue; }
    m=$(((now - last) / 60))
    if [ -n "$p" ]; then
      r=$cwd
      until [ -z "$r" ] || has_feature "$r"; do r=${r%/*}; done
      if [ -z "$r" ]; then
        r=$(jq -rn 'first(inputs | select(.type == "user") | .message.content | strings | capture("<command-args>(?<r>.*) [^ ]+</command-args>").r) // empty' "${ts[0]}") || r=
        [ -n "$r" ] && has_feature "$r" || r=
      fi
      [ -n "$r" ] || { unseen "no project $p with feature $tf above $cwd or in the launch prompt of $name"; continue; }
      roots[$r]=1
      root_state "$r" || continue
      if [ -n "$n" ]; then
        ph=("$sd/phases/$n"-*/)
        [ ${#ph[@]} -eq 1 ] || { unseen "no phase $n in $sd"; continue; }
        d=${ph[0]%/}
        s=$(sid_of "$d") || { echo "forge: skipping $name" >&2; continue; }
      else
        d=$sd/features/$tf wh=${name##* }
        [[ $wh == */* ]] || wh=$tf
        wh+=" $kd"
        s=$([ ! -f "$d/events.jsonl" ] || jq -sr --arg n "$name" 'map(select(.step == "start" and .message == $n)) | last | .session // empty' "$d/events.jsonl") ||
          { echo "forge: cannot read $d/events.jsonl; skipping $name" >&2; continue; }
      fi
      [ -z "$s" ] || [ "$s" = "$id" ] || { unseen "the last start in $d/events.jsonl is session $s, not $name ($id)"; continue; }
    else
      [[ ${cwd%/} =~ ^(.+)/\.claude/worktrees/([^/]+)-([0-9]+)$ ]] || continue
      r=${BASH_REMATCH[1]} tf=${BASH_REMATCH[2]} n=${BASH_REMATCH[3]} d=
      while [ -n "$r" ]; do
        ph=()
        for rr in "$r/.forge" "$r"/*/.forge; do
          root_state "${rr%/.forge}" || continue
          ph+=("$sd/phases/$n"-*/events.jsonl)
        done
        for j in "${ph[@]}"; do
          s=$(sid_of "${j%/*}") || s=
          [ "$s" != "$id" ] || { d=${j%/*}; break; }
        done
        [ -z "$d" ] || break
        r=${r%/*}
      done
      [ -n "$d" ] || { unseen "no phase $n start above $cwd records session $id"; continue; }
      r=$(cat "${d%/phases/*}/root") || { unseen "cannot read ${d%/phases/*}/root"; continue; }
      p=${r##*/}
      roots[$r]=1
    fi
    [ "$st" != working ] || [ "$m" -ge "$lim" ] || continue
    c=
    if [ "$st" = blocked ]; then
      if ! c=$(stop_cause "${ts[0]}"); then
        echo "forge: cannot read the stop of $name from ${ts[0]}; checking it for a pending question" >&2
        c=
      fi
      if [[ $c != "usage limit"$'\t'* && $c != "API error "* ]]; then
        c=
        [ "$m" -ge "$lim" ] && [ "$wf" = - ] || continue
        q=0
        h=$(heal_of) || q=$?
        [ "$q" != 2 ] || echo "forge: cannot read the blocker of $name; checking it for a pending question" >&2
        [ "$q" != 0 ] || { self_heal "$h"; continue; }
        for f in "${ts[@]}"; do
          q=0
          pending_question "$f" || q=$?
          [ "$q" = 1 ] || { [ "$q" = 0 ] || echo "forge: cannot read $f; skipping $name" >&2; continue 2; }
        done
      fi
    fi
    if [ "$st" != working ] && { [ "$st" != blocked ] || [ -n "$c" ]; }; then
      if [ -f "$d/result.json" ]; then
        q=0
        h=$(heal_of) || q=$?
        [ "$q" != 2 ] || echo "forge: cannot read $d/result.json; not resuming $name" >&2
        [ "$q" != 0 ] || self_heal "$h"
        continue
      fi
      if [ -z "$n" ]; then
        [ "$kd" != verify ] || [ ! -f "$d/verify.json" ] || continue
        if [ "$kd" = verify ] || { [ "$kd" = ship ] && [ -f "$d/ship.json" ]; }; then
          q=0
          ship_replied "${ts[0]}" || q=$?
          [ "$q" = 1 ] || { [ "$q" = 0 ] || echo "forge: cannot read ${ts[0]}; skipping $name" >&2; continue; }
        fi
      fi
      e=
      [ ! -f "$d/events.jsonl" ] || e=$(jq -rs --arg s "($sid) turn ended" --argjson l "$last" "$park_defs"' if parked then "park \(parked.time) \(parked.message)"
        elif ((to_entries | map(select(.value.step == "resume" and (.value.message | strings | startswith("auto-resume")))) | last.key // -1) as $r
          | any(.[$r + 1:][]; .step == "stall" and (.message | contains($s)) and (.time | fromdateiso8601) >= $l)) then "seen" else last.step // "" end' "$d/events.jsonl") ||
        { echo "forge: cannot read $d/events.jsonl; skipping $name" >&2; continue; }
      case $e in
        "park "*)
          [[ $st =~ ^(done|failed|stopped|crashed)$ ]] || continue
          e=${e#park }
          wake "${e#* }"
          continue ;;
        wait) continue ;;
      esac
      [ -z "$n" ] || ! waits_on "${ts[0]}" "$n" || continue
      if [ "$st" = blocked ]; then
        :
      elif ! c=$(stop_cause "${ts[0]}"); then
        echo "forge: cannot read the stop of $name from ${ts[0]}; alerting on its ended turn" >&2
        c=
      fi
      if [ -z "$c" ] && [ "$st" = done ] && [ -n "$n" ]; then
        q=0
        h=$(heal_of) || q=$?
        [ "$q" != 2 ] || echo "forge: cannot read ${ts[0]}; alerting on the ended turn of $name" >&2
        [ "$q" != 0 ] || { self_heal "$h"; continue; }
      fi
      if [ -z "$c" ] && [ "$st" = done ]; then
        c="ended turn"$'\t'"$last"
        for f in "${ts[@]}"; do
          q=0
          pending_question "$f" || q=$?
          [ "$q" = 1 ] || { [ "$q" = 0 ] || echo "forge: cannot read $f; alerting on the ended turn of $name" >&2; c=; break; }
        done
      fi
      [ -z "$c" ] || k=$(auto_count "$d") || { echo "forge: cannot read the auto-resumes of $name from $d/events.jsonl; alerting on its ended turn" >&2; c=; }
      [[ $c != "ended turn"$'\t'* ]] || [ "$k" -lt 5 ] || c=
      [ "$e" != seen ] || [ -n "$c" ] || continue
      if [ "$e" != seen ]; then
        msg="$name ($sid) turn ended with no result"
        if [ -n "$c" ]; then
          msg+=": stopped by ${c%%$'\t'*}"
          if [ "$k" -ge 5 ]; then
            notify "forge: auto-resume gave up" "$p ${wh:-phase ${d##*/}}: $name stopped by ${c%%$'\t'*} after 5 resumes" ||
              echo "forge: cannot send the auto-resume give-up alert for $name through forge notify" >&2
            msg+="; gave up"
          fi
        else
          q=$(asked "${ts[0]}") || { echo "forge: cannot read the last reply of $name from ${ts[0]}; alerting on its ended turn" >&2; q=; }
          w=$(notified "${ts[0]}") || { echo "forge: cannot read ${ts[0]}; alerting on its ended turn" >&2; w=false; }
          [ -z "$q" ] || msg+="; asked: $q"
          if [ "$w" = true ]; then
            :
          elif [ -n "$q" ]; then
            q="$name: $q"
            notify "forge: question" "${q:0:200}" ||
              echo "forge: cannot send the question alert for $name through forge notify" >&2
          else
            notify "forge: turn ended" "$p ${wh:-phase ${d##*/}}: $name turn ended with no result" ||
              echo "forge: cannot send the ended-turn alert for $name through forge notify" >&2
          fi
        fi
        event "$d" stall "$msg" || die "cannot log the stall of $name in $d/events.jsonl"
        echo "forge: stall: $msg, logged in $d/events.jsonl"
      fi
      [ -z "$c" ] || auto_resume "$c" "$k"
      continue
    fi
    msg="$name ($sid) idle $m min"
    if ! t=$(unreported "${ts[0]}" "$cwd" "$sid" "$d"); then
      echo "forge: cannot read the background tasks of $name from ${ts[0]}; treating it as idle" >&2
      t=
    fi
    lt= oc=
    { IFS= read -r t; IFS= read -r dt || :; IFS= read -r lt || :; } <<<"$t"
    if [ -n "$t" ]; then
      t=
      IFS=$'\t' read -ra la <<<"$lt"
      for g in "${la[@]}"; do
        ge=${g%%:*} g=${g#*:}
        if [ -z "$ge" ]; then
          echo "forge: warning: no launch time for background task $g of $name in ${ts[0]}; counting it under the $bc min ceiling" >&2
        elif [ $(((now - ge) / 60)) -ge "$bc" ]; then
          oc+=${oc:+, }"background task $g in flight $(((now - ge) / 60)) min past the $bc min ceiling"
          continue
        fi
        t+=${t:+, }$g
      done
    fi
    fin=
    if [ -z "$oc" ] && [ "$st" = working ] && [ -n "$n" ] && [ "$id" != - ] && [ "$m" -ge 10 ] && [ -f "$d/result.json" ]; then fin=1; fi
    if [ -n "$t" ]; then
      if [ -n "$fin" ]; then
        echo "forge: $msg with background task $t in flight; no stall" >&2
      else
        echo "forge: $msg with background task $t in flight; no stall"
      fi
      continue
    fi
    [ -z "$oc" ] || msg+="; $oc"
    if [ -n "$dt" ] && [ ! -f "$d/result.json" ] &&
      resume_session "forge watchdog: background task(s) $dt died and will never report; continue ${wh:-phase $n} from where it stopped" "dead background task(s) $dt, idle $m min" "$st"; then
      continue
    fi
    if [ -n "$fin" ]; then
      if [ "$pd" != - ] && j=$(shell_of "$pd"); then
        echo "forge: $name ($sid) has a running Bash process $j in flight; not stopping it" >&2
      elif ! e=$(claude stop "$id" </dev/null 2>&1 >/dev/null); then
        echo "forge: cannot stop $name: $e" >&2
      else
        msg+="; stopped: phase has result.json"
        event "$d" stall "$msg" || die "cannot log the stall of $name in $d/events.jsonl"
        echo "forge: stall: $msg, logged in $d/events.jsonl"
        continue
      fi
    fi
    prev=
    [ ! -f "$d/events.jsonl" ] || prev=$(jq -rs --arg s "($sid)" --argjson l "$last" 'map(select(.step == "stall" and (.message | contains($s))) | .time |= fromdateiso8601)
      | if any(.[]; .time >= $l and (.message | endswith("; operator notified"))) then "notified" else last.time // empty end' "$d/events.jsonl") ||
      { echo "forge: cannot read $d/events.jsonl; treating the stall of $name as a first one" >&2; prev=; }
    [ "$prev" != notified ] || continue
    if [ -n "$prev" ] && [ $((now - prev)) -le 1800 ]; then
      if notify "forge: repeat stall" "$p: $name idle $m min${oc:+; $oc}"; then
        msg="$msg; operator notified"
      else
        echo "forge: cannot send the repeat-stall alert for $name through forge notify" >&2
      fi
    fi
    event "$d" stall "$msg" || die "cannot log the stall of $name in $d/events.jsonl"
    echo "forge: stall: $msg, logged in $d/events.jsonl"
  done <<<"$x"
  mkdir -p "${rf%/*}" || echo "forge: cannot create ${rf%/*}" >&2
  { flock 7 || echo "forge: cannot lock $rf.lock; rewriting $rf without it" >&2; keep_roots; } 7>>"$rf.lock" ||
    { echo "forge: cannot open $rf.lock; rewriting $rf without it" >&2; keep_roots; }
  watchdog_refused
  for r in "${!roots[@]}"; do
    for f in "$r/.forge/TESTING.md" "$r"/*/.forge/TESTING.md; do
      [ -f "$f" ] && [ -z "${tested[$f]:-}" ] || continue
      tested[$f]=1
      c=$(awk '/^## /{c = ($0 == "## Commands"); next} c && sub(/^- [^:`]+:[^`]*`/, "") {sub(/`.*/, ""); print}' "$f") ||
        { echo "forge: warning: cannot read $f; its test tools go unchecked" >&2; continue; }
      for t in node cargo; do
        w=cargo
        [ "$t" = cargo ] || w='node|npm|npx|pnpm|yarn'
        if grep -qwE "$w" <<<"$c" && ! command -v "$t" >/dev/null; then
          echo "forge: warning: $f runs $t, which is not on the watchdog PATH ($PATH)" >&2
        fi
      done
    done
  done
  for r in "${!roots[@]}"; do revive "$r"; done
  watchdog_held
  watchdog_gc
  watchdog_perf
}

park_defs='def parked: map(select(.step != "refused" and (.step != "stall" or ((.message // "") | startswith("launch refused: ") | not)))) | last | if .step == "park" then . else null end;'

watchdog_refused() {
  local r f m
  for r in "${!roots[@]}"; do
    root_state "$r" || continue
    for f in "$sd"/phases/*/events.jsonl "$sd"/features/*/events.jsonl; do
      [ -f "$f" ] || continue
      m=$(jq -rs --argjson now "$now" 'last | select(.step == "refused" and $now - (.time | fromdateiso8601) >= 1800) | .message // "no message"' "$f") ||
        { echo "forge: cannot read $f; skipping its launch-refused check" >&2; continue; }
      [ -n "$m" ] || continue
      notify "forge: launch refused" "${r##*/} $m" ||
        echo "forge: cannot send the launch-refused alert for ${r##*/} through forge notify" >&2
      event "${f%/*}" stall "launch refused: $m" || die "cannot log the stall of the launch refusal in $f"
      echo "forge: stall: launch refused: $m, logged in $f"
    done
  done
}

watchdog_held() {
  local h=${XDG_STATE_HOME:-$HOME/.local/state}/forge/held.jsonl x n r k g t d f c e s o ef rc ds al=
  [ -s "$h" ] || return 0
  [[ ${FORGE_MAX_SESSIONS:-$lim_sessions} =~ ^[1-9][0-9]*$ ]] ||
    { echo "forge: warning: FORGE_MAX_SESSIONS must be a positive integer, got '$FORGE_MAX_SESSIONS'; no held launch runs" >&2; return 0; }
  n=$(claude agents --json </dev/null 6>&- | jq -r --arg re "$forge_session_re" '[.[] | select((.name // "") | test($re))
    | select(.state | IN("blocked", "done", "failed", "stopped", "crashed") | not)] | length') ||
    { echo "forge: warning: cannot list Claude sessions; no held launch runs this scan" >&2; return 0; }
  [ "$n" -lt "${FORGE_MAX_SESSIONS:-$lim_sessions}" ] || return 0
  x=$({ flock 5 && jq -sr 'sort_by(.time)[] | [.root, .kind, .target, .time] | @tsv' "$h"; } 5>>"$h.lock") ||
    { echo "forge: warning: cannot read $h; no held launch runs this scan" >&2; return 0; }
  ef=$(mktemp) || { echo "forge: warning: cannot create a temp file; no held launch runs this scan" >&2; return 0; }
  while IFS=$'\t' read -r r k g t; do
    [ -n "$r" ] || continue
    s='' f=result.json ds=()
    if [ -d "$r/.forge" ]; then
      root_state "$r" || { echo "forge: warning: cannot read the state dir of $r; keeping the held $k $g for the next scan" >&2; continue; }
      case $k in
        phase) ds=("$sd/phases/$g"-*/) ;;
        verify | ship) ds=("$sd/features/${g/\//-}/") f=verify.json ;;
      esac
    fi
    if [ ${#ds[@]} -ne 1 ] || [ ! -d "${ds[0]}" ]; then
      s=gone
    else
      d=${ds[0]%/} e=
      if [ "$k" = ship ]; then
        [ ! -f "$d/verify.json" ] || e=$(jq -r .result "$d/verify.json") || s=err
        [ -n "$s" ] || [ "$e" = pass ] || s=gone
        if [ -z "$s" ] && [ -f "$d/ship.json" ]; then
          e=$(date -u -r "$d/ship.json" +%Y-%m-%dT%H:%M:%SZ) || s=err
          [ -n "$s" ] || [[ ! $e > $t ]] || s=gone
        fi
        if [ -z "$s" ]; then
          [ -n "$al" ] || al=$(claude agents --json --all </dev/null 6>&-) || al=
          [ -n "$al" ] && e=$(jq -r --arg n "${r##*/} ship $g" --arg r "$r" --arg t "$t" 'any(.[]; .name == $n
            and ((.cwd // "") | rtrimstr("/")) == $r and (.startedAt // 0) >= ($t | fromdateiso8601) * 1000)' <<<"$al") || s=err
          [ -n "$s" ] || [ "$e" != true ] || s=gone
        fi
      elif [ -f "$d/$f" ]; then
        s=gone
      elif [ -f "$d/events.jsonl" ]; then
        e=$(jq -rs --arg t "$t" 'any(.[]; .step == "start" and .time >= $t)' "$d/events.jsonl") || s=err
        [ "$e" != true ] || s=gone
      fi
    fi
    [ "$s" != err ] || { echo "forge: warning: cannot check the held $k $g of $r; keeping it for the next scan" >&2; continue; }
    if [ "$s" != gone ]; then
      case $k in phase) c=resume ;; verify) c=implement ;; ship) c=next ;; esac
      rc=0
      FORGE_ROOT=$r FORGE_HELD_SINCE=$t forge "$c" "$g" </dev/null 6>&- 2>"$ef" || rc=$?
      cat "$ef" >&2
      if [ "$rc" != 0 ] && [ "$rc" != 8 ]; then
        e=$(tail -n1 "$ef")
        echo "forge: held $k $g of $r failed to start: ${e:-forge $c $g exited $rc}; retrying next scan" >&2
        continue
      fi
      if grep -qF -e "forge: recorded the held $k $g;" -e "forge: warning: cannot record the held $k $g " "$ef"; then
        echo "forge: the held $k $g of $r is held again; the rest wait for the next scan"
        break
      fi
      if [ "$rc" = 8 ]; then s=refused; else echo "forge: started the held $k $g of $r, held since $t"; fi
    fi
    if ! { flock 5 && o=$(mktemp "$h.XXXXXX") && {
      jq -c --arg r "$r" --arg k "$k" --arg g "$g" --arg t "$t" 'select((.root == $r and .kind == $k and .target == $g and .time == $t) | not)' "$h" >"$o" && mv "$o" "$h" ||
        { rm -f "$o"; false; }
    }; } 5>>"$h.lock"; then
      echo "forge: warning: cannot remove the held $k $g of $r from $h; the next scan checks it again" >&2
      continue
    fi
    [ "$s" != gone ] || echo "forge: dropped the held $k $g of $r, held since $t: it no longer needs launching"
    [ "$s" != refused ] || echo "forge: dropped the held $k $g of $r, held since $t: launch refused, already reported"
  done <<<"$x"
  rm -f "$ef"
}

keep_roots() {
  [ ! -f "$rf" ] || { while IFS= read -r r; do
    if [ -d "$r/.forge/phases" ] || { root_state "$r" && [ -d "$sd/phases" ]; }; then roots[$r]=1; fi
  done <"$rf"; } ||
    echo "forge: cannot read $rf; checking only this scan's project roots for gone sessions" >&2
  printf '%s\n' "${!roots[@]}" >"$rf.$$" && mv "$rf.$$" "$rf" ||
    { rm -f "$rf.$$"; echo "forge: cannot record the project roots in $rf" >&2; }
  return 0
}

root_state() {
  local k
  [ -n "$1" ] || return 1
  if [ -n "${sds[$1]+x}" ]; then
    sd=${sds[$1]}
    [ -n "$sd" ]
    return
  fi
  sd= sds[$1]=
  [ -d "$1/.forge" ] || return 1
  for k in archive phases features; do
    [ ! -d "$1/.forge/$k" ] || [ -z "$(ls -A "$1/.forge/$k")" ] ||
      { echo "forge: $1/.forge still holds planning records; move them to its state dir" >&2; return 1; }
  done
  sd=$(state_dir "$1") || { sd=; return 1; }
  sds[$1]=$sd
}

has_feature() {
  [ "${1##*/}" = "$p" ] && root_state "$1" && [ -d "$sd/features/$tf" ]
}

note_root() {
  local rf=$HOME/.local/state/forge/watchdog-roots
  mkdir -p "${rf%/*}" && { flock 7 && printf '%s\n' "$1" >>"$rf"; } 7>>"$rf.lock" ||
    echo "forge: warning: cannot record $1 in $rf; forge watchdog resumes this parked phase only while its session is listed or once a scan has seen its project" >&2
}

watchdog_enabled() {
  if [ "$(forge_uname)" = Darwin ]; then
    launchctl print "gui/$(id -u)/com.github.claude-forge.watchdog" >/dev/null 2>&1
  else
    systemctl --user is-enabled --quiet forge-watchdog.timer
  fi
}

watchdog_install() {
  local u=$HOME/.config/systemd/user f miss=()
  if [ "$(forge_uname)" = Darwin ]; then
    f=$HOME/Library/LaunchAgents/com.github.claude-forge.watchdog.plist
    [ -f "$f" ] || die "missing $f; install it with ./port --apply in the forge clone, then rerun forge watchdog --install"
    launchctl bootout "gui/$(id -u)/com.github.claude-forge.watchdog" 2>/dev/null || :
    launchctl bootstrap "gui/$(id -u)" "$f" </dev/null || die "launchctl bootstrap $f failed"
    echo "forge: com.github.claude-forge.watchdog loaded"
    return
  fi
  for f in forge-watchdog.service forge-watchdog.timer; do
    [ -f "$u/$f" ] || miss+=("$u/$f")
  done
  [ ${#miss[@]} -eq 0 ] || die "missing ${miss[*]}; install the forge-watchdog units with ./port --apply in the forge clone, then rerun forge watchdog --install"
  systemctl --user enable --now forge-watchdog.timer </dev/null || die "systemctl --user enable --now forge-watchdog.timer failed"
  echo "forge: forge-watchdog.timer enabled and started"
}

unseen() {
  [ "$st" != working ] || [ "$m" -lt "$lim" ] || echo "forge: $1; skipping $name" >&2
}

wake() {
  local k=${d##*/}
  k=${k%%-*}
  cleared "$1" || return 0
  resume_session "forge watchdog: $1 cleared; continue phase $k from where it parked" "$1 cleared" || :
}

cleared() {
  local v c
  case $1 in
    slot | memory | load) ;;
    wait\ *)
      v=${1#wait }
      if [[ $v =~ ^[0-9]+$ ]]; then
        c=$(cat "${d%/phases/*}/root") || { echo "forge: cannot read ${d%/phases/*}/root; $name stays parked" >&2; return 1; }
      elif [[ $v =~ ^(/.+):([0-9]+)$ ]]; then
        c=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
      elif [[ $v =~ ^branch\ ([^ ]+)$ ]]; then
        v=${BASH_REMATCH[1]} c=0
        git -C "$cwd" merge-base --is-ancestor "$v" main 2>/dev/null || c=$?
        [ "$c" -le 1 ] || { echo "forge: cannot read branch $v or main in $cwd; $name stays parked" >&2; return 1; }
        return "$c"
      elif [[ $v =~ ^([^/ ]+)/([^/ ]+)$ ]]; then
        f=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
        c=$(cat "${d%/phases/*}/root") || { echo "forge: cannot read ${d%/phases/*}/root; $name stays parked" >&2; return 1; }
        f=$c/.forge/tracks/$f.json c=0
        [ -f "$f" ] || { echo "forge: no track file $f for wait ${1#wait }; $name stays parked" >&2; return 1; }
        jq -e --arg f "$v" 'any(.shipped[]?; .feature == $f)' "$f" >/dev/null 2>&1 || c=$?
        [ "$c" -le 1 ] || { echo "forge: cannot read $f; $name stays parked" >&2; return 1; }
        return "$c"
      else
        echo "forge: malformed wait ref '${1#wait }', expected <N>, <abs-root>:<N>, <track>/<feature> or branch <name>; $name stays parked" >&2
        return 1
      fi
      [ -d "$c/.forge" ] || { echo "forge: no .forge in $c; $name stays parked" >&2; return 1; }
      root_state "$c" || { echo "forge: cannot read the state dir of $c; $name stays parked" >&2; return 1; }
      (
        root=$c state=$sd
        x=("$state/phases/$v"-*/)
        [ ${#x[@]} -eq 1 ] && [ -f "${x[0]}spec.json" ] || exit 1
        t=$(jq -r .track "${x[0]}spec.json") && f=$(jq -r .feature "${x[0]}spec.json") || exit 1
        merged "$v"
      ) ;;
    *) return 1 ;;
  esac
}

listed() {
  claude agents --json --all </dev/null 6>&- | jq -r --arg i "$id" '.[] | select(.id == $i) | "\(.pid // "")/\(.state)"'
}

shell_of() {
  local r=${FORGE_PROC_ROOT:-/proc} p
  for p in $(cat "$r/$1"/task/*/children 2>/dev/null </dev/null); do
    if grep -qaF shell-snapshots/ "$r/$p/cmdline" 2>/dev/null; then echo "$p"; return 0; fi
    shell_of "$p" && return 0
  done
  return 1
}

orphan() {
  local c f=("${FORGE_PROC_ROOT:-/proc}"/[0-9]*/cmdline)
  [ ${#f[@]} -gt 0 ] || return 1
  while IFS= read -r c; do
    c=${c%/cmdline}
    grep -qzxF "CLAUDE_CODE_SESSION_ID=$1" "$c/environ" 2>/dev/null && { echo "${c##*/}"; return 0; }
  done < <(grep -laF shell-snapshots/ "${f[@]}" 2>/dev/null </dev/null)
  return 1
}

unreported() {
  local x i e o m now r=${FORGE_PROC_ROOT:-/proc} h= hs= l= dd= dx= tl=
  x=$(jq -rRn 'reduce (inputs | fromjson? | objects
    | ({i: (select(.type == "user") | .toolUseResult | objects | (.backgroundTaskId // (select(has("timeoutMs")) | .taskId) // (select(.status == "async_launched") | .agentId)) | strings), o: true,
        t: ((try (.timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) // null)},
      (select(.type == "user" or .type == "queue-operation") | (if .type == "user" then .message.content? else .content end) | strings
        | select(startswith("<task-notification>")) | {i: capture("<task-id>(?<i>[^<]+)</task-id>").i, o: ((contains("<status>") | not) or contains("may be interim") or contains("waiting on its own background work"))}))) as $x
    ({}; .[$x.i] |= {o: $x.o, t: ($x.t // .t?)})
    | to_entries[] | select(.value.o) | [.key, (.value.t // "" | tostring)] | @tsv' "$1") || return 1
  if [ -e "$4/events.jsonl" ]; then
    dx=$(jq -r 'select(.step == "resume") | .dead | arrays | .[] | strings' "$4/events.jsonl") || return 1
  fi
  now=$(date +%s)
  while IFS=$'\t' read -r i e; do
    [ -n "$i" ] || continue
    o=${CLAUDE_CODE_TMPDIR:-${TMPDIR:-/tmp}}/claude-$UID/${2//[^a-zA-Z0-9]/-}/$3/tasks/$i.output
    if ! m=$(LC_ALL=C stat -L -c %Y -- "$o" 2>&1); then
      if [[ $m != *"No such file or directory"* ]]; then
        echo "forge: warning: cannot stat $o: $m; counting background task $i in flight" >&2
        l+=${l:+, }$i tl+=${tl:+$'\t'}$e:$i
        continue
      fi
      m=0
    fi
    [ $((now - m)) -ge 600 ] || { l+=${l:+, }$i tl+=${tl:+$'\t'}$e:$i; continue; }
    [ -n "$h" ] || { h=1; hs=$(find "$r"/[0-9]*/fd -maxdepth 1 -type l -printf '%l\n' 2>/dev/null) || :; }
    if grep -qxF -e "$o" -e "$(readlink -m -- "${o%/*}")/$i.output" <<<"$hs"; then l+=${l:+, }$i tl+=${tl:+$'\t'}$e:$i; elif ! grep -qxF -e "$i" <<<"$dx"; then dd+=${dd:+, }$i; fi
  done <<<"$x"
  printf '%s\n%s\n%s\n' "$l" "$dd" "$tl"
}

stop_cause() {
  local x k v t r u z re='resets (([A-Z][a-z]{2}) ([0-9]{1,2}), )?([0-9]{1,2})(:([0-9]{2}))?(am|pm) \(([A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*)\)'
  x=$(tail -n 400 "$1" | jq -rRn 'def note: (if .type == "user" then .message.content? elif .type == "queue-operation" then .content else null end) | strings | select(startswith("<task-notification>"));
    [inputs | fromjson? | objects | select(.type == "assistant" or .type == "user" or .type == "queue-operation")
      | .at = ((.timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601) // null)] as $r
    | ([range($r | length) as $i | select($r[$i].type == "assistant") | $i] | last) as $i
    | $r[($i // -1) + 1:] as $t
    | select(all($t[]; .type != "user" or ([note] != [])))
    | if $i != null and $r[$i].isApiErrorMessage == true then $r[$i]
        | if .error == "rate_limit" then (.quotaLimits.resetsAt | numbers | ["limit", ., null]) // ["text", ([.message.content | if type == "string" then . else .[]? | .text? end | strings] | join(" ")), .at]
          else ["error", (.error // "unknown"), .at] end
      else first(([range($t | length) as $j | $t[$j] | select(note | contains("was restarted after the previous session ended") or contains("didn\u0027t finish before the previous session ended"))
            | ((note | (capture("<task-id>(?<i>[^<]+)</task-id>")? | .i)) // null) as $id
            | select(any($t[$j + 1:][] | note | select(contains("<status>")) | (capture("<task-id>(?<i>[^<]+)</task-id>")? | .i); . == $id) | not)]
          | last | select(. != null) | ["reboot", "", .at]),
          ($t | map(select(note | contains("<status>killed</status>"))) | last | select(. != null) | ["killed", "", .at])) // empty end
    | map(. // "" | tostring | gsub("[\n\u001f]"; " ")) | join("\u001f")') || return 1
  [ -n "$x" ] || return 0
  IFS=$'\x1f' read -r k v t <<<"$x"
  [ "$k" = limit ] || [ -n "$t" ] || { echo "forge: the stop record of $name in $1 has no timestamp; alerting on its ended turn" >&2; return 0; }
  case $k in
    limit) printf 'usage limit\t%s\n' "$v" ;;
    error) printf 'API error %s\t%s\n' "$v" "$t" ;;
    reboot) printf 'reboot\t%s\n' "$t" ;;
    killed)
      u=$(forge_uptime) && [[ $u =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
        { echo "forge: cannot read the uptime from ${FORGE_PROC_ROOT:-/proc}/uptime; $name counts as not rebooted" >&2; return 0; }
      [ "$t" -ge $(($(date +%s) - ${u%%.*})) ] || printf 'reboot\t%s\n' "$t" ;;
    text)
      if [[ $v =~ $re ]] && z=${BASH_REMATCH[8]} && [ -f "${TZDIR:-/usr/share/zoneinfo}/$z" ]; then
        u="${BASH_REMATCH[4]}:${BASH_REMATCH[6]:-00}${BASH_REMATCH[7]}"
        if [ -n "${BASH_REMATCH[1]}" ]; then
          r=$(date -d "TZ=\"$z\" ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} $u" +%s 2>/dev/null) || r=
        else
          r=$(date -d "TZ=\"$z\" $(TZ=$z date -d "@$t" +%F) $u" +%s 2>/dev/null) || r=
          [ -z "$r" ] || [ "$r" -gt "$t" ] || r=$(date -d "TZ=\"$z\" $(TZ=$z date -d "@$((t + 86400))" +%F) $u" +%s 2>/dev/null) || r=
        fi
        [ -z "$r" ] || { printf 'usage limit\t%s\n' "$r"; return 0; }
      fi
      printf 'API error rate_limit\t%s\n' "$t" ;;
  esac
}

waits_on() {
  tail -n 400 "$1" | jq -eRn --arg n "$2" '[inputs | fromjson? | objects | select(.type == "assistant")
    | [.message.content | if type == "string" then . else .[]? | select(.type == "text") | .text end | strings] | join("\n") | select(. != "")]
    | last // "" | test("(^|\n)result: Phase 0*\($n | ltrimstr("0")) waits on ")' >/dev/null
}

ship_replied() {
  local x
  x=$(tail -n 400 "$1") || return 2
  jq -eRn '[inputs | fromjson? | objects | select(.type == "assistant" or .type == "user")]
    | ([range(length) as $i | select(.[$i] | .type == "user" and .origin.kind == "human") | $i] | last // -1) as $u
    | any(.[$u + 1:][] | select(.type == "assistant" and .isApiErrorMessage != true)
      | [.message.content | if type == "string" then . else .[]? | select(.type == "text") | .text end | strings] | join("\n");
      test("(^|\n)result: "))' <<<"$x" >/dev/null
}

end_text_jq='def end_text: last as $l
  | if $l.type == "assistant" and $l.message.stop_reason == "end_turn" then
      [.[] | select(.type == "assistant" and (. == $l or ($l.message.id != null and .message.id == $l.message.id)))
        | .message.content | if type == "string" then . else arrays | .[] | objects | select(.type == "text") | .text | strings end]
      | join("\n")
    else null end;
  [inputs | fromjson? | objects | select(.type == "assistant" or .type == "user")]'

pending_question() {
  local x
  x=$(tail -n 400 "$1") || return 2
  jq -eRn "$end_text_jq"' as $r
    | ([$r[] | select(.type == "user") | .message.content | arrays | .[] | objects | select(.type == "tool_result") | .tool_use_id | strings | {(.): true}] | add // {}) as $done
    | any($r[] | select(.type == "assistant") | .message.content | arrays | .[] | objects | select(.type == "tool_use") | .id | strings; $done[.] | not)
      or (($r | end_text | strings | .[-800:] | sub("\\s+\\z"; "") | test("(^|\n)[ \t]*(needs input|blocked):") or endswith("?")) // false)' <<<"$x" >/dev/null
}

asked() {
  local x
  x=$(tail -n 400 "$1") || return 1
  jq -rRn "$end_text_jq"' | end_text | strings | [splits("\n[ \t]*\n") | gsub("^\\s+|\\s+$"; "") | select(. != "")] | last // "" | select(endswith("?")) | gsub("\\s*\n\\s*"; " ")' <<<"$x"
}

notified() {
  jq -rRn '[inputs | fromjson? | objects | select(.type == "assistant" or .type == "user")]
    | ([range(length) as $i | select(.[$i] | .type == "user" and (.message.content
        | if type == "string" then startswith("<task-notification>") | not
          else any(.[]?; type == "object" and .type != "tool_result" and (((.text | strings) // "" | startswith("<task-notification>")) | not)) end)) | $i]
      | last // -1) as $u
    | any(.[$u + 1:][] | select(.type == "assistant") | .message.content | arrays | .[] | objects
      | select(.type == "tool_use" and .name == "Bash") | .input.command | strings
      | gsub("\u0027[^\u0027]*\u0027|\"(\\\\.|[^\"\\\\])*\""; ""); test("(^|[;&|\n(])\\s*([A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)*(\\S*/)?forge\\s+notify\\b"))' "$1"
}

auto_count() {
  [ -f "$1/events.jsonl" ] || { echo 0; return 0; }
  jq -s 'map(select(.step == "resume" and (.message | strings | startswith("auto-resume")))) | length' "$1/events.jsonl"
}

auto_resume() {
  local c=${1%%$'\t'*} at=${1#*$'\t'} k=$2
  [ "$k" -lt 5 ] || return 0
  [ "$c" != "usage limit" ] || [ "$now" -ge $((at + 60)) ] || return 0
  if [[ $c == "API error "* ]] && ! getent hosts api.anthropic.com >/dev/null; then
    echo "forge: $name waits for api.anthropic.com to resolve" >&2
    return 0
  fi
  k=$((k + 1))
  resume_session "forge watchdog: $c cleared; continue ${wh:-phase $n} from where it stopped" "auto-resume $k/5 after $c" "$st" || return 0
  notify "forge: auto-resume" "$p ${wh:-phase ${d##*/}}: $name stopped by $c; resume $k/5" ||
    echo "forge: cannot send the auto-resume notice for $name through forge notify" >&2
}

heal_line() {
  local x
  x=$(tail -n 400 "$1") || return 2
  jq -rRn "$end_text_jq"' | end_text | strings | .[-800:] | sub("\\s+\\z"; "")
    | [match("(^|\n)[ \t]*((needs input|failed):[^\n]*)"; "g").captures[1].string] | last // empty' <<<"$x"
}

heal_of() {
  local x a
  [ -n "$n" ] || return 1
  if [ -f "$d/result.json" ]; then
    x=$(jq -r 'if .status == "blocked" then "blocked: " + ((.summary // "") | tostring) else "" end' "$d/result.json" 2>/dev/null) || return 2
    [ -n "$x" ] || return 1
    [[ ! ${x#blocked: } =~ ^phase\ 0*$((10#$n))\ already\ has\ a\ running\ session ]] || return 1
    if a=$(jq -r '"\(.track)-\(.feature)"' "$d/spec.json" 2>/dev/null); then [ ! -d "$sd/archive/$a" ] || return 1; fi
    a=$(stat -c %Y "$d/result.json" 2>/dev/null) || return 2
    [ $(( $(date +%s) - a )) -le 604800 ] || return 1
  else
    x=$(heal_line "${ts[0]}") || return 2
    [ -n "$x" ] || return 1
  fi
  echo "$x"
}

heal_count() {
  [ -f "$1/events.jsonl" ] || { printf '0\nfalse\n'; return 0; }
  jq -rs '(to_entries | map(select(.value.step == "resume" and (.value.message | strings | startswith("self-heal"))))) as $r
    | ($r | length), (($r | last | .key // -1) as $i | any(.[$i + 1:][]; .step == "stall" and (.message | strings | contains("self-heal") and endswith("; gave up"))))' "$1/events.jsonl"
}

heal_cap() {
  local line=$1 who=$2 g
  hk=$(heal_count "$d") || { echo "forge: cannot read the self-heals of $name from $d/events.jsonl; not resuming it" >&2; return 1; }
  { read -r hk; read -r g; } <<<"$hk"
  [ "$hk" -ge 3 ] || return 0
  [ "$g" != true ] || return 1
  notify "forge: self-heal gave up" "$p phase ${d##*/}: $name still stops after 3 self-heals; last line: ${line:0:200}" ||
    { echo "forge: cannot send the self-heal give-up alert for $name through forge notify" >&2; return 1; }
  event "$d" stall "$who stops on '$line' after 3 self-heals; gave up" || die "cannot log the stall of $name in $d/events.jsonl"
  echo "forge: stall: $who stops on '$line' after 3 self-heals; gave up, logged in $d/events.jsonl"
  return 1
}

self_heal() {
  local hk
  heal_cap "$1" "$name ($sid)" || return 0
  resume_session "forge watchdog: no operator is present; fix the blocker yourself and continue phase $n from where it stopped" "self-heal $((hk + 1))/3 on '$1'" "$st" || return 0
  [ ! -f "$d/result.json" ] || rm -f "$d/result.json" || echo "forge: warning: cannot remove $d/result.json after the self-heal of $name" >&2
}

resume_session() {
  local l=${XDG_RUNTIME_DIR:-$HOME/.local/state}/forge r=0
  [ -d "$cwd" ] || { echo "forge: the cwd $cwd of $name ($sid) is gone; not resuming it" >&2; return 1; }
  [ "$id" != - ] || { echo "forge: $name ($sid) has no session id; not resuming it" >&2; return 1; }
  mkdir -p "$l" && exec 6>"$l/sessions.lock" || { echo "forge: cannot open $l/sessions.lock; not resuming $name ($sid)" >&2; return 1; }
  resume_held "$@" || r=1
  exec 6>&-
  return "$r"
}

resume_held() {
  local f=$sid t=$HOME/.claude/projects/${cwd//[^a-zA-Z0-9]/-}/$sid.jsonl s x o i=0 now= b dk= dm=
  local sid
  flock 6 || { echo "forge: cannot lock sessions.lock; not resuming $name ($f)" >&2; return 1; }
  s=$(listed) || { echo "forge: cannot list Claude sessions; not resuming $name ($f)" >&2; return 1; }
  case $s in
    "") echo "forge: claude agents no longer lists $name ($f); not resuming it" >&2; return 1 ;;
    */blocked) [ "${3:-}" = blocked ] || { echo "forge: $name ($f) is blocked again; not resuming it" >&2; return 1; } ;;
    */working) [ "${3:-}" = working ] || { echo "forge: $name ($f) is working again; not resuming it" >&2; return 1; } ;;
  esac
  if [ -n "${s%%/*}" ]; then
    if x=$(shell_of "${s%%/*}"); then
      echo "forge: $name ($f) has a running Bash process $x in flight; not stopping it" >&2
      return 1
    fi
    x=$(unreported "$t" "$cwd" "$f" "$d") || { echo "forge: cannot read the background tasks of $name ($f) from $t; not stopping it" >&2; return 1; }
    { IFS= read -r x; IFS= read -r dk || :; } <<<"$x"
    [ -z "$x" ] || { echo "forge: $name ($f) has background task $x unreported in flight; not stopping it" >&2; return 1; }
    if [ -n "$dk" ]; then
      echo "forge: $name ($f): background task(s) $dk dead (no process, output idle over 10 min); resuming" >&2
      dm="; background task(s) $dk dead"
    fi
    claude stop "$id" </dev/null >/dev/null 6>&- || :
    until s=$(listed) && [[ $s =~ ^/ && ! $s =~ /(working|blocked)$ ]]; do
      i=$((i + 1))
      [ $i -lt 10 ] || { echo "forge: $name ($f) still runs after claude stop; resuming it next scan" >&2; return 1; }
      sleep "${FORGE_WATCHDOG_POLL_SECS:-0.5}"
    done
  elif x=$(orphan "$f"); then
    echo "forge: $name ($f) has a running Bash process $x in flight with no Claude process; not resuming it" >&2
    return 1
  fi
  b=$(date +%s%3N)
  started "$cwd" "$name" "$1" "" "$f" || { echo "forge: claude --bg --resume $f failed for $name; it stays parked until the next scan" >&2; return 1; }
  [ -n "$sid" ] || sid=$(took "$b")
  if [ -z "$sid" ]; then
    echo "forge: warning: cannot find the session that took the resume of $name; recording it as unknown, so no scan resumes $id again" >&2
    notify "forge: resume unconfirmed" "$p ${wh:-phase ${d##*/}}: $name was resumed, but its session is unknown and the watchdog no longer follows it" ||
      echo "forge: cannot send the unconfirmed-resume alert for $name through forge notify" >&2
    sid=unknown
  fi
  if [ "$sid" != "$id" ]; then
    o=$(jq -rs 'map(select(.step == "start")) | last | .offset // empty' "$d/events.jsonl") ||
      { echo "forge: warning: cannot read the last start offset in $d/events.jsonl; recording session $sid without one" >&2; o=; }
    event "$d" start "$name" "$o" "$sid" || die "resumed $name as session $sid but cannot log it in $d/events.jsonl"
    now="; now session $sid"
    if ! x=$(listed); then
      echo "forge: warning: cannot list Claude sessions; the superseded session $id of $name may still run" >&2
    elif [[ $x =~ ^[0-9] || $x =~ /(working|blocked)$ ]]; then
      claude stop "$id" </dev/null >/dev/null 6>&- || echo "forge: warning: claude stop $id failed; the superseded session of $name may still run" >&2
    fi
  fi
  event "$d" resume "$2; resumed $name with claude --bg --resume $f$now$dm" "" "" "$dk" || die "resumed $name but cannot log it in $d/events.jsonl"
  echo "forge: resume: $2; resumed $name ($f) with claude --bg --resume $f$now$dm, logged in $d/events.jsonl"
}

took() {
  local x i=0
  while :; do
    x=$(claude agents --json --all </dev/null 6>&- | jq -r --arg i "$id" --arg n "$name" --arg c "$cwd" --argjson t "$1" '([.[] | select(.id != $i and .name == $n and .cwd == $c and (.startedAt // 0) >= $t)] | max_by(.startedAt) | .id)
      // first(.[] | select(.id == $i and (.pid != null or .state == "working" or .state == "blocked")) | .id) // empty') || x=
    [ -z "$x" ] || { echo "$x"; return 0; }
    i=$((i + 1))
    [ $i -lt 10 ] || return 0
    sleep "${FORGE_WATCHDOG_POLL_SECS:-0.5}"
  done
}

revive() {
  local d e k c s name cwd t f w l n h q
  root_state "$1" || return 0
  for d in "$sd"/phases/*/; do
    d=${d%/} k=${d##*/}
    k=${k%%-*} n=$k h=
    [ -f "$d/events.jsonl" ] || continue
    e=$(jq -rs "$park_defs"' (map(select(.step == "start")) | last) as $s | select($s != null)
      | [(if parked then parked.message else "" end), $s.session // "", $s.message // ""] | join("\u001f")' "$d/events.jsonl") ||
      { echo "forge: cannot read $d/events.jsonl; not resuming phase $k" >&2; continue; }
    [ -n "$e" ] || continue
    IFS=$'\x1f' read -r c s name <<<"$e"
    if [ -z "$c" ]; then
      [ -f "$d/result.json" ] || continue
      q=0
      h=$(heal_of) || q=$?
      [ "$q" != 2 ] || echo "forge: cannot read $d/result.json; not resuming phase $k" >&2
      [ "$q" = 0 ] || continue
    fi
    l=$(jq -r --arg s "$s" --arg n "$name" 'first(.[] | select(if $s != "" then .id == $s else .name == $n end) | .cwd // "") // "-"' <<<"$a") ||
      { echo "forge: cannot list Claude sessions; skipping phase $k" >&2; continue; }
    [ "$l" = - ] || continue
    t=$(jq -r .track "$d/spec.json") && f=$(jq -r .feature "$d/spec.json") && cwd=$(root=$1 && repo "$d") ||
      { echo "forge: cannot find the repo of phase $k in $1; not resuming it" >&2; continue; }
    ! passed "$d" || ! git -C "$cwd" merge-base --is-ancestor "$(branch_of "$t/$f" "$k")" "$(branch_of "$t/$f")" || continue
    w=$(wt_of "$cwd" "$t/$f" "$k")
    [ ! -d "$w" ] || cwd=$w
    if [ -n "$h" ]; then
      revive_heal "$1" "$h" || :
      continue
    fi
    cleared "$c" || continue
    revive_one "$1" || :
  done
}

revive_one() {
  local e w
  e=0
  FORGE_ROOT=$1 forge resume "$k" </dev/null 6>&- || e=$?
  if [ "$e" = 8 ]; then
    echo "forge: forge resume $k refused for $name, already reported; phase $k stays parked until the next scan" >&2
    return 1
  elif [ "$e" != 0 ]; then
    echo "forge: forge resume $k failed for $name; phase $k stays parked until the next scan" >&2
    return 1
  fi
  w=$(jq -rs 'last.step' "$d/events.jsonl") || { echo "forge: cannot read $d/events.jsonl after forge resume $k; not logging its resume" >&2; return 0; }
  if [ "$w" = wait ]; then
    echo "forge: forge resume $k found no free session for $name; phase $k stays parked until the next scan" >&2
    event "$d" park "$c" || die "cannot log phase $k as parked again in $d/events.jsonl"
    return 1
  fi
  event "$d" resume "$c cleared; $name is gone, resumed phase $k with forge resume" || die "resumed phase $k but cannot log it in $d/events.jsonl"
  echo "forge: resume: $c cleared; $name is gone, resumed phase $k with forge resume, logged in $d/events.jsonl"
}

revive_heal() {
  local hk e=0 w p=${1##*/}
  heal_cap "$2" "$name" || return 1
  FORGE_ROOT=$1 forge resume "$k" </dev/null 6>&- || e=$?
  if [ "$e" = 8 ]; then
    echo "forge: forge resume $k refused for $name, already reported; phase $k stays blocked until the next scan" >&2
    return 1
  elif [ "$e" != 0 ]; then
    echo "forge: forge resume $k failed for $name; phase $k stays blocked until the next scan" >&2
    return 1
  fi
  w=$(jq -rs 'last.step' "$d/events.jsonl") || { echo "forge: cannot read $d/events.jsonl after forge resume $k; not logging its resume" >&2; return 0; }
  if [ "$w" = wait ]; then
    echo "forge: forge resume $k found no free session for $name; phase $k waits for one" >&2
    return 1
  fi
  event "$d" resume "self-heal $((hk + 1))/3 on '$2'; $name is gone, resumed phase $k with forge resume" || die "resumed phase $k but cannot log it in $d/events.jsonl"
  echo "forge: resume: self-heal $((hk + 1))/3 on '$2'; $name is gone, resumed phase $k with forge resume, logged in $d/events.jsonl"
}
