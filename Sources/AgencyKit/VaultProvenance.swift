import Foundation
import CryptoKit

/// App-authored provenance for vault writes (security round 2026-08-13, spec
/// rev 2 item 2). The problem it solves: an agent writes vault notes directly
/// inside its own child process, and the persona tells it to stamp
/// `author:`/`created:` frontmatter — but that frontmatter is agent-WRITABLE, so
/// a note can claim "author: lorenzo" or another teammate's name (the very thing
/// Bruno mistook for an attack; the capability is real either way).
///
/// The app is the only trustworthy narrator. It cannot see inside the child, but
/// it knows one thing the agent cannot forge: **which agent's process just ran**.
/// So every file that changed in the vault during a run was written by THAT
/// agent, whatever the frontmatter claims. We diff the vault around each run and
/// append records to a ledger stored OUTSIDE the vault — under the agency root,
/// which no agent's fence can reach (agents write only their own folder + the
/// vault via --add-dir). The ledger, not the in-file `author:`, is the truth.
public struct ProvenanceRecord: Codable, Equatable {
    public var path: String        // relative to the vault root
    public var agent: String       // the process that actually ran — ground truth
    public var at: Date
    public var sha256: String
    public var claimedAuthor: String?   // the in-file `author:` frontmatter, if any
    public var previousAgent: String?   // who the ledger last recorded for this path
    /// This record is a DELETION, not a write (review I3): an agent removing a
    /// note is at least as damaging as overwriting one, and was previously
    /// invisible. `sha256` is empty and there is no `claimedAuthor`.
    public var deleted: Bool?
    /// Another non-forked run was live during this one (review I1). The app
    /// serialises sends only PER THREAD, so two agents can write one vault at
    /// once — a write from run B landing inside run A's snapshot window would be
    /// mis-attributed to A. When that overlap is possible we still RECORD the
    /// write (history is preserved) but never FLAG it: a false forgery
    /// accusation from ordinary two-agent use corrodes the one thing the ledger
    /// is for. Optional so pre-existing ledger lines still decode.
    public var concurrent: Bool?

    private func differs(_ other: String?) -> Bool {
        guard let o = other, !o.isEmpty else { return false }
        return o.caseInsensitiveCompare(agent) != .orderedSame
    }

    /// The running agent overwrote a note the ledger attributes to a DIFFERENT
    /// agent — a cross-agent rewrite, worth surfacing (not necessarily hostile).
    public var isCrossAgentRewrite: Bool { deleted != true && differs(previousAgent) }
    /// A cross-agent DELETION — removing someone else's note.
    public var isCrossAgentDeletion: Bool { deleted == true && differs(previousAgent) }
    /// The note's own `author:` names someone other than the agent that wrote it
    /// — a forged byline ("author: lorenzo" written by bruno). The Bruno-class case.
    public var isAuthorForged: Bool { deleted != true && differs(claimedAuthor) }

    /// Concurrency makes attribution unreliable, so a `concurrent` record is
    /// never treated as suspicious (review I1) — it stays in the ledger, unflagged.
    public var isSuspicious: Bool {
        guard concurrent != true else { return false }
        return isCrossAgentRewrite || isCrossAgentDeletion || isAuthorForged
    }

    /// One line for the thread when a write is suspicious. The refrain is always
    /// the same: the ledger, not the byline, is the truth. Agent-controlled
    /// fields are truncated (review M6) so a hostile 5KB byline can't wreck the
    /// thread or the dedupe key.
    public var humanAlert: String {
        let who = previousAgent ?? "?"
        let byline = Self.clip(claimedAuthor ?? "?")
        let file = Self.clip(path)
        if isCrossAgentDeletion { return "⚠︎ \(agent) deleted \(file), a note last written by \(who). The vault ledger keeps the record." }
        switch (isCrossAgentRewrite, isAuthorForged) {
        case (true, true):
            return "⚠︎ \(agent) overwrote \(file) (last written by \(who)) and stamped it “author: \(byline)” — the vault ledger records \(agent) as the real writer, not the byline."
        case (true, false):
            return "⚠︎ \(agent) overwrote \(file), a note last written by \(who). The vault ledger keeps the real history."
        case (false, true):
            return "⚠︎ \(agent) wrote \(file) but stamped it “author: \(byline)”. Trust the vault ledger (\(agent) wrote it), not the in-file byline."
        case (false, false):
            return ""
        }
    }

