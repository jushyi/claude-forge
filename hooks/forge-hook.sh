#!/bin/sh
hook=$1
shift
dir=$(dirname "$0")
modern() {
  [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || return 1
  v=$("$1" -c 'echo "${BASH_VERSINFO:-0}"' 2>/dev/null) || return 1
  case $v in '' | *[!0-9]*) return 1 ;; esac
  [ "$v" -ge 4 ]
}
for b in bash ${FORGE_HOOK_BASHES-/opt/homebrew/bin/bash /usr/local/bin/bash}; do
  if modern "$b"; then
    exec "$b" "$dir/$hook" "$@"
  fi
done
echo "forge: $hook needs Bash 4 or newer and none was found; on macOS run: brew install bash" >&2
case $hook in
  forge-guard*) exit 2 ;;
esac
exit 0
