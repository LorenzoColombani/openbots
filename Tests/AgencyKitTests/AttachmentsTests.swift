import XCTest
@testable import AgencyKit

final class AttachmentsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, _ contents: String = "hello") throws -> URL {
        let u = root.appendingPathComponent(name)
        try contents.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: names

    func testSanitizedNameStripsTraversalInvisiblesAndLeadingDots() {
        // A crafted name must not climb out of the staging dir…
        XCTAssertEqual(Attachments.sanitizedName("../../etc/passwd"), "passwd")
        // …hide itself…
        XCTAssertEqual(Attachments.sanitizedName(".zshrc"), "zshrc")
        // …or carry the bidi/invisible class the MCP servers already reject.
        XCTAssertEqual(Attachments.sanitizedName("re\u{202E}fdp.txt"), "refdp.txt")
        XCTAssertEqual(Attachments.sanitizedName("a:b.txt"), "a-b.txt")
        XCTAssertEqual(Attachments.sanitizedName("\u{200B}."), "file")
    }

    func testSlugMapsTeamKeysAndPassesAgentHandles() {
        XCTAssertEqual(Attachments.slug(forThread: TeamThreads.key(for: "probe")), "#probe")
        XCTAssertEqual(Attachments.slug(forThread: "bruno"), "bruno")
        XCTAssertEqual(Attachments.slug(forThread: "…"), "thread")
    }

    // MARK: staging

