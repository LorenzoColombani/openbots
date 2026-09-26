import CryptoKit
import Foundation
import OpenBotsDomain
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("Control this Mac finds exactly the pinned Peekaboo already on the disk, or reads needs setup")
struct MacControlConnectorPreparationTests {
    private struct Cache {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "mac-control-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func package(hash: String, version: String, binary: Data, permissions: Int = 0o755,
                     bin: [String: String] = ["peekaboo": "peekaboo", "peekaboo-mcp": "peekaboo-mcp.js"]) throws -> URL {
            let dir = root.appending(path: "\(hash)/node_modules/@steipete/peekaboo")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": "@steipete/peekaboo", "version": version, "bin": bin]
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appending(path: "package.json"))
            let file = dir.appending(path: "peekaboo")
            try binary.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            return file
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test("The pinned version with the pinned bytes resolves to its own binary, not the node wrapper")
    func resolvesThePinnedBinary() throws {
        let cache = try Cache(); defer { cache.remove() }
        let bytes = Data("peekaboo binary".utf8)
        _ = try cache.package(hash: "aaa", version: "3.9.0", binary: Data("old".utf8))
        let binary = try cache.package(hash: "bbb", version: "4.0.0", binary: bytes)
        let resolved = try MacControlConnectorPreparation(npxCacheRootURL: cache.root, pinnedSHA256: digest(bytes),
                                                          systemMajorVersion: 27).resolve()
        #expect(resolved.binaryURL.path == binary.standardizedFileURL.path)
    }

