import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// Conversation-scoped presentation for an explicit durable local demo. This
/// model has no executor, timer, credential, or filesystem capability.
@MainActor
public final class RunRecoveryWorkspaceModel: ObservableObject {
    public enum LoadState: Equatable { case idle, loading, ready, failed }

    public static let disclosure = "Local recovery demo — no Claude or tools run"
    public static let maximumVisibleRuns = 5

    @Published public private(set) var conversationID: UUID?
    @Published public private(set) var reviews: [RunRecoveryReview] = []
    @Published public private(set) var loadState = LoadState.idle
    @Published public private(set) var isBusy = false
    @Published public private(set) var needsRefresh = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    private let service: any RunRecoveryFixtureServing
    private var generation: UInt64 = 0
    private var inFlight: [UUID: UUID] = [:]
    public private(set) var isShuttingDown = false

    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        generation &+= 1
        service.beginShutdown()
    }
    public func flushForShutdown() async -> Bool { await service.flushForShutdown() }
    public func finishShutdown() { beginShutdown(); service.finishShutdown() }

    public init(service: any RunRecoveryFixtureServing) { self.service = service }

    public var visibleReviews: [RunRecoveryReview] { Array(reviews.prefix(Self.maximumVisibleRuns)) }
    public var canRefresh: Bool { !isShuttingDown && conversationID != nil && !isBusy }
    public var canMutate: Bool { !isShuttingDown && conversationID != nil && loadState == .ready && !isBusy && !needsRefresh }
    public var canStartDemo: Bool {
        canMutate && !reviews.contains { Self.isActive($0.record.state) }
    }

    public func activateConversation(_ id: UUID?) {
        guard !isShuttingDown else { return }
        guard conversationID != id else { return }
        generation &+= 1
        conversationID = id
        reviews = []
        loadState = .idle
        isBusy = id.map { inFlight[$0] != nil } ?? false
        needsRefresh = false
        errorMessage = nil
        statusMessage = isBusy ? "A local demo action is still finishing. Refresh afterward to see its saved history." : nil
    }

    public func load() async {
        guard let conversationID, let operation = beginOperation(conversationID) else { return }
        let request = generation
        loadState = .loading
        errorMessage = nil
        statusMessage = nil
        do {
            let loaded = try await service.reviews(conversationID: ConversationID(conversationID))
            guard isCurrent(conversationID, request) else { finishOperation(conversationID, operation, stale: true); return }
            guard Self.isValid(loaded, conversationID: conversationID) else { throw PresentationError.invalidReceipt }
            reviews = Self.ordered(loaded)
            loadState = .ready
            needsRefresh = false
        } catch {
            guard isCurrent(conversationID, request) else { finishOperation(conversationID, operation, stale: true); return }
            loadState = .failed
            needsRefresh = true
            errorMessage = "OpenBots couldn’t load this conversation’s local run history. Try Refresh."
        }
        finishOperation(conversationID, operation)
    }

    public func startDemo() async {
        guard canStartDemo, let conversationID else { return }
        let service = service
        await perform(conversationID: conversationID, success: "Local demo started using a saved user message.") {
            [try await service.startDemo(conversationID: ConversationID(conversationID))]
        }
    }

    public func canAcknowledge(_ review: RunRecoveryReview) -> Bool {
        canChange(review) && [.running, .waitingForUser].contains(review.record.state)
            && review.inputs.contains {
                $0.messageID == review.record.request.initiatingMessageID && $0.sequence == 1 && $0.state == .submitted
            }
    }

    public func canFinish(_ review: RunRecoveryReview) -> Bool {
        canChange(review) && [.running, .waitingForUser].contains(review.record.state)
            && review.inputs.contains {
                $0.messageID == review.record.request.initiatingMessageID && $0.sequence == 1 && $0.state == .acknowledged
            }
    }

    public func canInterrupt(_ review: RunRecoveryReview) -> Bool {
        canChange(review) && [.starting, .running, .waitingForUser, .stopping].contains(review.record.state)
    }

    public func canRequestStop(_ review: RunRecoveryReview) -> Bool {
        canChange(review) && [.running, .waitingForUser].contains(review.record.state)
    }

    public func canFail(_ review: RunRecoveryReview) -> Bool {
        canChange(review) && (Self.isActive(review.record.state))
            && (review.record.state != .queued || review.record.lease == nil)
    }

    public func acknowledgeDemo(runID: UUID, expectedRevision: Int64? = nil) async {
        guard let review = review(runID), matchesExpectedRevision(review, expectedRevision), canAcknowledge(review) else { return }
        let service = service
        await change(review, success: "Demo acknowledgement recorded locally.") {
            try await service.acknowledgeDemo(runID: review.id, expectedRevision: review.record.revision)
        }
    }

    public func finishDemo(runID: UUID, expectedRevision: Int64? = nil) async {
        guard let review = review(runID), matchesExpectedRevision(review, expectedRevision), canFinish(review) else { return }
        let service = service
        await change(review, success: "Local demo marked finished. No real work was executed.") {
            try await service.finishDemo(runID: review.id, expectedRevision: review.record.revision)
        }
    }

    public func interruptDemo(runID: UUID, expectedRevision: Int64? = nil) async {
        guard let review = review(runID), matchesExpectedRevision(review, expectedRevision), canInterrupt(review) else { return }
        let service = service
        await change(review, success: "Local demo marked interrupted. Submitted inputs are not automatically retried.") {
            try await service.interruptDemo(runID: review.id, expectedRevision: review.record.revision)
        }
    }

    public func requestStopDemo(runID: UUID, expectedRevision: Int64? = nil) async {
        guard let review = review(runID), matchesExpectedRevision(review, expectedRevision), canRequestStop(review) else { return }
        let service = service
        await change(review, success: "The demo stop request was saved. No real process was running.") {
            try await service.requestStopDemo(runID: review.id, expectedRevision: review.record.revision)
        }
    }

    public func failDemo(runID: UUID, expectedRevision: Int64? = nil) async {
        guard let review = review(runID), matchesExpectedRevision(review, expectedRevision), canFail(review) else { return }
        let service = service
        await change(review, success: "Local demo marked failed. No real process was stopped and no input was resent.") {
            try await service.failDemo(runID: review.id, expectedRevision: review.record.revision)
        }
    }

    public func recoverExpiredDemos() async {
        guard canMutate, let conversationID else { return }
        let service = service
        await perform(conversationID: conversationID, success: "Expired local demos reviewed. No process was restarted and no input was resent.") {
            try await service.recoverExpiredDemos(conversationID: ConversationID(conversationID))
        }
    }

    private func change(_ review: RunRecoveryReview, success: String,
                        mutation: @escaping @MainActor () async throws -> RunRecoveryReview) async {
        await perform(conversationID: review.record.request.conversationID.rawValue, success: success) {
            let updated = try await mutation()
            guard updated.id == review.id, updated.record.revision > review.record.revision else {
                throw PresentationError.invalidReceipt
            }
            return [updated]
        }
    }

    private func perform(conversationID: UUID, success: String,
                         mutation: @escaping @MainActor () async throws -> [RunRecoveryReview]) async {
        guard let operation = beginOperation(conversationID) else { return }
        let request = generation
        errorMessage = nil
        statusMessage = nil
        do {
            let updated = try await mutation()
            guard isCurrent(conversationID, request) else { finishOperation(conversationID, operation, stale: true); return }
            guard Self.isValid(updated, conversationID: conversationID), updated.allSatisfy({ $0.record.origin == .localFixture }) else {
                throw PresentationError.invalidReceipt
            }
            let changedIDs = Set(updated.map(\.id))
            reviews = Self.ordered(updated + reviews.filter { !changedIDs.contains($0.id) })
            statusMessage = success
        } catch {
            guard isCurrent(conversationID, request) else { finishOperation(conversationID, operation, stale: true); return }
            needsRefresh = true
            errorMessage = Self.actionFailure(error)
        }
        finishOperation(conversationID, operation)
    }

    private func review(_ id: UUID) -> RunRecoveryReview? { reviews.first { $0.id.rawValue == id } }
    private func matchesExpectedRevision(_ review: RunRecoveryReview, _ expected: Int64?) -> Bool {
        expected == nil || review.record.revision == expected
    }
    private func canChange(_ review: RunRecoveryReview) -> Bool {
        canMutate && review.record.origin == .localFixture
            && review.record.request.conversationID.rawValue == conversationID
            && self.review(review.id.rawValue)?.record.revision == review.record.revision
    }

    private func beginOperation(_ id: UUID) -> UUID? {
        guard !isShuttingDown, conversationID == id, inFlight[id] == nil else { return nil }
        let operation = UUID()
        inFlight[id] = operation
        isBusy = true
        return operation
    }

    private func finishOperation(_ id: UUID, _ operation: UUID, stale: Bool = false) {
        guard !isShuttingDown else { return }
        guard inFlight[id] == operation else { return }
        inFlight[id] = nil
        guard conversationID == id else { return }
        isBusy = false
        if stale {
            needsRefresh = true
            statusMessage = "An earlier local history operation finished after navigation. Refresh to see the saved state. Switching conversations does not undo a submitted demo action."
        }
    }

    private func isCurrent(_ id: UUID, _ request: UInt64) -> Bool { conversationID == id && generation == request }

    private static func isActive(_ state: WorkRunState) -> Bool {
        [.queued, .starting, .running, .waitingForUser, .stopping].contains(state)
    }

    private static func ordered(_ reviews: [RunRecoveryReview]) -> [RunRecoveryReview] {
        Array(reviews.sorted {
            if $0.record.updatedAt != $1.record.updatedAt { return $0.record.updatedAt > $1.record.updatedAt }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }.prefix(RunRecoveryFixtureService.reviewLimit))
    }

    private static func isValid(_ reviews: [RunRecoveryReview], conversationID: UUID) -> Bool {
        reviews.count <= RunRecoveryFixtureService.reviewLimit && Set(reviews.map(\.id)).count == reviews.count && reviews.allSatisfy { review in
            review.record.request.conversationID.rawValue == conversationID
                && review.record.origin == .localFixture
                && review.record.revision > 0 && review.record.updatedAt.timeIntervalSince1970.isFinite
                && review.inputs.count <= RunRecoveryFixtureService.inputLimit
                && review.entries.count <= RunRecoveryFixtureService.entryLimit
                && Set(review.inputs.map(\.id)).count == review.inputs.count
                && Set(review.inputs.map(\.sequence)).count == review.inputs.count
                && Set(review.entries.map(\.id)).count == review.entries.count
                && review.inputs.allSatisfy { $0.runID == review.id && $0.sequence > 0 }
                && review.entries.allSatisfy { $0.runID == review.id && $0.sequence > 0 }
                && review.inputs.allSatisfy { $0.updatedAt.timeIntervalSince1970.isFinite }
                && review.entries.allSatisfy { $0.recordedAt.timeIntervalSince1970.isFinite }
        }
    }

    private static func actionFailure(_ error: any Error) -> String {
        switch error {
        case RunRecoveryFixtureError.needUserMessage, RunJournalError.inputUnavailable:
            "Send a user message in this conversation first, then Refresh before starting the local demo."
        case RunRecoveryFixtureError.partialStart:
            "Part of the demo was saved before setup stopped. Refresh to see what is available and the next step. Nothing will be resent automatically."
        case RunRecoveryFixtureError.wrongOwner:
            "This demo belongs to an earlier time you opened OpenBots. Refresh, then choose Recover Expired Demos when its time window has ended."
        case RunJournalError.staleRevision:
            "This run changed since it was shown. Refresh its history before choosing another demo action."
        case RunJournalError.conflictingActiveRun:
            "This conversation already has an active run. Refresh to see its current state."
        case RunJournalError.leaseExpired, RunJournalError.leaseUnavailable:
            "This demo can no longer be updated by the current session. Refresh, then choose Recover Expired Demos when its time window has ended."
        default:
            "OpenBots couldn’t confirm the demo change. Refresh before trying again; the change may already have been saved."
        }
    }

    private enum PresentationError: Error { case invalidReceipt }
}
