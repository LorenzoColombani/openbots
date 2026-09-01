import OpenBotsDomain
import SwiftUI

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
    var modelStatus: ClaudeModelRunPresentation? = nil

    var body: some View {
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
                Button(action: onClose) { Image(systemName: "sidebar.right") }
                    .accessibilityLabel("Close details")
                    .help("Collapse details")
            }
            .buttonStyle(.plain)
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        CharacterIdentityView(identity: TeammateIdentitySnapshot(teammate), activity: .idle, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(teammate.profile.displayName).font(.headline)
                            if let label = teammate.profile.title {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ClaudeModelStatusView(savedChoice: teammate.requestedClaudeModel,
                                          savedEffort: teammate.requestedClaudeEffort,
                                          savedContextWindow: teammate.requestedClaudeContextWindow, status: modelStatus)
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 30))
                        Text("Computer unavailable").font(.callout.weight(.medium))
                        Text("Computer access requires an approved execution backend.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(12)
                    .background(OpenBotsVisualStyle.canvas(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Computer preview unavailable")
                    VStack(alignment: .leading, spacing: 8) {
                        Button {} label: {
                            Label("Create Routine", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(true)
                        Text("Routines are unavailable until scheduling is implemented.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let description = teammate.profile.detailedInstructions, !description.isEmpty {
                        Text("Description").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(description).font(.callout).textSelection(.enabled)
                    } else {
                        Text("No description yet. Open bot settings to edit this profile.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    Button(action: onArchive) { Label("Archive Bot", systemImage: "archivebox") }
                        .disabled(!canArchive)
                        .accessibilityIdentifier("archive-bot")
                    Text("Remove this bot from the active list. Messages, drafts, files and settings stay saved. Restore it from Archived Bots.")
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
            } else if let observed = status?.observedAtStart {
                Text("Startup reported: \(ClaudeModelCatalog.label(for: observed)). A successful result has not been confirmed.")
            } else {
                Text("No model observation is loaded in this app session.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
