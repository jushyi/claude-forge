#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
st=$XDG_STATE_HOME/forge/p fxpd=$fx/state/phases/02-intake-form

if want event; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
ev=$st/phases/02-intake-form/events.jsonl
cp $ev "$tmp/events"
h=$(git rev-parse HEAD) idx=$(git write-tree)
mkdir -p "$tmp/cwd"
(cd "$tmp/cwd" && FORGE_ROOT=$tmp/p "$forge" event 02 ui yes) || fail "event must succeed from another directory"
[ "$(wc -l <$ev)" = "$(($(wc -l <"$tmp/events") + 1))" ] || fail "event appends one line: $(cat $ev)"
[ "$(head -n -1 $ev)" = "$(cat "$tmp/events")" ] || fail "event keeps the existing events"
[ "$(tail -n1 $ev | jq -c '{step, message}')" = '{"step":"ui","message":"yes"}' ] || fail "event line: $(tail -n1 $ev)"
tail -n1 $ev | jq -e '.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null || fail "event time is UTC"
"$forge" validate $ev || fail "events.jsonl must validate after event"
"$forge" validate || fail "the project must validate after event"
[ "$(git rev-parse HEAD)" = "$h" ] || fail "event must not commit"
[ "$(git write-tree)" = "$idx" ] || fail "event must not stage"
cp $ev "$tmp/events"
[ "$(code "$forge" event 02 ui)" = 2 ] || fail "a missing argument must exit 2"
[ "$(code "$forge" event 02 ui yes extra)" = 2 ] || fail "an extra argument must exit 2"
[ "$(code "$forge" event 99 ui yes)" = 1 ] || fail "unknown phase must exit 1"
[ "$(cat $ev)" = "$(cat "$tmp/events")" ] || fail "a failed event appends nothing"
ok event
fi

stub_run_claude
stub_codex
review() { local s=0; rm -f "$CODEX_LOG"; HOME=$home "$forge" review "$@" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
logged() { jq -s "$@" "$CODEX_LOG"; }
payload() {
  jq -cn --argjson findings "$1" '{review: "Adversarial Review", target: {mode: "branch", label: "branch diff"}, threadId: "t1",
    codex: {status: 0, stderr: "", stdout: "", reasoning: null},
    result: {verdict: "needs-attention", summary: "Issues found", findings: $findings, next_steps: []},
    rawOutput: "{}", parseError: null, reasoningSummary: null}'
}
finding() {
  jq -cn --arg s "$1" --arg t "$2" --arg b "$3" --arg f "$4" --argjson l "$5" \
    '{severity: $s, title: $t, body: $b, file: $f, line_start: $l, line_end: $l, confidence: 0.8, recommendation: "Fix it."}'
}

fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
git worktree add -q -b forge/crm-intake .claude/worktrees/crm-intake
p=$PWD fw=$(cd .claude/worktrees/crm-intake && pwd -P)
mkdir -p "$fw/src"
echo 'export const form = () => 2;' >"$fw/src/form.ts" && git -C "$fw" add src && git -C "$fw" commit -q -m form
pd=$st/phases/02-intake-form fr=$st/features/crm-intake
data=$home/.claude/plugins/data/codex-openai-codex
installed "$plug"
found="[$(finding critical "SQL injection" "The id is interpolated." "$fw/src/intake.ts" 3),$(finding high "Lost write" "The save is not awaited." src/intake.ts 7),$(finding medium "Weak check" "The email is not trimmed." "$fw/src/form.ts" 12),$(finding low "Typo" "The label says Emial." src/form.ts 20)]"
tpl=$root/templates/checks tag='\[(<focus>|[a-z-]+) (<ID>|[A-Z]+-[0-9]{2})\]'
fbase="Report only defects that this diff introduces against main; ignore pre-existing code, style and anything outside the diff. The diff implements the spec in $fr/spec.json."
cp $fr/spec.json "$tmp/fspec"
tagged() {
  local what=$1 base=$2 text rest x
  shift 2
  [ "$(logged '.[1].argv | length')" = 6 ] || fail "$what: the criteria stay in the one focus argument: $(logged -c '.[1].argv')"
  text=$(logged -r '.[1].argv[5]')
  [[ $text == "$base"* ]] || fail "$what: the focus text starts with the untagged text: $text"
  rest=${text#"$base"}
  for x in "$@"; do
    [[ $rest == *"$(cat "$tpl/$x.md")"* ]] || fail "$what: the focus text holds $x.md in full: $rest"
    rest=${rest//"$(cat "$tpl/$x.md")"/}
  done
  [[ $rest == *name* && $rest == *email* ]] || fail "$what: the focus text holds the spec's pii_fields: $rest"
  [[ $rest =~ [Hh]igh ]] || fail "$what: the focus text makes a violation a high finding: $rest"
  [[ $rest =~ $tag ]] || fail "$what: a violation's summary starts [<focus> <ID>]: $rest"
  crest=$rest
}
untagged() {
  local text x
  text=$(logged -r '.[1].argv[5]')
  [[ $text == "$2"* ]] || fail "$1: the focus text starts with the untagged text: $text"
  for x in security pii scaling; do
    [[ $text != *"$(cat "$tpl/$x.md")"* ]] || fail "$1: the focus text holds no $x.md criteria: $text"
  done
  [[ $text != *"PII fields:"* && $text != *"[<focus> <ID>]"* ]] || fail "$1: the focus text holds no criteria fields or tag rule: $text"
}
if want review-criteria; then
jq '.focus += ["scaling"] | .targets = {"rps": 4321, "max_rows": 98765}' "$tmp/fspec" >$fr/spec.json
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a tagged feature review must exit 0: $(cat "$tmp/out" "$tmp/err")"
tagged "crm/intake (focus security, pii, scaling)" "$fbase" security pii scaling
[[ $crest =~ rps[^A-Za-z0-9]+4321 && $crest =~ max_rows[^A-Za-z0-9]+98765 ]] || fail "the feature focus text holds the spec's targets: $crest"
jq 'del(.focus, .pii_fields)' "$tmp/fspec" >$fr/spec.json
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "an untagged feature review must exit 0: $(cat "$tmp/out" "$tmp/err")"
untagged "an untagged feature spec" "$fbase"
cp "$tmp/fspec" $fr/spec.json
mkdir -p "$tmp/notpl"
[ "$(cd "$fw" && FORGE_TEMPLATES=$tmp/notpl FORGE_ROOT=$p review crm/intake)" = 1 ] || fail "a focus tag with no criteria file must fail review: $(cat "$tmp/out" "$tmp/err")"
grep -qF "$tmp/notpl/checks/security.md" "$tmp/err" || fail "a missing criteria file names its path: $(cat "$tmp/err")"
! grep -q adversarial-review "$CODEX_LOG" 2>/dev/null || fail "a missing criteria file runs no review: $(cat "$CODEX_LOG")"
ok review-criteria
fi

reset() { rm -f $fr/review.json; }
fbreview() { (cd "$fw" && FORGE_ROOT=$p review crm/intake "$@"); }
fallback() {
  [ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(jq -cSn --arg l "$(head -n1 "$tmp/out")" '{findings: [], pending: [$l]}')" ] || fail "$1: review.json must hold no findings and the pending codex line: $(cat $fr/review.json)"
  [ "$(grep -c '' "$tmp/out")" = 2 ] && head -n1 "$tmp/out" | grep -qE '^codex: .+' && tail -n1 "$tmp/out" | grep -q '^findings: 0 open ' \
    || fail "$1: stdout must be one 'codex: <cause>' line and the findings: line: $(cat "$tmp/out")"
  [ "$(cat "$st"/phases/*/events.jsonl)" = "$(cat "$tmp/allevents")" ] || fail "$1: a feature fallback logs no event"
  "$forge" validate $fr/review.json || fail "$1: review.json must validate"
}
if want review-fallback; then
cat "$st"/phases/*/events.jsonl >"$tmp/allevents"
for s in '{"codex":{"available":true},"auth":{"loggedIn":false}}' '{"codex":{"available":false},"auth":{"loggedIn":true}}'; do
  reset
  [ "$(CODEX_SETUP=$s fbreview)" = 3 ] || fail "setup $s must exit 3: $(cat "$tmp/out" "$tmp/err")"
  fallback "setup $s"
  ! grep -q adversarial-review "$CODEX_LOG" || fail "setup $s: a failed setup check runs no review"
done
reset
[ "$(CODEX_SETUP= CODEX_SETUP_EXIT=1 fbreview)" = 3 ] || fail "a failing setup call must exit 3"
fallback "setup exit 1"
! grep -q adversarial-review "$CODEX_LOG" || fail "a failing setup call runs no review"
reset
echo '{"version": 2, "plugins": {}}' >"$home/.claude/plugins/installed_plugins.json"
[ "$(fbreview)" = 3 ] || fail "no codex plugin entry must exit 3: $(cat "$tmp/out" "$tmp/err")"
fallback "no plugin entry"
[ ! -e "$CODEX_LOG" ] || fail "no plugin entry calls no companion"
reset
installed "$tmp/noplugin"
[ "$(fbreview)" = 3 ] || fail "a missing companion file must exit 3: $(cat "$tmp/out" "$tmp/err")"
fallback "no companion file"
installed "$plug"
reset
[ "$(CODEX_REVIEW=$(payload "$found") CODEX_REVIEW_EXIT=1 fbreview)" = 3 ] || fail "a failed Codex turn (exit 1 with JSON) must exit 3"
fallback "companion exit 1 with JSON"
reset
[ "$(CODEX_REVIEW= CODEX_REVIEW_EXIT=1 fbreview)" = 3 ] || fail "a companion crash must exit 3"
fallback "companion crash"
reset
[ "$(CODEX_REVIEW=$(payload "$found" | jq -c '.parseError = "Unexpected token < in JSON" | .rawOutput = "<oops>"') fbreview)" = 3 ] || fail "a parseError must exit 3"
fallback "parseError"
for filt in 'del(.result.findings)' 'del(.result)' '.result.findings[0].line_start = 0' '.result.findings[1].line_start = "7"' 'del(.result.findings[2].line_start)'; do
  reset
  [ "$(CODEX_REVIEW=$(payload "$found" | jq -c "$filt") fbreview)" = 3 ] || fail "output with $filt must exit 3: $(cat "$tmp/out" "$tmp/err")"
  fallback "$filt"
done
reset
[ "$(CODEX_REVIEW='not json' fbreview)" = 3 ] || fail "output that is not JSON must exit 3"
fallback "not JSON"
reset
[ "$(review)" = 2 ] || fail "review without arguments must exit 2"
[ "$(review nope)" = 2 ] || fail "review of no <track>/<feature> must exit 2"
ok review-fallback
fi

ff="[$(finding high "Race" "Two saves overlap." "$fw/src/form.ts" 5),$(finding critical "Leak" "The handle is never closed." src/form.ts 9)]"
fwant='{"findings": [
  {"file": "src/form.ts", "line": 5, "severity": "high", "summary": "Race: Two saves overlap.", "fixed": false, "source": "codex"},
  {"file": "src/form.ts", "line": 9, "severity": "high", "summary": "Leak: The handle is never closed.", "fixed": false, "source": "codex"}]}'
if want review-feature; then
cat "$st"/phases/*/events.jsonl >"$tmp/allevents"
[ "$(cd "$fw/src" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a feature review Codex ran must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(json <<<"$fwant")" ] || fail "feature review.json maps Codex's findings: $(cat $fr/review.json 2>&1)"
"$forge" validate $fr/review.json || fail "the feature review.json must validate"
[ "$(logged -c '.[0].argv')" = '["setup","--json"]' ] || fail "the feature review checks setup first: $(cat "$CODEX_LOG")"
[ "$(logged -c '.[1].argv[0:5]')" = '["adversarial-review","--base","main","--wait","--json"]' ] || fail "feature review args: $(logged -c '.[1].argv')"
jq -se --arg s "$fr/spec.json" '(.[1].argv | length) == 6 and (.[1].argv[5] | contains("the spec in \($s).") and (contains("/.forge/") | not))' "$CODEX_LOG" >/dev/null \
  || fail "the focus names the feature spec.json under S: $(logged -c '.[1].argv')"
[ "$(logged -r '.[1].cwd')" = "$fw" ] || fail "the feature review runs in the top of the start directory's worktree: $(logged -r '.[1].cwd')"
jq -se --arg d "$data" 'all(.data == $d)' "$CODEX_LOG" >/dev/null || fail "every feature companion call sets CLAUDE_PLUGIN_DATA"
[ "$(cat "$st"/phases/*/events.jsonl)" = "$(cat "$tmp/allevents")" ] || fail "a feature review logs no event"
[ "$(cd "$fw" && CODEX_SETUP='{"codex":{"available":true},"auth":{"loggedIn":false}}' FORGE_ROOT=$p review crm/intake)" = 3 ] \
  || fail "a feature review with a failed setup check must exit 3"
[ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(jq -cSn --arg l "$(head -n1 "$tmp/out")" '{findings: [], pending: [$l]}')" ] || fail "a feature fallback writes no findings and the pending codex line: $(cat $fr/review.json)"
[ "$(grep -c '' "$tmp/out")" = 2 ] && head -n1 "$tmp/out" | grep -qE '^codex: .+' || fail "a feature fallback prints one codex: <cause> line, then the findings: line: $(cat "$tmp/out")"
[ "$(cat "$st"/phases/*/events.jsonl)" = "$(cat "$tmp/allevents")" ] || fail "a feature fallback logs no event"
[ "$(cd "$fw" && FORGE_ROOT=$p review crm/routing)" = 1 ] || fail "a feature without spec.json must exit 1"
grep -qF "no $st/features/crm-routing/spec.json" "$tmp/err" && ! grep -q '/\.forge/' "$tmp/err" || fail "a missing feature spec.json is named by its S path: $(cat "$tmp/err")"
mkdir -p "$tmp/nogit"
[ "$(cd "$tmp/nogit" && FORGE_ROOT=$p review crm/intake)" = 1 ] || fail "a feature review outside a worktree must exit 1"
[ "$(cd "$fw" && FORGE_ROOT=$p review crm/intake extra)" = 2 ] || fail "a feature review with an extra argument must exit 2"
ok review-feature
fi

if want review-base; then
ftree=$(git -C "$fw" rev-parse 'HEAD^{tree}')
rev=$(git -C "$fw" rev-parse HEAD~1)
freview() { (cd "$fw" && FORGE_ROOT=$p review crm/intake "$@"); }
[ "$(CODEX_REVIEW=$(payload "$ff") freview --base "$rev")" = 0 ] || fail "a feature review with --base must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged -c '.[1].argv[0:5]')" = "$(jq -cn --arg r "$rev" '["adversarial-review","--base",$r,"--wait","--json"]')" ] \
  || fail "--base <rev> goes to adversarial-review --base: $(logged -c '.[1].argv')"
[ "$(logged '.[1].argv | length')" = 6 ] || fail "--base keeps the focus one argument: $(logged -c '.[1].argv')"
logged -e --arg b "${fbase/against main;/against $rev;}" '.[1].argv[5] | startswith($b)' >/dev/null || fail "the focus names the --base rev instead of main: $(logged -c '.[1].argv[5]')"
[ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(json <<<"$fwant")" ] || fail "a --base review maps Codex's findings: $(cat $fr/review.json)"
[ "$(jq -r '.tree // empty' $fr/review.json)" = "$ftree" ] || fail "the feature record holds top-level tree, the worktree's HEAD^{tree}: $(cat $fr/review.json)"
"$forge" validate $fr/review.json || fail "a feature review.json with tree must validate"
[ "$(CODEX_REVIEW=$(payload "$ff") freview)" = 0 ] || fail "a feature review without --base must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged -c '.[1].argv[0:3]')" = '["adversarial-review","--base","main"]' ] || fail "without --base the base stays main: $(logged -c '.[1].argv')"
[ "$(jq -r '.tree // empty' $fr/review.json)" = "$ftree" ] || fail "a feature review without --base holds tree: $(cat $fr/review.json)"
echo '{"findings": []}' >"$tmp/prior.json"
[ "$(CODEX_REVIEW=$(payload "$ff") freview --prior "$tmp/prior.json" --base "$rev")" = 0 ] || fail "--prior before --base must be accepted: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged -r '.[1].argv[2]')" = "$rev" ] || fail "--base after --prior goes to adversarial-review: $(logged -c '.[1].argv')"
logged -e --arg r "against $rev;" '.[1].argv[5] | contains($r)' >/dev/null || fail "--base after --prior is named in the focus: $(logged -c '.[1].argv[5]')"
[ "$(CODEX_REVIEW=$(payload "$ff") freview --base "$rev" --prior "$tmp/prior.json")" = 0 ] || fail "--base before --prior must be accepted: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged -r '.[1].argv[2]')" = "$rev" ] || fail "--base before --prior goes to adversarial-review: $(logged -c '.[1].argv')"
[ "$(CODEX_SETUP='{"codex":{"available":true},"auth":{"loggedIn":false}}' freview --base "$rev")" = 3 ] || fail "a --base review with a failed setup check must exit 3"
[ "$(jq -r '.tree // empty' $fr/review.json)" = "$ftree" ] && jq -e '.pending | length == 1' $fr/review.json >/dev/null \
  || fail "a feature fallback record holds tree and its pending line: $(cat $fr/review.json)"
"$forge" validate $fr/review.json || fail "a feature fallback record with tree must validate"
[ "$(CODEX_REVIEW=$(payload "$ff") freview --base no-such-rev)" = 1 ] || fail "an unknown --base rev must exit 1: $(cat "$tmp/out" "$tmp/err")"
grep -qF no-such-rev "$tmp/err" || fail "an unknown --base rev is named: $(cat "$tmp/err")"
[ ! -e "$CODEX_LOG" ] || fail "an unknown --base rev runs no companion: $(cat "$CODEX_LOG")"
for a in "02 --base main" "crm/intake --base" "crm/intake --prior" "crm/intake --base main --base main" \
  "crm/intake --prior $tmp/prior.json --prior $tmp/prior.json" "crm/intake --base main --prior" "crm/intake --bogus main" \
  "crm/intake main" "--base main crm/intake"; do
  read -ra args <<<"$a"
  [ "$(cd "$fw" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review "${args[@]}")" = 2 ] || fail "review $a must exit 2: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$CODEX_LOG" ] || fail "review $a runs no companion: $(cat "$CODEX_LOG")"
