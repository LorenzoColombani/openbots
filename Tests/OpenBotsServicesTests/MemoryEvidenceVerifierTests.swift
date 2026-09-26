import Foundation
import Testing
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsServices

@Test("Registered user evidence comes from the exact durable user lane, not the artifact")
func memoryEvidenceVerifierBindsDurableUserCommand() async throws {
    let fixture = try MemoryEvidenceFixture()
    let message = try fixture.message("I confirm from first-hand knowledge: I prefer quiet places.")
    await fixture.store.put(message)
    let claim = try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let artifact = fixture.artifact([claim])
    let verified = try await fixture.verifier.verify(artifact: artifact, predecessor: nil,
        actor: .user(messageID: message.id), authority: fixture.context, at: fixture.now)
    #expect(verified.verified.count == 1)
    #expect(verified.verified[0].authority == .userAction)
    #expect(verified.verified[0].independentEvidenceID == message.id.rawValue)
    #expect(verified.userMessages[0].contentDigest == MemoryClaimDigests.bytes(Data("I confirm from first-hand knowledge: I prefer quiet places.".utf8)))
    try MemoryClaimAssessmentTransition.validate(previous: nil, previousReference: nil, proposal: claim,
        scope: fixture.scope, actor: claim.assessment.assessor, verifiedEvidence: verified.verified, at: fixture.now)
}

@Test("Quoted commands, hypotheticals, questions and model-authored commands cannot become user authority")
func memoryEvidenceVerifierRejectsFalseUserIntent() async throws {
    let fixture = try MemoryEvidenceFixture()
    for text in ["\"I confirm from first-hand knowledge: I live in Lyon.\"",
                 "If I said I confirm from first-hand knowledge: I live in Lyon.",
                 "Should I confirm from first-hand knowledge: I live in Lyon?",
                 "A bot said: I confirm from first-hand knowledge: I live in Lyon."] {
        let message = try fixture.message(text)
        await fixture.store.replaceMessages([message])
        await #expect(throws: MemoryEvidenceVerifierError.self) {
            _ = try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
                scope: fixture.scope, authority: fixture.context, at: fixture.now)
        }
    }
    let model = try fixture.message("I confirm from first-hand knowledge: I live in Lyon.", author: .teammate(fixture.teammate.id))
    await fixture.store.replaceMessages([model])
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.userProposal(messageID: model.id, claimID: MemoryClaimID(UUID()),
            scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
}

@Test("Latest-message admission prevents replay while retained evidence can recheck an older source")
func memoryEvidenceVerifierSeparatesActorFromRetainedSource() async throws {
    let fixture = try MemoryEvidenceFixture()
    let message = try fixture.message("I confirm from first-hand knowledge: I prefer quiet places.")
    await fixture.store.put(message)
    let claim = try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let later = try fixture.message("A different current request.", sequence: 2)
    await fixture.store.put(later)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.userProposal(messageID: message.id, claimID: claim.id,
            scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
    let refreshedAt = fixture.now.addingTimeInterval(86_400)
    let refreshed = try await fixture.verifier.verifyRetained(claim: claim, scope: fixture.scope,
        authority: fixture.context, at: refreshedAt)
    #expect(refreshed[0].checkedAt == refreshedAt)
    #expect(refreshed[0].validUntil == refreshedAt.addingTimeInterval(900))
    #expect(refreshed[0].reference.source.observedAt == message.createdAt)
    #expect(refreshed[0].reference == claim.assessment.evidence[0])
}

@Test("Forged receipt hashes and invented provenance cannot pass registered verification")
func memoryEvidenceVerifierRejectsForgedMetadata() async throws {
    let fixture = try MemoryEvidenceFixture()
    let message = try fixture.message("I confirm from first-hand knowledge: I prefer quiet places.")
    await fixture.store.put(message)
    let claim = try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let reference = claim.assessment.evidence[0]
    let forged = MemoryClaimEvidenceReference(receiptID: reference.receiptID,
        receiptDigest: String(repeating: "f", count: 64), source: reference.source,
        relation: reference.relation, subjectDigest: reference.subjectDigest)
    let altered = MemoryClaim(id: claim.id, body: claim.body,
        assessment: .init(level: claim.assessment.level, basis: claim.assessment.basis,
            assessor: claim.assessment.assessor, assessedAt: claim.assessment.assessedAt, evidence: [forged]),
        provenance: claim.provenance, observedAt: claim.observedAt)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.verify(artifact: fixture.artifact([altered]), predecessor: nil,
            actor: .user(messageID: message.id), authority: fixture.context, at: fixture.now)
    }
    let forgedBasis = MemoryClaim(id: claim.id, body: claim.body,
        assessment: .init(level: .confirmed, basis: "Independent experiments proved this.",
            assessor: claim.assessment.assessor, assessedAt: claim.assessment.assessedAt, evidence: [reference]),
        provenance: claim.provenance, observedAt: claim.observedAt)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.verifyRetained(claim: forgedBasis, scope: fixture.scope,
            authority: fixture.context, at: fixture.now)
    }
}

@Test("Registered app observation proves only the current stored name and fails on source revision change")
func memoryEvidenceVerifierChecksNarrowAppPredicate() async throws {
    let fixture = try MemoryEvidenceFixture()
    let claim = try await fixture.verifier.savedTeammateNameProposal(claimID: MemoryClaimID(UUID()),
        authority: fixture.context, at: fixture.now)
    #expect(claim.body == (try MemoryEvidenceVerifier.savedNameStatement(fixture.teammate.profile.displayName)))
    let evidence = try await fixture.verifier.verify(artifact: fixture.artifact([claim]), predecessor: nil,
        actor: .app(verifierID: MemoryEvidenceVerifier.savedNameRegistryID), authority: fixture.context, at: fixture.now)
    #expect(evidence.verified[0].authority == .appVerifier)
    #expect(evidence.userMessages.isEmpty)
    let changedBody = MemoryClaim(id: claim.id, body: "This bot is a trustworthy expert.", assessment: claim.assessment,
                                 provenance: claim.provenance, observedAt: claim.observedAt)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.verifyRetained(claim: changedBody, scope: fixture.scope,
            authority: fixture.context, at: fixture.now)
    }
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.verify(artifact: fixture.artifact([claim]), predecessor: nil,
            actor: .app(verifierID: "provider-chosen-verifier"), authority: fixture.context, at: fixture.now)
    }
    var changed = fixture.teammate
    changed.profile = try changed.profile.revised(displayName: "Changed")
    await fixture.store.put(changed)
    await #expect(throws: ReadContextError.self) {
        _ = try await fixture.verifier.verifyRetained(claim: claim, scope: fixture.scope,
            authority: fixture.context, at: fixture.now)
    }
}

