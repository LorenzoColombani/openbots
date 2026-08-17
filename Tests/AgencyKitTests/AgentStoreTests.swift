import XCTest
@testable import AgencyKit

final class AgentStoreTests: XCTestCase {
    func makeStore() throws -> AgentStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-test-\(UUID().uuidString)")
        return AgentStore(rootURL: tmp)
    }

    func testCreateAgentWritesFolderPersonaAndRoster() throws {
        let store = try makeStore()
        let agent = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "research specialist")
        XCTAssertEqual(agent.name, "alfredo")
        let persona = try String(contentsOf: store.agentDir("alfredo").appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(persona.contains("You are Alfredo"))
        XCTAssertTrue(persona.contains("author: alfredo"))       // provenance instructions
        XCTAssertTrue(persona.contains(store.vaultURL.path))     // vault path baked in
        let roster = try store.loadRoster()
        XCTAssertEqual(roster.agents.map(\.name), ["alfredo"])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.vaultURL.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testSetSessionIDPersists() throws {
        let store = try makeStore()
        _ = try store.createAgent(name: "bob", emoji: "🤖", role: "writer")
        try store.setSessionID("abc-123", for: "bob")
        XCTAssertEqual(try store.loadRoster().agents[0].sessionID, "abc-123")
    }

    func testDuplicateNameThrows() throws {
        let store = try makeStore()
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "x")
        XCTAssertThrowsError(try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "x"))
    }

    // MARK: group threads (R3 2026-08-14) — caps + emoji + schema

    private func teamStore() throws -> AgentStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-team-\(UUID().uuidString)")
        let s = AgentStore(rootURL: root)
        for n in ["a1", "a2", "a3", "a4", "a5", "a6", "a7"] {
            _ = try s.createAgent(name: n, emoji: "🧪", role: "r")
        }
        return s
    }

    func testCreateTeamRefusesSevenMembers() throws {
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        XCTAssertThrowsError(try s.createTeam("big",
            members: ["a1", "a2", "a3", "a4", "a5", "a6", "a7"])) {
            XCTAssertEqual($0 as? AgencyError, .teamFull("big"), "Grok's 2–6 cap, adopted")
        }
    }

    func testAddTeamMemberRefusesTheSeventh() throws {
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createTeam("big", members: ["a1", "a2", "a3", "a4", "a5", "a6"])
        XCTAssertThrowsError(try s.addTeamMember("a7", to: "big")) {
            XCTAssertEqual($0 as? AgencyError, .teamFull("big"))
        }
    }

    func testCreateTeamWithZeroMembersStillWorks() throws {
        // CLI pocket-only teams predate group threads and stay legal —
        // the 2-member MINIMUM is a UI/send-level rule, never structural.
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        XCTAssertNoThrow(try s.createTeam("pocketonly"))
    }

    func testTeamEmojiRoundTripsAndStampsSchema3() throws {
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createTeam("launch", members: ["a1", "a2"], emoji: "🚀")
        _ = try s.setTeamEmoji("🛰️", for: "launch")
        XCTAssertEqual(try s.listTeams().first?.emoji, "🛰️")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: s.rootURL.appendingPathComponent("roster.json"))) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 3,
                       "the skew guard must protect the emoji from stale binaries")
    }

    func testCreateTeamDeduplicatesMembers() throws {
        // Review minor: a doubled member would launch two concurrent group
        // runs against ONE claude session.
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        let t = try s.createTeam("dup", members: ["a1", "a2", "a1", "a1"])
        XCTAssertEqual(t.members, ["a1", "a2"], "de-duplicated, order preserved")
    }

    func testRemovingAMemberForgetsTheirCursor() throws {
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createTeam("launch", members: ["a1", "a2"])
        TeamCursorStore(store: s, team: "launch").advance("a1", to: 7)
        _ = try s.removeTeamMember("a1", from: "launch")
        XCTAssertNil(TeamCursorStore(store: s, team: "launch").cursor(for: "a1"),
                     "re-adding a1 later must make them a late joiner")
    }

    func testTeamLogLengthMatchesLoadedMessageCount() throws {
        // Review minor: the eager-cursor baseline and MessageLog.load must
        // agree on the index space — a raw newline count could diverge.
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        let log = MessageLog(store: s)
        for i in 0..<3 {
            try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "m\(i)"),
                           thread: "#launch")
        }
        XCTAssertEqual(s.teamLogLength("launch"),
                       try log.load(thread: "#launch").count)
    }

    func testFoundersGetEagerCursorsAndLateJoinersStartAtLogEnd() throws {
        let s = try teamStore()
        defer { try? FileManager.default.removeItem(at: s.rootURL) }
        _ = try s.createTeam("launch", members: ["a1"])
        XCTAssertEqual(TeamCursorStore(store: s, team: "launch").cursor(for: "a1"), 0,
                       "founders start at the log head")
        // Two messages land, then a2 joins → new-messages-only from now.
        let log = MessageLog(store: s)
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "1"), thread: "#launch")
        try log.append(ChatMessage(author: "a1", kind: .agent, text: "2"), thread: "#launch")
        _ = try s.addTeamMember("a2", to: "launch")
        XCTAssertEqual(TeamCursorStore(store: s, team: "launch").cursor(for: "a2"), 2,
                       "his assumption: late joiners are not back-filled")
    }
}
