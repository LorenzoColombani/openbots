import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class KeyboardFocusLayoutRegressionTests: XCTestCase {
    func testRenderedSecretCardConversationSwitchSettles() throws {
        let evidence = try exerciseRenderedTranscriptTransition()

        // Drain hosting-view updates while this test is still their owner.
        // Command-line XCTest must not create a global field editor: doing so
        // leaves an invalid autorelease for the later full-suite run loop.
        for _ in 0..<3 {
            _ = RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.002)
            )
        }

        XCTAssertLessThan(
            evidence.updateConstraintsPassCount,
            80,
            "Conversation switching repeatedly invalidated update constraints"
        )
        XCTAssertLessThan(
            evidence.layoutPassCount,
            80,
            "Conversation switching repeatedly re-entered layout"
        )
        XCTAssertEqual(evidence.selectedTeammateID, evidence.expectedTeammateID)
        XCTAssertEqual(evidence.conversationID, evidence.expectedConversationID)
    }
}

private enum RenderedFocusTransitionError: Error {
    case preconditionFailed(String)
    case timedOut(String)
}

private struct RenderedTranscriptTransitionEvidence {
    let updateConstraintsPassCount: Int
    let layoutPassCount: Int
    let selectedTeammateID: UUID?
    let expectedTeammateID: UUID
    let conversationID: UUID?
    let expectedConversationID: UUID
}

@MainActor
private func exerciseRenderedTranscriptTransition() throws
    -> RenderedTranscriptTransitionEvidence
{
    let fixture = FocusLayoutFixture()
    let host = LayoutCountingHostingView(
        rootView: FocusTransitionWorkspace(fixture: fixture)
    )
    host.frame = NSRect(x: 0, y: 0, width: 1_280, height: 760)
    host.layoutSubtreeIfNeeded()

    try waitUntil("the rendered secret field appears") {
        host.descendant(ofType: NSSecureTextField.self) != nil
    }
    XCTAssertTrue(
        host.containsSelectableText(FocusLayoutFixture.firstTranscriptText),
        "The transcript must remain natively selectable"
    )
    try assertNoPrivateSelectionArtifacts(in: host, phase: "before conversation replacement")
    let firstSelectableField = try XCTUnwrap(
        host.selectableTextField(containing: FocusLayoutFixture.firstTranscriptText)
    )
    assertMultilineSelectableAccessibility(
        field: firstSelectableField,
        expectedText: FocusLayoutFixture.firstTranscriptText
    )

    // Replace the actual rendered transcript/card tree. The private
    // SelectionOverlay assertion above guards the diagnosed crash mechanism;
    // physical keyboard focus remains a packaged-app review responsibility.
    host.resetLayoutCounters()
    fixture.selectSecondConversation()

    var mainTurnCompleted = false
    DispatchQueue.main.async {
        mainTurnCompleted = true
    }
    try waitUntil("the post-selection main turn remains responsive") {
        mainTurnCompleted
    }
    // A standalone offscreen hosting view remains marked for its next window
    // pass by design. Force that pass explicitly instead of waiting for a
    // window-owned dirty bit to clear.
    host.layoutSubtreeIfNeeded()
    try waitUntil("the replacement transcript text appears") {
        host.containsSelectableText(FocusLayoutFixture.secondTranscriptText)
    }
    try assertNoPrivateSelectionArtifacts(in: host, phase: "after conversation replacement")
    let secondSelectableField = try XCTUnwrap(
        host.selectableTextField(containing: FocusLayoutFixture.secondTranscriptText)
    )
    XCTAssertTrue(secondSelectableField.isSelectable)
    XCTAssertEqual(
        secondSelectableField.accessibilityValue(),
        FocusLayoutFixture.secondTranscriptText
    )

    return RenderedTranscriptTransitionEvidence(
        updateConstraintsPassCount: host.updateConstraintsPassCount,
        layoutPassCount: host.layoutPassCount,
        selectedTeammateID: fixture.sidebar.selection,
        expectedTeammateID: fixture.secondTeammateID,
        conversationID: fixture.conversation.conversationID,
        expectedConversationID: fixture.secondConversationID
    )
}

