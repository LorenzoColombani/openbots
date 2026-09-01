import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsServices

@Suite("Saved outcome history integration")
struct ConversationOutcomeHistoryIntegrationTests {
    @Test("Shutdown and approval facts survive reopen and resolve through the read-only human boundary")
    func composedReopenAndVisibility() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextOutcomeIntegration-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        let configuration = try SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection))
        let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
        let request = try ConversationOutcomeHistoryRequest(conversationID: conversationID, teammateID: teammateID)
        let seeded = try await seedAndRead(configuration, request: request)
        #expect(seeded.weakStore.value == nil)
        let reopened = try SQLiteStore(configuration: configuration)
        let reader: any ConversationOutcomeHistoryServing = ConversationOutcomeHistoryService(repository: reopened)
        let after = try await reader.history(request)
        #expect(after == seeded.summary)
        #expect(after.outcomes.count == 2 && !after.hasMore && after.scope == .available)
        let text = after.outcomes.map(\.text).joined(separator: "\n")
        #expect(text.contains("interrupted") && text.contains("unknown"))
        #expect(text.contains("approval") && text.contains("did not grant access or execute"))
        for privateValue in ["PRIVATE-HISTORY-INPUT", teammateID.persistedValue, conversationID.persistedValue] {
            #expect(!text.contains(privateValue))
        }
        let beforeRuns = try await reopened.runs(conversationID: conversationID, limit: 10)
        let beforeProposals = try await reopened.proposals(conversationID: conversationID, limit: 10)
        // A later request must re-resolve visibility; no service cache may
        // replay formerly readable history after the teammate is hidden.
        _ = try await reopened.execute(sql: "UPDATE teammates SET is_hidden=1 WHERE id=?;", bindings: [.text(teammateID.persistedValue)])
        let hidden = try await reader.history(request)
        #expect(hidden.scope == .unavailable && hidden.outcomes.isEmpty && !hidden.hasMore)
        let missingRequest = try ConversationOutcomeHistoryRequest(conversationID: ConversationID(UUID()), teammateID: teammateID)
        let missing = try await reader.history(missingRequest)
        #expect(hidden.notice == missing.notice)
        #expect(try await reopened.runs(conversationID: conversationID, limit: 10) == beforeRuns)
        #expect(try await reopened.proposals(conversationID: conversationID, limit: 10) == beforeProposals)
        #expect(try await reopened.activeGrants(teammateID: teammateID).isEmpty)
    }

    private func seedAndRead(_ configuration: SQLiteStoreConfiguration, request: ConversationOutcomeHistoryRequest) async throws
        -> (summary: ConversationOutcomeHistorySummary, weakStore: WeakOutcomeStore) {
        let store = try SQLiteStore(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_000)
        let teammate = try Teammate(id: request.teammateID, profile: .init(displayName: "Outcome fixture", role: "Research", revision: 1),
            appearance: .init(mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
                paletteToken: "mint", eyeDialect: "round", nonColorIdentityCue: "antenna", accessibleIdentityDescription: "Antenna creature"),
            createdAt: now, updatedAt: now)
        let conversation = try Conversation(id: request.conversationID, kind: .direct(teammateID: teammate.id), createdAt: now, updatedAt: now)
        try await store.provisionDirectChat(teammate: teammate, conversation: conversation, fixtureGreeting: nil, selectConversation: false)
        let message = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user,
            deliveryState: .completed, parts: [.init(id: MessagePartID(UUID()), ordinal: 0, content: .text("PRIVATE-HISTORY-INPUT"))],
            createdAt: now, updatedAt: now)
        try await store.append(message, expectedPreviousSequence: 0)
        let run = RunRecoveryFixtureService(journalRepository: store, teammateRepository: store, conversationRepository: store,
                                           messageRepository: store, contextRepository: store)
        _ = try await run.startDemo(conversationID: conversation.id)
        run.beginShutdown()
        #expect(await run.flushForShutdown())
        run.finishShutdown()
        let proposals = ActionProposalFixtureService(repository: store, teammateRepository: store, contextRepository: store)
        let review = try await proposals.prepare(conversationID: conversation.id, action: .send)
        _ = try await proposals.decide(review, decision: .approve)
        let summary = try await ConversationOutcomeHistoryService(repository: store).history(request)
        return (summary, WeakOutcomeStore(store))
    }
}

private final class WeakOutcomeStore: @unchecked Sendable {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}
