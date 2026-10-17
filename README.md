# OpenBots

**Persistent, named AI teammates as a native macOS app — rebuilt.**

[![CI](https://github.com/LorenzoColombani/openbots/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LorenzoColombani/openbots/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/LorenzoColombani/openbots?label=release)](https://github.com/LorenzoColombani/openbots/releases/latest) ![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-blue) [![MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

OpenBots turns Claude into a team of named teammates you hire, brief, and fence yourself. The app you install is called **OpenBots Next**: that is the name you will see in `/Applications`, the Dock and System Settings. This is the second-generation codebase (the "Next" rebuild): a modular Swift 6 / macOS 14 SwiftUI + AppKit app with durable local state, explicit approvals, and honest uncertainty — a saved plan is never presented as an executed action.

> **Status: v1.** Bots chat, work in their own folders, search and fetch the web, run code, hire helpers, hand work to each other, and use your Mac's apps through connectors. Every consequential step (a send, a script, a click on your screen) waits on a card you approve. No telemetry, no accounts, no server: everything lives on your Mac, and Claude runs through your own Claude Code login.

## What's in the build

- **Chat-first native UI** — sidebar/detail, stable teammate identities and avatars, conversational hiring with explicit confirmation, per-conversation drafts, keyset-paged history, workspace search, archive/restore without data loss.
- **Durable local state** — protected SQLite (app-owned `0700` roots, `0600` files), atomic repositories, exact startup/reopen restoration, scoped Markdown memory with explicit non-authoritative snapshots.
- **Claude through your own CLI** — replies run as one local `claude` call against your Claude Pro or Max plan, signed in on the app's own Claude Code profile. No API key, no credential harvesting: public network operations run through an isolated, credential-free wrapper (`Scripts/swiftpm-public.sh`), and authenticated access is always an explicit, visible step.
- **Tested Claude versions** — OpenBots retains a working Claude executable. A new version must pass the app's compatibility checks before replacing it. Your separate Claude Code installation stays under your control.
- **Approvals that mean something** — consequential actions become immutable proposals whose exact payload you see and approve; a simulated acknowledgement is never treated as acceptance, and an approval is never silently treated as execution or a capability grant.
- **Attachments and previews** — durable owned attachments, in-chat saved text, image and static-PDF preview with scope fences and cancellation.
- **Per-bot switches** — each bot has its own switches for work on this Mac, web search, web fetch, hiring, and every connector; nothing is on until you turn it on for that bot.
- **Connectors** — Apple Mail (read, and send as you), Messages (iMessage, RCS, SMS), Contacts and Calendar (read-only), Apple Notes and Control Chrome (Anthropic's Claude Desktop extensions), a browser through chrome-devtools-mcp, Gmail, Google Calendar and Google Drive (through a separate Google account you connect), and Control this Mac (through Peekaboo). Each call that acts shows a card first. What each needs: [docs/CONNECTORS.md](docs/CONNECTORS.md).
- **Teams and handoffs** — bots hand work to each other in view, and a bot can hire a new bot or a short-lived worker for one job.

## What it does not do

- **No API key, no accounts, no server, no telemetry.** Replies go through your own
  Claude Code login; nothing is sent to the developer.
- **Nothing runs unasked.** Beyond chat, every ability is off until you switch it on
  for a bot, and anything consequential waits on a card. A bot cannot turn on its
  own connectors, hiring or Control this Mac.
- **Bots stop when the app closes.** An approved app installation can finish after
  normal Quit. There is no login item or persistent background service.
- **No guarantee against a bot being fooled.** Bots are language models: they can be
  wrong, and a mail or web page can try to steer them. Text from outside is marked
  as untrusted before a bot reads it, which lowers the risk without removing it.
  Read each card before you approve it.
- **No prebuilt app.** You build it on your Mac (the installer does it for you).

## Before you install

- An Apple Silicon Mac that supports your Xcode version. The app targets macOS 14;
  local builds need a newer system. See [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements).
- Full **Xcode 16.3+** at `/Applications/Xcode.app`, opened once to finish setup.
  Your macOS version must also support the Xcode version you install.
  Add your Apple account in Xcode and create an **Apple Development** certificate
  for your own team. A free Personal Team is sufficient; paid Developer ID
  distribution membership is not required. Command Line Tools alone are not enough.
- **Claude Code from Anthropic's native installer** (`curl -fsSL https://claude.ai/install.sh | bash`)
  and a **Claude Pro or Max** plan. An npm or Homebrew install of Claude Code, an API
  key, a Team or an Enterprise login is not accepted. OpenBots Next signs in to Claude
  with its own profile, separate from your Terminal login.
- **Node.js** from Homebrew or nodejs.org is required for first runtime activation
  and for connectors (at `/opt/homebrew/bin/node` or `/usr/local/bin/node`; nvm,
  volta or asdf installs are not found). The first compatibility suite uses an
  inert Node fixture.
- **Google needs your own sign-in client.** Gmail, Google Calendar and Google Drive
  work only after you create a Google Desktop OAuth client and build its ID in:
  [the Google setup guide](docs/guides/google-setup.md) walks through it.

Details, permissions, updating and removal: **[docs/INSTALL.md](docs/INSTALL.md)**.
Every connector and what it needs: **[docs/CONNECTORS.md](docs/CONNECTORS.md)**.

## Install

<a href="https://lorenzocolombani.github.io/openbots/guides/install-guide.html"><img src="docs/guides/install-cards/01-cover.png" width="260" align="right" alt="The install guide's cover card: One line builds OpenBots Next on your own Mac."></a>

**New to this? Start with the [install guide](https://lorenzocolombani.github.io/openbots/guides/install-guide.html):** the steps as 18 short cards, with a Copy button on every command. The same cards as [pictures](docs/guides/install-cards/README.md), and every detail in [docs/INSTALL.md](docs/INSTALL.md).

Quit OpenBots Next normally before installing or bootstrapping an older version.

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
```

The installer reads the published release feed, downloads the one commit it names,
checks every file against the feed's SHA-256 list, builds it with your own Apple
Development certificate, verifies the candidate, and replaces the stopped app in
place. It keeps one copy of the previous app outside `/Applications`, refuses a
downgrade, and leaves app data and credentials in place. If the build fails, it
prints the path of its build log. If several signing teams are available, choose
your own with `OPENBOTS_DEVELOPMENT_TEAM`.

For Google, provide your own public Desktop client ID:

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh \
  | OPENBOTS_GOOGLE_OAUTH_CLIENT_ID=1234-abcd.apps.googleusercontent.com sh
```

An existing installation's embedded Google client ID is preserved automatically,
and an installation built without one can have it added the same way. Replacing a
different ID needs `OPENBOTS_REPLACE_GOOGLE_CLIENT_ID=1` as well (see the
[Google setup guide](docs/guides/google-setup.md)). The new app saves that public
configuration on first launch. Existing saved configuration and Keychain
credentials stay in place.

From a clean public clone:

```sh
/usr/bin/python3 -I -B -S Scripts/bootstrap-install.py --source .
```

Use `--prepare-only` to build and verify a candidate without installing or opening
it. Older 1.0.2 installations need this one-time bootstrap. Afterward, use **Update
now** in the app: it verifies the signed source release and builds locally with
Xcode before offering installation.

The [update guide](docs/UPDATES.md) describes signature verification, cancellation,
configuration preservation and recovery.

Read **[docs/INSTALL.md](docs/INSTALL.md)** for signing setup, recovery and updates.

Complete the separate compatibility-profile sign-in and first compatibility suite,
then sign in to the primary chat profile through Claude Code's official flow.
Follow the [first-run steps](docs/INSTALL.md#first-run) before creating a bot.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/swiftpm-public.sh test --no-parallel --scratch-path .build.noindex/gate
```

The XCTest and Swift Testing suites run serially without live provider calls.
Pure Python tests cover source-update and bootstrap safety; CI also checks source
content and compiles an unsigned app for compiler coverage. That CI artifact is
not an installable release. See [build and test guidance](docs/INSTALL.md#build-and-test-the-source).

## Data, privacy, legal

The app's records live in an app-owned folder under `~/Library/Application Support`, and your bots' working files in `~/OpenBots Next Preview Content`. Claude replies and compatibility checks use your own login. Enabled connectors contact their services. Update checks and source downloads contact GitHub; builds fetch nothing else. See [PRIVACY.md](PRIVACY.md), [TERMS.md](TERMS.md) and [SECURITY.md](SECURITY.md).

## Design credits

Some of OpenBots' team features were shaped by studying xAI's Grok Bot app. Earlier releases credited these ideas in code comments: teams of two to six bots, a 4,000-character limit on a bot's instructions, saving a message before it is sent, a read-only mode for side conversations, and copying a bot. The list of actions a bot had to ask about before doing them followed safety guidance xAI has published.

Later sources use neutral names for the tests and notes that grew out of that study. No code, text or screens from Grok Bot are included.

Grok and xAI are trademarks of their owner. OpenBots is not affiliated with or endorsed by xAI.

Designed and developed by Lorenzo Colombani; implementation is AI-assisted under his direction and review.

[MIT licensed](LICENSE). Read [SECURITY.md](SECURITY.md) before reporting a security issue.

