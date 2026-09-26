import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private func teamBot(_ n: UInt8, name: String, role: String) throws -> Teammate {
    let id = UUID(uuidString: String(format: "c3000000-0000-0000-0000-%012d", n))!
    let date = Date(timeIntervalSince1970: 1_781_300_000 + Double(n))
    return try Teammate(id: TeammateID(id), profile: TeammateProfile(displayName: name, role: role),
        appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: UInt64(n), silhouette: "soft-arch",
            paletteToken: "violet-coral", eyeDialect: "round-alert", nonColorIdentityCue: "brow notch \(n)",
            accessibleIdentityDescription: "Violet creature with brow notch \(n)"),
        createdAt: date, updatedAt: date)
}

private func teamText(_ conversationID: ConversationID, sequence: Int64, author: MessageAuthor, text: String) throws -> Message {
    let date = Date(timeIntervalSince1970: 1_781_400_000 + Double(sequence))
    return try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence, author: author,
        deliveryState: .completed, parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
        createdAt: date, updatedAt: date)
}

/// Production writes one `chat_navigation_state` singleton, so a team
/// selection overwrites a bot selection and the direct-chat query then reports
/// none. The fakes share this box rather than each keeping a private answer.
private actor SharedSelection {
    private(set) var conversationID: ConversationID?
    init(conversationID: ConversationID?) { self.conversationID = conversationID }
    func set(_ id: ConversationID?) { conversationID = id }
}

private actor TeamWorkspaceChatFake: DurableTeammateChatServing {
    private var chats: [DurableDirectChatSnapshot]
    private let selection: SharedSelection
    private(set) var messages: [ConversationID: [Message]]
    private(set) var savedTargets: [(ConversationID, TeammateID, String)] = []

    init(chats: [DurableDirectChatSnapshot], selection: SharedSelection, messages: [ConversationID: [Message]]) {
        self.chats = chats; self.selection = selection; self.messages = messages
    }
    func activeDirectChats() async throws -> [DurableDirectChatSnapshot] { chats }
    func selectedDirectChat() async throws -> DurableChatSelectionSnapshot? {
        guard let id = await selection.conversationID,
              let chat = chats.first(where: { $0.conversation.id == id }) else { return nil }
        return DurableChatSelectionSnapshot(teammate: chat.teammate, conversation: chat.conversation)
    }
    func select(teammateID: TeammateID, conversationID: ConversationID) async throws {
        guard chats.contains(where: { $0.teammate.id == teammateID && $0.conversation.id == conversationID }) else {
            throw RepositoryError.notFound(entity: "direct chat", id: conversationID.persistedValue)
        }
        await selection.set(conversationID)
    }
    func clearSelection() async throws { await selection.set(nil) }
    func createTeammateAndDirectChat(_ draft: DurableTeammateDraft) async throws -> DurableTeammateChatCreationSnapshot {
        throw RepositoryError.unavailable(reason: "unused")
    }
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        let all = (messages[conversationID] ?? []).sorted { $0.sequence < $1.sequence }
        return DurableMessagePageSnapshot(conversationID: conversationID, messages: Array(all.suffix(limit)), hasMore: false, nextBeforeSequence: nil)
    }
    func saveMessageLocally(conversationID: ConversationID, teammateID: TeammateID, userMessageID: MessageID,
                            text: String, attachmentIDs: [AttachmentID]) async throws -> Message {
        savedTargets.append((conversationID, teammateID, text))
        let sequence = Int64((messages[conversationID] ?? []).count + 1)
        let message = try Message(id: userMessageID, conversationID: conversationID, sequence: sequence, author: .user,
            deliveryState: .completed, parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: Date(), updatedAt: Date())
        messages[conversationID, default: []].append(message)
        return message
    }
    func append(_ message: Message) { messages[message.conversationID, default: []].append(message) }
    /// What the repository's direct-chat list does on Hide: a hidden bot's chat
    /// leaves the list, and comes back in place on Unhide.
    private var hiddenChats: [DurableDirectChatSnapshot] = []
    func setHidden(_ bot: Teammate) {
        if bot.isHidden {
            hiddenChats += chats.filter { $0.teammate.id == bot.id }
            chats.removeAll { $0.teammate.id == bot.id }
        } else {
            chats += hiddenChats.filter { $0.teammate.id == bot.id }
                .map { DurableDirectChatSnapshot(teammate: bot, conversation: $0.conversation) }
            hiddenChats.removeAll { $0.teammate.id == bot.id }
        }
    }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw DurableTeammateChatError.reviewFixtureUnavailable
    }
}

private actor TeamWorkspaceTeamFake: TeamChatServing {
    private(set) var teams: [TeamChatSnapshot]
    private let selection: SharedSelection
    private(set) var createdDrafts: [TeamChatDraft] = []
    private var members: [Teammate]
    init(teams: [TeamChatSnapshot], selection: SharedSelection, members: [Teammate]) {
        self.teams = teams; self.selection = selection; self.members = members
    }
    var selectedID: TeamID? {
        get async {
            guard let id = await selection.conversationID else { return nil }
            return teams.first { $0.conversation.id == id }?.team.id
        }
    }
    func activeTeamChats() async throws -> [TeamChatSnapshot] { teams }
    func member(_ id: TeammateID) -> Teammate? { members.first { $0.id == id } }
    func selectedTeamChat() async throws -> TeamChatSnapshot? {
        guard let id = await selection.conversationID else { return nil }
        return teams.first { $0.conversation.id == id }
    }
    func select(teamID: TeamID) async throws {
        guard let chat = teams.first(where: { $0.team.id == teamID }) else { throw TeamChatError.teamUnavailable(teamID) }
        await selection.set(chat.conversation.id)
    }
    func createTeamChat(_ draft: TeamChatDraft) async throws -> TeamChatSnapshot {
        createdDrafts.append(draft)
        let date = Date(timeIntervalSince1970: 1_781_500_000)
        let team = try Team(id: TeamID(UUID()), name: draft.name, leadID: draft.leadID, memberIDs: draft.memberIDs, createdAt: date, updatedAt: date)
        let conversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: team.id), title: draft.name, createdAt: date, updatedAt: date)
        let snapshot = TeamChatSnapshot(team: team, conversation: conversation, members: members.filter { draft.memberIDs.contains($0.id) })
        teams.append(snapshot)
        await selection.set(conversation.id)
        return snapshot
    }
    func teamChat(conversationID: ConversationID) async throws -> TeamChatSnapshot? { teams.first { $0.conversation.id == conversationID } }

    private(set) var edits: [TeamChatEdit] = []
    private var nextEditFailure: (any Error)?
    func failNextEdit(_ error: any Error) { nextEditFailure = error }
    /// Applies the edit the way the service does: the stored snapshot keeps its
    /// identity and its conversation recency, and its roster becomes exactly
    /// the edited member set.
    func updateTeamChat(_ edit: TeamChatEdit) async throws -> TeamChatSnapshot {
        edits.append(edit)
        if let failure = nextEditFailure { nextEditFailure = nil; throw failure }
        guard edit.memberIDs.count >= 2 else { throw TeamChatError.tooFewMembers }
        guard edit.memberIDs.contains(edit.leadID) else { throw TeamChatError.leadNotMember(edit.leadID) }
        guard let index = teams.firstIndex(where: { $0.team.id == edit.teamID }) else {
            throw TeamChatError.teamUnavailable(edit.teamID)
        }
        let current = teams[index]
        let team = try Team(id: current.team.id, name: edit.name, leadID: edit.leadID, memberIDs: edit.memberIDs,
                            createdAt: current.team.createdAt, updatedAt: current.team.updatedAt)
        let conversation = try Conversation(id: current.conversation.id, kind: current.conversation.kind,
                                            title: edit.name, createdAt: current.conversation.createdAt,
                                            updatedAt: current.conversation.updatedAt)
        let snapshot = TeamChatSnapshot(team: team, conversation: conversation,
            members: members.filter { edit.memberIDs.contains($0.id) }
                .sorted { $0.profile.displayName < $1.profile.displayName })
        teams[index] = snapshot
        return snapshot
    }

    /// A second writer publishing a new roster for this team, the way another
    /// window or a job would: the stored snapshot changes and carries the later
    /// instant that a sheet opened before it will be refused against.
    func publishFromAnotherWriter(teamID: TeamID, name: String, leadID: TeammateID,
                                  memberIDs: Set<TeammateID>, at instant: Date) throws {
        guard let index = teams.firstIndex(where: { $0.team.id == teamID }) else { return }
        let current = teams[index]
        let team = try Team(id: current.team.id, name: name, leadID: leadID, memberIDs: memberIDs,
                            createdAt: current.team.createdAt, updatedAt: instant)
        let conversation = try Conversation(id: current.conversation.id, kind: current.conversation.kind,
                                            title: name, createdAt: current.conversation.createdAt,
                                            updatedAt: current.conversation.updatedAt)
        teams[index] = TeamChatSnapshot(team: team, conversation: conversation,
            members: members.filter { memberIDs.contains($0.id) }
                .sorted { $0.profile.displayName < $1.profile.displayName })
    }

    /// Hide changes the bot, not its teams: the team snapshots carry the
    /// hidden bot among their members, as `TeamChatService` reads them.
    func setHidden(_ bot: Teammate) {
        members = members.map { $0.id == bot.id ? bot : $0 }
        teams = teams.map { snapshot in
            TeamChatSnapshot(team: snapshot.team, conversation: snapshot.conversation,
                             members: snapshot.members.map { $0.id == bot.id ? bot : $0 })
        }
    }

    /// What the repository reports after a bot is archived or restored: the
    /// team keeps naming it, the active roster does not carry it.
    func archive(_ id: TeammateID) {
        teams = teams.map { snapshot in
            TeamChatSnapshot(team: snapshot.team, conversation: snapshot.conversation,
                             members: snapshot.members.filter { $0.id != id })
        }
    }
    func restore(_ bot: Teammate) {
        teams = teams.map { snapshot in
            guard snapshot.team.memberIDs.contains(bot.id), !snapshot.members.contains(where: { $0.id == bot.id }) else { return snapshot }
            return TeamChatSnapshot(team: snapshot.team, conversation: snapshot.conversation,
                members: (snapshot.members + [bot]).sorted { $0.profile.displayName < $1.profile.displayName })
        }
    }
}

