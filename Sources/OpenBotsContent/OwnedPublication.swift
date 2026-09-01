import Foundation

public enum OwnedPublicationError: Error, Equatable, Sendable {
    case sourceRootIdentityUnavailable
    case destinationRootIdentityUnavailable
    case crossVolume
}

public struct OwnedAtomicPublicationPlan: Hashable, Sendable {
    public let source: URL
    public let destination: URL
    public let sourceRootID: UUID
    public let destinationRootID: UUID

    /// The future executor must use an exclusive atomic rename and revalidate both
    /// verified roots immediately before execution.
    public let requiresExclusiveAtomicRename = true

    fileprivate init(source: URL, destination: URL, sourceRootID: UUID, destinationRootID: UUID) {
        self.source = source
        self.destination = destination
        self.sourceRootID = sourceRootID
        self.destinationRootID = destinationRootID
    }
}

public struct OwnedPublicationPlanner: Sendable {
    private let pathSafety = PathSafety()

    public init() {}

    public func plan(
        source: URL,
        inside sourceRoot: VerifiedOwnedRoot,
        destination: URL,
        inside destinationRoot: VerifiedOwnedRoot
    ) throws -> OwnedAtomicPublicationPlan {
        let sourceRootPath = try pathSafety.canonicalExistingDirectory(sourceRoot.url)
        let destinationRootPath = try pathSafety.canonicalExistingDirectory(destinationRoot.url)
        guard let sourceRootIdentity = sourceRootPath.identity else {
            throw OwnedPublicationError.sourceRootIdentityUnavailable
        }
        guard let destinationRootIdentity = destinationRootPath.identity else {
            throw OwnedPublicationError.destinationRootIdentityUnavailable
        }
        guard sourceRootIdentity.device == destinationRootIdentity.device else {
            throw OwnedPublicationError.crossVolume
        }

        let canonicalSource = try pathSafety.canonicalExistingItem(source, containedIn: sourceRootPath)
        let destinationParent = try pathSafety.canonicalExistingDirectory(destination.deletingLastPathComponent())
        guard pathSafety.isComponentContained(destinationParent.url, in: destinationRootPath.url) else {
            throw PathSafetyError.escapesRoot
        }
        let exclusiveDestination = try pathSafety.exclusiveFutureChild(
            named: destination.lastPathComponent,
            of: destinationParent
        )
        return OwnedAtomicPublicationPlan(
            source: canonicalSource.url,
            destination: exclusiveDestination,
            sourceRootID: sourceRoot.rootID,
            destinationRootID: destinationRoot.rootID
        )
    }
}
