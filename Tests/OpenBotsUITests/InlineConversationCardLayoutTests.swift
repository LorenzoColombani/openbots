import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

@MainActor
final class InlineConversationCardLayoutTests: XCTestCase {
    func testCardSourceUsesOneFixedControlTree() throws {
        // SwiftUI's virtual accessibility alternatives are not exposed by a
        // windowless NSHostingView. Keep this deliberately narrow source
        // contract beside the rendered regression so the duplicate-control
        // pattern cannot silently return without a packaged review.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/InlineConversationCards.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("ViewThatFits"))
        XCTAssertFalse(source.contains("GroupBox"))
        XCTAssertEqual(source.occurrences(of: "Button(\"Reopen Authentication…\")"), 1)
        XCTAssertEqual(source.occurrences(of: "SecureField(\"Enter secret\""), 1)
        XCTAssertEqual(source.occurrences(of: "\"Write another answer\",\n            text:"), 1)
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Written answer\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Secret value\")"))
        XCTAssertTrue(source.contains(".accessibilityValue(\"Hidden\")"))
    }

    func testRenderedCardInputsStayUniqueAndStableAcrossResize() throws {
        let fixture = InlineCardRenderFixture()
        let host = NSHostingView(rootView: InlineCardRenderSurface(fixture: fixture))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1_400)
        settle(host)

        let wideQuestion = try XCTUnwrap(host.uniqueQuestionField())
        let wideSecret = try XCTUnwrap(host.uniqueSecretField())
        XCTAssertEqual(host.questionFields.count, 1)
        XCTAssertEqual(host.secretFields.count, 1)

        fixture.question.freeText = "Draft survives resize"
        fixture.secret.transientInput = "test-only-secret"
        let questionIdentity = ObjectIdentifier(wideQuestion)
        let secretIdentity = ObjectIdentifier(wideSecret)

        host.frame.size.width = 360
        settle(host)

        let narrowQuestion = try XCTUnwrap(host.uniqueQuestionField())
        let narrowSecret = try XCTUnwrap(host.uniqueSecretField())
        XCTAssertEqual(host.questionFields.count, 1)
        XCTAssertEqual(host.secretFields.count, 1)
        XCTAssertEqual(ObjectIdentifier(narrowQuestion), questionIdentity)
        XCTAssertEqual(ObjectIdentifier(narrowSecret), secretIdentity)
        XCTAssertEqual(fixture.question.freeText, "Draft survives resize")
        XCTAssertEqual(fixture.secret.transientInput, "test-only-secret")
        XCTAssertTrue(host.bounds.contains(narrowQuestion.frameIn(host)))
        XCTAssertTrue(host.bounds.contains(narrowSecret.frameIn(host)))
        XCTAssertTrue(host.privateSelectionArtifacts.isEmpty)

        host.frame.size.width = 900
        settle(host)

        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(host.uniqueQuestionField())), questionIdentity)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(host.uniqueSecretField())), secretIdentity)
        XCTAssertEqual(host.questionFields.count, 1)
        XCTAssertEqual(host.secretFields.count, 1)
    }
}

@MainActor
private final class InlineCardRenderFixture: ObservableObject {
    let questionSnapshot: ChatQuestionCardSnapshot
    let connectorSnapshot: ChatConnectorSetupCardSnapshot
    let secretSnapshot: ChatSecretCardSnapshot
    let question: QuestionCardInteractionModel
    let connector: ConnectorSetupCardInteractionModel
    let secret: SecretCardInteractionModel

    init() {
        questionSnapshot = ChatQuestionCardSnapshot(
            id: cardLayoutUUID(10),
            prompt: "Which outcome should I prioritize?",
            choices: [
                ChatQuestionChoiceSnapshot(id: cardLayoutUUID(11), title: "Prototype"),
                ChatQuestionChoiceSnapshot(id: cardLayoutUUID(12), title: "Research"),
                ChatQuestionChoiceSnapshot(id: cardLayoutUUID(13), title: "Deliverable")
            ],
            allowsFreeText: true
        )
        connectorSnapshot = ChatConnectorSetupCardSnapshot(
            id: cardLayoutUUID(20),
            connectorName: "GitHub",
            installation: .installed,
            authentication: .notAuthenticated,
            botGrant: .notGranted,
            actionApproval: .notRequested
        )
        secretSnapshot = ChatSecretCardSnapshot(
            id: cardLayoutUUID(30),
            label: "Preview connector token",
            purpose: "Test-only injected boundary",
            presence: .absent
        )

        question = QuestionCardInteractionModel(
            route: cardLayoutRoute(card: questionSnapshot.id, suffix: 10),
            snapshot: questionSnapshot,
            submit: { route, attemptID, _ in
                ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: nil)
                )
            }
        )
        connector = ConnectorSetupCardInteractionModel(
            route: cardLayoutRoute(card: connectorSnapshot.id, suffix: 20),
            snapshot: connectorSnapshot,
            reopenAuthentication: { route, attemptID in
                ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: nil)
                )
            }
        )
        secret = SecretCardInteractionModel(
            route: cardLayoutRoute(card: secretSnapshot.id, suffix: 30),
            snapshot: secretSnapshot,
            submit: { route, attemptID, _ in
                ConversationCardActionResult(
                    route: route,
                    attemptID: attemptID,
                    outcome: .succeeded(receiptID: cardLayoutUUID(31))
                )
            }
        )
    }
}

private struct InlineCardRenderSurface: View {
    @ObservedObject var fixture: InlineCardRenderFixture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InlineQuestionCardView(
                    snapshot: fixture.questionSnapshot,
                    interaction: fixture.question
                )
                InlineConnectorSetupCardView(
                    snapshot: fixture.connectorSnapshot,
                    interaction: fixture.connector
                )
                InlineSecretCardView(
                    snapshot: fixture.secretSnapshot,
                    interaction: fixture.secret
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }

    var questionFields: [NSTextField] {
        allDescendants.compactMap { view in
            guard let field = view as? NSTextField,
                  !(field is NSSecureTextField),
                  field.isEditable else {
                return nil
            }
            return field
        }
    }

    var secretFields: [NSSecureTextField] {
        allDescendants.compactMap { view in
            guard let field = view as? NSSecureTextField,
                  field.isEditable else {
                return nil
            }
            return field
        }
    }

    var privateSelectionArtifacts: [String] {
        allDescendants.map { String(describing: type(of: $0)) }.filter {
            $0.contains("SelectionOverlay")
        }
    }

    func uniqueQuestionField() -> NSTextField? {
        questionFields.count == 1 ? questionFields[0] : nil
    }

    func uniqueSecretField() -> NSSecureTextField? {
        secretFields.count == 1 ? secretFields[0] : nil
    }

    func frameIn(_ ancestor: NSView) -> NSRect {
        convert(bounds, to: ancestor)
    }
}

@MainActor
private func settle(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    for _ in 0..<4 {
        _ = RunLoop.main.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.002)
        )
        host.layoutSubtreeIfNeeded()
    }
}

private func cardLayoutRoute(card: UUID, suffix: UInt64) -> ConversationCardInteractionRoute {
    ConversationCardInteractionRoute(
        conversationID: cardLayoutUUID(100),
        messageID: cardLayoutUUID(101),
        messagePartID: cardLayoutUUID(200 + suffix),
        cardID: card,
        actionRouteID: cardLayoutUUID(300 + suffix)
    )
}

private func cardLayoutUUID(_ suffix: UInt64) -> UUID {
    let value = String(format: "%012llx", suffix)
    return UUID(uuidString: "8C000000-0000-0000-0000-\(value)")!
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
