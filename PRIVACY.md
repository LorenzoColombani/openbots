# Privacy Policy — OpenBots (Next preview)

_Draft written from templates, updated 2026-09-01 for the rebuilt app. **Not yet reviewed by a lawyer.** It states what the software does; it is not legal advice._

**This is a pre-release preview — a working version, not a finalized product. You use it at your own risk; it comes with no warranty.**

## The short version
Everything runs and is stored **locally on your Mac**. OpenBots sends **no telemetry** and phones home to nothing. Your messages reach Anthropic only through **your own Claude Code login**, under Anthropic's terms.

## What the app stores, and where
- Teammates, conversations, drafts, attachments, memory files, approval records and the audit trail live in an **app-owned folder on your Mac** (`~/Library/Application Support/com.lorenzocolombani.openbotsnext.preview`), in SQLite databases and files the app protects with owner-only permissions. Uninstalling = deleting the app and that folder.
- Nothing is uploaded to the developer. There is no account, no sign-up, no analytics, no crash reporting.

## What leaves your Mac, and only when you act
- **Claude.** A live reply runs as one local Claude Code CLI call signed in with *your* Anthropic account. What you send goes to Anthropic exactly as it would from the CLI, under [Anthropic's terms](https://www.anthropic.com/legal) and privacy policy. OpenBots never holds an API key and never harvests credentials: its build and package tooling runs network operations through a credential-free wrapper, and anything authenticated is an explicit, visible step.
- **Nothing else.** This preview has **no connectors and no executor**: consequential actions (sending something, paying something, deleting something outside the app's folder) are recorded as exact, immutable proposals you can read — they are **not executed** by this build. There is no web access, no shell access, and no integration with Mail, Messages or other accounts in this version.

## Permissions
This preview requests no special macOS permissions (no Full Disk Access, no Automation, no Screen Recording).

## Contact
Open an issue on the project's GitHub repository.
