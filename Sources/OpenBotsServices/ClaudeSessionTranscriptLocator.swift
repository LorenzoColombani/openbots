import Foundation

/// Where the CLI keeps a session it may resume: `<profile>/projects/<folder>/<id>.jsonl`,
/// the folder named after the working directory of the turn that started it.
/// The CLI finds a session by id whatever the current folder (probed on
/// 2.1.272), so the check looks one level down every
/// project folder.
public enum ClaudeSessionTranscriptLocator {
    /// Whether a project folder under the profile holds the session's
    /// transcript: a regular file by that name, never a link standing in for
    /// it, which could point anywhere. A
    /// folder that cannot be read answers no: a caller that then replaces the
    /// session's row removes what is left of it first, and that removal throws
    /// on the same folder, so the row stays.
    public static func exists(profileURL: URL, sessionID: UUID) -> Bool {
        let name = Array((sessionID.uuidString.lowercased() + ".jsonl").utf8CString)
        guard let projects = try? projectsFolder(in: profileURL), let names = try? projectNames(in: projects) else {
            return false
        }
        return names.contains { folderName in
            guard let folder = try? projects.folder(named: folderName) else { return false }
            return (try? folder.kind(of: name)) == S_IFREG
        }
    }

    /// The CLI's `projects` folder under the profile, when it is a real
    /// folder. A symbolic link in place of `projects` or of one of its folders
    /// is never followed, so nothing outside `<profile>/projects/` is taken for
    /// a session's file, and nothing there is removed with one. Nothing there
    /// is nil; a folder that is there but cannot be read throws, because
    /// taking it for an empty one would clear a session's row with its files
    /// still on disk.
    private static func projectsFolder(in profileURL: URL) throws -> HeldFolder? {
        try HeldFolder.open(profileURL.appendingPathComponent("projects", isDirectory: true))
    }

    /// The names in `projects`, hidden ones left out as they always were.
    private static func projectNames(in projects: HeldFolder) throws -> [[CChar]] {
        try projects.names().filter { $0.first != CChar(UInt8(ascii: ".")) }
    }

    public static let existsInProfile: @Sendable (URL, UUID) -> Bool = { profileURL, sessionID in
        exists(profileURL: profileURL, sessionID: sessionID)
    }

    /// Removes what the CLI kept of one session under the profile: its
    /// transcript in every project folder, the session's own folder beside it
    /// (its helpers' transcripts), and its lines in `history.jsonl`, which is
    /// rewritten through a temporary file and one rename. Every folder is
    /// tried before the first failure is thrown, so one stuck file does not
    /// keep the rest. A profile with none of it is left exactly as found.
    /// Only a name that is not there counts as nothing to remove: a folder or
    /// an entry that cannot be read is a failure, never an empty result.
    ///
    /// Everything is removed through the descriptor of the project folder that
    /// was checked, and a session's own folder is walked the same way, each
    /// level opened without following a link: a folder swapped for a link
    /// after the look cannot carry a removal out of the profile, and a link is
    /// removed as a link, never what it points at (the removal once resolved
    /// the path again).
    public static func remove(profileURL: URL, sessionID: UUID) throws -> ClaudeSessionTranscriptRemoval {
        let id = sessionID.uuidString.lowercased()
        var removed: [String] = []
        var failure: (any Error)?
        do {
            if let projects = try projectsFolder(in: profileURL) {
                for folderName in try projectNames(in: projects) {
                    do {
                        guard let folder = try projects.folder(named: folderName) else { continue }
                        var tookSomething = false
                        for name in [id + ".jsonl", id] {
                            do {
                                if try folder.removeEntry(named: Array(name.utf8CString)) {
                                    removed.append(folder.url.appendingPathComponent(name).path)
                                    tookSomething = true
                                }
                            } catch { failure = failure ?? error }
                        }
                        // One folder per turn's working folder, so most hold one
                        // session: left empty, it goes too (empty ones were
                        // once left behind). Only one this removal took
                        // from, and only while empty.
                        if tookSomething { projects.removeIfEmpty(named: folderName) }
                    } catch { failure = failure ?? error }
                }
            }
        } catch { failure = failure ?? error }
        var dropped = 0
        do { dropped = try dropHistoryLines(of: id, in: profileURL.appendingPathComponent("history.jsonl")) }
        catch { failure = failure ?? error }
        if let failure { throw failure }
        return ClaudeSessionTranscriptRemoval(removedPaths: removed, droppedHistoryLines: dropped)
    }

    public static let removeFromProfile: @Sendable (URL, UUID) throws -> ClaudeSessionTranscriptRemoval = { profileURL, sessionID in
        try remove(profileURL: profileURL, sessionID: sessionID)
    }

    /// `history.jsonl` is one JSON object per line, each naming its
    /// `sessionId`. The session's lines go; every other byte stays, a line
    /// that is not JSON included, and the file keeps its mode. Nothing is
    /// written when no line belongs to the session.
    ///
    /// The file is shared by every session in the profile, and the rewrite
    /// reads, filters and renames, so a line another writer appends between
    /// the read and the rename would be lost. The app's own rewrites take one
    /// lock, so two drops (a reply turn and a bot's deletion) cannot undo each
    /// other. The CLI takes no part in it, and needs none today: with resume on,
    /// turns that kept their session on 2.1.278 left no `history.jsonl` in the app's profile at all, since the
    /// CLI keeps prompt history for interactive sessions and the app runs
    /// `--print`. A CLI that starts writing it in print mode brings the race
    /// with a running turn back.
    ///
    /// Only a regular file is read and rewritten. The name is opened without
    /// following a link, and the kind, the mode and the bytes all come from
    /// that one descriptor, so a link standing in for the file (to anywhere)
    /// is neither read through nor replaced: the removal throws, which keeps
    /// the session's row, rather than reporting its lines as gone (the link
    /// was once replaced by a 0755 regular copy).
    private static let historyRewrite = NSLock()

