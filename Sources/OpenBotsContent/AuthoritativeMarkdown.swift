import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain

public enum AuthoritativeMarkdownError: Error, Equatable, Sendable {
    case wrongOwnedRoot
    case rootMismatch
    case rootUnavailable
    case rootIdentityChanged
    case rootPermissionsUnsafe(actual: UInt16)
    case rootOwnerMismatch
    case invalidRevision
    case invalidRelativePath
    case invalidDigest
    case contentTooLarge(maximumBytes: Int)
    case directoryUnavailable
    case directoryPermissionsUnsafe(actual: UInt16)
    case directoryOwnerMismatch
    case stagingCreationFailed(code: Int32)
    case stagingWriteFailed(code: Int32)
    case synchronizationFailed(code: Int32)
    case collision
    case publishFailed(code: Int32)
    case documentMissing
    case documentIsNotRegularFile
    case documentPermissionsUnsafe(actual: UInt16)
    case documentOwnerMismatch
    case documentHasUnexpectedLinks
    case documentIdentityChanged
    case digestMismatch(expected: String, actual: String)
    case invalidUTF8
    case rollbackReceiptMismatch
    case rollbackRefused
    case quarantineRefused
    case quarantineCollision
    case quarantineFailed(code: Int32)
}

public struct AuthoritativeMarkdownFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    fileprivate init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }
}

/// Read-only evidence for the exact app-owned Markdown authority. It can only be
/// produced for `Application Support/.../HighChurn.noindex/Memory` beneath a
/// verified preview Application Support root.
public struct VerifiedAuthoritativeMarkdownRoot: Hashable, Sendable {
    public let url: URL
    public let applicationSupportRootID: UUID
    public let identity: AuthoritativeMarkdownFileIdentity

    fileprivate init(
        url: URL,
        applicationSupportRootID: UUID,
        identity: AuthoritativeMarkdownFileIdentity
    ) {
        self.url = url
        self.applicationSupportRootID = applicationSupportRootID
        self.identity = identity
    }
}

public struct AuthoritativeMarkdownRootVerifier: Sendable {
    public init() {}

    public func verify(
        _ authorityURL: URL,
        inside applicationSupportRoot: VerifiedOwnedRoot
    ) throws -> VerifiedAuthoritativeMarkdownRoot {
        guard applicationSupportRoot.kind == .applicationSupport else {
            throw AuthoritativeMarkdownError.wrongOwnedRoot
        }
        let expected = FileURLNormalization.lexical(
            applicationSupportRoot.url
                .appending(path: "HighChurn.noindex", directoryHint: .isDirectory)
                .appending(path: "Memory", directoryHint: .isDirectory)
        )
        guard FileURLNormalization.lexical(authorityURL) == expected else {
            throw AuthoritativeMarkdownError.rootMismatch
        }

        let descriptor: CanonicalPath
        do {
            descriptor = try PathSafety().canonicalExistingDirectory(expected)
        } catch {
            throw AuthoritativeMarkdownError.rootUnavailable
        }
        guard descriptor.url == expected else {
            throw AuthoritativeMarkdownError.rootMismatch
        }

        var value = stat()
        guard lstat(expected.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw AuthoritativeMarkdownError.rootUnavailable
        }
        guard value.st_mode & 0o777 == 0o700 else {
            throw AuthoritativeMarkdownError.rootPermissionsUnsafe(actual: UInt16(value.st_mode & 0o777))
        }
        guard value.st_uid == geteuid() else {
            throw AuthoritativeMarkdownError.rootOwnerMismatch
        }
        return VerifiedAuthoritativeMarkdownRoot(
            url: expected,
            applicationSupportRootID: applicationSupportRoot.rootID,
            identity: AuthoritativeMarkdownFileIdentity(value)
        )
    }
}

