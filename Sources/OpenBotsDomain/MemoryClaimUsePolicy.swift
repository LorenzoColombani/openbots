import Foundation

/// Host-only verifier output. Deliberately not Codable: never construct this from
/// provider/artifact fields. Services must resolve durable receipts and current
/// authorization independently before invoking domain policy.
public struct MemoryClaimVerifiedEvidence: Equatable, Sendable {
    public enum Authority: String, Equatable, Sendable { case userAction, appVerifier }
    public let reference: MemoryClaimEvidenceReference
    public let claimID: MemoryClaimID
    public let scope: MemoryScope
    public let authority: Authority
    public let verifierID: String
    public let verifierVersion: UInt16
    public let checkedAt: Date
    public let validUntil: Date
    /// Copies of the same observation retain the same independence identity.
    public let independentEvidenceID: UUID

    public init(reference: MemoryClaimEvidenceReference, claimID: MemoryClaimID, scope: MemoryScope,
                authority: Authority, verifierID: String, verifierVersion: UInt16,
                checkedAt: Date, validUntil: Date, independentEvidenceID: UUID) {
        self.reference = reference; self.claimID = claimID; self.scope = scope
        self.authority = authority; self.verifierID = verifierID; self.verifierVersion = verifierVersion
        self.checkedAt = checkedAt; self.validUntil = validUntil; self.independentEvidenceID = independentEvidenceID
    }
}

public enum MemoryClaimEvidenceGate {
    /// Every retained receipt must resolve exactly; an omitted contradiction must
    /// not leave an apparently clean supporting subset.
    public static func validate(claim: MemoryClaim, scope: MemoryScope, at now: Date,
                                verifiedEvidence: [MemoryClaimVerifiedEvidence]) throws -> [MemoryClaimVerifiedEvidence] {
        try claim.validate(scope: scope)
        guard now.timeIntervalSince1970.isFinite, claim.hasKnownSemantics,
              !claim.provenance.isEmpty, !claim.assessment.evidence.isEmpty,
              verifiedEvidence.count <= 64,
              Set(verifiedEvidence.map { $0.reference.receiptID }).count == verifiedEvidence.count else {
            throw MemoryClaimValidationError.invalid("missing or unsupported evidence")
        }
        let subject = try MemoryClaimDigests.subject(claim, scope: scope)
        func resolve(_ reference: MemoryClaimEvidenceReference, requiresProvenance: Bool) throws -> MemoryClaimVerifiedEvidence {
            guard reference.subjectDigest == subject, reference.source.scope == scope,
                  !requiresProvenance || claim.provenance.contains(reference.source),
                  let receipt = verifiedEvidence.first(where: { $0.reference == reference }),
                  receipt.claimID == claim.id, receipt.scope == scope,
                  receipt.verifierVersion > 0, !receipt.verifierID.isEmpty,
                  receipt.checkedAt.timeIntervalSince1970.isFinite,
                  receipt.validUntil.timeIntervalSince1970.isFinite,
                  receipt.checkedAt <= now, now < receipt.validUntil,
                  let observedAt = reference.source.observedAt, observedAt <= receipt.checkedAt,
                  reference.source.contentDigest != nil else {
                throw MemoryClaimValidationError.invalid("unverified, stale or substituted evidence")
            }
            switch (receipt.authority, reference.source.kind) {
            case (.userAction, .userMessage), (.appVerifier, .appObservation), (.appVerifier, .sourceDocument):
                break
            default:
                throw MemoryClaimValidationError.invalid("model, echo or mismatched evidence authority")
            }
            return receipt
        }
        let retained = try claim.assessment.evidence.map { try resolve($0, requiresProvenance: true) }
        let retainedIDs = Set(retained.map { $0.reference.receiptID })
        // The trusted resolver supplies ALL known relevant contradictions, not
        // only references nominated by the proposal. Omitting one cannot promote.
        let additionalContradictions = verifiedEvidence.filter {
            $0.claimID == claim.id && $0.scope == scope && $0.reference.subjectDigest == subject
                && $0.reference.relation != .supports && !retainedIDs.contains($0.reference.receiptID)
        }
        return try retained + additionalContradictions.map { try resolve($0.reference, requiresProvenance: false) }
    }
}

public enum MemoryClaimUsePurpose: String, Codable, Equatable, Sendable {
    case conversation, sharing, consequential, ownerInspection, controlledBackup
}

public enum MemoryClaimFreshness: Equatable, Sendable {
    case current, stale, unknown, unresolvedNewerRevision
}

