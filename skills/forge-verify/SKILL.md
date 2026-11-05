---
name: forge-verify
description: Run a forge feature's verify session - smoke-test the merged feature branch, stand up its environment, run its manual test and decide each unmet requirement with the operator in one sheet.
argument-hint: '<root> <track>/<feature>'
disable-model-invocation: true
---

# forge-verify

You verify a forge feature whose phases are all done and merged into
`forge/<track>-<feature>`. The session starts in the feature worktree of the first
phase's repo.

Arguments: `$ARGUMENTS` — the project root `R`, then `<track>/<feature>`.

## Rules
- Every question to the operator goes through `AskUserQuestion`, never
  plain text. Before it, when `PushNotification` is not loaded load it with
  `ToolSearch` `select:PushNotification`, run
  `forge notify "<session title>" "<headers>"`, send `PushNotification`
  `<title>: <headers>` under 200 characters, then call `AskUserQuestion`
  with no tool call between; a failed notify or push is ignored, never
  retried. The session title is `<project> verify <track>/<feature>`
  (`<project>`: basename of R) and `<headers>` each question's `header`
  joined by `, `. A procedure of more than 3 steps is printed first as
  numbered session text, and the question stays one line.
- Spawn `forge-fixer` with the Agent tool's `run_in_background: false`
  on every call: the report is the tool result in the same turn, and a Bash
  command such an agent starts stops when its run ends. Put the independent
  spawns of one step in one message, each with `run_in_background: false`;
  the turn goes on once all have returned. If such a call returns an
  async-launch result instead of the report, end the turn with no result
  line and treat it as a background agent.
