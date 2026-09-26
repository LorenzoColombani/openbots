# Hire probe, Claude Code 2.1.272

Captured with a probe script that launches the CLI the way the app launches a turn
that can add a teammate, questions over `--permission-prompt-tool stdio`. Each folder
is one run: `argv.json` (the launch arguments), `meta.json` (the settings, the prompt
and the host's answers) and `wire.jsonl` (every frame in both directions). The replay
tests in `ClaudeCLIHireReplayTests.swift` read them. Paths are scrubbed to `$RUN` and
`/private/tmp/hire-probe.noindex`.

- `lead.md`, beside this file, is the system prompt every run used (`meta.json` names it).
- `a14-hire-beside-connector` also carried a stand-in connector: a tiny stdio MCP server
  with one `echo` tool that hands back its text and touches nothing. Its config, which
  the probe wrote to `$RUN/connectors.json`, is the `mcp_config` in `meta.json`. The
  server script is not shipped; no test launches it.
