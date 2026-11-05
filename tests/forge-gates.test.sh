#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"
suite=forge-gates
. "$(dirname "$0")/forge-gates-common.sh"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$PWD | $*" >>"$CLAUDE_LOG"
case $1 in
  --bg) echo "session started" ;;
  agents) echo '[]' ;;
esac
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SYSTEMD_LOG"
EOF
cat >"$tmp/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$SYSTEMD_LOG"
for a; do shift; [ "$a" != -- ] || exec "$@"; done
[ -z "${SYSTEMD_RUN_FAIL:-}" ] || { echo "$SYSTEMD_RUN_FAIL" >&2; exit 1; }
EOF
chmod +x "$tmp/bin/claude" "$tmp/bin/systemctl" "$tmp/bin/systemd-run"
export PATH=$tmp/bin:$PATH CLAUDE_LOG=$tmp/claude.log SYSTEMD_LOG=$tmp/systemd.log
claude_home
p=$tmp/p
S=$XDG_STATE_HOME/forge/p
base() {
  rm -rf "$p"
  project "$p"
  cd "$p"
  printf '# Testing\n\n## Commands\n- All tests: `true`\n- Changed tests: `true {files}`\n' >.forge/TESTING.md
}
fresh() {
  base
  mkdir -p $S/features/crm-export
  echo '{"requirements": [{"id": "EXP-01", "text": "Export leads", "done": false}]}' >$S/features/crm-export/requirements.json
  jq -n '{phases: [{slug: "export-core", goal: "Core", spec: [], requirements: ["EXP-01"], depends: []}, {slug: "export-api", goal: "API", spec: [], requirements: ["EXP-01"], depends: ["export-core"]}]}' >$S/features/crm-export/split.json
  "$forge" alloc crm/export >/dev/null
  gitinit "$p"
  git add -A && git commit -q -m init
  "$forge" implement crm/export >/dev/null
  : >"$CLAUDE_LOG"
}
pd=$S/phases/05-export-core wt=.claude/worktrees/crm-export-05
finding() { jq -n --arg f "$1" --argjson l "$2" --arg s "$3" --arg m "$4" --argjson x "$5" '{file: $f, line: $l, severity: $s, summary: $m, fixed: $x}'; }
review() { local out=$1; shift; mkdir -p "$(dirname "$out")"; jq -n '{findings: $ARGS.positional | map(fromjson)}' --args "$@" >"$out"; }