@MainActor
private final class FocusLayoutFixture: ObservableObject {
    static let firstTranscriptText =
        "Selectable first-conversation evidence wraps across the bounded chat column while "
        + "the secret card is visible.\nThe second line remains selectable and accessible."
    static let secondTranscriptText =
        "Selectable second-conversation evidence remains available after the complete chat "
        + "transcript and card tree is replaced."

    let firstTeammateID = UUID(uuidString: "8A000000-0000-0000-0000-000000000001")!
    let secondTeammateID = UUID(uuidString: "8A000000-0000-0000-0000-000000000002")!
    let firstConversationID = UUID(uuidString: "8A000000-0000-0000-0000-000000000011")!
    let secondConversationID = UUID(uuidString: "8A000000-0000-0000-0000-000000000012")!

    let sidebar: SidebarModel
    let conversation: ConversationModel
    @Published private(set) var cardInteractions: ConversationCardInteractionModel?

    init() {
        let first = TeammateRowSnapshot(
            id: firstTeammateID,
            name: "Ada",
            role: "Researcher",
            activity: .waitingForUser,
            identitySeed: 41
        )
        let second = TeammateRowSnapshot(
            id: secondTeammateID,
            name: "Mira",
            role: "Builder",
            activity: .idle,
            identitySeed: 42
        )
        sidebar = SidebarModel(rows: [first, second], selection: firstTeammateID)

        let card = Self.makeSecretCard(conversationID: firstConversationID)
        cardInteractions = card.interactions
        conversation = ConversationModel(
            conversationID: firstConversationID,
            title: "Ada",
            messages: [card.message],
            inputAvailability: .ready,
            submit: { _, _, _ in }
        )
    }

    func selectSecondConversation() {
        sidebar.selection = secondTeammateID
        conversation.show(
            conversationID: secondConversationID,
            title: "Mira",
            messages: [
                ChatMessageSnapshot(
                    id: UUID(uuidString: "8A000000-0000-0000-0000-000000000021")!,
                    author: .system(label: "OpenBots Preview"),
                    body: Self.secondTranscriptText,
                    delivery: .sent,
                    timestamp: Date(timeIntervalSince1970: 2)
                )
            ]
        )
        cardInteractions = nil
    }

    private static func makeSecretCard(
        conversationID: UUID
    ) -> (message: ChatMessageSnapshot, interactions: ConversationCardInteractionModel) {
        let messageID = UUID(uuidString: "8A000000-0000-0000-0000-000000000031")!
        let textPartID = UUID(uuidString: "8A000000-0000-0000-0000-000000000035")!
        let partID = UUID(uuidString: "8A000000-0000-0000-0000-000000000032")!
        let cardID = UUID(uuidString: "8A000000-0000-0000-0000-000000000033")!
        let route = ConversationCardInteractionRoute(
            conversationID: conversationID,
            messageID: messageID,
            messagePartID: partID,
            cardID: cardID,
            actionRouteID: UUID(uuidString: "8A000000-0000-0000-0000-000000000034")!
        )
        let snapshot = ChatSecretCardSnapshot(
            id: cardID,
            label: "Preview connector token",
            purpose: "Process-local fixture only",
            presence: .absent
        )
        let interaction = SecretCardInteractionModel(
            route: route,
            snapshot: snapshot,
            submit: { route, attemptID, _ in
                ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: UUID())
                )
            }
        )
        let interactions = ConversationCardInteractionModel(
            conversationID: conversationID
        )
        precondition(interactions.register(interaction))

        let message = ChatMessageSnapshot(
            id: messageID,
            author: .system(label: "OpenBots Preview"),
            parts: [
                ChatMessagePartSnapshot(
                    id: textPartID,
                    ordinal: 0,
                    content: .text(firstTranscriptText)
                ),
                ChatMessagePartSnapshot(
                    id: partID,
                    ordinal: 1,
                    content: .secret(snapshot)
                )
            ],
            delivery: .sent,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        return (message, interactions)
    }
}

private struct FocusTransitionWorkspace: View {
    @ObservedObject var fixture: FocusLayoutFixture

