# Install OpenBots Next: the guide in 16 cards

Read the cards in order. Every command on a card is repeated under it as text, so you can copy it on your Mac: pictures cannot be copied.

Without Google, skip cards 5, 8 and 14.

Prepared by an AI (Claude) from the OpenBots v1 docs (commit 968e6ce). The docs are the full reference: [README](https://github.com/LorenzoColombani/openbots/blob/main/README.md), [docs/INSTALL.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/INSTALL.md), [docs/CONNECTORS.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/CONNECTORS.md), [docs/guides/google-setup.md](https://github.com/LorenzoColombani/openbots/blob/main/docs/guides/google-setup.md), [PRIVACY.md](https://github.com/LorenzoColombani/openbots/blob/main/PRIVACY.md). The same cards as one scrolling page, with Copy buttons: [../install-guide.html](../install-guide.html) (download it and open it in your browser).

## 1 of 16 · Install OpenBots Next on your Mac

![Card 1: There is no app to download. One line builds OpenBots Next on your own Mac. Every step that sends, changes or clicks waits on a card you approve. Read each card before you approve it.](01-cover.png)

## 2 of 16 · Your Mac and Xcode

![Card 2: You need an Apple Silicon Mac with macOS 14 or later (Control this Mac needs macOS 15 or later), and full Xcode 16.3 or later from the App Store, at /Applications/Xcode.app. Open Xcode once, so it finishes its own setup.](02-your-mac-and-xcode.png)

## 3 of 16 · Claude Code

![Card 3: Install Claude Code with Anthropic's own installer, check that it is there, and have a Claude Pro or Max plan. Node.js is only for connectors.](03-claude-code.png)

Installs Claude Code, paste in Terminal:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

Checks that it is there:

```sh
ls -l ~/.local/bin/claude
```

## 4 of 16 · Gmail, Google Calendar or Google Drive?

![Card 4: Your Google Client ID goes into the app when it is built, so decide before you install. Yes: about fifteen minutes more, once, card 5 first. No: go to card 6.](04-google-or-not.png)

## 5 of 16 · Your own Google sign-in (only if you want Google)

![Card 5: Use a separate Google account. In your browser: a Google Cloud project, three APIs, a consent screen in Testing with you as test user, a Desktop client, its ID into the install line, the JSON file into the app. Keep the JSON file private. Google warns the app is unverified: it is your own app, so continue.](05-google-sign-in.png)

## 6 of 16 · The one line

![Card 6: The one line, pasted in Terminal. A few minutes later, the app opens. With Google, a longer line that carries your Client ID. It asks nothing, and a build made on your own Mac gets no Gatekeeper warning.](06-the-one-line.png)

The one line, paste in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh | sh
```

With Google, instead of the one line. Replace `1234-abcd.apps.googleusercontent.com` with your own Client ID, all of it, before you run it:

```sh
curl -fsSL https://raw.githubusercontent.com/LorenzoColombani/openbots/main/install.sh \
  | OPENBOTS_GOOGLE_OAUTH_CLIENT_ID=1234-abcd.apps.googleusercontent.com sh
```

## 7 of 16 · Check, sign in, say hello

![Card 7: In OpenBots Next, Settings, General and Claude Code, Check Claude. The app opens Claude Code in Terminal: sign in with your Pro or Max account, then check again. Press + New and say hello. Everything beyond chat is off until you turn it on for that bot.](07-first-run.png)

## 8 of 16 · Connect Google in the app (only if you want Google)

![Card 8: In Settings, Connectors and Skills, choose the Google sign-in file, then sign in to Google within five minutes and turn Google on per bot. Sign in again every seven days. Pass your Client ID again at every update.](08-google-in-the-app.png)

## 9 of 16 · Approval cards

![Card 9: The switch lets a bot read; the card asks before it acts. Control Chrome cards everything. A card shows exactly what will be sent, run or clicked. Nothing guarantees a bot is not fooled. Read each card before you approve it.](09-approval-cards.png)

## 10 of 16 · Control this Mac

![Card 10: Control this Mac is a trial. Allow for this turn lets the rest of a reply go on without asking. While any card is open, no screen action runs, so a bot cannot press Approve for you.](10-control-this-mac.png)

## 11 of 16 · macOS will ask

![Card 11: macOS asks for each permission when a feature first needs it. Full Disk Access is never asked: add OpenBots Next yourself, then quit and reopen it. You can refuse or withdraw any of them.](11-macos-will-ask.png)

## 12 of 16 · If something goes wrong: in Terminal

![Card 12: The installer's messages and what to do: an Apple Silicon Mac is needed, Xcode 16.3 or later opened once, run the line again after a failed build, and put in the Client ID, not the secret.](12-in-terminal.png)

## 13 of 16 · If something goes wrong: in the app

![Card 13: The app's messages and what to do: a Pro or Max login, Anthropic's own Claude Code, a build without a Client ID, a connector that is missing something, replies failing after a Claude Code update.](13-in-the-app.png)

## 14 of 16 · If something goes wrong: at Google (only if you use Google)

![Card 14: Google's messages and what to do: a Desktop app client, the right file, five minutes to sign in, an API switched off, the account as a test user, and a new sign-in after a week.](14-at-google.png)

## 15 of 16 · What stays on your Mac

![Card 15: Your bots' files and the app's records are folders on your Mac; Google keys are in your Keychain, not iCloud. What leaves your Mac is what you switch on. No telemetry, and nothing runs in the background.](15-what-stays-on-your-mac.png)

## 16 of 16 · Updating

![Card 16: Run the same line again to update; your data is kept. With Google, pass your Client ID at every update and sign in every seven days. To remove it, follow docs/INSTALL.md and copy out your bots' files first.](16-updating.png)
