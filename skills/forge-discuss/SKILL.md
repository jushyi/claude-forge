---
name: forge-discuss
description: Run forge feature discuss for a ready feature through spec, research, phase split and phase numbers, or reopen it after a failed operator test.
argument-hint: '[--auto] [<track>/<feature>]'
disable-model-invocation: true
---

# forge-discuss

You run a forge feature discuss: spec, research, phase split, phase numbers.

Arguments: `$ARGUMENTS`

## Rules
- Every question to the operator goes through `AskUserQuestion`; in auto
  mode only the questions Auto mode keeps reach the operator. Open each
  topic freeform: a question whose options are "Nothing more" and "I'll type
  it", so the operator answers in Other. Then ask one decision per question,
  options with trade-offs, your recommendation first.
- Run commands in the project root, the directory holding `.forge/`.
- Edit planning JSON. Schemas:
  `~/.claude/forge/schemas/`. `forge <command> --help` documents each command.
- Commit only with `forge commit`; never `git add`, `git commit` or
  `--amend` by hand. The global `forge-guard` hook denies what breaks
  forge's invariants with `forge-guard: <rule>: <reason>`; follow the
  reason and never work around it. It denies branch switches, stash,
  reset, rebase, merge, pull and `commit --amend` in the main checkout:
  work that needs another branch goes in a worktree under
  `.claude/worktrees/` or the job tmp dir. `F/research/R<k>.json` are
  agent records; rerun the agent instead of editing them.
- `F` below is the `F` line of `forge paths <track>/<feature>`, the
  feature's directory in the state dir S; every spawn prompt gives it
  absolute, so agents write it from any worktree. Doc paths passed to
  agents: `.forge/PROJECT.md`, `.forge/RULES.md`, `.forge/REJECTED.md` and the
  `.forge/` ARCHITECTURE, STACK, CONVENTIONS and TESTING of each repo the
  feature touches. Those repos are the project root, its child repos and the
  repos linked in `.forge/repos.json` (paths relative to the project root,
  each named by its directory basename); a linked repo's docs are its own
  `.forge/` docs.

## Auto mode
`--auto` as the first argument token selects auto mode, for a session that
settles the discuss without the operator; exactly one `<track>/<feature>`
follows it. Without `--auto` nothing here applies and every step runs as
written.
- Each other step that would ask the operator takes your recommended
  option instead and adds it to `F/spec.json` `decisions` as exactly
  `Auto: <decision> (recommended; operator may overturn)`.
- Only these reach the operator, through `AskUserQuestion` as in an
  interactive discuss: a `blocked: <decision>` reply from a researcher
  (Research step 2), asked between mockup rounds while Mockups runs, or from
  the splitter (Split step 1), its answer recorded as a decision there, and
  for a UI feature the Design step's `/impeccable shape` interview and each
  Mockups Approve or Revise.
- The researchers run in the background beside Design and Mockups as in an
  interactive discuss (Discuss steps 4-5), their findings recorded as
  `Auto:` bullets (Research step 4).
- A step below that needs the operator ends the discuss with Finish's line
  `result: Discuss <track>/<feature> waits for an interactive discuss: <what>`.
- A completed auto discuss runs Finish unchanged.

## Pick
In auto mode with no `<track>/<feature>`, print `usage: /forge-discuss
--auto <track>/<feature>` and stop.
1. With no argument, run `forge status`. Candidates are the Features rows
   with status todo or discussing and Waiting on `—`. None: say so and
   stop. Otherwise ask which one to discuss, one option per candidate (the
   first four when there are more; the operator types another in Other).
2. Run `forge ready <track>/<feature>`; when it does not print `ready`, report
   its output and stop.
3. `F/verify.json` exists, or a phase of the split has a `result.json`
   with `status` `blocked`: run Reopen. `F/split.json` with no phase
   `number`: run Split from step 2. `F/split.json` with a numbered phase:
   say `<track>/<feature> is in implementation` and stop. Otherwise run
   Discuss, resuming after
   the last file present: `research.json` → Split. `spec.json` with no
   `research.json`: re-list the research questions (Research step 1) and
   respawn in the background only those no existing `F/research/R<k>.json`
   answers, as Research step 2 gives, numbering new ones after the last
   `R<k>` as Reopen step 6 does. Beside the respawned researchers, run
   Discuss step 5 when `F/design.json` is missing, so a UI feature runs
   Design, or Mockups while any of its mockups is unapproved; Split then
   waits as Discuss step 5 gives.
   In auto mode, where this would run Reopen, run nothing and end with
   `result: Discuss <track>/<feature> waits for an interactive discuss:
   reopen`, since Reopen needs the operator's test findings.

