# Agency — design and architecture

This document is the design half of the project: what Agency is, the decisions
that shaped it, and the mechanisms that make multi-agent work safe on a
personal machine. The Swift source follows next week.

---

## 1. The idea

Most "multi-agent" tooling spawns anonymous workers inside one conversation.
Agency inverts that: **a conversation *is* an agent**. You hire a teammate, it
interviews you about its own job, and from then on it is a named colleague with
a persistent session, its own memory, its own permissions, and a face in a
sidebar. Work moves between teammates through handoffs you can watch.

Three properties follow from that inversion, and they drive everything else:

1. **Persistence is the product.** A teammate you re-brief every morning is a
   prompt, not a colleague. Sessions must survive quits, reboots, and weeks.
2. **Autonomy demands containment.** An agent with memory, shell, and network
   is a standing capability, not a one-off answer. Fences are load-bearing.
3. **Coordination must be visible.** If agents talk to each other invisibly,
   the human cannot audit, correct, or trust the result.

## 2. Engine

Each teammate is a **headless Claude Code session**: `claude -p` with
`--resume <session-id>`, `--output-format stream-json` for token-level
streaming, `--add-dir` for the shared vault, and an explicit
`--allowedTools` / `--disallowedTools` pair.

Every engine claim was tested on a real machine before app code existed —
resumption really recalls history, session forking really clones context,
cross-session messaging really round-trips. The feasibility study came first,
the implementation plan second, the code third.

**Billing rides a claude.ai subscription, never an API key.** Child processes
strip `ANTHROPIC_API_KEY` from their environment defensively, and a test
asserts it: if a key is present in the parent, it must not reach the child.

## 3. Containment: two halves, because they fail differently

| Half | Mechanism | Binds | Fails |
|---|---|---|---|
| Tool fence | `settings.json` deny rules per agent | the CLI's Read/Edit/Write/Glob/Grep | pattern-matched — a path spelled differently slips |
| Kernel fence | Seatbelt (`sandbox-exec`) profile per run | everything the process does, including Bash | path-matched on the *real* path |

Neither is sufficient. Deny rules do not bind Bash, so a shell-enabled agent
would walk straight past them. Seatbelt cannot express "this tool may not read
that file" and, in the permissive profile a working agent needs, does not fence
reads at all. Together they cover each other's blind spots.

Hard-won details:

- **`--add-dir` fences writes, never reads.** Reads by absolute path go
  anywhere the process can reach. This is the recurring hole class; every
  sealed location needs an explicit read-deny, not just a directory scope.
- **Seatbelt matches real paths.** Swift's `URL.resolvingSymlinksInPath()`
  does *not* resolve `/var → /private/var`, so a profile built from it silently
  matches nothing under temp paths — a fence that fails **open** while a string
  comparison test still passes. Resolution goes through libc `realpath(3)`, and
  profiles are validated with real `sandbox-exec` runs, never string tests.
- **Deny beats allow, and order matters.** Seatbelt takes the *last* matching
  rule, so pocket denials must follow the vault allow-back or the allow
  reopens them.
- **Credential stores are never read-denied.** Denying
  `~/Library/Keychains` breaks the CLI's own authentication — bisected the
  hard way. Sealing is targeted at data, not at the auth path.

## 4. Network egress fence

Fenced runs get **one road out**: a loopback-only HTTP `CONNECT` proxy started
per run, passed to the child as `HTTPS_PROXY`, with Seatbelt denying every
other outbound route. Allowlisted hosts tunnel through a blind TCP relay — no
TLS interception, since the CONNECT line already carries the hostname.

Design points that came out of review and live testing:

- **Host matching is label-anchored.** The host must equal the entry or end
  with `"." + entry`, so a lookalike registration (`evil-anthropic.com`) never
  matches.
- **Ports are allowlisted too.** A host-only allowlist would happily tunnel
  `CONNECT allowed-host:25`. Everything real is TLS on 443.
- **The listener binds `127.0.0.1` explicitly.** `NWListener` defaults to all
  interfaces, which would put the "local" proxy on the LAN.
