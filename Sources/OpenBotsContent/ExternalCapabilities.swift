import Darwin
import Foundation
import OpenBotsDomain

public enum LocationCapabilityHolder: Hashable, Sendable {
    case application
    case teammate(TeammateID)
}

public struct ExternalReadCapability: Hashable, Sendable {
    public let id: CapabilityGrantID
    public let holder: LocationCapabilityHolder
    public let canonicalRoot: URL
    public let recursive: Bool
    public let locationObservation: LocationObservation

    public static func grant(
        id: CapabilityGrantID,
        holder: LocationCapabilityHolder,
        selectedRoot: URL,
        recursive: Bool,
        locationChecker: any LocationEnvironmentChecking
    ) throws -> ExternalReadCapability {
        let root = try PathSafety().canonicalExistingDirectory(selectedRoot)
        return ExternalReadCapability(
            id: id,
            holder: holder,
            canonicalRoot: root.url,
            recursive: recursive,
            locationObservation: try locationChecker.observation(for: root.url)
        )
    }

    private init(
        id: CapabilityGrantID,
        holder: LocationCapabilityHolder,
        canonicalRoot: URL,
        recursive: Bool,
        locationObservation: LocationObservation
    ) {
        self.id = id
        self.holder = holder
        self.canonicalRoot = canonicalRoot
        self.recursive = recursive
        self.locationObservation = locationObservation
    }
}

public struct ExternalCreateNewCapability: Hashable, Sendable {
    public let id: CapabilityGrantID
    public let holder: LocationCapabilityHolder
    public let exactTarget: URL
    public let canonicalParent: URL
    public let parentIdentity: CanonicalFileIdentity
    public let locationObservation: LocationObservation
    public let expectedByteCount: Int

    /// Creates a one-shot capability for the exact file selected by the user. This
    /// conveys no overwrite, rename, move, metadata, cleanup, or deletion authority.
    public static func grant(
        id: CapabilityGrantID,
        holder: LocationCapabilityHolder,
        exactSelectedTarget: URL,
        expectedByteCount: Int,
        locationChecker: any LocationEnvironmentChecking
    ) throws -> ExternalCreateNewCapability {
        guard expectedByteCount >= 0 else { throw ExternalCreateNewError.invalidTarget }
        let safety = PathSafety()
        let parent = try safety.canonicalExistingDirectory(exactSelectedTarget.deletingLastPathComponent())
        let target = try safety.exclusiveFutureChild(
            named: exactSelectedTarget.lastPathComponent,
            of: parent
        )
        guard let identity = parent.identity else { throw PathSafetyError.rootDoesNotExist }
        return ExternalCreateNewCapability(
            id: id,
            holder: holder,
            exactTarget: target,
            canonicalParent: parent.url,
            parentIdentity: identity,
            locationObservation: try locationChecker.observation(for: parent.url),
            expectedByteCount: expectedByteCount
        )
    }

    private init(
        id: CapabilityGrantID,
        holder: LocationCapabilityHolder,
        exactTarget: URL,
        canonicalParent: URL,
        parentIdentity: CanonicalFileIdentity,
        locationObservation: LocationObservation,
        expectedByteCount: Int
    ) {
        self.id = id
        self.holder = holder
        self.exactTarget = exactTarget
        self.canonicalParent = canonicalParent
        self.parentIdentity = parentIdentity
        self.locationObservation = locationObservation
        self.expectedByteCount = expectedByteCount
    }
}

public struct ExternalCreateNewPlan: Hashable, Sendable {
    public let capabilityID: CapabilityGrantID
    public let holder: LocationCapabilityHolder
    public let exactTarget: URL
    public let canonicalParent: URL
    public let parentIdentity: CanonicalFileIdentity
    public let frozenLocationObservation: LocationObservation
    public let finalComponent: String
    public let expectedByteCount: Int

