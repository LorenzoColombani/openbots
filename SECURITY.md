# Security

OpenBots' whole premise is running semi-trusted AI agents on a personal Mac.
The fences are in the source: each bot works in its own folder, web access and
every connector are off until you switch them on for that bot, text that
connectors hand back is marked as untrusted material before a bot reads it, and
every consequential action waits on a card you approve.

## Reporting a vulnerability

If you find a way through a fence (a read that should have been denied, an
action that ran without its card, an injection that survives
neutralization), please report it privately via
[GitHub's private vulnerability reporting](../../security/advisories/new)
rather than a public issue. Include the smallest reproduction you can — the
test suite's existing injection fixtures are a good template.

## Scope notes

- This is a single-user desktop app; there is no server component and no
  multi-tenancy. Attacks requiring another local user account are out of the
  intended threat model.
- Agents you grant Mail/Messages/shell to act with **your** TCC permissions —
  a generous grant is a decision, not a vulnerability.
- Only the latest release is supported.
