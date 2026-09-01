import Foundation

/// A process-local review context, not a persisted capability or OS authorization.
public struct TrustFixtureContext: Codable, Hashable, Sendable {
    public let teammateID: TeammateID
    public let conversationID: ConversationID

    public init(teammateID: TeammateID, conversationID: ConversationID) {
        self.teammateID = teammateID
        self.conversationID = conversationID
    }
}

/// Closed preview capabilities. Shell is deliberately not representable here.
public enum FixtureCapability: String, Codable, CaseIterable, Sendable {
    case readReferenceFolder
    case createCompletedArtifact
    case connectorUse

    public var title: String {
        switch self {
        case .readReferenceFolder: "Read reference folder"
        case .createCompletedArtifact: "Create one completed artifact"
        case .connectorUse: "Use demo connector"
        }
    }

    /// Display-only labels: these are never resolved into URLs, handles or bookmarks.
    public var scopeSummary: String {
        switch self {
        case .readReferenceFolder: "Demo reference folder — read only; no mutation"
        case .createCompletedArtifact: "Demo delivery folder — one exact create-new file; no replacement"
        case .connectorUse: "Demo Mail account — one exact recipient and message per approval"
        }
    }

    public var effectSummary: String {
        "Simulate \(title.lowercased()) for this teammate and conversation only. Nothing is executed or granted outside this preview."
    }
}

public enum FixtureMacOSPermission: String, Codable, CaseIterable, Sendable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted
}

public enum FixtureGrantReviewState: String, Codable, Sendable {
    case pending
    case confirmed
    case declined
    case expired
    case invalidated
}

public struct FixtureGrantReview: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let context: TrustFixtureContext
    public let capability: FixtureCapability
    public let scopeSummary: String
    public let effectSummary: String
    public let generation: UInt64
    public let createdAt: Date
    public let expiresAt: Date
    public let fingerprint: String

    public init(id: UUID, context: TrustFixtureContext, capability: FixtureCapability,
                scopeSummary: String, effectSummary: String, generation: UInt64,
                createdAt: Date, expiresAt: Date, fingerprint: String) {
        self.id = id
        self.context = context
        self.capability = capability
        self.scopeSummary = scopeSummary
        self.effectSummary = effectSummary
        self.generation = generation
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
    }
}

public struct FixtureGrantReviewRecord: Equatable, Sendable, Identifiable {
    public var id: UUID { review.id }
    public let review: FixtureGrantReview
    public let state: FixtureGrantReviewState

    public init(review: FixtureGrantReview, state: FixtureGrantReviewState) {
        self.review = review
        self.state = state
    }
}

public struct FixtureCapabilityGrant: Equatable, Sendable, Identifiable {
    public let id: CapabilityGrantID
    public let context: TrustFixtureContext
    public let capability: FixtureCapability
    public let scopeSummary: String
    public let generation: UInt64
    public let status: CapabilityGrantStatus
    public let grantedAt: Date
    public let revokedAt: Date?

    public init(id: CapabilityGrantID, context: TrustFixtureContext,
                capability: FixtureCapability, scopeSummary: String, generation: UInt64,
                status: CapabilityGrantStatus, grantedAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.context = context
        self.capability = capability
        self.scopeSummary = scopeSummary
        self.generation = generation
        self.status = status
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }
}

/// Only two closed safe demonstrations may become approvable. The unsupported
/// case exists so unsafe proposals fail visibly, not so they can reach an executor.
public enum FixtureActionProposal: Codable, Equatable, Sendable {
    case completedArtifact(filename: String, contentSummary: String)
    case connectorSend(recipient: String, message: String)
    case unsupportedMutation(operation: ConsequentialActionKind, targetSummary: String, recursive: Bool)

    public static let sampleArtifact: Self = .completedArtifact(
        filename: "research-summary.pdf", contentSummary: "Completed research summary — demo bytes only"
    )
    public static let sampleConnectorSend: Self = .connectorSend(
        recipient: "reviewer@example.invalid", message: "The research summary is ready for your review."
    )

    public var capability: FixtureCapability? {
        switch self {
        case .completedArtifact: .createCompletedArtifact
        case .connectorSend: .connectorUse
        case .unsupportedMutation: nil
        }
    }

    public var targetSummary: String {
        switch self {
        case let .completedArtifact(filename, _): "Demo delivery folder / \(filename)"
        case let .connectorSend(recipient, _): "Demo Mail → \(recipient)"
        case let .unsupportedMutation(_, targetSummary, _): targetSummary
        }
    }

    public var payloadSummary: String {
        switch self {
        case let .completedArtifact(_, summary): summary
        case let .connectorSend(_, message): message
        case let .unsupportedMutation(operation, _, recursive):
            "\(operation.rawValue)\(recursive ? " recursively" : "") — unavailable in this preview"
        }
    }

    public var effectSummary: String {
        switch self {
        case .completedArtifact:
            "Create one new completed demo file only. An existing item is never replaced. A real local write in a synced folder may later synchronize through macOS; this preview writes nothing."
        case .connectorSend:
            "Send exactly the displayed demo message to the displayed recipient once. This preview sends nothing and accesses no account."
        case .unsupportedMutation:
            "Destructive, identity-changing and recursive provider operations are unavailable in this bounded preview."
        }
    }
}

