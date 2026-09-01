import Foundation

public enum RunOrigin: String, Codable, Equatable, Sendable { case localFixture, executor }
public enum RunInputState: String, Codable, Equatable, Sendable { case queued, submitted, acknowledged, outcomeUnknown }
public enum RunJournalEntryKind: String, Codable, Equatable, Sendable {
    case enqueued, claimed, leaseRenewed, stateChanged, inputQueued, inputSubmitted, inputAcknowledged, recovered
}

public struct RunLease: Equatable, Sendable {
    public let ownerID: UUID
    public let token: UUID
    public let generation: Int64
    public let expiresAt: Date
    public init(ownerID: UUID, token: UUID, generation: Int64, expiresAt: Date) {
        self.ownerID = ownerID; self.token = token; self.generation = generation; self.expiresAt = expiresAt
    }
}

public struct RunJournalRecord: Equatable, Sendable, Identifiable {
    public var id: RunID { request.runID }
    public let request: WorkRequest
    public let origin: RunOrigin
    public let state: WorkRunState
    public let revision: Int64
    public let lease: RunLease?
    public let updatedAt: Date
    public init(request: WorkRequest, origin: RunOrigin, state: WorkRunState,
                revision: Int64, lease: RunLease?, updatedAt: Date) {
        self.request = request; self.origin = origin; self.state = state
        self.revision = revision; self.lease = lease; self.updatedAt = updatedAt
    }
}

public struct RunInputReceipt: Equatable, Sendable, Identifiable {
    public var id: MessageID { messageID }
    public let runID: RunID
    public let messageID: MessageID
    public let sequence: Int64
    public let state: RunInputState
    public let updatedAt: Date
    public init(runID: RunID, messageID: MessageID, sequence: Int64, state: RunInputState, updatedAt: Date) {
        self.runID = runID; self.messageID = messageID; self.sequence = sequence
        self.state = state; self.updatedAt = updatedAt
    }
}

public struct RunJournalEntry: Equatable, Sendable, Identifiable {
    public var id: Int64 { sequence }
    public let runID: RunID
    public let sequence: Int64
    public let kind: RunJournalEntryKind
    public let state: WorkRunState
    public let inputMessageID: MessageID?
    public let recordedAt: Date
    public init(runID: RunID, sequence: Int64, kind: RunJournalEntryKind, state: WorkRunState,
                inputMessageID: MessageID?, recordedAt: Date) {
        self.runID = runID; self.sequence = sequence; self.kind = kind; self.state = state
        self.inputMessageID = inputMessageID; self.recordedAt = recordedAt
    }
}

public enum RunJournalError: Error, Equatable, Sendable {
    case unavailable, invalidRequest, invalidLimit, conflictingActiveRun, staleRevision
    case leaseUnavailable, leaseExpired, invalidLeaseDuration, invalidTransition
    case inputUnavailable, inputMismatch, invalidInputTransition, revisionExhausted, clockMovedBackwards
}

/// State-only authority: no process, credential, filesystem capability, or
/// consequential-action approval is granted by a run, lease or acknowledgement.
public protocol RunJournalRepository: Sendable {
    /// Exact, process-issued local demo IDs only. Never affects executor rows
    /// or a lease now held by another owner, and never dispatches work.
    func interruptOwnedLocalFixtures(ids: [RunID], ownerID: UUID, now: Date) async throws -> [RunJournalRecord]
    func enqueueRun(_ request: WorkRequest, origin: RunOrigin) async throws -> RunJournalRecord
    func run(id: RunID) async throws -> RunJournalRecord?
    func runs(conversationID: ConversationID, limit: Int) async throws -> [RunJournalRecord]
    func claimRun(id: RunID, expectedRevision: Int64, ownerID: UUID, token: UUID,
                  now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord
    func renewRunLease(id: RunID, expectedRevision: Int64, token: UUID,
                       now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord
    func transitionRun(id: RunID, expectedRevision: Int64, token: UUID,
                       event: WorkRunEvent, now: Date) async throws -> RunJournalRecord
    func failUnclaimedLocalFixture(id: RunID, expectedRevision: Int64,
                                  now: Date) async throws -> RunJournalRecord
    func queueRunInput(id: RunID, expectedRevision: Int64, token: UUID,
                       input: SteeringInput, now: Date) async throws -> RunJournalRecord
    func markRunInput(id: RunID, expectedRevision: Int64, token: UUID,
                      messageID: MessageID, sequence: Int64, state: RunInputState,
                      now: Date) async throws -> RunJournalRecord
    func runInputs(id: RunID, limit: Int) async throws -> [RunInputReceipt]
    func runEntries(id: RunID, afterSequence: Int64, limit: Int) async throws -> [RunJournalEntry]
    /// Explicit, bounded fixture recovery only. Production recovery still needs
    /// process-identity/absence proof; expiry alone must never kill/relaunch work.
    func recoverExpiredLocalFixtures(conversationID: ConversationID, now: Date,
                                     limit: Int) async throws -> [RunJournalRecord]
}

public struct RunRecoveryReview: Equatable, Sendable, Identifiable {
    public var id: RunID { record.id }
    public let record: RunJournalRecord
    public let inputs: [RunInputReceipt]
    public let entries: [RunJournalEntry]
    public init(record: RunJournalRecord, inputs: [RunInputReceipt], entries: [RunJournalEntry]) {
        self.record = record; self.inputs = inputs; self.entries = entries
    }
}

/// Explicit local demonstration, separate from the still-disabled executor.
public protocol RunRecoveryFixtureServing: Sendable {
    func beginShutdown()
    func flushForShutdown() async -> Bool
    func finishShutdown()
    func reviews(conversationID: ConversationID) async throws -> [RunRecoveryReview]
    func startDemo(conversationID: ConversationID) async throws -> RunRecoveryReview
    func acknowledgeDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview
    func finishDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview
    func interruptDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview
    func requestStopDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview
    func failDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview
    func recoverExpiredDemos(conversationID: ConversationID) async throws -> [RunRecoveryReview]
}

public extension RunJournalRepository {
    func interruptOwnedLocalFixtures(ids: [RunID], ownerID: UUID, now: Date) async throws -> [RunJournalRecord] {
        throw RunJournalError.unavailable
    }
    func failUnclaimedLocalFixture(id: RunID, expectedRevision: Int64, now: Date) async throws -> RunJournalRecord {
        throw RunJournalError.unavailable
    }
}

public extension RunRecoveryFixtureServing {
    func beginShutdown() {}
    func flushForShutdown() async -> Bool { false }
    func finishShutdown() {}
    func requestStopDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview { throw RunJournalError.unavailable }
    func failDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview { throw RunJournalError.unavailable }
}
