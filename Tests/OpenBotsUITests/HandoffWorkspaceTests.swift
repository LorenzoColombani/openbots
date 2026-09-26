import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private func handoffTeamBot(_ n: UInt8, name: String, role: String) throws -> Teammate {
    let id = UUID(uuidString: String(format: "c6000000-0000-0000-0000-%012d", n))!
    let date = Date(timeIntervalSince1970: 1_781_300_000 + Double(n))
    return try Teammate(id: TeammateID(id), profile: TeammateProfile(displayName: name, role: role),
        appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: UInt64(n), silhouette: "soft-arch",
            paletteToken: "violet-coral", eyeDialect: "round-alert", nonColorIdentityCue: "brow notch \(n)",
            accessibleIdentityDescription: "Violet creature with brow notch \(n)"),
        createdAt: date, updatedAt: date)
}

private func handoffTeamText(_ conversationID: ConversationID, sequence: Int64, author: MessageAuthor, text: String,
                             outputClass: OutputClass = .conversation) throws -> Message {
    let date = Date(timeIntervalSince1970: 1_781_400_000 + Double(sequence))
    return try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence, author: author,
        outputClass: outputClass, deliveryState: .completed,
        parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
        createdAt: date, updatedAt: date)
}

/// Production writes one `chat_navigation_state` singleton, so a team
/// selection overwrites a bot selection and the direct-chat query then reports
/// none. The fakes share this box rather than each keeping a private answer.
private actor HandoffSharedSelection {
    private(set) var conversationID: ConversationID?
    init(conversationID: ConversationID?) { self.conversationID = conversationID }
    func set(_ id: ConversationID?) { conversationID = id }
}

