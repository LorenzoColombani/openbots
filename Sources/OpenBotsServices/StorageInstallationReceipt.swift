import Darwin
import Foundation
import OpenBotsContent
import OpenBotsPersistence
import OpenBotsSecurity

public struct StorageInstallationRootIdentity: Codable, Equatable, Sendable {
    public let kind: OwnedRootKind
    public let rootID: UUID

    public init(kind: OwnedRootKind, rootID: UUID) {
        self.kind = kind
        self.rootID = rootID
    }
}

/// Nonsecret, immutable authority for reopening one preview installation.
/// The receipt identifies only the three app-owned internal roots; visible
/// content has a separate user-authorized lifecycle.
public struct StorageInstallationReceipt: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileName = PreviewStorageLayout.installationReceiptFileName

    public let formatVersion: Int
    public let bundleIdentifier: String
    public let installationID: UUID
    public let roots: [StorageInstallationRootIdentity]
    public let protectionSelection: DatabaseProtectionSelection
    public let protectionDecision: ProtectionDecisionReceipt

    public init(
        installationID: UUID,
        rootIDs: [OwnedRootKind: UUID],
        protectionSelection: DatabaseProtectionSelection,
        protectionDecision: ProtectionDecisionReceipt
    ) throws {
        let expectedKinds = Self.internalRootKinds
        guard Set(rootIDs.keys) == Set(expectedKinds),
              Set(rootIDs.values).count == expectedKinds.count
        else {
            throw StorageInstallationReceiptError.invalidRootIdentitySet
        }

        formatVersion = Self.currentFormatVersion
        bundleIdentifier = OpenBotsPreviewIdentity.bundleIdentifier
        self.installationID = installationID
        roots = expectedKinds.map {
            StorageInstallationRootIdentity(kind: $0, rootID: rootIDs[$0]!)
        }
        self.protectionSelection = protectionSelection
        self.protectionDecision = protectionDecision
    }

    public var rootIDs: [OwnedRootKind: UUID] {
        var result: [OwnedRootKind: UUID] = [:]
        for root in roots {
            result[root.kind] = root.rootID
        }
        return result
    }

    public func rootID(for kind: OwnedRootKind) -> UUID? {
        roots.first(where: { $0.kind == kind })?.rootID
    }

    public static func fileURL(in applicationSupportRoot: OwnedRootDescriptor) -> URL {
        applicationSupportRoot.url.appending(path: fileName, directoryHint: .notDirectory)
    }

    fileprivate static let internalRootKinds: [OwnedRootKind] = [
        .applicationSupport,
        .caches,
        .temporary
    ]

    fileprivate func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw StorageInstallationReceiptError.unsupportedFormatVersion
        }
        guard bundleIdentifier == OpenBotsPreviewIdentity.bundleIdentifier else {
            throw StorageInstallationReceiptError.bundleIdentifierMismatch
        }
        guard protectionDecision.rationaleVersion > 0 else {
            throw StorageInstallationReceiptError.invalidProtectionDecision
        }

        let expectedKinds = Self.internalRootKinds
        guard roots.count == expectedKinds.count,
              Set(roots.map(\.kind)) == Set(expectedKinds),
              Set(roots.map(\.rootID)).count == expectedKinds.count
        else {
            throw StorageInstallationReceiptError.invalidRootIdentitySet
        }
    }
}

public protocol StorageInstallationReceiptStoring: Sendable {
    func create(
        _ receipt: StorageInstallationReceipt,
        in applicationSupportRoot: OwnedRootDescriptor
    ) throws

    func read(from applicationSupportRoot: OwnedRootDescriptor) throws -> StorageInstallationReceipt
}

public enum StorageInstallationReceiptPOSIXOperation: String, Equatable, Sendable {
    case openRoot
    case inspectRoot
    case openRootMarker
    case inspectRootMarker
    case readRootMarker
    case openReceipt
    case inspectReceipt
    case readReceipt
    case createStaging
    case protectStaging
    case writeStaging
    case syncStaging
    case publishReceipt
    case syncDirectory
}

