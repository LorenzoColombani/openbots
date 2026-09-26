# Changelog

## v1.0.0 — 25 September 2026

v0.5.0 rebuilt the foundation. v1 brings the old app's abilities back on it, each
behind an approval card.

- **Work on this Mac.** A bot works in its own folder, writes files and runs code.
  A script runs only after you approve its card, and Stop ends the whole process
  tree, background runs included.
- **The web.** Search and fetch, switched on per bot.
- **Connectors.** Apple Mail (read, and send as you), Messages, Contacts, Calendar,
  Apple Notes, Control Chrome, a separate browser through chrome-devtools-mcp,
  Gmail, Google Calendar and Google Drive, and Control this Mac through Peekaboo.
  See [docs/CONNECTORS.md](docs/CONNECTORS.md).
- **Teams.** Bots hand work to each other in view, and a bot can hire a new
  teammate or a short-lived worker for one job.
- **Per-bot switches.** Nothing is on until you turn it on for that bot.
- **Setup docs.** [Install](docs/INSTALL.md), [Connectors](docs/CONNECTORS.md) and
  a step-by-step [Google setup guide](docs/guides/google-setup.md). The installer
  takes your own Google client ID (`OPENBOTS_GOOGLE_OAUTH_CLIENT_ID`).
- **Tested against Claude Code 2.1.282**, with recorded runs of 2.1.272 to 2.1.282
  replayed in the suite: 3,196 tests, no live calls, on macOS 15 and 26 in CI.

Needs Xcode 16.3 or later (Swift 6.1), up from Xcode 16.

## v0.5.0 — 1 September 2026

The ground-up rebuild: durable SQLite persistence on the system library, a stricter
security boundary, honest approval semantics and a simpler Claude sign-in, with
fewer visible features than v0.1.0. Chat, teammate identity, drafts, archives,
search, durable history and single live replies through your Claude Code CLI.

## v0.1.0 — 17 August 2026

First source release, under the working name *Agency*.
