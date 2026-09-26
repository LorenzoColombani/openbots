import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsRuntime
import OpenBotsSecurity

/// Narrow bootstrap seam used by the composition boundary. Conformance does not
/// add work to `StorageBootstrapService`; the only mutating operation remains the
/// explicit `bootstrap(using:)` call.
public protocol StorageBootstrapping: Sendable {
    func bootstrap(using plan: PreviewRootCreationPlan) async throws -> StorageBootstrapReceipt
}

extension StorageBootstrapService: StorageBootstrapping {}

/// Explicit recovery seam for disposable app-owned roots. This operation may
/// recreate only a genuinely absent Caches or temporary root with the immutable
/// installation receipt's existing identities. It never repairs or replaces an
/// existing item and never recreates Application Support.
public protocol DisposableStorageRootRecovering: Sendable {
    func recoverMissingDisposableRoots(
        using plan: PreviewRootCreationPlan
    ) async throws -> StorageBootstrapReceipt
}

extension StorageBootstrapService: DisposableStorageRootRecovering {}

/// Opens the control repository at the configuration supplied by composition.
/// The default implementation is deliberately small so tests can prove that no
/// database is opened merely by constructing the composition service.
public protocol ControlRepositoryOpening: Sendable {
    func open(configuration: SQLiteStoreConfiguration) async throws -> SQLiteStore
}

public struct SQLiteControlRepositoryOpener: ControlRepositoryOpening {
    public init() {}

    public func open(configuration: SQLiteStoreConfiguration) async throws -> SQLiteStore {
        try SQLiteStore(configuration: configuration)
    }
}

public enum ControlDatabaseValidationFailure: Error, Equatable, Sendable {
    case unexpectedDatabaseURL(expected: URL, actual: URL)
    case protectionModeMismatch(expected: DatabaseProtectionMode, actual: DatabaseProtectionMode)
    case journalModeIsNotWAL(actual: String)
    case foreignKeysDisabled
    case migrationCountMismatch(expected: Int, actual: Int)
    case integrityCheckFailed
}

/// Every case reached after roots have been published retains the complete
/// receipt. Recovery can therefore report and reverify published roots without
/// guessing or deleting them.
public enum StoragePersistenceCompositionError: Error, Equatable, Sendable {
    case alreadyAttempted
    case invalidPlan
    case invalidBootstrapReceipt(receipt: StorageBootstrapReceipt)
    case ownedRootVerificationFailed(
        receipt: StorageBootstrapReceipt,
        kind: OwnedRootKind,
        reason: String
    )
    case installationReceiptPublicationFailed(
        receipt: StorageBootstrapReceipt,
        reason: String
    )
    case installationReceiptReadFailed(reason: String)
    case existingRootVerificationFailed(
        receipt: StorageInstallationReceipt,
        kind: OwnedRootKind,
        reason: String
    )
    case disposableRootRecoveryFailed(
        receipt: StorageInstallationReceipt,
        reason: String
    )
    case databaseProtectionUnavailable(
        receipt: StorageBootstrapReceipt,
        requested: DatabaseProtectionMode
    )
    case databaseOpenFailed(receipt: StorageBootstrapReceipt, reason: String)
    /// The ledger names a schema version newer than this build's manifest: an
    /// older copy of the app opened a workspace a newer copy had migrated
    /// (for example, a displaced rollback bundle launched from the Dock).
    /// Fail closed and say so; never migrate down.
    case databaseNewerThanApplication(receipt: StorageBootstrapReceipt, schemaVersion: Int, supportedVersion: Int)
    case databaseInspectionFailed(receipt: StorageBootstrapReceipt, reason: String)
    case databaseValidationFailed(
        receipt: StorageBootstrapReceipt,
        failure: ControlDatabaseValidationFailure
    )
}

