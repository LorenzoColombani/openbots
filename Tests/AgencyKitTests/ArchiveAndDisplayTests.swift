import XCTest
@testable import AgencyKit

/// Item 6 (his calls 2026-08-13): rename is DISPLAY-ONLY (the handle is the
/// address — renaming the folder orphans the claude session), delete is
/// ARCHIVE-ONLY (runtime data is sacred), and the archive locations get a
/// standing fence so retirees' files aren't readable once their per-agent
/// rules disappear with the roster row.
final class ArchiveAndDisplayTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ad-\(UUID().uuidString)"))
    }

    // MARK: display-only rename

    func testDisplayNameSetsAndClears() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "🖋", role: "writer")
        let named = try store.updateAgent(name: "bruno", displayName: "Bruno the Writer")
        XCTAssertEqual(named.displayName, "Bruno the Writer")
        XCTAssertEqual(named.display, "Bruno the Writer")
        XCTAssertEqual(named.name, "bruno", "the handle NEVER moves")
        let cleared = try store.updateAgent(name: "bruno", displayName: "  ")
        XCTAssertNil(cleared.displayName, "whitespace clears")
        XCTAssertEqual(cleared.display, "Bruno", "falls back to the capitalized handle")
    }

    func testOldRosterDecodesWithDisplayNameNil() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.agents[0].displayName)
        XCTAssertEqual(roster.agents[0].display, "Alfredo")
    }

    func testPersonaCarriesDisplayNameButKeepsHandles() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "🖋", role: "writer")
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "checker")
        _ = try store.updateAgent(name: "bruno", displayName: "Bruno the Writer")
        let own = try String(contentsOf: store.agentDir("bruno").appendingPathComponent("CLAUDE.md"),
                             encoding: .utf8)
        XCTAssertTrue(own.contains("You are Bruno the Writer,"), "self-identity uses the display name")
        let teammate = try String(contentsOf: store.agentDir("nina").appendingPathComponent("CLAUDE.md"),
                                  encoding: .utf8)
        XCTAssertTrue(teammate.contains("@bruno (\"Bruno the Writer\")"),
                      "teammates see the display name but keep the @handle — RELAY needs the handle")
    }

    // MARK: archive, never rm

    func testArchiveMovesEverythingAndRegeneratesFences() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "🖋", role: "writer")
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "checker")
        _ = try store.createTeam("kitchen", members: ["bruno", "nina"])
        let note = store.privatePocket("bruno").appendingPathComponent("secret.md")
        try "private".write(to: note, atomically: true, encoding: .utf8)
        let convo = store.agentDir("bruno").appendingPathComponent("messages.jsonl")
        try "{}".write(to: convo, atomically: true, encoding: .utf8)

        let dest = try store.archiveAgent("bruno", now: Date(timeIntervalSince1970: 1_755_000_000))

        // Nothing destroyed — folder + pocket moved, contents intact.
        XCTAssertTrue(dest.path.contains("agents/.archived/bruno-"), "\(dest.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("messages.jsonl").path),
                      "the conversation survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.agentDir("bruno").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.privatePocket("bruno").path))
        let archivedPockets = try FileManager.default.contentsOfDirectory(
            atPath: store.vaultURL.appendingPathComponent("private/.archived").path)
        XCTAssertEqual(archivedPockets.count, 1, "the private pocket moved to the vault archive")

        // Roster + team membership dropped; the rest re-fenced.
        let roster = try store.loadRoster()
        XCTAssertNil(roster.agents.first { $0.name == "bruno" })
        XCTAssertEqual(roster.teams?.first?.members, ["nina"])
        let settingsURL = store.agentDir("nina").appendingPathComponent(".claude/settings.json")
        let deny = (((try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            as? [String: Any])?["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        XCTAssertFalse(deny.contains { $0.contains("/agents/bruno/") },
                       "no stale per-agent rule for the retiree")
    }

    func testArchiveLocationsHaveAStandingFence() throws {
        // The retiree has no roster row to hang a rule on — the archive dirs
        // are sealed for EVERYONE, always (rules + Seatbelt half).
        let store = makeStore()
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "checker")
        let rules = AgentStore.pocketDenyRules(
            for: "nina", roster: try store.loadRoster(), root: "/r/agency", home: "/h")
        XCTAssertTrue(rules.contains("Read(//r/agency/agents/.archived/**)"))
        XCTAssertTrue(rules.contains("Edit(//r/agency/agents/.archived/**)"))
        XCTAssertTrue(rules.contains("Read(//r/agency/vault/private/.archived/**)"))
        let denied = store.deniedPocketPaths(for: "nina", roster: try store.loadRoster())
        XCTAssertTrue(denied.contains(store.rootURL.appendingPathComponent("agents/.archived").path))
        XCTAssertTrue(denied.contains(store.vaultURL.appendingPathComponent("private/.archived").path))
    }

    func testArchiveUnknownAgentThrows() {
        XCTAssertThrowsError(try makeStore().archiveAgent("ghost")) { error in
            XCTAssertEqual(error as? AgencyError, .agentNotFound("ghost"))
        }
    }
}

/// Session-scoped chats (his ask 2026-08-13 #6): fresh session = clean chat;
/// the old one rotates into the fence-sealed archive, listed newest-first.
extension ArchiveAndDisplayTests {
    func testArchiveThreadRotatesAndLists() throws {
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-sc-\(UUID().uuidString)"))
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "checker")
        let log = MessageLog(store: store)
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "hello"), thread: "nina")
        try log.append(ChatMessage(author: "nina", kind: .agent, text: "Nina: hi"), thread: "nina")

        let dest = try XCTUnwrap(log.archiveThread("nina", now: Date(timeIntervalSince1970: 1_755_100_000)))
        XCTAssertTrue(dest.path.contains("agents/.archived/threads/nina-"),
                      "fence-sealed location — the fresh session must not be able to re-read it")
        XCTAssertTrue(try log.load(thread: "nina").isEmpty, "the visible chat starts clean")
        XCTAssertEqual(MessageLog.loadArchive(dest).map(\.text), ["hello", "Nina: hi"],
                       "nothing lost — read-only history")
        XCTAssertEqual(log.archivedSessions(for: "nina"), [dest])
        XCTAssertNil(try log.archiveThread("nina"), "no chat → no rotation, not an empty file")
    }

    func testArchivedSessionPrefixIsHyphenAnchored() throws {
        let store = AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-sc-\(UUID().uuidString)"))
        _ = try store.createAgent(name: "nina", emoji: "🔬", role: "a")
        _ = try store.createAgent(name: "nina2", emoji: "🔭", role: "b")
        let log = MessageLog(store: store)
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "x"), thread: "nina2")
        _ = try log.archiveThread("nina2")
        XCTAssertTrue(log.archivedSessions(for: "nina").isEmpty,
                      "nina must not list nina2's sessions")
    }
}
