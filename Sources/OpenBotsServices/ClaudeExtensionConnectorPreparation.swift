import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Launches a Claude Desktop extension this build has reviewed, and only the
/// exact copy that was reviewed.
///
/// Claude Desktop installs its extensions under `~/Library/Application Support/
/// Claude/Claude Extensions`, one folder each, already built: a manifest, a node
/// server and its `node_modules`. Nothing is fetched and nothing is installed
/// here. Reviewed means pinned, on Control this Mac's pattern: the app carries,
/// per reviewed extension, its version and one SHA-256 over every file as it
/// was read, and checks both again at every catalog read and every launch. An
/// update Claude Desktop installs is a different copy: its row goes unavailable
/// and a bot's grant goes off with the "changed" line, because the digest is
/// part of the row's identity.
public struct ClaudeExtensionConnectorPreparation: Sendable {
    /// One extension as it was reviewed.
    public struct Review: Equatable, Sendable {
        /// Its folder, as Claude Desktop names it.
        public let folder: String
        public let version: String
        /// `treeDigest` of the folder as reviewed.
        public let treeSHA256: String
        /// The server, relative to the folder, run by an absolute node.
        public let entryPoint: String
        public let role: ClaudeTextConnectorRole
        /// The tools its server announces, from the reviewed `server/index.js`.
        public let tools: [String]
        public let title: String
        public let summary: String
    }

    /// Apple Notes 0.1.7, by Anthropic. Reviewed: its
    /// `server/index.js` in full, and the SDK files it loads (the MCP SDK 1.11.3
    /// and zod 3.25.67), which read and write JSON on stdio and nothing else.
    /// Each tool builds an AppleScript with the bot's words spliced in through
    /// `JSON.stringify`, which AppleScript reads back as one string (proved
    /// against the real file); a
    /// folder is spliced in whatever JSON type it arrives as, so the card
    /// refuses anything but a string there. `update_note_content` replaces the
    /// whole note, and finds it by name alone.
    public static let notes = Review(
        folder: "ant.dir.ant.anthropic.notes",
        version: "0.1.7",
        treeSHA256: "361774e73f031175d471582c4afcee17dced0d2bba4bcc8003499d3cf549bb8d",
        entryPoint: "server/index.js",
        role: .appleNotes,
        tools: ["list_notes", "get_note_content", "add_note", "update_note_content"],
        title: "Apple Notes",
        summary: "Lists and reads your notes, adds a new note, and replaces the text of one. Adding a note "
            + "and replacing one's text each ask you on a card first, with the note's name, its folder and "
            + "the exact text; replacing puts the new text in place of everything the note held.\n"
            + "Claude Desktop extension by Anthropic, version 0.1.7, the copy OpenBots checked. Needs "
            + "permission for OpenBots Next to control Notes, which macOS asks for the first time a bot looks.")

    /// Control Chrome 0.1.6, by Anthropic. Reviewed: its `server/index.js` in
    /// full. Every tool is one `osascript -e` to
    /// `tell application "Google Chrome"`, which is the user's own Chrome, signed in;
    /// a bot's words enter the script through `JSON.stringify` (an address, a
    /// script) or `parseInt` (a tab number). `execute_javascript` runs any
    /// script in a tab and `get_page_content` is the same with a fixed one, so
    /// both work only while Chrome's "Allow JavaScript from Apple Events" is on.
    /// The list below is all ten tools the server
    /// announces, the script tool included, because a turn refuses a server
    /// that announces a tool not listed; the card refuses the script tool.
    public static let chromeControl = Review(
        folder: "ant.dir.ant.anthropic.chrome-control",
        version: "0.1.6",
        treeSHA256: "918f81f3c73c5a1d865f9c799973ae938ff03444cc4cb6f50848d3dd4a993d30",
        entryPoint: "server/index.js",
        role: .chromeControl,
        tools: ["open_url", "get_current_tab", "list_tabs", "close_tab", "switch_to_tab", "reload_tab", "go_back",
                "go_forward", "execute_javascript", "get_page_content"],
        title: "Control Chrome",
        summary: "Lists your Chrome tabs, reads a page's words, opens an address in a new tab, and closes, "
            + "reloads or moves a tab, in your own Chrome, where you are signed in. Every action, reading "
            + "included, asks you on a card first, naming the tab by its site and title. Running scripts in "
            + "your Chrome is not offered in this version.\n"
            + "Claude Desktop extension by Anthropic, version 0.1.6, the copy OpenBots checked. Chrome must be "
            + "open; a bot never starts it. Needs permission for OpenBots Next to control Google Chrome, which "
            + "macOS asks for the first time a bot uses it.")

    /// Every extension this build has reviewed. Anything else is listed and
    /// cannot be turned on.
    public static let reviewed: [Review] = [notes, chromeControl]

    /// The command the extension catalog writes on every row it lists, with the
    /// folder as the one argument. It is nothing any other preparation reads —
    /// the browser's reads `npx` and `node`, and would take an extension's own
    /// `node …/server/index.js` for a broken browser.
    public static let command = "claude-desktop-extension"

