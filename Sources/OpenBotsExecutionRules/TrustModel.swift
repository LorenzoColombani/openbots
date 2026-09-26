import Foundation

/// Version of the warning and policy whose exact meaning the user accepted.
public struct ShellPolicyVersion: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ShellModePresentation: Codable, Equatable, Hashable, Sendable {
    /// Short visible text that remains meaningful without color or an icon.
    public let statusText: String
    /// A compact non-color cue suitable for a badge or audit record.
    public let nonColorCue: String
    public let accessibilityLabel: String
    public let detailText: String

    public init(
        statusText: String,
        nonColorCue: String,
        accessibilityLabel: String,
        detailText: String
    ) {
        self.statusText = statusText
        self.nonColorCue = nonColorCue
        self.accessibilityLabel = accessibilityLabel
        self.detailText = detailText
    }
}

public enum ShellMode: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case contained
    case higherTrust

    public var presentation: ShellModePresentation {
        switch self {
        case .off:
            ShellModePresentation(
                statusText: "Off",
                nonColorCue: "OFF",
                accessibilityLabel: "Shell access off",
                detailText: "This teammate cannot start broad local commands."
            )
        case .contained:
            ShellModePresentation(
                statusText: "Contained",
                nonColorCue: "CONTAINED",
                accessibilityLabel: "Shell access enabled in contained probe mode",
                detailText: "New shell calls require the approved Claude Code sandbox and OpenBots broker boundary."
            )
        case .higherTrust:
            ShellModePresentation(
                statusText: "Higher trust",
                nonColorCue: "HIGHER TRUST",
                accessibilityLabel: "Higher-trust shell access",
                detailText: "This teammate can run broad local commands with the user's authority; folder and domain controls are not a hard operating-system security boundary."
            )
        }
    }

    public var enablementWarning: String? {
        switch self {
        case .off:
            nil
        case .contained:
            "This teammate may run broad local commands inside the candidate contained boundary. Exact approvals still apply to consequential actions."
        case .higherTrust:
            "This teammate can run broad local commands with your user authority. Fine-grained folder and domain controls are not a hard operating-system security boundary, and scripts or installed tools can have indirect side effects."
        }
    }
}

/// The current authorization is intentionally narrow. No case in this type can
/// authorize higher-trust mode; adding one requires a later reviewed decision.
public enum ShellEnablementAuthorization: String, Codable, Hashable, Sendable {
    case boundedPhysicalMacProbe

    public func permits(_ mode: ShellMode) -> Bool {
        switch (self, mode) {
        case (.boundedPhysicalMacProbe, .contained):
            true
        case (.boundedPhysicalMacProbe, .off),
             (.boundedPhysicalMacProbe, .higherTrust):
            false
        }
    }
}

/// Evidence of one explicit warning acknowledgement. It is usable only for the
/// teammate, policy version, and requested mode recorded here.
public struct ShellWarningReceipt: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let teammateID: TeammateID
    public let policyVersion: ShellPolicyVersion
    public let requestedMode: ShellMode
    public let wasAffirmativelyAccepted: Bool

    public init(
        id: UUID,
        teammateID: TeammateID,
        policyVersion: ShellPolicyVersion,
        requestedMode: ShellMode,
        wasAffirmativelyAccepted: Bool
    ) {
        self.id = id
        self.teammateID = teammateID
        self.policyVersion = policyVersion
        self.requestedMode = requestedMode
        self.wasAffirmativelyAccepted = wasAffirmativelyAccepted
    }
}

/// Any route that materializes a teammate must explicitly pass through this
/// list. Every route starts with shell access off.
public enum TeammateMaterialization: String, Codable, CaseIterable, Hashable, Sendable {
    case creation
    case duplication
    case importFromFile
    case restoreFromBackup
    case promoteEphemeralWorker
}

public struct CollaborationMembership: Codable, Equatable, Hashable, Sendable {
    public let teamIDs: Set<UUID>
    public let projectIDs: Set<UUID>

    public init(teamIDs: Set<UUID>, projectIDs: Set<UUID>) {
        self.teamIDs = teamIDs
        self.projectIDs = projectIDs
    }
}

public enum ShellTrustDisableReason: String, Codable, Hashable, Sendable {
    case revoke
    case reset
}

