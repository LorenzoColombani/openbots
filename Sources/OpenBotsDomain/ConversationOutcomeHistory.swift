import Foundation

/// An exact caller scope, not a grant. Future runtime dispatch must supply the
/// authorized conversation/teammate; a model never receives SQL or a database.
public struct ConversationOutcomeHistoryRequest: Equatable, Sendable {
    public static let maximumLimit = 50
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let limit: Int

    public init(conversationID: ConversationID, teammateID: TeammateID, limit: Int = 20) throws {
        guard (1...Self.maximumLimit).contains(limit) else { throw ConversationOutcomeHistoryError.invalidLimit }
        self.conversationID = conversationID; self.teammateID = teammateID; self.limit = limit
    }
}

public enum ConversationOutcomeHistoryError: Error, Equatable, Sendable {
    case invalidLimit, invalidRepositoryResponse, unavailable
}

public enum SavedOutcomeReference: Equatable, Hashable, Sendable {
    case run(RunID), proposal(ApprovalID)
}

/// Only outcome facts: no request/envelope JSON, message body, approval payload,
/// file path, profile instructions, lease token or private reasoning.
public enum SavedOutcomeEvent: Equatable, Sendable {
    case run(id: RunID, origin: RunOrigin, state: WorkRunState,
             hasUnconfirmedInput: Bool, hasUnknownInput: Bool)
    case proposal(id: ApprovalID, state: ActionProposalState)

    public var reference: SavedOutcomeReference {
        switch self {
        case let .run(id, _, _, _, _): .run(id)
        case let .proposal(id, _): .proposal(id)
        }
    }
}

public struct SavedOutcomeRecord: Equatable, Sendable {
    public let conversationID: ConversationID
    public let teammateID: TeammateID
    public let updatedAt: Date
    public let event: SavedOutcomeEvent
    public init(conversationID: ConversationID, teammateID: TeammateID, updatedAt: Date, event: SavedOutcomeEvent) {
        self.conversationID = conversationID; self.teammateID = teammateID
        self.updatedAt = updatedAt; self.event = event
    }
}

/// Unavailable intentionally does not distinguish missing, hidden, archived or
/// foreign scope. Available + empty means no saved outcome within this scope.
public enum SavedOutcomeScopeStatus: Equatable, Sendable { case available, unavailable }

public struct ConversationOutcomeHistoryPage: Equatable, Sendable {
    public let request: ConversationOutcomeHistoryRequest
    public let scope: SavedOutcomeScopeStatus
    public let records: [SavedOutcomeRecord]
    public let hasMore: Bool
    public init(request: ConversationOutcomeHistoryRequest, scope: SavedOutcomeScopeStatus,
                records: [SavedOutcomeRecord], hasMore: Bool) {
        self.request = request; self.scope = scope; self.records = records; self.hasMore = hasMore
    }
}

/// Read projection only. No recovery, acknowledgement, pruning or selection
/// mutation is implied. Scope visibility must be checked on every query.
public protocol ConversationOutcomeHistoryRepository: Sendable {
    func outcomeHistory(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistoryPage
}

public struct SavedOutcomeSummary: Equatable, Sendable {
    public let reference: SavedOutcomeReference
    public let recordedAt: Date
    public let text: String
    public init(reference: SavedOutcomeReference, recordedAt: Date, text: String) {
        self.reference = reference; self.recordedAt = recordedAt; self.text = text
    }
}

public struct ConversationOutcomeHistorySummary: Equatable, Sendable {
    public let scope: SavedOutcomeScopeStatus
    public let outcomes: [SavedOutcomeSummary]
    public let hasMore: Bool
    public let notice: String
    public init(scope: SavedOutcomeScopeStatus, outcomes: [SavedOutcomeSummary], hasMore: Bool, notice: String) {
        self.scope = scope; self.outcomes = outcomes; self.hasMore = hasMore; self.notice = notice
    }
}