- Spawn `forge-implementer` with `run_in_background: true`, then end the
  turn with no result line; each completion notification resumes you.
  Wait for background commands the same way. Make no foreground spawn
  while such a wake-up is pending in the same step. Never
  `ScheduleWakeup`, `CronCreate`, a `sleep` poll, `ReadNotifications` or a
  `pgrep`/`ps` loop.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`. Follow the reason; never work around it
  (`bash -c`, variables, scripts); ask the operator instead. It denies
  `git switch`, `checkout <x>`, `stash`, `reset`, `restore`, `clean`, `rebase`, `cherry-pick`,
  `merge` (all but `--abort` and `--quit`), `pull` and `commit --amend` in
  R's main checkout, and `branch -f|-m|-D main` or `update-ref
  refs/heads/main|HEAD|--stdin` or a `symbolic-ref` write of HEAD or main
  anywhere in the project: other-branch work goes in a worktree under
  `<repo>/.claude/worktrees/` or the job tmp dir, and `main` moves only
  through `forge land`/`forge golive`.
- Run `forge` as `FORGE_ROOT=R forge <command>`. Edit planning JSON.
  Schemas: `~/.claude/forge/schemas/`.
- Run `FORGE_ROOT=R forge paths <track>/<feature>` first and use its `R`,
  `F` and `G` verbatim; every agent spawn gets those lines. `F` is in
  forge's state dir S, so `F/verify.json` lives in S, never a worktree's
  `.forge/`. Phases are the numbered entries of `F/split.json`; phase
  `N`'s directory is `<P>`, the `P` line of `FORGE_ROOT=R forge paths <N>`.
- Run only the feature's changed tests, `forge test --changed --base M W`
  (the feature diff against `M`, the base step 2 merged), and step 3's
  stack tests, with `run_in_background: true`; never the full suite, which
  ship runs once. The one exception is step 6's background `forge review
  <track>/<feature> --base M`. The phases ran only their tasks' own tests
  and fixers' `--one` runs, so step 3's `forge test --changed --base M W`
  is the feature's first changed-tests run over its code, and its failures
  go through Inline fixes. After a fixer commit, rerun only the failing
  test ids with `forge test --one <id>`.
- Test logs: on failure read `forge-test.log` in `W`'s git dir. It can be
  the runner's summary, one `ok <suite> (<s>s)` or
  `FAIL <suite> (exit <s>, <s>s, log <path>)` line per suite: read the
  per-suite log each `FAIL` line names, under `<git dir>/forge-test.d/`
  (the suite's path relative to `tests/`, extension `.log`), and name it in
  the gap.
- Pre-existing failures: `forge test --changed --base M W` exiting 0 and
  printing `forge: tests passed (<short>), pre-existing failures on <base
  short>: <id> <id>...` is a pass like any changed pass: record no gap and
  spawn no fixer for those ids. On a failure whose stderr holds
  `forge: pre-existing failures on <base short>: <id> <id>...` right before
  `forge: tests failed, log <log>`, those ids already fail on `M`: leave
  them out of the gap and out of every fixer's work, so the gap and each
  fixer name only the other failing tests. forge itself reruns failing ids
  on `M`, opens their concerns and logs the `base-fails` event; never do
  any of that yourself. Pre-existing ids are only those the step 3
  `--base M` run named.
- Proof loop: `forge test --repeat N --one <id>` is the proof loop that
  shows a fix or a flaky case holds. It takes one machine-wide test run
  slot and runs the test up to N times, stopping at the first failing run
  with `forge: repeat failed on iteration <i>/<N>`; all passing prints
  `forge: repeat passed <N>/<N>`. Name it in a flaky test's gap.
- Never run `./port --apply` from a worktree; it refuses off `main`, and
  `forge golive` deploys at ship.
- A UI feature is one for which `FORGE_ROOT=R forge ui <track>/<feature>`
  exits 0. `E` is `G/forge-verify`.
- Drive the browser only with `mcp__jbc__*` tools. `mcp__playwright__*`
  only observes (console, network, screenshots to file, evaluate, dialogs)
  and is never called in the same message as a `jev_task`.
- The forge-jbc Chrome that `forge-browser start --headed` starts is the
  only visible browser a verify session opens. A project's own browser
  test suite (Playwright, Cypress or similar) run from a shell step always
  runs headless, never with `--headed`, `--ui`, `--debug` or `PWDEBUG`,
  even when the operator asks to watch it; to show the operator a flow,
  drive it in the forge-jbc Chrome with `mcp__jbc__*`.

## Steps
1. Repos. Run `FORGE_ROOT=R forge repos <track>/<feature>`. Each line is
   `<name> <path>`: that repo's `W` is
   `<path>/.claude/worktrees/<track>-<feature>`,
   its TESTING `W/.forge/TESTING.md` and its STACK `W/.forge/STACK.md`.
2. Sync. For each `W` in `forge repos` order: when
   `git -C W remote get-url origin` succeeds, run
   `git -C W fetch origin main` and then the Resolver loop with
   `origin/main` and step `sync`; with no `origin` remote, run the Resolver
   loop with `main` and step `sync`. A failed fetch is printed and the repo
   merges its last fetched `origin/main`. That repo's merged ref,
   `origin/main` or `main`, is its base `M` for every feature diff that
   follows.
3. Smoke test. Run every repo's tests as one stage. In one message, start,
   each with the Bash tool's `run_in_background: true`,
   `forge test --changed --base M W` in every repo's `W` and
   `forge test --stack W` in every repo whose TESTING has both a
   `- Local stack:` and a `- Stack tests:` line. While that batch runs, run
   as smoke checks each repo's STACK build or start command when it has
   one, checking it comes up without errors. Then end the turn
   to wait for every background run. No repo waits on another repo's run,
   and the skill adds no limit or order of its own: forge test's
   machine-wide run semaphore and each `W`'s `forge-test.lock` decide
   when each run starts, so a changed and a stack run in one `W` queue on
   that lock. On a changed run's failure read its logs as Test logs in
   Rules says, and read its pass line and pre-existing ids as Pre-existing
   failures in Rules says. Each stack run adds `{"repo": "<name>",
   "command": "<its Stack tests command>", "passed": <true or false>}` to
   `stack_tests`; exit 5 (a line missing) adds no entry, and
   `forge test --stack` stops its own unit even on failure, so step 8 has
   nothing more to stop for it. A failure is a gap tagged with the phase in
   the repo where it ran whose plan names the failing files, else as step 7
   tags an unclear gap; a stack failure's text names
   `<git dir>/forge-stack.log`. Finish every run of the stage before
   recording. On any failure run Inline fixes at once through step 4's
   rounds, before step 5's environment, which needs a tree that builds.
4. Stage fixes. For round r = 1, 2, note each `W`'s pre-fix commit
   P = `git -C W rev-parse HEAD`, then take every open smoke, changed and
   stack failure of step 3's stage across all the `W`s together and
   spawn in one message, each with `run_in_background: false`, one
   `forge-fixer` per failing file per `W` across every `W`, the failures of
   one file in one `W` going to one fixer, never two fixers on one file;
   files of different repos never collide. After those end, spawn one at a
   time, with `run_in_background: false`, one `forge-fixer` per failure
   naming no file, as its fixer finds the file at fault itself. Each fixer
   is given the failed command, its log (`<git dir>/forge-stack.log` for a
   stack run, the per-suite logs as Rules' Test logs says), `F/spec.json`,
   `W/.forge/TESTING.md` and its own `F/fixes/<repo>-V<k>.json`; a changed run's
   pre-existing ids get no fixer, and fixer results decide each gap as
   Inline fixes says. Commit the fixes in each `W` as Inline fixes step c
   does, then rerun every failed command together in the background, each
   in the `W` it ran in, a failed changed run as Inline fixes step e reruns
   it (each failing id with `forge test --one <id>`), ending the turn to
   wait for all; the rerun decides.
   A failure still open after round 2 is a gap tagged as step 3 says and
   skips to step 7 with `"result": "gaps"`; list the failed commands as the
   manual test. Step 6's final review covers these commits. Step 5's
   Environment starts only once every run of the stage has passed or been
   fixed.
5. Environment. For each repo whose STACK names a command that serves it,
   run `systemd-run --user --collect --unit forge-<feature>-<name>
   --working-directory <W> <command>`, with every character of `<name>`
   outside `[A-Za-z0-9:_.-]` replaced by `_`, and confirm it answers.
   Commands started from Bash any other way are reaped.
   Then, before the sheet, check each repo's build: read
   the running build's commit by running the backticked command of its
   STACK's `- Build commit:` line, which prints the commit the running
   build was built from, when present, else from the commit
   the served asset or page exposes, and compare it with
   `git -C <repo path> rev-parse forge/<track>-<feature>`. On a mismatch
   rebuild and restart that repo's environment from `W` and check again;
   a second mismatch is a gap naming both commits, tagged as step 7 does.
   A repo with neither source gets a note that its build commit could not
   be checked, printed in step 6 above the steps and the sheet, never a
   manual-test step; step 7 records it in `manual_test` as
   `[note] <repo>: <note>`.
6. Manual test. First start the final review: start one background Bash
   command per `W`, each with `run_in_background: true`, all in one
   message. The command of each `W`, `<repo>` being the basename of `W`'s
   repo and `<git dir>` being `$(git -C W rev-parse --absolute-git-dir)`:
   writes `git diff M...forge/<track>-<feature>` to
   `<git dir>/forge-<feature>.diff`; when
   `<git dir>/forge-<feature>-review.json` exists from an earlier verify
   round, moves it to `<git dir>/forge-<feature>-review.prev.json`; prints
   `<repo>: tree ` followed by `git -C W rev-parse HEAD^{tree}`, the
   reviewed tree; runs
   `FORGE_ROOT=R forge review <track>/<feature> --base M --out <git dir>/forge-<feature>-review.json`
   with `W` as the current directory, adding
   `--prior <git dir>/forge-<feature>-review.prev.json` when that file was
   moved there this round (with none, no `--prior`), its exit ignored and
   every output line prefixed `<repo>: `. A repo's review finished when its
   command ends, and its Inline fixes rounds start then, while other repos'
   reviews still run. Commit nothing in a `W` while its own review runs;
   other `W`s' fixers may commit meanwhile. Then write one set of numbered steps the operator follows to see
   each requirement in `F/requirements.json` working across all the repos,
   with what they should see, writing each step's requirement ID(s) into
   the step as you write it. Write no step checking a surface against
   `mockups/<surface>.html`: a visual problem shows in the requirement's
   user-flow step. Then read `deferred[]` from
   `<P>/result.json` of every numbered phase in
   `F/split.json` (a missing file or field adds none), drop each
   mockup-match entry of it and collect the deferred checks: identical
   checks from several phases become one step naming every phase that
   deferred them; a deferred check that serves a requirement folds into
   that requirement's step, its expected result joining what the operator
   should see there and its `(deferred by phase N: <reason>)` text kept in
   the step, and when you cannot run it, as the ownership rule below says,
   that step becomes operator-owned; only a deferred check that covers no
   requirement gets
   its own step after the normal steps: `<check> (deferred by phase N:
   <reason>)`, with what the operator should see.
   Read ~/.claude/skills/forge-verify/owed-checks.md and follow it.
   Write every build and
   start command in the steps as
   `cd <absolute W> && <command>`, with no relative path, so the operator
   can paste it from any directory. Each step is agent-owned or
   operator-owned. A step is agent-owned when its pass is decided by an
   exit code, test result, log line, API response, database row or file
   content (a CLI command, a test suite, a log, an API call, a headless
   check, a deferred check). It is operator-owned when its pass depends on
   judging what a user sees through the shipped surface (an end-to-end user
   flow, a visual check), and always when it is a physical, device or
   account step: an on-device step, a login, an external console or sudo. A deferred
   check stays operator-owned only when you cannot run it: its command
   matches a `Bash(...)` deny pattern of `~/.claude/settings.json` (the
   planner's reason for deferring it, such as `gcloud billing`), or it
   needs a sudo password, a secret you cannot read, an external console or
   account login, or a physical or device action. Before asking anything,
   run every agent-owned step, deferred checks included: each shell step by
   running its command in `W` (a browser test suite headless, per Rules)
   and saving its output under `E/s<k>/`, a headless or browser-driven
   check through Browser pass. For a UI feature with the environment up,
   also pre-run its user-flow and visual steps headless through Browser
   pass to catch their gaps before the operator's time; they still go to
   the sheet as `operator` lines. A failed agent-run step or deferred check goes to
   Inline fixes below, one fixer per failing step, with `run_in_background: false`,
   given the step, its
   command and its `E/s<k>/` evidence; after the fix is committed, the
   failed step reruns as Inline fixes step e says, replacing its `E/s<k>/`
   output. One still failing after round 2 is a gap with its
   evidence paths, and a failed deferred check is tagged as step 7 tags a
   failed deferred step. Agent-owned steps never become `operator` lines.
   The run's gaps join the round's in step 7.
   Then run
   `FORGE_ROOT=R forge clean --sessions <track>/<feature>`, so only this
   Verify session stays in the agents view: by then the last phase session
   has ended. A nonzero exit is reported and the step goes on.
   Then run Inline fixes: each `W`'s rounds wait for its own review and
   finish before the sheet below, so no fix waits on the operator's answer.
   The sheet. Print step 5's build-commit notes, then only the
   operator-owned steps once as numbered text, each with its requirement
   ID, what the operator does (commands written as
   `cd <absolute W> && <command>`), what they should see, and only the
   actions you cannot do yourself (a physical action, a sudo password, a
   secret you cannot read, an external console), each with why, after
   first doing every setup action you can for them (start or restart
   services under `systemd-run --user` as step 5 does, build and install,
   mint pairing codes or tokens, send test pushes, and undo the state a
   pre-run left, such as a record it created, or name that state in what
   the operator should see). Then print one sheet with one line per
   requirement of `F/requirements.json` in file order:
   `met <ID>: <evidence path>` for an `agent` requirement (`owner` absent
   or `agent`) whose every step passed in the agent run, the path its
   steps' `E/s<k>/`; `unmet <ID> (phase <N>): <reason>` for an `agent`
   requirement a step of which still fails after Inline fixes, `<N>` the
   phase of `F/split.json` whose `requirements` hold the ID (several or
   none: the phase step 7 tags an unclear gap with) and `<reason>` the
   failure with its evidence paths; `operator <ID>: <the step text>` for an
   `operator` requirement, and for an `agent` requirement with an
   operator-owned step (an on-device step, a user-flow or visual step, a
   deferred check you cannot run) or a step you could not run (a
   `needs_confirmation` stop, or a headless or browser-driven check when
   Browser pass was skipped because `forge-browser start` failed);
   `post-ship <ID>: owed` for a `post-ship` requirement. Then read
   `unmet[]` from `<P>/result.json` of every
   numbered phase in `F/split.json` (a missing file or field adds none)
   and add one `unmet` line per entry,
   `unmet <ID> (phase <N>): unmet <task>: <reason>`, `<ID>` the phase's
   `requirements` of `F/split.json` joined by `, ` (its `<N>-<slug>` when
   it holds none); an entry whose `task` is `sync` means that phase's
   branch is not merged into the feature branch, so its work is absent
   from the review diff and the changed tests, and its one line names the
   conflicted paths its reason holds. A step covering no requirement (a
   deferred check) gets a line too, `step <k>` in
   place of the ID: `unmet` when it failed, `operator` when you could not
   run it. A failed step's gap enters `gaps` only through its line's
   answer. An `unmet` line goes to no fixer: the operator decides it in
   the round below, and `result` is never `pass` while one stands without
   `Accept`. Its retry clears it: `forge next` removes the phase's unmet
   task records, so the retried phase runs those tasks again and its new
   result lists only what is still unmet.
   - When every line is `met` or `post-ship`, ask nothing: `result` is
     `pass` from your run, `pass` only with no gap, and `operator_ran` is
     false.
   - Otherwise ask one round over the `unmet` and `operator` lines.
     Read ~/.claude/skills/forge-verify/walkthrough.md and follow it.
7. Record. When step 6 started the review, Inline fixes waited for it
   before this step.
   Read ~/.claude/skills/forge-verify/reviewer-fallback.md and follow it.
   Then for each `W` set `review_trees[<repo>]` to the repo record's
   `tree` when that repo either printed `<repo>: findings: ...` (a clean
   repo prints `<repo>: findings: 0 open ...`) or had the `forge-reviewer` fallback run
   and append its findings; the final review counts as run for a repo only
   on those two paths, and with no such repo leave `review_trees` out.
   Ship copies the record as it stands. Print the sheet again, each line
   with its answer. Write `F/verify.json`: `manual_test` still records
   every step with its tag: the sheet's lines, each led by a tag of who
   decided it, `[agent]` for a `met` line followed by its `E/s<k>/`
   evidence paths, `[agent][carried]` followed by the kept `E/s<k>/` paths
   of a step Inline fixes did not rerun, `[operator]` for an `unmet` or
   `operator` line the operator answered (an accepted `unmet` line ending
   ` — accepted: <operator's words>`), `[skipped]` for one answered skip,
   or `[owed]` for a `post-ship` line or an owed check no one ran, then
   the deferred steps covering no requirement with the same tags, then
   step 5's build-commit notes as
   `[note] <repo>: <note>`,
   `result` is `pass` only when no step, agent-run or answered, left a gap
   (`result` ignores `[owed]` steps, so they never block `pass`),
   every repo of `forge repos <track>/<feature>` has a `review_trees` entry
   (a repo with none is a gap naming its missing final review),
   no answer or reply meant `Spec is wrong` and the round, when one was
   asked, ended as its last bullet says, else `gaps`,
   `operator_ran` is set by step 6, true when an `operator` line was asked
   and false otherwise (left
   out when step 4 skipped here), `stack_tests` holds step 3's entries
   (left out when it added none), `fixed` holds each gap Inline fixes
   closed, as that section writes it (left out when none), and `gaps`
   keeps only open gaps, those the round's answers recorded joining the
   rest: of the gaps Inline fixes takes, only one still open after 2
   inline rounds, one whose fixer reported `failed` with a summary
   starting none of `not a defect: `, `out of scope: ` and
   `spec requires: `, or a `needs plan: ` result is recorded, besides any
   gap Inline fixes does not take and a reply meaning `Spec is wrong`,
   and a step's gap only when its `unmet` line took `Restart phase <N>`.
   Read ~/.claude/skills/forge-verify/gap-rules.md and follow it.
   Run
   `FORGE_ROOT=R forge commit <track>/<feature> verify`, which records
   `F/verify.json` in S and prints
   `forge: recorded <track>/<feature> verify`. Every todo line
   verify writes to `R/.forge/todo.md` starts `- <today YYYY-MM-DD> `,
   today being the local date `date +%F` prints. For each `[owed]` step
   covering no requirement, append one line
   `- <today> <check> (owed after ship, <feature> verify, deferred by phase N)`
   to `R/.forge/todo.md`; an owed check folded into a requirement step adds
   no todo line. When verify wrote any todo line to `R/.forge/todo.md`,
   Browser pass findings, step c deferrals or owed checks, commit all of them once:
   `flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): defer <track>/<feature> verify findings" -- .forge/todo.md`;
   a `<repo>` child is its own repo, so commit step c's lines in
   `R/<repo>/.forge/todo.md` there the same way right after.