## Discuss
1. Read `F/requirements.json`, `.forge/tracks/<track>.json` and the doc paths.
2. Ask freeform, and question until each requirement has what a planner
   needs or an open research question. A concern or todo reaches the
   feature only when the operator names it: append it to
   `F/requirements.json` as a requirement with the next `<FEAT>-NN` id, its
   text a testable behavior, `done: false`, and a concern-backed one sets
   `concern: "<repo>:C-NN"`.
   In auto mode, settle each requirement from `F/requirements.json`,
   `.forge/tracks/<track>.json`, the doc paths and the code, taking the recommended answer for every open point and
   recording each as an `Auto:` bullet; an open factual question becomes a
   Research question.
3. Propose focus tags from `F/requirements.json`: each of `security`,
   `rate-limit`, `scaling`, `performance` and `pii` that applies, with a
   one-line reason.
   Confirm them in one multiSelect question, header `Focus`, one option per
   tag with its reason as the description; more than 4 spill into a second
   question. Pad a question with fewer than two tags, zero included, with
   `Nothing more` and then `I'll type it` to reach two options, so the
   operator can add tags in Other. Unticked tags are dropped.
   Keep a typed tag only when it is one of the five, since `forge commit`
   refuses any other; ask again about any other. When the confirmed focus
   holds `scaling`, ask freeform for the numeric targets (`rps`,
   `max_rows`, `max_fanout`; integers; at least one), question until at
   least one is settled; `performance` asks no number. When the focus holds
   `pii`, ask freeform for the PII field names, question until at least one
   is named.
   In auto mode, the proposed focus tags are confirmed as proposed,
   recorded as an `Auto:` bullet, and their targets and PII field names
   come from the requirements and docs. When a confirmed tag needs values
   neither states (numeric `targets` for `scaling`, `pii_fields` for
   `pii`), write and commit nothing and end with `result: Discuss
   <track>/<feature> waits for an interactive discuss: <what>`, since
   `forge commit` refuses those tags without their values.
4. Write `F/spec.json`: `decisions` holds each operator decision, one bullet,
   including the confirmed focus tags; `spec` holds behavior, interfaces
   and constraints the phases need; `focus` holds the confirmed tags, omitted
   when none; `targets` holds the confirmed numeric targets, present when
   focus holds `scaling`; `pii_fields` holds the confirmed
   field names, present when focus holds `pii`. Reword `F/requirements.json`
   when the operator changes a requirement. Then set `owner` on every
   requirement in `F/requirements.json` by one rule: `agent` when a test in
   the repo or feature verify's agent run can show it on this host;
   `operator` when it needs a live account, a physical device, production
   data, a payment, a sitting or a visual or user-flow judgement;
   `post-ship` when it is measurable only after golive, a release, a deploy
   or a window of real usage. For an `agent` requirement that names a tool,
   login, secret or runner, run that probe now (`command -v <tool>`,
   `gcloud auth print-access-token`, a `*_API_KEY` in an env file, a
   compositor through `$WAYLAND_DISPLAY`) and when it fails downgrade the
   requirement to `operator`, recording the probe's command and output as a
   decision bullet. Confirm the owners as a table in one decision question,
   header `Owners`, options `As proposed` and `I'll type it`; in auto mode
   apply the rule with no question and record each owner as an `Auto:`
   decision. Run `forge commit
   <track>/<feature> spec`. Once that succeeds, run Research steps 1-2 at
   once: list the factual questions and spawn one `forge-researcher` per
   question in one message, in the background, as Research step 2 gives.
   Then go on to step 5's UI check without waiting for them.
5. Decide yourself from `F/spec.json` and `F/requirements.json` whether
   the feature changes a user interface. UI: run Design, then Mockups, with
   the operator while the researchers work in the background. Otherwise wait
   for every researcher to return. Either way, Split starts only once every
   researcher has returned, `F/research.json` is merged (Research step 3)
   and committed with `forge commit <track>/<feature> research` (Research
   step 4), and every mockup in `F/design.json` is approved; run Research
   steps 3-4, then Split.
   In auto mode a UI feature runs Design and Mockups with the operator too,
   beside the background researchers, then Research steps 3-4 and Split
   unattended.

