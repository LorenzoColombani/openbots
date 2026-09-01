import Darwin
import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private let compositionAdmittedLocation = LocationObservation(
    isLocalVolume: true,
    isReadOnlyVolume: false,
    isUbiquitousItem: false,
    fileProviderStatus: .notManaged,
    volumeIdentifier: "composition-test-volume"
)

private struct CompositionFixedAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        compositionAdmittedLocation
    }
}

private struct CompositionFixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private struct CompositionFixedUUIDGenerator: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private struct InjectedBootstrapFailure: Error {}
private struct InjectedOpenFailure: Error {}

private actor FailingBootstrapper: StorageBootstrapping {
    private var callCount = 0

    func bootstrap(using plan: PreviewRootCreationPlan) async throws -> StorageBootstrapReceipt {
        callCount += 1
        throw InjectedBootstrapFailure()
    }

    func calls() -> Int { callCount }
}

private actor FailingRepositoryOpener: ControlRepositoryOpening {
    private var configurations: [SQLiteStoreConfiguration] = []

    func open(configuration: SQLiteStoreConfiguration) async throws -> SQLiteStore {
        configurations.append(configuration)
        throw InjectedOpenFailure()
    }

    func recordedConfigurations() -> [SQLiteStoreConfiguration] { configurations }
}

private actor SQLCipherRejectingRepositoryOpener: ControlRepositoryOpening {
    private var configurations: [SQLiteStoreConfiguration] = []

    func open(configuration: SQLiteStoreConfiguration) async throws -> SQLiteStore {
        configurations.append(configuration)
        throw DatabaseProtectionError.adapterUnavailable(requested: configuration.protection.mode)
    }

    func recordedConfigurations() -> [SQLiteStoreConfiguration] { configurations }
}

private struct WrongURLRepositoryOpener: ControlRepositoryOpening {
    let wrongURL: URL

    func open(configuration: SQLiteStoreConfiguration) async throws -> SQLiteStore {
        let wrongConfiguration = try SQLiteStoreConfiguration(
            fileURL: wrongURL,
            protection: configuration.protection,
            busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
        )
        return try SQLiteStore(configuration: wrongConfiguration)
    }
}

private struct TamperingBootstrapper: StorageBootstrapping {
    let base: StorageBootstrapService
    let layout: PreviewStorageLayout
    let kind: OwnedRootKind

    func bootstrap(using plan: PreviewRootCreationPlan) async throws -> StorageBootstrapReceipt {
        let receipt = try await base.bootstrap(using: plan)
        let markerURL: URL
        switch kind {
        case .applicationSupport:
            markerURL = layout.applicationSupportRoot.ownershipMarkerURL
        case .caches:
            markerURL = layout.cacheRoot.ownershipMarkerURL
        case .temporary:
            markerURL = layout.temporaryRoot.ownershipMarkerURL
        case .visibleContent:
            markerURL = layout.contentRoot.ownershipMarkerURL
        }
        try Data("tampered after bootstrap".utf8).write(to: markerURL, options: .atomic)
        return receipt
    }
}

