import Foundation
import Testing
@testable import OpenBotsDomain

@Test("Only current verified confirmation permits ordinary scoped conversation")
func memoryClaimPolicyRequiresHostEvidenceAndCurrentBinding() throws {
    let fixture = MemoryClaimTestFixture()
    let value = try fixture.make()
    let reference = try fixture.reference(value.claim)
    let permitted = memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt])
    #expect(permitted.disposition == .allow)
    #expect(permitted.requiredFraming == .none)
    #expect(memoryClaimDecision(fixture, value.claim, reference).disposition == .clarify)
    #expect(memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt],
                                freshness: .unresolvedNewerRevision).disposition == .clarify)
    #expect(memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt],
                                at: fixture.now.addingTimeInterval(61)).disposition == .clarify)
    let substituted = try fixture.make(body: "Everyone prefers loud venues.")
    #expect(memoryClaimDecision(fixture, substituted.claim, reference, receipts: [value.receipt]).disposition == .deny)
}

@Test("Low and middle assessments require different framing and cannot drive consequences")
func memoryClaimPolicyQualificationMatrix() throws {
    let fixture = MemoryClaimTestFixture()
    for level in [MemoryClaimAssessmentLevel.unassessed, .uncertain, .supportedInference] {
        let value = try fixture.make(level: level)
        let reference = try fixture.reference(value.claim)
        let answer = memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt])
        #expect(answer.disposition == .qualified)
        #expect(answer.requiredFraming == (level == .supportedInference ? .attributionAndHedge : .unconfirmedPossibility))
        #expect(memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt],
                                    purpose: .consequential).disposition == .deny)
        #expect(memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt],
                                    purpose: .sharing).disposition == .deny)
    }
}

@Test("Unknown and missing provenance cannot authorize confirmation; global memory is not bot context")
func memoryClaimPolicyScopeAndProvenanceAreIndependent() throws {
    let fixture = MemoryClaimTestFixture()
    let unknown = try fixture.make(sourceKind: .unknown("future-source"))
    #expect(memoryClaimDecision(fixture, unknown.claim, try fixture.reference(unknown.claim),
                                receipts: [unknown.receipt]).disposition == .deny)
    let value = try fixture.make()
    let missing = MemoryClaim(id: value.claim.id, body: value.claim.body, assessment: value.claim.assessment,
                             provenance: [], observedAt: value.claim.observedAt)
    #expect(memoryClaimDecision(fixture, missing, try fixture.reference(missing),
                                receipts: [value.receipt]).disposition == .clarify)
    let low = MemoryClaim(id: fixture.claimID, body: "Possibly useful",
        assessment: MemoryClaimAssessment(level: .unassessed, basis: "", assessor: .init(kind: .unassessed)), provenance: [])
    let globalRef = MemoryClaimReference(documentID: MemoryDocumentID(UUID()), documentRevision: 1,
        contentDigest: String(repeating: "a", count: 64), claimID: low.id,
        claimDigest: try MemoryClaimDigests.claim(low), subjectDigest: try MemoryClaimDigests.subject(low, scope: .user))
    #expect(MemoryClaimUsePolicy.evaluate(claim: low, reference: globalRef, scope: .user,
        context: .init(purpose: .conversation, now: fixture.now, teammateID: fixture.teammateID,
                       currentReference: globalRef, freshness: .current, isRelevant: true)).disposition == .deny)
    #expect(MemoryClaimUsePolicy.evaluate(claim: low, reference: globalRef, scope: .user,
        context: .init(purpose: .ownerInspection, now: fixture.now, ownerInspectionAuthorized: true))
        .requiredFraming == .historyOnly)
}

