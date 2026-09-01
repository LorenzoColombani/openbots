import Foundation
import OpenBotsContent
import OpenBotsRuntime
import OpenBotsSecurity

/// Fresh nonsecret checks for one operation. This never starts Claude and never
/// creates/repairs a missing profile or interprets display strings as authority.
public struct NativeClaudeConnectionPreparer: ClaudeConnectionPreparing {
    private let layout: PreviewStorageLayout
    private let installationInspector: any ClaudeInstallationInspecting
    private let applicationSupportRoot: @Sendable () async -> VerifiedOwnedRoot?

    public init(
        layout: PreviewStorageLayout,
        installationInspector: (any ClaudeInstallationInspecting)? = nil,
        applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?
    ) {
        self.layout = layout
        self.installationInspector = installationInspector
            ?? ClaudeInstallationInspector(homeDirectory: layout.homeDirectory)
        self.applicationSupportRoot = applicationSupportRoot
    }

    public func prepareConnection() async -> ClaudeConnectionPreparation {
        guard !Task.isCancelled else { return .refused(.init(outcome: .cancelled)) }
        let installation = await installationInspector.inspectInstallation()
        guard !Task.isCancelled else { return .refused(.init(outcome: .cancelled)) }
        switch installation.state {
        case .missing: return refused(.installationMissing)
        case .rejected: return refused(.installationRejected)
        case .unavailable: return refused(.installationUnavailable)
        case .verified: break
        }
        guard let resolved = installation.details.resolvedPath,
              let sha256 = installation.details.sha256,
              installation.details.signature?.identifier == ClaudeInstallationInspector.expectedIdentifier,
              installation.details.signature?.teamIdentifier == ClaudeInstallationInspector.expectedTeamIdentifier,
              installation.details.fileIdentity != nil else {
            return refused(.installationRejected)
        }
        guard let root = await applicationSupportRoot(), !Task.isCancelled else {
            return Task.isCancelled ? .refused(.init(outcome: .cancelled)) : refused(.profileUnavailable)
        }
        let layout = layout
        let profile = await Task.detached(priority: .userInitiated) {
            ClaudeProfileInspector().inspect(applicationSupportRoot: root, layout: layout)
        }.value
        guard !Task.isCancelled else { return .refused(.init(outcome: .cancelled)) }
        switch profile {
        case .missing: return refused(.profileMissing)
        case .rejected: return refused(.profileRejected)
        case .unavailable: return refused(.profileUnavailable)
        case .metadataVerified: break
        }
        do {
            // Authentication owns this exact profile, not any teammate's cwd.
            // Using the checked profile for its temporary files avoids selecting
            // another unverified path. Complete write isolation is a separate gate.
            let target = try ClaudeConnectionTarget(
                executableURL: URL(fileURLWithPath: resolved),
                expectedExecutableSHA256: sha256,
                profileURL: layout.claudeCLIProfileRoot,
                workingDirectoryURL: layout.claudeCLIProfileRoot,
                temporaryDirectoryURL: layout.claudeCLIProfileRoot,
                homeDirectoryURL: layout.homeDirectory
            )
            return .ready(local: .init(installation: .verified, profile: .metadataVerified), target: target)
        } catch { return refused(.installationRejected) }
    }

    private func refused(_ problem: ClaudeSetupProblem) -> ClaudeConnectionPreparation {
        .refused(.init(outcome: .problem(problem)))
    }
}

/// Prepares nonsecret command material only after admission. The official CLI,
/// Terminal and browser own all login interaction; no output is captured here.
public struct NativeClaudeConnectionSignInHandoff: ClaudeConnectionSignInHandingOff {
    private let layout: PreviewStorageLayout
    private let applicationSupportRoot: @Sendable () async -> VerifiedOwnedRoot?
    private let opener: any ClaudeOfficialSignInOpening

    public init(
        layout: PreviewStorageLayout,
        applicationSupportRoot: @escaping @Sendable () async -> VerifiedOwnedRoot?,
        opener: any ClaudeOfficialSignInOpening
    ) {
        self.layout = layout
        self.applicationSupportRoot = applicationSupportRoot
        self.opener = opener
    }

    public func handOffOfficialSignIn(target: ClaudeConnectionTarget) async -> Bool {
        guard !Task.isCancelled,
              target.profileURL == layout.claudeCLIProfileRoot,
              target.workingDirectoryURL == layout.claudeCLIProfileRoot,
              target.temporaryDirectoryURL == layout.claudeCLIProfileRoot,
              target.homeDirectoryURL == layout.homeDirectory,
              let root = await applicationSupportRoot(), !Task.isCancelled else { return false }
        guard ClaudeProfileInspector().inspect(applicationSupportRoot: root, layout: layout) == .metadataVerified
        else { return false }
        do {
            let script = ClaudeConnectionCommandBuilder.officialLoginScript(for: target)
            let commandFile = try ClaudeSignInCommandFileStore().create(
                script: script, applicationSupportRoot: root, layout: layout
            )
            guard !Task.isCancelled else { return false }
            return await opener.openOfficialSignIn(commandFile: commandFile)
        } catch { return false }
    }
}
