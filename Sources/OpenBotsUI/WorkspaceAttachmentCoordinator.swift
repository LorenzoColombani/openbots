import Combine
import Foundation
import OpenBotsDomain

/// The picker belongs to the draft that opened it, even if app navigation
/// changes before its result arrives. Cancellation consumes the request too.
@MainActor
final class AttachmentPickerRequest {
    private let draft: AttachmentDraftModel
    private var consumed = false
    init(draft: AttachmentDraftModel) { self.draft = draft }
    @discardableResult func consume(_ url: URL?) -> Bool {
        guard !consumed else { return false }
        consumed = true
        guard let url else { return false }
        return draft.selectFile(at: url)
    }
}

/// Frozen attachment sends stay separate from roster and navigation state.
@MainActor
public final class WorkspaceAttachmentCoordinator {
    public typealias Factory = @MainActor (ConversationID) -> AttachmentDraftModel
    private let conversation: ConversationModel
    private let factory: Factory
    private var models: [UUID: AttachmentDraftModel] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var activeID: UUID?
    private var submissions: [UUID: (UUID, AttachmentDraftModel, [AttachmentAsset])] = [:]
    public private(set) var isShuttingDown = false
    private var shutdownFinished = false
    private var shutdownWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(conversation: ConversationModel, factory: @escaping Factory) {
        self.conversation = conversation
        self.factory = factory
    }

    public func activate(_ id: UUID?) -> AttachmentDraftModel? {
        guard !isShuttingDown else { return nil }
        activeID = id
        guard let id else { refreshAdmission(); return nil }
        let model: AttachmentDraftModel
        if let cached = models[id] { model = cached }
        else {
            model = factory(ConversationID(id))
            models[id] = model
            model.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.refreshAdmission() }
            }.store(in: &subscriptions)
        }
        refreshAdmission()
        Task { await model.load() }
        return model
    }

    public func begin(messageID: UUID, conversationID: UUID) -> [AttachmentAsset]? {
        guard !isShuttingDown, submissions[messageID] == nil, let model = models[conversationID],
              !submissions.values.contains(where: { $0.0 == conversationID }),
              let assets = try? model.freezeForSubmission() else { return nil }
        submissions[messageID] = (conversationID, model, assets)
        refreshAdmission()
        return assets
    }

    public func assets(messageID: UUID) -> [AttachmentAsset] {
        shutdownFinished ? [] : submissions[messageID]?.2 ?? []
    }

    public func finish(messageID: UUID, committed: Bool) {
        guard !shutdownFinished, let (_, model, assets) = submissions.removeValue(forKey: messageID) else { return }
        if committed { model.acknowledgeSubmitted(ids: Set(assets.map(\.id))) }
        refreshAdmission()
        if isShuttingDown && submissions.isEmpty {
            let waiters = shutdownWaiters.values
            shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: true) }
        }
    }

    public var isSafeToQuit: Bool {
        submissions.isEmpty && models.values.allSatisfy(\.canSubmit)
    }

    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        for model in models.values { model.beginShutdown() }
        refreshAdmission()
    }

    /// No independent deadline or new work: the app supplies one shared grace.
    public func settleForShutdown() async -> Bool {
        guard isShuttingDown, !shutdownFinished, !Task.isCancelled else { return false }
        var settled = true
        for model in models.values {
            let result = await model.settleForShutdown()
            guard !shutdownFinished, !Task.isCancelled else { return false }
            settled = result && settled
        }
        guard !submissions.isEmpty else { return settled }
        let id = UUID()
        let submissionsSettled = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shutdownWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.shutdownWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        return settled && submissionsSettled && !shutdownFinished && !Task.isCancelled
    }

    public func finishShutdown() {
        beginShutdown()
        guard !shutdownFinished else { return }
        shutdownFinished = true
        for model in models.values { model.finishShutdown() }
        subscriptions.removeAll()
        submissions.removeAll()
        let waiters = shutdownWaiters.values
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
    }

    private func refreshAdmission() {
        guard !shutdownFinished else { return }
        guard !isShuttingDown else {
            conversation.setAttachmentSubmission(allowed: false, hasContent: false)
            return
        }
        guard let id = activeID, let model = models[id] else {
            conversation.setAttachmentSubmission(allowed: false, hasContent: false)
            return
        }
        conversation.setAttachmentSubmission(
            allowed: model.canSubmit && !submissions.values.contains(where: { $0.0 == id }),
            hasContent: model.hasDurableAttachments
        )
    }
}
