#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/tests/fixtures/forge-browser
fb=$root/bin/forge-browser
[ -z "${1:-}" ] || { echo "forge-browser.test.sh: no case $1" >&2; exit 1; }
export LC_ALL=C
tmp=$(mktemp -d)
cleanup() {
  if [ -e "$tmp/state/pids" ]; then
    while read -r p; do kill -KILL -- "-$p" 2>/dev/null || true; done <"$tmp/state/pids"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME=$tmp/home
export PATH=$fx/bin:$PATH STUB_LOG=$tmp/log STUB_STATE=$tmp/state
export CHROME_PATH=$fx/chrome
export STUB_TARBALL=$tmp/jbc.tgz STUB_TARBALL_URL STUB_LOCK=$fx/pin/package-lock.json
STUB_TARBALL_URL=$(jq -r .url "$fx/pin/pin.json")
key=fixture-value-not-secret
keysha=$(printf %s "$key" | sha256sum | cut -d' ' -f1)
mkdir -p "$HOME/.config/forge" "$STUB_STATE"
printf '%s\n' "$key" >"$HOME/.config/forge/jev-api-key"
chmod 600 "$HOME/.config/forge/jev-api-key"

tar -czf "$STUB_TARBALL" -C "$fx/tarball" package
sha=$(sha256sum <"$STUB_TARBALL" | cut -d' ' -f1)
pin() {
  mkdir -p "$1"
  jq -r '.patches[]' "$fx/pin/pin.json" | while read -r p; do cp "$fx/pin/$p" "$1/"; done
  cp "$fx/pin/package-lock.json" "$1/"
  jq --arg s "$2" '.sha256 = $s' "$fx/pin/pin.json" >"$1/pin.json"
}
pin "$tmp/pin" "$sha"
pin "$tmp/pin-sha" "$(printf '%064d' 0)"
pin "$tmp/pin-patch" "$sha"
cp "$fx/bad-hub.patch" "$tmp/pin-patch/hub.patch"
export FORGE_BROWSER_PIN_DIR=$tmp/pin FORGE_BROWSER_PREFIX=$tmp/prefix STUB_BROWSER_LOCK=$tmp/.forge-browser.lock
prefix=$FORGE_BROWSER_PREFIX

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = agents ] || { echo "claude stub: unexpected arguments: $*" >&2; exit 2; }
mkdir -p "${STUB_LOG:?}"
echo "claude $*" >>"$STUB_LOG/calls"
cat "${STUB_AGENTS:?}"
EOF
chmod +x "$tmp/bin/claude"
export PATH=$tmp/bin:$PATH STUB_AGENTS=$tmp/agents.json CLAUDE_CODE_SESSION_ID=sess-a
agent() {
  jq -nc --arg id "$1" --arg name "$2" --arg state "$3" --arg kind "$4" --argjson pid "$5" \
    '{sessionId: $id, kind: $kind, pid: $pid} + (if $state == "-" then {} else {state: $state} end) + (if $name == "" then {} else {name: $name} end)'
}
agents() { if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -s .; fi >"$STUB_AGENTS"; }
agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)"

