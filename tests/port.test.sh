#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/tests/fixtures/port
export LC_ALL=C GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=forge GIT_AUTHOR_EMAIL=forge@example.com GIT_COMMITTER_NAME=forge GIT_COMMITTER_EMAIL=forge@example.com
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mksrc() {
  mkdir -p "$1"
  cp -a "$root"/{port,global,templates,schemas,skills,agents,hooks,bin,systemd} "${@:2}" "$1"/
  git init -q -b main "$1"
  git -C "$1" add -A
  git -C "$1" commit -q -m src
}

fail() { echo "port: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "port $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() {
  [ -z "$only" ] && return
  local c
  for c; do [ "$only" != "$c" ] || return 0; done
  return 1
}

export HOME=$tmp/home CLAUDE_LOG=$tmp/claude.log SYSTEMCTL_LOG=$tmp/systemctl.log SYSTEMCTL_ENABLED=$tmp/timer-enabled SYSTEMCTL_ACTIVE=$tmp/timer-active CLAUDE_PLUGIN_PINS=$root/global/plugins.json
export FORGE_UNAME=Linux FORGE_RUN_ROOT=$tmp/run
mkdir -p "$HOME" "$tmp/bin" "$FORGE_RUN_ROOT/systemd/system"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" != agents ] || { printf '%s\n' "${CLAUDE_AGENTS_JSON:-[]}"; exit 0; }
jq -cn --arg cwd "$PWD" '[$cwd] + $ARGS.positional' --args -- "$@" >>"$CLAUDE_LOG"
if [ "$1" = plugin ]; then
  reply() { jq -cn --arg c "plugin $1" --arg o "$2" --arg m "$3" '{command: $c, outcome: $o, message: $m}'; }
  if [ "$2 $3" = "marketplace update" ]; then
    echo "Updating marketplace $4..."
    if ! jq -e --arg m "$4" '.extraKnownMarketplaces[$m].source.ref | strings' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
      echo "stub: marketplace update $4 ran before ~/.claude/settings.json carried its ref" >&2
      reply "marketplace update" failed "Marketplace $4 has no pinned ref"
      exit 1
    fi
    if [ "$4" = "${CLAUDE_MARKET_FAIL:-}" ]; then
      reply "marketplace update" failed "Failed to refresh marketplace $4: git fetch failed"
      exit 1
    fi
    reply "marketplace update" ok "Successfully updated marketplace: $4"
    exit 0
  fi
  case $2 in install|update) ;; *) echo "stub: unexpected claude $*" >&2; exit 1 ;; esac
  id=$3 mode=
  [ "${CLAUDE_PLUGIN_BAD:-}" = "" ] || [ "${CLAUDE_PLUGIN_BAD% *}" != "$id" ] || mode=${CLAUDE_PLUGIN_BAD#* }
  ip=$HOME/.claude/plugins/installed_plugins.json
  echo "Running plugin $2 for $id..."
  if [ "$2" = install ] && jq -e --arg id "$id" '.plugins[$id][0]' "$ip" >/dev/null 2>&1; then
    reply install ok "Plugin '$id' is already installed"
    exit 0
  fi
  if [ "$mode" != stale ]; then
    mkdir -p "${ip%/*}"
    [ -f "$ip" ] || echo '{"version":2,"plugins":{}}' >"$ip"
    jq --arg id "$id" --arg h "$HOME" --slurpfile pins "$CLAUDE_PLUGIN_PINS" '
      $pins[0][$id] as $p
      | .plugins[$id] = [(.plugins[$id][0] // {scope: "user"})
          + {version: $p.version, gitCommitSha: $p.gitCommitSha,
             installPath: "\($h)/.claude/plugins/cache/\($p.marketplace)/\($id | split("@")[0])/\($p.version)"}]
          + (.plugins[$id][1:] // [])' "$ip" >"$ip.stub" && mv "$ip.stub" "$ip"
  fi
  case $mode in
    failed) reply "$2" failed "Failed to $2 plugin '$id'" ;;
    shown) jq -cn --arg c "plugin $2" --arg id "$id" '{command: $c, outcome: "ok", message: "Run this command to continue", shownCommand: {command: "claude plugin \($c | split(" ")[1]) \($id) -y"}}' ;;
    silent) echo "Done." ;;
    *) reply "$2" ok "Plugin $id is at its marketplace version" ;;
  esac
  exit 0
fi
[ "$2 $3" = "add-json ${CLAUDE_FAIL_ADD:-}" ] && [ ! -e "$CLAUDE_LOG.failed" ] && touch "$CLAUDE_LOG.failed" && exit 1
if [ "$2" = add-json ]; then
  scope=${*: -1}
  if jq -e --arg cwd "$PWD" --arg n "$3" --arg s "$scope" \
      '(if $s == "local" then .projects[$cwd].mcpServers else .mcpServers end // {}) | has($n)' "$HOME/.claude.json" >/dev/null 2>&1 &&
    ! jq -se --arg cwd "$PWD" --arg n "$3" --arg s "$scope" \
      'any(.[]; .[0] == $cwd and .[2] == "remove" and .[3] == $n and .[5] == $s)' "$CLAUDE_LOG" >/dev/null; then
    echo "MCP server $3 already exists in $scope config" >&2
    exit 1
  fi
fi
exit 0
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
jq -cn '$ARGS.positional' --args -- "$@" >>"$SYSTEMCTL_LOG"
case $2 in
  daemon-reload) [ -z "${SYSTEMCTL_FAIL_RELOAD:-}" ] || { echo "Failed to connect to bus" >&2; exit 1; } ;;
  is-enabled) [ -e "$SYSTEMCTL_ENABLED" ] ;;
  is-active) [ -e "$SYSTEMCTL_ACTIVE" ] ;;
  disable)
    rm -f "$SYSTEMCTL_ENABLED"
    [ "$3" != --now ] || rm -f "$SYSTEMCTL_ACTIVE" ;;
  enable)
    [ -z "${SYSTEMCTL_FAIL_ENABLE:-}" ] || { echo "Failed to enable unit: Access denied" >&2; exit 1; }
    touch "$SYSTEMCTL_ENABLED"
    [ -z "${SYSTEMCTL_FAIL_START:-}" ] || { echo "Job for forge-watchdog.timer failed" >&2; exit 1; }
    touch "$SYSTEMCTL_ACTIVE" ;;
esac
EOF
chmod +x "$tmp/bin/claude" "$tmp/bin/systemctl"
export PATH=$tmp/bin:$PATH
src=$tmp/src
mksrc "$src" "$root/output-styles"
jq '.playwright.projects = ["~/Projects/ACME", "~/Projects/ACME/acme-hub", "~/Projects/forge"]' "$root/global/mcp-projects.json" >"$src/global/mcp-projects.json"
git -C "$src" commit -q -am "test projects"
port=$src/port
cj=$tmp/claude.json
jq --arg h "$HOME" '.projects |= with_entries(.key |= if startswith("~/") then $h + .[1:] else . end)' "$fx/claude.json" >"$cj"
mkprojects() { mkdir -p "$HOME/Projects/ACME/acme-hub" "$HOME/Projects/forge"; }
mkprojects
calls() {
  jq -cS --arg h "$HOME" --arg s "$src" '
    .[0] |= (if . == $s then "." elif startswith($h + "/") then "~" + .[($h | length):] else . end)
    | if .[2] == "add-json" then .[4] |= fromjson else . end' "$CLAUDE_LOG"
}

states() {
  awk -v n="$1" -F'[][[:space:]:,()"=]+' '
    { a = 0; s = ""
      for (i = 1; i <= NF; i++) {
        if ($i == n) a = 1
        if ($i == "absent" || $i == "drift" || $i == "ok" || $i == "extra") s = s $i " "
      }
      if (a && s != "") print s }' "$2"
}
expect() {
  local got
  got=$(states "$1" "$3")
  [ "$got" = "$2 " ] || fail "$4: $1 must have one '$2' line, got '${got}': $(cat "$3")"
}
dry() {
  rm -f "$CLAUDE_LOG" "$SYSTEMCTL_LOG"
  "$port" ${dry_args:-} >"$tmp/out" 2>&1 || fail "dry run exited non-zero: $(cat "$tmp/out")"
  [ ! -e "$CLAUDE_LOG" ] || fail "dry run must not call claude: $(cat "$CLAUDE_LOG")"
  [ ! -e "$SYSTEMCTL_LOG" ] || fail "dry run must not call systemctl: $(cat "$SYSTEMCTL_LOG")"
}

if want mcp.json; then
[ -f "$root/global/mcp.json" ] || fail "global/mcp.json is missing"
jq -e -S . "$root/global/mcp.json" >"$tmp/mcp" || fail "global/mcp.json must be JSON"
jq -S . >"$tmp/want" <<'EOF'
{
  "context7": {"type":"http","url":"https://mcp.context7.com/mcp"}
}
EOF
diff -u "$tmp/want" "$tmp/mcp" || fail "global/mcp.json must hold only the context7 user-scope entry"
jq -e '.jbc == {"type":"stdio","command":"forge-browser","args":["mcp"]}' "$root/global/mcp-browser.json" >/dev/null || fail "global/mcp-browser.json must hold the opt-in jbc entry"
ok mcp.json
fi

if want mcp-projects.json; then
[ -f "$root/global/mcp-projects.json" ] || fail "global/mcp-projects.json is missing"
jq -e -S . "$root/global/mcp-projects.json" >"$tmp/mcp-projects" || fail "global/mcp-projects.json must be JSON"
jq -S . >"$tmp/want" <<'EOF'
{
  "playwright": {
    "server": {"type":"stdio","command":"npx","args":["-y","@playwright/mcp@0.0.83","--cdp-endpoint","http://127.0.0.1:9222"]},
    "projects": []
  }
}
EOF
diff -u "$tmp/want" "$tmp/mcp-projects" || fail "global/mcp-projects.json must hold playwright pinned at 0.0.83 for no project by default"
ok mcp-projects.json
fi

if want "marketplace refs"; then
jq -S .extraKnownMarketplaces "$root/global/plugin-settings.json" >"$tmp/markets" || fail "global/plugin-settings.json must be JSON"
jq -S . >"$tmp/want" <<'EOF'
{
  "openai-codex": {"source":{"source":"github","repo":"openai/codex-plugin-cc","ref":"v1.0.6"}},
  "impeccable": {"source":{"source":"github","repo":"pbakaus/impeccable","ref":"skill-v4.5.2"}}
}
EOF
diff -u "$tmp/want" "$tmp/markets" || fail "global/plugin-settings.json must pin each extraKnownMarketplaces source with its ref"
ok "marketplace refs"
fi