/// Archiving is what makes a lead inactive, so this fake moves the team
/// roster exactly as the repository would.
private actor TeamWorkspaceArchiveFake: TeammateArchiving {
    private let teamFake: TeamWorkspaceTeamFake
    private var archived: [Teammate] = []
    init(teamFake: TeamWorkspaceTeamFake) { self.teamFake = teamFake }
    func archivedTeammates() async throws -> [Teammate] { archived }
    func archiveTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        guard var bot = await teamFake.member(id) else { throw TeammateArchiveError.notFound }
        bot.lifecycle = .archived
        await teamFake.archive(id)
        archived.append(bot)
        return bot
    }
    func restoreTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> Teammate {
        guard var bot = archived.first(where: { $0.id == id }) else { throw TeammateArchiveError.notFound }
        bot.lifecycle = .active
        archived.removeAll { $0.id == id }
        await teamFake.restore(bot)
        return bot
    }
}

/// Hide and Unhide as the navigation service writes them, carried to the
/// direct-chat list and the team snapshots the way the repository reads them.
private actor TeamWorkspaceNavigationFake: TeammateNavigating {
    private let chatFake: TeamWorkspaceChatFake
    private let teamFake: TeamWorkspaceTeamFake
    private var hidden: [Teammate] = []
    init(chatFake: TeamWorkspaceChatFake, teamFake: TeamWorkspaceTeamFake) { self.chatFake = chatFake; self.teamFake = teamFake }
    func setPinned(id: TeammateID, pinned: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        throw TeammateNavigationError.notFound
    }
    func setHidden(id: TeammateID, hidden isHidden: Bool, expectedProfileRevision: UInt64) async throws -> Teammate {
        guard var bot = await teamFake.member(id) else { throw TeammateNavigationError.notFound }
        bot.isHidden = isHidden
        await chatFake.setHidden(bot)
        await teamFake.setHidden(bot)
        hidden.removeAll { $0.id == id }
        if isHidden { hidden.append(bot) }
        return bot
    }
    func hiddenTeammates() async throws -> [Teammate] { hidden }
}

private actor TeamWorkspaceReplyFake: ClaudeTextReplyServing {
    private let store: TeamWorkspaceChatFake
    private let names: [TeammateID: String]
    private(set) var submissions: [ClaudeTextTurnSubmission] = []
    private var holdsReplies = false
    private var replyGates: [UUID: CheckedContinuation<ClaudeTextTurnOutcome, Never>] = [:]
    var waitingReplyCount: Int { replyGates.count }
    func holdReplies() { holdsReplies = true }
    func releaseReply(_ id: UUID, outcome: ClaudeTextTurnOutcome) { replyGates.removeValue(forKey: id)?.resume(returning: outcome) }
    func releaseAllReplies() {
        holdsReplies = false
        let gates = Array(replyGates.values)
        replyGates = [:]
        for gate in gates { gate.resume(returning: .stopped) }
    }
    init(store: TeamWorkspaceChatFake, names: [TeammateID: String]) { self.store = store; self.names = names }
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        submissions.append(submission)
        do {
            let user = try await store.saveMessageLocally(conversationID: submission.conversationID, teammateID: submission.teammateID,
                userMessageID: submission.userMessageID, text: submission.text, attachmentIDs: [])
            await onProgress(.userMessageSaved(user))
            var outcome: ClaudeTextTurnOutcome = .completed
            if holdsReplies {
                await onProgress(.stage(.responding))
                await onProgress(.approvalRequired(.init(id: UUID(), runID: RunID(UUID()), requestID: "fixture-card",
                    toolName: "Bash", title: "Move a note", detail: "fixture move", target: "fixture", expiresAt: Date().addingTimeInterval(600))))
                let released = await withCheckedContinuation { replyGates[submission.userMessageID.rawValue] = $0 }
                outcome = Task.isCancelled ? .stopped : released
            }
            let reply = try teamText(submission.conversationID, sequence: user.sequence + 1, author: .teammate(submission.teammateID),
                                     text: "Reply from \(names[submission.teammateID] ?? "?")")
            await store.append(reply)
            await onProgress(.assistantMessageSaved(reply))
            return .init(outcome: outcome, savedUserMessage: user, savedReplyMessage: reply)
        } catch { return .init(outcome: .failed(.persistenceFailed)) }
    }
    private var provenance: [TextTurnMessageProvenance] = []
    func addProvenance(_ record: TextTurnMessageProvenance) { provenance.append(record) }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        provenance.filter { messageIDs.contains($0.messageID) || messageIDs.contains($0.replyMessageID) }
    }
}

@MainActor
private struct TeamWorkspaceHarness {
    let mira: Teammate, ada: Teammate, zed: Teammate
    let miraChat: DurableDirectChatSnapshot, adaChat: DurableDirectChatSnapshot, zedChat: DurableDirectChatSnapshot
    let team: TeamChatSnapshot
    /// A second team the workspace lists but does not have open, so a row's
    /// own menu can be driven against a team that is not the selected one.
    let otherTeam: TeamChatSnapshot?
    let chatService: TeamWorkspaceChatFake
    let teamService: TeamWorkspaceTeamFake
    let replyService: TeamWorkspaceReplyFake
    let archiveService: TeamWorkspaceArchiveFake?
    let navigationService: TeamWorkspaceNavigationFake?
    let workspace: DurableWorkspaceModel

