import Foundation
import Testing
@testable import OpenBotsDomain

@Test("Claim hashes retain exact body bytes and bind time, scope, evidence and assessment")
func memoryClaimHashBindsCompleteStatement() throws {
    let fixture = MemoryClaimTestFixture()
    let first = try fixture.make(body: "  Cafe\u{301}\nnot always\n")
    let second = try fixture.make(body: "  Café\nnot always\n", source: first.claim.provenance[0])
    #expect(first.claim.body.utf8.elementsEqual("  Cafe\u{301}\nnot always\n".utf8))
    #expect(try MemoryClaimDigests.subject(first.claim, scope: fixture.scope)
            != MemoryClaimDigests.subject(second.claim, scope: fixture.scope))
    let qualified = try fixture.make(body: first.claim.body, source: first.claim.provenance[0], conditions: "Only on weekdays")
    #expect(try MemoryClaimDigests.subject(first.claim, scope: fixture.scope)
            != MemoryClaimDigests.subject(qualified.claim, scope: fixture.scope))
    let lower = try fixture.make(level: .uncertain, body: first.claim.body, source: first.claim.provenance[0])
    #expect(try MemoryClaimDigests.claim(first.claim) != MemoryClaimDigests.claim(lower.claim))
    #expect(try MemoryClaimDigests.subject(first.claim, scope: fixture.scope)
            != MemoryClaimDigests.subject(first.claim, scope: .user))
}

@Test("Artifact validation rejects duplicate identities and cross-scope provenance")
func memoryClaimArtifactRejectsAmbiguousOwnership() throws {
    let fixture = MemoryClaimTestFixture()
    let value = try fixture.make()
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: 1,
                                scope: fixture.scope, claims: [value.claim, value.claim]).validate()
    }
    #expect(throws: MemoryClaimValidationError.self) { try value.claim.validate(scope: .user) }
}

@Test("Promotion requires new independently verified evidence and exact change lineage")
func memoryClaimPromotionCannotCountRepetition() throws {
    let fixture = MemoryClaimTestFixture()
    let prior = try fixture.make(level: .uncertain)
    let priorRef = try fixture.reference(prior.claim)
    let change = MemoryClaimChange(kind: .reassessment, previous: priorRef, reason: "New observation",
                                   changedAt: fixture.now)
    let repeatProposal = try fixture.make(source: prior.claim.provenance[0], changes: [change])
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: prior.claim, previousReference: priorRef,
            proposal: repeatProposal.claim, scope: fixture.scope, actor: repeatProposal.claim.assessment.assessor,
            verifiedEvidence: [repeatProposal.receipt],
            previousIndependentEvidenceIDs: [repeatProposal.receipt.independentEvidenceID], at: fixture.now)
    }
    let newEvidence = try fixture.make(changes: [change])
    try MemoryClaimAssessmentTransition.validate(previous: prior.claim, previousReference: priorRef,
        proposal: newEvidence.claim, scope: fixture.scope, actor: newEvidence.claim.assessment.assessor,
        verifiedEvidence: [newEvidence.receipt], previousIndependentEvidenceIDs: [prior.receipt.independentEvidenceID],
        at: fixture.now)
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: prior.claim, previousReference: priorRef,
            proposal: newEvidence.claim, scope: fixture.scope, actor: newEvidence.claim.assessment.assessor,
            verifiedEvidence: [], at: fixture.now)
    }
}

@Test("Real user reassessment is accepted but actor spoofing and echo evidence are refused")
func memoryClaimTransitionChecksEvidenceAuthority() throws {
    let fixture = MemoryClaimTestFixture()
    let user = try fixture.make(sourceKind: .userMessage, actorKind: .user, authority: .userAction)
    try MemoryClaimAssessmentTransition.validate(previous: nil, previousReference: nil, proposal: user.claim,
        scope: fixture.scope, actor: user.claim.assessment.assessor, verifiedEvidence: [user.receipt], at: fixture.now)
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: nil, previousReference: nil, proposal: user.claim,
            scope: fixture.scope, actor: MemoryClaimAssessor(kind: .app, identity: "pretending"),
            verifiedEvidence: [user.receipt], at: fixture.now)
    }
    let echo = try fixture.make(sourceKind: .modelEcho)
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: nil, previousReference: nil, proposal: echo.claim,
            scope: fixture.scope, actor: echo.claim.assessment.assessor, verifiedEvidence: [echo.receipt], at: fixture.now)
    }
}

