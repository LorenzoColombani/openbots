import Combine
import Foundation
import OpenBotsDomain

/// Durable review-only presentation. A recorded decision is not a capability
/// and this model has no executor or action-consumption path.
@MainActor
public final class ActionProposalWorkspaceModel: ObservableObject {
    public enum LoadState: Equatable { case idle, loading, ready, failed }
    public static let disclosure = "Local proposal demo — decisions are saved, nothing is executed"

    @Published public private(set) var conversationID: UUID?
    @Published public private(set) var teammateName = ""
    @Published public var selectedAction = ConsequentialActionKind.send
    @Published public private(set) var records: [ActionProposalRecord] = []
    @Published public private(set) var selectedReviewID: ApprovalID?
    @Published public private(set) var loadState = LoadState.idle
    @Published public private(set) var isBusy = false
    @Published public private(set) var needsRefresh = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    private let service: any ActionProposalFixtureServing
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var inFlight: [UUID: UUID] = [:]
    public private(set) var isShuttingDown = false
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        generation &+= 1
    }

    public init(service: any ActionProposalFixtureServing, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }
    public var selectedReview: ActionProposalRecord? { records.first { $0.id == selectedReviewID } }
    public var canRefresh: Bool { !isShuttingDown && conversationID != nil && !isBusy }
    public var canPrepare: Bool { !isShuttingDown && conversationID != nil && loadState == .ready && !isBusy && !needsRefresh }

    public func activateConversation(_ id: UUID?, teammateName: String = "") {
        guard !isShuttingDown else { return }
        guard conversationID != id else { self.teammateName = teammateName; return }
        generation &+= 1
        conversationID = id
        self.teammateName = teammateName
        records = []
        selectedReviewID = nil
        selectedAction = .send
        loadState = .idle
        needsRefresh = false
        isBusy = id.map { inFlight[$0] != nil } ?? false
        errorMessage = nil
        statusMessage = isBusy ? "A submitted local decision is still finishing. Refresh afterward to inspect saved history." : nil
    }

    public func selectReview(_ id: ApprovalID) {
        guard !isShuttingDown, !isBusy, records.contains(where: { $0.id == id }) else { return }
        selectedReviewID = id
    }

    public func load() async {
        guard let conversationID, let operation = begin(conversationID) else { return }
        let request = generation
        loadState = .loading
        errorMessage = nil
        statusMessage = nil
        do {
            let loaded = try await service.proposals(conversationID: ConversationID(conversationID))
            guard current(conversationID, request) else { finish(conversationID, operation, stale: true); return }
            try validate(loaded, conversationID: conversationID)
            records = ordered(loaded)
            if !records.contains(where: { $0.id == selectedReviewID }) { selectedReviewID = records.first?.id }
            loadState = .ready
            needsRefresh = false
        } catch {
            guard current(conversationID, request) else { finish(conversationID, operation, stale: true); return }
            loadState = .failed
            needsRefresh = true
            errorMessage = "OpenBots couldn’t load the saved proposals for this conversation. Try Refresh."
        }
        finish(conversationID, operation)
    }

    public func prepareDemoProposal() async {
        guard canPrepare, let conversationID else { return }
        let action = selectedAction
        let service = service
        await mutate(conversationID, selectsResult: true, success: "Demo proposal saved for review. Nothing was executed.") {
            let result = try await service.prepare(conversationID: ConversationID(conversationID), action: action)
            guard result.proposal.action == action, result.state == .pending else { throw ActionProposalError.invalid }
            return result
        }
    }

    public func isExpired(_ review: ActionProposalRecord) -> Bool { now() >= review.proposal.expiresAt }

    public func canDecide(_ review: ActionProposalRecord, decision: ActionProposalDecision = .approve) -> Bool {
        guard canPrepare, matchesVisible(review) else { return false }
        switch (review.state, decision) {
        case (.pending, .approve): return !isExpired(review)
        case (.pending, .deny), (.pending, .cancel), (.approved, .cancel): return true
        case (.pending, .expire), (.approved, .expire): return isExpired(review)
        default: return false
        }
    }

    public func decide(_ review: ActionProposalRecord, decision: ActionProposalDecision) async {
        guard canPrepare, let conversationID, review.proposal.conversationID.rawValue == conversationID else { return }
        guard matchesVisible(review) else {
            needsRefresh = true
            errorMessage = Self.failure(ActionProposalError.staleReview)
            return
        }
        guard canDecide(review, decision: decision) else {
            needsRefresh = true
            errorMessage = Self.failure(isExpired(review) ? ActionProposalError.expired : ActionProposalError.invalidTransition)
            return
        }
        let service = service
        await mutate(conversationID, selectsResult: false, success: "Local demo decision saved. Nothing was executed and no capability was granted.") {
            let result = try await service.decide(review, decision: decision)
            guard result.id == review.id, result.fingerprint == review.fingerprint,
                  try result.proposal.canonicalData() == review.proposal.canonicalData(),
                  result.revision == review.revision + 1,
                  result.state == Self.resultState(decision) else { throw ActionProposalError.invalid }
            return result
        }
    }

    private func mutate(_ conversationID: UUID, selectsResult: Bool, success: String,
                        operation: @escaping @MainActor () async throws -> ActionProposalRecord) async {
        guard let token = begin(conversationID) else { return }
        let request = generation
        errorMessage = nil
        statusMessage = nil
        do {
            let record = try await operation()
            guard current(conversationID, request) else { finish(conversationID, token, stale: true); return }
            try validate([record], conversationID: conversationID)
            records = ordered([record] + records.filter { $0.id != record.id })
            if selectsResult { selectedReviewID = record.id }
            statusMessage = success
        } catch {
            guard current(conversationID, request) else { finish(conversationID, token, stale: true); return }
            needsRefresh = true
            errorMessage = Self.failure(error)
        }
        finish(conversationID, token)
    }

    private func matchesVisible(_ review: ActionProposalRecord) -> Bool {
        guard let visible = records.first(where: { $0.id == review.id }), visible == review,
              review.revision > 0, review.revision < Int64.max,
              let supplied = try? review.proposal.canonicalData(),
              let frozen = try? visible.proposal.canonicalData() else { return false }
        return supplied == frozen
    }

    private func validate(_ values: [ActionProposalRecord], conversationID: UUID) throws {
        guard values.count <= 10, Set(values.map(\.id)).count == values.count else { throw ActionProposalError.invalid }
        for value in values {
            try value.proposal.validate()
            guard value.proposal.conversationID.rawValue == conversationID, value.revision > 0,
                  value.updatedAt.timeIntervalSince1970.isFinite, value.updatedAt >= value.proposal.createdAt,
                  try value.fingerprint == value.proposal.fingerprint() else { throw ActionProposalError.invalid }
        }
    }
    private func ordered(_ values: [ActionProposalRecord]) -> [ActionProposalRecord] {
        Array(values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }.prefix(10))
    }
    private func begin(_ id: UUID) -> UUID? {
        guard !isShuttingDown, conversationID == id, inFlight[id] == nil else { return nil }
        let token = UUID()
        inFlight[id] = token
        isBusy = true
        return token
    }
    private func finish(_ id: UUID, _ token: UUID, stale: Bool = false) {
        guard !isShuttingDown else { return }
        guard inFlight[id] == token else { return }
        inFlight[id] = nil
        guard conversationID == id else { return }
        isBusy = false
        if stale {
            needsRefresh = true
            statusMessage = "A submitted local operation finished after navigation. Refresh to inspect saved proposals; switching does not undo a decision."
        }
    }
    private func current(_ id: UUID, _ request: UInt64) -> Bool { conversationID == id && generation == request }
    private static func resultState(_ decision: ActionProposalDecision) -> ActionProposalState {
        switch decision { case .approve: .approved; case .deny: .denied; case .cancel: .cancelled; case .expire: .expired }
    }
    private static func failure(_ error: any Error) -> String {
        switch error {
        case ActionProposalError.expired:
            "This demo review expired. Refresh and prepare a new proposal; nothing was executed."
        case ActionProposalError.staleReview, ActionProposalError.contextChanged:
            "The frozen review or teammate context changed. Refresh and review a new proposal before deciding."
        default:
            "OpenBots couldn’t confirm the local proposal change. Refresh before trying again; a decision may already have been saved. Nothing was executed."
        }
    }
}
