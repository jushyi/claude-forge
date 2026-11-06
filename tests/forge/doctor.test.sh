#!/usr/bin/env bash
set -euo pipefail
export FORGE_UNAME=Linux
. "$(dirname "$0")/../forge-common.sh"

unset FNM_DIR
db=$tmp/dbin
mkdir -p "$db" "$tmp/elsewhere" "$tmp/run-root/systemd/system"
export FORGE_RUN_ROOT=$tmp/run-root FORGE_PERMISSION_MODE=acceptEdits
printf '#!/bin/sh\nexit 0\n' >"$db/claude"
chmod +x "$db/claude"
cat >"$db/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOC_SYSTEMCTL_LOG"
case "$*" in
  "--user is-enabled --quiet "*) ;;
  *) echo "stub systemctl: unexpected call: $*" >&2; exit 64 ;;
esac
for u in ${DOC_OFF:-}; do [ "$4" != "$u" ] || exit 1; done
EOF
chmod +x "$db/systemctl"
export DOC_SYSTEMCTL_LOG=$tmp/systemctl.log
unset DOC_OFF
path=$db:$tmp/bin:$PATH
h=$tmp/home

repo() {
  mkdir -p "$1/.forge" "$1/.claude"
  git init -q "$1"
  printf '# Testing\n\n## Commands\n- Test: `%s`\n' "${2:-true}" >"$1/.forge/TESTING.md"
  printf '%s\n' "${3:-null}" | jq '. // {}' >"$1/.claude/settings.json"
}
home() {
  rm -rf "$h"
  mkdir -p "$h/Projects" "$h/.cargo/bin" "$h/.local/share/fnm/aliases/default/bin" "$h/.local/state/forge" "$h/.config/forge" "$h/bin"
  printf '#!/usr/bin/env bash\n' >"$h/.cargo/bin/doctor-cargo-tool"
  printf '#!/usr/bin/env bash\n' >"$h/.local/share/fnm/aliases/default/bin/doctor-node-tool"
  printf '#!/usr/bin/env bash\n' >"$h/bin/ok.sh"
  chmod +x "$h/.cargo/bin/doctor-cargo-tool" "$h/.local/share/fnm/aliases/default/bin/doctor-node-tool" "$h/bin/ok.sh"
}
doc() {
  : >"$DOC_SYSTEMCTL_LOG"
  local s=0
  (cd "$tmp/elsewhere" && HOME=$h PATH=$path "$forge" doctor "$@") </dev/null >"$tmp/out" 2>"$tmp/err" || s=$?
  echo $s
}
show() { echo "stdout:"; cat "$tmp/out"; echo "stderr:"; cat "$tmp/err"; }
snap() { (cd "$h" && find . -printf '%p %s %T@\n' | sort); }
tline() { echo "forge doctor: $1/.forge/TESTING.md runs $2, which is not on the watchdog PATH; fix: install $2 or put it on the watchdog PATH"; }
hruns() { echo "forge doctor: $1/.claude/settings.json hook runs $2, which is not on the watchdog PATH; fix: install $2 or fix the hook"; }
hcalls() { echo "forge doctor: $1/.claude/settings.json hook calls $2, which does not exist; fix: create $2 or remove the hook"; }
cline() { echo "forge doctor: $1/.forge/INTEGRATIONS.md names $2, which is missing; fix: create $2"; }
hook() { jq -cn '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [$ARGS.positional[] | {type: "command", command: .}]}], Stop: [{hooks: [{type: "prompt", prompt: "summarize"}]}]}}' --args "$@"; }

if want help; then
"$forge" --help | grep -qE '^  doctor( |$)' || fail "forge --help lists doctor"
(cd "$tmp/elsewhere" && "$forge" doctor --help) >"$tmp/help" 2>&1 || fail "forge doctor --help exits 0 with no .forge in the cwd: $(cat "$tmp/help")"
[ "$(head -1 "$tmp/help" | cut -d' ' -f1-3)" = "Usage: forge doctor" ] || fail "forge doctor --help prints its usage: $(cat "$tmp/help")"
(cd "$tmp/elsewhere" && "$forge" doctor -h) >"$tmp/help" 2>&1 || fail "forge doctor -h exits 0: $(cat "$tmp/help")"
[ "$(head -1 "$tmp/help" | cut -d' ' -f1-3)" = "Usage: forge doctor" ] || fail "forge doctor -h prints its usage: $(cat "$tmp/help")"
ok help
fi