@Test("A changed saved profile produces real app evidence that demotes the earlier proposition")
func memoryEvidenceVerifierAppDemotesOnContradictoryObservation() async throws {
    let fixture = try MemoryEvidenceFixture()
    let first = try await fixture.verifier.savedTeammateNameProposal(claimID: MemoryClaimID(UUID()),
        authority: fixture.context, at: fixture.now)
    let prior = fixture.artifact([first])
    let bytes = try MemoryClaimCodec().encode(prior)
    let reference = try MemoryClaimCodec().reference(for: first, in: prior, contentDigest: MemoryClaimDigests.bytes(bytes))
    var changed = fixture.teammate
    changed.profile = try changed.profile.revised(displayName: "A different saved name")
    changed.updatedAt = fixture.now.addingTimeInterval(5)
    await fixture.store.put(changed)
    let authority = ReadContextReceipt(conversationID: fixture.context.conversationID, teammateID: changed.id,
        profileRevision: 2, contextRevision: fixture.context.contextRevision, selectedProjectID: nil,
        selectedTeamID: nil, participantJoinedAt: fixture.context.participantJoinedAt,
        projectMembershipJoinedAt: nil, teamMembershipJoinedAt: nil, messages: [], memoryDocuments: [])
    let now = fixture.now.addingTimeInterval(10)
    let demoted = try await fixture.verifier.reconsiderSavedNameProposal(previous: first, previousReference: reference,
        authority: authority, at: now)
    let evidence = try await fixture.verifier.verify(artifact: fixture.artifact([demoted], revision: 2), predecessor: prior,
        actor: .app(verifierID: MemoryEvidenceVerifier.savedNameRegistryID), authority: authority, at: now)
    try MemoryClaimAssessmentTransition.validate(previous: first, previousReference: reference, proposal: demoted,
        scope: fixture.scope, actor: demoted.assessment.assessor, verifiedEvidence: evidence.verified,
        previousIndependentEvidenceIDs: evidence.previousIndependentEvidenceIDs, at: now)
    #expect(demoted.id == first.id)
    #expect(demoted.body.utf8.elementsEqual(first.body.utf8))
    #expect(demoted.assessment.level == .uncertain)
    #expect(demoted.validity == .disputed)
    #expect(evidence.verified[0].reference.relation == .contradicts)
    #expect(evidence.verified[0].reference.source.sourceRevision == 2)
    #expect(demoted.changes[0].previous == reference)
}