    private static func dropHistoryLines(of id: String, in historyURL: URL) throws -> Int {
        try historyRewrite.withLock { try rewriteHistory(dropping: id, in: historyURL) }
    }

    private static func rewriteHistory(dropping id: String, in historyURL: URL) throws -> Int {
        let manager = FileManager.default
        let descriptor = open(historyURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return 0 }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EFTYPE) }
        let mode = Int(status.st_mode & 0o777)
        let data = try handle.readToEnd() ?? Data()
        let newline = UInt8(ascii: "\n")
        // Empty pieces are kept so a trailing newline survives the round trip.
        let pieces = data.split(separator: newline, omittingEmptySubsequences: false)
        let kept = pieces.filter { !historyLine($0, belongsTo: id) }
        let dropped = pieces.count - kept.count
        guard dropped > 0 else { return 0 }
        let temporary = historyURL.deletingLastPathComponent()
            .appendingPathComponent(".history.jsonl.\(UUID().uuidString.lowercased()).tmp")
        let rewritten = Data(kept.joined(separator: [newline]))
        guard manager.createFile(atPath: temporary.path, contents: rewritten, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, historyURL.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return dropped
    }

    private static func historyLine(_ line: Data, belongsTo id: String) -> Bool {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let session = object["sessionId"] as? String else { return false }
        return session.lowercased() == id
    }
}

/// A folder held open by descriptor, opened without following a link at its
/// own name, so every name looked up through it is inside that very folder.
/// Only a name that is not there reads as absent; any other failure throws.
private final class HeldFolder {
    let descriptor: Int32
    let url: URL

    private init(descriptor: Int32, url: URL) { self.descriptor = descriptor; self.url = url }
    deinit { close(descriptor) }

    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The real folder at `url`; nil when nothing is there, or when a link or
    /// a file stands in its place.
    static func open(_ url: URL) throws -> HeldFolder? {
        try held(Darwin.open(url.path, flags), url: url)
    }

    /// The real folder by that name inside this one; nil as for `open`.
    func folder(named name: [CChar]) throws -> HeldFolder? {
        // The URL is for reporting; every call on the disk uses the bytes.
        let shown = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return try Self.held(openat(descriptor, name, Self.flags),
                             url: url.appendingPathComponent(shown, isDirectory: true))
    }

    private static func held(_ descriptor: Int32, url: URL) throws -> HeldFolder? {
        if descriptor >= 0 { return HeldFolder(descriptor: descriptor, url: url) }
        let code = errno
        // Nothing by that name, a link in its place (O_NOFOLLOW), or a file.
        if code == ENOENT || code == ELOOP || code == ENOTDIR { return nil }
        throw error(code)
    }

    /// Every name in the folder but "." and "..", as the bytes on disk.
    func names() throws -> [[CChar]] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw Self.error(errno) }
        guard let stream = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw Self.error(code)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.error(errno) }
                return names
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw.prefix(length).map { CChar(bitPattern: $0) }
            } + [0]
            if name == [46, 0] || name == [46, 46, 0] { continue }
            names.append(name)
        }
    }

    /// The kind of the entry by that name, never following a link; nil when
    /// there is none.
    func kind(of name: [CChar]) throws -> mode_t? {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw Self.error(code)
        }
        return status.st_mode & S_IFMT
    }

    /// Removes the entry by that name inside this folder, and when it is a
    /// real folder everything under it first, each level held the same way.
    /// A link or a file goes by `unlinkat`, which removes the name itself.
    /// True when something was removed; false when nothing was there.
    func removeEntry(named name: [CChar]) throws -> Bool {
        guard let kind = try kind(of: name) else { return false }
        if kind == S_IFDIR, let inner = try folder(named: name) {
            for child in try inner.names() { _ = try inner.removeEntry(named: child) }
            return try Self.unlinked(unlinkat(descriptor, name, AT_REMOVEDIR))
        }
        // A file or a link, or a folder that became one since the look: the
        // name itself goes, and nothing it might point at.
        return try Self.unlinked(unlinkat(descriptor, name, 0))
    }

    /// Removes the folder by that name only when it is empty; anything in
    /// it, or a link by that name, leaves it where it is.
    func removeIfEmpty(named name: [CChar]) {
        _ = unlinkat(descriptor, name, AT_REMOVEDIR)
    }

    private static func unlinked(_ result: Int32) throws -> Bool {
        guard result != 0 else { return true }
        let code = errno
        if code == ENOENT { return false }
        throw error(code)
    }

    static func error(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
}

/// What a removal took: the paths removed under `projects/` and the lines
/// dropped from `history.jsonl`.
public struct ClaudeSessionTranscriptRemoval: Equatable, Sendable {
    public let removedPaths: [String]
    public let droppedHistoryLines: Int
    public init(removedPaths: [String], droppedHistoryLines: Int) {
        self.removedPaths = removedPaths; self.droppedHistoryLines = droppedHistoryLines
    }
    public var removedAnything: Bool { !removedPaths.isEmpty || droppedHistoryLines > 0 }
}