public struct AuthoritativeMarkdownPath: Sendable {
    /// A durable intent names its one staging file before any bytes are written.
    public static func stagingRelativePath(
        documentID: MemoryDocumentID, scope: MemoryScope, revision: UInt64, operationID: UUID
    ) throws -> String {
        let final = try relativePath(documentID: documentID, scope: scope, revision: revision)
        return final.split(separator: "/").dropLast().joined(separator: "/")
            + "/.openbots-stage-\(operationID.uuidString.lowercased()).tmp"
    }

    public static func relativePath(
        documentID: MemoryDocumentID,
        scope: MemoryScope,
        revision: UInt64
    ) throws -> String {
        guard revision > 0 else { throw AuthoritativeMarkdownError.invalidRevision }
        let scopeComponents: [String]
        switch scope {
        case .user:
            scopeComponents = ["User"]
        case let .teammate(teammateID):
            scopeComponents = ["Teammates", teammateID.persistedValue]
        case let .project(projectID):
            scopeComponents = ["Projects", projectID.persistedValue]
        }
        let fileName = "\(documentID.persistedValue)-r\(revision).md"
        return (["Documents"] + scopeComponents + [fileName]).joined(separator: "/")
    }
}

public struct AuthoritativeMarkdownReference: Equatable, Sendable {
    public let documentID: MemoryDocumentID
    public let scope: MemoryScope
    public let revision: UInt64
    public let relativePath: String
    public let contentDigest: String

    public init(
        documentID: MemoryDocumentID,
        scope: MemoryScope,
        revision: UInt64,
        relativePath: String,
        contentDigest: String
    ) throws {
        let expected = try AuthoritativeMarkdownPath.relativePath(
            documentID: documentID,
            scope: scope,
            revision: revision
        )
        guard relativePath == expected else {
            throw AuthoritativeMarkdownError.invalidRelativePath
        }
        guard AuthoritativeMarkdownValidation.isSHA256(contentDigest) else {
            throw AuthoritativeMarkdownError.invalidDigest
        }
        self.documentID = documentID
        self.scope = scope
        self.revision = revision
        self.relativePath = relativePath
        self.contentDigest = contentDigest
    }

    public init(document: MemoryDocument) throws {
        try self.init(
            documentID: document.id,
            scope: document.scope,
            revision: document.revision,
            relativePath: document.relativePath,
            contentDigest: document.contentDigest
        )
    }
}

public struct AuthoritativeMarkdownPublicationRequest: Equatable, Sendable {
    public let documentID: MemoryDocumentID
    public let scope: MemoryScope
    public let revision: UInt64
    public let markdown: String
    public let authority: VerifiedAuthoritativeMarkdownRoot
    public let operationID: UUID?

    public init(
        documentID: MemoryDocumentID,
        scope: MemoryScope,
        revision: UInt64,
        markdown: String,
        authority: VerifiedAuthoritativeMarkdownRoot,
        operationID: UUID? = nil
    ) throws {
        guard revision > 0 else { throw AuthoritativeMarkdownError.invalidRevision }
        self.documentID = documentID
        self.scope = scope
        self.revision = revision
        self.markdown = markdown
        self.authority = authority
        self.operationID = operationID
    }
}

public struct AuthoritativeMarkdownPublicationReceipt: Equatable, Sendable {
    public let reference: AuthoritativeMarkdownReference
    public let byteCount: Int
    public let exactFileURL: URL

    fileprivate let applicationSupportRootID: UUID
    fileprivate let authorityIdentity: AuthoritativeMarkdownFileIdentity
    fileprivate let fileIdentity: AuthoritativeMarkdownFileIdentity

    fileprivate init(
        reference: AuthoritativeMarkdownReference,
        byteCount: Int,
        exactFileURL: URL,
        applicationSupportRootID: UUID,
        authorityIdentity: AuthoritativeMarkdownFileIdentity,
        fileIdentity: AuthoritativeMarkdownFileIdentity
    ) {
        self.reference = reference
        self.byteCount = byteCount
        self.exactFileURL = exactFileURL
        self.applicationSupportRootID = applicationSupportRootID
        self.authorityIdentity = authorityIdentity
        self.fileIdentity = fileIdentity
    }
}