    public init(capability: ExternalCreateNewCapability) {
        capabilityID = capability.id
        holder = capability.holder
        exactTarget = capability.exactTarget
        canonicalParent = capability.canonicalParent
        parentIdentity = capability.parentIdentity
        frozenLocationObservation = capability.locationObservation
        finalComponent = capability.exactTarget.lastPathComponent
        expectedByteCount = capability.expectedByteCount
    }
}

public enum ExternalCreateNewError: Error, Equatable, Sendable {
    case locationChanged
    case parentChanged
    case collision
    case invalidTarget
    case byteCountMismatch(expected: Int, actual: Int)
    case openFailed(code: Int32)
    case permissionsFailed(code: Int32)
    case writeFailed(code: Int32)
    case synchronizeFailed(code: Int32)
}

public struct ExternalCreateNewReceipt: Hashable, Sendable {
    public let capabilityID: CapabilityGrantID
    public let exactTarget: URL
    public let byteCount: Int
}

/// Executes one bounded, exclusive write directly to the exact final pathname.
/// On interruption or failure it deliberately does not delete or replace the path.
public struct ExternalCreateNewWriter: Sendable {
    private let locationChecker: any LocationEnvironmentChecking

    public init(locationChecker: any LocationEnvironmentChecking) {
        self.locationChecker = locationChecker
    }

    public func write(_ data: Data, using plan: ExternalCreateNewPlan) throws -> ExternalCreateNewReceipt {
        guard plan.exactTarget.deletingLastPathComponent() == plan.canonicalParent,
              plan.finalComponent == plan.exactTarget.lastPathComponent,
              !plan.finalComponent.isEmpty,
              plan.finalComponent != ".",
              plan.finalComponent != "..",
              !plan.finalComponent.contains("/")
        else {
            throw ExternalCreateNewError.invalidTarget
        }
        guard data.count == plan.expectedByteCount else {
            throw ExternalCreateNewError.byteCountMismatch(
                expected: plan.expectedByteCount,
                actual: data.count
            )
        }
        let currentObservation = try locationChecker.observation(for: plan.canonicalParent)
        guard currentObservation == plan.frozenLocationObservation else {
            throw ExternalCreateNewError.locationChanged
        }

        let parentFD = try openDirectoryWithoutFollowingSymlinks(plan.canonicalParent)
        defer { close(parentFD) }

        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0,
              CanonicalFileIdentity(stat: parentStat) == plan.parentIdentity
        else {
            throw ExternalCreateNewError.parentChanged
        }

        let fileFD = plan.finalComponent.withCString {
            openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard fileFD >= 0 else {
            if errno == EEXIST { throw ExternalCreateNewError.collision }
            throw ExternalCreateNewError.openFailed(code: errno)
        }
        defer { close(fileFD) }
        guard fchmod(fileFD, S_IRUSR | S_IWUSR) == 0 else {
            throw ExternalCreateNewError.permissionsFailed(code: errno)
        }

        var written = 0
        while written < data.count {
            let result: Int = data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(fileFD, baseAddress.advanced(by: written), data.count - written)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw ExternalCreateNewError.writeFailed(code: errno)
            }
            if result == 0 { throw ExternalCreateNewError.writeFailed(code: EIO) }
            written += result
        }
        guard fsync(fileFD) == 0 else {
            throw ExternalCreateNewError.synchronizeFailed(code: errno)
        }
        guard fsync(parentFD) == 0 else {
            throw ExternalCreateNewError.synchronizeFailed(code: errno)
        }
        return ExternalCreateNewReceipt(
            capabilityID: plan.capabilityID,
            exactTarget: plan.exactTarget,
            byteCount: written
        )
    }

    private func openDirectoryWithoutFollowingSymlinks(_ url: URL) throws -> Int32 {
        var currentFD = open("/", O_RDONLY | O_DIRECTORY)
        guard currentFD >= 0 else { throw ExternalCreateNewError.openFailed(code: errno) }
        for component in FileURLNormalization.lexical(url).pathComponents.dropFirst() {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            if nextFD < 0 {
                let code = errno
                close(currentFD)
                throw ExternalCreateNewError.openFailed(code: code)
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }
}
