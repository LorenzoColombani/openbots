import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

/// An on-request read of saved facts, not a cache, live status monitor or work
/// dispatcher. Hiding or changing scope discards the displayed read result.
@MainActor
public final class SavedOutcomeHistoryModel: ObservableObject {
    @Published public private(set) var request: ConversationOutcomeHistoryRequest?
    @Published public private(set) var summary: ConversationOutcomeHistorySummary?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var hasRequested = false
    @Published public private(set) var isClosing = false

    private let service: any ConversationOutcomeHistoryServing
    private var generation: UInt64 = 0
    private var loadingTask: Task<Void, Never>?

    public init(service: any ConversationOutcomeHistoryServing) { self.service = service }
    deinit { loadingTask?.cancel() }

    public var canLoad: Bool { request != nil && !isLoading && !isClosing }

    public func activateScope(_ request: ConversationOutcomeHistoryRequest?) {
        guard !isClosing, self.request != request else { return }
        resetDisplay()
        self.request = request
    }

    public func load() async {
        guard canLoad, !Task.isCancelled, let request else { return }
        generation &+= 1
        let operation = generation
        isLoading = true
        hasRequested = true
        errorMessage = nil
        summary = nil
        let service = service
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await service.history(request)
                try Task.checkCancellation()
                guard let self, self.isCurrent(request, operation) else { return }
                // The service validates provenance and output. Keep a final
                // bounded-view guard without silently truncating its result.
                guard result.outcomes.count <= request.limit else {
                    throw ConversationOutcomeHistoryError.invalidRepositoryResponse
                }
                self.summary = result
                self.isLoading = false
            } catch {
                guard let self, self.isCurrent(request, operation) else { return }
                self.isLoading = false
                if Task.isCancelled || error is CancellationError {
                    self.hasRequested = false
                    self.errorMessage = nil
                } else {
                    self.errorMessage = "OpenBots couldn’t read the saved outcomes for this conversation. Nothing was changed. Choose Retry Saved Outcomes."
                }
            }
        }
        loadingTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if isCurrent(request, operation) { loadingTask = nil }
    }

    /// Hiding is reversible: retain only the exact selected scope, not results.
    public func dismiss() { resetDisplay() }

    public func beginShutdown() {
        guard !isClosing else { return }
        isClosing = true
        resetDisplay()
        request = nil
    }

    private func resetDisplay() {
        generation &+= 1
        loadingTask?.cancel()
        loadingTask = nil
        summary = nil
        isLoading = false
        errorMessage = nil
        hasRequested = false
    }

    private func isCurrent(_ request: ConversationOutcomeHistoryRequest, _ operation: UInt64) -> Bool {
        !isClosing && generation == operation && self.request == request
    }
}
