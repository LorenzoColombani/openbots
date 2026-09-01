import Foundation
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

enum WorkspaceSearchDestination {
    case teammate(TeammateSearchHit)
    case message(MessageSearchTarget)
}

/// Owns only transient search navigation. A result is a hint, not authority:
/// message IDs are resolved afresh before the workspace opens a bounded page.
@MainActor
public final class WorkspaceSearchCoordinator: ObservableObject {
    public let model: ConversationSearchModel
    @Published public private(set) var isPresented = false
    @Published public private(set) var isOpening = false
    @Published public private(set) var notice: String?

    typealias Navigate = @MainActor (
        WorkspaceSearchDestination, @escaping @MainActor () -> Bool
    ) async throws -> Void
    private let service: any ConversationSearchServing
    private let navigate: Navigate
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(service: any ConversationSearchServing, navigate: @escaping Navigate) {
        self.service = service
        self.navigate = navigate
        model = ConversationSearchModel(service: service)
    }

    public func present() {
        generation &+= 1
        task?.cancel()
        isOpening = false
        notice = nil
        isPresented = true
    }

    public func close() {
        generation &+= 1
        task?.cancel()
        task = nil
        isOpening = false
        isPresented = false
        model.cancelPendingSearch()
    }

    public func openTeammate(_ hit: TeammateSearchHit) {
        open { .teammate(hit) }
    }

    public func openMessage(_ hit: MessageSearchHit) {
        open { [service] in
            guard let target = try await service.resolveMessage(id: hit.id),
                  target.id == hit.id,
                  target.conversationID == hit.conversationID,
                  target.teammateID == hit.teammateID else {
                throw SearchNavigationError.unavailable
            }
            return .message(target)
        }
    }

    private func open(_ resolve: @escaping @MainActor () async throws -> WorkspaceSearchDestination) {
        guard isPresented else { return }
        generation &+= 1
        let request = generation
        task?.cancel()
        isOpening = true
        notice = nil
        task = Task { [weak self] in
            guard let self else { return }
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                self?.generation == request && self?.isPresented == true && !Task.isCancelled
            }
            do {
                let destination = try await resolve()
                guard isCurrent() else { return }
                try await navigate(destination, isCurrent)
                guard isCurrent() else { return }
                isOpening = false
                isPresented = false
                model.cancelPendingSearch()
            } catch {
                guard isCurrent() else { return }
                isOpening = false
                notice = "That saved result could not be opened. Search again; your conversation and draft are unchanged."
            }
        }
    }
}

enum SearchNavigationError: Error { case unavailable }

struct WorkspaceSearchView: View {
    @ObservedObject var coordinator: WorkspaceSearchCoordinator

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.isOpening {
                Text("Opening saved result…").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let notice = coordinator.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(12)
            }
            ConversationSearchView(
                model: coordinator.model,
                onSelectTeammate: coordinator.openTeammate,
                onSelectMessage: coordinator.openMessage,
                onClose: coordinator.close
            )
        }
        .navigationTitle("Search OpenBots")
    }
}

struct WorkspaceSearchPresentation<Content: View>: View {
    @ObservedObject var coordinator: WorkspaceSearchCoordinator
    @ViewBuilder var content: (AnyView?) -> Content

    var body: some View {
        content(coordinator.isPresented ? AnyView(WorkspaceSearchView(coordinator: coordinator)) : nil)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: coordinator.present) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search teammates and saved messages")
                }
            }
    }
}
