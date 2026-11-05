#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"
unset COLUMNS
mkdir -p "$tmp/cbin"
printf '#!/usr/bin/env bash\n[ "$*" = "agents --json --all" ] || exit 64\necho "[]"\n' >"$tmp/cbin/claude" && chmod +x "$tmp/cbin/claude"
export PATH=$tmp/cbin:$PATH HOME=$tmp/home
mkdir -p "$HOME"
sp=$XDG_STATE_HOME/forge/p

sphase() {
  mkdir -p "$sp/phases/$1-$4"
  jq -n --arg t "$2" --arg f "$3" --arg n "$1" --arg s "$4" \
    '{track: $t, feature: $f, number: $n, slug: $s, goal: $s, spec: [], requirements: [], depends: []}' >"$sp/phases/$1-$4/spec.json"
  [ -z "${5:-}" ] || echo "{\"status\": \"$5\", \"summary\": \"$4\"}" >"$sp/phases/$1-$4/result.json"
}
if want status; then
fresh
echo '{"status": "blocked", "summary": "api"}' >$sp/phases/03-intake-api/result.json
sphase 11 crm routing routing-rules done
sphase 12 crm routing routing-ui done
jq '.phases[0].number = "11" | .phases[1].number = "12"' $sp/features/crm-routing/split.json >"$tmp/split" && mv "$tmp/split" $sp/features/crm-routing/split.json
sphase 10 crm intake intake-dropped done
sphase 16 voice routing voice-routing done
mkdir -p $sp/features/crm-export $sp/features/crm-audit $sp/features/voice-tag
echo '{"spec": ["Export as JSON."], "decisions": []}' >$sp/features/crm-export/spec.json
echo '{"phases": [{"number": "13", "slug": "audit-log", "goal": "Log changes", "spec": [], "requirements": [], "depends": []}]}' >$sp/features/crm-audit/split.json
sphase 13 crm audit audit-log done
echo '{"manual_test": ["Edit a lead"], "result": "pass", "gaps": []}' >$sp/features/crm-audit/verify.json
echo '{"phases": [{"number": "14", "slug": "tag-notes", "goal": "Tag notes", "spec": [], "requirements": [], "depends": []}, {"number": "15", "slug": "tag-search", "goal": "Search tags", "spec": [], "requirements": [], "depends": []}]}' >$sp/features/voice-tag/split.json
sphase 14 voice tag tag-notes done
sphase 15 voice tag tag-search done
echo '{"manual_test": ["Tag a note"], "result": "pass", "gaps": []}' >$sp/features/voice-tag/verify.json
echo '{"final_review": [], "pr": "https://example.com/pr/1", "date": "2026-09-20"}' >$sp/features/voice-tag/ship.json
"$forge" status | diff -u "$fx/expected/status.md" -
! "$forge" status | grep -q '^## Ready$' || fail "status prints no Ready section"
! "$forge" status --help | grep -q Ready || fail "status --help no longer mentions Ready"
fresh
ok status
fi

sums() { find .forge "$sp" -print0 | sort -z | xargs -0 stat -c '%n %F'; find .forge "$sp" -type f -print0 | sort -z | xargs -0 sha256sum; }
if want status-feature; then
fresh
mkdir -p "$tmp/notpl"
sums >"$tmp/sf.before"
s=0
FORGE_TEMPLATES=$tmp/notpl "$forge" status crm/intake >"$tmp/sf.out" 2>"$tmp/sf.err" || s=$?
[ "$s" = 0 ] || fail "forge status crm/intake must exit 0: exits $s: $(head -n 3 "$tmp/sf.err")"
diff -u "$fx/expected/status-feature.txt" "$tmp/sf.out" || fail "forge status crm/intake prints the feature view from its planning JSON without reading a template"
sums >"$tmp/sf.after"
diff -u "$tmp/sf.before" "$tmp/sf.after" || fail "forge status <track>/<feature> must not change any file under .forge or S"
for a in crm/nosuch nosuch/intake; do
  s=0
  "$forge" status "$a" >"$tmp/sf.out" 2>"$tmp/sf.err" || s=$?
  [ "$s" = 1 ] || fail "forge status $a must exit 1: exits $s: $(cat "$tmp/sf.out" "$tmp/sf.err")"
  grep -q "^forge: .*$a" "$tmp/sf.err" || fail "forge status $a names $a in a forge: message on stderr: $(cat "$tmp/sf.err")"
done
s=0
"$forge" status crm/auth >"$tmp/sf.out" 2>"$tmp/sf.err" || s=$?
[ "$s" = 0 ] || fail "forge status crm/auth (shipped) must exit 0: exits $s: $(head -n 3 "$tmp/sf.err")"
head -n 1 "$tmp/sf.out" | grep -qxF '# crm / auth' || fail "a shipped feature's view starts with its heading: $(cat "$tmp/sf.out")"
grep -qxF 'Status: shipped' "$tmp/sf.out" || fail "a shipped feature's view prints Status: shipped: $(cat "$tmp/sf.out")"
grep -qxF -- '- [x] AUTH-02 (agent): A session lasts 30 days. — concern: crm:C-02' "$tmp/sf.out" ||
  fail "a shipped feature's requirements come from archive/<track>-<feature>/: $(cat "$tmp/sf.out")"
sums >"$tmp/sf.after"
diff -u "$tmp/sf.before" "$tmp/sf.after" || fail "forge status <track>/<feature> must not change any file under .forge or S"
jq '.requirements[1].owner = "operator"' $sp/features/crm-intake/requirements.json >"$tmp/req" && cp "$tmp/req" $sp/features/crm-intake/requirements.json
"$forge" status crm/intake >"$tmp/sf.out" 2>"$tmp/sf.err" || fail "forge status crm/intake with an owner must exit 0: $(cat "$tmp/sf.err")"
grep -qxF -- '- [ ] INT-02 (operator): The API returns the lead. — concern: crm:C-03' "$tmp/sf.out" ||
  fail "a requirement's owner prints in parentheses after its id: $(cat "$tmp/sf.out")"
jq '.requirements[1] += {done: true, accepted: "fine without the toast"}' $sp/features/crm-intake/requirements.json >"$tmp/req" && cp "$tmp/req" $sp/features/crm-intake/requirements.json
"$forge" status crm/intake >"$tmp/sf.out" 2>"$tmp/sf.err" || fail "forge status crm/intake with an accepted requirement must exit 0: $(cat "$tmp/sf.err")"
grep -qxF -- '- [x] INT-02 (operator): The API returns the lead. — accepted: fine without the toast — concern: crm:C-03' "$tmp/sf.out" ||
  fail "an accepted requirement prints the operator's words after its text: $(cat "$tmp/sf.out")"
fresh
ok status-feature
fi

crepo() { rm -rf "$1" && mkdir -p "$1/.forge" && git -C "$1" init -q -b main; }
mkdir -p "$tmp/sjbin"
printf '#!/usr/bin/env bash\necho "$*" >>"$SJ_CLAUDE"\necho "[]"\n' >"$tmp/sjbin/claude"
printf '#!/usr/bin/env bash\necho "$*" >>"$SJ_GIT"\nexec %q "$@"\n' "$(command -v git)" >"$tmp/sjbin/git"
chmod +x "$tmp/sjbin/claude" "$tmp/sjbin/git"
export SJ_CLAUDE=$tmp/sj-claude.log SJ_GIT=$tmp/sj-git.log
sj() {
  local s=0
  rm -f "$SJ_CLAUDE" "$SJ_GIT"
  PATH=$tmp/sjbin:$PATH "$forge" status "$@" >"$tmp/sj.out" 2>"$tmp/sj.err" || s=$?
  [ "$s" = 0 ] || fail "forge status $* must exit 0: exits $s: $(head -n 3 "$tmp/sj.err")"
}
cat >"$tmp/shape.jq" <<'EOF'
def keys_are($k): type == "object" and keys == ($k | sort);
def str: type == "string";
def int($min): type == "number" and . == floor and . >= $min;
def arr(f): type == "array" and all(.[]; f);
def ymd: str and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
def when: str and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$");
def reqs: arr(keys_are(["id", "text", "done"]) and (.id | str) and (.text | str) and (.done | type == "boolean"));
def shipped: arr(keys_are(["feature", "date", "requirements"]) and (.feature | str) and (.date | str) and (.requirements | reqs));
def repos: type == "array" and length > 0 and all(.[]; str);
def source: IN("forge", "gsd");
def feature: keys_are(["feature", "delivers", "status", "phases", "depends", "waiting", "current_phase", "last_activity", "requirements"])
  and (.feature | str) and (.delivers | str)
  and (.status | IN("todo", "discussing", "discussed", "verify", "ship", "stalled", "shipped"))
  and (.phases | . == null or (keys_are(["done", "total"]) and (.done | int(0)) and (.total | int(0))))
  and (.depends | arr(str)) and (.waiting | arr(str))
  and (.current_phase | . == null or (keys_are(["number", "name"]) and (.number | int(1)) and (.name | str)))
  and (.last_activity | . == null or when)
  and (.requirements | reqs);
keys_are(["tracks", "closed_tracks", "quicks", "debugs", "gsd_history", "todos", "seeds", "concerns"])
and (.tracks | arr(keys_are(["track", "goal", "features", "shipped"]) and (.track | str) and (.goal | str) and (.features | arr(feature)) and (.shipped | shipped)))
and (.closed_tracks | arr(keys_are(["track", "goal", "shipped"]) and (.track | str) and (.goal | str) and (.shipped | shipped)))
and (.quicks | arr(keys_are(["slug", "task", "repos", "date", "source"]) and (.slug | str) and (.task | str) and (.repos | repos) and (.date | ymd) and (.source | source)))
and (.debugs | arr(keys_are(["slug", "symptom", "cause", "repos", "date", "source"]) and (.slug | str) and (.symptom | str) and (.cause | str) and (.repos | repos) and (.date | ymd) and (.source | source)))
and (.gsd_history | arr(keys_are(["repo", "milestones"]) and (.repo | str)
  and (.milestones | arr(keys_are(["version", "name", "shipped", "phases"]) and (.version | str) and (.name | str) and (.shipped | . == null or ymd)
    and (.phases | arr(keys_are(["number", "name"]) and (.number | str) and (.name | str)))))))
