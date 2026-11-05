#!/usr/bin/env bash
. "$(dirname "$0")/../forge-common.sh"
export FORGE_CPUS=16
machine() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' $(($1 * 1048576)) $(($2 * 1048576)) >"$FORGE_PROC_ROOT/meminfo"; }
lim() { "$forge" limits | sed -n "s/^$1=//p"; }
unset FORGE_MAX_SESSIONS FORGE_CONCURRENCY FORGE_TEST_RUNS

if want table; then
  while read -r g s c r cap; do
    machine "$g" "$g"
    [ "$(lim FORGE_MAX_SESSIONS)/$(lim FORGE_CONCURRENCY)/$(lim FORGE_TEST_RUNS)/$(lim 'test memory cap')" = "$s/$c/$r/$cap" ] ||
      fail "$g GiB limits: $("$forge" limits)"
  done <<'T'
8 2 1 1 2G
16 4 2 1 4G
32 6 4 2 4G
93 6 4 2 4G
T
  ok table
fi

if want cpus; then
  machine 93 93
  [ "$(FORGE_CPUS=2 lim FORGE_MAX_SESSIONS)/$(FORGE_CPUS=2 lim FORGE_CONCURRENCY)/$(FORGE_CPUS=2 lim FORGE_TEST_RUNS)" = 2/1/1 ] || fail "2 CPUs: $(FORGE_CPUS=2 "$forge" limits)"
  ok cpus
fi

if want test-cap; then
  for g in 8 16 32 93; do
    machine "$g" 1
    [ "$(lim 'test memory cap')" = 1048576K ] || fail "$g GiB with 1 GiB available: cap $(lim 'test memory cap')"
  done
  printf 'MemTotal: 8388608 kB\nMemAvailable: 1000000 kB\n' >"$FORGE_PROC_ROOT/meminfo"
  [ "$(lim 'test memory cap')" = 1000000K ] || fail "the cap never exceeds what is available: $(lim 'test memory cap')"
  ok test-cap
fi

if want override; then
  machine 8 8
  printf 'FORGE_MAX_SESSIONS=9\nFORGE_CONCURRENCY=7\nFORGE_TEST_RUNS=3\n' >"$tmp/env"
  [ "$(FORGE_ENV=$tmp/env lim FORGE_MAX_SESSIONS)/$(FORGE_ENV=$tmp/env lim FORGE_CONCURRENCY)/$(FORGE_ENV=$tmp/env lim FORGE_TEST_RUNS)" = 9/7/3 ] || fail "the env file overrides: $(FORGE_ENV=$tmp/env "$forge" limits)"
  ok override
fi

if want darwin-memory; then
  mkdir -p "$tmp/dbin"
  printf '#!/bin/sh\ncase $2 in hw.memsize) echo 17179869184 ;; vm.loadavg) echo "{ 1.25 1.00 0.75 }" ;; kern.boottime) echo "{ sec = 100, usec = 0 }" ;; hw.ncpu) echo 8 ;; esac\n' >"$tmp/dbin/sysctl"
  printf '#!/bin/sh\nprintf "Mach Virtual Memory Statistics: (page size of 16384 bytes)\\nPages free:  100000.\\nPages active:  5.\\nPages inactive:  200000.\\nPages speculative:  50000.\\n"\n' >"$tmp/dbin/vm_stat"
  chmod +x "$tmp/dbin/sysctl" "$tmp/dbin/vm_stat"
  d=$(env -u FORGE_PROC_ROOT FORGE_UNAME=Darwin PATH="$tmp/dbin:$PATH" "$forge" limits)
  grep -qx 'FORGE_MAX_SESSIONS=4' <<<"$d" && grep -qx 'memory available KiB=5600000' <<<"$d" && grep -qx 'load=1.25' <<<"$d" || fail "macOS memory and load: $d"
  ok darwin-memory
fi

if want bg; then
  mkdir -p "$tmp/bgbin"
  export BG_LOG=$tmp/bg.log
  for c in systemd-run systemctl launchctl; do
    printf '#!/bin/sh\necho "%s $*" >>"$BG_LOG"\n' "$c" >"$tmp/bgbin/$c"
    chmod +x "$tmp/bgbin/$c"
  done
  run_bg() { PATH=$tmp/bgbin:$PATH "$forge" bg "$@"; }
  FORGE_UNAME=Linux run_bg job1 --cwd /w --env A=1 -- sleep 5
  grep -q '^systemd-run --user --unit=job1 --collect --quiet --working-directory=/w --setenv=A=1 --setenv=PATH=.* -- sleep 5$' "$BG_LOG" || fail "linux bg: $(cat "$BG_LOG")"
  FORGE_UNAME=Linux run_bg --stop job1
  grep -qx 'systemctl --user stop job1' "$BG_LOG" || fail "linux stop: $(cat "$BG_LOG")"
  : >"$BG_LOG"
  HOME=$tmp FORGE_UNAME=Darwin run_bg job2 --cwd /w -- sleep 5
  grep -q '^launchctl submit -l job2 -o .*job2.log -e .*job2.log -- .*bash -c cd /w && exec env PATH=.* sleep 5$' "$BG_LOG" || fail "macos bg: $(cat "$BG_LOG")"
  : >"$BG_LOG"
  FORGE_UNAME=Darwin run_bg --stop job2
  grep -qx 'launchctl remove job2' "$BG_LOG" || fail "macos stop: $(cat "$BG_LOG")"
  [ "$(code run_bg 'bad name' -- true)" != 0 ] || fail "a name with a space is refused"
  ok bg
