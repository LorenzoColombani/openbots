import Combine
import Foundation
import OpenBotsDomain
import OpenBotsServices

public enum ConversationSearchState: Equatable, Sendable {
    case idle, waiting, loading, results, noResults, failed
}

/// Process-local search presentation, not a query history or a message loader.
/// Result navigation and fresh target resolution belong to the coordinator.
@MainActor
public final class ConversationSearchModel: ObservableObject {
    public static let scopeDisclosure =
        "Searches active teammates and saved messages in their direct chats. Unsent drafts and secret-card input are not searched."

    @Published public private(set) var query = ""
    @Published public private(set) var state = ConversationSearchState.idle
    @Published public private(set) var page: ConversationSearchPage?
    @Published public private(set) var errorMessage: String?

    private let service: any ConversationSearchServing
    private let debounce: Duration
    private var generation: UInt64 = 0
    private var requestTask: Task<Void, Never>?

    public init(service: any ConversationSearchServing, debounce: Duration = .milliseconds(200)) {
        self.service = service
        self.debounce = debounce
    }

    public var isSearching: Bool { state == .waiting || state == .loading }
    public var hasMoreResults: Bool { page?.hasMoreTeammates == true || page?.hasMoreMessages == true }

    public func setQuery(_ value: String) {
        guard !query.utf8.elementsEqual(value.utf8) else { return }
        invalidatePendingSearch()
        query = value
        page = nil
        errorMessage = nil
        guard let request = validatedRequest() else { return }
        let operation = generation
        let delay = debounce
        state = .waiting
        requestTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.performSearch(request, generation: operation)
        }
    }

    public func clear() {
        invalidatePendingSearch()
        query = ""
        page = nil
        errorMessage = nil
        state = .idle
    }

    /// An explicit Return/retry bypasses only the debounce, never validation.
    public func searchNow() async {
        invalidatePendingSearch()
        page = nil
        errorMessage = nil
        guard let request = validatedRequest() else { return }
        let operation = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSearch(request, generation: operation)
        }
        requestTask = task
        await task.value
    }

    /// Closing the panel cancels pending work without clearing a conversation,
    /// writing a preference, or retaining any query outside this model.
    public func cancelPendingSearch() {
        invalidatePendingSearch()
        if isSearching { state = .idle }
    }

    private func invalidatePendingSearch() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
    }

    private func validatedRequest() -> ConversationSearchRequest? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            return nil
        }
        do { return try ConversationSearchRequest(query: query) }
        catch {
            state = .failed
            errorMessage = "Use up to 200 characters and eight search terms, without null characters."
            return nil
        }
    }

    private func performSearch(_ request: ConversationSearchRequest, generation operation: UInt64) async {
        guard generation == operation, !Task.isCancelled else { return }
        state = .loading
        do {
            let result = try await service.search(request)
            guard generation == operation, !Task.isCancelled else { return }
            page = result
            state = result.teammates.isEmpty && result.messages.isEmpty ? .noResults : .results
        } catch is CancellationError {
            guard generation == operation else { return }
            state = .idle
        } catch {
            guard generation == operation, !Task.isCancelled else { return }
            errorMessage = "OpenBots couldn’t search the saved conversations. Your chats and drafts are unchanged. Try again."
            state = .failed
        }
    }
}
