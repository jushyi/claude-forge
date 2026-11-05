phase_finish() {
  local n=$1 f s=0
  phase "$n"
  [ -f "$pd/result.json" ] || die "no $pd/result.json; nothing committed"
  f=$(readlink -f "$0")
  FORGE_ROOT=$root "$f" commit "$n" result </dev/null || exit 1
  FORGE_ROOT=$root "$f" done "$n" </dev/null || s=$?
  if [ $s = 0 ]; then
    echo "forge: phase $n finished"
  else
    echo "forge: phase $n: forge done exited $s" >&2
  fi
  exit $s
}