@Test("Different corrected propositions get a deterministic successor while the original remains withdrawn history")
func memoryEvidenceVerifierBindsCorrectionAndWithdrawal() async throws {
    let fixture = try MemoryEvidenceFixture()
    let firstMessage = try fixture.message("Remember as uncertain: I live in Paris.")
    await fixture.store.put(firstMessage)
    let first = try await fixture.verifier.userProposal(messageID: firstMessage.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let prior = fixture.artifact([first])
    let bytes = try MemoryClaimCodec().encode(prior)
    let reference = try MemoryClaimCodec().reference(for: first, in: prior, contentDigest: MemoryClaimDigests.bytes(bytes))
    let correction = try fixture.message("Correct from first-hand knowledge to: I live in Lyon.", sequence: 2)
    await fixture.store.put(correction)
    do {
        _ = try await fixture.verifier.userProposal(messageID: correction.id, claimID: first.id,
            scope: fixture.scope, previous: first, previousReference: reference, authority: fixture.context, at: fixture.now)
        Issue.record("A different proposition reused the prior identity")
    } catch let error as MemoryEvidenceVerifierError { #expect(error == .ambiguousIntent) }
    let pair = try await fixture.verifier.userCorrectionProposal(messageID: correction.id, previous: first,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let corrected = pair.successor
    let revised = fixture.artifact([pair.withdrawnPredecessor, corrected], revision: 2)
    let evidence = try await fixture.verifier.verify(artifact: revised, predecessor: prior,
        actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
    try MemoryClaimAssessmentTransition.validate(previous: first, previousReference: reference, proposal: corrected,
        scope: fixture.scope, actor: corrected.assessment.assessor,
        verifiedEvidence: evidence.verified.filter { $0.claimID == corrected.id },
        previousIndependentEvidenceIDs: evidence.previousIndependentEvidenceIDs, at: fixture.now)
    try MemoryClaimAssessmentTransition.validate(previous: first, previousReference: reference, proposal: pair.withdrawnPredecessor,
        scope: fixture.scope, actor: pair.withdrawnPredecessor.assessment.assessor,
        verifiedEvidence: evidence.verified.filter { $0.claimID == first.id },
        previousIndependentEvidenceIDs: evidence.previousIndependentEvidenceIDs, at: fixture.now)
    #expect(corrected.id != first.id)
    #expect(pair.withdrawnPredecessor.id == first.id && pair.withdrawnPredecessor.body == first.body)
    #expect(pair.withdrawnPredecessor.validity == .withdrawn)
    #expect(pair.withdrawnPredecessor.changes[0].kind == .withdrawal)
    #expect(pair.withdrawnPredecessor.observedAt == first.observedAt)
    #expect(corrected.changes[0].kind == .supersession)
    #expect(corrected.changes[0].previous == reference)
    #expect(corrected.body == "I live in Lyon.")
    #expect(try await fixture.verifier.userCorrectionProposal(messageID: correction.id, previous: first,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now) == pair)
    // Omitting the old-claim tombstone cannot turn a replacement into an
    // ordinary single-claim edit, even though the source message is real.
    do {
        _ = try await fixture.verifier.verify(artifact: fixture.artifact([first, corrected], revision: 2), predecessor: prior,
            actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
        Issue.record("A successor was accepted without withdrawing its predecessor")
    } catch let error as MemoryEvidenceVerifierError { #expect(error == .ambiguousIntent) }
    do {
        _ = try await fixture.verifier.verify(artifact: fixture.artifact([pair.withdrawnPredecessor], revision: 2), predecessor: prior,
            actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
        Issue.record("Replacement withdrawal was accepted without its successor")
    } catch let error as MemoryEvidenceVerifierError { #expect(error == .ambiguousIntent) }
    let correctedBytes = try MemoryClaimCodec().encode(revised)
    let correctedRef = try MemoryClaimCodec().reference(for: corrected, in: revised,
        contentDigest: MemoryClaimDigests.bytes(correctedBytes))
    let withdrawal = try fixture.message("Withdraw this memory: I live in Lyon.", sequence: 3)
    await fixture.store.put(withdrawal)
    let withdrawn = try await fixture.verifier.userProposal(messageID: withdrawal.id, claimID: corrected.id,
        scope: fixture.scope, previous: corrected, previousReference: correctedRef, authority: fixture.context, at: fixture.now)
    #expect(withdrawn.validity == .withdrawn)
    #expect(withdrawn.body == corrected.body)
    #expect(withdrawn.changes[0].kind == .withdrawal)
    #expect(withdrawn.assessment.evidence[0].relation == .invalidates)
    let retained = try await fixture.verifier.verifyRetained(claim: pair.withdrawnPredecessor,
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    #expect(retained.first?.reference.relation == .invalidates)
}

@Test("A correction attesting identical bytes keeps identity and withdrawn predecessors cannot be reused")
func memoryEvidenceSameBodyCorrectionKeepsIdentity() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that I prefer tea.")
    await fixture.store.put(initial)
    let first = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let prior = fixture.artifact([first])
    let reference = try MemoryClaimCodec().reference(for: first, in: prior,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(prior)))
    let correction = try fixture.message("Correct from first-hand knowledge to: I prefer tea.", sequence: 2)
    await fixture.store.put(correction)
    let reassessed = try await fixture.verifier.userProposal(messageID: correction.id, claimID: first.id,
        scope: fixture.scope, previous: first, previousReference: reference, authority: fixture.context, at: fixture.now)
    #expect(reassessed.id == first.id && reassessed.body == first.body)
    #expect(reassessed.assessment.level == .confirmed)
    let evidence = try await fixture.verifier.verify(artifact: fixture.artifact([reassessed], revision: 2), predecessor: prior,
        actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
    #expect(evidence.verified.count == 1)
    let replacement = try fixture.message("Correct from first-hand knowledge to: I prefer coffee.", sequence: 3)
    await fixture.store.put(replacement)
    let pair = try await fixture.verifier.userCorrectionProposal(messageID: replacement.id, previous: first,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let replacedArtifact = fixture.artifact([pair.withdrawnPredecessor, pair.successor], revision: 2)
    let withdrawnReference = try MemoryClaimCodec().reference(for: pair.withdrawnPredecessor, in: replacedArtifact,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(replacedArtifact)))
    do {
        _ = try await fixture.verifier.userCorrectionProposal(messageID: replacement.id, previous: pair.withdrawnPredecessor,
            previousReference: withdrawnReference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
        Issue.record("A withdrawn identity was accepted as a replacement target")
    } catch let error as MemoryEvidenceVerifierError { #expect(error == .ambiguousIntent) }
}

@Test("Conversational recognition requires a whole explicit command, not quotes, questions or hypothetical instructions")
func memoryEvidenceConversationalRecognitionIsBounded() {
    for text in ["Remember that I might move to Lyon.", "Please forget that I live in Paris.",
                 "Forget that I live in Paris.", "I no longer live in Paris."] {
        #expect(MemoryEvidenceVerifier.recognizesUserCommand(text))
    }
    for text in ["\"Remember that I live in Paris.\"", "> Forget that I live in Paris.",
                 "If I no longer live in Paris, what happens?", "I no longer live in Paris?",
                 "Should I remember that I live in Paris?", "Remember that ",
                 "Remember that I live in Paris.\nActually, this is only a quotation."] {
        #expect(!MemoryEvidenceVerifier.recognizesUserCommand(text))
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: []) == .unsupported)
    }
    #expect(MemoryEvidenceVerifier.userTarget(text: "Remember that I might move to Lyon, but only in winter.", claims: [])
        == .newClaim(action: .retainUncertain, body: "I might move to Lyon, but only in winter."))
}

@Test("Explicitly adopted quotation preserves its exact body and uncertainty; quotes alone grant no authority")
func memoryEvidenceAdoptedQuotationIsExactAndFallible() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that I live in Paris.")
    await fixture.store.put(initial)
    let previous = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let artifact = fixture.artifact([previous])
    let reference = try MemoryClaimCodec().reference(for: previous, in: artifact,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(artifact)))
    let exactBody = "  I might move to Lyon, but only in winter.  "
    for (offset, quoted) in ["\"" + exactBody + "\"", "“" + exactBody + "”"].enumerated() {
        let text = "Replace it with this: " + quoted
        #expect(MemoryEvidenceVerifier.recognizesUserCommand(text))
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: [previous])
            == .existingClaim(action: .correctAdoptedQuotation, body: exactBody, claimID: previous.id))
        let message = try fixture.message(text, sequence: Int64(offset + 2))
        await fixture.store.put(message)
        let pair = try await fixture.verifier.userCorrectionProposal(messageID: message.id, previous: previous,
            previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
        #expect(pair.successor.body.utf8.elementsEqual(exactBody.utf8))
        #expect(pair.successor.assessment.level == .uncertain)
        #expect(pair.successor.assessment.basis.contains("explicitly adopted"))
        #expect(!pair.successor.assessment.basis.contains("first-hand"))
        #expect(pair.withdrawnPredecessor.validity == .withdrawn && pair.successor.id != previous.id)
        let evidence = try await fixture.verifier.verify(
            artifact: fixture.artifact([pair.withdrawnPredecessor, pair.successor], revision: 2), predecessor: artifact,
            actor: .user(messageID: message.id), authority: fixture.context, at: fixture.now)
        #expect(evidence.userMessages.contains { $0.messageID == message.id })
    }
    let model = try fixture.message("Replace it with this: \"I live in Lyon.\"", sequence: 4,
        author: .teammate(fixture.teammate.id))
    await fixture.store.put(model)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.userCorrectionProposal(messageID: model.id, previous: previous,
            previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
}

@Test("Adoption grammar refuses quoted commands, hypothetical prefixes, extra prose and ambiguous delimiters")
func memoryEvidenceQuotationDoesNotImplyAdoption() {
    for text in [
        "\"Replace it with this: I live in Lyon.\"", "> Replace it with this: \"I live in Lyon.\"",
        "If I said Replace it with this: \"I live in Lyon.\"", "The document says Replace it with this: \"I live in Lyon.\"",
        "Replace it with this: I live in Lyon.", "Replace it with this: \"\"", "Replace it with this: \"   \"",
        "Replace it with this: \"I live in Lyon.\" I am just quoting someone.",
        "Replace it with this: \"I live in Lyon.\" or \"I live in Paris.\"",
        "Replace it with this: “I live in Lyon.\"", "Replace it with this: \"I live in Lyon?\"",
        "Replace it with this: \"I live in Lyon.\nMaybe.\"",
        "Replace \"\" with \"I live in Lyon.\"", "Replace \"I live in Paris.\" with \"\"",
        "Replace “I live in Paris.” with \"I live in Lyon.\"",
        "Replace \"I live in Paris.\" with \"I live in Lyon.\" and \"I live in Rome.\"",
        "If needed, Replace \"I live in Paris.\" with \"I live in Lyon.\""
    ] {
        #expect(!MemoryEvidenceVerifier.recognizesUserCommand(text))
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: []) == .unsupported)
    }
}

@Test("Named adopted replacements must match the actual prior statement and do not infer a target")
func memoryEvidenceNamedQuotedTargetIsBound() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that I prefer tea.")
    await fixture.store.put(initial)
    let prior = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let artifact = fixture.artifact([prior])
    let reference = try MemoryClaimCodec().reference(for: prior, in: artifact,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(artifact)))
    let command = "Replace “I prefer tea.” with “I might prefer cocoa, if available.”"
    #expect(MemoryEvidenceVerifier.userTarget(text: command, claims: [prior])
        == .existingClaim(action: .correctAdoptedQuotation, body: "I might prefer cocoa, if available.", claimID: prior.id))
    #expect(MemoryEvidenceVerifier.userTarget(text: command, claims: []) == .ambiguous)
    let message = try fixture.message(command, sequence: 2)
    await fixture.store.put(message)
    let pair = try await fixture.verifier.userCorrectionProposal(messageID: message.id, previous: prior,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    #expect(pair.successor.assessment.level == .uncertain)
    let wrong = try fixture.message("Replace \"I prefer trains.\" with \"I prefer cocoa.\"", sequence: 3)
    await fixture.store.put(wrong)
    #expect(MemoryEvidenceVerifier.userTarget(text: "Replace \"I prefer trains.\" with \"I prefer cocoa.\"", claims: [prior]) == .ambiguous)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.userCorrectionProposal(messageID: wrong.id, previous: prior,
            previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
}

@Test("Conversational target resolution preserves exact qualifications and refuses ambiguity or withdrawn resurrection")
func memoryEvidenceConversationalTargetIsExact() {
    func claim(_ body: String, validity: MemoryClaimValidity = .active) -> MemoryClaim {
        MemoryClaim(id: MemoryClaimID(UUID()), body: body,
            assessment: .init(level: .unassessed, basis: "", assessor: .init(kind: .unassessed)),
            provenance: [], validity: validity)
    }
    let first = claim("I live in Paris, during summer only.")
    #expect(MemoryEvidenceVerifier.userTarget(text: "Forget that I live in Paris.", claims: [first]) == .ambiguous)
    #expect(MemoryEvidenceVerifier.userTarget(text: "Please forget that I live in Paris, during summer only.", claims: [first])
        == .existingClaim(action: .withdraw, body: first.body, claimID: first.id))
    let residence = claim("I live in Paris.")
    #expect(MemoryEvidenceVerifier.userTarget(text: "I no longer live in Paris.", claims: [residence])
        == .existingClaim(action: .withdraw, body: residence.body, claimID: residence.id))
    #expect(MemoryEvidenceVerifier.userTarget(text: "I no longer live in Lyon.", claims: [residence]) == .ambiguous)
    #expect(MemoryEvidenceVerifier.userTarget(text: "Forget that I live in Paris.",
                                            claims: [residence, claim(residence.body)]) == .ambiguous)
    #expect(MemoryEvidenceVerifier.userTarget(text: "Remember that I live in Paris.",
                                            claims: [claim(residence.body, validity: .withdrawn)]) == .ambiguous)
    let historical = claim(residence.body, validity: .withdrawn)
    for (text, action) in [
        ("I confirm from first-hand knowledge: I live in Paris.", MemoryUserCommandAction.confirmFirstHand),
        ("Remember as uncertain: I live in Paris.", .retainUncertain)
    ] {
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: [historical, residence])
            == .existingClaim(action: action, body: residence.body, claimID: residence.id))
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: [historical]) == .ambiguous)
    }
    #expect(MemoryEvidenceVerifier.userTarget(text: "I no longer live in Paris.", claims: []) == .ambiguous)
}