public struct ValidatedAuthoritativeMarkdown: Equatable, Sendable {
    public let reference: AuthoritativeMarkdownReference
    public let markdown: String
    /// A Reveal/Open-in-Finder URL returned only after the exact current file
    /// passed path, type, ownership, mode, identity, and digest validation.
    public let validatedFileURL: URL
}

public enum AuthoritativeMarkdownMalformation: Equatable, Sendable {
    case digestMismatch(expected: String, actual: String)
    case invalidUTF8(actualDigest: String)
}

public struct AuthoritativeMarkdownQuarantineReceipt: Equatable, Sendable {
    public let reference: AuthoritativeMarkdownReference
    public let originalFileURL: URL
    public let quarantinedFileURL: URL
    public let byteCount: Int
    public let malformation: AuthoritativeMarkdownMalformation
}

struct AuthoritativeMarkdownTestHooks: Sendable {
    var beforeExclusivePublish: (@Sendable () throws -> Void)?
    var beforeFinalPathRevalidation: (@Sendable () throws -> Void)?

    init(
        beforeExclusivePublish: (@Sendable () throws -> Void)? = nil,
        beforeFinalPathRevalidation: (@Sendable () throws -> Void)? = nil
    ) {
        self.beforeExclusivePublish = beforeExclusivePublish
        self.beforeFinalPathRevalidation = beforeFinalPathRevalidation
    }
}

public struct AuthoritativeMarkdownStore: Sendable {
    public static let defaultMaximumBytes = 8 * 1_024 * 1_024

    private let maximumBytes: Int
    private let hooks: AuthoritativeMarkdownTestHooks

    public init(maximumBytes: Int = Self.defaultMaximumBytes) {
        self.maximumBytes = maximumBytes
        hooks = AuthoritativeMarkdownTestHooks()
    }

    init(maximumBytes: Int, hooks: AuthoritativeMarkdownTestHooks) {
        self.maximumBytes = maximumBytes
        self.hooks = hooks
    }

    public func publish(
        _ request: AuthoritativeMarkdownPublicationRequest
    ) async throws -> AuthoritativeMarkdownPublicationReceipt {
        let maximumBytes = maximumBytes
        let hooks = hooks
        return try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(maximumBytes: maximumBytes, hooks: hooks)
                .publish(request)
        }.value
    }

    public func read(
        _ reference: AuthoritativeMarkdownReference,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws -> ValidatedAuthoritativeMarkdown {
        let maximumBytes = maximumBytes
        let hooks = hooks
        return try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(maximumBytes: maximumBytes, hooks: hooks)
                .read(reference, inside: authority)
        }.value
    }

    /// Resolves only the two exact paths named by a durable publication intent.
    /// Caller must revalidate the pending operation before this call and again
    /// before catalog commit. This method grants no authority from file presence.
    public func recoverPublication(
        reference: AuthoritativeMarkdownReference, operationID: UUID,
        expectedByteCount: Int, inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws -> ValidatedAuthoritativeMarkdown {
        let maximumBytes = maximumBytes
        let hooks = hooks
        return try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(maximumBytes: maximumBytes, hooks: hooks)
                .recoverPublication(reference: reference, operationID: operationID,
                    expectedByteCount: expectedByteCount, inside: authority)
        }.value
    }

    /// Read-only counterpart used to revalidate evidence before a recovery rename.
    public func readPendingPublication(
        reference: AuthoritativeMarkdownReference, operationID: UUID,
        expectedByteCount: Int, inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws -> ValidatedAuthoritativeMarkdown {
        let maximumBytes = maximumBytes
        let hooks = hooks
        return try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(maximumBytes: maximumBytes, hooks: hooks)
                .recoverPublication(reference: reference, operationID: operationID,
                    expectedByteCount: expectedByteCount, inside: authority, publishStaged: false)
        }.value
    }

    public func validatedRevealURL(
        for reference: AuthoritativeMarkdownReference,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws -> URL {
        try await read(reference, inside: authority).validatedFileURL
    }

    /// Removes only the exact still-identical immutable file from this receipt.
    /// Parent directories are deliberately retained; no traversal or cleanup is performed.
    public func rollback(
        _ receipt: AuthoritativeMarkdownPublicationReceipt,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws {
        let maximumBytes = maximumBytes
        try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(
                maximumBytes: maximumBytes,
                hooks: AuthoritativeMarkdownTestHooks()
            ).rollback(receipt, inside: authority)
        }.value
    }

    /// Moves only a proven-malformed current authority file into the app-owned
    /// Quarantine directory. The destination is deterministic and exclusive;
    /// a prior quarantine is never overwritten or cleaned up automatically.
    public func quarantine(
        _ reference: AuthoritativeMarkdownReference,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) async throws -> AuthoritativeMarkdownQuarantineReceipt {
        let maximumBytes = maximumBytes
        let hooks = hooks
        return try await Task.detached(priority: .utility) {
            try AuthoritativeMarkdownExecutor(maximumBytes: maximumBytes, hooks: hooks)
                .quarantine(reference, inside: authority)
        }.value
    }
}

private enum AuthoritativeMarkdownValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct AuthoritativeMarkdownExecutor {
    private let maximumBytes: Int
    private let hooks: AuthoritativeMarkdownTestHooks

    init(maximumBytes: Int, hooks: AuthoritativeMarkdownTestHooks) {
        self.maximumBytes = maximumBytes
        self.hooks = hooks
    }

    func publish(
        _ request: AuthoritativeMarkdownPublicationRequest
    ) throws -> AuthoritativeMarkdownPublicationReceipt {
        let data = Data(request.markdown.utf8)
        guard maximumBytes >= 0, data.count <= maximumBytes else {
            throw AuthoritativeMarkdownError.contentTooLarge(maximumBytes: maximumBytes)
        }
        let relativePath = try AuthoritativeMarkdownPath.relativePath(
            documentID: request.documentID,
            scope: request.scope,
            revision: request.revision
        )
        let components = try validatedComponents(relativePath)
        let rootFD = try openAndRevalidateRoot(request.authority)
        defer { close(rootFD) }
        let parentFD = try openParent(
            components: Array(components.dropLast()),
            beneath: rootFD,
            createIfMissing: true
        )
        defer { close(parentFD) }

        let finalName = components.last!
        let stagingName = ".openbots-stage-\((request.operationID ?? UUID()).uuidString.lowercased()).tmp"
        let stagingFD = stagingName.withCString {
            openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard stagingFD >= 0 else {
            throw AuthoritativeMarkdownError.stagingCreationFailed(code: errno)
        }

        var published = false
        defer {
            close(stagingFD)
            if !published {
                _ = stagingName.withCString { unlinkat(parentFD, $0, 0) }
            }
        }
        guard fchmod(stagingFD, S_IRUSR | S_IWUSR) == 0 else {
            throw AuthoritativeMarkdownError.stagingCreationFailed(code: errno)
        }
        var stagedStat = stat()
        guard fstat(stagingFD, &stagedStat) == 0,
              stagedStat.st_mode & S_IFMT == S_IFREG,
              stagedStat.st_mode & 0o777 == 0o600,
              stagedStat.st_uid == geteuid(),
              stagedStat.st_nlink == 1
        else {
            throw AuthoritativeMarkdownError.stagingCreationFailed(code: errno)
        }

        try writeAll(data, to: stagingFD)
        guard fsync(stagingFD) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }
        try hooks.beforeExclusivePublish?()

        let result = stagingName.withCString { staging in
            finalName.withCString { final in
                renameatx_np(parentFD, staging, parentFD, final, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw AuthoritativeMarkdownError.collision }
            throw AuthoritativeMarkdownError.publishFailed(code: errno)
        }
        published = true
        guard fsync(parentFD) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }

        let digest = AuthoritativeMarkdownValidation.sha256(data)
        let reference = try AuthoritativeMarkdownReference(
            documentID: request.documentID,
            scope: request.scope,
            revision: request.revision,
            relativePath: relativePath,
            contentDigest: digest
        )
        return AuthoritativeMarkdownPublicationReceipt(
            reference: reference,
            byteCount: data.count,
            exactFileURL: exactURL(for: components, beneath: request.authority.url),
            applicationSupportRootID: request.authority.applicationSupportRootID,
            authorityIdentity: request.authority.identity,
            fileIdentity: AuthoritativeMarkdownFileIdentity(stagedStat)
        )
    }

