import Foundation

public enum AgenticJobError: Error, Equatable, Sendable {
    case unavailable, invalidState, invalidTransition, staleGeneration, staleRevision, invalidLimit, revisionExhausted
}

public enum AgenticJobWorkerLifecycle: String, Codable, Equatable, Sendable {
    case starting, running, stopping, succeeded, failed, stopped, outcomeUnknown

    public var isTerminal: Bool {
        [.succeeded, .failed, .stopped, .outcomeUnknown].contains(self)
    }

    func permits(_ next: Self) -> Bool {
        if next == self { return true }
        switch self {
        case .starting: return [.running, .stopping, .failed, .stopped, .outcomeUnknown].contains(next)
        case .running: return [.stopping, .succeeded, .failed, .stopped, .outcomeUnknown].contains(next)
        case .stopping: return [.succeeded, .failed, .stopped, .outcomeUnknown].contains(next)
        case .succeeded, .failed, .stopped, .outcomeUnknown: return false
        }
    }
}

/// Historical observations only. A restored PID or session never grants process
/// ownership, permission to signal a group, or permission to resume a worker.
public struct AgenticJobWorker: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let processID: Int32?
    public let processGroupID: Int32?
    public let lifecycle: AgenticJobWorkerLifecycle

    public init(id: UUID, sessionID: UUID, processID: Int32? = nil, processGroupID: Int32? = nil,
                lifecycle: AgenticJobWorkerLifecycle = .starting) {
        self.id = id; self.sessionID = sessionID; self.processID = processID
        self.processGroupID = processGroupID; self.lifecycle = lifecycle
    }
}

/// Reference and digest of completed work recorded by its trusted owner. Reading
/// this metadata does not open a path, verify its bytes or grant file access.
public struct AgenticJobCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let workerID: UUID?
    public let reference: String
    public let sha256: String

    public init(id: UUID, workerID: UUID? = nil, reference: String, sha256: String) {
        self.id = id; self.workerID = workerID; self.reference = reference; self.sha256 = sha256
    }
}

/// One logical run's conversation/worker associations. WorkRunState, the frozen
/// original request and ordered correction receipts remain in the run journal.
/// Neither decoded state nor a persisted approval/PID is execution authority.
public struct AgenticJobState: Codable, Equatable, Sendable {
    public static let maximumWorkers = 8
    public static let maximumCheckpoints = 32
    public let runID: RunID
    public let conversationGeneration: UInt64
    public let sessionID: UUID?
    public let workers: [AgenticJobWorker]
    public let checkpointReferences: [AgenticJobCheckpoint]

    public init(runID: RunID, conversationGeneration: UInt64 = 0, sessionID: UUID? = nil,
                workers: [AgenticJobWorker] = [], checkpointReferences: [AgenticJobCheckpoint] = []) {
        self.runID = runID; self.conversationGeneration = conversationGeneration; self.sessionID = sessionID
        self.workers = workers; self.checkpointReferences = checkpointReferences
    }

    public func validate() throws {
        guard conversationGeneration <= UInt64(Int64.max), (conversationGeneration == 0) == (sessionID == nil),
              conversationGeneration != 0 || (workers.isEmpty && checkpointReferences.isEmpty),
              workers.count <= Self.maximumWorkers, checkpointReferences.count <= Self.maximumCheckpoints,
              Set(workers.map(\.id)).count == workers.count,
              Set(workers.map(\.sessionID)).count == workers.count,
              !workers.contains(where: { $0.sessionID == sessionID }),
              Set(checkpointReferences.map(\.id)).count == checkpointReferences.count else { throw AgenticJobError.invalidState }
        var activeGroups = Set<Int32>()
        for worker in workers {
            guard (worker.processID == nil) == (worker.processGroupID == nil),
                  worker.processID.map({ $0 > 0 }) ?? true,
                  worker.processGroupID.map({ $0 > 0 }) ?? true else { throw AgenticJobError.invalidState }
            if !worker.lifecycle.isTerminal, let group = worker.processGroupID {
                guard activeGroups.insert(group).inserted else { throw AgenticJobError.invalidState }
            }
        }
        for checkpoint in checkpointReferences {
            guard checkpoint.reference.utf8.count <= 1_024,
                  !checkpoint.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !checkpoint.reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  checkpoint.sha256.utf8.count == 64,
                  checkpoint.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  checkpoint.workerID == nil || workers.contains(where: { $0.id == checkpoint.workerID }) else {
                throw AgenticJobError.invalidState
            }
        }
    }

    /// Preserve worker identity/order and completed references across redirects.
    /// A conversation generation may advance only once per stored update.
    public func validateTransition(from previous: Self) throws {
        try validate()
        try previous.validate()
        guard runID == previous.runID else { throw AgenticJobError.invalidState }
        if conversationGeneration == previous.conversationGeneration {
            guard sessionID == previous.sessionID else { throw AgenticJobError.staleGeneration }
        } else {
            guard previous.conversationGeneration < UInt64(Int64.max),
                  conversationGeneration == previous.conversationGeneration + 1,
                  sessionID != nil, sessionID != previous.sessionID else { throw AgenticJobError.staleGeneration }
        }
        guard workers.count >= previous.workers.count,
              checkpointReferences.count >= previous.checkpointReferences.count else { throw AgenticJobError.invalidTransition }
        for (old, new) in zip(previous.workers, workers) {
            guard old.id == new.id, old.sessionID == new.sessionID, old.lifecycle.permits(new.lifecycle),
                  old.processID == nil || old.processID == new.processID,
                  old.processGroupID == nil || old.processGroupID == new.processGroupID else { throw AgenticJobError.invalidTransition }
        }
        for (old, new) in zip(previous.checkpointReferences, checkpointReferences) {
            guard old.id == new.id, old.workerID == new.workerID, old.sha256 == new.sha256,
                  old.reference.utf8.elementsEqual(new.reference.utf8) else { throw AgenticJobError.invalidTransition }
        }
    }
}

public struct AgenticJobRecord: Equatable, Sendable, Identifiable {
    public var id: RunID { journal.id }
    public let journal: RunJournalRecord
    /// Metadata revision, independent of journal.revision and lease renewals.
    public let revision: Int64
    public let state: AgenticJobState
    public let updatedAt: Date
    public init(journal: RunJournalRecord, revision: Int64, state: AgenticJobState, updatedAt: Date) {
        self.journal = journal; self.revision = revision; self.state = state; self.updatedAt = updatedAt
    }
}

public struct AgenticJobUpdate: Equatable, Sendable {
    public let runID: RunID
    public let revision: Int64
    public let state: AgenticJobState
    public let recordedAt: Date
    public init(runID: RunID, revision: Int64, state: AgenticJobState, recordedAt: Date) {
        self.runID = runID; self.revision = revision; self.state = state; self.recordedAt = recordedAt
    }
}

/// Durable state only. Creation atomically enqueues one executor run and its
/// initial metadata. Recovery is read-only; callers must never automatically
/// resume, signal a persisted PID or approve an action from these records.
public protocol AgenticJobRepository: RunJournalRepository {
    func createAgenticJob(request: WorkRequest) async throws -> AgenticJobRecord
    func agenticJob(runID: RunID) async throws -> AgenticJobRecord?
    func agenticJobs(conversationID: ConversationID, limit: Int) async throws -> [AgenticJobRecord]
    func updateAgenticJob(runID: RunID, expectedRevision: Int64, leaseToken: UUID,
                          state: AgenticJobState, now: Date) async throws -> AgenticJobRecord
    func agenticJobUpdates(runID: RunID, afterRevision: Int64, limit: Int) async throws -> [AgenticJobUpdate]
}