check() { diff -u "$fx/$1" - && echo "forge-browser $1: ok"; }
yn() { if "$@"; then echo yes; else echo no; fi; }
calls() { grep -c "^$1" "$STUB_LOG/calls" 2>/dev/null || true; }
dirs() {
  local d
  for d in "$STUB_LOG"/node.*; do
    [ -e "$d/role" ] || continue
    [ -z "${1:-}" ] || [ "$(cat "$d/role")" = "$1" ] || continue
    echo "$d"
  done
}
settle() {
  local i d done
  for i in $(seq 100); do
    done=1
    [ "$(calls systemd-run)" = 0 ] || [ -n "$(dirs owner)" ] || done=
    for d in $(dirs owner); do [ -e "$d/stdin" ] || done=; done
    [ -z "$done" ] || return 0
    sleep 0.1
  done
}
run() {
  local s=0
  rm -rf "$STUB_LOG"
  mkdir -p "$STUB_LOG"
  : >"$STUB_LOG/calls"
  timeout 60 "$fb" "$@" <"${IN:-/dev/null}" >"$tmp/out" 2>"$tmp/err" || s=$?
  settle
  echo "\$ forge-browser $*${LABEL:+ ($LABEL)}"
  if [ "$s" = 0 ]; then echo "exit 0"; else echo "exit non-zero"; fi
}
field() { sed -n "s/^$2=//p" "$1/env"; }
unit_alive() { [ -s "$STUB_STATE/forge-jbc.pid" ] && kill -0 -- "-$(cat "$STUB_STATE/forge-jbc.pid")" 2>/dev/null; }
after() {
  awk -v a="$1" -v b="$2" '!x && index($0, a) == 1 { x = NR; next } x && index($0, b) { f = 1 } END { print (f ? "yes" : "no") }' "$STUB_LOG/calls"
}
leak() {
  echo "key leaked: $(yn grep -rqsF "$key" "$tmp/out" "$tmp/err" "$STUB_LOG" "$STUB_STATE")"
}
node_report() {
  local who=$1 d=$2
  echo "$who argv: $(sed "s|^$prefix/|<prefix>/|" "$d/argv" | paste -sd' ')"
  echo "$who FORGE_JBC_PEER=$(field "$d" FORGE_JBC_PEER)"
}
unit_report() {
  local d r
  echo "systemd-run calls: $(calls systemd-run)"
  for d in "$STUB_LOG"/systemd-run.*; do
    [ -e "$d/argv" ] || continue
    echo "systemd-run --user: $(yn test -e "$d/user")"
    echo "systemd-run unit: $(cat "$d/unit")"
    echo "systemd-run caller env holds the key: $(yn grep -qF "$key" "$d/env")"
    echo "systemd-run under the start lock: $(cat "$d/lock")"
  done
  echo "owner processes: $(dirs owner | wc -l)"
  for d in $(dirs owner); do
    node_report owner "$d"
    echo "owner JBC_HEADLESS=$(field "$d" JBC_HEADLESS)"
    echo "owner JBC_CONFIRM_IRREVERSIBLE=$(field "$d" JBC_CONFIRM_IRREVERSIBLE)"
    echo "owner JBC_PROVIDER=$(field "$d" JBC_PROVIDER)"
    case $(field "$d" OPENROUTER_API_KEY_SHA256) in
      "$keysha") echo "owner OPENROUTER_API_KEY: the key file" ;;
      "<unset>") echo "owner OPENROUTER_API_KEY: <unset>" ;;
      *) echo "owner OPENROUTER_API_KEY: another value" ;;
    esac
    echo "owner stdin: $(cat "$d/stdin" 2>/dev/null || echo unknown)"
    field "$d" JBC_HOME >"$tmp/jbc-home"
  done
  echo "peer processes: $(dirs peer | wc -l)"
  for d in $(dirs peer); do
    node_report peer "$d"
    echo "peer tools/call: $(grep '^tools/call' "$d/requests" | sed 's|^tools/call ||' | paste -sd' ')"
    echo "peer still running: $(yn kill -0 "$(cat "$d/pid")" 2>/dev/null)"
    r=$(field "$d" JBC_HOME)
    echo "peer JBC_HOME same as owner: $(yn test -n "$r" -a "$r" != "<unset>" -a "$r" = "$(cat "$tmp/jbc-home" 2>/dev/null)")"
  done
  echo "peer started after systemd-run: $(after systemd-run 'node peer')"
  echo "devtools 127.0.0.1:9222 probed after systemd-run: $(after systemd-run '127.0.0.1:9222')"
  echo "devtools probes under the start lock: $(grep -lxF http://127.0.0.1:9222/json/version "$STUB_LOG"/curl.*/argv | while read -r a; do cat "${a%/argv}/lock"; done | sort -u | paste -sd' ')"
  echo "unit running: $(yn unit_alive)"
  echo "start lock free once start returns: $(yn flock -n "$STUB_BROWSER_LOCK" true)"
}

{
  run --help
  echo "stdout names start, --headed, stop, mcp: $(yn grep -q start "$tmp/out") $(yn grep -qF -- --headed "$tmp/out") $(yn grep -q stop "$tmp/out") $(yn grep -q mcp "$tmp/out")"
  echo "stdout names waiting for another owner and /clear: $(yn grep -qi wait "$tmp/out") $(yn grep -qF /clear "$tmp/out")"
  echo "stub calls: $(wc -l <"$STUB_LOG/calls")"
  leak
} | check help.txt

