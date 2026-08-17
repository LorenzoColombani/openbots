import SwiftUI
import AppKit
import AgencyKit

struct ThreadView: View {
    @ObservedObject var state: AppState
    let thread: String
    @State private var draft = ""
    @State private var showProfile = false
    @State private var confirmFresh = false
    @State private var viewingArchive: ArchiveItem?
    @FocusState private var composerFocused: Bool
    @State private var showFreshPicker = false
    @State private var confirmArchiveTeam = false
    // Attachments (his ask 2026-08-14): picked or dropped files wait here as
    // chips until Send; staging (the copy into shared/attachments/) happens
    // in AppState.send so queued/relayed/group paths all carry the block.
    @State private var attachments: [URL] = []
    @State private var dropTargeted = false

    // MARK: group threads (R3)
    private var isTeam: Bool { TeamThreads.isTeamKey(thread) }
    private var teamMembers: [Agent] {
        guard let t = state.team(forKey: thread) else { return [] }
        return state.roster.agents.filter { t.members.contains($0.name) }
    }
    @State private var confirmFreshAll = false

    struct ArchiveItem: Identifiable { let url: URL; var id: URL { url } }

    private static let ts: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// Completion for the @token being typed ANYWHERE in the draft (review #4
    /// I-4 limited this to leading-@ drafts; live gap 2026-08-13: "hey once
    /// @annoyinglibrarian…" — mid-sentence, exactly how Lorenzo types — got
    /// nothing). Logic lives in AgencyKit.Mentions, where it is tested.
    private var mentionSuggestions: [Agent] {
        // Group threads suggest MEMBERS only, and an @ there is always plain
        // text to everyone (his call) — never a relay.
        Mentions.suggestions(draft: draft,
                             agents: isTeam ? teamMembers : state.roster.agents,
                             thread: thread)
    }