private actor CompositionExecutorSpy: TeammateExecutor {
    private var callCount = 0

    func start(_ request: WorkRequest) async throws { callCount += 1 }

    func steer(_ input: SteeringInput, into runID: RunID) async throws -> SteeringSubmission {
        callCount += 1
        return SteeringSubmission(runID: runID, messageID: input.messageID, sequence: input.sequence)
    }

    func events(for runID: RunID) async -> AsyncThrowingStream<WorkEvent, any Error> {
        callCount += 1
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    func requestStop(runID: RunID) async throws { callCount += 1 }

    func calls() -> Int { callCount }
}

private final class StoragePersistenceCompositionFixture: @unchecked Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let installationID = UUID()
    let rootIDs: [OwnedRootKind: UUID] = [
        .applicationSupport: UUID(),
        .caches: UUID(),
        .temporary: UUID()
    ]

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp/OpenBotsNextCompositionTests-\(UUID().uuidString).noindex",
            isDirectory: true
        )
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Caches", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
    }

    deinit {
        let path = root.path
        guard path.hasPrefix("/private/tmp/OpenBotsNextCompositionTests-"),
              path.hasSuffix(".noindex")
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func plan() throws -> PreviewRootCreationPlan {
        try PreviewRootCreationPlan(
            layout: layout,
            installationID: installationID,
            rootIDs: rootIDs
        )
    }

    func decision() throws -> ProtectionDecisionReceipt {
        try ProtectionDecisionReceipt(
            decisionID: UUID(),
            selectedAt: Date(timeIntervalSince1970: 860),
            rationaleVersion: 1
        )
    }

    func bootstrapper() -> StorageBootstrapService {
        StorageBootstrapService(
            layout: layout,
            locationAdmission: CompositionFixedAdmission()
        )
    }

    var internalRootURLs: [URL] {
        [
            layout.applicationSupportRoot.url,
            layout.cacheRoot.url,
            layout.temporaryRoot.url
        ]
    }
}

@Test("Constructing storage composition performs no filesystem, database, Keychain, or runtime work")
func compositionConstructionIsInert() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let bootstrapper = FailingBootstrapper()
    let opener = FailingRepositoryOpener()
    let keychain = InMemoryKeychainClient()
    let executor = CompositionExecutorSpy()

    _ = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: bootstrapper,
        repositoryOpener: opener,
        keychainClient: keychain,
        teammateExecutor: executor
    )

    #expect(await bootstrapper.calls() == 0)
    #expect(await opener.recordedConfigurations().isEmpty)
    #expect(await keychain.recordedOperations().isEmpty)
    #expect(await executor.calls() == 0)
    for rootURL in fixture.internalRootURLs {
        #expect(!FileManager.default.fileExists(atPath: rootURL.path))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseURL.path))
}

@Test("Only the explicit one-shot operation bootstraps, and bootstrap failure prevents database open")
func compositionRequiresExplicitBootstrapAndStopsAfterFailure() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let bootstrapper = FailingBootstrapper()
    let opener = FailingRepositoryOpener()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: bootstrapper,
        repositoryOpener: opener
    )

    await #expect(throws: InjectedBootstrapFailure.self) {
        _ = try await service.bootstrapAndOpen(
            using: fixture.plan(),
            protection: .ordinarySQLite,
            decision: fixture.decision()
        )
    }
    await #expect(throws: StoragePersistenceCompositionError.alreadyAttempted) {
        _ = try await service.bootstrapAndOpen(
            using: fixture.plan(),
            protection: .ordinarySQLite,
            decision: fixture.decision()
        )
    }

    #expect(await bootstrapper.calls() == 1)
    #expect(await opener.recordedConfigurations().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseURL.path))
}

