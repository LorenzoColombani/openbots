import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsUI

@Test("A presentation appearance preserves every persisted identity field")
func completeAppearanceMapping() throws {
    let assetUUID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    let appearance = try AgentAppearance(
        mode: .photo,
        grammarVersion: 7,
        deterministicSeed: 42,
        silhouette: "photo-mask",
        paletteToken: "violet-coral",
        eyeDialect: "photo",
        nonColorIdentityCue: "hexagonal frame",
        accessibleIdentityDescription: "Portrait in a hexagonal frame",
        profileAssetID: ProfileAssetID(assetUUID),
        revision: 9
    )

    let snapshot = CharacterAppearanceSnapshot(appearance)

    #expect(snapshot.mode == .photo)
    #expect(snapshot.grammarVersion == 7)
    #expect(snapshot.deterministicSeed == 42)
    #expect(snapshot.silhouette == "photo-mask")
    #expect(snapshot.paletteToken == "violet-coral")
    #expect(snapshot.eyeDialect == "photo")
    #expect(snapshot.nonColorIdentityCue == "hexagonal frame")
    #expect(snapshot.accessibleIdentityDescription == "Portrait in a hexagonal frame")
    #expect(snapshot.profileAssetID == assetUUID)
    #expect(snapshot.revision == 9)
}

@Test("Roster and chat authorship share one complete teammate identity")
func sharedTeammateIdentityContract() throws {
    let teammateID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 2,
        deterministicSeed: 84,
        silhouette: "tall-tuft",
        paletteToken: "teal-gold",
        eyeDialect: "wide-curious",
        nonColorIdentityCue: "forehead spark",
        accessibleIdentityDescription: "Tall tuft creature with a forehead spark",
        revision: 3
    )
    let teammate = try Teammate(
        id: TeammateID(teammateID),
        profile: TeammateProfile(displayName: "Mira", role: "Researcher"),
        appearance: appearance,
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let identity = TeammateIdentitySnapshot(teammate)
    let row = TeammateRowSnapshot(identity: identity, activity: .speaking)
    let message = ChatMessageSnapshot(
        id: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
        author: .teammate(identity),
        body: "I found the source.",
        delivery: .sent,
        timestamp: Date(timeIntervalSince1970: 11)
    )

    #expect(row.identity == identity)
    #expect(row.id == teammateID)
    #expect(row.identitySeed == appearance.deterministicSeed)
    #expect(message.author.identity == row.identity)
    #expect(message.author.visibleName == "Mira")
    #expect(message.author.isUser == false)
    #expect(message.authorName == "Mira")
    #expect(message.isFromUser == false)
}

@Test("Fixture appearances are deterministic and complete")
func deterministicAppearanceFixture() {
    let first = CharacterAppearanceSnapshot.fixture(seed: 123)
    let second = CharacterAppearanceSnapshot.fixture(seed: 123)

    #expect(first == second)
    #expect(first.mode == .creature)
    #expect(first.grammarVersion > 0)
    #expect(first.revision > 0)
    #expect(first.profileAssetID == nil)
    #expect(!first.accessibleIdentityDescription.isEmpty)
    #expect(!first.nonColorIdentityCue.isEmpty)
}

@Test("Every teammate activity has a visible non-color label and symbol")
func teammateActivityAccessibilityVocabulary() {
    let states = TeammateActivityState.allCases
    #expect(Set(states.map(\.visibleLabel)).count == states.count)
    #expect(Set(states.map(\.symbolName)).count == states.count)
    #expect(states.allSatisfy { !$0.visibleLabel.isEmpty && !$0.symbolName.isEmpty })
}

@Test("Sidebar updates one stable identity without replacing unrelated rows")
@MainActor
func sidebarLocalizedUpdate() {
    let firstID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
    let first = TeammateRowSnapshot(
        id: firstID,
        name: "Ada",
        role: "Researcher",
        activity: .idle,
        identitySeed: 1
    )
    let second = TeammateRowSnapshot(
        id: secondID,
        name: "Lin",
        role: "Builder",
        activity: .thinkingOrWorking,
        identitySeed: 2
    )
    let model = SidebarModel(rows: [first, second], selection: secondID)
    let firstRow = model.rowModels[0]
    let unrelatedRow = model.rowModels[1]

    model.update(
        TeammateRowSnapshot(
            id: firstID,
            name: "Ada",
            role: "Researcher",
            activity: .waitingForUser,
            identitySeed: 1,
            unreadCount: 1
        )
    )

    #expect(model.rows.count == 2)
    #expect(model.rows[0].activity == .waitingForUser)
    #expect(model.rows[1] == second)
    #expect(model.rowModels[0] === firstRow)
    #expect(model.rowModels[1] === unrelatedRow)
    #expect(model.selection == secondID)
}

