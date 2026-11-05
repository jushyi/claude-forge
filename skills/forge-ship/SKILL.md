---
name: forge-ship
description: Ship a verified forge feature - final review, doc updates, PRs or a forge golive, then cleanup and archive once landed.
argument-hint: '<root> <track>/<feature>'
disable-model-invocation: true
---

# forge-ship

You ship a forge feature the operator verified. The current directory is
the project root `R`, on main.

Arguments: `$ARGUMENTS` — the project root `R`, then `<track>/<feature>`.

## Rules
- Every question to the operator goes through `AskUserQuestion`, never
  plain text. Before it, when `PushNotification` is not loaded load it with
  `ToolSearch` `select:PushNotification`, run
  `forge notify "<session title>" "<headers>"`, send `PushNotification`
  `<title>: <headers>` under 200 characters, then call `AskUserQuestion`
  with no tool call between; a failed notify or push is ignored, never
  retried. The session title is `<project> ship <track>/<feature>`
  (`<project>`: basename of R) and `<headers>` each question's `header`
  separated by `, `. A procedure of more than 3 steps is printed first as
  numbered session text, and the question stays one line.
- Spawn `forge-fixer` with the Agent tool's `run_in_background: false`
  on every call; the report is the tool result in the same turn. Put the
  independent spawns of one step in one message, each with
  `run_in_background: false`; they run concurrently and the turn goes on
  when all have returned. When an Agent call that passed
  `run_in_background: false` returns an async-launch result in place of
  the report, end the turn and treat that agent as a background agent.
- Spawn `forge-implementer` with `run_in_background: true`, then end the
  turn; each completion notification resumes you. Spawn
  `forge-doc-updater` at step 4 with `run_in_background: true` too and
  wait for it by ending the turn after step 6; its completion notification
  resumes you. Never make a foreground spawn while an implementer or
  doc-updater wake-up is pending in the same step: queued notifications
  wait until the turn ends. Wait for any other agent spawn that returns an
  async-launch result the same way, by ending the turn.
- Start background commands (`forge test`, `forge pr checks`,
  `forge pr push`) with the Bash tool's
  `run_in_background: true` and wait for them by ending the turn; each
  completion resumes you. A Bash command a foreground subagent starts
  stops when that subagent's run ends.
- Never `ScheduleWakeup`, `CronCreate`, a `sleep` poll, `ReadNotifications`
  or a `pgrep`/`ps` loop.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`. Follow the reason; never work around it
  (`bash -c`, variables, scripts); ask the operator instead. It denies
  `git switch`, `checkout <x>`, `stash`, `reset`, `restore`, `clean`, `rebase`, `cherry-pick`,
  `merge` (all but `--abort` and `--quit`), `pull` and `commit --amend` in
  R's main checkout, and `branch -f|-m|-D main` or `update-ref
  refs/heads/main|HEAD|--stdin` or a `symbolic-ref` write of HEAD or main
  anywhere in the project: do that work in `W` (or a worktree under
  `<repo>/.claude/worktrees/` or the job tmp dir), and `main` moves only
  through `forge commit` and `forge golive`. `F/docs-<repo>/docs.json`,
  `F/fixes/` and `F/merge/` are agent records you never edit;
  `F/review-<repo>.json`, `F/review/<repo>.json` and `F/ship.json` are yours.
- Run `forge` in `R`. Edit planning JSON. Schemas:
  `~/.claude/forge/schemas/`.
- Run `forge paths <track>/<feature>` first and paste its lines into every
  agent spawn. `F` is its `F`, under the state dir S outside every repo,
  so one absolute path reaches it from any worktree, a `W` in a linked repo
  outside `R` included: give every `F` path absolute. Code changes are committed in `W`,
  Conventional Commits.
- Run tests with the Bash tool's `run_in_background: true`. The full
  suite runs as `forge test W`: for a repo with a remote in step 7 before
  the PR push, for a repo without one in step 7 after the last fix,
  concerns and docs commit, and again in PR merge's retry, which reruns
  the full suite on the merged tree. Ship runs `forge test --changed` only
  after fixing a failed PR check or a failed Pre-push, on top of the
  full-passed commit last noted. Flake rerun adds its `forge test --one`
  runs and one `forge test --force W` rerun after a full-suite test
  failure. A
  `forge: tests passed (...), cached from ... (docs-only change)` line is
  a pass, and a `forge: tests passed (...), cached` line from the full
  `forge test W` is a full-suite pass too. For a repo whose `W/.forge/TESTING.md` has a
  `- CI full suite:` line, step 7's full suite is
  `forge pr checks --full <url>` from `W` once the PR is open, and so is
  the run in PR merge's retry: its exit 0 is the full pass and its exit 6
  falls back to `forge test W`. A plain `forge pr checks` exit 0 is never
  the full pass. `forge golive`'s land reuses that full pass, a `--full`
  exit 0 included since it writes the same host stamp a full local pass
  writes, while `main` has moved only in `.forge/`.
- Ship ships this feature only. When it needs work outside the feature's
  spec (migrating another workspace, changing a repo the split does not
  name), do not do it: append it as a line `- <today YYYY-MM-DD> <text>`
  to `R/.forge/todo.md`, today being the local date `date +%F` prints,
  commit that with
  `flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): <summary>" -- .forge/todo.md`,
  and end the turn with `failed: Ship <track>/<feature> stopped: <work>
  recorded in .forge/todo.md`.
