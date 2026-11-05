#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export LC_ALL=C

fail() { echo "agents: FAIL $*" >&2; exit 1; }
only=${1:-}
ok() { echo "agents $1: ok"; [ "$1" != "$only" ] || exit 0; }
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
want_any() { local c; [ -z "$only" ] && return; for c; do [ "$c" != "$only" ] || return 0; done; return 1; }

read -r -d '' roster <<'EOF' || true
forge-researcher      sonnet high   yes -            Read Grep Glob WebSearch WebFetch Write mcp__context7__resolve-library-id mcp__context7__query-docs
forge-splitter        opus   high   yes split        Read Grep Glob Write
forge-planner         opus   high   yes plan         Read Grep Glob Write
forge-implementer     opus   high   no  task         Read Grep Glob Write Edit Bash
forge-reviewer        opus   medium yes review       Read Grep Glob Write
forge-fixer           opus   high   no  -            Read Grep Glob Write Edit Bash
forge-debugger        opus   xhigh  yes -            Read Grep Glob Bash Write
forge-mapper          sonnet medium yes -            Read Grep Glob Write
forge-mapper-concerns sonnet high   yes -            Read Grep Glob Write
forge-doc-updater     sonnet medium yes -            Read Grep Glob Edit Write
forge-merger          opus   high   no  -            Read Grep Glob Edit Write Bash
EOF

agent_json() {
  python3 - "$1" <<'PY'
import json, sys, yaml
text = open(sys.argv[1]).read()
_, front, body = text.split("---\n", 2)
meta = yaml.safe_load(front)
tools = meta.get("tools", "")
meta["tools"] = sorted(t.strip() for t in (tools.split(",") if isinstance(tools, str) else tools))
meta["body"] = body
meta["body_lines"] = len(body.splitlines())
print(json.dumps(meta))
PY
}

hook_cmds() { jq -r --arg e "$1" '[.hooks[$e][]? | select(.matcher == "Write|Edit") | .hooks[].command] | sort | join(";")' "$2"; }

too_long() { [ "$(jq .body_lines "$1")" -gt 150 ]; }

if want cap; then
  printf -- '---\nname: x\n---\n' >"$tmp/long.md"
  seq 151 >>"$tmp/long.md"
  agent_json "$tmp/long.md" >"$tmp/long.json"
  too_long "$tmp/long.json" || fail "a 151-line prompt must count as too long"
  sed -i '$d' "$tmp/long.md"
  agent_json "$tmp/long.md" >"$tmp/long.json"
  too_long "$tmp/long.json" && fail "a 150-line prompt is within the cap"
  ok cap
fi

if want roster; then
  want=$(awk '{print $1".md"}' <<<"$roster" | sort)
  have=$(find "$root/agents" -name "*.md" -printf "%f\n" 2>/dev/null | sort || true)
  [ "$want" = "$have" ] || fail "agent files differ from the roster: $(diff <(echo "$want") <(echo "$have") | grep '^[<>]' | tr '\n' ' ')"
  ok roster
fi

if want frontmatter; then
  pre='$HOME/.claude/hooks/forge-agent-write.sh pre'
  post='$HOME/.claude/hooks/forge-agent-write.sh post'
  planning='$HOME/.claude/hooks/forge-guard.sh planning'
  while read -r name model effort guarded schema tools; do
    f=$root/agents/$name.md
    agent_json "$f" >"$tmp/a.json"
    [ "$(jq -r .name "$tmp/a.json")" = "$name" ] || fail "$name: name"
    jq -e '.description | test("forge")' "$tmp/a.json" >/dev/null || fail "$name: description must say forge sessions spawn it"
    [ "$(jq -r .model "$tmp/a.json")" = "$model" ] || fail "$name: model $(jq -r .model "$tmp/a.json"), want $model"
    [ "$(jq -r .effort "$tmp/a.json")" = "$effort" ] || fail "$name: effort $(jq -r .effort "$tmp/a.json"), want $effort"
    [ "$(jq -r '.tools | join(" ")' "$tmp/a.json")" = "$(tr ' ' '\n' <<<"$tools" | sort | paste -sd' ')" ] \
      || fail "$name: tools $(jq -r '.tools | join(" ")' "$tmp/a.json")"
    [ "$(hook_cmds PostToolUse "$tmp/a.json")" = "$post" ] || fail "$name: PostToolUse must run '$post' on Write|Edit"
    if [ "$guarded" = yes ]; then
      [ "$(hook_cmds PreToolUse "$tmp/a.json")" = "$pre" ] || fail "$name: PreToolUse must run '$pre' on Write|Edit"
    else
      [ "$(hook_cmds PreToolUse "$tmp/a.json")" = "$planning" ] || fail "$name: writes code, so PreToolUse runs only '$planning' on Write|Edit"
    fi
    named=$(jq -r .body "$tmp/a.json" | grep -oE '[~$A-Za-z/]*\.claude/forge/schemas/[A-Za-z0-9._-]*' | sort -u | paste -sd' ' || true)
    if [ "$schema" = - ]; then
      [ -z "$named" ] || fail "$name: names no schema, so its prompt must name no ~/.claude/forge/schemas/ path; got $named"
    else
      [ -f "$root/schemas/$schema.schema.json" ] || fail "$name: no schema $schema"
      [ "$named" = "~/.claude/forge/schemas/$schema.schema.json" ] \
        || fail "$name: prompt must name ~/.claude/forge/schemas/$schema.schema.json and no other schema path; got $named"
    fi
    too_long "$tmp/a.json" && fail "$name: prompt is $(jq .body_lines "$tmp/a.json") lines, cap 150"
  done <<<"$roster"
  ok frontmatter
