import Foundation
import Testing
@testable import OpenBotsDomain

@Suite("Handoff record")
struct HandoffRecordTests {
    let date = Date(timeIntervalSince1970: 1_000)
    func provenance() throws -> HandoffProvenance {
        try HandoffProvenance(handoffID: HandoffID(UUID()), legID: HandoffLegID(UUID()),
            originConversationID: ConversationID(UUID()), senderID: TeammateID(UUID()), receiverID: TeammateID(UUID()), createdAt: date)
    }
    func brief() throws -> HandoffBrief {
        try HandoffBrief(goal: "Write a haiku about teamwork", constraints: ["Three lines"], inputReferences: [],
            requestedOutput: "The haiku only", exclusions: ["No title"], stopOrApprovalBoundary: "Stop after one haiku")
    }

    @Test("A record carries the state machine and its anchors through the whole leg")
    func recordWalksTheLeg() throws {
        var record = HandoffRecord(handoff: try Handoff(provenance: provenance(), brief: brief()), sourceMessageID: MessageID(UUID()))
        #expect(record.state == .staged)
        try record.apply(.accept(at: date.addingTimeInterval(1)))
        record.briefMessageID = MessageID(UUID())
        record.runID = RunID(UUID())
        try record.apply(.beginWork(at: date.addingTimeInterval(2)))
        try record.apply(.succeed(summary: "Silent hands align / one river from many streams / the work moves as one", at: date.addingTimeInterval(3)))
        record.replyMessageID = MessageID(UUID())
        #expect(record.state == .succeeded)
        #expect(record.handoff.resultSummary?.hasPrefix("Silent hands") == true)
        #expect(record.handoff.completedAt == date.addingTimeInterval(3))
        try record.apply(.returnToOrigin(at: date.addingTimeInterval(4)))
        #expect(record.state == .returnedToOrigin)
        #expect(record.handoff.returnedAt == date.addingTimeInterval(4))
        #expect(record.handoff.resultForOrigin?.result.summary.hasPrefix("Silent hands") == true)
    }

    @Test("Rehydration reproduces every state, including a returned result and a recovery")
    func rehydration() throws {
        let p = try provenance(), b = try brief()
        let succeeded = try Handoff(rehydrating: p, brief: b, state: .succeeded, recovery: nil,
            lastTransitionAt: date.addingTimeInterval(3), resultSummary: "Done", completedAt: date.addingTimeInterval(3), returnedAt: nil)
        #expect(succeeded.state == .succeeded && succeeded.resultSummary == "Done" && succeeded.resultForOrigin == nil)
        let returned = try Handoff(rehydrating: p, brief: b, state: .returnedToOrigin, recovery: nil,
            lastTransitionAt: date.addingTimeInterval(4), resultSummary: "Done", completedAt: date.addingTimeInterval(3), returnedAt: date.addingTimeInterval(4))
        #expect(returned.resultForOrigin?.returnedAt == date.addingTimeInterval(4))
        #expect(returned.resultForOrigin?.originTeammateID == p.senderID)
        let recovery = try HandoffRecovery(code: "declined", userMessage: "Not sent.", isRecoverable: false, occurredAt: date.addingTimeInterval(2))
        let needs = try Handoff(rehydrating: p, brief: b, state: .needsRecovery, recovery: recovery,
            lastTransitionAt: date.addingTimeInterval(2), resultSummary: nil, completedAt: nil, returnedAt: nil)
        #expect(needs.recovery?.code == "declined")
        #expect(throws: DomainValidationError.self) {
            _ = try Handoff(rehydrating: p, brief: b, state: .succeeded, recovery: nil,
                lastTransitionAt: date, resultSummary: nil, completedAt: nil, returnedAt: nil)
        }
        #expect(throws: DomainValidationError.self) {
            _ = try Handoff(rehydrating: p, brief: b, state: .returnedToOrigin, recovery: nil,
                lastTransitionAt: date, resultSummary: "Done", completedAt: date, returnedAt: nil)
        }
    }

    @Test("A text-turn identity without a leg id decodes from the old shape")
    func identityDecodesWithoutLeg() throws {
        let old = TextTurnIdentity(appOwnerID: UUID(), replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID()))
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(TextTurnIdentity.self, from: data)
        #expect(decoded.handoffLegID == nil)
        let leg = HandoffLegID(UUID())
        let new = TextTurnIdentity(appOwnerID: UUID(), replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID()), handoffLegID: leg)
        #expect(try JSONDecoder().decode(TextTurnIdentity.self, from: JSONEncoder().encode(new)).handoffLegID == leg)
    }
}