if want usage; then
home
repo "$h/Projects/alpha"
[ "$(doc extra)" = 2 ] || fail "forge doctor with an argument must exit 2: $(show)"
! grep -q 'forge doctor: ok' "$tmp/out" || fail "a usage error runs no check: $(show)"
[ "$(doc --json)" = 2 ] || fail "forge doctor with an option other than --help must exit 2: $(show)"
ok usage
fi

if want clean; then
home
repo "$h/Projects/alpha" 'FOO=1 BAR=x bash -c x && cd . ; true | doctor-cargo-tool || doctor-node-tool --flag && [ -n x ] && command -v ls' \
  "$(hook 'bash ~/bin/ok.sh' 'doctor-cargo-tool ${HOME}/bin/ok.sh' 'bash "$HOME/bin/ok.sh"' "bash $h/bin/ok.sh" 'bash $CLAUDE_PROJECT_DIR/.forge/TESTING.md' 'bash ~/bin/ok.sh; exit 0' 'true > /tmp/doctor-missing-log 2>&1' 'bash "$HOME/bin/my dir/ok.sh" &>/dev/null' 'bash ~/bin/$x.sh')"
cat >>"$h/Projects/alpha/.forge/TESTING.md" <<'EOF'
- All tests: `t={test}; s=${t%%:*}; "tests/$s.test.sh" ${t:${#s}+1}`
- Changed tests: `t={test}; case $t in web/*) cd . && true "${t#web/}" ;; a|b) true ;; *) true -q "$t" ;; esac`
- Setup: `(cd . && true) | sh -c "doctor-missing-x; y" 2>/dev/null # doctor-missing-comment`
EOF
mkdir -p "$h/bin/my dir"
cp "$h/bin/ok.sh" "$h/bin/my dir/ok.sh"
before=$(snap)
[ "$(doc)" = 0 ] || fail "a clean host must exit 0: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "a clean host prints exactly 'forge doctor: ok': $(show)"
grep -qx -- '--user is-enabled --quiet forge-watchdog.timer' "$DOC_SYSTEMCTL_LOG" || fail "doctor checks forge-watchdog.timer with systemctl --user is-enabled --quiet: $(cat "$DOC_SYSTEMCTL_LOG")"
[ "$(snap)" = "$before" ] || fail "doctor changes nothing under HOME: $(diff <(echo "$before") <(snap))"
ok clean
fi

if want units; then
home
repo "$h/Projects/alpha"
[ "$(DOC_OFF=forge-watchdog.timer doc)" = 1 ] || fail "a disabled forge-watchdog.timer must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: forge-watchdog.timer is not enabled; fix: forge watchdog --install" ] || fail "a disabled forge-watchdog.timer prints its line: $(show)"
grep -vxq -- '--user is-enabled --quiet forge-[a-z]*.timer' "$DOC_SYSTEMCTL_LOG" && fail "doctor only queries units, never enables one: $(cat "$DOC_SYSTEMCTL_LOG")"
ok units
fi

if want testing; then
home
a=$h/Projects/alpha
repo "$a" 'FOO=1 doctor-missing-one --x && true; doctor-cargo-tool | doctor-missing-two || doctor-missing-one -y'
cat >>"$a/.forge/TESTING.md" <<'EOF'
- Perf log: `doctor-missing-three && LC_ALL=C doctor-missing-four`
- Quarantine (added 2026-10-01): `(doctor-missing-five && "doctor-missing-six") >/dev/null`

## Gates
- Gate: `doctor-not-a-command-line`
EOF
[ "$(doc)" = 1 ] || fail "a TESTING.md naming missing commands must exit 1: $(show)"
want=$(printf '%s\n' "$(tline "$a" doctor-missing-one)" "$(tline "$a" doctor-missing-two)" "$(tline "$a" doctor-missing-three)" "$(tline "$a" doctor-missing-four)" "$(tline "$a" doctor-missing-five)" "$(tline "$a" doctor-missing-six)" | sort)
[ "$(sort "$tmp/out")" = "$want" ] || fail "each missing first word of a ## Commands line prints once per file, NAME=value words skipped, other sections ignored: $(show)"
! grep -q 'forge doctor: ok' "$tmp/out" || fail "a problem run never prints ok: $(show)"
ok testing
fi

