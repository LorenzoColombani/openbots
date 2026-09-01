import Foundation
import CryptoKit

/// A durable review envelope, not an executable action or capability. This
/// phase accepts local demonstrations only; no executor can consume approval.
public struct ActionProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: ApprovalID
    public let teammateID: TeammateID
    public let conversationID: ConversationID
    public let runID: RunID?
    public let profileRevision: UInt64
    public let contextRevision: UInt64
    public let action: ConsequentialActionKind
    public let target: String
    public let payload: String
    public let consequence: String
    public let createdAt: Date
    public let expiresAt: Date
    public let origin: RunOrigin

    public init(id: ApprovalID, teammateID: TeammateID, conversationID: ConversationID,
                runID: RunID? = nil, profileRevision: UInt64, contextRevision: UInt64,
                action: ConsequentialActionKind, target: String, payload: String, consequence: String,
                createdAt: Date, expiresAt: Date) throws {
        self.id = id; self.teammateID = teammateID; self.conversationID = conversationID
        self.runID = runID; self.profileRevision = profileRevision; self.contextRevision = contextRevision
        self.action = action; self.target = target; self.payload = payload; self.consequence = consequence
        self.createdAt = createdAt; self.expiresAt = expiresAt; origin = .localFixture
        try validate()
    }

    public func validate() throws {
        guard origin == .localFixture, profileRevision > 0, profileRevision <= UInt64(Int64.max),
              contextRevision <= UInt64(Int64.max), createdAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite, expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= 3_600 else { throw ActionProposalError.invalid }
        for (value, maximum) in [(target, 2_000), (payload, 16_384), (consequence, 2_000)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= maximum, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ActionProposalError.invalid
            }
        }
    }

    /// Full, versioned frozen envelope. Do not normalize text or drop context
    /// fields: a changed byte requires a new review, even if it looks similar.
    public func canonicalData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data("openbots-local-proposal-v1\n".utf8)
        data.append(try encoder.encode(self))
        return data
    }

    public func fingerprint() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ActionProposalState: String, Codable, Sendable {
    case pending, approved, denied, cancelled, expired
}
public enum ActionProposalDecision: Sendable { case approve, deny, cancel, expire }
public enum ActionProposalError: Error, Equatable, Sendable {
    case invalid, unavailable, staleReview, expired, contextChanged, invalidTransition, invalidLimit, clockMovedBackwards
}
public struct ActionProposalRecord: Equatable, Sendable, Identifiable {
    public var id: ApprovalID { proposal.id }
    public let proposal: ActionProposal
    public let fingerprint: String
    public let state: ActionProposalState
    public let revision: Int64
    public let updatedAt: Date
    public init(proposal: ActionProposal, fingerprint: String, state: ActionProposalState,
                revision: Int64, updatedAt: Date) {
        self.proposal = proposal; self.fingerprint = fingerprint; self.state = state
        self.revision = revision; self.updatedAt = updatedAt
    }
}
public protocol ActionProposalRepository: Sendable {
    func insertProposal(_ proposal: ActionProposal) async throws -> ActionProposalRecord
    func proposals(conversationID: ConversationID, limit: Int) async throws -> [ActionProposalRecord]
    func decideProposal(_ review: ActionProposalRecord, decision: ActionProposalDecision,
                        now: Date) async throws -> ActionProposalRecord
}
public protocol ActionProposalFixtureServing: Sendable {
    func proposals(conversationID: ConversationID) async throws -> [ActionProposalRecord]
    func prepare(conversationID: ConversationID, action: ConsequentialActionKind) async throws -> ActionProposalRecord
    func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async throws -> ActionProposalRecord
}
