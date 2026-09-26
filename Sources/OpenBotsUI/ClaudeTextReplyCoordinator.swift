import Foundation
import OpenBotsDomain
import OpenBotsServices

/// Observations are deliberately session-local. A saved choice is never evidence
/// that Claude accepted it, and reopening the app does not invent confirmation.
public struct ClaudeModelRunPresentation: Equatable {
    var requested: String?
    var observedAtStart: String?
    var confirmedRequest: String?
    var confirmedModel: String?
    /// The intensity and context the confirmed reply was requested with (its
    /// saved preferences at that time). Claude reports neither back, so they stay
    /// "requested", never "effective".
    var confirmedEffort: String?
    var confirmedContextWindow: String?
    /// True when the confirmation was read back from the saved turn record
    /// rather than observed in this app session.
    var isFromSavedRecord = false
    /// The Claude Code version the saved turn's init frame named, if it did.
    var claudeCodeVersion: String?
}

public enum ClaudeTextReplyPhase: Equatable, Sendable {
    case sending, responding, saving, stopping, completed, stopped
    /// The person typed over a running turn: the note was picked
    /// up, finished work is kept, and the bot starts again with it. In a
    /// team the chain stops too. Not a Stop, and it does not read as one.
    case correcting(team: Bool)
    case failed(ClaudeTextTurnProblem, refusedFrame: ClaudeTextRefusedFrame? = nil)

    public var isBusy: Bool {
        switch self {
        case .sending, .responding, .saving, .stopping, .correcting: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .sending: "Preparing reply…"
        case .responding: "Receiving response…"
        case .saving: "Saving reply…"
        case .stopping: "Stopping and saving available text…"
        case .correcting(let team): team
            ? "Got your note. The other bots stop here and their finished work is kept."
            : "Got your note. Finished work is kept and the bot starts again with it."
        case .completed: "Reply saved."
        case .stopped: "Stopped. Any saved message and partial reply are kept; nothing will be resent automatically."
        case .failed(let problem, let refusedFrame): Self.explanation(problem, refusedFrame: refusedFrame)
        }
    }

    /// A refused wire is almost always Claude Code updating itself under the
    /// app (every turn once died at the init frame of 2.1.272),
    /// so the sentence names the version and the code instead of hinting at a
    /// breakage in the app.
    public static func explanation(_ problem: ClaudeTextTurnProblem, refusedFrame: ClaudeTextRefusedFrame?) -> String {
        guard problem == .invalidResponse, let refusedFrame else { return explanation(problem) }
        let sender = refusedFrame.claudeCodeVersion.map { "Claude Code \($0)" } ?? "Claude Code"
        return "OpenBots stopped this reply: \(sender) sent something OpenBots does not understand (\(refusedFrame.code.rawValue)). Nothing was resent; your text is kept."
    }

    public static func explanation(_ problem: ClaudeTextTurnProblem) -> String {
        switch problem {
        case .unavailable, .runtimeUnavailable: "Claude could not complete this turn. Saved text is kept; check its connection under Settings → General & Claude Code."
        case .busy: "This bot already has an active or unresolved reply. Nothing was resent."
        case .attachmentsNotSupported: "This reply accepts text only. Keep attachments here, or choose Save Locally."
        case .invalidInput: "This message could not be submitted. Your text is preserved."
        case .modelUnavailable, .effortUnavailable, .contextWindowUnavailable: "Claude could not start this turn with the available execution settings. Your text and saved preferences are kept. This picker does not verify provider settings."
        case .contextTooLarge: "The full bot profile could not fit this request. Nothing was sent or shortened; edit the profile before trying again."
        case .contextUnavailable: "OpenBots could not safely prepare this bot’s saved context. Nothing was sent; your text is kept."
        case .contextChanged: "This bot’s context or access changed. The reply was not confirmed saved; your text is kept and nothing will be resent automatically."
        case .memoryPublicationNotReady: "This reply needs saved memory. Its controlled reply path is not ready yet, so nothing was sent and your text is kept."
        case .memoryAcknowledgementPending: "The memory change is saved, but its confirmation could not be added to this conversation. It has not been undone."
        case .setupRequired: "Claude setup needs attention under Settings → General & Claude Code."
        case .subscriptionNotVerified: "The Claude.ai subscription could not be verified. Check Settings → General & Claude Code."
        case .managedPolicyPresentOrUnknown: "Claude’s required tool-free configuration could not be verified. Nothing was sent."
        case .invalidResponse: "Claude’s response could not be verified. Saved text is kept; no retry will run automatically."
        case .timedOut: "Claude did not finish in time. Saved text is kept; no retry will run automatically."
        case .persistenceFailed: "The reply could not be confirmed saved. Any already-saved messages are kept; do not resend automatically."
        case .turnLimitReached: "Claude used up its rounds of tool calls before it finished this reply. Saved text is kept; no retry will run automatically."
        case .macControlRoundsUsedUp: "The bot used up its rounds on your Mac before it finished this reply. Saved text is kept; no retry will run automatically."
        case .sessionLost: "The bot’s saved session could not be continued, so this message was not answered. Send it again and the bot starts fresh."
        // Not a fault of the app's, so it does not read as one. A refusal
        // reported as "Claude's response could not be verified" would send the
        // person looking for a breakage that was never there.
        case .declined: "The bot decided not to answer this one. Nothing went wrong, your text is kept and nothing will be resent."
        }
    }
}

