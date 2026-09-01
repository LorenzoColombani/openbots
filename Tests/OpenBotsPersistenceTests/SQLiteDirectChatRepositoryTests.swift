import Foundation
import XCTest
import OpenBotsDomain
@testable import OpenBotsPersistence

final class SQLiteDirectChatRepositoryTests: XCTestCase {
    private let receipt = try! ProtectionDecisionReceipt(
        decisionID: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
        selectedAt: Date(timeIntervalSince1970: 1_788_000_000),
        rationaleVersion: 2
    )

    func testAtomicProvisionRoundTripsCompleteIdentityChatGreetingAndSelectionAcrossReopen() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let instant = Date(timeIntervalSince1970: 1_788_000_100)
        let teammate = try makeTeammate(
            id: teammateID(1),
            name: "Mika",
            seed: UInt64.max - 7,
            at: instant
        )
        let conversation = try makeDirectConversation(
            id: conversationID(1),
            teammateID: teammate.id,
            title: "Mika and Lorenzo",
            at: instant
        )
        let greeting = try makeFixtureGreeting(
            id: messageID(1),
            partBase: 10,
            teammateID: teammate.id,
            conversationID: conversation.id,
            at: instant
        )

        do {
            let store = try fixture.open()
            try await store.provisionDirectChat(
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: greeting,
                selectConversation: true
            )
            let facts = try await store.runtimeFacts()
            XCTAssertEqual(facts.migrationCount, SQLiteStore.expectedMigrationCount)
        }