@Test("Ordinary remember and no-longer-live commands bind real user messages and withdraw without inventing a city")
func memoryEvidenceConversationalAliasesPreserveAuthority() async throws {
    let fixture = try MemoryEvidenceFixture()
    let original = try fixture.message("Remember that I live in Paris.")
    await fixture.store.put(original)
    let claim = try await fixture.verifier.userProposal(messageID: original.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    #expect(claim.assessment.level == .uncertain)
    #expect(claim.assessment.basis.contains("not been independently verified"))
    let predecessor = fixture.artifact([claim])
    let bytes = try MemoryClaimCodec().encode(predecessor)
    let reference = try MemoryClaimCodec().reference(for: claim, in: predecessor,
        contentDigest: MemoryClaimDigests.bytes(bytes))
    let correction = try fixture.message("I no longer live in Paris.", sequence: 2)
    await fixture.store.put(correction)
    let withdrawn = try await fixture.verifier.userProposal(messageID: correction.id, claimID: claim.id,
        scope: fixture.scope, previous: claim, previousReference: reference, authority: fixture.context, at: fixture.now)
    let resolved = try await fixture.verifier.verify(artifact: fixture.artifact([withdrawn], revision: 2),
        predecessor: predecessor, actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
    try MemoryClaimAssessmentTransition.validate(previous: claim, previousReference: reference, proposal: withdrawn,
        scope: fixture.scope, actor: withdrawn.assessment.assessor, verifiedEvidence: resolved.verified,
        previousIndependentEvidenceIDs: resolved.previousIndependentEvidenceIDs, at: fixture.now)
    #expect(withdrawn.id == claim.id)
    #expect(withdrawn.body == "I live in Paris.")
    #expect(withdrawn.validity == .withdrawn)
    #expect(withdrawn.assessment.evidence[0].source.sourceID == correction.id.persistedValue)
    #expect(withdrawn.assessment.evidence[0].relation == .invalidates)
    let model = try fixture.message("Remember that I live in Lyon.", sequence: 3, author: .teammate(fixture.teammate.id))
    await fixture.store.put(model)
    await #expect(throws: MemoryEvidenceVerifierError.self) {
        _ = try await fixture.verifier.userProposal(messageID: model.id, claimID: MemoryClaimID(UUID()),
            scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
}

@Test("Ordinary preference corrections recognize one bounded statement with case and outer whitespace normalization")
func memoryEvidenceOrdinaryPreferenceRecognitionIsBounded() {
    for text in ["Actually, I prefer coffee.", "actually, i prefer coffee", " \tACTUALLY, I PREFER quiet places.\n "] {
        #expect(MemoryEvidenceVerifier.recognizesUserCommand(text))
    }
    for text in [
        "\"Actually, I prefer coffee.\"", "“Actually, I prefer coffee.”", "> Actually, I prefer coffee.",
        "If I said Actually, I prefer coffee.", "Hypothetically, actually, I prefer coffee.",
        "Actually, I prefer coffee if available.", "Actually, I prefer coffee when travelling.",
        "Actually, I prefer coffee only in winter.", "Actually, I prefer coffee hypothetically.",
        "Actually, I prefer coffee and tea.", "Actually, I prefer coffee or tea.",
        "Actually, I prefer coffee. I live in Paris.", "Actually, I prefer coffee; remember it.",
        "Actually, I prefer coffee.\nRemember it.", "Actually, \nI prefer coffee.",
        "Actually, I prefer \"coffee\".", "Actually, I prefer ‘coffee’.",
        "Actually, I prefer coffee?", "Actually, I prefer.", "Actually, I prefer ",
        "Actually, I might prefer coffee.", "Actually, they prefer coffee.", "Actually, I live in Paris."
    ] {
        #expect(!MemoryEvidenceVerifier.recognizesUserCommand(text), "Unexpected command: \(text)")
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: []) == .unsupported)
    }
    // Existing explicit grammar retains its original exact, case-sensitive behavior.
    #expect(!MemoryEvidenceVerifier.recognizesUserCommand(" correct from first-hand knowledge to: I prefer coffee."))
    #expect(MemoryEvidenceVerifier.recognizesUserCommand("Correct from first-hand knowledge to: I live in Lyon."))
}

@Test("Ordinary correction selects one current first-person preference and never the sole unrelated claim")
func memoryEvidenceOrdinaryPreferenceTargetIsRestricted() {
    func claim(_ body: String, validity: MemoryClaimValidity = .active) -> MemoryClaim {
        MemoryClaim(id: MemoryClaimID(UUID()), body: body,
            assessment: .init(level: .unassessed, basis: "", assessor: .init(kind: .unassessed)),
            provenance: [], validity: validity)
    }
    let preference = claim("  i PREFER tea.  ")
    let residence = claim("I live in Paris.")
    let text = "Actually, I prefer coffee."
    #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: [preference, residence])
        == .existingClaim(action: .correctFirstHand, body: "I prefer coffee.", claimID: preference.id))
    for candidates in [[], [residence], [claim("They prefer tea.")], [claim("I prefer tea if available.")],
                       [claim("I prefer tea. I live in Paris.")], [claim("I prefer tea.", validity: .withdrawn)],
                       [preference, claim("I prefer quiet places.")], [preference, claim("I prefer tea if available.")],
                       [preference, preference]] {
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: candidates) == .ambiguous)
    }
    #expect(MemoryEvidenceVerifier.userTarget(text: text,
        claims: [preference, claim("I prefer coffee.", validity: .withdrawn)])
        == .existingClaim(action: .correctFirstHand, body: "I prefer coffee.", claimID: preference.id))
    #expect(MemoryEvidenceVerifier.userTarget(text: "Correct from first-hand knowledge to: I live in Lyon.", claims: [residence])
        == .existingClaim(action: .correctFirstHand, body: "I live in Lyon.", claimID: residence.id))
}

