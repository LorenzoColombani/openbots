import OpenBotsServices
import Testing
@testable import OpenBotsUI

/// The sentence that tells the user where a web grant applies. It lived twice,
/// in the bot Details caption and in Settings, and both once still said "only
/// inside a job" after a granted bot could search inside an ordinary
/// conversation. One source now, and these are its exact words: a caption that drifts fails
/// here rather than being re-described by a substring it happens to keep. The
/// per-bot sentences live in `BotAccessCopy` since the Access sheet; the
/// retired runner's jobs switch and its sentences are gone.
@Suite("What the app says a web grant covers")
struct AgenticWebCopyTests {
    /// The per-bot switches live on the bot's Access sheet, not in Details
    /// (opened with Access… from Details or from the bot's row in the
    /// sidebar), so a caption that sends the user to Details sends them to a
    /// pane that no longer holds them. The retired runner's jobs switch left
    /// Settings too, so no caption may name a job.
    @Test("The settings caption names the surface, the two-switch rule, where the bot's switch lives, the stop, that the web switches survive a relaunch, and no retired job")
    func settingsCaptionIsExact() {
        #expect(AgenticWebCopy.settingsCaption ==
            "Web search lets a bot look things up; Web fetch lets it read one web page it names. "
            + "Each works in that bot's conversations, and only for bots "
            + "whose own Access sheet also has it on (Access… in Details or on the bot's row in the sidebar); "
            + "neither turns on the other. "
            + "Turning one off stops a reply that was using it. "
            + "These switches stay as you left them the next time OpenBots starts.")
        #expect(!AgenticWebCopy.settingsCaption.contains("job"))
    }

    /// An edit inside the bot's own folder goes through with no card; an
    /// added folder, anywhere outside and every command still ask. The work
    /// captions once said a card asks before anything that changes files, and
    /// then each caption stated the rule in its own words, and none named the
    /// two in-folder cases the policy still asks about (a protected file, a
    /// link that leads out of the folder). One rule, one sentence, in both:
    /// the sheet's work row and this caption.
    @Test("The work caption in Settings tells the truth about the card, points at the bot's Access sheet, and names no retired job")
    func settingsWorkCaptionIsExact() {
        #expect(AgenticWebCopy.settingsWorkCaption ==
            "Work on this Mac lets a bot use Claude Code's own file and shell tools in its own folder and in the "
            + "folders you add to it, as you. Edits inside its own folder go through on their own, except protected "
            + "files and links that lead outside it; a card asks before anything else that changes files or has "
            + "effects. Passwords, browser data and this app's own files stay off limits. Also turn it on in the "
            + "bot's Access sheet. Turning it off stops a reply that was using it; the switch stays as you left it "
            + "the next time OpenBots starts.")
        #expect(!AgenticWebCopy.settingsWorkCaption.contains("job"))
    }

    @Test("A turn that ran out of tool-call rounds says so, and does not blame the connection")
    func turnCapSentenceIsHonest() {
        #expect(ClaudeTextReplyPhase.explanation(.turnLimitReached) ==
            "Claude used up its rounds of tool calls before it finished this reply. "
            + "Saved text is kept; no retry will run automatically.")
    }

    // A Control this Mac reply's rounds are on the user's Mac. The sentence claims no card: the call
    // budget of a window ends the reply the same way, with none offered.
    @Test("A Control this Mac reply that ran out of rounds says rounds on the user's Mac, never web tool calls")
    func macRoundsSentenceNamesNoWeb() {
        let sentence = ClaudeTextReplyPhase.explanation(.macControlRoundsUsedUp)
        #expect(sentence == "The bot used up its rounds on your Mac before it finished this reply. "
            + "Saved text is kept; no retry will run automatically.")
        #expect(!sentence.contains("web"))
    }
}
