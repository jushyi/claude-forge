#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export LC_ALL=C

only=${1:-}
fail() { echo "skills: FAIL" >&2; printf '%s\n' "$@" >&2; exit 1; }
ok() { echo "skills $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

skills=(skills/forge-verify/SKILL.md skills/forge-ship/SKILL.md skills/forge-quick/SKILL.md)

skill_text() {
  awk -v root="$root" '
    { print }
    match($0, /Read ~\/\.claude\/skills\/[a-z0-9-]+\/[a-z0-9-]+\.md and follow it\./) {
      p = root "/" substr($0, RSTART + 15, RLENGTH - 30)
      while ((r = (getline l < p)) > 0) print l
      close(p)
      if (r < 0) { print "skills: FAIL\n" FILENAME ":" FNR ": pointer file " p " is missing" > "/dev/stderr"; bad = 1 }
    }
    END { exit bad }
  ' "$1"
}
phase_text=$(skill_text skills/forge-phase/SKILL.md)
verify_text=$(skill_text skills/forge-verify/SKILL.md)
vtext() { printf '%s\n' "$verify_text"; }

ask_rules() {
  awk '
    function flush() { if (b != "" && index(b, "AskUserQuestion")) print b; b = "" }
    /^## / { flush(); in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
    in_rules && /^- / { flush(); b = $0; next }
    in_rules && b != "" && /^[[:space:]]/ { b = b " " $0; next }
    { flush() }
    END { flush() }
  ' <(skill_text "$1") | tr -d '`' | tr -s '[:space:]' ' '
}

check() {
  local out=() f name rule hit rules=()
  for f in "${skills[@]}"; do
    name=${f#skills/forge-}; name=${name%/SKILL.md}
    mapfile -t rules < <(ask_rules "$f")
    if [ "$1" = heading ]; then
      [ "${#rules[@]}" -eq 1 ] \
        || out+=("$f: ${#rules[@]} ## Rules bullets name AskUserQuestion, want exactly one")
      while IFS= read -r hit; do
        out+=("$f: still has a $hit section; the AskUserQuestion Rules bullet replaces it")
      done < <(skill_text "$f" | grep -E '^## (Ask|Escalate)[[:space:]]*$' || true)
      continue
    fi
    if [ "$1" = outside ]; then
      while IFS= read -r hit; do
        out+=("$f: names Ask or Escalate, which ask the operator now replaces: $hit")
      done < <(skill_text "$f" | grep -wE 'Ask|Escalate' || true)
      continue
    fi
    [ "${#rules[@]}" -eq 1 ] || { out+=("$f: no single ## Rules bullet names AskUserQuestion"); continue; }
    rule=${rules[0]}
    case $1 in
      select)
        case "$rule" in
          *'select:PushNotification'*) ;;
          *) out+=("$f: the AskUserQuestion Rules bullet does not load PushNotification with ToolSearch select:PushNotification") ;;
        esac ;;
      order)
        case "$rule" in
          *PushNotification*) ;;
          *) out+=("$f: the AskUserQuestion Rules bullet names no PushNotification") ;;
        esac
        case "${rule##*PushNotification}" in
          *AskUserQuestion*) ;;
          *) out+=("$f: the AskUserQuestion Rules bullet does not call AskUserQuestion after sending PushNotification") ;;
        esac
        [[ ${rule##*PushNotification} =~ no\ (other\ )?tool\ call\ between ]] \
          || out+=("$f: the AskUserQuestion Rules bullet does not call AskUserQuestion right after the push with no tool call between") ;;
      notify)
        case "$rule" in
          *'select:PushNotification'*'forge notify'*PushNotification*AskUserQuestion*) ;;
          *) out+=("$f: the AskUserQuestion Rules bullet does not load PushNotification, run forge notify, send PushNotification, then call AskUserQuestion in that order") ;;
        esac
        for hit in "<project> $name " '200 characters' 'ignored' 'never retried'; do
          case "$rule" in
            *"$hit"*) ;;
            *) out+=("$f: the AskUserQuestion Rules bullet does not name $hit (session title <project> $name ..., a push under 200 characters, a failed notify or push ignored, never retried)") ;;
          esac
        done ;;
      procedure)
        for hit in 'more than (3|three) steps' 'numbered' 'session text' 'one[- ]line'; do
          [[ $rule =~ $hit ]] \
            || out+=("$f: the AskUserQuestion Rules bullet does not state the procedure rule's $hit (a procedure of more than 3 steps is printed first as numbered session text, and the question stays one line)")
        done
        if [ "$name" = verify ]; then
          ! [[ $rule =~ walkthrough.*plain[-\ ]text ]] \
            || out+=("$f: the AskUserQuestion Rules bullet still gives step 6's walkthrough a plain-text reply exception; the sheet's round asks with AskUserQuestion")
        fi ;;
    esac
  done
  [ "${#out[@]}" -eq 0 ] || fail "${out[@]}"
}

if want ask-heading; then
check heading
ok ask-heading
fi

if want ask-only-in-section; then
check outside
ok ask-only-in-section
fi

if want select-push; then
check select
ok select-push
fi

if want push-before-ask; then
check order
ok push-before-ask
fi

if want notify-before-push; then
check notify
ok notify-before-push
fi

if want ask-procedure; then
check procedure
ok ask-procedure
fi

verify_sec() {
  awk -v s="$1" '
    /^## / { in_sec = ($0 == "## " s); next }
    in_sec { printf "%s ", $0 }
  ' <(vtext) | tr -s '[:space:]' ' '
}
infx() { grep -qiE -- "$1" <<<"$fixes"; }
if want verify-inline-fixes; then
fixes=$(verify_sec 'Inline fixes')
[ "$(grep -c '^## Inline fixes[[:space:]]*$' skills/forge-verify/SKILL.md)" -eq 1 ] \
  || fail "skills/forge-verify/SKILL.md: want exactly one ## Inline fixes section"
! grep -qi 'In-place fixes' <(vtext) \
  || fail "skills/forge-verify/SKILL.md: still names In-place fixes, which Inline fixes replaces"
for want in 'review-only' 'open high' 'smoke' '`forge test --stack W`' 'agent-run' 'deferred check' \
  'r = 1, 2' 'F/fixes/<repo>-V<k>.json' 'never two for one file' 'P = `git -C W rev-parse HEAD`' \
  '`FORGE_ROOT=R forge fixes <track>/<feature> --record <git dir>/forge-<feature>-review.json`' '`forge test --changed --base M W`' \
  '`forge test --one <id>`' '`not a defect: `' '`needs plan: `' \
  'F/verify.json' '{"phase": "N", "gap": "<what failed>", "fix": "fixes/<repo>-V<k>.json"}'; do
  case "$fixes" in
    *"$want"*) ;;
    *) fail "skills/forge-verify/SKILL.md: ## Inline fixes does not hold $want (one round loop over smoke, stack, agent-run step, deferred-check and review-only high gaps, one fixer per file, --one reruns of the failing ids, the needs plan and not a defect rules and the fixed record)" ;;
  esac
done
! infx 'walkthrough' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes still takes walkthrough gaps; a Gap answer records a gap that forge next retries"
infx 'never more than 2 inline rounds' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not say never more than 2 inline rounds"
fsent=$(sed 's/\. /.\n/g' <<<"$fixes" | grep -F 'F/fixes/<repo>-V<k>.json' | grep -iE 'from 1' | grep -iE 'within (a|each|one|its) repo' \
  | grep -iE 'rounds and sources' || true)
[ -n "$fsent" ] \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not number F/fixes/<repo>-V<k>.json per repo, k counting from 1 within a repo across rounds and sources"
! grep -qF 'fixes/V<k>.json' <(vtext) \
  || fail "skills/forge-verify: still names the one F/fixes/V<k>.json numbering instead of F/fixes/<repo>-V<k>.json"
! grep -qiF 'across repos, rounds and sources' <(vtext) \
  || fail "skills/forge-verify/SKILL.md: still numbers fix records across repos, rounds and sources instead of per repo"
tr -s '[:space:]' ' ' <agents/forge-fixer.md | grep -qF 'output path `F/fixes/<repo>-V<k>.json`' \
  || fail "agents/forge-fixer.md: a walkthrough gap's output path is not F/fixes/<repo>-V<k>.json"
! grep -qF 'fixes/V<k>.json' agents/forge-fixer.md \
  || fail "agents/forge-fixer.md: still names the output path F/fixes/V<k>.json"
infx '`needs plan: `[^.]*gap at once[^.]*no second round' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not record a needs plan: result as a gap at once with no second round"
infx '`dismissed`[^.]*`not a defect: `[^.]*review finding|review finding[^.]*`not a defect: `' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not limit a not a defect: dismissal to a review finding"
infx '(test|stack|agent-run)[^.]*`not a defect: `[^.]*never close|`not a defect: `[^.]*never close[^.]*(test|stack|agent-run)' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes lets a not a defect: result close a test, stack or agent-run gap"
infx 'the rerun decides' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not let the rerun decide a test, stack or agent-run gap"
infx '`fixed`[^.]*\{"phase": "N", "gap": "<what failed>", "fix": "fixes/<repo>-V<k>\.json"\}' \
  || fail "skills/forge-verify/SKILL.md: ## Inline fixes does not write each closed gap as a fixed item {phase, gap, fix}"
verify_rules=$(verify_sec Rules)
case "$verify_rules" in
  *"The one exception is step 6's background \`forge review <track>/<feature> --base M\`."*) ;;
  *) fail "skills/forge-verify/SKILL.md: Rules' background-review exception is not step 6's background forge review <track>/<feature> --base M alone" ;;
esac
verify_step6=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { in6 = ($0 ~ /^6\. /) }
  in_steps && in6 { printf "%s ", $0 }
' <(vtext) | tr -s '[:space:]' ' ')
case "$verify_step6" in
  *'Then run Inline fixes'*'The sheet.'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not run Inline fixes before the sheet" ;;
esac
verify_step7=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { in7 = ($0 ~ /^7\. /) }
  in_steps && in7 { printf "%s ", $0 }
' <(vtext) | tr -s '[:space:]' ' ')
case "$verify_step7" in
  *'Inline fixes waited for it'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not name Inline fixes for the waited reviews and the forge-reviewer fallback" ;;
esac
ok verify-inline-fixes
fi

at() { local s=${2%%"$1"*}; if [ "$s" = "$2" ]; then echo -1; else echo "${#s}"; fi; }
vstep() {
  awk -v n="$1" '
    /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
    in_steps && /^[0-9]+\. / { in_n = (index($0, n ". ") == 1) }
    in_steps && in_n { printf "%s ", $0 }
  ' <(vtext) | tr -s '[:space:]' ' '
}
vsent() { sed 's/\. /.\n/g' <<<"$1"; }
has_sent() {
  local text=$1 s p
  shift
  s=$(vsent "$text")
  for p in "$@"; do s=$(grep -iE -- "$p" <<<"$s" || true); done
  [ -n "$s" ]
}
rstep() {
  awk -v n="$1" '
    /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
    in_steps && /^[0-9]+\. / { in_n = (index($0, n ". ") == 1) }
    in_steps && in_n { printf "%s ", $0 }
  ' skills/forge-verify/SKILL.md | tr -s '[:space:]' ' '
}
if want verify-steps-inline-fixes; then
fixes=$(verify_sec 'Inline fixes')
v3=$(vstep 3)
v4=$(vstep 4)
v6=$(vstep 6)
v7=$(vstep 7)
v34="$v3 $v4"
fx=$(at 'Inline fixes' "$v34")
sk=$(at 'skip to step 7' "$v34")
[ "$fx" -ge 0 ] || fail "skills/forge-verify/SKILL.md: steps 3-4 do not run Inline fixes on a smoke or stack failure"
[ "$sk" -lt 0 ] || [ "$fx" -lt "$sk" ] \
  || fail "skills/forge-verify/SKILL.md: steps 3-4 skip to step 7 before running Inline fixes"
! grep -qiE 'on any failure,? skip to step 7' <<<"$v34" \
  || fail "skills/forge-verify/SKILL.md: steps 3-4 still skip to step 7 on any failure instead of running Inline fixes first"
vf=skills/forge-verify/SKILL.md
r3=$(rstep 3)
r4=$(rstep 4)
r5=$(rstep 5)
r7=$(rstep 7)
rfix=$(awk '/^## / { in_sec = ($0 == "## Inline fixes"); next } in_sec { printf "%s ", $0 }' "$vf" | tr -s '[:space:]' ' ')
rrules=$(awk '/^## / { in_sec = ($0 == "## Rules"); next } in_sec { printf "%s ", $0 }' "$vf" | tr -s '[:space:]' ' ')
has_sent "$r3" 'one message' 'run_in_background: true' '`forge test --changed --base M W`' '`forge test --stack W`' \
  || fail "$vf: step 3 does not start every repo's \`forge test --changed --base M W\` and every qualifying \`forge test --stack W\` in one message, each with run_in_background: true"
has_sent "$r3" '`- Local stack:`' '`- Stack tests:`' \
  || fail "$vf: step 3 does not limit \`forge test --stack W\` to repos whose TESTING has both \`- Local stack:\` and \`- Stack tests:\`"
grep -qiE 'end(s|ing)? the turn' <<<"$r3" \
  || fail "$vf: step 3 does not end the turn to wait for its background batch"
has_sent "$r3" 'while|alongside' 'build or start' \
  || fail "$vf: step 3 does not run the STACK build or start as a smoke check alongside the background batch"
has_sent "$r3" 'no repo' 'wait' \
  || fail "$vf: step 3 does not say no repo waits on another repo's run"
grep -qiE 'machine-wide run semaphore' <<<"$r3" && grep -qF 'forge-test.lock' <<<"$r3" \
  || fail "$vf: step 3 does not leave concurrency to forge test's machine-wide run semaphore and each W's forge-test.lock"
! grep -qiE 'test.slots?|MemAvailable' <<<"$r3" \
  || fail "$vf: step 3 still leaves concurrency to test slots or MemAvailable admission instead of the run semaphore"
! grep -qF 'in `forge repos` order' <<<"$r3" \
  || fail "$vf: step 3 still runs its tests in \`forge repos\` order instead of one concurrent stage"
grep -qF 'stack_tests' <<<"$r3 $r4" && grep -qF 'exit 5' <<<"$r3 $r4" && grep -qF '<git dir>/forge-stack.log' <<<"$r3 $r4" \
  || fail "$vf: steps 3-4 no longer record each stack run's \`stack_tests\` entry (exit 5 adds none) and name <git dir>/forge-stack.log"
grep -qiE 'one `?forge-fixer`? per failing file per `?W`?' <<<"$r4" \
  || fail "$vf: step 4's fix round does not spawn one forge-fixer per failing file per W"
has_sent "$r4" 'one message' '(across|for) (all|every) (the )?`?W`?' \
  || fail "$vf: step 4 does not spawn the fixers of every W in one message"
grep -qiE 'never two( `?forge-fixer`?s?| fixers)? (on|for) one file' <<<"$r4" \
  || fail "$vf: step 4 does not say never two fixers on one file"
pf=$(at 'per failing file' "$r4")
oa=$(at 'one at a time' "$r4")
has_sent "$r4" 'no file' 'one at a time' && [ "$pf" -ge 0 ] && [ "$oa" -gt "$pf" ] \
  || fail "$vf: step 4 does not run failures naming no file one at a time after the per-file fixers"
grep -qiE 'commit' <<<"$r4" && has_sent "$r4" 'rerun' 'every failed command' 'background' \
  || fail "$vf: step 4 does not commit per W and rerun every failed command together in the background"
has_sent "$r4" 'still open after round 2' 'skip' 'step 7' '"result": "gaps"' \
  || fail "$vf: step 4 does not make a failure still open after round 2 a gap that skips to step 7 with \"result\": \"gaps\""
grep -qE '^5\. Environment\.' <<<"$r5" \
  || fail "$vf: step 5 is no longer Environment"
has_sent "$r4 $r5" 'Environment|step 5' 'only (once|when|after)' 'stage' 'pass' 'fix' \
  || fail "$vf: Environment does not start only once the whole step 3 stage has passed or been fixed"
! grep -qF "step 4's stack tests" <<<"$rrules $rfix" \
  || fail "$vf: Rules or Inline fixes still name step 4's stack tests, which the step 3 stage now runs"
! grep -qF '`forge test --stack W`) of step 4' <<<"$rfix" \
  || fail "$vf: Inline fixes' sources still name the stack tests of step 4 instead of the step 3 stage"
! grep -qF "step 4's entries" <<<"$r7" \
  || fail "$vf: step 7's stack_tests still holds step 4's entries instead of the step 3 stage's"
has_sent "$rfix" 'one at a time' '`?W`?' \
  || fail "$vf: Inline fixes no longer takes review, walkthrough and agent-run sources one W at a time"
fx=$(at 'Inline fixes' "$v34")
b5=$(at 'before step 5' "$v34")
[ "$fx" -ge 0 ] && [ "$b5" -gt "$fx" ] \
  || fail "skills/forge-verify/SKILL.md: steps 3-4 do not run Inline fixes on their failures before step 5's environment"
grep -qE 'after round 2[^.]*skip(s|ping)? to step 7|still open after (round 2|2 (inline )?rounds)[^.]*skip(s|ping)? to step 7' <<<"$v34" \
  || fail "skills/forge-verify/SKILL.md: steps 3-4 do not skip to step 7 only for a failure still open after round 2"
grep -qF 'list the failed commands as the manual test' <<<"$v34" \
  || fail "skills/forge-verify/SKILL.md: steps 3-4 no longer list the failed commands as the manual test when they skip to step 7"
grep -qiE 'reruns? (only the failed commands|every failed command)' <<<"$v34 $fixes" \
  || fail "skills/forge-verify/SKILL.md: a step 3-4 Inline fixes round does not rerun only or every failed command"
grep -qE '[Ff]ailed (agent-run )?(manual-test )?step[^.]*Inline fixes' <<<"$v6" \
  || fail "skills/forge-verify/SKILL.md: step 6 does not send a failed agent-run step or deferred check to Inline fixes"
grep -qE 'gap of the round goes to no fixer' <<<"$v6" \
  || fail "skills/forge-verify/SKILL.md: step 6 still sends a Gap answer to a fixer instead of recording it for forge next"
! grep -qF 'Step <k> of <n>' <<<"$v6 $fixes" \
  || fail "skills/forge-verify/SKILL.md: still presents walkthrough steps one at a time as \`Step <k> of <n>\`"
grep -qF '`needs plan: `' <<<"$v7" \
  || fail "skills/forge-verify/SKILL.md: step 7 does not record a needs plan: result as a gap"
grep -qE 'after 2 (inline )?rounds|after round 2' <<<"$v7" \
  || fail "skills/forge-verify/SKILL.md: step 7 does not record a gap only when it is still open after 2 inline rounds"
grep -qE '`fixed`' <<<"$v7" \
  || fail "skills/forge-verify/SKILL.md: step 7 does not write gaps closed inline to F/verify.json fixed"
grep -qE '`gaps` (keeps|holds) only open gaps' <<<"$v7" \
  || fail "skills/forge-verify/SKILL.md: step 7's gaps does not keep only open gaps"
! grep -qF 'holds every gap of this session' <<<"$v7" \
  || fail "skills/forge-verify/SKILL.md: step 7's gaps still holds every gap of this session, closed ones included"
ok verify-steps-inline-fixes
fi

step_refs() {
  awk -v RS='\001' '{
    s = "\n" $0
    gsub(/\n## [^\n]*/, "", s)
    gsub(/[[:space:]]+/, " ", s)
    re = "(Browser pass |present )?[Ss]teps? [0-9]+((-| or | and )[0-9]+)?(\047s)?( [^ ]+)?( [^ ]+)?( [^ ]+)?"
    while (match(s, re)) {
      m = substr(s, RSTART, RLENGTH)
      print m
      s = substr(s, RSTART + index(m, "tep") + 2)
    }
  }' "$1"
}
step_role() {
  local w
  for w in $1; do
    case "$w" in
      stage|smoke|stack|changed|entries) echo 'Smoke test'; return ;;
      rounds|fixes) echo 'Stage fixes'; return ;;
      environment|build) echo 'Environment'; return ;;
      walkthrough|agent|ownership|sheet|final|review|background) echo 'Manual test'; return ;;
      rules) echo 'Record'; return ;;
      path) echo 'Next'; return ;;
    esac
  done
}
if want verify-step-refs; then
vd=skills/forge-verify
vtitles=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { t = substr($0, index($0, " ") + 1); sub(/[.:].*/, "", t); print ($0 + 0) "\t" t }
' "$vd/SKILL.md")
[ -n "$vtitles" ] || fail "$vd/SKILL.md: no numbered steps under ## Steps"
vtitle() { awk -F '\t' -v n="$1" '$1 == n { print $2 }' <<<"$vtitles"; }
nsteps=$(wc -l <<<"$vtitles")
nbrowser=$(awk '/^[0-9]+\. / { n = $0 + 0 } END { print n + 0 }' "$vd/browser-pass.md")
bad=()
for f in "$vd"/*.md; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "${f##*/}:$ref" in
      browser-pass.md:*'step 2 leaves'*|walkthrough.md:'present step 1'*) continue ;;
    esac
    core=$(grep -oE '[Ss]teps? [0-9]+((-| or | and )[0-9]+)?' <<<"$ref" | head -n 1)
    nums=$(grep -oE '[0-9]+' <<<"$core")
    if [[ $core =~ ([0-9]+)-([0-9]+) ]]; then nums=$(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); fi
    case "$ref" in
      "Browser pass "*) max=$nbrowser; ns='Browser pass' ;;
      *) max=$nsteps; ns='## Steps' ;;
    esac
    for n in $nums; do
      [ "$n" -ge 1 ] && [ "$n" -le "$max" ] || bad+=("$f: \`$ref\` cites step $n, which $ns does not have")
    done
    [ "$ns" = '## Steps' ] || continue
    tail=${ref#*"$core"}
    case "$tail" in
      "'s "*)
        words=$(sed "s/^'s //; s/[\`\"(),.:;]//g; s/-/ /g" <<<"$tail" | tr '[:upper:]' '[:lower:]' | awk '{ print $1, $2, $3 }')
        role=$(step_role "$words")
        for n in $nums; do
          [ -z "$role" ] || [ "$(vtitle "$n")" = "$role" ] \
            || bad+=("$f: \`$ref\` cites step $n for its ${words%% *}, which is step $(awk -F '\t' -v t="$role" '$2 == t { print $1 }' <<<"$vtitles") ($role); step $n is $(vtitle "$n")")
        done ;;
      " failure"*)
        for n in $nums; do
          case "$(vtitle "$n")" in
            'Smoke test'|'Stage fixes') ;;
            *) bad+=("$f: \`$ref\` cites a step $n failure, but step $n is $(vtitle "$n"), not the step 3-4 test stage") ;;
          esac
        done ;;
    esac
  done < <(step_refs "$f")
done
[ "${#bad[@]}" -eq 0 ] || fail "${bad[@]}"
fr=$vd/fix-reruns.md
cross=$(awk -v RS= '/cross-repo rerun/' "$fr" | tr '\n' ' ' | tr -s ' ')
[ -n "$cross" ] || fail "$fr: no paragraph holds the cross-repo rerun"
! grep -qE "step 4's stack tests|as step 4 runs them" <<<"$cross" \
  || fail "$fr: the cross-repo rerun still reruns step 4's stack tests as step 4 runs them, but step 3's merged stage runs the stack tests now"
grep -qE "step 3's ([A-Za-z-]+ ){0,2}stage" <<<"$cross" \
  || fail "$fr: the cross-repo stack rerun does not name step 3's merged test stage"
grep -qE "step 4's ([A-Za-z-]+ ){0,2}rounds" <<<"$cross" \
  || fail "$fr: the cross-repo stack rerun does not name step 4's per-file rounds"
has_sent "$cross" "before step 5's environment" "step 4's" \
  || fail "$fr: the cross-repo rerun for step 4's fixes no longer runs before step 5's Environment"
grep -qF 'Skip that cross-repo rerun only when exactly one repo' <<<"$cross" \
  && grep -qF '`- Local stack:`' <<<"$cross" && grep -qF '`- Stack tests:`' <<<"$cross" \
  || fail "$fr: the cross-repo rerun lost its skip rule (exactly one repo with both \`- Local stack:\` and \`- Stack tests:\`)"
ok verify-step-refs
fi

if want verify-owed-checks; then
v6=$(vstep 6)
v7=$(vstep 7)
vf=skills/forge-verify/SKILL.md
grep -qF '`[owed]`' <<<"$v6" \
  || fail "$vf: step 6 does not tag a deferred check that cannot be observed before ship \`[owed]\`"
has_sent "$v6" 'before ship' 'merge to main' 'deploy' 'port or golive' 'release' 'production traffic' \
  || fail "$vf: step 6 does not define an owed check as one whose pass needs the merge to main, a deploy, a port or golive, a release, or production traffic or time after release"
has_sent "$v6" 'owed' 'never runs?,? walks?,? or fix' \
  || fail "$vf: step 6 does not say verify never runs, walks or fixes an \`[owed]\` check"
has_sent "$v6 $v7" 'owed' 'never (makes it a |becomes a |is a )?gap' \
  || fail "$vf: an \`[owed]\` check is not stated to never become a gap"
has_sent "$v6" 'folded' 'owed' 'other parts' \
  || fail "$vf: step 6 does not leave a requirement step's other parts judged as today when an owed check is folded into it"
has_sent "$v7" '`\[skipped\]`' '`\[owed\]`' \
  || fail "$vf: step 7's manual_test step tags do not include \`[owed]\`"
has_sent "$v7" '`result`' 'ignor' '`\[owed\]`' \
  || fail "$vf: step 7 does not state that \`result\` ignores \`[owed]\` steps so they never block \`pass\`"
grep -qF '`- <today> <check> (owed after ship, <feature> verify, deferred by phase N)`' <<<"$v7" \
  || fail "$vf: step 7 does not append the owed todo line \`- <today> <check> (owed after ship, <feature> verify, deferred by phase N)\`"
has_sent "$v7" 'owed after ship' 'no requirement' \
  || fail "$vf: step 7 does not limit the owed todo line to an \`[owed]\` step covering no requirement"
has_sent "$v7" 'owed' 'folded' 'no todo|none' \
  || fail "$vf: step 7 does not say an owed check folded into a requirement step adds no todo line"
has_sent "$v7" 'docs\(todo\)' 'any todo line' \
  || fail "$vf: step 7 commits R/.forge/todo.md only for Browser pass findings, not whenever any todo line was written"
ok verify-owed-checks
fi

if want verify-clears-sessions; then
verify_step5=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { in5 = ($0 ~ /^6\. /) }
  in_steps && in5 { printf "%s ", $0 }
' <(vtext) | tr -s '[:space:]' ' ')
clean_cmd='`FORGE_ROOT=R forge clean --sessions <track>/<feature>`'
[ -n "$verify_step5" ] || fail "skills/forge-verify/SKILL.md: no step 6 under ## Steps"
case "$verify_step5" in
  *"$clean_cmd"*"- When every line is"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not run $clean_cmd before the sheet" ;;
esac
ok verify-clears-sessions
fi

if want verify-phase-unmet; then
vf=skills/forge-verify/SKILL.md
v6=$(vstep 6)
has_sent "$v6" 'unmet\[\]' '`<P>/result\.json`' 'every numbered phase' \
  || fail "$vf: step 6 does not read \`unmet[]\` from every numbered phase's \`<P>/result.json\`"
grep -qF '`{"phase": "N", "gap": "unmet <task>: <reason>"}`' <<<"$v6" \
  || fail "$vf: step 6 does not record each phase's unmet entry as the gap \`{\"phase\": \"N\", \"gap\": \"unmet <task>: <reason>\"}\`"
has_sent "$v6" 'unmet' 'sync' 'not merged' \
  || fail "$vf: step 6 does not say a \`sync\` unmet entry means the phase branch is not merged into the feature branch"
has_sent "$v6" 'unmet' 'no fixer' 'never .*pass' \
  || fail "$vf: step 6 does not keep an unmet gap open with no fixer, so \`result\` is never \`pass\` while one stands"
grep -qF '`unmet <ID> (phase <N>): unmet <task>: <reason>`' <<<"$v6" \
  || fail "$vf: step 6 does not print a phase's unmet entry as the sheet line \`unmet <ID> (phase <N>): unmet <task>: <reason>\`"
ok verify-phase-unmet
fi

if want verify-sheet; then
vf=skills/forge-verify/SKILL.md
v6=$(vstep 6)
v7=$(vstep 7)
for want in '`met <ID>: <evidence path>`' '`unmet <ID> (phase <N>): <reason>`' '`operator <ID>: <the step text>`' \
  '`post-ship <ID>: owed`' 'one line per requirement' 'conflicted paths' '`step <k>` in place of the ID' \
  "A failed step's gap enters \`gaps\` only through its line's answer."; do
  case "$v6" in
    *"$want"*) ;;
    *) fail "$vf: step 6's sheet does not hold $want" ;;
  esac
done
has_sent "$v6" 'every line is `met` or `post-ship`' 'ask nothing' '`pass`' '`operator_ran` is false' \
  || fail "$vf: step 6 does not pass with operator_ran false and no question when every line is met or post-ship"
has_sent "$v6" '`unmet` line' 'exactly the options `Accept` and `Restart phase <N>`' \
  || fail "$vf: an unmet line's question does not have exactly the options Accept and Restart phase <N>"
has_sent "$v6" '`operator` line' 'exactly the options `Passed` and `Gap`' 'typed in Other' \
  || fail "$vf: an operator line's question does not have exactly the options Passed and Gap, the gap typed in Other"
has_sent "$v6" 'at most four questions' 'further calls' \
  || fail "$vf: the round does not cap each AskUserQuestion call at four questions with further calls for the rest"
has_sent "$v6" 'never one question per walkthrough step' \
  || fail "$vf: the round still asks one question per walkthrough step"
has_sent "$v6" 'operator-owned steps once as numbered text' \
  || fail "$vf: step 6 does not print the operator-owned steps once as numbered text before the round"
has_sent "$v6" '`Accept`' '`done` to `true`' '`accepted`' 'F/requirements.json' 'unmet` entry stays as recorded' \
  || fail "$vf: an Accept answer does not set done true and accepted in F/requirements.json while the phase's unmet entry stays"
has_sent "$v6" '`Restart phase <N>`' '\{"phase": "N", "gap":' \
  || fail "$vf: a Restart phase <N> answer does not record a gap tagged with that phase"
has_sent "$v6" '`Decision: <text>`' 'spec.json' 'F/split.json' '`forge next`' \
  || fail "$vf: a typed change is not appended to the phase's spec.json and F/split.json as Decision: <text> before forge next"
has_sent "$v6" '`Gap`' 'gap tagged' \
  || fail "$vf: a Gap answer does not record a gap tagged with a phase"
has_sent "$v6" 'skip' '`\[skipped\]`' 'not a gap' \
  || fail "$vf: an answer meaning skip does not record the line [skipped], not a gap"
has_sent "$v7" "a step's gap only when its \`unmet\` line took \`Restart phase <N>\`" \
  || fail "$vf: step 7 still records a step's gap whose unmet line the operator accepted"
has_sent "$v7" '`\[operator\]`' '`unmet`' "accepted: <operator's words>" \
  || fail "$vf: step 7 does not record an accepted unmet line as [operator] ending — accepted: <operator's words>"
for gone in 'Accept the agent run' 'I will test it myself' '`Ready`' 'Change steps' 'Step <k> of <n>' 'Watch mode' \
  '`[watched]`' 'needs input: confirm' 'Run it yourself' 'plain-text repl' 'agent summary'; do
  bad=$(grep -nF -- "$gone" skills/forge-verify/*.md || true)
  [ -z "$bad" ] || fail "skills/forge-verify: still holds \`$gone\`, a handshake the sheet replaces:" "$bad"
done
jq -e '.properties.requirements.items.properties.accepted.type == "string"' schemas/requirements.schema.json >/dev/null \
  || fail "schemas/requirements.schema.json: a requirement has no optional accepted string"
ok verify-sheet
fi

phase_rules() {
  rules=$(awk '
    /^## / { in_sec = ($0 ~ /^## Rules[[:space:]]*$/); next }
    in_sec && /^- / { printf "\n" }
    in_sec { printf "%s ", $0 }
  ' skills/forge-phase/SKILL.md | tr -s ' \t' ' ')
  [ -n "$rules" ] || fail "skills/forge-phase/SKILL.md: no ## Rules section"
}
phase_park() {
  phase_rules
  park=$(grep -F 'FORGE_ROOT=R forge event N park' <<<"$rules" || true)
  [ -n "$park" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no rule logging \`FORGE_ROOT=R forge event N park <cond>\`"
}
if want park-rule; then
phase_park
for want in '`wait <ref>`' '`<abs-root>:<N>`' '`<track>/<feature>`' '`branch <name>`' 'P/result.json' 'result: Phase N parked on'; do
  case "$park" in
    *"$want"*) ;;
    *) fail "skills/forge-phase/SKILL.md: the park rule does not name $want" ;;
  esac
done
for bad in '`slot`' '`memory`' '`load`' 'MemAvailable' 'gave up waiting'; do
  case "$park" in
    *"$bad"*) fail "skills/forge-phase/SKILL.md: the park rule still names $bad; a phase parks only on \`wait <ref>\`" ;;
  esac
done
ok park-rule
fi

if want wake-rule; then
phase_rules
wake=$(grep -F 'forge watchdog: <cond> cleared; continue phase <N> from where it parked' <<<"$rules" || true)
[ -n "$wake" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no rule for the prompt \`forge watchdog: <cond> cleared; continue phase <N> from where it parked\`"
case "$wake" in
  *"first step whose output is missing"*) ;;
  *) fail "skills/forge-phase/SKILL.md: the wake rule does not continue at the first step whose output is missing" ;;
esac
grep -qF 'already has a running session' <<<"$rules" || fail "skills/forge-phase/SKILL.md: ## Rules lost the peer-session check"
ok wake-rule
fi

if want phase-mockup-not-deferred; then
phase_rules
defer=$(grep -F 'FORGE_ROOT=R forge event N deferred' <<<"$rules" || true)
[ -n "$defer" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no human-only rule logging \`FORGE_ROOT=R forge event N deferred\`"
mock=$(sed 's/\. /.\n/g' <<<"$defer" | grep -iE -A1 'mockup' | tr '\n' ' ' || true)
[ -n "$mock" ] || fail "skills/forge-phase/SKILL.md: the human-only deferral rule does not name a mockup-match check"
grep -qE '\bnot\b' <<<"$mock" \
  || fail "skills/forge-phase/SKILL.md: the human-only deferral rule does not say a mockup-match check is not a human-only check" "$mock"
grep -E 'never' <<<"$mock" | grep -qF '`deferred`' \
  || fail "skills/forge-phase/SKILL.md: the human-only deferral rule does not say a mockup-match check is never logged as a \`deferred\` event" "$mock"
ok phase-mockup-not-deferred
fi

if want retest-rule; then
phase_rules
retest=$(grep -F 'FORGE_ROOT=R forge event N retest' <<<"$rules" || true)
[ -n "$retest" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no rule logging \`FORGE_ROOT=R forge event N retest \"<step> <attempt>\"\`"
grep -qE 'exits? 75' <<<"$retest" || fail "skills/forge-phase/SKILL.md: the retest rule does not name exit 75"
grep -qE 'up to 3 |3 reruns|third rerun' <<<"$retest" || fail "skills/forge-phase/SKILL.md: the retest rule does not cap reruns at 3"
for want in 'forge: tests passed' 'forge: tests failed'; do
  case "$retest" in
    *"$want"*) ;;
    *) fail "skills/forge-phase/SKILL.md: the retest rule does not name $want" ;;
  esac
done
ok retest-rule
fi

if want checkpoint-tests; then
phase_park
case "$park" in
  *'`wait <ref>`'*) ;;
  *) fail "skills/forge-phase/SKILL.md: the park rule does not name \`wait <ref>\`" ;;
esac
phase_flat=$(tr '\n' ' ' <skills/forge-phase/SKILL.md | tr -s '[:space:]' ' ')
for bad in 'gave up waiting for test memory' 'gave up waiting for a test slot' 'gave up waiting for CPU pressure' '`slot`' '`memory`' '`load`' 'test slot' 'memory admission'; do
  case "$phase_flat" in
    *"$bad"*) fail "skills/forge-phase/SKILL.md: still names $bad; forge test waits on its run semaphore and a phase parks only on \`wait <ref>\`" ;;
  esac
done
[ "$(grep -oF 'one machine-wide test run slot' <<<"$phase_flat" | wc -l)" -ge 2 ] \
  || fail "skills/forge-phase/SKILL.md: the task test rule and the proof loop do not both say forge test takes one machine-wide test run slot"
! grep -qF 'takes no test slot' skills/forge-phase/SKILL.md || fail "skills/forge-phase/SKILL.md: still says forge test --one takes no test slot"
step2=$(awk '/^2\. Tasks\./{f=1} /^3\. /{f=0} f' skills/forge-phase/SKILL.md | tr '\n' ' ' | tr -s ' ')
grep -qF "Trust the agent's recorded run" <<<"$step2" || fail "skills/forge-phase/SKILL.md: step 2 does not trust the agent's recorded test run"
grep -qF 'equal to W' <<<"$step2" && fail "skills/forge-phase/SKILL.md: step 2 still reruns a task test whose recorded tree differs from W's"
grep -qE '(^| )- 7:' <<<"$step2" && fail "skills/forge-phase/SKILL.md: step 2 still has a forge task-done exit 7 park line"
ok checkpoint-tests
fi

if want phase-retry-replans-plan; then
phase=skills/forge-phase/SKILL.md
after_retry='last `retry` or `replan` event[^.]*(follows|after) the last `check` event'
resume=$(awk '
  function flush() { gsub(/[[:space:]]+/, " ", b); if (b ~ /Start at the first step whose output is missing/) print b; b = "" }
  /^## / { if (r) flush(); r = ($0 ~ /^## Rules[[:space:]]*$/); next }
  r && /^- / { flush() }
  r { b = b " " $0 }
  END { if (r) flush() }
' "$phase" | tr -s '[:space:]' ' ')
[ -n "$resume" ] || fail "$phase: ## Rules has no resume rule starting at the first step whose output is missing"
grep -qE "$after_retry" <<<"$resume" \
  || fail "$phase: the resume rule does not treat the plan as missing when the last \`retry\` or \`replan\` event in P/events.jsonl follows the last \`check\` event" "$resume"
step1=$(awk '/^1\. Plan\./{f=1} /^2\. /{f=0} f' "$phase" | tr -s '[:space:]' ' ')
[ -n "$step1" ] || fail "$phase: no step 1 Plan under ## Steps"
grep -qE "$after_retry" <<<"$step1" \
  || fail "$phase: step 1 does not spawn forge-planner when the last \`retry\` or \`replan\` event follows the last \`check\` event, even though P/plan.json exists" "$step1"
retry_prompt=${step1#*'`retry` or `replan` event, the prompt also says:'}
[ "$retry_prompt" != "$step1" ] || fail "$phase: step 1 lost its retry/replan prompt paragraph"
retry_prompt=${retry_prompt%%'Run `FORGE_ROOT=R forge check N`'*}
for want in 'revise the existing `P/plan.json`' 'keep finished tasks' 'IDs' '`P/tasks/`' 'add tasks only for what the `Gap:` lines need'; do
  case "$retry_prompt" in
    *"$want"*) ;;
    *) fail "$phase: step 1's retry/replan prompt does not say \`$want\` (revise the existing plan, keep finished tasks with their IDs and records in P/tasks/, add tasks only for the Gap: lines)" "$retry_prompt" ;;
  esac
done
ok phase-retry-replans-plan
fi

skill_step() {
  awk -v n="$2" '
    /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
    in_steps && /^[0-9]+\. / { in_n = (n == "" || index($0, n ". ") == 1) }
    in_steps && in_n { printf "%s ", $0 }
  ' "$1" | tr -s '[:space:]' ' '
}

if want verify-starts-review; then
verify_step5=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { in5 = ($0 ~ /^6\. /) }
  in_steps && in5 { printf "%s ", $0 }
' <(vtext) | tr -s '[:space:]' ' ')
clean_cmd='`FORGE_ROOT=R forge clean --sessions <track>/<feature>`'
[ -n "$verify_step5" ] || fail "skills/forge-verify/SKILL.md: no step 6 under ## Steps"
review_cmd='`FORGE_ROOT=R forge review <track>/<feature> --base M --out <git dir>/forge-<feature>-review.json`'
diff_cmd='git diff M...forge/<track>-<feature>'
case "$verify_step5" in
  *"$diff_cmd"*"$clean_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not write $diff_cmd to W's git dir before the manual test" ;;
esac
case "$verify_step5" in
  *"$review_cmd"*"$clean_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not start $review_cmd before the manual test" ;;
esac
case "$verify_step5" in
  *"run_in_background: true"*"$clean_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not start the review with run_in_background: true" ;;
esac
case "$verify_step5" in
  *'HEAD^{tree}'*"$clean_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not record W's HEAD^{tree} as the reviewed tree" ;;
esac
case "$verify_step5" in
  *'<git dir>/forge-<feature>-review.prev.json'*"$review_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6 does not move an earlier forge-<feature>-review.json to forge-<feature>-review.prev.json before $review_cmd" ;;
esac
case "$verify_step5" in
  *'F/review.json'*) fail "skills/forge-verify/SKILL.md: step 6 still removes or moves F/review.json, which --out replaces" ;;
esac
ok verify-starts-review
fi

if want verify-review-exception; then
verify_rule=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { if (hit) exit; cur = "" }
  in_rules { cur = cur $0 " "; if (index($0, "forge test --changed --base M W")) hit = 1 }
  END { if (hit) print cur }
' <(vtext) | tr -s '[:space:]' ' ')
case "$verify_rule" in
  *"forge test --changed --base M W"*"forge review"*|*"forge review"*"forge test --changed --base M W"*) ;;
  *) fail "skills/forge-verify/SKILL.md: the forge test --changed --base M W rule does not name the background forge review as its exception" ;;
esac
ok verify-review-exception
fi

if want verify-rules-first-changed-run; then
verify_rules=$(verify_sec Rules)
grep -qiE 'phases ran only their tasks.? own tests[^.]*fixers.? `--one` runs' <<<"$verify_rules" \
  || fail "skills/forge-verify/SKILL.md: Rules do not say the phases ran only their tasks' own tests and fixers' \`--one\` runs"
grep -qiE 'step 3.?s `forge test --changed --base M W`[^.]*first changed-tests run' <<<"$verify_rules" \
  || fail "skills/forge-verify/SKILL.md: Rules do not say step 3's \`forge test --changed --base M W\` is the feature's first changed-tests run"
ok verify-rules-first-changed-run
fi

if want verify-narrow-rerun; then
sent_has() {
  local text=$1 s w hit
  shift
  while IFS= read -r s; do
    hit=1
    for w in "$@"; do
      case "$s" in *"$w"*) ;; *) hit=0; break ;; esac
    done
    [ "$hit" -eq 0 ] || return 0
  done < <(sed 's/\. /.\n/g' <<<"$text")
  return 1
}
one_cmd='forge test --one <id>'
p_cmd='forge test --changed --base P W'
m_cmd='forge test --changed --base M W'
case "$verify_text" in
  *"$one_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: verify never reruns a failing test id with \`$one_cmd\`" ;;
esac
case "$verify_text" in
  *"$p_cmd"*) fail "skills/forge-verify/SKILL.md: verify still runs the fix diff's tests with \`$p_cmd\`; a fix reruns only its failing ids with \`$one_cmd\`" ;;
esac
case "$(verify_sec Rules)" in
  *"After a fixer commit, rerun only the failing test ids with \`$one_cmd\`."*) ;;
  *) fail "skills/forge-verify/SKILL.md: Rules do not say a fixer commit reruns only the failing test ids with \`$one_cmd\`" ;;
esac
pre_rule=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { in_pre = ($0 ~ /^- Pre-existing failures:/) }
  in_rules && in_pre { printf "%s ", $0 }
' <(vtext) | tr -s '[:space:]' ' ')
sent_has "$pre_rule" 'only' 'step 3' '--base M' \
  || fail "skills/forge-verify/SKILL.md: Rules' Pre-existing failures does not limit pre-existing ids to those the step 3 \`--base M\` run named"
fixes=$(verify_sec 'Inline fixes')
case "$fixes" in
  *"$one_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: Inline fixes does not rerun each failing test id with \`$one_cmd\`" ;;
esac
sent_has "$fixes" 'forge test --one' '- Test:' \
  || fail "skills/forge-verify/SKILL.md: Inline fixes does not run \`forge test --one\` only where W's TESTING has a \`- Test:\` line accepting the id"
! sent_has "$fixes" 'P..HEAD' 'TESTING.md' "$m_cmd" \
  || fail "skills/forge-verify/SKILL.md: Inline fixes still falls back to \`$m_cmd\` when the fix diff touches .forge/TESTING.md"
step4=$(skill_step skills/forge-verify/SKILL.md 4)
case "$step4" in
  *"$one_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 4's rerun does not rerun each failing id with \`$one_cmd\` after the fixer commit" ;;
esac
grep -qE 'P = `?git -C W rev-parse HEAD' <<<"$step4" \
  || fail "skills/forge-verify/SKILL.md: step 4 does not note the pre-fix commit P = \`git -C W rev-parse HEAD\` before its fixers"
step6=$(skill_step skills/forge-verify/SKILL.md 6)
case "$step6" in
  *"$m_cmd"*) fail "skills/forge-verify/SKILL.md: step 6 still reruns \`$m_cmd\` after a fix" ;;
esac
walk=$(tr -s '[:space:]' ' ' <skills/forge-verify/walkthrough.md)
case "$walk" in
  *"forge-fixer"*|*"forge test"*) fail "skills/forge-verify/walkthrough.md: the round runs no fixer and no test; a Gap answer is a gap forge next retries" ;;
esac
ok verify-narrow-rerun
fi

if want verify-records-review-trees; then
verify_step6=$(skill_step <(vtext) 7)
commit_cmd='`FORGE_ROOT=R forge commit <track>/<feature> verify`'
[ -n "$verify_step6" ] || fail "skills/forge-verify/SKILL.md: no step 7 under ## Steps"
case "$verify_step6" in
  *"\`review_trees[<repo>]\` to the repo record's \`tree\`"*"$commit_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not set review_trees[<repo>] to the repo record's tree before $commit_cmd" ;;
esac
case "$verify_step6" in
  *'Ship copies the record as it stands.'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not say ship copies the record as it stands" ;;
esac
case "$verify_step6" in
  *'review_trees'*"$commit_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not write review_trees to F/verify.json before $commit_cmd" ;;
esac
case "$verify_step6" in
  *'review_trees'*'`<repo>: findings: ...`'*'`forge-reviewer`'*"$commit_cmd"*|*'review_trees'*'`forge-reviewer`'*'`<repo>: findings: ...`'*"$commit_cmd"*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not set review_trees only for a repo whose review printed findings or had the forge-reviewer fallback run" ;;
esac
every_repo=$(sed 's/\. /.\n/g' <<<"$verify_step6" | grep -F 'forge repos' | grep -F 'review_trees' | grep -F 'gap' || true)
[ -n "$every_repo" ] || fail "skills/forge-verify/SKILL.md: step 7 does not record pass only when every repo of forge repos <track>/<feature> has a review_trees entry, the missing review being a gap"
ok verify-records-review-trees
fi

if want verify-review-fallback; then
verify_fallback="$(skill_step <(vtext) 6) $(skill_step <(vtext) 7)"
case "$verify_fallback" in
  *'`codex: <cause>`'*'`forge-reviewer`'*'review_trees[<repo>]'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6/7 does not run the forge-reviewer fallback on a \`codex: <cause>\` line before setting review_trees[<repo>]" ;;
esac
case "$verify_fallback" in
  *'no `<repo>: findings: ...` line'*'`forge-reviewer`'*'review_trees[<repo>]'*|*'no `findings:` line'*'`forge-reviewer`'*'review_trees[<repo>]'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6/7 does not run the forge-reviewer fallback on a review with no findings: line before setting review_trees[<repo>]" ;;
esac
case "$verify_fallback" in
  *'`forge-reviewer`'*'F/spec.json'*'F/review/reviewer-<repo>.json'*'review_trees[<repo>]'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6/7's forge-reviewer fallback is not given F/spec.json and F/review/reviewer-<repo>.json before review_trees[<repo>] is set" ;;
esac
case "$verify_fallback" in
  *'`forge-reviewer`'*'`source`'*'`reviewer`'*'HEAD^{tree}'*'review_trees[<repo>]'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 6/7's forge-reviewer fallback does not append its findings with source reviewer and set the record's tree to HEAD^{tree} before review_trees[<repo>] is set" ;;
esac
ok verify-review-fallback
fi

if want verify-review-par; then
vs=skills/forge-verify/SKILL.md
s6=$(skill_step <(vtext) 6)
s6fixes="$s6 $(verify_sec 'Inline fixes')"
fixes=$(verify_sec 'Inline fixes')
fb=$(tr -s '[:space:]' ' ' < skills/forge-verify/reviewer-fallback.md)
in6() { grep -qiE -- "$1" <<<"$s6"; }
in6fx() { grep -qiE -- "$1" <<<"$s6fixes"; }
[ -n "$s6" ] || fail "$vs: no step 6 under ## Steps"
in6 'one (background )?Bash command per `W`' || fail "$vs: step 6 does not start one background Bash command per W"
in6 'all in one message' || fail "$vs: step 6 does not start the per-W review commands all in one message"
in6 'run_in_background: true' || fail "$vs: step 6 does not start the per-W review commands with run_in_background: true"
! in6 'one at a time|never two concurrently' || fail "$vs: step 6 still takes the Ws one at a time"
for want in '`FORGE_ROOT=R forge review <track>/<feature> --base M --out <git dir>/forge-<feature>-review.json`' \
  'git diff M...forge/<track>-<feature>' '<git dir>/forge-<feature>.diff' '`<repo>: tree' \
  '<git dir>/forge-<feature>-review.prev.json' '--prior <git dir>/forge-<feature>-review.prev.json'; do
  case "$s6" in
    *"$want"*) ;;
    *) fail "$vs: step 6's per-W command does not hold $want" ;;
  esac
done
in6 'prefix[^.]*`<repo>: `' || fail "$vs: step 6 does not prefix every output line with <repo>: "
! in6 'F/review\.json' || fail "$vs: step 6 still removes or moves F/review.json, which --out replaces"
! grep -qF 'rm -f F/review.json' <(vtext) || fail "$vs: still runs rm -f F/review.json, which --out and forge fixes --record replace"
! grep -qF 'F/review/reviewer.json' <(vtext) || fail "$vs: still names F/review/reviewer.json, not the per-repo F/review/reviewer-<repo>.json"
in6fx 'no `(<repo>: )?findings:( \.\.\.)?` line[^.]*`codex: <exit or error>`' \
  || fail "$vs: a review command that ended with no <repo>: findings: line does not count as codex: <exit or error>"
in6fx "while other (repos|\`W\`s)'? (final )?reviews? (still )?run" \
  || fail "$vs: a W's Inline fixes rounds do not start when its own review ends, while other repos' reviews still run"
in6fx 'commit nothing in (a |that |each )?`W` while its own (final )?review runs' \
  || fail "$vs: does not say commit nothing in a W while its own review runs"
! in6fx 'at most one review runs per worktree' \
  || fail "$vs: still limits a worktree to one review at a time, a rule only the removed re-review needed"
! grep -qiF 'take the `W`s one at a time' <<<"$fixes" || fail "$vs: Inline fixes still takes the Ws one at a time"
grep -qiE 'independently of' <<<"$fixes" || fail "$vs: Inline fixes rounds r = 1, 2 do not run per W independently of the other Ws"
! grep -qF 'F/review.json' <<<"$fixes" || fail "$vs: Inline fixes still copies or moves F/review.json"
case "$fixes" in
  *'`FORGE_ROOT=R forge fixes <track>/<feature> --record <git dir>/forge-<feature>-review.json`'*) ;;
  *) fail "$vs: ## Inline fixes does not hold \`FORGE_ROOT=R forge fixes <track>/<feature> --record <git dir>/forge-<feature>-review.json\`" ;;
esac
grep -qiE '`index`[^.]*`review` path[^.]*prints|`index`[^.]*printed `review` path' <<<"$fixes" \
  || fail "$vs: Inline fixes does not record findings at index of the review path forge fixes --record prints"
for want in 'F/review/reviewer-<repo>.json' '`rm -f F/review/reviewer-<repo>.json`'; do
  case "$fb" in
    *"$want"*) ;;
    *) fail "skills/forge-verify/reviewer-fallback.md: does not hold $want" ;;
  esac
done
grep -qiE 'fallbacks?[^.]*at once|at once[^.]*fallbacks?' <<<"$fb" \
  || fail "skills/forge-verify/reviewer-fallback.md: does not let the per-repo fallbacks run at once"
ok verify-review-par
fi

if want verify-no-rereview; then
bad=()
for f in skills/forge-verify/*.md; do
  flat=$(tr -s '[:space:]' ' ' <"$f")
  case "$flat" in *'--base P'*) bad+=("$f: names \`--base P\`; a fix reruns only its failing ids with \`forge test --one <id>\`") ;; esac
  case "$flat" in *rereview*) bad+=("$f: names a rereview record; verify reviews each repo once") ;; esac
  ! grep -qE '(^|[^a-z])steps? f([^a-z]|$)' <<<"$flat" || bad+=("$f: names Inline fixes step f, the removed fix-diff re-review")
done
[ "${#bad[@]}" -eq 0 ] || fail "${bad[@]}"
ok verify-no-rereview
fi

if want no-accept-callers; then
for f in skills/forge-verify/SKILL.md; do
  hit=$(grep -nF -- '--accept' "$f" || true)
  [ -z "$hit" ] || fail "$f names the removed forge done --accept:" "$hit"
done
ok no-accept-callers
fi

if want ship-reuses-verify-review; then
ship=skills/forge-ship/SKILL.md
ship_step3=$(skill_step "$ship" 3)
ship_flat=$(tr '\n' ' ' <"$ship" | tr -s '[:space:]' ' ')
record='forge-<feature>-review.json'
[ -n "$ship_step3" ] || fail "$ship: no step 3 under ## Steps"
for want in 'Review record. For each W: `<repo>` is the basename of W'"'"'s repo and `<git dir>` is `$(git -C W rev-parse --absolute-git-dir)`.' \
  'A present `F/review/<repo>.json` means that repo'"'"'s review and fixes are done, also on resume.' \
  'Otherwise copy `<git dir>/forge-<feature>-review.json` to `F/review-<repo>.json`.' \
  'Never run `forge review` or spawn `forge-reviewer`.' \
  'When the file is missing or has no `findings` array, end blocked with the cause `no verify review record for <repo>`.'; do
  case "$ship_step3" in
    *"$want"*) ;;
    *) fail "$ship: step 3 does not hold the spec's review record sentence: $want" ;;
  esac
done
case "$ship_step3" in
  *"$record"*'forge fixes <track>/<feature> --record F/review-<repo>.json'*) ;;
  *) fail "$ship: step 3 does not send the copied $record to the fixers through forge fixes <track>/<feature> --record F/review-<repo>.json" ;;
esac
for want in 'F/fixes/<repo>-F<k>.json' 'F/review-<repo>.json` to `F/review/<repo>.json`' '.forge/todo.md'; do
  case "$ship_step3" in
    *"$want"*) ;;
    *) fail "$ship: step 3 does not hold $want" ;;
  esac
done
for bad in 'review_trees' 'HEAD^{tree}' 'F/review/reviewer-<repo>.json' 'F/review.json' 'F/review/reviewer.json' 'F/fixes/F<k>.json'; do
  case "$ship_step3" in
    *"$bad"*) fail "$ship: step 3 still names $bad; it copies verify's record and reads no tree" ;;
  esac
done
hit=$(grep -oE 'forge review <track>[^`]*|spawn `forge-reviewer` with[^.]*' <<<"$ship_flat" || true)
[ -z "$hit" ] || fail "$ship: still runs forge review or spawns forge-reviewer:" "$hit"
case "$ship_flat" in
  *'Codex fallback: <cause>'*) fail "$ship: step 5 still writes a Codex fallback: <cause> line, though ship runs no review" ;;
esac
bgrule=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { if (hit) exit; cur = "" }
  in_rules { cur = cur $0 " "; if (index($0, "Start background commands")) hit = 1 }
  END { if (hit) print cur }
' "$ship" | tr -s '[:space:]' ' ')
[ -n "$bgrule" ] || fail "$ship: ## Rules has no Start background commands bullet"
case "$bgrule" in
  *'`forge review`'*) fail "$ship: the Rules background commands still name \`forge review\`" "$bgrule" ;;
esac
! grep -qF 'F/review/reviewer' "$ship" || fail "$ship: still names an F/review/reviewer record, though ship spawns no forge-reviewer"
! grep -qF 'F/review.json' "$ship" || fail "$ship: still names F/review.json, which ship no longer writes"
owners=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { printf "\n" }
  in_rules { printf "%s ", $0 }
' "$ship" | tr -s '[:space:]' ' ' | grep -F 'agent records you never edit' || true)
[ -n "$owners" ] || fail "$ship: ## Rules has no record ownership rule naming the agent records you never edit"
own_recs=${owners#*'agent records you never edit'}
own_recs=${own_recs%%'are yours'*}
case "$own_recs" in
  *'F/review-<repo>.json'*) ;;
  *) fail "$ship: the record ownership rule does not name F/review-<repo>.json among the records that are yours" "$owners" ;;
esac
ok ship-reuses-verify-review
fi

if want ship-record-owed; then
ship=skills/forge-ship/SKILL.md
ship_step5=$(skill_step "$ship" 5)
[ -n "$ship_step5" ] || fail "$ship: no step 5 under ## Steps"
case "$ship_step5" in
  '5. Record. '*) ;;
  *) fail "$ship: step 5 is not Record" ;;
esac
case "$ship_step5" in
  *'`forge owed <track>/<feature>`'*) ;;
  *) fail "$ship: step 5 does not run \`forge owed <track>/<feature>\`" ;;
esac
if grep -qE '(^|[.:;] )Set `done`' <<<"$ship_step5"; then
  fail "$ship: step 5 still tells the agent to set \`done\`"
fi
grep -qE '[Nn]ever sets? `done`' <<<"$ship_step5" \
  || fail "$ship: step 5 does not say it never sets \`done\` by hand"
case "$ship_step5" in
  *'`forge owed <track>/<feature>`'*'<ID> owed <kind>: <check>'*) ;;
  *) fail "$ship: step 5 does not name each \`<ID> owed <kind>: <check>\` line forge owed prints" ;;
esac
case "$ship_step5" in
  *'<ID> owed <kind>: <check>'*result*|*result*'<ID> owed <kind>: <check>'*) ;;
  *) fail "$ship: step 5 does not name the owed lines in the Ship result" ;;
esac
case "$ship_step5" in
  *'git -C R commit'*'-- .forge/todo.md'*) ;;
  *) fail "$ship: step 5 does not commit .forge/todo.md" ;;
esac
case "$ship_step5" in
  *'F/ship.json'*'forge commit <track>/<feature> ship'*) ;;
  *) fail "$ship: step 5 no longer writes F/ship.json and runs forge commit <track>/<feature> ship" ;;
esac
ok ship-record-owed
fi

ship_merge() {
  ship_steps=$(skill_step "$ship" "")
  merge=${ship_steps#*". Merge. "}
  [ "$merge" != "$ship_steps" ] || fail "$ship: no Merge step under ## Steps"
}
if want ship-no-changed-before-full; then
ship=skills/forge-ship/SKILL.md
ship_merge
full='`forge test W`'
case "$merge" in
  *"$full"*) ;;
  *) fail "$ship: Merge does not run the full suite $full" ;;
esac
before="${ship_steps%%". Merge. "*} ${merge%%"forge pr create"*}"
case "$before" in
  *'forge test --changed'*) fail "$ship: forge test --changed runs before Merge opens its PR" ;;
esac
ok ship-no-changed-before-full
fi

in_order() {
  local s=$1 w
  shift
  for w in "$@"; do
    case "$s" in
      *"$w"*) s=${s#*"$w"} ;;
      *) return 1 ;;
    esac
  done
}

in_order_pr() {
  local a=() b=() w
  for w in "$@"; do
    if [ "$w" = @PR ]; then
      a+=('PR merge with `<url>`'); b+=('`forge pr merge <url>`')
    else
      a+=("$w"); b+=("$w")
    fi
  done
  in_order "${a[@]}" || in_order "${b[@]}"
}
ship_sec() {
  awk -v h="$2" '
    /^## / { in_sec = ($0 == "## " h); next }
    in_sec { printf "%s ", $0 }
  ' "$1" | tr -s '[:space:]' ' '
}

if want ship-rule-full-suite-at-head; then
ship=skills/forge-ship/SKILL.md
full='`forge test W`'
ship_rule=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { if (hit) exit; cur = "" }
  in_rules { cur = cur $0 " "; if (index($0, "forge test W")) hit = 1 }
  END { if (hit) print cur }
' "$ship" | tr -s '[:space:]' ' ')
[ -n "$ship_rule" ] || fail "$ship: ## Rules has no bullet on the full suite $full"
for ban in 'Head re-sync' '--resync' 'Ship train' 'Queue wait' 'owed' 'FORGE_SHIP_QUEUE_FEATURE' 'second full suite' 'pre-head'; do
  case "$ship_rule" in
    *"$ban"*) fail "$ship: the Rules test-run bullet still names $ban; ship runs no queue, train or re-sync" ;;
  esac
done
remote_s=$(vsent "$ship_rule" | grep -F 'with a remote' | grep -F 'step 7' || true)
in_order "$remote_s" 'with a remote' 'step 7' 'before' 'push' \
  || fail "$ship: the Rules test-run bullet does not run the full suite for a repo with a remote in step 7 before the PR push"
case "$remote_s" in
  *'after the PR push'*) fail "$ship: the Rules test-run bullet still runs the full suite after the PR push" ;;
esac
retry_s=$(vsent "$ship_rule" | grep -F "PR merge's retry" || true)
[ -n "$retry_s" ] || fail "$ship: the Rules test-run bullet does not name PR merge's retry"
case "$retry_s" in
  *'--changed'*|*'changed test'*|*'changed run'*) fail "$ship: the Rules test-run bullet still gives PR merge's retry a changed run: $retry_s" ;;
esac
case "$retry_s" in
  *'full suite'*) ;;
  *) fail "$ship: the Rules test-run bullet does not say PR merge's retry reruns the full suite" ;;
esac
changed_s=$(vsent "$ship_rule" | grep -F 'forge test --changed' || true)
case "$changed_s" in
  *'failed PR check'*) ;;
  *) fail "$ship: the Rules test-run bullet does not keep \`forge test --changed\` for after fixing a failed PR check" ;;
esac
for want in '- CI full suite:' '`forge pr checks --full <url>`' 'exit 6'; do
  case "$ship_rule" in
    *"$want"*) ;;
    *) fail "$ship: the Rules test-run bullet lost $want" ;;
  esac
done
ok ship-rule-full-suite-at-head
fi

if want ship-pr-merge-open-blocked; then
ship=skills/forge-ship/SKILL.md
pr_merge=$(awk '
  /^## / { in_sec = ($0 ~ /^## PR merge[[:space:]]*$/); next }
  in_sec { printf "%s ", $0 }
' "$ship" | tr -s '[:space:]' ' ')
[ -n "$pr_merge" ] || fail "$ship: no ## PR merge section"
for want in '`DIRTY`' '`BEHIND`' 'at most 3 retries'; do
  case "$pr_merge" in
    *"$want"*) ;;
    *) fail "$ship: PR merge lost its DIRTY/BEHIND retry ($want)" ;;
  esac
done
case "$pr_merge" in
  *'Exit 1'*'`OPEN`'*'blocked'*'never'*[Ss]hipped*) ;;
  *) fail "$ship: PR merge does not say exit 1 with an \`OPEN\` state that is not DIRTY or BEHIND ends blocked, never shipped" ;;
esac
case "$pr_merge" in
  *transport*) ;;
  *) fail "$ship: PR merge does not say \`forge pr merge\` retries transport errors itself, so the skill adds no retry of its own" ;;
esac
case "$pr_merge" in
  *sleep*) fail "$ship: PR merge adds a retry of its own (sleep); \`forge pr merge\` retries transport errors itself" ;;
esac
ok ship-pr-merge-open-blocked
fi

if want ship-pr-merge-changed-retry; then
ship=skills/forge-ship/SKILL.md
full='`forge test W`'
fetch='`git -C W fetch origin main`'
cifull='`forge pr checks --full <url>`'
pr_merge=$(ship_sec "$ship" 'PR merge')
[ -n "$pr_merge" ] || fail "$ship: no ## PR merge section"
in_order "$pr_merge" '`forge pr merge <url>`' 'xit 5' "$fetch" '`origin/main`' 'step `retry`' '`forge pr push` from `W`' "$full" '`forge pr checks <url>`' '`forge pr merge <url>`' \
  || fail "$ship: PR merge's exit 5 retry does not run $fetch, the Resolver loop with \`origin/main\` and step \`retry\`, \`forge pr push\` from \`W\`, the full suite $full again, \`forge pr checks <url>\`, then \`forge pr merge <url>\` again"
in_order "$pr_merge" 'xit 1' '`forge pr state <url>`' '`DIRTY`' '`BEHIND`' "$fetch" \
  || fail "$ship: PR merge does not retry exit 1 with a \`forge pr state <url>\` merge state of \`DIRTY\` or \`BEHIND\` the same way"
case "$pr_merge" in
  *'at most 3 retries'*) ;;
  *) fail "$ship: PR merge's retry is not capped at most 3 retries" ;;
esac
for ban in 'forge test --changed' '--resync' 're-sync' 'resync' 'owed'; do
  case "$pr_merge" in
    *"$ban"*) fail "$ship: PR merge's retry still names $ban; it reruns the full suite" ;;
  esac
done
case "$pr_merge" in
  *'step 7'*) ;;
  *) fail "$ship: PR merge does not handle its rerun's exits as in step 7" ;;
esac
case "$pr_merge" in
  *'- CI full suite:'*) ;;
  *) fail "$ship: PR merge's retry lost the \`- CI full suite:\` path" ;;
esac
in_order "$pr_merge" "$cifull" 'xit 6' "$full" \
  || fail "$ship: PR merge's retry $cifull exit 6 does not fall back to $full"
resolver_sec=$(ship_sec "$ship" 'Resolver loop')
[ -n "$resolver_sec" ] || fail "$ship: no ## Resolver loop section"
for ban in 'resync' 're-sync' 'owed' 'changed run'; do
  case "$resolver_sec" in
    *"$ban"*) fail "$ship: the Resolver loop still names $ban" ;;
  esac
done
for want in 'step `sync`' 'step `retry`' 'step `merge`'; do
  case "$resolver_sec" in
    *"$want"*) ;;
    *) fail "$ship: the Resolver loop lost $want" ;;
  esac
done
retry_by=$(vsent "$resolver_sec" | grep -F 'step `retry`' || true)
case "$retry_by" in
  *'--changed'*|*'changed run'*) fail "$ship: the Resolver loop still tests step \`retry\`'s tree with a changed run" ;;
esac
case "$retry_by" in
  *'full suite'*) ;;
  *) fail "$ship: the Resolver loop does not say step \`retry\`'s merged tree is tested by PR merge's full-suite rerun" ;;
esac
ok ship-pr-merge-changed-retry
fi

if want ship-suite-before-head; then
ship=skills/forge-ship/SKILL.md
ship_merge
full='`forge test W`'
changed='forge test --changed --base <full-passed commit> W'
remote=${merge#*"With a remote:"}
[ "$remote" != "$merge" ] || fail "$ship: Merge has no path for a repo with a remote"
remote=${remote%%"Without one:"*}
no_remote=${merge#*"Without one:"}
[ "$no_remote" != "$merge" ] || fail "$ship: Merge has no path for a repo without a remote"
no_remote=${no_remote%%"After a PR:"*}
case "$merge" in
  *'runs no re-sync and no full suite before its PR'*) fail "$ship: step 7 still says a repo with a remote runs no full suite before its PR" ;;
esac
in_order "$remote" 'Resolver loop' '`main`' 'step `sync`' "$full" \
  || in_order "${merge%%"With a remote:"*}" 'Resolver loop' '`main`' 'step `sync`' \
  || fail "$ship: step 7 does not run the Resolver loop with \`main\` and step \`sync\` in \`W\` before a repo's full suite $full"
in_order "$no_remote" 'Resolver loop' "$full" \
  || in_order "${merge%%"With a remote:"*}" 'Resolver loop' '`main`' 'step `sync`' \
  || fail "$ship: step 7 does not run the Resolver loop before the full suite of a repo without a remote"
in_order_pr "$remote" "$full" '`forge pr push' 'forge pr create' '`forge pr checks <url>`' @PR '`forge golive' \
  || fail "$ship: step 7 does not run, for a repo with a remote, the full suite $full, then \`forge pr push\`, \`forge pr create\`, \`forge pr checks <url>\`, PR merge with \`<url>\` and \`forge golive\`, in that order"
in_order_pr "$remote" "$full" 'forge-fixer' '`forge pr push' @PR \
  || fail "$ship: step 7's full-suite failure does not go to \`forge-fixer\`s, then \`forge pr push\`, before PR merge"
pre_noted=$(vsent "$remote" | grep -F '`git -C W rev-parse HEAD`' | grep -F 'full-passed commit' || true)
[ -n "$pre_noted" ] || fail "$ship: step 7 does not note \`git -C W rev-parse HEAD\` as the full-passed commit after the full pass"
exit3=${remote#*"Exit 3:"}
[ "$exit3" != "$remote" ] || fail "$ship: step 7 has no exit 3 handling"
exit3=${exit3%%"Exit 4:"*}
case "$exit3" in
  *"\`$changed\`"*) ;;
  *) fail "$ship: step 7's exit 3 handling does not run \`$changed\` after a noted full pass" ;;
esac
case "$exit3" in
  *'`forge test --changed W`'*) ;;
  *) fail "$ship: step 7's exit 3 handling lost the plain \`forge test --changed W\` without a noted full pass" ;;
esac
after_pr=${merge#*"After a PR:"}
[ "$after_pr" != "$merge" ] || fail "$ship: Merge has no After a PR path"
in_order_pr "$after_pr" 'full-passed commit' "$full" @PR \
  || in_order_pr "$after_pr" "$full" 'full-passed commit' @PR \
  || fail "$ship: After a PR does not run the full suite $full before PR merge when no full-passed commit is noted"
resolver_sec=$(ship_sec "$ship" 'Resolver loop')
case "$resolver_sec" in
  *'step 7'*) ;;
  *) fail "$ship: the Resolver loop does not say step \`sync\`'s tree is tested by step 7's full suite" ;;
esac
leftover=$( { grep -nE 'ship[- ]queue|[Qq]ueue wait|re-sync|FORGE_SHIP_QUEUE_FEATURE|joined|the queue|owed run|run owed|run is owed|car order' "$ship"
  grep -nwiE 'resync|train|trains|car|cars' "$ship"; } | sort -un || true)
[ -z "$leftover" ] || fail "$ship: still holds queue, train or re-sync text:" "$leftover"
ok ship-suite-before-head
fi

ci_full_exit0_scoped() {
  local text=$1 site=$2 s ctx
  while IFS= read -r s; do
    case "$s" in
      *xit\ 0*) ;;
      *) continue ;;
    esac
    case "$s" in
      *'the full pass'*|*'full-passed commit'*) ;;
      *) continue ;;
    esac
    case "$s" in
      *never*) continue ;;
      *'forge pr checks'*)
        case "$s" in
          *'--full'*) continue ;;
          *) fail "$ship: $site takes a plain \`forge pr checks\` exit 0 as the full pass: $s" ;;
        esac ;;
    esac
    ctx=${text%%"$s"*}
    case "$ctx" in
      *'forge pr checks'*) ;;
      *) continue ;;
    esac
    case "${ctx##*'forge pr checks'}" in
      ' --full'*) ;;
      *) fail "$ship: $site takes a plain \`forge pr checks\` exit 0 as the full pass: $s" ;;
    esac
  done < <(sed 's/\. /.\n/g' <<<"$text")
}
if want ship-ci-full-step7; then
ship=skills/forge-ship/SKILL.md
ship_merge
full='`forge test W`'
cifull='`forge pr checks --full <url>`'
remote=${merge#*"With a remote:"}
[ "$remote" != "$merge" ] || fail "$ship: Merge has no path for a repo with a remote"
remote=${remote%%"Without one:"*}
after_pr=${merge#*"After a PR:"}
[ "$after_pr" != "$merge" ] || fail "$ship: Merge has no After a PR path"
case "$remote$after_pr" in
  *'Queue wait'*|*'ship-queue'*|*'Head re-sync'*|*'Ship train'*) fail "$ship: step 7 still waits on a queue, train or head re-sync" ;;
esac
case "$remote" in
  *'- CI full suite:'*) ;;
  *) fail "$ship: step 7 does not name the \`- CI full suite:\` line for a repo with a remote" ;;
esac
in_order "$remote" 'forge pr create' "$cifull" \
  || fail "$ship: step 7 does not run $cifull on the opened PR for a repo declaring \`- CI full suite:\`"
seg=${remote#*'forge pr create'}
seg=${seg#*"$cifull"}
note=$(vsent "$seg" | grep -F 'xit 0' | grep -F '`git -C W rev-parse HEAD`' | grep -F 'full-passed commit' | head -n 1 || true)
[ -n "$note" ] || fail "$ship: step 7's $cifull exit 0 does not note \`git -C W rev-parse HEAD\` as the full-passed commit"
in_order_pr "${seg#*"$note"}" @PR \
  || in_order_pr "$note" '`git -C W rev-parse HEAD`' @PR \
  || fail "$ship: step 7's $cifull exit 0 does not go on to PR merge with \`<url>\` after noting the full-passed commit"
fb=$(vsent "$seg" | grep -F 'xit 6' | grep -F "$full" || true)
[ -n "$fb" ] && in_order "$fb" 'xit 6' "$full" \
  || fail "$ship: step 7's $cifull exit 6 does not fall back to $full"
ci_full_exit0_scoped "$remote" "step 7"
case "$after_pr" in
  *'- CI full suite:'*) ;;
  *) fail "$ship: After a PR does not name the \`- CI full suite:\` line" ;;
esac
in_order_pr "$after_pr" 'full-passed commit' "$cifull" @PR \
  || in_order_pr "$after_pr" "$cifull" 'full-passed commit' @PR \
  || fail "$ship: After a PR does not run $cifull before PR merge when no full-passed commit is noted for a repo declaring \`- CI full suite:\`"
apr_seg=${after_pr#*"$cifull"}
afb=$(vsent "$apr_seg" | grep -F 'xit 6' | grep -F "$full" || true)
[ -n "$afb" ] && in_order "$afb" 'xit 6' "$full" \
  || fail "$ship: After a PR's $cifull exit 6 does not fall back to $full"
ci_full_exit0_scoped "$after_pr" "After a PR"
ok ship-ci-full-step7
fi

if want ship-archive-checks-pr-state; then
ship=skills/forge-ship/SKILL.md
ship_step9=$(skill_step "$ship" 9)
[ -n "$ship_step9" ] || fail "$ship: no step 9 under ## Steps"
for want in '`forge pr state <url>`' 'F/ship.json' '`MERGED`' 'nonzero' 'blocked' '`<url> is <state line>, not merged`' '`result: Shipped'; do
  case "$ship_step9" in
    *"$want"*) ;;
    *) fail "$ship: step 9 does not run \`forge pr state <url>\` for every F/ship.json pr before \`result: Shipped\`, ending blocked with \`<url> is <state line>, not merged\` on a non-MERGED state or nonzero exit (missing $want)" ;;
  esac
done
ok ship-archive-checks-pr-state
fi

if want ship-clean-reports-leftovers; then
ship=skills/forge-ship/SKILL.md
ship_step8=$(skill_step "$ship" 8)
[ -n "$ship_step8" ] || fail "$ship: no step 8 under ## Steps"
case "$ship_step8" in
  *Ask*|*'whether to override'*) fail "$ship: step 8 Clean asks an override question; exit 3's targets are reported as leftovers" ;;
esac
case "$ship_step8" in
  *[Ee]'xit 3'*leftover*) ;;
  *) fail "$ship: step 8 Clean does not report exit 3's targets as leftovers" ;;
esac
case "$ship_step8" in
  *'`forge clean --confirmed'*) fail "$ship: step 8 Clean names \`forge clean --confirmed\`, which cannot run once Archive moves the split away" ;;
esac
case "$ship_step8" in
  *'`forge gc`'*manual*) ;;
  *) fail "$ship: step 8 Clean does not name \`forge gc\` as the operator's manual follow-up for exit 3's leftovers" ;;
esac
case "$ship_step8" in
  *Archive*) ;;
  *) fail "$ship: step 8 Clean does not go on to Archive" ;;
esac
ok ship-clean-reports-leftovers
fi

if want ship-merges-without-go; then
ship=skills/forge-ship/SKILL.md
ship_merge
full='`forge test W`'
golive='`forge golive <path> forge/<track>-<feature>`'
after_pr=${merge#*"After a PR:"}
[ "$after_pr" != "$merge" ] || fail "$ship: Merge has no After a PR path"
no_remote=${merge#*"Without one:"}
[ "$no_remote" != "$merge" ] || fail "$ship: Merge has no path for a repo without a remote"
no_remote=${no_remote%%"After a PR:"*}
for ban in 'multiSelect' 'whether to merge' "operator's go" "operator's approval" \
  'merge approval' 'the merge question' 'one merge question' "repo's merge question" 'same go' 'the go that'; do
  ! grep -qF -- "$ban" "$ship" || fail "$ship: still holds \`$ban\`; ship merges and golives with no operator go"
done
ship_desc=$(sed -n 's/^description: //p' "$ship")
case "$ship_desc" in
  *approved*) fail "$ship: description still says approved: $ship_desc" ;;
esac
remote=${merge#*"With a remote:"}
[ "$remote" != "$merge" ] || fail "$ship: Merge has no path for a repo with a remote"
remote=${remote%%"Without one:"*}
for part in "$remote" "$after_pr" "$no_remote"; do
  case "$part" in
    *'Queue wait'*|*'ship-queue'*|*'Head re-sync'*|*'Ship train'*) fail "$ship: step 7 still waits on a queue, train or head re-sync before it merges" ;;
  esac
done
in_order_pr "$remote" '`forge pr checks <url>`' 'Exit 0' @PR '`forge golive' \
  || fail "$ship: step 7 does not run PR merge with \`<url>\`, then \`forge golive\`, after \`forge pr checks <url>\` exit 0"
in_order_pr "$after_pr" @PR "$golive" \
  || fail "$ship: After a PR does not run PR merge with \`<url>\`, then $golive"
for part in remote after_pr; do
  merge_s=$(vsent "${!part}" | grep -F -e 'PR merge with `<url>`' -e '`forge pr merge <url>`' || true)
  case "$merge_s" in
    *'no question'*) ;;
    *) fail "$ship: $part does not run PR merge with \`<url>\` with no question" ;;
  esac
done
pm='PR merge with `<url>`'
case "$remote" in
  *"$pm"*) ;;
  *) pm='`forge pr merge <url>`' ;;
esac
m2g=${remote#*"$pm"}
m2g=${m2g%%'`forge golive'*}
case "$m2g" in
  *AskUserQuestion*|*' ask '*|*'Ask '*) fail "$ship: step 7 asks the operator between PR merge and its golive" ;;
esac
in_order "$no_remote" "$full" "$golive" \
  || fail "$ship: a repo without a remote does not run $golive after its full suite $full"
t2g=${no_remote#*"$full"}
t2g=${t2g%%"$golive"*}
case "$t2g" in
  *AskUserQuestion*|*question*) fail "$ship: a repo without a remote asks the operator between its full suite and its golive" ;;
esac
ok ship-merges-without-go
fi

flake_before_fixer() {
  local s=$1 anchor=$2 site=$3 end=${4:-} pre
  case "$s" in
    *"$anchor"*) ;;
    *) fail "$ship: $site lost its anchor $anchor" ;;
  esac
  s=${s#*"$anchor"}
  [ -z "$end" ] || s=${s%%"$end"*}
  pre=${s%%'Flake rerun'*}
  [ "$pre" != "$s" ] || fail "$ship: $site does not run Flake rerun after its full suite \`forge test W\`"
  case "$pre" in
    *forge-fixer*) fail "$ship: $site sends a \`forge-fixer\` before Flake rerun" ;;
  esac
  case "$pre" in
    *'`forge test W`'*) ;;
    *) fail "$ship: $site names Flake rerun before its full suite \`forge test W\`" ;;
  esac
}
if want ship-flake-rerun; then
ship=skills/forge-ship/SKILL.md
grep -qx '## Flake rerun' "$ship" || fail "$ship: no ## Flake rerun section"
flake=$(ship_sec "$ship" 'Flake rerun')
for want in '`forge test --one ' 'flaky: <ids> failed in the full suite of <track>/<feature> and passed alone' '`forge test --force W`'; do
  case "$flake" in
    *"$want"*) ;;
    *) fail "$ship: Flake rerun does not name $want" ;;
  esac
done
ship_merge
flake_before_fixer "$merge" 'With a remote:' "step 7's full suite for a repo with a remote" 'Without one:'
flake_before_fixer "$merge" 'Without one:' "step 7's full suite for a repo without a remote" 'After a PR:'
pr_merge=$(ship_sec "$ship" 'PR merge')
[ -n "$pr_merge" ] || fail "$ship: no ## PR merge section"
flake_before_fixer "$pr_merge" 'step `retry`' "PR merge's retry full-suite rerun"
pr_full=${pr_merge#*'`forge pr checks --full <url>`'}
[ "$pr_full" != "$pr_merge" ] || fail "$ship: PR merge lost its \`forge pr checks --full <url>\` retry"
flake_before_fixer "$pr_full" 'exit 6' "PR merge's \`forge pr checks --full\` exit-6 fallback"
ok ship-flake-rerun
fi

if want quick-debug-merge-without-go; then
quick=skills/forge-quick/SKILL.md
debug=skills/forge-debug/SKILL.md
quick_merge=$(skill_step "$quick" 13)
debug_merge=$(skill_step "$debug" 13)
[ -n "$quick_merge" ] || fail "$quick: no step 13 under ## Steps"
[ -n "$debug_merge" ] || fail "$debug: no step 13 under ## Steps"
for f in "$quick" "$debug"; do
  [ "$f" = "$quick" ] && step=$quick_merge || step=$debug_merge
  for ban in 'whether to merge' "operator's go" 'explicit go' "operator's approval" 'approves the merge' \
    'the approval' 'on approval' 'declined merge' 'declined or skipped merge' 'skipped merge' 'any other answer' \
    'to merge `forge/'; do
    case "$step" in
      *"$ban"*) fail "$f: merge step still holds \`$ban\`; it merges and golives with no operator go" ;;
    esac
  done
  no_remote=${step#*Without}
  [ "$no_remote" != "$step" ] || fail "$f: merge step has no path for a repo without a remote"
  no_remote=${no_remote%%'`forge golive'*}
  case "$no_remote" in
    *AskUserQuestion*|*' ask '*|*approv*) fail "$f: a repo without a remote asks before its \`forge golive\`" ;;
  esac
  case "$step" in
    *'forge.pushMain'*) ;;
    *) fail "$f: merge step lost the forge.pushMain request" ;;
  esac
  after_merge=${step#*'`forge pr merge <url>`'}
  [ "$after_merge" != "$step" ] || fail "$f: merge step does not run \`forge pr merge <url>\`"
  case "$after_merge" in
    *'nonzero exit'*stderr*) ;;
    *) fail "$f: merge step lost the failed-merge handling (a nonzero exit reported with its stderr)" ;;
  esac
done
in_order "$quick_merge" 'forge pr create' '`forge pr merge <url>`' '`forge golive <repo>' \
  || fail "$quick: step 13 does not run \`forge pr merge <url>\` right after the PR is created, then \`forge golive\`"
in_order "$debug_merge" '`gh pr checks --watch --fail-fast`' '`forge pr merge <url>`' '`forge golive <repo> forge/<D>`' 'Deploy' \
  || fail "$debug: step 13 does not run \`forge pr merge <url>\` after its checks pass, then \`forge golive\` and Deploy"
checks_to_merge=${debug_merge#*'`gh pr checks --watch --fail-fast`'}
checks_to_merge=${checks_to_merge%%'`forge pr merge <url>`'*}
case "$checks_to_merge" in
  *AskUserQuestion*) fail "$debug: step 13 asks with AskUserQuestion between its checks and \`forge pr merge <url>\`" ;;
esac
grep -qF 'Live check' "$debug" || fail "$debug: lost its Live check step"
ok quick-debug-merge-without-go
fi

if want pr-push-from-w; then
ship=skills/forge-ship/SKILL.md
quick=skills/forge-quick/SKILL.md
debug=skills/forge-debug/SKILL.md
push='`forge pr push` from `W`'
for f in "$ship" "$quick" "$debug"; do
  raw=$(grep -nE '`git (-C [^ `]+ )?push' "$f" | grep -vF -- '--delete' || true)
  [ -z "$raw" ] || fail "$f: a PR-branch push still runs git push instead of \`forge pr push\` from \`W\`:" "$raw"
  case "$f" in
    "$ship") fixer='forge-fixer' ;;
    "$quick") fixer='fixer|step 9' ;;
    *) fixer='fixer' ;;
  esac
  route=$(tr '\n' ' ' <"$f" | tr -s '[:space:]' ' ' | sed 's/\. /.\n/g' \
    | grep -F 'forge pr push' | grep -F 'Pre-push' | grep -iE 'exits? 3' | grep -iE "$fixer" || true)
  [ -n "$route" ] || fail "$f: no sentence routes \`forge pr push\` exit 3 (Pre-push failed) to fixers ($fixer) the way a failed test goes"
  bg=$(tr '\n' ' ' <"$f" | tr -s '[:space:]' ' ' | sed 's/\. /.\n/g' \
    | grep -F 'forge pr push' | grep -F '`run_in_background: true`' | grep -F 'time limit' || true)
  [ -n "$bg" ] || fail "$f: no sentence runs \`forge pr push\` with the Bash tool's \`run_in_background: true\` past the Bash tool's time limit"
  if [ "$f" = "$ship" ]; then
    in_order "$route" 'forge-fixer' 'commit the fixes in `W`' '`forge test --changed --base <full-passed commit> W`' \
      '`forge test --changed W`' 'forge-fixer' "$push again" 'full-passed commit' \
      || fail "$ship: \`forge pr push\` exit 3 does not rerun \`forge test --changed --base <full-passed commit> W\` (else \`forge test --changed W\`) on the Pre-push fixes before pushing again"
  fi
done
grep -qF '`git -C <repo> push origin --delete forge/<D>`' "$debug" \
  || fail "$debug: lost the branch delete \`git -C <repo> push origin --delete forge/<D>\`"
ship_merge
remote=${merge#*"With a remote:"}
[ "$remote" != "$merge" ] || fail "$ship: Merge has no path for a repo with a remote"
remote=${remote%%"Without one:"*}
in_order "$remote" '`forge pr push -u origin forge/<track>-<feature>` from `W`' 'forge pr create' \
  || fail "$ship: step 7 does not push with \`forge pr push -u origin forge/<track>-<feature>\` from \`W\` before \`forge pr create\`"
in_order_pr "$remote" '`forge test W`' 'forge-fixer' "$push" @PR \
  || fail "$ship: step 7's full-suite fixes are not pushed with $push before PR merge"
exit3=${remote#*"Exit 3:"}
[ "$exit3" != "$remote" ] || fail "$ship: step 7 has no exit 3 handling"
exit3=${exit3%%"Exit 4:"*}
in_order "$exit3" '`forge test --changed --base <full-passed commit> W`' "$push" '`forge pr checks <url>`' \
  || fail "$ship: step 7's exit-3 check-fix loop does not push with $push before \`forge pr checks <url>\`"
pr_merge=$(ship_sec "$ship" 'PR merge')
[ -n "$pr_merge" ] || fail "$ship: no ## PR merge section"
retry=${pr_merge#*'step `retry`'}
[ "$retry" != "$pr_merge" ] || fail "$ship: PR merge has no Resolver loop step \`retry\`"
case "${retry%%'`forge test W`'*}" in
  *"$push"*) ;;
  *) fail "$ship: PR merge's retry does not push with $push before it reruns the full suite \`forge test W\`" ;;
esac
case "${retry%%'`forge pr checks --full <url>`'*}" in
  *"$push"*) ;;
  *) fail "$ship: PR merge's CI full suite retry does not push with $push before \`forge pr checks --full <url>\`" ;;
esac
in_order "$retry" "$push" '`forge test W`' '`forge pr merge <url>`' \
  || fail "$ship: PR merge's retry does not run \`forge pr merge <url>\` again after its push and full suite"
quick_merge=$(skill_step "$quick" 13)
[ -n "$quick_merge" ] || fail "$quick: no step 13 under ## Steps"
in_order "$quick_merge" 'With a remote:' '`forge pr push -u origin forge/quick-<slug>` from `W`' '`run_in_background: true`' 'forge pr create' \
  || fail "$quick: step 13 does not push with \`forge pr push -u origin forge/quick-<slug>\` from \`W\` in the background before \`forge pr create\`"
debug_merge=$(skill_step "$debug" 13)
[ -n "$debug_merge" ] || fail "$debug: no step 13 under ## Steps"
in_order "$debug_merge" 'origin' '`forge pr push -u origin forge/<D>` from `W`' '`run_in_background: true`' 'forge pr create' \
  || fail "$debug: step 13 does not push with \`forge pr push -u origin forge/<D>\` from \`W\` in the background before \`forge pr create\`"
in_order "$debug_merge" '`gh pr checks --watch --fail-fast`' 'review-fix round' "$push" 'checks again' \
  || fail "$debug: step 13's review-fix round does not push its fix commits with $push before waiting on the checks again"
ok pr-push-from-w
fi

if want ship-merged-pr-golive; then
ship=skills/forge-ship/SKILL.md
ship_merge
golive='`forge golive <path> forge/<track>-<feature>`'
after_pr=${merge#*"After a PR:"}
[ "$after_pr" != "$merge" ] || fail "$ship: Merge has no After a PR path"
in_order "$after_pr" '`forge pr state <url>`' '`MERGED`' \
  || fail "$ship: After a PR does not check \`forge pr state <url>\` for a PR already \`MERGED\`"
merged=${after_pr#*'`MERGED`'}
case "$merged" in
  *"$golive"*) ;;
  *) fail "$ship: After a PR does not run $golive for a PR already \`MERGED\`" ;;
esac
pre=${merged%%"$golive"*}
case "$pre" in
  *'not in `main`'*|*'--is-ancestor'*) ;;
  *) fail "$ship: After a PR runs $golive on a \`MERGED\` PR without checking that its branch is not in \`main\`" ;;
esac
case "$pre" in
  *'Merged in a train'*|*ship-queue*|*'forge test'*|*'PR merge'*|*'forge pr merge'*|*'forge pr checks'*|*'Resolver loop'*)
    fail "$ship: After a PR runs more than $golive on a \`MERGED\` PR whose branch is not in \`main\`: $pre" ;;
esac
gate=$(vsent "$merged" | grep -A1 -F "$golive" | head -n 2 | tr '\n' ' ' || true)
for want in 'land' 'xit 7' 'operator'; do
  case "$gate" in
    *"$want"*) ;;
    *) fail "$ship: After a PR's golive of a \`MERGED\` PR does not say golive's land is the gate, its exit 7 asking the operator (missing $want)" ;;
  esac
done
ok ship-merged-pr-golive
fi

if want quick-verify-step; then
quick=skills/forge-quick/SKILL.md
debug=skills/forge-debug/SKILL.md
quick_verify=$(skill_step "$quick" 10)
[ -n "$quick_verify" ] || fail "$quick: no step 10 under ## Steps"
case "$quick_verify" in
  '10. Verify'*) ;;
  *) fail "$quick: step 10 is not the Verify step: $quick_verify" ;;
esac
for want in '--verify' 'AskUserQuestion' 'Fix'; do
  case "$quick_verify" in
    *"$want"*) ;;
    *) fail "$quick: step 10 Verify does not name $want" ;;
  esac
done
case "$(skill_step "$quick" 9)" in
  '9. Fix'*) ;;
  *) fail "$quick: step 9 is not Fix, so Verify does not follow Fix" ;;
esac
case "$(skill_step "$quick" 11)" in
  '11. Concerns'*) ;;
  *) fail "$quick: step 11 is not Concerns, so Verify does not precede Concerns" ;;
esac
case "$(skill_step "$quick" 12)" in
  '12. Sync'*) ;;
  *) fail "$quick: step 12 is not Sync" ;;
esac
case "$(skill_step "$quick" 14)" in
  '14. Clean'*) ;;
  *) fail "$quick: step 14 is not Clean" ;;
esac
grep -qF -- '--verify' <(sed -n 's/^argument-hint: //p' "$quick") || fail "$quick: argument-hint does not name --verify"
grep -qF -- '`--verify`' "$quick" || fail "$quick: Arguments line does not name \`--verify\`"
! grep -qF "step 12's" "$quick" || fail "$quick: still refers to step 12's full suite; the full suite runs in step 13"
grep -qF "step 13's full suite" "$quick" || fail "$quick: does not refer to step 13's full suite"
! grep -qF 'forge-quick` step 12' "$debug" || fail "$debug: still refers to \`forge-quick\` step 12; its Merge is step 13"
grep -qF 'forge-quick` step 13' "$debug" || fail "$debug: does not refer to \`forge-quick\` step 13 for exit codes"
ok quick-verify-step
fi

if want quick-log; then
quick=skills/forge-quick/SKILL.md
quick_spec=$(skill_step "$quick" 1)
for want in '`STATE/quicks.json`' '`forge paths`' 'forge/quick-<slug>' 'R/.forge/quick/<slug>/' '`-2`'; do
  case "$quick_spec" in
    *"$want"*) ;;
    *) fail "$quick: step 1 Spec does not make slugs unique across STATE/quicks.json (STATE from forge paths) alongside the forge/quick-<slug> branch and R/.forge/quick/<slug>/ checks, appending -2, -3 (missing $want)" ;;
  esac
done
! grep -qF '.forge/quicks.json' "$quick" || fail "$quick: still names .forge/quicks.json; quicks.json lives in STATE"
quick_clean=$(skill_step "$quick" 14)
case "$quick_clean" in
  *'forge quick-log <slug> <task> <repo>'*) ;;
  *) fail "$quick: step 14 Clean does not run \`forge quick-log <slug> <task> <repo>...\`" ;;
esac
ql_ok=
while IFS= read -r ql_sentence; do
  case "$ql_sentence" in *golive*) ;; *) continue ;; esac
  case "$ql_sentence" in *every*) ;; *) continue ;; esac
  case "$ql_sentence" in *once*) ;; *) continue ;; esac
  grep -qE 'exit(s|ed)? 0' <<<"$ql_sentence" || continue
  ql_ok=1
done < <(grep -oE '([^.]|\.[^ ])*forge quick-log([^.]|\.[^ ])*' <<<"$quick_clean")
[ -n "$ql_ok" ] || fail "$quick: step 14 Clean does not run forge quick-log once, only after forge golive exited 0 for every touched repo"
ql_at=$(at 'forge quick-log' "$quick_clean")
rm_at=$(at 'emove `S`' "$quick_clean")
[ "$rm_at" -ge 0 ] || fail "$quick: step 14 Clean no longer removes \`S\`"
[ "$ql_at" -lt "$rm_at" ] || fail "$quick: step 14 Clean does not run forge quick-log before removing \`S\`"
[ "$ql_at" -lt "$(at 'result: Quick' "$quick_clean")" ] || fail "$quick: step 14 Clean does not run forge quick-log before the result line"
for want in 'flags' 'basename'; do
  case "$quick_clean" in
    *"$want"*) ;;
    *) fail "$quick: step 14 Clean does not pass the task text with the flags stripped and the touched repos' basenames to forge quick-log (missing $want)" ;;
  esac
done
grep -qE 'no `?forge quick-log' <<<"$quick_clean" \
  || fail "$quick: step 14 Clean does not say a stop, a PR left open or a golive that did not exit 0 runs no forge quick-log"
grep -qE 'failing `forge quick-log` writes nothing' <<<"$quick_clean" \
  || fail "$quick: step 14 Clean does not say a failing forge quick-log writes nothing"
quick_rules=$(awk '
  /^## / { in_sec = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_sec { printf "%s ", $0 }
' "$quick" | tr -s '[:space:]' ' ')
for want in '`forge quick-log`' '`STATE/quicks.json`' '`forge: recorded quick <slug>`' 'Write no track, feature or phase JSON' 'run no `forge commit`'; do
  case "$quick_rules" in
    *"$want"*) ;;
    *) fail "$quick: Rules do not say forge quick-log records the quick in STATE/quicks.json and prints forge: recorded quick <slug>, while keeping the ban on track, feature or phase JSON and forge commit (missing $want)" ;;
  esac
done
for f in "$quick" skills/forge-debug/SKILL.md; do
  ! grep -qE 'XDG_STATE_HOME|\.local/state/forge/(<|\$|\{)' "$f" || fail "$f: writes the XDG state-dir expression; name it STATE from forge paths"
done
ok quick-log
fi

skill_blocks() {
  awk '
    /^[[:space:]]*$/ || /^#/ || /^[[:space:]]*(- |[0-9]+\. )/ { if (cur != "") print cur; cur = "" }
    /^[[:space:]]*$/ || /^#/ { next }
    { cur = cur $0 " " }
    END { if (cur != "") print cur }
  ' "$1" | tr -s ' \t' ' '
}

block_with() {
  local f=$1 needle=$2 want b
  shift 2
  while IFS= read -r b; do
    case "$b" in *"$needle"*) ;; *) continue ;; esac
    for want in "$@"; do
      case "$b" in *"$want"*) ;; *) continue 2 ;; esac
    done
    return 0
  done < <(skill_blocks "$f")
  return 1
}

no_entry() {
  grep -qiE '(writes?|adds?|records?|appends?) no ([a-z`./]+ )*entry|no ([a-z`./]+ )*entry is (written|recorded|added|appended)|writes? nothing' <<<"$1"
}
if want debug-log; then
debug=skills/forge-debug/SKILL.md
debug_merge=$(skill_step "$debug" 13)
[ -n "$debug_merge" ] || fail "$debug: no step 13 under ## Steps"
debug_flat=$(tr '\n' ' ' <"$debug" | tr -s '[:space:]' ' ')
debug_clean=$(skill_step "$debug" 15)
[ -n "$debug_clean" ] || fail "$debug: no step 15 under ## Steps"
debug_lock='`flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" bash -c '"'"'<script>'"'"' _ '"'"'<entry JSON>'"'"'`'
in_order "$debug_clean" '`forge golive` exited 0' 'confirmed' '`forge paths`' "$debug_lock" 'STATE/debugs.json' '{"debugs": []}' 'S/debugs.json' \
  '`forge validate S/debugs.json`' '`mv S/debugs.json STATE/debugs.json`' 'Remove `S`' \
  || fail "$debug: step 15 does not, after every golive exited 0 and the live check confirmed, take STATE from forge paths and run under $debug_lock the read of STATE/debugs.json (absent as {\"debugs\": []}), the jq append to S/debugs.json, \`forge validate S/debugs.json\` and \`mv S/debugs.json STATE/debugs.json\` before removing S"
for gone in 'git -C R add' 'git -C R commit' 'debugs.prev.json' 'R/.forge/debugs.json'; do
  ! grep -qF -- "$gone" "$debug" || fail "$debug: still names $gone; debugs.json lives in STATE with no commit, backup or restore"
done
case "$debug_clean" in
  *jq*) ;;
  *) fail "$debug: step 15 does not append the debugs.json entry with jq" ;;
esac
locked_part=${debug_clean#*"$debug_lock"}
locked_part=${locked_part%%'Remove `S`'*}
case "$locked_part" in
  *flock*) fail "$debug: step 15 takes forge.lock a second time inside the locked script" ;;
esac
for want in '`slug`' '`symptom`' '`cause`' '`repos`' '`date`' '`-N`' '`--diagnose-only`' '`root_cause.summary`' \
  'round' 'producer order' 'YYYY-MM-DD'; do
  case "$debug_clean" in
    *"$want"*) ;;
    *) fail "$debug: step 15's debugs.json entry does not set slug (final slug with its step-2 \`-N\` suffix), symptom (without \`--diagnose-only\`), cause (the passing round's \`root_cause.summary\`), repos (touched repos in producer order) and date (local YYYY-MM-DD) (missing $want)" ;;
  esac
done
for want in 'error' 'entry JSON' 'STATE/debugs.json'; do
  case "$debug_clean" in
    *"$want"*) ;;
    *) fail "$debug: step 15 does not print the failing command's error and the entry JSON when the append, validate or move fails (missing $want)" ;;
  esac
done
grep -qiE 'as it was|unchanged|untouched' <<<"$debug_clean" \
  || fail "$debug: step 15 does not leave STATE/debugs.json as it was when the append or validate fails"
grep -qiE 'still ends with' <<<"$debug_clean" \
  || fail "$debug: step 15 does not say a failed debugs.json append or validate still ends with the result line"
in_order "$debug_clean" 'entry JSON' 'result: Debug <slug>: <root cause summary>;' \
  || fail "$debug: step 15 does not end with its result line after the debugs.json failure handling"
debug_commit_rule=$(skill_blocks "$debug" | grep -F 'Commit nothing under `.forge/`')
case "$debug_commit_rule" in
  *'`concerns.json`'*'`CONCERNS.md`'*) ;;
  *) fail "$debug: the Rules line \"Commit nothing under .forge/\" lost its concerns.json and CONCERNS.md exception" ;;
esac
case "$debug_commit_rule" in
  *debugs.json*) fail "$debug: the Rules line \"Commit nothing under .forge/\" still allows debugs.json, which lives in STATE" ;;
esac
block_with "$debug" 'run no `forge commit`' 'Write no track, feature or phase JSON' \
  || fail "$debug: the Rules lost \"Write no track, feature or phase JSON and run no \`forge commit\`\""
debug_stop=${debug_flat#*'Stop, at a budget prompt'}
debug_stop=${debug_stop%%'## Resolver loop'*}
case "$debug_stop" in
  *debugs.json*) no_entry "$debug_stop" || fail "$debug: the stop sequence does not say it writes no debugs.json entry" ;;
  *) fail "$debug: the stop sequence does not say it writes no debugs.json entry" ;;
esac
diag=$(skill_step "$debug" 7)
diag=${diag#*'With `--diagnose-only`'}
case "$diag" in
  *debugs.json*) no_entry "$diag" || fail "$debug: step 7's --diagnose-only exit does not say it writes no debugs.json entry" ;;
  *) fail "$debug: step 7's --diagnose-only exit does not say it writes no debugs.json entry" ;;
esac
case "$debug_merge" in
  *debugs.json*) no_entry "$debug_merge" || fail "$debug: step 13's stops after some repos landed do not say they write no debugs.json entry" ;;
  *) fail "$debug: step 13's stops after some repos landed do not say they write no debugs.json entry" ;;
esac
still_broken=$(skill_step "$debug" 14)
still_broken=${still_broken#*'Still broken'}
still_broken=${still_broken%%'Confirmed'*}
case "$still_broken" in
  *debugs.json*) no_entry "$still_broken" || fail "$debug: step 14's still-broken branch does not say it writes no debugs.json entry" ;;
  *) fail "$debug: step 14's still-broken branch does not say it writes no debugs.json entry" ;;
esac
ok debug-log
fi

if want per-suite-logs; then
for f in skills/forge-phase/SKILL.md skills/forge-verify/SKILL.md; do
  block_with <(skill_text "$f") '`FAIL`' 'per-suite log' \
    || fail "$f: no paragraph tells to read the per-suite log each \`FAIL\` line names"
  grep -qF 'forge-test.d/' <(skill_text "$f") || fail "$f: does not name the per-suite logs under <git dir>/forge-test.d/"
done
ok per-suite-logs
fi

if want no-failed-tree-refusal; then
for f in skills/*/*.md; do
  flat=$(tr '\n' ' ' <"$f" | tr -s '[:space:]' ' ')
  for bad in 'FORGE_TEST_RERUN' 'fix it or rerun with --force'; do
    case "$flat" in
      *"$bad"*) fail "$f: still names $bad; forge test never refuses a tree that failed" ;;
    esac
  done
done
for f in skills/forge-phase/SKILL.md skills/forge-verify/SKILL.md; do
  flat=$(skill_text "$f" | tr '\n' ' ' | tr -s '[:space:]' ' ')
  for bad in 'forge: tests failed on tree' 'refused rerun' 'failed/<tree>-<tier>' 'Failed tree:'; do
    case "$flat" in
      *"$bad"*) fail "$f: still names $bad; forge test never refuses a tree that failed" ;;
    esac
  done
done
ok no-failed-tree-refusal
fi

if want repeat-proof-loop; then
for f in skills/forge-phase/SKILL.md skills/forge-verify/SKILL.md; do
  block_with <(skill_text "$f") 'forge test --repeat N --one <id>' 'proof' \
    || fail "$f: does not name \`forge test --repeat N --one <id>\` as the proof loop"
done
ok repeat-proof-loop
fi

if want result-line-keys; then
for want in 'forge: tests passed (<tree>)' 'forge: tests failed, log <path>'; do
  grep -qF "$want" skills/forge-phase/SKILL.md || fail "skills/forge-phase/SKILL.md: lost the result-line key $want"
done
ok result-line-keys
fi

flat_of() { tr '\n' ' ' <"$1" | tr -s ' '; }
if want skills-removed; then
for d in skills/forge-build skills/forge-audit; do
  [ ! -e "$d" ] || fail "$d/: still exists; /forge-build and /forge-audit are removed"
done
ok skills-removed
fi


if want discuss-auto-design; then
d=$(flat_of skills/forge-discuss/SKILL.md)
for ban in 'stopped at spec; mockups wait for an interactive discuss' 'Auto: mockups wait for an interactive discuss' \
  'waits for an interactive discuss: mockups'; do
  case "$d" in
    *"$ban"*) fail "skills/forge-discuss/SKILL.md: auto mode still holds \`$ban\`; a UI feature runs Design and Mockups with the operator" ;;
  esac
