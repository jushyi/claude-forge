A `W` with no open gap left ends its rounds. After round 2 of step 4's
per-file rounds or of step 6's run, a still-failing smoke, changed or
stack run is a gap tagged as step 3's stage tags a failure, a
still-failing agent-run step or deferred check is a gap as
step 6 tags it, a deferred check tagged as step 7 tags a failed deferred
step, and every review
finding still open becomes a gap or a deferred todo by step 7's rules,
tagged as step 7 tags gaps. Each stack rerun sets `passed` of its repo's
`stack_tests` entry in step 7 to its last result. Never more than 2 inline
rounds. Each gap the loop closes is written to `F/verify.json` `fixed` as
`{"phase": "N", "gap": "<what failed>", "fix": "fixes/<repo>-V<k>.json"}`, tagged
with its phase as step 7 tags gaps, `fix` naming the record of the fixer
that closed it; `gaps` keeps only open gaps.

When step 4's per-file rounds or step 6's run committed any fix, once every `W`'s rounds have ended, rerun the stack tests of step
3's merged test stage in every repo, together in the background as step
3's stage runs them, so each repo's stack is tested against every repo's
last fix; this run sets `passed` of every repo's `stack_tests` entry, and
its failure is a gap tagged as step 3's stage tags a failure. It runs
before step 5's environment for step 4's fixes and before the sheet for
step 6's run. Skip
that cross-repo rerun only when exactly one repo of the
feature has both a `- Local stack:` and a `- Stack tests:` line in its
TESTING, every fix commit of these rounds is in that repo's `W`, and that
`W`'s last `forge test --stack W` rerun, in step 4's per-file rounds or
step e, ran after its last committed fix; that
repo's `stack_tests` `passed` is then final. Otherwise, or when any of
these is unsure, run it. When step 6's run committed any fix, then,
whether or not that rerun was skipped, rerun step
5's build check, rebuilding and
restarting on a mismatch, before the sheet, so the operator tests the
fixed tree. Then rerun, as you ran it there, each agent-run
manual-test step of step 6 that had a gap, whose requirement's files
intersect the fix diffs' files, or that has no mapping, replacing its
captured output under `E/s<k>/` and its gaps with the rerun's, so
the sheet records a run of the fixed tree. A step's files are
those of the requirement IDs step 6 wrote into it: the phases of
`F/split.json` whose `requirements` hold one, with their `number` and
`repo`, and the `files` of every task in their `<P>/plan.json`, `<P>` the
`P` line of `FORGE_ROOT=R forge paths <N>`, each relative to the repo its
task's `repo` names, or to the project root when it names none. The fix
diffs' files are `git -C W diff P..HEAD --name-only` for each `W` with a
fix committed by step 6's run, P being that `W`'s pre-fix commit from step
a before its first round of step 6's run, so both rounds count; intersect
them per repo, never across
repos. A step has no mapping when it has no requirement ID, is a deferred
check mapped only to a phase, or its requirements
have no plan task files. The mapping is unsure when any fix diffs' file
is in no task's `files` of the `plan.json` of any phase of `F/split.json`
in its repo, as a fix to a helper no plan names. Also rerun each step
whose files, as you read them, call, import or read a fix diffs' file of
their repo, directly or through any chain of intermediate files, whichever
plan task names them (the step's file calls A, A uses a fix-touched helper
B, B is in another requirement's task `files`); when you cannot trace that
dependency chain or cannot rule out a dependency on a fix-touched file,
rerun the step and do not carry it. When any mapping is
missing or unsure, rerun every
manual-test step you ran in step 6 before the fixes. Every step not rerun
keeps its `E/s<k>/` output and its gaps, and step 7 records it in
`manual_test` as `[agent][carried] <E/s<k>/ paths>`; a step run on the
fixed tree keeps the plain `[agent]` tag.
