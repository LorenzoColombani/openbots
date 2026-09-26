import Darwin
import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Offering and restoring a control-database backup")
struct DatabaseBackupRestoreTests {
    @Test("Only intact backups of this installation are offered, newest first")
    func catalogListsOnlyIntactBackupsOfThisInstallation() async throws {
        let fixture = try RestoreLayoutFixture()
        defer { fixture.remove() }
        try fixture.makeBackupsRoot()
        let root = fixture.layout.databaseBackupsRoot

        var names: [String] = []
        do {
            let store = try SQLiteStore(configuration: fixture.configuration(fixture.scratchDatabaseURL))
            names = try await [
                fixture.writeBackup(from: store, named: "OpenBots-20260906T090000Z-manual.sqlite", in: root),
                fixture.writeBackup(from: store, named: "OpenBots-20260906T100000Z-scheduled.sqlite", in: root),
                fixture.writeBackup(from: store, named: "OpenBots-20260906T110000Z-quit.sqlite", in: root),
                fixture.writeBackup(
                    from: store,
                    named: "OpenBots-20260906T120000Z-manual.sqlite",
                    in: root,
                    schemaVersion: SQLiteStore.supportedSchemaVersion + 4
                )
            ]
        }
        // A stranger's workspace: same shape, a different protection decision.
        let foreignFixture = try RestoreLayoutFixture()
        defer { foreignFixture.remove() }
        do {
            let foreignStore = try SQLiteStore(
                configuration: foreignFixture.configuration(foreignFixture.scratchDatabaseURL)
            )
            names.append(
                try await foreignFixture.writeBackup(
                    from: foreignStore,
                    named: "OpenBots-20260906T130000Z-manual.sqlite",
                    in: root
                )
            )
        }
        // The third backup's bytes are altered after its sidecar was written.
        let alteredURL = root.appending(path: names[1], directoryHint: .notDirectory)
        let handle = try #require(FileHandle(forUpdatingAtPath: alteredURL.path))
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        try handle.close()

        let catalog = DatabaseBackupCatalog(
            layout: fixture.layout,
            expectedDecisionID: fixture.decisionID
        )
        let report = catalog.verify()
        #expect(report.verified.map(\.id) == [names[2], names[0]])
        #expect(catalog.verifiedBackups().map(\.id) == [names[2], names[0]])
        #expect(Set(report.skipped.map(\.fileName)) == [names[1], names[3], names[4]])
        // Each refusal must come from its own check, not from a later one that
        // would have caught it anyway.
        let refusals = Dictionary(
            report.skipped.map { ($0.fileName, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(refusals[names[1]]?.contains("SHA-256") == true)
        #expect(refusals[names[3]]?.contains("the sidecar claims schema version") == true)
        #expect(refusals[names[4]]?.contains("protection decision") == true)
        #expect(report.verified.first?.reason == "quit")
        #expect(report.verified.first?.schemaVersion == SQLiteStore.supportedSchemaVersion)
        #expect(report.verified.allSatisfy { $0.byteCount > 0 })
    }

    @Test("A damaged workspace is replaced by a verified backup, and reopens with its work intact")
    func restoreReplacesADamagedDatabaseAndReopens() async throws {
        let fixture = try RestoreCompositionFixture()
        defer { fixture.remove() }
        let plan = try fixture.plan()
        let decision = try fixture.decision()
        let layout = fixture.layout
        let teammate = try RestoreCompositionFixture.teammate()

        var backupName = ""
        do {
            let context = try await StoragePersistenceCompositionService(
                layout: layout,
                bootstrapper: fixture.bootstrapper()
            ).bootstrapAndOpen(using: plan, protection: .ordinarySQLite, decision: decision)
            try await context.teammateRepository.insert(teammate)
            let store = try #require(context.teammateRepository as? SQLiteStore)
            backupName = try await fixture.writeBackup(
                from: store,
                named: "OpenBots-20260906T101500Z-manual.sqlite",
                protection: .ordinarySQLite(decision: decision)
            )
        }

        // The workspace is damaged the way a truncated write leaves it: the
        // database is unreadable and stale sidecars are still on disk.
        let garbage = Data(repeating: 0x7E, count: 4_096)
        try garbage.write(to: layout.databaseURL)
        try Data(repeating: 0x11, count: 128).write(to: layout.databaseWALURL)
        try Data(repeating: 0x22, count: 128).write(to: layout.databaseSHMURL)
        for url in [layout.databaseURL, layout.databaseWALURL, layout.databaseSHMURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        await #expect(throws: StoragePersistenceCompositionError.self) {
            try await StoragePersistenceCompositionService(layout: layout).reopenExisting()
        }

        let catalog = DatabaseBackupCatalog(layout: layout, expectedDecisionID: decision.decisionID)
        let offered = catalog.verify()
        #expect(offered.skipped.isEmpty)
        let backup = try #require(offered.verified.first)
        #expect(backup.id == backupName)

        let restoredAt = Date(timeIntervalSince1970: 1_788_693_600)
        let receipt = try DatabaseBackupRestoreService(
            layout: layout,
            clock: { restoredAt }
        ).restore(backup)

        #expect(receipt.restoredFrom == backupName)
        #expect(receipt.restoredAt == restoredAt)
        #expect(receipt.damagedFolder == "Damaged-20260906T112000Z")
        #expect(receipt.movedFiles == ["OpenBots.sqlite", "OpenBots.sqlite-wal", "OpenBots.sqlite-shm"])

        // The workspace opens again, through the real startup path, with the work
        // that was in the snapshot.
        let reopened = try await StoragePersistenceCompositionService(layout: layout).reopenExisting()
        #expect(try await reopened.teammateRepository.teammate(id: teammate.id) == teammate)
        #expect(reopened.databaseFacts.migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(reopened.installationReceipt.protectionDecision == decision)

        // Nothing was deleted: the damaged files are all in the timestamped folder.
        let damagedURL = layout.databaseBackupsRoot.appending(
            path: receipt.damagedFolder,
            directoryHint: .isDirectory
        )
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: damagedURL.path))
                == ["OpenBots.sqlite", "OpenBots.sqlite-wal", "OpenBots.sqlite-shm"]
        )
        #expect(
            try Data(contentsOf: damagedURL.appending(path: "OpenBots.sqlite", directoryHint: .notDirectory))
                == garbage
        )
        var folderInfo = stat()
        #expect(lstat(damagedURL.path, &folderInfo) == 0)
        #expect(UInt16(folderInfo.st_mode & 0o7777) == 0o700)