/// The bounded result of first-launch storage and persistence composition. It
/// exposes only the domain repository seams plus the deliberately injected
/// credential/runtime boundaries; callers never receive SQLite handles.
public struct StoragePersistenceContext: Sendable {
    public let storageReceipt: StorageBootstrapReceipt
    public let installationReceipt: StorageInstallationReceipt
    public let applicationSupportRoot: VerifiedOwnedRoot
    public let databaseURL: URL
    public let databaseFacts: DatabaseRuntimeFacts
    public let protectionSelection: DatabaseProtectionSelection
    public let protectionDecision: ProtectionDecisionReceipt
    /// The exact plan the database was opened with, for online backups of it.
    public let protectionPlan: PersistenceProtectionPlan
    /// The only way out of this context for a backup: the store's online-backup
    /// seam, never the connection or the file.
    public let backupExecutor: any SQLiteBackupExecuting

    public let teammateRepository: any TeammateRepository
    public let teammateArchiveRepository: any TeammateArchiveRepository
    public let teamArchiveRepository: any TeamArchiveRepository
    public let teammateDeletionRepository: any TeammateDeletionRepository
    public let botSidebarOrderRepository: any BotSidebarOrderRepository
    public let profilePhotoRepository: any ProfilePhotoRepository
    public let conversationDraftRepository: any ConversationDraftRepository
    public let conversationSearchRepository: any ConversationSearchRepository
    public let attachmentRepository: any AttachmentRepository
    public let runJournalRepository: any RunJournalRepository
    public let textTurnRepository: any TextTurnRepository
    public let readContextRepository: any ReadContextRepository
    public let claudeSessionRepository: any ClaudeSessionRepository
    public let sessionRecoveryRepository: any LocalSessionRecoveryRepository
    public let outcomeHistoryRepository: any ConversationOutcomeHistoryRepository
    public let actionProposalRepository: any ActionProposalRepository
    public let projectRepository: any ProjectRepository
    public let projectProvisioningRepository: any ProjectProvisioningRepository
    public let teamRepository: any TeamRepository
    public let teamProvisioningRepository: any TeamProvisioningRepository
    public let teamConversationRepository: any TeamConversationRepository
    public let handoffRepository: any HandoffRepository
    public let conversationRepository: any ConversationRepository
    public let conversationContextRepository: any ConversationContextRepository
    public let messageRepository: any MessageRepository
    public let directChatProvisioningRepository: any DirectChatProvisioningRepository
    public let hiringDraftRepository: any HiringDraftRepository
    public let chatSelectionRepository: any ChatSelectionRepository
    public let memoryRepository: any MemoryRepository
    public let memoryPublicationIntentRepository: any MemoryPublicationIntentRepository
    public let memoryConversationPublicationRepository: any MemoryConversationPublicationRepository
    public let memoryLocalCorrectionRepository: any MemoryLocalCorrectionRepository
    public let capabilityGrantRepository: any CapabilityGrantRepository
    /// The web switches a launch restores. Their own seam, not the grant
    /// repository's: a bot's web grant is half of a two-switch rule and is not
    /// the authority a `CapabilityGrant` records.
    public let agenticWebSwitchRepository: any AgenticWebSwitchRepository
    /// Bots waiting to set themselves up.
    public let botSelfSetupRepository: any BotSelfSetupRepository
    /// Where the connector grants live: one `app_metadata` row with its own
    /// revision, its own seam for the same reason the web switches have one.
    public let connectorAccessRepository: any ConnectorAccessRepository
    public let approvalRepository: any ApprovalRepository
    /// Where each bot works on the Mac: its own folder and the folders the user added.
    public let botWorkspaceRepository: any BotWorkspaceRepository
    /// What each run did, line by line: the "what happened" record.
    public let runActivityRepository: any RunActivityRepository

    public let keychainClient: any KeychainClient
    public let teammateExecutor: any TeammateExecutor

