import Darwin
import Foundation
import Testing
@testable import OpenBotsRuntime

/// The browser a turn owns runs in its own process group, so the turn's
/// `kill(-pid)` never reaches it. These are the two claims the profile path has
/// to earn instead: everything carrying it dies with the turn, and nothing else
/// is touched — including the browser the user is running for themselves.
@Suite("Ending the browser work a turn owns, and only that")
struct ClaudeTextConnectorReaperTests {
    /// A stand-in for Chrome: a process that lives long enough to be found and
    /// carries the given path in its argument vector, exactly as Chrome carries
    /// its `--user-data-dir`.
    private func longRunningProcess(carrying path: String?) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is planted the way Chrome actually carries it: Puppeteer
        // passes the profile as one combined `--user-data-dir=<path>` token,
        // never as a bare argument. An earlier version of this test planted the
        // bare path, which the reaper matched while the real browser it exists
        // to end went untouched.
        let planted = path.map { "--user-data-dir=\($0)" } ?? "--unrelated-openbots-reaper-control"
        // The trailing `; :` matters too: given a single simple command, sh
        // execs it and replaces its own argument vector, taking the path with
        // it — the same class of mistake, one layer down.
        process.arguments = ["-c", "sleep 30; :", planted]
        try process.run()
        return process
    }

    private func isAlive(_ process: Process) -> Bool {
        process.isRunning && Darwin.kill(process.processIdentifier, 0) == 0
    }

    @Test("Everything carrying the turn's profile path is ended, and the profile is gone")
    func reapsWhatTheTurnOwns() throws {
        let profile = URL(fileURLWithPath:
            "/private/tmp/openbots-reaper-\(UUID().uuidString).noindex/profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile.deletingLastPathComponent()) }

        let owned = try longRunningProcess(carrying: profile.path)
        let other = try longRunningProcess(carrying: nil)
        defer { for process in [owned, other] where process.isRunning { process.terminate() } }
        // Give both a moment to appear in the process table.
        usleep(300_000)
        #expect(isAlive(owned) && isAlive(other))

        let signalled = ClaudeTextConnectorReaper.reap(profileURLs: [profile])
        for _ in 0..<50 where isAlive(owned) { usleep(100_000) }
        #expect(signalled >= 1)
        #expect(!isAlive(owned))
        // The claim that matters most: a browser the app did not launch is never
        // signalled, however much it looks like the one that was.
        #expect(isAlive(other))
        #expect(!FileManager.default.fileExists(atPath: profile.path))
    }

    @Test("The profile is recognised however the browser spells it, and never by a near miss")
    func theMatchIsAnchored() {
        let path = "/private/tmp/openbots.noindex/profile"
        for argument in [path, "--user-data-dir=\(path)", "--profile-directory=\(path)"] {
            #expect(ClaudeTextConnectorReaper.carriesProfile(argument, paths: [path]), "\(argument)")
        }
        // A neighbour with a longer name is a different profile, not this one.
        for argument in ["--user-data-dir=\(path)-other", "--user-data-dir=\(path)/nested",
                         "\(path)-other", "--user-data-dir=/other\(path)", ""] {
            #expect(!ClaudeTextConnectorReaper.carriesProfile(argument, paths: [path]), "\(argument)")
        }
    }

    @Test("A turn takes its own directory with it, and leaves anyone else's alone")
    func theTurnDirectoryGoesToo() throws {
        let root = URL(fileURLWithPath: "/private/tmp/openbots-reaper-\(UUID().uuidString).noindex",
                       isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The shape the app makes: one directory per turn, one profile inside
        // it per granted connector.
        let turn = root.appendingPathComponent("turn-1", isDirectory: true)
        let first = turn.appendingPathComponent("openbots_aaa", isDirectory: true)
        let second = turn.appendingPathComponent("openbots_bbb", isDirectory: true)
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        ClaudeTextConnectorReaper.reap(profileURLs: [first])
        // One profile gone, the other still there, so the turn's own directory
        // stays: something is still using it.
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: turn.path))
        ClaudeTextConnectorReaper.reap(profileURLs: [second])
        #expect(!FileManager.default.fileExists(atPath: turn.path))
        // And the root above it is never touched: it is not this turn's.
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("A turn that owned no profile signals nothing at all")
    func reapsNothingWithoutAProfile() throws {
        let other = try longRunningProcess(carrying: nil)
        defer { if other.isRunning { other.terminate() } }
        usleep(200_000)
        #expect(ClaudeTextConnectorReaper.reap(profileURLs: []) == 0)
        // A path that is not a path is refused before anything is enumerated.
        #expect(ClaudeTextConnectorReaper.reap(profileURLs: [URL(fileURLWithPath: "/")]) == 0)
        #expect(isAlive(other))
    }
}
