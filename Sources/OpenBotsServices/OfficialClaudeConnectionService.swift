import Foundation
import OpenBotsRuntime

public enum ClaudeConnectionOperation: Equatable, Sendable {
    case status
    case officialSignIn
}

public enum ClaudeConnectionPreparation: Sendable {
    case ready(local: ClaudeOfflineSetupSnapshot, target: ClaudeConnectionTarget)
    case refused(ClaudeSetupReport)
}

public protocol ClaudeConnectionPreparing: Sendable {
    func prepareConnection() async -> ClaudeConnectionPreparation
}

/// Deliberately separate from UI intent and subscription state. Implementations
/// must establish the operation-specific live prerequisite, not a stored toggle.
public protocol ClaudeConnectionAdmitting: Sendable {
    func unmetRequirement(
        for operation: ClaudeConnectionOperation, target: ClaudeConnectionTarget
    ) async -> ClaudeSetupRequirement?
}

/// Safe default for callers that have not selected an authorized live policy.
/// Preview composition explicitly selects the user-initiated policy below.
public struct PendingClaudeConnectionAdmission: ClaudeConnectionAdmitting {
    public init() {}
    public func unmetRequirement(
        for operation: ClaudeConnectionOperation, target: ClaudeConnectionTarget
    ) async -> ClaudeSetupRequirement? {
        operation == .status ? .correctedStatusCheckApproval : .tracedOfficialSignIn
    }
}

/// Lorenzo explicitly authorized these two user-initiated setup operations.
/// App composition selects this policy; construction and local checks remain
/// inert, and every operation still requires fresh installation/profile checks.
/// This grants no model, tool, connector or general command authority.
public struct UserInitiatedClaudeConnectionAdmission: ClaudeConnectionAdmitting {
    public init() {}
    public func unmetRequirement(
        for operation: ClaudeConnectionOperation, target: ClaudeConnectionTarget
    ) async -> ClaudeSetupRequirement? { nil }
}

public protocol ClaudeConnectionSignInHandingOff: Sendable {
    /// Acceptance by Terminal is not completion of the provider's login.
    func handOffOfficialSignIn(target: ClaudeConnectionTarget) async -> Bool
}

/// Bounded setup operations only. No conversation, arbitrary command, secret,
/// connector, model or executor input exists on this service.
public actor OfficialClaudeConnectionService: ClaudeSetupServicing {
    private let inspector: any ClaudeOfflineSetupInspecting
    private let preparer: any ClaudeConnectionPreparing
    private let admission: any ClaudeConnectionAdmitting
    private let statusChecker: any ClaudeStatusChecking
    private let signInHandoff: any ClaudeConnectionSignInHandingOff
    private let now: @Sendable () -> Date
    private var operationInProgress = false

    public init(
        inspector: any ClaudeOfflineSetupInspecting,
        preparer: any ClaudeConnectionPreparing,
        admission: any ClaudeConnectionAdmitting = PendingClaudeConnectionAdmission(),
        statusChecker: any ClaudeStatusChecking = NativeClaudeStatusChecker(),
        signInHandoff: any ClaudeConnectionSignInHandingOff,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inspector = inspector
        self.preparer = preparer
        self.admission = admission
        self.statusChecker = statusChecker
        self.signInHandoff = signInHandoff
        self.now = now
    }

    public func checkThisMac() async -> ClaudeSetupReport {
        let report = await GuardedClaudeSetupService(inspector: inspector).checkThisMac()
        guard report.local?.installation == .verified,
              report.local?.profile == .metadataVerified,
              report.outcome == .actionRequired(.correctedStatusCheckApproval)
        else { return report }
        return .init(local: report.local, outcome: .readyToConnect)
    }

    public func checkSubscription() async -> ClaudeSetupReport {
        await perform(.status)
    }

    public func beginOfficialSignIn() async -> ClaudeSetupReport {
        await perform(.officialSignIn)
    }

    private func perform(_ operation: ClaudeConnectionOperation) async -> ClaudeSetupReport {
        guard !Task.isCancelled else { return .init(outcome: .cancelled) }
        guard !operationInProgress else {
            return .init(outcome: .problem(.connectionCheckInconclusive))
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let preparation = await preparer.prepareConnection()
        guard !Task.isCancelled else { return .init(outcome: .cancelled) }
        guard case let .ready(local, target) = preparation else {
            if case let .refused(report) = preparation { return report }
            return .init(outcome: .problem(.connectionCheckInconclusive))
        }
        guard local.installation == .verified, local.profile == .metadataVerified else {
            return .init(local: local, outcome: .problem(.connectionCheckInconclusive))
        }
        let requirement = await admission.unmetRequirement(for: operation, target: target)
        guard !Task.isCancelled else { return .init(local: local, outcome: .cancelled) }
        if let requirement { return .init(local: local, outcome: .actionRequired(requirement)) }

        switch operation {
        case .status:
            let result = await statusChecker.checkStatus(target: target)
            guard !Task.isCancelled else { return .init(local: local, outcome: .cancelled) }
            switch result {
            case .eligible(let tier):
                guard let verified = ClaudeVerifiedSubscription(
                    exitCode: 0, loggedIn: true, authMethod: "claude.ai",
                    apiProvider: "firstParty", subscriptionType: tier.rawValue, checkedAt: now()
                ) else { return .init(local: local, outcome: .problem(.connectionCheckInconclusive)) }
                return .init(local: local, outcome: .verified(verified))
            case .signedOut: return .init(local: local, outcome: .needsSignIn)
            case .inconclusive: return .init(local: local, outcome: .problem(.connectionCheckInconclusive))
            case .cancelled: return .init(local: local, outcome: .cancelled)
            }
        case .officialSignIn:
            let accepted = await signInHandoff.handOffOfficialSignIn(target: target)
            guard !Task.isCancelled else { return .init(local: local, outcome: .cancelled) }
            return .init(local: local, outcome: accepted
                ? .handedOffNeedsVerification : .problem(.signInIncomplete))
        }
    }
}
