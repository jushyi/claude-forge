#!/bin/sh
hook=$1
shift
dir=$(dirname "$0")
if [ "$(uname -s)" = Darwin ] && ! date --version >/dev/null 2>&1; then
  for h in ${FORGE_HOOK_BREW-/opt/homebrew /usr/local}; do
    [ ! -d "$h/bin" ] || PATH=$PATH:$h/bin
    for p in coreutils/libexec/gnubin findutils/libexec/gnubin gnu-sed/libexec/gnubin grep/libexec/gnubin util-linux/bin flock/bin rsync/bin; do
      [ ! -d "$h/opt/$p" ] || PATH=$h/opt/$p:$PATH
    done
  done
  export PATH
fi
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
