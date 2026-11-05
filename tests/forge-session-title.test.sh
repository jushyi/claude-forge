#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/forge-session-title.sh

fail() { echo "forge-session-title: FAIL $*" >&2; exit 1; }
[ -z "${1:-}" ] || fail "no case $1"
skill_text() {
  awk -v root="$root" '
    { print }
    match($0, /Read ~\/\.claude\/skills\/[a-z0-9-]+\/[a-z0-9-]+\.md and follow it\./) {
      p = root "/" substr($0, RSTART + 15, RLENGTH - 30)
      while ((r = (getline l < p)) > 0) print l
      close(p)
      if (r < 0) { print "forge-session-title: FAIL " FILENAME ":" FNR ": pointer file " p " is missing" > "/dev/stderr"; bad = 1 }
    }
    END { exit bad }
  ' "$1"
}
tmp=$(mktemp -d -p /tmp)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME=$tmp/state
mkdir -p "$XDG_STATE_HOME"

p=$tmp/Projects
mkdir -p "$p/forge/.forge" "$p/forge/.claude/worktrees/rollout-72/.forge" "$p/forge/.claude/worktrees/rollout-72/hooks" \
  "$p/ACME/.forge" "$p/ACME/acme-hub/.forge" "$p/ACME/acme-hub/src" \
  "$p/outer/.forge" "$p/outer/inner/.forge" "$p/outer/inner/src" \
  "$p/recall/.claude/worktrees/fix-1" "$p/recipes" "$p/forge/.git/forge-test/tmp/1/recipes"
touch "$p/forge/.forge/PROJECT.md" "$p/forge/.claude/worktrees/rollout-72/.forge/PROJECT.md" \
  "$p/ACME/.forge/PROJECT.md" "$p/outer/.forge/PROJECT.md" "$p/outer/inner/.forge/PROJECT.md"

run() {
  local t=null
  [ $# -lt 4 ] || t=$(jq -n --arg t "$4" '$t')
  jq -n --arg p "$1" --arg c "${2:-/home/u/Projects/acme}" --arg s "${3:-sid-$BASHPID-$RANDOM$RANDOM}" --argjson t "$t" \
    '{hook_event_name: "UserPromptSubmit", session_id: $s, cwd: $c, prompt: $p} + (if $t == null then {} else {session_title: $t} end)' | "$hook"
}
title() { run "$@" | jq -r .hookSpecificOutput.sessionTitle; }

[ "$(title '/forge-discuss forge/run' "$p/forge")" = "forge discuss forge/run" ] || fail "must title a discuss with its project first, then its feature"
[ "$(title '/forge-discuss web/login' "$p/recipes")" = "recipes discuss web/login" ] || fail "must take the project from the cwd basename"
[ "$(title '/forge-discuss forge/run' "$p/forge/.claude/worktrees/rollout-72")" = "forge discuss forge/run" ] || fail "must take the project from before /.claude/worktrees/"
[ "$(title '/forge-quick fix it' "$p/forge/.claude/worktrees/rollout-72/hooks")" = "forge quick fix it" ] || fail "must cut a worktree subdirectory at /.claude/worktrees/"
[ "$(title '/forge-discuss hub/api' "$p/ACME/acme-hub")" = "ACME discuss hub/api" ] || fail "must walk up to the nearest .forge/PROJECT.md"
[ "$(title '/forge-quick fix it' "$p/ACME/acme-hub/src")" = "ACME quick fix it" ] || fail "must walk up from a subdirectory to the nearest .forge/PROJECT.md"
[ "$(title '/forge-quick fix it' "$p/outer/inner/src")" = "inner quick fix it" ] || fail "must stop at the nearest .forge/PROJECT.md"
[ "$(title '/forge-quick fix it' "$p/recall/.claude/worktrees/fix-1")" = "recall quick fix it" ] || fail "must fall back to the cut cwd basename"
[ "$(title '/forge-quick fix it' "$p/forge/.git/forge-test/tmp/1/recipes")" = "recipes quick fix it" ] || fail "must stop the walk-up at a .git directory"
[ "$(title 'hello' "$p/ACME/acme-hub")" = "ACME hello" ] || fail "a first plain prompt must title with the resolved project"
[ "$(run '/forge-discuss forge/run' "$p/forge" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] || fail "must name the event"
[ "$(title '/forge-discuss   forge/run  ' "$p/forge")" = "forge discuss forge/run" ] || fail "must trim whitespace"
[ "$(title '/forge-discuss')" = "acme discuss" ] || fail "bare discuss must title with its project and skill"
[ "$(title '/forge-discuss  ')" = "acme discuss" ] || fail "blank discuss must title with its project and skill"
[ "$(title '/forge-discuss --auto forge/run' "$p/forge")" = "forge discuss forge/run" ] || fail "auto discuss must strip --auto and title with its feature"
[ "$(title '/forge-discuss --auto')" = "acme discuss" ] || fail "bare auto discuss must title with its project and skill"
[ "$(title '/forge-discussion forge/run')" = "acme /forge-discussion forge/run" ] || fail "a first lookalike command must title as a plain prompt"
[ "$(title 'run /forge-discuss forge/run')" = "acme run /forge-discuss forge/run" ] || fail "a first command mid-prompt must title as a plain prompt"
[ "$(title '/forge-build x')" = "acme /forge-build x" ] || fail "a first /forge-build prompt must title as a plain prompt"
[ "$(title '/forge-audit x')" = "acme /forge-audit x" ] || fail "a first /forge-audit prompt must title as a plain prompt"

long_word=$(printf 'x%.0s' {1..40})
long='add retry logic to the phase runner when the session dies unexpectedly'
cut() {
  local t body
  t=$(title "$2$long")
  case $t in "$1 "*) ;; *) fail "'$2' long prompt must title with '$1': $t" ;; esac
  body=${t#"$1 "}
  [ "${#body}" -ge 25 ] && [ "${#body}" -le 40 ] || fail "'$2' long prompt must cut to about 40 characters: $body"
  case "$long " in "$body "*) ;; *) fail "'$2' long prompt must cut at a word boundary: $body" ;; esac
}

