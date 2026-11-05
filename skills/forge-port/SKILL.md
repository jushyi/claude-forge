---
name: forge-port
description: Run an explicit /forge-port request - port one component to a new language or stack as a pure port, judged by replaying recorded requests against the old implementation's answers with forge replay until zero mismatches, on forge/port-<slug> worktrees, then review and merge.
argument-hint: '<component> to <target>'
disable-model-invocation: true
---

# forge-port

You port one component end to end in one interactive session: the
operator designs the port and owns the judge, agents write the new code,
and `forge replay` decides when it matches the old one. The current
directory is the project root `R`, the directory holding `.forge/`.

Arguments: `$ARGUMENTS` — the component and its target, such as
`the receipts service to Rust`. A blank argument stops with the line
`usage: /forge-port <component> to <target>`.

## Rules
- Every question to the operator goes through `AskUserQuestion`, never
  plain text, preceded by `forge notify` and `PushNotification` exactly as
  `forge-quick`'s Rules bullet says, with the session title
  `<project> port <component>`.
- Wait for spawned agents and background commands by ending the turn; each
  completion resumes you. Never `ScheduleWakeup`, `CronCreate` or a `sleep`
  poll. No `EnterWorktree`, no background session.
- The global `forge-guard` hook rules, test rules and commit rules of
  `forge-quick` apply unchanged, with `quick` read as `port` in every path,
  branch and description.
- Pure port. The new code reproduces the old behavior, its bugs included,
  and adds nothing: no feature, fix, cleanup or new dependency the plan
  does not name. A known old bug stays and becomes a `.forge/todo.md` line
  for its own later change. Every agent prompt says so.
- The old code is never edited. Before each judge run,
  `git -C W diff --stat main -- <old paths>` prints nothing; otherwise the
  round fails and the edit is reverted by a fixer.
- `J` is `STATE/port/<slug>/`, `STATE` being the `STATE` line of
  `forge paths` run in R: the
  judge, kept after the run for the next change and never committed, since
  recorded requests can hold user data. No agent gets `J`'s path or reads
  under it; `forge-guard` denies any agent write there and any agent
  `forge replay` (`port-judge`).
  Agents see only the `J/report.jsonl` lines you hand them, never a line
  of `J/holdout.jsonl` nor a request, answer or class from `J/holdout/`.
  `S/spec.json` and every agent prompt name the request source by what it
  is, never its path, since an agent that reads the source reads the
  holdout.
- Only the operator changes the judge. You run `forge replay lock` only
  right after an `AskUserQuestion` round that approved the change it locks.
  A rule (`ignore <path>` or `normalize keys|numbers|space`) is added only
  with the operator's approval and reason, never to clear a mismatch of
  the port. A `forge replay run` exit 3 stops the round and goes to the
  operator.
- `S` is `R/.forge/port/<slug>/`: untracked scratch, never committed.
  Remove `S` when the run ends, done or stopped; `J` stays.
- A repo's `W` is `<repo>/.claude/worktrees/port-<slug>` on
  `forge/port-<slug>`.

## Budgets
Planner: 2 attempts. Implementer: 2 attempts per task. Judge: 5 rounds.
Review fix: 2 fixer rounds. When one runs out, `AskUserQuestion` offers
retry, with the operator's text added to the spawn prompt, or stop. Stop
removes `S`, keeps `J`, every branch and worktree, and reports them.

## Steps
1. Spec. Derive a short kebab-case slug, made unique as `forge-quick`'s
   step 1 does against `forge/port-<slug>`, `R/.forge/port/<slug>/` and
   `J`. Read the old component and find its front door: the one boundary
   where a request goes in and an answer comes out (an HTTP route, a CLI,
   a function). A component with no single front door stops the run with
   the doors found and a suggestion to port them one at a time. Write
   `S/spec.json` (feature-spec): `spec` holds the task, the old paths, the
   front door and the target; `decisions` is empty.