- **`localhost:*` is not an allowlist.** Allowing all loopback ports would make
  any dev proxy or SSH tunnel a zero-effort bypass; only the run's own port is
  allowed.
- **Denials are visible, not silent.** A refused host becomes a thread notice,
  which is what turns an exfiltration attempt into evidence. The exception is
  the runtime's own telemetry, which is suppressed from the UI after being
  identified — otherwise real signals drown in noise.
- **Vendor domains rot.** When the CLI auto-updated and began calling a new
  vendor host, every fenced run died instantly. Allowlist *registrable
  domains*, and when a fenced child starts failing with no code change, read
  the fence's own denial log first.

## 5. The vault, and pockets

All teammates share an **Obsidian-compatible Markdown vault** — plain files,
no database, openable by the human at any time. Inside it:

- `vault/private/<agent>` — one agent's pocket, sealed both ways from others
- `vault/teams/<team>` — shared by that team's members only
- agent notebooks are symlinked into the vault so nothing an agent knows is
  invisible to the human

Writes go through a **provenance ledger**. It flags the obvious case (agent A
overwrote agent B's note) and the non-obvious one: a *new* file planted in a
namespace its author does not own. Diff-based checks never fire on creation,
which is exactly how a planted file slips past a rewrite alarm — so ownership
is checked positively, not only historically.

## 6. Coordination

- `@teammate question` at the start of a message **relays**: this agent asks
  that one, and both legs render in both threads.
- Multi-line `RELAY @name:` blocks let an agent delegate mid-answer, with the
  block body running to the next directive or the end of the message.
- **Hop budgets** bound the graph: relays cost a hop, fan-out width is free up
  to a cap, fan-in wakes are free. Runaway ping-pong terminates.
- **Group threads** key on `#<team>`. Because members are independent
  sessions, each gets a **cursor delta** of what it has not yet seen —
  computed against the on-disk log order, never the UI array, which reloads
  can clobber. Deltas carry outcomes, not every internal leg.

## 7. Connectors

Optional, per-agent, off by default. Two are custom-built because the
off-the-shelf versions were wrong in instructive ways:

**Apple Messages.** The stock integration hardcodes iMessage, which silently
fails to Android contacts. `buddy X of <service>` *always* resolves — no error
is ever raised — so "try iMessage, catch, fall back" is impossible. The fix is
to pick the service from **history**: three tiers of chat.db evidence
(per-message service, thread service, handle service), then verify delivery
afterwards against the database rather than trusting the send. Message bodies
mostly live in `attributedBody` as NeXT `streamtyped` archives, not in
`message.text`, so the server decodes them properly instead of returning hex.

**Apple Mail.** Sends as the human, through their own Mail.app. No default
account — accounts are different identities, so every send names one. All
failable work (resolving account, signature, recipients) happens *before* the
outgoing message is created, because a compose window that fails afterwards is
unremovable until Mail restarts.

Both servers pass recipients and bodies as `argv` into `on run argv` — never
interpolated into AppleScript source — and reject invisible/bidi characters in
addresses, since a zero-width space makes a handle read identically to a
different string.

## 8. Testing and process

- Tests are mock-driven with **no live calls**; fixtures mirror real captured
  event streams rather than being invented to match the code.
- Every bug fix ships with a **red-green proof**: the test must fail against
  the unfixed code, or it is not testing the fix.
- Live smoke scripts exist but run only at gates, never in loops.
- Features go through a definition-of-done pipeline: verification with
  evidence, live behavior verification in the real app, adversarial code
  review, then triage where every finding is *empirically checked* before
  being accepted or rejected. Several fence rules above exist because a review
  round broke the previous version.

## 9. Honest limitations

- Single-user by design. The connectors automate the user's own apps through
  their existing macOS permission grants; there is no multi-tenancy story.
- macOS-only, and tied to Apple's TCC model — permissions are granted to a
  code signature, so rebuilding with a different identity re-prompts.
- Live usage bills the connected subscription.
- The operator is addressed by first name throughout the personas; renaming is
  a search-and-replace, not a refactor.