if want plugins.json; then
[ -f "$root/global/plugins.json" ] || fail "global/plugins.json is missing"
jq -e -S . "$root/global/plugins.json" >"$tmp/plugins" || fail "global/plugins.json must be JSON"
jq -S . >"$tmp/want" <<'EOF'
{
  "codex@openai-codex": {"marketplace":"openai-codex","version":"1.0.6","gitCommitSha":"db52e28f4d9ded852ab3942cea316258ae4ef346"},
  "impeccable@impeccable": {"marketplace":"impeccable","version":"4.5.2","gitCommitSha":"d631a8827f99414d2b6daba4ef08b7f8701751d7"}
}
EOF
diff -u "$tmp/want" "$tmp/plugins" || fail "global/plugins.json must pin codex 1.0.6 and impeccable 4.5.2 at their tag commits"
ok plugins.json
fi

if want diff; then
cp "$cj" "$HOME/.claude.json"
dry
expect context7 absent "$tmp/out" "live fixture"
! grep -q 'extra' "$tmp/out" || fail "live fixture: servers forge does not own are never reported: $(cat "$tmp/out")"
[ -z "$(states project-only "$tmp/out")" ] || fail "project-scope servers are not user-scope: $(cat "$tmp/out")"
! grep -q 'env-value-' "$tmp/out" || fail "dry run must not print env values: $(grep 'env-value-' "$tmp/out")"
grep -qE '^[^ ]{11} forge/jbc/pin\.json$' "$tmp/out" || fail "dry run must still print rsync's itemized changes: $(cat "$tmp/out")"
! grep -qE '^[^ ]{11} mcp\.json$' "$tmp/out" || fail "global/mcp.json must be left out of the rsync copy: $(cat "$tmp/out")"
! grep -qE '^[^ ]{11} mcp-projects\.json$' "$tmp/out" || fail "global/mcp-projects.json must be left out of the rsync copy: $(cat "$tmp/out")"
for f in plugins plugin-settings mcp-browser; do
  ! grep -qE "^[^ ]{11} $f\.json\$" "$tmp/out" || fail "global/$f.json must be left out of the rsync copy: $(cat "$tmp/out")"
done
ok diff
fi

if want "project states"; then
cp "$cj" "$HOME/.claude.json"
dry
for want in 'mcp playwright ~/Projects/ACME: drift' 'mcp playwright ~/Projects/ACME/acme-hub: ok' 'mcp playwright ~/Projects/forge: absent'; do
  [ "$(grep -cxF "$want" "$tmp/out")" = 1 ] || fail "dry run must print '$want' once: $(cat "$tmp/out")"
done
[ "$(grep -c '^mcp playwright ~' "$tmp/out")" = 3 ] || fail "dry run must print one playwright line per project: $(cat "$tmp/out")"
[ "$(grep -n -m1 '^mcp playwright ~' "$tmp/out" | cut -d: -f1)" -lt "$(grep -n -m1 '^mcp [^ ]*: ' "$tmp/out" | cut -d: -f1)" ] \
  || fail "the project-scope lines must come before the user-scope lines: $(cat "$tmp/out")"
ok "project states"
fi

if want states; then
jq '.mcpServers.context7 = {"type":"http","url":"https://mcp.context7.com/mcp","env":{"C7":"env-value-c7"}}' \
  "$cj" >"$HOME/.claude.json"
dry
expect context7 ok "$tmp/out" "context7 differing only in env"
jq '.mcpServers.context7 = {"type":"sse","url":"https://mcp.context7.com/mcp"}' "$cj" >"$HOME/.claude.json"
dry
expect context7 drift "$tmp/out" "context7 with another type"
jq '.mcpServers.context7 = {"type":"http","url":"https://mcp.context7.com/sse"}' "$cj" >"$HOME/.claude.json"
dry
expect context7 drift "$tmp/out" "context7 with another url"
ok states
fi

ip=$HOME/.claude/plugins/installed_plugins.json
put_plugins() {
  mkdir -p "${ip%/*}"
  jq --arg h "$HOME" '.plugins[][].installPath |= if startswith("~/") then $h + .[1:] else . end' "$fx/installed_plugins.json" | jq "${1:-.}" >"$ip"
}
plugin_lines() {
  dry_args=--plugins
  dry
  dry_args=
  if [ -e "$tmp/ip-before" ]; then
    cmp -s "$tmp/ip-before" "$ip" || fail "$3: dry run must not write installed_plugins.json"
  else
    [ ! -e "$ip" ] || fail "$3: dry run must not create installed_plugins.json"
  fi
  for want in "plugin codex@openai-codex: $1" "plugin impeccable@impeccable: $2"; do
    [ "$(grep -cxF "$want" "$tmp/out")" = 1 ] || fail "$3: dry run must print '$want' once: $(cat "$tmp/out")"
  done
  [ "$(grep -c '^plugin ' "$tmp/out")" = 2 ] || fail "$3: dry run must print one plugin line per pinned plugin: $(cat "$tmp/out")"
}
snap() { rm -f "$tmp/ip-before"; [ ! -e "$ip" ] || cp "$ip" "$tmp/ip-before"; }
pin() {
  jq -r --arg id "$1" '.[$id] | "(.plugins[\"\($id)\"][0] |= (.version = \"\(.version)\" | .gitCommitSha = \"\(.gitCommitSha)\"))"' "$root/global/plugins.json"
}
if want "plugin states"; then
cp "$cj" "$HOME/.claude.json"
put_plugins
snap
plugin_lines drift drift "fixture at 1.0.4/4.5.0/0.1.3"
put_plugins "$(pin codex@openai-codex)"
snap
plugin_lines ok drift "codex record at its pin"
put_plugins "$(pin codex@openai-codex) | .plugins[\"codex@openai-codex\"][0].gitCommitSha = \"807e03ac9d5aa23bc395fdec8c3767500a86b3cf\""
snap
plugin_lines drift drift "codex at the pinned version with another sha"
put_plugins "$(pin codex@openai-codex) | .plugins[\"codex@openai-codex\"][0].version = \"1.0.4\""
snap
plugin_lines drift drift "codex at the pinned sha with another version"
put_plugins "del(.plugins[\"impeccable@impeccable\"])"
snap
plugin_lines drift absent "impeccable record removed"
rm -f "$ip"
snap
plugin_lines absent absent "installed_plugins.json missing"
put_plugins
"$port" --only skills/forge-phase >"$tmp/out" 2>&1 || fail "--only dry run exited non-zero: $(cat "$tmp/out")"
! grep -q '^plugin ' "$tmp/out" || fail "--only must skip the plugin step: $(cat "$tmp/out")"
rm -rf "$HOME/.claude/plugins"
ok "plugin states"
fi

at_pins() {
  jq -e --slurpfile p "$root/global/plugins.json" '. as $i | $p[0] | all(to_entries[]; .key as $id | .value as $v
    | ($i.plugins[$id][0] // {}) | .version == $v.version and .gitCommitSha == $v.gitCommitSha)' "$ip" >/dev/null 2>&1 \
    || fail "$1: every pinned plugin record must end at its pinned version and gitCommitSha: $(cat "$ip" 2>&1) $(cat "$tmp/out")"
}
apply() {
  rm -f "$CLAUDE_LOG"
  put_plugins
  cp "$HOME/.claude.json" "$tmp/claude-before"
  "$port" --apply --plugins >"$tmp/out" 2>&1 || fail "--apply exited non-zero: $(cat "$tmp/out")"
  cmp -s "$tmp/claude-before" "$HOME/.claude.json" || fail "$2: --apply must never write ~/.claude.json itself"
  touch "$CLAUDE_LOG"
  calls >"$tmp/calls" || fail "add-json must get the entry as one JSON argument: $(cat "$CLAUDE_LOG")"
  jq -cS . "$fx/$1" >"$tmp/want-calls"
  diff -u "$tmp/want-calls" "$tmp/calls" || fail "$2: --apply must issue exactly $1's claude calls in order"
  at_pins "$2"
}

if want_any copy apply; then
cp "$cj" "$HOME/.claude.json"
apply apply.log "live fixture"
[ -f "$HOME/.claude/forge/jbc/pin.json" ] || fail "--apply must still copy global/ to ~/.claude/"
[ ! -e "$HOME/.claude/CLAUDE.md" ] || fail "--apply must never create ~/.claude/CLAUDE.md"
[ ! -e "$HOME/.claude/mcp.json" ] || fail "mcp.json must not land in ~/.claude/"
[ ! -e "$HOME/.claude/mcp-projects.json" ] || fail "mcp-projects.json must not land in ~/.claude/"
[ ! -e "$HOME/.claude/plugins.json" ] || fail "plugins.json must not land in ~/.claude/"
ok copy
ok apply
fi

if want "apply keeps unowned servers"; then
jq '.mcpServers["user-own"] = {"type":"stdio","command":"user-own","args":[]}' "$cj" >"$HOME/.claude.json"
dry
[ -z "$(states user-own "$tmp/out")" ] || fail "servers forge never owned must be left out of the diff: $(cat "$tmp/out")"
apply apply.log "live fixture plus a server forge never owned"
ok "apply keeps unowned servers"
fi



plugin_calls() {
  touch "$CLAUDE_LOG"
  calls | jq -c 'select(.[1] == "plugin")' >"$tmp/plugin-calls"
  ! jq -e 'select(any(.[]; . == "-y" or . == "--yes"))' "$tmp/plugin-calls" >/dev/null || fail "$1: no claude plugin call may pass -y: $(cat "$tmp/plugin-calls")"
  ! jq -e 'select(.[2] == "marketplace" and .[3] == "remove")' "$tmp/plugin-calls" >/dev/null || fail "$1: port must never run claude plugin marketplace remove: $(cat "$tmp/plugin-calls")"
}
apply_plugins() {
  cp "$cj" "$HOME/.claude.json"
  rm -f "$CLAUDE_LOG"
  s=0
  "$port" --apply --plugins >"$tmp/out" 2>&1 || s=$?
  plugin_calls "$1"
}
if want "plugin apply"; then
cat >"$tmp/want-mixed" <<'EOF'
[".","plugin","marketplace","update","impeccable","--json"]
[".","plugin","install","impeccable@impeccable","--scope","user","--json"]
EOF
put_plugins "$(pin codex@openai-codex) | del(.plugins[\"impeccable@impeccable\"])"
apply_plugins "codex ok, impeccable absent"
[ "$s" = 0 ] || fail "--apply over codex ok and impeccable absent must exit 0, got $s: $(cat "$tmp/out")"
diff -u "$tmp/want-mixed" "$tmp/plugin-calls" || fail "--apply must skip an ok plugin, refresh then install an absent one and refresh then update a drifted one, in plugins.json order"
at_pins "codex ok, impeccable absent"
jq -e '.plugins["impeccable@impeccable"] | length == 1 and .[0].scope == "user"' "$ip" >/dev/null || fail "the installed impeccable record must be the one user-scope record: $(cat "$ip")"
cat >"$tmp/want-absent" <<'EOF'
[".","plugin","marketplace","update","openai-codex","--json"]
[".","plugin","install","codex@openai-codex","--scope","user","--json"]
[".","plugin","marketplace","update","impeccable","--json"]
[".","plugin","install","impeccable@impeccable","--scope","user","--json"]
EOF
rm -rf "$HOME/.claude/plugins"
apply_plugins "installed_plugins.json missing"
[ "$s" = 0 ] || fail "--apply with no installed_plugins.json must exit 0, got $s: $(cat "$tmp/out")"
diff -u "$tmp/want-absent" "$tmp/plugin-calls" || fail "--apply with no installed_plugins.json must refresh then install each pinned plugin"
at_pins "installed_plugins.json missing"
apply_plugins "every plugin at its pin"
[ "$s" = 0 ] || fail "--apply with every plugin at its pin must exit 0, got $s: $(cat "$tmp/out")"
[ ! -s "$tmp/plugin-calls" ] || fail "--apply with every plugin at its pin must make no claude plugin call: $(cat "$tmp/plugin-calls")"
ok "plugin apply"
fi

if want "plugin apply failures"; then
for bad in market "failed" shown silent stale; do
  put_plugins
  rm -f "$HOME/.local/state/forge/port.json" "$HOME/.local/state/forge/port.manifest"
  if [ "$bad" = market ]; then
    CLAUDE_MARKET_FAIL=impeccable apply_plugins "failed impeccable refresh"
    what="a failed marketplace refresh for impeccable"
  else
    CLAUDE_PLUGIN_BAD="impeccable@impeccable $bad" apply_plugins "impeccable update $bad"
    case $bad in
      failed) what="an update whose last line has outcome failed" ;;
      shown) what="an update whose last line carries a shownCommand" ;;
      silent) what="an update with no JSON last line" ;;
      stale) what="an update that reports ok but leaves the record off-pin" ;;
    esac
  fi
  [ "$s" = 1 ] || fail "$what must make --apply exit 1, got $s: $(cat "$tmp/out")"
  grep -q '^port: error: .*impeccable@impeccable' "$tmp/out" || fail "$what must print a 'port: error: ...' line naming impeccable@impeccable: $(cat "$tmp/out")"
  grep -qxF '[".","plugin","marketplace","update","impeccable","--json"]' "$tmp/plugin-calls" || fail "$what: --apply must have refreshed the impeccable marketplace: $(cat "$tmp/plugin-calls")"
  case $bad in
    market) why="Failed to refresh marketplace impeccable: git fetch failed" ;;
    failed) why="Failed to update plugin 'impeccable@impeccable'" ;;
    shown) why="Run this command to continue" ;;
    *) why= ;;
  esac
  [ -z "$why" ] || grep -q "^port: error: .*impeccable@impeccable.*$why" "$tmp/out" || fail "$what: the port: error line must carry claude's message '$why': $(cat "$tmp/out")"
  [ -f "$HOME/.local/state/forge/port.json" ] && [ -f "$HOME/.local/state/forge/port.manifest" ] || fail "$what: --apply must still write port.json and port.manifest: $(cat "$tmp/out")"
  if [ "$bad" = stale ]; then
    jq -e '.plugins["impeccable@impeccable"][0].version == "4.5.0"' "$ip" >/dev/null || fail "the stale stub must leave impeccable at 4.5.0: $(cat "$ip")"
  fi
