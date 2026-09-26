import CryptoKit
import Foundation

// These domain values intentionally do not share a raw UUID type at call
// sites. Mixing a teammate, run, action, or approval identifier is therefore a
// compile-time error instead of an authorization-boundary typo.
public struct TeammateID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct RunID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ActionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ApprovalReceiptID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ProvenanceEventID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum BrokerPolicyError: Error, Equatable, Sendable {
    case invalidDigest
    case invalidTarget(String)
    case duplicateTarget(String)
    case invalidTraversalDepth
    case exclusiveCreateRequiresOneExactItem
    case providerRootRecursiveMutationForbidden
    case actionFingerprintMismatch
    case invalidApprovalWindow
    case duplicateReceiptID
    case unknownReceipt
    case receiptBindingMismatch
    case receiptNotYetValid
    case receiptExpired
    case receiptAlreadyConsumed
    case invalidProvenance(String)
}

/// The operation class is part of the frozen action fingerprint. A grant for a
/// read or create-only action can never be interpreted as a mutation grant.
public enum OperationClass: String, CaseIterable, Codable, Hashable, Sendable {
    case containedWorkspaceCommand
    case readOnlyExternalAccess
    case exclusiveCreateNewArtifactDelivery
    case packageInstallProposal
    case destructiveFilesystemChange
    case overwrite
    case rename
    case move
    case metadataMutation
    case sendOrPublish
    case credentialAccess
    case productionOrDeployment
    case purchase
    case permissionChange

    public var isDestructiveOrIdentityChangingFilesystemOperation: Bool {
        switch self {
        case .destructiveFilesystemChange, .overwrite, .rename, .move, .metadataMutation:
            true
        default:
            false
        }
    }

    public var requiresFreshExactApproval: Bool {
        self != .readOnlyExternalAccess
    }
}

public enum TargetKind: String, Codable, Hashable, Sendable {
    case filesystem
    case externalResource
}

/// Classification is supplied by the file/resource broker after resolving the
/// local target. This pure policy layer never probes the filesystem itself.
public enum LocationClassification: String, Codable, Hashable, Sendable {
    case appOwned
    case userOwnedLocal
    case providerManaged
    case uncertainExternal
    case notApplicable

    public var isProviderManagedOrUncertainExternal: Bool {
        self == .providerManaged || self == .uncertainExternal
    }
}

public enum TargetScope: String, Codable, Hashable, Sendable {
    case exactItem
    case narrowFolder
}

/// A canonical target is already resolved by an outer broker. Filesystem
/// values must be absolute, lexically standardized paths. An outer execution
/// boundary remains responsible for revalidating symlinks, aliases, file IDs,
/// mounts, bookmarks, and provider state immediately before a real effect.
public struct CanonicalTarget: Codable, Hashable, Sendable {
    public let kind: TargetKind
    public let canonicalIdentifier: String
    public let location: LocationClassification
    public let scope: TargetScope
    public let isProviderRoot: Bool

    public init(
        kind: TargetKind,
        canonicalIdentifier: String,
        location: LocationClassification,
        scope: TargetScope,
        isProviderRoot: Bool = false
    ) throws {
        guard !canonicalIdentifier.isEmpty,
              canonicalIdentifier.utf8.count <= 16_384,
              !canonicalIdentifier.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              })
        else {
            throw BrokerPolicyError.invalidTarget("target identifier is empty, oversized, or contains control characters")
        }

        switch kind {
        case .filesystem:
            guard canonicalIdentifier.hasPrefix("/") else {
                throw BrokerPolicyError.invalidTarget("filesystem target must be absolute")
            }
            let standardized = URL(fileURLWithPath: canonicalIdentifier).standardizedFileURL.path
            guard ProbePathSpelling.isCanonical(canonicalIdentifier, standardized: standardized) else {
                throw BrokerPolicyError.invalidTarget("filesystem target must already be lexically canonical")
            }
            guard location != .notApplicable else {
                throw BrokerPolicyError.invalidTarget("filesystem target requires a location classification")
            }

        case .externalResource:
            guard location == .notApplicable, scope == .exactItem, !isProviderRoot else {
                throw BrokerPolicyError.invalidTarget("external resources must be exact, non-filesystem targets")
            }
        }

        if isProviderRoot && !location.isProviderManagedOrUncertainExternal {
            throw BrokerPolicyError.invalidTarget("provider-root marker requires provider-managed or uncertain classification")
        }

        self.kind = kind
        self.canonicalIdentifier = canonicalIdentifier
        self.location = location
        self.scope = scope
        self.isProviderRoot = isProviderRoot
    }
}

public enum TraversalScope: Codable, Hashable, Sendable {
    case exactTargets
    case boundedDescendants(maximumDepth: Int)

