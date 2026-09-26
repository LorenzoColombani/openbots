import Darwin
import Foundation

/// A work turn's temporary folder for the CLI and every command it runs.
///
/// The CLI hands each shell command its own temporary folder, `CLAUDE_CODE_TMPDIR`
/// (it overrides `TMPDIR` for them), and lets its sandbox write there. The run's
/// temporary folder sits inside the app's support root, which every work turn's
/// sandbox denies, so a command could write no temporary file at all: Apple's
/// `/usr/bin/python3` printed nothing and exited 0 (seen on Claude Code 2.1.280).
/// A work turn gets this folder instead, outside every protected
/// root, private to this user, fresh per turn and removed with it. The prompt and
/// connector files stay in the run's own folder, out of the shell's reach.
///
/// It must be short (seen on Claude Code 2.1.281 and in the installed app):
/// the CLI uses `<folder>/claude-<uid>` only while that is at most 44 bytes, since
/// it makes Unix sockets inside, and otherwise falls back to `/tmp/claude-<uid>`,
/// the folder every Claude Code session of the user shares, with the bot's shell free
/// to write there. So the folder is `/tmp/obn-<8 hex>.noindex`, 25 bytes, which
/// leaves room for any user id and keeps this high-churn folder under `.noindex`,
/// out of Spotlight; `/tmp` rather than `/private/tmp` buys the suffix.
enum ClaudeTextShellTemporaryDirectory {
    static let parentPath = "/tmp"
    static let namePrefix = "obn-"
    static let nameSuffix = ".noindex"

    enum LaunchFolder: Equatable {
        case notNeeded, ready(URL), unavailable
    }

    /// A work turn launches only with its folder: without one its commands
    /// would get the run's own folder, which the sandbox denies, and print
    /// nothing.
    static func forLaunch(of request: ClaudeTextOnlyRequest, create: () -> URL? = { create() }) -> LaunchFolder {
        guard request.workAccess != nil else { return .notNeeded }
        return create().map(LaunchFolder.ready) ?? .unavailable
    }

    /// A new, empty folder with mode 0700, or nil when it cannot be made safely.
    /// `mkdir` never follows or reuses what is there: a name already taken, by
    /// anyone, is skipped for a fresh one.
    static func create(parentPath: String = parentPath) -> URL? {
        for _ in 0..<16 {
            let path = parentPath + "/" + namePrefix + String(format: "%08x", UInt32.random(in: .min ... .max)) + nameSuffix
            guard mkdir(path, S_IRWXU) == 0 else {
                if errno == EEXIST { continue }
                return nil
            }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// Removes a folder `create` made, and nothing else: never a link under
    /// such a name. The path is compared as spelled, since Foundation's
    /// standardizing rewrites `/private` spellings.
    static func remove(_ folder: URL) {
        let path = folder.path
        guard path.hasPrefix(parentPath + "/"), path.hasSuffix(nameSuffix) else { return }
        let name = path.dropFirst(parentPath.count + 1).dropLast(nameSuffix.count)
        // Bytes, not Characters: Character calls full-width digits hex digits.
        let digits = name.utf8.dropFirst(namePrefix.utf8.count)
        guard name.hasPrefix(namePrefix), digits.count == 8,
              digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { return }
        try? FileManager().removeItem(atPath: path)
    }
}
