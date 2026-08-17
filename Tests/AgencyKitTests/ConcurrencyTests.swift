import XCTest
@testable import AgencyKit

/// The roster race (RosterConcurrencyTests) had two siblings the review caught
/// (C2, C4): messages.jsonl and pending-context.md are also shared mutable files
/// hit from multiple threads (and from the app + CLI as separate processes).
/// Pre-fix measurements: 134 of 400 log lines lost, 180 of 200 pending entries lost.
final class ConcurrencyTests: XCTestCase {
    private func makeStore() -> AgentStore {
        AgentStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-cc-\(UUID().uuidString)"))
    }

    /// Review C4: seekToEnd+write let concurrent appends overwrite each other.
    func testConcurrentMessageAppendsAllSurvive() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "r")
        let log = MessageLog(store: store)
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? log.append(ChatMessage(author: "w\(i)", kind: .agent, text: "msg \(i)"),
                            thread: "alfredo")
        }
        let loaded = try log.load(thread: "alfredo")
        XCTAssertEqual(loaded.count, count,
                       "lost \(count - loaded.count) messages to an append race")
        for i in 0..<count {
            XCTAssertTrue(loaded.contains { $0.text == "msg \(i)" }, "msg \(i) missing")
        }
    }

    /// Review C2: unsynchronised add/drain lost entries landing mid-drain.
    func testConcurrentPendingAddsAllSurvive() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "w")
        let pending = PendingContext(store: store)
        let count = 100
        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? pending.add("ENTRY-\(i)", for: "bruno")
        }
        let all = pending.begin(for: "bruno") ?? ""
        for i in 0..<count {
            XCTAssertTrue(all.contains("ENTRY-\(i)"), "ENTRY-\(i) lost to an add race")
        }
    }

    /// Adds racing a begin/commit cycle must never be deleted by the commit:
    /// commit clears only what begin staged (the inflight file), never the
    /// pending file where new adds accumulate.
    func testAddDuringDeliveryIsNotLostToCommit() throws {
        let store = makeStore()
        _ = try store.createAgent(name: "bruno", emoji: "✍️", role: "w")
        let pending = PendingContext(store: store)
        try pending.add("STAGED", for: "bruno")
        let staged = pending.begin(for: "bruno")
        XCTAssertEqual(staged?.contains("STAGED"), true)
        try pending.add("LATE-ARRIVAL", for: "bruno")   // lands mid-delivery
        pending.commit(for: "bruno")                    // clears ONLY the staged part
        let next = pending.begin(for: "bruno")
        XCTAssertEqual(next?.contains("LATE-ARRIVAL"), true,
                       "an add during delivery was destroyed by the commit")
        XCTAssertEqual(next?.contains("STAGED"), false)
    }
}
