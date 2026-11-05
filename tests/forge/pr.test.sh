#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

unset FORGEJO_URL FORGEJO_TOKEN FORGE_FORGEJO_ENV
stub_pr
pgit() { git -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false "$@"; }
prrepo=$tmp/pr/repo
git init -q -b main "$prrepo"
pgit -C "$prrepo" commit -q --allow-empty -m base
sha=$(git -C "$prrepo" rev-parse HEAD)
fsha=$(pgit -C "$prrepo" commit-tree -p "$sha" -m feature "$sha^{tree}")
git -C "$prrepo" update-ref refs/heads/forge/quick-x "$fsha"
git init -q --bare -b main "$tmp/pr/origin.git"
git -C "$prrepo" push -q "$tmp/pr/origin.git" main
mkdir -p "$tmp/pr/gitssh"
cat >"$tmp/pr/gitssh/ssh" <<'EOF'
#!/usr/bin/env bash
[[ ${!#} == "git-upload-pack '"* ]] || { echo "git ssh stub: refusing ${!#}" >&2; exit 255; }
exec git upload-pack "$SSH_GIT_REPO"
EOF
chmod +x "$tmp/pr/gitssh/ssh"
export GIT_SSH_COMMAND=$tmp/pr/gitssh/ssh SSH_GIT_REPO=$tmp/pr/origin.git GIT_ALLOW_PROTOCOL=file:ssh
cr() { jq -cn --arg n "$1" --arg s "$2" --arg c "$3" --arg t "$4" --arg w "${5:-CI}" '{__typename: "CheckRun", name: $n, workflowName: $w, status: $s, conclusion: $c, startedAt: $t, completedAt: "", detailsUrl: ("https://github.com/octo/forge/actions/" + $w + "/" + $n)}'; }
sc() { jq -cn --arg n "$1" --arg s "$2" '{__typename: "StatusContext", context: $n, state: $s, targetUrl: ("https://ci.example.test/" + $n), startedAt: "2026-09-30T10:00:00Z"}'; }
view() { jq -cn --arg h "$sha" '{headRefOid: $h, statusCheckRollup: ($ARGS.positional | map(fromjson))}' --args "$@"; }
green=$(view "$(cr build COMPLETED SUCCESS 2026-09-30T10:00:00Z)" "$(cr lint COMPLETED SKIPPED 2026-09-30T10:00:00Z)")
export GH_VIEW=$green FORGE_PR_CHECK_INTERVAL=0 FORGE_PR_CHECK_GRACE=0 FORGE_PR_CHECK_WAIT=0
git -C "$prrepo" remote add origin git@github.com:octo/forge.git
body=$tmp/pr/body.md
printf 'Fixes "the widget".\n\nSecond line' >"$body"
tok=s3cr3t-tok
printf 'FORGEJO_URL=https://forgejo.example.test\nFORGEJO_TOKEN=%s\n' "$tok" >"$tmp/pr/forge.env"
cp "$tmp/pr/forge.env" "$tmp/pr/home/.config/forgejo/forge.env"
printf 'FORGEJO_URL=https://forgejo.example.test\n' >"$tmp/pr/nokey.env"
printf 'FORGEJO_URL=http://forgejo.example.test\nFORGEJO_TOKEN=%s\n' "$tok" >"$tmp/pr/http.env"
qtok="$tok\$HOME \"x\" y"
printf '%s\n' "# Forgejo" "FORGEJO_URL='https://forgejo.example.test'" "FORGEJO_TOKEN=\"$qtok\"" "path=/evil" "touch $tmp/pr/PWNED" >"$tmp/pr/quoted.env"
chmod 600 "$tmp/pr"/*.env "$tmp/pr/home/.config/forgejo/forge.env"
export CURL_SECRET=$tok
origin() { git -C "$prrepo" remote set-url origin "$1"; }
prrun() {
  local s=0
  : >"$GH_LOG"; : >"$GH_VIEW_LOG"; : >"$CURL_LOG"; : >"$READY_LOG"
  (cd "${prdir:-$prrepo}" && PATH=$tmp/pr/bin:$PATH "$forge" pr "$@") >"$tmp/out" 2>"$tmp/err" || s=$?
  ! grep -qF "$tok" "$tmp/out" "$tmp/err" || fail "forge pr $* printed the token: $(cat "$tmp/out" "$tmp/err")"
  echo $s
}
ghargs() { [ "$(cat "$GH_LOG")" = "$(printf '%s\n' "$@" --)" ] || fail "gh args: want $* got $(cat "$GH_LOG")"; }
nocurl() { [ ! -s "$CURL_LOG" ] || fail "$1 must not call curl: $(cat "$CURL_LOG")"; }
nogh() { [ ! -s "$GH_LOG" ] && [ ! -s "$GH_VIEW_LOG" ] || fail "$1 must not call gh: $(cat "$GH_LOG" "$GH_VIEW_LOG")"; }
nomerge() { [ ! -s "$GH_LOG" ] || fail "$1 must not merge: $(cat "$GH_LOG")"; }
viewed() {
  grep -qxF "$2" "$GH_VIEW_LOG" || fail "$1 must read the PR with gh pr view $2: $(cat "$GH_VIEW_LOG")"
  grep -qxE 'statusCheckRollup,headRefOid|headRefOid,statusCheckRollup' "$GH_VIEW_LOG" || fail "$1 must ask gh pr view for --json statusCheckRollup,headRefOid: $(cat "$GH_VIEW_LOG")"
}
lines() { [ "$(sort "$tmp/out")" = "$(printf "$2" | sort)" ] || fail "$1 stdout: want $(printf "$2") got $(cat "$tmp/out")"; }
named() { local c; for c in "${@:2}"; do grep -qF -- "$c" "$tmp/err" || fail "$1 must name $c on stderr: $(cat "$tmp/err")"; done; }
onecall() {
  [ "$(wc -l <"$CURL_LOG")" = 1 ] || fail "$1 must call the Forgejo API once: $(cat "$CURL_LOG")"
  [ "$(jq -r .method "$CURL_LOG")" = "$2" ] || fail "$1 method: $(jq -r .method "$CURL_LOG")"
  [ "$(jq -r .url "$CURL_LOG")" = "$3" ] || fail "$1 url: $(jq -r .url "$CURL_LOG")"
  [ "$(jq -cS '.data | fromjson' "$CURL_LOG")" = "$(jq -cS . <<<"$4")" ] || fail "$1 payload: $(jq -r .data "$CURL_LOG")"
  jq -e --arg h "Authorization: token ${5:-$tok}" '.headers | index($h)' "$CURL_LOG" >/dev/null || fail "$1 must send the token header: $(jq -c .headers "$CURL_LOG")"
}
created=$(jq -cn --rawfile b "$body" '{head: "forge/quick-x", base: "main", title: "Add widget", body: $b}')
api=https://forgejo.example.test/api/v1/repos
export FORGE_FORGEJO_ENV=$tmp/pr/forge.env
fpull=$(jq -cn --arg h "$fsha" '{number: 7, state: "open", head: {ref: "forge/quick-x", sha: $h}}')
fmerged() {
  [ "$(jq -rs 'map(.method + " " + .url) | join(",")' "$CURL_LOG")" = "GET $api/op/widget/pulls/7,POST $api/op/widget/pulls/7/merge" ] ||
    fail "$1 must GET the pull for its head, then POST the merge: $(cat "$CURL_LOG")"
  jq -se --arg h "$2" '.[1].data | fromjson | .Do == "merge" and (.head_commit_id // $h) == $h' "$CURL_LOG" >/dev/null ||
    fail "$1 must POST {Do: merge} pinned to head $2 if at all: $(jq -rs '.[1].data' "$CURL_LOG")"
  jq -se --arg h "Authorization: token $tok" 'all(.headers | index($h))' "$CURL_LOG" >/dev/null || fail "$1 must send the token header on each call"
}

u=https://github.com/octo/forge/pull/12
t0=2026-09-30T09:00:00Z t1=2026-09-30T10:00:00Z
gh=https://github.com/octo/forge/actions
if want pr; then
s=$(prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "github create must exit 0, got $s: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = https://github.com/octo/forge/pull/12 ] || fail "github create prints only the PR URL on stdout: $(cat "$tmp/out")"
ghargs pr create --head forge/quick-x --base main --title "Add widget" --body-file "$body"
nocurl "github create"
s=$(prrun merge https://github.com/octo/forge/pull/12)
[ "$s" = 0 ] || fail "github merge must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge https://github.com/octo/forge/pull/12 --merge --match-head-commit "$sha"
viewed "github merge" https://github.com/octo/forge/pull/12
nocurl "github merge"
origin https://github.com/octo/forge.git
s=$(prrun close https://github.com/octo/forge/pull/12)
[ "$s" = 0 ] || fail "github close must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr close https://github.com/octo/forge/pull/12
nocurl "github close"
origin git@github.com-forge:octo/forge.git
s=$(prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "github ssh alias create must exit 0, got $s: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = https://github.com/octo/forge/pull/12 ] || fail "github ssh alias create prints only the PR URL: $(cat "$tmp/out")"
ghargs pr create --head forge/quick-x --base main --title "Add widget" --body-file "$body"
nocurl "github ssh alias create"
s=$(prrun merge https://github.com/octo/forge/pull/12)
[ "$s" = 0 ] || fail "github ssh alias merge must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge https://github.com/octo/forge/pull/12 --merge --match-head-commit "$sha"
nocurl "github ssh alias merge"

mixed=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr lint COMPLETED SKIPPED $t1)" "$(cr docs COMPLETED NEUTRAL $t1)" "$(sc deploy/preview SUCCESS)" \
  "$(cr unit COMPLETED FAILURE $t1)" "$(cr e2e COMPLETED CANCELLED $t1)" "$(cr slow COMPLETED TIMED_OUT $t1)" "$(cr gate COMPLETED ACTION_REQUIRED $t1)" \
  "$(cr boot COMPLETED STARTUP_FAILURE $t1)" "$(cr old COMPLETED STALE $t1)" "$(sc ci/legacy ERROR)" "$(sc ci/jenkins FAILURE)" \
  "$(cr queued QUEUED "" "")" "$(cr running IN_PROGRESS "" $t1)" "$(sc ci/waiting PENDING)" \
  "$(cr retry COMPLETED FAILURE $t0)" "$(cr retry COMPLETED SUCCESS $t1)" "$(cr rerun COMPLETED SUCCESS $t0)" "$(cr rerun QUEUED "" "")" \
  "$(cr matrix COMPLETED SUCCESS $t1 A)" "$(cr matrix COMPLETED FAILURE $t1 B)")
s=$(GH_VIEW=$mixed prrun checks "$u")
[ "$s" = 3 ] || fail "pr checks with a failed check must exit 3, got $s: $(cat "$tmp/err")"
lines "pr checks" "pass\tbuild\t$gh/CI/build\npass\tlint\t$gh/CI/lint\npass\tdocs\t$gh/CI/docs\npass\tdeploy/preview\thttps://ci.example.test/deploy/preview\nfail\tunit\t$gh/CI/unit\nfail\te2e\t$gh/CI/e2e\nfail\tslow\t$gh/CI/slow\nfail\tgate\t$gh/CI/gate\nfail\tboot\t$gh/CI/boot\nfail\told\t$gh/CI/old\nfail\tci/legacy\thttps://ci.example.test/ci/legacy\nfail\tci/jenkins\thttps://ci.example.test/ci/jenkins\npending\tqueued\t$gh/CI/queued\npending\trunning\t$gh/CI/running\npending\tci/waiting\thttps://ci.example.test/ci/waiting\npass\tretry\t$gh/CI/retry\npending\trerun\t$gh/CI/rerun\npass\tmatrix\t$gh/A/matrix\nfail\tmatrix\t$gh/B/matrix\n"
named "pr checks with failed checks" unit e2e slow gate boot old ci/legacy ci/jenkins
! grep -qF retry "$tmp/err" || fail "pr checks must not name a check whose newest run passed: $(cat "$tmp/err")"
viewed "pr checks" "$u"
nomerge "pr checks"
nocurl "pr checks"
s=$(GH_VIEW=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr queued QUEUED "" "")" "$(sc ci/waiting PENDING)") prrun checks "$u")
[ "$s" = 4 ] || fail "pr checks with pending checks past a zero wait must exit 4, got $s: $(cat "$tmp/err")"
lines "pr checks pending" "pass\tbuild\t$gh/CI/build\npending\tqueued\t$gh/CI/queued\npending\tci/waiting\thttps://ci.example.test/ci/waiting\n"
named "pr checks with pending checks" queued ci/waiting
s=$(prrun checks "$u")
[ "$s" = 0 ] || fail "pr checks with every check passed must exit 0, got $s: $(cat "$tmp/err")"
lines "pr checks green" "pass\tbuild\t$gh/CI/build\npass\tlint\t$gh/CI/lint\n"
s=$(GH_VIEW=$(view) prrun checks "$u")
[ "$s" = 0 ] || fail "pr checks with no checks must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "pr checks with no checks prints no lines: $(cat "$tmp/out")"
s=$(GH_VIEW_FAIL=1 prrun checks "$u")
[ "$s" = 1 ] || fail "pr checks must exit 1 when gh fails, got $s"
s=$(FORGE_PR_CHECK_GRACE=5 FORGE_PR_CHECK_WAIT=1 GH_VIEW=$(view) GH_VIEW2=$(view "$(cr unit COMPLETED FAILURE $t1)") prrun checks "$u")
[ "$s" = 3 ] || fail "pr checks must keep looking while no checks are reported within the grace, got $s: $(cat "$tmp/err")"
named "pr checks after the grace" unit
s=$(FORGE_PR_CHECK_GRACE=5 FORGE_PR_CHECK_WAIT=1 GH_VIEW=$(view "$(cr build COMPLETED SUCCESS $t1)") GH_VIEW2=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr unit COMPLETED FAILURE $t1 Test)") prrun checks "$u")
[ "$s" = 3 ] || fail "pr checks must keep looking for later checks within the grace once every reported check passed, got $s: $(cat "$tmp/err")"
named "pr checks with a later check" unit

s=$(GH_VIEW=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr unit COMPLETED FAILURE $t1)") prrun merge "$u")
[ "$s" = 3 ] || fail "github merge with a failed check must exit 3, got $s: $(cat "$tmp/err")"
named "github merge with a failed check" unit
nomerge "github merge with a failed check"
s=$(GH_VIEW=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr queued QUEUED "" "")") prrun merge "$u")
[ "$s" = 4 ] || fail "github merge with a pending check past a zero wait must exit 4, got $s: $(cat "$tmp/err")"
named "github merge with a pending check" queued
nomerge "github merge with a pending check"
s=$(GH_VIEW=$(view) prrun merge "$u")
[ "$s" = 0 ] || fail "github merge with no checks must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$sha"
s=$(GH_VIEW_FAIL=1 prrun merge "$u")
[ "$s" = 1 ] || fail "github merge must exit 1 when gh pr view fails, got $s"
nomerge "github merge when gh pr view fails"
s=$(FORGE_PR_CHECK_WAIT=1 GH_VIEW=$(view "$(cr build IN_PROGRESS "" $t1)") GH_VIEW2=$green prrun merge "$u")
[ "$s" = 0 ] || fail "github merge must wait for a running check to pass, got $s: $(cat "$tmp/err")"
[ "$(grep -cx -- -- "$GH_VIEW_LOG")" -ge 2 ] || fail "github merge must poll gh pr view until the checks finish: $(cat "$GH_VIEW_LOG")"
ghargs pr merge "$u" --merge --match-head-commit "$sha"
newhead() { jq -c --arg h fedcba9876543210fedcba9876543210fedcba98 '.headRefOid = $h' <<<"$1"; }
s=$(FORGE_PR_CHECK_GRACE=3 FORGE_PR_CHECK_INTERVAL=3 FORGE_PR_CHECK_WAIT=1 GH_VIEW=$(view "$(cr build IN_PROGRESS "" $t1)") GH_VIEW2=$(newhead "$(view)") GH_VIEW3=$(newhead "$(view "$(cr unit COMPLETED FAILURE $t1)")") prrun merge "$u")
[ "$s" = 3 ] || fail "github merge must give a new head its own no-checks grace, got $s: $(cat "$tmp/err")"
named "github merge after a new head" unit
nomerge "github merge after a new head"

mkdir -p "$prrepo/.forge" "$prrepo/sub"
top=$(cd "$prrepo" && pwd -P)
printf -- '- All tests: `true`.\n' >"$prrepo/.forge/TESTING.md"
s=$(prrun merge "$u")
[ "$s" = 0 ] || fail "github merge with a TESTING.md without a Merge ready line must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$sha"
printf -- '- All tests: `true`.\n- Merge ready: `%s {sha}`, run before a merge.\n' "$tmp/pr/ready" >"$prrepo/.forge/TESTING.md"
s=$(READY_EXIT=7 prrun merge "$u")
[ "$s" = 3 ] || fail "github merge with a failing Merge ready command must exit 3, got $s: $(cat "$tmp/err")"
nomerge "github merge with a failing Merge ready command"
named "a failing Merge ready command" "ready says: head $sha is not deployable"
[ "$(cat "$READY_LOG")" = "$sha"$'\n'"$top" ] || fail "the Merge ready command must get the head SHA and run from the checkout top: $(cat "$READY_LOG")"
s=$(prrun merge "$u")
[ "$s" = 0 ] || fail "github merge with a passing Merge ready command must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$sha"
[ "$(cat "$READY_LOG")" = "$sha"$'\n'"$top" ] || fail "a passing Merge ready command must get the head SHA and run from the checkout top: $(cat "$READY_LOG")"
s=$(prdir=$prrepo/sub prrun merge "$u")
[ "$s" = 0 ] || fail "github merge from a subdirectory with a passing Merge ready command must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$sha"
[ "$(cat "$READY_LOG")" = "$sha"$'\n'"$top" ] || fail "the Merge ready command must run from the checkout top, not a subdirectory: $(cat "$READY_LOG")"
s=$(GH_VIEW=$(view "$(cr unit COMPLETED FAILURE $t1)") prrun merge "$u")
[ "$s" = 3 ] || fail "github merge with a failed check and a Merge ready line must exit 3, got $s: $(cat "$tmp/err")"
[ ! -s "$READY_LOG" ] || fail "the Merge ready command must not run when a check failed: $(cat "$READY_LOG")"
nomerge "github merge with a failed check and a Merge ready line"
s=$(GH_VIEW=$(view "$(cr queued QUEUED "" "")") prrun merge "$u")
[ "$s" = 4 ] || fail "github merge with a pending check and a Merge ready line must exit 4, got $s: $(cat "$tmp/err")"
[ ! -s "$READY_LOG" ] || fail "the Merge ready command must not run while a check is pending: $(cat "$READY_LOG")"
nomerge "github merge with a pending check and a Merge ready line"
rm "$prrepo/.forge/TESTING.md"

origin ssh://git@forgejo.example.test:2222/op/widget.git
s=$(CURL_CODE=201 CURL_BODY='{"number": 7, "html_url": "https://forgejo.example.test/op/widget/pulls/7"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "forgejo ssh create must exit 0, got $s: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = https://forgejo.example.test/op/widget/pulls/7 ] || fail "forgejo create prints only html_url on stdout: $(cat "$tmp/out")"
onecall "forgejo ssh create" POST "$api/op/widget/pulls" "$created"
nogh "forgejo ssh create"

s=$(CURL_CODE=200 CURL_BODY=$fpull prrun merge https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 0 ] || fail "forgejo merge must exit 0, got $s: $(cat "$tmp/err")"
fmerged "forgejo merge" "$fsha"
nogh "forgejo merge"
[ "$(wc -l <"$tmp/err")" = 1 ] && grep -qF "forgejo.example.test is not GitHub" "$tmp/err" || fail "forgejo merge must say on one stderr line that it merges without waiting for checks: $(cat "$tmp/err")"
s=$(prrun checks https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 0 ] || fail "forgejo pr checks must exit 0, got $s: $(cat "$tmp/err")"
[ ! -s "$tmp/out" ] || fail "forgejo pr checks prints nothing on stdout: $(cat "$tmp/out")"
[ "$(wc -l <"$tmp/err")" = 1 ] && grep -qF "forgejo.example.test is not GitHub" "$tmp/err" || fail "forgejo pr checks must print the one-line not-GitHub note: $(cat "$tmp/err")"
nogh "forgejo pr checks"
nocurl "forgejo pr checks"
printf -- '- All tests: `true`.\n' >"$prrepo/.forge/TESTING.md"
s=$(CURL_CODE=200 CURL_BODY=$fpull prrun merge https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 0 ] || fail "forgejo merge with a TESTING.md without a Merge ready line must exit 0, got $s: $(cat "$tmp/err")"
fmerged "forgejo merge without a Merge ready line" "$fsha"
printf -- '- All tests: `true`.\n- Merge ready: `%s {sha}`, run before a merge.\n' "$tmp/pr/ready" >"$prrepo/.forge/TESTING.md"
s=$(CURL_CODE=200 CURL_BODY=$fpull prrun merge https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 0 ] || fail "forgejo merge with a passing Merge ready command must exit 0, got $s: $(cat "$tmp/err")"
[ "$(wc -l <"$CURL_LOG")" = 2 ] || fail "forgejo merge with a Merge ready line must GET the pull then POST the merge: $(cat "$CURL_LOG")"
[ "$(jq -rs '.[0].method + " " + .[0].url' "$CURL_LOG")" = "GET $api/op/widget/pulls/7" ] || fail "forgejo merge with a Merge ready line must first GET the pull: $(cat "$CURL_LOG")"
[ "$(jq -rs '.[1].method + " " + .[1].url' "$CURL_LOG")" = "POST $api/op/widget/pulls/7/merge" ] || fail "forgejo merge with a Merge ready line must then POST the merge: $(cat "$CURL_LOG")"
[ "$(jq -cSs '.[1].data | fromjson' "$CURL_LOG")" = "$(jq -cSn --arg h "$fsha" '{Do: "merge", head_commit_id: $h}')" ] || fail "forgejo merge with a Merge ready line must send head_commit_id: $(jq -rs '.[1].data' "$CURL_LOG")"
jq -se --arg h "Authorization: token $tok" 'all(.headers | index($h))' "$CURL_LOG" >/dev/null || fail "forgejo merge with a Merge ready line must send the token header on each call"
[ "$(cat "$READY_LOG")" = "$fsha"$'\n'"$top" ] || fail "forgejo Merge ready must get the pull's head SHA and run from the checkout top: $(cat "$READY_LOG")"
nogh "forgejo merge with a Merge ready line"
s=$(READY_EXIT=7 CURL_CODE=200 CURL_BODY=$fpull prrun merge https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 3 ] || fail "forgejo merge with a failing Merge ready command must exit 3, got $s: $(cat "$tmp/err")"
named "a failing forgejo Merge ready command" "ready says: head $fsha is not deployable"
[ "$(jq -rs 'map(.method) | join(" ")' "$CURL_LOG")" = GET ] || fail "forgejo merge with a failing Merge ready command must not POST the merge: $(cat "$CURL_LOG")"
[ "$(cat "$READY_LOG")" = "$fsha"$'\n'"$top" ] || fail "a failing forgejo Merge ready command must get the pull's head SHA: $(cat "$READY_LOG")"
rm "$prrepo/.forge/TESTING.md"
s=$(CURL_CODE=201 CURL_BODY='{"number": 7, "state": "closed"}' prrun close https://forgejo.example.test/op/widget/pulls/7)
[ "$s" = 0 ] || fail "forgejo close must exit 0, got $s: $(cat "$tmp/err")"
onecall "forgejo close" PATCH "$api/op/widget/pulls/7" '{"state": "closed"}'
nogh "forgejo close"
for sub in merge close; do
  s=$(prrun "$sub" https://forgejo.example.test/op/other/pulls/7)
  [ "$s" = 1 ] || fail "forgejo $sub of another repo's PR must exit 1, got $s"
  grep -qF "op/other" "$tmp/err" || fail "forgejo $sub of another repo's PR must name it on stderr: $(cat "$tmp/err")"
  nocurl "forgejo $sub of another repo's PR"
  s=$(prrun "$sub" https://elsewhere.example.test/op/widget/pulls/7)
  [ "$s" = 1 ] || fail "forgejo $sub of a PR on another host must exit 1, got $s"
  grep -qF "elsewhere.example.test" "$tmp/err" || fail "forgejo $sub of a PR on another host must name it on stderr: $(cat "$tmp/err")"
  nocurl "forgejo $sub of a PR on another host"
  s=$(prrun "$sub" https://forgejo.example.test/op/widget/issues/7)
  [ "$s" = 1 ] || fail "forgejo $sub of a non-PR URL must exit 1, got $s"
  nocurl "forgejo $sub of a non-PR URL"
done

origin git@forgejo.example.test:op/gadget.git
s=$(unset FORGE_FORGEJO_ENV; HOME=$tmp/pr/home CURL_CODE=201 CURL_BODY='{"number": 3, "html_url": "https://forgejo.example.test/op/gadget/pulls/3"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "forgejo scp-style create with the default env file must exit 0, got $s: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = https://forgejo.example.test/op/gadget/pulls/3 ] || fail "forgejo scp-style create prints html_url: $(cat "$tmp/out")"
onecall "forgejo scp-style create" POST "$api/op/gadget/pulls" "$created"

origin https://forgejo.example.test/op/gizmo.git
s=$(CURL_CODE=201 CURL_BODY='{"number": 4, "html_url": "https://forgejo.example.test/op/gizmo/pulls/4"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "forgejo https create must exit 0, got $s: $(cat "$tmp/err")"
onecall "forgejo https create" POST "$api/op/gizmo/pulls" "$created"

origin https://gitlab.com/op/widget.git
s=$(CURL_CODE=201 CURL_BODY='{"number": 7, "html_url": "https://gitlab.com/op/widget/pulls/7"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 1 ] || fail "a create on a non-Forgejo host must exit 1, got $s"
[ ! -s "$tmp/out" ] || fail "a create on a non-Forgejo host prints nothing on stdout: $(cat "$tmp/out")"
grep -qF gitlab.com "$tmp/err" || fail "a create on a non-Forgejo host must name it on stderr: $(cat "$tmp/err")"
nocurl "a create on a non-Forgejo host"
for o in https://op:hunter2@forgejo.example.test/widget https://op:hunter2@; do
  origin "$o"
  s=$(prrun create forge/quick-x "Add widget" "$body")
  [ "$s" = 1 ] || fail "an unreadable origin $o must exit 1, got $s"
  [ -s "$tmp/err" ] || fail "an unreadable origin $o must print an error on stderr"
  ! grep -qF hunter2 "$tmp/err" || fail "an unreadable origin's error must not print its userinfo: $(cat "$tmp/err")"
  nocurl "an unreadable origin $o"
done

origin ssh://git@forgejo.example.test:2222/op/widget.git
for b in '{"number": 7}' '{"number": 7, "html_url": ""}'; do
  s=$(CURL_CODE=201 CURL_BODY=$b prrun create forge/quick-x "Add widget" "$body")
  [ "$s" = 1 ] || fail "a 2xx create with $b must exit 1, got $s"
  [ ! -s "$tmp/out" ] || fail "a 2xx create with $b prints nothing on stdout: $(cat "$tmp/out")"
  [ -s "$tmp/err" ] || fail "a 2xx create with $b must print an error on stderr"
done
s=$(FORGE_FORGEJO_ENV=$tmp/pr/http.env prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 1 ] || fail "a FORGEJO_URL that is not https must exit 1, got $s"
grep -qF https "$tmp/err" || fail "a FORGEJO_URL that is not https must say so: $(cat "$tmp/err")"
nocurl "a FORGEJO_URL that is not https"
s=$(FORGE_FORGEJO_ENV=$tmp/pr/quoted.env CURL_CODE=201 CURL_BODY='{"number": 7, "html_url": "https://forgejo.example.test/op/widget/pulls/7"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "a quoted env file must exit 0, got $s: $(cat "$tmp/err")"
onecall "a quoted env file" POST "$api/op/widget/pulls" "$created" "$qtok"
[ ! -e "$tmp/pr/PWNED" ] || fail "the env file must not run as shell"
for m in 640 604; do
  chmod "$m" "$tmp/pr/forge.env"
  s=$(prrun create forge/quick-x "Add widget" "$body")
  [ "$s" = 1 ] || fail "an env file with mode $m must exit 1, got $s"
  grep -qF "group- or other-readable" "$tmp/err" || fail "an env file with mode $m must say why: $(cat "$tmp/err")"
  nocurl "an env file with mode $m"
done
chmod 600 "$tmp/pr/forge.env"
s=$(FORGE_FORGEJO_ENV=$tmp/pr/none.env prrun create forge/quick-x "Add widget" "$body")
[ "$s" != 0 ] || fail "a missing env file must exit nonzero"
[ ! -s "$tmp/out" ] || fail "a missing env file prints nothing on stdout: $(cat "$tmp/out")"
[ -s "$tmp/err" ] || fail "a missing env file must print an error on stderr"
nocurl "a missing env file"
s=$(FORGE_FORGEJO_ENV=$tmp/pr/nokey.env prrun create forge/quick-x "Add widget" "$body")
[ "$s" != 0 ] || fail "an env file without FORGEJO_TOKEN must exit nonzero"
[ ! -s "$tmp/out" ] || fail "a missing key prints nothing on stdout: $(cat "$tmp/out")"
[ -s "$tmp/err" ] || fail "a missing key must print an error on stderr"
nocurl "a missing key"

s=$(CURL_CODE=409 CURL_BODY='{"message": "pull request already exists for these targets", "url": "https://forgejo.example.test/api/swagger"}' prrun create forge/quick-x "Add widget" "$body")
[ "$s" != 0 ] || fail "a non-2xx create must exit nonzero"
[ ! -s "$tmp/out" ] || fail "a failed create prints nothing on stdout: $(cat "$tmp/out")"
grep -qF "pull request already exists for these targets" "$tmp/err" || fail "a failed create prints Forgejo's message on stderr: $(cat "$tmp/err")"
grep -qF 409 "$tmp/err" || fail "a failed create prints the HTTP code on stderr: $(cat "$tmp/err")"
s=$(CURL_GETS="200 $fpull" CURL_POSTS='409 {"message": "merge conflict between head and base"}' prrun merge https://forgejo.example.test/op/widget/pulls/7)
[ "$s" != 0 ] || fail "a non-2xx merge must exit nonzero"
grep -qF "merge conflict between head and base" "$tmp/err" || fail "a failed merge prints Forgejo's message on stderr: $(cat "$tmp/err")"
grep -qF 409 "$tmp/err" || fail "a failed merge prints the HTTP code on stderr: $(cat "$tmp/err")"
fmerged "a 409 merge" "$fsha"

[ "$(prrun)" = 2 ] || fail "forge pr without a subcommand must exit 2"
[ "$(prrun bogus x)" = 2 ] || fail "an unknown pr subcommand must exit 2"
[ "$(prrun create forge/quick-x "Add widget")" = 2 ] || fail "pr create without a body file must exit 2"
[ "$(prrun merge)" = 2 ] || fail "pr merge without a url must exit 2"
[ "$(prrun checks)" = 2 ] || fail "pr checks without a url must exit 2"
[ "$(prrun checks https://github.com/octo/forge/pull/12 x)" = 2 ] || fail "pr checks with two arguments must exit 2"
unset FORGE_FORGEJO_ENV GH_VIEW FORGE_PR_CHECK_INTERVAL FORGE_PR_CHECK_GRACE FORGE_PR_CHECK_WAIT
ok pr
fi

if want pr-labels; then
origin git@github.com:octo/forge.git
mkdir -p "$prrepo/.forge" "$prrepo/sub"
top=$(cd "$prrepo" && pwd -P)
export LABELS_LOG=$tmp/pr/labels.log
cat >"$tmp/pr/labels" <<'EOF'
#!/usr/bin/env bash
{ pwd -P; printf 'stdin[%s]\n' "$(cat)"; } >>"$LABELS_LOG"
if [ -n "${LABELS_EXIT:-}" ]; then
  echo "labels says: no diff base" >&2
  exit "$LABELS_EXIT"
fi
printf 'preview\n\nx\n'
EOF
chmod +x "$tmp/pr/labels"
lrun() { : >"$LABELS_LOG"; prrun "$@" <<<leaked-stdin; }
glabels() { awk 'p { print; p = 0; next } $0 == "--label" { p = 1 }' "$GH_LOG"; }
grest() { awk 'p { p = 0; next } $0 == "--label" { p = 1; next } 1' "$GH_LOG"; }
base=$(printf '%s\n' pr create --head forge/quick-x --base main --title "Add widget" --body-file "$body" --)
printf -- '- All tests: `true`.\n' >"$prrepo/.forge/TESTING.md"
s=$(lrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "github create without a PR labels line must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr create --head forge/quick-x --base main --title "Add widget" --body-file "$body"
[ ! -s "$LABELS_LOG" ] || fail "github create without a PR labels line must run no labels command: $(cat "$LABELS_LOG")"
printf -- '- All tests: `true`.\n- PR labels: `%s` prints the labels.\n' "$tmp/pr/labels" >"$prrepo/.forge/TESTING.md"
for d in "$prrepo" "$prrepo/sub"; do
  s=$(prdir=$d lrun create forge/quick-x "Add widget" "$body")
  [ "$s" = 0 ] || fail "github create with a PR labels line from $d must exit 0, got $s: $(cat "$tmp/err")"
  [ "$(cat "$tmp/out")" = https://github.com/octo/forge/pull/12 ] || fail "github create with a PR labels line from $d prints only the PR URL on stdout: $(cat "$tmp/out")"
  [ "$(glabels)" = $'preview\nx' ] || fail "github create from $d must pass --label preview --label x, one per non-empty printed line: $(cat "$GH_LOG")"
  [ "$(grest)" = "$base" ] || fail "github create from $d must keep the create arguments besides the labels: $(cat "$GH_LOG")"
  [ "$(cat "$LABELS_LOG")" = "$top"$'\nstdin[]' ] || fail "the PR labels command must run once from the checkout top with stdin /dev/null when invoked from $d: $(cat "$LABELS_LOG")"
  nocurl "github create with a PR labels line"
done
s=$(LABELS_EXIT=7 lrun create forge/quick-x "Add widget" "$body")
[ "$s" = 1 ] || fail "github create with a failing PR labels command must exit 1, got $s: $(cat "$tmp/err")"
named "a failing PR labels command" "labels says: no diff base" "PR labels"
nogh "github create with a failing PR labels command"
nocurl "github create with a failing PR labels command"
[ ! -s "$tmp/out" ] || fail "github create with a failing PR labels command prints nothing on stdout: $(cat "$tmp/out")"
origin ssh://git@forgejo.example.test:2222/op/widget.git
s=$(FORGE_FORGEJO_ENV=$tmp/pr/forge.env CURL_CODE=201 CURL_BODY='{"number": 7, "html_url": "https://forgejo.example.test/op/widget/pulls/7"}' lrun create forge/quick-x "Add widget" "$body")
[ "$s" = 0 ] || fail "forgejo create with a PR labels line must exit 0, got $s: $(cat "$tmp/err")"
[ "$(cat "$tmp/out")" = https://forgejo.example.test/op/widget/pulls/7 ] || fail "forgejo create with a PR labels line prints only html_url on stdout: $(cat "$tmp/out")"
[ "$(cat "$tmp/err")" = "forge: warning: forgejo.example.test is not GitHub; PR labels not applied" ] || fail "forgejo create with a PR labels line must print the one not-GitHub labels warning on stderr: $(cat "$tmp/err")"
[ ! -s "$LABELS_LOG" ] || fail "forgejo create must not run the PR labels command: $(cat "$LABELS_LOG")"
onecall "forgejo create with a PR labels line" POST "$api/op/widget/pulls" "$created"
nogh "forgejo create with a PR labels line"
rm "$prrepo/.forge/TESTING.md"
origin git@github.com:octo/forge.git
unset LABELS_LOG
ok pr-labels
fi

if want pr-push; then
pu=$tmp/pr/push
mkdir -p "$pu"
printf '[user]\n\tname = Forge Test\n\temail = forge@example.test\n[push]\n\tdefault = simple\n' >"$pu/gitconfig"
export GIT_CONFIG_GLOBAL=$pu/gitconfig GIT_CONFIG_NOSYSTEM=1
git init -q --bare -b main "$pu/origin.git"
git init -q -b main "$pu/repo"
git -C "$pu/repo" remote add origin "$pu/origin.git"
mkdir -p "$pu/repo/.forge" "$pu/repo/sub"
ptop=$(cd "$pu/repo" && pwd -P)
pcommit() { echo "$1" >"$pu/repo/sub/f"; git -C "$pu/repo" add sub/f; git -C "$pu/repo" commit -qm "$1"; git -C "$pu/repo" rev-parse HEAD; }
pref() { git -C "$pu/origin.git" rev-parse --verify -q "refs/heads/$1" || echo none; }
pcommit base >/dev/null
git -C "$pu/repo" push -q origin main
git -C "$pu/repo" checkout -q -b forge/quick-x
export PREPUSH_LOG=$pu/prepush.log PREPUSH_ORIGIN=$pu/origin.git
cat >"$pu/prepush" <<'EOF'
#!/usr/bin/env bash
{ pwd -P; printf 'stdin[%s]\n' "$(cat)"; printf 'origin[%s]\n' "$(git -C "$PREPUSH_ORIGIN" rev-parse --verify -q refs/heads/forge/quick-x || echo none)"; } >>"$PREPUSH_LOG"
echo "prepush says: checking"
if [ -n "${PREPUSH_EXIT:-}" ]; then echo "prepush warns: lint failed" >&2; else echo "prepush warns: all clear" >&2; fi
exit "${PREPUSH_EXIT:-0}"
EOF
chmod +x "$pu/prepush"
pprun() { : >"$PREPUSH_LOG"; prrun "$@" <<<leaked-stdin; }
both() { cat "$tmp/out" "$tmp/err"; }

printf -- '- All tests: `true`.\n' >"$pu/repo/.forge/TESTING.md"
c1=$(pcommit one)
s=$(prdir=$pu/repo pprun push -u origin forge/quick-x)
[ "$s" = 0 ] || fail "forge pr push -u origin forge/quick-x without a Pre-push line must exit 0, got $s: $(both)"
[ "$(pref forge/quick-x)" = "$c1" ] || fail "forge pr push without a Pre-push line must push forge/quick-x to origin: origin has $(pref forge/quick-x), want $c1"
[ "$(git -C "$pu/repo" rev-parse --abbrev-ref 'forge/quick-x@{upstream}' 2>&1)" = origin/forge/quick-x ] ||
  fail "forge pr push -u origin forge/quick-x must pass -u to git push and set the upstream: $(git -C "$pu/repo" rev-parse --abbrev-ref 'forge/quick-x@{upstream}' 2>&1)"
[ ! -s "$PREPUSH_LOG" ] || fail "forge pr push without a Pre-push line must run no Pre-push command: $(cat "$PREPUSH_LOG")"
nogh "forge pr push"
nocurl "forge pr push"

printf -- '- All tests: `true`.\n- Pre-push: `%s` runs the static checks.\n' "$pu/prepush" >"$pu/repo/.forge/TESTING.md"
c2=$(pcommit two)
s=$(prdir=$pu/repo/sub pprun push)
[ "$s" = 0 ] || fail "forge pr push with a passing Pre-push line must exit 0, got $s: $(both)"
[ "$(cat "$PREPUSH_LOG")" = "$ptop"$'\nstdin[]\n'"origin[$c1]" ] ||
  fail "the Pre-push command must run once from the checkout top with stdin /dev/null before the push when invoked from $pu/repo/sub: $(cat "$PREPUSH_LOG")"
both | grep -qxF "prepush says: checking" || fail "forge pr push must pass the Pre-push command's stdout through: $(both)"
grep -qxF "prepush warns: all clear" "$tmp/err" || fail "forge pr push must pass the Pre-push command's stderr through: $(both)"
[ "$(pref forge/quick-x)" = "$c2" ] || fail "forge pr push with a passing Pre-push line must then push: origin has $(pref forge/quick-x), want $c2"
nogh "forge pr push with a Pre-push line"
nocurl "forge pr push with a Pre-push line"

c3=$(pcommit three)
s=$(PREPUSH_EXIT=7 prdir=$pu/repo/sub pprun push origin forge/quick-x)
[ "$s" = 3 ] || fail "forge pr push with a failing Pre-push command must exit 3, got $s: $(both)"
grep -qxF "forge: Pre-push failed (exit 7); nothing pushed" "$tmp/err" || fail "forge pr push with a failing Pre-push command must print 'forge: Pre-push failed (exit 7); nothing pushed' on stderr: $(both)"
both | grep -qxF "prepush says: checking" || fail "forge pr push with a failing Pre-push command must pass its stdout through: $(both)"
grep -qxF "prepush warns: lint failed" "$tmp/err" || fail "forge pr push with a failing Pre-push command must pass its stderr through: $(both)"
[ "$(pref forge/quick-x)" = "$c2" ] || fail "forge pr push with a failing Pre-push command must push nothing: origin has $(pref forge/quick-x), want $c2 (local $c3)"
[ "$(wc -l <"$PREPUSH_LOG")" = 3 ] || fail "forge pr push must run the failing Pre-push command once: $(cat "$PREPUSH_LOG")"

s=$(prdir=$pu/repo pprun push nowhere forge/quick-x)
[ "$s" = 1 ] || fail "forge pr push must exit 1 when git push fails, got $s: $(both)"
[ "$(pref forge/quick-x)" = "$c2" ] || fail "a failed git push must leave origin at $c2: $(pref forge/quick-x)"
named "forge pr push when git push fails" nowhere

"$forge" pr --help | grep -qF "forge pr push" || fail "forge pr --help must document forge pr push"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM PREPUSH_LOG PREPUSH_ORIGIN
ok pr-push
fi

if want pr-perf; then
origin git@github.com:octo/forge.git
export GH_VIEW=$green FORGE_PR_CHECK_INTERVAL=0 FORGE_PR_CHECK_GRACE=0 FORGE_PR_CHECK_WAIT=0
s=$(GH_VIEW=$(view "$(cr build COMPLETED SUCCESS $t1)" "$(cr pr COMPLETED FAILURE $t1 perf)") prrun checks "$u")
[ "$s" = 3 ] || fail "pr checks with a failing perf workflow check must exit 3, got $s: $(cat "$tmp/err")"
lines "pr checks with a failing perf workflow check" "pass\tbuild\t$gh/CI/build\nfail\tpr\t$gh/perf/pr\n"
named "pr checks with a failing perf workflow check" "check failed: pr"
! grep -q 'advisory' "$tmp/err" || fail "pr checks must print no perf advisory line: $(cat "$tmp/err")"
unset GH_VIEW FORGE_PR_CHECK_INTERVAL FORGE_PR_CHECK_GRACE FORGE_PR_CHECK_WAIT
ok pr-perf
fi

oneline() {
  [ "$(wc -l <"$tmp/out")" = 1 ] && [ "$(cat "$tmp/out")" = "$2" ] || fail "$1 must print exactly the line '$2' on stdout, got: $(cat "$tmp/out")"
}
ghstate() { jq -cn --arg s "$1" --arg m "$2" --arg ms "$3" '{state: $s, mergeable: $m, mergeStateStatus: $ms}'; }
fu=https://forgejo.example.test/op/widget/pulls/7
fget() {
  [ "$(wc -l <"$CURL_LOG")" = 1 ] || fail "$1 must call the Forgejo API once: $(cat "$CURL_LOG")"
  [ "$(jq -r '.method + " " + .url' "$CURL_LOG")" = "GET $api/op/widget/pulls/7" ] || fail "$1 must GET the pull: $(cat "$CURL_LOG")"
  jq -e --arg h "Authorization: token $tok" '.headers | index($h)' "$CURL_LOG" >/dev/null || fail "$1 must send the token header: $(jq -c .headers "$CURL_LOG")"
  nogh "$1"
}
fpr() { jq -cn --arg s "$1" --argjson g "$2" --argjson m "$3" --arg h "$fsha" '{number: 7, state: $s, merged: $g, mergeable: $m, head: {ref: "forge/quick-x", sha: $h}}'; }
if want pr-state; then
stateview() {
  grep -qxF "$2" "$GH_VIEW_LOG" || fail "$1 must read the PR with gh pr view $2: $(cat "$GH_VIEW_LOG")"
  grep -qxF -- --json "$GH_VIEW_LOG" || fail "$1 must ask gh pr view for --json: $(cat "$GH_VIEW_LOG")"
  [ "$(grep -A1 -xF -- --json "$GH_VIEW_LOG" | tail -1 | tr , '\n' | sort | paste -sd,)" = mergeStateStatus,mergeable,state ] || fail "$1 must ask gh pr view for --json state,mergeable,mergeStateStatus: $(cat "$GH_VIEW_LOG")"
}
origin https://github.com/octo/forge.git
for st in OPEN MERGED CLOSED; do
  s=$(GH_VIEW=$(ghstate "$st" MERGEABLE CLEAN) prrun state "$u")
  [ "$s" = 0 ] || fail "github pr state of a $st PR must exit 0, got $s: $(cat "$tmp/err")"
  oneline "github pr state of a $st PR" "$st CLEAN"
  stateview "github pr state of a $st PR" "$u"
  nomerge "github pr state"
  nocurl "github pr state"
done
for ms in DIRTY BEHIND BLOCKED CLEAN HAS_HOOKS UNSTABLE UNKNOWN DRAFT; do
  m=MERGEABLE
  [ "$ms" != DIRTY ] || m=CONFLICTING
  s=$(GH_VIEW=$(ghstate OPEN "$m" "$ms") prrun state "$u")
  [ "$s" = 0 ] || fail "github pr state with mergeStateStatus $ms must exit 0, got $s: $(cat "$tmp/err")"
  oneline "github pr state with mergeStateStatus $ms" "OPEN $ms"
done
s=$(GH_VIEW=$(ghstate OPEN UNKNOWN "") prrun state "$u")
[ "$s" = 0 ] || fail "github pr state with an empty mergeStateStatus must exit 0, got $s: $(cat "$tmp/err")"
oneline "github pr state with an empty mergeStateStatus" "OPEN UNKNOWN"
s=$(GH_VIEW_FAIL=1 prrun state "$u")
[ "$s" = 1 ] || fail "github pr state must exit 1 when gh fails, got $s"
[ ! -s "$tmp/out" ] || fail "github pr state prints nothing on stdout when gh fails: $(cat "$tmp/out")"
named "github pr state when gh fails" "Could not resolve to a PullRequest"
nomerge "github pr state when gh fails"
for bad in "" '{"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"}' '{"state": "", "mergeStateStatus": "CLEAN"}'; do
  s=$(GH_VIEW=$bad prrun state "$u")
  [ "$s" = 1 ] || fail "github pr state must exit 1 when gh returns no state ('$bad'), got $s"
  [ ! -s "$tmp/out" ] || fail "github pr state prints nothing on stdout when gh returns no state ('$bad'): $(cat "$tmp/out")"
  named "github pr state when gh returns no state ('$bad')" "no state" "$u"
done

origin ssh://git@forgejo.example.test:2222/op/widget.git
export FORGE_FORGEJO_ENV=$tmp/pr/forge.env
for c in "closed true false MERGED UNKNOWN merged" "closed true true MERGED UNKNOWN merged-mergeable" "open false true OPEN UNKNOWN open-mergeable" "open false false OPEN DIRTY open-conflicting" "closed false false CLOSED UNKNOWN closed" "closed false true CLOSED UNKNOWN closed-mergeable"; do
  read -r st g m want wms name <<<"$c"
  s=$(CURL_CODE=200 CURL_BODY=$(fpr "$st" "$g" "$m") prrun state "$fu")
  [ "$s" = 0 ] || fail "forgejo pr state of a $name pull must exit 0, got $s: $(cat "$tmp/err")"
  oneline "forgejo pr state of a $name pull" "$want $wms"
  fget "forgejo pr state of a $name pull"
done
s=$(CURL_CODE=404 CURL_BODY='{"message": "pull request does not exist"}' prrun state "$fu")
[ "$s" = 1 ] || fail "forgejo pr state on an API error must exit 1, got $s"
[ ! -s "$tmp/out" ] || fail "forgejo pr state on an API error prints nothing on stdout: $(cat "$tmp/out")"
named "forgejo pr state on an API error" "pull request does not exist" 404
unset FORGE_FORGEJO_ENV

[ "$(prrun state)" = 2 ] || fail "pr state without a url must exit 2"
[ "$(prrun state "$u" x)" = 2 ] || fail "pr state with two arguments must exit 2"
"$forge" pr --help | grep -qF "forge pr state <url>" || fail "forge pr --help must document forge pr state <url>"
ok pr-state
fi

rrun() { : >"$SLEEP_LOG"; PATH=$tmp/pr/sleep:$PATH prrun "$@"; }
slept() { [ "$(cat "$SLEEP_LOG")" = "$(printf '%s\n' "${@:2}")" ] || fail "$1 must sleep ${*:2}, slept: $(paste -sd' ' "$SLEEP_LOG")"; }
if want pr-retry; then
origin git@github.com:octo/forge.git
export FORGE_PR_CHECK_INTERVAL=0 FORGE_PR_CHECK_GRACE=0 FORGE_PR_CHECK_WAIT=0 GH_VIEW=$(jq -c '.state = "OPEN"' <<<"$green")
merges() { [ "$(grep -cx merge "$GH_LOG")" = "$2" ] || fail "$1 must call gh pr merge $2 times: $(cat "$GH_LOG")"; }
retries() {
  local want=$2 i d
  [ "$(grep -c '; retry [0-9]/3 in ' "$tmp/err")" = "$want" ] || fail "$1 must print $want retry lines: $(cat "$tmp/err")"
  i=0
  for d in 10 30 90; do
    i=$((i + 1))
    [ "$i" -le "$want" ] || break
    grep -qxE "forge: gh transport error \(.*$3.*\); retry $i/3 in $d s" "$tmp/err" || fail "$1 must print 'forge: gh transport error (...$3...); retry $i/3 in $d s': $(cat "$tmp/err")"
  done
}
reset='Post "https://api.github.com/graphql": read tcp 203.0.113.5:50312->140.82.112.6:443: read: connection reset by peer'
for c in "connection reset|$reset" "timeout|Post \"https://api.github.com/graphql\": dial tcp 140.82.112.6:443: i/o timeout" \
  "timed out|Post \"https://api.github.com/graphql\": dial tcp 140.82.112.6:443: connect: operation timed out" \
  "EOF|Post \"https://api.github.com/graphql\": unexpected EOF" "HTTP 502|HTTP 502: Bad Gateway (https://api.github.com/graphql)"; do
  k=${c%%|*} e=${c#*|}
  s=$(GH_MERGE_FAILS=1 GH_MERGE_ERR=$e rrun merge "$u")
  [ "$s" = 0 ] || fail "github merge after one '$k' transport error must retry and exit 0, got $s: $(cat "$tmp/err")"
  merges "github merge after one '$k' transport error" 2
  [ "$(grep -A4 -x merge "$GH_LOG" | grep -vx -- --)" = "$(printf '%s\n' merge "$u" --merge --match-head-commit "$sha" merge "$u" --merge --match-head-commit "$sha")" ] || fail "github merge must retry the same gh pr merge call: $(cat "$GH_LOG")"
  slept "github merge after one '$k' transport error" 10
  retries "github merge after one '$k' transport error" 1 "$k"
  named "github merge after one '$k' transport error" "$e"
done
s=$(GH_MERGE_FAILS=4 GH_MERGE_ERR=$reset rrun merge "$u")
[ "$s" = 1 ] || fail "github merge after 4 transport errors must exit 1, got $s: $(cat "$tmp/err")"
merges "github merge after 4 transport errors" 4
slept "github merge after 4 transport errors" 10 30 90
retries "github merge after 4 transport errors" 3 "connection reset"
named "github merge after 4 transport errors" "$reset"
s=$(GH_MERGE_FAILS=3 GH_MERGE_ERR=$reset rrun merge "$u")
[ "$s" = 0 ] || fail "github merge that succeeds on the third retry must exit 0, got $s: $(cat "$tmp/err")"
merges "github merge that succeeds on the third retry" 4
slept "github merge that succeeds on the third retry" 10 30 90
s=$(GH_MERGE_FAILS=1 GH_MERGE_ERR='GraphQL: Pull request is not mergeable (mergePullRequest)' rrun merge "$u")
[ "$s" = 1 ] || fail "github merge with a non-transport gh error must exit 1, got $s: $(cat "$tmp/err")"
merges "github merge with a non-transport gh error" 1
slept "github merge with a non-transport gh error"
! grep -qF retry "$tmp/err" || fail "github merge with a non-transport gh error must not retry: $(cat "$tmp/err")"
named "github merge with a non-transport gh error" "Pull request is not mergeable"
s=$(GH_MERGE_FAILS=1 GH_MERGE_ERR=$reset GH_VIEW=$(jq -c '.state = "MERGED"' <<<"$green") rrun merge "$u")
[ "$s" = 0 ] || fail "github merge whose reset merge went through must exit 0, got $s: $(cat "$tmp/err")"
merges "github merge whose reset merge went through" 1
grep -qx state "$GH_VIEW_LOG" || fail "github merge after a reset gh pr merge must read gh pr view --json state: $(cat "$GH_VIEW_LOG")"
s=$(GH_MERGE_FAILS=1 GH_MERGE_ERR=$reset GH_STATE_ERR=$reset rrun merge "$u")
[ "$s" = 1 ] || fail "github merge whose state cannot be read after a reset merge must exit 1, got $s: $(cat "$tmp/err")"
merges "github merge whose state cannot be read after a reset merge" 1
[ "$(grep -cx state "$GH_VIEW_LOG")" = 4 ] || fail "github merge after a reset merge must retry gh pr view --json state 3 times: $(cat "$GH_VIEW_LOG")"
slept "github merge whose state cannot be read after a reset merge" 10 30 90
named "github merge whose state cannot be read after a reset merge" "cannot tell whether $u merged"
s=$(GH_VIEW_FAILS=1 GH_VIEW_ERR=$reset rrun checks "$u")
[ "$s" = 0 ] || fail "pr checks after a reset gh pr view must retry and exit 0, got $s: $(cat "$tmp/err")"
[ "$(grep -cx -- -- "$GH_VIEW_LOG")" = 2 ] || fail "pr checks must retry gh pr view once: $(cat "$GH_VIEW_LOG")"
lines "pr checks after a reset gh pr view" "pass\tbuild\t$gh/CI/build\npass\tlint\t$gh/CI/lint\n"
slept "pr checks after a reset gh pr view" 10
retries "pr checks after a reset gh pr view" 1 "connection reset"
s=$(GH_VIEW_FAILS=1 GH_VIEW_ERR=$reset rrun merge "$u")
[ "$s" = 0 ] || fail "github merge after a reset gh pr view in the checks poll must retry and exit 0, got $s: $(cat "$tmp/err")"
merges "github merge after a reset gh pr view in the checks poll" 1
slept "github merge after a reset gh pr view in the checks poll" 10
s=$(GH_VIEW_FAILS=4 GH_VIEW_ERR="HTTP 503: Service Unavailable (https://api.github.com/graphql)" rrun checks "$u")
[ "$s" = 1 ] || fail "pr checks after 4 transport errors must exit 1, got $s: $(cat "$tmp/err")"
slept "pr checks after 4 transport errors" 10 30 90
s=$(GH_VIEW_FAILS=1 GH_VIEW_ERR=$reset GH_VIEW=$(ghstate OPEN MERGEABLE CLEAN) rrun state "$u")
[ "$s" = 0 ] || fail "github pr state after a reset gh pr view must retry and exit 0, got $s: $(cat "$tmp/err")"
oneline "github pr state after a reset gh pr view" "OPEN CLEAN"
slept "github pr state after a reset gh pr view" 10
retries "github pr state after a reset gh pr view" 1 "connection reset"
unset GH_VIEW FORGE_PR_CHECK_INTERVAL FORGE_PR_CHECK_GRACE FORGE_PR_CHECK_WAIT
ok pr-retry
fi

if want pr-forgejo-retry; then
origin ssh://git@forgejo.example.test:2222/op/widget.git
export FORGE_FORGEJO_ENV=$tmp/pr/forge.env
unset FORGE_FORGEJO_MERGE_DELAYS
later='405 {"message": "Please try again later"}'
fopen="200 $(fpr open false true)"
fcalls() {
  [[ $(jq -rs 'map(.method) | join(" ")' "$CURL_LOG") =~ ^$2$ ]] || fail "$1 must call the Forgejo API as /$2/: $(jq -rs 'map(.method) | join(" ")' "$CURL_LOG")"
  jq -se --arg m "$api/op/widget/pulls/7/merge" --arg g "$api/op/widget/pulls/7" --arg h "$fsha" \
    'all((.method == "POST" and .url == $m and (.data | fromjson | .Do == "merge" and (.head_commit_id // $h) == $h)) or (.method == "GET" and .url == $g))' "$CURL_LOG" >/dev/null ||
    fail "$1 must only POST {\"Do\": \"merge\"} to the merge URL and GET the pull: $(cat "$CURL_LOG")"
  nogh "$1"
}
fretries() {
  local i=0 d
  [ "$(grep -c 'retry [0-9]/3 in ' "$tmp/err")" = "$(($# - 1))" ] || fail "$1 must print $(($# - 1)) retry lines: $(cat "$tmp/err")"
  for d in "${@:2}"; do
    i=$((i + 1))
    grep -qxF "forge: Forgejo merge HTTP 405 (Please try again later); retry $i/3 in $d s" "$tmp/err" ||
      fail "$1 must print 'forge: Forgejo merge HTTP 405 (Please try again later); retry $i/3 in $d s': $(cat "$tmp/err")"
  done
}
final() { grep -qxF "forge: Forgejo API POST /op/widget/pulls/7/merge failed with HTTP 405: $2" "$tmp/err" || fail "$1 must fail with 'Forgejo API POST /op/widget/pulls/7/merge failed with HTTP 405: $2': $(cat "$tmp/err")"; }

s=$(CURL_POSTS=$later$'\n'$later$'\n200 ' CURL_GETS=$fopen rrun merge "$fu")
[ "$s" = 0 ] || fail "forgejo merge after two 405 'Please try again later' must retry and exit 0, got $s: $(cat "$tmp/err")"
fcalls "forgejo merge after two 405s" "GET POST( GET)+ POST( GET)+ POST"
fretries "forgejo merge after two 405s" 3 10
slept "forgejo merge after two 405s" 3 10
! grep -qF "failed with HTTP" "$tmp/err" || fail "forgejo merge that succeeds on a retry must print no failure: $(cat "$tmp/err")"

s=$(CURL_POSTS=$later CURL_GETS=$fopen rrun merge "$fu")
[ "$s" = 1 ] || fail "forgejo merge after four 405s must exit 1, got $s: $(cat "$tmp/err")"
fcalls "forgejo merge after four 405s" "GET POST( GET)+ POST( GET)+ POST( GET)+ POST( GET)*"
fretries "forgejo merge after four 405s" 3 10 30
slept "forgejo merge after four 405s" 3 10 30
final "forgejo merge after four 405s" "Please try again later"

s=$(FORGE_FORGEJO_MERGE_DELAYS='1 2 5' CURL_POSTS=$later CURL_GETS=$fopen rrun merge "$fu")
[ "$s" = 1 ] || fail "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS='1 2 5' after four 405s must exit 1, got $s: $(cat "$tmp/err")"
fcalls "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS" "GET POST( GET)+ POST( GET)+ POST( GET)+ POST( GET)*"
fretries "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS" 1 2 5
slept "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS" 1 2 5
s=$(FORGE_FORGEJO_MERGE_DELAYS='0 0 0' CURL_POSTS=$later$'\n200 ' CURL_GETS=$fopen prrun merge "$fu")
[ "$s" = 0 ] || fail "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS='0 0 0' after one 405 must exit 0, got $s: $(cat "$tmp/err")"
fretries "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS='0 0 0'" 0
for bad in '3 x 30' '-1' '1.5 2 3'; do
  s=$(FORGE_FORGEJO_MERGE_DELAYS=$bad CURL_POSTS=$later CURL_GETS=$fopen rrun merge "$fu")
  [ "$s" = 1 ] || fail "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS='$bad' must exit 1, got $s: $(cat "$tmp/err")"
  named "forgejo merge with FORGE_FORGEJO_MERGE_DELAYS='$bad'" FORGE_FORGEJO_MERGE_DELAYS
done

for b in "$later" '405 ' '405 {"message": ""}' '405 {"message": "User not allowed to merge PR"}'; do
  s=$(CURL_POSTS=$b CURL_GETS="200 $(fpr closed true false)" rrun merge "$fu")
  [ "$s" = 0 ] || fail "forgejo merge whose 405 ($b) hit an already merged pull must exit 0, got $s: $(cat "$tmp/err")"
  [ "$(jq -s '[.[] | select(.method == "POST")] | length' "$CURL_LOG")" = 1 ] || fail "forgejo merge of an already merged pull must not POST again: $(cat "$CURL_LOG")"
  fcalls "forgejo merge of an already merged pull ($b)" "GET POST( GET)+"
  grep -qiE 'already[ -]merged' "$tmp/err" || fail "forgejo merge of an already merged pull must say on stderr it was already merged: $(cat "$tmp/err")"
  ! grep -qF "failed with HTTP" "$tmp/err" || fail "forgejo merge of an already merged pull must print no failure: $(cat "$tmp/err")"
done

for b in "$later" '405 {"message": "User not allowed to merge PR"}'; do
  s=$(CURL_POSTS=$b CURL_GETS="200 $(fpr closed false false)" rrun merge "$fu")
  [ "$s" = 1 ] || fail "forgejo merge whose 405 ($b) hit a closed pull must exit 1, got $s: $(cat "$tmp/err")"
  [ "$(jq -s '[.[] | select(.method == "POST")] | length' "$CURL_LOG")" = 1 ] || fail "forgejo merge of a closed pull must not POST again: $(cat "$CURL_LOG")"
  fcalls "forgejo merge of a closed pull ($b)" "GET POST( GET)+"
  named "forgejo merge of a closed pull ($b)" closed
done

for m in "User not allowed to merge PR" "Work in progress PRs cannot be merged" "Invalid merge style" "Not allowed to merge: protected branch"; do
  s=$(CURL_POSTS="405 $(jq -cn --arg m "$m" '{message: $m}')" CURL_GETS=$fopen rrun merge "$fu")
  [ "$s" = 1 ] || fail "forgejo merge with a 405 '$m' must exit 1, got $s: $(cat "$tmp/err")"
  fcalls "forgejo merge with a 405 '$m'" "GET POST GET"
  slept "forgejo merge with a 405 '$m'"
  ! grep -qF retry "$tmp/err" || fail "forgejo merge with a 405 '$m' must not retry: $(cat "$tmp/err")"
  final "forgejo merge with a 405 '$m'" "$m"
done

for c in '409 {"message": "merge conflict"}' '409 {"message": "head out of date"}' '403 {"message": "forbidden"}' '404 {"message": "not found"}' '500 {"message": "internal error"}'; do
  s=$(CURL_POSTS=$c CURL_GETS=$fopen rrun merge "$fu")
  [ "$s" = 1 ] || fail "forgejo merge with HTTP ${c%% *} must exit 1, got $s: $(cat "$tmp/err")"
  fcalls "forgejo merge with HTTP ${c%% *}" "GET POST"
  slept "forgejo merge with HTTP ${c%% *}"
  named "forgejo merge with HTTP ${c%% *}" "failed with HTTP ${c%% *}"
done

s=$(CURL_POSTS=$later CURL_GETS=$fopen rrun create forge/quick-x "Add widget" "$body")
[ "$s" = 1 ] || fail "forgejo create with a 405 must exit 1, got $s: $(cat "$tmp/err")"
onecall "forgejo create with a 405" POST "$api/op/widget/pulls" "$created"
slept "forgejo create with a 405"
s=$(CURL_CODE=405 CURL_BODY='{"message": "Please try again later"}' rrun close "$fu")
[ "$s" = 1 ] || fail "forgejo close with a 405 must exit 1, got $s: $(cat "$tmp/err")"
onecall "forgejo close with a 405" PATCH "$api/op/widget/pulls/7" '{"state": "closed"}'
slept "forgejo close with a 405"
s=$(CURL_GETS="$later" rrun state "$fu")
[ "$s" = 1 ] || fail "forgejo pr state with a 405 must exit 1, got $s: $(cat "$tmp/err")"
fget "forgejo pr state with a 405"
slept "forgejo pr state with a 405"
unset FORGE_FORGEJO_ENV

h=$("$forge" pr --help)
grep -qF FORGE_FORGEJO_MERGE_DELAYS <<<"$h" || fail "forge pr --help must document FORGE_FORGEJO_MERGE_DELAYS"
grep -qF "Please try again later" <<<"$h" || fail "forge pr --help must document the Forgejo merge 405 'Please try again later' retry"
grep -qF "forge: Forgejo merge HTTP 405 (Please try again later); retry" <<<"$h" || fail "forge pr --help must show the Forgejo merge retry stderr line"
ok pr-forgejo-retry
fi

if want pr-fresh; then
fr=$tmp/pr/fresh
git init -q --bare -b main "$fr/origin.git"
git init -q -b main "$fr/w"
git -C "$fr/w" remote add origin git@github.com:octo/forge.git
fc() {
  local m=$2 f
  git -C "$fr/w" checkout -q --detach "$1"
  for f in "${@:3}"; do mkdir -p "$(dirname "$fr/w/$f")"; echo "$m" >>"$fr/w/$f"; done
  pgit -C "$fr/w" add -A
  pgit -C "$fr/w" commit -qm "$m"
  git -C "$fr/w" rev-parse HEAD
}
mkdir -p "$fr/w/.forge" "$fr/w/src" "$fr/w/bin"
printf -- '- All tests: `true`.\n' >"$fr/w/.forge/TESTING.md"
printf 'state\n' >"$fr/w/.forge/STATE.md"
printf 'a\n' >"$fr/w/src/a"
printf 'x\n' >"$fr/w/bin/x"
pgit -C "$fr/w" add -A
pgit -C "$fr/w" commit -qm base
B=$(git -C "$fr/w" rev-parse HEAD)
H=$(fc "$B" head src/h)
Mforge=$(fc "$B" "forge state" .forge/STATE.md)
Mcode=$(fc "$Mforge" "code move" src/a bin/x)
Mtest=$(fc "$B" "testing move" .forge/TESTING.md)
git -C "$fr/w" checkout -q --detach "$H"
pgit -C "$fr/w" merge -q --no-edit "$Mcode"
H2=$(git -C "$fr/w" rev-parse HEAD)
git -C "$fr/w" checkout -q --detach "$H"
omain() { git -C "$fr/w" push -q -f "$fr/origin.git" "$1:refs/heads/main"; }
frun() { SSH_GIT_REPO=$fr/origin.git prdir=${prdir:-$fr/w} prrun "$@"; }
hv() { jq -c --arg h "$1" '.headRefOid = $h' <<<"$green"; }
stale() {
  [ "$2" = 5 ] || fail "$1 must exit 5, got $2: $(cat "$tmp/err")"
  grep -qxF "forge: origin/main moved outside .forge/ since head ${3:0:7}: $4; merge origin/main into the branch and retest" "$tmp/err" ||
    fail "$1 must print 'forge: origin/main moved outside .forge/ since head ${3:0:7}: $4; merge origin/main into the branch and retest': $(cat "$tmp/err")"
}
export FORGE_PR_CHECK_INTERVAL=0 FORGE_PR_CHECK_GRACE=0 FORGE_PR_CHECK_WAIT=0 FORGE_FORGEJO_ENV=$tmp/pr/forge.env

omain "$Mforge"
s=$(GH_VIEW=$(hv "$H") frun merge "$u")
[ "$s" = 0 ] || fail "github merge of a head behind a .forge/-only move of origin main must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$H"
om=$(git -C "$fr/w" rev-parse -q --verify refs/remotes/origin/main || echo none)
[ "$om" = "$Mforge" ] || fail "github merge must fetch origin main into refs/remotes/origin/main: want $Mforge, got $om"

omain "$Mcode"
s=$(GH_VIEW=$(hv "$H") frun merge "$u")
stale "github merge of a head behind a code move of origin main" "$s" "$H" bin/x
nomerge "github merge of a stale head"
s=$(GH_VIEW=$(hv "$H") prdir=$fr/w/src frun merge "$u")
stale "github merge of a stale head from a subdirectory" "$s" "$H" bin/x
nomerge "github merge of a stale head from a subdirectory"

s=$(GH_VIEW=$(hv "$H2") frun merge "$u")
[ "$s" = 0 ] || fail "github merge of a head containing origin main must exit 0, got $s: $(cat "$tmp/err")"
ghargs pr merge "$u" --merge --match-head-commit "$H2"

omain "$Mtest"
s=$(GH_VIEW=$(hv "$H") frun merge "$u")
stale "github merge of a head behind a .forge/TESTING.md move of origin main" "$s" "$H" .forge/TESTING.md
nomerge "github merge of a head behind a TESTING.md move"

omain "$Mforge"
s=$(GH_VIEW=$(hv 0123456789abcdef0123456789abcdef01234567) frun merge "$u")
[ "$s" != 0 ] && [ "$s" != 5 ] || fail "github merge of a head not in the checkout must fail, not exit $s: $(cat "$tmp/err")"
nomerge "github merge of a head not in the checkout"
s=$(SSH_GIT_REPO=$fr/none.git GH_VIEW=$(hv "$H") prdir=$fr/w prrun merge "$u")
[ "$s" != 0 ] && [ "$s" != 5 ] || fail "github merge when origin main cannot be fetched must fail, not exit $s: $(cat "$tmp/err")"
nomerge "github merge when origin main cannot be fetched"

git -C "$fr/w" remote set-url origin ssh://git@forgejo.example.test:2222/op/widget.git
fhead() { jq -cn --arg h "$1" '{number: 7, state: "open", merged: false, mergeable: true, head: {ref: "forge/quick-x", sha: $h}}'; }
omain "$Mforge"
s=$(CURL_GETS="200 $(fhead "$H")" CURL_POSTS='200 ' frun merge "$fu")
[ "$s" = 0 ] || fail "forgejo merge of a head behind a .forge/-only move of origin main must exit 0, got $s: $(cat "$tmp/err")"
fmerged "forgejo merge of a head behind a .forge/-only move" "$H"

omain "$Mcode"
s=$(CURL_GETS="200 $(fhead "$H")" CURL_POSTS='200 ' frun merge "$fu")
stale "forgejo merge of a head behind a code move of origin main" "$s" "$H" bin/x
[ "$(jq -rs 'map(.method + " " + .url) | join(",")' "$CURL_LOG")" = "GET $api/op/widget/pulls/7" ] ||
  fail "forgejo merge of a stale head must GET the pull and POST nothing: $(cat "$CURL_LOG")"

s=$(CURL_GETS="200 $(fhead "$H2")" CURL_POSTS='200 ' frun merge "$fu")
[ "$s" = 0 ] || fail "forgejo merge of a head containing origin main must exit 0, got $s: $(cat "$tmp/err")"
fmerged "forgejo merge of a head containing origin main" "$H2"

omain "$Mtest"
s=$(CURL_GETS="200 $(fhead "$H")" CURL_POSTS='200 ' frun merge "$fu")
stale "forgejo merge of a head behind a .forge/TESTING.md move of origin main" "$s" "$H" .forge/TESTING.md
[ "$(jq -rs 'map(.method) | join(" ")' "$CURL_LOG")" = GET ] || fail "forgejo merge of a head behind a TESTING.md move must POST nothing: $(cat "$CURL_LOG")"

h=$("$forge" pr --help)
grep -qE '^  5  ' <<<"$h" || fail "forge pr --help must list exit code 5"
grep -qF 'origin/main' <<<"$h" || fail "forge pr --help must document the origin/main freshness check of merge"
unset FORGE_FORGEJO_ENV FORGE_PR_CHECK_INTERVAL FORGE_PR_CHECK_GRACE FORGE_PR_CHECK_WAIT
ok pr-fresh
fi

if want pr-ci; then
export FORGE_PR_CHECK_INTERVAL=0 FORGE_PR_CHECK_GRACE=0 FORGE_PR_CHECK_WAIT=0
ci=$tmp/ci/repo
git init -q -b main "$ci"
git -C "$ci" remote add origin git@github.com:octo/forge.git
mkdir -p "$ci/.forge"
cidoc='- All tests: `true`.\n- CI full suite: `test`, the GitHub Actions job.\n'
printf -- "$cidoc" >"$ci/.forge/TESTING.md"
git -C "$ci" add -A
git -C "$ci" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false commit -qm init
echo dirty >"$ci/untracked.txt"
chead=$(git -C "$ci" rev-parse HEAD)
ctree=$(git -C "$ci" rev-parse "HEAD^{tree}")
cshort=$(git -C "$ci" rev-parse --short "$ctree")
hid=$(tr -d '[:space:]' </etc/machine-id 2>/dev/null) || hid=
[ -n "$hid" ] || { hid=0123456789abcdef0123456789abcde0; export FORGE_MACHINE_ID=$hid; }
hs=$(git -C "$ci" rev-parse --path-format=absolute --git-common-dir)/forge-test/$hid
cview() { jq -cn --arg h "$1" '{headRefOid: $h, statusCheckRollup: ($ARGS.positional | map(fromjson))}' --args "${@:2}"; }
cirun() { rm -rf "$hs"; prdir=$ci prrun "$@"; }
nostamp() { [ ! -e "$hs/$ctree" ] && [ -z "$(ls -A "$hs" 2>/dev/null)" ] || fail "$1 must write no stamp: $(ls -A "$hs")"; }
fallback() {
  [ "$2" = 6 ] || fail "$1 must exit 6, got $2: $(cat "$tmp/err")"
  [ "$(wc -l <"$tmp/err")" = 1 ] && grep -qxE 'forge: CI full suite: .+; run forge test' "$tmp/err" || fail "$1 must print one stderr line 'forge: CI full suite: <reason>; run forge test': $(cat "$tmp/err")"
  nostamp "$1"
  nomerge "$1"
  nocurl "$1"
}
cipass() { cr test COMPLETED SUCCESS "${1:-$t1}"; }
build=$(cr build COMPLETED SUCCESS $t1)
cu=https://github.com/octo/forge/pull/12

s=$(GH_VIEW=$(cview "$chead" "$(cipass)" "$build") cirun checks --full "$cu")
[ "$s" = 0 ] || fail "pr checks --full with the declared Actions check passed on HEAD must exit 0, got $s: $(cat "$tmp/err")"
[ -f "$hs/$ctree" ] && [ ! -s "$hs/$ctree" ] || fail "pr checks --full must write an empty stamp for HEAD's tree at $hs/$ctree: $(ls -A "$hs" 2>&1)"
[ "$(ls -A "$hs")" = "$ctree" ] || fail "pr checks --full must write only HEAD's tree stamp: $(ls -A "$hs")"
grep -qxF "forge: tests passed ($cshort), CI check test" "$tmp/err" || fail "pr checks --full must print 'forge: tests passed ($cshort), CI check test': $(cat "$tmp/err")"
lines "pr checks --full" "pass\ttest\t$gh/CI/test\npass\tbuild\t$gh/CI/build\n"
viewed "pr checks --full" "$cu"
nomerge "pr checks --full"
nocurl "pr checks --full"

s=$(GH_VIEW=$(cview "$chead" "$(cr test COMPLETED FAILURE $t0)" "$(cipass $t1)") cirun checks --full "$cu")
[ "$s" = 0 ] || fail "pr checks --full whose newest declared run passed must exit 0, got $s: $(cat "$tmp/err")"
[ -f "$hs/$ctree" ] || fail "pr checks --full whose newest declared run passed must write the stamp"

rm "$ci/.forge/TESTING.md"
s=$(GH_VIEW=$(cview "$chead" "$(cipass)") cirun checks --full "$cu")
fallback "pr checks --full without a TESTING.md" "$s"
nogh "pr checks --full without a TESTING.md"
[ ! -s "$tmp/out" ] || fail "pr checks --full without a TESTING.md prints nothing on stdout: $(cat "$tmp/out")"
printf -- '- All tests: `true`.\n' >"$ci/.forge/TESTING.md"
s=$(GH_VIEW=$(cview "$chead" "$(cipass)") cirun checks --full "$cu")
fallback "pr checks --full without a CI full suite line" "$s"
nogh "pr checks --full without a CI full suite line"
[ ! -s "$tmp/out" ] || fail "pr checks --full without a CI full suite line prints nothing on stdout: $(cat "$tmp/out")"
printf -- "$cidoc" >"$ci/.forge/TESTING.md"

s=$(GH_VIEW=$(cview "$chead" "$(cr test COMPLETED SKIPPED $t1)" "$build") cirun checks --full "$cu")
fallback "pr checks --full with a SKIPPED declared run" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cr test COMPLETED NEUTRAL $t1)" "$build") cirun checks --full "$cu")
fallback "pr checks --full with a NEUTRAL declared run" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass $t0)" "$(cr test COMPLETED SKIPPED $t1)") cirun checks --full "$cu")
fallback "pr checks --full whose newest declared run was skipped" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass $t0)" "$(cr test COMPLETED SKIPPED $t1 | jq -c '.startedAt = null')") cirun checks --full "$cu")
fallback "pr checks --full with a declared run of no start time beside a passed one" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass $t0)" "$(cr test COMPLETED SKIPPED "")") cirun checks --full "$cu")
fallback "pr checks --full with a declared run of an empty start time beside a passed one" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass $t1)" "$(cr test COMPLETED SKIPPED $t1)") cirun checks --full "$cu")
fallback "pr checks --full with two newest declared runs of one start time" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(sc test SUCCESS)" "$build") cirun checks --full "$cu")
fallback "pr checks --full with a StatusContext of the declared name" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass | jq -c '.workflowName = ""')" "$build") cirun checks --full "$cu")
fallback "pr checks --full with an empty workflowName" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cipass | jq -c 'del(.workflowName)')" "$build") cirun checks --full "$cu")
fallback "pr checks --full with no workflowName" "$s"
s=$(GH_VIEW=$(cview "$chead" "$build") cirun checks --full "$cu")
fallback "pr checks --full with no row of the declared name" "$s"
s=$(GH_VIEW=$(cview "$chead" "$(cr testing COMPLETED SUCCESS $t1)" "$(cr unit-test COMPLETED SUCCESS $t1)") cirun checks --full "$cu")
fallback "pr checks --full with only rows whose name merely contains the declared one" "$s"
s=$(GH_VIEW=$(cview "$sha" "$(cipass)" "$build") cirun checks --full "$cu")
fallback "pr checks --full on a head that is not W's HEAD" "$s"
s=$(GH_VIEW=$(cview "$sha" "$(cipass)" "$build") GH_VIEW2=$(cview "$chead" "$(cipass)" "$(cr build COMPLETED FAILURE $t1)") cirun checks --full "$cu")
fallback "pr checks --full whose gated view is another head than a later view" "$s"
[ "$(grep -cxF "$cu" "$GH_VIEW_LOG")" = 1 ] || fail "pr checks --full must stamp from the one view its checks gate read: $(cat "$GH_VIEW_LOG")"

printf -- '- All tests: `true`.\n- CI full suite: `build`.\n' >"$ci/.forge/TESTING.md"
s=$(GH_VIEW=$(cview "$chead" "$build") cirun checks --full "$cu")
fallback "pr checks --full with an uncommitted CI full suite line" "$s"
nogh "pr checks --full with an uncommitted CI full suite line"
git -C "$ci" add .forge/TESTING.md
s=$(GH_VIEW=$(cview "$chead" "$build") cirun checks --full "$cu")
fallback "pr checks --full with a staged CI full suite line" "$s"
nogh "pr checks --full with a staged CI full suite line"
printf -- "$cidoc" >"$ci/.forge/TESTING.md"
git -C "$ci" add .forge/TESTING.md

for x in https://github.com/evil/forge/pull/12 https://github.com/octo/forge-fork/pull/12 https://github.example.test/octo/forge/pull/12 12; do
  s=$(GH_VIEW=$(cview "$chead" "$(cipass)" "$build") cirun checks --full "$x")
  fallback "pr checks --full on $x, not a pull request of origin" "$s"
  nogh "pr checks --full on $x, not a pull request of origin"
done
s=$(GH_VIEW=$(cview "$chead" "$(cipass)" "$build") cirun checks --full https://github.com/Octo/Forge/pull/12/)
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "pr checks --full on origin's pull request in another case must stamp, got $s: $(cat "$tmp/err")"

s=$(GH_VIEW=$(cview "$chead" "$(cr test COMPLETED FAILURE $t1)" "$build") cirun checks --full "$cu")
[ "$s" = 3 ] || fail "pr checks --full with the declared check failed must exit 3, got $s: $(cat "$tmp/err")"
named "pr checks --full with the declared check failed" "check failed: test"
nostamp "pr checks --full with the declared check failed"
s=$(GH_VIEW=$(cview "$chead" "$(cr test QUEUED "" "")" "$build") cirun checks --full "$cu")
[ "$s" = 4 ] || fail "pr checks --full with the declared check pending must exit 4, got $s: $(cat "$tmp/err")"
nostamp "pr checks --full with the declared check pending"
s=$(GH_VIEW_FAIL=1 cirun checks --full "$cu")
[ "$s" = 1 ] || fail "pr checks --full must exit 1 when gh fails, got $s: $(cat "$tmp/err")"
nostamp "pr checks --full when gh fails"

export FORGE_FORGEJO_ENV=$tmp/pr/forge.env
git -C "$ci" remote set-url origin ssh://git@forgejo.example.test:2222/op/widget.git
fu=https://forgejo.example.test/op/widget/pulls/7
fapi=$api/op/widget
fruns=https://forgejo.example.test/op/widget/actions/runs
osha=fedcba9876543210fedcba9876543210fedcba98
fc0=2026-10-27T15:00:00-04:00 fc1=2026-10-27T15:21:37-04:00 fold=2026-10-27T14:00:00-04:00
fpull() { jq -cn --arg h "$1" '{id: 107, number: 7, state: "open", merged: false, html_url: "https://forgejo.example.test/op/widget/pulls/7", head: {ref: "forge/x", sha: $h}, base: {ref: "main"}}'; }
frun() { jq -cn --argjson id "$1" --arg w "$2" --argjson i "$3" --arg s "$4" --arg c "$5" --arg h "$6" '{id: $id, title: "feat: x", workflow_id: $w, index_in_repo: $i, commit_sha: $h, event: "pull_request", trigger_event: "pull_request", status: $s, created: $c, started: $c, stopped: $c, html_url: ("https://forgejo.example.test/op/widget/actions/runs/\($i)")}'; }
ftask() { jq -cn --argjson id "$1" --arg n "$2" --arg s "$3" --argjson r "$4" --arg w "$5" --arg c "$6" --arg h "$7" '{id: $id, name: $n, head_branch: "forge/x", head_sha: $h, run_number: $r, event: "pull_request", display_title: "feat: x", status: $s, workflow_id: $w, url: ("https://forgejo.example.test/op/widget/actions/runs/\($r)"), created_at: $c, updated_at: $c, run_started_at: $c}'; }
flist() { jq -cn '{workflow_runs: ($ARGS.positional | map(fromjson)), total_count: ($ARGS.positional | length)}' --args "$@"; }
fgets() { printf '200 %s\n' "$@"; }
fci() {
  local h=${3:-$chead}
  fgets "$(fpull "$h")" \
    "$(flist "$(frun 42 ci.yml 12 "$2" $fc1 "$h")" "$(frun 41 ci.yml 11 failure $fc0 "$h")")" \
    "$(flist "$(ftask 95 test failure 13 ci.yml 2026-10-27T15:30:00-04:00 $osha)" "$(ftask 90 lint success 12 ci.yml 2026-10-27T15:21:50-04:00 "$h")" \
      "$(ftask 89 test "$1" 12 ci.yml 2026-10-27T15:21:49-04:00 "$h")" "$(ftask 76 testing success 11 ci.yml 2026-10-27T15:00:21-04:00 "$h")" \
      "$(ftask 75 test failure 11 ci.yml 2026-10-27T15:00:20-04:00 "$h")" "$(ftask 60 test success 9 ci.yml $fold $osha)")"
}
nostatus() { ! jq -r .url "$CURL_LOG" | grep -qE '/statuses|/commits/|/status([?/]|$)' || fail "$1 must never read a commit status: $(jq -r .url "$CURL_LOG")"; }
fcalls() {
  nostatus "$1"
  [ "$(jq -r .url "$CURL_LOG" | head -n 1)" = "$fapi/pulls/7" ] || fail "$1 must first read the pull request at $fapi/pulls/7: $(jq -r .url "$CURL_LOG")"
  ! jq -r .url "$CURL_LOG" | grep -qvF "$fapi/" || fail "$1 must call only origin's repo API under $fapi/: $(jq -r .url "$CURL_LOG")"
  ! jq -r .method "$CURL_LOG" | grep -qvx GET || fail "$1 must only GET: $(jq -r .method "$CURL_LOG")"
  jq -r .url "$CURL_LOG" | grep -E "^$fapi/actions/runs\?" | grep -qF "head_sha=$2" || fail "$1 must read the runs of head $2 from /actions/runs: $(jq -r .url "$CURL_LOG")"
  jq -r .url "$CURL_LOG" | grep -qE "^$fapi/actions/tasks\?" || fail "$1 must read the tasks from /actions/tasks: $(jq -r .url "$CURL_LOG")"
  jq -se --arg h "Authorization: token $tok" 'all(.[]; .headers | index($h))' "$CURL_LOG" >/dev/null || fail "$1 must send the token header on every request: $(jq -c .headers "$CURL_LOG")"
}
ffallback() {
  [ "$2" = 6 ] || fail "$1 must exit 6, got $2: $(cat "$tmp/err")"
  [ "$(wc -l <"$tmp/err")" = 1 ] && grep -qxE 'forge: CI full suite: .+; run forge test' "$tmp/err" || fail "$1 must print one stderr line 'forge: CI full suite: <reason>; run forge test': $(cat "$tmp/err")"
  nostamp "$1"
  nomerge "$1"
  nogh "$1"
  nostatus "$1"
}

s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
[ "$s" = 0 ] || fail "forgejo pr checks --full with the declared Actions task passed on HEAD must exit 0, got $s: $(cat "$tmp/err")"
[ -f "$hs/$ctree" ] && [ ! -s "$hs/$ctree" ] || fail "forgejo pr checks --full must write an empty stamp for HEAD's tree at $hs/$ctree: $(ls -A "$hs" 2>&1)"
[ "$(ls -A "$hs")" = "$ctree" ] || fail "forgejo pr checks --full must write only HEAD's tree stamp: $(ls -A "$hs")"
grep -qxF "forge: tests passed ($cshort), CI check test" "$tmp/err" || fail "forgejo pr checks --full must print 'forge: tests passed ($cshort), CI check test': $(cat "$tmp/err")"
! grep -q '^fail' "$tmp/out" || fail "forgejo pr checks --full that passed prints no fail row: $(cat "$tmp/out")"
fcalls "forgejo pr checks --full" "$chead"
nogh "forgejo pr checks --full"

s=$(CURL_GETS=$(fci success success) cirun checks --full https://forgejo.example.test/Op/Widget/pulls/7/)
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full on origin's pull request in another case must stamp, got $s: $(cat "$tmp/err")"

: >"$CURL_LOG"; rm -rf "$hs"; s=0
(cd "$ci" && CURL_GETS=$(fci success success) PATH=$tmp/pr/bin:$PATH bash -x "$forge" pr checks --full "$fu") >"$tmp/out" 2>"$tmp/err" || s=$?
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full under xtrace must exit 0 and stamp, got $s: $(tail -n 5 "$tmp/err")"
grep -q '^+' "$tmp/err" || fail "forgejo pr checks --full under bash -x must trace"
! grep -qF "$tok" "$tmp/out" "$tmp/err" || fail "forgejo pr checks --full under xtrace printed the token"

for st in skipped cancelled neutral; do
  s=$(CURL_GETS=$(fci $st success) cirun checks --full "$fu")
  ffallback "forgejo pr checks --full with a $st declared task" "$s"
done
s=$(CURL_GETS=$(fci cancelled cancelled) cirun checks --full "$fu")
ffallback "forgejo pr checks --full with a cancelled declared task in a cancelled run" "$s"

s=$(CURL_GETS=$(fci failure failure) cirun checks --full "$fu")
[ "$s" = 3 ] || fail "forgejo pr checks --full with the declared task failed must exit 3, got $s: $(cat "$tmp/err")"
lines "forgejo pr checks --full with the declared task failed" "fail\ttest\t$fruns/12\n"
grep -qxF "forge: check failed: test" "$tmp/err" || fail "forgejo pr checks --full with the declared task failed must print 'forge: check failed: test': $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with the declared task failed"
nostatus "forgejo pr checks --full with the declared task failed"

fstat=$(jq -cn --arg h "$chead" '{state: "success", sha: $h, total_count: 1, statuses: [{id: 5, context: "test", status: "success", target_url: "https://ci.example.test/test", description: "posted"}]}')
s=$(CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist "$(frun 42 ci.yml 12 success $fc1 "$chead")")" \
  "$(flist "$(ftask 95 test success 13 ci.yml 2026-10-27T15:30:00-04:00 $osha)" "$(ftask 90 lint success 12 ci.yml 2026-10-27T15:21:50-04:00 "$chead")" "$(ftask 60 test success 9 ci.yml $fold $osha)")" "$fstat")" \
  cirun checks --full "$fu")
ffallback "forgejo pr checks --full with only a commit status of the declared name and no task" "$s"

s=$(CURL_GETS=$(fci success success "$sha") cirun checks --full "$fu")
ffallback "forgejo pr checks --full on a PR head that is not W's HEAD" "$s"
s=$(CURL_GETS=$(fci failure failure "$sha") cirun checks --full "$fu")
ffallback "forgejo pr checks --full with a failed task on a PR head that is not W's HEAD" "$s"

fsib() {
  fgets "$(fpull "$chead")" "$(flist "$(frun 42 ci.yml 12 "$1" $fc1 "$chead")")" \
    "$(flist "$(ftask 91 test "$2" 12 ci.yml 2026-10-27T15:21:52-04:00 "$chead")" "$(ftask 90 lint success 12 ci.yml 2026-10-27T15:21:50-04:00 "$chead")" \
      "$(ftask 89 test "$3" 12 ci.yml 2026-10-27T15:21:49-04:00 "$chead")" "$(ftask 60 test success 9 ci.yml $fold $osha)")"
}
s=$(CURL_GETS=$(fsib failure success failure) cirun checks --full "$fu")
ffallback "forgejo pr checks --full with the newest declared task passed beside a failed task of the name in a failed run" "$s"
s=$(CURL_GETS=$(fsib success success failure) cirun checks --full "$fu")
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full with a failed task of the name rerun to success in a passed run must stamp, got $s: $(cat "$tmp/err")"
s=$(CURL_GETS=$(fsib failure success success) cirun checks --full "$fu")
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full with every task of the name passed in a failed run must stamp, got $s: $(cat "$tmp/err")"

: >"$SLEEP_LOG"
s=$(FORGE_PR_CHECK_GRACE=60 FORGE_PR_CHECK_WAIT=1 CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist)")"$'\n'"$(fci success success)" PATH=$tmp/pr/sleep:$PATH cirun checks --full "$fu")
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full with no run yet on the first poll must wait within the grace period and stamp, got $s: $(cat "$tmp/err")"
[ "$(wc -l <"$SLEEP_LOG")" = 1 ] || fail "forgejo pr checks --full with no run yet on the first poll must sleep once: $(cat "$SLEEP_LOG")"
s=$(CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist)")" cirun checks --full "$fu")
ffallback "forgejo pr checks --full with no run on the head after the grace period" "$s"

s=$(CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist "$(frun 43 full.yml 13 success $fc1 "$chead")" "$(frun 42 ci.yml 12 success $fc1 "$chead")")" \
  "$(flist "$(ftask 91 test success 13 full.yml 2026-10-27T15:21:52-04:00 "$chead")" "$(ftask 89 test success 12 ci.yml 2026-10-27T15:21:49-04:00 "$chead")" "$(ftask 60 test success 9 ci.yml $fold $osha)")")" \
  cirun checks --full "$fu")
ffallback "forgejo pr checks --full with matching tasks of two workflow_ids" "$s"

mkdir -p "$ci/.forgejo/workflows" "$ci/.github/workflows"
printf 'on: push\njobs:\n  test:\n    runs-on: docker\n    steps:\n      - run: true\n' >"$ci/.forgejo/workflows/ci.yml"
printf 'on: push\njobs:\n  lint:\n    runs-on: docker\n    steps:\n      - run: true\n' >"$ci/.github/workflows/lint.yaml"
s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
[ "$s" = 0 ] && [ -f "$hs/$ctree" ] || fail "forgejo pr checks --full with the declared name in one workflow file must stamp, got $s: $(cat "$tmp/err")"
printf 'on: push\njobs:\n  full:\n    name: test\n    runs-on: docker\n    steps:\n      - run: true\n' >"$ci/.github/workflows/full.yaml"
s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
fallback "forgejo pr checks --full with the declared name defined in two workflow files" "$s"
grep -qF "test is defined in 2 workflow files" "$tmp/err" || fail "forgejo pr checks --full with the declared name in two workflow files must say so: $(cat "$tmp/err")"
printf 'on: push\njobs:\n  "test":\n    runs-on: docker\n' >"$ci/.github/workflows/full.yaml"
s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
fallback "forgejo pr checks --full with the declared name a quoted job id of a second workflow file" "$s"
grep -qF "test is defined in 2 workflow files" "$tmp/err" || fail "forgejo pr checks --full with the declared name a quoted job id of a second workflow file must say so: $(cat "$tmp/err")"
for b in '>-' '|'; do
  printf 'on: push\njobs:\n  full:\n    name: %s\n      test\n    runs-on: docker\n' "$b" >"$ci/.github/workflows/full.yaml"
  s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
  fallback "forgejo pr checks --full beside a second workflow file's block-scalar job name: $b" "$s"
  grep -qF "test is defined in 2 workflow files" "$tmp/err" || fail "forgejo pr checks --full beside a block-scalar job name: $b must say so: $(cat "$tmp/err")"
done
rm -rf "$ci/.forgejo" "$ci/.github"

s=$(CURL_GETS=$(fci running running) cirun checks --full "$fu")
[ "$s" = 4 ] || fail "forgejo pr checks --full with the declared task running past a zero wait must exit 4, got $s: $(cat "$tmp/err")"
grep -qxF "forge: check still pending: test" "$tmp/err" || fail "forgejo pr checks --full with the declared task running must print 'forge: check still pending: test': $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with the declared task running"
s=$(CURL_GETS=$(fci success running) cirun checks --full "$fu")
[ "$s" = 4 ] || fail "forgejo pr checks --full with the declared task passed in a run still running must exit 4, got $s: $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with the declared task passed in a run still running"
s=$(CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist "$(frun 42 ci.yml 12 waiting $fc1 "$chead")")" "$(flist "$(ftask 60 test success 9 ci.yml $fold $osha)")")" cirun checks --full "$fu")
[ "$s" = 4 ] || fail "forgejo pr checks --full with no task yet and a waiting run past a zero wait must exit 4, got $s: $(cat "$tmp/err")"
grep -qxF "forge: check still pending: test" "$tmp/err" || fail "forgejo pr checks --full with no task yet must print 'forge: check still pending: test': $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with no task yet and a waiting run"
s=$(FORGE_PR_CHECK_WAIT=x CURL_GETS=$(fci success success) cirun checks --full "$fu")
[ "$s" = 1 ] && grep -qF "FORGE_PR_CHECK_WAIT must be a whole number of minutes, got 'x'" "$tmp/err" || fail "forgejo pr checks --full must reject a FORGE_PR_CHECK_WAIT that is not whole minutes, got $s: $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with a bad FORGE_PR_CHECK_WAIT"

fdeny='token does not have at least one of required scope(s): [read:repository]'
s=$(CURL_GETS="$(fgets "$(fpull "$chead")" "$(flist "$(frun 42 ci.yml 12 success $fc1 "$chead")")"; printf '403 %s\n' "$(jq -cn --arg m "$fdeny" '{message: $m, url: "https://forgejo.example.test/api/swagger"}')")" cirun checks --full "$fu")
[ "$s" = 1 ] || fail "forgejo pr checks --full with HTTP 403 on /actions/tasks must exit 1, got $s: $(cat "$tmp/err")"
grep -qF "HTTP 403: $fdeny" "$tmp/err" || fail "forgejo pr checks --full with HTTP 403 on /actions/tasks must print the Forgejo message: $(cat "$tmp/err")"
nostamp "forgejo pr checks --full with HTTP 403 on /actions/tasks"

for x in https://forgejo.example.test/evil/widget/pulls/7 https://forgejo.example.test/op/widget-fork/pulls/7 https://other.example.test/op/widget/pulls/7 \
  http://forgejo.example.test/op/widget/pulls/7 https://forgejo.example.test/op/widget/pull/7 https://github.com/op/widget/pull/7 7; do
  s=$(CURL_GETS=$(fci success success) cirun checks --full "$x")
  fallback "forgejo pr checks --full on $x, not a pull request of origin" "$s"
  nogh "forgejo pr checks --full on $x, not a pull request of origin"
done
printf -- '- All tests: `true`.\n' >"$ci/.forge/TESTING.md"
s=$(CURL_GETS=$(fci success success) cirun checks --full "$fu")
fallback "forgejo pr checks --full without a CI full suite line" "$s"
printf -- "$cidoc" >"$ci/.forge/TESTING.md"
git -C "$ci" remote set-url origin git@github.com:octo/forge.git

[ "$(cirun checks --full)" = 2 ] || fail "pr checks --full without a url must exit 2"
nogh "pr checks --full without a url"
[ "$(cirun checks --full "$cu" x)" = 2 ] || fail "pr checks --full with two urls must exit 2"
[ "$(cirun checks "$cu" --full)" = 2 ] || fail "pr checks <url> --full must exit 2"
[ "$(cirun merge --full "$cu")" = 2 ] || fail "pr merge --full must exit 2"
nostamp "a pr checks --full usage error"
unset FORGE_FORGEJO_ENV FORGE_PR_CHECK_INTERVAL FORGE_PR_CHECK_GRACE FORGE_PR_CHECK_WAIT
ok pr-ci
fi
finish
