# Install, update and remove OpenBots

The app is called **OpenBots Next**: that is the name you will see in
`/Applications`, the Dock and System Settings.

OpenBots Next is built on your Mac from source. There is no downloadable app: a build
made on your own Mac is not quarantined, so macOS opens it without a Gatekeeper
warning.

Prefer pictures? The same steps as 16 short cards: [the install cards](guides/install-cards/README.md).

## Before you start

| You need | Why | Check |
|---|---|---|
| A Mac with Apple Silicon, macOS 14 or later | The build targets arm64 only. Control this Mac needs macOS 15 or later. | Apple menu → About This Mac |
| Full **Xcode 16.3 or later** at `/Applications/Xcode.app` | The app is built with Swift 6.1. Command Line Tools alone cannot build it. | Open Xcode once, so it finishes its own setup. |
| **Claude Code**, installed with Anthropic's native installer | Every reply runs through it. | `ls -l ~/.local/bin/claude` |
| A **Claude Pro or Max** plan | Replies count against your plan. | — |
| **Node.js** at `/opt/homebrew/bin/node` or `/usr/local/bin/node` | Only for connectors (every connector runs behind a small Node fence). Chat, work in folders and the web need no Node. | `ls /opt/homebrew/bin/node /usr/local/bin/node` (one of the two is enough) |

Things that surprise people:

- **Claude Code must be Anthropic's own build**, installed with
  `curl -fsSL https://claude.ai/install.sh | bash`. The app looks only at
  `~/.local/bin/claude`, and checks that it is signed by Anthropic. An npm or
  Homebrew install is refused as "not the official one".
- **Only a claude.ai Pro or Max login counts.** An API key, a Team or an Enterprise
  login is not accepted: the app reports that it could not confirm your
  subscription. The app never asks for an API key.
- **OpenBots Next signs in to Claude separately.** It keeps its own Claude Code profile
  inside its data folder, so your usual `claude` login in Terminal is not reused and
  not touched. You sign in once, from the app (see *First run*).
- **Node from nvm, volta or asdf is not found.** Install Node with Homebrew
  (`brew install node`) or the installer from nodejs.org, which put it in one of the
  two places above.
- **The app is tested against Claude Code 2.1.282.** Claude Code updates itself.
  When a newer version is installed, Settings says so, and if replies start failing,
  that update is the likely reason.

## Install with one line

```sh
curl -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
```

It checks for Apple Silicon and Xcode, downloads the latest release's source,
builds it (a few minutes the first time), copies **OpenBots Next.app** to
`/Applications` (replacing an older copy) and opens it. It asks nothing and
removes its temporary folder when it ends.

To use the Google connectors, you also pass your own Google client ID; see
[Connect Gmail, Google Calendar and Google Drive](guides/google-setup.md).

## Build from a clone

```sh
git clone https://github.com/LorenzoColombani/openbots.git
cd openbots
Scripts/build-preview.sh
open ".build.noindex/preview/DerivedData/Build/Products/Debug/OpenBots Next.app"
```

## First run

1. **Settings → General & Claude Code → Check Claude.** The app looks at Claude
   Code on this Mac and at your plan.
2. **Sign in.** The app opens Claude Code in Terminal on its own profile. Sign in
   with your Claude Pro or Max account, then come back and check again.
3. **Create a bot** with the **+ New** button, or pick one from the list, and say
   hello.

Everything a bot can reach beyond the chat (work in a folder, the web, hiring,
each connector) is **off until you turn it on for that bot**. See
[Connectors](CONNECTORS.md).

## macOS permissions

macOS asks for a permission only when a feature that needs it is first used:

| Feature | Permission (System Settings → Privacy & Security) |
|---|---|
| Mail, Messages, Contacts, Notes, Chrome | **Automation**, for that app |
| Calendar | **Calendars** |
| Messages history | **Full Disk Access**. macOS never asks for this one: add OpenBots Next yourself, then quit and reopen it. |
| Names in the Messages chat picker | **Contacts** |
| Control this Mac | **Accessibility** and **Screen Recording**, then quit and reopen |

You can refuse or withdraw any of them. The rest of the app keeps working.

## Good to know

- **An ad-hoc build can ask for permissions again.** The one-line installer and a
  clone build both sign the app with your **Apple Development** certificate if you
  have one in your keychain, and ad hoc otherwise. An ad-hoc build is a new program
  to macOS every time: permissions you granted (Automation, Accessibility and so on)
  and the Google helper's Keychain access may be asked for again after each rebuild.
- **Closing the last window quits the app.** Bots do not run in the background, and
  the app installs no login item or background service.
- **Your bots' files** live in `~/OpenBots Next Preview Content` (each bot's
  folder, shared files, projects, skills and exports). The app's own records live
  in its Application Support folder.

## Update

Run the one-line installer again, or `git pull` and `Scripts/build-preview.sh` in
your clone. Your data is kept. If you use Google, pass your client ID again, or the
new build has no Google client.

## Remove completely

1. If you connected Google, use **Disconnect Google account** in Settings while the
   app is still installed, or remove the app at
   <https://myaccount.google.com/permissions>.
2. Quit OpenBots Next and delete `/Applications/OpenBots Next.app`.
3. Delete its data. **Copy out anything you want to keep first**, especially your
   bots' files:
   - `~/OpenBots Next Preview Content`
   - `~/Library/Application Support/com.lorenzocolombani.openbotsnext.preview`
   - `~/Library/Caches/com.lorenzocolombani.openbotsnext.preview.noindex`
4. If you connected Google, in Keychain Access, delete the items whose name starts
   with `com.lorenzocolombani.openbotsnext.preview`.
5. Remove the permissions you gave it under System Settings → Privacy & Security.
