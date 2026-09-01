import Foundation
import OpenBotsDomain

/// Uses the universal action taxonomy, but records LOCAL DEMONSTRATIONS ONLY.
/// Approval never creates a grant, sends a message, or reaches an executor.
public actor ActionProposalFixtureService: ActionProposalFixtureServing {
    public static let limit = 10
    private let repository: any ActionProposalRepository
    private let teammates: any TeammateRepository
    private let contexts: any ConversationContextRepository
    private let clock: any OpenBotsClock
    private let ids: any UUIDGenerator

    public init(repository: any ActionProposalRepository, teammateRepository: any TeammateRepository,
                contextRepository: any ConversationContextRepository,
                clock: any OpenBotsClock = SystemClock(), ids: any UUIDGenerator = SystemUUIDGenerator()) {
        self.repository = repository; teammates = teammateRepository; contexts = contextRepository
        self.clock = clock; self.ids = ids
    }

    public func proposals(conversationID: ConversationID) async throws -> [ActionProposalRecord] {
        try Task.checkCancellation()
        let result = try await repository.proposals(conversationID: conversationID, limit: Self.limit)
        guard result.count <= Self.limit, Set(result.map(\.id)).count == result.count else { throw ActionProposalError.invalid }
        for record in result {
            try validate(record)
            guard record.proposal.conversationID == conversationID else { throw ActionProposalError.invalid }
        }
        try Task.checkCancellation()
        return result
    }

    public func prepare(conversationID: ConversationID, action: ConsequentialActionKind) async throws -> ActionProposalRecord {
        try Task.checkCancellation()
        let context = try await contexts.loadContext(conversationID: conversationID)
        guard context.conversationID == conversationID,
              let teammate = try await teammates.teammate(id: context.teammateID),
              teammate.id == context.teammateID, teammate.lifecycle == .active, !teammate.isHidden else {
            throw ActionProposalError.contextChanged
        }
        let now = try timestamp()
        let proposal = try ActionProposal(
            id: ApprovalID(ids.next()), teammateID: teammate.id, conversationID: conversationID,
            profileRevision: teammate.profile.revision, contextRevision: context.revision, action: action,
            target: "Synthetic \(action.rawValue) target — no real account, file, or destination",
            payload: "Record a local \(action.rawValue) approval demonstration only.",
            consequence: "Only this review decision is saved. No external operation occurs, no permission is granted, and nothing can execute this approval.",
            createdAt: now, expiresAt: now.addingTimeInterval(300)
        )
        try Task.checkCancellation()
        let result = try await repository.insertProposal(proposal)
        try validate(result)
        guard try result.proposal.canonicalData() == proposal.canonicalData(), result.state == .pending,
              result.revision == 1 else { throw ActionProposalError.invalid }
        return result
    }

    public func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async throws -> ActionProposalRecord {
        try validate(review)
        try Task.checkCancellation()
        let now = try timestamp()
        let result = try await repository.decideProposal(review, decision: decision, now: now)
        try validate(result)
        guard review.revision < Int64.max, result.revision == review.revision + 1,
              result.updatedAt >= review.updatedAt, result.updatedAt == now,
              try result.proposal.canonicalData() == review.proposal.canonicalData() else { throw ActionProposalError.invalid }
        let expected: ActionProposalState
        switch decision {
        case .approve: expected = .approved
        case .deny: expected = .denied
        case .cancel: expected = .cancelled
        case .expire: expected = .expired
        }
        guard result.state == expected else { throw ActionProposalError.invalid }
        return result
    }

    private func validate(_ record: ActionProposalRecord) throws {
        try record.proposal.validate()
        guard record.fingerprint == (try record.proposal.fingerprint()), record.revision > 0,
              record.updatedAt.timeIntervalSince1970.isFinite, record.updatedAt >= record.proposal.createdAt,
              (record.state == .pending) == (record.revision == 1) else { throw ActionProposalError.invalid }
    }

    private func timestamp() throws -> Date {
        let value = clock.now().timeIntervalSince1970
        guard value.isFinite else { throw ActionProposalError.invalid }
        // Stable across the JSON/SQLite date representations.
        return Date(timeIntervalSince1970: value.rounded(.down))
    }
}