done
case "$d" in
  *'waits for an interactive discuss: reopen'*) ;;
  *) fail "skills/forge-discuss/SKILL.md: auto mode lost the Reopen stop \`waits for an interactive discuss: reopen\`" ;;
esac
auto_ok=
while IFS= read -r b; do
  case "$b" in *Design*) ;; *) continue ;; esac
  case "$b" in *Mockups*) ;; *) continue ;; esac
  case "$b" in *'`AskUserQuestion`'*) auto_ok=1 ;; esac
done < <(awk '/^## /{ p = ($0 ~ /^## Auto mode[[:space:]]*$/) } p' skills/forge-discuss/SKILL.md |
  awk '/^[[:space:]]*$/ || /^#/ || /^[[:space:]]*- / { if (cur != "") print cur; cur = "" } /^[[:space:]]*$/ || /^#/ { next } { cur = cur $0 " " } END { if (cur != "") print cur }' |
  tr -s ' \t' ' ')
[ -n "$auto_ok" ] || fail "skills/forge-discuss/SKILL.md: ## Auto mode names no bullet sending Design and Mockups to the operator through \`AskUserQuestion\`"
ok discuss-auto-design
fi

if want verify-headless-project-browser; then
block_with <(vtext) 'PWDEBUG' 'forge-browser start --headed' 'only' 'visible' \
  'Playwright' 'Cypress' 'headless' '`--headed`' '`--ui`' '`--debug`' 'operator' '`mcp__jbc__*`' \
  || fail "skills/forge-verify/SKILL.md: no rule makes the forge-jbc Chrome of \`forge-browser start --headed\` the only visible browser and runs a project's Playwright, Cypress or similar suite headless, never with \`--headed\`, \`--ui\`, \`--debug\` or \`PWDEBUG\`, even when the operator asks, showing it through \`mcp__jbc__*\`"