    private func complete(with agent: Agent) {
        // ifFragment: a chip built for one fragment must never clobber a draft
        // that has since moved on (reviewer #5 — the AppKit field editor can
        // lag the binding under streaming re-render load).
        draft = Mentions.complete(draft: draft, with: agent,
                                  ifFragment: Mentions.activeFragment(in: draft))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.messages[thread] ?? []) { msg in bubble(msg) }
                        // Queued bubbles ABOVE the streaming bubble: the scroll
                        // auto-follows the "streaming" anchor on every delta, so
                        // anything rendered below it is unreachable during a long
                        // run — which made ✕/⑂ unusable exactly when they matter
                        // (verified live 2026-08-13; short threads masked it).
                        ForEach(state.queued.items(for: thread)) { q in queuedBubble(q) }
                        if state.forking.contains(thread) {
                            HStack(alignment: .top, spacing: 8) {
                                if let a = state.roster.agents.first(where: { $0.name == thread }) {
                                    AgentAvatar(agent: a, size: 32).padding(.top, 16).opacity(0.6)
                                }
                                bubbleShape(text: "…", tint: .purple.opacity(0.12),
                                            label: "\(state.displayName(thread)) ⑂ subagent — working…")
                            }
                        }
                        // Fan-out state (audit I1): who this teammate is waiting on.
                        if let targets = state.awaiting[thread], !targets.isEmpty {
                            Text("⏳ awaiting " + targets.sorted().map { state.displayName($0) }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.orange.opacity(0.10), in: Capsule())
                        }
                        // Transient working visibility (his asks 2026-08-13):
                        // rolling thinking tail + the current tool line. Never
                        // persisted — gone when the reply lands.
                        if let think = state.thinking[thread], !think.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("thinking…").font(.caption2).foregroundStyle(.tertiary)
                                Text(think)
                                    .font(.callout.italic()).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        if let act = state.activity[thread], !act.isEmpty {
                            Text("⚙ \(act)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let partial = state.streaming[thread], !partial.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                if let a = state.roster.agents.first(where: { $0.name == thread }) {
                                    AgentAvatar(agent: a, size: 32).padding(.top, 16)
                                }
                                bubbleShape(text: partial, tint: .gray.opacity(0.15),
                                            label: "\(state.displayName(thread)) — typing…")
                            }
                            .id("streaming")
                        }
                    }.padding()
                }
                .onChange(of: (state.messages[thread] ?? []).count) {
                    if let last = state.messages[thread]?.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: state.streaming[thread] ?? "") {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            // What the interview asked for, one tap away (his report: the
            // toggle "should have" been on). The agent proposes; he grants.
            if let ids = state.proposedConnectors[thread], !ids.isEmpty {
                let names = ids.compactMap { Connector.byID($0)?.displayName }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(state.displayName(thread)) needs: \(names.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Grant") { state.grantProposed(thread) }
                            .buttonStyle(.borderedProminent)
                        Button("Not now") { state.proposedConnectors[thread] = nil }
                        if ids.contains(where: { Connector.byID($0)?.requiresSetup == true }) {
                            Text("one of these still needs a macOS permission")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            // Interview answer CARDS (his design 2026-08-13: same UX as the
            // Claude app). Broad categories from the question, plus the two
            // escapes the app always supplies: type-your-own and manual.
            if let options = state.interviewOptions[thread], !options.isEmpty,
               !state.busy.contains(thread) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        optionCard(option) { state.send(option, to: thread) }
                    }
                    optionCard(InterviewOptions.somethingElse, muted: true) {
                        state.interviewOptions[thread] = nil
                        composerFocused = true
                    }
                    optionCard(InterviewOptions.manual, muted: true) {
                        state.send(InterviewOptions.manual, to: thread)
                        showProfile = true
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            // Queue paused after Stop (audit I5) — visible, resumable.
            if state.queueHold.contains(thread) {
                HStack(spacing: 8) {
                    Text("⏸ queue paused after Stop — \(state.queued.items(for: thread).count) message(s) waiting")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resume") { state.resumeQueue(thread) }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 6)
            }
            if !mentionSuggestions.isEmpty {
                // A leading @ IS a relay; anywhere else it's plain text the
                // agent reads. Same completion, different promise — the label
                // must match what send() will actually do (reviewer #5).
                let isRelay = !isTeam && Mentions.fragmentIsLeading(in: draft)
                HStack(spacing: 6) {
                    Text(isRelay ? "relay to:" : "mention (sent as text):")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(mentionSuggestions) { agent in
                        Button {
                            complete(with: agent)
                        } label: {
                            Text("\(agent.emoji) \(agent.display)")
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(isRelay ? Color.orange.opacity(0.18)
                                                    : Color.gray.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 6)
            }
            // Attachment chips — visible before Send so a mis-drop is undone
            // with one ✕ instead of a sent message.
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc").font(.caption2)
                                Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                Button {
                                    attachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove attachment")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.gray.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6)
            }
            HStack {
                // The MANUAL half of attachments: a picker for when the file
                // isn't already in a Finder window to drag from.
                Button { pickAttachments() } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach files — they're copied where \(state.displayName(thread)) can read them")
                TextField(isTeam
                            ? "Message everyone in \(state.displayName(thread))…"
                            : "Message \(state.displayName(thread))…   (@teammate question relays it)",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .onSubmit {
                        // Return completes the highlighted mention instead of
                        // sending a half-typed relay target.
                        if let first = mentionSuggestions.first { complete(with: first) }
                        else { submit() }
                    }
                // Busy no longer disables Send — the message queues instead
                // (his ask 2026-08-13) and delivers in typed order.
                Button("Send") { submit() }
                    .disabled(draft.isEmpty && attachments.isEmpty)
                // HIS ORDER 2026-08-13: the ability to STOP an agent. Cancels
                // every live run for this thread (send/relay/fork); partial
                // output is kept and the stop is noted in the thread.
                // A team key is never in `busy` (that set holds agent handles)
                // — its run-in-flight signal is awaiting[thread] (review
                // finding I2: the Stop button never rendered in a group
                // thread, leaving up to six runs with no stop control on the
                // surface that launched them).
                if state.busy.contains(thread) || state.forking.contains(thread)
                    || state.awaiting[thread]?.isEmpty == false {
                    Button {
                        state.stopRun(thread)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .tint(.red)
                    .help("Stop \(state.displayName(thread))'s current run — partial output is kept")
                }
            }.padding(8)
        }
        // The DRAG half of attachments: the whole thread is the drop target —
        // aiming a file at a one-line composer is fiddly; aiming at the
        // conversation you're already looking at is not.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            for u in files { appendAttachment(u) }
            return true
        } isTargeted: { dropTargeted = $0 }
        // Chips are pointers, not typed work: a drop meant for one teammate
        // must not ride silently into whichever thread is opened next (review
        // M5 — this view is reused across thread switches, so @State
        // survives). The draft keeps its pre-existing carry-over behavior.
        .onChange(of: thread) { attachments = [] }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.title3)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(state.displayName(thread))
        // Same DOET grouping as the sidebar: the frequent, harmless action
        // (open the profile) is labelled and primary; the occasional and the
        // consequential (start over, read history) live in one ⋯ menu.
        .toolbar {
            // Jakob's Law (his call 2026-08-13): "start a new chat" has a
            // learned glyph everywhere — square-and-pencil in Claude,
            // ChatGPT, Messages, Mail. Its own button, that icon, no menu
            // hunting for the action people reach for most.
            // Team threads (R3) get Archive instead: there is no session to
            // reset — member sessions are NOT touched.
            if isTeam {
                Button { confirmArchiveTeam = true } label: {
                    Label("Archive thread", systemImage: "archivebox")
                }
                .help("Archive — the group chat moves to history and starts clean; member sessions and memories are untouched")
                .disabled(state.awaiting[thread]?.isEmpty == false)
            } else {
                Button { confirmFresh = true } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
                .help("New session — this chat starts clean; the old one moves to the history menu")
                .disabled(state.busy.contains(thread) || state.forking.contains(thread))
            }
            Button { showProfile = true } label: {
                Label("Profile", systemImage: isTeam ? "person.2.circle" : "person.crop.circle")
            }
            .help(isTeam ? "Team — emoji and members" : "Profile — name, job, model, access, skills")
            // Everything else session-shaped stays one level deeper: history,
            // and resets that affect OTHER teammates.
            Menu {
                let sessions = state.log.archivedSessions(for: thread)
                if !sessions.isEmpty {
                    Section("Previous sessions") {
                        ForEach(sessions, id: \.self) { url in
                            Button(Self.archiveLabel(url, thread: thread)) {
                                viewingArchive = ArchiveItem(url: url)
                            }
                        }
                    }
                }
                Section("Other teammates") {
                    Button("Choose who to reset…") { showFreshPicker = true }
                    Button("New session for everyone…") { confirmFreshAll = true }
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .help("Sessions — start fresh, read a previous one, or reset others")
        }
        .confirmationDialog(
            "Start a fresh session for \(state.displayName(thread))? The chat starts clean; this conversation moves to the history menu (🕐), read-only. Notebook and vault notes stay.",
            isPresented: $confirmFresh, titleVisibility: .visible
        ) {
            Button("New session") { state.freshSession(thread) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "New session for EVERYONE? Each chat archives to its history and starts clean; notebooks and vault notes stay. Busy teammates are skipped.",
            isPresented: $confirmFreshAll, titleVisibility: .visible
        ) {
            Button("Reset the whole team") {
                _ = state.freshSessions(state.roster.agents.map(\.name))
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Archive this group chat? The transcript moves to the history menu (🕐), read-only, and the thread starts clean. Member sessions, notebooks and vault notes are untouched.",
            isPresented: $confirmArchiveTeam, titleVisibility: .visible
        ) {
            Button("Archive thread") { state.archiveTeamThread(thread) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showFreshPicker) { FreshSessionsSheet(state: state) }
        .sheet(isPresented: $showProfile) {
            // A team key would render the AGENT sheet against a nil agent —
            // it gets its own (R3).
            if isTeam { TeamProfileSheet(state: state, teamKey: thread) }
            else { AgentProfileSheet(state: state, agentName: thread) }
        }
        .sheet(item: $viewingArchive) { item in
            ArchivedSessionView(url: item.url, who: { state.displayName($0) },
                                agents: state.roster.agents)
        }
    }

    /// "nina-2026-08-13-140501.jsonl" → "2026-08-13 14:05" (the fork's earlier
    /// date-only archives render as their bare date).
    static func archiveLabel(_ url: URL, thread: String) -> String {
        var stamp = url.deletingPathExtension().lastPathComponent
        if stamp.hasPrefix("\(thread)-") { stamp.removeFirst(thread.count + 1) }
        let parts = stamp.split(separator: "-")
        if parts.count == 4, parts[3].count == 6 {
            let t = parts[3]
            return "\(parts[0])-\(parts[1])-\(parts[2]) \(t.prefix(2)):\(t.dropFirst(2).prefix(2))"
        }
        return stamp
    }

    /// A Claude-app-style answer card: full-width, bordered, tappable.
    @ViewBuilder private func optionCard(_ text: String, muted: Bool = false,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(muted ? .callout : .callout.weight(.medium))
                    .foregroundStyle(muted ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: muted ? "pencil.line" : "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(muted ? 0.06 : 0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(.gray.opacity(0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chips alone are a sendable message — the attachment block carries it.
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Clear the composer only if the message was actually accepted — a busy
        // guard tripping (or a failed attachment copy) must not eat what
        // Lorenzo typed or dropped (review I2).
        if state.send(text, to: thread, attachments: attachments) {
            draft = ""
            attachments = []
        }
    }

    /// The manual half: a standard open panel, multi-select, files or folders
    /// (agents Glob folders fine). Appends as chips — nothing is copied or
    /// sent until Send.
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { appendAttachment(u) }
    }

    /// Dedupe on the standardized path (review M4): the picker and a Finder
    /// drop can hand back differently-spelled URLs for the same file.
    private func appendAttachment(_ u: URL) {
        let path = u.standardizedFileURL.path
        guard !attachments.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        attachments.append(u)
    }

    @ViewBuilder private func bubble(_ msg: ChatMessage) -> some View {
        let who = state.displayName(msg.author)
        let (tint, label): (Color, String) = switch msg.kind {
        case .user:     (.accentColor.opacity(0.18), "You")
        case .agent:    (.gray.opacity(0.15), who)
        case .relayOut: (.orange.opacity(0.18), "\(who) → teammate")   // the target is named in the text
        case .relayIn:  (.orange.opacity(0.18), "↩ \(who) (inter-agent)")
        case .system:   (.yellow.opacity(0.15), "system")   // visible, not .clear
        case .subagent: (.purple.opacity(0.15), "\(who) ⑂ subagent")
        }
        // WHOSE voice is this? (his ask 2026-08-13) In a thread carrying
        // relay legs from several teammates, a name in small grey caption
        // isn't enough — the avatar sits beside the bubble, big enough to
        // recognise at a glance. Lorenzo's own messages and app notes get no
        // avatar: the asymmetry is the signal.
        let speaker = msg.kind == .user || msg.kind == .system
            ? nil : state.roster.agents.first { $0.name == msg.author }
        HStack(alignment: .top, spacing: 8) {
            if let speaker {
                AgentAvatar(agent: speaker, size: 32)
                    .padding(.top, 16)
                    .help(state.displayName(speaker.name))
            }
            bubbleShape(text: msg.text, tint: tint,
                        label: "\(label) · \(Self.ts.string(from: msg.ts))")
        }
        .id(msg.id)
    }

    /// A message waiting its turn: removable, and — when it isn't a relay —
    /// runnable NOW as a subagent (forked copy of the busy teammate).
    private func queuedBubble(_ q: ChatMessage) -> some View {
        // A queued relay names WHO it waits on — a hung target otherwise looks
        // like an unexplained stall (reviewer #5 starvation note).
        let waitingOn = state.parseRelay(q.text).map { " — waiting for \($0.target.display)" } ?? ""
        return HStack(alignment: .top, spacing: 6) {
            bubbleShape(text: q.text, tint: .accentColor.opacity(0.08),
                        label: q.author == "lorenzo"
                            ? "You · queued\(waitingOn.isEmpty ? " — sends when free" : waitingOn)"
                            : "\(q.author.capitalized) · queued relay\(waitingOn)")
            VStack(spacing: 6) {
                Button { state.removeQueued(id: q.id, thread: thread) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
                if state.parseRelay(q.text) == nil, !isTeam {
                    // No ⑂ for group heads: a fork answers as ONE agent — the
                    // button would lie about what runs.
                    Button { state.runQueuedAsSubagent(id: q.id, thread: thread) } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .buttonStyle(.plain)
                    .help("Run now as a subagent — a READ-ONLY forked copy of \(thread.capitalized)'s memory answers in parallel (it can search and browse but not write files); the main \(thread.capitalized) won't remember this exchange")
                }
            }.padding(.top, 14)
        }
        .id(q.id)
    }

    private func bubbleShape(text: String, tint: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            MessageBody(text: text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A previous session's chat, read-only (his ask 2026-08-13 #6): the rotated
/// log rendered with the same bubble styling, no composer.
struct ArchivedSessionView: View {
    let url: URL
    let who: (String) -> String
    /// Same faces as the live thread — history shouldn't look like a
    /// different app.
    let agents: [Agent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Previous session — read-only").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(MessageLog.loadArchive(url)) { msg in
                        HStack(alignment: .top, spacing: 8) {
                            if msg.kind != .user, msg.kind != .system,
                               let a = agents.first(where: { $0.name == msg.author }) {
                                AgentAvatar(agent: a, size: 32).padding(.top, 16)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.kind == .user ? "You" : who(msg.author))
                                    .font(.caption2).foregroundStyle(.secondary)
                                MessageBody(text: msg.text)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(msg.kind == .user ? Color.accentColor.opacity(0.18)
                                                                  : Color.gray.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }.padding()
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

/// Renders an agent message: fenced ``` blocks as monospaced verbatim text
/// (inline-only Markdown parsing was destroying them — fences stripped, newlines
/// collapsed; review #3 I-4), everything else with inline Markdown. Parsed
/// AttributedStrings are cached — LazyVStack re-renders every visible bubble on
/// each update (review #3 minor 12).
struct MessageBody: View {
    let text: String

    private enum Segment: Hashable {
        case prose(String)
        case code(String)
    }

    private static let inlineCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 500   // bounded; NSCache self-evicts under pressure anyway
        return c
    }()

    private static func inline(_ s: String) -> AttributedString {
        if let hit = inlineCache.object(forKey: s as NSString) {
            return AttributedString(hit)
        }
        let parsed = (try? AttributedString(markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        inlineCache.setObject(NSAttributedString(parsed), forKey: s as NSString)
        return parsed
    }

    private static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = [], code: [String] = []
        var inFence = false
        func flushCode() {
            let body = code.joined(separator: "\n")
            // ``` immediately followed by ``` renders an empty dark rectangle —
            // skip it (review #4 minor).
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.code(body))
            }
            code = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            // CRLF input would otherwise leave a trailing \r inside code text.
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    flushCode()
                } else if !prose.isEmpty {
                    segments.append(.prose(prose.joined(separator: "\n"))); prose = []
                }
                inFence.toggle()
                continue
            }
            if inFence { code.append(line) } else { prose.append(line) }
        }
        flushCode()                                                                    // unclosed fence
        if !prose.isEmpty { segments.append(.prose(prose.joined(separator: "\n"))) }
        return segments
    }

    var body: some View {
        let segments = Self.split(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let s):
                    Text(Self.inline(s)).textSelection(.enabled)
                case .code(let s):
                    Text(s)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
