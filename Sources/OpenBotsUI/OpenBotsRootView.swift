import SwiftUI
import UniformTypeIdentifiers

/// A detail with an optional pane must contribute both columns to the native
/// window minimum. Other details retain the ordinary chat minimum.
struct WorkspaceDetailMinimumWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Adds row identity to the near-bottom follow rule. Keeping this pure makes
/// the overlapping-reply case testable without driving a physical scroll view.
enum TranscriptTailFollowPolicy {
    static func followsStreamingGrowth(
        isNearBottom: Bool,
        streamingRowID: UUID,
        tailRowID: UUID?
    ) -> Bool {
        streamingRowID == tailRowID
            && TranscriptScrollFollowPolicy.followsStreamingGrowth(
                isNearBottom: isNearBottom
            )
    }
}

public struct OpenBotsRootView: View {
    // Native sidebar cells add eight points of horizontal inset compared with
    // the former plain List. Keep the full hover width without widening input.
    private static let sidebarHoverOutset = OpenBotsVisualStyle.spacing12 + OpenBotsVisualStyle.spacing8

    private enum FocusDestination: Hashable {
        case composer, search, plugins, details, account, sidebarToggle
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var sidebar: SidebarModel
    @ObservedObject private var conversation: ConversationModel
    @FocusState private var focus: FocusDestination?
    @State private var paginationAnchorID: UUID?
    @State private var isSelectingAttachment = false
    @State private var attachmentPickerRequest: AttachmentPickerRequest?
    @State private var transcriptIsNearBottom = true
    @State private var hasUnseenLatest = false
    @State private var pendingOpeningConversationID: UUID?
    @State private var detailMinimumWidth: CGFloat = 0
    @State private var isSidebarVisible = true
    @State private var isShowingPlugins = false
    @State private var detailsSelectionID: UUID?

    private let attachmentDraft: AttachmentDraftModel?
    private let draftCoordinator: WorkspaceDraftCoordinator?
    private let cardInteractions: ConversationCardInteractionModel?
    private let createTeammate: @MainActor () -> Void
    private let openSettings: @MainActor () -> Void
    private let detailOverride: AnyView?
    private let searchOverlay: AnyView?
    private let detailsPanel: AnyView?
    private let toggleDetails: @MainActor () -> Void
    private let openSearch: (@MainActor () -> Void)?
    private let isCreatingTeammate: Bool
    private let creationError: String?
    private let openClaudeSetup: (@MainActor () -> Void)?
    private let openArchivedBots: (@MainActor () -> Void)?
    private let openBotSettings: (@MainActor (UUID) -> Void)?
    private let archiveBot: (@MainActor (UUID) -> Void)?