        // The backup itself was copied, not moved, so the same snapshot is still offered.
        #expect(catalog.verifiedBackups().map(\.id) == [backupName])

        let receiptURL = layout.databaseBackupsRoot.appending(
            path: "restore-20260906T112000Z.json",
            directoryHint: .notDirectory
        )
        let decoded = try DatabaseBackupRestoreService.receiptDecoder().decode(
            DatabaseBackupRestoreReceipt.self,
            from: try Data(contentsOf: receiptURL)
        )
        #expect(decoded == receipt)
        var receiptInfo = stat()
        #expect(lstat(receiptURL.path, &receiptInfo) == 0)
        #expect(UInt16(receiptInfo.st_mode & 0o7777) == 0o600)
    }

    @Test("A backup outside the backups folder is refused before anything moves")
    func restoreRefusesABackupOutsideTheBackupsFolder() throws {
        let fixture = try RestoreLayoutFixture()
        defer { fixture.remove() }
        try fixture.makeBackupsRoot()
        let stranger = VerifiedDatabaseBackup(
            id: "OpenBots-elsewhere.sqlite",
            fileURL: fixture.scratchDirectory.appending(
                path: "OpenBots-elsewhere.sqlite",
                directoryHint: .notDirectory
            ),
            createdAt: Date(timeIntervalSince1970: 1_757_000_000),
            byteCount: 4_096,
            schemaVersion: SQLiteStore.supportedSchemaVersion,
            reason: "manual"
        )

        #expect(throws: DatabaseBackupRestoreError.backupOutsideBackupsRoot) {
            try DatabaseBackupRestoreService(layout: fixture.layout).restore(stranger)
        }
        #expect(try FileManager.default
            .contentsOfDirectory(atPath: fixture.layout.databaseBackupsRoot.path).isEmpty)
    }
}

// MARK: - Fixtures

/// Writes the sidecar exactly as `ControlDatabaseBackupService` does, by hand,
/// so these tests exercise the format rather than the writer.
private func writeManifest(
    for fileURL: URL,
    reason: String,
    createdAt: Date,
    schemaVersion: Int,
    protectionMode: String,
    decisionID: UUID,
    pageCount: Int
) throws {
    let bytes = try Data(contentsOf: fileURL)
    let digest = try DatabaseBackupDigest.hex(ofFileAt: fileURL)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    let manifest: [String: Any] = [
        "formatVersion": 1,
        "fileName": fileURL.lastPathComponent,
        "reason": reason,
        "createdAt": formatter.string(from: createdAt),
        "byteCount": bytes.count,
        "sha256": digest,
        "databasePageCount": pageCount,
        "schemaVersion": schemaVersion,
        "protectionMode": protectionMode,
        "decisionID": decisionID.uuidString.lowercased()
    ]
    let encoded = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try encoded.write(
        to: fileURL.deletingLastPathComponent().appending(
            path: "\(fileURL.lastPathComponent).json",
            directoryHint: .notDirectory
        ),
        options: [.withoutOverwriting]
    )
}