- Every step that works per repo takes the repos in `forge repos` order,
  producer first.
- Ship waits on no queue and holds no merge lock of its own; lands of one
  repo serialize only on `forge-land.lock`, which `forge land` and
  `forge golive` take.
- To end blocked with a cause, set `pr` in `F/ship.json` to every PR URL
  opened so far, in producer order, separated by spaces (null when none),
  run `forge commit <track>/<feature> ship`, skip Clean and Archive, then
  end the turn with `result: Blocked <track>/<feature>: <cause>` and
  nothing after it. Leaving a PR open, or a branch unmerged in a repo
  without a remote, ends blocked this way.
- Push a PR branch only with `forge pr push` from `W`, which runs the
  repo's `- Pre-push:` command before it pushes and pushes nothing when
  that fails. Run every `forge pr push` with the Bash tool's
  `run_in_background: true` and wait for it by ending the turn: a
  Pre-push can outlast the Bash tool's time limit, and a timeout is no
  exit 3. When `forge pr push` exits 3 (Pre-push failed, nothing pushed),
  send its output to one `forge-fixer`, with `run_in_background: false`,
  as a failing test in step 3, commit the fixes in `W`, then run
  `forge test --changed --base <full-passed commit> W` in the background
  once a full pass is noted, else `forge test --changed W`, a failure
  going to `forge-fixer`s as in step 3 until it passes, and run
  `forge pr push` from `W` again, pushing nothing until it exits 0, so no
  pushed tip, and no full-passed commit, holds an untested Pre-push fix;
  on any other nonzero exit ask the operator, giving its stderr.
- Spawn agents by type, description `ship <feature> <step> <agent>`.

## Resolver loop
Given a `W`, `<branch>` and the calling `<step>`: run `(cd W && forge merge <branch>)`. Exit 0:
continue. Exit 1: ask the operator with its message. Exit 4: for attempt k = 1, 2,
spawn `forge-merger`, description `ship <feature> <step> forge-merger`, with `W`,
the paths `forge merge` printed, the merge base
(`git -C W merge-base HEAD MERGE_HEAD`), the output of
`git -C W log --oneline <base>..HEAD` and of
`git -C W log --oneline <base>..MERGE_HEAD`, `F/requirements.json`, the
record `F/merge/<repo>-M<k>.json`, `<repo>` being the basename of `W`'s
repo, and, on attempt 2, the last merge-check output. Then run
`(cd W && forge merge-check <record>)` and, when it exits 0, run
`(cd W && forge merge --continue <record>)` and continue (its exit 1 is a
failed attempt). The merged tree is tested by the run that follows:
step 7's full suite after step `sync`, PR merge's full suite rerun after
step `retry`, or golive's land after step `merge`; for a repo declaring
`- CI full suite:`, step 7's and PR merge's full suite is
`forge pr checks --full <url>`. After the second failed attempt run
`(cd W && forge merge --abort)` and ask the operator with one question
giving the conflicted paths and the last merge-check output, and follow the
answer; both branches stay as they were.

