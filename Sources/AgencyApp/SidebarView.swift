import SwiftUI
import AgencyKit

struct SidebarView: View {
    @ObservedObject var state: AppState
    var body: some View {
        List(selection: $state.selected) {
            // Teams first when any exist (R3): a group thread is where multi-
            // agent work happens; solo threads below.
            if let teams = state.roster.teams, !teams.isEmpty {
                Section("Teams") {
                    ForEach(teams) { team in
                        let key = TeamThreads.key(for: team.name)
                        HStack(spacing: 10) {
                            TeamAvatar(team: team, size: 56)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(team.name.capitalized).font(.headline)
                                Text(team.members.map { state.displayName($0) }
                                        .joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            // Spinner iff THIS team's group run is in flight —
                            // awaiting[key] exists precisely then. busy can't
                            // tell a member's 1:1 work from group work.
                            if state.awaiting[key]?.isEmpty == false {
                                ProgressView().controlSize(.small)
                            } else if let reason = state.attention(key) {
                                Circle()
                                    .fill(reason == "new reply" ? Color.accentColor : Color.orange)
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                                    .help(reason)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(key)
                    }
                }
            }
            Section((state.roster.teams?.isEmpty ?? true) ? "" : "Teammates") {
            ForEach(state.roster.agents) { agent in
                HStack(spacing: 10) {
                    // 56pt (his ask 2026-08-13, twice): the sidebar is where
                    // he checks that a picture upload actually took, so the
                    // face is the row — not a decoration beside the text.
                    AgentAvatar(agent: agent, size: 56)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.display).font(.headline)
                        Text(agent.title ?? agent.role)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if state.busy.contains(agent.name) {
                        ProgressView().controlSize(.small)
                    } else if let reason = state.attention(agent.name) {
                        // One dot, one meaning: orange = it needs a decision
                        // from him, blue = there's something new to read.
                        // 12pt, not 8: beside a 56pt avatar an 8pt dot
                        // disappeared (his report — no badge seen at all).
                        Circle()
                            .fill(reason == "new reply" ? Color.accentColor : Color.orange)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .help(reason)
                    }
                }
                .padding(.vertical, 5)
                .tag(agent.name)
            }
            .onMove { indices, destination in
                // Drag to reorder (his ask): the roster array is the order.
                var names = state.roster.agents.map(\.name)
                names.move(fromOffsets: indices, toOffset: destination)
                state.reorder(names)
            }
            }
        }
        .navigationTitle("Agency")
        // Toolbar organised the DOET way (his ask 2026-08-13): grouped by
        // FREQUENCY and CONSEQUENCE rather than as a row of equal glyphs.
        // - the one constructive, frequent action is labelled and primary;
        // - everything occasional or resetting hides in one overflow, so a
        //   slip can't hit "reset the whole team" while reaching for "+";
        // - the same ⋯ idiom appears in the thread toolbar (consistency).
        .toolbar {
            // "+" grew a second constructive act (R3): one menu, same glyph,
            // both creations — the DOET grouping survives.
            Menu {
                Button("New teammate") { state.hireNeutral() }
                Button("New team…") { state.showNewTeam = true }
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("New teammate (they introduce themselves) or a new team (a group thread)")
            Button(action: { state.showConnectors = true }) {
                Label("Connectors", systemImage: "powerplug")
            }
            .help("Connectors — the app-wide catalog; grants are per agent")
        }
        .sheet(isPresented: $state.showCreate) { CreateAgentSheet(state: state) }
        .sheet(isPresented: $state.showConnectors) { ConnectorsPanel(state: state) }
        .sheet(isPresented: $state.showNewTeam) { NewTeamSheet(state: state) }
    }
}

/// Pick-who bulk reset (his ask 2026-08-13): checkboxes, one click, no
/// per-profile spelunking.
struct FreshSessionsSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New sessions").font(.headline)
            Text("Each chosen teammate starts a clean chat + fresh conversation; the old chat moves to its 🕐 history. Notebooks and vault notes stay. Busy teammates are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(state.roster.agents) { a in
                Toggle(isOn: Binding(
                    get: { selected.contains(a.name) },
                    set: { if $0 { selected.insert(a.name) } else { selected.remove(a.name) } }
                )) {
                    HStack(spacing: 6) {
                        Text("\(a.emoji) \(a.display)")
                        if state.busy.contains(a.name) || state.forking.contains(a.name) {
                            Text("busy — will be skipped").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            if let report { Text(report).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start \(selected.count) fresh session\(selected.count == 1 ? "" : "s")") {
                    let result = state.freshSessions(Array(selected))
                    if result.skipped.isEmpty { dismiss() }
                    else {
                        report = "✓ \(result.done.count) reset — skipped (busy): \(result.skipped.joined(separator: ", "))"
                        selected = Set(result.skipped)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { selected = Set(state.roster.agents.map(\.name)) }
    }
}
