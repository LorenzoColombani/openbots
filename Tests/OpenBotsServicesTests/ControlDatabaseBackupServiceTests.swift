import CryptoKit
import Darwin
import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

private let admittedControlBackupLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "control-backup-test-volume"
)

private struct FixedControlBackupAdmission: MacOSLocationAdmissionChecking {
    let observation: LocationObservation

    func observation(for url: URL) async throws -> LocationObservation {
        observation
    }
}

/// Proves the missing-folder failure happens before any backup is attempted.
private actor RefusingBackupExecutor: SQLiteBackupExecuting {
    private let source: URL
    private var wasInvoked = false

    init(source: URL) {
        self.source = source
    }

    func sourceDatabaseURL() -> URL {
        source
    }

    func createOnlineBackup(
        at destination: ExclusiveSQLiteBackupDestination,
        protection: PersistenceProtectionPlan
    ) throws -> SQLiteOnlineBackupReceipt {
        wasInvoked = true
        return SQLiteOnlineBackupReceipt(
            destinationFileURL: destination.exactFileURL,
            databasePageCount: 1
        )
    }

    func invoked() -> Bool {
        wasInvoked
    }
}

private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base: Date
    private let interval: TimeInterval
    private var step = 0

    init(base: Date, interval: TimeInterval) {
        self.base = base
        self.interval = interval
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = base.addingTimeInterval(Double(step) * interval)
        step += 1
        return date
    }
}

private enum FixtureEntry: Equatable {
    case directory
    case file(Data)
    case symbolicLink(String)
    case other
}

private struct FixtureSnapshot: Equatable {
    let entries: [String: FixtureEntry]
}

private struct FileFingerprint: Equatable {
    let bytes: Data
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

/// The exact on-disk manifest, read back without going through the service's
/// own Codable types so an accidental extra or renamed field fails the test.
private struct RawManifest: Sendable {
    let keys: Set<String>
    let strings: [String: String]
    let numbers: [String: Int]
}

private final class ControlDatabaseBackupFixture: @unchecked Sendable {
    static let rootPrefix = "/private/tmp/OpenBotsNextControlBackup-"

    let root: URL
    let layout: PreviewStorageLayout
    let installationID = UUID()
    let applicationSupportRootID = UUID()

    init(createBackupsRoot: Bool = true) throws {
        root = URL(
            fileURLWithPath: "\(Self.rootPrefix)\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let descriptor = layout.applicationSupportRoot
        try FileManager.default.createDirectory(at: descriptor.url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: descriptor.url.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let marker = OwnedRootMarker(
            installationID: installationID,
            rootID: applicationSupportRootID,
            kind: descriptor.kind
        )
        try encoder.encode(marker).write(to: descriptor.ownershipMarkerURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: descriptor.ownershipMarkerURL.path
        )

        try FileManager.default.createDirectory(
            at: layout.databaseDirectory,
            withIntermediateDirectories: true
        )
        if createBackupsRoot {
            try FileManager.default.createDirectory(
                at: layout.databaseBackupsRoot,
                withIntermediateDirectories: true
            )
        }
    }

    deinit {
        let path = root.path
        guard path.hasPrefix(Self.rootPrefix), path.hasSuffix(".noindex") else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func verifiedApplicationSupportRoot() throws -> VerifiedOwnedRoot {
        try OwnedRootVerifier().verify(
            layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: applicationSupportRootID
        )
    }

    func openStore(protection: PersistenceProtectionPlan) throws -> SQLiteStore {
        try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: layout.databaseURL,
                protection: protection
            )
        )
    }

    func backupFileNames() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: layout.databaseBackupsRoot.path)
            .sorted()
    }

    func snapshot() throws -> FixtureSnapshot {
        var entries: [String: FixtureEntry] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        ) else {
            return FixtureSnapshot(entries: entries)
        }
        while let item = enumerator.nextObject() as? URL {
            var value = stat()
            guard lstat(item.path, &value) == 0 else { continue }
            let relative = String(item.path.dropFirst(root.path.count + 1))
            switch value.st_mode & S_IFMT {
            case S_IFDIR:
                entries[relative] = .directory
            case S_IFREG:
                entries[relative] = .file(try Data(contentsOf: item))
            case S_IFLNK:
                entries[relative] = .symbolicLink(
                    try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                )
                enumerator.skipDescendants()
            default:
                entries[relative] = .other
            }
        }
        return FixtureSnapshot(entries: entries)
    }
}

