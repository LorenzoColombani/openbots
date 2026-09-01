import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("SQLiteChatSelectionCancellationTests")
struct SQLiteChatSelectionCancellationTests {
    @Test("Pre-cancelled select and clear leave the complete navigation receipt unchanged", arguments: [false, true])
    func cancelledBeforeEntry(clear: Bool) async throws {
        let fixture = try SelectionSQLiteFixture()
        defer { fixture.remove() }
        let store = try await fixture.provision()
        let before = try await store.selectionTestReceipt()
        let target = clear ? nil : fixture.secondConversation.id
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.setSelectedConversationID(target)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.selectionTestReceipt() == before)
        #expect(try await fixture.open().selectedConversationID() == fixture.firstConversation.id)
    }

    @Test("Cancellation observed during the SQL update rolls back select and clear before commit", arguments: [false, true])
    func cancelledDuringUpdate(clear: Bool) async throws {
        let fixture = try SelectionSQLiteFixture()
        defer { fixture.remove() }
        let store = try await fixture.provision()
        let before = try await store.selectionTestReceipt()
        let target = clear ? nil : fixture.secondConversation.id
        // The test-only C hook runs synchronously during this connection's
        // UPDATE, after actor entry but before transaction-body completion.
        await store.installSelectionTestCancellationHook()
        let task = Task { try await store.setSelectedConversationID(target) }
        await #expect(throws: CancellationError.self) { try await task.value }
        await store.removeSelectionTestCancellationHook()
        #expect(task.isCancelled)
        #expect(try await store.selectionTestReceipt() == before)
        #expect(try await store.integrityCheck())
        let reopened = try fixture.open()
        #expect(try await reopened.selectionTestReceipt() == before)
    }

    @Test("Uncancelled selection and clear still commit and survive reopening")
    func committedChangesSurviveReopen() async throws {
        let fixture = try SelectionSQLiteFixture()
        defer { fixture.remove() }
        let store = try await fixture.provision()
        try await store.setSelectedConversationID(fixture.secondConversation.id)
        let reopened = try fixture.open()
        #expect(try await reopened.selectedConversationID() == fixture.secondConversation.id)
        try await reopened.setSelectedConversationID(nil)
        #expect(try await store.selectedConversationID() == nil)
        #expect(try await fixture.open().selectedConversationID() == nil)
        #expect(try await store.integrityCheck())
    }
}

private struct SelectionCommitReceipt: Equatable, Sendable {
    let selectedID: String?
    let updatedAt: Double
}

private typealias SelectionUpdateHook = @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int64
) -> Void

@_silgen_name("sqlite3_update_hook")
private func selectionTestSQLiteUpdateHook(
    _ database: OpaquePointer?, _ callback: SelectionUpdateHook?, _ context: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?

private extension SQLiteStore {
    func selectionTestReceipt() throws -> SelectionCommitReceipt {
        guard let row = try query(sql: "SELECT selected_conversation_id,updated_at FROM chat_navigation_state WHERE singleton_id=1;").first else {
            throw RepositoryError.unavailable(reason: "Missing selection test receipt")
        }
        return try SelectionCommitReceipt(
            selectedID: row.optionalText("selected_conversation_id"), updatedAt: row.real("updated_at")
        )
    }

    func installSelectionTestCancellationHook() {
        _ = selectionTestSQLiteUpdateHook(connectionBox.pointer, { _, _, _, tableName, _ in
            guard let tableName, String(cString: tableName) == "chat_navigation_state" else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        }, nil)
    }

    func removeSelectionTestCancellationHook() {
        _ = selectionTestSQLiteUpdateHook(connectionBox.pointer, nil, nil)
    }
}

private struct SelectionSQLiteFixture {
    let directory: URL
    let configuration: SQLiteStoreConfiguration
    let firstTeammate: Teammate
    let secondTeammate: Teammate
    let firstConversation: Conversation
    let secondConversation: Conversation

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openbots-selection-cancellation-\(UUID().uuidString).noindex", isDirectory: true
        )
        let receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        configuration = try SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("selection.sqlite"), protection: .ordinarySQLite(decision: receipt)
        )
        firstTeammate = try Self.teammate(name: "Ada")
        secondTeammate = try Self.teammate(name: "Lin")
        firstConversation = try Self.conversation(teammate: firstTeammate)
        secondConversation = try Self.conversation(teammate: secondTeammate)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    func open() throws -> SQLiteStore { try SQLiteStore(configuration: configuration) }

    func provision() async throws -> SQLiteStore {
        let store = try open()
        try await store.provisionDirectChat(
            teammate: firstTeammate, conversation: firstConversation, fixtureGreeting: nil, selectConversation: true
        )
        try await store.provisionDirectChat(
            teammate: secondTeammate, conversation: secondConversation, fixtureGreeting: nil, selectConversation: false
        )
        return store
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func teammate(name: String) throws -> Teammate {
        let now = Date(timeIntervalSince1970: 1_000)
        return try Teammate(
            id: TeammateID(UUID()), profile: TeammateProfile(displayName: name, role: "Research partner"),
            appearance: AgentAppearance(
                mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                paletteToken: "sky", eyeDialect: "round", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature with one crest"
            ), createdAt: now, updatedAt: now
        )
    }

    private static func conversation(teammate: Teammate) throws -> Conversation {
        try Conversation(
            id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id), title: teammate.profile.displayName,
            createdAt: teammate.createdAt, updatedAt: teammate.updatedAt
        )
    }
}