## Flake rerun
Given a `W`, its `<path>` from step 1's `forge repos` and the log of its
full suite `forge test W` that failed on a test failure, run this before
any `forge-fixer`. A run that ended on a timeout, a memory kill or exit 75
is no test failure and keeps its own handling with no Flake rerun;
`forge pr checks --full` CI failures and `forge test --changed` failures
never run it. First, before running anything else, since later `--one`
runs append to the same log, read the failing test ids from that log:
when `W/.forge/TESTING.md` has a `- Failed tests:` line, the ids its
command prints for that log, else the failing tests the log names, as a
fixer reads them. With 1 to 10 ids, run `forge test --one <id> W` once
per id, one after another, each with the Bash tool's
`run_in_background: true`, waiting for each; only exit 0 is a pass, and
any other exit, a test failure, 75, 124, 126 or 127 included, is not.
When any id did not pass alone, or the log names no id or more than 10,
hand the failure to the caller's fixers: one `forge-fixer` per failing
test its log names, each with `run_in_background: false`, as in step 3,
then the caller's full suite again. When every id passed alone, append
`- <today> flaky: <ids> failed in the full suite of <track>/<feature> and passed alone`
to `<path>/.forge/todo.md`, today being the local date `date +%F`
prints, run `git -C <path> add -- .forge/todo.md`, since the append may
have created it, then commit it with
`flock "$(git -C <path> rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C <path> commit -m "docs(todo): flaky tests in <track>/<feature>" -- .forge/todo.md`,
then run the full suite once more as `forge test --force W` in the
background, with no fixer before it, and wait for it; `--force` skips
the cache, so the rerun runs the suite again. Forge test reruns a
load-hit failure once by itself, so never ask for a test rerun. Its
pass, the docs-only carry-over line included, is the caller's full pass.
Its failure goes to the caller's fixers as above, never to a second Flake
rerun: Flake rerun runs at most once per caller in a ship, so a later
failure there goes straight to the fixers.

## PR merge
Given a `W` and its PR `<url>`: run
`forge pr merge <url>` from `W`. Exit 0: the PR merged. Exit 5 (origin's
`main` moved outside `.forge/` since the head, nothing merged), or exit 1
where a `forge pr state <url>` run then prints `DIRTY` (a conflict) or
`BEHIND` as its merge state, the second word: retry with no question. A
retry runs `git -C W fetch origin main`, the Resolver loop with
`origin/main` and step `retry`, then `forge pr push` from `W`, then the
same full-suite step as step 7: in one turn start the full suite
`forge test W` and `forge pr checks <url>` from `W` in the background and
wait for both, a full-suite test failure running Flake rerun first, any
other failure and a failure Flake rerun hands to fixers going to one
`forge-fixer` per failing test its log names, each with
`run_in_background: false`, as in step 3, its fixes committed in `W`,
then `forge pr push` from `W` and both runs again; the checks' exits are
handled as in step 7. After the full pass note `git -C W rev-parse HEAD`
as the full-passed commit, and once `forge pr checks <url>` passes run
`forge pr merge <url>` again, handled the same way, at most 3 retries.
For a repo whose `W/.forge/TESTING.md` has a `- CI full suite:` line, the
retry runs `forge pr checks --full <url>` from `W` in the background in
place of the full suite and the plain checks run, its exits 3, 4 and 1
handled as in step 7 and its exit 6 falling back to the full suite
`forge test W` beside `forge pr checks <url>` as above, whose test
failure runs Flake rerun first. `forge pr merge` retries transport
errors itself, so add no retry of your own. Exit 3, exit 4, any other
exit or merge state, a nonzero `forge pr state` exit or a failed third
retry ends blocked with its cause: the stderr line or the merge state.
Exit 1 with an `OPEN` state whose merge state is not `DIRTY` or `BEHIND`
ends blocked with that state line as the cause, never `result: Shipped`.

## Steps
1. Repos. Run `forge repos <track>/<feature>` in `R`. Each line is
   `<name> <path>`: that repo's `W` is
   `<path>/.claude/worktrees/<track>-<feature>` on `forge/<track>-<feature>`.
   When `F/ship.json` already has `pr` set, go to Merge's After a PR;
   when it exists without one, go to step 4.
