import OpenBotsDomain
import SwiftUI

/// Inline discovery only. Selecting a result passes its immutable hit to the
/// coordinator, which revalidates and opens the appropriate conversation.
public struct ConversationSearchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model: ConversationSearchModel
    @FocusState private var fieldIsFocused: Bool
    private let onSelectTeammate: @MainActor (TeammateSearchHit) -> Void
    private let onSelectMessage: @MainActor (MessageSearchHit) -> Void
    private let onClose: @MainActor () -> Void

    public init(
        model: ConversationSearchModel,
        onSelectTeammate: @escaping @MainActor (TeammateSearchHit) -> Void,
        onSelectMessage: @escaping @MainActor (MessageSearchHit) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.onSelectTeammate = onSelectTeammate
        self.onSelectMessage = onSelectMessage
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            HStack {
                Text("Search").font(.title2.weight(.semibold)).fontDesign(.rounded)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { close() }
                    .accessibilityLabel("Close Search")
                    .accessibilityIdentifier("search.close")
                    .help("Close search (Escape)")
            }
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search teammates and saved messages", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldIsFocused)
                    .accessibilityLabel("Search teammates and saved messages")
                    .accessibilityIdentifier("search.query")
                    .accessibilityHint("Searches only active bots and messages saved in their direct chats")
                    .onSubmit { Task { await model.searchNow() } }
                if !model.query.isEmpty {
                    Button {
                        model.clear()
                        fieldIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("search.clear")
                    .help("Clear search")
                }
            }
            Text(ConversationSearchModel.scopeDisclosure)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            searchStatus
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("search.status")
            if let page = model.page, model.state == .results {
                results(page)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(OpenBotsVisualStyle.spacing16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityIdentifier("search.container")
        .onAppear {
            fieldIsFocused = true
            if model.state == .idle, !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await model.searchNow() }
            }
        }
        .onExitCommand { close() }
        .onDisappear { model.cancelPendingSearch() }
    }

    @ViewBuilder
    private var searchStatus: some View {
        switch model.state {
        case .idle:
            Text("Find a teammate or a message you’ve saved.")
                .font(.callout).foregroundStyle(.secondary)
        case .waiting, .loading:
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                ProgressView().controlSize(.small)
                Text("Searching local conversations…").font(.callout)
            }
            .accessibilityElement(children: .combine)
        case .noResults:
            Text("No matches in active direct chats. Try another name or message word.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .failed:
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                Label(model.errorMessage ?? "Search is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.searchNow() } }
                    .accessibilityLabel("Retry Search")
                    .accessibilityIdentifier("search.retry")
            }
        case .results:
            if let page = model.page {
                Text("\(page.teammates.count) teammates · \(page.messages.count) saved messages")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func results(_ page: ConversationSearchPage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                if !page.teammates.isEmpty {
                    Text("Teammates").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(page.teammates) { hit in
                        Button { selectTeammate(hit) } label: {
                            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                                Text(hit.teammate.profile.displayName).font(.headline)
                                Text(hit.teammate.profile.role).font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(OpenBotsVisualStyle.spacing8)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open chat with \(hit.teammate.profile.displayName). \(hit.teammate.profile.role)")
                        .accessibilityIdentifier("search.bot.\(hit.id.rawValue.uuidString)")
                    }
                }
                if !page.messages.isEmpty {
                    Text("Saved messages").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, page.teammates.isEmpty ? 0 : OpenBotsVisualStyle.spacing8)
                    ForEach(page.messages) { hit in
                        Button { selectMessage(hit) } label: {
                            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                                Text(hit.teammateName).font(.headline)
                                Text("\(hit.authorName) · \(hit.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(hit.snippet).font(.body).lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(OpenBotsVisualStyle.spacing8)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open saved message in \(hit.teammateName)’s chat. \(hit.authorName). \(hit.createdAt.formatted(date: .abbreviated, time: .shortened)). \(hit.snippet)")
                        .accessibilityIdentifier("search.message.\(hit.id.rawValue.uuidString)")
                        .accessibilityHint("Opens the saved message in its original conversation without sending anything")
                    }
                }
                if model.hasMoreResults {
                    Text("More matches are available. Refine your search to narrow the results.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, OpenBotsVisualStyle.spacing8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
        .accessibilityIdentifier("search.results")
    }

    // These action routes pass exact immutable hits; the coordinator retains
    // ownership of target revalidation, history loading and conversation state.
    func selectTeammate(_ hit: TeammateSearchHit) { onSelectTeammate(hit) }
    func selectMessage(_ hit: MessageSearchHit) { onSelectMessage(hit) }

    func close() {
        model.cancelPendingSearch()
        onClose()
    }
}