and (.todos | arr(keys_are(["text", "concern"]) and (.text | str) and (.concern | . == null or (str and test("^[^:]+:C-[0-9]{2,}$")))))
and (.seeds | arr(keys_are(["text"]) and (.text | str)))
and (.concerns | arr(keys_are(["repo", "id", "area", "severity", "focus"]) and (.repo | str) and (.id | str and test("^C-[0-9]{2,}$")) and (.area | str)
  and (.severity | IN("high", "medium", "low"))
  and (.focus | type == "array" and (unique | length) == length and all(.[]; IN("security", "rate-limit", "scaling", "performance", "pii", "budget")))))
EOF
shape() { jq -e -f "$tmp/shape.jq" "$1" >/dev/null 2>&1; }
if want status-json; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
fd=$sp/features
jq -n '{decisions: [], spec: [], build: true}' >$fd/crm-routing/spec.json
jq -n '{manual_test: [], result: "pass", gaps: []}' >$fd/crm-routing/verify.json
mkdir -p $fd/crm-export $fd/crm-audit $fd/crm-auth $fd/voice-tag $fd/voice-search $fd/voice-share $fd/voice-notes
echo '{"spec": ["Export as JSON."], "decisions": []}' >$fd/crm-export/spec.json
echo '{"phases": [{"number": "13", "slug": "audit-log", "goal": "Log changes", "spec": [], "requirements": [], "depends": []}]}' >$fd/crm-audit/split.json
sphase 13 crm audit audit-log done
echo '{"manual_test": ["Edit a lead"], "result": "pass", "gaps": []}' >$fd/crm-audit/verify.json
echo '{"phases": [{"number": "14", "slug": "tag-notes", "goal": "Tag notes", "spec": [], "requirements": [], "depends": []}, {"number": "15", "slug": "tag-search", "goal": "Search tags", "spec": [], "requirements": [], "depends": []}]}' >$fd/voice-tag/split.json
sphase 14 voice tag tag-notes done
sphase 15 voice tag tag-search done
echo '{"phases": [{"number": "17", "slug": "search-index", "goal": "Index notes", "spec": [], "requirements": [], "depends": []}]}' >$fd/voice-search/split.json
sphase 17 voice search search-index
echo '{"time": "2026-09-21T10:00:00Z", "step": "stall", "message": "no progress in 30 min; operator notified"}' >$sp/phases/17-search-index/events.jsonl
echo '{"requirements": [{"id": "SRCH-01", "text": "Search finds a note.", "done": false}]}' >$fd/voice-search/requirements.json
echo '{"final_review": [], "pr": "https://example.com/pr/3", "date": "2026-09-25"}' >$fd/voice-share/ship.json
echo '{"requirements": [{"id": "NOTE-01", "text": "A note saves.", "done": true}]}' >$fd/voice-notes/requirements.json
echo '{"requirements": [{"id": "AUTH-09", "text": "Live copy.", "done": false}]}' >$fd/crm-auth/requirements.json
mkdir -p $sp/archive/old-seed && echo '{"requirements": [{"id": "SEED-01", "text": "Legacy rows import.", "done": true}]}' >$sp/archive/old-seed/requirements.json
jq '.features += [{feature: "search", delivers: "Search notes", depends: ["tag"]}, {feature: "share", delivers: "Share notes", depends: []}]
  | .shipped += [{feature: "notes", phases: ["09"], date: "2026-09-10"}, {feature: "memo", phases: ["08"], date: "2026-09-05"}]' \
  .forge/tracks/voice.json >"$tmp/v" && mv "$tmp/v" .forge/tracks/voice.json
git add -A && git commit -q -m init
git checkout -q -b forge/voice-share && git commit -q --allow-empty -m share && git checkout -q main
crepo app && crepo lib && crepo web && crepo "$tmp/linked"
jq -n '{concerns: [
  {id: "C-01", area: "Intake form has no rate limit", files: ["src/form.ts"], severity: "high", evidence: ["src/form.ts:12"], status: "open", focus: ["rate-limit", "security"]},
  {id: "C-02", area: "Notes render raw HTML", files: ["src/notes.ts"], severity: "medium", evidence: ["src/notes.ts:4"], status: "resolved", focus: ["security"]},
  {id: "C-03", area: "Export query scans every lead", files: ["src/export.ts"], severity: "low", evidence: ["src/export.ts:40"], status: "open"}]}' >app/.forge/concerns.json
jq -n '{concerns: [{id: "C-10", area: "Logs hold emails", files: ["log.py"], severity: "medium", evidence: ["log.py:7"], status: "open", focus: ["pii"]}]}' >web/.forge/concerns.json
jq -n '{concerns: [{id: "C-99", area: "Root concern", files: ["x"], severity: "high", evidence: ["x:1"], status: "open"}]}' >.forge/concerns.json
jq -n '{concerns: [{id: "C-50", area: "Linked concern", files: ["y"], severity: "high", evidence: ["y:1"], status: "open"}]}' >"$tmp/linked/.forge/concerns.json"
echo '{"repos": ["../linked"]}' >.forge/repos.json
jq -n '{quicks: [
  {slug: "fix-typo", task: "Fix the typo", repos: ["app"], date: "2026-09-11", source: "gsd"},
  {slug: "bump-deps", task: "Bump deps", repos: ["app", "web"], date: "2026-09-12"}]}' >$sp/quicks.json
jq -n '{debugs: [
  {slug: "slow-export", symptom: "Export takes minutes", cause: "Full table scan", repos: ["app"], date: "2026-09-14"},
  {slug: "auth-loop", symptom: "Login redirects forever", cause: "Cookie path", repos: ["web"], date: "2026-09-13", source: "gsd"}]}' >$sp/debugs.json
jq -n '{repos: [
  {repo: "web", milestones: [
    {version: "v1.0", name: "Launch", done: true, shipped: "2026-08-20", phases: [{number: "1", name: "Setup"}, {number: "2.1", name: "Auth"}]},
    {version: "v1.1", name: "Polish", done: false, shipped: null, phases: []}]},
  {repo: "app", milestones: [{version: "v0.9", name: "Beta", done: true, shipped: null, phases: [{number: "01", name: "Intake"}]}]}]}' >$sp/history.json
for r in app "$tmp/linked"; do
  jq -n '{quicks: [{slug: "child-quick", task: "Child quick", repos: ["app"], date: "2026-09-01"}]}' >"$r/.forge/quicks.json"
  jq -n '{debugs: [{slug: "child-debug", symptom: "Child symptom", cause: "Child cause", repos: ["app"], date: "2026-09-01"}]}' >"$r/.forge/debugs.json"
  jq -n '{repos: [{repo: "child", milestones: []}]}' >"$r/.forge/history.json"
done
sj
grep -qs '^agents --json --all$' "$SJ_CLAUDE" && grep -qs 'merge-tree' "$SJ_GIT" || fail "the Markdown status lists sessions and runs merge-tree through the shims"
cp "$tmp/sj.out" "$tmp/sj.md"
mkdir "$tmp/hj" && mv $sp/quicks.json $sp/debugs.json $sp/history.json "$tmp/hj/"
sj
diff -u "$tmp/sj.md" "$tmp/sj.out" || fail "forge status Markdown output must not change with quicks.json, debugs.json and history.json present"
mv "$tmp/hj/quicks.json" "$tmp/hj/debugs.json" "$tmp/hj/history.json" "$sp/"
sj --json
cp "$tmp/sj.out" "$tmp/sj.json"
[ "$(jq -s length "$tmp/sj.json")" = 1 ] || fail "status --json prints one JSON document: $(cat "$tmp/sj.json")"
[ ! -s "$SJ_CLAUDE" ] || fail "status --json must not call claude: $(cat "$SJ_CLAUDE")"
! grep -qs 'merge-tree' "$SJ_GIT" || fail "status --json must not run git merge-tree: $(cat "$SJ_GIT")"
shape "$tmp/sj.json" || fail "status --json must have the status shape: $(cat "$tmp/sj.json")"
for e in '.extra = 1' '.tracks[0].extra = 1' '.tracks[0].features[0].extra = 1' '.tracks[0].features[0].phases.extra = 1' '.tracks[0].shipped[0].extra = 1' '.todos[0].extra = 1' '.concerns[0].extra = 1' 'del(.todos)' 'del(.seeds)' 'del(.tracks[0].features[0].phases)' 'del(.todos[1].concern)' '.closed_tracks[0].extra = 1' '.closed_tracks[0].shipped[0].extra = 1' '.closed_tracks[0].features = []' 'del(.closed_tracks)' \
  '.quicks[0].extra = 1' '.debugs[0].extra = 1' '.gsd_history[0].extra = 1' '.gsd_history[0].milestones[0].extra = 1' '.gsd_history[0].milestones[0].phases[0].extra = 1' \
  '.gsd_history[0].milestones[0].done = true' '.quicks[0].source = "other"' '.debugs[0].source = "other"' '.quicks[0].repos = []' '.debugs[0].repos = []' \
  '.quicks[0].date = "Sept 11"' '.debugs[0].date = "2026-9-13"' '.gsd_history[0].milestones[1].shipped = "soon"' '.gsd_history[0].milestones[0].phases[0].number = 1' \
  'del(.quicks[1].source)' 'del(.debugs[0].source)' 'del(.gsd_history[0].milestones[1].shipped)' 'del(.quicks)' 'del(.debugs)' 'del(.gsd_history)'; do
  jq "$e" "$tmp/sj.json" >"$tmp/bad.json"
  ! shape "$tmp/bad.json" || fail "the status shape must reject $e"
done
awk '/^## / { p = $0 == "## Features" } p' "$tmp/sj.md" | awk -F'|' '/^\| [a-z]/ && !/^\| Track/ {gsub(/ /, "", $2); gsub(/ /, "", $3); gsub(/ /, "", $4); print $2 "/" $3 " " $4}' >"$tmp/sj.mdst"
[ "$(cut -d' ' -f2 "$tmp/sj.mdst" | sort -u | tr '\n' ' ')" = "discussed discussing ship shipped stalled todo verify " ] ||
  fail "the fixture covers every Features status: $(cat "$tmp/sj.mdst")"
jq -r '.tracks[] | .track as $t | .features[] | "\($t)/\(.feature) \(.status)"' "$tmp/sj.json" | diff -u "$tmp/sj.mdst" - ||
  fail "each feature's JSON status equals the Markdown Features table's Status"
