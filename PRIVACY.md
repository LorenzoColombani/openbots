# Privacy Policy — OpenBots

_Draft written from templates, updated for v1. **Not yet reviewed by a lawyer.** It states what the software does; it is not legal advice._

**You use this software at your own risk; it comes with no warranty.**

## The short version
Everything runs and is stored **locally on your Mac**. OpenBots sends **no telemetry** and phones home to nothing. Your messages reach Anthropic only through **your own Claude Code login**, under Anthropic's terms.

## What the app stores, and where
- Teammates, conversations, drafts, attachments, memory files, approval records and the audit trail live in an **app-owned folder on your Mac** (`~/Library/Application Support/com.lorenzocolombani.openbotsnext.preview`), in SQLite databases and files the app protects with owner-only permissions. That folder also holds the app's own Claude Code sign-in.
- Your bots' working files (their folders, shared files, projects, skills and exports) live in `~/OpenBots Next Preview Content`, where you can open them. The app also keeps a cache in `~/Library/Caches/com.lorenzocolombani.openbotsnext.preview.noindex` and scratch files in your temporary folder.
- If you connect a Google account, its sign-in tokens and your Google client secret are kept in your Mac's local Keychain, in items that do not sync to iCloud.
- Uninstalling means deleting the app, those folders and those Keychain items; [docs/INSTALL.md](docs/INSTALL.md#remove-completely) lists them.
- Nothing is uploaded to the developer. There is no account, no sign-up, no analytics, no crash reporting.

## What leaves your Mac, and only when you act
- **Claude.** A live reply runs as one local Claude Code CLI call signed in with *your* Anthropic account. What you send goes to Anthropic exactly as it would from the CLI, under [Anthropic's terms](https://www.anthropic.com/legal) and privacy policy. OpenBots never holds an API key and never harvests credentials: its build and package tooling runs network operations through a credential-free wrapper, and anything authenticated is an explicit, visible step.
- **What your bots use, when you switch it on for them.** Web search and web fetch reach the web through Claude Code's own tools. Connectors act on your Mac's apps (Mail, Messages, Contacts, Calendar, Notes, Chrome) and, if you connect one, on a Google account (Gmail, Google Calendar, Google Drive) through Google's APIs. Some connectors run published tools you install yourself (apple-mail-fast-mcp, chrome-devtools-mcp, Peekaboo) or Anthropic's Claude Desktop extensions (Notes, Chrome); the app never downloads them. Every call that sends, changes or clicks something shows a card first; nothing goes out unless you approve it.
- **Nothing else.** No telemetry, no analytics, no crash reporting, nothing sent to the developer.

## Permissions
macOS asks for a permission only when you use the feature that needs it: Contacts and Calendars for those connectors, Automation to drive Mail, Messages, Contacts, Notes or Chrome, Full Disk Access to read your Messages history, and Accessibility plus Screen Recording for Control this Mac. You can refuse or withdraw any of them in System Settings; the rest of the app keeps working.

## Contact
Open an issue on the project's GitHub repository.
