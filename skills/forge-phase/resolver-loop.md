Given `<branch>`, in `W`: run
`FORGE_ROOT=R forge merge <branch>`. Exit 0: continue. Exit 1: decide it
yourself (the no-ask Rules bullet) with its message. Exit 4: for attempt
k = 1, 2, spawn `forge-merger`,
description `P<N> sync forge-merger`, with `W`, the paths
`forge merge` printed, the merge base (`git merge-base HEAD MERGE_HEAD`), the
output of `git log --oneline <base>..HEAD` and of
`git log --oneline <base>..MERGE_HEAD`, `F/requirements.json`, the record
`P/merge/M<k>.json` and, on attempt 2, the last merge-check output. Then
run `FORGE_ROOT=R forge merge-check <record>` and, when it exits 0, run
`FORGE_ROOT=R forge merge --continue <record>` and continue (its exit 1 is a
failed attempt). After the second failed attempt run
`FORGE_ROOT=R forge merge --abort`; both branches stay as they were. In step
1, go on to the tasks: step 3 runs the loop again. In step 3, append
`{"task": "sync", "reason": "merge conflict on <paths>"}`, `<paths>` the
conflicted paths, to `unmet` in `P/result.json` as step 4 writes it, and
run Finish. After the loop run `FORGE_ROOT=R forge commit N sync`.
