import XCTest
@testable import AgencyKit

final class MessageLogTests: XCTestCase {
    func testAppendAndLoadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        let log = MessageLog(store: store)
        let m1 = ChatMessage(ts: Date(timeIntervalSince1970: 1000), author: "lorenzo", kind: .user, text: "hi")
        let m2 = ChatMessage(ts: Date(timeIntervalSince1970: 1001), author: "alfredo", kind: .agent, text: "Alfredo: hello")
        try log.append(m1, thread: "alfredo")
        try log.append(m2, thread: "alfredo")
        XCTAssertEqual(try log.load(thread: "alfredo"), [m1, m2])
    }

    func testLoadMissingThreadIsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        XCTAssertEqual(try MessageLog(store: store).load(thread: "ghost"), [])
    }

    /// Sub-second precision must survive the round trip: ChatMessage.id IS the timestamp,
    /// and SwiftUI's ForEach needs those ids unique. Plain .iso8601 truncates to whole
    /// seconds, which would collide two messages logged in the same second.
    func testSubSecondTimestampsStayDistinct() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        let log = MessageLog(store: store)
        let a = ChatMessage(ts: Date(timeIntervalSince1970: 1000.125), author: "x", kind: .relayOut, text: "a")
        let b = ChatMessage(ts: Date(timeIntervalSince1970: 1000.875), author: "y", kind: .relayIn, text: "b")
        try log.append(a, thread: "t")
        try log.append(b, thread: "t")
        let loaded = try log.load(thread: "t")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNotEqual(loaded[0].id, loaded[1].id)
    }

    /// The log is append-only and human-greppable: one JSON object per line.
    func testStorageIsOneJSONObjectPerLine() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        let log = MessageLog(store: store)
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "one"), thread: "t")
        try log.append(ChatMessage(author: "t", kind: .agent, text: "two"), thread: "t")
        let raw = try String(contentsOf: store.agentDir("t").appendingPathComponent("messages.jsonl"))
        let lines = raw.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        // Each line is independently parseable JSON with the RIGHT values
        // (review #3 rec 3: presence-only checks pass with any author).
        let authors = try lines.map {
            (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["author"] as? String
        }
        XCTAssertEqual(authors, ["lorenzo", "t"])
    }

    // MARK: team threads (R3 2026-08-14)

    func testTeamThreadLogLivesUnderTeamsDirNotAgents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MessageLog(store: AgentStore(rootURL: root))
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "hi team"), thread: "#launch")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("teams/launch/messages.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("agents/#launch").path),
            "an agents/<key> dir would be UNFENCED — the fences enumerate roster agents only")
        XCTAssertEqual(try log.load(thread: "#launch").map(\.text), ["hi team"])
    }

    func testTeamThreadKeyRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MessageLog(store: AgentStore(rootURL: root))
        for bad in ["#../evil", "#Bad Name", "#"] {
            XCTAssertThrowsError(try log.append(
                ChatMessage(author: "x", kind: .user, text: "y"), thread: bad),
                "\(bad) must refuse")
            XCTAssertEqual(try log.load(thread: bad), [])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
    }

    func testArchivedTeamThreadLandsSealedAndDoesNotCrossMatchAgent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MessageLog(store: AgentStore(rootURL: root))
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "old"), thread: "#launch")
        // An AGENT named launch with its own archives must never cross-match.
        try log.append(ChatMessage(author: "lorenzo", kind: .user, text: "agent chat"), thread: "launch")
        _ = try log.archiveThread("launch")
        let dest = try XCTUnwrap(try log.archiveThread("#launch"))
        XCTAssertTrue(dest.path.contains("agents/.archived/threads/#launch-"),
                      "the archive location carries the standing seal")
        XCTAssertEqual(log.archivedSessions(for: "#launch").count, 1,
                       "the '#' prefix keeps team and agent archives apart")
        XCTAssertEqual(log.archivedSessions(for: "launch").count, 1)
        XCTAssertEqual(try log.load(thread: "#launch"), [], "fresh group log after archive")
    }
}