2. Sync. For each `W`, run the Resolver loop with `main` and step `sync`,
   so the final review diff `main...forge/<track>-<feature>` shows only the
   feature. Never pull or merge in R; `forge golive` reconciles origin.
3. Final review. Review record. For each W: `<repo>` is the basename of W's
   repo and `<git dir>` is `$(git -C W rev-parse --absolute-git-dir)`. A
   present `F/review/<repo>.json` means that repo's review and fixes are
   done, also on resume. Otherwise copy
   `<git dir>/forge-<feature>-review.json` to `F/review-<repo>.json`.
   Never run `forge review` or spawn `forge-reviewer`. When the file is
   missing or has no `findings` array, end blocked with the cause
   `no verify review record for <repo>`.
   Run `forge fixes <track>/<feature> --record F/review-<repo>.json` and
   spawn in one message one `forge-fixer` per printed line holding an open
   high or medium finding from `F/review-<repo>.json`, never two for one
   file, each with
   `run_in_background: false` and no model or effort override. A Codex-only medium (source `codex`, severity `medium`) is
   advisory: `forge fixes` does not list it, so it gets no fixer, and it is
   never chased; step 5's summary still shows it. Each prompt gives that
   file's findings with their `review` path, `index` and own output
   `F/fixes/<repo>-F<k>.json`, `k` counting from 1 within the repo, says
   the file is relative to `W`, gives its
   absolute path and passes `F/split.json` to name an owner phase and the
   TESTING doc in `W`. Commit the fixes in `W`; the full suite tests them.
   Record each finding at `index` of `review` (`F/review-<repo>.json`) from
   its fix JSON only, never
   on your own judgment, and never delete a finding. A `fixed` fix sets
   `fixed` true. A `failed` fix with a summary starting `not a defect: `
   sets `dismissed` to that summary, except on a high finding whose
   `forge fixes` `security` is true. For `out of scope: todo: ` followed
   by `<reason>`, set `deferred` to `{"owner": "todo", "reason": "<reason>"}`, never
   `dismissed`, with no owner check, except that a high finding whose
   `forge fixes` `security` is true stays open on an out of scope reply.
   An `out of scope: phase <N>: ` reply leaves the finding open. A `spec requires: `
   outcome asks the operator with `AskUserQuestion` about the finding and
   the spec bullet or decision it names, never setting `dismissed` from
   the fix; when the operator's answer dismisses the finding, set its
   `dismissed` to `settled: <operator's words>` at once, else it stays
   open. A high finding whose `forge fixes` `security` is true and whose
   fix says `not a defect: ` asks the operator the same way, with the same
   `settled: <operator's words>` record, never `dismissed` from the fix.
   Everything else stays open. When `deferred`
   `owner` is `todo`, append
   `- <today> <file>:<line> <title> (deferred from phase <N>: <reason>)`,
   today from `date +%F` and `<N>` the phase of `F/split.json` whose goal
   the finding falls in, to the finding's repo `.forge/todo.md`,
   `<path>/.forge/todo.md` with `<path>` from `W`'s step 1 `forge repos`
   line. Then move `F/review-<repo>.json` to `F/review/<repo>.json`; until
   then that repo is not done, since `F/review-<repo>.json` lies outside
   `F/review/`. When
   `W` is `R`'s repo and its findings appended a todo line, commit the line
   in the same commit as the review record: run
   `git -C R add -- <record>`, then
   `flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): defer <track>/<feature> ship findings" -- .forge/todo.md <record>`,
   `<record>` being `F/review/<repo>.json` relative to `R`. Another repo
   is its own git repo, so commit its line there the same way, without the
   record, which step 5's commit takes.
