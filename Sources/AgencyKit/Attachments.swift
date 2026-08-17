import Foundation

/// File attachments for the composer (his ask 2026-08-14): a picked or
/// dropped file is COPIED under `shared/attachments/` and the outgoing
/// message tells the agent where to read it.
///
/// Why shared/ and not the agent's workspace: other agents' folders are
/// sealed pockets BOTH ways, so a file staged in one member's dir would be
/// unreadable to the rest of a team — and to a relay target. shared/ is the
/// one place every fenced run can already read AND write (the Seatbelt
/// profile allow-backs it explicitly; no pocket seals it), so one staging
/// path serves 1:1 threads, group threads, and "@target …" relays alike.
/// Copies, never references: the original stays wherever Lorenzo keeps it,
/// and the snapshot the agent reads doesn't move or change under the run.
public enum Attachments {
    public enum AttachmentError: LocalizedError {
        case symlink(String)
        case tooLarge(totalBytes: Int, limit: Int)
        public var errorDescription: String? {
            switch self {
            case .symlink(let name):
                return "\"\(name)\" is (or contains) a symbolic link — links are refused because the staged copy would point somewhere else, possibly somewhere sealed"
            case .tooLarge(let total, let limit):
                return "attachments total \(total / 1_048_576) MB — over the \(limit / 1_048_576) MB limit"
            }
        }
    }

    /// The reject class: ASCII control chars (TAB and ESC survived the first
    /// cut — review I3), DEL, and the full invisible/bidi set — overrides
    /// U+202A–E AND the isolates U+2066–69 + U+061C (review M1: the MCP
    /// servers' class had the same isolate gap; closed there in the same
    /// round). A filename carrying these can display as something it isn't.
    static func isDisallowedScalar(_ v: UInt32) -> Bool {
        v < 0x20 || v == 0x7F || v == 0x061C || v == 0x2060 || v == 0xFEFF
            || (0x200B...0x200F).contains(v)
            || (0x202A...0x202E).contains(v)
            || (0x2066...0x2069).contains(v)
    }

