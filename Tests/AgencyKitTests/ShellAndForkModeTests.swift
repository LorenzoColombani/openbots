import XCTest
@testable import AgencyKit

/// 2026-08-13 round: shell as a per-agent GRANT (live failure: a sealed agent
/// couldn't grep a research project's transcripts) + Grok Bot's READONLY fork mode +
/// the durable send queue.
final class ShellAndForkModeTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-sh-\(UUID().uuidString)"))
    }

    // MARK: shell grant

    func testShellGrantMovesBothFenceHalves() {
        let granted = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil,
                            shell: true)
        let args = SessionRunner.arguments(for: granted, prompt: "hi", vaultPath: "/v")
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
        let disallowed = args[args.firstIndex(of: "--disallowedTools")! + 1]
        XCTAssertTrue(allowed.contains("Bash"), "granted shell must be pre-approved (headless auto-denies)")
        XCTAssertFalse(disallowed.contains("Bash"))
        XCTAssertTrue(disallowed.contains("SendMessage") && disallowed.contains("Skill"),
                      "the other seals stay")
    }

    func testDefaultAgentsStaySealed() {
        let sealed = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil)
        let args = SessionRunner.arguments(for: sealed, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(args[args.firstIndex(of: "--disallowedTools")! + 1].contains("Bash"))
        XCTAssertFalse(args[args.firstIndex(of: "--allowedTools")! + 1].contains("Bash"))
    }

    func testSetShellUpdatesSettingsAndPersona() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let granted = try store.setShell(true, for: "probe")
        XCTAssertEqual(granted.shell, true)

        let settingsURL = store.agentDir("probe")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        var deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny.contains("Bash"), "grant lifts the durable deny")
        XCTAssertTrue(deny.contains("SendMessage"), "only Bash moves")

        var persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("Shell access granted"))
        XCTAssertTrue(persona.contains("Ask Lorenzo BEFORE installing"),
                      "using tools is theirs, changing the machine is his")

        // Revoke restores the seal.
        let sealed = try store.setShell(false, for: "probe")
        XCTAssertNil(sealed.shell)
        deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertTrue(deny.contains("Bash"))
        persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertFalse(persona.contains("Shell access granted"))
    }

    /// Regression found during /dod stage 4 prep: addSkill regenerated
    /// settings WITHOUT the shell flag — a skill tick re-sealed Bash.
    func testAddingASkillDoesNotResealShell() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        _ = try store.setShell(true, for: "probe")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-\(UUID().uuidString).md")
        try "# a skill".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try store.addSkill(from: tmp, to: "probe")

        let settingsURL = store.agentDir("probe")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        let deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny.contains("Bash"), "a skill tick must not revoke the shell grant")
    }

    func testOldRosterDecodesWithShellNil() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.agents[0].shell)
    }

    // MARK: filesystem sandbox (security round 2 — shell agents only)

    private func runOnce(_ store: AgentStore, _ agent: Agent) -> ArgsCapturingMock {
        let mock = ArgsCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        let exp = expectation(description: "send")
        Task { for try await _ in runner.send("hi", to: agent) {}; exp.fulfill() }
        wait(for: [exp], timeout: 5)
        return mock
    }

    func testShellAgentRunIsWrappedInSandboxExec() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "sh", emoji: "x", role: "r")
        _ = try store.setShell(true, for: "sh")
        let agent = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "sh" })
        let mock = runOnce(store, agent)
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec, "a shell run goes through sandbox-exec")
        let a = try XCTUnwrap(mock.calls.first)
        XCTAssertEqual(a[0], "-p", "sandbox-exec -p <profile> …")
        XCTAssertTrue(a[1].contains("(version 1)") && a[1].contains("deny file-write*"),
                      "the Seatbelt profile rides as the -p argument")
        XCTAssertTrue(a.contains("--disallowedTools"), "the claude args still follow the profile")
    }

    func testSealedAgentRunIsNetworkOnlyWrapped() throws {
        // CHANGED by the egress fence (spec 2026-08-13): a sealed agent is now
        // sandbox-wrapped too — but ONLY with the network rules. No Bash means
        // the file fence is already structural; the wrap must never add file
        // rules (that would resurrect the pre-shell-grant breakage class).
        let store = makeStore()
        _ = try store.createAgent(name: "seal", emoji: "x", role: "r")
        let agent = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "seal" })
        let mock = runOnce(store, agent)
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec,
                       "fenced (no web/browser) → network-fence wrap")
        let profile = try XCTUnwrap(mock.calls.first)[1]
        XCTAssertTrue(profile.contains("(deny network-outbound (remote ip))"))
        XCTAssertFalse(profile.contains("file-write*"), "network-ONLY — no file rules for a sealed agent")
    }

    /// Vault pockets (spec 2026-08-13): a shell run's profile carries the
    /// pocket denies for THIS agent — other agents' folders and private
    /// pockets, and non-member team pockets — never its own.
    func testShellRunProfileCarriesPocketDenies() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "sh", emoji: "x", role: "r")
        _ = try store.createAgent(name: "other", emoji: "y", role: "r")
        _ = try store.createTeam("ops", members: ["other"])
        _ = try store.setShell(true, for: "sh")
        let agent = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "sh" })
        let mock = runOnce(store, agent)
        let profile = try XCTUnwrap(mock.calls.first)[1]
        XCTAssertTrue(profile.contains("agents/other"), "other agent's folder denied")
        XCTAssertTrue(profile.contains("vault/private/other"), "other's private pocket denied")
        XCTAssertTrue(profile.contains("vault/teams/ops"), "non-member team pocket denied")
        XCTAssertFalse(profile.contains("vault/private/sh"), "never denies the agent its OWN pocket")
    }

    /// review round 2, issue 5: FAIL-CLOSED. If the sandbox can't be applied, a
    /// shell agent must NOT run unsandboxed — the child never launches.
    func testShellAgentRefusesWhenSandboxUnavailable() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "sh", emoji: "x", role: "r")
        _ = try store.setShell(true, for: "sh")
        let agent = try XCTUnwrap(try store.loadRoster().agents.first { $0.name == "sh" })
        let mock = ArgsCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock, sandboxAvailable: { false })
        var events: [StreamEvent] = []
        let exp = expectation(description: "send")
        Task { for try await e in runner.send("hi", to: agent) { events.append(e) }; exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(mock.calls.isEmpty, "fail-CLOSED: no child process was launched")
        XCTAssertTrue(events.contains {
            if case .runError(let d) = $0 { return d.contains("sandbox-exec unavailable") }
            return false
        }, "the refusal is surfaced to the user")
    }

    // MARK: read-only forks (Grok Bot's READONLY per-run mode)

    func testForkedRunsAreReadOnly() {
        let agent = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: "sid-1",
                          connectors: ["browser-headless"], shell: true)
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v", forked: true)
        // Exact tool-name membership, not substring — "TodoWrite" contains "Write".
        let allowed = args[args.firstIndex(of: "--allowedTools")! + 1]
            .split(separator: ",").map(String.init)
        let disallowed = args[args.firstIndex(of: "--disallowedTools")! + 1]
            .split(separator: ",").map(String.init)
        XCTAssertFalse(allowed.contains("Write"), "a fork races the main run — no writes")
        XCTAssertFalse(allowed.contains("Edit"))
        XCTAssertTrue(disallowed.contains("Write") && disallowed.contains("Edit"))
        // Reviewer #6: these live in the CLI's context regardless of the
        // allowlist, and acceptEdits auto-approves edit tools.
        XCTAssertTrue(disallowed.contains("NotebookEdit") && disallowed.contains("MultiEdit"),
                      "a notebook edit is still a write")
        XCTAssertTrue(disallowed.contains("Bash"), "shell grant does NOT extend to forks")
        XCTAssertFalse(args.contains("--mcp-config"), "connectors don't ride read-only runs")
        XCTAssertFalse(allowed.contains(where: { $0.hasPrefix("mcp__") }),
                       "no inert mcp__ pre-approvals confusing the args")
        XCTAssertTrue(allowed.contains("Read") && allowed.contains("Grep"),
                      "reading and searching is the fork's whole job")
        XCTAssertTrue(allowed.contains("TodoWrite"), "the todo list is not a file write")
    }

    func testForkedPromptCarriesReadOnlyPreamble() {
        let agent = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: "sid-1")
        // The preamble is prepended inside send(); assert via the argument
        // builder's positional prompt after a forked send through a mock.
        // (Cheaper: the prompt transformation is in send — test through it.)
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-fp-\(UUID().uuidString)"))
        _ = try? store.createAgent(name: "a", emoji: "x", role: "r")
        try? store.setSessionID("sid-1", for: "a")
        let mock = ArgsCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"sid-1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        let exp = expectation(description: "forked send")
        Task {
            for try await _ in runner.send("what color?", to: agent, forked: true) {}
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        let prompt = mock.calls[0].last!
        XCTAssertTrue(prompt.hasPrefix("[Read-only subagent run:"),
                      "fork must be told its persona's write instructions don't apply this turn")
        XCTAssertTrue(prompt.contains("what color?"))
    }

    /// Reviewer #6: some library skills are symlinks into live working
    /// folders — copying one hands the agent a live pointer OUTSIDE its fence.
    func testSymlinkedSkillsAreRefusedAndHidden() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-skill-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link)
                try? FileManager.default.removeItem(at: target) }

        XCTAssertThrowsError(try store.addSkill(from: link, to: "probe")) { error in
            XCTAssertEqual(error as? AgencyError, .symlinkedSkill(link.lastPathComponent))
        }
        XCTAssertEqual(store.listSkills(for: "probe"), [], "nothing landed")
    }

    // MARK: durable queue (Grok Bot's send-journal pattern)

    func testQueueSurvivesSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-q-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var q = SendQueue()
        q.enqueue(ChatMessage(author: "lorenzo", kind: .user, text: "first"), thread: "alfredo")
        q.enqueue(ChatMessage(author: "lorenzo", kind: .user, text: "second"), thread: "alfredo")
        q.enqueue(ChatMessage(author: "nina", kind: .relayOut, text: "@bruno hi"), thread: "nina")
        q.save(to: url)

        var restored = SendQueue.load(from: url)
        XCTAssertEqual(restored.items(for: "alfredo").map(\.text), ["first", "second"],
                       "order survives the restart")
        XCTAssertEqual(restored.peek("nina")?.author, "nina", "authorship survives")
        XCTAssertEqual(restored.dequeue("alfredo")?.text, "first")
    }

    func testEmptyQueueRemovesItsFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-q-\(UUID().uuidString).json")
        var q = SendQueue()
        q.enqueue(ChatMessage(author: "lorenzo", kind: .user, text: "x"), thread: "a")
        q.save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        q.dequeue("a")
        q.save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an empty queue leaves nothing behind")
        XCTAssertTrue(SendQueue.load(from: url).isEmpty, "missing file loads as empty, not a crash")
    }
}

