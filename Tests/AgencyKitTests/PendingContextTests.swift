import XCTest
@testable import AgencyKit

/// Records the arguments it was invoked with, so tests can assert on the prompt
/// that would actually reach the `claude` binary.
final class RecordingProcess: ProcessRunning, @unchecked Sendable {
    let lines: [String]
    private(set) var lastArguments: [String] = []
    init(lines: [String]) { self.lines = lines }

    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        lastArguments = arguments
        return AsyncThrowingStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        }
    }

    var lastPrompt: String { lastArguments.last ?? "" }
}

/// Simulates a send that fails outright (claude not found, not logged in,
/// plan limit) — the process never produces a result.
struct ThrowingProcess: ProcessRunning {
    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProcessFailure(status: 1, stderr: "simulated failure")) }
    }
}

final class PendingContextTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-pc-\(UUID().uuidString)"))
    }

    func testBeginCommitDeliversExactlyOnce() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let pending = PendingContext(store: store)
        XCTAssertNil(pending.begin(for: "bruno"))
        try pending.add("the answer is 42", for: "bruno")
        XCTAssertEqual(pending.peek(for: "bruno")?.contains("42"), true)
        XCTAssertEqual(pending.begin(for: "bruno")?.contains("42"), true)
        pending.commit(for: "bruno")
        XCTAssertNil(pending.begin(for: "bruno"))   // committed = gone
        XCTAssertNil(pending.peek(for: "bruno"))
    }

    /// Review C1: a FAILED send must not destroy the handoff payload. begin()
    /// stages; only commit() (success) clears; the next begin() re-delivers.
    func testFailedSendPreservesHandoffPayload() async throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let pending = PendingContext(store: store)
        try pending.add("[Handoff] Alfredo replied: vault/coffee.md", for: "bruno")

        // Send fails outright — claude never ran.
        let failingRunner = SessionRunner(store: store, process: ThrowingProcess())
        let bruno = try store.loadRoster().agents.first { $0.name == "bruno" }!
        do {
            for try await _ in failingRunner.send("write the brief", to: bruno) {}
            XCTFail("send should have thrown")
        } catch { /* expected */ }

        // The payload survived the failure...
        XCTAssertEqual(pending.peek(for: "bruno")?.contains("vault/coffee.md"), true,
                       "failed send destroyed the handoff payload")

        // ...and the next SUCCESSFUL send both carries and clears it.
        let proc = RecordingProcess(lines: [
            #"{"type":"result","subtype":"success","result":"Bruno: done","session_id":"sid-b"}"#,
        ])
        let runner = SessionRunner(store: store, process: proc)
        for try await _ in runner.send("write the brief", to: bruno) {}
        XCTAssertTrue(proc.lastPrompt.contains("vault/coffee.md"))
        XCTAssertNil(pending.peek(for: "bruno"))
    }

    /// The original defect this component fixes: after a relay, the asker's own
    /// Claude session had never seen the reply — only its log had. The next
    /// prompt must carry it, exactly once.
    func testRelayReplyReachesAskersNextPrompt() async throws {
        let store = makeStore()
        let alfredo = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "research")
        let bruno = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        _ = alfredo
        let proc = RecordingProcess(lines: [
            #"{"type":"result","subtype":"success","result":"Alfredo: the note is at vault/coffee.md","session_id":"sid-a"}"#,
        ])
        let runner = SessionRunner(store: store, process: proc)
        let broker = HandoffBroker(store: store, runner: runner, log: MessageLog(store: store))

        let alfredoAgent = try store.loadRoster().agents.first { $0.name == "alfredo" }!
        _ = try await broker.relay(question: "where is your note?", from: bruno, to: alfredoAgent)

        // Bruno's next ordinary message must carry Alfredo's reply into his context.
        let refreshedBruno = try store.loadRoster().agents.first { $0.name == "bruno" }!
        for try await _ in runner.send("write the brief now", to: refreshedBruno) {}
        XCTAssertTrue(proc.lastPrompt.contains("vault/coffee.md"),
                      "asker's next prompt must include the handoff reply")
        XCTAssertTrue(proc.lastPrompt.contains("write the brief now"))

        // …and only once: a second message must not repeat it.
        for try await _ in runner.send("second message", to: refreshedBruno) {}
        XCTAssertFalse(proc.lastPrompt.contains("vault/coffee.md"))
    }
}
