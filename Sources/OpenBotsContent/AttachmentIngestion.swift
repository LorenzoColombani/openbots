import CryptoKit
import Darwin
import Foundation

/// The preview limit is deliberately provisional. Product policy can replace it
/// without changing the descriptor-safe ingestion boundary.
public struct AttachmentIngestionPolicy: Hashable, Sendable {
    public static let provisionalMaximumBytes: UInt64 = 100 * 1_024 * 1_024

    public let maximumBytes: UInt64

    public init(maximumBytes: UInt64 = Self.provisionalMaximumBytes) {
        self.maximumBytes = maximumBytes
    }
}

public enum AttachmentIngestionError: Error, Equatable, Sendable {
    case wrongOwnedRoot
    case ingestRootMismatch
    case ingestRootUnavailable
    case ingestRootIdentityChanged
    case ingestRootPermissionsUnsafe
    case ingestRootOwnerMismatch
    case sourceURLInvalid
    case sourceUnavailable
    case sourceIsSymbolicLink
    case sourceIsNotRegularFile
    case sourceIsFinderAlias
    case sourceIsNotOnLocalVolume
    case sourceHasUnexpectedHardLinks
    case sourceMetadataUnavailable
    case quarantineUnavailable
    case sourceTooLarge(maximumBytes: UInt64)
    case sourceChangedDuringIngestion
    case scratchCollision
    case scratchCreationFailed
    case stagedFileCollision
    case stagedFileCreationFailed
    case copyFailed
    case failureCleanupFailed
    case discardReceiptMismatch
    case discardRefused
}

public struct AttachmentFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }
}

/// Read-only evidence that the exact app-owned ingestion directory existed with
/// the expected identity, owner, and permissions at verification time. Execution
/// reopens and revalidates this identity before creating anything.
public struct VerifiedAttachmentIngestRoot: Hashable, Sendable {
    public let url: URL
    public let cacheRootID: UUID
    public let identity: AttachmentFileIdentity
    let cacheRootURL: URL
    let cacheRootIdentity: AttachmentFileIdentity

    fileprivate init(url: URL, cacheRootID: UUID, identity: AttachmentFileIdentity,
                     cacheRootURL: URL, cacheRootIdentity: AttachmentFileIdentity) {
        self.url = url
        self.cacheRootID = cacheRootID
        self.identity = identity
        self.cacheRootURL = cacheRootURL
        self.cacheRootIdentity = cacheRootIdentity
    }
}

public struct AttachmentIngestRootVerifier: Sendable {
    public init() {}

    public func verify(
        _ ingestRootURL: URL,
        inside cacheRoot: VerifiedOwnedRoot
    ) throws -> VerifiedAttachmentIngestRoot {
        guard cacheRoot.kind == .caches else {
            throw AttachmentIngestionError.wrongOwnedRoot
        }
        let expected = FileURLNormalization.lexical(
            cacheRoot.url.appending(path: "AttachmentIngest", directoryHint: .isDirectory)
        )
        guard FileURLNormalization.lexical(ingestRootURL) == expected else {
            throw AttachmentIngestionError.ingestRootMismatch
        }

        let canonical: CanonicalPath
        do {
            canonical = try PathSafety().canonicalExistingDirectory(expected)
        } catch {
            throw AttachmentIngestionError.ingestRootUnavailable
        }
        guard canonical.url == expected else {
            throw AttachmentIngestionError.ingestRootMismatch
        }

        var value = stat()
        guard lstat(expected.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw AttachmentIngestionError.ingestRootUnavailable
        }
        guard value.st_mode & 0o7777 == 0o700 else {
            throw AttachmentIngestionError.ingestRootPermissionsUnsafe
        }
        guard value.st_uid == geteuid() else {
            throw AttachmentIngestionError.ingestRootOwnerMismatch
        }
        var cacheValue = stat()
        guard lstat(cacheRoot.url.path, &cacheValue) == 0,
              cacheValue.st_mode & S_IFMT == S_IFDIR,
              cacheValue.st_mode & 0o7777 == 0o700,
              cacheValue.st_uid == geteuid() else {
            throw AttachmentIngestionError.ingestRootUnavailable
        }
        return VerifiedAttachmentIngestRoot(
            url: expected,
            cacheRootID: cacheRoot.rootID,
            identity: AttachmentFileIdentity(value), cacheRootURL: cacheRoot.url,
            cacheRootIdentity: AttachmentFileIdentity(cacheValue)
        )
    }
}

