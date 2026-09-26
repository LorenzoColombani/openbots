import OpenBotsServices
import AppKit
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

private struct TranscriptEndAnchor: Hashable {
    let conversationID: UUID?
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

enum NormalBusyFeedbackPolicy {
    static func isWorking(_ activity: TeammateActivityState) -> Bool {
        activity == .thinkingOrWorking || activity == .speaking
    }
    static func showsCaption(for phase: ClaudeTextReplyPhase) -> Bool {
        switch phase {
        case .sending, .responding, .saving, .completed: false
        case .stopping, .correcting, .stopped, .failed: true
        }
    }
    /// The activity beat the service writes ("Ran `ls` in Yogurt"), fit for
    /// the line beside the working creature: no code ticks, one line, or
    /// nothing when there is nothing to say. Working feedback stays in the
    /// avatars; this is the words a long turn was missing.
    static func activityCaption(_ activity: String?) -> String? {
        guard let activity else { return nil }
        let line = activity.replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }
    static func hidesPlaceholder(_ message: ChatMessageSnapshot) -> Bool {
        if case .failed = message.delivery { return false }
        if case .failed = message.streamState { return false }
        // Production projects a text turn's empty/status-only reply as an
        // OpenBots system record. Authorship is not evidence of a failure;
        // only these exact pending transport statuses are presentation noise.
        switch message.author {
        case .teammate: break
        case .system(let label): guard label == "OpenBots" else { return false }
        case .user: return false
        }
        guard message.delivery == .pending || message.streamState == .streaming else { return false }
        return message.parts.allSatisfy { part in
            guard case .status(let text) = part.content else { return false }
            return ["Waiting for Claude's reply.", "Preparing reply…", "Receiving response…", "Saving reply…"].contains(text)
        }
    }
    static func deliveryNotice(for message: ChatMessageSnapshot) -> String? {
        guard let notice = message.deliveryNotice else { return nil }
        let routine = ["Accepted by Claude", "Claude reply saved", "Saving locally…",
                       "Saved locally · preparing Claude", "Handoff brief saved · preparing Claude",
                       "Actual Claude reply · partial text saved", "Claude reply in progress · partial text saved"]
        if routine.contains(notice) { return nil }
        // The unverified fallback is what every message with no recorded
        // delivery carries; under a sent one it only worried the user.
        if message.delivery == .sent,
           ["Saved locally · not sent to Claude", "Saved Claude turn outcome", "Saved on this Mac",
            "Saved on this Mac · Claude delivery not verified"].contains(notice) { return nil }
        return notice
    }
}

@MainActor
enum TeamRosterAvatarPolicy {
    static let maximumFaces = 3
    static func rows(for team: TeamRowSnapshot, from rows: [TeammateRowModel]) -> [TeammateRowModel] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return team.members.compactMap { byID[$0.id] }
    }
    static func accessibilityLabel(for team: TeamRowSnapshot) -> String {
        "\(team.name), team, \(team.memberSummary). Members: \(team.memberNames.joined(separator: ", "))"
    }
    /// A member's state on this team's own surfaces: only
    /// this conversation's turn moves them; work in their own chat stays there.
    static func activity(of memberID: UUID, in workingAvatar: ConversationWorkingAvatar?) -> TeammateActivityState {
        guard let workingAvatar, workingAvatar.teammateID == memberID else { return .idle }
        return workingAvatar.activity
    }
    /// For surfaces drawn in any chat: `team` is nil outside a team (follow the
    /// bot's own row, so nil), else who is working in that team, if anyone.
    static func override(of memberID: UUID, team: ConversationWorkingAvatar??) -> TeammateActivityState? {
        team.map { activity(of: memberID, in: $0) }
    }
}

/// The real roster supplies every face. A missing identity contributes to the
/// count, never to an invented avatar. Each live face observes its own bot.
struct TeamRosterAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    let row: TeamRowSnapshot
    let memberRows: [TeammateRowModel]
    var fallbackMembers: [TeammateIdentitySnapshot] = []
    var isSelected = false
    var showsWorkingEffects = true
    /// Who is working in this team's conversation right now, if anyone.
    var workingAvatar: ConversationWorkingAvatar? = nil

    private var representedIDs: [UUID] {
        row.members.map(\.id).filter { id in
            memberRows.contains { $0.id == id } || fallbackMembers.contains { $0.id == id }
        }.prefix(TeamRosterAvatarPolicy.maximumFaces).map { $0 }
    }
    var body: some View {
        let ids = representedIDs
        ZStack {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let size: CGFloat = ids.count == 1 ? 42 : ids.count == 2 ? 29 : 25
                Group {
                    if let live = memberRows.first(where: { $0.id == id }) {
                        LiveRosterFace(row: live, size: size, isSelected: isSelected,
                            showsWorkingEffects: showsWorkingEffects,
                            activityOverride: TeamRosterAvatarPolicy.activity(of: live.id, in: workingAvatar),
                            conversationID: row.conversationID)
                    } else if let identity = fallbackMembers.first(where: { $0.id == id }) {
                        CharacterIdentityView(identity: identity,
                            activity: TeamRosterAvatarPolicy.activity(of: identity.id, in: workingAvatar),
                            size: size, isSelected: isSelected,
                            showsWorkingEffects: showsWorkingEffects,
                            conversationID: row.conversationID)
                    }
                }
                .offset(offset(index: index, count: ids.count))
            }
            if ids.isEmpty {
                Text(row.members.count, format: .number).font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.quaternary, in: Circle())
                    .accessibilityLabel("\(row.members.count) members")
            } else if row.members.count > ids.count {
                Text("+\(row.members.count - ids.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(OpenBotsVisualStyle.canvas(for: colorScheme), in: Capsule())
                    .frame(width: 42, height: 42, alignment: .bottomTrailing)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 42, height: 42)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TeamRosterAvatarPolicy.accessibilityLabel(for: row))
        .accessibilityIdentifier("team-roster-avatar-\(row.id.uuidString)")
    }
    private func offset(index: Int, count: Int) -> CGSize {
        if count == 1 { return .zero }
        if count == 2 { return index == 0 ? CGSize(width: -7, height: -6) : CGSize(width: 7, height: 7) }
        return [CGSize(width: -9, height: -8), CGSize(width: 9, height: -8), CGSize(width: 0, height: 10)][index]
    }
}

private struct LiveRosterFace: View {
    @ObservedObject var row: TeammateRowModel
    let size: CGFloat
    var isSelected = false
    var showsWorkingEffects = true
    /// Conversation-scoped activity. Nil falls back to idle on team
    /// surfaces so a DM turn never animates this face.
    var activityOverride: TeammateActivityState? = nil
    var conversationID: UUID? = nil
    var body: some View {
        let activity = activityOverride ?? .idle
        CharacterIdentityView(
            identity: row.snapshot.identity,
            activity: activity,
            size: size,
            isSelected: isSelected,
            showsWorkingEffects: showsWorkingEffects,
            conversationID: conversationID
        )
        .accessibilityIdentifier(conversationID.map { "team-roster-face-\(row.id.uuidString)-in-\($0.uuidString)" }
            ?? "team-roster-face-\(row.id.uuidString)")
    }
}

/// Work-audit legs have no transcript bubble. The live member still has a face
/// in the main conversation, including after an acknowledgement changes it to
/// speaking. The creature owns motion; the text here names the person only.
struct WorkingBotIndicator: View {
    @ObservedObject var row: TeammateRowModel
    /// When set, use conversation-scoped activity. When nil, follow
    /// the live row so sidebar-driven updates still reach this indicator.
    var activityOverride: TeammateActivityState? = nil
    var conversationID: UUID
    @State private var isHoveringAvatar = false

