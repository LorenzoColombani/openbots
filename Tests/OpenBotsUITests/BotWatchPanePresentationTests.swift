import XCTest
@testable import OpenBotsUI

final class BotWatchPanePresentationTests: XCTestCase {
    func testEmptyActivityMessageMatchesWorkingWaitingAndIdle() {
        XCTAssertEqual(
            BotWatchPanePresentation.emptyActivityMessage(activity: .thinkingOrWorking),
            "Working — live lines will show here as tools run."
        )
        XCTAssertEqual(
            BotWatchPanePresentation.emptyActivityMessage(activity: .waitingForUser),
            "Waiting for you — nothing new on this Mac yet."
        )
        XCTAssertEqual(
            BotWatchPanePresentation.emptyActivityMessage(activity: .idle),
            "Nothing running on this Mac right now."
        )
    }

    /// A member's pane shows the open team chat's turn, and
    /// nothing says which member drove the Mac, so the words never name this bot.
    func testTeamChatActivityNeverClaimsThisBotSawThePicture() {
        XCTAssertEqual(BotWatchPanePresentation.screenPreviewLabel(botName: "Ada"),
                       "What Ada last saw on this Mac. Opens full size.")
        XCTAssertEqual(BotWatchPanePresentation.screenPreviewNote(),
                       "What it last saw on this Mac, kept only until this reply ends.")
        let label = BotWatchPanePresentation.screenPreviewLabel(botName: "Ada", inTeamChat: true)
        XCTAssertFalse(label.contains("Ada"), label)
        XCTAssertEqual(label, "What a bot in this team chat last saw on this Mac. Opens full size.")
        XCTAssertEqual(BotWatchPanePresentation.screenPreviewNote(inTeamChat: true),
                       "What a bot in this team chat last saw on this Mac, kept only until this reply ends.")
        XCTAssertEqual(BotWatchPanePresentation.teamChatNote,
                       "From the open team chat: this is the whole team's reply, not only this bot's part.")
    }

    func testScreenPreviewCaptionNamesMissingPermissionsWithoutFakingReadyPreview() {
        XCTAssertEqual(
            BotWatchPanePresentation.screenPreviewCaption(
                accessibilityTrusted: false,
                screenRecordingAllowed: false
            ),
            "Screen preview needs OpenBots Next turned on for Accessibility and Screen Recording in System Settings → Privacy & Security."
        )
        XCTAssertEqual(
            BotWatchPanePresentation.screenPreviewCaption(
                accessibilityTrusted: true,
                screenRecordingAllowed: false
            ),
            "Screen preview needs OpenBots Next turned on for Screen Recording in System Settings → Privacy & Security."
        )
        XCTAssertEqual(
            BotWatchPanePresentation.screenPreviewCaption(
                accessibilityTrusted: true,
                screenRecordingAllowed: true
            ),
            "Screen preview appears here when Control this Mac is in use."
        )
    }
}
