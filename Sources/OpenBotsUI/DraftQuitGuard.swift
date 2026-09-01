import Foundation

public enum LocalShutdownOutcome: Equatable, Sendable {
    case saved, incomplete, timedOut

    public var message: String {
        switch self {
        case .saved: "Available local state was saved."
        case .incomplete: "Some recent changes could not be confirmed saved. Previously saved work is kept."
        case .timedOut: "OpenBots stopped waiting for saving. Some recent changes may not have been saved."
        }
    }
}

/// One finite app-close boundary, not a save-success veto. AppKit terminates
/// the process after the reply, including uncooperative in-process tasks.
/// Task cancellation alone is deliberately NOT represented as termination.
@MainActor
public final class DraftQuitGuard {
    public static let maximumGrace: Duration = .seconds(3)
    private let timeout: Duration
    private var flushTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completion: (@MainActor (LocalShutdownOutcome) -> Void)?
    public private(set) var isPending = false
    public private(set) var outcome: LocalShutdownOutcome?

    public init(timeout: Duration = DraftQuitGuard.maximumGrace) {
        self.timeout = min(Self.maximumGrace, max(.zero, timeout))
    }

    /// Admission closes synchronously. Duplicates never renew the deadline.
    @discardableResult
    public func request(
        begin: @MainActor () -> Void = {},
        flush: @escaping @MainActor () async -> Bool,
        finish: @escaping @MainActor () -> Void = {},
        reply: @escaping @MainActor (LocalShutdownOutcome) -> Void
    ) -> Bool {
        guard !isPending, outcome == nil else { return false }
        isPending = true
        completion = { result in finish(); reply(result) }
        begin()
        timeoutTask = Task { @MainActor [self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            resolve(.timedOut)
        }
        flushTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let saved = await flush()
            guard !Task.isCancelled else { return }
            self?.resolve(saved ? .saved : .incomplete)
        }
        return true
    }

    private func resolve(_ result: LocalShutdownOutcome) {
        guard isPending else { return }
        outcome = result
        isPending = false
        flushTask?.cancel()
        timeoutTask?.cancel()
        flushTask = nil
        timeoutTask = nil
        let reply = completion
        completion = nil
        reply?(result)
    }
}
