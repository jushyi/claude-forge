land_test() {
  if [ -n "${FORGE_LAND_TEST:-}" ]; then
    "$FORGE_LAND_TEST" "$1"
  else
    "${D%/forge.d}/forge" test "$1"
  fi
}

unlock() {
  exec 9>&-
  locked=
}

land_merge() {
  local out s=0
  out=$(git -C "$wt" merge -q --no-ff -m "$2" "$1" 2>&1) || s=$?
  [ $s -ne 0 ] || return 0
  if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    printf '%s\n' "$out" >&2
    exit 1
  fi
  conflicts=$(git -C "$wt" -c core.quotePath=false diff --name-only --diff-filter=U | paste -sd ' ')
  git -C "$wt" merge --abort || die "git merge --abort failed in $wt"
  return 1
}

integrate() {
  git -C "$wt" reset -q --hard && git -C "$wt" checkout -q --detach "$1" && git -C "$wt" clean -fdq || die "cannot reset $wt to $1"
  if [ -n "$push" ] && ! git -C "$wt" merge-base --is-ancestor origin/main HEAD; then
    if git -C "$wt" merge-base --is-ancestor "$sha" origin/main && git -C "$wt" merge-base --is-ancestor HEAD origin/main; then
      git -C "$wt" merge -q --ff-only origin/main || die "cannot fast-forward $wt to origin/main"
    else
      land_merge origin/main "Merge origin/main" ||
        die "origin/main conflicts with main in: $conflicts; merge origin/main into main by hand, then land again" 4
    fi
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$sha" HEAD; then
    land_merge "$sha" "Merge branch '$branch'" ||
      die "$branch conflicts with main in: $conflicts; run 'forge merge main' in its worktree, then land again" 4
  fi
  m=$(git -C "$wt" rev-parse HEAD)
}

