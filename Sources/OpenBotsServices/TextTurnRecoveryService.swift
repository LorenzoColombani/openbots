import Foundation
import OpenBotsDomain

/// Process identity metadata only. Neither a lease's age nor an unfamiliar
/// owner proves absence. A session ID is a correlation key, not an OS handle.
public struct TextTurnRecoveryCandidate: Equatable, Sendable {
    public let appOwnerID: UUID
    public let runID: RunID
    public let teammateID: TeammateID
    public let conversationID: ConversationID
    public let revision: Int64
    public let leaseOwnerID: UUID
    public let leaseGeneration: Int64
    public let sessionID: UUID?

    fileprivate init?(_ snapshot: TextTurnSnapshot, appOwnerID: UUID) {
        let run = snapshot.run
        guard run.origin == .executor, run.revision > 0,
              ![WorkRunState.succeeded, .failed, .interrupted].contains(run.state),
              let identity = run.request.textTurnIdentity, identity.appOwnerID == appOwnerID,
              let lease = run.lease, lease.generation > 0 else { return nil }
        self.appOwnerID = appOwnerID; runID = run.id
        teammateID = run.request.teammateID; conversationID = run.request.conversationID
        revision = run.revision; leaseOwnerID = lease.ownerID; leaseGeneration = lease.generation
        sessionID = identity.executionRequest?.sessionID
    }
}

/// Trusted process-owner boundary, not a scan/lease heuristic or cryptographic
/// assertion. Invoke operation at most once, only after proving absence of this
/// exact run's owned execution, and maintain exclusion against a late launch
/// until operation returns. Return its result unchanged. Return nil without
/// invoking operation when the proof or exclusion cannot be established.
///
/// Implementations must be bounded and cancellation-aware. Missing session IDs
/// require independent ownership evidence; never infer absence from missing IDs,
/// task cancellation, expired leases, a new app instance, or a failed probe.
public protocol TextTurnProcessAbsenceProving: Sendable {
    func withVerifiedAbsence(for candidate: TextTurnRecoveryCandidate,
        operation: @escaping @Sendable (TextTurnProcessAbsence) async throws -> TextTurnSnapshot)
        async throws -> TextTurnSnapshot?
}

/// Native startup currently has no durable process-ownership handle. Keep the
/// production default inert until a scoped proof implementation is supplied.
public struct UnprovenTextTurnProcessAbsence: TextTurnProcessAbsenceProving {
    public init() {}
    public func withVerifiedAbsence(for candidate: TextTurnRecoveryCandidate,
        operation: @escaping @Sendable (TextTurnProcessAbsence) async throws -> TextTurnSnapshot)
        async throws -> TextTurnSnapshot? { nil }
}

public enum TextTurnRecoveryStatus: Equatable, Sendable {
    case completed, cancelled, unavailable, inProgress
}

public enum TextTurnRecoveryDisposition: Equatable, Sendable {
    case interrupted, absenceUnproven, changed, unavailable
}

/// Status-only results never expose saved user text, provider partials or paths.
public struct TextTurnRecoveryEntry: Equatable, Sendable {
    public let runID: RunID
    public let disposition: TextTurnRecoveryDisposition
}

public struct TextTurnRecoveryReport: Equatable, Sendable {
    public let status: TextTurnRecoveryStatus
    public let entries: [TextTurnRecoveryEntry]
    public let hasMore: Bool

    public var interruptedCount: Int { entries.filter { $0.disposition == .interrupted }.count }
    public var needsAttention: Bool {
        status != .completed || hasMore || entries.contains { $0.disposition != .interrupted }
    }

    public var notice: String? {
        guard needsAttention else { return nil }
        if status == .inProgress { return "Saved Claude turns are still being checked. Nothing has been resent." }
        return "Some saved Claude turns remain unresolved. Their records are kept, and nothing has been resent."
    }
}