        let reopened = try fixture.open()
        let reloadedTeammate = try await reopened.teammate(id: teammate.id)
        let reloadedConversation = try await reopened.conversation(id: conversation.id)
        let reloadedConversations = try await reopened.conversations(
            for: teammate.id,
            includingArchived: false
        )
        XCTAssertEqual(reloadedTeammate, teammate)
        XCTAssertEqual(reloadedConversation, conversation)
        XCTAssertEqual(reloadedConversations, [conversation])
        let page = try await reopened.page(
            conversationID: conversation.id,
            request: PageRequest(limit: 20)
        )
        XCTAssertEqual(page.elements, [greeting])
        XCTAssertFalse(page.hasMore)
        let reloadedSelection = try await reopened.selectedConversationID()
        XCTAssertEqual(reloadedSelection, conversation.id)
    }

    func testLateGreetingCollisionRollsBackWholeAggregateAndPreservesPriorSelection() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let instant = Date(timeIntervalSince1970: 1_788_000_200)

        let firstTeammate = try makeTeammate(id: teammateID(2), name: "Mika", seed: 2, at: instant)
        let firstConversation = try makeDirectConversation(
            id: conversationID(2),
            teammateID: firstTeammate.id,
            title: nil,
            at: instant
        )
        let existingGreeting = try makeFixtureGreeting(
            id: messageID(2),
            partBase: 20,
            teammateID: firstTeammate.id,
            conversationID: firstConversation.id,
            at: instant
        )
        try await store.provisionDirectChat(
            teammate: firstTeammate,
            conversation: firstConversation,
            fixtureGreeting: existingGreeting,
            selectConversation: true
        )

        let secondTeammate = try makeTeammate(id: teammateID(3), name: "Rook", seed: 3, at: instant)
        let secondConversation = try makeDirectConversation(
            id: conversationID(3),
            teammateID: secondTeammate.id,
            title: nil,
            at: instant
        )
        let collidingGreeting = try makeFixtureGreeting(
            id: existingGreeting.id,
            partBase: 30,
            teammateID: secondTeammate.id,
            conversationID: secondConversation.id,
            at: instant
        )

        do {
            try await store.provisionDirectChat(
                teammate: secondTeammate,
                conversation: secondConversation,
                fixtureGreeting: collidingGreeting,
                selectConversation: true
            )
            XCTFail("A duplicate message identity must abort direct-chat provisioning.")
        } catch {
            XCTAssertTrue(error is SQLiteStoreError)
            // The exact SQLite constraint text is not a public contract. The
            // absence of every earlier insert proves transaction rollback.
        }

        let rolledBackTeammate = try await store.teammate(id: secondTeammate.id)
        let rolledBackConversation = try await store.conversation(id: secondConversation.id)
        let rolledBackConversations = try await store.conversations(
            for: secondTeammate.id,
            includingArchived: true
        )
        let preservedSelection = try await store.selectedConversationID()
        let preservedGreeting = try await store.message(id: existingGreeting.id)
        XCTAssertNil(rolledBackTeammate)
        XCTAssertNil(rolledBackConversation)
        XCTAssertTrue(rolledBackConversations.isEmpty)
        XCTAssertEqual(preservedSelection, firstConversation.id)
        XCTAssertEqual(preservedGreeting, existingGreeting)
    }

    func testSelectionChangesClearsAndOptionalGreetingCanBeOmitted() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let instant = Date(timeIntervalSince1970: 1_788_000_300)
        let firstTeammate = try makeTeammate(id: teammateID(4), name: "Mika", seed: 4, at: instant)
        let firstConversation = try makeDirectConversation(
            id: conversationID(4),
            teammateID: firstTeammate.id,
            title: nil,
            at: instant
        )
        let secondTeammate = try makeTeammate(id: teammateID(5), name: "Rook", seed: 5, at: instant)
        let secondConversation = try makeDirectConversation(
            id: conversationID(5),
            teammateID: secondTeammate.id,
            title: nil,
            at: instant
        )

        try await store.provisionDirectChat(
            teammate: firstTeammate,
            conversation: firstConversation,
            fixtureGreeting: nil,
            selectConversation: true
        )
        try await store.provisionDirectChat(
            teammate: secondTeammate,
            conversation: secondConversation,
            fixtureGreeting: nil,
            selectConversation: false
        )
        let firstSelection = try await store.selectedConversationID()
        XCTAssertEqual(firstSelection, firstConversation.id)

        try await store.setSelectedConversationID(secondConversation.id)
        let secondSelection = try await store.selectedConversationID()
        XCTAssertEqual(secondSelection, secondConversation.id)
        let secondPage = try await store.page(
            conversationID: secondConversation.id,
            request: PageRequest(limit: 10)
        )
        XCTAssertTrue(secondPage.elements.isEmpty)

        try await store.setSelectedConversationID(nil)
        let clearedSelection = try await store.selectedConversationID()
        XCTAssertNil(clearedSelection)

        let reopened = try fixture.open()
        let reopenedSelection = try await reopened.selectedConversationID()
        XCTAssertNil(reopenedSelection)
    }

    func testSelectionRejectsMissingAndNonDirectConversationsAtTypedAndSchemaBoundaries() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let instant = Date(timeIntervalSince1970: 1_788_000_400)
        let teammate = try makeTeammate(id: teammateID(6), name: "Mika", seed: 6, at: instant)
        let directConversation = try makeDirectConversation(
            id: conversationID(6),
            teammateID: teammate.id,
            title: nil,
            at: instant
        )
        try await store.provisionDirectChat(
            teammate: teammate,
            conversation: directConversation,
            fixtureGreeting: nil,
            selectConversation: true
        )

        let missingID = conversationID(99)
        do {
            try await store.setSelectedConversationID(missingID)
            XCTFail("A missing conversation must not become selected.")
        } catch let error as RepositoryError {
            XCTAssertEqual(
                error,
                .notFound(entity: "conversation", id: missingID.persistedValue)
            )
        }
        let selectionAfterMissing = try await store.selectedConversationID()
        XCTAssertEqual(selectionAfterMissing, directConversation.id)

        let projectConversation = try Conversation(
            id: conversationID(7),
            kind: .project(projectID: ProjectID(uuid(700))),
            title: "Project room",
            createdAt: instant,
            updatedAt: instant
        )
        try await store.insert(projectConversation, participantIDs: [teammate.id])

        do {
            try await store.setSelectedConversationID(projectConversation.id)
            XCTFail("A project conversation must not become direct-chat selection.")
        } catch let error as DomainValidationError {
            XCTAssertEqual(
                error,
                .invalid(
                    field: "selected conversation",
                    reason: "must reference a direct conversation"
                )
            )
        }
        let selectionAfterProject = try await store.selectedConversationID()
        XCTAssertEqual(selectionAfterProject, directConversation.id)

        do {
            _ = try await store.execute(
                sql: "UPDATE chat_navigation_state SET selected_conversation_id=? WHERE singleton_id=1;",
                bindings: [.text(projectConversation.id.persistedValue)]
            )
            XCTFail("The schema trigger must reject a non-direct conversation even if a caller bypasses the repository API.")
        } catch {
            XCTAssertTrue(error is SQLiteStoreError)
            // The schema-level error is deliberately lower-level than the
            // repository's typed validation, but it must still fail closed.
        }
        let selectionAfterSchemaRejection = try await store.selectedConversationID()
        XCTAssertEqual(selectionAfterSchemaRejection, directConversation.id)
    }

    func testCrossAggregateValidationFailsBeforeAnyRowsAreWritten() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let instant = Date(timeIntervalSince1970: 1_788_000_500)
        let teammate = try makeTeammate(id: teammateID(8), name: "Mika", seed: 8, at: instant)
        let otherID = teammateID(9)
        let mismatchedConversation = try makeDirectConversation(
            id: conversationID(8),
            teammateID: otherID,
            title: nil,
            at: instant
        )

        do {
            try await store.provisionDirectChat(
                teammate: teammate,
                conversation: mismatchedConversation,
                fixtureGreeting: nil,
                selectConversation: true
            )
            XCTFail("A direct conversation for a different teammate must be rejected.")
        } catch let error as DomainValidationError {
            XCTAssertEqual(
                error,
                .invalid(
                    field: "direct conversation",
                    reason: "must reference the teammate being provisioned"
                )
            )
        }

        let missingTeammate = try await store.teammate(id: teammate.id)
        let missingConversation = try await store.conversation(id: mismatchedConversation.id)
        let missingSelection = try await store.selectedConversationID()
        XCTAssertNil(missingTeammate)
        XCTAssertNil(missingConversation)
        XCTAssertNil(missingSelection)
    }

    func testFixtureGreetingMustMatchConversationTeammateAndFirstSequence() async throws {
        let fixture = try TestStoreFixture(receipt: receipt)
        defer { fixture.remove() }
        let store = try fixture.open()
        let instant = Date(timeIntervalSince1970: 1_788_000_600)

        let cases: [(Int, String, Message)] = [
            (
                10,
                "fixture greeting conversation",
                try makeFixtureGreeting(
                    id: messageID(10),
                    partBase: 100,
                    teammateID: teammateID(10),
                    conversationID: conversationID(90),
                    at: instant
                )
            ),
            (
                11,
                "fixture greeting author",
                try makeFixtureGreeting(
                    id: messageID(11),
                    partBase: 110,
                    teammateID: teammateID(91),
                    conversationID: conversationID(11),
                    at: instant
                )
            ),
            (
                12,
                "fixture greeting sequence",
                try makeFixtureGreeting(
                    id: messageID(12),
                    partBase: 120,
                    teammateID: teammateID(12),
                    conversationID: conversationID(12),
                    sequence: 2,
                    at: instant
                )
            )
        ]

        for (value, expectedField, greeting) in cases {
            let teammate = try makeTeammate(
                id: teammateID(value),
                name: "Fixture \(value)",
                seed: UInt64(value),
                at: instant
            )
            let conversation = try makeDirectConversation(
                id: conversationID(value),
                teammateID: teammate.id,
                title: nil,
                at: instant
            )
            do {
                try await store.provisionDirectChat(
                    teammate: teammate,
                    conversation: conversation,
                    fixtureGreeting: greeting,
                    selectConversation: true
                )
                XCTFail("An invalid fixture greeting must not be provisioned.")
            } catch let error as DomainValidationError {
                guard case let .invalid(field, _) = error else {
                    return XCTFail("Expected an invalid-field error, got \(error).")
                }
                XCTAssertEqual(field, expectedField)
            }

            let absentTeammate = try await store.teammate(id: teammate.id)
            let absentConversation = try await store.conversation(id: conversation.id)
            XCTAssertNil(absentTeammate)
            XCTAssertNil(absentConversation)
        }
        let selection = try await store.selectedConversationID()
        XCTAssertNil(selection)
    }

    private func makeTeammate(
        id: TeammateID,
        name: String,
        seed: UInt64,
        at instant: Date
    ) throws -> Teammate {
        try Teammate(
            id: id,
            profile: TeammateProfile(
                displayName: name,
                title: "Evidence lead",
                role: "Research and synthesis",
                detailedInstructions: "Keep sources, assumptions, and open questions visible.",
                revision: 3
            ),
            appearance: AgentAppearance(
                mode: .creature,
                grammarVersion: 4,
                deterministicSeed: seed,
                silhouette: "soft-diamond",
                paletteToken: "ocean-violet",
                eyeDialect: "offset-wide",
                nonColorIdentityCue: "three crown notches",
                accessibleIdentityDescription: "Soft diamond creature with offset wide eyes and three crown notches",
                revision: 7
            ),
            lifecycle: .active,
            isPinned: true,
            isHidden: false,
            notificationPreference: .enabled,
            createdAt: instant,
            updatedAt: instant
        )
    }

    private func makeDirectConversation(
        id: ConversationID,
        teammateID: TeammateID,
        title: String?,
        at instant: Date
    ) throws -> Conversation {
        try Conversation(
            id: id,
            kind: .direct(teammateID: teammateID),
            title: title,
            createdAt: instant,
            updatedAt: instant
        )
    }

    private func makeFixtureGreeting(
        id: MessageID,
        partBase: Int,
        teammateID: TeammateID,
        conversationID: ConversationID,
        sequence: Int64 = 1,
        at instant: Date
    ) throws -> Message {
        try Message(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            author: .teammate(teammateID),
            outputClass: .conversation,
            deliveryState: .completed,
            parts: [
                try MessagePart(
                    id: MessagePartID(uuid(partBase)),
                    ordinal: 0,
                    content: .text("Local fixture greeting — Claude and the production runtime are not running.")
                ),
                try MessagePart(
                    id: MessagePartID(uuid(partBase + 1)),
                    ordinal: 1,
                    content: .status("Fixture only")
                )
            ],
            createdAt: instant,
            updatedAt: instant
        )
    }

    private func teammateID(_ value: Int) -> TeammateID { TeammateID(uuid(100 + value)) }
    private func conversationID(_ value: Int) -> ConversationID { ConversationID(uuid(200 + value)) }
    private func messageID(_ value: Int) -> MessageID { MessageID(uuid(300 + value)) }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "82000000-0000-0000-0000-%012d", value))!
    }
}

private final class TestStoreFixture {
    let directory: URL
    let databaseURL: URL
    let receipt: ProtectionDecisionReceipt

    init(receipt: ProtectionDecisionReceipt) throws {
        self.receipt = receipt
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openbots-direct-chat-tests-\(UUID().uuidString).noindex",
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