/// A pure request value. Creating it never opens the source or creates scratch.
public struct AttachmentIngestionRequest: Hashable, Sendable {
    public let sourceFileURL: URL
    public let ingestRoot: VerifiedAttachmentIngestRoot
    public let operationID: UUID

    public init(
        sourceFileURL: URL,
        ingestRoot: VerifiedAttachmentIngestRoot,
        operationID: UUID = UUID()
    ) {
        self.sourceFileURL = sourceFileURL
        self.ingestRoot = ingestRoot
        self.operationID = operationID
    }
}

/// An intentionally non-durable receipt for the preview copy. It does not create
/// attachment metadata and it does not publish into stable content.
public struct PreviewAttachmentIngestionReceipt: Hashable, Sendable {
    public let operationID: UUID
    public let sourceFileName: String
    public let sourceIdentity: AttachmentFileIdentity
    public let stagedFileURL: URL
    public let byteCount: UInt64
    public let sha256: String

    public let isDurable = false
    public let isPublished = false

    let cacheRootID: UUID
    let scratchIdentity: AttachmentFileIdentity
    let stagedIdentity: AttachmentFileIdentity
    let quarantineData: Data?

    fileprivate init(
        operationID: UUID,
        sourceFileName: String,
        sourceIdentity: AttachmentFileIdentity,
        stagedFileURL: URL,
        byteCount: UInt64,
        sha256: String,
        cacheRootID: UUID,
        scratchIdentity: AttachmentFileIdentity,
        stagedIdentity: AttachmentFileIdentity,
        quarantineData: Data?
    ) {
        self.operationID = operationID
        self.sourceFileName = sourceFileName
        self.sourceIdentity = sourceIdentity
        self.stagedFileURL = stagedFileURL
        self.byteCount = byteCount
        self.sha256 = sha256
        self.cacheRootID = cacheRootID
        self.scratchIdentity = scratchIdentity
        self.stagedIdentity = stagedIdentity
        self.quarantineData = quarantineData
    }
}

struct AttachmentIngestionTestHooks: Sendable {
    var startSourceAccess: (@Sendable (URL) -> Bool)?
    var stopSourceAccess: (@Sendable (URL) -> Void)?
    var afterScratchDirectoryCreated: (@Sendable (URL) throws -> Void)?
    var failAfterCopiedBytes: UInt64?
    var beforeFinalSourceRevalidation: (@Sendable () throws -> Void)?

    init(
        startSourceAccess: (@Sendable (URL) -> Bool)? = nil,
        stopSourceAccess: (@Sendable (URL) -> Void)? = nil,
        afterScratchDirectoryCreated: (@Sendable (URL) throws -> Void)? = nil,
        failAfterCopiedBytes: UInt64? = nil,
        beforeFinalSourceRevalidation: (@Sendable () throws -> Void)? = nil
    ) {
        self.startSourceAccess = startSourceAccess
        self.stopSourceAccess = stopSourceAccess
        self.afterScratchDirectoryCreated = afterScratchDirectoryCreated
        self.failAfterCopiedBytes = failAfterCopiedBytes
        self.beforeFinalSourceRevalidation = beforeFinalSourceRevalidation
    }
}

public struct AttachmentIngestor: Sendable {
    private let policy: AttachmentIngestionPolicy
    private let testHooks: AttachmentIngestionTestHooks

    public init(policy: AttachmentIngestionPolicy = AttachmentIngestionPolicy()) {
        self.policy = policy
        testHooks = AttachmentIngestionTestHooks()
    }