    static func clip(_ s: String, _ n: Int = 80) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}

/// A cheap pre-hash fingerprint: a file is a write candidate if it is new or its
/// (size, mtime) changed since the snapshot. Only candidates get hashed.
public struct FileFingerprint: Equatable {
    public var size: Int
    public var mtime: TimeInterval
}

public final class VaultProvenance {
    public let vaultURL: URL
    private let ledgerURL: URL
    private let lock: FileLock

    /// Ledger lives under the agency ROOT, a sibling of vault/ — OUTSIDE the vault
    /// so a FILE-TOOL-fenced agent cannot reach it: --add-dir grants only the
    /// vault to Read/Write/Edit, and those tools don't escape cwd + added dirs.
    /// SCOPE (review C1): --add-dir fences file tools, NOT Bash. A shell-granted
    /// agent can `rm`/`sed -i`/`touch -r` this file like any path the user can
    /// reach — the ledger is trustworthy for NON-shell agents; for shell agents
    /// it is part of the shell grant's accepted residual, closed only by the
    /// client-side sandbox (next round). The leading dot keeps it out of Obsidian.
    public init(rootURL: URL) {
        self.vaultURL = rootURL.appendingPathComponent("vault")
        self.ledgerURL = rootURL.appendingPathComponent(".provenance.jsonl")
        self.lock = FileLock(lockURL: rootURL.appendingPathComponent(".provenance.lock"))
    }

    // MARK: snapshot / commit

    /// Fingerprints every regular file under the vault (recursively), skipping
    /// dotfiles and dot-directories (.obsidian, .trash…). Cheap: stat only.
    public func snapshot() -> [String: FileFingerprint] {
        var out: [String: FileFingerprint] = [:]
        // Resolve symlinks on BOTH sides: the enumerator yields /private/var/…
        // for temp dirs while vaultURL.path is /var/… — without this the base
        // never strips and every path is recorded absolute (and never matches
        // across runs). Harmless where there is no symlink (production vault).
        let base = vaultURL.resolvingSymlinksInPath().path
        // Do NOT skip hidden files (review M1): an agent could otherwise write
        // `.secret.md` to escape provenance entirely. We enumerate everything and
        // only prune known machine dirs (large + not agent notes) by name.
        let skipDirs: Set<String> = [".obsidian", ".trash", ".git", ".DS_Store"]
        guard let en = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []) else { return out }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if vals?.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard vals?.isRegularFile == true else { continue }
            let rel = relativePath(of: url.resolvingSymlinksInPath().path, under: base)
            out[rel] = FileFingerprint(size: vals?.fileSize ?? 0,
                                       mtime: vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return out
    }

    /// Diffs the vault against `previous`, records every new/changed file as
    /// written by `agent` at `now`, and returns the fresh records (so the caller
    /// can surface suspicious ones). `now` is injected — scripts/tests can't call
    /// Date() and the runner passes the real clock.
    @discardableResult
    public func commit(previous: [String: FileFingerprint], by agent: String,
                       now: Date = Date(), concurrent: Bool = false) -> [ProvenanceRecord] {
        let current = snapshot()
        var changed: [String] = []
        for (rel, fp) in current where previous[rel] != fp { changed.append(rel) }
        // Deletions (review I3): a file that WAS in the vault and is gone now.
        let deletedPaths = Set(previous.keys).subtracting(current.keys)
        guard !changed.isEmpty || !deletedPaths.isEmpty else { return [] }
        let flag: Bool? = concurrent ? true : nil

        return lock.withLock {
            let existing = loadRecordsUnlocked()
            var lastByPath: [String: String] = [:]
            for r in existing where r.deleted != true { lastByPath[r.path] = r.agent }

            var fresh: [ProvenanceRecord] = []
            for rel in changed.sorted() {
                let fileURL = vaultURL.appendingPathComponent(rel)
                // Vault hygiene: stamp BEFORE hashing so the ledger records the
                // final bytes (the app is the trustworthy narrator — extending
                // that to the one frontmatter field agents kept forgetting).
                Self.stampUpdated(at: fileURL, now: now)
                fresh.append(ProvenanceRecord(
                    path: rel, agent: agent, at: now,
                    sha256: Self.hash(of: fileURL),
                    claimedAuthor: Self.claimedAuthor(in: fileURL),
                    previousAgent: lastByPath[rel], concurrent: flag))
            }
            for rel in deletedPaths.sorted() {
                fresh.append(ProvenanceRecord(
                    path: rel, agent: agent, at: now, sha256: "",
                    claimedAuthor: nil, previousAgent: lastByPath[rel],
                    deleted: true, concurrent: flag))
            }
            appendUnlocked(fresh)
            return fresh
        }
    }