    public init(
        sidebar: SidebarModel,
        conversation: ConversationModel,
        attachmentDraft: AttachmentDraftModel? = nil,
        draftCoordinator: WorkspaceDraftCoordinator? = nil,
        cardInteractions: ConversationCardInteractionModel? = nil,
        createTeammate: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        detailOverride: AnyView? = nil,
        searchOverlay: AnyView? = nil,
        detailsPanel: AnyView? = nil,
        toggleDetails: @escaping @MainActor () -> Void = {},
        openSearch: (@MainActor () -> Void)? = nil,
        isCreatingTeammate: Bool = false,
        creationError: String? = nil,
        openClaudeSetup: (@MainActor () -> Void)? = nil,
        openArchivedBots: (@MainActor () -> Void)? = nil,
        openBotSettings: (@MainActor (UUID) -> Void)? = nil,
        archiveBot: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.sidebar = sidebar
        self.conversation = conversation
        self.attachmentDraft = attachmentDraft
        self.draftCoordinator = draftCoordinator
        self.cardInteractions = cardInteractions
        self.createTeammate = createTeammate
        self.openSettings = openSettings
        self.detailOverride = detailOverride
        self.searchOverlay = searchOverlay
        self.detailsPanel = detailsPanel
        self.toggleDetails = toggleDetails
        self.openSearch = openSearch
        self.isCreatingTeammate = isCreatingTeammate
        self.creationError = creationError
        self.openClaudeSetup = openClaudeSetup
        self.openArchivedBots = openArchivedBots
        self.openBotSettings = openBotSettings
        self.archiveBot = archiveBot
        self._paginationAnchorID = State(initialValue: nil)
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebarView
                    .frame(width: 280)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Bots")
                    .accessibilityIdentifier("bot-sidebar")
                columnDivider
            }
            ZStack {
                HStack(spacing: 0) {
                    Group {
                        if let detailOverride {
                            detailOverride
                        } else {
                            conversationView
                        }
                    }
                    .frame(minWidth: max(340, detailMinimumWidth), maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(sidebar.selection == nil ? "Conversation" : "Conversation with \(conversation.title)")
                    .accessibilityIdentifier("bot-conversation")
                    if let detailsPanel {
                        columnDivider
                        detailsPanel
                            .frame(width: 320)
                            .frame(maxHeight: .infinity)
                            .background(OpenBotsVisualStyle.surface(for: colorScheme))
                            .accessibilityIdentifier("bot-details")
                    }
                }
                // Search must not tear down the scroll view or an unfinished
                // profile/hiring editor. The covered view is neither focusable
                // through hit testing nor exposed as duplicate accessible UI.
                .opacity(searchOverlay == nil ? 1 : 0)
                .environment(\.characterMotionAllowed, searchOverlay == nil)
                .allowsHitTesting(searchOverlay == nil)
                .disabled(searchOverlay != nil)
                .accessibilityHidden(searchOverlay != nil)
                if let searchOverlay { searchOverlay }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        // The side columns never consume the chat's readable minimum. Explicit
        // toggles preserve content and do not infer an undocumented breakpoint.
        .frame(minWidth: minimumWidth, minHeight: 520)
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
        .onPreferenceChange(WorkspaceDetailMinimumWidthKey.self) { detailMinimumWidth = $0 }
        .tint(OpenBotsVisualStyle.brandAccent(for: colorScheme))
        .sheet(isPresented: $isShowingPlugins, onDismiss: { focus = .plugins }) {
            PluginsCatalogView { isShowingPlugins = false }
                .frame(minWidth: 600, idealWidth: 720, minHeight: 460, idealHeight: 540)
                .preferredColorScheme(colorScheme)
        }
        .fileImporter(
            isPresented: $isSelectingAttachment,
            // `UTType.item` is abstract and left regular files visible but
            // disabled in the physical Mac picker. Ingestion still performs
            // the authoritative regular-file and locality checks.
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            defer { attachmentPickerRequest = nil }
            guard case .success(let urls) = result, let exactURL = urls.first else {
                _ = attachmentPickerRequest?.consume(nil)
                return
            }
            _ = attachmentPickerRequest?.consume(exactURL)
        }
        .onAppear {
            if detailsPanel != nil { detailsSelectionID = sidebar.selection }
            // Only claim initial focus. A later selection/load must not move
            // focus away from the List, a navigation control, or an editor.
            if focus == nil, searchOverlay == nil, detailsPanel == nil,
               sidebar.selection != nil, conversation.inputAvailability == .ready {
                focus = .composer
            }
        }
        .onChange(of: conversation.conversationID) { _, newConversationID in
            pendingOpeningConversationID = newConversationID
            transcriptIsNearBottom = true
            hasUnseenLatest = false
        }
        .onChange(of: conversation.conversationID) {
            paginationAnchorID = nil
        }
        .onChange(of: searchOverlay == nil) { _, isClosed in
            if isClosed, openSearch != nil { focus = .search }
        }
        .onChange(of: detailsPanel == nil) { _, isClosed in
            if isClosed {
                if detailsSelectionID == sidebar.selection, sidebar.selection != nil, searchOverlay == nil {
                    focus = .details
                }
                detailsSelectionID = nil
            } else {
                detailsSelectionID = sidebar.selection
            }
        }
    }

    private var minimumWidth: CGFloat {
        if detailOverride != nil {
            // Explicit historical hiring fixtures retain their verified native
            // minimum; normal creation never opens that surface.
            return max(720, 369 + detailMinimumWidth)
        }
        return max(720, (isSidebarVisible ? 281 : 0)
            + max(340, detailMinimumWidth)
            + (detailsPanel == nil ? 0 : 321))
    }

    private var columnDivider: some View {
        OpenBotsVisualStyle.border(for: colorScheme)
            .frame(width: 1)
            .ignoresSafeArea(.container, edges: .top)
            .accessibilityHidden(true)
    }

    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("OpenBots")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button { isSidebarVisible = false; focus = .sidebarToggle } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Hide bot list")
                .accessibilityLabel("Hide bot list")
                .focused($focus, equals: .sidebarToggle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Button(action: presentSearch) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(OpenBotsVisualStyle.elevatedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(openSearch == nil)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Search")
                .accessibilityHint("Search bot names and messages saved on this Mac")
                .focused($focus, equals: .search)
                .help("Search bot names and messages saved on this Mac")
                Menu {
                    Button("New Bot", systemImage: "plus", action: createTeammate)
                        .disabled(isCreatingTeammate)
                    Button("New Channel — unavailable", systemImage: "person.2") {}
                        .disabled(true)
                    Text("Channels need membership and shared conversation services.")
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("New bot or channel")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if isCreatingTeammate {
                ProgressView("Creating bot…")
                    .controlSize(.small)
                    .font(.caption)
                    .padding(.bottom, 8)
            }
            if let creationError {
                Text(creationError)
                    .font(.caption)
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityLabel(creationError)
            }
            if sidebar.isOrderSaving {
                ProgressView("Saving bot order…")
                    .controlSize(.small)
                    .font(.caption)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("bot-order-saving")
            }
            if let orderError = sidebar.orderError {
                Text(orderError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("bot-order-error")
            }

            ScrollViewReader { proxy in
                List(selection: $sidebar.selection) {
                    ForEach(sidebar.rowModels) { row in
                        TeammateRow(row: row, isSelected: sidebar.selection == row.id)
                            .overlay {
                                BotSidebarDragDropOverlay(
                                    sidebar: sidebar, rowID: row.id,
                                    rowName: row.snapshot.name,
                                    isEnabled: searchOverlay == nil,
                                    horizontalVisualOutset: Self.sidebarHoverOutset,
                                    openBotSettings: openBotSettings,
                                    archiveBot: archiveBot
                                )
                                .padding(.horizontal, -Self.sidebarHoverOutset)
                            }
                            .contextMenu {
                                if openBotSettings != nil || archiveBot != nil {
                                    Section(row.snapshot.name) {
                                        if let openBotSettings {
                                            Button("Open Settings") { [id = row.id] in openBotSettings(id) }
                                                .disabled(searchOverlay != nil)
                                        }
                                        if let archiveBot {
                                            Button("Archive Bot") { [id = row.id] in archiveBot(id) }
                                                .disabled(searchOverlay != nil)
                                        }
                                    }
                                }
                            }
                            .modifier(BotSidebarReorderAccessibility(
                                sidebar: sidebar, rowID: row.id,
                                isEnabled: searchOverlay == nil
                            ))
                            .opacity(sidebar.sidebarDrag?.sourceID == row.id ? 0.55 : 1)
                            .help(sidebar.canReorder ? "Drag to reorder bots" : row.snapshot.name)
                            .tag(row.id)
                            .id(row.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Bot list")
                .task(id: sidebar.creationRevealID) { @MainActor in
                    guard let id = sidebar.creationRevealID else { return }
                    // Let the List install the newly inserted row before asking
                    // its native scroll view to reveal it. No animation or focus
                    // change is needed, and newer navigation always wins.
                    await Task.yield()
                    guard !Task.isCancelled, sidebar.creationRevealID == id else { return }
                    defer { sidebar.completeCreationReveal(id) }
                    guard sidebar.selection == id, sidebar.rowModels.first?.id == id else { return }
                    proxy.scrollTo(id, anchor: .top)
                }
                .overlay {
                    if sidebar.rows.isEmpty, !isCreatingTeammate {
                        VStack(spacing: 12) {
                            Text("Your bots live here")
                                .font(.headline)
                            Text("Start a chat with a new bot.")
                                .font(.callout)
                                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                            Button("New Bot", action: createTeammate)
                                .buttonStyle(.bordered)
                        }
                        .padding(20)
                    }
                }
            }

            VStack(spacing: 2) {
                if let openArchivedBots {
                    Button(action: openArchivedBots) {
                        Label("Archived Bots", systemImage: "archivebox")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-archived-bots")
                }
                Button { focus = .plugins; isShowingPlugins = true } label: {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the plugin catalog")
                .focused($focus, equals: .plugins)
                Divider().padding(.vertical, 5)
                accountMenu
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background {
            if reduceTransparency || colorSchemeContrast == .increased {
                OpenBotsVisualStyle.surface(for: colorScheme)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                Rectangle().fill(.regularMaterial)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Text("Local Preview · no account connected")
            Button("Settings…", systemImage: "gearshape") {
                // Leave per-window responder restoration to AppKit. A later
                // Settings close must never overwrite newer workspace focus.
                focus = .account
                openSettings()
            }
            if let openClaudeSetup {
                Button("Claude setup…", systemImage: "bubble.left") {
                    focus = .account
                    openClaudeSetup()
                }
            }
            Divider()
            Button("Mobile app — unavailable") {}.disabled(true)
            Button("Help & feedback — unavailable") {}.disabled(true)
            Button("Log out — no account connected") {}.disabled(true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenBots Next").font(.callout.weight(.medium))
                    Text("Local Preview")
                        .font(.caption2)
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Open account menu")
        .accessibilityHint("Local Preview; no account connected")
        .focused($focus, equals: .account)
    }

    @ViewBuilder
    private var conversationView: some View {
        if sidebar.selection == nil {
            VStack(spacing: 0) {
                HStack {
                    if !isSidebarVisible { showSidebarButton }
                    Spacer()
                    if !isSidebarVisible { searchHeaderButton }
                }
                .padding(12)
                creationStatusWithoutSidebar
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    Text("Start a conversation")
                        .font(.title2.weight(.medium))
                    Text("Create a bot, or pick one from the list.")
                        .font(.callout)
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    Button("New Bot", action: createTeammate)
                        .buttonStyle(.bordered)
                        .disabled(isCreatingTeammate)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenBotsVisualStyle.canvas(for: colorScheme))
        } else {
            VStack(spacing: 0) {
                conversationHeader
                Divider()
                creationStatusWithoutSidebar
                if conversation.needsLatestPage {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(conversation.isShowingLatestPlaceholder ? "Current message — latest history not loaded" : "Saved search result",
                                  systemImage: conversation.isShowingLatestPlaceholder ? "clock" : "magnifyingglass")
                            Spacer()
                            Button("Return to Latest", action: conversation.requestLatestMessages)
                                .disabled(conversation.isReturningToLatest)
                        }
                        if let notice = conversation.searchNavigationNotice {
                            Text(notice).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(12)
                    Divider()
                }
                transcript
                composer
            }
            .background(OpenBotsVisualStyle.canvas(for: colorScheme))
            .navigationTitle(conversation.title)
        }
    }

    @ViewBuilder
    private var creationStatusWithoutSidebar: some View {
        if !isSidebarVisible {
            if isCreatingTeammate {
                ProgressView("Creating bot…")
                    .controlSize(.small)
                    .padding(12)
            } else if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .accessibilityLabel(creationError)
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            if !isSidebarVisible { showSidebarButton }
            if let selected = selectedTeammate {
                SelectedTeammateHeader(row: selected)
                    .layoutPriority(1)
            } else {
                Text(conversation.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if !isSidebarVisible {
                searchHeaderButton
            }
            Button { focus = .details; toggleDetails() } label: {
                Label(detailsPanel == nil ? "Show bot details" : "Hide bot details", systemImage: "gearshape")
                    .frame(width: 32, height: 32)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            .help(detailsPanel == nil ? "Show bot details and settings" : "Hide bot details")
            .accessibilityValue(detailsPanel == nil ? "Collapsed" : "Expanded")
            .focused($focus, equals: .details)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, OpenBotsVisualStyle.spacing12)
        .frame(minHeight: 72)
        .background {
            // The native titlebar keeps its controls and drag strip. Only this
            // surface continues underneath it; content stays in the safe area.
            OpenBotsVisualStyle.surface(for: colorScheme)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var showSidebarButton: some View {
        Button { isSidebarVisible = true; focus = .sidebarToggle } label: {
            Image(systemName: "sidebar.left").frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Show bot list")
        .accessibilityLabel("Show bot list")
        .focused($focus, equals: .sidebarToggle)
    }

    private var searchHeaderButton: some View {
        Button(action: presentSearch) {
            Label("Search", systemImage: "magnifyingglass")
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .disabled(openSearch == nil)
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityLabel("Search")
        .accessibilityHint("Search bot names and messages saved on this Mac")
        .focused($focus, equals: .search)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    historyControl
                    ForEach(conversation.messageRows) { row in
                        TranscriptRowContainer(
                            row: row,
                            cardInteractions: cardInteractions,
                            isLocalOnly: conversation.isLocalOnly,
                            onStreamingGrowth: {
                                handleStreamingGrowth(rowID: row.id, proxy: proxy)
                            }
                        )
                            .id(row.id)
                            .background {
                                if conversation.searchFocus?.messageID == row.id {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.primary.opacity(0.35), lineWidth: 2)
                                        .padding(-4)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, OpenBotsVisualStyle.spacing24)
                .padding(.vertical, OpenBotsVisualStyle.spacing24)
                .frame(maxWidth: .infinity)
                .background(
                    TranscriptScrollPositionObserver(
                        isNearBottom: $transcriptIsNearBottom
                    )
                    .frame(width: 0, height: 0)
                )
            }
            .onChange(of: conversation.messageRows.map(\.id)) { oldIDs, newIDs in
                guard !conversation.isViewingSearchResult else { return }
                guard let lastID = newIDs.last else { return }
                let isOpening = pendingOpeningConversationID == conversation.conversationID
                guard isOpening || isTailAppend(oldIDs: oldIDs, newIDs: newIDs) else { return }
                let lastMessageIsFromUser = conversation.messageRows.last?.snapshot.isFromUser == true
                if TranscriptScrollFollowPolicy.followsTailAppend(
                    isNearBottom: transcriptIsNearBottom,
                    lastMessageIsFromUser: lastMessageIsFromUser,
                    isOpeningConversation: isOpening
                ) {
                    scrollToLatest(lastID: lastID, proxy: proxy)
                    pendingOpeningConversationID = nil
                } else {
                    hasUnseenLatest = true
                }
            }
            .onChange(of: conversation.historyLoadState) { oldState, newState in
                guard oldState == .loading, newState == .idle,
                      let anchorID = paginationAnchorID,
                      conversation.messageRows.contains(where: { $0.id == anchorID })
                else { return }
                // Restore the pre-prepend first-row anchor after SwiftUI has
                // incorporated the inserted page into the lazy stack.
                Task { @MainActor in
                    proxy.scrollTo(anchorID, anchor: .top)
                    paginationAnchorID = nil
                }
            }
            .onChange(of: transcriptIsNearBottom) { _, isNearBottom in
                if isNearBottom {
                    hasUnseenLatest = false
                }
            }
            .task(id: conversation.conversationID) {
                // The first loaded conversation may predate this view. A
                // switched conversation that is still loading is handled by
                // the message-ID change path above.
                await Task.yield()
                guard !Task.isCancelled, !conversation.isViewingSearchResult else { return }
                guard let lastID = conversation.messageRows.last?.id else { return }
                scrollToLatest(lastID: lastID, proxy: proxy)
                pendingOpeningConversationID = nil
            }
            .task(id: conversation.searchFocus?.requestID) {
                guard let request = conversation.searchFocus else { return }
                await Task.yield()
                guard !Task.isCancelled, conversation.searchFocus == request,
                      conversation.conversationID == request.conversationID,
                      conversation.messageRows.contains(where: { $0.id == request.messageID }) else { return }
                proxy.scrollTo(request.messageID, anchor: .center)
                pendingOpeningConversationID = nil
                transcriptIsNearBottom = false
                hasUnseenLatest = false
            }
            .task(id: conversation.latestFocus?.requestID) {
                guard let request = conversation.latestFocus else { return }
                await Task.yield()
                guard !Task.isCancelled, conversation.latestFocus == request,
                      conversation.conversationID == request.conversationID,
                      !conversation.isViewingSearchResult,
                      conversation.messageRows.contains(where: { $0.id == request.messageID }) else { return }
                scrollToLatest(lastID: request.messageID, proxy: proxy)
            }
            .overlay {
                if conversation.messageRows.isEmpty {
                    VStack(spacing: 10) {
                        Text("What would you like to do?")
                            .font(.title3.weight(.medium))
                        Text(emptyTranscriptDescription)
                            .font(.callout)
                            .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(OpenBotsVisualStyle.spacing24)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasUnseenLatest, let lastID = conversation.messageRows.last?.id {
                    Button {
                        scrollToLatest(lastID: lastID, proxy: proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(OpenBotsVisualStyle.spacing16)
                    .accessibilityHint("Moves to the newest message in this conversation.")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation transcript")
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
    }

    @ViewBuilder
    private var historyControl: some View {
        switch conversation.historyLoadState {
        case .loading:
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading earlier messages…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let reason):
            VStack(spacing: OpenBotsVisualStyle.spacing8) {
                Label("Earlier messages could not be loaded", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry Loading Earlier") {
                    requestEarlierMessages()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(OpenBotsVisualStyle.spacing12)
            .background(
                .quaternary,
                in: RoundedRectangle(
                    cornerRadius: OpenBotsVisualStyle.radiusMedium,
                    style: .continuous
                )
            )
        case .idle:
            if conversation.hasEarlierMessages {
                Button {
                    requestEarlierMessages()
                } label: {
                    Label("Load Earlier", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityHint(
                    "Loads older messages and keeps the current conversation position."
                )
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draftCoordinator {
                ComposerDraftStatusContainer(coordinator: draftCoordinator)
            }
            if let attachmentDraft {
                AttachmentDraftTray(model: attachmentDraft)
            }
            if conversation.textRepliesEnabled {
                if let disclosure = conversation.textReplyContextDisclosure,
                   disclosure.unavailableContext || disclosure.omittedForCandidateLimit
                    || disclosure.omittedForReadLimit || disclosure.omittedForSizeLimit
                    || disclosure.usesPlainCurrentInput {
                    Text("Some earlier messages or saved memory were not included in this reply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let phase = conversation.textReplyPhase, phase != .completed {
                    HStack(alignment: .center, spacing: 8) {
                        if phase.isBusy { ProgressView().controlSize(.small) }
                        Text(phase.description)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if phase.isBusy {
                            Button("Stop", action: conversation.stopCurrentTextReply)
                                .disabled(phase == .stopping)
                                .help("Stop this bot’s current Claude request and keep available saved text.")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Reply status")
                }
                if conversation.hasAttachmentContent {
                    Text("Attachments stay in this draft on this Mac. Remove them from the draft before sending; Claude accepts text only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Message \(conversation.title)", text: $conversation.composerText, axis: .vertical)
                    .modifier(ComposerReturnKeyHandling(conversationID: conversation.conversationID, isFocused: focus == .composer))
                    .font(.system(size: 15))
                    .lineLimit(1...7)
                    .fixedSize(horizontal: false, vertical: true)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .composer)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("message-composer")
                    .accessibilityHint(composerAccessibilityHint)
                    .help(composerAccessibilityHint)
                    .onSubmit {
                        guard conversation.canSend else { return }
                        conversation.sendCurrentText()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                HStack(spacing: 8) {
                    Menu {
                        Button("Attach files…", systemImage: "paperclip") {
                            guard let attachmentDraft else { return }
                            attachmentPickerRequest = AttachmentPickerRequest(draft: attachmentDraft)
                            isSelectingAttachment = true
                        }
                        .disabled(attachmentDraft == nil || conversation.inputAvailability != .ready)
                        Divider()
                        Button("Teach a task — unavailable", systemImage: "graduationcap") {}
                            .disabled(true)
                        Text("Teaching needs a connected runtime and a task-learning workflow.")
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Attach file")
                    .help("Attach one local file; the source is unchanged")
                    Spacer(minLength: 0)
                    Button {} label: {
                        Image(systemName: "mic").font(.system(size: 16))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .accessibilityLabel("Voice input unavailable")
                    .accessibilityHint("Microphone recording and transcription are not connected.")
                    .help("Voice input needs recording and transcription services")
                    Button {
                        conversation.sendCurrentText()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .background(conversation.canSend ? Color.primary : Color.primary.opacity(0.25), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!conversation.canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityLabel(conversation.submissionActionTitle)
                    .accessibilityHint(composerAccessibilityHint)
                    .help(conversation.isLocalOnly ? "Save locally (⌘Return); nothing is sent to Claude" : "Send (⌘Return)")
                }
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Composer actions")
                .accessibilityIdentifier("composer-actions")
            }
            .padding(12)
            .background(
                OpenBotsVisualStyle.elevatedSurface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(OpenBotsVisualStyle.border(for: colorScheme), lineWidth: 0.5)
            }
            if conversation.inputAvailability.unavailableReason != nil || conversation.isLocalOnly {
                Label(composerHelperText, systemImage: composerHelperSymbol)
                    .font(.caption2)
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Message delivery. \(composerHelperText)")
                    .help(conversation.readyDeliveryDescription)
            }
        }
        .frame(maxWidth: 880)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
    }

    private var selectedTeammate: TeammateRowModel? {
        guard let selection = sidebar.selection else { return nil }
        return sidebar.rowModels.first(where: { $0.id == selection })
    }

    private var composerHelperText: String {
        if let reason = conversation.inputAvailability.unavailableReason {
            return reason
        }
        if conversation.isLocalOnly {
            return "Local only · Claude isn’t connected"
        }
        return conversation.readyDeliveryDescription
    }

    private var composerHelperSymbol: String {
        conversation.inputAvailability.unavailableReason == nil
            ? "bolt.horizontal.circle"
            : "pause.circle"
    }

    private var emptyTranscriptDescription: String {
        if let reason = conversation.inputAvailability.unavailableReason {
            return reason
        }
        return conversation.isLocalOnly
            ? conversation.readyDeliveryDescription
            : "Write a message to \(conversation.title)."
    }

    private var composerAccessibilityHint: String {
        if let reason = conversation.inputAvailability.unavailableReason {
            return reason
        }
        return conversation.isLocalOnly
            ? "Press Shift-Enter for a new line. Press Return or Command-Return to save on this Mac. This does not send to Claude or queue later delivery."
            : "Press Shift-Enter for a new line. Press Return or Command-Return to send."
    }

    private func presentSearch() {
        guard let openSearch else { return }
        focus = .search
        openSearch()
    }

    private func requestEarlierMessages() {
        if paginationAnchorID == nil {
            paginationAnchorID = conversation.messageRows.first?.id
        }
        conversation.loadEarlierMessages()
    }

    private func isTailAppend(oldIDs: [UUID], newIDs: [UUID]) -> Bool {
        guard newIDs.count > oldIDs.count else { return false }
        return Array(newIDs.prefix(oldIDs.count)) == oldIDs
    }

    private func handleStreamingGrowth(rowID: UUID, proxy: ScrollViewProxy) {
        guard !conversation.isViewingSearchResult else { return }
        // Growth from an earlier reply must neither move the viewport back to
        // that row nor create a false "Latest" affordance while a newer row is
        // already the conversation tail.
        guard conversation.messageRows.last?.id == rowID else { return }
        if TranscriptTailFollowPolicy.followsStreamingGrowth(
            isNearBottom: transcriptIsNearBottom,
            streamingRowID: rowID,
            tailRowID: conversation.messageRows.last?.id
        ) {
            scrollToLatest(lastID: rowID, proxy: proxy)
        } else {
            hasUnseenLatest = true
        }
    }

    private func scrollToLatest(lastID: UUID, proxy: ScrollViewProxy) {
        let request = TranscriptTailScrollRequest(
            conversationID: conversation.conversationID,
            searchRequestID: conversation.searchFocus?.requestID,
            latestRequestID: conversation.latestFocus?.requestID, tailID: lastID
        )
        Task { @MainActor in
            await Task.yield()
            guard request.matches(conversationID: conversation.conversationID,
                                  searchRequestID: conversation.searchFocus?.requestID,
                                  latestRequestID: conversation.latestFocus?.requestID,
                                  tailID: conversation.messageRows.last?.id) else { return }
            proxy.scrollTo(lastID, anchor: .bottom)
            hasUnseenLatest = false
        }
    }
}

private struct TranscriptRowContainer: View {
    @ObservedObject var row: ChatMessageModel
    let cardInteractions: ConversationCardInteractionModel?
    let isLocalOnly: Bool
    let onStreamingGrowth: @MainActor () -> Void

    var body: some View {
        Group {
            switch row.snapshot.author {
            case .user:
                UserMessageBubble(row: row, cardInteractions: cardInteractions, isLocalOnly: isLocalOnly)
            case .system:
                SystemMessageBubble(row: row, cardInteractions: cardInteractions)
            case .teammate(let identity):
                DetachedTeammateMessageBubble(
                    row: row,
                    identity: identity,
                    cardInteractions: cardInteractions
                )
            }
        }
        .onChange(of: row.snapshot.body) { oldBody, newBody in
            guard row.snapshot.streamState == .streaming,
                  newBody.count > oldBody.count else { return }
            onStreamingGrowth()
        }
    }
}

private struct AttachmentDraftTray: View {
    @ObservedObject var model: AttachmentDraftModel

    var body: some View {
        if !model.rows.isEmpty || (model.isDurable && model.loadState != .ready) {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            if model.isDurable {
                switch model.loadState {
                case .notLoaded, .loading:
                    Text("Loading saved attachments…").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    HStack {
                        Text("Saved attachments couldn’t be loaded.").font(.caption)
                        Button("Retry Attachments") { Task { await model.reload() } }
                    }
                case .ready: EmptyView()
                }
            }
            if !model.rows.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: OpenBotsVisualStyle.spacing8) {
                    ForEach(model.rows) { row in
                        AttachmentDraftChip(
                            row: row,
                            remove: { model.removePresentationRow(id: row.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            Text(model.disclosure)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Attachment status. \(model.disclosure)"
                )
            }
        }
        }
    }
}

private struct AttachmentDraftChip: View {
    let row: AttachmentDraftRow
    let remove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing8) {
            stateSymbol
            VStack(alignment: .leading, spacing: 2) {
                Text(row.selectedDisplayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(stateLabel)
                    .font(.caption2)
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
            }
            Button(action: remove) {
                Label("Remove from Draft", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from this draft; the original file is unchanged")
            .disabled(row.isRemoving)
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing8)
        .padding(.vertical, OpenBotsVisualStyle.spacing4)
        .background(
            .quaternary,
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityDescription)
    }

    @ViewBuilder
    private var stateSymbol: some View {
        switch row.state {
        case .pending:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }

    private var stateLabel: String {
        switch row.state {
        case .pending:
            "Preparing protected copy…"
        case .ready(let receipt):
            "\(Self.byteCount(receipt.byteCount)) • SHA-256 \(receipt.shortHash)"
        case .failed:
            "Couldn’t prepare this file"
        }
    }

    private var stateColor: Color {
        if case .failed = row.state { return .red }
        return .secondary
    }

    private static func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .file
        )
    }
}

private struct TeammateRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @ObservedObject var row: TeammateRowModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            CharacterIdentityView(teammate: row.snapshot, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.snapshot.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let date = row.snapshot.lastActivityAt {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                            .help(date.formatted(date: .complete, time: .shortened))
                    }
                }
                HStack(spacing: 6) {
                    Label(row.snapshot.activity.visibleLabel, systemImage: row.snapshot.activity.symbolName)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.snapshot.unreadCount > 0 {
                        Text(row.snapshot.unreadCount, format: .number)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, OpenBotsVisualStyle.spacing4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.snapshot.accessibilitySummary(locale: locale, timeZone: timeZone)
        )
        .accessibilityValue(unreadAccessibilityValue)
    }

    private var unreadAccessibilityValue: String {
        guard row.snapshot.unreadCount > 0 else { return "No unread messages" }
        return "\(row.snapshot.unreadCount) unread messages"
    }

    private var secondaryText: Color {
        isSelected ? .primary : OpenBotsVisualStyle.secondaryText(for: colorScheme)
    }
}

private struct SelectedTeammateHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var row: TeammateRowModel

    var body: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing12) {
            CharacterIdentityView(teammate: row.snapshot, size: 42)
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text(row.snapshot.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(row.snapshot.activity.visibleLabel)
                    .font(.caption)
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.snapshot.name), \(row.snapshot.role), \(row.snapshot.activity.visibleLabel)"
        )
        .accessibilityAddTraits(.isHeader)
    }
}

private struct DetachedTeammateMessageBubble: View {
    @ObservedObject var row: ChatMessageModel
    let identity: TeammateIdentitySnapshot
    let cardInteractions: ConversationCardInteractionModel?

    var body: some View {
        teammateMessageLayout(
            message: row.snapshot,
            identity: identity,
            cardInteractions: cardInteractions
        )
    }
}

private struct UserMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var row: ChatMessageModel
    let cardInteractions: ConversationCardInteractionModel?
    let isLocalOnly: Bool

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: OpenBotsVisualStyle.spacing4) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                MessageTimestampView(message: row.snapshot)
                MessageContent(
                    message: row.snapshot,
                    background: OpenBotsVisualStyle.brandWash(for: colorScheme),
                    cardInteractions: cardInteractions,
                    isLocalOnly: isLocalOnly
                )
            }
        }
        .modifier(
            MessageRowAccessibilityModifier(
                message: row.snapshot
            )
        )
    }
}

struct SystemMessageBubble: View {
    @ObservedObject var row: ChatMessageModel
    let cardInteractions: ConversationCardInteractionModel?

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            if row.snapshot.isInformationalSystemStatus {
                content
            } else {
                content
                    .padding(.horizontal, OpenBotsVisualStyle.spacing12)
                    .padding(.vertical, OpenBotsVisualStyle.spacing8)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(
                            cornerRadius: OpenBotsVisualStyle.radiusMedium,
                            style: .continuous
                        )
                    )
            }
            Spacer(minLength: 40)
        }
        .modifier(
            MessageRowAccessibilityModifier(
                message: row.snapshot
            )
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label(row.snapshot.author.visibleName, systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MessageTimestampView(message: row.snapshot)
            TranscriptMessagePartsView(
                message: row.snapshot,
                textStyle: .system,
                cardInteractions: cardInteractions
            )
        }
    }
}

@MainActor
@ViewBuilder
private func teammateMessageLayout(
    message: ChatMessageSnapshot,
    identity: TeammateIdentitySnapshot,
    cardInteractions: ConversationCardInteractionModel?
) -> some View {
    let activity = messageActivity(message)
    HStack(alignment: .top, spacing: OpenBotsVisualStyle.spacing12) {
        CharacterIdentityView(
            teammate: TeammateRowSnapshot(identity: identity, activity: activity),
            size: 36
        )
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            HStack(spacing: OpenBotsVisualStyle.spacing8) {
                Text(identity.name)
                    .font(.caption.weight(.semibold))
                    .fontDesign(.rounded)
                if message.streamState == .streaming {
                    Label(activity.visibleLabel, systemImage: activity.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .failed = message.streamState {
                    Label(activity.visibleLabel, systemImage: activity.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            MessageTimestampView(message: message)
            MessageContent(message: message, cardInteractions: cardInteractions)
        }
        Spacer(minLength: 56)
    }
    .modifier(
        MessageRowAccessibilityModifier(
            message: message
        )
    )
}

private func messageActivity(_ message: ChatMessageSnapshot) -> TeammateActivityState {
    switch message.streamState {
    case .streaming:
        .speaking
    case .failed:
        .errorOrAttention
    case .notStreaming, .complete:
        .idle
    }
}

private struct MessageContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessageSnapshot
    var background: Color?
    var cardInteractions: ConversationCardInteractionModel?
    var isLocalOnly: Bool

    init(
        message: ChatMessageSnapshot,
        background: Color? = nil,
        cardInteractions: ConversationCardInteractionModel? = nil,
        isLocalOnly: Bool = false
    ) {
        self.message = message
        self.background = background
        self.cardInteractions = cardInteractions
        self.isLocalOnly = isLocalOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            TranscriptMessagePartsView(
                message: message,
                cardInteractions: cardInteractions
            )
            deliveryLabel
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            background ?? OpenBotsVisualStyle.surface(for: colorScheme),
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
            .stroke(OpenBotsVisualStyle.border(for: colorScheme).opacity(message.isFromUser ? 0 : 0.5), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var deliveryLabel: some View {
        if let notice = message.deliveryNotice {
            let isRoutineSuccess = notice == "Accepted by Claude" || notice == "Claude reply saved"
                || (message.delivery == .sent && (notice == "Saved locally · not sent to Claude"
                    || notice == "Saved Claude turn outcome"))
            if !isRoutineSuccess {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            switch message.delivery {
            case .pending:
                Label(isLocalOnly ? "Saving" : "Sending", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .sent:
                EmptyView()
            case .failed(let reason):
                Label("\(isLocalOnly ? "Not saved" : "Not sent"): \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Every message retains native readable and actionable descendants, including
/// file Preview/Reveal buttons. Metadata names the group rather than hiding
/// those controls behind an all-in-one text summary.
private struct MessageRowAccessibilityModifier: ViewModifier {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    let message: ChatMessageSnapshot

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message.accessibilityGroupLabel(locale: locale, timeZone: timeZone))
            .accessibilityIdentifier("message-\(message.id)")
    }
}

private struct MessageTimestampView: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    let message: ChatMessageSnapshot

    var body: some View {
        Text(message.timestamp, format: .dateTime.hour().minute())
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(WorkspaceAccessibilityMetadata.timestamp(message.timestamp, locale: locale, timeZone: timeZone))
            .accessibilityIdentifier("message-timestamp-\(message.id)")
    }
}
