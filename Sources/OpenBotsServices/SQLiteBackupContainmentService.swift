import Darwin
import Foundation
import OpenBotsContent
import OpenBotsPersistence

/// The execution seam is deliberately narrower than returning an approved pathname.
/// Implementations receive a persistence destination only after the app-owned root,
/// source database, enclosing backup tree, location, and collision checks succeed.
public protocol SQLiteBackupExecuting: Sendable {
    func sourceDatabaseURL() async -> URL

    func createOnlineBackup(
        at destination: ExclusiveSQLiteBackupDestination,
        protection: PersistenceProtectionPlan
    ) async throws -> SQLiteOnlineBackupReceipt
}

public struct SQLiteStoreBackupExecutor: SQLiteBackupExecuting {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func sourceDatabaseURL() async -> URL {
        await store.fileURL
    }

    public func createOnlineBackup(
        at destination: ExclusiveSQLiteBackupDestination,
        protection: PersistenceProtectionPlan
    ) async throws -> SQLiteOnlineBackupReceipt {
        try await store.createOnlineBackup(at: destination, protection: protection)
    }
}

public enum SQLiteBackupContainmentError: Error, Equatable, Sendable {
    case unexpectedOwnedRoot
    case ownedRootInvalid(OwnedRootError)
    case ownedRootInspectionFailed
    case ownedRootIdentityChanged
    case sourceDatabaseMismatch
    case sourceDatabaseUnsafe(PathSafetyError)
    case sourceDatabaseUnsupportedType
    case sourceDatabaseDeviceMismatch
    case sourceDatabaseIdentityChanged
    case backupRootUnsafe(PathSafetyError)
    case backupRootDeviceMismatch
    case backupRootIdentityChanged
    case invalidDestination
    case destinationParentUnsafe(PathSafetyError)
    case destinationParentDeviceMismatch
    case destinationOutsideBackupRoot
    case destinationAliasesSource
    case destinationCollision
    case locationInspectionFailed
    case unsafeLocation(HighChurnLocationViolation)
}

/// Authorizes and immediately performs one SQLite online backup inside the preview's
/// marker-owned `DatabaseBackups` tree. This service never creates roots, parents,
/// markers, staging material, or destination files itself.
public struct SQLiteBackupContainmentService: Sendable {
    private let layout: PreviewStorageLayout
    private let locationAdmission: any MacOSLocationAdmissionChecking
    private let pathSafety = PathSafety()
    private let locationValidator = HighChurnLocationValidator()

    public init(
        layout: PreviewStorageLayout,
        locationAdmission: any MacOSLocationAdmissionChecking = MacOSLocationAdmission()
    ) {
        self.layout = layout
        self.locationAdmission = locationAdmission
    }

    public func createBackup(
        at exactFileURL: URL,
        inside applicationSupportRoot: VerifiedOwnedRoot,
        protection: PersistenceProtectionPlan,
        using executor: any SQLiteBackupExecuting
    ) async throws -> SQLiteOnlineBackupReceipt {
        guard applicationSupportRoot.kind == .applicationSupport,
              applicationSupportRoot.url == layout.applicationSupportRoot.url
        else {
            throw SQLiteBackupContainmentError.unexpectedOwnedRoot
        }

        try reverify(applicationSupportRoot)
        let ownedRoot = try captureOwnedRoot(applicationSupportRoot)

        let sourceURL = await executor.sourceDatabaseURL()
        guard sourceURL.isFileURL else {
            throw SQLiteBackupContainmentError.sourceDatabaseMismatch
        }
        let canonicalSource = try captureSource(sourceURL, inside: ownedRoot)

        let backupRoot = try captureBackupRoot(inside: ownedRoot)
        let requested = try validateDestinationShape(exactFileURL)
        let destinationParent = try captureDestinationParent(
            requested.deletingLastPathComponent(),
            finalComponent: requested.lastPathComponent,
            source: canonicalSource.path.url,
            inside: backupRoot
        )
        let exactDestination = try exclusiveDestination(
            named: requested.lastPathComponent,
            inside: destinationParent.path
        )

        guard exactDestination != canonicalSource.path.url else {
            throw SQLiteBackupContainmentError.destinationAliasesSource
        }
        try rejectSidecarCollisions(at: exactDestination)

        let observation: LocationObservation
        do {
            observation = try await locationAdmission.observation(for: destinationParent.path.url)
        } catch {
            throw SQLiteBackupContainmentError.locationInspectionFailed
        }
        do {
            try locationValidator.validate(exactDestination, observation: observation)
        } catch let violation as HighChurnLocationViolation {
            throw SQLiteBackupContainmentError.unsafeLocation(violation)
        } catch {
            throw SQLiteBackupContainmentError.locationInspectionFailed
        }

        // The async File Provider lookup creates a race boundary. Revalidate every
        // captured identity and the ownership marker immediately before execution.
        try revalidate(ownedRoot, failure: .ownedRootIdentityChanged)
        try revalidate(backupRoot, failure: .backupRootIdentityChanged)
        try revalidate(destinationParent, failure: .backupRootIdentityChanged)
        try revalidateSource(canonicalSource, inside: ownedRoot.path)
        try reverify(applicationSupportRoot)
        let revalidatedDestination = try exclusiveDestination(
            named: requested.lastPathComponent,
            inside: destinationParent.path
        )
        guard revalidatedDestination == exactDestination else {
            throw SQLiteBackupContainmentError.backupRootIdentityChanged
        }
        try rejectSidecarCollisions(at: exactDestination)

        let destination: ExclusiveSQLiteBackupDestination
        do {
            destination = try ExclusiveSQLiteBackupDestination(exactFileURL: exactDestination)
        } catch {
            throw SQLiteBackupContainmentError.invalidDestination
        }
        return try await executor.createOnlineBackup(at: destination, protection: protection)
    }