/// This is a snapshot of an independently verified grant, not a capability minted
/// by certainty. The effect/delivery boundary must revalidate it at action time.
public struct MemoryClaimExternalAuthorization: Equatable, Sendable {
    public let grantID: UUID
    public let reference: MemoryClaimReference
    public let purpose: MemoryClaimUsePurpose
    public let destination: String
    public let payloadDigest: String
    public let checkedAt: Date
    public let validUntil: Date
    public let qualificationPreserved: Bool
    public let consequentialPredicateVerified: Bool
    public init(grantID: UUID, reference: MemoryClaimReference, purpose: MemoryClaimUsePurpose,
                destination: String, payloadDigest: String, checkedAt: Date, validUntil: Date,
                qualificationPreserved: Bool, consequentialPredicateVerified: Bool = false) {
        self.grantID = grantID; self.reference = reference; self.purpose = purpose
        self.destination = destination; self.payloadDigest = payloadDigest
        self.checkedAt = checkedAt; self.validUntil = validUntil
        self.qualificationPreserved = qualificationPreserved
        self.consequentialPredicateVerified = consequentialPredicateVerified
    }
}

public struct MemoryClaimUseContext: Sendable {
    public let purpose: MemoryClaimUsePurpose
    public let teammateID: TeammateID?
    public let selectedProjectID: ProjectID?
    public let activeProjectMemberships: Set<ProjectID>
    public let currentReference: MemoryClaimReference?
    public let freshness: MemoryClaimFreshness
    public let now: Date
    public let isRelevant: Bool
    public let ownerInspectionAuthorized: Bool
    public let verifiedEvidence: [MemoryClaimVerifiedEvidence]
    public let destination: String?
    public let payloadDigest: String?
    public let externalAuthorization: MemoryClaimExternalAuthorization?
    public let conditionsSatisfied: Bool

    public init(purpose: MemoryClaimUsePurpose, now: Date, teammateID: TeammateID? = nil,
                selectedProjectID: ProjectID? = nil, activeProjectMemberships: Set<ProjectID> = [],
                currentReference: MemoryClaimReference? = nil, freshness: MemoryClaimFreshness = .unknown,
                isRelevant: Bool = false, ownerInspectionAuthorized: Bool = false,
                verifiedEvidence: [MemoryClaimVerifiedEvidence] = [], destination: String? = nil,
                payloadDigest: String? = nil, externalAuthorization: MemoryClaimExternalAuthorization? = nil,
                conditionsSatisfied: Bool = false) {
        self.purpose = purpose; self.now = now; self.teammateID = teammateID
        self.selectedProjectID = selectedProjectID; self.activeProjectMemberships = activeProjectMemberships
        self.currentReference = currentReference; self.freshness = freshness; self.isRelevant = isRelevant
        self.ownerInspectionAuthorized = ownerInspectionAuthorized; self.verifiedEvidence = verifiedEvidence
        self.destination = destination; self.payloadDigest = payloadDigest
        self.externalAuthorization = externalAuthorization; self.conditionsSatisfied = conditionsSatisfied
    }
}

public enum MemoryClaimUseDisposition: String, Codable, Equatable, Sendable { case allow, qualified, clarify, deny }
public enum MemoryClaimRequiredFraming: String, Codable, Equatable, Sendable {
    case none, unconfirmedPossibility, attributionAndHedge, reconsideration, historyOnly
}
public enum MemoryClaimUseReason: String, Codable, Equatable, Sendable {
    case scopeDenied, invalidBinding, unsupported, irrelevant, withdrawn, needsReview, disputed
    case stale, unresolvedNewerRevision, unverifiedEvidence, conflictingEvidence, unknownTime
    case conditionsUnverified, lowAssessment, requiresQualification, authorizationMissing, consequentialEvidenceRequired
    case ownerHistory
}
public struct MemoryClaimUseDecision: Codable, Equatable, Sendable {
    public let disposition: MemoryClaimUseDisposition
    public let reasons: [MemoryClaimUseReason]
    public let requiredFraming: MemoryClaimRequiredFraming
    public let dependency: MemoryClaimReference
    public init(disposition: MemoryClaimUseDisposition, reasons: [MemoryClaimUseReason],
                requiredFraming: MemoryClaimRequiredFraming, dependency: MemoryClaimReference) {
        self.disposition = disposition; self.reasons = reasons
        self.requiredFraming = requiredFraming; self.dependency = dependency
    }
}

public enum MemoryClaimUsePolicy {
    public static let version: UInt16 = 1

