import XCTest
@testable import AgencyKit

final class HandoffBrokerTests: XCTestCase {
    func testRelayLogsBothSidesAndReturnsReply() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-hb-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        let alfredo = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "research")
        let bruno = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let mock = MockProcess(lines: [
            #"{"type":"system","subtype":"init","session_id":"sid-a"}"#,
            #"{"type":"result","subtype":"success","result":"Alfredo: the answer is 42","session_id":"sid-a"}"#,
        ])
        let runner = SessionRunner(store: store, process: mock)
        let log = MessageLog(store: store)
        let broker = HandoffBroker(store: store, runner: runner, log: log)

        let reply = try await broker.relay(question: "what is the answer?", from: bruno, to: alfredo)
        XCTAssertEqual(reply, "Alfredo: the answer is 42")

        let brunoThread = try log.load(thread: "bruno")
        // The trailing .system leg is the parked-reply receipt (audit I6):
        // "reply parked — bruno reads it next turn" — the previously invisible leg.
        XCTAssertEqual(brunoThread.map(\.kind), [.relayOut, .relayIn, .system])
        XCTAssertEqual(brunoThread[0].author, "bruno")
        XCTAssertEqual(brunoThread[1].author, "alfredo")
        XCTAssertTrue(brunoThread[2].text.contains("reply parked"))

        let alfredoThread = try log.load(thread: "alfredo")
        XCTAssertEqual(alfredoThread.map(\.kind), [.relayIn, .relayOut])  // question in, answer out
    }

    /// Observability rule: the FULL text of both sides must be recoverable from the
    /// logs — never collapsed into a "handoff happened" marker.
    func testFullExchangeTextIsPreservedInBothThreads() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agency-hb-\(UUID().uuidString)")
        let store = AgentStore(rootURL: tmp)
        let alfredo = try store.createAgent(name: "alfredo", emoji: "🧑‍🍳", role: "research")
        let bruno = try store.createAgent(name: "bruno", emoji: "✍️", role: "writer")
        let mock = MockProcess(lines: [
            #"{"type":"result","subtype":"success","result":"Alfredo: brewing notes are in vault/coffee.md","session_id":"sid-a"}"#,
        ])
        let broker = HandoffBroker(store: store,
                                   runner: SessionRunner(store: store, process: mock),
                                   log: MessageLog(store: store))
        let log = MessageLog(store: store)
        _ = try await broker.relay(question: "where are the brewing notes?", from: bruno, to: alfredo)

        let bothThreads = try log.load(thread: "bruno") + log.load(thread: "alfredo")
        // the question survives verbatim in both threads
        XCTAssertEqual(bothThreads.filter { $0.text.contains("where are the brewing notes?") }.count, 2)
        // so does the answer
        XCTAssertEqual(bothThreads.filter { $0.text.contains("vault/coffee.md") }.count, 2)
        // every entry is attributed and timestamped
        XCTAssertTrue(bothThreads.allSatisfy { !$0.author.isEmpty })
        XCTAssertTrue(bothThreads.allSatisfy { $0.ts.timeIntervalSince1970 > 0 })
    }
}
