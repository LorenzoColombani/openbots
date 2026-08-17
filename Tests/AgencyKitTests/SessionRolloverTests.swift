import XCTest
@testable import AgencyKit

/// First invocation fails the way a stale `--resume` really fails (probed live
/// 2026-08-12, receipt in .feasibility/resume-failure-receipt.md: exit 1, stderr
/// "No conversation found with session ID: …"); the retry succeeds.
final class FailingThenSucceedingProcess: ProcessRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []

    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        calls.append(arguments)
        let attempt = calls.count
        return AsyncThrowingStream { cont in
            if attempt == 1 {
                cont.finish(throwing: ProcessFailure(
                    status: 1, stderr: "No conversation found with session ID: dead-sid-1"))
            } else {
                cont.yield(#"{"type":"system","subtype":"init","session_id":"fresh-sid-2"}"#)
                cont.yield(#"{"type":"result","subtype":"success","result":"Alfredo: hello again","session_id":"fresh-sid-2"}"#)
                cont.finish()
            }
        }
    }
}

/// Counts invocations so retry-count assertions are real (review #3 I-5: the old
/// double had no counter, so a guard that retried EVERY failure still passed).
final class CountingThrowingProcess: ProcessRunning, @unchecked Sendable {
    let stderrText: String
    private(set) var calls = 0
    init(stderr: String) { self.stderrText = stderr }

    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        calls += 1
        return AsyncThrowingStream { [stderrText] cont in
            cont.finish(throwing: ProcessFailure(status: 1, stderr: stderrText))
        }
    }
}

/// Yields a successful result FIRST, then throws with the rollover phrase on a
/// later call — the "phrase arrived on a shared stderr channel after real work
/// happened" scenario (review #3 I-1).
final class ResultThenPhraseFailureProcess: ProcessRunning, @unchecked Sendable {
    private(set) var calls = 0
    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        calls += 1
        return AsyncThrowingStream { cont in
            cont.yield(#"{"type":"system","subtype":"init","session_id":"live-sid"}"#)
            cont.yield(#"{"type":"result","subtype":"success","result":"partial work","session_id":"live-sid"}"#)
            cont.finish(throwing: ProcessFailure(
                status: 1, stderr: "grandchild noise: No conversation found with session ID: live-sid"))
        }
    }
}

private func hasRollover(_ events: [StreamEvent]) -> Bool {
    events.contains { if case .sessionRolledOver = $0 { return true }; return false }
}

final class SessionRolloverTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ro-\(UUID().uuidString)"))
    }

    /// Review #1 I4: a dead session id used to brick the teammate forever.
    /// Now: drop the id, notify WITH THE REASON, retry once on a fresh session.
    func testUnresumableSessionRollsOverAndRetriesOnce() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        try store.setSessionID("dead-sid-1", for: "alfredo")
        let proc = FailingThenSucceedingProcess()
        let runner = SessionRunner(store: store, process: proc)
        let alfredo = try store.loadRoster().agents[0]

        var events: [StreamEvent] = []
        var rolloverReason: String?
        for try await e in runner.send("hi", to: alfredo) {
            events.append(e)
            if case .sessionRolledOver(let reason) = e { rolloverReason = reason }
        }

        XCTAssertTrue(hasRollover(events), "UI was not told about the rollover")
        XCTAssertEqual(rolloverReason?.contains("No conversation found"), true,
                       "the notice must carry WHY the session was unresumable")
        XCTAssertTrue(events.contains(.resultText("Alfredo: hello again", sessionID: "fresh-sid-2")))
        XCTAssertEqual(proc.calls.count, 2)
        XCTAssertTrue(proc.calls[0].contains("--resume"), "first attempt should resume")
        XCTAssertFalse(proc.calls[1].contains("--resume"), "retry must start FRESH")
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "fresh-sid-2")
    }

    /// A genuinely failing send (unrelated stderr) must NOT retry — exactly one
    /// billed attempt (review #3 I-5: now asserted with a real call counter).
    func testOtherFailuresDoNotRetry() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "w")
        try store.setSessionID("live-sid", for: "bruno")
        let proc = CountingThrowingProcess(stderr: "usage limit reached")
        let runner = SessionRunner(store: store, process: proc)
        let bruno = try store.loadRoster().agents[0]
        do {
            for try await _ in runner.send("hi", to: bruno) {}
            XCTFail("should have thrown")
        } catch { /* expected */ }
        XCTAssertEqual(proc.calls, 1, "an unrelated failure must not be retried (double billing)")
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "live-sid",
                       "an unrelated failure must not wipe the live session id")
    }

    /// Review #3 I-1 precondition 1: no `--resume` in play → the phrase must not
    /// trigger a rollover (there is no session to roll over — a retry would be a
    /// second billed call for nothing).
    func testNoRolloverWhenNothingWasResumed() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "f")   // no sessionID
        let proc = CountingThrowingProcess(stderr: "No conversation found with session ID: ghost")
        let runner = SessionRunner(store: store, process: proc)
        let nina = try store.loadRoster().agents[0]
        do {
            for try await e in runner.send("hi", to: nina) {
                if case .sessionRolledOver = e { XCTFail("rollover fired with no --resume in play") }
            }
            XCTFail("should have thrown")
        } catch { /* expected */ }
        XCTAssertEqual(proc.calls, 1)
    }

    /// Review #3 I-1 precondition 2: once the attempt produced real events, a
    /// trailing phrase on the shared stderr channel must not wipe the live
    /// session — that is the "grandchild noise" hazard, measured by the reviewer.
    func testNoRolloverAfterRealEventsThisAttempt() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        try store.setSessionID("live-sid", for: "alfredo")
        let proc = ResultThenPhraseFailureProcess()
        let runner = SessionRunner(store: store, process: proc)
        let alfredo = try store.loadRoster().agents[0]
        var events: [StreamEvent] = []
        do {
            for try await e in runner.send("hi", to: alfredo) { events.append(e) }
            XCTFail("should have thrown")
        } catch { /* expected */ }
        XCTAssertFalse(hasRollover(events), "phrase after real events must not roll over")
        XCTAssertEqual(proc.calls, 1)
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "live-sid",
                       "live session id must survive stderr noise")
    }
}