done
ok "plugin apply failures"
fi


if want "missing project directory skipped"; then
cp "$cj" "$HOME/.claude.json"
rm -rf "$HOME/Projects/forge"
rm -f "$CLAUDE_LOG"
"$port" >"$tmp/out" 2>"$tmp/err" || fail "dry run with a missing project directory must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ ! -e "$CLAUDE_LOG" ] || fail "dry run with a missing project directory must not call claude: $(cat "$CLAUDE_LOG")"
grep -q '^port: warning: .*Projects/forge' "$tmp/err" || fail "dry run must warn on stderr about the missing ~/Projects/forge: $(cat "$tmp/err")"
grep -qxF 'mcp playwright ~/Projects/ACME: drift' "$tmp/out" || fail "a missing project directory must not stop the other projects: $(cat "$tmp/out")"
grep -v '"~/Projects/forge"' "$fx/apply.log" >"$tmp/apply-noforge.log"
rm -f "$CLAUDE_LOG"
put_plugins
cp "$HOME/.claude.json" "$tmp/claude-before"
"$port" --apply --plugins >"$tmp/out" 2>"$tmp/err" || fail "--apply with a missing project directory must exit 0: $(cat "$tmp/out" "$tmp/err")"
grep -q '^port: warning: .*Projects/forge' "$tmp/err" || fail "--apply must warn on stderr about the missing ~/Projects/forge: $(cat "$tmp/err")"
[ ! -e "$HOME/Projects/forge" ] || fail "--apply must not create the missing project directory"
calls >"$tmp/calls"
jq -cS . "$tmp/apply-noforge.log" >"$tmp/want-calls"
diff -u "$tmp/want-calls" "$tmp/calls" || fail "--apply must skip the missing project directory and handle the rest"
mkprojects
ok "missing project directory skipped"
fi

settings=$root/global/settings.json
live=$HOME/.claude/settings.json
ov=$HOME/.config/forge/settings.json
fresh() {
  rm -rf "$HOME"
  mkdir -p "$HOME"
  mkprojects
  cp "$cj" "$HOME/.claude.json"
}
drifts() { grep -qE '^[^ ]{11} settings\.json$' "$tmp/out"; }
put_overlay() {
  mkdir -p "${ov%/*}"
  cp "$fx/overlay.json" "$ov"
  touch -d '2001-02-03 04:05:06' "$ov"
}
overlay_kept() {
  cmp -s "$fx/overlay.json" "$ov" || fail "$1 must not write the overlay: $(cat "$ov")"
  [ "$(stat -c %Y "$ov")" = "$(date -d '2001-02-03 04:05:06' +%s)" ] || fail "$1 must not touch the overlay's mtime"
}
apply_plain() {
  "$port" --apply >"$tmp/out" 2>&1 || fail "--apply exited non-zero: $(cat "$tmp/out")"
  [ -f "$live" ] && [ ! -L "$live" ] || fail "~/.claude/settings.json must be a regular file"
}
plain_home() {
  if [ -d "$tmp/home-snap" ]; then
    rm -rf "$HOME"
    cp -a "$tmp/home-snap" "$HOME"
  else
    fresh
    apply_plain
    cp -a "$HOME" "$tmp/home-snap"
  fi
}




if want "invalid overlay"; then
for bad in '{not json' '[1,2]' '{"env":{"A":"1"}} {"env":{"B":"2"}}' ''; do
  for mode in "" --apply; do
    fresh
    mkdir -p "${ov%/*}"
    printf '%s\n' "$bad" >"$ov"
    rm -f "$CLAUDE_LOG"
    if "$port" ${mode:+"$mode"} >"$tmp/out" 2>"$tmp/err"; then
      fail "overlay '$bad' must make port ${mode:-dry run} exit non-zero: $(cat "$tmp/out" "$tmp/err")"
    fi
    grep -q '^jq: ' "$tmp/err" || fail "overlay '$bad' must print jq's error on stderr: $(cat "$tmp/err")"
    [ "$(cd "$HOME" && find . \( -type f -o -type l \) | sort)" = "$(printf './.claude.json\n./.config/forge/settings.json')" ] \
      || fail "overlay '$bad' must stop port ${mode:-dry run} before any live write: $(cd "$HOME" && find . -type f | sort)"
    [ ! -e "$CLAUDE_LOG" ] || fail "overlay '$bad' must stop port before any claude call: $(cat "$CLAUDE_LOG")"
    [ "$(cat "$ov")" = "$bad" ] || fail "port must not write the invalid overlay"
    [ ! -e "$HOME/.local/state/forge/port.manifest" ] || fail "overlay '$bad' must stop port ${mode:-dry run} before writing the manifest"
  done
done
ok "invalid overlay"
fi

manifest=$HOME/.local/state/forge/port.manifest
pending=$HOME/.local/state/forge/port.reload-pending
mine=$HOME/.claude/skills/mine/SKILL.md
installed() {
  find "$HOME" \( -type f -o -type l \) ! -path "$HOME/.claude.json" ! -path "$manifest" ! -path "$pending" ! -path "$mine" ! -path "${manifest%/*}/port.json" ! -path "${manifest%/*}/port.settings.json" ! -path "$HOME/.claude/forge-backup-*" ! -path "${manifest%/*}/CLAUDE.md.base" ! -path "$HOME/.claude/plugins/*" | sort
}
deletions() { grep -E '^\*deleting' "$tmp/out" || true; }