    /// Team pockets are multi-writer BY DESIGN (vault pockets spec 2026-08-13):
    /// a member editing a fellow member's note is collaboration, not a breach —
    /// and a false accusation from ordinary teamwork corrodes the one thing the
    /// ledger is for (the review-I1 principle, again). So cross-agent rewrite
    /// and deletion ALERTS are suppressed inside a team pocket when BOTH agents
    /// are members. The ledger record itself is kept unchanged, and a forged
    /// BYLINE still flags — forgery is forgery, teammates or not.
    public static func isTeamCollaboration(_ r: ProvenanceRecord, teams: [Team]) -> Bool {
        guard !r.isAuthorForged else { return false }
        let parts = r.path.split(separator: "/")
        guard parts.count >= 2, parts.first == "teams" else { return false }
        guard let team = teams.first(where: { $0.name == String(parts[1]) }) else { return false }
        guard let prev = r.previousAgent else { return false }
        return team.members.contains(r.agent) && team.members.contains(prev)
    }

    /// A record landing INSIDE someone else's pocket is a fence breach
    /// regardless of history (pocket review I2): a NEW file there has
    /// previousAgent == nil, so every rewrite-based flag stays silent — the
    /// exact class of write the ledger exists to catch. Suspicious when the
    /// path is another agent's private pocket, or a team pocket the writer is
    /// not a member of (an UNREGISTERED teams/ dir counts: nobody creates
    /// pockets by hand except Lorenzo). Concurrent records are never flagged —
    /// attribution is unreliable and a false breach accusation is worse than
    /// a missed alert (the review-I1 principle).
    public static func isPocketBreach(_ r: ProvenanceRecord, teams: [Team]) -> Bool {
        guard r.concurrent != true else { return false }
        let parts = r.path.split(separator: "/")
        guard parts.count >= 2 else { return false }
        if parts[0] == "private" {
            return String(parts[1]).caseInsensitiveCompare(r.agent) != .orderedSame
        }
        if parts[0] == "teams" {
            guard let team = teams.first(where: { $0.name == String(parts[1]) }) else { return true }
            return !team.members.contains(r.agent)
        }
        return false
    }

    /// The thread line for a pocket breach. Same refrain as humanAlert: the
    /// ledger, not the write, is the truth.
    public static func pocketBreachAlert(_ r: ProvenanceRecord) -> String {
        let verb = r.deleted == true ? "deleted" : "wrote"
        return "⚠︎ \(r.agent) \(verb) \(ProvenanceRecord.clip(r.path)) — inside a pocket it does not own. "
            + "That is a fence breach; the vault ledger keeps the record."
    }

    // MARK: query (the app's trustworthy narrator)

    /// The last recorded writer of a note — what the app trusts over `author:`.
    public func latest(for relativePath: String) -> ProvenanceRecord? {
        lock.withLock { loadRecordsUnlocked().last { $0.path == relativePath } }
    }

    public func history(for relativePath: String) -> [ProvenanceRecord] {
        lock.withLock { loadRecordsUnlocked().filter { $0.path == relativePath } }
    }