private actor SubmissionRecorder {
    private(set) var values: [(UUID, UUID, String)] = []

    func append(id: UUID, conversationID: UUID, text: String) {
        values.append((id, conversationID, text))
    }

    func count() -> Int { values.count }
}

@Test("Send inserts a pending bubble synchronously before async delivery")
@MainActor
func immediatePendingMessage() async throws {
    let recorder = SubmissionRecorder()
    let messageID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
    let conversationID = UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
    let now = Date(timeIntervalSince1970: 123)
    let model = ConversationModel(conversationID: conversationID, submit: { id, targetConversationID, text in
        await recorder.append(
            id: id,
            conversationID: targetConversationID,
            text: text
        )
    })
    model.composerText = "  steer this work  "

    model.sendCurrentText(now: now, messageID: messageID)

    #expect(model.composerText.isEmpty)
    #expect(model.messages == [
        ChatMessageSnapshot(
            id: messageID,
            author: .user,
            body: "steer this work",
            delivery: .pending,
            timestamp: now
        )
    ])

    for _ in 0..<100 {
        if await recorder.count() > 0 {
            break
        }
        await Task.yield()
    }
    #expect(await recorder.count() == 1)
    #expect(await recorder.values.first?.1 == conversationID)
}

@Test("Empty or whitespace-only composer text never creates a row")
@MainActor
func emptyComposerDoesNotSend() {
    let model = ConversationModel()
    model.composerText = " \n\t "
    model.sendCurrentText()
    #expect(model.messages.isEmpty)
}

@Test("An unavailable runtime preserves the draft and never creates a false pending row")
@MainActor
func unavailableRuntimeDoesNotPretendToSend() {
    let model = ConversationModel()
    model.composerText = "keep this draft"

    model.sendCurrentText()

    #expect(model.composerText == "keep this draft")
    #expect(model.messages.isEmpty)
    #expect(model.canSend == false)
    #expect(model.inputAvailability.unavailableReason == ConversationModel.defaultUnavailableReason)
}

@Test("A delivery update keeps the same message row object")
@MainActor
func deliveryUpdateIsRowScoped() {
    let messageID = UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
    let timestamp = Date(timeIntervalSince1970: 456)
    let pending = ChatMessageSnapshot(
        id: messageID,
        author: .user,
        body: "Continue",
        delivery: .pending,
        timestamp: timestamp
    )
    let model = ConversationModel(messages: [pending])
    let row = model.messageRows[0]

    model.replaceMessage(
        ChatMessageSnapshot(
            id: messageID,
            author: .user,
            body: "Continue",
            delivery: .sent,
            timestamp: timestamp
        )
    )

    #expect(model.messageRows[0] === row)
    #expect(model.messages[0].delivery == .sent)
}

@Test("Transcript follow policy preserves history reading and follows explicit user sends")
func transcriptScrollFollowPolicy() {
    #expect(
        TranscriptScrollFollowPolicy.followsTailAppend(
            isNearBottom: true,
            lastMessageIsFromUser: false,
            isOpeningConversation: false
        )
    )
    #expect(
        TranscriptScrollFollowPolicy.followsTailAppend(
            isNearBottom: false,
            lastMessageIsFromUser: true,
            isOpeningConversation: false
        )
    )
    #expect(
        TranscriptScrollFollowPolicy.followsTailAppend(
            isNearBottom: false,
            lastMessageIsFromUser: false,
            isOpeningConversation: true
        )
    )
    #expect(
        TranscriptScrollFollowPolicy.followsTailAppend(
            isNearBottom: false,
            lastMessageIsFromUser: false,
            isOpeningConversation: false
        ) == false
    )
    #expect(TranscriptScrollFollowPolicy.followsStreamingGrowth(isNearBottom: true))
    #expect(TranscriptScrollFollowPolicy.followsStreamingGrowth(isNearBottom: false) == false)
}