[ "$(title '/forge-quick fix the typo')" = "acme quick fix the typo" ] || fail "must title a quick with its task"
[ "$(title '/forge-quick fix the typo' "$p/recipes")" = "recipes quick fix the typo" ] || fail "quick must take the project from the cwd basename"
[ "$(run '/forge-quick fix the typo' | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] || fail "quick must name the event"
[ "$(title '/forge-quick --discuss fix the typo')" = "acme quick fix the typo" ] || fail "quick must strip --discuss"
[ "$(title '/forge-quick --research fix the typo')" = "acme quick fix the typo" ] || fail "quick must strip --research"
[ "$(title '/forge-quick --discuss --research   fix  the   typo  ')" = "acme quick fix the typo" ] || fail "quick must strip flags and collapse whitespace"
[ "$(title '/forge-quick --verify fix the typo')" = "acme quick fix the typo" ] || fail "quick must strip --verify"
[ "$(title '/forge-quick --discuss  --verify --research fix the typo')" = "acme quick fix the typo" ] || fail "quick must strip --verify mixed with --discuss and --research"
[ "$(title '/forge-quick --verify --discuss fix the typo')" = "acme quick fix the typo" ] || fail "quick must strip --verify ahead of --discuss"
[ "$(title '/forge-quick --verifyx fix the typo')" = "acme quick --verifyx fix the typo" ] || fail "quick must strip --verify only as a whole word"
[ "$(title '/forge-quick --verify')" = "acme quick" ] || fail "flag-only --verify quick must title with its project and skill"
[ "$(title '/forge-quick --research --verify --discuss')" = "acme quick" ] || fail "flag-only quick with --verify must title with its project and skill"
cut "acme quick" "/forge-quick "
[ "$(title '/forge-quick')" = "acme quick" ] || fail "bare quick must title with its project and skill"
[ "$(title '/forge-quick  ')" = "acme quick" ] || fail "blank quick must title with its project and skill"
[ "$(title '/forge-quick --discuss --research')" = "acme quick" ] || fail "flag-only quick must title with its project and skill"
[ "$(title '/forge-quickly fix the typo')" = "acme /forge-quickly fix the typo" ] || fail "a first quick lookalike must title as a plain prompt"
[ "$(title 'run /forge-quick fix the typo')" = "acme run /forge-quick fix the typo" ] || fail "a first quick mid-prompt must title as a plain prompt"

[ "$(title '/forge-fast bump the version')" = "acme fast bump the version" ] || fail "must title a fast with its task"
[ "$(title '/forge-fast   bump   the version ')" = "acme fast bump the version" ] || fail "fast must collapse whitespace"
cut "acme fast" "/forge-fast "
[ "$(title '/forge-fast')" = "acme fast" ] || fail "bare fast must title with its project and skill"
[ "$(title '/forge-fast  ')" = "acme fast" ] || fail "blank fast must title with its project and skill"
[ "$(title '/forge-faster bump the version')" = "acme /forge-faster bump the version" ] || fail "a first fast lookalike must title as a plain prompt"

[ "$(title '/forge-new a recipe tracker')" = "acme new a recipe tracker" ] || fail "must title a new with its args"
[ "$(title "$(printf '/forge-new  a recipe\n\ttracker  ')")" = "acme new a recipe tracker" ] || fail "new must collapse whitespace across lines"
cut "acme new" "/forge-new "
[ "$(title '/forge-new')" = "acme new" ] || fail "bare new must title with its project and skill"
[ "$(title '/forge-new  ')" = "acme new" ] || fail "blank new must title with its project and skill"
[ "$(title '/forge-newer a recipe tracker')" = "acme /forge-newer a recipe tracker" ] || fail "a first new lookalike must title as a plain prompt"

[ "$(title '/forge-debug fix the crash')" = "acme debug fix the crash" ] || fail "must title a debug with its symptom"
[ "$(run '/forge-debug fix the crash' | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] || fail "debug must name the event"
[ "$(title '/forge-debug --diagnose-only fix the crash')" = "acme debug fix the crash" ] || fail "debug must strip --diagnose-only"
[ "$(title '/forge-debug --diagnose-onlyx fix the crash')" = "acme debug --diagnose-onlyx fix the crash" ] || fail "debug must strip --diagnose-only only as a whole word"
[ "$(title '/forge-debug --diagnose-only   fix  the   crash  ')" = "acme debug fix the crash" ] || fail "debug must strip the flag and collapse whitespace"
cut "acme debug" "/forge-debug "
[ "$(title '/forge-debug')" = "acme debug" ] || fail "bare debug must title with its project and skill"
[ "$(title '/forge-debug  ')" = "acme debug" ] || fail "blank debug must title with its project and skill"
[ "$(title '/forge-debug --diagnose-only')" = "acme debug" ] || fail "flag-only debug must title with its project and skill"
[ "$(title '/forge-debugger x')" = "acme /forge-debugger x" ] || fail "a first debug lookalike must title as a plain prompt"

[ "$(title '/forge-port the receipts service to Rust')" = "acme port the receipts service to Rust" ] || fail "must title a port with its component"
cut "acme port" "/forge-port "
[ "$(title '/forge-port')" = "acme port" ] || fail "bare port must title with its project and skill"
[ "$(title '/forge-porter x')" = "acme /forge-porter x" ] || fail "a first port lookalike must title as a plain prompt"

[ "$(title 'fix the login page')" = "acme fix the login page" ] || fail "a first plain prompt must title with its project first"
[ "$(title "$(printf '  fix   the\n\tlogin page  ')")" = "acme fix the login page" ] || fail "a first plain prompt must collapse whitespace"
[ "$(title '/review-pr 12')" = "acme /review-pr 12" ] || fail "a first other slash command must title as a plain prompt"
cut acme ""
for q in 'ship crm/old' 'verify crm/export' 'P5 crm/export' 'P12R3 crm/export' "  ship   crm/old  " "verify crm/export $long_word"; do
  [ -z "$(run "$q")" ] || fail "a first plain prompt shaped like a launched session title must set no title: $q"
done
[ "$(title 'ship crm/old now')" = "acme ship crm/old now" ] || fail "a first plain prompt with more words after a launched kind must title"
[ "$(title 'ship crm')" = "acme ship crm" ] || fail "a first plain prompt without a track/feature must title"
[ "$(title 'Ship crm/old')" = "acme Ship crm/old" ] || fail "a first plain prompt with a capitalised kind must title"
[ "$(run 'hello' "$p/forge" s1 | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ] || fail "a first plain prompt must name the event"
[ -n "$(ls -A "$XDG_STATE_HOME/forge-session-title" 2>/dev/null)" ] || fail "a first prompt must leave a marker under \$XDG_STATE_HOME/forge-session-title/"
[ -z "$(run 'and again' "$p/forge" s1)" ] || fail "a later plain prompt in the same session must keep its title"
[ -z "$(run '/review-pr 12' "$p/forge" s1)" ] || fail "a later other slash command in the same session must keep its title"
[ "$(title 'hello' "$p/forge" s2)" = "forge hello" ] || fail "a first plain prompt in another session must title"
[ "$(title '/forge-quick fix it' "$p/forge" s1)" = "forge quick fix it" ] || fail "a forge skill prompt must title after other prompts"
[ "$(title '/forge-discuss' "$p/forge" s1)" = "forge discuss" ] || fail "a bare forge skill prompt must title after other prompts"
[ "$(title '/forge-quick fix it' "$p/forge" s3)" = "forge quick fix it" ] || fail "a forge skill prompt must title as a first prompt"
[ -z "$(run 'hello' "$p/forge" s3)" ] || fail "a plain prompt after a forge skill prompt must keep its title"
[ "$(title '/forge-new' "$p/forge" s4)" = "forge new" ] || fail "a bare forge skill prompt must title as a first prompt"
[ -z "$(run 'hello' "$p/forge" s4)" ] || fail "a plain prompt after a bare forge skill prompt must keep its title"
note=$(printf '<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>')
[ -z "$(run "$note" "$p/forge" s5)" ] || fail "a first prompt starting with an XML-style tag must set no title"
[ -z "$(run '<system-reminder>x</system-reminder>' "$p/forge" s5)" ] || fail "a second tag prompt must set no title"
[ "$(title 'fix the login page' "$p/forge" s5)" = "forge fix the login page" ] || fail "a tag prompt must not consume the first-prompt marker"
[ -z "$(run 'and again' "$p/forge" s5)" ] || fail "a later plain prompt after a tag prompt and a first prompt must keep its title"
[ -z "$(run "$note" "$p/forge" s6)" ] || fail "a tag prompt must set no title in a new session"
[ "$(title '/forge-quick fix it' "$p/forge" s6)" = "forge quick fix it" ] || fail "a forge skill prompt must title after a tag prompt"
wd='forge watchdog: x cleared; continue phase 5 from where it stopped'
[ -z "$(run "$wd" "$p/forge" wd1)" ] || fail "a forge watchdog prompt on a fresh session must set no title"
[ -z "$(run "$wd" "$p/forge" wd2 'forge P5 t/f')" ] || fail "a forge watchdog prompt in a forge-named session must set no title"
[ -z "$(run "$wd" "$p/forge" wd3 'forge fix the login')" ] || fail "a forge watchdog prompt must set no title whatever the session title"
[ "$(title 'forge watchdog x' "$p/forge" wd4)" = "forge forge watchdog x" ] || fail "a first prompt without the forge watchdog: prefix must title"
n=0
for st in 'proj P5 t/f' 'proj/sub P5R1 t/f' 'proj/sub verify t/f' 'proj ship t/f' 'forge P12R3 audit-261014/session-names'; do
  n=$((n + 1))
  [ -z "$(run 'hello' "$p/forge" "fn$n" "$st")" ] || fail "a first prompt in a forge-named session must set no title: $st"
  [ -z "$(run '/forge-quick x' "$p/forge" "fn$n" "$st")" ] || fail "a later /forge-quick in a forge-named session must set no title: $st"
  [ -z "$(run '/forge-quick x' "$p/forge" "fq$n" "$st")" ] || fail "a first /forge-quick in a forge-named session must set no title: $st"
done
n=0
for st in 'proj fix the login' 'forge quick fix it' 'proj P5 t/f more' 'proj Ship t/f' 'P5 t/f' 'proj P5 t'; do
  n=$((n + 1))
  [ "$(title 'hello' "$p/forge" "hn$n" "$st")" = "forge hello" ] || fail "a first prompt in a human-named session must keep today's title: $st"
  [ "$(title '/forge-quick x' "$p/forge" "hn$n" "$st")" = "forge quick x" ] || fail "a later /forge-quick in a human-named session must keep today's title: $st"
  [ -z "$(run 'and again' "$p/forge" "hn$n" "$st")" ] || fail "a later plain prompt in a human-named session must keep its title: $st"
done
[ "$(title 'hello' "$p/forge" he1 '')" = "forge hello" ] || fail "an empty session title must title like no session title"
[ "$(title '/forge-quick x' "$p/forge" he1 '')" = "forge quick x" ] || fail "a later /forge-quick with an empty session title must title"
[ "$(title 'hello' "$p/forge" hx1)" = "forge hello" ] || fail "a first prompt with no session title must title"
[ "$(title '/forge-quick x' "$p/forge" hx1)" = "forge quick x" ] || fail "a later /forge-quick with no session title must title"

skip=" forge-phase forge-verify forge-ship "
for d in "$root"/skills/*/; do
  s=$(basename "$d")
  if [[ $skip == *" $s "* ]]; then
    [ -z "$(run "/$s x")" ] || fail "$s is launched by bin/forge and must keep its title"
    [ -z "$(run "/$s x" "$p/forge" "mark-$s")" ] || fail "$s must keep its title in a new session"
    [ -z "$(run 'hello' "$p/forge" "mark-$s")" ] || fail "a plain prompt after $s must keep its title"
  else
    run 'hello' "$p/forge" "later-$s" >/dev/null
    [ -n "$(title "/$s x" "$p/forge" "later-$s" | grep -v '^null$')" ] || fail "$s gets no session title and is not on the skip list"
  fi
done

endings=$(skill_text "$root/skills/forge-phase/SKILL.md" | tr '\n' ' ' | tr -s ' ' | grep -oiE 'ends? the turn([^.;`]|`[^`]*`)*') ||
  fail "forge-phase names no turn ending"
while IFS= read -r e; do
  spans=$(grep -oE '`[^`]*`' <<<"$e" | grep ' ') || {
    grep -qiF 'with no result line' <<<"$e" || fail "forge-phase ending names no line: $e"
    continue
  }
  while IFS= read -r line; do
    case ${line#\`} in 'result:'* | 'failed:'* | 'blocked:'* | 'needs input:'*) ;;
      *) fail "forge-phase ending must start result:, failed:, blocked: or needs input:: $e" ;; esac
  done <<<"$spans"
done <<<"$endings"

verify=$(skill_text "$root/skills/forge-verify/SKILL.md" | tr '\n' ' ' | tr -s ' ')
has() { grep -qiE -- "$1" <<<"$verify"; }
has 'operator deferred' || fail "forge-verify must write P2/P3 findings as 'operator deferred' todo lines"
has '\.forge/todo\.md' || fail "forge-verify must append deferred findings to .forge/todo.md"
has 'P2 or P3 finding' || fail "forge-verify must name P2 or P3 findings as deferred"
has 'only P0(/| or | and )P1 findings' || fail "forge-verify must make only P0/P1 findings gaps"
! has 'Each Priority Issue is a gap' || fail "forge-verify must not make every critique Priority Issue a gap"
has 'forge test --stack' || fail "forge-verify must run the stack tests with forge test --stack"
has 'rev-parse forge/<track>-<feature>' || fail "forge-verify must check the build commit against rev-parse forge/<track>-<feature>"
has '`met <ID>: <evidence path>`' || fail "forge-verify must print a met <ID>: <evidence path> sheet line"
has '`unmet <ID> \(phase <N>\): <reason>`' || fail "forge-verify must print an unmet <ID> (phase <N>): <reason> sheet line"
has '`operator <ID>: <the step text>`' || fail "forge-verify must print an operator <ID>: <the step text> sheet line"
has '`post-ship <ID>: owed`' || fail "forge-verify must print a post-ship <ID>: owed sheet line"
! has '`Accept the agent run`' || fail "forge-verify must drop the Accept the agent run question; the sheet decides"
! has '`I will test it myself`' || fail "forge-verify must drop the I will test it myself option; the sheet decides"
! has 'Change steps' || fail "forge-verify must not offer a Change steps handshake"
! has '`I ran the test and it passed`' || fail "forge-verify must drop the bulk result question's 'I ran the test and it passed'"
! has 'date \+%s' || fail "forge-verify must drop the date +%s timing of the manual test"
! has '60 seconds or more|under 60 seconds' || fail "forge-verify must drop the 60-second operator_ran timing check"
! has '`Ready`' || fail "forge-verify must not offer a separate 'Ready' option"
! has '- Ready:' || fail "forge-verify must not ask a separate Ready question"
order=$(grep -oE '[0-9]+\. (Repos|Sync|Smoke test)\.' <<<"$verify" | sed -E 's/^[0-9]+\. //' | tr '\n' ' ')
[ "$order" = "Repos. Sync. Smoke test. " ] || fail "forge-verify must run a Sync step between Repos and Smoke test: $order"
has 'git -C W remote get-url origin' || fail "forge-verify Sync must check for an origin remote with git -C W remote get-url origin"
has 'git -C W fetch origin main' || fail "forge-verify Sync must fetch origin main"
has 'Resolver loop with `origin/main`' || fail "forge-verify Sync must run the Resolver loop with origin/main"
has 'Resolver loop with `main`' || fail "forge-verify Sync must run the Resolver loop with main when there is no origin remote"
has 'failed fetch[^.]*last fetched `origin/main`' || fail "forge-verify Sync must print a failed fetch and merge the last fetched origin/main"
has 'base `M`' || fail "forge-verify Sync must name each repo's merged ref its base M"
grep -qx '## Resolver loop' "$root/skills/forge-verify/SKILL.md" || fail "forge-verify must have a ## Resolver loop section"
has 'forge merge <branch>' || fail "forge-verify Resolver loop must run forge merge <branch>"
has 'forge merge-check <record>' || fail "forge-verify Resolver loop must run forge merge-check <record>"
has 'forge merge --continue <record>' || fail "forge-verify Resolver loop must run forge merge --continue <record>"
has 'forge merge --abort' || fail "forge-verify Resolver loop must run forge merge --abort after the second failed attempt"
has '`verify <feature> sync forge-merger`' || fail "forge-verify Resolver loop must spawn forge-merger described 'verify <feature> sync forge-merger'"
has 'F/merge/<repo>-V<k>\.json' || fail "forge-verify Resolver loop must record F/merge/<repo>-V<k>.json"
! has 'F/merge/<repo>-M<k>\.json' || fail "forge-verify must not reuse ship's F/merge/<repo>-M<k>.json records"
has 'ask the operator[^.]*conflicted paths[^.]*last merge-check output' || fail "forge-verify Resolver loop must ask the operator with the conflicted paths and the last merge-check output"
has 'Exit 1: ask the operator with its message' || fail "forge-verify Resolver loop must ask the operator on forge merge exit 1"
! has 'run Escalate' || fail "forge-verify Resolver loop must ask the operator, not run Escalate"
! grep -qx '## Escalate' "$root/skills/forge-verify/SKILL.md" || fail "forge-verify must not have a ## Escalate section"
has 'forge test --changed --base M W' || fail "forge-verify must run the changed tests with forge test --changed --base M W"
! has 'forge test --changed W' || fail "forge-verify must not run forge test --changed W against main"
! has 'feature diff against `main`' || fail "forge-verify Rules must name M, not main, as the changed-tests base"
has 'git diff M\.\.\.forge/<track>-<feature>' || fail "forge-verify must write the review diff as git diff M...forge/<track>-<feature>"
! has 'git diff main\.\.\.forge/<track>-<feature>' || fail "forge-verify must not diff against main after Sync"
has 'forge review <track>/<feature> --base M --out <git dir>/forge-<feature>-review\.json' ||
  fail "forge-verify must run forge review <track>/<feature> --base M --out <git dir>/forge-<feature>-review.json"
has 'one (background )?Bash command per `W`' || fail "forge-verify step 6 must start one background Bash command per W"
! has 'rm -f F/review\.json' || fail "forge-verify must not rm -f F/review.json once --out writes the repo record"
! has 'F/review/reviewer\.json' || fail "forge-verify must give forge-reviewer F/review/reviewer-<repo>.json, not F/review/reviewer.json"
has 'F/review/reviewer-<repo>\.json' || fail "forge-verify must give forge-reviewer F/review/reviewer-<repo>.json"
pos() { local s=${2%%"$1"*}; if [ "$s" = "$2" ]; then echo -1; else echo "${#s}"; fi; }
section() { skill_text "$root/skills/forge-verify/SKILL.md" | awk -v h="## $1" '$0 == h {f = 1; next} /^## /{f = 0} f' | tr '\n' ' ' | tr -s ' '; }
prev=$(pos 'forge-<feature>-review.prev.json' "$verify")
outr=$(pos '--base M --out <git dir>/forge-<feature>-review.json' "$verify")
[ "$prev" -ge 0 ] && [ "$prev" -lt "$outr" ] ||
  fail "forge-verify must move an earlier forge-<feature>-review.json to forge-<feature>-review.prev.json before the review's --out writes it"
has '--prior[^.]*review\.prev\.json|review\.prev\.json[^.]*--prior' || fail "forge-verify must pass the moved review.prev.json record to the first review as --prior"
grep -qx '## Inline fixes' "$root/skills/forge-verify/SKILL.md" || fail "forge-verify must have a ## Inline fixes section"
! has 'In-place fixes' || fail "forge-verify must name no In-place fixes section or step once Inline fixes replaces it"
fixes=$(section 'Inline fixes')
infix() { grep -qiE -- "$1" <<<"$fixes"; }
infix 'review-only' || fail "forge-verify Inline fixes must fix only review-only findings"
infix '\[<focus> <ID>\]' || fail "forge-verify Inline fixes must treat a [<focus> <ID>] finding as naming an unmet criterion"
infix 'F/requirements\.json' || fail "forge-verify Inline fixes must match requirement IDs of F/requirements.json"
infix 'open high' || fail "forge-verify Inline fixes must fix only open high findings"
infix 'r = 1, 2' || fail "forge-verify Inline fixes must run rounds r = 1, 2"
infix 'never more than 2 inline rounds' || fail "forge-verify must never run more than 2 inline rounds"
infix 'P = `?git -C W rev-parse HEAD`' || fail "forge-verify Inline fixes must note the pre-fix commit P = git -C W rev-parse HEAD"
infix 'FORGE_ROOT=R forge fixes <track>/<feature> --record <git dir>/forge-<feature>-review\.json' ||
  fail "forge-verify Inline fixes must run forge fixes <track>/<feature> --record the repo record"
infix 'forge-fixer' || fail "forge-verify Inline fixes must spawn forge-fixer per file"
infix 'F/fixes/<repo>-V<k>\.json' || fail "forge-verify Inline fixes must give each forge-fixer its own F/fixes/<repo>-V<k>.json"
! has 'fixes/V<k>\.json' || fail "forge-verify must number fix records per repo as F/fixes/<repo>-V<k>.json, not F/fixes/V<k>.json"
infix '`not a defect: `' || fail "forge-verify Inline fixes must dismiss only failed fixes starting 'not a defect: '"
infix 'forge test --one <id>' || fail "forge-verify Inline fixes must rerun each failing id with forge test --one <id>"
! has 'forge test --changed --base P W' || fail "forge-verify must not rerun a fix diff's tests with forge test --changed --base P W"
! has 'rereview' || fail "forge-verify must not re-review a fix diff into a rereview record"
infix 'after round 2' || fail "forge-verify Inline fixes must turn what is left after round 2 into gaps or deferred todos"
infix "rerun step 5's build check" || fail "forge-verify must rerun step 5's build check after any committed fix"
infix 'rerun[^.]*manual-test step[^.]*(had|has|with|left) a gap' || fail "forge-verify must rerun an agent-run manual-test step that had a gap after any committed fix"
infix 'rerun every manual-test step you ran in step 6 before the fixes' || fail "forge-verify must rerun every manual-test step it ran in step 6 when any mapping is missing or unsure"
infix '<P>/plan\.json' ||
  fail "forge-verify must map a manual-test step to files through its requirement's plan.json task files"
infix 'F/split\.json[^.]*requirements|requirements[^.]*F/split\.json' ||
  fail "forge-verify must find a requirement's phases through F/split.json phases' requirements"
infix 'git -C W diff P\.\.HEAD --name-only' || fail "forge-verify must take the fix diff files from git -C W diff P..HEAD --name-only"
infix 'P[^.]*before (its|the) first round' || fail "forge-verify's fix diff base P must be the W's pre-fix commit before its first round"
infix 'intersect[^.]*(per|each|same) repo|(per|each|same) repo[^.]*intersect' ||
  fail "forge-verify must intersect a step's files with the fix diff files per repo"
infix 'no mapping' || fail "forge-verify must rerun a manual-test step with no mapping"
infix 'no requirement ID' || fail "forge-verify must treat a step with no requirement ID as having no mapping"
infix 'deferred check[^.]*only[^.]*phase|phase-only deferred' || fail "forge-verify must treat a deferred check mapped only to a phase as having no mapping"
infix 'no (plan )?task files' || fail "forge-verify must treat a requirement with no plan task files as having no mapping"
infix 'mapping[^.]*unsure|unsure[^.]*mapping' || fail "forge-verify must fall back to the full manual-test rerun when the mapping is unsure"
infix 'rerun each step whose files[^.]*fix diffs. file[^.]*chain of intermediate files' ||
  fail "forge-verify must rerun a manual-test step whose files depend on a fix-touched file through intermediate files"
infix 'cannot rule out a dependency on a fix-touched file, rerun the step' ||
  fail "forge-verify must rerun a manual-test step when it cannot rule out a dependency on a fix-touched file"
infix 'keeps?[^.]*E/s<k>/[^.]*gaps' || fail "forge-verify must let a step it does not rerun keep its E/s<k>/ output and gaps"
infix '`\[agent\]\[carried\] <[^`]*E/s<k>/[^`]*>`' || fail "forge-verify must record a step it does not rerun as [agent][carried] <E/s<k>/ paths>"
infix '\[agent\][^[][^.]*fixed tree|fixed tree[^.]*\[agent\][^[]' || fail "forge-verify must keep the plain [agent] tag for a step run on the fixed tree"
in6s=${verify#*6. Manual test.}
in6s=${in6s%%7. Record.*}
grep -qiE -- "(each|every) step's requirement IDs?|requirement IDs?(\(s\))?[^.]*(into|in) (each|the|every) step" <<<"$in6s" ||
  fail "forge-verify step 6 must write each step's requirement ID(s) into the step"
infix 'forge test --stack' || fail "forge-verify Inline fixes must rerun step 4's stack tests with forge test --stack"
infix 'rerun[^.]*forge test --stack[^.]*after[^.]*commit|after[^.]*commit[^.]*rerun[^.]*forge test --stack' ||
  fail "forge-verify Inline fixes must say the stack tests rerun after the fixes are committed"
infix 'forge-stack\.log' || fail "forge-verify Inline fixes must give a failing stack test's forge-stack.log to the next round's forge-fixer"
infix 'after round 2[^.]*stack' || fail "forge-verify Inline fixes must make a stack run still failing after round 2 a gap"
infix "rounds have ended[^.]*rerun[^.]*stack tests of step 3's merged test stage in every repo" ||
  fail "forge-verify must rerun every repo's stack tests after the last inline fix, not only the fixed repo's"
infix "skip[^.]*(one|single) repo|(one|single) repo[^.]*skip" ||
  fail "forge-verify Inline fixes must skip the cross-repo stack rerun only for a single stack repo"
infix "(exactly|only) one repo[^.]*both[^.]*- Local stack:[^.]*- Stack tests:" ||
  fail "forge-verify's cross-repo stack rerun skip must need exactly one repo with both a - Local stack: and a - Stack tests: line"
infix 'every fix commit[^.]*`W`' ||
  fail "forge-verify's cross-repo stack rerun skip must need every fix commit in that repo's W"
infix 'last `forge test --stack W` rerun[^.]*step e[^.]*after[^.]*last[^.]*fix' ||
  fail "forge-verify's cross-repo stack rerun skip must need that W's last forge test --stack W rerun, in step 4's per-file rounds or step e, after its last committed fix"
infix 'stack_tests`[^.]*final' ||
  fail "forge-verify's cross-repo stack rerun skip must make that repo's stack_tests passed final"
infix "(still|either way|whether or not|even when)[^.]*step 5's build check|step 5's build check[^.]*(still|either way|whether or not|even when)" ||
  fail "forge-verify must still rerun step 5's build check after any committed fix when the cross-repo stack rerun is skipped"
! section Rules | grep -qF -- '--base P' || fail "forge-verify Rules' background-review exception must be step 6's forge review alone, with no --base P re-review"
steps=$(section Steps)
fx=$(pos 'Inline fixes' "$steps")
ask=$(pos 'The sheet.' "$steps")
[ "$fx" -ge 0 ] && [ "$fx" -lt "$ask" ] || fail "forge-verify must run Inline fixes before the sheet"
has "review_trees\[<repo>\][^.]*record's \`tree\`" || fail "forge-verify must set review_trees[<repo>] from the repo record's tree"
! has 'equals the reviewed tree step 6 printed' || fail "forge-verify review_trees must compare with the record's tree, not the tree step 6 printed"
! has '`Run it yourself`' || fail "forge-verify must not take a 'Run it yourself' reply; the sheet's round has no watch mode"
has 'exactly the options `Accept` and `Restart phase <N>`' ||
  fail "forge-verify's unmet question must have exactly the options 'Accept' and 'Restart phase <N>'"
has 'exactly the options `Passed` and `Gap`' ||
  fail "forge-verify's operator question must have exactly the options 'Passed' and 'Gap'"
bp() { section 'Browser pass' | grep -qiE -- "$1"; }
! bp 'deferred[^.]*`Run it yourself`' || fail "forge-verify Browser pass must not gate the deferred steps on 'Run it yourself'"
bp 'deferred[^.]*(headless|browser-driven)|(headless|browser-driven)[^.]*deferred' ||
  fail "forge-verify Browser pass step 2 must run a headless or browser-driven deferred check in the agent run"
s6=${steps#*6. Manual test.}
s6=${s6%%7. Record.*}
s7=${steps#*7. Record.}
s7=${s7%%8. Stop*}
[ "$s6" != "$steps" ] && [ "$s7" != "$steps" ] || fail "forge-verify must keep step 6 Manual test and step 7 Record"
in6() { grep -qiE -- "$1" <<<"$s6"; }
in7() { grep -qiE -- "$1" <<<"$s7"; }
! in6 '`Gaps` \(typed in Other\)' || fail "forge-verify step 6 must drop the bulk result question's Gaps option"
! in6 'ask the result question|result question (again|below)' || fail "forge-verify step 6 must replace the bulk result question with the walkthrough"
in6 'on-device' || fail "forge-verify must start the walkthrough when an on-device step could not be run"
! in6 'deferred steps do not run here' || fail "forge-verify step 6 must run the deferred checks in the agent run"
in6 'agent[- ]owned[^.]*deferred|deferred[^.]*agent[- ](owned|run)' ||
  fail "forge-verify step 6 must run every agent-owned step, deferred checks included, before asking anything"
in6 'in `W`[^.]*`E/s<k>/`' || fail "forge-verify step 6 must run each shell step in W with its output under E/s<k>/"
in6 'agent[- ]owned steps?[^.]*never[^.]*`operator` lines?' || fail "forge-verify agent-owned steps must never become operator lines"
in6 'only[^.]*operator[- ]owned steps' || fail "forge-verify must print only the operator-owned steps as numbered text"
in6 'every line is `met` or `post-ship`[^.]*ask nothing' ||
  fail "forge-verify must ask nothing when every sheet line is met or post-ship"
! in6 'watch mode|`\[watched\]`' || fail "forge-verify must drop watch mode; the operator answers Passed or Gap per operator line"
has '`manual_test`[^.]*`\[agent\]`[^.]*`\[operator\]`[^.]*`\[skipped\]`' ||
  fail "forge-verify manual_test must tag each step [agent], [operator] or [skipped]"
in7 '`manual_test`[^.]*`\[agent\]\[carried\]`' || fail "forge-verify manual_test tag sentence must list [agent][carried]"
has '`\[agent\]`[^.]*`E/s<k>/`' || fail "forge-verify must follow an [agent] tag with its E/s<k>/ evidence paths"
has '`operator_ran`[^.]*true[^.]*`operator` line' || fail "forge-verify must set operator_ran true when an operator line was asked"
! in6 'Step <?k>? of <?n>?' || fail "forge-verify must not present walkthrough steps one at a time as 'Step k of n'"
in6 'first[^.]*setup|setup[^.]*first' || fail "forge-verify must do every setup action it can before presenting a step"
in6 'forge bg' || fail "forge-verify walkthrough setup must start services under forge bg"
in6 'pairing code' || fail "forge-verify walkthrough setup must mint pairing codes or tokens"
in6 'test push' || fail "forge-verify walkthrough setup must send test pushes"
in6 'sudo password' || fail "forge-verify must name a sudo password as an action it cannot do itself"
in6 'external console' || fail "forge-verify must name an external console as an action it cannot do itself"
! in6 '`needs input: ' || fail "forge-verify must not end a turn on a per-step needs input: line; the round asks with AskUserQuestion"
in6 'forge notify' || fail "forge-verify must run forge notify before the round"
in6 'PushNotification' || fail "forge-verify must send PushNotification before the round"
in6 'before the round only' || fail "forge-verify must notify and push once, before the round"
in6 'at most four questions' || fail "forge-verify must ask at most four questions per AskUserQuestion call"
in6 'never one question per walkthrough step' || fail "forge-verify must never ask one question per walkthrough step"
in6 'intent|meaning' || fail "forge-verify must read a typed answer's intent, not keyword syntax"
in6 'database rows' || fail "forge-verify must read the evidence it can reach after each reply"
in6 '`Passed` records[^.]*`\[operator\]`' || fail "forge-verify must record a Passed answer as [operator]"
in6 'contradict' || fail "forge-verify must make a reply that the evidence contradicts a gap"
in6 'skip[^.]*not a gap|not a gap[^.]*skip' || fail "forge-verify must record a skipped step as not a gap"
in6 'skip[^.]*`manual_test`|`manual_test`[^.]*skip' || fail "forge-verify must record a skipped step in manual_test"
in6 'Spec is wrong`?[^.]*step 9' || fail "forge-verify Spec is wrong must end the walkthrough and run step 9's path"
in6 'Spec is wrong`?[^.]*`result`[^.]*`gaps`' || fail "forge-verify Spec is wrong must end the walkthrough with result gaps"
in6 'pass`?[^.]*no answer meant `Spec is wrong`' || fail "forge-verify's round must not record pass after Spec is wrong"
in7 'pass`? only[^.]*no answer or reply meant `Spec is wrong`' || fail "forge-verify step 7 must not record pass after Spec is wrong"
! section Rules | grep -qiE -- 'walkthrough[^.]*plain[- ]text|plain[- ]text repl' ||
  fail "forge-verify Rules must give walkthrough steps no plain-text reply exception; the round asks with AskUserQuestion"
has 'round[^.]*`operator_ran`[^.]*true|`operator_ran`[^.]*true[^.]*round' ||
  fail "forge-verify must set operator_ran true after a round with an operator line"
! in7 'pass` only on' || fail "forge-verify step 7 must drop 'pass only on' the bulk result answer"
in7 'pass`? only (when|if) no step[^.]*gap' || fail "forge-verify step 7 must record pass only when no step left a gap"
in7 'pass`? only[^.]*the round[^.]*ended as its last bullet says' ||
  fail "forge-verify step 7 must record pass only when the round ended as the walkthrough's last bullet says"
in6 '`Accept`[^.]*`done`[^.]*`accepted`' || fail "forge-verify must set done and accepted on an Accept answer"
in6 '`Decision: <text>`' || fail "forge-verify must append a typed change as the phase's Decision: <text>"
in6 '`Gap`[^.]*typed in Other' || fail "forge-verify must take the gap typed in Other"
s5=${steps#*5. Environment.}
s5=${s5%%6. Manual test.*}
[ "$s5" != "$steps" ] || fail "forge-verify must keep step 5 Environment"
in5() { grep -qiE -- "$1" <<<"$s5"; }
! has 'adds a manual-test line saying its build commit could not be checked' ||
  fail "forge-verify step 5 must not add a manual-test line for a build commit it could not check"
in5 'build commit could not be checked[^.]*note|note[^.]*build commit could not be checked' ||
  fail "forge-verify step 5 must make 'build commit could not be checked' a note"
in5 'note[^.]*above the (manual-test )?steps' || fail "forge-verify step 5 must print the build-commit note above the steps"
in5 '(never|not) a manual-test (line|step)' || fail "forge-verify step 5's build-commit note must never be a manual-test step"
in6 '(no|never[^.]*an?) (manual-test )?step[^.]*mockups/<surface>\.html' ||
  fail "forge-verify step 6 must write no step checking a surface against mockups/<surface>.html"
in6 '(drop|skip|ignor)[a-z]*[^.]*mockup[- ]match[^.]*deferred|deferred[^.]*mockup[- ]match[^.]*(drop|skip|ignor)' ||
  fail "forge-verify step 6 must drop a mockup-match entry of a phase's result.json deferred[]"
! in6 'add one step per deferred check' || fail "forge-verify step 6 must not add one step per deferred check"
in6 'identical[^.]*(one|a single) step' || fail "forge-verify step 6 must dedupe identical deferred checks across phases into one step"
in6 '(one|single) step[^.]*(nam|list)[a-z]* (every|each|all)[^.]*phase' ||
  fail "forge-verify step 6's deduped deferred step must name every phase that deferred it"
in6 'deferred check[^.]*serves? a requirement[^.]*fold' ||
  fail "forge-verify step 6 must fold a deferred check that serves a requirement"
in6 'fold[a-z]*[^.]*requirement[^.]*step[^.]*what (the operator|you|they) should see' ||
  fail "forge-verify step 6 must fold a requirement's deferred check into that requirement step's what-you-should-see text"
in6 'only a deferred check[^.]*(covers|serves|covering|serving) no requirement[^.]*own step' ||
  fail "forge-verify step 6 must give only a deferred check covering no requirement its own step"
in6 '\(deferred by phase N' || fail "forge-verify step 6 must keep the (deferred by phase N...) step for a check covering no requirement"
! in6 'with their captured results' || fail "forge-verify step 6 must not print every agent-run step with its captured result"
in6 'one line per requirement' || fail "forge-verify step 6 must print one sheet line per requirement"
! in6 'agent checks passed|agent summary' || fail "forge-verify step 6 must print the sheet, not an agent summary"
bullets=$(sed -E 's/ - ([A-Z])/\n\1/g' <<<"$s6")
for b in '^When every line is `met` or `post-ship`, ask nothing' '^Otherwise ask one round'; do
  grep -qE -- "$b" <<<"$bullets" || fail "forge-verify step 6 lost the branch: $b"
done
in7 'Print the sheet again' || fail "forge-verify step 7 must print the sheet again with each line's answer"
in7 '`manual_test`[^.]*(still )?(records|holds|keeps) every step' ||
  fail "forge-verify F/verify.json manual_test must still record every step with its tag"
! grep -q '^## Ask[[:space:]]*$' "$root/skills/forge-verify/SKILL.md" || fail "forge-verify must not have a ## Ask section; one Rules bullet holds the AskUserQuestion rule"
awk '
  /^## / { rules = /^## Rules[[:space:]]*$/; b = 0; next }
  rules && /^- / { b++ }
  /AskUserQuestion/ { if (!rules) bad = 1; else if (!seen) seen = b; else if (seen != b) bad = 1 }
  END { exit bad || !seen }
' "$root/skills/forge-verify/SKILL.md" ||
  fail "forge-verify must name AskUserQuestion in exactly one ## Rules bullet and nowhere else in SKILL.md"
echo "forge-session-title: ok"