{
  run start
  echo "tarball fetched from the pin url: $(yn grep -qxF "curl $STUB_TARBALL_URL" "$STUB_LOG/calls")"
  echo "npm calls: $(calls npm)"
  for d in "$STUB_LOG"/npm.*; do
    [ -e "$d/argv" ] || continue
    echo "npm ci: $(yn grep -qx ci "$d/argv")"
    echo "npm --ignore-scripts: $(yn grep -qx -- --ignore-scripts "$d/argv")"
    echo "npm lockfile: $(cat "$d/lock") as the pin's"
    echo "npm ran on patched sources: $(cat "$d/patched")"
  done
  echo "npm ran before systemd-run: $(after "npm" systemd-run)"
  echo "prefix server.mjs: $(yn test -f "$prefix/server.mjs")"
  echo "prefix local-browser.mjs patched: $(yn grep -qF -- "'--remote-debugging-port=9222'" "$prefix/lib/local-browser.mjs")"
  echo "prefix hub.mjs patched: $(yn grep -qF "process.env.FORGE_JBC_PEER === '1'" "$prefix/lib/hub.mjs")"
  echo "prefix server.mjs patched: $(yn grep -qF "process.env.FORGE_JBC_PEER === '1'" "$prefix/server.mjs")"
  echo "prefix server.mjs peer wording names forge-browser start, --headed, stop: $(yn grep -qF 'forge-browser start' "$prefix/server.mjs") $(yn grep -qF 'forge-browser start --headed' "$prefix/server.mjs") $(yn grep -qF 'forge-browser stop' "$prefix/server.mjs")"
  echo "prefix server.mjs owner wording kept: $(yn grep -qF 'The first tool call opens it.' "$prefix/server.mjs")"
  echo "prefix hub.mjs reconnect error names forge-browser start, --headed: $(yn grep -qF 'forge-browser start' "$prefix/lib/hub.mjs") $(yn grep -qF 'forge-browser start --headed' "$prefix/lib/hub.mjs")"
  echo "prefix hub.mjs owner reconnect error kept: $(yn grep -qF 'Reconnecting to the browser bridge; retry in a moment.' "$prefix/lib/hub.mjs")"
  echo "prefix local-browser.mjs ozone wayland when headed under Wayland: $(yn grep -qF -- "...(!b.headless && process.env.WAYLAND_DISPLAY ? ['--ozone-platform=wayland'] : [])" "$prefix/lib/local-browser.mjs")"
  echo "prefix node_modules: $(yn test -e "$prefix/node_modules/playwright-core/package.json")"
  echo "prefix .orig or .rej files: $(find "$prefix" \( -name '*.orig' -o -name '*.rej' \) 2>/dev/null | wc -l)"
  unit_report
  leak

  first=$(cat "$STUB_STATE/forge-jbc.pid" 2>/dev/null || echo 999999999)
  run start --headed
  echo "previous unit running: $(yn kill -0 -- "-$first" 2>/dev/null)"
  unit_report
  leak

  printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/list"}' >"$tmp/in"
  IN=$tmp/in run mcp
  cat "$tmp/out"
  echo "node processes: $(dirs | wc -l)"
  for d in $(dirs); do
    node_report "mcp node" "$d"
    echo "mcp node requests: $(paste -sd' ' "$d/requests")"
    r=$(field "$d" JBC_HOME)
    echo "mcp node JBC_HOME same as owner: $(yn test -n "$r" -a "$r" != "<unset>" -a "$r" = "$(cat "$tmp/jbc-home" 2>/dev/null)")"
  done
  echo "systemd-run calls: $(calls systemd-run)"
  echo "unit running: $(yn unit_alive)"
  leak

  run stop
  echo "systemctl --user stop forge-jbc: $(yn grep -qx 'systemctl --user stop forge-jbc' "$STUB_LOG/calls")"
  echo "systemd-run calls: $(calls systemd-run)"
  echo "node processes: $(dirs | wc -l)"
  echo "unit running: $(yn unit_alive)"
  leak
} | check start.txt

failed() {
  echo "stderr names $1: $(yn grep -Eqi -- "$2" "$tmp/err")"
  echo "prefix exists: $(yn test -e "$FORGE_BROWSER_PREFIX")"
  [ "$1" = CHROME_PATH ] || echo "npm calls: $(calls npm)"
  echo "systemd-run calls: $(calls systemd-run)"
  echo "node processes: $(dirs | wc -l)"
  echo "unit running: $(yn unit_alive)"
  leak
}

