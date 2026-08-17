import XCTest
@testable import AgencyKit

final class SendQueueTests: XCTestCase {
    private func msg(_ text: String) -> ChatMessage {
        ChatMessage(author: "lorenzo", kind: .user, text: text)
    }

    func testFIFOOrderWithinAThread() {
        var q = SendQueue()
        q.enqueue(msg("first"), thread: "alfredo")
        q.enqueue(msg("second"), thread: "alfredo")
        q.enqueue(msg("third"), thread: "alfredo")
        XCTAssertEqual(q.dequeue("alfredo")?.text, "first")
        XCTAssertEqual(q.dequeue("alfredo")?.text, "second")
        XCTAssertEqual(q.dequeue("alfredo")?.text, "third")
        XCTAssertNil(q.dequeue("alfredo"))
    }

    func testThreadsAreIsolated() {
        var q = SendQueue()
        q.enqueue(msg("for-a"), thread: "alfredo")
        q.enqueue(msg("for-b"), thread: "bruno")
        XCTAssertEqual(q.dequeue("bruno")?.text, "for-b")
        XCTAssertNil(q.peek("bruno"))
        XCTAssertEqual(q.peek("alfredo")?.text, "for-a")
        XCTAssertEqual(q.threads, ["alfredo"])
    }

    func testPeekDoesNotConsume() {
        var q = SendQueue()
        q.enqueue(msg("stay"), thread: "nina")
        XCTAssertEqual(q.peek("nina")?.text, "stay")
        XCTAssertEqual(q.items(for: "nina").count, 1)
    }

    func testRemoveByIDCancelsOneMessage() {
        var q = SendQueue()
        let doomed = msg("cancel me")
        q.enqueue(msg("keep"), thread: "nina")
        q.enqueue(doomed, thread: "nina")
        q.remove(id: doomed.id, thread: "nina")
        XCTAssertEqual(q.items(for: "nina").map(\.text), ["keep"])
    }

    func testEmptiedThreadDisappearsFromThreads() {
        var q = SendQueue()
        let m = msg("only")
        q.enqueue(m, thread: "nina")
        q.remove(id: m.id, thread: "nina")
        XCTAssertEqual(q.threads, [])
    }
}