if want done; then
plantasks() { jq -n '{tasks: $ARGS.positional | map({id: ., title: "x", requirements: ["EXP-01"], files: ["core.txt"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"})}' --args "$@" >$pd/plan.json; }
taskrec() { mkdir -p $pd/tasks && jq -n --arg i "$1" --arg s "$2" '{id: $i, status: $s}' >$pd/tasks/$1.json; }
notdone() { grep -qE "^  tasks: $1 not committed through forge task-done: " "$tmp/out"; }
merged05() { git merge-base --is-ancestor forge/crm-export-05 forge/crm-export && [ -f .claude/worktrees/crm-export/core.txt ]; }
testevs() { jq -sr 'map(select(.step == "tests")) | length' $pd/events.jsonl 2>/dev/null || echo 0; }
fresh
echo core >"$wt/core.txt" && git -C "$wt" add core.txt && git -C "$wt" commit -q -m core
echo '{"status": "done", "summary": "core"}' >$pd/result.json
review $pd/review.json "$(finding src/a.ts 3 high "Drops leads" false)"
jq '.pending = ["codex: setup --json exited 1"]' $pd/review.json >"$tmp/rj" && mv "$tmp/rj" $pd/review.json
jq -n '{command: "true", passed: true, criteria: [{criterion: "Exports JSON", met: true, evidence: "t"}, {criterion: "Streams rows", met: false, evidence: "none"}]}' >$pd/verify.json
plantasks T1 T2 T3
taskrec T1 done
taskrec T3 failed
hf=$(git rev-parse forge/crm-export) head=$(git rev-parse HEAD)
[ "$(code "$forge" done 05)" = 1 ] || fail "done with uncommitted tasks exits 1: $(cat "$tmp/out")"
grep -qxF "forge: phase 05 is not done:" "$tmp/out" || fail "done names the phase: $(cat "$tmp/out")"
[ "$(grep -c '^  ' "$tmp/out")" = 2 ] && notdone T2 && notdone T3 || fail "done lists only a tasks line for each planned task without a done record, no review, verify or tests line: $(cat "$tmp/out")"
! notdone T1 || fail "a task recorded done is not named: $(cat "$tmp/out")"
grep -qxF "  tasks: T2 not committed through forge task-done: no $pd/tasks/T2.json at status done" "$tmp/out" || fail "the tasks line names the task record in the S phase dir $pd: $(cat "$tmp/out")"
tail -1 "$tmp/out" | grep -F "forge task-done" | grep -qF "forge done 05" || fail "done closes telling the session to commit each task through forge task-done and rerun forge done 05: $(cat "$tmp/out")"
! grep -qE "forge-fixer|forge fixes|forge-verifier|forge-reviewer|settle|--accept" "$tmp/out" || fail "the refusal names no fixer, fixes, verifier, reviewer, settle or --accept: $(cat "$tmp/out")"
[ "$(git rev-parse forge/crm-export)" = "$hf" ] && [ "$(git rev-parse HEAD)" = "$head" ] || fail "a refused done merges and commits nothing"
! grep -q -- " --bg " "$CLAUDE_LOG" || fail "a refused done starts nothing"
taskrec T2 done
[ "$(code "$forge" done 05)" = 1 ] && notdone T3 && ! notdone T2 && [ "$(grep -c '^  ' "$tmp/out")" = 1 ] || fail "a failed task record is not committed through forge task-done: $(cat "$tmp/out")"
! merged05 || fail "an uncommitted task merges nothing"
taskrec T3 done
rm -r $pd/review.json $pd/verify.json
[ "$(code "$forge" done 05)" = 0 ] || fail "done with every planned task recorded done and no verify.json or review record exits 0: $(cat "$tmp/out")"
merged05 || fail "done merges once every planned task is done"
: >"$CLAUDE_LOG"
review $S/phases/06-export-api/review.json "$(finding src/a.ts 3 high "Open" false)"
echo '{"status": "blocked", "summary": "api"}' >$S/phases/06-export-api/result.json
[ "$(code "$forge" done 06)" = 0 ] || fail "a blocked result is recorded: $(cat "$tmp/out")"
for tl in '- All tests: none' '- Changed tests: `true {files}`'; do
  fresh
  echo core >"$wt/core.txt"
  printf '%s\n' "# Testing" "" "## Commands" "$tl" >"$wt/.forge/TESTING.md"
  git -C "$wt" add -A && git -C "$wt" commit -q -m core
  echo '{"status": "done", "summary": "core"}' >$pd/result.json
  plantasks T1
  taskrec T1 done
  s=0; "$forge" done 05 >"$tmp/out" 2>"$tmp/err" || s=$?
  [ $s = 0 ] || fail "done under TESTING.md $tl exits 0: $s $(cat "$tmp/out" "$tmp/err")"
  ! grep -qF "warning" "$tmp/out" "$tmp/err" || fail "done under TESTING.md $tl prints no warning: $(cat "$tmp/out" "$tmp/err")"
  [ "$(testevs)" = 0 ] || fail "done under TESTING.md $tl logs no tests event: $(cat $pd/events.jsonl)"
  merged05 || fail "done under TESTING.md $tl merges"
done
fresh
echo core >"$wt/core.txt" && git -C "$wt" add core.txt && git -C "$wt" commit -q -m core
echo '{"status": "done", "summary": "core"}' >$pd/result.json
plantasks T1
taskrec T1 done
"$forge" check 05 >"$tmp/c" 2>&1 || fail "check 05: $(cat "$tmp/c")"
[ "$(code "$forge" finish 05)" = 0 ] || fail "finish with every planned task recorded done and no verify.json or review record exits 0: $(cat "$tmp/out")"
grep -qxF "forge: phase 05 finished" "$tmp/out" || fail "finish reports the finished phase: $(cat "$tmp/out")"
merged05 || fail "finish merges the phase once the gate passes"
ok done
fi