    func read(
        _ reference: AuthoritativeMarkdownReference,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) throws -> ValidatedAuthoritativeMarkdown {
        let expected = try AuthoritativeMarkdownPath.relativePath(
            documentID: reference.documentID,
            scope: reference.scope,
            revision: reference.revision
        )
        guard reference.relativePath == expected else {
            throw AuthoritativeMarkdownError.invalidRelativePath
        }
        guard AuthoritativeMarkdownValidation.isSHA256(reference.contentDigest) else {
            throw AuthoritativeMarkdownError.invalidDigest
        }
        let components = try validatedComponents(reference.relativePath)
        let rootFD = try openAndRevalidateRoot(authority)
        defer { close(rootFD) }
        let parentFD = try openParent(
            components: Array(components.dropLast()),
            beneath: rootFD,
            createIfMissing: false
        )
        defer { close(parentFD) }
        let fileName = components.last!
        let opened = try openValidatedFile(named: fileName, beneath: parentFD)
        defer { close(opened.fileDescriptor) }
        let data = try readAll(from: opened.fileDescriptor, expectedSize: opened.size)
        let actualDigest = AuthoritativeMarkdownValidation.sha256(data)
        guard actualDigest == reference.contentDigest else {
            throw AuthoritativeMarkdownError.digestMismatch(
                expected: reference.contentDigest,
                actual: actualDigest
            )
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw AuthoritativeMarkdownError.invalidUTF8
        }

        try hooks.beforeFinalPathRevalidation?()
        try requirePathIdentity(opened.identity, named: fileName, beneath: parentFD)
        return ValidatedAuthoritativeMarkdown(
            reference: reference,
            markdown: markdown,
            validatedFileURL: exactURL(for: components, beneath: authority.url)
        )
    }