if want values; then
home
a=$h/Projects/alpha
repo "$a" 'FOO=1 true && doctor-cargo-tool'
cat >>"$a/.forge/TESTING.md" <<'EOF2'
- All tests: `doctor-cargo-tool --all && true`
- Changed tests: `doctor-node-tool {files}`
- Perf log: `LC_ALL=C true`
- Memory: `12G` (forge sets `FORGE_TEST_CPUS` to fit it; each tier passes it to cargo as its job count)
- DB floor: `apps/api/test/db-floor-reporter.ts` reports the lowest DB latency
- Setup: `<command installing dependencies>`
- GPU device selection (Vulkan, by default the discrete GPU): `INTERSTELLAR_VK_DEVICE=discrete|integrated|<index>`
EOF2
[ "$(doc)" = 0 ] || fail "Memory, placeholder, prose and file-path lines in ## Commands are not commands and must exit 0: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "only run lines with a non-placeholder command are checked, so the host prints exactly 'forge doctor: ok': $(show)"
ok values
fi

if want none; then
home
a=$h/Projects/alpha
repo "$a"
printf -- '- All tests: none  \n' >>"$a/.forge/TESTING.md"
[ "$(doc)" = 0 ] || fail "a - All tests: none line is not a command and must exit 0: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "a - All tests: none line reports no problem, so the host prints exactly 'forge doctor: ok': $(show)"
ok none
fi

if want ci; then
home
a=$h/Projects/alpha
repo "$a"
ciline="forge doctor: $a/.forge/TESTING.md has no - CI full suite: line but $a has CI; fix: add one naming its full-suite job"
wf() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
[ "$(doc)" = 0 ] || fail "a repo with no workflows dir reports nothing: $(show)"
mkdir -p "$a/.github/workflows"
: >"$a/.github/workflows/perf.yml"
: >"$a/.github/workflows/perf-nightly.yml"
[ "$(doc)" = 0 ] || fail "a repo with only perf*.yml workflows reports nothing: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "only perf*.yml workflows print exactly 'forge doctor: ok': $(show)"
wf "$a/.github/workflows/ci.yml" $'on:\n  push:\n    branches: [main]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make test'
[ "$(doc)" = 0 ] || fail "a push-only workflow is no PR CI and reports nothing: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "a push-only workflow prints exactly 'forge doctor: ok': $(show)"
wf "$a/.github/workflows/release.yml" $'on:\n  release:\n    types: [published]\n  workflow_dispatch:\njobs:\n  build:\n    runs-on: ubuntu-latest'
wf "$a/.github/workflows/nightly.yml" $'on:\n  schedule:\n    - cron: "0 3 * * *"\njobs:\n  full:\n    runs-on: ubuntu-latest'
wf "$a/.github/workflows/push.yml" 'on: [push, workflow_dispatch]'
wf "$a/.github/workflows/bare.yml" 'on: push'
wf "$a/.github/workflows/perms.yml" $'on: push\npermissions:\n  pull-requests: write\njobs:\n  note:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ github.event.pull_request.number }}'
[ "$(doc)" = 0 ] || fail "release, scheduled, dispatch and push-only workflows report nothing: $(show)"
wf "$a/.github/workflows/ci.yml" $'on:\n  push:\n    branches: [main]\n  pull_request:\n    branches: [main]\njobs:\n  test:\n    runs-on: ubuntu-latest'
[ "$(doc)" = 1 ] || fail "a pull_request-triggered workflow with no - CI full suite: line must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "$ciline" ] || fail "a pull_request-triggered workflow with no - CI full suite: line prints its exact line and no ok: $(show)"
printf -- '- CI full suite: `test` job in .github/workflows/ci.yml\n' >>"$a/.forge/TESTING.md"
[ "$(doc)" = 0 ] || fail "a - CI full suite: line clears the CI problem: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "a - CI full suite: line prints exactly 'forge doctor: ok': $(show)"
for form in 'on: [push, pull_request]' 'on: pull_request' $'on:\n  - push\n  - pull_request' $'"on":\n  pull_request_target:\n    types: [opened]' $'on:\n  pull_request: # every PR\njobs:\n  test:\n    runs-on: ubuntu-latest'; do
  rm -rf "$a/.github"
  repo "$a"
  wf "$a/.github/workflows/ci.yml" "$form"
  [ "$(doc)" = 1 ] && [ "$(cat "$tmp/out")" = "$ciline" ] || fail "the trigger form $(printf '%q' "$form") counts as PR CI: $(show)"