cat >"$tmp/sj.want" <<'EOF'
{
  "tracks": [
    {
      "track": "crm",
      "goal": "Customer records from intake to export",
      "features": [
        {"feature": "intake", "delivers": "Intake form", "status": "discussed", "phases": {"done": 1, "total": 2}, "depends": [], "waiting": [],
         "current_phase": {"number": 3, "name": "intake-api"}, "last_activity": "2026-09-20T11:00:00Z",
         "requirements": [{"id": "INT-01", "text": "The form saves a lead.", "done": true}, {"id": "INT-02", "text": "The API returns the lead.", "done": false}]},
        {"feature": "routing", "delivers": "Route leads", "status": "ship", "phases": {"done": 0, "total": 2}, "depends": ["intake"], "waiting": ["intake"],
         "current_phase": null, "last_activity": null,
         "requirements": [{"id": "ROUTE-01", "text": "A lead goes to one owner.", "done": false}]},
        {"feature": "export", "delivers": "Export JSON", "status": "discussing", "phases": null, "depends": [], "waiting": [], "current_phase": null, "last_activity": null, "requirements": []},
        {"feature": "audit", "delivers": "Audit trail", "status": "ship", "phases": {"done": 1, "total": 1}, "depends": ["voice/capture"], "waiting": ["voice/capture"], "current_phase": null, "last_activity": null, "requirements": []}
      ],
      "shipped": [
        {"feature": "auth", "date": "2026-09-01",
         "requirements": [{"id": "AUTH-01", "text": "A user logs in with email.", "done": true}, {"id": "AUTH-02", "text": "A session lasts 30 days.", "done": true}]}
      ]
    },
    {
      "track": "voice",
      "goal": "Voice notes on records",
      "features": [
        {"feature": "capture", "delivers": "Capture audio", "status": "todo", "phases": null, "depends": ["crm/auth"], "waiting": [], "current_phase": null, "last_activity": null, "requirements": []},
        {"feature": "tag", "delivers": "Tag notes", "status": "verify", "phases": {"done": 2, "total": 2}, "depends": ["capture", "crm/export"], "waiting": ["capture", "crm/export"], "current_phase": null, "last_activity": null, "requirements": []},
        {"feature": "search", "delivers": "Search notes", "status": "stalled", "phases": {"done": 0, "total": 1}, "depends": ["tag"], "waiting": ["tag"],
         "current_phase": {"number": 17, "name": "search-index"}, "last_activity": "2026-09-21T10:00:00Z",
         "requirements": [{"id": "SRCH-01", "text": "Search finds a note.", "done": false}]},
        {"feature": "share", "delivers": "Share notes", "status": "shipped", "phases": null, "depends": [], "waiting": [], "current_phase": null, "last_activity": null, "requirements": []}
      ],
      "shipped": [
        {"feature": "notes", "date": "2026-09-10", "requirements": [{"id": "NOTE-01", "text": "A note saves.", "done": true}]},
        {"feature": "memo", "date": "2026-09-05", "requirements": []}
      ]
    }
  ],
  "closed_tracks": [
    {
      "track": "old",
      "goal": "Retired line",
      "shipped": [
        {"feature": "seed", "date": "2026-08-01", "requirements": [{"id": "SEED-01", "text": "Legacy rows import.", "done": true}]}
      ]
    }
  ],
  "quicks": [
    {"slug": "fix-typo", "task": "Fix the typo", "repos": ["app"], "date": "2026-09-11", "source": "gsd"},
    {"slug": "bump-deps", "task": "Bump deps", "repos": ["app", "web"], "date": "2026-09-12", "source": "forge"}
  ],
  "debugs": [
    {"slug": "slow-export", "symptom": "Export takes minutes", "cause": "Full table scan", "repos": ["app"], "date": "2026-09-14", "source": "forge"},
    {"slug": "auth-loop", "symptom": "Login redirects forever", "cause": "Cookie path", "repos": ["web"], "date": "2026-09-13", "source": "gsd"}
  ],
  "gsd_history": [
    {"repo": "web", "milestones": [
      {"version": "v1.0", "name": "Launch", "shipped": "2026-08-20", "phases": [{"number": "1", "name": "Setup"}, {"number": "2.1", "name": "Auth"}]},
      {"version": "v1.1", "name": "Polish", "shipped": null, "phases": []}]},
    {"repo": "app", "milestones": [{"version": "v0.9", "name": "Beta", "shipped": null, "phases": [{"number": "01", "name": "Intake"}]}]}
  ],
  "todos": [
    {"text": "Rate-limit the intake form — concern: app:C-01", "concern": "app:C-01"},
    {"text": "Add a CSV export", "concern": null}
  ],
  "seeds": [],
  "concerns": [
    {"repo": "app", "id": "C-01", "area": "Intake form has no rate limit", "severity": "high", "focus": ["rate-limit", "security"]},
    {"repo": "app", "id": "C-03", "area": "Export query scans every lead", "severity": "low", "focus": []},
    {"repo": "web", "id": "C-10", "area": "Logs hold emails", "severity": "medium", "focus": ["pii"]}
  ]
}
EOF
jq -S '.concerns |= sort_by(.repo, .id)' "$tmp/sj.json" | diff -u <(jq -S . "$tmp/sj.want") - ||
  fail "status --json lists open tracks with features and shipped (archive requirements first, then live), closed tracks with goal and shipped (archive requirements too) and no features, root quicks.json and debugs.json entries in file order with source defaulting to forge, root history.json repos in file order with done dropped, todo.md lines with their concern, no seeds without a seeds.md, and open concerns of child repos only"
printf '# Seeds\n\n<!-- one idea per line -->\n\n- 2026-09-01 Root idea\n- Undated root idea — concern: app:C-01\n' >.forge/seeds.md
printf '# Seeds\n\n- App idea\n' >app/.forge/seeds.md
sj --json
jq -S '.concerns |= sort_by(.repo, .id)' "$tmp/sj.out" |
  diff -u <(jq -S '.seeds = [{text: "Root idea"}, {text: "Undated root idea — concern: app:C-01"}]' "$tmp/sj.want") - ||
  fail "root seeds.md '- ' lines appear as seeds {text} with the date prefix stripped and no date or concern key, and a child repo seeds.md adds nothing"
shape "$tmp/sj.out" || fail "the status shape must accept seeds: $(cat "$tmp/sj.out")"
for e in '.seeds[0].extra = 1' '.seeds[0].date = "2026-09-01"' '.seeds[0].concern = null' 'del(.seeds[0].text)' '.seeds[0].text = 1'; do
  jq "$e" "$tmp/sj.out" >"$tmp/bad.json"
  ! shape "$tmp/bad.json" || fail "the status shape must reject $e"
done
chmod 000 .forge/seeds.md
s=0
PATH=$tmp/sjbin:$PATH "$forge" status --json >"$tmp/sj.out" 2>"$tmp/sj.err" || s=$?
chmod 644 .forge/seeds.md
[ "$s" != 0 ] || fail "an unreadable seeds.md must fail status --json: $(cat "$tmp/sj.out")"
grep -q '^forge: .*seeds\.md' "$tmp/sj.err" || fail "an unreadable seeds.md fails status --json with a forge: message naming the file: $(cat "$tmp/sj.err")"
rm .forge/seeds.md app/.forge/seeds.md
sj --json
jq -e '.seeds == []' "$tmp/sj.out" >/dev/null || fail "a missing seeds.md gives an empty seeds list: $(cat "$tmp/sj.out")"
mv .forge/todo.md "$tmp/todo.md"
sj --json
jq -e '.todos == []' "$tmp/sj.out" >/dev/null || fail "a missing todo.md gives an empty todos list: $(cat "$tmp/sj.out")"
mv "$tmp/todo.md" .forge/todo.md
mkdir -p $sp/archive/crm-gone && echo '{"requirements": [' >$sp/archive/crm-gone/requirements.json
sj --json
jq -S '.concerns |= sort_by(.repo, .id)' "$tmp/sj.out" | diff -u <(jq -S . "$tmp/sj.want") - ||
  fail "an invalid archive of a feature no open or closed track ships must not change status --json"
rm -rf $sp/archive/crm-gone
mv $sp/quicks.json $sp/debugs.json $sp/history.json "$tmp/hj/"
sj --json
jq -S '.concerns |= sort_by(.repo, .id)' "$tmp/sj.out" | diff -u <(jq -S '.quicks = [] | .debugs = [] | .gsd_history = []' "$tmp/sj.want") - ||
  fail "a missing root quicks.json, debugs.json or history.json gives [] for its key, child repos' copies adding nothing"
shape "$tmp/sj.out" || fail "the status shape must accept empty quicks, debugs and gsd_history: $(cat "$tmp/sj.out")"
mv "$tmp/hj/quicks.json" "$tmp/hj/debugs.json" "$tmp/hj/history.json" "$sp/"
for f in quicks debugs history; do
  chmod 000 $sp/$f.json
  s=0
  PATH=$tmp/sjbin:$PATH "$forge" status --json >"$tmp/sj.out" 2>"$tmp/sj.err" || s=$?
  chmod 644 $sp/$f.json
  [ "$s" != 0 ] || fail "an unreadable $f.json must fail status --json: $(cat "$tmp/sj.out")"
  grep -qF "forge: cannot read $sp/$f.json" "$tmp/sj.err" || fail "an unreadable $f.json fails status --json with a forge: message naming the file: $(cat "$tmp/sj.err")"
  cp $sp/$f.json "$tmp/hj/$f.json"
  printf '{"%s": [' "$f" >$sp/$f.json
  s=0
  PATH=$tmp/sjbin:$PATH "$forge" status --json >"$tmp/sj.out" 2>"$tmp/sj.err" || s=$?
  mv "$tmp/hj/$f.json" $sp/$f.json
  [ "$s" != 0 ] || fail "an unparsable $f.json must fail status --json: $(cat "$tmp/sj.out")"
  grep -qF "forge: cannot read $sp/$f.json" "$tmp/sj.err" || fail "an unparsable $f.json fails status --json with a forge: message naming the file: $(cat "$tmp/sj.err")"
done
for a in "--jsn" "x" "--json x" "x --json" "--json --json" "-j"; do
  [ "$(code "$forge" status $a)" = 2 ] || fail "forge status $a must be a usage error (exit 2): $(cat "$tmp/out")"
