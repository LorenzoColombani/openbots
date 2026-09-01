import Foundation

public enum PreviewStorageDataClass: String, CaseIterable, Codable, Sendable {
    case installationProtectionReceipt
    case sqliteControlDatabase
    case sqliteWriteAheadLog
    case sqliteSharedMemory
    case databaseRollbackSnapshots
    case queueSpool
    case leaseSpool
    case checkpoints
    case runtimeMetadata
    case claudeCLIProfile
    case generatedConfiguration
    case redactedLogs
    case teammateProfileAssets
    case internalDurableAttachments
    case internalWorkspaces
    case authoritativeMarkdownMemory
    case internalProjectWorkingFiles
    case cacheContainer
    case indexes
    case searchCache
    case thumbnails
    case renderCache
    case downloadCache
    case derivedMetadata
    case attachmentIngestionScratch
    case avatarIngestionScratch
    case avatarRenderCache
    case perRunRuntimeMaterial
    case skillImportStaging
    case temporaryMaterial
    case visibleWorkingContent
    case stableAttachments
    case stableProjectsAndVault
    case knowledgeSnapshots
    case skills
    case exports
}

public enum StorageAuthority: String, Codable, Sendable {
    case structuredAuthority
    case structuredSidecar
    case durableRecovery
    case durableRuntimeAuthority
    case providerOwnedState
    case regenerableConfiguration
    case diagnostics
    case durableUserContent
    case reproducibleDerived
    case stablePublication
}

public enum StorageChurn: String, Codable, Sendable {
    case high
    case low
}

public enum SpotlightBoundaryPolicy: String, Codable, Sendable {
    case requiresNoIndexAncestor
    case ordinaryIndexingAllowed
}

public enum TimeMachinePolicy: String, Codable, Sendable {
    case includedByDefault
    case excludedUsingResourceValue
    case providerOwnedNoOpenBotsMutation
}

public enum HumanExportPolicy: String, Codable, Sendable {
    case never
    case backupArchiveOnly
    case selectedAuditOrStatusOnly
    case redactedDiagnosticsOnly
    case selectedProfileOnly
    case selectedHumanReadable
    case providerOwnedNever
}

public enum StorageResetOwnership: Hashable, Sendable {
    case verifiedOwnedRoot(OwnedRootKind)
    case separatelyDisclosedProviderProfileReset
}

public struct StoragePolicyRecord: Hashable, Sendable {
    public let dataClass: PreviewStorageDataClass
    public let location: URL
    public let authority: StorageAuthority
    public let churn: StorageChurn
    public let spotlight: SpotlightBoundaryPolicy
    public let timeMachine: TimeMachinePolicy
    public let humanExport: HumanExportPolicy
    public let resetOwnership: StorageResetOwnership
}

/// The exhaustive policy ledger for every fixed data-bearing location currently
/// exposed by `PreviewStorageLayout`. Both switches are intentionally exhaustive:
/// adding a data class requires an explicit path and policy before compilation succeeds.
public struct PreviewStoragePolicyInventory: Sendable {
    public let records: [StoragePolicyRecord]
    private let layout: PreviewStorageLayout

    public init(layout: PreviewStorageLayout) {
        self.layout = layout
        records = PreviewStorageDataClass.allCases.map {
            Self.record(for: $0, layout: layout)
        }
    }

    public func record(for dataClass: PreviewStorageDataClass) -> StoragePolicyRecord {
        records.first(where: { $0.dataClass == dataClass })!
    }

    public func ownedRootDescriptor(for kind: OwnedRootKind) -> OwnedRootDescriptor {
        switch kind {
        case .applicationSupport:
            layout.applicationSupportRoot
        case .caches:
            layout.cacheRoot
        case .temporary:
            layout.temporaryRoot
        case .visibleContent:
            layout.contentRoot
        }
    }

    private static func record(
        for dataClass: PreviewStorageDataClass,
        layout: PreviewStorageLayout
    ) -> StoragePolicyRecord {
        let location = location(for: dataClass, layout: layout)
        let policy = policy(for: dataClass)
        return StoragePolicyRecord(
            dataClass: dataClass,
            location: location,
            authority: policy.authority,
            churn: policy.churn,
            spotlight: policy.spotlight,
            timeMachine: policy.timeMachine,
            humanExport: policy.humanExport,
            resetOwnership: policy.resetOwnership
        )
    }

