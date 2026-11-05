# Testing

<!-- test layout, commands, markers, which tests enforce which rules -->

Tests that bind ports add `FORGE_PORT_OFFSET` to their base port and tests that create databases use the name in `FORGE_TEST_DB`; when they are unset, the offset is 0 and the default DB is used.

Test commands pass `$FORGE_TEST_CPUS`, the runner's job count, to their runner's worker cap, such as vitest `--maxWorkers`, turbo `--concurrency`, `ctest -j` and `make` or cmake `-j`. `forge test` sets it to 2 for `--one` and `--repeat` runs and to max(2, floor(nproc / 4)) for full and changed runs, capped at `nproc`. A repo whose runner can use more workers without overrunning its `- Memory:` budget raises that job count, or lowers it, with `` - CPUs one: `<n>` `` or `` - CPUs all: `<n>` `` under Commands, `<n>` a whole number of at least 2, which sets it to min(nproc, `<n>`) for `--one` and `--repeat` runs or for full and changed runs.

Test list files that every phase only appends to, such as the test registrations in `tests/CMakeLists.txt`, are marked `merge=union` in `.gitattributes`, so phases that each add a line run at once instead of waiting on each other in `forge check`, and git keeps both sides' added lines on merge; mark only files whose lines are only ever added and whose order does not matter.

## Commands

A phase runs one test (`Test`) or the tests covering its changed files (`Changed tests`) and ship runs `All tests` once; forge fills `{test}` with a test id and `{files}` with the changed paths, and a missing line falls back to the next wider one.
Every tier first runs `Setup`, the dependency install, when the command or a tracked or untracked manifest or lockfile changed since it last passed in that worktree.

- Setup: `<command installing dependencies>`
- All tests: `<command>`
- Test: `<command running {test}>`
- Changed tests: `<command running the tests covering {files}>`
- Failed tests: `<command printing one id and file per failing test in {log}>`

The `Failed tests` line is optional and needs a `Test` line. Its command, run from the repo top with `{log}` filled with the failed run's log, prints one `<id> <file>` pair per failing test, where `Test` accepts `<id>` as `{test}` and `<file>` is the test's source path from the repo root. After a failed `--changed` run on the real changed tier, forge reruns up to 10 listed ids on the merge base through `Test`; an id whose file is missing at the merge base or changed by the branch counts as a new failure, and a run whose every failure also fails on base passes with a concern opened per test. Add the line only when the changed tier runs every selected test to completion, with no fail-fast and no `&&` chain, because a runner that stops early can hide a new failure. Suite- or file-level ids let a failure already present on base hide a new failure in the same suite or file, and forge accepts that granularity.

A repo with no tests writes `- All tests: none` (no backticks) instead of a command; `forge test` then exits 5 and land and verify go on untested. Without a `- All tests:` line `forge test` exits 6 and land and verify refuse until a command or `none` is added; a test command's own exit 5 counts as a failure.

A repo whose PR CI runs the full suite may add `` - CI full suite: `<check name>` `` here, `<check name>` being the GitHub Actions or Forgejo Actions job name that `forge pr checks` prints (a job's `name:`, or its id when it has none), so ship's step 7 takes that check's pass on the PR head in place of the local `All tests` run and golive's land reuses it; only a GitHub Actions check run with conclusion success or a Forgejo Actions task with status success counts, a commit status never does, and the name must match a job of `.github/workflows` or `.forgejo/workflows`. A repo without such CI, or whose workflows run on no `pull_request`, declares none.

A repo whose PR checks need labels may add `` - PR labels: `<command>` `` here. `forge pr create` runs the command with bash from the repo top, stdin closed, and passes each non-empty line it prints as one `--label` to `gh pr create`; a nonzero exit fails the create before any pull request is opened. A Forgejo origin runs nothing and creates without labels. A repo without labels to add declares none.

An app that keeps usage logs may add `` - Perf log: `<command>` `` here. The weekly `forge perf pull` runs the command with `FORGE_PERF_WINDOW`, a number of days defaulting to 7, in the environment; the command prints one JSON line `{"metric", "value", "unit", "kind", "at"}` per sample, `at` an ISO-8601 time, read from the app's own usage logs for the last `FORGE_PERF_WINDOW` days. A repo without usage logs declares none.

A repo whose PR CI runs checks the changed tests do not, such as lint or a build, may add `` - Pre-push: `<command>` `` here. `forge pr push`, which the skills use for every pull request branch push, runs the command with bash from the repo top, stdin closed, before `git push`; a nonzero exit exits 3 and pushes nothing, and the skills send the failure to fixers as for a failed test. A repo without such checks declares none.

## Gates