@Test("Ordinary preference correction binds original message bytes and retains the exact withdrawn preference")
func memoryEvidenceOrdinaryPreferencePreservesSourceAndHistory() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that   i PREFER tea.  ")
    await fixture.store.put(initial)
    let previous = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let predecessor = fixture.artifact([previous])
    let reference = try MemoryClaimCodec().reference(for: previous, in: predecessor,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(predecessor)))
    let originalText = " \tACTUALLY, i PREFER coffee.\n "
    let correction = try fixture.message(originalText, sequence: 2)
    await fixture.store.put(correction)
    let pair = try await fixture.verifier.userCorrectionProposal(messageID: correction.id, previous: previous,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    #expect(pair.withdrawnPredecessor.body.utf8.elementsEqual(previous.body.utf8))
    #expect(pair.withdrawnPredecessor.id == previous.id && pair.withdrawnPredecessor.validity == .withdrawn)
    #expect(pair.successor.body == "i PREFER coffee.")
    #expect(pair.successor.id != previous.id && pair.successor.validity == .active)
    #expect(pair.successor.assessment.level == .uncertain)
    #expect(pair.successor.assessment.basis.contains("not been independently verified"))
    #expect(!pair.successor.assessment.basis.contains("first-hand"))
    #expect(pair.successor.changes[0].kind == .supersession && pair.successor.changes[0].previous == reference)
    #expect(pair.successor.assessment.evidence[0].source.contentDigest == MemoryClaimDigests.bytes(Data(originalText.utf8)))
    #expect(try await fixture.verifier.userCorrectionProposal(messageID: correction.id, previous: previous,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now) == pair)
    let evidence = try await fixture.verifier.verify(
        artifact: fixture.artifact([pair.withdrawnPredecessor, pair.successor], revision: 2), predecessor: predecessor,
        actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
    #expect(evidence.verified.count == 2)
    #expect(evidence.userMessages.contains { $0.messageID == correction.id && $0.contentDigest == MemoryClaimDigests.bytes(Data(originalText.utf8)) })
    let later = try fixture.message("What do you remember about me?", sequence: 3)
    await fixture.store.put(later)
    let retainedOld = try await fixture.verifier.verifyRetained(claim: pair.withdrawnPredecessor,
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let retainedNew = try await fixture.verifier.verifyRetained(claim: pair.successor,
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    #expect(retainedOld[0].reference.relation == .invalidates)
    #expect(retainedNew[0].reference.relation == .supports)
    let model = try fixture.message("Actually, I prefer cocoa.", sequence: 4, author: .teammate(fixture.teammate.id))
    await fixture.store.put(model)
    await #expect(throws: MemoryEvidenceVerifierError.invalidSource) {
        _ = try await fixture.verifier.userCorrectionProposal(messageID: model.id, previous: previous,
            previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
}

@Test("Ordinary preference corrections cannot authorize an unrelated withdrawal even with recomputed source receipts")
func memoryEvidenceOrdinaryPreferenceRejectsUnrelatedEvidence() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that I live in Paris.")
    await fixture.store.put(initial)
    let previous = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let predecessor = fixture.artifact([previous])
    let reference = try MemoryClaimCodec().reference(for: previous, in: predecessor,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(predecessor)))
    let explicit = try fixture.message("Correct from first-hand knowledge to: I prefer coffee.", sequence: 2)
    await fixture.store.put(explicit)
    let explicitPair = try await fixture.verifier.userCorrectionProposal(messageID: explicit.id, previous: previous,
        previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let ordinaryText = "Actually, I prefer coffee."
    let ordinary = try Message(id: explicit.id, conversationID: explicit.conversationID, sequence: explicit.sequence,
        author: .user, deliveryState: .pending,
        parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(ordinaryText))],
        createdAt: explicit.createdAt, updatedAt: explicit.updatedAt)
    await fixture.store.put(ordinary)
    await #expect(throws: MemoryEvidenceVerifierError.ambiguousIntent) {
        _ = try await fixture.verifier.userCorrectionProposal(messageID: ordinary.id, previous: previous,
            previousReference: reference, scope: fixture.scope, authority: fixture.context, at: fixture.now)
    }
    await #expect(throws: MemoryEvidenceVerifierError.ambiguousIntent) {
        _ = try await fixture.verifier.userProposal(messageID: ordinary.id, claimID: previous.id,
            scope: fixture.scope, previous: previous, previousReference: reference, authority: fixture.context, at: fixture.now)
    }
    let forged = try rebindPreferenceTestEvidence(explicitPair.withdrawnPredecessor,
        sourceText: ordinaryText, scope: fixture.scope)
    #expect(forged.assessment.evidence[0].source.contentDigest == MemoryClaimDigests.bytes(Data(ordinaryText.utf8)))
    // All public receipt hashes match the actual ordinary message. Its narrow
    // meaning still cannot invalidate this residence claim during retained reads.
    await #expect(throws: MemoryEvidenceVerifierError.unsupportedIntent) {
        _ = try await fixture.verifier.verifyRetained(claim: forged, scope: fixture.scope,
            authority: fixture.context, at: fixture.now)
    }
    await #expect(throws: MemoryEvidenceVerifierError.ambiguousIntent) {
        _ = try await fixture.verifier.verify(
            artifact: fixture.artifact([forged, explicitPair.successor], revision: 2), predecessor: predecessor,
            actor: .user(messageID: ordinary.id), authority: fixture.context, at: fixture.now)
    }
}

