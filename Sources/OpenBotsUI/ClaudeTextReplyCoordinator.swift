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
}

public enum ClaudeTextReplyPhase: Equatable, Sendable {
    case sending, responding, saving, stopping, completed, stopped
    case failed(ClaudeTextTurnProblem)

    public var isBusy: Bool {
        switch self {
        case .sending, .responding, .saving, .stopping: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .sending: "Preparing reply…"
        case .responding: "Receiving response…"
        case .saving: "Saving reply…"
        case .stopping: "Stopping and saving available text…"
        case .completed: "Reply saved."
        case .stopped: "Stopped. Any saved message and partial reply are kept; nothing will be resent automatically."
        case .failed(let problem): Self.explanation(problem)
        }
    }

    public static func explanation(_ problem: ClaudeTextTurnProblem) -> String {
        switch problem {
        case .unavailable, .runtimeUnavailable: "Claude could not complete this turn. Saved text is kept; check its connection under Settings → Computer."
        case .busy: "This bot already has an active or unresolved reply. Nothing was resent."
        case .attachmentsNotSupported: "This reply accepts text only. Keep attachments here, or choose Save Locally."
        case .invalidInput: "This message could not be submitted. Your text is preserved."
        case .modelUnavailable, .effortUnavailable, .contextWindowUnavailable: "Claude could not start this turn with the available execution settings. Your text and saved preferences are kept. This picker does not verify provider settings."
        case .contextTooLarge: "The full bot profile could not fit this request. Nothing was sent or shortened; edit the profile before trying again."
        case .contextUnavailable: "OpenBots could not safely prepare this bot’s saved context. Nothing was sent; your text is kept."
        case .contextChanged: "This bot’s context or access changed. The reply was not confirmed saved; your text is kept and nothing will be resent automatically."
        case .memoryPublicationNotReady: "This reply needs saved memory. Its controlled reply path is not ready yet, so nothing was sent and your text is kept."
        case .memoryAcknowledgementPending: "The memory change is saved, but its confirmation could not be added to this conversation. It has not been undone."
        case .setupRequired: "Claude setup needs attention under Settings → Computer."
        case .subscriptionNotVerified: "The Claude.ai subscription could not be verified. Check Settings → Computer."
        case .managedPolicyPresentOrUnknown: "Claude’s required tool-free configuration could not be verified. Nothing was sent."
        case .invalidResponse: "Claude’s response could not be verified. Saved text is kept; no retry will run automatically."
        case .timedOut: "Claude did not finish in time. Saved text is kept; no retry will run automatically."
        case .persistenceFailed: "The reply could not be confirmed saved. Any already-saved messages are kept; do not resend automatically."
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
    private var tasks: [UUID: Task<ClaudeTextTurnResult, Never>] = [:]
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

    func reserve(conversationID: UUID, messageID: UUID) -> Bool {
        guard !closing, phases[conversationID]?.isBusy != true else { return false }
        messages[conversationID] = messageID
        contextDisclosures[conversationID] = nil
        modelPresentations[conversationID]?.requested = nil
        modelPresentations[conversationID]?.observedAtStart = nil
        phases[conversationID] = .sending
        changed()
        return true
    }

    func abandon(conversationID: UUID, messageID: UUID) {
        guard messages[conversationID] == messageID, tasks[conversationID] == nil else { return }
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
        guard !closing, phases[id] != .stopping else {
            phases[id] = .stopped
            changed()
            return .init(outcome: .stopped)
        }
        let service = self.service
        let task = Task { [weak self] in
            let coordinator = self
            return await service.sendText(submission) { progress in
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
        tasks[id] = nil
        if phases[id] != .stopping { phases[id] = .saving }
        changed()
        return result
    }

    func finish(conversationID: UUID, messageID: UUID, outcome: ClaudeTextTurnOutcome) {
        guard messages[conversationID] == messageID else { return }
        switch outcome {
        case .completed: phases[conversationID] = .completed
        case .stopped: phases[conversationID] = .stopped
        case .failed(let problem): phases[conversationID] = .failed(problem)
        }
        changed()
    }

    func stop(conversationID: UUID) {
        guard phases[conversationID]?.isBusy == true else { return }
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
            modelPresentations[conversationID] = presentation
            changed()
        }
    }
}
