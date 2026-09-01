import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// One workspace's draft bridge. The conversation renders immediately;
/// individual draft models own persistence and conflict state independently.
/// No transcript, runtime, file import, or secret-card state enters this object.
@MainActor
public final class WorkspaceDraftCoordinator: ObservableObject {
    @Published public private(set) var activeDraft: ConversationComposerDraftModel?
    @Published public private(set) var isShuttingDown = false
    private let conversation: ConversationModel
    private let service: any ConversationDraftServing
    private var models: [UUID: ConversationComposerDraftModel] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var isUpdatingComposer = false
    private var submissions: [UUID: (ConversationComposerDraftModel, ConversationDraftSubmissionToken)] = [:]
    private var shutdownModels: [ConversationComposerDraftModel] = []
    private var shutdownTask: Task<Bool, Never>?
    private var shutdownFinished = false

    public init(conversation: ConversationModel, service: any ConversationDraftServing) {
        self.conversation = conversation
        self.service = service
        conversation.$composerText.dropFirst().sink { [weak self] text in
            guard let self, !self.isShuttingDown, !self.isUpdatingComposer,
                  let id = self.conversation.conversationID,
                  let model = self.models[id] else { return }
            model.setText(text)
        }.store(in: &subscriptions)
    }

    public func activate(conversationID: UUID?) {
        guard !isShuttingDown else { return }
        guard let conversationID else {
            activeDraft = nil
            updateComposer("")
            conversation.setDraftSubmissionAllowed(false)
            return
        }
        let model: ConversationComposerDraftModel
        if let existing = models[conversationID] {
            model = existing
        } else {
            model = ConversationComposerDraftModel(conversationID: ConversationID(conversationID), service: service)
            models[conversationID] = model
            model.$text.dropFirst().sink { [weak self, weak model] text in
                guard let self, !self.shutdownFinished, let model, self.activeDraft === model,
                      self.conversation.conversationID == conversationID else { return }
                self.updateComposer(text)
            }.store(in: &subscriptions)
            model.objectWillChange.sink { [weak self, weak model] _ in
                Task { @MainActor in
                    guard let self, !self.isShuttingDown, !Task.isCancelled, let model, self.activeDraft === model else { return }
                    self.conversation.setDraftSubmissionAllowed(model.canBeginSubmission)
                }
            }.store(in: &subscriptions)
        }
        activeDraft = model
        updateComposer(model.text)
        conversation.setDraftSubmissionAllowed(model.canBeginSubmission)
        Task { [weak self] in
            guard let self, !self.isShuttingDown, !Task.isCancelled else { return }
            await model.load()
        }
    }

    public func beginSubmission(messageID: UUID, conversationID: UUID, rawText: String, allowsEmptyText: Bool = false) -> Bool {
        guard !isShuttingDown, submissions[messageID] == nil, let model = models[conversationID],
              let token = model.beginSubmission(messageID: messageID, rawText: rawText, allowsEmptyText: allowsEmptyText) else { return false }
        submissions[messageID] = (model, token)
        if activeDraft === model { conversation.setDraftSubmissionAllowed(false) }
        return true
    }

    public func persistSubmission(messageID: UUID) async -> Bool {
        guard !isShuttingDown, !Task.isCancelled, let (model, token) = submissions[messageID] else { return false }
        let saved = await model.persistSubmission(token)
        return !shutdownFinished && !Task.isCancelled && saved
    }

    public func completeSubmission(messageID: UUID) async {
        guard !shutdownFinished, !Task.isCancelled, let (model, token) = submissions.removeValue(forKey: messageID) else { return }
        _ = await model.completeSubmission(token)
    }

    public func failSubmission(messageID: UUID) {
        guard !shutdownFinished, let (model, token) = submissions.removeValue(forKey: messageID) else { return }
        model.failSubmission(token)
    }

    /// Ordinary explicit persistence checkpoint, not permission to veto Quit.
    /// Shutdown uses the frozen, deadline-owned path below.
    public func flushAll() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled else { return false }
        var saved = submissions.isEmpty
        for model in Array(models.values) {
            if !(await model.flush()) { saved = false }
            guard !isShuttingDown, !Task.isCancelled else { return false }
        }
        // Awaiting another conversation can let the user edit a previously
        // flushed draft or open a new one. Recheck every current model at the
        // final synchronous decision, not just the initial iteration snapshot.
        return saved && submissions.isEmpty && models.values.allSatisfy {
            $0.status == .saved && !$0.hasUnsavedChanges
        }
    }

    /// Freeze every visited conversation in the same synchronous admission
    /// boundary. Navigation cannot create another draft after this point.
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownModels = Array(models.values)
        shutdownModels.forEach { $0.beginShutdown() }
        conversation.setDraftSubmissionAllowed(false)
    }

    public func flushForShutdown() async -> Bool {
        guard isShuttingDown, !shutdownFinished, !Task.isCancelled else { return false }
        if let pending = shutdownTask {
            let result = await pending.value
            return !shutdownFinished && !Task.isCancelled && result
        }
        let frozen = shutdownModels
        let task = Task { [weak self] in
            guard let self, !self.shutdownFinished, !Task.isCancelled else { return false }
            // Separate conversations start their bounded pass independently;
            // one stalled save must not prevent another available draft saving.
            let saved = await withTaskGroup(of: Bool.self) { group in
                for model in frozen {
                    group.addTask { await model.flushForShutdown() }
                }
                var result = true
                for await value in group { result = result && value }
                return result
            }
            guard !self.shutdownFinished, !Task.isCancelled else { return false }
            return saved && self.submissions.isEmpty && frozen.allSatisfy { !$0.hasUnsavedChanges }
        }
        shutdownTask = task
        let saved = await task.value
        return !shutdownFinished && !Task.isCancelled && saved
    }

    public func finishShutdown() {
        beginShutdown()
        guard !shutdownFinished else { return }
        shutdownFinished = true
        shutdownTask?.cancel()
        shutdownModels.forEach { $0.finishShutdown() }
        subscriptions.removeAll()
        submissions.removeAll()
    }

    private func updateComposer(_ text: String) {
        guard !conversation.composerText.utf8.elementsEqual(text.utf8) else { return }
        isUpdatingComposer = true
        conversation.composerText = text
        isUpdatingComposer = false
    }
}
