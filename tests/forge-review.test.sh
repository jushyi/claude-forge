#!/usr/bin/env bash
set -euo pipefail
export FORGE_UNAME=Linux
root=$(cd "$(dirname "$0")/.." && pwd)
fx=$root/tests/fixtures/forge
forge=$root/bin/forge
export FORGE_TEMPLATES=$root/templates FORGE_SCHEMAS=$root/schemas LC_ALL=C
unset FORGE_ROOT FORGE_CONCURRENCY
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state
st=$XDG_STATE_HOME/forge/p fxpd=$fx/state/phases/02-intake-form

only=${1:-}
fail() { echo "forge-review: FAIL $*" >&2; exit 1; }
ok() { echo "forge-review $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

mkdir -p "$tmp/nbin"
cat >"$tmp/nbin/notify-send" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\t' "$@"; echo; } >>"$NOTIFY_LOG"
exit "${NOTIFY_EXIT:-0}"
EOF
cat >"$tmp/nbin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$LOGIN_LOG"
echo "Failed to stop forge-codex-login.service: Unit forge-codex-login.service not loaded." >&2
exit 5
EOF
cat >"$tmp/nbin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$LOGIN_LOG"
exit "${SYSTEMD_RUN_EXIT:-0}"
EOF
chmod +x "$tmp/nbin/notify-send" "$tmp/nbin/systemctl" "$tmp/nbin/systemd-run"
export PATH=$tmp/nbin:$PATH NOTIFY_LOG=$tmp/notify.log LOGIN_LOG=$tmp/login.log

home=$tmp/home plug=$tmp/home/.claude/plugins/cache/openai-codex/codex/9.9.9
data=$home/.claude/plugins/data/codex-openai-codex
mkdir -p "$plug/scripts/lib"
cat >"$plug/scripts/lib/broker-lifecycle.mjs" <<'EOF'
import { existsSync, readFileSync } from "node:fs";
export const brokerFile = (cwd) => `${process.env.CLAUDE_PLUGIN_DATA}/brokers/${encodeURIComponent(cwd)}`;
export function loadBrokerSession(cwd) {
  return existsSync(brokerFile(cwd)) ? JSON.parse(readFileSync(brokerFile(cwd), "utf8")) : null;
}
EOF
cat >"$plug/scripts/codex-companion.mjs" <<'EOF'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { brokerFile } from "./lib/broker-lifecycle.mjs";
mkdirSync(`${process.env.CLAUDE_PLUGIN_DATA}/brokers`, { recursive: true });
if (!existsSync(brokerFile(process.cwd()))) writeFileSync(brokerFile(process.cwd()), JSON.stringify({ endpoint: `unix:/${Math.random()}` }));
const argv = process.argv.slice(2);
appendFileSync(process.env.CODEX_LOG, JSON.stringify({ argv, cwd: process.cwd(), data: process.env.CLAUDE_PLUGIN_DATA ?? null }) + "\n");
const key = { setup: "SETUP", "adversarial-review": "REVIEW" }[argv[0]];
const ready = JSON.stringify({ codex: { available: true }, auth: { loggedIn: true } });
const file = process.env[`CODEX_${key}_FILE`];
const out = file ? readFileSync(file, "utf8").trimEnd() : process.env[`CODEX_${key}`] ?? (key === "SETUP" ? ready : "");
if (out) process.stdout.write(out + "\n");
if (key === "REVIEW" && process.env.CODEX_REVIEW_JOB_PATH) writeFileSync(process.env.CODEX_REVIEW_JOB_PATH, process.env.CODEX_REVIEW_JOB);
if (process.env[`CODEX_${key}_STDERR`]) process.stderr.write(process.env[`CODEX_${key}_STDERR`]);
process.exitCode = Number(process.env[`CODEX_${key}_EXIT`] ?? 0);
EOF
cat >"$plug/scripts/session-lifecycle-hook.mjs" <<'EOF'
import { appendFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { brokerFile } from "./lib/broker-lifecycle.mjs";
const input = readFileSync(0, "utf8");
const cwd = JSON.parse(input).cwd;
rmSync(brokerFile(process.cwd()), { force: true });
appendFileSync(process.env.HOOK_LOG, JSON.stringify({ argv: process.argv.slice(2), cwd, exists: existsSync(cwd), pwd: process.cwd(),
  data: process.env.CLAUDE_PLUGIN_DATA ?? null, session: process.env.CODEX_COMPANION_SESSION_ID ?? null,
  endpoint: process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT ?? null }) + "\n");
process.exitCode = Number(process.env.HOOK_EXIT ?? 0);
EOF
mkdir -p "$home/.claude/plugins"
jq -n --arg p "$plug" '{version: 2, plugins: {"codex@openai-codex": [{scope: "user", installPath: $p, version: "9.9.9"}]}}' >"$home/.claude/plugins/installed_plugins.json"

export CODEX_LOG=$tmp/codex.log HOOK_LOG=$tmp/hook.log CODEX_COMPANION_SESSION_ID=parent-session CODEX_COMPANION_APP_SERVER_ENDPOINT=unix:/nowhere
run() { local s=0; rm -f "$CODEX_LOG" "$HOOK_LOG"; HOME=$home "$forge" "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
payload() {
  jq -cn --argjson findings "$1" '{review: "Adversarial Review", target: {mode: "branch", label: "branch diff"}, threadId: "t1",
    codex: {status: 0, stderr: "", stdout: "", reasoning: null},
    result: {verdict: "needs-attention", summary: "Issues found", findings: $findings, next_steps: []},
    rawOutput: "{}", parseError: null, reasoningSummary: null}'
}
finding() {
  jq -cn --arg s "$1" --arg f "$2" --argjson l "$3" '{severity: $s, title: "T", body: "B", file: $f, line_start: $l, line_end: $l, confidence: 0.8, recommendation: "Fix it."}'
}
hooks() { jq -s "$@" "$HOOK_LOG"; }

cp -r "$fx/project" "$tmp/p" && mkdir -p "$st" && cp -r "$fx/state/." "$st" && echo "$tmp/p" >"$st/root" && cd "$tmp/p"
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
git worktree add -q -b forge/crm-intake .claude/worktrees/crm-intake
p=$PWD fw=$(cd .claude/worktrees/crm-intake && pwd -P)
pd=$st/phases/02-intake-form fr=$st/features/crm-intake
fgit=$(git -C "$fw" rev-parse --absolute-git-dir)
frun() { (cd "$fw" && FORGE_ROOT=$p run review crm/intake "$@"); }
found="[$(finding critical src/intake.ts 3),$(finding high src/intake.ts 7),$(finding medium src/form.ts 12),$(finding low src/form.ts 20)]"
credits="Your workspace is out of credits. Add credits to continue."

if want review-cause; then
  [ "$(CODEX_REVIEW=$(payload "$found" | jq -c --arg e "$credits" '.parseError = $e | .result = null | .codex.status = 1') CODEX_REVIEW_EXIT=1 frun)" = 3 ] \
    || fail "a failed Codex turn must exit 3: $(cat "$tmp/out" "$tmp/err")"
  [ "$(head -n1 "$tmp/out")" = "codex: adversarial-review exited 1: $credits" ] || fail "the codex: line carries the parseError: $(cat "$tmp/out")"
  grep -qF "$credits" "$fgit/forge-codex.log" || fail "the worktree's git dir holds the companion's stdout: $(cat "$fgit/forge-codex.log" 2>&1)"
  [ "$(CODEX_REVIEW= CODEX_REVIEW_STDERR=$'warming up\nfatal: bad revision forge/nope\n\n' CODEX_REVIEW_EXIT=1 frun)" = 3 ] || fail "a companion crash must exit 3"
  [ "$(head -n1 "$tmp/out")" = "codex: adversarial-review exited 1: fatal: bad revision forge/nope" ] || fail "the codex: line carries the last stderr line: $(cat "$tmp/out")"
  grep -q 'warming up' "$fgit/forge-codex.log" || fail "the log holds all of stderr: $(cat "$fgit/forge-codex.log" 2>&1)"
  [ "$(CODEX_REVIEW=$(payload '[]' | jq -c '.result = null | .codex.stderr = "turn aborted"') CODEX_REVIEW_STDERR=other CODEX_REVIEW_EXIT=2 frun)" = 3 ] || fail "an aborted turn must exit 3"
  [ "$(head -n1 "$tmp/out")" = "codex: adversarial-review exited 2: turn aborted" ] || fail "the codex: line carries .codex.stderr before stderr: $(cat "$tmp/out")"
  long=$(printf 'line one\nline two %0300d' 0)
  [ "$(CODEX_REVIEW=$(payload '[]' | jq -c --arg e "$long" '.parseError = $e') CODEX_REVIEW_EXIT=1 frun)" = 3 ] || fail "a long parseError must exit 3"
  want="codex: adversarial-review exited 1: $(tr '\n' ' ' <<<"$long" | cut -c1-240)"
  [ "$(head -n1 "$tmp/out")" = "$want" ] || fail "the cause is flattened and cut to 240 characters: $(head -n1 "$tmp/out")"
  [ "$(cd "$fw" && CODEX_REVIEW= CODEX_REVIEW_STDERR='fatal: no main' CODEX_REVIEW_EXIT=1 FORGE_ROOT=$p run review crm/intake)" = 3 ] || fail "a failed feature review must exit 3"
  [ "$(head -n1 "$tmp/out")" = "codex: adversarial-review exited 1: fatal: no main" ] || fail "a feature review's codex: line: $(cat "$tmp/out")"
  grep -q 'fatal: no main' "$fgit/forge-codex.log" || fail "a feature review logs to its worktree's git dir"
  ok review-cause
fi

if want teardown; then
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a review must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(hooks -c 'map(.cwd)')" = "$(jq -cn --arg w "$fw" '[$w, $w]')" ] || fail "setup and review each stop the worktree's broker: $(cat "$HOOK_LOG")"
  hooks -e --arg d "$data" 'all(.argv == ["SessionEnd"] and .pwd == .cwd and .data == $d and .session == null and .endpoint == null)' >/dev/null \
    || fail "the teardown runs SessionEnd in the worktree with CLAUDE_PLUGIN_DATA and no session or broker env: $(cat "$HOOK_LOG")"
  [ "$(CODEX_REVIEW=$(payload "$found") HOOK_EXIT=1 frun)" = 0 ] || fail "a failed teardown leaves the review's exit: $(cat "$tmp/out" "$tmp/err")"
  grep -q teardown "$tmp/err" || fail "a failed teardown warns on stderr: $(cat "$tmp/err")"
  [ "$(jq '.findings | length' $fr/review.json)" = 4 ] || fail "a failed teardown keeps the findings: $(cat $fr/review.json)"
  theirs=$data/brokers/$(jq -rn --arg c "$fw" '$c | @uri')
  mkdir -p "$data/brokers" && echo '{"endpoint": "unix:/theirs"}' >"$theirs"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a review beside a running broker must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$HOOK_LOG" ] || fail "a broker forge did not start is left running: $(cat "$HOOK_LOG")"
  [ "$(jq -r .endpoint "$theirs")" = unix:/theirs ] || fail "the running broker's record is kept"
  rm "$theirs"
  ok teardown
fi

jobs=$data/state/ws-1/jobs
job() {
  mkdir -p "$jobs"
  jq -n --arg id "$1" --arg s "$2" --arg t "$3" --arg e "$4" --arg l "$jobs/$1.log" \
    '{id: $id, kind: "adversarial-review", status: $s, completedAt: $t, logFile: $l, result: {parseError: (if $e == "" then null else $e end)}}' >"$jobs/$1.json"
}
now() { date -u -d "${1:-now}" +%FT%T.000Z; }
if want readiness; then
  job a failed "$(now '-2 min')" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a recent out-of-credits job must fail readiness: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "codex: " "$tmp/out" && grep -qF "$credits" "$tmp/out" || fail "the codex: line names the credit error: $(cat "$tmp/out")"
  [ ! -e "$CODEX_LOG" ] || fail "a recent out-of-credits job calls no companion: $(cat "$CODEX_LOG")"
  job b completed "$(now '-1 min')" ""
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a later completed job clears the breaker: $(cat "$tmp/out" "$tmp/err")"
  rm -rf "$jobs"
  job c failed "$(now '-1 min')" ""
  echo "[$(now)] Codex error: You've hit your usage limit. Try again at Oct 19th." >"$jobs/c.log"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a recent usage-limit task job must fail readiness"
  grep -qF "usage limit" "$tmp/out" || fail "the codex: line names the usage limit: $(cat "$tmp/out")"
  rm -rf "$jobs"
  job c failed "$(now '-4 min')" "$credits"
  touch -d '4 minutes ago' "$jobs/c.json"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a credit error 4 minutes old still fails readiness: $(cat "$tmp/out" "$tmp/err")"
  job c failed "$(now '-6 min')" "$credits"
  touch -d '6 minutes ago' "$jobs/c.json"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a notified credit error keeps Codex skipped for the rest of the day: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "skipping Codex for the rest of today" "$tmp/out" "$tmp/err" || fail "the same-day skip names its cause: $(cat "$tmp/out" "$tmp/err")"
  rm -f "$tmp/home/.local/state/forge/codex-quota-notified"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "an un-notified credit error older than 5 minutes is ignored: $(cat "$tmp/out" "$tmp/err")"
  job e completed "$(now '-1 min')" ""
  job c failed "$(now '-2 min')" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a job that succeeded after the credit error clears it: $(cat "$tmp/out" "$tmp/err")"
  rm -rf "$jobs"
  job d failed "$(now '-1 min')" "Unexpected token"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a recent failure of another kind is ignored: $(cat "$tmp/out" "$tmp/err")"
  rm -rf "$data/state"
  ok readiness
fi

nst=$home/.local/state/forge/codex-quota-notified title="forge: Codex out of credits"
notes() { awk -F'\t' -v t="$title" '$2 == t { n++ } END { print n + 0 }' "$NOTIFY_LOG"; }
if want quota-notify; then
  rm -f "$nst" && : >"$NOTIFY_LOG"
  t1=$(now '-3 min')
  job f failed "$t1" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "an out-of-credits job still fails readiness: $(cat "$tmp/out" "$tmp/err")"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a second review of the same job still fails readiness: $(cat "$tmp/out" "$tmp/err")"
  [ "$(notes)" = 1 ] || fail "one failed Codex job sends one notification across two reviews: $(cat "$NOTIFY_LOG" 2>&1)"
  awk -F'\t' -v t="$title" '$2 == t' "$NOTIFY_LOG" | grep -qF "$credits" || fail "the notification body names the error: $(cat "$NOTIFY_LOG")"
  awk -F'\t' -v t="$title" '$2 == t' "$NOTIFY_LOG" | grep -qF "switch Codex seats; reviews use the fallback reviewer until then" \
    || fail "the notification body says to switch Codex seats: $(cat "$NOTIFY_LOG")"
  [ "$(cat "$nst" 2>&1)" = "$t1" ] || fail "the notified job's completedAt is kept in $nst: $(cat "$nst" 2>&1)"
  t2=$(now '-2 min')
  job g failed "$t2" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a second out-of-credits job fails readiness"
  printf '%s\n' "$(date -u +%FT%TZ)" >"$nst"; n0=$(ls "$jobs" 2>/dev/null | wc -l)
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a notified out-of-credits day still fails readiness"
  grep -qF "skipping Codex for the rest of today" "$tmp/out" "$tmp/err" || fail "the same-day skip names its cause: $(cat "$tmp/out" "$tmp/err")"
  [ "$(ls "$jobs" 2>/dev/null | wc -l)" = "$n0" ] || fail "the same-day skip starts no Codex job"
  [ "$(notes)" = 1 ] || fail "a second failed Codex job on the same day sends no second notification: $(cat "$NOTIFY_LOG" 2>&1)"
  rm -f "$nst"
  t3=$(now '-1 min')
  job h failed "$t3" "$credits"
  [ "$(NOTIFY_EXIT=1 CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a failing notify-send leaves the review's exit 3: $(cat "$tmp/out" "$tmp/err")"
  [ "$(head -n1 "$tmp/out")" = "codex: the last Codex job, at $t3, failed: $credits" ] || fail "a failing notify-send leaves the codex: line: $(cat "$tmp/out")"
  grep -q '^forge: warning: .*notify-send' "$tmp/err" || fail "a failing notify-send prints a forge: warning: $(cat "$tmp/err")"
  [ "$(notes)" = 2 ] || fail "the failing notify-send was called: $(cat "$NOTIFY_LOG" 2>&1)"
  [ ! -f "$nst" ] || fail "a failed notification records no completedAt: $(cat "$nst" 2>&1)"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a retried notification keeps the exit 3"
  [ "$(notes)" = 3 ] && [ "$(cat "$nst" 2>&1)" = "$t3" ] || fail "a job whose notification failed is notified on the next review: $(cat "$NOTIFY_LOG" "$nst" 2>&1)"
  rm -rf "$data/state"
  ok quota-notify
fi

auth=$home/.codex/auth.json
login_start="systemd-run --user --unit=forge-codex-login.service --collect --quiet -- codex login"
logins() { grep -cxF "$login_start" "$LOGIN_LOG" || true; }
if want quota-login; then
  rm -f "$nst" "$auth" && : >"$NOTIFY_LOG" && : >"$LOGIN_LOG"
  t1=$(now '-4 min')
  job l1 failed "$t1" "$credits"
  [ "$(BROWSER=true CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "an out-of-credits job fails readiness: $(cat "$tmp/out" "$tmp/err")"
  [ "$(cat "$LOGIN_LOG")" = "systemctl --user stop forge-codex-login.service"$'\n'"$login_start" ] \
    || fail "the notification stops a left login unit, then starts codex login with no BROWSER: $(cat "$LOGIN_LOG")"
  ! grep -q warning "$tmp/err" || fail "stopping a login unit that is not loaded is no warning: $(cat "$tmp/err")"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] && [ "$(logins)" = 1 ] || fail "one failed job opens one login across two reviews: $(cat "$LOGIN_LOG")"
  rm -f "$nst"
  t2=$(now '-3 min')
  job l2 failed "$t2" "$credits"
  [ "$(NOTIFY_EXIT=1 CODEX_REVIEW=$(payload "$found") frun)" = 3 ] && [ "$(logins)" = 1 ] || fail "a failed notification opens no login: $(cat "$LOGIN_LOG")"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] && [ "$(logins)" = 2 ] || fail "the retried notification opens the login once: $(cat "$LOGIN_LOG")"
  n=$(notes)
  rm -f "$nst"
  t3=$(now '-2 min')
  job l3 failed "$t3" "$credits"
  [ "$(SYSTEMD_RUN_EXIT=1 CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a failed login start leaves the exit 3: $(cat "$tmp/out" "$tmp/err")"
  [ "$(head -n1 "$tmp/out")" = "codex: the last Codex job, at $t3, failed: $credits" ] || fail "a failed login start leaves the codex: line: $(cat "$tmp/out")"
  grep -q '^forge: warning: .*Codex login' "$tmp/err" || fail "a failed login start prints a forge: warning: $(cat "$tmp/err")"
  [ "$(notes)" = $((n + 1)) ] && [ "$(cat "$nst")" = "$t3" ] || fail "a failed login start leaves the notice and its record: $(cat "$NOTIFY_LOG" "$nst")"
  grep -qF forge-codex-login.service "$root/bin/forge.d/help/review.txt" || fail "review.txt names the login unit"
  rm -rf "$data/state"
  rm -f "$nst"
  ok quota-login
fi

if want quota-auth; then
  rm -f "$nst" "$auth" && : >"$NOTIFY_LOG" && : >"$LOGIN_LOG"
  mkdir -p "${auth%/*}"
  sec=$(date -u -d '-2 min' +%FT%T) t1=$sec.500Z
  job a1 failed "$t1" "$credits"
  touch -d "$sec.100Z" "$auth"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "an auth.json older in the job's second keeps the check failing: $(cat "$tmp/out" "$tmp/err")"
  [ "$(notes)$(logins)" = 11 ] && [ "$(cat "$nst")" = "$t1" ] || fail "an older auth.json leaves the notice and login: $(cat "$NOTIFY_LOG" "$LOGIN_LOG")"
  touch -d "$sec.500Z" "$auth"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "an auth.json of the job's millisecond is not newer: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "skipping Codex for the rest of today" "$tmp/out" || fail "the same-day skip holds under an auth.json that is not newer: $(cat "$tmp/out")"
  touch -d "$sec.900Z" "$auth"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "an auth.json newer in the job's second clears the same-day skip: $(cat "$tmp/out" "$tmp/err")"
  [ "$(notes)$(logins)" = 11 ] || fail "a cleared job sends no notice or login: $(cat "$NOTIFY_LOG" "$LOGIN_LOG")"
  [ "$(cat "$nst")" = "$t1" ] || fail "a cleared job keeps $nst: $(cat "$nst" 2>&1)"
  touch -d '6 minutes ago' "$jobs/a1.json"
  touch -d "$sec.100Z" "$auth"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "an old notified job with an older auth.json stays skipped: $(cat "$tmp/out" "$tmp/err")"
  touch -d "$sec.900Z" "$auth"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "an old notified job with a newer auth.json is cleared: $(cat "$tmp/out" "$tmp/err")"
  rm -f "$nst"
  job a2 failed "$t1" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "an un-notified job before the new login passes: $(cat "$tmp/out" "$tmp/err")"
  [ "$(notes)$(logins)" = 11 ] && [ ! -e "$nst" ] || fail "an un-notified job before the new login notifies nothing: $(cat "$NOTIFY_LOG" "$LOGIN_LOG")"
  t2=$(now '-1 min')
  job a3 failed "$t2" "$credits"
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 3 ] || fail "a later failed job on the new seat fails the check: $(cat "$tmp/out" "$tmp/err")"
  [ "$(notes)$(logins)" = 22 ] && [ "$(cat "$nst")" = "$t2" ] || fail "a later failed job notifies and opens a login: $(cat "$NOTIFY_LOG" "$LOGIN_LOG")"
  rm -rf "$data/state" "${auth%/*}"
  rm -f "$nst"
  ok quota-auth
fi

if want quota-rerun; then
  rm -f "$nst" && : >"$NOTIFY_LOG" && : >"$LOGIN_LOG"
  t1=$(now '-1 min')
  job r1 failed "$t1" "$credits"
  j=$(cat "$jobs/r1.json")
  rm "$jobs/r1.json"
  bad=$(payload '[]' | jq -c --arg e "$credits" '.parseError = $e | .result = null | .codex.status = 1')
  [ "$(CODEX_REVIEW_JOB_PATH=$jobs/r1.json CODEX_REVIEW_JOB=$j CODEX_REVIEW=$bad CODEX_REVIEW_EXIT=1 frun)" = 3 ] || fail "a review failing on credits exits 3: $(cat "$tmp/out" "$tmp/err")"
  [ "$(head -n1 "$tmp/out")" = "codex: adversarial-review exited 1: $credits" ] || fail "the rerun keeps the review's codex: line: $(cat "$tmp/out")"
  jq -e --arg l "codex: adversarial-review exited 1: $credits" '.pending == [$l]' "$fr/review.json" >/dev/null || fail "the rerun keeps the review's pending line: $(cat "$fr/review.json")"
  [ "$(notes)$(logins)" = 11 ] && [ "$(cat "$nst")" = "$t1" ] || fail "a review's own failed job notifies and opens a login at once: $(cat "$NOTIFY_LOG" "$LOGIN_LOG")"
  rm -rf "$data/state"
  rm -f "$nst"
  ok quota-rerun
fi

if want result-line; then
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a review must exit 0"
  [ "$(cat "$tmp/out")" = "findings: 3 open (2 high, 0 medium, 1 low), 1 advisory in $fr/review.json" ] || fail "a review prints one findings: line: $(cat "$tmp/out")"
  jq -e 'has("pending") | not' $fr/review.json >/dev/null || fail "a finished review has no pending: $(cat $fr/review.json)"
  [ "$(CODEX_REVIEW= CODEX_REVIEW_EXIT=1 frun)" = 3 ] || fail "a failed review must exit 3"
  [ "$(grep -c '' "$tmp/out")" = 2 ] && grep -q '^codex: ' "$tmp/out" \
    && [ "$(tail -n1 "$tmp/out")" = "findings: 0 open (0 high, 0 medium, 0 low), pending codex in $fr/review.json" ] || fail "a fallback prints the findings: line last, saying pending: $(cat "$tmp/out")"
  jq -e --arg l "$(head -n1 "$tmp/out")" '.pending == [$l] and .findings == []' $fr/review.json >/dev/null || fail "a failed review records its fallback line as pending: $(cat $fr/review.json)"
  "$forge" validate $fr/review.json || fail "a review.json with pending must validate"
  [ "$(cd "$fw" && CODEX_REVIEW=$(payload "[$(finding low src/form.ts 2)]") FORGE_ROOT=$p run review crm/intake)" = 0 ] || fail "a feature review must exit 0"
  [ "$(cat "$tmp/out")" = "findings: 1 open (0 high, 0 medium, 1 low) in $fr/review.json" ] || fail "a feature review prints its findings: line: $(cat "$tmp/out")"
  ok result-line
fi

if want dismissed; then
  [ "$(CODEX_REVIEW=$(payload "$found") frun)" = 0 ] || fail "a review must exit 0: $(cat "$tmp/out" "$tmp/err")"
  jq '.findings[0].dismissed = "a false positive: the style is global" | .findings[1].dismissed = ""' $fr/review.json >"$tmp/d.json" && cp "$tmp/d.json" $fr/review.json
  "$forge" validate $fr/review.json || fail "a review.json with dismissed findings must validate"
  jq '.findings[0].dismissed = 3' $fr/review.json >"$tmp/bad.json" && cp "$tmp/bad.json" $fr/review.json
  ! "$forge" validate $fr/review.json >/dev/null 2>&1 || fail "a dismissed that is not a string must fail"
  "$forge" validate "$fxpd/review.json" || fail "review data without dismissed stays valid"
  ok dismissed
fi

if want large-findings; then
  big=$(printf '%0200d' 0)
  payload '[]' | jq -c --arg b "$big" '.result.findings = [range(1500) | {severity: "low", title: "T", body: $b, file: "src/intake.ts", line_start: (. + 1), line_end: (. + 1), confidence: 0.8, recommendation: "Fix it."}]' >"$tmp/big-review.json"
  [ "$(CODEX_REVIEW_FILE=$tmp/big-review.json frun)" = 0 ] || fail "a review with over 128 KiB of findings must exit 0: $(cat "$tmp/out" "$tmp/err")"
  [ "$(jq -c '[.findings[].source] | group_by(.) | map({(.[0]): length}) | add' $fr/review.json)" = '{"codex":1500}' ] \
    || fail "a large review keeps every codex finding: $(head -c 300 $fr/review.json)"
  ok large-findings
fi

rec() { jq "$@" "$fxpd/review.json" >"$rv"; }
if want review-tree; then
  rv=$tmp/rv/features/crm-intake/review.json t40=$(printf '%040d' 0 | tr 0 a) t64=$(printf '%064d' 0 | tr 0 b)
  mkdir -p "$(dirname "$rv")"
  rec 'del(.tree)'
  "$forge" validate "$rv" || fail "a review record without tree must validate: $(cat "$rv")"
  for t in "$t40" "$t64"; do
    rec --arg t "$t" '.tree = $t'
    "$forge" validate "$rv" || fail "a review record with tree $t must validate"
  done
  for t in '"HEAD"' "\"${t40^^}\"" "\"${t40:1}\"" "\"${t40}a\"" "\"${t64}c\"" 7 null; do
    rec --argjson t "$t" '.tree = $t'
    ! "$forge" validate "$rv" >/dev/null 2>&1 || fail "a review record with tree $t must fail"
  done
  "$forge" validate "$fxpd/review.json" || fail "the phase gate review fixture stays valid"
  ok review-tree
fi

[ -z "$only" ] || fail "no case $only"
