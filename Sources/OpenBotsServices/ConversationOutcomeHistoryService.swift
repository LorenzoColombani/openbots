import Foundation
import OpenBotsDomain

public protocol ConversationOutcomeHistoryServing: Sendable {
    func history(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistorySummary
}

/// Bounded, read-only saved facts. Construction does not query the repository;
/// every request resolves its exact scope freshly, without a transcript cache,
/// recovery action, acknowledgment, executor or external authority.
public actor ConversationOutcomeHistoryService: ConversationOutcomeHistoryServing {
    private let repository: any ConversationOutcomeHistoryRepository

    public init(repository: any ConversationOutcomeHistoryRepository) {
        self.repository = repository
    }

    public func history(_ request: ConversationOutcomeHistoryRequest) async throws -> ConversationOutcomeHistorySummary {
        try Task.checkCancellation()
        let page: ConversationOutcomeHistoryPage
        do {
            page = try await repository.outcomeHistory(request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Repository diagnostics may contain SQL, paths or private data.
            // None of that crosses this human-facing read boundary.
            throw ConversationOutcomeHistoryError.unavailable
        }
        try Task.checkCancellation()
        try validate(page, request: request)
        let outcomes = page.records.map {
            SavedOutcomeSummary(reference: $0.event.reference, recordedAt: $0.updatedAt, text: summary($0.event))
        }
        let notice: String
        switch page.scope {
        case .unavailable:
            notice = "Saved outcomes are unavailable for this conversation."
        case .available where outcomes.isEmpty:
            notice = "No saved outcomes were found for this conversation."
        case .available where page.hasMore:
            notice = "Showing only the most recent \(outcomes.count) saved outcomes. Earlier records are not included."
        case .available:
            notice = "These are saved records, not a live check of completed work."
        }
        try Task.checkCancellation()
        return ConversationOutcomeHistorySummary(scope: page.scope, outcomes: outcomes,
                                                  hasMore: page.hasMore, notice: notice)
    }

    private func validate(_ page: ConversationOutcomeHistoryPage, request: ConversationOutcomeHistoryRequest) throws {
        guard page.request == request, page.records.count <= request.limit,
              !page.hasMore || page.records.count == request.limit,
              page.scope != .unavailable || (page.records.isEmpty && !page.hasMore) else {
            throw ConversationOutcomeHistoryError.invalidRepositoryResponse
        }
        var references = Set<SavedOutcomeReference>()
        var previous: SavedOutcomeRecord?
        for record in page.records {
            guard record.conversationID == request.conversationID, record.teammateID == request.teammateID,
                  record.updatedAt.timeIntervalSince1970.isFinite,
                  references.insert(record.event.reference).inserted,
                  previous.map({ isOrdered($0, before: record) }) ?? true else {
                throw ConversationOutcomeHistoryError.invalidRepositoryResponse
            }
            previous = record
        }
    }

    private func isOrdered(_ first: SavedOutcomeRecord, before second: SavedOutcomeRecord) -> Bool {
        let lhsDate = first.updatedAt.timeIntervalSince1970, rhsDate = second.updatedAt.timeIntervalSince1970
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        let lhs = orderingKey(first.event.reference), rhs = orderingKey(second.event.reference)
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id < rhs.id
    }

    private func orderingKey(_ reference: SavedOutcomeReference) -> (kind: Int, id: String) {
        switch reference {
        case .run(let id): (0, id.persistedValue)
        case .proposal(let id): (1, id.persistedValue)
        }
    }

    private func summary(_ event: SavedOutcomeEvent) -> String {
        switch event {
        case let .run(_, origin, state, unconfirmed, unknown):
            var text = runSummary(origin: origin, state: state)
            if unconfirmed {
                text += " Some input has no confirmed acknowledgment; its receipt is not proven."
            }
            if unknown {
                text += " The outcome of some input is unknown."
            }
            if unconfirmed || unknown {
                text += " Nothing will be replayed automatically."
            }
            return text
        case let .proposal(_, state):
            let decision: String
            switch state {
            case .pending: decision = "A demo action was waiting for your review."
            case .approved: decision = "Your approval was recorded for a demo action."
            case .denied: decision = "A demo action was not approved."
            case .cancelled: decision = "A demo action review was cancelled."
            case .expired: decision = "A demo action review expired."
            }
            return decision + " This recorded review did not grant access or execute the action."
        }
    }

    private func runSummary(origin: RunOrigin, state: WorkRunState) -> String {
        let status: String
        switch origin {
        case .localFixture:
            switch state {
            case .queued: status = "A local demo was saved but had not started."
            case .starting: status = "A local demo was preparing to start."
            case .running: status = "A local demo was in progress."
            case .waitingForUser: status = "A local demo was waiting for your input."
            case .stopping: status = "A local demo was being stopped."
            case .succeeded: status = "A local demo was marked complete."
            case .failed: status = "A local demo could not finish."
            case .interrupted: status = "A local demo was interrupted."
            }
            return status + " This was a demonstration, not real teammate work."
        case .executor:
            switch state {
            case .queued: status = "Work was recorded as waiting to start."
            case .starting: status = "Work was recorded as preparing to start."
            case .running: status = "Work was recorded as in progress."
            case .waitingForUser: status = "Work was recorded as waiting for your input."
            case .stopping: status = "Work was recorded as being stopped."
            case .succeeded: status = "Work was recorded as complete."
            case .failed: status = "Work was recorded as unable to finish."
            case .interrupted: status = "Work was recorded as interrupted."
            }
            return status + " This saved status is not an independent check of the result."
        }
    }
}
