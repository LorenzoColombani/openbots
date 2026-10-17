import Darwin
import Foundation

/// Remove screenshots left by Control this Mac. Peekaboo 4.0.0 `see` writes
/// `peekaboo-observation-<UUID>.png` into the account's temporary folder regardless of TMPDIR
/// and reports the path in its result. Explicit cleanup prevents screen captures from remaining
/// on disk.
public enum MacControlScreenshotSweep {
    static let prefix = "peekaboo-observation-"
    static let suffix = ".png"

    /// The folder `confstr` names for this account, which is where Foundation
    /// writes when TMPDIR is ignored.
    public static func accountTemporaryFolder() -> URL? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else { return nil }
        let path = String(cString: buffer)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Removes this account's plain screenshot files in `folder` last written
    /// at or after `modifiedSince`. A link, a folder or anything another
    /// account owns is left alone. Returns how many went.
    @discardableResult
    public static func remove(in folder: URL? = accountTemporaryFolder(), modifiedSince: Date) -> Int {
        guard let folder, let names = try? FileManager().contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let path = folder.appendingPathComponent(name).path
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified >= modifiedSince, unlink(path) == 0 else { continue }
            removed += 1
        }
        return removed
    }
}
