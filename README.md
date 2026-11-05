# claude-forge

**Preview.** Tested on Linux only so far; macOS and WSL2 support is in progress.

Forge is an automated development framework for Claude Code: discuss a feature, split it into phases, run them in parallel sessions and worktrees, verify and ship. The command is `forge`.

This project is unofficial and not affiliated with or endorsed by Anthropic.

## What install changes

`./port --apply` backs up what it changes to `~/.claude/forge-backup-<timestamp>/`, then:

- copies skills, agents, hooks, templates and schemas to `~/.claude/`, scripts to `~/.local/bin/` and a watchdog timer to `~/.config/systemd/user/`;
- merges forge's hooks and env into `~/.claude/settings.json`, keeping every setting of yours;
- registers the `context7` MCP server unless you have one by that name.

It never creates, changes or deletes a `CLAUDE.md`. `./port --uninstall` removes only what forge added.

Forge's own background sessions run with `bypassPermissions`, so they act without prompting, within the rails of its guard hook. Set `FORGE_PERMISSION_MODE` to change that. Your own sessions keep your settings.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