public enum StorageInstallationReceiptError: Error, Equatable, Sendable {
    case invalidApplicationSupportDescriptor
    case unsupportedFormatVersion
    case bundleIdentifierMismatch
    case invalidRootIdentitySet
    case invalidProtectionDecision
    case rootVerificationFailed(OwnedRootError)
    case receiptMissing
    case receiptAlreadyExists
    case receiptIsNotRegularFile
    case receiptOwnerMismatch
    case receiptPermissionsUnsafe(actual: UInt16)
    case receiptTooLarge(maximumBytes: Int)
    case receiptChangedDuringRead
    case receiptEncodingFailed
    case receiptDecodingFailed
    case stagingAlreadyExists
    case incompleteWrite
    case posixFailure(operation: StorageInstallationReceiptPOSIXOperation, code: Int32)
}

/// Descriptor-relative POSIX storage for the one installation receipt. Merely
/// constructing this value performs no filesystem, credential, or runtime work.
public struct POSIXStorageInstallationReceiptStore: StorageInstallationReceiptStoring {
    public static let maximumReceiptBytes = 64 * 1024

    private static let markerFileName = ".openbots-root.json"
    private static let stagingPrefix = ".openbots-installation.staging-"

    public init() {}

    public func create(
        _ receipt: StorageInstallationReceipt,
        in applicationSupportRoot: OwnedRootDescriptor
    ) throws {
        try receipt.validate()
        guard applicationSupportRoot.kind == .applicationSupport,
              let applicationSupportRootID = receipt.rootID(for: .applicationSupport)
        else {
            throw StorageInstallationReceiptError.invalidApplicationSupportDescriptor
        }

        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(receipt)
        } catch {
            throw StorageInstallationReceiptError.receiptEncodingFailed
        }
        guard encoded.count <= Self.maximumReceiptBytes else {
            throw StorageInstallationReceiptError.receiptTooLarge(
                maximumBytes: Self.maximumReceiptBytes
            )
        }

        let rootFD = try openDirectoryWithoutFollowingSymlinks(applicationSupportRoot.url)
        defer { close(rootFD) }
        try validateRootDirectory(rootFD)
        try verifyRootMarker(
            beneath: rootFD,
            installationID: receipt.installationID,
            rootID: applicationSupportRootID
        )