done
ok review-base
fi

if want review-out; then
ftree=$(git -C "$fw" rev-parse 'HEAD^{tree}')
rev=$(git -C "$fw" rev-parse HEAD~1)
oreview() { (cd "$fw" && FORGE_ROOT=$p review crm/intake "$@"); }
fline() { grep '^findings: ' "$tmp/out"; }
rm -f $fr/review.json
[ "$(CODEX_REVIEW=$(payload "$ff") oreview --out "$tmp/rec.json")" = 0 ] || fail "a feature review with --out must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS 'del(.tree)' "$tmp/rec.json" 2>&1)" = "$(json <<<"$fwant")" ] || fail "--out writes the record at its path: $(cat "$tmp/rec.json" 2>&1)"
[ "$(jq -r '.tree // empty' "$tmp/rec.json")" = "$ftree" ] || fail "the --out record holds the worktree's HEAD^{tree}: $(cat "$tmp/rec.json")"
check-jsonschema -q --schemafile "$root/schemas/review.schema.json" "$tmp/rec.json" || fail "the --out record is a valid review record"
[ ! -e $fr/review.json ] || fail "a review with --out writes no F/review.json: $(cat $fr/review.json)"
[ "$(fline)" = "findings: 2 open (2 high, 0 medium, 0 low) in $tmp/rec.json" ] || fail "the findings: line names the --out path: $(cat "$tmp/out")"
[ "$(logged -c '.[1].argv[0:5]')" = '["adversarial-review","--base","main","--wait","--json"]' ] || fail "--out leaves the companion args alone: $(logged -c '.[1].argv')"
[ "$(logged -r '.[1].cwd')" = "$fw" ] || fail "--out keeps the review in the start directory's worktree: $(logged -r '.[1].cwd')"
[ "$(CODEX_REVIEW=$(payload "$ff") oreview --out "$tmp/rec2.json" --base "$rev")" = 0 ] || fail "--out before --base must be accepted: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged -r '.[1].argv[2]')" = "$rev" ] && [ "$(jq -cS 'del(.tree)' "$tmp/rec2.json" 2>&1)" = "$(json <<<"$fwant")" ] \
  || fail "--out with --base reviews against the rev and writes at the --out path: $(logged -c '.[1].argv') $(cat "$tmp/rec2.json" 2>&1)"
echo '{"findings": []}' >"$tmp/prior.json"
[ "$(CODEX_REVIEW=$(payload "$ff") oreview --prior "$tmp/prior.json" --out "$tmp/rec3.json")" = 0 ] && [ -s "$tmp/rec3.json" ] \
  || fail "--out after --prior must be accepted and write the record: $(cat "$tmp/out" "$tmp/err")"