done
echo '{"concerns": [' >web/.forge/concerns.json
s=0
PATH=$tmp/sjbin:$PATH "$forge" status --json >"$tmp/sj.out" 2>"$tmp/sj.err" || s=$?
[ "$s" != 0 ] || fail "an invalid concerns.json must fail status --json"
grep -q '^forge: .*web/\.forge/concerns\.json' "$tmp/sj.err" || fail "an invalid concerns.json fails with a forge: message naming the file: $(cat "$tmp/sj.err")"
rm -rf "$tmp/linked"
fresh
ok status-json
fi

if want status-json-date; then
fresh
cat >.forge/todo.md <<'EOF'
# Todo

- 2026-10-01 Add a CSV export
- Rate-limit the intake form — concern: app:C-01
- 2026-10-03 Fix the notes render — concern: app:C-02
- 2026-1-05 Not a date
- 2026-10-07
EOF
sj --json
cat >"$tmp/sjd.want" <<'EOF'
[
  {"text": "Add a CSV export", "concern": null},
  {"text": "Rate-limit the intake form — concern: app:C-01", "concern": "app:C-01"},
  {"text": "Fix the notes render — concern: app:C-02", "concern": "app:C-02"},
  {"text": "2026-1-05 Not a date", "concern": null},
  {"text": "2026-10-07", "concern": null}
]
EOF
jq -S .todos "$tmp/sj.out" | diff -u <(jq -S . "$tmp/sjd.want") - ||
  fail "status --json todos carry only text and concern with no date key: '- YYYY-MM-DD <text>' lines keep the text after the date, other lines the text after '- '"
shape "$tmp/sj.out" || fail "the status shape must accept todos without a date: $(cat "$tmp/sj.out")"
for e in '.todos[0].extra = 1' '.todos[0].date = "2026-10-01"' '.todos[1].date = null'; do
  jq "$e" "$tmp/sj.out" >"$tmp/bad.json"
  ! shape "$tmp/bad.json" || fail "the status shape must reject $e"
done
printf '# Seeds\n\n- 2026-09-30 Old idea\n- Undated idea\n' >.forge/seeds.md
s=0
FORGE_NOW="2026-10-14 06:00 UTC" TZ=UTC "$forge" status >"$tmp/st" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] || fail "forge status with dated todos and seeds exits $s: $(cat "$tmp/err")"
awk '/^## / { p = $0 == "## Intake" } p' "$tmp/st" | sed '/^$/d' >"$tmp/in"
printf '%s\n' "## Intake" "| Repo | Todos | Seeds | Concerns | Oldest |" "|------|-------|-------|----------|--------|" "| p    | 5     | 2     | 0        | 14     |" |
  diff -u - "$tmp/in" || fail "forge status Intake still counts dated todos and seeds and takes Oldest from the oldest todo or seed date: $(cat "$tmp/st")"
sj --json
jq -e '.seeds == [{text: "Old idea"}, {text: "Undated idea"}]' "$tmp/sj.out" >/dev/null || fail "status --json seeds strip the date prefix while forge status keeps it for Oldest: $(jq -c .seeds "$tmp/sj.out")"
fresh
ok status-json-date
fi

ev() { printf '{"time": "%s", "step": "start", "message": "%s"}\n' "$2" "$3" >>"$1"; }
mdst() { FORGE_NOW="2026-10-14 06:00 UTC" TZ=UTC "$forge" status >"$1" 2>"$tmp/err" || fail "forge status must exit 0: $(cat "$tmp/err")"; }
nowrows() { jq -c '.tracks[] | .track as $t | .features[] | {feature: "\($t)/\(.feature)", status, current_phase, last_activity}' "$tmp/sj.out"; }
if want status-json-now; then
fresh
fd=$sp/features
sphase 05 crm intake intake-sync
jq '.phases = [.phases[0], {number: "05", slug: "intake-sync", goal: "Sync leads", spec: [], requirements: [], depends: []}, .phases[1]]' \
  $fd/crm-intake/split.json >"$tmp/split" && mv "$tmp/split" $fd/crm-intake/split.json
sphase 05 voice capture capture-sync done
ev $sp/phases/05-capture-sync/events.jsonl 2026-10-09T10:00:00Z capture
mkdir -p $fd/crm-export $fd/crm-audit $fd/voice-tag $fd/voice-share
echo '{"spec": ["Export as JSON."], "decisions": []}' >$fd/crm-export/spec.json
echo '{"phases": [{"number": "13", "slug": "audit-log", "goal": "Log changes", "spec": [], "requirements": [], "depends": []}]}' >$fd/crm-audit/split.json
sphase 13 crm audit audit-log done
echo '{"manual_test": ["Edit a lead"], "result": "pass", "gaps": []}' >$fd/crm-audit/verify.json
echo '{"phases": [{"number": "14", "slug": "tag-notes", "goal": "Tag notes", "spec": [], "requirements": [], "depends": []}, {"number": "15", "slug": "tag-search", "goal": "Search tags", "spec": [], "requirements": [], "depends": []}]}' >$fd/voice-tag/split.json
sphase 14 voice tag tag-notes done
sphase 15 voice tag tag-search done
ev $sp/phases/14-tag-notes/events.jsonl 2026-10-01T09:00:00Z tag-notes
ev $sp/phases/15-tag-search/events.jsonl 2026-10-02T09:00:00Z tag-search
ev $sp/phases/15-tag-search/events.jsonl 2026-10-02T08:00:00Z tag-search
jq '.features += [{feature: "share", delivers: "Share notes", depends: []}]' .forge/tracks/voice.json >"$tmp/v" && mv "$tmp/v" .forge/tracks/voice.json
echo '{"final_review": [], "pr": "https://example.com/pr/3", "date": "2026-09-25"}' >$fd/voice-share/ship.json
mdst "$tmp/now-before.md"
ev $fd/crm-export/events.jsonl 2026-10-09T11:00:00Z discuss
ev $fd/crm-audit/events.jsonl 2026-10-04T10:00:00Z ship
ev $fd/voice-tag/events.jsonl 2026-10-01T12:00:00Z verify
ev $fd/voice-share/events.jsonl 2026-10-09T12:00:00Z ship
mdst "$tmp/now-after.md"
diff -u "$tmp/now-before.md" "$tmp/now-after.md" || fail "feature-level events.jsonl must not change forge status (Markdown)"
sj --json
cat >"$tmp/now.want" <<'EOF'
{"feature":"crm/intake","status":"discussed","current_phase":{"number":5,"name":"intake-sync"},"last_activity":"2026-09-20T11:00:00Z"}
{"feature":"crm/routing","status":"discussed","current_phase":null,"last_activity":null}
{"feature":"crm/export","status":"discussing","current_phase":null,"last_activity":null}
{"feature":"crm/audit","status":"ship","current_phase":null,"last_activity":"2026-10-04T10:00:00Z"}
{"feature":"voice/capture","status":"todo","current_phase":null,"last_activity":null}
{"feature":"voice/tag","status":"verify","current_phase":null,"last_activity":"2026-10-02T09:00:00Z"}
{"feature":"voice/share","status":"shipped","current_phase":null,"last_activity":null}
EOF
nowrows | diff -u "$tmp/now.want" - ||
  fail "current_phase is the first unfinished numbered split phase in split order and last_activity the latest phase or feature event time, both null outside the Now set"
shape "$tmp/sj.out" || fail "the status shape must accept current_phase and last_activity: $(cat "$tmp/sj.out")"
for e in 'del(.tracks[0].features[0].current_phase)' 'del(.tracks[0].features[0].last_activity)' '.tracks[0].features[0].current_phase.extra = 1' \
  'del(.tracks[0].features[0].current_phase.number)' 'del(.tracks[0].features[0].current_phase.name)' '.tracks[0].features[0].current_phase.number = "5"' \
  '.tracks[0].features[0].current_phase.number = 0' '.tracks[0].features[0].current_phase.name = 5' '.tracks[0].features[0].current_phase = "intake-sync"' \
  '.tracks[0].features[0].last_activity = "yesterday"' '.tracks[0].features[0].last_activity = 1'; do
  jq "$e" "$tmp/sj.out" >"$tmp/bad.json"
  ! shape "$tmp/bad.json" || fail "the status shape must reject $e"
done
rm $fd/voice-tag/events.jsonl
ev $fd/voice-tag/events.jsonl 2026-10-03T10:00:00Z verify
ev $fd/voice-tag/events.jsonl 2026-10-01T12:00:00Z verify
sj --json
nowrows | jq -e 'select(.feature == "voice/tag") | .last_activity == "2026-10-03T10:00:00Z"' >/dev/null ||
  fail "a feature-level event later than every phase event sets last_activity, whatever its line in events.jsonl: $(nowrows | grep voice/tag)"
fresh
ok status-json-now
fi

intake() {
  local s=0
  FORGE_NOW="2026-10-14 06:00 UTC" TZ=UTC "$forge" status >"$tmp/st" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "$1: status exits $s: $(cat "$tmp/err")"
  awk '/^## / { p = $0 == "## Intake" } p' "$tmp/st" | sed '/^$/d' >"$tmp/in"
}
rows() { head -n 3 "$1"; tail -n +4 "$1" | sort; }
want_intake() {
  printf '%s\n' "## Intake" "| Repo | Todos | Seeds | Concerns | Oldest |" "|------|-------|-------|----------|--------|" "${@:2}" >"$tmp/in.want"
  diff -u <(rows "$tmp/in.want") <(rows "$tmp/in") >"$tmp/in.diff" || fail "$1: $(cat "$tmp/in.diff") in $(cat "$tmp/st")"
}
crepo() { rm -rf "$1" && mkdir -p "$1/.forge" && git -C "$1" init -q -b main; }
if want status-intake; then
fresh
jq -n '{concerns: [
  {id: "C-01", area: "Open undated", files: ["a"], severity: "high", evidence: ["a:1"], status: "open"},
  {id: "C-02", area: "Resolved dated", files: ["b"], severity: "low", evidence: ["b:1"], status: "resolved", date: "2026-01-01"}]}' >.forge/concerns.json
