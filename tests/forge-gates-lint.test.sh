#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/forge-common.sh"
suite=forge-gates-lint
. "$(dirname "$0")/forge-gates-common.sh"

if want help; then
for c in test fixes; do
  grep -qE "^  $c( |$)" "$tmp/forge-help" || fail "forge --help lists $c"
  "$forge" "$c" --help >"$tmp/out" && [ "$(head -1 "$tmp/out" | cut -d' ' -f1-3)" = "Usage: forge $c" ] || fail "forge $c --help prints its usage"
done
ok help
fi

if want lint; then
lintdoc valid '- All tests: `for t in tests/*.test.sh; do "$t" || exit 1; done`.' '- Test: `pytest -x {test}` for one test.' '- Changed tests: `tests/changed.sh {files}`.' '- Setup: `npm ci`.'
[ "$(code lint "$lr/valid")" = 0 ] || fail "lint passes valid command lines: $(cat "$tmp/out")"
lintdoc quoted '- Test: `pytest "{test}"`.' '- Changed tests: `run --files "{files}"`.'
[ "$(code lint "$lr/quoted")" = 0 ] || fail "lint passes placeholders inside quotes: $(cat "$tmp/out")"
tfl='- Failed tests: `<command printing one id and file per failing test in {log}>`'
lintdoc template '- Setup: `<command installing dependencies>`' '- All tests: `<command>`' '- Test: `<command running {test}>`' '- Changed tests: `<command running the tests covering {files}>`' "$tfl"
[ "$(code lint "$lr/template")" = 0 ] || fail "lint skips template placeholder commands: $(cat "$tmp/out")"
grep -qxF -- "$tfl" "$root/templates/TESTING.md" || fail "the TESTING template shows the Failed tests placeholder line"
[ "$(grep -n -m1 -- '^- Failed tests: ' "$root/templates/TESTING.md" | cut -d: -f1)" -gt "$(grep -n -m1 -- '^- Changed tests: ' "$root/templates/TESTING.md" | cut -d: -f1)" ] || fail "the Failed tests placeholder follows Changed tests"
grep -v -- '^- ' "$root/templates/TESTING.md" | grep -qF 'up to 10' || fail "the TESTING template prose names the 10-id cap"
grep -v -- '^- ' "$root/templates/TESTING.md" | grep -qF 'fail-fast' || fail "the TESTING template prose names the fail-fast condition"
lintdoc notest '- All tests: `pytest`.' '- Test: `pytest -x` for one test.'
[ "$(code lint "$lr/notest")" != 0 ] || fail "lint fails a Test line without {test}: $(cat "$tmp/out")"
grep -qF "$lr/notest/.forge/TESTING.md" "$tmp/out" && grep -qF "{test}" "$tmp/out" && names_line 5 "pytest -x" ||
  fail "a Test line without {test} names the file, line and missing placeholder: $(cat "$tmp/out")"
lintdoc nofiles '- All tests: `pytest`.' '- Changed tests: `tests/changed.sh` over changed paths.'
[ "$(code lint "$lr/nofiles")" != 0 ] || fail "lint fails a Changed tests line without {files}: $(cat "$tmp/out")"
grep -qF "$lr/nofiles/.forge/TESTING.md" "$tmp/out" && grep -qF "{files}" "$tmp/out" && names_line 5 "tests/changed.sh" ||
  fail "a Changed tests line without {files} names the file, line and missing placeholder: $(cat "$tmp/out")"
lintdoc quote '- All tests: `echo "unclosed`.'
[ "$(code lint "$lr/quote")" != 0 ] || fail "lint fails an unbalanced quote: $(cat "$tmp/out")"
grep -qF "$lr/quote/.forge/TESTING.md" "$tmp/out" && grep -qF 'unexpected EOF' "$tmp/out" && names_line 4 'echo "unclosed' ||
  fail "an unbalanced quote names the file, line and bash -n error: $(cat "$tmp/out")"
lintdoc tick '- Changed tests: `run $(printf %s `echo {files}`)`.'
[ "$(code lint "$lr/tick")" != 0 ] || fail "lint fails a command cut short by an unbalanced backtick: $(cat "$tmp/out")"
grep -qF "$lr/tick/.forge/TESTING.md" "$tmp/out" && grep -qF 'unexpected EOF' "$tmp/out" && names_line 4 'run $(printf %s' ||
  fail "an unbalanced backtick names the file, line and bash -n error: $(cat "$tmp/out")"
lintdoc open '- All tests: `pytest`.' '- Test: `pytest {test}'
[ "$(code lint "$lr/open")" != 0 ] || fail "lint fails a command line without a closed backtick span: $(cat "$tmp/out")"
grep -qF "$lr/open/.forge/TESTING.md" "$tmp/out" && grep -qF 'no backticked command' "$tmp/out" && names_line 5 '- Test: `pytest {test}' ||
  fail "a command line without a closed backtick span names the file, line and reason: $(cat "$tmp/out")"
lintdoc many '- All tests: `echo "a`.' '- Test: `pytest`.' '- Changed tests: `pytest`.' '- Setup: `npm ci (`.'
[ "$(code lint "$lr/many")" != 0 ] || fail "lint fails a doc with four bad lines: $(cat "$tmp/out")"
grep -qF "{test}" "$tmp/out" && grep -qF "{files}" "$tmp/out" && [ "$(grep -c 'unexpected\|syntax error' "$tmp/out")" -ge 2 ] && names_line 4 'echo "a' && names_line 7 'npm ci (' ||
  fail "lint prints every failure before returning: $(cat "$tmp/out")"
lintdoc missing '- All tests: `pytest`.'
[ "$(code lint "$lr/missing")" = 0 ] || fail "lint passes missing optional lines: $(cat "$tmp/out")"
for v in 4G 512M; do
  lintdoc memok '- All tests: `pytest`.' "- Memory: \`$v\` per run."
  [ "$(code lint "$lr/memok")" = 0 ] || fail "lint passes a Memory line of $v: $(cat "$tmp/out")"
done
for v in 4GB 4.5G '' 0G 9000000000000G; do
  lintdoc membad '- All tests: `pytest`.' "- Memory: \`$v\` per run."
  [ "$(code lint "$lr/membad")" != 0 ] || fail "lint fails a Memory line of '$v': $(cat "$tmp/out")"
  grep -qF "$lr/membad/.forge/TESTING.md" "$tmp/out" && grep -qF "Memory" "$tmp/out" && { [ -z "$v" ] || grep -qF "$v" "$tmp/out"; } ||
    fail "a Memory line of '$v' names the file, the Memory line and its value: $(cat "$tmp/out")"
done
lintdoc none 'Run the tests by hand.'
[ "$(code lint "$lr/none")" = 0 ] || fail "lint passes a doc with no command line: $(cat "$tmp/out")"
lintdoc declared '- All tests: none' '- Test: `pytest -x {test}`.'
[ "$(code lint "$lr/declared")" = 0 ] && ! grep -qF 'no backticked command' "$tmp/out" || fail "lint passes a - All tests: none declaration: $(cat "$tmp/out")"
lintdoc declaredsp '- All tests: none   '
[ "$(code lint "$lr/declaredsp")" = 0 ] || fail "lint passes a - All tests: none declaration with trailing spaces: $(cat "$tmp/out")"
mkdir -p "$lr/nodoc"
[ "$(code lint "$lr/nodoc")" = 0 ] || fail "lint passes a repo without TESTING.md: $(cat "$tmp/out")"
qd=$(date -u +%F) q3=$(date -u -d '3 days ago' +%F) q8=$(date -u -d '8 days ago' +%F)
lintdoc quar '- All tests: `pytest`.' "- Quarantine (added $qd): \`pytest -m flaky\` for the flaky tests."
[ "$(code lint "$lr/quar")" = 0 ] || fail "lint passes a dated Quarantine line with a backticked command: $(cat "$tmp/out")"
lintdoc quar3 '- All tests: `pytest`.' "- Quarantine (added $q3): \`pytest -m flaky\`."
[ "$(code lint "$lr/quar3")" = 0 ] || fail "lint passes a Quarantine line dated 3 days ago: $(cat "$tmp/out")"
lintdoc quarold '- All tests: `pytest`.' "- Quarantine (added $q8): \`pytest -m flaky\`."
[ "$(code lint "$lr/quarold")" != 0 ] || fail "lint fails a Quarantine line dated over 7 days ago: $(cat "$tmp/out")"
grep -qF "$lr/quarold/.forge/TESTING.md" "$tmp/out" && grep -qF "$q8" "$tmp/out" && grep -qw 5 "$tmp/out" ||
  fail "a Quarantine line dated over 7 days ago names the file, line number and date: $(cat "$tmp/out")"
lintdoc quarundated '- All tests: `pytest`.' '- Quarantine: `pytest -m flaky` for the flaky tests.'
[ "$(code lint "$lr/quarundated")" != 0 ] || fail "lint fails an undated Quarantine line: $(cat "$tmp/out")"
grep -qF "$lr/quarundated/.forge/TESTING.md" "$tmp/out" && grep -qw 5 "$tmp/out" && grep -qF -- '- Quarantine: `pytest -m flaky`' "$tmp/out" ||
  fail "an undated Quarantine line names the file, line number and line: $(cat "$tmp/out")"
lintdoc quarbad '- All tests: `pytest`.' '- Quarantine (added 2026-02-30): `pytest -m flaky`.'
[ "$(code lint "$lr/quarbad")" != 0 ] || fail "lint fails a Quarantine line with an invalid calendar date: $(cat "$tmp/out")"
grep -qF "$lr/quarbad/.forge/TESTING.md" "$tmp/out" && grep -qw 5 "$tmp/out" && grep -qF '2026-02-30' "$tmp/out" ||
  fail "a Quarantine line with an invalid date names the file, line number and line: $(cat "$tmp/out")"
for h in '(added)' "(on $qd)" "($qd)" "(added  $qd)"; do
  lintdoc quarhdr '- All tests: `pytest`.' "- Quarantine $h: \`pytest -m flaky\`."
  [ "$(code lint "$lr/quarhdr")" != 0 ] || fail "lint fails a Quarantine header of '$h': $(cat "$tmp/out")"
  grep -qF "$lr/quarhdr/.forge/TESTING.md" "$tmp/out" && names_line 5 "- Quarantine $h:" ||
    fail "a Quarantine header of '$h' names the file, line number and line: $(cat "$tmp/out")"
done
lintdoc quarnone '- All tests: `pytest`.' "- Quarantine (added $qd): the flaky tests."
[ "$(code lint "$lr/quarnone")" != 0 ] || fail "lint fails a dated Quarantine line without a backticked command: $(cat "$tmp/out")"
grep -qF "$lr/quarnone/.forge/TESTING.md" "$tmp/out" && grep -qF 'no backticked command' "$tmp/out" && names_line 5 "- Quarantine (added $qd): the flaky tests." ||
  fail "a dated Quarantine line without a backticked command names the file, line and reason: $(cat "$tmp/out")"
lintdoc quarsyn '- All tests: `pytest`.' "- Quarantine (added $qd): \`pytest -m \"flaky\`."
[ "$(code lint "$lr/quarsyn")" != 0 ] || fail "lint fails a dated Quarantine command with an unbalanced quote: $(cat "$tmp/out")"
grep -qF "$lr/quarsyn/.forge/TESTING.md" "$tmp/out" && grep -qF 'unexpected EOF' "$tmp/out" && names_line 5 'pytest -m "flaky' ||
  fail "an unbalanced quote in a dated Quarantine command names the file, line and bash -n error: $(cat "$tmp/out")"
lintdoc perf '- All tests: `pytest`.' '- Perf log: `pytest -m perf` for the wall-clock bounds.'
[ "$(code lint "$lr/perf")" = 0 ] || fail "lint passes a Perf log line with a backticked command: $(cat "$tmp/out")"
lintdoc perfnone '- All tests: `pytest`.' '- Perf log: the wall-clock bounds.'
[ "$(code lint "$lr/perfnone")" != 0 ] || fail "lint fails a Perf log line without a backticked command: $(cat "$tmp/out")"
grep -qF "$lr/perfnone/.forge/TESTING.md" "$tmp/out" && grep -qF 'no backticked command' "$tmp/out" && names_line 5 '- Perf log: the wall-clock bounds.' ||
  fail "a Perf log line without a backticked command names the file, line and reason: $(cat "$tmp/out")"
lintdoc ftok '- All tests: `pytest`.' "- Failed tests: \`awk '\$1==\"FAIL\"{print \$2, \"tests/\"\$2\".py\"}' {log}\` for the failing ids."
[ "$(code lint "$lr/ftok")" = 0 ] || fail "lint passes a Failed tests line with {log}: $(cat "$tmp/out")"
lintdoc ftph '- All tests: `pytest`.' '- Failed tests: `<command>`'
[ "$(code lint "$lr/ftph")" = 0 ] || fail "lint passes a Failed tests <...> placeholder without {log}: $(cat "$tmp/out")"
lintdoc ftnolog '- All tests: `pytest`.' '- Failed tests: `grep FAIL test.log` for the failing ids.'
[ "$(code lint "$lr/ftnolog")" != 0 ] || fail "lint fails a Failed tests line without {log}: $(cat "$tmp/out")"
grep -qxF "forge: $lr/ftnolog/.forge/TESTING.md: - Failed tests: \`grep FAIL test.log\`: no {log} placeholder" "$tmp/out" ||
  fail "a Failed tests line without {log} names the file, command and missing placeholder: $(cat "$tmp/out")"