ok verify-headless-project-browser
fi

if want verify-gap-tag-decides; then
verify_tag=$(skill_step <(vtext) 7 | tr -s '[:space:]' ' ')
case "$verify_tag" in
  *'phase does this gap fall in'*|*'ask the operator which'*) fail "skills/forge-verify/SKILL.md: step 7 asks the operator which phase a gap falls in" ;;
esac
case "$verify_tag" in
  *'tag it yourself'*'never ask'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 7 does not tag an unclear gap itself without asking" ;;
esac
ok verify-gap-tag-decides
fi

if want verify-replan-prefix; then
vf=skills/forge-verify/SKILL.md
v7=$(vstep 7)
fixes=$(verify_sec 'Inline fixes')
grep -qF '`Replan: `' <<<"$v7" \
  || fail "$vf: step 7 does not name the \`Replan: \` gap prefix"
has_sent "$v7" '`Replan: `' 'capital R' 'colon' 'one space' \
  || fail "$vf: step 7 does not give \`Replan: \` as the exact prefix (capital R, colon, one space)"
has_sent "$v7" '`Replan: `' 'only when' 'existing planned task' 'approach' 'replaced' 'not added to' \
  || fail "$vf: step 7 does not prefix a gap \`Replan: \` only when an existing planned task's approach must be replaced, not added to"
