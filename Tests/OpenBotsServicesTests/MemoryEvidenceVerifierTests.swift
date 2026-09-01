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
        verifier = MemoryEvidenceVerifier(messages: store, teammates: store, contexts: store)
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
}

private actor MemoryEvidenceTestStore: MessageRepository, TeammateRepository, ReadContextRepository {
    private var teammateValue: Teammate
    private let context: ReadContextReceipt
    private var messageValues: [MessageID: Message] = [:]
    init(teammate: Teammate, context: ReadContextReceipt) { teammateValue = teammate; self.context = context }
    func put(_ message: Message) { messageValues[message.id] = message }
    func put(_ teammate: Teammate) { teammateValue = teammate }
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
}