lintdoc ftnone '- All tests: `pytest`.' '- Failed tests: the ids in the log.'
[ "$(code lint "$lr/ftnone")" != 0 ] || fail "lint fails a Failed tests line without a backticked command: $(cat "$tmp/out")"
grep -qF "$lr/ftnone/.forge/TESTING.md" "$tmp/out" && grep -qF 'no backticked command' "$tmp/out" && names_line 5 '- Failed tests: the ids in the log.' ||
  fail "a Failed tests line without a backticked command names the file, line and reason: $(cat "$tmp/out")"
lintdoc ftsyn '- All tests: `pytest`.' '- Failed tests: `grep FAIL {log} | awk "{print $2`.'
[ "$(code lint "$lr/ftsyn")" != 0 ] || fail "lint fails a Failed tests command with an unbalanced quote: $(cat "$tmp/out")"
grep -qF "$lr/ftsyn/.forge/TESTING.md" "$tmp/out" && grep -qF 'unexpected EOF' "$tmp/out" && grep -qF -- '- Failed tests: `grep FAIL {log}' "$tmp/out" ||
  fail "an unbalanced quote in a Failed tests command names the file, command and bash -n error: $(cat "$tmp/out")"
"$forge" check --help | tr '\n' ' ' | tr -s ' ' >"$tmp/out"
grep -qF 'Failed tests' "$tmp/out" && grep -qF '{log}' "$tmp/out" ||
  fail "forge check --help lists the Failed tests {log} lint rule: $(cat "$tmp/out")"
[ "$(code lint "$root")" = 0 ] || fail "forge's own TESTING.md lints clean: $(cat "$tmp/out")"
ftc=$(sed -n 's/^- Failed tests: `\([^`]*\)`.*/\1/p' "$root/.forge/TESTING.md")
[ -n "$ftc" ] || fail "forge's own TESTING.md has a Failed tests command"
[ "$(grep -n -m1 -- '^- Failed tests: ' "$root/.forge/TESTING.md" | cut -d: -f1)" -gt "$(grep -n -m1 -- '^- Changed tests: ' "$root/.forge/TESTING.md" | cut -d: -f1)" ] || fail "forge's own Failed tests line follows Changed tests"
printf '%s\n' 'ok forge/state (3s)' 'FAIL forge-gates (exit 1, 40s, log /x/forge-gates.log)' 'FAIL forge/budget (exit 1, 2s, log /x/forge/budget.log)' >"$tmp/ft.log"
(cd "$root" && bash -c "${ftc//\{log\}/$tmp/ft.log}") >"$tmp/out" 2>&1 || fail "forge's own Failed tests command runs: $(cat "$tmp/out")"
[ "$(cat "$tmp/out")" = $'forge-gates tests/forge-gates.test.sh\nforge/budget tests/forge/budget.test.sh' ] || fail "forge's own Failed tests command prints each failing suite id and file: $(cat "$tmp/out")"
"$forge" test --help | tr '\n' ' ' >"$tmp/out" && grep -q "forge map" "$tmp/out" && grep -q "forge check" "$tmp/out" ||
  fail "forge test --help says forge map and forge check lint the command lines"
ok lint
fi

if want lint-ci; then
cidoc() { lintdoc "$1" '- All tests: `pytest`.' "- CI full suite: $2"; }
ciwf() { mkdir -p "$lr/$1/.github/workflows"; cat >"$lr/$1/.github/workflows/$2"; }
fjwf() { mkdir -p "$lr/$1/.forgejo/workflows"; cat >"$lr/$1/.forgejo/workflows/$2"; }
cimsg() { echo "forge: $lr/$1/.forge/TESTING.md: - CI full suite: \`$2\`: no job of .github/workflows or .forgejo/workflows defines it"; }
ciflow() {
  ciwf "$1" ci.yml <<'EOF'
name: CI
on:
  pull_request:
jobs:
  build:
    name: "Full suite"
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
  tests:
    runs-on: ubuntu-latest
    steps:
      - name: Run tests
        run: make test
  matrix:
    name: test (${{ matrix.os }})
    strategy:
      matrix:
        os: [ubuntu, windows]
    runs-on: ${{ matrix.os }}-latest
    steps:
      - run: make test
EOF
}
cipass() {
  cidoc "$1" "\`$2\` runs the full suite."
  ciflow "$1"
  [ "$(code lint "$lr/$1")" = 0 ] && ! grep -qF 'CI full suite' "$tmp/out" || fail "lint passes a CI full suite of '$2' ($3): $(cat "$tmp/out")"
}
cifail() {
  cidoc "$1" "\`$2\` runs the full suite."
  ciflow "$1"
  [ "$(code lint "$lr/$1")" = 1 ] || fail "lint fails a CI full suite of '$2' ($3) with exit 1: $(cat "$tmp/out")"
  grep -qxF "$(cimsg "$1" "$2")" "$tmp/out" || fail "a CI full suite of '$2' ($3) prints the exact no-job message: $(cat "$tmp/out")"
}
cipass ciname 'Full suite' 'a job name: with quotes stripped'
cipass ciid tests 'the id of a job with no name:'
cipass cimatrix 'test (ubuntu)' 'a ${{ matrix.os }} name'
cipass cimatrix2 'test (windows)' 'a ${{ matrix.os }} name'
cifail cibuild build 'the id of a job with a name:'
cifail ciundef 'Lint' 'a name no job defines'
cifail ciwfname CI 'the workflow name:'
cifail cistep 'Run tests' 'a step name:'
cifail cistep2 Checkout 'a step name:'
cifail cimatrixbad 'tset (ubuntu)' 'text around the expression differing'
cidoc ciyaml '`Docs build` runs the full suite.'
ciwf ciyaml docs.yaml <<'EOF'
on: push
jobs:
  docs:
    name: Docs build
    runs-on: ubuntu-latest
    steps:
      - run: make docs
EOF
[ "$(code lint "$lr/ciyaml")" = 0 ] || fail "lint passes a CI full suite defined in a .yaml workflow: $(cat "$tmp/out")"
cidoc ciyamlid '`docs` runs the full suite.'
ciwf ciyamlid docs.yaml <<'EOF'
on: push
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - run: make docs
EOF
[ "$(code lint "$lr/ciyamlid")" = 0 ] || fail "lint passes a CI full suite naming a job id in a .yaml workflow: $(cat "$tmp/out")"
for n in 'Full suite' 'Quoted suite'; do
  cidoc cicomment "\`$n\` runs the full suite."
  ciwf cicomment ci.yml <<'EOF'
on: push
jobs:
  plain:
    name: Full suite # runs tests
    steps:
      - run: make test
  quoted:
    name: "Quoted suite"   # runs tests
    steps:
      - run: make test
EOF
  [ "$(code lint "$lr/cicomment")" = 0 ] || fail "lint passes a CI full suite of '$n' whose job name: has a YAML comment: $(cat "$tmp/out")"
done
cidoc cinowf '`Full suite` runs the full suite.'
[ "$(code lint "$lr/cinowf")" = 1 ] || fail "lint fails a CI full suite with no .github/workflows: $(cat "$tmp/out")"
grep -qxF "$(cimsg cinowf 'Full suite')" "$tmp/out" || fail "a CI full suite with no .github/workflows prints the exact no-job message: $(cat "$tmp/out")"
cidoc ciempty '`Full suite` runs the full suite.'
ciwf ciempty README.md <<'EOF'
name: Full suite
jobs:
  build:
    name: Full suite
EOF
[ "$(code lint "$lr/ciempty")" = 1 ] || fail "lint fails a CI full suite whose .github/workflows has no .yml or .yaml file: $(cat "$tmp/out")"
grep -qxF "$(cimsg ciempty 'Full suite')" "$tmp/out" || fail "a CI full suite with no workflow file prints the exact no-job message: $(cat "$tmp/out")"
cidoc cinotick 'the full suite job on the PR.'
ciflow cinotick
[ "$(code lint "$lr/cinotick")" = 1 ] || fail "lint fails a CI full suite line with no backticked name: $(cat "$tmp/out")"
grep -qxF "forge: $lr/cinotick/.forge/TESTING.md: line 5: - CI full suite: the full suite job on the PR.: no backticked command" "$tmp/out" ||
  fail "a CI full suite line with no backticked name names the file, line and reason: $(cat "$tmp/out")"
cidoc ciplace '`<check name>`, the GitHub Actions job name.'
[ "$(code lint "$lr/ciplace")" = 0 ] || fail "lint skips a <check name> placeholder CI full suite: $(cat "$tmp/out")"
lintdoc cinone '- All tests: `pytest`.' '- Test: `pytest -x {test}`.'
[ "$(code lint "$lr/cinone")" = 0 ] && [ ! -s "$tmp/out" ] || fail "lint passes a doc without a CI full suite line and no workflows as before: $(cat "$tmp/out")"
lintdoc cinonewf '- All tests: `pytest`.'
ciflow cinonewf
[ "$(code lint "$lr/cinonewf")" = 0 ] && [ ! -s "$tmp/out" ] || fail "lint passes a doc without a CI full suite line beside workflows as before: $(cat "$tmp/out")"
lintdoc cimixed '- All tests: `pytest`.' '- Test: `pytest -x` for one test.' '- CI full suite: `Lint`.'
ciflow cimixed
[ "$(code lint "$lr/cimixed")" = 1 ] && grep -qF '{test}' "$tmp/out" && grep -qxF "$(cimsg cimixed Lint)" "$tmp/out" ||
  fail "lint prints both a Test failure and a CI full suite failure: $(cat "$tmp/out")"
fjflow() {
  fjwf "$1" ci.yml <<'EOF'
on: [pull_request]
jobs:
  build:
    name: "Forgejo suite"
    runs-on: docker
    steps:
      - run: make test
  check:
    runs-on: docker
    steps:
      - name: Run checks
        run: make check
EOF
}
fjpass() {
  cidoc "$1" "\`$2\` runs the full suite."
  fjflow "$1"
  [ "$(code lint "$lr/$1")" = 0 ] && ! grep -qF 'CI full suite' "$tmp/out" || fail "lint passes a CI full suite of '$2' ($3): $(cat "$tmp/out")"
}
fjfail() {
  cidoc "$1" "\`$2\` runs the full suite."
  fjflow "$1"
  [ "$(code lint "$lr/$1")" = 1 ] || fail "lint fails a CI full suite of '$2' ($3) with exit 1: $(cat "$tmp/out")"
  grep -qxF "$(cimsg "$1" "$2")" "$tmp/out" || fail "a CI full suite of '$2' ($3) prints the exact no-job message: $(cat "$tmp/out")"
}
fjpass fjname 'Forgejo suite' 'a .forgejo/workflows job name: with quotes stripped'
fjpass fjid check 'the id of a .forgejo/workflows job with no name:'
fjfail fjbuild build 'the id of a .forgejo/workflows job with a name:'
fjfail fjstep 'Run checks' 'a .forgejo/workflows step name:'
fjfail fjmeta 'Forgejo.*' 'regex metacharacters against a .forgejo/workflows job name:'
fjfail fjmeta2 '.*' 'regex metacharacters against a .forgejo/workflows job name:'
cidoc fjyaml '`Forgejo docs` runs the full suite.'
fjwf fjyaml docs.yaml <<'EOF'
on: push
jobs:
  docs:
    name: Forgejo docs
    runs-on: docker
    steps:
      - run: make docs
EOF
[ "$(code lint "$lr/fjyaml")" = 0 ] || fail "lint passes a CI full suite defined in a .forgejo/workflows .yaml workflow: $(cat "$tmp/out")"
cidoc fjyamlid '`docs` runs the full suite.'
fjwf fjyamlid docs.yaml <<'EOF'
on: push
jobs:
  docs:
    runs-on: docker
    steps:
      - run: make docs
EOF
[ "$(code lint "$lr/fjyamlid")" = 0 ] || fail "lint passes a CI full suite naming a job id in a .forgejo/workflows .yaml workflow: $(cat "$tmp/out")"
cidoc fjboth '`Forgejo suite` runs the full suite.'
ciflow fjboth
fjflow fjboth
[ "$(code lint "$lr/fjboth")" = 0 ] || fail "lint passes a .forgejo/workflows job name beside .github/workflows: $(cat "$tmp/out")"
cidoc fjboth '`Full suite` runs the full suite.'
ciflow fjboth
fjflow fjboth
[ "$(code lint "$lr/fjboth")" = 0 ] || fail "lint passes a .github/workflows job name beside .forgejo/workflows: $(cat "$tmp/out")"
cidoc fjundef '`Lint` runs the full suite.'
ciflow fjundef
fjflow fjundef
[ "$(code lint "$lr/fjundef")" = 1 ] || fail "lint fails a CI full suite no job of either directory defines with exit 1: $(cat "$tmp/out")"
grep -qxF "$(cimsg fjundef Lint)" "$tmp/out" || fail "a CI full suite no job of either directory defines prints the exact no-job message: $(cat "$tmp/out")"
cidoc fjempty '`Full suite` runs the full suite.'
ciwf fjempty README.md <<'EOF'
jobs:
  build:
    name: Full suite