    /// Where Claude Desktop keeps its extensions.
    public static func defaultExtensionsRootURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent("Library/Application Support/Claude/Claude Extensions",
                                                isDirectory: true)
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAnExtension
        case notReviewed
        case folderMissing
        /// A link, a file someone else owns or can write to, or something that
        /// is not a plain file or folder, anywhere in the extension.
        case unsafeTree
        /// Something moved while the folder was being read.
        case changedWhileRead
        /// Readable, but not the copy that was reviewed.
        case notTheReviewedCopy
        case interpreterMissing
        case fenceUnavailable(FenceProxyResource.Failure)
        /// On Claude Desktop's list of extensions Anthropic has blocked.
        case blockedByClaudeDesktop
        /// That list is there and cannot be read, so a block cannot be ruled out.
        case blocklistUnreadable
    }

    private let extensionsRootURL: URL
    private let blocklistURL: URL
    private let interpreterCandidateURLs: [URL]
    private let ownerUID: uid_t
    private let reviews: [Review]
    private let tools: InstalledToolResolution
    private let fence: FenceProxyResource
    /// Shared by every copy of this value, so the catalog and the launch read
    /// the folder once between them while it stays as it is.
    private let digests = TreeDigestCache()

    /// `blocklistURL` defaults to Claude Desktop's own list, beside the
    /// extensions folder.
    public init(extensionsRootURL: URL, blocklistURL: URL? = nil,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                ownerUID: uid_t = getuid(),
                reviews: [Review] = ClaudeExtensionConnectorPreparation.reviewed,
                fence: FenceProxyResource = FenceProxyResource()) {
        self.extensionsRootURL = extensionsRootURL
        self.blocklistURL = blocklistURL ?? extensionsRootURL.deletingLastPathComponent()
            .appendingPathComponent("extensions-blocklist.json", isDirectory: false)
        self.fence = fence
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.ownerUID = ownerUID
        self.reviews = reviews
        self.tools = InstalledToolResolution(ownerUID: ownerUID)
    }

    /// Every extension this preparation has a review for.
    public var knownReviews: [Review] { reviews }

    /// The review for a folder name, or nil when this build has none.
    public func review(forFolder folder: String) -> Review? {
        reviews.first { $0.folder == folder }
    }

    public func folderURL(_ folder: String) -> URL {
        extensionsRootURL.appendingPathComponent(folder, isDirectory: true)
    }

    /// The folder's digest as it is on the disk now, for the catalog's identity.
    public func currentDigest(ofFolder folder: String) throws -> String {
        try digests.digest(of: folderURL(folder), ownerUID: ownerUID)
    }

    /// The reviewed copy, checked, with the node that will run it.
    public func resolve(_ launch: ConnectorLaunchConfiguration)
        throws -> (review: Review, entryPoint: URL, interpreter: URL) {
        guard launch.command == Self.command, launch.transport == .stdio,
              launch.arguments.count == 1, let folder = launch.arguments.first else { throw Failure.notAnExtension }
        guard let review = review(forFolder: folder) else { throw Failure.notReviewed }
        try checkBlocklist(folder: folder)
        let root = folderURL(folder)
        guard (try? root.checkResourceIsReachable()) == true else { throw Failure.folderMissing }
        guard try digests.digest(of: root, ownerUID: ownerUID) == review.treeSHA256 else {
            throw Failure.notTheReviewedCopy
        }
        let entryPoint = root.appendingPathComponent(review.entryPoint, isDirectory: false).standardizedFileURL
        guard entryPoint.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw Failure.unsafeTree }
        guard let interpreter = tools.firstResolved(of: interpreterCandidateURLs) else {
            throw Failure.interpreterMissing
        }
        return (review, entryPoint, interpreter)
    }

    /// Claude Desktop keeps the extensions Anthropic has blocked in a list it
    /// fetches (`extensions-blocklist.json`: an array of lists, each with
    /// `entries` of `{ id, hash, … }`). An entry naming the folder blocks it,
    /// whatever its hash, since this build cannot tell which copy a hash means.
    /// No list is no block; a list that cannot be read blocks, so an emergency
    /// revocation is never missed for a format this build does not know.
    func checkBlocklist(folder: String) throws {
        var info = stat()
        guard lstat(blocklistURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw Failure.blocklistUnreadable
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4_194_304,
              let data = FileManager().contents(atPath: blocklistURL.path),
              let lists = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { throw Failure.blocklistUnreadable }
        for list in lists {
            guard let entries = list["entries"] as? [[String: Any]] else { throw Failure.blocklistUnreadable }
            if entries.contains(where: { ($0["id"] as? String) == folder }) { throw Failure.blockedByClaudeDesktop }
        }
    }

    // MARK: - The digest

    /// SHA-256 over every regular file in the folder, as `path NUL sha256 LF`
    /// lines sorted by the path's bytes, paths relative to the folder with `/`.
    /// A link, a file or folder this user does not own or that anyone else can
    /// write to, or anything that is not a plain file or folder refuses the
    /// whole folder. `.DS_Store`, which Finder writes and node never reads, is
    /// left out, so opening the folder in Finder does not unpin it.
    static func treeDigest(of root: URL, ownerUID: uid_t) throws -> String {
        let entries = try walk(root, ownerUID: ownerUID)
        var lines = Data()
        for entry in entries where entry.isFile {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(entry.path), options: .uncached)
            else { throw Failure.changedWhileRead }
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lines.append(contentsOf: Array(entry.path.utf8) + [0] + Array(hex.utf8) + [0x0A])
        }
        return SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
    }

    struct Entry: Equatable {
        let path: String
        let isFile: Bool
        /// What moves whenever the entry's bytes may have: device and inode,
        /// size, and the modification and status-change times. Only the kernel
        /// sets the status-change time, and it moves with every write.
        let stamp: [Int64]
    }

    /// Every entry under the folder, checked, sorted by path bytes.
    static func walk(_ root: URL, ownerUID: uid_t) throws -> [Entry] {
        guard try check(root.path, ownerUID: ownerUID).isDirectory else { throw Failure.unsafeTree }
        var entries: [Entry] = []
        var pending = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root.path : root.path + "/" + relative
            guard let names = try? FileManager().contentsOfDirectory(atPath: directory) else {
                throw Failure.changedWhileRead
            }
            for name in names where name != ".DS_Store" {
                let path = relative.isEmpty ? name : relative + "/" + name
                let found = try check(root.path + "/" + path, ownerUID: ownerUID)
                entries.append(Entry(path: path, isFile: !found.isDirectory, stamp: found.stamp))
                if found.isDirectory { pending.append(path) }
            }
        }
        return entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    private static func check(_ path: String, ownerUID: uid_t) throws -> (isDirectory: Bool, stamp: [Int64]) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.changedWhileRead }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR, info.st_uid == ownerUID,
              info.st_mode & 0o022 == 0 else { throw Failure.unsafeTree }
        return (type == S_IFDIR, [Int64(info.st_dev), Int64(bitPattern: UInt64(info.st_ino)), Int64(info.st_size),
                                  Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                                  Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)])
    }

    /// The digest of a folder already read, kept against every entry's stamp.
    /// A full read of Notes is about a thousand files; checking the stamps
    /// costs a stat each and is all a read costs while nothing has moved.
    final class TreeDigestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (walk: [Entry], digest: String)] = [:]

        func digest(of root: URL, ownerUID: uid_t) throws -> String {
            let before = try ClaudeExtensionConnectorPreparation.walk(root, ownerUID: ownerUID)
            lock.lock()
            let cached = entries[root.path]
            lock.unlock()
            if let cached, cached.walk == before { return cached.digest }
            let digest = try ClaudeExtensionConnectorPreparation.treeDigest(of: root, ownerUID: ownerUID)
            guard try ClaudeExtensionConnectorPreparation.walk(root, ownerUID: ownerUID) == before else {
                throw Failure.changedWhileRead
            }
            lock.lock()
            entries[root.path] = (before, digest)
            lock.unlock()
            return digest
        }
    }
}