4. Docs. Each `W` has its own docs manifest, `F/docs-<repo>/docs.json`,
   `<repo>` being the basename of `W`'s repo, so concurrent doc-updaters
   never overwrite each other's. For each `W` whose `F/docs-<repo>/docs.json`
   exists, skip its spawn and make its docs commit below. For each other
   `W`, write the diff, `git diff main...forge/<track>-<feature>` to
   `<git dir>/forge-<feature>.diff`, then spawn in one
   message one `forge-doc-updater` per such `W` with the Agent tool's
   `run_in_background: true`, each with the diff path, the repo's router
   `.claude/rules/forge.md` in `W`, `F/spec.json`, `F/requirements.json`, `F/split.json`
   and that `W`'s own `F/docs-<repo>/docs.json` as the output path,
   working in `W`.
   When `git -C W diff --name-only main...forge/<track>-<feature>` lists a
   UI file, a path ending in `.html`, `.htm`, `.css`, `.scss`, `.sass`,
   `.less`, `.jsx`, `.tsx`, `.vue`, `.svelte` or `.astro`, the prompt also
   gives the absolute paths of `W`'s root `PRODUCT.md` and `DESIGN.md`,
   whichever exist. Each prompt says never to edit `.forge/CONCERNS.md` or
   `.forge/concerns.json`, since `forge resolve` writes both while the
   doc-updater works. Do not wait for it: go straight on to step 5 (Record)
   and step 6 (Concerns) in the same turn. The docs commit, for each `W`,
   takes as `<paths>` every path that `W`'s own `F/docs-<repo>/docs.json`
   lists. Before it, run `forge validate <paths>` in `W` with only the
   linked-doc paths among `<paths>`, each `.forge/<doc>.md` with `<doc>`
   one of `PROJECT`, `RULES`, `REJECTED`, `ARCHITECTURE`, `STACK`,
   `CONVENTIONS`, `TESTING` or `INTEGRATIONS`, and skip the check when
   none is listed. When it prints doc-limit warning lines, each
   `forge: warning: <path>:<line>: <rule>`, respawn that `W`'s
   `forge-doc-updater` once with the same prompt plus those warning lines,
   saying to fix them and keep every earlier entry in
   `F/docs-<repo>/docs.json`, wait for it, then run `forge validate <paths>`
   again on the linked-doc paths its `F/docs-<repo>/docs.json` lists. Then
   trim each bullet a remaining `bullet over 300 characters` warning names
   yourself, shortening its text to at most 300 characters while keeping
   its meaning, and leave any remaining size and history-phrase warnings
   in place. Step 4 never ends Ship blocked on a doc-limit line. Then, for
   the `<paths>` `W`'s `F/docs-<repo>/docs.json` lists, when
   `git -C W status --porcelain -- <paths>` prints anything, run
   `git -C W commit -m "docs: update docs for <track>/<feature>" -- <paths>`,
   so it never sweeps another step's files.
5. Record. Skip this step when `F/ship.json` exists. Run
   `forge owed <track>/<feature>` in `R`; a non-zero exit ends
   Ship blocked with its stderr. It settles `done` and `owed` on each
   requirement in `F/requirements.json` from `F/verify.json`, appends one
   line per owed requirement to `R/.forge/todo.md` and prints one line per
   requirement. Keep each printed `<ID> owed <kind>: <check>` line and name
   it in the Ship result, before the `result:` line. Ship never sets `done`
   by hand. Write `F/ship.json`: `final_review` is an array with one line per finding
   in each `F/review/<repo>.json`
   (`<repo>/<file>:<line> <severity>: <summary>` then `, fixed`,
   `, dismissed: <reason>`, `, deferred: <owner>`, `, advisory` for an
   open Codex-only medium, or `, open`), or `No findings`; `pr` is null for
   now; `date` is today. Run `forge commit <track>/<feature> ship`; with
   `F` in S it prints `forge: recorded <track>/<feature> ship` and makes no
   commit. When
   `forge owed` changed or created `.forge/todo.md`, run
   `git -C R add -- .forge/todo.md`, then commit it with
   `flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C R commit -m "docs(todo): owed checks of <track>/<feature>" -- .forge/todo.md`.
6. Concerns. Always run this step, after step 5, since `forge resolve`
   reads the `done` flags `forge owed` sets. Run
   `forge resolve <track>/<feature> <name>=<W> ...` in `R`, one
   `<name>=<W>` per `forge repos` line. It edits each `W`'s
   `.forge/concerns.json` and `.forge/CONCERNS.md` only when needed. For
   each `W` where
   `git -C W status --porcelain -- .forge/concerns.json .forge/CONCERNS.md`
   prints anything, commit only those two files by path:
   `git -C W commit -m "docs(concerns): resolve <track>/<feature> concerns" -- .forge/concerns.json .forge/CONCERNS.md`.
   Make every commit yourself, one at a time, each naming its paths.
   When a doc-updater from step 4 is still running, end the turn; its
   completion notification resumes you. A doc-updater that fails or writes
   no `F/docs-<repo>/docs.json` for its `W` ends Ship blocked through the
   Rules' blocked ending, record in S and concerns already committed. Then make
   step 4's docs commit, which commits in each `W` only the paths that
   `W`'s own `F/docs-<repo>/docs.json` lists. Step 7 (Merge) starts only
   once every `W`'s `F/docs-<repo>/docs.json` exists and every doc change
   it lists is committed in that `W`,
   `git -C W status --porcelain -- <paths>` printing nothing for its
   listed paths.