@Test("Real bootstrap opens the exact database and returns working narrow repositories")
func compositionBootstrapsAndOpensRepositoryRoundTrip() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let keychain = InMemoryKeychainClient()
    let executor = CompositionExecutorSpy()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper(),
        keychainClient: keychain,
        teammateExecutor: executor
    )

    let context = try await service.bootstrapAndOpen(
        using: plan,
        protection: .ordinarySQLite,
        decision: decision
    )

    #expect(context.storageReceipt.installationID == plan.installationID)
    #expect(context.installationReceipt.installationID == plan.installationID)
    #expect(context.installationReceipt.rootIDs == plan.rootIDs)
    #expect(context.installationReceipt.protectionSelection == .ordinarySQLite)
    #expect(context.installationReceipt.protectionDecision == decision)
    #expect(context.databaseURL == fixture.layout.databaseURL)
    #expect(context.applicationSupportRoot.url == fixture.layout.applicationSupportRoot.url)
    #expect(context.protectionSelection == .ordinarySQLite)
    #expect(context.protectionDecision == decision)
    #expect(context.databaseFacts.protectionMode == .ordinarySQLite)
    #expect(context.databaseFacts.journalMode.caseInsensitiveCompare("wal") == .orderedSame)
    #expect(context.databaseFacts.foreignKeysEnabled)
    #expect(try await context.runJournalRepository.run(id: RunID(UUID())) == nil)
    #expect(try await context.actionProposalRepository.proposals(conversationID: ConversationID(UUID()), limit: 10).isEmpty)
    let historyRequest = try ConversationOutcomeHistoryRequest(conversationID: ConversationID(UUID()), teammateID: TeammateID(UUID()))
    let history = try await ConversationOutcomeHistoryService(repository: context.outcomeHistoryRepository).history(historyRequest)
    #expect(history.scope == .unavailable && history.outcomes.isEmpty && !history.hasMore)
    #expect(
        context.databaseFacts.migrationCount
            == StoragePersistenceCompositionService.expectedMigrationCount
    )

    let teammateID = UUID(uuidString: "87000000-0000-0000-0000-000000000001")!
    let profileService = TeammateProfileService(
        repository: context.teammateRepository,
        clock: CompositionFixedClock(value: Date(timeIntervalSince1970: 870)),
        uuidGenerator: CompositionFixedUUIDGenerator(value: teammateID)
    )
    let teammate = try await profileService.createQuickTeammate(
        QuickTeammateDraft(displayName: "Nova", role: "Researcher")
    )
    #expect(try await context.teammateRepository.teammate(id: teammate.id) == teammate)

    let project = try Project(
        id: ProjectID(UUID(uuidString: "87000000-0000-0000-0000-000000000003")!),
        name: "Composition Project",
        createdAt: Date(timeIntervalSince1970: 872),
        updatedAt: Date(timeIntervalSince1970: 872)
    )
    try await context.projectProvisioningRepository.provisionProject(
        project,
        initialMemberIDs: [teammate.id]
    )
    #expect(try await context.projectRepository.project(id: project.id) == project)
    #expect(
        try await context.projectRepository.activeMemberIDs(projectID: project.id)
            == [teammate.id]
    )

    let descriptors = [
        fixture.layout.applicationSupportRoot,
        fixture.layout.cacheRoot,
        fixture.layout.temporaryRoot
    ]
    for descriptor in descriptors {
        let expectedRootID = try #require(plan.rootIDs[descriptor.kind])
        let verified = try OwnedRootVerifier().verify(
            descriptor,
            expectedInstallationID: plan.installationID,
            expectedRootID: expectedRootID
        )
        #expect(context.storageReceipt.verifiedRoots.contains(verified))
    }

    #expect(await keychain.recordedOperations().isEmpty)
    #expect(await executor.calls() == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
}

@Test("An existing installation reopens from its immutable receipt without creating or selecting")
func compositionReopensExistingInstallation() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let firstContext = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper()
    ).bootstrapAndOpen(
        using: plan,
        protection: .ordinarySQLite,
        decision: decision
    )

    let teammateID = UUID(uuidString: "87000000-0000-0000-0000-000000000002")!
    let profileService = TeammateProfileService(
        repository: firstContext.teammateRepository,
        clock: CompositionFixedClock(value: Date(timeIntervalSince1970: 871)),
        uuidGenerator: CompositionFixedUUIDGenerator(value: teammateID)
    )
    let teammate = try await profileService.createQuickTeammate(
        QuickTeammateDraft(displayName: "Mica", role: "Analyst")
    )

    let keychain = InMemoryKeychainClient()
    let executor = CompositionExecutorSpy()
    let reopened = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        keychainClient: keychain,
        teammateExecutor: executor
    ).reopenExisting()

    #expect(reopened.installationReceipt == firstContext.installationReceipt)
    #expect(reopened.storageReceipt.installationID == plan.installationID)
    #expect(reopened.storageReceipt.verifiedRoots.count == 3)
    #expect(try await reopened.teammateRepository.teammate(id: teammate.id) == teammate)
    #expect(await keychain.recordedOperations().isEmpty)
    #expect(await executor.calls() == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
}

