# Security

Agency's whole premise is running semi-trusted AI agents on a personal Mac, so
its threat model is documented in the open: see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §3 (containment) and §4
(network egress fence) for what the fences promise and — just as important —
what they don't.

## Reporting a vulnerability

If you find a way through a fence (a read that should have been denied, an
egress path that bypasses the proxy, an injection that survives
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
