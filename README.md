# claude-forge

Forge is an automated development framework for Claude Code. It takes a feature from a conversation to a merged branch, running the work in parallel background sessions and git worktrees. The command is `forge`.

This project is unofficial and is not affiliated with or endorsed by Anthropic.

## The loop

1. **Discuss:** `/forge-discuss` turns a feature idea into a spec and asks you what it can't decide.
2. **Plan:** forge splits the feature into phases, and a planner breaks each phase into tasks.
3. **Execute:** `forge implement` starts phase sessions in worktrees. Implementers write each task's test and code.
4. **Verify:** `/forge-verify` reviews the feature and checks each requirement, with a manual test for you where one is needed.
5. **Ship:** `/forge-ship` updates the docs and lands the branch once the gates pass.

## Platform support

| Platform | CI | Notes |
|---|---|---|
| Ubuntu (with systemd) | CI-tested | Primary platform. Install also tested in a container |
| Fedora | CI-tested | Test suite only, in a container without systemd |
| Arch Linux | CI-tested | Test suite only, in a container without systemd |
| macOS | CI-tested, with limits below | Needs Homebrew tools, listed below |
| Windows through WSL2 | CI-tested | Ubuntu 24.04 on WSL 2 with systemd. Needs systemd enabled in WSL2; `port` prints the fix |
| Native Windows | Refused | `port` stops before changing anything and points to WSL2 |
| Linux without systemd | Unsupported | `port` stops before changing anything |

CI has no Claude login, so it stubs the `claude` command. CI does not cover real background sessions, plan limits, desktop notifications, Chrome, or the `claude plugin` checks of the mods, which skip when `claude` is absent. No one has run forge with a real Claude login on macOS or WSL2 yet.

**What macOS CI covers.** The test suite runs on macOS with Homebrew's GNU tools and forge's real macOS code paths. Nine suites that stub Linux tools such as `notify-send` and `systemctl` pin the Linux paths: `forge-browser`, `forge-commit`, `forge-gates-setup`, `forge-review`, `forge-watchdog`, `forge/doctor`, `forge/env`, `forge/run` and `forge/run-launch`. A separate step runs a real `./port --apply`, loads the watchdog agent in launchd, starts a `forge bg` job, sends a notification, runs `forge-init` and `./port --uninstall`, with a stubbed `claude`. The guard's fail-closed behavior under Bash 3.2 is also checked.

## Dependencies