@Test("Full startup migrates schema 12 or 13 identity, chat and unsent draft to the current schema without authority calls", arguments: [12, 13])
func compositionMigratesSchema12AvatarIdentityAndDraftAcrossReopen(priorSchema: Int) async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let keychain = InMemoryKeychainClient()
    let executor = CompositionExecutorSpy()
    let timestamp = Date(timeIntervalSince1970: 8_713)
    let teammate = try Teammate(
        id: TeammateID(UUID()),
        profile: TeammateProfile(displayName: "Saved schema-12 bot", title: "Analyst", role: "Keep existing work",
            detailedInstructions: "Preserve the original profile.", revision: 3),
        appearance: AgentAppearance(mode: .creature, grammarVersion: 3, deterministicSeed: UInt64.max - 13,
            silhouette: "sprout", paletteToken: "violet", eyeDialect: "bright", nonColorIdentityCue: "leaf ears",
            accessibleIdentityDescription: "Original saved sprout", builtInAvatarID: priorSchema == 13 ? "guide" : nil, revision: 4),
        isPinned: true, notificationPreference: .disabled, createdAt: timestamp, updatedAt: timestamp
    )
    let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: teammate.id),
        title: "Existing conversation", createdAt: timestamp, updatedAt: timestamp)
    let message = try Message(id: MessageID(UUID()), conversationID: conversation.id, sequence: 1, author: .user,
        deliveryState: .completed,
        parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Saved message\n  exact whitespace  "))],
        createdAt: timestamp, updatedAt: timestamp)
    var draft: ConversationDraftSnapshot?
    weak var previousStore: SQLiteStore?
    var originalTriggers: [String] = []
    do {
        let context = try await StoragePersistenceCompositionService(
            layout: fixture.layout, bootstrapper: fixture.bootstrapper(),
            keychainClient: keychain, teammateExecutor: executor
        ).bootstrapAndOpen(using: plan, protection: .ordinarySQLite, decision: decision)
        let store = try #require(context.teammateRepository as? SQLiteStore)
        previousStore = store
        try await context.directChatProvisioningRepository.provisionDirectChat(
            teammate: teammate, conversation: conversation, fixtureGreeting: nil, selectConversation: true)
        try await context.messageRepository.append(message, expectedPreviousSequence: 0)
        draft = try await context.conversationDraftRepository.saveDraft(
            conversationID: conversation.id, text: "Unsent schema-12 draft\n  keep this text  ",
            expectedRevision: 0, updatedAt: timestamp)

        originalTriggers = try await store.nonOrderingTriggerSignaturesForStartupTest()
        try await store.reconstructPriorSidebarSchemaForStartupTest(priorSchema)
        #expect(try await store.runtimeFacts().migrationCount == priorSchema)
        #expect(try await store.query(sql: "SELECT version FROM schema_migrations ORDER BY version;")
            .map { try $0.integer("version") } == Array(1...Int64(priorSchema)))
        #expect(try await store.nonOrderingTriggerSignaturesForStartupTest() == originalTriggers)
    }
    #expect(previousStore == nil)
    let receiptBytes = try Data(contentsOf: fixture.layout.installationReceiptURL)

    // Both passes go through the actual startup composition validation, not
    // merely SQLiteStore opening: the first migrates 12/13 to the current schema, the second
    // proves an already-upgraded database remains accepted on the next launch.
    for _ in 0..<2 {
        do {
            let context = try await StoragePersistenceCompositionService(
                layout: fixture.layout, keychainClient: keychain, teammateExecutor: executor
            ).reopenExisting()
            previousStore = context.teammateRepository as? SQLiteStore
            #expect(context.databaseFacts.migrationCount == 20)
            #expect(context.databaseFacts.migrationCount == StoragePersistenceCompositionService.expectedMigrationCount)
            #expect(context.installationReceipt.installationID == plan.installationID)
            #expect(context.installationReceipt.protectionDecision == decision)
            #expect(try await context.teammateRepository.teammate(id: teammate.id) == teammate)
            #expect(try await context.teammateRepository.listTeammates(includingArchived: true) == [teammate])
            #expect(try await context.conversationRepository.conversation(id: conversation.id) == conversation)
            #expect(try await context.messageRepository.page(conversationID: conversation.id, request: PageRequest(limit: 10)).elements == [message])
            #expect(try await context.conversationDraftRepository.loadDraft(conversationID: conversation.id) == draft)
            #expect(try await context.chatSelectionRepository.selectedConversationID() == conversation.id)
            #expect(try Data(contentsOf: fixture.layout.installationReceiptURL) == receiptBytes)
            #expect(try await context.botSidebarOrderRepository.loadBotSidebarOrder().teammateIDs == [teammate.id])
            let reopenedStore = try #require(context.teammateRepository as? SQLiteStore)
            #expect(try await reopenedStore.nonOrderingTriggerSignaturesForStartupTest() == originalTriggers)
            #expect(try await reopenedStore.query(sql: "SELECT version FROM schema_migrations ORDER BY version;")
                .map { try $0.integer("version") } == Array(1...Int64(StoragePersistenceCompositionService.expectedMigrationCount)))
        }
        #expect(previousStore == nil)
    }
    #expect(await keychain.recordedOperations().isEmpty)
    #expect(await executor.calls() == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
}

