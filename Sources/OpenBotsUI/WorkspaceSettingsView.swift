import Combine
import SwiftUI

/// Public presentation-only navigation for the native global Settings scene.
/// Selecting a section never starts connection checks or changes permissions.
public enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case computer = "Computer"
    case usage = "Usage & Billing"
    case updates = "Updates"

    public var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .computer: "desktopcomputer"
        case .usage: "chart.bar"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor
public final class WorkspaceSettingsNavigation: ObservableObject {
    @Published public var selection: WorkspaceSettingsSection?

    public init(selection: WorkspaceSettingsSection? = .general) {
        self.selection = selection
    }
}

@MainActor
public struct WorkspaceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var closeTarget = UtilityOwningWindowClose()
    @ObservedObject private var navigation: WorkspaceSettingsNavigation
    private let model: ClaudeSetupModel
    private let usesReviewFixtures: Bool
    private let textRepliesEnabled: Bool

    public init(navigation: WorkspaceSettingsNavigation, model: ClaudeSetupModel, usesReviewFixtures: Bool = false, textRepliesEnabled: Bool = false) {
        self.navigation = navigation
        self.model = model
        self.usesReviewFixtures = usesReviewFixtures
        self.textRepliesEnabled = textRepliesEnabled
    }

    private var selectedSection: WorkspaceSettingsSection { navigation.selection ?? .general }

    public var body: some View {
        HStack(spacing: 0) {
            List(WorkspaceSettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .padding(.vertical, 6)
                    .tag(section)
                    .accessibilityIdentifier("settings.section.\(section.id)")
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 190)
            .background(OpenBotsVisualStyle.surface(for: colorScheme))
            .accessibilityLabel("Settings sections")
            .accessibilityIdentifier("settings.sections")

            Divider()

            Group {
                if selectedSection == .computer {
                    computerSettings
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
                            Text(selectedSection.rawValue)
                                .font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            switch selectedSection {
                            case .general: generalSettings
                            case .usage: usageSettings
                            case .updates: updateSettings
                            case .computer: EmptyView()
                            }
                        }
                        .padding(OpenBotsVisualStyle.spacing32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenBotsVisualStyle.canvas(for: colorScheme))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(selectedSection.rawValue)
            .accessibilityIdentifier("settings.content.\(selectedSection.id)")
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 620, idealHeight: 700)
        .preferredColorScheme(.dark)
        .tint(OpenBotsVisualStyle.brandAccent(for: colorScheme))
        .overlay(alignment: .topTrailing) {
            Button(action: closeTarget.close) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!closeTarget.isAttached)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Settings")
            .accessibilityIdentifier("settings.close")
            .help("Close Settings")
            .padding(8)
        }
        .background {
            UtilitySettingsWindowAttachment(closeTarget: closeTarget)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenBots settings")
        .accessibilityIdentifier("settings.global")
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
            settingsCard("OpenBots Next Preview") {
                Text("A local development build. Conversations, drafts and protected attachment copies stay on this Mac.")
                Text("Live agent work is unavailable. Saved messages aren't queued to send when a connection becomes available.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            }
            settingsCard("Appearance") {
                LabeledContent("Workspace", value: "Dark")
                Text("This build uses the dark workspace. Appearance preferences aren't available yet.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            }
            settingsCard("Account") {
                Text("No OpenBots account service is connected. There is no account to sign in to or log out of here.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                Button("Sign In") {}
                    .disabled(true)
                    .accessibilityIdentifier("settings.account.signIn")
                    .help("OpenBots account sign-in is unavailable in this build")
            }
            if usesReviewFixtures {
                settingsCard("Development review mode") {
                    Label("Local simulations are enabled", systemImage: "hammer")
                    Text("Sample replies and controls don't run Claude or grant real access.")
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                }
            }
        }
    }

    private var computerSettings: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                Text("Computer")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Computer control isn't available. Connection checks below do not grant execution or system permissions.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connections")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, OpenBotsVisualStyle.spacing32)
            .padding(.top, OpenBotsVisualStyle.spacing24)

            // Keep the guarded setup surface intact. Selecting this section
            // performs no check; the existing explicit actions own admission.
            ClaudeSetupView(model: model, usesReviewFixtures: usesReviewFixtures, textRepliesEnabled: textRepliesEnabled)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var usageSettings: some View {
        settingsCard("Usage & Billing") {
            Text("Usage reporting and billing aren't available in OpenBots Next Preview.")
            Text("No balance, subscription tier or account usage is inferred. Claude subscription verification remains a separate guarded connection step under Computer.")
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            Button("Manage Billing") {}
                .disabled(true)
                .accessibilityIdentifier("settings.billing.manage")
                .help("No OpenBots billing service is connected")
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
            settingsCard("Application updates") {
                Text("Automatic updates and update checks aren't connected in this development build.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                Button("Check for Updates") {}
                    .disabled(true)
                    .accessibilityIdentifier("settings.updates.check")
                    .help("No application update service is connected")
            }
            settingsCard("Computer") {
                Text("There is no remote computer update or reset service. OpenBots does not change your Mac or erase local records from this screen.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            }
        }
    }

    private func settingsCard<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OpenBotsVisualStyle.spacing16)
        .background(OpenBotsVisualStyle.surface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusMedium))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
