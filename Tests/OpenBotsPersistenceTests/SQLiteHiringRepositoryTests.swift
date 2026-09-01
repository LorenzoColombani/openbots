import Foundation
import XCTest
@testable import OpenBotsDomain
@testable import OpenBotsPersistence

final class SQLiteHiringRepositoryTests: XCTestCase {
    private let receipt = try! ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "93000000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 1_788_200_000),
        rationaleVersion: 2
    )
    private let instant = Date(timeIntervalSince1970: 1_788_200_100)

    func testCreateAndReopenRoundTripsDraftAndExactOrderedTurns() async throws {
        let fixture = try HiringStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let snapshot = try initialSnapshot(value: 1)

        do {
            let store = try fixture.open()
            let created = try await store.createHiringDraft(snapshot)
            XCTAssertEqual(created, snapshot)
        }

        let reopened = try fixture.open()
        let loaded = try await reopened.latestHiringDraft()
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded?.turns.map(\.sequence), [1, 2])
        XCTAssertEqual(loaded?.turns[1].text, "  A source-conscious research lead.\n")
        let facts = try await reopened.runtimeFacts()
        XCTAssertEqual(facts.migrationCount, SQLiteStore.expectedMigrationCount)
    }

    func testOrderedRevisionAppendsTurnsAndStaleRevisionRollsBack() async throws {
        let fixture = try HiringStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let initial = try initialSnapshot(value: 2)
        _ = try await store.createHiringDraft(initial)

        let revisedDraft = try initial.draft.revised(
            displayName: "Ada",
            role: "Research lead",
            responsibilities: "Keep provenance visible.",
            updatedAt: instant.addingTimeInterval(20)
        )
        let third = try hiringTurn(
            value: 23,
            draftID: revisedDraft.id,
            sequence: 3,
            author: .guide,
            text: "How should Ada work?",
            at: instant.addingTimeInterval(15)
        )
        let fourth = try hiringTurn(
            value: 24,
            draftID: revisedDraft.id,
            sequence: 4,
            author: .user,
            text: "Carefully and independently.",
            at: instant.addingTimeInterval(20)
        )
        let revised = try await store.reviseHiringDraft(
            revisedDraft,
            expectedRevision: 1,
            appending: [third, fourth]
        )
        XCTAssertEqual(revised.draft.revision, 2)
        XCTAssertEqual(revised.turns.map(\.sequence), [1, 2, 3, 4])

        let staleAlternative = try initial.draft.revised(
            displayName: "Stale",
            role: "Should not persist",
            updatedAt: instant.addingTimeInterval(30)
        )
        do {
            _ = try await store.reviseHiringDraft(
                staleAlternative,
                expectedRevision: 1,
                appending: []
            )
            XCTFail("A stale revision must fail closed.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .optimisticLockFailed(
                    entity: "hiring draft",
                    id: initial.draft.id.persistedValue
                )
            )
        }
        let afterStaleRevision = try await store.latestHiringDraft()
        XCTAssertEqual(afterStaleRevision, revised)
    }

    func testCancelDeletesOnlyExactDraftGraphAndCreatesNoTeammate() async throws {
        let fixture = try HiringStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let snapshot = try initialSnapshot(value: 3)
        _ = try await store.createHiringDraft(snapshot)

        try await store.cancelHiringDraft(id: snapshot.draft.id, expectedRevision: 1)

        let draftAfterCancel = try await store.latestHiringDraft()
        let teammatesAfterCancel = try await store.listTeammates(includingArchived: true)
        let turnCountAfterCancel = try await countRows(in: "hiring_turns", store: store)
        XCTAssertNil(draftAfterCancel)
        XCTAssertTrue(teammatesAfterCancel.isEmpty)
        XCTAssertEqual(turnCountAfterCancel, 0)
    }

    func testConfirmAtomicallyProvisionsDirectChatOnceAndRemovesDraft() async throws {
        let fixture = try HiringStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let existing = try [makeTeammate(value: 1, name: "First", role: "Research"),
                            makeTeammate(value: 2, name: "Second", role: "Writing")]
        for (index, teammate) in existing.enumerated() {
            try await store.provisionDirectChat(
                teammate: teammate, conversation: makeConversation(value: index + 1, teammateID: teammate.id),
                fixtureGreeting: nil, selectConversation: false
            )
        }
        let initialOrder = try await store.loadBotSidebarOrder()
        _ = try await store.saveBotSidebarOrder(existing.map(\.id), expectedRevision: initialOrder.revision)
        let collecting = try initialSnapshot(value: 4)
        _ = try await store.createHiringDraft(collecting)
        let readyDraft = try collecting.draft.revised(
            phase: .readyForReview,
            displayName: "Mika",
            role: "Evidence lead",
            responsibilities: "Trace claims.",
            workingStyle: "Calm and direct.",
            skills: "Research; synthesis",
            permissionIntent: "Read-only until explicitly granted more.",
            projectPlacement: "Research",
            teamPlacement: "Studio",
            updatedAt: instant.addingTimeInterval(20)
        )
        let readyTurn = try hiringTurn(
            value: 43,
            draftID: readyDraft.id,
            sequence: 3,
            author: .guide,
            text: "Mika is ready for review.",
            at: instant.addingTimeInterval(20)
        )
        _ = try await store.reviseHiringDraft(
            readyDraft,
            expectedRevision: 1,
            appending: [readyTurn]
        )

        let teammate = try makeTeammate(value: 4, name: "Mika", role: "Evidence lead")
        let conversation = try makeConversation(value: 4, teammateID: teammate.id)
        let greeting = try makeGreeting(value: 4, teammate: teammate, conversation: conversation)
        try await store.confirmHiringDraft(
            id: readyDraft.id,
            expectedRevision: 2,
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: greeting,
            selectConversation: true
        )

        let draftAfterConfirmation = try await store.latestHiringDraft()
        let turnCountAfterConfirmation = try await countRows(in: "hiring_turns", store: store)
        let confirmedTeammate = try await store.teammate(id: teammate.id)
        let confirmedConversation = try await store.conversation(id: conversation.id)
        let confirmedSelection = try await store.selectedConversationID()
        XCTAssertNil(draftAfterConfirmation)
        XCTAssertEqual(turnCountAfterConfirmation, 0)
        XCTAssertEqual(confirmedTeammate, teammate)
        XCTAssertEqual(confirmedConversation, conversation)
        XCTAssertEqual(confirmedSelection, conversation.id)
        let confirmedOrder = try await store.loadBotSidebarOrder()
        XCTAssertEqual(confirmedOrder.teammateIDs, [teammate.id] + existing.map(\.id))
        let page = try await store.page(
            conversationID: conversation.id,
            request: PageRequest(limit: 10)
        )
        XCTAssertEqual(page.elements, [greeting])

        do {
            try await store.confirmHiringDraft(
                id: readyDraft.id,
                expectedRevision: 2,
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: greeting,
                selectConversation: true
            )
            XCTFail("A consumed draft must not confirm twice.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .notFound(entity: "hiring draft", id: readyDraft.id.persistedValue)
            )
        }
        let teammatesAfterSecondConfirmation = try await store.listTeammates(includingArchived: true)
        XCTAssertEqual(teammatesAfterSecondConfirmation.count, existing.count + 1)
    }

    func testNotReadyAndMalformedConfirmationRollBackWithoutConsumingDraft() async throws {
        let fixture = try HiringStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let collecting = try initialSnapshot(value: 5)
        _ = try await store.createHiringDraft(collecting)
        let teammate = try makeTeammate(value: 5, name: "Draft", role: "Candidate")
        let conversation = try makeConversation(value: 5, teammateID: teammate.id)

        do {
            try await store.confirmHiringDraft(
                id: collecting.draft.id,
                expectedRevision: 1,
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: nil,
                selectConversation: true
            )
            XCTFail("A collecting draft must not confirm.")
        } catch let error as DomainValidationError {
            XCTAssertEqual(
                error,
                .invalid(
                    field: "hiring draft phase",
                    reason: "must be ready for review before confirmation"
                )
            )
        }
        let collectingAfterRejection = try await store.latestHiringDraft()
        let teammateAfterRejection = try await store.teammate(id: teammate.id)
        XCTAssertEqual(collectingAfterRejection, collecting)
        XCTAssertNil(teammateAfterRejection)

        let ready = try collecting.draft.revised(
            phase: .readyForReview,
            displayName: "Draft",
            role: "Candidate",
            updatedAt: instant.addingTimeInterval(30)
        )
        _ = try await store.reviseHiringDraft(ready, expectedRevision: 1, appending: [])
        let malformedConversation = try makeConversation(
            value: 6,
            teammateID: TeammateID(uuid(999))
        )
        do {
            try await store.confirmHiringDraft(
                id: ready.id,
                expectedRevision: 2,
                teammate: teammate,
                conversation: malformedConversation,
                fixtureGreeting: nil,
                selectConversation: true
            )
            XCTFail("A malformed direct-chat aggregate must not confirm.")
        } catch let error as DomainValidationError {
            guard case .invalid(field: "direct conversation", reason: _) = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }
        let readyAfterMalformedConfirmation = try await store.latestHiringDraft()
        let teammateAfterMalformedConfirmation = try await store.teammate(id: teammate.id)
        let conversationAfterMalformedConfirmation = try await store.conversation(
            id: malformedConversation.id
        )
        XCTAssertEqual(readyAfterMalformedConfirmation?.draft, ready)
        XCTAssertNil(teammateAfterMalformedConfirmation)
        XCTAssertNil(conversationAfterMalformedConfirmation)
    }

    private func initialSnapshot(value: Int) throws -> HiringDraftSnapshot {
        let draftID = HiringDraftID(uuid(100 + value))
        let draft = try HiringDraft(
            id: draftID,
            createdAt: instant,
            updatedAt: instant.addingTimeInterval(10)
        )
        return try HiringDraftSnapshot(
            draft: draft,
            turns: [
                hiringTurn(
                    value: value * 10 + 1,
                    draftID: draftID,
                    sequence: 1,
                    author: .guide,
                    text: "Who should we hire?",
                    at: instant
                ),
                hiringTurn(
                    value: value * 10 + 2,
                    draftID: draftID,
                    sequence: 2,
                    author: .user,
                    text: "  A source-conscious research lead.\n",
                    at: instant.addingTimeInterval(10)
                )
            ]
        )
    }

    private func hiringTurn(
        value: Int,
        draftID: HiringDraftID,
        sequence: Int64,
        author: HiringTurnAuthor,
        text: String,
        at date: Date
    ) throws -> HiringTurn {
        try HiringTurn(
            id: HiringTurnID(uuid(1_000 + value)),
            draftID: draftID,
            sequence: sequence,
            author: author,
            text: text,
            createdAt: date
        )
    }

    private func makeTeammate(value: Int, name: String, role: String) throws -> Teammate {
        try Teammate(
            id: TeammateID(uuid(2_000 + value)),
            profile: TeammateProfile(displayName: name, role: role),
            appearance: AgentAppearance(
                mode: .creature,
                grammarVersion: 1,
                deterministicSeed: UInt64(value),
                silhouette: "rounded",
                paletteToken: "indigo",
                eyeDialect: "focused",
                nonColorIdentityCue: "two short antennae",
                accessibleIdentityDescription: "An indigo rounded creature with two short antennae."
            ),
            createdAt: instant.addingTimeInterval(40),
            updatedAt: instant.addingTimeInterval(40)
        )
    }

    private func makeConversation(value: Int, teammateID: TeammateID) throws -> Conversation {
        try Conversation(
            id: ConversationID(uuid(3_000 + value)),
            kind: .direct(teammateID: teammateID),
            title: "Hiring confirmation",
            createdAt: instant.addingTimeInterval(40),
            updatedAt: instant.addingTimeInterval(40)
        )
    }

    private func makeGreeting(
        value: Int,
        teammate: Teammate,
        conversation: Conversation
    ) throws -> Message {
        try Message(
            id: MessageID(uuid(4_000 + value)),
            conversationID: conversation.id,
            sequence: 1,
            author: .teammate(teammate.id),
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(uuid(5_000 + value)),
                    ordinal: 0,
                    content: .text("Preview fixture only; no Claude runtime produced this greeting.")
                )
            ],
            createdAt: instant.addingTimeInterval(40),
            updatedAt: instant.addingTimeInterval(40)
        )
    }

    private func countRows(in table: String, store: SQLiteStore) async throws -> Int64 {
        let allowed = ["hiring_turns"]
        precondition(allowed.contains(table))
        return try await store.query(sql: "SELECT COUNT(*) AS count FROM \(table);").first!.integer("count")
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "93000000-0000-0000-0000-%012d", value))!
    }
}

private final class HiringStoreFixture {
    let directory: URL
    let databaseURL: URL
    let receipt: ProtectionDecisionReceipt

    init(receipt: ProtectionDecisionReceipt) throws {
        self.receipt = receipt
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openbots-hiring-tests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        databaseURL = directory.appendingPathComponent("OpenBots.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: databaseURL,
                protection: .ordinarySQLite(decision: receipt)
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