    private var activity: TeammateActivityState { activityOverride ?? row.snapshot.activity }

    var body: some View {
        if NormalBusyFeedbackPolicy.isWorking(activity) || activity == .waitingForUser {
            HStack(spacing: 6) {
                CharacterIdentityView(
                    identity: row.snapshot.identity,
                    activity: activity,
                    size: 32,
                    conversationID: conversationID
                )
                .onHover { isHoveringAvatar = $0 }
                Text(isHoveringAvatar && NormalBusyFeedbackPolicy.isWorking(activity)
                     ? "\(row.snapshot.name) is working" : row.snapshot.name)
                    .font(.callout).lineLimit(1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(row.snapshot.name), \(activity.visibleLabel)")
            .accessibilityIdentifier("conversation-working-bot-\(row.id.uuidString)-in-\(conversationID.uuidString)")
        }
    }
}

private struct LiveTeamMemberSettingsButton: View {
    @ObservedObject var row: TeammateRowModel
    /// The member's state in this team's conversation, never its own chat's.
    let activity: TeammateActivityState
    let open: @MainActor (UUID) -> Void
    var body: some View {
        Button { open(row.id) } label: {
            HStack(spacing: OpenBotsVisualStyle.spacing4) {
                CharacterIdentityView(identity: row.snapshot.identity, activity: activity, size: 22,
                    showsWorkingEffects: false).accessibilityHidden(true)
                Text(row.snapshot.name).font(.callout).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(row.snapshot.name)’s settings")
        .accessibilityValue(activity.visibleLabel)
        .accessibilityHint("Opens this bot’s own settings without leaving the team conversation")
        .help("Open \(row.snapshot.name)’s settings")
        .accessibilityIdentifier("team-member-settings-\(row.id.uuidString)")
    }
}

public struct OpenBotsRootView: View {
    // Native sidebar cells add eight points of horizontal inset compared with
    // the former plain List. Keep the full hover width without widening input.
    private static let sidebarHoverOutset = OpenBotsVisualStyle.spacing12 + OpenBotsVisualStyle.spacing8

    fileprivate enum FocusDestination: Hashable {
        case composer, search, details, account, sidebarToggle
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
    @State private var detailsSelectionID: UUID?

    private let attachmentDraft: AttachmentDraftModel?
    private let draftCoordinator: WorkspaceDraftCoordinator?
    private let cardInteractions: ConversationCardInteractionModel?
    private let createTeammate: @MainActor () -> Void
    private let createTeam: (@MainActor () -> Void)?
    private let configureTeam: (@MainActor (UUID) -> Void)?
    /// The open team's members whose own settings this screen can open.
    private let teamMembers: [TeammateIdentitySnapshot]
    /// Its hidden members, shown in the header by face and name only.
    private let hiddenTeamMembers: [TeammateIdentitySnapshot]
    private let openMemberSettings: (@MainActor (UUID) -> Void)?
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
    private let archiveTeam: (@MainActor (UUID) -> Void)?
    private let pinBot: (@MainActor (UUID) -> Void)?
    private let hideBot: (@MainActor (UUID) -> Void)?
    private let deleteBot: (@MainActor (UUID) -> Void)?
    private let openHiddenBots: (@MainActor () -> Void)?
    /// Opens one bot's Access sheet, every switch it has in one place.
    private let openBotAccess: (@MainActor (UUID) -> Void)?
    /// Opens the conversation's "what happened" record.
    private let openWorkRecord: (@MainActor () -> Void)?

    public init(
        sidebar: SidebarModel,
        conversation: ConversationModel,
        attachmentDraft: AttachmentDraftModel? = nil,
        draftCoordinator: WorkspaceDraftCoordinator? = nil,
        cardInteractions: ConversationCardInteractionModel? = nil,
        createTeammate: @escaping @MainActor () -> Void,
        createTeam: (@MainActor () -> Void)? = nil,
        configureTeam: (@MainActor (UUID) -> Void)? = nil,
        teamMembers: [TeammateIdentitySnapshot] = [],
        hiddenTeamMembers: [TeammateIdentitySnapshot] = [],
        openMemberSettings: (@MainActor (UUID) -> Void)? = nil,
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
        archiveBot: (@MainActor (UUID) -> Void)? = nil,
        archiveTeam: (@MainActor (UUID) -> Void)? = nil,
        pinBot: (@MainActor (UUID) -> Void)? = nil,
        hideBot: (@MainActor (UUID) -> Void)? = nil,
        deleteBot: (@MainActor (UUID) -> Void)? = nil,
        openHiddenBots: (@MainActor () -> Void)? = nil,
        openBotAccess: (@MainActor (UUID) -> Void)? = nil,
        openWorkRecord: (@MainActor () -> Void)? = nil
    ) {
        self.sidebar = sidebar
        self.conversation = conversation
        self.attachmentDraft = attachmentDraft
        self.draftCoordinator = draftCoordinator
        self.cardInteractions = cardInteractions
        self.createTeammate = createTeammate
        self.createTeam = createTeam
        self.configureTeam = configureTeam
        self.teamMembers = teamMembers
        self.hiddenTeamMembers = hiddenTeamMembers
        self.openMemberSettings = openMemberSettings
        self.openSettings = openSettings
        self.detailOverride = detailOverride
        self.searchOverlay = searchOverlay
        self.detailsPanel = detailsPanel
        self.toggleDetails = toggleDetails
        self.openSearch = openSearch
        self.isCreatingTeammate = isCreatingTeammate
        self.creationError = creationError
        self.openClaudeSetup = openClaudeSetup
        self.openWorkRecord = openWorkRecord
        self.openArchivedBots = openArchivedBots
        self.openBotSettings = openBotSettings
        self.archiveBot = archiveBot
        self.archiveTeam = archiveTeam
        self.pinBot = pinBot
        self.hideBot = hideBot
        self.deleteBot = deleteBot
        self.openHiddenBots = openHiddenBots
        self.openBotAccess = openBotAccess
        self._paginationAnchorID = State(initialValue: nil)
    }

    public var body: some View {
        let _ = LayoutStormCounters.hit("root.body")
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
        .onPreferenceChange(WorkspaceDetailMinimumWidthKey.self) { LayoutStormCounters.hit("detailMinimumWidth", detail: "\($0)"); detailMinimumWidth = $0 }
        .tint(OpenBotsVisualStyle.brandAccent(for: colorScheme))
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
                    if let createTeam {
                        Button("New Team…", systemImage: "person.2", action: createTeam)
                    } else {
                        Button("New Team… — needs two bots", systemImage: "person.2") {}.disabled(true)
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("New bot or team")
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
                    // Teams sit above the bots. While no team exists the
                    // bots stay one unlabelled block, so a single list
                    // never gains a header row it does not need. The "Bots"
                    // header waits for a bot to put under it: a team whose
                    // members are all archived leaves no bot row, and a
                    // header over nothing names an empty list.
                    if sidebar.teamRows.isEmpty {
                        botSidebarRows
                    } else {
                        Section("Teams") { teamSidebarRows }
                        if !sidebar.rowModels.isEmpty {
                            Section("Bots") { botSidebarRows }
                        }
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
                    // The invitation covers the whole list, so it is only
                    // shown while the list holds nothing at all: a team the
                    // user can still click must not sit underneath it. The
                    // toolbar's New menu offers a bot either way.
                    if sidebar.isEmpty, !isCreatingTeammate {
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
                        Label("Archived", systemImage: "archivebox")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-archived-bots")
                }
                if let openHiddenBots {
                    Button(action: openHiddenBots) {
                        Label("Hidden Bots", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-hidden-bots")
                }
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

    @ViewBuilder
    private var botSidebarRows: some View {
        ForEach(sidebar.rowModels) { row in
            TeammateRow(row: row, isSelected: sidebar.selection == row.id)
                .overlay {
                    BotSidebarDragDropOverlay(
                        sidebar: sidebar, rowID: row.id,
                        rowName: row.snapshot.name,
                        isEnabled: searchOverlay == nil,
                        horizontalVisualOutset: Self.sidebarHoverOutset,
                        openBotSettings: openBotSettings,
                        archiveBot: archiveBot,
                        pinBot: pinBot,
                        hideBot: hideBot,
                        deleteBot: deleteBot
                    )
                    .padding(.horizontal, -Self.sidebarHoverOutset)
                }
                .contextMenu {
                    if openBotSettings != nil || archiveBot != nil || openBotAccess != nil
                        || pinBot != nil || hideBot != nil || deleteBot != nil {
                        Section(row.snapshot.name) {
                            if let openBotSettings {
                                Button("Open Settings") { [id = row.id] in openBotSettings(id) }
                                    .disabled(searchOverlay != nil)
                            }
                            if let openBotAccess {
                                // Every switch this bot has, one sheet, for
                                // the row it was opened on, selected or not.
                                Button("Access…") { [id = row.id] in openBotAccess(id) }
                                    .disabled(searchOverlay != nil)
                            }
                            if let pinBot {
                                Button(row.snapshot.isPinned ? "Unpin Bot" : "Pin Bot") { [id = row.id] in pinBot(id) }
                                    .disabled(searchOverlay != nil)
                            }
                            if let hideBot {
                                Button("Hide Bot") { [id = row.id] in hideBot(id) }
                                    .disabled(searchOverlay != nil)
                            }
                            if let archiveBot {
                                Button("Archive Bot") { [id = row.id] in archiveBot(id) }
                                    .disabled(searchOverlay != nil)
                            }
                            if let deleteBot {
                                Button("Delete Bot", role: .destructive) { [id = row.id] in deleteBot(id) }
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

    @ViewBuilder
    private var teamSidebarRows: some View {
        ForEach(sidebar.teamRows) { row in
            TeamRow(row: row, memberRows: TeamRosterAvatarPolicy.rows(for: row, from: sidebar.teamMemberRowModels),
                    isSelected: sidebar.selection == row.id,
                    workingAvatar: sidebar.workingAvatarByConversation[row.conversationID])
                .contextMenu {
                    Section(row.name) {
                        // The action takes the row's own team, so the menu
                        // edits the team it was opened on, selected or not.
                        Button("Team Settings") { configureTeam?(row.id) }
                            .disabled(configureTeam == nil)
                        if let archiveTeam {
                            Button("Archive Team") { archiveTeam(row.id) }
                        }
                    }
                }
                .help(row.name)
                .tag(row.id)
                .id(row.id)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
    }

    private var accountMenu: some View {
        Menu {
            // True in every state. This view holds only a closure that opens
            // Claude setup; whether anyone is signed in lives in
            // ClaudeSetupModel, so the header may not claim it.
            Text("Runs on this Mac.")
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
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                // The displayed name alone: "Preview" stays out of it.
                Text("OpenBots Next").font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Open account menu")
        .accessibilityHint("Runs on this Mac")
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
                composerSection
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
                Button { focus = .details; toggleDetails() } label: {
                    SelectedTeammateHeader(row: selected)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help(detailsPanel == nil ? "Show details" : "Hide details")
                .accessibilityIdentifier("conversation.details")
                .accessibilityValue(detailsPanel == nil ? "Collapsed" : "Expanded")
                .focused($focus, equals: .details)
                .layoutPriority(1)
            } else if let team = selectedTeamRow {
                SelectedTeamHeader(row: team, memberRows: TeamRosterAvatarPolicy.rows(for: team, from: sidebar.teamMemberRowModels), members: teamMembers,
                                   hiddenMembers: hiddenTeamMembers, openMemberSettings: openMemberSettings,
                                   workingAvatar: sidebar.workingAvatarByConversation[team.conversationID]).layoutPriority(1)
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
            if let openWorkRecord {
                Button(action: openWorkRecord) {
                    // Said in words: an unlabelled icon was
                    // never found.
                    Label("What happened", systemImage: "list.bullet.rectangle")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.plain)
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                .help("What happened here: briefs between bots, the cards you answered, what a bot did on the Mac")
                .accessibilityIdentifier("conversation.record")
            }
            if selectedTeamRow == nil {
                Button { if let selected = selectedTeammate { openBotSettings?(selected.id) } } label: {
                    Label("Bot settings", systemImage: "gearshape")
                        .frame(width: 32, height: 32)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                .disabled(openBotSettings == nil || selectedTeammate == nil)
                .help("Edit this bot’s profile and preferences")
                .accessibilityIdentifier("conversation.bot-settings")
            } else {
                // A bot's details panel has no team counterpart, so the same
                // slot opens the team's own settings instead of staying blank.
                Button { if let row = selectedTeamRow { configureTeam?(row.id) } } label: {
                    Label("Team Settings", systemImage: "gearshape")
                        .frame(width: 32, height: 32)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                .disabled(configureTeam == nil || selectedTeamRow == nil)
                .help("Edit this team's name, members and lead")
                .accessibilityIdentifier("team-settings")
            }
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
            let _ = LayoutStormCounters.hit("transcript.body")
            ScrollView {
                // A plain stack, deliberately. The transcript was once a
                // `LazyVStack`, and twice the installed app froze inside one
                // SwiftUI transaction flush that never drained: once when the
                // details pane narrowed the column under a reader at the end, and
                // once when the user scrolled up by trackpad after a team research
                // (main thread at 100 %, memory climbing 5 MB/s to 1.9 GB, sampled
                // twice). Both samples show the lazy
                // stack's own machinery looping — rows placed and un-placed
                // (`initialPlacement`/`finalPlacement`), their estimates re-measured,
                // the scroll anchor translated for the changed estimate, and a
                // prefetch signal queueing the next transaction inside the same
                // flush — while the labels themselves answered from their caches.
                // The loaded page is bounded and every row's height is cached per
                // width, so laying out every row costs one text layout per row per
                // width; a lazy stack saved that and cost the app itself.
                VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    historyControl
                    ForEach(conversation.messageRows) { row in
                        TranscriptRowContainer(
                            row: row,
                            teammate: liveTeammate(for: row.snapshot),
                            teamWorkingAvatar: shownTeamWorkingAvatar,
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
                .padding(.top, OpenBotsVisualStyle.spacing24)
                // Latest means the document's end, including its existing
                // bottom inset. A last-message anchor stops 24 points short
                // and can undo a native scroll-to-end when queued work lands.
                Color.clear
                    .frame(height: OpenBotsVisualStyle.spacing24)
                    .id(TranscriptEndAnchor(conversationID: conversation.conversationID))
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .background(
                    TranscriptScrollPositionObserver(
                        isNearBottom: $transcriptIsNearBottom
                    )
                    .frame(width: 0, height: 0)
                )
            }
            // A reader at the end of the transcript stays at the end when the rows
            // re-wrap (details pane opening, window width). Without this anchor the
            // scroll view's own end-of-content offset adjustment and the lazy stack's
            // placement of the last rows never agreed once the transcript column
            // narrowed under a reader at the very end: every transaction queued the
            // next inside one run-loop turn, main thread at 100 %, memory climbing
            // (the same conversation scrolled to the top opened the pane without
            // incident).
            .defaultScrollAnchor(.bottom)
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

    private var composerSection: some View {
        ComposerView(
            conversation: conversation,
            composer: conversation.composer,
            participants: selectedTeamRow.map { TeamRosterAvatarPolicy.rows(for: $0, from: sidebar.teamMemberRowModels) }
                ?? selectedTeammate.map { [$0] } ?? [],
            teamWorkingAvatar: shownTeamWorkingAvatar,
            attachmentDraft: attachmentDraft,
            draftCoordinator: draftCoordinator,
            composerPrompt: composerPrompt,
            focus: $focus,
            isSelectingAttachment: $isSelectingAttachment,
            attachmentPickerRequest: $attachmentPickerRequest
        )
    }

    private var selectedTeammate: TeammateRowModel? {
        guard let selection = sidebar.selection else { return nil }
        return sidebar.rowModels.first(where: { $0.id == selection })
    }

    /// A hidden member's messages in its team keep their live face, which the
    /// team's turn moves.
    private func liveTeammate(for message: ChatMessageSnapshot) -> TeammateRowModel? {
        guard case .teammate(let identity) = message.author else { return nil }
        return sidebar.teamMemberRowModels.first { $0.id == identity.id }
    }

    /// Nil unless the conversation on screen is a team's; then who is working
    /// in it, if anyone. Read from the conversation shown, not the selection,
    /// which moves first while the new conversation is still loading.
    private var shownTeamWorkingAvatar: ConversationWorkingAvatar?? {
        guard let id = conversation.conversationID,
              sidebar.teamRows.contains(where: { $0.conversationID == id }) else { return nil }
        return .some(sidebar.workingAvatarByConversation[id])
    }

    private var selectedTeamRow: TeamRowSnapshot? {
        guard let selection = sidebar.selection else { return nil }
        return sidebar.teamRows.first(where: { $0.id == selection })
    }

    private var composerPrompt: String {
        guard let team = selectedTeamRow else { return "Message \(conversation.title)" }
        return "Message \(team.name) — \(team.leadName) answers unless you @mention a member"
    }

    private var emptyTranscriptDescription: String {
        if let reason = conversation.inputAvailability.unavailableReason {
            return reason
        }
        return conversation.isLocalOnly
            ? conversation.readyDeliveryDescription
            : "Write a message to \(conversation.title)."
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
        LayoutStormCounters.hit("scrollToLatest")
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
            proxy.scrollTo(TranscriptEndAnchor(conversationID: request.conversationID), anchor: .bottom)
            hasUnseenLatest = false
        }
    }
}

/// Which of an approval card's buttons may be pressed.
///
/// Approve, and Allow for this turn beside it, wait while the end of the
/// card's words is known to be past its box: the box holds nine lines of its
/// type, a trackpad hides the scroller, and a text whose second paragraph sat
/// below the fold could be approved with only its first line ever on screen.
/// Deny never waits: refusing unread is always
/// safe.
///
/// `endSeen` is nil until the box has measured words laid out, and nil waits
/// for nothing. No hint flashes on a card whose words fit, and a box that
/// could not be measured leaves Approve as it was before the wait existed,
/// rather than dead, with no hint, on every card in the app.
///
/// Chosen over letting the box grow to fit: an accepted text can still run
/// to twelve hundred lines, so any box that grows needs a ceiling, and a
/// ceiling brings the fold back.
struct ApprovalCardButtons: Equatable {
    let expired: Bool
    let endSeen: Bool?
    var approveEnabled: Bool { !expired && endSeen != false }
    var denyEnabled: Bool { !expired }
    var showsScrollHint: Bool { !expired && endSeen == false }
}

/// How long a card still waits, in words: "About 4 minutes left", never a clock
/// time to subtract. The card redraws on a 30-second tick that lands on the
/// deadline itself, so its buttons grey the moment time is up.
enum CardDeadlineWording {
    enum Kind { case action, handOver, missingFile, question }

    static let tick: TimeInterval = 30

    static func timeLeft(until expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Time is up" }
        guard remaining >= 60 else { return "Less than a minute left" }
        let minutes = Int((remaining / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "About a minute left" : "About \(minutes) minutes left" }
        let hours = Int((remaining / 3_600).rounded())
        return hours == 1 ? "About an hour left" : "About \(hours) hours left"
    }

    static func line(_ kind: Kind, expiresAt: Date, now: Date) -> String {
        let expired = expiresAt <= now
        let left = timeLeft(until: expiresAt, now: now)
        switch kind {
        case .action:
            return expired ? "Time is up, so the action is not done." : "\(left). Then the action is not done."
        case .handOver:
            return expired ? "Time is up, so the bot is told you did not finish."
                : "Nothing of Control this Mac runs until you hand the screen back. \(left). Then the bot is told you did not finish."
        case .missingFile:
            return expired ? "Time is up, so the reply does not run. The results wait for your next message."
                : "\(left). Then the reply does not run, and the results wait for your next message."
        case .question:
            return expired ? "Time is up, so the bot goes on without an answer."
                : "\(left). Then the bot goes on without an answer."
        }
    }

    /// The start of the 30-second schedule: no later than now, and a whole
    /// number of ticks before the deadline, so one tick falls on it.
    static func tickStart(expiresAt: Date, now: Date) -> Date {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return now }
        return expiresAt.addingTimeInterval(-tick * (remaining / tick).rounded(.up))
    }
}

/// What a ready file chip says: its size and what kind of
/// file it is, never a hash.
enum AttachmentChipWording {
    static func readyLine(displayName: String, byteCount: UInt64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
        let fileExtension = (displayName as NSString).pathExtension
        guard !fileExtension.isEmpty,
              let kind = UTType(filenameExtension: fileExtension)?.localizedDescription, !kind.isEmpty else { return size }
        return "\(size) • \(kind)"
    }
}

/// What "Allow for this turn" says it allows, in words true of the card.
///
/// A folder card's allowance is the tool kind in that one folder. Control this
/// Mac shares one scope across every card of the connector, and its "folder" is
/// the words "your Mac", so the folder sentence read "Lets this bot do this in
/// your Mac" when the allowance covers every reviewed Control this Mac action
/// until the reply ends. Only a connector card can
/// carry that scope, so a real folder that happens to share the name keeps the
/// folder sentence.
enum TurnAllowanceWording {
    static func help(toolName: String, folder: String) -> String {
        if ClaudeTextConnectorApprovalPolicy.isConnectorTool(toolName),
           folder == ClaudeTextMacControlApprovalPolicy.turnScope.folderName {
            // What the card beside this button says, and what the policy does: only
            // Control this Mac's own quit and open actions ask every time, while a
            // click, a keystroke or a menu can still quit an app or open a link.
            return "Lets this bot keep seeing your screen, clicking, typing and pressing keys in your apps until "
                + "this reply ends, without asking again: its own quit and open still ask, but a click or a "
                + "shortcut can still close or quit things, or open a link. Stop ends it at once."
        }
        // Run-code cards key the allowance on the script file name.
        if folder.contains("."), !folder.hasSuffix(".") {
            return "Lets this bot rerun \(folder) for the rest of this turn without asking again."
        }
        return "Lets this bot do this in \(folder) for the rest of this turn without asking again."
    }
}

/// The words of an approval card in their box, which scrolls rather than
/// reflowing the composer, and reports once their end has been in view. Once
/// seen stays seen: scrolling back up to reread does not take Approve away.
struct ApprovalDetailBox: View {
    static let maximumHeight: CGFloat = 140
    let detail: String
    @Binding var endSeen: Bool?
    /// Code type only for a shell command or a script run; every other card's
    /// words are prose.
    var codeType = false

    static func usesCodeType(toolName: String) -> Bool { toolName == "Bash" }
    /// The words' own height, once laid out.
    @State private var wordsHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(detail).font(.system(.callout, design: codeType ? .monospaced : .default)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ApprovalDetailEndObserver { atEnd in
                        if atEnd {
                            if endSeen != true { endSeen = true }
                        } else if endSeen == nil {
                            endSeen = false
                        }
                    }
                    .frame(width: 0, height: 0)
                )
                .background(GeometryReader { words in
                    Color.clear.preference(key: ApprovalWordsHeight.self, value: words.size.height)
                })
        }
        .onPreferenceChange(ApprovalWordsHeight.self) { wordsHeight = $0 }
        // Never shorter than its words, up to the cap. In a short window the
        // box was the part that gave way beside the transcript: squeezed to no
        // height, its words could not scroll and Approve stayed grey. The
        // transcript above gives way instead.
        .frame(minHeight: min(wordsHeight, Self.maximumHeight), maxHeight: Self.maximumHeight)
        // The box the user must read to the end of shows its scroller, and keeps it.
        .scrollIndicators(.visible)
    }
}

/// The card's target line, under the same clamp as its words. It was a plain line
/// with no limit, so a target shaped by the bot could push Approve and Deny off the
/// card while the words above it were held to their box. It keeps the height of its
/// words up to that cap, for the reason `ApprovalDetailBox` does; it asks for no
/// reading to the end, because the target repeats what the words say rather than
/// adding to it.
struct ApprovalTargetBox: View {
    let target: String
    @State private var wordsHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(target).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { words in
                    Color.clear.preference(key: ApprovalWordsHeight.self, value: words.size.height)
                })
        }
        .onPreferenceChange(ApprovalWordsHeight.self) { wordsHeight = $0 }
        .frame(minHeight: min(wordsHeight, ApprovalDetailBox.maximumHeight),
               maxHeight: ApprovalDetailBox.maximumHeight)
        // A target cut at the cap must look cut, on a trackpad too.
        .scrollIndicators(.visible)
    }
}

private struct ApprovalWordsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The transcript's own scroll probe, asked about the very end: it finds the
/// enclosing scroll view and answers after each change, a run-loop turn later,
/// never from inside AppKit's layout.
///
/// An answer about words not yet laid out is dropped. Before SwiftUI sizes
/// them, the probe finds a document of no height in a box of 140 points and
/// calls it no taller than the box, which latched sixty lines as seen whole
/// before one of them had been drawn.
struct ApprovalDetailEndObserver: NSViewRepresentable {
    let onAssessment: (Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollProbeView {
        let view = TranscriptScrollProbeView()
        view.threshold = 1
        view.keepsScrollerVisible = true
        view.onNearBottomChange = Self.laidOut(view, onAssessment)
        return view
    }

    func updateNSView(_ nsView: TranscriptScrollProbeView, context: Context) {
        nsView.threshold = 1
        nsView.keepsScrollerVisible = true
        nsView.onNearBottomChange = Self.laidOut(nsView, onAssessment)
        nsView.scheduleAttachmentAndAssessment()
    }

    private static func laidOut(_ probe: TranscriptScrollProbeView,
                                _ onAssessment: @escaping (Bool) -> Void) -> (Bool) -> Void {
        { [weak probe] atEnd in
            guard let words = probe?.enclosingScrollView?.documentView, words.bounds.height > 0 else { return }
            onAssessment(atEnd)
        }
    }
}

/// The approval card on the chat path: the exact action in plain
/// words, Approve and Deny, and when the question expires. Fixed geometry; the
/// detail scrolls inside its own box rather than reflowing the composer.
/// Internal rather than private so `ApprovalCardReadingTests` can render it
/// whole.
struct TextReplyApprovalCard: View {
    let approval: ClaudeTextApproval
    @ObservedObject var conversation: ConversationModel
    /// Nil until the box has measured the words; then whether their end has
    /// been in view. The card is given its approval's id, so a new card starts
    /// again at nil.
    @State private var detailEndSeen: Bool?
    /// The screenshot decoded once for this card, not on every redraw of the
    /// conversation around it; it goes with the card.
    @State private var screenPicture: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(approval.title).font(.headline)
            ApprovalDetailBox(detail: approval.detail, endSeen: $detailEndSeen,
                              codeType: ApprovalDetailBox.usesCodeType(toolName: approval.toolName))
            // A handoff's detail already carries the reason in the user's words.
            if !approval.handsOverScreen, !approval.asksForMissingFile {
                ApprovalTargetBox(target: approval.target)
            }
            // A web call after a look at the user's screen shows what the bot saw,
            // from memory only.
            if let picture = screenPicture {
                ApprovalScreenPicture(picture: picture)
            }
            if let path = approval.openablePath {
                Button("Reveal script") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .font(.caption)
                .accessibilityIdentifier("text.approval.revealScript")
            }
            // Redrawn every 30 seconds, with a tick on the deadline itself, so the
            // time left counts down and the buttons grey when it is up.
            TimelineView(.periodic(from: CardDeadlineWording.tickStart(expiresAt: approval.expiresAt, now: Date()),
                                   by: CardDeadlineWording.tick)) { context in
                let now = context.date
                let buttons = ApprovalCardButtons(expired: approval.expiresAt <= now, endSeen: detailEndSeen)
                VStack(alignment: .leading, spacing: 6) {
                    if buttons.showsScrollHint, !approval.asksForMissingFile {
                        Text(approval.handsOverScreen ? "Scroll to the end of the words above to hand back."
                                : "Scroll to the end of the words above to approve.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("text.approval.scrollHint")
                    }
                    Text(CardDeadlineWording.line(approval.handsOverScreen ? .handOver
                                                  : approval.asksForMissingFile ? .missingFile : .action,
                                                  expiresAt: approval.expiresAt, now: now))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("text.approval.deadline")
                    if approval.asksForMissingFile {
                        // A member's missing file: the user chooses a file in its
                        // place, or lets it go.
                        HStack {
                            Button("Choose the File…") { conversation.chooseMissingFileForTextReplyApproval(approval) }
                                .accessibilityIdentifier("text.approval.chooseFile")
                                .disabled(!buttons.denyEnabled)
                            Button("Continue Without It") { conversation.decideTextReplyApproval(approval, allow: false) }
                                .accessibilityIdentifier("text.approval.continueWithout")
                                .disabled(!buttons.denyEnabled)
                        }
                    } else if approval.handsOverScreen {
                        // The login handoff: the user did the step, or could not.
                        HStack {
                            Button("Hand back") { conversation.decideTextReplyApproval(approval, allow: true) }
                                .accessibilityIdentifier("text.approval.handBack")
                                .disabled(!buttons.approveEnabled)
                            Button("I couldn't do it") { conversation.decideTextReplyApproval(approval, allow: false) }
                                .accessibilityIdentifier("text.approval.couldNot")
                                .disabled(!buttons.denyEnabled)
                        }
                    } else {
                        HStack {
                            // No Return shortcut: the composer sends on Return, and typing must
                            // never approve an action by accident.
                            Button("Approve") { conversation.decideTextReplyApproval(approval, allow: true) }
                                .accessibilityIdentifier("text.approval.approve")
                                .disabled(!buttons.approveEnabled)
                            Button("Deny") { conversation.decideTextReplyApproval(approval, allow: false) }
                                .accessibilityIdentifier("text.approval.deny")
                                .disabled(!buttons.denyEnabled)
                            // Only on a card that can be answered once for the rest of the
                            // turn: a kind of edit in one folder, a rerun of the
                            // same script, or Control this Mac, whose every card
                            // shares one allowance until the reply ends. A plain
                            // command, a helper and every other connector call ask
                            // every time.
                            if let folder = approval.turnScopeFolder {
                                Button("Allow for this turn") { conversation.allowTextReplyApprovalForTurn(approval) }
                                    .accessibilityIdentifier("text.approval.allowTurn")
                                    .help(TurnAllowanceWording.help(toolName: approval.toolName, folder: folder))
                                    .disabled(!buttons.approveEnabled)
                            }
                        }
                    }
                }
            }
        }
        // Decoded as the Details preview decodes the same bytes (ImageIO, pixel
        // size): NSImage(data:) drew the card's picture with no height while
        // Details showed it.
        .onAppear {
            if screenPicture == nil {
                screenPicture = approval.screenPicture.flatMap(ConversationModel.decodedScreenPicture)
                    .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action approval")
        .accessibilityIdentifier("text.approval")
    }
}

/// The screenshot on a web card after a look: small, with the full size a
/// click away. The picture lives only as long as the card. Internal so
/// `ApprovalCardReadingTests` can lay it out beside a transcript.
struct ApprovalScreenPicture: View {
    let picture: NSImage
    @State private var showsFullSize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("What it saw on your screen").font(.caption).foregroundStyle(.secondary)
            Button { showsFullSize = true } label: {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    // A fixed height: no layout above can squeeze it away.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 110)
            }
            .buttonStyle(.plain)
            .help("Open full size")
            .accessibilityLabel("What the bot saw on your screen")
            .accessibilityIdentifier("text.approval.screenPicture")
        }
        .sheet(isPresented: $showsFullSize) {
            VStack(alignment: .trailing, spacing: 8) {
                ScrollView([.horizontal, .vertical]) { Image(nsImage: picture) }
                    .frame(minWidth: 480, idealWidth: min(picture.size.width, 1200), maxWidth: .infinity,
                           minHeight: 320, idealHeight: min(picture.size.height, 800), maxHeight: .infinity)
                Button("Done") { showsFullSize = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("text.approval.screenPicture.done")
            }
            .padding(12)
        }
    }
}

/// The bot's question above the composer: choices, something else,
/// or a masked answer when the question asks for a secret. Dismiss declines.
private struct TextReplyQuestionCard: View {
    let question: ClaudeTextQuestion
    @ObservedObject var conversation: ConversationModel
    @State private var chosen: [String] = []
    @State private var typed = ""
    @State private var secret = ""

    private var answer: ClaudeTextQuestionAnswer {
        ClaudeTextQuestionAnswer(chosen: question.options.map(\.label).filter { chosen.contains($0) },
                                 text: question.isSecret ? secret : typed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if question.count > 1 {
                    Text("\(question.position) of \(question.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(question.prompt).font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            // A secret question still shows the bot's choices (Claude Code
            // 2.1.282 requires them); only the typed field is masked.
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button { pick(option.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: chosen.contains(option.label)
                              ? (question.allowsMultiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                              : (question.allowsMultiple ? "square" : "circle"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.body)
                            if !option.detail.isEmpty {
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityValue(chosen.contains(option.label) ? "Chosen" : "Not chosen")
                .accessibilityIdentifier("text.question.option-\(index)")
            }
            if question.isSecret {
                SecureField("Type it here; only commands you approve use it, and it is never kept", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("text.question.secret")
            } else {
                TextField(question.options.isEmpty ? "Your answer" : "Something else…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("text.question.other")
            }
            // The same 30-second tick as the approval card.
            TimelineView(.periodic(from: CardDeadlineWording.tickStart(expiresAt: question.expiresAt, now: Date()),
                                   by: CardDeadlineWording.tick)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text(CardDeadlineWording.line(.question, expiresAt: question.expiresAt, now: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("text.question.deadline")
                    HStack {
                        Button("Answer") { conversation.answerTextReplyQuestion(question, answer: answer) }
                            .disabled(answer.isEmpty || question.expiresAt <= context.date)
                            .accessibilityIdentifier("text.question.answer")
                        // Says what it does: the bot goes on with no answer.
                        Button("Don’t Answer") { conversation.answerTextReplyQuestion(question, answer: nil) }
                            .help("The bot goes on without an answer.")
                            .accessibilityIdentifier("text.question.dismiss")
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the bot")
        .accessibilityIdentifier("text.question")
    }

    private func pick(_ label: String) {
        if question.allowsMultiple {
            if let index = chosen.firstIndex(of: label) { chosen.remove(at: index) } else { chosen.append(label) }
        } else {
            chosen = chosen == [label] ? [] : [label]
        }
    }
}

/// The composer, alone in its own view.
///
/// It observes `ComposerTextModel` for the field's text instead of reading it
/// off the conversation, so a keystroke invalidates this subtree and nothing
/// else. The sidebar, the header and the transcript's rows are no longer
/// re-evaluated per character, which is what stopped every visible reply from
/// re-measuring its native label on each keypress.
///
/// The conversation is still observed here: availability, the reply phase, the
/// job banner and `canSend` all live on it, and it no longer publishes while
/// typing. Every accessibility identifier, label, hint and help string is
/// unchanged from when this block lived in `OpenBotsRootView`.
private struct ComposerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var conversation: ConversationModel
    @ObservedObject var composer: ComposerTextModel
    let participants: [TeammateRowModel]
    /// Nil outside a team; in a team, who is working in it, if anyone.
    var teamWorkingAvatar: ConversationWorkingAvatar?? = nil
    let attachmentDraft: AttachmentDraftModel?
    let draftCoordinator: WorkspaceDraftCoordinator?
    let composerPrompt: String
    @FocusState.Binding var focus: OpenBotsRootView.FocusDestination?
    @Binding var isSelectingAttachment: Bool
    @Binding var attachmentPickerRequest: AttachmentPickerRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draftCoordinator {
                ComposerDraftStatusContainer(coordinator: draftCoordinator)
            }
            if let attachmentDraft {
                AttachmentDraftTray(model: attachmentDraft)
            }
            if conversation.agenticJobPresentation != nil {
                AgenticJobStatusView(conversation: conversation)
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
                        if NormalBusyFeedbackPolicy.showsCaption(for: phase) {
                            Text(phase.description)
                                .font(.callout)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(participants) { member in
                                WorkingBotIndicator(
                                    row: member,
                                    activityOverride: TeamRosterAvatarPolicy.override(of: member.id, team: teamWorkingAvatar),
                                    conversationID: conversation.conversationID ?? member.id
                                )
                            }
                            if let line = NormalBusyFeedbackPolicy.activityCaption(conversation.textReplyActivity) {
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .accessibilityIdentifier("reply.activity")
                            }
                        }
                        Spacer(minLength: 0)
                        if phase.isBusy {
                            Button("Stop", action: conversation.stopCurrentTextReply)
                                .disabled(phase == .stopping)
                                // Command-period, the Mac's own stop key.
                                .keyboardShortcut(".", modifiers: .command)
                                .help("Stop this bot’s current Claude request and keep available saved text (⌘.).")
                                .accessibilityIdentifier("reply.stop")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Reply status")
                }
                if let approval = conversation.textReplyApproval {
                    TextReplyApprovalCard(approval: approval, conversation: conversation)
                        .id(approval.id)
                }
                if let question = conversation.textReplyQuestion {
                    TextReplyQuestionCard(question: question, conversation: conversation)
                        .id(question.id)
                }
                if conversation.hasAttachmentContent {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Claude reads text only. Your file stays in this draft on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if conversation.textRepliesEnabled {
                            Button("Send just the text") { conversation.submitTextKeepingAttachments() }
                                .font(.caption)
                                .disabled(!conversation.canSendTextOnly)
                                .accessibilityIdentifier("composer.sendTextOnly")
                                .help("Sends what you typed and keeps the file here in the draft.")
                        }
                    }
                }
                if let refusal = conversation.lastSubmissionRefusal {
                    Label(refusal, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("composer.refusal")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(composerPrompt, text: $composer.text, axis: .vertical)
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
                            guard let attachmentDraft, conversation.attachmentsAvailable else { return }
                            attachmentPickerRequest = AttachmentPickerRequest(draft: attachmentDraft)
                            isSelectingAttachment = true
                        }
                        .disabled(attachmentDraft == nil || conversation.inputAvailability != .ready
                                  || !conversation.attachmentsAvailable)
                        if !conversation.attachmentsAvailable {
                            Text(ConversationModel.attachmentsUnavailableInTeamReason)
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Attach file")
                    .help(conversation.attachmentsAvailable
                          ? "Attach one local file; the source is unchanged"
                          : ConversationModel.attachmentsUnavailableInTeamReason)
                    Spacer(minLength: 0)
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

    private var composerAccessibilityHint: String {
        if let reason = conversation.inputAvailability.unavailableReason {
            return reason
        }
        return conversation.isLocalOnly
            ? "Press Shift-Enter for a new line. Press Return or Command-Return to save on this Mac. This does not send to Claude or queue later delivery."
            : "Press Shift-Enter for a new line. Press Return or Command-Return to send."
    }
}

private struct TranscriptRowContainer: View {
    @ObservedObject var row: ChatMessageModel
    let teammate: TeammateRowModel?
    /// Set only in a team conversation: who is working in it, if anyone. A
    /// member's faces there follow this, never the member's own chat.
    let teamWorkingAvatar: ConversationWorkingAvatar??
    let cardInteractions: ConversationCardInteractionModel?
    let isLocalOnly: Bool
    let onStreamingGrowth: @MainActor () -> Void

    var body: some View {
        let _ = LayoutStormCounters.hit("row.body")
        Group {
            if !NormalBusyFeedbackPolicy.hidesPlaceholder(row.snapshot) {
                switch row.snapshot.author {
                case .user:
                    UserMessageBubble(row: row, cardInteractions: cardInteractions, isLocalOnly: isLocalOnly)
                case .system:
                    SystemMessageBubble(row: row, cardInteractions: cardInteractions)
                case .teammate(let identity):
                    if let teammate {
                        LiveTeammateMessageBubble(row: row, teammate: teammate, identity: identity,
                            teamWorkingAvatar: teamWorkingAvatar, cardInteractions: cardInteractions)
                    } else {
                        DetachedTeammateMessageBubble(row: row, identity: identity, cardInteractions: cardInteractions)
                    }
                }
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
            AttachmentChipWording.readyLine(displayName: receipt.displayName, byteCount: receipt.byteCount)
        case .failed:
            "Couldn’t prepare this file"
        }
    }

    private var stateColor: Color {
        if case .failed = row.state { return .red }
        return .secondary
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
            CharacterIdentityView(teammate: row.snapshot, size: 42, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.snapshot.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // A pinned bot sits above the rest; the pin says why. Still,
                    // like the unread badge: no motion.
                    if row.snapshot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryText)
                            .help("Pinned")
                            .accessibilityHidden(true)
                    }
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
                    if NormalBusyFeedbackPolicy.isWorking(row.snapshot.activity) {
                        Text(row.snapshot.identity.title ?? row.snapshot.role)
                            .font(.caption).foregroundStyle(secondaryText).lineLimit(1)
                    } else {
                        Label(row.snapshot.activity.visibleLabel, systemImage: row.snapshot.activity.symbolName)
                            .font(.caption).foregroundStyle(secondaryText).lineLimit(1)
                    }
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
        .accessibilityElement(children: .contain)
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
            CharacterIdentityView(teammate: row.snapshot, size: 42, isSelected: true, showsWorkingEffects: false)
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text(row.snapshot.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let title = row.snapshot.identity.title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.snapshot.name), \(row.snapshot.role), \(row.snapshot.activity.visibleLabel)"
        )
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TeamRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let row: TeamRowSnapshot
    let memberRows: [TeammateRowModel]
    let isSelected: Bool
    var workingAvatar: ConversationWorkingAvatar? = nil

    var body: some View {
        HStack(spacing: 10) {
            TeamRosterAvatar(row: row, memberRows: memberRows, isSelected: isSelected, workingAvatar: workingAvatar)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let date = row.lastActivityAt {
                        Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(secondaryText).lineLimit(1)
                    }
                }
                Text(row.memberSummary).font(.caption).foregroundStyle(secondaryText).lineLimit(1)
            }
        }
        .padding(.vertical, OpenBotsVisualStyle.spacing4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TeamRosterAvatarPolicy.accessibilityLabel(for: row))
    }

    private var secondaryText: Color { isSelected ? .primary : OpenBotsVisualStyle.secondaryText(for: colorScheme) }
}

struct SelectedTeamHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let row: TeamRowSnapshot
    let memberRows: [TeammateRowModel]
    /// The members this screen can open settings for. Empty leaves the header
    /// exactly as it was: one combined, static line.
    var members: [TeammateIdentitySnapshot] = []
    /// Hidden members: seated and shown by face and name, never a settings
    /// control.
    var hiddenMembers: [TeammateIdentitySnapshot] = []
    var openMemberSettings: (@MainActor (UUID) -> Void)?
    var workingAvatar: ConversationWorkingAvatar? = nil

    var body: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing12) {
            TeamRosterAvatar(row: row, memberRows: memberRows, fallbackMembers: members + hiddenMembers, isSelected: true, showsWorkingEffects: false, workingAvatar: workingAvatar)
            if let openMemberSettings, !members.isEmpty || !hiddenMembers.isEmpty {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text(row.name).font(.title2.weight(.semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    memberControls(open: openMemberSettings)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(TeamRosterAvatarPolicy.accessibilityLabel(for: row))
            } else {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text(row.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Text("Lead: \(row.leadName) · Members: \(row.memberNames.joined(separator: ", "))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// A member's state beside its name here: this team's turn only, whether
    /// or not the member's own row has loaded.
    func activity(of memberID: UUID) -> TeammateActivityState {
        TeamRosterAvatarPolicy.activity(of: memberID, in: workingAvatar)
    }

    /// Each member of the open team is its own control: one click opens that
    /// bot's own settings without leaving this conversation.
    private func memberControls(open: @escaping @MainActor (UUID) -> Void) -> some View {
        HStack(spacing: OpenBotsVisualStyle.spacing8) {
            Text("Lead: \(row.leadName)")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            ForEach(members) { member in
                memberControl(member, open: open)
            }
            ForEach(hiddenMembers) { member in
                HStack(spacing: OpenBotsVisualStyle.spacing4) {
                    CharacterIdentityView(identity: member, activity: activity(of: member.id), size: 22,
                        showsWorkingEffects: false)
                        .accessibilityHidden(true)
                    Text(member.name).font(.callout).lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(member.name), hidden from the bot list")
                .accessibilityValue(activity(of: member.id).visibleLabel)
                .help("\(member.name) is hidden from the bot list. Unhide it from Hidden Bots to open its settings.")
                .accessibilityIdentifier("team-hidden-member-\(member.id.uuidString)")
            }
        }
    }

    @ViewBuilder
    private func memberControl(_ member: TeammateIdentitySnapshot, open: @escaping @MainActor (UUID) -> Void) -> some View {
        if let live = memberRows.first(where: { $0.id == member.id }) {
            LiveTeamMemberSettingsButton(row: live, activity: activity(of: live.id), open: open)
        } else {
            Button { open(member.id) } label: {
                HStack(spacing: OpenBotsVisualStyle.spacing4) {
                    CharacterIdentityView(identity: member, activity: activity(of: member.id), size: 22,
                        showsWorkingEffects: false)
                        .accessibilityHidden(true)
                    Text(member.name).font(.callout).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(member.name)’s settings")
            .accessibilityValue(activity(of: member.id).visibleLabel)
            .accessibilityHint("Opens this bot’s own settings without leaving the team conversation")
            .help("Open \(member.name)’s settings")
            // Keyed by id, not by name: two bots may share a display name,
            // and an identifier that names two controls names neither. The
            // spoken label above is where the name belongs.
            .accessibilityIdentifier("team-member-settings-\(member.id.uuidString)")
        }
    }
}

private struct DetachedTeammateMessageBubble: View {
    @ObservedObject var row: ChatMessageModel
    let identity: TeammateIdentitySnapshot
    let cardInteractions: ConversationCardInteractionModel?

    var body: some View {
        let _ = LayoutStormCounters.hit("teammateBubble.body")
        teammateMessageLayout(
            message: row.snapshot,
            identity: identity,
            cardInteractions: cardInteractions
        )
    }
}

private struct LiveTeammateMessageBubble: View {
    @ObservedObject var row: ChatMessageModel
    @ObservedObject var teammate: TeammateRowModel
    let identity: TeammateIdentitySnapshot
    let teamWorkingAvatar: ConversationWorkingAvatar??
    let cardInteractions: ConversationCardInteractionModel?
    var body: some View {
        let activity = TeamRosterAvatarPolicy.override(of: teammate.id, team: teamWorkingAvatar)
            ?? teammate.snapshot.activity
        teammateMessageLayout(message: row.snapshot, identity: identity,
            cardInteractions: cardInteractions, activity: activity)
    }
}

private struct UserMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var row: ChatMessageModel
    let cardInteractions: ConversationCardInteractionModel?
    let isLocalOnly: Bool

    var body: some View {
        let _ = LayoutStormCounters.hit("userBubble.body", detail: "scheme=\(colorScheme)")
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
        let _ = LayoutStormCounters.hit("systemBubble.body")
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
    cardInteractions: ConversationCardInteractionModel?,
    activity: TeammateActivityState? = nil
) -> some View {
    let activity = activity ?? messageActivity(message)
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
                if case .failed = message.streamState {
                    Label(TeammateActivityState.errorOrAttention.visibleLabel, systemImage: TeammateActivityState.errorOrAttention.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            MessageTimestampView(message: message)
            // One bubble per settled piece of the reply: a short first line, the
            // beats, then the answer whole. Attachments and cards
            // follow in their own box.
            ForEach(replyBubbleSlices(message)) { slice in
                MessageContent(message: slice.snapshot, cardInteractions: cardInteractions)
            }
        }
        Spacer(minLength: 56)
    }
    .modifier(
        MessageRowAccessibilityModifier(
            message: message
        )
    )
}

/// One drawn bubble of a teammate message.
private struct ReplyBubbleSlice: Identifiable {
    let id: String
    let snapshot: ChatMessageSnapshot
}

/// Splits a teammate message into the bubbles the rule in `ReplyBubbleSplitter`
/// gives: each text part's short first line and beats on their own, its answer
/// whole; every non-text part in one trailing box. Only the last slice carries
/// the delivery state and notice, so they are shown once.
private func replyBubbleSlices(_ message: ChatMessageSnapshot) -> [ReplyBubbleSlice] {
    var slices: [(id: String, parts: [ChatMessagePartSnapshot])] = []
    var others: [ChatMessagePartSnapshot] = []
    for part in message.parts {
        guard case .text(let text) = part.content else { others.append(part); continue }
        let bubbles = ReplyBubbleSplitter.split(text)
        if bubbles.count <= 1 { slices.append(("\(part.id)", [part])); continue }
        for (index, bubble) in bubbles.enumerated() {
            slices.append(("\(part.id)-\(index)", [ChatMessagePartSnapshot(id: derivedPartID(part.id, index: index),
                ordinal: part.ordinal, content: .text(bubble))]))
        }
    }
    if !others.isEmpty { slices.append(("\(message.id)-others", others)) }
    guard slices.count > 1 else { return [ReplyBubbleSlice(id: "\(message.id)", snapshot: message)] }
    return slices.enumerated().map { offset, slice in
        let isLast = offset == slices.count - 1
        var snapshot = ChatMessageSnapshot(id: message.id, author: message.author, parts: slice.parts,
            delivery: isLast ? message.delivery : .sent, streamState: message.streamState, timestamp: message.timestamp)
        snapshot.deliveryNotice = isLast ? message.deliveryNotice : nil
        return ReplyBubbleSlice(id: slice.id, snapshot: snapshot)
    }
}

/// A stable id for the nth bubble of one part, so rows keep their identity.
private func derivedPartID(_ base: UUID, index: Int) -> UUID {
    guard index > 0 else { return base }
    var bytes = base.uuid
    bytes.15 = bytes.15 &+ UInt8(truncatingIfNeeded: index)
    bytes.14 = bytes.14 &+ UInt8(truncatingIfNeeded: index >> 8)
    return UUID(uuid: bytes)
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
        let _ = LayoutStormCounters.hit("content.body", detail: "scheme=\(colorScheme)")
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
        if message.deliveryNotice != nil {
            // The coarse failed state also covers accepted turns that failed
            // later. Their provenance distinguishes acceptance, saved partial
            // replies and unknown outcomes from an actual local-send failure.
            if let notice = NormalBusyFeedbackPolicy.deliveryNotice(for: message) {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        } else if case .failed(let reason) = message.delivery {
            Label("\(isLocalOnly ? "Not saved" : "Not sent"): \(reason)", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.red)
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
        let _ = LayoutStormCounters.hit("rowA11y.body", detail: "\(locale.identifier) \(timeZone.identifier)")
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
        let _ = LayoutStormCounters.hit("timestamp.body")
        Text(message.timestamp, format: .dateTime.hour().minute())
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(WorkspaceAccessibilityMetadata.timestamp(message.timestamp, locale: locale, timeZone: timeZone))
            .accessibilityIdentifier("message-timestamp-\(message.id)")
    }
}