    fileprivate init(
        storageReceipt: StorageBootstrapReceipt,
        installationReceipt: StorageInstallationReceipt,
        applicationSupportRoot: VerifiedOwnedRoot,
        databaseURL: URL,
        databaseFacts: DatabaseRuntimeFacts,
        protectionSelection: DatabaseProtectionSelection,
        protectionDecision: ProtectionDecisionReceipt,
        protectionPlan: PersistenceProtectionPlan,
        store: SQLiteStore,
        keychainClient: any KeychainClient,
        teammateExecutor: any TeammateExecutor
    ) {
        self.protectionPlan = protectionPlan
        self.backupExecutor = SQLiteStoreBackupExecutor(store: store)
        self.storageReceipt = storageReceipt
        self.installationReceipt = installationReceipt
        self.applicationSupportRoot = applicationSupportRoot
        self.databaseURL = databaseURL
        self.databaseFacts = databaseFacts
        self.protectionSelection = protectionSelection
        self.protectionDecision = protectionDecision
        teammateRepository = store
        teammateArchiveRepository = store
        teamArchiveRepository = store
        teammateDeletionRepository = store
        botSidebarOrderRepository = store
        profilePhotoRepository = store
        conversationDraftRepository = store
        conversationSearchRepository = store
        attachmentRepository = store
        runJournalRepository = store
        textTurnRepository = store
        readContextRepository = store
        claudeSessionRepository = store
        sessionRecoveryRepository = store
        outcomeHistoryRepository = store
        actionProposalRepository = store
        projectRepository = store
        projectProvisioningRepository = store
        teamRepository = store
        teamProvisioningRepository = store
        teamConversationRepository = store
        handoffRepository = store
        conversationRepository = store
        conversationContextRepository = store
        messageRepository = store
        directChatProvisioningRepository = store
        hiringDraftRepository = store
        chatSelectionRepository = store
        memoryRepository = store
        memoryPublicationIntentRepository = store
        memoryConversationPublicationRepository = store
        memoryLocalCorrectionRepository = store
        capabilityGrantRepository = store
        agenticWebSwitchRepository = store
        botSelfSetupRepository = store
        connectorAccessRepository = store
        approvalRepository = store
        botWorkspaceRepository = store
        runActivityRepository = store
        self.keychainClient = keychainClient
        self.teammateExecutor = teammateExecutor
    }
}