intake "only undated items"
want_intake "a repo with only undated open todos and concerns shows its counts and Oldest —, a resolved concern is not counted, a missing seeds.md counts 0 seeds" "| p    | 2     | 0     | 1        | —      |"
awk '/^## Features$/ { f = NR } /^## Intake$/ { i = NR } END { exit !(f && i > f) }' "$tmp/st" || fail "the Intake section comes after Features: $(cat "$tmp/st")"
printf -- '- 2026-10-12 Dated todo\n' >>.forge/todo.md
jq '.concerns += [{id: "C-03", area: "Open dated", files: ["c"], severity: "low", evidence: ["c:1"], status: "open", date: "2026-10-09"}]' .forge/concerns.json >"$tmp/c" && mv "$tmp/c" .forge/concerns.json
intake "dated concern"
want_intake "Oldest is the whole days since the oldest dated open concern" "| p    | 3     | 0     | 2        | 5      |"
printf -- '- 2026-10-02 Older todo\n' >>.forge/todo.md
intake "dated todo"
want_intake "Oldest is the whole days since the oldest dated todo" "| p    | 4     | 0     | 2        | 12     |"
printf '# Seeds\n\n<!-- one idea per line, today'"'"'s date first: - YYYY-MM-DD <text>; undated - <text> lines stay valid -->\n\n- 2026-09-30 Old idea\n- Undated idea\n' >.forge/seeds.md
intake "seeds"
want_intake "Seeds counts the '- ' lines of .forge/seeds.md, heading and comment lines skipped, and Oldest is the whole days since a seed date older than every todo and concern" "| p    | 4     | 2     | 2        | 14     |"
printf '# Todo\n\n<!-- none -->\n' >.forge/todo.md
jq '.concerns[].status = "resolved"' .forge/concerns.json >"$tmp/c" && mv "$tmp/c" .forge/concerns.json
intake "seeds only"
want_intake "a repo with only seeds gets a row, Oldest from its seed date" "| p    | 0     | 2     | 0        | 14     |"
rm .forge/seeds.md
intake "no open items"
[ ! -s "$tmp/in" ] || fail "the Intake section is left out when no repo has an open todo or concern: $(cat "$tmp/st")"
rm .forge/todo.md .forge/concerns.json
intake "no todo.md or concerns.json"
[ ! -s "$tmp/in" ] || fail "the Intake section is left out without todo.md and concerns.json: $(cat "$tmp/st")"
cp "$fx/project/.forge/todo.md" .forge/todo.md
crepo app && crepo web && crepo lib && crepo docs
jq -n '{concerns: [
  {id: "C-01", area: "Intake form has no rate limit", files: ["src/form.ts"], severity: "high", evidence: ["src/form.ts:12"], status: "open", date: "2026-10-04"},
  {id: "C-02", area: "Notes render raw HTML", files: ["src/notes.ts"], severity: "medium", evidence: ["src/notes.ts:4"], status: "resolved", date: "2026-09-01"}]}' >app/.forge/concerns.json
printf '# Todo\n\n- 2026-10-01 Rate-limit the intake form — concern: app:C-01\n- Add a CSV export\n' >app/.forge/todo.md
jq -n '{concerns: [
  {id: "C-10", area: "Logs hold emails", files: ["log.py"], severity: "medium", evidence: ["log.py:7"], status: "open", date: "2026-09-30"},
  {id: "C-11", area: "Logs rotate daily", files: ["log.py"], severity: "low", evidence: ["log.py:9"], status: "open"}]}' >web/.forge/concerns.json
printf -- '- 2026-10-10 Mask emails\n' >web/.forge/todo.md
jq -n '{concerns: [{id: "C-20", area: "Old", files: ["z"], severity: "low", evidence: ["z:1"], status: "resolved"}]}' >lib/.forge/concerns.json
printf '# Todo\n' >lib/.forge/todo.md
printf '# Seeds\n\n- 2026-09-20 App idea\n' >app/.forge/seeds.md
printf '# Seeds\n\n- 2026-10-11 Docs idea\n- Docs undated idea\n' >docs/.forge/seeds.md
printf '# Seeds\n' >lib/.forge/seeds.md
printf '# Seeds\n\n- Root idea\n' >.forge/seeds.md
jq '.requirements += [{id: "INT-03", text: "Rate-limit src/form.ts.", done: false}]' $sp/features/crm-intake/requirements.json >"$tmp/r" && mv "$tmp/r" $sp/features/crm-intake/requirements.json
intake "workspace"
want_intake "workspace rows: each child repo's todo.md, seeds.md and open concerns, the root's todo.md and seeds.md under its basename, Oldest from a dated seed (app), a dated concern (web) and a dated seed (docs), a seeds-only repo listed, empty repos skipped" \
  "| app  | 2     | 1     | 1        | 24     |" "| docs | 0     | 2     | 0        | 3      |" "| p    | 2     | 1     | 0        | —      |" "| web  | 1     | 0     | 2        | 14     |"
grep -qE '^\| app +\| [0-9]+ +\| 1 +\|' "$tmp/in" || fail "TDI-07: app's open concern on src/form.ts, named by crm/intake's requirement INT-03, counts in app's Intake row: $(cat "$tmp/in")"
chmod 000 app/.forge/seeds.md
s=0
FORGE_NOW="2026-10-14 06:00 UTC" TZ=UTC "$forge" status >"$tmp/st" 2>"$tmp/err" || s=$?
chmod 644 app/.forge/seeds.md
[ "$s" != 0 ] || fail "an unreadable seeds.md must fail forge status: $(cat "$tmp/st")"
grep -q '^forge: cannot read .*app/\.forge/seeds\.md: ' "$tmp/err" || fail "an unreadable seeds.md fails with a forge: cannot read message naming the file: $(cat "$tmp/err")"
rm .forge/todo.md app/.forge/todo.md web/.forge/todo.md .forge/seeds.md app/.forge/seeds.md docs/.forge/seeds.md
for r in app web; do jq '.concerns[].status = "resolved"' $r/.forge/concerns.json >"$tmp/c" && mv "$tmp/c" $r/.forge/concerns.json; done
intake "empty workspace"
[ ! -s "$tmp/in" ] || fail "the Intake section is left out when no workspace repo has an open todo or concern: $(cat "$tmp/st")"
"$forge" status --help | grep -q 'Intake' || fail "status --help documents the Intake section"
"$forge" status --help | grep -q 'Seeds' || fail "status --help documents the Intake Seeds column"
"$forge" status --help | sed -n '/^Reads:/,/^Writes:/p' | grep -q 'seeds\.md' || fail "status --help Reads lists each repo's .forge/seeds.md"
fresh
ok status-intake
fi

st() { "$forge" status >"$tmp/st" 2>"$tmp/err" || fail "status must exit 0: $(cat "$tmp/err")"; }
if want status-build-flag; then
fresh
fr=$sp/features/crm-routing
jq -n '{decisions: [], spec: [], build: true}' >$fr/spec.json
jq -n '{manual_test: [], result: "pass", gaps: []}' >$fr/verify.json
jq -n '{repos: [{repo: ".", workflow: "release.yml", window: {days: ["mon"], start: "09:00", end: "17:00", tz: "Nowhere/Unknown"}, live_sha: "echo x"}]}' >.forge/release.json
st
grep -qE '^\| crm +\| routing +\| ship +\|' "$tmp/st" || fail "a build: true feature with a passing verify shows Status ship: $(cat "$tmp/st")"
[ "$(grep '^## ' "$tmp/st")" = "$(printf '## %s\n' Tracks Features Intake Sessions)" ] ||
  fail "forge status prints no Builds, Prereqs or Release section, whatever build.json, procedure.json or release.json say: $(cat "$tmp/st")"
"$forge" status crm/routing >"$tmp/sf.out" 2>"$tmp/err" || fail "forge status crm/routing must exit 0: $(cat "$tmp/err")"
grep -qxF 'Status: ship' "$tmp/sf.out" && ! grep -q '^Build:' "$tmp/sf.out" ||
  fail "a build: true feature's view shows Status: ship and no Build line: $(cat "$tmp/sf.out")"
"$forge" status --json >"$tmp/sj.out" 2>"$tmp/err" || fail "forge status --json must exit 0: $(cat "$tmp/err")"
jq -e '.tracks[] | select(.track == "crm") | .features[] | select(.feature == "routing") | .status == "ship"' "$tmp/sj.out" >/dev/null ||
  fail "status --json shows a build: true feature with a passing verify as ship: $(cat "$tmp/sj.out")"
! "$forge" status --help | grep -qE 'Builds|Prereqs|Release|build' || fail "status --help names no build, Builds, Prereqs or Release: $("$forge" status --help | grep -E 'Builds|Prereqs|Release|build')"
fresh
ok status-build-flag
fi

repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}

conflict() {
  printf '1\n' >"$1/$3" && git -C "$1" add "$3" && git -C "$1" commit -q -m base
  git -C "$1" branch "$2"
  printf 'main\n' >"$1/$3" && git -C "$1" add "$3" && git -C "$1" commit -q -m main
  git -C "$1" checkout -q "$2"
  printf '%s\n' "$2" >"$1/$3" && git -C "$1" add "$3" && git -C "$1" commit -q -m "$2"
  git -C "$1" checkout -q main
}
st() { "$forge" status >"$tmp/st" 2>"$tmp/err" || fail "status must exit 0: $(cat "$tmp/err")"; }
if want status-conflicts; then
fresh
"$forge" status >"$tmp/base" 2>"$tmp/err" || fail "status must exit 0 outside a repo: $(cat "$tmp/err")"
rm -rf "$tmp/outer"
repo "$tmp/outer" && conflict "$tmp/outer" forge/o o
project "$tmp/outer/p"
(cd "$tmp/outer/p" && st)
echo "$tmp/p" >"$sp/root"
diff -u "$tmp/base" "$tmp/st" || fail "a root nested in another repo must not scan the outer repo"
repo .
st && diff -u "$tmp/base" "$tmp/st" || fail "a repo with no forge branch omits the section"
printf '1\n' >one.txt && printf '2\n' >two.txt && git add one.txt two.txt && git commit -q -m base
git branch forge/a && git branch forge/c
printf 'main\n' >one.txt && printf 'main\n' >two.txt && git add one.txt two.txt && git commit -q -m main
git checkout -q -b forge/b && printf 'b\n' >b.txt && git add b.txt && git commit -q -m b && git checkout -q main
st && diff -u "$tmp/base" "$tmp/st" || fail "no conflicting branch omits the section"
git checkout -q forge/a && printf 'a\n' >one.txt && printf 'a\n' >two.txt && git add one.txt two.txt && git commit -q -m a && git checkout -q main
st
{ head -n -4 "$tmp/base"; printf '\n## Conflicts\n\n%s\n' 'p forge/a: one.txt, two.txt'; tail -n 4 "$tmp/base"; } | diff -u - "$tmp/st" || fail "only forge/a conflicts, with its files"
repo web && conflict web forge/w w.txt
git -C web checkout -q --orphan forge/u && git -C web commit -q --allow-empty -m u && git -C web checkout -q main
git init -q -b trunk nomain && git -C nomain config user.name forge && git -C nomain config user.email forge@example.com
git -C nomain commit -q --allow-empty -m init && git -C nomain branch forge/x
rm -rf "$tmp/sib"
repo "$tmp/sib" && conflict "$tmp/sib" forge/s s.txt
echo '{"repos": ["../sib", "web"]}' >.forge/repos.json
st
{ head -n -4 "$tmp/base"; printf '\n## Conflicts\n\n'; printf '%s\n' 'p forge/a: one.txt, two.txt' 'web forge/u: merge-tree failed' 'web forge/w: w.txt' 'sib forge/s: s.txt'; tail -n 4 "$tmp/base"; } \
  | diff -u - "$tmp/st" || fail "child and repos.json repos list their conflicting branches, each repo once"
