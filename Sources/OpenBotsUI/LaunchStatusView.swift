import OpenBotsServices
import SwiftUI

/// One verified local backup the recovery screen can offer. The app derives it
/// from the backup catalog; the screen never inspects files itself.
public struct LaunchRecoveryRestoreOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

/// Native inline startup status for the executor-independent preview. It does
/// not create storage, open the database, request credentials, or start Claude.
public struct LaunchStatusView: View {
    @ObservedObject private var model: LaunchReadinessModel

    private let continueAction: @MainActor () -> Void
    private let performsAutomaticRefresh: Bool
    private let isApplicationStartup: Bool
    private let retryAction: (@MainActor () -> Void)?
    private let restoreOptions: [LaunchRecoveryRestoreOption]
    private let restoreAction: (@MainActor (LaunchRecoveryRestoreOption) -> Void)?
    @State private var pendingRestore: LaunchRecoveryRestoreOption?

    public init(
        model: LaunchReadinessModel,
        performsAutomaticRefresh: Bool = true,
        isApplicationStartup: Bool = false,
        retryAction: (@MainActor () -> Void)? = nil,
        restoreOptions: [LaunchRecoveryRestoreOption] = [],
        restoreAction: (@MainActor (LaunchRecoveryRestoreOption) -> Void)? = nil,
        continueAction: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.performsAutomaticRefresh = performsAutomaticRefresh
        self.isApplicationStartup = isApplicationStartup
        self.retryAction = retryAction
        self.restoreOptions = restoreOptions
        self.restoreAction = restoreAction
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
                Text("Your bots and saved conversations stay on this Mac. Claude setup is separate from opening your workspace.")
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
                    ? "Opening your saved bots and conversations. A new installation creates only OpenBots' own local folders."
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
            if issue.offersRestore, let restoreAction, !restoreOptions.isEmpty {
                restoreSection(restoreAction)
            }
        }
    }

    /// Verified local backups, newest first. Restoring is a two-step, exact-scope
    /// action: the current database files are moved aside, never deleted. The
    /// screen says so without naming the files.
    private func restoreSection(_ restoreAction: @escaping @MainActor (LaunchRecoveryRestoreOption) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore a local backup")
                .font(.subheadline.weight(.semibold))
            StableSelectableText(Self.restoreExplanation, style: .caption, tone: .secondary)
            ForEach(restoreOptions) { option in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title).font(.callout)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Restore…") { pendingRestore = option }
                        .accessibilityLabel("Restore \(option.title)")
                        .accessibilityHint("Asks first, then puts this copy in place of your current data.")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { option in
            Button("Restore \(option.title)") { pendingRestore = nil; restoreAction(option) }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { option in
            Text(Self.restoreConfirmation(for: option))
        }
    }

    /// What restoring does, in plain words: no file names.
    static let restoreExplanation = "OpenBots kept these copies of your workspace on this Mac. "
        + "Restoring one sets your current data aside, without deleting it, and puts the copy in its place."

    /// The confirmation, naming the copy by its date. The app titles each copy
    /// "Backup from <date>"; any other title is used whole.
    static func restoreConfirmation(for option: LaunchRecoveryRestoreOption) -> String {
        let prefix = "Backup from "
        let copy = option.title.hasPrefix(prefix)
            ? "the copy from \(option.title.dropFirst(prefix.count))" : option.title
        return "Your current data is set aside, not deleted, and \(copy) takes its place. "
            + "The damaged copy is kept in a folder of its own, next to your other backups. "
            + "OpenBots then tries to open your workspace again."
    }

    private func statusLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(title)")
    }
}

private extension LaunchRecoveryIssue {
    /// Only a database that will not open or fails its checks is a restore case; a
    /// workspace newer than this build must not be rolled back to an older copy.
    var offersRestore: Bool {
        switch self {
        case .databaseOpenFailed, .databaseValidationFailed: true
        case .installationReceiptUnavailable, .ownedRootVerificationFailed,
             .databaseProtectionUnavailable, .workspaceNewerThanApplication: false
        }
    }

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
        case .workspaceNewerThanApplication:
            "Your saved workspace was last opened by a newer OpenBots Next. Open the newer copy from Applications; this older copy left everything as it was."
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
        case .workspaceNewerThanApplication:
            "This copy of OpenBots Next is older than your workspace"
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
        case .workspaceNewerThanApplication:
            "The control database's schema ledger names a version newer than this build's manifest. OpenBots did not migrate, repair, or replace it; the newer build opens it."
        }
    }
}
