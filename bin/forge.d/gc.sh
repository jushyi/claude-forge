gc_merged() {
  [[ " ${open[*]} " != *" $1 "* ]] &&
    git -C "$top" merge-base --is-ancestor "$1" main && ! grep -qxF "$(git -C "$top" rev-parse "$1")" <<<"$fp"
}

gc_clean() {
  local out
  out=$(git -C "$1" status --porcelain --ignored=matching 2>/dev/null) || return 1
  [ -z "$(grep -vE '^!! (.*/)?((\.serena|node_modules)/|\.impeccable/.*)$' <<<"$out" | sed '/^$/d')" ]
}

gc_worktree() {
  local p=$path c
  path=
  [ -n "$p" ] || return 0
  [ -z "$branch" ] || held+=("$branch")
  [ -z "$skip" ] && [ -n "$branch" ] && [ "$p" != "$top" ] || return 0
  case $p in
    "$top/.claude/worktrees/_land") return 0 ;;
    "$top"/.claude/worktrees/* | "$HOME"/.claude/jobs/*/tmp/*) ;;
    *) return 0 ;;
  esac
  case $start/ in "$p"/*) return 0 ;; esac
  while IFS= read -r c; do
    [ -z "$c" ] || case $c/ in "$p"/*) return 0 ;; esac
  done <<<"$sess"
  gc_merged "$branch" && gc_clean "$p" || return 0
  ws+=("$p") wb+=("$branch")
}

gc() {
  local mode=$1 top fp ofp sess line path= branch= skip= b p agents x tsd
  local -a ps=() ws=() wb=() bs=() held=() kept=() open=() rbs=() rts=() stale=() lease=() ss=()
  top=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$top" ] || die "not a git repository: $root"
  fp=$(git -C "$top" rev-list --first-parent main) || die "no main branch in $top"
  tsd=$top/.forge
  for p in "$root" "$top"; do
    [ -d "$p/.forge" ] || continue
    x=$(state_dir "$p") || exit 1
    [ "$p" != "$top" ] || tsd=$x
    for b in "$x"/features/*/; do
      b=${b%/}
      open+=("forge/${b##*/}")
    done
  done
  agents=$(claude agents --json --all </dev/null) &&
    sess=$(jq -r '.[] | select(.state == "working" or .state == "blocked") | .cwd // empty' <<<"$agents") &&
    x=$(stale "${top##*/}" "$tsd" <<<"$agents") || die "cannot list Claude sessions"
  [ -z "$x" ] || mapfile -t ss <<<"$x"
  mapfile -t ps < <(git -C "$top" worktree prune -n -v 2>&1 | sed -n 's#^Removing worktrees/##p')
  while IFS= read -r line; do
    case $line in
      'worktree '*) path=${line#worktree } branch= skip= ;;
      'branch refs/heads/'*) branch=${line#branch refs/heads/} ;;
      locked* | prunable*) skip=1 ;;
      '') gc_worktree ;;
    esac
  done < <(git -C "$top" worktree list --porcelain && echo)
  while IFS= read -r b; do
    if [[ " ${held[*]} " == *" $b "* && " ${wb[*]} " != *" $b "* ]]; then continue; fi
    gc_merged "$b" || continue
    bs+=("$b")
  done < <(git -C "$top" for-each-ref --format='%(refname:short)' refs/heads/forge/)
  if git -C "$top" remote get-url origin >/dev/null 2>&1; then
    if GIT_TERMINAL_PROMPT=0 git -C "$top" fetch -q --no-prune origin 2>/dev/null; then
      mapfile -t stale < <(git -C "$top" remote prune --dry-run origin | sed -n 's/^ \* \[would prune\] //p')
      ofp=$(git -C "$top" rev-list --first-parent origin/main 2>/dev/null) || ofp=
      while IFS=' ' read -r b p; do
        [[ " ${open[*]} " != *" $b "* && " ${stale[*]} " != *" origin/$b "* ]] || continue
        [ -n "$ofp" ] && git -C "$top" merge-base --is-ancestor "$p" origin/main && ! grep -qxF "$p" <<<"$ofp" || continue
        rbs+=("$b") rts+=("$p")
      done < <(git -C "$top" for-each-ref --format='%(refname:lstrip=3) %(objectname)' refs/remotes/origin/forge/)
    else
      echo "forge: warning: cannot fetch origin in $top; skipping remote branches" >&2
    fi
  fi
  if [ ${#ps[@]} -eq 0 ] && [ ${#ws[@]} -eq 0 ] && [ ${#bs[@]} -eq 0 ] && [ ${#rbs[@]} -eq 0 ] && [ ${#stale[@]} -eq 0 ] && [ ${#ss[@]} -eq 0 ]; then
    echo "forge: nothing to collect"
    return 0
  fi
  for p in "${ps[@]}"; do echo "prune $p"; done
  for p in "${!ws[@]}"; do echo "worktree ${ws[p]} ${wb[p]}"; done
  for b in "${bs[@]}"; do echo "branch $b"; done
  for b in "${rbs[@]}"; do echo "remote $b"; done
  for b in "${stale[@]}"; do echo "stale $b"; done
  for b in "${ss[@]}"; do echo "session $b"; done
  if [ -z "$mode" ]; then
    echo "(dry run — rerun with --apply or --confirmed to remove)"
    return 0
  fi
  [ ${#ps[@]} -eq 0 ] || git -C "$top" worktree prune
  for p in "${!ws[@]}"; do
    gc_clean "${ws[p]}" && git -C "$top" worktree remove "${ws[p]}" && continue
    echo "forge: ${ws[p]} changed since the scan; kept" >&2
    kept+=("${wb[p]}")
  done
  for b in "${bs[@]}"; do
    [[ " ${kept[*]} " == *" $b "* ]] || git -C "$top" branch -q -D "$b"
  done
  [ ${#stale[@]} -eq 0 ] || git -C "$top" remote prune origin >/dev/null
  if [ ${#ss[@]} -gt 0 ]; then
    agents=$(claude agents --json --all </dev/null) && x=$(stale "${top##*/}" "$tsd" <<<"$agents") || die "cannot list Claude sessions"
    for b in "${ss[@]}"; do
      grep -qxF "$b" <<<"$x" || { echo "forge: session ${b#* } changed since the scan; kept" >&2; continue; }
      claude rm "${b%% *}" </dev/null || echo "forge: warning: cannot remove session ${b#* }" >&2
    done
  fi
  if [ ${#rbs[@]} -gt 0 ]; then
    p=$(git -C "$top" rev-parse origin/main)
    lease=("--force-with-lease=refs/heads/main:$p" "$p:refs/heads/main")
  fi
  for p in "${!rbs[@]}"; do lease+=("--force-with-lease=refs/heads/${rbs[p]}:${rts[p]}" ":refs/heads/${rbs[p]}"); done
  [ ${#rbs[@]} -eq 0 ] || GIT_TERMINAL_PROMPT=0 git -C "$top" push -q --atomic origin "${lease[@]}" ||
    echo "forge: warning: deleting merged branches on origin failed in $top; nothing was deleted if main or a branch moved since the fetch" >&2
}