/// One-shot composition boundary for the executor-independent foundation. Its
/// initializer is inert: it derives no paths, creates no roots, opens no
/// database, consults no credential store, and starts no runtime process.
public actor StoragePersistenceCompositionService {
    public static let expectedMigrationCount = SQLiteStore.expectedMigrationCount

    private enum Lifecycle: Sendable {
        case ready
        case running
        case finished
    }

    private let layout: PreviewStorageLayout
    private let bootstrapper: any StorageBootstrapping
    private let disposableRootRecoverer: any DisposableStorageRootRecovering
    private let installationReceiptStore: any StorageInstallationReceiptStoring
    private let repositoryOpener: any ControlRepositoryOpening
    private let keychainClient: any KeychainClient
    private let teammateExecutor: any TeammateExecutor
    private let protectionBridge = DatabaseProtectionBridge()
    private let rootVerifier = OwnedRootVerifier()
    private var lifecycle = Lifecycle.ready

    public init(
        layout: PreviewStorageLayout,
        bootstrapper: (any StorageBootstrapping)? = nil,
        disposableRootRecoverer: (any DisposableStorageRootRecovering)? = nil,
        installationReceiptStore: any StorageInstallationReceiptStoring =
            POSIXStorageInstallationReceiptStore(),
        repositoryOpener: any ControlRepositoryOpening = SQLiteControlRepositoryOpener(),
        keychainClient: any KeychainClient = InMemoryKeychainClient(),
        teammateExecutor: any TeammateExecutor = PendingArchitectureExecutor()
    ) {
        self.layout = layout
        self.bootstrapper = bootstrapper ?? StorageBootstrapService(layout: layout)
        self.disposableRootRecoverer = disposableRootRecoverer
            ?? StorageBootstrapService(layout: layout)
        self.installationReceiptStore = installationReceiptStore
        self.repositoryOpener = repositoryOpener
        self.keychainClient = keychainClient
        self.teammateExecutor = teammateExecutor
    }

    /// Performs the only authorized bootstrap/open transition. Protection is an
    /// explicit caller decision: neither the mode nor its receipt has a default.
    public func bootstrapAndOpen(
        using plan: PreviewRootCreationPlan,
        protection selection: DatabaseProtectionSelection,
        decision: ProtectionDecisionReceipt
    ) async throws -> StoragePersistenceContext {
        guard lifecycle == .ready else {
            throw StoragePersistenceCompositionError.alreadyAttempted
        }
        lifecycle = .running
        defer { lifecycle = .finished }

        try validate(plan)
        let installationReceipt: StorageInstallationReceipt
        do {
            installationReceipt = try StorageInstallationReceipt(
                installationID: plan.installationID,
                rootIDs: plan.rootIDs,
                protectionSelection: selection,
                protectionDecision: decision
            )
        } catch {
            throw StoragePersistenceCompositionError.invalidPlan
        }

        let receipt = try await bootstrapper.bootstrap(using: plan)
        let verifiedRoots = try freshlyVerifiedRoots(
            receipt: receipt,
            plan: plan
        )
        do {
            try installationReceiptStore.create(
                installationReceipt,
                in: layout.applicationSupportRoot
            )
        } catch {
            throw StoragePersistenceCompositionError.installationReceiptPublicationFailed(
                receipt: receipt,
                reason: Self.installationReceiptErrorSummary(error)
            )
        }

        return try await openContext(
            storageReceipt: receipt,
            installationReceipt: installationReceipt,
            verifiedRoots: verifiedRoots
        )
    }

    /// Reopens one existing preview installation without creating, repairing, or
    /// selecting anything. Missing disposable roots are surfaced for a later
    /// explicit recovery service; they never cause identity regeneration here.
    public func reopenExisting() async throws -> StoragePersistenceContext {
        guard lifecycle == .ready else {
            throw StoragePersistenceCompositionError.alreadyAttempted
        }
        lifecycle = .running
        defer { lifecycle = .finished }

        let installationReceipt: StorageInstallationReceipt
        do {
            installationReceipt = try installationReceiptStore.read(
                from: layout.applicationSupportRoot
            )
        } catch {
            throw StoragePersistenceCompositionError.installationReceiptReadFailed(
                reason: Self.installationReceiptErrorSummary(error)
            )
        }

        let verifiedRoots = try freshlyVerifiedRoots(
            installationReceipt: installationReceipt
        )
        let storageReceipt = StorageBootstrapReceipt(
            installationID: installationReceipt.installationID,
            verifiedRoots: Self.orderedRoots(from: verifiedRoots)
        )
        return try await openContext(
            storageReceipt: storageReceipt,
            installationReceipt: installationReceipt,
            verifiedRoots: verifiedRoots
        )
    }

    /// Reopens an existing installation while recovering only disposable roots
    /// that are completely absent. The method is separately named because,
    /// unlike `reopenExisting()`, it may publish a missing cache or temporary
    /// root. Existing invalid roots and a missing Application Support root still
    /// fail closed, and the immutable installation receipt is never rewritten.
    public func recoverDisposableRootsAndReopenExisting() async throws -> StoragePersistenceContext {
        guard lifecycle == .ready else {
            throw StoragePersistenceCompositionError.alreadyAttempted
        }
        lifecycle = .running
        defer { lifecycle = .finished }

        let installationReceipt: StorageInstallationReceipt
        do {
            installationReceipt = try installationReceiptStore.read(
                from: layout.applicationSupportRoot
            )
        } catch {
            throw StoragePersistenceCompositionError.installationReceiptReadFailed(
                reason: Self.installationReceiptErrorSummary(error)
            )
        }

        let recoveryPlan: PreviewRootCreationPlan
        do {
            recoveryPlan = try PreviewRootCreationPlan(
                layout: layout,
                installationID: installationReceipt.installationID,
                rootIDs: installationReceipt.rootIDs
            )
        } catch {
            throw StoragePersistenceCompositionError.installationReceiptReadFailed(
                reason: Self.errorSummary(error)
            )
        }

        let storageReceipt: StorageBootstrapReceipt
        do {
            storageReceipt = try await disposableRootRecoverer
                .recoverMissingDisposableRoots(using: recoveryPlan)
        } catch {
            throw StoragePersistenceCompositionError.disposableRootRecoveryFailed(
                receipt: installationReceipt,
                reason: Self.errorSummary(error)
            )
        }

        let verifiedRoots = try freshlyVerifiedRoots(
            receipt: storageReceipt,
            plan: recoveryPlan
        )
        return try await openContext(
            storageReceipt: storageReceipt,
            installationReceipt: installationReceipt,
            verifiedRoots: verifiedRoots
        )
    }

    private func openContext(
        storageReceipt receipt: StorageBootstrapReceipt,
        installationReceipt: StorageInstallationReceipt,
        verifiedRoots: [OwnedRootKind: VerifiedOwnedRoot]
    ) async throws -> StoragePersistenceContext {
        guard let applicationSupportRoot = verifiedRoots[.applicationSupport] else {
            throw StoragePersistenceCompositionError.invalidBootstrapReceipt(receipt: receipt)
        }

        let protectionPlan = protectionBridge.persistencePlan(
            for: installationReceipt.protectionSelection,
            decision: installationReceipt.protectionDecision
        )
        let configuration: SQLiteStoreConfiguration
        do {
            configuration = try SQLiteStoreConfiguration(
                fileURL: layout.databaseURL,
                protection: protectionPlan
            )
        } catch {
            throw StoragePersistenceCompositionError.databaseOpenFailed(
                receipt: receipt,
                reason: Self.errorSummary(error)
            )
        }

        let store: SQLiteStore
        do {
            store = try await repositoryOpener.open(configuration: configuration)
        } catch let error as DatabaseProtectionError {
            if case let .adapterUnavailable(requested) = error {
                throw StoragePersistenceCompositionError.databaseProtectionUnavailable(
                    receipt: receipt,
                    requested: requested
                )
            }
            throw StoragePersistenceCompositionError.databaseOpenFailed(
                receipt: receipt,
                reason: Self.errorSummary(error)
            )
        } catch SQLiteStoreError.unsupportedSchemaVersion(let schemaVersion) {
            throw StoragePersistenceCompositionError.databaseNewerThanApplication(
                receipt: receipt,
                schemaVersion: schemaVersion,
                supportedVersion: SQLiteStore.supportedSchemaVersion
            )
        } catch {
            throw StoragePersistenceCompositionError.databaseOpenFailed(
                receipt: receipt,
                reason: Self.errorSummary(error)
            )
        }

        let openedDatabaseURL = await store.fileURL
        guard openedDatabaseURL == layout.databaseURL else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .unexpectedDatabaseURL(
                    expected: layout.databaseURL,
                    actual: openedDatabaseURL
                )
            )
        }
        let openedProtectionMode = await store.protectionMode
        guard openedProtectionMode == protectionPlan.mode else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .protectionModeMismatch(
                    expected: protectionPlan.mode,
                    actual: openedProtectionMode
                )
            )
        }

        let facts: DatabaseRuntimeFacts
        let integrityOK: Bool
        do {
            facts = try await store.runtimeFacts()
            integrityOK = try await store.integrityCheck()
        } catch {
            throw StoragePersistenceCompositionError.databaseInspectionFailed(
                receipt: receipt,
                reason: Self.errorSummary(error)
            )
        }
        try validateDatabase(
            facts: facts,
            integrityOK: integrityOK,
            expectedProtection: protectionPlan.mode,
            receipt: receipt
        )

        return StoragePersistenceContext(
            storageReceipt: receipt,
            installationReceipt: installationReceipt,
            applicationSupportRoot: applicationSupportRoot,
            databaseURL: layout.databaseURL,
            databaseFacts: facts,
            protectionSelection: installationReceipt.protectionSelection,
            protectionDecision: installationReceipt.protectionDecision,
            protectionPlan: protectionPlan,
            store: store,
            keychainClient: keychainClient,
            teammateExecutor: teammateExecutor
        )
    }

    private func validate(_ plan: PreviewRootCreationPlan) throws {
        let expected: PreviewRootCreationPlan
        do {
            expected = try PreviewRootCreationPlan(
                layout: layout,
                installationID: plan.installationID,
                rootIDs: plan.rootIDs
            )
        } catch {
            throw StoragePersistenceCompositionError.invalidPlan
        }
        guard expected.steps == plan.steps,
              Set(plan.rootIDs.values).count == plan.rootIDs.count
        else {
            throw StoragePersistenceCompositionError.invalidPlan
        }
    }

    private func freshlyVerifiedRoots(
        receipt: StorageBootstrapReceipt,
        plan: PreviewRootCreationPlan
    ) throws -> [OwnedRootKind: VerifiedOwnedRoot] {
        let descriptors = [
            layout.applicationSupportRoot,
            layout.cacheRoot,
            layout.temporaryRoot
        ]
        guard receipt.installationID == plan.installationID,
              receipt.verifiedRoots.count == descriptors.count
        else {
            throw StoragePersistenceCompositionError.invalidBootstrapReceipt(receipt: receipt)
        }

        var result: [OwnedRootKind: VerifiedOwnedRoot] = [:]
        for descriptor in descriptors {
            let claims = receipt.verifiedRoots.filter { $0.kind == descriptor.kind }
            guard claims.count == 1,
                  let claimedRoot = claims.first,
                  let expectedRootID = plan.rootIDs[descriptor.kind],
                  claimedRoot.url == descriptor.url,
                  claimedRoot.installationID == plan.installationID,
                  claimedRoot.rootID == expectedRootID
            else {
                throw StoragePersistenceCompositionError.invalidBootstrapReceipt(receipt: receipt)
            }

            let freshlyVerified: VerifiedOwnedRoot
            do {
                freshlyVerified = try rootVerifier.verify(
                    descriptor,
                    expectedInstallationID: plan.installationID,
                    expectedRootID: expectedRootID
                )
            } catch {
                throw StoragePersistenceCompositionError.ownedRootVerificationFailed(
                    receipt: receipt,
                    kind: descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
            guard freshlyVerified == claimedRoot else {
                throw StoragePersistenceCompositionError.invalidBootstrapReceipt(receipt: receipt)
            }
            result[descriptor.kind] = freshlyVerified
        }
        return result
    }

    private func freshlyVerifiedRoots(
        installationReceipt: StorageInstallationReceipt
    ) throws -> [OwnedRootKind: VerifiedOwnedRoot] {
        let descriptors = [
            layout.applicationSupportRoot,
            layout.cacheRoot,
            layout.temporaryRoot
        ]
        var result: [OwnedRootKind: VerifiedOwnedRoot] = [:]
        for descriptor in descriptors {
            guard let expectedRootID = installationReceipt.rootID(for: descriptor.kind) else {
                throw StoragePersistenceCompositionError.installationReceiptReadFailed(
                    reason: Self.errorSummary(StorageInstallationReceiptError.invalidRootIdentitySet)
                )
            }
            do {
                result[descriptor.kind] = try rootVerifier.verify(
                    descriptor,
                    expectedInstallationID: installationReceipt.installationID,
                    expectedRootID: expectedRootID
                )
            } catch {
                throw StoragePersistenceCompositionError.existingRootVerificationFailed(
                    receipt: installationReceipt,
                    kind: descriptor.kind,
                    reason: Self.errorSummary(error)
                )
            }
        }
        return result
    }

    private static func orderedRoots(
        from roots: [OwnedRootKind: VerifiedOwnedRoot]
    ) -> [VerifiedOwnedRoot] {
        [OwnedRootKind.applicationSupport, .caches, .temporary].compactMap { roots[$0] }
    }

    private func validateDatabase(
        facts: DatabaseRuntimeFacts,
        integrityOK: Bool,
        expectedProtection: DatabaseProtectionMode,
        receipt: StorageBootstrapReceipt
    ) throws {
        guard facts.protectionMode == expectedProtection else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .protectionModeMismatch(
                    expected: expectedProtection,
                    actual: facts.protectionMode
                )
            )
        }
        guard facts.journalMode.caseInsensitiveCompare("wal") == .orderedSame else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .journalModeIsNotWAL(actual: facts.journalMode)
            )
        }
        guard facts.foreignKeysEnabled else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .foreignKeysDisabled
            )
        }
        guard facts.migrationCount == Self.expectedMigrationCount else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .migrationCountMismatch(
                    expected: Self.expectedMigrationCount,
                    actual: facts.migrationCount
                )
            )
        }
        guard integrityOK else {
            throw StoragePersistenceCompositionError.databaseValidationFailed(
                receipt: receipt,
                failure: .integrityCheckFailed
            )
        }
    }

    private static func errorSummary(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }

    private static func installationReceiptErrorSummary(_ error: any Error) -> String {
        guard let receiptError = error as? StorageInstallationReceiptError else {
            return errorSummary(error)
        }
        return String(describing: receiptError)
    }
}
