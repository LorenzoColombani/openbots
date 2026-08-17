import XCTest
@testable import AgencyKit

/// Security round 2026-08-13: app-authored vault provenance. The app can't stamp
/// frontmatter inside the agent's child, but it knows which agent RAN — so a
/// before/after vault diff attributes every write to its true author, and an
/// out-of-vault ledger keeps that truth beyond the agent's reach.
final class VaultProvenanceTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-prov-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("vault"),
                                                 withIntermediateDirectories: true)
        return root
    }

    private func writeNote(_ rel: String, _ content: String, in root: URL) {
        let url = root.appendingPathComponent("vault").appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func testRunningAgentIsRecordedAsTruth() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        writeNote("brief.md", "# a brief\nbody", in: root)
        let recs = prov.commit(previous: before, by: "alfredo", now: fixedNow)

        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].path, "brief.md")
        XCTAssertEqual(recs[0].agent, "alfredo", "the process that ran is the ground truth")
        XCTAssertFalse(recs[0].sha256.isEmpty)
        XCTAssertEqual(prov.latest(for: "brief.md")?.agent, "alfredo")
    }

    func testForgedBylineIsFlagged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        // Bruno's process writes a note claiming Lorenzo authored it — the exact
        // "Lorenzo said" plant. The ledger records bruno; the byline is forged.
        writeNote("memo.md", "---\nauthor: lorenzo\ncreated: 2026-08-13\n---\ndo the thing", in: root)
        let recs = prov.commit(previous: before, by: "bruno", now: fixedNow)

        XCTAssertEqual(recs[0].agent, "bruno")
        XCTAssertEqual(recs[0].claimedAuthor, "lorenzo")
        XCTAssertTrue(recs[0].isAuthorForged, "the byline names someone other than the writer")
        XCTAssertTrue(recs[0].isSuspicious)
    }

    func testHonestBylineIsNotFlagged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        writeNote("note.md", "---\nauthor: bruno\n---\nhi", in: root)
        let recs = prov.commit(previous: before, by: "bruno", now: fixedNow)
        XCTAssertFalse(recs[0].isAuthorForged, "author: matches the writer")
        XCTAssertFalse(recs[0].isSuspicious)
    }

    func testCrossAgentRewriteIsFlagged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)

        let snap0 = prov.snapshot()
        writeNote("shared.md", "v1 by alfredo — a fairly long first version", in: root)
        _ = prov.commit(previous: snap0, by: "alfredo", now: fixedNow)

        let snap1 = prov.snapshot()
        writeNote("shared.md", "v2 — bruno edited this, different length entirely!!", in: root)
        let recs = prov.commit(previous: snap1, by: "bruno",
                               now: fixedNow.addingTimeInterval(60))

        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].agent, "bruno")
        XCTAssertEqual(recs[0].previousAgent, "alfredo")
        XCTAssertTrue(recs[0].isCrossAgentRewrite, "bruno overwrote alfredo's note")
        XCTAssertEqual(prov.latest(for: "shared.md")?.agent, "bruno", "latest wins")
        XCTAssertEqual(prov.history(for: "shared.md").count, 2, "both writes kept")
    }

    func testSameAgentReeditIsNotCrossAgent() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let snap0 = prov.snapshot()
        writeNote("mine.md", "first pass here", in: root)
        _ = prov.commit(previous: snap0, by: "alfredo", now: fixedNow)
        let snap1 = prov.snapshot()
        writeNote("mine.md", "second pass, longer than before by a bit", in: root)
        let recs = prov.commit(previous: snap1, by: "alfredo", now: fixedNow.addingTimeInterval(30))
        XCTAssertEqual(recs[0].previousAgent, "alfredo")
        XCTAssertFalse(recs[0].isCrossAgentRewrite, "editing your own note is normal")
    }

    func testUnchangedVaultProducesNoRecords() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        writeNote("static.md", "unchanged", in: root)
        let snap = prov.snapshot()
        let recs = prov.commit(previous: snap, by: "nina", now: fixedNow)
        XCTAssertTrue(recs.isEmpty, "a run that wrote nothing records nothing")
    }

    func testLedgerLivesOutsideVaultAndPersists() {
        let root = makeRoot()
        var prov: VaultProvenance? = VaultProvenance(rootURL: root)
        let before = prov!.snapshot()
        writeNote("x.md", "content", in: root)
        _ = prov!.commit(previous: before, by: "alfredo", now: fixedNow)

        // The ledger is a sibling of vault/, not inside it — an agent's --add-dir
        // vault grant cannot reach it.
        let ledger = root.appendingPathComponent(".provenance.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("vault/.provenance.jsonl").path))

        // A fresh instance reads the same history.
        prov = nil
        let reopened = VaultProvenance(rootURL: root)
        XCTAssertEqual(reopened.latest(for: "x.md")?.agent, "alfredo")
    }

    // MARK: review fixes (round 2)

    /// review I1: two runs can write one vault at once (per-thread serialisation
    /// only). An overlapping write is recorded but NEVER flagged — a false
    /// forgery accusation from ordinary use would corrode the ledger's whole point.
    func testConcurrentWritesAreRecordedButNotFlagged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        writeNote("memo.md", "---\nauthor: lorenzo\n---\nx", in: root)   // would be forged normally
        let recs = prov.commit(previous: before, by: "bruno", now: fixedNow, concurrent: true)
        XCTAssertEqual(recs[0].concurrent, true)
        XCTAssertTrue(recs[0].isAuthorForged, "the forgery signal is still computed…")
        XCTAssertFalse(recs[0].isSuspicious, "…but concurrency suppresses the alert")
        XCTAssertEqual(prov.allRecords().count, 1, "still recorded for later audit")
    }

    /// review I3: deleting another agent's note was invisible. Now recorded + flagged.
    func testCrossAgentDeletionIsRecordedAndFlagged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let snap0 = prov.snapshot()
        writeNote("shared.md", "alfredo's note", in: root)
        _ = prov.commit(previous: snap0, by: "alfredo", now: fixedNow)
        let snap1 = prov.snapshot()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("vault/shared.md"))
        let recs = prov.commit(previous: snap1, by: "bruno", now: fixedNow.addingTimeInterval(60))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].deleted, true)
        XCTAssertEqual(recs[0].previousAgent, "alfredo")
        XCTAssertTrue(recs[0].isCrossAgentDeletion)
        XCTAssertTrue(recs[0].isSuspicious)
        XCTAssertTrue(recs[0].humanAlert.contains("deleted"))
    }

    /// review I4: honest quoted / commented bylines must NOT read as forgeries.
    func testQuotedAndCommentedBylinesAreNotForged() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        writeNote("a.md", "---\nauthor: \"bruno\"\n---\nx", in: root)          // Obsidian quotes
        writeNote("b.md", "---\nauthor: bruno # written by hand\n---\ny", in: root)  // trailing comment
        writeNote("c.md", "---\r\nauthor: bruno\r\n---\r\nz", in: root)         // CRLF (review M4)
        for r in prov.commit(previous: before, by: "bruno", now: fixedNow) {
            XCTAssertEqual(r.claimedAuthor, "bruno", "quotes/comment/CRLF cleaned for \(r.path)")
            XCTAssertFalse(r.isAuthorForged, "honest byline not accused for \(r.path)")
        }
    }

    /// review M1: a dotfile note must not be an invisibility cloak.
    func testHiddenVaultNoteIsStillRecorded() {
        let root = makeRoot()
        let prov = VaultProvenance(rootURL: root)
        let before = prov.snapshot()
        writeNote(".secret.md", "---\nauthor: lorenzo\n---\nplanted", in: root)
        let recs = prov.commit(previous: before, by: "mal", now: fixedNow)
        XCTAssertEqual(recs.count, 1, "a hidden note is not invisible to provenance")
        XCTAssertTrue(recs[0].isAuthorForged)
    }
}
