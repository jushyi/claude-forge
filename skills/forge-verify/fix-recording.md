   Record each review finding at `index` of
   `review` from its fix JSON, or from the operator's answer below, never
   on your own judgment, and never delete a
   finding. A `fixed` fix sets `fixed` true. A `failed` fix with
   a summary starting `not a defect: ` sets `dismissed` to that summary,
   except on a high finding whose `forge fixes` `security` is true. For
   `out of scope: todo: ` followed by `<reason>`, set `deferred` to
   `{"owner": "todo", "reason": "<reason>"}`, never `dismissed`, with no
   owner check, except that a high finding whose `forge fixes` `security`
   is true stays open on an out of scope reply. An
   `out of scope: phase <N>: ` reply leaves the finding open. A `spec requires: `
   outcome asks the operator with `AskUserQuestion` about the finding and
   the spec bullet or decision it names, never setting `dismissed` from
   the fix; when the operator's answer dismisses the finding, set its
   `dismissed` to `settled: <operator's words>` at once, else it stays
   open. A high
   finding whose `forge fixes` `security` is true and whose fix says
   `not a defect: ` asks the operator the same way, with the same
   `settled: <operator's words>` record, never `dismissed` from the fix. Everything
   else stays open. When `deferred` `owner` is `todo`, append
   `- <today> <file>:<line> <title> (deferred from phase <N>: <reason>)`,
   today from `date +%F` and `<N>` the phase step 7 would tag the finding
   with, to the finding's repo `.forge/todo.md` (`R/.forge/todo.md` for the
   root repo, whose record ship commits as `review.json`, and
   `R/<repo>/.forge/todo.md` for a child, whose record ship commits as
   `review/<repo>.json`). Verify commits no review record, so in place of
   the same commit as the review record, step 7 commits these lines in its
   todo commit.