{
  export FORGE_BROWSER_PIN_DIR=$tmp/pin-sha FORGE_BROWSER_PREFIX=$tmp/prefix-sha
  LABEL="pin sha256 does not match the tarball" run start
  failed sha256 'sha-?256'

  export FORGE_BROWSER_PIN_DIR=$tmp/pin-patch FORGE_BROWSER_PREFIX=$tmp/prefix-patch
  LABEL="hub.patch does not apply" run start
  failed hub.patch 'hub\.patch'

  export FORGE_BROWSER_PIN_DIR=$tmp/pin FORGE_BROWSER_PREFIX=$prefix
  CHROME_PATH=$tmp/no-chrome LABEL="CHROME_PATH missing" run start
  failed CHROME_PATH "$tmp/no-chrome"
} | sed "s|$tmp|<tmp>|g" | check install.txt

mkdir -p "$tmp/xdg/forge" "$tmp/onlychromium"
ln -sf "$(command -v env)" "$tmp/onlychromium/env"
printf '%s\n' "$key" >"$tmp/xdg/forge/jev-api-key"
XDG_CONFIG_HOME=$tmp/xdg bash -c '. /dev/stdin <<<"$(sed -n "/^key_file=/p" "$1")"; [ "$key_file" = "$2/forge/jev-api-key" ]' _ "$fb" "$tmp/xdg" || { echo "forge-browser: key file must follow XDG_CONFIG_HOME" >&2; exit 1; }
printf '#!/bin/sh\n' >"$tmp/onlychromium/chromium" && chmod +x "$tmp/onlychromium/chromium"
got=$(env -u CHROME_PATH PATH="$tmp/onlychromium:$PATH" bash -c 'eval "$(sed -n "/^find_chrome() {/,/^}/p" "$1")"; uname() { echo Linux; }; PATH=$2:$PATH; hash -r; find_chrome' _ "$fb" "$tmp/onlychromium")
case $got in *chromium|*google-chrome*) ;; *) echo "forge-browser: linux detection found '$got'" >&2; exit 1 ;; esac
got=$(env -u CHROME_PATH bash -c 'eval "$(sed -n "/^find_chrome() {/,/^}/p" "$1")"; uname() { echo Darwin; }; find_chrome' _ "$fb")
[ "$got" = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] || { echo "forge-browser: macOS detection found '$got'" >&2; exit 1; }
got=$(CHROME_PATH=/x/chrome bash -c 'eval "$(sed -n "/^find_chrome() {/,/^}/p" "$1")"; find_chrome' _ "$fb")
[ "$got" = /x/chrome ] || { echo "forge-browser: CHROME_PATH must win, found '$got'" >&2; exit 1; }
echo "forge-browser detect: ok"

said() {
  cat "$@" 2>/dev/null | sed -n 's/^forge-browser: browser in use by \(.*\); waiting for it to stop$/\1/p' | head -1 | grep . || echo none
}
proceeds() {
  echo "wait message names: $(said "$tmp/out" "$tmp/err")"
  echo "systemd-run calls: $(calls systemd-run)"
  echo "unit running: $(yn unit_alive)"
}
gives_up() {
  local t=$SECONDS e
  FORGE_BROWSER_OWNER_WAIT=2 run start
  e=$((SECONDS - t))
  echo "wait message names: $(said "$tmp/out" "$tmp/err")"
  echo "gave up after waiting, within the bound: $(yn test "$e" -ge 1)"
  echo "stderr names $1 outside the wait message: $(yn sh -c 'grep -vF "waiting for it to stop" "$1" | grep -qF "$2"' - "$tmp/err" "$1")"
  echo "systemd-run calls: $(calls systemd-run)"
  echo "unit running: $(yn unit_alive)"
}
refused() {
  echo "stderr names CLAUDE_CODE_SESSION_ID: $(yn grep -qF CLAUDE_CODE_SESSION_ID "$tmp/err")"
  echo "wait message names: $(said "$tmp/out" "$tmp/err")"
  echo "systemd-run calls: $(calls systemd-run)"
  echo "unit running: $(yn unit_alive)"
}

