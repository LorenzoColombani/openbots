import ApplicationServices
import OpenBotsServices
import OpenBotsDomain
import SwiftUI

/// What Details says about the bot's profile, under the names its settings use:
/// "What this bot does" is the role, the one paragraph the New Bot sheet asks for,
/// and the instructions follow under their own name when there are any. Reading
/// only the instructions would tell a bot made a minute earlier that it had
/// "No description yet".
struct BotDetailsProfileText {
    struct Section: Equatable {
        let label: String
        let text: String
    }

    static func sections(for profile: TeammateProfile) -> [Section] {
        var sections = [Section(label: "What this bot does", text: profile.role)]
        if let instructions = profile.detailedInstructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(Section(label: "Instructions", text: instructions))
        }
        return sections
    }
}

/// A local bot's details. Unavailable runtime surfaces never synthesize state.
struct BotDetailsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var settingsIsFocused: Bool
    let teammate: Teammate
    let canEdit: Bool
    let onEdit: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    var canArchive: Bool = false
    var onArchive: @MainActor () -> Void = {}
    /// Present when the workspace can write a readable copy of this bot's chats.
    var onExport: (@MainActor () -> Void)? = nil
    var modelStatus: ClaudeModelRunPresentation? = nil
    /// The workspace's shared view of the selected bot's switches. Details
    /// reads it for the one-line summary and selects this bot on it, as it
    /// always did; the switches themselves live on the Access sheet now.
    var agenticJobAccess: AgenticJobAccessModel? = nil
    /// The connector grants, when the app has them. Read by the Access sheet;
    /// kept here so the pane knows the app has connectors at all.
    var connectorAccess: ConnectorAccessStore? = nil
    /// Opens this bot's Access sheet: every switch it has, in one place.
    var onOpenAccess: (@MainActor () -> Void)? = nil
    /// The bot's desk on the Mac; present when the workspace can keep one.
    var workspace: BotWorkspaceModel? = nil
    /// Observe the row and the matching conversation directly, so tool beats
    /// update this pane without rebuilding the whole workspace.
    var activityRow: TeammateRowModel? = nil
    var activityConversation: ConversationModel? = nil
    /// The activity conversation is the open team chat this bot belongs to.
    var activityIsTeamChat = false
    var onOpenWorkRecord: (@MainActor () -> Void)? = nil

    var body: some View {
        let _ = LayoutStormCounters.hit("botDetails.body")
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Details").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onEdit) { Image(systemName: "gearshape") }
                    .disabled(!canEdit)
                    .accessibilityLabel("Bot settings")
                    .help("Bot settings")
                    .focused($settingsIsFocused)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .accessibilityLabel("Close details")
                    .help("Close details")
                    .accessibilityIdentifier("details.close")
            }
            .buttonStyle(.plain)
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        CharacterIdentityView(
                            identity: TeammateIdentitySnapshot(teammate),
                            activity: BotDetailsCreatureActivity.resolve(activityRow?.snapshot.activity),
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(teammate.profile.displayName).font(.headline)
                            if let label = teammate.profile.title {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let activityRow {
                        BotActivityDetailsView(row: activityRow, conversation: activityConversation,
                                               inTeamChat: activityIsTeamChat, onOpenWorkRecord: onOpenWorkRecord)
                    }
                    // One sheet per bot: the
                    // work, web and connector switches that used to stack here
                    // are on the Access sheet, each saying when its app-wide
                    // master is off. Details keeps the state in one line and the
                    // button that opens the sheet.
                    if let agenticJobAccess {
                        BotAccessSummaryView(switches: agenticJobAccess, teammateID: teammate.id,
                                             hasConnectors: connectorAccess != nil, onOpen: onOpenAccess)
                    } else if let onOpenAccess {
                        BotAccessSummaryView(switches: nil, teammateID: teammate.id,
                                             hasConnectors: connectorAccess != nil, onOpen: onOpenAccess)
                    }
                    if let workspace {
                        BotWorkspaceFoldersView(model: workspace, teammateID: teammate.id)
                        BotInterpretersView()
                        BotSkillsView(model: workspace, teammateID: teammate.id)
                    }
                    // Below what the bot may do and where it works, closed until
                    // the user opens it, so Details does not open on model settings.
                    BotModelDetailsView(teammate: teammate, status: modelStatus)
                    ForEach(BotDetailsProfileText.sections(for: teammate.profile), id: \.label) { section in
                        Text(section.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(section.text).font(.callout).textSelection(.enabled)
                    }
                    BotSeatDetailsView(seat: teammate.profile.seat)
                    if let author = BotSeatCopy.authorLine(for: teammate) {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("details.profile-author")
                    }
                    Divider()
                    if let onExport {
                        Button(action: onExport) { Label("Export Conversations…", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("export-conversations")
                            .help("Write this bot's conversations as Markdown and JSON into a folder you choose")
                        Text("Transcripts and metadata only; attachments, secrets and memory documents stay on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: onArchive) { Label("Archive Bot", systemImage: "archivebox") }
                        .disabled(!canArchive)
                        .accessibilityIdentifier("archive-bot")
                    Text("Remove this bot from the active list. Messages, drafts, files and settings stay saved. Restore it from Archived.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation details")
        .accessibilityIdentifier("bot-details-panel")
        .onAppear { settingsIsFocused = canEdit }
    }
}

/// The bot's model choices and what the last reply reported, behind one
/// closed heading: useful to check, not what Details should open on.
private struct BotModelDetailsView: View {
    let teammate: Teammate
    let status: ClaudeModelRunPresentation?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ClaudeModelStatusView(savedChoice: teammate.requestedClaudeModel,
                                  savedEffort: teammate.requestedClaudeEffort,
                                  savedContextWindow: teammate.requestedClaudeContextWindow, status: status)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Model").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("details.model")
    }
}

/// A bot's seat in Details: the four fields a hirer wrote, each on
/// its own labelled line, in the order the old app's seat file kept them. A
/// field the seat does not have is not drawn; a bot without a seat shows none.
enum BotSeatCopy {
    static let heading = "Seat"

    static func rows(_ seat: TeammateSeat?) -> [(label: String, text: String)] {
        guard let seat else { return [] }
        let fields: [(String, String?)] = [("Owns", seat.purview), ("Hands off", seat.never),
                                           ("Works with", seat.interfaces), ("Escalates", seat.escalate)]
        return fields.compactMap { label, text in text.map { (label, $0) } }
    }

    /// Who wrote a hired bot's role, instructions and seat, until the person
    /// saves the profile: the same fact its own prompt carries.
    static func authorLine(for teammate: Teammate) -> String? {
        teammate.profileWrittenByHirer.map { "Written by @\($0) when hiring; you have not reviewed it yet." }
    }
}

/// Openable, not a wall of fields: the heading shows, the lines
/// show when the user opens it.
private struct BotSeatDetailsView: View {
    let seat: TeammateSeat?
    @State private var isExpanded = false

    var body: some View {
        let rows = BotSeatCopy.rows(seat)
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).font(.caption).foregroundStyle(.secondary)
                            Text(row.text).font(.callout).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(BotSeatCopy.heading).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("details.seat")
        }
    }
}

private struct BotActivityDetailsView: View {
    @ObservedObject var row: TeammateRowModel
    var conversation: ConversationModel?
    /// The conversation is the open team chat, not this bot's own.
    var inTeamChat = false
    var onOpenWorkRecord: (@MainActor () -> Void)?
    /// Injected for tests; defaults read the live TCC answers without prompting.
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var screenRecordingAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this bot is doing").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(row.snapshot.activity.visibleLabel).font(.callout)
            if conversation != nil, inTeamChat {
                Text(BotWatchPanePresentation.teamChatNote).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("details.activity.team-chat")
            }
            if let conversation {
                BotConversationActivityLine(
                    conversation: conversation,
                    activity: row.snapshot.activity
                )
                BotBackgroundWorkerLines(conversation: conversation)
            }
            if let conversation {
                BotScreenPreview(conversation: conversation, botName: row.snapshot.name, inTeamChat: inTeamChat)
            }
            if conversation?.textReplyScreenPicture == nil {
                Text(BotWatchPanePresentation.screenPreviewCaption(
                    accessibilityTrusted: accessibilityTrusted(),
                    screenRecordingAllowed: screenRecordingAllowed()
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("details.activity.screen-preview-status")
            }
            if let onOpenWorkRecord {
                Button("What happened", action: onOpenWorkRecord)
                    .buttonStyle(.link)
                    .help("Open this conversation’s activity and approvals")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("details.activity")
    }
}

/// What Control this Mac last saw in the open turn: a small copy that
/// opens full size. Held in memory only, and gone when the turn ends.
private struct BotScreenPreview: View {
    @ObservedObject var conversation: ConversationModel
    var botName: String
    /// The picture is the open team chat's: any member may have taken it.
    var inTeamChat = false
    @State private var showsFullSize = false

    var body: some View {
        if let picture = conversation.textReplyScreenPicture {
            VStack(alignment: .leading, spacing: 4) {
                Button { showsFullSize = true } label: {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
                .buttonStyle(.plain)
                .help("Open full size")
                .accessibilityLabel(BotWatchPanePresentation.screenPreviewLabel(botName: botName, inTeamChat: inTeamChat))
                .accessibilityIdentifier("details.activity.screen-preview")
                Text(BotWatchPanePresentation.screenPreviewNote(inTeamChat: inTeamChat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showsFullSize) {
                VStack(alignment: .trailing, spacing: 8) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: picture)
                    }
                    .frame(minWidth: 480, idealWidth: min(picture.size.width, 1200), maxWidth: .infinity,
                           minHeight: 320, idealHeight: min(picture.size.height, 800), maxHeight: .infinity)
                    .accessibilityLabel(BotWatchPanePresentation.screenPreviewLabel(botName: botName, inTeamChat: inTeamChat))
                    Button("Done") { showsFullSize = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("details.activity.screen-preview.done")
                }
                .padding(12)
            }
            // A turn that ends takes its picture with it; so does the sheet.
            .onChange(of: conversation.textReplyScreenPicture == nil) { _, gone in
                if gone { showsFullSize = false }
            }
        }
    }
}

/// This chat's background workers: seen here while they
/// run and until their bot answers, never as a seat of their own.
private struct BotBackgroundWorkerLines: View {
    @ObservedObject var conversation: ConversationModel

    var body: some View {
        if !conversation.backgroundWorkerLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(conversation.backgroundWorkerLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if conversation.canStopBackgroundWorkers {
                    Button("Stop", action: conversation.stopBackgroundWorkers)
                        .help("Stop this chat’s background workers. Their bot is not woken.")
                        .accessibilityIdentifier("details.activity.workers.stop")
                }
            }
            .accessibilityIdentifier("details.activity.workers")
        }
    }
}

private struct BotConversationActivityLine: View {
    @ObservedObject var conversation: ConversationModel
    var activity: TeammateActivityState

    var body: some View {
        let lines = conversation.textReplyActivityLines
        if !lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .accessibilityIdentifier("details.activity.live-list")
                .onChange(of: lines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
                .onAppear {
                    guard !lines.isEmpty else { return }
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
        } else if let line = conversation.textReplyActivity, !line.isEmpty {
            Text(line).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("details.activity.current")
        } else {
            Text(BotWatchPanePresentation.emptyActivityMessage(activity: activity))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("details.activity.empty")
        }
    }
}

/// Offline watch-pane copy for Details. Pure so tests cover the
/// honest empty and permission lines without raising TCC prompts.
enum BotWatchPanePresentation {
    static func emptyActivityMessage(activity: TeammateActivityState) -> String {
        switch activity {
        case .thinkingOrWorking, .speaking:
            return "Working — live lines will show here as tools run."
        case .waitingForUser:
            return "Waiting for you — nothing new on this Mac yet."
        case .idle, .errorOrAttention:
            return "Nothing running on this Mac right now."
        }
    }

    /// In a team chat any member may have taken the picture, and nothing says
    /// which, so the words never name the bot whose pane this is.
    static func screenPreviewLabel(botName: String, inTeamChat: Bool = false) -> String {
        inTeamChat ? "What a bot in this team chat last saw on this Mac. Opens full size."
            : "What \(botName) last saw on this Mac. Opens full size."
    }

    static func screenPreviewNote(inTeamChat: Bool = false) -> String {
        (inTeamChat ? "What a bot in this team chat" : "What it")
            + " last saw on this Mac, kept only until this reply ends."
    }

    /// Above a member's live lines when they come from the open team chat.
    static let teamChatNote = "From the open team chat: this is the whole team's reply, not only this bot's part."

    /// Always returns a caption: either what permissions are still missing, or
    /// that the preview slot is ready once Control this Mac is actually used.
    static func screenPreviewCaption(accessibilityTrusted: Bool, screenRecordingAllowed: Bool) -> String {
        var missing: [String] = []
        if !accessibilityTrusted { missing.append("Accessibility") }
        if !screenRecordingAllowed { missing.append("Screen Recording") }
        if missing.isEmpty {
            return "Screen preview appears here when Control this Mac is in use."
        }
        return "Screen preview needs OpenBots Next turned on for "
            + missing.joined(separator: " and ")
            + " in System Settings → Privacy & Security."
    }
}

/// Where the bot works: its own folder, then the folders the user added, each
/// with Show in Finder and Remove; Add Folder… opens the native picker.
struct BotWorkspaceFoldersView: View {
    @ObservedObject var model: BotWorkspaceModel
    let teammateID: TeammateID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let workspace = model.workspace, model.teammateID == teammateID {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(workspace.homeURL.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text("own folder").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Show in Finder", action: model.revealHome)
                        .accessibilityIdentifier("workspace.reveal-home")
                }
                ForEach(workspace.folders) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: !folder.exists ? "folder.badge.questionmark" : folder.isOutOfReach ? "folder.badge.minus" : "folder").foregroundStyle(.secondary)
                        Text(folder.url.path).font(.callout).lineLimit(1).truncationMode(.middle)
                            .help(folder.url.path)
                        Spacer(minLength: 0)
                        if !folder.exists {
                            Text("missing").font(.caption).foregroundStyle(.secondary)
                        } else if folder.isOutOfReach {
                            // A work turn leaves it out.
                            Text("out of reach").font(.caption).foregroundStyle(.secondary)
                                .help("The bot can't work in this folder: it takes in too much of your Mac, or it sits in one of your Mac's private stores.")
                        } else {
                            Button("Show in Finder") { model.reveal(folder.url) }
                        }
                        Button("Remove") { model.removeFolder(id: folder.id) }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("workspace.remove-folder")
                    }
                }
                Button("Add Folder…", action: model.addFolder)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("workspace.add-folder")
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Text("With Work on this Mac on, the bot reads and writes in these folders as you; a card asks before anything else.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Preparing this bot's folder…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.link)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders")
        .accessibilityIdentifier("workspace.folders")
        .task(id: teammateID) { model.select(teammateID) }
    }
}

/// Interpreters resolved on this Mac for Work on this Mac's run-code.
/// Discovery only — never installs.
struct BotInterpretersView: View {
    @State private var interpreters: [ClaudeTextInterpreter] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interpreters").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if interpreters.isEmpty {
                Text("None found yet. Install Python, Node, Ruby, Swift or uv yourself; OpenBots never installs them silently.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(interpreters) { interpreter in
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(interpreter.name).font(.callout)
                            Text(interpreter.path).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Text("Used when Work on this Mac is on. A run card names the interpreter and script before the first run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interpreters")
        .accessibilityIdentifier("workspace.interpreters")
        .task { interpreters = ClaudeTextInterpreterCatalog.resolve() }
    }
}


/// The sentence under the skills, named so a test can read it.
enum BotSkillsCopy {
    /// Every bot reads its skills, Work or not (a turn without Work reads the
    /// shared folder and its skills). The line
    /// used to say the bot needed Work on this Mac for that, which stopped being
    /// true the moment reading reached every bot.
    static let caption = "Copied from your Claude skills. The bot reads the one that fits before a task, "
        + "with or without Work on this Mac, and it can never change them."
    /// In the Add Skill menu until `~/.claude/skills` has been read.
    static let readingSkills = "Reading ~/.claude/skills…"
    /// In the menu when the folder holds no skill folder at all.
    static let noSkills = "No skills in ~/.claude/skills"
    /// In the menu when the folder holds skill folders, none of which can be added.
    static let noUsableSkills = "Nothing in ~/.claude/skills can be added: a skill needs its own folder "
        + "with a SKILL.md inside, named with letters, digits, dots, hyphens or underscores."
}

/// The bot's skills: copies of the user's own Claude skills that it reads before
/// a task they fit and can never change (the old app's way).
struct BotSkillsView: View {
    @ObservedObject var model: BotWorkspaceModel
    let teammateID: TeammateID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if model.teammateID == teammateID {
                ForEach(model.skills) { skill in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.callout)
                            if !skill.summary.isEmpty {
                                Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Remove") { model.removeSkill(named: skill.name) }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("skills.remove")
                    }
                }
                Menu("Add Skill") {
                    if let note = model.skillMenuNote {
                        Text(note)
                    }
                    ForEach(model.availableSkills) { skill in
                        Button(skill.name) { model.addSkill(named: skill.name) }
                            .disabled(model.skills.contains { $0.name == skill.name })
                            .help(skill.summary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isBusy)
                .accessibilityIdentifier("skills.add")
                if let notice = model.skillNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Text(BotSkillsCopy.caption)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.link)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skills")
        .accessibilityIdentifier("workspace.skills")
    }
}

struct ClaudeModelStatusView: View {
    let savedChoice: String
    let savedEffort: String
    let savedContextWindow: String
    let status: ClaudeModelRunPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Saved model preference: \(ClaudeModelCatalog.label(for: savedChoice))")
                .font(.callout.weight(.medium))
            Text("Saved intensity preference: \(ClaudeModelCatalog.effortLabel(savedEffort, model: savedChoice))")
            Text("Saved context preference: \(ClaudeModelCatalog.contextLabel(savedContextWindow, model: savedChoice))")
            Text("Supported saved preferences apply to the next reply. Effective intensity and context capacity are not verified.")
            if let confirmed = status?.confirmedModel {
                Text("Last saved result reported: \(ClaudeModelCatalog.label(for: confirmed))")
                if let requested = status?.confirmedRequest, requested != confirmed {
                    Text("That turn requested: \(ClaudeModelCatalog.label(for: requested))")
                }
                if let effort = status?.confirmedEffort, let window = status?.confirmedContextWindow,
                   let request = status?.confirmedRequest {
                    if effort == "default", window == "default" {
                        Text("That reply used the model's default intensity and context; Claude reports neither back.")
                    } else {
                        Text("That reply was requested with \(ClaudeModelCatalog.effortLabel(effort, model: request)) and \(ClaudeModelCatalog.contextLabel(window, model: request)); Claude reports neither back.")
                    }
                }
            } else if let observed = status?.observedAtStart {
                Text("Startup reported: \(ClaudeModelCatalog.label(for: observed)). A successful result has not been confirmed.")
            } else {
                Text("No model observation is loaded in this app session.")
            }
            if let version = status?.claudeCodeVersion {
                Text("Claude Code \(version) answered the last saved reply.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}


/// Details creature activity mirrors the sidebar row when one is provided.
enum BotDetailsCreatureActivity {
    static func resolve(_ activity: TeammateActivityState?) -> TeammateActivityState {
        activity ?? .idle
    }
}