Required everywhere: [Claude Code](https://code.claude.com/docs), `git`, `jq`, `rsync`, `flock`, `curl`, `python3` with PyYAML, and `check-jsonschema` (`pipx install check-jsonschema`). `port` prints one install line for each missing tool.

| OS | Command |
|---|---|
| Ubuntu, WSL2 | `sudo apt-get install -y git jq rsync curl util-linux python3-yaml pipx` |
| Fedora | `sudo dnf install -y git jq rsync curl util-linux python3-pyyaml pipx` |
| Arch | `sudo pacman -S --needed git jq rsync curl util-linux python-yaml python-pipx` |
| macOS | `brew install bash coreutils findutils gnu-sed grep util-linux flock rsync jq pipx` |

Optional: `node` and `npm` for plugins and browser tooling, the Codex and Impeccable plugins, Google Chrome, and an OpenRouter key for Jev Browser Control.

## Before you install

**What `./port --apply` changes:**

- Backs up every file it will change to `~/.claude/forge-backup-<timestamp>/`.
- Copies skills, agents, hooks, an output style, templates, schemas and mods into `~/.claude/`, and `forge`, `forge-init` and `forge-browser` into `~/.local/bin/`.
- Merges forge's hooks and one env value into `~/.claude/settings.json`. Every key and hook of yours stays, and your value wins any conflict. It records what it added in `~/.local/state/forge/port.settings.json`.
- Registers the `context7` MCP server at user scope, unless you already have a server with that name.
- Installs a watchdog that runs every 5 minutes: a systemd user timer on Linux, a launchd agent on macOS.

**Your `CLAUDE.md` files are never touched.** `port` and `forge-init` do not create, change, reject or delete any `CLAUDE.md`. `forge-init` writes its routing table to `.claude/rules/forge.md` in each project, which Claude Code loads alongside `CLAUDE.md`.

**Forge's own sessions run with `bypassPermissions`.** Sessions started by `forge implement`, `forge discuss`, `forge map` and the watchdog act without asking for permission, including running commands and editing files. Claude Code's documentation says this mode offers no protection against prompt injection or unintended actions. Your own sessions keep your permission settings; forge doesn't change them.

- Claude Code refuses `claude --bg --permission-mode bypassPermissions` until you have accepted its warning once. Forge doesn't accept it for you. To accept it, run `claude --permission-mode bypassPermissions` once and answer the dialog. That writes `skipDangerousModePermissionPrompt` to your `~/.claude/settings.json`, and `forge doctor` reports when it's missing.
- Claude Code won't start in this mode as root.
- To use another mode, set `FORGE_PERMISSION_MODE=acceptEdits` in `~/.config/forge/env`. Headless phase sessions will then stall on prompts they can't answer.

**Safety rails:**

- The `forge-guard` hook runs on every tool call in every session, yours included. It denies rewriting `main`, editing installed forge files and tampering with forge's gates. If it can't find Bash 4 or newer it blocks the tool call and says why.
- Phases run in their own worktrees and reach `main` only after the full test suite passes.
- Test runs have memory and time limits, and session counts are capped.

The hook affects your own sessions in forge-managed repos and when they touch installed forge files. Run forge in a VM or container if you want a harder boundary.

## Install

```bash
git clone https://github.com/jushyi/claude-forge.git
cd claude-forge
./port
./port --apply
forge doctor
```

`./port` alone is a dry run. Put `~/.local/bin` on your `PATH` if it isn't already.

Optional add-ons, both off by default:

- `./port --apply --plugins` installs the pinned Codex and Impeccable plugins. Without Codex, reviews use the `forge-reviewer` agent. Without Impeccable, design steps are skipped.
- `./port --apply --browser` registers the browser server. Then put your key in `~/.config/forge/jev-api-key` with mode 600. Without it, verify skips browser checks.

## First run

```bash
cd your-project
forge-init your-project "One line about the project."
claude
```

Then run `/forge-new` in Claude Code. `forge status` shows progress and `forge --help` lists the commands.

## Update, uninstall, rollback

- **Update:** `git pull && ./port --apply`, from a clean checkout on `main`.
- **Uninstall:** `./port --uninstall`, from the clone. It removes forge's files, its settings entries and the servers it added. If you haven't edited your settings since install, it restores them byte for byte; otherwise it removes only forge's entries. Projects keep their `.forge/` and `.claude/rules/forge.md`, and backups stay in `~/.claude/forge-backup-*`.
- **Rollback:** copy the file you want from the matching `~/.claude/forge-backup-<timestamp>/`. Paths inside it are relative to your home directory.

## Cost and limits

Forge can use a lot of your Claude plan. It runs parallel sessions, `forge` starts them with `--model opus`, and 7 of its 11 agents default to Opus. Your plan's limits may bind before your hardware does.

Limits come from your machine's memory and CPU count, with no configuration:

| Memory | Sessions | Phases per feature | Test runs | Test memory cap |
|---|---|---|---|---|
| 8 GiB | 2 | 1 | 1 | 2 GiB |
| 16 GiB | 4 | 2 | 1 | 4 GiB |
| 32 GiB or more | 6 | 4 | 2 | 4 GiB |

CPU count can lower these. `forge limits` prints the values for your machine. To spend less, set lower values in `~/.config/forge/env`:

```bash
FORGE_MAX_SESSIONS=2
FORGE_CONCURRENCY=1
```

## The `forge` name

Foundry also ships a command called `forge`. Run `type -a forge` to see which comes first on your `PATH`. If Foundry's wins, put `~/.local/bin` ahead of `~/.foundry/bin` in your shell profile, or call forge as `~/.local/bin/forge`. Forge's own scripts assume its `forge` comes first.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems through [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