has_sent "$v7" '`Replan: `|replan' '`forge next`' 'full replan' "phase" \
  || fail "$vf: step 7 does not say a \`Replan: \` gap makes \`forge next\` run the full replan for that gap's phase"
has_sent "$v7" 'every other gap' '`needs plan: `' 'additive' 'no prefix' \
  || fail "$vf: step 7 does not make every other gap, \`needs plan: \` results included, additive with no prefix"
v9=$(vstep 9)
! grep -qF 'Replan: ' <<<"$v9 $fixes" \
  || fail "$vf: step 9 or Inline fixes changed its \`needs plan: \` handling to use the \`Replan: \` prefix"
ok verify-replan-prefix
fi

if want discuss-split-no-approval; then
split_step2=$(awk '
  /^## / { in_sec = ($0 ~ /^## Split[[:space:]]*$/); next }
  in_sec && /^[0-9]+\. / { in_n = (index($0, "2. ") == 1) }
  in_sec && in_n { printf "%s ", $0 }
' skills/forge-discuss/SKILL.md | tr -s '[:space:]' ' ')
[ -n "$split_step2" ] || fail "skills/forge-discuss/SKILL.md: no step 2 under ## Split"
for ban in 'approv' 'Approv' 'ask the operator' 'Changes go back to the splitter' 'In auto mode'; do
  case "$split_step2" in
    *"$ban"*) fail "skills/forge-discuss/SKILL.md: Split step 2 still holds \`$ban\`; it prints the phase table and continues with no approval question in every mode" ;;
  esac
