import Foundation

/// Group threads (R3 2026-08-14, structure audit N4 — Grok Bot's model):
/// Lorenzo addresses 2–6 members in ONE thread; every reply and handoff is
/// visible there. Members have independent claude sessions, so "a group chat"
/// is made real by DELTAS: each member's group turn carries the transcript
/// slice since that member's last group turn. No manager slot — "single owner
/// per stage" is persona guidance (xAI's own failure-mode warning).
///
/// Kit-side (the QueueScheduler precedent): everything here is pure or
/// file-backed and unit-tested; the app supplies the concurrency.
public enum TeamThreads {
    /// "#" is outside isValidName's alphabet, so a team key can never collide
    /// with an agent handle in the string-keyed app state.
    public static func key(for team: String) -> String { "#" + team }
    public static func isTeamKey(_ thread: String) -> Bool { thread.hasPrefix("#") }
    /// nil for a key whose team part is not a legal name — callers refuse it.
    public static func teamName(fromKey thread: String) -> String? {
        guard thread.hasPrefix("#") else { return nil }
        let name = String(thread.dropFirst())
        return AgentStore.isValidName(name) ? name : nil
    }
}

/// Per-member read cursors for one team's transcript — the index AFTER the
/// last message that member has been shown. Persisted at
/// <root>/teams/<team>/.cursors.json under the shared cursors lock.
public final class TeamCursorStore {
    private let url: URL
    private let lock: FileLock

    public init(store: AgentStore, team: String) {
        self.url = store.teamThreadDir(team).appendingPathComponent(".cursors.json")
        self.lock = FileLock(lockURL: store.rootURL.appendingPathComponent(".cursors.lock"))
    }

    private func loadUnlocked() -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return obj
    }

    private func saveUnlocked(_ cursors: [String: Int]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cursors) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// nil = the member has never been shown anything (late joiner / lost
    /// file) — the delta rule then delivers ONLY the newest message, never the
    /// whole history (token bomb; and a lost cursor file must not re-send it).
    public func cursor(for member: String) -> Int? {
        lock.withLock { loadUnlocked()[member] }
    }

    /// MONOTONIC: a stale concurrent write can never move a member backwards
    /// (a regressed cursor re-delivers content as if new).
    public func advance(_ member: String, to index: Int) {
        lock.withLock {
            var c = loadUnlocked()
            c[member] = max(c[member] ?? 0, index)
            saveUnlocked(c)
        }
    }

    /// Eager init at createTeam/addTeamMember time: the member starts at the
    /// CURRENT end of log, so the missing-cursor fallback stays exceptional.
    public func initialize(member: String, at index: Int) {
        lock.withLock {
            var c = loadUnlocked()
            guard c[member] == nil else { return }
            c[member] = index
            saveUnlocked(c)
        }
    }

    /// A removed member's cursor is forgotten (review minor): re-adding them
    /// later makes them a LATE JOINER — new-messages-only — not someone
    /// silently back-filled from where they left off.
    public func remove(member: String) {
        lock.withLock {
            var c = loadUnlocked()
            c[member] = nil
            saveUnlocked(c)
        }
    }

    /// Archive path: a fresh transcript starts everyone at zero.
    public func reset() {
        lock.withLock { saveUnlocked([:]) }
    }
}

/// Builds one member's group turn from the transcript.
public enum GroupPrompt {
    public struct Delta: Equatable {
        /// Messages to show, oldest first.
        public let included: [ChatMessage]
        /// Index AFTER the last message covered by this delta — what the
        /// cursor advances to IF the member's reply lands. Never the live end
        /// of log: replies landing mid-run must ride the NEXT delta.
        public let upTo: Int
        /// True when the member had no cursor (joined now / cursor lost).
        public let joinedNow: Bool
    }

    /// Content rules (his call, question round 2026-08-14):
    /// - include Lorenzo's .user messages, OTHER members' .agent replies, and
    ///   .system notes;
    /// - exclude the member's own-authored messages (its session has them);
    /// - exclude .relayOut/.relayIn (mirrored handoff legs): the participants
    ///   already have that content — the asker via its parked reply, the
    ///   target via its session — so inclusion GUARANTEES duplicates, and his
    ///   ruling was outcomes-only for everyone else.
    /// - missing cursor → only the newest message, flagged joinedNow;
    /// - a stale cursor beyond the log (post-archive) clamps safely.
    public static func delta(log: [ChatMessage], cursor: Int?, member: String) -> Delta {
        let end = log.count
        guard let cursor else {
            let last = log.suffix(1).filter { include($0, member: member) }
            return Delta(included: Array(last), upTo: end, joinedNow: true)
        }
        let start = min(max(cursor, 0), end)
        let slice = log[start..<end].filter { include($0, member: member) }
        return Delta(included: Array(slice), upTo: end, joinedNow: false)
    }

    private static func include(_ m: ChatMessage, member: String) -> Bool {
        switch m.kind {
        case .relayOut, .relayIn: return false
        case .user, .system, .subagent: return true
        case .agent: return m.author != member
        }
    }

    /// The group-turn prompt contract — the personas teach this exact shape.
    /// The delta is computed AFTER Lorenzo's new message is appended, so the
    /// newest .user message in `included` IS the message being answered —
    /// split structurally, never by text matching. `display` maps handles to
    /// display names (Riker, not teammate2).
    public static func render(team: Team, member: String, delta: Delta,
                              display: (String) -> String) -> String {
        let others = team.members.filter { $0 != member }.map { "@" + $0 }
        var out = """
        [Group thread #\(team.name) — members: \(others.joined(separator: ", ")) and you. \
        Lorenzo is addressing the whole group; your reply is posted to the group thread \
        for everyone (keep it focused — every member reads it).]
        """
        if delta.joinedNow {
            out += "\n(You joined this group thread now — earlier discussion is not carried; ask if you need it.)"
        }
        var history = delta.included
        let newest = history.last?.kind == .user ? history.removeLast() : nil
        if !history.isEmpty {
            out += "\n\n[Messages since your last group turn:]"
            for m in history {
                let who = m.author == "lorenzo" ? "Lorenzo"
                    : m.kind == .system ? "app" : display(m.author)
                out += "\n[\(who)] \(m.text)"
            }
        }
        if let newest {
            out += "\n\n[New message from Lorenzo to the group:]\n\(newest.text)"
        }
        return out
    }
}

/// The dispatch rule, pure so QueueScheduler stays untouched: a team key is
/// effectively BUSY while any member is busy, forking, or already awaited by
/// another thread — a group send must never launch against a member who is
/// mid-fork or about to receive a relay reply.
public enum GroupDispatch {
    public static func effectiveBusy(busy: Set<String>, forking: Set<String>,
                                     awaiting: [String: Set<String>],
                                     teams: [Team]) -> Set<String> {
        var out = busy
        let awaited = awaiting.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let unavailable = busy.union(forking).union(awaited)
        for t in teams where t.members.contains(where: unavailable.contains) {
            out.insert(TeamThreads.key(for: t.name))
        }
        return out
    }
}
