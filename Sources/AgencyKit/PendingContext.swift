import Foundation

/// A teammate's inbox of material handed to it by another agent.
///
/// Why this exists: `HandoffBroker` sends the question to the TARGET's session, so
/// the reply lands in the target's context — never the asker's. Writing it to the
/// asker's message log makes it visible to Lorenzo and to the UI, but the asker
/// agent itself would still not know what it received. It parks the text here
/// instead, and `SessionRunner` folds it into the asker's very next prompt, so the
/// handoff costs no extra Claude call — it rides along with a message that was
/// going to be sent anyway.
///
/// Delivery is two-phase (review C1): `begin` STAGES the material into an inflight
/// file and `commit` deletes it only after the send actually succeeded. A failed
/// launch (binary missing, not logged in, plan limit) leaves the inflight file in
/// place, and the next `begin` picks it up again — the handoff payload survives
/// failed sends instead of being destroyed by them.
///
/// All operations are serialised by a FileLock (review C2): add/begin/commit are
/// read-modify-write sequences, and an unsynchronised `add` landing between a
/// peek and a delete used to be lost outright (measured: 180 of 200 entries).
public final class PendingContext {
    private let store: AgentStore
    private let lock: FileLock

    public init(store: AgentStore) {
        self.store = store
        self.lock = FileLock(lockURL: store.rootURL.appendingPathComponent(".pending.lock"))
    }

    private func pendingURL(_ name: String) -> URL {
        store.agentDir(name).appendingPathComponent("pending-context.md")
    }
    private func inflightURL(_ name: String) -> URL {
        store.agentDir(name).appendingPathComponent("pending-context.inflight.md")
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url)) ?? ""
    }

    public func add(_ text: String, for name: String) throws {
        // Team keys have no session to park anything for (R3): a "#" name here
        // would silently mint agents/#<team>/ — refuse loudly instead. Cheap
        // insurance for future call sites; nothing calls it this way today.
        guard !name.hasPrefix("#") else {
            fputs("agency: PendingContext.add called with team key \(name) — ignored (no session exists)\n",
                  stderr)
            return
        }
        try lock.withLock {
            let dir = store.agentDir(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = read(pendingURL(name))
            try (existing + text + "\n\n").write(to: pendingURL(name), atomically: true, encoding: .utf8)
        }
    }

    /// Everything currently parked for `name` — pending AND staged-but-undelivered.
    public func peek(for name: String) -> String? {
        lock.withLock {
            let all = read(inflightURL(name)) + read(pendingURL(name))
            return all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : all
        }
    }

    /// Stages all parked material (including anything left by a previously FAILED
    /// delivery) for injection into the next prompt. Cleared only by `commit`.
    public func begin(for name: String) -> String? {
        lock.withLock {
            let all = read(inflightURL(name)) + read(pendingURL(name))
            guard !all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            do {
                try FileManager.default.createDirectory(at: store.agentDir(name),
                                                        withIntermediateDirectories: true)
                try all.write(to: inflightURL(name), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: pendingURL(name))
            } catch {
                // Staging failed — leave everything where it was; inject nothing.
                return nil
            }
            return all
        }
    }

    /// The send that carried the staged material succeeded — it is delivered.
    public func commit(for name: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: inflightURL(name))
        }
    }
}
