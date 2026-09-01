import Foundation

/// Metadata only. None of these observations establish subscription access.
public enum ClaudeInstallationFinding: Equatable, Sendable {
    case notChecked
    case missing
    case verified
    case rejected
    case unavailable
}

public enum ClaudeProfileFinding: Equatable, Sendable {
    case notChecked
    case missing
    case metadataVerified
    case rejected
    case unavailable
}

public struct ClaudeSetupDetail: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ClaudeOfflineSetupSnapshot: Equatable, Sendable {
    public let installation: ClaudeInstallationFinding
    public let profile: ClaudeProfileFinding
    public let details: [ClaudeSetupDetail]

    public init(
        installation: ClaudeInstallationFinding,
        profile: ClaudeProfileFinding,
        details: [ClaudeSetupDetail] = []
    ) {
        self.installation = installation
        self.profile = profile
        self.details = details
    }
}

public protocol ClaudeOfflineSetupInspecting: Sendable {
    func inspectOffline() async -> ClaudeOfflineSetupSnapshot
}

/// A checked auth classification, not a runtime/tool capability. A caller must
/// supply the official status command's exit and decoded, minimized fields.
/// Rejected, malformed and nonzero results cannot construct a verified value.
public struct ClaudeVerifiedSubscription: Equatable, Sendable {
    public enum Tier: String, Sendable { case pro, max }
    public let tier: Tier
    public let checkedAt: Date

    public init?(
        exitCode: Int32, loggedIn: Bool, authMethod: String,
        apiProvider: String?, subscriptionType: String?, checkedAt: Date
    ) {
        guard exitCode == 0, loggedIn,
              authMethod.lowercased() == "claude.ai",
              apiProvider?.lowercased() == "firstparty",
              let tier = Tier(rawValue: subscriptionType?.lowercased() ?? "")
        else { return nil }
        self.tier = tier
        self.checkedAt = checkedAt
    }
}

public enum ClaudeSetupRequirement: Equatable, Sendable {
    case correctedStatusCheckApproval
    case tracedOfficialSignIn
}

public enum ClaudeSetupProblem: Equatable, Sendable {
    case installationMissing
    case installationRejected
    case installationUnavailable
    case profileMissing
    case profileRejected
    case profileUnavailable
    case connectionCheckInconclusive
    case signInIncomplete
}

public enum ClaudeSetupOutcome: Equatable, Sendable {
    /// Local checks passed; no account status or sign-in was attempted.
    case readyToConnect
    case actionRequired(ClaudeSetupRequirement)
    case needsSignIn
    case signedInNeedsVerification
    /// Terminal accepted the handoff. No login completion was observed.
    case handedOffNeedsVerification
    case verified(ClaudeVerifiedSubscription)
    case problem(ClaudeSetupProblem)
    case cancelled
}

public struct ClaudeSetupReport: Equatable, Sendable {
    public let local: ClaudeOfflineSetupSnapshot?
    public let outcome: ClaudeSetupOutcome

    public init(local: ClaudeOfflineSetupSnapshot? = nil, outcome: ClaudeSetupOutcome) {
        self.local = local
        self.outcome = outcome
    }
}

/// Deliberately has no conversation, prompt, attachment, database, credential
/// or executor input. An explicit action is required for every setup step.
public protocol ClaudeSetupServicing: Sendable {
    func checkThisMac() async -> ClaudeSetupReport
    func checkSubscription() async -> ClaudeSetupReport
    func beginOfficialSignIn() async -> ClaudeSetupReport
}

/// Receives only an app-generated, private command file. The opener must use
/// Terminal rather than implementing OAuth or inspecting the login transcript.
public protocol ClaudeOfficialSignInOpening: Sendable {
    func openOfficialSignIn(commandFile: URL) async -> Bool
}

/// The current production admission boundary. The consumed status exception
/// is not a reusable user preference. No credential-affecting transport is
/// injected here, so a view/model cannot turn offline success into a launch.
public struct GuardedClaudeSetupService: ClaudeSetupServicing {
    private let inspector: any ClaudeOfflineSetupInspecting

    public init(inspector: any ClaudeOfflineSetupInspecting) {
        self.inspector = inspector
    }

    public func checkThisMac() async -> ClaudeSetupReport {
        guard !Task.isCancelled else { return .init(outcome: .cancelled) }
        let local = await inspector.inspectOffline()
        guard !Task.isCancelled else { return .init(outcome: .cancelled) }
        let outcome: ClaudeSetupOutcome
        switch local.installation {
        case .missing: outcome = .problem(.installationMissing)
        case .rejected: outcome = .problem(.installationRejected)
        case .notChecked, .unavailable: outcome = .problem(.installationUnavailable)
        case .verified:
            switch local.profile {
            case .missing: outcome = .problem(.profileMissing)
            case .rejected: outcome = .problem(.profileRejected)
            case .notChecked, .unavailable: outcome = .problem(.profileUnavailable)
            case .metadataVerified:
                outcome = .actionRequired(.correctedStatusCheckApproval)
            }
        }
        return .init(local: local, outcome: outcome)
    }

    public func checkSubscription() async -> ClaudeSetupReport {
        .init(outcome: Task.isCancelled ? .cancelled : .actionRequired(.correctedStatusCheckApproval))
    }

    public func beginOfficialSignIn() async -> ClaudeSetupReport {
        .init(outcome: Task.isCancelled ? .cancelled : .actionRequired(.tracedOfficialSignIn))
    }
}
