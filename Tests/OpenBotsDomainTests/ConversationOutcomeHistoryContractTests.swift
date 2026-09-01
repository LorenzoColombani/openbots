import Foundation
import OpenBotsDomain
import Testing

@Suite("Exact bounded saved-outcome read contract")
struct ConversationOutcomeHistoryContractTests {
    @Test("Invalid result limits are rejected before repository access", arguments: [-1, 0, 51, Int.max])
    func invalidLimits(_ limit: Int) {
        #expect(throws: ConversationOutcomeHistoryError.invalidLimit) {
            try ConversationOutcomeHistoryRequest(conversationID: ConversationID(UUID()), teammateID: TeammateID(UUID()), limit: limit)
        }
    }

    @Test("The request preserves exact caller scope and a bounded default")
    func exactScope() throws {
        let conversation = ConversationID(UUID()), teammate = TeammateID(UUID())
        let request = try ConversationOutcomeHistoryRequest(conversationID: conversation, teammateID: teammate)
        #expect(request.conversationID == conversation && request.teammateID == teammate)
        #expect(request.limit == 20 && ConversationOutcomeHistoryRequest.maximumLimit == 50)
        #expect(try ConversationOutcomeHistoryRequest(conversationID: conversation, teammateID: teammate, limit: 1).limit == 1)
        #expect(try ConversationOutcomeHistoryRequest(conversationID: conversation, teammateID: teammate, limit: 50).limit == 50)
    }

    @Test("A shared UUID never merges run and proposal provenance")
    func separateReferenceKinds() {
        let id = UUID()
        let run = SavedOutcomeEvent.run(id: RunID(id), origin: .localFixture, state: .interrupted,
                                       hasUnconfirmedInput: true, hasUnknownInput: true)
        let proposal = SavedOutcomeEvent.proposal(id: ApprovalID(id), state: .approved)
        #expect(run.reference != proposal.reference)
        #expect(Set([run.reference, proposal.reference]).count == 2)
    }
}