    func testStageCopiesUnderSharedAndLeavesOriginal() throws {
        let src = try makeFile("report.md", "the content")
        let staged = try Attachments.stage(files: [src], thread: "bruno", root: root)
        XCTAssertEqual(staged.count, 1)
        // The copy lives under shared/attachments/<slug>/ — the one place every
        // fenced run can read; NEVER inside an agent's sealed folder.
        XCTAssertTrue(staged[0].path.hasPrefix(
            root.appendingPathComponent("shared/attachments/bruno").path))
        XCTAssertFalse(staged[0].path.contains("/agents/"))
        XCTAssertTrue(staged[0].lastPathComponent.hasSuffix("report.md"))
        XCTAssertEqual(try String(contentsOf: staged[0], encoding: .utf8), "the content")
        // Copy, not move — the original is untouched.
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "the content")
    }

    func testStageNeverOverwrites() throws {
        // Same file, same second → distinct staged copies, no clobber (the
        // no-overwrite rule holds for Lorenzo's files too).
        let src = try makeFile("dup.txt", "v1")
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let a = try Attachments.stage(files: [src], thread: "bruno", root: root, now: now)
        try "v2".write(to: src, atomically: true, encoding: .utf8)
        let b = try Attachments.stage(files: [src], thread: "bruno", root: root, now: now)
        XCTAssertNotEqual(a[0], b[0])
        XCTAssertEqual(try String(contentsOf: a[0], encoding: .utf8), "v1")
        XCTAssertEqual(try String(contentsOf: b[0], encoding: .utf8), "v2")
    }

    func testStageThrowsOnMissingSource() {
        let ghost = root.appendingPathComponent("not-there.pdf")
        XCTAssertThrowsError(try Attachments.stage(files: [ghost], thread: "bruno", root: root))
    }

    func testStagePreservesInputOrder() throws {
        let files = try ["one.txt", "two.txt", "three.txt"].map { try makeFile($0) }
        let staged = try Attachments.stage(files: files, thread: "nina", root: root)
        XCTAssertEqual(staged.map { String($0.lastPathComponent.split(separator: "-").last!) },
                       ["one.txt", "two.txt", "three.txt"])
    }

    // MARK: retention sweep (review M6)

    func testSweepRemovesOldKeepsRecentPrunesEmptyDirs() throws {
        let src = try makeFile("keep.txt")
        let now = Date()
        let staged = try Attachments.stage(files: [src], thread: "bruno", root: root, now: now)
        let old = try Attachments.stage(files: [makeFile("old.txt")], thread: "nina",
                                        root: root, now: now)
        // Age nina's copy past the cutoff via its modification date.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-40 * 24 * 3600)],
            ofItemAtPath: old[0].path)
        let removed = Attachments.sweep(root: root, now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].path), "recent survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old[0].path), "old is swept")
        // nina's slug dir emptied out → pruned; bruno's still holds a file.
        let base = root.appendingPathComponent("shared/attachments")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("nina").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("bruno").path))
    }

    func testSweepOnMissingBaseIsQuietNoop() {
        XCTAssertEqual(Attachments.sweep(root: root), 0)
    }

    // MARK: prompt block

    // MARK: review round (2026-08-14): symlinks, control chars, caps, slug collision

    func testStageRefusesSymlinkSource() throws {
        // C1: copyItem stages the LINK, not the target (verified live) — an
        // absolute link resolves through the fence, a relative one dangles.
        let target = try makeFile("real.txt")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try Attachments.stage(files: [link], thread: "bruno", root: root))
    }

    func testStageRefusesFolderContainingSymlink() throws {
        let dir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("sneaky"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try Attachments.stage(files: [dir], thread: "bruno", root: root))
        // …and the refused call left nothing behind (M3: no orphans).
        let staged = root.appendingPathComponent("shared/attachments/bruno")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "refused stage must clean up after itself")
    }

    func testStageCleansUpEarlierCopiesWhenALaterFileFails() throws {
        let good = try makeFile("good.txt")
        let ghost = root.appendingPathComponent("ghost.txt")
        XCTAssertThrowsError(try Attachments.stage(files: [good, ghost], thread: "bruno", root: root))
        let staged = root.appendingPathComponent("shared/attachments/bruno")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "good.txt's copy must not survive the refused send")
    }

    func testSanitizedNameStripsControlCharactersAndBidiIsolates() {
        // I3: TAB/ESC survived the first cut; M1: the isolate class
        // U+2066–2069 (+U+061C) did too — same gap as the MCP servers had.
        XCTAssertEqual(Attachments.sanitizedName("a\tb\u{1B}c.txt"), "abc.txt")
        XCTAssertEqual(Attachments.sanitizedName("d\u{7F}e.txt"), "de.txt")
        XCTAssertEqual(Attachments.sanitizedName("f\u{2066}g\u{2069}h.txt"), "fgh.txt")
        XCTAssertEqual(Attachments.sanitizedName("i\u{061C}j.txt"), "ij.txt")
    }

    func testStageRefusesOversizedPayload() throws {
        // I2: staging is synchronous on the main actor — a runaway payload
        // must be refused up front, not beachball the UI mid-copy.
        let big = try makeFile("big.bin", String(repeating: "x", count: 4096))
        XCTAssertThrowsError(try Attachments.stage(files: [big], thread: "bruno",
                                                   root: root, maxTotalBytes: 1024))
        XCTAssertNoThrow(try Attachments.stage(files: [big], thread: "bruno",
                                               root: root, maxTotalBytes: 1_000_000))
    }

    func testTeamSlugCannotCollideWithAgentSlug() {
        // M2: an agent legally named "team-probe" must not share a staging dir
        // with team "#probe" — the team slug keeps '#', which the agent-slug
        // alphabet filter can never produce.
        XCTAssertEqual(Attachments.slug(forThread: TeamThreads.key(for: "probe")), "#probe")
        XCTAssertEqual(Attachments.slug(forThread: "team-probe"), "team-probe")
        XCTAssertNotEqual(Attachments.slug(forThread: TeamThreads.key(for: "probe")),
                          Attachments.slug(forThread: "team-probe"))
    }

    func testPromptBlockNamesAbsolutePathsAndCount() throws {
        let src = try makeFile("notes.md")
        let staged = try Attachments.stage(files: [src], thread: "bruno", root: root)
        let block = Attachments.promptBlock(for: staged)
        XCTAssertTrue(block.contains("1 file"))
        XCTAssertTrue(block.contains(staged[0].path), "absolute path — valid for any run's cwd")
        XCTAssertEqual(Attachments.promptBlock(for: []), "")
        let two = try Attachments.stage(files: [src, makeFile("b.md")], thread: "bruno", root: root)
        XCTAssertTrue(Attachments.promptBlock(for: two).contains("2 files"))
    }
}