done
for want in 'table' 'slug' 'goal' 'depends' 'requirements' '`Files: `' 'session text' 'step 3' 'no question'; do
  case "$split_step2" in
    *"$want"*) ;;
    *) fail "skills/forge-discuss/SKILL.md: Split step 2 does not print the phase table (slug, goal, depends, requirements, files from each phase's \`Files: \` spec bullet) in the session text and continue to step 3 with no question (missing $want)" ;;
  esac
done
ok discuss-split-no-approval
fi

if want launch-refused-exit8; then
finish=$(awk '
  /^## / { in_sec = ($0 ~ /^## Finish[[:space:]]*$/); next }
  in_sec { printf "%s ", $0 }
' skills/forge-phase/SKILL.md | tr -s '[:space:]' ' ')
exit8=$(awk '{
  i = match($0, /[Ee]xit 8[^0-9]/); if (!i) exit
  s = substr($0, i + 6)
  j = match(s, /Exits? [0-9]|For a `blocked`/)
  print (j ? substr(s, 1, j - 1) : s)
}' <<<"$finish")
[ -n "$exit8" ] || fail "skills/forge-phase/SKILL.md: Finish does not handle exit 8 of \`FORGE_ROOT=R forge done N\`"
for want in 'already reported' 'notify' 'result: Phase N done'; do
  case "$exit8" in
    *"$want"*) ;;
    *) fail "skills/forge-phase/SKILL.md: Finish's exit 8 of forge done is not launch refused, already reported, done with no second notify, ending with \`result: Phase N done: <summary>\` (missing $want)" ;;
  esac
done
verify_next=$(skill_step <(vtext) 9)
case "$verify_next" in
  *[Ee]'xit 8'*) ;;
  *) fail "skills/forge-verify/SKILL.md: step 9 does not handle exit 8 of \`FORGE_ROOT=R forge next <track>/<feature>\`" ;;
esac
v8=${verify_next#*xit 8}
for want in 'not a failure' 'not started'; do
  case "$v8" in
    *"$want"*) ;;
    *) fail "skills/forge-verify/SKILL.md: step 9 does not treat exit 8 of forge next as not a failure, ending with \`result: Verify <result>, ...\` naming the not-started targets (missing $want)" ;;
  esac
done
ok launch-refused-exit8
fi

if want todo-dated; then
vf=skills/forge-verify/SKILL.md
vflat=$(flat_of <(vtext))
grep -qF 'date +%F' <(vtext) || fail "$vf: does not take today's date from \`date +%F\`"
block_with <(vtext) 'operator deferred' '`- <today YYYY-MM-DD> <summary> (P<n>, <feature> verify, operator deferred) — <screenshot path>`' '`R/.forge/todo.md`' \
  || fail "$vf: Browser pass does not append a P2/P3 finding as \`- <today YYYY-MM-DD> <summary> (P<n>, <feature> verify, operator deferred) — <screenshot path>\`"
case "$vflat" in
  *'- <summary> (P<n>'*) fail "$vf: still writes the undated todo line \`- <summary> (P<n>, ...)\`" ;;
esac
verify_record=$(skill_step <(vtext) 7)
case "$verify_record" in
  *'- <today YYYY-MM-DD>'*) ;;
  *) fail "$vf: step 7 does not start every todo line verify writes with \`- <today YYYY-MM-DD>\`" ;;
esac
case "$verify_record" in
  *'`flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): defer <track>/<feature> verify findings" -- .forge/todo.md`'*) ;;
  *) fail "$vf: step 7 lost its single flock docs(todo): defer <track>/<feature> verify findings commit" ;;
esac
[ "$(grep -cF 'docs(todo):' <(vtext))" -eq 1 ] || fail "$vf: does not keep exactly one docs(todo): commit"
for want in 'operator deferred' '.forge/todo.md'; do
  case "$vflat" in *"$want"*) ;; *) fail "$vf: lost \`$want\`" ;; esac
done
sf=skills/forge-ship/SKILL.md
block_with "$sf" '`R/.forge/todo.md`' '`- <today YYYY-MM-DD> <text>`' 'date +%F' \
  '`flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): <summary>" -- .forge/todo.md`' \
  '`failed: Ship <track>/<feature> stopped: <work> recorded in .forge/todo.md`' \
  || fail "$sf: the out-of-spec Rules bullet does not append \`- <today YYYY-MM-DD> <text>\` (today from \`date +%F\`) with the flock docs(todo): <summary> commit and its failed: line"
ok todo-dated
fi

if want discuss-pruned; then
df=skills/forge-discuss/SKILL.md
d=$(flat_of "$df")
for ban in 'forge jev' 'forge-jev' 'forge intake' '## Budget' '`budget`' 'run Budget' 'build.json' \
  'header `Build`' 'build question' 'build answer' 'physical build' 'triaged' '/forge-audit' 'docs(todo)'; do
  case "$d" in
    *"$ban"*) fail "$df: still names \`$ban\`; jev, intake, budget, build and the audit loop are removed from discuss" ;;
  esac
done
case "$d" in
  *'one of the five'*) ;;
  *) fail "$df: Discuss step 3 does not keep a typed tag only when it is one of the five" ;;
esac
ok discuss-pruned
fi

if want verify-pruned; then
vd=skills/forge-verify
for f in budget-guard perf-continuation; do
  [ ! -e "$vd/$f.md" ] || fail "$vd/$f.md: still exists; budget guard and perf continuation are removed"
  bad=$(grep -rnF "$f" skills hooks agents || true)
  [ -z "$bad" ] || fail "skills: still point at $vd/$f.md:" "$bad"
done
for f in walkthrough owed-checks reviewer-fallback; do
  [ -s "$vd/$f.md" ] || fail "$vd/$f.md: is missing; verify keeps it"