{
  export FORGE_BROWSER_OWNER_WAIT=20
  agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a, no owner" run start
  proceeds
  first=$(cat "$STUB_STATE/forge-jbc.pid" 2>/dev/null || echo 999999999)

  echo "\$ forge-browser start (session b in the background, a owns and is working)"
  rm -rf "$tmp/blog"
  CLAUDE_CODE_SESSION_ID=sess-b FORGE_BROWSER_OWNER_WAIT=60 STUB_LOG=$tmp/blog \
    timeout 90 "$fb" start </dev/null >"$tmp/bout" 2>"$tmp/berr" &
  bpid=$!
  for _ in $(seq 100); do
    [ "$(said "$tmp/bout" "$tmp/berr")" = none ] || break
    kill -0 "$bpid" 2>/dev/null || break
    sleep 0.1
  done
  echo "session b wait message names: $(said "$tmp/bout" "$tmp/berr")"
  echo "session b still waiting: $(yn kill -0 "$bpid" 2>/dev/null)"
  echo "session b systemd-run calls: $(grep -c ^systemd-run "$tmp/blog/calls" 2>/dev/null || true)"
  echo "session a unit still running: $(yn kill -0 -- "-$first" 2>/dev/null)"

  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a restarts headed while b waits" run start --headed
  proceeds
  echo "owner JBC_HEADLESS=$(for d in $(dirs owner); do field "$d" JBC_HEADLESS; done)"
  echo "session b still waiting: $(yn kill -0 "$bpid" 2>/dev/null)"

  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a stops" run stop
  echo "unit stopped by a: $(yn grep -qx 'systemctl --user stop forge-jbc' "$STUB_LOG/calls")"
  for _ in $(seq 300); do kill -0 "$bpid" 2>/dev/null || break; sleep 0.1; done
  bs=0
  wait "$bpid" || bs=$?
  echo "session b exit once a stopped: $(if [ "$bs" = 0 ]; then echo 0; else echo non-zero; fi)"
  echo "session b systemd-run calls: $(grep -c ^systemd-run "$tmp/blog/calls" 2>/dev/null || true)"
  echo "unit running: $(yn unit_alive)"

  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a while b owns and is working" gives_up 'Discuss mockup'

  CLAUDE_CODE_SESSION_ID= LABEL="empty session id while b owns and is working" run start
  refused

  agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)" "$(agent sess-b 'Discuss mockup' done bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a, owner b done" run start
  proceeds

  agents "$(agent sess-a 'Verify 99-browser-owner' blocked bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b while a owns, idle awaiting input in the background" gives_up 'Verify 99-browser-owner'

  agents "$(agent sess-a 'Verify 99-browser-owner' - interactive 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b while a owns, interactive with no state" gives_up 'Verify 99-browser-owner'

  agents "$(agent sess-a 'Verify 99-browser-owner' failed bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b, owner a failed" run start
  proceeds

  agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)" "$(agent sess-b 'Discuss mockup' stopped bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a, owner b stopped" run start
  proceeds

  agents "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b, owner a absent from claude agents" run start
  proceeds

  systemctl --user stop forge-jbc 2>/dev/null || true
  agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a, owner b's unit inactive" run start
  proceeds

  agents "$(agent sess-a 'Verify 99-browser-owner' idle interactive 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b while a owns, idle and interactive with a pid" gives_up 'Verify 99-browser-owner'

  CLAUDE_CODE_SESSION_ID= LABEL="empty session id" run stop
  echo "unit running: $(yn unit_alive)"
  CLAUDE_CODE_SESSION_ID= LABEL="empty session id, no owner" run start
  refused
  agents "$(agent sess-a 'Verify 99-browser-owner' working bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b, unit stopped" run start
  proceeds

  agents "$(agent sess-a '' working bg 4101)" "$(agent sess-b 'Discuss mockup' working bg 4102)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a while b owns and is working" gives_up 'Discuss mockup'
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a, not the owner" run stop
  echo "unit running: $(yn unit_alive)"
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a without a name, unit stopped" run start
  proceeds
  CLAUDE_CODE_SESSION_ID=sess-b LABEL="session b while unnamed a owns and is working" gives_up sess-a
  CLAUDE_CODE_SESSION_ID=sess-a LABEL="session a" run stop
  echo "unit running: $(yn unit_alive)"
} | check owner.txt
