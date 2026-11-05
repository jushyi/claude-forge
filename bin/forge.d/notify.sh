notify() {
  local s=0 t=${FORGE_NOTIFY_TIMEOUT:-10} tool=notify-send w
  if [ "$(forge_uname)" = Darwin ]; then
    tool=osascript
    timeout "$t" osascript -e 'on run a' -e 'display notification (item 2 of a) with title (item 1 of a)' -e 'end run' -- "$1" "$2" </dev/null || s=$?
  else
    DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus} \
      timeout "$t" notify-send -- "$1" "${2//\\/\\\\}" </dev/null || s=$?
  fi
  case $s in
    0) return 0 ;;
    124) echo "forge: warning: $tool timed out after $t seconds (exit 124)" >&2 ;;
    *)
      if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        w=${XDG_STATE_HOME:-$HOME/.local/state}/forge/notify-warned
        [ -e "$w" ] && return 0
        mkdir -p "${w%/*}" && : >"$w"
        echo "forge: warning: no notifier on this WSL2 system; forge alerts stay in its logs" >&2
        return 0
      fi
      if [ "$s" = 127 ]; then
        echo "forge: warning: $tool not found on PATH (exit 127)" >&2
      else
        echo "forge: warning: $tool failed with exit $s" >&2
      fi ;;
  esac
  return 1
}
