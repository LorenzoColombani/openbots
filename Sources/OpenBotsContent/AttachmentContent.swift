import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain
import UniformTypeIdentifiers

public enum AttachmentContentError: Error, Equatable, Sendable {
    case wrongOwnedRoot, rootMismatch, rootUnavailable, rootIdentityChanged, rootProtectionInvalid
    case invalidMetadata, receiptMismatch, stagedContentChanged, quarantineMismatch
    case missing, unsafeFile, contentMismatch, collision, publicationFailed, cleanupRefused
}

/// Content evidence, not a conversation/database commit or an executable path.
public struct StoredAttachmentContent: Equatable, Sendable {
    public let id: AttachmentID
    public let byteCount: Int64
    public let sha256: String
    public let typeIdentifier: String
    public let displayName: String

    public init(id: AttachmentID, byteCount: Int64, sha256: String, typeIdentifier: String, displayName: String) throws {
        try AttachmentContentDescriptors.validateMetadata(byteCount: byteCount, sha256: sha256)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 255, displayName != ".", displayName != "..",
              !displayName.contains("/"),
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !typeIdentifier.isEmpty, typeIdentifier.utf8.count <= 255,
              typeIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 46 || $0 == 45 }) else {
            throw AttachmentContentError.invalidMetadata
        }
        self.id = id
        self.byteCount = byteCount
        self.sha256 = sha256
        self.typeIdentifier = typeIdentifier
        self.displayName = displayName
    }
}

public struct VerifiedAttachmentContentRoot: Hashable, Sendable {
    public let url: URL
    public let applicationSupportRootID: UUID
    fileprivate let applicationSupportURL: URL
    fileprivate let identities: [AttachmentFileIdentity]

    fileprivate init(inside root: VerifiedOwnedRoot, identities: [AttachmentFileIdentity]) {
        url = root.url.appending(path: "HighChurn.noindex/Attachments", directoryHint: .isDirectory)
        applicationSupportRootID = root.rootID
        applicationSupportURL = root.url
        self.identities = identities
    }
}

/// Read-only: an absent child is not created or repaired by verification.
public struct AttachmentContentRootVerifier: Sendable {
    public init() {}

    public func verify(_ url: URL, inside root: VerifiedOwnedRoot) throws -> VerifiedAttachmentContentRoot {
        try AttachmentContentDescriptors.verifyOwnedSupport(root)
        let expected = root.url.appending(path: "HighChurn.noindex/Attachments", directoryHint: .isDirectory)
        guard url.isFileURL, FileURLNormalization.lexical(url) == FileURLNormalization.lexical(expected) else {
            throw AttachmentContentError.rootMismatch
        }
        let opened = try AttachmentContentDescriptors.openHierarchy(root.url, includingAttachments: true)
        defer { close(opened.fd) }
        return VerifiedAttachmentContentRoot(inside: root, identities: opened.identities)
    }
}

/// Explicit upgrade for already-bootstrapped installations. It creates only the
/// exact missing Attachments child, never intermediate roots or visible content.
public struct AttachmentContentRootProvisioner: Sendable {
    public init() {}

    public func prepare(inside root: VerifiedOwnedRoot) throws -> VerifiedAttachmentContentRoot {
        try AttachmentContentDescriptors.verifyOwnedSupport(root)
        let parent = try AttachmentContentDescriptors.openHierarchy(root.url, includingAttachments: false)
        defer { close(parent.fd) }
        let created = mkdirat(parent.fd, "Attachments", S_IRWXU) == 0
        guard created || errno == EEXIST else { throw AttachmentContentError.rootUnavailable }
        if created, fsync(parent.fd) != 0 { throw AttachmentContentError.publicationFailed }
        let verified = try AttachmentContentRootVerifier().verify(
            root.url.appending(path: "HighChurn.noindex/Attachments", directoryHint: .isDirectory), inside: root
        )
        guard Array(verified.identities.prefix(2)) == parent.identities else {
            throw AttachmentContentError.rootIdentityChanged
        }
        return verified
    }
}