if want "manifest"; then
fresh
mkdir -p "${mine%/*}"
echo mine >"$mine"
dry
[ -z "$(deletions)" ] || fail "dry run with no manifest must list no deletions: $(deletions)"
[ ! -e "$manifest" ] || fail "dry run must not write the manifest"
apply_plain
[ -f "$manifest" ] || fail "--apply must write ~/.local/state/forge/port.manifest"
sort -c "$manifest" || fail "manifest must be LC_ALL=C sorted: $(cat "$manifest")"
grep -qxF "$HOME/.claude/settings.json" "$manifest" || fail "manifest must hold ~/.claude/settings.json: $(cat "$manifest")"
! grep -qxF "$HOME/.claude/CLAUDE.md" "$manifest" || fail "manifest must not hold ~/.claude/CLAUDE.md: $(cat "$manifest")"
! grep -qxF "$HOME/.claude/mcp.json" "$manifest" || fail "manifest must not hold ~/.claude/mcp.json"
! grep -qxF "$HOME/.claude/mcp-projects.json" "$manifest" || fail "manifest must not hold ~/.claude/mcp-projects.json"
! grep -qxF "$HOME/.claude/plugins.json" "$manifest" || fail "manifest must not hold ~/.claude/plugins.json"
while IFS= read -r p; do
  case $p in /*) ;; *) fail "manifest line must be an absolute path: '$p'" ;; esac
  [ -f "$p" ] || fail "manifest line must be a shipped file: '$p'"
done <"$manifest"
diff -u <(installed) "$manifest" || fail "manifest must be exactly the shipped set"
[ -f "$mine" ] || fail "--apply with no manifest must prune nothing"
! grep -qxF "$mine" "$manifest" || fail "manifest must not hold a file port never installed"
ok "manifest"
fi

seed_stale() {
  fresh
  mkdir -p "${mine%/*}"
  echo mine >"$mine"
  apply_plain
  stale=$HOME/.claude/skills/gone/sub/SKILL.md
  mkdir -p "${stale%/*}"
  echo stale >"$stale"
  { cat "$manifest"; echo "$stale"; } | sort >"$tmp/seeded"
  cp "$tmp/seeded" "$manifest"
}

if want "dry run deletions"; then
seed_stale
touch -d '2001-02-03 04:05:06' "$manifest"
dry
[ "$(deletions)" = "$(printf '%-11s %s' '*deleting' "$stale")" ] \
  || fail "dry run must list '*deleting   $stale' and nothing else: $(deletions)"
[ -f "$stale" ] || fail "dry run must not prune"
cmp -s "$tmp/seeded" "$manifest" || fail "dry run must not rewrite the manifest"
[ "$(stat -c %Y "$manifest")" = "$(date -d '2001-02-03 04:05:06' +%s)" ] || fail "dry run must not touch the manifest"
ok "dry run deletions"
fi

if want "prune"; then
seed_stale
apply_plain
[ ! -e "$stale" ] || fail "--apply must remove a manifest file the repo no longer ships"
[ ! -e "$HOME/.claude/skills/gone" ] || fail "--apply must remove directories the removal left empty"
[ -d "$HOME/.claude/skills" ] || fail "--apply must keep the map target root"
[ -f "$mine" ] || fail "--apply must keep a file not in the manifest"
! grep -qxF "$stale" "$manifest" || fail "manifest must be rewritten without the removed file"
diff -u <(installed) "$manifest" || fail "rewritten manifest must be exactly the shipped set"
ok "prune"
fi

repo=$tmp/repo
mkrepo() {
  rm -rf "$repo"
  mkdir -p "$repo/output-styles"
  mksrc "$repo"
}
if want "map target root kept"; then
mkrepo
fresh
old=$HOME/.claude/output-styles/deep/old.md
mkdir -p "${old%/*}" "${manifest%/*}"
echo old >"$old"
echo "$old" >"$manifest"
"$repo/port" --apply >"$tmp/out" 2>&1 || fail "--apply exited non-zero: $(cat "$tmp/out")"
[ ! -e "$old" ] || fail "--apply must remove a manifest file under a map whose source is empty"
[ ! -e "$HOME/.claude/output-styles/deep" ] || fail "--apply must remove the emptied directory under the map target"
[ -d "$HOME/.claude/output-styles" ] || fail "--apply must never remove a map target directory, even when empty"
ok "map target root kept"
fi

if want "prune after install"; then
plain_home
cp "$manifest" "$tmp/good"
stale=$HOME/.claude/skills/gone/SKILL.md
mkdir -p "${stale%/*}"
echo stale >"$stale"
{ cat "$tmp/good"; echo "$stale"; } | sort >"$manifest"
cp "$manifest" "$tmp/seeded"
mkdir -p "$tmp/failbin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/failbin/claude"
chmod +x "$tmp/failbin/claude"
if PATH=$tmp/failbin:$PATH "$port" --apply >"$tmp/out" 2>&1; then
  fail "--apply must exit non-zero when a claude call fails: $(cat "$tmp/out")"
fi
[ -f "$stale" ] || fail "--apply must not prune before the install succeeds"
cmp -s "$tmp/seeded" "$manifest" || fail "--apply must not rewrite the manifest when the install fails"
ok "prune after install"
fi

if want "prune stays inside map targets"; then
fresh
put_overlay
outside=$HOME/unrelated.txt
echo keep >"$outside"
mkdir -p "${manifest%/*}"
printf '%s\n' "$ov" "$outside" "$HOME/.claude/../unrelated.txt" "$HOME/.claude" >"$manifest"
dry
[ -z "$(deletions)" ] || fail "dry run must not list manifest paths outside every map target: $(deletions)"
apply_plain
overlay_kept "--apply with the overlay in the manifest"
[ -f "$outside" ] || fail "--apply must never remove a manifest path outside every map target"
[ -d "$HOME/.claude" ] || fail "--apply must never remove a map target listed in the manifest"
ok "prune stays inside map targets"
fi

elsewhere=$tmp/elsewhere
if want "prune never follows symlinked directories"; then
for link in "$HOME/.claude/skills/linked" "$HOME/.claude/skills"; do
  plain_home
  cp "$manifest" "$tmp/good"
  rm -rf "$elsewhere"
  mkdir -p "$elsewhere"
  echo keep >"$elsewhere/SKILL.md"
  rm -rf "$link"
  ln -s "$elsewhere" "$link"
  through=$HOME/.claude/skills/linked/SKILL.md
  [ "$link" = "$HOME/.claude/skills" ] && through=$HOME/.claude/skills/SKILL.md
  { cat "$tmp/good"; echo "$through"; } | sort >"$manifest"
  dry
  [ -z "$(deletions)" ] || fail "dry run must not list a manifest path under symlinked $link: $(deletions)"
  apply_plain
  [ -f "$elsewhere/SKILL.md" ] || fail "--apply must never delete through symlinked $link"
  rm -f "$link"
done
ok "prune never follows symlinked directories"
fi

if want "prune across file-directory replacements"; then
plain_home
cp "$manifest" "$tmp/good"
shipped_file=$HOME/.claude/agents/$(ls "$src/agents" | head -n1)
rm -f "$shipped_file"
mkdir -p "$shipped_file"
echo stale >"$shipped_file/old.md"
{ cat "$tmp/good"; echo "$shipped_file/old.md"; } | sort >"$manifest"
apply_plain
[ -f "$shipped_file" ] || fail "--apply must replace a stale manifest directory with the file now shipped at its path"
diff -u <(installed) "$manifest" || fail "manifest must be exactly the shipped set after a directory becomes a file"
shipped_dir=$HOME/.claude/skills/forge-new
rm -rf "$shipped_dir"
echo stale >"$shipped_dir"
{ cat "$tmp/good"; echo "$shipped_dir"; } | sort >"$manifest"
apply_plain
[ -f "$shipped_dir/SKILL.md" ] || fail "--apply must replace a stale manifest file with the directory now shipped at its path"
diff -u <(installed) "$manifest" || fail "manifest must be exactly the shipped set after a file becomes a directory"
ok "prune across file-directory replacements"
fi

units=$HOME/.config/systemd/user
reload='["--user","daemon-reload"]'
isen='["--user","is-enabled","--quiet","forge-watchdog.timer"]'
running=$isen$'\n''["--user","is-active","--quiet","forge-watchdog.timer"]'
enable='["--user","enable","--now","forge-watchdog.timer"]'
own=$units/idle-suspend-gate.service
apply_units() {
  rm -f "$SYSTEMCTL_LOG"
  "$1" --apply >"$tmp/out" 2>&1 || fail "--apply exited non-zero: $(cat "$tmp/out")"
  touch "$SYSTEMCTL_LOG"
  [ "$(cat "$SYSTEMCTL_LOG")" = "$2" ] || fail "$3: systemctl calls must be '$2', got '$(cat "$SYSTEMCTL_LOG")'"
}
seed_units() {
  fresh
  touch "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
  mkdir -p "$units"
  echo own >"$own"
  apply_plain
}

if want "units install"; then
fresh
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
mkdir -p "$units"
echo own >"$own"
dry
for u in forge-watchdog.service forge-watchdog.timer; do
  grep -qE "^[^ ]{11} ${u//./\\.}\$" "$tmp/out" || fail "dry run must list systemd/$u: $(cat "$tmp/out")"
  [ ! -e "$units/$u" ] || fail "dry run must not install $u"
done
apply_units "$port" "$reload"$'\n'"$isen"$'\n'"$enable" "--apply with new units and the timer disabled"
[ -e "$SYSTEMCTL_ENABLED" ] || fail "--apply must enable forge-watchdog.timer once its units are installed"
for u in forge-watchdog.service forge-watchdog.timer; do
  cmp -s "$root/systemd/$u" "$units/$u" || fail "--apply must install systemd/$u to ~/.config/systemd/user/$u"
  grep -qxF "$units/$u" "$manifest" || fail "manifest must hold ~/.config/systemd/user/$u: $(cat "$manifest")"
done
[ "$(cat "$own")" = own ] || fail "--apply must leave the operator's own user units untouched"
! grep -qxF "$own" "$manifest" || fail "manifest must not hold a user unit port never installed"
diff -u <(installed | grep -vxF "$own") "$manifest" || fail "manifest must be exactly the shipped set with the units"
ok "units install"
fi

if want "no daemon-reload without a unit change"; then
seed_units
dry
apply_units "$port" "$running" "--apply with the units unchanged and the timer enabled"
echo drift >>"$HOME/.claude/forge/jbc/pin.json"
apply_units "$port" "$running" "--apply with only a non-unit file changed and the timer enabled"
ok "no daemon-reload without a unit change"
fi

if want "daemon-reload on a changed unit"; then
seed_units
mkrepo
echo drift >>"$units/forge-watchdog.timer"
dry
apply_units "$port" "$reload"$'\n'"$running" "--apply over a drifted live unit"
cmp -s "$root/systemd/forge-watchdog.timer" "$units/forge-watchdog.timer" || fail "--apply must restore a drifted live unit"
echo '# changed' >>"$repo/systemd/forge-watchdog.service"
git -C "$repo" commit -q -am changed
apply_units "$repo/port" "$reload"$'\n'"$running" "--apply with a changed unit source"
cmp -s "$repo/systemd/forge-watchdog.service" "$units/forge-watchdog.service" || fail "--apply must install a changed unit source"
[ "$(cat "$own")" = own ] || fail "--apply must leave the operator's own user units untouched"
ok "daemon-reload on a changed unit"
fi

if want "daemon-reload on a pruned unit"; then
fresh
touch "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
apply_units "$port" "$reload"$'\n'"$running" "--apply with new units and the timer enabled"
gone=$units/forge-old.timer
echo old >"$gone"
{ cat "$manifest"; echo "$gone"; } | sort >"$tmp/seeded"
cp "$tmp/seeded" "$manifest"
apply_units "$port" "$reload"$'\n'"$running" "--apply pruning a unit"
[ ! -e "$gone" ] || fail "--apply must prune a unit port no longer ships"
ok "daemon-reload on a pruned unit"
fi

mkdir -p "$tmp/failctl"
printf '#!/usr/bin/env bash\necho "Failed to connect to bus" >&2\nexit 1\n' >"$tmp/failctl/systemctl"
chmod +x "$tmp/failctl/systemctl"

if want "failed daemon-reload finishes the run and exits non-zero"; then
fresh
gone=$units/forge-old.timer
mkdir -p "$units" "${manifest%/*}"
echo old >"$gone"
echo "$gone" >"$manifest"
rm -f "$CLAUDE_LOG"
if PATH=$tmp/failctl:$PATH "$port" --apply >"$tmp/out" 2>&1; then fail "--apply must exit non-zero when daemon-reload fails: $(cat "$tmp/out")"; fi
grep -q 'daemon-reload failed' "$tmp/out" || fail "--apply must report a failed daemon-reload: $(cat "$tmp/out")"
[ -s "$CLAUDE_LOG" ] || fail "--apply must still sync MCP servers after a failed daemon-reload"
[ ! -e "$gone" ] || fail "--apply must still prune after a failed daemon-reload"
diff -u <(installed) "$manifest" || fail "--apply must still write the manifest after a failed daemon-reload"
[ -e "$pending" ] || fail "--apply must record a pending daemon-reload after it fails"
ok "failed daemon-reload finishes the run and exits non-zero"
fi

if want "pending daemon-reload retried until it succeeds"; then
fresh
touch "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
if PATH=$tmp/failctl:$PATH "$port" --apply >"$tmp/out" 2>&1; then fail "setup: --apply must fail when daemon-reload fails: $(cat "$tmp/out")"; fi
if PATH=$tmp/failctl:$PATH "$port" --apply >"$tmp/out" 2>&1; then fail "--apply must retry a pending daemon-reload and fail again: $(cat "$tmp/out")"; fi
[ -e "$pending" ] || fail "--apply must keep a pending daemon-reload that failed again"
apply_units "$port" "$reload"$'\n'"$running" "--apply with a pending daemon-reload and no unit change"
[ ! -e "$pending" ] || fail "--apply must clear the pending daemon-reload once it succeeds"
apply_units "$port" "$running" "--apply after the pending daemon-reload succeeded"
ok "pending daemon-reload retried until it succeeds"
fi

if want "timer enabled when disabled"; then
plain_home
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
apply_units "$port" "$isen"$'\n'"$enable" "--apply with the units installed and the timer disabled"
[ -e "$SYSTEMCTL_ENABLED" ] || fail "--apply must enable a disabled forge-watchdog.timer"
apply_units "$port" "$running" "--apply right after enabling the timer"
ok "timer enabled when disabled"
fi

if want "failed enable warns and exits 0"; then
plain_home
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE" "$SYSTEMCTL_LOG"
SYSTEMCTL_FAIL_ENABLE=1 "$port" --apply >"$tmp/out" 2>"$tmp/err" || fail "--apply must exit 0 when enabling the timer fails: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$SYSTEMCTL_LOG")" = "$isen"$'\n'"$enable" ] || fail "--apply with a failing enable must query then try the enable, got '$(cat "$SYSTEMCTL_LOG")'"
grep -q '^port: warning: .*forge-watchdog\.timer' "$tmp/err" || fail "--apply must warn on stderr naming forge-watchdog.timer when the enable fails: $(cat "$tmp/err")"
! grep -q 'port: warning' "$tmp/out" || fail "the enable warning must go to stderr, not stdout: $(cat "$tmp/out")"
[ ! -e "$pending" ] || fail "a failed enable must not record a pending daemon-reload"
grep -q '^ported ' "$tmp/out" || fail "--apply must finish the run after a failed enable: $(cat "$tmp/out")"
apply_units "$port" "$isen"$'\n'"$enable" "--apply after a failed enable"
[ -e "$SYSTEMCTL_ENABLED" ] || fail "--apply must retry enabling the timer after a failed enable"
ok "failed enable warns and exits 0"
fi

if want "enabled but stopped timer started on the next apply"; then
plain_home
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE" "$SYSTEMCTL_LOG"
SYSTEMCTL_FAIL_START=1 "$port" --apply >"$tmp/out" 2>"$tmp/err" || fail "--apply must exit 0 when starting the timer fails: $(cat "$tmp/out" "$tmp/err")"
[ "$(cat "$SYSTEMCTL_LOG")" = "$isen"$'\n'"$enable" ] || fail "--apply with a failing start must query then try the enable, got '$(cat "$SYSTEMCTL_LOG")'"
grep -q '^port: warning: .*forge-watchdog\.timer' "$tmp/err" || fail "--apply must warn on stderr naming forge-watchdog.timer when the start fails: $(cat "$tmp/err")"
[ -e "$SYSTEMCTL_ENABLED" ] && [ ! -e "$SYSTEMCTL_ACTIVE" ] || fail "a failed start must leave the timer enabled but stopped"
apply_units "$port" "$running"$'\n'"$enable" "--apply with the timer enabled but not running"
[ -e "$SYSTEMCTL_ACTIVE" ] || fail "--apply must start an enabled timer that is not running"
apply_units "$port" "$running" "--apply once the timer is enabled and running"
ok "enabled but stopped timer started on the next apply"
fi

if want "failed daemon-reload skips the enable"; then
fresh
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE" "$SYSTEMCTL_LOG"
if SYSTEMCTL_FAIL_RELOAD=1 "$port" --apply >"$tmp/out" 2>&1; then fail "--apply must exit non-zero when daemon-reload fails: $(cat "$tmp/out")"; fi
[ "$(cat "$SYSTEMCTL_LOG")" = "$reload" ] || fail "--apply must not query or enable the timer after a failed daemon-reload, got '$(cat "$SYSTEMCTL_LOG")'"
[ ! -e "$SYSTEMCTL_ENABLED" ] || fail "--apply must not enable the timer after a failed daemon-reload"
ok "failed daemon-reload skips the enable"
fi

if want "no timer enable without both units"; then
for u in forge-watchdog.service forge-watchdog.timer; do
  fresh
  rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
  mkdir -p "$HOME/.config/forge"
  echo "/$u" >"$HOME/.config/forge/port-exclude"
  apply_units "$port" "$reload" "--apply with $u not installed"
  [ ! -e "$units/$u" ] || fail "port-exclude must keep $u from being installed"
  [ ! -e "$SYSTEMCTL_ENABLED" ] || fail "--apply must not enable the timer while $u is not installed"
done
ok "no timer enable without both units"
fi

if want "timer enable follows --only"; then
fresh
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE"
apply_units "$port" "$reload"$'\n'"$isen"$'\n'"$enable" "--apply installing the units"
rm -f "$SYSTEMCTL_ENABLED" "$SYSTEMCTL_ACTIVE" "$SYSTEMCTL_LOG"
"$port" --apply --only skills/forge-phase >"$tmp/out" 2>&1 || fail "--only skills/forge-phase --apply exited non-zero: $(cat "$tmp/out")"
[ ! -e "$SYSTEMCTL_LOG" ] || fail "--only outside systemd/ must make no systemctl call: $(cat "$SYSTEMCTL_LOG")"
rm -f "$SYSTEMCTL_LOG"
"$port" --apply --only systemd >"$tmp/out" 2>&1 || fail "--only systemd --apply exited non-zero: $(cat "$tmp/out")"
touch "$SYSTEMCTL_LOG"
[ "$(cat "$SYSTEMCTL_LOG")" = "$isen"$'\n'"$enable" ] || fail "--only systemd must query and enable the timer, got '$(cat "$SYSTEMCTL_LOG")'"
ok "timer enable follows --only"
fi

refused() {
  fresh
  rm -f "$CLAUDE_LOG"
  if "$port" --apply >"$tmp/out" 2>&1; then fail "--apply $1 must refuse: $(cat "$tmp/out")"; fi
  grep -qF "$2" "$tmp/out" || fail "--apply $1 must say '$2': $(cat "$tmp/out")"
  grep -qF "forge golive" "$tmp/out" || fail "--apply $1 must point at forge golive: $(cat "$tmp/out")"
  [ "$(cd "$HOME" && find . -type f)" = ./.claude.json ] || fail "--apply $1 must write nothing: $(cd "$HOME" && find . -type f)"
  [ ! -e "$CLAUDE_LOG" ] || fail "--apply $1 must call no claude: $(cat "$CLAUDE_LOG")"
  dry
}
if want "apply only from a clean main"; then
git -C "$src" checkout -q -b other
refused "off main" "on branch other"
git -C "$src" checkout -q --detach main
refused "on a detached HEAD" "detached"
git -C "$src" checkout -q main
echo dirty >>"$src/skills/forge-phase/SKILL.md"
refused "with a dirty tracked file" "skills/forge-phase/SKILL.md"
git -C "$src" checkout -q -- skills
mkdir -p "$src/skills/unlanded" && echo u >"$src/skills/unlanded/SKILL.md" && echo u >"$src/bin/forge-unlanded"
refused "with untracked files in a mapped source" "untracked files bin/forge-unlanded skills/unlanded/SKILL.md"
rm -r "$src/skills/unlanded" "$src/bin/forge-unlanded"
mkdir -p "$src/.forge"
echo '{}' >"$src/.forge/x.json" && git -C "$src" add .forge && git -C "$src" commit -q -m forge
echo '{"a":1}' >"$src/.forge/x.json"
echo u >"$src/untracked.txt"
fresh
apply_plain
git -C "$src" checkout -q -- .forge && rm "$src/untracked.txt"
ok "apply only from a clean main"
fi

leaked() { find "$HOME" \( -name '*.pyc' -o -name secret.env -o -name __pycache__ \); }

if want "ignored files"; then
printf '*.pyc\n__pycache__/\nsecret.env\n' >"$src/.gitignore"
git -C "$src" add .gitignore && git -C "$src" commit -q -m ignore
ign=(skills/forge-phase/x.pyc skills/__pycache__/a.pyc hooks/secret.env hooks/cache/__pycache__/b.pyc)
for x in "${ign[@]}"; do mkdir -p "$src/${x%/*}" && echo secret >"$src/$x"; done
fresh
dry
! grep -qE 'pyc|__pycache__|secret\.env' "$tmp/out" || fail "dry run must not list git-ignored files: $(cat "$tmp/out")"
apply_plain
! grep -qE 'pyc|__pycache__|secret\.env' "$tmp/out" || fail "--apply must not list git-ignored files: $(cat "$tmp/out")"
[ -z "$(leaked)" ] || fail "--apply must not copy git-ignored files: $(leaked)"
! grep -qE 'pyc|__pycache__|secret\.env' "$manifest" || fail "the manifest must not hold git-ignored files: $(grep -E 'pyc|secret' "$manifest")"
[ -f "$HOME/.claude/skills/forge-phase/SKILL.md" ] || fail "--apply must still copy the tracked files beside ignored ones"
for o in skills/forge-phase hooks skills/forge-phase/x.pyc; do
  fresh
  "$port" --apply --only "$o" >"$tmp/out" 2>&1 || fail "--only $o exited non-zero: $(cat "$tmp/out")"
  [ -z "$(leaked)" ] || fail "--only $o must not copy git-ignored files: $(leaked)"
done
for x in "${ign[@]}"; do rm -f "$src/$x"; done
rm -r "$src/skills/__pycache__" "$src/hooks/cache"
ok "ignored files"
fi

stamp=$HOME/.local/state/forge/port.json
stamped='def utc: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"); def part($c): (keys == ["commit", "time"]) and .commit == $c and (.time | utc);'
if want stamp; then
fresh
dry
[ ! -e "$stamp" ] || fail "dry run must not write the stamp"
! grep -q '^ported ' "$tmp/out" || fail "dry run must not print ported: $(cat "$tmp/out")"
apply_plain
jq -e --arg c "$(git -C "$src" rev-parse HEAD)" "$stamped"' .commit == $c and (.time | utc) and (keys == ["bin", "commit", "rest", "source", "time"]) and (.bin | part($c)) and (.rest | part($c))' "$stamp" >/dev/null \
  || fail "--apply must write {commit, time, bin: {commit, time}, rest: {commit, time}} at HEAD to port.json: $(cat "$stamp")"
[ "$(tail -n1 "$tmp/out")" = "ported $(git -C "$src" rev-parse --short HEAD)" ] || fail "--apply must end with ported <sha>: $(tail -n1 "$tmp/out")"
ok stamp
fi

if want "atomic writes"; then
plain_home
for f in "$manifest" "$stamp"; do
  echo old >"$f"
  ln -f "$f" "$tmp/link"
  apply_plain
  [ "$(cat "$tmp/link")" = old ] || fail "--apply must replace ${f##*/} by rename, not rewrite it in place"
  [ "$(cat "$f")" != old ] || fail "--apply must rewrite ${f##*/}"
