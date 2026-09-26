import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

/// Found live and reproduced on Claude Code 2.1.280:
/// the CLI hands each shell command its own temporary folder, CLAUDE_CODE_TMPDIR,
/// and the app put that inside its own support root, which a work turn's
/// sandbox denies. Apple's /usr/bin/python3 then printed nothing and exited 0,
/// so a bot's script "ran" with no output. A work turn now gets a temporary
/// folder of its own outside every protected root, gone with the turn.
@Suite("A work turn's shell has a temporary folder it can write")
struct ClaudeTextShellTemporaryDirectoryTests {
    private let appRoot = "/private/tmp/not-created-text.noindex"

    private func workRequest() throws -> ClaudeTextOnlyRequest {
        let access = try ClaudeTextWorkAccess(
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/shell-temp-test.noindex/Bot"),
            additionalDirectoryURLs: [], protectedPaths: [appRoot])
        return try textOnlyTestRequest(workAccess: access)
    }

    @Test("A work turn's CLI and shell temporary folder is the turn's own, not the app's run folder")
    func workTurnUsesShellFolder() throws {
        let request = try workRequest()
        let folder = try #require(ClaudeTextShellTemporaryDirectory.create())
        defer { ClaudeTextShellTemporaryDirectory.remove(folder) }
        let environment = ClaudeTextOnlyCommandBuilder.environment(for: request, shellTemporaryDirectory: folder)
        #expect(environment["TMPDIR"] == folder.path)
        #expect(environment["CLAUDE_CODE_TMPDIR"] == folder.path)
        #expect(!folder.path.hasPrefix(appRoot))
    }

    /// Found in the installed app on Claude Code
    /// 2.1.281: the CLI builds each command's temporary folder as
    /// `CLAUDE_CODE_TMPDIR/claude-<uid>` and, when that is over 44 bytes (too long
    /// for the Unix sockets it makes there), falls back to `/tmp/claude-<uid>`, the
    /// folder every Claude Code session of the user shares, and lets the bot's shell
    /// write there. The old folder under `$TMPDIR/OpenBotsNext-Shell.noindex/<uuid>`
    /// was 123 bytes. On 2.1.280 the long folder itself was the shell's TMPDIR and
    /// the sandbox refused writes in it, so `swift` failed with "permissionDenied".
    /// Fixture: `claude-cli-2.1.281/shell-temp-probe/`.
    @Test("The folder is short enough that the CLI uses it, for any user id")
    func folderFitsTheCLILimit() throws {
        let folder = try #require(ClaudeTextShellTemporaryDirectory.create())
        defer { ClaudeTextShellTemporaryDirectory.remove(folder) }
        // Under `.noindex`, as all high-churn state is,
        // and still short: `/tmp` rather than `/private/tmp` buys the suffix.
        #expect(folder.path.hasPrefix("/tmp/obn-"))
        #expect(folder.path.hasSuffix(".noindex"))
        #expect(folder.path.utf8.count + "/claude-\(getuid())".utf8.count <= 44)
        #expect(folder.path.utf8.count + "/claude-4294967295".utf8.count <= 44)
    }

    /// A work turn whose folder cannot be made must not fall through to the
    /// run's own folder, which the sandbox denies: its scripts would run with no
    /// output. It fails to launch instead.
    @Test("A work turn without its folder does not launch")
    func missingFolderFailsTheLaunch() throws {
        #expect(ClaudeTextShellTemporaryDirectory.forLaunch(of: try workRequest(), create: { nil }) == .unavailable)
        let made = URL(fileURLWithPath: "/tmp/obn-00000000.noindex")
        #expect(ClaudeTextShellTemporaryDirectory.forLaunch(of: try workRequest(), create: { made }) == .ready(made))
        #expect(ClaudeTextShellTemporaryDirectory.forLaunch(of: try textOnlyTestRequest(), create: { nil }) == .notNeeded)
        #expect(ClaudeTextShellTemporaryDirectory.create(parentPath: "/nonexistent-\(UUID().uuidString)") == nil)
    }

    /// The same finding: the CLI's shell snapshot runs the user's zsh startup
    /// files, and a `~/.zshenv` can put `~/.cargo/bin` ahead of the system
    /// folders, which is ruled out for any folder the user can write.
    /// zsh reads its startup files from ZDOTDIR; `/var/empty` is the system's
    /// own empty folder, owned by root, so no file of the user's and none a bot writes
    /// is ever read. The system's own `/etc/zprofile` and `/etc/zshrc` still run.
    @Test("A work turn's shell reads no zsh startup file of the user's")
    func workTurnSkipsUserShellFiles() throws {
        let environment = ClaudeTextOnlyCommandBuilder.environment(for: try workRequest(), shellTemporaryDirectory: nil)
        #expect(environment["ZDOTDIR"] == "/var/empty")
        let plain = ClaudeTextOnlyCommandBuilder.environment(for: try textOnlyTestRequest(), shellTemporaryDirectory: nil)
        #expect(plain["ZDOTDIR"] == nil)
    }