if want done-sync-unmet; then
fresh
echo phase >"$wt/core.txt" && git -C "$wt" add core.txt && git -C "$wt" commit -q -m phase
fw=.claude/worktrees/crm-export
echo feature >$fw/core.txt && git -C $fw add core.txt && git -C $fw commit -q -m feature
jq -n '{tasks: [{id: "T1", title: "x", requirements: ["EXP-01"], files: ["core.txt"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"}]}' >$pd/plan.json
mkdir -p $pd/tasks && jq -n '{id: "T1", status: "done"}' >$pd/tasks/T1.json
hf=$(git rev-parse forge/crm-export)
jq -n '{status: "done", summary: "core", unmet: [{task: "T1", reason: "attempts ran out"}]}' >$pd/result.json
[ "$(code "$forge" done 05)" = 6 ] || fail "a conflicting done whose unmet holds no sync entry still exits 6: $(cat "$tmp/out")"
! grep -qF "done with sync unmet" "$tmp/out" || fail "a conflict with no sync entry prints no sync-unmet line: $(cat "$tmp/out")"
[ "$(git rev-parse forge/crm-export)" = "$hf" ] || fail "a conflicting done leaves forge/crm-export unmoved"
jq -n '{status: "done", summary: "core", unmet: [{task: "sync", reason: "merge conflict on core.txt"}]}' >$pd/result.json
[ "$(code "$forge" done 05)" = 0 ] || fail "a done result with a sync unmet entry exits 0 despite the conflict: $(cat "$tmp/out")"
grep -qxF "forge: phase 05 done with sync unmet" "$tmp/out" || fail "done prints the sync-unmet line: $(cat "$tmp/out")"
[ "$(git rev-parse forge/crm-export)" = "$hf" ] || fail "a sync-unmet done leaves forge/crm-export unmoved"
! git merge-base --is-ancestor forge/crm-export-05 forge/crm-export || fail "a sync-unmet done leaves the phase branch unmerged"
[ "$(cat $fw/core.txt)" = feature ] && [ -z "$(git -C $fw status --porcelain)" ] || fail "a sync-unmet done leaves the feature worktree untouched: $(git -C $fw status --porcelain)"
rm $pd/tasks/T1.json
[ "$(code "$forge" done 05)" = 1 ] && grep -qF "  tasks: T1 not committed through forge task-done" "$tmp/out" || fail "a sync-unmet done keeps the task gate: $(cat "$tmp/out")"
ok done-sync-unmet
fi

if want archive; then
fresh
fi=$S/features/crm-intake
echo '{"final_review": ["No findings"], "pr": null, "date": "2026-09-27"}' >$fi/ship.json
kept() { [ -d $fi ] && [ -d $S/phases/02-intake-form ] || fail "a refused archive moves nothing"; }
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "archive with no feature branch exits 1"
grep -qF "forge/crm-intake" "$tmp/out" && grep -qF "after land" "$tmp/out" || fail "archive names the missing branch: $(cat "$tmp/out")"
kept
git branch forge/intake main
echo 'not json' >$fi/review.json
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "archive must refuse, not pass, when a review record cannot be read: $(cat "$tmp/out")"
grep -qF "cannot read the review record" "$tmp/out" || fail "archive names the unreadable review record: $(cat "$tmp/out")"
kept
review $fi/review.json "$(finding src/a.ts 3 high "Open high" false)" "$(finding src/b.ts 4 low "Low" false)"
review $fi/review/api.json "$(finding src/c.ts 5 medium "Open medium" false)" "$(finding src/d.ts 6 high "Dismissed" false | jq -c '.dismissed = "settled: not reachable"')"
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "archive with open findings exits 1"
grep -qxF "  review: src/a.ts:3 high: Open high" "$tmp/out" && grep -qxF "  review: src/c.ts:5 medium: Open medium" "$tmp/out" || fail "archive lists the open findings: $(cat "$tmp/out")"
! grep -qE "src/(b|d)\.ts" "$tmp/out" || fail "low and dismissed findings do not block archive: $(cat "$tmp/out")"
kept
review $fi/review.json "$(finding src/a.ts 3 high "Open high" true)"
review $fi/review/api.json "$(finding src/c.ts 5 medium "Open medium" true)"
git branch forge/crm-intake "$(git commit-tree -p main -m unlanded "main^{tree}")"
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "archive of an unlanded feature branch exits 1"
grep -qF "forge/crm-intake is not merged into main" "$tmp/out" || fail "archive prefers the track-qualified branch and names it: $(cat "$tmp/out")"
kept
git merge -q --no-ff -m land forge/crm-intake
jq '.pending = ["codex: adversarial-review exited 1: fatal: no main"]' $fi/review.json >"$tmp/rj" && mv "$tmp/rj" $fi/review.json
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "archive with a pending review part exits 1: $(cat "$tmp/out")"
grep -qF "  review: pending codex: adversarial-review exited 1: fatal: no main in $fi/review.json" "$tmp/out" || fail "archive lists the pending part: $(cat "$tmp/out")"
kept
jq 'del(.pending)' $fi/review.json >"$tmp/rj" && mv "$tmp/rj" $fi/review.json
git branch forge/crm-old "$(git commit-tree -p main -m old "main^{tree}")" && git merge -q --no-ff -m old forge/crm-old
[ "$(code "$forge" archive crm/intake)" = 0 ] || fail "archive after land exits 0: $(cat "$tmp/out")"
! git show-ref -q --verify refs/heads/forge/crm-old || fail "archive runs gc, which collects another archived feature's merged branch: $(cat "$tmp/out")"
git show-ref -q --verify refs/heads/forge/crm-export && [ -d .claude/worktrees/crm-export-05 ] || fail "archive's gc keeps an open feature's branch and worktree"
! grep -qF "forge: warning" "$tmp/out" || fail "archive's gc in a repo with no origin warns nothing: $(cat "$tmp/out")"
[ -d $S/archive/crm-intake/phases/02-intake-form ] && [ ! -e $fi ] || fail "archive moves the landed feature"
! git show-ref -q --verify refs/heads/forge/crm-intake || fail "archive deletes the landed feature branch"
git show-ref -q --verify refs/heads/forge/intake || fail "archive keeps other branches"
fresh
echo '{"final_review": ["No findings"], "pr": null, "date": "2026-09-27"}' >$fi/ship.json
git branch forge/intake "$(git commit-tree -p main -m unlanded "main^{tree}")"
[ "$(code "$forge" archive crm/intake)" = 1 ] && grep -qF "forge/intake is not merged into main" "$tmp/out" || fail "archive falls back to forge/<feature>: $(cat "$tmp/out")"
git merge -q --no-ff -m land forge/intake
[ "$(code "$forge" archive crm/intake)" = 0 ] || fail "archive of a landed fallback branch exits 0: $(cat "$tmp/out")"
! git show-ref -q --verify refs/heads/forge/intake || fail "archive deletes the landed fallback branch"
fresh
echo '{"final_review": ["No findings"], "pr": null, "date": "2026-09-27"}' >$fi/ship.json
git merge -q --no-ff -m "Merge branch 'forge/crm-intake-2'" "$(git commit-tree -p main -m other "main^{tree}")"
[ "$(code "$forge" archive crm/intake)" = 1 ] || fail "another feature's land merge does not count: $(cat "$tmp/out")"
git merge -q --no-ff -m "Merge branch 'forge/crm-intake'" "$(git commit-tree -p main -m landed "main^{tree}")"
mkdir -p "$tmp/gcfail" && printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/gcfail/claude" && chmod +x "$tmp/gcfail/claude"
s=0; PATH=$tmp/gcfail:$PATH "$forge" archive crm/intake >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 0 ] || fail "archive accepts a gone branch whose land merge is on main, and a failing gc keeps exit 0: $s $(cat "$tmp/out" "$tmp/err")"
[ -d $S/archive/crm-intake ] || fail "archive moves the feature whose branch is gone"
grep -qxF "forge: warning: forge gc failed in $p: cannot list Claude sessions" "$tmp/err" || fail "a failing gc warns on stderr naming the repo and cause: $(cat "$tmp/err")"
ok archive
fi

