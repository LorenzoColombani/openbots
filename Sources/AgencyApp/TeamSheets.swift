import SwiftUI
import AgencyKit

/// New team (R3): name + emoji + 2–6 member checkboxes — the Grok Bot flow
/// ("New chat → select 2–6 Bots"), inside the existing sheet idiom.
struct NewTeamSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "👥"
    @State private var members: Set<String> = []
    @State private var error: String?

    private var nameValid: Bool { AgentStore.isValidName(name) }
    private var countValid: Bool { (2...AgentStore.maxTeamMembers).contains(members.count) }
    /// Only onboarded teammates: a group turn assumes a configured colleague,
    /// not a mid-interview blank.
    private var candidates: [Agent] {
        state.roster.agents.filter { $0.onboarded != false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New team").font(.title2.bold())
            HStack(spacing: 10) {
                TextField("👥", text: $emoji)
                    .frame(width: 44)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                TextField("team name (lowercase, no spaces)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            if !name.isEmpty && !nameValid {
                Text("letters, digits, - and _ only").font(.caption).foregroundStyle(.orange)
            }
            Text("Members — pick 2 to \(AgentStore.maxTeamMembers)")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { agent in
                        Toggle(isOn: Binding(
                            get: { members.contains(agent.name) },
                            set: { on in
                                if on { members.insert(agent.name) }
                                else { members.remove(agent.name) }
                            })) {
                            HStack(spacing: 8) {
                                AgentAvatar(agent: agent, size: 24)
                                Text(agent.display)
                            }
                        }
                        .disabled(!members.contains(agent.name)
                                  && members.count >= AgentStore.maxTeamMembers)
                    }
                }
            }
            .frame(maxHeight: 260)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create team") {
                    do {
                        let t = try state.store.createTeam(name, members: Array(members).sorted(),
                                                           emoji: emoji.isEmpty ? nil : emoji)
                        state.reloadNow()
                        state.selected = TeamThreads.key(for: t.name)
                        dismiss()
                    } catch { self.error = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameValid || !countValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Team profile (R3): emoji + membership, using only existing store APIs.
/// There is deliberately no delete — runtime data is sacred.
struct TeamProfileSheet: View {
    @ObservedObject var state: AppState
    let teamKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    @State private var error: String?

    private var team: Team? { state.team(forKey: teamKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let team {
                HStack(spacing: 10) {
                    TeamAvatar(team: team, size: 44)
                    Text(team.name.capitalized).font(.title2.bold())
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("Emoji").font(.headline)
                    TextField(team.emoji ?? "👥", text: $emoji)
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                    Button("Set") {
                        try? state.store.setTeamEmoji(emoji, for: team.name)
                        state.reloadNow()
                        emoji = ""
                    }
                    .disabled(emoji.isEmpty)
                }
                Text("Members").font(.headline)
                ForEach(state.roster.agents.filter { $0.onboarded != false }) { agent in
                    Toggle(isOn: Binding(
                        get: { team.members.contains(agent.name) },
                        set: { on in
                            do {
                                if on { _ = try state.store.addTeamMember(agent.name, to: team.name) }
                                else { _ = try state.store.removeTeamMember(agent.name, from: team.name) }
                                state.reloadNow()
                            } catch { self.error = "\(error)" }
                        })) {
                        HStack(spacing: 8) {
                            AgentAvatar(agent: agent, size: 24)
                            Text(agent.display)
                        }
                    }
                    .disabled(!team.members.contains(agent.name)
                              && team.members.count >= AgentStore.maxTeamMembers)
                }
                if team.members.count < 2 {
                    Text("Below 2 members — group sends will warn.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Shared notes pocket: vault/teams/\(team.name)/ (members + you). "
                     + "The transcript itself is yours alone — members receive it inside their turns.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                Text("This team no longer exists.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 420)
    }
}
