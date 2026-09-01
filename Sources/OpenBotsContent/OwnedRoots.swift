import Darwin
import Foundation

public struct OwnedRootMarker: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let bundleIdentifier: String
    public let installationID: UUID
    public let rootID: UUID
    public let kind: OwnedRootKind

    public init(installationID: UUID, rootID: UUID, kind: OwnedRootKind) {
        formatVersion = Self.currentFormatVersion
        bundleIdentifier = OpenBotsPreviewIdentity.bundleIdentifier
        self.installationID = installationID
        self.rootID = rootID
        self.kind = kind
    }
}

public struct RootCreationStep: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case exclusiveRootDirectory(mode: UInt16)
        case ownedChildDirectory(mode: UInt16)
        case exclusiveOwnershipMarker(data: Data, mode: UInt16)
    }

    public let url: URL
    public let kind: Kind
}

/// A reviewable, side-effect-free description of the exact initial filesystem writes.
/// An application service executes it only after location validation.
public struct PreviewRootCreationPlan: Sendable {
    public let installationID: UUID
    public let rootIDs: [OwnedRootKind: UUID]
    public let steps: [RootCreationStep]

    public init(
        layout: PreviewStorageLayout,
        installationID: UUID,
        rootIDs: [OwnedRootKind: UUID]
    ) throws {
        let internalKinds: Set<OwnedRootKind> = [.applicationSupport, .caches, .temporary]
        guard Set(rootIDs.keys) == internalKinds else {
            throw OwnedRootError.incompleteRootIdentitySet
        }
        self.installationID = installationID
        self.rootIDs = rootIDs

        let roots = [
            layout.applicationSupportRoot,
            layout.cacheRoot,
            layout.temporaryRoot
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var generated: [RootCreationStep] = []
        for root in roots {
            generated.append(
                RootCreationStep(url: root.url, kind: .exclusiveRootDirectory(mode: 0o700))
            )
            let marker = OwnedRootMarker(
                installationID: installationID,
                rootID: rootIDs[root.kind]!,
                kind: root.kind
            )
            generated.append(
                RootCreationStep(
                    url: root.ownershipMarkerURL,
                    kind: .exclusiveOwnershipMarker(data: try encoder.encode(marker), mode: 0o600)
                )
            )
        }
        generated.append(contentsOf: layout.internalRequiredDirectoryURLs.map {
            RootCreationStep(url: $0, kind: .ownedChildDirectory(mode: 0o700))
        })
        steps = generated
    }
}

public struct SelectedVisibleContentRoot: Hashable, Sendable {
    public let selectionID: UUID
    public let descriptor: OwnedRootDescriptor
    public let locationObservation: LocationObservation

    /// Represents an explicit user selection after the exact visible location was
    /// shown. The high-churn child must independently pass the local/provider/.noindex gate.
    public static func validate(
        selectionID: UUID,
        layout: PreviewStorageLayout,
        locationChecker: any LocationEnvironmentChecking
    ) throws -> SelectedVisibleContentRoot {
        let parent = try PathSafety().canonicalExistingDirectory(layout.contentRoot.url.deletingLastPathComponent())
        _ = try PathSafety().exclusiveFutureChild(
            named: layout.contentRoot.url.lastPathComponent,
            of: parent
        )
        let observation = try locationChecker.observation(for: parent.url)
        try HighChurnLocationValidator().validate(
            layout.visibleWorkingRoot,
            observation: observation
        )
        return SelectedVisibleContentRoot(
            selectionID: selectionID,
            descriptor: layout.contentRoot,
            locationObservation: observation
        )
    }

    private init(
        selectionID: UUID,
        descriptor: OwnedRootDescriptor,
        locationObservation: LocationObservation
    ) {
        self.selectionID = selectionID
        self.descriptor = descriptor
        self.locationObservation = locationObservation
    }
}

public struct PreviewVisibleContentRootCreationPlan: Sendable {
    public let selection: SelectedVisibleContentRoot
    public let installationID: UUID
    public let rootID: UUID
    public let steps: [RootCreationStep]

    public init(
        selection: SelectedVisibleContentRoot,
        layout: PreviewStorageLayout,
        installationID: UUID,
        rootID: UUID
    ) throws {
        guard selection.descriptor == layout.contentRoot else {
            throw OwnedRootError.visibleSelectionMismatch
        }
        self.selection = selection
        self.installationID = installationID
        self.rootID = rootID
        let marker = OwnedRootMarker(
            installationID: installationID,
            rootID: rootID,
            kind: .visibleContent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        steps = [
            RootCreationStep(
                url: layout.contentRoot.url,
                kind: .exclusiveRootDirectory(mode: 0o700)
            ),
            RootCreationStep(
                url: layout.contentRoot.ownershipMarkerURL,
                kind: .exclusiveOwnershipMarker(data: try encoder.encode(marker), mode: 0o600)
            )
        ] + layout.visibleContentRequiredDirectoryURLs.map {
            RootCreationStep(url: $0, kind: .ownedChildDirectory(mode: 0o700))
        }
    }
}

public enum OwnedRootError: Error, Equatable, Sendable {
    case incompleteRootIdentitySet
    case visibleSelectionMismatch
    case rootMissing
    case rootTypeMismatch
    case rootPermissionsUnsafe(actual: UInt16)
    case rootOwnerMismatch
    case markerMissing
    case markerIsNotRegularFile
    case markerPermissionsUnsafe(actual: UInt16)
    case markerOwnerMismatch
    case markerUnreadable
    case markerMismatch
}

public struct VerifiedOwnedRoot: Hashable, Sendable {
    public let kind: OwnedRootKind
    public let url: URL
    public let installationID: UUID
    public let rootID: UUID