    fileprivate var fingerprintFields: [String] {
        switch self {
        case .exactTargets:
            ["exactTargets"]
        case .boundedDescendants(let maximumDepth):
            ["boundedDescendants", String(maximumDepth)]
        }
    }
}

/// Lowercase SHA-256 encoded as exactly 64 hexadecimal characters.
public struct PayloadDigest: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isCanonicalSHA256(rawValue) else {
            throw BrokerPolicyError.invalidDigest
        }
        self.rawValue = rawValue
    }

    public static func sha256(of data: Data) -> PayloadDigest {
        PayloadDigest(validated: Self.sha256Hex(data))
    }

    fileprivate init(validated: String) {
        rawValue = validated
    }

    fileprivate static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    fileprivate static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ActionFingerprint: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard PayloadDigest.isCanonicalSHA256(rawValue) else {
            throw BrokerPolicyError.invalidDigest
        }
        self.rawValue = rawValue
    }

    fileprivate init(validated: String) {
        rawValue = validated
    }
}

public struct ActionProposal: Codable, Hashable, Sendable {
    public let actionID: ActionID
    public let teammateID: TeammateID
    public let runID: RunID
    public let operation: OperationClass
    public let targets: [CanonicalTarget]
    public let payloadDigest: PayloadDigest
    public let traversal: TraversalScope

    public init(
        actionID: ActionID,
        teammateID: TeammateID,
        runID: RunID,
        operation: OperationClass,
        targets: [CanonicalTarget],
        payloadDigest: PayloadDigest,
        traversal: TraversalScope = .exactTargets
    ) {
        self.actionID = actionID
        self.teammateID = teammateID
        self.runID = runID
        self.operation = operation
        self.targets = targets
        self.payloadDigest = payloadDigest
        self.traversal = traversal
    }
}

/// A frozen action is the only action shape an approval ledger accepts. The
/// stored fingerprint is always recomputed before issue or consumption so a
/// decoded or otherwise forged value still fails closed.
public struct FrozenAction: Codable, Hashable, Sendable {
    public let actionID: ActionID
    public let teammateID: TeammateID
    public let runID: RunID
    public let operation: OperationClass
    public let targets: [CanonicalTarget]
    public let payloadDigest: PayloadDigest
    public let traversal: TraversalScope
    public let fingerprint: ActionFingerprint

    init(proposal: ActionProposal, fingerprint: ActionFingerprint) {
        actionID = proposal.actionID
        teammateID = proposal.teammateID
        runID = proposal.runID
        operation = proposal.operation
        targets = proposal.targets
        payloadDigest = proposal.payloadDigest
        traversal = proposal.traversal
        self.fingerprint = fingerprint
    }

    init(
        actionID: ActionID,
        teammateID: TeammateID,
        runID: RunID,
        operation: OperationClass,
        targets: [CanonicalTarget],
        payloadDigest: PayloadDigest,
        traversal: TraversalScope,
        fingerprint: ActionFingerprint
    ) {
        self.actionID = actionID
        self.teammateID = teammateID
        self.runID = runID
        self.operation = operation
        self.targets = targets
        self.payloadDigest = payloadDigest
        self.traversal = traversal
        self.fingerprint = fingerprint
    }
}

public enum ApprovalRequirement: String, Codable, Hashable, Sendable {
    case explicitReadCapability
    case freshExactSingleUseApproval
}

public enum BrokerPolicy {
    public static func freeze(_ proposal: ActionProposal) throws -> FrozenAction {
        try validateShape(proposal)
        return FrozenAction(
            proposal: proposal,
            fingerprint: fingerprint(for: proposal)
        )
    }

    public static func validateIntegrity(of action: FrozenAction) throws {
        let proposal = ActionProposal(
            actionID: action.actionID,
            teammateID: action.teammateID,
            runID: action.runID,
            operation: action.operation,
            targets: action.targets,
            payloadDigest: action.payloadDigest,
            traversal: action.traversal
        )
        try validateShape(proposal)
        guard fingerprint(for: proposal) == action.fingerprint else {
            throw BrokerPolicyError.actionFingerprintMismatch
        }
    }

    public static func approvalRequirement(for action: FrozenAction) -> ApprovalRequirement {
        if action.operation.requiresFreshExactApproval {
            return .freshExactSingleUseApproval
        }

        if action.operation.isDestructiveOrIdentityChangingFilesystemOperation,
           action.targets.contains(where: { $0.location.isProviderManagedOrUncertainExternal }) {
            return .freshExactSingleUseApproval
        }

        return .explicitReadCapability
    }

