import XCTest
@testable import AgencyKit

final class ModelsTests: XCTestCase {
    func testAgentRoundTripsThroughJSON() throws {
        let agent = Agent(name: "alfredo", emoji: "🧑‍🍳", role: "research specialist",
                          model: nil, sessionID: nil)
        let data = try JSONEncoder().encode(agent)
        let back = try JSONDecoder().decode(Agent.self, from: data)
        XCTAssertEqual(agent, back)
    }

    func testChatMessageRoundTrips() throws {
        let msg = ChatMessage(ts: Date(timeIntervalSince1970: 1_755_000_000),
                              author: "alfredo", kind: .agent, text: "Alfredo: done")
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(msg, back)
    }
}
