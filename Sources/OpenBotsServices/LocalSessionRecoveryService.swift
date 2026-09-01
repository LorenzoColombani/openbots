import Foundation
import OpenBotsDomain

/// Small, explicit app-lifecycle bookkeeping. It cannot save drafts itself,
/// launch work, extend a shutdown deadline, or clean up any filesystem path.
public actor LocalSessionRecoveryService {
    public static let unconfirmedCloseNotice = "OpenBots couldn’t confirm that recent changes were saved before the previous close. Review recent messages and drafts before continuing; this does not confirm that anything was lost."
    public static let unavailableNotice = "OpenBots couldn’t check the previous close or prepare save-status recovery. Review recent messages and drafts; their recovery status is unconfirmed."

    private let repository: any LocalSessionRecoveryRepository
    private let id: UUID
    private let clock: any OpenBotsClock
    private var beginAttempted = false
    private var beginning = false
    private var began = false
    private var beginNotice: String?
    private var finishing = false
    private var finishedOutcome: LocalSessionSaveOutcome?

    public init(repository: any LocalSessionRecoveryRepository, id: UUID = UUID(), clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository
        self.id = id
        self.clock = clock
    }

    public func begin() async -> String? {
        guard !Task.isCancelled else { return Self.unavailableNotice }
        guard !beginning else { return Self.unavailableNotice }
        guard !beginAttempted else { return beginNotice }
        beginAttempted = true
        beginning = true
        defer { beginning = false }
        do {
            try Task.checkCancellation()
            let prior = try await repository.beginLocalSession(id: id, at: clock.now())
            try prior?.validate()
            try Task.checkCancellation()
            began = true
            if let prior, prior.status != .saved { beginNotice = Self.unconfirmedCloseNotice }
        } catch { beginNotice = Self.unavailableNotice }
        return beginNotice
    }

    /// Called only with the completed bounded-save result. Cancellation before
    /// the transaction prevents a new saved claim. If cancellation arrives
    /// after commit, the valid saved marker may remain even though this caller
    /// receives false; cancellation cannot undo an already-completed commit.
    public func finish(saved: Bool) async -> Bool {
        guard began, !beginning, !finishing, !Task.isCancelled else { return false }
        let outcome: LocalSessionSaveOutcome = saved ? .saved : .incomplete
        if let finishedOutcome { return finishedOutcome == outcome }
        finishing = true
        defer { finishing = false }
        do {
            try Task.checkCancellation()
            try await repository.finishLocalSession(id: id, outcome: outcome, at: clock.now())
            try Task.checkCancellation()
            finishedOutcome = outcome
            return true
        } catch { return false }
    }
}
