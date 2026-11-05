   A gap is a phase's work only when an implementer can act on it: it names
   a failing test, a failing command or a reproducible step. Before a gap is
   recorded, triage it: a deferred check whose reason is a denied command, a
   device, a live account or another machine is an `[owed]` or `[operator]`
   step, never a gap; a criterion a phase has already recorded `unmet` twice
   as unattainable is one `AskUserQuestion` with the options `Relax it`,
   `Drop it` and `Retry phase <N>`, and only the last answer makes a gap; a
   review-only finding goes to Inline fixes, never to a phase retry; a step
   verify itself skipped or could not run (a review that did not run, a
   build-commit note) is a gap of verify, never charged to a phase.
   Only P0/P1 findings and failed steps or criteria become gaps; P2 and P3 findings
   are deferred todos, never gaps. A finding with a non-empty `dismissed`,
   including `settled: <operator's words>`, never becomes a gap. Each gap names the
   phase whose goal or plan it falls
   in (`{"phase": "N", "gap": "<what failed>"}`). A gap's `gap` text
   starts with the exact prefix `Replan: ` (capital R, colon, one space)
   only when the gap says an existing planned task's approach must be
   replaced, not added to. A `Replan: ` gap makes `forge next` run the
   full replan for that gap's phase. Every other gap, `needs plan: `
   results included, is additive and carries no prefix. A failed deferred step,
   or a requirement step failing on the deferred check folded into it, is
   a gap tagged with the phase N its `(deferred by phase N: <reason>)` text
   names, with no pick; when that text names several phases, with the one
   whose plan names the failing files, else the first it names. An
   `[owed]` step never becomes a gap. When a gap fits no phase or
   several, tag it yourself with the phase of `F/split.json` whose goal and
   plan files it touches most, the later phase on a tie, and log
   `forge event N gap-tag "<N> for <gap>"` in that phase; never ask the
   operator.
