import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// One process-local card row and the exact conversation-scoped action
/// registry that owns it. The row is presentation-only: it is never passed to
/// a message repository or included in keyset paging.
@MainActor
public struct ConversationCardFixturePresentation {
    public let message: ChatMessageSnapshot
    public let interactions: ConversationCardInteractionModel

    public init(
        message: ChatMessageSnapshot,
        interactions: ConversationCardInteractionModel
    ) {
        self.message = message
        self.interactions = interactions
    }
}

/// Screen-scoped orchestration for the durable Sprint 1 teammate/chat loop.
/// Repositories remain behind `DurableTeammateChatServing`; this model owns
/// presentation identity, selection generations, and row-local updates only.
@MainActor
public final class DurableWorkspaceModel: ObservableObject {
    public static let fixtureDeliveryDescription =
        "Messages save locally at once; replies are a preview fixture. Claude and tools are not running."
    public static let localDeliveryDescription =
        "Claude isn’t connected. Save messages and attachments on this Mac; drafts and history remain available. Nothing is sent automatically."
    public static let textReplyDeliveryDescription =
        "Memory questions and explicit memory updates are handled on this Mac. Other messages use Claude when their context can be published safely. Attachments, tools and connectors are not sent."
    public let mode: LocalChatMode

    public let sidebar: SidebarModel
    public let collaborationModel: CollaborationWorkspaceModel?
    public let knowledgeModel: KnowledgeWorkspaceModel?
    public let trustAuthorizationModel: TrustAuthorizationWorkspaceModel?
    public let runRecoveryModel: RunRecoveryWorkspaceModel?
    public let actionProposalModel: ActionProposalWorkspaceModel?
    public let savedOutcomeHistoryModel: SavedOutcomeHistoryModel?
    public let photoPresentation: ProfilePhotoPresentation?
    public let attachmentPresentation: AttachmentPresentation?
    public let archiveModel: BotArchiveModel?
    @Published public private(set) var attachmentDraft: AttachmentDraftModel
    @Published public private(set) var cardInteractions: ConversationCardInteractionModel?
    public private(set) lazy var conversation = makeConversationModel()

    @Published public var hiringModel: HiringConversationModel?
    @Published public private(set) var profileEditor: TeammateProfileEditorModel?
    @Published public private(set) var isBotDetailsPresented = false
    @Published public private(set) var isCreatingTeammate = false
    @Published public private(set) var creationError: String?
    private var creationTask: Task<Void, Never>?

