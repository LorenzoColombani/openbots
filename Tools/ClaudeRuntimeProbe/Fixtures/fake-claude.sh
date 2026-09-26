#!/bin/sh
set -eu

# Model-free fixture for exercising callers of the probe. It intentionally
# exposes only the redacted auth fields consumed by ClaudeRuntimeProbeCore.
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' '0.0.fixture (Claude Code)'
  exit 0
fi

if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--print --input-format --output-format --include-partial-messages --replay-user-messages --resume --strict-mcp-config --settings --setting-sources --allowed-tools --restricted --no-session-persistence'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
  exit 0
fi

printf '%s\n' 'fake Claude supports readiness only' >&2
exit 64