public enum ShellTrustAction: Codable, Equatable, Hashable, Sendable {
    case enable(
        mode: ShellMode,
        warningReceipt: ShellWarningReceipt,
        authorization: ShellEnablementAuthorization
    )
    case disable(reason: ShellTrustDisableReason)
    /// Membership is observable input, but it has no shell-trust effect.
    case observeMembership(CollaborationMembership)
}

public struct ShellTrustCommand: Codable, Equatable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: UInt64
    public let action: ShellTrustAction

    public init(operationID: UUID, expectedRevision: UInt64, action: ShellTrustAction) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.action = action
    }
}

public enum ShellTrustRejection: Codable, Equatable, Hashable, Sendable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case operationIdentifierConflict
    case warningNotAffirmativelyAccepted
    case warningBoundToDifferentTeammate
    case warningBoundToDifferentPolicy
    case warningBoundToDifferentMode
    case warningReceiptAlreadyUsed
    case modeCannotBeEnabled(ShellMode)
    case modeNotAuthorizedByCurrentProbe(ShellMode)
    case revisionExhausted
}

public enum ShellTrustEffect: Codable, Equatable, Hashable, Sendable {
    case enabled(ShellMode)
    case disabled(previousMode: ShellMode, reason: ShellTrustDisableReason)
    case alreadyDisabled(reason: ShellTrustDisableReason)
    case membershipObservedWithoutTrustChange
    case rejected(ShellTrustRejection)
}

/// Revoking trust and stopping a running process are deliberately separate.
public enum ExistingRunDisposition: String, Codable, Equatable, Hashable, Sendable {
    case unchanged
    case unaffectedRequiresExplicitStop
}

public struct ShellTrustMutationResult: Codable, Equatable, Hashable, Sendable {
    public let effect: ShellTrustEffect
    public let isIdempotentReplay: Bool
    public let mode: ShellMode
    public let revision: UInt64
    public let existingRunDisposition: ExistingRunDisposition

    public init(
        effect: ShellTrustEffect,
        isIdempotentReplay: Bool,
        mode: ShellMode,
        revision: UInt64,
        existingRunDisposition: ExistingRunDisposition
    ) {
        self.effect = effect
        self.isIdempotentReplay = isIdempotentReplay
        self.mode = mode
        self.revision = revision
        self.existingRunDisposition = existingRunDisposition
    }
}

public struct ShellRunAuthorization: Codable, Equatable, Hashable, Sendable {
    public let runID: RunID
    public let teammateID: TeammateID
    public let modeAtStart: ShellMode
    public let trustRevisionAtStart: UInt64

    init(
        runID: RunID,
        teammateID: TeammateID,
        modeAtStart: ShellMode,
        trustRevisionAtStart: UInt64
    ) {
        self.runID = runID
        self.teammateID = teammateID
        self.modeAtStart = modeAtStart
        self.trustRevisionAtStart = trustRevisionAtStart
    }
}

public enum NewShellCallDecision: Codable, Equatable, Hashable, Sendable {
    case deniedShellOff
    case granted(ShellRunAuthorization)
}

/// Pure feasibility state machine. It performs no execution, persistence,
/// authentication, prompting, or operating-system access.
public struct TeammateShellTrustRecord: Codable, Equatable, Sendable {
    public let teammateID: TeammateID
    public let policyVersion: ShellPolicyVersion
    public let materializedBy: TeammateMaterialization
    public private(set) var mode: ShellMode
    public private(set) var revision: UInt64

    private var consumedWarningReceiptIDs: Set<UUID>
    private var processedOperations: [UUID: ProcessedOperation]

    public init(
        teammateID: TeammateID,
        policyVersion: ShellPolicyVersion,
        materializedBy: TeammateMaterialization
    ) {
        self.teammateID = teammateID
        self.policyVersion = policyVersion
        self.materializedBy = materializedBy
        mode = .off
        revision = 0
        consumedWarningReceiptIDs = []
        processedOperations = [:]
    }

    public func authorizeNewShellCall(runID: RunID) -> NewShellCallDecision {
        guard mode != .off else {
            return .deniedShellOff
        }
        return .granted(
            ShellRunAuthorization(
                runID: runID,
                teammateID: teammateID,
                modeAtStart: mode,
                trustRevisionAtStart: revision
            )
        )
    }

