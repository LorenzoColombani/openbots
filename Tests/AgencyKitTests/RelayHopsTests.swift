import XCTest
@testable import AgencyKit

/// The 2026-08-13 panel failure, pinned. Lorenzo: "have Sherlock think of a
/// good follow up, but also invoke the right other bots". Riker fanned out to
/// three teammates, collected the pitches, ran a second round — and was then
/// blocked from relaying the chosen message to Hermes. The hop budget had been
/// spent on fan-in wakes rather than on actual relays.
final class RelayHopsTests: XCTestCase {

    func testARelayCostsAHopAndAWakeDoesNot() {
        XCTAssertEqual(RelayHops.forRelay(from: 0), 1)
        XCTAssertEqual(RelayHops.forRelay(from: 3), 4)
        XCTAssertEqual(RelayHops.forWake(at: 3), 3,
                       "resuming an agent to read replies it already paid for is not a new hop")
    }

    func testExhaustionIsAtTheLimitNotBeyondIt() {
        XCTAssertFalse(RelayHops.exhausted(at: RelayHops.limit - 1))
        XCTAssertTrue(RelayHops.exhausted(at: RelayHops.limit))
    }

    /// Replays his actual panel. Every step is what the app does, in order.
    func testHisThreeAgentPanelCanStillHandOffTheResult() {
        var depth = 0                                   // Lorenzo typed the ask

        // Riker fans out to Bruno, AnnoyingLibrarian and Sherlock at once.
        // WIDTH IS FREE — all three siblings are issued from the same depth.
        let fanOut = [RelayHops.forRelay(from: depth),
                      RelayHops.forRelay(from: depth),
                      RelayHops.forRelay(from: depth)]
        XCTAssertEqual(fanOut, [1, 1, 1], "asking three teammates costs one hop, not three")
        depth = fanOut.max()!

        depth = RelayHops.forWake(at: depth)            // "all 3 replies arrived"
        XCTAssertFalse(RelayHops.exhausted(at: depth))

        // Round two: Riker goes back to two of them with the collected set.
        depth = RelayHops.forRelay(from: depth)
        depth = RelayHops.forWake(at: depth)
        XCTAssertFalse(RelayHops.exhausted(at: depth))

        // Round three — Riker corrects course with AnnoyingLibrarian.
        depth = RelayHops.forRelay(from: depth)
        depth = RelayHops.forWake(at: depth)

        // THE relay that matters: hand the chosen message to Hermes to send.
        XCTAssertFalse(RelayHops.exhausted(at: depth),
                       "the send relay was blocked in the live run — it must not be again")
        XCTAssertEqual(RelayHops.forRelay(from: depth), 4)
    }

    /// The budget still exists: a two-agent loop that keeps relaying is bounded.
    func testPingPongBetweenTwoAgentsStillTerminates() {
        var depth = 0
        var relays = 0
        while !RelayHops.exhausted(at: depth) {
            depth = RelayHops.forRelay(from: depth)     // A → B
            depth = RelayHops.forWake(at: depth)        // A woken by B's reply
            relays += 1
            XCTAssertLessThan(relays, 50, "the loop must terminate")
        }
        XCTAssertEqual(relays, RelayHops.limit,
                       "wakes are free, so the cap counts real relays — and still caps")
    }

    // MARK: the queued-message round trip

    /// The app queues a relay as "@target <message>" and re-reads it at
    /// delivery. A multi-line payload has to survive THAT too — a second place
    /// truncation could hide.
    func testMultiLinePayloadSurvivesTheQueuedTextFormat() throws {
        let hermes = Agent(name: "teammate3", emoji: "💬", role: "courier",
                           model: nil, sessionID: nil)
        let directive = try XCTUnwrap(RelayDirective.parse("""
        RELAY @teammate3: Send the contact exactly this:

        "The rota says it's your turn to bring the coffee."
        """).first)

        let queued = "@\(directive.target) \(directive.message)"
        let resolved = try XCTUnwrap(Mentions.resolveRelay(text: queued, agents: [hermes]))
        XCTAssertEqual(resolved.target.name, "teammate3")
        XCTAssertTrue(resolved.question.contains("bring the coffee"),
                      "the payload must still be there when the queue hands it to the broker")
        XCTAssertEqual(resolved.question, directive.message, "byte-identical end to end")
    }
}