/// Owns only this app's explicit text requests. Navigation never cancels a turn.
/// Stop cancels the transport task; its result arrives after service cleanup.
@MainActor
final class ClaudeTextReplyCoordinator {
    private let service: any ClaudeTextReplyServing
    private let changed: @MainActor () -> Void
    private var messages: [UUID: UUID] = [:]
    private var phases: [UUID: ClaudeTextReplyPhase] = [:]
    private var contextDisclosures: [UUID: ClaudeContextDisclosure] = [:]
    private var modelPresentations: [UUID: ClaudeModelRunPresentation] = [:]
    private var approvals: [UUID: ClaudeTextApproval] = [:]
    /// The bot's question waiting for the user, per conversation.
    private var questions: [UUID: ClaudeTextQuestion] = [:]
    private var activities: [UUID: String] = [:]
    /// Live watch buffer for the open turn: every activity line kept in order
    /// `activities` remains the newest line for the one-line caption.
    private var activityHistories: [UUID: [String]] = [:]
    private static let maximumActivityHistoryLines = 100
    /// What Control this Mac last saw in the open turn, per conversation (the
    /// screen preview). The user's screen: held here only, never written, and gone
    /// with the turn's activity lines.
    private var screenPictures: [UUID: Data] = [:]
    private var bubbles: [UUID: [String]] = [:]
    private var tasks: [UUID: Task<ClaudeTextTurnResult, Never>] = [:]
    /// A message sent while a turn was running: that turn is stopping, and this
    /// message starts once it has settled, carrying the correction.
    private var superseders: [UUID: UUID] = [:]
    /// The turn a waiting correction replaced, by conversation: the chat goes
    /// back to it if the correction is abandoned before it sends.
    private var superseded: [UUID: UUID] = [:]
    private var closing = false

    init(service: any ClaudeTextReplyServing, changed: @escaping @MainActor () -> Void) {
        self.service = service
        self.changed = changed
    }

    func phase(for conversationID: UUID?) -> ClaudeTextReplyPhase? {
        conversationID.flatMap { phases[$0] }
    }

    func contextDisclosure(for conversationID: UUID?) -> ClaudeContextDisclosure? {
        conversationID.flatMap { contextDisclosures[$0] }
    }

    func modelPresentation(for conversationID: UUID?) -> ClaudeModelRunPresentation? {
        conversationID.flatMap { modelPresentations[$0] }
    }

    /// The card waiting for the user in this conversation, if any.
    func question(for conversationID: UUID?) -> ClaudeTextQuestion? {
        conversationID.flatMap { questions[$0] }
    }

    /// The user's answer to the bot's question, or nil to dismiss it.
    func answerQuestion(_ question: ClaudeTextQuestion, answer: ClaudeTextQuestionAnswer?, conversationID: UUID) async {
        guard !closing, questions[conversationID] == question else { return }
        questions[conversationID] = nil
        changed()
        _ = await service.answerUserQuestion(id: question.id, answer: answer)
    }

