import Darwin
import Foundation
@testable import OpenBotsContent
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

private let admittedBackupLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "backup-containment-test-volume"
)

private struct FixedBackupAdmission: MacOSLocationAdmissionChecking {
    let observation: LocationObservation

    func observation(for url: URL) async throws -> LocationObservation {
        observation
    }
}

private struct ActionBackupAdmission: MacOSLocationAdmissionChecking {
    let action: @Sendable () throws -> Void

    func observation(for url: URL) async throws -> LocationObservation {
        try action()
        return admittedBackupLocation
    }
}

private actor RecordingBackupExecutor: SQLiteBackupExecuting {
    struct Invocation: Equatable, Sendable {
        let destination: URL
        let protection: PersistenceProtectionPlan
    }

    private let source: URL
    private var capturedInvocation: Invocation?

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
        capturedInvocation = Invocation(
            destination: destination.exactFileURL,
            protection: protection
        )
        return SQLiteOnlineBackupReceipt(
            destinationFileURL: destination.exactFileURL,
            databasePageCount: 17
        )
    }

    func invocation() -> Invocation? {
        capturedInvocation
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

private final class SQLiteBackupContainmentFixture: @unchecked Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let installationID = UUID()
    let applicationSupportRootID = UUID()

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextSQLiteBackupContainmentTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try materializeOwnedRoot(
            layout.applicationSupportRoot,
            installationID: installationID,
            rootID: applicationSupportRootID
        )
        try FileManager.default.createDirectory(
            at: layout.databaseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.databaseBackupsRoot,
            withIntermediateDirectories: true
        )
        try Data("sqlite-source-sentinel".utf8).write(to: layout.databaseURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.databaseURL.path
        )
    }

    deinit {
        let path = root.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextSQLiteBackupContainmentTests-"),
              path.hasSuffix(".noindex")
        else {
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    func verifiedApplicationSupportRoot() throws -> VerifiedOwnedRoot {
        try OwnedRootVerifier().verify(
            layout.applicationSupportRoot,
            expectedInstallationID: installationID,
            expectedRootID: applicationSupportRootID
        )
    }

    func nestedBackupDirectory() throws -> URL {
        let directory = layout.databaseBackupsRoot
            .appending(path: "schema-0001", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func materializeOwnedRoot(
        _ descriptor: OwnedRootDescriptor,
        installationID: UUID,
        rootID: UUID
    ) throws {
        try FileManager.default.createDirectory(at: descriptor.url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: descriptor.url.path
        )
        try writeMarker(
            at: descriptor.ownershipMarkerURL,
            bundleIdentifier: OpenBotsPreviewIdentity.bundleIdentifier,
            installationID: installationID,
            rootID: rootID,
            kind: descriptor.kind
        )
    }

    func writeMarker(
        at url: URL,
        bundleIdentifier: String,
        installationID: UUID,
        rootID: UUID,
        kind: OwnedRootKind
    ) throws {
        struct Marker: Codable {
            let formatVersion: Int
            let bundleIdentifier: String
            let installationID: UUID
            let rootID: UUID
            let kind: OwnedRootKind
        }
        let marker = Marker(
            formatVersion: OwnedRootMarker.currentFormatVersion,
            bundleIdentifier: bundleIdentifier,
            installationID: installationID,
            rootID: rootID,
            kind: kind
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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

private func backupProtectionPlan() throws -> PersistenceProtectionPlan {
    .ordinarySQLite(
        decision: try ProtectionDecisionReceipt(
            decisionID: UUID(uuidString: "8B000000-0000-0000-0000-000000000001")!,
            selectedAt: Date(timeIntervalSince1970: 8_800),
            rationaleVersion: 1
        )
    )
}

@Suite("SQLite backup containment")
struct SQLiteBackupContainmentServiceTests {
    @Test("The verified service seam performs a real WAL-consistent SQLite backup")
    func performsRealSQLiteBackup() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        try FileManager.default.removeItem(at: fixture.layout.databaseURL)
        let protection = try backupProtectionPlan()
        let sourceStore = try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: fixture.layout.databaseURL,
                protection: protection
            )
        )
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        let receipt = try await service.createBackup(
            at: destination,
            inside: fixture.verifiedApplicationSupportRoot(),
            protection: protection,
            using: SQLiteStoreBackupExecutor(store: sourceStore)
        )

        #expect(receipt.destinationFileURL == destination)
        #expect(receipt.databasePageCount > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let destinationMode = try #require(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(destinationMode.uint16Value & 0o777 == 0o600)
        let reopened = try SQLiteStore(
            configuration: SQLiteStoreConfiguration(
                fileURL: destination,
                protection: protection
            )
        )
        #expect(try await reopened.integrityCheck())
    }

    @Test("A nested exact backup destination is verified and executed without planner mutation")
    func acceptsNestedOwnedDestination() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let protection = try backupProtectionPlan()
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        let receipt = try await service.createBackup(
            at: destination,
            inside: fixture.verifiedApplicationSupportRoot(),
            protection: protection,
            using: executor
        )

        #expect(receipt.destinationFileURL == destination)
        #expect(receipt.databasePageCount == 17)
        #expect(
            await executor.invocation() == .init(
                destination: destination,
                protection: protection
            )
        )
        #expect(try fixture.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(
        "Destination, WAL, and SHM collisions fail before the executor runs",
        arguments: ["", "-wal", "-shm"]
    )
    func rejectsEveryCollision(suffix: String) async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let collision = URL(fileURLWithPath: destination.path + suffix)
        let sentinel = Data("never-replace".utf8)
        try sentinel.write(to: collision, options: .withoutOverwriting)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected collision rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .destinationCollision)
        }

        #expect(await executor.invocation() == nil)
        #expect(try Data(contentsOf: collision) == sentinel)
        #expect(try fixture.snapshot() == before)
    }

    @Test("A symlinked nested parent cannot escape the backup root")
    func rejectsSymlinkEscape() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let external = fixture.root.appending(path: "External", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedParent = fixture.layout.databaseBackupsRoot.appending(
            path: "Linked",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: external)
        let destination = linkedParent.appending(path: "Escaped.sqlite", directoryHint: .notDirectory)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected symlink rejection")
        } catch let error as SQLiteBackupContainmentError {
            guard case let .destinationParentUnsafe(pathError) = error,
                  case .symlinkEncountered = pathError
            else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(await executor.invocation() == nil)
        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "Escaped.sqlite").path))
        #expect(try fixture.snapshot() == before)
    }

    @Test("Traversal to the live database is recognized as a source alias")
    func rejectsSourceAliasTraversal() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let schema = fixture.layout.databaseBackupsRoot.appending(path: "schema", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: schema, withIntermediateDirectories: true)
        let destination = URL(
            fileURLWithPath: schema
                .appending(path: "../../State/OpenBots.sqlite", directoryHint: .notDirectory)
                .path
        )
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected source-alias rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .destinationAliasesSource)
        }

        #expect(await executor.invocation() == nil)
        #expect(try fixture.snapshot() == before)
    }

    @Test("A user-selected path outside DatabaseBackups is never treated as owned")
    func rejectsExternalUserDestination() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let userFolder = fixture.root.appending(path: "UserSelected", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let destination = userFolder.appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected external-path rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .destinationOutsideBackupRoot)
        }

        #expect(await executor.invocation() == nil)
        #expect(try fixture.snapshot() == before)
    }

    @Test(
        "Managed and uncertain provider observations fail closed without mutation",
        arguments: [
            FileProviderStatus.managed(providerIdentifier: "provider-domain"),
            FileProviderStatus.uncertain(reason: "provider lookup unavailable")
        ]
    )
    func rejectsProviderOrUncertainLocation(status: FileProviderStatus) async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let observation = LocationObservation(
            isLocalVolume: true,
            isReadOnlyVolume: false,
            isUbiquitousItem: false,
            fileProviderStatus: status,
            volumeIdentifier: "provider-test-volume"
        )
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: observation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected provider-location rejection")
        } catch let error as SQLiteBackupContainmentError {
            guard case let .unsafeLocation(violation) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            switch status {
            case .managed:
                #expect(violation == .fileProviderManaged)
            case .uncertain:
                #expect(violation == .fileProviderUnknown)
            case .notManaged:
                Issue.record("The test does not supply an admitted status")
            }
        }

        #expect(await executor.invocation() == nil)
        #expect(try fixture.snapshot() == before)
    }

    @Test("A similarly marked nested root or a different owned-root kind is rejected")
    func rejectsWrongRootDescriptor() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let nestedDescriptor = OwnedRootDescriptor(
            kind: .applicationSupport,
            url: fixture.layout.databaseBackupsRoot.appending(path: "NestedOwned", directoryHint: .isDirectory)
        )
        let nestedRootID = UUID()
        try fixture.materializeOwnedRoot(
            nestedDescriptor,
            installationID: fixture.installationID,
            rootID: nestedRootID
        )
        let nested = try OwnedRootVerifier().verify(
            nestedDescriptor,
            expectedInstallationID: fixture.installationID,
            expectedRootID: nestedRootID
        )
        try fixture.materializeOwnedRoot(
            fixture.layout.cacheRoot,
            installationID: fixture.installationID,
            rootID: UUID()
        )
        let cacheMarker = try JSONDecoder().decode(
            OwnedRootMarker.self,
            from: Data(contentsOf: fixture.layout.cacheRoot.ownershipMarkerURL)
        )
        let cache = try OwnedRootVerifier().verify(
            fixture.layout.cacheRoot,
            expectedInstallationID: fixture.installationID,
            expectedRootID: cacheMarker.rootID
        )
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        for wrongRoot in [nested, cache] {
            do {
                _ = try await service.createBackup(
                    at: destination,
                    inside: wrongRoot,
                    protection: backupProtectionPlan(),
                    using: executor
                )
                Issue.record("Expected owned-root descriptor rejection")
            } catch let error as SQLiteBackupContainmentError {
                #expect(error == .unexpectedOwnedRoot)
            }
        }
        #expect(await executor.invocation() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(
        "Bundle, kind, and root-ID marker corruption invalidate a previously verified root",
        arguments: ["bundle", "kind", "root-id"]
    )
    func rejectsChangedMarker(corruption: String) async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let previouslyVerified = try fixture.verifiedApplicationSupportRoot()
        let bundle = corruption == "bundle"
            ? "com.example.not-openbots"
            : OpenBotsPreviewIdentity.bundleIdentifier
        let kind: OwnedRootKind = corruption == "kind" ? .caches : .applicationSupport
        let rootID = corruption == "root-id" ? UUID() : fixture.applicationSupportRootID
        try fixture.writeMarker(
            at: fixture.layout.applicationSupportRoot.ownershipMarkerURL,
            bundleIdentifier: bundle,
            installationID: fixture.installationID,
            rootID: rootID,
            kind: kind
        )
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let before = try fixture.snapshot()
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: previouslyVerified,
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected changed-marker rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .ownedRootInvalid(.markerMismatch))
        }

        #expect(await executor.invocation() == nil)
        #expect(try fixture.snapshot() == before)
    }

    @Test("Renaming the backup root during location admission invalidates its inode receipt")
    func rejectsRenamedBackupRoot() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let destination = try fixture.nestedBackupDirectory()
            .appending(path: "Snapshot.sqlite", directoryHint: .notDirectory)
        let renamed = fixture.layout.databaseBackupsRoot
            .deletingLastPathComponent()
            .appending(path: "DatabaseBackups-renamed", directoryHint: .isDirectory)
        let executor = RecordingBackupExecutor(source: fixture.layout.databaseURL)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: ActionBackupAdmission {
                try FileManager.default.moveItem(
                    at: fixture.layout.databaseBackupsRoot,
                    to: renamed
                )
            }
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: fixture.verifiedApplicationSupportRoot(),
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected renamed-root rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .backupRootIdentityChanged)
        }

        #expect(await executor.invocation() == nil)
        #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "Snapshot.sqlite").path))
    }

    @Test("A stale verified application-support root cannot survive a rename")
    func rejectsStaleOwnedRootAfterRename() async throws {
        let fixture = try SQLiteBackupContainmentFixture()
        let previouslyVerified = try fixture.verifiedApplicationSupportRoot()
        let renamed = fixture.layout.applicationSupportRoot.url
            .deletingLastPathComponent()
            .appending(path: "RenamedPreviewRoot", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: fixture.layout.applicationSupportRoot.url, to: renamed)
        let executor = RecordingBackupExecutor(
            source: renamed
                .appending(path: "HighChurn.noindex/State/OpenBots.sqlite", directoryHint: .notDirectory)
        )
        let destination = renamed
            .appending(path: "HighChurn.noindex/DatabaseBackups/Snapshot.sqlite", directoryHint: .notDirectory)
        let service = SQLiteBackupContainmentService(
            layout: fixture.layout,
            locationAdmission: FixedBackupAdmission(observation: admittedBackupLocation)
        )

        do {
            _ = try await service.createBackup(
                at: destination,
                inside: previouslyVerified,
                protection: backupProtectionPlan(),
                using: executor
            )
            Issue.record("Expected stale-root rejection")
        } catch let error as SQLiteBackupContainmentError {
            #expect(error == .ownedRootInvalid(.rootMissing))
        }

        #expect(await executor.invocation() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
