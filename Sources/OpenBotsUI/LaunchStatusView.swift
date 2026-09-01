import OpenBotsServices
import SwiftUI

/// Native inline startup status for the executor-independent preview. It does
/// not create storage, open the database, request credentials, or start Claude.
public struct LaunchStatusView: View {
    @ObservedObject private var model: LaunchReadinessModel

    private let continueAction: @MainActor () -> Void
    private let performsAutomaticRefresh: Bool
    private let isApplicationStartup: Bool
    private let retryAction: (@MainActor () -> Void)?

    public init(
        model: LaunchReadinessModel,
        performsAutomaticRefresh: Bool = true,
        isApplicationStartup: Bool = false,
        retryAction: (@MainActor () -> Void)? = nil,
        continueAction: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.performsAutomaticRefresh = performsAutomaticRefresh
        self.isApplicationStartup = isApplicationStartup
        self.retryAction = retryAction
        self.continueAction = continueAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Label("OpenBots", systemImage: "person.2.fill")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(isApplicationStartup ? "Your local workspace" : "Local preview readiness")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            statusCard

            if isApplicationStartup {
                Text("Your teammates and saved conversations stay on this Mac. Claude setup is separate from opening your workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            Label {
                StableSelectableText(
                    "Claude login, the Claude Code runtime, and Keychain access are disabled in this preview and were not requested by this check.",
                    style: .callout,
                    tone: .secondary
                )
            } icon: {
                Image(systemName: "lock.shield")
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "Safety boundary. Claude login, the Claude Code runtime, and Keychain access are disabled in this preview and were not requested by this check."
            )
            }
        }
        .padding(32)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: 680, alignment: .leading)
        .task {
            guard performsAutomaticRefresh, model.state == .notConfigured else { return }
            await model.refresh()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.state {
            case .notConfigured:
                notConfiguredContent
            case .opening:
                openingContent
            case .ready:
                readyContent
            case let .recovery(issue):
                recoveryContent(issue)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var notConfiguredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLabel("Not configured", systemImage: "circle.dashed")
            StableSelectableText(
                isApplicationStartup
                    ? "OpenBots is preparing your local workspace. Existing records will be preserved."
                    : "This preview has no verified OpenBots installation yet. The readiness check did not create folders, open a database, or change existing files.",
                tone: .secondary
            )
        }
    }

    private var openingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLabel("Checking local state", systemImage: "magnifyingglass.circle")
            StableSelectableText(
                isApplicationStartup
                    ? "Opening your saved teammates and conversations. A new installation creates only OpenBots' own local folders."
                    : "OpenBots is checking the fixed local installation receipt, protected roots, and database readiness. It is not repairing, deleting, or creating anything.",
                tone: .secondary
            )
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusLabel("Local storage is ready", systemImage: "checkmark.circle")
            StableSelectableText(
                "The existing preview installation passed its local checks. Agent execution and Claude authentication remain disabled until their separate approved setup.",
                tone: .secondary
            )
            Button("Continue", action: continueAction)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Continue to the OpenBots preview without starting Claude or requesting credentials.")
        }
    }

    private func recoveryContent(_ issue: LaunchRecoveryIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statusLabel(issue.title, systemImage: "exclamationmark.triangle")
            StableSelectableText(isApplicationStartup ? issue.applicationGuidance : issue.guidance, tone: .secondary)
            Button {
                if let retryAction {
                    retryAction()
                } else {
                    Task { await model.refresh() }
                }
            } label: {
                Label(isApplicationStartup ? "Try Opening Again" : "Retry Check", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityHint(
                isApplicationStartup
                    ? "Try opening the local workspace again. Existing data is not reset or removed."
                    : "Repeat the read-only readiness check. This does not repair or remove files."
            )
        }
    }

    private func statusLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(title)")
    }
}

private extension LaunchRecoveryIssue {
    var applicationGuidance: String {
        switch self {
        case .installationReceiptUnavailable:
            "OpenBots couldn't verify the saved workspace location. Existing records have not been reset."
        case .ownedRootVerificationFailed:
            "OpenBots couldn't safely open its local folders. Your existing files have not been removed or replaced."
        case .databaseProtectionUnavailable:
            "The saved workspace's protection settings could not be used. OpenBots has not weakened them or requested a database key."
        case .databaseOpenFailed:
            "Your saved conversations couldn't be opened. The existing files have been left in place."
        case .databaseValidationFailed:
            "Your saved workspace needs attention before it can open. OpenBots has not reset or replaced it."
        }
    }

    var title: String {
        switch self {
        case .installationReceiptUnavailable:
            "Installation receipt unavailable"
        case .ownedRootVerificationFailed:
            "Protected storage needs review"
        case .databaseProtectionUnavailable:
            "Database protection unavailable"
        case .databaseOpenFailed:
            "Database could not be opened"
        case .databaseValidationFailed:
            "Database check failed"
        }
    }

    var guidance: String {
        switch self {
        case .installationReceiptUnavailable:
            "OpenBots could not verify its fixed local installation receipt. No repair, reset, or root creation was attempted."
        case .ownedRootVerificationFailed:
            "One of the three app-owned internal roots no longer matches its ownership marker. Nothing was removed or replaced."
        case .databaseProtectionUnavailable:
            "The recorded database protection mode is unavailable. OpenBots did not downgrade it or request a Keychain key."
        case .databaseOpenFailed:
            "The existing control database could not be opened. Its files and app-owned roots were left in place."
        case .databaseValidationFailed:
            "The control database did not pass the startup checks. OpenBots did not repair, replace, or delete it."
        }
    }
}
