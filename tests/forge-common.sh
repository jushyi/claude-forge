set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fx=$root/tests/fixtures/forge
forge=$root/bin/forge
forge_unset_host_env() {
  local f l
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}/forge/env" "${FORGE_ENV:-}" "${FORGE_HOST_ENV:-}"; do
    [ -n "$f" ] && [ "$f" != /dev/null ] && [ -f "$f" ] && [ -r "$f" ] || continue
    while IFS= read -r l || [ -n "$l" ]; do
      if [[ $l =~ ^(FORGE_[A-Z0-9_]+)= ]] && [ "${BASH_REMATCH[1]}" != FORGE_ENV ]; then unset "${BASH_REMATCH[1]}"; fi
    done <"$f"
  done
  unset FORGE_HOST_ENV FORGE_ROOT FORGE_PHASE FORGE_CONCURRENCY FORGE_TEST_RUNS FORGE_TEST_SLOT_HELD FORGE_TEST_SLOT_WAIT FORGE_TEST_CPUS FORGE_TEST_LOG_DIR
}
forge_unset_host_env
export FORGE_TEMPLATES=$root/templates FORGE_SCHEMAS=$root/schemas LC_ALL=C
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export XDG_RUNTIME_DIR=$tmp/run XDG_STATE_HOME=$tmp/state FORGE_ENV=/dev/null
export FORGE_PROC_ROOT=$tmp/proc FORGE_SYS_ROOT=$tmp/sys
mkdir -p "$FORGE_PROC_ROOT" "$FORGE_SYS_ROOT" && printf 'MemTotal: 33554432 kB\nMemAvailable: 16777216 kB\n' >"$FORGE_PROC_ROOT/meminfo" && echo '0.00 0.00 0.00 1/100 1' >"$FORGE_PROC_ROOT/loadavg"
mkdir -p "$FORGE_PROC_ROOT/pressure" && printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"$FORGE_PROC_ROOT/pressure/cpu"

fail() { echo "forge: FAIL $*" >&2; exit 1; }
only=${1:-}
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() { local c; [ -z "$only" ] && return 0; for c; do [ "$only" = "$c" ] && return 0; done; return 1; }
ok() { echo "forge $1: ok"; [ "$1" != "$only" ] || exit 0; }
project() {
  local s
  s=$XDG_STATE_HOME/forge/$(basename "$1")
  rm -rf "$s"
  cp -r "$fx/project" "$1"
  mkdir -p "$s"
  cp -r "$fx/state/." "$s"
  (cd "$1" && pwd) >"$s/root"
}
fresh() { rm -rf "$tmp/p"; project "$tmp/p"; cd "$tmp/p"; }
code() { local s=0; "$@" >"$tmp/out" 2>&1 || s=$?; echo $s; }
json() { jq -cS . "$@"; }
finish() { [ -z "$only" ] || fail "no case $only"; }

stub_gcloud() {
  mkdir -p "$tmp/gbin"
  cat >"$tmp/gbin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GCLOUD_LOG"
if [ -n "${GCLOUD_FAIL:-}" ] && [[ "$*" == *"$GCLOUD_FAIL"* ]]; then
  echo "ERROR: (gcloud) stub denied: $*" >&2
  exit 1
fi
case "${1:-} ${2:-} ${3:-}" in
  "billing budgets list")
    [ $# -eq 5 ] && [[ $4 == --billing-account=* ]] && [ "$5" = --format=json ] || { echo "stub gcloud: bad args: $*" >&2; exit 64; }
    cat "$GCLOUD_FX/budgets-${4#--billing-account=}.json" ;;
  "projects describe "*)
    [ $# -eq 4 ] && [ "$4" = "--format=value(projectNumber)" ] || { echo "stub gcloud: bad args: $*" >&2; exit 64; }
    jq -r --arg p "$3" '.[$p] // error("stub gcloud: no project \($p)")' "$GCLOUD_FX/projects.json" ;;
  "beta quotas preferences")
    [ $# -eq 7 ] && [ "$4" = list ] && [[ $5 == --service=* ]] && [[ $6 == --project=* ]] && [ "$7" = --format=json ] || { echo "stub gcloud: bad args: $*" >&2; exit 64; }
    jq --arg p "${6#--project=}" '[.[] | select(.name | startswith("projects/\($p)/"))]' "$GCLOUD_FX/quotas-${5#--service=}.json" ;;
  *) echo "stub gcloud: unexpected call: $*" >&2; exit 64 ;;
esac
STUB
  chmod +x "$tmp/gbin/gcloud"
  export GCLOUD_LOG=$tmp/gcloud.log GCLOUD_FX=$tmp/gfx
}

