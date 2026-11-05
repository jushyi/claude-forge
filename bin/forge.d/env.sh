forge_host_env() {
  local f=${FORGE_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/forge/env} l
  [ -f "$f" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case $l in '' | '#'*) continue ;; esac
    if [[ $l =~ ^(FORGE_[A-Z0-9_]+)=([A-Za-z0-9._:/@%+,=-]*)$ ]] && [ "${BASH_REMATCH[1]}" != FORGE_ENV ]; then
      export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    else
      echo "forge: warning: $f: ignoring line '$l'" >&2
    fi
  done <"$f"
}

forge_uname() { echo "${FORGE_UNAME:-$(uname -s)}"; }

forge_is_darwin() { [ -z "${FORGE_PROC_ROOT:-}" ] && [ "$(forge_uname)" = Darwin ]; }

forge_meminfo() {
  local f=${FORGE_PROC_ROOT:-/proc}/meminfo k v
  if forge_is_darwin; then
    case $1 in
      MemTotal) v=$(sysctl -n hw.memsize) && echo $((v / 1024)) ;;
      MemAvailable) vm_stat | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") p = $(i + 1) }
        /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); n += $NF }
        END { if (!p) exit 1; printf "%d\n", n * p / 1024 }' ;;
      *) return 1 ;;
    esac
    return
  fi
  [ -r "$f" ] || return 1
  while read -r k v _; do
    [ "$k" = "$1:" ] || continue
    case $v in ''|*[!0-9]*) return 1;; esac
    echo "$v"
    return 0
  done <"$f"
  return 1
}

forge_mem_available() { forge_meminfo MemAvailable; }

forge_mem_total() { forge_meminfo MemTotal; }

forge_cpus() {
  [ -z "${FORGE_CPUS:-}" ] || { echo "$FORGE_CPUS"; return; }
  nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1
}

forge_clamp() {
  local v=$1
  [ "$v" -ge "$2" ] || v=$2
  [ "$v" -le "$3" ] || v=$3
  echo "$v"
}

forge_limits() {
  local t g c m
  t=$(forge_mem_total 2>/dev/null) || t=8388608
  g=$(((t + 1048575) / 1048576))
  c=$(forge_cpus)
  m=$((c > 2 ? c : 2))
  lim_sessions=$(forge_clamp $((g / 4)) 1 $((m < 6 ? m : 6)))
  m=$((c / 2 > 1 ? c / 2 : 1))
  lim_concurrency=$(forge_clamp $((g / 8)) 1 $((m < 4 ? m : 4)))
  m=$((c / 4 > 1 ? c / 4 : 1))
  lim_test_runs=$(forge_clamp $((g / 16)) 1 $((m < 2 ? m : 2)))
  lim_reserve_gib=$(forge_clamp $((g / 8)) 1 4)
  lim_test_gib=$(forge_clamp $((g / 4)) 1 4)
}

forge_test_cap() {
  local a c=$((lim_test_gib * 1048576))
  a=$(forge_mem_available 2>/dev/null) || a=$c
  [ "$a" -ge 524288 ] || a=524288
  if [ "$a" -lt "$c" ]; then echo "${a}K"; else echo "${lim_test_gib}G"; fi
}

forge_print_limits() {
  printf 'FORGE_MAX_SESSIONS=%s\nFORGE_CONCURRENCY=%s\nFORGE_TEST_RUNS=%s\nsession memory gate=%s GiB plus 1 GiB per session started\ntest memory cap=%s\n' \
    "${FORGE_MAX_SESSIONS:-$lim_sessions}" "${FORGE_CONCURRENCY:-$lim_concurrency}" "${FORGE_TEST_RUNS:-$lim_test_runs}" "$lim_reserve_gib" "$(forge_test_cap)"
  printf 'memory available KiB=%s\nload=%s\n' "$(forge_mem_available || echo -)" "$(forge_load1 || echo -)"
}

forge_load1() {
  local a
  if forge_is_darwin; then
    a=$(sysctl -n vm.loadavg) || return 1
    set -- $a
    a=$2
  else
    read -r a _ 2>/dev/null <"${FORGE_PROC_ROOT:-/proc}/loadavg" || return 1
  fi
  [[ $a =~ ^[0-9]+\.[0-9]{2}$ ]] || return 1
  echo "$a"
}

forge_uptime() {
  local b
  if forge_is_darwin; then
    b=$(sysctl -n kern.boottime) || return 1
    [[ $b =~ sec\ =\ ([0-9]+) ]] || return 1
    echo $((EPOCHSECONDS - BASH_REMATCH[1]))
  else
    read -r b _ 2>/dev/null <"${FORGE_PROC_ROOT:-/proc}/uptime" || return 1
    echo "$b"
  fi
}

forge_boot_id() {
  if forge_is_darwin; then sysctl -n kern.bootsessionuuid; else cat "${FORGE_PROC_ROOT:-/proc}/sys/kernel/random/boot_id"; fi
}

forge_parent() {
  local p
  if [ -r "/proc/$1/status" ]; then
    sed -n 's/^PPid:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null
  else
    p=$(ps -o ppid= -p "$1" 2>/dev/null) && echo "${p//[[:space:]]/}"
  fi
}

forge_bg() {
  local n=$1 cwd=$2 e q cmd=
  shift 2
  local -a env=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  if [ "$(forge_uname)" = Darwin ]; then
    local l=${XDG_STATE_HOME:-$HOME/.local/state}/forge/bg
    mkdir -p "$l" || return 1
    printf -v cmd 'cd %q && exec env' "${cwd:-$PWD}"
    for e in "${env[@]}" "$@"; do printf -v q ' %q' "$e"; cmd+=$q; done
    launchctl remove "$n" 2>/dev/null || :
    launchctl submit -l "$n" -o "$l/$n.log" -e "$l/$n.log" -- "$(command -v bash)" -c "$cmd"
  else
    local -a a=(--user "--unit=$n" --collect --quiet)
    [ -z "$cwd" ] || a+=("--working-directory=$cwd")
    for e in "${env[@]}"; do a+=("--setenv=$e"); done
    timeout 30 systemd-run "${a[@]}" -- "$@"
  fi
}

forge_bg_stop() {
  if [ "$(forge_uname)" = Darwin ]; then
    launchctl remove "$1" 2>/dev/null || :
  else
    timeout 90 systemctl --user stop "$1"
  fi
}

forge_bg_active() {
  if [ "$(forge_uname)" = Darwin ]; then
    launchctl list "$1" >/dev/null 2>&1
  else
    case $(timeout 30 systemctl --user is-active "$1" 2>/dev/null) in inactive | failed) return 1 ;; esac
  fi
}

forge_bg_cli() {
  local n cwd= s
  local -a env=()
  case ${1:-} in
    --stop) [ $# -eq 2 ] || usage; s=0; forge_bg_stop "$2" 2>/dev/null || s=$?; [ "$s" = 0 ] || [ "$s" = 5 ] || return "$s"; return 0 ;;
    --active) [ $# -eq 2 ] || usage; forge_bg_active "$2"; return ;;
    '' | -*) usage ;;
  esac
  n=$1
  shift
  [[ $n =~ ^[A-Za-z0-9:_.-]+$ ]] || die "forge bg: name '$n' may hold only letters, digits and : _ . -"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    case $1 in
      --cwd) [ $# -ge 2 ] || usage; cwd=$2; shift 2 ;;
      --env) [ $# -ge 2 ] || usage; env+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ $# -ge 2 ] || usage
  shift
  forge_bg "$n" "$cwd" "${env[@]}" "PATH=$PATH" -- "$@"
}