private extension SQLiteStore {
    func reconstructPriorSidebarSchemaForStartupTest(_ version: Int) throws {
        // One transaction on this test-owned temporary store only. Never
        // downgrade, restore or manually migrate an installed database.
        try transaction {
            // Reconstruct the actual old schema, not just its migration ledger.
            // Future migrations must add their explicit inverse here; retaining
            // an unknown newer ledger entry makes the fixture assertions fail.
            _ = try execute(sql: "DROP TABLE claude_text_execution_evidence;")
            _ = try execute(sql: "DROP TABLE controlled_memory_text_turns;")
            _ = try execute(sql: "DROP TABLE memory_local_correction_clarifications;")
            _ = try execute(sql: "DROP TABLE memory_local_corrections;")
            _ = try execute(sql: "DROP TABLE memory_conversation_publications;")
            _ = try execute(sql: "DROP TABLE memory_publication_intents;")
            for table in ["teammates", "teammate_profile_revisions"] {
                for column in ["claude_context_window", "claude_effort", "claude_model"] {
                    _ = try execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column);")
                }
            }
            _ = try execute(sql: "DELETE FROM schema_migrations WHERE version IN (15,16,17,18,19,20);")
            for suffix in ["teammate_lifecycle", "conversation_lifecycle", "participant_insert", "participant_update", "participant_delete"] {
                _ = try execute(sql: "DROP TRIGGER bot_sidebar_order_\(suffix);")
            }
            _ = try execute(sql: "DROP VIEW bot_sidebar_active_memberships;")
            _ = try execute(sql: "DROP TABLE bot_sidebar_order;")
            _ = try execute(sql: "DROP TABLE bot_sidebar_order_state;")
            _ = try execute(sql: "DELETE FROM schema_migrations WHERE version=14;")
            if version == 12 {
                _ = try execute(sql: "ALTER TABLE agent_appearances DROP COLUMN built_in_avatar_id;")
                _ = try execute(sql: "DELETE FROM schema_migrations WHERE version=13;")
            }
        }
    }

    func nonOrderingTriggerSignaturesForStartupTest() throws -> [String] {
        try query(sql: "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name NOT LIKE 'bot_sidebar_order_%' ORDER BY name;")
            .map { try $0.text("name") + "|" + $0.text("sql") }
    }
}