/// A disposable home whose only purpose is to give `PreviewStorageLayout` a
/// backups folder. No installation is bootstrapped here.
private struct RestoreLayoutFixture: Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let scratchDirectory: URL
    let decisionID = UUID()
    let decision: ProtectionDecisionReceipt

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextBackupCatalog-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        scratchDirectory = root.appending(path: "Scratch", directoryHint: .isDirectory)
        for url in [home, temporary, scratchDirectory] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        decision = try ProtectionDecisionReceipt(
            decisionID: decisionID,
            selectedAt: Date(timeIntervalSince1970: 1_750_000_000),
            rationaleVersion: 1
        )
    }

    var scratchDatabaseURL: URL {
        scratchDirectory.appending(path: "OpenBots.sqlite", directoryHint: .notDirectory)
    }

    func configuration(_ url: URL) throws -> SQLiteStoreConfiguration {
        try SQLiteStoreConfiguration(fileURL: url, protection: .ordinarySQLite(decision: decision))
    }

    func makeBackupsRoot() throws {
        try FileManager.default.createDirectory(
            at: layout.databaseBackupsRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @discardableResult
    func writeBackup(
        from store: SQLiteStore,
        named name: String,
        in root: URL,
        schemaVersion: Int? = nil
    ) async throws -> String {
        let fileURL = root.appending(path: name, directoryHint: .notDirectory)
        let receipt = try await store.createOnlineBackup(
            at: try ExclusiveSQLiteBackupDestination(exactFileURL: fileURL),
            protection: .ordinarySQLite(decision: decision)
        )
        try writeManifest(
            for: fileURL,
            reason: String(name.split(separator: "-").last?.split(separator: ".").first ?? "manual"),
            createdAt: RestoreLayoutFixture.createdAt(from: name),
            schemaVersion: schemaVersion ?? SQLiteStore.supportedSchemaVersion,
            protectionMode: "ordinarySQLite",
            decisionID: decisionID,
            pageCount: receipt.databasePageCount
        )
        return name
    }

    /// Reads the instant back out of the producer's own file-name stamp.
    static func createdAt(from fileName: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = fileName
            .replacingOccurrences(of: "OpenBots-", with: "")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return formatter.date(from: stamp) ?? Date(timeIntervalSince1970: 0)
    }

    func remove() {
        guard root.path.hasPrefix("/private/tmp/OpenBotsNextBackupCatalog-"),
              root.path.hasSuffix(".noindex") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RestoreFixedAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: .notManaged,
            volumeIdentifier: "restore-test-volume"
        )
    }
}

/// A disposable installation that the real composition service bootstraps and
/// reopens. This mirrors the file-private fixture in
/// `StoragePersistenceCompositionServiceTests`, which cannot be imported.
private final class RestoreCompositionFixture: @unchecked Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let installationID = UUID()
    let rootIDs: [OwnedRootKind: UUID] = [
        .applicationSupport: UUID(),
        .caches: UUID(),
        .temporary: UUID()
    ]
    private let decisionID = UUID()

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextBackupRestore-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
    }

    func plan() throws -> PreviewRootCreationPlan {
        try PreviewRootCreationPlan(layout: layout, installationID: installationID, rootIDs: rootIDs)
    }

    func decision() throws -> ProtectionDecisionReceipt {
        try ProtectionDecisionReceipt(
            decisionID: decisionID,
            selectedAt: Date(timeIntervalSince1970: 860),
            rationaleVersion: 1
        )
    }

    func bootstrapper() -> StorageBootstrapService {
        StorageBootstrapService(layout: layout, locationAdmission: RestoreFixedAdmission())
    }

    @discardableResult
    func writeBackup(
        from store: SQLiteStore,
        named name: String,
        protection: PersistenceProtectionPlan
    ) async throws -> String {
        let fileURL = layout.databaseBackupsRoot.appending(path: name, directoryHint: .notDirectory)
        let receipt = try await store.createOnlineBackup(
            at: try ExclusiveSQLiteBackupDestination(exactFileURL: fileURL),
            protection: protection
        )
        try writeManifest(
            for: fileURL,
            reason: "manual",
            createdAt: Date(timeIntervalSince1970: 1_788_689_700),
            // Mirrors what the producer records. Both accessors return the same
            // number while migrations stay contiguous, so this cannot catch a
            // regression to the count; it keeps the fixture honest, not guarded.
            schemaVersion: SQLiteStore.supportedSchemaVersion,
            protectionMode: "ordinarySQLite",
            decisionID: protection.decision.decisionID,
            pageCount: receipt.databasePageCount
        )
        return name
    }

    static func teammate() throws -> Teammate {
        let instant = Date(timeIntervalSince1970: 1_757_000_000)
        return try Teammate(
            id: TeammateID(UUID(uuidString: "9E000000-0000-0000-0000-000000000001")!),
            profile: TeammateProfile(displayName: "Restored partner", role: "Research"),
            appearance: AgentAppearance(
                mode: .creature,
                grammarVersion: 1,
                deterministicSeed: 42,
                silhouette: "round",
                paletteToken: "sky",
                eyeDialect: "bright",
                nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature"
            ),
            createdAt: instant,
            updatedAt: instant
        )
    }

    func remove() {
        guard root.path.hasPrefix("/private/tmp/OpenBotsNextBackupRestore-"),
              root.path.hasSuffix(".noindex") else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
