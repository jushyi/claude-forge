doctor_bad() {
  echo "forge doctor: $1"
  dn=$((dn + 1))
}

doctor_skip() {
  local o=$1 c=$2 k=1 ch
  while ((i < n && k > 0)); do
    ch=${s:i:1}
    case $ch in
      \\) i=$((i + 2)) ;;
      \') ch=${s:i+1} ch=${ch%%\'*} i=$((i + ${#ch} + 2)) ;;
      \")
        i=$((i + 1))
        while ((i < n)) && [ "${s:i:1}" != '"' ]; do
          [ "${s:i:1}" != '\' ] || i=$((i + 1))
          i=$((i + 1))
        done
        i=$((i + 1))
        ;;
      "$o") k=$((k + 1)) i=$((i + 1)) ;;
      "$c") k=$((k - 1)) i=$((i + 1)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
}

doctor_put() {
  if [ -n "$has" ]; then
    dw+=("$red$w")
    red=w
  fi
  w='' has=''
}

doctor_words() {
  local s=$1 n=${#1} i=0 w='' has='' red=w ch t j
  dw=()
  while ((i < n)); do
    ch=${s:i:1}
    case $ch in
      ' ' | $'\t') doctor_put; i=$((i + 1)) ;;
      $'\n') doctor_put; dw+=('o;'); i=$((i + 1)) ;;
      '#')
        if [ -n "$has" ]; then
          w+=$ch i=$((i + 1))
        else
          t=${s:i} t=${t%%$'\n'*} i=$((i + ${#t}))
        fi
        ;;
      \\)
        [ "${s:i+1:1}" = $'\n' ] || { w+=${s:i+1:1}; has=1; }
        i=$((i + 2))
        ;;
      \') t=${s:i+1} t=${t%%\'*} w+=$t has=1 i=$((i + ${#t} + 2)) ;;
      \")
        has=1 i=$((i + 1))
        while ((i < n)) && [ "${s:i:1}" != '"' ]; do
          ch=${s:i:1}
          case $ch in
            \\)
              case ${s:i+1:1} in '$' | '`' | '"' | \\) w+=${s:i+1:1} ;; $'\n') ;; *) w+=${s:i:2} ;; esac
              i=$((i + 2))
              ;;
            '$')
              j=$i
              case ${s:i+1:1} in
                '(') i=$((i + 2)); doctor_skip '(' ')' ;;
                '{') i=$((i + 2)); doctor_skip '{' '}' ;;
                *) i=$((i + 1)) ;;
              esac
              w+=${s:j:i-j}
              ;;
            '`') t=${s:i+1} t=${t%%\`*} w+="\`$t\`" i=$((i + ${#t} + 2)) ;;
            *) w+=$ch i=$((i + 1)) ;;
          esac
        done
        i=$((i + 1))
        ;;
      '$')
        j=$i has=1
        case ${s:i+1:1} in
          '(') i=$((i + 2)); doctor_skip '(' ')' ;;
          '{') i=$((i + 2)); doctor_skip '{' '}' ;;
          *) i=$((i + 1)) ;;
        esac
        w+=${s:j:i-j}
        ;;
      '`') t=${s:i+1} t=${t%%\`*} w+="\`$t\`" has=1 i=$((i + ${#t} + 2)) ;;
      '<' | '>')
        if [[ $w =~ ^[0-9]+$ ]]; then w='' has=''; else doctor_put; fi
        t=${s:i:3}
        case $t in
          '<<<' | '<<-' | '>>|') ;;
          *) t=${t:0:2}; case $t in '<<' | '<>' | '<&' | '>>' | '>&' | '>|') ;; *) t=$ch ;; esac ;;
        esac
        i=$((i + ${#t})) red=r
        ;;
      '&' | '|' | ';' | ')')
        doctor_put
        t=${s:i:3}
        case $t in
          ';;&' | '&>>') ;;
          *) t=${t:0:2}; case $t in '&&' | '||' | '|&' | ';;' | ';&' | '&>') ;; *) t=$ch ;; esac ;;
        esac
        i=$((i + ${#t}))
        case $t in '&>' | '&>>') red=r ;; *) dw+=("o$t") ;; esac
        ;;
      '(')
        if [[ $w == *= ]]; then
          j=$i i=$((i + 1))
          doctor_skip '(' ')'
          w+=${s:j:i-j}
        else
          doctor_put
          dw+=('o(') i=$((i + 1))
        fi
        ;;
      *) w+=$ch has=1 i=$((i + 1)) ;;
    esac
  done
  doctor_put
}