stub_map_claude() {
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=${!#}
focus=$(sed -n 's/^Focus: //p' <<<"$prompt")
{ echo "cwd: $PWD"; echo "args: ${*:1:$#-1}"; echo "$prompt"; } >"$(mktemp "$STUB_LOG/call.XXXXXX")"
[ "${focus:-concerns}" != "${STUB_FAIL:-}" ] || { echo "stub failed" >&2; exit 1; }
cp "$STUB_FX/${focus:-concerns}.json" "$(sed -n 's/^Output: //p' <<<"$prompt")"
STUB
  chmod +x "$tmp/bin/claude"
  export STUB_FX=$fx/map STUB_LOG=$tmp/calls
  stubbed() { rm -rf "$STUB_LOG"; mkdir -p "$STUB_LOG"; PATH=$tmp/bin:$PATH "$@"; }
  calls() { cat "$STUB_LOG"/call.*; }
}

stub_run_claude() {
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) [ -z "${CLAUDE_STDIN:-}" ] || cat >>"$CLAUDE_STDIN"
    n= p=; for a; do [ "$p" != -n ] || n=$a; p=$a; done
    [ -z "${CLAUDE_BG_FAIL:-}" ] || [ "$n" != "$CLAUDE_BG_FAIL" ] || { printf '%s\n' "${CLAUDE_BG_ERR:-}" >&2; exit 1; }
    printf 'backgrounded · %s · %s\n' "$(printf %s "$3" | md5sum | cut -c1-8)" "$3" ;;
  agents) cat "$CLAUDE_AGENTS" ;;
  rm) [ -z "${CLAUDE_RM_WT:-}" ] || [ ! -d "$CLAUDE_RM_WT" ] || echo "saw-worktree $CLAUDE_RM_WT" >>"$CLAUDE_LOG"
    [ -z "${CLAUDE_RM_LOCK:-}" ] || ! flock -n "$CLAUDE_RM_LOCK" true || echo "unlocked $2" >>"$CLAUDE_LOG"
    [ "$2" != "${CLAUDE_RM_FAIL:-}" ] || { echo "Error: cannot remove $2" >&2; exit 1; }
    [ "$2" = "${CLAUDE_RM_KEEP:-}" ] || [ ! -f "$CLAUDE_AGENTS" ] ||
      { jq --arg i "$2" 'map(select(.id != $i))' "$CLAUDE_AGENTS" >"$CLAUDE_AGENTS.rm" && mv "$CLAUDE_AGENTS.rm" "$CLAUDE_AGENTS"; } ;;
esac
EOF
  cat >"$tmp/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != -- ] || shift
printf '%s | %s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF
  chmod +x "$tmp/bin/claude" "$tmp/bin/notify-send"
  stub_systemd "$tmp/bin"
  export PATH=$tmp/bin:$PATH CLAUDE_LOG=$tmp/claude.log CLAUDE_AGENTS=$tmp/agents.json NOTIFY_LOG=$tmp/notify.log
  claude_home
}

claude_home() {
  export HOME=$tmp/home
  unset CLAUDE_CONFIG_DIR
  mkdir -p "$HOME"
  [ -f "$HOME/.gitconfig" ] || printf '[user]\n\tname = forge\n\temail = forge@example.com\n' >"$HOME/.gitconfig"
}

stub_systemd() {
  cat >"$1/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SYSTEMD_LOG"
EOF
  cat >"$1/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$SYSTEMD_LOG"
for a; do shift; [ "$a" != -- ] || exec "$@"; done
[ -z "${SYSTEMD_RUN_FAIL:-}" ] || { echo "$SYSTEMD_RUN_FAIL" >&2; exit 1; }
EOF
  chmod +x "$1/systemctl" "$1/systemd-run"
  export SYSTEMD_LOG=$tmp/systemd.log
}

