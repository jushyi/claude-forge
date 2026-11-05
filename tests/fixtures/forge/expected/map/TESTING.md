# Testing

<!-- test layout, commands, markers, which tests enforce which rules -->

Tests that bind ports add `FORGE_PORT_OFFSET` to their base port and tests that create databases use the name in `FORGE_TEST_DB`; when they are unset, the offset is 0 and the default DB is used.

Test commands pass `$FORGE_TEST_CPUS`, the runner's job count, to their runner's worker cap, such as vitest `--maxWorkers`, turbo `--concurrency`, `ctest -j` and `make` or cmake `-j`. `forge test` sets it to 2 for `--one` and `--repeat` runs and to max(2, floor(nproc / 4)) for full and changed runs, capped at `nproc`. A repo whose runner can use more workers without overrunning its `- Memory:` budget raises that job count, or lowers it, with `` - CPUs one: `<n>` `` or `` - CPUs all: `<n>` `` under Commands, `<n>` a whole number of at least 2, which sets it to min(nproc, `<n>`) for `--one` and `--repeat` runs or for full and changed runs.

Test list files that every phase only appends to, such as the test registrations in `tests/CMakeLists.txt`, are marked `merge=union` in `.gitattributes`, so phases that each add a line run at once instead of waiting on each other in `forge check`, and git keeps both sides' added lines on merge; mark only files whose lines are only ever added and whose order does not matter.

## Commands

- `npm test`
