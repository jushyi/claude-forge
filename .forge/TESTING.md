# Testing

## Commands
- All tests: `tests/forge.test.sh`
- Test: `t={test}; s=${t%%:*}; "tests/$s.test.sh" "${t:${#s}+1}"`
- Changed tests: `tests/changed.sh {files}`
- Failed tests: `awk '$1=="FAIL"{print $2, "tests/"$2".test.sh"}' {log}`
- A test id is a suite such as `forge-gates` or `forge/perf`, or `<suite>:<case>`, which runs only that case. An unknown case fails `no case <case>`, and a bare suite runs every case.
- Suites live in `tests/<script>.test.sh` and `tests/forge/<cmd>.test.sh`, with fixtures under `tests/fixtures/<script>/`. They need jq, `check-jsonschema` and python3 with PyYAML.
- `tests/changed.sh` maps each changed path to the suites covering it and selects every suite for a path it does not know.
- CI full suite: `ubuntu`
- The forge-gates lint cases `lint-ci` and `ci-docs` cover the CI full suite line.
- `tests/forge-watchdog.test.sh` covers `forge watchdog`, its stall pass and the gone-session pass that restarts a phase with forge resume.
- `tests/skills.test.sh`'s `phase-no-ask` case pins that `skills/forge-phase` never asks the operator, and `tests/agents.test.sh`'s `implementer-test-first` case that `forge-implementer` writes each task's test itself under the test-first rule.
- `tests/skills.test.sh`'s `verify-sheet` case pins the verify sheet's line forms, its question options and the handshakes it replaces.
- Tests run with `XDG_STATE_HOME=$tmp/state`, which `tests/forge-common.sh` sets and each standalone suite that runs `bin/forge` exports, so the state dir S of a test project lives under the test's temp dir.
- The fixture is split into `tests/fixtures/forge/project`, the repo part, and `tests/fixtures/forge/state`, the S part, and `forge-common.sh`'s `project <dest>` helper seeds both.

## Gates
- Manual test with the operator at verify.
