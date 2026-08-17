import SwiftUI
import AgencyKit
import UniformTypeIdentifiers

/// A teammate's profile: edit identity (role/emoji/model) without touching
/// their memory, and give them skills EXPLICITLY (his ruling: no inherited
/// add-ons — capabilities are granted per agent, inspectable on disk).
struct AgentProfileSheet: View {
    @ObservedObject var state: AppState
    let agentName: String
    @Environment(\.dismiss) private var dismiss

    @State private var emoji = ""
    @State private var role = ""
    @State private var displayName = ""
    @State private var instructions = ""
    @State private var title = ""
    @State private var primaryJob = ""
    @State private var duplicateName = ""
    @State private var showDuplicate = false
    @State private var notifications = true
    @State private var confirmArchive = false
    @State private var model = "sonnet"
    @State private var skills: [String] = []
    @State private var grants: Set<String> = []
    @State private var enabledCatalog: [Connector] = []
    @State private var shellAccess = false
    @State private var webAccess = false
    @State private var library: [String] = []
    @State private var libraryFilter = ""
    // ONE file importer for both pickers: SwiftUI silently breaks all but one
    // `.fileImporter` in a view, so a second one (the avatar) never presented —
    // "Choose image…" did nothing. `pickerOpen` drives presentation; `pickerKind`
    // selects the allowed types AND the action, and survives the callback.
    private enum PickerKind { case skill, avatar }
    @State private var pickerOpen = false
    @State private var pickerKind: PickerKind = .skill
    @State private var error: String?

    private var filteredLibrary: [String] {
        libraryFilter.isEmpty ? library
            : library.filter { $0.localizedCaseInsensitiveContains(libraryFilter) }
    }

    private static let models = ["haiku", "sonnet", "opus"]