@Test("An ordinary same-preference correction preserves identity without inventing confirmation")
func memoryEvidenceOrdinarySamePreferenceKeepsIdentity() async throws {
    let fixture = try MemoryEvidenceFixture()
    let initial = try fixture.message("Remember that I prefer coffee.")
    await fixture.store.put(initial)
    let previous = try await fixture.verifier.userProposal(messageID: initial.id, claimID: MemoryClaimID(UUID()),
        scope: fixture.scope, authority: fixture.context, at: fixture.now)
    let predecessor = fixture.artifact([previous])
    let reference = try MemoryClaimCodec().reference(for: previous, in: predecessor,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(predecessor)))
    let correction = try fixture.message("Actually, I prefer coffee.", sequence: 2)
    await fixture.store.put(correction)
    let proposal = try await fixture.verifier.userProposal(messageID: correction.id, claimID: previous.id,
        scope: fixture.scope, previous: previous, previousReference: reference, authority: fixture.context, at: fixture.now)
    #expect(proposal.id == previous.id && proposal.body == previous.body)
    #expect(proposal.assessment.level == .uncertain)
    let evidence = try await fixture.verifier.verify(artifact: fixture.artifact([proposal], revision: 2),
        predecessor: predecessor, actor: .user(messageID: correction.id), authority: fixture.context, at: fixture.now)
    #expect(evidence.verified.count == 1)
}