[ "$(cd "$fw/src" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review crm/intake --out rel-out.json)" = 0 ] || fail "a relative --out must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS 'del(.tree)' "$fw/src/rel-out.json" 2>&1)" = "$(json <<<"$fwant")" ] || fail "a relative --out resolves against the current directory: $(ls "$fw/src")"
[[ $(fline) == *" in "*rel-out.json ]] || fail "the findings: line names the relative --out record: $(cat "$tmp/out")"
rm -f "$fw/src/rel-out.json"
[ ! -e $fr/review.json ] || fail "a relative --out writes no F/review.json"
[ "$(CODEX_SETUP='{"codex":{"available":true},"auth":{"loggedIn":false}}' oreview --out "$tmp/fb.json")" = 3 ] || fail "a --out review with a failed setup check must exit 3"
jq -e '.findings == [] and (.pending | length == 1)' "$tmp/fb.json" >/dev/null 2>&1 || fail "a --out fallback writes its pending record at the --out path: $(cat "$tmp/fb.json" 2>&1)"
[[ $(fline) == *" in $tmp/fb.json" ]] || fail "a --out fallback's findings: line names the --out path: $(cat "$tmp/out")"
[ ! -e $fr/review.json ] || fail "a --out fallback writes no F/review.json"
[ "$(CODEX_REVIEW=$(payload "$ff") oreview --out "$tmp/nodir/rec.json")" != 0 ] || fail "--out under a missing directory must be refused: $(cat "$tmp/out")"
[ ! -e "$tmp/nodir" ] || fail "a refused --out creates no directory"
[ ! -e $fr/review.json ] || fail "a refused --out writes no F/review.json"
[ "$(CODEX_REVIEW=$(payload "$ff") oreview)" = 0 ] || fail "a feature review without --out must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(json <<<"$fwant")" ] || fail "without --out the record stays F/review.json: $(cat $fr/review.json 2>&1)"
[ "$(fline)" = "findings: 2 open (2 high, 0 medium, 0 low) in $fr/review.json" ] || fail "without --out the findings: line names F/review.json: $(cat "$tmp/out")"
for a in "02 --out $tmp/ph.json" "02 --prior $tmp/prior.json --out $tmp/ph.json" "crm/intake --out $tmp/a.json --out $tmp/b.json" "crm/intake --out" \
  "crm/intake --base main --out"; do
  read -ra args <<<"$a"
  [ "$(cd "$fw" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review "${args[@]}")" = 2 ] || fail "review $a must exit 2: $(cat "$tmp/out" "$tmp/err")"
  [ ! -e "$CODEX_LOG" ] || fail "review $a runs no companion: $(cat "$CODEX_LOG")"
done
[ "$(cd "$fw" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review crm/intake --out "")" = 2 ] || fail "an empty --out must exit 2: $(cat "$tmp/out" "$tmp/err")"
[ ! -e "$CODEX_LOG" ] || fail "an empty --out runs no companion"
[ ! -e "$tmp/ph.json" ] && [ ! -e "$tmp/a.json" ] && [ ! -e "$tmp/b.json" ] || fail "a refused --out writes no record"
"$forge" review --help >"$tmp/rhelp"
grep -qF -- '--out <path>' "$tmp/rhelp" && grep -qF 'review/reviewer-<repo>.json' "$tmp/rhelp" || fail "forge review --help documents --out <path> and the review/reviewer-<repo>.json fallback output"
git worktree add -q -b forge/crm-intake-o .claude/worktrees/crm-intake-o forge/crm-intake
ow=$(cd .claude/worktrees/crm-intake-o && pwd -P)
echo 'export const other = () => 3;' >"$ow/src/form.ts" && git -C "$ow" commit -q -am other
otree=$(git -C "$ow" rev-parse 'HEAD^{tree}')
[ "$otree" != "$ftree" ] || fail "setup: the two worktrees hold different trees"
cf="[$(finding high "Race" "Two saves overlap." src/form.ts 5),$(finding critical "Leak" "The handle is never closed." src/form.ts 9)]"
mkdir -p "$tmp/nbin"
cat >"$tmp/nbin/node" <<EOF
#!/usr/bin/env bash
if [ "\${2:-}" = adversarial-review ]; then
  touch "$tmp/bar.\$\$"
  for i in \$(seq 200); do [ "\$(find "$tmp" -maxdepth 1 -name 'bar.*' | wc -l)" -ge 2 ] && touch "$tmp/met.\$\$" && break; sleep 0.05; done
fi
exec "$(command -v node)" "\$@"
EOF
chmod +x "$tmp/nbin/node"
rm -f "$CODEX_LOG" $fr/review.json "$tmp"/bar.* "$tmp"/met.* "$tmp/rec-a.json" "$tmp/rec-b.json"
conc() { local s=0; (cd "$1" && CODEX_REVIEW=$(payload "$cf") HOME=$home FORGE_ROOT=$p PATH=$tmp/nbin:$PATH "$forge" review crm/intake --out "$2") >"$3.out" 2>"$3.err" || s=$?; echo $s >"$3.s"; }
conc "$fw" "$tmp/rec-a.json" "$tmp/ca" &
conc "$ow" "$tmp/rec-b.json" "$tmp/cb" &
wait
[ "$(cat "$tmp/ca.s")" = 0 ] && [ "$(cat "$tmp/cb.s")" = 0 ] || fail "two concurrent --out reviews must both exit 0: $(cat "$tmp/ca.out" "$tmp/ca.err" "$tmp/cb.out" "$tmp/cb.err")"
[ "$(find "$tmp" -maxdepth 1 -name 'met.*' | wc -l)" = 2 ] || fail "setup: the two reviews ran their companions at the same time"
[ "$(jq -cS 'del(.tree)' "$tmp/rec-a.json" 2>&1)" = "$(json <<<"$fwant")" ] && [ "$(jq -r .tree "$tmp/rec-a.json")" = "$ftree" ] \
  || fail "the first concurrent review leaves its complete record: $(cat "$tmp/rec-a.json" 2>&1)"
[ "$(jq -cS 'del(.tree)' "$tmp/rec-b.json" 2>&1)" = "$(json <<<"$fwant")" ] && [ "$(jq -r .tree "$tmp/rec-b.json")" = "$otree" ] \
  || fail "the second concurrent review leaves its complete record: $(cat "$tmp/rec-b.json" 2>&1)"
[ ! -e $fr/review.json ] || fail "two concurrent --out reviews leave no F/review.json: $(cat $fr/review.json)"
grep -qxF "findings: 2 open (2 high, 0 medium, 0 low) in $tmp/rec-a.json" "$tmp/ca.out" && grep -qxF "findings: 2 open (2 high, 0 medium, 0 low) in $tmp/rec-b.json" "$tmp/cb.out" \
  || fail "each concurrent review's findings: line names its own record: $(cat "$tmp/ca.out" "$tmp/cb.out")"
[ "$(jq -s '[.[] | select(.argv[0] == "adversarial-review") | .cwd] | sort' "$CODEX_LOG" | jq -c .)" = "$(jq -cn --arg a "$fw" --arg b "$ow" '[$a, $b] | sort')" ] \
  || fail "each concurrent review runs Codex in its own worktree: $(cat "$CODEX_LOG")"
git worktree remove --force "$ow" && git branch -q -D forge/crm-intake-o
ok review-out
fi

echo '{"findings": [{"file": "src/form.ts", "line": 5, "severity": "urgent", "summary": "x", "fixed": false}]}' >"$tmp/bad.json"
echo 'not json' >"$tmp/notjson.json"
if want review-prior; then
git worktree add -q -b forge/crm-intake-r .claude/worktrees/crm-intake-r forge/crm-intake
rw=$(cd .claude/worktrees/crm-intake-r && pwd -P)
for i in $(seq 30); do echo "export const v$i = $i;"; done >"$rw/src/form.ts" && git -C "$rw" add src && git -C "$rw" commit -q -m round1
ptree=$(git -C "$rw" rev-parse 'HEAD^{tree}')
sed -i '12s/.*/export const v12 = 1200;/' "$rw/src/form.ts" && git -C "$rw" commit -q -am fix
rtree=$(git -C "$rw" rev-parse 'HEAD^{tree}')
[ -n "$(git -C "$rw" diff -U0 "$ptree" 'HEAD^{tree}' -- src/form.ts)" ] || fail "setup: the fix changes src/form.ts"
rreview() { (cd "$rw" && FORGE_ROOT=$p review crm/intake "$@"); }
jq -n --arg t "$ptree" '{tree: $t, findings: [
  {file: "src/form.ts", line: 5, severity: "low", summary: "Race: Two saves overlap.", fixed: false, source: "codex"},
  {file: "src/form.ts", line: 5, severity: "medium", summary: "Race again: The retry overlaps.", fixed: false, source: "codex"},
  {file: "src/form.ts", line: 9, severity: "medium", summary: "Leak: The handle is never closed.", fixed: true, source: "codex"},
  {file: "src/form.ts", line: 12, severity: "low", summary: "Overflow: v12 is too small.", fixed: false, source: "codex"},
  {file: "src/form.ts", line: 20, severity: "low", summary: "Stale: v20 is cached.", fixed: false, source: "codex"},
  {file: "src/other.ts", line: 7, severity: "low", summary: "Other: Elsewhere.", fixed: false, source: "codex"}]}' >"$tmp/round1.json"