@Test(
    "Explicit reopen recovers an absent disposable root with the immutable identities",
    arguments: [OwnedRootKind.caches, .temporary]
)
func compositionRecoversOnlyMissingDisposableRoot(kind: OwnedRootKind) async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let firstContext = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper()
    ).bootstrapAndOpen(
        using: plan,
        protection: .ordinarySQLite,
        decision: decision
    )
    let receiptURL = fixture.layout.installationReceiptURL
    let receiptBefore = try Data(contentsOf: receiptURL)
    var databaseBefore = stat()
    #expect(lstat(fixture.layout.databaseURL.path, &databaseBefore) == 0)

    let missingDescriptor: OwnedRootDescriptor
    switch kind {
    case .caches:
        missingDescriptor = fixture.layout.cacheRoot
    case .temporary:
        missingDescriptor = fixture.layout.temporaryRoot
    case .applicationSupport, .visibleContent:
        Issue.record("Test accepts disposable roots only")
        return
    }
    try FileManager.default.removeItem(at: missingDescriptor.url)

    let reopened = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        disposableRootRecoverer: fixture.bootstrapper()
    ).recoverDisposableRootsAndReopenExisting()

    let recovered = try #require(
        reopened.storageReceipt.verifiedRoots.first(where: { $0.kind == kind })
    )
    #expect(recovered.installationID == plan.installationID)
    #expect(recovered.rootID == plan.rootIDs[kind])
    #expect(reopened.installationReceipt == firstContext.installationReceipt)
    #expect(try Data(contentsOf: receiptURL) == receiptBefore)
    var databaseAfter = stat()
    #expect(lstat(fixture.layout.databaseURL.path, &databaseAfter) == 0)
    #expect(databaseAfter.st_dev == databaseBefore.st_dev)
    #expect(databaseAfter.st_ino == databaseBefore.st_ino)
    #expect(reopened.databaseFacts.protectionMode == .ordinarySQLite)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
}

