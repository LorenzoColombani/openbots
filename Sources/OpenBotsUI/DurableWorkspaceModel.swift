import AppKit
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

/// Screen-scoped orchestration for the durable teammate/chat loop.
/// Repositories remain behind `DurableTeammateChatServing`; this model owns
/// presentation identity, selection generations, and row-local updates only.
@MainActor
public final class DurableWorkspaceModel: ObservableObject {
    public static let fixtureDeliveryDescription =
        "Messages save locally at once; replies are a preview fixture. Claude and tools are not running."
    public static let localDeliveryDescription =
        "Claude isn’t connected. Save messages and attachments on this Mac; drafts and history remain available. Nothing is sent automatically."
    /// Under the line that names what a reply's hires made: the
    /// app's own note, saved here, never a Claude reply that did not arrive.
    public static let hireNoteNotice = "OpenBots note · saved on this Mac"
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
    public let hiddenModel: BotHiddenModel?
    private let navigationService: (any TeammateNavigating)?
    private let deletionService: (any TeammateDeleting)?
    /// Bots Delete kept only for their team chat history: their messages
    /// there read as "Deleted bot", never "Former member".
    private var deletedBotIDs: Set<UUID> = []
    /// What the delete dialog shows: the bot, the profile revision it was
    /// confirmed at, and what goes with it.
    public struct BotDeleteRequest: Equatable, Sendable {
        public let id: UUID
        public let profileRevision: UInt64
        public let inventory: TeammateDeleteInventory
    }
    @Published public private(set) var deleteRequest: BotDeleteRequest?
    @Published public var deleteErrorMessage: String?
    @Published public private(set) var attachmentDraft: AttachmentDraftModel
    @Published public private(set) var cardInteractions: ConversationCardInteractionModel?
    public private(set) lazy var conversation = makeConversationModel()

    @Published public var hiringModel: HiringConversationModel?
    @Published public private(set) var profileEditor: TeammateProfileEditorModel?
    @Published public private(set) var isBotDetailsPresented = false
    /// The team member whose own settings the details pane is showing, while
    /// the sidebar stays on the team. A hint, not authority: every read
    /// revalidates it against the open team's active roster, so a member that
    /// leaves stops resolving instead of leaving the pane on a stale bot.
    @Published public private(set) var memberDetailsTargetID: UUID?
    /// Outcome of the last export request, shown once and cleared by the user.
    @Published public var exportNotice: String?
    @Published public private(set) var isExporting = false
    private let exportService: ConversationExportService?
    public var supportsConversationExport: Bool { exportService != nil && !isExporting && !isShuttingDown && !didFinishShutdown }
    public var supportsExport: Bool { supportsConversationExport && selectedTeammate != nil }

    private let teamService: (any TeamChatServing)?
    private let handoffService: (any HandoffServing)?
    /// The open team's handoff cards, oldest first, for the "what happened"
    /// record. A card is never a transcript row.
    @Published public private(set) var handoffCards: [WorkRecordHandoffCard] = []
    /// The openable record of the open conversation: briefs, the cards the
    /// user answered and what each bot did on the Mac.
    @Published public private(set) var isShowingWorkRecord = false
    @Published public private(set) var workRecord: ConversationWorkRecord?
    private let workRecordService: (any ConversationWorkRecordLoading)?
    public var canShowWorkRecord: Bool { workRecordService != nil && conversation.conversationID != nil }
    /// Installed-app composition owns delivery; fixtures and tests omit it.
    public weak var notifications: BotNotificationModel?
    /// The handoff legs this screen has dispatched and not yet seen finish. A
    /// reload arriving mid-leg must not start the same one a second time.
    private var dispatchingHandoffIDs: Set<UUID> = []
    /// The briefs this workspace watched its own completed turns stage, under
    /// the conversation each belongs to: the records anchored on the reply
    /// that turn saved. Only these send themselves, and one turned away before
    /// its accept leaves the set and goes back to being a person's to send.
    /// Kept per conversation so a Stop ends the chain of the room it was
    /// pressed in and no other. Session-scoped on purpose: it is the live
    /// chain the user started, never a durable column, so nothing survives a
    /// relaunch into being woken by it.
    private var sessionStagedHandoffIDs: [UUID: Set<UUID>] = [:]
    /// Team conversations whose chain the user stopped and whose stopped turn
    /// has not yet reached its end. Stop ends the whole chain, not only what is
    /// running: the briefs already waiting leave the set at once, and this is
    /// what keeps the turn being stopped from staging the ones it was still
    /// writing. The stopped run's own end gives the entry up — a typed turn's
    /// when it finishes, a leg's when it is judged, where it is also what
    /// redraws a pressed card the Stop left without a control — and a turn a
    /// person starts afterwards clears it too, since starting one is what
    /// resumes a chain.
    private var stoppedHandoffChainConversationIDs: Set<UUID> = []
    private var teamChatsByID: [UUID: TeamChatSnapshot] = [:] {
        didSet { publishHiddenTeamMembers() }
    }
    @Published public private(set) var teamCreation: TeamCreationModel?
    /// The same bounded sheet, seeded with the selected team. Held separately
    /// from `teamCreation` so neither can silently replace the other's
    /// unfinished draft.
    @Published public private(set) var teamEditor: TeamCreationModel?
    /// The Access sheet, one bot at a time: every switch that bot has, over
    /// the same stores Details and Settings write. Opened from Details and
    /// from a sidebar row.
    @Published public private(set) var botAccess: BotAccessModel?

    @Published public private(set) var isCreatingTeammate = false
    @Published public private(set) var creationError: String?