check-jsonschema -q --schemafile "$root/schemas/review.schema.json" "$tmp/round1.json" || fail "setup: the prior record is a valid review record"
rf="[$(finding high "Race" "Two saves overlap." "$rw/src/form.ts" 5),$(finding critical "Leak" "The handle is never closed." src/form.ts 9),$(finding high "Overflow" "v12 still overflows." src/form.ts 12),$(finding high "Stale" "New evidence: v20 is now read twice per save." src/form.ts 20),$(finding medium "Fresh" "A new defect." src/form.ts 25),$(finding high "Moved" "Same line, other file." src/form.ts 7),$(finding high "Crash" "The form is null on submit." src/form.ts 5),$(finding high "Race again" "The retry still overlaps." src/form.ts 5),$(finding low "Handle leak" "The handle stays open." src/form.ts 9)]"
row() { jq -cn --arg s "$1" --arg m "$2" --argjson l "$3" '{file: "src/form.ts", line: $l, severity: $s, summary: $m, fixed: false, source: "codex"}'; }
mapped=("$(row high "Race: Two saves overlap." 5)" "$(row high "Leak: The handle is never closed." 9)" "$(row high "Overflow: v12 still overflows." 12)" \
  "$(row high "Stale: New evidence: v20 is now read twice per save." 20)" "$(row medium "Fresh: A new defect." 25)" "$(row high "Moved: Same line, other file." 7)" \
  "$(row high "Crash: The form is null on submit." 5)" "$(row high "Race again: The retry still overlaps." 5)" "$(row low "Handle leak: The handle stays open." 9)")
kept=("$(row low "Race: Two saves overlap." 5)" "$(row medium "Leak: The handle is never closed." 9)" "${mapped[@]:2:5}" "$(row medium "Race again: The retry still overlaps." 5)" "$(row medium "Handle leak: The handle stays open." 9)")
[ "$(CODEX_REVIEW=$(payload "$rf") rreview --prior "$tmp/round1.json")" = 0 ] || fail "a feature review with --prior must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(logged '.[1].argv | length')" = 6 ] || fail "--prior keeps the focus one argument: $(logged -c '.[1].argv')"
focus=$(logged -r '.[1].argv[5]')
[[ $focus == "$fbase"* ]] || fail "the --prior focus starts with the base focus text: $focus"
for l in "src/form.ts:5 low: Race: Two saves overlap." "src/form.ts:5 medium: Race again: The retry overlaps." "src/form.ts:9 medium: Leak: The handle is never closed." \
  "src/form.ts:12 low: Overflow: v12 is too small." "src/form.ts:20 low: Stale: v20 is cached." "src/other.ts:7 low: Other: Elsewhere."; do
  grep -qxF -- "$l" <<<"$focus" || fail "the focus holds the prior finding line '$l': $focus"
done
[[ $focus == *"New evidence:"* ]] || fail "the focus holds the keep-severity instruction with its New evidence: exception: $focus"
[[ $focus == *"title word for word"* ]] || fail "the focus tells a finding that repeats a prior one to keep its title word for word: $focus"
[ "$(jq -c .findings $fr/review.json)" = "$(printf '%s\n' "${kept[@]}" | jq -cs .)" ] \
  || fail "unchanged file, line and title keep the first matching prior severity; another title takes the highest of its own and the prior severities at that line; a changed hunk, New evidence:, a new line and another file keep their own: $(jq -c .findings $fr/review.json)"
[ "$(jq -r '.tree // empty' $fr/review.json)" = "$rtree" ] || fail "a --prior record holds the reviewed tree: $(cat $fr/review.json)"
"$forge" validate $fr/review.json || fail "a --prior record must validate"
grep -q '^findings: 5 open (4 high, 0 medium, 1 low).*, 4 advisory' "$tmp/out" || fail "the findings: line counts the carried severities and leaves the Codex-only mediums out of the open counts as advisory: $(cat "$tmp/out")"
jq 'del(.tree)' "$tmp/round1.json" >"$tmp/notree.json"
[ "$(CODEX_REVIEW=$(payload "$rf") rreview --prior "$tmp/notree.json")" = 0 ] || fail "a --prior record without tree must exit 0: $(cat "$tmp/out" "$tmp/err")"
grep -qxF "src/form.ts:5 low: Race: Two saves overlap." <<<"$(logged -r '.[1].argv[5]')" || fail "a prior record without tree still puts its findings in the focus: $(logged -r '.[1].argv[5]')"
[ "$(jq -c .findings $fr/review.json)" = "$(printf '%s\n' "${mapped[@]}" | jq -cs .)" ] || fail "a prior record without tree changes no severity: $(jq -c .findings $fr/review.json)"
[ "$(CODEX_REVIEW=$(payload "$rf") rreview --prior "$tmp/round1.json" --base "$(git -C "$rw" rev-parse HEAD~1)")" = 0 ] || fail "--prior with --base must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -c .findings $fr/review.json)" = "$(printf '%s\n' "${kept[@]}" | jq -cs .)" ] || fail "--prior with --base carries the same severities: $(jq -c .findings $fr/review.json)"
cp $fr/review.json "$tmp/frkeep"
for r in "$tmp/bad.json" "$tmp/notjson.json" "$tmp/missing.json"; do
  [ "$(CODEX_REVIEW=$(payload "$rf") rreview --prior "$r")" = 1 ] || fail "--prior $r must exit 1: $(cat "$tmp/out" "$tmp/err")"
  grep -qF "$r" "$tmp/err" || fail "--prior $r names the record: $(cat "$tmp/err")"
  [ ! -e "$CODEX_LOG" ] || fail "--prior $r runs no companion: $(cat "$CODEX_LOG")"
  cmp -s $fr/review.json "$tmp/frkeep" || fail "--prior $r writes no record: $(cat $fr/review.json)"
done
sed -i '2a export const shift = 0;' "$rw/src/form.ts" && git -C "$rw" commit -q -am shift
[ "$(CODEX_REVIEW=$(payload "$rf") rreview --prior "$tmp/round1.json")" = 0 ] || fail "a --prior review after a line shift must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -c .findings $fr/review.json)" = "$(printf '%s\n' "${mapped[@]}" | jq -cs .)" ] || fail "a line an insertion above shifted keeps its own severity: $(jq -c .findings $fr/review.json)"
git worktree remove --force "$rw" && git branch -q -D forge/crm-intake-r
ok review-prior
fi

