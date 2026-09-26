import Foundation
import OpenBotsDomain
@testable import OpenBotsServices
import Testing

private actor HandoffRepositoryFake: HandoffRepository {
    var records: [HandoffID: HandoffRecord] = [:]
    var updates: [(HandoffID, HandoffState)] = []
    func insert(_ record: HandoffRecord) async throws { records[record.id] = record }
    func update(_ record: HandoffRecord, expectedState: HandoffState) async throws {
        guard records[record.id]?.state == expectedState else { throw RepositoryError.optimisticLockFailed(entity: "handoff", id: record.id.persistedValue) }
        records[record.id] = record; updates.append((record.id, record.state))
    }
    func record(id: HandoffID) async throws -> HandoffRecord? { records[id] }
    func records(conversationID: ConversationID) async throws -> [HandoffRecord] {
        records.values.filter { $0.conversationID == conversationID }.sorted { $0.handoff.provenance.createdAt > $1.handoff.provenance.createdAt }
    }
}

private struct HandoffFixedClock: OpenBotsClock {
    private let instant: Date
    init(now: Date) { instant = now }
    func now() -> Date { instant }
}

@Suite("Handoff service")
struct HandoffServiceTests {
    let date = Date(timeIntervalSince1970: 6_000)
    func record(conversation: ConversationID) throws -> HandoffRecord {
        HandoffRecord(handoff: try Handoff(provenance: HandoffProvenance(handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()),
                originConversationID: conversation, senderID: TeammateID(UUID()), receiverID: TeammateID(UUID()), createdAt: date),
            brief: HandoffBrief(goal: "Goal", constraints: [], inputReferences: [], requestedOutput: "Out", exclusions: [], stopOrApprovalBoundary: "Stop")),
            sourceMessageID: nil)
    }

    @Test("Records are listed per conversation and a staged handoff can be declined once")
    func listAndDecline() async throws {
        let repository = HandoffRepositoryFake()
        let conversation = ConversationID(UUID())
        let staged = try record(conversation: conversation)
        try await repository.insert(staged)
        try await repository.insert(try record(conversation: ConversationID(UUID())))
        let clock = HandoffFixedClock(now: date.addingTimeInterval(9))
        let service = HandoffService(repository: repository, clock: clock)
        #expect(try await service.records(conversationID: conversation).map(\.id) == [staged.id])
        let declined = try await service.decline(id: staged.id)
        #expect(declined.state == .needsRecovery && declined.handoff.recovery?.code == "declined")
        #expect(declined.handoff.recovery?.userMessage == "Not sent. The lead can hand this off again.")
        #expect(declined.handoff.lastTransitionAt == date.addingTimeInterval(9))
        await #expect(throws: HandoffServiceError.notDeclinable(.needsRecovery)) { _ = try await service.decline(id: staged.id) }
        await #expect(throws: HandoffServiceError.unknownHandoff) { _ = try await service.decline(id: HandoffID(UUID())) }
    }

    @Test("An accepted handoff is still the user's to decline; one already working is not")
    func declineAfterTheAccept() async throws {
        let repository = HandoffRepositoryFake()
        let conversation = ConversationID(UUID())
        var accepted = try record(conversation: conversation)
        try accepted.apply(.accept(at: date.addingTimeInterval(1)))
        try await repository.insert(accepted)
        var working = try record(conversation: conversation)
        try working.apply(.accept(at: date.addingTimeInterval(1)))
        try working.apply(.beginWork(at: date.addingTimeInterval(2)))
        try await repository.insert(working)
        let service = HandoffService(repository: repository, clock: HandoffFixedClock(now: date.addingTimeInterval(9)))
        // A send turned away between the accept and the durable turn leaves the
        // record here, and "Not now" is the only thing that can still move it.
        let declined = try await service.decline(id: accepted.id)
        #expect(declined.state == .needsRecovery && declined.handoff.recovery?.code == "declined")
        #expect(declined.handoff.recovery?.userMessage == "Not sent. The lead can hand this off again.")
        #expect(try await repository.record(id: accepted.id)?.state == .needsRecovery)
        // A leg whose turn exists belongs to that run, not to this button.
        await #expect(throws: HandoffServiceError.notDeclinable(.working)) { _ = try await service.decline(id: working.id) }
    }
}