    private let service: any DurableTeammateChatServing
    private let textReplyService: (any ClaudeTextReplyServing)?
    fileprivate lazy var textReplyCoordinator: ClaudeTextReplyCoordinator? = textReplyService.map {
        ClaudeTextReplyCoordinator(service: $0) { [weak self] in self?.refreshTextReplyPhase() }
    }
    private var deliveryNotices: [UUID: String] = [:]
    private var provenanceRequests: [ConversationID: [MessageID: UUID]] = [:]
    private var textTurnReplyMessageIDs: Set<UUID> = []
    private var liveSavedMessages: [UUID: [UUID: Message]] = [:]
    private let hiringService: any HiringConversationServing
    private let profileService: (any TeammateProfileEditing)?
    private let draftService: (any ConversationDraftServing)?
    private let searchService: (any ConversationSearchServing)?
    private let sidebarOrderService: (any BotSidebarOrdering)?
    public private(set) lazy var sidebarOrderCoordinator: WorkspaceSidebarOrderCoordinator? = sidebarOrderService.map {
        WorkspaceSidebarOrderCoordinator(sidebar: sidebar, service: $0) { [weak self] in
            guard let self else { return false }
            return !self.isShuttingDown && self.hiringModel == nil && self.archiveModel?.isBusy != true
        }
    }
    public private(set) lazy var searchCoordinator: WorkspaceSearchCoordinator? = {
        guard let searchService else { return nil }
        return WorkspaceSearchCoordinator(service: searchService) { [weak self] destination, isCurrent in
            guard let self else { throw SearchNavigationError.unavailable }
            try await self.openSearchDestination(destination, isCurrent: isCurrent)
        }
    }()
    public private(set) lazy var draftCoordinator: WorkspaceDraftCoordinator? = draftService.map {
        WorkspaceDraftCoordinator(conversation: conversation, service: $0)
    }
    private let photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)?
    private var profileDrafts: [UUID: TeammateProfileEditorModel] = [:]
    private let attachmentImporter: AttachmentDraftModel.Importer
    private let attachmentDraftFactory: WorkspaceAttachmentCoordinator.Factory?
    public private(set) lazy var attachmentCoordinator: WorkspaceAttachmentCoordinator? = attachmentDraftFactory.map {
        WorkspaceAttachmentCoordinator(conversation: conversation, factory: $0)
    }
    private let cardFixtureFactory: (@MainActor (UUID) -> ConversationCardFixturePresentation?)?
    private let unscopedAttachmentDraft: AttachmentDraftModel
    private var directChatsByTeammate: [UUID: DurableDirectChatSnapshot] = [:]
    private var messageSequenceByID: [UUID: Int64] = [:]
    private var composerDraftByConversationID: [UUID: String] = [:]
    private var attachmentDraftByConversationID: [UUID: AttachmentDraftModel] = [:]
    private var cardFixtureByConversationID: [UUID: ConversationCardFixturePresentation] = [:]
    private var admittedCollaborationFixtureIDByConversationID: [UUID: UUID] = [:]
    private var activeFixtureExchangeCountByTeammate: [UUID: Int] = [:]
    private var searchOriginatedSubmissions: [UUID: (requestID: UUID, generation: UInt64)] = [:]
    private var selectionBeforeHiring: UUID?
    private var selectionGeneration: UInt64 = 0
    // Retain the exact navigation operation so local integration checks can
    // join its completion rather than assuming a number of scheduler turns.
    private(set) var selectionTask: Task<Void, Never>?
    private var messagePageLimit = 100
    private var suppressSelectionObservation = false
    private var cancellables: Set<AnyCancellable> = []
    @Published public private(set) var isShuttingDown = false
    private var didFinishShutdown = false
    private var shutdownTasks: [Task<Bool, Never>] = []

    /// Synchronous freeze. No new save/import/send is admitted after this turn.
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        sidebar.cancelCreationReveal()
        textReplyCoordinator?.beginShutdown()
        sidebarOrderCoordinator?.beginShutdown()
        selectionGeneration &+= 1
        searchCoordinator?.close()
        hiringModel?.beginShutdown()
        profileDrafts.values.forEach { $0.beginShutdown() }
        conversation.beginShutdown()
        draftCoordinator?.beginShutdown()
        attachmentCoordinator?.beginShutdown()
        unscopedAttachmentDraft.beginShutdown()
        for model in attachmentDraftByConversationID.values { model.beginShutdown() }
        runRecoveryModel?.beginShutdown()
        actionProposalModel?.beginShutdown()
        savedOutcomeHistoryModel?.beginShutdown()
    }

    public func flushForShutdown() async -> Bool {
        beginShutdown()
        guard !didFinishShutdown, shutdownTasks.isEmpty else { return false }
        // Independent mechanical saves share the guard's one deadline. Waiting
        // on a stalled adapter never renews it; finish cancels every handle.
        shutdownTasks = [
            Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.conversation.settleForShutdown()
            },
            Task { @MainActor [weak self] in await self?.draftCoordinator?.flushForShutdown() ?? true },
            Task { @MainActor [weak self] in await self?.attachmentCoordinator?.settleForShutdown() ?? true },
            Task { @MainActor [weak self] in await self?.runRecoveryModel?.flushForShutdown() ?? true }
        ]
        var saved = true
        for task in shutdownTasks { if !(await task.value) { saved = false } }
        let unsavedEditors = profileDrafts.values.contains(where: \.hasUnsavedChanges)
            || !(hiringModel?.composerText.isEmpty ?? true)
        return saved && !isCreatingTeammate && !unsavedEditors && !didFinishShutdown && !Task.isCancelled
    }

    public func finishShutdown() {
        beginShutdown()
        guard !didFinishShutdown else { return }
        didFinishShutdown = true
        shutdownTasks.forEach { $0.cancel() }
        shutdownTasks.removeAll()
        conversation.finishShutdown()
        draftCoordinator?.finishShutdown()
        attachmentCoordinator?.finishShutdown()
        unscopedAttachmentDraft.finishShutdown()
        attachmentDraftByConversationID.values.forEach { $0.finishShutdown() }
        runRecoveryModel?.finishShutdown()
    }

    public init(
        mode: LocalChatMode = .localOnly,
        service: any DurableTeammateChatServing,
        textReplyService: (any ClaudeTextReplyServing)? = nil,
        hiringService: any HiringConversationServing,
        profileService: (any TeammateProfileEditing)? = nil,
        archiveService: (any TeammateArchiving)? = nil,
        sidebarOrderService: (any BotSidebarOrdering)? = nil,
        draftService: (any ConversationDraftServing)? = nil,
        searchService: (any ConversationSearchServing)? = nil,
        photoImporter: (@Sendable (URL) async throws -> ProfilePhotoAsset)? = nil,
        photoPresentation: ProfilePhotoPresentation? = nil,
        attachmentImporter: AttachmentDraftModel.Importer? = nil,
        attachmentDraftFactory: WorkspaceAttachmentCoordinator.Factory? = nil,
        attachmentPresentation: AttachmentPresentation? = nil,
        cardFixtureFactory: (@MainActor (UUID) -> ConversationCardFixturePresentation?)? = nil,
        collaborationModel: CollaborationWorkspaceModel? = nil,
        knowledgeModel: KnowledgeWorkspaceModel? = nil,
        trustAuthorizationModel: TrustAuthorizationWorkspaceModel? = nil,
        runRecoveryModel: RunRecoveryWorkspaceModel? = nil,
        actionProposalModel: ActionProposalWorkspaceModel? = nil,
        savedOutcomeHistoryModel: SavedOutcomeHistoryModel? = nil
    ) {
        self.mode = mode
        self.service = service
        self.textReplyService = mode == .localOnly ? textReplyService : nil
        self.hiringService = hiringService
        self.profileService = profileService
        archiveModel = archiveService.map(BotArchiveModel.init(service:))
        self.draftService = draftService
        self.searchService = searchService
        self.sidebarOrderService = sidebarOrderService
        self.photoImporter = photoImporter
        self.photoPresentation = photoPresentation
        self.attachmentDraftFactory = attachmentDraftFactory
        self.attachmentPresentation = attachmentPresentation
        self.cardFixtureFactory = cardFixtureFactory
        self.collaborationModel = collaborationModel
        self.knowledgeModel = knowledgeModel
        self.trustAuthorizationModel = trustAuthorizationModel
        self.runRecoveryModel = runRecoveryModel
        self.actionProposalModel = actionProposalModel
        self.savedOutcomeHistoryModel = savedOutcomeHistoryModel
        let resolvedAttachmentImporter = attachmentImporter ?? { _, _ in
            throw AttachmentDraftUnavailableError()
        }
        self.attachmentImporter = resolvedAttachmentImporter
        sidebar = SidebarModel()
        let unscopedAttachmentDraft = AttachmentDraftModel(
            importer: { _, _ in throw AttachmentDraftUnavailableError() }
        )
        self.unscopedAttachmentDraft = unscopedAttachmentDraft
        attachmentDraft = unscopedAttachmentDraft

        archiveModel?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        sidebar.$selection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] selection in
                // Combine publishes this assignment synchronously on the main
                // actor. Capture suppression now; checking in the later Task
                // would let programmatic restore/create updates escape it.
                guard let self, !self.suppressSelectionObservation else { return }
                // The panel is derived from the selected UUID, while its draft
                // remains owned by the original UUID through navigation.
                if self.profileEditor?.teammateID.rawValue != selection {
                    self.profileEditor = nil
                }
                if selection == nil { self.isBotDetailsPresented = false }
                self.objectWillChange.send()
                // A published selection must revoke the old read scope before
                // any queued history completion or navigation task can run.
                self.selectionGeneration &+= 1
                let generation = self.selectionGeneration
                self.savedOutcomeHistoryModel?.activateScope(nil)
                self.selectionTask = Task { @MainActor [weak self] in
                    await self?.selectionChanged(to: selection, generation: generation)
                }
            }
            .store(in: &cancellables)

        collaborationModel?.$reviewPresentation
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshVisibleCollaborationFixture()
            }
            .store(in: &cancellables)

        collaborationModel?.$selectedProjectID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // `@Published` emits from `willSet`. Recompute on the next
                // main-actor turn so `selectedProject` reflects the new ID,
                // never the project scope that was just replaced.
                Task { @MainActor [weak self] in
                    self?.activateKnowledgeContext(for: self?.conversation.conversationID)
                }
            }
            .store(in: &cancellables)
    }

    /// Loads only the current roster, selected direct chat, and its newest page.
    public func loadInitialWorkspace(messageLimit: Int = 100) async throws {
        guard !isShuttingDown, !Task.isCancelled else { return }
        _ = sidebarOrderCoordinator
        messagePageLimit = min(max(messageLimit, 1), 500)
        let chats = try await service.activeDirectChats()
        guard !isShuttingDown, !Task.isCancelled else { return }
        let selected = try await service.selectedDirectChat()
        guard !isShuttingDown, !Task.isCancelled else { return }
        directChatsByTeammate = Dictionary(
            uniqueKeysWithValues: chats.map { ($0.teammate.id.rawValue, $0) }
        )
        sidebar.replace(rows: chats.map(Self.rowSnapshot))
        collaborationModel?.replaceAvailableTeammates(
            chats.map { TeammateIdentitySnapshot($0.teammate) }
        )
        await collaborationModel?.load()
        guard !isShuttingDown, !Task.isCancelled else { return }

        guard let selected else {
            setSelectionWithoutPersistence(nil)
            showConversation(
                conversationID: nil,
                title: "Conversation",
                messages: []
            )
            conversation.setInputAvailability(
                .unavailable(
                    reason: chats.isEmpty
                        ? "Create a teammate to begin. Claude and tools remain disabled."
                        : "Choose a teammate to open its local conversation."
                )
            )
            return
        }

        let selectedChat = DurableDirectChatSnapshot(
            teammate: selected.teammate,
            conversation: selected.conversation
        )
        directChatsByTeammate[selected.teammate.id.rawValue] = selectedChat
        setSelectionWithoutPersistence(selected.teammate.id.rawValue)
        try await show(
            selectedChat,
            messageLimit: messageLimit,
            expectedGeneration: selectionGeneration
        )
    }

    public func beginTeammateCreation() {
        guard !isShuttingDown, archiveModel?.isBusy != true, !isCreatingTeammate, creationTask == nil else { return }
        if mode == .reviewFixture {
            beginHiringFixture()
            return
        }
        guard hiringModel == nil else { return }
        searchCoordinator?.close()
        let generation = selectionGeneration
        creationTask = Task { @MainActor [weak self] in
            await self?.createTeammateImmediately(expectedSelectionGeneration: generation)
            self?.creationTask = nil
        }
    }

    /// Explicit local creation; semantic profile inference remains unavailable.
    /// The service commits the identity, empty chat and selection atomically.
    public func createTeammateImmediately() async {
        guard mode == .localOnly, !isShuttingDown, archiveModel?.isBusy != true, !isCreatingTeammate,
              hiringModel == nil, creationTask == nil else { return }
        searchCoordinator?.close()
        await createTeammateImmediately(expectedSelectionGeneration: selectionGeneration)
    }

    private func createTeammateImmediately(expectedSelectionGeneration: UInt64) async {
        guard mode == .localOnly, !isShuttingDown, !isCreatingTeammate, hiringModel == nil else { return }
        isCreatingTeammate = true
        creationError = nil
        defer { isCreatingTeammate = false }
        // Finish navigation already admitted before New Bot. A failed create
        // must not strand the prior chat in an interrupted loading state.
        await selectionTask?.value
        guard !isShuttingDown else { return }
        do {
            let id = UUID()
            let seed = id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            let character = CharacterAppearanceSnapshot.newlyAllocated(seed: seed)
            let appearance = try AgentAppearance(
                mode: character.mode, grammarVersion: character.grammarVersion,
                deterministicSeed: character.deterministicSeed,
                silhouette: character.silhouette, paletteToken: character.paletteToken,
                eyeDialect: character.eyeDialect, nonColorIdentityCue: character.nonColorIdentityCue,
                accessibleIdentityDescription: character.accessibleIdentityDescription,
                builtInAvatarID: character.builtInAvatarID,
                revision: character.revision
            )
            let created = try await service.createTeammateAndDirectChat(.init(
                teammateID: TeammateID(id), role: "Not configured",
                appearance: appearance
            ))
            guard !isShuttingDown else { return }
            let chat = DurableDirectChatSnapshot(teammate: created.teammate, conversation: created.conversation)
            directChatsByTeammate[created.teammate.id.rawValue] = chat
            sidebar.replace(rows: [Self.rowSnapshot(chat)] + sidebar.rows.filter { $0.id != created.teammate.id.rawValue })
            collaborationModel?.replaceAvailableTeammates(
                directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) }
            )
            // A newer navigation intent wins even when provisioning commits
            // after it. Repair persistence only: reloading the current chat
            // would discard an exact search result or unfinished panel route.
            guard expectedSelectionGeneration == selectionGeneration else {
                let repairGeneration = selectionGeneration
                let selectedID = sidebar.selection
                do {
                    if let selectedID {
                        guard let selectedChat = directChatsByTeammate[selectedID] else {
                            throw DurableTeammateChatError.teammateUnavailable(TeammateID(selectedID))
                        }
                        try await service.select(
                            teammateID: selectedChat.teammate.id,
                            conversationID: selectedChat.conversation.id
                        )
                    } else {
                        try await service.clearSelection()
                    }
                } catch {
                    guard !isShuttingDown, repairGeneration == selectionGeneration,
                          sidebar.selection == selectedID else { return }
                    creationError = "Bot created, but the current selection couldn’t be saved. Your open chat and drafts are preserved."
                }
                return
            }
            profileEditor = nil // Keep independently owned unfinished drafts.
            isBotDetailsPresented = false
            setSelectionWithoutPersistence(created.teammate.id.rawValue)
            showConversation(
                conversationID: created.conversation.id.rawValue,
                title: created.teammate.profile.displayName, messages: [],
                hasEarlierMessages: false, includesFixtures: false
            )
            conversation.setInputAvailability(.ready)
            sidebar.requestCreationReveal(created.teammate.id.rawValue)
        } catch {
            guard !isShuttingDown else { return }
            creationError = "Couldn’t create the bot. Your current chat and drafts are unchanged."
        }
    }

    /// Explicit development fixture entry; normal New Bot never enters hiring.
    public func beginHiringFixture() {
        guard !isShuttingDown, !isCreatingTeammate else { return }
        searchCoordinator?.close()
        guard hiringModel == nil else { return }
        profileEditor = nil
        isBotDetailsPresented = false
        // A newer sidebar click may still be queued. Cancellation must return
        // to the resolved conversation whose transcript and draft stay mounted.
        selectionBeforeHiring = teammateID(for: conversation.conversationID)
        hiringModel = HiringConversationModel(service: hiringService, mode: mode)
        trustAuthorizationModel?.activateContext(nil)
        runRecoveryModel?.activateConversation(nil)
        actionProposalModel?.activateConversation(nil)
        savedOutcomeHistoryModel?.activateScope(nil)
        setSelectionWithoutPersistence(nil)
    }

    public var canEditSelectedProfile: Bool {
        !isShuttingDown && archiveModel?.isBusy != true && profileService != nil && sidebar.selection != nil && hiringModel == nil
    }

    var supportsBotProfileEditing: Bool { profileService != nil }

    func requestBotSettings(id: UUID) {
        enqueueBotContextAction { await $0.openBotSettings(id: id) }
    }

    func requestBotArchive(id: UUID) {
        enqueueBotContextAction { await $0.archiveBot(id: id) }
    }

    private func enqueueBotContextAction(
        _ action: @escaping @MainActor (DurableWorkspaceModel) async -> Void
    ) {
        let generation = selectionGeneration
        Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown,
                  generation == self.selectionGeneration else { return }
            await action(self)
        }
    }

    /// Context-menu construction never calls these routes. An explicit item
    /// selects its captured bot, then rechecks navigation before acting.
    public func openBotSettings(id: UUID) async {
        guard profileService != nil, await selectBotForContextAction(id) else { return }
        editSelectedProfile()
    }

    public func archiveBot(id: UUID) async {
        guard archiveModel != nil, await selectBotForContextAction(id) else { return }
        await archiveSelectedBot()
    }

    private func selectBotForContextAction(_ id: UUID) async -> Bool {
        guard !isShuttingDown, !isCreatingTeammate, archiveModel?.isBusy != true,
              let target = directChatsByTeammate[id],
              sidebar.rowModels.contains(where: { $0.id == id }) else { return false }
        if sidebar.selection != id { sidebar.selection = id }
        let generation = selectionGeneration
        let navigation = selectionTask
        await navigation?.value
        return !Task.isCancelled && !isShuttingDown && !isCreatingTeammate
            && archiveModel?.isBusy != true && generation == selectionGeneration
            && sidebar.selection == id
            && directChatsByTeammate[id]?.conversation.id == target.conversation.id
            && conversation.conversationID == target.conversation.id.rawValue
            && conversation.inputAvailability == .ready
    }

    public var selectedTeammate: Teammate? {
        guard let id = sidebar.selection else { return nil }
        return directChatsByTeammate[id]?.teammate
    }

    public var canArchiveSelectedBot: Bool {
        !isShuttingDown && archiveModel != nil && archiveModel?.isBusy == false
            && selectedTeammate != nil && hiringModel == nil && !isCreatingTeammate
    }

    public func archiveSelectedBot() async {
        guard canArchiveSelectedBot, let teammate = selectedTeammate, let archiveModel else { return }
        let generation = selectionGeneration
        let originalConversation = conversation.conversationID
        let saved = await archiveModel.archive(teammate) { [self] in
            let editor = profileDrafts[teammate.id.rawValue]
            guard editor?.isImportingPhoto != true, editor?.isSaving != true else {
                throw ArchivePreparationError.profileOperationPending
            }
            guard profileDrafts[teammate.id.rawValue]?.hasUnsavedChanges != true else {
                throw ArchivePreparationError.unfinishedEdits
            }
            guard !conversation.hasPendingSubmissions,
                  activeFixtureExchangeCountByTeammate[teammate.id.rawValue, default: 0] == 0,
                  !attachmentDraft.rows.contains(where: { row in
                      if row.isRemoving { return true }
                      if case .pending = row.state { return true }
                      return false
                  }) else { throw ArchivePreparationError.unresolvedLocalWork }
            if let draftCoordinator {
                guard await draftCoordinator.flushAll() else { throw ArchivePreparationError.draftNotSaved }
            } else if !conversation.composerText.isEmpty {
                throw ArchivePreparationError.draftNotSaved
            }
            guard !isShuttingDown, generation == selectionGeneration,
                  originalConversation == conversation.conversationID,
                  sidebar.selection == teammate.id.rawValue,
                  !conversation.hasPendingSubmissions else { throw ArchivePreparationError.navigationChanged }
        }
        guard saved != nil, !isShuttingDown else { return }
        directChatsByTeammate.removeValue(forKey: teammate.id.rawValue)
        if profileDrafts[teammate.id.rawValue]?.hasUnsavedChanges != true {
            profileDrafts.removeValue(forKey: teammate.id.rawValue)
        }
        if sidebar.selection == teammate.id.rawValue {
            searchCoordinator?.close()
            setSelectionWithoutPersistence(nil)
            profileEditor = nil
            isBotDetailsPresented = false
            showConversation(conversationID: nil, title: "Conversation", messages: [])
            conversation.setInputAvailability(.unavailable(reason: "Bot archived. Restore it from Archived Bots."))
        }
        // The repository already cleared only this bot's persisted selection.
        // Do not clear it again after an await and erase newer navigation.
        sidebar.replace(rows: sidebar.rows.filter { $0.id != teammate.id.rawValue })
        collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
    }

    public func restoreBot(_ teammate: Teammate) async {
        guard !isShuttingDown, let archiveModel, await archiveModel.restore(teammate) != nil else { return }
        do {
            let chats = try await service.activeDirectChats()
            guard !isShuttingDown, let chat = chats.first(where: { $0.teammate.id == teammate.id }) else { return }
            directChatsByTeammate[teammate.id.rawValue] = chat
            sidebar.update(Self.rowSnapshot(chat))
            collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
        } catch {
            archiveModel.errorMessage = "The bot was restored, but its sidebar could not refresh. Reopen the workspace to see it."
        }
    }

    public func toggleBotDetails() {
        if isBotDetailsPresented { closeBotDetails() } else { showBotDetails() }
    }

    public func showBotDetails() {
        guard !isShuttingDown, hiringModel == nil, selectedTeammate != nil else { return }
        searchCoordinator?.close()
        profileEditor = nil
        isBotDetailsPresented = true
    }

    public func closeBotDetails() {
        isBotDetailsPresented = false
        // Collapsing a panel is navigation, not cancellation of its edit draft.
        profileEditor = nil
    }

    public func editSelectedProfile() {
        searchCoordinator?.close()
        guard canEditSelectedProfile, let id = sidebar.selection, let profileService else { return }
        let editor = profileDrafts[id] ?? TeammateProfileEditorModel(
            service: profileService, teammateID: TeammateID(id), photoImporter: photoImporter
        )
        profileDrafts[id] = editor
        profileEditor = editor
        isBotDetailsPresented = true
    }

    public func cancelProfileEditing() {
        guard let editor = profileEditor, editor.isCancelled || editor.cancel() else { return }
        profileDrafts.removeValue(forKey: editor.teammateID.rawValue)
        profileEditor = nil
        isBotDetailsPresented = selectedTeammate != nil
    }

    public func profileDidSave(_ teammate: Teammate) {
        guard !isShuttingDown else { return }
        let id = teammate.id.rawValue
        guard let oldChat = directChatsByTeammate[id] else { return }
        let updated = DurableDirectChatSnapshot(teammate: teammate, conversation: oldChat.conversation)
        directChatsByTeammate[id] = updated
        let previous = sidebar.rows.first(where: { $0.id == id })
        sidebar.update(TeammateRowSnapshot(
            identity: TeammateIdentitySnapshot(teammate), activity: previous?.activity ?? .idle,
            unreadCount: previous?.unreadCount ?? 0,
            lastActivityAt: previous?.lastActivityAt ?? oldChat.conversation.updatedAt
        ))
        collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map {
            TeammateIdentitySnapshot($0.teammate)
        })
        if conversation.conversationID == updated.conversation.id.rawValue {
            conversation.renameTitle(teammate.profile.displayName)
            activateKnowledgeContext(for: conversation.conversationID)
        }
        profileDrafts.removeValue(forKey: id)
        if profileEditor?.teammateID == teammate.id { profileEditor = nil }
    }

    /// Debug/design-review control only. Runtime-owned activity replaces this
    /// once the separately approved executor exists.
    public func setSelectedActivity(_ activity: TeammateActivityState) {
        guard !isShuttingDown else { return }
        guard
            let selectedID = sidebar.selection,
            let current = sidebar.rows.first(where: { $0.id == selectedID })
        else { return }
        sidebar.update(
            TeammateRowSnapshot(
                identity: current.identity,
                activity: activity,
                unreadCount: current.unreadCount,
                lastActivityAt: current.lastActivityAt
            )
        )
    }

    /// Called only after `HiringConversationModel` has received the repository's
    /// atomic confirmation snapshot. Merely opening or editing the hiring
    /// conversation never enters the durable teammate roster.
    public func completeHiring(from model: HiringConversationModel) {
        guard !isShuttingDown else { return }
        guard
            hiringModel === model,
            let created = model.confirmedCreation
        else { return }

        let chat = DurableDirectChatSnapshot(
            teammate: created.teammate,
            conversation: created.conversation
        )
        directChatsByTeammate[created.teammate.id.rawValue] = chat
        sidebar.replace(rows: [Self.rowSnapshot(chat)] + sidebar.rows.filter { $0.id != created.teammate.id.rawValue })
        collaborationModel?.replaceAvailableTeammates(
            directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) }
        )
        setSelectionWithoutPersistence(created.teammate.id.rawValue)
        showConversation(
            conversationID: created.conversation.id.rawValue,
            title: created.teammate.profile.displayName,
            messages: created.fixtureGreeting.map { [Self.messageSnapshot($0, teammate: created.teammate)] } ?? [],
            hasEarlierMessages: false
        )
        recordMessageSequences(created.fixtureGreeting.map { [$0] } ?? [])
        conversation.setInputAvailability(.ready)
        hiringModel = nil
        selectionBeforeHiring = nil
        sidebar.requestCreationReveal(created.teammate.id.rawValue)
    }

    public func completeHiringCancellation(from model: HiringConversationModel) {
        guard !isShuttingDown else { return }
        guard hiringModel === model, model.isCancelled else { return }
        let priorSelection = selectionBeforeHiring
        hiringModel = nil
        selectionBeforeHiring = nil
        setSelectionWithoutPersistence(priorSelection)
        activateTrustContext(for: conversation.conversationID)
        activateRunRecoveryContext(for: conversation.conversationID)
    }

    private func selectionChanged(to teammateUUID: UUID?, generation: UInt64) async {
        guard !isShuttingDown, generation == selectionGeneration,
              sidebar.selection == teammateUUID else { return }
        searchCoordinator?.close()
        savedOutcomeHistoryModel?.activateScope(nil)

        // Selecting a roster conversation while hiring is an ordinary
        // navigation-away action. Pause the durable draft without cancelling
        // or confirming it; New Teammate resumes that same draft later.
        if hiringModel != nil, teammateUUID != nil {
            hiringModel = nil
            selectionBeforeHiring = nil
        }

        guard let teammateUUID else {
            showConversation(conversationID: nil, title: "Conversation", messages: [])
            conversation.setInputAvailability(
                .unavailable(reason: "Choose a teammate to open its local conversation.")
            )
            do {
                try await service.clearSelection()
            } catch {
                guard !isShuttingDown, generation == selectionGeneration,
                      sidebar.selection == teammateUUID else { return }
                conversation.setInputAvailability(
                    .unavailable(reason: "OpenBots could not save the local selection.")
                )
            }
            return
        }

        guard let chat = directChatsByTeammate[teammateUUID] else {
            conversation.setInputAvailability(
                .unavailable(reason: "That teammate’s local conversation is unavailable.")
            )
            return
        }

        showConversation(
            conversationID: chat.conversation.id.rawValue,
            title: chat.teammate.profile.displayName,
            messages: []
        )
        conversation.setInputAvailability(
            .unavailable(reason: "Opening the saved local conversation…")
        )

        do {
            try await service.select(
                teammateID: chat.teammate.id,
                conversationID: chat.conversation.id
            )
            guard !isShuttingDown, generation == selectionGeneration,
                  sidebar.selection == teammateUUID else { return }
            try await show(
                chat,
                messageLimit: messagePageLimit,
                expectedGeneration: generation
            )
        } catch {
            guard !isShuttingDown, generation == selectionGeneration,
                  sidebar.selection == teammateUUID else { return }
            conversation.setInputAvailability(
                .unavailable(reason: "OpenBots could not open this local conversation.")
            )
        }
    }

    private func show(
        _ chat: DurableDirectChatSnapshot,
        messageLimit: Int,
        expectedGeneration: UInt64
    ) async throws {
        let page = try await service.loadMessages(
            conversationID: chat.conversation.id,
            beforeSequence: nil,
            limit: messageLimit
        )
        await loadDeliveryProvenance(page.messages, conversationID: chat.conversation.id)
        guard
            expectedGeneration == selectionGeneration,
            sidebar.selection == chat.teammate.id.rawValue
        else { return }
        recordMessageSequences(page.messages)
        let loadedIDs = Set(page.messages.map { $0.id.rawValue })
        let pending = conversation.conversationID == chat.conversation.id.rawValue
            ? conversation.messages.filter { snapshot in
                guard !loadedIDs.contains(snapshot.id) else { return false }
                switch snapshot.delivery {
                case .pending, .failed: return true
                case .sent: return false
                }
            } : []
        showConversation(
            conversationID: chat.conversation.id.rawValue,
            title: chat.teammate.profile.displayName,
            messages: page.messages.map { presentedMessage($0, teammate: chat.teammate) } + pending,
            hasEarlierMessages: page.hasMore
        )
        conversation.setInputAvailability(.ready)
        presentSavedLiveMessages(conversationID: chat.conversation.id.rawValue, teammate: chat.teammate)
    }

    private func makeConversationModel() -> ConversationModel {
        let localSubmission: ConversationModel.Submission?
        let deliveryDescription: String
        if textReplyService != nil {
            deliveryDescription = Self.textReplyDeliveryDescription
            localSubmission = { [weak self] messageID, conversationID, text in
                await self?.persistMessage(messageID: messageID, conversationID: conversationID, text: text, locally: true)
            }
        } else {
            deliveryDescription = mode == .localOnly ? Self.localDeliveryDescription : Self.fixtureDeliveryDescription
            localSubmission = nil
        }
        return ConversationModel(
            readyDeliveryDescription: deliveryDescription,
            isLocalOnly: mode == .localOnly && textReplyService == nil,
            textRepliesEnabled: textReplyService != nil,
            stopTextReply: { [weak self] in
                guard let self, let id = self.conversation.conversationID else { return }
                self.textReplyCoordinator?.stop(conversationID: id)
            },
            saveLocally: localSubmission,
            inputAvailability: .unavailable(
                reason: "Create or choose a teammate to begin."
            ),
            submit: { [weak self] messageID, conversationID, text in
                await self?.persistMessage(
                    messageID: messageID,
                    conversationID: conversationID,
                    text: text
                )
            },
            beforeSubmission: { [weak self] messageID, conversationID, rawText in
                self?.prepareMessageSubmission(messageID: messageID, conversationID: conversationID, rawText: rawText, locally: false) ?? false
            },
            beforeLocalSubmission: { [weak self] messageID, conversationID, rawText in
                self?.prepareMessageSubmission(messageID: messageID, conversationID: conversationID, rawText: rawText, locally: true) ?? false
            },
            earlierPageLoader: { [weak self] conversationID, earliestMessageID in
                guard let self else {
                    return ConversationMessagePageSnapshot(
                        messages: [],
                        hasEarlierMessages: false
                    )
                }
                return try await self.loadEarlierPage(
                    conversationID: conversationID,
                    earliestMessageID: earliestMessageID
                )
            },
            latestPageLoader: { [weak self] in
                await self?.returnToLatest()
            }
        )
    }

    private func openSearchDestination(
        _ destination: WorkspaceSearchDestination,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        let teammateID: TeammateID
        let conversationID: ConversationID
        let target: MessageSearchTarget?
        switch destination {
        case .teammate(let hit):
            teammateID = hit.teammate.id
            conversationID = hit.conversationID
            target = nil
        case .message(let resolved):
            teammateID = resolved.teammateID
            conversationID = resolved.conversationID
            target = resolved
        }
        guard isCurrent(), let chat = directChatsByTeammate[teammateID.rawValue],
              chat.conversation.id == conversationID,
              target.map({ $0.sequence < Int64.max }) ?? true else {
            throw SearchNavigationError.unavailable
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let page = try await service.loadMessages(
            conversationID: conversationID,
            beforeSequence: target.map { $0.sequence + 1 }, limit: min(messagePageLimit, 50)
        )
        await loadDeliveryProvenance(page.messages, conversationID: conversationID)
        guard isCurrent(), generation == selectionGeneration else { throw CancellationError() }
        guard page.conversationID == conversationID,
              target.map({ requested in page.messages.contains { $0.id == requested.id && $0.sequence == requested.sequence } }) ?? true
        else { throw SearchNavigationError.unavailable }
        // The current repository rechecks active direct-chat membership. A
        // search hit cannot revive an archived or now-hidden teammate.
        try await service.select(teammateID: teammateID, conversationID: conversationID)
        guard isCurrent(), generation == selectionGeneration else { throw CancellationError() }
        setSelectionWithoutPersistence(teammateID.rawValue)
        hiringModel = nil
        selectionBeforeHiring = nil
        profileEditor = nil // Its independently owned edit draft is retained.
        recordMessageSequences(page.messages)
        showConversation(
            conversationID: conversationID.rawValue, title: target?.currentTitle ?? chat.teammate.profile.displayName,
            messages: page.messages.map { presentedMessage($0, teammate: chat.teammate) },
            hasEarlierMessages: page.hasMore, includesFixtures: target == nil
        )
        if let target { conversation.focusSearchMessage(target.id.rawValue) }
        conversation.setInputAvailability(.ready)
    }

    private func returnToLatest() async {
        guard let id = sidebar.selection, let chat = directChatsByTeammate[id] else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        do {
            try await show(chat, messageLimit: messagePageLimit, expectedGeneration: generation)
            guard generation == selectionGeneration else { return }
            conversation.focusLatestMessage()
        } catch {
            guard generation == selectionGeneration else { return }
            conversation.setSearchNavigationNotice("Latest messages could not be loaded. Your current page and draft are preserved.")
        }
    }

    private func loadEarlierPage(
        conversationID: UUID,
        earliestMessageID: UUID?
    ) async throws -> ConversationMessagePageSnapshot {
        guard
            let chat = directChatsByTeammate.values.first(where: {
                $0.conversation.id.rawValue == conversationID
            })
        else {
            return ConversationMessagePageSnapshot(
                messages: [],
                hasEarlierMessages: false
            )
        }

        let beforeSequence = earliestMessageID.flatMap { messageSequenceByID[$0] }
        let page = try await service.loadMessages(
            conversationID: chat.conversation.id,
            beforeSequence: beforeSequence,
            limit: messagePageLimit
        )
        await loadDeliveryProvenance(page.messages, conversationID: chat.conversation.id)
        recordMessageSequences(page.messages)
        return ConversationMessagePageSnapshot(
            messages: page.messages.map { presentedMessage($0, teammate: chat.teammate) },
            hasEarlierMessages: page.hasMore
        )
    }

    private func prepareMessageSubmission(messageID: UUID, conversationID: UUID, rawText: String, locally: Bool) -> Bool {
        guard !isShuttingDown, archiveModel?.isBusy != true else { return false }
        let live = textReplyService != nil && !locally
        if live {
            guard !conversation.hasAttachmentContent, attachmentDraft.rows.isEmpty,
                  textReplyCoordinator?.reserve(conversationID: conversationID, messageID: messageID) == true else { return false }
            liveSavedMessages[conversationID] = [:]
        }
        let assets: [AttachmentAsset]
        if let coordinator = attachmentCoordinator {
            guard let frozen = coordinator.begin(messageID: messageID, conversationID: conversationID) else {
                if live { textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID) }
                return false
            }
            assets = frozen
        } else { assets = [] }
        let admitted = draftCoordinator?.beginSubmission(
            messageID: messageID, conversationID: conversationID, rawText: rawText,
            allowsEmptyText: !assets.isEmpty
        ) ?? true
        if !admitted {
            attachmentCoordinator?.finish(messageID: messageID, committed: false)
            if live { textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID) }
        }
        if admitted, let focus = conversation.searchFocus {
            searchOriginatedSubmissions[messageID] = (focus.requestID, selectionGeneration)
        }
        return admitted
    }

    private func persistMessage(
        messageID: UUID,
        conversationID: UUID,
        text: String,
        locally: Bool = false
    ) async {
        guard !didFinishShutdown, !Task.isCancelled else { return }
        let originatedSearchRequest = searchOriginatedSubmissions.removeValue(forKey: messageID)
        let frozenAttachments = attachmentCoordinator?.assets(messageID: messageID) ?? []
        var attachmentCommitSucceeded = false
        defer { attachmentCoordinator?.finish(messageID: messageID, committed: attachmentCommitSucceeded) }
        guard let chat = directChatsByTeammate.values.first(where: {
            $0.conversation.id.rawValue == conversationID
        }) else {
            textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
            draftCoordinator?.failSubmission(messageID: messageID)
            markPendingMessageFailed(
                messageID,
                conversationID: conversationID,
                reason: "The local conversation is unavailable."
            )
            return
        }

        if let draftCoordinator, !(await draftCoordinator.persistSubmission(messageID: messageID)) {
            textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
            draftCoordinator.failSubmission(messageID: messageID)
            markPendingMessageFailed(messageID, conversationID: conversationID,
                                     reason: "OpenBots could not save the draft before sending. Your text is preserved.")
            return
        }
        let teammateID = chat.teammate.id.rawValue
        guard !didFinishShutdown, !Task.isCancelled else { return }
        if textReplyService != nil && !locally {
            await performTextReply(messageID: messageID, text: text, chat: chat, originatedSearchRequest: originatedSearchRequest)
            attachmentCommitSucceeded = liveSavedMessages[conversationID]?[messageID] != nil
            return
        }
        if mode == .reviewFixture { beginFixtureExchange(teammateID: teammateID) }
        var terminalActivity: TeammateActivityState = .waitingForUser
        defer {
            if mode == .reviewFixture {
                finishFixtureExchange(teammateID: teammateID, terminalActivity: terminalActivity)
            }
        }
        do {
            let userMessage: Message
            let fixtureReply: Message?
            switch mode {
            case .localOnly:
                userMessage = try await service.saveMessageLocally(
                    conversationID: chat.conversation.id, teammateID: chat.teammate.id,
                    userMessageID: MessageID(messageID), text: text,
                    attachmentIDs: frozenAttachments.map(\.id)
                )
                if textReplyService != nil { deliveryNotices[userMessage.id.rawValue] = "Saved locally · not sent to Claude" }
                fixtureReply = nil
            case .reviewFixture:
                let exchange = try await service.sendMessageToLocalFixture(
                    conversationID: chat.conversation.id, teammateID: chat.teammate.id,
                    userMessageID: MessageID(messageID), text: text,
                    attachmentIDs: frozenAttachments.map(\.id)
                )
                userMessage = exchange.userMessage
                fixtureReply = exchange.fixtureReply
            }
            attachmentCommitSucceeded = true
            attachmentCoordinator?.finish(messageID: messageID, committed: true)
            await draftCoordinator?.completeSubmission(messageID: messageID)
            guard !didFinishShutdown, !Task.isCancelled else { return }
            recordMessageSequences([userMessage] + (fixtureReply.map { [$0] } ?? []))
            if conversation.conversationID == conversationID, conversation.needsLatestPage {
                // Never join a historical page directly to newly sent rows,
                // silently omitting the intervening saved conversation.
                if originatedSearchRequest?.generation == selectionGeneration,
                   conversation.isShowingLatestPlaceholder {
                    await returnToLatest()
                }
                if conversation.needsLatestPage { return }
            }
            if conversation.conversationID == conversationID {
                conversation.replaceMessage(
                    presentedMessage(userMessage, teammate: chat.teammate)
                )
            }

            // Both rows are already durable. This labelled, deterministic
            // presentation fixture reveals the stored reply through one stable
            // row so S2 can verify row-local streaming without implying that a
            // model process or tool is running.
            if let fixtureReply, !isShuttingDown, conversation.conversationID == conversationID {
                setActivity(.speaking, teammateID: teammateID)
                let finalReply = Self.messageSnapshot(
                    fixtureReply,
                    teammate: chat.teammate
                )
                let streamingReply = ChatMessageSnapshot(
                    id: finalReply.id,
                    author: finalReply.author,
                    parts: [],
                    delivery: .sent,
                    timestamp: finalReply.timestamp
                )
                conversation.beginStreamingMessage(streamingReply)
                let partID = finalReply.parts.first?.id
                for chunk in Self.fixtureStreamChunks(finalReply.body) {
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !isShuttingDown, !Task.isCancelled, conversation.conversationID == conversationID else { break }
                    _ = conversation.appendStreamingDelta(
                        messageID: finalReply.id,
                        delta: chunk,
                        partID: partID,
                        ordinal: 0
                    )
                }
                if !isShuttingDown, conversation.conversationID == conversationID {
                    _ = conversation.completeStreamingMessage(id: finalReply.id)
                }
            }
        } catch DurableTeammateChatError.fixtureReplyUnavailable(let savedUserMessage) {
            guard !didFinishShutdown, !Task.isCancelled else { return }
            // A legacy nontransactional fixture adapter can report a saved
            // user row plus a failed reply. Never mark that user input unsent
            // or invite a duplicate retry. The production preview uses the
            // atomic repository path and cannot take this partial branch.
            attachmentCommitSucceeded = true
            attachmentCoordinator?.finish(messageID: messageID, committed: true)
            await draftCoordinator?.completeSubmission(messageID: messageID)
            guard !didFinishShutdown, !Task.isCancelled else { return }
            recordMessageSequences([savedUserMessage])
            if conversation.conversationID == conversationID {
                conversation.replaceMessage(Self.messageSnapshot(savedUserMessage, teammate: chat.teammate))
                conversation.replaceMessage(ChatMessageSnapshot(
                    id: UUID(), author: .system(label: "Local delivery status"),
                    body: "Your message was saved. The local demo reply could not be stored; do not resend the message.",
                    delivery: .sent, timestamp: Date()))
            }
            terminalActivity = .errorOrAttention
        } catch {
            guard !didFinishShutdown, !Task.isCancelled else { return }
            draftCoordinator?.failSubmission(messageID: messageID)
            markPendingMessageFailed(
                messageID,
                conversationID: conversationID,
                reason: "OpenBots could not store this local message."
            )
            terminalActivity = .errorOrAttention
        }
    }

    private func performTextReply(
        messageID: UUID, text: String, chat: DurableDirectChatSnapshot,
        originatedSearchRequest: (requestID: UUID, generation: UInt64)?
    ) async {
        guard let coordinator = textReplyCoordinator else { return }
        let conversationID = chat.conversation.id.rawValue
        setActivity(.thinkingOrWorking, teammateID: chat.teammate.id.rawValue)
        let submission = ClaudeTextTurnSubmission(
            conversationID: chat.conversation.id, teammateID: chat.teammate.id,
            userMessageID: MessageID(messageID), text: text
        )
        let result = await coordinator.send(submission) { [weak self] progress in
            guard let self, !self.didFinishShutdown else { return }
            switch progress {
            case .contextPrepared, .modelObserved, .modelConfirmed:
                break // The coordinator presents the disclosure for its own conversation.
            case .stage(let stage):
                // Responding begins at CLI initialization, before public text.
                // Only a saved streaming reply below can establish speaking.
                if stage != .responding {
                    self.setActivity(.thinkingOrWorking, teammateID: chat.teammate.id.rawValue)
                }
            case .userMessageSaved(let message):
                guard message.id == submission.userMessageID, message.conversationID == chat.conversation.id else { return }
                self.provenanceRequests[chat.conversation.id, default: [:]][message.id] = UUID()
                self.liveSavedMessages[conversationID, default: [:]][message.id.rawValue] = message
                self.deliveryNotices[message.id.rawValue] = "Saved locally · preparing Claude"
                await self.draftCoordinator?.completeSubmission(messageID: messageID)
                self.recordMessageSequences([message])
                if self.conversation.conversationID == conversationID,
                   self.conversation.isShowingLatestPlaceholder,
                   originatedSearchRequest?.generation == self.selectionGeneration {
                    await self.returnToLatest()
                }
                self.presentSavedLiveMessages(conversationID: conversationID, teammate: chat.teammate)
            case .assistantMessageSaved(let message):
                guard message.conversationID == chat.conversation.id else { return }
                self.provenanceRequests[chat.conversation.id, default: [:]][message.id] = UUID()
                self.textTurnReplyMessageIDs.insert(message.id.rawValue)
                self.liveSavedMessages[conversationID, default: [:]][message.id.rawValue] = message
                self.recordMessageSequences([message])
                let canStream: Bool
                switch message.deliveryState {
                case .completed, .failed, .outcomeUnknown: canStream = false
                case .pending, .queued, .submitted, .acknowledged: canStream = Self.hasClaudeReplyText(message)
                }
                self.deliveryNotices[message.id.rawValue] = canStream
                    ? "Actual Claude reply · partial text saved" : "Saved Claude turn outcome"
                if canStream { self.setActivity(.speaking, teammateID: chat.teammate.id.rawValue) }
                if canStream, !self.isShuttingDown, self.conversation.conversationID == conversationID, !self.conversation.needsLatestPage {
                    self.conversation.beginStreamingMessage(self.presentedMessage(message, teammate: chat.teammate))
                } else {
                    self.presentSavedLiveMessages(conversationID: conversationID, teammate: chat.teammate)
                }
            }
        }
        guard !didFinishShutdown else { return }
        if let user = result.savedUserMessage {
            liveSavedMessages[conversationID, default: [:]][user.id.rawValue] = user
        }
        if let reply = result.savedReplyMessage {
            textTurnReplyMessageIDs.insert(reply.id.rawValue)
            liveSavedMessages[conversationID, default: [:]][reply.id.rawValue] = reply
        }
        if liveSavedMessages[conversationID]?[messageID] != nil {
            // Provider failure never turns a committed user message back into
            // an unsent draft or creates an implicit retry.
            await draftCoordinator?.completeSubmission(messageID: messageID)
        } else {
            draftCoordinator?.failSubmission(messageID: messageID)
            let reason: String
            switch result.outcome {
            case .failed(let problem): reason = ClaudeTextReplyPhase.explanation(problem)
            case .stopped: reason = "Stopped before this message was saved. Your draft is preserved."
            case .completed: reason = "The saved message could not be confirmed."
            }
            markPendingMessageFailed(messageID, conversationID: conversationID, reason: reason)
        }
        let saved = Array(liveSavedMessages[conversationID, default: [:]].values)
        recordMessageSequences(saved)
        await loadDeliveryProvenance(saved, conversationID: chat.conversation.id)
        guard !didFinishShutdown else { return }
        coordinator.finish(conversationID: conversationID, messageID: messageID, outcome: result.outcome)
        presentSavedLiveMessages(conversationID: conversationID, teammate: chat.teammate)
        switch result.outcome {
        case .completed, .stopped: setActivity(.idle, teammateID: chat.teammate.id.rawValue)
        case .failed: setActivity(.errorOrAttention, teammateID: chat.teammate.id.rawValue)
        }
    }

    private func refreshTextReplyPhase() {
        guard !didFinishShutdown else { return }
        // Details holds a value snapshot of coordinator model status, so its
        // observing workspace must refresh as well as the child conversation.
        objectWillChange.send()
        conversation.setTextReplyPhase(textReplyCoordinator?.phase(for: conversation.conversationID))
        conversation.setTextReplyContextDisclosure(textReplyCoordinator?.contextDisclosure(for: conversation.conversationID))
    }

    private func presentSavedLiveMessages(conversationID: UUID, teammate: Teammate) {
        guard !isShuttingDown, conversation.conversationID == conversationID, !conversation.needsLatestPage else { return }
        for message in liveSavedMessages[conversationID, default: [:]].values.sorted(by: { $0.sequence < $1.sequence }) {
            conversation.replaceMessage(presentedMessage(message, teammate: teammate))
        }
    }

    private func presentedMessage(_ message: Message, teammate: Teammate) -> ChatMessageSnapshot {
        var snapshot = Self.messageSnapshot(message, teammate: teammate)
        if textReplyService != nil {
            snapshot.deliveryNotice = deliveryNotices[message.id.rawValue] ?? "Saved on this Mac · Claude delivery not verified"
            let hasStatusPart = message.parts.contains { part in
                if case .status = part.content { return true }
                return false
            }
            if message.author != .user,
               textTurnReplyMessageIDs.contains(message.id.rawValue) || hasStatusPart,
               !Self.hasClaudeReplyText(message) {
                snapshot = ChatMessageSnapshot(
                    id: snapshot.id, author: .system(label: "OpenBots"), parts: snapshot.parts,
                    delivery: snapshot.delivery, timestamp: snapshot.timestamp
                )
                snapshot.deliveryNotice = "OpenBots status · no Claude reply received"
            }
        }
        return snapshot
    }

    private static func hasClaudeReplyText(_ message: Message) -> Bool {
        guard case .teammate = message.author else { return false }
        return message.parts.contains { part in
            if case .text(let text) = part.content { return !text.isEmpty }
            return false
        }
    }

    private func loadDeliveryProvenance(_ messages: [Message], conversationID: ConversationID) async {
        guard let textReplyService, !messages.isEmpty else { return }
        let request = UUID()
        let requestedIDs = Set(messages.map(\.id))
        for id in requestedIDs { provenanceRequests[conversationID, default: [:]][id] = request }
        func isCurrent(_ id: MessageID) -> Bool {
            requestedIDs.contains(id) && provenanceRequests[conversationID]?[id] == request
        }
        do {
            var records: [TextTurnMessageProvenance] = []
            // The repository deliberately accepts at most 100 IDs per query.
            for start in stride(from: 0, to: messages.count, by: 100) {
                records += try await textReplyService.messageProvenance(
                    conversationID: conversationID,
                    messageIDs: messages[start..<min(start + 100, messages.count)].map(\.id)
                )
            }
            guard !didFinishShutdown else { return }
            for message in messages where isCurrent(message.id) {
                deliveryNotices[message.id.rawValue] = "Saved locally · not sent to Claude"
            }
            for record in records {
                let input: String
                switch record.inputState {
                case .queued: input = "Saved locally · Claude submission not confirmed"
                case .submitted: input = "Submitted to Claude · acceptance not confirmed"
                case .acknowledged: input = "Accepted by Claude"
                case .outcomeUnknown: input = "Claude delivery outcome unknown"
                }
                if isCurrent(record.messageID) { deliveryNotices[record.messageID.rawValue] = input }
                let reply: String
                switch record.state {
                case .succeeded: reply = "Claude reply saved"
                case .failed: reply = "Claude turn failed · available reply text saved"
                case .interrupted: reply = "Claude turn stopped · available reply text saved"
                case .queued, .starting, .running, .waitingForUser, .stopping:
                    reply = textReplyCoordinator?.phase(for: conversationID.rawValue)?.isBusy == true
                        ? "Claude reply in progress · partial text saved"
                        : "Saved partial reply · previous Claude turn outcome unknown"
                }
                if isCurrent(record.replyMessageID) {
                    textTurnReplyMessageIDs.insert(record.replyMessageID.rawValue)
                    deliveryNotices[record.replyMessageID.rawValue] = reply
                }
            }
        } catch {
            guard !didFinishShutdown else { return }
            for message in messages where isCurrent(message.id) {
                deliveryNotices[message.id.rawValue] = "Saved on this Mac · Claude delivery not verified"
            }
        }
    }

    /// Retains one process-local composer and attachment model per durable
    /// conversation. An importer that finishes after navigation updates only
    /// the originating model, which becomes visible again when that exact
    /// conversation is reselected.
    private func showConversation(
        conversationID: UUID?,
        title: String,
        messages: [ChatMessageSnapshot],
        hasEarlierMessages: Bool = false,
        includesFixtures: Bool = true
    ) {
        guard !isShuttingDown else { return }
        preserveCurrentComposerDraft()
        if profileEditor?.teammateID.rawValue != teammateID(for: conversationID) {
            profileEditor = nil
        }
        collaborationModel?.activateConversation(
            conversationID,
            selectedTeammateID: teammateID(for: conversationID)
        )
        activateKnowledgeContext(for: conversationID)
        activateTrustContext(for: conversationID)
        activateRunRecoveryContext(for: conversationID)
        let showsReviewFixtures = includesFixtures && mode == .reviewFixture
        let cardFixture = showsReviewFixtures ? cardFixturePresentation(
            for: conversationID,
            durableMessages: messages
        ) : nil
        var presentedMessages = messages
        if let cardMessage = cardFixture?.message {
            presentedMessages.append(cardMessage)
        }
        if showsReviewFixtures, let collaborationMessage = collaborationFixtureMessage(
            for: conversationID,
            existingMessages: presentedMessages
        ) {
            presentedMessages.append(collaborationMessage)
            if let conversationID {
                admittedCollaborationFixtureIDByConversationID[conversationID] =
                    collaborationMessage.id
            }
        } else if let conversationID {
            admittedCollaborationFixtureIDByConversationID.removeValue(
                forKey: conversationID
            )
        }
        conversation.show(
            conversationID: conversationID,
            title: title,
            messages: presentedMessages,
            hasEarlierMessages: hasEarlierMessages
        )
        refreshTextReplyPhase()
        cardInteractions = cardFixture?.interactions
        activateDraftState(for: conversationID)
    }

    private func collaborationFixtureMessage(
        for conversationID: UUID?,
        existingMessages: [ChatMessageSnapshot]
    ) -> ChatMessageSnapshot? {
        guard
            let conversationID,
            let message = collaborationModel?.conversationFixtureMessage(for: conversationID),
            !existingMessages.contains(where: { $0.id == message.id })
        else { return nil }
        return message
    }

    /// Variant changes update only the already-present process-local handoff
    /// row. A missing row is never appended here because that could bypass the
    /// collision checks performed while opening a conversation.
    private func refreshVisibleCollaborationFixture() {
        guard !isShuttingDown, mode == .reviewFixture else { return }
        guard
            let conversationID = conversation.conversationID,
            let message = collaborationModel?.conversationFixtureMessage(for: conversationID),
            admittedCollaborationFixtureIDByConversationID[conversationID] == message.id,
            conversation.messages.contains(where: { $0.id == message.id })
        else { return }
        conversation.replaceMessage(message)
    }

    private func teammateID(for conversationID: UUID?) -> UUID? {
        guard let conversationID else { return nil }
        return directChatsByTeammate.values.first(where: {
            $0.conversation.id.rawValue == conversationID
        })?.teammate.id.rawValue
    }

    private func activateKnowledgeContext(for conversationID: UUID?) {
        guard let knowledgeModel else { return }
        guard
            let conversationID,
            let chat = directChatsByTeammate.values.first(where: {
                $0.conversation.id.rawValue == conversationID
            })
        else {
            knowledgeModel.activateContext(nil)
            return
        }

        let selectedProject = collaborationModel?.selectedProject
        let teammateID = chat.teammate.id.rawValue
        let activeProjectMembershipIDs: Set<UUID>
        if let selectedProject,
           selectedProject.members.contains(where: { $0.id == teammateID }) {
            activeProjectMembershipIDs = [selectedProject.id]
        } else {
            activeProjectMembershipIDs = []
        }
        let context = KnowledgeWorkspaceContext(
            conversationID: conversationID,
            teammateID: teammateID,
            teammateName: chat.teammate.profile.displayName,
            selectedProjectID: selectedProject?.id,
            selectedProjectName: selectedProject?.name,
            activeProjectMembershipIDs: activeProjectMembershipIDs
        )
        guard knowledgeModel.context != context else { return }
        knowledgeModel.activateContext(context)
        Task { await knowledgeModel.load() }
    }

    /// Only a repository-resolved direct conversation can select a trust fixture.
    /// Hiring has no candidate authority, even while its prior chat stays mounted.
    private func activateRunRecoveryContext(for conversationID: UUID?) {
        let chat = directChatsByTeammate.values.first {
            $0.conversation.id.rawValue == conversationID
        }
        let resolvedID = chat?.conversation.id.rawValue
        runRecoveryModel?.activateConversation(resolvedID)
        actionProposalModel?.activateConversation(resolvedID)
        let request = chat.flatMap {
            try? ConversationOutcomeHistoryRequest(conversationID: $0.conversation.id, teammateID: $0.teammate.id)
        }
        savedOutcomeHistoryModel?.activateScope(request)
    }

    private func activateTrustContext(for conversationID: UUID?) {
        guard let trustAuthorizationModel else { return }
        guard let conversationID,
              let chat = directChatsByTeammate.values.first(where: {
                  $0.conversation.id.rawValue == conversationID
              }) else {
            trustAuthorizationModel.activateContext(nil)
            return
        }
        let context = TrustFixtureContext(
            teammateID: chat.teammate.id,
            conversationID: chat.conversation.id
        )
        let changed = trustAuthorizationModel.context != context
        trustAuthorizationModel.activateContext(
            context, teammateName: chat.teammate.profile.displayName
        )
        if changed {
            Task { await trustAuthorizationModel.load() }
        }
    }

    /// Lazily creates one stable process-local fixture per conversation. A
    /// mismatched registry or a message-ID collision fails closed to no card
    /// row, without mutating durable conversation state.
    private func cardFixturePresentation(
        for conversationID: UUID?,
        durableMessages: [ChatMessageSnapshot]
    ) -> ConversationCardFixturePresentation? {
        guard let conversationID else { return nil }
        let fixture: ConversationCardFixturePresentation
        if let cached = cardFixtureByConversationID[conversationID] {
            fixture = cached
        } else {
            guard let created = cardFixtureFactory?(conversationID) else { return nil }
            guard created.interactions.conversationID == conversationID else { return nil }
            cardFixtureByConversationID[conversationID] = created
            fixture = created
        }
        guard !durableMessages.contains(where: { $0.id == fixture.message.id }) else {
            return nil
        }
        return fixture
    }

    private func preserveCurrentComposerDraft() {
        guard draftService == nil else { return }
        guard let conversationID = conversation.conversationID else { return }
        composerDraftByConversationID[conversationID] = conversation.composerText
    }

    private func activateDraftState(for conversationID: UUID?) {
        draftCoordinator?.activate(conversationID: conversationID)
        if let attachmentCoordinator {
            attachmentDraft = attachmentCoordinator.activate(conversationID) ?? unscopedAttachmentDraft
            if draftService == nil {
                conversation.composerText = conversationID.flatMap { composerDraftByConversationID[$0] } ?? ""
            }
            return
        }
        guard let conversationID else {
            conversation.composerText = ""
            if attachmentDraft !== unscopedAttachmentDraft {
                attachmentDraft = unscopedAttachmentDraft
            }
            return
        }

        if draftService == nil {
            conversation.composerText = composerDraftByConversationID[conversationID] ?? ""
        }
        let scopedAttachmentDraft: AttachmentDraftModel
        if let existing = attachmentDraftByConversationID[conversationID] {
            scopedAttachmentDraft = existing
        } else {
            scopedAttachmentDraft = AttachmentDraftModel(importer: attachmentImporter)
            attachmentDraftByConversationID[conversationID] = scopedAttachmentDraft
        }
        if attachmentDraft !== scopedAttachmentDraft {
            attachmentDraft = scopedAttachmentDraft
        }
    }

    private func beginFixtureExchange(teammateID: UUID) {
        let priorCount = activeFixtureExchangeCountByTeammate[teammateID, default: 0]
        activeFixtureExchangeCountByTeammate[teammateID] = priorCount + 1
        if priorCount == 0 {
            setActivity(.thinkingOrWorking, teammateID: teammateID)
        }
    }

    private func finishFixtureExchange(
        teammateID: UUID,
        terminalActivity: TeammateActivityState
    ) {
        guard !didFinishShutdown else { return }
        let remaining = max(
            0,
            activeFixtureExchangeCountByTeammate[teammateID, default: 1] - 1
        )
        if remaining == 0 {
            activeFixtureExchangeCountByTeammate.removeValue(forKey: teammateID)
            setActivity(terminalActivity, teammateID: teammateID)
        } else {
            activeFixtureExchangeCountByTeammate[teammateID] = remaining
        }
    }

    private func markPendingMessageFailed(
        _ messageID: UUID,
        conversationID: UUID,
        reason: String
    ) {
        guard
            conversation.conversationID == conversationID,
            let pending = conversation.messages.first(where: { $0.id == messageID })
        else { return }
        conversation.replaceMessage(
            ChatMessageSnapshot(
                id: pending.id,
                author: pending.author,
                body: pending.body,
                delivery: .failed(reason),
                timestamp: pending.timestamp
            )
        )
    }

    private func setActivity(_ activity: TeammateActivityState, teammateID: UUID) {
        guard let current = sidebar.rows.first(where: { $0.id == teammateID }),
              current.activity != activity else { return }
        sidebar.update(
            TeammateRowSnapshot(
                identity: current.identity,
                activity: activity,
                unreadCount: current.unreadCount,
                lastActivityAt: current.lastActivityAt
            )
        )
    }

    private func recordMessageSequences(_ messages: [Message]) {
        var latestByConversation: [UUID: Date] = [:]
        for message in messages {
            messageSequenceByID[message.id.rawValue] = message.sequence
            let id = message.conversationID.rawValue
            latestByConversation[id] = max(latestByConversation[id] ?? message.createdAt, message.createdAt)
        }
        // Only repository-returned messages reach this path. Activity changes,
        // failed sends and local typing never manufacture a recency timestamp.
        for (conversationID, timestamp) in latestByConversation {
            guard let teammateID = teammateID(for: conversationID),
                  let current = sidebar.rows.first(where: { $0.id == teammateID }),
                  current.lastActivityAt.map({ timestamp > $0 }) ?? true else { continue }
            sidebar.update(TeammateRowSnapshot(
                identity: current.identity, activity: current.activity,
                unreadCount: current.unreadCount, lastActivityAt: timestamp
            ))
        }
    }

    private func setSelectionWithoutPersistence(_ teammateID: UUID?) {
        // Programmatic navigation also revokes already queued/in-flight work,
        // even when it returns to the same UUID before that work resumes.
        selectionGeneration &+= 1
        suppressSelectionObservation = true
        sidebar.selection = teammateID
        suppressSelectionObservation = false
    }

    private static func rowSnapshot(_ chat: DurableDirectChatSnapshot) -> TeammateRowSnapshot {
        TeammateRowSnapshot(
            identity: TeammateIdentitySnapshot(chat.teammate),
            activity: .idle,
            lastActivityAt: chat.conversation.updatedAt
        )
    }

    private static func messageSnapshot(
        _ message: Message,
        teammate: Teammate
    ) -> ChatMessageSnapshot {
        let author: ChatAuthorSnapshot
        switch message.author {
        case .user:
            author = .user
        case .system:
            author = .system(label: "OpenBots")
        case .teammate:
            author = .teammate(TeammateIdentitySnapshot(teammate))
        }

        let parts = message.parts.map { part -> ChatMessagePartSnapshot in
            let content: ChatMessagePartContentSnapshot
            switch part.content {
            case let .text(text):
                content = .text(text)
            case let .status(text):
                content = .status(text)
            case let .attachment(attachmentID):
                content = .attachment(
                    ChatAttachmentSnapshot(
                        id: attachmentID.rawValue,
                        displayName: "Attachment",
                        detail: "Saved local attachment reference"
                    )
                )
            case let .artifact(artifactID):
                content = .artifact(
                    ChatArtifactSnapshot(
                        id: artifactID.rawValue,
                        title: "Artifact",
                        detail: "Saved local artifact reference"
                    )
                )
            }
            return ChatMessagePartSnapshot(
                id: part.id.rawValue,
                ordinal: part.ordinal,
                content: content
            )
        }

        let delivery: MessageDeliveryState
        switch message.deliveryState {
        case .pending:
            delivery = .pending
        case .failed:
            delivery = .failed("Local delivery failed.")
        default:
            delivery = .sent
        }

        return ChatMessageSnapshot(
            id: message.id.rawValue,
            author: author,
            parts: parts,
            delivery: delivery,
            timestamp: message.createdAt
        )
    }

    private static func fixtureStreamChunks(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return [] }
        return stride(from: 0, to: words.count, by: 4).map { start in
            let end = min(start + 4, words.count)
            let phrase = words[start..<end].joined(separator: " ")
            return start == 0 ? phrase : " \(phrase)"
        }
    }

}

