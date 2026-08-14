# Agency

A native macOS app that turns Claude into a **team of persistent, named AI teammates** — each one a real, resumable [Claude Code](https://claude.com/claude-code) session with its own personality, memory, permissions, and sandbox, all sharing an Obsidian-compatible vault and visibly handing work to each other.

Think group chat, except every participant is an agent you hired, briefed, and fenced yourself — and the last seat is you.

> **Status: source release in progress.** The app is built, working, and used daily; 379 tests pass. This repository currently publishes the design and architecture. The full Swift source lands **next week**, once its final privacy review is complete — it is an extraction from a private working repo, and I would rather ship it late than ship someone's phone number in a code comment.
>
> Watch the repo if you want the drop.

---

## What it does

- **Persistent teammates.** Each conversation is a headless `claude -p --resume` session. Teammates keep their memory across app restarts, days, and reboots — a real session, not a prompt with a wig.
- **Visible agent-to-agent handoffs.** `@teammate question` relays the question agent-to-agent; multi-line `RELAY` blocks let an agent delegate mid-answer. Every leg renders in the UI — no invisible orchestration.
- **Group threads.** Teams of up to six agents share a thread; per-member cursor deltas make group chat coherent across independent sessions, with the human as the fan-in.
- **A shared vault.** Obsidian-compatible Markdown, with per-agent private pockets, per-team pockets, and a provenance ledger that flags cross-agent overwrites *and* files planted where they don't belong.
- **Connectors.** Optional per-agent grants: a service-aware Apple Messages server (picks iMessage / RCS / SMS from chat history instead of guessing), an Apple Mail sender (no default account, signature-aware), Google Workspace, browsers, shell.
- **File attachments.** Drag files onto a thread or use the picker; copies are staged where every fenced agent can read them, symlinks refused, names sanitized.

## Why the engineering is interesting

**No API key anywhere.** The whole thing rides a claude.ai subscription through the Claude Code CLI. Child processes strip `ANTHROPIC_API_KEY` defensively; billing never touches a key.

**Two-half fencing.** Every teammate is contained twice, because the two halves fail differently: settings deny rules bind the CLI's file tools, and Seatbelt profiles bind everything else — Bash is not subject to tool rules, so shell agents get kernel-level fences with paths resolved through `realpath(3)` (Swift's `resolvingSymlinksInPath()` silently skips `/var`, which would fail open).

**A network egress fence.** Each fenced run gets its own loopback CONNECT proxy; Seatbelt denies every other outbound route. Allowlisted hosts tunnel through a blind TCP relay; everything else is refused *visibly* — a tricked agent's exfiltration attempt becomes a thread notice, not a silent failure.

**Prompt injection is treated as weather, not surprise.** Untrusted material is fenced and neutralized, never silently censored, and the test suite carries injection fixtures: forged authorship, exfiltration instructions, lookalike hosts, invisible-character address spoofing.

**Verified, not vibed.** Mock-driven tests with no live calls, red-green proofs for every fix, live smoke scripts only at gates, and a written feasibility study in which every engine claim was tested on a real machine before a line of app code existed.

**Full design document: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).**

## Planned repository contents

```
Sources/AgencyApp     SwiftUI — threads, group chat, queues, attachments
Sources/AgencyKit     engine — sessions, sandboxing, egress, vault, teams
Sources/agency-cli    headless driver (also what the smoke scripts use)
Resources/mcp         Apple Messages + Apple Mail MCP servers (Node, zero deps)
Tests                 379 tests, no live calls
scripts               build/sign, live smoke gates
```

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Anthropic. Built by [Lorenzo Colombani](https://github.com/LorenzoColombani).
