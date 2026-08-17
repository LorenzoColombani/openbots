import Foundation

/// Per-thread FIFO of messages typed while a teammate was busy. Strictly
/// ordered — the head is never skipped, because delivering Lorenzo's messages
/// out of order would silently reorder a conversation. DURABLE since
/// 2026-08-13 (Grok Bot's send-journal pattern, reviewer #5's gap): the app
/// persists it on every change and re-delivers after a relaunch — quitting
/// with queued messages no longer loses them. Restored agent-relay items lose
/// their chain depth (rides in-memory) and restart at 0 — acceptable: depth
/// only guards runaway loops.
public struct SendQueue: Equatable, Codable {
    private var queues: [String: [ChatMessage]] = [:]

    public init() {}

    public var isEmpty: Bool { queues.isEmpty }

    /// Total waiting messages across all threads (drives the restore bar).
    public var totalCount: Int { queues.values.reduce(0) { $0 + $1.count } }

    /// Atomic persist; an empty queue removes the file. A durability promise
    /// that fails must SAY so (reviewer #6; house style: FileLock/lock
    /// degradation warn on stderr too).
    public func save(to url: URL) {
        if queues.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            fputs("agency: WARNING queue journal write failed (\(error.localizedDescription)) — queued messages will NOT survive a quit\n", stderr)
        }
    }

    public static func load(from url: URL) -> SendQueue {
        guard FileManager.default.fileExists(atPath: url.path) else { return SendQueue() }
        do {
            return try JSONDecoder().decode(SendQueue.self, from: Data(contentsOf: url))
        } catch {
            fputs("agency: WARNING queue journal unreadable (\(error.localizedDescription)) — its messages could not be restored\n", stderr)
            return SendQueue()
        }
    }

    /// Threads that currently have something waiting, stable order.
    public var threads: [String] { queues.keys.sorted() }

    public func items(for thread: String) -> [ChatMessage] { queues[thread] ?? [] }

    public func peek(_ thread: String) -> ChatMessage? { queues[thread]?.first }

    public mutating func enqueue(_ message: ChatMessage, thread: String) {
        queues[thread, default: []].append(message)
    }

    /// Removes and returns the head. FIFO only — there is deliberately no
    /// "dequeue the first sendable" variant.
    @discardableResult
    public mutating func dequeue(_ thread: String) -> ChatMessage? {
        guard var q = queues[thread], !q.isEmpty else { return nil }
        let head = q.removeFirst()
        queues[thread] = q.isEmpty ? nil : q
        return head
    }

    /// Cancel one queued message (the ✕ on its bubble).
    public mutating func remove(id: UUID, thread: String) {
        guard var q = queues[thread] else { return }
        q.removeAll { $0.id == id }
        queues[thread] = q.isEmpty ? nil : q
    }
}
