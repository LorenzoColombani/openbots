import Foundation
import Testing
@testable import OpenBotsServices

struct BudgetedWaitTests {
    @Test func quickWorkReturnsItsValueBeforeTheBudget() async throws {
        let work = Task<Int, any Error> { 42 }
        let outcome = await BudgetedWait.result(of: work, within: .seconds(5))
        guard case .finished(let result) = outcome else {
            Issue.record("expected the value, got \(outcome)")
            return
        }
        #expect(try result.get() == 42)
    }

    @Test func failingWorkReportsItsErrorBeforeTheBudget() async {
        struct Boom: Error {}
        let work = Task<Int, any Error> { throw Boom() }
        let outcome = await BudgetedWait.result(of: work, within: .seconds(5))
        guard case .finished(let result) = outcome, case .failure(let error) = result else {
            Issue.record("expected the failure, got \(outcome)")
            return
        }
        #expect(error is Boom)
    }

    @Test func hangingWorkIsAbandonedAndCancelledWhenTheBudgetLapses() async {
        let work = Task<Int, any Error> {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
        let started = ContinuousClock.now
        let outcome = await BudgetedWait.result(of: work, within: .milliseconds(100))
        let waited = ContinuousClock.now - started
        guard case .budgetExceeded = outcome else {
            Issue.record("expected the budget to win, got \(outcome)")
            return
        }
        #expect(waited < .seconds(5), "the budget, not the work, bounded the wait: \(waited)")
        #expect(work.isCancelled)
    }

    @Test func workThatIgnoresCancellationStillDoesNotHoldTheCaller() async {
        // A synchronous chore that never checks for cancellation.
        func chore() -> Int {
            Thread.sleep(forTimeInterval: 1.5)
            return 7
        }
        let work = Task<Int, any Error> { chore() }
        let started = ContinuousClock.now
        let outcome = await BudgetedWait.result(of: work, within: .milliseconds(100))
        let waited = ContinuousClock.now - started
        guard case .budgetExceeded = outcome else {
            Issue.record("expected the budget to win, got \(outcome)")
            return
        }
        #expect(waited < .seconds(1), "returned before the chore finished: \(waited)")
        _ = await work.result
    }
}
