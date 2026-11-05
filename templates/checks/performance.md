<!-- Performance criteria: per-request efficiency, plus no wall-clock gates in blocking tests or git hooks. -->

## Criteria
- PERF-01: block a query issued inside a loop over rows already fetched (N+1) where a join, one `WHERE ... IN` batch query or an eager load would do.
- PERF-02: block a new or changed query that filters, joins or sorts on a column with no supporting index added in the same diff.
- PERF-03: block a loop that makes one sequential blocking call (DB, RPC or HTTP) per item when a batch or bulk form of that call exists or is trivially available.
- PERF-04: block a new outbound dependency call (HTTP, RPC, DB) on a synchronous request-handling path with no timeout.
- PERF-06: block a new assertion that fails on elapsed wall-clock time (a latency or duration threshold, a benchmark bound) in a test the blocking suite runs or in a git hook. A timeout that only guards against a hang, and wall-clock measurement that reports without failing, pass.
- PERF-07: block a phase with focus `performance` that adds or changes a user-noticeable path (an interaction, a screen or page load, a frame, a CLI command a user runs) without the repo's `- Perf log:` command printing one metric line for that path from the app's own usage logs: a JSON object `{metric, value, unit, kind, at}`, with `metric` a non-empty string, `value` a number >= 0, `unit` a non-empty string, `kind` `count` or `time` and `at` an ISO-8601 time. Prefer a `count` kind (instructions, allocations, queries, bytes, renders, requests); a `time` metric only reports. A repo whose TESTING doc has no `- Perf log:` line gets one in the same phase. PERF-06 still holds: no test asserts on wall-clock time.
