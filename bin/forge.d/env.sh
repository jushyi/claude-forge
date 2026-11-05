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

forge_meminfo() {
  local f=${FORGE_PROC_ROOT:-/proc}/meminfo k v
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