8. Stop the environment: `systemctl --user stop` each unit step 5
   started and, when this session's last `forge-browser start` succeeded,
   `forge-browser stop`, so no browser process outlives the env. Run it
   then even after a skipped or failed pass, so the next session waiting on
   the browser gets it. After a failed start, never run it: the browser is
   then another session's or already stopped, and `stop` would stop it
   under that session.
9. Next. This session runs `forge next` once, so it starts at most one
   retry wave; it never re-verifies or runs `forge next` again after that.
   - `Spec is wrong`: end the turn with the line `needs input: run
     /forge-discuss <track>/<feature> to reopen the spec` and nothing after it.
   - Otherwise run `FORGE_ROOT=R forge next <track>/<feature>` and end the
     turn with the line `result: Verify <result>, <the session it started>`
     and nothing after it. Exit 8 is not a failure: forge already reported
     and notified each refused launch as
     `forge: <kind> <target> not started: <reason>` and logged each not held
     as a `refused` event in the feature's events.jsonl, which the watchdog
     re-alerts after 30 min; its `result:` line names the targets not started.

## Resolver loop
Read ~/.claude/skills/forge-verify/resolver-loop.md and follow it.

## Inline fixes
Inline fixes closes every fixer-sized gap before step 7 records it, in one
round loop. Its gap sources are: open high
review-only findings of step 6's final review; the failing runs of step
3's stage, smoke commands (`forge test --changed --base M W` and the STACK
build or start command) and stack tests (`forge test --stack W`); and failed agent-run manual-test steps and deferred checks
of step 6. Fix records are numbered per repo as `F/fixes/<repo>-V<k>.json`,
`<repo>` being the basename of `W`'s repo, `k` counting from 1 within a repo
across rounds and sources, as `F/merge/<repo>-V<k>.json` is, and one
`forge-fixer` holds each file, never two for one file.
Step 4 runs it on the stage's failures before step 5, across every `W`
at once in its own rounds; step 6 runs it on the review-only findings and
the agent run's failures before the sheet, these sources running in the
per-`W` rounds below.