    func approval(for conversationID: UUID?) -> ClaudeTextApproval? {
        conversationID.flatMap { approvals[$0] }
    }

    /// The last thing the bot did on the Mac this turn, one short line.
    func activity(for conversationID: UUID?) -> String? {
        conversationID.flatMap { activities[$0] }
    }

    /// Every activity line for the open turn, oldest first — the live watch list.
    func activityHistory(for conversationID: UUID?) -> [String] {
        conversationID.flatMap { activityHistories[$0] } ?? []
    }

    /// The newest picture Control this Mac saw in the open turn, if any.
    func screenPicture(for conversationID: UUID?) -> Data? {
        conversationID.flatMap { screenPictures[$0] }
    }

    private func clearActivity(for conversationID: UUID) {
        activities[conversationID] = nil
        activityHistories[conversationID] = nil
        screenPictures[conversationID] = nil
    }

    private func appendActivity(_ line: String, for conversationID: UUID) {
        activities[conversationID] = line
        var history = activityHistories[conversationID] ?? []
        if history.last != line {
            history.append(line)
            if history.count > Self.maximumActivityHistoryLines {
                history.removeFirst(history.count - Self.maximumActivityHistoryLines)
            }
            activityHistories[conversationID] = history
        }
    }

    /// The reply's settled bubbles for the turn in flight, in order.
    func bubbles(for conversationID: UUID?) -> [String] {
        conversationID.flatMap { bubbles[$0] } ?? []
    }

    /// The user's answer to the card. The service refuses a card that is gone.
    func decideApproval(_ approval: ClaudeTextApproval, allow: Bool, conversationID: UUID) async {
        guard !closing, approvals[conversationID] == approval else { return }
        approvals[conversationID] = nil
        changed()
        _ = await service.decideApproval(id: approval.id, allow: allow)
    }

    /// Choose the File… on a missing-file card. The card stays until the
    /// service takes the file, which resolves it; a file it cannot take leaves
    /// the card up, so the user can choose again or continue without it.
    func replaceMissingFile(_ approval: ClaudeTextApproval, with url: URL, conversationID: UUID) async {
        guard !closing, approvals[conversationID] == approval, approval.asksForMissingFile else { return }
        _ = await service.replaceMissingFile(id: approval.id, with: url)
    }

    /// Approve the card and let the same tool work in the same folder for the
    /// rest of this turn. The service refuses
    /// a card that is gone or carries no such scope.
    func allowApprovalForTurn(_ approval: ClaudeTextApproval, conversationID: UUID) async {
        guard !closing, approvals[conversationID] == approval, approval.turnScopeFolder != nil else { return }
        approvals[conversationID] = nil
        changed()
        _ = await service.allowApprovalForTurn(id: approval.id)
    }

    /// Reads the last saved reply's execution record so Details can name the model
    /// that reply reported even after a relaunch. A turn observed in this session
    /// keeps precedence; a busy conversation is left alone.
    func loadSavedModelStatus(conversationID: UUID) async {
        guard !closing, phases[conversationID]?.isBusy != true,
              modelPresentations[conversationID]?.confirmedModel == nil else { return }
        guard let evidence = try? await service.latestExecutionEvidence(conversationID: ConversationID(conversationID)),
              (try? evidence.validated()) != nil else { return }
        guard !closing, phases[conversationID]?.isBusy != true,
              modelPresentations[conversationID]?.confirmedModel == nil else { return }
        var presentation = modelPresentations[conversationID] ?? .init()
        presentation.isFromSavedRecord = true
        presentation.requested = evidence.request.selection.model
        presentation.observedAtStart = evidence.initializedModel
        presentation.claudeCodeVersion = evidence.claudeCodeVersion
        if let result = evidence.resultModel {
            presentation.confirmedRequest = evidence.request.selection.expectedResolvedModel
            presentation.confirmedModel = result
            presentation.confirmedEffort = evidence.request.selection.effort
            presentation.confirmedContextWindow = evidence.request.selection.contextWindow
        }
        modelPresentations[conversationID] = presentation
        changed()
    }