## Design
In a discuss, the researchers Discuss step 4 spawned work in the background
while Design and Mockups run.
1. Run `/impeccable shape` with the root `PRODUCT.md` and `DESIGN.md` of each
   repo the feature touches as context. When the optional Impeccable plugin
   is not installed, so `/impeccable` is not an available skill, ask for the
   brief yourself through `AskUserQuestion` instead. In auto mode every interview
   question goes through `AskUserQuestion`, never plain text, so the
   background session shows Needs input.
2. Write `F/design.json`: `brief` holds the confirmed brief, one point per
   string; `mockups` holds one entry per surface, `{"surface": <slug>,
   "path": "mockups/<surface>.html", "approved": false, "notes": []}`. Run
   `forge commit <track>/<feature> design`.

## Mockups
1. For each unapproved surface whose mockup is missing or that Reopen names,
   write `F/mockups/<surface>.html` yourself: one self-contained HTML page
   from the `F/design.json` brief and that surface's `notes`, plus the root
   `PRODUCT.md` and `DESIGN.md` of the repo the surface belongs to. Put
   every style and script inline, with no relative script `src` or
   stylesheet link.
2. Serve `F/mockups` over http, since JBC opens only http and https, on
   unit `U` = `forge-mockup-<track>-<feature>` and the port `P` this prints:
   ```
   unit=forge-mockup-<track>-<feature>
   port=$((8700 + $(printf %s <track>-<feature> | cksum | cut -d' ' -f1) % 1000))
   systemctl --user stop "$unit" 2>/dev/null || true
   [ -z "$(ss -Hltn "sport = :$port")" ] || { echo "port $port in use"; exit 1; }
   systemd-run --user --unit="$unit" --collect --quiet \
     -- python3 -m http.server "$port" --bind 127.0.0.1 \
     --directory "<F>/mockups"
   timeout 10 bash -c "until curl -fs --max-time 2 -o /dev/null http://127.0.0.1:$port/; do sleep 0.2; done"
   echo "$port"
   ```
   On a non-zero exit, report the output and `journalctl --user -u U`, and
   stop; in auto mode end with `result: Discuss <track>/<feature> waits for
   an interactive discuss: mockup server`. Then run `forge-browser start --headed`. It may wait while another
   session owns the browser, printing `browser in use by <owner>`. When it
   fails, including when it gives up waiting, or this session has no `jbc`
   tools, show the operator its message
   and skip the browser: the operator opens the mockup URLs themselves.
3. For each unapproved surface, open `http://127.0.0.1:P/<surface>.html`
   with the `jbc` tools and ask `Approve` or `Revise` through
   `AskUserQuestion`, in auto mode too (the operator types the notes in
   Other). Revise: append the notes to that entry's `notes`, fold
   what they change into `brief`, rewrite its page as in step 1, keeping
   what already works, then reopen and ask again. Approve: set `approved: true`.
   After each Approve or Revise answer and before the next mockup opens,
   ask any researcher `blocked:` reply that arrived meanwhile (Research
   step 2).
4. Once every mockup is approved, run `systemctl --user stop U 2>/dev/null
   || true`, `forge-browser stop` only when this session's
   `forge-browser start --headed` succeeded, and
   `forge commit <track>/<feature> design`. After a failed start, never run
   `forge-browser stop`: the browser is then another session's or already
   stopped, and `stop` would stop it under that session.

## Research
1. List the factual questions whose answers change the spec or the split.
   Zero is fine.
2. Spawn one `forge-researcher` per question in one message, in the
   background, description `discuss <feature> R<k> forge-researcher`. Each
   prompt gives the question, the output path `F/research/R<k>.json`,
   `F/spec.json`, `F/requirements.json` and the doc paths. Researcher
   notifications that arrive while an `AskUserQuestion` is open are held
   until it returns. A researcher's `blocked: <decision>` reply is asked
   through `AskUserQuestion`, during Mockups only between mockup rounds,
   right after the current Approve or Revise answer and before the next
   mockup opens, never while a mockup's Approve or Revise question is open;
   its answer is recorded as a decision in `F/spec.json` and that
   researcher is respawned.
3. Once every researcher has returned, merge: `jq -s '{questions:
   map(.questions[])}' F/research/*.json > F/research.json`, or write
   `{"questions": []}` when there were none.
