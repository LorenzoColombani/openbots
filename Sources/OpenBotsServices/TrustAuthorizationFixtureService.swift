import CryptoKit
import Foundation
import OpenBotsDomain

/// A bounded in-memory trust demonstration. It cannot call a file broker,
/// runtime, connector, OS permission API, repository or credential provider.
public actor TrustAuthorizationFixtureService: TrustAuthorizationFixtureServicing {
    public static let disclosure = "Trust review fixture — grants, macOS permission and connector readiness are simulated for this teammate and conversation. They reset when OpenBots quits. No files, accounts, credentials or runtime are accessed. Nothing is executed. Shell remains unavailable."

    private let context: TrustFixtureContext
    private let clock: any OpenBotsClock
    private let uuidGenerator: any UUIDGenerator
    private let reviewLifetime: TimeInterval
    private var permission: FixtureMacOSPermission = .notDetermined
    private var installation: ConnectorInstallationState = .notInstalled
    private var authentication: ConnectorAccountAuthenticationState = .notAuthenticated
    private var grants: [FixtureCapabilityGrant] = []
    private var grantReviews: [FixtureGrantReviewRecord] = []
    private var approvals: [FixtureApprovalRecord] = []
    private var generations: [FixtureCapability: UInt64] = [:]
    private var evidence: [FixtureTrustEvidence] = []
    private var evidenceOrdinal: UInt64 = 0
    private var issuedIDs: Set<UUID> = []
    private static let maximumReviews = 64

    public init(
        context: TrustFixtureContext,
        clock: any OpenBotsClock = SystemClock(),
        uuidGenerator: any UUIDGenerator = SystemUUIDGenerator(),
        reviewLifetime: TimeInterval = 300
    ) {
        self.context = context
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.reviewLifetime = reviewLifetime
    }

    public func snapshot(context: TrustFixtureContext) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        return makeSnapshot()
    }

    public func prepareGrant(context: TrustFixtureContext, capability: FixtureCapability) throws -> FixtureGrantReview {
        try validate(context)
        expireReviews()
        try checkCapacity()
        guard activeGrant(capability) == nil else { throw TrustFixtureError.alreadyGranted }
        let now = clock.now()
        let draft = FixtureGrantReview(
            id: try nextID(), context: context, capability: capability,
            scopeSummary: capability.scopeSummary, effectSummary: capability.effectSummary,
            generation: generations[capability, default: 0], createdAt: now,
            expiresAt: now.addingTimeInterval(reviewLifetime), fingerprint: ""
        )
        let review = grantReview(draft, fingerprint: try fingerprint(draft))
        grantReviews.append(.init(review: review, state: .pending))
        record("Prepared exact demo grant review: \(capability.title). No authority changed.")
        return review
    }

    public func confirmGrant(context: TrustFixtureContext, review: FixtureGrantReview) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        let index = try validateGrantReview(review)
        guard activeGrant(review.capability) == nil else { throw TrustFixtureError.alreadyGranted }
        let grant = FixtureCapabilityGrant(
            id: CapabilityGrantID(try nextID()), context: context,
            capability: review.capability, scopeSummary: review.scopeSummary,
            generation: review.generation, status: .active, grantedAt: clock.now()
        )
        grants.append(grant)
        grantReviews[index] = .init(review: review, state: .confirmed)
        for other in grantReviews.indices where other != index
            && grantReviews[other].review.capability == review.capability
            && grantReviews[other].state == .pending {
            grantReviews[other] = .init(review: grantReviews[other].review, state: .invalidated)
        }
        record("Confirmed \(review.capability.title) demo grant. Other permission layers did not change.")
        return makeSnapshot()
    }

    public func declineGrant(context: TrustFixtureContext, review: FixtureGrantReview) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        let index = try validateGrantReview(review)
        grantReviews[index] = .init(review: review, state: .declined)
        record("Declined demo grant. No authority changed.")
        return makeSnapshot()
    }

    public func revoke(context: TrustFixtureContext, grantID: CapabilityGrantID) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        guard let index = grants.firstIndex(where: { $0.id == grantID }) else { throw TrustFixtureError.grantMissing }
        let grant = grants[index]
        guard grant.status == .active else { throw TrustFixtureError.grantRevoked }
        grants[index] = FixtureCapabilityGrant(
            id: grant.id, context: context, capability: grant.capability,
            scopeSummary: grant.scopeSummary, generation: grant.generation,
            status: .revoked, grantedAt: grant.grantedAt, revokedAt: clock.now()
        )
        generations[grant.capability] = grant.generation + 1
        for index in approvals.indices where approvals[index].review.grantID == grantID
            && [.pending, .approved].contains(approvals[index].state) {
            approvals[index] = .init(review: approvals[index].review, state: .invalidated)
        }
        for index in grantReviews.indices where grantReviews[index].review.capability == grant.capability
            && grantReviews[index].state == .pending {
            grantReviews[index] = .init(review: grantReviews[index].review, state: .invalidated)
        }
        record("Revoked \(grant.capability.title) demo grant and invalidated its outstanding approvals. Regrant cannot revive them.")
        return makeSnapshot()
    }

    public func prepareApproval(context: TrustFixtureContext, proposal: FixtureActionProposal) throws -> FixtureApprovalReview {
        try validate(context)
        expireReviews()
        try checkCapacity()
        let capability = try validateProposal(proposal)
        guard let grant = activeGrant(capability) else { throw TrustFixtureError.grantMissing }
        try requireReadiness(capability)
        let now = clock.now()
        let draft = FixtureApprovalReview(
            id: ApprovalID(try nextID()), context: context, proposal: proposal,
            grantID: grant.id, grantGeneration: grant.generation,
            scopeSummary: grant.scopeSummary, effectSummary: proposal.effectSummary,
            createdAt: now, expiresAt: now.addingTimeInterval(reviewLifetime), fingerprint: ""
        )
        let review = approvalReview(draft, fingerprint: try fingerprint(draft))
        approvals.append(.init(review: review, state: .pending))
        record("Prepared an exact demo action review. Nothing is executed.")
        return review
    }

    public func resolveApproval(
        context: TrustFixtureContext, review: FixtureApprovalReview, decision: ApprovalDecision
    ) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        let index = try validateApprovalReview(review)
        guard approvals[index].state == .pending else { throw TrustFixtureError.alreadyResolved }
        let capability = try validateProposal(review.proposal)
        if decision == .approve { try requireReadiness(capability) }
        approvals[index] = .init(review: review, state: decision == .approve ? .approved : .denied)
        record(decision == .approve
               ? "Approved the exact demo action once. This is not execution or a broader grant."
               : "Denied the exact demo action. Nothing is executed.")
        return makeSnapshot()
    }

    /// Actor isolation makes check + consumption atomic. No await or external
    /// call appears between them, and the result expressly is not execution.
    public func consumeApprovedPreview(
        context: TrustFixtureContext, review: FixtureApprovalReview
    ) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        let index = try validateApprovalReview(review)
        guard approvals[index].state != .simulated else { throw TrustFixtureError.alreadyConsumed }
        guard approvals[index].state == .approved else { throw TrustFixtureError.alreadyResolved }
        try requireReadiness(try validateProposal(review.proposal))
        approvals[index] = .init(review: review, state: .simulated)
        record("Simulation complete; the one-shot approval is consumed. Nothing was executed, created or sent.")
        return makeSnapshot()
    }

    public func setMacOSPermission(context: TrustFixtureContext, value: FixtureMacOSPermission) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        permission = value
        record("Simulated macOS permission: \(value.rawValue). No system prompt or setting changed.")
        return makeSnapshot()
    }

    public func setConnectorInstallation(context: TrustFixtureContext, value: ConnectorInstallationState) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        installation = value
        record("Simulated connector installation: \(value.rawValue). No connector was installed.")
        return makeSnapshot()
    }

    public func setConnectorAuthentication(context: TrustFixtureContext, value: ConnectorAccountAuthenticationState) throws -> TrustFixtureSnapshot {
        try validate(context)
        expireReviews()
        authentication = value
        record("Simulated connector authentication: \(value.rawValue). No account or credential was accessed.")
        return makeSnapshot()
    }

    private func validate(_ submittedContext: TrustFixtureContext) throws {
        guard submittedContext == context else { throw TrustFixtureError.contextMismatch }
        guard reviewLifetime.isFinite, (1...3_600).contains(reviewLifetime),
              clock.now().timeIntervalSinceReferenceDate.isFinite else { throw TrustFixtureError.invalidInput }
    }

    private func validateGrantReview(_ review: FixtureGrantReview) throws -> Int {
        guard review.context == context else { throw TrustFixtureError.contextMismatch }
        guard let index = grantReviews.firstIndex(where: { $0.id == review.id }) else { throw TrustFixtureError.unissuedReview }
        guard grantReviews[index].review == review,
              try fingerprint(review) == review.fingerprint else { throw TrustFixtureError.changedReview }
        guard grantReviews[index].state != .expired else { throw TrustFixtureError.expiredReview }
        guard grantReviews[index].state == .pending else { throw TrustFixtureError.alreadyResolved }
        guard review.createdAt <= clock.now(), review.expiresAt > clock.now() else { throw TrustFixtureError.expiredReview }
        guard review.generation == generations[review.capability, default: 0] else { throw TrustFixtureError.grantRevoked }
        return index
    }

    private func validateApprovalReview(_ review: FixtureApprovalReview) throws -> Int {
        guard review.context == context else { throw TrustFixtureError.contextMismatch }
        guard let index = approvals.firstIndex(where: { $0.id == review.id }) else { throw TrustFixtureError.unissuedReview }
        guard approvals[index].review == review,
              try fingerprint(review) == review.fingerprint else { throw TrustFixtureError.changedReview }
        if approvals[index].state == .expired { throw TrustFixtureError.expiredReview }
        if approvals[index].state == .simulated { return index }
        guard review.createdAt <= clock.now(), review.expiresAt > clock.now() else { throw TrustFixtureError.expiredReview }
        guard let grant = grants.first(where: { $0.id == review.grantID }),
              grant.status == .active,
              grant.generation == review.grantGeneration,
              generations[grant.capability, default: 0] == review.grantGeneration,
              grant.context == review.context,
              grant.scopeSummary == review.scopeSummary,
              grant.capability == review.proposal.capability else { throw TrustFixtureError.grantRevoked }
        guard approvals[index].state != .invalidated else { throw TrustFixtureError.grantRevoked }
        return index
    }

    private func validateProposal(_ proposal: FixtureActionProposal) throws -> FixtureCapability {
        switch proposal {
        case let .completedArtifact(filename, summary):
            guard validText(filename, maximum: 120), validText(summary, maximum: 2_000),
                  filename != ".", filename != "..", !filename.contains("/"),
                  !filename.contains("\\"), !filename.contains(":"), !filename.contains("*"),
                  !filename.contains("?"), !filename.contains("[") else { throw TrustFixtureError.invalidInput }
            return .createCompletedArtifact
        case let .connectorSend(recipient, message):
            guard validText(recipient, maximum: 240), validText(message, maximum: 2_000),
                  recipient.hasSuffix("@example.invalid"),
                  recipient.filter({ $0 == "@" }).count == 1,
                  !recipient.contains(where: { $0.isWhitespace }),
                  recipient.count > "@example.invalid".count else { throw TrustFixtureError.invalidInput }
            return .connectorUse
        case .unsupportedMutation:
            throw TrustFixtureError.unsupportedOperation
        }
    }

    private func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximum
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func requireReadiness(_ capability: FixtureCapability) throws {
        guard makeSnapshot().eligibilityBlocker(for: capability) == nil else { throw TrustFixtureError.prerequisitesNotReady }
    }

    private func activeGrant(_ capability: FixtureCapability) -> FixtureCapabilityGrant? {
        grants.last { $0.capability == capability && $0.status == .active }
    }

    private func makeSnapshot() -> TrustFixtureSnapshot {
        let connectorGrant: ConnectorPerBotGrantState = activeGrant(.connectorUse) != nil
            ? .granted : grants.contains(where: { $0.capability == .connectorUse }) ? .revoked : .notGranted
        let connectorApproval: ConnectorPerActionApprovalState
        switch approvals.last(where: { $0.review.proposal.capability == .connectorUse })?.state {
        case .pending: connectorApproval = .pending
        case .approved: connectorApproval = .approved
        case .denied: connectorApproval = .denied
        default: connectorApproval = .notRequested
        }
        return TrustFixtureSnapshot(
            context: context, macOSPermission: permission,
            connector: .init(installation: installation, accountAuthentication: authentication,
                             perBotGrant: connectorGrant, perActionApproval: connectorApproval),
            grants: grants, grantReviews: grantReviews, approvals: approvals, evidence: evidence
        )
    }

    private func expireReviews() {
        let now = clock.now()
        for index in grantReviews.indices where grantReviews[index].state == .pending
            && grantReviews[index].review.expiresAt <= now {
            grantReviews[index] = .init(review: grantReviews[index].review, state: .expired)
        }
        for index in approvals.indices where [.pending, .approved].contains(approvals[index].state)
            && approvals[index].review.expiresAt <= now {
            approvals[index] = .init(review: approvals[index].review, state: .expired)
        }
    }

    private func record(_ summary: String) {
        evidenceOrdinal += 1
        evidence.append(.init(id: evidenceOrdinal, timestamp: clock.now(), summary: summary))
        if evidence.count > 100 { evidence.removeFirst(evidence.count - 100) }
    }

    private func checkCapacity() throws {
        guard grantReviews.count + approvals.count < Self.maximumReviews else { throw TrustFixtureError.capacityReached }
    }

    private func nextID() throws -> UUID {
        let id = uuidGenerator.next()
        guard issuedIDs.insert(id).inserted else { throw TrustFixtureError.invalidInput }
        return id
    }

    private func fingerprint(_ review: FixtureGrantReview) throws -> String {
        try digest(grantReview(review, fingerprint: ""))
    }

    private func fingerprint(_ review: FixtureApprovalReview) throws -> String {
        try digest(approvalReview(review, fingerprint: ""))
    }

    private func digest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private func grantReview(_ review: FixtureGrantReview, fingerprint: String) -> FixtureGrantReview {
        FixtureGrantReview(
            id: review.id, context: review.context, capability: review.capability,
            scopeSummary: review.scopeSummary, effectSummary: review.effectSummary,
            generation: review.generation, createdAt: review.createdAt,
            expiresAt: review.expiresAt, fingerprint: fingerprint
        )
    }

    private func approvalReview(_ review: FixtureApprovalReview, fingerprint: String) -> FixtureApprovalReview {
        FixtureApprovalReview(
            id: review.id, context: review.context, proposal: review.proposal,
            grantID: review.grantID, grantGeneration: review.grantGeneration,
            scopeSummary: review.scopeSummary, effectSummary: review.effectSummary,
            createdAt: review.createdAt, expiresAt: review.expiresAt, fingerprint: fingerprint
        )
    }
}
