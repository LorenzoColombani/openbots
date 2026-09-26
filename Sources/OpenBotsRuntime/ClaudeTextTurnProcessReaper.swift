import Darwin
import Foundation

/// Ends every program a turn's CLI started, wherever it went.
///
/// The turn's own cleanup, `kill(-pid, SIGKILL)` on the CLI's process group,
/// never reached the Bash tool's work: Claude Code runs each command in a shell
/// that leads a process group of its own (seen on 2.1.280, fixture
/// `run-code-probe`). The CLI died at Stop; the shell and the script
/// under it were handed to launchd and ran on. A run sent to the background
/// (`nohup python3 x.py &`) outlived even a turn that ended normally.
///
/// Two facts about a process name it as this turn's, and nothing else is ever
/// signalled. It descends from the CLI, which holds only while the CLI lives;
/// or its environment carries this turn's mark, which the CLI hands to every
/// shell it starts and a shell hands to every program, so it still holds for a
/// background run whose parents are gone. A process leading a group of its own
/// is killed with its group, which takes the script under the shell; any other
/// is killed alone. Twice when the first pass found something, like the
/// connector reaper: something may be starting as the first pass runs. Only this user's processes started since the turn
/// began are read. This is lifecycle control, not containment: a program that
/// clears its own environment and leaves the tree deliberately is not chased.
enum ClaudeTextTurnProcessReaper {
    /// The environment variable that carries a turn's mark.
    static let markName = "OPENBOTS_TURN"

    /// Signals what the turn left running, before the CLI's own group is
    /// killed. Returns the number of processes or groups signalled.
    @discardableResult
    static func reap(cliPID: pid_t, mark: String, startedAt: Date, cliIsAlive: Bool) -> Int {
        guard cliPID > 1, !mark.isEmpty else { return 0 }
        let entry = "\(markName)=\(mark)"
        let ownGroup = getpgrp()
        let since = startedAt.timeIntervalSince1970 - 1
        // Frozen, the CLI cannot start another command while its tree is read.
        if cliIsAlive { _ = Darwin.kill(-cliPID, SIGSTOP) }
        var signalled = 0
        for pass in 0..<2 {
            let table = ownedProcesses(startedSince: since)
            var targets = Set(descendants(of: cliPID, in: table))
            for process in table where !targets.contains(process.pid) && carriesMark(process.pid, entry: entry) {
                targets.insert(process.pid)
            }
            let groups = Dictionary(table.map { ($0.pid, $0.groupID) }, uniquingKeysWith: { first, _ in first })
            var found = false
            for pid in targets where pid > 1 && pid != getpid() && pid != cliPID {
                guard let group = groups[pid], group != ownGroup else { continue }
                found = true
                let killed = pid == group ? Darwin.kill(-pid, SIGKILL) : Darwin.kill(pid, SIGKILL)
                if killed == 0 { signalled += 1 }
            }
            // With the CLI frozen or gone and nothing of its found, nothing is
            // left to start another: a turn that ran no command pays no wait.
            guard found else { break }
            if pass == 0 { usleep(150_000) }
        }
        return signalled
    }

    struct OwnedProcess: Equatable { let pid: pid_t; let parentID: pid_t; let groupID: pid_t }

    /// Every process in the CLI's tree, however deep, while the links hold.
    static func descendants(of root: pid_t, in table: [OwnedProcess]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for process in table { children[process.parentID, default: []].append(process.pid) }
        var found: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var frontier = [root]
        while let parent = frontier.popLast() {
            for child in children[parent] ?? [] where seen.insert(child).inserted {
                found.append(child)
                frontier.append(child)
            }
        }
        return found
    }

    /// This user's live processes started at or after `since` (seconds since
    /// 1970), so a process of someone else's, or one older than the turn, is
    /// never read, let alone signalled.
    private static func ownedProcesses(startedSince since: TimeInterval) -> [OwnedProcess] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between sizing and reading.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&name, u_int(name.count), &entries, &size, nil, 0) == 0 else { return [] }
        return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { entry in
            let start = entry.kp_proc.p_un.__p_starttime
            let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
            guard started >= since else { return nil }
            return OwnedProcess(pid: entry.kp_proc.p_pid, parentID: entry.kp_eproc.e_ppid, groupID: entry.kp_eproc.e_pgid)
        }
    }

    /// True when the process's argument and environment strings, as the
    /// kernel recorded them at exec, hold exactly this entry. The mark is a
    /// fresh identifier per turn, so wherever it sits it names this turn.
    static func carriesMark(_ pid: pid_t, entry: String) -> Bool {
        execStrings(of: pid)?.contains(entry) ?? false
    }

    /// KERN_PROCARGS2: a 32-bit argument count, the executable path, padding,
    /// the arguments, then the environment's entries, each NUL-terminated.
    private static func execStrings(of pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var fields: [String] = []
        var current: [UInt8] = []
        for byte in buffer[MemoryLayout<Int32>.size..<size] {
            if byte == 0 {
                if !current.isEmpty { fields.append(String(decoding: current, as: UTF8.self)); current = [] }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { fields.append(String(decoding: current, as: UTF8.self)) }
        return fields
    }
}