EOF
fjwf fjempty README.md <<'EOF'
jobs:
  build:
    name: Full suite
EOF
[ "$(code lint "$lr/fjempty")" = 1 ] || fail "lint fails a CI full suite when neither workflows dir holds a .yml or .yaml file: $(cat "$tmp/out")"
grep -qxF "$(cimsg fjempty 'Full suite')" "$tmp/out" || fail "a CI full suite with no workflow file in either dir prints the exact no-job message: $(cat "$tmp/out")"
for n in quoted single; do
  cidoc ciqid "\`$n\` runs the full suite."
  ciwf ciqid ci.yml <<'EOF'
on: push
jobs:
  "quoted":
    runs-on: ubuntu-latest
  'single' :
    runs-on: ubuntu-latest
EOF
  [ "$(code lint "$lr/ciqid")" = 0 ] || fail "lint passes a CI full suite of '$n' naming a quoted job id: $(cat "$tmp/out")"
done
for b in '>-' '|' '>+2' '|-'; do
  cidoc ciblock '`Anything at all` runs the full suite.'
  ciwf ciblock ci.yml <<EOF
on: push
jobs:
  full:
    name: $b
      test
    runs-on: ubuntu-latest
EOF
  [ "$(code lint "$lr/ciblock")" = 0 ] || fail "lint passes any CI full suite beside a block-scalar job name: $b: $(cat "$tmp/out")"
done
cidoc fjread '`Forgejo suite` runs the full suite.'
fjflow fjread
chmod 000 "$lr/fjread/.forgejo/workflows/ci.yml"
[ "$(code lint "$lr/fjread")" != 0 ] || fail "lint fails a CI full suite whose .forgejo/workflows file cannot be read: $(cat "$tmp/out")"
chmod 644 "$lr/fjread/.forgejo/workflows/ci.yml"
grep -qF "cannot read $lr/fjread/.forgejo/workflows" "$tmp/out" || fail "an unreadable .forgejo/workflows file names that directory: $(cat "$tmp/out")"
ok lint-ci
fi

if want lint-pr-labels; then
lintdoc plok '- All tests: `pytest`.' '- PR labels: `scripts/pr-labels.sh origin/main` prints the labels.'
[ "$(code lint "$lr/plok")" = 0 ] && [ ! -s "$tmp/out" ] || fail "lint passes a PR labels line with a backticked command: $(cat "$tmp/out")"
lintdoc plnone '- All tests: `pytest`.' '- PR labels: the risk labels.'
[ "$(code lint "$lr/plnone")" = 1 ] || fail "lint fails a PR labels line without a backticked command with exit 1: $(cat "$tmp/out")"
grep -qxF "forge: $lr/plnone/.forge/TESTING.md: line 5: - PR labels: the risk labels.: no backticked command" "$tmp/out" ||
  fail "a PR labels line without a backticked command prints the exact no-backticked-command message: $(cat "$tmp/out")"
plc='echo "preview'
ple=$(bash -n -c "$plc" 2>&1 || :)
[ -n "$ple" ] || fail "bash -n reports an error for '$plc'"
lintdoc plsyn '- All tests: `pytest`.' "- PR labels: \`$plc\` prints the labels."
[ "$(code lint "$lr/plsyn")" = 1 ] || fail "lint fails a PR labels command with a bash syntax error with exit 1: $(cat "$tmp/out")"
grep -qxF "forge: $lr/plsyn/.forge/TESTING.md: - PR labels: \`$plc\`: ${ple//$'\n'/; }" "$tmp/out" ||
  fail "a PR labels command with a bash syntax error prints the exact bash -n message: $(cat "$tmp/out")"
ok lint-pr-labels
fi

if want lint-pre-push; then
lintdoc ppok '- All tests: `pytest`.' '- Pre-push: `pnpm lint && pnpm build` runs the static checks.'
[ "$(code lint "$lr/ppok")" = 0 ] && [ ! -s "$tmp/out" ] || fail "lint passes a Pre-push line with a backticked command: $(cat "$tmp/out")"
lintdoc ppnone '- All tests: `pytest`.' '- Pre-push: the static checks.'
[ "$(code lint "$lr/ppnone")" = 1 ] || fail "lint fails a Pre-push line without a backticked command with exit 1: $(cat "$tmp/out")"
grep -qxF "forge: $lr/ppnone/.forge/TESTING.md: line 5: - Pre-push: the static checks.: no backticked command" "$tmp/out" ||
  fail "a Pre-push line without a backticked command prints the exact no-backticked-command message: $(cat "$tmp/out")"
ppc='pnpm lint &&'
ppe=$(bash -n -c "$ppc" 2>&1 || :)
[ -n "$ppe" ] || fail "bash -n reports an error for '$ppc'"
lintdoc ppsyn '- All tests: `pytest`.' "- Pre-push: \`$ppc\` runs the static checks."
[ "$(code lint "$lr/ppsyn")" = 1 ] || fail "lint fails a Pre-push command with a bash syntax error with exit 1: $(cat "$tmp/out")"
grep -qxF "forge: $lr/ppsyn/.forge/TESTING.md: - Pre-push: \`$ppc\`: ${ppe//$'\n'/; }" "$tmp/out" ||
  fail "a Pre-push command with a bash syntax error prints the exact bash -n message: $(cat "$tmp/out")"
ok lint-pre-push
fi

if want ci-docs; then
cmds() { awk '/^## /{s=($0=="## Commands")} s' "$1"; }
cmds "$root/templates/TESTING.md" >"$tmp/tcmds"
! grep -qE '^## Layout[[:space:]]*$' "$root/templates/TESTING.md" || fail "the TESTING template has no ## Layout section: $(grep -nE '^## ' "$root/templates/TESTING.md")"
! grep -qE '^[[:space:]]*- CI full suite:' "$root/templates/TESTING.md" || fail "the TESTING template declares no active CI full suite line"
grep -vE '^[[:space:]]*- ' "$tmp/tcmds" | grep -F 'CI full suite' | grep -qF '<check name>' ||
  fail "the TESTING template's Commands describes the CI full suite line with its <check name> in prose: $(cat "$tmp/tcmds")"
grep -qF 'GitHub Actions' "$tmp/tcmds" && grep -qF 'success' "$tmp/tcmds" ||
  fail "the TESTING template's Commands names the GitHub Actions job and that only a success counts: $(cat "$tmp/tcmds")"
rm -rf "$lr/seeded" && mkdir -p "$lr/seeded/.forge" && cp "$root/templates/TESTING.md" "$lr/seeded/.forge/"
[ "$(code lint "$lr/seeded")" = 0 ] && [ ! -s "$tmp/out" ] || fail "a repo seeded from the TESTING template without CI passes test_lint: $(cat "$tmp/out")"
cmds "$root/.forge/TESTING.md" >"$tmp/fcmds"
! grep -qE '^[[:space:]]*- CI full suite:' "$root/.forge/TESTING.md" || fail "forge's TESTING.md declares no CI full suite line"
grep -E '^- ' "$tmp/fcmds" | grep -F 'CI full suite' | grep -qiE 'none|no ' && grep -E '^- ' "$tmp/fcmds" | grep -F 'CI full suite' | grep -qi 'workflow' ||
  fail "forge's TESTING.md Commands has a bullet on the CI full suite line saying forge declares none since it has no CI workflows: $(cat "$tmp/fcmds")"
awk '/^## Gates/{exit} 1' "$root/.forge/TESTING.md" | grep -F 'forge-gates' | grep -qF 'CI full suite' ||
  fail "forge's TESTING.md test notes cover the forge-gates CI full suite lint cases"
[ "$(code lint "$root")" = 0 ] && [ ! -s "$tmp/out" ] || fail "forge's own TESTING.md passes test_lint: $(cat "$tmp/out")"
ok ci-docs
fi

if want testing-keys; then
awk '/^## /{s=($0=="## Commands")} s' "$root/.forge/TESTING.md" >"$tmp/kcmds"
for k in 'All tests' Test 'Changed tests' 'Failed tests' 'Perf tests'; do
  sed -n "s/^\(- $k: \`[^\`]*\`\).*/\1/p" "$tmp/kcmds"
done >"$tmp/keys"
diff "$root/tests/fixtures/forge/docs-diet/testing-keys.txt" "$tmp/keys" >"$tmp/out" ||
  fail "forge's TESTING.md keeps its Commands key lines byte for byte: $(cat "$tmp/out")"
ok testing-keys
fi

if want docs-validate; then
[ "$(cd "$root" && code "$forge" validate .forge/ARCHITECTURE.md .forge/TESTING.md .forge/STACK.md)" = 0 ] && [ ! -s "$tmp/out" ] ||
  fail "forge's ARCHITECTURE.md, TESTING.md and STACK.md pass forge validate with no output: $(cat "$tmp/out")"
for n in port bin/forge.d/land.sh bin/forge.d/commit.sh bin/forge.d/gate.sh hooks/forge-guard.sh forge-init tests/agents.test.sh templates/ global/settings.json 'forge task-done' 'forge done' 'forge golive' 'forge pr checks --full'; do
  grep -qF -- "$n" "$root/.forge/ARCHITECTURE.md" || fail "forge's ARCHITECTURE.md names $n, which a RULES.md invariant cites"
done
ok docs-validate
fi

if want cpu-docs; then
cpara() { awk -v RS= '/FORGE_TEST_CPUS/' "$1"; }
cpara "$root/templates/TESTING.md" >"$tmp/tcpu"
[ -s "$tmp/tcpu" ] || fail "the TESTING template has a paragraph on FORGE_TEST_CPUS"
grep -qF 'nproc' "$tmp/tcpu" || fail "the TESTING template caps FORGE_TEST_CPUS at nproc: $(cat "$tmp/tcpu")"
grep -qF -- '- CPUs one:' "$tmp/tcpu" && grep -qF -- '- CPUs all:' "$tmp/tcpu" ||
  fail "the TESTING template's FORGE_TEST_CPUS guidance names the - CPUs one: and - CPUs all: lines: $(cat "$tmp/tcpu")"
grep -qiF 'job count' "$tmp/tcpu" || fail "the TESTING template calls FORGE_TEST_CPUS the runner's job count, set by the - CPUs lines: $(cat "$tmp/tcpu")"
grep -qF '2 for `--one`' "$tmp/tcpu" || fail "the TESTING template names the one-tier default job count 2: $(cat "$tmp/tcpu")"
grep -qF 'max(2, floor(nproc / 4))' "$tmp/tcpu" || fail "the TESTING template names the all-tier default job count max(2, floor(nproc / 4)): $(cat "$tmp/tcpu")"
grep -qF -- '- Memory:' "$tmp/tcpu" || fail "the TESTING template says a CPUs line raises the job count within the - Memory: budget: $(cat "$tmp/tcpu")"
! grep -qiwE 'grant(s|ed)?|wants?' "$tmp/tcpu" || fail "the TESTING template no longer describes a CPU grant or want: $(cat "$tmp/tcpu")"
! grep -qiF "share of the machine's CPUs" "$tmp/tcpu" || fail "the TESTING template no longer calls FORGE_TEST_CPUS a share of the CPUs: $(cat "$tmp/tcpu")"
cpara "$root/tests/fixtures/forge/expected/map/TESTING.md" | diff -u "$tmp/tcpu" - || fail "the map golden TESTING.md carries the template's FORGE_TEST_CPUS guidance"
ok cpu-docs
fi

if want test-none; then
tnone() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; tests_none "$2"' _ "$root" "$1"; }
nd=$tmp/nd
ndoc() { rm -rf "$nd/$1"; mkdir -p "$nd/$1/.forge"; printf '%s\n' "${@:2}" >"$nd/$1/.forge/TESTING.md"; }
ndoc plain '# Testing' '' '## Commands' '- All tests: none'
ndoc spaces '# Testing' '' '## Commands' '- All tests: none   '
ndoc later '# Testing' '' '## Layout' '- tests/ holds nothing' '' '## Commands' '- Setup: `npm ci`' '- All tests: none' '' '## Gates' '- none'
for c in plain spaces later; do
  [ "$(code tnone "$nd/$c")" = 0 ] || fail "tests_none holds for the $c declaration: $(cat "$tmp/out")"
