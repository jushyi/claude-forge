---
name: forge-quick
description: Run an explicit /forge-quick request - plan, implement, test, review, fix and optionally verify a small task on forge/quick-<slug> worktrees, then open PRs or merge locally.
argument-hint: '[--discuss] [--research] [--verify] <task>'
disable-model-invocation: true
---

# forge-quick

You run a small task end to end in one interactive session. The current
directory is the project root `R`, the directory holding `.forge/`.

Arguments: `$ARGUMENTS` — optional `--discuss`, `--research` and `--verify`
flags, then the task. Every `<repo>:C-NN` token names a concern; a token alone is a
valid task.

## Rules
- Every question to the operator goes through `AskUserQuestion`, never
  plain text. Before it, when `PushNotification` is not loaded load it with
  `ToolSearch` `select:PushNotification`, run
  `forge notify "<session title>" "<headers>"`, send `PushNotification`
  `<title>: <headers>` under 200 characters, then call `AskUserQuestion`
  with no tool call between; a failed notify or push is ignored, never
  retried. The session title is `<project> quick <task>` (`<project>`:
  basename of R) and `<headers>` each question's `header` joined by `, `.
  A procedure of more than 3 steps is printed first as numbered session
  text, and the question stays one line.
- Wait for spawned agents and background commands by ending the turn; each
  completion resumes you. Never `ScheduleWakeup`, `CronCreate` or a `sleep`
  poll. No `EnterWorktree`, no background session.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`. Follow the reason; never work around it
  (`bash -c`, variables, scripts); ask the operator instead. It denies
  `git switch`, `checkout <x>`, `stash`, `reset`, `restore`, `clean`, `rebase`, `cherry-pick`,
  `merge` (all but `--abort` and `--quit`), `pull` and `commit --amend` in
  R's main checkout, and `branch -f|-m|-D main` or `update-ref
  refs/heads/main|HEAD|--stdin` or a `symbolic-ref` write of HEAD or main
  anywhere in the project: do that work in `W`, and `main` moves only through
  `forge golive`. Commit subjects must be Conventional Commits; it denies
  others in a forge-managed repo.
- Run tests with the Bash tool's `run_in_background: true`. Iterate only
  with a task's recorded command or `forge test --one <id>`; quick runs no
  `forge test --changed`. Run a touched repo's full suite exactly once, as
  `forge test W` at the start of Merge, so `forge golive`'s land reuses its
  pass. A `forge: tests passed (...), cached from ... (docs-only change)`
  line is a pass, and a `forge: tests passed (...), cached` line from
  that `forge test W` is a full-suite pass too.
- `S` is `R/.forge/quick/<slug>/`: untracked scratch, never committed,
  records under `S/merge/` included. Every path given to an agent is
  absolute. Remove `S` when the run ends, done or stopped.
- Doc paths: `R/.forge/PROJECT.md`, `RULES.md` and `REJECTED.md`, plus
  ARCHITECTURE, STACK, CONVENTIONS and TESTING under each touched repo's
  `.forge/` (R's own in a single-repo project).
- A repo's `W` is `<repo>/.claude/worktrees/quick-<slug>` on
  `forge/quick-<slug>`. Work in it through `git -C W` and absolute paths.
- Spawn agents by type, description `quick <slug> <step> <agent>` or
  `quick <slug> <id> <agent>`. Agents never commit; you commit code in `W`,
  Conventional Commits.
- Write no track, feature or phase JSON and run no `forge commit`. Commit
  nothing under `.forge/` except a resolved concern's `concerns.json` and
  `CONCERNS.md` and step 9's todo deferral lines in `.forge/todo.md`.
  `forge quick-log` in Clean records the quick in `STATE/quicks.json` with
  no commit and prints `forge: recorded quick <slug>`; `STATE` is the
  `STATE` line of `forge paths` run in R, the project's state dir. The merge commits `forge merge` makes in `W`, in Sync and
  the Merge step's re-sync, may carry `.forge/` changes from `main`.
- Per-repo steps take the repos in producer order, producer first.

## Budgets
Planner: 2 attempts. Implementer: 2 attempts per task. Fix: 2 fixer
rounds, shared with Verify. When one runs out, `AskUserQuestion` offers retry, with the operator's text added to the spawn
prompt, or stop. Stop removes `S`, keeps every branch and worktree, and
reports them. An agent reply `blocked: <decision>` becomes an
`AskUserQuestion`; append the answer to `decisions` in `S/spec.json` and
rerun the step. No scout, gap-finder or verifier.

## Resolver loop
Given `<branch>` and a touched repo's `W`: run `(cd W && forge merge <branch>)`.
Exit 0: continue. Exit 1: escalate its message through `AskUserQuestion`,
following the operator's answer. Exit 4: for attempt k = 1, 2, spawn
`forge-merger`, description `quick <slug> sync forge-merger`, with `W`, the
paths `forge merge` printed, the merge base
(`git -C W merge-base HEAD MERGE_HEAD`), the output of
`git -C W log --oneline <base>..HEAD` and of
`git -C W log --oneline <base>..MERGE_HEAD`, `S/spec.json`, the record
`S/merge/<repo>-M<k>.json` (`<repo>` the repo's basename) and, on attempt 2,
the last `forge merge-check` output. Then run
`(cd W && forge merge-check <record>)` and, when it exits 0, run
`(cd W && forge merge --continue <record>)` and continue (its exit 1 counts
as a failed attempt). The merged tree is tested by the full suite that
follows: step 13's `forge test W`, or golive's land after a golive exit 4.
After the second failed attempt run `(cd W && forge merge --abort)` and
escalate through `AskUserQuestion` with
the conflicted paths and the last merge-check output, following the
operator's answer; both branches stay as they were.

## Deepen
Answer this prompt for the operator's request:

> I want a deeper version of this task, not a bigger one. Before rewriting it:
> (1) say what a top professional in this field would do here that I'm not
> asking for; (2) name the rawest material they would start from NEXT instead
> of what has already been digested for me; (3) name the specific methods and
> tools they would use; (4) say what, other than you or me, would show the
> result is right. Then rewrite my prompt to ask for exactly that.

No research, web or subagents: answer from the request, the project's docs and
what you know. Print the four answers and the rewritten prompt as session text,
then call `AskUserQuestion` with the options `Use the rewrite`, first, and
`Keep my prompt`; the operator's Other text replaces both. The chosen text is
the request from here on.

## Steps
1. Spec. Parse the flags and the `<repo>:C-NN` tokens. Look up each concern
   in that repo's `.forge/concerns.json`; a missing one stops the run with
   that error before `S` exists. A named concern's repo is a touched repo.
   Derive a short kebab-case slug from the task. When `forge/quick-<slug>`
   exists in any git repo the project holds (R, each git repo directly
   under R, each `.forge/repos.json` entry), `R/.forge/quick/<slug>/`
   exists or `STATE/quicks.json` (`STATE` from `forge paths` run in R)
   already holds the slug, append `-2`,
   `-3` and so on. Run Deepen on the task and its named concerns. Write
   `S/spec.json` (feature-spec):
   `spec` holds the task text Deepen settled and each named concern with its
   `concerns.json` entry; `decisions` is empty.
2. Discuss, with `--discuss`. One `AskUserQuestion` round, one decision per
   question, each with a recommendation; settle cross-repo details for a
   task spanning several repos. Append each answer to `decisions` in
   `S/spec.json`.
3. Research, with `--research`. List the factual questions whose answers
   change the plan; zero is fine. Spawn one `forge-researcher` per question
   in one message, outputs `S/research/R<k>.json`, framed by `S/spec.json`
   and the doc paths. Merge:
   `jq -s '{questions: map(.questions[])}' S/research/*.json > S/research.json`.
   Without `--research` or with no questions write `{"questions": []}`.
4. Plan. Spawn `forge-planner` with `S` as the input directory, the doc
   paths and output `S/plan.json`; each task records why it depends on
   another in `dep_reasons` (`{}` with no `deps`). Check it with
   `jq -r -f <file> S/plan.json`,
   the file holding:
   ```
   (.tasks | map({(.id): .deps}) | add) as $g
   | def up: . as $s | ($s + [$s[] | $g[.][]?] | unique) | if . == $s then . else up end;
   [.tasks[] | .up = (.deps | up)] as $t
   | ($t | group_by(.id)[] | select(length > 1) | "duplicate task \(.[0].id)"),
     ($t[] | .id as $i | .deps[] | select($g[.] == null) | "\($i) depends on unknown \(.)"),
     ($t[] | select(has("dep_reasons") | not) | "\(.id) has no dep_reasons"),
     ($t[] | .id as $i | .dep_reasons as $r | .deps[] | select($r[.]? == null) | "\($i) depends on \(.) with no dep_reasons entry"),
     ($t[] | select(IN(.up[]; .id)) | "\(.id) is in a dependency cycle"),
     ($t[] as $a | $t[] as $b | select($a.id < $b.id and ($a.repo // "") == ($b.repo // ""))
      | select((IN($a.up[]; $b.id) or IN($b.up[]; $a.id)) | not)
      | ($a.files - ($a.files - $b.files))[] | "\($a.id) and \($b.id) share \(.) with no dependency between them")
   ```
   Any output line fails the plan: spawn the planner again with those lines
   as the replan reason. Run only a plan that prints nothing.
5. Repos. A task's `repo` is a git repo directly under R, else the
   `.forge/repos.json` entry (relative to R) with that basename; a task
   with none is in the project root repo, named by R's basename. The
   touched repos are the tasks' repos plus each named concern's repo. Repo
   Y depends on repo X when a task in Y depends on a task in X. A cycle
   between repos stops the run before any worktree: report it and remove
   `S`.
6. Worktrees. For each touched repo run
   `git -C <repo> check-ignore -q .claude/worktrees/ || echo .claude/worktrees/ >> "$(git -C <repo> rev-parse --path-format=absolute --git-common-dir)/info/exclude"`,
   then
   `git -C <repo> worktree add -b forge/quick-<slug> <repo>/.claude/worktrees/quick-<slug> main`.
   Tell every agent the plan's `files` are relative to its `W` and to edit
   only under `W`, never the repo's main checkout.
7. Tasks, in waves. Every task whose `deps` are all done runs in the same
   message.
   - Spawn `forge-implementer` with `S/plan.json`, the task ID,
     `S/spec.json`, the doc paths and `S/tasks/<id>.json`, and no scout
     path. Its recorded `command` must exit 0 in `W`. A failure or
     `"status": "failed"` is a failed attempt: spawn it again with the
     output.
   - After each wave commit each task's files (its plan `files` and any
     file its `deviation` names) in its `W`, one commit per task.
8. Review. In each `W` write
   `git diff main...forge/quick-<slug>` to
   `$(git -C W rev-parse --absolute-git-dir)/forge-quick-<slug>.diff`. Spawn
   one `forge-reviewer` with every diff path, `S/spec.json` and
   `S/review.json`.
9. Fix. Group the open high and medium findings (`fixed` false, no
   `dismissed`, no `deferred`) by file and spawn in one message one
   `forge-fixer` per file, never two for one file, plus one per failing
   test whose files no finding names, the failing tests coming from
   step 13's full suite. A Codex-only medium (source `codex`, severity `medium`)
   is advisory: it gets no fixer and is never chased.
   Each prompt gives the file's findings (file, line, summary, `index` in
   `S/review.json`, each with its own output `S/fixes/F<k>.json`, k
   counting on across rounds) or the failing command and its output,
   `S/spec.json`, the TESTING doc in the `W` and the file's absolute path,
   and no split file, as quick has no later phase; a finding's file is
   relative to the `W` whose diff holds it. Commit each fix in its `W` as
   its own commit. Record each finding of `<review>`, the absolute path of
   `S/review.json`, from its fix JSON only, never on your own judgment, and
   never delete a finding. A `fixed` fix sets `fixed` true. A `failed` fix
   with a summary starting `not a defect: ` sets `dismissed` to that
   summary, except on a high security-class finding (its title, the
   summary before its first `: `, starts `[security]`, `[pii]` or
   `[auth]`, or `S/spec.json` `focus` holds `security` or `pii`). For
   `out of scope: todo: ` followed by `<reason>`, set `deferred` to
   `{"owner": "todo", "reason": "<reason>"}`, never `dismissed`, with no
   owner check, except that a high security-class finding stays open on
   an out of scope reply. Quick has no later phase, so an
   `out of scope: phase <N>: ` reply leaves the finding open. A
   `spec requires: ` outcome, and a `not a defect: ` outcome on a
   high security-class finding, asks the operator with `AskUserQuestion`
   about the finding and the spec bullet or decision it names, never
   setting `dismissed` from the fix; when the operator's answer dismisses
   the finding, set its `dismissed` to `settled: <operator's words>` at
   once, else it stays open. Everything else stays open. When `deferred`
   `owner` is `todo`, append
   `- <today> <file>:<line> <title> (deferred from quick <slug>: <reason>)`,
   today from `date +%F`, to the `.forge/todo.md` of the `W` holding the
   finding; `S/review.json` is never committed, so commit the line in the
   same commit as that file's fix in the `W`, or as its own
   `docs(todo): defer quick <slug> findings` commit when the fixer changed
   nothing. Send the findings still open to the next round;
   step 13's full suite tests the fixes.
10. Verify, with `--verify`. In each touched `W`, producer first, run its
    STACK build or start command when it has one and check it comes up
    without errors; run a serving command as
    `forge bg forge-quick-<slug>-<repo> --cwd <W> -- <command>`
    and stop it with `forge bg --stop` after the operator answers. Then print short
    manual-test steps for the task and ask pass or fail through
    `AskUserQuestion`. Add each smoke failure, and each failed manual step
    with the operator's text, to `S/review.json` as an open high finding on
    the file it points to; one that points to no file goes to step 9 as a
    failing test, with its command or the operator's text as the output.
    Run step 9 Fix for them with `forge-fixer`, then this step again. Fix and Verify share Fix's 2 rounds; when they run
    out, `AskUserQuestion` offers retry or stop as in Budgets.
11. Concerns. For each named concern run
    `forge resolve --concern <repo>:C-NN <repo>=<W>` in `R` before that
    repo's PR or merge, then commit `W`'s `.forge/concerns.json` and
    `.forge/CONCERNS.md` as their own commit.
12. Sync. For each touched repo, producer first, run the resolver loop above
    in its `W` with `main`.
13. Merge. First run `forge test W` for each touched repo, the one full
    run; the docs-only carry-over line is a pass. A failure goes back to
    step 9 as a failing test, then Sync and this run again. Then for each
    repo, producer first:
    - With a remote: `forge pr push -u origin forge/quick-<slug>` from
      `W`, which runs the repo's `- Pre-push:` command before it pushes,
      with the Bash tool's `run_in_background: true`, waiting for it by
      ending the turn: a Pre-push can outlast the Bash tool's time limit,
      and a timeout is no exit 3.
      When `forge pr push` exits 3 (Pre-push failed, nothing pushed), its
      output goes back to step 9 as a failing test, then Sync, the full
      run and this push again, pushing nothing until it exits 0; any other
      nonzero exit is escalated with its stderr through `AskUserQuestion`.
      Then write the body to `S/pr-<repo>.md` and run
      `url=$(forge pr create forge/quick-<slug> "<title>" S/pr-<repo>.md)`
      from `W`, the URL from stdout only, never `2>&1`. The body holds the
      task, the plan's task titles and one line
      `Merge after <producer PR URL>` for each producer repo that got a PR.
      A nonzero exit is escalated with its stderr through
      `AskUserQuestion`. Then run `forge pr merge <url>` from `W` with no
      question (a nonzero exit is reported with its stderr and the PR stays
      open), then `forge golive` as below, which brings origin's `main`
      into local `main`, tests it and ports; it needs
      `git config forge.pushMain true` in that repo, so ask the operator to
      set it when unset.
      Never tell the operator to merge by hand, and never a raw pull.
    - Without one: no PR and no question.
    After the PR merges, or right away without a remote, run
    `forge golive <repo> forge/quick-<slug>`. Exit 0 prints the `landed`,
    `pushed`/`not pushed` and `ported`/`no port` lines for the final
    message. Exit 4: rerun the resolver loop above with `main` in `W`, then
    golive again. Exit 5 or 7: land nothing and `AskUserQuestion` with the
    output, offering retry or stop, as in Budgets. Exit 6: report the R
    paths it named and offer retry once they are committed or moved, or
    stop. Exit 1: report its message. A failed merge or golive keeps the
    branch and `W`, as a stop does; say so.
14. Clean. After a repo's `forge golive` exits 0, run
    `git -C <repo> worktree remove <W>` and
    `git -C <repo> branch -d forge/quick-<slug>`. A PR left open keeps its
    branch and `W`.
    Once `forge golive` has exited 0 for every touched repo, run
    `forge quick-log <slug> <task> <repo>...` once from R: `<task>` is the
    task text as typed with the flags stripped and each `<repo>` a touched
    repo's basename. A stop, a PR left open or a golive that did not exit 0
    runs no `forge quick-log`. A failing `forge quick-log` writes nothing to
    `STATE/quicks.json`, is reported with its stderr before the result line
    and undoes none of the landed work.
    Remove `S`. End the turn with the golive lines, then the line
    `result: Quick <slug>: <each PR URL or landed sha>` and nothing after
    it.