        let stagingName = Self.stagingPrefix + UUID().uuidString.lowercased()
        let stagingFD = stagingName.withCString {
            openat(
                rootFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard stagingFD >= 0 else {
            if errno == EEXIST {
                throw StorageInstallationReceiptError.stagingAlreadyExists
            }
            throw StorageInstallationReceiptError.posixFailure(
                operation: .createStaging,
                code: errno
            )
        }

        var stagingPublished = false
        defer {
            close(stagingFD)
            if !stagingPublished {
                _ = stagingName.withCString { unlinkat(rootFD, $0, 0) }
            }
        }

        guard fchmod(stagingFD, S_IRUSR | S_IWUSR) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .protectStaging,
                code: errno
            )
        }
        try writeAll(encoded, to: stagingFD)
        guard fsync(stagingFD) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .syncStaging,
                code: errno
            )
        }

        let publishResult = stagingName.withCString { staging in
            StorageInstallationReceipt.fileName.withCString { final in
                renameatx_np(rootFD, staging, rootFD, final, UInt32(RENAME_EXCL))
            }
        }
        guard publishResult == 0 else {
            if errno == EEXIST {
                throw StorageInstallationReceiptError.receiptAlreadyExists
            }
            throw StorageInstallationReceiptError.posixFailure(
                operation: .publishReceipt,
                code: errno
            )
        }
        stagingPublished = true

        guard fsync(rootFD) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .syncDirectory,
                code: errno
            )
        }
    }

    public func read(
        from applicationSupportRoot: OwnedRootDescriptor
    ) throws -> StorageInstallationReceipt {
        guard applicationSupportRoot.kind == .applicationSupport else {
            throw StorageInstallationReceiptError.invalidApplicationSupportDescriptor
        }

        let rootFD = try openDirectoryWithoutFollowingSymlinks(applicationSupportRoot.url)
        defer { close(rootFD) }
        try validateRootDirectory(rootFD)

        let receiptFD = StorageInstallationReceipt.fileName.withCString {
            openat(rootFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard receiptFD >= 0 else {
            if errno == ENOENT {
                throw StorageInstallationReceiptError.receiptMissing
            }
            if errno == ELOOP {
                throw StorageInstallationReceiptError.receiptIsNotRegularFile
            }
            throw StorageInstallationReceiptError.posixFailure(
                operation: .openReceipt,
                code: errno
            )
        }
        defer { close(receiptFD) }

        let initialStat = try inspectReceiptFile(receiptFD)
        let data = try readBounded(
            from: receiptFD,
            maximumBytes: Self.maximumReceiptBytes,
            operation: .readReceipt
        )
        let finalStat = try inspectReceiptFile(receiptFD)
        guard FileSnapshot(initialStat) == FileSnapshot(finalStat),
              data.count == Int(finalStat.st_size)
        else {
            throw StorageInstallationReceiptError.receiptChangedDuringRead
        }

        let receipt: StorageInstallationReceipt
        do {
            receipt = try JSONDecoder().decode(StorageInstallationReceipt.self, from: data)
        } catch {
            throw StorageInstallationReceiptError.receiptDecodingFailed
        }
        try receipt.validate()
        guard let applicationSupportRootID = receipt.rootID(for: .applicationSupport) else {
            throw StorageInstallationReceiptError.invalidRootIdentitySet
        }

        // The receipt supplies the installation/root IDs, so the marker check is
        // intentionally repeated only after the receipt has decoded and validated.
        try verifyRootMarker(
            beneath: rootFD,
            installationID: receipt.installationID,
            rootID: applicationSupportRootID
        )
        return receipt
    }

    private func validateRootDirectory(_ rootFD: Int32) throws {
        var value = stat()
        guard fstat(rootFD, &value) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .inspectRoot,
                code: errno
            )
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw StorageInstallationReceiptError.rootVerificationFailed(.rootTypeMismatch)
        }
        guard value.st_uid == geteuid() else {
            throw StorageInstallationReceiptError.rootVerificationFailed(.rootOwnerMismatch)
        }
        let mode = UInt16(value.st_mode & 0o777)
        guard mode == 0o700 else {
            throw StorageInstallationReceiptError.rootVerificationFailed(
                .rootPermissionsUnsafe(actual: mode)
            )
        }
    }

    private func verifyRootMarker(
        beneath rootFD: Int32,
        installationID: UUID,
        rootID: UUID
    ) throws {
        let markerFD = Self.markerFileName.withCString {
            openat(rootFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard markerFD >= 0 else {
            if errno == ENOENT {
                throw StorageInstallationReceiptError.rootVerificationFailed(.markerMissing)
            }
            if errno == ELOOP {
                throw StorageInstallationReceiptError.rootVerificationFailed(
                    .markerIsNotRegularFile
                )
            }
            throw StorageInstallationReceiptError.posixFailure(
                operation: .openRootMarker,
                code: errno
            )
        }
        defer { close(markerFD) }

        var markerStat = stat()
        guard fstat(markerFD, &markerStat) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .inspectRootMarker,
                code: errno
            )
        }
        guard markerStat.st_mode & S_IFMT == S_IFREG else {
            throw StorageInstallationReceiptError.rootVerificationFailed(.markerIsNotRegularFile)
        }
        guard markerStat.st_uid == geteuid() else {
            throw StorageInstallationReceiptError.rootVerificationFailed(.markerOwnerMismatch)
        }
        let markerMode = UInt16(markerStat.st_mode & 0o777)
        guard markerMode == 0o600 else {
            throw StorageInstallationReceiptError.rootVerificationFailed(
                .markerPermissionsUnsafe(actual: markerMode)
            )
        }

        let markerData: Data
        do {
            markerData = try readBounded(
                from: markerFD,
                maximumBytes: Self.maximumReceiptBytes,
                operation: .readRootMarker
            )
        } catch let error as StorageInstallationReceiptError {
            switch error {
            case .receiptTooLarge, .receiptChangedDuringRead:
                throw StorageInstallationReceiptError.rootVerificationFailed(.markerUnreadable)
            default:
                throw error
            }
        }

        let marker: OwnedRootMarker
        do {
            marker = try JSONDecoder().decode(OwnedRootMarker.self, from: markerData)
        } catch {
            throw StorageInstallationReceiptError.rootVerificationFailed(.markerUnreadable)
        }
        guard marker.formatVersion == OwnedRootMarker.currentFormatVersion,
              marker.bundleIdentifier == OpenBotsPreviewIdentity.bundleIdentifier,
              marker.installationID == installationID,
              marker.rootID == rootID,
              marker.kind == .applicationSupport
        else {
            throw StorageInstallationReceiptError.rootVerificationFailed(.markerMismatch)
        }
    }

    private func inspectReceiptFile(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .inspectReceipt,
                code: errno
            )
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw StorageInstallationReceiptError.receiptIsNotRegularFile
        }
        guard value.st_uid == geteuid() else {
            throw StorageInstallationReceiptError.receiptOwnerMismatch
        }
        let mode = UInt16(value.st_mode & 0o777)
        guard mode == 0o600 else {
            throw StorageInstallationReceiptError.receiptPermissionsUnsafe(actual: mode)
        }
        guard value.st_size >= 0,
              value.st_size <= off_t(Self.maximumReceiptBytes)
        else {
            throw StorageInstallationReceiptError.receiptTooLarge(
                maximumBytes: Self.maximumReceiptBytes
            )
        }
        return value
    }

    private func openDirectoryWithoutFollowingSymlinks(_ url: URL) throws -> Int32 {
        guard url.isFileURL else {
            throw StorageInstallationReceiptError.invalidApplicationSupportDescriptor
        }
        // Preserve the descriptor's already-lexical physical spelling. On macOS,
        // `standardizedFileURL` can rewrite `/private/tmp` to the `/tmp` symlink;
        // descriptor traversal must not then reject its own trusted root alias.
        let components = url.pathComponents
        guard components.first == "/" else {
            throw StorageInstallationReceiptError.invalidApplicationSupportDescriptor
        }

        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard currentFD >= 0 else {
            throw StorageInstallationReceiptError.posixFailure(
                operation: .openRoot,
                code: errno
            )
        }
        do {
            for component in components.dropFirst() {
                guard Self.isSafePathComponent(component) else {
                    throw StorageInstallationReceiptError.invalidApplicationSupportDescriptor
                }
                let nextFD = component.withCString {
                    openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard nextFD >= 0 else {
                    throw StorageInstallationReceiptError.posixFailure(
                        operation: .openRoot,
                        code: errno
                    )
                }
                close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            close(currentFD)
            throw error
        }
    }

    private func readBounded(
        from descriptor: Int32,
        maximumBytes: Int,
        operation: StorageInstallationReceiptPOSIXOperation
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw StorageInstallationReceiptError.posixFailure(
                    operation: operation,
                    code: errno
                )
            }
            guard result.count <= maximumBytes - count else {
                throw StorageInstallationReceiptError.receiptTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StorageInstallationReceiptError.posixFailure(
                        operation: .writeStaging,
                        code: errno
                    )
                }
                guard written > 0 else {
                    throw StorageInstallationReceiptError.incompleteWrite
                }
                offset += written
            }
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
}