done
ndoc dot '# Testing' '' '## Commands' '- All tests: none.'
ndoc word '# Testing' '' '## Commands' '- All tests: nonesuch'
ndoc text '# Testing' '' '## Commands' '- All tests: none of them run here'
ndoc ticked '# Testing' '' '## Commands' '- All tests: `none`'
ndoc both '# Testing' '' '## Commands' '- All tests: none' '- All tests: `./t.sh`'
ndoc cmdfirst '# Testing' '' '## Commands' '- All tests: `./t.sh`' '- All tests: none'
ndoc outside '# Testing' '' '## Layout' '- All tests: none' '' '## Commands' '- Setup: `npm ci`'
ndoc after '# Testing' '' '## Commands' '- Setup: `npm ci`' '' '## Gates' '- All tests: none'
ndoc nohead '# Testing' '' '- All tests: none'
ndoc indent '# Testing' '' '## Commands' '  - All tests: none'
ndoc expand '# Testing' '' '## Commands' "- All tests: none \$(touch $nd/ran)"
ndoc noline '# Testing' '' '## Commands' '- Setup: `npm ci`'
mkdir -p "$nd/nodoc"
for c in dot word text ticked both cmdfirst outside after nohead indent expand noline nodoc; do
  [ "$(code tnone "$nd/$c")" != 0 ] || fail "tests_none is false for the $c doc: $(cat "$nd/$c/.forge/TESTING.md" 2>/dev/null)"
done
[ ! -e "$nd/ran" ] || fail "tests_none never expands or runs the line"
nr=$tmp/nr
gitinit "$nr"
mkdir -p "$nr/.forge" "$tmp/nbin"
printf '#!/usr/bin/env bash\necho "none $*" >>%q\n' "$tmp/n-ran" >"$tmp/nbin/none"
chmod +x "$tmp/nbin/none"
printf '# Testing\n\n## Commands\n- All tests: none\n' >"$nr/.forge/TESTING.md"
echo a >"$nr/a.txt"
git -C "$nr" add -A && git -C "$nr" commit -q -m init
nsaid() { [ "$(cat "$tmp/out")" = "forge: $nr/.forge/TESTING.md declares \"- All tests: none\"; tests not run" ]; }
ncode() { PATH=$tmp/nbin:$PATH code "$forge" test "$@" "$nr"; }
[ "$(ncode)" = 5 ] && nsaid || fail "a - All tests: none declaration exits 5 naming it: $(cat "$tmp/out")"
[ "$(ncode --force)" = 5 ] && nsaid || fail "--force with a none declaration exits 5: $(cat "$tmp/out")"
[ "$(ncode --changed)" = 5 ] && nsaid || fail "--changed with a none declaration exits 5: $(cat "$tmp/out")"
[ "$(ncode --one a)" = 5 ] && nsaid || fail "--one without a Test line under a none declaration exits 5: $(cat "$tmp/out")"
[ "$(ncode --passed)" = 5 ] && nsaid || fail "--passed passes the none declaration's 5 through: $(cat "$tmp/out")"
[ "$(ncode --passed --changed)" = 5 ] && nsaid || fail "--passed --changed passes the none declaration's 5 through: $(cat "$tmp/out")"
[ ! -e "$tmp/n-ran" ] || fail "a none declaration never runs none as a command: $(cat "$tmp/n-ran")"
[ ! -e "$nr/.git/forge-test" ] || [ -z "$(find "$nr/.git/forge-test" -type f -path "*$(git -C "$nr" rev-parse HEAD^{tree})*")" ] || fail "a none declaration records no pass stamp"
printf '# Testing\n\n## Commands\n- All tests: none  \t\n' >"$nr/.forge/TESTING.md"
git -C "$nr" commit -q -am spaces
[ "$(ncode)" = 5 ] && nsaid || fail "a none declaration with trailing whitespace exits 5: $(cat "$tmp/out")"
nfix() { [ "$(cat "$tmp/out")" = "forge: no \"- All tests:\" line in $nr/.forge/TESTING.md; add a command or \"- All tests: none\"" ]; }
for d in '# Testing' '# Testing\n\n## Commands\n- Setup: `true`' '# Testing\n\n## Commands\n- All tests: run them by hand' '# Testing\n\n## Commands\n- All tests: none.' '# Testing\n\n## Commands\n- All tests: nonesuch' '# Testing\n\n## Layout\n- All tests: none\n\n## Commands\n- Setup: `true`'; do
  printf "$d\n" >"$nr/.forge/TESTING.md"
  git -C "$nr" commit -q -am "doc $d"
  [ "$(ncode)" = 6 ] && nfix || fail "a doc of '$d' exits 6 with the fix: $(cat "$tmp/out")"
  [ "$(ncode --changed)" = 6 ] && nfix || fail "--changed on a doc of '$d' exits 6 with the fix: $(cat "$tmp/out")"
  [ "$(ncode --one a)" = 6 ] && nfix || fail "--one on a doc of '$d' exits 6 with the fix: $(cat "$tmp/out")"
  [ "$(ncode --passed)" = 6 ] && nfix || fail "--passed on a doc of '$d' passes the 6 through with the fix: $(cat "$tmp/out")"
done
git -C "$nr" rm -q .forge/TESTING.md && git -C "$nr" commit -q -m nodoc
[ "$(ncode)" = 6 ] && nfix || fail "no TESTING.md exits 6 with the fix: $(cat "$tmp/out")"
[ "$(ncode --passed)" = 6 ] && nfix || fail "--passed without TESTING.md exits 6 with the fix: $(cat "$tmp/out")"
[ ! -e "$tmp/n-ran" ] || fail "a missing line runs nothing: $(cat "$tmp/n-ran")"
mkdir -p "$nr/.forge"
cat >"$nr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$N5_LOG"
exit "$(cat "$N5_EXIT")"
EOF
chmod +x "$nr/t.sh"
export N5_LOG=$tmp/n5.log N5_EXIT=$tmp/n5.exit
echo 0 >"$N5_EXIT"
printf '# Testing\n\n## Commands\n- All tests: none\n- All tests: `./t.sh all`\n' >"$nr/.forge/TESTING.md"
git -C "$nr" add -A && git -C "$nr" commit -q -m both
: >"$N5_LOG"
[ "$(ncode)" = 0 ] && [ "$(cat "$N5_LOG")" = all ] || fail "a backticked All tests command wins over a none line: $(cat "$tmp/out" "$N5_LOG")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Test: `./t.sh one {test}`\n- Changed tests: `./t.sh changed {files}`\n' >"$nr/.forge/TESTING.md"
git -C "$nr" commit -q -am cmds
echo 5 >"$N5_EXIT"
n5() { local w=$1; shift; : >"$N5_LOG"; [ "$(ncode "$@")" = 1 ] && [ "$(head -n1 "$N5_LOG" | cut -d' ' -f1)" = "$w" ] || fail "a command exiting 5 on forge test $* exits 1 after running $w: $(cat "$tmp/out" "$N5_LOG")"; }
n5 all --force
echo u >"$nr/u.txt"
n5 changed --changed --force
n5 one --one a
n5 one --repeat 2 --one a
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Changed tests: `./t.sh changed {files}`\n' >"$nr/.forge/TESTING.md"
git -C "$nr" commit -q -am nontest
n5 changed --one a
n5 changed --repeat 2 --one a
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n' >"$nr/.forge/TESTING.md"
git -C "$nr" commit -q -am nochanged
n5 all --changed --force
n5 all --one a
n5 all --repeat 2 --one a
echo 0 >"$N5_EXIT"
"$forge" test --help | sed -n '/^Exit codes:/,/^Reads:/p' >"$tmp/nhelp"
grep -q '^  6 ' "$tmp/nhelp" && sed -n '/^  6 /,/^  [0-9*]/p' "$tmp/nhelp" | grep -qF -- '- All tests:' || fail "forge test --help lists exit 6 for a missing - All tests: line: $(cat "$tmp/nhelp")"
sed -n '/^  5 /,/^  6 /p' "$tmp/nhelp" | grep -qF -- '- All tests: none' || fail "forge test --help's exit 5 names the - All tests: none declaration: $(cat "$tmp/nhelp")"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh all`\n- Perf log: `./t.sh perf`\n' >"$nr/.forge/TESTING.md"
git -C "$nr" commit -q -am perfline
[ "$(ncode --bogus)" = 2 ] && cp "$tmp/out" "$tmp/nbogus" || fail "an unknown flag exits 2: $(cat "$tmp/out")"
: >"$N5_LOG"
[ "$(ncode --perf)" = 2 ] && cmp -s "$tmp/out" "$tmp/nbogus" && [ ! -s "$N5_LOG" ] || fail "forge test --perf exits 2 with the usage an unknown flag prints and runs nothing: $(cat "$tmp/out" "$N5_LOG")"
[ "$(ncode --perf --force)" = 2 ] && cmp -s "$tmp/out" "$tmp/nbogus" && [ ! -s "$N5_LOG" ] || fail "forge test --perf --force exits 2 with the usage an unknown flag prints and runs nothing: $(cat "$tmp/out" "$N5_LOG")"
ok test-none
fi

if want test-timeout-limit; then
tl=$tmp/tl
gitinit "$tl"
mkdir -p "$tl/.forge" "$tl/.git/forge-test"
tlrl=$tl/.git/forge-test/runs.log
tldoc() { printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh`' "$@" >"$tl/.forge/TESTING.md"; }
tlrun() { printf '2026-10-12 10:00:00 %s 0123456789abcdef0123456789abcdef01234567 0 %s %s 1.00 1000 4G peak=-\n' "$@" >>"$tlrl"; }
tlim() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; test_limit "$2"' _ "$root" "$tl" >"$tmp/out" 2>&1; }
limited() { local n s; tlim && [ "$(wc -l <"$tmp/out")" = 1 ] && read -r n s <"$tmp/out" && [ "$n" = "$1" ] && [ "$s" = "$2" ]; }
tldoc
rm -f "$tlrl"
limited 60 "the 60 min default" || fail "test_limit without a Timeout line prints 60 and the 60 min default: $(cat "$tmp/out")"
for t in all changed one repeat; do tlrun $t 9000 0; done
tlrun all 400 0
limited 60 "the 60 min default" || fail "test_limit without a Timeout line ignores runs.log and prints the 60 min default, never 3x the longest run: $(cat "$tmp/out")"
tldoc '- Timeout: `45` per run.'
limited 45 "- Timeout: in $tl/.forge/TESTING.md" || fail "a Timeout line of 45 sets test_limit to 45 from the TESTING.md path: $(cat "$tmp/out")"
tldoc '- Timeout: `1`'
limited 1 "- Timeout: in $tl/.forge/TESTING.md" || fail "a Timeout line of 1 sets test_limit to 1: $(cat "$tmp/out")"
tlout() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; top=$2 log=$3; test_clock; echo "$lim"; timed_out' _ "$root" "$tl" "$tl/x.log" >"$tmp/out" 2>&1; }
tldoc
tlout && [ "$(cat "$tmp/out")" = "3600"$'\n'"forge: tests timed out after 60 min (limit from the 60 min default), log $tl/x.log" ] ||
  fail "without a Timeout line the limit is 60 min, 3600 s, and the timeout line names the 60 min default: $(cat "$tmp/out")"
FORGE_TEST_MIN_SECS=2 tlout && [ "$(cat "$tmp/out")" = "120"$'\n'"forge: tests timed out after 60 min (limit from the 60 min default), log $tl/x.log" ] ||
  fail "FORGE_TEST_MIN_SECS=2 scales the 60 min default to 120 s and the timeout line still names 60 min: $(cat "$tmp/out")"
tldoc '- Timeout: `45`'
tlout && [ "$(cat "$tmp/out")" = "2700"$'\n'"forge: tests timed out after 45 min (limit from - Timeout: in $tl/.forge/TESTING.md), log $tl/x.log" ] ||
  fail "a Timeout line of 45 gives 2700 s and a timeout line naming the Timeout line's path: $(cat "$tmp/out")"
mkdir -p "$tmp/tobin"
printf '#!/usr/bin/env bash\necho "$1 $2 $3 ${4:0:2}" >>"$TO_ARGS"\nexec %q "$@"\n' "$(command -v timeout)" >"$tmp/tobin/timeout"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$tl/t.sh"
chmod +x "$tmp/tobin/timeout" "$tl/t.sh"
tlgo() { local s=0; : >"$tmp/to-args"; timeout 60 env PATH="$tmp/tobin:$PATH" TO_ARGS="$tmp/to-args" "$forge" test "$@" "$tl" >"$tmp/out" 2>&1 || s=$?; echo $s; }
tlargs() { [ "$(sort -u "$tmp/to-args")" = "$1" ] && [ "$(wc -l <"$tmp/to-args")" -ge "$2" ]; }
tldoc '- Setup: `true`' '- Test: `./t.sh {test}`'
git -C "$tl" add -A && git -C "$tl" commit -q -m init
[ "$(tlgo --force)" = 0 ] && tlargs "-k 10s 60m ba" 2 ||
  fail "Setup and a full run each run under timeout -k 10s 60m without a Timeout line: $(cat "$tmp/out") $(cat "$tmp/to-args")"
