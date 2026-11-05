# Contributing

Anyone can fork jushyi/claude-forge and open a pull request. Only the maintainer, jushyi, merges. There is no response-time promise.

## Tests

The suite needs `jq`, `rsync`, `check-jsonschema` and Python 3 with PyYAML. It stubs `claude` and needs no login.

```bash
tests/forge.test.sh                  # everything
tests/forge-init.test.sh             # one suite
tests/forge/help.test.sh             # one command's suite
tests/changed.sh <files>             # the suites covering these files
```

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/): `fix(port): keep user hooks on update`.
- One concern per PR.
- CI must pass. Explain any test you change; don't delete or weaken one to get green.
- Fork PR workflows wait for maintainer approval.
- No personal data, hostnames, tokens or local paths in code, tests or commit messages.

## License

Contributions are under the MIT license of this repo (inbound equals outbound). There is no CLA.