@Test("Conflicts, withdrawals and conditions restrict use without deleting records")
func memoryClaimPolicyRestrictsReconsiderationStates() throws {
    let fixture = MemoryClaimTestFixture()
    for validity in [MemoryClaimValidity.needsReview, .disputed, .withdrawn] {
        let value = try fixture.make(validity: validity)
        let reference = try fixture.reference(value.claim)
        let answer = memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt])
        #expect(answer.disposition == (validity == .withdrawn ? .deny : .clarify))
        #expect(memoryClaimDecision(fixture, value.claim, reference, receipts: [value.receipt],
                                    purpose: .sharing).disposition == .deny)
        #expect(MemoryClaimUsePolicy.evaluate(claim: value.claim, reference: reference, scope: fixture.scope,
            context: .init(purpose: .ownerInspection, now: fixture.now, ownerInspectionAuthorized: true))
            .requiredFraming == .historyOnly)
    }
    let contradictory = try fixture.make(relation: .contradicts)
    #expect(memoryClaimDecision(fixture, contradictory.claim, try fixture.reference(contradictory.claim),
                                receipts: [contradictory.receipt]).reasons == [.conflictingEvidence])
    let conditional = try fixture.make(conditions: "Weekdays only")
    #expect(memoryClaimDecision(fixture, conditional.claim, try fixture.reference(conditional.claim),
                                receipts: [conditional.receipt]).reasons == [.conditionsUnverified])
}

@Test("A proposal cannot omit a contradiction supplied by the trusted evidence resolver")
func memoryClaimPolicyDoesNotIgnoreUnlistedContradiction() throws {
    let fixture = MemoryClaimTestFixture()
    let claim = try fixture.make()
    let omitted = try fixture.make(relation: .contradicts)
    let decision = memoryClaimDecision(fixture, claim.claim, try fixture.reference(claim.claim),
                                       receipts: [claim.receipt, omitted.receipt])
    #expect(decision.disposition == .clarify)
    #expect(decision.reasons == [.conflictingEvidence])
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: nil, previousReference: nil, proposal: claim.claim,
            scope: fixture.scope, actor: claim.claim.assessment.assessor,
            verifiedEvidence: [claim.receipt, omitted.receipt], at: fixture.now)
    }
}

@Test("Sharing binds exact payload, destination, qualification and current grant independently of confidence")
func memoryClaimPolicyExternalGrantCannotBeReused() throws {
    let fixture = MemoryClaimTestFixture()
    let value = try fixture.make(level: .supportedInference)
    let reference = try fixture.reference(value.claim)
    let payload = String(repeating: "d", count: 64)
    let grant = MemoryClaimExternalAuthorization(grantID: UUID(), reference: reference, purpose: .sharing,
        destination: "approved-destination", payloadDigest: payload, checkedAt: fixture.now,
        validUntil: fixture.now.addingTimeInterval(30), qualificationPreserved: true)
    func check(_ destination: String, _ digest: String) -> MemoryClaimUseDecision {
        MemoryClaimUsePolicy.evaluate(claim: value.claim, reference: reference, scope: fixture.scope,
            context: .init(purpose: .sharing, now: fixture.now, teammateID: fixture.teammateID,
                currentReference: reference, freshness: .current, verifiedEvidence: [value.receipt],
                destination: destination, payloadDigest: digest, externalAuthorization: grant))
    }
    #expect(check("approved-destination", payload).requiredFraming == .attributionAndHedge)
    #expect(check("another-destination", payload).disposition == .deny)
    #expect(check("approved-destination", String(repeating: "e", count: 64)).disposition == .deny)
}

private func memoryClaimDecision(_ fixture: MemoryClaimTestFixture, _ claim: MemoryClaim,
                                 _ reference: MemoryClaimReference,
                                 receipts: [MemoryClaimVerifiedEvidence] = [],
                                 purpose: MemoryClaimUsePurpose = .conversation,
                                 freshness: MemoryClaimFreshness = .current, at: Date? = nil) -> MemoryClaimUseDecision {
    MemoryClaimUsePolicy.evaluate(claim: claim, reference: reference, scope: fixture.scope,
        context: .init(purpose: purpose, now: at ?? fixture.now, teammateID: fixture.teammateID,
                       currentReference: reference, freshness: freshness, isRelevant: true, verifiedEvidence: receipts))
}