tldoc '- Setup: `true`' '- Test: `./t.sh {test}`' '- Timeout: `45`'
git -C "$tl" commit -q -am timeout
[ "$(tlgo --force)" = 0 ] && tlargs "-k 10s 45m ba" 1 || fail "a full run runs under timeout -k 10s 45m with a Timeout line of 45: $(cat "$tmp/out") $(cat "$tmp/to-args")"
[ "$(tlgo --one x)" = 0 ] && tlargs "-k 10s 45m ba" 1 || fail "a --one run runs under timeout -k 10s 45m, the same limit as the full tier: $(cat "$tmp/out") $(cat "$tmp/to-args")"
[ "$(FORGE_TEST_MIN_SECS=2 tlgo --one x)" = 0 ] && tlargs "-k 10s 90s ba" 1 || fail "FORGE_TEST_MIN_SECS=2 scales the 45 min limit to timeout -k 10s 90s: $(cat "$tmp/out") $(cat "$tmp/to-args")"
for v in 45 1 120; do
  lintdoc took '- All tests: `pytest`.' "- Timeout: \`$v\` per run."
  [ "$(code lint "$lr/took")" = 0 ] || fail "lint passes a Timeout line of $v: $(cat "$tmp/out")"
done
for v in 0 45m -5 1.5 abc '' '4 5'; do
  lintdoc tobad '- All tests: `pytest`.' "- Timeout: \`$v\` per run."
  [ "$(code lint "$lr/tobad")" != 0 ] || fail "lint fails a Timeout line of '$v': $(cat "$tmp/out")"
  grep -qF "$lr/tobad/.forge/TESTING.md" "$tmp/out" && grep -qF "Timeout" "$tmp/out" && { [ -z "$v" ] || grep -qF -- "$v" "$tmp/out"; } ||
    fail "a Timeout line of '$v' names the file, the Timeout line and its value: $(cat "$tmp/out")"
done
lintdoc tonone '- All tests: `pytest`.' '- Timeout: forty-five minutes.'
[ "$(code lint "$lr/tonone")" != 0 ] || fail "lint fails a Timeout line without a backticked value: $(cat "$tmp/out")"
grep -qF "$lr/tonone/.forge/TESTING.md" "$tmp/out" && grep -qF "Timeout" "$tmp/out" ||
  fail "a Timeout line without a backticked value names the file and the Timeout line: $(cat "$tmp/out")"
ok test-timeout-limit
fi

if want_any test-timeout test-timeout-one; then
to=$tmp/to
gitinit "$to"
mkdir -p "$to/.forge"
printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh all`' '- Test: `./t.sh one {test}`' '- Timeout: `1`' >"$to/.forge/TESTING.md"
cat >"$to/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$FORGE_TEST_SLOT_HELD" >"$TO_SLOT"
sleep 600 &
sleep 600
EOF
chmod +x "$to/t.sh"
git -C "$to" add -A && git -C "$to" commit -q -m init
tost=$to/.git/forge-test
tops=$tost/$hid
torl=$tost/runs.log
totree=$(git -C "$to" rev-parse HEAD^{tree})
toline="forge: tests timed out after 1 min (limit from - Timeout: in $to/.forge/TESTING.md), log $to/.git/forge-test.log"
torun() { local s=0; rm -f "$tmp/to-slot"; TO_RUN=$tmp/to-$1 TO_SLOT=$tmp/to-slot FORGE_TEST_MIN_SECS=2 timeout --preserve-status 30 "$forge" test "${@:2}" "$to" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
toall() { cat "$tmp/out" "$tmp/err"; }
toleft() {
  local p=
  for _ in $(seq 30); do
    p=$(grep -lzxsF "TO_RUN=$tmp/to-$1" /proc/[0-9]*/environ | cut -d/ -f3 | paste -sd' ')
    [ -n "$p" ] || return 0
    sleep 0.1
  done
  kill -KILL $p 2>/dev/null || :
  echo "$p"
  return 1
}
toslot() {
  local f
  f=$(cat "$tmp/to-slot" 2>/dev/null) && [[ $f == "$XDG_RUNTIME_DIR"/forge/test-runs/[1-9]* ]] && flock -n "$f" true
}
mkdir -p "$tost"
: >"$torl"
fi

if want test-timeout; then
mkdir -p "$tops/changed" && : >"$tops/$totree" && echo >"$tops/changed/$totree"
tos=$(torun full --force)
[ "$tos" = 124 ] || fail "a run past its 1 min Timeout limit, 2 s per limit minute, exits 124, got $tos: $(toall)"
grep -qxF "$toline" "$tmp/err" || fail "a timed-out run prints '$toline' on stderr: $(toall)"
! grep -qF "tests passed" "$tmp/out" "$tmp/err" || fail "a timed-out run never prints tests passed: $(toall)"
left=$(toleft full) || fail "a timed-out run leaves no process of its suite, the background child included: pids $left"
toslot || fail "a timed-out run releases its run slot: $(cat "$tmp/to-slot" 2>/dev/null)"
read -ra tf <<<"$(tail -n1 "$torl" 2>/dev/null)"
[ "${#tf[@]}" = 12 ] && [ "${tf[2]}" = all ] && [ "${tf[3]}" = "$totree" ] && [ "${tf[6]}" = timeout ] && [[ ${tf[5]} =~ ^[0-9]+$ ]] && [ "${tf[5]}" -ge 2 ] ||
  fail "a timed-out run's runs.log line has tier all, its tree, its real run seconds and exit timeout: $(tail -n1 "$torl" 2>/dev/null)"
[ ! -e "$tops/$totree" ] && [ ! -e "$tops/changed/$totree" ] || fail "a timed-out run removes the tree's pass stamps: $(ls "$tops" "$tops/changed")"
[ ! -e "$tost/failed/$totree-all.log" ] || fail "a timed-out run writes no failed log: $(ls "$tost/failed")"
ok test-timeout
fi

if want test-timeout-one; then
ton=$(wc -l <"$torl")
tos=$(torun one --one x)
[ "$tos" = 124 ] || fail "a --one run past its 1 min Timeout limit exits 124, got $tos: $(toall)"
grep -qxF "$toline" "$tmp/err" || fail "a timed-out --one run prints '$toline' on stderr: $(toall)"
read -ra tf <<<"$(tail -n1 "$torl")"
[ "$(wc -l <"$torl")" = $((ton + 1)) ] && [ "${#tf[@]}" = 12 ] && [ "${tf[2]}" = one ] && [ "${tf[3]}" = "$totree" ] && [ "${tf[6]}" = timeout ] ||
  fail "a timed-out --one run appends one runs.log line with tier one, its tree and exit timeout: $(tail -n2 "$torl")"
left=$(toleft one) || fail "a timed-out --one run leaves no process of its suite: pids $left"
toslot || fail "a timed-out --one run releases its run slot: $(cat "$tmp/to-slot" 2>/dev/null)"
tos=$(torun rep --one x --repeat 3)
[ "$tos" = 124 ] || fail "a --repeat iteration past its 1 min Timeout limit exits 124, got $tos: $(toall)"
grep -qxF "$toline" "$tmp/err" && grep -qxF "forge: repeat failed on iteration 1/3" "$tmp/err" ||
  fail "a timed-out --repeat iteration prints the timeout line and its repeat failed line: $(toall)"
read -ra tf <<<"$(tail -n1 "$torl")"
[ "$(wc -l <"$torl")" = $((ton + 2)) ] && [ "${#tf[@]}" = 12 ] && [ "${tf[2]}" = repeat ] && [ "${tf[3]}" = "$totree" ] && [ "${tf[6]}" = timeout ] ||
  fail "a timed-out --repeat run appends one runs.log line with tier repeat, its tree and exit timeout: $(tail -n2 "$torl")"
left=$(toleft rep) || fail "a timed-out --repeat run leaves no process of its suite: pids $left"
ok test-timeout-one
fi

if want_any test-timeout-retry test-timeout-quarantine test-scope-stop; then
tr=$tmp/tr
gitinit "$tr"
mkdir -p "$tr/.forge" "$tmp/trsd"
cat >"$tr/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$TR_LOG"
if [ "$1" = q ]; then sleep "${TR_QSLEEP:-0}"; else sleep "${TR_SLEEP:-0}"; fi
EOF
chmod +x "$tr/t.sh"
cat >"$tmp/trsd/systemd-run" <<'EOF'
#!/usr/bin/env bash
[ -z "${TRSD_IGN:-}" ] || trap '' TERM
echo "$*" >>"$TRSD_LOG"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
[ "$*" != true ] || exit 0
s=0
"$@" || s=$?
c=$(head -n1 "$TRSD_CODES")
sed -i 1d "$TRSD_CODES"
exit "${c:-$s}"
EOF
cat >"$tmp/trsd/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TRSC_LOG"
[ "$2" != stop ] || [ -z "${TRSC_STOP_FAIL:-}" ] || { echo "$TRSC_STOP_FAIL" >&2; exit 5; }
[ "$2" = show ] || exit 0
r=$(head -n1 "$TRSC_RES")
sed -i 1d "$TRSC_RES"
echo "${r:-success}"
EOF
chmod +x "$tmp"/trsd/*
export TR_LOG=$tmp/tr.log TRSD_LOG=$tmp/trsd.log TRSC_LOG=$tmp/trsc.log TRSD_CODES=$tmp/trsd.codes TRSC_RES=$tmp/trsc.res
trdoc() { printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh all`' '- Test: `./t.sh one {test}`' '- Timeout: `1`' "$@" >"$tr/.forge/TESTING.md"; git -C "$tr" add -A && git -C "$tr" commit -q --allow-empty -m doc; }
trgo() { local s=0; : >"$TR_LOG"; : >"$TRSD_LOG"; : >"$TRSC_LOG"; printf '%b' "$2" >"$TRSD_CODES"; printf '%b' "$3" >"$TRSC_RES"; PATH=$1$PATH FORGE_TEST_MIN_SECS=$4 timeout -k 5 --preserve-status 60 "$forge" test "${@:5}" "$tr" >"$tmp/out" 2>"$tmp/err" || s=$?; echo $s; }
trrun() { trgo "$tmp/trsd:" "$@"; }
trall() { cat "$tmp/out" "$tmp/err"; echo "systemd-run:"; cat "$TRSD_LOG"; echo "systemctl:"; cat "$TRSC_LOG"; echo "ran:"; cat "$TR_LOG"; }
trscopes() { grep -- '^--user --scope --quiet --unit=' "$TRSD_LOG" || true; }
trlim() { [[ $1 == "--user --scope --quiet"*" --expand-environment=no -p ${2:-MemoryMax=4G -p MemoryHigh=3774873K} -p MemorySwapMax=0 -- "* && $1 != *CPUWeight* && $1 != *RuntimeMaxSec* && $1 != *TimeoutStopSec* ]]; }
trreset() {
  local u n m
  for u in $(sed -n 's/.*--unit=\([^ ]*\).*/\1/p' "$TRSD_LOG"); do
    n=$(grep -nxF -- "--user show -p Result --value $u.scope" "$TRSC_LOG" | head -n1 | cut -d: -f1)
    m=$(grep -nxF -- "--user reset-failed $u.scope" "$TRSC_LOG" | head -n1 | cut -d: -f1)
    [ -n "$n" ] && [ -n "$m" ] && [ "$n" -lt "$m" ] || return 1
  done
}
trtree() { git -C "$tr" rev-parse HEAD^{tree}; }
trst=$tr/.git/forge-test
trps=$trst/$hid
trrl=$trst/runs.log
trline="forge: tests timed out after 1 min (limit from - Timeout: in $tr/.forge/TESTING.md), log $tr/.git/forge-test.log"
fi

if want test-timeout-retry; then
trdoc
mkdir -p "$trps/changed" && : >"$trps/$(trtree)" && echo >"$trps/changed/$(trtree)"
trt0=$SECONDS
trs=$(TRSD_IGN=1 TR_SLEEP=60 trrun '' '' 1 --force)
trel=$((SECONDS - trt0))
[ "$trs" = 124 ] || fail "a capped run whose command ignores TERM past its 1 s limit is ended by the KILL 10 s later and exits 124, got $trs: $(trall)"
[ "$trel" -ge 10 ] && [ "$trel" -le 40 ] || fail "a TERM-ignoring run ends at its limit plus the 10 s KILL delay, took $trel s: $(trall)"
[ "$(cat "$TR_LOG")" = all ] && [ "$(trscopes | wc -l)" = 1 ] || fail "a TERM-ignoring run KILLed at its deadline is never retried as a memory kill: $(trall)"
grep -qxF "$trline" "$tmp/err" || fail "a capped timeout prints '$trline' on stderr: $(trall)"
! grep -qF "killed for memory" "$tmp/out" "$tmp/err" && ! grep -qF "tests passed" "$tmp/out" "$tmp/err" && ! grep -qF "tests failed" "$tmp/out" "$tmp/err" || fail "a capped timeout is no memory kill, no failure line and no pass: $(trall)"
trreset || fail "the timed-out scope's Result is read before reset-failed: $(trall)"
trlim "$(sed -n 1p "$TRSD_LOG")" && [[ $(sed -n 1p "$TRSD_LOG") == *" -- true" ]] || fail "the probe carries only the memory properties, no RuntimeMaxSec, TimeoutStopSec or CPUWeight: $(trall)"
trlim "$(trscopes)" || fail "the suite scope carries only the memory properties, no RuntimeMaxSec, TimeoutStopSec or CPUWeight: $(trall)"
[ "$(tail -n1 "$trrl" 2>/dev/null | cut -d' ' -f7)" = timeout ] || fail "a capped timeout appends a runs.log line with exit timeout: $(tail -n1 "$trrl" 2>/dev/null)"
[ ! -e "$trps/$(trtree)" ] && [ ! -e "$trps/changed/$(trtree)" ] || fail "a capped timeout removes the tree's pass stamps: $(ls "$trps" "$trps/changed")"
[ ! -e "$trst/failed/$(trtree)-all.log" ] || fail "a capped timeout writes no failed log: $(ls "$trst/failed")"
trs=$(trrun '137\n' 'timeout\n' 30 --force)
[ "$trs" = 0 ] && [ "$(paste -sd, "$TR_LOG")" = all,all ] && [ "$(trscopes | wc -l)" = 2 ] && ! grep -qF "timed out" "$tmp/err" ||
  fail "a scope exiting 137 before its deadline is a memory kill and retried, whatever its Result, got $trs: $(trall)"
