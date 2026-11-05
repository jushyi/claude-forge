replay_ids() {
  local s f
  for s in requests holdout; do
    for f in "$1/$s"/*; do [ ! -f "$f" ] || printf '%s %s\n' "$s" "${f##*/}"; done
  done
}

replay_hash() {
  (cd "$1" && { cat rules; [ ! -f cutover ] || { echo cutover; cat cutover; }; find requests holdout answers \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | xargs -0r sha256sum; } | sha256sum | cut -d' ' -f1)
}

replay() {
  local sub=${1:-} j=${2:-}
  case $sub in record | run) [ $# -eq 3 ] || usage ;; lock) [ $# -eq 2 ] || usage ;; *) usage ;; esac
  [ -d "$j/requests" ] || die "$j has no requests/ directory"
  j=$(cd "$j" && pwd)
  mkdir -p "$j/holdout"
  [ -f "$j/rules" ] || : >"$j/rules"
  "replay_$sub" "$j" "${3:-}"
}

replay_record() {
  local j=$1 d s id n
  [ ! -e "$j/lock" ] || die "$j is locked; nothing recorded" 3
  for d in answers noise; do
    mkdir -p "$j/$d"
    n=0
    while read -r s id; do
      timeout 60 bash -c "$2" <"$j/$s/$id" >"$j/$d/$id" 2>/dev/null || die "the old command failed on $id; $j/$d/$id is partial"
      n=$((n + 1))
    done < <(replay_ids "$j")
  done
  echo "forge: recorded $n answers twice in $j"
  python3 -I "$D/replay.py" noise "$j"
}

replay_lock() {
  local j=$1 s id r n=0 h=0
  r=$(python3 -I "$D/replay.py" rules "$j/rules") || exit 1
  [ ! -f "$j/cutover" ] || [[ $(<"$j/cutover") =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]] || die "cutover holds '$(<"$j/cutover")', not '<hours> <requests>'"
  while read -r s id; do
    [ -f "$j/answers/$id" ] || die "request $id has no answer; run forge replay record first"
    if [ "$s" = holdout ]; then
      h=$((h + 1))
    else
      n=$((n + 1))
      [ ! -e "$j/holdout/$id" ] || die "request $id is in both requests/ and holdout/"
    fi
  done < <(replay_ids "$j")
  [ "$n" -gt 0 ] || die "$j/requests holds no requests"
  [ "$h" -gt 0 ] || die "$j/holdout holds no requests; hold some out where no fixer sees them"
  echo "$(replay_hash "$j") $(date +%s%N)" >"$j/lock"
  echo "forge: locked $j: $n requests, $h holdout, $r rules"
}

replay_locked() {
  [ -f "$1/lock" ] || die "$1 is not locked; run forge replay lock first" 3
  [ "$(replay_hash "$1")" = "$(cut -d' ' -f1 "$1/lock")" ] || die "$1 changed since it was locked; only the operator relocks it" 3
}

replay_run() {
  local j=$1 s id
  replay_locked "$j"
  rm -rf "$j/got"
  mkdir "$j/got"
  while read -r s id; do
    timeout 60 bash -c "$2" <"$j/$s/$id" >"$j/got/$id" 2>/dev/null || true
  done < <(replay_ids "$j")
  python3 -I "$D/replay.py" run "$j" "$2"
}

port_gate() {
  j=$state/port/$1
  [[ $1 != */* && -d $j/requests ]] || die "no /forge-port judge $1 in $state/port"
  replay_locked "$j"
  [ -f "$j/cutover" ] || die "$j has no cutover gate; write '<hours> <requests>' to $j/cutover and relock"
}

shadow() {
  local j f=$2
  port_gate "$1"
  [ "$f" = - ] || [[ $f == /* ]] || f=$start/$f
  flock "$j/shadow.lock" python3 -I "$D/replay.py" shadow "$j" "$f"
}

cutover() {
  local j
  port_gate "$1"
  python3 -I "$D/replay.py" cutover "$j"
}