    public static func evaluate(claim: MemoryClaim, reference: MemoryClaimReference,
                                scope: MemoryScope, context: MemoryClaimUseContext) -> MemoryClaimUseDecision {
        func decision(_ disposition: MemoryClaimUseDisposition, _ reason: MemoryClaimUseReason? = nil,
                      _ framing: MemoryClaimRequiredFraming = .none) -> MemoryClaimUseDecision {
            MemoryClaimUseDecision(disposition: disposition, reasons: reason.map { [$0] } ?? [],
                                   requiredFraming: framing, dependency: reference)
        }
        let inspection = context.purpose == .ownerInspection || context.purpose == .controlledBackup
        // The broad legacy MemoryScope.user read helper is intentionally not used.
        let accessible: Bool
        if inspection {
            accessible = context.ownerInspectionAuthorized
        } else {
            switch scope {
            case .user: accessible = false
            case let .teammate(owner): accessible = owner == context.teammateID
            case let .project(project):
                accessible = context.teammateID != nil && project == context.selectedProjectID
                    && context.activeProjectMemberships.contains(project)
            }
        }
        guard accessible else { return decision(.deny, .scopeDenied) }
        do {
            try claim.validate(scope: scope); try MemoryClaimValidation.reference(reference)
            guard reference.claimID == claim.id,
                  reference.claimDigest == (try MemoryClaimDigests.claim(claim)),
                  reference.subjectDigest == (try MemoryClaimDigests.subject(claim, scope: scope)),
                  context.now.timeIntervalSince1970.isFinite else { return decision(.deny, .invalidBinding) }
        } catch { return decision(.deny, .invalidBinding) }
        if inspection { return decision(.qualified, .ownerHistory, .historyOnly) }
        guard claim.hasKnownSemantics else { return decision(.deny, .unsupported) }
        guard claim.validity != .withdrawn else { return decision(.deny, .withdrawn) }
        if context.purpose == .conversation && !context.isRelevant { return decision(.deny, .irrelevant) }
        func reconsider(_ reason: MemoryClaimUseReason) -> MemoryClaimUseDecision {
            context.purpose == .conversation ? decision(.clarify, reason, .reconsideration) : decision(.deny, reason)
        }
        guard context.currentReference == reference else { return reconsider(.invalidBinding) }
        if context.freshness == .unresolvedNewerRevision { return reconsider(.unresolvedNewerRevision) }
        guard context.freshness == .current else { return reconsider(.stale) }
        if claim.validity == .disputed { return reconsider(.disputed) }
        if claim.validity == .needsReview { return reconsider(.needsReview) }
        if let validFrom = claim.validFrom, context.now < validFrom { return reconsider(.stale) }
        if let validUntil = claim.validUntil, context.now >= validUntil { return reconsider(.stale) }
        if claim.conditions != nil && !context.conditionsSatisfied { return reconsider(.conditionsUnverified) }
        if claim.assessment.level == .unassessed || claim.assessment.level == .uncertain {
            return context.purpose == .conversation
                ? decision(.qualified, .lowAssessment, .unconfirmedPossibility) : decision(.deny, .lowAssessment)
        }
        guard let observedAt = claim.observedAt, observedAt <= context.now,
              let assessedAt = claim.assessment.assessedAt, assessedAt <= context.now,
              claim.assessment.assessor.kind != .unassessed else { return reconsider(.unknownTime) }
        let evidence: [MemoryClaimVerifiedEvidence]
        do { evidence = try MemoryClaimEvidenceGate.validate(claim: claim, scope: scope, at: context.now,
                                                            verifiedEvidence: context.verifiedEvidence) }
        catch { return reconsider(.unverifiedEvidence) }
        guard evidence.allSatisfy({ $0.reference.relation == .supports }) else { return reconsider(.conflictingEvidence) }
        let middle = claim.assessment.level == .supportedInference
        if context.purpose == .conversation {
            return middle ? decision(.qualified, .requiresQualification, .attributionAndHedge) : decision(.allow)
        }
        if context.purpose == .consequential && middle { return decision(.deny, .consequentialEvidenceRequired) }
        guard let grant = context.externalAuthorization,
              grant.reference == reference, grant.purpose == context.purpose,
              grant.destination == context.destination, !grant.destination.isEmpty,
              grant.payloadDigest == context.payloadDigest,
              (try? MemoryClaimValidation.digest(grant.payloadDigest)) != nil,
              grant.checkedAt.timeIntervalSince1970.isFinite, grant.validUntil.timeIntervalSince1970.isFinite,
              grant.checkedAt <= context.now, context.now < grant.validUntil,
              grant.qualificationPreserved else { return decision(.deny, .authorizationMissing) }
        if context.purpose == .consequential && !grant.consequentialPredicateVerified {
            return decision(.deny, .consequentialEvidenceRequired)
        }
        return middle ? decision(.qualified, .requiresQualification, .attributionAndHedge) : decision(.allow)
    }
}