@Test("Durable teammate identity selection and fixture chat survive a discarded graph and reopen")
func durableSprintOneStateSurvivesRelaunch() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = PreviewDatabaseProtectionDecision.receipt
    let teammateID = TeammateID(
        UUID(uuidString: "87000000-0000-0000-0000-000000000101")!
    )
    let userMessageID = MessageID(
        UUID(uuidString: "87000000-0000-0000-0000-000000000102")!
    )
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 3,
        deterministicSeed: 8_701,
        silhouette: "sprout",
        paletteToken: "violet",
        eyeDialect: "bright",
        nonColorIdentityCue: "leaf ears",
        accessibleIdentityDescription: "Violet sprout creature with leaf ears and bright eyes",
        revision: 4
    )
    let firstKeychain = InMemoryKeychainClient()
    let firstExecutor = CompositionExecutorSpy()

    let recorded: (
        creation: DurableTeammateChatCreationSnapshot,
        exchange: DurableLocalFixtureExchangeSnapshot
    ) = try await {
        let context = try await StoragePersistenceCompositionService(
            layout: fixture.layout,
            bootstrapper: fixture.bootstrapper(),
            keychainClient: firstKeychain,
            teammateExecutor: firstExecutor
        ).bootstrapAndOpen(
            using: plan,
            protection: PreviewDatabaseProtectionDecision.selection,
            decision: decision
        )
        let chat = DurableTeammateChatService(mode: .reviewFixture,
            teammateRepository: context.teammateRepository,
            conversationRepository: context.conversationRepository,
            messageRepository: context.messageRepository,
            provisioningRepository: context.directChatProvisioningRepository,
            selectionRepository: context.chatSelectionRepository,
            clock: CompositionFixedClock(value: Date(timeIntervalSince1970: 8_701))
        )
        let creation = try await chat.createTeammateAndDirectChat(
            DurableTeammateDraft(
                teammateID: teammateID,
                displayName: "Ada",
                role: "Research and synthesis",
                appearance: appearance
            )
        )
        let exchange = try await chat.sendMessageToLocalFixture(
            conversationID: creation.conversation.id,
            teammateID: teammateID,
            userMessageID: userMessageID,
            text: "relaunch-proof-8701"
        )
        return (creation, exchange)
    }()

    #expect(await firstKeychain.recordedOperations().isEmpty)
    #expect(await firstExecutor.calls() == 0)

    let reopenedKeychain = InMemoryKeychainClient()
    let reopenedExecutor = CompositionExecutorSpy()
    let reopenedContext = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        keychainClient: reopenedKeychain,
        teammateExecutor: reopenedExecutor
    ).reopenExisting()
    let reopenedChat = DurableTeammateChatService(mode: .reviewFixture,
        teammateRepository: reopenedContext.teammateRepository,
        conversationRepository: reopenedContext.conversationRepository,
        messageRepository: reopenedContext.messageRepository,
        provisioningRepository: reopenedContext.directChatProvisioningRepository,
        selectionRepository: reopenedContext.chatSelectionRepository
    )

    let activeChats = try await reopenedChat.activeDirectChats()
    let selected = try #require(try await reopenedChat.selectedDirectChat())
    let messages = try await reopenedChat.loadMessages(
        conversationID: recorded.creation.conversation.id,
        beforeSequence: nil,
        limit: 20
    )

    #expect(activeChats.count == 1)
    #expect(activeChats[0].teammate == recorded.creation.teammate)
    #expect(activeChats[0].teammate.id == teammateID)
    #expect(activeChats[0].teammate.appearance == appearance)
    #expect(selected.teammate == recorded.creation.teammate)
    #expect(selected.conversation == recorded.creation.conversation)
    let greeting = try #require(recorded.creation.fixtureGreeting)
    #expect(messages.messages == [
        greeting,
        recorded.exchange.userMessage,
        recorded.exchange.fixtureReply
    ])
    #expect(reopenedContext.protectionSelection == .ordinarySQLite)
    #expect(reopenedContext.protectionDecision == decision)
    #expect(await reopenedKeychain.recordedOperations().isEmpty)
    #expect(await reopenedExecutor.calls() == 0)

    for url in [
        fixture.layout.databaseURL,
        fixture.layout.databaseWALURL,
        fixture.layout.databaseSHMURL
    ] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeCLIProfileRoot.path))
}

@Test("Reopen without an installation receipt fails without creating or opening anything")
func compositionReopenMissingReceiptIsInert() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let opener = FailingRepositoryOpener()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        repositoryOpener: opener
    )

    do {
        _ = try await service.reopenExisting()
        Issue.record("Expected a missing receipt to fail closed")
    } catch let error as StoragePersistenceCompositionError {
        guard case .installationReceiptReadFailed = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }

    #expect(await opener.recordedConfigurations().isEmpty)
    for rootURL in fixture.internalRootURLs {
        #expect(!FileManager.default.fileExists(atPath: rootURL.path))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseURL.path))
}

@Test("Existing-root marker tampering blocks reopen before the database opener")
func compositionReopenFreshlyVerifiesEveryRoot() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    _ = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper()
    ).bootstrapAndOpen(
        using: fixture.plan(),
        protection: .ordinarySQLite,
        decision: fixture.decision()
    )

    try Data("tampered cache marker".utf8).write(
        to: fixture.layout.cacheRoot.ownershipMarkerURL,
        options: .atomic
    )
    let opener = FailingRepositoryOpener()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        repositoryOpener: opener
    )
    do {
        _ = try await service.reopenExisting()
        Issue.record("Expected the changed cache marker to block reopen")
    } catch let error as StoragePersistenceCompositionError {
        guard case let .existingRootVerificationFailed(receipt, kind, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(receipt.installationID == fixture.installationID)
        #expect(kind == .caches)
    }
    #expect(await opener.recordedConfigurations().isEmpty)
}