fi

if want background; then
  for name in forge-implementer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    jq -e 'has("background") | not' "$tmp/a.json" >/dev/null \
      || fail "$name: frontmatter must not set background, so a run_in_background: false spawn runs in the foreground; got background: $(jq -c .background "$tmp/a.json")"
  done
  ok background
fi

if want shared-worktree; then
  for name in forge-implementer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    sentences=$(sed 's/\. /.\n/g' <<<"$flat")
    grep -qE 'other agents' <<<"$flat" && grep -qE 'same worktree' <<<"$flat" \
      || fail "$name: prompt must say other agents may be editing other files in the same worktree"
    grep -E 'never|not|n.t ' <<<"$sentences" | grep -E 'touch' | grep -E 'revert' | grep -E 'format' | grep -qE 'stag' \
      || fail "$name: prompt must forbid touching, reverting, formatting or staging other files"
    grep -E 'no git write' <<<"$sentences" | grep -E '`add`' | grep -E '`stash`' | grep -E '`checkout`' | grep -E '`restore`' | grep -E '`reset`' | grep -qE '`commit`' \
      || fail "$name: prompt must forbid git write commands (add, stash, checkout, restore, reset, commit)"
    grep -qE 'wider tier' <<<"$flat" \
      || fail "$name: prompt must run only the task's own test or forge test --one <id>, never a wider tier"
  done
  agent_json "$root/agents/forge-implementer.md" >"$tmp/a.json"
  jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | sed 's/\. /.\n/g' | grep -F -- '`- Test:`' | grep -qF -- '--one' \
    || fail "forge-implementer: prompt must run forge test --one <id> only when the TESTING doc has a '- Test:' line"
  ok shared-worktree
fi