    /// `leadIsActive: false` models an archived lead: the team still names it,
    /// the active roster no longer contains it. `archiving` instead lets the
    /// test archive a bot while this workspace is running.
    /// `activeDirectChats` is how many of Mira, Ada and Zed still have an open
    /// direct chat. One models a workspace whose other bots have been archived,
    /// where a team may no longer be created but must still be editable.
    init(selectTeam: Bool, leadIsActive: Bool = true, archiving: Bool = false, hiding: Bool = false,
         secondTeam: Bool = false, activeDirectChats: Int = 3,
         attachmentDraftFactory: WorkspaceAttachmentCoordinator.Factory? = nil,
         draftService: (any ConversationDraftServing)? = nil,
         profileService: (any TeammateProfileEditing)? = nil,
         deletionService: (any TeammateDeleting)? = nil) throws {
        mira = try teamBot(1, name: "Mira", role: "Research lead")
        ada = try teamBot(2, name: "Ada", role: "Source verifier")
        zed = try teamBot(3, name: "Zed", role: "Outsider")
        func chat(_ bot: Teammate) throws -> DurableDirectChatSnapshot {
            DurableDirectChatSnapshot(teammate: bot, conversation: try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: bot.id),
                title: bot.profile.displayName, createdAt: bot.createdAt, updatedAt: bot.updatedAt))
        }
        miraChat = try chat(mira); adaChat = try chat(ada); zedChat = try chat(zed)
        let date = Date(timeIntervalSince1970: 1_781_600_000)
        let teamEntity = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id], createdAt: date, updatedAt: date)
        let teamConversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: teamEntity.id), title: "QA Team", createdAt: date, updatedAt: date)
        team = TeamChatSnapshot(team: teamEntity, conversation: teamConversation,
                                members: leadIsActive ? [ada, mira] : [ada])
        let history = [try teamText(teamConversation.id, sequence: 1, author: .user, text: "Welcome"),
                       try teamText(teamConversation.id, sequence: 2, author: .teammate(ada.id), text: "Ada here")]
        if secondTeam {
            let otherEntity = try Team(id: TeamID(UUID()), name: "Research Team", leadID: ada.id,
                                       memberIDs: [ada.id, zed.id], createdAt: date, updatedAt: date)
            let otherConversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: otherEntity.id),
                                                     title: "Research Team", createdAt: date, updatedAt: date)
            otherTeam = TeamChatSnapshot(team: otherEntity, conversation: otherConversation, members: [ada, zed])
        } else {
            otherTeam = nil
        }
        let selection = SharedSelection(conversationID: selectTeam ? teamConversation.id : miraChat.conversation.id)
        chatService = TeamWorkspaceChatFake(chats: Array([miraChat, adaChat, zedChat].prefix(activeDirectChats)),
            selection: selection, messages: [teamConversation.id: history])
        teamService = TeamWorkspaceTeamFake(teams: [team] + [otherTeam].compactMap { $0 },
                                            selection: selection, members: [mira, ada, zed])
        replyService = TeamWorkspaceReplyFake(store: chatService, names: [mira.id: "Mira", ada.id: "Ada", zed.id: "Zed"])
        archiveService = archiving ? TeamWorkspaceArchiveFake(teamFake: teamService) : nil
        navigationService = hiding ? TeamWorkspaceNavigationFake(chatFake: chatService, teamFake: teamService) : nil
        workspace = Self.makeWorkspace(chatService: chatService, replyService: replyService,
                                       teamService: teamService, archiveService: archiveService,
                                       navigationService: navigationService,
                                       attachmentDraftFactory: attachmentDraftFactory,
                                       draftService: draftService, profileService: profileService,
                                       deletionService: deletionService)
    }

    /// A second workspace over the same fakes: what a relaunch sees.
    static func makeWorkspace(chatService: TeamWorkspaceChatFake, replyService: TeamWorkspaceReplyFake,
                              teamService: TeamWorkspaceTeamFake,
                              archiveService: TeamWorkspaceArchiveFake? = nil,
                              navigationService: TeamWorkspaceNavigationFake? = nil,
                              attachmentDraftFactory: WorkspaceAttachmentCoordinator.Factory? = nil,
                              draftService: (any ConversationDraftServing)? = nil,
                              profileService: (any TeammateProfileEditing)? = nil,
                              deletionService: (any TeammateDeleting)? = nil) -> DurableWorkspaceModel {
        DurableWorkspaceModel(mode: .localOnly, service: chatService, textReplyService: replyService,
            hiringService: TeamWorkspaceHiringUnavailable(), profileService: profileService,
            archiveService: archiveService, navigationService: navigationService, deletionService: deletionService,
            draftService: draftService,
            attachmentDraftFactory: attachmentDraftFactory, teamService: teamService)
    }

    func relaunch() -> DurableWorkspaceModel {
        Self.makeWorkspace(chatService: chatService, replyService: replyService, teamService: teamService)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

/// Records what would reach Notification Center; always authorised.
@MainActor
private final class TeamNotificationClient: BotNotificationClient {
    private(set) var events: [BotNotificationEvent] = []
    func requestAuthorization() async throws -> Bool { true }
    func isAuthorized() async -> Bool { true }
    func deliver(_ event: BotNotificationEvent) async throws { events.append(event) }
    func removePending() {}
}

/// Only the list of bots Delete kept for their team history; nothing here deletes.
private struct DeletedBotsFake: TeammateDeleting {
    struct Unused: Error {}
    let ids: Set<TeammateID>
    func inventory(id: TeammateID) async throws -> TeammateDeleteInventory { throw Unused() }
    func deleteTeammate(id: TeammateID, expectedProfileRevision: UInt64) async throws -> TeammateDeleteInventory { throw Unused() }
    func deletedTeammateIDs() async throws -> Set<TeammateID> { ids }
}

private struct TeamWorkspaceHiringUnavailable: HiringConversationServing {
    struct Unused: Error {}
    func loadOrStart() async throws -> HiringConversationSnapshot { throw Unused() }
    func submit(text: String) async throws -> HiringConversationSnapshot { throw Unused() }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { throw Unused() }
    func cancel() async throws {}
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot { throw Unused() }
}

/// Records every conversation ID the workspace asks an attachment draft
/// factory for, and hands back a durable model whose load always fails —
/// exactly what a real direct-only repository does for a team conversation.
/// A team conversation must never reach this factory at all.
private struct TeamAttachmentFactoryProbeError: Error {}

@MainActor
private final class TeamAttachmentFactoryRecorder {
    private(set) var requestedConversationIDs: [ConversationID] = []

    func factory() -> WorkspaceAttachmentCoordinator.Factory {
        { [weak self] conversationID in
            self?.requestedConversationIDs.append(conversationID)
            return AttachmentDraftModel(
                conversationID: conversationID,
                load: { throw TeamAttachmentFactoryProbeError() },
                importFile: { _, _ in throw TeamAttachmentFactoryProbeError() },
                remove: { _ in throw TeamAttachmentFactoryProbeError() }
            )
        }
    }
}

/// The durable composer draft the shipped app always installs. It stores every
/// conversation's text the way the SQLite repository does, which validates
/// lifecycle only and so accepts a team conversation exactly like a direct one.
private actor TeamWorkspaceDraftStore: ConversationDraftServing {
    private var drafts: [ConversationID: ConversationDraftSnapshot] = [:]
    private(set) var savedTexts: [(ConversationID, String)] = []

    func load(conversationID: ConversationID) -> ConversationDraftSnapshot? { drafts[conversationID] }

    func save(conversationID: ConversationID, text: String, expectedRevision: UInt64) throws -> ConversationDraftSnapshot {
        guard (drafts[conversationID]?.revision ?? 0) == expectedRevision else { throw ConversationDraftError.staleRevision }
        let next = try ConversationDraftSnapshot(conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: Date(timeIntervalSince1970: 1_781_700_000))
        drafts[conversationID] = next
        savedTexts.append((conversationID, text))
        return next
    }
}

/// The direct-chat mirror needs a factory whose load succeeds; the recorder's
/// throwing one leaves `canSubmit` false, which would refuse a direct send for
/// a reason unrelated to this fix.
@MainActor
private final class TeamLoadableAttachmentFactoryRecorder {
    private(set) var requestedConversationIDs: [ConversationID] = []

    func factory() -> WorkspaceAttachmentCoordinator.Factory {
        { [weak self] conversationID in
            self?.requestedConversationIDs.append(conversationID)
            return AttachmentDraftModel(
                conversationID: conversationID,
                load: { AttachmentDraftSnapshot(conversationID: conversationID, revision: 0, attachments: []) },
                importFile: { _, _ in throw TeamAttachmentFactoryProbeError() },
                remove: { _ in AttachmentDraftSnapshot(conversationID: conversationID, revision: 1, attachments: []) }
            )
        }
    }
}

@Suite("Team conversations in the workspace")
@MainActor
struct TeamWorkspaceTests {
    @Test("Steering a team from one member to another retires the old avatar and preserves its other active conversation",
          arguments: [false, true])
    func steeringReconcilesMemberAvatars(preserveOtherConversation: Bool) async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        await h.replyService.holdReplies()
        try await h.workspace.loadInitialWorkspace()
        defer { Task { await h.replyService.releaseAllReplies() } }
        // The motion belongs to the conversation. A team turn
        // moves the member inside the team; the bot's own sidebar row follows
        // its direct chat alone, so a team turn leaves it still.
        func activity(_ bot: Teammate) -> TeammateActivityState? {
            h.workspace.sidebar.rows.first { $0.id == bot.id.rawValue }?.activity
        }
        func teamActivity(_ bot: Teammate) -> TeammateActivityState {
            h.workspace.sidebar.workingActivity(teammateID: bot.id.rawValue,
                                                conversationID: h.team.conversation.id.rawValue)
        }
        func waitForReplies(_ count: Int) async throws {
            for _ in 0..<400 {
                if await h.replyService.waitingReplyCount == count { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Expected \(count) paused reply services")
        }
        var otherMessageID: UUID?
        if preserveOtherConversation {
            h.workspace.sidebar.selection = h.ada.id.rawValue
            try await h.waitUntil { h.workspace.conversation.title == "Ada" && h.workspace.conversation.inputAvailability == .ready }
            h.workspace.conversation.composerText = "Keep this other conversation waiting"
            h.workspace.conversation.sendCurrentText()
            try await waitForReplies(1)
            otherMessageID = try #require(await h.replyService.submissions.first).userMessageID.rawValue
            h.workspace.sidebar.selection = h.team.team.id.rawValue
            try await h.waitUntil { h.workspace.conversation.title == "QA Team" && h.workspace.conversation.inputAvailability == .ready }
        }
        h.workspace.conversation.composerText = "@Ada check these notes"
        h.workspace.conversation.sendCurrentText()
        try await waitForReplies(preserveOtherConversation ? 2 : 1)
        let first = try #require(await h.replyService.submissions.last)
        #expect(first.teammateID == h.ada.id && teamActivity(h.ada) == .waitingForUser)
        #expect(activity(h.ada) == (preserveOtherConversation ? .waitingForUser : .idle),
                "Ada's own row shows only her direct chat, never the team's turn")
        h.workspace.conversation.composerText = "@Mira take over this request"
        h.workspace.conversation.sendCurrentText()
        #expect(h.workspace.conversation.textReplyPhase == .correcting(team: true), "a team correction says the other bots stop here")
        try await h.waitUntil {
            teamActivity(h.ada) == .idle && activity(h.ada) == (preserveOtherConversation ? .waitingForUser : .idle)
        }
        await h.replyService.releaseReply(first.userMessageID.rawValue, outcome: .stopped)
        try await waitForReplies(preserveOtherConversation ? 2 : 1)
        let second = try #require(await h.replyService.submissions.last)
        #expect(second.teammateID == h.mira.id && second.correctsRunningTurn)
        #expect(teamActivity(h.mira) == .waitingForUser)
        #expect(activity(h.mira) == .idle, "Mira works only in the team, so her own row stays still")
        #expect(teamActivity(h.ada) == .idle)
        #expect(activity(h.ada) == (preserveOtherConversation ? .waitingForUser : .idle))
        await h.replyService.releaseReply(second.userMessageID.rawValue, outcome: .completed)
        try await h.waitUntil { h.workspace.conversation.textReplyPhase == .completed && teamActivity(h.mira) == .idle }
        #expect(activity(h.mira) == .idle)
        if let otherMessageID {
            #expect(activity(h.ada) == .waitingForUser)
            await h.replyService.releaseReply(otherMessageID, outcome: .completed)
            try await h.waitUntil { activity(h.ada) == .idle }
        } else { #expect(activity(h.ada) == .idle) }
        try await h.waitUntil { !h.workspace.conversation.hasPendingSubmissions }
    }

    @Test("The sidebar lists the team beside the bots and a saved team selection opens it with its history and roster")
    func loadsTeamRowsAndRestoresSelection() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.sidebar.rows.map(\.name) == ["Mira", "Ada", "Zed"])
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["QA Team"])
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.selectedTeam?.team.id == h.team.team.id)
        #expect(h.workspace.selectedTeammate == nil)
        #expect(h.workspace.conversation.title == "QA Team")
        #expect(h.workspace.conversation.messages.map(\.authorName) == ["You", "Ada"])
        #expect(h.workspace.conversation.inputAvailability == .ready)
        h.workspace.showBotDetails()
        #expect(!h.workspace.isBotDetailsPresented)
    }

    @Test("Selecting the team from a bot chat saves the selection and shows the team conversation")
    func selectingTheTeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "Mira")
        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "QA Team" && h.workspace.conversation.inputAvailability == .ready }
        #expect(await h.teamService.selectedID == h.team.team.id)
        #expect(h.workspace.conversation.messages.count == 2)
    }

    @Test("Unmentioned text goes to the lead and an @mention to that member, each reply attributed to its author")
    func routesToLeadAndMention() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.conversation.composerText = "Summarise the plan"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Mira" } }
        let first = try #require(await h.replyService.submissions.first)
        #expect(first.teammateID == h.mira.id)
        #expect(first.conversationID == h.team.conversation.id)
        try await h.waitUntil { h.workspace.conversation.textReplyPhase?.isBusy != true }

        h.workspace.conversation.composerText = "@Ada check the sources"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Ada" } }
        let second = try #require(await h.replyService.submissions.last)
        #expect(second.teammateID == h.ada.id)
        let replies = h.workspace.conversation.messages.filter { !$0.isFromUser }
        #expect(replies.map(\.authorName) == ["Ada", "Mira", "Ada"])
        #expect(await h.replyService.submissions.count == 2)
    }

    @Test("A team whose lead is no longer active refuses the send instead of handing it to another member")
    func teamWithoutAnActiveLeadRefusesTheSend() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, leadIsActive: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.inputAvailability == .ready)
        h.workspace.conversation.composerText = "hello"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil {
            h.workspace.conversation.messages.contains { if case .failed = $0.delivery { return true }; return false }
        }
        let failed = try #require(h.workspace.conversation.messages.first {
            if case .failed = $0.delivery { return true }; return false
        })
        #expect(failed.delivery == .failed("No active lead can answer in this team. Restore its lead from Archived."))
        #expect(failed.body == "hello")
        #expect(await h.replyService.submissions.isEmpty)
        #expect(await h.chatService.savedTargets.isEmpty)
    }

    @Test("A saved team selection outlives the workspace and is not overtaken by the previously selected bot")
    func teamSelectionSurvivesARelaunch() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "Mira")
        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "QA Team" }
        let relaunched = h.relaunch()
        try await relaunched.loadInitialWorkspace()
        #expect(relaunched.sidebar.selection == h.team.team.id.rawValue)
        #expect(relaunched.selectedTeam?.team.id == h.team.team.id)
        #expect(relaunched.selectedTeammate == nil)
        #expect(relaunched.conversation.title == "QA Team")
    }

    @Test("A saved message from a bot that has left the roster is labelled a former member, not the lead")
    func formerMemberIsNotRelabelledAsTheLead() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        // Paging returns every saved author; the roster holds active members
        // only, so an archived author must never borrow the presenter's name.
        await h.chatService.append(try teamText(h.team.conversation.id, sequence: 3,
                                                author: .teammate(h.zed.id), text: "Zed was here"))
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.messages.map(\.authorName) == ["You", "Ada", "Former member"])
    }

    /// A deleted bot's team words stay under "Deleted bot"; a bot that merely left the
    /// team is still a former member.
    @Test("A saved message from a deleted bot reads Deleted bot, one from a bot that left reads Former member")
    func deletedBotIsNamedDeleted() async throws {
        let deleted = TeammateID(UUID())
        let h = try TeamWorkspaceHarness(selectTeam: true, deletionService: DeletedBotsFake(ids: [deleted]))
        await h.chatService.append(try teamText(h.team.conversation.id, sequence: 3,
                                                author: .teammate(deleted), text: "Pillow was here"))
        await h.chatService.append(try teamText(h.team.conversation.id, sequence: 4,
                                                author: .teammate(h.zed.id), text: "Zed was here"))
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.messages.map(\.authorName) == ["You", "Ada", "Deleted bot", "Former member"])
    }

    @Test("New Team creates the team through the sheet model, lists it and selects it")
    func createsATeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.canCreateTeam)
        h.workspace.beginTeamCreation()
        let creation = try #require(h.workspace.teamCreation)
        #expect(creation.candidates.map(\.name) == ["Ada", "Mira", "Zed"])
        creation.name = "Second Team"
        creation.toggleMember(h.zed.id.rawValue)
        creation.toggleMember(h.ada.id.rawValue)
        #expect(await creation.submit())
        #expect(h.workspace.teamCreation == nil)
        let draft = try #require(await h.teamService.createdDrafts.first)
        #expect(draft.name == "Second Team")
        #expect(draft.leadID == h.zed.id)
        #expect(draft.memberIDs == [h.zed.id, h.ada.id])
        #expect(h.workspace.sidebar.teamRows.map(\.name).contains("Second Team"))
        #expect(h.workspace.selectedTeam?.team.name == "Second Team")
        #expect(h.workspace.conversation.title == "Second Team")
        #expect(h.workspace.conversation.inputAvailability == .ready)
    }

    @Test("Team Settings renames the team in the sidebar row and the open header, and rewrites its roster")
    func editsTheSelectedTeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.canEditSelectedTeam)
        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        #expect(editor.mode == .edit)
        #expect(editor.title == "Team Settings")
        #expect(editor.submitTitle == "Save Changes")
        #expect(editor.submitIdentifier == "team-save")
        #expect(editor.name == "QA Team")
        #expect(editor.selectedMemberIDs == [h.mira.id.rawValue, h.ada.id.rawValue])
        #expect(editor.leadID == h.mira.id.rawValue)

        editor.name = "  Research Team "
        editor.toggleMember(h.zed.id.rawValue)
        editor.toggleMember(h.ada.id.rawValue)
        #expect(await editor.submit())
        #expect(h.workspace.teamEditor == nil)

        let edit = try #require(await h.teamService.edits.last)
        #expect(edit.teamID == h.team.team.id)
        #expect(edit.name == "Research Team")
        #expect(edit.leadID == h.mira.id)
        #expect(edit.memberIDs == [h.mira.id, h.zed.id])
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["Research Team"])
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")
        #expect(h.workspace.conversation.title == "Research Team")
        #expect(h.workspace.selectedTeam?.team.name == "Research Team")
        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Mira", "Zed"])
    }

    /// A hidden bot
    /// keeps its seat and shows in its teams. Hide takes its own row out of
    /// the sidebar and nothing out of the team.
    @Test("A hidden member keeps its face, its name, its turn and its checkbox in the team, and no row in the sidebar")
    func hiddenMemberKeepsItsSeat() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, hiding: true)
        try await h.workspace.loadInitialWorkspace()
        let ada = h.ada.id.rawValue, mira = h.mira.id.rawValue, room = h.team.conversation.id.rawValue
        await h.workspace.hideBot(id: ada)
        func seated(_ workspace: DurableWorkspaceModel) throws {
            let sidebar = workspace.sidebar
            #expect(!sidebar.rows.contains { $0.id == ada }, "Hide still tidies the sidebar")
            let team = try #require(sidebar.teamRows.first)
            #expect(team.memberSummary == "Lead: Mira · 2 members")
            // The faces on the team row, the header, the composer and beside
            // her messages all come from these live rows.
            #expect(TeamRosterAvatarPolicy.rows(for: team, from: sidebar.teamMemberRowModels).map(\.id) == [ada, mira])
            #expect(workspace.teamHiddenMembers.map(\.id) == [ada])
            #expect(workspace.teamMemberSettingsTargets.map(\.id) == [mira], "Her settings open from Hidden Bots, not from here")
        }
        try seated(h.workspace)

        // Her turn moves her face on this team's surfaces,
        // and her reply there notifies by her own preference.
        // A fixed name: macOS keeps a file per suite name in ~/Library/Preferences.
        let suite = "TeamHiddenMemberNotifications"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "openbots.notifications.enabled")
        let client = TeamNotificationClient()
        let notifications = BotNotificationModel(defaults: defaults, client: client)
        h.workspace.notifications = notifications
        await h.replyService.holdReplies()
        h.workspace.conversation.composerText = "@Ada check these notes"
        h.workspace.conversation.sendCurrentText()
        for _ in 0..<400 where await h.replyService.waitingReplyCount != 1 { try await Task.sleep(for: .milliseconds(5)) }
        let asked = try #require(await h.replyService.submissions.last)
        #expect(asked.teammateID == h.ada.id)
        #expect(h.workspace.sidebar.workingActivity(teammateID: ada, conversationID: room) == .waitingForUser)
        await h.replyService.releaseReply(asked.userMessageID.rawValue, outcome: .completed)
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Ada" } }
        try await h.waitUntil { h.workspace.conversation.textReplyPhase?.isBusy != true }
        #expect(h.workspace.sidebar.workingActivity(teammateID: ada, conversationID: room) == .idle)
        try await h.waitUntil { client.events.contains { $0.conversationID == room && $0.kind == .reply } }

        // Team Settings shows her checked, and a save keeps her.
        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        #expect(editor.candidates.contains { $0.id == ada })
        #expect(editor.isSelected(ada))
        editor.name = "QA Crew"
        #expect(await editor.submit())
        #expect(await h.teamService.edits.last?.memberIDs == [h.mira.id, h.ada.id])
        #expect(h.workspace.selectedTeam?.members.map(\.id) == [h.ada.id, h.mira.id])

        // A relaunch reads the same seat from the saved state.
        let relaunched = h.relaunch()
        defer { relaunched.finishShutdown() }
        try await relaunched.loadInitialWorkspace()
        try seated(relaunched)

        // Unhide brings her row back once: the sidebar and the team share it.
        let hidden = try #require(h.workspace.hiddenModel?.hiddenBots.first)
        await h.workspace.unhideBot(hidden)
        #expect(h.workspace.sidebar.rows.filter { $0.id == ada }.count == 1)
        #expect(h.workspace.sidebar.teamMemberRowModels.filter { $0.id == ada }.count == 1)
        #expect(h.workspace.teamHiddenMembers.isEmpty)
        #expect(h.workspace.teamMemberSettingsTargets.map(\.id) == [ada, mira])
    }

    @Test("A bot added to the team answers its own @mention in the same conversation")
    func addedMemberAnswersItsMention() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        // Zed is not a member yet, so its name is not a mention and the lead
        // takes the message.
        h.workspace.conversation.composerText = "@Zed take a look"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Mira" } }
        #expect(await h.replyService.submissions.first?.teammateID == h.mira.id)
        try await h.waitUntil { h.workspace.conversation.textReplyPhase?.isBusy != true }

        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        editor.toggleMember(h.zed.id.rawValue)
        #expect(await editor.submit())
        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Ada", "Mira", "Zed"])

        h.workspace.conversation.composerText = "@Zed take a look"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Zed" } }
        #expect(await h.replyService.submissions.last?.teammateID == h.zed.id)
        #expect(await h.replyService.submissions.last?.conversationID == h.team.conversation.id)
    }

    @Test("Changing the lead changes who answers a message that names nobody")
    func changingTheLeadChangesTheAnswerer() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        editor.leadID = h.ada.id.rawValue
        #expect(await editor.submit())
        #expect(await h.teamService.edits.last?.leadID == h.ada.id)
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Ada · 2 members")

        h.workspace.conversation.composerText = "Summarise the plan"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Ada" } }
        #expect(await h.replyService.submissions.last?.teammateID == h.ada.id)
    }

    @Test("An edit down to one member, or with a lead outside the members, never reaches the service")
    func invalidEditsAreNotSubmittable() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)

        editor.toggleMember(h.ada.id.rawValue)
        #expect(editor.selectedMemberIDs == [h.mira.id.rawValue])
        #expect(!editor.canSubmit)
        #expect(!(await editor.submit()))

        editor.toggleMember(h.ada.id.rawValue)
        editor.leadID = h.zed.id.rawValue
        #expect(!editor.canSubmit)
        #expect(!(await editor.submit()))

        #expect(await h.teamService.edits.isEmpty)
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["QA Team"])
        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Ada", "Mira"])
    }

    @Test("A refused save keeps the sheet open, says nothing changed, and leaves the team as it was")
    func refusedSaveChangesNothing() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        await h.teamService.failNextEdit(TeamChatError.teamUnavailable(h.team.team.id))
        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        editor.name = "Research Team"
        editor.toggleMember(h.zed.id.rawValue)
        #expect(!(await editor.submit()))
        #expect(editor.submissionError == "OpenBots couldn’t save these changes. The team is unchanged.")
        #expect(h.workspace.teamEditor === editor)
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["QA Team"])
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")
        #expect(h.workspace.conversation.title == "QA Team")
        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Ada", "Mira"])
    }

    @Test("A save refused because someone else changed the team re-reads it, so the reopened editor shows their roster and saves against their instant")
    func aRefusedSaveReopensOnTheRosterThatExists() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        let openedAt = h.team.team.updatedAt
        h.workspace.beginTeamEditing()
        let stale = try #require(h.workspace.teamEditor)
        #expect(stale.name == "QA Team")
        #expect(stale.selectedMemberIDs == [h.mira.id.rawValue, h.ada.id.rawValue])

        // Someone else publishes a different roster while this sheet stands
        // open. The write compares against the instant the sheet was opened on
        // and refuses this save rather than losing theirs.
        let publishedAt = Date(timeIntervalSince1970: 1_781_700_000)
        try await h.teamService.publishFromAnotherWriter(teamID: h.team.team.id, name: "Docs Team",
            leadID: h.mira.id, memberIDs: [h.mira.id, h.zed.id], at: publishedAt)
        await h.teamService.failNextEdit(TeamChatError.teamChangedElsewhere(h.team.team.id))
        stale.name = "Research Team"
        #expect(!(await stale.submit()))
        #expect(stale.submissionError?.contains("close and reopen the editor") == true)
        #expect(!stale.canSubmit)

        // The refusal re-read the team, which is what makes that message true:
        // the sidebar, and the sheet the user opens next, show what exists.
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["Docs Team"])
        h.workspace.dismissTeamEditing()
        h.workspace.beginTeamEditing()
        let reopened = try #require(h.workspace.teamEditor)
        #expect(reopened !== stale)
        #expect(reopened.name == "Docs Team")
        #expect(reopened.selectedMemberIDs == [h.mira.id.rawValue, h.zed.id.rawValue])
        #expect(reopened.canSubmit, "the refusal belonged to the sheet that was refused, not to this one")

        // And it carries their instant, so this save is judged against the
        // roster it was actually seeded from and lands.
        reopened.name = "Research Team"
        #expect(await reopened.submit())
        #expect(await h.teamService.edits.first?.expectedUpdatedAt == openedAt)
        #expect(await h.teamService.edits.last?.expectedUpdatedAt == publishedAt)
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["Research Team"])
        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Mira", "Zed"])
    }

    @Test("Team Settings needs a selected team and never replaces an unfinished New Team sheet")
    func editingNeedsASelectedTeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.canCreateTeam)
        #expect(!h.workspace.canEditSelectedTeam)
        h.workspace.beginTeamEditing()
        #expect(h.workspace.teamEditor == nil)

        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "QA Team" }
        #expect(h.workspace.canEditSelectedTeam)
        h.workspace.beginTeamCreation()
        h.workspace.beginTeamEditing()
        #expect(h.workspace.teamEditor == nil)
        h.workspace.dismissTeamCreation()
        h.workspace.beginTeamEditing()
        #expect(h.workspace.teamEditor?.mode == .edit)
        h.workspace.dismissTeamEditing()
        #expect(h.workspace.teamEditor == nil)
    }

    @Test("Team Settings on a row that is not the open team edits that team and leaves the open one alone")
    func editsATeamThatIsNotTheSelectedOne() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, secondTeam: true)
        try await h.workspace.loadInitialWorkspace()
        let other = try #require(h.otherTeam)
        #expect(h.workspace.selectedTeam?.team.id == h.team.team.id)

        h.workspace.beginTeamEditing(teamID: other.team.id.rawValue)
        let editor = try #require(h.workspace.teamEditor)
        // The sheet is seeded from the row the menu was opened on, not from
        // whichever team happens to be selected.
        #expect(editor.mode == .edit)
        #expect(editor.name == "Research Team")
        #expect(editor.selectedMemberIDs == [h.ada.id.rawValue, h.zed.id.rawValue])
        #expect(editor.leadID == h.ada.id.rawValue)
        // Editing a row must not navigate: QA Team is still the open one.
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.selectedTeam?.team.id == h.team.team.id)
        #expect(h.workspace.conversation.title == "QA Team")

        editor.name = "Research Crew"
        #expect(await editor.submit())
        #expect(await h.teamService.edits.last?.teamID == other.team.id)
        #expect(h.workspace.sidebar.teamRows.first { $0.id == other.team.id.rawValue }?.name == "Research Crew")
        #expect(h.workspace.sidebar.teamRows.first { $0.id == h.team.team.id.rawValue }?.name == "QA Team")
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.conversation.title == "QA Team")
    }

    @Test("A workspace down to one bot can still open its team's settings, and the sheet refuses the save")
    func aTeamStaysEditableWithOneActiveBotLeft() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, activeDirectChats: 1)
        try await h.workspace.loadInitialWorkspace()
        // Creating a team needs two bots to put in it; editing the team that
        // already exists does not.
        #expect(!h.workspace.canCreateTeam)
        #expect(h.workspace.canEditSelectedTeam)

        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        #expect(editor.name == "QA Team")
        // Only Mira can be drawn as a checkbox, so the roster the sheet can
        // submit is one member short of a team and the save waits.
        #expect(editor.candidates.map(\.name) == ["Mira"])
        #expect(editor.selectedMemberIDs == [h.mira.id.rawValue])
        #expect(!editor.canSubmit)
        editor.name = "Research Team"
        #expect(!(await editor.submit()))
        #expect(await h.teamService.edits.isEmpty)
        #expect(h.workspace.sidebar.teamRows.map(\.name) == ["QA Team"])
    }

    @Test("A memory-qualified reply is credited to the member whose run wrote it, not to OpenBots alone")
    func memoryQualifiedReplyKeepsItsMemberAttribution() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        // The memory rules store a qualified reply app-authored: the row has no
        // author teammate at all, so only the run still names who answered.
        let user = try teamText(h.team.conversation.id, sequence: 3, author: .user, text: "What do you remember?")
        let reply = try teamText(h.team.conversation.id, sequence: 4, author: .system,
                                 text: "I may have this wrong: you prefer quiet libraries.")
        await h.chatService.append(user)
        await h.chatService.append(reply)
        await h.replyService.addProvenance(TextTurnMessageProvenance(messageID: user.id, replyMessageID: reply.id,
            runID: RunID(UUID()), teammateID: h.mira.id, state: .succeeded, inputState: .acknowledged))
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.messages.map(\.authorName)
            == ["You", "Ada", "You", "OpenBots · for Mira"])
        let attributed = try #require(h.workspace.conversation.messages.last)
        #expect(attributed.deliveryNotice == "Claude reply saved")
        #expect(attributed.body == "I may have this wrong: you prefer quiet libraries.")
    }

    @Test("Archiving the lead while the app runs updates the team roster and refuses the next send with the real reason")
    func archivingTheLeadRefreshesTheOpenTeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, archiving: true)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")

        await h.workspace.archiveBot(id: h.mira.id.rawValue)
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: — · 1 member")

        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "QA Team" && h.workspace.conversation.inputAvailability == .ready }
        h.workspace.conversation.composerText = "hello"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil {
            h.workspace.conversation.messages.contains { if case .failed = $0.delivery { return true }; return false }
        }
        let failed = try #require(h.workspace.conversation.messages.first {
            if case .failed = $0.delivery { return true }; return false
        })
        #expect(failed.delivery == .failed("No active lead can answer in this team. Restore its lead from Archived."))
        #expect(await h.replyService.submissions.isEmpty)

        // Restoring puts the lead back into the open conversation, and the
        // re-present keeps the rows the page cannot contain.
        await h.workspace.restoreBot(h.mira)
        #expect(h.workspace.sidebar.teamRows.first?.memberSummary == "Lead: Mira · 2 members")
        #expect(h.workspace.conversation.messages.contains { $0.body == "hello" })
        #expect(h.workspace.conversation.title == "QA Team")
    }

    @Test("A team conversation never reaches the direct-only attachment draft factory and keeps Send enabled; a bot conversation still gets its own draft")
    func teamConversationSkipsTheAttachmentDraft() async throws {
        let recorder = TeamAttachmentFactoryRecorder()
        let h = try TeamWorkspaceHarness(selectTeam: true, attachmentDraftFactory: recorder.factory())
        // Captured before any conversation is shown, so this is exactly the
        // private `unscopedAttachmentDraft` instance the workspace starts with.
        let unscopedDraft = h.workspace.attachmentDraft
        try await h.workspace.loadInitialWorkspace()

        #expect(recorder.requestedConversationIDs.isEmpty)
        #expect(h.workspace.attachmentDraft === unscopedDraft)
        #expect(h.workspace.attachmentDraft.isDurable == false)
        #expect(h.workspace.attachmentDraft.loadState == .ready)
        #expect(h.workspace.conversation.attachmentSubmissionAllowed)
        #expect(!h.workspace.conversation.hasAttachmentContent)
        // Attaching is withdrawn in a team; sending text is not.
        #expect(!h.workspace.conversation.attachmentsAvailable)
        h.workspace.conversation.composerText = "hello team"
        #expect(h.workspace.conversation.canSend)

        h.workspace.sidebar.selection = h.mira.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "Mira" && h.workspace.conversation.inputAvailability == .ready }
        #expect(recorder.requestedConversationIDs.contains(h.miraChat.conversation.id))
        #expect(h.workspace.conversation.attachmentsAvailable)
    }

    /// The attach affordance is a SwiftUI menu item, so its gate is asserted
    /// against the view source the way the other composer affordances are.
    @Test("Attachments are unavailable in a team and available in a bot chat, and the attach control reads that flag")
    func attachmentsAreWithdrawnInATeam() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true, attachmentDraftFactory: TeamAttachmentFactoryRecorder().factory())
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "QA Team")
        #expect(!h.workspace.conversation.attachmentsAvailable)

        h.workspace.sidebar.selection = h.mira.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "Mira" && h.workspace.conversation.inputAvailability == .ready }
        #expect(h.workspace.conversation.attachmentsAvailable)

        // Returning to the team withdraws it again rather than leaving the
        // bot chat's answer behind.
        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "QA Team" && h.workspace.conversation.inputAvailability == .ready }
        #expect(!h.workspace.conversation.attachmentsAvailable)

        let rootSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenBotsUI/OpenBotsRootView.swift"), encoding: .utf8)
        #expect(rootSource.contains("|| !conversation.attachmentsAvailable"))
        #expect(rootSource.contains("guard let attachmentDraft, conversation.attachmentsAvailable else { return }"))
    }

    /// The shipped app always installs both a draft service and an attachment
    /// draft factory; the earlier team tests installed neither, which is why an
    /// enabled Send button did nothing in the installed build and nothing here
    /// caught it. This is that app's wiring.
    @Test("With the app's draft service and attachment factory installed, a team send reaches the reply service and its reply appears")
    func teamSendWithBothCoordinatorsInstalled() async throws {
        let recorder = TeamAttachmentFactoryRecorder()
        let drafts = TeamWorkspaceDraftStore()
        let h = try TeamWorkspaceHarness(selectTeam: true, attachmentDraftFactory: recorder.factory(), draftService: drafts)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "QA Team")

        h.workspace.conversation.composerText = "hello"
        try await h.waitUntil { h.workspace.conversation.canSend }
        h.workspace.conversation.sendCurrentText()

        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Mira" } }
        let submissions = await h.replyService.submissions
        #expect(submissions.map(\.text) == ["hello"])
        #expect(submissions.first?.conversationID == h.team.conversation.id)
        #expect(submissions.first?.teammateID == h.mira.id)
        #expect(h.workspace.conversation.messages.contains { $0.body == "hello" })
        #expect(h.workspace.conversation.messages.contains { if case .failed = $0.delivery { return true }; return false } == false)

        // The composer draft is durable for a team exactly as for a bot, and
        // the direct-only attachment draft was never built for the team.
        let saved = await drafts.savedTexts
        #expect(saved.contains { $0.0 == h.team.conversation.id && $0.1 == "hello" })
        #expect(recorder.requestedConversationIDs.isEmpty)
        #expect(!h.workspace.conversation.attachmentsAvailable)
    }

    @Test("A bot conversation still sends through both the attachment draft and the durable composer draft")
    func directSendStillUsesBothCoordinators() async throws {
        let recorder = TeamLoadableAttachmentFactoryRecorder()
        let drafts = TeamWorkspaceDraftStore()
        let h = try TeamWorkspaceHarness(selectTeam: false, attachmentDraftFactory: recorder.factory(), draftService: drafts)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "Mira")
        #expect(recorder.requestedConversationIDs == [h.miraChat.conversation.id])

        h.workspace.conversation.composerText = "direct hello"
        try await h.waitUntil { h.workspace.conversation.canSend }
        h.workspace.conversation.sendCurrentText()

        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.body == "Reply from Mira" } }
        let submissions = await h.replyService.submissions
        #expect(submissions.map(\.text) == ["direct hello"])
        #expect(submissions.first?.conversationID == h.miraChat.conversation.id)
        let saved = await drafts.savedTexts
        #expect(saved.contains { $0.0 == h.miraChat.conversation.id && $0.1 == "direct hello" })
        #expect(h.workspace.conversation.attachmentsAvailable)
    }
}

