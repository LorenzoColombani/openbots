import XCTest
@testable import AgencyKit

/// His correction 2026-08-13: "everything is supposed to be visible to the
/// vault, that was the deal". The pockets spec promised he keeps seeing
/// everything in one Obsidian graph, then carved the notebook out and parked
/// the bridge. The notebook is now revealed at
/// `vault/private/<name>/notebook` — inside the Obsidian root — without
/// weakening the fence.
final class NotebookInObsidianTests: XCTestCase {
    private func store() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-nb-\(UUID().uuidString)"))
    }

    func testNotebookIsRevealedInsideTheVault() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createAgent(name: "scribe", emoji: "📓", role: "writer")

        let link = s.rootURL.appendingPathComponent("vault/private/scribe/notebook")
        let dest = try XCTUnwrap(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                                 "the notebook must be reachable from inside the Obsidian vault")
        XCTAssertEqual(dest, "../../../agents/scribe/memory", "relative — the repo stays movable")

        // And it must actually resolve to the real notebook.
        let note = s.memoryDir("scribe").appendingPathComponent("thing-i-learned.md")
        try "# learned\n".write(to: note, atomically: true, encoding: .utf8)
        let viaVault = link.appendingPathComponent("thing-i-learned.md")
        XCTAssertEqual(try String(contentsOf: viaVault, encoding: .utf8), "# learned\n",
                       "Obsidian opens the file through the vault path")
    }

    func testRevealingItDoesNotOpenACrossAgentReadPath() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createAgent(name: "scribe", emoji: "📓", role: "writer")
        _ = try s.createAgent(name: "snoop", emoji: "🕵️", role: "reader")

        // Parse it — the raw file escapes forward slashes, so substring
        // matching on the text silently fails and would have "passed" nothing.
        let data = try Data(contentsOf: s.agentDir("snoop")
            .appendingPathComponent(".claude/settings.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deny = try XCTUnwrap((json["permissions"] as? [String: Any])?["deny"] as? [String])
        // BOTH names for the same bytes must be denied, because whether a tool
        // resolves the symlink first is not ours to decide.
        XCTAssertTrue(deny.contains { $0.hasPrefix("Read(") && $0.hasSuffix("/agents/scribe/**)") },
                      "the real path stays denied — got \(deny)")
        XCTAssertTrue(deny.contains { $0.hasPrefix("Read(") && $0.hasSuffix("/vault/private/scribe/**)") },
                      "the vault path — which now leads to the notebook — must be denied too")
    }

    /// Full audit 2026-08-13: nothing named the credential stores. Reads by
    /// absolute path are the gap --add-dir never closed, and the Gmail REFRESH
    /// TOKENS (~/.google_workspace_mcp) plus the OAuth client (<root>/.secrets)
    /// were readable by every agent — an egress-granted one could walk the
    /// mail account off the machine.
    func testCredentialStoresAreDeniedInBothFenceHalves() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createAgent(name: "plain", emoji: "📄", role: "writer")

        // Settings half (file tools) — everyone, google-granted or not.
        let data = try Data(contentsOf: s.agentDir("plain")
            .appendingPathComponent(".claude/settings.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deny = try XCTUnwrap((json["permissions"] as? [String: Any])?["deny"] as? [String])
        XCTAssertTrue(deny.contains { $0.hasPrefix("Read(") && $0.hasSuffix("/.secrets/**)") },
                      "the OAuth client dir must be Read-denied")
        XCTAssertTrue(deny.contains("Read(~/.google_workspace_mcp/**)"),
                      "the refresh-token dir must be Read-denied")
        XCTAssertTrue(deny.contains { $0.hasPrefix("Edit(") && $0.hasSuffix("/.provenance.jsonl)") },
                      "an agent must not be able to scrub the breach ledger")

        // Seatbelt half (Bash + child processes) — sealed unless the agent
        // holds a Google grant, whose server must read its own tokens.
        let roster = try s.loadRoster()
        let plainPaths = s.deniedPocketPaths(for: "plain", roster: roster)
        XCTAssertTrue(plainPaths.contains { $0.hasSuffix("/.secrets") })
        XCTAssertTrue(plainPaths.contains { $0.hasSuffix("/.google_workspace_mcp") })

        _ = try s.createAgent(name: "poster", emoji: "📮", role: "mail")
        _ = try s.setConnectors(["gmail"], for: "poster")
        let posterPaths = s.deniedPocketPaths(for: "poster", roster: try s.loadRoster())
        XCTAssertTrue(posterPaths.contains { $0.hasSuffix("/.secrets") },
                      ".secrets stays sealed even for the google agent — the server gets creds via env")
        XCTAssertFalse(posterPaths.contains { $0.hasSuffix("/.google_workspace_mcp") },
                       "the google agent's own server (inside this sandbox) must read its tokens")
    }

    /// Group threads (R3): the TRANSCRIPT home <root>/teams/** is sealed for
    /// members and non-members alike, in BOTH halves — while vault/teams/**
    /// (the member-open pocket) must stay open to members. The sharp edge is
    /// that the two paths share the word "teams".
    func testGroupTranscriptsSealedForEveryoneButVaultPocketStaysMemberOpen() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createAgent(name: "member", emoji: "🅰️", role: "r")
        _ = try s.createAgent(name: "outsider", emoji: "🅱️", role: "r")
        _ = try s.createTeam("launch", members: ["member"])

        for agent in ["member", "outsider"] {
            let data = try Data(contentsOf: s.agentDir(agent)
                .appendingPathComponent(".claude/settings.json"))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let deny = try XCTUnwrap((json["permissions"] as? [String: Any])?["deny"] as? [String])
            XCTAssertTrue(deny.contains { $0.hasPrefix("Read(") && $0.hasSuffix("/teams/**)")
                                            && !$0.contains("/vault/") },
                          "\(agent): transcripts Read-sealed (settings half)")
            // The MEMBER keeps the vault pocket open; the outsider does not.
            let vaultTeamDenied = deny.contains { $0.contains("/vault/teams/launch/**") }
            XCTAssertEqual(vaultTeamDenied, agent == "outsider",
                           "\(agent): vault pocket rule must track membership")
            // Seatbelt half: transcripts sealed for both.
            let pockets = s.deniedPocketPaths(for: agent, roster: try s.loadRoster())
            XCTAssertTrue(pockets.contains { $0.hasSuffix("/teams") && !$0.contains("/vault/") },
                          "\(agent): transcripts sealed (Seatbelt half)")
        }
    }

    func testAnExistingRealFolderIsNeverClobbered() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createAgent(name: "scribe", emoji: "📓", role: "writer")
        let link = s.rootURL.appendingPathComponent("vault/private/scribe/notebook")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let precious = link.appendingPathComponent("lorenzos-own-note.md")
        try "mine\n".write(to: precious, atomically: true, encoding: .utf8)

        s.linkNotebookIntoVault("scribe")   // refresh runs this on every launch

        XCTAssertEqual(try String(contentsOf: precious, encoding: .utf8), "mine\n",
                       "runtime data is sacred — a real folder is left alone, not replaced by a link")
    }
}