/// Apple Events vs Seatbelt (verified live 2026-08-13: a sandboxed process
/// cannot script another app — "privilege violation (-10004)" — even under a
/// profile that allows everything). The conflict is resolved explicitly.
final class AppleEventsFenceTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ae-\(UUID().uuidString)"))
    }
    private func run(_ store: AgentStore, _ agent: Agent) -> (ArgsCapturingMock, [StreamEvent]) {
        let mock = ArgsCapturingMock(lines: [
            #"{"type":"result","subtype":"success","result":"ok","session_id":"s1"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        var events: [StreamEvent] = []
        let exp = expectation(description: "send")
        Task { for try await e in runner.send("hi", to: agent) { events.append(e) }; exp.fulfill() }
        wait(for: [exp], timeout: 10)
        return (mock, events)
    }

    func testShellLessAppleScriptAgentRunsUnsandboxed() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "postie", emoji: "📮", role: "messages")
        _ = try store.setConnectors(["imessage"], for: "postie")
        let a = try XCTUnwrap(try store.loadRoster().agents.first)
        XCTAssertTrue(a.needsAppleEvents)
        let (mock, _) = run(store, a)
        XCTAssertNotEqual(mock.execs.first, SandboxProfile.sandboxExec,
                          "the wrapper would make every iMessage tool fail")
    }

    func testShellAgentKeepsTheSandboxAndIsToldWhy() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "both", emoji: "🧰", role: "everything")
        _ = try store.setConnectors(["imessage"], for: "both")
        _ = try store.setShell(true, for: "both")
        let a = try XCTUnwrap(try store.loadRoster().agents.first)
        let (mock, events) = run(store, a)
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec,
                       "the file fence and the vault pockets are not tradeable")
        XCTAssertTrue(events.contains {
            if case .runError(let d) = $0 { return d.contains("shell access and an AppleScript connector") }
            return false
        }, "the conflict is explained, not silently broken")
    }

    func testOrdinaryAgentsAreUnaffected() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "plain", emoji: "x", role: "r")
        let a = try XCTUnwrap(try store.loadRoster().agents.first)
        XCTAssertFalse(a.needsAppleEvents)
        let (mock, _) = run(store, a)
        XCTAssertEqual(mock.execs.first, SandboxProfile.sandboxExec,
                       "a sealed agent is still network-fenced as before")
    }
}