    /// A name safe to create under the staging dir: last path component only
    /// (a crafted "../x" can never climb out), control/invisible characters
    /// stripped, no leading dot (a dropped ".zshrc" stays visible),
    /// ":" swapped for "-" (Finder's separator). Empty after all that → "file".
    public static func sanitizedName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        var out = String(base.filter { ch in
            !ch.isNewline && !ch.unicodeScalars.contains { isDisallowedScalar($0.value) }
        })
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "file" : out
    }

    /// Directory name for a thread's attachments. Team keys ("#probe") carry a
    /// character outside the name alphabet — mapped to "team-<name>" so the
    /// path stays shell-friendly; agent handles pass through (already
    /// isValidName). Anything else is filtered to the same alphabet.
    public static func slug(forThread thread: String) -> String {
        // Team slugs KEEP the '#' (review M2): the agent-slug alphabet below
        // can never produce one, so team "#probe" and an agent legally named
        // "team-probe" can't share a staging dir. '#' is fine on APFS, and
        // mid-token it isn't a shell comment either.
        if TeamThreads.isTeamKey(thread), let team = TeamThreads.teamName(fromKey: thread) {
            return "#" + team
        }
        let kept = thread.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return kept.isEmpty ? "thread" : String(kept)
    }

    /// Pre-flight walk (reviews C1 + I2): refuses symlinks anywhere in the
    /// payload — a staged link points somewhere else (a sealed pocket, or
    /// nowhere: a relative link arrives dangling, both verified live) — and
    /// sums logical sizes so a runaway folder is refused up front instead of
    /// beachballing the synchronous main-actor copy.
    private static func preflight(_ files: [URL], maxTotalBytes: Int) throws {
        let fm = FileManager.default
        var total = 0
        var queue = files.map { ($0, $0.lastPathComponent) }
        while let (url, display) = queue.popLast() {
            let attrs = try fm.attributesOfItem(atPath: url.path)   // lstat — no resolution
            switch attrs[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                throw AttachmentError.symlink(display)
            case .typeDirectory:
                for child in try fm.contentsOfDirectory(at: url,
                                                        includingPropertiesForKeys: nil,
                                                        options: []) {
                    queue.append((child, display + "/" + child.lastPathComponent))
                }
            default:
                total += (attrs[.size] as? Int) ?? 0
                if total > maxTotalBytes {
                    throw AttachmentError.tooLarge(totalBytes: total, limit: maxTotalBytes)
                }
            }
        }
    }

    /// Copies `files` into `<root>/shared/attachments/<slug>/` with a
    /// per-send timestamp prefix; a same-second same-name collision gets a
    /// numeric suffix rather than an overwrite (the no-overwrite rule holds
    /// for Lorenzo's files too). Returns the staged URLs in input order.
    /// Throws on the first file that cannot be copied — the caller surfaces
    /// that in the thread instead of sending a message that references a
    /// path which isn't there.
    public static func stage(files: [URL], thread: String, root: URL,
                             now: Date = Date(),
                             maxTotalBytes: Int = 512 * 1024 * 1024) throws -> [URL] {
        let fm = FileManager.default
        try preflight(files, maxTotalBytes: maxTotalBytes)
        let dir = root.appendingPathComponent("shared")
            .appendingPathComponent("attachments")
            .appendingPathComponent(slug(forThread: thread))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = f.string(from: now)
        var staged: [URL] = []
        do {
            for src in files {
                let name = sanitizedName(src.lastPathComponent)
                var dest = dir.appendingPathComponent("\(stamp)-\(name)")
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(stamp)-\(n)-\(name)")
                    n += 1
                }
                try fm.copyItem(at: src, to: dest)
                staged.append(dest)
            }
        } catch {
            // A refused send must leave no orphans (review M3) — the message
            // that would have named these paths is never going out.
            for s in staged { try? fm.removeItem(at: s) }
            throw error
        }
        return staged
    }

    /// Retention (review M6, his "tidy up" 2026-08-14): staged copies are
    /// snapshots for a conversation turn, not an archive — the originals
    /// live wherever Lorenzo keeps them. Anything older than `maxAge`
    /// (default 30 days) is swept at app launch; emptied slug dirs go too.
    /// Old thread logs will then name paths that no longer exist, which is
    /// the accepted trade — the alternative is unbounded growth of files
    /// nobody reads twice a month later. Returns how many items were removed.
    @discardableResult
    public static func sweep(root: URL,
                             maxAge: TimeInterval = 30 * 24 * 3600,
                             now: Date = Date()) -> Int {
        let fm = FileManager.default
        let base = root.appendingPathComponent("shared").appendingPathComponent("attachments")
        guard let slugs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        let cutoff = now.addingTimeInterval(-maxAge)
        var removed = 0
        for slugDir in slugs {
            guard let entries = try? fm.contentsOfDirectory(
                at: slugDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: []) else { continue }
            for entry in entries {
                let mod = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                if mod < cutoff, (try? fm.removeItem(at: entry)) != nil { removed += 1 }
            }
            if let left = try? fm.contentsOfDirectory(atPath: slugDir.path), left.isEmpty {
                try? fm.removeItem(at: slugDir)
            }
        }
        return removed
    }

    /// The lines appended to the outgoing message so the agent knows what
    /// arrived and where. Absolute paths on purpose: they stay valid for a
    /// relay target or any team member, whatever that run's cwd is.
    public static func promptBlock(for staged: [URL]) -> String {
        guard !staged.isEmpty else { return "" }
        let noun = staged.count == 1 ? "file" : "files"
        let lines = staged.map { "  \($0.path)" }.joined(separator: "\n")
        return "\n\n[Lorenzo attached \(staged.count) \(noun) — read from:\n\(lines)]"
    }
}