done
rm -rf "$a/.github"
repo "$a"
wf "$a/.forgejo/workflows/build.yaml" $'on:\n  push:\n    branches: [main]'
[ "$(doc)" = 0 ] || fail "a push-only .forgejo/workflows/*.yaml workflow reports nothing: $(show)"
wf "$a/.forgejo/workflows/build.yaml" $'on:\n  pull_request:\n  push:\n    branches: [main]'
[ "$(doc)" = 1 ] || fail "a pull_request-triggered .forgejo/workflows/*.yaml workflow counts as CI: $(show)"
[ "$(cat "$tmp/out")" = "$ciline" ] || fail "a .forgejo/workflows/ workflow prints the exact CI line: $(show)"
ok ci
fi

if want hooks; then
home
a=$h/Projects/alpha
repo "$a" true "$(hook 'doctor-missing-hook --flag' 'bash ~/Projects/.atlas/hook.sh' 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/gone.sh" arg' "bash '\${HOME}/gone-too.sh'" 'bash ~/bin/ok.sh' 'bash ~/gone-semi.sh; exit 0' 'bash "$HOME/my dir/gone.sh" > /tmp/doctor-missing-log')"
[ "$(doc)" = 1 ] || fail "a settings.json hook running a missing command or calling a missing script must exit 1: $(show)"
want=$(printf '%s\n' "$(hruns "$a" doctor-missing-hook)" "$(hcalls "$a" "$h/Projects/.atlas/hook.sh")" "$(hcalls "$a" "$a/.claude/hooks/gone.sh")" "$(hcalls "$a" "$h/gone-too.sh")" "$(hcalls "$a" "$h/gone-semi.sh")" "$(hcalls "$a" "$h/my dir/gone.sh")" | sort)
[ "$(sort "$tmp/out")" = "$want" ] || fail "hook problems print one line each with ~, \$HOME, \${HOME} and \$CLAUDE_PROJECT_DIR expanded and quotes stripped: $(show)"
echo '{"hooks": ' >"$a/.claude/settings.json"
[ "$(doc)" = 1 ] || fail "an unparsable settings.json must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: cannot read $a/.claude/settings.json; fix: repair its JSON" ] || fail "an unparsable settings.json prints its line: $(show)"
printf ' \n' >"$a/.claude/settings.json"
[ "$(doc)" = 1 ] || fail "a blank settings.json must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "forge doctor: cannot read $a/.claude/settings.json; fix: repair its JSON" ] || fail "a blank settings.json prints its line: $(show)"
jq -n '{hooks: {Stop: [{hooks: [{type: "command", command: ["doctor-missing-array"]}, {type: "command", command: 7}]}]}}' >"$a/.claude/settings.json"
[ "$(doc)" = 0 ] || fail "only string command handlers are checked: $(show)"
ok hooks
fi

if want repos; then
home
a=$h/Projects/alpha b=$h/Projects/group/beta g=$tmp/elsewhere/gamma
repo "$a" doctor-missing-a
repo "$b" doctor-missing-b
repo "$g" doctor-missing-g
repo "$h/Projects/group/beta/deep" doctor-missing-deep
mkdir -p "$h/Projects/plain" "$tmp/noforge"
printf '%s\n' "$g" "$a" "$tmp/gone" "$tmp/noforge" "$g" >"$h/.local/state/forge/watchdog-roots"
[ "$(doc)" = 1 ] || fail "repos from Projects and watchdog-roots with problems must exit 1: $(show)"
want=$(printf '%s\n' "$(tline "$a" doctor-missing-a)" "$(tline "$b" doctor-missing-b)" "$(tline "$g" doctor-missing-g)" | sort)
[ "$(sort "$tmp/out")" = "$want" ] || fail "repos are \$HOME/Projects/*/ and */*/ holding .forge plus existing watchdog-roots lines holding .forge, each once: $(show)"
ok repos
fi

if want order; then
home
a=$h/Projects/alpha
repo "$a" doctor-missing-tool "$(hook 'doctor-missing-hook')"
want=$(printf '%s\n' "forge doctor: forge-watchdog.timer is not enabled; fix: forge watchdog --install" "$(tline "$a" doctor-missing-tool)" "$(hruns "$a" doctor-missing-hook)")
[ "$(DOC_OFF=forge-watchdog.timer doc)" = 1 ] || fail "problems in every category must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "$want" ] || fail "problems print in the order units, TESTING.md commands, hook commands: $(show)"
ok order
fi

