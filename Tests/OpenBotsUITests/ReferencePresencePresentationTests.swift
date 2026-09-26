import Foundation
import Testing
@testable import OpenBotsUI

@Test("Empty streaming chrome never exposes a Receiving-response transport caption")
func emptyStreamingChromeOmitsTransportCaption() {
    #expect(TranscriptEmptyStreamChrome.transportCaption == nil)
    #expect(TranscriptEmptyStreamChrome.accessibilityLabel == "Working")
    #expect(TranscriptEmptyStreamChrome.accessibilityLabel.localizedCaseInsensitiveContains("Receiving") == false)
    #expect(TranscriptEmptyStreamChrome.accessibilityLabel.localizedCaseInsensitiveContains("Preparing") == false)
    #expect(TranscriptEmptyStreamChrome.accessibilityLabel.localizedCaseInsensitiveContains("Saving") == false)
}

@Test("Empty streaming chrome source paint path drops Receiving response Label")
func emptyStreamingChromeSourceDropsReceivingResponseLabel() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OpenBotsUI/TranscriptMessagePartsView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("TranscriptEmptyStreamChrome.accessibilityLabel"))
    #expect(source.contains("Receiving response") == false)
    #expect(source.contains("systemImage: \"waveform\"") == false)
}

@Test("Details creature follows live activity when a row activity is provided")
func detailsCreatureFollowsLiveActivity() {
    #expect(BotDetailsCreatureActivity.resolve(nil) == .idle)
    #expect(BotDetailsCreatureActivity.resolve(.idle) == .idle)
    #expect(BotDetailsCreatureActivity.resolve(.thinkingOrWorking) == .thinkingOrWorking)
    #expect(BotDetailsCreatureActivity.resolve(.speaking) == .speaking)
    #expect(BotDetailsCreatureActivity.resolve(.waitingForUser) == .waitingForUser)
    #expect(BotDetailsCreatureActivity.resolve(.errorOrAttention) == .errorOrAttention)
}

@Test("Details creature source no longer hard-codes idle when a row exists")
func detailsCreatureSourceUsesResolver() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OpenBotsUI/BotDetailsView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("BotDetailsCreatureActivity.resolve(activityRow?.snapshot.activity)"))
    #expect(source.contains("activity: .idle, size: 44") == false)
}

@Test("NormalBusyFeedbackPolicy still hides Preparing/Receiving/Saving status placeholders")
func normalBusyFeedbackPolicyStillHidesTransportPlaceholders() {
    let hidden = ["Waiting for Claude's reply.", "Preparing reply…", "Receiving response…", "Saving reply…"]
    for text in hidden {
        let message = ChatMessageSnapshot(
            id: UUID(),
            author: .system(label: "OpenBots"),
            parts: [ChatMessagePartSnapshot(id: UUID(), ordinal: 0, content: .status(text))],
            delivery: .pending,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        #expect(NormalBusyFeedbackPolicy.hidesPlaceholder(message), "Expected hide for \(text)")
    }
}
