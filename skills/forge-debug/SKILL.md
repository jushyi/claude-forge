---
name: forge-debug
description: Run an explicit /forge-debug request - hunt a bug's root cause with forge-debugger through operator checkpoints, commit a failing reproducing test on forge/debug-<slug> worktrees, then fix, review, merge and deploy.
argument-hint: '[--diagnose-only] <symptom>'
disable-model-invocation: true
---

# forge-debug

You hunt a bug's root cause and, unless stopped early, fix it end to end in
one interactive session. The current directory is the project root `R`, the
directory holding `.forge/`.

Arguments: `$ARGUMENTS` — an optional leading `--diagnose-only` flag, then
the symptom. Every `<repo>:C-NN` token names a concern; a token alone is a
valid symptom.

## Rules
- One interactive session in `R`. No `EnterWorktree`, no background session,
  and never `ScheduleWakeup`, `CronCreate` or a `sleep` poll.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`. Follow the reason; never work around it
  (`bash -c`, variables, scripts); ask the operator instead. It denies
  `git switch`, `checkout <x>`, `stash`, `reset`, `restore`, `clean`, `rebase`, `cherry-pick`,
  `merge` (all but `--abort` and `--quit`), `pull` and `commit --amend` in
  R's main checkout, and `branch -f|-m|-D main` or `update-ref
  refs/heads/main|HEAD|--stdin` or a `symbolic-ref` write of HEAD or main
  anywhere in the project: do that work in `W`, and `main` moves only through
  `forge golive`. Commit subjects must be Conventional Commits; it denies
  others in a forge-managed repo. It also denies edits to the live install
  (each file `port` installed, listed in
  `~/.local/state/forge/port.manifest`, and `~/.claude/forge/`); fix the
  repo and deploy.
- Iterate with narrow tests: a task's recorded command or
  `forge test --one <id>`, and `forge test --changed W`, with the Bash
  tool's `run_in_background: true`. Run a repo's full suite exactly once,
  as `forge test W` in the background at the start of Merge, so
  `forge golive`'s land reuses its pass. A
  `forge: tests passed (...), cached` line from that `forge test W` is a
  full-suite pass.
- Work in each worktree `W` through `git -C W` and absolute paths given to
  agents, as `forge-quick` does.
- Every question to the operator goes through `AskUserQuestion`. Wait for
  spawned agents by ending the turn; each completion resumes you.
- Spawn agents by type, description `debug <slug> <step> <agent>`. Agents
  never commit; you commit code in `W`, Conventional Commits.
- Write no track, feature or phase JSON and run no `forge commit`. Commit
  nothing under `.forge/` except a resolved concern's `concerns.json` and
  `CONCERNS.md`.
- `S` is `R/.forge/debug/<slug>/`: untracked scratch, never committed,
  records under `S/merge/` included. Every
  path given to an agent is absolute. Remove `S` when the run ends, however
  it ends.
- A run is not resumable: it ends fixed, deployed and live-checked, or
  stopped with its scratch, worktrees and branches discarded.
- `D` is the current round's name: `debug-<slug>` in the first round, then
  `debug-<slug>.r2`, `.r3` and so on after each still-broken live check
  (step 14). The dot keeps a round name apart from step 2's `-2` slug
  suffix, since a kebab-case slug never holds a dot. The round's branch is
  `forge/<D>` and its worktrees are `<repo>/.claude/worktrees/<D>`.
- Doc paths: `R/.forge/PROJECT.md`, `RULES.md` and `REJECTED.md`, plus
  ARCHITECTURE, STACK, CONVENTIONS and TESTING under each repo's `.forge/`
  (R's own in a single-repo project). Give the debugger the docs of every
  repo the project holds (R, each git repo directly under R, each
  `.forge/repos.json` entry), since the touched repos are unknown until the
  root cause.

## Budgets
Implementer: 2 attempts per task. Fixer: 2 attempts per task. 2 review-fix
rounds. When one runs out, `AskUserQuestion` offers retry, with the
operator's text added to the spawn prompt, or stop.

Stop, at a budget prompt or the inconclusive prompt, discards everything
and writes no `debugs.json` entry:
1. In each repo whose `forge/<D>` was pushed in step 13 and not merged, run
   `forge pr close <url>` from its `W` when it got a PR, then
   `git -C <repo> push origin --delete forge/<D>`.
2. In each repo that has them, run `git -C <repo> worktree remove --force <W>`
   and `git -C <repo> branch -D forge/<D>`.
3. Report the hypotheses, their evidence and the root cause when there is
   one, each PR URL closed in 1, and each PR URL or remote branch that 1
   failed to close or delete, with the command's error, for the operator
   to clean up.
4. Remove `S`.
5. End the turn with `failed: Debug <slug>: <reason>` and nothing after it.

An agent reply `blocked: <decision>` becomes an `AskUserQuestion`; record the
answer in `S/session.json` as a new `decision` checkpoint holding the
question and the operator's answer, then rerun the step.

## Resolver loop
Given `<branch>` and a touched repo's `W`: run `(cd W && forge merge <branch>)`.
Exit 0: continue. Exit 1: escalate its message through `AskUserQuestion`,
following the operator's answer. Exit 4: for attempt k = 1, 2, spawn
`forge-merger`, description `debug <slug> sync forge-merger`, with `W`, the
paths `forge merge` printed, the merge base
(`git -C W merge-base HEAD MERGE_HEAD`), the output of
`git -C W log --oneline <base>..HEAD` and of
`git -C W log --oneline <base>..MERGE_HEAD`, `S/session.json`, the record
`S/merge/<repo>-M<k>.json` (`<repo>` the repo's basename) and, on attempt 2,
the last `forge merge-check` output and test failure. Then run
`(cd W && forge merge-check <record>)` and, when it exits 0,
`forge test --changed W`; when both pass, run
`(cd W && forge merge --continue <record>)` and continue (its exit 1 counts
as a failed attempt). After the second failed attempt run
`(cd W && forge merge --abort)` and escalate through `AskUserQuestion` with
the conflicted paths and the last merge-check output, following the
operator's answer; both branches stay as they were.

## Steps
1. Parse. Split a leading `--diagnose-only` flag from the symptom. Every
   `<repo>:C-NN` token names a concern, looked up in that repo's
   `.forge/concerns.json`; a missing concern stops the run with that error
   before `S` exists. A blank symptom stops with the line
   `usage: /forge-debug [--diagnose-only] <symptom>`; there is no resume
   path.
2. Slug. Derive a short kebab-case slug from the symptom. When
   `forge/debug-<slug>` exists in any git repo the project holds (R, each
   git repo directly under R, each `.forge/repos.json` entry) or
   `R/.forge/debug/<slug>/` exists, append `-2`, `-3` and so on.
3. Session. Write `S/session.json` (debug) as `{"symptom": "<text>"}`.
4. Hunt loop. Spawn `forge-debugger` by type with the absolute
   `S/session.json` path (its input and its only JSON output), the doc
   paths, the absolute main-checkout path of every repo the project holds,
   and, when there are any, each named concern's `concerns.json` entry and
   the operator's guidance. Delete `outcome` from `session.json` before
   every spawn after the first, so it is absent while a debugger runs. It
   replies one line:
   - `root cause: <summary>`: `root_cause` is set; go on to step 5.
   - `checkpoint: <question>`: `AskUserQuestion` with the last
     `checkpoints` entry's question and its options, set `answer` on that
     entry, then spawn a new debugger.
   - `inconclusive: <what was checked>`: `AskUserQuestion` offers continue
     or stop; continue puts the operator's guidance into the next spawn
     prompt, stop runs the stop sequence.
5. Repos. A location's or concern's repo resolves to a git repo directly
   under R by name, else the `.forge/repos.json` entry (relative to R) with
   that basename, else R when the name is R's basename. The touched repos
   are the repos of `root_cause.locations` plus each named concern's repo.
   Producer order takes the order `root_cause.locations` first names a
   repo (the debugger lists producers first), followed by concern-only
   repos. A repo's producers are the repos before it.
6. Worktrees. Only in the touched repos, run
   `git -C <repo> check-ignore -q .claude/worktrees/ || echo .claude/worktrees/ >> "$(git -C <repo> rev-parse --path-format=absolute --git-common-dir)/info/exclude"`,
   then
   `git -C <repo> worktree add -b forge/<D> <repo>/.claude/worktrees/<D> main`,
   a new branch from local `main`; that path is the repo's `W`. Tell every
   agent that files are relative to its `W` and to edit only under `W`,
   never the main checkout. A `W` in a linked repo outside `R` needs the
   session in `bypassPermissions` or started with `--add-dir`, as STACK.md
   states; check nothing extra.
7. Plan and tests. Write `S/plan.json` (plan) with one task
   per touched repo that holds a location: `id` `T1`, `T2`… in producer
   order, `title` the root cause summary, `repo` the repo name (left out
   for the project root repo), `files` that repo's location files, and
   `deps` empty with `dep_reasons` `{}`. A concern-only repo gets no task.
   Spawn one `forge-implementer` per task, all in one message, with `S/plan.json`,
   the task ID, `S/session.json` as the spec path, the TESTING doc in its
   `W`, the words 'reproduction only, no fix' and output `S/tests/<id>.json`.
   Run its `command` in `W`; it must fail, a pass is a failed attempt:
   spawn it again with the output.
   Commit each task's test files in its `W` as their own Conventional
   Commit, with the root cause summary and its locations in the body.

   With `--diagnose-only`: after the test commits, remove each `W` with
   `git -C <repo> worktree remove <W>`. Keep `forge/<D>` in each repo that
   got a task and its test commit. In each touched repo that got no task (a
   concern-only repo), delete the empty branch with
   `git -C <repo> branch -D forge/<D>`. Then remove `S`. This exit writes
   no `debugs.json` entry. End the turn with
   `result: Debug <slug>: <root cause summary>; test on forge/<D>`
   and nothing after it. No PR, merge or deploy.
8. Fix. Spawn one `forge-fixer` per task, all in one message, outputs
   `S/fixes/F<k>.json` (`k` counts on across the run). Each prompt gives
   the finding (file and line of the task's first root-cause location, and
   `root_cause.summary`), every root-cause location in the task's repo
   (file, line and absolute path under `W`), all of which the fix must
   cover, the failing test command and its output, `S/session.json` as the
   spec path, and the TESTING doc in `W`. The task's test must then pass
   in `W`; a failing test or `"status": "failed"` is a failed attempt:
   spawn it again with the output. Commit each fix in its `W` as its own
   Conventional Commit.
9. Changed tests. Run `forge test --changed W` for each touched repo. A
   failure becomes a fixer input for the review round.
10. Review, as `forge-quick` steps 8 and 9. In each `W` write
    `git diff main...forge/<D>` to
    `$(git -C W rev-parse --absolute-git-dir)/forge-<D>.diff`.
    Spawn one `forge-reviewer` with every diff path, `S/session.json` and
    output `S/review.json`. Fix as `forge-quick` step 9, one `forge-fixer`
    per file, with `S/session.json` as the spec path, up to 2 rounds.
11. Concerns. For each named concern, run
    `forge resolve --concern <repo>:C-NN <repo>=<W>` in `R` before that
    repo's merge. Commit `W`'s `.forge/concerns.json` and
    `.forge/CONCERNS.md` as their own Conventional Commit.
12. Sync. For each touched repo, producer first, run the Resolver loop
    above in its `W` with `main`.
13. Merge, per repo in producer order. First run the one full suite run,
    `forge test W`; a failure becomes a fixer input for a review-fix round,
    then Sync and this run again.

    With an `origin` remote:
    1. `forge pr push -u origin forge/<D>` from `W`, which runs the repo's
       `- Pre-push:` command before it pushes, with the Bash tool's
       `run_in_background: true`, waiting for it by ending the turn: a
       Pre-push can outlast the Bash tool's time limit, and a timeout is
       no exit 3. When `forge pr push` exits 3
       (Pre-push failed, nothing pushed), its output becomes a fixer input
       for a review-fix round, then Sync, the full suite run and this push
       again, pushing nothing until it exits 0; any other nonzero exit is
       reported with its stderr, and `AskUserQuestion` offers retry or
       stop.
    2. Write the body to `S/pr-<repo>.md` and run
       `url=$(forge pr create forge/<D> "<title>" S/pr-<repo>.md)` from `W`.
       Take the URL from stdout only, never `2>&1`. The body holds the
       symptom, the root cause summary, the fix summaries, and one
       `Merge after <producer PR URL>` line for each producer repo that got
       a PR. A nonzero exit is reported with its stderr, and
       `AskUserQuestion` offers retry or stop.
    3. When the host of `git -C W remote get-url origin` (for an ssh or
       scp-style origin, the `hostname` line of `ssh -G <host>`) is not
       `github.com`, the origin is Forgejo: skip the wait, report that
       Forgejo PRs carry no checks, and go to 4. Otherwise run
       `gh pr checks --watch --fail-fast` from `W` with the Bash tool's
       600000 ms timeout, run again when a call times out.
       - Exit 0 passes.
       - Exit 1 whose stderr holds `no checks reported`: checks register
         only after `gh pr create`, so rerun every 10 seconds for up to 60
         seconds; if checks never register, count it as no CI and pass.
       - Any other exit 1 is a failed check. Its output becomes a fixer
         input for the next review-fix round; push the fix commits with
         `forge pr push` from `W`, handled as in 1, and wait on the checks
         again.
    4. Run `forge pr merge <url>` from `W` with no question; never tell
       the operator to merge by hand, and never a raw pull. A nonzero exit
       is reported with its stderr, and `AskUserQuestion` offers retry or
       stop; that stop ends the run as below.

    Without a remote there is no PR and no question.

    After the PR merge, or right away without a remote, run
    `forge golive <repo> forge/<D>`: it brings origin's `main` into local
    `main` when `forge.pushMain` is set (ask the operator to set it when a
    merged PR's repo has it unset), merges and tests in `_land`,
    fast-forwards local `main`, pushes it and runs an executable
    `./port --apply`. Exit codes as in `forge-quick` step 13, exit 4
    running this skill's Resolver loop with `main` in `W` before golive
    again; its stop keeps earlier repos' landings. A stop after a failed
    merge ends the run as a stop does, closing this repo's PR and deleting
    its remote branch; earlier repos' landings stay.

    Deploy, right after the landing: a repo with an executable `./port` was
    deployed by golive (its `ported` line). Otherwise read the deploy
    command from the repo's STACK.md `## Commands`; `AskUserQuestion` shows
    the exact command and approves it; run it in the repo's main checkout,
    never in `W`. A failing deploy is reported with its output, and
    `AskUserQuestion` offers retry or stop; that stop, or a declined
    deploy, ends the run as a stop that keeps the landings. A repo whose
    STACK.md names no deploy command skips this step. A run stopped here
    after some repos landed, by a failed merge, golive or deploy or a
    declined deploy, writes no `debugs.json` entry.