@Test("Direct verification cannot select one of multiple preferences or trust caller-narrowed references")
func memoryEvidenceOrdinaryPreferenceVerificationRejectsAmbiguity() async throws {
    let fixture = try MemoryEvidenceFixture()
    var claims: [MemoryClaim] = []
    for (index, body) in ["I prefer tea.", "I prefer quiet rooms."].enumerated() {
        let message = try fixture.message("Remember that " + body, sequence: Int64(index + 1))
        await fixture.store.put(message)
        claims.append(try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
            scope: fixture.scope, authority: fixture.context, at: fixture.now))
    }
    let predecessor = fixture.artifact(claims)
    let reference = try MemoryClaimCodec().reference(for: claims[0], in: predecessor,
        contentDigest: MemoryClaimDigests.bytes(MemoryClaimCodec().encode(predecessor)))
    let narrowed = try fixture.qualifiedAuthority(for: predecessor, references: [reference])
    for (offset, text) in ["Actually, I prefer coffee.", "Actually, I prefer tea."].enumerated() {
        #expect(MemoryEvidenceVerifier.userTarget(text: text, claims: claims) == .ambiguous)
        let message = try fixture.message(text, sequence: Int64(offset + 3))
        await fixture.store.put(message)
        let revised: [MemoryClaim]
        if offset == 0 {
            let pair = try await fixture.verifier.userCorrectionProposal(messageID: message.id, previous: claims[0],
                previousReference: reference, scope: fixture.scope, authority: narrowed, at: fixture.now)
            revised = [pair.withdrawnPredecessor, claims[1], pair.successor]
        } else {
            let reassessed = try await fixture.verifier.userProposal(messageID: message.id, claimID: claims[0].id,
                scope: fixture.scope, previous: claims[0], previousReference: reference, authority: narrowed, at: fixture.now)
            revised = [reassessed, claims[1]]
        }
        for authority in [fixture.context, narrowed] {
            await #expect(throws: MemoryEvidenceVerifierError.ambiguousIntent) {
                _ = try await fixture.verifier.verify(artifact: fixture.artifact(revised, revision: 2), predecessor: predecessor,
                    actor: .user(messageID: message.id), authority: authority, at: fixture.now)
            }
        }
    }
}

@Test("Preference verification accepts an independently verified displayed target but rejects multiple displayed preferences")
func memoryEvidenceOrdinaryPreferenceVerificationChecksDisplayedPublication() async throws {
    let fixture = try MemoryEvidenceFixture()
    var claims: [MemoryClaim] = []
    for (index, body) in ["I prefer tea.", "I prefer quiet rooms."].enumerated() {
        let message = try fixture.message("Remember that " + body, sequence: Int64(index + 1))
        await fixture.store.put(message)
        claims.append(try await fixture.verifier.userProposal(messageID: message.id, claimID: MemoryClaimID(UUID()),
            scope: fixture.scope, authority: fixture.context, at: fixture.now))
    }
    let predecessor = fixture.artifact(claims)
    let digest = MemoryClaimDigests.bytes(try MemoryClaimCodec().encode(predecessor))
    let references = try claims.map { try MemoryClaimCodec().reference(for: $0, in: predecessor, contentDigest: digest) }
    let authority = try fixture.qualifiedAuthority(for: predecessor, references: [references[0]])
    let displayedAuthority = try fixture.qualifiedAuthority(for: predecessor, references: references)
    let query = try fixture.message("What do you remember about me?", sequence: 3)
    let replyID = MessageID(UUID())
    let correction = try fixture.message("Actually, I prefer coffee.", sequence: 5)
    await fixture.store.put(correction)
    let pair = try await fixture.verifier.userCorrectionProposal(messageID: correction.id, previous: claims[0],
        previousReference: references[0], scope: fixture.scope, authority: authority, at: fixture.now)
    let artifact = fixture.artifact([pair.withdrawnPredecessor, claims[1], pair.successor], revision: 2)
    for count in [1, 2] {
        let shown = Array(references.prefix(count))
        let rendered = claims.prefix(count).map { "Not established; " + $0.body }.joined(separator: "\n\n")
        let reply = try Message(id: replyID, conversationID: fixture.context.conversationID, sequence: 4,
            author: .system, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(rendered))],
            createdAt: query.createdAt, updatedAt: query.updatedAt)
        let receipt = MemoryPublicationReceipt(id: UUID(), policyVersion: MemoryConversationPublicationService.rendererPolicyVersion,
            runID: RunID(UUID()), messageID: reply.id, teammateID: fixture.teammate.id, selectedProjectID: nil,
            intent: .overview, renderedTextDigest: MemoryClaimDigests.bytes(Data(rendered.utf8)),
            units: [.init(kind: .overview, references: shown)],
            dependencies: shown.map { .init(reference: $0, scope: fixture.scope, sourceStamps: [], evidenceStamps: [],
                decision: .init(disposition: .qualified, reasons: [.lowAssessment], requiredFraming: .unconfirmedPossibility, dependency: $0)) },
            lineage: .independent, createdAt: query.createdAt)
        let record = MemoryConversationPublicationRecord(
            publication: .init(completeUnits: [rendered], receipt: receipt, omittedUnitCount: 0),
            userMessage: query, replyMessage: reply, authority: displayedAuthority, userSourceStamps: [], storedAt: query.createdAt)
        await fixture.store.put(record)
        if count == 1 {
            let verified = try await fixture.verifier.verify(artifact: artifact, predecessor: predecessor,
                actor: .user(messageID: correction.id), authority: authority, at: fixture.now)
            #expect(verified.verified.count == 3)
        } else {
            // Caller narrowing cannot hide a second preference actually shown.
            await #expect(throws: MemoryEvidenceVerifierError.ambiguousIntent) {
                _ = try await fixture.verifier.verify(artifact: artifact, predecessor: predecessor,
                    actor: .user(messageID: correction.id), authority: authority, at: fixture.now)
            }
        }
    }
}

private func rebindPreferenceTestEvidence(_ claim: MemoryClaim, sourceText: String,
                                          scope: MemoryScope) throws -> MemoryClaim {
    let original = claim.assessment.evidence[0]
    let source = MemoryClaimSourceReference(id: original.source.id, kind: original.source.kind,
        sourceID: original.source.sourceID, sourceRevision: original.source.sourceRevision,
        contentDigest: MemoryClaimDigests.bytes(Data(sourceText.utf8)), observedAt: original.source.observedAt, scope: scope)
    struct Binding: Encodable {
        let registry: String; let version: UInt16; let claimID: MemoryClaimID; let source: MemoryClaimSourceReference
        let subject: String; let relation: MemoryClaimEvidenceRelation; let level: MemoryClaimAssessmentLevel
        let validity: MemoryClaimValidity; let assessedAt: Date?
    }
    let digest = MemoryClaimDigests.bytes(try MemoryClaimDigests.canonicalData(Binding(
        registry: MemoryEvidenceVerifier.userRegistryID, version: MemoryEvidenceVerifier.registryVersion,
        claimID: claim.id, source: source, subject: original.subjectDigest, relation: original.relation,
        level: claim.assessment.level, validity: claim.validity, assessedAt: claim.assessment.assessedAt)))
    let chars = Array(MemoryClaimDigests.bytes(Data(digest.utf8)).prefix(32))
    let uuid = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16])
        + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
    let evidence = MemoryClaimEvidenceReference(receiptID: try #require(UUID(uuidString: uuid)), receiptDigest: digest,
        source: source, relation: original.relation, subjectDigest: original.subjectDigest)
    return MemoryClaim(id: claim.id, body: claim.body,
        assessment: .init(level: claim.assessment.level, basis: claim.assessment.basis, assessor: claim.assessment.assessor,
            assessedAt: claim.assessment.assessedAt, policyVersion: claim.assessment.policyVersion, evidence: [evidence]),
        provenance: [source], observedAt: claim.observedAt, validFrom: claim.validFrom, validUntil: claim.validUntil,
        conditions: claim.conditions, validity: claim.validity, changes: claim.changes)
}