done
v=$(cat "$vd"/*.md | tr '\n' ' ' | tr -s '[:space:]' ' ')
for ban in 'forge jev' 'forge-jev' 'Jev answer' 'contract' 'pinning' 'Pinning' 'budget' 'Budget' 'build.json' \
  'procedure.json' 'build: true' 'build feature' 'build walkthrough' 'triaged' '/forge-audit' 'forge perf' \
  'Perf continuation' 'perf stop'; do
  case "$v" in
    *"$ban"*) fail "$vd: still names \`$ban\`; jev, contracts, budget, build, the audit loop and perf are removed from verify" ;;
  esac
done
case "$v" in
  *'`jev_task`'*) ;;
  *) fail "$vd: Browser pass lost its \`jev_task\` run" ;;
esac
has_sent "$(vstep 7)" 'reviewer-fallback.md' \
  || fail "$vd/SKILL.md: step 7 lost its forge-reviewer fallback pointer"
grep -qF 'forge review <track>/<feature> --base M' "$vd/SKILL.md" \
  || fail "$vd/SKILL.md: step 6 lost its one final review"
ok verify-pruned
fi

if want ship-pruned; then
sp=skills/forge-ship/SKILL.md
s=$(flat_of "$sp")
for ban in 'build-gate' 'build.json' 'release.json' 'queued for the' 'forge release' 'perf check advisory' \
  'triaged' '/forge-audit'; do
  case "$s" in
    *"$ban"*) fail "$sp: still names \`$ban\`; the build gate, the release window, the perf advisory and the audit loop are removed from ship" ;;
  esac
done
ok ship-pruned
fi

if want discuss-research-overlap; then
df=skills/forge-discuss/SKILL.md
dro_step() {
  awk -v sec="$1" -v n="$2" '
    /^## / { in_sec = ($0 ~ ("^## " sec "[[:space:]]*$")); next }
    in_sec && /^[0-9]+\. / { in_n = (index($0, n ". ") == 1) }
    in_sec && in_n { printf "%s ", $0 }
  ' "$df" | tr -s '[:space:]' ' '
}
dro_sec() {
  awk -v sec="$1" '
    /^## / { in_sec = ($0 ~ ("^## " sec "[[:space:]]*$")); next }
    in_sec { printf "%s ", $0 }
  ' "$df" | tr -s '[:space:]' ' '
}
d4=$(dro_step Discuss 4)
d5=$(dro_step Discuss 5)
p3=$(dro_step Pick 3)
reopen6=$(dro_step Reopen 6)
dauto=$(dro_sec 'Auto mode')
dresearch=$(dro_sec Research)
dflat=$(flat_of "$df")
[ -n "$d4" ] || fail "$df: no step 4 under ## Discuss"
[ -n "$d5" ] || fail "$df: no step 5 under ## Discuss"
[ -n "$p3" ] || fail "$df: no step 3 under ## Pick"
[ -n "$reopen6" ] || fail "$df: no step 6 under ## Reopen"
[ -n "$dauto" ] || fail "$df: no ## Auto mode section"
[ -n "$dresearch" ] || fail "$df: no ## Research section"

case "$d4" in
  *'forge commit <track>/<feature> spec'*'`forge-researcher`'*) ;;
  *) fail "$df: Discuss step 4 does not spawn one \`forge-researcher\` per question after \`forge commit <track>/<feature> spec\` succeeds" ;;
esac
has_sent "$d4" '`forge-researcher`' 'background' \
  || fail "$df: Discuss step 4 does not spawn the researchers in the background"
has_sent "$d4" 'step 5' 'without waiting|not wait' \
  || fail "$df: Discuss step 4 does not go on to step 5's UI check without waiting for the researchers"

has_sent "$d5" 'Split' 'every researcher|researchers' 'returned' '`forge commit <track>/<feature> research`' 'every mockup' 'approved' \
  || fail "$df: Discuss step 5 does not start Split only once every researcher has returned, \`F/research.json\` is merged and committed with \`forge commit <track>/<feature> research\` and every mockup in \`F/design.json\` is approved"
has_sent "$d5" 'Design' 'Mockups' 'researchers?' 'while|beside|alongside' \
  || fail "$df: Discuss step 5 does not run Design and Mockups with the operator while the researchers work"
has_sent "$d5" 'otherwise|non-UI|not a UI' 'wait' 'researchers?' \
  || fail "$df: Discuss step 5's non-UI path does not wait for the researchers before Research steps 3-4 and Split"
case "$d5" in
  *'then Research and Split unattended'*) fail "$df: Discuss step 5's auto sentence still runs Research after Design and Mockups (\`then Research and Split unattended\`) instead of naming the overlap" ;;
esac
has_sent "$d5" 'auto mode' 'researchers?' 'background|beside|while|alongside' \
  || fail "$df: Discuss step 5's auto sentence does not name the researchers working beside Design and Mockups"

has_sent "$dflat" '`blocked:' '`AskUserQuestion`' 'between (mockup )?rounds' \
  || fail "$df: a researcher's \`blocked: <decision>\` reply is not asked through \`AskUserQuestion\` between mockup rounds"
has_sent "$dflat" '`blocked:' 'Approve or Revise' 'never while|not while' \
  || fail "$df: a researcher's \`blocked:\` reply is not kept out of an open mockup Approve or Revise question"
has_sent "$dflat" 'notification' 'held|hold' '`AskUserQuestion`' \
  || fail "$df: researcher notifications that arrive while an \`AskUserQuestion\` is open are not held until it returns"
has_sent "$dflat" '`blocked:' 'researcher' 'respawn' \
  || fail "$df: a researcher answered after its \`blocked:\` reply is not respawned"

has_sent "$dresearch" 'finding' '(after|once) every mockup' 'approved' \
  || fail "$df: Research step 4 brings findings that change a decision to the operator before every mockup is approved"
has_sent "$dresearch" 'surface' 'brief' '`approved: false`' 'Mockups' 'before' \
  || fail "$df: Research does not fold a finding that changes a UI surface into \`brief\`, set \`approved: false\` and rerun Mockups for it before the research commit"
grep -qF '{"questions": []}' <<<"$dresearch" \
  || fail "$df: Research no longer writes \`{\"questions\": []}\` for zero questions"

has_sent "$p3" 'respawn' 'background' 'only' 'R<k>' \
  || fail "$df: Pick step 3 resume does not respawn in the background only the questions no existing \`F/research/R<k>.json\` answers"
has_sent "$p3" 'after the last' 'R<k>' \
  || fail "$df: Pick step 3 resume does not number new researchers after the last \`R<k>\`"
has_sent "$p3" 'researchers?|respawn' 'Design' 'Mockups' 'beside|alongside|while' \
  || fail "$df: Pick step 3 resume does not run Design or Mockups beside the respawned researchers"

has_sent "$dauto" 'researchers?' 'background' 'Design|Mockups' \
  || fail "$df: ## Auto mode does not name the overlap of background researchers beside Design and Mockups"
has_sent "$dauto" '`blocked:' 'between (mockup )?rounds' \
  || fail "$df: ## Auto mode's list of what reaches the operator does not ask researcher \`blocked:\` replies between mockup rounds"

case "$reopen6" in
  *'Run Research for the new questions only'*) ;;
  *) fail "$df: Reopen step 6 no longer runs Research for the new questions only after step 5's Mockups" ;;
esac
ok discuss-research-overlap
fi

new_run() { (cd "$new_tmp/repo" && bash -c "${new_cmd//<repo>/$new_tmp/repo}" 2>"$new_tmp/err"); }
if want new-track-baseline; then
nf=skills/forge-new/SKILL.md
new_list=$(awk '
  /^## / { in_sec = ($0 ~ /^## Track open[[:space:]]*$/); next }
  in_sec && /^[0-9]+\. / { in_n = (index($0, "2. ") == 1) }
  in_sec && in_n {
    sub(/^[[:space:]]+/, "")
    if ($0 ~ /^```/) next
    if (sub(/\\$/, "")) { printf "%s", $0; next }
    printf "%s ", $0
  }
' "$nf")
new_list=${new_list%%Rank them*}
case "$new_list" in
  *'jq -'*) ;;
  *) fail "$nf: Track open step 2 lists no candidates through a jq command" ;;
esac
new_cmd="jq -${new_list#*jq -}"
while :; do
  case "$new_cmd" in
    *[[:space:].:\`]) new_cmd=${new_cmd%?} ;;
    *) break ;;
  esac
done
case "$new_cmd" in
  *'.forge/concerns.json'*) ;;
  *) fail "$nf: Track open step 2's jq command does not read <repo>/.forge/concerns.json" ;;
esac
new_tmp=$(mktemp -d)
mkdir -p "$new_tmp/repo/.forge"
cat >"$new_tmp/repo/.forge/concerns.json" <<'JSON'
{"concerns": [
  {"id": "C-01", "area": "performance", "files": [".forge/perf.json"], "severity": "medium", "evidence": [], "status": "open",
   "text": "perf metric `build_ms`: baseline 830.5 ms, measured 1200 ms at abc1234, ratio 1.44, band 3", "date": "2026-10-01"},
  {"id": "C-02", "area": "performance", "files": [".forge/perf.json"], "severity": "high", "evidence": [], "status": "open",
   "focus": ["performance", "scaling"],
   "text": "perf metric `queries`: baseline 412 queries, measured 500 queries at abc1234", "date": "2026-10-01"},
  {"id": "C-03", "area": "performance", "files": [".forge/perf.json"], "severity": "low", "evidence": [], "status": "open",
   "text": "perf metric `gone`: baseline 3 calls, measured 9 calls at abc1234", "date": "2026-10-01"},
  {"id": "C-04", "area": "performance", "files": ["src/app.js"], "severity": "medium", "evidence": [], "status": "open",
   "text": "Startup is slow on cold cache.", "date": "2026-10-01"},
  {"id": "C-05", "area": "workflow", "files": [".forge/perf.json"], "severity": "medium", "evidence": [], "status": "open",
   "text": "perf metric `build_ms`: baseline 830.5 ms, measured 1200 ms at abc1234", "date": "2026-10-01"},
  {"id": "C-06", "area": "performance", "files": [".forge/perf.json"], "severity": "medium", "evidence": [], "status": "resolved",
   "text": "perf metric `build_ms`: baseline 830.5 ms, measured 1200 ms at abc1234", "date": "2026-10-01"},
  {"id": "C-07", "area": "performance", "files": [".forge/perf.json"], "severity": "low", "evidence": [], "status": "open",
   "text": "See perf metric `build_ms` after the cache lands.", "date": "2026-10-01"},
  {"id": "C-08", "area": "performance", "files": [".forge/perf.json"], "severity": "medium", "evidence": [], "status": "open",
   "text": "perf metric `build`: baseline 7 ms, measured 9 ms at abc1234", "date": "2026-10-01"},
  {"id": "C-09", "area": "performance", "files": ["src/app.js"], "severity": "high", "evidence": [], "status": "open"}
]}
JSON
new_today='C-01 — performance — medium — —
C-02 — performance — high — performance, scaling
C-03 — performance — low — —
C-04 — performance — medium — —
C-05 — workflow — medium — —
C-07 — performance — low — —
C-08 — performance — medium — —
C-09 — performance — high — —'
new_out=$(new_run) || { new_e=$(cat "$new_tmp/err"); rm -rf "$new_tmp"; fail "$nf: Track open step 2's command fails without a .forge/perf.json: $new_e"; }
[ "$new_out" = "$new_today" ] || { rm -rf "$new_tmp"; fail "$nf: Track open step 2 changes the candidate lines without a .forge/perf.json" "want:" "$new_today" "got:" "$new_out"; }
cat >"$new_tmp/repo/.forge/perf.json" <<'JSON'
{"metrics": {
  "build_ms": {"kind": "time", "unit": "ms", "baseline": 830.5, "noise": 1.2, "commit": "0123456789abcdef0123456789abcdef01234567", "date": "2026-10-01"},
  "queries": {"kind": "count", "unit": "queries", "baseline": 412, "tolerance": 0, "commit": "0123456789abcdef0123456789abcdef01234567", "date": "2026-10-01"}
}}
JSON
new_out=$(new_run) || { new_e=$(cat "$new_tmp/err"); rm -rf "$new_tmp"; fail "$nf: Track open step 2's command fails with a .forge/perf.json: $new_e"; }
rm -rf "$new_tmp"
[ "$new_out" = "$new_today" ] || fail "$nf: Track open step 2 changes the candidate lines when a .forge/perf.json exists; it no longer reads the perf ledger" "want:" "$new_today" "got:" "$new_out"
case "$new_cmd" in
  *perf.json*|*baseline*) fail "$nf: Track open step 2's jq command still reads .baseline from .forge/perf.json" ;;
esac
ok new-track-baseline
fi

new_step() {
  awk -v n="$1. " '
    /^## / { in_sec = ($0 ~ /^## Track open[[:space:]]*$/); next }
    in_sec && /^[0-9]+\. / { in_n = (index($0, n) == 1) }
    in_sec && in_n { printf "%s ", $0 }
  ' "$nf" | tr -s '[:space:]' ' '
}
if want new-track-seeds; then
nf=skills/forge-new/SKILL.md
seed_s2=$(new_step 2)
[ -n "$seed_s2" ] || fail "$nf: no step 2 under ## Track open"
seed_list=${seed_s2%%Rank them*}
for want in '.forge/seeds.md' '.forge/todo.md' '`- `' 'seed: ' 'todo: ' '.forge/concerns.json'; do
  case "$seed_list" in
    *"$want"*) ;;
    *) fail "$nf: Track open step 2 does not list the \`- \` lines of .forge/seeds.md and .forge/todo.md labeled \`seed: \` or \`todo: \` beside the open concerns before ranking them (missing $want)" ;;
  esac
done
for want in heading blank comment; do
  grep -qi -- "$want" <<<"$seed_list" \
    || fail "$nf: Track open step 2 does not state that heading, blank and comment lines of .forge/seeds.md and .forge/todo.md are not candidates (missing $want)"
done
grep -qiE '(missing|absent|no) `?(\.forge/)?seeds\.md|seeds\.md`? (is |file is )?(missing|absent)' <<<"$seed_list" \
  || fail "$nf: Track open step 2 does not state that a missing .forge/seeds.md adds no candidates"
seed_rank=${seed_s2#*Rank them}
[ "$seed_rank" != "$seed_s2" ] || fail "$nf: Track open step 2 does not rank the candidates"
case "$seed_s2" in
  *jev*|*'<<'*) fail "$nf: Track open step 2 still ranks through forge jev or splices candidates into a command; the session ranks them itself" ;;
esac
case "$seed_rank" in
  *'one numbered list'*) ;;
  *) fail "$nf: Track open step 2 does not print the seed, todo and concern candidates as one numbered list" ;;
esac
grep -qiE 'file order' <<<"$seed_rank" && grep -qiE 'seeds?\b.{0,120}todos?\b.{0,120}concerns?\b' <<<"$seed_rank" \
  || fail "$nf: Track open step 2's ranking does not break ties in file order: seeds, then todos, then concerns"
ok new-track-seeds
fi

if want new-track-seeds-commit; then
nf=skills/forge-new/SKILL.md
seed_s6=$(new_step 6)
[ -n "$seed_s6" ] || fail "$nf: no step 6 under ## Track open"
for want in 'seed' 'todo' '.forge/seeds.md' '.forge/todo.md' \
  'flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" git commit -m "docs(todo): '; do
  case "$seed_s6" in
    *"$want"*) ;;
    *) fail "$nf: Track open step 6 does not remove accepted seed and todo lines from .forge/seeds.md and .forge/todo.md and commit under the forge.lock flock with a docs(todo) message (missing $want)" ;;
  esac
done
grep -qiE 'came from|own file|its file|file it (came|comes) from' <<<"$seed_s6" \
  || fail "$nf: Track open step 6 does not remove each accepted seed or todo line from the file it came from"
grep -qiE '\b(one|a single|single) (docs\(todo\) )?commit\b' <<<"$seed_s6" \
  || fail "$nf: Track open step 6 does not commit the removed seed and todo lines in one commit"
grep -qiE 'only[^.]{0,40}(files?|\.md)' <<<"$seed_s6" \
  || fail "$nf: Track open step 6's commit does not name only the files whose lines it removed"
seed_n=$(grep -o 'git commit -m "docs(todo): ' <<<"$seed_s6" | wc -l)
[ "$seed_n" -eq 1 ] || fail "$nf: Track open step 6 holds $seed_n docs(todo) git commit commands, want exactly one"
grep -q 'seeds\.md' skills/forge-discuss/SKILL.md \
  && fail "skills/forge-discuss/SKILL.md: feature discuss names .forge/seeds.md; it stays todos and concerns only"
ok new-track-seeds-commit
fi

step6_exclude() {
  local f=$1 s6
  s6=$(skill_step "$f" 6)
  [ -n "$s6" ] || fail "$f: no step 6 under ## Steps"
  case "$s6" in
    *'`git -C <repo> check-ignore -q .claude/worktrees/ || echo .claude/worktrees/ >> "$(git -C <repo> rev-parse --path-format=absolute --git-common-dir)/info/exclude"`'*) ;;
    *) fail "$f: step 6 does not exclude .claude/worktrees/ through git check-ignore and the common dir's info/exclude" ;;
  esac
  case "${s6%%check-ignore*}" in
    *'worktree add'*) fail "$f: step 6 adds the worktree before excluding .claude/worktrees/" ;;
  esac
}
if want quick-step6-exclude; then
step6_exclude skills/forge-quick/SKILL.md
ok quick-step6-exclude
fi

if want debug-step6-exclude; then
step6_exclude skills/forge-debug/SKILL.md
ok debug-step6-exclude
fi

todo_owner() {
  local where=$1 text=$2
  case "$text" in
    *'`out of scope: todo: '*'{"owner": "todo", "reason": "<reason>"}'*) ;;
    *) fail "$where does not record an \`out of scope: todo: <reason>\` reply as \`deferred\` {\"owner\": \"todo\", \"reason\": \"<reason>\"}" ;;
  esac
  has_sent "$text" '`out of scope: phase <N>: `' 'open' \
    || fail "$where does not leave the finding open on an \`out of scope: phase <N>: \` reply"
  has_sent "$text" 'high' 'security' '(out[ -]of[ -]scope|deferred)' '(stays?|leaves?|left|remains?|keeps?).*open' \
    || fail "$where does not keep a high security-class finding open on an out of scope reply"
}

if want verify-fix-recording; then
vf=skills/forge-verify/SKILL.md
vfix=$(verify_sec 'Inline fixes')
[ -n "$vfix" ] || fail "$vf: no ## Inline fixes section"
vfix_b=${vfix#* b. For review findings}
vfix_b=${vfix_b%% c. *}
case "$vfix_b" in
  *'`forge-fixer`'*'F/split.json'*) ;;
  *) fail "$vf: ## Inline fixes step b's forge-fixer spawn prompts do not pass F/split.json to name an owner phase" ;;
esac
for want in '`fixed`' '`not a defect: `' '`out of scope: phase <N>: `' '`out of scope: todo: `' '`spec requires: `' \
  '`deferred`' '`security`' 'forge fixes'; do
  case "$vfix" in
    *"$want"*) ;;
    *) fail "$vf: ## Inline fixes' recording rule does not name $want (fixed from fixed; not a defect: dismisses except a high security finding; out of scope: todo: sets a todo deferred owner, out of scope: phase leaves it open)" ;;
  esac
done
bad=$(grep -nE 'forge (owner|deferred)([^a-z_-]|$)' skills/forge-verify/*.md || true)
[ -z "$bad" ] || fail "skills/forge-verify: verify still runs the removed \`forge owner\` or \`forge deferred\`:" "$bad"
todo_owner "$vf: ## Inline fixes" "$vfix"
grep -qE '`deferred`[^.]*never[^.]*`dismissed`|never[^.]*`dismissed`[^.]*`deferred`' <<<"$vfix" \
  || fail "$vf: ## Inline fixes does not say an out of scope outcome sets \`deferred\`, never \`dismissed\`"
case "$vfix" in
  *'`spec requires: `'*'asks the operator with `AskUserQuestion`'*"settled: <operator's words>"*) ;;
  *) fail "$vf: ## Inline fixes does not route \`spec requires: \` to the operator with AskUserQuestion, writing \`dismissed\` as \`settled: <operator's words>\` on the finding" ;;
esac
bad=$(grep -nE 'forge settle|settled\.json|apply_settled|Escalate|forge-escalator' skills/forge-verify/*.md || true)
[ -z "$bad" ] || fail "skills/forge-verify: verify still routes a ruling through forge settle, F/settled.json, apply_settled or Escalate; it asks the operator and writes settled: <operator's words> on the finding:" "$bad"
vsr_segs=$(sed -e 's/`not a defect: `/\n&/g' -e 's/`out of scope: /\n&/g' -e 's/`fixed`/\n&/g' -e 's/`spec requires: `/\n&/g' -e 's/Everything else/\n&/g' <<<"$vfix" | grep -F '`spec requires: `' | grep -F 'asks the operator' || true)
grep -qE 'never[^.;]*`dismissed`' <<<"$vsr_segs" \
  || fail "$vf: ## Inline fixes does not say a \`spec requires: \` outcome never sets \`dismissed\` from the fix"
bad=$(tr ';' '\n' <<<"$vsr_segs" | sed 's/\. /.\n/g' | grep -F '`dismissed`' | grep -vi 'never' | grep -vF "settled: <operator's words>" || true)
[ -z "$bad" ] || fail "$vf: ## Inline fixes sets \`dismissed\` from a \`spec requires: \` outcome:" "$bad"
grep -qE '(high|security)[^.]*`not a defect: `[^.]*asks? the operator|`not a defect: `[^.]*(high|security)[^.]*asks? the operator' <<<"$vfix" \
  || fail "$vf: ## Inline fixes does not ask the operator on a high security-class \`not a defect: \` outcome"
for want in '<file>:<line> <title> (deferred from phase <N>: <reason>)' 'date +%F' '.forge/todo.md' 'review/<repo>.json' 'same commit'; do
  case "$vfix" in
    *"$want"*) ;;
    *) fail "$vf: ## Inline fixes' todo deferral does not name $want (append \`- <date> <file>:<line> <title> (deferred from phase <N>: <reason>)\` to the finding's repo .forge/todo.md, root for review.json, the <repo> child for review/<repo>.json, in the same commit as the review record)" ;;
  esac
done
grep -qE 'Codex-only[^.]*advisory|advisory[^.]*Codex-only' <<<"$vfix" \
  || fail "$vf: ## Inline fixes does not say Codex-only mediums are advisory, get no fixer and are not chased"
vgap=$(vstep 7)
for want in '`dismissed`' "settled: <operator's words>"; do
  case "$vgap" in
    *"$want"*) ;;
    *) fail "$vf: step 7 no longer states that a finding with a non-empty $want never becomes a gap" ;;
  esac
done
ok verify-fix-recording
fi

if want ship-fix-recording; then
ship=skills/forge-ship/SKILL.md
sfix=$(skill_step "$ship" 3)
[ -n "$sfix" ] || fail "$ship: no step 3 under ## Steps"
sfix37="$sfix $(skill_step "$ship" 7)"
case "$sfix" in
  *'`forge-fixer`'*'F/split.json'*) ;;
  *) fail "$ship: step 3's forge-fixer spawn prompts do not pass F/split.json to name an owner phase" ;;
esac
for want in '`fixed`' '`not a defect: `' '`out of scope: phase <N>: `' '`out of scope: todo: `' '`spec requires: `' \
  '`deferred`' '`security`' 'forge fixes'; do
  case "$sfix" in
    *"$want"*) ;;
    *) fail "$ship: step 3's recording rule does not name $want (fixed from fixed; not a defect: dismisses except a high security finding; out of scope: todo: sets a todo deferred owner, out of scope: phase leaves it open)" ;;
  esac
done
bad=$(grep -nE 'forge (owner|deferred)([^a-z_-]|$)' "$ship" || true)
[ -z "$bad" ] || fail "$ship: ship still runs the removed \`forge owner\` or \`forge deferred\`:" "$bad"
todo_owner "$ship: step 3" "$sfix"
grep -qE '`deferred`[^.]*never[^.]*`dismissed`|never[^.]*`dismissed`[^.]*`deferred`' <<<"$sfix" \
  || fail "$ship: step 3 does not say an out of scope outcome sets \`deferred\`, never \`dismissed\`"
case "$sfix" in
  *'`spec requires: `'*'asks the operator with `AskUserQuestion`'*"settled: <operator's words>"*) ;;
  *) fail "$ship: step 3 does not route \`spec requires: \` to the operator with AskUserQuestion, writing \`dismissed\` as \`settled: <operator's words>\` on the finding" ;;
esac
bad=$(grep -nE 'forge settle|settled\.json|apply_settled|Escalate|forge-escalator|forge-diagnoser|escalation\.json|later `forge review` round' "$ship" || true)
[ -z "$bad" ] || fail "$ship: ship still routes a ruling through forge settle, F/settled.json, apply_settled, Escalate or the escalator; it asks the operator and writes settled: <operator's words> on the finding:" "$bad"
ssr_segs=$(sed -e 's/`not a defect: `/\n&/g' -e 's/`out of scope: /\n&/g' -e 's/`fixed`/\n&/g' -e 's/`spec requires: `/\n&/g' -e 's/Everything else/\n&/g' <<<"$sfix" | grep -F '`spec requires: `' | grep -F 'asks the operator' || true)
grep -qE 'never[^.;]*`dismissed`' <<<"$ssr_segs" \
  || fail "$ship: step 3 does not say a \`spec requires: \` outcome never sets \`dismissed\` from the fix"
bad=$(tr ';' '\n' <<<"$ssr_segs" | sed 's/\. /.\n/g' | grep -F '`dismissed`' | grep -vi 'never' | grep -vF "settled: <operator's words>" || true)
[ -z "$bad" ] || fail "$ship: step 3 sets \`dismissed\` from a \`spec requires: \` outcome:" "$bad"
grep -qE '(high|security)[^.]*`not a defect: `[^.]*asks? the operator|`not a defect: `[^.]*(high|security)[^.]*asks? the operator' <<<"$sfix" \
  || fail "$ship: step 3 does not ask the operator on a high security-class \`not a defect: \` outcome"
sstep7=$(skill_step "$ship" 7)
case "$sstep7" in
  *'ask the operator'*'security'*"settled: <operator's words>"*) ;;
  *) fail "$ship: step 7 does not ask the operator about each open finding and, on a high security-class one, set \`dismissed\` to \`settled: <operator's words>\`" ;;
esac
for want in '<file>:<line> <title> (deferred from phase <N>: <reason>)' 'date +%F' '.forge/todo.md' 'review/<repo>.json' 'same commit'; do
  case "$sfix" in
    *"$want"*) ;;
    *) fail "$ship: step 3's todo deferral does not name $want (append \`- <date> <file>:<line> <title> (deferred from phase <N>: <reason>)\` to the finding's repo .forge/todo.md, in the same commit as the review record)" ;;
  esac
done
grep -qE 'Codex-only[^.]*advisory|advisory[^.]*Codex-only' <<<"$sfix37" \
  || fail "$ship: steps 3 and 7 do not say Codex-only mediums are advisory, get no fixer and are not chased"
for want in 'forge fixes <track>/<feature> --record F/review-<repo>.json' 'own output `F/fixes/<repo>-F<k>.json`' \
  'never two for one file' 'run_in_background: false' 'no model or effort override' \
  'forge.lock' '`F/review/<repo>.json` relative to `R`'; do
  case "$sfix" in
    *"$want"*) ;;
    *) fail "$ship: step 3's fixer spawn and recording do not hold $want (forge fixes --record F/review-<repo>.json, each finding's own output F/fixes/<repo>-F<k>.json, the unchanged spawn and R todo commit rules)" ;;
  esac
done
grep -qiE '`k` count(s|ing) from 1 within (the|a|each|that) repo' <<<"$sfix" \
  || fail "$ship: step 3 does not count the fix record k from 1 within the repo"
grep -qE '`index` of `review` \(`F/review-<repo>\.json`\)|`index` of `review`[^.]*`F/review-<repo>\.json`' <<<"$sfix" \
  || fail "$ship: step 3 does not record each finding at index of review, F/review-<repo>.json"
case "$sfix" in
  *'F/fixes/F<k>.json'*) fail "$ship: step 3 still numbers fix records F/fixes/F<k>.json across repos" ;;
esac
srec=$(skill_step "$ship" 5)
[ -n "$srec" ] || fail "$ship: no step 5 under ## Steps"
for want in '`, fixed`' '`, dismissed: <reason>`' '`, deferred: <owner>`' '`, advisory`' '`, open`'; do
  case "$srec" in
    *"$want"*) ;;
    *) fail "$ship: step 5's final_review line format does not offer $want" ;;
  esac
done
ok ship-fix-recording
fi

if want quick-fix-recording; then
quick=skills/forge-quick/SKILL.md
qfix=$(skill_step "$quick" 9)
[ -n "$qfix" ] || fail "$quick: no step 9 under ## Steps"
qfix910="$qfix $(skill_step "$quick" 10)"
for want in '`fixed`' '`not a defect: `' '`out of scope: phase <N>: `' '`out of scope: todo: `' '`spec requires: `' \
  '`deferred`' 'security'; do
  case "$qfix" in
    *"$want"*) ;;
    *) fail "$quick: step 9's recording rule does not name $want (fixed from fixed; not a defect: dismisses except a high security-class finding; out of scope: todo: sets a todo deferred owner, out of scope: phase leaves it open)" ;;
  esac
done
bad=$(grep -nE 'forge (owner|deferred)([^a-z_-]|$)' "$quick" || true)
[ -z "$bad" ] || fail "$quick: quick still runs the removed \`forge owner\` or \`forge deferred\`:" "$bad"
todo_owner "$quick: step 9" "$qfix"
grep -qE '`deferred`[^.]*never[^.]*`dismissed`|never[^.]*`dismissed`[^.]*`deferred`' <<<"$qfix" \
  || fail "$quick: step 9 does not say an out of scope outcome sets \`deferred\`, never \`dismissed\`"
qsr_segs=$(sed 's/\. /.\n/g' <<<"$qfix" | grep -F '`spec requires: `' | grep -F 'AskUserQuestion' || true)
[ -n "$qsr_segs" ] || fail "$quick: step 9 does not route a \`spec requires: \` outcome to the operator through AskUserQuestion"
grep -qF "settled: <operator's words>" <<<"$qsr_segs" \
  || fail "$quick: step 9 does not write \`dismissed\` as \`settled: <operator's words>\` on a \`spec requires: \` finding after asking the operator"
bad=$(tr ';' '\n' <<<"$qsr_segs" | sed 's/\. /.\n/g' | grep -F '`dismissed`' | grep -viE '(never|no|not)[^`]*`dismissed`' | grep -vF "settled: <operator's words>" || true)
[ -z "$bad" ] || fail "$quick: step 9 sets \`dismissed\` from a \`spec requires: \` outcome other than \`settled: <operator's words>\`:" "$bad"
bad=$(grep -nE 'forge settle|settled\.json|apply_settled|escalator|diagnoser' "$quick" || true)
[ -z "$bad" ] || fail "$quick: quick still names forge settle, F/settled.json, apply_settled, the escalator or the diagnoser; it asks the operator and writes settled: <operator's words> on the finding:" "$bad"
grep -qE '(high|security)[^.]*`not a defect: `[^.]*AskUserQuestion|`not a defect: `[^.]*(high|security)[^.]*AskUserQuestion|`spec requires: `[^.]*(high|security)[^.]*`not a defect: `[^.]*AskUserQuestion' <<<"$qfix" \
  || fail "$quick: step 9 does not send a high security-class \`not a defect: \` outcome to the operator through AskUserQuestion"
for want in '<file>:<line> <title> (deferred from ' ': <reason>)' 'date +%F' '.forge/todo.md' 'same commit'; do
  case "$qfix" in
    *"$want"*) ;;
    *) fail "$quick: step 9's todo deferral does not name $want (append \`- <date> <file>:<line> <title> (deferred from ...: <reason>)\` to the repo's .forge/todo.md, today from date +%F, in the same commit as the review record)" ;;
  esac
done
grep -qE 'Codex-only[^.]*advisory|advisory[^.]*Codex-only' <<<"$qfix910" \
  || fail "$quick: steps 9 and 10 do not say Codex-only mediums are advisory and get no fixer"
ok quick-fix-recording
fi

ptr() { printf 'Read ~/.claude/skills/forge-phase/%s.md and follow it.' "$1"; }
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
raw_sec() {
  awk -v h="## $1" '
    /^## / { t = $0; sub(/[[:space:]]+$/, "", t); in_sec = (t == h); next }
    in_sec { printf "%s ", $0 }
  ' "$pf" | tr -s '[:space:]' ' '
}
moved() {
  local file=skills/forge-phase/$1.md want text
  shift
  [ -s "$file" ] || fail "$file is missing or empty; it holds the text moved out of $pf"
  text=$(tr '\n' ' ' <"$file" | tr -s '[:space:]' ' ')
  for want in "$@"; do
    case "$text" in
      *"$want"*) ;;
      *) fail "$file does not hold the moved text \`$want\`" ;;
    esac
  done
}
if want phase-pointers; then
pf=skills/forge-phase/SKILL.md
for pair in 'Resolver loop:resolver-loop'; do
  h=${pair%%:*} file=${pair#*:}
  n=$(grep -c "^## $h[[:space:]]*\$" "$pf" || true)
  [ "$n" -eq 1 ] || fail "$pf: $n \`## $h\` headings, want exactly one holding its pointer line"
  got=$(trim "$(raw_sec "$h")")
  [ "$got" = "$(ptr "$file")" ] \
    || fail "$pf: ## $h is not the one pointer line \`$(ptr "$file")\`; its text belongs in skills/forge-phase/$file.md" "got: ${got:0:200}"
done
! grep -qF 'skills/forge-phase/perf.md' "$pf" || fail "$pf: still holds a Perf pointer line to skills/forge-phase/perf.md; phases no longer handle Perf"
[ ! -e skills/forge-phase/perf.md ] || fail "skills/forge-phase/perf.md: still exists; phases no longer handle Perf"
for gone in 'Perf:' '`perf` object' 'next_hotspot' 'floor_ms'; do
  ! grep -qF -- "$gone" "$pf" || fail "$pf: still names \`$gone\`; the Perf handling is removed from phases"
done
moved resolver-loop 'FORGE_ROOT=R forge merge <branch>' '`forge-merger`' 'FORGE_ROOT=R forge merge --abort' 'FORGE_ROOT=R forge commit N sync'
case "$(skill_step "$pf" 3)" in
  *'Run the resolver loop with `BASE`'*) ;;
  *) fail "$pf: step 3 Sync no longer runs the resolver loop with BASE" ;;
esac
ok phase-pointers
fi

if want pointer-files; then
ptrs=$(grep -noE 'Read ~/\.claude/skills/[a-z0-9-]+/[a-z0-9-]+\.md and follow it\.' skills/*/*.md || true)
[ -n "$ptrs" ] || fail "no skill holds a pointer line"
while IFS=: read -r f ln m; do
  p=${m#'Read ~/.claude/'}
  p=${p%' and follow it.'}
  [ -f "$p" ] || fail "$f:$ln: pointer line names ~/.claude/$p, but $p does not exist"
done <<<"$ptrs"
ok pointer-files
fi

vptr() { printf 'Read ~/.claude/skills/forge-verify/%s.md and follow it.' "$1"; }
vflat_of() { tr '\n' ' ' | tr -s '[:space:]' ' '; }
vraw_sec() {
  awk -v h="## $1" '
    /^## / { t = $0; sub(/[[:space:]]+$/, "", t); in_sec = (t == h); next }
    in_sec { printf "%s ", $0 }
  ' "$vf" | tr -s '[:space:]' ' '
}
vmoved() {
  local file=skills/forge-verify/$1.md want text
  shift
  [ -s "$file" ] || fail "$file is missing or empty; it holds the text moved out of $vf"
  text=$(vflat_of <"$file")
  for want in "$@"; do
    case "$text" in
      *"$want"*) ;;
      *) fail "$file does not hold the moved text \`$want\`" ;;
    esac
  done
}
if want verify-pointers; then
vf=skills/forge-verify/SKILL.md
for file in resolver-loop browser-pass walkthrough fix-reruns; do
  n=$(grep -cF "$(vptr "$file")" "$vf" || true)
  [ "$n" -eq 1 ] || fail "$vf: $n pointer lines \`$(vptr "$file")\`, want exactly one"