From step 6, a `W`'s rounds wait for its own background review command
only. While it still runs, end the turn with no result line; its
completion resumes you. A command that ended with no
`<repo>: findings: ...` line counts as `codex: <exit or error>`, as in
ship.

A finding is review-only when it names no unmet spec criterion of the
feature and no failing test. A finding names an unmet criterion when its
summary starts `[<focus> <ID>]` or contains a requirement ID of
`F/requirements.json`. Failed tests, steps and criteria are never
review-only findings; they are fixed here as test or step gaps. Only open
high findings, neither `fixed`, `dismissed` nor validly `deferred`, are
fixed here, the ones that become P1 gaps; medium and low stay deferred
todos. A Codex-only medium (source `codex`, severity `medium`) is advisory:
`forge fixes` does not list it, so it gets no fixer, and it is never
chased; summaries still show it.

Fixer results decide a gap as follows. A fixer result `failed` whose
summary starts `needs plan: ` (it cannot close the gap without a new task,
a file outside the failing test's or step's scope, or a plan change) is
recorded as a gap at once, with no second round for it. `dismissed` is
set only for a review finding whose fixer reports `failed` with a summary
starting `not a defect: `, as step c records it. For a smoke, test, stack or agent-run
step failure a `not a defect: ` result never closes the gap: the rerun
decides, and a still-failing rerun is an open gap for the next round.