if want heavy; then
  for f in "$root"/agents/*.md; do
    grep -qF 'forge heavy' "$f" && fail "$(basename "$f" .md): prompt must not name forge heavy"
  done
  for name in forge-implementer forge-fixer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    sentences=$(sed 's/\. /.\n/g' <<<"$flat")
    grep -E 'only' <<<"$sentences" | grep -F -- 'forge test --one' | grep -qF 'testing' \
      || fail "$name: prompt must run TESTING.md tests only through forge test --one <id>"
    grep -E 'build' <<<"$sentences" | grep -qE 'directly' \
      || fail "$name: prompt must run builds and other commands directly"
    grep -E 'never|not|no ' <<<"$sentences" | grep -E 'busy' | grep -E 'poll' | grep -qE 'loop' \
      || fail "$name: prompt must forbid busy or polling loops"
    if [[ $name != forge-implementer ]]; then
      grep -E 'never|not|no ' <<<"$sentences" | grep -qE 'more than one background build' \
        || fail "$name: prompt must forbid more than one background build"
    fi
  done
  agent_json "$root/agents/forge-implementer.md" >"$tmp/a.json"
  flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  sentences=$(sed 's/\. /.\n/g' <<<"$flat")
  grep -E 'foreground' <<<"$sentences" | grep -F '600000' | grep -E 'never|not|no ' | grep -qF 'run_in_background' \
    || fail "forge-implementer: one sentence must run builds and tests in the foreground with a 600000 ms timeout, never with run_in_background"
  grep -qE 'more than one background build' <<<"$flat" \
    && fail "forge-implementer: prompt must no longer allow one background build at a time"
  grep -E 'bash' <<<"$sentences" | grep -E 'time limit' | grep -E 'never|not|no ' | grep -E 'rerun' | grep -qE 'background' \
    || fail "forge-implementer: a command that hits the Bash time limit must be recorded and never rerun in the background"
  ok heavy
fi

if want checkpoint-tests; then
  for name in forge-implementer forge-fixer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    sentences=$(sed 's/\. /.\n/g' <<<"$flat")
    grep -E 'exits 75' <<<"$sentences" | grep -E 'memory kill' | grep -qE 'worktree' \
      || fail "$name: prompt must say a run exiting 75 is a repeated memory kill or a worktree-lock wait that gave up"
    grep -qE 'gave up waiting for test memory|test slot' <<<"$flat" \
      && fail "$name: prompt must not say exit 75 is a wait for test memory or a test slot"
  done
  for name in forge-implementer forge-fixer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    grep -qE 'do not rerun it' <<<"$flat" || fail "$name: prompt must not rerun a run that exits 75"
  done
  for name in forge-implementer forge-fixer; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
    grep -qF 'run no test while you work' <<<"$flat" || fail "$name: prompt must run no test while it works"
    grep -qF 'at most 3 runs' <<<"$flat" || fail "$name: prompt must cap its test runs at 3"
  done
  ok checkpoint-tests
fi

if want implementer-test-first; then
  [ ! -e "$root/agents/forge-test-writer.md" ] || fail "agents/forge-test-writer.md must be deleted"
  agent_json "$root/agents/forge-implementer.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  flat=$(tr '\n' ' ' <<<"$body" | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  sentences=$(sed 's/\. /.\n/g' <<<"$flat")
  input=$(awk '/^## /{f=($0=="## Input")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  grep -qF 'test json' <<<"$input" && fail "forge-implementer: input must name no test JSON path"
  grep -qF 'without changing the test files' <<<"$flat" \
    && fail "forge-implementer: prompt must not tell it to pass a test without changing the test files"
  grep -E 'test first' <<<"$sentences" | grep -E 'fail' | grep -qE 'once|one red run' \
    || fail "forge-implementer: prompt must say to write the test first and run it once to see it fail"
  grep -E 'bug' <<<"$sentences" | grep -E 'reproduc' | grep -E 'test' | grep -qE 'before' \
    || fail "forge-implementer: prompt must say to reproduce a bug in a test before fixing it"
  grep -qF '<task> done (exempt: <kind>)' <<<"$body" \
    || fail "forge-implementer: prompt must give the \`<task> done (exempt: <kind>)\` reply"
  grep -qE 'reproduction[ -]only' <<<"$flat" \
    || fail "forge-implementer: prompt must hold the reproduction-only line"
  grep -qF 'fails as expected' <<<"$flat" \
    || fail "forge-implementer: the reproduction-only line must reply \`test <task>: fails as expected\`"
  ok implementer-test-first
fi

if want merger-test-failure; then
  agent_json "$root/agents/forge-merger.md" >"$tmp/m.json"
  grep -qiF 'test failure' <<<"$(jq -r .body "$tmp/m.json")" \
    && fail "forge-merger: prompt must not name a test failure"
  ok merger-test-failure
fi

if want_any planner-deny planner-retry; then
  agent_json "$root/agents/forge-planner.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  input=$(awk '/^## /{f=($0=="## Input")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
fi
if want planner-deny; then
  grep -qF 'Denied Bash patterns:' <<<"$input" \
    || fail "forge-planner: input must name the 'Denied Bash patterns:' lines"
  grep -qF '`none`' <<<"$input" \
    || fail "forge-planner: input must say the patterns line may be none"
  rule=$(awk '/^## /{f=($0=="## Rules")} f' <<<"$body" \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ' | grep -iE 'denied|`deferred`' || true)
  [ -n "$rule" ] || fail "forge-planner: rules must hold a denied-pattern rule naming deferred"
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$rule")
  grep -qF 'Bash(<prefix> *)' <<<"$rule" && grep -qE 'start' <<<"$lower" \
    || fail "forge-planner: the rule must say Bash(<prefix> *) matches a command that starts with <prefix>"
  grep -qE 'never' <<<"$lower" && grep -qE 'agent' <<<"$lower" \
    || fail "forge-planner: a command matching a denied pattern is never an agent task's work"
  grep -qF '`deferred`' <<<"$rule" && grep -qF '`check`' <<<"$rule" && grep -qF '`reason`' <<<"$rule" \
    || fail "forge-planner: the rule must list the command in the plan's deferred array as {check, reason}"
  grep -qE 'exact command' <<<"$lower" \
    || fail "forge-planner: check must state the exact commands to run and what to see"
  grep -qE 'pattern' <<<"$lower" \
    || fail "forge-planner: reason must name the matching pattern"
  grep -qE 'stub' <<<"$lower" && grep -qF 'path' <<<"$lower" \
    || fail "forge-planner: scripts, guards and tests with a PATH stub of the command stay agent tasks"
  grep -qF '.forge/features/' <<<"$body" \
    && fail "forge-planner: prompt must not name .forge/features/"
  ok planner-deny
fi

if want planner-retry; then
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$input")
  sentences=$(sed 's/\. /.\n/g' <<<"$lower")
  retry=$(grep -E '\bretr(y|ies)\b' <<<"$sentences" || true)
  [ -n "$retry" ] || fail "forge-planner: input must state what a retry does"
  grep -qF '`gap:' <<<"$retry" \
    || fail "forge-planner: a retry must be named by its spec ending with \`Gap:\` lines"
  grep -qF 'plan.json' <<<"$retry" && grep -qE 'revis' <<<"$retry" \
    || fail "forge-planner: a retry must revise plan.json"
  grep -qE 'replan reason' <<<"$retry" && grep -qE 'same|as for|like' <<<"$retry" \
    || fail "forge-planner: a retry must revise plan.json the same way as for a replan reason"
  grep -E 'finished tasks' <<<"$sentences" | grep -qE 'keep[^.]*\bids\b' \
    || fail "forge-planner: finished tasks must keep their IDs"
  grep -E 'new tasks' <<<"$sentences" | grep -F '`t<n>`' | grep -E '\bnext\b' | grep -qE 'after the highest' \
    || fail "forge-planner: new tasks must take the next \`T<n>\` IDs after the highest existing one"
  ok planner-retry
fi

if want planner-input; then
  agent_json "$root/agents/forge-planner.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  input=$(awk '/^## /{f=($0=="## Input")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$input")
  sentences=$(sed 's/\. /.\n/g' <<<"$lower")
  grep -qF 'spec.json' <<<"$input" \
    || fail "forge-planner: input must name P/spec.json"
  grep -qE 'doc paths' <<<"$lower" && grep -qE 'output path' <<<"$lower" \
    || fail "forge-planner: input must name the doc paths and the output path"
  for f in research.json scout.json; do
    if grep -qF "$f" <<<"$body"; then fail "forge-planner: input must not name $f"; fi
  done
  grep -E 'reads?' <<<"$sentences" | grep -qE '\b(repo|code)\b' \
    || fail "forge-planner: input must say the planner reads the repo itself"
  rules=$(awk '/^## /{f=($0=="## Rules")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
  grep -qF "task's \`criteria\`" <<<"$rules" && grep -qF '`na_criteria`' <<<"$rules" \
    || fail "forge-planner: rules must still map each criterion to a task's \`criteria\` or \`na_criteria\`"
  if too_long "$tmp/a.json"; then fail "forge-planner: prompt must stay within 150 lines"; fi
  ok planner-input
fi

if want splitter-owner; then
  agent_json "$root/agents/forge-splitter.md" >"$tmp/a.json"
  owner=$(jq -r .body "$tmp/a.json" \
    | awk '/^## /{f=($0=="## Rules"); if (b!="") print b; b=""; next}
        !f {next}
        /^$/ || /^- / {if (b!="") print b; b=$0; next}
        {b=b" "$0}
        END{if (b!="") print b}' \
    | tr -s ' ' | grep -F 'post-ship' || true)
  [ -n "$owner" ] || fail "forge-splitter: a rule must name post-ship requirements"
  [ "$(wc -l <<<"$owner")" = 1 ] || fail "forge-splitter: one rule covers requirement owners: $owner"
  grep -qF '`agent`' <<<"$owner" || fail "forge-splitter: the owner rule maps agent requirements to phases"
  grep -qF '`operator`' <<<"$owner" || fail "forge-splitter: the owner rule keeps operator requirements out of phases"
  grep -qF '`forge alloc`' <<<"$owner" || fail "forge-splitter: the owner rule says forge alloc refuses the split"
  ok splitter-owner
fi

if want splitter-mockup; then
  agent_json "$root/agents/forge-splitter.md" >"$tmp/a.json"
  flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ')
  grep -qF '`<F>/mockups/<surface>.html`' <<<"$flat" \
    || fail "forge-splitter: a UI phase's spec must name each mockup by its absolute path <F>/mockups/<surface>.html"
  grep -qE 'F being the feature directory the spawn prompt gives' <<<"$flat" \
    || fail "forge-splitter: the mockup rule must say F is the feature directory the spawn prompt gives"
  grep -qF '.forge/features/<track>-<feature>/mockups' <<<"$flat" \
    && fail "forge-splitter: the mockup rule must not name .forge/features/<track>-<feature>/mockups"
  if too_long "$tmp/a.json"; then fail "forge-splitter: prompt must stay within 150 lines"; fi
  ok splitter-mockup
fi

if want splitter-focus; then
  agent_json "$root/agents/forge-splitter.md" >"$tmp/a.json"
  rules=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Rules")} f' \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ')
  if grep -qE "subset .*the phase'?s work touches" <<<"$rules"; then
    fail "forge-splitter: the old 'subset ... that the phase's work touches' focus rule must be gone"
  fi
  focus=$(grep -F '`focus`' <<<"$rules" | grep -F '`spec.json`' || true)
  [ -n "$focus" ] || fail "forge-splitter: rules must hold a phase focus rule naming the feature \`spec.json\` \`focus\`"
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$focus")
  grep -qE 'whole (of the )?feature `spec\.json` `focus`' <<<"$focus" \
    || fail "forge-splitter: each phase's focus must be the whole feature \`spec.json\` \`focus\`"
  grep -qF 'Files:' <<<"$focus" && grep -qE 'no source file' <<<"$lower" \
    || fail "forge-splitter: a phase whose Files: bullet lists no source file must carry no focus"
  grep -qE '\bdocs\b' <<<"$lower" && grep -qF '`.forge/`' <<<"$focus" \
    && grep -qE '\btest\b' <<<"$lower" && grep -qE 'configuration' <<<"$lower" \
    || fail "forge-splitter: the no-source-file exception must name docs, \`.forge/\` planning, test and configuration files"
  grep -qE 'out when empty' <<<"$lower" \
    || fail "forge-splitter: a phase's focus must be left out when empty"
  grep -qE 'absent feature `focus`' <<<"$focus" && grep -qE 'no phase carries one' <<<"$lower" \
    || fail "forge-splitter: an absent feature focus must mean no phase carries one"
  for tag in security rate-limit scaling performance pii; do
    grep -qF "\`$tag\`" <<<"$focus" || fail "forge-splitter: the focus rule must list the \`$tag\` tag"
  done
  grep -qF 'five tags' <<<"$focus" \
    || fail "forge-splitter: the focus rule must name five tags"
  body=$(jq -r .body "$tmp/a.json")
  for gone in budget procedure contracts 'Intake:' 'Perf:' 'perf.json' 'Build features' 'build: true'; do
    if grep -qF -- "$gone" <<<"$body"; then fail "forge-splitter: prompt must not name '$gone'"; fi
  done
  grep -qF '`na_criteria`' <<<"$focus" && grep -qE 'planner' <<<"$lower" && grep -qF 'n/a' <<<"$lower" \
    || fail "forge-splitter: the focus rule must say the planner maps criteria that do not apply to \`na_criteria\`, so an over-broad tag costs only n/a lines"
  grep -qE 'When two phases list the same file in the same repo and have no dependency path between them' <<<"$rules" \
    || fail "forge-splitter: the shared-file \`depends\` rule must stay"
  ok splitter-focus
fi

if want prompts-pruned; then
  for name in forge-planner forge-mapper-concerns; do
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ')
    for gone in budget 'forge perf check'; do
      if grep -qiF -- "$gone" <<<"$flat"; then fail "$name: prompt must not name '$gone'"; fi
    done
    too_long "$tmp/a.json" && fail "$name: prompt is $(jq .body_lines "$tmp/a.json") lines, cap 150"
  done
  agent_json "$root/agents/forge-mapper-concerns.md" >"$tmp/a.json"
  tags=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ' | grep -oE 'one of `security`, `rate-limit`, `scaling`, `performance`, `pii`\.' || true)
  [ -n "$tags" ] || fail "forge-mapper-concerns: the focus rule must list exactly \`security\`, \`rate-limit\`, \`scaling\`, \`performance\`, \`pii\`"
  ok prompts-pruned
fi

if want planner-na-files; then
  agent_json "$root/agents/forge-planner.md" >"$tmp/a.json"
  nafiles=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Rules")} f' \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ' | grep -F '`na_files`' || true)
  [ -n "$nafiles" ] || fail "forge-planner: rules must hold a rule naming plan.json \`na_files\`"
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$nafiles")
  grep -qF '`Files:`' <<<"$nafiles" && grep -qE '(every|each) path' <<<"$lower" && grep -qE 'spec' <<<"$lower" \
    || fail "forge-planner: the na_files rule must cover every path the phase spec's \`Files:\` bullet names"
  grep -qE "task'?s? \`files\`" <<<"$nafiles" \
    || fail "forge-planner: each Files: path must go in some task's \`files\` or in \`na_files\`"
  grep -qF '`{file, reason}`' <<<"$nafiles" \
    || fail "forge-planner: an na_files entry must be \`{file, reason}\`"
  grep -qE 'one-line' <<<"$lower" \
    || fail "forge-planner: an na_files entry must carry a one-line reason"
  for why in 'read-only reference' 'owned by another phase' 'path drifted'; do
    grep -qF "$why" <<<"$lower" || fail "forge-planner: the na_files rule must give '$why' as an example reason"
  done
  if grep -qE 'backtick' <<<"$lower"; then
    fail "forge-planner: the na_files rule must not mention backticked paths; only Files: entries count"
  fi
  ok planner-na-files
fi

if want fixer-gaps; then
  agent_json "$root/agents/forge-fixer.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  rule=$(awk '/^## /{f=($0=="## Rules")} f' <<<"$body" \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ' | grep -F '`needs plan: `' || true)
  [ -n "$rule" ] || fail "forge-fixer: rules must hold a 'needs plan: ' summary rule"
  grep -qF '`failed`' <<<"$rule" \
    || fail "forge-fixer: the 'needs plan: ' rule must report status failed"
  input=$(awk '/^## /{f=($0=="## Input")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$input")
  grep -qE 'walkthrough step' <<<"$lower" \
    || fail "forge-fixer: input must name the walkthrough step's text"
  grep -qE "operator'?s reply" <<<"$lower" \
    || fail "forge-fixer: input must name the operator's reply"
  grep -qF 'E/s<k>/' <<<"$input" \
    || fail "forge-fixer: input must name the step's E/s<k>/ evidence paths"
  ok fixer-gaps
fi

if want fixer-outcomes; then
  agent_json "$root/agents/forge-fixer.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  rules=$(awk '/^## /{f=($0=="## Rules")} f' <<<"$body" \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ')
  for p in '`not a defect: `' '`out of scope: todo: <reason>`' '`spec requires: <spec bullet or decision>`' '`needs plan: `'; do
    grep -qF -- "$p" <<<"$rules" || fail "forge-fixer: rules must name the $p outcome"
  done
  bad=$(grep -nF 'out of scope: phase' <<<"$body" || true)
  [ -z "$bad" ] || fail "forge-fixer: the fixer must offer only \`out of scope: todo: <reason>\`, no \`out of scope: phase\`:" "$bad"
  scope=$(grep -F '`out of scope: todo: <reason>`' <<<"$rules" || true)
  grep -qF '`failed`' <<<"$scope" \
    || fail "forge-fixer: the 'out of scope: ' rule must report status failed"
  grep -qiF 'owner is valid' <<<"$scope" \
    && fail "forge-fixer: the 'out of scope: todo' rule must not wait on a valid owner"
  grep -qiE 'later todo' <<<"$scope" \
    || fail "forge-fixer: the 'out of scope: todo' owner must be a later todo"
  grep -qiE 'change[s]? nothing' <<<"$scope" \
    || fail "forge-fixer: the fixer must change nothing for an out-of-scope finding"
  spec=$(grep -F '`spec requires: <spec bullet or decision>`' <<<"$rules" || true)
  grep -qF '`failed`' <<<"$spec" \
    || fail "forge-fixer: the 'spec requires: ' rule must report status failed"
  why=$(sed 's/`spec requires: <spec bullet or decision>`//' <<<"$spec")
  grep -qiE '\bspec\b' <<<"$why" && grep -qiE 'decision' <<<"$why" \
    || fail "forge-fixer: the 'spec requires: ' rule must apply when the spec or a feature decision mandates the behavior"
  grep -qiE 'asks? the operator' <<<"$spec" \
    || fail "forge-fixer: the 'spec requires: ' rule must say the session asks the operator"
  bad=$(grep -niE 'escalat' "$root/agents/forge-fixer.md" || true)
  [ -z "$bad" ] || fail "forge-fixer: prompt must not say the session escalates:" "$bad"
  sentences=$(tr '[:upper:]' '[:lower:]' <<<"$rules" | tr '\n' ' ' | sed 's/\. /.\n/g')
  grep -E '\bnever\b' <<<"$sentences" | grep -E 'dismiss|not a defect' | grep -qE '\bholds?\b|holding' \
    || fail "forge-fixer: rules must never report a dismissal for a finding that holds"
  input=$(awk '/^## /{f=($0=="## Input")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
  grep -qiE 'owner phase' <<<"$input" \
    && fail "forge-fixer: input must not give F/split.json to name an owner phase"
  ok fixer-outcomes
fi

if want fixer-tests; then
  agent_json "$root/agents/forge-fixer.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  rules=$(awk '/^## /{f=($0=="## Rules")} f' <<<"$body" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  sentences=$(sed 's/\. /.\n/g' <<<"$rules")
  grep -E 'third run' <<<"$sentences" | grep -E 'still fails' | grep -qF '`failed`' \
    || fail "forge-fixer: rules must report \`failed\` when the third run still fails"
  grep -E 'no test covers' <<<"$sentences" | grep -qE 'runs? no test' \
    || fail "forge-fixer: rules must say a fix to a file no test covers runs no test"
  flat=$(tr '\n' ' ' <<<"$body" | tr -s ' ' | tr '[:upper:]' '[:lower:]')
  grep -qF 'the session runs the changed tests' <<<"$flat" \
    && fail "forge-fixer: prompt must no longer say the session runs the changed tests"
  grep -E 'feature verify' <<<"$sentences" | grep -qE 'runs the changed tests' \
    || fail "forge-fixer: rules must say feature verify runs the changed tests"
  ok fixer-tests
fi

if want reviewer-security; then
  agent_json "$root/agents/forge-reviewer.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ')
  sentences=$(tr '[:upper:]' '[:lower:]' <<<"$body" | sed 's/\. /.\n/g')
  for t in '`[security]`' '`[pii]`' '`[auth]`'; do
    grep -qF -- "$t" <<<"$body" || fail "forge-reviewer: must ask for the $t title tag"
  done
  tag=$(grep -F '`[security]`' <<<"$sentences" || true)
  for w in authentication authorization secret injection personal-data; do
    grep -qF "$w" <<<"$tag" || fail "forge-reviewer: the title tag must cover a $w finding"
  done
  grep -qE 'title' <<<"$tag" && grep -qF '`: `' <<<"$tag" \
    || fail "forge-reviewer: the tag must start the title, the summary before the first ': '"
  grep -E 'security[- ]class' <<<"$sentences" | grep -E '\bhigh\b' | grep -E '\bopen\b' | grep -qE 'asks? the operator' \
    || fail "forge-reviewer: the keep-and-dismiss rule must not apply to a high security-class finding, which stays open for the session to ask the operator"
  bad=$(grep -niE 'settled|escalat' "$root/agents/forge-reviewer.md" || true)
  [ -z "$bad" ] || fail "forge-reviewer: prompt must name no F/settled.json, settled item or Escalate:" "$bad"
  ok reviewer-security
fi

if want record-shape; then
  while read -r name fields; do
    [ "$(awk -v n="$name" '$1 == n {print $5}' <<<"$roster")" = - ] \
      || fail "$name: its schema is gone, so its roster entry must be '-'"
    agent_json "$root/agents/$name.md" >"$tmp/a.json"
    out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
    [ -n "$out" ] || fail "$name: prompt must have an Output section"
    grep -qF 'schemas/' <<<"$out" && fail "$name: Output must state the record shape in prose, not cite a schema"
    grep -qiE 'valid against|validates every write' <<<"$out" \
      && fail "$name: the write hook only checks the file parses as JSON, so Output must not claim it validates against a schema"
    for k in $fields; do
      grep -qF -- "\`$k\`" <<<"$out" || fail "$name: Output must name \`$k\` in the record shape"
    done
  done <<'EOF'
forge-researcher questions question answer sources
forge-fixer file line status fixed failed summary
forge-debugger symptom symptoms expected actual errors reproduction hypotheses hypothesis test evidence verdict open confirmed eliminated checkpoints question type verify action decision options answer outcome root-cause checkpoint inconclusive root_cause summary locations repo file line
forge-mapper focus docs doc sections heading bullets
forge-mapper-concerns concerns id area files severity evidence status
forge-doc-updater docs path change
forge-merger files path resolution dropped side line reason
EOF
  agent_json "$root/agents/forge-researcher.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qF 'exactly one entry' <<<"$out" || fail "forge-researcher: Output must hold exactly one entry in \`questions\`"
  grep -qiE '`sources`[^.]*string|string[^.]*`sources`' <<<"$out" || fail "forge-researcher: Output must say \`sources\` is a list of strings"
  agent_json "$root/agents/forge-fixer.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qiE '`line`[^.]*(at least 1|positive|1 or more|from 1)' <<<"$out" || fail "forge-fixer: Output must say \`line\` is at least 1"
  agent_json "$root/agents/forge-debugger.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qiE '`locations`[^.]*at least one|at least one[^.]*`locations`' <<<"$out" || fail "forge-debugger: Output must say \`root_cause\` holds at least one entry in \`locations\`"
  grep -qiE '`line`[^.]*(at least 1|positive|1 or more|from 1)' <<<"$out" || fail "forge-debugger: Output must say a location's \`line\` is at least 1"
  agent_json "$root/agents/forge-mapper.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qE '`focus`[^.]*tech[^.]*arch[^.]*quality' <<<"$out" || fail "forge-mapper: Output must say \`focus\` is one of \`tech\`, \`arch\` or \`quality\`"
  grep -qiE '`bullets`[^.]*string|string[^.]*`bullets`' <<<"$out" || fail "forge-mapper: Output must say \`bullets\` is a list of strings"
  agent_json "$root/agents/forge-mapper-concerns.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qE '`id`[^.]*C-(NN|\[0-9\])' <<<"$out" || fail "forge-mapper-concerns: Output must say \`id\` is of the form C-NN"
  grep -qE '`severity`[^.]*high[^.]*medium[^.]*low' <<<"$out" || fail "forge-mapper-concerns: Output must say \`severity\` is one of \`high\`, \`medium\` or \`low\`"
  grep -qE '`status`[^.]*open[^.]*resolved' <<<"$out" || fail "forge-mapper-concerns: Output must say \`status\` is \`open\` or \`resolved\`"
  grep -qE '`evidence`[^.]*path:line' <<<"$out" || fail "forge-mapper-concerns: Output must say each \`evidence\` entry is a path:line"
  agent_json "$root/agents/forge-merger.md" >"$tmp/a.json"
  out=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Output"); next} f' | tr '\n' ' ' | tr -s ' ')
  grep -qE '`side`[^.]*`ours`[^.]*`theirs`' <<<"$out" || fail "forge-merger: Output must say \`side\` is \`ours\` or \`theirs\`"
  ok record-shape
fi

if want doc-updater-input; then
  agent_json "$root/agents/forge-doc-updater.md" >"$tmp/a.json"
  body=$(jq -r .body "$tmp/a.json")
  flat=$(tr '\n' ' ' <<<"$body" | tr -s ' ')
  input=$(awk '/^## /{f=($0=="## Input"); next} f' <<<"$body" | tr '\n' ' ' | tr -s ' ')
  for f in spec.json requirements.json split.json; do
    grep -qF "F/$f" <<<"$input" || fail "forge-doc-updater: Input must name F/$f"
  done
  grep -qF 'FEATURE.md' <<<"$flat" && fail "forge-doc-updater: FEATURE.md is no longer rendered, so the prompt must not name it"
  grep -qF 'bin/forge.d/forge.jq' <<<"$flat" || fail "forge-doc-updater: the sentences rule must cite bin/forge.d/forge.jq"
  grep -qF 'render.jq' <<<"$flat" && fail "forge-doc-updater: templates/render.jq is gone, so the prompt must not name it"
  grep -qF 'rendered; never edit it' <<<"$flat" || fail "forge-doc-updater: the 'rendered; never edit it' line must stay"
  ok doc-updater-input
fi

if want merger-rendered; then
  agent_json "$root/agents/forge-merger.md" >"$tmp/a.json"
  flat=$(jq -r .body "$tmp/a.json" | tr '\n' ' ' | tr -s ' ')
  grep -qiE 'render' <<<"$flat" && fail "forge-merger: forge merge no longer handles rendered files, so the prompt must name no rendered file or re-render"
  for f in STATE.md 'tracks/*.md' FEATURE.md PHASE.md; do
    grep -qF "$f" <<<"$flat" && fail "forge-merger: the prompt must not list $f as a conflict kind"
  done
  ok merger-rendered
fi

if want doc-updater-limits; then
  agent_json "$root/agents/forge-doc-updater.md" >"$tmp/a.json"
  [ "$(jq -r '.tools | join(" ")' "$tmp/a.json")" = "Edit Glob Grep Read Write" ] \
    || fail "forge-doc-updater: tools must stay Read, Grep, Glob, Edit, Write so it runs nothing itself; got $(jq -c .tools "$tmp/a.json")"
  rules=$(jq -r .body "$tmp/a.json" | awk '/^## /{f=($0=="## Rules")} f' \
    | awk '/^- /{if (b!="") print b; b=$0; next} /^  /{b=b" "$0; next} {if (b!="") print b; b=""} END{if (b!="") print b}' \
    | tr -s ' ')
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$rules")
  sentences=$(sed 's/\. /.\n/g' <<<"$lower")
  grep -E '\bdoc\b' <<<"$sentences" | grep -qE 'at most `?8192`? bytes' \
    || fail "forge-doc-updater: rules must state a doc is at most 8192 bytes"
  bullet=$(grep -E 'at most `?300`? characters' <<<"$lower" || true)
  [ -n "$bullet" ] || fail "forge-doc-updater: rules must state a bullet is at most 300 characters"
  grep -qF '`- `' <<<"$bullet" && grep -qE 'more-indented continuation lines' <<<"$bullet" && grep -qE '\bjoined\b' <<<"$bullet" \
    || fail "forge-doc-updater: the 300-character rule must define a bullet as a \`- \` line plus its more-indented continuation lines, joined"
  phrases=$(grep -F '`no longer`' <<<"$lower" || true)
  [ -n "$phrases" ] || fail "forge-doc-updater: rules must name the history phrases in backticks"
  for p in '`now `' '`no longer`' '`was `' '`previously`' '`used to`'; do
    grep -qF -- "$p" <<<"$phrases" || fail "forge-doc-updater: the history-phrase rule must name $p in backticks"
  done
  grep -qE 'word start|start of a word' <<<"$phrases" && grep -qE 'outside backticks' <<<"$phrases" \
    || fail "forge-doc-updater: the history-phrase rule must apply at a word start outside backticks"
  grep -E 'wrong' <<<"$sentences" | grep -E '\breplaces?\b' | grep -E 'in place' | grep -E 'instead of append' | grep -qE 'correct' \
    || fail "forge-doc-updater: rules must replace a bullet the diff makes wrong in place instead of appending a correcting one"
  grep -E '\btargets?\b' <<<"$sentences" | grep -E '\bmeet' | grep -qE '\bedit' \
    || fail "forge-doc-updater: rules must state the limits as targets it meets when it edits a doc"
  grep -qE 'until .*\bpass|\bblock|\bfail' <<<"$lower" \
    && fail "forge-doc-updater: rules must not say a limit violation blocks, fails or must pass"
  ok doc-updater-limits
fi

[ -z "$only" ] || fail "no case $only"
