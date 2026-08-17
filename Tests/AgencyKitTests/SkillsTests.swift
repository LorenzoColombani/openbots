import XCTest
@testable import AgencyKit

/// R6 — the agency skills library (structure audit). Grants still COPY into
/// each agent's fence; the library adds a canonical source and the re-push
/// that the copy-only model made impossible.
final class SkillsLibraryTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-lib-\(UUID().uuidString)"))
    }
    private func tempSkill(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-\(UUID().uuidString).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLibraryHoldsTheCanonicalCopyAndRePushesIt() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "a", emoji: "🅰️", role: "r")
        _ = try store.createAgent(name: "b", emoji: "🅱️", role: "r")
        let src = tempSkill("# v1 rules")
        defer { try? FileManager.default.removeItem(at: src) }
        try store.addToLibrary(from: src)
        let name = src.lastPathComponent
        XCTAssertEqual(store.librarySkills(), [name])

        // Grant to ONE agent (explicit, unchanged semantics).
        try store.addSkill(from: store.skillsLibraryURL.appendingPathComponent(name), to: "a")
        XCTAssertTrue(store.listSkills(for: "a").contains(name))
        XCTAssertFalse(store.listSkills(for: "b").contains(name))

        // Improve the library version, then re-push.
        try "# v2 rules".write(to: store.skillsLibraryURL.appendingPathComponent(name),
                               atomically: true, encoding: .utf8)
        let touched = try store.updateFromLibrary(name)
        XCTAssertEqual(touched, ["a"], "only holders are updated — granting stays explicit")
        let onDisk = try String(contentsOf: store.skillsDir("a").appendingPathComponent(name),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "# v2 rules", "the fix actually reached the teammate")
        XCTAssertFalse(store.listSkills(for: "b").contains(name), "non-holders untouched")
    }

    func testSymlinksAreRefusedAtTheLibraryDoorToo() throws {
        let store = makeStore()
        let real = tempSkill("# x")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-\(UUID().uuidString).md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try store.addToLibrary(from: link)) { error in
            XCTAssertEqual(error as? AgencyError, .symlinkedSkill(link.lastPathComponent))
        }
    }

    func testUpdatingAnUnknownSkillIsANoOp() throws {
        XCTAssertEqual(try makeStore().updateFromLibrary("nope.md"), [])
    }
}
