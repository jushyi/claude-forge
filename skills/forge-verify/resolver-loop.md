Given a `W` and `<branch>`: run `(cd W && forge merge <branch>)`. Exit 0:
continue. Exit 1: ask the operator with its message. Exit 4: for attempt k = 1, 2,
spawn `forge-merger`, description `verify <feature> sync forge-merger`,
with `W`, the paths `forge merge` printed, the merge base
(`git -C W merge-base HEAD MERGE_HEAD`), the output of
`git -C W log --oneline <base>..HEAD` and of
`git -C W log --oneline <base>..MERGE_HEAD`, `F/requirements.json`, the
record `F/merge/<repo>-V<k>.json`, `<repo>` being the basename of `W`'s
repo, and, on attempt 2, the last merge-check output. Then run
`(cd W && forge merge-check <record>)` and, when it exits 0, run
`(cd W && forge merge --continue <record>)` and continue (its exit 1 is a
failed attempt). The merged tree is tested by step 3's smoke test. After
the second failed attempt run `(cd W && forge merge --abort)` and ask the
operator with the conflicted paths and the last merge-check output; both
branches stay as they were.