struct AttachmentContentTestHooks: Sendable {
    var beforePublication: (@Sendable (URL) throws -> Void)?
    var beforeVerificationCompletes: (@Sendable () throws -> Void)?
    var beforePreviewRendering: (@Sendable () throws -> Void)?
    var afterPreviewRendering: (@Sendable () throws -> Void)?
}

/// Inert until an explicit call. This store never opens user documents, executes
/// an attachment, creates a root, or removes an already-published blob.
public struct AttachmentContentStore: Sendable {
    private let root: VerifiedAttachmentContentRoot
    private let hooks: AttachmentContentTestHooks

    public init(root: VerifiedAttachmentContentRoot) {
        self.root = root
        hooks = AttachmentContentTestHooks()
    }

    init(root: VerifiedAttachmentContentRoot, hooks: AttachmentContentTestHooks) {
        self.root = root
        self.hooks = hooks
    }

    public func publish(
        receipt: PreviewAttachmentIngestionReceipt, from ingestRoot: VerifiedAttachmentIngestRoot, id: AttachmentID
    ) async throws -> StoredAttachmentContent {
        let root = root
        let hooks = hooks
        let task = Task.detached(priority: .userInitiated) {
            try AttachmentContentExecutor(root: root, hooks: hooks).publish(receipt, from: ingestRoot, id: id)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func verify(id: AttachmentID, byteCount: Int64, sha256: String) async throws {
        _ = try await verifiedURL(id: id, byteCount: byteCount, sha256: sha256)
    }

    /// Intended only for an explicit Finder Reveal. A verified URL is a point-
    /// in-time receipt, not authority to execute/open bytes or mutate this path.
    public func verifiedURL(id: AttachmentID, byteCount: Int64, sha256: String) async throws -> URL {
        let root = root
        let hooks = hooks
        let task = Task.detached(priority: .userInitiated) {
            try AttachmentContentExecutor(root: root, hooks: hooks).verify(id: id, byteCount: byteCount, sha256: sha256)
            return root.url.appending(path: AttachmentContentDescriptors.fileName(id))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Read-only presentation of verified owned bytes. The decoder receives no
    /// URL or descriptor, and no original document is opened or executed.
    public func preview(
        id: AttachmentID, byteCount: Int64, sha256: String,
        displayName: String, typeIdentifier: String, pageNumber: Int = 1
    ) async throws -> AttachmentPreview {
        let root = root
        let hooks = hooks
        let task = Task.detached(priority: .userInitiated) {
            try AttachmentContentExecutor(root: root, hooks: hooks).preview(
                id: id, byteCount: byteCount, sha256: sha256,
                displayName: displayName, typeIdentifier: typeIdentifier, pageNumber: pageNumber
            )
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private struct AttachmentContentExecutor {
    let root: VerifiedAttachmentContentRoot
    let hooks: AttachmentContentTestHooks

    func publish(
        _ receipt: PreviewAttachmentIngestionReceipt, from ingestRoot: VerifiedAttachmentIngestRoot, id: AttachmentID
    ) throws -> StoredAttachmentContent {
        try Task.checkCancellation()
        guard receipt.byteCount <= AttachmentIngestionPolicy.provisionalMaximumBytes else {
            throw AttachmentContentError.invalidMetadata
        }
        let type = UTType(filenameExtension: (receipt.sourceFileName as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        let content = try StoredAttachmentContent(
            id: id, byteCount: Int64(receipt.byteCount), sha256: receipt.sha256,
            typeIdentifier: type, displayName: Self.safeDisplayName(receipt.sourceFileName)
        )
        let source = try AttachmentContentDescriptors.openReceipt(receipt, inside: ingestRoot)
        defer { close(source.fd) }
        let rootFD = try AttachmentContentDescriptors.openVerifiedRoot(root)
        defer { close(rootFD) }
        let scratchName = ".publish-\(UUID().uuidString.lowercased()).tmp"
        let destinationFD = openat(rootFD, scratchName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard destinationFD >= 0 else { throw AttachmentContentError.publicationFailed }
        defer { close(destinationFD) }
        let initial = try AttachmentContentDescriptors.snapshot(destinationFD)
        var published = false
        do {
            guard fchmod(destinationFD, S_IRUSR | S_IWUSR) == 0 else { throw AttachmentContentError.publicationFailed }
            try AttachmentContentDescriptors.requireOwnedFile(try AttachmentContentDescriptors.snapshot(destinationFD))
            let digest = try AttachmentContentDescriptors.hash(source.fd, exactBytes: content.byteCount, copyingTo: destinationFD)
            guard digest == content.sha256,
                  try AttachmentContentDescriptors.snapshot(source.fd) == source.snapshot,
                  try AttachmentQuarantine.read(source.fd) == receipt.quarantineData else {
                throw AttachmentContentError.stagedContentChanged
            }
            try AttachmentQuarantine.copy(receipt.quarantineData, to: destinationFD)
            guard fsync(destinationFD) == 0 else { throw AttachmentContentError.publicationFailed }
            try hooks.beforePublication?(root.url.appending(path: scratchName))
            try Task.checkCancellation()
            let current = try AttachmentContentDescriptors.snapshot(destinationFD)
            try AttachmentContentDescriptors.requireOwnedFile(current)
            guard current.identity == initial.identity, current.value.st_size == content.byteCount,
                  AttachmentContentDescriptors.pathMatches(scratchName, inside: rootFD, snapshot: current),
                  lseek(destinationFD, 0, SEEK_SET) == 0,
                  try AttachmentContentDescriptors.hash(destinationFD, exactBytes: content.byteCount) == content.sha256,
                  try AttachmentQuarantine.read(destinationFD) == receipt.quarantineData else {
                throw AttachmentContentError.contentMismatch
            }
            let checkedSource = try AttachmentContentDescriptors.openReceipt(receipt, inside: ingestRoot)
            close(checkedSource.fd)
            let checkedRoot = try AttachmentContentDescriptors.openVerifiedRoot(root)
            close(checkedRoot)
            try Task.checkCancellation()
            guard renameatx_np(rootFD, scratchName, rootFD, AttachmentContentDescriptors.fileName(id), UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? AttachmentContentError.collision : .publicationFailed
            }
            published = true
            guard fsync(rootFD) == 0 else { throw AttachmentContentError.publicationFailed }
        } catch {
            if !published {
                var value = stat()
                guard fstatat(rootFD, scratchName, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
                      AttachmentFileIdentity(value) == initial.identity,
                      unlinkat(rootFD, scratchName, 0) == 0 else {
                    throw AttachmentContentError.cleanupRefused
                }
            }
            throw error
        }
        // Finished content survives later cancellation or database failures.
        // The original ingest receipt remains available for exact explicit discard.
        try verify(id: id, byteCount: content.byteCount, sha256: content.sha256)
        return content
    }

    func verify(id: AttachmentID, byteCount: Int64, sha256: String) throws {
        try withVerifiedBytes(id: id, byteCount: byteCount, sha256: sha256) { _ in () }
    }

    func preview(
        id: AttachmentID, byteCount: Int64, sha256: String,
        displayName: String, typeIdentifier: String, pageNumber: Int
    ) throws -> AttachmentPreview {
        _ = try StoredAttachmentContent(
            id: id, byteCount: byteCount, sha256: sha256,
            typeIdentifier: typeIdentifier, displayName: displayName
        )
        guard (1...AttachmentPreviewLimits.maximumPDFPages).contains(pageNumber) else {
            throw AttachmentPreviewRenderingError.invalidPageNumber
        }
        return try withVerifiedBytes(
            id: id, byteCount: byteCount, sha256: sha256,
            captureByteLimit: AttachmentPreviewLimits.maximumInputBytes
        ) { bytes in
            try hooks.beforePreviewRendering?()
            try Task.checkCancellation()
            let result: AttachmentPreview
            if let bytes {
                result = try AttachmentPreviewRenderer.render(
                    bytes, displayName: displayName, typeIdentifier: typeIdentifier, pageNumber: pageNumber
                )
            } else {
                result = .unavailable(.fileTooLarge)
            }
            try hooks.afterPreviewRendering?()
            try Task.checkCancellation()
            return result
        }
    }

    private func withVerifiedBytes<Result>(
        id: AttachmentID, byteCount: Int64, sha256: String, captureByteLimit: Int? = nil,
        consume: (Data?) throws -> Result
    ) throws -> Result {
        try Task.checkCancellation()
        try AttachmentContentDescriptors.validateMetadata(byteCount: byteCount, sha256: sha256)
        let rootFD = try AttachmentContentDescriptors.openVerifiedRoot(root)
        defer { close(rootFD) }
        let name = AttachmentContentDescriptors.fileName(id)
        let fd = openat(rootFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ENOENT ? AttachmentContentError.missing : .unsafeFile }
        defer { close(fd) }
        let before = try AttachmentContentDescriptors.snapshot(fd)
        try AttachmentContentDescriptors.requireOwnedFile(before)
        guard before.value.st_size == byteCount else { throw AttachmentContentError.contentMismatch }
        let read = try AttachmentContentDescriptors.readAndHash(
            fd, exactBytes: byteCount, captureByteLimit: captureByteLimit
        )
        guard read.sha256 == sha256 else {
            throw AttachmentContentError.contentMismatch
        }
        // Reading must not silently accept an inaccessible quarantine attribute.
        let quarantine = try AttachmentQuarantine.read(fd)
        try hooks.beforeVerificationCompletes?()
        try revalidate()
        let result = try consume(read.bytes)
        try Task.checkCancellation()
        try revalidate()
        return result

        func revalidate() throws {
            guard try AttachmentContentDescriptors.snapshot(fd) == before,
                  AttachmentContentDescriptors.pathMatches(name, inside: rootFD, snapshot: before),
                  try AttachmentQuarantine.read(fd) == quarantine else {
                throw AttachmentContentError.contentMismatch
            }
            let checked = try AttachmentContentDescriptors.openVerifiedRoot(root)
            close(checked)
        }
    }

    private static func safeDisplayName(_ original: String) -> String {
        var label = String(String.UnicodeScalarView(original.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        while label.utf8.count > 255 { label.removeLast() }
        return label.isEmpty || label == "." || label == ".." ? "Attachment" : label
    }
}

/// Copy only the existing quarantine value, never broad xattrs, execute bits,
/// origin URLs or source flags. ENOATTR proves absence; all other errors fail.
enum AttachmentQuarantine {
    static func read(_ fd: Int32) throws -> Data? {
        let count = fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0)
        if count < 0 {
            if errno == ENOATTR { return nil }
            throw AttachmentIngestionError.quarantineUnavailable
        }
        // Reuse the existing attachment input ceiling rather than allocating
        // an unbounded amount from an untrusted extended-attribute size.
        guard count <= Int(AttachmentIngestionPolicy.provisionalMaximumBytes) else {
            throw AttachmentIngestionError.quarantineUnavailable
        }
        if count == 0 { return Data() }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
        guard readCount == count else { throw AttachmentIngestionError.quarantineUnavailable }
        return data
    }

    static func copy(_ value: Data?, to fd: Int32) throws {
        guard try read(fd) == nil else { throw AttachmentIngestionError.quarantineUnavailable }
        if let value {
            let result = value.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE) }
            guard result == 0 else { throw AttachmentIngestionError.quarantineUnavailable }
        }
        guard try read(fd) == value else { throw AttachmentIngestionError.quarantineUnavailable }
    }
}

private struct AttachmentFileSnapshot: Equatable {
    let value: stat
    var identity: AttachmentFileIdentity { AttachmentFileIdentity(value) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.value.st_size == rhs.value.st_size &&
        lhs.value.st_mode == rhs.value.st_mode && lhs.value.st_uid == rhs.value.st_uid &&
        lhs.value.st_nlink == rhs.value.st_nlink && lhs.value.st_flags == rhs.value.st_flags &&
        lhs.value.st_mtimespec.tv_sec == rhs.value.st_mtimespec.tv_sec &&
        lhs.value.st_mtimespec.tv_nsec == rhs.value.st_mtimespec.tv_nsec &&
        lhs.value.st_ctimespec.tv_sec == rhs.value.st_ctimespec.tv_sec &&
        lhs.value.st_ctimespec.tv_nsec == rhs.value.st_ctimespec.tv_nsec
    }
}

private enum AttachmentContentDescriptors {
    static func fileName(_ id: AttachmentID) -> String { id.persistedValue + ".blob" }

    static func validateMetadata(byteCount: Int64, sha256: String) throws {
        guard byteCount >= 0, byteCount <= Int64(AttachmentIngestionPolicy.provisionalMaximumBytes),
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AttachmentContentError.invalidMetadata
        }
    }

    static func verifyOwnedSupport(_ root: VerifiedOwnedRoot) throws {
        guard root.kind == .applicationSupport else { throw AttachmentContentError.wrongOwnedRoot }
        _ = try OwnedRootVerifier().verify(
            OwnedRootDescriptor(kind: .applicationSupport, url: root.url),
            expectedInstallationID: root.installationID, expectedRootID: root.rootID
        )
    }

    static func openVerifiedRoot(_ root: VerifiedAttachmentContentRoot) throws -> Int32 {
        let opened = try openHierarchy(root.applicationSupportURL, includingAttachments: true)
        guard opened.identities == root.identities else {
            close(opened.fd)
            throw AttachmentContentError.rootIdentityChanged
        }
        return opened.fd
    }

    static func openHierarchy(_ supportURL: URL, includingAttachments: Bool) throws -> (fd: Int32, identities: [AttachmentFileIdentity]) {
        var current = try directoryChain(supportURL)
        var identities: [AttachmentFileIdentity] = []
        do {
            let children: [String?] = includingAttachments ? [nil, "HighChurn.noindex", "Attachments"] : [nil, "HighChurn.noindex"]
            for child in children {
                if let child {
                    let next = openat(current, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw AttachmentContentError.rootUnavailable }
                    close(current)
                    current = next
                }
                let value = try snapshot(current)
                try requireDirectory(value)
                try requireLocalVolume(current)
                identities.append(value.identity)
            }
            return (current, identities)
        } catch { close(current); throw error }
    }

    static func openReceipt(
        _ receipt: PreviewAttachmentIngestionReceipt, inside root: VerifiedAttachmentIngestRoot
    ) throws -> (fd: Int32, snapshot: AttachmentFileSnapshot) {
        let scratchName = receipt.operationID.uuidString.lowercased()
        let expected = root.url.appending(path: scratchName).appending(path: "payload")
        guard receipt.cacheRootID == root.cacheRootID,
              FileURLNormalization.lexical(receipt.stagedFileURL) == FileURLNormalization.lexical(expected) else {
            throw AttachmentContentError.receiptMismatch
        }
        let cacheFD = try directoryChain(root.cacheRootURL)
        defer { close(cacheFD) }
        let cache = try snapshot(cacheFD)
        try requireDirectory(cache)
        try requireLocalVolume(cacheFD)
        guard cache.identity == root.cacheRootIdentity else { throw AttachmentContentError.rootIdentityChanged }
        let ingestFD = openat(cacheFD, "AttachmentIngest", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard ingestFD >= 0 else { throw AttachmentContentError.receiptMismatch }
        defer { close(ingestFD) }
        let ingest = try snapshot(ingestFD)
        try requireDirectory(ingest)
        try requireLocalVolume(ingestFD)
        guard ingest.identity == root.identity else { throw AttachmentContentError.rootIdentityChanged }
        let scratchFD = openat(ingestFD, scratchName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scratchFD >= 0 else { throw AttachmentContentError.receiptMismatch }
        defer { close(scratchFD) }
        let scratch = try snapshot(scratchFD)
        try requireDirectory(scratch)
        try requireLocalVolume(scratchFD)
        guard scratch.identity == receipt.scratchIdentity else { throw AttachmentContentError.receiptMismatch }
        let fd = openat(scratchFD, "payload", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AttachmentContentError.receiptMismatch }
        do {
            let value = try snapshot(fd)
            try requireOwnedFile(value)
            guard value.identity == receipt.stagedIdentity, value.value.st_size >= 0,
                  UInt64(value.value.st_size) == receipt.byteCount else { throw AttachmentContentError.receiptMismatch }
            guard try AttachmentQuarantine.read(fd) == receipt.quarantineData else { throw AttachmentContentError.quarantineMismatch }
            return (fd, value)
        } catch { close(fd); throw error }
    }

    static func directoryChain(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.contains("\0"), !url.pathComponents.contains("..") else {
            throw AttachmentContentError.rootMismatch
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AttachmentContentError.rootUnavailable }
        for component in url.pathComponents.dropFirst() where component != "." && !component.isEmpty {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw AttachmentContentError.rootUnavailable }
            fd = next
        }
        return fd
    }

    static func snapshot(_ fd: Int32) throws -> AttachmentFileSnapshot {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw AttachmentContentError.unsafeFile }
        return AttachmentFileSnapshot(value: value)
    }

    static func requireDirectory(_ value: AttachmentFileSnapshot) throws {
        guard value.value.st_mode & S_IFMT == S_IFDIR,
              value.value.st_mode & 0o7777 == 0o700, value.value.st_uid == geteuid() else {
            throw AttachmentContentError.rootProtectionInvalid
        }
    }

    static func requireLocalVolume(_ fd: Int32) throws {
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw AttachmentContentError.rootProtectionInvalid
        }
        // Provider admission is owned by bootstrap. A .noindex marker does not
        // control cloud sync; this verifies the currently opened local volume.
    }

    static func requireOwnedFile(_ value: AttachmentFileSnapshot) throws {
        guard value.value.st_mode & S_IFMT == S_IFREG, value.value.st_mode & 0o7777 == 0o600,
              value.value.st_uid == geteuid(), value.value.st_nlink == 1 else {
            throw AttachmentContentError.unsafeFile
        }
    }

    static func pathMatches(_ name: String, inside rootFD: Int32, snapshot: AttachmentFileSnapshot) -> Bool {
        var value = stat()
        return fstatat(rootFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 && AttachmentFileSnapshot(value: value) == snapshot
    }

    static func hash(_ fd: Int32, exactBytes: Int64, copyingTo destination: Int32? = nil) throws -> String {
        try readAndHash(fd, exactBytes: exactBytes, copyingTo: destination).sha256
    }

    static func readAndHash(
        _ fd: Int32, exactBytes: Int64, copyingTo destination: Int32? = nil,
        captureByteLimit: Int? = nil
    ) throws -> (sha256: String, bytes: Data?) {
        var hasher = SHA256()
        var copied: Int64 = 0
        var captured: Data?
        if let captureByteLimit, exactBytes <= captureByteLimit {
            captured = Data()
            captured?.reserveCapacity(Int(exactBytes))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AttachmentContentError.contentMismatch }
            if count == 0 { break }
            guard copied <= exactBytes, Int64(count) <= exactBytes - copied else { throw AttachmentContentError.contentMismatch }
            let data = Data(buffer.prefix(count))
            hasher.update(data: data)
            captured?.append(data)
            if let destination { try writeAll(data, to: destination) }
            copied += Int64(count)
        }
        guard copied == exactBytes else { throw AttachmentContentError.contentMismatch }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), captured)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AttachmentContentError.publicationFailed }
                offset += count
            }
        }
    }
}