if want two; then
home
a=$h/Projects/alpha b=$h/Projects/beta
repo "$a" doctor-missing-tool "$(hook 'bash ~/Projects/.atlas/hook.sh')"
repo "$b"
want=$(printf '%s\n' "$(tline "$a" doctor-missing-tool)" "$(hcalls "$a" "$h/Projects/.atlas/hook.sh")")
[ "$(doc)" = 1 ] || fail "a missing TESTING.md command and a missing hook script must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "$want" ] || fail "the fixture prints exactly its two problem lines: $(show)"
ok two
fi

if want creds; then
home
a=$h/Projects/alpha b=$h/Projects/beta
repo "$a"
repo "$b"
mkdir -p "$h/.config/have"
: >"$h/.config/have/key"
chmod 000 "$h/.config/have/key"
cat >"$a/.forge/INTEGRATIONS.md" <<'EOF'
# Integrations

- API token: `~/.config/svc/token`, read by the client
- Secret store: `$HOME/.config/have/key` and `$HOME/.secrets/gone.pem`
- PASSWORD file: `${DOC_PASS_FILE:-~/.config/svc/pass}`
- Netrc: `${DOC_NETRC:-~/.netrc}`
- Credential cache: `~/.cache/creds/*.json`, `~/.cache/creds/[ab].json` and `~/.cache/c?.json`
- Token in repo: `config/token.txt`
- Key: `/etc/doctor-missing-key`
- Docs: `~/docs/missing.md`
EOF
cat >"$b/.forge/INTEGRATIONS.md" <<'EOF'
# Integrations

- Token: `~/.config/svc/token`
- Secret: `$HOME/.b-secret`
EOF
s=$(DOC_NETRC=$h/.netrc-env doc)
chmod 600 "$h/.config/have/key"
[ "$s" = 1 ] || fail "missing credential files named in INTEGRATIONS.md must exit 1: $(show)"
want=$(printf '%s\n' "$(cline "$a" "$h/.config/svc/token")" "$(cline "$a" "$h/.secrets/gone.pem")" "$(cline "$a" "$h/.config/svc/pass")" "$(cline "$a" "$h/.netrc-env")" "$(cline "$b" "$h/.b-secret")" | sort)
[ "$(sort "$tmp/out")" = "$want" ] || fail "each missing ~/, \$HOME/ or \${NAME:-default} path on a key/token/secret/credential/password/netrc line prints once per run; globs, relative paths and other lines are skipped; an existing unreadable file is fine: $(show)"
ok creds
fi

if want order-all; then
home
a=$h/Projects/alpha b=$h/Projects/beta
repo "$a" doctor-missing-tool "$(hook 'doctor-missing-hook')"
printf -- '- Token: `~/.doctor-token`\n' >"$a/.forge/INTEGRATIONS.md"
want=$(printf '%s\n' "forge doctor: forge-watchdog.timer is not enabled; fix: forge watchdog --install" "$(tline "$a" doctor-missing-tool)" "$(hruns "$a" doctor-missing-hook)" "$(cline "$a" "$h/.doctor-token")")
[ "$(DOC_OFF=forge-watchdog.timer doc)" = 1 ] || fail "problems in all four categories must exit 1: $(show)"
[ "$(cat "$tmp/out")" = "$want" ] || fail "problems print in the order units, TESTING.md commands, hook commands, credentials: $(show)"
ok order-all
fi

