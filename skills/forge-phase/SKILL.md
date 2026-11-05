---
name: forge-phase
description: Run one forge phase session, or its retry, from plan through tasks and sync to its result and forge finish.
argument-hint: '<root> <N>'
disable-model-invocation: true
hooks:
  Stop:
    - hooks:
        - type: command
          command: $HOME/.claude/hooks/forge-phase-stop.sh
---
# forge-phase

`$ARGUMENTS`: project root `R`, phase `N`. Run it in its worktree `W`, the cwd.

## Rules
- First run `FORGE_ROOT=R forge paths N`; use its `R`, `F`, `P`, `W`, `B`,
  `BASE` and `G` values verbatim. Then read `P/spec.json` and check
  `ListAgents` for a peer session `<project> P<N>[R<k>] <track>/<feature>`
  (`<project>`: basename of R; older runs used
  `<project> <track>-<feature> Phase N[ retry <k>]` and
  `<repo> <feature> Phase N`, so accept those too) other than this one;
  a session started outside `forge implement`/`resume`/`done`/`next` skips
  their guard. With a live peer, touch nothing (no write, no `forge` call)
  and end the turn with `blocked: phase N already has a running session <name>`.
- Never ask the operator and never wait for one. Decide every blocker
  yourself: take the option with the least work that keeps the task
  correct, append it to `spec` in `P/spec.json` as
  `Decision: <what and why>`, and go on; a check only a human can run is
  logged as a `deferred` event and treated as settled.
- A check only a human can run (manual, device, live-account or visual) is
  deferred to verify and never asked about: log it with
  `FORGE_ROOT=R forge event N deferred "$(jq -cn --arg check '<check>' --arg reason '<reason>' '{$check,$reason}')"`,
  treat it as settled for this phase and go on. Never run a retry for it.
  A check that a surface matches its approved
  mockup is not such a check: feature verify meets it from the code, and it
  is never logged as a `deferred` event.
- Spawn `forge-planner` with the Agent tool's `run_in_background: false` on every call: the report is the
  tool result in the same turn, and a Bash command such an agent starts
  stops when its run ends. Put the independent
  spawns of one step in one message, each with `run_in_background: false`;
  the turn goes on once all have returned. If such a call returns an
  async-launch result instead of the report, end the turn with no result
  line and treat it as a background agent.
- Spawn `forge-implementer` with `run_in_background: true`, then end the
  turn with no result line; each
  completion notification resumes you. Wait for background commands the
  same way. Never `ScheduleWakeup`, `CronCreate`, a `sleep` poll,
  `ReadNotifications` or a `pgrep`/`ps` loop on another session's process.
- `FORGE_FOREGROUND_TASKS` foreground mode: if `echo "${FORGE_FOREGROUND_TASKS:-}"`
  prints 1 each wake, spawn `forge-implementer` with
  `run_in_background: false`, ready tasks in one message; once the message
  returns, run `forge task-done` one at a time, respawns and newly ready tasks
  in the next message, never ending the turn.
- A step stopped by another phase or feature parks: log `FORGE_ROOT=R forge event N park <cond>`, `<cond>` being
  `wait <ref>` (another phase or feature edits a task's files or feeds
  it; `<ref>` is `<N>` in R, `<abs-root>:<N>` for the project at
  `<abs-root>`, `<track>/<feature>` until that feature ships, or
  `branch <name>` until `<name>` is merged into `main`; log
  `park "wait <ref>"` quoted), write no `P/result.json` and end the turn
  with `result: Phase N parked on <cond>`. Any other wait is never a park:
  decide it yourself (the no-ask Rules bullet).