    public func allRecords() -> [ProvenanceRecord] {
        lock.withLock { loadRecordsUnlocked() }
    }

    // MARK: internals

    // NOTE (review M3): every commit/latest/history decodes the WHOLE ledger —
    // O(total history) per send, no rotation. Fine at a personal team's volume;
    // if the ledger ever grows large, rotate or index by path before it bites.
    private func loadRecordsUnlocked() -> [ProvenanceRecord] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? dec.decode(ProvenanceRecord.self, from: Data(line.utf8))
        }
    }

    private func appendUnlocked(_ records: [ProvenanceRecord]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        // Each record is ONE JSON line — appends never rewrite prior history,
        // so a crash mid-run can lose at most the current run's records.
        var blob = ""
        for r in records {
            guard let d = try? enc.encode(r), let s = String(data: d, encoding: .utf8) else { continue }
            blob += s + "\n"
        }
        guard let out = blob.data(using: .utf8), !out.isEmpty else { return }
        // POSIX O_APPEND for BOTH create and extend (review M2): the previous
        // FileHandle-or-.atomic fallback would REPLACE the whole append-only
        // ledger with just this run's records if the handle open failed for any
        // reason other than "missing" (read-only file, etc.). Never do that.
        let fd = open(ledgerURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            fputs("agency: WARNING cannot append provenance ledger (errno \(errno)) — record dropped\n", stderr)
            return
        }
        defer { close(fd) }
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Stamps `updated:` in a note's YAML frontmatter (vault hygiene, from the
    /// coordinator's 2026-08-13 report). The app knows precisely which notes a
    /// run changed, so it stamps them itself instead of trusting every agent to
    /// remember — an unbumped stamp already cost real work (bruno read it as a
    /// tampering signal and wrote from superseded material).
    ///
    /// Conservative by construction: Markdown only, frontmatter must exist AND
    /// be properly terminated, `created:` is never touched, body bytes are
    /// never reflowed. Returns whether it wrote.
    @discardableResult
    public static func stampUpdated(at url: URL, now: Date = Date()) -> Bool {
        guard url.pathExtension.lowercased() == "md",
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        // Normalise for PARSING only; the written text keeps the original style.
        let crlf = raw.contains("\r\n")
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        // A block that never closes is not frontmatter — don't guess.
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return false }

        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone.current
        fmt.formatOptions = [.withInternetDateTime]
        let stamp = "updated: \(fmt.string(from: now))"
        if let i = lines[1..<close].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("updated:")
        }) {
            lines[i] = stamp
        } else {
            lines.insert(stamp, at: close)   // last field in the block
        }
        var out = lines.joined(separator: "\n")
        if crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        guard out != raw, (try? out.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }
        return true
    }

    static func hash(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the `author:` value from leading YAML frontmatter, if present.
    /// Deliberately forgiving: the point is to catch a byline the agent SET, so
    /// any `author:` in the first frontmatter block counts.
    static func claimedAuthor(in url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Normalise CRLF/CR first (review M4): a `\r` left on the line made every
        // CRLF frontmatter miss, so a forged byline in a Windows/Obsidian note
        // slipped through unflagged.
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if t.lowercased().hasPrefix("author:") {
                let v = Self.cleanYAMLScalar(String(t.dropFirst("author:".count)))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Unwraps a YAML scalar the way honest tooling writes it (review I4): quoted
    /// values (`author: "bruno"` — Obsidian's default) unquote to `bruno` so they
    /// stop reading as forgeries, and an unquoted trailing `# comment` is dropped.
    static func cleanYAMLScalar(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if let q = v.first, q == "\"" || q == "'" {
            if let end = v.dropFirst().firstIndex(of: q) {
                return String(v[v.index(after: v.startIndex)..<end])
            }
            return String(v.dropFirst())   // unterminated quote — drop the opener
        }
        if let hash = v.firstIndex(of: "#") {
            return String(v[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return v
    }

    private func relativePath(of path: String, under base: String) -> String {
        var p = path
        if p.hasPrefix(base) { p.removeFirst(base.count) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