extension ClaudeExtensionConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command && launch.arguments.count == 1
            && launch.arguments.first.flatMap(review(forFolder:)) != nil
    }

    /// A note read or written, or a tab read or opened, leaves nothing of the
    /// extension's own on the disk.
    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = resolved.review.role
        // A note holds whatever was pasted into it, and a page whatever its
        // site wrote, so neither is ever unfenced.
        precondition(role.handsBackUntrustedMaterial)
        let program: ClaudeTextConnectorProgram
        do {
            program = try fence.fenced(
                .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.entryPoint),
                label: role.fenceLabel)
        } catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [],
            // Both reviewed extensions run `osascript` by its bare name, so the
            // search path is set here rather than trusted to whatever the CLI
            // passes down. Notes' manifest also asks for HOME, which nothing it
            // loads reads; the CLI's own is left to stand.
            environment: ["PATH": ClaudeTextConnectorServer.systemSearchPath])
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            _ = try resolve(launch)
            // The fence is part of being launchable, so its absence is the
            // row's problem too, not a surprise inside a turn.
            try fence.verify()
            return .ready
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and this extension needs it "
                + "to run.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch Failure.notTheReviewedCopy {
            return .unavailable("This copy is not the one OpenBots Next checked, so it will not run it.")
        } catch Failure.blockedByClaudeDesktop {
            return .unavailable("Claude Desktop has blocked this extension, so OpenBots Next will not run it.")
        } catch Failure.blocklistUnreadable {
            return .unavailable("Claude Desktop's list of blocked extensions could not be read, so OpenBots Next "
                + "will not run this one.")
        } catch {
            return .unavailable("This extension cannot be read safely where Claude Desktop installed it.")
        }
    }
}