if want fixes; then
base
fr=$S/features/crm-export
mkdir -p $fr
review $fr/review.json "$(finding src/a.ts 9 high "Second in a" false)" "$(finding src/b.ts 1 low "Only in b" false)" "$(finding src/a.ts 3 medium "First in a" false)" \
  "$(finding src/c.ts 1 high "Fixed" true)" "$(finding src/d.ts 1 high "Dismissed" false | jq -c '.dismissed = "by design"')"
review $fr/review/reviewer.json "$(finding src/a.ts 3 medium "First in a" false)" "$(finding src/e.ts 2 medium "Raw" false)"
review $fr/review/reviewer-api.json "$(finding src/h.ts 4 high "Raw repo" false)"
review $fr/review/audit.json "$(finding src/f.ts 2 medium "Raw audit" false)"
review $fr/review/detect.json "$(finding src/g.ts 2 medium "Raw detect" false)"
[ "$(code "$forge" fixes crm/export)" = 0 ] || fail "fixes exits 0: $(cat "$tmp/out")"
rv=$fr/review.json
jq -nc --arg rv "$rv" '
  {repo: null, file: "src/a.ts", findings: [{index: 2, severity: "medium", line: 3, summary: "First in a", review: $rv, security: false}, {index: 0, severity: "high", line: 9, summary: "Second in a", review: $rv, security: false}]},
  {repo: null, file: "src/b.ts", findings: [{index: 1, severity: "low", line: 1, summary: "Only in b", review: $rv, security: false}]}' >"$tmp/want"
diff -u "$tmp/want" "$tmp/out" || fail "fixes prints one line per file with its open findings from review.json only"
review $fr/review.json "$(finding lib/x.ts 1 high "Feature" false)" "$(finding README.md 2 medium "Current repo" false)"
review $fr/review/api.json "$(finding README.md 2 medium "Current repo" false)" "$(finding README.md 5 low "Api" false)"
review $fr/review/reviewer.json "$(finding lib/y.ts 1 high "Raw" false)"
review $fr/review/reviewer-api.json "$(finding lib/w.ts 1 high "Raw repo" false)"
review $fr/review-api.json "$(finding lib/v.ts 1 high "Ship in progress" false)"
jq '.pending = ["codex: setup --json exited 1"]' $fr/review-api.json >"$tmp/rj" && mv "$tmp/rj" $fr/review-api.json
[ "$(code "$forge" fixes crm/export)" = 0 ] || fail "fixes reads a feature's review and not a pending F/review-<repo>.json: $(cat "$tmp/out")"
jq -nc --arg rv "$fr/review.json" --arg api "$fr/review/api.json" '
  {repo: null, file: "README.md", findings: [{index: 1, severity: "medium", line: 2, summary: "Current repo", review: $rv, security: false}]},
  {repo: null, file: "lib/x.ts", findings: [{index: 0, severity: "high", line: 1, summary: "Feature", review: $rv, security: false}]},
  {repo: "api", file: "README.md", findings: [{index: 0, severity: "medium", line: 2, summary: "Current repo", review: $api, security: false}, {index: 1, severity: "low", line: 5, summary: "Api", review: $api, security: false}]}' >"$tmp/want"