done
left=$(find "$HOME" -name 'settings.json.?*' -o -name 'port.manifest.?*' -o -name 'port.json.?*')
[ -z "$left" ] || fail "--apply must leave no temp files: $left"
ok "atomic writes"
fi

if want only; then
fresh
"$port" --only skills/forge-phase >"$tmp/out" 2>&1 || fail "--only dry run exited non-zero: $(cat "$tmp/out")"
grep -q 'forge-phase/SKILL.md$' "$tmp/out" || fail "--only dry run lists the subtree: $(cat "$tmp/out")"
! grep -qE 'CLAUDE\.md$|settings\.json$|forge-ship|^mcp ' "$tmp/out" || fail "--only dry run lists only the subtree: $(cat "$tmp/out")"
mkdir -p "${manifest%/*}"
stale=$HOME/.claude/skills/gone/SKILL.md
mkdir -p "${stale%/*}" && echo stale >"$stale"
echo "$stale" >"$manifest"
rm -f "$CLAUDE_LOG"
"$port" --only skills/forge-phase --apply >"$tmp/out" 2>&1 || fail "--only --apply exited non-zero: $(cat "$tmp/out")"
[ "$(cd "$HOME" && find . -type f ! -path ./.local/state/forge/port.json | sort)" = "$(cd "$HOME" && { echo ./.claude.json; echo ./.local/state/forge/port.manifest; echo ./.claude/skills/gone/SKILL.md; (cd "$src" && find skills/forge-phase -type f | sed 's#^#./.claude/#'); } | sort)" ] \
  || fail "--only skills/forge-phase installs only that subtree: $(cd "$HOME" && find . -type f | sort)"