    private func reverify(_ root: VerifiedOwnedRoot) throws {
        do {
            let refreshed = try OwnedRootVerifier().verify(
                layout.applicationSupportRoot,
                expectedInstallationID: root.installationID,
                expectedRootID: root.rootID
            )
            guard refreshed == root else {
                throw SQLiteBackupContainmentError.ownedRootIdentityChanged
            }
        } catch let error as SQLiteBackupContainmentError {
            throw error
        } catch let error as OwnedRootError {
            throw SQLiteBackupContainmentError.ownedRootInvalid(error)
        } catch {
            throw SQLiteBackupContainmentError.ownedRootInspectionFailed
        }
    }

    private func captureOwnedRoot(_ root: VerifiedOwnedRoot) throws -> CapturedDirectory {
        do {
            let path = try pathSafety.canonicalExistingDirectory(root.url)
            guard let identity = path.identity else {
                throw SQLiteBackupContainmentError.ownedRootInspectionFailed
            }
            return CapturedDirectory(path: path, identity: identity)
        } catch let error as SQLiteBackupContainmentError {
            throw error
        } catch {
            throw SQLiteBackupContainmentError.ownedRootInspectionFailed
        }
    }

    private func captureSource(
        _ requestedSource: URL,
        inside ownedRoot: CapturedDirectory
    ) throws -> CapturedItem {
        let source: CanonicalPath
        do {
            source = try pathSafety.canonicalExistingItem(requestedSource, containedIn: ownedRoot.path)
        } catch let error as PathSafetyError {
            throw SQLiteBackupContainmentError.sourceDatabaseUnsafe(error)
        } catch {
            throw SQLiteBackupContainmentError.sourceDatabaseUnsafe(.unsupportedFileType)
        }
        guard source.url == layout.databaseURL else {
            throw SQLiteBackupContainmentError.sourceDatabaseMismatch
        }
        guard isRegularFile(source.url) else {
            throw SQLiteBackupContainmentError.sourceDatabaseUnsupportedType
        }
        guard let identity = source.identity else {
            throw SQLiteBackupContainmentError.sourceDatabaseUnsupportedType
        }
        guard identity.device == ownedRoot.identity.device else {
            throw SQLiteBackupContainmentError.sourceDatabaseDeviceMismatch
        }
        return CapturedItem(path: source, identity: identity)
    }

    private func captureBackupRoot(inside ownedRoot: CapturedDirectory) throws -> CapturedDirectory {
        do {
            let contained = try pathSafety.canonicalExistingItem(
                layout.databaseBackupsRoot,
                containedIn: ownedRoot.path
            )
            let directory = try pathSafety.canonicalExistingDirectory(layout.databaseBackupsRoot)
            guard contained.url == layout.databaseBackupsRoot,
                  contained.identity == directory.identity,
                  let identity = directory.identity
            else {
                throw SQLiteBackupContainmentError.backupRootIdentityChanged
            }
            guard identity.device == ownedRoot.identity.device else {
                throw SQLiteBackupContainmentError.backupRootDeviceMismatch
            }
            return CapturedDirectory(path: directory, identity: identity)
        } catch let error as SQLiteBackupContainmentError {
            throw error
        } catch let error as PathSafetyError {
            throw SQLiteBackupContainmentError.backupRootUnsafe(error)
        } catch {
            throw SQLiteBackupContainmentError.backupRootUnsafe(.unsupportedFileType)
        }
    }

