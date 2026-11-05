---
name: forge-fast
description: Make a trivial change inline in the current session - at most 3 files, gated on the narrowest covering test and committed per repo. A larger task gets the /forge-quick command to run instead.
argument-hint: '<task>'
disable-model-invocation: true
---

# forge-fast

You make a trivial change inline in the current session and commit it. Fast
runs in any git repo and needs no `.forge/`.

Arguments: `$ARGUMENTS` — the task. When it is empty, ask once with a
freeform `AskUserQuestion` for the task.

## Rules
- Inline only: never spawn an `Agent`, never call the `Skill` tool, never run
  a `forge` command other than `forge push`, never write under any `.forge/`
  and write no planning JSON. Fast leaves only commits. `flock` (util-linux)
  is not a `forge` command, so step 4's use of it on `main` does not break
  this rule; its `forge.lock` file lives in the repo's common git dir
  (shared across the repo's worktrees), never under any `.forge/`.
- The global `forge-guard` hook denies what breaks forge's invariants with
  `forge-guard: <rule>: <reason>`; follow the reason and never work around
  it. It denies branch switches, stash, reset, rebase, cherry-pick, merge,
  pull and `commit --amend` in a forge project's main checkout: work that
  needs another branch goes in a worktree under `.claude/worktrees/` or the
  job tmp dir, never a branch switch in the main checkout.
- Too big: print the line `/forge-quick <task>` with the task text filled in
  verbatim, and end the turn. Do not ask with `AskUserQuestion` and do not
  run it yourself: `forge-quick` has `disable-model-invocation: true`, so
  Claude Code blocks a Skill-tool call to it and its steps must not be
  reproduced another way. The operator types the command.
- The only question fast asks is the one for an empty task.

## Steps
1. Scope check, before any edit. Read what you need to judge the task. It is
   trivial when it needs at most 3 files, no new dependency, no research and
   has a clear implementation. Otherwise edit nothing: the task is too big.
2. Edit. Make the change and keep the list of paths you edited. Before
   touching a 4th file, stop: leave the edits so far unstaged in the tree,
   do not commit, and the task is too big. Before touching any file, run
   `git -C <dir of the path> status --porcelain -- <path>`; when it prints
   anything, the file already holds staged or unstaged changes that a commit
   of that path would sweep in, so do not touch it: stop, leave the edits so
   far unstaged, do not commit, and go to step 5 with that path dirty.
3. Test gate. Run the narrowest existing test covering the changed files. In
   a repo with `.forge/TESTING.md`, take the command from it; otherwise infer
   it from the repo (its manifest, test layout or CI config). Run each touched
   repo's test in that repo. A failing test blocks every commit: leave the
   edits unstaged in the tree, neither revert nor retry, and go to step 5 with
   the failure output. With no covering test, go on and note
   `no covering test`.
4. Commit, per touched git repo. Find each edited path's repo with
   `git -C <dir of the path> rev-parse --show-toplevel`; in a workspace each
   child repo that holds an edited path counts. In each repo `<top>`:
   - `git -C <top> add -- <the paths fast edited in it>`, nothing else, so
     every other uncommitted change stays untouched and unstaged.
   - `git -C <top> commit -m <message> -- <those paths>`: one Conventional
     Commit on the repo's current branch, with no extra prompt and no push
     other than `forge push`. The message ends with the session's
     attribution lines. When `git -C <top> branch --show-current` prints
     `main`, wrap that same commit in `flock` on the repo's `forge.lock`,
     the lock `forge commit` and `forge land` hold:
     `flock "$(git -C <top> rev-parse --path-format=absolute --git-common-dir)/forge.lock" git -C <top> commit -m <message> -- <paths>`.
     `git add` stays outside the lock either way. On any other branch,
     commit exactly as above with no `flock`.
   - Once the commit has succeeded, run `forge push <top>`; it does nothing
     unless that repo opted in and is on `main`, so it is safe to run after
     every commit. A failed push only warns; note the warning for step 5.
5. Final message.
   - Committed: per repo, the commit hash and its files, plus the test
     command run or `no covering test`, plus any push warning.
   - Blocked by the test: the failure output and that the edits are left
     unstaged.
   - Dirty path: the path with pre-existing changes, the files left unstaged,
     and that the operator commits or moves that path's changes before rerunning.
   - Too big: the files left unstaged when step 2 stopped, then the line
     `/forge-quick <task>` and nothing after it.