@Test("Withdrawal retains history and cannot reactivate through a later assessment")
func memoryClaimWithdrawalIsNotErasureOrFallback() throws {
    let fixture = MemoryClaimTestFixture()
    let prior = try fixture.make()
    let priorRef = try fixture.reference(prior.claim)
    let change = MemoryClaimChange(kind: .withdrawal, previous: priorRef, reason: "No longer applies",
                                   changedAt: fixture.now)
    let withdrawn = try fixture.make(level: .uncertain, validity: .withdrawn, relation: .invalidates, changes: [change])
    try MemoryClaimAssessmentTransition.validate(previous: prior.claim, previousReference: priorRef,
        proposal: withdrawn.claim, scope: fixture.scope, actor: withdrawn.claim.assessment.assessor,
        verifiedEvidence: [withdrawn.receipt], at: fixture.now)
    #expect(withdrawn.claim.changes[0].previous == priorRef)
    let withdrawnRef = try fixture.reference(withdrawn.claim, revision: 2)
    let revival = try fixture.make(changes: [MemoryClaimChange(kind: .reassessment, previous: withdrawnRef,
                                                               reason: "Again", changedAt: fixture.now)])
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: withdrawn.claim, previousReference: withdrawnRef,
            proposal: revival.claim, scope: fixture.scope, actor: revival.claim.assessment.assessor,
            verifiedEvidence: [revival.receipt], at: fixture.now)
    }
}

@Test("A changed proposition cannot reuse an existing claim identity even with valid correction evidence")
func memoryClaimReplacementRequiresDistinctIdentity() throws {
    let fixture = MemoryClaimTestFixture()
    let prior = try fixture.make()
    let reference = try fixture.reference(prior.claim)
    let replacement = try fixture.make(body: "My synthetic project is named Orchard.",
        changes: [.init(kind: .correction, previous: reference,
                        reason: "Explicit replacement", changedAt: fixture.now)])
    #expect(throws: MemoryClaimValidationError.self) {
        try MemoryClaimAssessmentTransition.validate(previous: prior.claim, previousReference: reference,
            proposal: replacement.claim, scope: fixture.scope, actor: replacement.claim.assessment.assessor,
            verifiedEvidence: [replacement.receipt], at: fixture.now)
    }
}

struct MemoryClaimTestFixture {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let teammateID = TeammateID(UUID())
    let claimID = MemoryClaimID(UUID())
    var scope: MemoryScope { .teammate(teammateID) }

    func make(level: MemoryClaimAssessmentLevel = .confirmed, body: String = "Quiet venues are preferred.",
              source: MemoryClaimSourceReference? = nil, sourceKind: MemoryClaimSourceKind = .appObservation,
              actorKind: MemoryClaimAssessor.Kind = .app, authority: MemoryClaimVerifiedEvidence.Authority = .appVerifier,
              validity: MemoryClaimValidity = .active, relation: MemoryClaimEvidenceRelation = .supports,
              conditions: String? = nil, changes: [MemoryClaimChange] = []) throws
        -> (claim: MemoryClaim, receipt: MemoryClaimVerifiedEvidence) {
        let source = source ?? MemoryClaimSourceReference(id: UUID(), kind: sourceKind, sourceID: UUID().uuidString,
            sourceRevision: 1, contentDigest: String(repeating: "a", count: 64),
            observedAt: now.addingTimeInterval(-10), scope: scope)
        let assessor = MemoryClaimAssessor(kind: actorKind, identity: "test-assessor")
        let unbound = MemoryClaim(id: claimID, body: body,
            assessment: MemoryClaimAssessment(level: level, basis: "Observed bounded preference", assessor: assessor,
                                               assessedAt: now), provenance: [source],
            observedAt: now.addingTimeInterval(-10), conditions: conditions, validity: validity, changes: changes)
        let evidence = MemoryClaimEvidenceReference(receiptID: UUID(), receiptDigest: String(repeating: "b", count: 64),
            source: source, relation: relation, subjectDigest: try MemoryClaimDigests.subject(unbound, scope: scope))
        let claim = MemoryClaim(id: claimID, body: body,
            assessment: MemoryClaimAssessment(level: level, basis: unbound.assessment.basis, assessor: assessor,
                                               assessedAt: now, evidence: [evidence]), provenance: [source],
            observedAt: unbound.observedAt, conditions: conditions, validity: validity, changes: changes)
        let receipt = MemoryClaimVerifiedEvidence(reference: evidence, claimID: claimID, scope: scope,
            authority: authority, verifierID: "fixture", verifierVersion: 1, checkedAt: now,
            validUntil: now.addingTimeInterval(60), independentEvidenceID: source.id)
        return (claim, receipt)
    }

    func reference(_ claim: MemoryClaim, revision: UInt64 = 1) throws -> MemoryClaimReference {
        MemoryClaimReference(documentID: MemoryDocumentID(UUID()), documentRevision: revision,
            contentDigest: String(repeating: "c", count: 64), claimID: claim.id,
            claimDigest: try MemoryClaimDigests.claim(claim), subjectDigest: try MemoryClaimDigests.subject(claim, scope: scope))
    }
}
