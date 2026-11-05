#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../forge-common.sh"

repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.name forge && git -C "$1" config user.email forge@example.com
  git -C "$1" commit -q --allow-empty -m init
}
render() { jq -j -L "$root/bin/forge.d" --rawfile tpl "$root/templates/CONCERNS.md" 'include "forge"; concerns_doc($tpl)' "$1"; }
paths() { git -C "$1" show --name-only --format= HEAD | sort | paste -sd' '; }
today=$(date +%F)

webrepo() { fresh; repo web && repo api && mkdir -p web/.forge; }

if want first; then
webrepo
echo staged >web/other.txt && git -C web add other.txt
out=$("$forge" concern add web intake high src/intake.ts src/form.ts -- 'Intake trusts the client email unchecked') || fail "concern add on a missing concerns.json: $out"
[ "$out" = "added web:C-01" ] || fail "first concern prints added web:C-01: $out"
want=$(jq -cnS --arg d "$today" '{concerns: [{id: "C-01", area: "intake", files: ["src/intake.ts", "src/form.ts"], severity: "high", evidence: [], status: "open", text: "Intake trusts the client email unchecked", date: $d}]}')
[ "$(json web/.forge/concerns.json)" = "$want" ] || fail "concerns.json holds the new concern: $(cat web/.forge/concerns.json)"
"$forge" validate web/.forge/concerns.json || fail "the written concerns.json validates"
diff -u <(render web/.forge/concerns.json) web/.forge/CONCERNS.md || fail "CONCERNS.md is concerns_doc of concerns.json"
grep -q -- '^- C-01 — intake — src/intake.ts, src/form.ts — high — .* — open — Intake trusts the client email unchecked$' web/.forge/CONCERNS.md || fail "CONCERNS.md line shows the text: $(cat web/.forge/CONCERNS.md)"
[ "$(git -C web log -1 --format=%s)" = "docs(concerns): add web:C-01" ] || fail "commit subject: $(git -C web log -1 --format=%s)"
[ "$(paths web)" = ".forge/CONCERNS.md .forge/concerns.json" ] || fail "commit holds exactly the two paths: $(paths web)"
[ "$(git -C web status --porcelain)" = "A  other.txt" ] || fail "an unrelated staged file stays staged, uncommitted: $(git -C web status --porcelain)"
[ ! -e api/.forge ] || fail "another repo is untouched"
[ "$(git -C api rev-list --count HEAD)" = 1 ] || fail "another repo gets no commit"
git -C web reset -q other.txt && rm web/other.txt
ok first
fi

if want next-id; then
webrepo
jq '.concerns[0].id = "C-07" | .concerns[1].id = "C-03"' "$fx/map/concerns.json" >web/.forge/concerns.json
render web/.forge/concerns.json >web/.forge/CONCERNS.md
git -C web add .forge && git -C web commit -qm gaps
jq -c '.concerns' web/.forge/concerns.json >"$tmp/before"
out=$("$forge" concern add web queue low src/queue.ts -- 'Queue drops retries') || fail "concern add past gaps: $out"
[ "$out" = "added web:C-08" ] || fail "next id is the highest + 1 past gaps: $out"
[ "$(jq -c '.concerns[:-1]' web/.forge/concerns.json)" = "$(cat "$tmp/before")" ] || fail "existing concerns are kept unchanged: $(cat web/.forge/concerns.json)"
[ "$(jq -cS '.concerns[-1]' web/.forge/concerns.json)" = "$(jq -cnS --arg d "$today" '{id: "C-08", area: "queue", files: ["src/queue.ts"], severity: "low", evidence: [], status: "open", text: "Queue drops retries", date: $d}')" ] || fail "appended concern: $(jq -c '.concerns[-1]' web/.forge/concerns.json)"
"$forge" validate web/.forge/concerns.json || fail "concerns.json with old and new concerns validates"
diff -u <(render web/.forge/concerns.json) web/.forge/CONCERNS.md || fail "CONCERNS.md re-rendered past gaps"
grep -qxF -- '- C-07 — intake — src/intake.ts — high — security, pii — `src/intake.ts:12` — open' web/.forge/CONCERNS.md || fail "an old concern without text renders as before: $(cat web/.forge/CONCERNS.md)"
jq '.concerns[0].id = "C-99"' "$fx/map/concerns.json" >web/.forge/concerns.json
render web/.forge/concerns.json >web/.forge/CONCERNS.md
git -C web add .forge && git -C web commit -qm c99
[ "$("$forge" concern add web cache medium src/cache.ts -- 'Cache never expires')" = "added web:C-100" ] || fail "the id after C-99 is C-100: $(cat web/.forge/concerns.json)"
[ "$("$forge" concern add web cache medium src/cache.ts -- 'Cache key collides')" = "added web:C-101" ] || fail "ids compare by number past C-99: $(jq -c '[.concerns[].id]' web/.forge/concerns.json)"
[ "$(git -C web log -1 --format=%s)" = "docs(concerns): add web:C-101" ] || fail "commit subject after C-100: $(git -C web log -1 --format=%s)"
"$forge" validate web/.forge/concerns.json || fail "concerns.json past C-99 validates"
ok next-id
fi