    private static func location(
        for dataClass: PreviewStorageDataClass,
        layout: PreviewStorageLayout
    ) -> URL {
        switch dataClass {
        case .installationProtectionReceipt: layout.installationReceiptURL
        case .sqliteControlDatabase: layout.databaseURL
        case .sqliteWriteAheadLog: layout.databaseWALURL
        case .sqliteSharedMemory: layout.databaseSHMURL
        case .databaseRollbackSnapshots: layout.databaseBackupsRoot
        case .queueSpool: layout.queueRoot
        case .leaseSpool: layout.leaseRoot
        case .checkpoints: layout.checkpointRoot
        case .runtimeMetadata: layout.runtimeMetadataRoot
        case .claudeCLIProfile: layout.claudeCLIProfileRoot
        case .generatedConfiguration: layout.generatedConfigurationRoot
        case .redactedLogs: layout.logsRoot
        case .teammateProfileAssets: layout.profileAssetsRoot
        case .internalDurableAttachments: layout.internalAttachmentsRoot
        case .internalWorkspaces: layout.internalWorkspacesRoot
        case .authoritativeMarkdownMemory: layout.internalMemoryRoot
        case .internalProjectWorkingFiles: layout.internalProjectsRoot
        case .cacheContainer: layout.cacheRoot.url
        case .indexes: layout.cacheIndexesRoot
        case .searchCache: layout.cacheSearchRoot
        case .thumbnails: layout.cacheThumbnailsRoot
        case .renderCache: layout.cacheRenderingRoot
        case .downloadCache: layout.cacheDownloadsRoot
        case .derivedMetadata: layout.cacheDerivedMetadataRoot
        case .attachmentIngestionScratch: layout.attachmentIngestRoot
        case .avatarIngestionScratch: layout.avatarIngestRoot
        case .avatarRenderCache: layout.avatarRendersRoot
        case .perRunRuntimeMaterial: layout.perRunRuntimeRoot
        case .skillImportStaging: layout.skillStagingRoot
        case .temporaryMaterial: layout.temporaryRoot.url
        case .visibleWorkingContent: layout.visibleWorkingRoot
        case .stableAttachments: layout.stableAttachmentsRoot
        case .stableProjectsAndVault: layout.stableProjectsRoot
        case .knowledgeSnapshots: layout.knowledgeSnapshotsRoot
        case .skills: layout.skillsRoot
        case .exports: layout.exportsRoot
        }
    }

    private static func policy(
        for dataClass: PreviewStorageDataClass
    ) -> (
        authority: StorageAuthority,
        churn: StorageChurn,
        spotlight: SpotlightBoundaryPolicy,
        timeMachine: TimeMachinePolicy,
        humanExport: HumanExportPolicy,
        resetOwnership: StorageResetOwnership
    ) {
        switch dataClass {
        case .installationProtectionReceipt:
            return (
                .durableRecovery, .low, .ordinaryIndexingAllowed, .includedByDefault,
                .backupArchiveOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .sqliteControlDatabase:
            return (
                .structuredAuthority, .high, .requiresNoIndexAncestor, .includedByDefault,
                .backupArchiveOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .sqliteWriteAheadLog, .sqliteSharedMemory:
            return (
                .structuredSidecar, .high, .requiresNoIndexAncestor, .includedByDefault,
                .never, .verifiedOwnedRoot(.applicationSupport)
            )
        case .databaseRollbackSnapshots, .checkpoints:
            return (
                .durableRecovery, .high, .requiresNoIndexAncestor, .includedByDefault,
                .never, .verifiedOwnedRoot(.applicationSupport)
            )
        case .queueSpool, .leaseSpool, .runtimeMetadata:
            return (
                .durableRuntimeAuthority, .high, .requiresNoIndexAncestor, .includedByDefault,
                .selectedAuditOrStatusOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .claudeCLIProfile:
            return (
                .providerOwnedState, .high, .requiresNoIndexAncestor,
                .providerOwnedNoOpenBotsMutation, .providerOwnedNever,
                .separatelyDisclosedProviderProfileReset
            )
        case .generatedConfiguration:
            return (
                .regenerableConfiguration, .high, .requiresNoIndexAncestor, .includedByDefault,
                .never, .verifiedOwnedRoot(.applicationSupport)
            )
        case .redactedLogs:
            return (
                .diagnostics, .high, .requiresNoIndexAncestor, .excludedUsingResourceValue,
                .redactedDiagnosticsOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .teammateProfileAssets:
            return (
                .durableUserContent, .low, .requiresNoIndexAncestor, .includedByDefault,
                .selectedProfileOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .internalDurableAttachments:
            // Blobs are immutable; their publication scratch/directory entries
            // still churn. No garbage collector or public/raw exporter exists.
            return (
                .durableUserContent, .high, .requiresNoIndexAncestor, .includedByDefault,
                .backupArchiveOnly, .verifiedOwnedRoot(.applicationSupport)
            )
        case .internalWorkspaces, .authoritativeMarkdownMemory, .internalProjectWorkingFiles:
            return (
                .durableUserContent, .high, .requiresNoIndexAncestor, .includedByDefault,
                .selectedHumanReadable, .verifiedOwnedRoot(.applicationSupport)
            )
        case .cacheContainer, .indexes, .searchCache, .thumbnails, .renderCache,
             .downloadCache, .derivedMetadata, .attachmentIngestionScratch,
             .avatarIngestionScratch, .avatarRenderCache, .perRunRuntimeMaterial,
             .skillImportStaging:
            return (
                .reproducibleDerived, .high, .requiresNoIndexAncestor,
                .excludedUsingResourceValue, .never, .verifiedOwnedRoot(.caches)
            )
        case .temporaryMaterial:
            return (
                .reproducibleDerived, .high, .requiresNoIndexAncestor,
                .excludedUsingResourceValue, .never, .verifiedOwnedRoot(.temporary)
            )
        case .visibleWorkingContent:
            return (
                .durableUserContent, .high, .requiresNoIndexAncestor, .includedByDefault,
                .selectedHumanReadable, .verifiedOwnedRoot(.visibleContent)
            )
        case .stableAttachments, .stableProjectsAndVault, .skills:
            return (
                .durableUserContent, .low, .ordinaryIndexingAllowed, .includedByDefault,
                .selectedHumanReadable, .verifiedOwnedRoot(.visibleContent)
            )
        case .knowledgeSnapshots, .exports:
            return (
                .stablePublication, .low, .ordinaryIndexingAllowed, .includedByDefault,
                .selectedHumanReadable, .verifiedOwnedRoot(.visibleContent)
            )
        }
    }
}