@Test(
    "Composition freshly verifies every internal ownership marker before opening SQLite",
    arguments: [
        OwnedRootKind.applicationSupport,
        OwnedRootKind.caches,
        OwnedRootKind.temporary
    ]
)
func compositionRejectsPostBootstrapRootTampering(kind: OwnedRootKind) async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let opener = FailingRepositoryOpener()
    let base = fixture.bootstrapper()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: TamperingBootstrapper(base: base, layout: fixture.layout, kind: kind),
        repositoryOpener: opener
    )

    do {
        _ = try await service.bootstrapAndOpen(
            using: fixture.plan(),
            protection: .ordinarySQLite,
            decision: fixture.decision()
        )
        Issue.record("Expected fresh root verification to reject the changed marker")
    } catch let error as StoragePersistenceCompositionError {
        guard case let .ownedRootVerificationFailed(receipt, failedKind, _) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(receipt.installationID == fixture.installationID)
        #expect(failedKind == kind)
    }

    #expect(await opener.recordedConfigurations().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseURL.path))
}

@Test("Unavailable SQLCipher is preserved exactly and never falls back or touches Keychain")
func compositionFailsClosedWhenSQLCipherIsUnavailable() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let opener = SQLCipherRejectingRepositoryOpener()
    let keychain = InMemoryKeychainClient()
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper(),
        repositoryOpener: opener,
        keychainClient: keychain
    )

    do {
        _ = try await service.bootstrapAndOpen(
            using: plan,
            protection: .sqlCipher,
            decision: decision
        )
        Issue.record("Expected unavailable SQLCipher to fail closed")
    } catch let error as StoragePersistenceCompositionError {
        guard case let .databaseProtectionUnavailable(receipt, requested) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(receipt.installationID == plan.installationID)
        #expect(requested == .sqlCipher)
    }

    let configurations = await opener.recordedConfigurations()
    let configuration = try #require(configurations.only)
    #expect(configuration.fileURL == fixture.layout.databaseURL)
    #expect(configuration.protection.mode == .sqlCipher)
    #expect(configuration.protection.decision == decision)
    #expect(await keychain.recordedOperations().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseWALURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.databaseSHMURL.path))
}

@Test("A post-bootstrap database validation failure retains its receipt and published roots")
func databaseFailurePreservesBootstrapReceiptAndRoots() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let plan = try fixture.plan()
    let decision = try fixture.decision()
    let wrongURL = fixture.layout.databaseDirectory.appending(
        path: "Wrong.sqlite",
        directoryHint: .notDirectory
    )
    let service = StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper(),
        repositoryOpener: WrongURLRepositoryOpener(wrongURL: wrongURL)
    )

    do {
        _ = try await service.bootstrapAndOpen(
            using: plan,
            protection: .ordinarySQLite,
            decision: decision
        )
        Issue.record("Expected the unexpected database URL to fail validation")
    } catch let error as StoragePersistenceCompositionError {
        guard case let .databaseValidationFailed(receipt, failure) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(receipt.installationID == plan.installationID)
        #expect(failure == .unexpectedDatabaseURL(expected: fixture.layout.databaseURL, actual: wrongURL))
    }

    for rootURL in fixture.internalRootURLs {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
    #expect(FileManager.default.fileExists(atPath: wrongURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
}

@Test("The default executor remains explicitly unavailable after successful composition")
func defaultExecutorRemainsUnavailable() async throws {
    let fixture = try StoragePersistenceCompositionFixture()
    let context = try await StoragePersistenceCompositionService(
        layout: fixture.layout,
        bootstrapper: fixture.bootstrapper()
    ).bootstrapAndOpen(
        using: fixture.plan(),
        protection: .ordinarySQLite,
        decision: fixture.decision()
    )

    await #expect(throws: ExecutorUnavailableError.self) {
        try await context.teammateExecutor.requestStop(runID: RunID(UUID()))
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
