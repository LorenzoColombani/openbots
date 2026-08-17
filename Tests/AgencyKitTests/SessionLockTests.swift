import XCTest
@testable import AgencyKit

/// Slow double that records wall-clock run intervals, so overlap is measurable.
final class SlowRecordingProcess: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var intervals: [(start: Date, end: Date)] = []
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    private(set) var launches = 0

    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        lock.lock(); launches += 1; lock.unlock()
        let delay = self.delay
        return AsyncThrowingStream { cont in
            Task {
                let start = Date()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let end = Date()
                self.lock.lock(); self.intervals.append((start, end)); self.lock.unlock()
                cont.yield(#"{"type":"result","subtype":"success","result":"ok","session_id":"s"}"#)
                cont.finish()
            }
        }
    }
}

/// The per-agent session lock (review #3 rec / #4 priority 1): ONE live process
/// per agent, even across concurrent sends.
final class SessionLockTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-sl-\(UUID().uuidString)"))
    }

    func testConcurrentSendsToOneAgentAreSerialized() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "solo", emoji: "🧪", role: "probe")
        let proc = SlowRecordingProcess(delay: 0.4)
        let runner = SessionRunner(store: store, process: proc)
        let agent = try store.loadRoster().agents[0]

        async let a: Void = { for try await _ in runner.send("one", to: agent) {} }()
        async let b: Void = { for try await _ in runner.send("two", to: agent) {} }()
        _ = try await (a, b)

        XCTAssertEqual(proc.intervals.count, 2)
        let sorted = proc.intervals.sorted { $0.start < $1.start }
        XCTAssertGreaterThanOrEqual(sorted[1].start, sorted[0].end,
            "second process started before the first finished — the session lock did not serialize")
    }

    /// Review #4 I-3: cancellation while WAITING for the lock must not launch —
    /// the launched process would run without the lock the wait exists to hold.
    func testCancelDuringLockWaitDoesNotLaunch() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "solo", emoji: "🧪", role: "probe")
        let agent = try store.loadRoster().agents[0]

        // Hold the agent's session lock from the outside.
        let lockPath = store.agentDir("solo").appendingPathComponent(".session.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let proc = SlowRecordingProcess(delay: 0.1)
        let runner = SessionRunner(store: store, process: proc)
        let consumer = Task {
            do { for try await _ in runner.send("hi", to: agent) {} } catch {}
        }
        try await Task.sleep(nanoseconds: 500_000_000)   // let it enter the poll loop
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(nanoseconds: 300_000_000)   // grace for any stray launch
        XCTAssertEqual(proc.launches, 0,
            "cancelled-while-waiting send launched a process without holding the lock")
    }
}
