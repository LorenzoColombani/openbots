import Darwin
import Foundation

/// Ends the browser work a turn owns, and nothing else.
///
/// The turn's own cleanup is `kill(-pid, SIGKILL)` on the child's process
/// group, which is the right instrument for the CLI and everything it keeps
/// inside that group. Chrome is not inside it: the connector server launches it
/// into a group of its own, so the turn's kill cannot reach it. Stop has to end
/// the run and its whole process tree, so this type ends the browser.
///
/// The instrument is the profile directory. Each turn gets a fresh, app-owned
/// profile whose path contains that turn's own identifier, and Chrome carries
/// its profile path in its argument vector. So a process is this turn's browser
/// exactly when its arguments contain this turn's path — which is a fact about
/// the process, not a guess from a name, and cannot match the browser the user
/// is running for themselves. Nothing without that path is ever signalled.
enum ClaudeTextConnectorReaper {
    /// Kills every process of ours whose arguments carry one of these paths,
    /// then removes the directories. Returns the number of processes signalled.
    @discardableResult
    static func reap(profileURLs: [URL]) -> Int {
        // Both spellings, and never the standardized one alone: `/private/tmp`
        // standardizes to `/tmp`, and the browser carries the path it was
        // actually launched with. Matching only the tidied form finds nothing.
        let paths = Set(profileURLs.flatMap { [$0.path, $0.standardizedFileURL.path] })
            .filter { $0.hasPrefix("/") && $0.utf8.count > 1 }
        guard !paths.isEmpty else { return 0 }
        var signalled = 0
        // Twice: the server may still be starting a browser as the first pass
        // runs, and a process that appears between the two would otherwise
        // outlive the turn.
        for pass in 0..<2 {
            for process in ownedProcesses() where process.pid != getpid() && process.pid > 1 {
                guard let arguments = argumentVector(of: process.pid),
                      arguments.contains(where: { carriesProfile($0, paths: paths) }) else { continue }
                // Chrome leads a process group of its own, and its renderer and
                // GPU helpers are in that group without carrying the profile
                // themselves. Killing the group takes them; killing only the
                // leader would leave them orphaned. A process that is not a
                // group leader is killed on its own, so a group we do not own
                // is never signalled.
                let killed = process.pid == process.groupID
                    ? Darwin.kill(-process.pid, SIGKILL)
                    : Darwin.kill(process.pid, SIGKILL)
                if killed == 0 { signalled += 1 }
            }
            if pass == 0 { usleep(150_000) }
        }
        let manager = FileManager()
        for url in profileURLs {
            try? manager.removeItem(at: url)
            // A turn's profiles sit together in a directory of that turn's own.
            // Removing only the profile leaves that directory behind, empty,
            // once for every turn that ever browsed. Remove it too, but only
            // while it is empty: anything still in it belongs to someone else.
            let parent = url.deletingLastPathComponent()
            let remaining = (try? manager.contentsOfDirectory(atPath: parent.path)) ?? ["not-empty"]
            if remaining.isEmpty { try? manager.removeItem(at: parent) }
        }
        return signalled
    }

    /// True when this argument names one of the profiles the turn owns.
    ///
    /// The bare path is not enough. Chrome is launched by Puppeteer, which
    /// always passes the profile as one combined `--user-data-dir=<path>`
    /// token, so an equality test against the path alone matches nothing —
    /// which is to say it would leave a browser running after every turn the
    /// app did not end gracefully. Both spellings are accepted, and the `=`
    /// anchor keeps `/a/profile` from matching `/a/profile-other`.
    static func carriesProfile(_ argument: String, paths: some Collection<String>) -> Bool {
        paths.contains { argument == $0 || argument.hasSuffix("=" + $0) }
    }

    private struct OwnedProcess { let pid: pid_t; let groupID: pid_t }

    /// Every live process of this user's, so a process of someone else's is
    /// never even read, let alone signalled.
    private static func ownedProcesses() -> [OwnedProcess] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: max(count, 1))
        // The table can grow between sizing and reading; a short read is fine,
        // a failed one yields nothing rather than a stale guess.
        guard sysctl(&name, u_int(name.count), &entries, &size, nil, 0) == 0 else { return [] }
        return entries.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map { OwnedProcess(pid: $0.kp_proc.p_pid, groupID: $0.kp_eproc.e_pgid) }
    }

    /// The process's full argument vector, as the kernel recorded it at exec.
    private static func argumentVector(of pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1 << 20 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        // KERN_PROCARGS2: a 32-bit argument count, the executable path, padding,
        // then that many NUL-terminated arguments, then the environment. Only
        // the arguments are read; the environment is never looked at.
        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount > 0, argumentCount < 4_096 else { return nil }
        var fields: [String] = []
        var index = MemoryLayout<Int32>.size
        var current: [CChar] = []
        while index < size, fields.count <= Int(argumentCount) {
            let byte = buffer[index]
            index += 1
            if byte == 0 {
                if !current.isEmpty {
                    fields.append(String(cString: current + [0]))
                    current = []
                }
                continue
            }
            current.append(byte)
        }
        // Drop the executable path, which the kernel writes before the
        // arguments; what is left is the vector itself.
        return fields.isEmpty ? nil : Array(fields.dropFirst())
    }
}
