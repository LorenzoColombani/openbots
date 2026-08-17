import XCTest
@testable import AgencyKit

/// v1.1 containment (his rulings 2026-08-12): sealed by default, Sonnet default
/// with role-based auto-pick, clean per-agent environment, explicit skills.
final class ContainmentTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ct-\(UUID().uuidString)"))
    }

    func testSuggestModelHeuristic() {
        XCTAssertEqual(AgentStore.suggestModel(forRole: "research specialist"), "opus")
        XCTAssertEqual(AgentStore.suggestModel(forRole: "deep strategy architect"), "opus")
        XCTAssertEqual(AgentStore.suggestModel(forRole: "file sorter and label maker"), "haiku")
        XCTAssertEqual(AgentStore.suggestModel(forRole: "writer and brief-assembler"), "sonnet")
        XCTAssertEqual(AgentStore.suggestModel(forRole: ""), "sonnet")
        // Word-anchored (review #4 minor): substrings must not misfire.
        XCTAssertEqual(AgentStore.suggestModel(forRole: "profile writer"), "sonnet")           // not "file"
        XCTAssertEqual(AgentStore.suggestModel(forRole: "internal communications lead"), "sonnet") // not "intern"
        XCTAssertEqual(AgentStore.suggestModel(forRole: "simple research helper"), "opus")     // heavy wins
    }

    func testCreateAgentAppliesPolicyDefaults() throws {
        let store = makeStore()
        let a = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        XCTAssertEqual(a.model, "sonnet")
        XCTAssertEqual(a.allowedTools, AgentStore.defaultAllowedTools)
        XCTAssertFalse(a.allowedTools?.contains("Bash") ?? true, "sealed agents get no shell")

        // Clean environment: per-agent project settings exist and deny ~/.claude writes.
        let settingsURL = store.agentDir("bruno")
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as? [String: Any]
        XCTAssertEqual(json?["outputStyle"] as? String, "default")
        // Style-leak fix 2026-08-14: user-level enabledPlugins reach every
        // session this user starts, and both output-style plugins ship
        // SessionStart hooks that inject "★ Insight" coaching into replies
        // (seen live in a teammate's chat). Explicit false at project scope
        // is the only thing that actually turns them off for teammates —
        // an empty map disables nothing.
        let plugins = json?["enabledPlugins"] as? [String: Bool]
        XCTAssertEqual(plugins?["explanatory-output-style@claude-plugins-official"], false)
        XCTAssertEqual(plugins?["learning-output-style@claude-plugins-official"], false)
        // EXACT rule strings (review #4 C1: a shape-only assertion passed for
        // rules that were documented-inert — Write(path) is never consulted,
        // and a single leading slash anchors at the settings file, not /).
        let deny = ((json?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        // Static seals first (exact strings, exact order), then the pocket rules
        // (root-path dependent — vault/.claude/** Read+Edit for a sole agent).
        let staticSeals = ["Read(~/.claude/**)", "Edit(~/.claude/**)",
                           // Audit review 2026-08-13: the CLI's own config and
                           // Claude Desktop's folder (which holds the extension
                           // CODE agency executes as connector servers).
                           "Read(~/.claude.json)", "Edit(~/.claude.json)",
                           "Read(~/Library/Application Support/Claude/**)",
                           "Edit(~/Library/Application Support/Claude/**)",
                           "Edit(.claude/**)",
                           "Bash", "SendMessage", "ListAgents", "Skill", "WebFetch", "WebSearch",
                           "NotebookEdit", "MultiEdit"]
        XCTAssertEqual(Array(deny.prefix(staticSeals.count)), staticSeals,
                       "web + notebooks joined the durable seal — grant-gated / never lifted")
        let pocketPart = Array(deny.dropFirst(staticSeals.count))
        // Standing seals for a sole agent (full audit 2026-08-13 added the
        // credential stores + control-plane files): vault/.claude, both
        // archive locations, .secrets and the Google tokens dir — Read+Edit
        // each — plus Edit-only seals on the provenance ledger, roster and
        // connectors.json (reads stay open: transparency is the ledger's point).
        XCTAssertEqual(pocketPart.count, 16,
                       "6 Read+Edit pairs (12 rules — R3 added the group-transcript "
                       + "seal /teams/**) + 4 Edit-only seals "
                       + "(ledger/roster/connectors/.obsidian): \(pocketPart)")
        XCTAssertTrue(pocketPart.allSatisfy {
            $0.contains("/vault/.claude/**") || $0.contains("/.archived/**")
                || $0.contains("/.secrets/**") || $0.contains(".google_workspace_mcp")
                || $0.contains(".provenance.jsonl") || $0.contains("roster.json")
                || $0.contains("connectors.json") || $0.contains("/vault/.obsidian/**")
                || $0.contains("/teams/**")
        }, "\(pocketPart)")
        XCTAssertTrue(pocketPart.contains { $0.hasPrefix("Read(") }
                        && pocketPart.contains { $0.hasPrefix("Edit(") },
                      "Read+Edit paired — Read alone doesn't cover NotebookEdit")

        // Skills live where Claude Code actually loads them.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.skillsDir("bruno").path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testExplicitModelOverridesSuggestion() throws {
        let store = makeStore()
        let a = try store.createAgent(name: "nina", emoji: "🔬", role: "research", model: "haiku")
        XCTAssertEqual(a.model, "haiku")
    }

    func testArgumentsCarryAllowedToolsAndDefaultForOldRows() {
        let sealed = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: nil,
                           allowedTools: ["Read", "Grep"])
        let args = SessionRunner.arguments(for: sealed, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(args.contains("--allowedTools"))
        XCTAssertTrue(args.contains("Read,Grep"))
        // --allowedTools only pre-approves; --disallowedTools actually removes
        // the tool from the agent's context (review #4 C2). SendMessage and
        // ListAgents joined Bash after the 2026-08-13 live breach: nina used
        // the session-to-session socket channel, bypassing the visible relay.
        if let i = args.firstIndex(of: "--disallowedTools") {
            // WebFetch/WebSearch joined the removed set (security round
            // 2026-08-13): web is grant-gated off — an egress path a sealed
            // agent has no way past.
            XCTAssertEqual(args[i + 1],
                           "Bash,SendMessage,ListAgents,Skill,WebFetch,WebSearch,NotebookEdit,MultiEdit",
                           "NotebookEdit/MultiEdit removed from EVERY run (pocket review I1), not just forks")
        } else {
            XCTFail("--disallowedTools missing — Bash is only un-approved, not removed")
        }

        // Pre-v1.1 roster rows decode with allowedTools == nil → default set, not unrestricted.
        let old = Agent(name: "b", emoji: "x", role: "r", model: nil, sessionID: nil)
        let oldArgs = SessionRunner.arguments(for: old, prompt: "hi", vaultPath: "/v")
        XCTAssertTrue(oldArgs.contains(AgentStore.defaultAllowedTools.joined(separator: ",")))
    }

    func testOldRosterJSONStillDecodes() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r","sessionID":"s1"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertEqual(roster.agents[0].name, "alfredo")
        XCTAssertNil(roster.agents[0].allowedTools)
    }

    func testUpdateAgentEditsIdentityButKeepsMemory() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        try store.setSessionID("sid-keep", for: "bruno")
        let log = MessageLog(store: store)
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "hello"), thread: "bruno")

        let updated = try store.updateAgent(name: "bruno", emoji: "📚", role: "editor and fact-checker",
                                            model: "opus")
        XCTAssertEqual(updated.role, "editor and fact-checker")
        XCTAssertEqual(updated.model, "opus")
        XCTAssertEqual(updated.sessionID, "sid-keep", "editing identity must not cost memory")

        let persona = try String(contentsOf: store.agentDir("bruno").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("editor and fact-checker"))
        XCTAssertEqual(try log.load(thread: "bruno").count, 1, "history untouched")
    }

    func testPersonaTeachesVaultAsMemory() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "fact-checker")
        let persona = try String(contentsOf: store.agentDir("nina").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("long-term memory"))
        XCTAssertTrue(persona.contains("CHECK THEM ON YOUR OWN"),
                      "agents must consult vault/memory without being told where to look")
    }

    /// Reviewer #5 Important 4: without a roster in the persona, "pass this to
    /// the librarian" is a blind guess at the exact name. Creating an agent
    /// must also update every EXISTING teammate's list.
    func testPersonasCarryTeammateRosterAndStayCurrent() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "fact-checker")
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let bruno = try String(contentsOf: store.agentDir("bruno").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(bruno.contains("@nina 🔬 — fact-checker"), "new agent learns existing team")
        let nina = try String(contentsOf: store.agentDir("nina").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(nina.contains("@bruno ✍️ — writer"),
                      "EXISTING agent's persona regenerated when the team grows")
        XCTAssertFalse(nina.contains("@nina 🔬"), "an agent never lists itself")
    }

    func testAddListRemoveSkill() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-style-\(UUID().uuidString).md")
        try "# Brief style\nAlways five lines.".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try store.addSkill(from: tmp, to: "bruno")
        XCTAssertEqual(store.listSkills(for: "bruno"), [tmp.lastPathComponent])
        try store.removeSkill(tmp.lastPathComponent, from: "bruno")
        XCTAssertEqual(store.listSkills(for: "bruno"), [])
    }
}