trn=$(wc -l <"$trrl")
trs=$(TR_SLEEP=60 trrun '' '' 1 --one x)
[ "$trs" = 124 ] || fail "a capped --one past its 1 s limit exits 124, got $trs: $(trall)"
[ "$(cat "$TR_LOG")" = one ] && [ "$(trscopes | wc -l)" = 1 ] && grep -qxF "$trline" "$tmp/err" && ! grep -qF "killed for memory" "$tmp/err" || fail "a timed-out capped --one is not retried and prints the timeout line: $(trall)"
trlim "$(trscopes)" "MemoryMax=2097152K -p MemoryHigh=1887436K" && trreset || fail "the --one scope carries its narrow MemoryMax=2097152K and MemoryHigh=1887436K and no RuntimeMaxSec, and its Result is read before reset-failed: $(trall)"
[ "$(wc -l <"$trrl")" = $((trn + 1)) ] && [ "$(tail -n1 "$trrl" | wc -w)" = 12 ] && [ "$(tail -n1 "$trrl" | cut -d' ' -f3,7)" = "one timeout" ] ||
  fail "a timed-out capped --one appends one runs.log line with tier one and exit timeout: $(tail -n2 "$trrl")"
trs=$(TR_SLEEP=60 trrun '' '' 1 --one x --repeat 3)
[ "$trs" = 124 ] && [ "$(cat "$TR_LOG")" = one ] && grep -qxF "$trline" "$tmp/err" && grep -qxF "forge: repeat failed on iteration 1/3" "$tmp/err" ||
  fail "a capped --repeat iteration past its limit exits 124 with the timeout and repeat failed lines, got $trs: $(trall)"
trlim "$(trscopes)" || fail "the --repeat scope carries no RuntimeMaxSec: $(trall)"
trs=$(TR_SLEEP=3 trrun '137\n' 'oom-kill\n' 30 --force)
[ "$trs" = 0 ] && [ "$(paste -sd, "$TR_LOG")" = all,all ] && [ "$(trscopes | wc -l)" = 2 ] || fail "a memory-killed run is retried once and passes, got $trs: $(trall)"
trlim "$(trscopes | sed -n 1p)" && trlim "$(trscopes | sed -n 2p)" || fail "the first attempt and the retry carry the same memory properties and no RuntimeMaxSec: $(trall)"
trs=$(TR_SLEEP=6 trrun '137\n' 'oom-kill\n' 2 --force)
[ "$trs" = 124 ] && [ "$(cat "$TR_LOG")" = all ] && [ "$(trscopes | wc -l)" = 1 ] && grep -qxF "$trline" "$tmp/err" && ! grep -qF "killed for memory" "$tmp/err" ||
  fail "a run stopped at its deadline is a timeout without a second attempt, even with a Result of oom-kill, got $trs: $(trall)"
[ "$(tail -n1 "$trrl" | cut -d' ' -f7)" = timeout ] || fail "a run stopped at its deadline logs exit timeout: $(tail -n1 "$trrl")"
ok test-timeout-retry
fi

if want test-timeout-quarantine; then
trdoc "- Quarantine (added $(date +%F)): \`./t.sh q\`"
trs=$(TR_QSLEEP=60 trrun '' '' 1 --force)
[ "$trs" = 0 ] && [ "$(paste -sd, "$TR_LOG")" = all,q ] || fail "a capped run whose Quarantine command outlives its limit still passes, got $trs: $(trall)"
grep -qxF 'forge: quarantine failed (exit 124); not gating' "$tmp/err" && [ "$(tail -n1 "$tmp/out")" = "forge: tests passed ($(git -C "$tr" rev-parse --short "$(trtree)"))" ] && ! grep -qF "timed out" "$tmp/err" ||
  fail "a capped Quarantine timeout prints the quarantine failure with exit 124, no timeout line, and the pass line: $(trall)"
[ -e "$trps/$(trtree)" ] && [ "$(tail -n1 "$trrl" | cut -d' ' -f7)" = 0 ] || fail "a capped Quarantine timeout keeps the full run's pass stamp and runs.log exit 0: $(tail -n1 "$trrl")"
trlim "$(grep -- '--unit=forge-test-[0-9]*-q ' "$TRSD_LOG")" || fail "the Quarantine scope carries no CPUWeight and no RuntimeMaxSec: $(trall)"
trs=$(TR_QSLEEP=600 trgo "" "" "" 2 --force)
[ "$trs" = 0 ] && [ "$(paste -sd, "$TR_LOG")" = all,q ] || fail "an uncapped run whose Quarantine command outlives its limit still passes, got $trs: $(trall)"
grep -qxF 'forge: quarantine failed (exit 124); not gating' "$tmp/err" && [ "$(tail -n1 "$tmp/out")" = "forge: tests passed ($(git -C "$tr" rev-parse --short "$(trtree)"))" ] && [ -e "$trps/$(trtree)" ] ||
  fail "an uncapped Quarantine timeout prints the quarantine failure with exit 124, the pass line and keeps the stamp: $(trall)"
ok test-timeout-quarantine
fi

if want test-scope-stop; then
trunit() { trscopes | sed -n "${1}s/.*--unit=\([^ ]*\).*/\1/p"; }
trstop() {
  local u n k m
  u=$(trscopes | sed -n 's/.*--unit=\([^ ]*\).*/\1/p')
  [ -n "$u" ] || return 1
  for u in $u; do
    n=$(grep -nxF -- "--user show -p Result --value $u.scope" "$TRSC_LOG" | head -n1 | cut -d: -f1)
    k=$(grep -nxF -- "--user stop $u.scope" "$TRSC_LOG" | head -n1 | cut -d: -f1)
    m=$(grep -nxF -- "--user reset-failed $u.scope" "$TRSC_LOG" | head -n1 | cut -d: -f1)
    [ -n "$n" ] && [ -n "$k" ] && [ -n "$m" ] && [ "$n" -lt "$k" ] && [ "$k" -lt "$m" ] || return 1
  done
}
trlog=$tr/.git/forge-test.log
trsf="trsc: stop refused"
trdoc
trs=$(trrun '0\n' '' 30 --force)
[ "$trs" = 0 ] && [[ $(trunit 1) =~ ^forge-test-[0-9]+-1$ ]] && trstop ||
  fail "a passing capped run stops its scope forge-test-<pid>-1.scope after its runner returns and its Result is read, before reset-failed, got $trs: $(trall)"
trs=$(trrun '3\n' '' 30 --force)
trf=$trs
[ "$trs" != 0 ] && [[ $(trunit 1) =~ ^forge-test-[0-9]+-1$ ]] && trstop ||
  fail "a failing capped run stops its scope forge-test-<pid>-1.scope after its runner returns and its Result is read, before reset-failed, got $trs: $(trall)"
trs=$(trrun '137\n' 'oom-kill\n' 30 --force)
[ "$trs" = 0 ] && [ "$(trscopes | wc -l)" = 2 ] && [[ $(trunit 2) =~ ^forge-test-[0-9]+-2$ ]] && trstop ||
  fail "a memory-killed run stops both its first scope and its retry's scope, each after its Result is read and before reset-failed, got $trs: $(trall)"
trs=$(TRSC_STOP_FAIL=$trsf trrun '0\n' '' 30 --force)
[ "$trs" = 0 ] && trstop && grep -qxF "$trsf" "$trlog" ||
  fail "a scope that fails to stop is logged in the run log $trlog and the passing run still exits 0, got $trs: $(trall) log: $(cat "$trlog" 2>/dev/null)"
trs=$(TRSC_STOP_FAIL=$trsf trrun '3\n' '' 30 --force)
[ "$trs" = "$trf" ] && trstop && grep -qxF "$trsf" "$trlog" ||
  fail "a failing run whose scope fails to stop logs the stop error in $trlog and keeps its exit $trf, got $trs: $(trall) log: $(cat "$trlog" 2>/dev/null)"
trdoc "- Quarantine (added $(date +%F)): \`./t.sh q\`"
trs=$(trrun '0\n0\n' '' 30 --force)
[ "$trs" = 0 ] && [ "$(paste -sd, "$TR_LOG")" = all,q ] && [[ $(trunit 2) =~ ^forge-test-[0-9]+-q$ ]] && trstop ||
  fail "the Quarantine run stops its scope forge-test-<pid>-q.scope after its Result is read and before reset-failed, got $trs: $(trall)"
trdoc
: >"$TR_LOG"
: >"$TRSD_LOG"
: >"$TRSC_LOG"
: >"$TRSD_CODES"
: >"$TRSC_RES"
PATH=$tmp/trsd:$PATH FORGE_TEST_MIN_SECS=30 TR_SLEEP=30 "$forge" test --force "$tr" >"$tmp/out" 2>"$tmp/err" &
trp=$!
for _ in $(seq 100); do [ ! -s "$TR_LOG" ] || break; sleep 0.1; done
[ -s "$TR_LOG" ] || { kill "$trp" 2>/dev/null || :; fail "the run to be TERMed starts its suite: $(trall)"; }
kill -TERM "$trp"
trs=0
wait "$trp" || trs=$?
[ "$trs" = 143 ] && grep -qE -- "^--user stop (.+ )?forge-test-$trp-(1|\*)\.scope( |$)" "$TRSC_LOG" ||
  fail "a TERMed capped run exits 143 and stops its scope forge-test-$trp-1.scope, got $trs: $(trall)"
ok test-scope-stop
fi

if want test-timeout-scope; then
trlim() { [[ $1 == "--user --scope --quiet"*" --expand-environment=no -p ${2:-MemoryMax=4G -p MemoryHigh=3774873K} -p MemorySwapMax=0 -- "* && $1 != *CPUWeight* && $1 != *RuntimeMaxSec* && $1 != *TimeoutStopSec* ]]; }
ts=$tmp/ts
gitinit "$ts"
mkdir -p "$ts/.forge" "$tmp/tssd"
printf '%s\n' "# Testing" "" "## Commands" '- All tests: `./t.sh`' '- Timeout: `1`' >"$ts/.forge/TESTING.md"
cat >"$ts/t.sh" <<'EOF'
#!/usr/bin/env bash
setsid bash -c 'echo $$ >"$1"; exec sleep 600' _ "$TS_CHILD" </dev/null &
trap '' TERM
sleep 600 &
sleep 600
EOF
chmod +x "$ts/t.sh"
git -C "$ts" add -A && git -C "$ts" commit -q -m init
export TS_XDG=/run/user/$(id -u) TSSD_LOG=$tmp/tssd.log TSSC_LOG=$tmp/tssc.log TS_CHILD=$tmp/ts.child TS_SYSTEMD_RUN= TS_SYSTEMCTL=
for d in "${dirs[@]}"; do
  [ -n "$TS_SYSTEMD_RUN" ] || [ ! -x "$d/systemd-run" ] || TS_SYSTEMD_RUN=$d/systemd-run
  [ -n "$TS_SYSTEMCTL" ] || [ ! -x "$d/systemctl" ] || TS_SYSTEMCTL=$d/systemctl
done
cat >"$tmp/tssd/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TSSD_LOG"
XDG_RUNTIME_DIR=$TS_XDG exec "$TS_SYSTEMD_RUN" "$@"
EOF
cat >"$tmp/tssd/systemctl" <<'EOF'
#!/usr/bin/env bash
s=0
o=$(XDG_RUNTIME_DIR=$TS_XDG "$TS_SYSTEMCTL" "$@") || s=$?
echo "$* => $o" >>"$TSSC_LOG"
[ -z "$o" ] || echo "$o"
exit $s
EOF
chmod +x "$tmp"/tssd/*
tsleft() {
  local p= d=$1
  while :; do
    p=$(grep -lzxsF "TS_RUN=$tmp/ts-run" /proc/[0-9]*/environ | cut -d/ -f3 | paste -sd' ')
    [ -n "$p" ] || return 0
    [ "$(date +%s)" -lt "$d" ] || break
    sleep 0.2
  done
  kill -KILL $p 2>/dev/null || :
  echo "$p"
  return 1
}
if [ -z "$TS_SYSTEMD_RUN" ] || [ -z "$TS_SYSTEMCTL" ] || ! PATH=$tmp/tssd:$PATH systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
  echo "$suite test-timeout-scope: skipped, no reachable user manager"