/// Enough of the profile service to prove which bot an editor was opened for.
/// Nothing in these tests loads or saves a profile.
private actor TeamMemberProfileFake: TeammateProfileEditing {
    private let bots: [TeammateID: Teammate]
    private(set) var loads: [TeammateID] = []
    init(bots: [Teammate]) { self.bots = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) }) }

    func loadProfile(teammateID: TeammateID) async throws -> Teammate {
        loads.append(teammateID)
        guard let bot = bots[teammateID] else { throw RepositoryError.notFound(entity: "teammate", id: teammateID.rawValue.uuidString) }
        return bot
    }

    func saveProfile(teammateID: TeammateID, expectedRevision: UInt64,
                     draft: TeammateProfileEditDraft) async throws -> Teammate {
        throw RepositoryError.unavailable(reason: "unused")
    }
}

@Suite("A member's own settings from inside the team")
@MainActor
struct TeamMemberSettingsTests {
    @Test("Opening a member's settings targets that member, not the lead, and leaves the selection and the conversation alone")
    func opensTheMemberNotTheLead() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.conversation.composerText = "unsent team draft"
        // Ada is a member; Mira is the lead. The header offers both.
        #expect(h.workspace.teamMemberSettingsTargets.map(\.name) == ["Ada", "Mira"])