if want holders; then
home
a=$h/Projects/alpha n=$h/Projects/plain
repo "$a"
mkdir -p "$n/.forge"
printf '# Testing\n\n## Commands\n- Test: `true`\n' >"$n/.forge/TESTING.md"
gl=$a/.git/forge.lock
removed() { echo "forge doctor: removed dead lock holder $1 (pid $2)"; }
: >"$gl"
echo '99999999 x since t' >"$gl.holder"
[ "$(doc)" = 0 ] || fail "a dead lock holder with a free lock and nothing else wrong exits 0: $(show)"
[ "$(cat "$tmp/out")" = "$(printf '%s\n' "$(removed "$gl.holder" 99999999)" "forge doctor: ok")" ] || fail "a dead lock holder in the git common dir prints its removal line, then 'forge doctor: ok': $(show)"
[ ! -e "$gl.holder" ] || fail "a dead lock holder with a free lock is removed: $(show)"
[ -e "$gl" ] || fail "the lock file itself stays: $(show)"
echo 'abc x since t' >"$gl.holder"
[ "$(doc)" = 0 ] || fail "a non-numeric holder with a free lock exits 0: $(show)"
[ "$(cat "$tmp/out")" = "$(printf '%s\n' "$(removed "$gl.holder" abc)" "forge doctor: ok")" ] || fail "a non-numeric first field counts as dead: $(show)"
[ ! -e "$gl.holder" ] || fail "a non-numeric holder is removed: $(show)"
echo "$$ x since t" >"$gl.holder"
doc >/dev/null
[ "$(cat "$tmp/out")" = "forge doctor: ok" ] || fail "a live-PID holder prints no removal line: $(show)"
! grep -qF "$gl.holder" "$tmp/err" || fail "a live-PID holder stays silently: $(show)"
[ -e "$gl.holder" ] || fail "a live-PID holder stays: $(show)"
echo '99999999 x since t' >"$gl.holder"
exec 7<"$gl"
flock -n 7 || fail "the test shell takes the lock"
doc >/dev/null
exec 7<&-
[ -e "$gl.holder" ] || fail "a dead holder whose lock is held stays: $(show)"
! grep -q 'removed dead lock holder' "$tmp/out" || fail "a dead holder whose lock is held prints no removal line: $(show)"
grep -q '^forge: warning: ' "$tmp/err" || fail "a dead holder whose lock is held prints a forge: warning line on stderr: $(show)"
rm -f "$gl"
doc >/dev/null
[ -e "$gl.holder" ] || fail "a dead holder whose lock file is missing stays: $(show)"
[ ! -e "$gl" ] || fail "doctor never creates a missing lock file: $(show)"
! grep -q 'removed dead lock holder' "$tmp/out" || fail "a dead holder whose lock file is missing prints no removal line: $(show)"
grep -q '^forge: warning: ' "$tmp/err" || fail "a dead holder whose lock file is missing prints a forge: warning line on stderr: $(show)"
rm -f "$gl.holder"
nl=$n/.forge/forge.lock
: >"$nl"
echo '99999999 x since t' >"$nl.holder"
[ "$(doc)" = 0 ] || fail "a dead .forge/ holder in a non-git repo exits 0: $(show)"
[ "$(cat "$tmp/out")" = "$(printf '%s\n' "$(removed "$nl.holder" 99999999)" "forge doctor: ok")" ] || fail "a .forge/forge.lock.holder in a non-git repo is swept: $(show)"
[ ! -e "$nl.holder" ] || fail "a dead .forge/ holder is removed: $(show)"
fl=$a/.git/forge-land.lock
: >"$fl"
echo '99999999 x since t' >"$fl.holder"
[ "$(DOC_OFF=forge-watchdog.timer doc)" = 1 ] || fail "a removal beside a real problem still exits 1: $(show)"
[ "$(cat "$tmp/out")" = "$(printf '%s\n' "forge doctor: forge-watchdog.timer is not enabled; fix: forge watchdog --install" "$(removed "$fl.holder" 99999999)")" ] || fail "a removal beside a real problem prints the problem, then the removal line, and no ok: $(show)"
[ ! -e "$fl.holder" ] || fail "a dead holder beside a real problem is removed: $(show)"
ok holders
fi

finish

if want bypass-note; then
  note=$(HOME=$tmp/note-home PATH=$path FORGE_PERMISSION_MODE=bypassPermissions "$forge" doctor 2>&1 | grep -c 'note: background sessions need' || true)
  [ "$note" = 1 ] || fail "doctor must note the unaccepted bypass warning"
  mkdir -p "$tmp/note-home/.claude"
  echo '{"skipDangerousModePermissionPrompt": true}' >"$tmp/note-home/.claude/settings.json"
  note=$(HOME=$tmp/note-home PATH=$path FORGE_PERMISSION_MODE=bypassPermissions "$forge" doctor 2>&1 | grep -c 'note: background sessions need' || true)
  [ "$note" = 0 ] || fail "doctor must not note an accepted bypass warning"
  ok bypass-note
fi