diff -u "$tmp/want" "$tmp/out" || fail "fixes keeps each repo's record apart and skips raw agent output, reviewer-<repo>.json included, and F/review-<repo>.json"
[ "$(code "$forge" fixes crm/routing)" = 0 ] && [ ! -s "$tmp/out" ] || fail "no review prints nothing: $(cat "$tmp/out")"
jq '.pending = ["codex: setup --json exited 1"]' $fr/review/api.json >"$tmp/rj" && mv "$tmp/rj" $fr/review/api.json
[ "$(code "$forge" fixes crm/export)" = 1 ] || fail "fixes refuses while a review part is pending: $(cat "$tmp/out")"
grep -qF "  review: pending codex: setup --json exited 1 in $fr/review/api.json" "$tmp/out" && grep -qF "forge-reviewer" "$tmp/out" \
  || fail "fixes names the pending part and the fallback: $(cat "$tmp/out")"
! grep -qF "review-api.json" "$tmp/out" || fail "fixes does not name a pending F/review-<repo>.json: $(cat "$tmp/out")"
[ "$(cd "$S" && FORGE_ROOT=$p code "$forge" fixes crm/export --record features/crm-export/review-api.json)" = 1 ] || fail "fixes --record refuses while that record is pending: $(cat "$tmp/out")"
grep -qF "  review: pending codex: setup --json exited 1 in $fr/review-api.json" "$tmp/out" && grep -qF "forge-reviewer" "$tmp/out" \
  || fail "fixes --record names that record's pending part, its path resolved against the current directory: $(cat "$tmp/out")"
! grep -qF "review/api.json" "$tmp/out" || fail "fixes --record reads that record only: $(cat "$tmp/out")"
review $fr/review-api.json \
  "$(finding lib/v.ts 7 high "Ship in progress" false)" \
  "$(finding lib/v.ts 2 medium "Earlier" false)" \
  "$(finding lib/u.ts 1 low "Fixed" true)" \
  "$(finding lib/t.ts 3 medium "Codex only" false | jq -c '.source = "codex"')" \
  "$(finding lib/s.ts 4 medium "Todo" false | jq -c '.deferred = {owner: "todo", reason: "later"}')" \
  "$(finding lib/q.ts 5 high "Later phase" false | jq -c '.deferred = {owner: "phase 06", reason: "api"}')"
mkdir -p "$tmp/rec"
cp $fr/review-api.json "$tmp/rec/ship-api.json"
echo '{"focus": []}' >"$tmp/rec/spec.json"
echo '{"focus": ["pii"]}' >$fr/spec.json
recwant() {
  jq -nc --arg rv "$1" '
    {file: "lib/q.ts", findings: [{index: 5, severity: "high", line: 5, summary: "Later phase", review: $rv, security: true}]},
    {file: "lib/v.ts", findings: [{index: 1, severity: "medium", line: 2, summary: "Earlier", review: $rv, security: true}, {index: 0, severity: "high", line: 7, summary: "Ship in progress", review: $rv, security: true}]}' >"$tmp/want"
  jq -e 'has("repo")' "$tmp/out" >/dev/null && jq -c 'del(.repo)' "$tmp/out" >"$tmp/got" && diff -u "$tmp/want" "$tmp/got"
}
[ "$(code "$forge" fixes crm/export --record $fr/review-api.json)" = 0 ] || fail "fixes --record lists a finished record while F/review/api.json is pending: $(cat "$tmp/out")"
recwant "$fr/review-api.json" || fail "fixes --record prints that record's open findings, review set to the path given: $(cat "$tmp/out")"
[ "$(code "$forge" fixes crm/export --record "$tmp/rec/ship-api.json")" = 0 ] || fail "fixes --record reads a record outside F: $(cat "$tmp/out")"
recwant "$tmp/rec/ship-api.json" || fail "fixes --record takes closure and security from F, not the record's directory: $(cat "$tmp/out")"
[ "$(code "$forge" fixes 05)" = 2 ] || fail "fixes of a phase number is a usage error: $(cat "$tmp/out")"
[ "$(code "$forge" fixes 05 --record "$tmp/rec/ship-api.json")" = 2 ] || fail "fixes --record with a phase number is a usage error: $(cat "$tmp/out")"
[ "$(code "$forge" fixes crm/export --record "")" = 2 ] || fail "fixes --record with an empty value is a usage error: $(cat "$tmp/out")"
[ "$(code "$forge" fixes crm/export --record)" = 2 ] || fail "fixes --record with no value is a usage error: $(cat "$tmp/out")"
"$forge" fixes --help >"$tmp/out" || fail "forge fixes --help exits 0"
grep -qF -- "--record <path>" "$tmp/out" && grep -qF "reviewer-<repo>.json" "$tmp/out" || fail "forge fixes --help documents --record and names reviewer-<repo>.json: $(cat "$tmp/out")"
! grep -qF ".forge/features" "$tmp/out" && grep -qF "STATE/features/<track>-<feature>" "$tmp/out" || fail "forge fixes --help names the feature dir under STATE, not .forge/features: $(cat "$tmp/out")"
[ "$(code "$forge" fixes x)" = 2 ] || fail "a bad scope is a usage error"
ok fixes
fi