    @Test("A missing version, changed bytes, a writable or non-executable binary and an old macOS each read needs setup")
    func refusesAnythingElse() throws {
        let cache = try Cache(); defer { cache.remove() }
        let bytes = Data("peekaboo binary".utf8)
        #expect(throws: MacControlConnectorPreparation.Failure.packageNotCached) {
            try MacControlConnectorPreparation(npxCacheRootURL: cache.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27).resolve()
        }
        _ = try cache.package(hash: "bbb", version: "4.0.0", binary: Data("swapped".utf8))
        #expect(throws: MacControlConnectorPreparation.Failure.binaryChanged) {
            try MacControlConnectorPreparation(npxCacheRootURL: cache.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27).resolve()
        }
        let writable = try Cache(); defer { writable.remove() }
        _ = try writable.package(hash: "ccc", version: "4.0.0", binary: bytes, permissions: 0o777)
        #expect(throws: MacControlConnectorPreparation.Failure.binaryUnusable) {
            try MacControlConnectorPreparation(npxCacheRootURL: writable.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27).resolve()
        }
        let plain = try Cache(); defer { plain.remove() }
        _ = try plain.package(hash: "ddd", version: "4.0.0", binary: bytes, permissions: 0o644)
        #expect(throws: MacControlConnectorPreparation.Failure.binaryUnusable) {
            try MacControlConnectorPreparation(npxCacheRootURL: plain.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27).resolve()
        }
        let wrapperOnly = try Cache(); defer { wrapperOnly.remove() }
        _ = try wrapperOnly.package(hash: "eee", version: "4.0.0", binary: bytes, bin: ["peekaboo-mcp": "peekaboo-mcp.js"])
        #expect(throws: MacControlConnectorPreparation.Failure.binaryUnusable) {
            try MacControlConnectorPreparation(npxCacheRootURL: wrapperOnly.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27).resolve()
        }
        let good = try Cache(); defer { good.remove() }
        _ = try good.package(hash: "fff", version: "4.0.0", binary: bytes)
        #expect(throws: MacControlConnectorPreparation.Failure.systemTooOld) {
            try MacControlConnectorPreparation(npxCacheRootURL: good.root, pinnedSHA256: digest(bytes), systemMajorVersion: 14).resolve()
        }
    }

    /// Rewrites a file in place with bytes of the same length, then puts its
    /// modification time back to the exact nanosecond: the swap a size and
    /// modification-time check alone would miss.
    private func swapInPlaceKeepingTheTime(_ file: URL, with bytes: Data) throws {
        var before = stat()
        #expect(lstat(file.path, &before) == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: bytes)
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        var after = stat()
        #expect(lstat(file.path, &after) == 0)
        #expect(after.st_ino == before.st_ino && after.st_size == before.st_size)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    }

    @Test("The binary is read once while it stays the same file, and read again after any write, even with its time put back")
    func theDigestIsReadOncePerFileState() throws {
        let cache = try Cache(); defer { cache.remove() }
        let file = try cache.package(hash: "ggg", version: "4.0.0", binary: Data("peekaboo binary".utf8))
        let digests = MacControlConnectorPreparation.DigestCache()
        var reads = 0
        func read(_ url: URL) -> String? { reads += 1; return "digest \(reads)" }
        #expect(digests.digest(of: file, read: read) == "digest 1")
        #expect(digests.digest(of: file, read: read) == "digest 1")
        #expect(reads == 1)
        try swapInPlaceKeepingTheTime(file, with: Data("peekaboo BINARY".utf8))
        #expect(digests.digest(of: file, read: read) == "digest 2")
        #expect(reads == 2)
    }

    @Test("A same-size swap of the pinned binary with its modification time put back still reads as changed")
    func aSwapThatKeepsSizeAndTimeIsStillCaught() throws {
        let cache = try Cache(); defer { cache.remove() }
        let bytes = Data("peekaboo binary".utf8)
        let binary = try cache.package(hash: "hhh", version: "4.0.0", binary: bytes)
        let preparation = MacControlConnectorPreparation(npxCacheRootURL: cache.root, pinnedSHA256: digest(bytes),
                                                         systemMajorVersion: 27)
        _ = try preparation.resolve()
        try swapInPlaceKeepingTheTime(binary, with: Data("peekaboo BINARY".utf8))
        #expect(throws: MacControlConnectorPreparation.Failure.binaryChanged) { try preparation.resolve() }
    }

    @Test("The launch runs the pinned binary with mcp serve behind the fence, its tools narrowed to the reviewed list and its home in a folder the turn owns")
    func serverShape() throws {
        let cache = try Cache(); defer { cache.remove() }
        let bytes = Data("peekaboo binary".utf8)
        let binary = try cache.package(hash: "bbb", version: "4.0.0", binary: bytes)
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let preparation = MacControlConnectorPreparation(npxCacheRootURL: cache.root, pinnedSHA256: digest(bytes),
            systemMajorVersion: 27, accessibilityTrusted: { true }, screenRecordingAllowed: { true }, fence: fence)
        let launch = ConnectorLaunchConfiguration(serverKey: "openbots_mac", transport: .stdio,
            command: MacControlConnectorPreparation.command, arguments: [],
            pinnedPackage: "\(MacControlConnectorPreparation.packageName)@\(MacControlConnectorPreparation.pinnedVersion)")
        #expect(preparation.prepares(launch) && preparation.needsOwnedProfile)
        // The app's shared temporary folder, and the folder this one turn owns.
        let temporary = cache.root.appending(path: "tmp")
        let home = cache.root.appending(path: "Profiles.noindex/turn-1/openbots_mac")
        let server = try preparation.server(for: launch, profileURL: home, temporaryDirectoryURL: temporary, fence: fence)
        #expect(server.role == .macControl && server.program.isFenced)
        #expect(server.arguments.contains(binary.standardizedFileURL.path))
        #expect(server.arguments.suffix(2) == ["mcp", "serve"])
        #expect(server.environment["PEEKABOO_ALLOW_TOOLS"] == ClaudeTextMacControlApprovalPolicy.allowedTools.joined(separator: ","))
        // Capture writes files through spellings no card can check, and image hands the bot no picture on
        // Claude Code 2.1.280; see covers a screenshot.
        let exposed = Set((server.environment["PEEKABOO_ALLOW_TOOLS"] ?? "").split(separator: ",").map(String.init))
        #expect(!exposed.contains("capture") && !exposed.contains("image") && exposed.contains("see"), "\(exposed)")
        // The whole environment, so a key the closed vocabulary drops fails here
        // instead of taking the connector silently out of the turn.
        #expect(Set(server.environment.keys) == ["HOME", "TMPDIR", "CFFIXED_USER_HOME", "PEEKABOO_NO_REMOTE",
            "PEEKABOO_DISABLE_AGENT", "PEEKABOO_DISABLE_MCP_AUTOCONNECT", "PEEKABOO_ALLOW_TOOLS",
            "PEEKABOO_CONFIG_DIR", "PEEKABOO_CONFIG_DISABLE_MIGRATION"])
        #expect(server.environment["PEEKABOO_NO_REMOTE"] == "1" && server.environment["PEEKABOO_DISABLE_AGENT"] == "1")
        // Tachikoma's auto-connect policy compares this one to "true" exactly
        // (MCPClientManager.swift at Peekaboo 4.0.0's pinned submodule); "1" is
        // read as not set.
        #expect(server.environment["PEEKABOO_DISABLE_MCP_AUTOCONNECT"] == "true")
        // Foundation takes its home from CFFIXED_USER_HOME, never HOME (probed),
        // and Peekaboo keeps a copy of every screenshot `see`
        // takes under that home's .peekaboo/snapshots.
        #expect(server.environment["CFFIXED_USER_HOME"] == home.path)
        #expect(server.environment["HOME"] == home.path && server.environment["TMPDIR"] == home.path)
        #expect(server.environment["PEEKABOO_CONFIG_DIR"] == home.appending(path: ".peekaboo").path)
        #expect(server.environment["PEEKABOO_CONFIG_DISABLE_MIGRATION"] == "1")
        // The folder belongs to the turn: the launch service makes it and the
        // reaper takes it away with the turn, exactly as a browser profile.
        #expect(try ClaudeTextConnectorAccess(servers: [server]).ownedProfileURLs.map(\.path) == [home.path])
        // No folder of its own, no launch.
        #expect(throws: MacControlConnectorPreparation.Failure.self) {
            try preparation.server(for: launch, profileURL: nil, temporaryDirectoryURL: temporary, fence: fence)
        }
    }

    @Test("The row is ready only with the pinned copy, Accessibility and Screen Recording, and names the pane that is missing")
    func availabilityNamesWhatIsMissing() throws {
        let cache = try Cache(); defer { cache.remove() }
        let bytes = Data("peekaboo binary".utf8)
        _ = try cache.package(hash: "bbb", version: "4.0.0", binary: bytes)
        let launch = ConnectorLaunchConfiguration(serverKey: "", transport: .stdio,
            command: MacControlConnectorPreparation.command, arguments: [])
        func availability(ax: Bool, screen: Bool, root: URL? = nil) -> ConnectorAvailability? {
            MacControlConnectorPreparation(npxCacheRootURL: root ?? cache.root, pinnedSHA256: digest(bytes), systemMajorVersion: 27,
                accessibilityTrusted: { ax }, screenRecordingAllowed: { screen },
                fence: FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])).availability(for: launch)
        }
        #expect(availability(ax: true, screen: true) == .ready)
        guard case .needsSetup(let noAX) = availability(ax: false, screen: true) else { Issue.record("needs Accessibility"); return }
        #expect(noAX.contains("Accessibility"))
        guard case .needsSetup(let noScreen) = availability(ax: true, screen: false) else { Issue.record("needs Screen Recording"); return }
        #expect(noScreen.contains("Screen Recording"))
        let empty = try Cache(); defer { empty.remove() }
        guard case .needsSetup(let missing) = availability(ax: true, screen: true, root: empty.root) else { Issue.record("needs the package"); return }
        #expect(missing.contains("4.0.0"))
    }

    /// Whether a cache holds the pinned version's own manifest, the real-cache
    /// check's only reason to run: another version cached alone would make that
    /// check fail on a Mac where nothing is wrong.
    static func holdsThePinnedManifest(_ root: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).contains { entry in
            let url = root.appending(path: "\(entry)/node_modules/@steipete/peekaboo/package.json")
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return manifest["name"] as? String == MacControlConnectorPreparation.packageName
                && manifest["version"] as? String == MacControlConnectorPreparation.pinnedVersion
        }
    }

    /// This Mac's own npx cache, where the app looks for Peekaboo.
    static let realCacheRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".npm/_npx")

    @Test("The real-cache check runs only for the pinned version: another version cached alone is not the pin")
    func theRealCacheCheckWaitsForThePinnedVersion() throws {
        let other = try Cache(); defer { other.remove() }
        _ = try other.package(hash: "eee", version: "4.1.0", binary: Data("newer".utf8))
        #expect(!Self.holdsThePinnedManifest(other.root))
        let pinned = try Cache(); defer { pinned.remove() }
        _ = try pinned.package(hash: "fff", version: MacControlConnectorPreparation.pinnedVersion, binary: Data("pinned".utf8))
        #expect(Self.holdsThePinnedManifest(pinned.root))
    }

    // Skipped, and reported as skipped, on a Mac without the pinned version,
    // rather than passing there without checking anything.
    @Test("The real cached Peekaboo on this Mac matches the pin, when the pinned version is cached",
          .enabled(if: holdsThePinnedManifest(realCacheRoot), "Peekaboo 4.0.0 is not in this Mac's npx cache"))
    func theRealCacheMatchesThePin() throws {
        let resolved = try MacControlConnectorPreparation(npxCacheRootURL: Self.realCacheRoot).resolve()
        #expect(resolved.binaryURL.lastPathComponent == "peekaboo")
    }
}