Rounds r = 1, 2 run per `W`, each `W` independently of the others, for
each `W` that still has an open gap: an open review-only high finding
(its review printed `<repo>: findings: ...` and
`<git dir>/forge-<feature>-review.json` exists), a failing smoke, test or
stack command run in it, or a failed agent-run step or
deferred check run in it:
a. Note the pre-fix commit P = `git -C W rev-parse HEAD`.
b. For review findings, run
   `FORGE_ROOT=R forge fixes <track>/<feature> --record <git dir>/forge-<feature>-review.json`
   and spawn in one message,
   each with `run_in_background: false`, one `forge-fixer` per printed line
   holding an open review-only high
   finding, with no model or effort override. Each prompt gives that
   file's findings with their `review` path and `index`, findings being
   recorded at `index` of the printed `review` path, the repo record
   itself, and its own output
   `F/fixes/<repo>-V<k>.json`, says the file is relative to `W`, gives its
   absolute path and passes `F/split.json` to name an owner phase and
   `W/.forge/TESTING.md`. After those end, spawn in one message, each with `run_in_background: false`, one `forge-fixer`
   per other open gap of `W` that names a
   file, the gaps whose failing tests, step or check point to one file
   going to one fixer, so no two fixers edit one file; after those end,
   spawn one at a time, with `run_in_background: false`, one
   `forge-fixer` per open gap whose failure names
   no file, as its fixer finds the file at fault itself; each given
   `F/spec.json`, `W/.forge/TESTING.md` and its own `F/fixes/<repo>-V<k>.json`,
   and: for a
   failing smoke, test or stack command, the failed command and
   the log it failed with (`<git dir>/forge-stack.log` for a stack test,
   the per-suite logs as Rules' Test logs says); for a failed agent-run
   step or deferred check, the step, its command and its `E/s<k>/`
   evidence paths.
c. Commit the fixes in `W`.
   Read ~/.claude/skills/forge-verify/fix-recording.md and follow it.
e. Rerun only the failing tests, in the background, never the whole
   feature's changed tier: rerun each test id still failing in `W`, of
   step 3's changed run or of the last round's reruns, with
   `forge test --one <id>` when `W/.forge/TESTING.md` has a `- Test:` line
   with `{test}` that accepts the id; without one that id stays open.
   `W`'s worktree lock serializes these runs within one `W`, so they
   overlap only across `W`s. On failure read the failing tests from the
   logs as Test logs in Rules says. Pre-existing ids are not failing tests
   for these rounds: they get no rerun and no fixer and become no gap, as
   Pre-existing failures in Rules says. After
   the fixes are committed, also rerun in the background step 3's stack
   tests, as step 3 runs them:
   `forge test --stack W` when `W`'s TESTING has both a `- Local stack:`
   and a `- Stack tests:` line (exit 5 adds nothing). A failing stack
   run's log is `<git dir>/forge-stack.log`. Rerun each failed smoke
   command, agent-run step and deferred check of `W` too, replacing a
   step's `E/s<k>/` output with the rerun's.

Read ~/.claude/skills/forge-verify/fix-reruns.md and follow it.

## Browser pass
Read ~/.claude/skills/forge-verify/browser-pass.md and follow it.