ready() {
  fresh
  echo core >"$wt/core.txt" && git -C "$wt" add core.txt && git -C "$wt" commit -q -m core
  echo '{"status": "done", "summary": "core"}' >$pd/result.json
}
fnd() { finding "$1" "$2" "$3" "$4" false | jq -c "${5:-.}"; }
listed() { jq -e --arg f "$1" 'select(.file == $f)' "$tmp/out" >/dev/null; }
sec() { jq -r --arg f "$1" 'select(.file == $f) | .findings[0].security' "$tmp/out"; }
if want review-rule; then
ready
fr=$S/features/crm-export
review $pd/review.json \
  "$(finding src/a.ts 1 high "Fixed" true)" \
  "$(fnd src/b.ts 2 high "Later phase" '.deferred = {owner: "phase 06", reason: "the api phase rewrites it"}')" \
  "$(fnd src/d.ts 4 high "Outside split" '.deferred = {owner: "phase 02", reason: "intake owns it"}')" \
  "$(fnd src/e.ts 5 medium "Own phase" '.deferred = {owner: "phase 05", reason: "later"}')" \
  "$(fnd src/f.ts 6 high "Tracked" '.deferred = {owner: "todo", reason: "needs a migration"}')" \
  "$(fnd src/g.ts 7 high "Dismissed" '.dismissed = "not a defect: guarded upstream"')" \
  "$(fnd src/h.ts 8 high "[security] Token leaks: in logs" '.dismissed = "not a defect: redacted"')" \
  "$(fnd src/i.ts 9 high "[pii] Email logged: in audit" '.dismissed = "settled: operator keeps the audit trail"')" \
  "$(fnd src/j.ts 10 high "[auth] Session fixation: on login" '.deferred = {owner: "todo", reason: "later"}')" \
  "$(fnd src/k.ts 11 high "[auth] Weak check: on refresh" '.deferred = {owner: "phase 06", reason: "the api phase owns refresh"}')" \
  "$(fnd src/l.ts 12 medium "[security] Verbose error: on 500" '.dismissed = "not a defect: internal only"')" \
  "$(fnd src/m.ts 13 medium "Codex nit" '.source = "codex"')" \
  "$(fnd src/n.ts 14 medium "Reviewer nit" '.source = "reviewer"')" \
  "$(fnd src/o.ts 15 high "Codex high" '.source = "codex"')" \
  "$(fnd src/p.ts 16 medium "Mixed" '.source = "codex"')" \
  "$(fnd src/p.ts 16 medium "Mixed" '.source = "reviewer"')" \
  "$(fnd src/q.ts 17 high "Security token leaks" '.dismissed = "not a defect: test key"')" \
  "$(fnd src/r.ts 18 high "Leaks: [security] in body" '.dismissed = "not a defect: test key"')" \
  "$(fnd src/s.ts 19 medium "Audit nit" '.source = "audit"')" \
  "$(fnd src/u.ts 20 medium "Detect nit" '.source = "detect"')"
cp $pd/review.json $fr/review.json
[ "$(code "$forge" fixes crm/export)" = 0 ] || fail "fixes exits 0: $(cat "$tmp/out")"
for x in src/b.ts src/d.ts src/e.ts src/h.ts src/j.ts src/k.ts src/n.ts src/o.ts src/p.ts src/s.ts src/u.ts; do
  listed "$x" || fail "fixes lists the open $x: $(cat "$tmp/out")"
done
for x in src/a.ts src/f.ts src/g.ts src/i.ts src/l.ts src/m.ts src/q.ts src/r.ts; do
  ! listed "$x" || fail "fixes skips the closed or advisory $x: $(cat "$tmp/out")"
