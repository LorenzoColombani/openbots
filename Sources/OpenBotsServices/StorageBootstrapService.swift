import Darwin
import Foundation
import OpenBotsContent

public enum StorageBootstrapError: Error, Equatable, Sendable {
    case invalidPlan
    case locationInspectionFailed(kind: OwnedRootKind, reason: String)
    case unsafeHighChurnLocation(kind: OwnedRootKind, violation: HighChurnLocationViolation)
    case filesystemPreflightFailed(kind: OwnedRootKind, reason: String)
    case stagingFailed(kind: OwnedRootKind, reason: String)
    case publicationFailed(failedKind: OwnedRootKind, publishedRoots: [URL], reason: String)
    case verificationFailed(kind: OwnedRootKind, reason: String)
}

public struct StorageBootstrapReceipt: Hashable, Sendable {
    public let installationID: UUID
    public let verifiedRoots: [VerifiedOwnedRoot]

    public init(installationID: UUID, verifiedRoots: [VerifiedOwnedRoot]) {
        self.installationID = installationID
        self.verifiedRoots = verifiedRoots
    }
}

public struct StorageRootEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case directory(mode: UInt16)
        case exclusiveFile(data: Data, mode: UInt16)
    }

    public let relativeComponents: [String]
    public let kind: Kind

    init(relativeComponents: [String], kind: Kind) {
        self.relativeComponents = relativeComponents
        self.kind = kind
    }
}

public struct StorageRootSpecification: Hashable, Sendable {
    public let descriptor: OwnedRootDescriptor
    public let rootMode: UInt16
    public let entries: [StorageRootEntry]

    init(descriptor: OwnedRootDescriptor, rootMode: UInt16, entries: [StorageRootEntry]) {
        self.descriptor = descriptor
        self.rootMode = rootMode
        self.entries = entries
    }
}

struct StorageFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }
}

public struct StagedStorageRoot: Hashable, Sendable {
    public let kind: OwnedRootKind
    public let finalRoot: URL
    public let stagingRoot: URL

    let parentIdentity: StorageFileIdentity
    let stagingIdentity: StorageFileIdentity

    init(
        kind: OwnedRootKind,
        finalRoot: URL,
        stagingRoot: URL,
        parentIdentity: StorageFileIdentity,
        stagingIdentity: StorageFileIdentity
    ) {
        self.kind = kind
        self.finalRoot = finalRoot
        self.stagingRoot = stagingRoot
        self.parentIdentity = parentIdentity
        self.stagingIdentity = stagingIdentity
    }
}

public protocol StorageBootstrapFileSystem: Sendable {
    /// Performs a no-symlink, writable-parent and destination-absence check.
    /// This method must not create or mutate filesystem content.
    func preflight(_ specification: StorageRootSpecification) throws

    /// Builds the complete root in a new same-parent staging directory.
    func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot

    /// Publishes one complete root without replacing or merging an existing item.
    func publish(_ stagedRoot: StagedStorageRoot) throws

    /// Removes only an unpublished staging directory whose captured identity still matches.
    func discard(_ stagedRoot: StagedStorageRoot) throws
}

public enum StorageBootstrapFileSystemError: Error, Equatable, Sendable {
    case invalidPath
    case parentNotWritable
    case destinationAlreadyExists
    case identityChanged
    case unsupportedItem
    case posixFailure(operation: String, code: Int32)
}