if want worktree; then
fresh
rm -rf "$tmp/s" && mkdir -p "$tmp/s" && project "$tmp/s/p"
(cd "$tmp/s" && repo p && git -C p add -A && git -C p commit -qm fixture)
git -C "$tmp/s/p" worktree add -q -b phase "$tmp/s/wt/p"
cd "$tmp/s/wt/p"
jq '.concerns[1].id = "C-05"' "$fx/map/concerns.json" >.forge/concerns.json
git add .forge/concerns.json && git commit -qm "branch concerns"
wt=$(git rev-parse HEAD) main=$(git -C "$tmp/s/p" rev-parse HEAD)
out=$("$forge" concern add p intake medium src/intake.ts -- 'Found while in a phase') || fail "concern add from a linked worktree: $out"
[ "$out" = "added p:C-01" ] || fail "the id comes from the main checkout's concerns.json, not the worktree's: $out"
[ "$(git rev-parse HEAD)" = "$wt" ] || fail "the phase branch gets no commit"
[ -z "$(git status --porcelain)" ] || fail "the worktree is left untouched: $(git status --porcelain)"
[ "$(jq -c '[.concerns[].id]' .forge/concerns.json)" = '["C-01","C-05"]' ] || fail "the worktree's concerns.json is unchanged"
m=$tmp/s/p
[ "$(json "$m/.forge/concerns.json")" = "$(jq -cnS --arg d "$today" '{concerns: [{id: "C-01", area: "intake", files: ["src/intake.ts"], severity: "medium", evidence: [], status: "open", text: "Found while in a phase", date: $d}]}')" ] || fail "the main checkout's concerns.json holds the concern: $(cat "$m/.forge/concerns.json" 2>&1)"
diff -u <(render "$m/.forge/concerns.json") "$m/.forge/CONCERNS.md" || fail "the main checkout's CONCERNS.md is re-rendered"
[ "$(git -C "$m" rev-parse HEAD^)" = "$main" ] || fail "the main checkout gets exactly one commit"
[ "$(git -C "$m" rev-parse --abbrev-ref HEAD)" = main ] || fail "the main checkout stays on main"
[ "$(git -C "$m" log -1 --format=%s)" = "docs(concerns): add p:C-01" ] || fail "main checkout commit subject: $(git -C "$m" log -1 --format=%s)"
[ "$(paths "$m")" = ".forge/CONCERNS.md .forge/concerns.json" ] || fail "main checkout commit holds exactly the two paths: $(paths "$m")"
[ -z "$(git -C "$m" status --porcelain)" ] || fail "the main checkout is clean: $(git -C "$m" status --porcelain)"
[ "$("$forge" concern add p queue low src/queue.ts -- 'Second from the phase')" = "added p:C-02" ] || fail "a second add from the worktree reads the main checkout"
[ "$(git -C "$m" log -1 --format=%s)" = "docs(concerns): add p:C-02" ] || fail "second main checkout commit"
cd "$tmp/p"
ok worktree
fi

snap() { { cat web/.forge/concerns.json web/.forge/CONCERNS.md; git -C web rev-parse HEAD; git -C web status --porcelain; ls -A web/.forge; } 2>&1; }
nothing() { [ "$(snap)" = "$before" ] || fail "$1 writes nothing"; }

if want usage; then
webrepo
before=$(snap)
while IFS= read -r line; do
  eval "set -- $line"
  [ "$(code "$forge" concern "$@")" = 2 ] || fail "forge concern $line must exit 2, got $(cat "$tmp/out")"
  nothing "forge concern $line"
done <<'EOF'
add
bogus web intake high src/a.ts -- text
add web
add web intake
add web intake high
add web intake high src/a.ts
add web intake high src/a.ts text
add web intake high -- text
add web '' high src/a.ts -- text
add web intake high src/a.ts --
add web intake high src/a.ts -- ''
add web intake critical src/a.ts -- text
add web intake HIGH src/a.ts -- text
add web intake '' src/a.ts -- text
EOF
ok usage
fi

if want unknown-repo; then
webrepo
before=$(snap)
s=$(code "$forge" concern add nope intake high src/a.ts -- text)
[ "$s" != 0 ] || fail "an unknown repo must fail"
[ -s "$tmp/out" ] || fail "an unknown repo prints an error"
grep -q nope "$tmp/out" || fail "the error names the repo: $(cat "$tmp/out")"
[ ! -e nope ] || fail "an unknown repo creates nothing"
nothing "an unknown repo"
ok unknown-repo
fi

