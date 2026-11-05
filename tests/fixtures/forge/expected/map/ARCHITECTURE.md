# Architecture

<!-- components, how they connect, boundaries, where code lives -->

## Components

- `src/server.ts` serves the intake API
- `bin/forge` validates each output.
  It then renders the docs.
- Mappers cover several foci, e.g. Tech and arch.
  Each writes one JSON file.
- One mapper runs per focus, i.e. Four per repo.
  The concerns mapper runs on high effort.
- Docs cover the stack, layout, tests, etc. The concerns doc keeps one line per concern.
- Rendered docs vs. Hand-edited docs differ in owner.
  The map owns the rendered ones.
- Dr. Watson reviews the layout.
  The fixer applies each finding.
- Ticket No. A12 tracks the split.
  The golden pins it.
- Node 20.11 runs the CLI.
  Tests need jq 1.7 or later.
- `forge map. Then render` keeps its period.
  The span stays whole.
- Why one sentence per line?
  Branches that edit different sentences merge cleanly.
- Never hand-edit a rendered doc!
  `forge map` overwrites it.
- The render pipeline runs on every map.
  It has two stages:
  - `load` reads the JSON.
    It keys each file by path.
  - `map_doc` renders the docs.
    Each sentence gets its own line.
- Guards fail the build before passing, e.g. `xtask/tests/no_servo_reads.rs`; forbidden literals stay out of the tree.
- Secrets live in compose (e.g. `WIREGUARD_PRIVATE_KEY`, `CF_API_TOKEN`, and the rest) and never in the repo.
- The stack runs several apps (Home Assistant, Frigate, Paperless-ngx, etc.).
  The proxy fronts them all.
- Live tests are opt-in (env-gated, e.g. `LUNA_LIVE_SANDBOX=1`) and skip in CI.
- The shell adds a portal file chooser, perf hooks.
  `browser-shell/src/filters.rs` is the ordered filter chain.
- Only the shell crates name `gtk4`/`libadwaita`.
  `browser-core` names no GUI toolkit.
- Each rating appends to a JSONL ledger.
  Callers apply a `value` only on exit 0.

## Layout

- `src/` code
- `tests/` tests
