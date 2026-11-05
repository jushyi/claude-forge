#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

loose() {
  local file=$1 filter=$2
  cp "$file" "$tmp/good"
  jq "$filter" "$tmp/good" >"$file"
  [ "$(code "$forge" validate "$file")" = 0 ] || fail "$file with $filter must pass the parse-only check: $(cat "$tmp/out")"
  printf '{' >"$file"
  [ "$(code "$forge" validate "$file")" = 1 ] || fail "unparsable $file must fail"
  grep -qF "$file: not JSON" "$tmp/out" || fail "unparsable $file must fail as not JSON: $(cat "$tmp/out")"
  cp "$tmp/good" "$file"
}

fresh
sp=$XDG_STATE_HOME/forge/p
h=$sp/history.json
cat >$h <<'EOF'
{
  "repos": [
    {
      "repo": "acme-hub",
      "milestones": [
        {"version": "v1.0", "name": "Launch", "done": true, "shipped": "2026-03-14", "phases": [{"number": "01", "name": "Scaffold"}, {"number": "41.1", "name": "Hotfix auth"}]},
        {"version": "v3.0", "name": "Rewrite", "done": true, "shipped": null, "phases": [{"number": "7", "name": "Router"}]}
      ]
    },
    {
      "repo": "acme-proxy",
      "milestones": [
        {"version": "v1", "name": "Proxy", "done": true, "shipped": "2026-05-02", "phases": []}
      ]
    },
    {
      "repo": "tpc_site.web",
      "milestones": [
        {"version": "v2", "name": "Redesign", "done": false, "shipped": null, "phases": [{"number": "03", "name": "Landing page"}]}
      ]
    }
  ]
}
EOF
[ "$(code "$forge" validate $h)" = 0 ] || fail "$h must validate: $(cat "$tmp/out")"
(cd "$sp" && "$forge" validate history.json) || fail "history.json from inside the state dir must validate"
loose $h '. + {"bogus": 1}'
loose $h 'del(.repos)'
loose $h '.repos[0].milestones[0].shipped = "14/03/2026"'
loose $h '.repos[0].milestones[0].phases[0].number = 1'
loose $h '.repos[0].repo = "../acme-hub"'
loose $h 'del(.repos[0].milestones)'
ok history-validate

q=$sp/quicks.json
echo '{"quicks": [{"slug": "fix-typo", "task": "fix the footer typo", "repos": ["acme-hub"], "date": "2026-10-20"}]}' >$q
[ "$(code "$forge" validate $q)" = 0 ] || fail "$q must validate: $(cat "$tmp/out")"
(cd "$sp" && "$forge" validate quicks.json) || fail "quicks.json from inside the state dir must validate"
loose $q '.quicks[0].bogus = 1'
ok quicks-validate
finish
