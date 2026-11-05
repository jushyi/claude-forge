   For each `W` whose final
   review printed a `codex: <cause>` line or ended with no
   `<repo>: findings: ...` line, run the `forge-reviewer` fallback: write
   `git -C W diff M...HEAD` to
   `<git dir>/forge-<feature>-final.diff`, spawn `forge-reviewer` with that
   diff path, `F/spec.json` and `F/review/reviewer-<repo>.json`, and wait
   for it by ending the turn; append its findings to the repo record
   `<git dir>/forge-<feature>-review.json` (written as `{"findings": []}`
   first when absent) with `source` set to `reviewer`, delete the record's
   `pending` array, set the record's `tree` to `git -C W rev-parse HEAD^{tree}` and run
   `rm -f F/review/reviewer-<repo>.json`. Each repo writes its own
   `F/review/reviewer-<repo>.json`, so the fallbacks of several repos may
   run at once.
