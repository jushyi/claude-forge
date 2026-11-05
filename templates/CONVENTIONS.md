# Conventions

<!-- patterns specific to this project that the global rules don't cover -->

Shared docs and ledgers that every phase only appends to, such as decision logs, API surface lists and perf ledgers, are marked `merge=union` in `.gitattributes`, so phases that each add a line run at once instead of waiting on each other in `forge check`, and git keeps both sides' added lines on merge; mark only files whose lines are only ever added and whose order does not matter.

## Patterns
