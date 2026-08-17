import XCTest
@testable import AgencyKit

/// Connectors spec 2026-08-13: app-wide catalog (inventory), per-agent grants
/// (capability), --strict-mcp-config on EVERY invocation.
final class ConnectorsTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-cn-\(UUID().uuidString)"))
    }

    func testStrictMCPConfigRidesEveryInvocation() {
        let sealed = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil)
        let args = SessionRunner.arguments(for: sealed, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(args.contains("--strict-mcp-config"),
                      "zero-grant agents must not inherit user-scope MCP servers either")
        XCTAssertFalse(args.contains("--mcp-config"), "no grants → no config file to load")
    }

    func testGrantedConnectorAddsConfigAndToolApproval() {
        let granted = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil,
                            connectors: ["browser-headless"])
        let args = SessionRunner.arguments(for: granted, prompt: "hi", vaultPath: "/v")
        let i = args.firstIndex(of: "--mcp-config")
        XCTAssertNotNil(i)
        XCTAssertEqual(args[i! + 1], ".claude/mcp.json", "relative on purpose — cwd IS the agent dir")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let toolsArg = args[args.firstIndex(of: "--allowedTools")! + 1]
        XCTAssertTrue(toolsArg.contains("mcp__playwright"),
                      "headless prompts auto-deny — the server must be pre-approved")
    }

    func testSetConnectorsWritesMCPJSONAndPersona() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let updated = try store.setConnectors(["browser-headless"], for: "probe")
        XCTAssertEqual(updated.connectors, ["browser-headless"])

        let mcpURL = store.agentDir("probe").appendingPathComponent(".claude/mcp.json")
        let json = try String(contentsOf: mcpURL)
        XCTAssertTrue(json.contains("\"playwright\""))
        XCTAssertFalse(json.contains(Connector.agentDirToken), "token must be substituted")
        XCTAssertTrue(json.contains(store.agentDir("probe").path + "/.browser/headless"),
                      "per-agent browser profile — isolation is the point")

        let persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("Connectors granted to you"))
        XCTAssertTrue(persona.contains("retry it there"), "the headless→visible escalation rule")
    }

    func testRevokingAllRemovesFileAndClearsRoster() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        _ = try store.setConnectors(["browser-headless"], for: "probe")
        let cleared = try store.setConnectors([], for: "probe")
        XCTAssertNil(cleared.connectors)
        let mcpURL = store.agentDir("probe").appendingPathComponent(".claude/mcp.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mcpURL.path))
        let persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertFalse(persona.contains("Connectors granted to you"))
    }

    /// LIVE BRICK 2026-08-13 (reported from a real run): bruno granted ONLY the
    /// imessage placeholder (no real servers) → generator wrote no mcp.json,
    /// runner still passed --mcp-config → claude exited 1, every send failed.
    /// The file must exist whenever GRANTS exist — empty mcpServers is valid.
    /// (Every catalog entry is wired since 2026-08-13, so the stand-in is a
    /// connector whose SETUP is incomplete — same shape, same guarantee.)
    func testPlaceholderOnlyGrantStillWritesAValidMCPFile() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        // Every catalog entry is wired now, so the stand-in for "granted but
        // no server" is a Google connector with its setup incomplete (no
        // .secrets/ client here) — the generator omits the server, and the
        // FILE must still exist.
        _ = try store.setConnectors(["gmail"], for: "bruno")
        let mcpURL = store.agentDir("bruno").appendingPathComponent(".claude/mcp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mcpURL.path),
                      "the runner passes --mcp-config whenever grants exist — the file must too")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: mcpURL)) as? [String: Any]
        XCTAssertNotNil(obj?["mcpServers"] as? [String: Any])
        XCTAssertTrue((obj?["mcpServers"] as? [String: Any])?.isEmpty ?? false)
    }

    func testUnknownConnectorIDsAreDropped() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let updated = try store.setConnectors(["no-such-connector"], for: "probe")
        XCTAssertNil(updated.connectors)
    }

    func testCatalogEnableDisableRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = ConnectorCatalog(rootURL: root)
        XCTAssertEqual(catalog.enabledIDs(), [])
        try catalog.setEnabled("browser-headless", true)
        try catalog.setEnabled("gmail", true)
        XCTAssertEqual(catalog.enabledIDs(), ["browser-headless", "gmail"])
        try catalog.setEnabled("gmail", false)
        XCTAssertEqual(ConnectorCatalog(rootURL: root).enabledIDs(), ["browser-headless"],
                       "state survives a fresh instance — it's on disk")
    }

    func testOldRosterWithoutConnectorsDecodes() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.agents[0].connectors, "old rows = sealed, not crashed")
    }
}

/// A bundled .app inherits NO shell PATH (live 2026-08-13: Hermes reported
/// "the iMessage tools just disconnected from the MCP server" — which is what
/// a server that never started looks like from inside the agent).
final class ExecutableResolutionTests: XCTestCase {
    func testKnownRuntimesResolveToAbsolutePaths() {
        for cmd in ["node", "npx", "uvx"] {
            let resolved = Executables.resolve(cmd)
            guard resolved != cmd else { continue }   // not installed on this Mac
            XCTAssertTrue(resolved.hasPrefix("/"), "\(cmd) → \(resolved)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved))
        }
    }

    func testAbsoluteAndUnknownCommandsPassThrough() {
        XCTAssertEqual(Executables.resolve("/usr/bin/env"), "/usr/bin/env")
        XCTAssertEqual(Executables.resolve("totally-made-up"), "totally-made-up",
                       "better a clear 'not found' than a wrong guess")
    }

    func testSearchPathCoversTheUsualHomes() {
        let p = Executables.searchPath
        XCTAssertTrue(p.contains("/opt/homebrew/bin"))
        XCTAssertTrue(p.contains("/.local/bin"), "uvx lives here")
        XCTAssertEqual(p.split(separator: ":").count, Set(p.split(separator: ":")).count,
                       "no duplicate entries")
    }

    func testGeneratedConfigCarriesAbsoluteCommandAndPATH() throws {
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-exe-\(UUID().uuidString)"))
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        _ = try store.setConnectors(["browser-headless"], for: "probe")
        let url = store.agentDir("probe").appendingPathComponent(".claude/mcp.json")
        let servers = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any])?["mcpServers"] as? [String: Any])
        let playwright = try XCTUnwrap(servers["playwright"] as? [String: Any])
        let command = try XCTUnwrap(playwright["command"] as? String)
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npx") {
            XCTAssertTrue(command.hasPrefix("/"), "a GUI app can't find a bare 'npx': \(command)")
        }
        XCTAssertNotNil((playwright["env"] as? [String: String])?["PATH"],
                        "servers that shell out to siblings need a real PATH too")
    }
}