    private static func validateShape(_ proposal: ActionProposal) throws {
        guard PayloadDigest.isCanonicalSHA256(proposal.payloadDigest.rawValue) else {
            throw BrokerPolicyError.invalidDigest
        }

        guard !proposal.targets.isEmpty else {
            throw BrokerPolicyError.invalidTarget("action requires at least one exact target")
        }
        for target in proposal.targets {
            _ = try CanonicalTarget(
                kind: target.kind,
                canonicalIdentifier: target.canonicalIdentifier,
                location: target.location,
                scope: target.scope,
                isProviderRoot: target.isProviderRoot
            )
        }

        let targetKeys = proposal.targets.map {
            "\($0.kind.rawValue):\($0.canonicalIdentifier):\($0.scope.rawValue)"
        }
        var seen = Set<String>()
        for key in targetKeys where !seen.insert(key).inserted {
            throw BrokerPolicyError.duplicateTarget(key)
        }

        if case .boundedDescendants(let maximumDepth) = proposal.traversal,
           maximumDepth <= 0 {
            throw BrokerPolicyError.invalidTraversalDepth
        }

        if proposal.operation == .exclusiveCreateNewArtifactDelivery {
            guard proposal.targets.count == 1,
                  proposal.targets[0].kind == .filesystem,
                  proposal.targets[0].scope == .exactItem,
                  !proposal.targets[0].isProviderRoot,
                  proposal.traversal == .exactTargets
            else {
                throw BrokerPolicyError.exclusiveCreateRequiresOneExactItem
            }
        }

        if proposal.operation == .containedWorkspaceCommand {
            guard proposal.targets.count <= 2, proposal.traversal == .exactTargets,
                  proposal.targets.allSatisfy({ $0.kind == .filesystem && $0.location == .appOwned
                      && $0.scope == .narrowFolder && !$0.isProviderRoot }) else {
                throw BrokerPolicyError.invalidTarget("contained commands require exact app-owned workspace scopes")
            }
        }

        if proposal.operation.isDestructiveOrIdentityChangingFilesystemOperation,
           proposal.targets.contains(where: { $0.isProviderRoot }),
           proposal.traversal != .exactTargets {
            throw BrokerPolicyError.providerRootRecursiveMutationForbidden
        }
    }

    private static func fingerprint(for proposal: ActionProposal) -> ActionFingerprint {
        var fields = [
            "openbots-agentic-boundary-action-v1",
            proposal.actionID.rawValue.uuidString.lowercased(),
            proposal.teammateID.rawValue.uuidString.lowercased(),
            proposal.runID.rawValue.uuidString.lowercased(),
            proposal.operation.rawValue,
            proposal.payloadDigest.rawValue,
            String(proposal.targets.count),
        ]

        fields.append(contentsOf: proposal.traversal.fingerprintFields)
        for target in proposal.targets {
            fields.append(contentsOf: [
                target.kind.rawValue,
                target.canonicalIdentifier,
                target.location.rawValue,
                target.scope.rawValue,
                target.isProviderRoot ? "providerRoot" : "notProviderRoot",
            ])
        }

        let encoded = fields.map { field in
            "\(field.utf8.count):\(field)"
        }.joined(separator: "|")
        return ActionFingerprint(validated: PayloadDigest.sha256Hex(Data(encoded.utf8)))
    }
}

public struct ApprovalReceipt: Codable, Hashable, Sendable {
    public let receiptID: ApprovalReceiptID
    public let actionID: ActionID
    public let teammateID: TeammateID
    public let runID: RunID
    public let actionFingerprint: ActionFingerprint
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        receiptID: ApprovalReceiptID,
        actionID: ActionID,
        teammateID: TeammateID,
        runID: RunID,
        actionFingerprint: ActionFingerprint,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.receiptID = receiptID
        self.actionID = actionID
        self.teammateID = teammateID
        self.runID = runID
        self.actionFingerprint = actionFingerprint
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct BrokerAuthorization: Codable, Hashable, Sendable {
    public let receiptID: ApprovalReceiptID
    public let actionID: ActionID
    public let teammateID: TeammateID
    public let runID: RunID
    public let actionFingerprint: ActionFingerprint
    public let authorizedAt: Date
}

/// Deterministic in-memory authority for the feasibility probe. Receipt UUIDs
/// are caller-supplied so tests and persistence layers do not depend on ambient
/// randomness. The locked reference identity prevents value-copy or concurrent
/// consumption from turning one receipt into two authorities. The private
/// ledger record, not possession of a receipt-shaped value, establishes that
/// the receipt was issued. Durable production persistence remains a later seam.
public final class ApprovalLedger: @unchecked Sendable {
    private struct Record: Sendable {
        let receipt: ApprovalReceipt
        var consumed: Bool
    }