4. Once every mockup is approved, bring findings that change a decision to
   the operator and update `F/spec.json`; in auto mode record each as an
   `Auto:` bullet instead of asking. A finding that changes a UI surface
   folds into `F/design.json` `brief`, sets that surface's `approved:
   false` and reruns Mockups for it before the research commit. Run
   `forge commit <track>/<feature> research`.

## Split
1. Spawn `forge-splitter`, description `discuss <feature> split forge-splitter`, with `F`, the
   doc paths and the output path `F/split.json`. A reply
   `blocked: <decision>` becomes an operator question and a decision in
   `F/spec.json`; then spawn it again.
2. Print the phases as a table (slug, goal, depends, requirements, files
   from each phase's `Files: ` spec bullet) in the session text and
   continue to step 3 with no question.
3. Run `forge alloc <track>/<feature>`, then `forge commit <track>/<feature> split`.
   When alloc refuses because the slug is open in another track, ask for a
   new feature name with `AskUserQuestion`, move `F` inside S to the `F`
   line of `forge paths <track>/<new>`, rename it in the
   track's `features` and in any `depends` naming it, run
   `forge commit <track>/<new> "rename from <old>"` and
   `forge commit <track>/<old> "rename to <new>"`, then alloc again.
   In auto mode rename nothing and end with `result: Discuss
   <track>/<feature> waits for an interactive discuss: slug open in another
   track`.
   Outside Reopen, run Finish.

## Reopen
Runs after the operator's test showed the spec itself is wrong or a phase
blocked on it.
1. Read `F/verify.json` when it exists, each blocked phase's `result.json`,
   `F/spec.json`, `F/split.json` and `P/spec.json` of each phase in the
   split, P being the `P` line of `forge paths <N>`.
2. Ask freeform what the test showed, or give each blocked result's
   `summary`, then question until the amendment is settled.
3. Propose and confirm focus tags again as in Discuss step 3, including its
   targets and PII questions, when the amendment rewords or adds
   requirements, when it changes a target or PII field without changing any
   requirement text, or when the confirmed focus holds `scaling` and
   `F/spec.json` is missing `targets`, or holds `pii` and it is missing
   `pii_fields`.
4. Amend `F/spec.json` in place, with `focus` set to the tags step 3
   confirmed when it ran, omitted when none, `targets` set to the numeric targets step 3 confirmed when it
   ran and the focus holds `scaling`, `pii_fields` set to
   the field names step 3 confirmed when it ran and the focus holds `pii`,
   and add the decision `Amended <YYYY-MM-DD>: <what changed and why>`.
   When step 3 dropped a tag, remove it from the `focus` of each phase in
   `F/split.json` and of each phase's `P/spec.json` (P from `forge paths
   <N>`) in the split, omitting `focus` when none remain, since `forge commit`
   refuses a phase focus tag missing from `F/spec.json`; drop `targets` from `F/spec.json` when
   `scaling` does not remain, and `pii_fields` when `pii` does not remain.
   Run `forge commit <track>/<feature> "amend spec"`.
5. When the amendment changes a UI surface: with no `F/design.json`, run
   Design; otherwise fold the amendment into its `brief` and set `approved:
   false` on the entries of the surfaces it touches, adding one per new
   surface and removing the entry and `F/mockups/<surface>.html` of each
   surface it drops. Then run Mockups for those surfaces.
6. Run Research for the new questions only, numbering after the last `R<k>`.
7. Run Split; the spawn prompt names the amendment, and the splitter
   keeps the existing phases and numbers and changes only what it requires.
8. Split's `forge alloc` numbers new phases and prints `replan <dir>` for
   each changed phase it reset. Once it succeeds, delete `F/verify.json`
   when it exists, so the feature's status falls back to split, and run
   `forge commit <track>/<feature> reopen`, which prints
   `forge: recorded <track>/<feature> reopen` and commits nothing. Run Finish.

## Finish
End the discuss with these plain-text lines, never inside a code fence,
with the `result:` line last and nothing after it, since the background-job
classifier detects completion only from a bare `result:` line and reads a
command after it as work still running. `<root>` is the project root's
absolute path. `<phases>` lists each numbered phase as `<N>-<slug>`; after
a Reopen it reads `new <phases>; replanned <phases>`, naming only the
phases Split's `forge alloc` numbered or reset, `none` for an empty list.

Your next step: `cd <root> && forge implement <track>/<feature>`

result: Discussed <track>/<feature>: <phases>

After a Reopen, add one line `Then: cd <root> && forge resume <N>` before
the `result:` line for each phase whose `result.json` still has `status`
`blocked`.

An auto discuss that stops early ends with its one `result:` line, plain
text, last, with nothing after it, in the form its step gives:

result: Discuss <track>/<feature> waits for an interactive discuss: <what>