ok status-conflicts
fi

mkdir -p "$tmp/sbin"
cat >"$tmp/sbin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SESS_LOG"
[ "${1:-}" = agents ] || { echo "stub claude: unexpected call: $*" >&2; exit 64; }
[ -z "${SESS_FAIL:-}" ] || exit 1
cat "$SESS_AGENTS"
EOF
chmod +x "$tmp/sbin/claude"
export SESS_LOG=$tmp/sess.log SESS_AGENTS=$tmp/sess.json
sst() {
  local s=0
  PATH=$tmp/sbin:$PATH "$@" "$forge" status >"$tmp/st" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "status must exit 0 with the Sessions line: exits $s: $(cat "$tmp/err")"
  [ "$(grep -c '^## Sessions$' "$tmp/st")" = 1 ] || fail "status prints one Sessions section: $(cat "$tmp/st")"
}
sessions_line() { awk '/^## Sessions$/{print prev; print; getline; print; getline; print; exit} {prev = $0}' "$tmp/st"; }
want_line() { printf '\n## Sessions\n\n%s\n' "$1"; }
agent() { jq -nc --arg i "$1" --arg n "$2" --arg s "$3" --arg k "$4" --arg c "$5" '{id: $i, name: $n, state: $s, kind: $k, cwd: $c}'; }
if want status-sessions; then
fresh
git init -q -b main && git config user.name forge && git config user.email forge@example.com
git add -A && git commit -q -m init
rm -rf "$tmp/lk" && repo "$tmp/lk"
echo '{"repos": ["../lk"]}' >.forge/repos.json
echo '[]' >"$SESS_AGENTS"
rm -f "$SESS_LOG"
reaped=$(git rev-parse --path-format=absolute --git-common-dir)/forge-reaped.log
sst env FORGE_NOW="2026-09-20 12:00 UTC"
sessions_line | diff -u <(want_line "0 forge sessions removed in the last 24 h, 0 idle") - ||
  fail "no removal log counts 0 removed, an empty listing 0 idle, in a printf '\\n## Sessions\\n\\n' section: $(cat "$tmp/st")"
[ ! -e "$reaped" ] || fail "status must not create the removal log"
printf '%s\t%s\t%s\n' \
  2026-09-20T11:59:00Z a1 "p P11 crm/routing" \
  2026-09-19T12:30:00Z a2 "p verify crm/routing" \
  2026-09-19T11:00:00Z a3 "p P12 crm/routing" \
  2026-09-01T08:00:00Z a4 "p ship crm/audit" >"$reaped"
printf 'garbage line\nnot-a-time\ta5\tp P13 crm/audit\n\n2026-13-45T99:99:99Z\ta6\tp P14 crm/audit\n' >>"$reaped"
printf '%s\t%s\t%s\n' 2026-09-20T06:00:00Z a7 "p quick fix the typo" >>"$reaped"
cp "$reaped" "$tmp/reaped.before"
p=$PWD
{
  agent b1 "p P11 crm/routing" done background "$p/.claude/worktrees/crm-routing-11"
  agent b2 "p P12R1 crm/routing" done background "$p"
  agent b3 "p verify crm/routing" done background "$p"
  agent b4 "p ship crm/audit" done background "$p/.claude/worktrees/crm-audit"
  agent b5 "p quick fix the typo" done background "$tmp/lk"
  agent b6 "p debug login fails on save" done background "$tmp/lk/sub"
  agent b7 "p discuss voice/capture" done background "$p"
  agent b8 "p crm-intake Phase 3 retry 1" done background "$p"
  agent b9 "p crm-routing Verify" done background "$p"
  agent b10 "p crm-audit Ship" done background "$p"
  agent b11 "p/lk P5 crm/routing" done background "$tmp/lk/.claude/worktrees/crm-routing-5"
  agent b12 "p/lk verify crm/routing" done background "$tmp/lk"
  agent w1 "p P13 crm/audit" working background "$p" | jq -c '.status = "done"'
  agent w2 "p P14 crm/audit" blocked background "$p"
  agent i1 "p P15 crm/audit" done interactive "$p"
  agent o1 "q P11 crm/routing" done background "$tmp/q"
  agent o2 "p P11 crm/routing" done background "${p}2"
  agent o3 "p P11 crm/routing" done background "$tmp/elsewhere"
  agent n1 "p fix the readme" done background "$p"
  agent n2 "P11 crm/routing" done background "$p"
  agent n3 "pp P11 crm/routing" done background "$p"
  agent n4 "q/lk P5 crm/routing" done background "$tmp/lk"
  agent n5 "p/lk/x P5 crm/routing" done background "$tmp/lk"
  agent n6 "p/ P5 crm/routing" done background "$tmp/lk"
} | jq -s . >"$SESS_AGENTS"
sst env FORGE_NOW="2026-09-20 12:00 UTC"
sessions_line | diff -u <(want_line "3 forge sessions removed in the last 24 h, 12 idle") - ||
  fail "3 log lines fall in the 24 h before FORGE_NOW (malformed skipped) and 12 done background forge sessions of this project are idle, p/lk phase and verify names under the repos.json repo beside root-form ones: $(cat "$tmp/st") $(cat "$tmp/err")"
cmp -s "$reaped" "$tmp/reaped.before" || fail "status must not write the removal log"
[ "$(sort -u "$SESS_LOG")" = "agents --json --all" ] || fail "status only lists sessions with claude agents --json --all, never removes one: $(cat "$SESS_LOG")"
sst env FORGE_NOW="2026-09-20 12:00 UTC" SESS_FAIL=1
sessions_line | diff -u <(want_line "3 forge sessions removed in the last 24 h, idle unknown") - ||
  fail "a failing claude agents prints the removed count and idle unknown: $(cat "$tmp/st")"
[ -s "$tmp/err" ] || fail "a failing claude agents warns on stderr"
sst env FORGE_NOW="not a time"
sessions_line | diff -u <(want_line "unknown forge sessions removed in the last 24 h, 12 idle") - ||
  fail "an unreadable FORGE_NOW prints unknown removed and still the idle count: $(cat "$tmp/st") $(cat "$tmp/err")"
[ -s "$tmp/err" ] || fail "an unreadable FORGE_NOW warns on stderr"
printf '%s\t%s\t%s\n' "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" a8 "p P16 crm/audit" >>"$reaped"
sst env -u FORGE_NOW
sessions_line | diff -u <(want_line "1 forge sessions removed in the last 24 h, 12 idle") - ||
  fail "without FORGE_NOW only the line from an hour ago is in the last 24 h: $(cat "$tmp/st")"
rm -f "$SESS_LOG"
ok status-sessions
fi

