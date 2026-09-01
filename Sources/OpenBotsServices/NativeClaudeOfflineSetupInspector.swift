import Foundation
import OpenBotsContent
import OpenBotsSecurity

/// Joins two read-only observations. Storage ownership comes from the existing
/// app composition; this service never bootstraps or repairs a missing profile.
public struct NativeClaudeOfflineSetupInspector: ClaudeOfflineSetupInspecting {
    private let layout: PreviewStorageLayout
    private let installationInspector: any ClaudeInstallationInspecting
    private let applicationSupportRoot: @Sendable () async -> VerifiedOwnedRoot?

    public init(
        layout: PreviewStorageLayout,
        applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?
    ) {
        self.init(
            layout: layout,
            installationInspector: ClaudeInstallationInspector(homeDirectory: layout.homeDirectory),
            applicationSupportRoot: applicationSupportRoot
        )
    }

    public init(
        layout: PreviewStorageLayout,
        installationInspector: any ClaudeInstallationInspecting,
        applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?
    ) {
        self.layout = layout
        self.installationInspector = installationInspector
        self.applicationSupportRoot = applicationSupportRoot
    }

    public func inspectOffline() async -> ClaudeOfflineSetupSnapshot {
        guard !Task.isCancelled else { return .init(installation: .unavailable, profile: .notChecked) }
        let installation = await installationInspector.inspectInstallation()
        guard !Task.isCancelled else { return .init(installation: .unavailable, profile: .notChecked) }
        var details = installationDetails(installation)
        let finding: ClaudeInstallationFinding
        switch installation.state {
        case .missing: finding = .missing
        case .verified: finding = .verified
        case .rejected: finding = .rejected
        case .unavailable: finding = .unavailable
        }
        // A rejected/missing executable does not broaden inspection into the
        // profile or imply that a user should authenticate another installation.
        guard finding == .verified else {
            return .init(installation: finding, profile: .notChecked, details: details)
        }
        guard let root = await applicationSupportRoot(), !Task.isCancelled else {
            details.append(.init(label: "Profile check", value: "Verified app storage is not available."))
            return .init(installation: finding, profile: .unavailable, details: details)
        }
        let layout = self.layout
        let profile = await Task.detached(priority: .userInitiated) {
            ClaudeProfileInspector().inspect(applicationSupportRoot: root, layout: layout)
        }.value
        guard !Task.isCancelled else { return .init(installation: finding, profile: .notChecked, details: details) }
        let profileFinding: ClaudeProfileFinding
        switch profile {
        case .missing: profileFinding = .missing
        case .metadataVerified: profileFinding = .metadataVerified
        case .rejected(let issue):
            profileFinding = .rejected
            details.append(.init(label: "Profile check", value: issue.rawValue))
        case .unavailable: profileFinding = .unavailable
        }
        details.append(.init(label: "Preview profile", value: layout.claudeCLIProfileRoot.path))
        details.append(.init(label: "Subscription", value: "Not checked; the prior status result was inconclusive."))
        details.append(.init(label: "Allowed next command", value: "One separately approved auth status check; no help, retry, login or model request."))
        return .init(installation: finding, profile: profileFinding, details: details)
    }

    private func installationDetails(_ result: ClaudeInstallationInspection) -> [ClaudeSetupDetail] {
        let value = result.details
        var rows = [ClaudeSetupDetail(label: "CLI launcher", value: value.requestedPath)]
        if let path = value.resolvedPath { rows.append(.init(label: "Resolved target", value: path)) }
        if let version = value.versionFilename {
            rows.append(.init(label: "Installed filename", value: "\(version) — Claude was not run to check its version."))
        }
        if let sha = value.sha256 { rows.append(.init(label: "SHA-256", value: sha)) }
        if let signature = value.signature {
            rows.append(.init(label: "Signing identity", value: "\(signature.identifier) / \(signature.teamIdentifier)"))
            rows.append(.init(label: "Signature scope", value: "Local static signature check; no online revocation or notarization check."))
        }
        switch result.state {
        case .rejected(let issue): rows.append(.init(label: "Installation check", value: issue.rawValue))
        case .unavailable(let reason): rows.append(.init(label: "Installation check", value: String(describing: reason)))
        case .missing, .verified: break
        }
        return rows
    }
}
