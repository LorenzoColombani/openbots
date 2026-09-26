# Claude runtime feasibility probe

This standalone Swift package tests the load-bearing Claude Code boundary that
`OpenBotsRuntime` builds on. It does not import the app, copy credentials,
or offer any fallback provider.

The executable always builds an allowlist-first child environment. Provider/API
variables are reported by name only and removed before the child is launched.
It accepts only `authMethod: claude.ai`, `apiProvider: firstParty`, and a `pro`
or `max` subscription.

## Commands

From the repository root, use the credential-isolated SwiftPM wrapper and an
explicit, new `.noindex` root under `/private/tmp` for every invocation:

```sh
Scripts/swiftpm-public.sh run --disable-sandbox \
  --package-path Tools/ClaudeRuntimeProbe \
  --scratch-path .build.noindex/claude-runtime-probe \
  claude-runtime-probe inspect \
  --root /private/tmp/OpenBotsClaudeInspect.noindex \
  --config "$PREVIEW_CLAUDE_CONFIG"

Scripts/swiftpm-public.sh run --disable-sandbox \
  --package-path Tools/ClaudeRuntimeProbe \
  --scratch-path .build.noindex/claude-runtime-probe \
  claude-runtime-probe isolation \
  --root /private/tmp/OpenBotsClaudeIsolation.noindex \
  --config /private/tmp/OpenBotsClaudeIsolation.noindex/config

Scripts/swiftpm-public.sh run --disable-sandbox \
  --package-path Tools/ClaudeRuntimeProbe \
  --scratch-path .build.noindex/claude-runtime-probe \
  claude-runtime-probe live \
  --root /private/tmp/OpenBotsClaudeLive.noindex \
  --config "$PREVIEW_CLAUDE_CONFIG"
```

For `inspect` and `live`, `PREVIEW_CLAUDE_CONFIG` must resolve to the exact
Foundation Application Support path
`com.lorenzocolombani.openbotsnext.preview/HighChurn.noindex/Runtime/Claude/CLIProfile`.
That directory must already be owned by the current user, mode `0700`, not
symlinked, and contain a mode-`0600` `.openbots-claude-profile.json` marker with
schema version `1`, the preview bundle identifier, and role `preview`.
Production `StorageLayoutService` owns this layout in the app. For a physical
feasibility experiment only, a separate bootstrap
may create exactly this profile, its private parent directories and `backups`
directory, and the marker. The runtime probe itself still never creates it.
An omitted, default, merely `.noindex`, misplaced, mismarked, or symlinked
profile fails before Claude launches.

`inspect` is read-only apart from Claude's own bounded readiness behavior and
the explicit temp root. `isolation` sets `CLAUDE_CONFIG_DIR` to the explicit
disposable config child and is expected to fail logged out, proving that the
default profile was not reused; do not log that disposable control in. The
probe never starts login itself. `live` makes two minimal ACK-only requests only
after the marker-owned preview profile passes readiness; it uses no tools, no
session persistence, restricted/safe mode, strict empty MCP,
bounded nonblocking input, and reports replay UUID correlation plus the watched
filesystem diff.

The isolated probe marker has role `probe` and cannot authorize `live`. Every
readiness child receives a nonoptional `CLAUDE_CONFIG_DIR`; no API in this
package can silently omit it and fall back to the user's default Claude profile.

The write-set receipt is a metadata diff over the explicit probe root,
`~/.claude`, `~/.claude.json`, and `~/Library/Caches/claude-cli-nodejs`. It is
useful evidence but not a kernel-complete filesystem trace. Full proof also
needs a trace on a physical Mac plus a live run under the separately and
officially authenticated preview `CLAUDE_CONFIG_DIR`.

## Offline mechanics fixtures

`Fixtures/runtime-mechanics.sh` is a model-free test fixture, not an OpenBots
tool or command surface. The test suite uses it only as a deterministic child
to prove two same-process stream inputs, exact replay correlation, a final
result racing EOF, bounded pipe backpressure, teardown races, dedicated process
groups, and child/grandchild cleanup. It never invokes Claude, accesses a
network, or reads authentication state.

The probe launches every child in an explicitly new POSIX process group. Input
is capped at 1 MiB and written through a duplicated nonblocking descriptor with
a monotonic deadline; no lifecycle lock is held across `poll` or `write`.
Backpressure or a broken pipe tears down the whole owned process group before
the error returns. Payload-contract failures are rejected without killing an
otherwise healthy child. A replay event carrying the exact input UUID remains
the delivery acknowledgement—an unacknowledged partial write is never reported
as delivered or automatically replayed.