    private let lock = NSLock()
    private var records: [ApprovalReceiptID: Record] = [:]

    public init() {}

    public func issue(
        receiptID: ApprovalReceiptID,
        for action: FrozenAction,
        issuedAt: Date,
        expiresAt: Date
    ) throws -> ApprovalReceipt {
        try BrokerPolicy.validateIntegrity(of: action)
        guard expiresAt > issuedAt else {
            throw BrokerPolicyError.invalidApprovalWindow
        }

        lock.lock()
        defer { lock.unlock() }
        guard records[receiptID] == nil else {
            throw BrokerPolicyError.duplicateReceiptID
        }

        let receipt = ApprovalReceipt(
            receiptID: receiptID,
            actionID: action.actionID,
            teammateID: action.teammateID,
            runID: action.runID,
            actionFingerprint: action.fingerprint,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        records[receiptID] = Record(receipt: receipt, consumed: false)
        return receipt
    }

    public func consume(
        _ receipt: ApprovalReceipt,
        for action: FrozenAction,
        at now: Date
    ) throws -> BrokerAuthorization {
        try BrokerPolicy.validateIntegrity(of: action)

        lock.lock()
        defer { lock.unlock() }
        guard var record = records[receipt.receiptID] else {
            throw BrokerPolicyError.unknownReceipt
        }
        guard !record.consumed else {
            throw BrokerPolicyError.receiptAlreadyConsumed
        }
        guard record.receipt == receipt,
              receipt.actionID == action.actionID,
              receipt.teammateID == action.teammateID,
              receipt.runID == action.runID,
              receipt.actionFingerprint == action.fingerprint
        else {
            throw BrokerPolicyError.receiptBindingMismatch
        }
        guard now >= receipt.issuedAt else {
            throw BrokerPolicyError.receiptNotYetValid
        }
        guard now < receipt.expiresAt else {
            throw BrokerPolicyError.receiptExpired
        }

        record.consumed = true
        records[receipt.receiptID] = record
        return BrokerAuthorization(
            receiptID: receipt.receiptID,
            actionID: action.actionID,
            teammateID: action.teammateID,
            runID: action.runID,
            actionFingerprint: action.fingerprint,
            authorizedAt: now
        )
    }
}

public enum ProvenanceOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut
    case outcomeUnknown
    case refused
}

/// The schema deliberately accepts only identities, canonical executable path,
/// digests, timestamps, and outcomes. It has no fields for raw argv, raw script,
/// environment values, credentials, output, or model/private reasoning.
public struct StructuredCommandProvenance: Codable, Hashable, Sendable {
    public let eventID: ProvenanceEventID
    public let teammateID: TeammateID
    public let runID: RunID
    public let actionID: ActionID
    public let operation: OperationClass
    public let canonicalExecutablePath: String
    public let argumentDigest: PayloadDigest
    public let scriptDigest: PayloadDigest?
    public let workingScopeFingerprints: [ActionFingerprint]
    public let policyDigest: PayloadDigest
    public let approvalReceiptID: ApprovalReceiptID?
    public let startedAt: Date
    public let endedAt: Date?
    public let outcome: ProvenanceOutcome
    public let artifactDigests: [PayloadDigest]

    public init(
        eventID: ProvenanceEventID,
        teammateID: TeammateID,
        runID: RunID,
        actionID: ActionID,
        operation: OperationClass,
        canonicalExecutablePath: String,
        argumentDigest: PayloadDigest,
        scriptDigest: PayloadDigest?,
        workingScopeFingerprints: [ActionFingerprint],
        policyDigest: PayloadDigest,
        approvalReceiptID: ApprovalReceiptID?,
        startedAt: Date,
        endedAt: Date?,
        outcome: ProvenanceOutcome,
        artifactDigests: [PayloadDigest]
    ) throws {
        guard canonicalExecutablePath.hasPrefix("/"),
              URL(fileURLWithPath: canonicalExecutablePath).standardizedFileURL.path == canonicalExecutablePath
        else {
            throw BrokerPolicyError.invalidProvenance("executable path must be absolute and canonical")
        }
        if let endedAt, endedAt < startedAt {
            throw BrokerPolicyError.invalidProvenance("end precedes start")
        }

        self.eventID = eventID
        self.teammateID = teammateID
        self.runID = runID
        self.actionID = actionID
        self.operation = operation
        self.canonicalExecutablePath = canonicalExecutablePath
        self.argumentDigest = argumentDigest
        self.scriptDigest = scriptDigest
        self.workingScopeFingerprints = workingScopeFingerprints
        self.policyDigest = policyDigest
        self.approvalReceiptID = approvalReceiptID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.artifactDigests = artifactDigests
    }
}
