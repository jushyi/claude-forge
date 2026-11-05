# Architecture

## Components
- `port` installs forge by its top map, never symlinking; it records each installed path in `~/.local/state/forge/port.manifest` and prunes dropped ones.
- `./port --apply` runs only from a clean `main`: it preflights the platform and tools, backs up to `~/.claude/forge-backup-<timestamp>/`, merges forge's hooks and env into `~/.claude/settings.json` (user values win), records what it added and stamps `port.json`.
- `./port --uninstall` removes only forge's files and recorded entries. `port` never creates, changes or deletes any `CLAUDE.md`.
- `bin/forge` is a thin dispatcher: each command's code is in `bin/forge.d/<area>.sh`, its `--help` in `bin/forge.d/help/<cmd>.txt`.
- `bin/forge.d/state.sh` holds `forge validate`, which checks the ten planning JSON kinds with a schema in `schemas/`, parse-checks the rest and lints linked docs.
- Planning state is JSON only, never rendered Markdown: phase, feature and archive records live in the state dir S, tracks in `.forge/tracks/`.
- `forge status [--json]` and `forge status <track>/<feature>` print it via the jq library `bin/forge.d/forge.jq`, the feature form ending with its phases' unmet tasks.
- `bin/forge.d/commit.sh` (`forge commit`) validates and gates a scope's changed S records in place and commits only in-repo `.forge` files from a private index under `<git common dir>/forge.lock`, moving `main` by CAS.
- `forge commit` enforces phase and feature `review_trees` rules, and with no in-repo change commits nothing and prints `forge: recorded <scope> <step>`.
- `bin/forge.d/land.sh` (`forge land`, `forge golive`) merges a feature into `main` under `forge.lock` and `forge-land.lock` only after a full-suite pass or a reusable full stamp; `forge golive` then queues porting the landed commit.
- `bin/forge.d/gate.sh` holds the phase gate: `forge done` passes a phase only once every planned task is committed via `forge task-done` as `done` or `unmet` and its branch merges cleanly into BASE, unless `result.json` `unmet` holds a `sync` entry.
- `bin/forge.d/task-done.sh` (`forge task-done`) commits one task's files by path and logs it, and `--unmet <reason>` records a task out of attempts; `plan-done` and `finish` close a phase step likewise.
- `bin/forge.d/pr.sh` (`forge pr`) handles GitHub or Forgejo PRs; `forge pr checks --full` stamps a full-suite pass for a PR head whose declared CI run succeeded.
  `forge pr merge` exits 5 when `origin/main` moved a path outside `.forge/` since the PR head's merge base.