else
  : >"$TSSD_LOG"; : >"$TSSC_LOG"; rm -f "$TS_CHILD"
  tst0=$(date +%s)
  tss=0
  PATH=$tmp/tssd:$PATH TS_RUN=$tmp/ts-run FORGE_TEST_MIN_SECS=3 timeout -k 5 --preserve-status 90 "$forge" test --force "$ts" >"$tmp/out" 2>"$tmp/err" || tss=$?
  left=$(tsleft $((tst0 + 3 + 10 + 15))) || fail "a real scope past its 3 s limit leaves no process, the TERM-ignoring group members and the setsid child included, within the limit plus the 10 s KILL delay and a 15 s margin: pids $left: $(cat "$tmp/out" "$tmp/err" "$TSSD_LOG" "$TSSC_LOG")"
  tsel=$(($(date +%s) - tst0))
  [ -s "$TS_CHILD" ] || fail "the setsid child started: $(cat "$tmp/out" "$tmp/err")"
  [ "$tss" = 124 ] || fail "a real scope past its limit exits 124, got $tss: $(cat "$tmp/out" "$tmp/err" "$TSSD_LOG" "$TSSC_LOG")"
  grep -qxF "forge: tests timed out after 1 min (limit from - Timeout: in $ts/.forge/TESTING.md), log $ts/.git/forge-test.log" "$tmp/err" || fail "a real scope timeout prints the timeout line: $(cat "$tmp/out" "$tmp/err")"
  [ "$tsel" -ge 3 ] && [ "$tsel" -le 28 ] || fail "a real scope timeout ends between the 3 s limit and the limit plus 10 s plus a 15 s margin, took $tsel s"
  tsu=$(sed -n 's/.*--unit=\(forge-test-[^ ]*\).*/\1/p' "$TSSD_LOG" | head -n1)
  [ -n "$tsu" ] && trlim "$(grep -- "--unit=$tsu " "$TSSD_LOG")" || fail "the real scope carries only the memory properties, no CPUWeight, RuntimeMaxSec or TimeoutStopSec: $(cat "$TSSD_LOG")"
  n=$(grep -nF -- "--user show -p Result --value $tsu.scope =>" "$TSSC_LOG" | head -n1 | cut -d: -f1)
  k=$(grep -nF -- "--user stop $tsu.scope =>" "$TSSC_LOG" | head -n1 | cut -d: -f1)
  m=$(grep -nF -- "--user reset-failed $tsu.scope =>" "$TSSC_LOG" | head -n1 | cut -d: -f1)
  [ -n "$n" ] && [ -n "$k" ] && [ -n "$m" ] && [ "$n" -lt "$k" ] && [ "$k" -lt "$m" ] || fail "the real scope's Result is read, then the scope stopped, then reset: $(cat "$TSSC_LOG")"
  [ "$(tail -n1 "$ts/.git/forge-test/runs.log" | cut -d' ' -f7)" = timeout ] || fail "a real scope timeout logs exit timeout: $(tail -n1 "$ts/.git/forge-test/runs.log")"
  [ "$(sed -n 's/.*--unit=\(forge-test-[^ ]*\).*/\1/p' "$TSSD_LOG" | wc -l)" = 1 ] && ! grep -qF "killed for memory" "$tmp/err" || fail "a real scope timeout is not retried: $(cat "$tmp/err" "$TSSD_LOG" "$TSSC_LOG")"
fi
ok test-timeout-scope
fi