m=$(git rev-parse forge/crm-intake)
drow() { jq -cn --arg s "$1" --arg m "$2" --argjson l "$3" '{file: "src/form.ts", line: $l, severity: $s, summary: $m, fixed: false, source: "codex"}'; }
if want review-dismissed; then
git worktree add -q -b forge/crm-intake-d .claude/worktrees/crm-intake-d forge/crm-intake
dw=$(cd .claude/worktrees/crm-intake-d && pwd -P)
for i in $(seq 30); do echo "export const v$i = $i;"; done >"$dw/src/form.ts" && git -C "$dw" add src && git -C "$dw" commit -q -m round1
dtree=$(git -C "$dw" rev-parse 'HEAD^{tree}')
dreview() { (cd "$dw" && FORGE_ROOT=$p review crm/intake --base "$m" "$@"); }
jq -n --arg t "$dtree" '{tree: $t, findings: [
  {file: "src/form.ts", line: 5, severity: "low", summary: "Race: Two saves overlap.", fixed: false, source: "codex"},
  {file: "src/form.ts", line: 20, severity: "medium", summary: "Stale: v20 is cached.", fixed: false, source: "codex", dismissed: "v20 is read once per request."},
  {file: "src/form.ts", line: 20, severity: "low", summary: "Stale: v20 is cached twice.", fixed: false, source: "codex", dismissed: "Second reason."},
  {file: "src/form.ts", line: 28, severity: "low", summary: "Noise: v28 is unused.", fixed: false, source: "codex", dismissed: ""}]}' >"$tmp/dround1.json"
check-jsonschema -q --schemafile "$root/schemas/review.schema.json" "$tmp/dround1.json" || fail "setup: the dismissed prior record is a valid review record"
sed -i '2a export const shift1 = 0;' "$dw/src/form.ts" && sed -i '2a export const shift2 = 0;' "$dw/src/form.ts" && git -C "$dw" commit -q -am shift
[ "$(sed -n 22p "$dw/src/form.ts")" = "export const v20 = 20;" ] || fail "setup: the shift moves v20 to line 22"
df="[$(finding high "Stale" "v20 is still cached." src/form.ts 22),$(finding high "Stale" "New evidence: v20 is now read twice per save." src/form.ts 22),$(finding low "Noise" "v28 is still unused." src/form.ts 30),$(finding medium "Fresh" "A new defect." src/form.ts 25)]"
dopen=("$(drow high "Stale: New evidence: v20 is now read twice per save." 22)" "$(drow low "Noise: v28 is still unused." 30)" "$(drow medium "Fresh: A new defect." 25)")
dwant=("$(drow high "Stale: v20 is still cached." 22 | jq -c '. + {dismissed: "v20 is read once per request."}')" "${dopen[@]}")
[ "$(CODEX_REVIEW=$(payload "$df") dreview --prior "$tmp/dround1.json")" = 0 ] || fail "a --prior review over a dismissed finding must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
for l in "src/form.ts:5 low: Race: Two saves overlap." "src/form.ts:20 medium: Stale: v20 is cached. (dismissed: v20 is read once per request.)" \
  "src/form.ts:20 low: Stale: v20 is cached twice. (dismissed: Second reason.)" "src/form.ts:28 low: Noise: v28 is unused."; do
  grep -qxF -- "$l" <<<"$focus" || fail "the prior listing shows '$l', with ' (dismissed: <reason>)' only for a non-empty dismissed: $focus"
done
[ "$(jq -cS '.findings[]' $fr/review.json | jq -cs .)" = "$(printf '%s\n' "${dwant[@]}" | jq -cS . | jq -cs .)" ] \
  || fail "a repeat by file and title of a dismissed finding whose lines only shifted carries the first match's dismissed; New evidence:, an empty prior dismissed and a new finding stay open: $(jq -c .findings $fr/review.json)"
"$forge" validate $fr/review.json || fail "a record with a carried dismissal must validate"
grep -q '^findings: 3 open (2 high, 0 medium, 1 low).*, 1 advisory' "$tmp/out" || fail "the findings: line keeps a carried dismissal without settled: of a high finding under a security-focus spec open and counts the Codex medium advisory: $(cat "$tmp/out")"
[ "$(CODEX_REVIEW=$(payload "[$(finding high "Stale" "v25 is cached." src/form.ts 27)]") dreview --prior "$tmp/dround1.json")" = 0 ] || fail "a --prior review with a title repeat at another line must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS .findings $fr/review.json)" = "$(drow high "Stale: v25 is cached." 27 | jq -cS '[.]')" ] \
  || fail "a title repeat whose line is not the dismissed finding's shifted line gets no dismissed: $(jq -c .findings $fr/review.json)"
sed -i '22s/.*/export const v20 = 2000;/' "$dw/src/form.ts" && git -C "$dw" commit -q -am fix20
[ "$(CODEX_REVIEW=$(payload "$df") dreview --prior "$tmp/dround1.json")" = 0 ] || fail "a --prior review after an edit in the dismissed finding's hunk must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS '.findings[]' $fr/review.json | jq -cs .)" = "$(printf '%s\n' "$(drow high "Stale: v20 is still cached." 22)" "${dopen[@]}" | jq -cS . | jq -cs .)" ] \
  || fail "a repeat in a hunk changed since the dismissing round gets no dismissed: $(jq -c .findings $fr/review.json)"
grep -q '^findings: 3 open (2 high, 0 medium, 1 low).*, 1 advisory' "$tmp/out" || fail "the findings: line counts a repeat in a changed hunk as open and the Codex medium advisory: $(cat "$tmp/out")"
git worktree remove --force "$dw" && git branch -q -D forge/crm-intake-d
ok review-dismissed
fi

if want review-settled-ignored; then
git worktree add -q -b forge/crm-intake-s .claude/worktrees/crm-intake-s forge/crm-intake
sw=$(cd .claude/worktrees/crm-intake-s && pwd -P)
for i in $(seq 30); do echo "export const v$i = $i;"; done >"$sw/src/form.ts" && git -C "$sw" add src && git -C "$sw" commit -q -m round1
jq -n '{items: [
  {subject: {finding: "src/form.ts: Stale"}, ruling: "v20 caching is intended.", by: "operator", date: "2026-10-14"},
  {subject: {requirement: "INT-02"}, ruling: "INT-02 is out of scope here.", by: "operator", phase: "02", date: "2026-10-14"}]}' >$fr/settled.json
sf="[$(finding high "Stale" "v20 is still cached." src/form.ts 20),$(finding high "Scope" "INT-02 has no API route." src/form.ts 25)]"
[ "$(cd "$sw" && CODEX_REVIEW=$(payload "$sf") FORGE_ROOT=$p review crm/intake --base "$m")" = 0 ] || fail "a review with a settled.json must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
[[ $focus != *"settled by"* && $focus != *"Decisions already settled"* && $focus != *"v20 caching is intended."* && $focus != *"INT-02 is out of scope here."* ]] \
  || fail "the focus lists no settled item from F/settled.json: $focus"
jq -e '.findings | length == 2 and all(.[]; has("dismissed") | not)' $fr/review.json >/dev/null \
  || fail "a codex finding matching an F/settled.json ruling by file and title or by requirement keeps no dismissed: $(jq -c .findings $fr/review.json)"
grep -q '^findings: 2 open (2 high, 0 medium, 0 low)' "$tmp/out" || fail "the findings: line counts both findings open: $(cat "$tmp/out")"
"$forge" validate $fr/review.json || fail "the record must validate"
rm $fr/settled.json
git worktree remove --force "$sw" && git branch -q -D forge/crm-intake-s
ok review-settled-ignored
fi