- On the prompt
  `forge watchdog: <cond> cleared; continue phase <N> from where it parked`,
  run the first rule's peer-session check, then continue at the first step
  whose output is missing, rerunning the parked command.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`. Follow the reason; never work around it
  (`bash -c`, variables, scripts); decide it yourself (the no-ask Rules
  bullet) instead. It enforces: you never edit code (spawn
  `forge-implementer`); you never edit an agent's record (`plan` JSON and
  `merge/`; rerun the agent); planning JSON goes under `P`/`F`, never `W/.forge/`;
  no branch switch, stash, reset, rebase or merge in R's main checkout
  (other-branch work goes in a worktree under `<repo>/.claude/worktrees/`
  or the job tmp dir).
- When a task's test run fails in a test file outside the plan's files
  because a sibling phase or `BASE` changed what it expects, spawn
  `forge-planner` with `run_in_background: false` to revise `P/plan.json`
  (keep finished tasks with their IDs and records) with one more
  implementer task whose files are that test file, the reason being the
  failing test and its log, run `FORGE_ROOT=R forge plan-done N`, then
  run that task under the task budget and commit it through
  `forge task-done`; never edit `P/plan.json` yourself.
- When a task needs a tool, login, environment variable or secret the
  host lacks, run
  `FORGE_ROOT=R forge task-done N <id> --unmet "<probe and its output>"`
  (the command that showed it missing and what it printed) and go on
  with the next ready task.
- Run `forge` as `FORGE_ROOT=R forge <command>`; `--help` documents each.
  Edit planning JSON. Diffs and logs go to `G`.
- Doc paths: `R/.forge/PROJECT.md`, `RULES.md`, `REJECTED.md`, and TESTING and
  the ARCHITECTURE, STACK and CONVENTIONS under `W/.forge/`.
- Spawn agents by type, description `P<N> <step> <agent>` or
  `P<N> T<k> <agent>`. Each prompt pastes the `forge paths` lines and gives
  the paths its agent's Input names and the output path, absolute under `P`
  or `F`. Agents never commit; code in `W` is committed one commit per
  task, each staging only its own files by path, as Conventional Commits
  (`feat(<scope>): ...`); `forge(...)` subjects are `forge commit`'s.
  `forge task-done` commits a task (step 2).
- A phase never runs the full suite or the changed tests: ship runs the
  full suite once and feature verify runs the changed tests. A phase runs
  only its tasks' own test commands (the implementer's and
  `forge task-done`'s). A `forge test` run ends with
  `forge: tests passed (<tree>)` or `forge: tests failed, log <path>`.
  Task test commands stay narrow, in the foreground, one task at a time
  after its agent completes, run only by `FORGE_ROOT=R forge task-done N <id>`
  when the agent's record holds no usable exit (step 2): a task's recorded
  command or `forge test --one <id>`, which takes one machine-wide test run
  slot.
- Retest: a `forge test` that exits 75 after a memory kill repeated after
  its retry or a worktree-lock wait that gave up, or a background
  `forge test` that ends without a `forge: tests passed` or
  `forge: tests failed` line (status `killed`, or exit 0, 75, 137 or 143),
  is rerun. Read the last lines of its output file first: either forge line
  decides, whatever the status or exit says. Rerun it up to 3 times per
  step, each background rerun with an explicit Bash `timeout`, logging each
  with `FORGE_ROOT=R forge event N retest "<step> <attempt>"`; this rule
  overrides a harness note not to start the task again. A retest is never a
  test failure and never an implementer's input; when the third rerun ends
  the same way, decide it yourself (the no-ask Rules bullet).
- Test logs: a failure log can be the runner's summary, one
  `ok <suite> (<s>s)` or `FAIL <suite> (exit <s>, <s>s, log <path>)` line
  per suite. Read the per-suite log each `FAIL` line names, under
  `G/forge-test.d/` (the suite's path relative to `tests/`, extension
  `.log`), and give those paths to the implementer.
- Proof loop: `forge test --repeat N --one <id>` (N a run count, not the
  phase number) is the proof loop that shows a fix or a flaky case holds.
  It takes one machine-wide test run slot and runs the test up to N times,
  stopping at the first failing run with
  `forge: repeat failed on iteration <i>/<N>`;
  all passing prints `forge: repeat passed <N>/<N>`. Name it in an
  implementer's prompt when its task targets a flaky test.
- Run the steps in order. After each step run
  `FORGE_ROOT=R forge commit N <step>`; it prints
  `forge: recorded <scope> <step>` and commits nothing, since the step's
  records live under `P`/`F` in the state dir. Start at the first
  step whose output is missing; the plan counts as missing when the last
  `retry` or `replan` event follows the last `check` event in
  `P/events.jsonl`, even though `P/plan.json` exists. A task is finished
  when `P/tasks/<id>.json` has `"status": "done"` or `"status": "unmet"`.
  `forge commit` refuses
  (exit 1) a step whose records are missing, naming the file: run the step that writes it, never
  a later step. A write under `W/.forge` is denied at write time, naming
  the path under `P`/`F` to write instead.
- Never pass a model or effort override to an Agent spawn.

## Budgets
Implementer 2 attempts per task, plan check 2 replans. When a task's
attempts run out, run
`FORGE_ROOT=R forge task-done N <id> --unmet "<one-line reason>"` and go on
with the next ready task; when the replans run out, keep the last plan.
Nothing here asks the operator or ends the phase blocked.

## Resolver loop
Read ~/.claude/skills/forge-phase/resolver-loop.md and follow it.

## Steps
1. Plan. Before spawning `forge-planner`, read the denied Bash patterns with
   `jq -r '(.permissions.deny // [])[] | select(startswith("Bash("))' ~/.claude/settings.json`;
   a missing file means no patterns, and on any other read or jq failure
   decide it yourself (the no-ask Rules bullet) from its stderr. Spawn `forge-planner` with
   `run_in_background: false`, `P/spec.json`, the doc paths and
   `Denied Bash patterns:` followed by one pattern per line, or `none`, output
   `P/plan.json`; replans pass them too. Spawn it also when the last `retry`
   or `replan` event follows the last `check` event in `P/events.jsonl`,
   even though `P/plan.json` exists.
   When `P/events.jsonl` has a `retry` or `replan` event, the prompt also says:
   the branch already holds this phase's earlier work; revise the existing
   `P/plan.json`, keep finished tasks with their IDs and records in
   `P/tasks/`, add tasks only for what the `Gap:` lines need,
   plus what the `Decision:` lines and the event need, and list each
   requirement already met on one of those tasks. Then run
   `FORGE_ROOT=R forge plan-done N`; replans rerun it. Exit 1: replan with
   the printed failures as the reason. Exit 0 or 3: the plan passed and is
   committed. After exit 3, end the turn with
   `result: Phase N waits on <M>, …` as printed; write no `P/result.json`, skip Finish.
   After exit 0, before the first task, run the resolver loop with `BASE`.
2. Tasks. Before the first unfinished
   task, when a phase in `depends` of `P/spec.json` has no `result.json` with
   `"status": "done"`, end the turn with `result: Phase N waits on <those phases>`.
   A task is ready when it is unfinished, no agent of it is running, every
   task in its `deps` is done and its files are disjoint from those of every
   task in flight. Spawn the agents of the ready tasks in one
   message, up to `FORGE_TASK_CONCURRENCY` agents at once (default 3; above
   20 counts as 20); a dependent task waits for its deps.
   For every ready task spawn `forge-implementer` with
   `run_in_background: true` (`false` in foreground mode), `P/plan.json`,
   the task ID, `P/spec.json`, the doc paths and `P/tasks/<id>.json`.
   After each agent completes, or its message returns in foreground mode,
   run `FORGE_ROOT=R forge task-done N <id>` for
   that task only, one task at a time, never assuming completion order.
   Trust the agent's recorded run, as `forge task-done` does: feature
   verify's changed tests catch what a sibling task's later edit breaks. Its
   exit decides:
   - 0: the task is committed; spawn the newly ready tasks. After a `retry`
     or `replan` event a pass, run or recorded, means the work already
     exists.
   - 5: respawn the implementer with the printed `G/forge-N-<id>.log`;
     after the implementer's 2 attempts in Budgets, run the Budgets path.
   - 1: run the Budgets path with its stderr.
   A respawn on 5 respawns only that task's agent; the others keep going.
   Foreground mode spawns in the next message; otherwise wait by ending the
   turn with no result line.
   On every resume recompute the ready set from `P/tasks/`. Make no
   foreground spawn while an implementer wake-up is pending in this step,
   since queued notifications
   wait until the turn ends: wait for the running agents first.
3. Sync. Run the resolver loop with `BASE`, so `forge done`'s
   merge into `BASE` is clean. It writes no step file, so a session
   resuming before Result reruns it; an up-to-date merge exits 0.
4. Result. Write `P/result.json`: `"status": "done"` and a one-sentence
   `summary`. Add `unmet`, only when non-empty: one
   `{"task": "<id>", "reason": "<reason>"}` per `P/tasks/<id>.json` at
   `"status": "unmet"`, plus any `sync` entry the resolver loop appended,
   and name each unmet task in `summary`. Add `deferred`, only when non-empty: the `deferred` events of
   `P/events.jsonl` not logged from a plan
   (`jq -s '[.[] | select(.step == "deferred") | .message | fromjson | select(.plan != true) | {check, reason}]'`)
   plus the `deferred` entries of the current `P/plan.json`, so a check a
   replan dropped is never kept, unique by `check`.
   Run Finish.

## Finish
Run `FORGE_ROOT=R forge finish N`: it commits `result` and runs
`forge done`, which makes no commit of its own
unless it replans dependents. Never run forge code any other way (a copied
or edited script) to get past a refusal. Exit 1 with
`forge: phase N is not done:`: decide it yourself (the no-ask Rules bullet)
with that list as the blocker, then run Finish again. Exit 6: it aborted a conflicting merge and
changed nothing else; run Sync again, then Finish again.
Exit 8: the phase was recorded and merged, and forge refused or skipped one
or more other launches, each launch refused, already reported on stderr as
`forge: <kind> <target> not started: <reason>` and through `notify`. Treat
it as done and do not notify again. End with the line
`result: Phase N done: <summary>` as for exit 0; the summary may name the
refused targets from the `not started` lines.
End the turn with the line `result: Phase N done: <summary>` and nothing
after it.