fetch_main() {
  local e
  git -C "$top" remote get-url origin >/dev/null 2>&1 || return 0
  if ! e=$(GIT_TERMINAL_PROMPT=0 git -C "$top" fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>&1); then
    e=${e##*$'\n'}
    [ -z "$push" ] || die "cannot fetch main from origin in $top${e:+: $e}"
    echo "forge: warning: cannot fetch main from origin in $top${e:+: $e}" >&2
    return 0
  fi
  [ -n "$push" ] || git -C "$top" merge-base --is-ancestor origin/main main ||
    die "origin/main has commits local main lacks in $top (a merged PR?); set git config forge.pushMain true so land brings them in, then land again"
}

prune_remote() {
  local tip om
  [ "$1" != main ] || return 0
  om=$(git -C "$top" rev-parse -q --verify origin/main) || return 0
  tip=$(GIT_TERMINAL_PROMPT=0 git -C "$top" ls-remote --heads origin "refs/heads/$1" | cut -f1) || {
    echo "forge: warning: kept origin/$1; cannot list it on origin" >&2
    return 0
  }
  [ -n "$tip" ] || return 0
  if git -C "$top" merge-base --is-ancestor "$tip" origin/main 2>/dev/null &&
    GIT_TERMINAL_PROMPT=0 git -C "$top" push -q --atomic origin "--force-with-lease=refs/heads/main:$om" "$om:refs/heads/main" \
      "--force-with-lease=refs/heads/$1:$tip" ":refs/heads/$1"; then
    echo "forge: deleted origin/$1"
  else
    echo "forge: warning: kept origin/$1" >&2
  fi
}

names() { git -C "$top" diff --name-only --no-renames "$@"; }

stamp_scan() {
  local n=0 o=0 k t c d x old
  local -a dirs=("$hs")
  [ -d "$hs" ] || return 0
  [ ! -d "$hs/changed" ] || dirs+=("$hs/changed")
  old=$(($(date +%s) - 21600))
  while read -r t c d; do
    if [ "$d" = "$hs/changed" ]; then o=$((o + 1)) k=$o; else n=$((n + 1)) k=$n; fi
    [ $k -le 60 ] || [ "${t%.*}" -ge $old ] || continue
    git -C "$top" cat-file -e "$c^{tree}" 2>/dev/null || continue
    x=$(names "$c" "$m" | sed '\#^\.forge/TESTING\.md$#b; \#^\.forge/#d') || return 1
    [ -z "$x" ] || continue
    [ -f "$hs/$c" ] || full_chain "$top" "$hs" "$c" "$m" || continue
    echo "$c"
    return 0
  done < <(find "${dirs[@]}" -mindepth 1 -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{40}' -printf '%T@ %f %h\n' | sort -rn)
}

land() {
  local repo=$1 branch=$2 top ll wt b base now m moved out paths i s sha push= root conflicts tree hs c e
  [[ $repo == /* ]] || repo=$start/$repo
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $repo"
  root=$top
  sha=$(git -C "$top" rev-parse -q --verify "$branch^{commit}") || die "unknown branch $branch in $top"
  [ "$(git -C "$top" rev-parse --symbolic-full-name "$branch")" != refs/heads/main ] || die "cannot land main onto itself"
  b=$(git -C "$top" branch --show-current)
  [ "$b" = main ] || die "$top is on ${b:-a detached HEAD}, not main"
  [ "$(git -C "$top" config --bool forge.pushMain)" != true ] || push=1
  wt=$top/.claude/worktrees/_land
  ll=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/forge-land.lock
  exec 8>"$ll"
  wait_lock 8 "$ll"
  exclude "$top"
  [ ! -f "$wt/.git" ] || [ -d "$(sed -n 's/^gitdir: //p' "$wt/.git")" ] || rm -rf "$wt"
  [ -d "$wt" ] || git -C "$top" worktree add -q -f --detach "$wt" main || die "cannot create $wt"
  [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$wt" ] || die "$wt is not a worktree of $top"
  hs=$(host_stamps "$top") || exit
  for i in 1 2 3 4 5; do
    fetch_main
    base=$(git -C "$top" rev-parse main)
    integrate "$base"
    s=0 tree=$(git -C "$top" rev-parse "$m^{tree}") || exit 1
    [ -f "$hs/$tree" ] || full_chain "$top" "$hs" "$tree" "$m" || tree=$(stamp_scan) || exit 1
    if [ -n "$tree" ]; then
      echo "forge: tests passed ($(git -C "$top" rev-parse --short "$tree")), cached" >&2
    else
      land_test "$wt" >&2 8>&- || s=$?
    fi
    if [ $s -eq 5 ] && tests_none "$wt"; then
      echo "forge: warning: $wt declares \"- All tests: none\"; landing $branch untested" >&2
    elif [ $s -ne 0 ]; then
      die "tests failed in $wt with $branch merged into main at ${base:0:7}; nothing landed" 7
    fi
    lock
    fetch_main
    now=$(git -C "$top" rev-parse main)
    if [ "$now" != "$base" ] || { [ -n "$push" ] && ! git -C "$top" merge-base --is-ancestor origin/main "$m"; }; then
      moved=$({ names "$base" "$now"; [ -z "$push" ] || names "$(git -C "$top" merge-base "$m" origin/main)" origin/main; } | sed '\#^\.forge/#d')
      if [ -n "$moved" ]; then
        unlock
        continue
      fi
      integrate "$now"
    fi
    b=$(git -C "$top" branch --show-current)
    [ "$b" = main ] || die "$top is on ${b:-a detached HEAD}, not main; nothing landed"
    out=$(git -C "$top" merge -q --ff-only "$m" 2>&1) || {
      paths=$(sed -n 's/^\t//p' <<<"$out" | paste -sd ' ')
      [ -n "$paths" ] || { printf '%s\n' "$out" >&2; exit 1; }
      die "$top has local changes to $paths, which landing $branch changes; commit or move them, then land again" 6
    }
    echo "forge: landed $branch as $(git -C "$top" rev-parse --short "$m") on main"
    uptodate=
    if [ -n "$push" ]; then
      if [ -n "$(git -C "$top" rev-list -n1 origin/main..main)" ]; then
        push_main "$top"
      else
        pushed= uptodate=1
        echo "forge: nothing to push; origin has main"
      fi
      if [ -n "$pushed$uptodate" ]; then
        prune_remote "$branch"
      fi
    fi
    unlock
    exec 8>&-
    return 0
  done
  die "main kept moving outside .forge/ while $branch was tested; tested $i times, nothing landed" 5
}

forge_agents() {
  local x
  x=$(timeout -k 2 "${FORGE_AGENTS_TIMEOUT:-30}" claude agents --json </dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$x" || return 1
  printf '%s' "$x"
}

forge_count() {
  jq --arg me "${2:-}" --arg dir "${3:-}" '[.[] | select(.state == "working" and .sessionId != $me and ((.name // "") | test("^(Discuss|Quick|Debug|Fast|New|Port) |^[^ ]+ [^ ]+ (Phase [0-9]+( retry [0-9]+)?|Verify|Ship)$|^[^ ]+ (discuss|quick|fast|debug|new|port)( |$)|^[^ ]+ (P[0-9]+(R[0-9]+)?|verify|ship) [^ /]+/[^ /]+$")) and ((.cwd // "") as $c | $dir == "" or $c == "" or $c == $dir or ($c | startswith($dir + "/")) or ($dir | startswith($c + "/"))))] | length' <<<"$1"
}

forge_working() {
  local x
  x=$(forge_agents) || return 1
  forge_count "$x" "${1:-}" "${2:-}"
}

port_scope() {
  [ "$(git -C "$1" config --bool forge.liveInstall)" = true ] || printf '%s' "$1"
}

queue_port() {
  local top=$1 fr=$2 dir=$HOME/.local/state/forge p t c o
  shift 2
  p=$dir/port.pending
  c=$(git -C "$top" rev-parse main) \
    && mkdir -p "$dir" && exec 7>"$p.lock" && flock 7 && t=$(mktemp "$p.XXXXXX") || die "cannot queue the port in $p; landed, not ported"
  { o=$([ ! -f "$p" ] || jq -c --arg r "$top" 'select(.repo == $r) | {time, branches}' "$p") && o=${o##*$'\n'} \
    && { [ -n "$o" ] || o='{}'; } \
    && { [ ! -f "$p" ] || jq -c --arg r "$top" 'select(.repo != $r)' "$p"; } >"$t" \
    && jq -nc --arg r "$top" --arg c "$c" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg f "$fr" --argjson o "$o" \
      '{repo: $r, commit: $c, time: ($o.time // $t), root: $f, branches: ((($o.branches // []) + $ARGS.positional) | unique)}' --args "$@" >>"$t" \
    && mv "$t" "$p"; } \
    || { rm -f "$t"; die "cannot queue the port in $p; landed, not ported"; }
  exec 7>&-
}

bin_ready() {
  local p=() d r
  for d in templates schemas; do [ ! -e "$1/$d" ] || p+=("$d"); done
  [ ${#p[@]} -gt 0 ] || return 0
  r=$(jq -r '.rest.commit // empty' "$HOME/.local/state/forge/port.json" 2>/dev/null) && [ -n "$r" ] \
    && git -C "$1" cat-file -e "$r^{commit}" 2>/dev/null && git -C "$1" diff --quiet "$r" main -- "${p[@]}"
}

golive() {
  local repo=$1 top ll out sha n why= bf= pf=
  land "$1" "$2"
  [[ $repo == /* ]] || repo=$start/$repo
  top=$(git -C "$repo" rev-parse --show-toplevel)
  ll=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/forge-land.lock
  exec 8>"$ll"
  wait_lock 8 "$ll"
  if [ "$(git -C "$top" config --bool forge.pushMain)" != true ]; then
    echo "forge: not pushed: forge.pushMain unset"
  elif [ -n "$uptodate" ]; then
    echo "forge: not pushed: nothing to push"
  elif [ -z "$pushed" ]; then
    echo "forge: not pushed: pushing main to origin failed"
  fi
  if [ ! -x "$top/port" ]; then
    echo "forge: no port"
    return 0
  fi
  if ! n=$(forge_working "${CLAUDE_CODE_SESSION_ID:-}" "$(port_scope "$top")"); then
    why="cannot list Claude sessions"
  elif [ "$n" -gt 0 ]; then
    why="$n forge sessions working"
  fi
  if [ -n "$why" ]; then
    queue_port "$top" "$root" "$2"
    if [ -d "$top/bin" ] && ! bin_ready "$top"; then
      echo "forge: bin held: templates/ or schemas/ changed since the last full port"
    elif [ -d "$top/bin" ]; then
      out=$(cd "$top" && ./port --apply --only bin </dev/null) || bf=1
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      if [ -z "$bf" ]; then
        sha=$(sed -n 's/^ported //p' <<<"$out" | tail -n1)
        echo "forge: ported bin ${sha:-$(git -C "$top" rev-parse --short HEAD)}"
      fi
    fi
    echo "forge: port queued: $why"
    [ -z "$bf" ] || die "./port --apply --only bin failed in $top; port queued"
    return 0
  fi
  out=$(cd "$top" && ./port --apply </dev/null) || pf=1
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ -z "$pf" ] || die "./port --apply failed in $top"
  sha=$(sed -n 's/^ported //p' <<<"$out" | tail -n1)
  echo "forge: ported ${sha:-$(git -C "$top" rev-parse --short HEAD)}"
}
