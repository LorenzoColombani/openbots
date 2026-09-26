import Foundation

/// One place for what the app tells the user a web grant covers.
///
/// The sentence lived twice, in the bot Details caption and in Settings, and
/// both said a web tool "works only inside a job". That stopped being true
/// when a granted bot became able to search and fetch inside
/// an ordinary chat or team turn; the change landed in the runtime and the
/// services while the sentence sat in the UI, so nobody owned it and the
/// running app showed the false version. Both captions now come from here.
///
/// What stays true: a capability needs the app-wide switch **and** that bot's
/// own grant, and neither turns on the other. The settings caption also
/// carries what turning one off does, because that is where the switches are,
/// and says how long a switch lasts. The web switches were once
/// session-local, and every reinstall turned them off; they now survive a
/// relaunch. The per-bot sentences moved to `BotAccessCopy` with the Access sheet,
/// and the retired runner's own switch and its sentences are gone, so only Settings reads from here.
enum AgenticWebCopy {
    /// Settings → Permissions & Bot Access, under the app-wide web switches.
    static let settingsCaption =
        "Web search lets a bot look things up; Web fetch lets it read one web page it names. "
        + "Each works in that bot's conversations, and only for bots "
        + "whose own Access sheet also has it on (Access… in Details or on the bot's row in the sidebar); "
        + "neither turns on the other. "
        + "Turning one off stops a reply that was using it. "
        + "These switches stay as you left them the next time OpenBots starts."

    /// The own-folder rule, one sentence, shared by every caption that states
    /// it: the Access sheet's work row and the Settings work master (the old
    /// Details switch left with the retired runner's controls). An edit inside the bot's own folder
    /// goes through with no card. The policy
    /// (`ClaudeTextWorkApprovalPolicy.isInsideOwnFolder`) keeps two in-folder
    /// cases that still ask, and the sentence names both: a target under the
    /// deny list (passwords, browser data, this app's own files) and a link
    /// that leads out of the folder (a symlink, or a file the disk knows under
    /// a second name). An added folder, anywhere outside and every command
    /// with effects still ask.
    static let ownFolderRule =
        "Edits inside its own folder go through on their own, except protected files and links that "
        + "lead outside it; a card asks before anything else that changes files or has effects."

    /// Settings → Permissions & Bot Access, under the app-wide work switch.
    /// The bot's own switch lives on its Access sheet, not in Details.
    static let settingsWorkCaption =
        "Work on this Mac lets a bot use Claude Code's own file and shell tools in its own folder and in the "
        + "folders you add to it, as you. " + ownFolderRule + " Passwords, browser data and this app's own "
        + "files stay off limits. Also turn it on in the bot's Access sheet. Turning it off stops a reply "
        + "that was using it; the switch stays as you left it the next time OpenBots starts."

    /// Settings → Permissions & Bot Access, under the app-wide hire switch.
    /// The bot's own switch lives on its Access sheet.
    static let settingsHireCaption =
        "Hiring lets a bot ask OpenBots for a new bot from its own replies, at most three a reply. OpenBots "
        + "makes each one with every switch off and no connectors; like every bot, it reads the team's shared "
        + "folder and the skills you give it. OpenBots notes each hire in the conversation it came from. "
        + "Also turn it on in the bot's Access sheet. Turned off while a bot is answering, it takes effect when "
        + "that reply ends. The switch stays as you left it the next time OpenBots starts."

    /// Settings → Permissions & Bot Access, under the app-wide background-workers switch.
    /// The bot's own switch lives on its Access sheet.
    static let settingsWorkersCaption =
        "Background workers let a bot start a one-time worker for a chore no other bot owns, like summarising "
        + "some files. A worker has no chat, no memory and no place in the sidebar; it ends after one reply, and "
        + "the bot answers you with what it found. Also turn it on in the bot's Access sheet. Turned off while a "
        + "bot is answering, it takes effect when that reply ends. The switch stays as you left it the next time "
        + "OpenBots starts."

    /// Settings → Permissions & Bot Access, under the app-wide fetcher-workers switch.
    static let settingsFetchersCaption =
        "Fetcher workers let a bot's background workers use that bot's own web search and fetch. Pages they "
        + "read are data, never instructions. Also turn it on in the bot's Access sheet. Turned off while a bot "
        + "is answering, it takes effect when that reply ends. The switch stays as you left it the next time "
        + "OpenBots starts."
}
