import Foundation

/// Waits for a task or a time budget, whichever ends first.
///
/// A quit-time chore such as a database backup must never hold the app past the
/// close boundary. Structured concurrency cannot express that: a task group waits
/// for every child, and a child doing synchronous file work cannot observe
/// cancellation until it is done. This helper returns when the budget lapses,
/// cancels the task, and leaves it to finish or die with the process.
public enum BudgetedWait {
    public enum Outcome<Value: Sendable>: Sendable {
        case finished(Result<Value, any Error>)
        case budgetExceeded
    }

    /// The task's result if it ends within `budget`; otherwise the task is
    /// cancelled and `.budgetExceeded` is returned without waiting for it.
    public static func result<Value: Sendable>(
        of work: Task<Value, any Error>,
        within budget: Duration
    ) async -> Outcome<Value> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
            let gate = ResumeOnce(continuation)
            let deadline = Task {
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled else { return }
                work.cancel()
                gate.resume(.budgetExceeded)
            }
            Task {
                let result = await work.result
                deadline.cancel()
                gate.resume(.finished(result))
            }
        }
    }
}

/// Resumes a continuation at most once, from whichever caller arrives first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