- `bin/forge.d/run.sh` launches phase, Verify and Ship sessions in track-qualified worktrees under `.claude/worktrees/`, capping live sessions by `FORGE_MAX_SESSIONS` and `FORGE_CONCURRENCY` and holding starts it cannot make.
- `bin/forge.d/test.sh` runs tests in capped systemd scopes behind one machine-wide run semaphore and a hard timeout; `forge test --one`, `--changed` and the full suite write stamps `land` reuses.
- `bin/forge.d/watchdog.sh` (`forge watchdog`, every 5 minutes via `systemd/forge-watchdog.timer`) applies queued ports, alerts on stalls and overrunning tests, auto-resumes parked, limited or ended sessions and runs `forge perf pull` once a week.
- The watchdog also runs `forge gc --apply` weekly per root in `watchdog-roots`, gated by the `~/.local/state/forge/gc-week` stamp.
- The watchdog also self-heals a phase stopped on a blocker with a fix-it-yourself prompt (a blocked result under 7 days old, feature not archived), 3 per phase then one alert, and clears a `wait <ref>` park once its condition holds.
- `bin/forge.d/check.sh` (`forge check`) checks a plan against its spec and lints each touched repo's `TESTING.md`; a `Quarantine` line over 7 days old becomes a `quarantine` concern via `concern.sh`, not a failure.
- `bin/forge.d/doctor.sh` (`forge doctor`) prints one host setup problem and fix per line, including a repo with PR CI and no `- CI full suite:` line in TESTING.md.
- `bin/forge.d/perf.sh` holds `forge perf pull`, aggregating each repo's `- Perf log:` metric lines into `.forge/perf.json`; `owed.sh` and `quick-log.sh` run ship-time requirement tracking and quick logs.
- A requirement names its `owner`, `agent`, `operator` or `post-ship` (`agent` when absent): the splitter maps only `agent` ones to phases and `forge owed` settles `post-ship` ones — `schemas/requirements.schema.json`.
- `bin/forge.d/replay.sh` is the `/forge-port` judge: `forge replay` records old answers twice for noise, locks and replays; `forge shadow` and `forge cutover` judge live mirror logs; `replay.py` compares bytes except where a rule allows.
- `bin/forge-init` seeds a workspace or single-repo project from `templates/` and renders the never hand-edited router `.claude/rules/forge.md`; no `CLAUDE.md` is read or written.
- `bin/forge-browser` installs the pinned Jev Browser Control; browser tooling is optional and skills skip it when absent.
- `skills/forge-*` are the operator and session entry points: discuss, new, phase, verify, ship, quick, fast, debug and port.
- `skills/forge-phase` runs only plan, tasks and sync and never asks the operator, deciding each blocker itself and recording what it cannot finish as `unmet`; verify, ship and quick use `AskUserQuestion`, and verify reviews the feature once for ship to reuse.
- `skills/forge-verify` ends in one sheet, a `met`, `unmet`, `operator` or `post-ship` line per requirement; all `met` or `post-ship` passes unasked, else one `AskUserQuestion` round settles the `unmet` and `operator` lines.
- `agents/forge-<role>.md` are the forge agents, each writing JSON shaped by its prompt (`schemas/` holds only the planner, splitter, implementer and reviewer shapes); the implementer writes each task's test and code, and `tests/agents.test.sh` caps each prompt at 150 lines.
- `hooks/forge-guard.sh` is the global `PreToolUse` hook denying git writes that move or rewrite R's `main`, live forge file edits outside `port`, forge script copies and a main agent's edits to agent records, S's included.
- The guard also denies Write, Edit and Bash writes of `.forge/{archive,phases,features}/**` under any repo or worktree top, naming the S path, and allows `ListAgents` in forge-launched sessions.
- The guard matches a forge-script copy by content (a write or run whose sha256 is a live or repo forge file) or by source, never by name; `forge-internals` fires only on sourcing `forge.d` or defining a gate function with a body, not on prose naming one.
- `hooks/forge-agent-write.sh` scopes agent writes, sending records to `S/phases/**` and `S/features/**` and validating the JSON there.
- `hooks/forge-phase-stop.sh` and `forge-session-title.sh` check a phase session's stop and title skill sessions; `output-style-reinforce.sh` is opt-in and unregistered by default.
- `global/settings.json` holds only forge's hooks and env, merged by `port`; `global/mcp.json` lists its MCP servers; `global/plugins.json` pins the opt-in plugins.
- `mods/<name>/` are Claude Code mods in interactive sessions, showing forge runs and stalls, writing only their own state.
  `mods/forge-runs` finds a phase's directory through `forge paths`.

## Boundaries
- The clone is the source; `~/.claude/` and `~/.local/bin/` are the target.
  Installed forge files change only through `port`; user settings and `CLAUDE.md` files stay the user's.

## Layout
- `global/` → `~/.claude/`; `skills/`, `agents/`, `hooks/`, `output-styles/` → `~/.claude/<same>/`
- `templates/`, `schemas/`, `mods/` → `~/.claude/forge/<same>/`
- `bin/` → `~/.local/bin/`; `systemd/` → `~/.config/systemd/user/`
- `.forge/`: forge's own project docs and, when present, tracks, `todo.md`, `seeds.md` and `concerns.json`.
- S, `${XDG_STATE_HOME:-$HOME/.local/state}/forge/<repo>/`: phase, feature and archive records, `quicks.json`, `debugs.json` and `history.json`, never ported.
- `<repo>` is the main checkout's basename: in a linked worktree the parent of its git common dir when that ends in `/.git`, else its own top.