if want invalid-json; then
webrepo
printf '{"concerns": [' >web/.forge/concerns.json
before=$(snap)
s=$(code "$forge" concern add web intake high src/a.ts -- text)
[ "$s" != 0 ] || fail "an invalid concerns.json must fail"
[ -s "$tmp/out" ] || fail "an invalid concerns.json prints an error"
nothing "an invalid concerns.json"
ok invalid-json
fi

snap() { { cat web/.forge/concerns.json web/.forge/CONCERNS.md; git -C web rev-parse HEAD; git -C web status --porcelain; git -C web ls-files -s .forge; ls -A web/.forge; } 2>&1; }
if want failed-commit; then
webrepo
jq '.concerns[0].id = "C-04"' "$fx/map/concerns.json" >web/.forge/concerns.json
render web/.forge/concerns.json >web/.forge/CONCERNS.md
git -C web add .forge && git -C web commit -qm restored
mkdir -p "$tmp/hooks" && printf '#!/bin/sh\nexit 1\n' >"$tmp/hooks/pre-commit" && chmod +x "$tmp/hooks/pre-commit"
git -C web config core.hooksPath "$tmp/hooks"
before=$(snap)
s=$(code "$forge" concern add web intake high src/a.ts -- 'Rejected by a hook')
[ "$s" != 0 ] || fail "a failed commit must fail"
nothing "a failed commit"
rm -f web/.forge/CONCERNS.md && git -C web rm -q --cached .forge/CONCERNS.md
before=$(snap)
s=$(code "$forge" concern add web intake high src/a.ts -- 'Rejected by a hook')
[ "$s" != 0 ] || fail "a failed commit without CONCERNS.md must fail"
nothing "a failed commit without CONCERNS.md"
git -C web commit -qm "drop CONCERNS.md" --no-verify
git -C web config --unset core.hooksPath
[ "$("$forge" concern add web intake high src/a.ts -- 'Rejected by a hook')" = "added web:C-05" ] || fail "a retry after a failed commit takes the same id: $(jq -c '[.concerns[].id]' web/.forge/concerns.json)"
[ "$(jq '[.concerns[] | select(.text == "Rejected by a hook")] | length' web/.forge/concerns.json)" = 1 ] || fail "a retry adds the concern once"
[ -z "$(git -C web status --porcelain)" ] || fail "the retry leaves web clean: $(git -C web status --porcelain)"
ok failed-commit
fi

if want markdown-only; then
webrepo
jq '.concerns[0].id = "C-04"' "$fx/map/concerns.json" >web/.forge/concerns.json
render web/.forge/concerns.json >web/.forge/CONCERNS.md
git -C web add .forge && git -C web commit -qm restored
printf -- '- C-09 — legacy — src/old.ts — medium — — `src/old.ts:3` — open\n- C-11 — legacy — src/older.ts — low — — — open\n' >>web/.forge/CONCERNS.md
git -C web add .forge/CONCERNS.md && git -C web commit -qm "markdown-only concerns"
before=$(snap)
s=$(code "$forge" concern add web intake high src/a.ts -- 'Would erase markdown-only concerns')
[ "$s" != 0 ] || fail "a CONCERNS.md with concerns missing from concerns.json must fail"
grep -q 'C-09, C-11' "$tmp/out" || fail "the error names the markdown-only concerns: $(cat "$tmp/out")"
nothing "a CONCERNS.md with markdown-only concerns"
ok markdown-only
fi

if want open-only; then
fresh
jq '.concerns[1].status = "resolved"' "$fx/map/concerns.json" >"$tmp/oo.json"
{ cat "$root/templates/CONCERNS.md"; printf '\n%s\n' '- C-01 — intake — src/intake.ts — high — security, pii — `src/intake.ts:12` — open'; } >"$tmp/oo.want"
diff -u "$tmp/oo.want" <(render "$tmp/oo.json") || fail "a resolved concern is left out of CONCERNS.md, the open one kept"
jq '.concerns[].status = "resolved"' "$fx/map/concerns.json" >"$tmp/oo.json"
{ cat "$root/templates/CONCERNS.md"; printf '\n—\n'; } >"$tmp/oo.want"
diff -u "$tmp/oo.want" <(render "$tmp/oo.json") || fail "zero open concerns render the dash placeholder"
ok open-only
fi

if want help; then
"$forge" --help | grep -qE '^  concern( |$)' || fail "forge --help lists concern"
"$forge" concern --help >"$tmp/help" || fail "forge concern --help: $(cat "$tmp/help")"
grep -q '^Usage: forge concern add <repo> <area> <severity> <files\.\.\.> -- <text>' "$tmp/help" || fail "forge concern --help prints its usage: $(head -3 "$tmp/help")"
for s in concerns.json CONCERNS.md 'docs(concerns): add' '^Example'; do
  grep -q -- "$s" "$tmp/help" || fail "forge concern --help names $s"
done
ok help
fi
finish