    private func validateDestinationShape(_ url: URL) throws -> URL {
        guard url.isFileURL,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != "..",
              !url.lastPathComponent.contains("/"),
              !url.lastPathComponent.contains("\0")
        else {
            throw SQLiteBackupContainmentError.invalidDestination
        }
        return url
    }

    private func captureDestinationParent(
        _ requestedParent: URL,
        finalComponent: String,
        source: URL,
        inside backupRoot: CapturedDirectory
    ) throws -> CapturedDirectory {
        let parent: CanonicalPath
        do {
            parent = try pathSafety.canonicalExistingDirectory(requestedParent)
        } catch let error as PathSafetyError {
            throw SQLiteBackupContainmentError.destinationParentUnsafe(error)
        } catch {
            throw SQLiteBackupContainmentError.destinationParentUnsafe(.unsupportedFileType)
        }
        let requestedDestination = parent.url.appending(
            path: finalComponent,
            directoryHint: .notDirectory
        )
        guard requestedDestination != source else {
            throw SQLiteBackupContainmentError.destinationAliasesSource
        }
        guard pathSafety.isComponentContained(parent.url, in: backupRoot.path.url) else {
            throw SQLiteBackupContainmentError.destinationOutsideBackupRoot
        }
        do {
            let contained = try pathSafety.canonicalExistingItem(
                parent.url,
                containedIn: backupRoot.path
            )
            guard contained.identity == parent.identity, let identity = parent.identity else {
                throw SQLiteBackupContainmentError.backupRootIdentityChanged
            }
            guard identity.device == backupRoot.identity.device else {
                throw SQLiteBackupContainmentError.destinationParentDeviceMismatch
            }
            return CapturedDirectory(path: parent, identity: identity)
        } catch let error as SQLiteBackupContainmentError {
            throw error
        } catch let error as PathSafetyError {
            throw SQLiteBackupContainmentError.destinationParentUnsafe(error)
        } catch {
            throw SQLiteBackupContainmentError.destinationParentUnsafe(.unsupportedFileType)
        }
    }

    private func revalidate(
        _ directory: CapturedDirectory,
        failure: SQLiteBackupContainmentError
    ) throws {
        do {
            try pathSafety.validateIdentity(of: directory.path.url, equals: directory.identity)
        } catch {
            throw failure
        }
    }

    private func revalidateSource(_ source: CapturedItem, inside ownedRoot: CanonicalPath) throws {
        do {
            let current = try pathSafety.canonicalExistingItem(source.path.url, containedIn: ownedRoot)
            guard current.identity == source.identity, isRegularFile(current.url) else {
                throw SQLiteBackupContainmentError.sourceDatabaseIdentityChanged
            }
        } catch let error as SQLiteBackupContainmentError {
            throw error
        } catch {
            throw SQLiteBackupContainmentError.sourceDatabaseIdentityChanged
        }
    }

    private func exclusiveDestination(named name: String, inside parent: CanonicalPath) throws -> URL {
        do {
            return try pathSafety.exclusiveFutureChild(named: name, of: parent)
        } catch PathSafetyError.destinationAlreadyExists {
            throw SQLiteBackupContainmentError.destinationCollision
        } catch let error as PathSafetyError {
            throw SQLiteBackupContainmentError.destinationParentUnsafe(error)
        } catch {
            throw SQLiteBackupContainmentError.invalidDestination
        }
    }

    private func rejectSidecarCollisions(at destination: URL) throws {
        guard !itemExistsWithoutFollowing(URL(fileURLWithPath: destination.path + "-wal")),
              !itemExistsWithoutFollowing(URL(fileURLWithPath: destination.path + "-shm"))
        else {
            throw SQLiteBackupContainmentError.destinationCollision
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
    }

    private func itemExistsWithoutFollowing(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }
}

private struct CapturedDirectory: Sendable {
    let path: CanonicalPath
    let identity: CanonicalFileIdentity
}

private struct CapturedItem: Sendable {
    let path: CanonicalPath
    let identity: CanonicalFileIdentity
}
