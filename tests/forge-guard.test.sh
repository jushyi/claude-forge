#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
hook=$root/hooks/forge-guard.sh
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
unset FORGE_ROOT FORGE_PHASE
export HOME=$tmp/home XDG_STATE_HOME=$tmp/state LC_ALL=C GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
mkdir -p "$HOME/.local/state/forge" && jq -n --arg s "$HOME/Projects/forge" '{source: $s}' >"$HOME/.local/state/forge/port.json"

fail() { echo "forge-guard: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "forge-guard $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() { local c; [ -z "$only" ] && return 0; for c; do [ "$only" = "$c" ] && return 0; done; return 1; }

sh_in() { jq -nc --arg d "$1" --arg c "$2" --arg a "${3:-}" \
  '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
ed_in() { jq -nc --arg d "$1" --arg p "$2" --arg a "${3:-}" --arg t "${4:-Write}" \
  '{hook_event_name: "PreToolUse", session_id: "s", tool_name: $t, cwd: $d,
    tool_input: (if $t == "NotebookEdit" then {notebook_path: $p} else {file_path: $p} end)}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
tool_in() { jq -nc --arg d "$1" --arg t "$2" --arg a "${3:-}" '{hook_event_name: "PreToolUse", tool_name: $t, cwd: $d, tool_input: {}}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
big_in() { jq -Rsc --arg d "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: .}}'; }

run() { local s=0; "$hook" ${mode:+"$mode"} <<<"$1" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
deny() {
  local s
  s=$(run "$2")
  [ "$s" = 2 ] || fail "$3 must be denied (exit $s): $(cat "$tmp/err")"
  [ "$(wc -l <"$tmp/err")" = 1 ] || fail "$3 must print one line: $(cat "$tmp/err")"
  grep -q "^forge-guard: $1: " "$tmp/err" || fail "$3 must name rule $1: $(cat "$tmp/err")"
}
allow() {
  local s
  s=$(run "$1")
  [ "$s" = 0 ] || fail "$2 must be allowed (exit $s): $(cat "$tmp/err")"
  [ ! -s "$tmp/err" ] || fail "$2 must print nothing: $(cat "$tmp/err")"
}

R=$tmp/proj
S=$XDG_STATE_HOME/forge/proj
mkdir -p "$R/.forge" "$R/src" "$S/phases/07-x" "$S/features/t-f"
git -C "$R" init -q -b main
echo x >"$R/.forge/PROJECT.md"
echo x >"$R/src/a.txt"
git -C "$R" add -A
git -C "$R" commit -qm init
wt=$R/.claude/worktrees/feat-7
git -C "$R" worktree add -q -b forge/feat-7 "$wt"
plain=$tmp/plain
mkdir -p "$plain"
git -C "$plain" init -q -b main
git -C "$plain" commit -q --allow-empty -m init
gitplain=$R/.git/forge-test/tmp/1/plain
mkdir -p "$gitplain"
git -C "$gitplain" init -q -b main
git -C "$gitplain" commit -q --allow-empty -m init

if want root-checkout; then
for c in 'git switch x' 'git switch -c x' 'git checkout main' 'git checkout -b x' 'git checkout -B x' \
  'git checkout -- src/a.txt' 'git checkout src/a.txt' 'git stash' 'git stash pop' 'git stash push -m tag' \
  'git reset --hard' 'git reset --keep HEAD~1' 'git reset --merge' 'git rebase main' 'git cherry-pick abc' \
  'git merge x' 'git merge --ff-only x' 'git rebase --continue' 'git pull' 'git pull --ff-only origin main' 'git commit --amend --no-edit' \
  'git reset HEAD~1' 'git reset --soft HEAD~1' 'git reset --mixed HEAD~1' 'git reset' 'git reset HEAD src/a.txt' 'git reset -- src/a.txt' \
  'git branch -m other' 'git branch -M other' \
  'git status && git switch main' 'git status; git stash' 'git log | git merge x' $'git status\ngit switch x' \
  'git --no-pager -c core.pager=cat checkout main' 'FOO=1 git pull' 'env FOO=1 git rebase main' \
  '(git reset --hard)' 'git status 2>&1 && git switch x' "bash -c 'git status && git checkout main'"; do
  deny root-checkout "$(sh_in "$R" "$c")" "in R: $c"
done
deny root-checkout "$(sh_in "$R/src" 'git switch x')" "from a subdirectory of R"
deny root-checkout "$(sh_in "$R" 'git switch x' forge-fixer)" "a subagent in R"
for c in "git -C $R switch x" "cd $R && git switch x" "cd $R; git stash" "echo hi | git -C $R merge x" \
  "bash -c 'cd $R && git checkout main'" "sh -c \"git -C $R rebase main\"" "(cd $R && git reset --hard)" \
  "cd $R/src && git -C .. stash" "git -C $R/src -C .. pull"; do
  deny root-checkout "$(sh_in "$plain" "$c")" "from elsewhere: $c"
done
for c in "git --git-dir $R/.git --work-tree $R switch x" "git --git-dir=$R/.git switch x" "git --work-tree=$R --git-dir=$R/.git rebase main" \
  "GIT_DIR=$R/.git git switch x" "env GIT_DIR=$R/.git GIT_WORK_TREE=$R git merge x" "GIT_DIR=$R/.git git -C $plain pull" \
  "cd $tmp && GIT_DIR=proj/.git git switch x" "git -C $tmp --git-dir proj/.git switch x" "GIT_DIR=$R/.git bash -c 'git switch x'"; do
  deny root-checkout "$(sh_in "$plain" "$c")" "git dir option from elsewhere: $c"
done
for c in "git --git-dir=$plain/.git --work-tree=$plain switch x" "GIT_DIR=$plain/.git GIT_WORK_TREE=$plain git switch x" "git --git-dir=$R/.git/worktrees/feat-7 --work-tree=$wt switch x"; do
  allow "$(sh_in "$R" "$c")" "git dir option aimed away from R: $c"
done
deny conventional-commit "$(sh_in "$plain" "GIT_DIR=$R/.git git commit -m wip")" "a commit aimed at R by GIT_DIR"
deny root-checkout "$(sh_in "$tmp" 'cd proj && git switch x')" "relative cd into R"
for d in "$R" "$wt" "$plain"; do
  for c in "git -C $R branch -f main HEAD~1" "git -C $R branch --force main x" "git -C $R branch -D main" "git -C $R branch -d x main" \
    "git -C $R branch -M main old" "git -C $R branch -m old main" "git -C $R branch -C x main" "git -C $wt branch -f main HEAD~1" \
    "git -C $R update-ref refs/heads/main HEAD~1" "git -C $R update-ref -d refs/heads/main" "git -C $wt update-ref refs/heads/main x y"; do
    deny main-ref "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
grep -q 'forge land' "$tmp/err" || fail "main-ref reason must point at forge land: $(cat "$tmp/err")"
for c in 'git branch -f main HEAD~1' 'git update-ref refs/heads/main HEAD~1' 'git branch -D main'; do
  allow "$(sh_in "$plain" "$c")" "main of a non-forge repo: $c"
done
allow "$(sh_in "$wt" 'git branch -m other')" "renaming a worktree's own branch"
for c in 'git restore src/a.txt' 'git restore --staged src/a.txt' 'git restore --worktree --source HEAD~1 .' 'git restore -SW .' \
  'git restore .' 'git clean -fd' 'git clean -n' 'git clean -xfd src' 'git checkout .' 'git checkout -- .' 'xargs -r git restore'; do
  deny root-checkout "$(sh_in "$R" "$c")" "in R: $c"
  allow "$(sh_in "$wt" "$c")" "in a linked worktree: $c"
  allow "$(sh_in "$plain" "$c")" "in a non-forge repo: $c"
done
for d in "$R" "$wt" "$plain"; do
  for c in "git -C $R update-ref --stdin" "git -C $wt update-ref --stdin -z" "git -C $R update-ref -m msg refs/heads/main x" \
    "git -C $R update-ref HEAD x" "git -C $R update-ref -d HEAD" "git -C $R update-ref --no-deref HEAD x" "git -C $wt update-ref --no-deref HEAD x" \
    "git -C $R symbolic-ref HEAD refs/heads/x" "git -C $wt symbolic-ref HEAD refs/heads/other" "git -C $R symbolic-ref refs/heads/main refs/heads/x" \
    "git -C $R symbolic-ref -m m HEAD refs/heads/x" "git -C $R symbolic-ref --delete HEAD" "git -C $wt symbolic-ref -d refs/heads/main" \
    "timeout 5 git -C $R update-ref --stdin"; do
    deny main-ref "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
for d in "$R" "$wt"; do
  for c in 'git symbolic-ref HEAD' 'git symbolic-ref -q HEAD' 'git symbolic-ref --short HEAD' 'git symbolic-ref -q --short HEAD' \
    'git symbolic-ref --no-recurse HEAD' 'git update-ref refs/heads/forge/x refs/heads/main' 'git update-ref -m main refs/heads/forge/x HEAD' \
    "git symbolic-ref refs/heads/alias refs/heads/forge/feat-7"; do
    allow "$(sh_in "$d" "$c")" "in $d: $c"
  done
done
allow "$(sh_in "$wt" 'git update-ref HEAD x')" "moving a linked worktree's own branch through HEAD"
for c in 'git update-ref --stdin' 'git symbolic-ref HEAD refs/heads/x' 'git update-ref HEAD x' 'git symbolic-ref -d HEAD'; do
  allow "$(sh_in "$plain" "$c")" "in a non-forge repo: $c"
done
deny root-checkout "$(sh_in "$tmp" 'git -C proj switch x')" "relative -C into R"
grep -q 'worktree' "$tmp/err" || fail "root-checkout reason must point at a worktree"
grep -q 'forge land' "$tmp/err" || fail "root-checkout reason must point at forge land"

for c in 'git status' 'git log --oneline' 'git checkout' 'git merge --abort' 'git merge --quit' 'git rebase --abort' \
  'git rebase --quit' 'git cherry-pick --abort' 'git cherry-pick --quit' 'git branch -D forge/x' 'git branch -f forge/x main' \
  'git branch x main' 'git branch -m forge/a forge/b' 'git branch -c main forge/copy' 'git update-ref refs/heads/forge/x HEAD' \
  'git stash list' 'git stash show' 'git merge-base a b' 'git worktree add .claude/worktrees/x -b x' \
  'echo "git switch x"' "echo 'git stash'" 'git log --grep "git stash"' 'git diff main...HEAD' \
  "git commit -m 'fix: drop git stash; git reset --hard in R'" \
  $'cat > notes.txt <<\'EOF\'\ngit switch x\nit\'s fine\nEOF' $'cat > notes.txt <<EOF\ngit stash\nEOF\ngit status' \
  "git -C $plain switch x" "cd $wt && git switch x" "git -C $wt rebase main"; do
  allow "$(sh_in "$R" "$c")" "in R: $c"
done
for c in 'git switch x' 'git rebase main' 'git reset --hard' 'git commit --amend --no-edit' 'git checkout -- a'; do
  allow "$(sh_in "$wt" "$c")" "in a linked worktree: $c"
  allow "$(sh_in "$plain" "$c")" "in a non-forge repo: $c"
done
allow "$(sh_in "$tmp/nowhere" 'git switch x')" "a cwd that does not exist"
ok root-checkout
fi

if want wrappers; then
for c in 'env -i git reset --hard' 'env -u X git switch x' 'env -uX git pull' 'env -iu X git pull' 'env --unset=X git pull' \
  'env --unset X git pull' 'env - git pull' 'env -- git pull' 'env FOO=1 git reset --hard' 'env -i FOO=1 git pull' \
  'timeout 5 git reset --hard' 'timeout -s KILL 5 git reset --hard' 'timeout --signal=KILL 5s git pull' 'timeout --signal KILL 5 git pull' \
  'timeout -k 1 --preserve-status 5 git pull' 'timeout -sKILL 5 git pull' 'nice -n 5 git pull' 'nice -n5 git pull' 'nice -5 git pull' \
  'nice --adjustment=5 git pull' 'nice git pull' 'nohup git pull' 'nohup -- git pull' 'command git pull' 'command -p git pull' \
  'exec git pull' 'exec -a x git pull' 'exec -c git pull' 'stdbuf -oL git pull' 'stdbuf -o L -e0 git pull' 'stdbuf --output=L git pull' \
  'time git pull' 'time -p git pull' '/usr/bin/time -f %e -o t.txt git pull' 'xargs git reset --hard' 'xargs -0 -n 1 git checkout --' \
  'xargs -I{} git checkout {}' 'xargs -I {} git checkout {}' 'xargs --max-args 1 git switch' 'xargs -r -P 2 git merge x' \
  'timeout 5 env -i nice -n 5 git pull' "timeout 5 bash -c 'git pull'" '/usr/bin/env -i git pull' 'env -S "git reset --hard"' \
  'env -C src git pull' 'git status && timeout 5 git pull'; do
  deny root-checkout "$(sh_in "$R" "$c")" "a wrapped git in R: $c"
done
for c in "env -C $R git switch x" "env --chdir=$R git switch x" "env --chdir $R/src git pull" "env -iC $R git pull" "env -C $tmp -C proj git pull"; do
  deny root-checkout "$(sh_in "$plain" "$c")" "env chdir into R: $c"
done
for c in 'env -i git status' 'timeout 5 git status' 'timeout -s KILL 5 git log' 'xargs git log' 'nice -n 5 make' 'timeout 5 sleep 1' \
  'env -u GIT_DIR git status' 'env -u git pull' 'command -v git' 'time make test' 'xargs -n1 echo' 'nohup ./run.sh' 'stdbuf -oL tail -f x' \
  'timeout 5' 'env' 'xargs' 'nohup' 'exec 3>&1' 'time' "env -C $plain git switch x" "cd $plain && env -C $R git status"; do
  allow "$(sh_in "$R" "$c")" "in R: $c"
done
for c in 'env -i git reset --hard' 'timeout 5 git switch x' 'xargs git checkout --' 'nice -n 5 git pull'; do
  allow "$(sh_in "$plain" "$c")" "a wrapped git in a non-forge repo: $c"
done
deny conventional-commit "$(sh_in "$R" 'timeout 60 git commit -m wip')" "a wrapped commit"
deny stash "$(sh_in "$wt" 'nice git stash')" "a wrapped stash"
deny main-ref "$(sh_in "$wt" 'env -i git branch -f main HEAD~1')" "a wrapped main move"
for d in "$R" "$wt"; do
  for c in "env -S 'bash -c \"git update-ref refs/heads/main HEAD\"'" "env -S \"sh -c 'git -C $R branch -D main'\"" \
    "env --split-string='timeout 5 bash -c \"git update-ref refs/heads/main HEAD\"'" \
    "printf 'refs/heads/main HEAD\n' | xargs git update-ref" 'xargs git update-ref -m msg' 'echo HEAD x | xargs git symbolic-ref' \
    'xargs env git update-ref' 'xargs -n 2 timeout 5 git update-ref'; do
    deny main-ref "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
deny main-ref "$(sh_in "$wt" 'xargs -r git branch -d')" "an xargs branch delete in a worktree"
deny root-checkout "$(sh_in "$R" 'xargs -r git branch -d')" "an xargs branch delete in R"
for c in 'xargs git' 'xargs -I{} git {} refs/heads/main HEAD'; do
  deny main-ref "$(sh_in "$wt" "$c")" "an xargs-supplied subcommand in a worktree: $c"
  deny root-checkout "$(sh_in "$R" "$c")" "an xargs-supplied subcommand in R: $c"
done
for c in 'xargs git checkout' 'xargs git commit' 'xargs git rebase --abort' 'xargs git stash list' 'xargs -0 git reset' \
  "env -S \"sh -c 'git switch x'\""; do
  deny root-checkout "$(sh_in "$R" "$c")" "in R: $c"
  allow "$(sh_in "$wt" "$c")" "in a linked worktree: $c"
done
for c in 'xargs git update-ref' 'xargs git symbolic-ref' 'xargs git branch -D' 'xargs git' 'xargs git checkout' \
  "env -S 'bash -c \"git update-ref refs/heads/main HEAD\"'"; do
  allow "$(sh_in "$plain" "$c")" "in a non-forge repo: $c"
done
for c in 'xargs grep x' 'xargs rm -f' 'xargs rm -rf /tmp/x' 'git ls-files | xargs wc -l' 'xargs git log' 'xargs git show' \
  'xargs -I{} git log {}' 'xargs -n1 git diff --stat' 'xargs cp -t /tmp/out' 'xargs sed -i s/a/b/' "env -S 'git status'" \
  "env -S 'bash -c \"git log --oneline\"'" 'env -S "echo a  b"'; do
  allow "$(sh_in "$R" "$c")" "in R: $c"
  allow "$(sh_in "$wt" "$c")" "in a linked worktree: $c"
done
ok wrappers
fi

if want stash; then
deny stash "$(sh_in "$wt" 'git stash')" "stash in a forge worktree"
deny stash "$(sh_in "$wt/src" 'git stash push -u -m tag')" "stash from a subdirectory of a forge worktree"
deny stash "$(sh_in "$wt" 'git status && git stash pop' forge-fixer)" "stash from a subagent"
deny stash "$(sh_in "$plain" "git -C $wt stash")" "stash aimed at a forge worktree"
grep -q 'stack' "$tmp/err" || fail "stash reason must name the shared stack"
FORGE_ROOT=$R deny stash "$(sh_in "$plain" 'git stash')" "stash in a forge-launched session"
allow "$(sh_in "$plain" 'git stash')" "stash outside forge"
allow "$(sh_in "$gitplain" 'git stash')" "stash in a repo under a forge project's .git directory"
allow "$(sh_in "$wt" 'git stash list')" "stash list in a forge worktree"
allow "$(sh_in "$wt" 'git log --grep stash')" "a stash mention"
ok stash
fi

if want polling; then
FORGE_PHASE=7 deny polling "$(tool_in "$wt" ScheduleWakeup)" "ScheduleWakeup in a forge phase session"
FORGE_ROOT=$R deny polling "$(tool_in "$R/src" CronCreate)" "CronCreate in a forge-launched session"
grep -q "wait for the agent's completion notification; don't poll" "$tmp/err" || fail "polling reason: $(cat "$tmp/err")"
FORGE_ROOT=$R deny polling "$(tool_in "$plain" CronCreate)" "CronCreate in a forge-launched session outside the project"
allow "$(tool_in "$wt" ScheduleWakeup)" "ScheduleWakeup in an operator session in a forge worktree"
allow "$(tool_in "$R/src" CronCreate)" "CronCreate in an operator session in a forge project"
allow "$(tool_in "$plain" ScheduleWakeup)" "ScheduleWakeup outside forge"
FORGE_PHASE=7 deny polling "$(tool_in "$wt" ReadNotifications)" "ReadNotifications in a forge phase session"
grep -q "wait for the agent's completion notification; don't poll" "$tmp/err" || fail "ReadNotifications polling reason: $(cat "$tmp/err")"
FORGE_ROOT=$R deny polling "$(tool_in "$plain" ReadNotifications)" "ReadNotifications in a forge-launched session outside the project"
FORGE_PHASE=7 allow "$(tool_in "$wt" ReadNotifications forge-fixer)" "ReadNotifications from a subagent of a forge phase session"
FORGE_ROOT=$R allow "$(tool_in "$R/src" ReadNotifications forge-implementer)" "ReadNotifications from a subagent of a forge-launched session"
allow "$(tool_in "$wt" ReadNotifications)" "ReadNotifications in an operator session in a forge worktree"
allow "$(tool_in "$plain" ReadNotifications)" "ReadNotifications outside forge"
FORGE_PHASE=1 allow "$(tool_in "$wt" ListAgents)" "ListAgents in a forge phase session"
FORGE_ROOT=$R allow "$(tool_in "$R/src" ListAgents)" "ListAgents in a forge-launched session"
FORGE_PHASE=7 allow "$(tool_in "$wt" ListAgents forge-fixer)" "ListAgents from a subagent of a forge phase session"
allow "$(tool_in "$plain" ListAgents)" "ListAgents outside forge"
for c in 'sleep 30' 'sleep 5 && ls' '/usr/bin/sleep 2' 'git status; sleep 1' 'claude agents --json' 'claude agents --json --all' \
  "claude --settings '{}' agents --json" 'claude --dangerously-skip-permissions agents' '/usr/bin/claude agents --json' \
  'command claude agents --json' 'ls && claude agents' 'claude --effort medium agents --json' 'claude -n worker agents --json' \
  'claude --name worker agents' 'claude -w wt agents --json' 'claude --resume --verbose agents' 'claude --effort=high agents'; do
  FORGE_PHASE=7 deny polling "$(sh_in "$wt" "$c")" "the main agent of a forge phase session: $c"
  FORGE_ROOT=$R deny polling "$(sh_in "$R/src" "$c")" "the main agent of a forge-launched session: $c"
  FORGE_ROOT=$R deny polling "$(sh_in "$plain" "$c")" "the main agent of a forge-launched session outside the project: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c" forge-fixer)" "a subagent of a forge phase session: $c"
  FORGE_ROOT=$R allow "$(sh_in "$R/src" "$c" forge-implementer)" "a subagent of a forge-launched session: $c"
  allow "$(sh_in "$wt" "$c")" "an operator session in a forge worktree: $c"
  allow "$(sh_in "$plain" "$c")" "outside forge: $c"
done
for c in "bash -c 'sleep 1'" "timeout 5 bash -c 'until x; do sleep 1; done'" 'claude agent' 'claude --bg "x"' 'claude attach ID' \
  'claude stop ID' 'claude -p "list agents"' 'echo sleep' 'grep -r "claude agents" .' 'claude -n agents' 'claude --resume agents'; do
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "the main agent of a forge phase session: $c"
  FORGE_ROOT=$R allow "$(sh_in "$R/src" "$c")" "the main agent of a forge-launched session: $c"
done
pw='while pgrep -f "tools/test-display.sh" >/dev/null; do sleep 5; done'
pu='until ! pgrep -f "tools/test-display.sh"; do sleep 5; done'
pt='while pgrep -f "tools/test-display.sh" >/dev/null; do for p in $(pgrep -f "tools/test-display.sh"); do tail --pid=$p -f /dev/null; done; done'
FORGE_PHASE=7 deny polling "$(sh_in "$wt" "$pw")" "a while-pgrep loop in a forge phase session"
FORGE_ROOT=$R deny polling "$(sh_in "$R/src" "$pu")" "an until-pgrep loop in a forge-launched session"
FORGE_ROOT=$R FORGE_PHASE=11 deny polling "$(sh_in "$plain" "$pt")" "a pgrep and tail --pid loop in a forge-launched session"
for c in "$pw" "$pu" "$pt"; do
  deny polling "$(sh_in "$wt" "$c")" "a pgrep loop in an operator session: $c"
  ! grep -q 'forge-launched' "$tmp/err" || fail "polling reason must not name a forge-launched session: $(cat "$tmp/err")"
  ! grep -qi 'escalat' "$tmp/err" || fail "polling reason must not name Escalate: $(cat "$tmp/err")"
done
for c in "$pw" "$pu" 'while ps aux | grep -q x; do sleep 5; done' 'until ! ps -p 42 >/dev/null; do sleep 5; done' \
  'while [ -n "$(pgrep -f x)" ]; do sleep 5; done' 'until [ -z "$(ps -C x -o pid=)" ]; do sleep 5; done' \
  "bash -c 'until ! pgrep -f x; do sleep 5; done'" "timeout 600 bash -c 'while pgrep -f x >/dev/null; do sleep 5; done'" \
  "timeout 60 sh -c 'while [ -n \"\$(pgrep -f x)\" ]; do sleep 5; done'" "timeout 600 bash -c 'while ps -p 42 >/dev/null; do sleep 5; done'"; do
  for d in "$plain" "$R" "$wt"; do
    deny polling "$(sh_in "$d" "$c")" "a pgrep/ps loop in an operator session in $d: $c"
    deny polling "$(sh_in "$d" "$c" forge-fixer)" "a pgrep/ps loop from a subagent of an operator session in $d: $c"
  done
done
FORGE_PHASE=7 allow "$(sh_in "$wt" 'pgrep -f x')" "a single pgrep in a forge phase session"
for c in 'while /usr/bin/pgrep -f x >/dev/null; do sleep 5; done' 'while :; do pgrep -f x >/dev/null || break; sleep 5; done' \
  'while [ -n "$(pgrep -f x)" ]; do sleep 5; done' 'until [ -z "$( /usr/bin/pgrep -f x)" ]; do sleep 5; done' \
  'while [ -n $(pgrep -f x) ]; do sleep 5; done' "while bash -c 'pgrep -f x'; do sleep 5; done" \
  'while :; do for i in 1 2; do :; done; pgrep -f x || break; sleep 5; done'; do
  FORGE_PHASE=7 deny polling "$(sh_in "$wt" "$c")" "a pgrep loop in a forge phase session: $c"
  deny polling "$(sh_in "$wt" "$c")" "a pgrep loop in an operator session: $c"
done
for c in 'pgrep -f x | while read -r p; do echo $p; done' 'while read -r p; do echo $p; done < <(pgrep -f x)' \
  'for p in $(pgrep -f x); do echo $p; done' 'while [ -n "$(pgrepx)" ]; do sleep 5; done' "bash -c 'pgrep -f x'"; do
  if [[ $c == *sleep* ]]; then
    FORGE_ROOT=$R deny polling "$(sh_in "$wt" "$c")" "a sleep in the main agent of a forge-launched session: $c"
  else
    FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "a bounded pgrep in a forge-launched session: $c"
  fi
  allow "$(sh_in "$plain" "$c")" "a bounded pgrep in an operator session: $c"
  allow "$(sh_in "$wt" "$c" forge-fixer)" "a bounded pgrep from a subagent: $c"
done
for c in 'while ps aux | grep -q x; do sleep 5; done' 'while ps -ef | grep -v grep | grep -q x; do sleep 5; done' \
  'until ! /bin/ps -p 42 >/dev/null; do sleep 5; done' 'while [ -n "$(ps -C x -o pid=)" ]; do sleep 5; done' \
  $'while read -r n; do while pgrep -x "$n" >/dev/null; do sleep 5; done; done < services.txt' \
  $'while read -r n; do until ! ps -C "$n" >/dev/null; do sleep 5; done; done <<< "$list"'; do
  FORGE_PHASE=7 deny polling "$(sh_in "$wt" "$c")" "a pgrep/ps loop in a forge phase session: $c"
  deny polling "$(sh_in "$wt" "$c")" "a pgrep/ps loop in an operator session: $c"
  grep -q "a pgrep/ps wait loop" "$tmp/err" || fail "polling reason names a pgrep/ps wait loop: $(cat "$tmp/err")"
  ! grep -q 'forge-launched' "$tmp/err" || fail "polling reason must not name a forge-launched session: $(cat "$tmp/err")"
done
for c in 'ps aux' 'ps aux | grep -q x' 'while read -r n; do pgrep -x "$n" >/dev/null || echo "$n down"; done < services.txt' \
  $'while read -r n; do pgrep -x "$n" >/dev/null || echo "$n down"; done <<EOF\nsshd\ncrond\nEOF' \
  'while IFS= read -r n; do ps -C "$n" >/dev/null || echo "$n down"; done <<< "$list"' \
  'until read -r n; do [ -z "$(pgrep -x x)" ] && break; done < services.txt'; do
  FORGE_ROOT=$R FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "a bounded pgrep/ps in a forge-launched session: $c"
  allow "$(sh_in "$wt" "$c")" "a bounded pgrep/ps in an operator session: $c"
  allow "$(sh_in "$plain" "$c" forge-fixer)" "a bounded pgrep/ps from a subagent outside forge: $c"
done
for c in 'pgrep -f x' 'ps aux' 'for p in $(pgrep -f x); do kill $p; done' 'select p in $(ps -o pid=); do echo $p; break; done'; do
  allow "$(sh_in "$plain" "$c")" "a single or for/select pgrep/ps outside forge: $c"
  allow "$(sh_in "$R" "$c" forge-fixer)" "a single or for/select pgrep/ps from a subagent: $c"
done
ok polling
fi

if want poll-loop; then
plr() { echo "forge-guard: polling: a $1 loop that waits with $2; run the command once with run_in_background and wait for its completion notification; don't poll"; }
pls='until gh run list --limit 1 | grep -q completed; do sleep 30; done'
for c in "until:sleep:$pls" 'while:sleep:while ! gh run view 42 --exit-status; do sleep 60; done' \
  'while:read -t:while read -t 30 line; do echo "$line"; done < <(gh run watch 42)' \
  'while:read -t:while :; do read -t 30 line || break; echo "$line"; done' \
  "until:sleep:bash -c 'until gh run view 42 --exit-status; do sleep 60; done'" \
  'while:sleep:yes | while read _; do gh run view 42 --exit-status && break; sleep 30; done' \
  'while:sleep:while read -r id; do gh run view "$id"; sleep 60; done < <(gh run list --json databaseId -q ".[].databaseId")' \
  'until:sleep:until read -r l < f; do sleep 5; done' \
  "until:sleep:timeout 0 bash -c 'until gh run view 42 --exit-status; do sleep 60; done'" \
  "until:sleep:timeout infinity bash -c 'until gh run view 42 --exit-status; do sleep 60; done'" \
  "while:sleep:timeout -s KILL inf sh -c 'while ! gh run view 42 --exit-status; do sleep 60; done'"; do
  k=${c%%:*} r=${c#*:} w=${r%%:*} c=${r#*:}
  for a in forge-fixer forge-implementer ""; do
    FORGE_ROOT=$R deny polling "$(sh_in "$R/src" "$c" "$a")" "a $k/$w loop in a forge-launched session (agent '$a'): $c"
    [ "$(cat "$tmp/err")" = "$(plr "$k" "$w")" ] || fail "polling reason for $c (agent '$a'): $(cat "$tmp/err")"
    FORGE_PHASE=7 deny polling "$(sh_in "$wt" "$c" "$a")" "a $k/$w loop in a forge phase session (agent '$a'): $c"
    [ "$(cat "$tmp/err")" = "$(plr "$k" "$w")" ] || fail "polling reason for $c in a phase session (agent '$a'): $(cat "$tmp/err")"
  done
done
for c in "timeout 10 bash -c 'until curl -s localhost:8080 >/dev/null; do sleep 0.2; done'" \
  "timeout 600 bash -c 'while ! gh run view 42 --exit-status; do sleep 60; done'" \
  "timeout -k 5 2m bash -c 'while read -r l < f; do sleep 1; done'" "timeout .5 bash -c 'until test -f x; do sleep 0.1; done'"; do
  for a in forge-fixer ""; do
    FORGE_ROOT=$R allow "$(sh_in "$R/src" "$c" "$a")" "a timeout-bounded loop in a forge-launched session (agent '$a'): $c"
    FORGE_PHASE=7 allow "$(sh_in "$wt" "$c" "$a")" "a timeout-bounded loop in a forge phase session (agent '$a'): $c"
  done
done
for c in "$pls" 'while read -t 30 line; do echo "$line"; done < <(gh run watch 42)'; do
  for a in forge-fixer ""; do
    allow "$(sh_in "$wt" "$c" "$a")" "a wait loop outside a forge-launched session (agent '$a'): $c"
    allow "$(sh_in "$plain" "$c" "$a")" "a wait loop outside forge (agent '$a'): $c"
  done
done
for c in 'while read -r l; do echo "$l"; done < f' 'for i in 1 2 3; do sleep 1; done' 'sleep 1' 'until test -f done.flag; do :; done'; do
  FORGE_ROOT=$R allow "$(sh_in "$R/src" "$c" forge-fixer)" "a loop without a wait or a sleep outside a loop from a subagent of a forge-launched session: $c"
done
ok poll-loop
fi

if want_any forge-copy forge-internals forge-internals-script tests-none forge-script; then
fr=$HOME/Projects/forge fw=$HOME/Projects/forge/.claude/worktrees/x f2=$tmp/forge2 f2w=$tmp/forge2/.claude/worktrees/y dst=/tmp/forge-guard-dst-$$
mkdir -p "$HOME/.local/bin/forge.d" "$HOME/.claude/forge/schemas"
for f in "$HOME/.local/bin/forge" "$HOME/.local/bin/forge-browser" "$HOME/.local/bin/forge.d/land.sh" "$HOME/.local/bin/forge.d/gate.sh" \
  "$HOME/.claude/forge/schemas/test.schema.json"; do
  echo x >"$f"
done
for f in "$fr" "$f2"; do
  mkdir -p "$f/.forge" "$f/bin/forge.d"
  git -C "$f" init -q -b main
  echo x >"$f/.forge/PROJECT.md"
  for s in forge forge.d/land.sh forge.d/gate.sh; do echo x >"$f/bin/$s"; done
  git -C "$f" add -A
  git -C "$f" commit -qm init
done
git -C "$fr" worktree add -q -b forge/x "$fw"
git -C "$f2" worktree add -q -b forge/y "$f2w"
L=$fr/bin/forge.d/land.sh
fi
if want forge-copy; then
for d in "$plain" "$fr" "$fw"; do
  for c in "cp $L $fw/" "cp $L $fw/bin/forge.d/land.sh" "rsync -a $L $fw/bin/forge.d/" "install -m755 $L $fw/bin/forge.d/land.sh" \
    "cat $L > $fw/bin/forge.d/land.sh" "tee $fw/bin/forge.d/land.sh < $L" "cat $L | tee $fw/bin/forge.d/land.sh" \
    "cp $fw/bin/forge.d/land.sh $fr/bin/forge.d/land.sh" "cp $L $fr/tests/fixtures/" \
    "cat $L" "grep -n x $L" "diff $L ~/.local/bin/forge.d/land.sh" "cat $L | grep x" "cat ~/.local/bin/forge.d/land.sh | head -5" \
    "cp $plain/a.sh $dst/" "cp $R/src/a.txt $dst/" "cat $R/src/a.txt > $dst/a.txt" "tee $dst/a.txt < $R/src/a.txt" \
    "cat $R/src/a.txt | tee $dst/a.txt" 'cp ~/.local/bin/forge-browser '"$dst/" 'forge done 03' 'forge land' '~/.local/bin/forge status' \
    "echo cp $L $dst/" "cat $L >&2" "cat $L 2>&1 | grep x" "cat $L >&-" "cat $L 1>&2"; do
    allow "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
allow "$(sh_in "$f2w" "cp bin/forge.d/land.sh $f2/bin/forge.d/land.sh")" "a copy from a forge worktree into its main repo"
allow "$(sh_in "$f2" "cp bin/forge.d/land.sh $f2w/bin/forge.d/")" "a copy from a forge repo into its worktree"
allow "$(sh_in "$plain" "cp ~/.local/bin/forge.d/land.sh $f2w/bin/forge.d/l2.sh")" "a live-install copy into a worktree of a second forge repo"
allow "$(sh_in "$plain" "cp $L $f2/bin/forge.d/l2.sh")" "a copy into a second forge repo found from the target"
deny forge-copy "$(sh_in "$plain" "cp $f2/bin/forge.d/gate.sh $f2w/bin/forge.d/ && cp ~/Projects/forge/bin/forge.d/land.sh $dst/l.sh")" \
  "a copy after a segment that resolves a second forge repo"
for d in "$plain" "$R" "$fr" "$fw"; do
  for c in "cp $L $dst/" "cp $L $dst/land.sh" "cp -t $dst $L" "rsync -a $L $dst/" "install -m755 $L $dst/land.sh" \
    "cat $L > $dst/land.sh" "cat $L >> $dst/land.sh" "tee $dst/land.sh < $L" "tee -a $dst/land.sh <$L" "cat $L | tee $dst/land.sh" \
    "\"cp\" $L $dst/" "'cp' $L $dst/" "cp \"$L\" $dst/" "cp ~/Projects/forge/bin/forge.d/land.sh $dst/" \
    'cp ~/.local/bin/forge.d/land.sh '"$dst/" 'cp $HOME/.local/bin/forge '"$dst/forge" 'cp ~/.claude/forge/schemas/test.schema.json '"$dst/" \
    "cp $fw/bin/forge.d/gate.sh $dst/" "cd $fr/bin/forge.d && cp land.sh $dst/" "cd ~/.local/bin/forge.d; cat land.sh > $dst/land.sh" \
    "cd $fr && cp bin/forge.d/land.sh $dst/" "sh -c 'cp $L $dst/'" "bash -c 'cat $L > $dst/land.sh'" "env FOO=1 cp $L $dst/" \
    "env -i rsync -a $L $dst/" "timeout 5 cp $L $dst/" "git status && cp $L $dst/" "(cp $L $dst/)" "cp $L $plain/" "cp $L $R/src/" \
    "cp $L $wt/" "cat $L >| $dst/l.sh" "cat $L >& $dst/l.sh" "cat $L 1>& $dst/l.sh" "cat $L >|$dst/l.sh"; do
    deny forge-copy "$(sh_in "$d" "$c")" "from $d: $c"
    grep -qF land.sh "$tmp/err" || grep -qF "$dst" "$tmp/err" || fail "forge-copy reason must name the source or target: $(cat "$tmp/err")"
    grep -q 'forge repo' "$tmp/err" || fail "forge-copy reason must point at the forge repo: $(cat "$tmp/err")"
    grep -q 'phase' "$tmp/err" || fail "forge-copy reason must point at a phase: $(cat "$tmp/err")"
  done
done
deny forge-copy "$(sh_in "$fr" "cp bin/forge.d/land.sh $dst/")" "a relative source in the forge repo"
deny forge-copy "$(sh_in "$fw" "cat bin/forge.d/land.sh | tee $dst/land.sh")" "a relative source in a forge worktree"
deny forge-copy "$(sh_in "$fr/bin/forge.d" "tee $dst/land.sh < land.sh")" "a relative tee source"
deny forge-copy "$(sh_in "$fr/bin/forge.d" "cat land.sh > $dst/land.sh")" "a relative cat source"
deny forge-copy "$(sh_in "$HOME/.local/bin/forge.d" "rsync -a land.sh $dst/")" "a relative live-install source"
deny forge-copy "$(sh_in "$f2w" "cp bin/forge.d/land.sh $dst/")" "a forge repo found from a linked worktree cwd"
deny forge-copy "$(sh_in "$f2" "cp $f2w/bin/forge.d/land.sh $dst/")" "a forge repo found from its main worktree cwd"
deny forge-copy "$(sh_in "$plain" "cp $L $dst/" forge-fixer)" "a subagent's copy"
FORGE_PHASE=7 deny forge-copy "$(sh_in "$fw" "cp $L $dst/" forge-implementer)" "a phase subagent's copy"
gl=$tmp/gitlog
mkdir -p "$gl/bin"
printf '#!/bin/sh\necho x >>"%s/n"\nexec %s "$@"\n' "$gl" "$(command -v git)" >"$gl/bin/git"
chmod +x "$gl/bin/git"
srcs=
for i in $(seq 30); do
  mkdir -p "$tmp/many/$i"
  srcs+=" $tmp/many/$i/a"
done
for c in "cp$srcs $dst/" "cat$srcs" "cat$srcs | grep x"; do
  : >"$gl/n"
  PATH=$gl/bin:$PATH allow "$(sh_in "$plain" "$c")" "$c from 30 directories"
  [ "$(wc -l <"$gl/n")" -le 2 ] || fail "$c from 30 directories must run git at most twice, ran it $(wc -l <"$gl/n") times"
done
: >"$gl/n"
PATH=$gl/bin:$PATH deny forge-copy "$(sh_in "$plain" "cp$srcs $L $dst/")" "a forge script copied among 30 directories"
[ "$(wc -l <"$gl/n")" -le 3 ] || fail "a forge script copied among 30 directories must run git at most 3 times, ran it $(wc -l <"$gl/n") times"
ok forge-copy
fi

fi_deny() {
  deny forge-internals "$1" "$2"
  grep -q 'forge done' "$tmp/err" || fail "forge-internals reason must point at the forge command: $(cat "$tmp/err")"
  grep -q 'report a gate it cannot pass' "$tmp/err" || fail "forge-internals reason must point at reporting a gate: $(cat "$tmp/err")"
  ! grep -qi 'escalat' "$tmp/err" || fail "forge-internals reason must not name escalating: $(cat "$tmp/err")"
}
if want forge-internals; then
fd='~/.local/bin/forge.d'
for d in "$plain" "$R" "$wt" "$fr" "$fw"; do
  for c in "cat $fd/gate.sh" "cat $fr/bin/forge.d/*.sh" "grep -n phase_gate $fd/gate.sh" "grep -rn 'phase_gate()' $fr/bin/forge.d" \
    "sed -n 1,40p $fd/gate.sh" "sed -n '/^finish()/,/^}/p' $fw/bin/forge.d/gate.sh" "ls $fd" "ls -la $fr/bin/forge.d/" "ls $fd/gate.sh" \
    "cd $fd && cat gate.sh" "cat $fd/gate.sh | grep -n records" 'forge done 03' 'forge done 03 && forge land' 'echo finish phase_gate' \
    'source ~/.bashrc' '. ./env.sh' 'for f in lib/*.sh; do . $f; done' 'myfn(){ :; }; myfn' 'gatekeeper() { :; }' \
    'function finished { :; }' 'finish_up(){ :; }' 'phase_gates() { :; }' "bash --rcfile $dst/rc.sh" '. ./forge.dev/x.sh' \
    'source ~/myforge.data/x.sh' 'echo delegate navigate investigate gateway; . ./env.sh' 'pending_x() { :; }; . ./env.sh'; do
    allow "$(sh_in "$d" "$c")" "from $d: $c"
  done
  allow "$(sh_in "$d" 'p=forge; . ~/.local/bin/$p.d/lib.sh')" "known gap, a forge.d name built from parts at run time, from $d"
done

for d in "$plain" "$R" "$wt" "$fr" "$fw"; do
  for c in "$fd/gate.sh" "$fr/bin/forge.d/gate.sh" "$fw/bin/forge.d/gate.sh" '$HOME/.local/bin/forge.d/land.sh' \
    "$fd/*.sh" '"$HOME"/.local/bin/forge.d/*.sh'; do
    fi_deny "$(sh_in "$d" ". $c")" "from $d: . $c"
    fi_deny "$(sh_in "$d" "source $c")" "from $d: source $c"
  done
  for c in "for m in $fd/*.sh; do . \$m; done" "for m in $fd/*.sh; do source \"\$m\"; done" \
    "d=$fd/gate.sh; source \$d" "D=$fd; . \"\$D\"/gate.sh" "ls $fd && source \$f" \
    "bash --rcfile $fd/gate.sh" "bash --rcfile $fr/bin/forge.d/gate.sh -i" "bash --init-file $fd/gate.sh" \
    "bash --rcfile $fd/gate.sh -ic 'finish 07'" "bash --init-file $fd/gate.sh -ic true" "env bash --rcfile $fd/gate.sh -i -c 'finish 07'" \
    "BASH_ENV=$fd/gate.sh bash x.sh" "BASH_ENV=$fw/bin/forge.d/gate.sh bash -c true" "export BASH_ENV=$fd/gate.sh; bash x.sh" \
    "sh -c '. $fd/gate.sh'" "bash -c 'source $fd/gate.sh; records'" "bash -lc '. $fd/gate.sh'" \
    "eval '. $fd/gate.sh'" "eval \"source $fd/gate.sh\"" "env FOO=1 bash --rcfile $fd/gate.sh" \
    "builtin source $fd/gate.sh" "builtin . $fd/gate.sh" "builtin eval '. $fd/gate.sh'" "command builtin source $fd/gate.sh" \
    "env BASH_ENV=$fd/gate.sh bash x.sh" "timeout 60 bash --init-file $fd/gate.sh" "timeout 60 bash -c '. $fd/gate.sh'" \
    "\"source\" $fd/gate.sh" "'.' $fd/gate.sh" "\\. $fd/gate.sh" ". \"$fd/gate.sh\"" ". ~/.local/bin/'forge.d'/gate.sh" \
    ". ~/.local/bin/fo\"rge\".d/gate.sh" ". ~/.local/bin/forge\\.d/gate.sh" "git status && . $fd/gate.sh" "(source $fd/gate.sh)" \
    $'bash <<\'EOF\'\n. ~/.local/bin/forge.d/gate.sh\nEOF'; do
    fi_deny "$(sh_in "$d" "$c")" "from $d: $c"
  done
  for n in records pending open_findings blocking phase_gate landed fixes branch_read build_state build_fails build_gate \
    build_results finish gate reviewed checked tests_state tests_none; do
    for c in "$n(){ :; }" "$n() { return 0; }" "$n () { :; }" "function $n { :; }" "function $n() { :; }" "true; $n(){ :; }; finish 07"; do
      fi_deny "$(sh_in "$d" "$c")" "from $d: $c"
    done
  done
  for c in "sh -c 'phase_gate(){ :; }; finish 07'" "bash -c 'function finish { :; }'" "bash -lc 'phase_gate() { :; }; finish 07'" \
    "eval 'phase_gate(){ :; }'" "eval \"function gate { :; }\"" "env FOO=1 bash -c 'tests_state(){ :; }'" \
    "builtin eval 'phase_gate(){ :; }'" "builtin eval \"function gate { :; }\"" \
    "timeout 60 bash -c 'phase_gate(){ :; }; finish 07'" "git status && phase_gate(){ :; }" "(build_gate(){ :; }; finish 07)" \
    $'cat > /dev/null <<EOF\nphase_gate() { :; }\nEOF'; do
    fi_deny "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
for c in ". $fd/gate.sh" "phase_gate(){ :; }; finish 07" "bash -c 'source $fd/gate.sh'"; do
  fi_deny "$(sh_in "$wt" "$c" forge-implementer)" "a subagent's $c"
  FORGE_PHASE=7 fi_deny "$(sh_in "$wt" "$c" forge-implementer)" "a phase subagent's $c"
  FORGE_ROOT=$R fi_deny "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
done
ww=$(printf '%s\n' "cat > $tmp/job/req/guardtest/finish326.sh <<'EOF'" '#!/usr/bin/env bash' 'D=$HOME/.local/bin/forge.d' 'root=$FORGE_ROOT' \
  'for _m in "$D"/*.sh; do . "$_m"; done' 'phase_gate() { echo skipped >&2; }' 'cd "$root/.forge"' 'finish 326' 'EOF')
is='for m in ~/.local/bin/forge.d/*.sh; do . $m; done; phase_gate(){ :; }; finish 326'
ib='for m in ~/.local/bin/forge.d/*.sh; do builtin . "$m"; done; builtin eval '\''phase_gate(){ :; }'\''; finish 326'
for c in "$ww" "$is" "$ib"; do
  FORGE_ROOT=$R fi_deny "$(sh_in "$wt" "$c")" "regression with FORGE_ROOT: $c"
  fi_deny "$(sh_in "$plain" "$c")" "regression: $c"
  fi_deny "$(sh_in "$fr" "$c" forge-fixer)" "regression from a subagent in the forge repo: $c"
done
ok forge-internals
fi

if want forge-internals-script; then
ct_in() { jq -nc --arg d "$1" --arg p "$2" --arg t "$3" --arg c "$4" --arg a "${5:-}" \
  '{hook_event_name: "PreToolUse", session_id: "s", tool_name: $t, cwd: $d,
    tool_input: (if $t == "NotebookEdit" then {notebook_path: $p, new_source: $c}
      elif $t == "Edit" then {file_path: $p, old_string: "x", new_string: $c} else {file_path: $p, content: $c} end)}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
w326=$(printf '%s\n' '#!/usr/bin/env bash' 'D=$HOME/.local/bin/forge.d' 'root=$FORGE_ROOT' 'for _m in "$D"/*.sh; do . "$_m"; done' \
  'phase_gate() { echo skipped >&2; }' 'cd "$root/.forge"' 'finish 326')
wsrc=$(printf '%s\n' '#!/usr/bin/env bash' '. "$HOME/.local/bin/forge.d/gate.sh"' 'records 07')
wloop=$(printf '%s\n' '#!/usr/bin/env bash' 'for m in ~/.local/bin/forge.d/*.sh; do source "$m"; done' 'forge done 07')
wdef=$(printf '%s\n' '#!/usr/bin/env bash' 'tests_state() { echo passed; }' 'function build_gate { :; }' 'forge done 07')
wclean=$(printf '%s\n' '#!/usr/bin/env bash' 'echo hi' 'forge done 03' 'cat ~/.local/bin/forge.d/gate.sh | grep -n phase_gate' \
  'grep -rn "finish()" ~/.local/bin/forge.d' 'ls ~/.local/bin/forge.d')
whelp=$(printf '%s\n' '#!/usr/bin/env bash' 'root=$(cd "$(dirname "$0")/.." && pwd)' '. "$root/bin/forge.d/gate.sh"' \
  'for m in "$root"/bin/forge.d/*.sh; do . "$m"; done' 'tests_none() { return 1; }' 'phase_gate 07')
gt=$tmp/job/req/guardtest
mkdir -p "$gt" "$plain/scripts" "$R/src" "$fr/tests" "$fw/tests" "$f2/tests" "$f2w/tests"
printf '%s\n' "$w326" >"$gt/finish326.sh"
outs=("$gt/finish326.sh")
for s in wsrc wloop wdef; do
  for o in "$gt" "$plain/scripts" "$R/src"; do
    printf '%s\n' "${!s}" >"$o/$s.sh"
    outs+=("$o/$s.sh")
  done
done
printf '%s\n' "$wclean" >"$gt/clean.sh"
printf '%s\n' "$wclean" >"$plain/scripts/clean.sh"
for h in "$fr" "$fw" "$f2" "$f2w"; do printf '%s\n' "$whelp" >"$h/tests/helper.sh"; done
chmod +x "$gt"/*.sh "$plain/scripts"/*.sh "$R/src"/*.sh "$fr/tests/helper.sh" "$fw/tests/helper.sh" "$f2/tests/helper.sh" "$f2w/tests/helper.sh"
rw="bash $gt/finish326.sh"
FORGE_ROOT=$R fi_deny "$(sh_in "$wt" "$rw")" "regression run_wrapper with FORGE_ROOT: $rw"
for d in "$plain" "$R" "$wt" "$fr" "$fw"; do
  for x in "${outs[@]}"; do
    for c in "bash $x" "sh $x" ". $x" "source $x" "$x" "$x --dry-run" "cd ${x%/*} && ./${x##*/}" "cd ${x%/*}; . ./${x##*/}" \
      "bash -x $x" "env FOO=1 bash $x" "timeout 60 sh $x" "git status && bash $x" "bash -c 'bash $x'" "bash \"$x\""; do
      fi_deny "$(sh_in "$d" "$c")" "from $d: $c"
    done
  done
  fi_deny "$(sh_in "$d" "$rw" forge-fixer)" "regression run_wrapper from a subagent: $rw"
done
{ printf '#!/usr/bin/env bash\n#'; printf '%*s' 300000 '' | tr ' ' x; printf '\nphase_gate(){ :; }; phase_gate\n'; } >"$gt/pad.sh"
{ printf '#!/usr/bin/env bash\necho hi\n'; printf '\0x'; printf '\nphase_gate(){ :; }; phase_gate\n'; } >"$gt/nul.sh"
chmod +x "$gt/pad.sh" "$gt/nul.sh"
for x in "$gt/pad.sh" "$gt/nul.sh"; do
  for c in "bash $x" ". $x" "$x"; do
    fi_deny "$(sh_in "$plain" "$c")" "a gate function defined past a long or NUL prefix: $c"
  done
done
printf '\177ELF\2\1\1\0phase_gate forge.d\n' >"$gt/elf"
chmod +x "$gt/elf"
allow "$(sh_in "$plain" "$gt/elf")" "a binary whose first line holds a NUL"
for x in "${outs[@]}"; do
  fi_deny "$(sh_in "${x%/*}" "./${x##*/}")" "from ${x%/*}: ./${x##*/}"
  fi_deny "$(sh_in "${x%/*}" "sh ${x##*/}")" "from ${x%/*}: sh ${x##*/}"
  fi_deny "$(sh_in "${x%/*}" ". ${x##*/}")" "from ${x%/*}: . ${x##*/}"
done
for d in "$plain" "$R" "$wt" "$fr" "$fw"; do
  for p in "$gt/w.sh" "$plain/scripts/w.sh" "$R/src/w.sh" "$wt/w.sh" "$tmp/w.ipynb"; do
    for s in w326 wsrc wloop wdef; do
      for t in Write Edit NotebookEdit; do
        fi_deny "$(ct_in "$d" "$p" "$t" "${!s}")" "from $d: $t $p with $s"
      done
      fi_deny "$(ct_in "$d" "$p" Write "${!s}" forge-implementer)" "from $d: a subagent's Write $p with $s"
    done
  done
done
FORGE_ROOT=$R fi_deny "$(ct_in "$wt" "$gt/finish326.sh" Write "$w326")" "regression Write of finish326.sh with FORGE_ROOT"
for d in "$plain" "$R" "$wt" "$fr" "$fw"; do
  for h in "$fr/tests/helper.sh" "$fw/tests/helper.sh"; do
    for c in "bash $h" "sh $h" ". $h" "source $h" "$h" "cd ${h%/*} && ./helper.sh" "cd ${h%/*}/.. && bash tests/helper.sh"; do
      allow "$(sh_in "$d" "$c")" "from $d: in-repo test helper $c"
    done
  done
  for x in "$gt/clean.sh" "$plain/scripts/clean.sh"; do
    for c in "bash $x" "sh $x" ". $x" "$x" "cd ${x%/*} && ./clean.sh"; do
      allow "$(sh_in "$d" "$c")" "from $d: an outside script naming neither forge.d nor a gate function, $c"
    done
  done
  for p in "$fr/tests/h2.sh" "$fw/tests/h2.sh" "$fr/bin/forge.d/x2.sh" "$fw/bin/forge.d/x2.sh"; do
    for s in whelp w326 wsrc wdef; do
      for t in Write Edit; do
        allow "$(ct_in "$d" "$p" "$t" "${!s}")" "from $d: $t $p with $s inside the forge repo"
      done
    done
  done
  for p in "$gt/w.sh" "$plain/scripts/w.sh" "$R/src/w.sh"; do
    for t in Write Edit NotebookEdit; do
      allow "$(ct_in "$d" "$p" "$t" "$wclean")" "from $d: $t $p naming neither forge.d nor a gate function"
    done
    allow "$(ed_in "$d" "$p" '' Edit)" "from $d: Edit $p with no new_string"
  done
done
for d in "$plain" "$f2" "$f2w"; do
  for h in "$f2/tests/helper.sh" "$f2w/tests/helper.sh"; do
    allow "$(sh_in "$d" "bash $h")" "from $d: a second forge repo's test helper bash $h"
    allow "$(ct_in "$d" "${h%/*}/h3.sh" Write "$whelp")" "from $d: Write ${h%/*}/h3.sh in a second forge repo"
  done
done
wnear=$(printf '%s\n' '#!/usr/bin/env bash' '. ./forge.dev/x.sh' 'source ~/myforge.data/lib.sh' 'delegate() { :; }' \
  'navigate; investigate gateway finished gatekeeper pending_x')
printf '%s\n' "$wnear" >"$gt/near.sh"
chmod +x "$gt/near.sh"
jl=$tmp/jqlog
mkdir -p "$jl/bin"
printf '#!/bin/sh\necho x >>"%s/n"\nexec %s "$@"\n' "$jl" "$(command -v jq)" >"$jl/bin/jq"
chmod +x "$jl/bin/jq"
for c in "bash $gt/near.sh" ". $gt/near.sh" "$gt/near.sh"; do
  i=$(sh_in "$plain" "$c")
  : >"$jl/n"
  PATH=$jl/bin:$PATH allow "$i" "a script naming only near misses of forge.d and gate functions: $c"
  [ "$(wc -l <"$jl/n")" = 1 ] || fail "$c naming only near misses must not parse the script, ran jq $(wc -l <"$jl/n") times"
done
allow "$(ct_in "$plain" "$gt/w.sh" Write "$wnear")" "Write of a script naming only near misses of forge.d and gate functions"
wprose=$(printf '%s\n' '# Friction report' '' 'Since 2026-10-08, 129 endings were blocked or failed. We ran forge done 3.' \
  'Phase 471 ended with pending (3) tasks; the gate (land) was never passed and finish() is what the session calls.' \
  'Open fixes() in the phase: records (2), landed. The function finish runs last. Fixes: none. forge done.' \
  '- `forge done N` passes once every task is committed.')
for p in "$gt/REPORT.md" "$plain/notes.md" "$HOME/Documents/x/REPORT.md"; do
  for t in Write Edit NotebookEdit; do
    allow "$(ct_in "$plain" "$p" "$t" "$wprose")" "$t $p: prose naming forge done and gate functions before a ( or a sentence-ending dot"
  done
done
for c in $'finish() {\n  :\n}' 'phase_gate () { :; }' 'function gate { :; }' 'function fixes() { :; }' ". ~/.local/bin/forge.d/gate.sh" "source \"\$HOME/.local/bin/forge.d/land.sh\""; do
  fi_deny "$(ct_in "$plain" "$gt/REPORT.md" Write "$wprose"$'\n'"$c")" "Write of prose holding the line: $c"
done
ok forge-internals-script
fi

if want tests-none; then
tn_in() { jq -nc --arg d "$1" --arg p "$2" --arg t "$3" --arg c "$4" --arg o "${5:-}" --arg a "${6:-}" \
  '{hook_event_name: "PreToolUse", session_id: "s", tool_name: $t, cwd: $d,
    tool_input: (if $t == "Edit" then {file_path: $p, old_string: $o, new_string: $c} else {file_path: $p, content: $c} end)}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
tnr() {
  grep -qF "$1" "$tmp/err" || fail "tests-none reason must name $1: $(cat "$tmp/err")"
  grep -qi 'only the operator' "$tmp/err" || fail "tests-none reason must say only the operator adds the line: $(cat "$tmp/err")"
  grep -qi 'by hand' "$tmp/err" || fail "tests-none reason must offer editing the file by hand: $(cat "$tmp/err")"
  grep -qF '!' "$tmp/err" || fail "tests-none reason must offer a ! command: $(cat "$tmp/err")"
  grep -qF '## Commands' "$tmp/err" || fail "tests-none reason must name ## Commands: $(cat "$tmp/err")"
}
tl='- All tests: none'
tdoc=$wt/.forge/TESTING.md
printf '%s\n' '# Testing' '' '## Commands' '- All tests: `make test`' >"$tdoc"
tpro=$wt/docs/prose/TESTING.md
mkdir -p "${tpro%/*}"
printf '%s\n' '# Testing' 'Declare `- All tests: none` under ## Commands.' >"$tpro"
tg=$wt/docs/gap
mkdir -p "$tg"/{a,b,c,d}
printf '%s\n' '## Commands' "- All tests: 'make test'" >"$tg/a/TESTING.md"
printf '%s\n' '## Commands' '- All tests: X' none >"$tg/b/TESTING.md"
printf '%s\r\n' '## Commands' '- All tests: `make test`' foo >"$tg/c/TESTING.md"
printf '%s\n' '## Commands' '- All tests: é' >"$tg/d/TESTING.md"
for a in '' forge-implementer; do
  for n in "$tl" "$tl  " "$tl"$'\t'; do
    deny tests-none "$(tn_in "$wt" "$tdoc" Edit $'## Commands\n'"$n" '## Commands' "$a")" "${a:-main} Edit adding the line: $n"
    tnr "$tdoc"
  done
  deny tests-none "$(tn_in "$wt" "$tdoc" Edit "$tl" '- All tests: `make test`' "$a")" "${a:-main} Edit replacing a command with the line"
  tnr "$tdoc"
  deny tests-none "$(tn_in "$wt" "$tdoc" Write $'# Testing\n\n## Commands\n'"$tl"$'\n' '' "$a")" "${a:-main} Write of the line that disk lacks"
  tnr "$tdoc"
  deny tests-none "$(tn_in "$wt" "$wt/docs/new/TESTING.md" Write $'## Commands\n'"$tl" '' "$a")" "${a:-main} Write of a new TESTING.md with the line"
  tnr "$wt/docs/new/TESTING.md"
  deny tests-none "$(tn_in "$wt" "$wt/tests/fixtures/p/.forge/TESTING.md" Edit "$tl" x "$a")" "${a:-main} Edit under tests/ of a repo that is not forge"
  deny tests-none "$(tn_in "$fw" "$fw/.forge/TESTING.md" Edit "$tl" x "$a")" "${a:-main} Edit of a forge worktree's own TESTING.md"
  allow "$(tn_in "$wt" "$tdoc" Edit 'Declare `- All tests: none` under ## Commands.' '# Testing' "$a")" "${a:-main} Edit of backticked prose"
  allow "$(tn_in "$wt" "$tdoc" Write $'## Commands\n- All tests: `make test`\nSee `- All tests: none`.' '' "$a")" "${a:-main} Write of backticked prose"
  allow "$(tn_in "$wt" "$tdoc" Edit "x $tl" '# Testing' "$a")" "${a:-main} Edit with the text inside a line"
  deny tests-none "$(tn_in "$wt" "$tdoc" Edit none '`make test`' "$a")" "${a:-main} partial-line Edit leaving the line in the file"
  tnr "$tdoc"
  deny tests-none "$(tn_in "$wt" "$tpro" Edit $'\n'"$tl"$'\n' "$tl" "$a")" "${a:-main} Edit starting mid-line in backticked prose leaving the line in the file"
  tnr "$tpro"
  allow "$(tn_in "$wt" "$tdoc" Edit '`make check`' '`make test`' "$a")" "${a:-main} partial-line Edit not leaving the line in the file"
  allow "$(tn_in "$wt" "$tdoc" Edit none 'make test' "$a")" "${a:-main} partial-line Edit leaving the text backticked"
  deny tests-none "$(tn_in "$wt" "$tg/a/TESTING.md" Edit none '‘make test’' "$a")" "${a:-main} Edit whose curly-quoted old_string the tool matches to straight quotes"
  tnr "$tg/a/TESTING.md"
  deny tests-none "$(tn_in "$wt" "$tg/b/TESTING.md" Edit '' X "$a")" "${a:-main} Edit with an empty new_string deleting old_string and its newline"
  tnr "$tg/b/TESTING.md"
  deny tests-none "$(tn_in "$wt" "$tg/c/TESTING.md" Edit $'none\nfoo' $'`make test`\nfoo' "$a")" "${a:-main} Edit of a CRLF file with an LF multi-line old_string"
  tnr "$tg/c/TESTING.md"
  deny tests-none "$(tn_in "$wt" "$tg/d/TESTING.md" Edit none '\u00e9' "$a")" "${a:-main} Edit whose \\u old_string the tool unescapes"
  tnr "$tg/d/TESTING.md"
  allow "$(tn_in "$wt" "$tg/c/TESTING.md" Edit $'`make check`\nfoo' $'`make test`\nfoo' "$a")" "${a:-main} Edit of a CRLF file with an LF multi-line old_string not adding the line"
  allow "$(tn_in "$wt" "$tdoc" Edit '' '## Commands' "$a")" "${a:-main} Edit with an empty new_string not joining lines into the line"
  for d in "$R" "$fr" "$fw"; do
    for p in "$fr/tests/fixtures/p/.forge/TESTING.md" "$fw/tests/fixtures/q/.forge/TESTING.md"; do
      allow "$(tn_in "$d" "$p" Edit $'## Commands\n'"$tl" '## Commands' "$a")" "${a:-main} Edit of fixture $p from $d"
      allow "$(tn_in "$d" "$p" Write $'## Commands\n'"$tl" '' "$a")" "${a:-main} Write of fixture $p from $d"
    done
  done
  for p in "$wt/.forge/NOTES.md" "$wt/.forge/TESTING.md.bak" "$wt/xTESTING.md"; do
    allow "$(tn_in "$wt" "$p" Write $'## Commands\n'"$tl" '' "$a")" "${a:-main} Write of $p not named TESTING.md"
    allow "$(tn_in "$wt" "$p" Edit "$tl" x "$a")" "${a:-main} Edit of $p not named TESTING.md"
  done
done
printf '%s\n' '# Testing' '' '## Commands' "$tl" >"$tdoc"
allow "$(tn_in "$wt" "$tdoc" Write $'# Testing\n\n## Commands\n'"$tl"$'\n- Memory: 4G' '')" "a Write keeping the line the disk file has"
allow "$(tn_in "$wt" "$tdoc" Write $'# Testing\n\n## Commands\n'"$tl" '' forge-implementer)" "a subagent Write keeping the line the disk file has"
for a in '' forge-implementer; do
  allow "$(tn_in "$wt" "$tdoc" Edit "$tl"$'\n- Memory: 8G' "$tl" "$a")" "${a:-main} Edit whose old_string has the line"
done
rm "$tdoc"
for a in '' forge-implementer; do
  for c in "echo '$tl' >> .forge/TESTING.md" "echo '$tl' >>.forge/TESTING.md" "printf '%s\n' '$tl' >> $wt/.forge/TESTING.md" \
    $'cat >> .forge/TESTING.md <<\'EOF\'\n'"$tl"$'\nEOF' "echo '$tl' | tee -a .forge/TESTING.md" \
    "sed -i '/## Commands/a $tl' .forge/TESTING.md" "echo '- All tests'': none' >> .forge/TESTING.md" \
    "echo \"- All tests: \"none >> .forge/TESTING.md" "echo - All\\ tests:\\ none >> .forge/TESTING.md" \
    "cd $wt && echo '$tl' >> .forge/TESTING.md" "echo '$tl' | tee -a $fr/tests/fixtures/p/.forge/TESTING.md .forge/TESTING.md"; do
    deny tests-none "$(sh_in "$wt" "$c" "$a")" "${a:-main} Bash: $c"
    tnr .forge/TESTING.md
  done
  for d in "$fr" "$fw"; do
    for c in "echo '$tl' >> tests/fixtures/p/.forge/TESTING.md" "echo '$tl' >> $d/tests/fixtures/q/.forge/TESTING.md" \
      "echo '$tl' | tee -a $fr/tests/fixtures/p/.forge/TESTING.md $fw/tests/fixtures/q/.forge/TESTING.md"; do
      allow "$(sh_in "$d" "$c" "$a")" "${a:-main} Bash on a fixture TESTING.md from $d: $c"
    done
  done
  fx=$fr/tests/fixtures/p/.forge/TESTING.md
  for c in $'python3 - <<\'PY\'\nfrom pathlib import Path\nPath(\'.forge/TESTING.md\').write_text(\'## Commands\\n'"$tl"$'\\n\')\nPY\n: '"$fx" \
    "python3 - $fx <<< \"open('.forge/TESTING.md', 'a').write('$tl')\"" "f=.forge/TESTING.md; echo '$tl' >> \"\$f\"; : $fx" \
    "eval : $fx; f=.forge/TESTING.md; echo '$tl' >> \"\$f\""; do
    deny tests-none "$(sh_in "$wt" "$c" "$a")" "${a:-main} Bash hiding a TESTING.md behind a fixture: $c"
    grep -qi 'only the operator' "$tmp/err" || fail "tests-none reason must say only the operator adds the line: $(cat "$tmp/err")"
  done
  for c in "echo '$tl' >> notes.md" "grep -n 'All tests: none' bin/forge.d/test.sh" "cat .forge/TESTING.md" \
    "grep -n 'All tests:' .forge/TESTING.md"; do
    allow "$(sh_in "$wt" "$c" "$a")" "${a:-main} Bash naming one of the strings only: $c"
  done
done
ok tests-none
fi

if want forge-script; then
lb=$HOME/.local/bin/forge.d
landsrc=$(printf '%s\n' '#!/usr/bin/env bash' 'land() {' '  echo "forge: landing $1"' '}' 'land "$@"')
gatesrc=$(printf '%s\n' '#!/usr/bin/env bash' 'echo gate-in-the-repo')
schemasrc=$(printf '%s\n' '{"type": "object", "required": ["task"]}')
printf '%s\n' "$landsrc" >"$lb/land.sh"
printf '%s\n' "$gatesrc" >"$fr/bin/forge.d/gate.sh"
printf '%s\n' "$schemasrc" >"$HOME/.claude/forge/schemas/test.schema.json"
wc_in() { jq -nc --arg d "$1" --arg p "$2" --arg t "$3" --arg c "$4" --arg a "${5:-}" \
  '{hook_event_name: "PreToolUse", session_id: "s", tool_name: $t, cwd: $d,
    tool_input: (if $t == "NotebookEdit" then {notebook_path: $p, new_source: $c}
      elif $t == "Edit" then {file_path: $p, old_string: "x", new_string: $c} else {file_path: $p, content: $c} end)}
   + if $a == "" then {} else {agent_id: "a1", agent_type: $a} end'; }
fcr() {
  grep -qF "$1" "$tmp/err" || fail "forge-copy reason must name $1: $(cat "$tmp/err")"
  grep -q 'forge repo' "$tmp/err" || fail "forge-copy reason must point at the forge repo: $(cat "$tmp/err")"
  grep -q 'phase' "$tmp/err" || fail "forge-copy reason must point at a phase: $(cat "$tmp/err")"
}
mkdir -p "$dst/sub" "$plain/job"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi' >"$dst/land.sh"
cp "$dst/land.sh" "$dst/gate.sh"
cp "$dst/land.sh" "$dst/sub/test.sh"
cp "$dst/land.sh" "$plain/job/run.sh"
cp "$dst/land.sh" "$plain/job/review.sh"
printf '%s\n' "$landsrc" >"$dst/copy.sh"
printf '%s\n' "$landsrc" >"$plain/job/review.sh.copy"
printf '%s\n' "$gatesrc" >"$dst/g.sh"
for d in "$plain" "$R" "$fr" "$fw"; do
  for p in "$dst/land.sh" "$dst/gate.sh" "$dst/sub/test.sh" "$plain/job/run.sh" "$plain/job/review.sh" "$dst/notes.md"; do
    for t in Write Edit NotebookEdit; do
      allow "$(wc_in "$d" "$p" "$t" "$gatesrc"$'\n'"echo more")" "from $d: $t $p, named like a forge script, with content that is no forge file"
    done
    allow "$(ed_in "$d" "$p")" "from $d: Write $p with no content"
    [ "$d" != "$plain" ] || allow "$(wc_in "$d" "$p" Edit 'echo x' forge-fixer)" "from $d: a subagent's Edit $p"
  done
  for c in "echo x > $dst/land.sh" "printf x >> $dst/gate.sh" "echo x | tee $dst/land.sh" "sed -i s/a/b/ $dst/land.sh" \
    "cd $dst && echo x > land.sh" "bash -c 'echo x > $dst/land.sh'" "echo x > $plain/job/run.sh" "sed -i s/a/b/ $plain/job/review.sh" \
    "bash $dst/land.sh" "sh $dst/land.sh" "source $dst/land.sh" ". $dst/land.sh" "$dst/land.sh" "$dst/land.sh --dry-run" \
    "bash $dst/gate.sh 07" "cd $dst && bash land.sh" "cd $dst && ./land.sh" "cd $dst; . ./land.sh" "env FOO=1 bash $dst/land.sh" \
    "timeout 5 sh $dst/land.sh" "bash $dst/sub/test.sh" "bash $plain/job/run.sh" "cd $plain/job && ./review.sh" \
    "cat $dst/copy.sh" "grep -n x $dst/copy.sh" "diff $dst/copy.sh $L" "ls $dst/copy.sh" "echo bash $dst/copy.sh" "sed s/a/b/ $dst/copy.sh"; do
    allow "$(sh_in "$d" "$c")" "from $d: $c"
  done
  for p in "$dst/notes.sh" "$dst/land.sh" "$plain/job/review.sh" "$R/src/x.sh" "$dst/x.md"; do
    for t in Write Edit NotebookEdit; do
      deny forge-copy "$(wc_in "$d" "$p" "$t" "$landsrc")" "from $d: $t $p with the content of the live land.sh"
      fcr "$p"
      fcr "$lb/land.sh"
    done
    deny forge-copy "$(wc_in "$d" "$p" Write "$gatesrc")" "from $d: Write $p with the content of the forge repo's gate.sh"
    fcr "$fr/bin/forge.d/gate.sh"
    deny forge-copy "$(wc_in "$d" "$p" Write "$schemasrc")" "from $d: Write $p with the content of a live schema"
    fcr "$HOME/.claude/forge/schemas/test.schema.json"
    [ "$d" != "$plain" ] || deny forge-copy "$(wc_in "$d" "$p" Edit "$landsrc" forge-fixer)" "from $d: a subagent's Edit $p with the content of the live land.sh"
  done
  for c in "bash $dst/copy.sh" "sh $dst/copy.sh" "source $dst/copy.sh" ". $dst/copy.sh" "$dst/copy.sh" "$dst/copy.sh --dry-run" \
    "cd $dst && bash copy.sh" "cd $dst && ./copy.sh" "cd $dst; . ./copy.sh" "env FOO=1 bash $dst/copy.sh" "timeout 5 sh $dst/copy.sh" \
    "git status && source $dst/copy.sh" "(bash $dst/copy.sh)" "bash -c 'bash $dst/copy.sh'" "sh -c '$dst/copy.sh'" "bash \"$dst/copy.sh\"" \
    "bash $dst/g.sh" "bash $plain/job/review.sh.copy"; do
    deny forge-copy "$(sh_in "$d" "$c")" "from $d: $c"
    case $c in *g.sh*) fcr "$fr/bin/forge.d/gate.sh" ;; *) fcr "$lb/land.sh" ;; esac
    [ "$d" != "$plain" ] || deny forge-copy "$(sh_in "$d" "$c" forge-fixer)" "from $d: a subagent's $c"
  done
  for p in "$fr/bin/forge.d/land.sh" "$fw/bin/forge.d/land.sh" "$fr/tests/fixtures/land.sh" "$fw/x/copy.sh"; do
    allow "$(wc_in "$d" "$p" Write "$landsrc")" "from $d: Write $p, a forge script's content inside a forge repo or its worktree"
  done
  [ "$d" != "$plain" ] || allow "$(wc_in "$d" "$f2w/bin/forge.d/l2.sh" Write "$landsrc")" "from $d: Write into a second forge repo's worktree found from the target"
  for c in "bash $fr/bin/forge.d/land.sh" "sh $fw/bin/forge.d/gate.sh" "$fr/bin/forge.d/gate.sh" "cd $fr/bin/forge.d && bash gate.sh" \
    "bash ~/.local/bin/forge.d/land.sh" "$HOME/.local/bin/forge.d/land.sh" "cd ~/.local/bin/forge.d && bash land.sh" \
    'forge done 03' 'forge land' '~/.local/bin/forge status' "$HOME/.local/bin/forge done 03"; do
    allow "$(sh_in "$d" "$c")" "from $d: $c"
  done
done
deny forge-copy "$( (printf 'w%d ' $(seq 40000); printf '&& bash %s/copy.sh' "$dst") | big_in "$plain")" "a 40,000-word command ending in a run of a copy"
allow "$( (printf 'w%d.sh ' $(seq 40000); printf '&& forge done 03') | big_in "$plain")" "a 40,000-word command of script names"
rm -rf "$dst" "$plain/job"
echo x >"$lb/land.sh"
echo x >"$fr/bin/forge.d/gate.sh"
echo x >"$HOME/.claude/forge/schemas/test.schema.json"
ok forge-script
fi

if want live-install; then
mkdir -p "$HOME/.local/state/forge" "$HOME/.claude/skills/forge-phase" "$HOME/.local/bin"
printf '%s\n' "$HOME/.claude/skills/forge-phase/SKILL.md" "$HOME/.claude/agents/forge-fixer.md" "$HOME/.claude/hooks/forge-guard.sh" \
  "$HOME/.claude/output-styles/o.md" "$HOME/.local/bin/forge" "$HOME/.local/bin/forge-browser" "$HOME/.config/systemd/user/forge-watchdog.service" \
  "$HOME/.config/systemd/user/forge-watchdog.timer" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json" >"$HOME/.local/state/forge/port.manifest"
for p in "$HOME/.claude/skills/forge-phase/SKILL.md" "$HOME/.claude/agents/forge-fixer.md" "$HOME/.claude/hooks/forge-guard.sh" \
  "$HOME/.claude/forge/templates/x.md" "$HOME/.claude/forge/new.md" "$HOME/.claude/output-styles/o.md" "$HOME/.local/bin/forge" \
  "$HOME/.local/bin/forge-browser" "$HOME/.config/systemd/user/forge-watchdog.service" "$HOME/.claude/CLAUDE.md" \
  "$HOME/.claude/x/../skills/forge-phase/SKILL.md" '~/.claude/skills/forge-phase/SKILL.md'; do
  deny live-install "$(ed_in "$R" "$p")" "Write $p"
  deny live-install "$(ed_in "$plain" "$p" forge-fixer Edit)" "a subagent's Edit $p"
done
deny live-install "$(ed_in "$R" "$HOME/.claude/forge/n.ipynb" '' NotebookEdit)" "NotebookEdit into ~/.claude/forge"
grep -q 'port' "$tmp/err" || fail "live-install reason must point at port"
for p in "$HOME/.claude/settings.json" "$HOME/.claude/jobs/x/notes.md" "$HOME/.local/bin/other" "$HOME/.local/bin/forge-x" \
  "$HOME/.config/systemd/user/other.service" "$HOME/.claude/skillsx/a" "$R/skills/a.md" "$HOME/.claude/skills/ksp-rp1-aircraft/SKILL.md" \
  "$HOME/.claude/skills/new-skill/SKILL.md" "$HOME/.claude/skills/forge-phase/notes.md" "$HOME/.claude/hooks/my-hook.sh" \
  "$HOME/.claude/agents/mine.md" "$HOME/.claude/skills/synced/x.md" "$HOME/.claude/forgery/x"; do
  allow "$(ed_in "$R" "$p")" "Write $p"
done
for c in 'cp skills/forge-phase/SKILL.md ~/.claude/skills/forge-phase/' 'mv forge-fixer.md $HOME/.claude/agents/' 'rsync -a hooks/ ~/.claude/hooks/' \
  'install -m755 bin/forge ~/.local/bin/forge' 'install -m 755 bin/forge ~/.local/bin/forge' 'echo x | tee ~/.claude/forge/a' 'tee -a ~/.claude/forge/a <x' \
  "sed -i s/a/b/ $HOME/.claude/skills/forge-phase/SKILL.md" "sed --in-place -e s/a/b/ $HOME/.claude/skills/forge-phase/SKILL.md" \
  'ln -sf x ~/.local/bin/forge-browser' 'echo x > ~/.claude/hooks/forge-guard.sh' 'echo x >> "$HOME/.claude/agents/forge-fixer.md"' \
  'cp -t ~/.claude/skills forge-phase b' 'cd ~/.claude && cp -r x/forge-phase skills/' 'cp x ${HOME}/.config/systemd/user/forge-watchdog.timer' \
  'git status && cat a > ~/.claude/output-styles/o.md' "bash -c 'cat a >~/.claude/forge/a'" 'cp -r skills/ ~/.claude/' 'cp -r skills ~/.claude' \
  'rsync -a skills ~/.claude/' 'rsync -a global/ ~/.claude/' 'rsync -av --exclude .git bin/ ~/.local/bin/' 'cp -r bin/. ~/.local/bin/' \
  'mv forge ~/.claude/' 'cp a.md forge-fixer.md ~/.claude/agents' 'cp --target-directory=$HOME/.local/bin forge' 'echo x >| ~/.claude/forge/a' 'echo x >& ~/.claude/forge/a' \
  'cat a 1>& ~/.claude/hooks/forge-guard.sh'; do
  deny live-install "$(sh_in "$R" "$c")" "$c"
done
for c in 'timeout 5 cp x ~/.claude/forge/a' 'env -i FOO=1 tee ~/.claude/forge/a <x' 'nice -n 5 install -m755 bin/forge ~/.local/bin/forge' \
  'nohup cp x ~/.claude/forge/a' 'command cp x ~/.claude/forge/a' 'stdbuf -oL tee ~/.claude/forge/a' 'time -p cp x ~/.claude/forge/a' \
  "xargs sed -i s/a/b/ $HOME/.claude/skills/forge-phase/SKILL.md" 'exec -a y cp x ~/.claude/forge/a' 'env -C ~/.claude cp x forge/a' \
  'env -C /tmp cat x > ~/.claude/forge/a' 'xargs cp -t ~/.claude/skills' "xargs sed s/a/b/ $HOME/.claude/skills/forge-phase/SKILL.md" \
  'xargs mv ~/.claude/agents/forge-fixer.md' 'xargs cp --target-directory=$HOME/.claude/forge' 'xargs -I{} install {} ~/.local/bin/forge' \
  "env -S 'bash -c \"cp x ~/.claude/forge/a\"'"; do
  deny live-install "$(sh_in "$R" "$c")" "a wrapped write: $c"
done
for c in 'xargs cp -t ~/.claude/skills/mine' 'xargs -I{} cp {} /tmp/out' 'xargs sed s/a/b/' 'xargs tee /tmp/log'; do
  allow "$(sh_in "$R" "$c")" "an xargs write away from the live install: $c"
done
allow "$(sh_in "$R" 'env -C ~/.claude cat x > forge/a')" "a redirect resolved in the shell's directory, not env's"
for c in './port --apply' "cd $R && ./port --apply" 'port --apply' './port' \
  'cat ~/.claude/skills/forge-phase/SKILL.md' 'cp ~/.claude/skills/forge-phase /tmp/x' 'diff -r skills ~/.claude/skills' \
  'echo x > ~/.claude/jobs/n.md' 'sed s/a/b/ ~/.claude/skills/forge-phase/SKILL.md' 'ls ~/.local/bin/forge*' 'port status' \
  'cp -r my-skill ~/.claude/skills/' 'cp script.sh ~/.local/bin/' 'cp a b ~/.local/bin' 'rsync -a mine/ ~/.claude/skills/mine/' \
  'echo x > ~/.claude/hooks/my-hook.sh' 'ln -sf x ~/.local/bin/other' 'install -m 755 tool ~/.local/bin/tool' \
  'mkdir -p ~/.claude/skills/new && cp SKILL.md ~/.claude/skills/new/' 'cp x ~/.claude/skills/' 'rsync -a ksp ~/.claude/skills' \
  'cat ~/.claude/forge/a >&2' 'cat ~/.claude/forge/a 2>&1 >&-'; do
  allow "$(sh_in "$R" "$c")" "$c"
done
deny live-install "$(sh_in "$R" 'port status; cp x ~/.claude/forge/')" "a port lookalike"
for c in 'cp payload ~/.claude/forge/a && ./port --apply' './port; printf x > ~/.claude/forge/pwn.sh' \
  './port --apply && echo x >> ~/.claude/forge/port.json' "$R/port --apply; rsync -a x/ ~/.claude/forge/" \
  './port --apply; cp x ~/.claude/skills/forge-phase/SKILL.md'; do
  deny live-install "$(sh_in "$R" "$c")" "a live write beside port: $c"
done
HOME=$tmp/bare deny live-install "$(ed_in "$R" "$tmp/bare/.claude/forge/x")" "~/.claude/forge without a manifest"
HOME=$tmp/bare allow "$(ed_in "$R" "$tmp/bare/.claude/skills/forge-phase/SKILL.md")" "a skill without a manifest"
ok live-install
fi

if want planning-path; then
deny planning-path "$(ed_in "$wt" "$wt/.forge/tracks/t.json")" "a main-agent Write of a worktree's tracks file"
grep -qF "write $R/.forge/tracks/t.json" "$tmp/err" || fail "planning-path reason must name the main-worktree path: $(cat "$tmp/err")"
deny planning-path "$(ed_in "$wt" "$wt/.forge/tracks/t.json" forge-planner Edit)" "a subagent Edit of a worktree's tracks file"
mode=planning deny planning-path "$(ed_in "$wt" "$wt/.forge/tracks/t.json" forge-implementer Edit)" "a forge-implementer Edit of a worktree's tracks file through planning mode"
deny planning-path "$(ed_in "$wt/src" ../.forge/tracks/t.json '' Edit)" "a relative path in a worktree"
allow "$(ed_in "$wt" "$R/.forge/tracks/t.json")" "a tracks file in the main worktree"
mode=planning allow "$(ed_in "$R" "$R/.forge/tracks/t.json" forge-implementer Edit)" "a tracks file in the main worktree through planning mode"
allow "$(ed_in "$wt" "$wt/.forge/STACK.md")" "repo docs in a worktree's .forge/"
allow "$(ed_in "$wt" "$wt/src/phases/a.json")" "a phases directory outside .forge/"
allow "$(ed_in "$plain" "$tmp/loose/.forge/tracks/t.json")" "a tracks file outside any repo"
for p in "$wt/tests/fixtures/p/.forge/tracks/crm.json" "$wt/tests/fixtures/p/.forge/phases/02-x/spec.json" "$wt/src/.forge/features/t-f/spec.json"; do
  allow "$(ed_in "$wt" "$p")" "a main-agent Write of nested $p"
  allow "$(ed_in "$wt" "$p" forge-implementer Edit)" "a subagent Edit of nested $p"
done
m=$tmp/merge
git init -q -b main "$m"
mkdir -p "$m/.forge/tracks"
echo '{"a": 0}' >"$m/.forge/tracks/t.json"
echo '{"b": 0}' >"$m/.forge/tracks/u.json"
git -C "$m" add -A && git -C "$m" commit -qm init
mw=$m/.claude/worktrees/t-f-1
git -C "$m" worktree add -q -b forge/t-f-1 "$mw"
echo '{"a": 1}' >"$m/.forge/tracks/t.json" && git -C "$m" commit -qam main
echo '{"a": 2}' >"$mw/.forge/tracks/t.json" && git -C "$mw" commit -qam branch
! git -C "$mw" merge -q main >/dev/null 2>&1 || fail "the merger fixture must conflict"
allow "$(ed_in "$mw" "$mw/.forge/tracks/t.json" forge-merger Edit)" "forge-merger's Edit of a conflicted planning file"
deny planning-path "$(ed_in "$mw" "$mw/.forge/tracks/t.json" forge-implementer Edit)" "another agent's Edit of a conflicted planning file"
deny planning-path "$(ed_in "$mw" "$mw/.forge/tracks/t.json" '' Edit)" "a main-agent Edit of a conflicted planning file"
deny planning-path "$(ed_in "$mw" "$mw/.forge/tracks/u.json" forge-merger Edit)" "forge-merger's Edit of a clean planning file"
git -C "$mw" merge --abort
deny planning-path "$(ed_in "$mw" "$mw/.forge/tracks/t.json" forge-merger Edit)" "forge-merger's Edit with no merge in progress"
ok planning-path
fi

if want orchestrator-code; then
FORGE_PHASE=7 deny orchestrator-code "$(ed_in "$wt" "$wt/src/a.txt")" "a phase orchestrator's Write to code"
grep -q 'spawn forge-fixer / forge-implementer' "$tmp/err" || fail "orchestrator-code reason: $(cat "$tmp/err")"
FORGE_PHASE=7 deny orchestrator-code "$(ed_in "$wt" "$wt/src/new/b.ts" '' Edit)" "a phase orchestrator's Edit in a new directory"
FORGE_PHASE=7 deny orchestrator-code "$(ed_in "$wt" "$wt/n.ipynb" '' NotebookEdit)" "a phase orchestrator's NotebookEdit"
FORGE_ROOT=$R deny orchestrator-code "$(ed_in "$wt/src" "$wt/src/a.txt")" "FORGE_ROOT with a phase worktree cwd"
FORGE_PHASE=7 deny orchestrator-code "$(ed_in "$gitplain" "$gitplain/a.txt")" "a phase orchestrator's Write to a repo under a .git directory"
FORGE_PHASE=7 allow "$(ed_in "$wt" "$wt/src/a.txt" forge-implementer)" "a subagent's Write in a phase session"
FORGE_PHASE=7 allow "$(ed_in "$wt" "$S/phases/07-x/result.json")" "a phase orchestrator's phase record"
FORGE_PHASE=7 allow "$(ed_in "$wt" "$R/.git/worktrees/feat-7/forge-7.diff")" "a phase orchestrator's log in the git dir"
FORGE_PHASE=7 allow "$(ed_in "$wt" "$tmp/scratch/x.md")" "a phase orchestrator's scratch outside any repo"
FORGE_ROOT=$R allow "$(ed_in "$R" "$R/src/a.txt")" "FORGE_ROOT with a cwd outside a phase worktree"
allow "$(ed_in "$wt" "$wt/src/a.txt")" "a session without a phase marker"
ok orchestrator-code
fi

if want old-state; then
olddeny() {
  local s
  s=$(run "$2")
  [ "$s" = 2 ] || fail "$3 must be denied (exit $s): $(cat "$tmp/err")"
  [ "$(wc -l <"$tmp/err")" = 1 ] || fail "$3 must print one line: $(cat "$tmp/err")"
  grep -q '^forge-guard: [a-z-]*: ' "$tmp/err" || fail "$3 must name a rule: $(cat "$tmp/err")"
  grep -qF "$1" "$tmp/err" || fail "$3 must name the state-dir path $1: $(cat "$tmp/err")"
}
for d in "$R" "$wt"; do
  for r in phases/07-x/result.json phases/07-x/plan.json phases/99-new/spec.json features/t-f/spec.json \
    features/t-f/build.json features/t-f/procedure.json features/t-f/x/build.json archive/t-f/docs.json; do
    p=$d/.forge/$r
    olddeny "$S/$r" "$(ed_in "$d" "$p")" "a main-agent Write of $p"
    olddeny "$S/$r" "$(ed_in "$d" "$p" '' Edit)" "a main-agent Edit of $p"
    olddeny "$S/$r" "$(ed_in "$d" "$p" forge-planner Edit)" "a subagent Edit of $p"
    olddeny "$S/$r" "$(ed_in "$d" "$p" '' NotebookEdit)" "a NotebookEdit of $p"
    mode=planning olddeny "$S/$r" "$(ed_in "$d" "$p" forge-implementer)" "a forge-implementer Write of $p through planning mode"
    mode=planning olddeny "$S/$r" "$(ed_in "$d" "$p" forge-implementer Edit)" "a forge-implementer Edit of $p through planning mode"
  done
done
olddeny "$S/phases/07-x/result.json" "$(ed_in "$R/src" ../.forge/phases/07-x/result.json '' Edit)" "a relative path in the main checkout"
olddeny "$S/features/t-f/spec.json" "$(ed_in "$wt/src" ../.forge/features/t-f/spec.json '' Edit)" "a relative path in a worktree"
XDG_STATE_HOME= olddeny "$HOME/.local/state/forge/proj/phases/07-x/result.json" "$(ed_in "$R" "$R/.forge/phases/07-x/result.json")" "an old path with XDG_STATE_HOME unset"
for d in "$R" "$wt"; do
  for c in "jq . x > $d/.forge/phases/07-x/result.json" "echo x >> $d/.forge/phases/07-x/plan.json" \
    "jq . x | tee $d/.forge/features/t-f/build.json" "cp /tmp/x $d/.forge/features/t-f/procedure.json" \
    "mv /tmp/x $d/.forge/archive/t-f/docs.json" "sed -i s/a/b/ $d/.forge/phases/07-x/result.json" \
    "bash -c 'jq . x >$d/.forge/features/t-f/spec.json'" "cd $d && jq . x > .forge/phases/07-x/scout.json"; do
    olddeny "$S/" "$(sh_in "$d" "$c")" "main agent: $c"
    olddeny "$S/" "$(sh_in "$d" "$c" forge-implementer)" "subagent: $c"
  done
done
olddeny "$S/phases/07-x/result.json" "$(sh_in "$R" "jq . x > $R/.forge/phases/07-x/result.json")" "a shell redirect into the main checkout's phases"
for p in "$R/tests/fixtures/p/.forge/phases/02-x/plan.json" "$R/tests/fixtures/p/.forge/features/t-f/build.json" \
  "$wt/tests/fixtures/p/.forge/archive/t-f/docs.json" "$R/src/.forge/phases/02-x/spec.json"; do
  allow "$(ed_in "$R" "$p")" "a main-agent Write of the nested $p"
  allow "$(ed_in "$R" "$p" forge-implementer Edit)" "a subagent Edit of the nested $p"
  mode=planning allow "$(ed_in "$R" "$p" forge-implementer Edit)" "a forge-implementer Edit of the nested $p through planning mode"
  allow "$(sh_in "$R" "jq . x > $p")" "a main-agent shell write of the nested $p"
done
for p in "$tmp/loose/.forge/phases/07-x/result.json" "$tmp/loose/.forge/features/t-f/build.json" "$tmp/loose/.forge/archive/t-f/docs.json"; do
  allow "$(ed_in "$plain" "$p")" "a Write of $p outside any repo"
  mode=planning allow "$(ed_in "$plain" "$p" forge-implementer Edit)" "a planning-mode Edit of $p outside any repo"
  allow "$(sh_in "$plain" "jq . x > $p")" "a shell write of $p outside any repo"
done
for p in "$R/.forge/STACK.md" "$R/.forge/tracks/t.json" "$R/.forge/quick/x/plan.json" "$R/.forge/phasesx/a.json" "$R/src/phases/a.json"; do
  allow "$(ed_in "$R" "$p")" "a main-agent Write of $p"
  mode=planning allow "$(ed_in "$R" "$p" forge-implementer Edit)" "a forge-implementer Edit of $p through planning mode"
done
for p in "$S/phases/07-x/result.json" "$S/features/t-f/build.json" "$S/features/t-f/procedure.json" "$S/phases/07-x/spec.json"; do
  allow "$(ed_in "$R" "$p")" "a main-agent Write of $p"
  mode=planning allow "$(ed_in "$wt" "$p" forge-implementer Edit)" "a forge-implementer Edit of $p through planning mode"
  allow "$(sh_in "$wt" "jq . x > $p")" "a main-agent shell write of $p"
done
ok old-state
fi

if want agent-record; then
P=$S/phases/07-x F=$S/features/t-f
for f in $P/plan.json $P/merge/M1.json \
  $F/docs.json $F/{fixes/F1,merge/forge-M1,research/R1,review/reviewer,review/reviewer-forge,review/reviewer-my-app,review/audit}.json; do
  deny agent-record "$(ed_in "$R" "$f")" "a main-agent Write of $f"
  deny agent-record "$(ed_in "$wt" "$f" '' Edit)" "a main-agent Edit of $f"
  grep -q "rerun the agent; don't edit its record" "$tmp/err" || fail "agent-record reason: $(cat "$tmp/err")"
  ! grep -qi 'escalat' "$tmp/err" || fail "agent-record reason must not name escalating: $(cat "$tmp/err")"
  allow "$(ed_in "$R" "$f" forge-planner)" "a subagent's Write of $f"
  allow "$(ed_in "$wt" "$f" forge-planner Edit)" "a subagent's Edit of $f"
done
XDG_STATE_HOME= deny agent-record "$(ed_in "$R" "$HOME/.local/state/forge/proj/phases/07-x/plan.json")" "a main-agent Write of a record under the default state dir"
XDG_STATE_HOME= allow "$(ed_in "$R" "$HOME/.local/state/forge/proj/phases/07-x/plan.json" forge-planner)" "a subagent's Write of a record under the default state dir"
ln -s "$XDG_STATE_HOME" "$tmp/statelink"
XDG_STATE_HOME=$tmp/statelink deny agent-record "$(ed_in "$R" "$tmp/statelink/forge/proj/phases/07-x/plan.json")" "a main-agent Write of a record through a symlinked state dir"
for f in $P/{result,review,spec,research,scout,gaps,verify,verify.prev,review.prev,escalation}.json \
  $P/diagnoses/D1.json $F/escalation.json $P/{tasks/T1,tests/T1,research/R1,review/reviewer,review/audit,fixes/F1}.json $P/events.jsonl \
  $F/{verify,review,split,spec,ship,design,requirements,research,build,procedure}.json $F/review/forge.json \
  "$S/archive/t-f/docs.json" "$S/archive/t-f/review/reviewer.json" "$S/quicks.json" "$S/debugs.json" "$S/history.json" "$S/root" \
  "$S/plan.json" "$XDG_STATE_HOME/forge/port.json" "$XDG_STATE_HOME/forge/plan.json" "$R/.forge/quick/x/plan.json"; do
  allow "$(ed_in "$R" "$f")" "a main-agent Write of $f"
done
for c in "jq . x > $P/plan.json" "jq '.a = 1' $P/plan.json | sponge $P/plan.json" "sed -i s/a/b/ $P/merge/M1.json" \
  "cp /tmp/x $F/docs.json" "bash -c 'jq . x >$F/research/R2.json'" "jq . x > $F/review/reviewer-forge.json" \
  "echo x >> $F/review/reviewer-forge.json" "cd $S && jq . x > phases/07-x/plan.json"; do
  deny agent-record "$(sh_in "$R" "$c")" "main agent: $c"
  allow "$(sh_in "$R" "$c" forge-planner)" "subagent: $c"
done
for c in "cat $P/plan.json" "jq . $P/plan.json > /tmp/x" "jq . x > $P/result.json" "jq -s . $P/research/*.json > $P/research.json" \
  "sed -i s/a/b/ $P/verify.json" "echo x >> $P/review/reviewer.json" "cd $S && jq . x > phases/07-x/scout.json" \
  "tee $P/gaps.json <x" "jq . x > $P/fixes/F1.json" "cd $S && jq . x > phases/07-x/escalation.json" \
  "tee $P/diagnoses/D1.json <x" "jq . x > $F/escalation.json"; do
  allow "$(sh_in "$R" "$c")" "main agent: $c"
done
ok agent-record
fi

if want port-judge; then
J=$S/port/receipts
mkdir -p "$J/requests" "$J/holdout"
for f in "$J/rules" "$J/requests/r1" "$J/holdout/h1" "$J/answers/r1" "$J/lock" "$J/report.jsonl"; do
  for a in forge-fixer forge-implementer forge-planner; do
    deny port-judge "$(ed_in "$wt" "$f" "$a")" "a $a Write of $f"
    deny port-judge "$(ed_in "$wt" "$f" "$a" Edit)" "a $a Edit of $f"
  done
  grep -q "only the operator changes a /forge-port judge" "$tmp/err" || fail "port-judge reason: $(cat "$tmp/err")"
  allow "$(ed_in "$R" "$f")" "a main-agent Write of $f"
done
for c in "echo x > $J/rules" "echo x >> $J/answers/r1" "cp /tmp/x $J/answers/r1" "mv /tmp/x $J/holdout/h1" "sed -i s/a/b/ $J/rules" \
  "tee $J/lock <x" "cd $S && echo x > port/receipts/rules" "bash -c 'echo x > $J/rules'" "rm -f x; jq . x > $J/answers/r1"; do
  deny port-judge "$(sh_in "$wt" "$c" forge-fixer)" "fixer: $c"
  allow "$(sh_in "$R" "$c")" "main agent: $c"
done
XDG_STATE_HOME= deny port-judge "$(ed_in "$wt" "$HOME/.local/state/forge/proj/port/receipts/rules" forge-fixer)" "a fixer Write under the default state dir"
for f in "$S/phases/07-x/tasks/T1.json" "$wt/src/port.rs" "$R/.forge/port/receipts/spec.json"; do
  allow "$(ed_in "$wt" "$f" forge-fixer)" "a fixer Write of $f"
done
allow "$(sh_in "$wt" "cat $J/report.jsonl > /tmp/r" forge-fixer)" "a fixer reading the judge"
for c in "forge replay lock $J" "forge replay record $J ./old" "forge replay run $J ./new" "cd $wt && forge replay lock /tmp/elsewhere" "$HOME/.local/bin/forge replay lock $J" "forge shadow receipts /tmp/feed"; do
  deny port-judge "$(sh_in "$wt" "$c" forge-fixer)" "fixer: $c"
  allow "$(sh_in "$R" "$c")" "main agent: $c"
done
allow "$(sh_in "$wt" "forge paths" forge-fixer)" "a fixer running another forge command"
ok port-judge
fi

if want conventional-commit; then
for c in 'git commit -m "Update stuff"' 'git commit -m wip' 'git commit --message="wip"' 'git commit --message wip' \
  'git commit -am "wip"' 'git commit -m"wip"' 'git commit -m "feat:x"' 'git commit -m "feat: "' 'git commit -m "feat(): x"' \
  'git add -A && git commit -m "wip"' 'git commit -m "Feat: x"' 'git commit -m "fixup: x"' 'git commit -m "wip" -m "feat: x"' \
  $'git commit -m "$(cat <<\'EOF\'\nwip stuff\n\nbody\nEOF\n)"' $'git commit -m "wip\n\nfeat: x"' 'git commit -m "Merged stuff"' \
  'git commit -m "Revert x"' 'git commit -m "fixup!x"' \
  $'cat > /tmp/commitmsg <<EOF\nfeat: x\nEOF\ngit commit -m "$(cat <<\'EOF\'\nwip\nEOF\n)"' \
  $'git commit -m "$(cat <<\'EOF\'\nfeat: a\nEOF\n)" && git commit -m "$(cat <<\'EOF\'\nwip\nEOF\n)"'; do
  deny conventional-commit "$(sh_in "$R" "$c")" "in R: $c"
done
grep -q 'Conventional Commits' "$tmp/err" || fail "conventional-commit reason: $(cat "$tmp/err")"
deny conventional-commit "$(sh_in "$plain" "git -C $wt commit -m wip")" "a commit aimed at a forge worktree"
deny conventional-commit "$(sh_in "$wt" 'git commit -m wip' forge-fixer)" "a subagent's commit"
for c in 'git commit -m "feat(forge): x"' 'git commit -m "fix: x"' 'git commit -m "fix!: x"' 'git commit -m "refactor(a)!: x"' \
  'git commit -am "chore: x"' 'git commit --message="docs: y"' 'git commit --message "test(x): y"' 'git commit -m"ci: x"' \
  'git commit -m "forge(07): plan"' $'git commit -m "feat: x\n\nbody"' 'git commit -m "feat: x" -m "body"' \
  $'git commit -m "$(cat <<\'EOF\'\nfeat(x): y\n\nit\'s done\nEOF\n)"' $'git commit -m "$(cat <<EOF\n  perf: x\nEOF\n)"' \
  $'git commit -F - <<EOF\nwip\nEOF' 'git commit -F msg.txt' 'git commit' 'git commit --no-edit' 'git commit -m "$MSG"' \
  'git commit -m "$(cat msg.txt)"' 'git log -m' 'git commit -m "revert: x" -- a.txt' 'git commit -m "Revert \"feat: x\""' \
  'git commit -m "fixup! feat: x"' 'git commit -m "squash! fix: y"' 'git commit -m "amend! fix: y"' "git commit -m 'Merge branch x'" \
  $'cat > /tmp/commitmsg <<EOF\nwip\nEOF\ngit commit -m "$(cat <<\'EOF\'\nfeat: x\nEOF\n)"' \
  $'git commit -m "$(cat <<\'EOF\'\nfeat: a\nEOF\n)" && git commit -m "$(cat <<\'EOF\'\nfix: b\nEOF\n)"'; do
  allow "$(sh_in "$R" "$c")" "in R: $c"
done
allow "$(sh_in "$plain" 'git commit -m wip')" "a commit in a non-forge repo"
ok conventional-commit
fi

if want input; then
deny root-checkout "$(sh_in "$R" $'cat <<EOF\nEOF\ngit switch x')" "a command after an empty heredoc"
deny root-checkout "$(sh_in "$R" $'git switch x; cat <<EOF\nline')" "a command before an unterminated heredoc"
allow "$(sh_in "$R" $'cat > n.txt <<EOF\nEOF\ngit status')" "an empty heredoc"
allow "$(sh_in "$R" $'cat > n.txt <<EOF\ngit switch x\nmore')" "an unterminated heredoc runs to the end"
deny root-checkout "$( (printf 'w%d ' $(seq 40000); printf '&& git switch x') | big_in "$R")" "a 40,000-word command"
deny root-checkout "$( (printf 'FOO%d=1 ' $(seq 40000); printf 'git switch x') | big_in "$R")" "40,000 assignments before a command"
deny root-checkout "$( (for i in $(seq 10000); do printf 'env -i timeout -s KILL 5 '; done; printf 'git switch x') | big_in "$R")" "10,000 wrappers before a command"
allow "$( (printf 'cat > n.txt <<EOF\n'; seq 40000) | big_in "$R")" "a 40,000-line unterminated heredoc"
allow "$( (printf 'git commit -m "feat: '; printf 'w%d ' $(seq 40000); printf '"') | big_in "$R")" "a 40,000-word commit message"
allow '{}' "empty input"
allow "$(tool_in "$R" Read)" "an unrelated tool"
s=$(run 'not json')
[ "$s" = 2 ] || fail "invalid input must be denied with exit 2, not $s"
grep -q '^forge-guard: internal error (exit [0-9]*); denied$' "$tmp/err" || fail "invalid input must leave a forge-guard denial note: $(cat "$tmp/err")"
ok input
fi

if want test-bypass; then
printf '%s\n' '# Testing' '- All tests: `make check`.' '- Test: `tests/one.sh {test}`, one suite.' \
  '- Changed tests: `tests/changed.sh {files}`, the covering suites.' >"$wt/.forge/TESTING.md"
tbr() { echo "forge-guard: test-bypass: $1 runs a test suite of $wt/.forge/TESTING.md directly, which"; }
tbs() {
  grep -q 'machine-wide test run semaphore' "$tmp/err" || fail "$1 reason must name forge test's machine-wide test run semaphore: $(cat "$tmp/err")"
  ! grep -q 'slot\|memory cap\|admission registry' "$tmp/err" || fail "$1 reason must not name test slots, the memory cap or the admission registry: $(cat "$tmp/err")"
}
for c in 'make check' 'tests/changed.sh src/a.txt' 'tests/changed.sh src/a.txt hooks/forge-guard.sh' 'tests/changed.sh' \
  'git status && make check' 'forge test; make check' 'make check | tail -5' 'make check 2>&1 | tail' '(make check)' \
  "bash -c 'make check'" "sh -c 'tests/changed.sh src/a.txt'" "env -S 'make check'" 'timeout 600 make check' \
  'env FOO=1 make check' 'nice -n 5 tests/changed.sh src/a.txt' 'FOO=1 tests/changed.sh a b' "timeout 5 bash -c 'git log && make check'"; do
  FORGE_ROOT=$R deny test-bypass "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  tbs "a direct suite run"
  FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
done
for c in 'make check' 'tests/changed.sh src/a.txt'; do
  FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
  grep -q "^$(tbr "$c") .*; run forge test (forge test --changed for the changed suites, forge test --one <id> for one test)$" "$tmp/err" ||
    fail "test-bypass reason for $c: $(cat "$tmp/err")"
done
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt/src" 'make check')" "the All tests command from a subdirectory of the worktree"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$plain" "cd $wt && make check")" "cd into the worktree"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$plain" "env -C $wt tests/changed.sh src/a.txt")" "env -C into the worktree"
for c in "env -C $wt bash -c 'tests/changed.sh src/a.txt'" "env -C $wt sh -c 'git status; make check'" \
  "env -C $R env -C .claude/worktrees/feat-7 bash -c \"bash -c 'make check'\"" "cd $wt && bash -c 'cd $plain' && make check" \
  "bash -c 'cd $wt && make check'"; do
  FORGE_PHASE=7 deny test-bypass "$(sh_in "$plain" "$c")" "a nested shell run in the worktree: $c"
done
for c in "env -C $plain bash -c 'tests/changed.sh a'" "env -C $wt bash -c true; tests/changed.sh a" "bash -c 'cd $wt'; tests/changed.sh a" \
  "env -C $plain sh -c 'cd $wt; true'; tests/changed.sh a" "env -C $plain bash -c 'make check'" "env -C $wt bash -c true; make check" \
  "bash -c 'cd $wt'; make check"; do
  FORGE_PHASE=7 allow "$(sh_in "$plain" "$c")" "a nested shell whose directory does not reach the suite: $c"
done
FORGE_PHASE=7 allow "$(sh_in "$wt" "env -C $plain bash -c 'tests/changed.sh a'")" "a nested shell run outside the worktree"
FORGE_PHASE=7 allow "$(sh_in "$wt" "env -C $plain bash -c 'make check'")" "a nested make run outside the worktree"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'make check' forge-implementer)" "a subagent in a phase session"
tbs "a subagent's direct suite run"
for c in 'forge test' 'forge test --changed' 'forge test --changed --base main' 'forge test --force' 'forge test --one forge-guard' \
  'tests/one.sh forge-guard' 'tests/one.sh forge:validate' "echo 'make check'" 'grep -r tests/changed.sh .' \
  'git status && forge test --changed' 'make lint' 'make' 'make -j8' 'cargo build' 'cargo test' 'npm test' 'cmake --build build'; do
  FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c" forge-implementer)" "FORGE_PHASE from a subagent: $c"
done
for c in 'make check' 'tests/changed.sh src/a.txt' 'git status && make check'; do
  allow "$(sh_in "$wt" "$c")" "outside a forge session: $c"
done
for c in 'tests/changed.sh src/a.txt' 'git status && tests/changed.sh' 'make check' 'git status && make check'; do
  FORGE_ROOT=$R allow "$(sh_in "$R" "$c")" "a repo without TESTING.md: $c"
  FORGE_PHASE=7 allow "$(sh_in "$plain" "$c")" "a non-forge repo: $c"
done
FORGE_PHASE=7 allow "$(printf 'w%d ' $(seq 40000) | big_in "$wt")" "a 40,000-word command in a phase session"
FORGE_PHASE=7 deny test-bypass "$( (printf 'w%d ' $(seq 40000); printf '&& make check') | big_in "$wt")" "a 40,000-word command ending in the suite"
xr='overrides XDG_RUNTIME_DIR, which'
for c in 'XDG_RUNTIME_DIR=/tmp/x forge test' 'env XDG_RUNTIME_DIR=/tmp/x forge test' 'XDG_RUNTIME_DIR= forge test --changed' \
  'FOO=1 XDG_RUNTIME_DIR=/tmp/x forge test --one forge-guard' 'env -i FOO=1 XDG_RUNTIME_DIR=/tmp/x forge test --force' \
  'git status && XDG_RUNTIME_DIR=/tmp/x forge test' 'forge test; env XDG_RUNTIME_DIR=/tmp/x forge test --changed' \
  'XDG_RUNTIME_DIR=/tmp/x forge test 2>&1 | tail' '(XDG_RUNTIME_DIR=/tmp/x forge test)' "bash -c 'XDG_RUNTIME_DIR=/tmp/x forge test'" \
  "sh -c 'git log && env XDG_RUNTIME_DIR=/tmp/x forge test'" "env -S 'XDG_RUNTIME_DIR=/tmp/x forge test'" \
  'timeout 600 env XDG_RUNTIME_DIR=/tmp/x forge test' 'nice -n 5 env XDG_RUNTIME_DIR=/tmp/x forge test --changed' \
  "XDG_RUNTIME_DIR=/tmp/x bash -c 'forge test'" "env XDG_RUNTIME_DIR=/tmp/x sh -c 'git log && forge test --changed'" \
  "XDG_RUNTIME_DIR=/tmp/x bash -c \"FOO=1 bash -c 'forge test'\"" "XDG_RUNTIME_DIR=/tmp/x FOO=1 bash -c 'GIT_DIR=x forge test'"; do
  FORGE_ROOT=$R deny test-bypass "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  grep -q "$xr" "$tmp/err" || fail "the XDG_RUNTIME_DIR reason must name the override: $(cat "$tmp/err")"
  grep -q 'run forge test without XDG_RUNTIME_DIR$' "$tmp/err" || fail "the XDG_RUNTIME_DIR reason must point at forge test: $(cat "$tmp/err")"
  tbs "the XDG_RUNTIME_DIR"
  FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
done
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'env XDG_RUNTIME_DIR=/tmp/x forge test' forge-implementer)" "a subagent overriding XDG_RUNTIME_DIR"
for c in 'forge test''FOO=1 forge test' 'env FOO=1 forge test --changed' 'XDG_RUNTIME_DIR=/tmp/x forge status' \
  'env XDG_RUNTIME_DIR=/tmp/x tests/lint.sh' 'echo XDG_RUNTIME_DIR=/tmp/x forge test' 'XDG_RUNTIME_DIR=/tmp/x true && forge test' \
  "XDG_RUNTIME_DIR=/tmp/x bash -c 'tests/lint.sh'" "XDG_RUNTIME_DIR=/tmp/x bash -c true && forge test" \
  'env XDG_RUNTIME_DIR=/tmp/x make lint' "XDG_RUNTIME_DIR=/tmp/x bash -c 'make lint'"; do
  FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
done
for c in 'XDG_RUNTIME_DIR=/tmp/x forge test' 'env XDG_RUNTIME_DIR=/tmp/x forge test'; do
  allow "$(sh_in "$wt" "$c")" "outside a forge session: $c"
done
FORGE_PHASE=7 deny test-bypass "$( (printf 'w%d ' $(seq 40000); printf '&& XDG_RUNTIME_DIR=/tmp/x forge test') | big_in "$wt")" "a 40,000-word command ending in an XDG_RUNTIME_DIR forge test"
FORGE_PHASE=7 deny test-bypass "$( (printf 'FOO%d=1 ' $(seq 40000); printf 'XDG_RUNTIME_DIR=/tmp/x forge test') | big_in "$wt")" "40,000 assignments before an XDG_RUNTIME_DIR forge test"
printf '%s\n' '# Testing' '- All tests: `npm test`.' '- Test: `npm test -- {test}`, one test.' \
  '- Changed tests: `npm run changed -- {files}`.' >"$wt/.forge/TESTING.md"
for c in 'npm test -- foo' "npm test -- 'a b'" 'git status && npm test -- foo' "bash -c 'npm test -- foo'" \
  'timeout 60 npm test -- foo' 'npm test -- foo &>log' 'npm test -- foo | tail'; do
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "a Test command sharing the All tests words: $c"
done
for c in 'npm test' 'npm test -- foo bar' 'npm test --' 'npm test foo' 'npm test -- foo && npm test' "bash -c 'npm test'" \
  'npm test 2>&1 | tail'; do
  FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" "$c")" "the suite beside an overlapping Test command: $c"
done
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'npm run changed -- a.js')" "a Changed tests command"
for c in 'npm run build' 'cargo build' 'cargo test' 'make -j8' 'pnpm test'; do
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "a build or test outside a TESTING.md line: $c"
done
printf '%s\n' '# Testing' '- All tests: `pytest`.' '- Test: `pytest {test}`.' '- Changed tests: `pytest {files}`.' >"$wt/.forge/TESTING.md"
for c in 'pytest tests/x.py::t' 'env FOO=1 pytest tests/x.py::t' "sh -c 'pytest tests/x.py::t'"; do
  FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "a Test command sharing the suite words: $c"
done
for c in 'pytest' 'pytest a.py b.py' 'pytest tests/x.py::t; pytest'; do
  FORGE_ROOT=$R deny test-bypass "$(sh_in "$wt" "$c")" "the suite beside an overlapping Test command: $c"
done
printf '%s\n' '# Testing' '- All tests: `tests/oneX.sh`.' '- Test: `tests/one?.sh -k={test}`.' >"$wt/.forge/TESTING.md"
FORGE_PHASE=7 allow "$(sh_in "$wt" 'tests/one?.sh -k=foo')" "the Test command with a glob character"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'tests/oneX.sh -k=foo')" "a suite command matching the Test command only as a glob"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'tests/oneX.sh -x')" "a suite command beside a Test command with an embedded placeholder"
printf '%s\n' '# Testing' '- All tests: `run x`.' '- Test: `run +(x) {test}`.' >"$wt/.forge/TESTING.md"
FORGE_PHASE=7 deny test-bypass "$(sh_in "$wt" 'run x foo')" "a suite command matching the Test command only as an extended glob"
FORGE_PHASE=7 deny test-bypass "$( (printf 'w%d ' $(seq 40000); printf '&& run x') | big_in "$wt")" "a 40,000-word command ending in the suite beside a Test command"
rm -f "$wt/.forge/TESTING.md"
mkdir -p "$wt/sub"
for c in 'cargo build' 'cargo build --release' 'cargo test' 'cargo t' 'cargo +nightly test' 'cmake --build build' 'ctest' 'make' 'make -j8' \
  'make check' 'gmake all' 'ninja -C build' 'turbo run test' 'vitest run' 'jest --ci' 'pytest -x tests' 'npm test' 'npm run test' \
  'pnpm test' 'yarn test' "cd $wt/sub && cargo test" "timeout 600 make -j8" "bash -c 'npm test'" 'make -j8 2>&1 | tail -5'; do
  FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "FORGE_ROOT, no TESTING.md: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c")" "FORGE_PHASE, no TESTING.md: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c" forge-implementer)" "FORGE_PHASE from a subagent, no TESTING.md: $c"
  FORGE_PHASE=7 allow "$(sh_in "$plain" "$c" forge-fixer)" "FORGE_PHASE from a subagent in a non-forge repo: $c"
  FORGE_ROOT=$R allow "$(sh_in "$tmp" "$c")" "FORGE_ROOT outside any repo: $c"
done
FORGE_ROOT=$R allow "$( (printf 'make -j8'; printf ' a%d' $(seq 40000)) | big_in "$R")" "a 40,000-word make"
FORGE_PHASE=7 allow "$( (printf 'w%d ' $(seq 40000); printf '&& cargo test') | big_in "$wt")" "a 40,000-word command ending in cargo test"
ok test-bypass
fi

if want jbc-browser; then
jr='forge-guard: jbc-browser: run forge-browser start [--headed] instead of launching Chrome or JBC yourself'
for c in 'chrome --remote-debugging-port=9222' \
  '/opt/google/chrome/chrome --ozone-platform=wayland --remote-debugging-port=9222 --user-data-dir=$HOME/.jev-browser-control/chrome-profile' \
  'nohup google-chrome-stable --user-data-dir=~/.jev-browser-control/chrome-profile' \
  'node ~/.local/share/forge/jbc/server.mjs' \
  'chromium --remote-debugging-port=9222 about:blank' 'git status && chrome --remote-debugging-port=9222' \
  "bash -c 'google-chrome --remote-debugging-port=9222'" 'env FOO=1 timeout 60 node $HOME/.local/share/forge/jbc/server.mjs' \
  'PORT=9222 chrome --remote-debugging-port="$PORT"' \
  'profile="$HOME/.jev-browser-control/chrome-profile"; google-chrome --user-data-dir="$profile"' \
  'chromium --user-data-dir "$HOME/$p"' 'chrome --remote-debugging-port=$(cat port)' 'chrome --user-data-dir=`pwd`'; do
  for d in "$wt" "$plain" "$tmp"; do
    deny jbc-browser "$(sh_in "$d" "$c")" "outside a forge session in $d: $c"
    [ "$(cat "$tmp/err")" = "$jr" ] || fail "jbc-browser reason for $c: $(cat "$tmp/err")"
    deny jbc-browser "$(sh_in "$d" "$c" forge-implementer)" "a subagent outside a forge session in $d: $c"
  done
  FORGE_ROOT=$R deny jbc-browser "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  FORGE_PHASE=7 deny jbc-browser "$(sh_in "$wt" "$c")" "FORGE_PHASE in a worktree: $c"
  FORGE_PHASE=7 deny jbc-browser "$(sh_in "$wt" "$c" forge-implementer)" "FORGE_PHASE from a subagent: $c"
  FORGE_ROOT=$R deny jbc-browser "$(sh_in "$plain" "$c")" "FORGE_ROOT in a non-forge repo: $c"
done
for c in 'forge-browser start --headed' 'forge-browser start' 'forge-browser stop' 'google-chrome https://example.com' \
  'chrome --remote-debugging-port=9333' 'pgrep -f .local/share/forge/jbc/server.mjs' \
  'grep -r remote-debugging-port=9222 .' 'cat ~/.jev-browser-control/chrome-profile/Local\ State' \
  'node other.mjs' 'google-chrome --user-data-dir=$HOME/other-profile' 'chrome --user-data-dir "${HOME}/other"' \
  'chromium --user-data-dir=~/x --remote-debugging-port=9333'; do
  for d in "$wt" "$plain"; do
    allow "$(sh_in "$d" "$c")" "outside a forge session in $d: $c"
  done
  FORGE_ROOT=$R allow "$(sh_in "$wt" "$c")" "FORGE_ROOT in a worktree: $c"
  FORGE_PHASE=7 allow "$(sh_in "$wt" "$c" forge-implementer)" "FORGE_PHASE from a subagent: $c"
done
ok jbc-browser
fi

if want settings; then
m=$(jq -r '.hooks.PreToolUse[]? | select(any(.hooks[]; .command == "sh \"$HOME/.claude/hooks/forge-hook.sh\" forge-guard.sh")) | .matcher' \
  "$root/global/settings.json")
to=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command == "sh \"$HOME/.claude/hooks/forge-hook.sh\" forge-guard.sh") | .timeout' "$root/global/settings.json")
[ "$to" = 15 ] || fail "global/settings.json must give forge-guard a 15 s timeout, got $to"
for t in Bash Edit Write NotebookEdit ScheduleWakeup CronCreate ReadNotifications; do
  [[ "|$m|" == *"|$t|"* ]] || fail "global/settings.json must run forge-guard on $t, matcher: $m"
done
ok settings
fi
[ -z "$only" ] || fail "no case $only"