14. Live check, after every touched repo's merge and deploy. When
    `root_cause.reproduction` is set, run it in the main checkout of
    `root_cause.locations[0].repo` and show its output. Then ask, in its
    own `AskUserQuestion` after the operator tried the symptom, whether it
    is gone; only an explicit answer that they tried it and it is gone
    confirms it.

    Still broken, which writes no `debugs.json` entry; step 15 writes the
    run's single entry:
    1. Update `S/session.json`: append a `verify` checkpoint holding the
       live-check question and the operator's answer, append the
       reproduction rerun's command and output to the `evidence` of each
       `confirmed` hypothesis and set its verdict back to `open`, and
       delete `outcome`; `root_cause` keeps the merged fix's disproved or
       incomplete finding until the debugger replaces it.
    2. Remove this round's worktrees and delete its merged branches.
    3. Advance `D` to the next round's name (`debug-<slug>.r2`, then
       `.r3` and so on) and return to step 4. `S` keeps its path.

    Confirmed: go to step 15.
15. Clean up, after every repo's `forge golive` exited 0 and the live
    check confirmed. First, before removing `S`, record the run in
    `STATE/debugs.json`, `STATE` being the `STATE` line of `forge paths`
    run in R, the project's state dir. The entry is one JSON object: `slug`
    the run's final slug with any step-2 `-N` suffix, never `D`; `symptom`
    the parsed symptom without `--diagnose-only`; `cause` the
    `root_cause.summary` of the round whose live check passed; `repos` the
    touched repos' basenames in producer order, the repos golive landed in;
    `date` the local YYYY-MM-DD of the confirmed live check (`date +%F`).
    Hold `R`'s `forge.lock` from the read through the move, so two runs
    recording at once never drop each other's entry: run them as one
    command,
    `flock "$(git -C R rev-parse --path-format=absolute --git-common-dir)/forge.lock" bash -c '<script>' _ '<entry JSON>'`,
    whose script ends at its first failing command. In it, read
    `STATE/debugs.json` afresh, `{"debugs": []}` when it is absent, and
    write it with the entry appended by jq to `S/debugs.json`:
    `jq --argjson e "$1" '.debugs += [$e]' STATE/debugs.json > S/debugs.json`,
    with `jq -n --argjson e "$1" '{"debugs": [$e]}'` when the file is
    absent. Run `forge validate S/debugs.json`. When it exits 0, run
    `mv S/debugs.json STATE/debugs.json`. Nothing is committed. When the jq
    append, the validate or the move fails, print that command's error and
    the exact entry JSON for the operator to add by hand to
    `STATE/debugs.json`, and go on. A failed append or validate leaves
    `STATE/debugs.json` as it was, since only a validated `S/debugs.json`
    moves over it. The run still ends with its result line below, since
    the fix is live.

    Then remove each `W` with `git -C <repo> worktree remove <W>`. Delete
    each merged branch with `git -C <repo> branch -d`. Remove `S`. End the
    turn with the golive lines, then
    `result: Debug <slug>: <root cause summary>; <each PR URL or landed sha>; deployed`
    and nothing after it.
