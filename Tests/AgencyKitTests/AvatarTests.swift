import XCTest
@testable import AgencyKit

/// Custom avatar image per agent (his ask 2026-08-13) — copied into the agent's
/// own folder, emoji kept as the fallback.
final class AvatarTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-av-\(UUID().uuidString)"))
    }
    private func tempImage(_ ext: String = "png") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("img-\(UUID().uuidString).\(ext)")
        try? Data([0x89, 0x50, 0x4e, 0x47]).write(to: url)   // bytes are irrelevant; the store just copies
        return url
    }

    func testSetAvatarCopiesIntoAgentFolderAndSetsPath() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let img = tempImage("png"); defer { try? FileManager.default.removeItem(at: img) }
        let a = try store.setAvatar(from: img, for: "probe")
        XCTAssertEqual(URL(fileURLWithPath: a.avatarPath ?? "").lastPathComponent, "avatar.png")
        XCTAssertTrue((a.avatarPath ?? "").hasPrefix(store.agentDir("probe").path),
                      "copied INSIDE the agent folder — not a pointer outside the fence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.avatarPath ?? ""))
        XCTAssertEqual(try store.loadRoster().agents.first { $0.name == "probe" }?.avatarPath,
                       a.avatarPath, "persisted in the roster")
    }

    func testFormatSwitchLeavesExactlyOneFile() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let png = tempImage("png"); let jpg = tempImage("jpg")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: jpg) }
        _ = try store.setAvatar(from: png, for: "probe")
        let a = try store.setAvatar(from: jpg, for: "probe")
        XCTAssertEqual(URL(fileURLWithPath: a.avatarPath ?? "").lastPathComponent, "avatar.jpg")
        let avatars = (try FileManager.default.contentsOfDirectory(atPath: store.agentDir("probe").path))
            .filter { $0.hasPrefix("avatar") }
        XCTAssertEqual(avatars, ["avatar.jpg"], "the old avatar.png must be gone — no orphan")
    }

    func testClearAvatarRemovesFileAndPath() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let img = tempImage(); defer { try? FileManager.default.removeItem(at: img) }
        let path = try store.setAvatar(from: img, for: "probe").avatarPath ?? ""
        let cleared = try store.clearAvatar(for: "probe")
        XCTAssertNil(cleared.avatarPath, "reverts to emoji")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "image file removed")
    }

    /// review round 2, issue 6: the removal sweep must delete ONLY avatar images,
    /// never a user's `avatar.md` note (the old `hasPrefix("avatar.")` ate it).
    func testRemovalDoesNotEatUnrelatedFiles() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "probe", emoji: "🧪", role: "tester")
        let dir = store.agentDir("probe")
        let note = dir.appendingPathComponent("avatar.md")
        try "my notes".write(to: note, atomically: true, encoding: .utf8)
        let img = tempImage("png"); defer { try? FileManager.default.removeItem(at: img) }
        _ = try store.setAvatar(from: img, for: "probe")          // triggers the sweep
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "avatar.md note survives a set")
        _ = try store.clearAvatar(for: "probe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "avatar.md note survives a clear")
    }

    func testOldRosterDecodesWithAvatarNil() throws {
        let old = #"{"agents":[{"name":"alfredo","emoji":"🧑‍🍳","role":"r"}]}"#
        let roster = try JSONDecoder().decode(Roster.self, from: Data(old.utf8))
        XCTAssertNil(roster.agents[0].avatarPath, "old rosters have no avatar — emoji is the default")
    }
}
