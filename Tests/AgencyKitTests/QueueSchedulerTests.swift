import XCTest
@testable import AgencyKit

/// The dispatch brain, extracted + tested (audit step 2). Encodes the rules
/// whose absence stalled his team: global ts fairness (I3), fan-out (I1),
/// FIFO-per-thread, plain-waits-for-replies.
final class QueueSchedulerTests: XCTestCase {
    private func head(_ thread: String, _ t: TimeInterval, target: String? = nil) -> QueueScheduler.Head {
        .init(thread: thread, ts: Date(timeIntervalSince1970: t), target: target)
    }

    func testFanOutDispatchesRelaysToDistinctIdleTargets() {
        // The librarian repro: two relay heads from one source — with fan-out
        // machinery, drain pass 1 launches the first, and once awaiting (not
        // busy) is the source's state, pass 2 launches the second.
        let pass1 = QueueScheduler.dispatchable(
            heads: [head("lib", 1, target: "bruno")], busy: [], awaiting: [:])
        XCTAssertEqual(pass1, ["lib"])
        let pass2 = QueueScheduler.dispatchable(
            heads: [head("lib", 2, target: "nina")],
            busy: ["bruno"], awaiting: ["lib": ["bruno"]])
        XCTAssertEqual(pass2, ["lib"], "awaiting bruno must NOT block the relay to nina")
    }

    func testSameTargetRelaysStayFIFO() {
        let r = QueueScheduler.dispatchable(
            heads: [head("lib", 2, target: "bruno")],
            busy: ["bruno"], awaiting: ["lib": ["bruno"]])
        XCTAssertTrue(r.isEmpty, "a second relay to the SAME target queues behind the first")
    }

    func testGlobalTimestampFairness() {
        // Audit I3: 'zeta' typed earlier than 'alpha' — alphabetical iteration
        // used to let alpha win every contention for the shared target.
        let r = QueueScheduler.dispatchable(
            heads: [head("alpha", 10, target: "bruno"), head("zeta", 5, target: "bruno")],
            busy: [], awaiting: [:])
        XCTAssertEqual(r, ["zeta"], "oldest head wins the contended target")
    }

    func testPlainHeadWaitsForItsOwnRepliesButNotOthers() {
        let heads = [head("lib", 1), head("nina", 2)]
        let r = QueueScheduler.dispatchable(
            heads: heads, busy: [], awaiting: ["lib": ["bruno"]])
        XCTAssertEqual(r, ["nina"],
                       "lib's plain head waits for its inbound replies; nina's runs")
    }

    func testBusyAndSelfRelayRules() {
        XCTAssertTrue(QueueScheduler.dispatchable(
            heads: [head("lib", 1, target: "bruno")], busy: ["lib"], awaiting: [:]).isEmpty,
            "a live source run still blocks its relay heads")
        XCTAssertTrue(QueueScheduler.dispatchable(
            heads: [head("lib", 1, target: "lib")], busy: [], awaiting: [:]).isEmpty,
            "@self is not a relay")
        XCTAssertTrue(QueueScheduler.dispatchable(
            heads: [head("lib", 1)], busy: ["lib"], awaiting: [:]).isEmpty)
    }

    func testOnePassNeverDoubleBooksATarget() {
        let r = QueueScheduler.dispatchable(
            heads: [head("a", 1, target: "bruno"), head("b", 2, target: "bruno")],
            busy: [], awaiting: [:])
        XCTAssertEqual(r, ["a"], "two heads wanting bruno — only the older launches this pass")
    }
}
