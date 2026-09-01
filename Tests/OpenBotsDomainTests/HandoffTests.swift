import Foundation
import Testing
@testable import OpenBotsDomain

@Test("A handoff brief requires separate goal, output, and stop or approval fields")
func handoffBriefRequiresTypedFields() throws {
    #expect(throws: DomainValidationError.self) {
        _ = try HandoffBrief(
            goal: "Do the thing",
            constraints: [],
            inputReferences: [],
            requestedOutput: " ",
            exclusions: [],
            stopOrApprovalBoundary: "Stop if blocked"
        )
    }
    #expect(throws: DomainValidationError.self) {
        _ = try HandoffBrief(
            goal: "Do the thing",
            constraints: [],
            inputReferences: [],
            requestedOutput: "A result",
            exclusions: [],
            stopOrApprovalBoundary: " "
        )
    }

    let brief = try makeBrief()
    #expect(brief.goal == "Verify the evidence")
    #expect(brief.requestedOutput == "A compact verification result")
    #expect(brief.stopOrApprovalBoundary == "Stop if a source is unavailable")
}

@Test("Handoff provenance rejects self-targeting")
func handoffProvenanceRejectsSelfTarget() {
    let teammate = TeammateID(handoffDomainUUID(1))
    #expect(throws: DomainValidationError.self) {
        _ = try HandoffProvenance(
            handoffID: HandoffID(handoffDomainUUID(2)),
            legID: HandoffLegID(handoffDomainUUID(3)),
            originConversationID: ConversationID(handoffDomainUUID(4)),
            senderID: teammate,
            receiverID: teammate,
            createdAt: handoffBaseDate
        )
    }
}

@Test("A receiver result remains unavailable until explicit fan-in")
func handoffSuccessRequiresExplicitReturn() throws {
    let provenance = try makeProvenance()
    var handoff = Handoff(provenance: provenance, brief: try makeBrief())

    #expect(handoff.state == .staged)
    #expect(handoff.resultForOrigin == nil)
    #expect(throws: LifecycleTransitionError.self) {
        try handoff.apply(.returnToOrigin(at: handoffBaseDate.addingTimeInterval(1)))
    }

    try handoff.apply(.accept(at: handoffBaseDate.addingTimeInterval(1)))
    try handoff.apply(.beginWork(at: handoffBaseDate.addingTimeInterval(2)))
    try handoff.apply(
        .succeed(
            summary: "Two claims verified; one remains uncertain.",
            at: handoffBaseDate.addingTimeInterval(3)
        )
    )
    #expect(handoff.state == .succeeded)
    #expect(handoff.resultForOrigin == nil)

    try handoff.apply(.returnToOrigin(at: handoffBaseDate.addingTimeInterval(4)))
    let receipt = try #require(handoff.resultForOrigin)
    #expect(handoff.state == .returnedToOrigin)
    #expect(receipt.handoffID == provenance.handoffID)
    #expect(receipt.legID == provenance.legID)
    #expect(receipt.sourceTeammateID == provenance.receiverID)
    #expect(receipt.originTeammateID == provenance.senderID)
    #expect(receipt.result.summary == "Two claims verified; one remains uncertain.")
    #expect(receipt.returnedAt == handoffBaseDate.addingTimeInterval(4))
}

@Test("A recovery state cannot fabricate fan-in or silently retry")
func handoffRecoveryHasNoResultOrRetry() throws {
    let provenance = try makeProvenance()
    var handoff = Handoff(provenance: provenance, brief: try makeBrief())
    try handoff.apply(.accept(at: handoffBaseDate.addingTimeInterval(1)))
    try handoff.apply(.beginWork(at: handoffBaseDate.addingTimeInterval(2)))
    let recovery = try HandoffRecovery(
        code: "source-unavailable",
        userMessage: "A source is unavailable. No retry occurred.",
        isRecoverable: true,
        occurredAt: handoffBaseDate.addingTimeInterval(3)
    )
    try handoff.apply(.requireRecovery(recovery))

    #expect(handoff.state == .needsRecovery)
    #expect(handoff.recovery == recovery)
    #expect(handoff.resultForOrigin == nil)
    #expect(throws: LifecycleTransitionError.self) {
        try handoff.apply(.beginWork(at: handoffBaseDate.addingTimeInterval(4)))
    }
    #expect(throws: LifecycleTransitionError.self) {
        try handoff.apply(.returnToOrigin(at: handoffBaseDate.addingTimeInterval(4)))
    }
}

@Test("Handoff transitions cannot move backwards in time")
func handoffTransitionTimestampsAreMonotonic() throws {
    var handoff = Handoff(
        provenance: try makeProvenance(),
        brief: try makeBrief()
    )
    try handoff.apply(.accept(at: handoffBaseDate.addingTimeInterval(10)))
    #expect(throws: DomainValidationError.self) {
        try handoff.apply(.beginWork(at: handoffBaseDate.addingTimeInterval(9)))
    }
    #expect(handoff.state == .accepted)
}

private let handoffBaseDate = Date(timeIntervalSince1970: 1_780_100_000)

private func makeBrief() throws -> HandoffBrief {
    try HandoffBrief(
        goal: "Verify the evidence",
        constraints: ["Use only the supplied fixture references"],
        inputReferences: ["Draft revision 3"],
        requestedOutput: "A compact verification result",
        exclusions: ["Do not publish"],
        stopOrApprovalBoundary: "Stop if a source is unavailable"
    )
}

private func makeProvenance() throws -> HandoffProvenance {
    try HandoffProvenance(
        handoffID: HandoffID(handoffDomainUUID(20)),
        legID: HandoffLegID(handoffDomainUUID(21)),
        originConversationID: ConversationID(handoffDomainUUID(22)),
        senderID: TeammateID(handoffDomainUUID(23)),
        receiverID: TeammateID(handoffDomainUUID(24)),
        createdAt: handoffBaseDate
    )
}

private func handoffDomainUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "a4200000-0000-0000-0000-%012llu", value))!
}
