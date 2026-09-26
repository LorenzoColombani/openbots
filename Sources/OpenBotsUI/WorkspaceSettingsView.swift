import Combine
import OpenBotsServices
import SwiftUI

/// Selecting a section never starts connection checks or changes permissions.
public enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
    case general = "General & Claude Code"
    case connectors = "Connectors & Skills"
    case permissions = "Permissions & Bot Access"
    case appearance = "Appearance & Accessibility"
    case notifications = "Notifications"
    case storage = "Storage, Backup & Export"
    case diagnostics = "Diagnostics & Updates"

    public var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connectors: "puzzlepiece.extension"
        case .permissions: "hand.raised"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell"
        case .storage: "externaldrive"
        case .diagnostics: "stethoscope"
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

public struct WorkspaceSettingsExportBot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
public struct WorkspaceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var closeTarget = UtilityOwningWindowClose()
    @StateObject private var jobAccess: AgenticJobAccessModel
    @ObservedObject private var navigation: WorkspaceSettingsNavigation
    @ObservedObject private var appearance: WorkspaceAppearanceModel
    @State private var exportBotID: UUID?
    private let model: ClaudeSetupModel
    private let usesReviewFixtures: Bool
    private let textRepliesEnabled: Bool
    private let exportBots: [WorkspaceSettingsExportBot]
    private let isExporting: Bool
    private let exportNotice: String?
    private let onExport: (@MainActor (UUID) -> Void)?
    private let backupSummary: String?
    private let connectorsContent: AnyView?
    private let notificationsContent: AnyView?

    public init(
        navigation: WorkspaceSettingsNavigation, model: ClaudeSetupModel,
        usesReviewFixtures: Bool = false, textRepliesEnabled: Bool = false,
        agenticJobAccess: AgenticJobAccessStore? = nil,
        appearance: WorkspaceAppearanceModel = WorkspaceAppearanceModel(),
        exportBots: [WorkspaceSettingsExportBot] = [], isExporting: Bool = false, exportNotice: String? = nil,
        onExport: (@MainActor (UUID) -> Void)? = nil, backupSummary: String? = nil,
        connectorsContent: AnyView? = nil, notificationsContent: AnyView? = nil
    ) {
        self.navigation = navigation
        self.model = model
        self.usesReviewFixtures = usesReviewFixtures
        self.textRepliesEnabled = textRepliesEnabled
        self.appearance = appearance
        self.exportBots = exportBots
        self.isExporting = isExporting
        self.exportNotice = exportNotice
        self.onExport = onExport
        self.backupSummary = backupSummary
        self.connectorsContent = connectorsContent
        self.notificationsContent = notificationsContent
        _jobAccess = StateObject(wrappedValue: AgenticJobAccessModel(store: agenticJobAccess))
    }

    private var selectedSection: WorkspaceSettingsSection { navigation.selection ?? .general }

    public var body: some View {
        HStack(spacing: 0) {
            List(WorkspaceSettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .lineLimit(2)
                    .padding(.vertical, 6)
                    .tag(section)
                    .accessibilityIdentifier("settings.section.\(section.id)")
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 246)
            .background(OpenBotsVisualStyle.surface(for: colorScheme))
            .accessibilityLabel("Settings sections")
            .accessibilityIdentifier("settings.sections")

            Divider()

            Group {
                if selectedSection == .general {
                    generalSettings
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
                            sectionHeading
                            switch selectedSection {
                            case .general: EmptyView()
                            case .connectors: connectorsContent
                            case .permissions: permissionSettings
                            case .appearance: appearanceSettings
                            case .notifications: notificationsContent
                            case .storage: storageSettings
                            case .diagnostics: diagnosticsSettings
                            }
                        }
                        .padding(OpenBotsVisualStyle.spacing32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 510, maxWidth: .infinity, maxHeight: .infinity)
            .background(OpenBotsVisualStyle.canvas(for: colorScheme))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(selectedSection.rawValue)
            .accessibilityIdentifier("settings.content.\(selectedSection.id)")
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 620, idealHeight: 700)
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
        .onChange(of: exportBots.map(\.id)) { _, ids in
            if let exportBotID, !ids.contains(exportBotID) { self.exportBotID = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenBots settings")
        .accessibilityIdentifier("settings.global")
    }

    private var sectionHeading: some View {
        Text(selectedSection.rawValue)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                sectionHeading
                Text("Connection checks do not grant access. Manage bot permissions under Permissions & Bot Access.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if usesReviewFixtures {
                    Label("Local simulations are enabled", systemImage: "hammer")
                }
            }
            .padding(.horizontal, OpenBotsVisualStyle.spacing32)
            .padding(.top, OpenBotsVisualStyle.spacing32)

            // Preserve the explicit guarded actions. Opening Settings is inert.
            ClaudeSetupView(model: model, usesReviewFixtures: usesReviewFixtures,
                            textRepliesEnabled: textRepliesEnabled)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var permissionSettings: some View {
        if jobAccess.isAvailable {
            settingsCard("App-wide access") {
                ForEach(AgenticWebCapability.allCases, id: \.self) { capability in
                    Toggle("Allow \(capability.displayName.lowercased())", isOn: Binding(
                        get: { jobAccess.webAppEnabled(capability) },
                        set: { enabled in Task { await jobAccess.setWebAppEnabled(enabled, capability: capability) } }))
                    .disabled(!jobAccess.isReady || jobAccess.isUpdating)
                    .accessibilityIdentifier("agentic.app.\(capability.settingKey)")
                }
                permissionCaption(AgenticWebCopy.settingsCaption)
                Toggle("Allow bots to work on this Mac", isOn: Binding(
                    get: { jobAccess.workAppEnabled },
                    set: { enabled in Task { await jobAccess.setWorkAppEnabled(enabled) } }))
                .disabled(!jobAccess.isReady || jobAccess.isUpdating)
                .accessibilityIdentifier("agentic.app.work")
                permissionCaption(AgenticWebCopy.settingsWorkCaption)
                Toggle("Allow bots to hire new bots", isOn: Binding(
                    get: { jobAccess.hireAppEnabled },
                    set: { enabled in Task { await jobAccess.setHireAppEnabled(enabled) } }))
                .disabled(!jobAccess.isReady || jobAccess.isUpdating)
                .accessibilityIdentifier("agentic.app.hire")
                permissionCaption(AgenticWebCopy.settingsHireCaption)
                if AgenticWorkerAvailability.runsInThisBuild { workerSettings }
            }
        }
    }

    /// The two worker masters, shown since a worker runs
    /// (`AgenticWorkerAvailability`).
    @ViewBuilder
    private var workerSettings: some View {
        Toggle("Allow background workers", isOn: Binding(
            get: { jobAccess.workersAppEnabled },
            set: { enabled in Task { await jobAccess.setWorkersAppEnabled(enabled) } }))
        .disabled(!jobAccess.isReady || jobAccess.isUpdating)
        .accessibilityIdentifier("agentic.app.workers")
        permissionCaption(AgenticWebCopy.settingsWorkersCaption)
        Toggle("Allow fetcher workers", isOn: Binding(
            get: { jobAccess.fetchersAppEnabled },
            set: { enabled in Task { await jobAccess.setFetchersAppEnabled(enabled) } }))
        .disabled(!jobAccess.isReady || jobAccess.isUpdating)
        .accessibilityIdentifier("agentic.app.fetchers")
        permissionCaption(AgenticWebCopy.settingsFetchersCaption)
    }

    private var appearanceSettings: some View {
        settingsCard("Appearance") {
            Picker("Color scheme", selection: $appearance.selection) {
                ForEach(WorkspaceAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
            Text("Applies to all OpenBots Next windows. Follow System uses your Mac’s current appearance.")
                .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
        }
    }

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
            settingsCard("On this Mac") {
                Text("Conversations, drafts and protected attachment copies stay on this Mac.")
                if let backupSummary {
                    Text(backupSummary)
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                }
            }
            if let onExport {
                settingsCard("Export Conversations") {
                    if exportBots.isEmpty {
                        Text("Create a bot to export its conversations.")
                    } else {
                        Picker("Bot", selection: $exportBotID) {
                            Text("Choose a bot").tag(UUID?.none)
                            ForEach(exportBots) { bot in
                                Text(bot.name).tag(Optional(bot.id))
                            }
                        }
                        .accessibilityIdentifier("settings.export.bot")
                        Text("Saves this bot’s conversations as Markdown and JSON in a new folder you choose.")
                            .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                        Button(isExporting ? "Exporting…" : "Export Conversations…") {
                            guard let exportBotID, exportBots.contains(where: { $0.id == exportBotID }) else { return }
                            onExport(exportBotID)
                        }
                        .disabled(isExporting || !exportBots.contains(where: { $0.id == exportBotID }))
                        .accessibilityIdentifier("settings.export")
                    }
                    if let exportNotice {
                        Text(exportNotice)
                            .accessibilityAddTraits(.updatesFrequently)
                            .accessibilityIdentifier("settings.export.notice")
                    }
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        settingsCard("OpenBots Next") {
            ForEach(DiagnosticsFacts.rows(info: Bundle.main.infoDictionary ?? [:]), id: \.label) { row in
                LabeledContent(row.label, value: row.value)
            }
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
        }
    }

    private func permissionCaption(_ text: String) -> some View {
        Text(text).font(.caption)
            .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
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

/// What Diagnostics says about this build, from the bundle's own Info.plist.
/// `Scripts/build-preview.sh` stamps the source commit and uses the commit's date
/// as the build number; before that every build read the same build number
/// and nothing on screen said which one was installed. A bundle built
/// another way carries no commit, and shows no Source row rather than an empty one.
struct DiagnosticsFacts {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    static func rows(info: [String: Any]) -> [Row] {
        [("Version", "CFBundleShortVersionString"), ("Build", "CFBundleVersion"), ("Source", "OpenBotsSourceCommit")]
            .compactMap { label, key in
                guard let value = (info[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty
                else { return nil }
                return Row(label: label, value: value)
            }
    }
}
