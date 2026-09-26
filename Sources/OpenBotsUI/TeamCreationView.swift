import Combine
import OpenBotsServices
import SwiftUI

/// Which team this sheet is bounding: a team that does not exist yet, or the
/// one the user already has open.
public enum TeamCreationMode: Equatable, Sendable {
    case create
    case edit
}

/// Process-local state for the bounded team creation sheet. Construction is
/// inert: nothing is written until the injected submission closure runs.
@MainActor
public final class TeamCreationModel: ObservableObject, Identifiable {
    public typealias Submission = @MainActor @Sendable (_ name: String, _ leadID: UUID, _ memberIDs: Set<UUID>) async throws -> Void
    public static let maximumNameLength = 120

    public nonisolated let id = UUID()
    public let mode: TeamCreationMode
    public let candidates: [TeammateIdentitySnapshot]
    @Published public var name = "New Team"
    @Published public private(set) var selectedMemberIDs: Set<UUID> = []
    @Published public var leadID: UUID?
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var submissionError: String?
    private let submitAction: Submission
    private var hasSubmittedSuccessfully = false
    /// Whether a save was refused because someone else had changed this team.
    /// The roster on screen was read before theirs, so saving it again would
    /// publish it over theirs; the refusal stands until the sheet is reopened,
    /// which is what its message tells the user to do.
    private var wasRefusedByAnotherWriter = false

    /// `name`, `memberIDs` and `leadID` seed an edit with what the team holds
    /// today. Seeds are filtered to the candidates, and a lead outside the
    /// seeded members is dropped, so the picker never points outside itself.
    public init(mode: TeamCreationMode = .create, candidates: [TeammateIdentitySnapshot],
                name: String? = nil, memberIDs: Set<UUID> = [], leadID: UUID? = nil,
                submit: @escaping Submission) {
        self.mode = mode
        let sorted = candidates.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.candidates = sorted
        if let name { self.name = name }
        let seeded = memberIDs.intersection(sorted.map(\.id))
        self.selectedMemberIDs = seeded
        self.leadID = leadID.flatMap { seeded.contains($0) ? $0 : nil }
        self.submitAction = submit
    }

    public var title: String { mode == .create ? "New Team" : "Team Settings" }
    public var submitTitle: String { mode == .create ? "Create Team" : "Save Changes" }
    public var submitIdentifier: String { mode == .create ? "team-create" : "team-save" }
    public var submitHelp: String { mode == .create ? "Create Team" : "Save the team\u{2019}s members and lead" }
    public var summary: String {
        mode == .create
            ? "Pick the bots that belong to this team and choose a lead. The lead answers messages that name nobody; @Name sends to one member."
            : "Change this team\u{2019}s name, who belongs to it and who leads it. The lead answers messages that name nobody; @Name sends to one member."
    }

    public var selectedMembers: [TeammateIdentitySnapshot] { candidates.filter { selectedMemberIDs.contains($0.id) } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canSubmit: Bool {
        guard !isSubmitting, !hasSubmittedSuccessfully, !wasRefusedByAnotherWriter, !trimmedName.isEmpty,
              trimmedName.count <= Self.maximumNameLength, selectedMemberIDs.count >= 2,
              let leadID, selectedMemberIDs.contains(leadID) else { return false }
        return true
    }

    public func isSelected(_ id: UUID) -> Bool { selectedMemberIDs.contains(id) }

    /// The first selected member becomes the lead. Removing the lead hands the
    /// role to the first remaining member while a team is being created, where
    /// no lead has been chosen yet and the picker must never point outside the
    /// selection. An edit leaves the role empty instead: the lead answers every
    /// message that names nobody, so a team already has one the user picked,
    /// and `canSubmit` holds the save until a replacement is named rather than
    /// handing the role to whichever member sorts first.
    public func toggleMember(_ id: UUID) {
        guard !isSubmitting else { return }
        if selectedMemberIDs.contains(id) {
            selectedMemberIDs.remove(id)
            if leadID == id { leadID = mode == .create ? selectedMembers.first?.id : nil }
        } else {
            selectedMemberIDs.insert(id)
            if leadID == nil { leadID = id }
        }
    }

    @discardableResult
    public func submit() async -> Bool {
        // Clearing the message first would leave a dead Save control with
        // nothing on screen explaining why it is dead.
        guard !wasRefusedByAnotherWriter else { return false }
        submissionError = nil
        guard canSubmit, let leadID else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await submitAction(trimmedName, leadID, selectedMemberIDs)
            hasSubmittedSuccessfully = true
            return true
        } catch TeamChatError.teamChangedElsewhere {
            // The team did change, just not by this edit; saying it is
            // unchanged would be false.
            wasRefusedByAnotherWriter = true
            submissionError = "Someone else changed this team while it was open. Nothing was saved; "
                + "close and reopen the editor to see the current roster."
            return false
        } catch {
            submissionError = mode == .create
                ? "OpenBots couldn’t create this team. Nothing was saved."
                : "OpenBots couldn’t save these changes. The team is unchanged."
            return false
        }
    }
}

public struct TeamCreationView: View {
    @ObservedObject private var model: TeamCreationModel
    private let onCancel: @MainActor () -> Void
    /// The bots whose own settings this sheet can open. Held separately from
    /// the checkboxes on purpose: those are an unsaved draft of the roster,
    /// while this is the roster that exists, so a control is only offered where
    /// it actually leads somewhere and no checkbox makes one appear or vanish.
    private let memberSettingsTargets: Set<UUID>
    private let openMemberSettings: (@MainActor (UUID) -> Void)?

    public init(model: TeamCreationModel, onCancel: @escaping @MainActor () -> Void,
                memberSettingsTargets: Set<UUID> = [],
                openMemberSettings: (@MainActor (UUID) -> Void)? = nil) {
        self.model = model
        self.onCancel = onCancel
        self.memberSettingsTargets = memberSettingsTargets
        self.openMemberSettings = openMemberSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            Text(model.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(model.summary)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Team name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("team-name")
                .help("Team name")
            Text("Members").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    ForEach(model.candidates) { candidate in
                        HStack(spacing: OpenBotsVisualStyle.spacing8) {
                            Toggle(isOn: Binding(get: { model.isSelected(candidate.id) }, set: { _ in model.toggleMember(candidate.id) })) {
                                HStack(spacing: OpenBotsVisualStyle.spacing8) {
                                    CharacterIdentityView(teammate: TeammateRowSnapshot(identity: candidate, activity: .idle), size: 26)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.name).font(.callout.weight(.medium))
                                        Text(candidate.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Member \(candidate.name)")
                            .help("Member \(candidate.name)")
                            Spacer(minLength: OpenBotsVisualStyle.spacing8)
                            if let openMemberSettings, memberSettingsTargets.contains(candidate.id) {
                                Button("Settings") { openMemberSettings(candidate.id) }
                                    .accessibilityLabel("Settings for \(candidate.name)")
                                    .accessibilityHint("Closes this sheet and opens that bot’s own settings")
                                    .help("Settings for \(candidate.name)")
                                    .accessibilityIdentifier("team-editor-member-settings-\(candidate.id.uuidString)")
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
            Picker("Lead", selection: $model.leadID) {
                ForEach(model.selectedMembers) { member in
                    Text(member.name).tag(Optional(member.id))
                }
            }
            .disabled(model.selectedMembers.isEmpty)
            .accessibilityLabel("Team lead")
            .help("Team lead")
            if let error = model.submissionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("team-cancel").help("Cancel")
                Button(model.submitTitle) { Task { await model.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier(model.submitIdentifier)
                    .help(model.submitHelp)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