[ -f "$stale" ] || fail "--only must prune nothing outside its subtree"
[ "$(cat "$manifest")" = "$({ echo "$stale"; (cd "$src" && find skills/forge-phase -type f | sed "s#^#$HOME/.claude/#"); } | sort)" ] || fail "--only must keep manifest paths outside its subtree and record the ones it installs: $(cat "$manifest")"
[ ! -s "$CLAUDE_LOG" ] || fail "--only must not sync MCP servers: $(cat "$CLAUDE_LOG")"
grep -q '^ported ' "$tmp/out" || fail "--only --apply prints ported: $(cat "$tmp/out")"
jq -e '.only == "skills/forge-phase" and (keys == ["commit", "only", "source", "time"])' "$stamp" >/dev/null || fail "--only records the subtree in the stamp: $(cat "$stamp")"
fresh
"$port" --apply --only bin/forge >"$tmp/out" 2>&1 || fail "--only bin/forge exited non-zero: $(cat "$tmp/out")"
[ "$(cd "$HOME" && find . -type f ! -path './.local/state/*' | sort)" = "$(printf './.claude.json\n./.local/bin/forge')" ] || fail "--only bin/forge installs only that file: $(cd "$HOME" && find . -type f)"
cmp -s "$src/bin/forge" "$HOME/.local/bin/forge" || fail "--only bin/forge copies the file"
for bad in nope heritage; do
  if "$port" --only "$bad" >"$tmp/out" 2>&1; then fail "--only $bad must fail: $(cat "$tmp/out")"; fi
  grep -qF -- "--only $bad" "$tmp/out" || fail "--only $bad names the path: $(cat "$tmp/out")"
done
for prior in absent unreadable; do
  fresh
  [ "$prior" = absent ] || { mkdir -p "${stamp%/*}" && echo '{not json' >"$stamp"; }
  "$port" --apply --only bin >"$tmp/out" 2>&1 || fail "--only bin over $prior port.json exited non-zero: $(cat "$tmp/out")"
  jq -e --arg c "$(git -C "$src" rev-parse HEAD)" "$stamped"' (keys == ["bin", "source"]) and (.bin | part($c))' "$stamp" >/dev/null \
    || fail "--only bin over $prior port.json must write {bin: {commit, time}}: $(cat "$stamp")"
done
plain_home
full=$(cat "$stamp")
git -C "$src" commit -q --allow-empty -m bin-part
"$port" --apply --only bin >"$tmp/out" 2>&1 || fail "--only bin exited non-zero: $(cat "$tmp/out")"
[ "$(tail -n1 "$tmp/out")" = "ported $(git -C "$src" rev-parse --short HEAD)" ] || fail "--only bin must end with ported <sha>: $(tail -n1 "$tmp/out")"
jq -e --argjson f "$full" --arg c "$(git -C "$src" rev-parse HEAD)" "$stamped"' (keys == ["bin", "commit", "rest", "source", "time"]) and .commit == $f.commit and .time == $f.time and .rest == $f.rest and (.bin | part($c)) and .bin.commit != .rest.commit' "$stamp" >/dev/null \
  || fail "--only bin must replace only .bin in port.json, keeping commit, time and rest: before $full, after $(cat "$stamp")"
binpart=$(cat "$stamp")
"$port" --apply --only skills/forge-phase >"$tmp/out" 2>&1 || fail "--only skills/forge-phase after --only bin exited non-zero: $(cat "$tmp/out")"
jq -e --argjson p "$binpart" --arg c "$(git -C "$src" rev-parse HEAD)" "$stamped"' (keys == ["bin", "commit", "only", "rest", "source", "time"]) and .commit == $c and (.time | utc) and .only == "skills/forge-phase" and .bin == $p.bin and .rest == $p.rest' "$stamp" >/dev/null \
  || fail "--only skills/forge-phase must write {commit, time, only} and keep bin and rest: before $binpart, after $(cat "$stamp")"
ok only
fi

outside() {
  (cd "$HOME" && find . -path ./.claude/forge-backup-\* -prune -o -path ./.local/bin -prune -o -path ./.local/state/forge/port.json -prune -o \( -type f -o -type l \) -print0 \
    | sort -z | xargs -0 stat -c '%n %i %s %Y' && find . -path ./.claude/forge-backup-\* -prune -o -path ./.local/bin -prune -o -path ./.local/state/forge/port.json -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
}
if want "bin by rename"; then
inplace=$(grep -nE -- '--(inplace|append)' "$root/port" || true)
[ -z "$inplace" ] || fail "no rsync call in port may carry --inplace, --append or --append-verify: $inplace"
plain_home
held=$HOME/.local/bin/forge.d/gate.sh
exec 9<"$held"
old=$(cat "$held")
ino=$(stat -c %i "$held")
before=$(outside)
skill=$(ls "$src/skills" | head -n1) agent=$(ls "$src/agents" | head -n1) hook=$(ls "$src/hooks" | head -n1)
template=$(ls "$src/templates" | head -n1) schema=$(ls "$src/schemas" | head -n1)
for f in bin/forge.d/gate.sh "skills/$skill/SKILL.md" "agents/$agent" "hooks/$hook" "templates/$template" "schemas/$schema" global/forge/jbc/pin.json; do
  echo '# bin-part change' >>"$src/$f"
done
jq '.env.FORGE_BIN_PART = "1"' "$src/global/settings.json" >"$tmp/settings" && cp "$tmp/settings" "$src/global/settings.json"
git -C "$src" commit -q -am bin-rename
"$port" --apply --only bin </dev/null >"$tmp/out" 2>&1 || fail "--only bin over open descriptors exited non-zero: $(cat "$tmp/out")"
held_now=$(cat <&9)
exec 9<&-
[ "$(stat -c %i "$held")" != "$ino" ] || fail "--only bin must replace $held by rename, keeping inode $ino in place"
cmp -s "$src/bin/forge.d/gate.sh" "$held" || fail "--only bin must install the new content of bin/forge.d/gate.sh"
[ "$held_now" = "$old" ] || fail "an open descriptor on $held must still read the old content after --only bin, got: $held_now"
[ "$(outside)" = "$before" ] || fail "--only bin must change nothing outside \$HOME/.local/bin/: $(diff <(echo "$before") <(outside))"
[ "$(tail -n1 "$tmp/out")" = "ported $(git -C "$src" rev-parse --short HEAD)" ] || fail "--only bin must end with ported <sha>: $(tail -n1 "$tmp/out")"
git -C "$src" revert --no-edit HEAD >/dev/null
ok "bin by rename"
fi

if want "only prunes its scope"; then
plain_home
gone=$HOME/.claude/skills/gone/SKILL.md
mkdir -p "${gone%/*}" && echo stale >"$gone" && echo "$gone" >>"$manifest"
git -C "$src" mv bin/forge-init bin/forge-init2
printf '#!/bin/sh\n' >"$src/bin/forge-extra"
git -C "$src" add bin/forge-extra
git -C "$src" commit -q -m bin-rename-add
"$port" --only bin >"$tmp/out" 2>&1 || fail "--only bin dry run exited non-zero: $(cat "$tmp/out")"
[ "$(deletions)" = "$(printf '%-11s %s' '*deleting' "$HOME/.local/bin/forge-init")" ] || fail "--only bin dry run must list only the removed bin file for deletion: $(deletions)"
"$port" --apply --only bin >"$tmp/out" 2>&1 || fail "--only bin after a rename exited non-zero: $(cat "$tmp/out")"
[ ! -e "$HOME/.local/bin/forge-init" ] || fail "--only bin must prune a bin file the checkout no longer ships"
[ -f "$HOME/.local/bin/forge-init2" ] && [ -f "$HOME/.local/bin/forge-extra" ] || fail "--only bin must install the renamed and added bin files"
[ -f "$gone" ] || fail "--only bin must prune nothing outside \$HOME/.local/bin/"
grep -qxF "$gone" "$manifest" || fail "--only bin must keep manifest paths outside its scope"
! grep -qxF "$HOME/.local/bin/forge-init" "$manifest" || fail "--only bin must drop the pruned path from the manifest"
grep -qxF "$HOME/.local/bin/forge-extra" "$manifest" || fail "--only bin must record the bin files it installs in the manifest"
git -C "$src" rm -q bin/forge-extra
git -C "$src" commit -q -m bin-remove
"$port" --apply --only bin >"$tmp/out" 2>&1 || fail "--only bin after a removal exited non-zero: $(cat "$tmp/out")"
[ ! -e "$HOME/.local/bin/forge-extra" ] || fail "--only bin must prune a bin file an earlier --only bin installed"
partial=$(grep -vxF "$gone" "$manifest")
apply_plain
[ "$(cat "$manifest")" = "$partial" ] || fail "--only bin must leave the manifest a full --apply would write, plus out-of-scope paths: $(diff <(echo "$partial") "$manifest")"
[ ! -e "$gone" ] || fail "a full --apply must still prune the out-of-scope path"
git -C "$src" revert --no-edit HEAD~2..HEAD >/dev/null
ok "only prunes its scope"
fi

agents='[{"name":"forge run Phase 03","state":"working"},{"name":"Discuss crm/x","state":"blocked"},{"name":"Quick fix it","state":"idle"},{"name":"Debug crash","state":"working"},{"name":"other forge thing","state":"working"},
  {"name":"lumen crm-x Phase 05","state":"working"},{"name":"nova t-f Phase 12 retry 2","state":"blocked"},{"name":"wave t-f Verify","state":"working"},{"name":"Browser t-f Ship","state":"working"},
  {"name":"Fast tweak","state":"working"},{"name":"New app","state":"working"},{"name":"Quick fix","state":"working"},{"name":"lumen notes","state":"working"},{"name":"Discussion","state":"working"},
  {"name":"lumen discuss crm/x","state":"working"},{"name":"nova build urgent/reply","state":"blocked"},{"name":"wave quick fix the flake","state":"working"},{"name":"forge fast","state":"working"},
  {"name":"forge debug crash on start","state":"blocked"},{"name":"acme new app","state":"working"},{"name":"ACME P63 urgent/reply-templates","state":"working"},
  {"name":"ACME P63R2 urgent/reply-templates","state":"blocked"},{"name":"acme verify urgent/reply-templates","state":"working"},{"name":"acme ship urgent/reply-templates","state":"working"},
  {"name":"acme P7 t/idle-phase","state":"idle"},{"name":"acme quick idle thing","state":"idle"},
  {"name":"wave discussion topics","state":"working"},{"name":"nova verify the logs","state":"working"},{"name":"nova shipping plan","state":"working"}]'
if want "running sessions warning"; then
fresh
CLAUDE_AGENTS_JSON=$agents "$port" --apply >"$tmp/out" 2>&1 || fail "--apply with sessions exited non-zero: $(cat "$tmp/out")"
grep -q 'warning: .*running sessions' "$tmp/out" || fail "--apply changing skills warns about running sessions: $(cat "$tmp/out")"
for n in "forge run Phase 03" "Discuss crm/x" "Debug crash" "lumen crm-x Phase 05" "nova t-f Phase 12 retry 2" "wave t-f Verify" "Browser t-f Ship" "Fast tweak" "New app" "Quick fix" \
  "lumen discuss crm/x" "nova build urgent/reply" "wave quick fix the flake" "forge fast" "forge debug crash on start" "acme new app" \
  "ACME P63 urgent/reply-templates" "ACME P63R2 urgent/reply-templates" "acme verify urgent/reply-templates" "acme ship urgent/reply-templates"; do
  grep -qxF "  $n" "$tmp/out" || fail "the warning lists $n: $(cat "$tmp/out")"
done
for n in "Quick fix it" "acme P7 t/idle-phase" "acme quick idle thing"; do ! grep -qF "$n" "$tmp/out" || fail "an idle session $n is not listed: $(cat "$tmp/out")"; done
for n in "other forge thing" "lumen notes" "Discussion" "wave discussion topics" "nova verify the logs" "nova shipping plan"; do ! grep -qF "$n" "$tmp/out" || fail "a non-forge session $n is not listed: $(cat "$tmp/out")"; done
CLAUDE_AGENTS_JSON=$agents "$port" --apply >"$tmp/out" 2>&1 || fail "second --apply exited non-zero: $(cat "$tmp/out")"
! grep -q 'running sessions' "$tmp/out" || fail "an apply changing no skills, agents, hooks or bin files does not warn: $(cat "$tmp/out")"
echo drift >>"$HOME/.claude/agents/$(ls "$src/agents" | head -n1)"
CLAUDE_AGENTS_JSON=$agents "$port" --apply >"$tmp/out" 2>&1 || fail "third --apply exited non-zero: $(cat "$tmp/out")"
grep -q 'running sessions' "$tmp/out" || fail "an apply restoring an agent warns: $(cat "$tmp/out")"
ok "running sessions warning"
fi

if want "no /home/ in ported files"; then
leaks=$(cd "$root" && grep -rlF /home/ output-styles templates schemas global skills agents hooks bin systemd 2>/dev/null || true)
[ -z "$leaks" ] || fail "no ported file may contain /home/: $leaks"
ok "no /home/ in ported files"
fi

if want "hooks resolve under \$HOME"; then
jq -e '[.hooks[][].hooks[]] | length == 2 and all(has("args") | not)
  and all(.command | test("^sh \"\\$HOME/\\.claude/hooks/forge-hook\\.sh\" [A-Za-z0-9-]+\\.sh$"))' "$settings" >/dev/null \
  || fail "the two hooks must run through forge-hook.sh in shell form: $(jq -c '[.hooks[][].hooks[]]' "$settings")"
ok "hooks resolve under \$HOME"
fi



pex=$HOME/.config/forge/port-exclude
lbin=$HOME/.local/bin
put_pex() {
  mkdir -p "${pex%/*}"
  printf '%s\n' "$@" >"$pex"
  cp "$pex" "$tmp/pex"
  touch -d '2001-02-03 04:05:06' "$pex"
}
pex_kept() {
  cmp -s "$tmp/pex" "$pex" || fail "$1 must not write ~/.config/forge/port-exclude: $(cat "$pex")"
  [ "$(stat -c %Y "$pex")" = "$(date -d '2001-02-03 04:05:06' +%s)" ] || fail "$1 must not touch ~/.config/forge/port-exclude's mtime"
}
installed_pex() { installed | grep -vxF "$pex"; }
listed() { grep -E "^[^ ]{11} ${1//./\\.}\$" "$tmp/out" || true; }
hosts_ex=(/forge-browser /forge-init)

if want "port-exclude drops files from the copy and the manifest"; then
fresh
put_pex "${hosts_ex[@]}"
dry
pex_kept "dry run"
for s in forge-browser forge-init; do
  [ -z "$(listed "$s")" ] || fail "dry run must not list port-excluded bin/$s: $(listed "$s")"
done
[ -n "$(listed forge)" ] || fail "dry run must still list the rest of bin/: $(cat "$tmp/out")"
apply_plain
pex_kept "--apply"
for f in "$root"/bin/*; do
  n=${f##*/}
  case $n in
    forge-browser|forge-init)
      [ ! -e "$lbin/$n" ] || fail "--apply must not install port-excluded bin/$n"
      ! grep -qxF "$lbin/$n" "$manifest" || fail "manifest must not hold port-excluded $lbin/$n" ;;
    *) diff -rq "$f" "$lbin/$n" >/dev/null || fail "--apply must still install bin/$n with a port-exclude" ;;
  esac
