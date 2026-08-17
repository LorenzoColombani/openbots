import XCTest
@testable import AgencyKit

/// Regression tests for a MEASURED bug: `roster.json` is rewritten whole on every
/// change, so concurrent writers used to clobber each other. Twelve simultaneous
/// `createAgent` calls left four agents in the roster while twelve folders existed
/// on disk; the same window can drop a `sessionID`, which makes that teammate
/// forget its entire conversation.
final class RosterConcurrencyTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-race-\(UUID().uuidString)"))
    }

    func testConcurrentCreatesDoNotLoseAgents() throws {
        let store = makeStore()
        let count = 12
        DispatchQueue.concurrentPerform(iterations: count) { i in
            _ = try? store.createAgent(name: "agent\(i)", emoji: "🤖", role: "probe \(i)")
        }
        let roster = try store.loadRoster()
        XCTAssertEqual(roster.agents.count, count,
                       "lost \(count - roster.agents.count) agents to a roster write race")
        for i in 0..<count {
            XCTAssertTrue(roster.agents.contains { $0.name == "agent\(i)" }, "agent\(i) missing")
        }
    }

    /// The one that actually costs the user something: two teammates finishing at
    /// the same moment must not overwrite each other's session id.
    func testConcurrentSessionIDWritesAllSurvive() throws {
        let store = makeStore()
        let count = 10
        for i in 0..<count {
            _ = try store.createAgent(name: "agent\(i)", emoji: "🤖", role: "probe")
        }
        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? store.setSessionID("sid-\(i)", for: "agent\(i)")
        }
        let roster = try store.loadRoster()
        for i in 0..<count {
            let agent = roster.agents.first { $0.name == "agent\(i)" }
            XCTAssertEqual(agent?.sessionID, "sid-\(i)",
                           "agent\(i) lost its session id — it would forget its conversation")
        }
    }
}