stub_codex() {
  home=$tmp/home plug=$tmp/home/.claude/plugins/cache/openai-codex/codex/9.9.9
  mkdir -p "$plug/scripts"
  cat >"$plug/scripts/codex-companion.mjs" <<'EOF'
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
const argv = process.argv.slice(2);
const pf = argv.indexOf("--prompt-file");
const prompt = argv.slice(1).join(" ") + (pf > 0 && argv[pf + 1] ? " " + readFileSync(argv[pf + 1], "utf8") : "");
appendFileSync(process.env.CODEX_LOG, JSON.stringify({ argv, prompt, cwd: process.cwd(), data: process.env.CLAUDE_PLUGIN_DATA ?? null }) + "\n");
const key = { setup: "SETUP", "adversarial-review": "REVIEW", task: "TASK" }[argv[0]];
if (!key) {
  process.stderr.write(`stub companion: unknown command ${argv[0]}\n`);
  process.exit(9);
}
if (key === "TASK" && process.env.CODEX_AUDIT !== undefined) {
  const out = argv.slice(1).join(" ").match(/\/[^\s`'"]*\/audit\.json/);
  if (out) writeFileSync(out[0], process.env.CODEX_AUDIT);
}
const ready = JSON.stringify({ codex: { available: true }, auth: { loggedIn: true } });
const out = process.env[`CODEX_${key}`] ?? (key === "SETUP" ? ready : "");
if (out) process.stdout.write(out + "\n");
process.exitCode = Number(process.env[`CODEX_${key}_EXIT`] ?? 0);
EOF
  echo 'import { readFileSync } from "node:fs"; readFileSync(0);' >"$plug/scripts/session-lifecycle-hook.mjs"
  export CODEX_LOG=$tmp/codex.log DETECT_LOG=$tmp/detect.log
}

installed() {
  mkdir -p "$home/.claude/plugins"
  jq -n --arg p "$1" --arg i "${2:-}" '{version: 2, plugins: ({"codex@openai-codex": [{scope: "user", installPath: $p, version: "9.9.9"}]}
    + if $i == "" then {} else {"impeccable@impeccable": [{scope: "user", installPath: $i, version: "9.9.9"}]} end)}' \
    >"$home/.claude/plugins/installed_plugins.json"
}

stub_impeccable() {
  home=$tmp/home
  imp=$home/.claude/plugins/cache/impeccable/impeccable/9.9.9
  isk=$imp/skills/impeccable
  mkdir -p "$isk/scripts" "$isk/reference"
  echo "# impeccable" >"$isk/SKILL.md"
  echo "# audit" >"$isk/reference/audit.md"
  cat >"$isk/scripts/impeccable" <<'EOF'
#!/usr/bin/env bash
case $1 in
  context) echo '{}' ;;
  detect)
    files=()
    for a in "${@:2}"; do [[ $a == --* ]] || files+=("$(realpath -m -- "$a")"); done
    jq -cn --arg cwd "$(pwd -P)" --argjson files "$(jq -cn '$ARGS.positional' --args "${files[@]}")" \
      '{argv: $ARGS.positional, files: $files, cwd: $cwd}' --args -- "$@" >>"$DETECT_LOG"
    [ -z "${DETECT_OUT:-}" ] || printf '%s\n' "$DETECT_OUT"
    exit "${DETECT_EXIT:-0}" ;;
  *) echo "impeccable: unknown verb $1" >&2; exit 64 ;;
esac
EOF
  chmod +x "$isk/scripts/impeccable"
}

stub_pr() {
  mkdir -p "$tmp/pr/bin" "$tmp/pr/home/.config/forgejo"
  cat >"$tmp/pr/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "pr view" ]; then
  n=$(grep -cx -- -- "$GH_VIEW_LOG" || true)
  { printf '%s\n' "$@"; echo --; } >>"$GH_VIEW_LOG"
  [ -z "${GH_VIEW_FAIL:-}" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of 12. (repository.pullRequest)" >&2; exit 1; }
  [ "$n" -ge "${GH_VIEW_FAILS:-0}" ] || { printf '%s\n' "$GH_VIEW_ERR" >&2; exit 1; }
  [ -z "${GH_STATE_ERR:-}" ] || [ "${5:-}" != state ] || { printf '%s\n' "$GH_STATE_ERR" >&2; exit 1; }
  v=$GH_VIEW
  [ "$n" = 0 ] || [ -z "${GH_VIEW2:-}" ] || v=$GH_VIEW2
  [ "$n" -lt 2 ] || [ -z "${GH_VIEW3:-}" ] || v=$GH_VIEW3
  q= prev=
  for a; do
    case $prev in --jq | -q) q=$a ;; esac
    case $a in --jq=*) q=${a#--jq=} ;; esac
    prev=$a
  done
  if [ -n "$q" ]; then jq -r "$q" <<<"$v"; else printf '%s\n' "$v"; fi
  exit
fi
n=$(grep -cx merge "$GH_LOG" || true)
{ printf '%s\n' "$@"; echo --; } >>"$GH_LOG"
if [ "${1:-} ${2:-}" = "pr merge" ] && [ "$n" -lt "${GH_MERGE_FAILS:-0}" ]; then
  printf '%s\n' "$GH_MERGE_ERR" >&2
  exit 1
fi
if [ "${1:-} ${2:-}" = "pr create" ]; then
  echo "Warning: 1 uncommitted change" >&2
  echo https://github.com/octo/forge/pull/12
fi
EOF
  cat >"$tmp/pr/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -G ] || exit 255
h=${!#}
[ "$h" != github.com-forge ] || h=github.com
printf 'user git\nhostname %s\nport 22\n' "$h"
EOF
  cat >"$tmp/pr/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${CURL_SECRET:-}" ] && printf '%s\n' "$@" | grep -qF "$CURL_SECRET"; then echo "curl stub: the token is on the command line" >&2; exit 99; fi
method= data= hasdata= out= wfmt= url= fail= failbody= headers=()
src() { local f=${1#@}; [ "$f" != - ] || f=/dev/stdin; cat "$f"; }
hdr() { if [[ $1 == @* ]]; then while IFS= read -r l; do [ -z "$l" ] || headers+=("$l"); done < <(src "$1"); else headers+=("$1"); fi; }
dat() { hasdata=1; if [[ $1 == @* ]]; then data=$(src "$1"); else data=$1; fi; }
conf() {
  local l
  while IFS= read -r l; do
    if [[ $l =~ ^[[:space:]]*(-H|--header|header)[[:space:]=]+\"(.*)\"[[:space:]]*$ ]]; then headers+=("${BASH_REMATCH[2]}")
    elif [[ $l =~ ^[[:space:]]*(--url|url)[[:space:]=]+\"(.*)\"[[:space:]]*$ ]]; then url=${BASH_REMATCH[2]}
    fi
  done < <(src "@$1")
}
while [ $# -gt 0 ]; do
  case $1 in
    -X | --request) method=$2; shift ;;
    -H | --header) hdr "$2"; shift ;;
    -d | --data | --data-binary | --data-raw) dat "$2"; shift ;;
    --json) dat "$2"; headers+=("Content-Type: application/json"); shift ;;
    -o | --output) out=$2; shift ;;
    -w | --write-out) wfmt=$2; shift ;;
    --url) url=$2; shift ;;
    -K | --config) conf "$2"; shift ;;
    -m | --max-time | --connect-timeout | --retry | -u | --user | -A | --user-agent) shift ;;
    --fail | -f) fail=1 ;;
    --fail-with-body) failbody=1 ;;
    --*) ;;
    -*) [[ $1 != *f* ]] || fail=1 ;;
    *) url=$1 ;;
  esac
  shift
done
[ -n "$method" ] || { [ -n "$hasdata" ] && method=POST || method=GET; }
code=${CURL_CODE:-200} body=${CURL_BODY:-} seq=
case $method in POST) seq=${CURL_POSTS:-} ;; GET) seq=${CURL_GETS:-} ;; esac
if [ -n "$seq" ]; then
  n=$(jq -r .method "$CURL_LOG" | grep -cx "$method" || true)
  r=$(sed -n "$((n + 1))p" <<<"$seq")
  [ -n "$r" ] || r=$(tail -n 1 <<<"$seq")
  code=${r%% *} body=${r#* }
fi
jq -cn --arg m "$method" --arg u "$url" --arg d "$data" '{method: $m, url: $u, data: $d, headers: $ARGS.positional}' --args "${headers[@]}" >>"$CURL_LOG"
if [ -n "$fail" ] && [ "$code" -ge 400 ]; then echo "curl: (22) The requested URL returned error: $code" >&2; exit 22; fi
if [ -n "$out" ] && [ "$out" != - ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
if [ -n "$wfmt" ]; then w=${wfmt//'%{http_code}'/$code}; w=${w//'%{response_code}'/$code}; printf '%b' "$w"; fi
[ -z "$failbody" ] || [ "$code" -lt 400 ] || exit 22
EOF
  mkdir -p "$tmp/pr/sleep"
  cat >"$tmp/pr/sleep/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SLEEP_LOG"
EOF
  cat >"$tmp/pr/ready" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$READY_LOG"
pwd -P >>"$READY_LOG"
echo "ready says: head $1 is not deployable"
echo "ready warns on stderr" >&2
exit "${READY_EXIT:-0}"
EOF
  chmod +x "$tmp/pr/bin/gh" "$tmp/pr/bin/ssh" "$tmp/pr/bin/curl" "$tmp/pr/sleep/sleep" "$tmp/pr/ready"
  export GH_LOG=$tmp/pr/gh.log GH_VIEW_LOG=$tmp/pr/gh-view.log CURL_LOG=$tmp/pr/curl.log READY_LOG=$tmp/pr/ready.log SLEEP_LOG=$tmp/pr/sleep.log
}