/// First-launch creation of app-owned internal roots only. Visible content and
/// Claude's authenticated profile have separate, explicit workflows and cannot
/// be introduced through this API.
public actor StorageBootstrapService {
    private let layout: PreviewStorageLayout
    private let locationAdmission: any MacOSLocationAdmissionChecking
    private let fileSystem: any StorageBootstrapFileSystem
    private let locationValidator = HighChurnLocationValidator()

    public init(
        layout: PreviewStorageLayout,
        locationAdmission: (any MacOSLocationAdmissionChecking)? = nil,
        fileSystem: any StorageBootstrapFileSystem = POSIXStorageBootstrapFileSystem()
    ) {
        self.layout = layout
        self.locationAdmission = locationAdmission
            ?? PreviewAppOwnedLocationAdmission(layout: layout)
        self.fileSystem = fileSystem
    }

    public func bootstrap(using plan: PreviewRootCreationPlan) async throws -> StorageBootstrapReceipt {
        let specifications = try specifications(for: plan)

        // Every location and every destination is checked before the first write.
        for specification in specifications {
            let boundary = highChurnBoundary(for: specification.descriptor.kind)
            let observation: LocationObservation
            do {
                observation = try await locationAdmission.observation(for: boundary)
            } catch {
                throw StorageBootstrapError.locationInspectionFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
            do {
                try locationValidator.validate(boundary, observation: observation)
            } catch let violation as HighChurnLocationViolation {
                throw StorageBootstrapError.unsafeHighChurnLocation(
                    kind: specification.descriptor.kind,
                    violation: violation
                )
            } catch {
                throw StorageBootstrapError.locationInspectionFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        for specification in specifications {
            do {
                try fileSystem.preflight(specification)
            } catch {
                throw StorageBootstrapError.filesystemPreflightFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        // Stage all roots before publishing any root. A staging failure therefore
        // leaves no partial live hierarchy and cleanup is limited to our own tokens.
        var stagedRoots: [StagedStorageRoot] = []
        do {
            for specification in specifications {
                stagedRoots.append(try fileSystem.stage(specification))
            }
        } catch {
            for stagedRoot in stagedRoots.reversed() {
                try? fileSystem.discard(stagedRoot)
            }
            let failedKind = specifications[stagedRoots.count].descriptor.kind
            throw StorageBootstrapError.stagingFailed(
                kind: failedKind,
                reason: Self.errorSummary(error)
            )
        }

        var publishedRoots: [URL] = []
        for (index, stagedRoot) in stagedRoots.enumerated() {
            do {
                try fileSystem.publish(stagedRoot)
                publishedRoots.append(stagedRoot.finalRoot)
            } catch {
                for unpublished in stagedRoots[index...].reversed() {
                    try? fileSystem.discard(unpublished)
                }
                // Published app-owned roots are deliberately not deleted here. A
                // later recovery flow can verify their markers before any cleanup.
                throw StorageBootstrapError.publicationFailed(
                    failedKind: stagedRoot.kind,
                    publishedRoots: publishedRoots,
                    reason: Self.errorSummary(error)
                )
            }
        }

        let verifier = OwnedRootVerifier()
        var verifiedRoots: [VerifiedOwnedRoot] = []
        for specification in specifications {
            guard let rootID = plan.rootIDs[specification.descriptor.kind] else {
                throw StorageBootstrapError.invalidPlan
            }
            do {
                verifiedRoots.append(
                    try verifier.verify(
                        specification.descriptor,
                        expectedInstallationID: plan.installationID,
                        expectedRootID: rootID
                    )
                )
            } catch {
                throw StorageBootstrapError.verificationFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }
        return StorageBootstrapReceipt(
            installationID: plan.installationID,
            verifiedRoots: verifiedRoots
        )
    }

    /// Recovers only missing disposable roots for an installation whose fixed
    /// identities were reconstructed from its immutable installation receipt.
    /// Application Support is authority, not disposable state, and is therefore
    /// always required to exist and verify before this operation can write.
    public func recoverMissingDisposableRoots(
        using plan: PreviewRootCreationPlan
    ) async throws -> StorageBootstrapReceipt {
        let specifications = try specifications(for: plan)
        let verifier = OwnedRootVerifier()
        var missingSpecifications: [StorageRootSpecification] = []

        // Inspect every existing root before the first write. Only a genuinely
        // absent cache or temporary root is recoverable; every other verifier
        // result is an integrity failure and is left untouched.
        for specification in specifications {
            guard let rootID = plan.rootIDs[specification.descriptor.kind] else {
                throw StorageBootstrapError.invalidPlan
            }
            do {
                _ = try verifier.verify(
                    specification.descriptor,
                    expectedInstallationID: plan.installationID,
                    expectedRootID: rootID
                )
            } catch let error as OwnedRootError {
                if error == .rootMissing,
                   specification.descriptor.kind == .caches
                    || specification.descriptor.kind == .temporary
                {
                    missingSpecifications.append(specification)
                    continue
                }
                throw StorageBootstrapError.verificationFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            } catch {
                throw StorageBootstrapError.verificationFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        // Admission remains a gate for all high-churn authority, including an
        // installation whose disposable roots happen to need no recovery.
        for specification in specifications {
            let boundary = highChurnBoundary(for: specification.descriptor.kind)
            let observation: LocationObservation
            do {
                observation = try await locationAdmission.observation(for: boundary)
            } catch {
                throw StorageBootstrapError.locationInspectionFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
            do {
                try locationValidator.validate(boundary, observation: observation)
            } catch let violation as HighChurnLocationViolation {
                throw StorageBootstrapError.unsafeHighChurnLocation(
                    kind: specification.descriptor.kind,
                    violation: violation
                )
            } catch {
                throw StorageBootstrapError.locationInspectionFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        // Every absent destination receives the same no-follow preflight before
        // any staging directory is created.
        for specification in missingSpecifications {
            do {
                try fileSystem.preflight(specification)
            } catch {
                throw StorageBootstrapError.filesystemPreflightFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        var stagedRoots: [StagedStorageRoot] = []
        do {
            for specification in missingSpecifications {
                stagedRoots.append(try fileSystem.stage(specification))
            }
        } catch {
            for stagedRoot in stagedRoots.reversed() {
                try? fileSystem.discard(stagedRoot)
            }
            let failedKind = missingSpecifications[stagedRoots.count].descriptor.kind
            throw StorageBootstrapError.stagingFailed(
                kind: failedKind,
                reason: Self.errorSummary(error)
            )
        }

        var publishedRoots: [URL] = []
        for (index, stagedRoot) in stagedRoots.enumerated() {
            do {
                try fileSystem.publish(stagedRoot)
                publishedRoots.append(stagedRoot.finalRoot)
            } catch {
                for unpublished in stagedRoots[index...].reversed() {
                    try? fileSystem.discard(unpublished)
                }
                // Never roll back a published, marker-owned root. Its stable
                // evidence makes a later retry safe and reviewable.
                throw StorageBootstrapError.publicationFailed(
                    failedKind: stagedRoot.kind,
                    publishedRoots: publishedRoots,
                    reason: Self.errorSummary(error)
                )
            }
        }

        // Reverify all three roots after publication so races or identity drift
        // fail closed while leaving any published evidence intact.
        var verifiedRoots: [VerifiedOwnedRoot] = []
        for specification in specifications {
            guard let rootID = plan.rootIDs[specification.descriptor.kind] else {
                throw StorageBootstrapError.invalidPlan
            }
            do {
                verifiedRoots.append(
                    try verifier.verify(
                        specification.descriptor,
                        expectedInstallationID: plan.installationID,
                        expectedRootID: rootID
                    )
                )
            } catch {
                throw StorageBootstrapError.verificationFailed(
                    kind: specification.descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }

        return StorageBootstrapReceipt(
            installationID: plan.installationID,
            verifiedRoots: verifiedRoots
        )
    }

    private func specifications(for plan: PreviewRootCreationPlan) throws -> [StorageRootSpecification] {
        let expected = try PreviewRootCreationPlan(
            layout: layout,
            installationID: plan.installationID,
            rootIDs: plan.rootIDs
        )
        guard expected.steps == plan.steps else { throw StorageBootstrapError.invalidPlan }

        let descriptors = [
            layout.applicationSupportRoot,
            layout.cacheRoot,
            layout.temporaryRoot
        ]
        return try descriptors.map { descriptor in
            guard let rootStep = plan.steps.first(where: { $0.url == descriptor.url }),
                  case let .exclusiveRootDirectory(mode) = rootStep.kind
            else {
                throw StorageBootstrapError.invalidPlan
            }

            let rootComponents = ServiceFileURLNormalization.lexical(descriptor.url).pathComponents
            let entries = try plan.steps.compactMap { step -> StorageRootEntry? in
                let stepComponents = ServiceFileURLNormalization.lexical(step.url).pathComponents
                guard step.url != descriptor.url,
                      stepComponents.count > rootComponents.count,
                      Array(stepComponents.prefix(rootComponents.count)) == rootComponents
                else {
                    return nil
                }
                let relative = Array(stepComponents.dropFirst(rootComponents.count))
                switch step.kind {
                case let .ownedChildDirectory(mode):
                    return StorageRootEntry(relativeComponents: relative, kind: .directory(mode: mode))
                case let .exclusiveOwnershipMarker(data, mode):
                    return StorageRootEntry(
                        relativeComponents: relative,
                        kind: .exclusiveFile(data: data, mode: mode)
                    )
                case .exclusiveRootDirectory:
                    throw StorageBootstrapError.invalidPlan
                }
            }
            return StorageRootSpecification(
                descriptor: descriptor,
                rootMode: mode,
                entries: entries
            )
        }
    }

    private func highChurnBoundary(for kind: OwnedRootKind) -> URL {
        switch kind {
        case .applicationSupport:
            layout.highChurnRoot
        case .caches:
            layout.cacheRoot.url
        case .temporary:
            layout.temporaryRoot.url
        case .visibleContent:
            // The plan validator makes this unreachable.
            layout.visibleWorkingRoot
        }
    }

    private static func errorSummary(_ error: any Error) -> String {
        if let error = error as? StorageBootstrapFileSystemError {
            return String(describing: error)
        }
        if let error = error as? OwnedRootError {
            return String(describing: error)
        }
        return String(reflecting: type(of: error))
    }
}

public struct POSIXStorageBootstrapFileSystem: StorageBootstrapFileSystem {
    private static let stagingPrefix = ".openbots-bootstrap-"
    private static let stagingSuffix = ".noindex"

    public init() {}

    public func preflight(_ specification: StorageRootSpecification) throws {
        let finalRoot = ServiceFileURLNormalization.lexical(specification.descriptor.url)
        let finalName = try safeFinalComponent(of: finalRoot)
        let parentFD = try openDirectoryWithoutFollowingSymlinks(finalRoot.deletingLastPathComponent())
        defer { close(parentFD) }

        let writable = ".".withCString {
            faccessat(parentFD, $0, W_OK | X_OK, AT_EACCESS)
        }
        guard writable == 0 else { throw StorageBootstrapFileSystemError.parentNotWritable }

        var value = stat()
        let result = finalName.withCString {
            fstatat(parentFD, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { throw StorageBootstrapFileSystemError.destinationAlreadyExists }
        guard errno == ENOENT else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fstatat", code: errno)
        }
    }

    public func stage(_ specification: StorageRootSpecification) throws -> StagedStorageRoot {
        let finalRoot = ServiceFileURLNormalization.lexical(specification.descriptor.url)
        _ = try safeFinalComponent(of: finalRoot)
        let parentURL = finalRoot.deletingLastPathComponent()
        let parentFD = try openDirectoryWithoutFollowingSymlinks(parentURL)
        defer { close(parentFD) }

        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fstat", code: errno)
        }

        let stagingName = Self.stagingPrefix + UUID().uuidString.lowercased() + Self.stagingSuffix
        let created = stagingName.withCString {
            mkdirat(parentFD, $0, mode_t(specification.rootMode))
        }
        guard created == 0 else {
            if errno == EEXIST { throw StorageBootstrapFileSystemError.destinationAlreadyExists }
            throw StorageBootstrapFileSystemError.posixFailure(operation: "mkdirat", code: errno)
        }

        let stagingURL = parentURL.appending(path: stagingName, directoryHint: .isDirectory)
        let stagingFD: Int32
        do {
            stagingFD = try openChildDirectory(named: stagingName, beneath: parentFD)
        } catch {
            _ = stagingName.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            throw error
        }

        var stagingStat = stat()
        guard fstat(stagingFD, &stagingStat) == 0 else {
            let code = errno
            close(stagingFD)
            _ = stagingName.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fstat", code: code)
        }
        let staged = StagedStorageRoot(
            kind: specification.descriptor.kind,
            finalRoot: finalRoot,
            stagingRoot: stagingURL,
            parentIdentity: StorageFileIdentity(parentStat),
            stagingIdentity: StorageFileIdentity(stagingStat)
        )

        do {
            guard fchmod(stagingFD, mode_t(specification.rootMode)) == 0 else {
                throw StorageBootstrapFileSystemError.posixFailure(operation: "fchmod", code: errno)
            }
            for entry in specification.entries {
                try materialize(entry, beneath: stagingFD)
            }
            guard fsync(stagingFD) == 0 else {
                throw StorageBootstrapFileSystemError.posixFailure(operation: "fsync", code: errno)
            }
            close(stagingFD)
            return staged
        } catch {
            close(stagingFD)
            try? discard(staged)
            throw error
        }
    }

    public func publish(_ stagedRoot: StagedStorageRoot) throws {
        try validateStagingToken(stagedRoot)
        let parentURL = stagedRoot.finalRoot.deletingLastPathComponent()
        guard parentURL == stagedRoot.stagingRoot.deletingLastPathComponent() else {
            throw StorageBootstrapFileSystemError.invalidPath
        }
        let parentFD = try openDirectoryWithoutFollowingSymlinks(parentURL)
        defer { close(parentFD) }
        try requireIdentity(stagedRoot.parentIdentity, of: parentFD)

        let stagingFD = try openChildDirectory(named: stagedRoot.stagingRoot.lastPathComponent, beneath: parentFD)
        defer { close(stagingFD) }
        try requireIdentity(stagedRoot.stagingIdentity, of: stagingFD)

        let result = stagedRoot.stagingRoot.lastPathComponent.withCString { stagingName in
            stagedRoot.finalRoot.lastPathComponent.withCString { finalName in
                renameatx_np(parentFD, stagingName, parentFD, finalName, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw StorageBootstrapFileSystemError.destinationAlreadyExists }
            throw StorageBootstrapFileSystemError.posixFailure(operation: "renameatx_np", code: errno)
        }
        guard fsync(parentFD) == 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fsync", code: errno)
        }
    }

    public func discard(_ stagedRoot: StagedStorageRoot) throws {
        try validateStagingToken(stagedRoot)
        let parentURL = stagedRoot.stagingRoot.deletingLastPathComponent()
        guard parentURL == stagedRoot.finalRoot.deletingLastPathComponent() else {
            throw StorageBootstrapFileSystemError.invalidPath
        }
        let parentFD = try openDirectoryWithoutFollowingSymlinks(parentURL)
        defer { close(parentFD) }
        try requireIdentity(stagedRoot.parentIdentity, of: parentFD)

        let stagingName = stagedRoot.stagingRoot.lastPathComponent
        let stagingFD: Int32
        do {
            stagingFD = try openChildDirectory(named: stagingName, beneath: parentFD)
        } catch let error as StorageBootstrapFileSystemError {
            if case let .posixFailure(_, code) = error, code == ENOENT { return }
            throw error
        }
        do {
            try requireIdentity(stagedRoot.stagingIdentity, of: stagingFD)
            try removeContentsWithoutFollowingSymlinks(directoryFD: stagingFD)
            close(stagingFD)
        } catch {
            close(stagingFD)
            throw error
        }

        let removed = stagingName.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
        guard removed == 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "unlinkat", code: errno)
        }
        _ = fsync(parentFD)
    }

    private func materialize(_ entry: StorageRootEntry, beneath rootFD: Int32) throws {
        guard !entry.relativeComponents.isEmpty,
              entry.relativeComponents.allSatisfy(Self.isSafeComponent)
        else {
            throw StorageBootstrapFileSystemError.invalidPath
        }
        let parentFD = try openExistingParent(
            components: Array(entry.relativeComponents.dropLast()),
            beneath: rootFD
        )
        defer { close(parentFD) }
        let name = entry.relativeComponents.last!

        switch entry.kind {
        case let .directory(mode):
            let result = name.withCString { mkdirat(parentFD, $0, mode_t(mode)) }
            guard result == 0 else {
                if errno == EEXIST { throw StorageBootstrapFileSystemError.destinationAlreadyExists }
                throw StorageBootstrapFileSystemError.posixFailure(operation: "mkdirat", code: errno)
            }
            let directoryFD = try openChildDirectory(named: name, beneath: parentFD)
            defer { close(directoryFD) }
            guard fchmod(directoryFD, mode_t(mode)) == 0 else {
                throw StorageBootstrapFileSystemError.posixFailure(operation: "fchmod", code: errno)
            }
            _ = fsync(directoryFD)

        case let .exclusiveFile(data, mode):
            let fileFD = name.withCString {
                openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
            }
            guard fileFD >= 0 else {
                if errno == EEXIST { throw StorageBootstrapFileSystemError.destinationAlreadyExists }
                throw StorageBootstrapFileSystemError.posixFailure(operation: "openat", code: errno)
            }
            do {
                guard fchmod(fileFD, mode_t(mode)) == 0 else {
                    throw StorageBootstrapFileSystemError.posixFailure(operation: "fchmod", code: errno)
                }
                try writeAll(data, to: fileFD)
                guard fsync(fileFD) == 0 else {
                    throw StorageBootstrapFileSystemError.posixFailure(operation: "fsync", code: errno)
                }
                close(fileFD)
            } catch {
                close(fileFD)
                throw error
            }
        }
    }

    private func openExistingParent(components: [String], beneath rootFD: Int32) throws -> Int32 {
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "dup", code: errno)
        }
        do {
            for component in components {
                guard Self.isSafeComponent(component) else {
                    throw StorageBootstrapFileSystemError.invalidPath
                }
                let nextFD = try openChildDirectory(named: component, beneath: currentFD)
                close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            close(currentFD)
            throw error
        }
    }

    private func openDirectoryWithoutFollowingSymlinks(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw StorageBootstrapFileSystemError.invalidPath }
        let components = ServiceFileURLNormalization.lexical(url).pathComponents.dropFirst()
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard currentFD >= 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "open", code: errno)
        }
        do {
            for component in components {
                guard Self.isSafeComponent(component) else {
                    throw StorageBootstrapFileSystemError.invalidPath
                }
                let nextFD = try openChildDirectory(named: component, beneath: currentFD)
                close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            close(currentFD)
            throw error
        }
    }

    private func openChildDirectory(named name: String, beneath parentFD: Int32) throws -> Int32 {
        guard Self.isSafeComponent(name) else { throw StorageBootstrapFileSystemError.invalidPath }
        let childFD = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard childFD >= 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "openat-directory-\(name)", code: errno)
        }
        return childFD
    }

    private func safeFinalComponent(of url: URL) throws -> String {
        let name = url.lastPathComponent
        guard Self.isSafeComponent(name), url.deletingLastPathComponent() != url else {
            throw StorageBootstrapFileSystemError.invalidPath
        }
        return name
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private func requireIdentity(_ expected: StorageFileIdentity, of descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fstat", code: errno)
        }
        guard StorageFileIdentity(value) == expected else {
            throw StorageBootstrapFileSystemError.identityChanged
        }
    }

    private func validateStagingToken(_ stagedRoot: StagedStorageRoot) throws {
        let name = stagedRoot.stagingRoot.lastPathComponent
        guard name.hasPrefix(Self.stagingPrefix), name.hasSuffix(Self.stagingSuffix) else {
            throw StorageBootstrapFileSystemError.invalidPath
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result: Int = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw StorageBootstrapFileSystemError.posixFailure(operation: "write", code: errno)
            }
            guard result > 0 else {
                throw StorageBootstrapFileSystemError.posixFailure(operation: "write", code: EIO)
            }
            offset += result
        }
    }

    private func removeContentsWithoutFollowingSymlinks(directoryFD: Int32) throws {
        let iterationFD = dup(directoryFD)
        guard iterationFD >= 0 else {
            throw StorageBootstrapFileSystemError.posixFailure(operation: "dup", code: errno)
        }
        guard let stream = fdopendir(iterationFD) else {
            let code = errno
            close(iterationFD)
            throw StorageBootstrapFileSystemError.posixFailure(operation: "fdopendir", code: code)
        }
        defer { closedir(stream) }

        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard Self.isSafeComponent(name) else {
                throw StorageBootstrapFileSystemError.invalidPath
            }

            var value = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &value, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                throw StorageBootstrapFileSystemError.posixFailure(operation: "fstatat", code: errno)
            }
            if value.st_mode & S_IFMT == S_IFDIR {
                let childFD = try openChildDirectory(named: name, beneath: directoryFD)
                do {
                    try removeContentsWithoutFollowingSymlinks(directoryFD: childFD)
                    close(childFD)
                } catch {
                    close(childFD)
                    throw error
                }
                let result = name.withCString { unlinkat(directoryFD, $0, AT_REMOVEDIR) }
                guard result == 0 else {
                    throw StorageBootstrapFileSystemError.posixFailure(operation: "unlinkat", code: errno)
                }
            } else {
                let result = name.withCString { unlinkat(directoryFD, $0, 0) }
                guard result == 0 else {
                    throw StorageBootstrapFileSystemError.posixFailure(operation: "unlinkat", code: errno)
                }
            }
        }
    }
}
