import Foundation

/// Append-only, one JSON object per line: crash-safe, human-greppable, and
/// trivially tailable while an agent is mid-answer.
public final class MessageLog {
    private let store: AgentStore
    private let lock: FileLock

    public init(store: AgentStore) {
        self.store = store
        self.lock = FileLock(lockURL: store.rootURL.appendingPathComponent(".messages.lock"))
    }

    /// ISO 8601 WITH fractional seconds. Whole-second precision would collide
    /// timestamps for messages logged in the same second.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return enc
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let d = iso.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unparseable date: \(s)"))
            }
            return d
        }
        return dec
    }

    /// Team threads (R3 2026-08-14) are keyed "#<team>" and live under
    /// <root>/teams/<team>/ — NOT agents/<key>/, which the fences don't seal
    /// for arbitrary keys. nil = an INVALID team key ("#../evil", "#Bad Name"):
    /// append throws, load returns empty — nothing is ever written outside
    /// teams/ via a crafted key.
    private func fileURL(thread: String) -> URL? {
        if thread.hasPrefix("#") {
            let name = String(thread.dropFirst())
            guard AgentStore.isValidName(name) else { return nil }
            return store.teamThreadDir(name).appendingPathComponent("messages.jsonl")
        }
        return store.agentDir(thread).appendingPathComponent("messages.jsonl")
    }

    /// O_APPEND + a single write(2) under the lock (review C4): the previous
    /// `FileHandle(forWritingTo:)` + `seekToEnd()` opened O_WRONLY, so two
    /// concurrent writers read the same end offset and overwrote each other —
    /// measured 134 of 400 lines silently lost. The relay path and the CLI can
    /// both be appending to one thread at the same time.
    public func append(_ msg: ChatMessage, thread: String) throws {
        var line = try Self.encoder().encode(msg)
        line.append(0x0A)
        guard let url = fileURL(thread: thread) else {
            throw AgencyError.invalidName(thread)
        }
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
            }
            defer { close(fd) }
            try line.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                    guard n > 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                      userInfo: [NSLocalizedDescriptionKey: "write to \(url.path) failed"])
                    }
                    offset += n
                }
            }
        }
    }

    public func load(thread: String) throws -> [ChatMessage] {
        guard let url = fileURL(thread: thread) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = Self.decoder()
        return text.split(separator: "\n").compactMap {
            try? dec.decode(ChatMessage.self, from: Data($0.utf8))
        }
    }

    // MARK: session-scoped chats (his ask 2026-08-13 #6)

    /// Rotates the thread's chat into the archive: a FRESH session starts with
    /// an empty visible chat, and the old one becomes a dated, read-only
    /// "previous session". The destination — agents/.archived/threads/ — is
    /// standing-fence-sealed from every agent (the whole point of a fresh
    /// session is that the old conversation is NOT readable from the new one);
    /// the app itself is unfenced and lists/renders it for Lorenzo.
    @discardableResult
    public func archiveThread(_ thread: String, now: Date = Date()) throws -> URL? {
        guard let url = fileURL(thread: thread) else { return nil }
        return try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HHmmss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let dir = store.rootURL.appendingPathComponent("agents/.archived/threads")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(thread)-\(fmt.string(from: now)).jsonl")
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    /// Archived session chats for one agent, newest first. The trailing hyphen
    /// anchors the prefix — "nina-…" never matches "nina2-…".
    public func archivedSessions(for thread: String) -> [URL] {
        let dir = store.rootURL.appendingPathComponent("agents/.archived/threads")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries
            .filter { $0.hasPrefix("\(thread)-") && $0.hasSuffix(".jsonl") }
            .sorted(by: >)
            .map { dir.appendingPathComponent($0) }
    }

    /// Read-only load of one archived session file.
    public static func loadArchive(_ url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap {
            try? dec.decode(ChatMessage.self, from: Data($0.utf8))
        }
    }
}
