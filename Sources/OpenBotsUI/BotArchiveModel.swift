import Combine
import OpenBotsDomain
import OpenBotsServices
import SwiftUI

/// Owns the reversible archive list and operation feedback, never a transcript.
@MainActor
public final class BotArchiveModel: ObservableObject {
    @Published public var isPresented = false
    @Published public private(set) var archivedBots: [Teammate] = []
    @Published public private(set) var archivedTeams: [Team] = []
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    private let service: any TeammateArchiving
    private let teamService: (any TeamArchiving)?

    public init(service: any TeammateArchiving, teamService: (any TeamArchiving)? = nil) {
        self.service = service
        self.teamService = teamService
    }

    /// Whether teams can be archived here at all.
    public var supportsTeams: Bool { teamService != nil }

    public func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { archivedBots = try await service.archivedTeammates() }
        catch { errorMessage = "Couldn’t load archived bots. Your saved bots are unchanged." }
        guard let teamService else { return }
        do { archivedTeams = try await teamService.archivedTeams() }
        catch { errorMessage = "Couldn’t load archived teams. Your saved teams are unchanged." }
    }

    func archiveTeam(_ team: Team, prepare: @MainActor () async throws -> Void) async -> Team? {
        guard !isBusy, let teamService else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await prepare()
            try Task.checkCancellation()
            let saved = try await teamService.archiveTeam(id: team.id, expectedUpdatedAt: team.updatedAt)
            archivedTeams.removeAll { $0.id == saved.id }
            archivedTeams.append(saved)
            return saved
        } catch { errorMessage = Self.teamMessage(for: error); return nil }
    }

    func restoreTeam(_ team: Team) async -> Team? {
        guard !isBusy, let teamService else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await teamService.restoreTeam(id: team.id, expectedUpdatedAt: team.updatedAt)
            archivedTeams.removeAll { $0.id == saved.id }
            return saved
        } catch { errorMessage = Self.teamMessage(for: error); return nil }
    }

    static func teamMessage(for error: Error) -> String {
        if let preparation = error as? ArchivePreparationError { return preparation.message }
        switch error as? TeamArchiveError {
        case .unresolvedWork: return "This team still has work in progress or a handoff waiting for you. Let it finish or stop it before archiving. Nothing was cancelled."
        case .staleTeam: return "This team changed in another operation. Try again."
        case .notFound, .invalidTransition: return "This team is no longer in the expected state. Refresh Archived and try again."
        default: return "Couldn’t change this team’s archive state. Your saved data is preserved."
        }
    }

    func archive(_ teammate: Teammate, prepare: @MainActor () async throws -> Void) async -> Teammate? {
        guard !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await prepare()
            try Task.checkCancellation()
            let saved = try await service.archiveTeammate(id: teammate.id, expectedProfileRevision: teammate.profile.revision)
            archivedBots.removeAll { $0.id == saved.id }
            archivedBots.append(saved)
            return saved
        } catch { errorMessage = Self.message(for: error); return nil }
    }

    func restore(_ teammate: Teammate) async -> Teammate? {
        guard !isBusy else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await service.restoreTeammate(id: teammate.id, expectedProfileRevision: teammate.profile.revision)
            archivedBots.removeAll { $0.id == saved.id }
            return saved
        } catch { errorMessage = Self.message(for: error); return nil }
    }

    private static func message(for error: Error) -> String {
        if let preparation = error as? ArchivePreparationError { return preparation.message }
        if let taken = error as? TeammateNameTakenError {
            return "There is already a bot called \(taken.existingName). Rename that bot first, then restore this one."
        }
        switch error as? TeammateArchiveError {
        case .unresolvedWork: return "This bot still has work in progress. Let it finish or stop it before archiving. Nothing was cancelled."
        case .staleRevision: return "This bot changed in another operation. Reopen its details or refresh Archived before trying again."
        case .notFound, .invalidTransition: return "This bot is no longer in the expected state. Refresh the bot list before trying again."
        default: return "Couldn’t change this bot’s archive state. Your saved data is preserved."
        }
    }
}

enum ArchivePreparationError: Error {
    case draftNotSaved, unfinishedEdits, profileOperationPending, unresolvedLocalWork, navigationChanged
    case teamWorkInProgress, teamMessageSaving, messageSavingElsewhere, workerRunning

    var message: String {
        switch self {
        case .draftNotSaved: "The draft could not be saved. Keep this conversation open and resolve its save error before archiving."
        case .unfinishedEdits: "Save or cancel this bot’s unfinished profile edits before archiving."
        case .profileOperationPending: "Wait for this bot’s profile save or photo import to finish before archiving."
        case .unresolvedLocalWork: "Wait for this bot’s message or attachment to finish saving before archiving."
        case .navigationChanged: "The open conversation changed. Select the bot and try archiving again."
        case .teamWorkInProgress: "This team still has work in progress or a handoff waiting for you. Let it finish or stop it before archiving. Nothing was cancelled."
        case .teamMessageSaving: "Wait for the message in this team’s chat to finish saving before archiving."
        case .messageSavingElsewhere: "Wait for the message you just sent to finish saving, then archive again."
        case .workerRunning: "This bot has a background worker running. Let it finish, then archive. Nothing was cancelled."
        }
    }
}

struct ArchivedBotsView: View {
    @ObservedObject var model: BotArchiveModel
    let restore: @MainActor (Teammate) async -> Void
    var restoreTeam: (@MainActor (Team) async -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Archived").font(.title2).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { model.isPresented = false }.keyboardShortcut(.cancelAction)
            }
            Text(model.supportsTeams
                 ? "Archived bots and teams keep their messages, files and settings. Restore brings one back as it was, without starting work."
                 : "Archived bots keep their messages, drafts, files and settings. Restore brings the same bot back without starting work.")
                .foregroundStyle(.secondary)
            // One list, one scroll: two lists split the window and hid rows.
            List {
                Section(model.supportsTeams ? "Bots" : "") {
                    ForEach(model.archivedBots) { bot in
                        HStack(spacing: 12) {
                            CharacterIdentityView(identity: TeammateIdentitySnapshot(bot), activity: .idle, size: 36)
                            VStack(alignment: .leading) {
                                Text(bot.profile.displayName).font(.headline)
                                Text(bot.profile.role).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { Task { await restore(bot) } }
                                .accessibilityLabel("Restore \(bot.profile.displayName)")
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Restore Bot") { [bot] in Task { await restore(bot) } }
                                .disabled(model.isBusy)
                        }
                    }
                    if model.archivedBots.isEmpty, !model.isBusy {
                        Text("No archived bots").foregroundStyle(.secondary)
                    }
                }
                if model.supportsTeams, let restoreTeam {
                    Section("Teams") {
                        ForEach(model.archivedTeams) { team in
                            HStack(spacing: 12) {
                                Image(systemName: "person.3").frame(width: 36).accessibilityHidden(true)
                                Text(team.name).font(.headline)
                                Spacer()
                                Button("Restore") { Task { await restoreTeam(team) } }
                                    .accessibilityLabel("Restore team \(team.name)")
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("Restore Team") { [team] in Task { await restoreTeam(team) } }
                                    .disabled(model.isBusy)
                            }
                        }
                        if model.archivedTeams.isEmpty, !model.isBusy {
                            Text("No archived teams").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Button("Refresh") { Task { await model.load() } }
                if model.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Updating the archive") }
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 360, idealHeight: 420)
        .disabled(model.isBusy)
        .task { await model.load() }
        .alert("Archive or Restore", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK", role: .cancel) { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
    }
}