done
jq -e '.findings | all(.security | type == "boolean")' "$tmp/out" >/dev/null || fail "fixes adds a boolean security to every finding: $(cat "$tmp/out")"
[ "$(sec src/j.ts)" = true ] && [ "$(sec src/k.ts)" = true ] || fail "an [auth] title is security-class in fixes: $(cat "$tmp/out")"
[ "$(sec src/h.ts)" = true ] || fail "a [security] title is security-class in fixes: $(cat "$tmp/out")"
for x in src/b.ts src/d.ts src/e.ts src/n.ts src/o.ts src/p.ts; do
  [ "$(sec "$x")" = false ] || fail "$x is not security-class in fixes: $(cat "$tmp/out")"
done
rm $fr/review.json
review $pd/review.json \
  "$(finding src/a.ts 1 high "Fixed" true)" \
  "$(fnd src/b.ts 2 high "Later phase" '.deferred = {owner: "phase 06", reason: "the api phase rewrites it"}')" \
  "$(fnd src/f.ts 6 high "Tracked" '.deferred = {owner: "todo", reason: "needs a migration"}')" \
  "$(fnd src/g.ts 7 high "Dismissed" '.dismissed = "not a defect: guarded upstream"')" \
  "$(fnd src/i.ts 9 high "[pii] Email logged: in audit" '.dismissed = "settled: operator keeps the audit trail"')" \
  "$(fnd src/k.ts 11 high "[auth] Weak check: on refresh" '.deferred = {owner: "phase 06", reason: "the api phase owns refresh"}')" \
  "$(fnd src/m.ts 13 medium "Codex nit" '.source = "codex"')"
jq '.findings |= map(select((.deferred.owner // "") | startswith("phase ") | not))' $pd/review.json >$fr/review.json
[ "$(code "$forge" fixes crm/export)" = 0 ] && [ ! -s "$tmp/out" ] || fail "fixes prints nothing when every finding is closed or advisory: $(cat "$tmp/out")"
rm $fr/review.json
for fo in security pii; do
  ready
  jq --arg fo "$fo" '.focus = [$fo]' $pd/spec.json >"$tmp/sp" && mv "$tmp/sp" $pd/spec.json
  review $pd/review.json \
    "$(fnd src/a.ts 1 high "Plain bug" '.dismissed = "not a defect: guarded"')" \
    "$(fnd src/b.ts 2 high "Ruled bug" '.dismissed = "settled: operator ruled it safe"')" \
    "$(fnd src/c.ts 3 high "Todo bug" '.deferred = {owner: "todo", reason: "later"}')" \
    "$(fnd src/d.ts 4 medium "Medium bug" '.dismissed = "not a defect: guarded"')"
  jq -n --arg fo "$fo" '{focus: [$fo]}' >$fr/spec.json && cp $pd/review.json $fr/review.json
  [ "$(code "$forge" fixes crm/export)" = 0 ] && [ "$(sec src/c.ts)" = true ] || fail "a high under a $fo focus is security-class in fixes: $(cat "$tmp/out")"
done
fresh
review $fr/review.json \
  "$(fnd lib/x.ts 1 high "Final later" '.deferred = {owner: "phase 06", reason: "api"}')" \
  "$(fnd lib/y.ts 2 high "Final todo" '.deferred = {owner: "todo", reason: "later"}')" \
  "$(fnd lib/z.ts 3 medium "Final codex" '.source = "codex"')"
[ "$(code "$forge" fixes crm/export)" = 0 ] || fail "fixes reads a feature's review: $(cat "$tmp/out")"
listed lib/x.ts && ! listed lib/y.ts && ! listed lib/z.ts || fail "a feature record has no valid phase owner, a todo deferral and a Codex-only medium are skipped: $(cat "$tmp/out")"
for c in fixes archive; do
  "$forge" "$c" --help >"$tmp/out" || fail "forge $c --help exits 0"
  grep -qF "deferred" "$tmp/out" && grep -qF "settled: " "$tmp/out" && grep -qF "advisory" "$tmp/out" || fail "forge $c --help states the new rule: $(cat "$tmp/out")"
done
ok review-rule
fi