    /// The dictionary alone does not show what zsh makes
    /// of it. The CLI's shell is not a login shell (on 2.1.281 its PATH carried
    /// nothing from `/etc/paths`, which `/etc/zprofile`'s path_helper would put
    /// first), so zsh with this environment, interactive as a snapshot is, must
    /// leave PATH exactly as the app built it. A login shell would not: that is
    /// the day this test must change with the CLI.
    @Test("zsh started with a work turn's environment keeps the app's PATH")
    func zshKeepsThePath() throws {
        var environment = ClaudeTextOnlyCommandBuilder.environment(for: try workRequest(), shellTemporaryDirectory: nil)
        environment["TMPDIR"] = NSTemporaryDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-c", "print -r -- \"$PATH\""]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(printed == environment["PATH"])
    }

    /// Probed on 2.1.280: with the app's PATH, `node` and `uv` were
    /// "command not found" while Details listed them, and `python3` was Apple's 3.9.
    /// The system folders stay first. Homebrew's and
    /// ~/.local/bin are writable by the user, and the approval policy lets `ls`,
    /// `cat` and the rest run with no card by name, so a program planted there
    /// under such a name must never be the one the shell finds.
    @Test("A work turn's shell finds the interpreters Details lists, after the system folders")
    func workTurnPathReachesInterpreters() throws {
        let request = try workRequest()
        let path = try #require(ClaudeTextOnlyCommandBuilder.environment(for: request, shellTemporaryDirectory: nil)["PATH"])
        let home = request.target.homeDirectoryURL.path
        let expected = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        #expect(path == expected.joined(separator: ":"))
        let plain = try #require(ClaudeTextOnlyCommandBuilder.environment(for: try textOnlyTestRequest(),
                                                                         shellTemporaryDirectory: nil)["PATH"])
        #expect(plain == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("A turn without Work keeps the run's own temporary folder")
    func textTurnUnchanged() throws {
        let request = try textOnlyTestRequest()
        let folder = try #require(ClaudeTextShellTemporaryDirectory.create())
        defer { ClaudeTextShellTemporaryDirectory.remove(folder) }
        let environment = ClaudeTextOnlyCommandBuilder.environment(for: request, shellTemporaryDirectory: folder)
        #expect(environment["TMPDIR"] == request.target.temporaryDirectoryURL.path)
        #expect(environment["CLAUDE_CODE_TMPDIR"] == request.target.temporaryDirectoryURL.path)
    }

    @Test("The folder is private to this user, fresh per turn, and removed whole")
    func folderLifecycle() throws {
        let first = try #require(ClaudeTextShellTemporaryDirectory.create())
        let second = try #require(ClaudeTextShellTemporaryDirectory.create())
        #expect(first != second)
        var info = stat()
        #expect(stat(first.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(info.st_uid == geteuid())
        try FileManager.default.createDirectory(at: first.appending(path: "claude-501/x"), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: first.appending(path: "claude-501/x/file"))
        ClaudeTextShellTemporaryDirectory.remove(first)
        ClaudeTextShellTemporaryDirectory.remove(second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Removal touches only a folder the store made")
    func removeRefusesForeignFolder() throws {
        let foreign = FileManager.default.temporaryDirectory.appending(path: "not-a-shell-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: foreign) }
        ClaudeTextShellTemporaryDirectory.remove(foreign)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        let lookalike = URL(fileURLWithPath: "/tmp/obn-not-hex-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lookalike) }
        ClaudeTextShellTemporaryDirectory.remove(lookalike)
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        // Names with the right frame and the wrong middle: not hex, upper case,
        // seven digits, and full-width digits, which Character calls hex digits.
        for middle in ["zzzzzzzz", "ABCDEF01", "1234567", "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}\u{FF18}"] {
            let path = "/tmp/obn-" + middle + ".noindex"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: path) }
            ClaudeTextShellTemporaryDirectory.remove(URL(fileURLWithPath: path))
            #expect(FileManager.default.fileExists(atPath: path), "removed \(middle)")
        }
        // A link under a name the store could have made is left alone, and so
        // is what it points to.
        let target = FileManager.default.temporaryDirectory.appending(path: "shell-link-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "file"))
        defer { try? FileManager.default.removeItem(at: target) }
        let link = "/tmp/obn-" + String(format: "%08x", UInt32.random(in: .min ... .max)) + ".noindex"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        defer { unlink(link) }
        ClaudeTextShellTemporaryDirectory.remove(URL(fileURLWithPath: link))
        var info = stat()
        #expect(lstat(link, &info) == 0)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "file").path))
    }
}