if want review-findings; then
git worktree add -q -b forge/crm-intake-g .claude/worktrees/crm-intake-g forge/crm-intake
gw=$(cd .claude/worktrees/crm-intake-g && pwd -P)
gm=$(git -C "$gw" rev-parse HEAD)
for i in $(seq 30); do echo "export const v$i = $i;"; done >"$gw/src/form.ts" && git -C "$gw" add src && git -C "$gw" commit -q -m round1
gtree=$(git -C "$gw" rev-parse 'HEAD^{tree}')
jq -n --arg t "$gtree" '{tree: $t, findings: [
  {file: "src/form.ts", line: 5, severity: "high", summary: "[security] Token: v5 leaks.", fixed: false, source: "codex", dismissed: "v5 is public."},
  {file: "src/form.ts", line: 8, severity: "high", summary: "Race: v8 overlaps.", fixed: false, source: "codex", dismissed: "v8 is serialized."}]}' >"$tmp/ground1.json"
check-jsonschema -q --schemafile "$root/schemas/review.schema.json" "$tmp/ground1.json" || fail "setup: the dismissed prior record is a valid review record"
greview() { (cd "$gw" && FORGE_ROOT=$p review crm/intake --base "$gm" --prior "$tmp/ground1.json"); }
fline() { grep '^findings: ' "$tmp/out"; }
gf="[$(finding critical "[security] Token" "v5 still leaks." src/form.ts 5),$(finding high "Race" "v8 still overlaps." src/form.ts 8),$(finding medium "Weak" "v11 is loose." src/form.ts 11),$(finding medium "Loose" "v12 is loose." src/form.ts 12),$(finding low "Typo" "v14 is misspelled." src/form.ts 14),$(finding critical "Leak" "v16 is never closed." src/form.ts 16)]"
jq 'del(.focus, .pii_fields)' "$tmp/fspec" >$fr/spec.json
[ "$(CODEX_REVIEW=$(payload "$gf") greview)" = 0 ] || fail "a review without spec focus must exit 0: $(cat "$tmp/out" "$tmp/err")"
jq -e '[.findings[] | select((.dismissed // "") != "") | .line] == [5, 8]' $fr/review.json >/dev/null || fail "setup: both prior dismissals are carried: $(jq -c .findings $fr/review.json)"
l=$(fline)
[[ $l == "findings: 3 open (2 high, 0 medium, 1 low)"* && $l == *", 2 advisory"* && $l == *" in $fr/review.json"* ]] \
  || fail "without spec focus a dismissed high [security] title stays open, a dismissed plain high closes and the two Codex-only mediums are advisory: $l"
[ "$(CODEX_REVIEW=$(payload "[$(finding high "Race" "v8 still overlaps." src/form.ts 8),$(finding low "Typo" "v14 is misspelled." src/form.ts 14)]") greview)" = 0 ] \
  || fail "a review without mediums must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(fline)" = "findings: 1 open (0 high, 0 medium, 1 low) in $fr/review.json" ] || fail "with no Codex-only medium the findings: line has no advisory suffix: $(fline)"
cp "$tmp/fspec" $fr/spec.json
[ "$(CODEX_REVIEW=$(payload "$gf") greview)" = 0 ] || fail "a review under a security-focus spec must exit 0: $(cat "$tmp/out" "$tmp/err")"
l=$(fline)
[[ $l == "findings: 4 open (3 high, 0 medium, 1 low)"* && $l == *", 2 advisory"* ]] \
  || fail "under a security-focus spec a high finding dismissed without settled: stays open: $l"
jq '(.findings[] | select(.line == 5) | .dismissed) = "settled: v5 is a public token."' "$tmp/ground1.json" >"$tmp/gsettled" && mv "$tmp/gsettled" "$tmp/ground1.json"
[ "$(CODEX_REVIEW=$(payload "$gf") greview)" = 0 ] || fail "a review with a settled: dismissal of a security finding must exit 0: $(cat "$tmp/out" "$tmp/err")"
jq -e '.findings[] | select(.line == 5) | .dismissed == "settled: v5 is a public token."' $fr/review.json >/dev/null || fail "setup: the prior settled: dismissal of the [security] finding is carried: $(jq -c .findings $fr/review.json)"
l=$(fline)
[[ $l == "findings: 3 open (2 high, 0 medium, 1 low)"* && $l == *", 2 advisory"* ]] \
  || fail "a high security-class finding dismissed settled: is not open while the plain dismissal under security focus stays open: $l"
"$forge" review --help >"$tmp/rhelp"
grep -q advisory "$tmp/rhelp" && grep -q deferred "$tmp/rhelp" || fail "forge review --help states the open-finding rule with deferred owners and advisory Codex mediums"
git worktree remove --force "$gw" && git branch -q -D forge/crm-intake-g
ok review-findings
fi

if want review-prompt; then
cp $fr/split.json "$tmp/split" && cp .forge/todo.md "$tmp/todo"
jq '.phases += [{slug: "intake-export", number: "05", goal: "Leads export as JSON", spec: ["Files: src/export.ts"], requirements: [], depends: []},
    {slug: "intake-mail", number: "06", goal: "Mail confirms the lead", spec: ["Files: src/mail.ts"], requirements: [], depends: []}]' "$tmp/split" >$fr/split.json
mkdir -p $st/phases/05-intake-export && echo '{"status": "done", "summary": "Leads export"}' >$st/phases/05-intake-export/result.json
dec2='Emails compare "case-insensitively"; $HOME stays literal.'
jq --arg d "$dec2" '.decisions += [$d]' "$tmp/fspec" >$fr/spec.json
decided() {
  local what=$1 text=$2 h x
  h=$(grep -niE 'operator decision' <<<"$text" | head -n1 | cut -d: -f1)
  [ -n "$h" ] || fail "$what: the focus has an operator-decisions heading: $text"
  [[ $(sed -n "${h}p" <<<"$text") =~ [Nn]ot\ (a\ )?defects? ]] || fail "$what: the decisions heading says they are not defects: $(sed -n "${h}p" <<<"$text")"
  for x in "Leads live in one table." "$dec2"; do
    tail -n +"$((h + 1))" <<<"$text" | grep -qxE -- "(- )?$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$x")" || fail "$what: the decision '$x' is listed verbatim on its own line under the heading: $text"
  done
}
tagreq() {
  [[ $2 == *"[security]"* && $2 == *"[pii]"* && $2 == *"[auth]"* ]] || fail "$1: the focus asks for the [security], [pii] or [auth] title tag: $2"
  [[ $2 =~ authentication && $2 =~ authorization && $2 =~ secret && $2 =~ injection && $2 =~ personal ]] || fail "$1: the tag request names authentication, authorization, secret, injection and personal-data defects: $2"
}
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a feature review with later phases must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
[[ $focus != *"Later phases of this feature"* && $focus != *"03-intake-api"* && $focus != *"06-intake-mail"* ]] || fail "a feature review lists no later phases: $focus"
decided "a feature review" "$focus"
tagreq "a feature review" "$focus"
[[ $focus != *"(deferred to"* ]] || fail "a feature review without deferrals lists none: $focus"
jq 'del(.decisions)' "$tmp/fspec" >$fr/spec.json
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a feature review without decisions must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
! grep -qiE 'operator decision' <<<"$focus" && [[ $focus != *"Leads live in one table."* ]] || fail "a feature review under a spec without decisions has no decisions block: $focus"
tagreq "a feature review without a decisions key" "$focus"
jq '.decisions = []' "$tmp/fspec" >$fr/spec.json
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a feature review with empty decisions must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
! grep -qiE 'operator decision' <<<"$focus" || fail "a feature review under empty decisions has no decisions block: $focus"
tagreq "a feature review without decisions" "$focus"
cp "$tmp/fspec" $fr/spec.json
dfrow() { jq -cn --arg l "$1" --arg m "$2" --arg o "$3" --arg r "$4" '{file: "src/form.ts", line: ($l | tonumber), severity: "high", summary: $m, fixed: false, source: "codex", deferred: {owner: $o, reason: $r}}'; }
printf '%s\n' "$(dfrow 12 "Unclamped: The count is not clamped." "phase 05" "Phase 05 clamps the count.")" \
  "$(dfrow 14 "Overdue: The retry never ends." "phase 06" "Phase 06 bounds the retry.")" \
  "$(dfrow 16 "Noted: The label is long." todo "Cosmetic.")" \
  "$(dfrow 18 "Again: The cache is stale." "phase 05" "Phase 05 refreshes the cache.")" | jq -s '{findings: .}' >"$tmp/deferrals.json"
