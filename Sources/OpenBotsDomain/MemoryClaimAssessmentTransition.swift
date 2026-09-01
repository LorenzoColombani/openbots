import Foundation

/// Pure admission rules. The service owns receipt issuance, actual user-lane
/// attribution, authorization and document CAS; this never accepts model confidence.
public enum MemoryClaimAssessmentTransition {
    public static func validate(previous: MemoryClaim?, previousReference: MemoryClaimReference?,
                                proposal: MemoryClaim, scope: MemoryScope, actor: MemoryClaimAssessor,
                                verifiedEvidence: [MemoryClaimVerifiedEvidence],
                                previousIndependentEvidenceIDs: Set<UUID> = [], at now: Date) throws {
        try proposal.validate(scope: scope)
        guard proposal.hasKnownSemantics, proposal.assessment.assessor == actor,
              actor.kind == .user || actor.kind == .app,
              let identity = actor.identity, !identity.isEmpty,
              now.timeIntervalSince1970.isFinite,
              let assessedAt = proposal.assessment.assessedAt, assessedAt <= now,
              proposal.observedAt.map({ $0 <= now }) ?? true,
              proposal.changes.allSatisfy({ $0.changedAt <= now }) else {
            throw MemoryClaimValidationError.invalid("assessment actor, policy or time")
        }
        if let previous {
            try previous.validate(scope: scope)
            guard let previousReference, previousReference.claimID == previous.id,
                  previousReference.claimDigest == (try MemoryClaimDigests.claim(previous)),
                  previousReference.subjectDigest == (try MemoryClaimDigests.subject(previous, scope: scope)),
                  let change = proposal.changes.first(where: { $0.previous == previousReference }),
                  change.changedAt == assessedAt,
                  previous.assessment.assessedAt.map({ $0 <= assessedAt }) ?? true else {
                throw MemoryClaimValidationError.invalid("exact predecessor and change required")
            }
            try MemoryClaimValidation.reference(previousReference)
            if previous.validity == .withdrawn && proposal.validity != .withdrawn {
                throw MemoryClaimValidationError.invalid("withdrawn claim cannot silently return; create a new related claim")
            }
            if proposal.id != previous.id && change.kind != .supersession {
                throw MemoryClaimValidationError.invalid("new proposition requires explicit supersession")
            }
            if !proposal.body.utf8.elementsEqual(previous.body.utf8), proposal.id == previous.id {
                throw MemoryClaimValidationError.invalid("changed proposition requires a distinct claim identity")
            }
            if proposal.validity == .withdrawn && change.kind != .withdrawal {
                throw MemoryClaimValidationError.invalid("withdrawal requires explicit change")
            }
            if previousReference.subjectDigest != (try MemoryClaimDigests.subject(proposal, scope: scope)),
               change.kind != .correction && change.kind != .supersession {
                throw MemoryClaimValidationError.invalid("changed proposition requires correction lineage")
            }
        } else {
            guard previousReference == nil, proposal.changes.isEmpty, proposal.validity != .withdrawn else {
                throw MemoryClaimValidationError.invalid("initial claim cannot invent change history")
            }
            // Retention of an unverified assertion is not evidence-based promotion.
            if proposal.assessment.level == .unassessed || proposal.assessment.level == .uncertain {
                guard proposal.assessment.evidence.isEmpty else {
                    _ = try MemoryClaimEvidenceGate.validate(claim: proposal, scope: scope, at: now,
                                                            verifiedEvidence: verifiedEvidence)
                    return
                }
                return
            }
        }
        let receipts = try MemoryClaimEvidenceGate.validate(claim: proposal, scope: scope, at: now,
                                                           verifiedEvidence: verifiedEvidence)
        guard receipts.contains(where: { receipt in
            (actor.kind == .user && receipt.authority == .userAction)
                || (actor.kind == .app && receipt.authority == .appVerifier)
        }) else { throw MemoryClaimValidationError.invalid("assessor lacks matching evidence authority") }
        let supported = proposal.assessment.level == .supportedInference || proposal.assessment.level == .confirmed
        if supported && proposal.validity == .active {
            guard receipts.allSatisfy({ $0.reference.relation == .supports }),
                  proposal.observedAt != nil,
                  proposal.validUntil.map({ now < $0 }) ?? true,
                  proposal.validFrom.map({ $0 <= now }) ?? true else {
                throw MemoryClaimValidationError.invalid("current support without unresolved contradiction required")
            }
        }
        let oldRank = previous.map { rank($0.assessment.level) } ?? 0
        if rank(proposal.assessment.level) > oldRank {
            guard previous?.assessment.evidence.isEmpty != false || !previousIndependentEvidenceIDs.isEmpty else {
                throw MemoryClaimValidationError.invalid("prior evidence independence must be resolved before promotion")
            }
            let priorSourceIDs = Set(previous?.assessment.evidence.map { $0.source.id } ?? [])
            guard receipts.contains(where: {
                $0.reference.relation == .supports
                    && !previousIndependentEvidenceIDs.contains($0.independentEvidenceID)
                    && !priorSourceIDs.contains($0.reference.source.id)
                    && $0.reference.source.derivedFrom.isEmpty
            }) else { throw MemoryClaimValidationError.invalid("promotion needs new independent real evidence") }
        }
    }

    private static func rank(_ level: MemoryClaimAssessmentLevel) -> Int {
        switch level {
        case .unassessed, .unknown: 0
        case .uncertain: 1
        case .supportedInference: 2
        case .confirmed: 3
        }
    }
}
