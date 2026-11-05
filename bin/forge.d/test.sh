test_line() {
  local doc=$1/.forge/TESTING.md
  [ ! -f "$doc" ] || sed -n "s/^- $2:[^\`]*\`\([^\`]*\)\`.*/\1/p" "$doc" | head -n1 || die "cannot read $doc"
}

quarantine_line() {
  local doc=$1/.forge/TESTING.md
  [ ! -f "$doc" ] || sed -n "s/^- Quarantine\( *(\([^)]*\))\)\?:[^\`]*\`\([^\`]*\)\`.*/\2\t\3/p" "$doc" | head -n1 || die "cannot read $doc"
}

test_lint() {
  local doc=$1/.forge/TESTING.md n c x e t f l p q a s=0
  printf -v t %q tests/sample.test.sh
  printf -v f '%q %q' src/a.sh src/b.sh
  printf -v l %q .forge/failed/sample-changed.log
  for n in "All tests" Test "Changed tests" "Failed tests" Setup Quarantine "Perf log" "PR labels" Pre-push; do
    p="^- $n:"
    if [ "$n" = Quarantine ]; then
      p='^- Quarantine\( *([^)]*)\)\?:'
      x=$(quarantine_line "$1") || exit
      q=${x%%$'\t'*} c=${x#*$'\t'}
    else
      c=$(test_line "$1" "$n") || exit
    fi
    if [ -z "$c" ]; then
      [ "$n" != "All tests" ] || ! tests_none "$1" || continue
      x=$(grep -m1 -n "$p" "$doc" 2>/dev/null) || continue
      echo "forge: $doc: line ${x%%:*}: ${x#*:}: no backticked command" >&2
      s=1
      continue
    fi
    if [ "$n" = Quarantine ]; then
      x=$(grep -m1 -n "$p" "$doc") || die "cannot read $doc"
      if [ -z "$q" ]; then
        echo "forge: $doc: line ${x%%:*}: ${x#*:}: no (added YYYY-MM-DD) date" >&2
        s=1
      elif [[ ! $q =~ ^added\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] || ! a=$(date -u -d "${BASH_REMATCH[1]}" +%F\ %s 2>/dev/null) || [ "${a% *}" != "${BASH_REMATCH[1]}" ]; then
        echo "forge: $doc: line ${x%%:*}: ${x#*:}: ($q) is not an (added YYYY-MM-DD) date" >&2
        s=1
      elif [ $(($(date +%s) - ${a#* })) -gt $((168 * 3600)) ]; then
        echo "forge: $doc: line ${x%%:*}: ${x#*:}: $q, over 7 days ago; lift it or fix the tests" >&2
        s=1
      fi
    fi
    [[ ! $c =~ ^\<[^\>]*\>$ ]] || continue
    if [ "$n" = Test ] && [[ $c != *'{test}'* ]]; then
      echo "forge: $doc: - $n: \`$c\`: no {test} placeholder" >&2
      s=1
    fi
    if [ "$n" = "Changed tests" ] && [[ $c != *'{files}'* ]]; then
      echo "forge: $doc: - $n: \`$c\`: no {files} placeholder" >&2
      s=1
    fi
    if [ "$n" = "Failed tests" ] && [[ $c != *'{log}'* ]]; then
      echo "forge: $doc: - $n: \`$c\`: no {log} placeholder" >&2
      s=1
    fi
    x=${c//\{test\}/"$t"}
    x=${x//\{files\}/"$f"}
    x=${x//\{log\}/"$l"}
    if ! e=$(bash -n -c "$x" 2>&1); then
      echo "forge: $doc: - $n: \`$c\`: ${e//$'\n'/; }" >&2
      s=1
    fi
  done
  for n in Memory "Memory one"; do
    grep -q "^- $n:" "$doc" 2>/dev/null || continue
    c=$(test_line "$1" "$n") || exit
    if ! kib "$c" >/dev/null; then
      echo "forge: $doc: - $n: \`$c\`: not a size such as 4G or 512M" >&2
      s=1
    fi
  done
  for n in "CPUs one" "CPUs all"; do
    grep -q "^- $n:" "$doc" 2>/dev/null || continue
    c=$(test_line "$1" "$n") || exit
    if [[ ! $c =~ ^[1-9][0-9]{0,8}$ ]] || [ "$c" -lt 2 ]; then
      echo "forge: $doc: - $n: \`$c\`: not a whole number of CPUs of at least 2" >&2
      s=1
    fi
  done
  if grep -q "^- Timeout:" "$doc" 2>/dev/null; then
    c=$(test_line "$1" Timeout) || exit
    if [[ ! $c =~ ^[1-9][0-9]*$ ]]; then
      echo "forge: $doc: - Timeout: \`$c\`: not a whole number of minutes such as 45" >&2
      s=1
    fi
  fi
  if x=$(grep -m1 -n "^- CI full suite:" "$doc" 2>/dev/null); then
    c=$(test_line "$1" "CI full suite") || exit
    if [ -z "$c" ]; then
      echo "forge: $doc: line ${x%%:*}: ${x#*:}: no backticked command" >&2
      s=1
    elif [[ ! $c =~ ^\<[^\>]*\>$ ]] && ! ci_job "$1" "$c"; then
      echo "forge: $doc: - CI full suite: \`$c\`: no job of .github/workflows or .forgejo/workflows defines it" >&2
      s=1
    fi
  fi
  return $s
}

ci_job() {
  local d f a s n
  CI_FILES=0
  for d in .github/workflows .forgejo/workflows; do
    a=()
    for f in "$1/$d"/*.yml "$1/$d"/*.yaml; do
      [ ! -f "$f" ] || a+=("$f")
    done
    [ ${#a[@]} -gt 0 ] || continue
    s=0
    n=$(CI_NAME=$2 awk '
    function lit(v) { gsub(/[][\\.^$*+?(){}|]/, "\\\\&", v); return v }
    function hit(v,   r) {
      r = ""
      while (match(v, /\$\{\{[^}]*\}\}/)) { r = r lit(substr(v, 1, RSTART - 1)) ".*"; v = substr(v, RSTART + RLENGTH) }
      return ENVIRON["CI_NAME"] ~ ("^" r lit(v) "$")
    }
    function val(v,   q) {
      if (match(v, /^"[^"\\]*"/) || match(v, /^\047[^\047]*\047/)) {
        q = substr(v, 2, RLENGTH - 2)
        return substr(v, RLENGTH + 1) ~ /^[[:space:]]*(#.*)?$/ ? q : "${{}}"
      }
      sub(/(^|[[:space:]]+)#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      return v ~ /^[][|>*&!%@`{}?"\047]/ ? "${{}}" : v
    }
    function emit() { if (id != "" && hit(nm != "" ? nm : id) && !(jf in fs)) { fs[jf] = 1; f++ } id = ""; nm = ""; ci = ""; pn = 0 }
    FNR == 1 { emit(); j = 0; ji = "" }
    /^[[:space:]]*(#.*)?$/ { next }
    { match($0, /^ */); ind = RLENGTH }
    ind == 0 {
      emit()
      j = ($0 ~ /^("jobs"|\047jobs\047|jobs)[[:space:]]*:[[:space:]]*(#.*)?$/)
      if (!j && $0 ~ /^("jobs"|\047jobs\047|jobs)[[:space:]]*:/) { id = "${{}}"; jf = FILENAME; emit() }
      next
    }
    !j { next }
    ji == "" { ji = ind }
    ind <= ji {
      emit()
      if (match($0, /^ *[^:]+:/)) {
        k = RLENGTH; jf = FILENAME
        id = substr($0, k + 1) ~ /^[[:space:]]*(#.*)?$/ ? val(substr($0, ind + 1, k - ind - 1)) : "${{}}"
      }
      next
    }
    ci == "" { ci = ind }
    pn { if (ind > ci) nm = "${{}}"; else pn = 0 }
    ind == ci && $0 ~ /^ *("name"|\047name\047|name)[[:space:]]*:/ {
      v = $0
      sub(/^ *[^:]*:[[:space:]]*/, "", v)
      nm = val(v); pn = 1
    }
    END { emit(); print f + 0; exit !f }
    ' "${a[@]}") || s=$?
    [ $s -le 1 ] || die "cannot read $1/$d"
    CI_FILES=$((CI_FILES + n))
  done
  [ "$CI_FILES" -gt 0 ]
}

tests_none() {
  local doc=$1/.forge/TESTING.md c s=0
  [ -f "$doc" ] || return 1
  c=$(test_line "$1" "All tests") || exit
  [ -z "$c" ] || return 1
  awk '/^## /{s=($0 ~ /^## Commands[[:space:]]*$/)} s && /^- All tests: none[[:space:]]*$/{f=1} END{exit !f}' "$doc" || s=$?
  [ $s -le 1 ] || die "cannot read $doc"
  return $s
}

test_cmd() {
  local c
  c=$(test_line "$1" "All tests") || exit
  if [ -z "$c" ]; then
    ! tests_none "$1" || die "$1/.forge/TESTING.md declares \"- All tests: none\"; tests not run" 5
    die "no \"- All tests:\" line in $1/.forge/TESTING.md; add a command or \"- All tests: none\"" 6
  fi
  echo "$c"
}

stamps() { echo "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/forge-test"; }

host_id() {
  machine_id=$(tr -d '[:space:]' </etc/machine-id 2>/dev/null) || machine_id=
  [ -n "$machine_id" ] || die "cannot read /etc/machine-id; cannot key $1"
}

host_stamps() {
  host_id "test stamps"
  echo "$(stamps "$1")/$machine_id"
}

tmp_kept() {
  [ -f "$1.unit" ] || return 1
  forge_bg_active "$(cat "$1.unit")" || return 1
}

tmp_free() {
  local u
  tmp_kept "$1" || return 0
  u=$(cat "$1.unit") || die "cannot read $1.unit"
  printf -v u %q "$u"
  die "$2 the TMPDIR of stack unit $u, kept from a dead run under the reused pid $$; stop it with systemctl --user stop $u and rerun"
}

test_tmp() {
  local d f
  d=$(stamps "$1")/tmp
  for f in "$d"/*; do
    [[ ${f##*/} =~ ^[0-9]+$ ]] && ! kill -0 "${f##*/}" 2>/dev/null || continue
    ! tmp_kept "$f" || continue
    rm -rf "$f" "$f.unit" || die "cannot remove $f"
  done
  snap_prune "$1" || exit 1
  run_tmp=$d/$$
  tmp_free "$run_tmp" "$run_tmp is"
  tmp_link=/tmp/fg-$$
  if [ -L "$tmp_link" ] && [ "$(stat -c %u -- "$tmp_link")" = "$EUID" ]; then
    f=$(readlink -- "$tmp_link") || die "cannot read $tmp_link"
    tmp_free "$f" "$tmp_link links to $f,"
    rm -f -- "$tmp_link" || die "cannot remove $tmp_link"
  elif [ -e "$tmp_link" ] || [ -L "$tmp_link" ]; then
    die "$tmp_link is not a symlink owned by $(id -un); remove it and rerun"
  fi
  rm -rf "$run_tmp" "$run_tmp.unit" && mkdir -p "$run_tmp" || die "cannot create $run_tmp"
  trap "rm -rf $(printf %q "$run_tmp")" EXIT
  ln -s -- "$run_tmp" "$tmp_link" || die "cannot link $tmp_link to $run_tmp"
  trap "$(tmp_clean)" EXIT
  export TMPDIR=$tmp_link GIT_CEILING_DIRECTORIES=$d${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}
}

nogit() { (unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR && "$@"); }

tmp_clean() { printf 'rm -rf %q %q' "$run_tmp" "$tmp_link"; }

snap_drop() {
  local a=$1/worktrees/${2##*/} g
  [ ! -f "$a/gitdir" ] || { g=$(cat "$a/gitdir") && [[ $g == */.claude/worktrees/_snap/${2##*/}/.git || $g == */forge-test/snap/${2##*/}/.git ]]; } || a=
  rm -rf "$2" ${a:+"$a"} && rm -f -- "$1/forge-test/snap-owner/${2##*/}" "$1/forge-test/snap-owner/${2##*/}.deps" "$1/forge-test/snap-owner/${2##*/}.lock"
}

snap_dir() {
  local m
  m=$(git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p') && [ -n "$m" ] || return 1
  echo "$m/.claude/worktrees/_snap"
}

snap_prune() {
  local st sd f l s n= k= o=
  st=$(stamps "$1") || { echo "forge: cannot read the git common dir of $1" >&2; return 1; }
  sd=$(snap_dir "$1") || { echo "forge: cannot find the main worktree of $1" >&2; return 1; }
  for f in "$sd"/* "$st"/snap/*; do
    l=$st/snap-owner/${f##*/}.lock s=0
    if [[ ${f##*/} =~ ^[0-9]+$ ]] && { kill -0 "${f##*/}" 2>/dev/null || tmp_kept "$st/tmp/${f##*/}"; }; then
      [[ $f == "$sd"/* ]] || o=1
      continue
    elif [[ $f == "$sd"/k* && -e $l ]]; then
      (flock -n 9 || exit 3; snap_drop "${st%/*}" "$f") 9>>"$l" || s=$?
    else
      snap_drop "${st%/*}" "$f" || s=$?
    fi
    case $s in
      0) n=1 ;;
      3) k=1 ;;
      *) echo "forge: cannot remove $f" >&2; return 1 ;;
    esac
  done
  [ -n "$k" ] || rm -rf -- "$st/snap-owner" || { echo "forge: cannot remove $st/snap-owner" >&2; return 1; }
  [ -n "$o" ] || rm -rf -- "$st/snap" || { echo "forge: cannot remove $st/snap" >&2; return 1; }
  [ -z "$n" ] || nogit git -C "$1" worktree prune || { echo "forge: cannot prune the git worktrees of $1" >&2; return 1; }
}

stack_unit() {
  local u=${1##*/} g
  g=$(git -C "$1" rev-parse --absolute-git-dir) || return 1
  echo "forge-stack-${u//[^A-Za-z0-9:_.-]/_}-$(printf %s "$g" | sha256sum | cut -c1-8)"
}

worktree_tree() {
  local ix real
  ix=$(mktemp -d)
  real=$(git -C "$1" rev-parse --path-format=absolute --git-path index) &&
    if [ -f "$real" ]; then cp -p "$real" "$ix/index"; else GIT_INDEX_FILE=$ix/index git -C "$1" read-tree HEAD; fi &&
    GIT_INDEX_FILE=$ix/index git -C "$1" add -A &&
    GIT_INDEX_FILE=$ix/index git -C "$1" write-tree || { rm -rf "$ix"; die "cannot read the worktree of $1"; }
  rm -rf "$ix"
}

tier() {
  local c x q mb
  local -a fs
  if [ "$1" = one ]; then
    c=$(test_line "$top" Test) || exit
    if [ -n "$c" ]; then
      printf -v q %q "$3"
      cmd=${c//\{test\}/"$q"} level=one
      return
    fi
  fi
  cmd=$(test_cmd "$top") || exit
  level=all
  [ "$1" != all ] || return 0
  c=$(test_line "$top" "Changed tests") || exit
  [ -n "$c" ] || return 0
  mb=$(git -C "$top" merge-base HEAD "$2" 2>/dev/null) || die "no merge base of HEAD and $2 in $top"
  x=$(git -C "$top" -c core.quotePath=false diff --name-only "$mb" "$4") ||
    die "cannot list the changed files of $top"
  level=changed
  [ -n "$x" ] || { level=none; return; }
  mapfile -t fs <<<"$x"
  printf -v q '%q ' "${fs[@]}"
  cmd=${c//\{files\}/"${q% }"}
}

manifests=(package.json package-lock.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock pyproject.toml uv.lock poetry.lock 'requirements*.txt' Cargo.toml Cargo.lock go.mod go.sum)

test_setup() {
  local c h gd m f ls fs=()
  c=$(test_line "$1" Setup) || exit
  [ -n "$c" ] || return 0
  gd=$(git -C "$1" rev-parse --absolute-git-dir) || die "cannot read the git dir of $1"
  host_id "the Setup stamp"
  exec 8>>"$gd/forge-setup.lock" || die "cannot open $gd/forge-setup.lock"
  flock 8 || die "cannot lock $gd/forge-setup.lock"
  mapfile -d '' -t ls < <(git -C "$1" ls-files -z -co --exclude-standard -- "${manifests[@]/#/:(glob)**/}") && wait $! || die "cannot list the manifests of $1"
  for f in "${ls[@]}"; do [ ! -f "$1/$f" ] || fs+=("$f"); done
  h=$({ echo "$c" && { [ ${#fs[@]} = 0 ] || (cd "$1" && printf '%s\0' "${fs[@]}" | LC_ALL=C sort -zu | xargs -0 sha256sum --); }; } | sha256sum) || die "cannot hash the setup of $1"
  h="$machine_id ${h%% *}"
  m=$(cat "$gd/forge-setup" 2>/dev/null) || m=
  if [ "$m" != "$h" ]; then
    run_in "$1" bash -c "$c" >>"$2" 2>&1 </dev/null 4>&- 7>&- 8>&- || setup_failed "$2"
    echo "$h" >"$gd/forge-setup" || die "cannot write $gd/forge-setup"
  fi
  exec 8>&-
}

setup_failed() {
  [ -z "${timed:-}" ] || { timed_out; exit 124; }
  echo "forge: setup failed, log $1" >&2
  exit 1
}

posint() { [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer, got '$2'"; }

ancestor() {
  local h=$$
  while [[ $h =~ ^[0-9]+$ ]] && [ "$h" -gt 1 ]; do
    [ "$h" != "$1" ] || return 0
    h=$(forge_parent "$h")
  done
  return 1
}

runs_held() {
  local f=${FORGE_TEST_SLOT_HELD:-} p
  [[ $f =~ ^"$1"/[1-9][0-9]*$ ]] && [ -f "$f" ] && ! flock -n "$f" true && read -r _ p _ <"$f" || return 1
  ancestor "$p"
}

slot_wait() {
  w=${FORGE_TEST_SLOT_WAIT:-30}
  posint FORGE_TEST_SLOT_WAIT "$w"
}

runs_holders() {
  local f c
  hn=0 h=
  for f in "$1"/*; do
    [[ ${f##*/} =~ ^[1-9][0-9]*$ ]] && ! flock -n "$f" true || continue
    hn=$((hn + 1))
    c=$(<"$f")
    c=${c#pid * in }
    h+=", ${c% since *}"
  done
  h=${h#, }
}

runs_older() {
  local f p s a
  o=
  for f in "$1"/wait/*; do
    [ -f "$f" ] && [ "${f##*/}" != $$ ] || continue
    p= s= a=
    read -r p s a _ <"$f" 2>/dev/null || :
    if ! [[ $p =~ ^[0-9]+$ && $s =~ ^[0-9]+$ && $a =~ ^[0-9]+$ ]] || [ "$(proc_start "$p")" != "$s" ]; then
      rm -f "$f" || die "cannot remove $f"
      continue
    fi
    [ "$a" -lt "$2" ] || { [ "$a" -eq "$2" ] && [ "$p" -lt $$ ]; } || continue
    o=1
  done
}

runs_take() {
  local i
  for ((i = 1; i <= $2; i++)); do
    exec 9>>"$1/$i" || die "cannot open $1/$i"
    if flock -n 9; then
      slot=$1/$i
      return 0
    fi
  done
  exec 9>&-
  return 1
}

test_run_slot() {
  local r=${XDG_RUNTIME_DIR:-$HOME/.local/state}/forge/test-runs n=${FORGE_TEST_RUNS-$lim_test_runs} slot o hn h me e a=${EPOCHREALTIME//[!0-9]/} q=
  [[ $n =~ ^[1-9][0-9]{0,8}$ ]] || die "FORGE_TEST_RUNS must be a whole number of at least 1, got '$n'" 2
  ! runs_held "$r" || return 0
  e=$r/wait/$$
  mkdir -p "$r/wait" || die "cannot create $r/wait"
  exec 7>&-
  while :; do
    exec 6>>"$r/lock" && flock 6 || die "cannot lock $r/lock"
    runs_older "$r" "$a"
    runs_holders "$r"
    if [ -z "$o" ] && [ "$hn" -lt "$n" ] && runs_take "$r" "$n"; then
      exec 7>&9 9>&-
      echo "pid $$ in $1 since $(date '+%F %T')" >"$slot" || die "cannot write $slot"
      if [ -n "$q" ]; then
        rm -f "$e" || die "cannot remove $e"
        trap - EXIT
      fi
      exec 6>&-
      export FORGE_TEST_SLOT_HELD=$slot
      return 0
    fi
    if [ -z "$q" ]; then
      q=1
      me=$(proc_start $$) || die "cannot read the start time of pid $$"
      trap "rm -f $(printf %q "$e")" EXIT
      traps
      echo "$$ $me $a" >"$e" || die "cannot write $e"
      echo "forge: waiting for a test run slot ($hn in use${h:+: $h})" >&2
    fi
    exec 6>&-
    sleep "${FORGE_TEST_POLL_SECS:-1}"
  done
}

wt_held() {
  local p
  [ "${FORGE_TEST_WT_HELD:-}" = "$1" ] && ! flock -n "$1" true && read -r _ p _ <"$1" && ancestor "$p"
}

wt_lock() {
  local f=$2/forge-test.lock w t0= now p=
  ! wt_held "$f" || return 0
  slot_wait
  exec 4>>"$f" || die "cannot open $f"
  until flock -n 4; do
    now=$(date +%s)
    if [ -z "$t0" ]; then
      t0=$now
      read -r _ p _ <"$f" || :
      echo "forge: waiting for the test run in $1 (pid $p)" >&2
    elif [ $((now - t0)) -gt $((w * 60)) ]; then
      die "gave up waiting for the test run in $1 after $(((now - t0) / 60)) min (pid $p)" 75
    fi
    sleep "${FORGE_TEST_POLL_SECS:-1}"
  done
  echo "pid $$ in $1" >"$f" || die "cannot write $f"
  export FORGE_TEST_WT_HELD=$f
}

kib() {
  [[ $1 =~ ^([1-9][0-9]{0,8})([KMG])$ ]] || return 1
  case ${BASH_REMATCH[2]} in
    K) echo $((10#${BASH_REMATCH[1]})) ;;
    M) echo $((10#${BASH_REMATCH[1]} * 1024)) ;;
    G) echo $((10#${BASH_REMATCH[1]} * 1048576)) ;;
  esac
}

test_mem() {
  local m
  m=$(test_line "$1" Memory) || exit
  m=${m:-$(forge_test_cap)}
  kib "$m" >/dev/null || die "$1/.forge/TESTING.md: - Memory: \`$m\`: not a size such as 4G or 512M"
  echo "$m"
}

test_mem_one() {
  local m
  m=$(test_line "$1" "Memory one") || exit
  if [ -z "$m" ]; then
    m=$(test_mem "$1") || exit
    m=$(($(kib "$m") / 2))
    m=$((m > 524288 ? m : 524288))K
  fi
  kib "$m" >/dev/null || die "$1/.forge/TESTING.md: - Memory one: \`$m\`: not a size such as 4G or 512M"
  echo "$m"
}

test_limit() {
  local m
  m=$(test_line "$1" Timeout) || exit
  if grep -q "^- Timeout:" "$1/.forge/TESTING.md" 2>/dev/null; then
    [[ $m =~ ^[1-9][0-9]*$ ]] || die "$1/.forge/TESTING.md: - Timeout: \`$m\`: not a whole number of minutes such as 45"
    echo "$m - Timeout: in $1/.forge/TESTING.md"
  else
    echo "60 the 60 min default"
  fi
}

scope_props() {
  local h
  h=$(($(kib "$mem") * 9 / 10))
  [ "$h" -ge 1 ] || h=1
  sp=(--expand-environment=no -p "MemoryMax=$mem" -p "MemoryHigh=${h}K" -p MemorySwapMax=0)
}

proc_start() {
  local s
  if [ ! -r "/proc/$1/stat" ]; then
    s=$(ps -o lstart= -p "$1" 2>/dev/null) && [ -n "$s" ] && echo "${s// /_}"
    return
  fi
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -ra s <<<"${s##*) }"
  [ "${s[0]}" != Z ] && [ -n "${s[19]:-}" ] && echo "${s[19]}"
}

reap_suite() {
  local j
  for j in $(jobs -p); do kill -TERM -- "-$j" 2>/dev/null || :; done
  [ -z "${cap:-}" ] || systemctl --user stop "forge-test-$$-*.scope" >/dev/null 2>>"$log" || :
  exit "$1"
}

traps() {
  trap 'reap_suite 129' HUP
  trap 'reap_suite 130' INT
  trap 'reap_suite 143' TERM
}

test_clock() {
  local x
  x=$(test_limit "$top") || exit
  [ -z "${FORGE_TEST_MIN_SECS:-}" ] || posint FORGE_TEST_MIN_SECS "$FORGE_TEST_MIN_SECS"
  limit=${x%% *} limsrc=${x#* } lim=$((${x%% *} * ${FORGE_TEST_MIN_SECS:-60}))
}

timed_out() { echo "forge: tests timed out after $limit min (limit from $limsrc), log $log" >&2; }

run_in() {
  local j s=0 t d=${limit}m
  [ -z "${FORGE_TEST_MIN_SECS:-}" ] || d=${lim}s
  traps
  t=${EPOCHREALTIME//[!0-9]/}
  set -m
  (cd "$1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR && exec timeout -k 10s "$d" "${@:2}") &
  j=$!
  set +m
  wait "$j" || s=$?
  [ $s -ne 0 ] && [ $((${EPOCHREALTIME//[!0-9]/} - t)) -ge $((lim * 1000000)) ] || return $s
  timed=1
  kill -KILL -- "-$j" 2>/dev/null || :
  return 124
}

cpu_pressure() {
  local f=${FORGE_PROC_ROOT:-/proc}/pressure/cpu k a
  [ -r "$f" ] || return 1
  while read -r k a _; do
    [ "$k" = some ] || continue
    [[ ${a#avg10=} =~ ^([0-9]+)\.([0-9]{2})$ ]] || return 1
    pv=${a#avg10=} ph=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
    return 0
  done <"$f"
  return 1
}

test_cpus() {
  local n x c pv ph
  cpu_pressure && cpu=$pv || cpu=-
  n=$(nproc) || die "cannot count the CPUs"
  x="CPUs one" c=2
  [ "$2" != all ] || x="CPUs all" c=$((n / 4 > 2 ? n / 4 : 2))
  if grep -q "^- $x:" "$1/.forge/TESTING.md" 2>/dev/null; then
    c=$(test_line "$1" "$x") || exit
    [[ $c =~ ^[1-9][0-9]{0,8}$ ]] && [ "$c" -ge 2 ] || die "$1/.forge/TESTING.md: - $x: \`$c\`: not a whole number of CPUs of at least 2"
  fi
  [ "$c" -le "$n" ] || c=$n
  export FORGE_TEST_CPUS=$c CARGO_BUILD_JOBS=$c
}

term() {
  run_in "$top" "$@" bash -c "ulimit -c 0
$cmd" </dev/null 4>&- 7>&-
}

suite() { term "$@" >>"$log" 2>&1; }

probe() {
  scope_props
  command -v systemd-run >/dev/null || return 0
  if systemd-run --user --scope --quiet "${sp[@]}" -- true >>"$log" 2>&1 </dev/null; then
    cap=1
  else
    echo "forge: memory cap unavailable, running uncapped" >&2
  fi
}

retried() {
  local n u r p j=$FORGE_TEST_CPUS
  for n in 1 2; do
    u=forge-test-$$-${it:+$it-}$n s=0
    rm -f "$pf" || die "cannot remove $pf"
    FORGE_TEST_CPUS=$j CARGO_BUILD_JOBS=$j "$@" systemd-run --user --scope --quiet "--unit=$u" "${sp[@]}" -- bash -c 'f=$1
shift
"$@"
s=$?
c=
while read -r l; do [[ $l != 0::* ]] || c=${l#0::}; done 2>/dev/null <"${FORGE_PROC_ROOT:-/proc}/self/cgroup"
[ -z "$c" ] || ! read -r p 2>/dev/null <"${FORGE_SYS_ROOT:-/sys}/fs/cgroup$c/memory.peak" || echo "$p" >"$f"
exit $s' forge-test "$pf" || s=$?
    r=$(systemctl --user show -p Result --value "$u.scope" 2>>"$log") || r=
    p=
    if [ $n -eq 1 ] && { [ $s -eq 137 ] || [ "$r" = oom-kill ]; }; then
      read -r p 2>/dev/null <"$pf" || :
      [[ $p =~ ^[0-9]+$ ]] || p=$(systemctl --user show -p MemoryPeak --value "$u.scope" 2>>"$log") || p=
    fi
    systemctl --user stop "$u.scope" >/dev/null 2>>"$log" || :
    systemctl --user reset-failed "$u.scope" >/dev/null 2>&1 || :
    [ -z "$timed" ] || return 1
    [ $s -eq 137 ] || [ "$r" = oom-kill ] || return 0
    [ $n -eq 1 ] || break
    if [[ $p =~ ^[0-9]+$ ]]; then
      p=$(((p / 1024 * 10 + 524288) / 1048576))
      p=$((p / 10)).$((p % 10))G
    else
      p=unknown
    fi
    j=$((j / 2))
    [ $j -ge 1 ] || j=1
    echo "forge: tests killed for memory: peak $p of $mem budget; retrying with $j jobs" >&2
  done
  [ $s -ne 0 ] || s=137
  return 1
}

capped() {
  local s
  retried suite && return $s
  [ -z "$timed" ] || return 124
  runlog $s
  echo "forge: tests killed for memory (budget $mem), log $log" >&2
  exit 75
}

peak() {
  local p=
  [ -z "$cap" ] || read -r p 2>/dev/null <"$pf" || :
  rm -f "$pf" || die "cannot remove $pf"
  [[ ! $p =~ ^[0-9]+$ ]] || echo $((p / 1024))
}

memhint() {
  local b d
  b=$(kib "$mem")
  [ -n "$1" ] && [ $(($1 * 5)) -gt $((b * 4)) ] || return 0
  d=$((($1 * 10 + 524288) / 1048576))
  echo "forge: memory peak $((d / 10)).$((d % 10))G of $mem budget; set - ${ml:-Memory}: $((($1 * 5 + 4194303) / 4194304))G in $top/.forge/TESTING.md" >&2
}

runlog() {
  local k d=${runlog_s:--} c=${cpu:-} pv ph
  k=$(peak)
  k=${k:-${pk:-}}
  [ -n "$c" ] || { cpu_pressure && c=$pv || c=-; }
  [ -n "${runlog_s:-}" ] || [ -z "${t1:-}" ] || d=$(($(date +%s) - t1))
  mkdir -p "${rl%/*}" && echo "$(date '+%F %T') ${level:--} ${before:--} ${waited:--} $d $1 ${la:--} ${ma:--} ${mem:--} peak=${k:--} cpu=$c" >>"$rl" || die "cannot write $rl"
  memhint "$k"
}

quarantine_age() {
  local x q a
  x=$(quarantine_line "$1") || exit
  [[ ${x%%$'\t'*} =~ ^added\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] && q=${BASH_REMATCH[1]} && a=$(date -u -d "$q" +%s 2>/dev/null) || return 0
  a=$(($(date +%s) - a))
  [ $a -le $((48 * 3600)) ] || echo "forge: warning: quarantine added $q ($((a / 3600)) h ago); lift it or fix the tests" >&2
}

event_dir() {
  local b s
  local -a x=()
  [ -n "${FORGE_ROOT:-}" ] || return 0
  s=$(state_dir "$FORGE_ROOT") || return 0
  [ -z "${FORGE_PHASE:-}" ] || x=("$s"/phases/"$FORGE_PHASE"-*/)
  if [ ${#x[@]} -gt 0 ]; then
    echo "${x[0]%/}"
  elif b=$(git -C "$top" symbolic-ref -q --short HEAD) && [[ $b == forge/* ]] && [ -d "$s/features/${b#forge/}" ]; then
    echo "$s/features/${b#forge/}"
  fi
}

quarantine() {
  local s=0 d r
  cmd=$(quarantine_line "$top") || exit
  cmd=${cmd#*$'\t'}
  [ -n "$cmd" ] || return 0
  if [ -n "$cap" ]; then
    suite systemd-run --user --scope --quiet "--unit=forge-test-$$-q" "${sp[@]}" -- || s=$?
    r=$(systemctl --user show -p Result --value "forge-test-$$-q.scope" 2>>"$log") || r=
    systemctl --user stop "forge-test-$$-q.scope" >/dev/null 2>>"$log" || :
    systemctl --user reset-failed "forge-test-$$-q.scope" >/dev/null 2>&1 || :
    [ "$r" != oom-kill ] || [ $s -ne 0 ] || s=137
  else
    suite || s=$?
  fi
  [ $s -ne 0 ] || return 0
  echo "forge: quarantine failed (exit $s); not gating" >&2
  d=$(event_dir)
  [ -z "$d" ] || event "$d" quarantine "exit $s, log $log" || echo "forge: cannot write $d/events.jsonl" >&2
}

stamped() {
  local -A seen=()
  stamp_walk "$1" "$2" 0
}

stamp_walk() {
  local f=$1/changed/$2 l c=
  local -a a
  [ "$3" -le 20 ] && [[ $2 =~ ^[0-9a-f]+$ ]] && [ -z "${seen[$2]+x}" ] || return 1
  seen[$2]=1
  [ ! -f "$1/$2" ] || return 0
  [ -f "$f" ] && mapfile -t a <"$f" || return 1
  for l in "${a[@]}"; do
    [[ $l == "chain "* ]] || return 0
    c=1
    ! stamp_walk "$1" "${l#chain }" $(($3 + 1)) || return 0
  done
  [ -z "$c" ]
}

based() {
  if [ "$2" = any ]; then
    stamped "${1%/changed/*}" "${1##*/}"
  else
    [ -f "$1" ] && [ -n "$2" ] && { grep -qxF "$2" "$1" || grep -qxF "$(stamp_line "$3" "${1%/changed/*}" "$2" "${1##*/}")" "$1"; }
  fi
}

stamp_line() {
  local pt
  if pt=$(git -C "$1" rev-parse -q --verify "$3^{tree}") && [ "$pt" != "$4" ] && stamped "${2%/changed}" "$pt"; then
    echo "chain $pt"
  else
    echo "$3"
  fi
}

carried() {
  local t p d ok
  for t in $(git -C "$1" log -n 20 --format=%T HEAD 2>/dev/null); do
    [ -f "$2/$t" ] || { [ -n "$4" ] && based "$2/changed/$t" any; } || { [ "$5" = all ] && full_chain "$1" "$2" "$t" HEAD; } || continue
    d=$(git -C "$1" -c core.quotePath=false diff --name-only --no-renames "$t" "$3") && [ -n "$d" ] || continue
    ok=1
    while IFS= read -r p; do
      case $p in .forge/TESTING.md) ok= && break ;; .forge/* | *.md | docs/*) ;; *) ok= && break ;; esac
    done <<<"$d"
    [ -z "$ok" ] || { echo "$t"; return; }
  done
}

base_check() {
  local ft q out line i r h k bw=$sd/base bl=$sd/base.log rs=$sd/base.status bt= n=1 ok=1
  local -a ids=() fs=() run=()
  local -A seen=()
  ft=$(test_line "$top" "Failed tests") && q=$(test_line "$top" Test) || exit
  [ -n "$ft" ] && [ -n "$q" ] || return 1
  printf -v q %q "$fl.log"
  out=$(cd "$top" && FORGE_TEST_LOG_DIR=$fl.d/ nogit bash -c "${ft//\{log\}/"$q"}" </dev/null 4>&- 7>&-) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ $line == ?*' '?* ]] || return 1
    k=${line% *}
    [ -z "${seen[$k]+x}" ] || continue
    seen[$k]=1
    ids+=("$k") fs+=("${line##* }")
  done <<<"$out"
  [ ${#ids[@]} -ge 1 ] && [ ${#ids[@]} -le 10 ] || return 1
  for i in "${!ids[@]}"; do
    if h=$(git -C "$top" rev-parse -q --verify "$mb:${fs[i]}") && [ "$h" = "$(git -C "$top" rev-parse -q --verify "$before:${fs[i]}")" ]; then run+=("$i"); else ok=; fi
  done
  [ ${#run[@]} -gt 0 ] || return 1
  exec 5>>"$sd/base.lock" && flock 5 || { echo "forge: cannot lock $sd/base.lock; base check skipped" >&2; return 1; }
  if ! {
    : >"$bl" &&
      { [ -f "$bw/.git" ] && git -C "$bw" checkout -q --detach --force "$mb" && git -C "$bw" clean -q -fd ||
        { { [ ! -e "$bw" ] || git -C "$top" worktree remove --force --force "$bw" || rm -rf "$bw"; } &&
          git -C "$top" worktree prune && git -C "$top" worktree add -q --detach "$bw" "$mb"; }; } >>"$bl" 2>&1
  }; then
    exec 5>&-
    echo "forge: cannot prepare the base worktree $bw, log $bl; base check skipped" >&2
    return 1
  fi
  if [ -z "$(test_line "$bw" Test)" ]; then
    ok= run=()
  fi
  for i in "${run[@]}"; do
    r=0
    rm -f "$rs" || { ok=; break; }
    env -u FORGE_TEST_LOG_DIR "FORGE_TEST_ONE_STATUS=$rs" "$D/../forge" test --one "${ids[i]}" "$bw" >>"$bl" 2>&1 </dev/null 4>&- 5>&- 7>&- || r=$?
    case $r in
      0 | 75 | 124 | 126 | 127) ok= ;;
      *) if [ $r -le 128 ] && [ "$(cat "$rs" 2>/dev/null)" = "$r" ]; then pre+=("${ids[i]}") prf+=("${fs[i]}"); else ok=; fi ;;
    esac
  done
  rm -f "$rs"
  if bt=$(git -C "$top" rev-parse "$mb^{tree}") && mkdir -p "$sd/base-fails" &&
    while [ -e "$sd/base-fails/$bt-$n.log" ]; do n=$((n + 1)); done && cp "$bl" "$sd/base-fails/$bt-$n.log"; then
    bf=$sd/base-fails/$bt-$n.log
  else
    ok=
    echo "forge: cannot write $sd/base-fails/$bt-$n.log" >&2
  fi
  exec 5>&-
  [ -n "$ok" ]
}

base_concerns() {
  local m r c i n e l
  m=$(git -C "$top" worktree list --porcelain | sed -n '1s/^worktree //p') && [ -n "$m" ] || {
    echo "forge: warning: cannot find the main checkout of $top; no concern for pre-existing failures ${pre[*]}" >&2
    return 0
  }
  r=$m
  [ ! -d "${m%/*}/.forge" ] || r=${m%/*}
  c=$m/.forge/concerns.json
  (
    if ! l=$(git -C "$m" rev-parse --path-format=absolute --git-common-dir 2>&1) || ! exec 9>"$l/forge.lock" || ! wait_lock 9 "$l/forge.lock"; then
      echo "forge: warning: cannot lock $l/forge.lock; no concern for pre-existing failures ${pre[*]}" >&2
      exit 0
    fi
    for i in "${!pre[@]}"; do
      n=0
      if [ -f "$c" ] && ! n=$(jq --arg p "Pre-existing test failure: ${pre[i]} " '[.concerns[] | select(.status == "open" and (.text // "" | startswith($p)))] | length' "$c" 2>&1); then
        echo "forge: warning: cannot look up the concern for pre-existing failure ${pre[i]} in $c: ${n//$'\n'/ }" >&2
        continue
      fi
      [ "$n" = 0 ] || continue
      e=$(locked=1 FORGE_ROOT=$r "$D/../forge" concern add "${m##*/}" test medium "${prf[i]}" -- "Pre-existing test failure: ${pre[i]} fails on base tree $1 ($2); log $bf" 2>&1 >/dev/null </dev/null) ||
        echo "forge: warning: cannot add the concern for pre-existing failure ${pre[i]}: ${e//$'\n'/ }" >&2
    done
  )
}

stamp_changed() {
  local c
  c=$(stamp_line "$top" "$st" "$mb" "$before")
  [[ $ln != "chain "* ]] || [ "$c" = "$ln" ] || die "merge-base tree $(git -C "$top" rev-parse --short "${ln#chain }") lost its test pass while tests ran; no pass recorded, rerun forge test (log $log)"
  mkdir -p "$st" && echo "$c" >>"$st/$before" || die "cannot write $st/$before"
}

full_chain() {
  local top=$1 hs=$2 m=$4 t x l d i=0
  local -A seen=([$3]=1)
  local -a q=("0 $3") a
  while [ $i -lt ${#q[@]} ]; do
    d=${q[$i]%% *} t=${q[$i]#* }
    i=$((i + 1))
    [ "$d" -lt 20 ] && [ -f "$hs/changed/$t" ] && mapfile -t a <"$hs/changed/$t" || continue
    for l in ${a[@]+"${a[@]}"}; do
      [[ $l =~ ^chain\ ([0-9a-f]+)$ ]] || continue
      x=${BASH_REMATCH[1]}
      [ -z "${seen[$x]+x}" ] || continue
      seen[$x]=1
      if [ -f "$hs/$x" ]; then
        { git -C "$top" log --format=%T "$m" || [ $? -eq 141 ]; } | grep -qxF "$x" && return 0
      else
        q+=("$((d + 1)) $x")
      fi
    done
  done
  return 1
}

tree_passed() { [ -f "$1/$2" ] || based "$1/changed/$2" "$3" "$4" || { [ "$5" = all ] && full_chain "$4" "$1" "$2" HEAD; }; }

load1() {
  forge_load1
}

test_failure() {
  [ -z "$timed" ] && [ $s -ne 0 ] && [ $s -ne 75 ] && [ $s -ne 126 ] && [ $s -ne 127 ] && [ $s -le 128 ] && ! grep -rqsF -e 'No space left on device' -e 'Disk quota exceeded' "$log" "$FORGE_TEST_LOG_DIR"
}

log_dir() { rm -rf "$FORGE_TEST_LOG_DIR" && mkdir -p "$FORGE_TEST_LOG_DIR" || die "cannot empty $FORGE_TEST_LOG_DIR"; }

attempt() {
  if [ -n "$cap" ]; then capped || s=$?; else suite || s=$?; fi
  if [ -n "$timed" ]; then
    s=124
    runlog timeout
  else
    runlog $s
  fi
}

run_tests() {
  local top cmd level log pf sd st rl before short mb= c= ln= s=0 mem cap= la ma t1 waited cpu fd fl m limit limsrc lim timed= bq= bf= d l0 l1 n
  local -a sp pre=() prf=()
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "$1 is not in a git worktree"
  test_cmd "$top" >/dev/null || exit
  quarantine_age "$top"
  mem=$(test_mem "$top") || exit
  log=$(git -C "$top" rev-parse --absolute-git-dir)/forge-test.log
  pf=${log%.log}-$$.peak
  host_id "test stamps"
  st=$(host_stamps "$top") || exit
  sd=$(stamps "$top")
  rl=$sd/runs.log
  before=$(worktree_tree "$top") || exit 1
  short=$(git -C "$top" rev-parse --short "$before")
  [ "$2" != changed ] || mb=$(git -C "$top" merge-base HEAD "$3" 2>/dev/null) || mb=
  if [ -z "$4" ] && tree_passed "$st" "$before" "$mb" "$top" "$2"; then
    echo "forge: tests passed ($short), cached"
    return
  fi
  tier "$2" "$3" "" "$before"
  [ "$level" = none ] || test_clock
  fd=$sd/failed fl=$sd/failed/$before-$level
  [ ! -d "$fd" ] || find "$fd" -mindepth 1 -maxdepth 1 -mmin +30 -exec rm -rf {} + || die "cannot prune $fd"
  if [ -z "$4" ] && [[ $top != */.claude/worktrees/_land ]]; then
    c=$(carried "$top" "$st" "$before" "$mb" "$2")
    if [ -n "$c" ]; then
      echo "forge: tests passed ($short), cached from $(git -C "$top" rev-parse --short "$c") (docs-only change)"
      return
    fi
  fi
  [ "$level" = all ] || st+=/changed
  if [ "$level" = none ]; then
    mkdir -p "$st"
    stamp_line "$top" "$st" "$mb" "$before" >>"$st/$before"
    echo "forge: tests passed ($short), no changed files"
    return
  fi
  test_cpus "$top" all
  t1=${EPOCHREALTIME//[!0-9]/}
  test_run_slot "$top"
  waited=$(((${EPOCHREALTIME//[!0-9]/} - t1) / 1000000))
  wt_lock "$top" "${log%/*}"
  if [ -z "$4" ] && tree_passed "${st%/changed}" "$before" "$mb" "$top" "$2"; then
    echo "forge: tests passed ($short), cached"
    return
  fi
  [ "$level" != changed ] || ln=$(stamp_line "$top" "$st" "$mb" "$before")
  test_tmp "$top"
  : >"$log"
  export FORGE_TEST_LOG_DIR=${log%.log}.d/
  log_dir
  probe
  la=$(FORGE_PROC_ROOT= forge_load1) && ma=$(FORGE_PROC_ROOT= forge_mem_available) && [ -n "$ma" ] || die "cannot read the load and memory"
  test_setup "$top" "$log"
  t1=$(date +%s)
  l0=$(load1) || l0=
  attempt
  l1=$(load1) || l1=
  if test_failure; then
    [ -z "$l1" ] || { [ -n "$l0" ] && [ $((10#${l0/./})) -ge $((10#${l1/./})) ]; } || l0=$l1
    n=$(nproc) || die "cannot count the CPUs"
    if [ -n "$l0" ] && [ $((10#${l0/./})) -ge $((n * 100)) ]; then
      echo "forge: rerun: load $l0 >= nproc $n" >&2
      log_dir
      t1=$(date +%s) s=0
      attempt
    fi
  fi
  if [ $s -ne 0 ]; then
    if [ $s -ne 75 ]; then
      rm -f "${st%/changed}/$before" "${st%/changed}/changed/$before" || die "cannot remove the stamps of tree $short"
      if test_failure; then
        mkdir -p "$fd" && cp "$log" "$fl.log" && rm -rf "$fl.d" && { [ ! -d "$FORGE_TEST_LOG_DIR" ] || cp -r "$FORGE_TEST_LOG_DIR" "$fl.d"; } || die "cannot write $fl.log"
        [ "$level" != changed ] || [ $s -eq 5 ] || bq=1
      fi
    fi
    if [ -n "$bq" ] && base_check; then
      stamp_changed
      exec 4>&- 7>&-
      unset FORGE_TEST_SLOT_HELD
      rm -rf "$fl.log" "$fl.d" || die "cannot remove $fl.log"
      m=$(git -C "$top" rev-parse --short "$mb")
      echo "forge: tests passed ($short), pre-existing failures on $m: ${pre[*]}"
      d=$(event_dir)
      [ -z "$d" ] || event "$d" base-fails "pre-existing failures ${pre[*]} on $m (base $3), log $bf" || echo "forge: cannot write $d/events.jsonl" >&2
      base_concerns "$m" "$3"
      return
    fi
    exec 4>&- 7>&-
    [ -z "$timed" ] || { timed_out; exit 124; }
    [ ${#pre[@]} -eq 0 ] || echo "forge: pre-existing failures on $(git -C "$top" rev-parse --short "$mb"): ${pre[*]}" >&2
    echo "forge: tests failed, log $log" >&2
    [ $s -ne 5 ] && [ $s -ne 75 ] || exit 1
    exit $s
  fi
  mkdir -p "$st"
  if [ "$level" = all ]; then
    : >"$st/$before"
  else
    stamp_changed
    [ ! -e "${FORGE_TEST_LOG_DIR}.full" ] || : >"${st%/changed}/$before"
  fi
  exec 7>&-
  unset FORGE_TEST_SLOT_HELD
  [ "$level" != all ] || quarantine
  rm -rf "$fl.log" "$fl.d" || die "cannot remove $fl.log"
  exec 4>&- 7>&-
  echo "forge: tests passed ($short)"
}

run_one() {
  local top tree cmd level mem log pf cap= s=0 it n=${4:-1} k pk= limit limsrc lim timed= ml=Memory rs=${FORGE_TEST_ONE_STATUS:-} rl before waited la ma t1 cpu
  local -a sp
  unset FORGE_TEST_ONE_STATUS
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "$1 is not in a git worktree"
  quarantine_age "$top"
  tree=$(worktree_tree "$top") || exit 1
  tier one "$2" "$3" "$tree"
  if [ "$level" = none ]; then
    echo "forge: no changed files; nothing to test"
    return
  fi
  if [ "$level" = one ] && [ -z "$4" ]; then
    mem=$(test_mem_one "$top") || exit
    ml="Memory one"
  else
    mem=$(test_mem "$top") || exit
  fi
  level=one
  [ -z "$4" ] || level=repeat
  test_clock
  log=$(git -C "$top" rev-parse --absolute-git-dir)/forge-test.log
  pf=${log%.log}-$$.peak
  rl=$(stamps "$top")/runs.log before=$tree
  test_cpus "$top" one
  t1=${EPOCHREALTIME//[!0-9]/}
  test_run_slot "$top"
  waited=$(((${EPOCHREALTIME//[!0-9]/} - t1) / 1000000))
  wt_lock "$top" "${log%/*}"
  test_tmp "$top"
  probe
  la=$(FORGE_PROC_ROOT= forge_load1) && ma=$(FORGE_PROC_ROOT= forge_mem_available) && [ -n "$ma" ] || die "cannot read the load and memory"
  test_setup "$top" "$log"
  t1=$(date +%s)
  for ((it = 1; it <= n; it++)); do
    s=0
    if [ -z "$cap" ]; then
      term || s=$?
    elif ! retried term && [ -z "$timed" ]; then
      k=$(peak)
      [ -z "$k" ] || [ "$k" -le "${pk:-0}" ] || pk=$k
      runlog 75
      echo "forge: tests killed for memory (budget $mem)" >&2
      [ -z "$4" ] || echo "forge: repeat failed on iteration $it/$n" >&2
      exit 75
    fi
    k=$(peak)
    [ -z "$k" ] || [ "$k" -le "${pk:-0}" ] || pk=$k
    [ $s -eq 0 ] || break
  done
  [ $s -ne 5 ] && [ $s -ne 75 ] || s=1
  if [ -n "$timed" ]; then
    s=124
    runlog timeout
    timed_out
  else
    runlog $s
  fi
  if [ -n "$4" ]; then
    if [ $s -ne 0 ]; then echo "forge: repeat failed on iteration $it/$n" >&2; else echo "forge: repeat passed $n/$n"; fi
  fi
  [ -z "$rs" ] || echo $s >"$rs" || die "cannot write $rs"
  exit $s
}

run_stack() {
  local top tree stack tests gd log unit off stop s=0 limit limsrc lim timed=
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "$1 is not in a git worktree"
  tree=$(worktree_tree "$top") || exit 1
  stack=$(test_line "$top" "Local stack") && tests=$(test_line "$top" "Stack tests") || exit
  [ -n "$stack" ] && [ -n "$tests" ] || die "no \"- Local stack:\" or \"- Stack tests:\" line in $top/.forge/TESTING.md; stack not run" 5
  test_clock
  gd=$(git -C "$top" rev-parse --absolute-git-dir) || exit 1
  log=$gd/forge-stack.log
  unit=$(stack_unit "$top") || exit 1
  off=${FORGE_PORT_OFFSET:-0}
  wt_lock "$top" "$gd"
  : >"$log"
  test_tmp "$top"
  printf -v stop 'forge_bg_stop %q >>%q 2>&1 </dev/null' "$unit" "$log"
  eval "$stop" || [ $? -eq 5 ] || die "cannot stop the previous stack unit $unit, log $log"
  test_setup "$top" "$log"
  trap "if $stop || [ \$? -eq 5 ]; then rm -rf $(printf %q "$run_tmp") $(printf %q "$run_tmp.unit") $(printf %q "$tmp_link"); fi" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  echo "$unit" >"$run_tmp.unit" || die "cannot write $run_tmp.unit"
  echo "forge: stack journal: journalctl --user -u $unit" >>"$log"
  forge_bg "$unit" "$top" "FORGE_PORT_OFFSET=$off" "PATH=$PATH" "TMPDIR=$tmp_link" "GIT_CEILING_DIRECTORIES=$GIT_CEILING_DIRECTORIES" -- bash -c "$stack" >>"$log" 2>&1 </dev/null ||
    die "local stack failed to start, log $log"
  (cd "$top" && nogit env "FORGE_PORT_OFFSET=$off" bash -c "$tests") >>"$log" 2>&1 </dev/null 4>&- || s=$?
  if [ $s -ne 0 ]; then
    echo "forge: stack tests failed, log $log" >&2
    [ $s -ne 5 ] && [ $s -ne 2 ] && [ $s -ne 75 ] || exit 1
    exit $s
  fi
  eval "$stop" || [ $? -eq 5 ] || die "stack tests passed but unit $unit did not stop, log $log"
  trap - EXIT
  rm -rf "$run_tmp" "$run_tmp.unit" "$tmp_link" || die "cannot remove $run_tmp"
  echo "forge: stack tests passed"
}

tests_state() {
  local top tree x s st short c m=
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { echo "$1 is not in a git worktree"; return 1; }
  x=$(test_cmd "$top" 2>&1) || { s=$?; echo "${x#forge: }"; return $s; }
  tree=$(worktree_tree "$top") || return 1
  [ "$tree" = "$(git -C "$top" rev-parse HEAD^{tree})" ] || { echo "$top has uncommitted changes or untracked files"; return 1; }
  st=$(host_stamps "$top" 2>&1) || { echo "${st#forge: }"; return 1; }
  short=$(git -C "$top" rev-parse --short "$tree")
  [ "$2" != changed ] || m=any
  if ! tree_passed "$st" "$tree" "$m" "$top" "$2"; then
    c=$(carried "$top" "$st" "$tree" "$m" "$2")
    if [ -n "$c" ]; then
      echo "tests passed ($short), cached from $(git -C "$top" rev-parse --short "$c") (docs-only change)"
      return
    fi
    x=
    [ "$2" != changed ] || x=" --changed"
    echo "no test pass for tree $short in $top; run forge test$x $top"
    return 1
  fi
  echo "tests passed ($short)"
}

tests_passed() {
  local out
  out=$(tests_state "$1" "$2") || die "$out" $?
  echo "forge: $out"
}

forge_test() {
  local mode=all base=main one= id= passed= force= stack= other= repeat=
  while [ $# -gt 0 ]; do
    case $1 in
      --changed) mode=changed other=1 ;;
      --base) [ $# -ge 2 ] || usage; base=$2 other=1; shift ;;
      --one) [ $# -ge 2 ] || usage; one=1 id=$2 other=1; shift ;;
      --repeat) [ $# -ge 2 ] && [[ $2 =~ ^[1-9][0-9]{0,17}$ ]] || usage; repeat=$2 other=1; shift ;;
      --passed) passed=1 other=1 ;;
      --force) force=1 other=1 ;;
      --stack) stack=1 ;;
      -*) usage ;;
      *) break ;;
    esac
    shift
  done
  [ $# -le 1 ] || usage
  [ -z "$passed" ] || [ -z "$one$force" ] || usage
  [ -z "$stack" ] || [ -z "$other" ] || usage
  [ -z "$repeat" ] || [ -n "$one" ] || usage
  if [ -n "$stack" ]; then
    run_stack "${1:-$start}"
  elif [ -n "$passed" ]; then
    tests_passed "${1:-$start}" "$mode"
  elif [ -n "$one" ]; then
    run_one "${1:-$start}" "$base" "$id" "$repeat"
  else
    run_tests "${1:-$start}" "$mode" "$base" "$force"
  fi
}