    @discardableResult
    public mutating func handle(_ command: ShellTrustCommand) -> ShellTrustMutationResult {
        let fingerprint = CommandFingerprint(
            expectedRevision: command.expectedRevision,
            action: command.action
        )

        if let processed = processedOperations[command.operationID] {
            guard processed.fingerprint == fingerprint else {
                return result(
                    effect: .rejected(.operationIdentifierConflict),
                    isReplay: false,
                    existingRunDisposition: .unchanged
                )
            }
            return result(
                effect: processed.effect,
                isReplay: true,
                existingRunDisposition: processed.existingRunDisposition
            )
        }

        let evaluation: Evaluation
        if command.expectedRevision != revision {
            evaluation = Evaluation(
                effect: .rejected(
                    .staleRevision(expected: command.expectedRevision, actual: revision)
                ),
                existingRunDisposition: .unchanged
            )
        } else {
            evaluation = evaluate(command.action)
        }

        processedOperations[command.operationID] = ProcessedOperation(
            fingerprint: fingerprint,
            effect: evaluation.effect,
            existingRunDisposition: evaluation.existingRunDisposition
        )
        return result(
            effect: evaluation.effect,
            isReplay: false,
            existingRunDisposition: evaluation.existingRunDisposition
        )
    }

    private mutating func evaluate(_ action: ShellTrustAction) -> Evaluation {
        switch action {
        case .enable(let requestedMode, let receipt, let authorization):
            guard requestedMode != .off else {
                return rejected(.modeCannotBeEnabled(requestedMode))
            }
            guard receipt.wasAffirmativelyAccepted else {
                return rejected(.warningNotAffirmativelyAccepted)
            }
            guard receipt.teammateID == teammateID else {
                return rejected(.warningBoundToDifferentTeammate)
            }
            guard receipt.policyVersion == policyVersion else {
                return rejected(.warningBoundToDifferentPolicy)
            }
            guard receipt.requestedMode == requestedMode else {
                return rejected(.warningBoundToDifferentMode)
            }
            guard !consumedWarningReceiptIDs.contains(receipt.id) else {
                return rejected(.warningReceiptAlreadyUsed)
            }
            guard authorization.permits(requestedMode) else {
                return rejected(.modeNotAuthorizedByCurrentProbe(requestedMode))
            }
            guard mode != requestedMode else {
                // A second affirmative warning is not allowed to remain as a
                // latent grant that could silently re-enable shell after a
                // later revocation.
                consumedWarningReceiptIDs.insert(receipt.id)
                return Evaluation(
                    effect: .enabled(requestedMode),
                    existingRunDisposition: .unchanged
                )
            }
            guard advanceRevision() else {
                return rejected(.revisionExhausted)
            }
            mode = requestedMode
            consumedWarningReceiptIDs.insert(receipt.id)
            return Evaluation(
                effect: .enabled(requestedMode),
                existingRunDisposition: .unchanged
            )

        case .disable(let reason):
            guard mode != .off else {
                return Evaluation(
                    effect: .alreadyDisabled(reason: reason),
                    existingRunDisposition: .unchanged
                )
            }
            let previousMode = mode
            guard advanceRevision() else {
                return rejected(.revisionExhausted)
            }
            mode = .off
            return Evaluation(
                effect: .disabled(previousMode: previousMode, reason: reason),
                existingRunDisposition: .unaffectedRequiresExplicitStop
            )

        case .observeMembership:
            return Evaluation(
                effect: .membershipObservedWithoutTrustChange,
                existingRunDisposition: .unchanged
            )
        }
    }

    private mutating func advanceRevision() -> Bool {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { return false }
        revision = next
        return true
    }

    private func rejected(_ rejection: ShellTrustRejection) -> Evaluation {
        Evaluation(
            effect: .rejected(rejection),
            existingRunDisposition: .unchanged
        )
    }

    private func result(
        effect: ShellTrustEffect,
        isReplay: Bool,
        existingRunDisposition: ExistingRunDisposition
    ) -> ShellTrustMutationResult {
        ShellTrustMutationResult(
            effect: effect,
            isIdempotentReplay: isReplay,
            mode: mode,
            revision: revision,
            existingRunDisposition: existingRunDisposition
        )
    }
}

private extension TeammateShellTrustRecord {
    struct CommandFingerprint: Codable, Equatable, Sendable {
        let expectedRevision: UInt64
        let action: ShellTrustAction
    }

    struct ProcessedOperation: Codable, Equatable, Sendable {
        let fingerprint: CommandFingerprint
        let effect: ShellTrustEffect
        let existingRunDisposition: ExistingRunDisposition
    }

    struct Evaluation {
        let effect: ShellTrustEffect
        let existingRunDisposition: ExistingRunDisposition
    }
}