    private let service: any DurableTeammateChatServing
    private let textReplyService: (any ClaudeTextReplyServing)?
    private let agenticJobService: (any AgenticJobServing)?
    private let agenticJobAccess: AgenticJobAccessStore?
    public let agenticJobAccessModel: AgenticJobAccessModel?
    /// The connector grants, shown in a bot's Details. Deliberately not tied to
    /// the sample-folder job service the way the switch model is: browsing is
    /// its own grant and must not inherit that coupling.
    public let connectorAccessStore: ConnectorAccessStore?
    /// The user's Messages conversations, for choosing the chats each bot may
    /// read on its Access sheet. Nil in tests, which must never read a real history.
    private let messagesChats: (any MessagesChatDirectory)?
    /// The selected bot's folders on the Mac, for Details.
    public let botWorkspaceModel: BotWorkspaceModel?
    private var agenticJobSubmissions: Set<UUID> = []
    fileprivate lazy var agenticJobCoordinator: AgenticJobCoordinator? = {
        guard let agenticJobService, let agenticJobAccess else { return nil }
        return AgenticJobCoordinator(service: agenticJobService, access: agenticJobAccess,
            changed: { [weak self] in self?.refreshAgenticJobPresentation() },
            completed: { [weak self] id in self?.agenticJobCompleted(conversationID: id) })
    }()
    fileprivate lazy var textReplyCoordinator: ClaudeTextReplyCoordinator? = textReplyService.map {
        let coordinator = ClaudeTextReplyCoordinator(service: $0) { [weak self] in self?.refreshTextReplyPhase() }
        // Deferred: whoever ended the turn goes first (a lead's report, the
        // next brief), and a worker's result waits for the room.
        coordinator.conversationFreed = { [weak self] _ in Task { @MainActor [weak self] in self?.drainWorkerWakes() } }
        return coordinator
    }
    /// Throwaway workers: what runs them. Nil keeps
    /// every reply's workers unrun, and none is ever offered without it.
    private let workerService: (any TeammateWorking)?
    /// One worker this session is running, by its id, with its holder's name
    /// for the line a quit leaves. Session-scoped on purpose: a worker is never
    /// a durable row, so nothing survives a relaunch into being woken by it.
    private struct RunningWorker {
        let worker: TeammateWorker
        let holderName: String
        var task: Task<Void, Never>?
    }
    private var runningWorkers: [UUID: RunningWorker] = [:]
    /// Results waiting for their holder to be free, oldest first.
    private var pendingWorkerWakes: [(worker: TeammateWorker, holderName: String, result: TeammateWorkerResult)] = []
    /// Wakes whose turn is under way, by worker id.
    private var wakingWorkerIDs: Set<UUID> = []
    /// Wakes whose note the service has saved: from then on the wake's own
    /// turn is the record of how it ended, a quit included.
    private var wakeNotesSavedWorkerIDs: Set<UUID> = []
    /// Team chats whose own chain comes first: a turn there just ended and its
    /// briefs and cards are still being settled, or a brief is on its way out.
    /// A worker's result waits until the chain has had its turn.
    private var teamChainConversationIDs: [UUID: Int] = [:]
    private func beginTeamChainStep(_ conversationID: UUID) { teamChainConversationIDs[conversationID, default: 0] += 1 }
    private func endTeamChainStep(_ conversationID: UUID) {
        let left = (teamChainConversationIDs[conversationID] ?? 1) - 1
        teamChainConversationIDs[conversationID] = left > 0 ? left : nil
        drainWorkerWakes()
    }
    /// Chats where the user pressed Stop since their wake began: a wake stopped any
    /// other way (a message typed over it, a switch taken away) goes again.
    private var stopPressedConversationIDs: Set<UUID> = []
    /// Workers the user's Stop ended while they ran: their end
    /// leaves a line and wakes nobody.
    private var stoppedByHimWorkerIDs: Set<UUID> = []
    private var deliveryNotices: [UUID: String] = [:]
    private var provenanceRequests: [ConversationID: [MessageID: UUID]] = [:]
    private var textTurnReplyMessageIDs: Set<UUID> = []
    /// Reply message IDs whose turn ended with the bot declining to answer.
    /// Filled by this session's own turns and, on load, from the saved outcome,
    /// so a relaunch still reads the decision rather than a failure.
    private var declinedReplyMessageIDs: Set<UUID> = []
    /// Reply message ID to the bot its run was journalled against. A
    /// memory-qualified reply is stored app-authored, so only the run
    /// still names the member that wrote it.
    private var textTurnReplyTeammates: [UUID: UUID] = [:]
    /// Presentation ownership follows the coordinator's reservation, including
    /// internal team legs. Late progress cannot move a newer turn's avatar.
    private struct TextReplyAvatarTurn {
        let reservation: UUID
        let teammateID: UUID
        var workingActivity: TeammateActivityState = .thinkingOrWorking
        var approvalID: UUID?
        var questionID: UUID?
        var activity: TeammateActivityState {
            approvalID != nil || questionID != nil ? .waitingForUser : workingActivity
        }
    }
    private var textReplyAvatarTurns: [UUID: TextReplyAvatarTurn] = [:]
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
        notifications?.stop()
        sidebar.cancelCreationReveal()
        textReplyCoordinator?.beginShutdown()
        // A worker's result lives in memory only: a quit stops every worker,
        // and `flushForShutdown` leaves one line in each holder's chat.
        runningWorkers.values.forEach { $0.task?.cancel() }
        agenticJobCoordinator?.beginShutdown()
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
            Task { @MainActor [weak self] in await self?.runRecoveryModel?.flushForShutdown() ?? true },
            Task { @MainActor [weak self] in await self?.agenticJobCoordinator?.flushForShutdown() ?? true },
            Task { @MainActor [weak self] in await self?.noteWorkersEndedByQuit() ?? true }
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
        agenticJobService: (any AgenticJobServing)? = nil,
        agenticJobAccess: AgenticJobAccessStore? = nil,
        connectorAccess: ConnectorAccessStore? = nil,
        messagesChats: (any MessagesChatDirectory)? = nil,
        hiringService: any HiringConversationServing,
        profileService: (any TeammateProfileEditing)? = nil,
        archiveService: (any TeammateArchiving)? = nil,
        teamArchiveService: (any TeamArchiving)? = nil,
        navigationService: (any TeammateNavigating)? = nil,
        deletionService: (any TeammateDeleting)? = nil,
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
        savedOutcomeHistoryModel: SavedOutcomeHistoryModel? = nil,
        exportService: ConversationExportService? = nil,
        teamService: (any TeamChatServing)? = nil,
        handoffService: (any HandoffServing)? = nil,
        botWorkspaces: BotWorkspaceService? = nil,
        workRecordService: (any ConversationWorkRecordLoading)? = nil,
        workerService: (any TeammateWorking)? = nil
    ) {
        self.exportService = exportService
        self.workerService = mode == .localOnly ? workerService : nil
        self.workRecordService = mode == .localOnly ? workRecordService : nil
        self.botWorkspaceModel = mode == .localOnly ? botWorkspaces.map(BotWorkspaceModel.init(service:)) : nil
        self.teamService = mode == .localOnly ? teamService : nil
        self.handoffService = mode == .localOnly ? handoffService : nil
        self.mode = mode
        self.service = service
        self.textReplyService = mode == .localOnly ? textReplyService : nil
        self.agenticJobService = mode == .localOnly ? agenticJobService : nil
        self.agenticJobAccess = mode == .localOnly ? agenticJobAccess : nil
        self.connectorAccessStore = mode == .localOnly ? connectorAccess : nil
        self.messagesChats = mode == .localOnly ? messagesChats : nil
        self.agenticJobAccessModel = mode == .localOnly && agenticJobService != nil
            ? agenticJobAccess.map { AgenticJobAccessModel(store: $0) } : nil
        self.hiringService = hiringService
        self.profileService = profileService
        archiveModel = archiveService.map { BotArchiveModel(service: $0, teamService: teamArchiveService) }
        self.navigationService = navigationService
        self.deletionService = deletionService
        hiddenModel = navigationService.map(BotHiddenModel.init(service:))
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
        agenticJobAccessModel?.changed = { [weak self] in self?.refreshAgenticJobPresentation() }

        archiveModel?.objectWillChange.sink { [weak self] in self?.notifyWorkspaceChange() }
            .store(in: &cancellables)
        hiddenModel?.objectWillChange.sink { [weak self] in self?.notifyWorkspaceChange() }
            .store(in: &cancellables)

        sidebar.$selection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] selection in
                // Combine publishes this assignment synchronously on the main
                // actor. Capture suppression now; checking in the later Task
                // would let programmatic restore/create updates escape it.
                guard let self, !self.suppressSelectionObservation else { return }
                // A member's details pane belongs to the team it was opened
                // from; navigating away ends it, as it does for a bot's own.
                self.memberDetailsTargetID = nil
                // The panel is derived from the selected UUID, while its draft
                // remains owned by the original UUID through navigation.
                if self.profileEditor?.teammateID.rawValue != selection {
                    self.profileEditor = nil
                }
                if selection == nil { self.isBotDetailsPresented = false }
                self.notifyWorkspaceChange()
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
        // Hidden bots keep their names: a new bot's default name and a rename
        // are checked against them too, as the database already does (a hidden
        // "New Bot" once made every press of + fail).
        await hiddenModel?.load()
        guard !isShuttingDown, !Task.isCancelled else { return }
        let selected = try await service.selectedDirectChat()
        guard !isShuttingDown, !Task.isCancelled else { return }
        directChatsByTeammate = Dictionary(
            uniqueKeysWithValues: chats.map { ($0.teammate.id.rawValue, $0) }
        )
        sidebar.replace(rows: chats.map(Self.rowSnapshot))
        let teams = try await teamService?.activeTeamChats() ?? []
        guard !isShuttingDown, !Task.isCancelled else { return }
        await refreshDeletedBotIDs()
        guard !isShuttingDown, !Task.isCancelled else { return }
        teamChatsByID = Dictionary(uniqueKeysWithValues: teams.map { ($0.team.id.rawValue, $0) })
        sidebar.replaceTeams(teams.map(Self.teamRowSnapshot))
        collaborationModel?.replaceAvailableTeammates(
            chats.map { TeammateIdentitySnapshot($0.teammate) }
        )
        await collaborationModel?.load()
        guard !isShuttingDown, !Task.isCancelled else { return }

        guard let selected else {
            if let selectedTeam = try await teamService?.selectedTeamChat(),
               let team = teamChatsByID[selectedTeam.team.id.rawValue] {
                guard !isShuttingDown, !Task.isCancelled else { return }
                setSelectionWithoutPersistence(team.team.id.rawValue)
                try await showTeam(team, messageLimit: messageLimit, expectedGeneration: selectionGeneration)
                return
            }
            setSelectionWithoutPersistence(nil)
            showConversation(
                conversationID: nil,
                title: "Conversation",
                messages: []
            )
            conversation.setInputAvailability(
                .unavailable(
                    reason: chats.isEmpty
                        ? "Create a bot to begin. Claude and tools remain disabled."
                        : "Choose a bot to open its local conversation."
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

    /// New Bot: click plus, a bot appears, asks what it is for, and sets itself
    /// up. The bot is made at once under a free placeholder name, its chat
    /// opens on its one question, and the user's answer sets it up. It replaces
    /// the earlier New Bot sheet. The review fixture keeps its hiring conversation.
    public func beginTeammateCreation() {
        guard !isShuttingDown, archiveModel?.isBusy != true, !isCreatingTeammate else { return }
        if mode == .reviewFixture {
            beginHiringFixture()
            return
        }
        guard mode == .localOnly, hiringModel == nil else { return }
        searchCoordinator?.close()
        // Claimed now, before the task starts, so a second press is refused
        // rather than making a second bot.
        // The name is chosen at the press too, from the roster as it is then.
        isCreatingTeammate = true
        let generation = selectionGeneration, name = freeName(from: "New Bot")
        Task { await createSelfSettingTeammate(named: name, expectedSelectionGeneration: generation) }
    }

    private func createSelfSettingTeammate(named name: String, expectedSelectionGeneration: UInt64) async {
        let id = UUID()
        do {
            let appearance = try Self.agentAppearance(Self.allocateCharacter(for: id))
            try await commitCreation(named: name, claimed: true, expectedSelectionGeneration: expectedSelectionGeneration) {
                try await self.service.createSelfSettingTeammateAndDirectChat(
                    teammateID: TeammateID(id), placeholderName: name, appearance: appearance)
            }
        } catch {
            isCreatingTeammate = false
            guard !isShuttingDown else { return }
            creationError = "Couldn’t create the bot. Your current chat and drafts are unchanged."
        }
    }

    /// The name an active bot already carries for `typed`, under the one rule
    /// the services and the handoff fence read (`TeammateProfile.namesMatch`),
    /// so two bots never share one. `excluded` is the bot being renamed, which
    /// keeps its own name in any case. Archived bots are not in the roster;
    /// hidden ones are counted, since they still hold their names.
    private func activeBotName(matching typed: String, excluding excluded: TeammateID? = nil) -> String? {
        (directChatsByTeammate.values.map(\.teammate) + (hiddenModel?.hiddenBots ?? []))
            .activeBot(named: typed, excluding: excluded)?.profile.displayName
    }

    /// A bot with the default name and a plain role that does not set itself
    /// up. The app's New Bot goes through `beginTeammateCreation`; this stays
    /// for fixtures and tests that need a bot in one call. Two bots never share
    /// a name, so the default name is numbered past the ones the roster
    /// already has: "New Bot", then "New Bot 2".
    public func createTeammateImmediately() async {
        guard mode == .localOnly, !isShuttingDown, archiveModel?.isBusy != true, !isCreatingTeammate,
              hiringModel == nil else { return }
        searchCoordinator?.close()
        let id = UUID()
        do {
            let appearance = try Self.agentAppearance(Self.allocateCharacter(for: id))
            let named = DurableTeammateDraft(teammateID: TeammateID(id), role: "Teammate", appearance: appearance)
            let draft = DurableTeammateDraft(
                teammateID: named.teammateID, displayName: freeName(from: named.displayName),
                role: named.role, appearance: appearance
            )
            try await commitTeammate(draft, expectedSelectionGeneration: selectionGeneration)
        } catch {
            guard !isShuttingDown else { return }
            creationError = "Couldn’t create the bot. Your current chat and drafts are unchanged."
        }
    }

    /// `base` if no bot the workspace knows carries it, else the first of
    /// "base 2", "base 3", … that none does. Archived bots count here, unlike
    /// in the rule itself: a bot made this way may be restored later, and a
    /// default name it shares with one would block that restore.
    private func freeName(from base: String) -> String {
        let known = directChatsByTeammate.values.map(\.teammate) + (archiveModel?.archivedBots ?? [])
            + (hiddenModel?.hiddenBots ?? [])
        var candidate = base
        var ordinal = 2
        while known.contains(where: { TeammateProfile.namesMatch($0.profile.displayName, candidate) }) {
            candidate = "\(base) \(ordinal)"
            ordinal += 1
        }
        return candidate
    }

    /// The creature a new bot is born with: a deterministic spawn from its id,
    /// by the domain's one allocation, which a hire uses too.
    static func allocateCharacter(for id: UUID) -> CharacterAppearanceSnapshot {
        CharacterAppearanceSnapshot(CreatureAllocation(id: id))
    }

    private static func agentAppearance(_ character: CharacterAppearanceSnapshot) throws -> AgentAppearance {
        try AgentAppearance(
            mode: character.mode, grammarVersion: character.grammarVersion,
            deterministicSeed: character.deterministicSeed,
            silhouette: character.silhouette, paletteToken: character.paletteToken,
            eyeDialect: character.eyeDialect, nonColorIdentityCue: character.nonColorIdentityCue,
            accessibleIdentityDescription: character.accessibleIdentityDescription,
            builtInAvatarID: character.builtInAvatarID,
            revision: character.revision
        )
    }

    /// The one creation path. The service commits the identity, empty chat
    /// and selection atomically; this then shows the row and the empty chat
    /// and selects it, unless the person navigated elsewhere meanwhile.
    private func commitTeammate(_ draft: DurableTeammateDraft, expectedSelectionGeneration: UInt64) async throws {
        try await commitCreation(named: draft.displayName, claimed: false,
                                 expectedSelectionGeneration: expectedSelectionGeneration) {
            try await self.service.createTeammateAndDirectChat(draft)
        }
    }

    /// `claimed` is true when the caller already set `isCreatingTeammate`.
    private func commitCreation(
        named displayName: String, claimed: Bool, expectedSelectionGeneration: UInt64,
        create: () async throws -> DurableTeammateChatCreationSnapshot
    ) async throws {
        guard mode == .localOnly, !isShuttingDown, claimed || !isCreatingTeammate, hiringModel == nil else {
            if claimed { isCreatingTeammate = false }
            throw TeammateCreationUnavailableError()
        }
        isCreatingTeammate = true
        creationError = nil
        defer { isCreatingTeammate = false }
        // Finish navigation already admitted before New Bot. A failed create
        // must not strand the prior chat in an interrupted loading state.
        await selectionTask?.value
        guard !isShuttingDown else { return }
        // The wait above is the one suspension between the sheet's live check
        // and the commit: a bot of that name can be made or renamed elsewhere
        // during it, so the roster is read once more here, after it. The
        // service reads the saved roster too, for callers that never opened
        // the sheet.
        if let existing = activeBotName(matching: displayName) {
            throw TeammateNameTakenError(existingName: existing)
        }
        do {
            let created = try await create()
            guard !isShuttingDown else { return }
            let chat = DurableDirectChatSnapshot(teammate: created.teammate, conversation: created.conversation)
            directChatsByTeammate[created.teammate.id.rawValue] = chat
            sidebar.replace(rows: Self.placing(Self.rowSnapshot(chat), in: sidebar.rows, first: true))
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
                    if let selectedID, let team = teamChatsByID[selectedID] {
                        try await teamService?.select(teamID: team.team.id)
                    } else if let selectedID {
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
            // A bot that sets itself up opens on its one question.
            let first = created.fixtureGreeting.map { [$0] } ?? []
            showConversation(
                conversationID: created.conversation.id.rawValue,
                title: created.teammate.profile.displayName,
                messages: first.map { Self.messageSnapshot($0, teammate: created.teammate) },
                hasEarlierMessages: false, includesFixtures: false
            )
            recordMessageSequences(first)
            conversation.setInputAvailability(.ready)
            sidebar.requestCreationReveal(created.teammate.id.rawValue)
        } catch {
            guard !isShuttingDown else { return }
            throw error
        }
    }

    public var selectedTeam: TeamChatSnapshot? {
        guard let id = sidebar.selection else { return nil }
        return teamChatsByID[id]
    }

    public var canCreateTeam: Bool {
        teamService != nil && mode == .localOnly && !isShuttingDown && hiringModel == nil
            && archiveModel?.isBusy != true && directChatsByTeammate.count >= 2
    }

    public func beginTeamCreation() {
        guard canCreateTeam, teamCreation == nil else { return }
        searchCoordinator?.close()
        let candidates = directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) }
        teamCreation = TeamCreationModel(candidates: candidates) { [weak self] name, leadID, memberIDs in
            try await self?.createTeam(name: name, leadID: leadID, memberIDs: memberIDs)
        }
    }

    public func dismissTeamCreation() {
        guard teamCreation?.isSubmitting != true else { return }
        teamCreation = nil
    }

    private func createTeam(name: String, leadID: UUID, memberIDs: Set<UUID>) async throws {
        guard let teamService, !isShuttingDown else { throw TeamCreationUnavailableError() }
        await selectionTask?.value
        let created = try await teamService.createTeamChat(TeamChatDraft(
            name: name, leadID: TeammateID(leadID), memberIDs: Set(memberIDs.map { TeammateID($0) })))
        guard !isShuttingDown else { return }
        teamChatsByID[created.team.id.rawValue] = created
        sidebar.replaceTeams(teamChatsByID.values.map(Self.teamRowSnapshot).sorted { $0.name < $1.name })
        teamCreation = nil
        profileEditor = nil
        isBotDetailsPresented = false
        setSelectionWithoutPersistence(created.team.id.rawValue)
        showConversation(conversationID: created.conversation.id.rawValue, title: created.team.name,
                         messages: [], hasEarlierMessages: false, includesFixtures: false)
        conversation.setInputAvailability(.ready)
    }

    /// The quiet-workspace half of the creation guard. Editing a team that
    /// already exists does not need two active bots in the workspace, only a
    /// workspace that is not busy elsewhere; the sheet's own rule (two members,
    /// one of them the lead) still refuses a save that would leave the team
    /// unusable, and a team whose bots were archived can at least be opened
    /// and read.
    public var canEditTeams: Bool {
        teamService != nil && mode == .localOnly && !isShuttingDown && hiringModel == nil
            && archiveModel?.isBusy != true
    }

    public var canEditSelectedTeam: Bool { canEditTeams && selectedTeam != nil }

    public func beginTeamEditing() {
        guard let team = selectedTeam else { return }
        beginTeamEditing(teamID: team.team.id.rawValue)
    }

    /// Opens the editor for any team the sidebar shows, not only the open one,
    /// so a row's context menu edits the row it was opened from instead of
    /// staying inert on every row but the selected one.
    public func beginTeamEditing(teamID: UUID) {
        guard canEditTeams, let team = teamChatsByID[teamID], teamEditor == nil, teamCreation == nil else { return }
        searchCoordinator?.close()
        // A hidden member keeps its seat, so it keeps its checkbox, checked: left out of the
        // candidates, a save would drop it. A hidden bot outside this team stays
        // out of the picker, as it stays out of the sidebar.
        let candidates = directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) }
            + team.members.filter { $0.isHidden && directChatsByTeammate[$0.id.rawValue] == nil }
                .map(TeammateIdentitySnapshot.init)
        let teamID = team.team.id
        // The instant the roster below was read. Carried to the write so a
        // second writer publishing while this sheet stands open refuses the
        // save rather than losing their roster to it.
        let seededAt = team.team.updatedAt
        // Seeded from the active roster: a member archived while the team still
        // names it cannot be shown as a checkbox, so saving would drop it.
        teamEditor = TeamCreationModel(mode: .edit, candidates: candidates, name: team.team.name,
            memberIDs: Set(team.members.map(\.id.rawValue)), leadID: team.lead?.id.rawValue) { [weak self] name, leadID, memberIDs in
            try await self?.saveTeamEdit(teamID: teamID, name: name, leadID: leadID, memberIDs: memberIDs,
                                         expectedUpdatedAt: seededAt)
        }
    }

    public func dismissTeamEditing() {
        guard teamEditor?.isSubmitting != true else { return }
        teamEditor = nil
    }

    private func saveTeamEdit(teamID: TeamID, name: String, leadID: UUID, memberIDs: Set<UUID>,
                              expectedUpdatedAt: Date) async throws {
        guard let teamService, !isShuttingDown else { throw TeamCreationUnavailableError() }
        await selectionTask?.value
        let saved: TeamChatSnapshot
        do {
            saved = try await teamService.updateTeamChat(TeamChatEdit(
                teamID: teamID, name: name, leadID: TeammateID(leadID), memberIDs: Set(memberIDs.map { TeammateID($0) }),
                expectedUpdatedAt: expectedUpdatedAt))
        } catch TeamChatError.teamChangedElsewhere(let refused) {
            // The refusal is proof this screen's snapshot is behind the other
            // writer's. Re-reading it here is what makes the sheet's own
            // message true: the editor opened next seeds from the roster that
            // exists and carries its instant, so that save is judged against
            // it instead of being refused for the same reason again.
            await reloadTeamChats()
            throw TeamChatError.teamChangedElsewhere(refused)
        }
        guard !isShuttingDown else { return }
        teamChatsByID[saved.team.id.rawValue] = saved
        sidebar.updateTeam(Self.teamRowSnapshot(saved))
        teamEditor = nil
        // The open transcript's header and roster are presented from the
        // snapshot this screen holds, so a renamed team and a changed roster
        // must both be re-read before the sheet's caller returns.
        await reloadTeamChats()
    }

    /// The hidden bots that sit in a team get a live row of their own for the
    /// team surfaces, never one in the list. Their motion there is the
    /// conversation's own (`workingAvatarByConversation`), so this row only
    /// carries the face and the name.
    private func publishHiddenTeamMembers() {
        var seen: Set<UUID> = []
        let rows = teamChatsByID.values.flatMap(\.members)
            .filter { $0.isHidden && $0.lifecycle == .active && directChatsByTeammate[$0.id.rawValue] == nil }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            .filter { seen.insert($0.id.rawValue).inserted }
            .map { TeammateRowSnapshot(identity: TeammateIdentitySnapshot($0), activity: .idle, isPinned: $0.isPinned) }
        sidebar.replaceHiddenMembers(rows)
    }

    private static func teamRowSnapshot(_ chat: TeamChatSnapshot) -> TeamRowSnapshot {
        TeamRowSnapshot(id: chat.team.id.rawValue,
                        conversationID: chat.conversation.id.rawValue,
                        name: chat.team.name,
                        leadName: chat.lead?.profile.displayName ?? "—",
                        members: chat.members.map { .init(id: $0.id.rawValue, name: $0.profile.displayName) },
                        lastActivityAt: chat.conversation.updatedAt)
    }

    private func teamChat(for conversationID: UUID?) -> TeamChatSnapshot? {
        guard let conversationID else { return nil }
        return teamChatsByID.values.first { $0.conversation.id.rawValue == conversationID }
    }

    /// The one predicate that decides a conversation is a team's. Withholding
    /// the attachment draft and admitting a send must never disagree about
    /// that: the send would be refused for a draft that was never created.
    private func isTeamConversation(_ conversationID: UUID?) -> Bool {
        teamChat(for: conversationID) != nil
    }

    /// Bots that can author a message in this conversation, for attribution.
    private func roster(for conversationID: UUID) -> [UUID: Teammate] {
        guard let team = teamChat(for: conversationID) else { return [:] }
        return Dictionary(uniqueKeysWithValues: team.members.map { ($0.id.rawValue, $0) })
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
        // A team row is a selection with no teammate profile behind it.
        !isShuttingDown && archiveModel?.isBusy != true && profileService != nil && selectedTeammate != nil && hiringModel == nil
    }

    var supportsBotProfileEditing: Bool { profileService != nil }

    /// The sheet exists wherever the app keeps at least one of the two stores
    /// it reads; a review-fixture workspace keeps neither and shows no button.
    public var supportsBotAccess: Bool { agenticJobAccess != nil || connectorAccessStore != nil }

    /// Opens the Access sheet for one bot by id, from its sidebar row or its
    /// Details pane. The selection is not moved: the sheet is about that bot,
    /// whichever conversation is open, exactly as the old app's profile sheet
    /// was about its seat.
    public func openBotAccess(id: UUID) {
        guard !isShuttingDown, supportsBotAccess, let chat = directChatsByTeammate[id] else { return }
        botAccess?.stopObserving()
        botAccess = BotAccessModel(teammateID: chat.teammate.id, botName: chat.teammate.profile.displayName,
                                   switches: agenticJobAccess, connectors: connectorAccessStore,
                                   messages: messagesChats)
    }

    public func dismissBotAccess() {
        botAccess?.stopObserving()
        botAccess = nil
    }

    func requestBotSettings(id: UUID) {
        enqueueBotContextAction { await $0.openBotSettings(id: id) }
    }

    func requestBotArchive(id: UUID) {
        enqueueBotContextAction { await $0.archiveBot(id: id) }
    }

    func requestTeamArchive(id: UUID) {
        enqueueBotContextAction { await $0.archiveTeam(id: id) }
    }

    func requestBotPin(id: UUID) {
        enqueueBotContextAction { await $0.togglePinBot(id: id) }
    }

    func requestBotHide(id: UUID) {
        enqueueBotContextAction { await $0.hideBot(id: id) }
    }

    func requestBotDelete(id: UUID) {
        enqueueBotContextAction { await $0.prepareDeleteBot(id: id) }
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

    public var deletionServiceAvailable: Bool { deletionService != nil }

    public var canArchiveSelectedBot: Bool {
        !isShuttingDown && archiveModel != nil && archiveModel?.isBusy == false
            && selectedTeammate != nil && hiringModel == nil && !isCreatingTeammate
    }


    /// Where the saved order reads a bot that has just joined the list: pinned bots
    /// come first, so a new or hired bot, never
    /// pinned, leads the unpinned ones, and a restored bot, appended by the order's
    /// triggers, ends its own group. Drawing it anywhere else made the next drag
    /// fail as stale.
    static func placing(_ row: TeammateRowSnapshot, in rows: [TeammateRowSnapshot],
                        first: Bool) -> [TeammateRowSnapshot] {
        let others = rows.filter { $0.id != row.id }
        let group = others.filter { $0.isPinned == row.isPinned }
        let placed = first ? [row] + group : group + [row]
        let pinned = row.isPinned ? placed : others.filter(\.isPinned)
        let unpinned = row.isPinned ? others.filter { !$0.isPinned } : placed
        return pinned + unpinned
    }

    public func togglePinBot(id: UUID) async {
        guard let navigationService, let chat = directChatsByTeammate[id], !isShuttingDown else { return }
        do {
            let saved = try await navigationService.setPinned(
                id: chat.teammate.id,
                pinned: !chat.teammate.isPinned,
                expectedProfileRevision: chat.teammate.profile.revision
            )
            guard !isShuttingDown else { return }
            applyTeammateNavigation(saved)
            // Pinned bots sit above the rest.
            if let sidebarOrderCoordinator {
                await sidebarOrderCoordinator.refresh()
            } else {
                let rows = sidebar.rows
                sidebar.replace(rows: rows.filter(\.isPinned) + rows.filter { !$0.isPinned })
            }
        } catch {
            deleteErrorMessage = "Couldn’t change pin. Your saved bots are unchanged."
        }
    }

    public func hideBot(id: UUID) async {
        guard let navigationService, let chat = directChatsByTeammate[id], !isShuttingDown else { return }
        do {
            let saved = try await navigationService.setHidden(
                id: chat.teammate.id,
                hidden: true,
                expectedProfileRevision: chat.teammate.profile.revision
            )
            guard !isShuttingDown, saved.isHidden else { return }
            directChatsByTeammate.removeValue(forKey: id)
            if sidebar.selection == id {
                searchCoordinator?.close()
                setSelectionWithoutPersistence(nil)
                profileEditor = nil
                isBotDetailsPresented = false
                showConversation(conversationID: nil, title: "Conversation", messages: [])
                conversation.setInputAvailability(.unavailable(reason: "Bot hidden. Unhide it from Hidden Bots."))
            }
            sidebar.replace(rows: sidebar.rows.filter { $0.id != id })
            collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
            await hiddenModel?.load()
            await reloadTeamChats()
        } catch {
            deleteErrorMessage = "Couldn’t hide this bot. Your saved bots are unchanged."
        }
    }

    public func unhideBot(_ teammate: Teammate) async {
        guard let hiddenModel, !isShuttingDown else { return }
        guard let saved = await hiddenModel.setHidden(teammate, hidden: false), !saved.isHidden else { return }
        guard !isShuttingDown else { return }
        // Reload roster so the unhidden bot returns with its conversation.
        if let chats = try? await service.activeDirectChats(), !isShuttingDown {
            directChatsByTeammate = Dictionary(uniqueKeysWithValues: chats.map { ($0.teammate.id.rawValue, $0) })
            sidebar.replace(rows: chats.map(Self.rowSnapshot))
            collaborationModel?.replaceAvailableTeammates(chats.map { TeammateIdentitySnapshot($0.teammate) })
        }
        await reloadTeamChats()
    }

    public func prepareDeleteBot(id: UUID) async {
        guard let deletionService, !isShuttingDown else { return }
        guard !hasWorkerWork(holderID: id) else { deleteErrorMessage = Self.workerRunningDeleteMessage; return }
        guard let chat = directChatsByTeammate[id] else {
            deleteErrorMessage = Self.deleteMessage(for: .notFound)
            return
        }
        do {
            let inventory = try await deletionService.inventory(id: chat.teammate.id)
            guard !isShuttingDown else { return }
            deleteRequest = BotDeleteRequest(id: id, profileRevision: chat.teammate.profile.revision,
                                             inventory: inventory)
        } catch let error as TeammateDeleteError {
            deleteErrorMessage = Self.deleteMessage(for: error)
        } catch {
            deleteErrorMessage = "Couldn’t prepare delete. Your saved bots are unchanged."
        }
    }

    /// Deletes the bot the dialog showed. The dialog's button hands over its
    /// own copy of the request, because SwiftUI clears the dialog's binding,
    /// and with it `deleteRequest`, before the button's task runs.
    public func confirmDeleteBot(_ request: BotDeleteRequest) async {
        if deleteRequest == request { deleteRequest = nil }
        guard let deletionService, !isShuttingDown else { return }
        let id = request.id
        guard !hasWorkerWork(holderID: id) else { deleteErrorMessage = Self.workerRunningDeleteMessage; return }
        guard let chat = directChatsByTeammate[id] else {
            deleteErrorMessage = Self.deleteMessage(for: .notFound)
            return
        }
        do {
            _ = try await deletionService.deleteTeammate(
                id: chat.teammate.id,
                expectedProfileRevision: request.profileRevision
            )
            guard !isShuttingDown else { return }
            directChatsByTeammate.removeValue(forKey: id)
            profileDrafts.removeValue(forKey: id)
            if sidebar.selection == id {
                searchCoordinator?.close()
                setSelectionWithoutPersistence(nil)
                profileEditor = nil
                isBotDetailsPresented = false
                showConversation(conversationID: nil, title: "Conversation", messages: [])
                conversation.setInputAvailability(.unavailable(reason: "Bot deleted."))
            }
            sidebar.replace(rows: sidebar.rows.filter { $0.id != id })
            collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
            await reloadTeamChats()
        } catch let error as TeammateDeleteError {
            deleteErrorMessage = Self.deleteMessage(for: error)
        } catch {
            // Not a refusal Delete knows: a gap in Delete itself, kept for diagnosis.
            AgenticDiagnosticsLog.error("delete", String(describing: error))
            deleteErrorMessage = "Couldn’t delete this bot. Your saved data is preserved."
        }
    }

    public func cancelDeleteBot() {
        deleteRequest = nil
    }

    private func applyTeammateNavigation(_ teammate: Teammate) {
        let id = teammate.id.rawValue
        guard var chat = directChatsByTeammate[id] else { return }
        chat = DurableDirectChatSnapshot(teammate: teammate, conversation: chat.conversation)
        directChatsByTeammate[id] = chat
        let previous = sidebar.rows.first(where: { $0.id == id })
        sidebar.update(TeammateRowSnapshot(
            identity: TeammateIdentitySnapshot(teammate),
            activity: previous?.activity ?? .idle,
            unreadCount: previous?.unreadCount ?? 0,
            lastActivityAt: previous?.lastActivityAt ?? chat.conversation.updatedAt,
            isPinned: teammate.isPinned
        ))
    }

    private static func deleteMessage(for error: TeammateDeleteError) -> String {
        switch error {
        case .isTeamLead(let name):
            return "Assign a different lead for \(name) before deleting this bot. Nothing was deleted."
        case .unresolvedWork:
            return "This bot still has work in progress. Let it finish or stop it before deleting. Nothing was deleted."
        case .staleRevision:
            return "This bot changed in another operation. Refresh and try again."
        case .notFound:
            return "This bot is no longer available. Refresh the bot list."
        case .invalidDate:
            return "Couldn’t delete this bot. Your saved data is preserved."
        }
    }

    public func archiveSelectedBot() async {
        guard canArchiveSelectedBot, let teammate = selectedTeammate, let archiveModel else { return }
        let generation = selectionGeneration
        let originalConversation = conversation.conversationID
        let savingHere = { [self] in
            originalConversation.map { conversation.hasPendingSubmissions(in: $0) } ?? conversation.hasPendingSubmissions
        }
        let saved = await archiveModel.archive(teammate) { [self] in
            let editor = profileDrafts[teammate.id.rawValue]
            guard editor?.isImportingPhoto != true, editor?.isSaving != true else {
                throw ArchivePreparationError.profileOperationPending
            }
            guard profileDrafts[teammate.id.rawValue]?.hasUnsavedChanges != true else {
                throw ArchivePreparationError.unfinishedEdits
            }
            // A worker it started runs, or its result waits for it.
            guard !hasWorkerWork(holderID: teammate.id.rawValue) else { throw ArchivePreparationError.workerRunning }
            // A message saving into this bot's chat, not any chat.
            guard !savingHere(),
                  activeFixtureExchangeCountByTeammate[teammate.id.rawValue, default: 0] == 0,
                  !attachmentDraft.rows.contains(where: { row in
                      if row.isRemoving { return true }
                      if case .pending = row.state { return true }
                      return false
                  }) else { throw ArchivePreparationError.unresolvedLocalWork }
            if let draftCoordinator {
                // Saving drafts waits for every message in flight, in any chat.
                switch await draftCoordinator.flushAllExplained() {
                case .saved: break
                case .messageInFlight: throw ArchivePreparationError.messageSavingElsewhere
                case .draftFailed: throw ArchivePreparationError.draftNotSaved
                }
            } else if !conversation.composerText.isEmpty {
                throw ArchivePreparationError.draftNotSaved
            }
            guard !isShuttingDown, generation == selectionGeneration,
                  originalConversation == conversation.conversationID,
                  sidebar.selection == teammate.id.rawValue,
                  !savingHere() else { throw ArchivePreparationError.navigationChanged }
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
            conversation.setInputAvailability(.unavailable(reason: "Bot archived. Restore it from Archived."))
        }
        // The repository already cleared only this bot's persisted selection.
        // Do not clear it again after an await and erase newer navigation.
        sidebar.replace(rows: sidebar.rows.filter { $0.id != teammate.id.rawValue })
        collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
        await reloadTeamChats()
    }

    /// A team snapshot carries its own copy of the roster, so an archive or a
    /// restore in this session leaves it stale: the row still counts the bot,
    /// the composer still promises it, and a send routed to it fails
    /// downstream as a Claude connection problem instead of the real reason.
    private func reloadTeamChats() async {
        guard let teamService, !isShuttingDown,
              let teams = try? await teamService.activeTeamChats(), !isShuttingDown else { return }
        await refreshDeletedBotIDs()
        guard !isShuttingDown else { return }
        teamChatsByID = Dictionary(uniqueKeysWithValues: teams.map { ($0.team.id.rawValue, $0) })
        sidebar.replaceTeams(teams.map(Self.teamRowSnapshot))
        // A member's details pane cannot outlive that member's place in the
        // roster: the pane already stops resolving, and this collapses it.
        if memberDetailsTargetID != nil, detailsTeammate == nil { closeBotDetails() }
        // The open team conversation is presented from that same snapshot.
        guard let selectedID = sidebar.selection, let team = teamChatsByID[selectedID] else { return }
        try? await showTeam(team, messageLimit: messagePageLimit, expectedGeneration: selectionGeneration)
    }

    /// A failed read keeps the last answer: a deleted bot's words fall back to
    /// "Former member" at worst, never to another bot's name.
    private func refreshDeletedBotIDs() async {
        guard let deletionService, let ids = try? await deletionService.deletedTeammateIDs() else { return }
        deletedBotIDs = Set(ids.map(\.rawValue))
    }

    /// A teammate a bot's reply hired: its row at the top of the
    /// sidebar, where a bot made by hand lands, and, when it joined a team,
    /// that team's roster, so its replies there carry its name and a handoff
    /// card for it resolves. The selection stays where the person has it.
    private func presentHiredTeammate(_ hire: TeammateHire) async {
        guard !isShuttingDown, let chats = try? await service.activeDirectChats(), !isShuttingDown,
              let chat = chats.first(where: { $0.teammate.id == hire.teammateID }) else { return }
        directChatsByTeammate[hire.teammateID.rawValue] = chat
        sidebar.replace(rows: Self.placing(Self.rowSnapshot(chat), in: sidebar.rows, first: true))
        collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
        guard hire.joinedTeam, let teamService, let teams = try? await teamService.activeTeamChats(), !isShuttingDown else { return }
        teamChatsByID = Dictionary(uniqueKeysWithValues: teams.map { ($0.team.id.rawValue, $0) })
        sidebar.replaceTeams(teams.map(Self.teamRowSnapshot))
    }

    /// Archive Team: the team leaves the sidebar, its
    /// chat and records stay. Refused while its chat has work in progress; an
    /// open chat's draft is saved first and the chat closes.
    public func archiveTeam(id: UUID) async {
        guard !isShuttingDown, let archiveModel, archiveModel.supportsTeams, !archiveModel.isBusy,
              let chat = teamChatsByID[id] else { return }
        let conversationID = chat.conversation.id.rawValue
        let saved = await archiveModel.archiveTeam(chat.team) { [self] in
            if let phase = textReplyCoordinator?.phase(for: conversationID), phase.isBusy {
                throw ArchivePreparationError.teamWorkInProgress
            }
            // A worker started in the team's chat is work in progress there.
            guard !hasWorkerWork(conversationID: conversationID) else { throw ArchivePreparationError.teamWorkInProgress }
            // A message still saving into this team's chat, open or not. No
            // new one can start: every send is refused while the archive is busy.
            guard !self.conversation.hasPendingSubmissions(in: conversationID) else {
                throw ArchivePreparationError.teamMessageSaving
            }
            guard self.conversation.conversationID == conversationID else { return }
            if let draftCoordinator {
                // Saving drafts waits for every message in flight, in any chat.
                switch await draftCoordinator.flushAllExplained() {
                case .saved: break
                case .messageInFlight: throw ArchivePreparationError.messageSavingElsewhere
                case .draftFailed: throw ArchivePreparationError.draftNotSaved
                }
            }
        }
        guard !isShuttingDown else { return }
        guard saved != nil else {
            // A refusal may mean the team moved: read it afresh for the retry.
            await reloadTeamChats()
            return
        }
        if sidebar.selection == id || conversation.conversationID == conversationID {
            searchCoordinator?.close()
            setSelectionWithoutPersistence(nil)
            isBotDetailsPresented = false
            showConversation(conversationID: nil, title: "Conversation", messages: [])
            conversation.setInputAvailability(.unavailable(reason: "Team archived. Restore it from Archived."))
        }
        // The repository already cleared a persisted selection of its chat.
        await reloadTeamChats()
    }

    public func restoreTeam(_ team: Team) async {
        guard !isShuttingDown, let archiveModel, await archiveModel.restoreTeam(team) != nil else { return }
        await reloadTeamChats()
    }

    func refreshTeams() async { await reloadTeamChats() }

    public func restoreBot(_ teammate: Teammate) async {
        guard !isShuttingDown, let archiveModel, await archiveModel.restore(teammate) != nil else { return }
        do {
            let chats = try await service.activeDirectChats()
            guard !isShuttingDown, let chat = chats.first(where: { $0.teammate.id == teammate.id }) else { return }
            directChatsByTeammate[teammate.id.rawValue] = chat
            sidebar.replace(rows: Self.placing(Self.rowSnapshot(chat), in: sidebar.rows, first: false))
            collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map { TeammateIdentitySnapshot($0.teammate) })
            await reloadTeamChats()
        } catch {
            archiveModel.errorMessage = "The bot was restored, but its sidebar could not refresh. Reopen the workspace to see it."
        }
    }

    /// Writes the selected bot's conversations as Markdown and JSON into a new folder
    /// inside the folder the user picked. Nothing existing is overwritten.
    public func exportSelectedBotConversations(into folder: URL) async {
        guard let teammate = selectedTeammate else { return }
        await exportBotConversations(teammateID: teammate.id.rawValue, into: folder)
    }

    /// Settings can export an active bot without navigating away from the
    /// current team. Revalidate the selected inventory item when invoked.
    public func exportBotConversations(teammateID: UUID, into folder: URL) async {
        guard supportsConversationExport, let exportService,
              let teammate = directChatsByTeammate[teammateID]?.teammate, teammate.lifecycle == .active,
              sidebar.rowModels.contains(where: { $0.id == teammateID }) else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let receipt = try await exportService.export(.init(teammateID: teammate.id, destinationFolder: folder))
            exportNotice = "Exported \(receipt.conversationCount) conversation\(receipt.conversationCount == 1 ? "" : "s") and \(receipt.messageCount) message\(receipt.messageCount == 1 ? "" : "s") to \(receipt.folderURL.lastPathComponent)."
        } catch {
            exportNotice = "The export could not be written: \(String(describing: error)). Nothing was changed."
        }
    }

    public func toggleBotDetails() {
        if isBotDetailsPresented { closeBotDetails() } else { showBotDetails() }
    }

    /// A notification opens an existing conversation through ordinary sidebar
    /// navigation. It never submits text, retries a run, or resumes a chain.
    @discardableResult
    public func openNotificationConversation(id: UUID) -> Bool {
        guard !isShuttingDown, !didFinishShutdown, hiringModel == nil else { return false }
        if let chat = directChatsByTeammate.values.first(where: { $0.conversation.id.rawValue == id }),
           sidebar.rows.contains(where: { $0.id == chat.teammate.id.rawValue }) {
            searchCoordinator?.close()
            sidebar.selection = chat.teammate.id.rawValue
            return true
        }
        if let team = teamChatsByID.values.first(where: { $0.conversation.id.rawValue == id }) {
            searchCoordinator?.close()
            sidebar.selection = team.team.id.rawValue
            return true
        }
        return false
    }

    public func showBotDetails() {
        guard !isShuttingDown, hiringModel == nil, selectedTeammate != nil else { return }
        searchCoordinator?.close()
        profileEditor = nil
        isBotDetailsPresented = true
    }

    /// The bot the details pane is about: a member opened from inside the open
    /// team, otherwise the bot whose own chat is selected. Resolved on every
    /// read against the team's active roster and the active direct chats, so a
    /// member archived or removed while its pane is open resolves to nothing.
    public var detailsTeammate: Teammate? {
        guard let id = memberDetailsTargetID else { return selectedTeammate }
        guard let team = selectedTeam, team.members.contains(where: { $0.id.rawValue == id }),
              let chat = directChatsByTeammate[id] else { return nil }
        return chat.teammate
    }

    /// The conversation whose live lines and screen picture the details pane
    /// shows for its bot: its own chat when that is open, or the open team chat
    /// when the bot is one of its members (otherwise a member's pane would
    /// show nothing live). A team turn's lines are the team reply's, not
    /// this member's alone; the pane says so (`BotWatchPanePresentation`).
    public var detailsActivityConversation: ConversationModel? {
        guard let teammate = detailsTeammate else { return nil }
        if selectedTeammate?.id == teammate.id { return conversation }
        // The id check covers the moment the selection is still switching.
        guard let team = selectedTeam, team.members.contains(where: { $0.id == teammate.id }),
              conversation.conversationID == team.conversation.id.rawValue else { return nil }
        return conversation
    }

    /// Whether the details pane's activity is a team chat's rather than the
    /// bot's own.
    public var detailsActivityIsTeamChat: Bool {
        detailsActivityConversation != nil && selectedTeammate?.id != detailsTeammate?.id
    }

    /// The open team's members that still have an active direct chat: exactly
    /// the members whose own settings this screen can open.
    public var teamMemberSettingsTargets: [TeammateIdentitySnapshot] {
        guard !isShuttingDown, hiringModel == nil, let team = selectedTeam else { return [] }
        return team.members.compactMap { member in
            guard let chat = directChatsByTeammate[member.id.rawValue] else { return nil }
            return TeammateIdentitySnapshot(chat.teammate)
        }
    }

    /// The open team's hidden members: the header shows them by face and name, but their
    /// settings open from Hidden Bots, since the details pane, its editor and
    /// Access all read the bot's own chat, which Hide shuts.
    public var teamHiddenMembers: [TeammateIdentitySnapshot] {
        guard !isShuttingDown, hiringModel == nil, let team = selectedTeam else { return [] }
        return team.members.filter { $0.isHidden && directChatsByTeammate[$0.id.rawValue] == nil }
            .map(TeammateIdentitySnapshot.init)
    }

    public func canOpenMemberDetails(id: UUID) -> Bool {
        teamMemberSettingsTargets.contains { $0.id == id }
    }

    /// One step from the team conversation into a member's own settings. The
    /// sidebar selection, the open conversation and its draft are untouched:
    /// only the details pane changes what it is about.
    public func showMemberDetails(id: UUID) {
        guard canOpenMemberDetails(id: id) else { return }
        searchCoordinator?.close()
        // A member's own unfinished edit draft is retained in `profileDrafts`;
        // only the presented editor is dropped, exactly as showBotDetails does.
        profileEditor = nil
        memberDetailsTargetID = id
        isBotDetailsPresented = true
    }

    /// The same step taken from the team editor sheet. That sheet is modal over
    /// the pane it would open, so it closes first; its unfinished name and
    /// checkbox changes are dropped exactly as its own Cancel drops them.
    public func openMemberDetailsFromTeamEditor(id: UUID) {
        guard teamEditor != nil, teamEditor?.isSubmitting != true,
              canOpenMemberDetails(id: id) else { return }
        dismissTeamEditing()
        showMemberDetails(id: id)
    }

    /// Back out of the editor to the details view, for whichever bot the pane
    /// is about. A member whose roster entry vanished mid-edit has nothing to
    /// go back to, so the pane closes rather than showing another bot.
    public func returnToDetails() {
        guard memberDetailsTargetID != nil else { return showBotDetails() }
        guard !isShuttingDown, hiringModel == nil, detailsTeammate != nil else { return closeBotDetails() }
        searchCoordinator?.close()
        profileEditor = nil
        isBotDetailsPresented = true
    }

    /// What the details pane reports about the model behind its bot: a member
    /// opened from a team reports its own direct chat, not the team's.
    var detailsModelStatus: ClaudeModelRunPresentation? {
        guard let coordinator = textReplyCoordinator else { return nil }
        if let id = memberDetailsTargetID, detailsTeammate != nil,
           let chat = directChatsByTeammate[id] {
            return coordinator.modelPresentation(for: chat.conversation.id.rawValue)
        }
        return coordinator.modelPresentation(for: conversation.conversationID)
    }

    public func closeBotDetails() {
        isBotDetailsPresented = false
        memberDetailsTargetID = nil
        // Collapsing a panel is navigation, not cancellation of its edit draft.
        profileEditor = nil
    }

    public func editSelectedProfile() {
        searchCoordinator?.close()
        guard canEditSelectedProfile, let id = sidebar.selection, let profileService else { return }
        let editor = profileDrafts[id] ?? TeammateProfileEditorModel(
            service: profileService, teammateID: TeammateID(id), photoImporter: photoImporter,
            takenName: { [weak self] name in self?.activeBotName(matching: name, excluding: TeammateID(id)) }
        )
        profileDrafts[id] = editor
        profileEditor = editor
        isBotDetailsPresented = true
    }

    /// `canEditSelectedProfile` for whichever bot the details pane is about, so
    /// a member opened from inside a team can be edited there too.
    public var canEditDetailsProfile: Bool {
        !isShuttingDown && archiveModel?.isBusy != true && profileService != nil
            && detailsTeammate != nil && hiringModel == nil
    }

    /// Opens the profile editor on the bot the details pane is showing. From a
    /// bot's own chat that is the selection; from a team it is the member the
    /// pane was opened for, and the selection is never moved to reach it.
    public func editDetailsProfile() {
        guard memberDetailsTargetID != nil else {
            editSelectedProfile()
            return
        }
        searchCoordinator?.close()
        guard canEditDetailsProfile, let teammate = detailsTeammate, let profileService else { return }
        let id = teammate.id.rawValue
        let editor = profileDrafts[id] ?? TeammateProfileEditorModel(
            service: profileService, teammateID: teammate.id, photoImporter: photoImporter,
            takenName: { [weak self] name in self?.activeBotName(matching: name, excluding: teammate.id) }
        )
        profileDrafts[id] = editor
        profileEditor = editor
        isBotDetailsPresented = true
    }

    public func cancelProfileEditing() {
        guard let editor = profileEditor, editor.isCancelled || editor.cancel() else { return }
        profileDrafts.removeValue(forKey: editor.teammateID.rawValue)
        profileEditor = nil
        isBotDetailsPresented = detailsTeammate != nil
    }

    public func profileDidSave(_ teammate: Teammate) {
        notifications?.preferencesChanged()
        guard !isShuttingDown else { return }
        let id = teammate.id.rawValue
        let before = directChatsByTeammate[id]
        guard presentChangedProfile(teammate) else { return }
        profileDrafts.removeValue(forKey: id)
        if profileEditor?.teammateID == teammate.id { profileEditor = nil }
        // The user's edit of the bot's words is said in its chat.
        guard let before, let line = BotProfileChangeNote.line(before: before.teammate.profile, after: teammate.profile) else { return }
        let conversationID = before.conversation.id
        Task { [weak self, service] in
            guard let note = try? await service.saveStatusLine(line, conversationID: conversationID),
                  let self, !self.isShuttingDown else { return }
            self.liveSavedMessages[conversationID.rawValue, default: [:]][note.id.rawValue] = note
            self.recordMessageSequences([note])
            self.presentSavedLiveMessages(conversationID: conversationID.rawValue, teammate: teammate)
        }
    }

    /// A new bot set itself up: its new name reaches the sidebar, the chat
    /// title and the team pickers. An edit by the user that is open stays
    /// open: it was begun on the old profile, so its save is refused as stale
    /// rather than written over the bot's words unseen.
    private func presentSelfSetUp(_ teammateID: TeammateID) async {
        guard !isShuttingDown, let chats = try? await service.activeDirectChats(), !isShuttingDown,
              let chat = chats.first(where: { $0.teammate.id == teammateID }) else { return }
        presentChangedProfile(chat.teammate)
    }

    /// The saved profile everywhere it shows. False when the bot has no chat here.
    @discardableResult
    private func presentChangedProfile(_ teammate: Teammate) -> Bool {
        let id = teammate.id.rawValue
        guard let oldChat = directChatsByTeammate[id] else { return false }
        let updated = DurableDirectChatSnapshot(teammate: teammate, conversation: oldChat.conversation)
        directChatsByTeammate[id] = updated
        let previous = sidebar.rows.first(where: { $0.id == id })
        sidebar.update(TeammateRowSnapshot(
            identity: TeammateIdentitySnapshot(teammate), activity: previous?.activity ?? .idle,
            unreadCount: previous?.unreadCount ?? 0,
            lastActivityAt: previous?.lastActivityAt ?? oldChat.conversation.updatedAt,
            isPinned: teammate.isPinned
        ))
        collaborationModel?.replaceAvailableTeammates(directChatsByTeammate.values.map {
            TeammateIdentitySnapshot($0.teammate)
        })
        if conversation.conversationID == updated.conversation.id.rawValue {
            conversation.renameTitle(teammate.profile.displayName)
            activateKnowledgeContext(for: conversation.conversationID)
        }
        return true
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
                lastActivityAt: current.lastActivityAt,
                isPinned: current.isPinned
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
        sidebar.replace(rows: Self.placing(Self.rowSnapshot(chat), in: sidebar.rows, first: true))
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
                .unavailable(reason: "Choose a bot to open its local conversation.")
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

        if let team = teamChatsByID[teammateUUID] {
            showConversation(conversationID: team.conversation.id.rawValue, title: team.team.name, messages: [])
            conversation.setInputAvailability(.unavailable(reason: "Opening the team conversation…"))
            do {
                try await teamService?.select(teamID: team.team.id)
                guard !isShuttingDown, generation == selectionGeneration, sidebar.selection == teammateUUID else { return }
                try await showTeam(team, messageLimit: messagePageLimit, expectedGeneration: generation)
            } catch {
                guard !isShuttingDown, generation == selectionGeneration, sidebar.selection == teammateUUID else { return }
                conversation.setInputAvailability(.unavailable(reason: "OpenBots could not open this team conversation."))
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
        await agenticJobCoordinator?.loadHistory(conversationID: chat.conversation.id.rawValue)
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
            messages: page.messages.filter(Self.showsInTranscript).map { presentedMessage($0, teammate: chat.teammate) } + pending,
            hasEarlierMessages: page.hasMore
        )
        conversation.setInputAvailability(.ready)
        presentSavedLiveMessages(conversationID: chat.conversation.id.rawValue, teammate: chat.teammate)
    }

    private func showTeam(_ team: TeamChatSnapshot, messageLimit: Int, expectedGeneration: UInt64) async throws {
        let page = try await service.loadMessages(conversationID: team.conversation.id, beforeSequence: nil, limit: messageLimit)
        await loadDeliveryProvenance(page.messages, conversationID: team.conversation.id)
        guard expectedGeneration == selectionGeneration, sidebar.selection == team.team.id.rawValue else { return }
        recordMessageSequences(page.messages)
        let presenter = team.lead ?? team.members.first
        // A reload during a live turn must not drop the rows that page cannot
        // contain yet: an unsaved send stays visible, exactly as a direct chat.
        let loadedIDs = Set(page.messages.map { $0.id.rawValue })
        let pending = conversation.conversationID == team.conversation.id.rawValue
            ? conversation.messages.filter { snapshot in
                guard !loadedIDs.contains(snapshot.id) else { return false }
                switch snapshot.delivery {
                case .pending, .failed: return true
                case .sent: return false
                }
            } : []
        showConversation(conversationID: team.conversation.id.rawValue, title: team.team.name,
                         messages: page.messages.filter(Self.showsInTranscript).map { presentedMessage($0, teammate: presenter) } + pending,
                         hasEarlierMessages: page.hasMore)
        conversation.setInputAvailability(.ready)
        presentSavedLiveMessages(conversationID: team.conversation.id.rawValue, teammate: presenter)
        await reloadHandoffCards(team: team)
    }

    /// Rebuilds the team's handoff cards from the durable records. A card is a
    /// synthetic row: it is never saved as a message, never paged, and its
    /// action registry is replaced whole so a stale route cannot outlive it.
    /// Replacing the whole registry is safe only while a team conversation
    /// carries no other cards. The day a question, connector or secret card can
    /// reach one, this must rebuild the handoff models and keep the rest.
    private func reloadHandoffCards(team: TeamChatSnapshot) async {
        guard let handoffService else { return }
        let conversationID = team.conversation.id
        guard let records = try? await handoffService.records(conversationID: conversationID),
              !didFinishShutdown, conversation.conversationID == conversationID.rawValue else { return }
        let roster = roster(for: conversationID.rawValue)
        let interactions = ConversationCardInteractionModel(conversationID: conversationID.rawValue)
        // A control is drawn only while a press could be admitted. A turn or
        // leg holding the conversation would refuse the press outright, and
        // the end of either is followed by a reload that draws it back.
        let conversationIsBusy = textReplyCoordinator?.phase(for: conversationID.rawValue)?.isBusy == true
        // The repository's own ORDER BY is not a contract this screen may lean
        // on. Sorting newest first here is what makes the insert-after-anchor
        // walk below leave several cards on one reply in the order they were
        // staged: each insert at anchor + 1 pushes the newer ones down.
        let staged = records.compactMap {
            record -> (record: HandoffRecord, sender: Teammate, receiver: Teammate, dispatches: Bool)? in
            guard let sender = roster[record.senderID.rawValue],
                  let receiver = roster[record.receiverID.rawValue] else { return nil }
            // Read once per record and used both to draw the card and to
            // choose what to dispatch, so a card that offers a button and a
            // dispatch that runs the same brief can never both be true.
            return (record, sender, receiver,
                    sessionStagedHandoffIDs[conversationID.rawValue, default: []].contains(record.id.rawValue))
        }.sorted { left, right in
            let leftDate = left.record.handoff.provenance.createdAt
            let rightDate = right.record.handoff.provenance.createdAt
            if leftDate != rightDate { return leftDate > rightDate }
            return left.record.id.rawValue.uuidString > right.record.id.rawValue.uuidString
        }
        var shown: [WorkRecordHandoffCard] = []
        for (record, sender, receiver, dispatches) in staged {
            let card = ChatHandoffCardSnapshot(record: record, sender: TeammateIdentitySnapshot(sender),
                                               receiver: TeammateIdentitySnapshot(receiver),
                                               dispatchesItself: dispatches, conversationIsBusy: conversationIsBusy)
            shown.append(WorkRecordHandoffCard(card: card, legID: record.legID.rawValue))
            guard card.control != nil else { continue }
            let route = ConversationCardInteractionRoute(
                conversationID: conversationID.rawValue, messageID: record.id.rawValue,
                messagePartID: record.legID.rawValue, cardID: record.id.rawValue, actionRouteID: UUID()
            )
            interactions.register(HandoffCardInteractionModel(
                route: route, snapshot: card,
                send: { [weak self] route, attempt in
                    let sent = await self?.sendHandoffLeg(record: record, team: team, receiver: receiver,
                                                          dispatchedItself: false) ?? false
                    return ConversationCardActionResult(route: route, attemptID: attempt,
                                                        outcome: sent ? .succeeded(receiptID: nil) : .failed(receiptID: nil))
                },
                decline: { [weak self] route, attempt in
                    let declined = await self?.declineHandoff(id: record.id, team: team) ?? false
                    return ConversationCardActionResult(route: route, attemptID: attempt,
                                                        outcome: declined ? .succeeded(receiptID: nil) : .failed(receiptID: nil))
                }
            ))
        }
        // Bot-to-bot traffic leaves the transcript: the cards live on the record, oldest first, and a
        // record that stopped resolving simply stops being listed.
        handoffCards = shown.reversed()
        cardInteractions = interactions
        refreshWorkRecordIfShown()
        dispatchNextStagedHandoff(from: staged, team: team)
    }

    /// Opens the conversation's "what happened" record.
    public func openWorkRecord() {
        guard canShowWorkRecord else { return }
        isShowingWorkRecord = true
        refreshWorkRecord()
    }

    public func closeWorkRecord() { isShowingWorkRecord = false }

    private func refreshWorkRecordIfShown() {
        if isShowingWorkRecord { refreshWorkRecord() }
    }

    private func refreshWorkRecord() {
        guard let service = workRecordService, let id = conversation.conversationID else { workRecord = nil; return }
        Task { [weak self] in
            let record = try? await service.workRecord(conversationID: ConversationID(id))
            guard let self, !self.didFinishShutdown, self.conversation.conversationID == id else { return }
            self.workRecord = record
        }
    }

    // MARK: Throwaway workers

    /// How long a wake turned away as busy waits before it tries again.
    static let busyWakeRetryDelay: Duration = .seconds(3)

    static let workerRunningDeleteMessage =
        "This bot has a background worker running. Let it finish, then delete. Nothing was deleted."

    /// Runs each worker a saved reply started. The holder's face keeps working
    /// in that chat while one runs; its end wakes the holder.
    private func startWorkers(_ workers: [TeammateWorker], holder: Teammate) {
        guard let workerService, !isShuttingDown, !didFinishShutdown else { return }
        for worker in workers where runningWorkers[worker.id] == nil && worker.holderID == holder.id {
            runningWorkers[worker.id] = RunningWorker(worker: worker, holderName: holder.profile.displayName)
            runningWorkers[worker.id]?.task = Task { [weak self] in
                let result = await workerService.run(worker)
                self?.workerEnded(worker, result: result)
            }
        }
        reconcileTextReplyAvatar(teammateID: holder.id.rawValue, fallback: .idle)
        refreshTextReplyPhase()
    }

    private func workerEnded(_ worker: TeammateWorker, result: TeammateWorkerResult) {
        // A quit stopped it: `flushForShutdown` says so in the chat.
        guard !isShuttingDown, !didFinishShutdown,
              let running = runningWorkers.removeValue(forKey: worker.id) else { return }
        if stoppedByHimWorkerIDs.remove(worker.id) != nil {
            // The user's Stop ended it: one line in its chat, and its bot is not woken.
            saveStoppedWorkerLine(worker, holderName: running.holderName, finished: false)
            reconcileTextReplyAvatar(teammateID: worker.holderID.rawValue, fallback: .idle)
            refreshTextReplyPhase()
            return
        }
        pendingWorkerWakes.append((worker: worker, holderName: running.holderName, result: result))
        reconcileTextReplyAvatar(teammateID: worker.holderID.rawValue, fallback: .idle)
        refreshTextReplyPhase()
        drainWorkerWakes()
    }

    /// Wakes every holder whose result waits and whose chat is free, one wake
    /// per chat at a time. The reservation is taken here, synchronously, so no
    /// second wake and no correction can slip into the same chat.
    private func drainWorkerWakes() {
        guard !isShuttingDown, !didFinishShutdown, let coordinator = textReplyCoordinator else { return }
        var claimed: Set<UUID> = []
        for wake in pendingWorkerWakes where !wakingWorkerIDs.contains(wake.worker.id) {
            let conversationID = wake.worker.conversationID.rawValue
            // A wake under way holds its chat busy, so this also keeps one wake per chat.
            guard !claimed.contains(conversationID), coordinator.phase(for: conversationID)?.isBusy != true,
                  teamChainConversationIDs[conversationID] == nil else { continue }
            let reservation = UUID()
            guard coordinator.reserveIdle(conversationID: conversationID, messageID: reservation) else { continue }
            claimed.insert(conversationID)
            wakingWorkerIDs.insert(wake.worker.id)
            stopPressedConversationIDs.remove(conversationID)
            Task { [weak self] in await self?.wakeHolder(wake.worker, result: wake.result, reservation: reservation) }
        }
    }

    private func wakeHolder(_ worker: TeammateWorker, result workerResult: TeammateWorkerResult, reservation: UUID) async {
        guard let coordinator = textReplyCoordinator else { return }
        let conversationID = worker.conversationID.rawValue
        let holder = roster(for: conversationID)[worker.holderID.rawValue] ?? directChatsByTeammate[worker.holderID.rawValue]?.teammate
        beginTextReplyAvatar(conversationID: conversationID, reservation: reservation, teammateID: worker.holderID.rawValue)
        let result = await coordinator.sendWorkerResult(
            WorkerResultSubmission(worker: worker, result: workerResult), conversationID: conversationID, messageID: reservation
        ) { [weak self] progress in
            guard let self, !self.didFinishShutdown else { return }
            if case .userMessageSaved = progress { self.wakeNotesSavedWorkerIDs.insert(worker.id) }
            guard let holder else { return }
            await self.handleTextReplyProgress(progress, conversationID: worker.conversationID, teammate: holder,
                                               avatarReservation: reservation,
                                               expectedUserMessageID: nil, originatedSearchRequest: nil)
        }
        // A wake stopped without the user's Stop (a message typed over it,
        // whether it then sent or not) did not answer the result, so the result
        // waits and goes again when the chat is next free. A Stop the user
        // pressed ends it for good.
        let stoppedByHim = stopPressedConversationIDs.remove(conversationID) != nil
        let takenByAMessage = result.outcome == .stopped && !isShuttingDown && !stoppedByHim
        // A quit that caught the wake before its note was saved: nothing records
        // it, so the result stays for the quit line.
        let unrecordedAtQuit = result.outcome == .stopped && isShuttingDown && !wakeNotesSavedWorkerIDs.contains(worker.id)
        wakingWorkerIDs.remove(worker.id)
        guard !didFinishShutdown else { return }
        if case .failed(.busy, _) = result.outcome {
            // The holder is answering in another chat. Nothing was written; the
            // result waits for the next turn's end anywhere, and tries again
            // shortly in case that end came while this wake was being refused.
            coordinator.abandon(conversationID: conversationID, messageID: reservation)
            finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: reservation)
            Task { [weak self] in
                try? await Task.sleep(for: Self.busyWakeRetryDelay)
                self?.drainWorkerWakes()
            }
            return
        }
        if !takenByAMessage && !unrecordedAtQuit { pendingWorkerWakes.removeAll { $0.worker.id == worker.id } }
        wakeNotesSavedWorkerIDs.remove(worker.id)
        for message in [result.savedUserMessage, result.savedReplyMessage].compactMap({ $0 }) {
            liveSavedMessages[conversationID, default: [:]][message.id.rawValue] = message
            if message.id == result.savedReplyMessage?.id {
                recordTextTurnReply(message.id.rawValue, outcome: result.outcome)
            }
        }
        let saved = Array(liveSavedMessages[conversationID, default: [:]].values)
        recordMessageSequences(saved)
        await loadDeliveryProvenance(saved, conversationID: worker.conversationID)
        guard !didFinishShutdown else { return }
        switch result.outcome {
        case .completed, .stopped, .failed(.unavailable, _):
            finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: reservation)
        case .failed:
            finishTextReplyAvatar(.errorOrAttention, conversationID: conversationID, reservation: reservation)
        }
        // Like every other turn's end in a team: the team's own step (a brief
        // that waited) goes before the next worker's result.
        let isTeamChat = teamChat(for: conversationID) != nil
        if isTeamChat { beginTeamChainStep(conversationID) }
        defer { if isTeamChat { endTeamChainStep(conversationID) } }
        coordinator.finish(conversationID: conversationID, messageID: reservation, outcome: result.outcome)
        presentSavedLiveMessages(conversationID: conversationID, teammate: holder)
        refreshTextReplyPhase()
        // A team chat's cards were drawn without their controls while the wake
        // held it; redrawing them also sends a brief that waited.
        if let team = teamChat(for: conversationID) { await reloadHandoffCards(team: team) }
    }

    /// The user's Stop in a chat ends what its bots started there: every
    /// running worker is cancelled, and a result still waiting for its bot is
    /// dropped, each with a line; none of them wakes a bot. A wake already
    /// under way is that Stop's own business (`stopPressedConversationIDs`).
    private func stopWorkers(conversationID: UUID) {
        for running in runningWorkers.values where running.worker.conversationID.rawValue == conversationID {
            stoppedByHimWorkerIDs.insert(running.worker.id)
            running.task?.cancel()
        }
        let waiting = pendingWorkerWakes.filter {
            $0.worker.conversationID.rawValue == conversationID && !wakingWorkerIDs.contains($0.worker.id)
        }
        pendingWorkerWakes.removeAll { wake in waiting.contains { $0.worker.id == wake.worker.id } }
        for wake in waiting { saveStoppedWorkerLine(wake.worker, holderName: wake.holderName, finished: true) }
        refreshTextReplyPhase()
    }

    private func saveStoppedWorkerLine(_ worker: TeammateWorker, holderName: String, finished: Bool) {
        guard let textReplyService else { return }
        let line = TeammateWorkerNote.stoppedLine(holderName: holderName, worker: worker, finished: finished)
        Task { [weak self] in
            guard let note = await textReplyService.saveWorkerNote(line, conversationID: worker.conversationID),
                  let self, !self.didFinishShutdown else { return }
            let conversationID = worker.conversationID.rawValue
            self.liveSavedMessages[conversationID, default: [:]][note.id.rawValue] = note
            self.recordMessageSequences([note])
            let holder = self.roster(for: conversationID)[worker.holderID.rawValue]
                ?? self.directChatsByTeammate[worker.holderID.rawValue]?.teammate
            self.presentSavedLiveMessages(conversationID: conversationID, teammate: holder)
        }
    }

    private func workerIsRunning(holderID: UUID, conversationID: UUID) -> Bool {
        runningWorkers.values.contains {
            $0.worker.holderID.rawValue == holderID && $0.worker.conversationID.rawValue == conversationID
        }
    }

    /// A worker running for this bot, or its result waiting for it.
    func hasWorkerWork(holderID: UUID) -> Bool {
        runningWorkers.values.contains { $0.worker.holderID.rawValue == holderID }
            || pendingWorkerWakes.contains { $0.worker.holderID.rawValue == holderID }
    }

    /// A worker running in this chat, or its result waiting to be answered there.
    func hasWorkerWork(conversationID: UUID) -> Bool {
        runningWorkers.values.contains { $0.worker.conversationID.rawValue == conversationID }
            || pendingWorkerWakes.contains { $0.worker.conversationID.rawValue == conversationID }
    }

    /// What Details says about this chat's workers, one line each.
    private func backgroundWorkerLines(conversationID: UUID?) -> [String] {
        guard let conversationID else { return [] }
        let running = runningWorkers.values.filter { $0.worker.conversationID.rawValue == conversationID }
            .sorted { $0.worker.brief < $1.worker.brief }
            .map { "Background worker running: \($0.worker.quotedBrief)" }
        let waiting = pendingWorkerWakes.filter { $0.worker.conversationID.rawValue == conversationID }
            .map { "Background worker done, \($0.holderName) answers next: \($0.worker.quotedBrief)" }
        return running + waiting
    }

    /// A quit ends every worker and every waiting result; each holder's chat
    /// keeps one line saying so. True when every line was saved.
    private func noteWorkersEndedByQuit() async -> Bool {
        guard let textReplyService else { return true }
        // A wake under way keeps its own record of how the quit ended it;
        // only a result that never reached its bot gets a line.
        let lines = runningWorkers.values.map { ($0.worker, TeammateWorkerNote.quitLine(holderName: $0.holderName, worker: $0.worker, finished: false)) }
            + pendingWorkerWakes.filter { !wakingWorkerIDs.contains($0.worker.id) || !wakeNotesSavedWorkerIDs.contains($0.worker.id) }
                .map { ($0.worker, TeammateWorkerNote.quitLine(holderName: $0.holderName, worker: $0.worker, finished: true)) }
        runningWorkers.removeAll()
        pendingWorkerWakes.removeAll()
        var saved = true
        for (worker, line) in lines {
            if !(await textReplyService.saveWorkerLine(line, conversationID: worker.conversationID)) { saved = false }
        }
        return saved
    }

    /// The lead compiles a member's finished leg for the user: the
    /// member's reply stays on the record, and the room hears the lead once.
    private func compileHandoffReport(record: HandoffRecord, team: TeamChatSnapshot, lead: Teammate) async {
        guard let coordinator = textReplyCoordinator else { return }
        let conversationID = team.conversation.id.rawValue
        let reservation = UUID()
        guard coordinator.reserveIdle(conversationID: conversationID, messageID: reservation) else { return }
        beginTextReplyAvatar(conversationID: conversationID, reservation: reservation, teammateID: lead.id.rawValue)
        let result = await coordinator.sendReport(
            HandoffReportSubmission(handoffID: record.id), conversationID: conversationID, messageID: reservation
        ) { [weak self] progress in
            guard let self, !self.didFinishShutdown else { return }
            await self.handleTextReplyProgress(progress, conversationID: team.conversation.id, teammate: lead,
                                               avatarReservation: reservation,
                                               expectedUserMessageID: nil, originatedSearchRequest: nil)
        }
        guard !didFinishShutdown else { return }
        for message in [result.savedUserMessage, result.savedReplyMessage].compactMap({ $0 }) {
            liveSavedMessages[conversationID, default: [:]][message.id.rawValue] = message
            if message.id == result.savedReplyMessage?.id {
                recordTextTurnReply(message.id.rawValue, outcome: result.outcome)
            }
        }
        let saved = Array(liveSavedMessages[conversationID, default: [:]].values)
        recordMessageSequences(saved)
        await loadDeliveryProvenance(saved, conversationID: team.conversation.id)
        guard !didFinishShutdown else { return }
        beginTeamChainStep(conversationID)
        defer { endTeamChainStep(conversationID) }
        coordinator.finish(conversationID: conversationID, messageID: reservation, outcome: result.outcome)
        presentSavedLiveMessages(conversationID: conversationID, teammate: lead)
        let chainWasStopped = stoppedHandoffChainConversationIDs.remove(conversationID) != nil
        if result.outcome == .completed, !chainWasStopped {
            await noteHandoffsStagedByThisTurn(team: team, replyMessageID: result.savedReplyMessage?.id)
        }
        switch result.outcome {
        case .completed, .stopped: finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: reservation)
        // No report service wired: the member's reply is on the record and
        // the lead has nothing to add, which is not the lead's failure.
        case .failed(.unavailable, _): finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: reservation)
        case .failed: finishTextReplyAvatar(.errorOrAttention, conversationID: conversationID, reservation: reservation)
        }
        await reloadHandoffCards(team: team)
    }

    /// A lead's brief to a named member of its own team sends itself. That is
    /// ordinary teaming inside the room the user is already in, not an act
    /// that leaves the product, so it is not gated. Visibility, not a
    /// click, is what keeps it honest: the card records the brief and the
    /// member's reply arrives attributed in the same conversation.
    ///
    /// One leg at a time, oldest first, and only ever from `staged` — an
    /// `accepted` record is mid-flight or stalled and carries its own control,
    /// and anything past that is finished — and only from a brief this session
    /// watched its own turn stage. A Stop empties that conversation's set in
    /// one go, so a chain the user ended reaches this method no further than
    /// the leg it was already running. A leg turned away before its accept leaves
    /// the record exactly where it was; the send then takes that brief out of
    /// the session's set and redraws it with its own Send, so nothing here
    /// retries itself and no later reload does either. The reservation is the
    /// first guard against a second start mid-leg and the in-flight set the
    /// second: a rebuild that a moved record does cause can never re-enter
    /// the leg it caused.
    private func dispatchNextStagedHandoff(
        from records: [(record: HandoffRecord, sender: Teammate, receiver: Teammate, dispatches: Bool)],
        team: TeamChatSnapshot
    ) {
        guard !isShuttingDown, !didFinishShutdown, textReplyCoordinator != nil else { return }
        // `records` is newest first, so the oldest brief is the last match.
        guard let next = records.last(where: {
            $0.record.state == .staged && $0.dispatches && !dispatchingHandoffIDs.contains($0.record.id.rawValue)
        }) else { return }
        let handoffRowID = next.record.id.rawValue
        dispatchingHandoffIDs.insert(handoffRowID)
        let chatID = team.conversation.id.rawValue
        beginTeamChainStep(chatID)
        Task { [weak self] in
            defer { self?.endTeamChainStep(chatID) }
            _ = await self?.sendHandoffLeg(record: next.record, team: team, receiver: next.receiver,
                                           dispatchedItself: true)
            // Released here rather than inside the send, whose several
            // shutdown exits would otherwise strand the id and stop this
            // screen ever dispatching that brief again.
            self?.dispatchingHandoffIDs.remove(handoffRowID)
        }
    }

    /// Stop in a team conversation ends the whole handoff chain, not only the
    /// leg or turn that is running. Every brief this workspace was going to
    /// send itself leaves the session's set at once, so no reload dispatches
    /// one, and the turn being stopped stages none of the briefs it was still
    /// writing. The cards are rebuilt so each brief left waiting is a person's
    /// to send; the controls themselves appear on the rebuild that follows the
    /// stopped run's end, since a conversation still stopping would refuse a
    /// press. The stopped record keeps whatever its own leg wrote: `accepted`
    /// with "Send again", or a recovery.
    private func stopHandoffChain(conversationID: UUID) {
        guard let team = teamChat(for: conversationID) else { return }
        stoppedHandoffChainConversationIDs.insert(conversationID)
        sessionStagedHandoffIDs[conversationID] = nil
        Task { [weak self] in await self?.reloadHandoffCards(team: team) }
    }

    /// Runs a member's leg, whether the staging dispatched it or the user
    /// pressed "Send again" on a stalled one. It reserves the conversation
    /// under the handoff's own id so it cannot overlap a typed reply or a
    /// second leg, and never touches the composer draft: none was submitted.
    /// `dispatchedItself` says which of the two started it, and so which of
    /// them has to hand the brief back when a leg is turned away before its
    /// accept.
    private func sendHandoffLeg(record: HandoffRecord, team: TeamChatSnapshot, receiver: Teammate,
                                dispatchedItself: Bool) async -> Bool {
        guard let coordinator = textReplyCoordinator else { return false }
        let conversationID = team.conversation.id.rawValue
        let messageID = record.id.rawValue
        guard coordinator.reserveIdle(conversationID: conversationID, messageID: messageID) else { return false }
        let avatarReservation = UUID()
        // What the member's row showed before this leg claimed it. A leg
        // turned away before its accept ran nothing, so it puts this back.
        let activityBeforeLeg = sidebar.rows.first { $0.id == receiver.id.rawValue }?.activity ?? .idle
        beginTextReplyAvatar(conversationID: conversationID, reservation: avatarReservation, teammateID: receiver.id.rawValue)
        let result = await coordinator.sendLeg(
            HandoffLegSubmission(handoffID: record.id), conversationID: conversationID, messageID: messageID
        ) { [weak self] progress in
            guard let self, !self.didFinishShutdown else { return }
            await self.handleTextReplyProgress(progress, conversationID: team.conversation.id, teammate: receiver,
                                               avatarReservation: avatarReservation,
                                               expectedUserMessageID: nil, originatedSearchRequest: nil)
        }
        guard !didFinishShutdown else { return false }
        for message in [result.savedUserMessage, result.savedReplyMessage].compactMap({ $0 }) {
            liveSavedMessages[conversationID, default: [:]][message.id.rawValue] = message
            if message.id == result.savedReplyMessage?.id {
                recordTextTurnReply(message.id.rawValue, outcome: result.outcome)
            }
        }
        let saved = Array(liveSavedMessages[conversationID, default: [:]].values)
        recordMessageSequences(saved)
        await loadDeliveryProvenance(saved, conversationID: team.conversation.id)
        guard !didFinishShutdown else { return false }
        beginTeamChainStep(conversationID)
        defer { endTeamChainStep(conversationID) }
        coordinator.finish(conversationID: conversationID, messageID: messageID, outcome: result.outcome)
        presentSavedLiveMessages(conversationID: conversationID, teammate: receiver)
        // Whether a Stop ended this conversation's chain while this leg ran.
        // The leg's end is that stopped run's end, so the flag stops governing
        // here; the conversation is free again by this line, which is what
        // makes the reading final. What it buys the card below is the control
        // the Stop's own rebuild could not draw.
        let chainWasStopped = stoppedHandoffChainConversationIDs.remove(conversationID) != nil
        if result.outcome == .completed {
            finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: avatarReservation)
            // The member reported to the lead; the lead now speaks for the
            // room, before the next waiting brief goes out: the compile ends
            // with the reload that dispatches it. A Stop during the leg ends
            // the chain here instead.
            if !chainWasStopped, let lead = roster(for: conversationID)[record.senderID.rawValue] {
                await compileHandoffReport(record: record, team: team, lead: lead)
            } else {
                await reloadHandoffCards(team: team)
            }
            return true
        }
        // A leg that did not complete is judged by what it wrote, not by how it
        // ended. A record that moved is redrawn — that is how one stalled at
        // `accepted` gets its "Send again" — and the member's row says how
        // the leg ended.
        if await handoffState(id: record.id, conversationID: team.conversation.id) != record.state {
            switch result.outcome {
            case .completed, .stopped: finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: avatarReservation)
            case .failed: finishTextReplyAvatar(.errorOrAttention, conversationID: conversationID, reservation: avatarReservation)
            }
            await reloadHandoffCards(team: team)
            return false
        }
        // Turned away before its accept: nothing was written and the member did
        // nothing, so its row goes back to what it showed. A pressed card is
        // left alone, since rebuilding would replace the registry and throw
        // away the failure the view shows over it — unless a Stop rebuilt the
        // cards mid-leg, which discarded that failure already and drew the
        // pressed card with no control at all; then the record is redrawn from
        // what it still holds, `staged` with its Send or `accepted` with its
        // Send again. A brief this workspace was sending itself stops being its
        // to send: it leaves the session's set, if a Stop has not already
        // emptied it, and is redrawn with its own Send, with the reason still
        // on the status line, so no later reload can put the same refused brief
        // back into this method.
        finishTextReplyAvatar(activityBeforeLeg, conversationID: conversationID, reservation: avatarReservation)
        var redrawsTheCards = chainWasStopped
        if record.state == .staged, dispatchedItself {
            sessionStagedHandoffIDs[conversationID]?.remove(record.id.rawValue)
            redrawsTheCards = true
        }
        if redrawsTheCards { await reloadHandoffCards(team: team) }
        return false
    }

    /// The record's state as persistence now holds it, and nil when it cannot
    /// be read or no longer exists. A read that fails reads as a move, and the
    /// reload it causes is inert: rebuilding reads the same records and returns
    /// having changed nothing.
    private func handoffState(id: HandoffID, conversationID: ConversationID) async -> HandoffState? {
        guard let handoffService,
              let records = try? await handoffService.records(conversationID: conversationID) else { return nil }
        return records.first { $0.id == id }?.state
    }

    /// The installed build's "Not now". No control offers it any more — the
    /// gate the decline belonged to is gone —
    /// but the interaction model still takes a decline action, so this stays
    /// wired rather than handing it one that lies about what it does.
    private func declineHandoff(id: HandoffID, team: TeamChatSnapshot) async -> Bool {
        guard let handoffService, (try? await handoffService.decline(id: id)) != nil else { return false }
        await reloadHandoffCards(team: team)
        return true
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
            // The same line whether or not the retired job runner is composed:
            // no control can turn a job on any more.
            readyDeliveryDescription: deliveryDescription,
            isLocalOnly: mode == .localOnly && textReplyService == nil && agenticJobService == nil,
            textRepliesEnabled: textReplyService != nil,
            stopTextReply: { [weak self] in
                guard let self, let id = self.conversation.conversationID else { return }
                if self.agenticJobCoordinator?.isActive(conversationID: id) == true {
                    self.agenticJobCoordinator?.stop(conversationID: id)
                } else {
                    self.textReplyCoordinator?.stop(conversationID: id)
                    self.stopHandoffChain(conversationID: id)
                    self.stopPressedConversationIDs.insert(id)
                    self.stopWorkers(conversationID: id)
                }
            },
            stopWorkers: { [weak self] in
                guard let self, let id = self.conversation.conversationID else { return }
                self.stopWorkers(conversationID: id)
            },
            agenticJobDecision: { [weak self] approval, allow in
                guard let self, let id = self.conversation.conversationID else { return }
                Task { await self.agenticJobCoordinator?.decide(approval, allow: allow, conversationID: id) }
            },
            textReplyApprovalDecision: { [weak self] approval, allow in
                guard let self, let id = self.conversation.conversationID else { return }
                Task { await self.textReplyCoordinator?.decideApproval(approval, allow: allow, conversationID: id) }
            },
            textReplyApprovalTurnAllowance: { [weak self] approval in
                guard let self, let id = self.conversation.conversationID else { return }
                Task { await self.textReplyCoordinator?.allowApprovalForTurn(approval, conversationID: id) }
            },
            textReplyMissingFileReplacement: { [weak self] approval, url in
                guard let self, let id = self.conversation.conversationID else { return }
                Task { await self.textReplyCoordinator?.replaceMissingFile(approval, with: url, conversationID: id) }
            },
            textReplyQuestionAnswer: { [weak self] question, answer in
                guard let self, let id = self.conversation.conversationID else { return }
                Task { await self.textReplyCoordinator?.answerQuestion(question, answer: answer, conversationID: id) }
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
            beforeSubmission: { [weak self] messageID, conversationID, rawText, keepsAttachments in
                // nil is "admitted"; only a workspace that is gone refuses here.
                guard let self else { return Self.workspaceGoneRefusal }
                return self.prepareMessageSubmission(messageID: messageID, conversationID: conversationID, rawText: rawText,
                                                     locally: false, keepsAttachments: keepsAttachments)
            },
            beforeLocalSubmission: { [weak self] messageID, conversationID, rawText, keepsAttachments in
                guard let self else { return Self.workspaceGoneRefusal }
                return self.prepareMessageSubmission(messageID: messageID, conversationID: conversationID, rawText: rawText,
                                                     locally: true, keepsAttachments: keepsAttachments)
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
            messages: page.messages.filter(Self.showsInTranscript).map { presentedMessage($0, teammate: chat.teammate) },
            hasEarlierMessages: page.hasMore, includesFixtures: target == nil
        )
        if let target { conversation.focusSearchMessage(target.id.rawValue) }
        conversation.setInputAvailability(.ready)
    }

    /// The conversation and the bot that presents or answers it. For a team the
    /// recipient is routed from the text: the lead unless a member is named.
    private func replyTarget(for conversationID: UUID, text: String?) -> (conversation: Conversation, teammate: Teammate)? {
        if let chat = directChatsByTeammate.values.first(where: { $0.conversation.id.rawValue == conversationID }) {
            return (chat.conversation, chat.teammate)
        }
        guard let team = teamChat(for: conversationID) else { return nil }
        if let text {
            // A send must reach the member the text addresses. When no active
            // lead can take an unmentioned message the send is refused, never
            // handed to whichever member happens to sort first.
            guard let route = TeamMentionRouting.recipient(for: text, team: team.team, members: team.members),
                  let recipient = team.members.first(where: { $0.id == route.teammateID }) else { return nil }
            return (team.conversation, recipient)
        }
        // Paging and display only need a presenter for the roster fallback.
        guard let presenter = team.lead ?? team.members.first else { return nil }
        return (team.conversation, presenter)
    }

    private func returnToLatest() async {
        guard let id = sidebar.selection else { return }
        if let team = teamChatsByID[id] {
            selectionGeneration &+= 1
            let generation = selectionGeneration
            do {
                try await showTeam(team, messageLimit: messagePageLimit, expectedGeneration: generation)
                guard generation == selectionGeneration else { return }
                conversation.focusLatestMessage()
            } catch {
                guard generation == selectionGeneration else { return }
                conversation.setSearchNavigationNotice("Latest messages could not be loaded. Your current page and draft are preserved.")
            }
            return
        }
        guard let chat = directChatsByTeammate[id] else { return }
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
        guard let target = replyTarget(for: conversationID, text: nil) else {
            return ConversationMessagePageSnapshot(
                messages: [],
                hasEarlierMessages: false
            )
        }

        let beforeSequence = earliestMessageID.flatMap { messageSequenceByID[$0] }
        let page = try await service.loadMessages(
            conversationID: target.conversation.id,
            beforeSequence: beforeSequence,
            limit: messagePageLimit
        )
        await loadDeliveryProvenance(page.messages, conversationID: target.conversation.id)
        recordMessageSequences(page.messages)
        // Paging must never be the reason a card stops being shown, so the set
        // and its registry are refreshed here. A card already placed keeps its
        // position: `insertMessage` updates in place, so one anchored to a
        // reply that only now arrived stays where it was first put.
        if let team = teamChat(for: conversationID) { await reloadHandoffCards(team: team) }
        return ConversationMessagePageSnapshot(
            messages: page.messages.filter(Self.showsInTranscript).map { presentedMessage($0, teammate: target.teammate) },
            hasEarlierMessages: page.hasMore
        )
    }

    static let workspaceGoneRefusal = "This message could not be sent right now. Your text is kept."
    static let archiveBusyRefusal = "This bot is being archived, so nothing can be sent right now."
    static let correctionPendingRefusal = "Your last note is still being picked up. Send this one right after."
    static let jobBusyRefusal = "The bot is still busy with its job. Your text is kept."
    static let attachmentFrozenRefusal = "The file could not be attached to this message. Your text is kept."
    static let draftNotSavedRefusal = "This message could not be saved, so it was not sent. Your text is kept."

    /// Nil when the message may go; otherwise the one sentence the composer
    /// shows for why it did not.
    private func prepareMessageSubmission(messageID: UUID, conversationID: UUID, rawText: String, locally: Bool,
                                          keepsAttachments: Bool = false) -> String? {
        guard !isShuttingDown else { return Self.workspaceGoneRefusal }
        guard archiveModel?.isBusy != true else { return Self.archiveBusyRefusal }
        // Attachments are direct-only for now, so a team conversation owns
        // no scoped attachment draft. Every attachment gate on this send must
        // use the same predicate `activateDraftState` used to withhold that
        // draft, or the send is refused with nothing to show for it: the
        // coordinator's `begin` returns nil for a conversation it never
        // modelled, and the inert unscoped tray can still hold a failed row
        // from a picked file its always-throwing importer refused.
        let team = isTeamConversation(conversationID)
        let job = !locally && routesToAgenticJob(conversationID: conversationID, text: rawText)
        let live = textReplyService != nil && !locally && !job
        if job {
            guard !conversation.hasAttachmentContent, attachmentDraft.rows.isEmpty,
                  textReplyCoordinator?.phase(for: conversationID)?.isBusy != true,
                  let id = teammateID(for: conversationID),
                  agenticJobCoordinator?.reserve(conversationID: conversationID, teammateID: TeammateID(id), messageID: messageID) == true else { return Self.jobBusyRefusal }
            agenticJobSubmissions.insert(messageID)
        }
        if live {
            guard team || keepsAttachments || (!conversation.hasAttachmentContent && attachmentDraft.rows.isEmpty) else {
                return Self.attachmentFrozenRefusal
            }
            // A second correction while the first is still being picked up is
            // a refusal that must not be swallowed.
            guard textReplyCoordinator?.reserve(conversationID: conversationID, messageID: messageID) == true else {
                return Self.correctionPendingRefusal
            }
            if textReplyCoordinator?.supersedesRunningTurn(conversationID: conversationID, messageID: messageID) == true {
                // Typed during work: the running turn stops and, in a team, so
                // does its chain; the finished replies stay in the transcript.
                stopHandoffChain(conversationID: conversationID)
                if team { textReplyCoordinator?.markTeamCorrection(conversationID: conversationID) }
            } else {
                liveSavedMessages[conversationID] = [:]
            }
        }
        let assets: [AttachmentAsset]
        if let coordinator = attachmentCoordinator, !team, !keepsAttachments {
            guard let frozen = coordinator.begin(messageID: messageID, conversationID: conversationID) else {
                if live { textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID) }
                if job { abandonAgenticSubmission(messageID: messageID, conversationID: conversationID) }
                return Self.attachmentFrozenRefusal
            }
            assets = frozen
        } else { assets = [] }
        let admitted = draftCoordinator?.beginSubmission(
            messageID: messageID, conversationID: conversationID, rawText: rawText,
            allowsEmptyText: !assets.isEmpty
        ) ?? true
        if !admitted {
            if !keepsAttachments { attachmentCoordinator?.finish(messageID: messageID, committed: false) }
            if live { textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID) }
            if job { abandonAgenticSubmission(messageID: messageID, conversationID: conversationID) }
            return Self.draftNotSavedRefusal
        }
        if let focus = conversation.searchFocus {
            searchOriginatedSubmissions[messageID] = (focus.requestID, selectionGeneration)
        }
        return nil
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
        guard let target = replyTarget(for: conversationID, text: text) else {
            textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
            abandonAgenticSubmission(messageID: messageID, conversationID: conversationID)
            draftCoordinator?.failSubmission(messageID: messageID)
            markPendingMessageFailed(
                messageID,
                conversationID: conversationID,
                reason: teamChat(for: conversationID) != nil
                    ? "No active lead can answer in this team. Restore its lead from Archived."
                    : "The local conversation is unavailable."
            )
            return
        }

        if let draftCoordinator, !(await draftCoordinator.persistSubmission(messageID: messageID)) {
            textReplyCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
            abandonAgenticSubmission(messageID: messageID, conversationID: conversationID)
            draftCoordinator.failSubmission(messageID: messageID)
            markPendingMessageFailed(messageID, conversationID: conversationID,
                                     reason: "OpenBots could not save the draft before sending. Your text is preserved.")
            return
        }
        let teammateID = target.teammate.id.rawValue
        guard !didFinishShutdown, !Task.isCancelled else { return }
        if agenticJobSubmissions.remove(messageID) != nil {
            // Jobs stay direct-only. A reservation taken for anything else is
            // released here rather than left holding the conversation.
            if let chat = directChatsByTeammate[teammateID], chat.conversation.id.rawValue == conversationID {
                attachmentCommitSucceeded = await performAgenticJob(messageID: messageID, text: text, chat: chat)
                return
            }
            agenticJobCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
        }
        if textReplyService != nil && !locally {
            await performTextReply(messageID: messageID, text: text, conversation: target.conversation,
                                   teammate: target.teammate, originatedSearchRequest: originatedSearchRequest)
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
                    conversationID: target.conversation.id, teammateID: target.teammate.id,
                    userMessageID: MessageID(messageID), text: text,
                    attachmentIDs: frozenAttachments.map(\.id)
                )
                if textReplyService != nil { deliveryNotices[userMessage.id.rawValue] = "Saved locally · not sent to Claude" }
                fixtureReply = nil
            case .reviewFixture:
                let exchange = try await service.sendMessageToLocalFixture(
                    conversationID: target.conversation.id, teammateID: target.teammate.id,
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
                    presentedMessage(userMessage, teammate: target.teammate)
                )
            }

            // Both rows are already durable. This labelled, deterministic
            // presentation fixture reveals the stored reply through one stable
            // row so a check can verify row-local streaming without implying
            // that a model process or tool is running.
            if let fixtureReply, !isShuttingDown, conversation.conversationID == conversationID {
                setActivity(.speaking, teammateID: teammateID)
                let finalReply = Self.messageSnapshot(
                    fixtureReply,
                    teammate: target.teammate
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
                conversation.replaceMessage(Self.messageSnapshot(savedUserMessage, teammate: target.teammate))
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

    private func routesToAgenticJob(conversationID: UUID, text: String) -> Bool {
        guard agenticJobCoordinator != nil else { return false }
        if agenticJobCoordinator?.isActive(conversationID: conversationID) == true { return true }
        // Preserve explicit local memory commands and inquiries when no job owns the conversation.
        guard !MemoryEvidenceVerifier.recognizesUserCommand(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              MemoryLocalConversationService.inquiry(text) == nil,
              let id = teammateID(for: conversationID),
              agenticJobAccessModel?.teammateID == TeammateID(id) else { return false }
        return agenticJobAccessModel?.isEnabled == true
    }

    private func abandonAgenticSubmission(messageID: UUID, conversationID: UUID) {
        guard agenticJobSubmissions.remove(messageID) != nil else { return }
        agenticJobCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
    }

    private func performAgenticJob(messageID: UUID, text: String, chat: DurableDirectChatSnapshot) async -> Bool {
        let conversationID = chat.conversation.id.rawValue
        let saved: Message
        do {
            saved = try await service.saveMessageLocally(conversationID: chat.conversation.id,
                teammateID: chat.teammate.id, userMessageID: MessageID(messageID), text: text, attachmentIDs: [])
        } catch {
            agenticJobCoordinator?.abandon(conversationID: conversationID, messageID: messageID)
            draftCoordinator?.failSubmission(messageID: messageID)
            markPendingMessageFailed(messageID, conversationID: conversationID, reason: "OpenBots could not save this job message. Your draft is preserved.")
            return false
        }
        await draftCoordinator?.completeSubmission(messageID: messageID)
        recordMessageSequences([saved])
        if !didFinishShutdown, conversation.conversationID == conversationID {
            conversation.replaceMessage(Self.messageSnapshot(saved, teammate: chat.teammate))
        }
        guard !isShuttingDown, !Task.isCancelled else { return true }
        await agenticJobCoordinator?.submit(.init(teammateID: chat.teammate.id, message: saved, text: text))
        return true
    }

    /// Diagnostics wrapper around the workspace's own change notification.
    func notifyWorkspaceChange(line: Int = #line) {
        LayoutStormCounters.hit("workspace.objectWillChange", detail: "line \(line)")
        objectWillChange.send()
    }

    private func refreshAgenticJobPresentation() {
        LayoutStormCounters.hit("refreshAgenticJobPresentation")
        guard !didFinishShutdown else { return }
        let id = conversation.conversationID
        let matchingBot = teammateID(for: id).map { TeammateID($0) } == agenticJobAccessModel?.teammateID
        conversation.setAgenticJob(enabled: matchingBot && agenticJobAccessModel?.isEnabled == true,
            presentation: agenticJobCoordinator?.presentation(for: id))
        if let id, let teammate = teammateID(for: id), let phase = conversation.agenticJobPresentation?.phase {
            setActivity(phase.isActive ? .thinkingOrWorking : .waitingForUser, teammateID: teammate)
        }
        notifyWorkspaceChange()
    }

    private func agenticJobCompleted(conversationID: UUID) {
        guard !isShuttingDown, conversation.conversationID == conversationID, !conversation.isViewingSearchResult,
              let chat = directChatsByTeammate.values.first(where: { $0.conversation.id.rawValue == conversationID }) else { return }
        let generation = selectionGeneration
        Task { [weak self] in
            guard let self else { return }
            try? await self.show(chat, messageLimit: self.messagePageLimit, expectedGeneration: generation)
        }
    }

    /// `conversation` and `teammate` are the resolved target of this turn: a
    /// direct chat and its bot, or a team conversation and its routed member.
    private func performTextReply(
        messageID: UUID, text: String, conversation: Conversation, teammate: Teammate,
        originatedSearchRequest: (requestID: UUID, generation: UInt64)?
    ) async {
        guard let coordinator = textReplyCoordinator else { return }
        let conversationID = conversation.id.rawValue
        // Starting a turn is what resumes a chain, so an earlier Stop stops
        // governing this conversation here rather than at that Stop's own end.
        stoppedHandoffChainConversationIDs.remove(conversationID)
        let avatarReservation = UUID()
        beginTextReplyAvatar(conversationID: conversationID, reservation: avatarReservation, teammateID: teammate.id.rawValue)
        let submission = ClaudeTextTurnSubmission(
            conversationID: conversation.id, teammateID: teammate.id,
            userMessageID: MessageID(messageID), text: text
        )
        let result = await coordinator.send(submission) { [weak self] progress in
            guard let self, !self.didFinishShutdown else { return }
            await self.handleTextReplyProgress(progress, conversationID: conversation.id, teammate: teammate,
                                               avatarReservation: avatarReservation,
                                               expectedUserMessageID: submission.userMessageID,
                                               originatedSearchRequest: originatedSearchRequest)
        }
        guard !didFinishShutdown else { return }
        if let user = result.savedUserMessage {
            liveSavedMessages[conversationID, default: [:]][user.id.rawValue] = user
        }
        if let reply = result.savedReplyMessage {
            recordTextTurnReply(reply.id.rawValue, outcome: result.outcome)
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
            case .failed(let problem, let refusedFrame): reason = ClaudeTextReplyPhase.explanation(problem, refusedFrame: refusedFrame)
            case .stopped: reason = "Stopped before this message was saved. Your draft is preserved."
            case .completed: reason = "The saved message could not be confirmed."
            }
            markPendingMessageFailed(messageID, conversationID: conversationID, reason: reason)
        }
        let saved = Array(liveSavedMessages[conversationID, default: [:]].values)
        recordMessageSequences(saved)
        await loadDeliveryProvenance(saved, conversationID: conversation.id)
        guard !didFinishShutdown else { return }
        let isTeamChat = teamChat(for: conversationID) != nil
        if isTeamChat { beginTeamChainStep(conversationID) }
        defer { if isTeamChat { endTeamChainStep(conversationID) } }
        coordinator.finish(conversationID: conversationID, messageID: messageID, outcome: result.outcome)
        presentSavedLiveMessages(conversationID: conversationID, teammate: teammate)
        switch result.outcome {
        case .completed, .stopped: finishTextReplyAvatar(.idle, conversationID: conversationID, reservation: avatarReservation)
        case .failed: finishTextReplyAvatar(.errorOrAttention, conversationID: conversationID, reservation: avatarReservation)
        }
        // The lead may have staged a handoff in this reply, or returned one. A
        // brief this reply staged is the chain the user just started and sends
        // itself; anything else on the board is not this session's to wake. A
        // turn the user stopped stages none of them: the Stop ended the chain
        // this turn was writing, so its briefs wait for a person like every
        // other record on the board.
        if let team = teamChat(for: conversationID) {
            if stoppedHandoffChainConversationIDs.remove(conversationID) == nil {
                await noteHandoffsStagedByThisTurn(team: team, replyMessageID: result.savedReplyMessage?.id)
            }
            await reloadHandoffCards(team: team)
        }
    }

    /// Marks the briefs a completed turn of this session staged, which are the
    /// only ones that dispatch themselves. The reply service anchors every
    /// record it stages on the reply it saved in that same turn, so the turn's
    /// briefs are exactly the staged records whose source is that reply: no
    /// roster reasoning, and neither a record another writer inserted between
    /// two draws nor one left behind while its member was away can be taken
    /// for this turn's. A record staged by a session that ended is governed by
    /// the rule that a pending handoff or saved queue is not permission to wake
    /// work after close: it waits for a person and carries its own Send. A turn
    /// that saved no reply staged nothing.
    private func noteHandoffsStagedByThisTurn(team: TeamChatSnapshot, replyMessageID: MessageID?) async {
        guard let handoffService, !didFinishShutdown, let replyMessageID,
              let records = try? await handoffService.records(conversationID: team.conversation.id) else { return }
        // Stop can arrive while the repository read suspends this task.
        guard !isShuttingDown, !stoppedHandoffChainConversationIDs.contains(team.conversation.id.rawValue) else { return }
        for record in records where record.state == .staged && record.sourceMessageID == replyMessageID {
            sessionStagedHandoffIDs[team.conversation.id.rawValue, default: []].insert(record.id.rawValue)
        }
    }

    /// One text turn's progress, shared by the user's own reply and a member's
    /// handoff leg. A leg has no expected user message: its brief is authored
    /// by the sender, and no composer draft was ever submitted for it.
    private func handleTextReplyProgress(
        _ progress: ClaudeTextTurnProgress,
        conversationID: ConversationID,
        teammate: Teammate,
        avatarReservation: UUID,
        expectedUserMessageID: MessageID?,
        originatedSearchRequest: (requestID: UUID, generation: UInt64)?
    ) async {
        let id = conversationID.rawValue
        updateTextReplyAvatar(progress, conversationID: id, reservation: avatarReservation)
        switch progress {
        case .contextPrepared, .modelObserved, .modelConfirmed, .approvalResolved, .questionResolved, .screenPicture:
            break // The coordinator presents these for its own conversation.
        case .teammateHired(let hire):
            await presentHiredTeammate(hire)
        case .workersStarted(let workers):
            startWorkers(workers, holder: teammate)
        case .selfSetUp(let teammateID, _):
            await presentSelfSetUp(teammateID)
        case .hireNoteSaved(let note), .workerNoteSaved(let note), .selfSetupNoteSaved(let note):
            // The app's own line after the reply: kept like any saved row,
            // and presented as a note, never as a reply that did not come.
            guard note.conversationID == conversationID else { return }
            liveSavedMessages[id, default: [:]][note.id.rawValue] = note
            recordMessageSequences([note])
            presentSavedLiveMessages(conversationID: id, teammate: teammate)
        case .approvalRequired(let approval):
            postNotification(id: approval.id, conversationID: id, teammateID: teammate.id.rawValue, kind: .attention)
        case .questionAsked(let question):
            postNotification(id: question.id, conversationID: id, teammateID: teammate.id.rawValue, kind: .attention)
        case .activity:
            // The coordinator shows the line; an open record follows it.
            refreshWorkRecordIfShown()
        case .bubbles:
            // Committed bubbles, not streamed text: the reply row shows what has
            // settled so far and nothing of the partial text behind it.
            presentInFlightReply(conversationID: conversationID, teammate: teammate)
        case .stage(let stage):
            // Responding begins at CLI initialization, before public text.
            // Only a saved streaming reply below can establish speaking.
            _ = stage // Avatar state is reservation-scoped above.
        case .userMessageSaved(let message):
            guard expectedUserMessageID.map({ $0 == message.id }) ?? true,
                  message.conversationID == conversationID else { return }
            provenanceRequests[conversationID, default: [:]][message.id] = UUID()
            liveSavedMessages[id, default: [:]][message.id.rawValue] = message
            // A leg's first saved message is the sender's brief, not something
            // the user typed, so it does not borrow the composer's wording.
            deliveryNotices[message.id.rawValue] = expectedUserMessageID == nil
                ? "Handoff brief saved · preparing Claude" : "Saved locally · preparing Claude"
            if let expectedUserMessageID {
                await draftCoordinator?.completeSubmission(messageID: expectedUserMessageID.rawValue)
                // The attachment draft's freeze ends at the same durable point as
                // the text draft's. Left to `persistMessage`'s defer, it would
                // hold `attachmentSubmissionAllowed` (and refuse the next `begin`)
                // for the whole turn, which is exactly when a correction must
                // still be able to go out (Send stays live while a bot works). A live turn never carries attachments, so the frozen
                // set committed here is empty.
                attachmentCoordinator?.finish(messageID: expectedUserMessageID.rawValue, committed: true)
            }
            recordMessageSequences([message])
            if conversation.conversationID == id,
               conversation.isShowingLatestPlaceholder,
               originatedSearchRequest?.generation == selectionGeneration {
                await returnToLatest()
            }
            presentSavedLiveMessages(conversationID: id, teammate: teammate)
        case .assistantMessageSaved(let message):
            guard message.conversationID == conversationID else { return }
            if message.deliveryState == .completed, Self.showsInTranscript(message) {
                postNotification(id: message.id.rawValue, conversationID: id, teammateID: teammate.id.rawValue, kind: .reply)
            } else if message.deliveryState == .failed, textReplyCoordinator?.phase(for: id) != .stopping {
                postNotification(id: message.id.rawValue, conversationID: id, teammateID: teammate.id.rawValue, kind: .attention)
            }
            provenanceRequests[conversationID, default: [:]][message.id] = UUID()
            textTurnReplyMessageIDs.insert(message.id.rawValue)
            liveSavedMessages[id, default: [:]][message.id.rawValue] = message
            recordMessageSequences([message])
            let canStream: Bool
            switch message.deliveryState {
            case .completed, .failed, .outcomeUnknown: canStream = false
            case .pending, .queued, .submitted, .acknowledged: canStream = Self.hasClaudeReplyText(message)
            }
            deliveryNotices[message.id.rawValue] = canStream
                ? "Actual Claude reply · partial text saved" : "Saved Claude turn outcome"
            if canStream {
                // A pending reply shows only its settled bubbles; nothing is
                // painted letter by letter.
                presentInFlightReply(conversationID: conversationID, teammate: teammate)
            } else {
                presentSavedLiveMessages(conversationID: id, teammate: teammate)
            }
        }
    }

    private func postNotification(id: UUID, conversationID: UUID, teammateID: UUID, kind: BotNotificationKind) {
        guard !isShuttingDown, !didFinishShutdown, let notifications else { return }
        let event = BotNotificationEvent(id: id, conversationID: conversationID, kind: kind)
        Task { [weak self, weak notifications] in
            // A hidden bot has no chat of its own here but still answers in its
            // teams.
            guard let self, let notifications, !self.isShuttingDown, !self.didFinishShutdown,
                  let teammate = self.directChatsByTeammate[teammateID]?.teammate
                    ?? self.roster(for: conversationID)[teammateID],
                  teammate.lifecycle == .active else { return }
            await notifications.post(event, preference: teammate.notificationPreference)
        }
    }

    /// The reply in flight, as the bubbles settled so far. Absent bubbles mean
    /// no row yet: the creature works, and the first line appears when it is
    /// settled. The saved partial text is never shown.
    private func presentInFlightReply(conversationID: ConversationID, teammate: Teammate) {
        let id = conversationID.rawValue
        guard !isShuttingDown, conversation.conversationID == id, !conversation.needsLatestPage,
              let bubbles = textReplyCoordinator?.bubbles(for: id), !bubbles.isEmpty,
              let reply = liveSavedMessages[id, default: [:]].values
                  .filter({ Self.showsInTranscript($0) && textTurnReplyMessageIDs.contains($0.id.rawValue) && $0.deliveryState != .completed })
                  .max(by: { $0.sequence < $1.sequence }) else { return }
        var snapshot = presentedMessage(reply, teammate: teammate)
        let partID = reply.parts.first?.id.rawValue ?? reply.id.rawValue
        snapshot = ChatMessageSnapshot(id: snapshot.id, author: snapshot.author,
            parts: [ChatMessagePartSnapshot(id: partID, ordinal: 0, content: .text(bubbles.joined(separator: "\n\n")))],
            delivery: snapshot.delivery, timestamp: snapshot.timestamp)
        snapshot.deliveryNotice = deliveryNotices[reply.id.rawValue]
        conversation.replaceMessage(snapshot)
    }

    /// What Details says about the model of the last reply for a conversation:
    /// this session's observation first, otherwise the saved turn record.
    public func modelStatus(for conversationID: UUID?) -> ClaudeModelRunPresentation? {
        textReplyCoordinator?.modelPresentation(for: conversationID)
    }

    private func refreshTextReplyPhase() {
        guard !didFinishShutdown else { return }
        // Details holds a value snapshot of coordinator model status, so its
        // observing workspace must refresh as well as the child conversation.
        notifyWorkspaceChange()
        let wasBusy = conversation.textReplyPhase?.isBusy == true
        let hadApproval = conversation.textReplyApproval != nil
        conversation.setTextReplyPhase(textReplyCoordinator?.phase(for: conversation.conversationID))
        conversation.setTextReplyContextDisclosure(textReplyCoordinator?.contextDisclosure(for: conversation.conversationID))
        conversation.setTextReplyApproval(textReplyCoordinator?.approval(for: conversation.conversationID))
        conversation.setTextReplyQuestion(textReplyCoordinator?.question(for: conversation.conversationID))
        conversation.setTextReplyActivity(textReplyCoordinator?.activity(for: conversation.conversationID))
        conversation.setTextReplyActivityLines(textReplyCoordinator?.activityHistory(for: conversation.conversationID) ?? [])
        conversation.setBackgroundWorkerLines(backgroundWorkerLines(conversationID: conversation.conversationID),
            canStop: conversation.conversationID.map { hasWorkerWork(conversationID: $0) } ?? false)
        conversation.setTextReplyScreenPicture(textReplyCoordinator?.screenPicture(for: conversation.conversationID))
        // The record re-reads on the edges that change it: a card answered, a
        // turn begun or ended. Activity lines arrive with the next edge.
        if wasBusy != (conversation.textReplyPhase?.isBusy == true) || hadApproval != (conversation.textReplyApproval != nil) {
            refreshWorkRecordIfShown()
        }
    }

    private func presentSavedLiveMessages(conversationID: UUID, teammate: Teammate?) {
        guard !isShuttingDown, conversation.conversationID == conversationID, !conversation.needsLatestPage else { return }
        for message in liveSavedMessages[conversationID, default: [:]].values.sorted(by: { $0.sequence < $1.sequence })
        where Self.showsInTranscript(message) {
            conversation.replaceMessage(presentedMessage(message, teammate: teammate))
        }
    }

    /// The transcript shows what is for the user. Bot-to-bot traffic, saved
    /// as work-audit messages, is on the record instead.
    static func showsInTranscript(_ message: Message) -> Bool { message.outputClass != .workAudit }

    private func presentedMessage(_ message: Message, teammate: Teammate?) -> ChatMessageSnapshot {
        // A team names its own authors. A bot that has left the roster is
        // labelled a former member, never relabelled as the presenting bot,
        // which would attribute one bot's saved words to another.
        let roster = roster(for: message.conversationID.rawValue)
        var snapshot = Self.messageSnapshot(message, teammate: roster.isEmpty ? teammate : nil, roster: roster,
                                            deletedAuthors: deletedBotIDs)
        if textReplyService != nil {
            snapshot.deliveryNotice = deliveryNotices[message.id.rawValue] ?? "Saved on this Mac · Claude delivery not verified"
            if agenticJobCoordinator?.presentation(for: message.conversationID.rawValue) != nil,
               !textTurnReplyMessageIDs.contains(message.id.rawValue) {
                // A job uses its own journal, not the text-only provenance table.
                snapshot.deliveryNotice = "Saved on this Mac"
            }
            let hasStatusPart = message.parts.contains { part in
                if case .status = part.content { return true }
                return false
            }
            // The line naming a reply's hires or workers is the app's own note.
            // It is recognised by its words, so a relaunch knows it too.
            if Self.isHireNote(message) {
                snapshot = ChatMessageSnapshot(
                    id: snapshot.id, author: .system(label: "OpenBots"), parts: snapshot.parts,
                    delivery: snapshot.delivery, timestamp: snapshot.timestamp
                )
                snapshot.deliveryNotice = Self.hireNoteNotice
                return snapshot
            }
            // A memory-qualified reply is stored app-authored, so a team
            // transcript would otherwise credit every one of them to
            // "OpenBots" and hide which member answered. The run names that
            // member; keep the app-qualified mark and add the name to it.
            // A direct chat is the bot's own, so it is left exactly as it was.
            if !roster.isEmpty, message.author == .system, Self.hasReplyText(message),
               let responsible = textTurnReplyTeammates[message.id.rawValue],
               let member = roster[responsible] {
                let notice = snapshot.deliveryNotice
                snapshot = ChatMessageSnapshot(
                    id: snapshot.id,
                    author: .system(label: "OpenBots · for \(member.profile.displayName)"),
                    parts: snapshot.parts, delivery: snapshot.delivery, timestamp: snapshot.timestamp
                )
                snapshot.deliveryNotice = notice
            } else if message.author != .user,
                      textTurnReplyMessageIDs.contains(message.id.rawValue) || hasStatusPart,
                      !Self.hasClaudeReplyText(message) {
                snapshot = ChatMessageSnapshot(
                    id: snapshot.id, author: .system(label: "OpenBots"), parts: snapshot.parts,
                    delivery: snapshot.delivery, timestamp: snapshot.timestamp
                )
                // A turn the bot declined is not a turn that broke. Saying
                // "no Claude reply received" over it sends the person after a
                // fault that never happened.
                snapshot.deliveryNotice = declinedReplyMessageIDs.contains(message.id.rawValue)
                    ? "OpenBots status · the bot declined this one"
                    : "OpenBots status · no Claude reply received"
            }
        }
        return snapshot
    }

    /// One reply row this session's own turn produced, and whether that turn
    /// ended with the bot declining rather than with anything going wrong.
    private func recordTextTurnReply(_ id: UUID, outcome: ClaudeTextTurnOutcome) {
        textTurnReplyMessageIDs.insert(id)
        if outcome == .failed(.declined) { declinedReplyMessageIDs.insert(id) }
    }

    /// One app-authored status line that `TeammateHireNote` or
    /// `TeammateWorkerNote` wrote.
    static func isHireNote(_ message: Message) -> Bool {
        guard message.author == .system, message.parts.count == 1,
              case .status(let text) = message.parts[0].content else { return false }
        return TeammateHireNote.isNote(text) || TeammateWorkerNote.isNote(text)
    }

    private static func hasClaudeReplyText(_ message: Message) -> Bool {
        guard case .teammate = message.author else { return false }
        return hasReplyText(message)
    }

    private static func hasReplyText(_ message: Message) -> Bool {
        message.parts.contains { part in
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
                // A turn the bot declined is journalled failed like any other
                // that ended without an answer, so the outcome, not the state,
                // decides whether this line accuses the app of anything.
                case .failed where record.outcome == .declined:
                    reply = "The bot declined this one · available reply text saved"
                case .failed: reply = "Claude turn failed · available reply text saved"
                case .interrupted: reply = "Claude turn stopped · available reply text saved"
                case .queued, .starting, .running, .waitingForUser, .stopping:
                    reply = textReplyCoordinator?.phase(for: conversationID.rawValue)?.isBusy == true
                        ? "Claude reply in progress · partial text saved"
                        : "Saved partial reply · previous Claude turn outcome unknown"
                }
                if isCurrent(record.replyMessageID) {
                    textTurnReplyMessageIDs.insert(record.replyMessageID.rawValue)
                    // Only a run that has actually ended may speak here. A
                    // record still in flight carries no outcome at all, and a
                    // provenance read that started before this turn settled can
                    // land after it; forgetting the decision on that would put
                    // the failure wording back over a turn nobody failed.
                    if record.outcome == .declined { declinedReplyMessageIDs.insert(record.replyMessageID.rawValue) }
                    else if record.outcome != nil { declinedReplyMessageIDs.remove(record.replyMessageID.rawValue) }
                    textTurnReplyTeammates[record.replyMessageID.rawValue] = record.teammateID.rawValue
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
        // A member's editor opened from inside a team belongs to the details
        // pane rather than to the conversation, so re-presenting that same team
        // after a roster change must not drop the edit in progress.
        let editorTeammateID = profileEditor?.teammateID.rawValue
        if editorTeammateID != teammateID(for: conversationID),
           editorTeammateID != detailsTeammate?.id.rawValue {
            profileEditor = nil
        }
        collaborationModel?.activateConversation(
            conversationID,
            selectedTeammateID: teammateID(for: conversationID)
        )
        if conversationID == nil || teamChat(for: conversationID ?? UUID()) == nil { handoffCards = [] }
        refreshWorkRecordIfShown()
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
        if let conversationID, let coordinator = textReplyCoordinator {
            Task { @MainActor [weak self] in
                await coordinator.loadSavedModelStatus(conversationID: conversationID)
                self?.refreshTextReplyPhase()
            }
        }
        agenticJobAccessModel?.selectTeammate(teammateID(for: conversationID).map { TeammateID($0) })
        botWorkspaceModel?.select(teammateID(for: conversationID).map { TeammateID($0) })
        refreshAgenticJobPresentation()
        if let conversationID { Task { [weak self] in await self?.agenticJobCoordinator?.loadHistory(conversationID: conversationID) } }
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

    /// Attachments are direct-only for now. A team conversation must
    /// never reach the durable per-conversation draft: the attachment
    /// repository validates direct-only and always throws for a team
    /// conversation ID, so a scoped draft never reaches `.ready` there —
    /// `canSubmit` stays false from the moment it is created, which both
    /// surfaces a "couldn't be loaded" error in the tray once the load
    /// settles and leaves `attachmentSubmissionAllowed` (so Send) disabled
    /// the whole time. Route it to the inert unscoped draft instead, and set
    /// submission state explicitly since it never goes through the
    /// coordinator's admission recompute.
    private func activateDraftState(for conversationID: UUID?) {
        draftCoordinator?.activate(conversationID: conversationID)
        let isTeamConversation = isTeamConversation(conversationID)
        // Withdraw the affordance rather than leaving it pointed at the shared
        // unscoped draft: picking a file there stages a row before the
        // always-throwing importer refuses it, and that failed row would then
        // sit in every team conversation until it was dismissed by hand.
        // Sending text stays enabled; only attaching is withdrawn.
        conversation.setAttachmentsAvailable(!isTeamConversation)
        if let attachmentCoordinator {
            if isTeamConversation {
                attachmentDraft = unscopedAttachmentDraft
                conversation.setAttachmentSubmission(allowed: true, hasContent: false)
            } else {
                attachmentDraft = attachmentCoordinator.activate(conversationID) ?? unscopedAttachmentDraft
            }
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
        if isTeamConversation {
            if attachmentDraft !== unscopedAttachmentDraft {
                attachmentDraft = unscopedAttachmentDraft
            }
            return
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
                lastActivityAt: current.lastActivityAt,
                isPinned: current.isPinned
            )
        )
    }

    private func beginTextReplyAvatar(conversationID: UUID, reservation: UUID, teammateID: UUID) {
        let previous = textReplyAvatarTurns[conversationID]
        textReplyAvatarTurns[conversationID] = .init(reservation: reservation, teammateID: teammateID)
        if let previous, previous.teammateID != teammateID {
            // Steering can replace member A with @B before A's cancelled task
            // returns. Retire A now; its late terminal callback no longer owns
            // this conversation, but another conversation can still own A.
            reconcileTextReplyAvatar(teammateID: previous.teammateID, fallback: .idle)
        }
        guard textReplyCoordinator?.phase(for: conversationID) != .stopping else { return }
        reconcileTextReplyAvatar(teammateID: teammateID, fallback: .thinkingOrWorking)
    }

    private func updateTextReplyAvatar(_ progress: ClaudeTextTurnProgress, conversationID: UUID, reservation: UUID) {
        guard !isShuttingDown, !didFinishShutdown,
              var turn = textReplyAvatarTurns[conversationID], turn.reservation == reservation,
              let phase = textReplyCoordinator?.phase(for: conversationID), phase.isBusy, phase != .stopping else { return }
        switch progress {
        case .approvalRequired(let approval):
            guard textReplyCoordinator?.approval(for: conversationID)?.id == approval.id else { return }
            turn.approvalID = approval.id
        case .questionAsked(let question):
            guard textReplyCoordinator?.question(for: conversationID)?.id == question.id else { return }
            turn.questionID = question.id
        case .approvalResolved(let id):
            guard turn.approvalID == id else { return }
            turn.approvalID = nil
        case .questionResolved(let id):
            guard turn.questionID == id else { return }
            turn.questionID = nil
        case .bubbles:
            turn.workingActivity = .speaking
        case .stage(let stage):
            if stage != .responding { turn.workingActivity = .thinkingOrWorking }
        default: return
        }
        textReplyAvatarTurns[conversationID] = turn
        reconcileTextReplyAvatar(teammateID: turn.teammateID, fallback: turn.activity)
    }

    private func finishTextReplyAvatar(_ activity: TeammateActivityState, conversationID: UUID, reservation: UUID) {
        guard let turn = textReplyAvatarTurns[conversationID], turn.reservation == reservation else { return }
        textReplyAvatarTurns[conversationID] = nil
        reconcileTextReplyAvatar(teammateID: turn.teammateID, fallback: activity)
    }

    private func reconcileTextReplyAvatar(teammateID: UUID, fallback: TeammateActivityState) {
        // A bot can also be visible through a different conversation. Finishing
        // this reservation must not erase another currently owned activity.
        let activeTurns = textReplyAvatarTurns.filter {
            $0.value.teammateID == teammateID && textReplyCoordinator?.phase(for: $0.key)?.isBusy == true
                && textReplyCoordinator?.phase(for: $0.key) != .stopping
        }
        // Sidebar DM row: only the bot's own direct chat may set its row activity.
        // Team turns publish through workingAvatarByConversation instead.
        let dmConversationID = directChatsByTeammate[teammateID]?.conversation.id.rawValue
        let dmActivity: TeammateActivityState
        if let dmConversationID, let turn = activeTurns[dmConversationID] {
            dmActivity = turn.activity
        } else if let dmConversationID, workerIsRunning(holderID: teammateID, conversationID: dmConversationID) {
            // A worker the bot started in its own chat keeps its face working
            // after its one-line turn ended, so it is seen in motion.
            dmActivity = .thinkingOrWorking
        } else if activeTurns.isEmpty {
            dmActivity = fallback
        } else {
            dmActivity = .idle
        }
        setActivity(dmActivity, teammateID: teammateID)
        publishWorkingAvatarsByConversation()
    }

    /// Rebuild the per-conversation working map from open avatar turns so team
    /// and in-thread surfaces can animate without leaking into other chats.
    private func publishWorkingAvatarsByConversation() {
        var map: [UUID: ConversationWorkingAvatar] = [:]
        for (conversationID, turn) in textReplyAvatarTurns {
            guard textReplyCoordinator?.phase(for: conversationID)?.isBusy == true,
                  textReplyCoordinator?.phase(for: conversationID) != .stopping else { continue }
            map[conversationID] = ConversationWorkingAvatar(teammateID: turn.teammateID, activity: turn.activity)
        }
        for running in runningWorkers.values where map[running.worker.conversationID.rawValue] == nil {
            map[running.worker.conversationID.rawValue] = ConversationWorkingAvatar(
                teammateID: running.worker.holderID.rawValue, activity: .thinkingOrWorking)
        }
        sidebar.setWorkingAvatarByConversation(map)
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
                unreadCount: current.unreadCount, lastActivityAt: timestamp,
                isPinned: current.isPinned
            ))
        }
        for (conversationID, timestamp) in latestByConversation {
            guard let team = teamChat(for: conversationID),
                  let current = sidebar.teamRows.first(where: { $0.id == team.team.id.rawValue }),
                  current.lastActivityAt.map({ timestamp > $0 }) ?? true else { continue }
            sidebar.updateTeam(TeamRowSnapshot(id: current.id, conversationID: current.conversationID,
                                               name: current.name, leadName: current.leadName,
                                               members: current.members, lastActivityAt: timestamp))
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
            lastActivityAt: chat.conversation.updatedAt,
            isPinned: chat.teammate.isPinned
        )
    }

    private static func messageSnapshot(
        _ message: Message,
        teammate: Teammate?,
        roster: [UUID: Teammate] = [:],
        deletedAuthors: Set<UUID> = []
    ) -> ChatMessageSnapshot {
        let author: ChatAuthorSnapshot
        switch message.author {
        case .user:
            author = .user
        case .system:
            author = .system(label: "OpenBots")
        case let .teammate(authorID):
            // A team transcript names its own author. The presenting bot is
            // the fallback for a direct chat, where the roster is empty. A
            // deleted bot's kept words say so; a bot that merely left the
            // team is a former member.
            if let member = roster[authorID.rawValue] {
                author = .teammate(TeammateIdentitySnapshot(member))
            } else if deletedAuthors.contains(authorID.rawValue) {
                author = .system(label: DeletedTeammate.displayName)
            } else if let teammate {
                author = .teammate(TeammateIdentitySnapshot(teammate))
            } else {
                author = .system(label: "Former member")
            }
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
    /// Opens Settings on one pane: the Access sheet's Open Settings beside a
    /// master that is off. Nil leaves that button out.
    private let openSettingsPane: (@MainActor (WorkspaceSettingsSection) -> Void)?

    public init(
        model: DurableWorkspaceModel,
        openSettings: @escaping @MainActor () -> Void,
        openClaudeSetup: (@MainActor () -> Void)? = nil,
        openSettingsPane: (@MainActor (WorkspaceSettingsSection) -> Void)? = nil
    ) {
        self.model = model
        self.openSettings = openSettings
        self.openClaudeSetup = openClaudeSetup
        self.openSettingsPane = openSettingsPane
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
            createTeam: model.canCreateTeam ? model.beginTeamCreation : nil,
            configureTeam: model.canEditTeams ? { model.beginTeamEditing(teamID: $0) } : nil,
            teamMembers: model.teamMemberSettingsTargets,
            hiddenTeamMembers: model.teamHiddenMembers,
            openMemberSettings: model.showMemberDetails,
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
            archiveBot: model.archiveModel != nil ? model.requestBotArchive : nil,
            archiveTeam: model.archiveModel?.supportsTeams == true ? model.requestTeamArchive : nil,
            pinBot: model.hiddenModel != nil ? model.requestBotPin : nil,
            hideBot: model.hiddenModel != nil ? model.requestBotHide : nil,
            deleteBot: model.deletionServiceAvailable ? model.requestBotDelete : nil,
            openHiddenBots: model.hiddenModel.map { hidden in { hidden.isPresented = true } },
            openBotAccess: model.supportsBotAccess ? model.openBotAccess : nil,
            openWorkRecord: model.canShowWorkRecord ? model.openWorkRecord : nil
        )
        .sheet(isPresented: Binding(get: { model.isShowingWorkRecord }, set: { if !$0 { model.closeWorkRecord() } })) {
            ConversationWorkRecordView(model: model)
        }
        .sheet(item: Binding(get: { model.botAccess }, set: { if $0 == nil { model.dismissBotAccess() } })) { access in
            BotAccessSheet(model: access, onDone: model.dismissBotAccess, openSettings: openSettingsPane)
        }
        .disabled(model.archiveModel?.isBusy == true)
        .sheet(isPresented: Binding(
            get: { model.archiveModel?.isPresented == true },
            set: { model.archiveModel?.isPresented = $0 }
        )) {
            if let archive = model.archiveModel {
                ArchivedBotsView(model: archive, restore: model.restoreBot, restoreTeam: model.restoreTeam)
                    .environment(\.profilePhotoPresentation, model.photoPresentation)
            }
        }
        .alert("Archive Bot", isPresented: Binding(
            get: { model.archiveModel?.isPresented == false && model.archiveModel?.errorMessage != nil },
            set: { if !$0 { model.archiveModel?.errorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.archiveModel?.errorMessage = nil } }
        message: { Text(model.archiveModel?.errorMessage ?? "") }

        .sheet(isPresented: Binding(
            get: { model.hiddenModel?.isPresented == true },
            set: { model.hiddenModel?.isPresented = $0 }
        )) {
            if let hidden = model.hiddenModel {
                HiddenBotsView(model: hidden, unhide: model.unhideBot)
                    .environment(\.profilePhotoPresentation, model.photoPresentation)
            }
        }
        .confirmationDialog(
            model.deleteRequest.map { "Delete \($0.inventory.displayName)?" } ?? "Delete Bot?",
            isPresented: Binding(
                get: { model.deleteRequest != nil },
                set: { if !$0 { model.cancelDeleteBot() } }
            ),
            titleVisibility: .visible,
            presenting: model.deleteRequest
        ) { request in
            Button("Delete Bot", role: .destructive) { Task { await model.confirmDeleteBot(request) } }
            Button("Cancel", role: .cancel) { model.cancelDeleteBot() }
        } message: { request in
            Text(deleteConfirmationMessage(request.inventory))
        }
        .alert("Bot Action", isPresented: Binding(
            get: { model.deleteErrorMessage != nil },
            set: { if !$0 { model.deleteErrorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.deleteErrorMessage = nil } }
        message: { Text(model.deleteErrorMessage ?? "") }
        .alert("Export Conversations", isPresented: Binding(
            get: { model.exportNotice != nil },
            set: { if !$0 { model.exportNotice = nil } }
        )) { Button("OK", role: .cancel) { model.exportNotice = nil } } message: { Text(model.exportNotice ?? "") }
        .sheet(item: Binding(get: { model.teamCreation }, set: { if $0 == nil { model.dismissTeamCreation() } })) { creation in
            TeamCreationView(model: creation, onCancel: model.dismissTeamCreation)
                .environment(\.profilePhotoPresentation, model.photoPresentation)
        }
        .sheet(item: Binding(get: { model.teamEditor }, set: { if $0 == nil { model.dismissTeamEditing() } })) { editor in
            TeamCreationView(model: editor, onCancel: model.dismissTeamEditing,
                             memberSettingsTargets: Set(model.teamMemberSettingsTargets.map(\.id)),
                             openMemberSettings: model.openMemberDetailsFromTeamEditor)
                .environment(\.profilePhotoPresentation, model.photoPresentation)
        }
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
              let teammate = model.detailsTeammate else { return nil }
        if let editor = model.profileEditor, editor.teammateID == teammate.id {
            return AnyView(TeammateProfileEditorView(
                model: editor, onSaved: model.profileDidSave,
                onCancelled: model.cancelProfileEditing,
                onBack: model.returnToDetails, onClose: model.closeBotDetails,
                modelStatus: model.detailsModelStatus
            ).id(teammate.id))
        }
        return AnyView(BotDetailsView(
            teammate: teammate, canEdit: model.canEditDetailsProfile,
            onEdit: model.editDetailsProfile, onClose: model.closeBotDetails,
            // Archiving and exporting stay on the bot's own chat: both act on
            // the selection, which a member's pane deliberately leaves alone.
            canArchive: model.canArchiveSelectedBot,
            onArchive: { Task { await model.archiveSelectedBot() } },
            onExport: model.supportsExport ? { Self.chooseExportFolder(for: model) } : nil,
            modelStatus: model.detailsModelStatus,
            agenticJobAccess: model.agenticJobAccessModel,
            connectorAccess: model.connectorAccessStore,
            onOpenAccess: model.supportsBotAccess ? { model.openBotAccess(id: teammate.id.rawValue) } : nil,
            workspace: model.botWorkspaceModel,
            activityRow: model.sidebar.rowModels.first(where: { $0.id == teammate.id.rawValue }),
            activityConversation: model.detailsActivityConversation,
            activityIsTeamChat: model.detailsActivityIsTeamChat,
            onOpenWorkRecord: model.canShowWorkRecord ? model.openWorkRecord : nil
        ).id(teammate.id))
    }
}

extension DurableWorkspaceView {
    /// The native folder picker; the export writes one new folder inside the choice
    /// and never overwrites anything.
    @MainActor
    static func chooseExportFolder(for model: DurableWorkspaceModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose where OpenBots creates a new export folder for this bot's conversations."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.exportSelectedBotConversations(into: folder) }
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

/// New Team was reachable but the workspace can no longer commit one: the
/// service is absent or shutdown began. Distinct from a rejected draft.
private struct TeamCreationUnavailableError: Error, Sendable {}
private struct TeammateCreationUnavailableError: Error, Sendable {}

func deleteConfirmationMessage(_ inventory: TeammateDeleteInventory) -> String {
    var named: [String] = []
    if inventory.hasProfile { named.append("its profile") }
    named.append(inventory.conversationCount > 1 ? "its \(inventory.conversationCount) transcripts" : "its transcript")
    if inventory.memoryDocumentCount > 0 { named.append("its memory") }
    if inventory.membershipCount > 0 { named.append("its memberships") }
    if inventory.hasProfileAsset { named.append("its profile photo") }
    let last = named.removeLast()
    let listed = named.isEmpty ? last : named.joined(separator: ", ") + " and " + last
    var sentences = ["This permanently removes \(listed)."]
    // A deleted bot that spoke in a team chat keeps its messages there.
    if inventory.keepsTeamHistory {
        sentences.append("Its messages in team chats stay, shown as “Deleted bot”.")
    }
    if inventory.botHomePath != nil || inventory.skillsPath != nil {
        sentences.append("Recoverable folders go to Trash where macOS allows.")
    }
    sentences.append("Workspace folders you added stay where they are.")
    return sentences.joined(separator: " ")
}
