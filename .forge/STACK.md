# Stack

## Languages and frameworks
- Bash and rsync; jq and `check-jsonschema` (pipx) for `bin/forge`, whose `forge validate` runs `bin/forge.d/validate.py` under check-jsonschema's own Python.
- Claude Code skills, agents and hooks (Markdown with frontmatter, shell).
- `forge replay` compares answers in `bin/forge.d/replay.py` under the system `python3`; `/forge-port` measures a judge with coverage.py, mutmut 2 (`uvx`) or llvm-cov and cargo-mutants, and freezes time with libfaketime.
- Claude Code mods under `mods/`: TypeScript hooks modules against the `claude-code` API, checked with `claude plugin validate` and `claude plugin test`.
- Codex plugin (`codex@openai-codex`): its `codex-companion.mjs` serves `forge review` and `forge mockup`, its install path read from `~/.claude/plugins/installed_plugins.json`.
- Impeccable plugin (`impeccable@impeccable`): `detect.mjs`, the `audit` and `critique` reference and the `init`, `document` and `shape` skills, its install path read the same way.
- Jev Browser Control (JBC) 0.4.2, pinned in `global/forge/jbc/pin.json`, patched by `global/forge/jbc/` and run by `bin/forge-browser` (optional; needs `node`, `npm` and Google Chrome; DevTools on 9222).
- systemd user units `systemd/forge-watchdog.service` and `.timer`, installed by `port` under `~/.config/systemd/user/`; `forge watchdog --install` or `port --apply` enables the timer.
- Each `forge watchdog` scan prepends fnm's default Node, the fnm dir and `~/.cargo/bin` to the unit's minimal `PATH`, each only when it exists.

## Commands
- Preview a port: `./port`.
  Apply it from a clean `main`: `./port --apply`, or one subtree: `./port --only <src path> --apply`; remove it: `./port --uninstall`.
- Seed a workspace or project: `forge-init <name> "<description>" [<repo>="<description>"...]` in its root; `forge-init --help` for details.
- Start a project, track or feature: `/forge-new`; discuss a ready feature: `/forge-discuss` in a fresh session; make a trivial inline change (at most 3 files): `/forge-fast <task>`.
- Run a split feature: `forge implement <track>/<feature>`, up to `FORGE_CONCURRENCY` (default derived from memory and CPU) phase sessions at once, each running up to `FORGE_TASK_CONCURRENCY` (default 3) task agents; restart a crashed phase: `forge resume <N>`.
- `FORGE_MAX_SESSIONS` (default derived from memory and CPU) caps live forge sessions across all projects; a session over the cap or short of memory waits for a later `forge done`, `next`, `implement` or `resume`.
- Set host values as `FORGE_<NAME>=<value>` lines in `~/.config/forge/env` (or `$FORGE_ENV`); every `forge` command exports them over the computed defaults.
- Record a task that ran out of attempts as unmet: `forge task-done <N> <id> --unmet <reason>`; the phase session does this itself and never asks the operator.
- Link a sibling project: run `forge-init` in its root, then add its path, relative to the project root, to `.forge/repos.json` (`{"repos": ["../<sibling>"]}`).
- A session reaches paths outside its cwd, such as the state dir S, the driving project's `.forge/` or a linked repo outside R, without prompts only in `bypassPermissions`.
- In `acceptEdits`, starting it with `--add-dir <path>` auto-accepts edits and `mkdir`, `touch`, `rm`, `rmdir`, `mv`, `cp` and `sed` there, but other Bash writers still prompt, so it does not suffice for a headless phase session.
- Planning state: `forge --help` lists the commands; `forge status` shows progress across tracks, branch conflicts with `main` and a Sessions line; `forge status --json` prints it as one JSON document; `forge status <track>/<feature>` prints one feature's view.
- Merge a branch with conflict resolution: `forge merge <branch>`, then `forge merge --continue <record>` or `forge merge --abort`; check what a merge lost: `forge merge-check [<record>]`.
- Land a branch on a repo's `main` (merge, test, fast-forward, push when opted in): `forge land <repo> <branch>`.
  Land and port in one step: `forge golive <repo> <branch>`.
- Run tests: `forge test [<dir>]` runs the full suite in the background, `--changed [--base <ref>]` the changed tests, `--one <id>` one test and `--repeat <n> --one <id>` repeats it; `forge test --passed [--changed]` checks HEAD has a pass.
- Full, changed, `--one` and `--repeat` runs of `forge test` wait in arrival order for one of `FORGE_TEST_RUNS` machine-wide run slots (default 2), never giving up; every test command and Setup runs under `timeout -k 10s <n>m`, `<n>` the `- Timeout:` minutes or 60, and a stopped run exits 124.
- Each capped run gets a `systemd-run --user --scope` capped at its memory budget (`- Memory:`, default `4G`; `- Memory one:` for `--one`, default half that), `FORGE_TEST_CPUS` and `CARGO_BUILD_JOBS` set by `- CPUs one:` or `- CPUs all:`, and a line in `<git common dir>/forge-test/runs.log`.
- `FORGE_TEST_SLOT_WAIT` (default 30 minutes) bounds the worktree-lock wait, which ends in exit 75; a full or changed run whose command hits a test failure with the 1-minute load at or above nproc reruns once by itself in the same slot, and a failed tree is never refused a rerun.
- Print a phase's or feature's absolute paths for spawns: `forge paths <N>|<track>/<feature>`; list a feature's open review findings by file: `forge fixes <track>/<feature>`.
- `forge paths` also prints a `STATE=<S>` line, the state dir absolute with no trailing slash; with no argument it prints only the `R=` and `STATE=` lines.
- Collect merged worktrees and branches: `forge gc` (dry run), `forge gc --confirmed`.
  A repo with no `origin` is judged against local `main`; `forge archive` and a weekly `forge watchdog` pass run `forge gc --apply`.
- Map repo docs and concerns: `forge map [<repo>...]` in a project root; it runs `claude` in `bypassPermissions`, since `acceptEdits` treats `.forge/` as sensitive and denies the mappers' writes.
- Review a feature diff on Codex: `forge review <track>/<feature>`; build a mockup: `forge mockup <track>/<feature> <surface> [<repo dir>]`; both need the codex plugin installed and logged in.
- Run the shared browser: `forge-browser start [--headed]`, `forge-browser stop`; sessions register it as an MCP server with `forge-browser mcp`.
  One Claude session owns it at a time; a `start` from another waits for the owner, giving up after `FORGE_BROWSER_OWNER_WAIT` seconds (default 540).
- Push `main` to `origin` when opted in: `forge push [<repo>]`.
