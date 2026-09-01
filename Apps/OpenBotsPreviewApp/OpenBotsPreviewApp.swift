import Combine
import Darwin
import AppKit
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
import OpenBotsUI
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct OpenBotsPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewApplicationDelegate.self) private var applicationDelegate
    @StateObject private var composition = AppCompositionRoot()
    @StateObject private var settingsNavigation = WorkspaceSettingsNavigation()

    var body: some Scene {
        WindowGroup("OpenBots") {
            PreviewWindow(composition: composition, showClaudeSetup: {
                settingsNavigation.selection = .computer
            })
                .background(WorkspaceWindowReporter { window in
                    applicationDelegate.observeWorkspaceWindow(window)
                })
                .onAppear {
                    applicationDelegate.beginShutdown = { [weak composition] in composition?.beginShutdown() }
                    applicationDelegate.saveAvailableState = { [weak composition] in
                        await composition?.saveAvailableStateForShutdown() ?? true
                    }
                    applicationDelegate.finishShutdown = { [weak composition] in composition?.workspace?.finishShutdown() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Bot") {
                    composition.beginTeammateCreation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(composition.workspace == nil)
            }

            #if DEBUG
            if composition.usesReviewFixtures {
            CommandMenu("Preview") {
                Button("Not Configured") {
                    composition.reviewLaunchState(.notConfigured)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Checking Local State") {
                    composition.reviewLaunchState(.opening)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Ready") {
                    composition.reviewLaunchState(.ready)
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Menu("Recovery") {
                    Button("Installation Receipt") {
                        composition.reviewLaunchState(
                            .recovery(.installationReceiptUnavailable)
                        )
                    }
                    Button("Protected Root") {
                        composition.reviewLaunchState(
                            .recovery(.ownedRootVerificationFailed)
                        )
                    }
                    Button("Database Protection") {
                        composition.reviewLaunchState(
                            .recovery(.databaseProtectionUnavailable)
                        )
                    }
                    Button("Database Open") {
                        composition.reviewLaunchState(
                            .recovery(.databaseOpenFailed)
                        )
                    }
                    Button("Database Validation") {
                        composition.reviewLaunchState(
                            .recovery(.databaseValidationFailed)
                        )
                    }
                }

                Divider()

                Button("Representative Teammate Workspace") {
                    composition.enterWorkspace()
                }
                .keyboardShortcut("4", modifiers: [.command, .option])

                Menu("Selected Teammate Status") {
                    ForEach(TeammateActivityState.allCases, id: \.self) { activity in
                        Button(activity.visibleLabel) {
                            composition.reviewTeammateActivity(activity)
                        }
                    }
                }

                Menu("Appearance Review") {
                    Button("Follow System") {
                        composition.reviewAppearance(nil)
                    }
                    Button("Light") {
                        composition.reviewAppearance(.light)
                    }
                    Button("Dark") {
                        composition.reviewAppearance(.dark)
                    }
                }
            }
            }
            #endif
        }

        Settings {
            WorkspaceSettingsView(navigation: settingsNavigation, model: composition.claudeSetup,
                                usesReviewFixtures: composition.usesReviewFixtures,
                                textRepliesEnabled: !composition.usesReviewFixtures)
        }
    }
}

/// AppKit owns termination. Available state gets one three-second grace;
/// failed/stalled saving cannot veto Quit or leave a hidden running task.
@MainActor
private final class PreviewApplicationDelegate: NSObject, NSApplicationDelegate {
    var beginShutdown: (@MainActor () -> Void)?
    var saveAvailableState: (@MainActor () async -> Bool)?
    var finishShutdown: (@MainActor () -> Void)?
    private let draftQuitGuard = DraftQuitGuard()
    private var workspaceWindows: [ObjectIdentifier: NSObjectProtocol] = [:]

    func observeWorkspaceWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard workspaceWindows[id] == nil else { return }
        workspaceWindows[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            // The observer is delivered on the main queue. Do not defer the
            // admission boundary to another task when Settings stays open.
            MainActor.assumeIsolated {
                guard let self, let observer = self.workspaceWindows.removeValue(forKey: id) else { return }
                NotificationCenter.default.removeObserver(observer)
                // Settings and preview sheets are not workspace windows. A
                // dismissed pane never enters this route.
                if self.workspaceWindows.isEmpty {
                    self.beginShutdown?()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if draftQuitGuard.outcome != nil { return .terminateNow }
        guard let saveAvailableState else { beginShutdown?(); finishShutdown?(); return .terminateNow }
        guard draftQuitGuard.request(begin: { self.beginShutdown?() }, flush: saveAvailableState,
            finish: { self.finishShutdown?() }, reply: { _ in
                // This terminates the app, not just a Swift task. No alert or
                // waiting for a model to finish can keep it alive afterward.
                sender.reply(toApplicationShouldTerminate: true)
            }) else { return .terminateLater }
        return .terminateLater
    }
}

@MainActor
private struct WorkspaceWindowReporter: NSViewRepresentable {
    let report: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reporter { Reporter(report: report) }
    func updateNSView(_ nsView: Reporter, context: Context) {}
    final class Reporter: NSView {
        let report: (NSWindow) -> Void
        init(report: @escaping (NSWindow) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { report(window) } }
    }
}

@MainActor
private final class AppCompositionRoot: ObservableObject {
    private static let knowledgeUnavailableNotice =
        "Local memory couldn't be opened. Your teammates and conversations are still available."

    /// Development scenarios require an explicit launch argument. Normal
    /// Finder/Dock launch never enables canned replies or simulated controls.
    let usesReviewFixtures: Bool
    private var chatMode: LocalChatMode { usesReviewFixtures ? .reviewFixture : .localOnly }

    private let layout: PreviewStorageLayout
    private var claudeSetupSupportRoot: VerifiedOwnedRoot?
    /// Settings owns a separate setup model; local chat/storage readiness never
    /// depends on a Claude connection. Constructing this model performs no I/O.
    lazy var claudeSetup = ClaudeSetupModel(
        service: OfficialClaudeConnectionService(
            inspector: NativeClaudeOfflineSetupInspector(
                layout: layout,
                applicationSupportRoot: { [weak self] in
                    await self?.claudeSetupSupportRoot
                }
            ),
            preparer: NativeClaudeConnectionPreparer(
                layout: layout,
                applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot }
            ),
            admission: UserInitiatedClaudeConnectionAdmission(),
            signInHandoff: NativeClaudeConnectionSignInHandoff(
                layout: layout,
                applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot },
                opener: NativeClaudeTerminalSignInOpener()
            )
        )
    )
    let launchReadiness = LaunchReadinessModel(
        inspector: FixedLaunchReadinessInspector(state: .notConfigured)
    )

    @Published private(set) var workspace: DurableWorkspaceModel?
    @Published private(set) var showsWorkspace = false
    @Published private(set) var reviewColorScheme: ColorScheme?
    @Published private(set) var startupDiagnosticCode: String?
    @Published private(set) var knowledgeAvailabilityNotice: String?
    @Published private(set) var isClosing = false
    @Published private(set) var sessionRecoveryNotice: String?
    @Published private(set) var memoryRecoveryNotice: String?
    private var sessionRecovery: LocalSessionRecoveryService?
    private var didStart = false

    init(layout: PreviewStorageLayout = .live()) {
        self.layout = layout
        #if DEBUG
        usesReviewFixtures = CommandLine.arguments.contains("--review-fixtures")
        #else
        usesReviewFixtures = false
        #endif
    }

    func beginShutdown() {
        guard !isClosing else { return }
        isClosing = true
        claudeSetup.beginShutdown()
        claudeSetupSupportRoot = nil
        workspace?.beginShutdown()
    }

    private func requireOpen() throws {
        guard !isClosing, !Task.isCancelled else { throw CancellationError() }
    }

    func saveAvailableStateForShutdown() async -> Bool {
        let saved = await workspace?.flushForShutdown() ?? true
        guard !Task.isCancelled else { return false }
        let recorded = await sessionRecovery?.finish(saved: saved) ?? false
        return saved && recorded
    }

    func start() async {
        guard !didStart, !isClosing else { return }
        didStart = true
        launchReadiness.setPreviewReviewState(.opening)

        do {
            let context = try await openOrBootstrapPreviewInstallation()
            guard !isClosing, !Task.isCancelled else { return }
            claudeSetupSupportRoot = context.applicationSupportRoot
            let recovery = LocalSessionRecoveryService(repository: context.sessionRecoveryRepository)
            sessionRecovery = recovery
            let previousCloseNotice = await recovery.begin()
            try requireOpen()
            sessionRecoveryNotice = previousCloseNotice
            let attachmentService = await makeAttachmentService(context: context)
            try requireOpen()
            let service = DurableTeammateChatService(
                mode: chatMode,
                teammateRepository: context.teammateRepository,
                conversationRepository: context.conversationRepository,
                messageRepository: context.messageRepository,
                provisioningRepository: context.directChatProvisioningRepository,
                selectionRepository: context.chatSelectionRepository,
                attachmentRepository: context.attachmentRepository,
                attachmentValidator: attachmentService
            )
            let hiringService = HiringConversationService(
                mode: chatMode,
                repository: context.hiringDraftRepository
            )
            let providerTextReplyService: (any ClaudeTextReplyServing)? = usesReviewFixtures ? nil :
                OfficialClaudeTextReplyService(
                    repository: context.textTurnRepository,
                    teammates: context.teammateRepository,
                    conversations: context.conversationRepository,
                    messages: context.messageRepository,
                    preparer: NativeClaudeTextLaunchPreparer(
                        layout: layout,
                        applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot },
                        connection: NativeClaudeConnectionPreparer(
                            layout: layout,
                            applicationSupportRoot: { [weak self] in await self?.claudeSetupSupportRoot }
                        )
                    ),
                    appOwnerID: context.installationReceipt.installationID,
                    context: context.conversationContextRepository,
                    contextReader: context.readContextRepository,
                    contextAssembler: ClaudeContextAssemblyService(memoryReader: { reference, maximumBytes in
                        // Verify and read only when an eligible document is selected.
                        // Missing/malformed optional memory never repairs or blocks chat startup.
                        let root = try AuthoritativeMarkdownRootVerifier().verify(
                            context.applicationSupportRoot.url.appending(
                                path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                directoryHint: .isDirectory),
                            inside: context.applicationSupportRoot)
                        return try await AuthoritativeMarkdownStore(maximumBytes: maximumBytes)
                            .read(reference, inside: root).markdown
                    }),
                    controlledMemory: ControlledMemoryReplyPreparation(
                        memory: context.memoryRepository, intents: context.memoryPublicationIntentRepository,
                        contexts: context.readContextRepository, publications: context.memoryConversationPublicationRepository,
                        messages: context.messageRepository, teammates: context.teammateRepository,
                        authority: {
                            try AuthoritativeMarkdownRootVerifier().verify(
                                context.applicationSupportRoot.url.appending(
                                    path: MemoryAuthorityContract.appOwnedMarkdownV1.relativeRoot,
                                    directoryHint: .isDirectory), inside: context.applicationSupportRoot)
                        })
                )
            let textReplyService: (any ClaudeTextReplyServing)?
            if let providerTextReplyService {
                textReplyService = await context.localMemoryConversationService(fallback: providerTextReplyService) { [weak self] report in
                    await MainActor.run {
                        self?.memoryRecoveryNotice = report.notice
                    }
                }
            } else {
                textReplyService = nil
            }
            try requireOpen()
            // Photo availability is local to the character surface. Missing or
            // unsafe assets must not turn healthy chat storage into global recovery.
            let photoService: ProfilePhotoService?
            let photoRootURL = layout.profileAssetsRoot
            let ownedSupportRoot = context.applicationSupportRoot
            let verifiedPhotoRoot = try? await Task.detached(priority: .userInitiated) {
                try ProfilePhotoRootVerifier().verify(photoRootURL, inside: ownedSupportRoot)
            }.value
            try requireOpen()
            if let photoRoot = verifiedPhotoRoot {
                let store = ProfilePhotoContentStore(root: photoRoot)
                photoService = ProfilePhotoService(
                    repository: context.profilePhotoRepository,
                    importer: { url, id in try await store.importPhoto(from: url, id: id) },
                    reader: { asset in try await store.read(asset) }
                )
            } else {
                photoService = nil
            }
            let photoPresentation = photoService.map { service in
                ProfilePhotoPresentation(loader: { id in try await service.imageData(id: id) })
            }
            let photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)?
            if let service = photoService {
                photoImporter = { [weak self] url in
                    guard let self else { throw CancellationError() }
                    try await self.requireOpen()
                    return try await service.importPhoto(from: url)
                }
            } else {
                photoImporter = nil
            }
            // Work Context is not part of chat. Do not construct its models:
            // a hidden Knowledge loader could quarantine Markdown or seed
            // review content merely because a conversation opens.
            let workspace = DurableWorkspaceModel(
                mode: chatMode,
                service: service,
                textReplyService: textReplyService,
                hiringService: hiringService,
                profileService: TeammateProfileService(
                    repository: context.teammateRepository, photoValidator: photoService
                ),
                archiveService: TeammateArchiveService(repository: context.teammateArchiveRepository),
                sidebarOrderService: BotSidebarOrderService(repository: context.botSidebarOrderRepository),
                draftService: ConversationDraftService(repository: context.conversationDraftRepository),
                searchService: ConversationSearchService(repository: context.conversationSearchRepository),
                photoImporter: photoImporter,
                photoPresentation: photoPresentation,
                attachmentDraftFactory: { conversationID in
                    AttachmentDraftModel(conversationID: conversationID,
                        load: { try await context.attachmentRepository.draft(conversationID: conversationID) },
                        importFile: { url, operationID in
                            guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                            return try await attachmentService.importFile(url, operationID: operationID, conversationID: conversationID)
                        },
                        remove: { id in
                            try await context.attachmentRepository.removeDraftAttachment(id: id, conversationID: conversationID)
                        })
                },
                attachmentPresentation: AttachmentPresentation(
                    resolve: { messageID, partID, attachmentID in
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        return try await attachmentService.attachment(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                    },
                    reveal: { [weak self] messageID, partID, attachmentID in
                        guard let self else { throw CancellationError() }
                        try self.requireOpen()
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        let url = try await attachmentService.revealLocation(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID))
                        try self.requireOpen()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    preview: { messageID, partID, attachmentID, pageNumber in
                        guard let attachmentService else { throw ConversationAttachmentError.unavailable }
                        return try await attachmentService.preview(messageID: MessageID(messageID),
                            partID: MessagePartID(partID), attachmentID: AttachmentID(attachmentID),
                            pageNumber: pageNumber)
                    }
                ),
                cardFixtureFactory: usesReviewFixtures ? SprintTwoCardFixture.make(conversationID:) : nil
            )
            try requireOpen()
            try await workspace.loadInitialWorkspace(
                messageLimit: usesReviewFixtures ? 2 : 100
            )
            guard !isClosing, !Task.isCancelled else { workspace.beginShutdown(); workspace.finishShutdown(); return }
            self.workspace = workspace
            showsWorkspace = true
            startupDiagnosticCode = nil
            knowledgeAvailabilityNotice = nil
            launchReadiness.setPreviewReviewState(.ready)
        } catch {
            guard !isClosing, !Task.isCancelled else { return }
            workspace = nil
            showsWorkspace = false
            startupDiagnosticCode = Self.diagnosticCode(for: error)
            knowledgeAvailabilityNotice = nil
            launchReadiness.setPreviewReviewState(.recovery(Self.recoveryIssue(for: error)))
        }
    }

    /// Explicit app-owned upgrade preparation, off the main actor. Failure is
    /// attachment-local; healthy text chats never enter global recovery for it.
    private func makeAttachmentService(context: StoragePersistenceContext) async -> ConversationAttachmentService? {
        guard let cache = context.storageReceipt.verifiedRoots.first(where: { $0.kind == .caches }) else { return nil }
        let support = context.applicationSupportRoot
        let ingestURL = layout.attachmentIngestRoot
        do {
            let (ingestRoot, contentRoot) = try await Task.detached(priority: .userInitiated) {
                let ingest = try AttachmentIngestRootVerifier().verify(ingestURL, inside: cache)
                let content = try AttachmentContentRootProvisioner().prepare(inside: support)
                return (ingest, content)
            }.value
            try requireOpen()
            let ingestor = AttachmentIngestor()
            let store = AttachmentContentStore(root: contentRoot)
            return ConversationAttachmentService(repository: context.attachmentRepository,
                messages: context.messageRepository,
                importer: { url, id in
                    let receipt = try await ingestor.ingest(AttachmentIngestionRequest(
                        sourceFileURL: url, ingestRoot: ingestRoot, operationID: id.rawValue))
                    do {
                        try Task.checkCancellation()
                        let published = try await store.publish(receipt: receipt, from: ingestRoot, id: id)
                        try Task.checkCancellation()
                        try await ingestor.discard(receipt, inside: ingestRoot)
                        return published
                    } catch {
                        // Only the ingestor's exact still-owned scratch may be
                        // removed. A published immutable file is never rolled back.
                        if !Task.isCancelled { try? await ingestor.discard(receipt, inside: ingestRoot) }
                        throw error
                    }
                },
                verifier: { asset in try await store.verify(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256) },
                location: { asset in try await store.verifiedURL(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256) },
                previewer: { asset, page in
                    try await store.preview(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256,
                        displayName: asset.displayName, typeIdentifier: asset.typeIdentifier, pageNumber: page)
                })
        } catch { return nil }
    }

    func beginTeammateCreation() {
        guard !isClosing, let workspace else { return }
        showsWorkspace = true
        workspace.beginTeammateCreation()
    }

    func reviewLaunchState(_ state: LaunchReadinessState) {
        guard usesReviewFixtures, !isClosing else { return }
        showsWorkspace = false
        launchReadiness.setPreviewReviewState(state)
    }

    func enterWorkspace() {
        guard !isClosing else { return }
        showsWorkspace = workspace != nil
    }

    func reviewTeammateActivity(_ activity: TeammateActivityState) {
        guard usesReviewFixtures, !isClosing, let workspace else { return }
        showsWorkspace = true
        workspace.setSelectedActivity(activity)
    }

    func reviewAppearance(_ colorScheme: ColorScheme?) {
        guard usesReviewFixtures, !isClosing else { return }
        reviewColorScheme = colorScheme
    }

    func retryStartup() {
        guard !isClosing, workspace == nil, launchReadiness.state != .opening else { return }
        didStart = false
        Task { await start() }
    }

    private func openOrBootstrapPreviewInstallation() async throws -> StoragePersistenceContext {
        try requireOpen()
        let roots = [
            layout.applicationSupportRoot.url,
            layout.cacheRoot.url,
            layout.temporaryRoot.url
        ]
        let presence = await Task.detached(priority: .userInitiated) {
            roots.map(Self.pathEntryExists)
        }.value
        try requireOpen()

        if presence.allSatisfy({ !$0 }) {
            let installationID = UUID()
            let rootIDs: [OwnedRootKind: UUID] = [
                .applicationSupport: UUID(),
                .caches: UUID(),
                .temporary: UUID()
            ]
            let plan = try PreviewRootCreationPlan(
                layout: layout,
                installationID: installationID,
                rootIDs: rootIDs
            )
            let composition = StoragePersistenceCompositionService(layout: layout)
            return try await composition.bootstrapAndOpen(
                using: plan,
                protection: PreviewDatabaseProtectionDecision.selection,
                decision: PreviewDatabaseProtectionDecision.receipt
            )
        }

        // Only an entirely absent installation may be created. Application
        // Support remains durable authority. The explicit recovery transition
        // may recreate a wholly absent cache or temporary root with the IDs in
        // the immutable receipt; any existing mismatch still fails closed.
        guard presence[0] else { throw PreviewStartupError.partialInstallation }
        let composition = StoragePersistenceCompositionService(layout: layout)
        return try await composition.recoverDisposableRootsAndReopenExisting()
    }

    nonisolated private static func pathEntryExists(_ url: URL) -> Bool {
        var information = stat()
        return url.path.withCString { lstat($0, &information) == 0 }
    }

    nonisolated private static func recoveryIssue(for error: any Error) -> LaunchRecoveryIssue {
        if error is StorageBootstrapError || error is PreviewStartupError {
            return .ownedRootVerificationFailed
        }
        guard let error = error as? StoragePersistenceCompositionError else {
            return .databaseOpenFailed
        }
        switch error {
        case .installationReceiptReadFailed:
            return .installationReceiptUnavailable
        case .invalidPlan, .invalidBootstrapReceipt, .ownedRootVerificationFailed,
             .existingRootVerificationFailed, .disposableRootRecoveryFailed,
             .installationReceiptPublicationFailed:
            return .ownedRootVerificationFailed
        case .databaseProtectionUnavailable:
            return .databaseProtectionUnavailable
        case .databaseOpenFailed:
            return .databaseOpenFailed
        case .databaseInspectionFailed, .databaseValidationFailed:
            return .databaseValidationFailed
        case .alreadyAttempted:
            return .databaseOpenFailed
        }
    }

    nonisolated private static func diagnosticCode(for error: any Error) -> String {
        if let error = error as? StorageBootstrapError {
            switch error {
            case .invalidPlan:
                return "storage-plan-invalid"
            case let .locationInspectionFailed(kind, _):
                return "storage-location-inspection-\(kind.rawValue)"
            case let .unsafeHighChurnLocation(kind, violation):
                return "storage-location-\(kind.rawValue)-\(String(describing: violation))"
            case let .filesystemPreflightFailed(kind, reason):
                return "storage-preflight-\(kind.rawValue)-\(Self.safeDiagnosticComponent(reason))"
            case let .stagingFailed(kind, _):
                return "storage-staging-\(kind.rawValue)"
            case let .publicationFailed(kind, _, _):
                return "storage-publication-\(kind.rawValue)"
            case let .verificationFailed(kind, _):
                return "storage-verification-\(kind.rawValue)"
            }
        }
        if let error = error as? PreviewStartupError {
            switch error {
            case .partialInstallation:
                return "storage-partial-installation"
            case .attachmentIngestUnavailable:
                return "storage-attachment-ingest-root"
            }
        }
        if let error = error as? StoragePersistenceCompositionError {
            switch error {
            case .alreadyAttempted: return "composition-already-attempted"
            case .invalidPlan: return "composition-plan-invalid"
            case .invalidBootstrapReceipt: return "composition-bootstrap-receipt"
            case let .ownedRootVerificationFailed(_, kind, _):
                return "composition-root-\(kind.rawValue)"
            case .installationReceiptPublicationFailed:
                return "composition-installation-receipt-publication"
            case .installationReceiptReadFailed:
                return "composition-installation-receipt-read"
            case let .existingRootVerificationFailed(_, kind, _):
                return "composition-existing-root-\(kind.rawValue)"
            case .disposableRootRecoveryFailed:
                return "composition-disposable-root-recovery"
            case .databaseProtectionUnavailable:
                return "composition-database-protection"
            case .databaseOpenFailed:
                return "composition-database-open"
            case .databaseInspectionFailed:
                return "composition-database-inspection"
            case .databaseValidationFailed:
                return "composition-database-validation"
            }
        }
        return "startup-unexpected"
    }

    nonisolated private static func safeDiagnosticComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private static func unavailableKnowledgeModel() -> KnowledgeWorkspaceModel {
        KnowledgeWorkspaceModel(
            loader: { _ in throw PreviewKnowledgeUnavailableError.authorityVerificationFailed },
            revealer: { _, _ in
                throw PreviewKnowledgeUnavailableError.authorityVerificationFailed
            },
            chooseSnapshotDestination: { _ in nil },
            createSnapshot: { _, _ in
                throw PreviewKnowledgeUnavailableError.authorityVerificationFailed
            },
            releaseSnapshotDestination: { _ in }
        )
    }

    nonisolated private static func knowledgePresentation(
        _ snapshot: MemoryKnowledgeWorkspaceSnapshot,
        context: KnowledgeWorkspaceContext
    ) -> KnowledgeWorkspaceSnapshot {
        KnowledgeWorkspaceSnapshot(
            id: snapshot.id,
            context: context,
            documents: snapshot.documents.map { item in
                let scope: KnowledgeDocumentScopePresentation
                switch item.document.scope {
                case .user:
                    scope = .user
                case let .teammate(teammateID):
                    scope = .teammate(
                        id: teammateID.rawValue,
                        name: teammateID.rawValue == context.teammateID
                            ? context.teammateName
                            : "Teammate"
                    )
                case let .project(projectID):
                    scope = .project(
                        id: projectID.rawValue,
                        name: projectID.rawValue == context.selectedProjectID
                            ? (context.selectedProjectName ?? "Selected project")
                            : "Project"
                    )
                }

                let author: KnowledgeDocumentAuthorPresentation
                switch item.document.author {
                case .user:
                    author = .user(displayName: "Lorenzo")
                case let .teammate(teammateID):
                    author = .teammate(
                        id: teammateID.rawValue,
                        name: teammateID.rawValue == context.teammateID
                            ? context.teammateName
                            : "Teammate"
                    )
                case .system:
                    author = .system(label: "OpenBots")
                }

                let recovery: KnowledgeDocumentRecoveryPresentation
                if let unavailableRevision = item.unavailableNewerRevision {
                    recovery = .lastKnownGood(
                        unavailableRevision: unavailableRevision,
                        explanation: "The current revision could not be verified, so OpenBots is showing the last known good revision."
                    )
                } else {
                    recovery = .current
                }
                return KnowledgeDocumentPresentation(
                    id: item.document.id.rawValue,
                    title: item.document.title,
                    scope: scope,
                    author: author,
                    revision: item.document.revision,
                    updatedAt: item.document.updatedAt,
                    markdown: item.markdown,
                    recovery: recovery
                )
            },
            excludedDocumentCount: snapshot.excludedDocumentCount
        )
    }

    private static func chooseKnowledgeSnapshotDestination(
        suggestedFileName: String
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Create Non-Authoritative Knowledge Snapshot"
        panel.message = "Choose one exact local file. OpenBots will create a new snapshot and never overwrite an existing item."
        panel.prompt = "Choose"
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}

private enum PreviewStartupError: Error {
    case partialInstallation
    case attachmentIngestUnavailable
}

private actor PreviewKnowledgeSeeder {
    private let repository: any MemoryRepository

    init(repository: any MemoryRepository) {
        self.repository = repository
    }

    func ensureSampleKnowledge(
        for context: KnowledgeWorkspaceContext,
        using service: MemoryKnowledgeService
    ) async throws {
        if try await repository.documents(scope: .user).isEmpty {
            _ = try await service.publishRevision(
                title: "How Lorenzo likes updates",
                scope: .user,
                author: .user,
                markdown: """
                # How Lorenzo likes updates

                This is preview sample knowledge stored in the real app-owned Markdown authority.

                Prefer short, plain-English milestone updates with verified outcomes and honest limitations.
                """
            )
        }

        let teammateID = TeammateID(context.teammateID)
        let teammateScope = MemoryScope.teammate(teammateID)
        if try await repository.documents(scope: teammateScope).isEmpty {
            _ = try await service.publishRevision(
                title: "\(context.teammateName)’s working approach",
                scope: teammateScope,
                author: .teammate(teammateID),
                markdown: """
                # \(context.teammateName)’s working approach

                This is preview sample knowledge stored in the real app-owned Markdown authority.

                Keep evidence traceable, surface blockers early, and return finished work in the active conversation.
                """
            )
        }

        if let selectedProjectID = context.selectedProjectID,
           context.activeProjectMembershipIDs.contains(selectedProjectID) {
            let projectID = ProjectID(selectedProjectID)
            let projectScope = MemoryScope.project(projectID)
            if try await repository.documents(scope: projectScope).isEmpty {
                let projectName = context.selectedProjectName ?? "Selected project"
                _ = try await service.publishRevision(
                    title: "\(projectName) brief",
                    scope: projectScope,
                    author: .user,
                    markdown: """
                    # \(projectName) brief

                    This is preview sample knowledge stored in the real app-owned Markdown authority.

                    Project memory is available only while the teammate is an active member of this selected project.
                    """
                )
            }
        }
    }
}

private enum PreviewKnowledgeUnavailableError: Error {
    case authorityVerificationFailed
}

private struct PreviewWindow: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var composition: AppCompositionRoot
    let showClaudeSetup: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if composition.usesReviewFixtures {
                reviewFixtureBanner
            }
            if composition.isClosing {
                Text("Closing OpenBots. Saving available local changes briefly…")
                    .font(.callout).padding(8).accessibilityAddTraits(.updatesFrequently)
            } else if let notice = composition.sessionRecoveryNotice {
                Text(notice).font(.callout).padding(8).fixedSize(horizontal: false, vertical: true)
            }
            if !composition.isClosing, let notice = composition.memoryRecoveryNotice {
                Text(notice).font(.callout).padding(8).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Local memory recovery. " + notice)
            }
            if composition.usesReviewFixtures || composition.isClosing
                || composition.sessionRecoveryNotice != nil || composition.memoryRecoveryNotice != nil {
                Divider()
            }
            content
                .disabled(composition.isClosing)
        }
        .preferredColorScheme(composition.reviewColorScheme ?? .dark)
        .task {
            await composition.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if composition.showsWorkspace {
            if let workspace = composition.workspace {
                DurableWorkspaceView(
                    model: workspace,
                    openSettings: { openSettings() },
                    openClaudeSetup: {
                        showClaudeSetup()
                        openSettings()
                    }
                )
            }
        } else {
            LaunchStatusView(
                model: composition.launchReadiness,
                performsAutomaticRefresh: false,
                isApplicationStartup: !composition.usesReviewFixtures,
                retryAction: composition.retryStartup,
                continueAction: composition.enterWorkspace
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewFixtureBanner: some View {
        Label(
            reviewFixtureDisclosure,
            systemImage: "externaldrive.badge.checkmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityLabel(reviewFixtureDisclosure)
    }

    private var reviewFixtureDisclosure: String {
        let base: String
        if composition.showsWorkspace {
            base = "Durable local preview — teammates and conversations use protected ordinary SQLite. Replies, hiring guidance, and inline cards remain local fixtures. The app runtime, real Keychain client, provider authentication, and network remain disabled."
        } else {
            base = "Local preview startup — app-owned storage may be verified or created. The app runtime, real Keychain client, and network remain disabled."
        }
        return base
            + (composition.startupDiagnosticCode.map { " Recovery code: \($0)." } ?? "")
    }
}