    func recoverPublication(
        reference: AuthoritativeMarkdownReference, operationID: UUID,
        expectedByteCount: Int, inside authority: VerifiedAuthoritativeMarkdownRoot,
        publishStaged: Bool = true
    ) throws -> ValidatedAuthoritativeMarkdown {
        guard expectedByteCount >= 0, expectedByteCount <= maximumBytes else {
            throw AuthoritativeMarkdownError.contentTooLarge(maximumBytes: maximumBytes)
        }
        // An already published file is accepted only after the ordinary exact
        // path/type/identity/digest checks. An invalid final file never falls back.
        do {
            let final = try read(reference, inside: authority)
            guard final.markdown.utf8.count == expectedByteCount else {
                throw AuthoritativeMarkdownError.documentIdentityChanged
            }
            return final
        } catch AuthoritativeMarkdownError.documentMissing {
            // Only an absent final file allows inspecting the named staging file.
        }
        let components = try validatedComponents(reference.relativePath)
        let rootFD = try openAndRevalidateRoot(authority)
        defer { close(rootFD) }
        let parentFD = try openParent(components: Array(components.dropLast()),
            beneath: rootFD, createIfMissing: false)
        defer { close(parentFD) }
        let stagingName = ".openbots-stage-\(operationID.uuidString.lowercased()).tmp"
        let opened = try openValidatedFile(named: stagingName, beneath: parentFD)
        defer { close(opened.fileDescriptor) }
        guard opened.size == expectedByteCount else {
            throw AuthoritativeMarkdownError.documentIdentityChanged
        }
        let data = try readAll(from: opened.fileDescriptor, expectedSize: opened.size)
        let digest = AuthoritativeMarkdownValidation.sha256(data)
        guard digest == reference.contentDigest else {
            throw AuthoritativeMarkdownError.digestMismatch(expected: reference.contentDigest, actual: digest)
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw AuthoritativeMarkdownError.invalidUTF8
        }
        if !publishStaged {
            try requirePathIdentity(opened.identity, named: stagingName, beneath: parentFD)
            return ValidatedAuthoritativeMarkdown(reference: reference, markdown: markdown,
                validatedFileURL: exactURL(for: Array(components.dropLast()) + [stagingName], beneath: authority.url))
        }
        guard fsync(opened.fileDescriptor) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }
        try hooks.beforeExclusivePublish?()
        try requirePathIdentity(opened.identity, named: stagingName, beneath: parentFD)
        let result = stagingName.withCString { staging in
            components.last!.withCString { final in
                renameatx_np(parentFD, staging, parentFD, final, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw AuthoritativeMarkdownError.collision }
            throw AuthoritativeMarkdownError.publishFailed(code: errno)
        }
        guard fsync(parentFD) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }
        return try read(reference, inside: authority)
    }

    func rollback(
        _ receipt: AuthoritativeMarkdownPublicationReceipt,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) throws {
        guard receipt.applicationSupportRootID == authority.applicationSupportRootID,
              receipt.authorityIdentity == authority.identity
        else {
            throw AuthoritativeMarkdownError.rollbackReceiptMismatch
        }
        let expectedURL = exactURL(
            for: try validatedComponents(receipt.reference.relativePath),
            beneath: authority.url
        )
        guard FileURLNormalization.lexical(receipt.exactFileURL) == expectedURL else {
            throw AuthoritativeMarkdownError.rollbackReceiptMismatch
        }

        let components = try validatedComponents(receipt.reference.relativePath)
        let rootFD = try openAndRevalidateRoot(authority)
        defer { close(rootFD) }
        let parentFD = try openParent(
            components: Array(components.dropLast()),
            beneath: rootFD,
            createIfMissing: false
        )
        defer { close(parentFD) }
        let fileName = components.last!
        let opened = try openValidatedFile(named: fileName, beneath: parentFD)
        defer { close(opened.fileDescriptor) }
        guard opened.identity == receipt.fileIdentity,
              opened.size == receipt.byteCount
        else {
            throw AuthoritativeMarkdownError.rollbackRefused
        }
        let data = try readAll(from: opened.fileDescriptor, expectedSize: opened.size)
        guard AuthoritativeMarkdownValidation.sha256(data) == receipt.reference.contentDigest else {
            throw AuthoritativeMarkdownError.rollbackRefused
        }
        try requirePathIdentity(receipt.fileIdentity, named: fileName, beneath: parentFD)
        let result = fileName.withCString { unlinkat(parentFD, $0, 0) }
        guard result == 0 else { throw AuthoritativeMarkdownError.rollbackRefused }
        guard fsync(parentFD) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }
    }

    func quarantine(
        _ reference: AuthoritativeMarkdownReference,
        inside authority: VerifiedAuthoritativeMarkdownRoot
    ) throws -> AuthoritativeMarkdownQuarantineReceipt {
        let expectedRelativePath = try AuthoritativeMarkdownPath.relativePath(
            documentID: reference.documentID,
            scope: reference.scope,
            revision: reference.revision
        )
        guard reference.relativePath == expectedRelativePath else {
            throw AuthoritativeMarkdownError.invalidRelativePath
        }
        guard AuthoritativeMarkdownValidation.isSHA256(reference.contentDigest) else {
            throw AuthoritativeMarkdownError.invalidDigest
        }
        let components = try validatedComponents(reference.relativePath)
        let rootFD = try openAndRevalidateRoot(authority)
        defer { close(rootFD) }
        let sourceParentFD = try openParent(
            components: Array(components.dropLast()),
            beneath: rootFD,
            createIfMissing: false
        )
        defer { close(sourceParentFD) }
        let sourceName = components.last!
        let opened = try openValidatedFile(named: sourceName, beneath: sourceParentFD)
        defer { close(opened.fileDescriptor) }
        let data = try readAll(from: opened.fileDescriptor, expectedSize: opened.size)
        let actualDigest = AuthoritativeMarkdownValidation.sha256(data)
        let malformation: AuthoritativeMarkdownMalformation
        if actualDigest != reference.contentDigest {
            malformation = .digestMismatch(expected: reference.contentDigest, actual: actualDigest)
        } else if String(data: data, encoding: .utf8) == nil {
            malformation = .invalidUTF8(actualDigest: actualDigest)
        } else {
            throw AuthoritativeMarkdownError.quarantineRefused
        }

        try hooks.beforeFinalPathRevalidation?()
        try requirePathIdentity(opened.identity, named: sourceName, beneath: sourceParentFD)
        let quarantineFD = try openParent(
            components: ["Quarantine"],
            beneath: rootFD,
            createIfMissing: true
        )
        defer { close(quarantineFD) }
        let quarantineName = [
            reference.documentID.persistedValue,
            "r\(reference.revision)",
            reference.contentDigest
        ].joined(separator: "-") + ".md"
        let moveResult = sourceName.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(
                    sourceParentFD,
                    source,
                    quarantineFD,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moveResult == 0 else {
            if errno == EEXIST { throw AuthoritativeMarkdownError.quarantineCollision }
            throw AuthoritativeMarkdownError.quarantineFailed(code: errno)
        }
        do {
            try requirePathIdentity(opened.identity, named: quarantineName, beneath: quarantineFD)
        } catch {
            throw AuthoritativeMarkdownError.quarantineFailed(code: ESTALE)
        }
        guard fsync(sourceParentFD) == 0, fsync(quarantineFD) == 0 else {
            throw AuthoritativeMarkdownError.synchronizationFailed(code: errno)
        }
        let quarantineURL = authority.url
            .appending(path: "Quarantine", directoryHint: .isDirectory)
            .appending(path: quarantineName, directoryHint: .notDirectory)
        return AuthoritativeMarkdownQuarantineReceipt(
            reference: reference,
            originalFileURL: exactURL(for: components, beneath: authority.url),
            quarantinedFileURL: quarantineURL,
            byteCount: data.count,
            malformation: malformation
        )
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0")
        else {
            throw AuthoritativeMarkdownError.invalidRelativePath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else {
            throw AuthoritativeMarkdownError.invalidRelativePath
        }
        return components
    }

    private func exactURL(for components: [String], beneath root: URL) -> URL {
        components.reduce(root) { partial, component in
            partial.appending(path: component, directoryHint: .inferFromPath)
        }
    }

    private func openAndRevalidateRoot(_ root: VerifiedAuthoritativeMarkdownRoot) throws -> Int32 {
        let fileDescriptor: Int32
        do {
            fileDescriptor = try openDirectoryChainNoFollow(root.url)
        } catch {
            throw AuthoritativeMarkdownError.rootUnavailable
        }
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.rootUnavailable
        }
        guard AuthoritativeMarkdownFileIdentity(value) == root.identity else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.rootIdentityChanged
        }
        guard value.st_mode & 0o777 == 0o700 else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.rootPermissionsUnsafe(actual: UInt16(value.st_mode & 0o777))
        }
        guard value.st_uid == geteuid() else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.rootOwnerMismatch
        }
        return fileDescriptor
    }

    private func openParent(
        components: [String],
        beneath rootFD: Int32,
        createIfMissing: Bool
    ) throws -> Int32 {
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else { throw AuthoritativeMarkdownError.directoryUnavailable }
        for component in components {
            var nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if nextFD < 0, errno == ENOENT, createIfMissing {
                let created = component.withCString { mkdirat(currentFD, $0, S_IRWXU) }
                guard created == 0 || errno == EEXIST else {
                    close(currentFD)
                    throw AuthoritativeMarkdownError.directoryUnavailable
                }
                nextFD = component.withCString {
                    openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
            }
            guard nextFD >= 0 else {
                close(currentFD)
                throw AuthoritativeMarkdownError.directoryUnavailable
            }
            var value = stat()
            guard fstat(nextFD, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
                close(nextFD)
                close(currentFD)
                throw AuthoritativeMarkdownError.directoryUnavailable
            }
            guard value.st_mode & 0o777 == 0o700 else {
                let actual = UInt16(value.st_mode & 0o777)
                close(nextFD)
                close(currentFD)
                throw AuthoritativeMarkdownError.directoryPermissionsUnsafe(actual: actual)
            }
            guard value.st_uid == geteuid() else {
                close(nextFD)
                close(currentFD)
                throw AuthoritativeMarkdownError.directoryOwnerMismatch
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private func openValidatedFile(named name: String, beneath parentFD: Int32) throws -> OpenedFile {
        let fileDescriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { throw AuthoritativeMarkdownError.documentMissing }
            throw AuthoritativeMarkdownError.documentIsNotRegularFile
        }
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.documentIsNotRegularFile
        }
        guard value.st_mode & 0o777 == 0o600 else {
            let actual = UInt16(value.st_mode & 0o777)
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.documentPermissionsUnsafe(actual: actual)
        }
        guard value.st_uid == geteuid() else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.documentOwnerMismatch
        }
        guard value.st_nlink == 1 else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.documentHasUnexpectedLinks
        }
        guard value.st_size >= 0, value.st_size <= off_t(maximumBytes) else {
            close(fileDescriptor)
            throw AuthoritativeMarkdownError.contentTooLarge(maximumBytes: maximumBytes)
        }
        return OpenedFile(
            fileDescriptor: fileDescriptor,
            identity: AuthoritativeMarkdownFileIdentity(value),
            size: Int(value.st_size)
        )
    }

    private func readAll(from fileDescriptor: Int32, expectedSize: Int) throws -> Data {
        guard lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
            throw AuthoritativeMarkdownError.documentIdentityChanged
        }
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AuthoritativeMarkdownError.documentIdentityChanged
            }
            guard result.count <= maximumBytes - count else {
                throw AuthoritativeMarkdownError.contentTooLarge(maximumBytes: maximumBytes)
            }
            result.append(contentsOf: buffer[0..<count])
        }
        guard result.count == expectedSize else {
            throw AuthoritativeMarkdownError.documentIdentityChanged
        }
        return result
    }

    private func requirePathIdentity(
        _ expected: AuthoritativeMarkdownFileIdentity,
        named name: String,
        beneath parentFD: Int32
    ) throws {
        var value = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              value.st_mode & S_IFMT == S_IFREG,
              AuthoritativeMarkdownFileIdentity(value) == expected
        else {
            throw AuthoritativeMarkdownError.documentIdentityChanged
        }
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw AuthoritativeMarkdownError.stagingWriteFailed(code: errno)
                }
                guard result > 0 else {
                    throw AuthoritativeMarkdownError.stagingWriteFailed(code: EIO)
                }
                written += result
            }
        }
    }

    private func openDirectoryChainNoFollow(_ url: URL) throws -> Int32 {
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else { throw AuthoritativeMarkdownError.rootUnavailable }
        for component in FileURLNormalization.lexical(url).pathComponents.dropFirst() {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextFD >= 0 else {
                close(currentFD)
                throw AuthoritativeMarkdownError.rootUnavailable
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private struct OpenedFile {
        let fileDescriptor: Int32
        let identity: AuthoritativeMarkdownFileIdentity
        let size: Int
    }
}
