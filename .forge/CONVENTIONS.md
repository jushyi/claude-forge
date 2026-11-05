# Conventions

## Patterns
- Templates define fixed `##` sections; docs fill sections and never add or rename them.
- Each template carries a one-line HTML comment defining the doc's scope.
- Project docs are terse bullets that point to paths instead of restating code.
  No history, decision IDs or changing numbers.
- A linked doc stays at most 8192 bytes, each bullet at most 300 characters and none holds a history phrase.
  `forge validate <path>`, `forge commit` on a changed doc and `forge map` print a violation as a `forge: warning:` line naming file and line, and exit 0.
- `.forge/CONCERNS.md` is rendered from `concerns.json` and lists open concerns only; it is exempt from the limits.