public struct FixtureApprovalReview: Codable, Equatable, Sendable, Identifiable {
    public let id: ApprovalID
    public let context: TrustFixtureContext
    public let proposal: FixtureActionProposal
    public let grantID: CapabilityGrantID
    public let grantGeneration: UInt64
    public let scopeSummary: String
    public let effectSummary: String
    public let createdAt: Date
    public let expiresAt: Date
    public let fingerprint: String

    public init(id: ApprovalID, context: TrustFixtureContext, proposal: FixtureActionProposal,
                grantID: CapabilityGrantID, grantGeneration: UInt64,
                scopeSummary: String, effectSummary: String, createdAt: Date,
                expiresAt: Date, fingerprint: String) {
        self.id = id
        self.context = context
        self.proposal = proposal
        self.grantID = grantID
        self.grantGeneration = grantGeneration
        self.scopeSummary = scopeSummary
        self.effectSummary = effectSummary
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
    }
}

public enum FixtureApprovalState: String, Codable, Sendable {
    case pending
    case approved
    case denied
    case expired
    case invalidated
    case simulated
}

public struct FixtureApprovalRecord: Equatable, Sendable, Identifiable {
    public var id: ApprovalID { review.id }
    public let review: FixtureApprovalReview
    public let state: FixtureApprovalState

    public init(review: FixtureApprovalReview, state: FixtureApprovalState) {
        self.review = review
        self.state = state
    }
}

public struct FixtureTrustEvidence: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let summary: String

    public init(id: UInt64, timestamp: Date, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.summary = summary
    }
}

public struct TrustFixtureSnapshot: Equatable, Sendable {
    public let context: TrustFixtureContext
    public let macOSPermission: FixtureMacOSPermission
    public let connector: ConnectorSetupState
    public let grants: [FixtureCapabilityGrant]
    public let grantReviews: [FixtureGrantReviewRecord]
    public let approvals: [FixtureApprovalRecord]
    public let evidence: [FixtureTrustEvidence]

    public init(context: TrustFixtureContext, macOSPermission: FixtureMacOSPermission,
                connector: ConnectorSetupState, grants: [FixtureCapabilityGrant],
                grantReviews: [FixtureGrantReviewRecord], approvals: [FixtureApprovalRecord],
                evidence: [FixtureTrustEvidence]) {
        self.context = context
        self.macOSPermission = macOSPermission
        self.connector = connector
        self.grants = grants
        self.grantReviews = grantReviews
        self.approvals = approvals
        self.evidence = evidence
    }

    public func activeGrant(for capability: FixtureCapability) -> FixtureCapabilityGrant? {
        grants.last { $0.capability == capability && $0.status == .active }
    }

    /// This is eligibility for a simulated review, never production authorization.
    public func eligibilityBlocker(for capability: FixtureCapability) -> String? {
        guard activeGrant(for: capability) != nil else { return "This teammate has no active demo grant." }
        guard macOSPermission == .granted else { return "Simulated macOS permission is not granted." }
        if capability == .connectorUse {
            guard connector.installation == .installed else { return "Demo connector is not installed." }
            guard connector.accountAuthentication == .authenticated else { return "Demo account is not authenticated." }
        }
        return nil
    }
}

public enum TrustFixtureError: Error, Equatable, Sendable {
    case contextMismatch
    case unissuedReview
    case changedReview
    case expiredReview
    case grantMissing
    case grantRevoked
    case alreadyGranted
    case alreadyResolved
    case alreadyConsumed
    case prerequisitesNotReady
    case unsupportedOperation
    case invalidInput
    case capacityReached
}

/// No implementation of this protocol can be substituted for the production executor.
public protocol TrustAuthorizationFixtureServicing: Sendable {
    func snapshot(context: TrustFixtureContext) async throws -> TrustFixtureSnapshot
    func prepareGrant(context: TrustFixtureContext, capability: FixtureCapability) async throws -> FixtureGrantReview
    func confirmGrant(context: TrustFixtureContext, review: FixtureGrantReview) async throws -> TrustFixtureSnapshot
    func declineGrant(context: TrustFixtureContext, review: FixtureGrantReview) async throws -> TrustFixtureSnapshot
    func revoke(context: TrustFixtureContext, grantID: CapabilityGrantID) async throws -> TrustFixtureSnapshot
    func prepareApproval(context: TrustFixtureContext, proposal: FixtureActionProposal) async throws -> FixtureApprovalReview
    func resolveApproval(context: TrustFixtureContext, review: FixtureApprovalReview, decision: ApprovalDecision) async throws -> TrustFixtureSnapshot
    func consumeApprovedPreview(context: TrustFixtureContext, review: FixtureApprovalReview) async throws -> TrustFixtureSnapshot
    func setMacOSPermission(context: TrustFixtureContext, value: FixtureMacOSPermission) async throws -> TrustFixtureSnapshot
    func setConnectorInstallation(context: TrustFixtureContext, value: ConnectorInstallationState) async throws -> TrustFixtureSnapshot
    func setConnectorAuthentication(context: TrustFixtureContext, value: ConnectorAccountAuthenticationState) async throws -> TrustFixtureSnapshot
}
