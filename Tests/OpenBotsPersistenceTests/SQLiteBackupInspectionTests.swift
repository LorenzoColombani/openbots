import Darwin
import Foundation
import Testing
@testable import OpenBotsPersistence

@Suite("Reading a database snapshot without disturbing it")
struct SQLiteBackupInspectionTests {
    @Test("A closed workspace reports its integrity, schema version and protection decision")
    func inspectReportsFactsOfARealDatabase() async throws {
        let fixture = try BackupInspectionFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL(named: "OpenBots.sqlite")
        weak var released: SQLiteStore?
        var store: SQLiteStore? = try SQLiteStore(configuration: fixture.configuration(databaseURL))
        released = store
        #expect(try await store?.integrityCheck() == true)
        // Releasing the last reference closes the connection, which checkpoints
        // and removes the write-ahead log.
        store = nil
        #expect(released == nil)
        // `immutable=1` reads the file's own pages, so frames still sitting in a
        // write-ahead log would be silently invisible. Apple's SQLite keeps the
        // sidecars after the last connection closes rather than deleting them,
        // so the condition to prove is that the log was checkpointed empty.
        var walInfo = stat()
        if lstat(databaseURL.path + "-wal", &walInfo) == 0 {
            #expect(walInfo.st_size == 0)
        }

        let facts = try SQLiteBackupInspection.inspect(fileURL: databaseURL)
        #expect(facts.integrityOK)
        #expect(facts.schemaVersion == SQLiteStore.supportedSchemaVersion)
        #expect(facts.protectionMode == "ordinarySQLite")
        #expect(facts.decisionID == fixture.decisionID.uuidString.lowercased())
        #expect(facts.pageCount > 0)
    }

    @Test("An online backup is a WAL-mode file that still inspects with no sidecar left behind")
    func inspectingAnOnlineBackupCreatesNoSidecars() async throws {
        let fixture = try BackupInspectionFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL(named: "OpenBots.sqlite")
        let backupURL = fixture.databaseURL(named: "OpenBots-snapshot.sqlite")
        do {
            let store = try SQLiteStore(configuration: fixture.configuration(databaseURL))
            let destination = try ExclusiveSQLiteBackupDestination(exactFileURL: backupURL)
            let receipt = try await store.createOnlineBackup(
                at: destination,
                protection: fixture.protectionPlan
            )
            #expect(receipt.databasePageCount > 0)
        }

        // The header the online backup API copies from a WAL source: file format
        // write and read versions 2. This is why the inspector must open the
        // file as immutable rather than merely read-only.
        let header = try #require(FileHandle(forReadingAtPath: backupURL.path))
        try header.seek(toOffset: 18)
        #expect(try header.read(upToCount: 2) == Data([2, 2]))
        try header.close()

        #expect(!FileManager.default.fileExists(atPath: backupURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path + "-shm"))
        let facts = try SQLiteBackupInspection.inspect(fileURL: backupURL)
        #expect(facts.integrityOK)
        #expect(facts.schemaVersion == SQLiteStore.supportedSchemaVersion)
        #expect(facts.protectionMode == "ordinarySQLite")
        #expect(facts.decisionID == fixture.decisionID.uuidString.lowercased())
        // Nothing was created next to the snapshot, and nothing was removed.
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let neighbours = try FileManager.default
            .contentsOfDirectory(atPath: fixture.databaseDirectory.path)
            .filter { $0.hasPrefix("OpenBots-snapshot.sqlite") && $0 != "OpenBots-snapshot.sqlite" }
        #expect(neighbours.isEmpty)
    }

    @Test("A file of garbage bytes is refused rather than reported healthy")
    func garbageBytesAreRefused() throws {
        let fixture = try BackupInspectionFixture()
        defer { fixture.remove() }
        let garbageURL = fixture.databaseURL(named: "OpenBots-garbage.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: garbageURL)

        do {
            let facts = try SQLiteBackupInspection.inspect(fileURL: garbageURL)
            Issue.record("garbage must not inspect as a database: \(facts)")
        } catch let error as SQLiteBackupInspectionError {
            guard case .databaseUnreadable = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test("A symbolic link is refused before SQLite can interpret its target")
    func symbolicLinkIsRefused() async throws {
        let fixture = try BackupInspectionFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.databaseURL(named: "OpenBots.sqlite")
        do {
            _ = try SQLiteStore(configuration: fixture.configuration(databaseURL))
        }
        let linkURL = fixture.databaseURL(named: "OpenBots-link.sqlite")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: databaseURL.path
        )

        #expect(throws: SQLiteBackupInspectionError.unexpectedFileType) {
            try SQLiteBackupInspection.inspect(fileURL: linkURL)
        }
    }

    @Test("The inspector opens read-only, refuses link following, and encodes the path it is given")
    func openFlagsAndURIEncodingAreExplicit() {
        #expect(sqliteBackupInspectionOpenFlags & sqliteOpenReadOnly != 0)
        #expect(sqliteBackupInspectionOpenFlags & sqliteOpenNoFollow != 0)
        #expect(sqliteBackupInspectionOpenFlags & sqliteOpenURI != 0)
        #expect(sqliteBackupInspectionOpenFlags & sqliteOpenReadWrite == 0)
        #expect(sqliteBackupInspectionOpenFlags & sqliteOpenCreate == 0)
        #expect(
            SQLiteBackupInspection.immutableReadOnlyURI(
                for: URL(fileURLWithPath: "/tmp/Application Support/a?b#c.sqlite")
            ) == "file:/tmp/Application%20Support/a%3Fb%23c.sqlite?immutable=1"
        )
    }

    @Test("A missing file is reported as an inspection failure, not as an unhealthy database")
    func missingFileIsReported() throws {
        let fixture = try BackupInspectionFixture()
        defer { fixture.remove() }
        #expect(
            throws: SQLiteBackupInspectionError.fileInspectionFailed(code: ENOENT)
        ) {
            try SQLiteBackupInspection.inspect(fileURL: fixture.databaseURL(named: "absent.sqlite"))
        }
    }
}

/// A disposable root whose database folder carries a space, because the live
/// one lives under `Library/Application Support` and a percent-encoding bug
/// would otherwise pass every test here.
private struct BackupInspectionFixture: Sendable {
    let root: URL
    let databaseDirectory: URL
    let decisionID = UUID()
    let protectionPlan: PersistenceProtectionPlan

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextBackupInspection-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        databaseDirectory = root.appending(path: "Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let decision = decisionID
        protectionPlan = .ordinarySQLite(
            decision: try ProtectionDecisionReceipt(
                decisionID: decision,
                selectedAt: Date(timeIntervalSince1970: 1_750_000_000),
                rationaleVersion: 1
            )
        )
    }

    func databaseURL(named name: String) -> URL {
        databaseDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    func configuration(_ url: URL) throws -> SQLiteStoreConfiguration {
        try SQLiteStoreConfiguration(fileURL: url, protection: protectionPlan)
    }

    func remove() {
        guard root.path.hasPrefix("/private/tmp/OpenBotsNextBackupInspection-"),
              root.path.hasSuffix(".noindex") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