    /// True when a message reserved for this conversation is a correction to a
    /// turn that was still running.
    /// Whether this reservation still holds its conversation: false once a
    /// message typed during the turn has taken it (`reserve`).
    func holds(conversationID: UUID, messageID: UUID) -> Bool {
        messages[conversationID] == messageID
    }

    func supersedesRunningTurn(conversationID: UUID, messageID: UUID) -> Bool {
        superseders[conversationID] == messageID
    }

    /// The reservation for a turn the app starts itself: a handoff leg, a
    /// report, a worker's wake. It takes only a free chat, and never stops a
    /// running turn the way a message the user types does.
    func reserveIdle(conversationID: UUID, messageID: UUID) -> Bool {
        guard phases[conversationID]?.isBusy != true else { return false }
        return reserve(conversationID: conversationID, messageID: messageID)
    }

    func reserve(conversationID: UUID, messageID: UUID) -> Bool {
        guard !closing else { return false }
        if phases[conversationID]?.isBusy == true {
            // Send stays live while a bot works: the new message stops the
            // running turn (finished work kept) and takes its place.
            guard superseders[conversationID] == nil else { return false }
            superseders[conversationID] = messageID
            superseded[conversationID] = messages[conversationID]
            messages[conversationID] = messageID
            contextDisclosures[conversationID] = nil
            approvals[conversationID] = nil
            questions[conversationID] = nil
            clearActivity(for: conversationID)
            bubbles[conversationID] = nil
            phases[conversationID] = .correcting(team: false)
            tasks[conversationID]?.cancel()
            changed()
            return true
        }
        messages[conversationID] = messageID
        contextDisclosures[conversationID] = nil
        modelPresentations[conversationID]?.requested = nil
        modelPresentations[conversationID]?.observedAtStart = nil
        approvals[conversationID] = nil
        questions[conversationID] = nil
        clearActivity(for: conversationID)
        bubbles[conversationID] = nil
        phases[conversationID] = .sending
        changed()
        return true
    }

    /// The correction landed in a team: the chain stops with the turn, and the
    /// caption says so.
    func markTeamCorrection(conversationID: UUID) {
        guard case .correcting = phases[conversationID] else { return }
        phases[conversationID] = .correcting(team: true)
        changed()
    }

    func abandon(conversationID: UUID, messageID: UUID) {
        guard messages[conversationID] == messageID else {
            releaseReplacedTurn(conversationID: conversationID, messageID: messageID)
            return
        }
        if superseders[conversationID] == messageID {
            // The correction never started, but it already stopped the turn it
            // was replacing (left "correcting", the chat would refuse every
            // later message). A replaced turn still running gets
            // the chat back, so its own end frees it; one already ended leaves
            // nothing to wait for, so the chat is free now.
            superseders[conversationID] = nil
            if let replaced = superseded.removeValue(forKey: conversationID) {
                messages[conversationID] = replaced
                phases[conversationID] = .stopping
                changed()
            } else if tasks[conversationID] != nil {
                // A stopped turn is still winding down (a Stop came first): the
                // chat stays stopping, and that turn's end frees it (`settle`).
                messages[conversationID] = nil
                phases[conversationID] = .stopping
                changed()
            } else {
                messages[conversationID] = nil
                phases[conversationID] = .stopped
                changed()
                conversationFreed?(conversationID)
            }
            return
        }
        guard tasks[conversationID] == nil else { return }
        messages[conversationID] = nil
        phases[conversationID] = nil
        changed()
    }

    func send(_ submission: ClaudeTextTurnSubmission,
              onProgress: @escaping @MainActor @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        let id = submission.conversationID.rawValue
        guard messages[id] == submission.userMessageID.rawValue else {
            return .init(outcome: .failed(.busy))
        }
        var steered = submission
        if superseders[id] == submission.userMessageID.rawValue {
            // The running turn settles first, so its partial reply is saved
            // before the correction reads it; then this one starts.
            if let previous = tasks[id] { _ = await previous.value }
            guard !closing, messages[id] == submission.userMessageID.rawValue else { return .init(outcome: .stopped) }
            superseders[id] = nil
            superseded[id] = nil
            tasks[id] = nil
            phases[id] = .sending
            changed()
            steered = ClaudeTextTurnSubmission(conversationID: submission.conversationID,
                teammateID: submission.teammateID, userMessageID: submission.userMessageID,
                text: submission.text, attachmentIDs: submission.attachmentIDs, correctsRunningTurn: true)
        }
        guard !closing, phases[id] != .stopping else {
            phases[id] = .stopped
            changed()
            return .init(outcome: .stopped)
        }
        let service = self.service
        let sent = steered
        let task = Task { [weak self] in
            let coordinator = self
            return await service.sendText(sent) { progress in
                await coordinator?.receive(progress, conversationID: id, messageID: submission.userMessageID.rawValue)
                await onProgress(progress)
            }
        }
        tasks[id] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        settle(task, conversationID: id, messageID: submission.userMessageID.rawValue)
        return result
    }