done
! grep -qxF "$pex" "$manifest" || fail "manifest must not hold ~/.config/forge/port-exclude"
diff -u <(installed_pex) "$manifest" || fail "manifest must be exactly the shipped set with a port-exclude"
ok "port-exclude drops files from the copy and the manifest"
fi

if want "port-exclude applies to every map"; then
fresh
put_pex /forge/jbc/pin.json
dry
[ -z "$(listed forge/jbc/pin.json)" ] || fail "dry run must not list port-excluded global/forge/jbc/pin.json: $(listed forge/jbc/pin.json)"
apply_plain
pex_kept "--apply excluding global/forge/jbc/pin.json"
[ ! -e "$HOME/.claude/forge/jbc/pin.json" ] || fail "--apply must not install port-excluded global/forge/jbc/pin.json"
! grep -qxF "$HOME/.claude/forge/jbc/pin.json" "$manifest" || fail "manifest must not hold port-excluded pin.json"
[ -f "$lbin/forge-browser" ] || fail "a global/-only port-exclude must not drop bin/forge-browser"
diff -u <(installed_pex) "$manifest" || fail "manifest must be exactly the shipped set with a global/ port-exclude"
ok "port-exclude applies to every map"
fi

if want "port-exclude prunes files shipped before"; then
plain_home
for s in forge-browser forge-init; do
  [ -f "$lbin/$s" ] && grep -qxF "$lbin/$s" "$manifest" || fail "--apply with no port-exclude must ship bin/$s"
done
echo own >"$lbin/own-tool"
( cd "$lbin" && find . \( -type f -o -type l \) | sort ) | grep -vxE '\./(forge-browser|forge-init)' >"$tmp/keep-bin"
cp "$manifest" "$tmp/before"
touch -d '2001-02-03 04:05:06' "$manifest"
put_pex "${hosts_ex[@]}"
dry
pex_kept "dry run over a manifest holding the excluded files"
[ "$(deletions)" = "$(printf '%-11s %s\n%-11s %s' '*deleting' "$lbin/forge-browser" '*deleting' "$lbin/forge-init")" ] \
  || fail "dry run must list exactly the two excluded scripts as '*deleting': $(deletions)"
for s in forge-browser forge-init; do
  [ -f "$lbin/$s" ] || fail "dry run must not remove $lbin/$s"
done
cmp -s "$tmp/before" "$manifest" || fail "dry run must not rewrite the manifest"
[ "$(stat -c %Y "$manifest")" = "$(date -d '2001-02-03 04:05:06' +%s)" ] || fail "dry run must not touch the manifest"
apply_plain
pex_kept "--apply pruning the excluded files"
for s in forge-browser forge-init; do
  [ ! -e "$lbin/$s" ] || fail "--apply must prune $lbin/$s once port-exclude names it"
  ! grep -qxF "$lbin/$s" "$manifest" || fail "manifest must be rewritten without $lbin/$s"