7. Merge. First run `forge clean --sessions <track>/<feature>` in `R`, so
   only this Ship session stays in the agents view; a nonzero exit is
   reported and Merge goes on. Then run `forge fixes <track>/<feature>`. When it prints a high
   or medium finding, run one more round of step 3's fixers on them,
   recording each by step 3's rule, then run it again; a Codex-only medium
   is advisory, never listed and never chased. For each one still open,
   ask the operator with a question whether to dismiss it, setting
   `dismissed` to the operator's reason, or stop; on a high finding whose
   `forge fixes` `security` is true, set `dismissed` to
   `settled: <operator's words>` instead. On stop end the turn with
   `failed: Ship <track>/<feature> stopped: open review findings` and
   nothing after it. After any change rewrite `final_review` as in step 5
   and run `forge commit <track>/<feature> ship`. Never push, open a PR or
   golive while a high or medium finding is open. Then, for each repo,
   run the Resolver loop with `main` and step `sync` in `W`, so the tested
   tree holds `main`, then:
   - With a remote: when `grep -q '^- CI full suite:' W/.forge/TESTING.md`
     exits nonzero, run the full suite `forge test W` in the background and
     wait for it; the docs-only carry-over line and a Flake rerun
     `forge test --force W` pass are full passes. A full-suite test failure
     runs Flake rerun first. Any other full-suite failure, and a failure
     Flake rerun hands to fixers, goes to one `forge-fixer` per failing
     test its log names, each with `run_in_background: false`, as in
     step 3; commit the fixes in `W`, then run this full suite again.
     After the full pass note `git -C W rev-parse HEAD` as the full-passed
     commit. Then run `forge pr push -u origin forge/<track>-<feature>` from `W`, then
     write the body to
     `$(git -C W rev-parse --absolute-git-dir)/forge-<track>-<feature>-pr.md`
     and run `url=$(forge pr create forge/<track>-<feature> "<title>" <body file>)`
     from `W`, the URL from stdout only, never `2>&1`. The body holds the
     summary from `F/spec.json`, the requirements from
     `F/requirements.json` and the manual test from `F/verify.json`'s
     `manual_test`, `result` and `gaps`, plus one line
     `Merge after <producer PR URL>` for each producer repo this repo
     depends on that got a PR. Repo Y depends on repo X when a phase of Y in
     `F/split.json` depends on a phase of X, a phase's repo being its
     `repo`, else `R`'s basename. On a nonzero exit ask the operator,
     giving its stderr. Then run `forge pr checks <url>` from `W` with the
     Bash tool's `run_in_background: true` and wait for it.
     Each `forge pr checks` stdout line is
     `<state>\t<name>\t<link>`, `<state>` being `pass`, `fail` or
     `pending`.
     Exit 0: every check passed, or the repo reports none; run PR merge
     with `<url>` with no question, then `forge golive` as below, which
     fast-forwards local `main` to origin's `main` with no merge commit,
     tests it and ports; it needs `git config forge.pushMain true` in that
     repo, so ask the operator to set it when unset. Exit 3: send the failed checks to
     `forge-fixer`s as a failing test in step 3, one per `fail` line, each
     with `run_in_background: false`,
     giving the check's name and link (the fixer reads its log with
     `gh run view <run> --log-failed` when the link holds
     `/actions/runs/<run>`, else from the link itself). For a check whose fixer
     reports `failed`, ask the operator, giving its name, link and summary,
     whether to retry it or leave the PR open, ending blocked. Commit the fixes
     in `W`, run `forge test --changed --base <full-passed commit> W` once
     a full pass is noted, else `forge test --changed W`, and send a
     failure to `forge-fixer`s, each with `run_in_background: false`, as in
     step 3 until it passes, run `forge pr push` from `W`, then
     run `forge pr checks <url>` in the background again; repeat until
     another exit, never merging before exit 0. A pass of the `--base`
     run makes the pushed tip the new full-passed commit. Exit 4: ask
     the operator with one question, naming the pending checks from its `pending`
     lines or stderr, whether to wait again, running `forge pr checks <url>`
     again, or leave the PR open, ending blocked; never merge on exit 4. Exit 1: ask the
     operator with its stderr.
     When `grep -q '^- CI full suite:' W/.forge/TESTING.md` exits 0, run
     no full suite before the push: after `forge pr create`, run
     `forge pr checks --full <url>` from `W` with the Bash tool's
     `run_in_background: true` in place of the plain checks run and wait
     for it. Its exit 0 is the full pass, the checks having passed on the
     pushed tip: note `git -C W rev-parse HEAD` as the full-passed commit,
     then go on as on exit 0 above to PR merge with `<url>` with no
     question. Its exits 3, 4 and 1 are handled as above, with no full pass
     noted: on exit 3 the fixes are committed in `W`, then
     `forge test --changed W` runs, then `forge pr push` from `W`, then
     `forge pr checks --full <url>` again in place of the plain rerun, and
     on exit 4 waiting again runs `forge pr checks --full <url>` again. Its
     exit 6 falls back to `forge test W`: run the full suite as above, a
     full-suite test failure running Flake rerun first, noting the
     full-passed commit after its full pass, then `forge pr push` from `W`,
     then `forge pr checks <url>` from `W` in the background, handled as
     above.
     Never tell the operator to merge by hand, and never a raw pull.
   - Without one: run the full suite, `forge test W`, and wait for it; the
     docs-only carry-over line is a pass. A test failure runs Flake rerun
     first. Any other failure, and a failure Flake rerun hands to fixers,
     goes to one `forge-fixer` per failing test its log names, each with
     `run_in_background: false`, as in step 3, then this run again. Then
     run `forge golive <path> forge/<track>-<feature>`, `<path>` from
     `forge repos`.
   `forge golive` exit 0 prints the
   `landed`, `pushed`/`not pushed` and `ported`/`no port` lines. `forge: not pushed: nothing to push`, printed
   when origin already has `main`, is a success like `pushed`. In place of the `ported` line it may print
   `forge: port queued: <n> forge sessions working` or
   `forge: port queued: cannot list Claude sessions`, still exiting 0,
   after `forge: ported bin <sha>` when it installed the repo's `bin/`
   part at once, or after
   `forge: bin held: templates/ or schemas/ changed since the last full port`
   when it held that part; the forge watchdog ports the rest later, and a repo
   queued again keeps its first queue time. When that bin install fails
   golive still queues the port and exits 1 with
   `forge: ./port --apply --only bin failed in <top>; port queued`.
   Keep every line, `ported bin`, `bin held` and
   `port queued` included, for the result. Ship never runs a deploy. Exit 4 (conflict
   with `main`): run the Resolver loop with `main` and step `merge` in `W`,
   then golive again. Exit 5 (main kept moving) or 7 (tests failed in
   `_land`): land nothing more, ask the operator with one question giving the
   output, and follow the answer. Exit 6: ask the operator with one question
   naming the R paths it reported, to commit or move them, then retry. Exit 1:
   it landed nothing, or a port (the bin install included) after the
   `landed` line failed and the landing stays; end blocked with its
   message.
   Set `pr` in `F/ship.json` to every PR URL in producer order, separated
   by spaces, or leave it null when no repo has a remote, and run
   `forge commit <track>/<feature> ship`. Then run `forge pr state <url>`
   for each PR. Go on to Clean and Archive only when every one prints
   `MERGED` as its first word and every repo's golive exited 0 or its
   branch was already in `main`, a repo without a remote counting by its
   golive exit 0; otherwise end blocked with the first failing repo's
   cause: its PR URL and state line, or its golive exit and message.
   After a PR: in a later `/forge-ship` run, first run
   `forge pr state <url>` for each repo's PR; a nonzero exit ends blocked
   with its stderr. A PR that prints `MERGED` (an earlier run merged it,
   its golive perhaps not landed) needs only its golive: when
   `git -C <path> merge-base --is-ancestor forge/<track>-<feature> main`
   exits nonzero, its branch not in `main`, run
   `forge golive <path> forge/<track>-<feature>` directly, handled as
   above, golive's land being the gate, a full retest or its stamp reuse,
   its exit 7 asking the operator; when the ancestry check exits 0, that
   repo is done.
   For each repo's open PR, first run the Resolver loop with `main` and
   step `sync` in `W` as in step 7. When no full-passed commit is noted
   for the branch tip and
   `grep -q '^- CI full suite:' W/.forge/TESTING.md` exits 0, run
   `forge pr push` from `W`, then `forge pr checks --full <url>` from `W`
   in the background as in step 7 and show the operator each check's name
   and result. Its exit 0 is the full pass, noting
   `git -C W rev-parse HEAD` as the full-passed commit, and its exits 3, 4
   and 1 are handled as in step 7. Its exit 6 falls back to the full suite
   `forge test W`, then `forge pr push` from `W`, then
   `forge pr checks <url>` as in step 7.
   Otherwise, when no full-passed commit is noted for the branch tip, run
   the full suite `forge test W` as in step 7, then `forge pr push` from
   `W`; then run `forge pr checks <url>` from `W` in the background and
   show the operator each check's name and result, handling exits 3, 4
   and 1 as in step 7. Then run PR merge with `<url>` with no question,
   with the same retry, and then
   `forge golive <path> forge/<track>-<feature>`; with `forge.pushMain`
   unset, golive cannot fetch origin, so ask the operator to set it.
   Handle golive's exit and lines as above, keeping the `ported bin`,
   `bin held` and `port queued` lines, and run no deploy;
   then set `pr` and check every PR's state as above: Clean and Archive
   when every PR is merged, else end blocked the same way. Squash or
   rebase merges never make the branch an ancestor of `main`, so
   `forge archive` refuses them.
