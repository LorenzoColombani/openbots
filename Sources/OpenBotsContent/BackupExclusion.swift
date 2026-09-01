import Foundation

public protocol BackupExclusionResourceAccess: Sendable {
    func setExcludedFromBackup(at url: URL) throws
    func isExcludedFromBackup(at url: URL) throws -> Bool?
}

/// The supported Foundation resource-value adapter. It does not call `tmutil`,
/// Spotlight APIs, File Provider setters, or synchronization APIs.
public struct FoundationBackupExclusionResourceAccess: BackupExclusionResourceAccess {
    public init() {}

    public func setExcludedFromBackup(at url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    public func isExcludedFromBackup(at url: URL) throws -> Bool? {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }
}

public struct BackupExclusionTarget: Hashable, Sendable {
    public let dataClass: PreviewStorageDataClass
    public let exactURL: URL
}

public struct BackupExclusionPlan: Hashable, Sendable {
    public let rootKind: OwnedRootKind
    public let exactRoot: URL
    public let expectedInstallationID: UUID
    public let expectedRootID: UUID
    public let targets: [BackupExclusionTarget]

    fileprivate init(root: VerifiedOwnedRoot, targets: [BackupExclusionTarget]) {
        rootKind = root.kind
        exactRoot = root.url
        expectedInstallationID = root.installationID
        expectedRootID = root.rootID
        self.targets = targets
    }
}

public enum BackupExclusionError: Error, Equatable, Sendable {
    case rootDoesNotMatchInventory
    case noEligibleTargets
    case targetMissingNoIndexBoundary(PreviewStorageDataClass)
    case targetEscapesVerifiedRoot(PreviewStorageDataClass)
    case targetIdentityChanged(PreviewStorageDataClass)
    case resourceValueNotTrue(PreviewStorageDataClass)
}

public struct BackupExclusionPlanner: Sendable {
    public init() {}

    public func plan(
        for root: VerifiedOwnedRoot,
        inventory: PreviewStoragePolicyInventory
    ) throws -> BackupExclusionPlan {
        guard inventory.ownedRootDescriptor(for: root.kind).url == root.url else {
            throw BackupExclusionError.rootDoesNotMatchInventory
        }
        let targets = try inventory.records.compactMap { record -> BackupExclusionTarget? in
            guard record.timeMachine == .excludedUsingResourceValue,
                  record.resetOwnership == .verifiedOwnedRoot(root.kind)
            else {
                return nil
            }
            guard record.location.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
                throw BackupExclusionError.targetMissingNoIndexBoundary(record.dataClass)
            }
            guard PathSafety().isComponentContained(record.location, in: root.url) else {
                throw BackupExclusionError.targetEscapesVerifiedRoot(record.dataClass)
            }
            return BackupExclusionTarget(dataClass: record.dataClass, exactURL: record.location)
        }
        guard !targets.isEmpty else { throw BackupExclusionError.noEligibleTargets }
        return BackupExclusionPlan(root: root, targets: targets)
    }
}

public struct BackupExclusionReceipt: Hashable, Sendable {
    public let rootID: UUID
    public let verifiedDataClasses: [PreviewStorageDataClass]
}

public struct BackupExclusionExecutor: Sendable {
    private let resourceAccess: any BackupExclusionResourceAccess

    public init(resourceAccess: any BackupExclusionResourceAccess) {
        self.resourceAccess = resourceAccess
    }

    public func execute(_ plan: BackupExclusionPlan) throws -> BackupExclusionReceipt {
        let validator = BackupExclusionTargetValidator()
        _ = try validator.verifyRoot(plan)
        for target in plan.targets {
            let before = try validator.verifyTarget(target, in: plan)
            try resourceAccess.setExcludedFromBackup(at: target.exactURL)
            let after = try validator.verifyTarget(target, in: plan)
            guard before.identity == after.identity else {
                throw BackupExclusionError.targetIdentityChanged(target.dataClass)
            }
            guard try resourceAccess.isExcludedFromBackup(at: target.exactURL) == true else {
                throw BackupExclusionError.resourceValueNotTrue(target.dataClass)
            }
        }
        return BackupExclusionReceipt(
            rootID: plan.expectedRootID,
            verifiedDataClasses: plan.targets.map(\.dataClass)
        )
    }
}

public struct BackupExclusionVerifier: Sendable {
    private let resourceAccess: any BackupExclusionResourceAccess

    public init(resourceAccess: any BackupExclusionResourceAccess) {
        self.resourceAccess = resourceAccess
    }

    public func verify(_ plan: BackupExclusionPlan) throws -> BackupExclusionReceipt {
        let validator = BackupExclusionTargetValidator()
        _ = try validator.verifyRoot(plan)
        for target in plan.targets {
            _ = try validator.verifyTarget(target, in: plan)
            guard try resourceAccess.isExcludedFromBackup(at: target.exactURL) == true else {
                throw BackupExclusionError.resourceValueNotTrue(target.dataClass)
            }
        }
        return BackupExclusionReceipt(
            rootID: plan.expectedRootID,
            verifiedDataClasses: plan.targets.map(\.dataClass)
        )
    }
}

private struct BackupExclusionTargetValidator {
    private let pathSafety = PathSafety()

    func verifyRoot(_ plan: BackupExclusionPlan) throws -> VerifiedOwnedRoot {
        try OwnedRootVerifier().verify(
            OwnedRootDescriptor(kind: plan.rootKind, url: plan.exactRoot),
            expectedInstallationID: plan.expectedInstallationID,
            expectedRootID: plan.expectedRootID
        )
    }

    func verifyTarget(
        _ target: BackupExclusionTarget,
        in plan: BackupExclusionPlan
    ) throws -> CanonicalPath {
        guard target.exactURL.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) else {
            throw BackupExclusionError.targetMissingNoIndexBoundary(target.dataClass)
        }
        guard pathSafety.isComponentContained(target.exactURL, in: plan.exactRoot) else {
            throw BackupExclusionError.targetEscapesVerifiedRoot(target.dataClass)
        }
        return try pathSafety.canonicalExistingDirectory(target.exactURL)
    }
}