plan() { jq -n --arg r "$2" '{tasks: [{id: "T1", title: "x", files: $ARGS.positional, deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"} + (if $r == "" then {} else {repo: $r} end)]}' --args "${@:3}" >"$1/plan.json"; }
overlaps() { jq -sr 'map(select(.step == "overlap") | .message) | join("|")' $pd/events.jsonl; }
if want cross-overlap; then
fresh
plan $S/phases/02-intake-form "" src/form.ts src/api.ts
echo '{"status": "blocked", "summary": "form"}' >$S/phases/02-intake-form/result.json
mkdir -p $S/phases/03-intake-api && plan $S/phases/03-intake-api "" src/api.ts
mkdir -p $S/phases/20-other && jq -n '{track: "voice", feature: "tag", number: "20", slug: "other", goal: "g", spec: [], requirements: [], depends: []}' >$S/phases/20-other/spec.json
plan $S/phases/20-other api src/form.ts
echo '{"status": "done", "summary": "x"}' >$S/phases/20-other/result.json
mkdir -p $S/phases/21-live && jq -n '{track: "voice", feature: "tag", number: "21", slug: "live", goal: "g", spec: [], requirements: [], depends: []}' >$S/phases/21-live/spec.json
plan $S/phases/21-live api lib/x.ts
plan $S/phases/06-export-api "" src/api.ts
plan $pd "" src/form.ts src/api.ts src/core.ts
jq '.tasks[0].repo = "api" | .tasks[0].files += ["lib/x.ts"] | .tasks += [{id: "T2", title: "y", files: ["src/form.ts", "src/api.ts", "src/core.ts"], deps: [], dep_reasons: {}, test: "exempt", exempt_reason: "x"}]' $pd/plan.json >"$tmp/pl" && mv "$tmp/pl" $pd/plan.json
jq '.tasks[].requirements = ["EXP-01"]' $pd/plan.json >"$tmp/pl" && mv "$tmp/pl" $pd/plan.json
s=0; "$forge" check 05 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a cross-feature overlap does not block check: $s $(cat "$tmp/out" "$tmp/err")"
grep -qxF "forge: warning: phase 05 plans files that phase 02 (crm/intake) also plans: src/api.ts, src/form.ts" "$tmp/err" || fail "check warns about the failed but active phase 02: $(cat "$tmp/err")"
grep -qxF "forge: warning: phase 05 plans files that phase 03 (crm/intake) also plans: src/api.ts" "$tmp/err" || fail "check warns about 03: $(cat "$tmp/err")"
grep -qxF "forge: warning: phase 05 plans files that phase 21 (voice/tag) also plans: api:lib/x.ts" "$tmp/err" || fail "check warns per repo about 21: $(cat "$tmp/err")"
[ "$(wc -l <"$tmp/err")" = 3 ] || fail "no warning for a done phase, the same path in another repo or a phase of the same feature: $(cat "$tmp/err")"
[ "$(overlaps)" = "phase 02 (crm/intake): src/api.ts, src/form.ts|phase 03 (crm/intake): src/api.ts|phase 21 (voice/tag): api:lib/x.ts" ] || fail "check logs one overlap event per phase: $(overlaps)"
[ "$(jq -c .depends $pd/spec.json)" = '[]' ] || fail "a cross-feature overlap adds no depends"
"$forge" validate $pd/events.jsonl || fail "overlap events validate"
ok cross-overlap
fi

if want cross-overlap-union; then
fresh
printf 'docs/log.md merge=union\n' >.claude/worktrees/crm-export/.gitattributes
git -C .claude/worktrees/crm-export add .gitattributes && git -C .claude/worktrees/crm-export commit -q -m attributes
plan $S/phases/03-intake-api "" docs/log.md
mkdir -p $S/phases/22-mixed && jq -n '{track: "voice", feature: "tag", number: "22", slug: "mixed", goal: "g", spec: [], requirements: [], depends: []}' >$S/phases/22-mixed/spec.json
plan $S/phases/22-mixed "" docs/log.md src/core.ts
plan $pd "" docs/log.md src/core.ts
jq '.tasks[].requirements = ["EXP-01"]' $pd/plan.json >"$tmp/pl" && mv "$tmp/pl" $pd/plan.json
s=0; "$forge" check 05 >"$tmp/out" 2>"$tmp/err" || s=$?
[ $s = 0 ] && [ "$(cat "$tmp/out")" = "plan ok" ] || fail "a cross-feature overlap with union files does not block check: $s $(cat "$tmp/out" "$tmp/err")"
! grep -qF "phase 03 (crm/intake)" "$tmp/err" || fail "a cross-feature overlap on only a union-merged file warns nothing: $(cat "$tmp/err")"
grep -qxF "forge: warning: phase 05 plans files that phase 22 (voice/tag) also plans: src/core.ts" "$tmp/err" || fail "the warning lists only the non-union file: $(cat "$tmp/err")"
[ "$(wc -l <"$tmp/err")" = 1 ] || fail "one warning, for the mixed overlap only: $(cat "$tmp/err")"
[ "$(overlaps)" = "phase 22 (voice/tag): src/core.ts" ] || fail "only the mixed overlap logs an event, listing the non-union file: $(overlaps)"
"$forge" validate $pd/events.jsonl || fail "overlap events validate"
ok cross-overlap-union
fi

finish