8. Clean. Only after every repo's `forge golive` exited 0 or its branch
   was already in `main`, run
   `forge clean <track>/<feature>`; it needs the split, so settle it before
   archive. It removes the targets when `origin/main` contains every
   branch; a repo with no origin is checked against local `main`. On
   exit 3 (an unreachable origin, a stale `origin/main` or a branch not
   in it) it removed nothing and printed on
   stderr every worktree, phase branch and session of the feature it would
   remove: keep each as a leftover for the result, with no question, and
   name `forge gc`, which collects them once the feature is archived, only
   as the operator's manual follow-up. Any other nonzero exit is reported
   the same way. Then go on to Archive.
9. Archive. First, while `F/ship.json` is still in place, run
   `forge pr state <url>` for every PR URL in `F/ship.json` `pr`; when any
   prints a first word other than `MERGED` (`OPEN` above all) or exits
   nonzero, end blocked through the Rules' blocked ending with the cause
   `<url> is <state line>, not merged`, never `result: Shipped`, and do
   not archive. Archive moves `F`, so this check never runs after it.
   Then run `forge archive <track>/<feature>`, then
   `forge commit <track>/<feature> archive`, which commits only the track
   JSON, the feature's records staying in S, and pushes that commit on
   `main` to origin when the repo has `forge.pushMain`; keep its
   `pushed` line or push warning for the result. Archive ends by printing
   each branch, worktree, origin branch or uncommitted tracked file the
   feature left behind as a `forge: leftover: <what>` line on stderr; it
   still exits 0, so keep every such line for the result. Archive deletes the merged
   local feature branch; golive deleted it on origin when it pushed `main`; `forge gc` catches any left over. Exit 1 on open findings
   means a record changed after step 7's check, with the code already on
   `main`: ask the operator with a question per finding whether to dismiss it, setting `dismissed`
   to the operator's reason, then archive again, or stop with
   `result: Not archived <track>/<feature>: open review findings`; on a
   branch not in `main`, end the turn with
   `result: Not landed <track>/<feature>: <reason>`. Otherwise end the turn with the
   golive lines of each repo, the archive commit's `pushed` line or push
   warning and each `forge: leftover:` line, then the line
   `result: Shipped <track>/<feature>, <each item>` and nothing after it.
   Each repo gives its PR URL or landed sha.