/// Vault pockets (spec 2026-08-13): four tiers — shared vault (unchanged),
/// vault/private/<agent> (agent + Lorenzo), vault/teams/<team> (members +
/// Lorenzo), agents/<name>/memory/ (owner only). Reads are the real fence work:
/// --add-dir never fenced reads, so per-agent deny rules subtract the pockets.
final class VaultPocketTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-vp-\(UUID().uuidString)"))
    }

    // MARK: roster model

    func testOldRosterDecodesWithTeamsNil() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.teams, "pre-pocket rosters have no teams")
    }

    func testTeamsRoundTrip() throws {
        var roster = Roster(agents: [])
        roster.teams = [Team(name: "kitchen", members: ["alfredo", "nina"])]
        let data = try JSONEncoder().encode(roster)
        let back = try JSONDecoder().decode(Roster.self, from: data)
        XCTAssertEqual(back.teams, roster.teams)
    }

    // MARK: pocket directories

    func testCreateAgentMakesMemoryAndPrivatePocket() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.memoryDir("probe").path, isDirectory: &isDir) && isDir.boolValue,
            "agents/probe/memory/ — the inner notebook")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.privatePocket("probe").path, isDirectory: &isDir) && isDir.boolValue,
            "vault/private/probe/ — Lorenzo-facing private work")
    }

    func testRefreshRetrofitsPocketDirs() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        // Simulate a pre-pocket agent: the dirs don't exist yet.
        try? FileManager.default.removeItem(at: store.memoryDir("probe"))
        try? FileManager.default.removeItem(at: store.privatePocket("probe"))
        try store.refreshAgentConfig(name: "probe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.memoryDir("probe").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.privatePocket("probe").path))
    }

    // MARK: deny-rule generation (pure — the durable fence half)

    private func twoAgentRoster(teams: [Team]? = nil) -> Roster {
        var r = Roster(agents: [
            Agent(name: "a", emoji: "🅰️", role: "r", model: nil, sessionID: nil),
            Agent(name: "b", emoji: "🅱️", role: "r", model: nil, sessionID: nil),
        ])
        r.teams = teams
        return r
    }

    func testPocketRulesDenyOtherAgentsDirAndPrivatePocket() {
        let rules = AgentStore.pocketDenyRules(for: "a", roster: twoAgentRoster(),
                                               root: "/r/agency", home: "/h")
        XCTAssertTrue(rules.contains("Read(//r/agency/agents/b/**)"),
                      "closes the cross-agent READ gap — b's whole folder (memory/ included)")
        XCTAssertTrue(rules.contains("Read(//r/agency/vault/private/b/**)"))
        XCTAssertFalse(rules.contains { $0.contains("/agents/a/") || $0.contains("/private/a/") },
                       "never denies the agent its OWN pockets")
    }

    /// pocket review I1: a Read(path) deny blocks Edit/Write but documented-NOT
    /// NotebookEdit — every pocket rule pairs Read+Edit, like the ~/.claude seals.
    func testEveryPocketRulePairsReadWithEdit() {
        let roster = twoAgentRoster(teams: [Team(name: "kitchen", members: ["b"])])
        let rules = AgentStore.pocketDenyRules(for: "a", roster: roster,
                                               root: "/r/agency", home: "/h")
        let reads = rules.filter { $0.hasPrefix("Read(") }.map { $0.dropFirst("Read".count) }
        let edits = rules.filter { $0.hasPrefix("Edit(") }.map { $0.dropFirst("Edit".count) }
        XCTAssertFalse(reads.isEmpty)
        // The invariant runs ONE way: every Read deny needs its Edit twin
        // (a Read(path) deny covers Edit but not NotebookEdit). Edit-ONLY
        // seals are legitimate — the provenance ledger, roster and
        // connectors.json stay readable on purpose (full audit 2026-08-13).
        XCTAssertTrue(Set(reads).isSubset(of: Set(edits)),
                      "each Read must have an Edit twin — NotebookEdit escape")
        for editOnly in [".provenance.jsonl", "roster.json", "connectors.json",
                         "vault/.obsidian"] {
            XCTAssertTrue(edits.contains { $0.contains(editOnly) },
                          "\(editOnly) must carry a tamper seal")
            XCTAssertFalse(reads.contains { $0.contains(editOnly) },
                           "\(editOnly) stays READABLE — transparency is the point")
        }
        XCTAssertEqual(rules.count, reads.count + edits.count, "nothing but Read/Edit rules")
    }

    /// pocket review M5: vault/.claude auto-loads (skills/agents, live reload)
    /// into EVERY teammate session — no agent may plant one, sole agents included.
    func testVaultDotClaudeSealedForEveryone() throws {
        let rules = AgentStore.pocketDenyRules(
            for: "a", roster: Roster(agents: [twoAgentRoster().agents[0]]),
            root: "/r/agency", home: "/h")
        XCTAssertTrue(rules.contains("Read(//r/agency/vault/.claude/**)"))
        XCTAssertTrue(rules.contains("Edit(//r/agency/vault/.claude/**)"))
        // …and in the shell half:
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        let denied = store.deniedPocketPaths(for: "a", roster: try store.loadRoster())
        XCTAssertTrue(denied.contains(store.vaultURL.appendingPathComponent(".claude").path))
    }

    /// pocket review M1: the ROOT path is user-chosen and spliced into a
    /// gitignore-style pattern — unescaped glob metacharacters fail OPEN.
    func testGlobMetacharactersInRootAreEscaped() {
        let rules = AgentStore.pocketDenyRules(for: "a", roster: twoAgentRoster(),
                                               root: "/r/we[i]rd*dir", home: "/h")
        XCTAssertTrue(rules.contains("Read(//r/we\\[i\\]rd\\*dir/agents/b/**)"), "\(rules)")
    }

    func testPocketRulesDenyNonMemberTeamPocketsOnly() {
        let roster = twoAgentRoster(teams: [Team(name: "kitchen", members: ["b"])])
        let aRules = AgentStore.pocketDenyRules(for: "a", roster: roster,
                                                root: "/r/agency", home: "/h")
        let bRules = AgentStore.pocketDenyRules(for: "b", roster: roster,
                                                root: "/r/agency", home: "/h")
        XCTAssertTrue(aRules.contains("Read(//r/agency/vault/teams/kitchen/**)"),
                      "a is not in kitchen — denied")
        XCTAssertFalse(bRules.contains { $0.contains("/teams/kitchen/") },
                       "b is a member — never denied its own team pocket")
    }

    func testPocketRulesAnchorTildeWhenRootUnderHome() {
        // Production shape: the agency root lives under home, and a plain
        // "/Users/…" single-slash rule would anchor at the SETTINGS FILE, not
        // the fs root (documented gotcha) — so under home it must be ~-anchored.
        let rules = AgentStore.pocketDenyRules(for: "a", roster: twoAgentRoster(),
                                               root: "/h/somewhere/agency", home: "/h")
        XCTAssertTrue(rules.contains("Read(~/somewhere/agency/agents/b/**)"), "\(rules)")
    }

    func testPocketRulesAbsoluteAnchorOutsideHome() {
        // Test/scratch shape: //-prefixed = documented absolute-path form.
        let rules = AgentStore.pocketDenyRules(for: "a", roster: twoAgentRoster(),
                                               root: "/private/tmp/scratch", home: "/h")
        XCTAssertTrue(rules.contains("Read(//private/tmp/scratch/agents/b/**)"), "\(rules)")
    }

    // MARK: settings integration (regenerated for ALL agents on roster change)

    private func denyList(_ store: AgentStore, _ name: String) throws -> [String] {
        let url = store.agentDir(name).appendingPathComponent(".claude/settings.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let perms = obj?["permissions"] as? [String: Any]
        return perms?["deny"] as? [String] ?? []
    }

    func testCreatingSecondAgentAddsPocketRulesToBoth() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        // Creating b must regenerate a's settings too — a new teammate means a
        // NEW deny for every existing agent.
        XCTAssertTrue(try denyList(store, "a").contains { $0.contains("/agents/b/") },
                      "a's settings deny b's folder")
        XCTAssertTrue(try denyList(store, "b").contains { $0.contains("/agents/a/") },
                      "b's settings deny a's folder")
        XCTAssertTrue(try denyList(store, "a").contains { $0.contains("/vault/private/b/") })
    }

    func testTeamMembershipChangeRegeneratesAllSettings() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        _ = try store.createTeam("kitchen", members: ["b"])
        XCTAssertTrue(try denyList(store, "a").contains { $0.contains("/vault/teams/kitchen/") },
                      "non-member a is denied the pocket")
        XCTAssertFalse(try denyList(store, "b").contains { $0.contains("/vault/teams/kitchen/") },
                       "member b is not")
        try store.addTeamMember("a", to: "kitchen")
        XCTAssertFalse(try denyList(store, "a").contains { $0.contains("/vault/teams/kitchen/") },
                       "joining lifts the deny")
        try store.removeTeamMember("a", from: "kitchen")
        XCTAssertTrue(try denyList(store, "a").contains { $0.contains("/vault/teams/kitchen/") },
                      "leaving restores it")
    }

    func testExistingSealsSurvivePocketRules() throws {
        // The pocket rules ADD to agentDenyRules — the Bash/web/side-channel
        // seals must all still be present afterwards.
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        let deny = try denyList(store, "a")
        for seal in ["Bash", "SendMessage", "ListAgents", "Skill", "WebFetch", "WebSearch"] {
            XCTAssertTrue(deny.contains(seal), "\(seal) seal must survive")
        }
    }

    // MARK: teams API

    func testCreateTeamMakesPocketAndValidatesNames() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        let team = try store.createTeam("kitchen", members: ["a"])
        XCTAssertEqual(team.members, ["a"])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.teamPocket("kitchen").path, isDirectory: &isDir) && isDir.boolValue,
            "vault/teams/kitchen/ created")
        XCTAssertThrowsError(try store.createTeam("Bad Name")) { _ in }
        XCTAssertThrowsError(try store.createTeam("kitchen")) { error in
            XCTAssertEqual(error as? AgencyError, .teamExists("kitchen"))
        }
        XCTAssertThrowsError(try store.createTeam("crew", members: ["ghost"])) { error in
            XCTAssertEqual(error as? AgencyError, .agentNotFound("ghost"),
                           "members must be real agents")
        }
    }

    func testDeniedPocketPathsForTheShellFence() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        _ = try store.createTeam("kitchen", members: ["b"])
        let roster = try store.loadRoster()
        let denied = store.deniedPocketPaths(for: "a", roster: roster)
        XCTAssertTrue(denied.contains(store.agentDir("b").path))
        XCTAssertTrue(denied.contains(store.privatePocket("b").path))
        XCTAssertTrue(denied.contains(store.teamPocket("kitchen").path))
        XCTAssertFalse(denied.contains(store.agentDir("a").path), "own folder never denied")
        XCTAssertFalse(denied.contains(store.privatePocket("a").path))
        let bDenied = store.deniedPocketPaths(for: "b", roster: roster)
        XCTAssertFalse(bDenied.contains(store.teamPocket("kitchen").path), "member keeps its pocket")
    }

    // MARK: personas teach the tiers

    func testPersonaTeachesPocketTiersAndRelayHygiene() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        _ = try store.createTeam("kitchen", members: ["a", "b"])
        _ = try store.createTeam("ops", members: ["b"])
        let persona = try String(contentsOf: store.agentDir("a").appendingPathComponent("CLAUDE.md"),
                                 encoding: .utf8)
        XCTAssertTrue(persona.contains(store.memoryDir("a").path), "notebook path taught")
        XCTAssertTrue(persona.contains(store.privatePocket("a").path), "private pocket taught")
        XCTAssertTrue(persona.contains(store.teamPocket("kitchen").path), "member pocket taught")
        XCTAssertFalse(persona.contains(store.teamPocket("ops").path),
                       "a non-member is never pointed at a pocket it cannot read")
        XCTAssertTrue(persona.contains("RELAY line"), "relay hygiene for private tiers")
    }

    // MARK: team-aware provenance alert suppression

    private func record(path: String, agent: String, prev: String?, claimed: String? = nil,
                        deleted: Bool? = nil) -> ProvenanceRecord {
        ProvenanceRecord(path: path, agent: agent, at: Date(timeIntervalSince1970: 0),
                         sha256: "h", claimedAuthor: claimed, previousAgent: prev,
                         deleted: deleted, concurrent: nil)
    }

    func testTeamPocketCollaborationSuppressesTheAlert() {
        let teams = [Team(name: "kitchen", members: ["a", "b"])]
        let r = record(path: "teams/kitchen/menu.md", agent: "a", prev: "b")
        XCTAssertTrue(r.isSuspicious, "the raw record still reads as a cross-agent rewrite")
        XCTAssertTrue(VaultProvenance.isTeamCollaboration(r, teams: teams),
                      "…but members editing members' notes is the pocket working as designed")
    }

    func testTeamPocketDeletionByMemberSuppressed() {
        let teams = [Team(name: "kitchen", members: ["a", "b"])]
        let r = record(path: "teams/kitchen/menu.md", agent: "a", prev: "b", deleted: true)
        XCTAssertTrue(VaultProvenance.isTeamCollaboration(r, teams: teams))
    }

    func testForgedBylineStillFlagsInsideATeamPocket() {
        let teams = [Team(name: "kitchen", members: ["a", "b"])]
        let r = record(path: "teams/kitchen/menu.md", agent: "a", prev: "b", claimed: "lorenzo")
        XCTAssertFalse(VaultProvenance.isTeamCollaboration(r, teams: teams),
                       "forgery is forgery, teammates or not")
    }

    func testNonMemberWriterNeverSuppressed() {
        let teams = [Team(name: "kitchen", members: ["b"])]
        let r = record(path: "teams/kitchen/menu.md", agent: "a", prev: "b")
        XCTAssertFalse(VaultProvenance.isTeamCollaboration(r, teams: teams))
    }

    func testPrivatePocketPathNeverSuppressed() {
        let teams = [Team(name: "kitchen", members: ["a", "b"])]
        let r = record(path: "private/b/x.md", agent: "a", prev: "b")
        XCTAssertFalse(VaultProvenance.isTeamCollaboration(r, teams: teams),
                       "a write recorded in someone's PRIVATE pocket is a fence breach, not teamwork")
    }

    /// /dod probe finding 2026-08-13: `team remove ops pa` for a NON-member
    /// printed "pa left ops" — a lie. The API stays idempotent, but it reports
    /// whether anything actually changed so the CLI can tell the truth.
    func testMembershipNoOpsReportHonestly() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createTeam("kitchen")
        XCTAssertTrue(try store.addTeamMember("a", to: "kitchen"), "first add changes state")
        XCTAssertFalse(try store.addTeamMember("a", to: "kitchen"), "re-add is a no-op")
        XCTAssertTrue(try store.removeTeamMember("a", from: "kitchen"), "removal changes state")
        XCTAssertFalse(try store.removeTeamMember("a", from: "kitchen"), "re-remove is a no-op")
    }

    // MARK: pocket-breach detection (pocket review I2 — the ledger as alarm)

    func testNewFileInAnothersPrivatePocketIsABreach() {
        // The I2 gap: a NEW file has previousAgent nil — no rewrite flag fires.
        let r = record(path: "private/b/planted.md", agent: "a", prev: nil)
        XCTAssertFalse(r.isSuspicious, "rewrite-based flags stay silent — the gap")
        XCTAssertTrue(VaultProvenance.isPocketBreach(r, teams: []), "…the breach detector fires")
        XCTAssertTrue(VaultProvenance.pocketBreachAlert(r).contains("fence breach"))
    }

    func testOwnPrivatePocketWriteIsNotABreach() {
        XCTAssertFalse(VaultProvenance.isPocketBreach(
            record(path: "private/a/mine.md", agent: "a", prev: nil), teams: []))
    }

    func testNonMemberTeamWriteIsABreach() {
        let teams = [Team(name: "kitchen", members: ["b"])]
        XCTAssertTrue(VaultProvenance.isPocketBreach(
            record(path: "teams/kitchen/new.md", agent: "a", prev: nil), teams: teams))
        XCTAssertFalse(VaultProvenance.isPocketBreach(
            record(path: "teams/kitchen/new.md", agent: "b", prev: nil), teams: teams),
            "a member creating a team note is the pocket working")
    }

    func testUnregisteredTeamPocketWriteIsABreach() {
        // Nobody creates pockets by hand except Lorenzo — a write into a
        // teams/ dir with no roster row is suspicious.
        XCTAssertTrue(VaultProvenance.isPocketBreach(
            record(path: "teams/ghost/x.md", agent: "a", prev: nil), teams: []))
    }

    func testConcurrentRecordsAreNeverBreachFlagged() {
        // Attribution is unreliable during overlap — a false breach accusation
        // is worse than a missed alert (the review-I1 principle).
        var r = record(path: "private/b/x.md", agent: "a", prev: nil)
        r.concurrent = true
        XCTAssertFalse(VaultProvenance.isPocketBreach(r, teams: []))
    }

    func testSharedVaultWriteIsNeverABreach() {
        XCTAssertFalse(VaultProvenance.isPocketBreach(
            record(path: "briefs/2026-08-13.md", agent: "a", prev: "b"), teams: []))
    }

    // MARK: roster version-skew guard (pocket review I3 — fail CLOSED)

    func testRosterFromNewerBinaryRefusesToSave() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")   // creates root + roster
        let rosterURL = store.rootURL.appendingPathComponent("roster.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: rosterURL)) as! [String: Any]
        obj["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: obj).write(to: rosterURL)
        XCTAssertThrowsError(try store.createAgent(name: "b", emoji: "🅱️", role: "r")) { error in
            XCTAssertEqual(error as? AgencyError, .rosterNewerSchema(99),
                           "an older binary must REFUSE to rewrite a newer roster — silent field loss unfences pockets")
        }
    }

    func testSavedRosterIsStampedWithCurrentSchema() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        XCTAssertEqual(try store.loadRoster().schemaVersion, Roster.currentSchemaVersion)
    }

    /// pocket review I1 follow-through: the fork path appends its read-only
    /// removals without duplicating the base seals.
    func testForkDisallowedListHasNoDuplicates() {
        let agent = Agent(name: "a", emoji: "x", role: "r", model: nil, sessionID: "sid-1")
        let args = SessionRunner.arguments(for: agent, prompt: "hi", vaultPath: "/v", forked: true)
        let disallowed = args[args.firstIndex(of: "--disallowedTools")! + 1].split(separator: ",")
        XCTAssertEqual(disallowed.count, Set(disallowed).count, "no dupes: \(disallowed)")
        XCTAssertTrue(disallowed.contains("NotebookEdit") && disallowed.contains("Write"))
    }

    func testRemovingMemberNeverDeletesThePocket() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createTeam("kitchen", members: ["a"])
        let note = store.teamPocket("kitchen").appendingPathComponent("recipe.md")
        try "secret sauce".write(to: note, atomically: true, encoding: .utf8)
        try store.removeTeamMember("a", from: "kitchen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path),
                      "runtime data is sacred — membership changes never touch the folder")
    }
}
