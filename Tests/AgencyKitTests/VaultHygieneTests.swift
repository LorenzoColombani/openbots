import XCTest
@testable import AgencyKit

/// Vault hygiene (coordinator's report 2026-08-13). Root cause of the worst
/// case: `updated:` was AGENT discipline, and when one agent didn't bump it,
/// bruno read the stale stamp as a tampering signal and shipped a piece built
/// on superseded material. The app already knows exactly which notes changed
/// (the provenance diff) — so the app stamps them, mechanically.
final class VaultHygieneTests: XCTestCase {
    private func tempFile(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyg-\(UUID().uuidString).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    /// 2026-08-13T12:00:00Z (= 14:00 in a UTC+02:00 zone — same calendar day
    /// either way, so the date assertions below are timezone-safe).
    private let now = Date(timeIntervalSince1970: 1_786_622_400)

    func testBumpsExistingUpdatedField() throws {
        let url = tempFile("""
        ---
        author: bruno
        created: 2026-08-12T10:00:00Z
        updated: 2026-08-12T10:00:00Z
        tags: []
        ---

        body text
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(VaultProvenance.stampUpdated(at: url, now: now))
        let out = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(out.contains("updated: 2026-08-13"), out)
        XCTAssertTrue(out.contains("created: 2026-08-12T10:00:00Z"), "created is NEVER touched")
        XCTAssertTrue(out.contains("author: bruno"), "other fields survive")
        XCTAssertTrue(out.hasSuffix("body text"), "body survives verbatim")
    }

    func testInsertsUpdatedWhenFrontmatterLacksIt() throws {
        let url = tempFile("---\nauthor: nina\n---\n\nbody")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(VaultProvenance.stampUpdated(at: url, now: now))
        let out = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(out.contains("updated: 2026-08-13"), out)
        XCTAssertEqual(out.components(separatedBy: "---").count, 3, "frontmatter block stays well-formed")
    }

    func testLeavesFilesWithoutFrontmatterAlone() throws {
        let url = tempFile("# just a heading\n\nno frontmatter here")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(VaultProvenance.stampUpdated(at: url, now: now))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "# just a heading\n\nno frontmatter here", "untouched, byte for byte")
    }

    func testIgnoresNonMarkdownAndUnterminatedFrontmatter() throws {
        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyg-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        XCTAssertFalse(VaultProvenance.stampUpdated(at: png, now: now), "binaries are never rewritten")

        let bad = tempFile("---\nauthor: x\nno closing fence\n\nbody")
        defer { try? FileManager.default.removeItem(at: bad) }
        XCTAssertFalse(VaultProvenance.stampUpdated(at: bad, now: now),
                       "an unterminated block is not frontmatter — don't guess")
    }

    func testCRLFNotesAreHandled() throws {
        let url = tempFile("---\r\nauthor: bruno\r\nupdated: old\r\n---\r\n\r\nbody")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(VaultProvenance.stampUpdated(at: url, now: now))
        let out = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(out.contains("updated: 2026-08-13"))
        XCTAssertFalse(out.contains("updated: old"))
    }

    /// End-to-end through the ledger: a note an agent changed gets stamped,
    /// and the recorded sha matches the STAMPED bytes (not the pre-stamp ones).
    func testCommitStampsChangedNotesAndHashesTheResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-hyg-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()

        let note = vault.appendingPathComponent("brief.md")
        try "---\nauthor: bruno\nupdated: 2026-01-01T00:00:00Z\n---\n\nnew work".write(
            to: note, atomically: true, encoding: .utf8)

        let records = prov.commit(previous: before, by: "bruno", now: now)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("updated: 2026-08-13"), "the app stamped it: \(text)")
        XCTAssertEqual(records.first?.sha256, VaultProvenance.hash(of: note),
                       "the ledger's hash is of the FINAL bytes")
    }

    func testDeletionsAreNotStamped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-hyg-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = vault.appendingPathComponent("gone.md")
        try "---\nauthor: nina\n---\nx".write(to: note, atomically: true, encoding: .utf8)
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        try FileManager.default.removeItem(at: note)
        let records = prov.commit(previous: before, by: "nina", now: now)
        XCTAssertEqual(records.first?.deleted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path), "no resurrection by stamping")
    }
}