@Test("Prepending a deduplicated page preserves every existing row identity and page order")
@MainActor
func prependPagePreservesRowsAndOrder() {
    let olderID = UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
    let firstVisibleID = UUID(uuidString: "74000000-0000-0000-0000-000000000002")!
    let newestID = UUID(uuidString: "74000000-0000-0000-0000-000000000003")!
    let timestamp = Date(timeIntervalSince1970: 500)
    let firstVisible = ChatMessageSnapshot(
        id: firstVisibleID,
        author: .user,
        body: "First visible",
        delivery: .sent,
        timestamp: timestamp
    )
    let newest = ChatMessageSnapshot(
        id: newestID,
        author: .system(label: "OpenBots"),
        body: "Newest",
        delivery: .sent,
        timestamp: timestamp.addingTimeInterval(1)
    )
    let model = ConversationModel(
        messages: [firstVisible, newest],
        hasEarlierMessages: true
    )
    let firstVisibleRow = model.messageRows[0]
    let newestRow = model.messageRows[1]

    let olderDraft = ChatMessageSnapshot(
        id: olderID,
        author: .system(label: "OpenBots"),
        body: "Stale duplicate",
        delivery: .sent,
        timestamp: timestamp.addingTimeInterval(-2)
    )
    let olderFinal = ChatMessageSnapshot(
        id: olderID,
        author: .system(label: "OpenBots"),
        body: "Older final",
        delivery: .sent,
        timestamp: timestamp.addingTimeInterval(-2)
    )
    let overlappingUpdate = ChatMessageSnapshot(
        id: firstVisibleID,
        author: .user,
        body: "First visible, acknowledged",
        delivery: .sent,
        timestamp: timestamp
    )

    model.prependEarlierMessages(
        [olderDraft, olderFinal, overlappingUpdate],
        hasEarlierMessages: false
    )

    #expect(model.messageRows.map(\.id) == [olderID, firstVisibleID, newestID])
    #expect(model.messageRows[1] === firstVisibleRow)
    #expect(model.messageRows[2] === newestRow)
    #expect(model.messages[0].body == "Older final")
    #expect(model.messages[1].body == "First visible, acknowledged")
    #expect(model.hasEarlierMessages == false)
    #expect(model.historyLoadState == .idle)
}

private struct EarlierPageFailure: LocalizedError, Sendable {
    var errorDescription: String? { "Sensitive backend diagnostic" }
}

private actor EarlierPageLoaderRecorder {
    private(set) var attempts = 0
    private(set) var receivedAnchors: [UUID?] = []
    let page: ConversationMessagePageSnapshot

    init(page: ConversationMessagePageSnapshot) {
        self.page = page
    }

    func load(anchor: UUID?) throws -> ConversationMessagePageSnapshot {
        attempts += 1
        receivedAnchors.append(anchor)
        if attempts == 1 { throw EarlierPageFailure() }
        return page
    }
}

@Test("Earlier-page failure is inline and the same bounded request can retry")
@MainActor
func paginationFailureAndRetry() async {
    let conversationID = UUID(uuidString: "75000000-0000-0000-0000-000000000001")!
    let olderID = UUID(uuidString: "75000000-0000-0000-0000-000000000002")!
    let currentID = UUID(uuidString: "75000000-0000-0000-0000-000000000003")!
    let timestamp = Date(timeIntervalSince1970: 600)
    let older = ChatMessageSnapshot(
        id: olderID,
        author: .system(label: "OpenBots"),
        body: "Earlier",
        delivery: .sent,
        timestamp: timestamp
    )
    let current = ChatMessageSnapshot(
        id: currentID,
        author: .user,
        body: "Current",
        delivery: .sent,
        timestamp: timestamp.addingTimeInterval(1)
    )
    let recorder = EarlierPageLoaderRecorder(
        page: ConversationMessagePageSnapshot(
            messages: [older],
            hasEarlierMessages: false
        )
    )
    let model = ConversationModel(
        conversationID: conversationID,
        messages: [current],
        hasEarlierMessages: true,
        earlierPageLoader: { _, anchor in
            try await recorder.load(anchor: anchor)
        }
    )
    let currentRow = model.messageRows[0]

    model.loadEarlierMessages()
    #expect(model.historyLoadState == .loading)
    for _ in 0..<100 where model.historyLoadState.failureReason == nil {
        await Task.yield()
    }

    #expect(
        model.historyLoadState.failureReason ==
            "The local history service did not complete. Try again."
    )
    #expect(model.historyLoadState.failureReason?.contains("Sensitive") == false)
    #expect(model.messageRows.count == 1)
    #expect(model.messageRows[0] === currentRow)
    #expect(model.hasEarlierMessages)

    model.loadEarlierMessages()
    #expect(model.historyLoadState == .loading)
    for _ in 0..<100 where model.historyLoadState != .idle {
        await Task.yield()
    }

    #expect(model.historyLoadState == .idle)
    #expect(model.messageRows.map(\.id) == [olderID, currentID])
    #expect(model.messageRows[1] === currentRow)
    #expect(model.hasEarlierMessages == false)
    #expect(await recorder.attempts == 2)
    #expect(await recorder.receivedAnchors == [currentID, currentID])
}