done
for pair in 'Resolver loop:resolver-loop' 'Browser pass:browser-pass'; do
  h=${pair%%:*} file=${pair#*:}
  n=$(grep -c "^## $h[[:space:]]*\$" "$vf" || true)
  [ "$n" -eq 1 ] || fail "$vf: $n \`## $h\` headings, want exactly one holding its pointer line"
  got=$(trim "$(vraw_sec "$h")")
  [ "$got" = "$(vptr "$file")" ] \
    || fail "$vf: ## $h is not the one pointer line \`$(vptr "$file")\`; its text belongs in skills/forge-verify/$file.md" "got: ${got:0:200}"
done
for h in Rules Steps 'Inline fixes'; do
  n=$(grep -c "^## $h[[:space:]]*\$" "$vf" || true)
  [ "$n" -eq 1 ] || fail "$vf: $n \`## $h\` headings; ## $h stays in SKILL.md"
done
for h in Ask Escalate; do
  n=$(grep -c "^## $h[[:space:]]*\$" "$vf" || true)
  [ "$n" -eq 0 ] || fail "$vf: $n \`## $h\` headings; the AskUserQuestion Rules bullet replaces ## $h"
done
[ ! -e skills/forge-verify/escalate.md ] || fail "skills/forge-verify/escalate.md: still exists; verify asks the operator through the Rules bullet"
grep -qF "$(vptr escalate)" "$vf" && fail "$vf: still points at \`$(vptr escalate)\`"
vs6=$(trim "$(skill_step "$vf" 6)")
case "$vs6" in
  *'- When every line is `met` or `post-ship`, ask nothing'*) ;;
  *) fail "$vf: step 6 lost its no-question branch \`- When every line is \`met\` or \`post-ship\`, ask nothing\`" ;;
esac
case "$vs6" in
  *"- Otherwise ask one round over the \`unmet\` and \`operator\` lines. $(vptr walkthrough)") ;;
  *) fail "$vf: step 6 does not end with the round's bullet followed by \`$(vptr walkthrough)\`; the round's questions belong in skills/forge-verify/walkthrough.md" "got: ...${vs6: -200}" ;;
esac
vfix=$(trim "$(vraw_sec 'Inline fixes')")
case "$vfix" in
  *"$(vptr fix-reruns)") ;;
  *) fail "$vf: ## Inline fixes does not end with the pointer line \`$(vptr fix-reruns)\`; its tail from \`A walkthrough gap runs its rounds\` belongs in skills/forge-verify/fix-reruns.md" "got: ...${vfix: -200}" ;;
esac
for r in a b c e; do
  awk -v r="$r" '
    /^## / { t = $0; sub(/[[:space:]]+$/, "", t); s = (t == "## Inline fixes"); next }
    s && index($0, r ". ") == 1 { hit = 1 }
    END { exit !hit }
  ' "$vf" || fail "$vf: ## Inline fixes lost round $r., which stays in SKILL.md"
done
awk '
  /^## / { t = $0; sub(/[[:space:]]+$/, "", t); s = (t == "## Inline fixes"); next }
  s && index($0, "d. ") == 1 { hit = 1 }
  END { exit hit }
' "$vf" || fail "$vf: ## Inline fixes still has round d.; forge fixes --record left nothing to move back from F/review.json"
for r in f g; do
  awk -v r="$r" '
    /^## / { t = $0; sub(/[[:space:]]+$/, "", t); s = (t == "## Inline fixes"); next }
    s && index($0, r ". ") == 1 { hit = 1 }
    END { exit hit }
  ' "$vf" || fail "$vf: ## Inline fixes still has round $r., the removed fix-diff re-review"
done
vrawflat=$(vflat_of <"$vf")
for gone in 'Before the round only' 'exactly the options `Accept` and `Restart phase <N>`' 'exactly the options `Passed` and `Gap`' \
  'with no open gap left ends its rounds' 'Never more than 2 inline rounds' \
  'cross-repo rerun' '[agent][carried] <E/s<k>/ paths>'; do
  case "$vrawflat" in
    *"$gone"*) fail "$vf: still holds \`$gone\`; it belongs in skills/forge-verify/walkthrough.md or fix-reruns.md" ;;
  esac
done
vmoved resolver-loop '`verify <feature> sync forge-merger`' 'forge merge-check <record>' 'forge merge --continue <record>' \
  'F/merge/<repo>-V<k>.json' 'forge merge --abort' 'Exit 1: ask the operator with its message'
vmoved browser-pass 'forge-browser start' 'jev_task' 'browser_take_screenshot' 'critique.md' 'operator deferred' 'forge-browser start --headed'
vmoved walkthrough 'Before the round only' 'exactly the options `Accept` and `Restart phase <N>`' \
  'exactly the options `Passed` and `Gap`' '`Decision: <text>`' 'at most four questions'
vmoved fix-reruns 'with no open gap left ends its rounds' 'Never more than 2 inline rounds' \
  'cross-repo rerun' "rerun step 5's build check" '`[agent][carried] <E/s<k>/ paths>`'
grep -nE '^[0-9]+\. ' skills/forge-verify/walkthrough.md \
  && fail "skills/forge-verify/walkthrough.md: a line starts a numbered step at column 0; keep step 6's bullet indentation"
for file in resolver-loop browser-pass walkthrough fix-reruns; do
  grep -nE '^## ' "skills/forge-verify/$file.md" \
    && fail "skills/forge-verify/$file.md: holds a \`## \` heading, which would end the section that points at it"
done
vxflat=$(vtext | vflat_of)
for ref in 'the Resolver loop with `origin/main`' 'through Browser pass' 'as Browser pass step 3 does'; do
  case "$vxflat" in
    *"$ref"*) ;;
    *) fail "$vf: the cross-reference \`$ref\` no longer appears in forge-verify read through its pointer files" ;;
  esac
done
grep -qE '^3\. ' skills/forge-verify/browser-pass.md \
  || fail "skills/forge-verify/browser-pass.md: no step 3 for \`as Browser pass step 3 does\` to name"
lean_base=93780
lean_now=$(cat skills/forge-phase/SKILL.md "$vf" | wc -c)
[ $((lean_now * 10)) -le $((lean_base * 7)) ] \
  || fail "skills/forge-phase/SKILL.md + $vf: $lean_now bytes, want at most 70% of $lean_base ($((lean_base * 7 / 10))), their bytes at git merge-base main forge/audit-261016-lean-session (forge-phase 40042, forge-verify 53738)"
ok verify-pointers
fi

sentences() {
  tr '\n' ' ' | tr -s '[:space:]' ' ' | awk -v semi="${1:-0}" '{
    n = length($0); s = ""; code = 0
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1); s = s c
      if (c == "`") code = !code
      else if (!code && (c == "." || (semi && c == ";")) && (i == n || substr($0, i + 1, 1) == " ")) { print s; s = "" }
    }
    if (s != "") print s
  }'
}
spawn_re() { printf '[Ss]pawns? (in one message )?((one|the) )?`(%s)`' "$1"; }
if want phase-agent-wait; then
pf=skills/forge-phase/SKILL.md
fg_agents=(forge-planner)
bg_agents=(forge-implementer)
rules=$(awk '
  /^## / { r = ($0 ~ /^## Rules[[:space:]]*$/); next }
  r && /^- / { if (b != "") print b; b = $0; next }
  r { b = b " " $0 }
  END { if (b != "") print b }
' "$pf" | tr -s '[:space:]' ' ')
grep -qF 'Wait for agents and background commands by ending the turn' <<<"$rules" \
  && fail "$pf: Rules still hold the single wait rule \`Wait for agents and background commands by ending the turn\`; replace it with Rule 1 (listed agents with \`run_in_background: false\`) and Rule 2 (forge-implementer with \`run_in_background: true\`)"
rule1=$(grep -F '`run_in_background: false`' <<<"$rules" | grep -iE 'same turn' | grep -iE 'one message' | head -1 || true)
[ -n "$rule1" ] || fail "$pf: no Rules bullet spawns the listed agents with the Agent tool's \`run_in_background: false\`, the report returning in the same turn and a step's independent spawns in one message"
for a in "${fg_agents[@]}"; do
  grep -qF "\`$a\`" <<<"$rule1" || fail "$pf: the foreground wait rule does not name \`$a\`" "rule: ${rule1:0:300}"
done
rule2=$(grep -F '`run_in_background: true`' <<<"$rules" | grep -F '`forge-implementer`' | grep -iE 'end the turn' | head -1 || true)
[ -n "$rule2" ] || fail "$pf: no Rules bullet spawns \`forge-implementer\` with \`run_in_background: true\` and then ends the turn"
for w in ScheduleWakeup CronCreate sleep ReadNotifications pgrep; do
  grep -qF "$w" <<<"$rule2" || fail "$pf: the background wait rule does not forbid $w" "rule: ${rule2:0:300}"
done
grep -F '`run_in_background: false`' <<<"$rules" | grep -iE 'async' | grep -qiE 'end the turn' \
  || fail "$pf: Rules give no fallback for an Agent call with \`run_in_background: false\` that returns an async-launch result: end the turn and treat it as a background agent"

body=$(skill_text "$pf" | awk '/^## / { r = ($0 ~ /^## Rules[[:space:]]*$/) } !r')
fg_re=$(IFS='|'; echo "${fg_agents[*]}")
bg_re=$(IFS='|'; echo "${bg_agents[*]}")
fg_sites=$(sentences <<<"$body" | grep -E "$(spawn_re "$fg_re")" || true)
bg_sites=$(sentences <<<"$body" | grep -E "$(spawn_re "$bg_re")" || true)
[ -n "$fg_sites" ] || fail "$pf: no spawn of a listed agent found"
while IFS= read -r s; do
  grep -qF '`run_in_background: false`' <<<"$s" || fail "$pf: a listed agent's spawn does not pass \`run_in_background: false\`" "spawn: ${s:0:300}"
done <<<"$fg_sites"
for a in "${fg_agents[@]}"; do
  sentences <<<"$body" | grep -E '[Ss]pawns? ' | grep -F "\`$a\`" | grep -qF '`run_in_background: false`' \
    || fail "$pf: no spawn of \`$a\` passes \`run_in_background: false\`"
done
for a in "${bg_agents[@]}"; do
  grep -qF "\`$a\`" <<<"$bg_sites" || fail "$pf: step 4 spawns no \`$a\`"
done
while IFS= read -r s; do
  grep -qF '`run_in_background: true`' <<<"$s" || fail "$pf: a forge-implementer spawn does not pass \`run_in_background: true\`" "spawn: ${s:0:300}"
done <<<"$bg_sites"
keep=$(sentences <<<"$body" | grep -E "$(spawn_re 'forge-merger|forge-reviewer')|\`forge-(merger|reviewer)\` per" | grep -F 'run_in_background' || true)
[ -z "$keep" ] || fail "$pf: forge-merger and forge-reviewer call sites keep their wording, with no run_in_background" "got: ${keep:0:300}"

waits=$(skill_step <(skill_text "$pf") "" | sentences 1 | grep -iE 'end(s|ing)? the turn' | grep -iE 'planner' || true)
[ -z "$waits" ] || fail "$pf: a step still waits for a foreground agent by ending the turn; it continues in the same turn once the agent returns and ends the turn only for the implementer" "got: ${waits:0:300}"
pending_re='foreground[^.]*(pending|wake)|(pending|wake)[^.]*foreground'
skill_step <(skill_text "$pf") 2 | grep -qiE "$pending_re" \
  || fail "$pf: step 2 does not state that no foreground spawn is made while an implementer wake-up is pending"
ok phase-agent-wait
fi

if want verify-agent-wait; then
vf=skills/forge-verify/SKILL.md
fg_agents=(forge-fixer)
fg_re=$(IFS='|'; echo "${fg_agents[*]}")
pending_re='foreground[^.]*(pending|wake)|(pending|wake)[^.]*foreground'
vrules=$(awk '
  /^## / { r = ($0 ~ /^## Rules[[:space:]]*$/); next }
  r && /^- / { if (b != "") print b; b = $0; next }
  r { b = b " " $0 }
  END { if (b != "") print b }
' "$vf" | tr -s '[:space:]' ' ')
grep -qF 'Wait for spawned agents and background commands by ending the turn' <<<"$vrules" \
  && fail "$vf: Rules still hold the single wait rule \`Wait for spawned agents and background commands by ending the turn\`; replace it with Rule 1 (listed agents with \`run_in_background: false\`) and Rule 2 (forge-implementer with \`run_in_background: true\`)"
vrule1=$(grep -F '`run_in_background: false`' <<<"$vrules" | grep -iE 'same turn' | grep -iE 'one message' | head -1 || true)
[ -n "$vrule1" ] || fail "$vf: no Rules bullet spawns the listed agents with the Agent tool's \`run_in_background: false\`, the report returning in the same turn and a step's independent spawns in one message"
for a in "${fg_agents[@]}"; do
  grep -qF "\`$a\`" <<<"$vrule1" || fail "$vf: the foreground wait rule does not name \`$a\`" "rule: ${vrule1:0:300}"
done
grep -qF 'Bash command' <<<"$vrule1" \
  || fail "$vf: the foreground wait rule does not say a Bash command such an agent starts stops when its run ends" "rule: ${vrule1:0:300}"
vrule2=$(grep -F '`run_in_background: true`' <<<"$vrules" | grep -F '`forge-implementer`' | grep -iE 'end the turn' | head -1 || true)
[ -n "$vrule2" ] || fail "$vf: no Rules bullet spawns \`forge-implementer\` with \`run_in_background: true\` and then ends the turn"
for w in ScheduleWakeup CronCreate sleep ReadNotifications pgrep; do
  grep -qF "$w" <<<"$vrule2" || fail "$vf: the background wait rule does not forbid $w" "rule: ${vrule2:0:300}"
done
grep -qiE "$pending_re" <<<"$vrules" \
  || fail "$vf: Rules do not state that no foreground spawn is made while an implementer wake-up is pending in the same step"
grep -F '`run_in_background: false`' <<<"$vrules" | grep -iE 'async' | grep -qiE 'end the turn' \
  || fail "$vf: Rules give no fallback for an Agent call with \`run_in_background: false\` that returns an async-launch result: end the turn and treat it as a background agent"

vbody=$(vtext | awk '/^## / { r = ($0 ~ /^## Rules[[:space:]]*$/) } !r')
vfg_sites=$(sentences <<<"$vbody" | grep -E '[Ss]pawns? ' | grep -E "\`($fg_re)\`" || true)
[ -n "$vfg_sites" ] || fail "$vf: no spawn of a listed agent found in forge-verify read through its pointer files"
while IFS= read -r s; do
  grep -qF '`run_in_background: false`' <<<"$s" || fail "$vf: a listed agent's spawn does not pass \`run_in_background: false\`" "spawn: ${s:0:300}"
done <<<"$vfg_sites"
for a in forge-escalator forge-diagnoser; do
  grep -qF "\`$a\`" <<<"$vrule1" && fail "$vf: the foreground wait rule still names the removed \`$a\`"
done
for k in 4 6; do
  skill_step "$vf" "$k" | sentences | grep -iE 'fixer' | grep -qF '`run_in_background: false`' \
    || fail "$vf: step $k's fixers do not pass \`run_in_background: false\`"
done
vstep_b=$(awk '
  /^## / { t = $0; sub(/[[:space:]]+$/, "", t); s = (t == "## Inline fixes"); next }
  s && /^b\. / { b = 1 }
  s && /^c\. / { b = 0 }
  s && b { printf "%s ", $0 }
' "$vf" | tr -s '[:space:]' ' ')
vgroups=$(sentences 1 <<<"$vstep_b" | grep -E '[Ss]pawn' | grep -cF '`forge-fixer`' || true)
vfalse=$(grep -oF '`run_in_background: false`' <<<"$vstep_b" | wc -l)
[ "$vgroups" -ge 3 ] || fail "$vf: Inline fixes step b has $vgroups forge-fixer spawn groups, want its three"
[ "$vfalse" -ge "$vgroups" ] \
  || fail "$vf: Inline fixes step b passes \`run_in_background: false\` $vfalse times for its $vgroups forge-fixer spawn groups; each group passes it"
vkeep=$(sentences <<<"$vbody" | grep -E '[Ss]pawns? ' | grep -E '`forge-(merger|reviewer)`' | grep -F 'run_in_background' || true)
[ -z "$vkeep" ] || fail "$vf: forge-merger and forge-reviewer call sites keep their wording, with no run_in_background" "got: ${vkeep:0:300}"
for k in 3 6; do
  skill_step "$vf" "$k" | grep -qF '`run_in_background: true`' \
    || fail "$vf: step $k no longer runs its background command with the Bash tool's \`run_in_background: true\`"
done
ok verify-agent-wait
fi

if want fg-agents-exist; then
for f in skills/forge-phase/SKILL.md skills/forge-ship/SKILL.md skills/forge-verify/SKILL.md; do
  rule=$(awk '
    /^## / { r = ($0 ~ /^## Rules[[:space:]]*$/); next }
    r && /^- / { if (b != "") print b; b = $0; next }
    r { b = b " " $0 }
    END { if (b != "") print b }
  ' "$f" | tr -s ' \t' ' ' | grep -E '^- Spawn ' | grep -F '`run_in_background: false`' | head -1 || true)
  [ -n "$rule" ] || fail "$f: no Rules bullet spawns its foreground agents with the Agent tool's \`run_in_background: false\`"
  body=$(skill_text "$f" | awk '/^## / { r = ($0 ~ /^## Rules[[:space:]]*$/) } !r')
  for a in $(grep -oE '`forge-[a-z-]+`' <<<"$rule" | tr -d '`' | sort -u); do
    [ -f "agents/$a.md" ] || fail "$f: the foreground spawn rule names \`$a\`, which has no agents/$a.md"
    sentences <<<"$body" | grep -iE 'spawn' | grep -qF "\`$a\`" \
      || fail "$f: the foreground spawn rule names \`$a\`, which no step spawns"
  done
done
ok fg-agents-exist
fi

if want test-writer-gone; then
named=$(grep -rlF 'forge-test-writer' skills || true)
[ -z "$named" ] || fail "skills: these files still name \`forge-test-writer\`; the implementer writes the test" $named
for f in skills/forge-quick/SKILL.md skills/forge-debug/SKILL.md; do
  hit=$(grep -nF 'test-first' "$f" || true)
  [ -z "$hit" ] || fail "$f: still plans a \`test-first\` task" "$hit"
done
qstep7=$(skill_step skills/forge-quick/SKILL.md 7)
[ -n "$qstep7" ] || fail "skills/forge-quick/SKILL.md: no step 7 under ## Steps"
for w in '`forge-implementer`' '`S/plan.json`' '`S/spec.json`' '`S/tasks/<id>.json`'; do
  grep -qF "$w" <<<"$qstep7" || fail "skills/forge-quick/SKILL.md: step 7 does not spawn the implementer with $w"
done
grep -qF '`S/tests/<id>.json`' <<<"$qstep7" \
  && fail "skills/forge-quick/SKILL.md: step 7 still passes \`S/tests/<id>.json\` to the implementer"
dstep7=$(skill_step skills/forge-debug/SKILL.md 7)
[ -n "$dstep7" ] || fail "skills/forge-debug/SKILL.md: no step 7 under ## Steps"
dspawn=$(sentences <<<"$dstep7" | grep -E "$(spawn_re forge-implementer)" | head -1 || true)
[ -n "$dspawn" ] || fail "skills/forge-debug/SKILL.md: step 7 spawns no \`forge-implementer\` for the reproduction"
for w in 'reproduction only' '`S/tests/<id>.json`' '`S/plan.json`' '`S/session.json`'; do
  grep -qF "$w" <<<"$dspawn" || fail "skills/forge-debug/SKILL.md: step 7's \`forge-implementer\` spawn does not name $w" "spawn: ${dspawn:0:300}"
done
dbudget=$(awk '/^## / { b = ($0 ~ /^## Budgets[[:space:]]*$/); next } b' skills/forge-debug/SKILL.md | tr -s '[:space:]' ' ')
grep -qF 'Implementer: 2 attempts per task' <<<"$dbudget" \
  || fail "skills/forge-debug/SKILL.md: Budgets does not read 'Implementer: 2 attempts per task'"
grep -qiF 'test-writer' <<<"$dbudget" && fail "skills/forge-debug/SKILL.md: Budgets still names the test-writer"
ok test-writer-gone
fi

if want ship-docs-background; then
ship=skills/forge-ship/SKILL.md
ship_step1=$(skill_step "$ship" 1)
ship_step4=$(skill_step "$ship" 4)
ship_step5=$(skill_step "$ship" 5)
ship_step6=$(skill_step "$ship" 6)
ship_steps=$(skill_step "$ship" "")
[ -n "$ship_step4" ] || fail "$ship: no step 4 under ## Steps"
[ -n "$ship_step6" ] || fail "$ship: no step 6 under ## Steps"
case "$ship_step4" in
  '4. Docs. '*) ;;
  *) fail "$ship: step 4 is not Docs" ;;
esac
case "$ship_step5" in
  '5. Record. '*) ;;
  *) fail "$ship: step 5 is not Record" ;;
esac
case "$ship_step6" in
  '6. Concerns. '*) ;;
  *) fail "$ship: step 6 is not Concerns" ;;
esac
bg=$(sentences <<<"$ship_step4" | grep -F '`forge-doc-updater`' | grep -F '`run_in_background: true`' || true)
[ -n "$bg" ] || fail "$ship: step 4 does not spawn \`forge-doc-updater\` with the Agent tool's \`run_in_background: true\`"
for want in 'F/spec.json' 'F/requirements.json' 'F/split.json' 'F/docs-<repo>/docs.json' '.claude/rules/forge.md' 'PRODUCT.md' 'DESIGN.md'; do
  case "$ship_step4" in
    *"$want"*) ;;
    *) fail "$ship: step 4 lost the doc-updater spawn input $want" ;;
  esac
done
for want in 'F/spec.json' 'F/requirements.json' 'F/split.json'; do
  case "$bg" in
    *"$want"*) ;;
    *) fail "$ship: step 4's \`forge-doc-updater\` spawn does not pass $want" ;;
  esac
done
case "$ship_step4" in
  *'FEATURE.md'*) fail "$ship: step 4 still passes FEATURE.md to the doc-updater; it passes F/spec.json, F/requirements.json and F/split.json" ;;
esac
ship_step7=$(skill_step "$ship" 7)
case "$ship_step7" in
  '7. Merge. '*) ;;
  *) fail "$ship: step 7 is not Merge" ;;
esac
case "$ship_step7" in
  *'FEATURE.md'*) fail "$ship: step 7 still builds the PR body from the FEATURE.md summary" ;;
esac
body=$(sentences <<<"$ship_step7" | grep -iF 'body' | grep -F 'F/spec.json' | grep -F 'F/requirements.json' | grep -F 'F/verify.json' || true)
[ -n "$body" ] || fail "$ship: step 7's PR body is not built from F/spec.json, F/requirements.json and F/verify.json"
case "$(flat_of "$ship")" in
  *'never the Markdown'*) fail "$ship: still says never the Markdown; planning JSON is the only planning record" ;;
esac
case "$(flat_of "$ship")" in
  *'Edit planning JSON'*) ;;
  *) fail "$ship: lost 'Edit planning JSON'" ;;
esac
case "$ship_step4" in
  *'.forge/CONCERNS.md'*) ;;
  *) fail "$ship: step 4's doc-updater prompt does not forbid editing \`.forge/CONCERNS.md\`" ;;
esac
case "$ship_step4" in
  *'.forge/concerns.json'*) ;;
  *) fail "$ship: step 4's doc-updater prompt does not forbid editing \`.forge/concerns.json\`" ;;
esac
never=$(sentences <<<"$ship_step4" | grep -iE 'never|not' | grep -F '.forge/CONCERNS.md' | grep -F '.forge/concerns.json' || true)
[ -n "$never" ] || fail "$ship: step 4's doc-updater prompt does not say never to edit \`.forge/CONCERNS.md\` or \`.forge/concerns.json\`"
case "$(flat_of "$ship")" in
  *'`F/docs.json`'*) fail "$ship: the concurrent doc-updaters still share one \`F/docs.json\`; each \`W\` writes its own \`F/docs-<repo>/docs.json\`" ;;
esac
own=$(sentences <<<"$ship_step4" | grep -F 'own' | grep -F '`F/docs-<repo>/docs.json` as the output path' || true)
[ -n "$own" ] || fail "$ship: step 4 does not give each doc-updater its own \`F/docs-<repo>/docs.json\` as the output path"
case "$ship_step4" in
  *'Skip this step when `F/docs.json` exists'*) fail "$ship: step 4 still skips whole when \`F/docs.json\` exists; it skips only the spawn and still commits the listed paths left uncommitted" ;;
esac
case "$ship_step4" in
  *'Commit its doc changes in `W`.'*) fail "$ship: step 4 still commits the doc changes in \`W\` unscoped; the docs commit names the \`F/docs.json\` paths after step 6" ;;
esac
grep -qE '[Ss]tep 5|Record' <<<"$ship_step4" \
  || fail "$ship: step 4 does not go straight on to step 5 (Record) after the background spawn"