done
diff -u "$tmp/keep-bin" <(cd "$lbin" && find . \( -type f -o -type l \) | sort) || fail "--apply must keep every other ~/.local/bin file"
[ "$(cat "$lbin/own-tool")" = own ] || fail "--apply must keep the operator's own ~/.local/bin file"
diff -u <(installed_pex | grep -vxF "$lbin/own-tool") "$manifest" || fail "rewritten manifest must be exactly the shipped set"
! grep -qxF "$pex" "$manifest" || fail "manifest must not hold ~/.config/forge/port-exclude"
ok "port-exclude prunes files shipped before"
fi

if want "unreadable port-exclude fails the run"; then
plain_home
cp "$manifest" "$tmp/before"
touch -d '2001-02-03 04:05:06' "$manifest"
mkdir -p "$pex"
rm -f "$CLAUDE_LOG"
if "$port" --apply >"$tmp/out" 2>&1; then
  fail "--apply must exit non-zero when rsync cannot read the port-exclude: $(cat "$tmp/out")"
fi
for s in forge-browser forge-init; do
  [ -f "$lbin/$s" ] || fail "--apply with an unreadable port-exclude must prune nothing: $lbin/$s is gone"
done
cmp -s "$tmp/before" "$manifest" || fail "--apply with an unreadable port-exclude must not rewrite the manifest"
[ "$(stat -c %Y "$manifest")" = "$(date -d '2001-02-03 04:05:06' +%s)" ] || fail "--apply with an unreadable port-exclude must not touch the manifest"
[ -d "$pex" ] || fail "port must not replace the unreadable port-exclude"
ok "unreadable port-exclude fails the run"
fi

user_settings() {
  mkdir -p "${live%/*}"
  jq -n '{model: "sonnet", theme: "dark", env: {MY_VAR: "1", CLAUDE_CODE_PLUGIN_DIRS: "/my/mods"},
    permissions: {deny: ["Bash(rm *)"]},
    hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "my-hook"}]}], Stop: [{hooks: [{type: "command", command: "my-stop"}]}]}}' >"$live"
  printf '# mine\n' >"$HOME/.claude/CLAUDE.md"
  cp "$live" "$tmp/user-settings"
}

if want "shipped settings are forge's only"; then
jq -e 'keys == ["env", "hooks"] and (.env | keys) == ["CLAUDE_CODE_PLUGIN_DIRS"]
  and ([.. | objects | keys[]] | any(IN("defaultMode", "skipDangerousModePermissionPrompt", "remoteControlAtStartup", "model", "effortLevel", "outputStyle", "statusLine", "voice", "theme")) | not)' "$settings" >/dev/null \
  || fail "global/settings.json must hold only forge's hooks and env: $(jq -c 'keys' "$settings")"
ok "shipped settings are forge's only"
fi

if want "install merges and keeps user keys"; then
fresh
user_settings
sha=$(sha256sum <"$HOME/.claude/CLAUDE.md")
apply_plain
[ "$(sha256sum <"$HOME/.claude/CLAUDE.md")" = "$sha" ] || fail "--apply must not change ~/.claude/CLAUDE.md"
jq -e '.model == "sonnet" and .theme == "dark" and .env.MY_VAR == "1" and .env.CLAUDE_CODE_PLUGIN_DIRS == "/my/mods"
  and .permissions.deny == ["Bash(rm *)"]
  and (.hooks.Stop | length) == 1
  and ([.hooks.PreToolUse[].hooks[].command] | index("my-hook") != null and any(test("forge-guard")))
  and ([.hooks.UserPromptSubmit[].hooks[].command] | any(test("forge-session-title")))' "$live" >/dev/null \
  || fail "--apply must keep every user key and add forge's hooks: $(cat "$live")"
rec=$HOME/.local/state/forge/port.settings.json
[ "$(jq -c '[.hooks[].event] | sort' "$rec")" = '["PreToolUse","UserPromptSubmit"]' ] || fail "the record must name the hooks port added: $(cat "$rec")"
[ "$(jq -c '.added' "$rec")" = '[]' ] || fail "a user's own env value is not forge's addition: $(cat "$rec")"
bk=$(jq -r .first_backup "$rec")
cmp -s "$bk/.claude/settings.json" "$tmp/user-settings" || fail "--apply must back up settings.json first: $bk"
cp "$live" "$tmp/once"
apply_plain
cmp -s "$tmp/once" "$live" || fail "a second --apply must leave the merged settings unchanged"
[ "$(jq '[.hooks.PreToolUse[].hooks[].command] | map(select(test("forge-guard"))) | length' "$live")" = 1 ] || fail "--apply must not duplicate forge's hook"
ok "install merges and keeps user keys"
fi

if want "uninstall restores settings"; then
fresh
user_settings
sha=$(sha256sum <"$HOME/.claude/CLAUDE.md")
apply_plain
[ -x "$HOME/.local/bin/forge" ] || fail "--apply must install forge"
rm -f "$CLAUDE_LOG"
"$port" --uninstall >"$tmp/out" 2>&1 || fail "--uninstall exited non-zero: $(cat "$tmp/out")"
cmp "$tmp/user-settings" "$live" || fail "--uninstall must restore the settings: $(cat "$live")"
[ "$(sha256sum <"$HOME/.claude/CLAUDE.md")" = "$sha" ] || fail "--uninstall must not change ~/.claude/CLAUDE.md"
[ ! -e "$HOME/.local/bin/forge" ] && [ ! -e "$HOME/.claude/hooks/forge-guard.sh" ] && [ ! -e "$HOME/.claude/forge/schemas" ] || fail "--uninstall must remove forge's files"
[ ! -e "$manifest" ] || fail "--uninstall must remove the manifest"
grep -qF '"disable","--now","forge-watchdog.timer"' "$SYSTEMCTL_LOG" || fail "--uninstall must disable the timer"
grep -qF '"mcp","remove","context7"' "$CLAUDE_LOG" || fail "--uninstall must remove the mcp servers it added: $(cat "$CLAUDE_LOG")"
fresh
user_settings
apply_plain
jq '.env.AFTER = "kept" | .env.CLAUDE_CODE_PLUGIN_DIRS = "/mine/after"' "$live" >"$tmp/edited" && cp "$tmp/edited" "$live"
"$port" --uninstall >"$tmp/out" 2>&1 || fail "--uninstall after edits exited non-zero: $(cat "$tmp/out")"
jq -e '.env.AFTER == "kept" and .env.CLAUDE_CODE_PLUGIN_DIRS == "/mine/after" and .model == "sonnet"
  and ([.hooks.PreToolUse[].hooks[].command] | any(test("forge-guard")) | not)' "$live" >/dev/null || fail "--uninstall must keep user edits made after install: $(cat "$live")"
fresh
apply_plain
"$port" --uninstall >"$tmp/out" 2>&1 || fail "--uninstall from no prior settings exited non-zero: $(cat "$tmp/out")"
[ ! -e "$live" ] || fail "--uninstall must remove a settings file forge created: $(cat "$live")"
s=0; "$port" --uninstall >"$tmp/out" 2>&1 || s=$?
[ "$s" = 1 ] || fail "--uninstall with nothing installed must exit 1"
ok "uninstall restores settings"
fi

if want "plugins and browser are opt-in"; then
fresh
apply_plain
! jq -e 'has("enabledPlugins") or has("extraKnownMarketplaces")' "$live" >/dev/null || fail "plain --apply must not enable plugins: $(cat "$live")"
! grep -q '^plugin ' "$tmp/out" || fail "plain --apply must not touch plugins: $(cat "$tmp/out")"
grep -q '^mcp jbc' "$tmp/out" && fail "plain --apply must not register jbc: $(cat "$tmp/out")"
fresh
jq 'del(.mcpServers.jbc)' "$cj" >"$HOME/.claude.json"
"$port" --apply --browser >"$tmp/out" 2>&1 || fail "--browser exited non-zero: $(cat "$tmp/out")"
grep -qxF 'mcp jbc: absent' "$tmp/out" || fail "--browser must register jbc: $(cat "$tmp/out")"
ok "plugins and browser are opt-in"
fi

if want "user mcp definition wins"; then
jq '.mcpServers.context7 = {"type":"sse","url":"https://mine.example/mcp"}' "$cj" >"$HOME/.claude.json"
rm -f "$CLAUDE_LOG"
"$port" --apply >"$tmp/out" 2>&1 || fail "--apply exited non-zero: $(cat "$tmp/out")"
grep -q 'keeping your mcp context7' "$tmp/out" || fail "port must say it kept the user's server: $(cat "$tmp/out")"
! grep -qF '"context7"' "$CLAUDE_LOG" || fail "port must not touch the user's server: $(cat "$CLAUDE_LOG")"
! grep -qF '"remove"' "$CLAUDE_LOG" || fail "port must never remove a server it did not add: $(cat "$CLAUDE_LOG")"
ok "user mcp definition wins"
fi

if want "guard fallback source recorded"; then
fresh
apply_plain
[ "$(jq -r .source "$HOME/.local/state/forge/port.json")" = "$(cd "$src" && pwd -P)" ] || fail "port.json must record the source clone: $(cat "$HOME/.local/state/forge/port.json")"
ok "guard fallback source recorded"
fi

if want "macOS installs a launchd agent"; then
cat >"$tmp/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$LAUNCHCTL_LOG"
EOF
chmod +x "$tmp/bin/launchctl"
export LAUNCHCTL_LOG=$tmp/launchctl.log
fresh
FORGE_UNAME=Darwin "$port" --apply >"$tmp/out" 2>&1 || fail "--apply on macOS exited non-zero: $(cat "$tmp/out")"
plist=$HOME/Library/LaunchAgents/com.github.claude-forge.watchdog.plist
[ -f "$plist" ] || fail "--apply on macOS must install the launchd agent: $(cat "$tmp/out")"
grep -qF "$HOME/.local/bin/forge" "$plist" && ! grep -q __HOME__ "$plist" || fail "the plist must name the real home: $(cat "$plist")"
[ ! -e "$HOME/.config/systemd/user/forge-watchdog.timer" ] || fail "macOS must not install systemd units"
grep -q "^bootstrap gui/$(id -u) $plist" "$LAUNCHCTL_LOG" || fail "--apply must load the agent: $(cat "$LAUNCHCTL_LOG")"
FORGE_UNAME=Darwin "$port" --uninstall >"$tmp/out" 2>&1 || fail "--uninstall on macOS exited non-zero: $(cat "$tmp/out")"
[ ! -e "$plist" ] || fail "--uninstall must remove the plist"
grep -q "^bootout gui/$(id -u)/com.github.claude-forge.watchdog" "$LAUNCHCTL_LOG" || fail "--uninstall must unload the agent: $(cat "$LAUNCHCTL_LOG")"
ok "macOS installs a launchd agent"
fi

[ -z "$only" ] || fail "no case $only"