    private var agent: Agent? { state.roster.agents.first { $0.name == agentName } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Image wins when set; otherwise the live-edited emoji.
                if let a = agent, a.avatarPath != nil {
                    AgentAvatar(agent: a, size: 48)
                } else {
                    Text(emoji).font(.largeTitle).frame(width: 48, height: 48)
                }
                VStack(alignment: .leading) {
                    Text(state.displayName(agentName)).font(.title2.bold())
                    Text("Editing identity never touches memory or history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Everything between the header and the button row scrolls (his
            // screenshot 2026-08-13: with 12 connectors the sheet outgrew the
            // display, cut off the buttons, and SwiftUI compressed the Role
            // field to zero height trying to make it fit).
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
            // Labeled sections — Lorenzo asked twice tonight where roles live;
            // unlabeled fields are the reason.
            // Layout follows his screenshot 2026-08-13: Name, Title,
            // Description first and plain — everything we added over time
            // (model, access, skills, connectors) sits BELOW, out of the way.
            Text("Name").font(.caption).foregroundStyle(.secondary)
            TextField("Display name (empty = \(agentName.capitalized))", text: $displayName)
            Text("Title").font(.caption).foregroundStyle(.secondary)
            TextField("Describe what your agent does", text: $title)
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextField("What this agent is for", text: $role, axis: .vertical)
                .lineLimit(3...6)

            // His screenshot: the notifications card sits right under the
            // three plain fields.
            Toggle(isOn: $notifications) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(.headline)
                    Text("Get notified when this agent finishes or needs input")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(10)
            .background(.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            Divider()
            Text("Avatar").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Choose image…") { pickerKind = .avatar; pickerOpen = true }
                if agent?.avatarPath != nil {
                    Button("Use emoji") {
                        do { _ = try state.store.clearAvatar(for: agentName); state.reload() }
                        catch { self.error = "could not clear avatar: \(error.localizedDescription)" }
                    }
                }
                Text("An image replaces the emoji in the sidebar and here. Applies immediately.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Emoji — the fallback when no image is set").font(.caption).foregroundStyle(.secondary)
            TextField("Emoji", text: $emoji)
            // The @handle can never change (folders, relays, session key hang
            // off it) — say so quietly rather than with a field.
            Text("@\(agentName) — their permanent handle for relays")
                .font(.caption2).foregroundStyle(.tertiary)
            // Standing instructions (R2): stored in the ROSTER, rendered into
            // the persona — so they survive the launch-time regeneration that
            // used to wipe hand-edited CLAUDE.md files.
            Text("Standing instructions — your own rules for this teammate; they survive app restarts (\(instructions.count)/\(AgentStore.maxInstructions))")
                .font(.caption).foregroundStyle(.secondary)
            TextField("e.g. Always draft, never send without asking. Sign off as “The Agency”.",
                      text: $instructions, axis: .vertical)
                .lineLimit(3...8)

            Picker("Model", selection: $model) {
                // A roster row with a model outside the standard three would
                // otherwise render a blank picker while Save writes state anyway.
                if !Self.models.contains(model) { Text(model).tag(model) }
                ForEach(Self.models, id: \.self) { m in
                    Text(m == AgentStore.suggestModel(forRole: role) ? "\(m) (suggested for this role)" : m)
                        .tag(m)
                }
            }

            Divider()

            Toggle(isOn: $shellAccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shell access").font(.headline)
                    Text("Command-line tools — grep, ffmpeg, jq, anything from Homebrew. For teammates that crunch files and transcripts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $webAccess) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web access").font(.headline)
                    Text("Search + fetch the internet (WebSearch, WebFetch). Off by default — web is a door OUT of the machine, so grant it only to teammates whose job needs the live web.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            HStack {
                Text("Skills").font(.headline)
                Spacer()
                Button("Add from file…") { pickerKind = .skill; pickerOpen = true }
            }
            Text("Tick skills from your library to grant them — each is COPIED into this teammate's own folder (inspectable, theirs). Applies immediately, unlike the fields above.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Filter your \(library.count)-skill library…", text: $libraryFilter)
                .textFieldStyle(.roundedBorder).controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLibrary, id: \.self) { skill in
                        Toggle(isOn: Binding(
                            get: { skills.contains(skill) },
                            set: { on in
                                do {
                                    if on {
                                        let src = URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/skills/\(skill)")
                                        try state.store.addSkill(from: src, to: agentName)
                                    } else {
                                        try state.store.removeSkill(skill, from: agentName)
                                    }
                                } catch { self.error = "\(error.localizedDescription)" }
                                skills = state.store.listSkills(for: agentName)
                            }
                        )) { Text(skill).font(.callout) }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 130)
            // Granted skills that came from a FILE (not the library) still show,
            // removable, below the list.
            let nonLibrary = skills.filter { !library.contains($0) }
            ForEach(nonLibrary, id: \.self) { skill in
                HStack {
                    Image(systemName: "sparkles")
                    Text(skill).font(.callout)
                    Spacer()
                    Button(role: .destructive) {
                        do {
                            try state.store.removeSkill(skill, from: agentName)
                        } catch {
                            self.error = "could not remove skill: \(error.localizedDescription)"
                        }
                        skills = state.store.listSkills(for: agentName)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            Text("Connectors").font(.headline)
            Text("Granted from the app-wide catalog (⚡ toolbar) — least privilege, per teammate.")
                .font(.caption).foregroundStyle(.secondary)
            if enabledCatalog.isEmpty {
                Text("No connectors enabled app-wide yet.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(enabledCatalog) { c in
                    Toggle(isOn: Binding(
                        get: { grants.contains(c.id) },
                        set: { if $0 { grants.insert(c.id) } else { grants.remove(c.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Text(c.displayName)
                            if c.requiresSetup {
                                Text("needs setup").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.yellow.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }

              }
            }   // end of the scrolling middle

            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            HStack {
                // A poisoned/stuck conversation gets a clean slate without
                // touching files (his ask 2026-08-13: the librarian kept
                // ruminating on yesterday's session).
                Button {
                    state.freshSession(agentName)
                    self.error = "✓ fresh session — the chat starts clean; the old one is in the history menu (🕐)"
                } label: {
                    Label("New session", systemImage: "arrow.counterclockwise")
                }
                .help("New conversation + clean chat — the old chat moves to the thread's history menu, read-only")
                // Retire = archive, never delete (his call): everything moves to
                // agents/.archived/, nothing is destroyed, fences regenerate.
                Button { duplicateName = agentName + "2"; showDuplicate = true } label: {
                    Label("Duplicate…", systemImage: "person.badge.plus")
                }
                .help("Hire a copy: same job, grants, instructions and skills — but a blank conversation and an empty notebook")
                Button(role: .destructive) { confirmArchive = true } label: {
                    Label("Retire…", systemImage: "archivebox")
                }
                .help("Archive this teammate — conversations and notes are kept in agents/.archived/, nothing is deleted")
                .confirmationDialog(
                    "Retire \(agentName.capitalized)? The roster row is removed; all files move to agents/.archived/ (nothing is deleted).",
                    isPresented: $confirmArchive, titleVisibility: .visible
                ) {
                    Button("Retire \(agentName.capitalized)", role: .destructive) {
                        do {
                            if try state.archiveAgent(agentName) { dismiss() }
                            else { self.error = "\(agentName.capitalized) is mid-run — stop the run first, then retire." }
                        } catch { self.error = "could not archive: \(error.localizedDescription)" }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        _ = try state.store.updateAgent(name: agentName, emoji: emoji,
                                                        role: role, model: model,
                                                        displayName: displayName,
                                                        title: title, primaryJob: primaryJob)
                        _ = try state.store.setInstructions(instructions, for: agentName)
                        _ = try state.store.setNotifications(notifications, for: agentName)
                        _ = try state.store.setConnectors(Array(grants), for: agentName)
                        _ = try state.store.setShell(shellAccess, for: agentName)
                        _ = try state.store.setWeb(webAccess, for: agentName)
                        state.reload(); dismiss()
                    } catch { self.error = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(role.isEmpty)
            }
        }
        // Fixed height + scrolling middle (his screenshot): the sheet must
        // never outgrow the display however long the connector list gets.
        .padding(20).frame(width: 480, height: 700)
        .onAppear {
            guard let a = agent else { return }
            emoji = a.emoji; role = a.role
            displayName = a.displayName ?? ""
            instructions = a.instructions ?? ""
            title = a.title ?? ""
            primaryJob = a.primaryJob ?? ""
            notifications = a.notifications != false
            model = a.model ?? AgentStore.suggestModel(forRole: a.role)
            skills = state.store.listSkills(for: agentName)
            grants = Set(a.connectors ?? [])
            shellAccess = a.shell ?? false
            webAccess = a.web ?? false
            library = AgentStore.availableUserSkills()
            // Grants come from the ENABLED subset — plus anything already
            // granted (so a catalog-disable never hides an existing grant).
            let enabledIDs = state.catalog.enabledIDs().union(grants)
            enabledCatalog = Connector.catalog.filter { enabledIDs.contains($0.id) }
        }
        .alert("Duplicate \(state.displayName(agentName))", isPresented: $showDuplicate) {
            TextField("New handle", text: $duplicateName)
            Button("Duplicate") {
                do {
                    let copy = try state.store.duplicateAgent(agentName, as: duplicateName)
                    state.reload(); state.selected = copy.name; dismiss()
                } catch { self.error = "could not duplicate: \(error)" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies the job, grants, standing instructions and taught skills. The copy starts with a blank conversation and an empty notebook — memory is never duplicated.")
        }
        .fileImporter(isPresented: $pickerOpen,
                      allowedContentTypes: pickerKind == .avatar
                          ? [.image]
                          : [.folder, UTType(filenameExtension: "md") ?? .plainText],
                      allowsMultipleSelection: false) { result in
            // pickerKind is untouched by the presentation binding, so it's still
            // valid here — it tells us which action the picked file feeds.
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                switch pickerKind {
                case .avatar:
                    // Validate it actually decodes (review round 2, issue 8) —
                    // otherwise a non-image silently keeps the emoji, which is
                    // indistinguishable from the "button did nothing" bug just fixed.
                    guard NSImage(contentsOf: url) != nil else {
                        self.error = "That file isn't a readable image."; return
                    }
                    _ = try state.store.setAvatar(from: url, for: agentName); state.reload()
                case .skill:
                    try state.store.addSkill(from: url, to: agentName)
                    skills = state.store.listSkills(for: agentName)
                }
            } catch {
                self.error = pickerKind == .avatar
                    ? "could not set avatar: \(error.localizedDescription)"
                    : "could not add skill: \(error.localizedDescription)"
            }
        }
    }
}