@Test("Streaming deltas and completion mutate only the target leaf row")
@MainActor
func streamingUpdatesStayRowLocal() {
    let priorID = UUID(uuidString: "76000000-0000-0000-0000-000000000001")!
    let streamID = UUID(uuidString: "76000000-0000-0000-0000-000000000002")!
    let partID = UUID(uuidString: "76000000-0000-0000-0000-000000000003")!
    let timestamp = Date(timeIntervalSince1970: 700)
    let prior = ChatMessageSnapshot(
        id: priorID,
        author: .user,
        body: "Keep this row",
        delivery: .sent,
        timestamp: timestamp
    )
    let model = ConversationModel(messages: [prior])
    let priorRow = model.messageRows[0]
    let streamRow = model.beginStreamingMessage(
        ChatMessageSnapshot(
            id: streamID,
            author: .system(label: "Local fixture"),
            body: "",
            delivery: .sent,
            timestamp: timestamp.addingTimeInterval(1)
        )
    )

    #expect(model.appendStreamingDelta(messageID: streamID, delta: "Hel", partID: partID))
    #expect(model.appendStreamingDelta(messageID: streamID, delta: "lo", partID: partID))
    #expect(model.appendStreamingDelta(messageID: streamID, delta: "!", partID: partID))
    #expect(model.completeStreamingMessage(id: streamID))

    #expect(model.messageRows[0] === priorRow)
    #expect(model.messageRows[1] === streamRow)
    #expect(model.messageRows[1].snapshot.body == "Hello!")
    #expect(model.messageRows[1].snapshot.parts.map(\.id) == [partID])
    #expect(model.messageRows[1].snapshot.streamState == .complete)
    #expect(model.messageRows[1].snapshot.delivery == .sent)
    #expect(
        model.appendStreamingDelta(messageID: streamID, delta: " ignored", partID: partID)
            == false
    )
    #expect(model.messageRows[1].snapshot.body == "Hello!")
}

@Test("Structured message parts are deduplicated and rendered in ordinal order")
func structuredPartsAreOrderedAndAccessible() {
    let messageID = UUID(uuidString: "77000000-0000-0000-0000-000000000001")!
    let textPartID = UUID(uuidString: "77000000-0000-0000-0000-000000000002")!
    let attachmentPartID = UUID(uuidString: "77000000-0000-0000-0000-000000000003")!
    let artifactPartID = UUID(uuidString: "77000000-0000-0000-0000-000000000004")!
    let attachmentID = UUID(uuidString: "77000000-0000-0000-0000-000000000005")!
    let artifactID = UUID(uuidString: "77000000-0000-0000-0000-000000000006")!
    let message = ChatMessageSnapshot(
        id: messageID,
        author: .system(label: "Local fixture"),
        parts: [
            ChatMessagePartSnapshot(
                id: artifactPartID,
                ordinal: 2,
                content: .artifact(
                    ChatArtifactSnapshot(
                        id: artifactID,
                        title: "Research brief.pdf",
                        detail: "Verified local artifact"
                    )
                )
            ),
            ChatMessagePartSnapshot(
                id: attachmentPartID,
                ordinal: 1,
                content: .attachment(
                    ChatAttachmentSnapshot(id: attachmentID, displayName: "draft.txt")
                )
            ),
            ChatMessagePartSnapshot(
                id: textPartID,
                ordinal: 0,
                content: .text("Here are the files.")
            ),
            ChatMessagePartSnapshot(
                id: attachmentPartID,
                ordinal: 1,
                content: .attachment(
                    ChatAttachmentSnapshot(
                        id: attachmentID,
                        displayName: "sources.txt",
                        detail: "3 KB"
                    )
                )
            )
        ],
        delivery: .sent,
        timestamp: Date(timeIntervalSince1970: 800)
    )

    #expect(message.parts.map(\.id) == [textPartID, attachmentPartID, artifactPartID])
    #expect(message.parts.map(\.ordinal) == [0, 1, 2])
    if case .attachment(let attachment) = message.parts[1].content {
        #expect(attachment.displayName == "sources.txt")
        #expect(attachment.detail == "3 KB")
    } else {
        Issue.record("Expected an attachment presentation part")
    }
    #expect(message.body == "Here are the files.")
    #expect(message.accessibilityBody.contains("Attachment: sources.txt"))
    #expect(message.accessibilityBody.contains("Artifact: Research brief.pdf"))
}