fi

if want notify; then
  mkdir -p "$tmp/nbin"
  export N_LOG=$tmp/n.log
  printf '#!/bin/sh\necho "osascript $*" >>"$N_LOG"\n' >"$tmp/nbin/osascript"
  chmod +x "$tmp/nbin/osascript"
  FORGE_UNAME=Darwin PATH=$tmp/nbin:$PATH "$forge" notify T B
  grep -q '^osascript .*display notification.* -- T B$' "$N_LOG" || fail "macOS notify: $(cat "$N_LOG")"
  nosend=$tmp/nosend
  mkdir -p "$nosend"
  for c in timeout id; do ln -sf "$(command -v "$c")" "$nosend/$c"; done
  w() { FORGE_UNAME=Linux WSL_DISTRO_NAME=Ubuntu PATH=$nosend:$(dirname "$(command -v jq)"):$(dirname "$(command -v bash)") "$forge" notify T B 2>&1; }
  rm -f "$XDG_STATE_HOME/forge/notify-warned"
  o=$(FORGE_NOTIFY_TIMEOUT=2 w) || fail "WSL2 without a notifier exits 0: $o"
  ok notify
fi

if want watchdog-launchd; then
  mkdir -p "$tmp/lbin" "$tmp/lhome/Library/LaunchAgents"
  export L_LOG=$tmp/l.log
  printf '#!/bin/sh\necho "launchctl $*" >>"$L_LOG"\n' >"$tmp/lbin/launchctl"
  chmod +x "$tmp/lbin/launchctl"
  [ "$(HOME=$tmp/lhome FORGE_UNAME=Darwin PATH=$tmp/lbin:$PATH code "$forge" watchdog --install)" = 1 ] || fail "a missing plist fails: $(cat "$tmp/out")"
  : >"$tmp/lhome/Library/LaunchAgents/com.github.claude-forge.watchdog.plist"
  HOME=$tmp/lhome FORGE_UNAME=Darwin PATH=$tmp/lbin:$PATH "$forge" watchdog --install >/dev/null
  grep -q '^launchctl bootstrap gui/[0-9]* .*watchdog.plist$' "$L_LOG" || fail "bootstrap: $(cat "$L_LOG")"
  plutil_free=$root/launchd/com.github.claude-forge.watchdog.plist
  grep -q '<integer>300</integer>' "$plutil_free" || fail "the agent runs every 5 minutes"
  ok watchdog-launchd
fi

if want session-gate; then
  mkdir -p "$tmp/sbin"
  export CLAUDE_LOG=$tmp/claude.log CLAUDE_AGENTS=$tmp/agents.json
  echo '[]' >"$CLAUDE_AGENTS"
  cat >"$tmp/sbin/claude" <<'S'
#!/usr/bin/env bash
if [ "$1" = agents ]; then cat "$CLAUDE_AGENTS"; exit 0; fi
printf '%s\n' "$*" >>"$CLAUDE_LOG"
echo "backgrounded · $(printf %s "$*" | md5sum | cut -c1-8) · x"
S
  chmod +x "$tmp/sbin/claude"
  export PATH=$tmp/sbin:$PATH
  while read -r g a; do
    fresh
    machine "$g" "$a"
    : >"$CLAUDE_LOG"
    "$forge" discuss --auto crm/intake >"$tmp/out" 2>&1 || :
    ! grep -q 'waits for memory' "$tmp/out" || fail "$g GiB with $a GiB free must start one session: $(cat "$tmp/out")"
    [ -s "$CLAUDE_LOG" ] || fail "$g GiB with $a GiB free started nothing: $(cat "$tmp/out")"
  done <<'T'
8 2
16 3
32 5
93 5
T
  fresh
  machine 8 0
  : >"$CLAUDE_LOG"
  "$forge" discuss --auto crm/intake >"$tmp/out" 2>&1 || :
  grep -q 'waits for memory' "$tmp/out" || fail "with no memory free the session waits: $(cat "$tmp/out")"
  fresh
  machine 8 8
  echo '[{"id": "a", "name": "q quick one", "state": "working"}, {"id": "b", "name": "q quick two", "state": "working"}]' >"$CLAUDE_AGENTS"
  "$forge" discuss --auto crm/intake >"$tmp/out" 2>&1 || :
  grep -q 'waits for a free session' "$tmp/out" || fail "8 GiB holds 2 sessions by default: $(cat "$tmp/out")"
  ok session-gate
fi
finish