        h.workspace.showMemberDetails(id: h.ada.id.rawValue)

        #expect(h.workspace.isBotDetailsPresented)
        #expect(h.workspace.detailsTeammate?.id == h.ada.id)
        #expect(h.workspace.detailsTeammate?.id != h.mira.id)
        #expect(h.workspace.memberDetailsTargetID == h.ada.id.rawValue)
        // The sidebar, the open conversation and its unsent draft are untouched.
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.selectedTeammate == nil)
        #expect(h.workspace.selectedTeam?.team.id == h.team.team.id)
        #expect(h.workspace.conversation.conversationID == h.team.conversation.id.rawValue)
        #expect(h.workspace.conversation.title == "QA Team")
        #expect(h.workspace.conversation.composerText == "unsent team draft")
        #expect(await h.teamService.selectedID == h.team.team.id)

        // The lead is one click away in the same pane, without navigating.
        h.workspace.showMemberDetails(id: h.mira.id.rawValue)
        #expect(h.workspace.detailsTeammate?.id == h.mira.id)
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.conversation.conversationID == h.team.conversation.id.rawValue)
    }

    @Test("A member's pane shows the open team chat's live lines, and a bot's own chat shows its own")
    func memberPaneShowsTheTeamChatActivity() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.detailsActivityConversation == nil, "no pane, nothing to show")

        // A member and the lead, opened from inside the team: both read the team chat.
        h.workspace.showMemberDetails(id: h.ada.id.rawValue)
        let forAda = try #require(h.workspace.detailsActivityConversation)
        #expect(forAda === h.workspace.conversation)
        #expect(forAda.conversationID == h.team.conversation.id.rawValue)
        #expect(h.workspace.detailsActivityIsTeamChat, "the pane says the lines are the team's")
        h.workspace.showMemberDetails(id: h.mira.id.rawValue)
        #expect(h.workspace.detailsActivityConversation?.conversationID == h.team.conversation.id.rawValue)

        // Zed's own chat: Zed's own conversation, never the team's.
        h.workspace.sidebar.selection = h.zed.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "Zed" && h.workspace.conversation.inputAvailability == .ready }
        #expect(h.workspace.detailsTeammate?.id == h.zed.id)
        let forZed = try #require(h.workspace.detailsActivityConversation)
        #expect(forZed.conversationID != h.team.conversation.id.rawValue)
        #expect(forZed.title == "Zed")
        #expect(!h.workspace.detailsActivityIsTeamChat)
    }

    @Test("The member pane edits that member's own profile, and archiving and exporting stay on the bot's own chat")
    func editsThatMembersProfile() async throws {
        let profiles = TeamMemberProfileFake(bots: [])
        let h = try TeamWorkspaceHarness(selectTeam: true, profileService: profiles)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.showMemberDetails(id: h.ada.id.rawValue)

        // The selection-derived route stays exactly as it was on a team.
        #expect(!h.workspace.canEditSelectedProfile)
        #expect(h.workspace.canEditDetailsProfile)
        h.workspace.editDetailsProfile()
        #expect(h.workspace.profileEditor?.teammateID == h.ada.id)
        #expect(h.workspace.isBotDetailsPresented)
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.conversation.conversationID == h.team.conversation.id.rawValue)
        // Both act on the selection, which this pane deliberately never moves.
        #expect(!h.workspace.canArchiveSelectedBot)
        #expect(!h.workspace.supportsExport)

        h.workspace.returnToDetails()
        #expect(h.workspace.profileEditor == nil)
        #expect(h.workspace.isBotDetailsPresented)
        #expect(h.workspace.detailsTeammate?.id == h.ada.id)

        h.workspace.closeBotDetails()
        #expect(!h.workspace.isBotDetailsPresented)
        #expect(h.workspace.memberDetailsTargetID == nil)
        #expect(h.workspace.detailsTeammate == nil)
        #expect(await profiles.loads.isEmpty)
    }

    @Test("The control exists for every active member and not for a bot that has left the roster")
    func onlyActiveMembersAreOffered() async throws {
        // An archived lead: the team still names Mira, the active roster does not.
        let h = try TeamWorkspaceHarness(selectTeam: true, leadIsActive: false)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.teamMemberSettingsTargets.map(\.name) == ["Ada"])
        #expect(h.workspace.canOpenMemberDetails(id: h.ada.id.rawValue))
        #expect(!h.workspace.canOpenMemberDetails(id: h.mira.id.rawValue))
        // Zed is an active bot that belongs to no team, so the team offers it
        // no control either.
        #expect(!h.workspace.canOpenMemberDetails(id: h.zed.id.rawValue))

        h.workspace.showMemberDetails(id: h.mira.id.rawValue)
        #expect(!h.workspace.isBotDetailsPresented)
        #expect(h.workspace.memberDetailsTargetID == nil)
        #expect(h.workspace.detailsTeammate == nil)
    }

    @Test("A member removed from the roster while its settings are open loses the pane instead of showing a stale bot")
    func removingTheOpenMemberClosesThePane() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.showMemberDetails(id: h.ada.id.rawValue)
        #expect(h.workspace.detailsTeammate?.id == h.ada.id)

        h.workspace.beginTeamEditing()
        let editor = try #require(h.workspace.teamEditor)
        editor.toggleMember(h.zed.id.rawValue)
        editor.toggleMember(h.ada.id.rawValue)
        #expect(await editor.submit())

        #expect(h.workspace.selectedTeam?.members.map(\.profile.displayName) == ["Mira", "Zed"])
        #expect(h.workspace.teamMemberSettingsTargets.map(\.name) == ["Mira", "Zed"])
        #expect(h.workspace.detailsTeammate == nil)
        #expect(!h.workspace.isBotDetailsPresented)
        #expect(h.workspace.memberDetailsTargetID == nil)
        // Ada is still an active bot with its own chat; only the team lost it.
        #expect(h.workspace.sidebar.rows.map(\.name) == ["Mira", "Ada", "Zed"])
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
    }

    @Test("Navigating away from the team ends the member pane rather than pointing it at the next bot")
    func navigationEndsTheMemberPane() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.showMemberDetails(id: h.ada.id.rawValue)
        #expect(h.workspace.detailsTeammate?.id == h.ada.id)

        h.workspace.sidebar.selection = h.zed.id.rawValue
        try await h.waitUntil { h.workspace.conversation.title == "Zed" && h.workspace.conversation.inputAvailability == .ready }
        #expect(h.workspace.memberDetailsTargetID == nil)
        // The pane follows the selection again, exactly as it did before.
        #expect(h.workspace.detailsTeammate?.id == h.zed.id)
        #expect(h.workspace.teamMemberSettingsTargets.isEmpty)
    }

    @Test("The team editor's Settings closes that sheet and opens the member's pane; a bot outside the roster gets no such route")
    func opensFromTheTeamEditorSheet() async throws {
        let h = try TeamWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace()
        h.workspace.beginTeamEditing()
        #expect(h.workspace.teamEditor != nil)

        // Zed is a candidate in that sheet but not a member, so the sheet
        // never offers a control that would lead nowhere.
        h.workspace.openMemberDetailsFromTeamEditor(id: h.zed.id.rawValue)
        #expect(h.workspace.teamEditor != nil)
        #expect(!h.workspace.isBotDetailsPresented)

        h.workspace.openMemberDetailsFromTeamEditor(id: h.ada.id.rawValue)
        #expect(h.workspace.teamEditor == nil)
        #expect(h.workspace.isBotDetailsPresented)
        #expect(h.workspace.detailsTeammate?.id == h.ada.id)
        #expect(h.workspace.sidebar.selection == h.team.team.id.rawValue)
        #expect(h.workspace.conversation.conversationID == h.team.conversation.id.rawValue)
    }

    @Test("A bot's own chat keeps the details pane it always had")
    func directChatDetailsAreUnchanged() async throws {
        let profiles = TeamMemberProfileFake(bots: [])
        let h = try TeamWorkspaceHarness(selectTeam: false, profileService: profiles)
        try await h.workspace.loadInitialWorkspace()
        #expect(h.workspace.conversation.title == "Mira")
        #expect(h.workspace.teamMemberSettingsTargets.isEmpty)

        h.workspace.showBotDetails()
        #expect(h.workspace.isBotDetailsPresented)
        #expect(h.workspace.memberDetailsTargetID == nil)
        #expect(h.workspace.detailsTeammate?.id == h.mira.id)
        #expect(h.workspace.canEditSelectedProfile)
        #expect(h.workspace.canEditDetailsProfile)
        h.workspace.editDetailsProfile()
        #expect(h.workspace.profileEditor?.teammateID == h.mira.id)
    }
}
