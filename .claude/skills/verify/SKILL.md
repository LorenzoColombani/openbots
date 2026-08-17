---
name: verify
description: How to build, launch, and drive Agency for runtime verification — CLI harness, GUI driving, and safe live-call budgeting.
---

# Verifying agency

## Build & test
- ALWAYS prefix: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (CLT lacks XCTest).
- `swift build --product agency-cli` for the harness; `./scripts/make-app.sh` for `dist/Agency.app`.
- Suite is mock-driven — `swift test` makes NO live calls. `ClaudeProcessRunnerTests` spawns real `/bin/sh` (still free).

## Live calls cost real subscription usage
- Every `agency-cli chat/ask` and every message in the GUI = one `claude -p` call (a relay = one call to the target).
- `claude -p --resume <bad-sid>` fails BEFORE the model — free. Rollover's retry costs one call.
- Budget gates: batch what each live message proves; don't chat casually.

## CLI surface (cheapest handle)
- Root = cwd. For destructive probes, NEVER use the repo root — use a scratch dir:
  `mkdir <scratch> && cd <scratch> && <repo>/.build/debug/agency-cli create probe 🧪 test subject`
  (`create` is free — no claude call.)
- Commands: `create <name> <emoji> <role…>` · `chat <name> <msg…>` · `ask <asker> <target> <q…>` · `roster`.
- Rollover scenario: inject a bogus `sessionID` into the scratch `roster.json`, then `chat` —
  expect stderr `[name] previous session unresumable — rolled over…`, fresh sid in roster, exit 0.

## GUI surface
- `open /Applications/Agency.app` (or `dist/`). Drive via computer-use; **request_access("Agency") only resolves if the app existed when the Claude Code session started** — if denied with `not_installed`, restart the session.
- Screenshot the window only: enumerate `CGWindowList` for owner "Agency", then `screencapture -l<id>` (see scratchpad winid.swift pattern) — avoids capturing the user's desktop.
- Composer at bottom; click it before typing. **Wait ~1.5s after clicking a sidebar row before clicking the composer** — a fast batch can land the text in the previous thread (its busy guard then eats or bounces it).
- Runtime data lives in the repo root (`agents/`, `vault/`, `roster.json`) — messages sent in the GUI are real conversations with the user's team; keep test chatter minimal and harmless.

## Network egress fence (2026-08-13)
- FENCED agents (any fork; any agent without web/browser/gmail/gcal) run through
  a loopback allowlist proxy + Seatbelt. **Expect `🚧 egress denied: pypi.org` +
  `…datadoghq.com` on stderr of EVERY fenced CLI chat — that's claude's own
  runtime telemetry being blocked, normal, not a failure.**
- Thread notices suppress those two noise hosts; any OTHER 🚧 host in a thread
  is agent-driven and significant.
- Live fence checks: a fenced shell agent's `curl https://example.com` should
  report `curl: (56) CONNECT tunnel failed, response 403`.

## Evidence shortcuts
- Per-thread log: `agents/<name>/messages.jsonl` (ts/author/kind/text — relay legs included).
- Vault provenance: frontmatter of `vault/*.md`.
- Agent session namespaces: `~/.claude/projects/…-agency-agents-<name>/`.
