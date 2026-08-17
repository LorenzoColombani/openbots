import XCTest
import Network
@testable import AgencyKit

/// Network egress fence wiring (spec 2026-08-13): who is fenced, what the
/// child's environment and Seatbelt profile look like, and fail-closed.
final class NetworkFenceTests: XCTestCase {
    private func agent(web: Bool? = nil, connectors: [String]? = nil,
                       shell: Bool? = nil) -> Agent {
        Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil,
              connectors: connectors, shell: shell, web: web)
    }

    // MARK: the fencing matrix — derived from capabilities, no new toggle

    func testSealedAgentIsFenced() {
        XCTAssertTrue(agent().isNetworkFenced(forked: false))
    }

    func testWebGrantLiftsTheFence() {
        XCTAssertFalse(agent(web: true).isNetworkFenced(forked: false),
                       "web IS the door — can't allowlist arbitrary browsing")
    }

    func testBrowserConnectorLiftsTheFence() {
        XCTAssertFalse(agent(connectors: ["browser-headless"]).isNetworkFenced(forked: false))
        XCTAssertFalse(agent(connectors: ["browser-visible"]).isNetworkFenced(forked: false))
    }

    func testNetworkConnectorsLiftOnlyWhenWired() {
        // fence review I5: a needsNetwork connector lifts the fence only when
        // it is actually WIRED. gmail/gcal became wired on 2026-08-13
        // (workspace-mcp) — so they now lift it, BY DESIGN…
        XCTAssertFalse(agent(connectors: ["gmail"]).isNetworkFenced(forked: false),
                       "a wired mail connector needs the network")
        XCTAssertFalse(agent(connectors: ["gcal"]).isNetworkFenced(forked: false))
        // …while still-unwired placeholders (no mcpServers yet) must NOT.
        // Local mechanisms stay fenced even when fully wired: AppleScript into
        // Mail.app, the iMessage extension, the shared-folder server.
        XCTAssertTrue(agent(connectors: ["imessage", "filesystem-shared", "mail-app"])
            .isNetworkFenced(forked: false),
            "local mechanisms (AppleScript / local MCP) don't need the network")
        // …while mac-control does NOT: it drives whatever is on screen,
        // browsers included — arbitrary egress by the same logic as a browser.
        XCTAssertFalse(agent(connectors: ["mac-control"]).isNetworkFenced(forked: false),
                       "screen control can drive a browser — it is an egress surface")
    }

    func testUnknownConnectorNeverLiftsTheFence() {
        XCTAssertTrue(agent(connectors: ["mystery-id"]).isNetworkFenced(forked: false),
                      "an id the catalog doesn't know must fail CLOSED")
    }

    func testForksAreAlwaysFenced() {
        // A fork strips web + MCP, so even a browser agent's fork needs only
        // the API — fence it regardless of the parent's grants.
        XCTAssertTrue(agent(web: true, connectors: ["browser-headless"], shell: true)
            .isNetworkFenced(forked: true))
    }

    // MARK: Seatbelt shapes

    func testNetworkRulesAppendToTheFileProfile() {
        let p = SandboxProfile.seatbelt(root: "/r/agency", agentDir: "/r/agency/agents/a",
                                        vault: "/r/agency/vault", shared: "/r/agency/shared",
                                        home: "/Users/x", networkProxyPort: 60443)
        XCTAssertTrue(p.contains("(deny network-outbound (remote ip))"))
        // fence review I3: scoped to the proxy's OWN port — `localhost:*`
        // would open every local service (ssh -D tunnel = zero-effort bypass).
        XCTAssertTrue(p.contains("(allow network-outbound (remote ip \"localhost:60443\"))"))
        XCTAssertFalse(p.contains("localhost:*"), "never the wildcard")
        XCTAssertTrue(p.contains("(deny file-write* (subpath \"/r/agency\"))"),
                      "the file fence rides along for a fenced SHELL agent")
        let deny = p.range(of: "(deny network-outbound (remote ip))")!.lowerBound
        let allow = p.range(of: "(allow network-outbound (remote ip \"localhost:60443\"))")!.lowerBound
        XCTAssertLessThan(deny, allow, "last-match-wins: loopback allow must FOLLOW the deny")
    }

    func testUnfencedShellProfileHasNoNetworkRules() {
        let p = SandboxProfile.seatbelt(root: "/r/agency", agentDir: "/r/agency/agents/a",
                                        vault: "/r/agency/vault", shared: "/r/agency/shared",
                                        home: "/Users/x")
        XCTAssertFalse(p.contains("network-outbound"),
                       "alfredo-class (web+browser+shell) keeps full egress BY THE GRANT")
    }

    func testNetworkOnlyProfileHasNoFileRules() {
        let p = SandboxProfile.networkOnly(proxyPort: 60443)
        XCTAssertTrue(p.contains("(allow default)"))
        XCTAssertTrue(p.contains("(deny network-outbound (remote ip))"))
        XCTAssertTrue(p.contains("localhost:60443"))
        XCTAssertFalse(p.contains("file-write*"),
                       "a fenced NON-shell agent has no Bash — only the network needs Seatbelt")
    }

    /// INTEGRATION: real sandbox-exec — loopback flows, direct egress dies
    /// fast with EPERM (not a timeout — nothing may even leave the box).
    func testSeatbeltBlocksDirectEgressButAllowsLoopback() throws {
        guard SandboxProfile.available else { throw XCTSkip("sandbox-exec unavailable") }
        // Loopback target: a listener that answers instantly.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: params)
        server.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
        let ready = expectation(description: "ready")
        server.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.start(queue: .global())
        wait(for: [ready], timeout: 5)
        defer { server.cancel() }
        let port = server.port!.rawValue

        func run(_ url: String, timeout: String) -> (status: Int32, elapsed: TimeInterval, err: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExec)
            // The profile allows ONLY the test server's port — standing in for
            // the proxy port (fence review I3: port-scoped, never localhost:*).
            p.arguments = ["-p", SandboxProfile.networkOnly(proxyPort: port), "/usr/bin/curl",
                           "-sS", "--connect-timeout", timeout, "-o", "/dev/null", url]
            let err = Pipe()
            p.standardError = err
            let t0 = Date()
            try? p.run(); p.waitUntilExit()
            return (p.terminationStatus, Date().timeIntervalSince(t0),
                    String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        XCTAssertEqual(run("http://127.0.0.1:\(port)/", timeout: "5").status, 0,
                       "the proxy's own loopback port must stay reachable")
        // A DIFFERENT loopback port with a LIVE listener (review I3): a local
        // ssh -D tunnel or dev proxy must NOT be reachable from inside the
        // fence. The second server is genuinely answering — only the fence
        // can explain a failure here.
        let params2 = NWParameters.tcp
        params2.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server2 = try NWListener(using: params2)
        server2.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
        let ready2 = expectation(description: "ready2")
        server2.stateUpdateHandler = { if case .ready = $0 { ready2.fulfill() } }
        server2.start(queue: .global())
        wait(for: [ready2], timeout: 5)
        defer { server2.cancel() }
        let other = run("http://127.0.0.1:\(server2.port!.rawValue)/", timeout: "4")
        XCTAssertNotEqual(other.status, 0,
                          "a LIVE listener on another loopback port must be unreachable from inside the fence")
        XCTAssertLessThan(other.elapsed, 3, "refused by the OS, immediately")
        // RFC-5737 TEST-NET: if the fence FAILED, the SYN goes to a blackhole
        // and curl exits 28 (timeout) — the fence working = instant EPERM.
        let external = run("http://192.0.2.9/", timeout: "4")
        XCTAssertNotEqual(external.status, 0, "direct egress must be blocked")
        XCTAssertNotEqual(external.status, 28, "blocked ≠ timed out — EPERM proves the OS fence, not a slow network")
        XCTAssertLessThan(external.elapsed, 3, "the denial is immediate")
    }

    // MARK: runner wiring (mock process, real EgressProxy — loopback only, free)

    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-nf-\(UUID().uuidString)"))
    }

    private func run(_ store: AgentStore, _ agent: Agent,
                     runner: SessionRunner? = nil) -> (mock: EnvCapturingMock, events: [StreamEvent]) {
        let mock = EnvCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = runner ?? SessionRunner(store: store, process: mock)
        var events: [StreamEvent] = []
        let exp = expectation(description: "send")
        Task { for try await e in runner.send("hi", to: agent) { events.append(e) }; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        return (mock, events)
    }

    func testFencedSealedRunGetsProxyEnvAndNetworkOnlyProfile() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "seal", emoji: "x", role: "r")
        let a = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "seal" })
        let (mock, _) = run(store, a)
        let env = try XCTUnwrap(mock.envs.first)
        XCTAssertTrue(env["HTTPS_PROXY"]?.hasPrefix("http://127.0.0.1:") ?? false,
                      "the child's only road out is the loopback proxy: \(env)")
        XCTAssertEqual(env["HTTPS_PROXY"], env["HTTP_PROXY"])
        XCTAssertEqual(env["NO_PROXY"], "", "an inherited NO_PROXY must not exempt the API host")
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec,
                       "fenced runs are sandbox-wrapped even without shell")
        let profile = try XCTUnwrap(mock.calls.first)[1]
        XCTAssertTrue(profile.contains("(deny network-outbound (remote ip))"))
        XCTAssertFalse(profile.contains("file-write*"), "no Bash → no file section")
        // review I3 wiring: the Seatbelt allow is scoped to the SAME port the
        // env points the child at — the two halves reference one proxy.
        let envPort = try XCTUnwrap(env["HTTPS_PROXY"]?.split(separator: ":").last)
        XCTAssertTrue(profile.contains("localhost:\(envPort)"),
                      "profile port must match the proxy env port")
    }

    /// fence review M16: forks are the ALWAYS-fenced class — assert a fork run
    /// actually gets the proxy env even when its parent has every grant.
    func testForkedRunOfAWebAgentIsFenced() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "webby", emoji: "x", role: "r")
        _ = try store.setWeb(true, for: "webby")
        var a = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "webby" })
        a.sessionID = "sid-1"
        let mock = EnvCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        let exp = expectation(description: "send")
        Task { for try await _ in runner.send("hi", to: a, forked: true) {}; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(mock.envs.first?["HTTPS_PROXY"]?.hasPrefix("http://127.0.0.1:") ?? false,
                      "a fork rides the proxy even when its parent is web-granted")
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec)
    }

    func testWebBrowserAgentRunIsUntouched() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "webby", emoji: "x", role: "r")
        _ = try store.setWeb(true, for: "webby")
        let a = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "webby" })
        let (mock, _) = run(store, a)
        XCTAssertNil(mock.envs.first?["HTTPS_PROXY"], "no proxy for a web-granted agent")
        XCTAssertNotEqual(mock.execs.first, SandboxProfile.sandboxExec,
                          "web + no shell → no sandbox at all (today's behavior)")
    }

    func testFencedShellRunGetsCombinedProfile() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "sh", emoji: "x", role: "r")
        _ = try store.setShell(true, for: "sh")   // shell but NO web → shell-only tier
        let a = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "sh" })
        let (mock, _) = run(store, a)
        let profile = try XCTUnwrap(mock.calls.first)[1]
        XCTAssertTrue(profile.contains("(deny file-write*"), "file fence present")
        XCTAssertTrue(profile.contains("(deny network-outbound (remote ip))"), "network fence present")
        XCTAssertTrue(mock.envs.first?["HTTPS_PROXY"]?.hasPrefix("http://127.0.0.1:") ?? false)
    }

    func testProxyBindFailureFailsClosed() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "seal", emoji: "x", role: "r")
        let a = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "seal" })
        let mock = EnvCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock,
                                   startEgressProxy: { _ in
                                       throw ProcessFailure(status: -1, stderr: "bind failed")
                                   })
        var events: [StreamEvent] = []
        let exp = expectation(description: "send")
        Task { for try await e in runner.send("hi", to: a) { events.append(e) }; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(mock.calls.isEmpty, "fail-CLOSED: a fenced run never launches unfenced")
        XCTAssertTrue(events.contains {
            if case .runError(let d) = $0 { return d.contains("egress proxy") }
            return false
        })
    }
}

/// Mock that captures the environment each run received (the proxy env is the
/// fence's env half — it must be asserted, not assumed).
final class EnvCapturingMock: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var execs: [String] = []
    private(set) var calls: [[String]] = []
    private(set) var envs: [[String: String]] = []
    private let lines: [String]
    init(lines: [String]) { self.lines = lines }

    func runLines(executable: String, arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        runLines(executable: executable, arguments: arguments, cwd: cwd, extraEnvironment: [:])
    }

    func runLines(executable: String, arguments: [String], cwd: URL,
                  extraEnvironment: [String: String]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        execs.append(executable); calls.append(arguments); envs.append(extraEnvironment)
        lock.unlock()
        let lines = self.lines
        return AsyncThrowingStream { c in
            for l in lines { c.yield(l) }
            c.finish()
        }
    }
}