    var body: some View {
        OpenBotsRootView(
            sidebar: fixture.sidebar,
            conversation: fixture.conversation,
            cardInteractions: fixture.cardInteractions,
            createTeammate: {},
            openSettings: {}
        )
    }
}

@MainActor
private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var updateConstraintsPassCount = 0
    private(set) var layoutPassCount = 0

    override func updateConstraints() {
        updateConstraintsPassCount += 1
        super.updateConstraints()
    }

    override func layout() {
        layoutPassCount += 1
        super.layout()
    }

    func resetLayoutCounters() {
        updateConstraintsPassCount = 0
        layoutPassCount = 0
    }
}

@MainActor
private func assertNoPrivateSelectionArtifacts(
    in host: NSView,
    phase: String
) throws {
    let artifacts = host.privateSelectionArtifacts
    guard artifacts.isEmpty else {
        let description = artifacts.joined(separator: ", ")
        XCTFail("Private SwiftUI selection artifacts found \(phase): \(description)")
        throw RenderedFocusTransitionError.preconditionFailed(description)
    }
}

@MainActor
private func assertMultilineSelectableAccessibility(
    field: NSTextField,
    expectedText: String
) {
    XCTAssertTrue(field.isSelectable)
    XCTAssertFalse(field.isEditable)
    XCTAssertFalse(field.usesSingleLineMode)
    XCTAssertEqual(field.maximumNumberOfLines, 0)
    XCTAssertEqual(field.lineBreakMode, .byWordWrapping)

    let narrowBounds = NSRect(x: 0, y: 0, width: 180, height: 10_000)
    let wideBounds = NSRect(x: 0, y: 0, width: 620, height: 10_000)
    let narrowHeight = field.cell?.cellSize(forBounds: narrowBounds).height ?? 0
    let wideHeight = field.cell?.cellSize(forBounds: wideBounds).height ?? 0
    XCTAssertGreaterThan(
        narrowHeight,
        wideHeight,
        "The selectable transcript label must grow vertically at a bounded narrow width"
    )

    // A standalone NSHostingView has no accessibility server/window context,
    // so AppKit reports AXUnknown here even for a packaged static-text view.
    // Its exposed value is stable offscreen; role/element registration remains
    // part of the physical packaged-app accessibility review.
    XCTAssertEqual(field.accessibilityValue(), expectedText)
}

private extension NSView {
    func descendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews {
            if let match = child.descendant(ofType: type) {
                return match
            }
        }
        return nil
    }

    var privateSelectionArtifacts: [String] {
        var artifacts: [String] = []
        let viewType = String(reflecting: type(of: self))
        if viewType.contains("SelectionTextField") || viewType.contains("SelectionOverlay") {
            artifacts.append(viewType)
        }
        if let control = self as? NSControl, let cell = control.cell {
            let cellType = String(reflecting: type(of: cell))
            if cellType.contains("SelectionTextField") || cellType.contains("SelectionOverlay") {
                artifacts.append(cellType)
            }
        }
        return artifacts + subviews.flatMap(\.privateSelectionArtifacts)
    }

    func containsSelectableText(_ expected: String) -> Bool {
        if let textView = self as? NSTextView,
           textView.string.contains(expected), textView.isSelectable {
            return true
        }
        if let textField = self as? NSTextField,
           textField.stringValue.contains(expected), textField.isSelectable {
            return true
        }
        return subviews.contains { $0.containsSelectableText(expected) }
    }

    func selectableTextField(containing expected: String) -> NSTextField? {
        if let textField = self as? NSTextField,
           textField.stringValue.contains(expected), textField.isSelectable {
            return textField
        }
        for child in subviews {
            if let match = child.selectableTextField(containing: expected) {
                return match
            }
        }
        return nil
    }

}

@MainActor
private func waitUntil(
    _ description: String,
    iterations: Int = 240,
    condition: @MainActor () -> Bool
) throws {
    for _ in 0..<iterations {
        if condition() { return }
        _ = RunLoop.main.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.002)
        )
    }
    throw RenderedFocusTransitionError.timedOut(description)
}