pst() {
  local s=0
  "$forge" status >"$tmp/st" 2>"$tmp/err" || s=$?
  [ "$s" = 0 ] || fail "$1: status exits $s: $(cat "$tmp/err")"
}
ago() { date -u -d "$(sed -E 's/([0-9]+)/-\1/g' <<<"$1")" +%Y-%m-%dT%H:%M:%SZ; }
pline() { jq -nc --arg r "$1" --arg c "$2" --arg t "$3" '{repo: $r, commit: $c, time: $t}'; }
if want status-port; then
fresh
pending=$HOME/.local/state/forge/port.pending
rm -rf "$tmp/pr1" && repo "$tmp/pr1" && git -C "$tmp/pr1" config core.abbrev 12
c1=$(git -C "$tmp/pr1" rev-parse HEAD) s1=$(git -C "$tmp/pr1" rev-parse --short HEAD)
c2=0123456789abcdef0123456789abcdef01234567
[ ${#s1} = 12 ] || fail "core.abbrev 12 gives a 12-character short sha: $s1"
pst "no port.pending"
"$forge" status --json >"$tmp/base.json" 2>/dev/null
! grep -q 'forge port' "$tmp/st" || fail "no port.pending prints no warning: $(cat "$tmp/st")"
mkdir -p "${pending%/*}" && : >"$pending"
pst "an empty port.pending"
! grep -q 'forge port' "$tmp/st" || fail "an empty port.pending prints no warning: $(cat "$tmp/st")"
pline "$tmp/pr1" "$c1" "$(ago '59 minutes')" >"$pending"
pst "a 59 minute old line"
! grep -q 'forge port' "$tmp/st" || fail "a line 59 minutes old prints no warning: $(cat "$tmp/st")"
pline "$tmp/pr1" "$c1" "$(ago '65 minutes 30 seconds')" >"$pending"
pst "a 1h5m old line"
tail -n 3 "$tmp/st" | diff -u <(printf '%s\n' "$(sed -n '/^## Sessions$/{n;n;p}' "$tmp/st")" "" "warning: forge port $s1 queued 1h5m") - ||
  fail "a line 1 h 5 min old prints the warning with git's short sha after the Sessions section and a blank line: $(cat "$tmp/st") $(cat "$tmp/err")"
grep -q '^## Sessions$' "$tmp/st" || fail "the warning keeps the Sessions section: $(cat "$tmp/st")"
"$forge" status --json 2>/dev/null | diff -u "$tmp/base.json" - || fail "status --json is unchanged by a queued port"
{ pline "$tmp/pr1" "$c1" "$(ago '26 hours 30 seconds')"; pline "$tmp/gone" "$c2" "$(ago '2 hours 10 minutes 30 seconds')"; pline "$tmp/young" "$c2" "$(ago '10 minutes')"; } >"$pending"
pst "two old lines and a young one"
grep 'forge port' "$tmp/st" | diff -u <(printf '%s\n' "warning: forge port $s1 queued 26h0m" "warning: forge port ${c2:0:7} queued 2h10m") - ||
  fail "each old line prints its warning in file order, a repo git cannot read falls back to 7 characters, the young line prints none: $(cat "$tmp/st") $(cat "$tmp/err")"
printf 'not json\n' >"$pending"
pst "an unparseable port.pending"
grep -qxF "forge: warning: cannot read $pending" "$tmp/err" || fail "an unparseable port.pending warns on stderr: $(cat "$tmp/err")"
! grep -q 'forge port' "$tmp/st" || fail "an unparseable port.pending prints no warning line: $(cat "$tmp/st")"
pline "$tmp/pr1" "$c1" "yesterday" >"$pending"
pst "a line with a bad time"
grep -qxF "forge: warning: cannot read $pending" "$tmp/err" || fail "a line whose time cannot be parsed warns on stderr: $(cat "$tmp/err")"
pline "$tmp/pr1" "" "bad" >"$pending"
pst "a line with an empty commit and a bad time"
diff -u <(echo "forge: warning: cannot read $pending") "$tmp/err" || fail "an empty commit with a bad time warns cannot read and nothing else: $(cat "$tmp/err")"
"$forge" status --help | grep -q 'port.pending' || fail "status --help names port.pending"
rm -rf "$HOME/.local"
ok status-port
fi

if want status-unmet; then
fresh
pd=$sp/phases
jq '.unmet = [{task: "sync", reason: "merge conflict on core.txt"}]' "$fx/state/phases/02-intake-form/result.json" >$pd/02-intake-form/result.json
echo '{"id": "T3", "status": "unmet", "reason": "covered by result.json"}' >$pd/02-intake-form/tasks/T3.json
mkdir -p $pd/03-intake-api/tasks
echo '{"id": "T1", "status": "done", "commit": "abc1234"}' >$pd/03-intake-api/tasks/T1.json
echo '{"id": "T2", "status": "unmet", "reason": "no webhook sandbox"}' >$pd/03-intake-api/tasks/T2.json
sphase 16 voice routing voice-routing
mkdir -p $pd/16-voice-routing/tasks
echo '{"id": "T1", "status": "unmet", "reason": "other track"}' >$pd/16-voice-routing/tasks/T1.json
"$forge" validate $pd/02-intake-form/result.json $pd/03-intake-api/tasks/T2.json || fail "the unmet fixtures must validate"
s=$(code "$forge" status crm/intake)
[ "$s" = 0 ] || fail "forge status crm/intake exits 0: exits $s: $(cat "$tmp/out")"
head -n 1 "$tmp/out" | grep -qxF '# crm / intake' || fail "forge status crm/intake starts with the feature view: $(cat "$tmp/out")"
sed -n '/^## Unmet tasks$/,$p' "$tmp/out" | diff -u - <(cat <<'EOF'
## Unmet tasks
02-intake-form: unmet sync: merge conflict on core.txt
03-intake-api: unmet T2: no webhook sandbox
EOF
) || fail "forge status crm/intake ends with each phase's unmet tasks in number order, result.json's list over task records"
s=$(code "$forge" status crm/routing)
[ "$s" = 0 ] || fail "forge status crm/routing exits 0: exits $s: $(cat "$tmp/out")"
head -n 1 "$tmp/out" | grep -qxF '# crm / routing' || fail "forge status crm/routing prints the feature view: $(cat "$tmp/out")"
! grep -q '^## Unmet tasks$' "$tmp/out" || fail "a feature with no unmet tasks prints no Unmet tasks section: $(cat "$tmp/out")"
s=$(code "$forge" status crm/nope)
[ "$s" = 1 ] || fail "an unknown feature exits 1: exits $s: $(cat "$tmp/out")"
grep -qF crm/nope "$tmp/out" || fail "an unknown feature's error names it: $(cat "$tmp/out")"
"$forge" status --help | head -n 1 | grep -qF '<track>/<feature>' || fail "status --help usage shows the <track>/<feature> form"
"$forge" --help | grep -E '^  status ' | grep -qF '<track>/<feature>' || fail "forge --help's status line shows the <track>/<feature> form"
ok status-unmet
fi

if want state-dir; then
sd=$tmp/sd st=$XDG_STATE_HOME/forge
sr=$sd/sdproj S=$st/sdproj
rm -rf "$sd" "$st/sdproj" "$st/sdold" "$st/sdempty" "$st/sdmain" "$st/sdwt" "$st/sdchild" "$st/sdrace"
mkdir -p "$sr/.forge/tracks"
cd "$sr"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "forge paths with no argument exits 0: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
printf 'R=%s\nSTATE=%s\n' "$sr" "$S" | diff -u - "$tmp/sd.out" || fail "forge paths with no argument prints only R= and STATE=, the state dir absolute with no trailing slash"
[ -d "$S" ] || fail "forge paths creates the state dir $S"
[ -f "$S/root" ] && [ "$(cat "$S/root")" = "$sr" ] || fail "forge paths writes S/root holding the root's absolute path: $(cat "$S/root" 2>&1)"
mkdir -p "$S/phases/07-sd-core" "$S/features/sd-core"
jq -n '{track: "sd", feature: "core", number: "07", slug: "sd-core", goal: "Core", spec: [], requirements: [], depends: []}' >"$S/phases/07-sd-core/spec.json"
echo '{"phases": [{"number": "07", "slug": "sd-core", "goal": "Core", "spec": [], "requirements": [], "depends": []}]}' >"$S/features/sd-core/split.json"
s=0
(cd "$tmp" && FORGE_ROOT=$sr "$forge" paths 07) >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "forge paths 07 exits 0 for a phase under S: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
for l in "R=$sr" "F=$S/features/sd-core" "P=$S/phases/07-sd-core" "STATE=$S" "W=$sr/.claude/worktrees/sd-core-07" "B=forge/sd-core-07"; do
  grep -qxF "$l" "$tmp/sd.out" || fail "forge paths 07 prints $l: $(cat "$tmp/sd.out")"
done
s=0
"$forge" paths sd/core >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "forge paths sd/core exits 0 for a feature under S: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
for l in "R=$sr" "F=$S/features/sd-core" "STATE=$S" "W=$sr/.claude/worktrees/sd-core"; do
  grep -qxF "$l" "$tmp/sd.out" || fail "forge paths sd/core prints $l: $(cat "$tmp/sd.out")"
done
! grep -q '^P=' "$tmp/sd.out" || fail "forge paths sd/core prints no P: $(cat "$tmp/sd.out")"
[ "$(code "$forge" paths 99)" = 1 ] || fail "forge paths 99 exits 1 with no phase 99 under S: $(cat "$tmp/out")"
[ ! -e "$sr/.forge/phases" ] && [ ! -e "$sr/.forge/features" ] || fail "forge paths writes no record dir under R/.forge"

echo /elsewhere/sdproj >"$S/root"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" != 0 ] || fail "forge paths dies when S/root names another root: $(cat "$tmp/sd.out")"
grep -qF "$sr" "$tmp/sd.err" && grep -qF /elsewhere/sdproj "$tmp/sd.err" || fail "the root-file mismatch names both roots: $(cat "$tmp/sd.err")"
s=0
"$forge" status >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" != 0 ] && grep -qF /elsewhere/sdproj "$tmp/sd.err" || fail "forge status dies on the root-file mismatch: exits $s: $(cat "$tmp/sd.err")"
[ "$(cat "$S/root")" = /elsewhere/sdproj ] || fail "a root-file mismatch leaves S/root alone"
ln -s "$sd" "$tmp/sdlink"
echo "$tmp/sdlink/sdproj" >"$S/root"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "S/root naming the same root through a symlink is no mismatch: exits $s: $(cat "$tmp/sd.err")"
rm "$tmp/sdlink"
echo "$sr" >"$S/root"

rc=$sd/sdrace
mkdir -p "$rc/.forge/tracks" "$tmp/sdrbin"
printf '#!/usr/bin/env bash\n%q "$@" || exit\n[ -d "$SD_RACE_DIR" ] && [ ! -e "$SD_RACE_DIR/root" ] && echo /elsewhere/sdrace >"$SD_RACE_DIR/root"\nexit 0\n' "$(command -v mkdir)" >"$tmp/sdrbin/mkdir"
chmod +x "$tmp/sdrbin/mkdir"
s=0
(cd "$rc" && SD_RACE_DIR=$st/sdrace PATH=$tmp/sdrbin:$PATH "$forge" paths) >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" != 0 ] && grep -qF "$rc" "$tmp/sd.err" && grep -qF /elsewhere/sdrace "$tmp/sd.err" ||
  fail "a root that loses the S/root claim to another root dies naming both: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
[ "$(cat "$st/sdrace/root")" = /elsewhere/sdrace ] || fail "a lost S/root claim leaves the winner's S/root alone: $(cat "$st/sdrace/root")"
[ -z "$(find "$st/sdrace" -name 'root.*')" ] || fail "a lost S/root claim leaves no temp file: $(ls -a "$st/sdrace")"

old=$sd/sdold
for k in phases/01-x features/sd-x archive/sd-x; do
  rm -rf "$old" "$st/sdold"
  mkdir -p "$old/.forge/tracks" "$old/.forge/$k"
  echo '{}' >"$old/.forge/$k/spec.json"
  cd "$old"
  for c in status paths; do
    s=0
    "$forge" "$c" >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
    [ "$s" != 0 ] || fail "forge $c refuses a root whose .forge holds ${k%%/*}/: $(cat "$tmp/sd.out")"
    grep -qxF "forge: $old/.forge still holds planning records; move them to its state dir" "$tmp/sd.err" ||
      fail "forge $c on a root whose .forge holds ${k%%/*}/ names the state dir: $(cat "$tmp/sd.err")"
  done
  s=0
  (cd "$tmp" && FORGE_ROOT=$old "$forge" paths 01) >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
  [ "$s" != 0 ] && grep -qxF "forge: $old/.forge still holds planning records; move them to its state dir" "$tmp/sd.err" ||
    fail "forge paths 01 with FORGE_ROOT on an unmoved root refuses: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
done
rm -rf "$st/sdold"
s=0
"$forge" status --help >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] && head -n 1 "$tmp/sd.out" | grep -q '^Usage: forge status' || fail "--help is exempt from the refusal: exits $s: $(cat "$tmp/sd.err")"
echo '{}' >"$old/.forge/extra.json"
s=0
"$forge" validate .forge/extra.json >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "forge validate with file arguments is exempt from the refusal: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
[ ! -e "$st/sdold" ] || fail "--help and forge validate with file arguments never create the state dir"

emp=$sd/sdempty
mkdir -p "$emp/.forge/tracks" "$emp/.forge/phases" "$emp/.forge/features" "$emp/.forge/archive"
cd "$emp"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] && grep -qxF "STATE=$st/sdempty" "$tmp/sd.out" || fail "empty archive/, phases/ and features/ dirs are not refused: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"

