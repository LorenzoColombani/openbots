# Connectors

A connector lets a bot use one of your apps or accounts. Each one is **off until you
turn it on for a bot**, under that bot's Access, and a bot can have at most thirteen
on. Anything that sends, changes or clicks something waits on a **card** you
approve; reading usually does not (Control Chrome cards everything).

Text a connector hands back (a mail, a message, a web page) is marked as untrusted
before the bot reads it, so instructions hidden inside it are treated as content,
not as orders. That lowers the risk of prompt injection; it does not remove it.
Read each card before you approve it.

**Every connector needs Node.js** at `/opt/homebrew/bin/node` or
`/usr/local/bin/node` (see [Install](INSTALL.md)). When something a connector needs
is missing, its row in **Settings → Connectors & Skills** says what, and how to fix
it.

## Apple apps

| Connector | Can | Needs |
|---|---|---|
| **Apple Mail** (read) | search and read your mail; no send, no delete | `uv tool install apple-mail-fast-mcp==0.10.2`; Automation for Mail; Mail open |
| **Apple Mail send** | send as you, from the account the card names | Automation for Mail; a card for every message |
| **Messages** (iMessage, RCS, SMS) | read only the chats you pick for that bot; send from your number | **Full Disk Access** (add it yourself, macOS never asks); Automation for Messages; a card for every message |
| **Contacts** | read | Automation for Contacts |
| **Calendar** | read | the Calendars permission |
| **Apple Notes** | list, read, add and replace notes; adding and replacing are carded | Anthropic's Notes extension for Claude Desktop, version 0.1.7; Automation for Notes |

The Apple Mail reader is a third-party tool. If you once ran its `setup-imap`
command, it reads mail over the network through IMAP instead of from Mail on this
Mac. The app cannot prevent that.

## Browsers

| Connector | Can | Needs |
|---|---|---|
| **Control Chrome** | in your own, signed-in Chrome: list tabs, read a page's words, open an address, close, reload or switch tabs; every action, reading included, is carded; running scripts is not offered | Anthropic's Chrome extension for Claude Desktop, version 0.1.6; Chrome open (a bot never starts it); in Chrome, **View → Developer → Allow JavaScript from Apple Events** to read pages |
| **Browser** (chrome-devtools-mcp) | browse in a separate, invisible Chrome with its own empty profile, deleted when the reply ends; looking at a page is quiet, opening a page or changing what the browser has installed is carded | the chrome-devtools-mcp plugin switched on in Claude Code; its version already downloaded once (the app never downloads it: run it once with `npx` in Terminal); Google Chrome installed |

**About the Claude Desktop extensions.** The app uses the Notes and Chrome
extensions that the Claude Desktop app installs, exactly the versions above, from
`~/Library/Application Support/Claude/Claude Extensions`. Install Claude Desktop and
add those extensions there. Any other version shows as unavailable until the app is
updated for it.

## Google

Gmail, Gmail send, Google Calendar and Google Drive, through a separate Google
account. This one needs your own Google sign-in client, set up once:
[Connect Gmail, Google Calendar and Google Drive](guides/google-setup.md).

## Control this Mac

Lets a bot look at your screen, click and type, through the open-source
[Peekaboo](https://github.com/steipete/Peekaboo) 4.0.0. Treat it as a trial.

- Needs macOS 15 or later, and **Accessibility** plus **Screen Recording** for
  OpenBots Next (then quit and reopen the app).
- Run `npx -y @steipete/peekaboo@4.0.0 --version` once in Terminal, so the exact
  version is on the Mac. The app checks the binary it runs against a pinned hash.
- The first action of a reply waits on a card. On that card, **Allow for this turn**
  lets the rest of that reply go on without asking again. While any card is open,
  no bot's screen action runs, so a bot cannot press Approve for you.
- After 64 rounds on your Mac in one reply, the bot asks to keep going on a card.
  Deny ends the reply and keeps what it wrote.

## Not offered

The Claude Desktop filesystem, AppleScript and iMessage extensions are not offered:
work on this Mac, Messages and the fenced connectors above cover those jobs with
cards in front.
