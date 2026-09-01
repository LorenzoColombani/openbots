import Foundation
import OpenBotsDomain

public enum RunRecoveryFixtureError: Error, Equatable, Sendable {
    case conversationUnavailable, teammateUnavailable, needUserMessage
    case invalidRepositoryResponse, wrongOrigin, wrongOwner
    /// Some start steps are already durable. Reload this exact run; starting a
    /// replacement or claiming that the earlier writes rolled back is unsafe.
    case partialStart(runID: RunID)
}

/// Journal-only demonstration. No executor, transport, credentials, capability
/// broker or chat-message writer is invoked by this service.
public actor RunRecoveryFixtureService: RunRecoveryFixtureServing {
    public static let reviewLimit = 10
    public static let inputLimit = 50
    public static let entryLimit = 100
    public static let leaseDuration: TimeInterval = 30

    private let journal: any RunJournalRepository
    private let teammates: any TeammateRepository
    private let conversations: any ConversationRepository
    private let messages: any MessageRepository
    private let contexts: any ConversationContextRepository
    private let ownerID: UUID
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    private nonisolated let shutdown = LocalRunShutdownFence()
    private var activeActions = 0
    private var issuedRunIDs: Set<RunID> = []

    public nonisolated func beginShutdown() { shutdown.begin() }
    public nonisolated func finishShutdown() { shutdown.finish() }

    /// Only mechanical recording for this service instance's local demos.
    /// The app owns the one deadline and cancels this wait at termination.
    public func flushForShutdown() async -> Bool {
        beginShutdown()
        do {
            while activeActions > 0 {
                try Task.checkCancellation()
                guard !shutdown.isFinished else { return false }
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            guard !shutdown.isFinished else { return false }
            _ = try await journal.interruptOwnedLocalFixtures(ids: Array(issuedRunIDs), ownerID: ownerID, now: now())
            return !shutdown.isFinished && !Task.isCancelled
        } catch { return false }
    }

    private func beginAction() throws {
        try checkAdmission()
        activeActions += 1
    }

    private func checkAdmission() throws {
        try Task.checkCancellation()
        guard shutdown.acceptsWork else { throw CancellationError() }
    }

    public init(
        journalRepository: any RunJournalRepository,
        teammateRepository: any TeammateRepository,
        conversationRepository: any ConversationRepository,
        messageRepository: any MessageRepository,
        contextRepository: any ConversationContextRepository,
        ownerID: UUID = UUID(), clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator()
    ) {
        journal = journalRepository; teammates = teammateRepository
        conversations = conversationRepository; messages = messageRepository
        contexts = contextRepository; self.ownerID = ownerID
        self.clock = clock; self.uuidGenerator = uuidGenerator
    }

    public func reviews(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        try checkAdmission()
        let records = try await journal.runs(conversationID: conversationID, limit: Self.reviewLimit)
        try validateList(records, conversationID: conversationID)
        // This is the bounded latest journal page filtered to local demos, not
        // a claim that ten fixture records were found behind executor records.
        var result: [RunRecoveryReview] = []
        for record in records where record.origin == .localFixture {
            result.append(try await review(record))
        }
        try checkAdmission()
        return result
    }

    public func startDemo(conversationID: ConversationID) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        guard issuedRunIDs.count < 256 else { throw RunJournalError.invalidLimit }
        guard let conversation = try await conversations.conversation(id: conversationID),
              conversation.id == conversationID, conversation.lifecycle == .active,
              case let .direct(teammateID) = conversation.kind else {
            throw RunRecoveryFixtureError.conversationUnavailable
        }
        guard let teammate = try await teammates.teammate(id: teammateID),
              teammate.id == teammateID, teammate.lifecycle == .active, !teammate.isHidden,
              teammate.profile.revision <= UInt64(Int64.max) else {
            throw RunRecoveryFixtureError.teammateUnavailable
        }
        let context = try await contexts.loadContext(conversationID: conversationID)
        guard context.conversationID == conversationID, context.teammateID == teammateID,
              context.revision <= UInt64(Int64.max),
              context.revision != 0 || (context.projectID == nil && context.teamID == nil) else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        let page = try await messages.page(conversationID: conversationID, request: PageRequest(limit: 50))
        guard page.elements.count <= 50,
              Set(page.elements.map(\.id)).count == page.elements.count,
              Set(page.elements.map(\.sequence)).count == page.elements.count,
              page.elements.allSatisfy({ $0.conversationID == conversationID && $0.sequence > 0
                  && $0.createdAt.timeIntervalSince1970.isFinite && $0.updatedAt.timeIntervalSince1970.isFinite }) else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        guard let message = page.elements.filter({ $0.author == .user && $0.outputClass == .conversation })
            .max(by: { $0.sequence < $1.sequence }) else { throw RunRecoveryFixtureError.needUserMessage }
        let input = try initialInput(message)
        try checkAdmission()
        let request = try WorkRequest(
            runID: RunID(uuidGenerator.next()), teammateID: teammateID, conversationID: conversationID,
            initiatingMessageID: message.id, selectedProjectID: context.projectID,
            profileRevision: teammate.profile.revision, initialInput: input, submittedAt: now()
        )
        try checkAdmission()
        let enqueued = try await journal.enqueueRun(request, origin: .localFixture)
        // From here onward a failure must disclose a partial durable start.
        // No hidden retry, rollback claim, synthetic chat message or executor.
        do {
            try validate(enqueued)
            guard sameRequest(enqueued.request, request), enqueued.origin == .localFixture,
                  enqueued.state == .queued, enqueued.revision == 1, enqueued.lease == nil else {
                throw RunRecoveryFixtureError.invalidRepositoryResponse
            }
            issuedRunIDs.insert(request.runID)
            try checkAdmission()
            let token = uuidGenerator.next()
            let claimed = try await journal.claimRun(
                id: request.runID, expectedRevision: enqueued.revision, ownerID: ownerID, token: token,
                now: now(), leaseDuration: Self.leaseDuration
            )
            try validateSuccessor(claimed, of: enqueued, state: .starting)
            guard let lease = claimed.lease, lease.ownerID == ownerID, lease.token == token else {
                throw RunRecoveryFixtureError.invalidRepositoryResponse
            }
            try checkAdmission()
            let started = try await journal.transitionRun(id: request.runID, expectedRevision: claimed.revision,
                token: token, event: .started, now: now())
            try validateSuccessor(started, of: claimed, state: .running)
            guard started.lease == lease else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
            try checkAdmission()
            let submitted = try await journal.markRunInput(id: request.runID, expectedRevision: started.revision,
                token: token, messageID: input.messageID, sequence: 1, state: .submitted, now: now())
            try validateSuccessor(submitted, of: started, state: .running)
            guard submitted.lease == lease else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
            let result = try await review(submitted)
            guard try initialReceipt(result).state == .submitted else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
            return result
        } catch {
            throw RunRecoveryFixtureError.partialStart(runID: request.runID)
        }
    }

    public func acknowledgeDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        let current = try await ownedReview(runID: runID, expectedRevision: expectedRevision)
        guard try initialReceipt(current).state == .submitted else { throw RunJournalError.invalidInputTransition }
        let lease = try requireLease(current.record, now: now())
        try checkAdmission()
        let updated = try await journal.markRunInput(id: runID, expectedRevision: expectedRevision,
            token: lease.token, messageID: current.record.request.initiatingMessageID,
            sequence: 1, state: .acknowledged, now: now())
        try validateSuccessor(updated, of: current.record, state: current.record.state)
        guard updated.lease == lease else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        let result = try await review(updated)
        guard try initialReceipt(result).state == .acknowledged else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        return result
    }

    public func finishDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        let current = try await ownedReview(runID: runID, expectedRevision: expectedRevision)
        guard try initialReceipt(current).state == .acknowledged else { throw RunJournalError.invalidInputTransition }
        return try await transition(current, event: .finish)
    }

    public func interruptDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        let current = try await ownedReview(runID: runID, expectedRevision: expectedRevision)
        return try await transition(current, event: .interrupt)
    }

    public func requestStopDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        let current = try await ownedReview(runID: runID, expectedRevision: expectedRevision)
        return try await transition(current, event: .requestStop)
    }

    public func failDemo(runID: RunID, expectedRevision: Int64) async throws -> RunRecoveryReview {
        try beginAction()
        defer { activeActions -= 1 }
        let current = try await ownedReview(runID: runID, expectedRevision: expectedRevision, requiresOwnedLease: false)
        if current.record.state == .queued {
            try checkAdmission()
            // Explicitly end an unclaimed partial demo; do not acquire a lease,
            // replay input or invent a running process merely to close the row.
            let updated = try await journal.failUnclaimedLocalFixture(id: runID,
                expectedRevision: expectedRevision, now: now())
            try validateSuccessor(updated, of: current.record, state: .failed)
            guard updated.lease == nil else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
            issuedRunIDs.remove(runID)
            let result = try await review(updated)
            guard try initialReceipt(result).state == initialReceipt(current).state else {
                throw RunRecoveryFixtureError.invalidRepositoryResponse
            }
            return result
        }
        return try await transition(current, event: .fail)
    }

    public func recoverExpiredDemos(conversationID: ConversationID) async throws -> [RunRecoveryReview] {
        try beginAction()
        defer { activeActions -= 1 }
        let records = try await journal.recoverExpiredLocalFixtures(
            conversationID: conversationID, now: now(), limit: Self.reviewLimit
        )
        try validateList(records, conversationID: conversationID)
        var changed: [RunRecoveryReview] = []
        for record in records {
            guard record.origin == .localFixture, record.state == .interrupted, record.lease == nil else {
                throw RunRecoveryFixtureError.invalidRepositoryResponse
            }
            issuedRunIDs.remove(record.id)
            changed.append(try await review(record))
        }
        return changed
    }

    private func transition(_ current: RunRecoveryReview, event: WorkRunEvent) async throws -> RunRecoveryReview {
        let next = try current.record.state.applying(event)
        let lease = try requireLease(current.record, now: now())
        try checkAdmission()
        let updated = try await journal.transitionRun(id: current.id, expectedRevision: current.record.revision,
            token: lease.token, event: event, now: now())
        try validateSuccessor(updated, of: current.record, state: next)
        let terminal = [.succeeded, .failed, .interrupted].contains(next)
        if terminal { issuedRunIDs.remove(current.id) }
        guard updated.lease == (terminal ? nil : lease) else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        let result = try await review(updated)
        let initialState = try initialReceipt(current).state
        let expectedInput: RunInputState = (next == .failed || next == .interrupted) && initialState == .submitted
            ? .outcomeUnknown : initialState
        guard try initialReceipt(result).state == expectedInput else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        return result
    }

    private func ownedReview(
        runID: RunID, expectedRevision: Int64, requiresOwnedLease: Bool = true
    ) async throws -> RunRecoveryReview {
        try checkAdmission()
        guard expectedRevision > 0, let record = try await journal.run(id: runID) else { throw RunJournalError.unavailable }
        try validate(record)
        guard record.id == runID else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        guard record.origin == .localFixture else { throw RunRecoveryFixtureError.wrongOrigin }
        guard record.revision == expectedRevision else { throw RunJournalError.staleRevision }
        if requiresOwnedLease || record.state != .queued { _ = try requireLease(record, now: now()) }
        return try await review(record)
    }

    private func review(_ record: RunJournalRecord) async throws -> RunRecoveryReview {
        try checkAdmission()
        try validate(record)
        let inputs = try await journal.runInputs(id: record.id, limit: Self.inputLimit)
        let entries = try await journal.runEntries(id: record.id, afterSequence: 0, limit: Self.entryLimit)
        // These are separate bounded repository reads, not a snapshot
        // transaction. Check the revision before treating a mixed-time result
        // as a malformed receipt; a concurrent update is simply stale.
        guard let latest = try await journal.run(id: record.id), latest == record else { throw RunJournalError.staleRevision }
        guard !inputs.isEmpty, !entries.isEmpty,
              inputs.count <= Self.inputLimit, entries.count <= Self.entryLimit,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.sequence)).count == inputs.count,
              inputs.allSatisfy({ $0.runID == record.id && $0.sequence > 0 && $0.updatedAt.timeIntervalSince1970.isFinite }),
              Set(entries.map(\.sequence)).count == entries.count,
              entries.allSatisfy({ $0.runID == record.id && $0.sequence > 0 && $0.recordedAt.timeIntervalSince1970.isFinite }),
              entries.map(\.sequence) == entries.map(\.sequence).sorted() else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        guard inputs.enumerated().allSatisfy({ $0.element.sequence == Int64($0.offset) + 1 }),
              entries.enumerated().allSatisfy({ $0.element.sequence == Int64($0.offset) + 1
                  && $0.element.sequence <= record.revision }),
              entries.count == Self.entryLimit || entries.last?.sequence == record.revision else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        let result = RunRecoveryReview(record: record, inputs: inputs, entries: entries)
        _ = try initialReceipt(result)
        try checkAdmission()
        return result
    }

    private func initialReceipt(_ review: RunRecoveryReview) throws -> RunInputReceipt {
        guard let input = review.inputs.first(where: { $0.sequence == 1 }),
              input.messageID == review.record.request.initiatingMessageID else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        return input
    }

    private func initialInput(_ message: Message) throws -> WorkInput {
        let parts = message.parts.sorted { $0.ordinal < $1.ordinal }
        guard !parts.isEmpty, parts.count <= 100,
              Set(parts.map(\.ordinal)).count == parts.count,
              parts.allSatisfy({ $0.ordinal >= 0 }) else { throw RunJournalError.invalidRequest }
        var text = ""
        var attachments: [AttachmentID] = []
        for part in parts {
            switch part.content {
            case let .text(value):
                guard value.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount - text.utf8.count else {
                    throw RunJournalError.invalidRequest
                }
                text += value
            case let .attachment(id): attachments.append(id)
            default: throw RunJournalError.invalidRequest
            }
        }
        guard !text.isEmpty || !attachments.isEmpty else { throw RunRecoveryFixtureError.needUserMessage }
        guard text.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount,
              attachments.count <= AttachmentDraftSnapshot.maximumAttachments,
              Set(attachments).count == attachments.count else { throw RunJournalError.invalidRequest }
        return try WorkInput(messageID: message.id, sequence: 1, text: text, attachmentIDs: attachments)
    }

    private func requireLease(_ record: RunJournalRecord, now: Date) throws -> RunLease {
        guard let lease = record.lease else { throw RunJournalError.leaseUnavailable }
        guard lease.ownerID == ownerID else { throw RunRecoveryFixtureError.wrongOwner }
        guard now.timeIntervalSince1970 >= record.updatedAt.timeIntervalSince1970 else { throw RunJournalError.clockMovedBackwards }
        guard lease.expiresAt.timeIntervalSince1970 > now.timeIntervalSince1970 else { throw RunJournalError.leaseExpired }
        return lease
    }

    private func validateList(_ records: [RunJournalRecord], conversationID: ConversationID) throws {
        guard records.count <= Self.reviewLimit, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.request.conversationID == conversationID }) else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        for record in records { try validate(record) }
    }

    private func validate(_ record: RunJournalRecord) throws {
        guard record.revision > 0, record.request.profileRevision > 0,
              record.request.profileRevision <= UInt64(Int64.max),
              record.request.initialInput.sequence == 1,
              record.request.initialInput.messageID == record.request.initiatingMessageID,
              record.request.initialInput.text.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount,
              !record.request.initialInput.text.isEmpty || !record.request.initialInput.attachmentIDs.isEmpty,
              record.request.initialInput.attachmentIDs.count <= AttachmentDraftSnapshot.maximumAttachments,
              Set(record.request.initialInput.attachmentIDs).count == record.request.initialInput.attachmentIDs.count,
              record.request.submittedAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970 >= record.request.submittedAt.timeIntervalSince1970 else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
        let requiresLease = [.starting, .running, .waitingForUser, .stopping].contains(record.state)
        guard requiresLease == (record.lease != nil) else { throw RunRecoveryFixtureError.invalidRepositoryResponse }
        if let lease = record.lease {
            guard lease.generation > 0, lease.expiresAt.timeIntervalSince1970.isFinite else {
                throw RunRecoveryFixtureError.invalidRepositoryResponse
            }
        }
    }

    private func validateSuccessor(_ updated: RunJournalRecord, of previous: RunJournalRecord, state: WorkRunState) throws {
        try validate(updated)
        guard previous.revision < Int64.max, updated.revision == previous.revision + 1,
              sameRequest(updated.request, previous.request), updated.origin == .localFixture,
              updated.state == state, updated.updatedAt.timeIntervalSince1970 >= previous.updatedAt.timeIntervalSince1970 else {
            throw RunRecoveryFixtureError.invalidRepositoryResponse
        }
    }

    private func sameRequest(_ lhs: WorkRequest, _ rhs: WorkRequest) -> Bool {
        lhs.runID == rhs.runID && lhs.teammateID == rhs.teammateID && lhs.conversationID == rhs.conversationID
            && lhs.initiatingMessageID == rhs.initiatingMessageID && lhs.selectedProjectID == rhs.selectedProjectID
            && lhs.profileRevision == rhs.profileRevision
            && lhs.submittedAt.timeIntervalSince1970 == rhs.submittedAt.timeIntervalSince1970
            && lhs.initialInput.messageID == rhs.initialInput.messageID && lhs.initialInput.sequence == rhs.initialInput.sequence
            && lhs.initialInput.text.utf8.elementsEqual(rhs.initialInput.text.utf8)
            && lhs.initialInput.attachmentIDs == rhs.initialInput.attachmentIDs
    }

    private func now() throws -> Date {
        let value = clock.now()
        guard value.timeIntervalSince1970.isFinite else { throw RunJournalError.invalidRequest }
        // Match SQLite REAL's Unix-epoch representation before freezing the
        // request. This avoids a false backwards-clock result on reopen.
        return Date(timeIntervalSince1970: value.timeIntervalSince1970)
    }
}

/// A tiny synchronous admission fence; no task, I/O or executor is created.
private final class LocalRunShutdownFence: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0
    var acceptsWork: Bool { lock.lock(); defer { lock.unlock() }; return phase == 0 }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return phase == 2 }
    func begin() { lock.lock(); defer { lock.unlock() }; phase = max(phase, 1) }
    func finish() { lock.lock(); defer { lock.unlock() }; phase = 2 }
}