@Test("One card part can update without replacing its message row or sibling parts")
@MainActor
func cardPartReplacementStaysLeafScoped() {
    let messageID = UUID(uuidString: "78000000-0000-0000-0000-000000000001")!
    let textPartID = UUID(uuidString: "78000000-0000-0000-0000-000000000002")!
    let cardPartID = UUID(uuidString: "78000000-0000-0000-0000-000000000003")!
    let cardID = UUID(uuidString: "78000000-0000-0000-0000-000000000004")!
    let choiceID = UUID(uuidString: "78000000-0000-0000-0000-000000000005")!
    let question = ChatQuestionCardSnapshot(
        id: cardID,
        prompt: "Which format should I use?",
        choices: [ChatQuestionChoiceSnapshot(id: choiceID, title: "Markdown")],
        allowsFreeText: true
    )
    let model = ChatMessageModel(
        snapshot: ChatMessageSnapshot(
            id: messageID,
            author: .system(label: "Local fixture"),
            parts: [
                ChatMessagePartSnapshot(
                    id: textPartID,
                    ordinal: 0,
                    content: .text("I need one detail.")
                ),
                ChatMessagePartSnapshot(
                    id: cardPartID,
                    ordinal: 1,
                    content: .question(question)
                )
            ],
            delivery: .sent,
            timestamp: Date(timeIntervalSince1970: 900)
        )
    )
    let sameRow = model

    #expect(
        model.replacePart(
            id: cardPartID,
            content: .question(
                ChatQuestionCardSnapshot(
                    id: cardID,
                    prompt: question.prompt,
                    choices: question.choices,
                    allowsFreeText: question.allowsFreeText,
                    resolution: .answered
                )
            )
        )
    )

    #expect(model === sameRow)
    #expect(model.id == messageID)
    #expect(model.snapshot.parts.map(\.id) == [textPartID, cardPartID])
    #expect(model.snapshot.parts.map(\.ordinal) == [0, 1])
    #expect(model.snapshot.body == "I need one detail.")
    if case .question(let updated) = model.snapshot.parts[1].content {
        #expect(updated.id == cardID)
        #expect(updated.resolution == .answered)
    } else {
        Issue.record("Expected the exact question part to be replaced")
    }
    #expect(
        model.replacePart(
            id: UUID(uuidString: "78000000-0000-0000-0000-000000000099")!,
            content: .status("Should not append")
        ) == false
    )
    #expect(model.snapshot.parts.count == 2)
}

@Test("Card accessibility summaries omit arbitrary paths and secret-like copy")
func cardAccessibilitySummariesAreBounded() {
    let pathSentinel = "/Users/example/Private/secret.txt"
    let secretSentinel = "s2b-secret-sentinel-never-describe"
    let question = ChatQuestionCardSnapshot(
        id: UUID(),
        prompt: pathSentinel,
        choices: [ChatQuestionChoiceSnapshot(id: UUID(), title: secretSentinel)],
        allowsFreeText: true
    )
    let connector = ChatConnectorSetupCardSnapshot(
        id: UUID(),
        connectorName: pathSentinel,
        installation: .installed,
        authentication: .failed,
        botGrant: .notGranted,
        actionApproval: .notRequested
    )
    let secret = ChatSecretCardSnapshot(
        id: UUID(),
        label: secretSentinel,
        purpose: pathSentinel,
        presence: .absent
    )
    let summaries = [
        question.accessibilityDescription,
        connector.accessibilityDescription,
        secret.accessibilityDescription
    ]

    #expect(summaries.allSatisfy { !$0.contains(pathSentinel) })
    #expect(summaries.allSatisfy { !$0.contains(secretSentinel) })
    #expect(question.accessibilityDescription.contains("answer choices"))
    #expect(connector.accessibilityDescription.contains("Account authentication"))
    #expect(secret.accessibilityDescription.contains("value is never shown"))
}
