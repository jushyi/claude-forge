1. Run `forge-browser start`. It may wait while another session owns the
   browser, printing `browser in use by <owner>`. When browser tooling is
   optional and absent (no `forge-browser` key, Chrome or `mcp__jbc__*`
   tools), or it fails, including
   when it gives up waiting, show the operator its message and skip the
   pass; each headless or browser-driven check it would have run becomes
   operator-owned, an `operator` line of step 6's sheet.
2. For each manual-test step `k`, run one `jev_task` against the env URL
   with every value it types in `details`, never `allowIrreversible`. A
   `needs_confirmation` stop leaves that step to the operator. A deferred
   check that is headless or browser-driven runs here in step 6's agent run
   unless step 6's ownership rule leaves it the operator's.
3. After each step, judge it from JBC's `browser_screenshot`. Save its
   evidence with playwright's `browser_take_screenshot`,
   `browser_console_messages` (level `error`) and `browser_network_requests`,
   each given a `filename` under `.playwright-mcp/` in this directory: JBC
   returns its screenshot inline with no path, and playwright writes only
   under the session's directory. `mv` the files into `E/s<k>/`.
4. Any other step that does not end `done` or does not show what it should
   is a gap whose text names its `E/s<k>/` evidence paths, except a step
   that stopped at `needs_confirmation`: step 2 leaves that to the
   operator, not a gap.
5. Critique. Read `<installPath>/skills/impeccable/reference/critique.md`,
   `installPath` being that of `impeccable@impeccable` in
   `~/.claude/plugins/installed_plugins.json`; when the optional Impeccable
   plugin is not installed, skip this step and record no critique. Judge each page the steps
   reach from JBC's `browser_screenshot` and `browser_snapshot` with your own
   vision, by its Assessment A criteria, Heuristics Scoring Guide and P0-P3
   severity. Borrow the rubric only, not its Setup, sub-agents, Assessment B,
   persistence or questions to the operator. Each Priority Issue keeps its
   own P0-P3; any other review finding verify surfaces maps high to P1,
   medium to P2 and low to P3. Only P0/P1 findings are gaps, whose text
   gives the severity and the step's `E/s<k>/` evidence paths. A P2 or P3
   finding is never a gap: append it to `R/.forge/todo.md` as
   `- <today YYYY-MM-DD> <summary> (P<n>, <feature> verify, operator deferred) — <screenshot path>`,
   today being the local date `date +%F` prints and the screenshot path
   the step's saved screenshot under `E/s<k>/`; the Record step commits
   these lines.
6. Run `forge-browser start --headed`; this session's `jbc` and
   `playwright` servers reattach to the same endpoints. The operator runs
   the operator-owned steps in that Chrome, the only visible browser per
   Rules. It
   may wait while another session owns the browser. When it fails,
   including when it gives up waiting, show the operator its message;
   they test as today. Step 8 of Steps runs `forge-browser stop` when
   they are done if a start of this session
   succeeded, so the next session gets the browser.
