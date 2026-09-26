import Foundation
import OpenBotsDomain

/// Launch-time proof that a saved text turn's owning process is gone.
///
/// The app keeps one running copy per workspace: a second copy brings the first
/// forward and quits before it touches storage. A text turn's lease carries the
/// owner ID of the reply service that started it, and that ID is minted per
/// process. So while this process is the only running copy, a pending turn whose
/// lease owner is not one of this process's own reply services belonged to a
/// process that no longer runs: it crashed, was force-quit, or the Mac went down
/// with it. That is the whole proof. Lease age, session IDs and probe failures
/// prove nothing here and are never consulted.
public struct SoleInstanceTextTurnProcessAbsence: TextTurnProcessAbsenceProving {
    private let ownersHeldByThisProcess: @Sendable () -> Set<UUID>
    private let isSoleRunningInstance: @Sendable () -> Bool

    /// - Parameters:
    ///   - ownersHeldByThisProcess: the lease owner IDs any reply service of this
    ///     process uses or will use; a turn leased by one of them is live, not orphaned.
    ///   - isSoleRunningInstance: true only when no other copy of the app is running.
    public init(ownersHeldByThisProcess: @escaping @Sendable () -> Set<UUID>,
                isSoleRunningInstance: @escaping @Sendable () -> Bool) {
        self.ownersHeldByThisProcess = ownersHeldByThisProcess
        self.isSoleRunningInstance = isSoleRunningInstance
    }

    public func withVerifiedAbsence(for candidate: TextTurnRecoveryCandidate,
        operation: @escaping @Sendable (TextTurnProcessAbsence) async throws -> TextTurnSnapshot)
        async throws -> TextTurnSnapshot? {
        guard isSoleRunningInstance(),
              !ownersHeldByThisProcess().contains(candidate.leaseOwnerID) else { return nil }
        try Task.checkCancellation()
        return try await operation(TextTurnProcessAbsence(runID: candidate.runID, leaseOwnerID: candidate.leaseOwnerID))
    }
}
