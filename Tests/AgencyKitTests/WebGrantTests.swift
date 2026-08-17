import XCTest
@testable import AgencyKit

/// 2026-08-13 security round: web (WebSearch + WebFetch) as a per-agent GRANT,
/// off by default. Web is an EGRESS path — the URL a fetch/search sends out can
/// carry vault data past the file fence, and no OS sandbox stops a server-side
/// web tool. Off by default makes a sealed agent airtight; "web means web" is
/// preserved by opting each agent in. Mirrors the shell-grant machinery.
final class WebGrantTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-web-\(UUID().uuidString)"))
    }

    private func allowed(_ args: [String]) -> [String] {
        guard let i = args.firstIndex(of: "--allowedTools") else { return [] }
        return args[i + 1].split(separator: ",").map(String.init)
    }
    private func disallowed(_ args: [String]) -> [String] {
        guard let i = args.firstIndex(of: "--disallowedTools") else { return [] }
        return args[i + 1].split(separator: ",").map(String.init)
    }

    // MARK: default fence

    func testSealedAgentsHaveNoWeb() {
        let sealed = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil)
        let args = SessionRunner.arguments(for: sealed, prompt: "hi", vaultPath: "/v")
        XCTAssertFalse(allowed(args).contains("WebFetch"), "web is grant-gated off")
        XCTAssertFalse(allowed(args).contains("WebSearch"))
        XCTAssertTrue(disallowed(args).contains("WebFetch"), "removed from context, not merely un-approved")
        XCTAssertTrue(disallowed(args).contains("WebSearch"))
    }

    func testDefaultAllowedToolsDropWeb() {
        XCTAssertFalse(AgentStore.defaultAllowedTools.contains("WebFetch"))
        XCTAssertFalse(AgentStore.defaultAllowedTools.contains("WebSearch"))
    }

    // MARK: web grant

    func testWebGrantMovesBothFenceHalves() {
        let granted = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil, web: true)
        let args = SessionRunner.arguments(for: granted, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(allowed(args).contains("WebFetch"), "granted web must be pre-approved (headless auto-denies)")
        XCTAssertTrue(allowed(args).contains("WebSearch"))
        XCTAssertFalse(disallowed(args).contains("WebFetch"))
        XCTAssertFalse(disallowed(args).contains("WebSearch"))
        XCTAssertTrue(disallowed(args).contains("Bash"), "the other seals stay")
        XCTAssertTrue(disallowed(args).contains("SendMessage"))
    }

    func testWebAndShellAreIndependent() {
        // shell without web: Bash lifted, web still sealed.
        let shellOnly = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil, shell: true)
        let a1 = SessionRunner.arguments(for: shellOnly, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(allowed(a1).contains("Bash"))
        XCTAssertTrue(disallowed(a1).contains("WebFetch"), "a shell grant does not open web")

        // web without shell: web lifted, Bash still sealed.
        let webOnly = Agent(name: "b", emoji: "x", role: "r", model: nil, sessionID: nil, web: true)
        let a2 = SessionRunner.arguments(for: webOnly, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(allowed(a2).contains("WebFetch"))
        XCTAssertTrue(disallowed(a2).contains("Bash"), "a web grant does not open shell")

        // both: both lifted.
        let both = Agent(name: "c", emoji: "x", role: "r", model: nil, sessionID: nil, shell: true, web: true)
        let a3 = SessionRunner.arguments(for: both, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(allowed(a3).contains("Bash") && allowed(a3).contains("WebFetch"))
        XCTAssertFalse(disallowed(a3).contains("Bash") || disallowed(a3).contains("WebFetch"))
    }

    func testForkedRunsHaveNoWebEvenWhenGranted() {
        let granted = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: "sid-1", web: true)
        let args = SessionRunner.arguments(for: granted, prompt: "hi", vaultPath: "/v", forked: true)
        XCTAssertFalse(allowed(args).contains("WebFetch"),
                       "a read-only fork stays local — no egress while the main run holds the session")
        XCTAssertFalse(allowed(args).contains("WebSearch"))
        XCTAssertTrue(disallowed(args).contains("WebFetch"))
        XCTAssertTrue(disallowed(args).contains("WebSearch"))
    }

    // MARK: settings + persona wiring

    func testSetWebUpdatesSettingsAndPersona() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let granted = try store.setWeb(true, for: "probe")
        XCTAssertEqual(granted.web, true)

        let settingsURL = store.agentDir("probe")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        func denyList() throws -> [String] {
            (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
                as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        }
        var deny = try denyList()
        XCTAssertFalse(deny.contains("WebFetch"), "grant lifts the durable deny")
        XCTAssertFalse(deny.contains("WebSearch"))
        XCTAssertTrue(deny.contains("Bash"), "only web moves")

        var persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("Web access granted"))
        XCTAssertTrue(persona.contains("door OUT of the machine"), "the exfil reminder rides the grant")
        XCTAssertTrue(persona.contains("web means web"), "granted agent gets the outward-facing vault line")

        // Revoke restores the seal, and points the persona inward.
        let sealed = try store.setWeb(false, for: "probe")
        XCTAssertNil(sealed.web)
        deny = try denyList()
        XCTAssertTrue(deny.contains("WebFetch") && deny.contains("WebSearch"))
        persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertFalse(persona.contains("Web access granted"))
        XCTAssertTrue(persona.contains("no live web access"), "sealed agent is told web is off, not left guessing")
    }

    func testWebAndShellGrantsCoexistInSettings() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        _ = try store.setShell(true, for: "probe")
        _ = try store.setWeb(true, for: "probe")

        let settingsURL = store.agentDir("probe")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        let deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny.contains("Bash"), "shell grant survives a later web grant")
        XCTAssertFalse(deny.contains("WebFetch"), "web grant is present")

        // And revoking web must NOT re-seal shell.
        _ = try store.setWeb(false, for: "probe")
        let deny2 = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny2.contains("Bash"), "revoking web left shell alone")
        XCTAssertTrue(deny2.contains("WebFetch"), "web re-sealed")
    }

    func testAddingASkillDoesNotResealWeb() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        _ = try store.setWeb(true, for: "probe")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-\(UUID().uuidString).md")
        try "# a skill".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try store.addSkill(from: tmp, to: "probe")

        let settingsURL = store.agentDir("probe")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        let deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny.contains("WebFetch"), "a skill tick must not revoke the web grant")
    }

    func testSealedAgentPersonaHasNoWebLine() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let persona = try String(contentsOf: store.agentDir("probe").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("no live web access"))
        XCTAssertFalse(persona.contains("Web access granted"))
    }

    func testOldRosterDecodesWithWebNil() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r","shell":true}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.agents[0].web, "a pre-web roster row is sealed, not accidentally web-enabled")
        XCTAssertEqual(roster.agents[0].shell, true)
    }

    /// review I2: a legacy roster row still lists web in its stored allowedTools
    /// (created before web became a grant). Only the absent `web` grant should
    /// decide — the seal must NOT rely on deny-beating-allow on the command line.
    func testLegacyAllowedToolsNamingWebIsStillSealed() {
        let legacy = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil,
                           allowedTools: ["Read", "Write", "Edit", "Glob", "Grep",
                                          "WebSearch", "WebFetch", "TodoWrite"])
        let args = SessionRunner.arguments(for: legacy, prompt: "hi", vaultPath: "/v")
        XCTAssertFalse(allowed(args).contains("WebFetch"), "stale allow entry is DROPPED, not just out-denied")
        XCTAssertFalse(allowed(args).contains("WebSearch"))
        XCTAssertTrue(disallowed(args).contains("WebFetch") && disallowed(args).contains("WebSearch"))
    }
}
