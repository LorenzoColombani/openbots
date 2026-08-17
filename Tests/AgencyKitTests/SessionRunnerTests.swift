import XCTest
@testable import AgencyKit

struct MockProcess: ProcessRunning {
    let lines: [String]
    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        }
    }
}

/// Records every invocation's arguments — lets tests assert on the PROMPT a
/// send actually carried (e.g. whether a staged handoff rode along).
final class ArgsCapturingMock: ProcessRunning, @unchecked Sendable {
    let lines: [String]
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _execs: [String] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var execs: [String] { lock.lock(); defer { lock.unlock() }; return _execs }
    init(lines: [String]) { self.lines = lines }
    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _calls.append(arguments); _execs.append(executable); lock.unlock()
        return AsyncThrowingStream { cont in
            for l in lines { cont.yield(l) }
            cont.finish()
        }
    }
}

final class SessionRunnerTests: XCTestCase {
    func testArgumentsForNewAgent() {
        let agent = Agent(name: "alfredo", emoji: "🧑‍🍳", role: "r", model: nil, sessionID: nil)
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/tmp/vault")
        XCTAssertEqual(args, ["-p", "--output-format", "stream-json", "--include-partial-messages",
                              "--verbose", "--add-dir", "/tmp/vault",
                              "--permission-mode", "acceptEdits",
                              "--allowedTools", AgentStore.defaultAllowedTools.joined(separator: ","),
                              "--disallowedTools", AgentStore.agentDisallowedTools.joined(separator: ","),
                              "--strict-mcp-config",
                              "--", "hi"])
    }

    func testArgumentsWithResumeAndModel() {
        let agent = Agent(name: "a", emoji: "x", role: "r", model: "haiku", sessionID: "sid-9")
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(args.contains("--resume")); XCTAssertTrue(args.contains("sid-9"))
        XCTAssertTrue(args.contains("--model")); XCTAssertTrue(args.contains("haiku"))
    }

    func testSendYieldsEventsAndPersistsSessionID() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-sr-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        let agent = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        let mock = MockProcess(lines: [
            #"{"type":"system","subtype":"init","session_id":"new-sid-1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Alfredo: hello"}}}"#,
            #"{"type":"result","subtype":"success","result":"Alfredo: hello","session_id":"new-sid-1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        var events: [StreamEvent] = []
        for try await e in runner.send("hi", to: agent) { events.append(e) }
        XCTAssertTrue(events.contains(.textDelta("Alfredo: hello")))
        XCTAssertTrue(events.contains(.resultText("Alfredo: hello", sessionID: "new-sid-1")))
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "new-sid-1")
    }

    // MARK: forked mode (queued message → subagent)

    func testForkArgumentsCarryForkSessionAfterResume() {
        let agent = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: "sid-7")
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v", forked: true)
        let resumeIdx = args.firstIndex(of: "--resume")!
        XCTAssertEqual(args[resumeIdx + 1], "sid-7")
        XCTAssertEqual(args[resumeIdx + 2], "--fork-session")
        // Normal sends never fork.
        XCTAssertFalse(SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v")
            .contains("--fork-session"))
        // Nothing to fork without a session.
        let fresh = Agent(name: "b", emoji: "x", role: "r", model: nil, sessionID: nil)
        XCTAssertFalse(SessionRunner.arguments(for: fresh, prompt: "hi", vaultPath: "/v", forked: true)
            .contains("--fork-session"))
    }

    /// A fork's session ids belong to the throwaway copy — persisting one
    /// would hijack the MAIN conversation.
    func testForkedSendNeverPersistsSessionID() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-fork-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        try store.setSessionID("sid-main", for: "alfredo")
        let agent = try store.loadRoster().agents[0]
        let mock = MockProcess(lines: [
            #"{"type":"system","subtype":"init","session_id":"fork-copy-1"}"#,
            #"{"type":"result","subtype":"success","result":"forked answer","session_id":"fork-copy-1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        for try await _ in runner.send("hi", to: agent, forked: true) {}
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "sid-main",
                       "fork must not steal the main session")
    }

    /// A staged handoff belongs to the MAIN session's next turn — a fork must
    /// neither carry it nor consume it.
    func testForkedSendLeavesPendingHandoffForMainSession() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-forkpend-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        try store.setSessionID("sid-main", for: "alfredo")
        let agent = try store.loadRoster().agents[0]
        try PendingContext(store: store).add("HANDOFF-PAYLOAD", for: "alfredo")

        let mock = ArgsCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"sid-main"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        for try await _ in runner.send("fork question", to: agent, forked: true) {}
        XCTAssertFalse(mock.calls[0].last!.contains("HANDOFF-PAYLOAD"),
                       "fork must not carry the staged handoff")
        for try await _ in runner.send("main question", to: agent) {}
        XCTAssertTrue(mock.calls[1].last!.contains("HANDOFF-PAYLOAD"),
                      "the main session's next turn must still receive it")
    }

    /// The hard rule: no child process may ever see an API key.
    func testClaudeRunnerStripsAPIKeyFromEnvironment() throws {
        setenv("ANTHROPIC_API_KEY", "sk-should-not-survive", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let env = ClaudeProcessRunner.childEnvironment()
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNotNil(env["PATH"])   // the rest of the environment survives
    }
}