private actor HandoffWorkspaceChatFake: DurableTeammateChatServing {
    private var chats: [DurableDirectChatSnapshot]
    private let selection: HandoffSharedSelection
    private(set) var messages: [ConversationID: [Message]]

    init(chats: [DurableDirectChatSnapshot], selection: HandoffSharedSelection, messages: [ConversationID: [Message]]) {
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
    /// Honours `beforeSequence` and `limit` the way the SQLite keyset page
    /// does, so a paging test can actually reach a second page.
    func loadMessages(conversationID: ConversationID, beforeSequence: Int64?, limit: Int) async throws -> DurableMessagePageSnapshot {
        let all = (messages[conversationID] ?? []).sorted { $0.sequence < $1.sequence }
        let older = beforeSequence.map { bound in all.filter { $0.sequence < bound } } ?? all
        let page = Array(older.suffix(limit))
        return DurableMessagePageSnapshot(conversationID: conversationID, messages: page,
                                          hasMore: older.count > page.count, nextBeforeSequence: page.first?.sequence)
    }
    func saveMessageLocally(conversationID: ConversationID, teammateID: TeammateID, userMessageID: MessageID,
                            text: String, attachmentIDs: [AttachmentID]) async throws -> Message {
        let sequence = Int64((messages[conversationID] ?? []).count + 1)
        let message = try Message(id: userMessageID, conversationID: conversationID, sequence: sequence, author: .user,
            deliveryState: .completed, parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: Date(), updatedAt: Date())
        messages[conversationID, default: []].append(message)
        return message
    }
    func append(_ message: Message) { messages[message.conversationID, default: []].append(message) }
    func lastSequence(_ conversationID: ConversationID) -> Int64 { messages[conversationID]?.last?.sequence ?? 0 }
    func messageCount(_ conversationID: ConversationID) -> Int { messages[conversationID]?.count ?? 0 }
    func sendMessageToLocalFixture(conversationID: ConversationID, teammateID: TeammateID,
                                   userMessageID: MessageID, text: String) async throws -> DurableLocalFixtureExchangeSnapshot {
        throw DurableTeammateChatError.reviewFixtureUnavailable
    }
}

private actor HandoffWorkspaceTeamFake: TeamChatServing {
    private(set) var teams: [TeamChatSnapshot]
    private let selection: HandoffSharedSelection
    private let members: [Teammate]
    init(teams: [TeamChatSnapshot], selection: HandoffSharedSelection, members: [Teammate]) {
        self.teams = teams; self.selection = selection; self.members = members
    }
    func activeTeamChats() async throws -> [TeamChatSnapshot] { teams }
    func selectedTeamChat() async throws -> TeamChatSnapshot? {
        guard let id = await selection.conversationID else { return nil }
        return teams.first { $0.conversation.id == id }
    }
    func select(teamID: TeamID) async throws {
        guard let chat = teams.first(where: { $0.team.id == teamID }) else { throw TeamChatError.teamUnavailable(teamID) }
        await selection.set(chat.conversation.id)
    }
    func createTeamChat(_ draft: TeamChatDraft) async throws -> TeamChatSnapshot {
        throw TeamChatError.teamUnavailable(TeamID(UUID()))
    }
    func updateTeamChat(_ edit: TeamChatEdit) async throws -> TeamChatSnapshot {
        throw TeamChatError.teamUnavailable(edit.teamID)
    }
    func teamChat(conversationID: ConversationID) async throws -> TeamChatSnapshot? { teams.first { $0.conversation.id == conversationID } }
}

/// The staged handoffs a team conversation holds. `records` answers newest
/// first, exactly as `SQLiteHandoffRepository` orders `created_at DESC`, so a
/// workspace that assumes the opposite renders several cards backwards.
private actor HandoffWorkspaceHandoffFake: HandoffServing {
    private(set) var staged: [HandoffRecord] = []
    private(set) var declined: [HandoffID] = []
    private var failNextDecline = false

    func stage(_ record: HandoffRecord) { staged.append(record) }
    func record(id: HandoffID) -> HandoffRecord? { staged.first { $0.id == id } }
    func replace(_ record: HandoffRecord) {
        guard let index = staged.firstIndex(where: { $0.id == record.id }) else { return }
        staged[index] = record
    }
    func failNextDecline(_ fail: Bool) { failNextDecline = fail }

    func records(conversationID: ConversationID) async throws -> [HandoffRecord] {
        staged.filter { $0.conversationID == conversationID }
            .sorted { $0.handoff.provenance.createdAt > $1.handoff.provenance.createdAt }
    }

    @discardableResult
    func decline(id: HandoffID) async throws -> HandoffRecord {
        if failNextDecline { failNextDecline = false; throw HandoffServiceError.unknownHandoff }
        guard var record = staged.first(where: { $0.id == id }) else { throw HandoffServiceError.unknownHandoff }
        guard record.state == .staged || record.state == .accepted else {
            throw HandoffServiceError.notDeclinable(record.state)
        }
        try record.apply(.requireRecovery(HandoffRecovery(code: "declined",
            userMessage: "Not sent. The lead can hand this off again.", isRecoverable: false,
            occurredAt: record.handoff.provenance.createdAt.addingTimeInterval(60))))
        replace(record)
        declined.append(id)
        return record
    }
}

/// What the service writes on a leg that started and then did not finish. The
/// workspace decides what to do by the record's state, never by this wording,
/// so the tests assert the card shows whatever the record carries.
private let handoffLegFailureMessage = "The lead can hand this off again."
private let handoffReportFailureMessage = "The lead could not compile the member's answer. The lead can hand this off again."

/// The lead's own reply plus the member's leg. The leg saves the rendered
/// brief as the sender's message and the answer as the receiver's, exactly as
/// the shipped service does, so attribution is what the transcript shows.
/// A leg can fail in the three ways that matter to the card: `refuseNextLeg`
/// turns it away before acceptance, leaving the record staged and untouched;
/// `stopNextLegAfterAccept` gives up between the accept and the durable turn,
/// leaving it `accepted` with nothing saved; `failNextLeg` dies after the brief
/// was saved, moving it to `needsRecovery`.
private actor HandoffWorkspaceReplyFake: ClaudeTextReplyServing {
    private let store: HandoffWorkspaceChatFake
    private let handoffs: HandoffWorkspaceHandoffFake
    private let roster: [TeammateID: Teammate]
    private(set) var submissions: [ClaudeTextTurnSubmission] = []
    private(set) var legSubmissions: [HandoffLegSubmission] = []
    private(set) var reportSubmissions: [HandoffReportSubmission] = []
    private var failNextLeg = false
    private var failNextReport = false
    private var refuseNextLeg = false
    private var stopNextLegAfterAccept = false
    private var legHold: LegHoldPoint?
    private var legHeld = false
    private var replyHeld = false
    private var stageOnNextReply: [HandoffRecord] = []
    private var workersOnNextReply: [TeammateWorker] = []
    private(set) var wakeSubmissions: [WorkerResultSubmission] = []
    private var stageOnNextReport: HandoffRecord?
    private var reportHeld = false

    /// Where `holdLeg` parks a leg. Before its accept the record still reads
    /// as staged, so only the workspace's own guards stand between a reload
    /// and a second start; after the brief the transcript shows the brief's
    /// own notice.
    enum LegHoldPoint { case beforeAccept, afterBrief }

    init(store: HandoffWorkspaceChatFake, handoffs: HandoffWorkspaceHandoffFake, roster: [TeammateID: Teammate]) {
        self.store = store; self.handoffs = handoffs; self.roster = roster
    }

    func failNextLeg(_ fail: Bool) { failNextLeg = fail }
    /// The lead's report turn dies after the member's report was saved: the
    /// shipped service then moves the record to `needsRecovery`, and so does
    /// this, with the same message.
    func failNextReport(_ fail: Bool) { failNextReport = fail }
    /// The lead's next reply carried a fence: the service stages the records
    /// inside that same turn, anchored on the reply it saves, before the
    /// workspace hears the turn finished.
    func stageOnNextReply(_ records: [HandoffRecord]) { stageOnNextReply = records }
    /// The lead's next reply also started these workers.
    func startWorkersOnNextReply(_ workers: [TeammateWorker]) { workersOnNextReply = workers }
    func stageOnNextReport(_ record: HandoffRecord) { stageOnNextReport = record }
    func holdReport() { reportHeld = true }
    func releaseReport() { reportHeld = false }
    /// Turned away before acceptance: nothing is saved and the record is left
    /// exactly as the card already shows it.
    func refuseNextLeg(_ refuse: Bool) { refuseNextLeg = refuse }
    /// Stop, or a CLI that is no longer ready, between the accept and the
    /// durable turn: the record moves to `accepted` and no message is written.
    func stopNextLegAfterAccept(_ stop: Bool) { stopNextLegAfterAccept = stop }
    /// Parks the next leg at `point` until `releaseLeg`. A refusal honours a
    /// hold before the accept too, so a test can read the reload that
    /// dispatched a leg before the refusal changes what that reload drew.
    func holdLeg(at point: LegHoldPoint) { legHold = point; legHeld = true }
    func releaseLeg() { legHeld = false }
    /// Parks the lead's next turn inside the service until `releaseReply`, so
    /// a test can press Stop while that turn is genuinely in flight. The turn
    /// then finishes and stages its briefs anyway: a service that does not
    /// notice the cancellation is the shape the workspace has to survive.
    func holdReply() { replyHeld = true }
    func releaseReply() { replyHeld = false }
    private func awaitRelease(at point: LegHoldPoint) async {
        guard legHold == point else { return }
        while legHeld { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        submissions.append(submission)
        while replyHeld { try? await Task.sleep(for: .milliseconds(2)) }
        do {
            let user = try await store.saveMessageLocally(conversationID: submission.conversationID, teammateID: submission.teammateID,
                userMessageID: submission.userMessageID, text: submission.text, attachmentIDs: [])
            await onProgress(.userMessageSaved(user))
            let reply = try handoffTeamText(submission.conversationID, sequence: user.sequence + 1, author: .teammate(submission.teammateID),
                text: "Reply from \(roster[submission.teammateID]?.profile.displayName ?? "?")")
            await store.append(reply)
            await onProgress(.assistantMessageSaved(reply))
            // The shipped service anchors what it stages on the reply it just
            // saved, and so does this: a brief's source is the turn that wrote it.
            for staging in stageOnNextReply {
                await handoffs.stage(HandoffRecord(handoff: staging.handoff, sourceMessageID: reply.id))
            }
            stageOnNextReply = []
            if !workersOnNextReply.isEmpty { await onProgress(.workersStarted(workersOnNextReply)) }
            workersOnNextReply = []
            return .init(outcome: .completed, savedUserMessage: user, savedReplyMessage: reply)
        } catch { return .init(outcome: .failed(.persistenceFailed)) }
    }

    /// A worker's wake: the holder answers the room once.
    func sendWorkerResult(_ submission: WorkerResultSubmission,
                          onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        wakeSubmissions.append(submission)
        do {
            let conversationID = submission.worker.conversationID
            let last = await store.lastSequence(conversationID)
            let note = try handoffTeamText(conversationID, sequence: last + 1, author: .system, text: "[From OpenBots] worker result")
            await store.append(note)
            let reply = try handoffTeamText(conversationID, sequence: last + 2, author: .teammate(submission.worker.holderID),
                text: "Worker summary from \(roster[submission.worker.holderID]?.profile.displayName ?? "?")")
            await store.append(reply)
            await onProgress(.assistantMessageSaved(reply))
            return .init(outcome: .completed, savedReplyMessage: reply)
        } catch { return .init(outcome: .failed(.persistenceFailed)) }
    }

    func sendHandoffLeg(_ submission: HandoffLegSubmission,
                        onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        legSubmissions.append(submission)
        await awaitRelease(at: .beforeAccept)
        if refuseNextLeg { refuseNextLeg = false; return .init(outcome: .failed(.busy)) }
        guard var record = await handoffs.record(id: submission.handoffID),
              let sender = roster[record.senderID], let receiver = roster[record.receiverID] else {
            return .init(outcome: .failed(.invalidInput))
        }
        do {
            let conversationID = record.conversationID
            let base = record.handoff.provenance.createdAt
            await onProgress(.stage(.starting))
            // The service accepts a staged record and leaves an already
            // accepted one alone, so a second click on the same card runs.
            if record.state == .staged {
                try record.apply(.accept(at: base.addingTimeInterval(10)))
                await handoffs.replace(record)
            }
            if stopNextLegAfterAccept {
                stopNextLegAfterAccept = false
                return .init(outcome: .failed(.setupRequired))
            }
            try record.apply(.beginWork(at: base.addingTimeInterval(20)))
            let next = Int64(await store.messageCount(conversationID) + 1)
            // The shipped persistence classes a leg's brief and reply as the
            // work channel, and so does this fake.
            let brief = try handoffTeamText(conversationID, sequence: next, author: .teammate(sender.id),
                text: HandoffFence.renderBrief(record.brief, sender: sender, receiver: receiver), outputClass: .workAudit)
            await store.append(brief)
            await onProgress(.userMessageSaved(brief))
            await awaitRelease(at: .afterBrief)
            await onProgress(.stage(.responding))
            if failNextLeg {
                failNextLeg = false
                record.briefMessageID = brief.id
                try record.apply(.requireRecovery(HandoffRecovery(code: "leg-failed",
                    userMessage: handoffLegFailureMessage, isRecoverable: false,
                    occurredAt: base.addingTimeInterval(25))))
                await handoffs.replace(record)
                return .init(outcome: .failed(.runtimeUnavailable), savedUserMessage: brief)
            }
            let reply = try handoffTeamText(conversationID, sequence: next + 1, author: .teammate(receiver.id),
                text: "Reply from \(receiver.profile.displayName)", outputClass: .workAudit)
            await store.append(reply)
            await onProgress(.assistantMessageSaved(reply))
            try record.apply(.succeed(summary: "Reply from \(receiver.profile.displayName)", at: base.addingTimeInterval(30)))
            record.briefMessageID = brief.id
            record.replyMessageID = reply.id
            await handoffs.replace(record)
            return .init(outcome: .completed, savedUserMessage: brief, savedReplyMessage: reply)
        } catch { return .init(outcome: .failed(.persistenceFailed)) }
    }

    /// The lead compiles a finished leg, the way the shipped service
    /// does: the report is the member's work-channel message, the reply the
    /// lead's for the room, and the record returns to the lead.
    func sendHandoffReport(_ submission: HandoffReportSubmission,
                           onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        reportSubmissions.append(submission)
        while reportHeld { try? await Task.sleep(for: .milliseconds(2)) }
        guard var record = await handoffs.record(id: submission.handoffID), record.state == .succeeded,
              record.replyMessageID != nil, let sender = roster[record.senderID], let receiver = roster[record.receiverID] else {
            return .init(outcome: .failed(.unavailable))
        }
        do {
            let conversationID = record.conversationID
            let base = record.handoff.provenance.createdAt
            await onProgress(.stage(.starting))
            let next = Int64(await store.messageCount(conversationID) + 1)
            let report = try handoffTeamText(conversationID, sequence: next, author: .teammate(receiver.id),
                text: "\(receiver.profile.displayName) reports back on \"\(record.brief.goal)\":\n\nReply from \(receiver.profile.displayName)",
                outputClass: .workAudit)
            await store.append(report)
            await onProgress(.userMessageSaved(report))
            await onProgress(.stage(.responding))
            if failNextReport {
                failNextReport = false
                try record.apply(.requireRecovery(HandoffRecovery(code: "report-failed",
                    userMessage: handoffReportFailureMessage, isRecoverable: false,
                    occurredAt: base.addingTimeInterval(35))))
                await handoffs.replace(record)
                return .init(outcome: .failed(.runtimeUnavailable), savedUserMessage: report)
            }
            let successor = stageOnNextReport
            stageOnNextReport = nil
            let reply = try handoffTeamText(conversationID, sequence: next + 1, author: .teammate(sender.id),
                text: successor == nil ? "Compiled by \(sender.profile.displayName)" : "Internal request for another member",
                outputClass: successor == nil ? .conversation : .workAudit)
            await store.append(reply)
            await onProgress(.assistantMessageSaved(reply))
            if let successor {
                await handoffs.stage(HandoffRecord(handoff: successor.handoff, sourceMessageID: reply.id,
                    chainID: record.chainID, parentHandoffID: record.id, hopCount: record.hopCount + 1,
                    originalUserMessageID: record.originalUserMessageID))
            } else {
                for var member in try await handoffs.records(conversationID: conversationID)
                where member.chainID == record.chainID && member.state == .succeeded {
                    try member.apply(.returnToOrigin(at: max(base, member.handoff.lastTransitionAt).addingTimeInterval(40)))
                    await handoffs.replace(member)
                }
            }
            return .init(outcome: .completed, savedUserMessage: report, savedReplyMessage: reply)
        } catch { return .init(outcome: .failed(.persistenceFailed)) }
    }

    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}

private struct HandoffWorkspaceHiringUnavailable: HiringConversationServing {
    struct Unused: Error {}
    func loadOrStart() async throws -> HiringConversationSnapshot { throw Unused() }
    func submit(text: String) async throws -> HiringConversationSnapshot { throw Unused() }
    func revise(field: HiringCandidateField, value: String) async throws -> HiringConversationSnapshot { throw Unused() }
    func cancel() async throws {}
    func confirm(appearance: AgentAppearance) async throws -> DurableTeammateChatCreationSnapshot { throw Unused() }
}

/// A worker that finishes at once, so its result waits for the chat.
private struct HandoffWorkspaceInstantWorkers: TeammateWorking {
    func spawn(_ submission: TeammateWorkerSubmission) async -> TeammateWorkerOutcome { .refused(.notStarted) }
    func finishReply(_ replyID: UUID) async -> [TeammateWorkerOutcome] { [] }
    func run(_ worker: TeammateWorker) async -> TeammateWorkerResult { .finished("Three summaries.") }
}

@MainActor
private struct HandoffWorkspaceHarness {
    let mira: Teammate, ada: Teammate, stranger: Teammate
    let team: TeamChatSnapshot
    /// A second team of the same two bots, present only when `secondTeam` asks
    /// for it: a chain waiting in one room is what proves a Stop in another
    /// room left it alone.
    let otherTeam: TeamChatSnapshot
    let otherLeadReplyID: MessageID
    let miraChat: DurableDirectChatSnapshot
    let leadReplyID: MessageID
    let userMessageID: MessageID
    let chatService: HandoffWorkspaceChatFake
    let teamService: HandoffWorkspaceTeamFake
    let handoffService: HandoffWorkspaceHandoffFake
    let replyService: HandoffWorkspaceReplyFake
    let workspace: DurableWorkspaceModel

    /// `handoffs: false` is the workspace built without the handoff service:
    /// a team conversation that behaves exactly as it did before handoffs existed.
    init(selectTeam: Bool, handoffs: Bool = true, secondTeam: Bool = false, workers: Bool = false) throws {
        mira = try handoffTeamBot(1, name: "Mira", role: "Research lead")
        ada = try handoffTeamBot(2, name: "Ada", role: "Source verifier")
        stranger = try handoffTeamBot(9, name: "Gone", role: "Former member")
        func chat(_ bot: Teammate) throws -> DurableDirectChatSnapshot {
            DurableDirectChatSnapshot(teammate: bot, conversation: try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: bot.id),
                title: bot.profile.displayName, createdAt: bot.createdAt, updatedAt: bot.updatedAt))
        }
        miraChat = try chat(mira)
        let adaChat = try chat(ada)
        let date = Date(timeIntervalSince1970: 1_781_600_000)
        let teamEntity = try Team(id: TeamID(UUID()), name: "QA Team", leadID: mira.id, memberIDs: [mira.id, ada.id], createdAt: date, updatedAt: date)
        let teamConversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: teamEntity.id), title: "QA Team", createdAt: date, updatedAt: date)
        team = TeamChatSnapshot(team: teamEntity, conversation: teamConversation, members: [ada, mira])
        let history = [try handoffTeamText(teamConversation.id, sequence: 1, author: .user, text: "Haiku please"),
                       try handoffTeamText(teamConversation.id, sequence: 2, author: .teammate(mira.id), text: "Ada, over to you.")]
        userMessageID = history[0].id
        leadReplyID = history[1].id
        let otherEntity = try Team(id: TeamID(UUID()), name: "Docs Team", leadID: mira.id, memberIDs: [mira.id, ada.id],
                                   createdAt: date, updatedAt: date)
        let otherConversation = try Conversation(id: ConversationID(UUID()), kind: .team(teamID: otherEntity.id),
                                                 title: "Docs Team", createdAt: date, updatedAt: date)
        otherTeam = TeamChatSnapshot(team: otherEntity, conversation: otherConversation, members: [ada, mira])
        let otherHistory = [try handoffTeamText(otherConversation.id, sequence: 1, author: .user, text: "Docs please"),
                            try handoffTeamText(otherConversation.id, sequence: 2, author: .teammate(mira.id), text: "Ada, the docs.")]
        otherLeadReplyID = otherHistory[1].id
        let selection = HandoffSharedSelection(conversationID: selectTeam ? teamConversation.id : miraChat.conversation.id)
        var stored = [teamConversation.id: history]
        if secondTeam { stored[otherConversation.id] = otherHistory }
        chatService = HandoffWorkspaceChatFake(chats: [miraChat, adaChat], selection: selection, messages: stored)
        teamService = HandoffWorkspaceTeamFake(teams: secondTeam ? [team, otherTeam] : [team],
                                               selection: selection, members: [mira, ada])
        handoffService = HandoffWorkspaceHandoffFake()
        replyService = HandoffWorkspaceReplyFake(store: chatService, handoffs: handoffService,
                                                 roster: [mira.id: mira, ada.id: ada])
        workspace = DurableWorkspaceModel(mode: .localOnly, service: chatService, textReplyService: replyService,
            hiringService: HandoffWorkspaceHiringUnavailable(), teamService: teamService,
            handoffService: handoffs ? handoffService : nil,
            workerService: workers ? HandoffWorkspaceInstantWorkers() : nil)
    }

    /// Stages the lead's brief for Ada anchored to one of its own replies.
    @discardableResult
    func stageHandoff(after anchor: MessageID, goal: String = "Write a haiku",
                      createdAt: Date = Date(timeIntervalSince1970: 1_781_800_000),
                      in conversation: ConversationID? = nil,
                      receiver: Teammate? = nil) async throws -> HandoffRecord {
        let record = try makeRecord(after: anchor, goal: goal, createdAt: createdAt,
                                    in: conversation, receiver: receiver)
        await handoffService.stage(record)
        return record
    }

    func makeRecord(after anchor: MessageID, goal: String = "Write a haiku",
                    createdAt: Date = Date(timeIntervalSince1970: 1_781_800_000),
                    in conversation: ConversationID? = nil,
                    receiver: Teammate? = nil,
                    handoffID: HandoffID = HandoffID(UUID()),
                    legID: HandoffLegID = HandoffLegID(UUID())) throws -> HandoffRecord {
        let provenance = try HandoffProvenance(handoffID: handoffID, legID: legID,
            originConversationID: conversation ?? team.conversation.id, senderID: mira.id,
            receiverID: (receiver ?? ada).id, createdAt: createdAt)
        let brief = try HandoffBrief(goal: goal, constraints: ["Three lines"], inputReferences: [],
            requestedOutput: "The haiku only", exclusions: [], stopOrApprovalBoundary: "Ask before publishing")
        return HandoffRecord(handoff: Handoff(provenance: provenance, brief: brief), sourceMessageID: anchor)
    }

    /// A card lives on the conversation's record, never in the transcript.
    func card(for record: HandoffRecord) -> ChatHandoffCardSnapshot? {
        workspace.handoffCards.first { $0.id == record.id.rawValue }?.card
    }

    /// Bot-to-bot traffic stays out of the room: neither the lead's brief, nor
    /// the member's reply to it, nor the report the lead compiles from is a
    /// transcript row.
    func transcriptHidesTheLeg() -> Bool {
        !workspace.conversation.messages.contains {
            $0.body.hasPrefix("Handoff from Mira to Ada.") || $0.body == "Reply from Ada" || $0.body.contains("reports back on")
        } && !workspace.conversation.messages.contains { if case .handoffCard = $0.parts.first?.content { return true } else { return false } }
    }

    /// A leg that ran to its end: succeeded, or already compiled by the lead.
    func legFinished(_ record: HandoffRecord) -> Bool {
        guard let state = card(for: record)?.trail.state else { return false }
        return state == .succeeded || state == .returnedToOrigin
    }

    func interaction(for record: HandoffRecord) -> HandoffCardInteractionModel? {
        workspace.cardInteractions?.handoff(messageID: record.id.rawValue,
                                            partID: record.legID.rawValue, cardID: record.id.rawValue)
    }

    /// What the bot's own sidebar row shows. A leg runs in the team, so its
    /// motion never lands here; a leg that ends badly still
    /// marks the row, and one turned away gives back what the row showed.
    func activity(of bot: Teammate) -> TeammateActivityState? {
        workspace.sidebar.rows.first { $0.id == bot.id.rawValue }?.activity
    }

    /// The bot's face inside the team conversation, where a running leg moves.
    func teamActivity(of bot: Teammate) -> TeammateActivityState {
        workspace.sidebar.workingActivity(teammateID: bot.id.rawValue, conversationID: team.conversation.id.rawValue)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    /// The same wait for a condition that has to ask one of the fakes.
    func waitUntilAsync(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 where !(await condition()) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }

    /// Long enough for a dispatch that retried itself to be caught doing it.
    func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }
}
@Suite("Handoffs in the team workspace")
@MainActor
struct HandoffWorkspaceTests {
    @Test("An intermediate lead report dispatches its successor and only the final compile is visible")
    func reportContinuesTheSessionChain() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let first = try h.makeRecord(after: h.leadReplyID)
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the haiku",
            createdAt: first.handoff.provenance.createdAt.addingTimeInterval(100))
        await h.replyService.stageOnNextReply([first])
        await h.replyService.stageOnNextReport(second)
        h.workspace.conversation.composerText = "Write and check the haiku"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.card(for: second)?.trail.state == .returnedToOrigin }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id, second.id])
        #expect(await h.replyService.reportSubmissions.map(\.handoffID) == [first.id, second.id])
        #expect(h.workspace.conversation.messages.filter { $0.body == "Compiled by Mira" }.count == 1)
        #expect(!h.workspace.conversation.messages.contains { $0.body == "Internal request for another member" })
        #expect(h.transcriptHidesTheLeg())
        #expect(h.card(for: first)?.trail.state == .returnedToOrigin)
    }

    @Test("Stop during an intermediate report prevents its saved successor from waking on reload")
    func stoppedReportCannotContinueChain() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let first = try h.makeRecord(after: h.leadReplyID)
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the haiku",
            createdAt: first.handoff.provenance.createdAt.addingTimeInterval(100))
        await h.replyService.stageOnNextReply([first])
        await h.replyService.stageOnNextReport(second)
        await h.replyService.holdReport()
        h.workspace.conversation.composerText = "Write and check the haiku"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.reportSubmissions.count == 1 }
        h.workspace.conversation.stopCurrentTextReply()
        await h.replyService.releaseReport()
        try await h.waitUntil { h.card(for: second)?.control == .send }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id])
        h.workspace.conversation.loadEarlierMessages()
        try await h.settle()
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id])
        #expect(!h.workspace.conversation.messages.contains { $0.body == "Internal request for another member" })
    }

    @Test("A completed lead turn stages a brief and the workspace dispatches it with nothing to click")
    func stagedBriefDispatchesItself() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])

        // The user talks to the lead. Nothing else in this test touches a card.
        h.workspace.conversation.composerText = "Ada should check the sources"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.legFinished(staged) }

        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [staged.id])
        // The member's reply went to the lead, not the room; the lead then
        // compiled it for the user, once, and that is the row the room ends on.
        try await h.waitUntil { h.card(for: staged)?.trail.state == .returnedToOrigin }
        #expect(await h.replyService.reportSubmissions.map(\.handoffID) == [staged.id])
        #expect(h.transcriptHidesTheLeg())
        #expect(h.workspace.conversation.messages.map(\.body).suffix(2) == ["Reply from Mira", "Compiled by Mira"])
        #expect(h.activity(of: h.mira) == .idle && h.activity(of: h.ada) == .idle)
        let card = try #require(h.card(for: staged))
        #expect(card.control == nil && card.trail.resultSummary?.hasPrefix("Reply from Ada") == true)
        #expect(h.interaction(for: staged) == nil)

        // The reservation is genuinely released: the next typed turn is admitted.
        h.workspace.conversation.composerText = "thanks"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 2 }
    }

    /// A worker's result waiting for the room must not take it the moment the
    /// lead's turn ends, or the brief that turn staged is refused and never
    /// sent, and a finished leg's report can be dropped.
    @Test("A worker's result waits for the team's own chain: the brief goes, the member answers, the lead reports, then the lead answers the worker's result")
    func aWorkerResultWaitsForTheTeamsChain() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true, workers: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        await h.replyService.startWorkersOnNextReply([TeammateWorker(id: UUID(), kind: .local, brief: "Sum up the notes",
            holderID: h.mira.id, conversationID: h.team.conversation.id)])
        h.workspace.conversation.composerText = "Ada should check the sources, and sum up the notes"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.card(for: staged)?.trail.state == .returnedToOrigin }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [staged.id])
        #expect(await h.replyService.reportSubmissions.map(\.handoffID) == [staged.id])
        try await h.waitUntilAsync { await h.replyService.wakeSubmissions.count == 1 }
        try await h.waitUntil { h.workspace.conversation.messages.last?.body == "Worker summary from Mira" }
        #expect(h.workspace.conversation.messages.map(\.body).suffix(3) == ["Reply from Mira", "Compiled by Mira", "Worker summary from Mira"])
    }

    @Test("Two briefs staged by one turn go one at a time, oldest first")
    func twoBriefsFromOneTurnGoInOrder() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let first = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku",
                                     createdAt: Date(timeIntervalSince1970: 1_781_800_000))
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources",
                                      createdAt: Date(timeIntervalSince1970: 1_781_800_500))
        await h.replyService.stageOnNextReply([first, second])
        h.workspace.conversation.composerText = "both please"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.legFinished(second) }
        // In order, never side by side: the second only starts once the first
        // has released the conversation.
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id, second.id])
        #expect(h.legFinished(first))
        #expect(h.card(for: first)?.control == nil && h.card(for: second)?.control == nil)
    }

    @Test("A brief already staged when the conversation opens is never woken, and its own control sends it")
    func preexistingStagedBriefWaitsForAPerson() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let staged = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)

        // Nothing runs on display: a pending handoff is not permission to
        // wake work after close.
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)

        // A later turn does not adopt it either: only what that turn staged is
        // the chain the user just started.
        h.workspace.conversation.composerText = "any news?"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 1 }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
        #expect(await h.handoffService.record(id: staged.id)?.state == .staged)

        let card = try #require(h.card(for: staged))
        #expect(card.control == .send && card.controlLabel == "Send to Ada")
        let model = try #require(h.interaction(for: staged))
        model.send()
        try await h.waitUntil { model.state == .sent }
        try await h.waitUntil { h.legFinished(staged) }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [staged.id])
        #expect(h.transcriptHidesTheLeg())
        #expect(h.card(for: staged)?.control == nil)
    }

    @Test("Only what the turn's own reply staged sends itself: not a brief for a member who was away, not one another writer inserted meanwhile")
    func onlyTheTurnsOwnBriefsSendThemselves() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        // Staged for a member who is not in the roster: the record exists, and
        // no card can be drawn for it.
        let away = try await h.stageHandoff(after: h.leadReplyID, goal: "Check the sources",
                                            createdAt: Date(timeIntervalSince1970: 1_781_800_000), receiver: h.stranger)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        #expect(h.card(for: away) == nil)
        // Inserted by another writer after the cards were drawn and before the
        // turn, anchored on history rather than on the reply the turn saves.
        let meanwhile = try await h.stageHandoff(after: h.leadReplyID, goal: "Write a haiku",
                                                 createdAt: Date(timeIntervalSince1970: 1_781_800_500))

        h.workspace.conversation.composerText = "any news?"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 1 }
        try await h.waitUntil { h.card(for: meanwhile) != nil }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
        #expect(h.card(for: meanwhile)?.control == .send)

        // The member comes back — a restore, or a team edit that re-adds her —
        // and the record resolves on the next reload. It is still not this
        // session's to wake.
        await h.handoffService.replace(try h.makeRecord(
            after: h.leadReplyID, goal: "Check the sources",
            createdAt: Date(timeIntervalSince1970: 1_781_800_000), receiver: h.ada,
            handoffID: away.id, legID: away.legID
        ))
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.card(for: away) != nil }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
        #expect(await h.handoffService.record(id: away.id)?.state == .staged)
        #expect(h.card(for: away)?.control == .send)
        #expect(h.card(for: meanwhile)?.control == .send)
    }

    @Test("One reload tells the two staged kinds apart: this turn's brief has no control, the waiting one does")
    func oneReloadTellsTheTwoStagedKindsApart() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let waiting = try await h.stageHandoff(after: h.leadReplyID, goal: "Check the sources",
                                               createdAt: Date(timeIntervalSince1970: 1_781_800_000))
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let fresh = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku",
                                     createdAt: Date(timeIntervalSince1970: 1_781_800_500))
        await h.replyService.stageOnNextReply([fresh])
        // The fresh leg is parked before its accept, so the reload that
        // dispatched it can be read while both records are still staged.
        await h.replyService.holdLeg(at: .beforeAccept)
        h.workspace.conversation.composerText = "go"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.card(for: fresh) != nil }
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }
        try await h.settle()

        #expect(await h.handoffService.record(id: fresh.id)?.state == .staged)
        #expect(await h.handoffService.record(id: waiting.id)?.state == .staged)
        // Same reload, same durable state, different answer.
        #expect(h.card(for: fresh)?.control == nil)
        #expect(h.interaction(for: fresh) == nil)
        #expect(h.card(for: waiting)?.control == .send)
        #expect(h.interaction(for: waiting) != nil)
        // The older brief is the waiting one, and the dispatch still skipped it.
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [fresh.id])

        await h.replyService.releaseLeg()
        try await h.waitUntil { h.legFinished(fresh) }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [fresh.id])
        #expect(h.card(for: waiting)?.control == .send)
    }

    @Test("A staged brief is a card on the record, not a transcript row")
    func cardAppears() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let staged = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let ids = h.workspace.conversation.messages.map(\.id)
        #expect(!ids.contains(staged.id.rawValue))
        #expect(ids == [h.userMessageID.rawValue, h.leadReplyID.rawValue])
        let card = try #require(h.card(for: staged))
        #expect(card.receiverName == "Ada" && card.trail.goal == "Write a haiku")
        // Staged before this session opened the conversation, so it waits.
        #expect(card.control == .send)
        #expect(h.interaction(for: staged) != nil)
    }

    @Test("The transcript's line says who asked whom for what, and holds none of the rest of the brief")
    func collapsedLineHidesTheBrief() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let staged = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let card = try #require(h.card(for: staged))
        #expect(card.summaryLine == "Mira asked Ada — Write a haiku")
        #expect(card.collapsedAccessibilityLabel == "Mira asked Ada for: Write a haiku. Staged.")
        // Everything the old card put in the timeline is still recorded; the
        // line the transcript shows carries none of it until it is opened.
        #expect(!card.summaryLine.contains("The haiku only"))
        #expect(!card.summaryLine.contains("Ask before publishing"))
        #expect(!card.summaryLine.contains("Three lines"))
        #expect(card.trail.requestedOutput == "The haiku only")
        #expect(card.trail.stopOrApprovalBoundary == "Ask before publishing")
        #expect(card.trail.timeline.map(\.summary) == ["Brief staged by the lead"])
    }

    @Test("Two handoffs staged on one reply are listed oldest first on the record, and neither is woken")
    func twoCardsOnOneAnchorRenderOldestFirst() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let first = try await h.stageHandoff(after: h.leadReplyID, goal: "Write a haiku",
                                             createdAt: Date(timeIntervalSince1970: 1_781_800_000))
        let second = try await h.stageHandoff(after: h.leadReplyID, goal: "Check the sources",
                                              createdAt: Date(timeIntervalSince1970: 1_781_800_500))
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        #expect(h.workspace.handoffCards.map(\.id) == [first.id.rawValue, second.id.rawValue])
        #expect(h.transcriptHidesTheLeg())
        #expect(h.card(for: first)?.trail.goal == "Write a haiku")
        #expect(h.card(for: second)?.trail.goal == "Check the sources")
        // Both predate this session, so both wait and neither ran.
        try await h.settle()
        #expect(h.card(for: first)?.control == .send && h.card(for: second)?.control == .send)
        #expect(await h.replyService.legSubmissions.isEmpty)
    }

    @Test("A dispatch turned away before its accept hands the brief to a person: Send appears, the member is not marked broken, and no scroll retries it")
    func refusedDispatchHandsTheBriefToAPerson() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        await h.replyService.refuseNextLeg(true)
        h.workspace.conversation.composerText = "over to Ada"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }

        // Nothing was written and the record did not move. The workspace stops
        // being the one that sends it: the card is redrawn with its own Send,
        // the status line keeps the reason, and Ada, who did nothing, is not
        // shown as broken.
        try await h.waitUntil { h.card(for: staged)?.control == .send }
        #expect(await h.handoffService.record(id: staged.id)?.state == .staged)
        #expect(h.card(for: staged)?.trail.state == .staged)
        #expect(h.card(for: staged)?.controlLabel == "Send to Ada")
        #expect(h.interaction(for: staged) != nil)
        #expect(h.workspace.conversation.textReplyPhase == .failed(.busy))
        #expect(h.activity(of: h.ada) == .idle)
        #expect(!h.workspace.conversation.messages.contains { $0.body.hasPrefix("Handoff from Mira to Ada.") })

        // A reload is not a retry: paging leaves the brief where it is.
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
        #expect(h.card(for: staged)?.control == .send)

        // Only a person's press runs the member.
        let model = try #require(h.interaction(for: staged))
        model.send()
        try await h.waitUntil { model.state == .sent }
        try await h.waitUntil { h.legFinished(staged) }
        #expect(await h.replyService.legSubmissions.count == 2)
        #expect(h.transcriptHidesTheLeg())
        #expect(h.card(for: staged)?.control == nil)
        #expect(h.activity(of: h.ada) == .idle)
    }

    @Test("A reload that lands while a leg is running does not start that leg a second time")
    func reloadDuringARunningLegStartsNothing() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        // Parked before its accept: the record still reads as staged, so only
        // the workspace's own guards stand between a reload and a second start.
        await h.replyService.holdLeg(at: .beforeAccept)
        h.workspace.conversation.composerText = "over to Ada"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }
        #expect(await h.handoffService.record(id: staged.id)?.state == .staged)
        #expect(h.teamActivity(of: h.ada) == .thinkingOrWorking)
        #expect(h.activity(of: h.ada) == .idle, "the leg moves Ada inside the team, not on her own row")

        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
        // What that reload drew is still the record of a brief being sent, not
        // a button: a person cannot start it twice either.
        #expect(h.card(for: staged)?.control == nil)
        #expect(h.interaction(for: staged) == nil)

        await h.replyService.releaseLeg()
        try await h.waitUntil { h.legFinished(staged) }
        #expect(await h.replyService.legSubmissions.count == 1)
        #expect(h.transcriptHidesTheLeg())
        #expect(h.activity(of: h.ada) == .idle)
        #expect(h.teamActivity(of: h.ada) == .idle)
    }

    @Test("A control is drawn only while a press could be admitted: a running leg hides Send and Send again, and its end brings them back")
    func controlsWaitWhileTheConversationIsBusy() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        var stalled = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources", createdAt: base)
        try stalled.apply(.accept(at: base.addingTimeInterval(10)))
        await h.handoffService.stage(stalled)
        let waiting = try await h.stageHandoff(after: h.leadReplyID, goal: "Count the lines",
                                               createdAt: base.addingTimeInterval(100))
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        #expect(h.card(for: stalled)?.control == .sendAgain && h.card(for: waiting)?.control == .send)

        let fresh = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku", createdAt: base.addingTimeInterval(500))
        await h.replyService.stageOnNextReply([fresh])
        await h.replyService.holdLeg(at: .afterBrief)
        h.workspace.conversation.composerText = "go"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.teamActivity(of: h.ada) == .thinkingOrWorking }
        #expect(h.activity(of: h.ada) == .idle)
        #expect(h.transcriptHidesTheLeg())

        // A reload landing mid-leg draws the two waiting records as records:
        // a press now could only be refused, so neither promises one.
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.waitUntil { h.card(for: stalled)?.control == nil }
        #expect(h.card(for: waiting)?.control == nil)
        #expect(h.interaction(for: stalled) == nil && h.interaction(for: waiting) == nil)
        #expect(h.card(for: stalled)?.trail.state == .accepted && h.card(for: waiting)?.trail.state == .staged)

        // The leg's end is a reload, and the conversation is free again.
        await h.replyService.releaseLeg()
        try await h.waitUntil { h.legFinished(fresh) }
        #expect(h.card(for: stalled)?.control == .sendAgain && h.card(for: waiting)?.control == .send)
        #expect(h.interaction(for: stalled) != nil && h.interaction(for: waiting) != nil)
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [fresh.id])
    }

    @Test("A leg that stalls after its accept offers Send again, and pressing it runs the member")
    func stalledAfterAcceptOffersSendAgain() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        await h.replyService.stopNextLegAfterAccept(true)
        h.workspace.conversation.composerText = "over to Ada"
        h.workspace.conversation.sendCurrentText()

        // The record moved but nothing was written: the automatic dispatch will
        // not take an accepted record, so this is the one state a person has to
        // push, and the card is rebuilt to say so.
        try await h.waitUntil { h.card(for: staged)?.control == .sendAgain }
        #expect(await h.handoffService.record(id: staged.id)?.state == .accepted)
        #expect(h.card(for: staged)?.controlLabel == "Send again")
        #expect(!h.workspace.conversation.messages.contains { $0.body.hasPrefix("Handoff from Mira to Ada.") })

        let model = try #require(h.interaction(for: staged))
        model.send()
        try await h.waitUntil { model.state == .sent }
        try await h.waitUntil { h.legFinished(staged) }
        #expect(await h.replyService.legSubmissions.count == 2)
        #expect(h.transcriptHidesTheLeg())
        #expect(h.card(for: staged)?.control == nil)
        #expect(h.interaction(for: staged) == nil)
    }

    @Test("A press the service turns away keeps the same card and shows why")
    func refusedPressKeepsTheCard() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let staged = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let model = try #require(h.interaction(for: staged))

        await h.replyService.refuseNextLeg(true)
        model.send()
        try await h.waitUntil { model.state == .failed("Could not send. Try again.") }
        // The record did not move, so the registry still holds this exact model
        // and the view shows its failure over a card that can be pressed again.
        #expect(h.interaction(for: staged) === model)
        #expect(h.card(for: staged)?.control == .send)
        #expect(h.card(for: staged)?.trail.state == .staged)
    }

    @Test("A leg that fails after acceptance rebuilds the card from the record it wrote, and offers nothing")
    func failedLegRebuildsTheCard() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        await h.replyService.failNextLeg(true)
        h.workspace.conversation.composerText = "over to Ada"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntil { h.card(for: staged)?.trail.state == .needsRecovery }
        // A record in recovery cannot be sent again — the reply service admits
        // only a staged or accepted one — so the card promises nothing and the
        // recovery wording is what tells the reader who can move it.
        let card = try #require(h.card(for: staged))
        #expect(card.control == nil && card.controlLabel == nil)
        #expect(card.trail.recoveryMessage == handoffLegFailureMessage)
        #expect(h.interaction(for: staged) == nil)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
    }

    @Test("A report turn that fails leaves the card needing attention with the lead's message, marks the lead, and offers nothing")
    func failedReportRebuildsTheCard() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        let staged = try h.makeRecord(after: h.leadReplyID)
        await h.replyService.stageOnNextReply([staged])
        await h.replyService.failNextReport(true)
        h.workspace.conversation.composerText = "Ada should check the sources"
        h.workspace.conversation.sendCurrentText()
        // The member answered, the lead's compile broke: the record does not
        // read as done, the card says who can move it, and the lead's row
        // shows the failure. Nothing on the card can be pressed.
        try await h.waitUntil { h.card(for: staged)?.trail.state == .needsRecovery }
        #expect(await h.replyService.reportSubmissions.map(\.handoffID) == [staged.id])
        let card = try #require(h.card(for: staged))
        #expect(card.control == nil && card.controlLabel == nil)
        #expect(card.trail.recoveryMessage == handoffReportFailureMessage)
        #expect(card.trail.resultSummary == nil)
        #expect(h.interaction(for: staged) == nil)
        try await h.waitUntil { h.activity(of: h.mira) == .errorOrAttention }
        #expect(h.activity(of: h.ada) == .idle)
        #expect(h.transcriptHidesTheLeg())
        // The reservation is released: the next typed turn is admitted.
        h.workspace.conversation.composerText = "thanks"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 2 }
    }

    @Test("A finished handoff is a record and nothing else: no control in either terminal state")
    func finishedRecordsCarryNoControl() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        var succeeded = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku", createdAt: base)
        try succeeded.apply(.accept(at: base.addingTimeInterval(10)))
        try succeeded.apply(.beginWork(at: base.addingTimeInterval(20)))
        try succeeded.apply(.succeed(summary: "Silent hands", at: base.addingTimeInterval(30)))
        var returned = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources",
                                        createdAt: base.addingTimeInterval(500))
        try returned.apply(.accept(at: base.addingTimeInterval(510)))
        try returned.apply(.beginWork(at: base.addingTimeInterval(520)))
        try returned.apply(.succeed(summary: "Two of three check out", at: base.addingTimeInterval(530)))
        try returned.apply(.returnToOrigin(at: base.addingTimeInterval(540)))
        await h.handoffService.stage(succeeded)
        await h.handoffService.stage(returned)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)

        #expect(h.legFinished(succeeded))
        #expect(h.card(for: succeeded)?.control == nil)
        #expect(h.interaction(for: succeeded) == nil)
        #expect(h.card(for: returned)?.trail.state == .returnedToOrigin)
        #expect(h.card(for: returned)?.control == nil)
        #expect(h.interaction(for: returned) == nil)
        // Neither is staged, so the workspace ran nothing.
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
    }

    @Test("A card whose record stops resolving is removed from the transcript on the next reload")
    func staleCardRowIsRemoved() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let kept = try await h.stageHandoff(after: h.leadReplyID, goal: "Write a haiku",
                                            createdAt: Date(timeIntervalSince1970: 1_781_800_000))
        let lost = try await h.stageHandoff(after: h.leadReplyID, goal: "Check the sources",
                                            createdAt: Date(timeIntervalSince1970: 1_781_800_500))
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        #expect(h.card(for: lost) != nil)

        // The receiver has left the roster: the record no longer resolves.
        await h.handoffService.replace(try h.makeRecord(
            after: h.leadReplyID, goal: "Check the sources",
            createdAt: Date(timeIntervalSince1970: 1_781_800_500), receiver: h.stranger,
            handoffID: lost.id, legID: lost.legID
        ))
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }

        try await h.waitUntil { h.card(for: lost) == nil }
        #expect(!h.workspace.conversation.messages.contains { $0.id == lost.id.rawValue })
        #expect(h.card(for: kept) != nil)
        #expect(await h.replyService.legSubmissions.isEmpty)
    }

    @Test("Paging keeps the cards, brings in one staged since the last reload, and never anchors on a card")
    func pagingKeepsTheCards() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let staged = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        #expect(h.card(for: staged) != nil)
        #expect(h.workspace.conversation.hasEarlierMessages)

        // The card is not a row, so the latest anchor is the lead's reply.
        #expect(h.workspace.conversation.messages.last?.id == h.leadReplyID.rawValue)
        h.workspace.conversation.focusLatestMessage()
        #expect(h.workspace.conversation.latestFocus?.messageID == h.leadReplyID.rawValue)

        // Staged after the load, anchored on the message the earlier page
        // holds: nothing has reloaded the cards yet, so it is not shown.
        let later = try await h.stageHandoff(after: h.userMessageID, goal: "Check the sources",
                                             createdAt: Date(timeIntervalSince1970: 1_781_800_500))
        #expect(h.card(for: later) == nil)

        // Paging reloads them, which is the only reason the new one appears.
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.waitUntil { h.card(for: later) != nil }
        #expect(h.card(for: later)?.trail.goal == "Check the sources")
        #expect(h.card(for: staged) != nil)
        // Paging is not a turn, so it woke neither: both still wait for a press.
        #expect(h.card(for: later)?.control == .send && h.card(for: staged)?.control == .send)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
    }

    @Test("A card whose anchor is older than the loaded page is on the record all the same")
    func cardAnchoredOffThePageOpensAtTheTop() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        // Anchored on the first user message, which one page of one does not
        // reach, and older than everything that page holds.
        let old = try await h.stageHandoff(after: h.userMessageID,
                                           createdAt: Date(timeIntervalSince1970: 1_781_400_001))
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let ids = h.workspace.conversation.messages.map(\.id)
        #expect(ids == [h.leadReplyID.rawValue])
        #expect(h.workspace.handoffCards.map(\.id) == [old.id.rawValue])
        // It is a record wherever it landed, and still the user's to send.
        #expect(h.card(for: old)?.control == .send)
        #expect(h.interaction(for: old) != nil)
    }

    @Test("A direct chat shows no cards and a workspace without the handoff service is unchanged")
    func directChatsAndAbsence() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: false)
        // Staged on the direct conversation itself, so the record filter cannot
        // be what hides it: the rule under test is that direct chats show none.
        let direct = try await h.stageHandoff(after: h.leadReplyID, in: h.miraChat.conversation.id)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        #expect(h.workspace.conversation.conversationID == h.miraChat.conversation.id.rawValue)
        #expect(h.card(for: direct) == nil)
        #expect(h.interaction(for: direct) == nil)
        #expect(!h.workspace.conversation.messages.contains { if case .handoffCard = $0.parts.first?.content { return true } else { return false } })
        // Nothing dispatches out of a direct chat either.
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)

        let plain = try HandoffWorkspaceHarness(selectTeam: true, handoffs: false)
        let unused = try await plain.stageHandoff(after: plain.leadReplyID)
        try await plain.workspace.loadInitialWorkspace(messageLimit: 20)
        #expect(plain.card(for: unused) == nil)
        #expect(!plain.workspace.conversation.messages.contains { if case .handoffCard = $0.parts.first?.content { return true } else { return false } })
        try await plain.settle()
        #expect(await plain.replyService.legSubmissions.isEmpty)
    }

    @Test("Stop ends the whole chain: the stopped leg keeps its own control and the brief behind it waits for a person")
    func stopEndsTheWholeChain() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        let first = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku", createdAt: base)
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources",
                                      createdAt: base.addingTimeInterval(500))
        await h.replyService.stageOnNextReply([first, second])
        // Parked before its accept, so the user presses Stop on a leg that is
        // genuinely running; it then gives up after accepting and writes
        // nothing, which is the state a person has to push again.
        await h.replyService.holdLeg(at: .beforeAccept)
        await h.replyService.stopNextLegAfterAccept(true)
        h.workspace.conversation.composerText = "both please"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }

        h.workspace.conversation.stopCurrentTextReply()
        await h.replyService.releaseLeg()

        // The stopped leg keeps the handling its own record earned.
        try await h.waitUntil { h.card(for: first)?.control == .sendAgain }
        #expect(await h.handoffService.record(id: first.id)?.state == .accepted)
        // The brief behind it never started, and is a person's to send.
        #expect(h.card(for: second)?.control == .send)
        #expect(h.card(for: second)?.controlLabel == "Send to Ada")
        #expect(await h.handoffService.record(id: second.id)?.state == .staged)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
        #expect(h.workspace.conversation.textReplyPhase?.isBusy != true, "a stopped leg ends stopped, never stuck stopping")

        // A page and a full redraw are the two reloads a team edit also ends
        // in. Neither is a retry.
        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)
        #expect(h.card(for: second)?.control == .send)

        // Only a person's press runs the member.
        let model = try #require(h.interaction(for: second))
        model.send()
        try await h.waitUntil { model.state == .sent }
        try await h.waitUntil { h.legFinished(second) }
        #expect(await h.replyService.legSubmissions.count == 2)
        #expect(h.transcriptHidesTheLeg())
    }

    @Test("Stopping the lead's own turn leaves nothing that dispatches itself afterwards")
    func stoppingTheLeadsTurnEndsTheChainItWasWriting() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        let first = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku", createdAt: base)
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources",
                                      createdAt: base.addingTimeInterval(500))
        await h.replyService.stageOnNextReply([first, second])
        // The lead's turn is parked inside the service, so Stop lands while it
        // is still answering. It then finishes and stages both briefs anyway:
        // what ends the chain is the Stop, not how the turn happened to end.
        await h.replyService.holdReply()
        h.workspace.conversation.composerText = "Ada, twice"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 1 }
        h.workspace.conversation.stopCurrentTextReply()
        await h.replyService.releaseReply()

        // Both briefs are on the board as records a person can send, and the
        // member the lead named was never claimed.
        try await h.waitUntil { h.card(for: first)?.control == .send }
        #expect(h.card(for: second)?.control == .send)
        #expect(h.card(for: first)?.controlLabel == "Send to Ada")
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)
        #expect(h.activity(of: h.ada) == .idle)

        h.workspace.conversation.loadEarlierMessages()
        try await h.waitUntil { h.workspace.conversation.messages.contains { $0.id == h.userMessageID.rawValue } }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.isEmpty)

        // A person's press still runs the member, one leg at a time.
        let model = try #require(h.interaction(for: first))
        model.send()
        try await h.waitUntil { h.legFinished(first) }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id])
        #expect(h.card(for: second)?.control == .send)
    }

    @Test("A Stop in one team conversation leaves another team's waiting chain alone")
    func stopEndsOnlyTheChainOfTheRoomItWasPressedIn() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true, secondTeam: true)
        try await h.workspace.loadInitialWorkspace(messageLimit: 1)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        let first = try h.makeRecord(after: h.leadReplyID, goal: "Write a haiku", createdAt: base)
        let second = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources",
                                      createdAt: base.addingTimeInterval(500))
        await h.replyService.stageOnNextReply([first, second])
        await h.replyService.holdLeg(at: .beforeAccept)
        h.workspace.conversation.composerText = "both please"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }

        // The user leaves the QA team mid-chain, so its second brief is left
        // waiting: the leg's own end reloads nothing while another room is on
        // screen.
        h.workspace.sidebar.selection = h.otherTeam.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.conversationID == h.otherTeam.conversation.id.rawValue }
        await h.replyService.releaseLeg()
        // The leg ends, and the lead compiles it whichever room is on screen:
        // the record is succeeded or, a moment later, returned.
        try await h.waitUntilAsync {
            let state = await h.handoffService.record(id: first.id)?.state
            return state == .succeeded || state == .returnedToOrigin
        }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)

        // A turn in the Docs team is stopped. Its own brief waits for a person.
        let docs = try h.makeRecord(after: h.otherLeadReplyID, goal: "Read the docs",
                                    createdAt: base.addingTimeInterval(900), in: h.otherTeam.conversation.id)
        await h.replyService.stageOnNextReply([docs])
        await h.replyService.holdReply()
        h.workspace.conversation.composerText = "Ada, the docs"
        h.workspace.conversation.sendCurrentText()
        try await h.waitUntilAsync { await h.replyService.submissions.count == 2 }
        h.workspace.conversation.stopCurrentTextReply()
        await h.replyService.releaseReply()
        try await h.waitUntil { h.card(for: docs)?.control == .send }
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1)

        // The QA team's chain was never this Stop's to end: returning to it
        // sends the brief that was still waiting there.
        h.workspace.sidebar.selection = h.team.team.id.rawValue
        try await h.waitUntil { h.workspace.conversation.conversationID == h.team.conversation.id.rawValue }
        try await h.waitUntil { h.legFinished(second) }
        #expect(await h.replyService.legSubmissions.map(\.handoffID) == [first.id, second.id])
    }
    @Test("A Stop during a leg a person pressed gives that card its Send back when the leg writes nothing")
    func stopDuringAPressedLegBringsTheSendBack() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        // A brief from a session that ended: nothing dispatches it, so its own
        // control is the only way it moves.
        let waiting = try await h.stageHandoff(after: h.leadReplyID)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        #expect(h.card(for: waiting)?.control == .send)
        let model = try #require(h.interaction(for: waiting))

        // Parked before its accept, so Stop lands on a leg that is genuinely
        // running, and the leg is then turned away with the record untouched.
        await h.replyService.holdLeg(at: .beforeAccept)
        await h.replyService.refuseNextLeg(true)
        model.send()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }
        h.workspace.conversation.stopCurrentTextReply()
        // Stop rebuilds the cards while the conversation is still stopping, so
        // the card it draws carries nothing to press.
        try await h.waitUntil { h.card(for: waiting)?.control == nil }

        await h.replyService.releaseLeg()
        // The leg's end is the stopped run's end, and it is what hands the card
        // back its control: no page, no redraw, no other turn.
        try await h.waitUntil { h.card(for: waiting)?.control == .send }
        #expect(h.card(for: waiting)?.controlLabel == "Send to Ada")
        #expect(await h.handoffService.record(id: waiting.id)?.state == .staged)
        #expect(h.activity(of: h.ada) == .idle)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1, "the redraw is not a retry")

        // The control that came back is a working one.
        let redrawn = try #require(h.interaction(for: waiting))
        redrawn.send()
        try await h.waitUntil { h.legFinished(waiting) }
        #expect(await h.replyService.legSubmissions.count == 2)
    }

    @Test("A Stop during a Send again gives that card its Send again back when the leg writes nothing")
    func stopDuringAPressedSendAgainBringsTheControlBack() async throws {
        let h = try HandoffWorkspaceHarness(selectTeam: true)
        let base = Date(timeIntervalSince1970: 1_781_800_000)
        // Accepted and stalled before its durable turn: the state only a person
        // pushes, and the second shape a Stop can catch mid-press.
        var stalled = try h.makeRecord(after: h.leadReplyID, goal: "Check the sources", createdAt: base)
        try stalled.apply(.accept(at: base.addingTimeInterval(10)))
        await h.handoffService.stage(stalled)
        try await h.workspace.loadInitialWorkspace(messageLimit: 20)
        #expect(h.card(for: stalled)?.control == .sendAgain)
        let model = try #require(h.interaction(for: stalled))

        await h.replyService.holdLeg(at: .beforeAccept)
        await h.replyService.stopNextLegAfterAccept(true)
        model.send()
        try await h.waitUntilAsync { await h.replyService.legSubmissions.count == 1 }
        h.workspace.conversation.stopCurrentTextReply()
        try await h.waitUntil { h.card(for: stalled)?.control == nil }

        await h.replyService.releaseLeg()
        try await h.waitUntil { h.card(for: stalled)?.control == .sendAgain }
        #expect(h.card(for: stalled)?.controlLabel == "Send again")
        #expect(await h.handoffService.record(id: stalled.id)?.state == .accepted)
        #expect(h.interaction(for: stalled) != nil)
        try await h.settle()
        #expect(await h.replyService.legSubmissions.count == 1, "the redraw is not a retry")
    }
}