public struct DurableWorkspaceView: View {
    @ObservedObject private var model: DurableWorkspaceModel
    private let openSettings: @MainActor () -> Void
    private let openClaudeSetup: (@MainActor () -> Void)?

    public init(
        model: DurableWorkspaceModel,
        openSettings: @escaping @MainActor () -> Void,
        openClaudeSetup: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.openSettings = openSettings
        self.openClaudeSetup = openClaudeSetup
    }

    public var body: some View {
        if let search = model.searchCoordinator {
            BotWorkspaceSearchPresentation(coordinator: search) { detail in
                workspaceContent(searchDetail: detail)
            }
        } else {
            workspaceContent(searchDetail: nil)
        }
    }

    @ViewBuilder
    private func workspaceContent(searchDetail: AnyView?) -> some View {
        OpenBotsRootView(
            sidebar: model.sidebar,
            conversation: model.conversation,
            attachmentDraft: model.attachmentDraft,
            draftCoordinator: model.draftCoordinator,
            cardInteractions: model.cardInteractions,
            createTeammate: model.beginTeammateCreation,
            openSettings: openSettings,
            detailOverride: hiringDetail,
            searchOverlay: searchDetail,
            detailsPanel: detailsPanel,
            toggleDetails: model.toggleBotDetails,
            openSearch: searchAction,
            isCreatingTeammate: model.isCreatingTeammate,
            creationError: model.creationError,
            openClaudeSetup: openClaudeSetup,
            openArchivedBots: model.archiveModel.map { archive in { archive.isPresented = true } },
            openBotSettings: model.supportsBotProfileEditing ? model.requestBotSettings : nil,
            archiveBot: model.archiveModel != nil ? model.requestBotArchive : nil
        )
        .disabled(model.archiveModel?.isBusy == true)
        .sheet(isPresented: Binding(
            get: { model.archiveModel?.isPresented == true },
            set: { model.archiveModel?.isPresented = $0 }
        )) {
            if let archive = model.archiveModel {
                ArchivedBotsView(model: archive, restore: model.restoreBot)
                    .environment(\.profilePhotoPresentation, model.photoPresentation)
            }
        }
        .alert("Archive Bot", isPresented: Binding(
            get: { model.archiveModel?.isPresented == false && model.archiveModel?.errorMessage != nil },
            set: { if !$0 { model.archiveModel?.errorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.archiveModel?.errorMessage = nil } }
        message: { Text(model.archiveModel?.errorMessage ?? "") }
        .environment(\.attachmentPresentation, model.attachmentPresentation)
        .environment(\.profilePhotoPresentation, model.photoPresentation)
    }

    private var searchAction: (@MainActor () -> Void)? {
        guard let coordinator = model.searchCoordinator else { return nil }
        return { coordinator.present() }
    }

    private var hiringDetail: AnyView? {
        guard let hiringModel = model.hiringModel else { return nil }
        return AnyView(
            HiringConversationView(
                model: hiringModel,
                onHired: {
                    model.completeHiring(from: hiringModel)
                },
                onCancelled: {
                    model.completeHiringCancellation(from: hiringModel)
                }
            )
        )
    }

    private var detailsPanel: AnyView? {
        guard model.isBotDetailsPresented, model.hiringModel == nil,
              let teammate = model.selectedTeammate else { return nil }
        if let editor = model.profileEditor, editor.teammateID == teammate.id {
            return AnyView(TeammateProfileEditorView(
                model: editor, onSaved: model.profileDidSave,
                onCancelled: model.cancelProfileEditing,
                onBack: model.showBotDetails, onClose: model.closeBotDetails,
                modelStatus: model.textReplyCoordinator?.modelPresentation(for: model.conversation.conversationID)
            ).id(teammate.id))
        }
        return AnyView(BotDetailsView(
            teammate: teammate, canEdit: model.canEditSelectedProfile,
            onEdit: model.editSelectedProfile, onClose: model.closeBotDetails,
            canArchive: model.canArchiveSelectedBot,
            onArchive: { Task { await model.archiveSelectedBot() } },
            modelStatus: model.textReplyCoordinator?.modelPresentation(for: model.conversation.conversationID)
        ))
    }
}

/// Observe search independently without restoring the old global toolbar.
private struct BotWorkspaceSearchPresentation<Content: View>: View {
    @ObservedObject var coordinator: WorkspaceSearchCoordinator
    @ViewBuilder var content: (AnyView?) -> Content

    var body: some View {
        content(coordinator.isPresented ? AnyView(WorkspaceSearchView(coordinator: coordinator)) : nil)
    }
}

private struct AttachmentDraftUnavailableError: Error, Sendable {}
