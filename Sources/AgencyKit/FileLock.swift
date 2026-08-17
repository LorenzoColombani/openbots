import Foundation

/// Serialises read-modify-write access to a shared file — across threads in this
/// process (NSLock) AND across processes (flock; the app and agency-cli can run
/// at the same time). One instance per protected resource.
///
/// This is the roster-race fix generalised: roster.json got a lock first,
/// but messages.jsonl and pending-context.md had the same lost-update window
/// (review C2/C4 — measured 180/200 and 134/400 entries lost respectively).
public final class FileLock {
    private let lockURL: URL
    private let threadLock = NSLock()

    public init(lockURL: URL) { self.lockURL = lockURL }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        threadLock.lock()
        defer { threadLock.unlock() }
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            flock(fd, LOCK_EX)
        } else {
            // Degrading to thread-only locking in exactly the scenario the file
            // lock exists for deserves a trace, not silence (review Minor 1).
            fputs("agency: WARNING cannot open \(lockURL.path) (errno \(errno)) — cross-process locking degraded\n", stderr)
        }
        defer {
            if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
        }
        return try body()
    }
}
