import Foundation
import Testing
@testable import OpenBotsUI

@Suite("DraftQuitGuardTests")
@MainActor
struct DraftQuitGuardTests {
    @Test("Begin is immediate; save outcome never becomes a Quit veto")
    func finiteOutcomes() async {
        for saved in [true, false] {
            let gate = DraftQuitGuard()
            var events: [String] = []
            let result = await withCheckedContinuation { continuation in
                let accepted = gate.request(begin: { events.append("freeze") }, flush: {
                    events.append("save")
                    return saved
                }, finish: { events.append("finish") }, reply: {
                    events.append("reply")
                    continuation.resume(returning: $0)
                })
                #expect(accepted)
                #expect(events == ["freeze"])
            }
            #expect(result == (saved ? .saved : .incomplete))
            #expect(events == ["freeze", "save", "finish", "reply"])
            #expect(gate.outcome == result)
            #expect(!gate.isPending)
            let repeated = gate.request(flush: { true }, reply: { _ in Issue.record("Second reply") })
            #expect(!repeated)
        }
    }

    @Test("Repeated close requests cannot extend a deadline or admit work")
    func duplicateAndReentrant() async {
        let gate = DraftQuitGuard()
        var duplicateCalls = 0
        await withCheckedContinuation { continuation in
            let accepted = gate.request(flush: { true }, reply: { _ in
                let reentrant = gate.request(begin: { duplicateCalls += 1 }, flush: { true }, reply: { _ in duplicateCalls += 1 })
                #expect(!reentrant)
                continuation.resume()
            })
            #expect(accepted)
            let repeated = gate.request(begin: { duplicateCalls += 1 }, flush: { true }, reply: { _ in duplicateCalls += 1 })
            #expect(!repeated)
        }
        #expect(duplicateCalls == 0)
    }

    @Test("Noncooperative save cannot delay termination reply or publish a late success")
    func stalledSave() async {
        let gate = DraftQuitGuard(timeout: .milliseconds(25))
        let flush = SuspendedShutdownSave()
        var replies: [LocalShutdownOutcome] = []
        var finishes = 0
        let start = ContinuousClock.now
        await withCheckedContinuation { continuation in
            gate.request(flush: { await flush.wait() }, finish: { finishes += 1 }, reply: {
                replies.append($0); continuation.resume()
            })
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(replies == [.timedOut])
        #expect(finishes == 1)
        #expect(flush.continuation != nil, "Cancel is not proof of task/process termination.")
        flush.continuation?.resume(returning: true)
        flush.continuation = nil
        await flush.waitForReturn()
        #expect(flush.wasCancelled)
        #expect(replies == [.timedOut])
        #expect(gate.outcome == .timedOut)
        #expect(finishes == 1)
    }

    @Test("Immediate deadline is bounded and exposes possible loss plainly")
    func immediateDeadline() async {
        let gate = DraftQuitGuard(timeout: .zero)
        let result = await withCheckedContinuation { continuation in
            gate.request(flush: {
                do { try await Task.sleep(for: .seconds(2)) } catch {}
                return false
            }, reply: { continuation.resume(returning: $0) })
        }
        #expect(result == .timedOut)
        #expect(result.message.contains("may not have been saved"))
        #expect(DraftQuitGuard.maximumGrace == .seconds(3))
    }
}

@MainActor
private final class SuspendedShutdownSave {
    var continuation: CheckedContinuation<Bool, Never>?
    var wasCancelled = false
    private var returned = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async -> Bool {
        let value = await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
        returned = true
        waiter?.resume(); waiter = nil
        return value
    }
    func waitForReturn() async {
        if returned { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
