notify() {
  local s=0 t=${FORGE_NOTIFY_TIMEOUT:-10}
  DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus} \
    timeout "$t" notify-send -- "$1" "${2//\\/\\\\}" </dev/null || s=$?
  case $s in
    0) return 0 ;;
    124) echo "forge: warning: notify-send timed out after $t seconds (exit 124)" >&2 ;;
    127) echo "forge: warning: notify-send not found on PATH (exit 127)" >&2 ;;
    *) echo "forge: warning: notify-send failed with exit $s" >&2 ;;
  esac
  return 1
}
