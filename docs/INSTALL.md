# Install, update and remove OpenBots

The app is called **OpenBots Next**: that is the name you will see in
`/Applications`, the Dock and System Settings.

OpenBots Next is built on your Mac from reviewed public source using your own
Apple Development certificate. A paid Apple Developer Program membership is not
required. This guide covers the current source bootstrap.

Prefer an easier read? The [install guide](https://lorenzocolombani.github.io/openbots/guides/install-guide.html) has the same steps as 18 short cards, with a Copy button on every command (also as [pictures](guides/install-cards/README.md)).

## Before you start

| You need | Why | Check |
|---|---|---|
| An Apple Silicon Mac that supports your Xcode version | The app targets macOS 14, but building it locally requires a newer system: Xcode 16.3 needs macOS 15.2 or later. | Check [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements) for your chosen version. |
| Full **Xcode 16.3 or later** at `/Applications/Xcode.app` | The app is built with Swift 6.1. Command Line Tools alone cannot build it. | Open Xcode once, so it finishes its own setup. |
| Your own **Apple Development** certificate | Local builds keep a stable signing identity. There is no ad-hoc fallback. | Xcode → Settings → Accounts: add your Apple account, select your team, Manage Certificates → Apple Development. A free Personal Team is sufficient. |
| **Claude Code**, installed with Anthropic's native installer | Every reply runs through it. | `ls -l ~/.local/bin/claude` |
| A **Claude Pro or Max** plan | Replies count against your plan. | — |
| **Node.js** at `/opt/homebrew/bin/node` or `/usr/local/bin/node` | Required for first runtime activation: the compatibility suite uses an inert Node fixture. Connectors also use Node afterward. | `ls /opt/homebrew/bin/node /usr/local/bin/node` (one of the two is enough) |

Things that surprise people:

- **Claude Code must be Anthropic's own build**, installed with
  `curl -fsSL https://claude.ai/install.sh | bash`. The app looks only at
  `~/.local/bin/claude`, and checks that it is signed by Anthropic. An npm or
  Homebrew install is refused as "not the official one".
- **Only a claude.ai Pro or Max login counts.** An API key, a Team or an Enterprise
  login is not accepted: the app reports that it could not confirm your
  subscription. The app never asks for an API key.
- **OpenBots Next keeps two separate Claude sign-ins.** The first compatibility
  suite uses its own `CompatibilityProfile`. After that suite passes, sign in to
  the primary profile for everyday chats. Both use Claude Code's official sign-in
  flow. Neither reuses or changes your usual `claude` login in Terminal; credentials
  are not copied between these profiles. See *First run*.
- **Node from nvm, volta or asdf is not found.** Install Node with Homebrew
  (`brew install node`) or the installer from nodejs.org, which put it in one of the
  two places above.
- The app checks the local Claude Code installation and reports compatibility in
  Settings. Follow that status before starting work.

## Install or bootstrap an older version

Quit OpenBots Next normally first. The installer never forces the app to quit or
replaces it while it is running.

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
```

What the installer does, in order:

1. Checks that full Xcode 16.3 or later is installed and its license accepted.
2. Reads the published release feed, `docs/updates/source-update.json` on `main`.
   The feed names one immutable source commit, its version and build number, and
   the SHA-256 and mode of every file in it. If nothing is published yet, the
   installer stops with "No published release yet"; it never builds whatever
   happens to be on `main`.
3. Downloads the bootstrap script of that commit and compares it with the feed's
   SHA-256 before running it. The bootstrap then downloads the source archive of
   that commit and checks that it holds exactly the listed files with the listed
   SHA-256 and executable bit. Nothing downloaded runs before its check passes.
4. Builds in private staging with your own signing team, then verifies the
   finished app: identity, version, build, commit, signing team and hardened
   runtime.
5. Replaces only `OpenBots Next.app`, in place. A newer installed build is never
   replaced by an older one.

App databases, bot folders, sign-ins and credentials are not edited by the
installer.

**What is and is not checked.** The feed carries an Ed25519 signature, but the
installer does not check it: macOS's built-in Python has no Ed25519 support, and a
key fetched alongside the script would come over the same connection anyway. The
first install therefore trusts the feed as GitHub serves it over HTTPS, the same
way it trusts the launcher you piped into `sh`. Everything downloaded afterward is
held to that feed's file list. Once installed, the app checks the feed's
signature against the public key built into it before every **Update now**.

**Where the previous app goes.** The installed app is never moved: macOS and the
Dock follow a moved app and would later open the old copy. The installer copies
the previous app to

```
~/Library/Application Support/com.lorenzocolombani.openbotsnext.preview/HighChurn.noindex/SourceUpdates/Rollback/OpenBots Next.app
```

then removes the old app and copies the new one, already verified in private
staging, to the same path. If anything fails after the removal, the previous app
is copied back and checked.
Exactly one previous copy is kept, and **Update now** keeps its previous copy in
the same place, so the next installation by either route replaces it. The copy is
made only once the app has been opened at least once, because the app creates
that folder itself on first launch; before that, a temporary copy in private
staging covers a failed installation and is then deleted.

**If the build fails,** the installer prints the last lines of the build output and
the path of the full log, `~/Library/Logs/OpenBots Next/bootstrap-build.log`. Only
your account can read it, it holds at most the last 256 KB, and each run replaces
it. Problems found before the build, such as an Xcode that is too old, an
unaccepted Xcode license, no Apple Development certificate or several signing
teams, are reported directly.

**Where it installs.** One installation per Mac user. Your account must be able to
write to `/Applications` (administrator accounts can; the installer never uses
`sudo`). To install somewhere else, set `OPENBOTS_APPLICATIONS_DIR` to an existing
folder you can write to, for example `| OPENBOTS_APPLICATIONS_DIR=$HOME/Applications sh`.
The installer only replaces an app signed by your own team: a copy that another
account on this Mac installed with a different team is refused, not replaced.

If Xcode has several usable teams, select your own explicitly:

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh \
  | OPENBOTS_DEVELOPMENT_TEAM=YOURTEAMID sh
```

Replace `YOURTEAMID` with the ten-character team ID shown for your own Xcode
account. An existing signed installation must keep its current team. If that
certificate is unavailable, restore it through your own Xcode signing setup
before bootstrapping. No signing identity belonging to the maintainer is used.

An older ad-hoc installation can be bootstrapped using your own Apple Development
certificate. macOS may ask you to approve permissions or Keychain access again
because its signing identity has changed.

For Google, provide your own public client ID as shown in the
[Google setup guide](guides/google-setup.md). For an existing installation, the
embedded ID is preserved automatically. An installation built without an ID can
have one added later the same way. A different ID replaces the installed one only
when you also set `OPENBOTS_REPLACE_GOOGLE_CLIENT_ID=1`; the app then asks you to
sign in to Google again. An empty embedded ID in a newer app can use saved
app-owned configuration; the installer leaves that storage untouched.

## Build from a clean public clone

```sh
git clone https://github.com/LorenzoColombani/openbots.git
cd openbots
/usr/bin/python3 -I -B -S Scripts/bootstrap-install.py --source .
```

Only the committed Git tree is copied into private build staging. Ignored local
files and Git history are excluded. This route builds your clone as it is and does
not read the release feed. To build and verify without installing or opening,
append `--prepare-only`; the printed candidate path is retained.

## Build and test the source

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/swiftpm-public.sh test --no-parallel --scratch-path .build.noindex/gate
/bin/sh Scripts/test-install-sh.sh
/usr/bin/python3 -I -B -S -m unittest discover -s Tools/SourceUpdateTests -p 'test_*.py'
python3 Scripts/public-gate.py .
```

Run the Swift suites serially: process tests use real startup deadlines and can
miss them under parallel load. Automated tests replay protocol fixtures and do
not sign in to Claude or call live providers. Pure bootstrap tests use temporary
folders and mocks, with no real install, signing, Keychain or network operation.

After adding a Swift file, regenerate the native project with
`xcodegen generate --spec project.yml`. The SwiftPM suite and native Xcode project
have separate file inventories. Keep compatibility with Swift 6.1; passing with
a newer compiler alone does not establish that compatibility. The public content
scanner helps identify accidental private paths and secrets; it does not replace
an independent review of the exact release payload.

CI also compiles an unsigned application for compiler coverage. It is not an
installable artifact. Use the bootstrap's `--prepare-only` path for a candidate
signed and verified with your own local team.

## First run

1. Open **Settings → General & Claude Code**. In the Claude version section,
   choose **Check for a new Claude version**. When requested, use **Sign in for
   compatibility checks** to sign in through Claude Code's official flow with
   your Pro or Max account. This uses the separate `CompatibilityProfile`.
2. Return to the app, choose **Check compatibility sign-in**, then **Retry
   compatibility checks**. The first runtime becomes available only after the
   suite passes. It uses up to six short requests from your Claude plan, synthetic
   data and inert tools, including a Node fixture; install Node first.
3. Use **Sign in with Claude** for the primary chat profile, then **Check Claude**.
   This is a second official sign-in. Passing compatibility does not sign the
   primary profile in, and the app does not copy credentials between them.
4. **Create a bot** with **+ New**, or pick one from the list, and say hello.

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

- **Keep your Apple Development certificate available.** Source updates use
  your existing signing team. Replacing that identity can require new macOS and
  Keychain approvals.
- **Closing the last window quits the app.** Bots stop. An approved app installation
  can finish after normal Quit; there is no login item or persistent background service.
- **Your bots' files** live in `~/OpenBots Next Preview Content` (each bot's
  folder, shared files, projects, skills and exports). The app's own records live
  in its Application Support folder.

## Update

If you have 1.0.2 or an app without the source update channel, run the bootstrap
once. It keeps the old embedded Google public client ID in the new signed bundle.
On first launch, the app saves that ID into its own protected configuration store;
credentials remain in Keychain. An invalid ID or a failed save prevents unsafe
update admission.

After bootstrapping, choose **Update now** in the app. It verifies the signed
manifest, downloads the immutable public commit, checks all source files, and
builds with your local Xcode and signing identity. Installation waits for a normal
Quit after the app's work and draft-save checks. Keep Xcode and your certificate
available. Google configuration is preserved; you do not re-enter its public ID
for every source update.

The initial bootstrap trusts the release feed as served over HTTPS, like the
launcher you run, and holds the downloaded source to the feed's file list.
Subsequent in-app updates additionally authenticate the feed with the bundled
production public key.

## Recover a previous bundle

If replacement fails, the installer copies the previous app back into place and
checks it. It never removes a copy that has started running. If recovery needs
your attention, it says where the previous copy is kept and the command that
copies it back.

To go back to the previous app after a successful installation, quit OpenBots
Next, move `/Applications/OpenBots Next.app` to the Trash, and copy the rollback
copy (path above, also printed by the installer) into `/Applications`. In Finder,
hold Option while dragging so the copy is made rather than moved. Keep the
rollback copy until the new app has opened successfully and your saved work is
present.

The backup contains only the previous application bundle, not a database snapshot.
Restoring it does not undo database migrations or later work. Do not remove app
data to recover a failed application installation.

## Remove completely

1. If you connected Google, use **Disconnect Google account** in Settings while the
   app is still installed, or remove the app at
   <https://myaccount.google.com/permissions>.
2. Quit OpenBots Next and delete `/Applications/OpenBots Next.app`.
3. Delete its data. **Copy out anything you want to keep first**, especially your
   bots' files:
   - `~/OpenBots Next Preview Content`
   - `~/Library/Application Support/com.lorenzocolombani.openbotsnext.preview`
     (this also holds the previous app kept for rollback, under
     `HighChurn.noindex/SourceUpdates/Rollback`)
   - `~/Library/Caches/com.lorenzocolombani.openbotsnext.preview.noindex`
   - `~/Library/Logs/OpenBots Next` (the installer's build log)
4. If you connected Google, in Keychain Access, delete the items whose name starts
   with `com.lorenzocolombani.openbotsnext.preview`.
5. Remove the permissions you gave it under System Settings → Privacy & Security.