private func controlBackupProtectionPlan() throws -> PersistenceProtectionPlan {
    .ordinarySQLite(
        decision: try ProtectionDecisionReceipt(
            decisionID: UUID(uuidString: "9C000000-0000-0000-0000-0000000000A1")!,
            selectedAt: Date(timeIntervalSince1970: 9_900),
            rationaleVersion: 1
        )
    )
}

private func controlBackupTeammate() throws -> Teammate {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return try Teammate(
        id: TeammateID(UUID(uuidString: "9C000000-0000-0000-0000-0000000000B2")!),
        profile: TeammateProfile(displayName: "Backup Partner", role: "Research"),
        appearance: AgentAppearance(
            mode: .creature,
            grammarVersion: 1,
            deterministicSeed: 6,
            silhouette: "round",
            paletteToken: "sky",
            eyeDialect: "bright",
            nonColorIdentityCue: "single crest",
            accessibleIdentityDescription: "Round creature with a crest"
        ),
        createdAt: date,
        updatedAt: date
    )
}

/// 2026-09-06T12:00:00Z. The manifest assertion below re-checks this instant
/// against the ISO 8601 text the service actually wrote.
private let controlBackupInstant = Date(timeIntervalSince1970: 1_788_696_000)

private func posixMode(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let mode = attributes[.posixPermissions] as? NSNumber else {
        throw CocoaError(.fileReadUnknown)
    }
    return mode.uint16Value & 0o777
}

private func fingerprint(of url: URL) throws -> FileFingerprint {
    let bytes = try Data(contentsOf: url)
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        throw CocoaError(.fileNoSuchFile)
    }
    return FileFingerprint(
        bytes: bytes,
        modifiedSeconds: Int(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int(value.st_mtimespec.tv_nsec)
    )
}

private func rawManifest(at url: URL) throws -> RawManifest {
    let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
    let fields = object as? [String: Any] ?? [:]
    var strings: [String: String] = [:]
    var numbers: [String: Int] = [:]
    for (key, value) in fields {
        if let text = value as? String {
            strings[key] = text
        } else if let number = value as? NSNumber {
            numbers[key] = number.intValue
        }
    }
    return RawManifest(keys: Set(fields.keys), strings: strings, numbers: numbers)
}