rule=$(awk '
  /^## / { in_rules = ($0 ~ /^## Rules[[:space:]]*$/); next }
  in_rules && /^- / { if (hit) exit; cur = "" }
  in_rules { cur = cur $0 " "; if (index($0, "forge-implementer")) hit = 1 }
  END { if (hit) print cur }
' "$ship" | tr -s '[:space:]' ' ')
case "$rule" in
  *'`forge-doc-updater`'*'run_in_background: true'*|*'run_in_background: true'*'`forge-doc-updater`'*) ;;
  *) fail "$ship: the Rules bullet on background spawns does not name \`forge-doc-updater\` with \`run_in_background: true\`" ;;
esac
grep -qE '[Ss]kip[^.]*`F/ship.json` exists' <<<"$ship_step5" \
  || fail "$ship: step 5 is not skipped when \`F/ship.json\` exists"
case "$ship_step6" in
  *'forge resolve <track>/<feature> <name>=<W> ...'*) ;;
  *) fail "$ship: step 6 no longer runs \`forge resolve <track>/<feature> <name>=<W> ...\`" ;;
esac
case "$ship_step6" in
  *'git -C W commit -m '*'-- .forge/concerns.json .forge/CONCERNS.md'*) ;;
  *) fail "$ship: step 6 does not commit only \`.forge/concerns.json\` and \`.forge/CONCERNS.md\` by path (\`git -C W commit -m ... -- .forge/concerns.json .forge/CONCERNS.md\`)" ;;
esac
docs_commit=$(sentences <<<"$ship_steps" | grep -F 'F/docs-<repo>/docs.json' | grep -F 'git -C W commit' | grep -F -- '-- <paths>' || true)
[ -n "$docs_commit" ] || fail "$ship: no step commits in \`W\` only the paths its own \`F/docs-<repo>/docs.json\` lists by path (\`git -C W commit ... -- <paths>\`)"
case "$ship_steps" in
  *'git -C W status --porcelain -- <paths>'*) ;;
  *) fail "$ship: no Merge gate checks the \`F/docs-<repo>/docs.json\` paths with \`git -C W status --porcelain -- <paths>\` before step 7" ;;
esac
gate=$(sentences <<<"$ship_steps" | grep -F 'F/docs-<repo>/docs.json' | grep -E '[Ss]tep 7|Merge' | grep -E 'until|only once|only when|only after' || true)
[ -n "$gate" ] || fail "$ship: no Merge gate says step 7 waits until every \`W\`'s \`F/docs-<repo>/docs.json\` exists and its listed doc changes are committed"
blocked=$(sentences <<<"$ship_steps" | grep -F 'doc-updater' | grep -F 'F/docs-<repo>/docs.json' | grep -F 'blocked' || true)
[ -n "$blocked" ] || fail "$ship: a doc-updater that fails or writes no \`F/docs-<repo>/docs.json\` does not end Ship blocked"
resume=$(sentences <<<"$ship_step1" | grep -F 'F/ship.json' | grep -F 'step 4' || true)
[ -n "$resume" ] || fail "$ship: step 1 resume with \`F/ship.json\` and no \`pr\` does not go to step 4"
case "$ship_step1" in
  *'go to step 6'*) fail "$ship: step 1 resume without \`pr\` still goes to step 6" ;;
esac
ok ship-docs-background
fi

if want phase-lean-steps; then
pf=skills/forge-phase/SKILL.md
names=$(awk '
  /^## / { in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { n = $0 + 0; s = substr($0, index($0, ". ") + 2); sub(/\..*/, "", s); print n " " s }
' "$pf")
for gone in Research Scout Verify Contracts Review Fix; do
  ! grep -qE "^[0-9]+ $gone\$" <<<"$names" || fail "$pf: ## Steps still has a $gone step" "steps: $(tr '\n' ',' <<<"$names")"
done
want_names=$'1 Plan\n2 Tasks\n3 Sync\n4 Result'
[ "$names" = "$want_names" ] || [ "$names" = "$want_names"$'\n5 Finish' ] \
  || fail "$pf: ## Steps are not Plan, Tasks, Sync, Result (and Finish) numbered from 1" "got: $(tr '\n' ',' <<<"$names")"
fin=$(awk '
  /^## / { in_fin = ($0 ~ /^## Finish[[:space:]]*$/); in_steps = ($0 ~ /^## Steps[[:space:]]*$/); next }
  in_steps && /^[0-9]+\. / { in_fin = ($0 ~ /^[0-9]+\. Finish\./) }
  in_fin { printf "%s ", $0 }
' "$pf")
case "$fin" in
  *'FORGE_ROOT=R forge finish N'*) ;;
  *) fail "$pf: Finish does not run \`FORGE_ROOT=R forge finish N\`" ;;
esac
case "$fin" in
  *--accept*) fail "$pf: Finish still passes \`--accept\` to forge finish" ;;
esac
for f in contracts fix-recording; do
  [ ! -e "skills/forge-phase/$f.md" ] || fail "skills/forge-phase/$f.md still exists; its step is removed"
done
for gone in forge-gap-finder forge-scout forge-verifier FORGE_PHASE_STAGE 'forge verify-tests' contracts.md fix-recording.md; do
  ! grep -qF -- "$gone" <<<"$phase_text" || fail "$pf: forge-phase still names \`$gone\`" "$(grep -nF -- "$gone" <<<"$phase_text" | head -3)"
done
plan=$(skill_step "$pf" 1)
case "$plan" in
  *research.json*|*scout.json*) fail "$pf: the Plan step still names research.json or scout.json" ;;
esac
case "$plan" in
  *'Spawn `forge-planner`'*'P/spec.json'*) ;;
  *) fail "$pf: the Plan step does not spawn \`forge-planner\` with \`P/spec.json\`" ;;
esac
ok phase-lean-steps
fi

if want phase-self-fix; then
phase_rules
stale=$(grep -F 'sibling phase' <<<"$rules" || true)
[ -n "$stale" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no rule for a test file a sibling phase or the base branch changed"
for want in 'test file' 'outside the plan' 'forge-planner' '`P/plan.json`' 'files are that test file' 'task budget' 'forge plan-done N' 'forge task-done'; do
  case "$stale" in
    *"$want"*) ;;
    *) fail "skills/forge-phase/SKILL.md: the stale-test rule does not say $want: $stale" ;;
  esac
done
lack=$(grep -F 'tool, login, environment variable or secret' <<<"$rules" || true)
[ -n "$lack" ] || fail "skills/forge-phase/SKILL.md: ## Rules has no rule for a tool, login, environment variable or secret the host lacks"
for want in 'FORGE_ROOT=R forge task-done N <id> --unmet "<probe and its output>"' 'go on'; do
  case "$lack" in
    *"$want"*) ;;
    *) fail "skills/forge-phase/SKILL.md: the missing-host rule does not say $want: $lack" ;;
  esac
done
ok phase-self-fix
fi

if want phase-no-ask; then
asks=$(grep -nF -e AskUserQuestion -e PushNotification -e 'forge notify' -e 'needs input' -e Escalate skills/forge-phase/*.md || true)
[ -z "$asks" ] || fail "skills/forge-phase: SKILL.md or a part file still asks the operator:" "$asks"
ok phase-no-ask
fi

if want ship-docs-validate; then
ship=skills/forge-ship/SKILL.md
ship_step4=$(skill_step "$ship" 4)
[ -n "$ship_step4" ] || fail "$ship: no step 4 under ## Steps"
docs_commit='git -C W commit -m "docs: update docs for <track>/<feature>" -- <paths>'
case "$ship_step4" in
  *"$docs_commit"*) ;;
  *) fail "$ship: step 4 lost the docs commit \`$docs_commit\`" ;;
esac
case "$ship_step4" in
  *'forge validate <paths>'*) ;;
  *) fail "$ship: step 4 does not run \`forge validate <paths>\` on the doc-updater's output" ;;
esac
case "$ship_step4" in
  *'forge validate <paths>'*"$docs_commit"*) ;;
  *) fail "$ship: step 4 does not run \`forge validate <paths>\` before the docs commit \`$docs_commit\`" ;;
esac
run=$(sentences <<<"$ship_step4" | grep -F 'forge validate <paths>' | grep -iF 'linked' | grep -E 'F/docs-<repo>/docs\.json|<paths>' | grep -E '(^|[ `])W([ `.,;]|$)|-C W' || true)
[ -n "$run" ] || fail "$ship: step 4 does not run \`forge validate <paths>\` in \`W\` on the linked-doc paths \`F/docs-<repo>/docs.json\` lists"
respawn=$(sentences <<<"$ship_step4" | grep -iE 'respawn|spawn[^.]*again' | grep -F 'doc-updater' | grep -F 'once' | grep -iF 'warning' || true)
[ -n "$respawn" ] || fail "$ship: step 4 does not respawn the \`forge-doc-updater\` once with the warning lines \`forge validate\` prints"
trim=$(sentences <<<"$ship_step4" | grep -iE 'trim|shorten' | grep -F '300' | grep -iF 'bullet' | grep -iE 'itself|yourself' || true)
[ -n "$trim" ] || fail "$ship: step 4 does not trim each remaining over-300-character bullet itself"
never=$(sentences <<<"$ship_step4" | grep -iF 'never' | grep -F 'blocked' | grep -iF 'doc-limit' || true)
[ -n "$never" ] || fail "$ship: step 4 does not say it never ends Ship blocked on a doc-limit line"
again=$(sentences <<<"$ship_step4" | grep -F 'blocked' | grep -viF 'never' || true)
[ -z "$again" ] || fail "$ship: step 4 still ends Ship blocked on a doc-limit line: $again"
ok ship-docs-validate
fi

if want cached-full-pass; then
for f in skills/forge-ship/SKILL.md skills/forge-quick/SKILL.md skills/forge-debug/SKILL.md; do
  hit=$(skill_text "$f" | sentences | grep -E '`forge: tests passed \([^`]*\), cached`' | sed 's/`[^`]*`//g' | grep -wE 'pass' || true)
  [ -n "$hit" ] || fail "$f: does not call a \`forge: tests passed (<tree>), cached\` line from the full \`forge test W\` a full-suite pass"
done
ok cached-full-pass
fi

if want ship-flake-no-operator-rerun; then
ship=skills/forge-ship/SKILL.md
flake=$(ship_sec "$ship" 'Flake rerun')
[ -n "$flake" ] || fail "$ship: no ## Flake rerun section"
for bad in '30 min' '30-minute' 'refus' 'operator' 'AskUserQuestion'; do
  case "$flake" in
    *"$bad"*) fail "$ship: Flake rerun still names $bad; forge test never refuses a failed tree and forge reruns a load-hit failure itself, never asking the operator" ;;
  esac
done
why=$(sentences <<<"$flake" | grep -F -- '--force' | grep -iE 'skips? the cache' || true)
[ -n "$why" ] || fail "$ship: Flake rerun does not say its \`forge test --force W\` rerun uses \`--force\` to skip the cache"
ok ship-flake-no-operator-rerun
fi

if want phase-discuss-state; then
pf=skills/forge-phase/SKILL.md
df=skills/forge-discuss/SKILL.md
pflat=$(tr -s '[:space:]' ' ' <"$pf")
dflat=$(tr -s '[:space:]' ' ' <"$df")
case "$pflat" in
  *'prints `forge: recorded <scope> <step>`'*) ;;
  *) fail "$pf: a phase step does not print \`forge: recorded <scope> <step>\`" ;;
esac
grep -qiE 'denied at write time' <<<"$pflat" || fail "$pf: does not say a write under W/.forge is denied at write time"
for ban in 'restore the worktree copy' 'restore the worktree' 'nothing to commit' 'forge: committed <sha>'; do
  case "$pflat" in *"$ban"*) fail "$pf: still names the W/.forge recovery or a phase step commit: $ban" ;; esac
done
grep -qF 'planning JSON goes under `P`/`F`, never `W/.forge/`' <<<"$pflat" || fail "$pf: lost the planning-JSON-under-P/F rule"
fdef=$(sentences <<<"$dflat" | grep -F '`F` below is' || true)
case "$fdef" in
  *'`forge paths <track>/<feature>`'*) ;;
  *) fail "$df: does not define F from \`forge paths <track>/<feature>\`" ;;
esac
for ban in '.forge/features' '.forge/phases' 'git show'; do
  case "$dflat" in *"$ban"*) fail "$df: still names $ban" ;; esac
done
grep -qE -- '--directory "<?F>?/mockups"' <<<"$dflat" || fail "$df: the mockup server does not serve F/mockups"
r1=$(awk '/^## Reopen/{r=1;next} /^## /{r=0} r' "$df" | tr -s '[:space:]' ' ')
spec=$(sentences <<<"$dflat" | grep -F 'P/spec.json' | grep -F '`forge paths <N>`' || true)
[ -n "$spec" ] || fail "$df: does not name each phase spec by P from \`forge paths <N>\`"
case "$r1" in
  *'`forge commit <track>/<feature> reopen`'*'recorded'*) ;;
  *) fail "$df: the reopen \`forge commit\` does not print recorded" ;;
esac
ren=$(sentences <<<"$dflat" | grep -F 'rename' | grep -E 'move `F`' | grep -F 'S' || true)
[ -n "$ren" ] || fail "$df: a rename does not move F inside S"
ok phase-discuss-state
fi

if want build-verify-state; then
vf=skills/forge-verify/SKILL.md
vflat=$(vtext | tr -s '[:space:]' ' ')
for ban in '.forge/phases' '.forge/features' 'W/.forge/features'; do
  case "$vflat" in *"$ban"*) fail "$vf: still names $ban" ;; esac
done
vs=$(sentences <<<"$vflat" | grep -F '`F/verify.json`' | grep -F 'lives in S' || true)
[ -n "$vs" ] || fail "$vf: does not say \`F/verify.json\` lives in S"
pd=$(sentences <<<"$vflat" | grep -F '`<P>`' | grep -F '`FORGE_ROOT=R forge paths <N>`' | grep -F 'directory' || true)
[ -n "$pd" ] || fail "$vf: phase N's directory is not \`<P>\` from \`FORGE_ROOT=R forge paths <N>\`"
case "$(vstep 7)" in
  *'`FORGE_ROOT=R forge commit <track>/<feature> verify`'*'forge: recorded <track>/<feature> verify'*) ;;
  *) fail "$vf: step 7's verify \`forge commit\` does not print \`forge: recorded <track>/<feature> verify\`" ;;
esac
case "$(vstep 7)" in *'docs(todo): defer <track>/<feature> verify findings'*) ;; *) fail "$vf: step 7 lost the todo deferral commit" ;; esac
fr=skills/forge-verify/fix-reruns.md
frf=$(tr -s '[:space:]' ' ' <"$fr")
case "$frf" in *'`<P>/plan.json`'*'`FORGE_ROOT=R forge paths <N>`'*) ;; *) fail "$fr: the plan is not \`<P>/plan.json\` with P from \`FORGE_ROOT=R forge paths <N>\`" ;; esac
ok build-verify-state
fi

if want ship-new-state; then
sf=skills/forge-ship/SKILL.md
sflat=$(tr -s '[:space:]' ' ' <"$sf")
for ban in '.forge/features' '.forge/phases' '.forge/archive' 'the ship commits included'; do
  case "$sflat" in *"$ban"*) fail "$sf: still names $ban" ;; esac
done
sa=$(sentences <<<"$sflat" | grep -F 'give every `F` path absolute' | grep -F 'any worktree' || true)
[ -n "$sa" ] || fail "$sf: 'give every \`F\` path absolute' is not justified by S working from any worktree"
ss=$(sentences <<<"$sflat" | grep -F '`forge commit <track>/<feature> ship`' | grep -F '`forge: recorded <track>/<feature> ship`' | grep -F 'no commit' || true)
[ -n "$ss" ] || fail "$sf: \`forge commit <track>/<feature> ship\` does not print \`forge: recorded <track>/<feature> ship\` with no commit"
s9=$(skill_step "$sf" 9 | tr -s '[:space:]' ' ')
sr=$(sentences <<<"$s9" | grep -F '`forge commit <track>/<feature> archive`' | grep -F 'only the track JSON' | grep -F 'push' || true)
[ -n "$sr" ] || fail "$sf: step 9's \`forge commit <track>/<feature> archive\` does not commit and push only the track JSON"
nf=skills/forge-new/SKILL.md
nflat=$(tr -s '[:space:]' ' ' <"$nf")
case "$nflat" in *'.forge/features'*) fail "$nf: still names .forge/features" ;; esac
n5=$(new_step 5)
in_order "$n5" '`forge paths <track>/<feature>`' '`F/requirements.json`' \
  || fail "$nf: Track open step 5 does not run \`forge paths <track>/<feature>\` before writing \`F/requirements.json\`"
na=$(awk '/^## Add feature/{r=1;next} /^## /{r=0} r' "$nf" | tr -s '[:space:]' ' ')
in_order "$na" '`forge paths <track>/<feature>`' '`F/requirements.json`' \
  || fail "$nf: Add feature does not run \`forge paths <track>/<feature>\` before writing \`F/requirements.json\`"
case "$nflat" in *'.forge/tracks/<track>.json'*) ;; *) fail "$nf: the track JSON left .forge/tracks/" ;; esac
ok ship-new-state
fi

if want skills-state-paths; then
hits=$(grep -rnF -e '.forge/phases' -e '.forge/features' -e '.forge/archive' skills/ || true)
[ -z "$hits" ] || fail "skills/ still names an in-repo record path, which lives under STATE now:" "$hits"
hits=$( { grep -rnF -e 'XDG_STATE_HOME' -e '$HOME/.local/state' skills/; grep -rnE '\.local/state/forge/' skills/ | grep -vE '\.local/state/forge/port\.(json|manifest)'; } || true)
[ -z "$hits" ] || fail "skills/ writes the XDG state expression; name the state dir \`STATE\` from \`forge paths\`:" "$hits"
mapfile -t named < <(grep -rlE '`STATE[`/]' skills/ | sort)
for f in skills/forge-debug/SKILL.md skills/forge-quick/SKILL.md; do
  printf '%s\n' "${named[@]}" | grep -qxF "$f" || fail "$f: does not name \`STATE\`"
done
for f in "${named[@]}"; do
  st=$(sentences <"$f" | grep -F '`STATE`' | grep -E '`[^`]*forge paths[^`]*`' | grep -F ' line' || true)
  [ -n "$st" ] || fail "$f: names \`STATE\` but does not take it from the \`STATE\` line of \`forge paths\`"
done
ok skills-state-paths
fi

if want discuss-owner; then
discuss=skills/forge-discuss/SKILL.md
step4=$(awk '
  /^## / { in_d = ($0 ~ /^## Discuss[[:space:]]*$/); next }
  in_d && /^[0-9]+\. / { in4 = ($0 ~ /^4\. /) }
  in_d && in4 { printf "%s ", $0 }
' "$discuss" | tr -s '[:space:]' ' ')
[ -n "$step4" ] || fail "$discuss: no step 4 under ## Discuss"
rule=${step4%%'`forge commit <track>/<feature> spec`'*}
[ "$rule" != "$step4" ] || fail "$discuss: step 4 does not run \`forge commit <track>/<feature> spec\`"
for w in '`owner`' '`agent`' '`operator`' '`post-ship`' 'golive' 'physical device' 'live account' '`command -v' 'gcloud auth print-access-token' '_API_KEY' 'compositor' 'downgrade' 'decision'; do
  case "$rule" in
    *"$w"*) ;;
    *) fail "$discuss: step 4 does not set owners by the rule naming $w before forge commit spec" ;;
  esac
done
case "$rule" in
  *'auto mode'*'no question'*'`Auto:`'*) ;;
  *) fail "$discuss: step 4 does not apply the owner rule in auto mode with no question, recording each owner as an \`Auto:\` decision" ;;
esac
new=skills/forge-new/SKILL.md
open=$(awk '
  /^## / { in_o = ($0 ~ /^## Track open[[:space:]]*$/); next }
  in_o { printf "%s ", $0 }
' "$new" | tr -s '[:space:]' ' ')
case "$open" in
  *'`owner`'*'`agent`'*) ;;
  *) fail "$new: Track open does not let a requirement name its \`owner\`, \`agent\` by default" ;;
esac
ok discuss-owner
fi

if want optional-plugins; then
for pair in 'forge-new/SKILL.md:Impeccable plugin is not' 'forge-discuss/SKILL.md:Impeccable plugin' 'forge-verify/browser-pass.md:Impeccable' 'forge-verify/browser-pass.md:mcp__jbc__' 'forge-discuss/SKILL.md:no `jbc`'; do
  grep -qF "${pair#*:}" "skills/${pair%%:*}" || fail "skills/${pair%%:*}: no skip when optional ${pair#*:} is absent"
done
ok optional-plugins
fi

if want no-removed-parts; then
bans=('forge jev' 'forge intake' '/forge-build' '/forge-audit' 'triaged' 'forge budget' 'build-gate' 'build.json' 'procedure.json' 'forge exclude' 'forge perf check' 'forge perf stop' 'perf-continuation' 'budget-guard' 'forge-phase/perf.md' 'release.json' 'contract pinning')
gargs=()
for ban in "${bans[@]}"; do gargs+=(-e "$ban"); done
hits=$(grep -rnF "${gargs[@]}" skills hooks/forge-session-title.sh || true)
[ -z "$hits" ] || fail "skills/ or hooks/forge-session-title.sh still names a removed part:" "$hits"
ok no-removed-parts
fi

if want port-judge; then
pf=skills/forge-port/SKILL.md
pstep() { awk -v n="$1" '/^## /{ on = 0 } /^[0-9]+\. /{ on = index($0, n ". ") == 1 } on' "$pf" | tr -s '[:space:]' ' '; }
pw() { local t=$1 w; shift; for w; do [[ $t == *"$w"* ]] || miss+=("$pf: $label does not hold: $w"); done; }
miss=()
label='step 2' pw "$(pstep 2)" 'stops the run' 'vcrpy' 'WireMock' 'faketime' 'seeded generator' 'held out' 'line coverage' 'mutation score'
label='step 3' pw "$(pstep 3)" '`J/holdout/<id>`' 'twice' '`noise <path> <count> <first id>`' '`normalize keys`' '`normalize space`' \
  'a `body` line stops the run' 'coverage.py' 'llvm-cov' 'mutmut' 'cargo-mutants' 'Below either threshold' '`holdout_mismatches=0`'
label='step 3' pw "$(pstep 3)" 'or drop the requests it names' 'the interpreter the old command runs'
label='## Rules' pw "$(tr -s '[:space:]' ' ' <"$pf")" 'never its path'
label='step 2' pw "$(pstep 2)" 'cutover gate'
label='step 3' pw "$(pstep 3)" '`J/cutover`'
label='step 9' pw "$(pstep 9)" '`forge shadow <slug> <feed>`' '`forge cutover <slug>`' 'side effects cut off'
label='step 6' pw "$(pstep 6)" '`S/fixtures/<id>`' '`J/report.jsonl`' 'holdout alone' '`J/holdout.jsonl`'
label='## Rules' pw "$(tr -s '[:space:]' ' ' <"$pf")" '`port-judge`' 'never a line of `J/holdout.jsonl`'
! grep -q 'J/ignore' "$pf" || miss+=("$pf: still names J/ignore; the judge's rules file is J/rules")
! grep -qi 'change one' "$pf" || miss+=("$pf: still proves the judge with one hand-made mutant")
[ "${#miss[@]}" -eq 0 ] || fail "${miss[@]}"
ok port-judge
fi

if want deepen; then
deepen_section() { awk '/^## /{ on = ($0 ~ /^## Deepen[[:space:]]*$/) } on' "$1"; }
prompt='I want a deeper version of this task, not a bigger one. Before rewriting it: (1) say what a top professional in this field would do here that I'"'"'m not asking for; (2) name the rawest material they would start from NEXT instead of what has already been digested for me; (3) name the specific methods and tools they would use; (4) say what, other than you or me, would show the result is right. Then rewrite my prompt to ask for exactly that.'
qf=skills/forge-quick/SKILL.md
nf=skills/forge-new/SKILL.md
[ "$(deepen_section "$qf")" = "$(deepen_section "$nf")" ] || fail "the ## Deepen sections of $qf and $nf differ"
for f in "$qf" "$nf"; do
  d=$(deepen_section "$f" | tr -d '>' | tr -s '[:space:]' ' ')
  for w in "$prompt" 'AskUserQuestion' 'Use the rewrite' 'Keep my prompt' 'No research, web or subagents'; do
    [[ $d == *"$w"* ]] || fail "$f: ## Deepen does not hold: $w"
  done
done
qs=$(skill_step "$qf" 1 | tr -s '[:space:]' ' ')
in_order "$qs" 'Run Deepen' '`S/spec.json`' || fail "$qf: step 1 does not run Deepen before writing \`S/spec.json\`"
[[ $qs == *'task text Deepen settled'* ]] || fail "$qf: step 1's spec does not hold the task text Deepen settled"
ql=$(skill_step "$qf" 14 | tr -s '[:space:]' ' ')
[[ $ql == *'task text as typed'* ]] || fail "$qf: step 14's quick-log no longer records the task as typed"
no=$(new_step 1)
[[ $no == *'Run Deepen'* ]] || fail "$nf: Track open step 1 does not run Deepen"
in_order "$no" 'Run Deepen' 'Name the track' || fail "$nf: Track open step 1 names the track before Deepen settles the text"
na=$(awk '/^## Add feature/{r=1;next} /^## /{r=0} r && /^1\. /{p=1} r && /^2\. /{p=0} p' "$nf" | tr -s '[:space:]' ' ')
[[ $na == *'Run Deepen'* ]] || fail "$nf: Add feature step 1 does not run Deepen"
ok deepen
fi

[ -z "$only" ] || fail "no case $only"