private struct MemoryEvidenceFixture {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let teammate: Teammate
    let context: ReadContextReceipt
    let store: MemoryEvidenceTestStore
    let verifier: MemoryEvidenceVerifier
    var scope: MemoryScope { .teammate(teammate.id) }
    init() throws {
        let id = TeammateID(UUID())
        let time = Date(timeIntervalSince1970: 1_779_999_980)
        teammate = try Teammate(id: id, profile: TeammateProfile(displayName: "Fixture", role: "Testing"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
                silhouette: "round", paletteToken: "mint", eyeDialect: "calm", nonColorIdentityCue: "ears",
                accessibleIdentityDescription: "Fixture bot"), createdAt: time, updatedAt: time)
        context = ReadContextReceipt(conversationID: ConversationID(UUID()), teammateID: id, profileRevision: 1,
            contextRevision: 1, selectedProjectID: nil, selectedTeamID: nil, participantJoinedAt: time,
            projectMembershipJoinedAt: nil, teamMembershipJoinedAt: nil, messages: [], memoryDocuments: [])
        store = MemoryEvidenceTestStore(teammate: teammate, context: context)
        verifier = MemoryEvidenceVerifier(messages: store, teammates: store, contexts: store, publications: store)
    }
    func message(_ text: String, sequence: Int64 = 1, author: MessageAuthor = .user) throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: context.conversationID, sequence: sequence,
            author: author, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))],
            createdAt: now.addingTimeInterval(-5), updatedAt: now.addingTimeInterval(-5))
    }
    func artifact(_ claims: [MemoryClaim], revision: UInt64 = 1) -> MemoryClaimArtifact {
        MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()), revision: revision, scope: scope, claims: claims)
    }
    func qualifiedAuthority(for artifact: MemoryClaimArtifact, references: [MemoryClaimReference]) throws -> ReadContextReceipt {
        let digest = MemoryClaimDigests.bytes(try MemoryClaimCodec().encode(artifact))
        return try ReadContextReceipt(conversationID: context.conversationID, teammateID: context.teammateID,
            profileRevision: context.profileRevision, contextRevision: context.contextRevision,
            selectedProjectID: nil, selectedTeamID: nil, participantJoinedAt: context.participantJoinedAt,
            projectMembershipJoinedAt: nil, teamMembershipJoinedAt: nil, messages: [],
            memoryDocuments: [.init(documentID: artifact.documentID, scope: scope, revision: artifact.revision,
                contentDigest: digest, metadataDigest: String(repeating: "b", count: 64))]).qualifying(with: references)
    }
}

private actor MemoryEvidenceTestStore: MessageRepository, TeammateRepository, ReadContextRepository, MemoryConversationPublicationRepository {
    private var teammateValue: Teammate
    private let context: ReadContextReceipt
    private var messageValues: [MessageID: Message] = [:]
    private var publicationValues: [MessageID: MemoryConversationPublicationRecord] = [:]
    init(teammate: Teammate, context: ReadContextReceipt) { teammateValue = teammate; self.context = context }
    func put(_ message: Message) { messageValues[message.id] = message }
    func put(_ teammate: Teammate) { teammateValue = teammate }
    func put(_ record: MemoryConversationPublicationRecord) {
        publicationValues[record.replyMessage.id] = record
        messageValues[record.userMessage.id] = record.userMessage
        messageValues[record.replyMessage.id] = record.replyMessage
    }
    func replaceMessages(_ messages: [Message]) { messageValues = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }) }
    func message(id: MessageID) async throws -> Message? { messageValues[id] }
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message> {
        let values = messageValues.values.filter { $0.conversationID == conversationID }.sorted { $0.sequence < $1.sequence }
        return Page(elements: Array(values.suffix(request.limit)), hasMore: values.count > request.limit)
    }
    func teammate(id: TeammateID) async throws -> Teammate? { id == teammateValue.id ? teammateValue : nil }
    func revalidateReadContext(_ receipt: ReadContextReceipt) async throws {
        guard receipt.conversationID == context.conversationID, receipt.teammateID == teammateValue.id,
              receipt.profileRevision == teammateValue.profile.revision, receipt.contextRevision == context.contextRevision,
              receipt.selectedProjectID == context.selectedProjectID else { throw ReadContextError.staleReferences }
    }
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws { throw ReadContextError.unavailable }
    func updateDeliveryState(messageID: MessageID, from expectedState: MessageDeliveryState,
                             to newState: MessageDeliveryState, updatedAt: Date) async throws { throw ReadContextError.unavailable }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { [teammateValue] }
    func insert(_ teammate: Teammate) async throws { throw ReadContextError.unavailable }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws { throw ReadContextError.unavailable }
    func loadReadContextCandidates(_ request: ReadContextRequest) async throws -> ReadContextSnapshot { throw ReadContextError.unavailable }
    func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord? {
        publicationValues.values.first { $0.publication.receipt.id == id }
    }
    func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID) async throws -> MemoryConversationPublicationRecord? {
        guard let record = publicationValues[messageID], record.authority.conversationID == conversationID else { return nil }
        return record
    }
    func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend, now: Date) async throws -> MemoryConversationPublicationRecord {
        throw ReadContextError.unavailable
    }
}