    fileprivate init(descriptor: OwnedRootDescriptor, marker: OwnedRootMarker) {
        kind = descriptor.kind
        url = descriptor.url
        installationID = marker.installationID
        rootID = marker.rootID
    }
}

public struct OwnedRootVerifier: Sendable {
    private let pathSafety = PathSafety()

    public init() {}

    public func verify(
        _ descriptor: OwnedRootDescriptor,
        expectedInstallationID: UUID,
        expectedRootID: UUID
    ) throws -> VerifiedOwnedRoot {
        let root: CanonicalPath
        do {
            root = try pathSafety.canonicalExistingDirectory(descriptor.url)
        } catch PathSafetyError.rootDoesNotExist {
            throw OwnedRootError.rootMissing
        } catch PathSafetyError.rootIsNotDirectory {
            throw OwnedRootError.rootTypeMismatch
        }
        guard root.url == descriptor.url else { throw OwnedRootError.rootTypeMismatch }

        let rootAttributes = try FileManager.default.attributesOfItem(atPath: descriptor.url.path)
        try validateOwnerAndMode(
            attributes: rootAttributes,
            expectedMode: 0o700,
            unsafeMode: { .rootPermissionsUnsafe(actual: $0) },
            ownerMismatch: .rootOwnerMismatch
        )

        let markerURL = descriptor.ownershipMarkerURL
        var markerStat = stat()
        guard lstat(markerURL.path, &markerStat) == 0 else { throw OwnedRootError.markerMissing }
        guard markerStat.st_mode & S_IFMT == S_IFREG else {
            throw OwnedRootError.markerIsNotRegularFile
        }
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        try validateOwnerAndMode(
            attributes: markerAttributes,
            expectedMode: 0o600,
            unsafeMode: { .markerPermissionsUnsafe(actual: $0) },
            ownerMismatch: .markerOwnerMismatch
        )

        let data: Data
        do {
            data = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
        } catch {
            throw OwnedRootError.markerUnreadable
        }
        let marker: OwnedRootMarker
        do {
            marker = try JSONDecoder().decode(OwnedRootMarker.self, from: data)
        } catch {
            throw OwnedRootError.markerUnreadable
        }
        guard marker.formatVersion == OwnedRootMarker.currentFormatVersion,
              marker.bundleIdentifier == OpenBotsPreviewIdentity.bundleIdentifier,
              marker.installationID == expectedInstallationID,
              marker.rootID == expectedRootID,
              marker.kind == descriptor.kind
        else {
            throw OwnedRootError.markerMismatch
        }
        return VerifiedOwnedRoot(descriptor: descriptor, marker: marker)
    }

    private func validateOwnerAndMode(
        attributes: [FileAttributeKey: Any],
        expectedMode: UInt16,
        unsafeMode: (UInt16) -> OwnedRootError,
        ownerMismatch: OwnedRootError
    ) throws {
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? UInt16.max
        guard mode & 0o777 == expectedMode else { throw unsafeMode(mode & 0o777) }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard owner == geteuid() else { throw ownerMismatch }
    }
}

public enum OwnedLifecycleOperation: String, Sendable {
    case reset
    case remove
}

public struct OwnedLifecyclePlan: Hashable, Sendable {
    public let operation: OwnedLifecycleOperation
    public let exactRoot: URL
    public let expectedInstallationID: UUID
    public let expectedRootID: UUID

    /// Lifecycle traversal is physically bounded to this verified root and must not
    /// follow symbolic links. External capabilities are not accepted by this API.
    public let followsSymbolicLinks = false

    fileprivate init(operation: OwnedLifecycleOperation, root: VerifiedOwnedRoot) {
        self.operation = operation
        exactRoot = root.url
        expectedInstallationID = root.installationID
        expectedRootID = root.rootID
    }
}

public struct OwnedLifecyclePlanner: Sendable {
    public init() {}

    public func plan(_ operation: OwnedLifecycleOperation, for root: VerifiedOwnedRoot) -> OwnedLifecyclePlan {
        OwnedLifecyclePlan(operation: operation, root: root)
    }
}
