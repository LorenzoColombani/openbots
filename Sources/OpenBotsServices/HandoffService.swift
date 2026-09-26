import Foundation
import OpenBotsDomain

public enum HandoffServiceError: Error, Equatable, Sendable {
    case unknownHandoff
    case notDeclinable(HandoffState)
}

/// Reads and declines handoffs for the workspace. Sending a leg lives on the
/// text reply service because it needs the runtime.
public protocol HandoffServing: Sendable {
    func records(conversationID: ConversationID) async throws -> [HandoffRecord]
    @discardableResult func decline(id: HandoffID) async throws -> HandoffRecord
}

public actor HandoffService: HandoffServing {
    private let repository: any HandoffRepository
    private let clock: any OpenBotsClock

    public init(repository: any HandoffRepository, clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository; self.clock = clock
    }

    public func records(conversationID: ConversationID) async throws -> [HandoffRecord] {
        try await repository.records(conversationID: conversationID)
    }

    /// "Not now" reaches a brief the user has not sent and one whose send was
    /// turned away after the record moved: an accepted leg that never began a
    /// durable turn is still the user's to decline, and nothing else can move
    /// it. A leg already working belongs to its run, not to this.
    @discardableResult
    public func decline(id: HandoffID) async throws -> HandoffRecord {
        guard var record = try await repository.record(id: id) else { throw HandoffServiceError.unknownHandoff }
        let previous = record.state
        guard previous == .staged || previous == .accepted else { throw HandoffServiceError.notDeclinable(previous) }
        try record.apply(.requireRecovery(HandoffRecovery(code: "declined",
            userMessage: "Not sent. The lead can hand this off again.", isRecoverable: false, occurredAt: clock.now())))
        try await repository.update(record, expectedState: previous)
        return record
    }
}
