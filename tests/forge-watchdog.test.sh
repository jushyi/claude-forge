#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
forge=$repo/bin/forge
export FORGE_TEMPLATES=$repo/templates FORGE_SCHEMAS=$repo/schemas LC_ALL=C
unset FORGE_ROOT FORGE_STALL_MIN FORGE_BG_CEIL_MIN DBUS_SESSION_BUS_ADDRESS FORGE_PERMISSION_MODE FORGE_MAX_SESSIONS CLAUDE_CONFIG_DIR FORGE_NOTIFY_TIMEOUT
export FORGE_WATCHDOG_POLL_SECS=0.05
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FORGE_SYS_ROOT=$tmp/sys FORGE_RUN_ROOT=$tmp/run-root
mkdir -p "$FORGE_RUN_ROOT/systemd/system"
mkdir -p "$FORGE_SYS_ROOT"

fail() { echo "forge-watchdog: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "forge-watchdog $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
command -v jq >/dev/null || fail "jq must be on PATH"

"$forge" --help >"$tmp/forge-help" || fail "forge --help exits 0"
if want help; then
grep -qE '^  watchdog( |$)' "$tmp/forge-help" || fail "forge --help lists watchdog"
"$forge" watchdog --help >"$tmp/help" 2>&1 || fail "forge watchdog --help exits 0: $(cat "$tmp/help")"
[ "$(head -1 "$tmp/help" | cut -d' ' -f1-3)" = "Usage: forge watchdog" ] || fail "forge watchdog --help prints its usage: $(cat "$tmp/help")"
grep -qF FORGE_STALL_MIN "$tmp/help" || fail "forge watchdog --help documents FORGE_STALL_MIN: $(cat "$tmp/help")"
grep -q stall "$tmp/help" || fail "forge watchdog --help documents the stall event: $(cat "$tmp/help")"
ok help
fi

if want notify; then
grep -qE '^  notify( |$)' "$tmp/forge-help" || fail "forge --help lists notify"
"$forge" notify --help >"$tmp/help" 2>&1 || fail "forge notify --help exits 0: $(cat "$tmp/help")"
[ "$(head -1 "$tmp/help" | cut -d' ' -f1-3)" = "Usage: forge notify" ] || fail "forge notify --help prints its usage: $(cat "$tmp/help")"
n=$tmp/notify
mkdir -p "$n/bin" "$n/min" "$n/cwd"
export N_DIR=$n XDG_RUNTIME_DIR=$n/run
cat >"$n/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$N_DIR/args"
printf '%s\n' "${DBUS_SESSION_BUS_ADDRESS-unset}" >"$N_DIR/bus"
cat >"$N_DIR/stdin"
[ -z "${N_SLEEP:-}" ] || exec sleep "$N_SLEEP"
exit "${N_RC:-0}"
STUB
chmod +x "$n/bin/notify-send"
for c in bash dirname readlink timeout id cat sed grep; do ln -s "$(command -v "$c")" "$n/min/$c"; done
np=$n/bin:$PATH
nrun() {
  rm -f "$n/args" "$n/bus" "$n/stdin"
  rc=0
  (cd "$n/cwd" && printf 'stdin data\n' | timeout 60 env "$@") >"$n/out" 2>"$n/err" || rc=$?
}
sent() {
  printf '%s\n' "$@" >"$n/want"
  [ -f "$n/args" ] || fail "forge notify runs notify-send: $(cat "$n/err")"
  cmp -s "$n/want" "$n/args" || fail "forge notify runs notify-send with exactly: $(paste -sd'|' "$n/want"), got: $(paste -sd'|' "$n/args")"
}
warned() {
  [ "$rc" = 1 ] || fail "$1: forge notify exits 1, got $rc: $(cat "$n/err")"
  grep -q '^forge: warning: .*notify-send' "$n/err" || fail "$1: forge notify prints a forge: warning: line naming notify-send on stderr: $(cat "$n/err")"
}
nrun PATH="$np" "$forge" notify "forge: question" "proj P07 tr/feat: needs input"
[ "$rc" = 0 ] || fail "forge notify exits 0 when notify-send succeeds, got $rc: $(cat "$n/err")"
[ ! -s "$n/out" ] && [ ! -s "$n/err" ] || fail "forge notify prints nothing on success: $(cat "$n/out" "$n/err")"
sent -- "forge: question" "proj P07 tr/feat: needs input"
[ ! -s "$n/stdin" ] || fail "notify-send reads its stdin from /dev/null, got: $(cat "$n/stdin")"
[ "$(cat "$n/bus")" = "unix:path=$n/run/bus" ] || fail "with DBUS_SESSION_BUS_ADDRESS unset notify-send runs over unix:path=\$XDG_RUNTIME_DIR/bus, got $(cat "$n/bus")"
nrun -u XDG_RUNTIME_DIR PATH="$np" "$forge" notify t b
[ "$rc" = 0 ] && [ "$(cat "$n/bus")" = "unix:path=/run/user/$(id -u)/bus" ] || fail "with XDG_RUNTIME_DIR unset too notify-send runs over unix:path=/run/user/<uid>/bus, got $rc $(cat "$n/bus" "$n/err")"
nrun DBUS_SESSION_BUS_ADDRESS=unix:path=/elsewhere/bus PATH="$np" "$forge" notify t b
[ "$rc" = 0 ] && [ "$(cat "$n/bus")" = unix:path=/elsewhere/bus ] || fail "a set DBUS_SESSION_BUS_ADDRESS is kept, got $rc $(cat "$n/bus" "$n/err")"
nrun PATH="$np" "$forge" notify -u '--help a\nb \ c'
[ "$rc" = 0 ] || fail "forge notify takes dash-led arguments as title and body, got $rc: $(cat "$n/err")"
sent -- -u '--help a\\nb \\ c'
nrun N_RC=7 PATH="$np" "$forge" notify t b
warned "notify-send exiting 7"
grep '^forge: warning: ' "$n/err" | grep -qw 7 || fail "the warning names notify-send's exit status 7: $(cat "$n/err")"
nrun PATH="$n/min" "$forge" notify t b
warned "notify-send missing from PATH"
s=$SECONDS
nrun FORGE_NOTIFY_TIMEOUT=1 N_SLEEP=120 PATH="$np" "$forge" notify t b
[ $((SECONDS - s)) -lt 30 ] || fail "forge notify bounds notify-send at FORGE_NOTIFY_TIMEOUT=1 seconds, took $((SECONDS - s))"
warned "notify-send hanging past the bound"
grep -qxF 'forge: warning: notify-send timed out after 1 seconds (exit 124)' "$n/err" || fail "the timeout warning names the configured bound: 'forge: warning: notify-send timed out after 1 seconds (exit 124)', got: $(cat "$n/err")"
mkdir -p "$n/tb"
cat >"$n/tb/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$N_DIR/timeout-arg"
shift
exec "$@"
STUB
chmod +x "$n/tb/timeout"
rm -f "$n/timeout-arg"
nrun -u FORGE_NOTIFY_TIMEOUT PATH="$n/tb:$np" "$forge" notify t b
[ "$rc" = 0 ] || fail "forge notify exits 0 under a pass-through timeout with FORGE_NOTIFY_TIMEOUT unset, got $rc: $(cat "$n/err")"
sent -- t b
[ "$(cat "$n/timeout-arg" 2>/dev/null)" = 10 ] || fail "with FORGE_NOTIFY_TIMEOUT unset forge notify bounds notify-send at the default 10 seconds, timeout got: $(cat "$n/timeout-arg" 2>/dev/null)"
"$forge" notify --help >"$tmp/help" 2>&1
grep -qF FORGE_NOTIFY_TIMEOUT "$tmp/help" || fail "forge notify --help names the FORGE_NOTIFY_TIMEOUT bound: $(cat "$tmp/help")"
for a in 0 1 3; do
  set -- t b c
  nrun PATH="$np" "$forge" notify "${@:1:$a}"
  [ "$rc" = 2 ] || fail "forge notify with $a arguments is a usage error (exit 2), got $rc: $(cat "$n/err")"
  [ ! -f "$n/args" ] || fail "forge notify with $a arguments runs no notify-send"
done
set --
m=$n/map
mkdir -p "$m/tests/forge" "$n/rl"
git init -q "$m"
cp "$repo/tests/changed.sh" "$repo/tests/forge.test.sh" "$m/tests/"
for s in forge-watchdog forge-gates forge/help forge/state; do
  printf '#!/usr/bin/env bash\necho %s >>"$N_DIR/mapped"\n' "$s" >"$m/tests/$s.test.sh"
done
chmod +x "$m"/tests/*.sh "$m"/tests/forge/*.sh
for p in bin/forge.d/notify.sh bin/forge.d/help/notify.txt; do
  : >"$n/mapped"
  FORGE_TEST_CPUS=1 FORGE_TEST_LOG_DIR=$n/rl "$m/tests/changed.sh" "$p" >"$n/out" 2>&1 || fail "tests/changed.sh $p: $(cat "$n/out")"
  [ "$(sort -u "$n/mapped" | paste -sd' ')" = "forge-watchdog forge/help" ] || fail "tests/changed.sh maps $p to forge-watchdog and forge/help, got: $(sort -u "$n/mapped" | paste -sd' ')"
done
for pe in "tests/changed.sh|forge-watchdog" ".forge/TESTING.md|forge-watchdog" "bin/forge.d/help/forge.txt|forge-gates forge-watchdog forge/help"; do
  p=${pe%%|*} e=${pe#*|}
  : >"$n/mapped"
  FORGE_TEST_CPUS=1 FORGE_TEST_LOG_DIR=$n/rl "$m/tests/changed.sh" "$p" >"$n/out" 2>&1 || fail "tests/changed.sh $p: $(cat "$n/out")"
  [ "$(sort -u "$n/mapped" | paste -sd' ')" = "$e" ] || fail "tests/changed.sh maps $p to $e, got: $(sort -u "$n/mapped" | paste -sd' ')"
done
ok notify
fi

tf=tr-feat tfs=tr/feat
state_at() {
  local p
  sd=${XDG_STATE_HOME:-$HOME/.local/state}/forge/${1##*/}
  rm -rf "$sd"
  mkdir -p "$sd/features/$tf" "$1/.forge/tracks"
  for p in 07-alpha 08-beta 09-gamma 10-delta 11-eps 12-zeta 13-eta 14-theta 15-iota 16-kappa; do mkdir -p "$sd/phases/$p"; done
  printf '%s\n' "$1" >"$sd/root"
}
setup() {
  env_dir=$tmp/$1
  export HOME=$env_dir/home
  unset XDG_STATE_HOME
  root=$env_dir/Projects/proj
  bin=$env_dir/bin
  log=$env_dir/calls.log
  agents=$env_dir/agents.json
  mkdir -p "$HOME/.claude/projects" "$bin" "$env_dir/elsewhere"
  : >"$log"
  state_at "$root"
  cat >"$bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$WD_LOG"
[ "${1:-}" = agents ] || exit 1
case " $* " in
  *" --all "*) cat "$WD_AGENTS" ;;
  *) jq '[.[] | select(.pid != null or .state == "working" or .state == "blocked")]' "$WD_AGENTS" ;;
esac
STUB
  cat >"$bin/notify-send" <<'STUB'
#!/usr/bin/env bash
printf 'notify-send %s\n' "$(IFS='|'; echo "$*")" >>"$WD_LOG"
printf '%s\n' "${DBUS_SESSION_BUS_ADDRESS:-}" >>"$WD_BUS"
exit "${WD_NOTIFY_RC:-0}"
STUB
  cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$WD_LOG"
u=${!#}
case " $* " in
  *" list-units "*)
    [ -f "$WD_SCOPES/list" ] || exit 0
    pats=() st=
    for a in "$@"; do
      case $a in --state=*) st=,${a#--state=}, ;; -* | list-units) ;; *) pats+=("$a") ;; esac
    done
    while read -r n l s r; do
      m=0
      [ ${#pats[@]} != 0 ] || m=1
      for p in "${pats[@]}"; do [[ $n != $p ]] || m=1; done
      [ $m = 1 ] || continue
      [ -z "$st" ] || [[ $st == *",$s,"* ]] || continue
      printf '%s %s %s %s\n' "$n" "$l" "$s" "$r"
    done <"$WD_SCOPES/list"
    exit 0
    ;;
  *" show "*RuntimeMaxUSec*)
    if [ -f "$WD_SCOPES/$u.limit" ]; then cat "$WD_SCOPES/$u.limit"; else echo infinity; fi
    exit 0
    ;;
  *" show "*ActiveEnterTimestamp*)
    if [ -f "$WD_SCOPES/$u.start" ]; then cat "$WD_SCOPES/$u.start"; else echo; fi
    exit 0
    ;;
esac
exit "${WD_SYSTEMCTL_RC:-0}"
STUB
  cat >"$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$WD_LOG"
echo "stub systemd-run must not run in tests" >&2
exit 64
STUB
  for c in pgrep ps; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >>"$WD_LOG"\nexit 1\n' "$c" >"$bin/$c"
  done
  chmod +x "$bin"/*
  export FORGE_CPUS=16 FORGE_MAX_SESSIONS=12 FORGE_CONCURRENCY=10 WD_LOG=$log WD_AGENTS=$agents WD_BUS=$env_dir/bus.log WD_SCOPES=$env_dir/scopes XDG_RUNTIME_DIR=$env_dir/run FORGE_PROC_ROOT=$env_dir/proc CLAUDE_CODE_TMPDIR=$env_dir/ctmp
  mkdir -p "$XDG_RUNTIME_DIR" "$FORGE_PROC_ROOT"
  printf 'MemTotal: 33554432 kB\nMemAvailable: 16777216 kB\n' >"$FORGE_PROC_ROOT/meminfo"
  mkdir -p "$FORGE_PROC_ROOT/sys/kernel/random" "$HOME/.local/state/forge"
  printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b001 >"$FORGE_PROC_ROOT/sys/kernel/random/boot_id"
  printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b001 >"$HOME/.local/state/forge/doctor-boot"
  date +%s >"$HOME/.local/state/forge/gc-week"
  : >"$WD_BUS"
  echo '[]' >"$agents"
}

session() {
  local name=$1 state=$2 cwd=$3 sid=$4
  jq --arg n "$name" --arg s "$state" --arg c "$cwd" --arg i "$sid" \
    '. + [{pid: 1, id: ($i | .[0:8]), kind: "background", startedAt: 1, name: $n, status: "busy", state: $s}
      + (if $c == "" then {} else {cwd: $c} end) + (if $i == "" then {} else {sessionId: $i} end)]' \
    "$agents" >"$agents.new"
  mv "$agents.new" "$agents"
  [ -n "$cwd" ] && [ -n "$sid" ] || return 0
  mkdir -p "$cwd"
}

pdir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }
transcript() {
  local d
  d=$(pdir "$1")
  mkdir -p "$d"
  echo '{}' >"$d/$2.jsonl"
  [ -z "${4:-}" ] || jq -cn --arg a "$4" '{type: "user", message: {role: "user", content: ("<command-message>x</command-message>\n<command-name>/x</command-name>\n<command-args>" + $a + "</command-args>")}}' >>"$d/$2.jsonl"
  touch -d "$3 minutes ago" "$d/$2.jsonl"
}
subagent() {
  local d
  d=$(pdir "$1")/$2/subagents
  mkdir -p "$d"
  echo '{}' >"$d/agent-$3.jsonl"
  touch -d "$4 minutes ago" "$d/agent-$3.jsonl"
}

populate() {
  wt=$root/.claude/worktrees
  session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
  transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
  subagent "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 old7 40
  session "proj P08 $tfs" working "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008
  transcript "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 60
  subagent "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 new8 2
  session "proj P09R1 $tfs" working "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009
  transcript "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 25
  session "proj P10 $tfs" blocked "$wt/$tf-10" aaaaaa10-0000-4000-8000-000000000010
  transcript "$wt/$tf-10" aaaaaa10-0000-4000-8000-000000000010 90
  session "proj P11 $tfs" crashed "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011
  transcript "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011 90
  session "proj P12 $tfs" stopped "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012
  transcript "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012 90
  session "proj P13 $tfs" working "$wt/$tf-13" ""
  session "proj P14 $tfs" working "" aaaaaa14-0000-4000-8000-000000000014
  transcript "$wt/$tf-14" aaaaaa14-0000-4000-8000-000000000014 90
  session "scratch notes" working "$env_dir/elsewhere" bbbbbbbb-0000-4000-8000-000000000001
  transcript "$env_dir/elsewhere" bbbbbbbb-0000-4000-8000-000000000001 90
  session "proj verify $tfs" working "$wt/$tf" cccccccc-0000-4000-8000-00000000000v
  transcript "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 45
  session "proj ship $tfs" working "$root" dddddddd-0000-4000-8000-00000000000s
  transcript "$root" dddddddd-0000-4000-8000-00000000000s 50
  session "proj $tf Phase 15" working "$wt/$tf-15" aaaaaa15-0000-4000-8000-000000000015
  transcript "$wt/$tf-15" aaaaaa15-0000-4000-8000-000000000015 35
  session "proj $tf Phase 16 retry 2" working "$wt/$tf-16" aaaaaa16-0000-4000-8000-000000000016
  transcript "$wt/$tf-16" aaaaaa16-0000-4000-8000-000000000016 28
  session "proj $tf Verify" working "$wt/$tf" cccccccc-0000-4000-8000-0000000000lv
  transcript "$wt/$tf" cccccccc-0000-4000-8000-0000000000lv 55
  session "proj $tf Ship" working "$root" dddddddd-0000-4000-8000-0000000000ls
  transcript "$root" dddddddd-0000-4000-8000-0000000000ls 65
}

run() {
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog "$@") >"$env_dir/out" 2>&1 ||
    fail "forge watchdog exits 0 from a directory without .forge: $(cat "$env_dir/out")"
}

stalls() {
  local ev=$sd/phases/$1/events.jsonl
  [ -f "$ev" ] || { echo 0; return; }
  jq -s 'map(select(.step == "stall")) | length' "$ev"
}
has_minutes() { printf '%s\n' "$1" | grep -Eq "(^|[^0-9])$2([^0-9]|$)"; }
stalled() {
  local p=$1 name=$2 sid=$3 min=$4 msg
  [ "$(stalls "$p")" = 1 ] || fail "$name stalled at $min min must log one stall event in phases/$p/events.jsonl, got $(stalls "$p"): $(cat "$sd/phases/$p/events.jsonl" 2>/dev/null)"
  msg=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")
  [[ $msg == *"$name"* || $msg == *"$sid"* ]] || fail "the stall event of $p names the session: '$msg'"
  has_minutes "$msg" "$min" || fail "the stall event of $p gives $min idle minutes: '$msg'"
}
ends() {
  local ev=$sd/phases/$1/events.jsonl
  [ -f "$ev" ] || { echo 0; return; }
  jq -s 'map(select(.step == "stall" and (.message | contains("turn ended with no result")))) | length' "$ev"
}
quiet() { [ "$(stalls "$1")" = 0 ] || fail "$2: phases/$1/events.jsonl must hold no stall event: $(cat "$sd/phases/$1/events.jsonl")"; }
featured() {
  local name=$1 sid=$2 min=$3 lines f
  lines=$(grep -rhF -e "$name" -e "$sid" "$sd/features/$tf" 2>/dev/null || true)
  [ -n "$lines" ] || fail "the $name stall must be logged under S/features/$tf/: $(find "$sd" -type f)"
  printf '%s\n' "$lines" | grep -q stall || fail "the $name feature-level record is a stall: $lines"
  has_minutes "$lines" "$min" || fail "the $name stall gives $min idle minutes: $lines"
  f=$(grep -rlF -e "$name" -e "$sid" "$sd/features/$tf" | head -1)
  grep -qF "$(basename "$f")" "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the feature-level stall log $(basename "$f")"
  ! grep -rqF -e "$name" -e "$sid" "$sd/phases" || fail "the $name stall must not go to a phase's events.jsonl"
}
nothing_else() {
  local bad
  bad=$(grep -v -e '^claude agents' -e '^notify-send --|forge: turn ended|' \
    -e '^systemctl --user list-units ' -e '^systemctl --user show -p RuntimeMaxUSec ' -e '^systemctl --user show -p ActiveEnterTimestamp ' \
    -e '^notify-send --|forge: test past limit|' "$log" || true)
  [ -z "$bad" ] || fail "forge watchdog only lists sessions: no nudge, no pgrep/ps wait loop: $bad"
  grep -q '^claude agents.*--json' "$log" || fail "forge watchdog reads claude agents --json: $(cat "$log")"
}

if want doctor-boot; then
setup doctor-boot
cat >"$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$WD_LOG"
[ "$*" != "--user is-enabled --quiet forge-watchdog.timer" ] || exit 1
exit 0
STUB
chmod +x "$bin/systemctl"
bid=$FORGE_PROC_ROOT/sys/kernel/random/boot_id db=$HOME/.local/state/forge/doctor-boot
doctored() { grep -c '^systemctl --user is-enabled --quiet forge-watchdog\.timer$' "$log" || true; }
dnotes() { grep -c '^notify-send --|forge: doctor|' "$log" || true; }
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b002 >"$bid"
rm -f "$db"
run
[ "$(doctored)" = 1 ] || fail "a scan with no doctor-boot runs forge doctor once, got $(doctored) forge-watchdog.timer checks: $(cat "$log")"
[ -f "$db" ] || fail "the scan that runs forge doctor writes $db: $(cat "$env_dir/out")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b002 ] || fail "doctor-boot holds the boot id 0b5e7c1a-0000-4000-8000-00000000b002, got: $(cat "$db")"
[ "$(dnotes)" = 1 ] || fail "doctor finding a problem sends one forge notify titled 'forge: doctor', got $(dnotes): $(grep '^notify-send ' "$log" || true)"
line=$(grep '^notify-send --|forge: doctor|' "$log")
[[ $line == 'notify-send --|forge: doctor|1 problems: '* ]] || fail "the doctor notify body is '<n> problems: <first problem line>' with n=1, got: $line"
[[ $line == *'forge-watchdog.timer is not enabled'* ]] || fail "the doctor notify body carries the first problem line, got: $line"
: >"$log"
run
[ "$(doctored)" = 0 ] || fail "a second scan in the same boot runs no forge doctor: $(cat "$log")"
[ "$(dnotes)" = 0 ] || fail "a second scan in the same boot sends no doctor notify: $(grep '^notify-send ' "$log")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b002 ] || fail "doctor-boot keeps the boot id on a same-boot scan, got: $(cat "$db")"
: >"$log"
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b003 >"$bid"
run
[ "$(doctored)" = 1 ] && [ "$(dnotes)" = 1 ] || fail "a scan after a new boot runs forge doctor and notifies once, got $(doctored) checks and $(dnotes) notifies: $(cat "$log")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b003 ] || fail "doctor-boot holds the new boot id, got: $(cat "$db")"
: >"$log"
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b004 >"$bid"
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" WD_NOTIFY_RC=1 "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
  fail "a failing doctor notify does not fail forge watchdog: $(cat "$env_dir/out" "$env_dir/err")"
[ "$(doctored)" = 1 ] || fail "a scan after a new boot runs forge doctor, got $(doctored): $(cat "$log")"
grep -q '^forge: warning: ' "$env_dir/err" || fail "a failing doctor notify prints forge: warning: on stderr: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan goes on after a failing doctor notify: $(cat "$log")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b004 ] || fail "doctor-boot is written even when the doctor notify fails, got: $(cat "$db")"
: >"$log"
mkdir -p "$HOME/Projects/doctor-hang/.forge"
cat >"$bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"/Projects/doctor-hang rev-parse --path-format=absolute --git-common-dir "*) echo doctor-git-hang >>"\$WD_LOG"; exec sleep 600 ;;
esac
exec $(command -v git) "\$@"
STUB
chmod +x "$bin/git"
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b005 >"$bid"
s=$SECONDS
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" FORGE_DOCTOR_TIMEOUT=2 "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
  fail "a hanging forge doctor does not fail forge watchdog: $(cat "$env_dir/out" "$env_dir/err")"
[ $((SECONDS - s)) -lt 30 ] || fail "forge watchdog bounds forge doctor at FORGE_DOCTOR_TIMEOUT seconds, took $((SECONDS - s))"
grep -q '^doctor-git-hang$' "$log" || fail "the hanging doctor ran its git rev-parse lock-holder check: $(cat "$log")"
grep -q '^forge: warning: forge doctor timed out after 2 s' "$env_dir/err" || fail "a hanging forge doctor prints a forge: warning: timed out line on stderr: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan goes on after a hanging forge doctor: $(cat "$log")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b005 ] || fail "doctor-boot is written after a timed-out forge doctor, got: $(cat "$db")"
[ "$(dnotes)" = 1 ] || fail "a timed-out forge doctor that printed a local problem sends one forge notify titled 'forge: doctor', got $(dnotes): $(grep '^notify-send ' "$log" || true)"
line=$(grep '^notify-send --|forge: doctor|' "$log")
[[ $line == 'notify-send --|forge: doctor|1 problems: '*'forge-watchdog.timer is not enabled'* ]] ||
  fail "a timed-out forge doctor notifies '<n> problems: <first problem line>' with its local problem, got: $line"
: >"$log"
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b006 >"$bid"
exec 8>>"$db.lock"
flock 8
s=$SECONDS
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog 8>&-) >"$env_dir/out" 2>"$env_dir/err" ||
  fail "a held doctor-boot.lock does not fail forge watchdog: $(cat "$env_dir/out" "$env_dir/err")"
exec 8>&-
[ $((SECONDS - s)) -lt 30 ] || fail "a scan does not wait for a doctor-boot.lock another scan holds, took $((SECONDS - s))"
[ "$(doctored)" = 0 ] || fail "a scan that finds doctor-boot.lock held runs no forge doctor: $(cat "$log")"
grep -q '^forge: warning: .*doctor-boot\.lock' "$env_dir/err" || fail "a held doctor-boot.lock prints a forge: warning: line naming it on stderr: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan goes on past a held doctor-boot.lock: $(cat "$log")"
[ "$(cat "$db")" = 0b5e7c1a-0000-4000-8000-00000000b005 ] || fail "a scan that skips forge doctor leaves doctor-boot, got: $(cat "$db")"
rm -rf "$HOME/Projects/doctor-hang" "$bin/git"
: >"$log"
rm -f "$bid"
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
  fail "an unreadable boot id does not fail forge watchdog: $(cat "$env_dir/out" "$env_dir/err")"
grep -q '^forge: warning: .*boot' "$env_dir/err" || fail "an unreadable boot id prints a forge: warning: line naming the boot id on stderr: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan goes on after an unreadable boot id: $(cat "$log")"
for w in doctor-boot sys/kernel/random/boot_id 'forge: doctor' 'forge doctor'; do
  grep -qF "$w" "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the once-per-boot doctor run: no '$w'"
done
ok doctor-boot
fi

if want doctor-removed; then
setup doctor-removed
fb=$env_dir/fb
cp -R "$repo/bin" "$fb"
cat >"$fb/forge.d/zz-doctor-stub.sh" <<'STUB'
doctor() {
  echo "forge doctor: removed dead lock holder $HOME/.local/state/forge/build.lock (pid 4242)"
  echo "forge doctor: forge-watchdog.timer is not enabled"
  return 1
}
STUB
printf '%s\n' 0b5e7c1a-0000-4000-8000-00000000b00a >"$FORGE_PROC_ROOT/sys/kernel/random/boot_id"
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$fb/forge" watchdog) >"$env_dir/out" 2>&1 ||
  fail "forge watchdog exits 0 when forge doctor exits 1: $(cat "$env_dir/out")"
[ "$(cat "$HOME/.local/state/forge/doctor-boot")" = 0b5e7c1a-0000-4000-8000-00000000b00a ] || fail "the scan ran forge doctor and wrote doctor-boot: $(cat "$env_dir/out")"
notes=$(grep '^notify-send --|forge: doctor|' "$log" || true)
[ "$notes" = 'notify-send --|forge: doctor|1 problems: forge-watchdog.timer is not enabled' ] ||
  fail "a doctor exiting 1 with a 'forge doctor: removed ' line and one problem line alerts '1 problems: forge-watchdog.timer is not enabled', got: $notes"
ok doctor-removed
fi

if want gc-week; then
setup gc-week
fb=$env_dir/fb
cp -R "$repo/bin" "$fb"
cat >"$fb/forge.d/zz-gc-stub.sh" <<'STUB'
gc() {
  printf 'gc %s %s %s\n' "$1" "$root" "$PWD" >>"$WD_LOG"
  [ "$root" != "${WD_GC_HANG:-}" ] && [ "${WD_GC_HANG:-}" != all ] || exec sleep 600
  [ "$root" != "${WD_GC_FAIL:-}" ] || return 3
  return 0
}
STUB
gw=$HOME/.local/state/forge/gc-week gr=$HOME/.local/state/forge/watchdog-roots
g1=$env_dir/gc-a g2=$env_dir/gc-b g3=$env_dir/gc-c
mkdir -p "$g1/.forge/phases" "$g2/.forge/phases" "$g3/.forge/phases"
groots() { printf '%s\n' "$g1" "$env_dir/gc-gone" "$g2" "$g1" >"$gr"; }
gcs() { grep -c '^gc ' "$log" || true; }
grun() {
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$@" "$fb/forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
    fail "forge watchdog exits 0 around the weekly forge gc: $(cat "$env_dir/out" "$env_dir/err")"
  grep -q '^claude agents.*--json' "$log" || fail "the stall scan runs around the weekly forge gc: $(cat "$log")"
}
rm -f "$gw"
groots
t0=$(date +%s)
grun
t1=$(date +%s)
[ "$(gcs)" = 2 ] || fail "a missing gc-week stamp runs forge gc once per listed root that is a directory, got $(gcs): $(cat "$log")"
grep -qxF "gc --apply $g1 $env_dir" "$log" && grep -qxF "gc --apply $g2 $env_dir" "$log" ||
  fail "forge gc --apply runs with FORGE_ROOT=<root> from the caller's cwd: $(cat "$log")"
! grep -qF gc-gone "$log" || fail "a listed root that is no longer a directory runs no forge gc: $(cat "$log")"
[ "$(grep -n '^gc ' "$log" | head -1 | cut -d: -f1)" -gt "$(grep -n '^claude agents.*--all' "$log" | head -1 | cut -d: -f1)" ] ||
  fail "the weekly forge gc runs after the stall scan: $(cat "$log")"
s=$(cat "$gw" 2>/dev/null) || s=
[[ $s =~ ^[0-9]+$ ]] && [ "$s" -ge "$t0" ] && [ "$s" -le "$t1" ] || fail "the weekly gc writes the epoch second to $gw, got: '$s'"
: >"$log"
groots
echo $((t0 - 3600)) >"$gw"
grun
[ "$(gcs)" = 0 ] || fail "a gc-week stamp younger than 7 days runs no forge gc: $(cat "$log")"
[ "$(cat "$gw")" = $((t0 - 3600)) ] || fail "a scan that runs no gc leaves gc-week, got: $(cat "$gw")"
: >"$log"
groots
echo $((t0 - 604800 - 60)) >"$gw"
t0=$(date +%s)
grun
[ "$(gcs)" = 2 ] || fail "a gc-week stamp older than 7 days runs forge gc again per root, got $(gcs): $(cat "$log")"
s=$(cat "$gw")
[ "$s" -ge "$t0" ] || fail "the gc that ran again rewrites gc-week, got: $s"
: >"$log"
printf '%s\n' "$g1" "$g2" "$g3" >"$gr"
rm -f "$gw"
s=$SECONDS
grun WD_GC_FAIL="$g1" WD_GC_HANG="$g2" FORGE_GC_TIMEOUT=2
[ $((SECONDS - s)) -lt 30 ] || fail "forge watchdog bounds forge gc at FORGE_GC_TIMEOUT seconds, took $((SECONDS - s))"
[ "$(gcs)" = 3 ] || fail "a failing and a hung forge gc do not stop the gc of the next root, got $(gcs): $(cat "$log")"
[ "$(grep -c '^forge: warning: .*forge gc' "$env_dir/err")" = 2 ] || fail "a failing and a hung forge gc each print one forge: warning: line: $(cat "$env_dir/err")"
grep -q "^forge: warning: .*forge gc.*$g1.* 3" "$env_dir/err" || fail "a failing forge gc warns naming the root and its exit: $(cat "$env_dir/err")"
grep -q "^forge: warning: .*forge gc.*$g2.*timed out after 2 s" "$env_dir/err" || fail "a hung forge gc warns naming the root and the timeout: $(cat "$env_dir/err")"
[ -f "$gw" ] || fail "gc-week is written after a failing forge gc"
: >"$log"
rm -f "$gw"
t0=$(date +%s)
grun SECONDS=280 WD_GC_HANG=all FORGE_GC_TIMEOUT=60
[ "$(gcs)" = 1 ] || fail "a hung forge gc near the 285 s scan deadline leaves the next roots for next week, got $(gcs): $(cat "$log")"
[ $(($(date +%s) - t0)) -lt 15 ] || fail "forge watchdog caps forge gc at 285 s into the scan, took $(($(date +%s) - t0)) s"
grep -q "^forge: warning: forge gc --apply in $env_dir/gc-[abc] timed out after [1-5] s" "$env_dir/err" ||
  fail "a forge gc capped at the scan deadline warns with the capped timeout: $(cat "$env_dir/err")"
[ "$(grep -c '^forge: warning: the weekly forge gc reached the 5 min forge-watchdog.service deadline before ' "$env_dir/err")" = 1 ] ||
  fail "a root reached past the scan deadline prints one deadline warning: $(cat "$env_dir/err")"
[ -f "$gw" ] || fail "gc-week is written when the scan deadline cuts the weekly gc short"
for w in gc-week FORGE_GC_TIMEOUT 'forge gc --apply' watchdog-roots; do
  grep -qF "$w" "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the weekly forge gc: no '$w'"
done
ok gc-week
fi

if want default; then
setup default
populate
run
stalled 07-alpha "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
quiet 08-beta "a subagent transcript 2 min old counts as activity"
stalled 09-gamma "proj P09R1 $tfs" aaaaaaa9-0000-4000-8000-000000000009 25
stalled 10-delta "proj P10 $tfs" aaaaaa10-0000-4000-8000-000000000010 90
[ "$(stalls 11-eps)$(ends 11-eps)" = 11 ] || fail "a crashed session gets no idle stall, only an ended-turn stall: $(cat "$sd/phases/11-eps/events.jsonl")"
[ "$(stalls 12-zeta)$(ends 12-zeta)" = 11 ] || fail "a stopped session gets no idle stall, only an ended-turn stall: $(cat "$sd/phases/12-zeta/events.jsonl")"
quiet 13-eta "a session without sessionId is skipped"
quiet 14-theta "a session without cwd is skipped"
featured "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
featured "proj ship $tfs" dddddddd-0000-4000-8000-00000000000s 50
stalled 15-iota "proj $tf Phase 15" aaaaaa15-0000-4000-8000-000000000015 35
stalled 16-kappa "proj $tf Phase 16 retry 2" aaaaaa16-0000-4000-8000-000000000016 28
featured "proj $tf Verify" cccccccc-0000-4000-8000-0000000000lv 55
featured "proj $tf Ship" dddddddd-0000-4000-8000-0000000000ls 65
[ -z "$(find "$env_dir/elsewhere" -name events.jsonl)" ] || fail "a non-forge session logs nothing"
nothing_else
ok default
fi

if want override; then
setup override
populate
FORGE_STALL_MIN=30 run
stalled 07-alpha "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
quiet 09-gamma "25 idle minutes is under FORGE_STALL_MIN=30"
quiet 08-beta "a subagent transcript 2 min old counts as activity"
featured "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
nothing_else
FORGE_STALL_MIN=60 run
[ "$(stalls 07-alpha)" = 1 ] || fail "30 idle minutes under FORGE_STALL_MIN=60 logs no new stall"
ok override
fi

if want codex-quota; then
setup codex-quota
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
qj=$HOME/.claude/plugins/data/codex-openai-codex/state/ws-1/jobs
mkdir -p "$qj"
qjob() { jq -n --arg t "$(date -u -d "$2" +%FT%T.000Z)" '{status: "failed", completedAt: $t, errorMessage: "Your workspace is out of credits."}' >"$qj/$1.json"; }
qnotes() { grep -c '^notify-send --|forge: Codex out of credits|' "$log" || true; }
qlogins() { grep -cxF 'systemd-run --user --unit=forge-codex-login.service --collect --quiet -- codex login' "$log" || true; }
run
[ "$(qnotes)$(qlogins)" = 00 ] || fail "a scan with no failed Codex job starts no login: $(cat "$log")"
! grep -q forge-codex-login "$log" || fail "a scan with no failed Codex job touches no login unit: $(cat "$log")"
[ "$(stalls 07-alpha)" = 1 ] || fail "the stall scan runs beside the quota check: $(cat "$sd/phases/07-alpha/events.jsonl")"
qjob a '-2 min'
run
[ "$(qnotes)$(qlogins)" = 11 ] || fail "a scan notifies a failed Codex job and opens a login: $(cat "$log")"
grep -q '^forge: warning: .*Codex login' "$env_dir/out" || fail "a failed login start warns: $(cat "$env_dir/out")"
[ "$(stalls 07-alpha)" = 2 ] || fail "a failed login start leaves the stall scan running: $(cat "$sd/phases/07-alpha/events.jsonl")"
cat >"$bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$WD_LOG"
STUB
run
[ "$(qnotes)$(qlogins)" = 11 ] || fail "a later scan of the same job sends nothing: $(cat "$log")"
rm "$qj/a.json" "$HOME/.local/state/forge/codex-quota-notified"
qjob b '-7 min'
touch -d '7 minutes ago' "$qj/b.json"
run
[ "$(qnotes)$(qlogins)" = 22 ] || fail "a scan covers the job that finished just after the last scan's read: $(cat "$log")"
! grep -q '^forge: warning: .*Codex login' "$env_dir/out" || fail "a started login warns nothing: $(cat "$env_dir/out")"
[ "$(cat "$HOME/.local/state/forge/codex-quota-notified")" = "$(jq -r .completedAt "$qj/b.json")" ] || fail "the scan records the notified job"
qjob c '-1 min'
mkdir -p "$HOME/.codex"
touch "$HOME/.codex/auth.json"
run
[ "$(qnotes)$(qlogins)" = 22 ] || fail "an auth.json newer than the job sends nothing: $(cat "$log")"
touch -d '10 minutes ago' "$HOME/.codex/auth.json"
rm "$HOME/.local/state/forge/codex-quota-notified"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/claude"
if (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1; then fail "a failed claude agents listing still exits 1: $(cat "$env_dir/out")"; fi
grep -q 'cannot list Claude sessions' "$env_dir/out" || fail "the listing's die names itself: $(cat "$env_dir/out")"
[ "$(qnotes)$(qlogins)" = 33 ] || fail "the quota check runs before the listing can die: $(cat "$log")"
grep -qF forge-codex-login.service "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt names the login unit"
ok codex-quota
fi

rline() { jq -cn --arg t "$(date -u -d "$3 minutes ago" +%FT%TZ)" --arg s "$2" --arg m "$4" '{time: $t, step: $s, message: $m}' >>"$1/events.jsonl"; }
refusals() { grep -F 'notify-send --|forge: launch refused|' "$log" | sed 's/^notify-send --|forge: launch refused|//' | sort || true; }
rstalls() { [ -f "$1/events.jsonl" ] || { echo 0; return; }; jq -s 'map(select(.step == "stall")) | length' "$1/events.jsonl"; }
rlogged() {
  local d=$1 what=$2 last
  [ "$(rstalls "$d")" = 1 ] || fail "$what: one stall event in $d/events.jsonl, got $(rstalls "$d"): $(cat "$d/events.jsonl")"
  last=$(jq -cs last "$d/events.jsonl")
  [ "$(jq -r .step <<<"$last")" = stall ] || fail "$what: the stall is the last event of $d/events.jsonl: $(cat "$d/events.jsonl")"
  jq -r .message <<<"$last" | grep -qi refused || fail "$what: the stall message names the refusal: $last"
}

if want refused; then
setup refused
printf '%s\n' "$root" >"$HOME/.local/state/forge/watchdog-roots"
pd=$sd/phases fd=$sd/features/$tf
m07="phase 07 not started: the worktree has uncommitted changes"
mfeat="verify tr/feat not started: verify.json already exists"
rline "$pd/07-alpha" start 60 "proj P07 $tfs"
rline "$pd/07-alpha" refused 45 "$m07"
rline "$fd" refused 40 "$mfeat"
rline "$pd/08-beta" refused 10 "phase 08 not started: young refusal"
rline "$pd/09-gamma" refused 50 "phase 09 not started: later step"
rline "$pd/09-gamma" start 35 "proj P09 $tfs"
run
[ "$(refusals)" = "$(printf '%s\n' "proj $m07" "proj $mfeat" | sort)" ] ||
  fail "a first scan sends one forge notify \"forge: launch refused\" \"proj <message>\" for each refused event at least 30 min old that is still its file's last event, got: $(refusals | paste -sd';') (log: $(cat "$log"); out: $(cat "$env_dir/out"))"
rlogged "$pd/07-alpha" "an old refused phase event"
rlogged "$fd" "an old refused feature event"
[ "$(rstalls "$pd/08-beta")" = 0 ] || fail "a refused event 10 min old logs no stall: $(cat "$pd/08-beta/events.jsonl")"
[ "$(rstalls "$pd/09-gamma")" = 0 ] || fail "a refused event followed by another step logs no stall: $(cat "$pd/09-gamma/events.jsonl")"
: >"$log"
run
[ -z "$(refusals)" ] || fail "a second scan sends no launch-refused alert for refusals already alerted: $(refusals | paste -sd';')"
rlogged "$pd/07-alpha" "a second scan of an alerted phase refusal"
rlogged "$fd" "a second scan of an alerted feature refusal"
[ "$(rstalls "$pd/08-beta")$(rstalls "$pd/09-gamma")" = 00 ] || fail "a second scan logs no stall for the young or superseded refusals"
rline "$pd/10-delta" refused 31 "phase 10 not started: notify fails"
: >"$log"
WD_NOTIFY_RC=1 run
[ "$(refusals)" = "proj phase 10 not started: notify fails" ] || fail "a scan whose notify fails tries the launch-refused alert once: $(refusals | paste -sd';')"
grep -q '^forge: cannot send ' "$env_dir/out" || fail "a failed launch-refused notify prints a forge: cannot send warning: $(cat "$env_dir/out")"
ok refused
fi

if want test-past-limit; then
setup test-past-limit
sc=$WD_SCOPES
tpl=$env_dir/state/forge/test-past-limit
mkdir -p "$sc"
scope() {
  local sub
  case $2 in active) sub=running ;; deactivating) sub=stop-sigterm ;; failed) sub=failed ;; *) sub=dead ;; esac
  printf '%s loaded %s %s [systemd-run] /usr/bin/bash -c tests/forge.test.sh\n' "$1" "$2" "$sub" >>"$sc/list"
  [ "$3" = - ] || printf '%s\n' "$3" >"$sc/$1.limit"
  case $4 in -) ;; '' | *[!0-9]*) printf '%s\n' "$4" >"$sc/$1.start" ;; *) printf '@%s\n' $(($(date +%s) - $4 * 60)) >"$sc/$1.start" ;; esac
}
tscan() {
  local what=$1
  shift
  : >"$log"
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" XDG_STATE_HOME="$env_dir/state" "$@" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
    fail "$what: forge watchdog exits 0: $(cat "$env_dir/out" "$env_dir/err")"
}
limits() { grep -F 'notify-send --|forge: test past limit|' "$log" | sed 's/^notify-send --|forge: test past limit|//' | sort || true; }
reported() {
  local what=$1
  shift
  [ "$(limits)" = "$(printf '%s\n' "$@" | sort)" ] ||
    fail "$what: one forge notify \"forge: test past limit\" \"<unit> running <age> min\" for exactly: $(printf '%s; ' "$@"), got: $(limits | paste -sd';') (log: $(cat "$log"))"
}
none() { [ -z "$(limits)" ] || fail "$1 sends no test-past-limit alert: $(limits | paste -sd';')"; }
recorded() { [ -f "$tpl" ] && grep -qF "$1" "$tpl" || fail "$2: $tpl records $1: $(cat "$tpl" 2>/dev/null)"; }
unrecorded() { [ ! -f "$tpl" ] || ! grep -qF "$1" "$tpl" || fail "$2: $tpl does not record $1: $(cat "$tpl")"; }
clean_err() { ! grep -qF forge-test- "$env_dir/err" || fail "$1 prints nothing about the scopes on stderr: $(cat "$env_dir/err")"; }
scope forge-test-101-1.scope active 1min 10
scope forge-test-102-1.scope deactivating 1min 20
scope forge-test-103-1.scope active '1h 40min' 110
scope forge-test-112-1.scope active 1d 1450
scope forge-test-113-1.scope active '2min 500ms' 8
scope forge-test-104-1.scope active '1min 30s' 5
scope forge-test-105-1.scope active infinity 600
scope forge-test-106-1.scope active '' 600
scope forge-test-107-1.scope inactive 1min 10
scope forge-test-108-1.scope failed 1min 10
scope forge-test-109-1.scope active - -
scope forge-test-110-1.scope active 1min @0
scope forge-test-111-1.scope active 1min junk
scope forge-stack-120-1.scope active 1min 10
past=("forge-test-101-1.scope running 10 min" "forge-test-102-1.scope running 20 min" "forge-test-103-1.scope running 110 min"
  "forge-test-112-1.scope running 1450 min" "forge-test-113-1.scope running 8 min")
tscan "a first scan with past-limit forge-test scopes"
reported "a first scan: past limit + 5 min (active and deactivating, s/min/h/d/ms limits); not within limit + 5 min, infinity, empty, inactive, failed, vanished, @0, unreadable start or forge-stack" "${past[@]}"
clean_err "a first scan, with a vanished unit (empty start, infinity limit)"
nothing_else
for u in 101 102 103 112 113; do recorded "forge-test-$u-1.scope" "a reported scope"; done
for u in 104 105 106 107 108 109 110 111; do unrecorded "forge-test-$u-1.scope" "an unreported scope"; done
tscan "a second scan"
none "a second scan of the same scopes"
clean_err "a second scan"
sed -i '/^forge-test-101-1\.scope /d' "$sc/list"
tscan "a scan after forge-test-101-1.scope is gone"
none "a scan after forge-test-101-1.scope is gone"
unrecorded forge-test-101-1.scope "a unit no longer listed is pruned"
recorded forge-test-102-1.scope "a unit still listed stays recorded"
scope forge-test-101-1.scope active 1min 10
tscan "a scan after forge-test-101-1.scope is listed again"
reported "a pruned unit listed again past its limit" "forge-test-101-1.scope running 10 min"
scope forge-test-114-1.scope active 1min 12
tscan "a scan whose notify fails" WD_NOTIFY_RC=1
[ "$(limits | wc -l)" = 1 ] || fail "a scan whose notify fails tries one alert for forge-test-114-1.scope: $(cat "$log")"
grep -qxF 'forge: cannot send the test-past-limit alert for forge-test-114-1.scope through forge notify' "$env_dir/err" ||
  fail "a failing test-past-limit alert prints 'forge: cannot send the test-past-limit alert for forge-test-114-1.scope through forge notify' on stderr: $(cat "$env_dir/err")"
unrecorded forge-test-114-1.scope "a failed alert"
tscan "the scan after a failed alert"
reported "the scan after a failed alert retries it" "forge-test-114-1.scope running 12 min"
recorded forge-test-114-1.scope "a retried alert"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'forge: test past limit' "$h" || fail "watchdog.txt documents the forge: test past limit alert"
grep -qF 'forge-test-' "$h" || fail "watchdog.txt names the forge-test-*.scope units the alert scans"
grep -qE 'RuntimeMax(U)?Sec' "$h" || fail "watchdog.txt documents the limit read from the scope's RuntimeMaxSec"
tpar=$(awk -v RS= '/test past limit|test-past-limit|forge-test-/' "$h")
grep -qw deactivating <<<"$tpar" || fail "watchdog.txt documents that deactivating scopes are reported"
grep -qF 'test-past-limit' "$h" || fail "watchdog.txt documents the test-past-limit state file"
grep -qF 'forge: cannot send the test-past-limit alert' "$h" || fail "watchdog.txt documents the stderr warning of a failed test-past-limit alert"
grep -qw failed <<<"$tpar" || fail "watchdog.txt says failed scopes are not reported, beside the test-past-limit alert"
ok test-past-limit
fi

if want snaps; then
setup snaps
mkdir -p "$WD_SCOPES"
sed -i 's/^  \*" show "\*RuntimeMaxUSec\*)$/  *" is-active "*)\n    [ ! -f "$WD_SCOPES\/$u.active" ] || { cat "$WD_SCOPES\/$u.active"; [ "$(cat "$WD_SCOPES\/$u.active")" = active ] \&\& exit 0 || exit 3; }\n    ;;\n&/' "$bin/systemctl"
grep -qF '"$WD_SCOPES/$u.active"' "$bin/systemctl" || fail "snaps: the stub systemctl answers is-active from \$WD_SCOPES/<unit>.active"
dead=$(($(cat /proc/sys/kernel/pid_max) + 7))
[ ! -d "/proc/$dead" ] || fail "snaps: pid $dead is not alive"
mkrepo() {
  mkdir -p "$1/.forge/phases"
  git init -q "$1"
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}
snapshot() {
  local m
  m=$(git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p')
  mkdir -p "$m/.claude/worktrees/_snap"
  git -C "$1" worktree add -q --detach "$m/.claude/worktrees/_snap/$2" HEAD
  echo "$m/.claude/worktrees/_snap/$2"
}
listed_wt() { git -C "$1" worktree list --porcelain | grep -qxF "worktree $2"; }
sscan() {
  local what=$1
  shift
  : >"$log"
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$@" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
    fail "$what: forge watchdog exits 0: $(cat "$env_dir/out" "$env_dir/err")"
}
ro=$HOME/Projects/a-ro
sr=$HOME/Projects/b-snap
plain=$HOME/Projects/c-plain
nogitr=$HOME/Projects/d-nogit
rr=$env_dir/rooted
mkrepo "$sr"
mkrepo "$plain"
mkrepo "$rr"
mkdir -p "$nogitr/.forge"
printf '%s\n' "$rr" >>"$HOME/.local/state/forge/watchdog-roots"
sr=$(cd "$sr" && pwd -P) rr=$(cd "$rr" && pwd -P)
s_dead=$(snapshot "$sr" "$dead")
s_live=$(snapshot "$sr" $$)
s_unit=$(snapshot "$sr" $((dead + 1)))
s_root=$(snapshot "$rr" $((dead + 2)))
st=$(git -C "$sr" rev-parse --path-format=absolute --git-common-dir)/forge-test
mkdir -p "$st/tmp"
echo forge-stack-777-1.service >"$st/tmp/$((dead + 1)).unit"
echo active >"$WD_SCOPES/forge-stack-777-1.service.active"
so=$st/snap-owner kf=k111111111111 kh=k222222222222
s_kfree=$(snapshot "$sr" "$kf")
s_kheld=$(snapshot "$sr" "$kh")
s_odd=$(snapshot "$sr" odd)
mkdir -p "$so" "$st/snap/$((dead + 6))" && echo "$sr/.git" >"$so/$kf" && : >"$so/$kf.lock" && echo "$sr/.git" >"$so/$kh" && : >"$so/$kh.lock" && echo s >"$so/$kh.deps"
exec {kfd}>>"$so/$kh.lock" && flock -n "$kfd" || fail "snaps: the test holds the lock $so/$kh.lock"
or=$HOME/Projects/e-owner
mkrepo "$or"
ost=$(git -C "$or" rev-parse --path-format=absolute --git-common-dir)/forge-test
mkdir -p "$ost/snap-owner" && echo gone >"$ost/snap-owner/$kf" && : >"$ost/snap-owner/$kf.lock"
sscan "a scan with dead, live and active-unit snapshots"
[ ! -e "$s_kfree" ] && ! listed_wt "$sr" "$s_kfree" && [ ! -e "$st/../worktrees/$kf" ] && [ ! -e "$so/$kf" ] && [ ! -e "$so/$kf.lock" ] || fail "snaps: one scan removes the k-keyed snapshot $s_kfree whose lock is free, its registration and its snap-owner record: $(git -C "$sr" worktree list) $(ls -A "$so" 2>&1)"
[ -d "$s_kheld" ] && listed_wt "$sr" "$s_kheld" && [ -f "$so/$kh.lock" ] && [ "$(cat "$so/$kh" 2>/dev/null)" = "$sr/.git" ] || fail "snaps: a k-keyed snapshot whose snap-owner lock is held is kept with snap-owner/: $(git -C "$sr" worktree list) $(ls -A "$so" 2>&1)"
[ ! -e "$s_odd" ] && ! listed_wt "$sr" "$s_odd" || fail "snaps: one scan removes a _snap entry that is neither a pid nor k-keyed: $(git -C "$sr" worktree list)"
[ ! -e "$st/snap" ] || fail "snaps: one scan removes the legacy forge-test/snap dir with its dead-pid snapshot: $(ls -A "$st/snap")"
[ ! -e "$ost/snap-owner" ] || fail "snaps: a scan removes forge-test/snap-owner of a repo that has no _snap dir: $(ls -A "$ost/snap-owner")"
[ ! -e "$s_dead" ] || fail "snaps: one scan removes the snapshot of dead pid $dead: $(cat "$env_dir/out" "$env_dir/err")"
! listed_wt "$sr" "$s_dead" || fail "snaps: one scan unregisters the dead pid's snapshot from git worktree list: $(git -C "$sr" worktree list)"
[ ! -e "$st/../worktrees/$dead" ] || fail "snaps: one scan removes the dead pid's git worktree admin dir"
[ ! -e "$s_root" ] && ! listed_wt "$rr" "$s_root" || fail "snaps: a scan prunes the dead snapshot of a repo listed in watchdog-roots: $(git -C "$rr" worktree list)"
[ -d "$s_live" ] && listed_wt "$sr" "$s_live" || fail "snaps: the snapshot of live pid \$\$ is kept and registered: $(git -C "$sr" worktree list)"
[ -d "$s_unit" ] && listed_wt "$sr" "$s_unit" || fail "snaps: a dead pid's snapshot whose stack unit is active is kept: $(git -C "$sr" worktree list)"
! grep -q 'forge-test\|snap' "$env_dir/out" "$env_dir/err" || fail "snaps: a scan that prunes cleanly prints nothing about snapshots: $(cat "$env_dir/out" "$env_dir/err")"
echo inactive >"$WD_SCOPES/forge-stack-777-1.service.active"
exec {kfd}>&-
sscan "a scan once the stack unit is inactive"
[ ! -e "$s_kheld" ] && ! listed_wt "$sr" "$s_kheld" && [ ! -e "$so" ] || fail "snaps: once its lock is free a scan removes the k-keyed snapshot $s_kheld and the whole snap-owner dir: $(git -C "$sr" worktree list) $(ls -A "$so" 2>&1)"
[ ! -e "$s_unit" ] && ! listed_wt "$sr" "$s_unit" || fail "snaps: a dead pid's snapshot is removed once its stack unit is inactive: $(git -C "$sr" worktree list)"
[ -d "$s_live" ] && listed_wt "$sr" "$s_live" || fail "snaps: the live pid's snapshot is still kept on a later scan"
s_gone=$(snapshot "$sr" $((dead + 3)))
mv "$agents" "$agents.off"
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1 && fail "snaps: a scan whose claude agents listing fails exits non-zero"
mv "$agents.off" "$agents"
[ ! -e "$s_gone" ] && ! listed_wt "$sr" "$s_gone" || fail "snaps: the snapshot prune runs before the claude agents listing, so a failing listing still prunes: $(cat "$env_dir/out")"
mkrepo "$ro"
ro=$(cd "$ro" && pwd -P)
s_ro=$(snapshot "$ro" "$dead")
s_after=$(snapshot "$sr" $((dead + 4)))
chmod a-w "${s_ro%/*}"
: >"$log"
rc=0
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" || rc=$?
chmod u+w "${s_ro%/*}"
[ "$rc" = 0 ] || fail "snaps: an unremovable snapshot does not fail forge watchdog, got $rc: $(cat "$env_dir/out" "$env_dir/err")"
grep -q "^forge: warning: .*$ro" "$env_dir/err" || fail "snaps: an unremovable snapshot prints a forge: warning: line naming the repo $ro on stderr: $(cat "$env_dir/err")"
[ ! -e "$s_after" ] && ! listed_wt "$sr" "$s_after" || fail "snaps: the scan goes on to the next repo after an unremovable snapshot: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "snaps: the stall scan goes on after an unremovable snapshot: $(cat "$log")"
s_hang=$(snapshot "$sr" $((dead + 5)))
echo forge-stack-777-2.service >"$st/tmp/$((dead + 5)).unit"
sed -i '2a [[ " $* " != *" is-active forge-stack-777-2.service "* ]] || sleep 30' "$bin/systemctl"
s=$SECONDS
sscan "a scan whose snapshot prune hangs" FORGE_SNAP_TIMEOUT=1
[ $((SECONDS - s)) -lt 20 ] || fail "snaps: forge watchdog bounds the snapshot prune at FORGE_SNAP_TIMEOUT seconds, took $((SECONDS - s))"
grep -q '^forge: warning: the forge test snapshot prune timed out after 1 s' "$env_dir/err" || fail "snaps: a hung snapshot prune prints a forge: warning: timed out line: $(cat "$env_dir/err")"
grep -q '^claude agents.*--json' "$log" || fail "snaps: the stall scan goes on after a hung snapshot prune: $(cat "$log")"
sed -i '3d' "$bin/systemctl"
rm -rf "$ro" "$sr" "$rr" "$or"
sscan "a scan of repos without .claude/worktrees/_snap"
[ ! -e "$plain/.claude/worktrees/_snap" ] || fail "snaps: a repo without .claude/worktrees/_snap gets no _snap dir"
[ ! -e "$(git -C "$plain" rev-parse --path-format=absolute --git-common-dir)/forge-test" ] || fail "snaps: a repo without .claude/worktrees/_snap gets no forge-test dir"
[ ! -e "$nogitr/.claude/worktrees/_snap" ] || fail "snaps: a .forge dir outside git gets no _snap dir"
[ ! -s "$env_dir/out" ] && [ ! -s "$env_dir/err" ] || fail "snaps: a git repo without .claude/worktrees/_snap and a .forge dir outside git add no output: $(cat "$env_dir/out" "$env_dir/err")"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF '.claude/worktrees/_snap' "$h" || fail "watchdog.txt documents the .claude/worktrees/_snap snapshots the scan prunes"
grep -qF 'forge-test/snap-owner/' "$h" && grep -qF 'forge-test/snap/' "$h" || fail "watchdog.txt names the forge-test/snap-owner/ and legacy forge-test/snap/ dirs the scan removes"
spar=$(awk -v RS= '/\.claude\/worktrees\/_snap|snapshot/' "$h")
grep -qw dead <<<"$spar" || fail "watchdog.txt says the scan removes snapshots of dead pids"
grep -qw live <<<"$spar" || fail "watchdog.txt says a live pid's snapshot is kept"
grep -qw active <<<"$spar" || fail "watchdog.txt says a snapshot whose stack unit is active is kept"
grep -qF 'git worktree' <<<"$spar" || fail "watchdog.txt says the scan unregisters the snapshot from git worktree"
grep -qF 'forge: warning:' <<<"$spar" || fail "watchdog.txt documents the forge: warning: line of an unremovable snapshot"
sflat=$(tr -s '\n ' '  ' <<<"$spar")
grep -qF '_snap/k' <<<"$sflat" || fail "watchdog.txt names the k-keyed .claude/worktrees/_snap/k<key> snapshot the scan prunes"
grep -qE 'whose lock .* still holds' <<<"$sflat" || fail "watchdog.txt says a k-keyed _snap snapshot whose lock is held is kept"
grep -qF 'every snapshot' <<<"$sflat" || fail "watchdog.txt says the scan removes every _snap snapshot but the kept ones"
! grep -qF 'no longer exists' <<<"$sflat" || fail "watchdog.txt drops the owning-worktree-gone rule"
ok snaps
fi

tout() { printf '%s/claude-%s/%s/%s/tasks/%s.output' "$CLAUDE_CODE_TMPDIR" "$(id -u)" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')" "$2" "$3"; }
output() {
  local f
  f=$(tout "$1" "$2" "$3")
  mkdir -p "${f%/*}"
  echo out >"$f"
  touch -d "$4 minutes ago" "$f"
}
agent_out() {
  local f t
  f=$(tout "$1" "$2" "$3") t=$CLAUDE_CODE_TMPDIR/agents/$2-$3.jsonl
  mkdir -p "${f%/*}" "${t%/*}"
  echo '{}' >"$t"
  touch -d "$4 minutes ago" "$t"
  ln -sfn "$t" "$f"
  touch -h -d "$5 minutes ago" "$f"
}
holds() {
  mkdir -p "$FORGE_PROC_ROOT/$1/fd"
  printf '%s\0' sleep 600 >"$FORGE_PROC_ROOT/$1/cmdline"
  ln -sfn "$2" "$FORGE_PROC_ROOT/$1/fd/3"
}

if want inflight; then
setup inflight
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 40
t7=$(pdir "$wt/$tf-07")/aaaaaaa7-0000-4000-8000-000000000007.jsonl
echo '{"type":"user","toolUseResult":{"status":"async_launched","agentId":"ag7"}}' >>"$t7"
touch -d "40 minutes ago" "$t7"
agent_out "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 ag7 2 40
session "proj P08 $tfs" working "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008
transcript "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 40
t8=$(pdir "$wt/$tf-08")/aaaaaaa8-0000-4000-8000-000000000008.jsonl
echo '{"type":"user","toolUseResult":{"backgroundTaskId":"bt8"}}' >>"$t8"
echo '{"type":"user","message":{"role":"user","content":"<task-notification><task-id>bt8</task-id><status>completed</status></task-notification>"}}' >>"$t8"
touch -d "40 minutes ago" "$t8"
run
quiet 07-alpha "a session whose background agent is still in flight is waiting on it, not idle"
grep -qxF "forge: proj P07 $tfs (aaaaaaa7-0000-4000-8000-000000000007) idle 40 min with background task ag7 in flight; no stall" "$env_dir/out" ||
  fail "the skipped stall of 07-alpha names its in-flight task: $(cat "$env_dir/out")"
stalled 08-beta "proj P08 $tfs" aaaaaaa8-0000-4000-8000-000000000008 40
session "proj P09 $tfs" working "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009
transcript "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 40
t9=$(pdir "$wt/$tf-09")/aaaaaaa9-0000-4000-8000-000000000009.jsonl
echo '{"type":"user","toolUseResult":{"status":"async_launched","agentId":"ag9"}}' >>"$t9"
echo '{"type":"user","message":{"role":"user","content":"<task-notification><task-id>ag9</task-id><status>completed</status><summary>Agent P09 T1 forge-implementer is waiting on its own background work; the result below may be interim</summary></task-notification>"}}' >>"$t9"
touch -d "40 minutes ago" "$t9"
agent_out "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 ag9 2 40
run
quiet 09-gamma "an implementer's interim notification (may be interim) does not count as its final report"
ok inflight
fi

age() {
  local f=$1 min=$2 t
  t=$(date -u -d "$min minutes ago" +%FT%TZ)
  jq -c --arg t "$t" '.time = $t' "$f" >"$f.new"
  mv "$f.new" "$f"
}
notified() {
  local p=$1 what=$2 last
  last=$(jq -cs 'map(select(.step == "stall")) | last' "$sd/phases/$p/events.jsonl")
  printf '%s\n' "$last" | grep -qi notified || fail "$what: the latest stall event of phases/$p is recorded as notified: $last"
}
plain() {
  local p=$1 what=$2 ev
  ev=$(jq -cs 'map(select(.step == "stall")) | .[]' "$sd/phases/$p/events.jsonl")
  ! printf '%s\n' "$ev" | grep -qi notified || fail "$what: no stall event of phases/$p is recorded as notified: $ev"
}
alerted() {
  local name=$1 sid=$2 min=$3 line
  line=$(grep '^notify-send ' "$log" | grep -F -e "$name" -e "$sid" || true)
  [ -n "$line" ] || fail "a repeat stall of $name within 30 min sends a notify-send alert naming it: $(cat "$log")"
  [ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "one alert for the repeat stall of $name: $line"
  printf '%s\n' "$line" | grep -qF proj || fail "the alert for $name names the project proj: $line"
  has_minutes "$line" "$min" || fail "the alert for $name gives $min idle minutes: $line"
  [ "$line" = "notify-send --|forge: repeat stall|proj: $name idle $min min" ] ||
    fail "the alert for $name goes through forge notify as notify-send -- 'forge: repeat stall' 'proj: $name idle $min min', got args: $line"
}
unalerted() {
  ! grep '^notify-send ' "$log" | grep -qF -e "$1" -e "$2" || fail "$3: no alert for $1: $(grep '^notify-send ' "$log")"
}

bgrec() {
  local f=$1 k=$2 i=$3 at=${4:-} r t=
  case $k in
    bash) r=$(jq -cn --arg i "$i" '{backgroundTaskId: $i}') ;;
    monitor) r=$(jq -cn --arg i "$i" '{taskId: $i, timeoutMs: 600000}') ;;
    agent) r=$(jq -cn --arg i "$i" '{status: "async_launched", agentId: $i}') ;;
  esac
  [ -z "$at" ] || t=$(date -u -d "$at minutes ago" +%FT%T.%3NZ)
  jq -cn --argjson r "$r" --arg t "$t" '{type: "user", toolUseResult: $r} + (if $t == "" then {} else {timestamp: $t} end)' >>"$f"
}
bgsession() {
  local n=$1 sid=$2 f s k i a
  shift 2
  wt=$root/.claude/worktrees
  session "proj P$n $tfs" working "$wt/$tf-$n" "$sid"
  transcript "$wt/$tf-$n" "$sid" 40
  f=$(pdir "$wt/$tf-$n")/$sid.jsonl
  for s in "$@"; do
    IFS=: read -r k i a <<<"$s"
    bgrec "$f" "$k" "$i" "$a"
    if [ "$k" = agent ]; then agent_out "$wt/$tf-$n" "$sid" "$i" 1 40; else output "$wt/$tf-$n" "$sid" "$i" 1; fi
  done
  touch -d "40 minutes ago" "$f"
}
bgscan() {
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$@" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
    fail "bg-ceiling: forge watchdog exits 0: $(cat "$env_dir/out" "$env_dir/err")"
}
bgheld() {
  local n=$1 p=$2 sid=$3 ids=$4 what=$5
  quiet "$p" "bg-ceiling: $what"
  grep -qxF "forge: proj P$n $tfs ($sid) idle 40 min with background task $ids in flight; no stall" "$env_dir/out" ||
    fail "bg-ceiling: $what prints 'forge: proj P$n $tfs ($sid) idle 40 min with background task $ids in flight; no stall': $(cat "$env_dir/out" "$env_dir/err")"
}
bgstall() {
  local n=$1 p=$2 sid=$3 what=$4 msg c
  shift 4
  stalled "$p" "proj P$n $tfs" "$sid" 40
  msg=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")
  [[ $msg == "proj P$n $tfs ($sid) idle 40 min; background task "* ]] ||
    fail "bg-ceiling: $what extends the idle-stall msg with '; background task <id> in flight <age> min past the <ceil> min ceiling': '$msg'"
  for c in "$@"; do
    [[ $msg == *"$c"* ]] || fail "bg-ceiling: $what names '$c' in its stall event: '$msg'"
  done
  ! grep -qF "($sid) idle 40 min with background task" "$env_dir/out" ||
    fail "bg-ceiling: $what is not reported as in flight once past the ceiling: $(cat "$env_dir/out")"
}

if want bg-ceiling; then
setup bg-ceiling
bgsession 07 aaaaaaa7-0000-4000-8000-000000000007 bash:bt7:130
bgsession 08 aaaaaaa8-0000-4000-8000-000000000008 bash:bt8:100
bgsession 09 aaaaaaa9-0000-4000-8000-000000000009 agent:ag9:150 monitor:bm9:125
bgsession 11 aaaaaa11-0000-4000-8000-000000000011 bash:bo11:130 bash:bu11:30
bgsession 12 aaaaaa12-0000-4000-8000-000000000012 bash:bn12
bgscan
bgstall 07 07-alpha aaaaaaa7-0000-4000-8000-000000000007 "a session whose only background Bash task launched 130 min ago" \
  "; background task bt7 in flight 130 min past the 120 min ceiling"
bgheld 08 08-beta aaaaaaa8-0000-4000-8000-000000000008 bt8 "a session whose background task launched 100 min ago, under the 120 min default ceiling, though its output is fresh"
bgstall 09 09-gamma aaaaaaa9-0000-4000-8000-000000000009 "a session whose Agent and Monitor tasks both launched past the ceiling" \
  "background task ag9 in flight 150 min past the 120 min ceiling" "background task bm9 in flight 125 min past the 120 min ceiling"
bgheld 11 11-eps aaaaaa11-0000-4000-8000-000000000011 bu11 "a session with one task past the ceiling and one under it keeps only the one under it in flight and"
bgheld 12 12-zeta aaaaaa12-0000-4000-8000-000000000012 bn12 "a session whose task record has no launch timestamp counts it under the ceiling and"
grep -F bn12 "$env_dir/err" | grep -q '^forge: ' ||
  fail "bg-ceiling: a task with no recoverable launch timestamp warns on stderr naming bn12: $(cat "$env_dir/err")"
! grep -qF FORGE_BG_CEIL_MIN "$env_dir/err" || fail "bg-ceiling: an unset FORGE_BG_CEIL_MIN warns nothing: $(cat "$env_dir/err")"
! grep -q '^claude stop' "$log" || fail "bg-ceiling: the watchdog never stops or kills a session over the ceiling: $(cat "$log")"
age "$sd/phases/07-alpha/events.jsonl" 10
: >"$log"
bgscan
[ "$(stalls 07-alpha)" = 2 ] || fail "bg-ceiling: a second scan of the over-ceiling session logs a repeat stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
a=$(grep '^notify-send ' "$log" | grep -F "proj P07 " || true)
[ "$a" = "notify-send --|forge: repeat stall|proj: proj P07 $tfs idle 40 min; background task bt7 in flight 130 min past the 120 min ceiling" ] ||
  fail "bg-ceiling: the repeat-stall alert of an over-ceiling session names the task bt7 and its age 130 min: $a"
notified 07-alpha "bg-ceiling: a repeat stall past the ceiling"
setup bg-ceiling-90
bgsession 07 aaaaaaa7-0000-4000-8000-000000000007 bash:bt7:100
bgsession 08 aaaaaaa8-0000-4000-8000-000000000008 bash:bt8:60
bgscan FORGE_BG_CEIL_MIN=90
bgstall 07 07-alpha aaaaaaa7-0000-4000-8000-000000000007 "FORGE_BG_CEIL_MIN=90 with a task launched 100 min ago" \
  "; background task bt7 in flight 100 min past the 90 min ceiling"
bgheld 08 08-beta aaaaaaa8-0000-4000-8000-000000000008 bt8 "FORGE_BG_CEIL_MIN=90 with a task launched 60 min ago"
! grep -qF FORGE_BG_CEIL_MIN "$env_dir/err" || fail "bg-ceiling: FORGE_BG_CEIL_MIN=90 warns nothing: $(cat "$env_dir/err")"
for v in 0 2h; do
  setup "bg-ceiling-bad-$v"
  bgsession 07 aaaaaaa7-0000-4000-8000-000000000007 bash:bt7:130
  bgsession 08 aaaaaaa8-0000-4000-8000-000000000008 bash:bt8:100
  bgscan FORGE_BG_CEIL_MIN="$v"
  grep -qxF "forge: FORGE_BG_CEIL_MIN=$v is not a positive integer; using 120" "$env_dir/err" ||
    fail "bg-ceiling: FORGE_BG_CEIL_MIN=$v prints 'forge: FORGE_BG_CEIL_MIN=$v is not a positive integer; using 120' on stderr: $(cat "$env_dir/err")"
  bgstall 07 07-alpha aaaaaaa7-0000-4000-8000-000000000007 "FORGE_BG_CEIL_MIN=$v falling back to 120 with a task launched 130 min ago" \
    "; background task bt7 in flight 130 min past the 120 min ceiling"
  bgheld 08 08-beta aaaaaaa8-0000-4000-8000-000000000008 bt8 "FORGE_BG_CEIL_MIN=$v falling back to 120 with a task launched 100 min ago"
done
ok bg-ceiling
fi

if want repeat; then
setup repeat
populate
run
nothing_else
plain 07-alpha "a first stall"
plain 09-gamma "a first stall"
fev=$sd/features/$tf/events.jsonl
[ -f "$fev" ] || fail "verify and ship stalls go to S/features/$tf/events.jsonl as documented"
! grep -qi notified "$fev" || fail "a first verify or ship stall is not recorded as notified: $(cat "$fev")"
age "$sd/phases/07-alpha/events.jsonl" 10
age "$sd/phases/09-gamma/events.jsonl" 45
age "$fev" 10
: >"$log"
run
[ "$(stalls 07-alpha)" = 2 ] || fail "a repeat stall of Phase 07 is logged as a stall event: $(cat "$sd/phases/07-alpha/events.jsonl")"
stalled_last=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/07-alpha/events.jsonl")
has_minutes "$stalled_last" 30 || fail "the repeat stall event of 07-alpha gives 30 idle minutes: '$stalled_last'"
notified 07-alpha "a stall 10 min after the previous one"
[ "$(jq -cs 'map(select(.step == "stall")) | first' "$sd/phases/07-alpha/events.jsonl" | grep -ci notified)" = 0 ] ||
  fail "the earlier stall of 07-alpha stays plain: $(cat "$sd/phases/07-alpha/events.jsonl")"
alerted "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
[ "$(stalls 09-gamma)" = 2 ] || fail "a stall 45 min after the previous one is still logged: $(cat "$sd/phases/09-gamma/events.jsonl")"
plain 09-gamma "a stall 45 min after the previous one is a plain stall"
unalerted "proj P09R1 $tfs" aaaaaaa9-0000-4000-8000-000000000009 "a stall 45 min after the previous one"
alerted "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
alerted "proj ship $tfs" dddddddd-0000-4000-8000-00000000000s 50
grep -F "proj verify $tfs" "$fev" | tail -1 | grep -qi notified || fail "the repeat Verify stall is recorded as notified in $fev: $(cat "$fev")"
unalerted "proj P08 $tfs" aaaaaaa8-0000-4000-8000-000000000008 "an active session"
alerted "proj P10 $tfs" aaaaaa10-0000-4000-8000-000000000010 90
[ -s "$WD_BUS" ] || fail "notify-send was run"
! grep -vxF "unix:path=$XDG_RUNTIME_DIR/bus" "$WD_BUS" || fail "notify-send runs over the user session bus unix:path=\$XDG_RUNTIME_DIR/bus when DBUS_SESSION_BUS_ADDRESS is unset"
grep -qF 'forge notify' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents that the repeat-stall alert goes through forge notify"
sed -n '/^Writes:/,/^$/p' "$repo/bin/forge.d/help/watchdog.txt" | grep -qF 'forge notify' || fail "watchdog.txt's Writes section names forge notify for the repeat-stall alert"
grep -Eq '30[ -]min' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the 30-minute repeat window"
: >"$log"
run
unalerted "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 "a session already alerted for its current idle stretch"
unalerted "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v "a session already alerted for its current idle stretch"
unalerted "proj ship $tfs" dddddddd-0000-4000-8000-00000000000s "a session already alerted for its current idle stretch"
[ "$(stalls 07-alpha)" = 2 ] || fail "a session already alerted for its current idle stretch logs no further stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
notified 07-alpha "the alerted stall stays the latest event"
age "$sd/phases/07-alpha/events.jsonl" 25
touch -d "21 minutes ago" "$(pdir "$wt/$tf-07")/aaaaaaa7-0000-4000-8000-000000000007.jsonl"
: >"$log"
run
alerted "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 21
setup repeat-fail
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
run
age "$sd/phases/07-alpha/events.jsonl" 10
: >"$log"
WD_NOTIFY_RC=1 run
alerted "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
[ "$(stalls 07-alpha)" = 2 ] || fail "a repeat stall whose alert fails is still logged: $(cat "$sd/phases/07-alpha/events.jsonl")"
plain 07-alpha "a repeat stall whose forge notify alert fails"
grep -q '^forge: warning: .*notify-send' "$env_dir/out" || fail "a failed repeat-stall alert prints forge notify's forge: warning: line naming notify-send: $(cat "$env_dir/out")"
ok repeat
fi

if want retry; then
setup retry
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
run
[ "$(stalls 07-alpha)" = 1 ] || fail "the Phase 07 session stall is logged"
age "$sd/phases/07-alpha/events.jsonl" 10
echo '[]' >"$agents"
session "proj P07R1 $tfs" working "$wt/$tf-07" eeeeeeee-0000-4000-8000-000000000007
transcript "$wt/$tf-07" eeeeeeee-0000-4000-8000-000000000007 25
: >"$log"
run
[ "$(stalls 07-alpha)" = 2 ] || fail "the retry session's stall is logged: $(cat "$sd/phases/07-alpha/events.jsonl")"
plain 07-alpha "the first stall of a retry session, 10 min after another session's stall"
[ -z "$(grep '^notify-send ' "$log")" ] || fail "another session's earlier stall does not make a repeat stall: $(cat "$log")"
ok retry
fi

if want nested; then
setup nested
root=$env_dir/Projects/host/.claude/worktrees/proj
state_at "$root"
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
session "proj verify $tfs" working "$wt/$tf" cccccccc-0000-4000-8000-00000000000v
transcript "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 45
session "proj ship $tfs" working "$root" dddddddd-0000-4000-8000-00000000000s
transcript "$root" dddddddd-0000-4000-8000-00000000000s 50
run
! grep -q skipping "$env_dir/out" || fail "sessions of a project that is itself a worktree are not skipped: $(cat "$env_dir/out")"
stalled 07-alpha "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
featured "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
featured "proj ship $tfs" dddddddd-0000-4000-8000-00000000000s 50
ok nested
fi

if want linked; then
setup linked
other=$env_dir/Projects/other
wt=$other/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30 "$root 07"
session "proj verify $tfs" working "$wt/$tf" cccccccc-0000-4000-8000-00000000000v
transcript "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 45 "$root tr/feat"
session "proj P08 $tfs" working "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008
transcript "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 30 "$env_dir/Projects/nope 08"
run
stalled 07-alpha "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
featured "proj verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
quiet 08-beta "a session whose launch prompt names no project proj"
grep -q "skipping proj P08 $tfs" "$env_dir/out" || fail "a linked session with no project found is skipped with a warning: $(cat "$env_dir/out")"
ok linked
fi

started() {
  jq -cn --arg t "$(date -u -d '1 hour ago' +%FT%TZ)" --arg m "$2" --arg s "${3:-}" \
    '{time: $t, step: "start", message: $m, offset: 70} + if $s == "" then {} else {session: $s} end' >>"$sd/phases/$1/events.jsonl"
}
if want ids; then
setup ids
wt=$root/.claude/worktrees
session "fix the parser" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
started 07-alpha "proj P07 $tfs" aaaaaaa7
session "renamed elsewhere" working "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008
transcript "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 30
started 08-beta "proj P08 $tfs" ffffffff
session "renamed unstarted" working "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012
transcript "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012 30
session "proj P09 $tfs" working "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009
transcript "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 30
started 09-gamma "proj P09 $tfs" eeeeeeee
session "proj P10 $tfs" working "$wt/$tf-10" aaaaaa10-0000-4000-8000-000000000010
transcript "$wt/$tf-10" aaaaaa10-0000-4000-8000-000000000010 30
started 10-delta "proj P10 $tfs" aaaaaa10
session "proj P11 $tfs" working "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011
transcript "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011 30
started 11-eps "proj P11 $tfs"
run
stalled 07-alpha "fix the parser" aaaaaaa7-0000-4000-8000-000000000007 30
quiet 08-beta "a renamed session whose phase's last start event records another session id"
quiet 12-zeta "a renamed session whose phase has no start event recording its id"
quiet 09-gamma "a parsed name whose phase's last start event records another session id"
stalled 10-delta "proj P10 $tfs" aaaaaa10-0000-4000-8000-000000000010 30
stalled 11-eps "proj P11 $tfs" aaaaaa11-0000-4000-8000-000000000011 30
nothing_else
setup ids-ws
ws=$env_dir/Projects/ws
root=$ws/proj
state_at "$root"
wt=$ws/.claude/worktrees
session "fix the parser" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
started 07-alpha "proj P07 $tfs" aaaaaaa7
ssub=$HOME/.local/state/forge/sub
mkdir -p "$root/sub/.forge/tracks" "$ssub/phases/08-other"
printf '%s\n' "$root/sub" >"$ssub/root"
session "renamed nested" working "$root/sub/.claude/worktrees/$tf-08" aaaaaaa8-0000-4000-8000-000000000008
transcript "$root/sub/.claude/worktrees/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 30
started 08-beta "proj P08 $tfs" aaaaaaa8
jq -cn '{time: "2026-01-01T00:00:00Z", step: "start", message: "sub P08", session: "ffffffff"}' >"$ssub/phases/08-other/events.jsonl"
run
stalled 07-alpha "fix the parser" aaaaaaa7-0000-4000-8000-000000000007 30
stalled 08-beta "renamed nested" aaaaaaa8-0000-4000-8000-000000000008 30
! grep -q stall "$ssub/phases/08-other/events.jsonl" || fail "a nearer phase 08 in the child root's state dir recording another session id gets no stall: $(cat "$ssub/phases/08-other/events.jsonl")"
[ ! -e "$root/sub/.forge/phases" ] && [ ! -e "$root/.forge/phases" ] || fail "the renamed-session search writes no record under a repo's .forge: $(find "$root" -path '*/.forge/*' -type f)"
grep -qiE 'session id|\.id\b' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents mapping a session to its phase by session id"
grep -qiE 'renam' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents that a renamed session is found by its session id"
ok ids
fi

turn_end() {
  local f
  f=$(pdir "$1")/$2.jsonl
  mkdir -p "${f%/*}" "$1"
  [ -f "$f" ] || echo '{}' >"$f"
  jq -cn --arg t "$(date -u -d "$3 minutes ago" +%FT%T.123Z)" '{type: "system", subtype: "turn_duration", durationMs: 1000, timestamp: $t}' >>"$f"
  touch -d "$3 minutes ago" "$f"
}
ended_at() { session "$1" done "$2" "$3"; turn_end "$2" "$3" "$4"; }
logged() {
  jq -cn --arg t "$(date -u -d '50 minutes ago' +%FT%TZ)" --arg s "$2" --arg m "$3" '{time: $t, step: $s, message: $m}' >>"$sd/phases/$1/events.jsonl"
}
pings() { grep '^notify-send ' "$log" | grep -cF 'turn ended with no result' || true; }
alerted_end() {
  local p=$1 sid=$2 msg n=${1%%-*}
  [ "$(ends "$p")" = 1 ] || fail "$3: one stall event 'turn ended with no result' in phases/$p/events.jsonl, got $(ends "$p"): $(cat "$sd/phases/$p/events.jsonl" 2>/dev/null)"
  msg=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")
  [[ $msg == *"($sid)"* ]] || fail "$3: the ended-turn stall names the session as ($sid): '$msg'"
  grep '^notify-send ' "$log" | grep -F 'turn ended with no result' | grep -F proj | grep -Eq "(^|[^0-9a-f-])0?${n#0}([^0-9]|\$)" ||
    fail "$3: forge notify alerts on the ended turn naming project proj and phase $n: $(grep '^notify-send ' "$log")"
}
if want ended; then
setup ended
wt=$root/.claude/worktrees
ended_at "proj P07 $tfs" "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
started 07-alpha "proj P07 $tfs" aaaaaaa7
ended_at "proj P08 $tfs" "$wt/$tf-08" aaaaaaa8-0000-4000-8000-000000000008 30
started 08-beta "proj P08 $tfs" aaaaaaa8
jq -n '{status: "done", summary: "s"}' >"$sd/phases/08-beta/result.json"
ended_at "proj P09 $tfs" "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 30
started 09-gamma "proj P09 $tfs" aaaaaaa9
logged 09-gamma park "ci green"
ended_at "proj P10 $tfs" "$wt/$tf-10" aaaaaa10-0000-4000-8000-000000000010 30
started 10-delta "proj P10 $tfs" aaaaaa10
logged 10-delta wait "dependency 07 merged"
session "proj P11 $tfs" working "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011
turn_end "$wt/$tf-11" aaaaaa11-0000-4000-8000-000000000011 30
started 11-eps "proj P11 $tfs" aaaaaa11
session "proj P12 $tfs" blocked "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012
turn_end "$wt/$tf-12" aaaaaa12-0000-4000-8000-000000000012 30
started 12-zeta "proj P12 $tfs" aaaaaa12
ended_at "fix the parser" "$wt/$tf-13" aaaaaa13-0000-4000-8000-000000000013 30
started 13-eta "proj P13 $tfs" aaaaaa13
ended_at "proj P14 $tfs" "$wt/$tf-14" aaaaaa14-0000-4000-8000-000000000014 30
started 14-theta "proj P14 $tfs" ffffffff
ended_at "proj P15 $tfs" "$wt/$tf-15" aaaaaa15-0000-4000-8000-000000000015 30
started 15-iota "proj P15 $tfs" aaaaaa15
logged 15-iota park "ci green"
logged 15-iota jev "site: resumed"
session "proj P16 $tfs" crashed "$wt/$tf-16" aaaaaa16-0000-4000-8000-000000000016
turn_end "$wt/$tf-16" aaaaaa16-0000-4000-8000-000000000016 30
started 16-kappa "proj P16 $tfs" aaaaaa16
mkdir -p "$sd/phases/17-lambda"
session "proj P17 $tfs" stopped "$wt/$tf-17" aaaaaa17-0000-4000-8000-000000000017
turn_end "$wt/$tf-17" aaaaaa17-0000-4000-8000-000000000017 30
started 17-lambda "proj P17 $tfs" aaaaaa17
mkdir -p "$sd/phases/18-mu"
session "proj P18 $tfs" done "$wt/$tf-18" aaaaaa18-0000-4000-8000-000000000018
mkdir -p "$(pdir "$wt/$tf-18")"
jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "Paused until 07 merges.\n\nresult: Phase 18 waits on 07"}]}}' >"$(pdir "$wt/$tf-18")/aaaaaa18-0000-4000-8000-000000000018.jsonl"
turn_end "$wt/$tf-18" aaaaaa18-0000-4000-8000-000000000018 30
started 18-mu "proj P18 $tfs" aaaaaa18
ended_at "proj verify $tfs" "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 30
ended_at "proj ship $tfs" "$root" dddddddd-0000-4000-8000-00000000000s 30
ended_at "proj $tf Verify" "$wt/$tf" cccccccc-0000-4000-8000-0000000000lv 30
ended_at "proj $tf Ship" "$root" dddddddd-0000-4000-8000-0000000000ls 30
jq 'map(if .state == "done" then del(.pid, .status) else . end | if (.sessionId | test("^(aaaaaaa7|aaaaaa13|aaaaaa15|cccccccc|dddddddd)-")) then .state = "stopped" else . end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
run
grep -q '^claude agents.*--all' "$log" || fail "the ended-turn scan lists sessions with claude agents --json --all: $(cat "$log")"
! grep -E '^(pgrep|ps) ' "$log" || fail "forge watchdog runs no pgrep/ps wait loop: $(cat "$log")"
alerted_end 07-alpha aaaaaaa7-0000-4000-8000-000000000007 "an ended phase session with no result"
[ "$(stalls 07-alpha)" = 1 ] || fail "an ended phase session logs exactly one stall event: $(cat "$sd/phases/07-alpha/events.jsonl")"
quiet 08-beta "an ended phase session whose phase has result.json"
quiet 09-gamma "an ended phase session whose last event is park"
quiet 10-delta "an ended phase session whose last event is wait"
quiet 18-mu "an ended phase session whose last reply ends result: Phase 18 waits on 07"
[ "$(ends 11-eps)" = 0 ] || fail "a working session is not scanned for an ended turn: $(cat "$sd/phases/11-eps/events.jsonl")"
stalled 12-zeta "proj P12 $tfs" aaaaaa12-0000-4000-8000-000000000012 30
alerted_end 13-eta aaaaaa13-0000-4000-8000-000000000013 "a renamed ended session found by its session id"
quiet 14-theta "an ended session whose parsed phase's last start event records another session id"
alerted_end 15-iota aaaaaa15-0000-4000-8000-000000000015 "an ended session whose park is not its last event"
alerted_end 16-kappa aaaaaa16-0000-4000-8000-000000000016 "a crashed phase session with no result"
alerted_end 17-lambda aaaaaa17-0000-4000-8000-000000000017 "a stopped phase session with no result"
fends() { [ ! -f "$sd/features/$tf/events.jsonl" ] && echo 0 || jq -s --arg s "($1) turn ended with no result" 'map(select(.step == "stall" and (.message | contains($s)))) | length' "$sd/features/$tf/events.jsonl"; }
for s in cccccccc-0000-4000-8000-00000000000v dddddddd-0000-4000-8000-00000000000s cccccccc-0000-4000-8000-0000000000lv dddddddd-0000-4000-8000-0000000000ls; do
  [ "$(fends "$s")" = 1 ] || fail "an ended Verify or Ship session ($s) with no verify.json and no newer ship.json logs one 'turn ended with no result' stall in features/$tf/events.jsonl: $(cat "$sd/features/$tf/events.jsonl" 2>/dev/null)"
done
[ "$(pings)" = 9 ] || fail "one forge notify alert per ended phase session (07, 13, 15, 16, 17) and per ended Verify or Ship session (4), got $(pings): $(grep '^notify-send ' "$log")"
: >"$log"
run
[ "$(ends 07-alpha)$(ends 13-eta)$(ends 15-iota)$(ends 16-kappa)$(ends 17-lambda)" = 11111 ] || fail "a second scan of the same turn end logs no stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(pings)" = 0 ] || fail "a second scan of the same turn end sends no alert: $(grep '^notify-send ' "$log")"
age "$sd/phases/07-alpha/events.jsonl" 28
: >"$log"
run
[ "$(ends 07-alpha)" = 1 ] && [ "$(pings)" = 0 ] || fail "a turn end alerted 28 min ago, before which the transcript last changed, is not alerted again: $(cat "$sd/phases/07-alpha/events.jsonl")"
turn_end "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 22
: >"$log"
run
[ "$(ends 07-alpha)" = 2 ] || fail "a later turn end (newer transcript mtime) logs a second ended-turn stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(pings)" = 1 ] || fail "a later turn end alerts once more through forge notify, got $(pings): $(grep '^notify-send ' "$log")"
age "$sd/phases/13-eta/events.jsonl" 28
turn_end "$wt/$tf-13" aaaaaa13-0000-4000-8000-000000000013 22
: >"$log"
WD_NOTIFY_RC=1 run
[ "$(ends 13-eta)" = 2 ] || fail "an ended-turn stall whose forge notify fails is still logged: $(cat "$sd/phases/13-eta/events.jsonl")"
grep -qiE 'warning|cannot' "$env_dir/out" || fail "a failed ended-turn alert warns: $(cat "$env_dir/out")"
grep -qF 'turn ended with no result' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the ended-turn stall 'turn ended with no result'"
grep -qF -- '--all' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents that the ended-turn scan reads claude agents --json --all"
ok ended
fi

stamp() { date -u -d "$1 minutes ago" +%FT%T.123Z; }
rec() { jq -cn "$@" >>"$tl"; }
said_ok() { rec --arg t "$(stamp "$1")" '{type: "assistant", timestamp: $t, message: {role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: "T2 is committed; waiting on T3."}], stop_reason: "end_turn"}}'; }
turn_done() { rec --arg t "$(stamp "$1")" '{type: "system", subtype: "turn_duration", durationMs: 1000, timestamp: $t}'; }
api_err() {
  rec --arg t "$(stamp "$1")" --arg e "$2" --arg x "$3" --argjson q "${4:-null}" \
    '{type: "assistant", timestamp: $t, isApiErrorMessage: true, error: $e, message: {role: "assistant", model: "<synthetic>", content: [{type: "text", text: $x}], stop_reason: "stop_sequence"}}
      + (if $e == "rate_limit" then {apiErrorStatus: 429} else {} end) + (if $q == null then {} else {quotaLimits: $q} end)'
}
human() { rec --arg t "$(stamp "$1")" --arg c "$2" '{type: "user", timestamp: $t, origin: {kind: "human"}, message: {role: "user", content: $c}}'; }
note_body() {
  printf '<task-notification>\n<task-id>%s</task-id>\n<output-file>/tmp/claude-1000/x/tasks/%s.output</output-file>\n%s</task-notification>' "$1" "$1" "$2"
}
task_note() { rec --arg t "$(stamp "$1")" --arg c "$(note_body "$2" "$3")" '{type: "user", timestamp: $t, origin: {kind: "task-notification"}, message: {role: "user", content: $c}}'; }
queued() { rec --arg t "$(stamp "$1")" --arg c "$(note_body "$2" "$3")" '{type: "queue-operation", operation: "enqueue", timestamp: $t, content: $c}'; }
restarted() {
  local b='<summary>Background agent "P34 T5 forge-implementer" was restarted after the previous session ended</summary>
<note>It had no completion record after the previous Claude Code process exited, and was automatically restarted from its saved transcript. It is running in the background again; its result will arrive as a separate task notification.</note>
'
  queued "$1" a386abb4fa9a13693 "$b"
  task_note "$1" a386abb4fa9a13693 "$b"
}
unfinished() {
  local b="<tool-use-id>toolu_01Vq7Hx3NpL2cRk9ZsYb4WmE</tool-use-id>
<status>stopped</status>
<summary>Background shell command didn't finish before the previous session ended</summary>
<note>No completion record was found for this task after the previous Claude Code process exited.</note>
"
  queued "$1" b7x2k9q1m "$b"
  task_note "$1" b7x2k9q1m "$b"
}
killed() { queued "$1" bggu4x6dz '<tool-use-id>toolu_01Mn1AWz1m4Sh57rrXSVwqdr</tool-use-id>
<status>killed</status>
<summary>Background command "Fly three-arm isolation series on laptop" was stopped</summary>
'; }
finished() {
  local b='<status>completed</status>
<summary>Agent "P34 T5 forge-implementer" finished</summary>
'
  queued "$1" a386abb4fa9a13693 "$b"
  task_note "$1" a386abb4fa9a13693 "$b"
}
completed() { task_note "$1" bvhjk2jcc '<tool-use-id>toolu_01Q33QtRKKquh4BNDeA71vdx</tool-use-id>
<status>completed</status>
<summary>Background command "Build base and phase arm" completed (exit code 0)</summary>
'; }
stop_row() {
  local p=$1 st=$2 k=${1%%-*} sid
  sid=aaaaaa$k-0000-4000-8000-0000000000$k
  session "proj P$k $tfs" "$st" "$wt/$tf-$k" "$sid"
  started "$p" "proj P$k $tfs" "aaaaaa$k"
  tl=$(pdir "$wt/$tf-$k")/$sid.jsonl
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  human 90 "/forge:run 1 proj tr/feat"
  said_ok 60
}
stopped_by() {
  local p=$1 cause=$2 k=${1%%-*} msg want
  want="proj P$k $tfs (aaaaaa$k-0000-4000-8000-0000000000$k) turn ended with no result: stopped by $cause"
  [ "$(ends "$p")" = 1 ] || fail "$3: one stall event 'turn ended with no result' in phases/$p/events.jsonl, got $(ends "$p"): $(cat "$sd/phases/$p/events.jsonl" 2>/dev/null)"
  msg=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")
  [ "$msg" = "$want" ] || fail "$3: the stall event reads '$want', got '$msg'"
  ! grep '^notify-send ' "$log" | grep -F 'forge: turn ended' | grep -qF "phase $p:" ||
    fail "$3: a classified stop sends no 'forge: turn ended' alert: $(grep '^notify-send ' "$log")"
}
plain_end() {
  local p=$1 k=${1%%-*} msg
  alerted_end "$p" "aaaaaa$k-0000-4000-8000-0000000000$k" "$2"
  msg=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")
  [ "$msg" = "proj P$k $tfs (aaaaaa$k-0000-4000-8000-0000000000$k) turn ended with no result" ] ||
    fail "$2: the stall event keeps today's text with no cause, got '$msg'"
}
if want stopped-cause; then
setup stopped-cause
wt=$root/.claude/worktrees
mkdir -p "$sd/phases/17-lambda"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/getent"
chmod +x "$bin/getent"
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
stop_row 07-alpha done
api_err 40 rate_limit "You've hit your weekly limit · resets Oct 6, 7am (America/New_York)" \
  "$(jq -cn --argjson r "$(($(date +%s) + 7200))" '{status: "rejected", resetsAt: $r, unifiedRateLimitFallbackAvailable: false, rateLimitType: "seven_day", overageStatus: "rejected", overageDisabledReason: "org_level_disabled", isUsingOverage: false}')"
api_err 39 rate_limit "You've hit your weekly limit · resets Oct 6, 7am (America/New_York)" \
  "$(jq -cn --argjson r "$(($(date +%s) + 7200))" '{status: "rejected", resetsAt: $r, rateLimitType: "seven_day"}')"
turn_done 39
stop_row 08-beta stopped
api_err 40 rate_limit "You've hit your session limit · resets 3:45pm (Asia/Tokyo)"
turn_done 40
stop_row 09-gamma failed
api_err 40 rate_limit "You've hit your monthly spend limit. Run /usage-credits to manage your limit and keep using Fable 5.1 or switch models to continue this chat."
turn_done 40
stop_row 10-delta stopped
api_err 40 server_error "API Error: Can't reach the API server at api.anthropic.com (EAI_AGAIN)"
turn_done 40
completed 35
stop_row 11-eps stopped
turn_done 60
restarted 5
stop_row 12-zeta stopped
turn_done 60
queued 55 bvhjk2jcc '<status>completed</status>
'
killed 30
stop_row 13-eta stopped
turn_done 60
killed 5
stop_row 14-theta stopped
turn_done 60
stop_row 15-iota stopped
api_err 40 server_error "Request timed out"
turn_done 40
human 30 "hold on, I'll pick this up myself"
stop_row 16-kappa crashed
turn_done 60
completed 20
stop_row 17-lambda stopped
turn_done 60
unfinished 5
for k in 07 08 09 10 11 12 13 14 15 16 17; do touch -d '3 minutes ago' "$(pdir "$wt/$tf-$k")"/aaaaaa$k-*.jsonl; done
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
run
stopped_by 07-alpha "usage limit" "a rate_limit error record with quotaLimits.resetsAt"
stopped_by 08-beta "usage limit" "a rate_limit error record whose text gives 'resets 3:45pm (Asia/Tokyo)'"
stopped_by 09-gamma "API error rate_limit" "a rate_limit error record with no resetsAt and no parseable reset text"
stopped_by 10-delta "API error server_error" "a server_error record followed only by a task-notification user record"
stopped_by 11-eps reboot "a 'was restarted after the previous session ended' record after boot"
stopped_by 12-zeta reboot "a killed task-notification before the current boot"
stopped_by 17-lambda reboot "a 'didn't finish before the previous session ended' record after boot"
plain_end 13-eta "a killed task-notification after the current boot"
plain_end 14-theta "a stopped row with no cause"
plain_end 15-iota "a server_error record followed by an operator user record"
plain_end 16-kappa "a crashed row whose last assistant record is no error"
[ "$(pings)" = 4 ] || fail "only the four unclassified stops (13, 14, 15, 16) send a 'forge: turn ended' alert, got $(pings): $(grep '^notify-send ' "$log")"
: >"$log"
run
for p in 07-alpha 08-beta 09-gamma 10-delta 11-eps 12-zeta 13-eta 14-theta 15-iota 16-kappa 17-lambda; do
  [ "$(ends "$p")" = 1 ] || fail "a second scan of the same turn end of $p logs no stall: $(cat "$sd/phases/$p/events.jsonl")"
done
[ "$(pings)" = 0 ] || fail "a second scan of the same turn ends sends no alert: $(grep '^notify-send ' "$log")"
ok stopped-cause
fi

asked() { rec --arg t "$(stamp "$1")" --arg x "$2" '{type: "assistant", timestamp: $t, message: {id: "msg_q\($t)", role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: $x}], stop_reason: "end_turn"}}'; }
questions() { { grep -F 'notify-send --|forge: question|' "$log" || true; } | sed 's/^notify-send --|forge: question|//' | { grep -F "$1" || true; }; }
asks() { questions "$1" | grep -c . || true; }
ended_pings() { { grep -F 'notify-send --|forge: turn ended|' "$log" || true; } | { grep -cF "phase $1:" || true; }; }
sends() { grep -c '^notify-send ' "$log" || true; }
stall_msg() { jq -rs 'map(select(.step == "stall")) | last | .message // ""' "$sd/phases/$1/events.jsonl"; }
if want question; then
setup question
wt=$root/.claude/worktrees
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
q7="Should I keep the old stall flag or drop it?"
stop_row 07-alpha done
asked 40 "T3 is committed and its tests pass.

$q7"
turn_done 40
q8="Should I rename the $(printf 'very %.0s' $(seq 60))long watchdog flag before T4 lands?"
stop_row 08-beta done
asked 40 "Both options build.

$q8"
turn_done 40
stop_row 09-gamma stopped
asked 40 "Should I keep the old flag?

No, I dropped it; T4 is committed."
turn_done 40
stop_row 10-delta blocked
asked 40 "Both options build.

Should I keep the old stall flag or drop it?"
for k in 07 08 09; do touch -d '3 minutes ago' "$(pdir "$wt/$tf-$k")"/aaaaaa$k-*.jsonl; done
touch -d '30 minutes ago' "$(pdir "$wt/$tf-10")"/aaaaaa10-*.jsonl
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
run
n7="proj P07 $tfs"
[ "$(asks "$n7:")" = 1 ] || fail "an ended done turn whose last paragraph ends in '?' sends one 'forge: question' notify, got $(asks "$n7:"): $(grep '^notify-send ' "$log"; cat "$env_dir/out")"
[ "$(questions "$n7:")" = "$n7: $q7" ] || fail "the question notify body is '<name>: <paragraph>', want '$n7: $q7', got '$(questions "$n7:")'"
[ "$(ended_pings 07-alpha)" = 0 ] || fail "a question turn sends 'forge: question' in place of 'forge: turn ended': $(grep '^notify-send ' "$log")"
[ "$(ends 07-alpha)" = 1 ] || fail "a question turn logs one ended-turn stall event: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(stall_msg 07-alpha)" = "$n7 (aaaaaa07-0000-4000-8000-000000000007) turn ended with no result; asked: $q7" ] ||
  fail "the question turn's stall event gains '; asked: <paragraph>', got '$(stall_msg 07-alpha)'"
n8="proj P08 $tfs"
b8=$(questions "$n8:")
[ "$(asks "$n8:")" = 1 ] || fail "a long question sends one 'forge: question' notify, got $(asks "$n8:"): $(grep '^notify-send ' "$log")"
[ "${#b8}" -le 200 ] || fail "a long question's notify body is cut to 200 characters, got ${#b8}: '$b8'"
[[ $b8 == "$n8: ${q8:0:100}"* ]] || fail "a long question's cut body starts '$n8: ${q8:0:100}', got '$b8'"
[ "$(ended_pings 08-beta)" = 0 ] || fail "a long question turn sends no 'forge: turn ended': $(grep '^notify-send ' "$log")"
[[ $(stall_msg 08-beta) == *"; asked: ${q8:0:100}"* ]] || fail "a long question turn's stall event gains '; asked: <paragraph>', got '$(stall_msg 08-beta)'"
[ "$(asks "proj P09 $tfs:")" = 0 ] || fail "a turn whose last paragraph has no '?' sends no 'forge: question': $(grep '^notify-send ' "$log")"
[ "$(ended_pings 09-gamma)" = 1 ] || fail "a turn whose last paragraph has no '?' sends one 'forge: turn ended', got $(ended_pings 09-gamma): $(grep '^notify-send ' "$log")"
[[ $(stall_msg 09-gamma) != *"; asked:"* ]] || fail "a turn whose last paragraph has no '?' logs no '; asked:' suffix: '$(stall_msg 09-gamma)'"
[ "$(asks "proj P10 $tfs:")" = 0 ] && [ "$(ended_pings 10-delta)" = 0 ] || fail "a blocked row ending in a question sends nothing: $(grep '^notify-send ' "$log")"
[ "$(sends)" = 3 ] || fail "one notify-send per event (questions 07 and 08, ended turn 09), got $(sends): $(grep '^notify-send ' "$log")"
: >"$log"
run
[ "$(sends)" = 0 ] || fail "a second scan of the same question and ended turns sends nothing, got $(sends): $(grep '^notify-send ' "$log")"
[ "$(ends 07-alpha)$(ends 08-beta)$(ends 09-gamma)" = 111 ] || fail "a second scan logs no further stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
grep -qF 'forge: question' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the 'forge: question' alert"
grep -qF '; asked:' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the '; asked: <paragraph>' stall suffix"
ok question
fi

fsid() { printf 'cccccc%s-0000-4000-8000-0000000000%s' "$1" "$1"; }
fdir() { printf '%s/features/tr-%s' "$sd" "$1"; }
fev() {
  local e
  e=$(fdir "$1")/events.jsonl
  [ -f "$e" ] || { echo 0; return; }
  jq -s --arg s "$2" 'map(select(.step == $s)) | length' "$e"
}
fmsg() { jq -rs --arg s "$2" 'map(select(.step == $s)) | last | .message' "$(fdir "$1")/events.jsonl"; }
fnotes() { grep '^notify-send ' "$log" | grep -F "tr/$1" || true; }
if want already-alerted; then
setup already-alerted
wt=$root/.claude/worktrees
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
tls=()
drow() {
  local k=$1 f=$2 cwd=$3 n=$4
  mkdir -p "$(fdir "$f")"
  session "proj $k tr/$f" done "$cwd" "$(fsid "$n")"
  tl=$(pdir "$cwd")/$(fsid "$n").jsonl
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  tls+=("$tl")
  human 90 "/forge-$k $root tr/$f"
}
used() {
  rec --arg t "$(stamp "$1")" --arg i "toolu_$2" --arg n "$3" --argjson x "$4" \
    '{type: "assistant", timestamp: $t, message: {id: "msg_\($i)", role: "assistant", model: "claude-opus-5-5", content: [{type: "tool_use", id: $i, name: $n, input: $x, caller: {type: "direct"}}], stop_reason: "tool_use"}}'
  rec --arg t "$(stamp "$1")" --arg i "toolu_$2" --arg r "$5" '{type: "user", timestamp: $t, message: {role: "user", content: [{tool_use_id: $i, type: "tool_result", content: $r, is_error: false}]}}'
}
bashed() { used "$1" "$2" Bash "$(jq -cn --arg c "$3" '{command: $c, description: "Send forge notification"}')" "(Bash completed with no output)"; }
deferred() {
  rec --arg t "$(stamp "$1")" '{type: "attachment", timestamp: $t, attachment: {type: "deferred_tools_record", entries: [{name: "PushNotification", description: "This tool sends a desktop notification in the user'"'"'s terminal.", defer_loading: true}]}}'
}
alerts() { fnotes "$1" | grep -cE '^notify-send --\|forge: (turn ended|question)\|' || true; }
drow verify nf "$wt/tr-nf" 41
bashed 50 nf 'forge notify "proj verify tr/nf" "Manual test walkthrough"'
task_note 48 bnf41aa1 '<status>completed</status>
<summary>Background command "Start the dev server" completed (exit code 0)</summary>
'
asked 45 "Step 1: open the board at http://localhost:5173.

Did the board load?"
turn_done 45
drow verify pn "$wt/tr-pn" 42
used 50 pn PushNotification '{"message": "proj verify tr/pn: Manual test walkthrough", "status": "proactive"}' "Push not sent — mobile push is disabled in /config."
asked 45 "Step 1: open the board at http://localhost:5173.

Did the board load?"
turn_done 45
drow verify old "$wt/tr-old" 43
bashed 80 old 'forge notify "proj verify tr/old" "Manual test walkthrough"'
asked 75 "Step 1: open the board.

Did the board load?"
turn_done 75
human 60 "It loaded; go on."
asked 50 "Step 2: export the board.

Did the CSV download?"
turn_done 50
drow ship dt "$root" 44
deferred 88
used 87 dt ToolSearch '{"query": "select:PushNotification", "max_results": 1}' "Loaded PushNotification"
asked 45 "The PR is open and CI is running.

Should I wait for CI before merging?"
turn_done 45
drow ship sa "$root" 45
bashed 50 sa "date +%s >\"\$CLAUDE_JOB_DIR/tmp/shown\"; FORGE_ROOT=$root forge notify \"proj ship tr/sa\" \"Release notes\""
asked 45 "The PR is open.

Should I merge it now?"
turn_done 45
drow verify gr "$wt/tr-gr" 46
bashed 50 gr1 "rg -n 'forge notify' skills/"
bashed 49 gr2 'grep -F "forge notify" bin/forge.d/help/watchdog.txt'
bashed 48 gr3 'echo "next: forge notify the operator"'
asked 45 "Step 1: open the board.

Did the board load?"
turn_done 45
stop_row 07-alpha done
turn_done 60
tl7=$tl
touch -d '3 minutes ago' "${tls[@]}" "$tl7"
chmod 000 "$tl7"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
run
for f in nf sa; do
  [ "$(fev "$f" stall)" = 1 ] || fail "a done turn of tr/$f that ran forge notify after the last user prompt logs one stall event: $(cat "$(fdir "$f")/events.jsonl" 2>/dev/null; cat "$env_dir/out")"
  [[ $(fmsg "$f" stall) == *") turn ended with no result"* ]] || fail "the stall event of the already-alerted tr/$f turn is an ended-turn stall, got '$(fmsg "$f" stall)'"
  [ -z "$(fnotes "$f")" ] || fail "a done turn of tr/$f that ran forge notify after the last user prompt sends no notify: $(grep '^notify-send ' "$log")"
done
[ "$(alerts pn)" = 1 ] && [ "$(fnotes pn | grep -c .)" = 1 ] ||
  fail "a done Verify turn that only called PushNotification gets exactly one 'forge: turn ended' or 'forge: question' notify: $(grep '^notify-send ' "$log"; cat "$env_dir/out")"
[ "$(fev pn stall)" = 1 ] || fail "a done Verify turn that only called PushNotification logs one stall event: $(cat "$(fdir pn)/events.jsonl" 2>/dev/null)"
[ "$(alerts old)" = 1 ] && [ "$(fnotes old | grep -c .)" = 1 ] ||
  fail "a forge notify before the last user prompt does not suppress the ended-turn alert: $(grep '^notify-send ' "$log"; cat "$env_dir/out")"
[ "$(alerts dt)" = 1 ] && [ "$(fnotes dt | grep -c .)" = 1 ] ||
  fail "a deferred_tools_record or ToolSearch mention of PushNotification does not suppress the ended-turn alert: $(grep '^notify-send ' "$log"; cat "$env_dir/out")"
[ "$(alerts gr)" = 1 ] && [ "$(fnotes gr | grep -c .)" = 1 ] ||
  fail "a Bash command that greps, rg-searches or echoes the string 'forge notify' does not suppress the ended-turn alert: $(grep '^notify-send ' "$log"; cat "$env_dir/out")"
grep -qxF "forge: cannot read $tl7; alerting on its ended turn" "$env_dir/out" ||
  fail "an unreadable transcript prints 'forge: cannot read $tl7; alerting on its ended turn': $(cat "$env_dir/out")"
[ "$(ended_pings 07-alpha)" = 1 ] && [ "$(grep '^notify-send ' "$log" | grep -cF "proj P07 $tfs")" = 1 ] ||
  fail "an unreadable transcript alerts once on its ended turn: $(grep '^notify-send ' "$log")"
[ "$(ends 07-alpha)" = 1 ] || fail "an unreadable transcript logs one ended-turn stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(sends)" = 5 ] || fail "one notify-send per alerted event (tr/pn, tr/old, tr/dt, tr/gr, 07-alpha) and none for tr/nf and tr/sa, got $(sends): $(grep '^notify-send ' "$log")"
: >"$log"
run
[ "$(sends)" = 0 ] || fail "a second scan of the same ended turns sends nothing, got $(sends): $(grep '^notify-send ' "$log")"
[ "$(fev nf stall)$(fev sa stall)$(fev pn stall)$(fev old stall)$(fev dt stall)$(fev gr stall)$(ends 07-alpha)" = 1111111 ] ||
  fail "a second scan logs no further stall: $(cat "$(fdir nf)/events.jsonl" "$(fdir sa)/events.jsonl")"
chmod 600 "$tl7"
! grep -qF 'never a Verify or Ship session' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt no longer says the ended-turn scan skips Verify and Ship sessions"
grep -qiE 'last (real )?user prompt' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the skip of a turn that ran forge notify after the last user prompt"
ok already-alerted
fi

lsj='{"env":{"CLAUDE_CODE_FORK_SUBAGENT":"0"},"disableBundledSkills":true,"skillListingBudgetFraction":0.0001,"worktree":{"bgIsolation":"none","baseRef":"head"}}'
resume_stubs() {
  cat >"$bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$WD_LOG"
lk=$XDG_RUNTIME_DIR/forge/sessions.lock
held() { if [ -e "$lk" ] && ! flock -n "$lk" true; then echo held; else echo free; fi; }
case ${1:-} in
  agents)
    case " $* " in
      *" --all "*) cat "$WD_AGENTS" ;;
      *) jq '[.[] | select(.pid != null or .state == "working" or .state == "blocked")]' "$WD_AGENTS" ;;
    esac ;;
  stop)
    printf 'stop %s %s %s\n' "$2" "$PWD" "$(held)" >>"$WD_ACTS"
    if ! grep -qxF "$2" "$WD_KEEP"; then
      jq --arg i "$2" 'map(if .id == $i or .sessionId == $i then del(.pid) | .state = "stopped" else . end)' "$WD_AGENTS" >"$WD_AGENTS.new"
      mv "$WD_AGENTS.new" "$WD_AGENTS"
    fi
    if grep -qxF "$2" "$WD_STOPFAIL"; then echo "couldn't confirm $2 was stopped — the background service may be restarting. Try again in a moment." >&2; exit 1; fi
    echo "stopped $2" ;;
  --bg)
    s=
    for ((i = 1; i < $#; i++)); do [ "${!i}" != --resume ] || { j=$((i + 1)); s=${!j}; }; done
    fds=closed
    [ ! -e "/proc/$$/fd/6" ] && [ ! -e "/proc/$$/fd/9" ] || fds=open
    [ -z "${WD_STDIN:-}" ] || cat >>"$WD_STDIN"
    [ -z "${WD_PATH:-}" ] || printf '%s\n' "$PATH" >>"$WD_PATH"
    printf 'resume %s %s\n' "$s" "$PWD" >>"$WD_ACTS"
    jq -cn --arg c "$PWD" --arg l "$(held)" --arg f "$fds" '{cwd: $c, lock: $l, fds: $f, args: $ARGS.positional}' --args -- "$@" >>"$WD_RESUMES"
    if [ -z "$s" ] || grep -qxF "$s" "$WD_FAIL"; then echo "Error: cannot resume $s" >&2; exit 1; fi
    n=$(awk -v s="$s" '$1 == s {print $2; exit}' "${WD_FORK:-/dev/null}")
    if [ -n "$n" ]; then
      jq --arg s "$s" --arg n "$n" --arg c "$PWD" --argjson t "$(date +%s%3N)" '(first(.[] | select(.sessionId == $s)) | .name) as $m
        | map(if .sessionId == $s then .pid = 1 | .state = "working" else . end)
        + [{pid: 2, id: ($n | .[0:8]), kind: "background", startedAt: $t, name: $m, status: "busy", state: "working", cwd: $c, sessionId: $n}]' "$WD_AGENTS" >"$WD_AGENTS.new"
      mv "$WD_AGENTS.new" "$WD_AGENTS"
    elif grep -qxF "$s" "${WD_QUIET:-/dev/null}" && ! grep -qxF "$s" "${WD_LOST:-/dev/null}"; then
      jq --arg s "$s" 'map(if .sessionId == $s then .pid = 1 | .state = "working" else . end)' "$WD_AGENTS" >"$WD_AGENTS.new"
      mv "$WD_AGENTS.new" "$WD_AGENTS"
    fi
    if grep -qxF "$s" "${WD_QUIET:-/dev/null}"; then echo "resuming in the background"; exit 0; fi
    b=${n:-$s}
    echo "backgrounded · ${b:0:8} · resumed" ;;
  *) exit 1 ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "${WD_NPROC:-4}"\n' >"$bin/nproc"
  chmod +x "$bin/claude" "$bin/nproc"
}
gc() { git -C "$1" -c user.name=t -c user.email=t@t commit -q "${@:2}"; }
landed() {
  local p c
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  [ -d "$root/.git" ] || { git -C "$root" init -q && gc "$root" --allow-empty -m init; }
  git -C "$root" rev-parse -q --verify "forge/$tf" >/dev/null || git -C "$root" branch "forge/$tf" HEAD
  for p; do
    mkdir -p "$sd/phases/$p"
    jq -n --arg n "${p%%-*}" --arg s "${p#*-}" '{track: "tr", feature: "feat", number: $n, slug: $s, goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/$p/spec.json"
    jq -n '{status: "done", summary: "s"}' >"$sd/phases/$p/result.json"
    c=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "forge/$tf" -m "p${p%%-*}" "forge/$tf^{tree}")
    git -C "$root" branch -f "forge/$tf-${p%%-*}" "$c"
    c=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "forge/$tf" -p "$c" -m "Merge branch 'forge/$tf-${p%%-*}'" "forge/$tf^{tree}")
    git -C "$root" branch -f "forge/$tf" "$c"
  done
}
sidn() { printf 'aaaaaa%s-0000-4000-8000-0000000000%s' "$1" "$1"; }
begun() {
  jq -cn --arg t "$(date -u -d '2 hours ago' +%FT%TZ)" --arg m "$2" --arg s "$3" --argjson o "$4" \
    '{time: $t, step: "start", message: $m, offset: $o, session: $s}' >>"$sd/phases/$1/events.jsonl"
}
parked() {
  local p=$1 n=${1%%-*} s
  s=$(sidn "$n")
  ended_at "$2" "$wt/$tf-$n" "$s" 30
  jq --arg s "$s" --arg st "$3" 'map(if .sessionId == $s then .state = $st else . end)' "$agents" >"$agents.new"
  mv "$agents.new" "$agents"
  begun "$p" "$6" "aaaaaa$n" "$5"
  logged "$p" park "$4"
}
nopid() {
  jq --arg i "aaaaaa$1" 'map(if .id == $i then del(.pid) else . end)' "$agents" >"$agents.new"
  mv "$agents.new" "$agents"
}
job() {
  mkdir -p "$HOME/.claude/jobs/aaaaaa$1"
  printf '%s\n' "$2" >"$HOME/.claude/jobs/aaaaaa$1/state.json"
}
idle='{"state":"done","inFlight":{"tasks":0,"queued":0,"kinds":[],"drainableMonitors":0}}'
fx=$repo/tests/fixtures/watchdog
proc() {
  local p=$1 q=$2 t=$3
  shift 3
  mkdir -p "$FORGE_PROC_ROOT/$p/task/$p"
  : >>"$FORGE_PROC_ROOT/$p/task/$p/children"
  printf '%s\0' "$@" >"$FORGE_PROC_ROOT/$p/cmdline"
  [ "$q" = - ] || { mkdir -p "$FORGE_PROC_ROOT/$q/task/$t"; printf '%s ' "$p" >>"$FORGE_PROC_ROOT/$q/task/$t/children"; }
}
rowpid() {
  local p=$((1000 + 10#$1))
  jq --arg i "aaaaaa$1" --argjson p "$p" 'map(if .id == $i then .pid = $p else . end)' "$agents" >"$agents.new"
  mv "$agents.new" "$agents"
  proc "$p" - - /home/u/.local/share/claude/versions/2.1.293 --bg-pty-host
}
tlog() { printf '%s/%s.jsonl' "$(pdir "$wt/$tf-$1")" "$(sidn "$1")"; }
starts() {
  local n=$1 i x t
  shift
  t=$(date -u -d '30 minutes ago' +%FT%T.%3NZ)
  for i; do
    x=$(jq -c --arg i "$i" --arg t "$t" 'select(.toolUseResult | objects | any(.backgroundTaskId, .taskId, (select(.status == "async_launched") | .agentId); . == $i)) | .timestamp = $t' "$fx/starts.jsonl")
    [ -n "$x" ] || fail "tests/fixtures/watchdog/starts.jsonl holds a start of $i"
    printf '%s\n' "$x" >>"$(tlog "$n")"
  done
  touch -d "30 minutes ago" "$(tlog "$n")"
}
notes() {
  local n=$1 k=$2 i x
  shift 2
  for i; do
    x=$(jq -c --arg i "$i" --arg k "$k" 'select((.content // .message.content) | strings | startswith("<task-notification>") and contains("<task-id>\($i)</task-id>") and (contains("<status>") == ($k == "status")))' "$fx/notifications.jsonl")
    [ -n "$x" ] || fail "tests/fixtures/watchdog/notifications.jsonl holds a $k notification of $i"
    printf '%s\n' "$x" >>"$(tlog "$n")"
  done
  touch -d "30 minutes ago" "$(tlog "$n")"
}
snap="source /home/u/.claude/shell-snapshots/snapshot-bash-1759900000000-abc123.sh 2>/dev/null || true && shopt -u extglob 2>/dev/null || true && eval 'sleep 600' < /dev/null && pwd -P >| /tmp/claude-1a2b-cwd"
py="python3 -c 'import time; time.sleep(120)'"
penv() {
  local p=$1
  shift
  printf '%s\0' "$@" >"$FORGE_PROC_ROOT/$p/environ"
}
inflight() {
  grep -qxF "forge: proj P$1 $tfs ($(sidn "$1")) has $2 in flight; not stopping it" "$env_dir/out" ||
    fail "$3: phase $1 stays parked with 'forge: proj P$1 $tfs ($(sidn "$1")) has $2 in flight; not stopping it': $(cat "$env_dir/out")"
}
phases_r=(07-alpha 08-beta 09-gamma 10-delta 11-eps 12-zeta 13-eta 14-theta 15-iota 16-kappa 17-lambda 18-mu 19-nu 20-xi 21-omicron 22-pi 23-rho)
resumes() { jq -s 'map(select(.step == "resume")) | length' "$sd/phases/$1/events.jsonl"; }
stops() { grep -c "^stop aaaaaa$1 " "$WD_ACTS" || true; }
tries() { grep -c "^resume $(sidn "$1") " "$WD_ACTS" || true; }
untouched() {
  [ "$(stops "${1%%-*}")$(tries "${1%%-*}")" = 00 ] || fail "$2: phase $1 is neither stopped nor resumed: $(cat "$WD_ACTS")"
  [ "$(resumes "$1")" = 0 ] || fail "$2: phase $1 logs no resume event: $(cat "$sd/phases/$1/events.jsonl")"
}
named() {
  local n=${1%%-*}
  grep -qF -e "proj P$n $tfs" -e "$(sidn "$n")" -e "aaaaaa$n" "$env_dir/out" || fail "$2: phase $1 is skipped with a warning naming its session: $(cat "$env_dir/out")"
}
woke() {
  local p=$1 cond=$2 n=${1%%-*} s got msg nm
  s=$(sidn "$n")
  nm=$(jq -r --arg s "$s" 'first(.[] | select(.sessionId == $s) | .name)' "$agents")
  got=$(jq -c --arg s "$s" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
  [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "phase $p is resumed once with claude --bg --resume $s: $(cat "$WD_RESUMES" "$env_dir/out")"
  printf '%s\n' "$got" | jq -e --arg c "$wt/$tf-$n" --arg s "$s" --arg nm "$nm" --arg pr "forge watchdog: $cond cleared; continue phase $n from where it parked" --arg ls "$lsj" '
    .cwd == $c and .lock == "held" and .fds == "closed" and .args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, $pr]' >/dev/null ||
    fail "phase $p resumes from $wt/$tf-$n under sessions.lock with fds 6 and 9 closed, as exactly claude --bg --resume $s -n '$nm' 'forge watchdog: $cond cleared; continue phase $n from where it parked', got $got"
  [ "$(resumes "$p")" = 1 ] || fail "phase $p logs one resume event: $(cat "$sd/phases/$p/events.jsonl")"
  msg=$(jq -rs 'map(select(.step == "resume")) | last | .message' "$sd/phases/$p/events.jsonl")
  [[ $msg == *"$cond"* && $msg == *"claude --bg --resume $s"* ]] || fail "the resume event of $p names $cond and claude --bg --resume $s: '$msg'"
}
stopped_first() {
  local n=${1%%-*} a b
  a=$(grep -n "^stop aaaaaa$n " "$WD_ACTS" | tail -1 | cut -d: -f1)
  b=$(grep -n "^resume $(sidn "$n") " "$WD_ACTS" | tail -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "phase $1's session is stopped with claude stop aaaaaa$n before its resume: $(cat "$WD_ACTS")"
  grep "^stop aaaaaa$n " "$WD_ACTS" | grep -q ' held$' || fail "claude stop aaaaaa$n runs under sessions.lock: $(cat "$WD_ACTS")"
}
if want resume; then
setup resume
wt=$root/.claude/worktrees
mkdir -p "$sd/phases/17-lambda" "$sd/phases/18-mu" "$sd/phases/19-nu" "$sd/phases/20-xi" "$sd/phases/21-omicron" "$sd/phases/22-pi" "$sd/phases/23-rho"
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
: >"$WD_ACTS"
: >"$WD_RESUMES"
: >"$WD_KEEP"
: >"$WD_STOPFAIL"
: >"$WD_FAIL"
resume_stubs
begun 07-alpha "proj P07 $tfs" ffffffff 30
parked 07-alpha "proj P07R1 $tfs" done "wait 05" 31 "proj P07R1 $tfs"
job 07 '{"state":"done","inFlight":{"tasks":3,"queued":1,"kinds":["local_agent","session_cron"],"drainableMonitors":0}}'
parked 08-beta "fix the parser" stopped "wait 06" 32 "proj P08 $tfs"
nopid 08
parked 09-gamma "proj P09 $tfs" working "wait 05" 33 "proj P09 $tfs"
job 09 "$idle"
parked 10-delta "proj P10 $tfs" blocked "wait 05" 34 "proj P10 $tfs"
job 10 "$idle"
parked 11-eps "proj P11 $tfs" done "wait 05" 35 "proj P11 $tfs"
job 11 '{"state":"done","inFlight":{"tasks":1,"queued":0,"kinds":["local_agent"],"drainableMonitors":0}}'
parked 12-zeta "proj P12 $tfs" done "wait 05" 36 "proj P12 $tfs"
job 12 '{"state":"done","inFlight":{"tasks":2,"queued":0,"kinds":["monitor"],"drainableMonitors":2}}'
echo aaaaaa12 >>"$WD_STOPFAIL"
parked 13-eta "proj P13 $tfs" done "wait 05" 37 "proj P13 $tfs"
job 13 '{"state":"done","inFlight":{"tasks":0,"queued":1,"kinds":[],"drainableMonitors":0}}'
parked 14-theta "proj P14 $tfs" done "wait 05" 38 "proj P14 $tfs"
job 14 '{"state":"done","inFlight":{"tasks":1,"queued":0,"kinds":["monitor","session_cron"],"drainableMonitors":1}}'
parked 15-iota "proj P15 $tfs" done "wait 05" 39 "proj P15 $tfs"
parked 16-kappa "proj P16 $tfs" done "wait 05" 40 "proj P16 $tfs"
job 16 '{"state":"done","inFlight":{"tasks":2,"queued":0,"kinds":["local_bash"],"drainableMonitors":0}}'
echo aaaaaa16 >>"$WD_KEEP"
parked 17-lambda "proj P17 $tfs" done "wait 05" 41 "proj P17 $tfs"
job 17 '{"state":'
parked 18-mu "proj P18 $tfs" stopped "wait 05" 42 "proj P18 $tfs"
nopid 18
rm -rf "${wt:?}/$tf-18"
parked 19-nu "proj P19 $tfs" stopped "wait 05" 43 "proj P19 $tfs"
nopid 19
sidn 19 >>"$WD_FAIL"
echo >>"$WD_FAIL"
parked 20-xi "proj P20 $tfs" crashed "wait 05" 44 "proj P20 $tfs"
nopid 20
parked 21-omicron "proj P21 $tfs" done "wait 05" 45 "proj P21 $tfs"
parked 22-pi "proj P22 $tfs" done "wait 05" 46 "proj P22 $tfs"
parked 23-rho "proj P23 $tfs" done "wait 05" 47 "proj P23 $tfs"
for n in 07 09 10 11 12 13 14 15 16 17 21 22 23; do rowpid "$n"; done
proc 2071 1007 1007 node /home/u/.local/share/forge/jbc/server.mjs
proc 2072 2071 2071 node /home/u/.npm/_npx/1/node_modules/.bin/playwright-mcp --cdp-endpoint http://127.0.0.1:9222
proc 2073 1007 1007 python /home/u/.local/bin/serena start-mcp-server --context claude-code
proc 2074 1007 1007 /home/u/.cargo/bin/cargo build --release
proc 2075 2074 2074 /home/u/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin/rustc --crate-name engine --edition=2021 src/lib.rs
proc 2076 1007 1007 python3 scripts/gen_shaders.py
starts 07 a8b1f24ca4c579fc5 a386abb4fa9a13693 bzui28sfr bjqeokjtb bp67hm9zt
jq -ce 'select(.toolUseResult.success and .toolUseResult.taskId == "1")' "$fx/tasklist.jsonl" >>"$(tlog 07)" || fail "tests/fixtures/watchdog/tasklist.jsonl holds a TaskUpdate result of task 1"
notes 07 restart a386abb4fa9a13693
notes 07 status a8b1f24ca4c579fc5 a386abb4fa9a13693 bzui28sfr bjqeokjtb bp67hm9zt
proc 2111 1011 1011 node /home/u/.local/share/forge/jbc/server.mjs
proc 2112 1011 5011 /bin/bash -c "$snap"
proc 2113 2112 2112 timeout 30 tail -f /dev/null
proc 2131 1013 1013 /home/u/.local/share/claude/versions/2.1.293 bg-spare
proc 2132 2131 2131 /bin/bash -c "$snap"
starts 14 bjqeokjtb bzui28sfr
notes 14 status bjqeokjtb
starts 15 a386abb4fa9a13693
notes 15 restart a386abb4fa9a13693
starts 17 a8b1f24ca4c579fc5 bp67hm9zt
notes 17 status a8b1f24ca4c579fc5
starts 21 a386abb4fa9a13693
notes 21 status a386abb4fa9a13693
notes 21 restart a386abb4fa9a13693
proc 2221 1022 1022 /bin/bash -c "${snap/sleep 600/cargo build --release}"
proc 2222 2221 2221 /home/u/.cargo/bin/cargo build --release
proc 2223 2222 2222 /home/u/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin/rustc --crate-name engine --edition=2021 src/lib.rs
proc 2224 2221 2221 python3 scripts/gen_shaders.py
proc 2231 1023 1023 /home/u/.local/share/uv/tools/serena-agent/bin/python /home/u/.local/bin/serena start-mcp-server --context claude-code --project-from-cwd --mode no-memories
proc 2232 1023 1023 node /home/u/.local/share/forge/jbc/server.mjs
proc 2233 1023 1023 "npm exec @playwright/mcp@0.0.82 --cdp-endpoint http://127.0.0.1:9222"
proc 2234 2233 2233 node /home/u/.npm/_npx/53b5ca06f5b71ebd/node_modules/.bin/playwright-mcp --cdp-endpoint http://127.0.0.1:9222
proc 2235 1023 1023 /bin/bash -c "${snap/sleep 600/$py}"
proc 2236 2235 2235 python3 -c 'import time; time.sleep(120)'
proc 2241 - - /bin/bash -c "$snap"
penv 2241 HOME=/home/u "CLAUDE_CODE_SESSION_ID=$(sidn 20)" CLAUDECODE=1
proc 2242 2241 2241 sleep 600
proc 2243 - - python /home/u/.local/bin/serena start-mcp-server --context claude-code
penv 2243 "CLAUDE_CODE_SESSION_ID=$(sidn 08)"
proc 2244 - - /bin/bash -c "$snap"
penv 2244 "CLAUDE_CODE_SESSION_ID=$(sidn 19)0" "X_SESSION=CLAUDE_CODE_SESSION_ID=$(sidn 08)"
output "$wt/$tf-14" "$(sidn 14)" bzui28sfr 30
holds 2141 "$(tout "$wt/$tf-14" "$(sidn 14)" bzui28sfr)"
agent_out "$wt/$tf-15" "$(sidn 15)" a386abb4fa9a13693 1 30
output "$wt/$tf-17" "$(sidn 17)" bp67hm9zt 2
agent_out "$wt/$tf-21" "$(sidn 21)" a386abb4fa9a13693 1 1

landed
run
[ ! -s "$WD_ACTS" ] || fail "with neither phase 05 nor phase 06 landed nothing is stopped or resumed: $(cat "$WD_ACTS")"
for p in "${phases_r[@]}"; do [ "$(resumes "$p")" = 0 ] || fail "no condition cleared, yet $p logs a resume event: $(cat "$sd/phases/$p/events.jsonl")"; done

landed 05-pre
: >"$log"
run
[ "$(stops 07)$(tries 07)" = 11 ] || fail "phase 07, whose session's descendants are MCP servers (node, python) and cargo, rustc under it and python with no shell-snapshots/ ancestor, whose transcript's Bash, Agent and Monitor tasks all reported (completed, failed, killed on queue-operation records alone, a restart then completed), whose TaskUpdate result of task 1 is no background start, and whose state.json claims work in flight, is stopped and resumed: $(cat "$WD_ACTS" "$env_dir/out")"
woke 07-alpha "wait 05" "proj P07R1 $tfs" 31
stopped_first 07-alpha
woke 12-zeta "wait 05" "proj P12 $tfs" 36
stopped_first 12-zeta
untouched 08-beta "a wait 06 park while phase 06 has not landed"
untouched 09-gamma "a working session"
untouched 10-delta "a blocked session"
for p in 11-eps 13-eta 14-theta 15-iota 17-lambda 21-omicron 22-pi 23-rho; do untouched "$p" "a live session with work in flight"; done
inflight 11 "a running Bash process 2112" "a shell-snapshots/ bash child listed in a second thread's children"
inflight 13 "a running Bash process 2132" "a shell-snapshots/ bash grandchild"
inflight 14 "background task bzui28sfr unreported" "a background Bash start with no notification, whose 30 min old output a live process holds open"
inflight 15 "background task a386abb4fa9a13693 unreported" "a background Agent start with only a status-less restart notice and a fresh output"
inflight 17 "background task bp67hm9zt unreported" "a Monitor start with no notification and a fresh output"
inflight 21 "background task a386abb4fa9a13693 unreported" "a background Agent restarted after its completion with no later status and a fresh output"
inflight 22 "a running Bash process 2221" "a shell-snapshots/ bash child running non-Bash grandchildren (cargo, rustc under it, python)"
inflight 23 "a running Bash process 2235" "closing the codex P1 on watchdog.sh:385 (shell_of counts only a descendant whose cmdline holds shell-snapshots/): the tree a live claude --bg session showed for a foreground python3 Bash tool command, python3 under a shell-snapshots/ bash beside unmarked serena, jbc and playwright MCP servers, so Bash-tool work never runs outside a marked bash"
! grep -qF 'state.json' "$env_dir/out" || fail "the watchdog no longer reads ~/.claude/jobs/<id>/state.json: $(cat "$env_dir/out")"
[ "$(stops 16)" = 1 ] || fail "phase 16's live idle session, whose state.json claims work in flight, is stopped once: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(tries 16)$(resumes 16-kappa)" = 00 ] || fail "a session still holding a pid after claude stop is not resumed that scan: $(cat "$WD_ACTS")"
untouched 18-mu "a session whose cwd is gone"
named 18-mu "a session whose cwd is gone"
[ "$(stops 19)" = 0 ] && [ "$(tries 19)" = 1 ] || fail "phase 19's stopped session is resumed without a stop: $(cat "$WD_ACTS")"
[ "$(resumes 19-nu)" = 0 ] || fail "a failed resume logs no resume event: $(cat "$sd/phases/19-nu/events.jsonl")"
named 19-nu "a failed resume"
untouched 20-xi "a session without a pid whose Bash process outlived it"
grep -qxF "forge: proj P20 $tfs ($(sidn 20)) has a running Bash process 2241 in flight with no Claude process; not resuming it" "$env_dir/out" ||
  fail "phase 20, whose session has no pid but whose shell-snapshots/ bash 2241 still runs with its CLAUDE_CODE_SESSION_ID, stays parked naming it: $(cat "$env_dir/out")"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 3 ] || fail "the scan after phase 05 lands resumes phases 07, 12 and 19 only: $(cat "$WD_ACTS")"
rm -rf "${FORGE_PROC_ROOT:?}/2241" "${FORGE_PROC_ROOT:?}/2242"

landed 06-post
: >"$WD_KEEP"
: >"$WD_FAIL"
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
woke 08-beta "wait 06" "proj P08 $tfs" 32
[ "$(stops 08)" = 0 ] || fail "a session without a pid is not stopped: $(cat "$WD_ACTS")"
woke 16-kappa "wait 05" "proj P16 $tfs" 40
stopped_first 16-kappa
woke 19-nu "wait 05" "proj P19 $tfs" 43
woke 20-xi "wait 05" "proj P20 $tfs" 44
[ "$(stops 20)" = 0 ] || fail "a crashed session without a pid, once its last Bash process exited, is resumed without a stop: $(cat "$WD_ACTS")"
[ "$(tries 07)$(tries 12)$(resumes 07-alpha)$(resumes 12-zeta)" = 0011 ] || fail "a phase whose last event is no longer park is not resumed again: $(cat "$WD_ACTS")"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 4 ] || fail "the scan after phase 06 lands resumes phases 08, 16, 19 and 20 only, an MCP server or another session's Bash process outliving 08 and 19 blocking neither: $(cat "$WD_ACTS")"
for p in 09-gamma 10-delta 11-eps 13-eta 14-theta 15-iota 17-lambda 18-mu 21-omicron 22-pi 23-rho; do untouched "$p" "a later scan"; done
h=$repo/bin/forge.d/help/watchdog.txt
! grep -qF 'never messages a session' "$h" || fail "watchdog.txt no longer says the watchdog never messages a session"
grep -qF 'claude --bg --resume' "$h" || fail "watchdog.txt documents the resume through claude --bg --resume"
grep -qF 'claude stop' "$h" || fail "watchdog.txt documents claude stop before the resume"
! grep -qF 'state.json' "$h" || fail "watchdog.txt no longer documents reading ~/.claude/jobs/<id>/state.json"
grep -qF 'shell-snapshots/' "$h" || fail "watchdog.txt documents the in-flight Bash process rule (a descendant whose cmdline holds shell-snapshots/)"
grep -qi 'notification' "$h" || fail "watchdog.txt documents the in-flight background task rule (a start with no task notification)"
grep -qF 'wait <ref>' "$h" && grep -qF '<track>/<feature>' "$h" && grep -qF 'branch <name>' "$h" || fail "watchdog.txt documents the wait <ref> condition and its <track>/<feature> and branch <name> forms"
grep -qF 'cleared; continue phase' "$h" || fail "watchdog.txt documents the wake prompt"
ok resume
fi

if want resume-two; then
setup resume-two
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_STDIN=$env_dir/stdin
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_STDIN"; do : >"$f"; done
landed 05-pre
parked 07-alpha "proj P07 $tfs" stopped "wait 05" 31 "proj P07 $tfs"
nopid 07
parked 08-beta "proj P08 $tfs" stopped "wait 05" 32 "proj P08 $tfs"
nopid 08
run
woke 07-alpha "wait 05" "proj P07 $tfs" 31
woke 08-beta "wait 05" "proj P08 $tfs" 32
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "one scan resumes both parked phases 07 and 08: $(cat "$WD_ACTS")"
[ ! -s "$WD_STDIN" ] || fail "the resume's claude --bg reads its stdin from /dev/null, not the scan's session list: $(cat "$WD_STDIN")"
unset WD_STDIN
ok resume-two
fi

if want dead-task; then
setup dead-task
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
landed 05-pre
parked 07-alpha "proj P07 $tfs" done "wait 05" 31 "proj P07 $tfs"
parked 08-beta "proj P08 $tfs" done "wait 05" 32 "proj P08 $tfs"
parked 09-gamma "proj P09 $tfs" done "wait 05" 33 "proj P09 $tfs"
parked 10-delta "proj P10 $tfs" done "wait 05" 34 "proj P10 $tfs"
parked 11-eps "proj P11 $tfs" done "wait 05" 35 "proj P11 $tfs"
parked 12-zeta "proj P12 $tfs" done "wait 05" 36 "proj P12 $tfs"
for n in 07 08 09 10 11 12; do rowpid "$n"; done
for n in 07 08 09 10; do starts "$n" bzui28sfr; done
output "$wt/$tf-07" "$(sidn 07)" bzui28sfr 15
output "$wt/$tf-08" "$(sidn 08)" bzui28sfr 15
holds 2081 "$(tout "$wt/$tf-08" "$(sidn 08)" bzui28sfr)"
output "$wt/$tf-09" "$(sidn 09)" bzui28sfr 1
starts 11 a386abb4fa9a13693
agent_out "$wt/$tf-11" "$(sidn 11)" a386abb4fa9a13693 2 30
starts 12 bzui28sfr bp67hm9zt
output "$wt/$tf-12" "$(sidn 12)" bzui28sfr 15
output "$wt/$tf-12" "$(sidn 12)" bp67hm9zt 2
for n in 13 14; do
  session "proj P$n $tfs" working "$wt/$tf-$n" "$(sidn "$n")"
  transcript "$wt/$tf-$n" "$(sidn "$n")" 40
  printf '{"type":"user","toolUseResult":{"backgroundTaskId":"bt%s"}}\n' "$n" >>"$(tlog "$n")"
  touch -d "40 minutes ago" "$(tlog "$n")"
  output "$wt/$tf-$n" "$(sidn "$n")" "bt$n" 15
done
holds 2131 "$(tout "$wt/$tf-13" "$(sidn 13)" bt13)"
session "proj P15 $tfs" working "$wt/$tf-15" "$(sidn 15)"
transcript "$wt/$tf-15" "$(sidn 15)" 40
printf '{"type":"user","toolUseResult":{"backgroundTaskId":"bt15"}}\n' >>"$(tlog 15)"
touch -d "40 minutes ago" "$(tlog 15)"
output "$wt/$tf-15" "$(sidn 15)" bt15 15
rowpid 15
proc 2151 1015 1015 /bin/bash -c "$snap"
run
woke 07-alpha "wait 05"
stopped_first 07-alpha
grep -qxF "forge: proj P07 $tfs ($(sidn 07)): background task(s) bzui28sfr dead (no process, output idle over 10 min); resuming" "$env_dir/out" ||
  fail "phase 07, whose only unreported Bash task's output is 15 min old with no process holding it, logs the dead id and resumes: $(cat "$env_dir/out")"
jq -es 'map(select(.step == "resume")) | last | .message | contains("bzui28sfr")' "$sd/phases/07-alpha/events.jsonl" >/dev/null ||
  fail "the resume event of phase 07 names the dead task bzui28sfr: $(cat "$sd/phases/07-alpha/events.jsonl")"
untouched 08-beta "a Bash task whose 15 min old output a live process holds open"
inflight 08 "background task bzui28sfr unreported" "a Bash task whose 15 min old output a live process holds open"
untouched 09-gamma "a Bash task whose output changed 1 min ago with no process holding it"
inflight 09 "background task bzui28sfr unreported" "a Bash task whose output changed 1 min ago with no process holding it"
woke 10-delta "wait 05"
grep -qxF "forge: proj P10 $tfs ($(sidn 10)): background task(s) bzui28sfr dead (no process, output idle over 10 min); resuming" "$env_dir/out" ||
  fail "phase 10, whose only unreported Bash task has no output file and no process, logs the dead id and resumes: $(cat "$env_dir/out")"
untouched 11-eps "an Agent task whose output symlink is 30 min old but whose target changed 2 min ago"
inflight 11 "background task a386abb4fa9a13693 unreported" "an Agent task whose output symlink is 30 min old but whose target changed 2 min ago"
untouched 12-zeta "a dead Bash task beside a Monitor task with a fresh output"
inflight 12 "background task bp67hm9zt unreported" "a dead Bash task beside a Monitor task with a fresh output"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 3 ] || fail "the scan resumes phases 07, 10 and 14 only: $(cat "$WD_ACTS" "$env_dir/out")"
quiet 13-eta "a working session idle 40 min whose Bash task's output a live process holds open"
grep -qxF "forge: proj P13 $tfs ($(sidn 13)) idle 40 min with background task bt13 in flight; no stall" "$env_dir/out" ||
  fail "the skipped stall of 13-eta names its live task bt13: $(cat "$env_dir/out")"
[ "$(stops 13)$(tries 13)$(resumes 13-eta)" = 000 ] || fail "13-eta, whose Bash task is live, is neither stopped nor resumed: $(cat "$WD_ACTS" "$env_dir/out")"
! grep -qF "background task bt14 in flight" "$env_dir/out" || fail "a dead task counts as no task in flight: $(cat "$env_dir/out")"
quiet 14-theta "a working session idle 40 min whose only Bash task died, resumed instead of stalled"
[ "$(tries 14)" = 1 ] || fail "14-theta, working and idle 40 min with its only Bash task bt14 dead and no live Bash child, gets exactly one claude --bg --resume: $(cat "$WD_ACTS" "$env_dir/out")"
stopped_first 14-theta
got=$(jq -c --arg s "$(sidn 14)" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
printf '%s\n' "$got" | jq -e --arg c "$wt/$tf-14" --arg s "$(sidn 14)" '.cwd == $c and .lock == "held" and .args[0:3] == ["--bg", "--resume", $s]
  and (.args[-1] | contains("bt14") and test("die|dead"; "i") and contains("continue"))' >/dev/null ||
  fail "14-theta resumes from $wt/$tf-14 under sessions.lock with a prompt naming the dead task bt14, saying it died and to continue the phase: $got"
ev14=$sd/phases/14-theta/events.jsonl
[ "$(resumes 14-theta)" = 1 ] || fail "14-theta logs one resume event: $(cat "$ev14" 2>/dev/null)"
jq -es 'map(select(.step == "resume")) | last | .dead == ["bt14"] and (.message | startswith("dead background task"))' "$ev14" >/dev/null ||
  fail "the resume event of 14-theta records dead [\"bt14\"] and its message begins 'dead background task': $(cat "$ev14")"
stalled 15-iota "proj P15 $tfs" "$(sidn 15)" 40
[ "$(stops 15)$(tries 15)$(resumes 15-iota)" = 000 ] || fail "15-iota, idle 40 min with a dead task bt15 but a live Bash child 2151 under its pid, only stalls: $(cat "$WD_ACTS" "$env_dir/out")"
jq --arg s "$(sidn 14)" 'map(if .sessionId == $s then .pid = 1 | .state = "working" else . end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
[ "$(tries 14)" = 0 ] || fail "the next scan on 14-theta's same transcript, whose dead task bt14 the resume event recorded, runs no second claude --bg --resume: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(resumes 14-theta)" = 1 ] || fail "the next scan on 14-theta logs no second resume event: $(cat "$ev14")"
! grep -qF "bt14 dead" "$env_dir/out" || fail "the next scan reports the recorded dead task bt14 dead no more: $(cat "$env_dir/out")"
ok dead-task
fi

if want dead-record; then
setup dead-record
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORK=$env_dir/fork
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORK"; do : >"$f"; done
landed 05-pre
cp7=bbbbbb07-0000-4000-8000-000000000007
ev7=$sd/phases/07-alpha/events.jsonl
parked 07-alpha "proj P07 $tfs" done "wait 05" 31 "proj P07 $tfs"
rowpid 07
starts 07 bzui28sfr
printf '%s %s\n' "$(sidn 07)" "$cp7" >>"$WD_FORK"
run
woke 07-alpha "wait 05"
jq -es 'map(select(.step == "resume")) | last | .dead == ["bzui28sfr"] and (.message | contains("background task(s) bzui28sfr dead"))' "$ev7" >/dev/null ||
  fail "the resume of phase 07 for its dead task bzui28sfr logs dead [\"bzui28sfr\"] and keeps the message text: $(cat "$ev7")"
jq -e --arg s "$cp7" 'any(.[]; .sessionId == $s and .id == "bbbbbb07")' "$agents" >/dev/null || fail "the stub forks phase 07's resume to session $cp7: $(cat "$agents")"
ct=$(pdir "$wt/$tf-07")/$cp7.jsonl
cp "$(tlog 07)" "$ct"
touch -d "30 minutes ago" "$ct"
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
[ "$(grep -c '^resume ' "$WD_ACTS")" = 0 ] || fail "the next scan, on the resumed copy $cp7 whose transcript still holds bzui28sfr's launch, runs no second claude --bg --resume: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(resumes 07-alpha)" = 1 ] || fail "the next scan on the resumed copy logs no second resume event: $(cat "$ev7")"
! grep -qF "bzui28sfr dead" "$env_dir/out" || fail "the next scan on the resumed copy reports bzui28sfr dead no more: $(cat "$env_dir/out")"
! grep -qF "background task bzui28sfr" "$env_dir/out" || fail "the next scan on the resumed copy counts no recorded dead task bzui28sfr in flight: $(cat "$env_dir/out")"
logged 07-alpha park "wait 05"
jq --arg s "$cp7" 'map(if .sessionId == $s then .state = "done" else . end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
output "$wt/$tf-07" "$cp7" bzui28sfr 1
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
[ "$(grep -c '^resume ' "$WD_ACTS")" = 0 ] || fail "the resumed copy, whose recorded dead task bzui28sfr was restarted with a fresh output, is not resumed: $(cat "$WD_ACTS" "$env_dir/out")"
grep -qxF "forge: proj P07 $tfs ($cp7) has background task bzui28sfr unreported in flight; not stopping it" "$env_dir/out" ||
  fail "a recorded dead task bzui28sfr restarted with a fresh output counts in flight: $(cat "$env_dir/out")"
output "$wt/$tf-07" "$cp7" bzui28sfr 15
jq -c --arg i bjqeokjtb 'select(.toolUseResult.backgroundTaskId? == $i)' "$fx/starts.jsonl" >>"$ct"
touch -d "30 minutes ago" "$ct"
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
[ "$(grep -c "^resume $cp7 " "$WD_ACTS")" = 1 ] && [ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] ||
  fail "the resumed copy, parked again with a different dead task bjqeokjtb, is resumed once as $cp7: $(cat "$WD_ACTS" "$env_dir/out")"
grep -qxF "forge: proj P07 $tfs ($cp7): background task(s) bjqeokjtb dead (no process, output idle over 10 min); resuming" "$env_dir/out" ||
  fail "the resume of the copy names only the new dead task bjqeokjtb, not the recorded bzui28sfr: $(cat "$env_dir/out")"
[ "$(resumes 07-alpha)" = 2 ] || fail "the resume for the new dead task bjqeokjtb logs a second resume event: $(cat "$ev7")"
jq -es 'map(select(.step == "resume")) | last | .dead == ["bjqeokjtb"]' "$ev7" >/dev/null ||
  fail "the second resume event logs dead [\"bjqeokjtb\"] only: $(cat "$ev7")"
ok dead-record
fi

fk() { printf 'bbbbbb%s-0000-4000-8000-0000000000%s' "$1" "$1"; }
lstart() { jq -cs 'map(select(.step == "start")) | last | del(.time)' "$sd/phases/$1/events.jsonl"; }
rmsg() { jq -rs 'map(select(.step == "resume")) | last | .message' "$sd/phases/$1/events.jsonl"; }
if want resume-id; then
setup resume-id
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORK=$env_dir/fork WD_QUIET=$env_dir/quiet WD_LOST=$env_dir/lost
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORK" "$WD_QUIET" "$WD_LOST"; do : >"$f"; done
landed 05-pre
parked 07-alpha "proj P07 $tfs" done "wait 05" 31 "proj P07 $tfs"
rowpid 07
printf '%s %s\n' "$(sidn 07)" "$(fk 07)" >>"$WD_FORK"
parked 08-beta "proj P08 $tfs" stopped "wait 05" 32 "proj P08 $tfs"
nopid 08
parked 09-gamma "proj P09 $tfs" stopped "wait 05" 33 "proj P09 $tfs"
nopid 09
echo "$(sidn 09)" >>"$WD_QUIET"
parked 10-delta "proj P10 $tfs" stopped "wait 05" null "proj P10 $tfs"
nopid 10
jq -c 'if .offset == null then del(.offset) else . end' "$sd/phases/10-delta/events.jsonl" >"$env_dir/ev10"
mv "$env_dir/ev10" "$sd/phases/10-delta/events.jsonl"
printf '%s %s\n' "$(sidn 10)" "$(fk 10)" >>"$WD_FORK"
echo "$(sidn 10)" >>"$WD_QUIET"
parked 11-eps "proj P11 $tfs" stopped "wait 05" 35 "proj P11 $tfs"
nopid 11
printf '%s %s\n' "$(sidn 11)" "$(fk 11)" >>"$WD_FORK"
echo aaaaaa11 >>"$WD_STOPFAIL"
parked 12-zeta "proj P12 $tfs" stopped "wait 05" 36 "proj P12 $tfs"
nopid 12
echo "$(sidn 12)" >>"$WD_QUIET"
echo "$(sidn 12)" >>"$WD_LOST"
nstarts() { jq -s 'map(select(.step == "start")) | length' "$sd/phases/$1/events.jsonl"; }
said() { [ "$(rmsg "$1")" = "$2" ] || fail "$3: the resume event of $1 is '$2', got '$(rmsg "$1")'"; }
run
for p in 07-alpha 08-beta 09-gamma 10-delta 11-eps 12-zeta; do woke "$p" "wait 05"; done
said 07-alpha "wait 05 cleared; resumed proj P07 $tfs with claude --bg --resume $(sidn 07); now session bbbbbb07" "a resume whose banner names a new id"
[ "$(nstarts 07-alpha)" = 2 ] && [ "$(lstart 07-alpha)" = "{\"step\":\"start\",\"message\":\"proj P07 $tfs\",\"offset\":31,\"session\":\"bbbbbb07\"}" ] ||
  fail "a resume that took a new id appends one start event carrying the last start's offset and the new session: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(jq -rs 'last.step' "$sd/phases/07-alpha/events.jsonl")" = resume ] || fail "the resume event follows the new start event: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(stops 07)" = 2 ] || fail "phase 07's live session is stopped before the resume and its old row, live again after the copy, once more after it: $(cat "$WD_ACTS" "$env_dir/out")"
a=$(grep -n "^resume $(sidn 07) " "$WD_ACTS" | cut -d: -f1)
b=$(grep -n "^stop aaaaaa07 " "$WD_ACTS" | tail -1 | cut -d: -f1)
[ "$b" -gt "$a" ] || fail "the superseded session aaaaaa07 is stopped after the resume that copied it: $(cat "$WD_ACTS")"
said 08-beta "wait 05 cleared; resumed proj P08 $tfs with claude --bg --resume $(sidn 08)" "a resume whose banner names the same id"
[ "$(nstarts 08-beta)$(stops 08)" = 10 ] || fail "a resume that kept its id appends no start and stops nothing: $(cat "$sd/phases/08-beta/events.jsonl" "$WD_ACTS")"
! grep -F 'cannot find the session' "$env_dir/out" | grep -qF "P09" || fail "a resume with no banner whose own row is live again warns nothing: $(cat "$env_dir/out")"
said 09-gamma "wait 05 cleared; resumed proj P09 $tfs with claude --bg --resume $(sidn 09)" "a resume with no banner whose own row is live again"
[ "$(nstarts 09-gamma)$(stops 09)" = 10 ] || fail "a resume with no banner whose own row is live again keeps its id, appends no start and stops nothing: $(cat "$sd/phases/09-gamma/events.jsonl" "$WD_ACTS")"
grep -qxF "forge: warning: cannot find the session that took the resume of proj P12 $tfs; recording it as unknown, so no scan resumes aaaaaa12 again" "$env_dir/out" ||
  fail "a resume with no banner, no new row and its own row still stopped warns that its session is unknown: $(cat "$env_dir/out")"
said 12-zeta "wait 05 cleared; resumed proj P12 $tfs with claude --bg --resume $(sidn 12); now session unknown" "a resume whose session is not found"
[ "$(nstarts 12-zeta)$(stops 12)" = 20 ] && [ "$(lstart 12-zeta)" = "{\"step\":\"start\",\"message\":\"proj P12 $tfs\",\"offset\":36,\"session\":\"unknown\"}" ] ||
  fail "a resume whose session is not found appends a start with the session unknown and the last start's offset and stops nothing: $(cat "$sd/phases/12-zeta/events.jsonl" "$WD_ACTS")"
grep '^notify-send ' "$log" | grep -F 'forge: resume unconfirmed|' | grep -qF 'phase 12-zeta: proj P12' ||
  fail "a resume whose session is not found sends one forge: resume unconfirmed notify: $(grep '^notify-send ' "$log")"
said 10-delta "wait 05 cleared; resumed proj P10 $tfs with claude --bg --resume $(sidn 10); now session bbbbbb10" "a resume with no banner whose new row claude agents lists"
[ "$(nstarts 10-delta)" = 2 ] && [ "$(lstart 10-delta)" = "{\"step\":\"start\",\"message\":\"proj P10 $tfs\",\"session\":\"bbbbbb10\"}" ] ||
  fail "a new id found through claude agents appends a start with that session and, as the last start had none, no offset: $(cat "$sd/phases/10-delta/events.jsonl")"
[ "$(stops 10)" = 1 ] || fail "phase 10's superseded session, live after the copy, is stopped: $(cat "$WD_ACTS")"
said 11-eps "wait 05 cleared; resumed proj P11 $tfs with claude --bg --resume $(sidn 11); now session bbbbbb11" "a copy whose old row fails to stop"
[ "$(nstarts 11-eps)$(stops 11)" = 21 ] || fail "phase 11 records its new id and tries one stop of the superseded aaaaaa11: $(cat "$WD_ACTS")"
grep '^forge: warning: ' "$env_dir/out" | grep -qF aaaaaa11 || fail "a failed stop of the superseded session warns naming aaaaaa11: $(cat "$env_dir/out")"
! grep -q '^claude rm ' "$log" || fail "the superseded session's row is left listed, never claude rm'd: $(grep '^claude rm ' "$log")"
jq --arg s "$(fk 07)" 'map(if .sessionId == $s then .state = "done" else . end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
turn_end "$wt/$tf-07" "$(fk 07)" 30
logged 07-alpha park "wait 05"
logged 12-zeta park "wait 05"
: >"$WD_ACTS"
: >"$WD_RESUMES"
run
[ "$(tries 07)" = 0 ] || fail "the next scan never resumes the superseded session $(sidn 07) again: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(tries 12)" = 0 ] || fail "the next scan never resumes $(sidn 12) again after a resume whose session is unknown, even once phase 12 parks again: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(grep -c "^resume $(fk 07) " "$WD_ACTS")" = 1 ] && [ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] ||
  fail "the next scan resumes phase 07's recorded session $(fk 07) once and nothing else: $(cat "$WD_ACTS" "$env_dir/out")"
jq -e --arg s "$(fk 07)" --arg nm "proj P07 $tfs" --arg ls "$lsj" '.args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, "forge watchdog: wait 05 cleared; continue phase 07 from where it parked"]' "$WD_RESUMES" >/dev/null ||
  fail "the resume of the new session carries -n '$nm' and a one-line prompt: $(cat "$WD_RESUMES")"
said 07-alpha "wait 05 cleared; resumed proj P07 $tfs with claude --bg --resume $(fk 07)" "the resume of the recorded new session"
[ "$(nstarts 07-alpha)$(resumes 07-alpha)" = 22 ] || fail "the second resume, keeping its id, appends no start: $(cat "$sd/phases/07-alpha/events.jsonl")"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF '; now session' "$h" || fail "watchdog.txt documents the '; now session <id>' suffix of the resume event"
grep -qi 'supersed' "$h" || fail "watchdog.txt documents the new start event and the stop of the superseded session"
unset WD_FORK WD_QUIET WD_LOST
ok resume-id
fi

if want poll-secs; then
polled() {
  setup "poll-secs-$1"
  wt=$root/.claude/worktrees
  resume_stubs
  export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_QUIET=$env_dir/quiet WD_LOST=$env_dir/lost
  for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_QUIET" "$WD_LOST"; do : >"$f"; done
  landed 05-pre
  parked 12-zeta "proj P12 $tfs" stopped "wait 05" 36 "proj P12 $tfs"
  nopid 12
  echo "$(sidn 12)" >>"$WD_QUIET"
  echo "$(sidn 12)" >>"$WD_LOST"
  mkdir -p "$env_dir/sb"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$env_dir/sleeps" >"$env_dir/sb/sleep"
  chmod +x "$env_dir/sb/sleep"
  : >"$env_dir/sleeps"
  shift
  (cd "$env_dir" && timeout 60 env "$@" PATH="$env_dir/sb:$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1 ||
    fail "forge watchdog exits 0 on the took()-exhausting resume: $(cat "$env_dir/out")"
  grep -qxF "forge: warning: cannot find the session that took the resume of proj P12 $tfs; recording it as unknown, so no scan resumes aaaaaa12 again" "$env_dir/out" ||
    fail "the took()-exhausting resume warns that its session is unknown: $(cat "$env_dir/out")"
  unset WD_QUIET WD_LOST
}
polled set FORGE_WATCHDOG_POLL_SECS=0.05
[ "$(cat "$env_dir/sleeps")" = "$(yes 0.05 | head -9)" ] ||
  fail "with FORGE_WATCHDOG_POLL_SECS=0.05 took() sleeps 0.05 nine times between its 10 tries, got: $(paste -sd' ' "$env_dir/sleeps")"
polled unset -u FORGE_WATCHDOG_POLL_SECS
[ "$(cat "$env_dir/sleeps")" = "$(yes 0.5 | head -9)" ] ||
  fail "with FORGE_WATCHDOG_POLL_SECS unset took() sleeps the default 0.5 nine times between its 10 tries, got: $(paste -sd' ' "$env_dir/sleeps")"
"$forge" watchdog --help >"$tmp/help" 2>&1
grep -qF FORGE_WATCHDOG_POLL_SECS "$tmp/help" || fail "forge watchdog --help documents FORGE_WATCHDOG_POLL_SECS: $(cat "$tmp/help")"
ok poll-secs
fi

eai="API Error: Can't reach the API server at api.anthropic.com (EAI_AGAIN)"
weekly="You've hit your weekly limit · resets Oct 6, 7am (America/New_York)"
resets() { jq -cn --argjson r "$(($(date +%s) + $1))" '{status: "rejected", resetsAt: $r, unifiedRateLimitFallbackAvailable: false, rateLimitType: "seven_day"}'; }
tokyo() { TZ=Asia/Tokyo date -d "@$(($(date +%s) + $1 * 60))" +%-I:%M%P; }
evt() {
  jq -cn --arg t "$(date -u -d "$2 minutes ago" +%FT%TZ)" --arg s "$3" --arg m "$4" '{time: $t, step: $s, message: $m}' >>"$sd/phases/$1/events.jsonl"
}
resolver() {
  cat >"$bin/getent" <<'STUB'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >>"$WD_LOG"
exit "${WD_GETENT_RC:-0}"
STUB
  chmod +x "$bin/getent"
}
later() {
  local p=$1 s=$(($2 * 60)) f e t
  f=$(tlog "${1%%-*}") e=$sd/phases/$p/events.jsonl
  t=$(($(stat -c %Y "$f") - s))
  jq -c --argjson s "$s" 'if (.timestamp | type) == "string" then .timestamp |= (sub("\\.[0-9]+"; "") | fromdateiso8601 - $s | strftime("%Y-%m-%dT%H:%M:%S.123Z")) else . end' "$f" >"$f.new"
  mv "$f.new" "$f"
  touch -d "@$t" "$f"
  jq -c --argjson s "$s" '.time |= (fromdateiso8601 - $s | todate)' "$e" >"$e.new"
  mv "$e.new" "$e"
}
again() {
  tl=$(tlog "${1%%-*}")
  api_err 0 server_error "$eai"
  turn_done 0
}
gave() { jq -s 'map(select(.step == "stall" and (.message | endswith("; gave up")))) | length' "$sd/phases/10-delta/events.jsonl"; }
retired() { for p; do jq -n '{status: "done", summary: "s"}' >"$sd/phases/$p/result.json"; done; }
scan() {
  : >"$log"
  : >"$WD_ACTS"
  : >"$WD_RESUMES"
  run
}
waited() {
  [ "$(tries "${1%%-*}")" = 0 ] || fail "$2: phase $1 is not resumed: $(cat "$WD_ACTS" "$env_dir/out")"
  ! grep '^notify-send ' "$log" | grep -F 'forge: auto-resume|' | grep -qF "phase $1:" || fail "$2: no auto-resume notify for phase $1: $(grep '^notify-send ' "$log")"
}
auto() {
  local p=$1 k=$2 cause=$3 n=${1%%-*} s got want
  s=$(sidn "$n")
  got=$(jq -c --arg s "$s" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
  [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "$4: phase $p is resumed once with claude --bg --resume $s: $(cat "$WD_RESUMES" "$env_dir/out")"
  printf '%s\n' "$got" | jq -e --arg s "$s" --arg nm "proj P$n $tfs" --arg pr "forge watchdog: $cause cleared; continue phase $n from where it stopped" --arg ls "$lsj" '.args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, $pr]' >/dev/null ||
    fail "$4: phase $p resumes as claude --bg --resume $s -n 'proj P$n $tfs' 'forge watchdog: $cause cleared; continue phase $n from where it stopped', got $got"
  want="auto-resume $k/5 after $cause; resumed proj P$n $tfs with claude --bg --resume $s"
  [ "$(rmsg "$p")" = "$want" ] || fail "$4: the resume event of $p is '$want', got '$(rmsg "$p")'"
  want="notify-send --|forge: auto-resume|proj phase $p: proj P$n $tfs stopped by $cause; resume $k/5"
  [ "$(grep '^notify-send ' "$log" | grep -F "phase $p:" || true)" = "$want" ] ||
    fail "$4: one forge notify '${want#notify-send --|}', got: $(grep '^notify-send ' "$log")"
}
healed() {
  local p=$1 line=$2 k=$3 n=${1%%-*} s got want
  s=$(sidn "$n")
  got=$(jq -c --arg s "$s" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
  [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "$4: phase $p is resumed once with claude --bg --resume $s: $(cat "$WD_RESUMES" "$env_dir/out")"
  printf '%s\n' "$got" | jq -e --arg s "$s" --arg nm "proj P$n $tfs" --arg pr "forge watchdog: no operator is present; fix the blocker yourself and continue phase $n from where it stopped" --arg ls "$lsj" '.args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, $pr]' >/dev/null ||
    fail "$4: phase $p resumes as claude --bg --resume $s -n 'proj P$n $tfs' 'forge watchdog: no operator is present; fix the blocker yourself and continue phase $n from where it stopped', got $got"
  want="self-heal $k/3 on '$line'; resumed proj P$n $tfs with claude --bg --resume $s"
  [ "$(rmsg "$p")" = "$want" ] || fail "$4: the resume event of $p is '$want', got '$(rmsg "$p")'"
  ! grep '^notify-send ' "$log" | grep -qF "phase $p:" || fail "$4: a self-heal sends no notify: $(grep '^notify-send ' "$log")"
  [ ! -f "$sd/phases/$p/result.json" ] || fail "$4: the self-heal of $p removes its blocked result.json"
}
if want stopped-resume; then
setup stopped-resume
wt=$root/.claude/worktrees
resume_stubs
resolver
mkdir -p "$sd/phases/17-lambda" "$sd/phases/18-mu" "$sd/phases/19-sigma" "$sd/phases/20-xi"
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
stop_row 07-alpha done
api_err 40 rate_limit "$weekly" "$(resets 7200)"
turn_done 40
stop_row 08-beta stopped
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
stop_row 09-gamma stopped
api_err 40 rate_limit "$weekly" "$(resets -20)"
turn_done 40
stop_row 10-delta stopped
api_err 3 server_error "$eai"
turn_done 3
stop_row 11-eps stopped
turn_done 60
restarted 10
stop_row 12-zeta stopped
turn_done 60
queued 55 bvhjk2jcc '<status>completed</status>
'
killed 30
stop_row 13-eta stopped
turn_done 60
killed 8
stop_row 14-theta stopped
turn_done 60
stop_row 15-iota done
api_err 10 server_error "$eai"
turn_done 10
stop_row 16-kappa stopped
evt 16-kappa 50 resume "auto-resume 1/5 after API error server_error; resumed proj P16R1 $tfs with claude --bg --resume $(sidn 16)"
for k in 2 3; do evt 16-kappa $((60 - 10 * k)) resume "auto-resume $k/5 after API error server_error; resumed proj P16 $tfs with claude --bg --resume $(sidn 16)"; done
evt 16-kappa 20 test "T4 fails as expected"
api_err 10 server_error "$eai"
turn_done 10
stop_row 17-lambda stopped
api_err 40 rate_limit "You've hit your session limit · resets $(tokyo -10) (Asia/Tokyo)"
turn_done 40
stop_row 18-mu stopped
api_err 40 rate_limit "You've hit your session limit · resets $(tokyo 60) (Asia/Tokyo)"
turn_done 40
stop_row 19-sigma stopped
turn_done 60
restarted 10
finished 5
stop_row 20-xi stopped
turn_done 60
unfinished 10
for k in 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do touch -d '3 minutes ago' "$(tlog "$k")"; done
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
rowpid 15
proc 2151 1015 1015 /bin/bash -c "$snap"
scan
waited 07-alpha "a usage limit whose resetsAt is 2 h ahead"
auto 08-beta 1 "usage limit" "a usage limit whose resetsAt is 120 s past"
waited 09-gamma "a usage limit whose resetsAt is only 20 s past"
auto 10-delta 1 "API error server_error" "a server_error stop 3 min ago, resumed on the first scan rather than 5 min after the stop"
auto 11-eps 1 reboot "a 'was restarted after the previous session ended' record 10 min ago"
auto 12-zeta 1 reboot "a killed task-notification before the current boot"
waited 13-eta "a killed task-notification after the current boot"
plain_end 13-eta "a killed task-notification after the current boot"
waited 14-theta "a stopped row with no cause"
plain_end 14-theta "a stopped row with no cause"
waited 15-iota "a server_error stop whose session has a Bash process in flight"
inflight 15 "a running Bash process 2151" "a server_error stop whose session has a Bash process in flight"
[ "$(resumes 15-iota)" = 0 ] || fail "a resume_session that returned 1 logs no resume event: $(cat "$sd/phases/15-iota/events.jsonl")"
auto 16-kappa 4 "API error server_error" "a server_error stop after a test event that follows three earlier auto-resumes, one by a retry session, all counted toward the cap"
auto 17-lambda 1 "usage limit" "a usage limit whose text reset 'resets $(tokyo -10) (Asia/Tokyo)' is past"
waited 18-mu "a usage limit whose text reset is an hour ahead in Asia/Tokyo"
waited 19-sigma "a restarted record of a386abb4fa9a13693 followed by its completed notice and no assistant record"
plain_end 19-sigma "a restarted record of a386abb4fa9a13693 followed by its completed notice and no assistant record"
[ "$(resumes 19-sigma)" = 0 ] || fail "a restart notice whose task later completed is no reboot: $(cat "$sd/phases/19-sigma/events.jsonl")"
auto 20-xi 1 reboot "a 'didn't finish before the previous session ended' record 10 min ago"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 7 ] || fail "the first scan resumes phases 08, 10, 11, 12, 16, 17 and 20 only: $(cat "$WD_ACTS")"
retired 08-beta 09-gamma 11-eps 12-zeta 16-kappa 17-lambda 18-mu 19-sigma 20-xi
: >"$FORGE_PROC_ROOT/1015/task/1015/children"
again 10-delta
later 10-delta 5
scan
auto 10-delta 2 "API error server_error" "a second server_error stop, resumed on the next scan after auto-resume 1/5"
auto 15-iota 1 "API error server_error" "a server_error stop whose earlier in-flight resume counted no attempt"
for p in 07-alpha 13-eta 14-theta; do waited "$p" "the second scan"; done
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "the second scan resumes phases 10 and 15 only: $(cat "$WD_ACTS")"
retired 15-iota
for k in 3 4 5; do
  again 10-delta
  later 10-delta 5
  scan
  auto 10-delta "$k" "API error server_error" "a server_error stop, resumed on the next scan after auto-resume $((k - 1))/5"
done
again 10-delta
later 10-delta 5
scan
waited 10-delta "a sixth stop after auto-resume 5/5"
[ "$(grep '^notify-send ' "$log" | grep -F 'phase 10-delta:' || true)" = "notify-send --|forge: auto-resume gave up|proj phase 10-delta: proj P10 $tfs stopped by API error server_error after 5 resumes" ] ||
  fail "a stop after auto-resume 5/5 sends one forge notify 'forge: auto-resume gave up' 'proj phase 10-delta: proj P10 $tfs stopped by API error server_error after 5 resumes', got: $(grep '^notify-send ' "$log")"
[ "$(gave)" = 1 ] || fail "giving up logs one stall event ending '; gave up': $(cat "$sd/phases/10-delta/events.jsonl")"
n=$(stalls 10-delta)
scan
waited 10-delta "a later scan of a given-up stop"
[ "$(stalls 10-delta)$(gave)" = "${n}1" ] || fail "a later scan of a given-up stop logs no stall: $(cat "$sd/phases/10-delta/events.jsonl")"
! grep '^notify-send ' "$log" | grep -qF 'phase 10-delta:' || fail "a later scan of a given-up stop sends no notify: $(grep '^notify-send ' "$log")"
[ "$(jq -s 'map(select(.step == "resume" and (.message | startswith("auto-resume")))) | length' "$sd/phases/10-delta/events.jsonl")" = 5 ] ||
  fail "a server_error stop is auto-resumed 5 times in all: $(cat "$sd/phases/10-delta/events.jsonl")"
for p in 07-alpha 13-eta 14-theta; do [ "$(resumes "$p")" = 0 ] || fail "phase $p is never resumed: $(cat "$sd/phases/$p/events.jsonl")"; done

setup stopped-resume-dns
wt=$root/.claude/worktrees
resume_stubs
resolver
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
stop_row 07-alpha stopped
api_err 10 server_error "$eai"
turn_done 10
touch -d '3 minutes ago' "$(tlog 07)"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
export WD_GETENT_RC=2
scan
unset WD_GETENT_RC
grep -qxF 'getent hosts api.anthropic.com' "$log" || fail "an API-error attempt first probes getent hosts api.anthropic.com: $(cat "$log")"
waited 07-alpha "a server_error stop while api.anthropic.com does not resolve"
[ "$(resumes 07-alpha)" = 0 ] || fail "a failed probe logs no resume event: $(cat "$sd/phases/07-alpha/events.jsonl")"
grep -qxF "forge: proj P07 $tfs waits for api.anthropic.com to resolve" "$env_dir/out" ||
  fail "a failed probe prints 'forge: proj P07 $tfs waits for api.anthropic.com to resolve': $(cat "$env_dir/out")"
scan
auto 07-alpha 1 "API error server_error" "a server_error stop once api.anthropic.com resolves, its failed probe counted no attempt"

setup stopped-resume-park
wt=$root/.claude/worktrees
resume_stubs
resolver
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
stop_row 07-alpha stopped
for k in 1 2 3 4 5; do evt 07-alpha $((60 - 5 * k)) resume "auto-resume $k/5 after API error server_error; resumed proj P07 $tfs with claude --bg --resume $(sidn 07)"; done
evt 07-alpha 30 park "wait 05"
evt 07-alpha 25 resume "wait 05 cleared; resumed proj P07 $tfs with forge resume"
api_err 10 server_error "$eai"
turn_done 10
touch -d '3 minutes ago' "$(tlog 07)"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
scan
waited 07-alpha "a sixth stop after five auto-resumes and a later park and wake"
[ "$(grep '^notify-send ' "$log" | grep -F 'phase 07-alpha:' || true)" = "notify-send --|forge: auto-resume gave up|proj phase 07-alpha: proj P07 $tfs stopped by API error server_error after 5 resumes" ] ||
  fail "a sixth stop across a park event sends one forge notify 'forge: auto-resume gave up' 'proj phase 07-alpha: proj P07 $tfs stopped by API error server_error after 5 resumes', got: $(grep '^notify-send ' "$log")"
[ "$(jq -s 'map(select(.step == "stall" and (.message | endswith("; gave up")))) | length' "$sd/phases/07-alpha/events.jsonl")" = 1 ] ||
  fail "a sixth stop across a park event logs one stall event ending '; gave up': $(cat "$sd/phases/07-alpha/events.jsonl")"
scan
waited 07-alpha "a later scan of a stop given up across a park event"
! grep '^notify-send ' "$log" | grep -qF 'phase 07-alpha:' || fail "a later scan of a stop given up across a park event sends no notify: $(grep '^notify-send ' "$log")"
[ "$(jq -s 'map(select(.step == "stall" and (.message | endswith("; gave up")))) | length' "$sd/phases/07-alpha/events.jsonl")" = 1 ] ||
  fail "a later scan of a stop given up across a park event logs no further give-up: $(cat "$sd/phases/07-alpha/events.jsonl")"
[ "$(jq -s 'map(select(.step == "resume" and (.message | startswith("auto-resume")))) | length' "$sd/phases/07-alpha/events.jsonl")" = 5 ] ||
  fail "a phase given up across a park event logs no sixth auto-resume: $(cat "$sd/phases/07-alpha/events.jsonl")"
ok stopped-resume
fi

if want ended-resume; then
setup ended-resume
wt=$root/.claude/worktrees
resume_stubs
resolver
mkdir -p "$sd/phases/17-lambda" "$sd/phases/18-mu"
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
open_tool() {
  rec --arg t "$(stamp "$1")" '{type: "assistant", timestamp: $t, message: {id: "msg_open", role: "assistant", model: "claude-opus-5-5", content: [{type: "tool_use", id: "toolu_open1", name: "Bash", input: {command: "cargo build"}, caller: {type: "direct"}}], stop_reason: "tool_use"}}'
}
stop_row 07-alpha done
turn_done 60
stop_row 08-beta stopped
turn_done 60
stop_row 09-gamma done
asked 60 "T3 is committed.

Should I keep the old stall flag or drop it?"
turn_done 60
stop_row 10-delta done
open_tool 60
stop_row 11-eps done
asked 60 "T3 is committed.

needs input: the name of the new flag"
turn_done 60
stop_row 12-zeta done
asked 60 "Paused until 07 merges.

result: Phase 12 waits on 07"
turn_done 60
stop_row 13-eta failed
turn_done 60
stop_row 14-theta crashed
turn_done 60
stop_row 15-iota done
turn_done 60
logged 15-iota wait "dependency 07 merged"
stop_row 16-kappa done
turn_done 60
sa=$(pdir "$wt/$tf-16")/$(sidn 16)/subagents
mkdir -p "$sa"
sl16=$sa/agent-open16.jsonl
tl=$sl16
echo '{}' >"$tl"
open_tool 60
stop_row 17-lambda done
turn_done 60
sa=$(pdir "$wt/$tf-17")/$(sidn 17)/subagents
mkdir -p "$sa"
sl17=$sa/agent-lost17.jsonl
echo '{}' >"$sl17"
stop_row 18-mu done
turn_done 60
retired 18-mu
for k in 07 08 09 10 11 12 13 14 15 16 17 18; do touch -d '3 minutes ago' "$(tlog "$k")"; done
touch -d '3 minutes ago' "$sl16" "$sl17"
chmod 000 "$sl17"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
scan
chmod 600 "$sl17"
auto 07-alpha 1 "ended turn" "a done row with no cause, no pending question and no park, wait or waits-on line, resumed on the first scan"
stopped_by 07-alpha "ended turn" "a done row with no cause"
[ "$(ended_pings 07-alpha)" = 0 ] || fail "a resumed ended turn sends no 'forge: turn ended': $(grep '^notify-send ' "$log")"
waited 08-beta "a stopped row with the same transcript as the resumed done row"
plain_end 08-beta "a stopped row with the same transcript as the resumed done row"
waited 09-gamma "a done row whose last reply ends in '?'"
[ "$(asks "proj P09 $tfs:")" = 1 ] || fail "a done row whose last reply ends in '?' keeps its 'forge: question' alert, got $(asks "proj P09 $tfs:"): $(grep '^notify-send ' "$log")"
waited 10-delta "a done row with an open tool_use"
[ "$(ends 10-delta)" = 1 ] || fail "a done row with an open tool_use keeps its ended-turn stall: $(cat "$sd/phases/10-delta/events.jsonl" 2>/dev/null)"
healed 11-eps "needs input: the name of the new flag" 1 "a done row whose last reply holds a 'needs input:' line is self-healed"
[ "$(ends 11-eps)" = 0 ] || fail "a self-healed done row logs no ended-turn stall: $(cat "$sd/phases/11-eps/events.jsonl" 2>/dev/null)"
untouched 12-zeta "a done row whose last reply ends 'result: Phase 12 waits on 07'"
quiet 12-zeta "a done row whose last reply ends 'result: Phase 12 waits on 07'"
waited 13-eta "a failed row with no cause"
plain_end 13-eta "a failed row with no cause"
waited 14-theta "a crashed row with no cause"
plain_end 14-theta "a crashed row with no cause"
untouched 15-iota "a done row whose last event is wait"
quiet 15-iota "a done row whose last event is wait"
waited 16-kappa "a done row whose subagent transcript has an open tool_use"
[ "$(resumes 16-kappa)" = 0 ] || fail "a done row whose subagent has a pending tool_use logs no resume event: $(cat "$sd/phases/16-kappa/events.jsonl")"
waited 17-lambda "a done row whose subagent transcript cannot be read"
[ "$(resumes 17-lambda)" = 0 ] || fail "a done row whose subagent transcript cannot be read logs no resume event: $(cat "$sd/phases/17-lambda/events.jsonl")"
grep -qF "forge: cannot read $sl17" "$env_dir/out" || fail "an unreadable subagent transcript warns 'forge: cannot read $sl17': $(cat "$env_dir/out")"
untouched 18-mu "a done row whose phase has result.json"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "the scan resumes phases 07 and 11 only: $(cat "$WD_ACTS")"
ok ended-resume
fi

ftries() { grep -c "^resume $(fsid "$1") " "$WD_ACTS" || true; }
fresumed() {
  local k=$1 f=$2 n=$3 cause=$4 why=$5 s got want
  s=$(fsid "$n")
  got=$(jq -c --arg s "$s" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
  [ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "$why: the $k session of tr/$f is resumed once with claude --bg --resume $s: $(cat "$WD_RESUMES" "$env_dir/out")"
  want="forge watchdog: $cause cleared; continue tr/$f $k from where it stopped"
  printf '%s\n' "$got" | jq -e --arg s "$s" --arg nm "proj $k tr/$f" --arg pr "$want" --arg ls "$lsj" '.args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, $pr]' >/dev/null ||
    fail "$why: the $k session resumes as claude --bg --resume $s -n 'proj $k tr/$f' '$want', got $got"
  want="proj $k tr/$f ($s) turn ended with no result: stopped by $cause"
  [ "$(fev "$f" stall)" = 1 ] && [ "$(fmsg "$f" stall)" = "$want" ] ||
    fail "$why: one stall event '$want' in features/tr-$f/events.jsonl: $(cat "$(fdir "$f")/events.jsonl" 2>/dev/null)"
  want="auto-resume 1/5 after $cause; resumed proj $k tr/$f with claude --bg --resume $s"
  [ "$(fev "$f" resume)" = 1 ] && [ "$(fmsg "$f" resume)" = "$want" ] ||
    fail "$why: one resume event '$want' in features/tr-$f/events.jsonl: $(cat "$(fdir "$f")/events.jsonl" 2>/dev/null)"
  want="notify-send --|forge: auto-resume|proj tr/$f $k: proj $k tr/$f stopped by $cause; resume 1/5"
  [ "$(fnotes "$f")" = "$want" ] || fail "$why: exactly one forge notify '${want#notify-send --|}' naming tr/$f $k, got: $(grep '^notify-send ' "$log")"
}
fquiet() {
  [ "$(fev "$1" stall)$(fev "$1" resume)$(ftries "$2")" = 000 ] ||
    fail "$3: no stall or resume event and no resume for tr/$1: $(cat "$(fdir "$1")/events.jsonl" 2>/dev/null) $(cat "$WD_ACTS")"
  [ -z "$(fnotes "$1")" ] || fail "$3: no notify naming tr/$1: $(grep '^notify-send ' "$log")"
}
if want stopped-feature; then
setup stopped-feature
wt=$root/.claude/worktrees
resume_stubs
resolver
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
tls=()
frow() {
  local k=$1 f=$2 cwd=$3 n=$4
  mkdir -p "$(fdir "$f")"
  session "proj $k tr/$f" stopped "$cwd" "$(fsid "$n")"
  tl=$(pdir "$cwd")/$(fsid "$n").jsonl
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  tls+=("$tl")
  human 90 "/forge-$k $root tr/$f"
  said_ok 60
}
fevt() {
  jq -cn --arg t "$(date -u -d "$2 minutes ago" +%FT%TZ)" --arg s "$3" --arg m "$4" --arg i "${5:-}" \
    '{time: $t, step: $s, message: $m} + if $i == "" then {} else {session: $i} end' >>"$(fdir "$1")/events.jsonl"
}
frow verify feat "$wt/tr-feat" 31
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
frow verify done "$wt/tr-done" 32
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
jq -n '{result: "pass"}' >"$(fdir done)/verify.json"
frow ship shp "$root" 33
api_err 10 server_error "$eai"
turn_done 10
fevt shp 120 start "proj ship tr/shp" cccccc33
frow ship old "$root" 34
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
fevt old 120 start "proj ship tr/old" cccccc34
jq -n '{result: "pass"}' >"$(fdir old)/verify.json"
jq -n '{result: "pass"}' >"$(fdir old)/ship.json"
frow ship sub "$root" 37
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
fevt sub 120 start "proj ship tr/sub" cccccc37
jq -n '{result: "pass"}' >"$(fdir sub)/verify.json"
jq -n '{result: "pass"}' >"$(fdir sub)/ship.json"
frow ship arc "$root" 38
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
fevt arc 120 start "proj ship tr/arc" cccccc38
jq -n '{result: "pass"}' >"$(fdir arc)/verify.json"
jq -n '{result: "pass"}' >"$(fdir arc)/ship.json"
mkdir -p "$sd/archive"
mv "$(fdir arc)" "$sd/archive/tr-arc"
frow ship res "$root" 39
rec --arg t "$(stamp 50)" '{type: "assistant", timestamp: $t, message: {role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: "Merged PR #9 into main.\nresult: Shipped tr/res, merged"}], stop_reason: "end_turn"}}'
api_err 40 rate_limit "$weekly" "$(resets -120)"
turn_done 40
fevt res 120 start "proj ship tr/res" cccccc39
jq -n '{result: "pass"}' >"$(fdir res)/verify.json"
jq -n '{result: "pass"}' >"$(fdir res)/ship.json"
frow verify gu "$wt/tr-gu" 35
for k in 1 2 3 4 5; do fevt gu $((70 - 10 * k)) resume "auto-resume $k/5 after usage limit; resumed proj verify tr/gu with claude --bg --resume $(fsid 35)"; done
api_err 10 rate_limit "$weekly" "$(resets -120)"
turn_done 10
frow verify sw "$wt/tr-sw" 36
fevt sw 80 start "proj verify tr/sw" cccccc40
for k in 1 2 3 4 5; do
  o=$(fsid 4$((k - 1))) w=cccccc4$k
  [ "$k" != 5 ] || w=cccccc36
  fevt sw $((70 - 10 * k)) start "proj verify tr/sw" "$w"
  fevt sw $((70 - 10 * k)) resume "auto-resume $k/5 after usage limit; resumed proj verify tr/sw with claude --bg --resume $o; now session $w"
done
api_err 10 rate_limit "$weekly" "$(resets -120)"
turn_done 10
touch -d '3 minutes ago' "${tls[@]}"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
scan
fresumed verify feat 31 "usage limit" "a verify session stopped by a usage limit whose reset is 120 s past"
fresumed ship shp 33 "API error server_error" "a ship session stopped by a server_error 10 min ago"
fquiet done 32 "a verify session stopped by a usage limit whose feature has verify.json"
fresumed ship old 34 "usage limit" "a ship session stopped by a usage limit after step 5 wrote ship.json, with no result: line"
fresumed ship sub 37 "usage limit" "a second ship session stopped by a usage limit after ship.json, with no result: line"
fquiet res 39 "a ship session whose last non-error reply holds a result: line, stopped later by a usage limit"
fquiet arc 38 "a ship session stopped by a usage limit whose feature was archived"
want="proj verify tr/gu ($(fsid 35)) turn ended with no result: stopped by usage limit; gave up"
[ "$(fev gu stall)" = 1 ] && [ "$(fmsg gu stall)" = "$want" ] ||
  fail "a verify stop after auto-resume 5/5 logs one stall event '$want': $(cat "$(fdir gu)/events.jsonl")"
[ "$(ftries 35)$(fev gu resume)" = 05 ] || fail "a verify stop after auto-resume 5/5 is not resumed again: $(cat "$WD_ACTS")"
want="notify-send --|forge: auto-resume gave up|proj tr/gu verify: proj verify tr/gu stopped by usage limit after 5 resumes"
[ "$(fnotes gu)" = "$want" ] || fail "a verify stop after auto-resume 5/5 sends one forge notify '${want#notify-send --|}', got: $(grep '^notify-send ' "$log")"
want="proj verify tr/sw ($(fsid 36)) turn ended with no result: stopped by usage limit; gave up"
[ "$(fev sw stall)" = 1 ] && [ "$(fmsg sw stall)" = "$want" ] ||
  fail "a verify stop after 5 auto-resumes that each took a new session id logs one stall event '$want': $(cat "$(fdir sw)/events.jsonl")"
[ "$(ftries 36)$(fev sw resume)" = 05 ] || fail "a verify stop after 5 auto-resumes that each took a new session id is not resumed again: $(cat "$WD_ACTS")"
want="notify-send --|forge: auto-resume gave up|proj tr/sw verify: proj verify tr/sw stopped by usage limit after 5 resumes"
[ "$(fnotes sw)" = "$want" ] || fail "a verify stop after 5 auto-resumes that each took a new session id sends one forge notify '${want#notify-send --|}', got: $(grep '^notify-send ' "$log")"
! grep '^notify-send ' "$log" | grep -qF 'forge: turn ended' || fail "a classified verify or ship stop sends no 'forge: turn ended' alert: $(grep '^notify-send ' "$log")"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 4 ] || fail "the scan resumes the tr/feat verify and tr/shp, tr/old and tr/sub ship sessions only: $(cat "$WD_ACTS")"
jq -n '{result: "pass"}' >"$(fdir feat)/verify.json"
jq -n '{result: "pass"}' >"$(fdir shp)/verify.json"
jq -n '{result: "pass"}' >"$(fdir shp)/ship.json"
for k in 33:shp 34:old 37:sub; do
  tl=$(pdir "$root")/$(fsid "${k%%:*}").jsonl
  rec --arg t "$(stamp 5)" --arg x "result: Shipped tr/${k#*:}, merged" '{type: "assistant", timestamp: $t, message: {role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: $x}], stop_reason: "end_turn"}}'
done
touch -d '3 minutes ago' "${tls[@]}"
scan
[ "$(fev feat stall)$(fev feat resume)$(fev shp stall)$(fev shp resume)$(fev old stall)$(fev old resume)$(fev sub stall)$(fev sub resume)$(fev gu stall)" = 111111111 ] ||
  fail "a later scan of finished or given-up verify and ship sessions logs no event: $(cat "$(fdir feat)/events.jsonl" "$(fdir shp)/events.jsonl" "$(fdir old)/events.jsonl" "$(fdir sub)/events.jsonl" "$(fdir gu)/events.jsonl")"
[ ! -s "$WD_ACTS" ] || fail "a later scan of finished or given-up verify and ship sessions resumes nothing: $(cat "$WD_ACTS")"
! grep -q '^notify-send ' "$log" || fail "a later scan of finished or given-up verify and ship sessions sends no notify: $(grep '^notify-send ' "$log")"
ok stopped-feature
fi

if want verify-gaps; then
setup verify-gaps
wt=$root/.claude/worktrees
resume_stubs
resolver
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
vtls=()
for k in 51:gp 52:ve 53:lr 54:lc 55:tn 56:tl; do
  n=${k%%:*} f=${k#*:} st=done
  [ "$f" != lr ] && [ "$f" != tl ] || st=stopped
  mkdir -p "$(fdir "$f")"
  session "proj verify tr/$f" "$st" "$wt/tr-$f" "$(fsid "$n")"
  tl=$(pdir "$wt/tr-$f")/$(fsid "$n").jsonl
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  vtls+=("$tl")
  human 90 "/forge-verify $root tr/$f"
  jq -cn --arg t "$(date -u -d '90 minutes ago' +%FT%TZ)" --arg m "proj verify tr/$f" --arg s "cccccc$n" '{time: $t, step: "start", message: $m, offset: 50, session: $s}' >"$(fdir "$f")/events.jsonl"
  if [ "$f" = gp ]; then
    rec --arg t "$(stamp 60)" '{type: "assistant", timestamp: $t, message: {id: "msg_gaps", role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: "Verify recorded gaps on one item; phase 3 is being retried.\n\nresult: Verify gaps, 386619fc (proj P03R1 tr/gp)"}], stop_reason: "end_turn"}}'
    turn_done 60
  elif [ "$f" = lr ]; then
    rec --arg t "$(stamp 70)" '{type: "assistant", timestamp: $t, message: {id: "msg_lrgaps", role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: "Verify recorded gaps on one item.\n\nresult: Verify gaps, 386619fd (proj P03R1 tr/lr)"}], stop_reason: "end_turn"}}'
    turn_done 70
    human 65 "Recheck item 2 against the new build."
    rec --arg t "$(stamp 60)" '{type: "assistant", timestamp: $t, message: {id: "msg_lrtool", role: "assistant", model: "claude-opus-5-5", content: [{type: "tool_use", id: "toolu_lr1", name: "Bash", input: {command: "forge test --one demo:item2"}, caller: {type: "direct"}}], stop_reason: "tool_use"}}'
    rec --arg t "$(stamp 60)" '{type: "user", timestamp: $t, message: {role: "user", content: [{tool_use_id: "toolu_lr1", type: "tool_result", content: "ok", is_error: false}]}}'
    api_err 40 rate_limit "$weekly" "$(resets -120)"
    turn_done 40
  elif [ "$f" != ve ]; then
    rec --arg t "$(stamp 70)" --arg x "Verify recorded gaps on one item.

result: Verify gaps, 3866$n (proj P03R1 tr/$f)" '{type: "assistant", timestamp: $t, message: {id: "msg_gaps", role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: $x}], stop_reason: "end_turn"}}'
    turn_done 70
    if [ "$f" = lc ]; then
      rec --arg t "$(stamp 65)" '{type: "user", isMeta: true, timestamp: $t, message: {role: "user", content: "<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, and its output goes straight to the user. It'"'"'s recorded here as context for later messages.</local-command-caveat>"}}'
      rec --arg t "$(stamp 65)" '{type: "user", timestamp: $t, message: {role: "user", content: "<command-name>/cost</command-name>\n            <command-message>cost</command-message>\n            <command-args></command-args>"}}'
      rec --arg t "$(stamp 65)" '{type: "user", timestamp: $t, message: {role: "user", content: "<local-command-stdout>Total cost: $4.12</local-command-stdout>"}}'
    else
      task_note 65 "b${f}${n}aa1" '<status>completed</status>
<summary>Background command "Start the preview server" completed (exit code 0)</summary>
'
      if [ "$f" = tn ]; then
        rec --arg t "$(stamp 60)" '{type: "assistant", timestamp: $t, message: {id: "msg_tnsay", role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: "The preview server exited; nothing to do."}], stop_reason: "end_turn"}}'
        turn_done 60
      else
        rec --arg t "$(stamp 60)" '{type: "assistant", timestamp: $t, message: {id: "msg_tltool", role: "assistant", model: "claude-opus-5-5", content: [{type: "tool_use", id: "toolu_tl1", name: "Bash", input: {command: "forge test --one demo:item2"}, caller: {type: "direct"}}], stop_reason: "tool_use"}}'
        rec --arg t "$(stamp 60)" '{type: "user", timestamp: $t, message: {role: "user", content: [{tool_use_id: "toolu_tl1", type: "tool_result", content: "ok", is_error: false}]}}'
        api_err 40 rate_limit "$weekly" "$(resets -120)"
        turn_done 40
      fi
    fi
  else
    said_ok 60
    turn_done 60
  fi
done
touch -d '3 minutes ago' "${vtls[@]}"
jq 'map(del(.pid, .status))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
[ ! -f "$(fdir gp)/verify.json" ] || fail "the gaps verify fixture has no verify.json, as forge next leaves it"
scan
vtries() { grep -c "^resume $(fsid "$1") " "$WD_ACTS" || true; }
[ "$(vtries 52)" = 1 ] || fail "a done verify session with no result: line and no verify.json is resumed once on its ended turn: $(cat "$WD_ACTS" "$env_dir/out")"
got=$(jq -c --arg s "$(fsid 51)" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
[ -z "$got" ] || fail "a done verify session whose transcript ends on 'result: Verify gaps, <session>' with verify.json removed by forge next is not resumed with claude --bg --resume $(fsid 51), got: $got $(cat "$env_dir/out")"
[ "$(vtries 51)" = 0 ] || fail "a done verify session that ended on 'result: Verify gaps, <session>' is not resumed: $(cat "$WD_ACTS")"
[ "$(jq -s 'map(select(.step == "resume" or (.message | strings | startswith("auto-resume")))) | length' "$(fdir gp)/events.jsonl")" = 0 ] ||
  fail "a done verify session that ended on 'result: Verify gaps, <session>' logs no auto-resume event: $(cat "$(fdir gp)/events.jsonl")"
[ ! -f "$(fdir lr)/verify.json" ] || fail "the follow-up verify fixture has no verify.json"
fresumed verify lr 53 "usage limit" "a verify session that ended on 'result: Verify gaps, <session>', then took an operator follow-up whose tool-only turn hit a usage limit"
for k in "54:lc:then the operator ran /cost (local-command lines with no origin)" "55:tn:then a task-notification turn replied with plain text and no result: line"; do
  n=${k%%:*} f=${k#*:} why="a done verify session that ended on 'result: Verify gaps, <session>', ${f#*:}"
  f=${f%%:*}
  [ ! -f "$(fdir "$f")/verify.json" ] || fail "the tr/$f verify fixture has no verify.json"
  got=$(jq -c --arg s "$(fsid "$n")" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
  [ -z "$got" ] || fail "$why, is not resumed with claude --bg --resume $(fsid "$n"), got: $got $(cat "$env_dir/out")"
  [ "$(vtries "$n")" = 0 ] || fail "$why, is not resumed: $(cat "$WD_ACTS")"
  [ "$(jq -s 'map(select(.step == "resume" or (.message | strings | startswith("auto-resume")))) | length' "$(fdir "$f")/events.jsonl")" = 0 ] ||
    fail "$why, logs no auto-resume event: $(cat "$(fdir "$f")/events.jsonl")"
done
[ ! -f "$(fdir tl)/verify.json" ] || fail "the task-notification limit verify fixture has no verify.json"
fquiet tl 56 "a verify session that ended on 'result: Verify gaps, <session>', then took a task-notification whose tool-only turn hit a usage limit"
ok verify-gaps
fi

bsay() {
  rec --arg t "$(stamp "$1")" --arg m "$2" --arg x "$3" --arg s "${4-end_turn}" \
    '{type: "assistant", timestamp: $t, message: {id: $m, role: "assistant", model: "claude-opus-5-5", content: [{type: "text", text: $x}], stop_reason: (if $s == "" then null else $s end)}}'
}
if want blocked; then
setup blocked
wt=$root/.claude/worktrees
resume_stubs
resolver
mkdir -p "$sd/phases/17-lambda" "$sd/phases/18-mu"
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
brow() {
  local k=${1%%-*}
  session "proj P$k $tfs" blocked "$wt/$tf-$k" "$(sidn "$k")"
  started "$1" "proj P$k $tfs" "aaaaaa$k"
  tl=$(tlog "$k")
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  human 90 "/forge:run 1 proj tr/feat"
}
bcall() {
  rec --arg t "$(stamp "$1")" --arg m "$2" --arg i "$3" --arg n "$4" \
    '{type: "assistant", timestamp: $t, message: {id: $m, role: "assistant", model: "claude-opus-5-5", content: [{type: "tool_use", id: $i, name: $n, input: {}}], stop_reason: "tool_use"}}'
}
bans() { rec --arg t "$(stamp "$1")" --arg i "$2" '{type: "user", timestamp: $t, message: {role: "user", content: [{type: "tool_result", tool_use_id: $i, content: "ok"}]}, permissionDecision: {decision: "accept", source: "user_temporary"}}'; }
bblob() { rec --arg i "$1" --arg n "$2" '{type: "api-request-blob", message: {role: "assistant", content: [{type: "tool_use", id: $i, name: $n, input: {}}]}}'; }
bsub() {
  tl=$(pdir "$wt/$tf-$1")/$(sidn "$1")/subagents/agent-$2.jsonl
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
}
bstall() {
  local p=$1 k=${1%%-*} want
  want="proj P$k $tfs ($(sidn "$k")) idle 30 min"
  [ "$(stalls "$p")" = 1 ] && [ "$(jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl")" = "$want" ] ||
    fail "$2: one stall event '$want' in phases/$p/events.jsonl: $(cat "$sd/phases/$p/events.jsonl" "$env_dir/out")"
}
brow 07-alpha
bcall 40 msg_07 toolu_07 Bash
bans 39 toolu_07
brow 08-beta
bcall 40 msg_08 toolu_08 AskUserQuestion
brow 09-gamma
bcall 40 msg_09 toolu_09 AskUserQuestion
bans 35 toolu_09
brow 10-delta
said_ok 60
brow 11-eps
bsay 40 msg_11 $'Step 11 passed: the dashboard renders.\n\nneeds input: run step 12 in your browser and tell me what you saw'
brow 12-zeta
bsay 40 msg_12 $'I can rebase onto main or keep the branch as it is. Want me to rebase?\n\n  '
brow 13-eta
bsay 41 msg_13 $'Summary of the run.\nblocked: the staging API key is missing from the env file' ""
bsay 40 msg_13 "Details are in the log above."
brow 14-theta
bsay 40 msg_14 "needs input: pick a branch name"$'\n'"$(jq -rn '[range(50) | "All checks passed."] | join(" ")')"
brow 15-iota
said_ok 60
bsub 15 a15
bcall 35 msg_15 toolu_15 Bash
bblob toolu_15 Bash
brow 16-kappa
said_ok 60
bsub 16 a16
bcall 40 msg_16 toolu_16a Bash
bans 39 toolu_16a
bblob toolu_16b Bash
brow 17-lambda
said_ok 60
brow 18-mu
said_ok 60
api_err 30 rate_limit "$weekly" "$(resets -120)"
turn_done 30
mkdir -p "$(fdir vb)"
session "proj verify tr/vb" blocked "$wt/tr-vb" "$(fsid 41)"
tl=$(pdir "$wt/tr-vb")/$(fsid 41).jsonl
mkdir -p "${tl%/*}"
echo '{}' >"$tl"
human 90 "/forge-verify $root tr/vb"
said_ok 60
jq --arg i aaaaaa10 'map(if .id == $i then .status = "waiting" | .waitingFor = "permission prompt" else .status = "idle" end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
find "$HOME/.claude/projects" -name '*.jsonl' -exec touch -d '30 minutes ago' {} +
chmod 000 "$(tlog 17)"
skips=(08-beta 10-delta 12-zeta 13-eta 15-iota 17-lambda)
idles=(07-alpha 09-gamma 14-theta 16-kappa)
scan
healed 11-eps "needs input: run step 12 in your browser and tell me what you saw" 1 "a blocked session whose end_turn text has a needs input: line is self-healed"
[ "$(stops 11)" = 1 ] || fail "the blocked session of phase 11 is stopped before its self-heal resume: $(cat "$WD_ACTS")"
bstall 07-alpha "a blocked session whose last Bash tool_use has its tool_result"
bstall 09-gamma "a blocked session whose AskUserQuestion has its tool_result"
bstall 14-theta "a blocked session whose needs input: line lies before the last 800 characters of its end_turn text"
bstall 16-kappa "a blocked session whose subagent's tool_use has its tool_result and whose only open tool_use is an api-request-blob copy"
[ "$(fev vb stall)" = 1 ] && [ "$(fmsg vb stall)" = "proj verify tr/vb ($(fsid 41)) idle 30 min" ] ||
  fail "a blocked verify session with no pending question logs one stall event 'proj verify tr/vb ($(fsid 41)) idle 30 min' in features/tr-vb/events.jsonl: $(cat "$(fdir vb)/events.jsonl" "$env_dir/out" 2>/dev/null)"
quiet 08-beta "a blocked session with an unanswered AskUserQuestion"
quiet 10-delta "a blocked session whose row has waitingFor set"
quiet 12-zeta "a blocked session whose end_turn text ends in ? before trailing whitespace"
quiet 13-eta "a blocked session whose end_turn message, gathered across records sharing its message id, has a blocked: line"
quiet 15-iota "a blocked session whose subagent has an unanswered tool_use"
quiet 17-lambda "a blocked session whose transcript jq cannot read"
grep -qxF "forge: cannot read $(tlog 17); skipping proj P17 $tfs" "$env_dir/out" ||
  fail "a blocked session whose transcript jq cannot read is skipped with 'forge: cannot read $(tlog 17); skipping proj P17 $tfs': $(cat "$env_dir/out")"
stopped_by 18-mu "usage limit" "a blocked session stopped by a usage limit"
auto 18-mu 1 "usage limit" "a blocked session stopped by a usage limit whose reset is 120 s past"
for p in "${skips[@]}" "${idles[@]}"; do
  [ "$(stops "${p%%-*}")$(tries "${p%%-*}")$(resumes "$p")" = 000 ] || fail "blocked phase $p is neither stopped nor resumed: $(cat "$WD_ACTS")"
done
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "the scan resumes only the usage-limit stop of phase 18 and the self-heal of phase 11: $(cat "$WD_ACTS")"
[ "$(grep -c '^notify-send ' "$log")" = 1 ] || fail "the first scan sends one notify, the auto-resume of phase 18, and none for a first idle stall, a self-heal or a skipped session: $(grep '^notify-send ' "$log")"
retired 18-mu
jq 'map(if .id == "aaaaaa11" then .pid = 1 | .state = "working" else . end)' "$agents" >"$agents.new" && mv "$agents.new" "$agents"
touch "$(tlog 11)"
scan
for p in "${idles[@]}"; do
  k=${p%%-*}
  [ "$(stalls "$p")" = 2 ] && jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$p/events.jsonl" | grep -qxF "proj P$k $tfs ($(sidn "$k")) idle 30 min; operator notified" ||
    fail "a repeat stall of blocked phase $p logs a second stall ending '; operator notified': $(cat "$sd/phases/$p/events.jsonl")"
  alerted "proj P$k $tfs" "$(sidn "$k")" 30
done
alerted "proj verify tr/vb" "$(fsid 41)" 30
for p in "${skips[@]}"; do quiet "$p" "a second scan of a skipped blocked session"; done
[ "$(grep -c '^notify-send ' "$log")" = 5 ] || fail "the second scan sends one forge: repeat stall per idle blocked session (07, 09, 14, 16, tr/vb) and nothing else: $(grep '^notify-send ' "$log")"
[ ! -s "$WD_ACTS" ] || fail "the second scan stops and resumes nothing: $(cat "$WD_ACTS")"
scan
for p in "${idles[@]}"; do [ "$(stalls "$p")" = 2 ] || fail "a blocked session already alerted for its idle stretch logs no further stall: $(cat "$sd/phases/$p/events.jsonl")"; done
[ "$(fev vb stall)" = 2 ] || fail "a blocked verify session already alerted for its idle stretch logs no further stall: $(cat "$(fdir vb)/events.jsonl")"
! grep -q '^notify-send ' "$log" || fail "a third scan sends no notify: $(grep '^notify-send ' "$log")"
ok blocked
fi

if want self-heal; then
setup self-heal
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORGES=$env_dir/forges.jsonl
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORGES"; do : >"$f"; done
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
jq -cn --arg r "${FORGE_ROOT-unset}" '{root: $r, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
for d in "${XDG_STATE_HOME:-$HOME/.local/state}/forge/${FORGE_ROOT##*/}"/phases/"$2"-*; do rm -f "$d/result.json"; done
echo "forge: phase $2 started"
STUB
chmod +x "$bin/forge"
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
git -C "$root" init -q
git -C "$root" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
hrow() {
  local k=${1%%-*}
  session "proj P$k $tfs" "$2" "$wt/$tf-$k" "$(sidn "$k")"
  started "$1" "proj P$k $tfs" "aaaaaa$k"
  tl=$(tlog "$k")
  mkdir -p "${tl%/*}"
  echo '{}' >"$tl"
  human 90 "/forge-phase $root $k"
}
blocked_result() { jq -n --arg s "$2" '{status: "blocked", summary: $s}' >"$sd/phases/$1/result.json"; }
hrow 07-alpha done
bsay 60 msg_07 $'Sync is clean.\n\nresult: Phase 07 blocked: the staging key is missing'
blocked_result 07-alpha "the staging key is missing"
hrow 08-beta done
bsay 60 msg_08 $'T2 is committed.\n\nneeds input: pick the database name'
hrow 09-gamma done
bsay 60 msg_09 $'T3 ran its tests.\nfailed: tests/other.test.sh expects the old prompt'
hrow 10-delta done
bsay 60 msg_10 "blocked: phase 10 already has a running session proj P10 $tfs"
blocked_result 10-delta "phase 10 already has a running session proj P10 $tfs"
hrow 11-eps done
bsay 60 msg_11 "result: Phase 11 blocked: no network"
blocked_result 11-eps "no network"
for i in 1 2 3; do logged 11-eps resume "self-heal $i/3 on 'blocked: no network'; resumed proj P11 $tfs with claude --bg --resume $(sidn 11)"; done
jq -n '{track: "tr", feature: "feat", number: "12", slug: "zeta", goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/12-zeta/spec.json"
hrow 15-iota done
bsay 60 msg_15 "result: Phase 15 blocked: the fixture host is gone"
blocked_result 15-iota "the fixture host is gone"
touch -d '8 days ago' "$sd/phases/15-iota/result.json"
mkdir -p "$sd/phases/16-kappa" "$sd/archive/tr-arc"
jq -n '{track: "tr", feature: "arc", number: "16", slug: "kappa", goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/16-kappa/spec.json"
session "proj P16 tr/arc" done "$wt/tr-arc-16" "$(sidn 16)"
started 16-kappa "proj P16 tr/arc" "aaaaaa16"
tl=$(pdir "$wt/tr-arc-16")/$(sidn 16).jsonl
mkdir -p "${tl%/*}"
echo '{}' >"$tl"
human 90 "/forge-phase $root 16"
bsay 60 msg_16 "result: Phase 16 blocked: the operator dropped this phase"
blocked_result 16-kappa "the operator dropped this phase"
started 12-zeta "proj P12 $tfs" aaaaaa12
blocked_result 12-zeta "the implementer needs a login"
hrow 13-eta stopped
nopid 13
bsay 60 msg_13 "result: Phase 13 blocked: lost the lock"
blocked_result 13-eta "lost the lock"
hrow 14-theta done
bsay 60 msg_14 $'All tests failed: see the log.\n\nresult: Phase 14 done: all green'
jq -n '{status: "done", summary: "all green"}' >"$sd/phases/14-theta/result.json"
find "$HOME/.claude/projects" -name '*.jsonl' -exec touch -d '30 minutes ago' {} +
scan
healed 07-alpha "blocked: the staging key is missing" 1 "a done session whose result.json is blocked"
[ "$(stops 07)" = 1 ] || fail "the done row of phase 07 is stopped before its self-heal resume: $(cat "$WD_ACTS")"
healed 08-beta "needs input: pick the database name" 1 "a done session whose last turn ended on a needs input: line"
healed 09-gamma "failed: tests/other.test.sh expects the old prompt" 1 "a done session whose last turn ended on a failed: line"
healed 13-eta "blocked: lost the lock" 1 "a stopped session whose result.json is blocked"
[ "$(stops 13)" = 0 ] || fail "a stopped row with no pid is resumed without a claude stop: $(cat "$WD_ACTS")"
untouched 10-delta "a blocked result whose summary starts 'phase 10 already has a running session'"
[ -f "$sd/phases/10-delta/result.json" ] || fail "the peer-session blocked result of phase 10 is kept"
untouched 14-theta "a done result whose text has failed: inside a line"
untouched 15-iota "a blocked result older than 7 days"
[ -f "$sd/phases/15-iota/result.json" ] || fail "the stale blocked result of phase 15 is kept"
untouched 16-kappa "a blocked phase of an archived feature"
[ -f "$sd/phases/16-kappa/result.json" ] || fail "the blocked result of archived phase 16 is kept"
[ "$(tries 11)" = 0 ] && [ "$(resumes 11-eps)" = 3 ] || fail "phase 11, self-healed 3 times already, is not resumed again: $(cat "$WD_ACTS" "$sd/phases/11-eps/events.jsonl")"
[ "$(grep -c '^notify-send ' "$log")" = 1 ] && grep -qxF "notify-send --|forge: self-heal gave up|proj phase 11-eps: proj P11 $tfs still stops after 3 self-heals; last line: blocked: no network" "$log" ||
  fail "the scan sends one notify, 'forge: self-heal gave up' 'proj phase 11-eps: proj P11 $tfs still stops after 3 self-heals; last line: blocked: no network': $(grep '^notify-send ' "$log")"
[ "$(jq -rs 'last | .step + " " + .message' "$sd/phases/11-eps/events.jsonl")" = "stall proj P11 $tfs ($(sidn 11)) stops on 'blocked: no network' after 3 self-heals; gave up" ] ||
  fail "giving up logs one stall event ending '; gave up' in phases/11-eps/events.jsonl: $(cat "$sd/phases/11-eps/events.jsonl")"
[ -f "$sd/phases/11-eps/result.json" ] || fail "giving up keeps the blocked result.json of phase 11"
[ "$(jq -s 'map(select(.args[0] == "resume" and .args[1] == "12")) | length' "$WD_FORGES")" = 1 ] && jq -e --arg r "$root" 'select(.args[0] == "resume") | .root == $r' "$WD_FORGES" >/dev/null ||
  fail "phase 12, blocked with its session gone, runs FORGE_ROOT=$root forge resume 12 once: $(cat "$WD_FORGES" "$env_dir/out")"
[ "$(rmsg 12-zeta)" = "self-heal 1/3 on 'blocked: the implementer needs a login'; proj P12 $tfs is gone, resumed phase 12 with forge resume" ] ||
  fail "the resume event of phase 12 names the self-heal, the gone session and forge resume: $(cat "$sd/phases/12-zeta/events.jsonl")"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 4 ] || fail "the scan resumes phases 07, 08, 09 and 13 through claude --bg --resume and nothing else: $(cat "$WD_ACTS")"
jq 'map(if IN(.id; "aaaaaa08", "aaaaaa09", "aaaaaa13") then .pid = 1 | .state = "working" else . end)' "$agents" >"$agents.new" && mv "$agents.new" "$agents"
for k in 08 09 13; do touch "$(tlog "$k")"; done
again07() {
  tl=$(tlog 07)
  jq --arg i aaaaaa07 'map(if .id == $i then .pid = 1 | .state = "done" else . end)' "$agents" >"$agents.new" && mv "$agents.new" "$agents"
  bsay 0 "msg_07_$1" "failed: the staging key is still missing (try $1)"
  touch -d '1 minute ago' "$tl"
  : >"$WD_FORGES"
  scan
  [ ! -s "$WD_FORGES" ] || fail "the scan of try $1 runs no forge resume: phase 12 has no result.json any more: $(cat "$WD_FORGES")"
}
for i in 2 3; do
  again07 "$i"
  healed 07-alpha "failed: the staging key is still missing (try $i)" "$i" "self-heal $i of phase 07"
  ! grep -q '^notify-send ' "$log" || fail "self-heal $i of phase 07 sends no notify: $(grep '^notify-send ' "$log")"
  [ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] || fail "the scan of try $i resumes phase 07 only: $(cat "$WD_ACTS")"
done
again07 4
[ "$(tries 07)" = 0 ] && [ "$(resumes 07-alpha)" = 3 ] || fail "a fourth stop of phase 07 is not resumed: $(cat "$WD_ACTS" "$sd/phases/07-alpha/events.jsonl")"
grep -qxF "notify-send --|forge: self-heal gave up|proj phase 07-alpha: proj P07 $tfs still stops after 3 self-heals; last line: failed: the staging key is still missing (try 4)" "$log" ||
  fail "the fourth stop of phase 07 sends one 'forge: self-heal gave up' naming its last line: $(grep '^notify-send ' "$log")"
[ "$(grep -c '^notify-send ' "$log")" = 1 ] || fail "the fourth stop of phase 07 sends one notify: $(grep '^notify-send ' "$log")"
scan
! grep -q '^notify-send ' "$log" || fail "a scan after giving up on phase 07 sends nothing more: $(grep '^notify-send ' "$log")"
[ "$(jq -s 'map(select(.step == "stall" and (.message | endswith("; gave up")))) | length' "$sd/phases/07-alpha/events.jsonl")" = 1 ] ||
  fail "giving up on phase 07 logs one gave-up stall: $(cat "$sd/phases/07-alpha/events.jsonl")"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'fix the blocker yourself and continue phase <N> from where it stopped' "$h" || fail "watchdog.txt documents the self-heal prompt"
grep -qF 'self-heal' "$h" || fail "watchdog.txt documents the self-heal resume events and cap"
grep -qF 'already has a running session' "$h" || fail "watchdog.txt documents the peer-session blocked result that is never resumed"
ok self-heal
fi

if want result-stop; then
setup result-stop
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
for k in 12 07 08 09 10 11; do
  p=$(basename "$sd"/phases/"$k"-*)
  stop_row "$p" working
done
retired 07-alpha 08-beta 09-gamma 11-eps 12-zeta
echo aaaaaa12 >>"$WD_STOPFAIL"
rowpid 08
proc 2081 1008 1008 /bin/bash -c "$snap"
starts 09 bzui28sfr
output "$wt/$tf-09" "$(sidn 09)" bzui28sfr 2
for k in 07 08 09 10 12; do touch -d '30 minutes ago' "$(tlog "$k")"; done
touch -d '7 minutes ago' "$(tlog 11)"
rsmsg() { jq -rs 'map(select(.step == "stall")) | last | .message' "$sd/phases/$1/events.jsonl"; }
: >"$log"
: >"$WD_ACTS"
: >"$WD_RESUMES"
(cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" FORGE_STALL_MIN=5 "$forge" watchdog) >"$env_dir/so" 2>"$env_dir/err" ||
  fail "forge watchdog exits 0: $(cat "$env_dir/so" "$env_dir/err")"
cat "$env_dir/so" "$env_dir/err" >"$env_dir/out"
want="proj P07 $tfs ($(sidn 07)) idle 30 min; stopped: phase has result.json"
[ "$(stops 07)" = 1 ] || fail "a working phase session idle 30 min whose phase has result.json is stopped once with claude stop aaaaaa07: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(stalls 07-alpha)" = 1 ] && [ "$(rsmsg 07-alpha)" = "$want" ] ||
  fail "the stopped session of 07-alpha logs one stall event '$want': $(cat "$sd/phases/07-alpha/events.jsonl")"
! grep '^notify-send ' "$log" | grep -qF -e "proj P07 $tfs" -e "$(sidn 07)" || fail "stopping an idle session whose phase has result.json sends no notify: $(grep '^notify-send ' "$log")"
[ "$(stops 08)" = 0 ] || fail "a session whose phase has result.json but which has a running Bash process 2081 is not stopped: $(cat "$WD_ACTS")"
grep '^forge: ' "$env_dir/out" | grep -F "proj P08 $tfs" | grep -qF 2081 ||
  fail "a session kept alive by its running Bash process 2081 gets a forge: line naming it and the process: $(cat "$env_dir/out")"
[ "$(stops 09)" = 0 ] || fail "a session whose phase has result.json but whose background task bzui28sfr is in flight is not stopped: $(cat "$WD_ACTS")"
grep -qxF "forge: proj P09 $tfs ($(sidn 09)) idle 30 min with background task bzui28sfr in flight; no stall" "$env_dir/err" ||
  fail "a session kept alive by its in-flight background task gets a forge: line on stderr naming it and the task: $(cat "$env_dir/err")"
! grep -qF bzui28sfr "$env_dir/so" || fail "the in-flight line of a finished phase's session is not on stdout: $(cat "$env_dir/so")"
[ "$(stops 10)" = 0 ] || fail "a session whose phase has no result.json is not stopped: $(cat "$WD_ACTS")"
stalled 10-delta "proj P10 $tfs" "$(sidn 10)" 30
[ "$(stops 11)" = 0 ] || fail "a session idle 7 min, past FORGE_STALL_MIN=5 but under 10 min, is not stopped though its phase has result.json: $(cat "$WD_ACTS")"
[ "$(stops 12)" = 1 ] || fail "phase 12's session, whose phase has result.json, gets one claude stop aaaaaa12: $(cat "$WD_ACTS")"
grep -qxF "forge: cannot stop proj P12 $tfs: couldn't confirm aaaaaa12 was stopped — the background service may be restarting. Try again in a moment." "$env_dir/out" ||
  fail "a failing claude stop prints 'forge: cannot stop proj P12 $tfs: <its stderr>': $(cat "$env_dir/out")"
! grep -qF 'stopped: phase has result.json' "$sd/phases/12-zeta/events.jsonl" 2>/dev/null ||
  fail "a failed claude stop logs no stopped event: $(cat "$sd/phases/12-zeta/events.jsonl")"
[ "$(grep -c '^stop ' "$WD_ACTS")" = 2 ] || fail "the scan runs claude stop on phases 07 and 12 only: $(cat "$WD_ACTS")"
[ ! -s "$WD_RESUMES" ] || fail "stopping a finished phase's session resumes nothing: $(cat "$WD_RESUMES")"
[ "$(grep -c '^notify-send ' "$log")" = 0 ] || fail "a first scan of idle sessions sends no notify: $(grep '^notify-send ' "$log")"
FORGE_STALL_MIN=5 scan
[ "$(stops 07)" = 0 ] || fail "a stopped session whose phase has result.json is not stopped again: $(cat "$WD_ACTS")"
[ "$(stalls 07-alpha)" = 1 ] || fail "a stopped session whose phase has result.json logs no further event: $(cat "$sd/phases/07-alpha/events.jsonl")"
! grep '^notify-send ' "$log" | grep -qF -e "proj P07 $tfs" -e "$(sidn 07)" || fail "a later scan of the stopped session sends no notify: $(grep '^notify-send ' "$log")"
ok result-stop
fi

if want sub-repo; then
setup sub-repo
wt=$root/app/.claude/worktrees
resume_stubs
resolver
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORK=$env_dir/fork WD_QUIET=$env_dir/quiet WD_LOST=$env_dir/lost
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORK" "$WD_QUIET" "$WD_LOST"; do : >"$f"; done
printf '600.42 1234.56\n' >"$FORGE_PROC_ROOT/uptime"
sub=proj/app ow=$env_dir/Projects/other/app/.claude/worktrees rw=$root/.claude/worktrees
session "$sub P07 $tfs" working "$wt/$tf-07" "$(sidn 07)"
transcript "$wt/$tf-07" "$(sidn 07)" 30
session "$sub verify $tfs" working "$wt/$tf" cccccccc-0000-4000-8000-00000000000v
transcript "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 45
session "$sub P08 $tfs" working "$ow/$tf-08" "$(sidn 08)"
transcript "$ow/$tf-08" "$(sidn 08)" 30 "$root 08"
session "proj P09 $tfs" working "$rw/$tf-09" "$(sidn 09)"
transcript "$rw/$tf-09" "$(sidn 09)" 30
session "$sub P10 $tfs" stopped "$wt/$tf-10" "$(sidn 10)"
started 10-delta "$sub P10 $tfs" aaaaaa10
tl=$(tlog 10)
mkdir -p "${tl%/*}"
echo '{}' >"$tl"
human 90 "/forge:run 1 proj tr/feat"
said_ok 60
api_err 10 server_error "$eai"
turn_done 10
touch -d '3 minutes ago' "$tl"
printf '%s %s\n' "$(sidn 10)" "$(fk 10)" >>"$WD_FORK"
echo "$(sidn 10)" >>"$WD_QUIET"
ended_at "$sub P11 $tfs" "$wt/$tf-11" "$(sidn 11)" 30
started 11-eps "$sub P11 $tfs" aaaaaa11
jq 'map(if .state == "working" then . else del(.pid, .status) end)' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
scan
! grep -q skipping "$env_dir/out" || fail "no <root>/<repo> session is skipped as unseen: $(cat "$env_dir/out")"
stalled 07-alpha "$sub P07 $tfs" "$(sidn 07)" 30
featured "$sub verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
stalled 08-beta "$sub P08 $tfs" "$(sidn 08)" 30
stalled 09-gamma "proj P09 $tfs" "$(sidn 09)" 30
got=$(jq -c --arg s "$(sidn 10)" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
[ "$(printf '%s\n' "$got" | grep -c .)" = 1 ] || fail "the stopped $sub P10 $tfs row is auto-resumed once with claude --bg --resume $(sidn 10): $(cat "$WD_RESUMES" "$env_dir/out")"
printf '%s\n' "$got" | jq -e --arg c "$wt/$tf-10" --arg s "$(sidn 10)" --arg nm "$sub P10 $tfs" --arg ls "$lsj" \
  '.cwd == $c and .args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, "forge watchdog: API error server_error cleared; continue phase 10 from where it stopped"]' >/dev/null ||
  fail "the $sub P10 $tfs row resumes from $wt/$tf-10 as claude --bg --resume $(sidn 10) -n '$sub P10 $tfs' 'forge watchdog: API error server_error cleared; continue phase 10 from where it stopped', got $got"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "the sub-repo scan resumes phases 10 and 11 only: $(cat "$WD_ACTS")"
want="auto-resume 1/5 after API error server_error; resumed $sub P10 $tfs with claude --bg --resume $(sidn 10); now session bbbbbb10"
[ "$(rmsg 10-delta)" = "$want" ] || fail "the resume event of 10-delta is '$want', got '$(rmsg 10-delta)'"
[ "$(lstart 10-delta)" = "{\"step\":\"start\",\"message\":\"$sub P10 $tfs\",\"offset\":70,\"session\":\"bbbbbb10\"}" ] ||
  fail "the copy found under the full listed name $sub P10 $tfs is logged as a start of bbbbbb10: $(cat "$sd/phases/10-delta/events.jsonl")"
want="notify-send --|forge: auto-resume|proj phase 10-delta: $sub P10 $tfs stopped by API error server_error; resume 1/5"
[ "$(grep '^notify-send ' "$log" | grep -F 'phase 10-delta:' || true)" = "$want" ] || fail "one forge notify '${want#notify-send --|}' naming the project root, got: $(grep '^notify-send ' "$log")"
got=$(jq -c --arg s "$(sidn 11)" 'select(.args | index("--resume") as $i | $i != null and .[$i + 1] == $s)' "$WD_RESUMES")
printf '%s\n' "$got" | jq -e --arg c "$wt/$tf-11" --arg s "$(sidn 11)" --arg nm "$sub P11 $tfs" --arg ls "$lsj" \
  '.cwd == $c and .args == ["--bg", "--resume", $s, "-n", $nm, "--settings", $ls, "forge watchdog: ended turn cleared; continue phase 11 from where it stopped"]' >/dev/null ||
  fail "the done $sub P11 $tfs row with no cause resumes from $wt/$tf-11 as claude --bg --resume $(sidn 11) -n '$sub P11 $tfs' 'forge watchdog: ended turn cleared; continue phase 11 from where it stopped', got $got"
want="auto-resume 1/5 after ended turn; resumed $sub P11 $tfs with claude --bg --resume $(sidn 11)"
[ "$(rmsg 11-eps)" = "$want" ] || fail "the resume event of 11-eps is '$want', got '$(rmsg 11-eps)'"
want="notify-send --|forge: auto-resume|proj phase 11-eps: $sub P11 $tfs stopped by ended turn; resume 1/5"
[ "$(grep '^notify-send ' "$log" | grep -F 'phase 11-eps:' || true)" = "$want" ] || fail "one forge notify '${want#notify-send --|}' naming the project root, got: $(grep '^notify-send ' "$log")"
[ "$(ends 11-eps)" = 1 ] || fail "the ended $sub P11 $tfs row logs one ended-turn stall: $(cat "$sd/phases/11-eps/events.jsonl")"
jq --arg n "$sub P10 $tfs" --arg m "$sub P11 $tfs" 'map(select(.name != $n and .name != $m))' "$agents" >"$agents.new"
mv "$agents.new" "$agents"
age "$sd/phases/07-alpha/events.jsonl" 10
age "$sd/features/$tf/events.jsonl" 10
scan
alerted "$sub P07 $tfs" "$(sidn 07)" 30
alerted "$sub verify $tfs" cccccccc-0000-4000-8000-00000000000v 45
unset WD_FORK WD_QUIET WD_LOST
ok sub-repo
fi

if want path; then
setup path
unset FNM_DIR
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_PATH=$env_dir/path
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
landed 05-pre
parked 07-alpha "proj P07 $tfs" stopped "wait 05" 31 "proj P07 $tfs"
nopid 07
fnm=$HOME/.local/share/fnm cargo=$HOME/.cargo/bin base=$bin:$PATH
mkdir -p "$fnm/aliases/default/bin" "$cargo"
pathed() {
  local what=$1 want=$2
  shift 2
  : >"$WD_PATH"
  logged 07-alpha park "wait 05"
  (cd "$env_dir" && timeout 60 env "$@" "$forge" watchdog) >"$env_dir/out" 2>&1 || fail "$what: forge watchdog exits 0: $(cat "$env_dir/out")"
  [ "$(grep -c . "$WD_PATH")" = 1 ] || fail "$what: phase 07 is resumed once by claude --bg, logged PATHs: $(cat "$WD_PATH"), out: $(cat "$env_dir/out")"
  [ "$(cat "$WD_PATH")" = "$want" ] || fail "$what: the resumed claude --bg runs with PATH '$want', got '$(cat "$WD_PATH")'"
}
pathed "fnm's default alias bin, fnm and ~/.cargo/bin in front in that order" "$fnm/aliases/default/bin:$fnm:$cargo:$base" PATH="$base"
f2=$env_dir/fnm2
mkdir -p "$f2/aliases/default/bin"
pathed "FNM_DIR moving the fnm dirs" "$f2/aliases/default/bin:$f2:$cargo:$base" FNM_DIR="$f2" PATH="$base"
f3=$env_dir/fnm3
mkdir -p "$f3"
pathed "an FNM_DIR without aliases/default/bin" "$f3:$cargo:$base" FNM_DIR="$f3" PATH="$base"
pathed "a missing FNM_DIR" "$cargo:$base" FNM_DIR="$env_dir/nofnm" PATH="$base"
rmdir "$cargo"
pathed "a missing ~/.cargo/bin" "$fnm/aliases/default/bin:$fnm:$base" PATH="$base"
mkdir -p "$cargo"
pathed "dirs already on PATH" "$fnm/aliases/default/bin:$base:$cargo:$fnm" PATH="$base:$cargo:$fnm"
pathed "every dir already on PATH" "$fnm/aliases/default/bin:$cargo:$fnm:$base" PATH="$fnm/aliases/default/bin:$cargo:$fnm:$base"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'aliases/default/bin' "$h" && grep -qF FNM_DIR "$h" && grep -qF '.cargo/bin' "$h" || fail "watchdog.txt documents the PATH the scan sets: FNM_DIR, its aliases/default/bin and ~/.cargo/bin"
unset WD_PATH
ok path
fi

if want tools; then
setup tools
unset FNM_DIR
wt=$root/.claude/worktrees
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 1
lean= i=0
IFS=: read -ra ds <<<"$PATH"
for d in "${ds[@]}"; do
  [ -n "$d" ] || continue
  if [ -e "$d/node" ] || [ -e "$d/cargo" ]; then
    i=$((i + 1))
    mkdir -p "$env_dir/lean$i"
    for x in "$d"/*; do case ${x##*/} in node | cargo) ;; *) ln -s "$x" "$env_dir/lean$i/" ;; esac; done
    d=$env_dir/lean$i
  fi
  lean+=${lean:+:}$d
done
wp=$bin:$lean
mkdir -p "$root/sub/.forge" "$root/docs/.forge"
tn=$root/.forge/TESTING.md tc=$root/sub/.forge/TESTING.md tp=$root/docs/.forge/TESTING.md
cat >"$tn" <<'EOF'
# Testing

## Layout
- Rust helpers build with cargo; run `cargo build` by hand.

## Commands
- All tests: `pnpm test`
- Test: `pnpm vitest run {test}`
- Lint: `npx eslint .`
Run cargo fmt before committing.

## Gates
- Build: `cargo build --release`
EOF
cat >"$tc" <<'EOF'
# Testing

## Commands
- All tests: run `cargo test` from the repo
EOF
cat >"$tp" <<'EOF'
# Testing

## Layout
- Tests run under node and cargo.

## Commands
- All tests: `make check`
Some suites need node, npm, pnpm, yarn or cargo installed.
EOF
tools() {
  (cd "$env_dir" && timeout 60 env PATH="$wp" "$forge" watchdog) >"$env_dir/out" 2>"$env_dir/err" ||
    fail "$1: forge watchdog exits 0 after a tool warning: $(cat "$env_dir/out" "$env_dir/err")"
  ! grep -qF 'which is not on the watchdog PATH' "$env_dir/out" || fail "$1: the tool warning goes to stderr only: $(cat "$env_dir/out")"
  grep -F 'which is not on the watchdog PATH' "$env_dir/err" | sort >"$env_dir/warns" || :
}
tools "node and cargo missing"
printf '%s\n' "forge: warning: $tc runs cargo, which is not on the watchdog PATH ($wp)" \
  "forge: warning: $tn runs node, which is not on the watchdog PATH ($wp)" | sort >"$env_dir/want"
cmp -s "$env_dir/want" "$env_dir/warns" ||
  fail "a pnpm/npx Commands line with no node on the computed PATH warns once naming $tn and node, a cargo Commands line with no cargo warns once naming $tc and cargo, and prose or other sections warn nothing: want $(cat "$env_dir/want"), got $(cat "$env_dir/warns"), stderr: $(cat "$env_dir/err")"
! grep -q '^notify-send ' "$log" || fail "the tool warning sends no notification: $(grep '^notify-send ' "$log")"
grep -q '^claude agents' "$log" || fail "the scan goes on after a tool warning: $(cat "$log")"
tools "a second scan"
cmp -s "$env_dir/want" "$env_dir/warns" || fail "each scan warns once per file and tool: want $(cat "$env_dir/want"), got $(cat "$env_dir/warns")"
fnm=$HOME/.local/share/fnm cargo=$HOME/.cargo/bin
mkdir -p "$fnm/aliases/default/bin" "$cargo"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fnm/aliases/default/bin/node"
printf '#!/usr/bin/env bash\nexit 0\n' >"$cargo/cargo"
chmod +x "$fnm/aliases/default/bin/node" "$cargo/cargo"
tools "node under fnm's default alias and cargo under ~/.cargo/bin"
[ ! -s "$env_dir/warns" ] || fail "with node and cargo on the computed PATH nothing is printed: $(cat "$env_dir/warns")"
rm "$fnm/aliases/default/bin/node"
tools "only cargo present"
[ "$(cat "$env_dir/warns")" = "forge: warning: $tn runs node, which is not on the watchdog PATH ($fnm/aliases/default/bin:$fnm:$cargo:$wp)" ] ||
  fail "with cargo present and node missing only $tn warns, naming node and the computed PATH: $(cat "$env_dir/warns")"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'TESTING.md' "$h" || fail "watchdog.txt documents the TESTING.md tool warning"
ok tools
fi

unset FORGE_TEST_SLOT_HELD FORGE_TEST_SLOTS_MAX FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
trap 'kill $(jobs -p) 2>/dev/null || :; rm -rf "$tmp"' EXIT
forged() { jq -s --arg n "$1" 'map(select(.args[0] == "resume" and (.args[1] | tonumber) == ($n | tonumber))) | length' "$WD_FORGES"; }
waiting() {
  untouched 07-alpha "$1"
  untouched 08-beta "$1"
  [ "$(forged 12)$(resumes 12-zeta)" = 00 ] || fail "$1: phase 12, parked on wait 09 with its session gone, runs no forge resume: $(cat "$WD_FORGES" "$sd/phases/12-zeta/events.jsonl")"
}
malformed() {
  local n
  for n in 10 11 16; do
    grep -qE "^forge: .+; proj P$n $tfs stays parked$" "$env_dir/out" ||
      fail "$1: phase $n, parked on $(jq -rs 'map(select(.step == "park")) | last | .message' "$sd/phases/$n-"*/events.jsonl), prints 'forge: <what failed>; proj P$n $tfs stays parked': $(cat "$env_dir/out")"
  done
  grep -qF '<track>/<feature>' "$env_dir/out" && grep -qF 'branch <name>' "$env_dir/out" || fail "$1: the malformed wait ref warning names the <track>/<feature> and branch <name> forms: $(cat "$env_dir/out")"
  untouched 10-delta "$1: a malformed wait ref"
  untouched 11-eps "$1: a wait ref naming an unreadable root"
  untouched 16-kappa "$1: a malformed feature wait ref"
}
feature_wait() {
  untouched 13-eta "$1: a wait on a feature the track JSON does not list as shipped"
  [ "$(forged 15)$(resumes 15-iota)" = 00 ] || fail "$1: phase 15, parked on wait branch topic with its session gone, runs no forge resume: $(cat "$WD_FORGES" "$sd/phases/15-iota/events.jsonl")"
}

if want wait-park; then
setup wait-park
unset FORGE_TEST_SLOT_HELD FORGE_TEST_SLOTS FORGE_TEST_SLOTS_MAX FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORGES=$env_dir/forges.jsonl
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORGES"; do : >"$f"; done
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
jq -cn --arg r "${FORGE_ROOT-unset}" '{root: $r, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
echo "forge: phase $2 started"
STUB
chmod +x "$bin/forge"
other=$env_dir/Projects/other
so=$HOME/.local/state/forge/other
mkdir -p "$other/.forge/tracks" "$so/phases/05-far" "$sd/phases/05-near"
printf '%s\n' "$other" >"$so/root"
wspec() { jq -n --arg n "${2%%-*}" --arg s "${2#*-}" '{track: "tr", feature: "feat", number: $n, slug: $s, goal: "g", spec: [], requirements: [], depends: []}' >"$1/phases/$2/spec.json"; }
wbranch() {
  local c
  c=$(git -C "$1" -c user.name=t -c user.email=t@t commit-tree -p "forge/$tf" -m "p$2" "forge/$tf^{tree}")
  git -C "$1" branch "forge/$tf-$2" "$c"
}
wmerge() {
  local c
  c=$(git -C "$1" -c user.name=t -c user.email=t@t commit-tree -p "forge/$tf" -p "forge/$tf-$2" -m "Merge branch 'forge/$tf-$2'" "forge/$tf^{tree}")
  git -C "$1" branch -f "forge/$tf" "$c"
}
for r in "$root" "$other"; do git -C "$r" init -q -b main && gc "$r" --allow-empty -m init && git -C "$r" branch "forge/$tf" HEAD && wbranch "$r" 05; done
wbranch "$root" 09
wspec "$sd" 05-near
wspec "$sd" 09-gamma
wspec "$so" 05-far
jq -n '{track: "tr", goal: "g", status: "open", features: [{feature: "feat2", delivers: "d", depends: []}], shipped: []}' >"$root/.forge/tracks/tr.json"
parked 13-eta "proj P13 $tfs" stopped "wait tr/feat2" 37 "proj P13 $tfs"
nopid 13
parked 14-theta "proj P14 $tfs" stopped "wait branch topic" 38 "proj P14 $tfs"
nopid 14
parked 16-kappa "proj P16 $tfs" stopped "wait tr/feat2/x" 39 "proj P16 $tfs"
nopid 16
jq -n '{track: "tr", feature: "feat", number: "15", slug: "iota", goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/15-iota/spec.json"
started 15-iota "proj P15 $tfs" aaaaaa15
logged 15-iota park "wait branch topic"
parked 07-alpha "proj P07 $tfs" stopped "wait 09" 31 "proj P07 $tfs"
nopid 07
parked 08-beta "proj P08 $tfs" stopped "wait $other:05" 32 "proj P08 $tfs"
nopid 08
parked 10-delta "proj P10 $tfs" stopped "wait nine" 34 "proj P10 $tfs"
nopid 10
parked 11-eps "proj P11 $tfs" stopped "wait $env_dir/no-such:05" 35 "proj P11 $tfs"
nopid 11
jq -n '{track: "tr", feature: "feat", number: "12", slug: "zeta", goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/12-zeta/spec.json"
started 12-zeta "proj P12 $tfs" aaaaaa12
logged 12-zeta park "wait 09"

run
waiting "with no result.json for phases 09 or 05 anywhere"
malformed "the first scan"
feature_wait "the first scan"
untouched 14-theta "a wait on a branch the repo does not have"
grep -qE "^forge: .*branch topic.*; proj P14 $tfs stays parked$" "$env_dir/out" || fail "a wait on a missing branch warns naming it and stays parked: $(cat "$env_dir/out")"
git -C "$root" branch topic
git -C "$root" checkout -q topic && gc "$root" --allow-empty -m topic && git -C "$root" checkout -q main
run
feature_wait "the scan with branch topic unmerged"
untouched 14-theta "a wait on a branch that is not an ancestor of main"

jq -n '{status: "done", summary: "s"}' >"$sd/phases/09-gamma/result.json"
jq -n '{status: "done", summary: "s"}' >"$so/phases/05-far/result.json"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/05-near/result.json"
wmerge "$root" 05
run
waiting "with phase 09's and the other root's phase 05 S result.json done but their branches unmerged, and only this root's phase 05 merged"
malformed "the second scan"
[ ! -e "$root/.forge/phases" ] && [ ! -e "$other/.forge/phases" ] || fail "a wait park reads S result.json and branches and writes no repo's .forge/phases"

wmerge "$root" 09
run
woke 07-alpha "wait 09" "proj P07 $tfs" 31
[ "$(stops 07)" = 0 ] || fail "a stopped session parked on wait 09 is resumed without a stop: $(cat "$WD_ACTS")"
untouched 08-beta "a wait on the other root's phase 05 while only this root's phases 05 and 09 are merged"
[ "$(forged 12)" = 1 ] || fail "phase 12, parked on wait 09 with its session gone, runs forge resume 12 once phase 09 is done and merged: $(cat "$WD_FORGES" "$env_dir/out")"
jq -e --arg r "$root" 'select(.args[0] == "resume") | .root == $r' "$WD_FORGES" >/dev/null || fail "forge resume 12 runs with FORGE_ROOT=$root: $(cat "$WD_FORGES")"
m12=$(jq -rs 'last | select(.step == "resume") | .message' "$sd/phases/12-zeta/events.jsonl")
[[ $m12 == "wait 09 cleared; "*"forge resume"* ]] || fail "the resume event of phase 12 is its last event and starts 'wait 09 cleared; ' naming forge resume: '$m12'"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] || fail "the scan after phase 09's merge resumes phase 07 only through claude --bg --resume: $(cat "$WD_ACTS")"
malformed "the third scan"

: >"$WD_ACTS"
: >"$WD_RESUMES"
: >"$WD_FORGES"
wmerge "$other" 05
run
woke 08-beta "wait $other:05" "proj P08 $tfs" 32
[ "$(tries 07)$(resumes 07-alpha)" = 01 ] || fail "phase 07, whose last event is no longer park, is not resumed again: $(cat "$WD_ACTS")"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] || fail "the scan after the other root's phase 05 merge resumes phase 08 only: $(cat "$WD_ACTS")"
[ "$(forged 12)" = 0 ] || fail "phase 12, no longer parked, runs no forge resume again: $(cat "$WD_FORGES")"
malformed "the fourth scan"
feature_wait "the fourth scan"
untouched 14-theta "the fourth scan: branch topic still unmerged"
: >"$WD_ACTS"
: >"$WD_RESUMES"
: >"$WD_FORGES"
jq '.shipped += [{feature: "feat2", phases: ["01"], date: "2026-10-29"}]' "$root/.forge/tracks/tr.json" >"$env_dir/tr.json" && mv "$env_dir/tr.json" "$root/.forge/tracks/tr.json"
git -C "$root" -c user.name=t -c user.email=t@t merge -q --no-ff -m "merge topic" topic
run
woke 13-eta "wait tr/feat2" "proj P13 $tfs" 37
woke 14-theta "wait branch topic" "proj P14 $tfs" 38
[ "$(forged 15)" = 1 ] || fail "phase 15, parked on wait branch topic with its session gone, runs forge resume 15 once topic is merged into main: $(cat "$WD_FORGES" "$env_dir/out")"
m15=$(jq -rs 'last | select(.step == "resume") | .message' "$sd/phases/15-iota/events.jsonl")
[[ $m15 == "wait branch topic cleared; "*"forge resume"* ]] || fail "the resume event of phase 15 starts 'wait branch topic cleared; ' naming forge resume: '$m15'"
[ "$(grep -c '^resume ' "$WD_ACTS")" = 2 ] || fail "the scan after the ship and the merge resumes phases 13 and 14 only: $(cat "$WD_ACTS")"
malformed "the fifth scan"
h=$repo/bin/forge.d/help/event.txt
grep -qF '<track>/<feature>' "$h" && grep -qF 'branch <name>' "$h" || fail "event.txt documents the <track>/<feature> and branch <name> wait refs"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'shipped' "$h" && grep -qF 'ancestor' "$h" || fail "watchdog.txt documents how the feature and branch wait refs clear"
ok wait-park
fi

if want park-refused; then
setup park-refused
unset FORGE_TEST_SLOT_HELD FORGE_TEST_SLOTS FORGE_TEST_SLOTS_MAX FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL"; do : >"$f"; done
landed
parked 07-alpha "proj P07 $tfs" stopped "wait 05" 31 "proj P07 $tfs"
nopid 07
logged 07-alpha refused "phase 07 not started: phase 07 has a live session proj P07 $tfs; not starting another"
logged 07-alpha stall "launch refused: phase 07 not started: phase 07 has a live session proj P07 $tfs; not starting another"
parked 08-beta "proj P08 $tfs" stopped "wait 05" 32 "proj P08 $tfs"
nopid 08
logged 08-beta refused "phase 08 not started: the worktree has uncommitted changes"
run
untouched 07-alpha "phase 05 not landed"
untouched 08-beta "phase 05 not landed"
! grep -qF 'turn ended with no result' "$log" "$sd/phases/07-alpha/events.jsonl" "$sd/phases/08-beta/events.jsonl" ||
  fail "a listed session parked before a refused resume is still parked, not alerted as an ended turn: $(cat "$log" "$sd"/phases/0[78]-*/events.jsonl)"
landed 05-pre
run
woke 07-alpha "wait 05"
woke 08-beta "wait 05"
ok park-refused
fi

forged() {
  jq -s --arg n "$1" 'map(select(.args[0] == "resume" and (.args | length) == 2 and (.args[1] | tonumber) == ($n | tonumber))) | length' "$WD_FORGES"
}
gone_woke() {
  local p=$1 cond=$2 n=${1%%-*} got msg
  [ "$(forged "$n")" = 1 ] || fail "phase $p, parked on $cond with its session gone, runs forge resume $n once: $(cat "$WD_FORGES")"
  got=$(jq -c --arg n "$n" 'select(.args[0] == "resume" and (.args[1] | tonumber) == ($n | tonumber))' "$WD_FORGES")
  printf '%s\n' "$got" | jq -e --arg r "$root" '.root == $r and .lock == "free" and .fd6 == "closed"' >/dev/null ||
    fail "forge resume $n runs with FORGE_ROOT=$root, outside sessions.lock and with fd 6 closed, got $got"
  [ "$(resumes "$p")" = 1 ] || fail "phase $p logs one resume event after forge resume: $(cat "$sd/phases/$p/events.jsonl")"
  msg=$(jq -rs 'last | select(.step == "resume") | .message' "$sd/phases/$p/events.jsonl")
  [[ $msg == *"$cond"* && $msg == *"forge resume"* ]] || fail "the resume event of $p is its last event and names $cond and forge resume: '$msg'"
}
if want gone; then
setup gone
unset FORGE_TEST_SLOT_HELD FORGE_TEST_SLOTS_MAX FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail
export WD_FORGES=$env_dir/forges.jsonl WD_FORGE_FAIL=$env_dir/forge-fail WD_FORGE_WAIT=$env_dir/forge-wait WD_FORGE_REFUSE=$env_dir/forge-refuse
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORGES" "$WD_FORGE_FAIL" "$WD_FORGE_WAIT" "$WD_FORGE_REFUSE"; do : >"$f"; done
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
lk=$XDG_RUNTIME_DIR/forge/sessions.lock
l=free
if [ -e "$lk" ] && ! flock -n "$lk" true; then l=held; fi
f=closed
[ ! -e "/proc/$$/fd/6" ] || f=open
jq -cn --arg r "${FORGE_ROOT-unset}" --arg l "$l" --arg f "$f" '{root: $r, lock: $l, fd6: $f, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
if [ -s "$WD_FORGE_FAIL" ]; then echo "forge: cannot launch phase $2" >&2; exit 1; fi
if [ -s "$WD_FORGE_REFUSE" ]; then
  for d in "${XDG_STATE_HOME:-$HOME/.local/state}/forge/${FORGE_ROOT##*/}"/phases/"$2"-*; do jq -cn --arg m "phase $2 not started: the worktree has uncommitted changes" '{time: "2026-01-01T00:00:00Z", step: "refused", message: $m}' >>"$d/events.jsonl"; done
  echo "forge: phase $2 not started: the worktree has uncommitted changes" >&2
  exit 8
fi
if [ -s "$WD_FORGE_WAIT" ]; then
  for d in "${XDG_STATE_HOME:-$HOME/.local/state}/forge/${FORGE_ROOT##*/}"/phases/"$2"-*; do jq -cn '{time: "2026-01-01T00:00:00Z", step: "wait", message: "waits for a free session"}' >>"$d/events.jsonl"; done
  echo "forge: 50 forge sessions live; phase $2 waits for a free session" >&2
  exit 0
fi
echo "forge: phase $2 started"
STUB
chmod +x "$bin/forge"
git -C "$root" init -q
git -C "$root" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
c0=$(git -C "$root" rev-parse HEAD)
c11=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "$c0" -m p11 "$c0^{tree}")
c16=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "$c0" -m p16 "$c0^{tree}")
cf=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "$c0" -p "$c16" -m "Merge branch 'forge/$tf-16'" "$c0^{tree}")
git -C "$root" branch "forge/$tf" "$cf"
git -C "$root" branch "forge/$tf-08" "$c0"
git -C "$root" branch "forge/$tf-11" "$c11"
git -C "$root" branch "forge/$tf-16" "$c16"
landed 04-pre
for p in 08-beta 09-gamma 10-delta 11-eps 12-zeta 13-eta 14-theta 16-kappa; do
  jq -n --arg n "${p%%-*}" --arg s "${p#*-}" '{track: "tr", feature: "feat", number: $n, slug: $s, goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/$p/spec.json"
done
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
started 07-alpha "proj P07 $tfs" aaaaaaa7
started 08-beta "proj P08 $tfs" aaaaaa08
logged 08-beta park "wait 05"
started 09-gamma "proj P09 $tfs" aaaaaa09
logged 09-gamma park "wait 06"
started 10-delta "proj P10 $tfs"
logged 10-delta park "wait 05"
started 11-eps "proj P11 $tfs" aaaaaa11
logged 11-eps park "wait 05"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/11-eps/result.json"
started 16-kappa "proj P16 $tfs" aaaaaa16
logged 16-kappa park "wait 05"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/16-kappa/result.json"
started 12-zeta "proj P12 $tfs" aaaaaa12
logged 12-zeta park "wait 05"
logged 12-zeta resume "wait 05 cleared; resumed proj P12 $tfs with forge resume"
started 13-eta "proj P13 $tfs" aaaaaa13
logged 13-eta park "wait 06"
started 14-theta "proj P14 $tfs" aaaaaa14
rline "$sd/phases/14-theta" park 55 "wait 04"
parked 15-iota "proj P15 $tfs" stopped "wait 05" 39 "proj P15 $tfs"
nopid 15
idle_gone() {
  local p
  for p in "$@"; do
    [ "$(forged "${p%%-*}")" = 0 ] || fail "phase $p runs no forge resume: $(cat "$WD_FORGES")"
    [ "$(jq -s 'map(select(.step == "resume")) | length' "$sd/phases/$p/events.jsonl")" = "$([ "$p" = 12-zeta ] && echo 1 || echo 0)" ] ||
      fail "phase $p logs no new resume event: $(cat "$sd/phases/$p/events.jsonl")"
  done
}

echo 1 >"$WD_FORGE_FAIL"
run
[ "$(forged 14)" = 1 ] || fail "phase 14, parked on wait 04 with its session gone and phase 04 landed, runs forge resume 14: $(cat "$WD_FORGES")"
[ "$(resumes 14-theta)" = 0 ] || fail "a failed forge resume logs no resume event: $(cat "$sd/phases/14-theta/events.jsonl")"
grep -F 'forge resume' "$env_dir/out" | grep -q 14 || fail "a failed forge resume warns naming forge resume and phase 14: $(cat "$env_dir/out")"
[ "$(jq -s length "$WD_FORGES")" = 1 ] || fail "with phases 05 and 06 not landed, only phase 14 runs forge resume: $(cat "$WD_FORGES")"
[ ! -s "$WD_ACTS" ] || fail "no listed session is stopped or resumed while phase 05 has not landed: $(cat "$WD_ACTS")"

: >"$WD_FORGE_FAIL"
: >"$WD_FORGES"
echo 1 >"$WD_FORGE_REFUSE"
run
[ "$(forged 14)" = 1 ] || fail "phase 14 runs forge resume 14 once when it refuses the launch: $(cat "$WD_FORGES")"
[ "$(resumes 14-theta)" = 0 ] || fail "a forge resume exiting 8 logs no resume event: $(cat "$sd/phases/14-theta/events.jsonl")"
grep -qxF "forge: forge resume 14 refused for proj P14 $tfs, already reported; phase 14 stays parked until the next scan" "$env_dir/out" ||
  fail "a forge resume exiting 8 prints its refused line: $(cat "$env_dir/out")"
! grep -qF "forge resume 14 failed" "$env_dir/out" || fail "a forge resume exiting 8 prints no failed line: $(cat "$env_dir/out")"
[ "$(jq -rs 'map(.step) | .[-2:] | join(" ")' "$sd/phases/14-theta/events.jsonl")" = "park refused" ] || fail "a forge resume exiting 8 leaves phase 14 parked, its refused event after the park: $(cat "$sd/phases/14-theta/events.jsonl")"
logged 14-theta stall "launch refused: phase 14 not started: the worktree has uncommitted changes"
: >"$WD_FORGE_REFUSE"
: >"$WD_FORGES"
landed 05-pre
run
gone_woke 08-beta "wait 05"
gone_woke 10-delta "wait 05"
gone_woke 14-theta "wait 04"
gone_woke 11-eps "wait 05"
idle_gone 09-gamma 12-zeta 13-eta 16-kappa
[ "$(forged 16)" = 0 ] || fail "phase 16, parked on wait 05 with a done result.json and forge/$tf-16 merged into forge/$tf, runs no forge resume: $(cat "$WD_FORGES")"
[ "$(forged 15)" = 0 ] || fail "phase 15, whose session is still listed, runs no forge resume: $(cat "$WD_FORGES")"
[ "$(jq -s length "$WD_FORGES")" = 4 ] || fail "the scan after phase 05 lands runs forge resume for phases 08, 10, 11 and 14 only: $(cat "$WD_FORGES")"
woke 15-iota "wait 05" "proj P15 $tfs" 39
[ "$(grep -c '^resume ' "$WD_ACTS")" = 1 ] || fail "only phase 15, whose session is still listed, is resumed through claude --bg --resume: $(cat "$WD_ACTS")"

: >"$WD_FORGES"
: >"$WD_ACTS"
: >"$WD_RESUMES"
landed 06-post
run
gone_woke 09-gamma "wait 06"
gone_woke 13-eta "wait 06"
[ "$(jq -s length "$WD_FORGES")" = 2 ] || fail "the scan after phase 06 lands runs forge resume for phases 09 and 13 only; a phase whose last event is no longer park is not resumed again: $(cat "$WD_FORGES")"
[ "$(resumes 16-kappa)" = 0 ] && [ "$(jq -rs 'last.step' "$sd/phases/16-kappa/events.jsonl")" = park ] ||
  fail "the merged phase 16 stays parked with no resume event: $(cat "$sd/phases/16-kappa/events.jsonl")"
[ ! -s "$WD_ACTS" ] || fail "the scan after phase 06 lands stops or resumes no listed session: $(cat "$WD_ACTS")"
ev8=$sd/phases/08-beta/events.jsonl
: >"$WD_FORGES"
logged 08-beta park "wait 05"
echo 1 >"$WD_FORGE_WAIT"
run
[ "$(forged 8)" = 1 ] || fail "phase 08, parked again on wait 05 with its session gone, runs forge resume 8: $(cat "$WD_FORGES")"
[ "$(resumes 08-beta)" = 1 ] || fail "a forge resume that only waits for a free session logs no resume event: $(cat "$ev8")"
[ "$(jq -rs 'last | "\(.step) \(.message)"' "$ev8")" = "park wait 05" ] || fail "a forge resume that only waits for a free session leaves phase 08 parked on wait 05: $(cat "$ev8")"
grep -F 'free session' "$env_dir/out" | grep -q 08 || fail "a forge resume that only waits warns naming the free session and phase 08: $(cat "$env_dir/out")"
: >"$WD_FORGE_WAIT"
: >"$WD_FORGES"
run
[ "$(forged 8)" = 1 ] && [ "$(resumes 08-beta)" = 2 ] || fail "phase 08 is retried the scan after a capacity wait and logs its resume: $(cat "$WD_FORGES" "$ev8")"
rf=$HOME/.local/state/forge/watchdog-roots
rm -f "$rf"
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 1
logged 08-beta park "wait 05"
: >"$WD_FORGES"
run
[ "$(forged 8)" = 1 ] && [ "$(resumes 08-beta)" = 3 ] || fail "a project whose only listed session is working and active still has its gone parked phase 08 resumed: $(cat "$WD_FORGES" "$env_dir/out")"
grep -qxF "$root" "$rf" || fail "forge watchdog records the project roots it resolves in $rf: $(cat "$rf" 2>/dev/null)"
echo '[]' >"$agents"
logged 08-beta park "wait 05"
: >"$WD_FORGES"
run
[ "$(forged 8)" = 1 ] && [ "$(resumes 08-beta)" = 4 ] || fail "a project no listed session resolves, seen in an earlier scan, still has its gone parked phase 08 resumed: $(cat "$WD_FORGES" "$env_dir/out")"
printf '%s\n' "$env_dir/no-such-project" >>"$rf"
run
! grep -qxF "$env_dir/no-such-project" "$rf" || fail "forge watchdog drops a recorded root that holds neither S/phases nor .forge/phases: $(cat "$rf")"
rm -f "$rf"
FORGE_ROOT=$root "$forge" event 08 park "wait 05" >"$env_dir/out" 2>&1 || fail "forge event 08 park wait 05 succeeds: $(cat "$env_dir/out")"
grep -qxF "$root" "$rf" || fail "forge event <N> park records the project root in $rf: $(cat "$rf" 2>/dev/null)"
: >"$WD_FORGES"
run
[ "$(forged 8)" = 1 ] && [ "$(resumes 08-beta)" = 5 ] || fail "a phase parked with forge event whose session is gone before any scan resolved its root still has forge resume run: $(cat "$WD_FORGES" "$env_dir/out")"
h=$repo/bin/forge.d/help/watchdog.txt
grep -qF 'forge resume' "$h" || fail "watchdog.txt documents restarting a gone session's phase with forge resume"
awk '/^Gone session:/ {on = 1} on && /^$/ {exit} on' "$h" | tr '\n' ' ' | grep -qF 'already reported' || fail "watchdog.txt's Gone session paragraph documents a forge resume exiting 8 as refused, already reported"
gp=$(awk '/^Gone session:/ {on = 1} on && /^$/ {exit} on' "$h" | tr '\n' ' ')
[[ $gp == *merged* && $gp != *"holds no result.json"* ]] || fail "watchdog.txt's Gone session paragraph skips a phase merged into its feature branch, not one holding result.json: $gp"
grep -F 'tests/forge-watchdog.test.sh' "$repo/.forge/TESTING.md" | grep -qF 'forge resume' || fail "the forge-watchdog line of .forge/TESTING.md covers the resume pass and forge resume"
ok gone
fi

if want state-dir; then
setup state-dir
unset XDG_STATE_HOME FORGE_TEST_SLOT_HELD FORGE_TEST_SLOTS_MAX FORGE_TEST_CPUS FORGE_TEST_LOG_DIR FORGE_TEST_RERUN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORGES=$env_dir/forges.jsonl
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORGES"; do : >"$f"; done
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
jq -cn --arg r "${FORGE_ROOT-unset}" '{root: $r, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
echo "forge: phase $2 started"
STUB
chmod +x "$bin/forge"
sd=$HOME/.local/state/forge/proj
rm -rf "$root/.forge/phases" "$root/.forge/features"
mkdir -p "$root/.forge/tracks" "$sd/features/$tf"
printf '%s\n' "$root" >"$sd/root"
sev() {
  jq -cn --arg t "$(date -u -d "$3 minutes ago" +%FT%TZ)" --arg s "$2" --arg m "$4" --arg i "${5:-}" \
    '{time: $t, step: $s, message: $m} + if $i == "" then {} else {session: $i} end' >>"$1/events.jsonl"
}
for p in 07-alpha 08-beta 09-gamma 12-zeta; do
  mkdir -p "$sd/phases/$p"
  jq -n --arg n "${p%%-*}" --arg s "${p#*-}" '{track: "tr", feature: "feat", number: $n, slug: $s, goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/$p/spec.json"
done
git -C "$root" init -q
gc "$root" --allow-empty -m init
c0=$(git -C "$root" rev-parse HEAD)
c9=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "$c0" -m p09 "$c0^{tree}")
git -C "$root" branch "forge/$tf" "$c0"
git -C "$root" branch "forge/$tf-09" "$c9"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/09-gamma/result.json"
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
sev "$sd/phases/07-alpha" start 60 "proj P07 $tfs" aaaaaaa7
session "proj verify $tfs" working "$wt/$tf" cccccccc-0000-4000-8000-00000000000v
transcript "$wt/$tf" cccccccc-0000-4000-8000-00000000000v 45
sev "$sd/phases/08-beta" start 60 "proj P08 $tfs" aaaaaa08
sev "$sd/phases/08-beta" park 50 memory
sev "$sd/phases/12-zeta" start 60 "proj P12 $tfs" aaaaaa12
sev "$sd/phases/12-zeta" park 50 "wait 09"
old=$env_dir/Projects/old
mkdir -p "$old/.forge/phases/05-far"
jq -n '{track: "tr", feature: "feat", number: "05", slug: "far", goal: "g", spec: [], requirements: [], depends: []}' >"$old/.forge/phases/05-far/spec.json"
sev "$old/.forge/phases/05-far" start 60 "old P05 $tfs" aaaaaa05
sev "$old/.forge/phases/05-far" park 50 memory
git -C "$old" init -q
gc "$old" --allow-empty -m init
rf=$HOME/.local/state/forge/watchdog-roots
printf '%s\n' "$old" >"$rf"
sforged() { jq -s --arg r "$1" --arg n "$2" 'map(select(.root == $r and .args[0] == "resume" and (.args[1] | tonumber) == ($n | tonumber))) | length' "$WD_FORGES"; }
sresumes() { jq -s 'map(select(.step == "resume")) | length' "$sd/phases/$1/events.jsonl"; }
refusal="forge: $old/.forge still holds planning records; move them to its state dir"

run
ev7=$sd/phases/07-alpha/events.jsonl
[ "$(jq -s 'map(select(.step == "stall")) | length' "$ev7")" = 1 ] ||
  fail "a phase session of a root whose records live in its state dir logs one stall in S/phases/07-alpha/events.jsonl: $(cat "$ev7"; cat "$env_dir/out")"
m7=$(jq -rs 'map(select(.step == "stall")) | last | .message' "$ev7")
[[ $m7 == *"proj P07 $tfs"* || $m7 == *aaaaaaa7-0000-4000-8000-000000000007* ]] && has_minutes "$m7" 30 ||
  fail "the S stall of phase 07 names its session and 30 idle minutes: '$m7'"
fl=$(grep -rhF -e "proj verify $tfs" -e cccccccc-0000-4000-8000-00000000000v "$sd/features/$tf" 2>/dev/null || true)
[ -n "$fl" ] && printf '%s\n' "$fl" | grep -q stall ||
  fail "a verify session of a root whose records live in its state dir logs its stall under S/features/$tf/: $(find "$sd" -type f; cat "$env_dir/out")"
[ ! -e "$root/.forge/phases" ] && [ ! -e "$root/.forge/features" ] ||
  fail "forge watchdog writes no record under the repo's .forge/phases or .forge/features: $(find "$root/.forge" -type f)"
[ "$(sforged "$root" 8)" = 1 ] || fail "phase 08 in S/phases, parked on memory with its session gone, runs forge resume 8 with FORGE_ROOT=$root read from S/root: $(cat "$WD_FORGES" "$env_dir/out")"
[ "$(sresumes 08-beta)" = 1 ] || fail "the resume of phase 08 is logged in S/phases/08-beta/events.jsonl: $(cat "$sd/phases/08-beta/events.jsonl")"
[ "$(sforged "$root" 12)" = 0 ] || fail "phase 12, parked on wait 09 whose S result.json says done but whose branch forge/$tf-09 is not merged into forge/$tf, runs no forge resume: $(cat "$WD_FORGES")"
grep -qF "$refusal" "$env_dir/out" || fail "an unmoved root in watchdog-roots is skipped with the line '$refusal' in the watchdog log: $(cat "$env_dir/out")"
[ "$(jq -s --arg r "$old" 'map(select(.root == $r)) | length' "$WD_FORGES")" = 0 ] || fail "the unmoved root's gone parked phase 05 runs no forge resume: $(cat "$WD_FORGES")"
[ "$(jq -s 'map(select(.step == "resume")) | length' "$old/.forge/phases/05-far/events.jsonl")" = 0 ] || fail "the unmoved root gets no event written: $(cat "$old/.forge/phases/05-far/events.jsonl")"
grep -qxF "$root" "$rf" && grep -qxF "$old" "$rf" || fail "watchdog-roots keeps the moved root and the unmoved root: $(cat "$rf")"

: >"$WD_FORGES"
cm=$(git -C "$root" -c user.name=t -c user.email=t@t commit-tree -p "$c0" -p "$c9" -m "Merge branch 'forge/$tf-09'" "$c0^{tree}")
git -C "$root" branch -f "forge/$tf" "$cm"
run
[ "$(sforged "$root" 12)" = 1 ] || fail "phase 12, parked on wait 09, runs forge resume 12 once phase 09's S result.json says done and forge/$tf-09 is merged into forge/$tf, with no git commit of result.json: $(cat "$WD_FORGES" "$env_dir/out")"
m12=$(jq -rs 'last | select(.step == "resume") | .message' "$sd/phases/12-zeta/events.jsonl")
[[ $m12 == "wait 09 cleared; "*"forge resume"* ]] || fail "the resume event of phase 12 in S starts 'wait 09 cleared; ' naming forge resume: '$m12'"
grep -qF "$refusal" "$env_dir/out" || fail "a second scan skips the unmoved root again with '$refusal': $(cat "$env_dir/out")"

: >"$WD_FORGES"
echo '[]' >"$agents"
sev "$sd/phases/08-beta" park 1 memory
printf '%s\n' "$env_dir/no-such-project" >>"$rf"
run
[ "$(sforged "$root" 8)" = 1 ] && [ "$(sresumes 08-beta)" = 2 ] ||
  fail "a moved root no listed session resolves, kept in watchdog-roots because S/phases exists, still has its gone parked phase 08 resumed: $(cat "$WD_FORGES" "$env_dir/out")"
grep -qxF "$root" "$rf" || fail "watchdog-roots keeps a root whose S/phases exists though its .forge/phases is gone: $(cat "$rf")"
grep -qxF "$old" "$rf" || fail "watchdog-roots keeps an unmoved root whose .forge/phases still exists: $(cat "$rf")"
! grep -qxF "$env_dir/no-such-project" "$rf" || fail "watchdog-roots drops a root with neither S/phases nor .forge/phases: $(cat "$rf")"
grep -qF "$refusal" "$env_dir/out" || fail "a scan with no listed session still skips the unmoved root with '$refusal': $(cat "$env_dir/out")"
grep -qF 'still holds planning records' "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents skipping an unmoved root"
ok state-dir
fi

if want legacy-park; then
setup legacy-park
wt=$root/.claude/worktrees
resume_stubs
export WD_ACTS=$env_dir/acts.log WD_RESUMES=$env_dir/resumes.jsonl WD_KEEP=$env_dir/keep WD_STOPFAIL=$env_dir/stopfail WD_FAIL=$env_dir/fail WD_FORGES=$env_dir/forges.jsonl
for f in "$WD_ACTS" "$WD_RESUMES" "$WD_KEEP" "$WD_STOPFAIL" "$WD_FAIL" "$WD_FORGES"; do : >"$f"; done
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
jq -cn --arg r "${FORGE_ROOT-unset}" '{root: $r, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
echo "forge: phase $2 started"
STUB
chmod +x "$bin/forge"
landed
printf 'MemTotal: 33554432 kB\nMemAvailable: 1024 kB\n' | tee "$env_dir/meminfo" >"$FORGE_PROC_ROOT/meminfo"
printf '99.00 99.00 99.00 2/300 4242\n' >"$env_dir/loadavg"
export FORGE_MEMINFO=$env_dir/meminfo FORGE_LOADAVG=$env_dir/loadavg FORGE_TEST_SLOTS=1
parked 07-alpha "proj P07 $tfs" stopped slot 31 "proj P07 $tfs"
nopid 07
parked 08-beta "proj P08 $tfs" stopped memory 32 "proj P08 $tfs"
nopid 08
parked 09-gamma "proj P09 $tfs" stopped load 33 "proj P09 $tfs"
nopid 09
jq -n '{track: "tr", feature: "feat", number: "12", slug: "zeta", goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/12-zeta/spec.json"
started 12-zeta "proj P12 $tfs" aaaaaa12
logged 12-zeta park slot
run
woke 07-alpha slot "proj P07 $tfs" 31
woke 08-beta memory "proj P08 $tfs" 32
woke 09-gamma load "proj P09 $tfs" 33
[ "$(grep -c '^resume ' "$WD_ACTS")" = 3 ] || fail "with no memory free, the load past nproc and FORGE_TEST_SLOTS=1, one scan resumes the listed legacy slot, memory and load parks 07, 08 and 09: $(cat "$WD_ACTS" "$env_dir/out")"
[ "$(stops 07)$(stops 08)$(stops 09)" = 000 ] || fail "stopped sessions with legacy parks are resumed without a stop: $(cat "$WD_ACTS")"
[ "$(forged 12)" = 1 ] || fail "phase 12, parked on slot before the port with its session gone, runs forge resume 12 once: $(cat "$WD_FORGES" "$env_dir/out")"
m12=$(jq -rs 'last | select(.step == "resume") | .message' "$sd/phases/12-zeta/events.jsonl")
[ "$m12" = "slot cleared; proj P12 $tfs is gone, resumed phase 12 with forge resume" ] ||
  fail "the gone legacy slot park's resume event reads 'slot cleared; proj P12 $tfs is gone, resumed phase 12 with forge resume': '$m12'"
! grep -qiE 'stays parked|command not found|slot parks resume' "$env_dir/out" || fail "a scan over legacy parks keeps none parked and calls no slot pool: $(cat "$env_dir/out")"
: >"$WD_ACTS"
: >"$WD_RESUMES"
: >"$WD_FORGES"
run
[ "$(tries 07)$(tries 08)$(tries 09)$(forged 12)" = 0000 ] || fail "a legacy park resumes once: the next scan resumes none of 07, 08, 09 or 12 again: $(cat "$WD_ACTS" "$WD_FORGES")"
for p in 07-alpha 08-beta 09-gamma 12-zeta; do [ "$(resumes "$p")" = 1 ] || fail "phase $p logs one resume event over two scans: $(cat "$sd/phases/$p/events.jsonl")"; done
! grep -qE '\b(slot_pool|slot_count|slot_free|slot_queue|test_room)\b|FORGE_MEMINFO|FORGE_LOADAVG' "$repo/bin/forge.d/watchdog.sh" ||
  fail "watchdog.sh probes no slot pool, memory or load: $(grep -nE '\b(slot_pool|slot_count|slot_free|slot_queue|test_room)\b|FORGE_MEMINFO|FORGE_LOADAVG' "$repo/bin/forge.d/watchdog.sh")"
h=$repo/bin/forge.d/help/watchdog.txt
rsec=$(awk '/^Resume:/ {on = 1} /^Held launches:/ {on = 0} on' "$h" | tr '\n' ' ')
grep -qF 'wait <ref>' <<<"$rsec" && grep -qF '<abs-root>:<N>' <<<"$rsec" || fail "watchdog.txt's Resume text names the wait <ref> condition and its <N> and <abs-root>:<N> forms"
grep -qiF 'resumes once' <<<"$rsec" || fail "watchdog.txt's Resume text says a legacy slot, memory or load park resumes once"
! grep -qiE 'MemAvailable|loadavg|slot pool|slot queue|oldest' <<<"$rsec" || fail "watchdog.txt's Resume and Gone session text names no memory, load or slot condition and no slot queue"
! grep -qE 'FORGE_MEMINFO|FORGE_LOADAVG|FORGE_TEST_SLOTS|/proc/loadavg|slot pool' "$h" || fail "watchdog.txt documents no memory, load or slot input: $(grep -nE 'FORGE_MEMINFO|FORGE_LOADAVG|FORGE_TEST_SLOTS|/proc/loadavg|slot pool' "$h")"
unset FORGE_MEMINFO FORGE_LOADAVG FORGE_TEST_SLOTS
ok legacy-park
fi

ago() { date -u -d "$1 hours ago" +%FT%TZ; }
hrec() { mkdir -p "${hf%/*}"; jq -cn --arg r "$root" --arg k "$1" --arg g "$2" --arg t "$3" '{root: $r, kind: $k, target: $g, time: $t}' >>"$hf"; }
fstart() { jq -cn --arg t "$2" '{time: $t, step: "start", message: "s"}' >>"$1/events.jsonl"; }
records() { if [ -f "$hf" ]; then jq -s length "$hf"; else echo 0; fi; }
calls() { jq -s length "$WD_FORGES"; }
recorded() {
  [ -f "$hf" ] && jq -se --arg r "$root" --arg k "$1" --arg g "$2" --arg t "$3" 'map(select(.root == $r and .kind == $k and .target == $g and .time == $t)) | length == 1' "$hf" >/dev/null ||
    fail "$4: held.jsonl keeps the record $1 $2 held since $3: $(cat "$hf" 2>/dev/null)"
}
launched() {
  local got
  got=$(jq -sc --argjson i "$1" '.[$i]' "$WD_FORGES")
  jq -e --arg r "$root" --arg s "$3" --argjson a "$2" '.root == $r and .since == $s and .args == $a and .lock == "free" and .hlock == "free" and .fd6 == "closed" and .stdin == "/dev/null" and .kept == 1' <<<"$got" >/dev/null ||
    fail "launch $1 runs forge $(jq -r 'join(" ")' <<<"$2") by name with FORGE_ROOT=$root and FORGE_HELD_SINCE=$3, stdin /dev/null, fd 6 closed, outside sessions.lock and held.jsonl.lock, its record still in held.jsonl while it runs, got $got"
}

if want held; then
setup held
unset FORGE_MAX_SESSIONS
export XDG_STATE_HOME=$env_dir/state
state_at "$root"
hf=$XDG_STATE_HOME/forge/held.jsonl
export WD_FORGES=$env_dir/forges.jsonl WD_HOLD=$env_dir/hold WD_ENTRY_FAIL=$env_dir/entry-fail WD_LIST_FAIL=$env_dir/list-fail WD_ENTRY_KILL=$env_dir/entry-kill WD_ENTRY_SIGKILL=$env_dir/entry-sigkill WD_ENTRY_REFUSE=$env_dir/entry-refuse WD_REFUSE_HOLD=$env_dir/refuse-hold
for f in "$WD_FORGES" "$WD_HOLD" "$WD_ENTRY_FAIL" "$WD_LIST_FAIL" "$WD_ENTRY_KILL" "$WD_ENTRY_SIGKILL" "$WD_ENTRY_REFUSE" "$WD_REFUSE_HOLD"; do : >"$f"; done
cat >"$bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$WD_LOG"
[ "${1:-}" = agents ] || exit 1
case " $* " in
  *" --all "*) cat "$WD_AGENTS" ;;
  *)
    if [ -s "$WD_LIST_FAIL" ]; then echo "Error: cannot reach the session daemon" >&2; exit 1; fi
    jq '[.[] | select(.pid != null or .state == "working" or .state == "blocked")]' "$WD_AGENTS" ;;
esac
STUB
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
h=${XDG_STATE_HOME:-$HOME/.local/state}/forge/held.jsonl
lk=$XDG_RUNTIME_DIR/forge/sessions.lock
l=free
if [ -e "$lk" ] && ! flock -n "$lk" true; then l=held; fi
hl=free
if [ -e "$h.lock" ] && ! flock -n "$h.lock" true; then hl=held; fi
f=closed
[ ! -e "/proc/$$/fd/6" ] || f=open
i=$(readlink "/proc/$$/fd/0")
case ${1:-} in resume) k=phase ;; implement) k=verify ;; next) k=ship ;; *) k=other ;; esac
c=0
[ ! -f "$h" ] || c=$(jq -s --arg r "${FORGE_ROOT-}" --arg k "$k" --arg g "${2:-}" 'map(select(.root == $r and .kind == $k and .target == $g)) | length' "$h")
jq -cn --arg r "${FORGE_ROOT-unset}" --arg s "${FORGE_HELD_SINCE-unset}" --arg l "$l" --arg hl "$hl" --arg f "$f" --arg i "$i" --argjson c "$c" \
  '{root: $r, since: $s, lock: $l, hlock: $hl, fd6: $f, stdin: $i, kept: $c, args: $ARGS.positional}' --args -- "$@" >>"$WD_FORGES"
if grep -qxF "$*" "$WD_HOLD"; then
  { flock 5 && x=$(jq -s --arg r "$FORGE_ROOT" --arg k "$k" --arg g "$2" 'any(.[]; .root == $r and .kind == $k and .target == $g)' "$h") &&
    { [ "$x" = true ] || jq -cn --arg r "$FORGE_ROOT" --arg k "$k" --arg g "$2" --arg t "$FORGE_HELD_SINCE" '{root: $r, kind: $k, target: $g, time: $t}' >>"$h"; }; } 5>>"$h.lock"
  echo "forge: 2 forge sessions live; $k $2 waits for a free session" >&2
  echo "forge: recorded the held $k $2; forge watchdog starts it once room frees" >&2
  exit 0
fi
if grep -qxF "$*" "$WD_REFUSE_HOLD"; then
  { flock 5 && x=$(jq -s --arg r "$FORGE_ROOT" --arg k "$k" --arg g "$2" 'any(.[]; .root == $r and .kind == $k and .target == $g)' "$h") &&
    { [ "$x" = true ] || jq -cn --arg r "$FORGE_ROOT" --arg k "$k" --arg g "$2" --arg t "$FORGE_HELD_SINCE" '{root: $r, kind: $k, target: $g, time: $t}' >>"$h"; }; } 5>>"$h.lock"
  echo "forge: verify tr/other not started: a verify session is already live" >&2
  echo "forge: recorded the held $k $2; forge watchdog starts it once room frees" >&2
  exit 8
fi
if grep -qxF "$*" "$WD_ENTRY_REFUSE"; then
  echo "forge: $k $2 not started: the worktree has uncommitted changes" >&2
  exit 8
fi
if grep -qxF "$*" "$WD_ENTRY_KILL"; then
  kill -TERM "$PPID"
  exit 143
fi
if grep -qxF "$*" "$WD_ENTRY_SIGKILL"; then
  kill -KILL "$PPID"
  exit 137
fi
if grep -qxF "$*" "$WD_ENTRY_FAIL"; then
  echo "forge: preparing $k $2" >&2
  echo "forge: cannot start $k $2: no worktree" >&2
  exit 1
fi
echo "forge: $k $2 started"
STUB
chmod +x "$bin/claude" "$bin/forge"
run
[ "$(calls)" = 0 ] || fail "without held.jsonl a scan runs no held launch: $(cat "$WD_FORGES")"
[ ! -e "$hf" ] || fail "without held.jsonl a scan does not create it: $(cat "$hf")"
mkdir -p "${hf%/*}"
: >"$hf"
run
[ "$(calls)" = 0 ] || fail "an empty held.jsonl runs no held launch: $(cat "$WD_FORGES")"

mkdir -p "$sd/features/tr-calm"
jq -n '{result: "pass"}' >"$sd/features/$tf/verify.json"
fstart "$sd/phases/07-alpha" "$(ago 2)"
t7=$(ago 1) t8=$(ago 3) tv=$(ago 4) ts=$(ago 2)
hrec phase 08 "$t8"
hrec ship "$tfs" "$ts"
hrec phase 07 "$t7"
hrec verify tr/calm "$tv"
run
[ "$(calls)" = 4 ] || fail "four held records needing a launch run four entries: $(cat "$WD_FORGES" "$env_dir/out")"
launched 0 '["implement", "tr/calm"]' "$tv"
launched 1 '["resume", "08"]' "$t8"
launched 2 "[\"next\", \"$tfs\"]" "$ts"
launched 3 '["resume", "07"]' "$t7"
grep -qxF "forge: started the held verify tr/calm of $root, held since $tv" "$env_dir/out" || fail "a started held verify prints its started line: $(cat "$env_dir/out")"
grep -qxF "forge: started the held phase 08 of $root, held since $t8" "$env_dir/out" || fail "a started held phase prints its started line: $(cat "$env_dir/out")"
grep -qxF "forge: started the held ship $tfs of $root, held since $ts" "$env_dir/out" || fail "a started held ship prints its started line: $(cat "$env_dir/out")"
[ "$(records)" = 0 ] || fail "each launched record is dropped from held.jsonl: $(cat "$hf")"

: >"$WD_FORGES"
: >"$hf"
rm -f "$sd/features/$tf/verify.json"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/09-gamma/result.json"
td=$(ago 3)
fstart "$sd/phases/10-delta" "$(ago 1)"
fstart "$sd/phases/11-eps" "$td"
for f in vdone vstarted sfail snone; do mkdir -p "$sd/features/tr-$f"; done
jq -n '{result: "pass"}' >"$sd/features/tr-vdone/verify.json"
fstart "$sd/features/tr-vstarted" "$(ago 1)"
jq -n '{result: "fail"}' >"$sd/features/tr-sfail/verify.json"
hrec phase 09 "$td"
hrec phase 10 "$td"
hrec phase 11 "$td"
hrec phase 31 "$td"
hrec verify tr/gone "$td"
hrec verify tr/vdone "$td"
hrec verify tr/vstarted "$td"
hrec ship tr/sfail "$td"
hrec ship tr/snone "$td"
hrec ship tr/gone "$td"
run
[ "$(calls)" = 0 ] || fail "done, started-since, missing and archived targets and ships without a passed verify run no entry: $(cat "$WD_FORGES")"
[ "$(records)" = 0 ] || fail "records whose target no longer needs launching are dropped from held.jsonl: $(cat "$hf")"

: >"$WD_FORGES"
: >"$hf"
for f in snew seq sold; do
  mkdir -p "$sd/features/tr-$f"
  jq -n '{result: "pass"}' >"$sd/features/tr-$f/verify.json"
  jq -n '{result: "blocked"}' >"$sd/features/tr-$f/ship.json"
done
tn=$(ago 3) tq=$(ago 3) to=$(ago 2)
touch -d "$(ago 1)" "$sd/features/tr-snew/ship.json"
touch -d "$tq" "$sd/features/tr-seq/ship.json"
touch -d "$(ago 4)" "$sd/features/tr-sold/ship.json"
hrec ship tr/snew "$tn"
hrec ship tr/seq "$tq"
hrec ship tr/sold "$to"
run
[ "$(calls)" = 2 ] || fail "a held ship whose ship.json was written after the record's time runs no entry; forge next tr/seq and tr/sold, whose ship.json is not newer, run: $(cat "$WD_FORGES" "$env_dir/out")"
launched 0 '["next", "tr/seq"]' "$tq"
launched 1 '["next", "tr/sold"]' "$to"
[ "$(records)" = 0 ] || fail "held ships whose Ship ran since the hold are dropped from held.jsonl: $(cat "$hf")"
grep -qxF "forge: dropped the held ship tr/snew of $root, held since $tn: it no longer needs launching" "$env_dir/out" ||
  fail "a held ship whose ship.json is newer than its record prints its dropped line: $(cat "$env_dir/out")"
! grep -qF "forge: dropped the held ship tr/seq" "$env_dir/out" ||
  fail "a held ship whose ship.json is as old as its record, to the second, is not dropped: $(cat "$env_dir/out")"
rm -rf "$sd/features/tr-snew" "$sd/features/tr-seq" "$sd/features/tr-sold"

: >"$WD_FORGES"
: >"$hf"
for f in slaunched searly; do
  mkdir -p "$sd/features/tr-$f"
  jq -n '{result: "pass"}' >"$sd/features/tr-$f/verify.json"
done
tl=$(ago 3) te=$(ago 3)
jq -n --arg r "$root" --argjson l "$(($(date -d "$(ago 2)" +%s) * 1000))" --argjson e "$(($(date -d "$(ago 4)" +%s) * 1000))" \
  '[{id: "sl", kind: "background", startedAt: $l, name: "proj ship tr/slaunched", cwd: $r, state: "done"},
    {id: "se", kind: "background", startedAt: $e, name: "proj ship tr/searly", cwd: $r, state: "done"}]' >"$agents"
hrec ship tr/slaunched "$tl"
hrec ship tr/searly "$te"
run
[ "$(calls)" = 1 ] || fail "a held ship whose Ship session started after the record's time runs no entry, even without ship.json; forge next tr/searly, whose Ship started before it, runs: $(cat "$WD_FORGES" "$env_dir/out")"
launched 0 '["next", "tr/searly"]' "$te"
[ "$(records)" = 0 ] || fail "a held ship whose Ship session started since the hold is dropped from held.jsonl: $(cat "$hf")"
grep -qxF "forge: dropped the held ship tr/slaunched of $root, held since $tl: it no longer needs launching" "$env_dir/out" ||
  fail "a held ship whose Ship session started since its record prints its dropped line: $(cat "$env_dir/out")"
echo '[]' >"$agents"
rm -rf "$sd/features/tr-slaunched" "$sd/features/tr-searly"

: >"$WD_FORGES"
: >"$hf"
t13=$(ago 3) t14=$(ago 2)
hrec phase 14 "$t14"
hrec phase 13 "$t13"
echo "resume 13" >"$WD_HOLD"
run
[ "$(calls)" = 1 ] || fail "an entry held again stops the pass: only forge resume 13 runs, got $(cat "$WD_FORGES")"
launched 0 '["resume", "13"]' "$t13"
[ "$(records)" = 2 ] || fail "after a renewed hold held.jsonl holds the renewed and the later record: $(cat "$hf")"
recorded phase 13 "$t13" "a renewed hold"
recorded phase 14 "$t14" "a pass stopped by a renewed hold"
: >"$WD_HOLD"

: >"$WD_FORGES"
: >"$hf"
t12=$(ago 5)
hrec phase 12 "$t12"
echo "resume 12" >"$WD_ENTRY_FAIL"
run
[ "$(calls)" = 1 ] || fail "a held phase runs forge resume 12 once: $(cat "$WD_FORGES")"
grep -qxF "forge: held phase 12 of $root failed to start: forge: cannot start phase 12: no worktree; retrying next scan" "$env_dir/out" ||
  fail "a failing entry warns naming its kind, target, root and last stderr line: $(cat "$env_dir/out")"
! grep -qF "started the held phase 12" "$env_dir/out" || fail "a failing entry prints no started line: $(cat "$env_dir/out")"
[ "$(records)" = 1 ] || fail "a failing entry keeps one record: $(cat "$hf")"
recorded phase 12 "$t12" "a failing entry"
: >"$WD_ENTRY_FAIL"
: >"$WD_FORGES"
run
launched 0 '["resume", "12"]' "$t12"
[ "$(records)" = 0 ] || fail "the retried record is dropped once launched: $(cat "$hf")"

: >"$WD_FORGES"
: >"$hf"
hrec phase 14 "$t14"
hrec phase 13 "$t13"
echo "resume 13" >"$WD_REFUSE_HOLD"
run
[ "$(calls)" = 1 ] || fail "an entry exiting 8 that held again stops the pass: only forge resume 13 runs, got $(cat "$WD_FORGES")"
grep -qxF "forge: the held phase 13 of $root is held again; the rest wait for the next scan" "$env_dir/out" ||
  fail "an entry exiting 8 with the recorded-held line prints the held-again line: $(cat "$env_dir/out")"
! grep -qF "failed to start" "$env_dir/out" || fail "an entry exiting 8 prints no failed line: $(cat "$env_dir/out")"
grep -qxF "forge: verify tr/other not started: a verify session is already live" "$env_dir/out" || fail "an entry exiting 8 has its stderr passed through: $(cat "$env_dir/out")"
[ "$(records)" = 2 ] || fail "after an entry exiting 8 held again held.jsonl holds both records: $(cat "$hf")"
recorded phase 13 "$t13" "an entry exiting 8 held again"
recorded phase 14 "$t14" "a pass stopped by an entry exiting 8 held again"
: >"$WD_REFUSE_HOLD"

: >"$WD_FORGES"
: >"$hf"
hrec phase 12 "$t12"
echo "resume 12" >"$WD_ENTRY_REFUSE"
run
[ "$(calls)" = 1 ] || fail "a held phase refused with exit 8 runs forge resume 12 once: $(cat "$WD_FORGES")"
launched 0 '["resume", "12"]' "$t12"
grep -qxF "forge: phase 12 not started: the worktree has uncommitted changes" "$env_dir/out" || fail "an entry exiting 8 has its stderr passed through: $(cat "$env_dir/out")"
grep -qxF "forge: dropped the held phase 12 of $root, held since $t12: launch refused, already reported" "$env_dir/out" ||
  fail "an entry exiting 8 without the recorded-held line prints the refused dropped line: $(cat "$env_dir/out")"
! grep -qF "failed to start" "$env_dir/out" || fail "an entry exiting 8 prints no failed line: $(cat "$env_dir/out")"
! grep -qF "started the held phase 12" "$env_dir/out" || fail "an entry exiting 8 prints no started line: $(cat "$env_dir/out")"
[ "$(records)" = 0 ] || fail "an entry exiting 8 without the recorded-held line has its record dropped: $(cat "$hf")"
: >"$WD_FORGES"
run
[ "$(calls)" = 0 ] || fail "a held launch refused with exit 8 is not relaunched on the next scan: $(cat "$WD_FORGES")"
: >"$WD_ENTRY_REFUSE"

: >"$WD_FORGES"
: >"$hf"
hrec phase 12 "$t12"
echo "resume 12" >"$WD_ENTRY_KILL"
! (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1 || fail "a scan killed during a held launch exits non-zero: $(cat "$env_dir/out")"
[ "$(calls)" = 1 ] || fail "a scan killed during a held launch ran forge resume 12 once: $(cat "$WD_FORGES")"
[ "$(records)" = 1 ] || fail "a scan killed during a held launch keeps one record: $(cat "$hf")"
recorded phase 12 "$t12" "a scan killed during its launch"
: >"$WD_ENTRY_KILL"

: >"$WD_FORGES"
: >"$hf"
hrec phase 12 "$t12"
echo "resume 12" >"$WD_ENTRY_SIGKILL"
! (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1 || fail "a scan killed by SIGKILL during a held launch exits non-zero: $(cat "$env_dir/out")"
[ "$(calls)" = 1 ] || fail "a scan killed by SIGKILL during a held launch ran forge resume 12 once: $(cat "$WD_FORGES")"
[ "$(records)" = 1 ] || fail "a scan killed by SIGKILL during a held launch keeps one record: $(cat "$hf")"
recorded phase 12 "$t12" "a scan killed by SIGKILL during its launch"
: >"$WD_ENTRY_SIGKILL"

: >"$WD_FORGES"
: >"$hf"
t15=$(ago 2)
hrec phase 15 "$t15"
session "proj discuss" working "" ""
session "proj quick fix it" working "" ""
session "proj build tr" blocked "" ""
session "proj fast tidy" done "" ""
session "scratch notes" working "" ""
export FORGE_MAX_SESSIONS=2
run
[ "$(calls)" = 0 ] || fail "with FORGE_MAX_SESSIONS forge sessions live no held entry runs: $(cat "$WD_FORGES")"
recorded phase 15 "$t15" "a scan at the cap"
export FORGE_MAX_SESSIONS=3
run
[ "$(calls)" = 1 ] || fail "blocked, done and non-forge sessions do not count toward FORGE_MAX_SESSIONS, so below the cap forge resume 15 runs: $(cat "$WD_FORGES" "$env_dir/out")"
launched 0 '["resume", "15"]' "$t15"
unset FORGE_MAX_SESSIONS

: >"$WD_FORGES"
: >"$hf"
hrec phase 16 "$t15"
echo 1 >"$WD_LIST_FAIL"
run
[ "$(calls)" = 0 ] || fail "when claude agents --json fails no held entry runs: $(cat "$WD_FORGES")"
recorded phase 16 "$t15" "a scan that cannot list the sessions"
grep -q '^forge: warning:' "$env_dir/out" || fail "a failed session listing for the held launches prints a warning: $(cat "$env_dir/out")"
: >"$WD_LIST_FAIL"
unset XDG_STATE_HOME

h=$repo/bin/forge.d/help/watchdog.txt
grep -q '^Held launches' "$h" || fail "watchdog.txt has a 'Held launches' paragraph"
awk '/^Held launches/ {on = 1} on && /^$/ {exit} on' "$h" | tr '\n' ' ' | grep -qF 'launch refused, already reported' || fail "watchdog.txt's Held launches paragraph documents an entry exiting 8 as launch refused, already reported"
awk '/^  ship <t>\/<f>/ {on = 1} on && /^Otherwise/ {exit} on' "$h" | grep -qF ship.json || fail "watchdog.txt's ship drop rule names ship.json written after the record's time"
awk '/^  ship <t>\/<f>/ {on = 1} on && /^Otherwise/ {exit} on' "$h" | grep -qF 'claude agents --json --all' || fail "watchdog.txt's ship drop rule names a Ship session started since the record's time"
for s in Reads Writes; do
  awk -v s="$s:" '$0 == s {on = 1; next} on && /^$/ {exit} on' "$h" | grep -qF held.jsonl || fail "watchdog.txt lists held.jsonl under $s"
done
ok held
fi

if want status; then
setup status
wt=$root/.claude/worktrees
mkdir -p "$root/.forge/tracks"
jq -n '{track: "tr", goal: "g", status: "open", notes: [], features: [{feature: "feat", delivers: "d", depends: []}, {feature: "calm", delivers: "c", depends: []}], shipped: []}' >"$root/.forge/tracks/tr.json"
jq -n '{phases: [{slug: "alpha", number: "07", goal: "a", spec: [], requirements: [], depends: []}, {slug: "gamma", number: "09", goal: "c", spec: [], requirements: [], depends: []}]}' >"$sd/features/$tf/split.json"
for p in 07-alpha 09-gamma; do
  jq -n --arg n "${p%%-*}" --arg s "${p#*-}" '{track: "tr", feature: "feat", number: $n, slug: $s, goal: "g", spec: [], requirements: [], depends: []}' >"$sd/phases/$p/spec.json"
done
session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
session "proj P09 $tfs" working "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009
transcript "$wt/$tf-09" aaaaaaa9-0000-4000-8000-000000000009 25
status() {
  (cd "$root" && env PATH="$bin:$PATH" "$forge" status) >"$env_dir/status" 2>&1 ||
    fail "forge status exits 0: $(cat "$env_dir/status")"
}
status
! grep -q stalled "$env_dir/status" || fail "no stall, no stalled status: $(cat "$env_dir/status")"
run
plain 07-alpha "a first stall"
status
! grep -q stalled "$env_dir/status" || fail "a plain stall does not show stalled in forge status: $(cat "$env_dir/status")"
age "$sd/phases/07-alpha/events.jsonl" 10
age "$sd/phases/09-gamma/events.jsonl" 45
run
notified 07-alpha "a stall 10 min after the previous one"
plain 09-gamma "a stall 45 min after the previous one"
status
line=$(grep stalled "$env_dir/status" || true)
[ -n "$line" ] || fail "forge status shows stalled while phase 07's latest event is a notified repeat stall: $(cat "$env_dir/status")"
[ "$(printf '%s\n' "$line" | wc -l)" = 1 ] || fail "one stalled status, for phase 07 of tr/feat: $line"
printf '%s\n' "$line" | grep -Eq '(^|[^a-z])feat([^a-z]|$)|07' || fail "the stalled status belongs to tr/feat phase 07: $line"
! printf '%s\n' "$line" | grep -q calm || fail "a feature without a stalled phase is not stalled: $line"
jq -n '{status: "done", summary: "s"}' >"$sd/phases/07-alpha/result.json"
status
! grep -q stalled "$env_dir/status" || fail "a done phase is not stalled, though its latest event is a notified stall: $(cat "$env_dir/status")"
rm "$sd/phases/07-alpha/result.json"
(cd "$root" && "$forge" event 07 jev "site: resumed") >"$env_dir/ev" 2>&1 || fail "forge event 07 logs a later event: $(cat "$env_dir/ev")"
status
! grep -q stalled "$env_dir/status" || fail "a later event reverts the stalled status: $(cat "$env_dir/status")"
grep -qw stalled "$repo/bin/forge.d/help/status.txt" || fail "status.txt documents the stalled status"
ok status
fi

export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=forge GIT_AUTHOR_EMAIL=forge@example.com GIT_COMMITTER_NAME=forge GIT_COMMITTER_EMAIL=forge@example.com
mkrepo() {
  git init -q -b main "$1"
  cat >"$1/port" <<'STUB'
#!/usr/bin/env bash
l=$(git rev-parse --path-format=absolute --git-common-dir)/forge-land.lock
h=unlocked
flock -n "$l" true || h=locked
printf 'port %s %s %s\n' "$PWD" "$*" "$h" >>"$WD_LOG"
if [ "${WD_PORT_RC:-0}" != 0 ]; then
  echo "rsync: boom" >&2
  exit "$WD_PORT_RC"
fi
echo "ported $(git rev-parse --short HEAD)"
STUB
  chmod +x "$1/port"
  git -C "$1" add port
  git -C "$1" commit -q -m port
  git -C "$1" rev-parse --show-toplevel
}
ago() { date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
queue() { jq -nc --arg r "$1" --arg c "$2" --arg t "${3:-$(ago 0)}" '{repo: $r, commit: $c, time: $t}' >>"$pending"; }
pcase() {
  setup "$1"
  unset WD_FIRST WD_PORT_RC WD_SWAP
  cat >"$bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$WD_LOG"
[ "${1:-}" = agents ] || exit 1
if [ -n "${WD_FIRST:-}" ] && [ ! -e "$WD_FIRST.used" ]; then
  : >"$WD_FIRST.used"
  [ -z "${WD_SWAP:-}" ] || mv "$WD_SWAP" "$HOME/.local/state/forge/port.pending"
  [ "$(cat "$WD_FIRST")" != FAIL ] || exit 1
  cat "$WD_FIRST"
  exit 0
fi
cat "$WD_AGENTS"
STUB
  chmod +x "$bin/claude"
  wt=$root/.claude/worktrees
  session "proj P07 $tfs" working "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007
  transcript "$wt/$tf-07" aaaaaaa7-0000-4000-8000-000000000007 30
  pending=$HOME/.local/state/forge/port.pending
  mkdir -p "${pending%/*}"
  A=$(mkrepo "$env_dir/repoA")
  amain=$(git -C "$A" rev-parse main)
  session "repoA P08 $tfs" working "$A/.claude/worktrees/$tf-08" ""
}
idle_first() { echo '[]' >"$env_dir/first.json"; export WD_FIRST=$env_dir/first.json; }
prun() { (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog) >"$env_dir/out" 2>&1 || true; }
scanned() {
  stalled 07-alpha "proj P07 $tfs" aaaaaaa7-0000-4000-8000-000000000007 30
  after "$1"
}
after() {
  awk '/^port |^notify-send --\|forge: queued port failed\|/ { p = NR } /^claude agents.*--json/ { c = NR } END { exit !(c > p) }' "$log" ||
    fail "$1: the stall scan lists sessions after the queued port is handled: $(cat "$log")"
}
unported() { ! grep -q '^port ' "$log" || fail "$1 runs no port: $(cat "$log")"; }
kept() { [ "$(jq -c 'del(.alerted)' "$pending" 2>/dev/null)" = "$2" ] || fail "$1 keeps the pending line: '$(cat "$pending" 2>/dev/null)', want '$2'"; }

if want port-run; then
pcase port-run
B=$(mkrepo "$env_dir/repoB")
git -C "$B" switch -q -c side
echo x >"$B/x"
git -C "$B" add x
git -C "$B" commit -q -m side
bside=$(git -C "$B" rev-parse side)
git -C "$B" switch -q main
queue "$A" "$amain"
queue "$B" "$bside"
bline=$(tail -n1 "$pending")
idle_first
run
grep -qx "port $A --apply locked" "$log" || fail "with no forge session working the queued port runs ./port --apply in $A under its forge-land.lock: $(cat "$log")"
grep -qxF "forge: ported $(git -C "$A" rev-parse --short main) from the queued golive of $A" "$env_dir/out" || fail "a queued port that ran says so: $(cat "$env_dir/out")"
! grep -q "^port $B" "$log" || fail "main behind the queued commit runs no port in $B: $(cat "$log")"
kept "a ported repo's line is removed while main behind the queued commit" "$bline"
grep -F "$B" "$env_dir/out" | grep -q main || fail "main behind the queued commit prints why, naming $B and main: $(cat "$env_dir/out")"
scanned "a queued port run"
git -C "$B" merge -q --ff-only side
rm -f "$WD_FIRST.used"
: >"$log"
run
grep -qx "port $B --apply locked" "$log" || fail "once main holds the queued commit the port runs in $B: $(cat "$log")"
[ ! -e "$pending" ] || fail "the pending file is removed once its last line is ported: $(cat "$pending")"
after "the second queued port"
ok port-run
fi

if want port-working; then
pcase port-working
queue "$A" "$amain"
line=$(cat "$pending")
prun
unported "a working forge session"
kept "a working forge session" "$line"
grep -qxF "forge: port still queued: 1 forge sessions working" "$env_dir/out" || fail "a working forge session keeps the port queued and says so: $(cat "$env_dir/out")"
scanned "a working forge session"
ok port-working
fi

if want port-other-project; then
pcase port-other-project
jq 'map(select(.name | startswith("repoA ") | not))' "$agents" >"$agents.new" && mv "$agents.new" "$agents"
queue "$A" "$amain"
prun
grep -qx "port $A --apply locked" "$log" || fail "a forge session working only in another project does not hold the queued port of $A: $(cat "$log")"
[ ! -e "$pending" ] || fail "a port with no session in its project removes the pending file: $(cat "$pending")"
ok port-other-project
fi

if want port-live-install; then
pcase port-live-install
jq 'map(select(.name | startswith("repoA ") | not))' "$agents" >"$agents.new" && mv "$agents.new" "$agents"
git -C "$A" config forge.liveInstall true
queue "$A" "$amain"
line=$(cat "$pending")
prun
unported "a forge session in another project of a forge.liveInstall repo"
kept "a forge session in another project of a forge.liveInstall repo" "$line"
grep -qxF "forge: port still queued: 1 forge sessions working" "$env_dir/out" || fail "a forge.liveInstall repo waits for every forge session: $(cat "$env_dir/out")"
ok port-live-install
fi

if want port-list; then
pcase port-list
queue "$A" "$amain"
line=$(cat "$pending")
echo FAIL >"$env_dir/first.json"
export WD_FIRST=$env_dir/first.json
prun
unported "a failed session list"
kept "a failed session list" "$line"
grep -qxF "forge: port still queued: cannot list Claude sessions" "$env_dir/out" || fail "a failed session list keeps the port queued and says so: $(cat "$env_dir/out")"
scanned "a failed session list"
ok port-list
fi

if want port-branch; then
pcase port-branch
git -C "$A" switch -q -c feature
queue "$A" "$amain"
line=$(cat "$pending")
idle_first
prun
unported "R off main"
kept "R off main" "$line"
grep -F "$A" "$env_dir/out" | grep -q main || fail "R off main prints why, naming $A and main: $(cat "$env_dir/out")"
scanned "R off main"
ok port-branch
fi

if want port-fail; then
pcase port-fail
queue "$A" "$amain"
line=$(cat "$pending")
idle_first
export WD_PORT_RC=3
prun
grep -qx "port $A --apply locked" "$log" || fail "the failing queued port ran: $(cat "$log")"
kept "a failing port" "$line"
grep -qi fail "$env_dir/out" || fail "a failing queued port prints the failure: $(cat "$env_dir/out")"
n=$(grep -cF "notify-send --|forge: queued port failed|$A: " "$log" || true)
[ "$n" = 1 ] || fail "a failing queued port sends one forge notify \"forge: queued port failed\" \"$A: <cause>\": $(cat "$log")"
grep -qxF "unix:path=$XDG_RUNTIME_DIR/bus" "$WD_BUS" || fail "the queued port alert uses the unix:path=\$XDG_RUNTIME_DIR/bus fallback: $(cat "$WD_BUS")"
scanned "a failing port"
rm -f "$WD_FIRST.used"
: >"$log"
prun
grep -qx "port $A --apply locked" "$log" || fail "a failing queued port is retried on the next scan: $(cat "$log")"
kept "a port failing again" "$line"
grep -qi fail "$env_dir/out" || fail "a queued port failing again prints the failure: $(cat "$env_dir/out")"
! grep -qF 'notify-send --|forge: queued port failed|' "$log" || fail "a queued port that failed and alerted before sends no second alert: $(cat "$log")"
after "a port failing again"
queue "$A" "$amain"
sed -i 1d "$pending"
line=$(cat "$pending")
rm -f "$WD_FIRST.used"
: >"$log"
prun
n=$(grep -cF "notify-send --|forge: queued port failed|$A: " "$log" || true)
[ "$n" = 1 ] || fail "a port queued again alerts again when it fails: $(cat "$log")"
ok port-fail
fi

if want port-held; then
pcase port-held
queue "$A" "$amain"
line=$(cat "$pending")
idle_first
exec 9>"$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/forge-land.lock"
flock 9
prun 9>&-
exec 9>&-
unported "a held forge-land.lock"
kept "a held forge-land.lock" "$line"
grep -F "$A" "$env_dir/out" | grep -q forge-land.lock || fail "a held forge-land.lock keeps the port queued without waiting and says so: $(cat "$env_dir/out")"
scanned "a held forge-land.lock"
ok port-held
fi

if want port-requeue; then
pcase port-requeue
echo y >"$A/y"
git -C "$A" add y
git -C "$A" commit -q -m y
queue "$A" "$amain"
amain=$(git -C "$A" rev-parse main)
jq -nc --arg r "$A" --arg c "$amain" '{repo: $r, commit: $c, time: "2026-10-01T00:05:00Z"}' >"$env_dir/requeued"
export WD_SWAP=$env_dir/requeued
idle_first
run
grep -qx "port $A --apply locked" "$log" || fail "a port queued again before the lock is taken runs once: $(cat "$log")"
[ ! -e "$pending" ] || fail "a port queued again before the lock is taken is cleared by the port that covers it: $(cat "$pending")"
ok port-requeue
fi

if want port-flip; then
pcase port-flip
R=$(mkrepo "$env_dir/flipped")
state_at "$R"
mkdir -p "$sd/features/aa-one"
jq -n '{track: "aa", goal: "g", status: "open", notes: [], features: [{feature: "one", delivers: "d", depends: []}], shipped: []}' >"$R/.forge/tracks/aa.json"
reqs='{"requirements": [
  {"id": "AAA-01", "text": "one ships", "done": false, "owed": {"kind": "deferred", "check": "prod serves one", "owner": "aa/one", "until": "release"}},
  {"id": "AAA-02", "text": "one docs", "done": false, "owed": {"kind": "bookkeeping", "check": "docs list one", "owner": "aa/one"}}
]}'
rf=$sd/features/aa-one/requirements.json
jq . <<<"$reqs" >"$rf"
todo=$(printf '%s\n' '# Todo' '' '- aa/one AAA-01 owes deferred: prod serves one' '- aa/one AAA-02 owes bookkeeping: docs list one')
printf '%s\n' "$todo" >"$R/.forge/todo.md"
git -C "$R" add -A && git -C "$R" commit -q -m owed
rhead=$(git -C "$R" rev-parse HEAD)
jq -nc --arg r "$A" --arg c "$amain" --arg t "$(ago 0)" --arg f "$R" '{repo: $r, commit: $c, time: $t, root: $f, branches: ["forge/aa-one", "side"]}' >"$pending"
idle_first
prun
grep -qx "port $A --apply locked" "$log" || fail "a queued golive with owed requirements runs its port: $(cat "$log")"
[ ! -e "$pending" ] || fail "a queued port with until: release owed requirements removes its line: $(cat "$pending")"
jq -e --argjson w "$reqs" '. == $w' "$rf" >/dev/null || fail "a queued port leaves the until: release requirements owed: $(cat "$rf")"
[ "$(cat "$R/.forge/todo.md")" = "$todo" ] || fail "a queued port leaves todo.md unchanged: $(cat "$R/.forge/todo.md")"
[ "$(git -C "$R" rev-parse HEAD)" = "$rhead" ] && [ -z "$(git -C "$R" status --porcelain)" ] || fail "a queued port commits nothing in the project root: $(git -C "$R" log --oneline -3)"
! grep -qF 'forge: owed flip failed' "$log" || fail "a queued port sends no owed-flip notify: $(cat "$log")"
! grep -qF 'until: release' "$env_dir/out" || fail "a queued port prints no until: release flip: $(cat "$env_dir/out")"
jq -nc --arg r "$A" --arg c "$amain" --arg t "$(ago 0)" --arg f "$R" '{repo: $r, commit: $c, time: $t, root: $f, branches: ["forge/aa-one"], ported: true}' >"$pending"
rm -f "$WD_FIRST.used"
: >"$log"
prun
unported "a line marked ported"
[ ! -e "$pending" ] || fail "a line marked ported is cleared: $(cat "$pending")"
jq -e --argjson w "$reqs" '. == $w' "$rf" >/dev/null || fail "clearing a line marked ported leaves the requirements: $(cat "$rf")"
! grep -qF 'forge: owed flip failed' "$log" || fail "clearing a line marked ported sends no owed-flip notify: $(cat "$log")"
ok port-flip
fi

if want port-empty; then
pcase port-empty
: >"$pending"
run
unported "an empty pending file"
scanned "an empty pending file"
grep -qF port.pending "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents the queued port --apply from port.pending"
ok port-empty
fi

applied() { grep -cF 'notify-send --|forge: port applied|' "$log" || true; }
notice() {
  local want="notify-send --|forge: port applied|$(git -C "$A" rev-parse --short main) applied after 2 h queued with $2 sessions working"
  [ "$(applied)" = 1 ] && grep -qxF "$want" "$log" || fail "$1 sends exactly one forge notify naming the sha and count, '${want#notify-send --|}': $(cat "$log")"
}

if want port-young; then
pcase port-young
queue "$A" "$amain" "$(ago 119)"
line=$(cat "$pending")
prun
unported "a working forge session with a line 1 h 59 min old"
kept "a working forge session with a line 1 h 59 min old" "$line"
grep -qxF "forge: port still queued: 1 forge sessions working" "$env_dir/out" || fail "a line 1 h 59 min old keeps the existing still-queued message: $(cat "$env_dir/out")"
[ "$(applied)" = 0 ] || fail "a line kept queued sends no applied notice: $(cat "$log")"
scanned "a line 1 h 59 min old"
ok port-young
fi

if want port-forced; then
pcase port-forced
B=$(mkrepo "$env_dir/repoB")
session "repoB P09 $tfs" working "$B/.claude/worktrees/$tf-09" ""
queue "$A" "$amain" "$(ago 120)"
queue "$B" "$(git -C "$B" rev-parse main)" "$(ago 119)"
bline=$(tail -n1 "$pending")
prun
grep -qx "port $A --apply locked" "$log" || fail "a working forge session with a line 2 h old runs ./port --apply in $A under its forge-land.lock: $(cat "$log")"
! grep -q "^port $B" "$log" || fail "a line 1 h 59 min old beside a 2 h old one runs no port in $B: $(cat "$log")"
kept "a forced port removes its line and keeps the younger one" "$bline"
notice "a forced port" 1
grep -qxF "forge: port still queued: 1 forge sessions working" "$env_dir/out" || fail "the younger line keeps the still-queued message: $(cat "$env_dir/out")"
scanned "a forced port"
ok port-forced
fi

if want port-idle; then
pcase port-idle
queue "$A" "$amain" "$(ago 180)"
idle_first
prun
grep -qx "port $A --apply locked" "$log" || fail "with no forge session working a 3 h old line is ported: $(cat "$log")"
[ ! -e "$pending" ] || fail "a port with 0 sessions removes the pending file: $(cat "$pending")"
[ "$(applied)" = 0 ] || fail "an apply with 0 sessions working sends no applied notice: $(cat "$log")"
scanned "a port with 0 sessions"
ok port-idle
fi

if want port-unlisted; then
pcase port-unlisted
B=$(mkrepo "$env_dir/repoB")
queue "$A" "$amain" "$(ago 120)"
queue "$B" "$(git -C "$B" rev-parse main)" "$(ago 119)"
bline=$(tail -n1 "$pending")
echo FAIL >"$env_dir/first.json"
export WD_FIRST=$env_dir/first.json
prun
grep -qx "port $A --apply locked" "$log" || fail "a failed session list still ports a 2 h old line: $(cat "$log")"
! grep -q "^port $B" "$log" || fail "a failed session list runs no port for a line 1 h 59 min old: $(cat "$log")"
kept "a failed session list removes the forced line and keeps the younger one" "$bline"
notice "a forced port with a failed session list" unknown
grep -qxF "forge: port still queued: cannot list Claude sessions" "$env_dir/out" || fail "a failed session list keeps the younger line with its message: $(cat "$env_dir/out")"
scanned "a forced port with a failed session list"
ok port-unlisted
fi

if want port-forced-fail; then
pcase port-forced-fail
queue "$A" "$amain" "$(ago 120)"
line=$(cat "$pending")
export WD_PORT_RC=3
prun
grep -qx "port $A --apply locked" "$log" || fail "the failing forced port ran: $(cat "$log")"
kept "a failing forced port" "$line"
n=$(grep -cF "notify-send --|forge: queued port failed|$A: " "$log" || true)
[ "$n" = 1 ] || fail "a failing forced port sends the existing queued port failed alert once: $(cat "$log")"
[ "$(applied)" = 0 ] || fail "a failing forced port sends no applied notice: $(cat "$log")"
scanned "a failing forced port"
ok port-forced-fail
fi

if want port-notice-fail; then
pcase port-notice-fail
queue "$A" "$amain" "$(ago 120)"
WD_NOTIFY_RC=1 prun
grep -qx "port $A --apply locked" "$log" || fail "the forced port whose notice fails ran: $(cat "$log")"
[ ! -e "$pending" ] || fail "a forced port whose notice fails still removes its line: $(cat "$pending")"
grep -qxF "forge: cannot send the forced-port notice for $A through forge notify" "$env_dir/out" || fail "a failed forced-port notice says so: $(cat "$env_dir/out")"
ok port-notice-fail
fi

if want port-time; then
pcase port-time
queue "$A" "$amain" "not a time"
line=$(cat "$pending")
prun
unported "an unparsable queue time"
kept "an unparsable queue time" "$line"
grep -qxF "forge: cannot read the queue time of $A in $pending" "$env_dir/out" || fail "an unparsable queue time says so: $(cat "$env_dir/out")"
grep -qxF "forge: port still queued: 1 forge sessions working" "$env_dir/out" || fail "an unparsable queue time counts as younger than 2 h: $(cat "$env_dir/out")"
ok port-time
fi

if want port-help; then
h=$repo/bin/forge.d/help/watchdog.txt
grep -qE '(^|[^0-9])2( |-)?(h|hours?)([^a-z]|$)' "$h" || fail "watchdog.txt documents the 2-hour limit of a queued port"
grep -qF 'forge: port applied' "$h" || fail "watchdog.txt documents the forge: port applied notice of a forced port"
grep -qw unknown "$h" || fail "watchdog.txt documents the unknown session count"
ok port-help
fi

if want perf-pull; then
setup perf-pull
pa=$env_dir/pa pb=$env_dir/pb pc=$env_dir/pc
rf=$HOME/.local/state/forge/watchdog-roots sf=$HOME/.local/state/forge/perf-pull
for d in "$pa" "$pb" "$pc"; do mkdir -p "$d/.forge/phases"; done
printf '## Commands\n\n- Perf log: `echo`\n' >"$pa/.forge/TESTING.md"
printf '## Commands\n\n- Test: `true`\n' >"$pb/.forge/TESTING.md"
printf '## Commands\n\n- Perf log: `echo`\n' >"$pc/.forge/TESTING.md"
export WD_PULLS=$env_dir/pulls.log
: >"$WD_PULLS"
cat >"$bin/forge" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "perf pull" ] || exit 0
o=
for f in 8 9; do [ ! -e "/proc/$$/fd/$f" ] || o+=" $f"; done
printf '%s|%s|%s\n' "${FORGE_ROOT-unset}" "$(readlink "/proc/$$/fd/0")" "${o# }" >>"$WD_PULLS"
[ "$FORGE_ROOT" != "${WD_PULL_FAIL:-}" ] || { echo "stub pull failed" >&2; exit 3; }
[ "$FORGE_ROOT" != "${WD_PULL_HANG:-}" ] || sleep 30
STUB
chmod +x "$bin/forge"
pprun() {
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog 8>/dev/null 9>/dev/null) >"$env_dir/out" 2>&1 ||
    fail "perf-pull: forge watchdog exits 0: $(cat "$env_dir/out")"
}
pulls() { grep -c "^$1|" "$WD_PULLS" || true; }
printf '%s\n' "$pa" "$pb" >"$rf"
pprun
[ "$(cat "$WD_PULLS")" = "$pa|/dev/null|" ] || fail "the first scan runs FORGE_ROOT=<root> forge perf pull once for the root with a - Perf log: line, stdin /dev/null and fd 8/9 closed, and skips the root without one: $(cat "$WD_PULLS" "$env_dir/out")"
grep -q "^$pa"$'\t''[0-9][0-9]*$' "$sf" || fail "the scan records the last pull time of $pa in $sf: $(cat "$sf" 2>/dev/null)"
! grep -q '^forge: warning: ' "$env_dir/out" || fail "a passing pull prints no warning: $(cat "$env_dir/out")"
ls "${sf%/*}" | grep -q '^perf-pull\.' && fail "the state file is written through a temp file and a rename, leaving no temp file: $(ls "${sf%/*}")"
printf '%s\n' "$pa" "$pb" >"$rf"
pprun
[ "$(pulls "$pa")" = 1 ] || fail "a root pulled less than 7 days ago is not pulled again: $(cat "$WD_PULLS")"
printf '%s\t%s\n' "$pa" $((EPOCHSECONDS - 6 * 86400)) >"$sf"
printf '%s\n' "$pa" "$pb" >"$rf"
pprun
[ "$(pulls "$pa")" = 1 ] || fail "a root pulled 6 days ago is not pulled again: $(cat "$WD_PULLS")"
printf '%s\t%s\n' "$pa" $((EPOCHSECONDS - 7 * 86400)) >"$sf"
printf '%s\n' "$pc" "$pa" "$pb" >"$rf"
: >"$log"
WD_PULL_FAIL=$pc pprun
[ "$(pulls "$pa")" = 2 ] || fail "a root whose recorded pull is 7 days old is pulled again: $(cat "$WD_PULLS" "$env_dir/out")"
[ "$(pulls "$pc")" = 1 ] || fail "a new root with a - Perf log: line is pulled: $(cat "$WD_PULLS")"
[ "$(pulls "$pb")" = 0 ] || fail "a root with no - Perf log: line is never pulled: $(cat "$WD_PULLS")"
grep -qF "forge: warning: forge perf pull exited 3 in $pc" "$env_dir/out" || fail "a failing pull prints a forge: warning: line naming its exit and root: $(cat "$env_dir/out")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan goes on after a failing pull: $(cat "$log")"
now=$EPOCHSECONDS
for d in "$pa" "$pc"; do
  t=$(awk -F'\t' -v r="$d" '$1 == r { print $2 }' "$sf")
  [ -n "$t" ] && [ $((now - t)) -lt 300 ] || fail "the scan records the new pull time of $d in $sf: $(cat "$sf")"
done
pd=$env_dir/pd
mkdir -p "$pd/.forge/phases"
printf '## Commands\n\n- Perf log: `echo`\n' >"$pd/.forge/TESTING.md"
printf '%s\n' "$pd" >"$rf"
: >"$log"
s0=$EPOCHSECONDS
FORGE_PERF_TIMEOUT=1 WD_PULL_HANG=$pd pprun
[ $((EPOCHSECONDS - s0)) -lt 20 ] || fail "a hung pull is killed after FORGE_PERF_TIMEOUT seconds: the scan took $((EPOCHSECONDS - s0)) s"
[ "$(pulls "$pd")" = 1 ] || fail "the hung root is pulled once: $(cat "$WD_PULLS")"
grep -qF "forge: warning: forge perf pull in $pd timed out after 1 s; it runs again in 7 days" "$env_dir/out" || fail "a hung pull prints a forge: warning: timed out line naming its root: $(cat "$env_dir/out")"
grep -q '^claude agents.*--json' "$log" || fail "the stall scan runs with a hung pull: $(cat "$log")"
t=$(awk -F'\t' -v r="$pd" '$1 == r { print $2 }' "$sf")
[ -n "$t" ] && [ $((EPOCHSECONDS - t)) -lt 300 ] || fail "the scan records the pull time of a timed-out pull of $pd in $sf: $(cat "$sf")"
h=$repo/bin/forge.d/help/watchdog.txt
for w in 'forge perf pull' '~/.local/state/forge/perf-pull' '7 days' '- Perf log:' FORGE_PERF_TIMEOUT; do
  grep -qF -- "$w" "$h" || fail "watchdog.txt documents the weekly perf pull: no '$w'"
done
ok perf-pull
fi

service=$repo/systemd/forge-watchdog.service
timer=$repo/systemd/forge-watchdog.timer
directive() {
  awk -v s="[$2]" -v k="$3" '
    /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
    sec == s && index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"
}
expect() {
  local got
  got=$(directive "$1" "$2" "$3")
  [ "$got" = "$4" ] || fail "$(basename "$1") [$2] $3 must be '$4', got '${got}'"
}
if want service; then
[ -f "$service" ] || fail "missing $service"
[ -f "$timer" ] || fail "missing $timer"
[ -n "$(directive "$service" Unit Description)" ] || fail "forge-watchdog.service needs a [Unit] Description"
expect "$service" Service Type oneshot
expect "$service" Service ExecStart '%h/.local/bin/forge watchdog'
env=$(directive "$service" Service Environment)
[ "$(printf '%s\n' "$env" | grep -c '^PATH=')" = 1 ] || fail "forge-watchdog.service needs one Environment=PATH=, got '${env}'"
path=$(printf '%s\n' "$env" | sed -n 's/^PATH=//p')
case ":$path:" in *:%h/.local/bin:*) ;; *) fail "unit PATH must hold %h/.local/bin, where forge and claude live, got '${path}'" ;; esac
case ":$path:" in *:/usr/bin:*) ;; *) fail "unit PATH must hold /usr/bin for jq and notify-send, got '${path}'" ;; esac
case "$path" in *fnm*) fail "unit PATH must hold no fnm path, got '${path}'" ;; esac
if grep -Eiq 'fnm|\.bashrc|\.bash_profile|\.profile|\.zshrc' "$service"; then
  fail "forge-watchdog.service must source no fnm setup or shell rc file: $(cat "$service")"
fi
ok service
fi

if want timer; then
[ -n "$(directive "$timer" Unit Description)" ] || fail "forge-watchdog.timer needs a [Unit] Description"
cal=$(directive "$timer" Timer OnCalendar)
active=$(directive "$timer" Timer OnUnitActiveSec)
if [ -n "$cal" ]; then
  norm=$(systemd-analyze calendar "$cal" 2>&1 | sed -n 's/^ *Normalized form: //p')
  [ "$norm" = '*-*-* *:00/5:00' ] || fail "forge-watchdog.timer OnCalendar must fire every 5 minutes, got '$cal' ($norm)"
elif [ -n "$active" ]; then
  case "$active" in 5min | 5m | 300 | 300s) ;; *) fail "forge-watchdog.timer OnUnitActiveSec must be 5 minutes, got '$active'" ;; esac
  [ -n "$(directive "$timer" Timer OnBootSec)$(directive "$timer" Timer OnActiveSec)" ] ||
    fail "forge-watchdog.timer with OnUnitActiveSec needs OnBootSec or OnActiveSec to fire the first time"
else
  fail "forge-watchdog.timer must fire every 5 minutes (OnCalendar or OnUnitActiveSec): $(cat "$timer")"
fi
expect "$timer" Install WantedBy timers.target
ok timer
fi

if want install; then
grep -qF -- --install "$repo/bin/forge.d/help/watchdog.txt" || fail "watchdog.txt documents --install"
setup install
units=$HOME/.config/systemd/user
install() {
  (cd "$env_dir" && timeout 60 env PATH="$bin:$PATH" "$forge" watchdog --install) >"$env_dir/out" 2>&1
}
refused() {
  if install; then fail "--install $1 must fail: $(cat "$env_dir/out")"; fi
  ! grep -q '^Usage:' "$env_dir/out" || fail "--install $1 fails with its own message, not the usage: $(head -3 "$env_dir/out")"
  grep -qF './port --apply' "$env_dir/out" || fail "--install $1 names ./port --apply: $(cat "$env_dir/out")"
  grep -qF forge-watchdog "$env_dir/out" || fail "--install $1 names the missing forge-watchdog units: $(cat "$env_dir/out")"
  ! grep -q '^systemctl' "$log" || fail "--install $1 runs no systemctl: $(cat "$log")"
}
mkdir -p "$units"
refused "without installed units"
[ -z "$(ls -A "$units")" ] || fail "--install writes no unit files itself: $(ls -A "$units")"
echo timer >"$units/forge-watchdog.timer"
refused "without forge-watchdog.service"
[ "$(ls -A "$units")" = forge-watchdog.timer ] || fail "--install writes no unit files itself: $(ls -A "$units")"
echo service >"$units/forge-watchdog.service"
install || fail "--install with the installed units exits 0: $(cat "$env_dir/out")"
grep -qx 'systemctl --user enable --now forge-watchdog.timer' "$log" || fail "--install runs systemctl --user enable --now forge-watchdog.timer: $(cat "$log")"
[ "$(cat "$units/forge-watchdog.timer")$(cat "$units/forge-watchdog.service")" = timerservice ] || fail "--install leaves the installed units untouched"
: >"$log"
if WD_SYSTEMCTL_RC=1 install; then fail "--install fails when systemctl fails: $(cat "$env_dir/out")"; fi
grep -qx 'systemctl --user enable --now forge-watchdog.timer' "$log" || fail "--install ran systemctl: $(cat "$log")"
ok install
fi
[ -z "$only" ] || fail "no case $only"
