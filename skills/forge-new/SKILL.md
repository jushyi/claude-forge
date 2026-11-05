---
name: forge-new
description: Set up a forge project, open, close or reopen a track, or add a feature to an open track.
disable-model-invocation: true
---

# forge-new

You run forge's entry: project setup, track open, close and reopen, and add
feature. Feature discuss is `/forge-discuss`, in a fresh session.

## Rules
- Every question to the operator goes through `AskUserQuestion`. Open each
  topic freeform: a question whose options are "Nothing more" and "I'll type
  it", so the operator answers in Other. Then ask one decision per question,
  options with trade-offs, your recommendation first.
- No research, no web, no subagents.
- Run commands in the project root, the directory holding `.forge/`.
- Edit planning JSON. Schemas:
  `~/.claude/forge/schemas/`. `forge <command> --help` documents each command.
- Commit only with `forge commit`, except the two commits below (Setup
  step 7, Track open step 6); never `--amend` and never `git add -A` in an
  existing project. The global `forge-guard` hook denies what breaks
  forge's invariants with `forge-guard: <rule>: <reason>`; follow the
  reason and never work around it. It denies branch switches, stash,
  reset, rebase, merge, pull and `commit --amend` in the main checkout:
  work that needs another branch goes in a worktree under
  `.claude/worktrees/` or the job tmp dir.

## Route
- No `.forge/` in the working directory: run Setup, then Track open.
- Otherwise read `.forge/tracks/*.json` and ask which to run: New track, Add
  feature (an open track exists), Close track (an open track exists), Reopen
  track (a closed track exists).

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

## Setup
1. Ask for the project name, a one-line description, and what the project is
   for, its priorities and what is out of scope.
2. Child repos are the direct subdirectories holding `.git`. Ask a one-line
   description for each repo without a `.claude/rules/forge.md`.
3. Run `forge-init <name> "<description>" [<repo>="<description>"...]`.
4. Fill the sections of `.forge/PROJECT.md` from the answers.
5. When any repo holds code, run `forge map`.
6. For each repo with UI, by your judgment (the project root in a
   single-repo project, each child in a workspace; skip a repo without UI,
   and skip this step entirely when the optional Impeccable plugin is not
   installed, so `/impeccable` is not an available skill):
   run `/impeccable init` when its root has no `PRODUCT.md`, then
   `/impeccable document` when it holds UI code and its root still has no
   `DESIGN.md`. Both are skills run in this session with the impeccable
   skill loaded, not subagents; the operator answers their `AskUserQuestion`
   rounds. In a workspace, run impeccable's helper commands from `<repo>/`:
   its `impeccable context` verb takes the working directory as the project
   root and a child's `.git` stops its monorepo walk. When any file was
   written, rerun `forge-init` with the step 3 arguments so the routers link
   the new files.
7. Commit the paths setup wrote, `PRODUCT.md` and `DESIGN.md` included,
   plus `.impeccable/config.json` and `.impeccable/design.json` when setup
   wrote them, and nothing else; the rest of `.impeccable/` stays
   uncommitted: `git add -- <paths> && git commit -m
   "chore(forge): set up <name>" -- <paths>`.

## Track open
1. Ask freeform what the line of work is and its goal. Run Deepen on the
   answer. Name the track with a lowercase slug of at most 16 characters.
2. Candidates: list each `- ` line of `.forge/seeds.md` prefixed `seed: `
   and each `- ` line of `.forge/todo.md` prefixed `todo: `; heading, blank
   and comment lines are not candidates, and a missing `.forge/seeds.md`
   adds none. Beside them list the open concerns of each repo the track
   touches (`.forge/concerns.json` in a single-repo project):
   ```bash
   jq -r '.concerns[] | select(.status == "open")
     | "\(.id) — \(.area) — \(.severity) — \(.focus // [] | if length == 0 then "—" else join(", ") end)"
   ' <repo>/.forge/concerns.json
   ```
   Rank them against the track goal yourself and print all candidates as
   one numbered list, the ones that serve the goal most first, ties in file
   order: seeds, then todos, then concerns. Ask which become features or
   requirements.
3. Question until you can split the work: users, outcomes, constraints, edge
   cases, what is out of scope.
4. Propose the feature split as a table: feature slug (at most 20
   characters), what it delivers (one line), depends (a slug in this track
   or `<track>/<feature>`), and its requirements. Requirement IDs are
   `<FEAT>-NN` with a short uppercase prefix; each requirement states one
   behavior specific and testable enough to verify, and may name its
   `owner`: `agent`, the default you propose, when a test or the agent run
   shows it; `operator` when it needs a live account, device, production
   data, payment, sitting or visual judgement; `post-ship` when measurable
   only after golive. `/forge-discuss` settles the owners. Ask the operator
   to approve or change it.
5. Write `.forge/tracks/<track>.json` (`status: "open"`; `notes` holds
   standing context the features share, `[]` when none; `shipped: []` for a
   new track). Then for each feature run `forge paths <track>/<feature>`
   first, so the state dir S and its root file exist, and write
   `F/requirements.json`, `F` being its `F` line, under S, with
   `done: false`, each requirement carrying the `owner` the approved table
   names. A requirement taken from a concern sets `concern: "<repo>:C-NN"`.
6. Run `forge commit <track> "open track"`. When accepted seed or todo
   lines became features or requirements, remove each line from the file it
   came from, `.forge/seeds.md` or `.forge/todo.md`, and commit the removals
   in one commit under the lock `forge commit` holds, with `<files>` naming
   only the files whose lines it removed, since a file absent from the repo
   fails the commit:
   `flock "$(git rev-parse --path-format=absolute --git-common-dir)/forge.lock" git commit -m "docs(todo): move todos into track <track>" -- <files>`.
7. Print the Features table from `forge status` and tell the operator to start
   `/forge-discuss` in a fresh session.

## Add feature
1. Ask which open track, then freeform what the feature delivers. Run Deepen
   on the answer.
2. Run Track open steps 2 to 4 for this one feature, listing the `seed: ` and
   `todo: ` lines beside the open concerns and ranking them against the
   track's `goal`; it only grows the track's scope.
3. Append it to the track's `features`, run `forge paths <track>/<feature>`
   and write `F/requirements.json` as Track open step 5 does, then run
   `forge commit <track> "add <feature>"`. When accepted seed or todo lines
   became the feature or its requirements, remove them from the file each
   came from and commit the removals as Track open step 6 does. Point to
   `/forge-discuss`.

## Close track
1. Ask which open track. When it still has unshipped features, name them and
   ask to confirm.
2. Set `status: "closed"` and run `forge commit <track> "close track"`.

## Reopen track
1. Ask which closed track, set `status: "open"`.
2. Run Track open steps 2 to 5 with the track's goal, features and shipped
   list as the starting point, ranking against the track's `goal`, then Track open steps 6 and 7 with the commit
   step `"reopen track"`.