m=$sd/sdmain w=$sd/sdwt
mkdir -p "$m/.forge/tracks"
echo '{}' >"$m/.forge/tracks/keep.json"
git -C "$m" init -q -b main
git -C "$m" add -A
git -C "$m" -c user.name=forge -c user.email=forge@example.com commit -q -m init
git -C "$m" worktree add -q -b sdwt "$w"
cd "$w"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "forge paths in a linked worktree exits 0: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
grep -qxF "STATE=$st/sdmain" "$tmp/sd.out" || fail "a linked worktree's state dir is its main checkout's: $(cat "$tmp/sd.out")"
[ "$(cat "$st/sdmain/root" 2>&1)" = "$m" ] || fail "a linked worktree's S/root holds the main checkout R: $(cat "$st/sdmain/root" 2>&1)"
[ ! -e "$st/sdwt" ] || fail "a linked worktree gets no state dir of its own basename"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] || fail "a linked worktree rerun matches S/root of its main checkout: exits $s: $(cat "$tmp/sd.err")"
c=$w/sdchild
mkdir -p "$c/.forge/tracks"
cd "$c"
s=0
"$forge" paths >"$tmp/sd.out" 2>"$tmp/sd.err" || s=$?
[ "$s" = 0 ] && grep -qxF "STATE=$st/sdchild" "$tmp/sd.out" || fail "a root below a worktree top keys S by its own basename: exits $s: $(cat "$tmp/sd.out" "$tmp/sd.err")"
[ "$(cat "$st/sdchild/root" 2>&1)" = "$c" ] || fail "a root below a worktree top writes its own S/root: $(cat "$st/sdchild/root" 2>&1)"
[ "$(cat "$st/sdmain/root")" = "$m" ] || fail "a root below a worktree top leaves the main checkout's S/root alone"
cd "$tmp"
ok state-dir
fi

if want state-readers; then
fresh
sp=$XDG_STATE_HOME/forge/p
s=0
"$forge" status crm/intake >"$tmp/sr.out" 2>"$tmp/sr.err" || s=$?
[ "$s" = 0 ] || fail "forge status crm/intake exits 0 with its records under S: exits $s: $(cat "$tmp/sr.err")"
diff -u "$fx/expected/status-feature.txt" "$tmp/sr.out" || fail "forge status crm/intake reads the feature and its phases from S"
s=0
"$forge" status crm/auth >"$tmp/sr.out" 2>"$tmp/sr.err" || s=$?
[ "$s" = 0 ] && grep -qxF 'Status: shipped' "$tmp/sr.out" && grep -qxF -- '- [x] AUTH-02 (agent): A session lasts 30 days. — concern: crm:C-02' "$tmp/sr.out" ||
  fail "a shipped feature's view reads S/archive/<track>-<feature>/: exits $s: $(cat "$tmp/sr.out" "$tmp/sr.err")"
mkdir -p "$sp/phases/03-intake-api/tasks"
echo '{"id": "T2", "status": "unmet", "reason": "no webhook sandbox"}' >"$sp/phases/03-intake-api/tasks/T2.json"
"$forge" status crm/intake >"$tmp/sr.out" 2>"$tmp/sr.err" || fail "forge status crm/intake with an unmet task exits 0: $(cat "$tmp/sr.err")"
sed -n '/^## Unmet tasks$/,$p' "$tmp/sr.out" | diff -u <(printf '%s\n' '## Unmet tasks' '03-intake-api: unmet T2: no webhook sandbox') - ||
  fail "the unmet tasks of S/phases/ print under their phase dir name"

fresh
"$forge" status >"$tmp/sr.out" 2>"$tmp/sr.err" || fail "forge status exits 0 with its records under S: $(cat "$tmp/sr.err")"
grep -qE '^\| crm +\| intake +\| discussed +\| 1/2 +\|' "$tmp/sr.out" || fail "forge status reads S/features and S/phases for the Features table: $(cat "$tmp/sr.out")"
jq -n '{quicks: [{slug: "s-quick", task: "S quick", repos: ["p"], date: "2026-09-12"}]}' >"$sp/quicks.json"
jq -n '{debugs: [{slug: "s-debug", symptom: "S symptom", cause: "S cause", repos: ["p"], date: "2026-09-13"}]}' >"$sp/debugs.json"
jq -n '{repos: [{repo: "s-repo", milestones: []}]}' >"$sp/history.json"
jq -n '{quicks: [{slug: "repo-quick", task: "Repo quick", repos: ["p"], date: "2026-09-12"}]}' >.forge/quicks.json
jq -n '{debugs: [{slug: "repo-debug", symptom: "Repo symptom", cause: "Repo cause", repos: ["p"], date: "2026-09-13"}]}' >.forge/debugs.json
jq -n '{repos: [{repo: "repo-repo", milestones: []}]}' >.forge/history.json
echo '{"time": "2026-09-25T09:00:00Z", "step": "note", "message": "S feature event"}' >"$sp/features/crm-intake/events.jsonl"
s=0
"$forge" status --json >"$tmp/sr.json" 2>"$tmp/sr.err" || s=$?
[ "$s" = 0 ] || fail "forge status --json exits 0 with its records under S: exits $s: $(cat "$tmp/sr.err")"
jq -c '{q: [.quicks[].slug], d: [.debugs[].slug], h: [.gsd_history[].repo]}' "$tmp/sr.json" | diff -u <(echo '{"q":["s-quick"],"d":["s-debug"],"h":["s-repo"]}') - ||
  fail "forge status --json reads quicks.json, debugs.json and history.json from S, not from R/.forge"
jq -c '.tracks[] | select(.track == "crm") | .features[] | select(.feature == "intake") | {status, phases, requirements: [.requirements[].id], last_activity}' "$tmp/sr.json" |
  diff -u <(echo '{"status":"discussed","phases":{"done":1,"total":2},"requirements":["INT-01","INT-02"],"last_activity":"2026-09-25T09:00:00Z"}') - ||
  fail "forge status --json reads the feature, its phases and S/features/*/events.jsonl from S"
jq -c '[.tracks[] | select(.track == "crm") | .shipped[] | select(.feature == "auth") | .requirements[].id]' "$tmp/sr.json" | diff -u <(echo '["AUTH-01","AUTH-02"]') - ||
  fail "forge status --json reads a shipped feature's requirements from S/archive/"

fresh
[ "$(code "$forge" validate)" = 0 ] || fail "the fixture under S validates with no arguments: $(cat "$tmp/out")"
jq '.tasks[0].files = []' "$sp/phases/02-intake-form/plan.json" >"$tmp/sr.plan" && mv "$tmp/sr.plan" "$sp/phases/02-intake-form/plan.json"
[ "$(code "$forge" validate)" = 1 ] && grep -q 'phases/02-intake-form/plan.json' "$tmp/out" ||
  fail "forge validate with no arguments checks the phase records under S: $(cat "$tmp/out")"
fresh
ps=$sp/phases/03-intake-api/spec.json
jq '.focus = ["budget"]' "$ps" >"$tmp/sr.spec" && mv "$tmp/sr.spec" "$ps"
[ "$(code "$forge" validate "$ps")" = 1 ] || fail "an S phase spec whose focus is outside its feature focus fails named: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = "$ps: focus budget not in the focus of $sp/features/crm-intake/spec.json" ] ||
  fail "links derives the root of an S path from S/root and reads the feature spec from S: $(cat "$tmp/out")"
[ "$(code "$forge" validate)" = 1 ] && grep -qF "phases/03-intake-api/spec.json: focus budget not in the focus of $sp/features/crm-intake/spec.json" "$tmp/out" ||
  fail "forge validate with no arguments runs the focus check on S phase specs: $(cat "$tmp/out")"
as=$sp/archive/crm-auth/phases/01-auth-login/spec.json
jq '.focus = ["pii"]' "$as" >"$tmp/sr.spec" && mv "$tmp/sr.spec" "$as"
[ "$(code "$forge" validate "$as")" = 1 ] && [ "$(cat "$tmp/out")" = "$as: focus pii has no feature spec at $sp/archive/crm-auth/spec.json" ] ||
  fail "an archived S phase spec looks up its feature spec under S/archive/: $(cat "$tmp/out")"
fresh
sl=$sp/features/crm-intake/split.json
jq '.phases[0].repo = "nosuch"' "$sl" >"$tmp/sr.split" && mv "$tmp/sr.split" "$sl"
[ "$(code "$forge" validate "$sl")" = 1 ] && [ "$(cat "$tmp/out")" = "$sl: repo nosuch is neither a git repo in $tmp/p nor a .forge/repos.json entry" ] ||
  fail "an S split.json resolves its phase repos against the root named in S/root: $(cat "$tmp/out")"
mkdir -p "$tmp/p/web/.git"
jq '.phases[0].repo = "web"' "$sl" >"$tmp/sr.split" && mv "$tmp/sr.split" "$sl"
[ "$(code "$forge" validate "$sl")" = 0 ] || fail "an S split.json naming a git repo under the S/root root validates: $(cat "$tmp/out")"

for c in status validate; do
  "$forge" "$c" --help | sed -n '/^Reads:/,/^$/p' >"$tmp/sr.reads"
  ! grep -qE '\.forge/[^ ]*(phases|features|archive|quicks|debugs|history)' "$tmp/sr.reads" ||
    fail "forge $c --help's Reads section names S records, not .forge/phases, .forge/features, .forge/archive or the run records: $(cat "$tmp/sr.reads")"
  grep -qF STATE/ "$tmp/sr.reads" || fail "forge $c --help's Reads section names its records under STATE/: $(cat "$tmp/sr.reads")"
done
fresh
ok state-readers
fi

finish
