# Install OpenBots Next: the guide in 18 cards

Read the cards in order. Every command on a card is repeated under it as text, so you can copy it on your Mac: pictures cannot be copied.

Without Google, skip cards 6, 8, 10 and 16.

Prepared by an AI (Claude) from the OpenBots v1.1 docs. The docs are the full reference: [README](https://github.com/LorenzoColombani/openbots/blob/main/README.md), [docs/INSTALL.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/INSTALL.md), [docs/UPDATES.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/UPDATES.md), [docs/CONNECTORS.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/CONNECTORS.md), [docs/guides/google-setup.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/guides/google-setup.md), [PRIVACY.md](https://github.com/LorenzoColombani/openbots/blob/main/PRIVACY.md). The same cards as one scrolling page, with Copy buttons: [the install guide](https://lorenzocolombani.github.io/openbots/guides/install-guide.html).

## 1 of 18 · Install OpenBots Next on your Mac

![Card 1: There is no app to download. One line builds OpenBots Next on your own Mac. Every step that sends, changes or clicks waits on a card you approve. Read each card before you approve it.](01-cover.png)

## 2 of 18 · Your Mac and Xcode

![Card 2: You need an Apple Silicon Mac that can run your Xcode (Xcode 16.3 needs macOS 15.2 or later), and full Xcode 16.3 or later at /Applications/Xcode.app. Command Line Tools alone cannot build it. Open Xcode once, so it finishes its own setup.](02-your-mac-and-xcode.png)

## 3 of 18 · Your own certificate

![Card 3: The app is built and signed with your own Apple Development certificate. It is free: a Personal Team is enough. In Xcode, Settings, Accounts: add your Apple account and select your team; Manage Certificates, Apple Development makes the certificate. Keep it: updates use the same one.](03-your-certificate.png)

## 4 of 18 · Claude Code

![Card 4: Install Claude Code with Anthropic's own installer, check that it is there, and have a Claude Pro or Max plan. You also need Node.js, from Homebrew or nodejs.org.](04-claude-code.png)

Installs Claude Code, paste in Terminal:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

Checks that it is there:

```sh
ls -l ~/.local/bin/claude
```

## 5 of 18 · Gmail, Google Calendar or Google Drive?

![Card 5: Your Google Client ID goes into the app when it is built. Yes: about fifteen minutes more, once, card 6 first. No: go to card 7. You can add it later: quit the app and run the Google line from card 8.](05-google-or-not.png)

## 6 of 18 · Your own Google sign-in (only if you want Google)

![Card 6: Use a separate Google account. In your browser: a Google Cloud project, three APIs, a consent screen in Testing with you as test user, a Desktop client, its ID into the install line, the JSON file into the app. Keep the JSON file private. Google warns the app is unverified: it is your own app, so continue.](06-google-sign-in.png)

## 7 of 18 · The one line

![Card 7: The one line, pasted in Terminal. It is one command over several lines: copy all of it. When it is built, the app opens. It builds only the published release and checks every file; if none is out yet, it stops with "No published release yet."](07-the-one-line.png)

The one line, paste in Terminal (both lines together):

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
```

## 8 of 18 · With Google (only if you want Google)

![Card 8: With Google, a longer line that carries your Client ID, instead of the one line. Installed without an ID? Quit the app and run this line. Updates keep the ID. Switching to another Google client also needs OPENBOTS_REPLACE_GOOGLE_CLIENT_ID=1, as docs/guides/google-setup.md shows.](08-with-google.png)

With Google, instead of the one line. Replace `1234-abcd.apps.googleusercontent.com` with your own Client ID, all of it, before you run it:

```sh
env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/curl -q -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh \
  | OPENBOTS_GOOGLE_OAUTH_CLIENT_ID=1234-abcd.apps.googleusercontent.com sh
```

## 9 of 18 · Two sign-ins, then hello

![Card 9: In OpenBots Next, Settings, General and Claude Code. One: Check for a new Claude version, then Sign in for compatibility checks, the first sign-in with your Pro or Max account. Two: Check compatibility sign-in, then Retry compatibility checks, up to six short test requests; this needs Node. Three: Sign in with Claude, then Check Claude, the second sign-in, for your bots. Four: press + New and say hello. Your own Terminal login is not touched. Everything beyond chat is off until you turn it on for that bot.](09-first-run.png)

## 10 of 18 · Connect Google in the app (only if you want Google)

![Card 10: In Settings, Connectors and Skills, choose the Google sign-in file, then sign in to Google within five minutes and turn Google on per bot. Sign in again every seven days. Updates keep your Google setup.](10-google-in-the-app.png)

## 11 of 18 · Approval cards

![Card 11: The switch lets a bot read; the card asks before it acts. Control Chrome cards everything. A card shows exactly what will be sent, run or clicked. Nothing guarantees a bot is not fooled. Read each card before you approve it.](11-approval-cards.png)

## 12 of 18 · Control this Mac

![Card 12: Control this Mac is a trial. Allow for this turn lets the rest of a reply go on without asking. While any card is open, no screen action runs, so a bot cannot press Approve for you.](12-control-this-mac.png)

## 13 of 18 · macOS will ask

![Card 13: macOS asks for each permission when a feature first needs it. Full Disk Access is never asked: add OpenBots Next yourself, then quit and reopen it. You can refuse or withdraw any of them.](13-macos-will-ask.png)

## 14 of 18 · If something goes wrong: in Terminal

![Card 14: The installer's messages and what to do: get Xcode 16.3 or later and open it once, make your Apple Development certificate, quit the app before installing, read the build log in ~/Library/Logs/OpenBots Next when the build fails, and put in the Client ID, not the secret.](14-in-terminal.png)

The full build log is `~/Library/Logs/OpenBots Next/bootstrap-build.log`.

## 15 of 18 · If something goes wrong: in the app

![Card 15: The app's messages and what to do: a Pro or Max login, Anthropic's own Claude Code, a build without a Client ID, a connector that is missing something, and the Claude Code status in Settings.](15-in-the-app.png)

## 16 of 18 · If something goes wrong: at Google (only if you use Google)

![Card 16: Google's messages and what to do: a Desktop app client, the right file, five minutes to sign in, an API switched off, the account as a test user, and a new sign-in after a week.](16-at-google.png)

## 17 of 18 · What stays on your Mac

![Card 17: Your bots' files and the app's records are folders on your Mac; Google keys are in your Keychain, not iCloud. What leaves your Mac is what you switch on. Update checks go to GitHub; nothing goes to the developer.](17-what-stays-on-your-mac.png)

## 18 of 18 · Updating

![Card 18: Press Update now in the app; your data is kept. It checks the signed release, builds it on your Mac and installs when you quit, keeping one previous copy. On 1.0.2 or older, run the one line once. To remove it, follow Remove completely in docs/INSTALL.md and copy out your bots' files first.](18-updating.png)