    init(policy: AttachmentIngestionPolicy, testHooks: AttachmentIngestionTestHooks) {
        self.policy = policy
        self.testHooks = testHooks
    }

    /// All descriptor validation, copying, hashing, syncing, and cleanup run on a
    /// detached task even when a presentation model calls this from MainActor.
    public func ingest(
        _ request: AttachmentIngestionRequest
    ) async throws -> PreviewAttachmentIngestionReceipt {
        let policy = policy
        let hooks = testHooks
        let task = Task.detached(priority: .userInitiated) {
            try AttachmentIngestionExecutor(policy: policy, hooks: hooks).execute(request)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Removes only the exact successful preview scratch objects named by the
    /// receipt. A replaced file/directory or mismatched root is preserved and
    /// fails closed for explicit recovery.
    public func discard(
        _ receipt: PreviewAttachmentIngestionReceipt,
        inside ingestRoot: VerifiedAttachmentIngestRoot
    ) async throws {
        let policy = policy
        try await Task.detached(priority: .utility) {
            try AttachmentIngestionExecutor(
                policy: policy,
                hooks: AttachmentIngestionTestHooks()
            ).discard(receipt, inside: ingestRoot)
        }.value
    }
}

private struct AttachmentIngestionExecutor {
    private static let stagedFileName = "payload"
    private static let copyBufferSize = 64 * 1_024

    let policy: AttachmentIngestionPolicy
    let hooks: AttachmentIngestionTestHooks

    func execute(_ request: AttachmentIngestionRequest) throws -> PreviewAttachmentIngestionReceipt {
        try Task.checkCancellation()
        let rootFD = try openAndRevalidateRoot(request.ingestRoot)
        defer { close(rootFD) }

        try validateSourceURL(request.sourceFileURL)
        let scopedAccess = hooks.startSourceAccess?(request.sourceFileURL)
            ?? request.sourceFileURL.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess {
                if let stop = hooks.stopSourceAccess { stop(request.sourceFileURL) }
                else { request.sourceFileURL.stopAccessingSecurityScopedResource() }
            }
        }
        let source = try openSource(request.sourceFileURL)
        defer { close(source.fileDescriptor) }

        guard source.snapshot.size <= policy.maximumBytes else {
            throw AttachmentIngestionError.sourceTooLarge(maximumBytes: policy.maximumBytes)
        }

        let scratchName = request.operationID.uuidString.lowercased()
        guard mkdirat(rootFD, scratchName, S_IRWXU) == 0 else {
            if errno == EEXIST {
                throw AttachmentIngestionError.scratchCollision
            }
            throw AttachmentIngestionError.scratchCreationFailed
        }

        let scratchURL = request.ingestRoot.url.appending(path: scratchName, directoryHint: .isDirectory)
        let cleanupState = ScratchCleanupState()
        do {
            cleanupState.scratchIdentity = try captureScratchIdentity(
                rootFD: rootFD,
                scratchName: scratchName
            )
            try hooks.afterScratchDirectoryCreated?(scratchURL)
            let receipt = try stage(
                source: source,
                sourceURL: request.sourceFileURL,
                rootFD: rootFD,
                scratchName: scratchName,
                scratchURL: scratchURL,
                request: request,
                cleanupState: cleanupState
            )
            return receipt
        } catch {
            let cleaned = cleanupOwnedScratch(
                rootFD: rootFD,
                scratchName: scratchName,
                expectedScratchIdentity: cleanupState.scratchIdentity,
                expectedStagedIdentity: cleanupState.stagedIdentity
            )
            guard cleaned || cleanupState.stagedIdentity == nil else {
                throw AttachmentIngestionError.failureCleanupFailed
            }
            if error is CancellationError { throw error }
            throw normalize(error)
        }
    }

    func discard(
        _ receipt: PreviewAttachmentIngestionReceipt,
        inside ingestRoot: VerifiedAttachmentIngestRoot
    ) throws {
        guard receipt.cacheRootID == ingestRoot.cacheRootID else {
            throw AttachmentIngestionError.discardReceiptMismatch
        }
        let scratchName = receipt.operationID.uuidString.lowercased()
        let expectedScratchURL = ingestRoot.url.appending(
            path: scratchName,
            directoryHint: .isDirectory
        )
        let expectedStagedURL = expectedScratchURL.appending(
            path: Self.stagedFileName,
            directoryHint: .notDirectory
        )
        guard FileURLNormalization.lexical(receipt.stagedFileURL) == expectedStagedURL else {
            throw AttachmentIngestionError.discardReceiptMismatch
        }

        let rootFD = try openAndRevalidateRoot(ingestRoot)
        defer { close(rootFD) }
        guard cleanupOwnedScratch(
            rootFD: rootFD,
            scratchName: scratchName,
            expectedScratchIdentity: receipt.scratchIdentity,
            expectedStagedIdentity: receipt.stagedIdentity
        ) else {
            throw AttachmentIngestionError.discardRefused
        }
    }

    private func stage(
        source: OpenSource,
        sourceURL: URL,
        rootFD: Int32,
        scratchName: String,
        scratchURL: URL,
        request: AttachmentIngestionRequest,
        cleanupState: ScratchCleanupState
    ) throws -> PreviewAttachmentIngestionReceipt {
        let scratchFD = scratchName.withCString {
            openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard scratchFD >= 0 else {
            throw AttachmentIngestionError.scratchCreationFailed
        }
        defer { close(scratchFD) }

        var scratchStat = stat()
        guard fstat(scratchFD, &scratchStat) == 0,
              scratchStat.st_mode & S_IFMT == S_IFDIR,
              scratchStat.st_mode & 0o7777 == 0o700,
              scratchStat.st_uid == geteuid(),
              AttachmentFileIdentity(scratchStat) == cleanupState.scratchIdentity
        else {
            throw AttachmentIngestionError.scratchCreationFailed
        }

        let destinationFD = Self.stagedFileName.withCString {
            openat(
                scratchFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard destinationFD >= 0 else {
            if errno == EEXIST {
                throw AttachmentIngestionError.stagedFileCollision
            }
            throw AttachmentIngestionError.stagedFileCreationFailed
        }
        defer { close(destinationFD) }

        guard fchmod(destinationFD, S_IRUSR | S_IWUSR) == 0 else {
            throw AttachmentIngestionError.stagedFileCreationFailed
        }

        var destinationStat = stat()
        guard fstat(destinationFD, &destinationStat) == 0,
              destinationStat.st_mode & S_IFMT == S_IFREG,
              destinationStat.st_mode & 0o7777 == 0o600,
              destinationStat.st_nlink == 1,
              destinationStat.st_uid == geteuid()
        else {
            throw AttachmentIngestionError.stagedFileCreationFailed
        }
        cleanupState.stagedIdentity = AttachmentFileIdentity(destinationStat)

        let copied = try copyAndHash(from: source.fileDescriptor, to: destinationFD)
        guard copied.byteCount == source.snapshot.size else {
            throw AttachmentIngestionError.sourceChangedDuringIngestion
        }
        try AttachmentQuarantine.copy(source.quarantine, to: destinationFD)
        guard fsync(destinationFD) == 0 else {
            throw AttachmentIngestionError.copyFailed
        }

        try hooks.beforeFinalSourceRevalidation?()
        try Task.checkCancellation()
        guard try AttachmentQuarantine.read(destinationFD) == source.quarantine else {
            throw AttachmentIngestionError.quarantineUnavailable
        }
        try revalidateSource(source, at: sourceURL)
        try revalidateStagedFile(
            scratchFD: scratchFD,
            expected: AttachmentFileIdentity(destinationStat)
        )
        try revalidateScratchDirectory(
            rootFD: rootFD,
            scratchName: scratchName,
            expected: cleanupState.scratchIdentity
        )
        guard let scratchIdentity = cleanupState.scratchIdentity else {
            throw AttachmentIngestionError.scratchCreationFailed
        }
        let checkedRootFD = try openAndRevalidateRoot(request.ingestRoot)
        close(checkedRootFD)

        return PreviewAttachmentIngestionReceipt(
            operationID: request.operationID,
            sourceFileName: sourceURL.lastPathComponent,
            sourceIdentity: AttachmentFileIdentity(source.snapshot.value),
            stagedFileURL: scratchURL.appending(path: Self.stagedFileName, directoryHint: .notDirectory),
            byteCount: copied.byteCount,
            sha256: copied.sha256,
            cacheRootID: request.ingestRoot.cacheRootID,
            scratchIdentity: scratchIdentity,
            stagedIdentity: AttachmentFileIdentity(destinationStat),
            quarantineData: source.quarantine
        )
    }

    private func copyAndHash(from sourceFD: Int32, to destinationFD: Int32) throws -> CopyResult {
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.copyBufferSize)

        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw AttachmentIngestionError.copyFailed
            }

            let count = Int(readCount)
            guard total <= policy.maximumBytes,
                  UInt64(count) <= policy.maximumBytes - total
            else {
                throw AttachmentIngestionError.sourceTooLarge(maximumBytes: policy.maximumBytes)
            }

            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            try writeAll(chunk, to: destinationFD)
            total += UInt64(count)

            if let threshold = hooks.failAfterCopiedBytes, total >= threshold {
                throw AttachmentIngestionError.copyFailed
            }
        }

        return CopyResult(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AttachmentIngestionError.copyFailed
                }
                guard count > 0 else { throw AttachmentIngestionError.copyFailed }
                written += count
            }
        }
    }

    private func openAndRevalidateRoot(_ root: VerifiedAttachmentIngestRoot) throws -> Int32 {
        let cacheFD: Int32
        do {
            cacheFD = try openDirectoryChainNoFollow(root.cacheRootURL)
        } catch {
            throw AttachmentIngestionError.ingestRootUnavailable
        }
        defer { close(cacheFD) }
        var cacheValue = stat()
        guard fstat(cacheFD, &cacheValue) == 0,
              AttachmentFileIdentity(cacheValue) == root.cacheRootIdentity,
              cacheValue.st_mode & S_IFMT == S_IFDIR,
              cacheValue.st_mode & 0o7777 == 0o700,
              cacheValue.st_uid == geteuid() else {
            throw AttachmentIngestionError.ingestRootIdentityChanged
        }
        let fileDescriptor = openat(cacheFD, "AttachmentIngest", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { throw AttachmentIngestionError.ingestRootUnavailable }

        var value = stat()
        guard fstat(fileDescriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR
        else {
            close(fileDescriptor)
            throw AttachmentIngestionError.ingestRootUnavailable
        }
        guard AttachmentFileIdentity(value) == root.identity else {
            close(fileDescriptor)
            throw AttachmentIngestionError.ingestRootIdentityChanged
        }
        guard value.st_mode & 0o7777 == 0o700 else {
            close(fileDescriptor)
            throw AttachmentIngestionError.ingestRootPermissionsUnsafe
        }
        guard value.st_uid == geteuid() else {
            close(fileDescriptor)
            throw AttachmentIngestionError.ingestRootOwnerMismatch
        }
        return fileDescriptor
    }

    private func openSource(_ url: URL) throws -> OpenSource {
        try validateSourceURL(url)
        let normalized = FileURLNormalization.lexical(url)
        let name = normalized.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw AttachmentIngestionError.sourceURLInvalid
        }

        let parentFD: Int32
        do {
            parentFD = try openDirectoryChainNoFollow(normalized.deletingLastPathComponent())
        } catch SecureOpenError.symbolicLink {
            throw AttachmentIngestionError.sourceIsSymbolicLink
        } catch {
            throw AttachmentIngestionError.sourceUnavailable
        }
        defer { close(parentFD) }

        let fileDescriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            if errno == ELOOP {
                throw AttachmentIngestionError.sourceIsSymbolicLink
            }
            throw AttachmentIngestionError.sourceUnavailable
        }

        do {
            var value = stat()
            guard fstat(fileDescriptor, &value) == 0 else {
                throw AttachmentIngestionError.sourceMetadataUnavailable
            }
            guard value.st_mode & S_IFMT == S_IFREG else {
                throw AttachmentIngestionError.sourceIsNotRegularFile
            }
            guard value.st_nlink == 1 else { throw AttachmentIngestionError.sourceHasUnexpectedHardLinks }
            guard try !isFinderAlias(fileDescriptor) else {
                throw AttachmentIngestionError.sourceIsFinderAlias
            }
            var filesystem = statfs()
            guard fstatfs(fileDescriptor, &filesystem) == 0 else {
                throw AttachmentIngestionError.sourceMetadataUnavailable
            }
            guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw AttachmentIngestionError.sourceIsNotOnLocalVolume
            }
            guard value.st_size >= 0 else {
                throw AttachmentIngestionError.sourceMetadataUnavailable
            }
            return OpenSource(fileDescriptor: fileDescriptor, snapshot: SourceSnapshot(value),
                              quarantine: try AttachmentQuarantine.read(fileDescriptor))
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private func revalidateSource(_ source: OpenSource, at sourceURL: URL) throws {
        var descriptorValue = stat()
        guard fstat(source.fileDescriptor, &descriptorValue) == 0,
              SourceSnapshot(descriptorValue) == source.snapshot,
              try AttachmentQuarantine.read(source.fileDescriptor) == source.quarantine
        else {
            throw AttachmentIngestionError.sourceChangedDuringIngestion
        }

        let reopened: OpenSource
        do {
            reopened = try openSource(sourceURL)
        } catch {
            throw AttachmentIngestionError.sourceChangedDuringIngestion
        }
        defer { close(reopened.fileDescriptor) }
        guard reopened.snapshot == source.snapshot, reopened.quarantine == source.quarantine else {
            throw AttachmentIngestionError.sourceChangedDuringIngestion
        }
    }

    private func revalidateStagedFile(
        scratchFD: Int32,
        expected: AttachmentFileIdentity
    ) throws {
        var value = stat()
        let status = Self.stagedFileName.withCString {
            fstatat(scratchFD, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o7777 == 0o600,
              value.st_nlink == 1,
              value.st_uid == geteuid(),
              AttachmentFileIdentity(value) == expected
        else {
            throw AttachmentIngestionError.copyFailed
        }
    }

    private func revalidateScratchDirectory(
        rootFD: Int32,
        scratchName: String,
        expected: AttachmentFileIdentity?
    ) throws {
        guard let expected else {
            throw AttachmentIngestionError.scratchCreationFailed
        }
        var value = stat()
        let status = scratchName.withCString {
            fstatat(rootFD, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o7777 == 0o700,
              value.st_uid == geteuid(),
              AttachmentFileIdentity(value) == expected
        else {
            throw AttachmentIngestionError.copyFailed
        }
    }

    private func isFinderAlias(_ fileDescriptor: Int32) throws -> Bool {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let result = finderInfo.withUnsafeMutableBytes { rawBuffer in
            fgetxattr(
                fileDescriptor,
                "com.apple.FinderInfo",
                rawBuffer.baseAddress,
                rawBuffer.count,
                0,
                0
            )
        }
        if result < 0 {
            if errno == ENOATTR { return false }
            throw AttachmentIngestionError.sourceMetadataUnavailable
        }
        guard result >= 10 else { return false }
        let flags = UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9])
        return flags & 0x8000 != 0
    }

    private func openDirectoryChainNoFollow(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw SecureOpenError.unavailable }
        let normalized = FileURLNormalization.lexical(url)
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard currentFD >= 0 else { throw SecureOpenError.unavailable }

        for component in normalized.pathComponents.dropFirst() {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            let code = errno
            guard nextFD >= 0 else {
                var value = stat()
                let isSymbolicLink = component.withCString {
                    fstatat(currentFD, $0, &value, AT_SYMLINK_NOFOLLOW) == 0 &&
                        value.st_mode & S_IFMT == S_IFLNK
                }
                close(currentFD)
                if code == ELOOP || isSymbolicLink { throw SecureOpenError.symbolicLink }
                throw SecureOpenError.unavailable
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private func cleanupOwnedScratch(
        rootFD: Int32,
        scratchName: String,
        expectedScratchIdentity: AttachmentFileIdentity?,
        expectedStagedIdentity: AttachmentFileIdentity?
    ) -> Bool {
        guard let expectedScratchIdentity else { return false }
        let scratchFD = scratchName.withCString {
            openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard scratchFD >= 0 else { return false }
        defer { close(scratchFD) }

        var current = stat()
        guard fstat(scratchFD, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              AttachmentFileIdentity(current) == expectedScratchIdentity
        else {
            return false
        }
        if let expectedStagedIdentity {
            var stagedValue = stat()
            let inspected = Self.stagedFileName.withCString {
                fstatat(scratchFD, $0, &stagedValue, AT_SYMLINK_NOFOLLOW)
            }
            guard inspected == 0,
                  stagedValue.st_mode & S_IFMT == S_IFREG,
                  AttachmentFileIdentity(stagedValue) == expectedStagedIdentity
            else {
                return false
            }
            let removed = Self.stagedFileName.withCString { unlinkat(scratchFD, $0, 0) }
            guard removed == 0 else { return false }
        }
        return scratchName.withCString { unlinkat(rootFD, $0, AT_REMOVEDIR) } == 0
    }

    private func captureScratchIdentity(rootFD: Int32, scratchName: String) throws -> AttachmentFileIdentity {
        let scratchFD = scratchName.withCString {
            openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard scratchFD >= 0 else {
            throw AttachmentIngestionError.scratchCreationFailed
        }
        defer { close(scratchFD) }

        var value = stat()
        guard fstat(scratchFD, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o7777 == 0o700,
              value.st_uid == geteuid()
        else {
            throw AttachmentIngestionError.scratchCreationFailed
        }
        return AttachmentFileIdentity(value)
    }

    private func normalize(_ error: Error) -> AttachmentIngestionError {
        error as? AttachmentIngestionError ?? .copyFailed
    }

    private enum SecureOpenError: Error {
        case symbolicLink
        case unavailable
    }

    private struct OpenSource {
        let fileDescriptor: Int32
        let snapshot: SourceSnapshot
        let quarantine: Data?
    }

    private final class ScratchCleanupState {
        var scratchIdentity: AttachmentFileIdentity?
        var stagedIdentity: AttachmentFileIdentity?
    }

    private struct SourceSnapshot: Equatable {
        let value: stat
        let size: UInt64
        private let device: UInt64
        private let inode: UInt64
        private let modificationSeconds: Int64
        private let modificationNanoseconds: Int64
        private let changeSeconds: Int64
        private let changeNanoseconds: Int64

        init(_ value: stat) {
            self.value = value
            size = UInt64(value.st_size)
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = Int64(value.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        static func == (lhs: SourceSnapshot, rhs: SourceSnapshot) -> Bool {
            lhs.size == rhs.size &&
                lhs.device == rhs.device &&
                lhs.inode == rhs.inode &&
                lhs.modificationSeconds == rhs.modificationSeconds &&
                lhs.modificationNanoseconds == rhs.modificationNanoseconds &&
                lhs.changeSeconds == rhs.changeSeconds &&
                lhs.changeNanoseconds == rhs.changeNanoseconds &&
                lhs.value.st_mode == rhs.value.st_mode && lhs.value.st_nlink == rhs.value.st_nlink &&
                lhs.value.st_uid == rhs.value.st_uid && lhs.value.st_flags == rhs.value.st_flags
        }
    }

    private func validateSourceURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.contains("\0"),
              !url.pathComponents.contains(".."), url.lastPathComponent != "/" else {
            throw AttachmentIngestionError.sourceURLInvalid
        }
    }

    private struct CopyResult {
        let byteCount: UInt64
        let sha256: String
    }
}