if want test; then
[ "$(git -C "$r" rev-parse --show-toplevel)" = "$r" ] || fail "the suite's temp dir is its physical path, as git's --show-toplevel reports it: $r vs $(git -C "$r" rev-parse --show-toplevel)"
cd "$r/sub"
[ "$(code "$forge" test)" = 0 ] || fail "a passing command exits 0: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests passed ($(short))" ] || fail "pass line: $(lastline)"
grep -qxF "ran in $r" "$log" && [ ! -e "$r/.claude" ] || fail "the command runs in the worktree top, creates no .claude/worktrees/_snap snapshot and logs to the git dir: $(cat "$log")"
[ -f "$r/.git/forge-test/$hid/$(tree)" ] || fail "a pass records a stamp for HEAD's tree"
[ "$(code "$forge" test --passed)" = 0 ] || fail "--passed exits 0 with a stamp and a clean tree: $(cat "$tmp/out")"
echo more >>"$r/a.txt"
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed exits 1 on a dirty tracked file"
grep -q "uncommitted" "$tmp/out" || fail "--passed names the uncommitted changes: $(cat "$tmp/out")"
[ "$(code "$forge" test)" = 0 ] || fail "a dirty tree still runs: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed stays 1 while the tree is dirty"
git -C "$r" commit -q -am more
[ "$(code "$forge" test --passed)" = 0 ] || fail "committing the tested content passes: $(cat "$tmp/out")"
echo again >>"$r/a.txt" && git -C "$r" commit -q -am again
[ "$(code "$forge" test --passed)" = 1 ] || fail "a new untested tree fails --passed"
grep -qF "forge test" "$tmp/out" || fail "--passed says to run forge test: $(cat "$tmp/out")"
echo 3 >"$T_EXIT"
[ "$(code "$forge" test)" = 3 ] || fail "a failing command's exit is forge test's exit"
[ "$(lastline)" = "forge: tests failed, log $log" ] || fail "fail line: $(lastline)"
[ ! -e "$r/.git/forge-test/$hid/$(tree)" ] || fail "a failure records no stamp"
echo 5 >"$T_EXIT"
[ "$(code "$forge" test --force)" = 1 ] || fail "a command exiting 5 exits 1, since 5 means a declared - All tests: none"
echo 75 >"$T_EXIT"
[ "$(code "$forge" test --force)" = 1 ] || fail "a command exiting 75 exits 1, since 75 means a resource exit: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests failed, log $log" ] || fail "a command exiting 75 prints the fail line: $(lastline)"
echo 0 >"$T_EXIT"
[ "$(T_MUTATE=1 code "$forge" test --force)" = 0 ] || fail "a tree changed during the run passes: $(cat "$tmp/out")"
[ "$(lastline)" = "forge: tests passed ($(short))" ] || fail "a tree changed during the run reports the start tree: $(cat "$tmp/out")"
[ -f "$r/.git/forge-test/$hid/$(tree)" ] || fail "a tree changed during the run stamps the start tree"
git -C "$r" checkout -q -- a.txt
echo lib >"$r/lib.txt"
[ "$(code "$forge" test)" = 0 ] || fail "a run with an untracked file passes: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed)" = 1 ] || fail "--passed refuses an untracked file the tests saw: $(cat "$tmp/out")"
git -C "$r" add lib.txt && git -C "$r" commit -q -m lib
[ "$(code "$forge" test --passed)" = 0 ] || fail "the stamp covers the untracked file once committed: $(cat "$tmp/out")"
echo lib2 >"$r/lib.txt" && git -C "$r" commit -q -am lib2
echo lib >"$r/lib.txt"
[ "$(code "$forge" test)" = 0 ] || fail "a run with a reverted file passes: $(cat "$tmp/out")"
git -C "$r" checkout -q -- lib.txt
[ "$(code "$forge" test --passed)" = 1 ] || fail "a stamp is never reused for other content: $(cat "$tmp/out")"
echo staged >"$r/staged.txt" && git -C "$r" add staged.txt
[ "$(code "$forge" test)" = 0 ] || fail "a run with a staged new file passes: $(cat "$tmp/out")"
git -C "$r" commit -q -m staged
[ "$(code "$forge" test --passed)" = 0 ] || fail "the stamp covers files only in the index: $(cat "$tmp/out")"
cd "$tmp"
[ "$(code "$forge" test r)" = 0 ] || fail "a relative dir argument runs there: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed "$r")" = 0 ] || fail "--passed takes a dir"
git -C "$r" worktree add -q "$tmp/w" -b side
[ "$(code "$forge" test --passed "$tmp/w")" = 0 ] || fail "a linked worktree on the same tree shares the stamp: $(cat "$tmp/out")"
echo 3 >"$T_EXIT"
[ "$(code "$forge" test --force "$tmp/w")" = 3 ] || fail "failing run in the linked worktree"
[ "$(lastline)" = "forge: tests failed, log $r/.git/worktrees/w/forge-test.log" ] || fail "a linked worktree logs to its own git dir: $(lastline)"
[ "$(code "$forge" test a b)" = 2 ] || fail "two dirs is a usage error"
mkdir -p "$tmp/none/.forge" && gitinit "$tmp/none" && echo '# Testing' >"$tmp/none/.forge/TESTING.md"
git -C "$tmp/none" add -A && git -C "$tmp/none" commit -q -m init
[ "$(code "$forge" test "$tmp/none")" = 6 ] || fail "no All tests line exits 6"
[ "$(cat "$tmp/out")" = "forge: no \"- All tests:\" line in $tmp/none/.forge/TESTING.md; add a command or \"- All tests: none\"" ] || fail "names the missing line and the fix: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed "$tmp/none")" = 6 ] || fail "--passed without an All tests line exits 6: $(cat "$tmp/out")"
grep -qF "no \"- All tests:\" line" "$tmp/out" || fail "--passed names the missing line: $(cat "$tmp/out")"
rm "$tmp/none/.forge/TESTING.md"
[ "$(code "$forge" test "$tmp/none")" = 6 ] || fail "no TESTING.md exits 6: $(cat "$tmp/out")"
mkdir -p "$tmp/plain"
[ "$(code "$forge" test "$tmp/plain")" = 1 ] || fail "outside git exits 1"
grep -qF -- "- All tests:" "$root/templates/TESTING.md" || fail "the TESTING template shows the All tests line"
o=$tmp/own
mkdir -p "$o/.forge" "$o/tests" && gitinit "$o"
cp "$root/.forge/TESTING.md" "$o/.forge/"
cp "$root/tests/forge.test.sh" "$o/tests/"
printf '#!/usr/bin/env bash\nexit 1\n' >"$o/tests/a.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$o/tests/b.test.sh"
chmod +x "$o"/tests/*.sh
git -C "$o" add -A && git -C "$o" commit -q -m init
[ "$(code "$forge" test "$o")" != 0 ] && grep -q '^FAIL a (exit 1, ' "$o/.git/forge-test.log" || fail "forge's own All tests command fails when a suite fails: $(cat "$tmp/out" "$o/.git/forge-test.log")"
ok test
fi

if want test-snap-owner; then
cd "$tmp"
kp=$tmp/keep
gitinit "$kp"
echo a1 >"$kp/a.txt" && git -C "$kp" add -A && git -C "$kp" commit -q -m init && echo .claude/worktrees/ >>"$kp/.git/info/exclude"
kw=$tmp/keep-wt
git -C "$kp" worktree add -q "$kw" -b side
kk=$(skey "$kp") kk2=$(skey "$kw")
[[ $kk =~ ^k[0-9a-f]{12}$ ]] || fail "the snapshot key is k plus 12 hex: $kk"
kd=$kp/.claude/worktrees/_snap
ks=$kd/$kk
kadm=$kp/.git/worktrees/$kk
kown=$kp/.git/forge-test/snap-owner
kwts() { git -C "$kp" worktree list --porcelain | sed -n 's/^worktree //p' | sort | paste -sd' '; }
kwant() { printf '%s\n' "$@" | sort | paste -sd' '; }
ksnap() { git -C "$kp" worktree add -q --detach "$kd/$1" HEAD && mkdir -p "$kown" && echo "$2" >"$kown/$1" && : >"$kown/$1.lock" || fail "the left-over snapshot $kd/$1 owned by $2 is set up"; }
kfn() { bash -c 'set -euo pipefail; shopt -s nullglob; for m in "$1"/bin/forge.d/*.sh; do . "$m"; done; s=0; "${@:2}" || s=$?; echo "returned $s"' _ "$root" "$@" >"$tmp/out" 2>"$tmp/err"; }
ksnap "$kk" "$kp/.git"
ksnap "$kk2" "$kp/.git/worktrees/keep-wt"
mkdir -p "$ks/build-x" && echo built >"$ks/build-x/marker"
echo s1 >"$kown/$kk.deps" && echo s2 >"$kown/$kk2.deps"
bash -c : & kdead=$!
wait "$kdead"
git -C "$kp" worktree add -q --detach "$kd/$kdead" HEAD && git -C "$kp" worktree add -q --detach "$kd/$$" HEAD || fail "the snapshots of dead pid $kdead and live pid $$ are set up"
mkdir -p "$kp/.git/forge-test/snap/$kdead" && : >"$kp/.git/forge-test/snap/$kdead/f"
exec {kfd}>>"$kown/$kk.lock" && flock -n "$kfd" || fail "the test holds the lock $kown/$kk.lock"
kfn snap_prune "$kp"
[ "$(cat "$tmp/out")" = "returned 0" ] || fail "snap_prune beside a held lock and a live pid returns 0: $(cat "$tmp/out" "$tmp/err")"
[ ! -e "$kd/$kk2" ] && [ ! -e "$kp/.git/worktrees/$kk2" ] && [ ! -e "$kown/$kk2" ] && [ ! -e "$kown/$kk2.deps" ] && [ ! -e "$kown/$kk2.lock" ] || fail "snap_prune drops the k-keyed snapshot $kd/$kk2 whose lock is free, with its registration and snap-owner files, though its owner worktree $kw still exists: $(ls -A "$kd" "$kp/.git/worktrees" "$kown" 2>&1)"
[ "$(cat "$ks/build-x/marker" 2>/dev/null)" = built ] && [ "$(cat "$kown/$kk" 2>/dev/null)" = "$kp/.git" ] && [ "$(cat "$kown/$kk.deps" 2>/dev/null)" = s1 ] && [ -f "$kown/$kk.lock" ] || fail "snap_prune keeps the k-keyed snapshot $ks whose lock is held, with snap-owner/: $(ls -A "$ks" "$kown" 2>&1)"
[ ! -e "$kd/$kdead" ] && [ -d "$kd/$$" ] || fail "snap_prune drops the snapshot of dead pid $kdead and keeps the one of live pid $$: $(ls -A "$kd")"
[ ! -e "$kp/.git/forge-test/snap" ] || fail "snap_prune removes the legacy forge-test/snap dir: $(ls -A "$kp/.git/forge-test/snap")"
[ "$(kwts)" = "$(kwant "$kp" "$kw" "$ks" "$kd/$$")" ] || fail "after snap_prune only W, its linked worktree and the kept snapshots stay registered: $(kwts)"
exec {kfd}>&-
kfn snap_prune "$kp"
[ "$(cat "$tmp/out")" = "returned 0" ] || fail "snap_prune once the lock is free returns 0: $(cat "$tmp/out" "$tmp/err")"
[ ! -e "$ks" ] && [ ! -e "$kadm" ] && [ ! -e "$kown" ] || fail "once its lock is free snap_prune drops $ks, its registration and the whole snap-owner dir: $(ls -A "$kd" "$kown" 2>&1)"
[ "$(kwts)" = "$(kwant "$kp" "$kw" "$kd/$$")" ] && [ "$(ls -A "$kd")" = "$$" ] || fail "after the full sweep only W, its linked worktree and the live pid's snapshot stay: $(kwts) $(ls -A "$kd")"
git -C "$kp" worktree remove --force "$kd/$$"
kk3=$(skey "$kw")
ksnap "$kk3" "$kp/.git/worktrees/keep-wt"
mkdir -p "$kp/.forge" && printf '# Testing\n\n## Commands\n- All tests: `true`\n' >"$kp/.forge/TESTING.md"
[ "$(code "$forge" test --force "$kp")" = 0 ] || fail "a run beside a left-over k-keyed snapshot passes: $(cat "$tmp/out")"
[ ! -e "$kd/$kk3" ] && [ ! -e "$kown" ] && [ "$(kwts)" = "$(kwant "$kp" "$kw")" ] || fail "the next forge test sweeps the k-keyed snapshot $kd/$kk3 and snap-owner/: $(kwts) $(ls -A "$kd" "$kown" 2>&1)"
rm -rf "$kp/.forge"
ksnap "$kk" "$kp/.git"
echo s1 >"$kown/$kk.deps"
kfn snap_drop "$kp/.git" "$ks"
[ "$(cat "$tmp/out")" = "returned 0" ] && [ ! -e "$ks" ] && [ ! -e "$kadm" ] || fail "snap_drop removes the snapshot $ks and its admin dir $kadm: $(cat "$tmp/out" "$tmp/err") $(ls -A "$kd" "$kp/.git/worktrees" 2>&1)"
[ ! -e "$kown/$kk" ] && [ ! -e "$kown/$kk.deps" ] || fail "snap_drop removes the owner record $kown/$kk and deps stamp $kown/$kk.deps: $(ls -A "$kown")"
ok test-snap-owner
fi

if want test-host; then
cd "$tmp"
h=$tmp/host
gitinit "$h" && mkdir -p "$h/.forge"
printf '# Testing\n\n## Commands\n- All tests: `./t.sh`\n- Changed tests: `./t.sh {files}`\n' >"$h/.forge/TESTING.md"
printf '#!/usr/bin/env bash\necho ran >>"$H_RAN"\nexit "${H_EXIT:-0}"\n' >"$h/t.sh" && chmod +x "$h/t.sh"
echo a >"$h/a.txt"
git -C "$h" add -A && git -C "$h" commit -q -m init
export H_RAN=$tmp/host.ran
hs=$h/.git/forge-test hk=0123456789abcdef0123456789abcdef
[ "$hk" != "$hid" ] || hk=fedcba9876543210fedcba9876543210
htree() { git -C "$h" rev-parse HEAD^{tree}; }
hshort() { git -C "$h" rev-parse --short HEAD^{tree}; }
hran() { [ -f "$H_RAN" ] && wc -l <"$H_RAN" || echo 0; }
[[ $hid =~ ^[0-9a-f]{32}$ ]] || fail "/etc/machine-id holds a 32-hex host id: $hid"
mkdir -p "$hs/$hk/changed" && : >"$hs/$hk/$(htree)" && git -C "$h" rev-parse HEAD >"$hs/$hk/changed/$(htree)"
[ "$(code "$forge" test --passed "$h")" = 1 ] || fail "--passed ignores a full stamp under another host's id: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed --changed "$h")" = 1 ] || fail "--passed --changed ignores a changed stamp under another host's id: $(cat "$tmp/out")"
[ "$(code env machine_id="$hk" "$forge" test --passed "$h")" = 1 ] || fail "an inherited machine_id never selects another host's stamps over /etc/machine-id: $(cat "$tmp/out")"
[ "$(code "$forge" test "$h")" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(hshort))" ] && [ "$(hran)" = 1 ] || fail "a stamp under another host's id runs the suite with no cached pass: $(cat "$tmp/out") ran $(hran)"
[ -f "$hs/$hid/$(htree)" ] || fail "a pass records its stamp under <git common dir>/forge-test/<machine-id>/<tree>: $(find "$hs" -type f)"
[ "$(code "$forge" test --passed "$h")" = 0 ] || fail "--passed accepts this host's stamp: $(cat "$tmp/out")"
echo n >"$h/NOTES.md" && git -C "$h" add -A && git -C "$h" commit -q -m notes
rm -rf "$hs/$hid"
[ "$(code "$forge" test --passed "$h")" = 1 ] || fail "--passed never carries a docs-only change over another host's stamp: $(cat "$tmp/out")"
[ "$(code "$forge" test "$h")" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(hshort))" ] && [ "$(hran)" = 2 ] || fail "a docs-only change over another host's stamp runs the suite: $(cat "$tmp/out") ran $(hran)"
echo b >>"$h/a.txt" && git -C "$h" commit -q -am b
mkdir -p "$hs/changed" && : >"$hs/$(htree)" && git -C "$h" rev-parse HEAD >"$hs/changed/$(htree)"
[ "$(code "$forge" test --passed "$h")" = 1 ] || fail "--passed ignores an old unkeyed full stamp: $(cat "$tmp/out")"
[ "$(code "$forge" test --passed --changed "$h")" = 1 ] || fail "--passed --changed ignores an old unkeyed changed stamp: $(cat "$tmp/out")"
[ "$(code "$forge" test "$h")" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(hshort))" ] && [ "$(hran)" = 3 ] || fail "an old unkeyed stamp runs the suite with no cached pass: $(cat "$tmp/out") ran $(hran)"
[ -f "$hs/$(htree)" ] && [ -f "$hs/changed/$(htree)" ] || fail "old unkeyed stamps stay on disk: $(find "$hs" -type f)"
[ -f "$hs/$hid/$(htree)" ] || fail "a pass over an old unkeyed stamp records this host's stamp: $(find "$hs" -type f)"
[ "$(code "$forge" test "$h")" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(hshort)), cached" ] && [ "$(hran)" = 3 ] || fail "this host's stamp gives the cached pass: $(cat "$tmp/out") ran $(hran)"
echo c >>"$h/a.txt" && git -C "$h" commit -q -am c
mkdir -p "$hs/$hid" && : >"$hs/$hid/$(htree)"
[ "$(code "$forge" test "$h")" = 0 ] && [ "$(lastline)" = "forge: tests passed ($(hshort)), cached" ] && [ "$(hran)" = 3 ] || fail "a stamp under this host's /etc/machine-id dir gives the cached pass: $(cat "$tmp/out") ran $(hran)"
[ "$(code "$forge" test --passed "$h")" = 0 ] || fail "--passed accepts a stamp under this host's id: $(cat "$tmp/out")"
mkdir -p "$hs/$hid/changed" && git -C "$h" rev-parse HEAD >"$hs/$hid/changed/$(htree)"
: >"$hs/$(htree)"
[ "$(H_EXIT=3 code "$forge" test --force "$h")" = 3 ] || fail "a failing --force run exits with its code: $(cat "$tmp/out")"
[ ! -e "$hs/$hid/$(htree)" ] && [ ! -e "$hs/$hid/changed/$(htree)" ] || fail "a failure removes this host's pass stamps of the tree: $(find "$hs" -type f)"
[ -f "$hs/$(htree)" ] || fail "a failure leaves an old unkeyed stamp on disk: $(find "$hs" -type f)"
ok test-host
fi

if want test-setup-host; then
cd "$tmp"
u=$tmp/setup-host
gitinit "$u" && mkdir -p "$u/.forge"
printf '# Testing\n\n## Commands\n- Setup: `./setup.sh`\n- All tests: `./t.sh all`\n- Test: `./t.sh {test}`\n' >"$u/.forge/TESTING.md"
printf '#!/usr/bin/env bash\necho "setup $PWD" >>"$U_LOG"\n' >"$u/setup.sh"
printf '#!/usr/bin/env bash\necho "t $*" >>"$U_LOG"\n' >"$u/t.sh"
chmod +x "$u/setup.sh" "$u/t.sh"
git -C "$u" add -A && git -C "$u" commit -q -m init
export U_LOG=$tmp/setup-host.log
ust=$u/.git/forge-setup
urun() { : >"$U_LOG"; [ "$(code "$forge" test --one a "$u")" = 0 ] || fail "$1 passes: $(cat "$tmp/out")"; paste -sd, "$U_LOG"; }
mfs=(package.json package-lock.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock pyproject.toml uv.lock poetry.lock 'requirements*.txt' Cargo.toml Cargo.lock go.mod go.sum)
shash() { { echo "$2" && (cd "$1" && git ls-files -z -co --exclude-standard -- "${mfs[@]/#/:(glob)**/}" | LC_ALL=C sort -zu | xargs -0r sha256sum --); } | sha256sum | cut -d' ' -f1; }
ush=$(shash "$u" ./setup.sh)
[ "$(urun "a first Setup")" = "setup $u,t a" ] || fail "a missing setup stamp runs Setup once, in the worktree: $(cat "$U_LOG")"
[ "$(cat "$ust")" = "$hid $ush" ] || fail "a Setup in the worktree writes <git dir>/forge-setup with this host's id and the manifests hash: $(cat "$ust" 2>&1)"
[ "$(urun "a second run")" = "t a" ] || fail "the stamp a worktree Setup wrote skips Setup in the next run: $(cat "$U_LOG")"
echo "$hk $ush" >"$ust"
[ "$(urun "a Setup under another host's id")" = "setup $u,t a" ] || fail "a setup stamp holding another host's id and this hash reruns Setup in the worktree: $(cat "$U_LOG")"
[ "$(cat "$ust")" = "$hid $ush" ] || fail "a worktree Setup over another host's stamp rekeys it to this host: $(cat "$ust")"
echo "$ush" >"$ust"
[ "$(urun "a bare-hash Setup")" = "setup $u,t a" ] || fail "a bare-hash setup stamp from before host keys reruns Setup in the worktree: $(cat "$U_LOG")"
[ "$(cat "$ust")" = "$hid $ush" ] || fail "a worktree Setup over a bare hash rekeys it to this host: $(cat "$ust")"
echo "$hid $ush" >"$ust"
[ "$(urun "a keyed Setup")" = "t a" ] || fail "a setup stamp holding this host's id and the manifests hash skips Setup: $(cat "$U_LOG")"
[ "$(cat "$ust")" = "$hid $ush" ] || fail "a skipped Setup leaves the stamp as it was: $(cat "$ust")"
ok test-setup-host
fi

finish
