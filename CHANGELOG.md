# Changelog

## v1.0.2 — 27 September 2026

- **New models.** Each bot's model picker offers Claude Opus 5.5 (its default
  intensity is medium) and Claude Fable 5.1. Fable 5.1 shows a warning directly
  under the picker: once your plan's Fable allowance runs out, its replies are
  billed to your usage credits if you have turned them on. Fable 5 leaves the
  list; a bot that saved it keeps the preference and is refused at launch as before.
- **Claude Code 2.1.283.** Its keep-alive pings during a long file write no longer
  end a reply, and time a reply spends waiting on your approval cards no longer
  counts against its fifteen minutes (up to forty-five minutes of cards).
- **Failed replies explain themselves.** The chip under a failed reply opens to say
  what happened in words, with the code to quote and a link to the "What happened"
  record. When a reply fails, the app keeps a private record of it (the last five,
  on your Mac only, never for a reply that used a secret) so the cause can be found.

## v1.0.1 — 26 September 2026

- **Install guide.** The install steps as 16 short cards: a [web page](https://lorenzocolombani.github.io/openbots/guides/install-guide.html)
  with a Copy button on every command, and the same cards as [pictures](docs/guides/install-cards/README.md).
- **Older Macs.** The workspace loads projects and teams one after the other,
  no longer through the `async let` pattern that, on macOS 15, kept a test's
  database open long after it finished.
- **Docs.** The Google install line in the README no longer breaks when pasted
  into zsh; removal starts by disconnecting Google; the Node check covers both
  install locations; the privacy page says what the Contacts permission is for.

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