doctor_first() {
  local e w='' got='' cmd=1 d=0 pat=''
  local -a dw
  doctor_words "$1"
  for e in "${dw[@]}" 'o;'; do
    if [ -n "$pat" ]; then
      case $e in
        'o)') pat='' ;;
        wesac) pat='' cmd=1 ;;
      esac
      continue
    fi
    case $e in
      w*)
        if [ -n "$cmd" ]; then
          [[ ${e:1} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { w=${e:1} got=1 cmd=''; }
        elif [ "$w" = case ] && [ "$e" = win ]; then
          w='' got='' cmd=1 pat=1
        fi
        ;;
      'o(') [ -z "$cmd" ] || d=$((d + 1)) ;;
      o*)
        [ "$e" != 'o)' ] || [ "$d" -eq 0 ] || d=$((d - 1))
        [ -z "$got" ] || [[ $w == *[\$\`]* ]] || printf '%s\n' "$w"
        w='' got='' cmd=1
        case $e in 'o;;' | 'o;&' | 'o;;&') pat=1 ;; esac
        ;;
    esac
  done
}

doctor_script() {
  dp=$1
  case $dp in
    /*) ;;
    '~/'*) dp=$HOME/${dp#'~/'} ;;
    '$HOME/'*) dp=$HOME/${dp#'$HOME/'} ;;
    '${HOME}/'*) dp=$HOME/${dp#'${HOME}/'} ;;
    '$CLAUDE_PROJECT_DIR/'*) dp=$2/${dp#'$CLAUDE_PROJECT_DIR/'} ;;
    *) return 1 ;;
  esac
  [[ $dp != *[\$\`]* ]]
}

doctor_cred() {
  local n v
  case $1 in
    '~/'* | '$HOME/'*) dp=$1 ;;
    *)
      [[ $1 =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.*)\}$ ]] || return 1
      n=${BASH_REMATCH[1]} dp=${BASH_REMATCH[2]}
      v=$(printenv "$n") && [ -n "$v" ] && dp=$v
      ;;
  esac
  [[ $dp != *[*?[]* ]] || return 1
  case $dp in
    '~/'*) dp=$HOME/${dp#'~/'} ;;
    '$HOME/'*) dp=$HOME/${dp#'$HOME/'} ;;
  esac
  [ -n "$dp" ]
}

doctor_repos() {
  local d rf=$HOME/.local/state/forge/watchdog-roots
  local -a ds=("$HOME"/Projects/*/ "$HOME"/Projects/*/*/)
  local -A seen=()
  if [ -f "$rf" ]; then
    while IFS= read -r d || [ -n "$d" ]; do
      [ -z "$d" ] || ds+=("$d")
    done <"$rf"
  fi
  for d in "${ds[@]}"; do
    [ -d "$d/.forge" ] || continue
    d=$(cd "$d" 2>/dev/null && pwd -P) || continue
    [ -z "${seen[$d]:-}" ] || continue
    seen[$d]=1
    repos+=("$d")
  done
}

doctor_dead() {
  [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null && return 1
  return 0
}

doctor_holders() {
  local r d h l p q fd
  local -a ds=()
  local -A seen=()
  for r in "${repos[@]}"; do
    d=$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && ds+=("$d")
    ds+=("$r/.forge")
  done
  for d in "${ds[@]}"; do
    [ -z "${seen[$d]:-}" ] || continue
    seen[$d]=1
    for h in "$d"/*.lock.holder; do
      p=$(cat -- "$h" 2>/dev/null) || continue
      p=${p%%[[:space:]]*}
      doctor_dead "$p" || continue
      l=${h%.holder}
      if [ ! -e "$l" ] || ! { exec {fd}<"$l"; } 2>/dev/null; then
        echo "forge: warning: $h names dead pid $p but cannot open $l; left in place" >&2
        continue
      fi
      if flock -n "$fd"; then
        if q=$(cat -- "$h" 2>/dev/null); then
          q=${q%%[[:space:]]*}
          if doctor_dead "$q"; then
            if rm -f -- "$h"; then
              echo "forge doctor: removed dead lock holder $h (pid $q)"
            else
              echo "forge: warning: cannot remove dead lock holder $h" >&2
            fi
          fi
        fi
      else
        echo "forge: warning: $h names dead pid $p but ${l##*/} is held; left in place" >&2
      fi
      exec {fd}<&-
    done
  done
}

doctor_pr_ci() {
  grep -Eq "^[[:space:]]*-?[[:space:]]*[\"']?pull_request(_target)?[\"']?[[:space:]]*:?[[:space:]]*(#.*)?\$|^[\"']?on[\"']?[[:space:]]*:([^#]*[[:space:],[])?[\"']?pull_request(_target)?[\"']?([][:space:],#]|\$)" "$1"
}

doctor() {
  local dn=0 dp r f c w cmd said
  local -a repos=() cmds=() dw
  watchdog_path
  doctor_repos
  while IFS= read -r w; do
    [ -z "$w" ] || doctor_bad "$w"
  done < <(forge_preflight || true)
  watchdog_enabled ||
    doctor_bad "forge-watchdog.timer is not enabled; fix: forge watchdog --install"
  for r in "${repos[@]}"; do
    f=$r/.forge/TESTING.md
    [ -f "$f" ] || continue
    cd "$r"
    c=$(awk '/^## /{c = ($0 == "## Commands"); next} c && sub(/^- (All tests|Test|Changed tests|Setup|Quarantine( *\([^)]*\))?|Perf log):[^`]*`/, "") {sub(/`.*/, ""); if ($0 !~ /^<[^>]*>$/) print}' "$f") ||
      { echo "forge: warning: cannot read $f; its commands go unchecked" >&2; continue; }
    said=$'\n'
    while IFS= read -r w; do
      [[ $said != *$'\n'"$w"$'\n'* ]] || continue
      said+=$w$'\n'
      doctor_script "$w" "$r" || dp=$w
      command -v -- "$dp" >/dev/null ||
        doctor_bad "$f runs $w, which is not on the watchdog PATH; fix: install $w or put it on the watchdog PATH"
    done < <(doctor_first "$c")
    for w in "$r"/.github/workflows/*.yml "$r"/.github/workflows/*.yaml "$r"/.forgejo/workflows/*.yml "$r"/.forgejo/workflows/*.yaml; do
      [ -f "$w" ] && [[ ${w##*/} != perf*.yml ]] && doctor_pr_ci "$w" || continue
      grep -q '^- CI full suite:' "$f" ||
        doctor_bad "$f has no - CI full suite: line but $r has CI; fix: add one naming its full-suite job"
      break
    done
  done
  for r in "${repos[@]}"; do
    f=$r/.claude/settings.json
    [ -f "$f" ] || continue
    cd "$r"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { doctor_bad "cannot read $f; fix: repair its JSON"; continue; }
    mapfile -d '' cmds < <(jq -j '.hooks?[]?[]?.hooks?[]?.command? | strings | ., "\u0000"' "$f")
    said=$'\n'
    for cmd in "${cmds[@]}"; do
      while IFS= read -r w; do
        ! doctor_script "$w" "$r" || continue
        [[ $said != *$'\n'"r $w"$'\n'* ]] || continue
        said+="r $w"$'\n'
        command -v -- "$w" >/dev/null ||
          doctor_bad "$f hook runs $w, which is not on the watchdog PATH; fix: install $w or fix the hook"
      done < <(doctor_first "$cmd")
      doctor_words "$cmd"
      for w in "${dw[@]}"; do
        [[ $w == w* ]] && doctor_script "${w:1}" "$r" || continue
        [[ $said != *$'\n'"c $dp"$'\n'* ]] || continue
        said+="c $dp"$'\n'
        [ -e "$dp" ] ||
          doctor_bad "$f hook calls $dp, which does not exist; fix: create $dp or remove the hook"
      done
    done
  done
  local -A cs=()
  for r in "${repos[@]}"; do
    f=$r/.forge/INTEGRATIONS.md
    [ -f "$f" ] || continue
    cd "$r"
    while IFS= read -r w; do
      doctor_cred "${w:1:${#w}-2}" || continue
      [ -z "${cs[$dp]:-}" ] || continue
      cs[$dp]=1
      [ -e "$dp" ] || doctor_bad "$f names $dp, which is missing; fix: create $dp"
    done < <(grep -iE 'key|token|secret|credential|password|netrc' "$f" | grep -o '`[^`]*`')
  done
  doctor_holders
  [ "$dn" -eq 0 ] || return 1
  echo "forge doctor: ok"
}