private func hexDigest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("Control database backups")
struct ControlDatabaseBackupServiceTests {
    @Test("A real control-database snapshot is written with a verified manifest")
    func writesVerifiedBackupOfALiveDatabase() async throws {
        let fixture = try ControlDatabaseBackupFixture()
        let protection = try controlBackupProtectionPlan()
        let store = try fixture.openStore(protection: protection)
        let teammate = try controlBackupTeammate()
        try await store.insert(teammate)
        let ownedRoot = try fixture.verifiedApplicationSupportRoot()
        let service = ControlDatabaseBackupService(
            layout: fixture.layout,
            applicationSupportRoot: ownedRoot,
            protection: protection,
            executor: SQLiteStoreBackupExecutor(store: store),
            locationAdmission: FixedControlBackupAdmission(observation: admittedControlBackupLocation),
            clock: { controlBackupInstant }
        )

        let record = try await service.backupNow(reason: .manual)

        #expect(record.fileName == "OpenBots-20260906T120000Z-manual.sqlite")
        #expect(record.fileURL.lastPathComponent == record.fileName)
        #expect(record.fileURL.deletingLastPathComponent().lastPathComponent == "DatabaseBackups")
        #expect(record.manifestURL.lastPathComponent == "\(record.fileName).json")
        #expect(record.reason == .manual)
        #expect(record.createdAt == controlBackupInstant)
        #expect(record.prunedFileNames.isEmpty)
        #expect(record.databasePageCount > 0)
        // The manifest records the bound the migrator enforces, never the
        // migration count. While migration versions stay contiguous the two are
        // equal, so this assertion cannot by itself catch a regression back to
        // the count; it only pins the intended source.
        #expect(record.schemaVersion == SQLiteStore.supportedSchemaVersion)
        #expect(record.protectionMode == "ordinarySQLite")
        #expect(record.decisionID == "9c000000-0000-0000-0000-0000000000a1")

        // Everything below must run before the backup is reopened: opening it as
        // a store sets WAL journalling, which creates the sidecars and rewrites
        // the file this manifest describes.
        let backupBytes = try Data(contentsOf: record.fileURL)
        #expect(record.byteCount == backupBytes.count)
        #expect(record.sha256 == hexDigest(of: backupBytes))
        #expect(try posixMode(of: record.fileURL) == 0o600)
        #expect(try posixMode(of: record.manifestURL) == 0o600)

        let manifest = try rawManifest(at: record.manifestURL)
        #expect(manifest.keys == [
            "byteCount",
            "createdAt",
            "databasePageCount",
            "decisionID",
            "fileName",
            "formatVersion",
            "protectionMode",
            "reason",
            "schemaVersion",
            "sha256"
        ])
        #expect(manifest.strings["createdAt"] == "2026-09-06T12:00:00Z")
        #expect(manifest.strings["fileName"] == record.fileName)
        #expect(manifest.strings["reason"] == "manual")
        #expect(manifest.strings["sha256"] == hexDigest(of: backupBytes))
        #expect(manifest.strings["protectionMode"] == "ordinarySQLite")
        #expect(manifest.strings["decisionID"] == "9c000000-0000-0000-0000-0000000000a1")
        #expect(manifest.numbers["formatVersion"] == 1)
        #expect(manifest.numbers["byteCount"] == backupBytes.count)
        #expect(manifest.numbers["schemaVersion"] == SQLiteStore.supportedSchemaVersion)
        #expect(manifest.numbers["databasePageCount"] == record.databasePageCount)

        let walURL = URL(fileURLWithPath: record.fileURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: record.fileURL.path + "-shm")
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))

        let reopened = try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: record.fileURL,
                protection: protection
            )
        )
        #expect(try await reopened.integrityCheck())
        let restored = try await reopened.teammate(id: teammate.id)
        #expect(restored?.profile.displayName == "Backup Partner")
        #expect(try await store.integrityCheck())
    }

    @Test("Retention keeps the newest five pairs and touches nothing else")
    func retainsOnlyTheNewestBackups() async throws {
        let fixture = try ControlDatabaseBackupFixture()
        let protection = try controlBackupProtectionPlan()
        let store = try fixture.openStore(protection: protection)
        try await store.insert(controlBackupTeammate())
        let liveBefore = try fingerprint(of: fixture.layout.databaseURL)

        let backupsRoot = fixture.layout.databaseBackupsRoot
        let notes = backupsRoot.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("keep me".utf8).write(to: notes, options: .withoutOverwriting)
        let vault = backupsRoot.appending(path: "Vault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let vaultFile = vault.appending(path: "keep.txt", directoryHint: .notDirectory)
        try Data("nested".utf8).write(to: vaultFile, options: .withoutOverwriting)

        // A directory wearing a backup's name, with a manifest that would make it
        // the oldest candidate. Retention must still never delete a directory.
        let decoyName = "OpenBots-20000101T000000Z-manual.sqlite"
        let decoy = backupsRoot.appending(path: decoyName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        let decoyManifest = ControlDatabaseBackupManifest(
            formatVersion: 1,
            fileName: decoyName,
            reason: .manual,
            createdAt: Date(timeIntervalSince1970: 946_684_800),
            byteCount: 0,
            sha256: String(repeating: "0", count: 64),
            databasePageCount: 0,
            schemaVersion: SQLiteStore.supportedSchemaVersion,
            protectionMode: "ordinarySQLite",
            decisionID: "9c000000-0000-0000-0000-0000000000a1"
        )
        try ControlDatabaseBackupService.manifestEncoder()
            .encode(decoyManifest)
            .write(
                to: backupsRoot.appending(path: "\(decoyName).json", directoryHint: .notDirectory),
                options: .withoutOverwriting
            )

        let clock = SteppingClock(base: controlBackupInstant, interval: 60)
        let ownedRoot = try fixture.verifiedApplicationSupportRoot()
        let service = ControlDatabaseBackupService(
            layout: fixture.layout,
            applicationSupportRoot: ownedRoot,
            protection: protection,
            executor: SQLiteStoreBackupExecutor(store: store),
            locationAdmission: FixedControlBackupAdmission(observation: admittedControlBackupLocation),
            clock: { clock.next() }
        )

        var records: [ControlDatabaseBackupRecord] = []
        for _ in 0..<7 {
            records.append(try await service.backupNow(reason: .scheduled))
        }

        let names = records.map(\.fileName)
        #expect(names == [
            "OpenBots-20260906T120000Z-scheduled.sqlite",
            "OpenBots-20260906T120100Z-scheduled.sqlite",
            "OpenBots-20260906T120200Z-scheduled.sqlite",
            "OpenBots-20260906T120300Z-scheduled.sqlite",
            "OpenBots-20260906T120400Z-scheduled.sqlite",
            "OpenBots-20260906T120500Z-scheduled.sqlite",
            "OpenBots-20260906T120600Z-scheduled.sqlite"
        ])
        #expect(records[0...4].allSatisfy { $0.prunedFileNames.isEmpty })
        #expect(records[5].prunedFileNames == [names[0]])
        #expect(records[6].prunedFileNames == [names[1]])

        let listed = try await service.listRecords()
        #expect(listed.map(\.fileName) == names[2...6].reversed().map { $0 })

        let onDisk = try fixture.backupFileNames()
        let survivingBackups = onDisk.filter { $0.hasPrefix("OpenBots-") && $0.hasSuffix(".sqlite") }
        #expect(survivingBackups == (Array(names[2...6]) + [decoyName]).sorted())
        let survivingManifests = onDisk.filter { $0.hasSuffix(".sqlite.json") }
        #expect(
            survivingManifests
                == (names[2...6].map { "\($0).json" } + ["\(decoyName).json"]).sorted()
        )
        #expect(!FileManager.default.fileExists(atPath: backupsRoot.appending(path: names[0]).path))
        #expect(!FileManager.default.fileExists(atPath: backupsRoot.appending(path: "\(names[0]).json").path))
        #expect(!FileManager.default.fileExists(atPath: backupsRoot.appending(path: names[1]).path))
        #expect(!FileManager.default.fileExists(atPath: backupsRoot.appending(path: "\(names[1]).json").path))

        #expect(try Data(contentsOf: notes) == Data("keep me".utf8))
        #expect(try Data(contentsOf: vaultFile) == Data("nested".utf8))
        var decoyStat = stat()
        let decoyStatResult = lstat(decoy.path, &decoyStat)
        #expect(decoyStatResult == 0)
        #expect(decoyStat.st_mode & S_IFMT == S_IFDIR)
        #expect(try fingerprint(of: fixture.layout.databaseURL) == liveBefore)
        #expect(try await store.integrityCheck())
    }

    @Test("Backups taken in the same second get suffixed names and overwrite nothing")
    func suffixesSameSecondNames() async throws {
        let fixture = try ControlDatabaseBackupFixture()
        let protection = try controlBackupProtectionPlan()
        let store = try fixture.openStore(protection: protection)
        try await store.insert(controlBackupTeammate())
        let ownedRoot = try fixture.verifiedApplicationSupportRoot()
        let service = ControlDatabaseBackupService(
            layout: fixture.layout,
            applicationSupportRoot: ownedRoot,
            protection: protection,
            executor: SQLiteStoreBackupExecutor(store: store),
            locationAdmission: FixedControlBackupAdmission(observation: admittedControlBackupLocation),
            clock: { controlBackupInstant }
        )

        let first = try await service.backupNow(reason: .quit)
        let firstBackup = try fingerprint(of: first.fileURL)
        let firstManifest = try fingerprint(of: first.manifestURL)
        let second = try await service.backupNow(reason: .quit)
        let third = try await service.backupNow(reason: .quit)

        #expect(first.fileName == "OpenBots-20260906T120000Z-quit.sqlite")
        #expect(second.fileName == "OpenBots-20260906T120000Z-quit-2.sqlite")
        #expect(third.fileName == "OpenBots-20260906T120000Z-quit-3.sqlite")
        #expect(Set([first, second, third].map(\.fileURL)).count == 3)
        #expect(try fingerprint(of: first.fileURL) == firstBackup)
        #expect(try fingerprint(of: first.manifestURL) == firstManifest)
        #expect(try fixture.backupFileNames() == [
            "OpenBots-20260906T120000Z-quit-2.sqlite",
            "OpenBots-20260906T120000Z-quit-2.sqlite.json",
            "OpenBots-20260906T120000Z-quit-3.sqlite",
            "OpenBots-20260906T120000Z-quit-3.sqlite.json",
            "OpenBots-20260906T120000Z-quit.sqlite",
            "OpenBots-20260906T120000Z-quit.sqlite.json"
        ])
        #expect(try await service.listRecords().count == 3)
        #expect(try await store.integrityCheck())
    }

    @Test("Listing returns newest first and skips a malformed manifest")
    func listsNewestFirstSkippingMalformedManifests() async throws {
        let fixture = try ControlDatabaseBackupFixture()
        let protection = try controlBackupProtectionPlan()
        let store = try fixture.openStore(protection: protection)
        try await store.insert(controlBackupTeammate())
        let clock = SteppingClock(base: controlBackupInstant, interval: 60)
        let ownedRoot = try fixture.verifiedApplicationSupportRoot()
        let service = ControlDatabaseBackupService(
            layout: fixture.layout,
            applicationSupportRoot: ownedRoot,
            protection: protection,
            executor: SQLiteStoreBackupExecutor(store: store),
            locationAdmission: FixedControlBackupAdmission(observation: admittedControlBackupLocation),
            clock: { clock.next() }
        )

        let oldest = try await service.backupNow(reason: .scheduled)
        let middle = try await service.backupNow(reason: .manual)
        let newest = try await service.backupNow(reason: .quit)
        #expect(try await service.listRecords().map(\.fileName) == [
            newest.fileName,
            middle.fileName,
            oldest.fileName
        ])

        try FileManager.default.removeItem(at: middle.manifestURL)
        try Data("{ this is not a manifest".utf8).write(
            to: middle.manifestURL,
            options: .withoutOverwriting
        )

        let listed = try await service.listRecords()
        #expect(listed.map(\.fileName) == [newest.fileName, oldest.fileName])
        #expect(listed.map(\.createdAt) == [
            controlBackupInstant.addingTimeInterval(120),
            controlBackupInstant
        ])
        #expect(listed.allSatisfy { $0.prunedFileNames.isEmpty })
        #expect(listed.first?.reason == .quit)
        #expect(listed.last?.reason == .scheduled)
        #expect(FileManager.default.fileExists(atPath: middle.fileURL.path))
        #expect(try await store.integrityCheck())
    }

    @Test("A missing backups folder fails before anything is created")
    func refusesToCreateTheBackupsFolder() async throws {
        let fixture = try ControlDatabaseBackupFixture(createBackupsRoot: false)
        let protection = try controlBackupProtectionPlan()
        let executor = RefusingBackupExecutor(source: fixture.layout.databaseURL)
        let ownedRoot = try fixture.verifiedApplicationSupportRoot()
        let before = try fixture.snapshot()
        let service = ControlDatabaseBackupService(
            layout: fixture.layout,
            applicationSupportRoot: ownedRoot,
            protection: protection,
            executor: executor,
            locationAdmission: FixedControlBackupAdmission(observation: admittedControlBackupLocation)
        )

        await #expect(throws: ControlDatabaseBackupError.backupsDirectoryMissing) {
            _ = try await service.backupNow(reason: .quit)
        }
        await #expect(throws: ControlDatabaseBackupError.backupsDirectoryMissing) {
            _ = try await service.listRecords()
        }

        #expect(await executor.invoked() == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseBackupsRoot.path))
        #expect(try fixture.snapshot() == before)
    }
}