check-jsonschema -q --schemafile "$root/schemas/review.schema.json" "$tmp/deferrals.json" || fail "setup: the deferring record is a valid review record"
echo "- src/form.ts:16 Noted: shorten the label" >>.forge/todo.md
jq -n '{findings: [{file: "src/form.ts", line: 18, severity: "high", summary: "Again: The cache is still stale.", fixed: false, source: "codex"}]}' >"$tmp/frfinal.json"
cp "$tmp/deferrals.json" $pd/review.json && cp "$tmp/frfinal.json" $fr/review.json && rm -rf $fr/review
[ "$(cd "$fw" && CODEX_REVIEW=$(payload '[]') FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "a feature review with deferred phase findings must exit 0: $(cat "$tmp/out" "$tmp/err")"
focus=$(logged -r '.[1].argv[5]')
[[ $focus != *"(deferred to"* && $focus != *"to recheck"* && $focus != *Unclamped* && $focus != *Overdue* && $focus != *Noted* && $focus != *Again* ]] || fail "a feature review with deferred phase findings gets no recheck focus line: $focus"
cp "$tmp/split" $fr/split.json && cp "$tmp/todo" .forge/todo.md
rm -rf $st/phases/05-intake-export $fr/review.json && cp "$fxpd/review.json" $pd/review.json
ok review-prompt
fi

if want help-state; then
for c in review ui event; do
  "$forge" $c --help >"$tmp/help-$c"
  ! grep -nE '\.forge/(phases|features|archive)' "$tmp/help-$c" || fail "forge $c --help names no record under .forge"
  grep -qE '(^|[^[:alnum:]./])(S|STATE)/(features|phases)/' "$tmp/help-$c" || fail "forge $c --help names its records under S: $(cat "$tmp/help-$c")"
done
ok help-state
fi

if want ui; then
fresh
[ "$(code "$forge" ui crm/intake)" = 0 ] || fail "a feature with design.json is UI: $(cat "$tmp/out")"
[ "$(code "$forge" ui crm/routing)" = 1 ] || fail "a feature without design.json is not UI: $(cat "$tmp/out")"
rm $st/features/crm-intake/design.json
[ "$(code "$forge" ui crm/intake)" = 1 ] || fail "a feature whose design.json is gone is not UI: $(cat "$tmp/out")"
[ "$(code "$forge" ui crm/nope)" = 2 ] || fail "an unknown feature is an error: $(cat "$tmp/out")"
[ "$(code "$forge" ui x)" = 2 ] || fail "a bad argument is a usage error"
ok ui
fi

if want phase-forms; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
git worktree add -q -b forge/crm-intake .claude/worktrees/crm-intake
p=$PWD fw=$(cd .claude/worktrees/crm-intake && pwd -P) fr=$st/features/crm-intake
mkdir -p "$fw/src" && echo 'export const form = () => 2;' >"$fw/src/form.ts" && git -C "$fw" add src && git -C "$fw" commit -q -m form
installed "$plug"
cp -r $st/phases/03-intake-api $st/phases/05-intake-more
cat "$st"/phases/*/events.jsonl >"$tmp/allevents"
for c in fixes review ui; do
  for n in 02 05; do
    [ "$(code "$forge" $c $n)" = 2 ] || fail "forge $c $n must exit 2: $(cat "$tmp/out")"
    cmp -s "$root/bin/forge.d/help/forge.txt" "$tmp/out" || fail "forge $c $n must print only the usage: $(cat "$tmp/out")"
  done
done
[ "$(code "$forge" review 05 --base main)" = 2 ] && cmp -s "$root/bin/forge.d/help/forge.txt" "$tmp/out" || fail "forge review 05 --base must be a usage error: $(cat "$tmp/out")"
[ "$(code "$forge" review 05 --prior x.json)" = 2 ] && cmp -s "$root/bin/forge.d/help/forge.txt" "$tmp/out" || fail "forge review 05 --prior must be a usage error: $(cat "$tmp/out")"
cmp -s "$fxpd/review.json" $st/phases/02-intake-form/review.json && [ ! -e $st/phases/05-intake-more/review.json ] || fail "a phase review form writes no review.json"
[ "$(cat "$st"/phases/*/events.jsonl)" = "$(cat "$tmp/allevents")" ] || fail "a phase form logs no event"
[ "$(code "$forge" ui crm/intake)" = 0 ] || fail "forge ui <track>/<feature> still answers UI: $(cat "$tmp/out")"
[ "$(code "$forge" ui crm/routing)" = 1 ] || fail "forge ui <track>/<feature> still answers not UI: $(cat "$tmp/out")"
[ "$(cd "$fw/src" && CODEX_REVIEW=$(payload "$ff") FORGE_ROOT=$p review crm/intake)" = 0 ] || fail "forge review <track>/<feature> must exit 0: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -cS 'del(.tree)' $fr/review.json)" = "$(json <<<"$fwant")" ] || fail "forge review <track>/<feature> writes its review.json: $(cat $fr/review.json 2>&1)"
[ "$(logged -c '.[1].argv[0:5]')" = '["adversarial-review","--base","main","--wait","--json"]' ] || fail "forge review <track>/<feature> args: $(logged -c '.[1].argv')"
jq -nc --arg rv "$fr/review.json" '{repo: null, file: "src/form.ts", findings: [
  {index: 0, severity: "high", line: 5, summary: "Race: Two saves overlap.", review: $rv, security: true},
  {index: 1, severity: "high", line: 9, summary: "Leak: The handle is never closed.", review: $rv, security: true}]}' >"$tmp/want"
[ "$(code "$forge" fixes crm/intake)" = 0 ] || fail "forge fixes <track>/<feature> must exit 0: $(cat "$tmp/out")"
diff -u "$tmp/want" "$tmp/out" || fail "forge fixes <track>/<feature> prints its open findings"
[ "$(code "$forge" fixes crm/intake --record $fr/review.json)" = 0 ] || fail "forge fixes <track>/<feature> --record must exit 0: $(cat "$tmp/out")"
diff -u "$tmp/want" "$tmp/out" || fail "forge fixes <track>/<feature> --record prints that record's open findings"
ok phase-forms
fi
finish