/// One explicit finite recovery pass. There is no runner, replay, retry, process
/// signalling or candidate-publication dependency. The repository preserves the
/// saved partial/status and performs the final revision/owner check atomically.
public actor TextTurnRecoveryService {
    private let repository: any TextTurnRepository
    private let appOwnerID: UUID
    private let absenceProver: any TextTurnProcessAbsenceProving
    private let clock: @Sendable () -> Date
    private var running = false

    public init(repository: any TextTurnRepository, appOwnerID: UUID,
                absenceProver: any TextTurnProcessAbsenceProving = UnprovenTextTurnProcessAbsence(),
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.repository = repository; self.appOwnerID = appOwnerID
        self.absenceProver = absenceProver; self.clock = clock
    }

    public func recover(limit: Int = 8) async -> TextTurnRecoveryReport {
        guard !running else { return .init(status: .inProgress, entries: [], hasMore: false) }
        guard (1...25).contains(limit) else { return .init(status: .unavailable, entries: [], hasMore: false) }
        running = true
        defer { running = false }
        if Task.isCancelled { return .init(status: .cancelled, entries: [], hasMore: true) }
        let pending: [TextTurnSnapshot]
        do { pending = try await repository.pendingTextTurns(appOwnerID: appOwnerID, limit: limit + 1) }
        catch is CancellationError { return .init(status: .cancelled, entries: [], hasMore: true) }
        catch { return .init(status: .unavailable, entries: [], hasMore: false) }
        guard pending.count <= limit + 1, Set(pending.map { $0.run.id }).count == pending.count,
              pending.allSatisfy({ $0.run.origin == .executor
                  && $0.run.request.textTurnIdentity?.appOwnerID == appOwnerID
                  && ![WorkRunState.succeeded, .failed, .interrupted].contains($0.run.state) }) else {
            return .init(status: .unavailable, entries: [], hasMore: false)
        }
        var entries: [TextTurnRecoveryEntry] = []
        for snapshot in pending.prefix(limit) {
            if Task.isCancelled { return .init(status: .cancelled, entries: entries, hasMore: true) }
            guard let candidate = TextTurnRecoveryCandidate(snapshot, appOwnerID: appOwnerID) else {
                entries.append(.init(runID: snapshot.run.id, disposition: .absenceUnproven))
                continue
            }
            let disposition: TextTurnRecoveryDisposition
            do {
                let repository = repository, clock = clock
                let recovered = try await absenceProver.withVerifiedAbsence(for: candidate) { proof in
                    try Task.checkCancellation()
                    guard proof.runID == candidate.runID, proof.leaseOwnerID == candidate.leaseOwnerID else {
                        throw RecoveryProofError.mismatchedIdentity
                    }
                    return try await repository.interruptTextTurn(id: candidate.runID,
                        expectedRevision: candidate.revision, appOwnerID: candidate.appOwnerID,
                        processAbsence: proof, now: clock())
                }
                if let recovered {
                    guard recovered.run.request == snapshot.run.request,
                          recovered.run.origin == .executor, recovered.run.state == .interrupted,
                          recovered.run.revision > snapshot.run.revision, recovered.run.lease == nil,
                          recovered.replyText.utf8.elementsEqual(snapshot.replyText.utf8) else {
                        throw RecoveryProofError.invalidResult
                    }
                    disposition = .interrupted
                } else {
                    disposition = .absenceUnproven
                }
            } catch is CancellationError {
                return .init(status: .cancelled, entries: entries, hasMore: true)
            } catch RecoveryProofError.mismatchedIdentity {
                disposition = .absenceUnproven
            } catch RunJournalError.staleRevision {
                disposition = .changed
            } catch TextTurnRepositoryError.processAbsenceMismatch {
                disposition = .changed
            } catch {
                disposition = .unavailable
            }
            entries.append(.init(runID: candidate.runID, disposition: disposition))
        }
        return .init(status: .completed, entries: entries, hasMore: pending.count > limit)
    }
}

private enum RecoveryProofError: Error { case mismatchedIdentity, invalidResult }
