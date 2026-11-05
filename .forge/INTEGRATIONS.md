# Integrations

## Services
- Codex plugin (`codex@openai-codex`), opt-in: `bin/forge review` and `bin/forge mockup` drive its `codex-companion.mjs` (`adversarial-review`, `task --write`); falls back to the Sonnet `forge-reviewer` when Codex is unavailable, logged as an `events.jsonl` `fallback`.
- Codex job records: forge reads the last 5 minutes of `~/.claude/plugins/data/codex-openai-codex/state/*/jobs/*.json` job records (`status`, `completedAt`, `result.parseError`, `errorMessage`, `logFile` and its `Codex error:` lines; companion 1.0.4 layout) to fail fast after an out-of-credits job.
- Codex broker: forge runs the plugin's `scripts/session-lifecycle-hook.mjs SessionEnd` with stdin `{"cwd": <dir>}` to stop a broker the call started, and reads the plugin's broker record with `scripts/lib/broker-lifecycle.mjs` `loadBrokerSession(cwd)` before and after each call.
- Impeccable plugin (`impeccable@impeccable`), opt-in, skipped when absent: `detect.mjs`/`audit`/`critique` in review and verify, `init`/`document`/`shape` in `/forge-new` and `/forge-discuss`.
- Jev Browser Control (JBC), optional, MIT, downloaded and patched at install, pinned in `global/forge/jbc/pin.json`; run by `bin/forge-browser` as a `systemd-run --user` unit, Chrome's CDP fixed at `127.0.0.1:9222` for the `playwright` MCP.
- The JBC unit pins `JBC_CONFIRM_IRREVERSIBLE=1` and `JBC_PROVIDER=openrouter`, which override `~/.jev-browser-control/config.env`.
- `context7` MCP server, registered at user scope by `port` from `global/mcp.json` unless the user already has one by that name.
- GitHub: `bin/forge pr` opens, merges and closes PRs on a `github.com` origin (an ssh origin's host is the hostname `ssh -G` resolves, so a `github.com-forge` alias counts) through `gh pr create|merge|close`, using `gh`'s own login.
- Forgejo, optional, at the host of `FORGEJO_URL`: `bin/forge pr` calls its REST API (`$FORGEJO_URL/api/v1/repos/<owner>/<repo>/pulls`, `POST` to create, `POST .../pulls/<n>/merge` to merge, `PATCH .../pulls/<n>` to close) for an origin on the host of `FORGEJO_URL`, which must be https.
- Forgejo hosts: `bin/forge pr create` refuses an origin on any other host, and `merge` and `close` a PR URL on any other host; a non-2xx response exits 1 with Forgejo's `message` and the HTTP code on stderr.
- Forgejo PRs carry no checks, so `/forge-debug` skips the `gh pr checks --watch` wait on a Forgejo origin.
- `forge pr checks --full` on a Forgejo origin only reads `GET .../pulls/<n>`, `GET .../actions/runs?head_sha=<sha>` and `GET .../actions/tasks`, and the token needs access to `/actions/tasks` (a 403 exits 1 with Forgejo's message).

## Credentials
- Jev API key at `${XDG_CONFIG_HOME:-~/.config}/forge/jev-api-key` (refused if group- or other-readable): read by `bin/forge-browser` as JBC's `OPENROUTER_API_KEY`.
  Never printed on stdout, stderr or in logs.
- Forgejo API token `FORGEJO_TOKEN`, with `FORGEJO_URL`, in `${FORGE_FORGEJO_ENV:-~/.config/forgejo/forge.env}`: parsed, not sourced, by `bin/forge pr` (only literal `FORGEJO_URL=`/`FORGEJO_TOKEN=` lines, optional surrounding quotes stripped; refused when group- or other-readable).
- `FORGEJO_TOKEN` is sent only as the `Authorization: token` header through a process-substitution header file, never on `curl`'s argv; never printed on stdout, stderr or in an error.
- `bin/forge pr` errors print the origin and `FORGEJO_URL` with any `user:token@` userinfo stripped.