    /// The receiver's leg of a staged handoff. Reservation, phases, stop and
    /// finish are exactly `send`'s; the handoff's own id stands in for the
    /// message id a user-authored turn would have reserved, so one leg and one
    /// typed reply can never run in the same conversation at once.
    func sendLeg(_ submission: HandoffLegSubmission, conversationID: UUID, messageID: UUID,
                 onProgress: @escaping @MainActor @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard messages[conversationID] == messageID else {
            return .init(outcome: .failed(.busy))
        }
        guard !closing, phases[conversationID] != .stopping else {
            phases[conversationID] = .stopped
            changed()
            return .init(outcome: .stopped)
        }
        let service = self.service
        let task = Task { [weak self] in
            let coordinator = self
            return await service.sendHandoffLeg(submission) { progress in
                await coordinator?.receive(progress, conversationID: conversationID, messageID: messageID)
                await onProgress(progress)
            }
        }
        tasks[conversationID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        settle(task, conversationID: conversationID, messageID: messageID)
        return result
    }

    /// The lead's turn on a member's report, under the same reservation rules
    /// as a leg: one holder per conversation, Stop ends it.
    func sendReport(_ submission: HandoffReportSubmission, conversationID: UUID, messageID: UUID,
                    onProgress: @escaping @MainActor @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard messages[conversationID] == messageID else {
            return .init(outcome: .failed(.busy))
        }
        guard !closing, phases[conversationID] != .stopping else {
            phases[conversationID] = .stopped
            changed()
            return .init(outcome: .stopped)
        }
        let service = self.service
        let task = Task { [weak self] in
            let coordinator = self
            return await service.sendHandoffReport(submission) { progress in
                await coordinator?.receive(progress, conversationID: conversationID, messageID: messageID)
                await onProgress(progress)
            }
        }
        tasks[conversationID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        settle(task, conversationID: conversationID, messageID: messageID)
        return result
    }

    /// A worker's holder woken with its result, under the
    /// same reservation rules as a report: one holder per conversation, Stop ends it.
    func sendWorkerResult(_ submission: WorkerResultSubmission, conversationID: UUID, messageID: UUID,
                          onProgress: @escaping @MainActor @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard messages[conversationID] == messageID else {
            return .init(outcome: .failed(.busy))
        }
        guard !closing, phases[conversationID] != .stopping else {
            phases[conversationID] = .stopped
            changed()
            return .init(outcome: .stopped)
        }
        let service = self.service
        let task = Task { [weak self] in
            let coordinator = self
            return await service.sendWorkerResult(submission) { progress in
                await coordinator?.receive(progress, conversationID: conversationID, messageID: messageID)
                await onProgress(progress)
            }
        }
        tasks[conversationID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        settle(task, conversationID: conversationID, messageID: messageID)
        return result
    }

    /// The end of one transport task. A correction can take the conversation
    /// while this turn is still settling, and the stopped turn's call
    /// resumes after the correction's has started its own task: it must leave
    /// that task, which Stop and the next correction cancel, and its phase
    /// alone. Clearing them unconditionally refuses a second correction and
    /// takes Stop away from a live run.
    private func settle(_ task: Task<ClaudeTextTurnResult, Never>, conversationID: UUID, messageID: UUID) {
        if tasks[conversationID] == task { tasks[conversationID] = nil }
        if messages[conversationID] == messageID {
            if phases[conversationID] != .stopping { phases[conversationID] = .saving }
        } else if messages[conversationID] == nil, tasks[conversationID] == nil, phases[conversationID] == .stopping {
            // Stop withdrew the correction that was waiting for this turn
            // (`stop`), so no `finish` names this conversation again: this
            // turn's end is the Stop's end, or it would read "Stopping…" for good.
            phases[conversationID] = .stopped
            changed()
            conversationFreed?(conversationID)
            return
        }
        changed()
    }

    func finish(conversationID: UUID, messageID: UUID, outcome: ClaudeTextTurnOutcome) {
        guard messages[conversationID] == messageID else {
            releaseReplacedTurn(conversationID: conversationID, messageID: messageID)
            return
        }
        approvals[conversationID] = nil
        questions[conversationID] = nil
        clearActivity(for: conversationID)
        bubbles[conversationID] = nil
        switch outcome {
        case .completed: phases[conversationID] = .completed
        case .stopped: phases[conversationID] = .stopped
        case .failed(let problem, let refusedFrame): phases[conversationID] = .failed(problem, refusedFrame: refusedFrame)
        }
        changed()
        conversationFreed?(conversationID)
    }

    /// A replaced turn that ended while its correction waited has no claim
    /// left: were the correction abandoned, there would be no end to wait for.
    private func releaseReplacedTurn(conversationID: UUID, messageID: UUID) {
        if superseded[conversationID] == messageID { superseded[conversationID] = nil }
    }

    /// Called when a turn's end frees its conversation: the moment a worker's
    /// result that waited for its holder can go.
    var conversationFreed: (@MainActor (UUID) -> Void)?

    func stop(conversationID: UUID) {
        guard phases[conversationID]?.isBusy == true else { return }
        // Stop pressed while a correction waits its turn: the correction is
        // withdrawn too; nothing restarts on its own.
        superseded[conversationID] = nil
        if let superseder = superseders.removeValue(forKey: conversationID), messages[conversationID] == superseder {
            messages[conversationID] = nil
        }
        phases[conversationID] = .stopping
        tasks[conversationID]?.cancel()
        changed()
    }

    func beginShutdown() {
        closing = true
        for id in Array(phases.keys) { stop(conversationID: id) }
    }

    private func receive(_ progress: ClaudeTextTurnProgress, conversationID: UUID, messageID: UUID) {
        guard messages[conversationID] == messageID, phases[conversationID] != .stopping else { return }
        if case .approvalRequired(let approval) = progress {
            approvals[conversationID] = approval
            changed()
        }
        if case .questionAsked(let question) = progress {
            questions[conversationID] = question
            changed()
        }
        if case .questionResolved(let id) = progress {
            if questions[conversationID]?.id == id { questions[conversationID] = nil; changed() }
        }
        if case .approvalResolved(let id) = progress {
            if approvals[conversationID]?.id == id { approvals[conversationID] = nil; changed() }
        }
        if case .activity(let line) = progress {
            appendActivity(line, for: conversationID)
            changed()
        }
        if case .screenPicture(let data) = progress {
            screenPictures[conversationID] = data
            changed()
        }
        if case .bubbles(let list) = progress {
            bubbles[conversationID] = list
        }
        if case .stage(let stage) = progress {
            switch stage {
            case .selectingContext, .checkingReadiness, .starting: phases[conversationID] = .sending
            case .responding: phases[conversationID] = .responding
            case .saving: phases[conversationID] = .saving
            }
            changed()
        }
        if case .contextPrepared(let disclosure) = progress {
            contextDisclosures[conversationID] = disclosure
            changed()
        }
        if case .modelObserved(let requested, let observed) = progress {
            var presentation = modelPresentations[conversationID] ?? .init()
            presentation.requested = requested
            presentation.observedAtStart = observed
            modelPresentations[conversationID] = presentation
            changed()
        }
        if case .modelConfirmed(let requested, let observed) = progress {
            var presentation = modelPresentations[conversationID] ?? .init()
            presentation.confirmedRequest = requested
            presentation.confirmedModel = observed
            presentation.confirmedEffort = nil
            presentation.confirmedContextWindow = nil
            presentation.isFromSavedRecord = false
            modelPresentations[conversationID] = presentation
            changed()
        }
    }
}
