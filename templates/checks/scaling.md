<!-- Scaling criteria: capacity and volume under growth, plus max_rows, max_fanout and rps targets. -->

## Criteria
- SCALE-01: block a query or ORM call that returns a collection with no row limit or page-size bound in the same code path (no `LIMIT`, `.take`/`.first(n)` or capped fetch).
- SCALE-02: block a new or changed endpoint that returns a list with no server-enforced pagination (cursor or offset/limit). A client parameter the server does not enforce does not count.
- SCALE-03: block a page-size or limit request parameter with no server-enforced maximum.
- SCALE-04: block a loop or batch that issues one query, RPC or HTTP call per element of an unbounded input with no fixed concurrency cap (worker pool, semaphore, `errgroup`-style limit).
- SCALE-05: when the spec's `targets.max_fanout` is set, block a fan-out whose code-enforced cap is absent or exceeds it. The cap must trace to `targets.max_fanout`.
- SCALE-06: when `targets.max_rows` is set, block a query, response or export whose enforced row cap is absent or exceeds it.
- SCALE-07: when `targets.rps` is set, block new capacity-facing code (rate limiter, connection-pool size, queue depth, autoscaling threshold) with no bound consistent with it, or a new externally reachable path that adds no such bound.
- SCALE-08: block an unbounded in-memory queue or buffer feeding a worker pool or channel. It needs a fixed capacity that blocks or drops producers once full.