2. Design, the operator's step. First list what the judge cannot judge,
   as `forge replay --help` names it: state the answer reads (a database,
   a cache, a file, earlier requests), the clock, randomness and outbound
   calls. A component whose answers depend on state that cannot be
   recorded and restored per request stops the run with that state named.
   Draft and settle in one `AskUserQuestion` round, one decision per
   question, each with a recommendation:
   - old command: reads one request on stdin, prints the old answer;
   - new command: the same contract, run from `W`;
   - dependencies: every outbound call, write or charge, each replayed
     from a recording (vcrpy, WireMock or a recorded stub) by both
     commands, so replaying never touches the outside world;
   - time and randomness: each frozen in both commands (`faketime -f
     '<date>'` from libfaketime with a fixed `TZ`, a seeded generator) or,
     when it cannot be frozen, its fields left to step 3's noise rules;
   - requests: where they come from, real traffic first (a log, a capture,
     the operator's file), generated cases only to cover named traps, how
     many, and the share held out (recommend 20%);
   - thresholds: the least line coverage of the old paths and the least
     mutation score the requests must reach (recommend 90% and 80%);
   - cutover gate: the least live shadow time and clean requests before
     the new code takes all traffic (recommend 168 hours and 10,000);
   - where the new code lives and which old paths it replaces.
   A dependency with no recording and a clock or generator neither frozen
   nor confined to ignorable fields stops the run. Append each answer to
   `decisions` in `S/spec.json`.
3. Judge. Write each request to `J/requests/<id>`, move the held-out
   share, picked with `shuf`, to `J/holdout/<id>`, and run
   `forge replay record J <old command>`.
   - Noise: record runs the old command twice and prints one
     `noise <path> <count> <first id>` line per path where the two runs
     disagree. Offer each line in one `AskUserQuestion` round as a rule
     with a drafted reason (`ignore <path>`, or `normalize keys` for
     `order` and `normalize space` for `space`), or drop the requests it
     names when the old code answers them differently from run to run; a `body` line stops the
     run, since a non-JSON answer that changes is a clock or generator
     step 2 missed. Add `normalize numbers` only when the operator names a
     number format both sides may differ in. Write the approved lines to
     `J/rules` and step 2's gate to `J/cutover` as `<hours> <requests>`,
     then `forge replay lock J` and
     `forge replay run J <old command>`, which must print `mismatches=0`
     and `holdout_mismatches=0`; otherwise rerun the round with the
     report's classes. Keep the rules short: an ignored path is a path
     nobody checks.
   - Adequacy: copy the old component into `S/mutant/` and measure the
     requests against it with the judge as the only test, each tool under
     the interpreter the old command runs (such as
     `uvx --python <that python>`), since another one can change the old
     answers. Coverage: coverage.py (`coverage run -p --branch --source <old paths>`) for
     Python or llvm-cov for Rust and C, the old command wrapped in it
     under `forge replay run J`. Mutation score: mutmut 2
     (`uvx --from 'mutmut<3' mutmut run --paths-to-mutate <copied paths>
     --runner 'forge replay run J <old command on the copy>'`) for Python
     or cargo-mutants with a test that runs `forge replay run J` for
     Rust; the score is killed over killed plus survived. Another
     language needs the operator to name its tools, or stops. Below
     either threshold, list the uncovered lines and surviving mutants in
     one `AskUserQuestion` round: more requests (written, recorded,
     approved and relocked as above, then measured again) or stop.
4. Worktrees. As `forge-quick` step 6, for each repo the new code touches.
5. Plan and port. `forge-quick` steps 4, 5 and 7, the planner and each
   implementer given `S/spec.json`, the pure-port rule and the doc paths;
   each task's recorded command passes in `W`.
6. Judge rounds. Run `forge replay run J <new command>` in the background.
   `mismatches=0 ... holdout_mismatches=0`: go to step 8. Mismatches on
   `J/requests/`: take the report's classes, largest first, and spawn in
   one message one `forge-fixer` per class with up to 3 of that class's
   `J/report.jsonl` lines (request, want, got, repro) as the failed
   command and its output, each request copied to `S/fixtures/<id>` and
   its repro rewritten to read it there, so no prompt holds `J`'s path, `S/spec.json`, the TESTING doc and `W`. The
   fixer adds a test built from those requests, then fixes the port.
   Commit each fix in `W`. A `failed` reply starting `needs plan: ` is a
   departure, kept for step 7; any other `failed` reply stays in the next
   round. Run the next round. Mismatches on the holdout alone mean the
   fixes fit the visible requests only: ask the operator in one
   `AskUserQuestion` round, giving the `J/holdout.jsonl` path, to move
   those requests into `J/requests/`, refill the holdout with new
   recorded requests and relock, or to stop.
7. Departures. When a fixer or implementer reports one (a file or
   dependency the plan does not name, a behavior it cannot match), list
   them in one `AskUserQuestion` round: approve, or reject with the
   operator's text sent back to a fixer. Append each ruling to
   `decisions`, then return to step 6.
8. Ship. `forge-quick` steps 8, 9 and 11 to 14 (review, fix, concerns,
   sync, merge, clean), with `forge-port` in place of `forge-quick` and a
   final `forge replay run J <new command>` after each fix round, which
   must still print `mismatches=0` and `holdout_mismatches=0`. The PR body
   holds the judge's last summary line, the coverage and mutation score,
   the rules with their reasons, each approved
   departure and each preserved old bug.
9. Final message: the golive lines, the judge's last summary line, `J`'s
   path, the preserved bugs written to `.forge/todo.md`, then the
   operator's cutover: mirror live traffic to the new code with side
   effects cut off, logging each request with both answers; feed that
   log to `forge shadow <slug> <feed>` (`forge shadow --help` gives the
   line form) until `forge cutover <slug>` says go; move traffic over in
   steps with the old code still running; name an owner; and rerun
   `forge replay run J` on the next change. End with the line
   `result: Port <slug>: <each PR URL or landed sha>` and nothing after it.
