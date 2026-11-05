#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != pre ] || trap 's=$?; [ $s = 0 ] || [ $s = 2 ] || { echo "forge-agent-write: internal error (exit $s); denied" >&2; exit 2; }' EXIT
input=$(cat)
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
sb=$(realpath -m -- "${XDG_STATE_HOME:-$HOME/.local/state}/forge")
case ${1:-} in
  pre)
    "${BASH_SOURCE%/*}/forge-guard.sh" planning <<<"$input" || [ $? != 2 ] || exit 2
    [ -n "$path" ] || { echo "forge: this agent's write names no path" >&2; exit 2; }
    real=$(cd -- "$(jq -r '.cwd // "."' <<<"$input")" && realpath -m -- "$path")
    [[ $real == */.forge/* ]] && exit 0
    if [[ $real == "$sb"/*/* ]]; then
      rest=${real#"$sb"/*/}
      case $rest in
        phases/?* | features/?*) exit 0 ;;
      esac
    fi
    case ${real##*/} in
      PRODUCT.md | DESIGN.md) [[ -e ${real%/*}/.git ]] && exit 0 ;;
    esac
    echo "forge: this agent writes only under .forge/ or the forge state dir; $path is outside them" >&2
    exit 2
    ;;
  post)
    [ -n "$path" ] || exit 0
    path=$(cd -- "$(jq -r '.cwd // "."' <<<"$input")" && realpath -ms -- "$path") || { echo "forge: cannot resolve $path against the input cwd" >&2; exit 2; }
    [[ ($path == */.forge/* || $path == "$sb"/*/*) && $path == *.json* ]] || exit 0
    out=$(forge validate "$path" 2>&1) || { echo "$out" >&2; exit 2; }
    ;;
  *)
    echo "usage: forge-agent-write.sh pre|post" >&2
    exit 1
    ;;
esac
