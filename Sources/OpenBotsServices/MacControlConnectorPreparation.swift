import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Finds the Peekaboo the old app ran for Control this Mac, without a package
/// manager and without the network: the exact pinned
/// version already in the user's npx cache, its own Swift binary, and that
/// binary's exact bytes. An uncached, different or altered copy reads "needs
/// setup"; nothing is ever fetched inside a turn.
public struct MacControlConnectorPreparation: Sendable {
    public static let packageName = "@steipete/peekaboo"
    public static let pinnedVersion = "4.0.0"
    /// The SHA-256 of the published 4.0.0 binary, signed by team FWJYW4S8P8.
    /// A package.json version alone would still run a swapped binary.
    public static let pinnedBinarySHA256 = "83abe6af1a4337f78b9324675438a7f71dcf7bf16b30615e8060f13d9b1b64d8"
    public static let minimumSystemMajorVersion = 15

    public enum Failure: Error, Equatable, Sendable {
        case packageNotCached
        case binaryUnusable
        case binaryChanged
        case systemTooOld
    }

    public struct ResolvedPackage: Equatable, Sendable {
        public let packageRootURL: URL
        public let binaryURL: URL
    }

    /// The command the app-owned row names for this connector.
    public static let command = "peekaboo"

    private let npxCacheRootURL: URL
    private let ownerUID: uid_t
    private let pinnedSHA256: String
    private let systemMajorVersion: Int
    private let accessibilityTrusted: @Sendable () -> Bool
    private let screenRecordingAllowed: @Sendable () -> Bool
    private let fence: FenceProxyResource
    /// Shared by every copy of this value, so the row and the launch read the
    /// binary once between them.
    private let digests = DigestCache()
    private var fileManager: FileManager { FileManager() }

    /// The digest of a binary already read, kept against the file's identity.
    /// The 4.0.0 binary is fifty-three megabytes, and hashing it took about a
    /// tenth of a second at every catalog read and every
    /// turn's launch.
    final class DigestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (identity: FileIdentity, digest: String)] = [:]

        /// The cached digest while the file is the same file in the same state,
        /// otherwise a fresh read, kept only if nothing moved while it was read.
        func digest(of url: URL, read: (URL) -> String?) -> String? {
            guard let identity = FileIdentity(url) else { return nil }
            lock.lock()
            let cached = entries[url.path]
            lock.unlock()
            if let cached, cached.identity == identity { return cached.digest }
            guard let digest = read(url), FileIdentity(url) == identity else { return nil }
            lock.lock()
            entries[url.path] = (identity, digest)
            lock.unlock()
            return digest
        }
    }

    /// What moves whenever a file's bytes may have: its device and inode, its
    /// size, and its modification and status-change times. The owner can put a
    /// modification time back after rewriting a file in place; the status-change
    /// time moves with every write and every change of times, and only the
    /// kernel sets it.
    struct FileIdentity: Equatable, Sendable {
        let device: Int64, inode: UInt64, size: Int64
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        let changedSeconds: Int, changedNanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// The two permission checks ask nobody: `AXIsProcessTrusted` and
    /// `CGPreflightScreenCaptureAccess` only read the current answer, so the
    /// row can say which pane to open without raising a prompt.
    public init(npxCacheRootURL: URL, ownerUID: uid_t = getuid(),
                pinnedSHA256: String = MacControlConnectorPreparation.pinnedBinarySHA256,
                systemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
                screenRecordingAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
                fence: FenceProxyResource = FenceProxyResource()) {
        self.npxCacheRootURL = npxCacheRootURL
        self.ownerUID = ownerUID
        self.pinnedSHA256 = pinnedSHA256
        self.systemMajorVersion = systemMajorVersion
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingAllowed = screenRecordingAllowed
        self.fence = fence
    }

    /// The cached copy of exactly the pinned version, with its binary checked.
    public func resolve() throws -> ResolvedPackage {
        guard systemMajorVersion >= Self.minimumSystemMajorVersion else { throw Failure.systemTooOld }
        let candidates = (try? fileManager.contentsOfDirectory(at: npxCacheRootURL,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var sawPinnedVersion = false
        for cache in candidates.sorted(by: { $0.path < $1.path }) {
            let root = cache.appendingPathComponent("node_modules/@steipete/peekaboo", isDirectory: true)
            guard let manifest = readManifest(root.appendingPathComponent("package.json")),
                  manifest["name"] as? String == Self.packageName,
                  manifest["version"] as? String == Self.pinnedVersion else { continue }
            sawPinnedVersion = true
            // The package's own binary, never the node wrapper that restarts a
            // crashed server behind the turn's back.
            guard let bin = manifest["bin"] as? [String: String], let relative = bin["peekaboo"] else {
                throw Failure.binaryUnusable
            }
            let binary = URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
            guard binary.path.hasPrefix(root.standardizedFileURL.path + "/"), isOwnedExecutable(binary) else {
                throw Failure.binaryUnusable
            }
            guard digests.digest(of: binary, read: Self.sha256(of:)) == pinnedSHA256 else { throw Failure.binaryChanged }
            return ResolvedPackage(packageRootURL: root.standardizedFileURL, binaryURL: binary)
        }
        throw sawPinnedVersion ? Failure.binaryUnusable : Failure.packageNotCached
    }

    private func readManifest(_ url: URL) -> [String: Any]? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A regular file this user owns, executable, and writable by no one else.
    private func isOwnedExecutable(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == ownerUID,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o022 == 0, permissions & 0o100 != 0 else { return false }
        return true
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension MacControlConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        launch.command == Self.command
    }

    /// A folder of its own for the turn, which is Peekaboo's home: it keeps a
    /// copy of every screenshot `see` takes under that home's .peekaboo, and
    /// the folder goes when the turn does.
    public var needsOwnedProfile: Bool { true }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        guard prepares(launch), launch.transport == .stdio, let home = profileURL else { throw Failure.binaryUnusable }
        let resolved = try resolve()
        let role = ClaudeTextConnectorRole.macControl
        // What it hands back is the user's screen, written by anyone: never unfenced.
        precondition(role.handsBackUntrustedMaterial)
        let program = try fence.fenced(.installedTool(resolved.binaryURL), label: role.fenceLabel)
        // Foundation takes the home from CFFIXED_USER_HOME and ignores HOME, so
        // HOME alone left Peekaboo's snapshot copies of the user's screen under
        // the real ~/.peekaboo (probed); HOME and TMPDIR stay for
        // anything that reads them directly. Its loose temporary images still
        // land in the account's own temporary folder, which no variable moves.
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [.mcpServe, .ownedHome(home)],
            environment: [
                "HOME": home.path,
                "TMPDIR": home.path,
                "CFFIXED_USER_HOME": home.path,
                "PEEKABOO_NO_REMOTE": "1",
                "PEEKABOO_DISABLE_AGENT": "1",
                // Compared to "true" exactly by Tachikoma's auto-connect policy.
                "PEEKABOO_DISABLE_MCP_AUTOCONNECT": "true",
                "PEEKABOO_ALLOW_TOOLS": ClaudeTextMacControlApprovalPolicy.allowedTools.joined(separator: ","),
                "PEEKABOO_CONFIG_DIR": home.appendingPathComponent(".peekaboo", isDirectory: true).path,
                "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
            ])
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            _ = try resolve()
            try fence.verify()
        } catch Failure.systemTooOld {
            return .unavailable("Control this Mac needs macOS \(Self.minimumSystemMajorVersion) or later.")
        } catch Failure.packageNotCached {
            return .needsSetup("Peekaboo \(Self.pinnedVersion) is not on this Mac. Run "
                + "`npx -y \(Self.packageName)@\(Self.pinnedVersion) --version` once in Terminal, then come back.")
        } catch Failure.binaryChanged {
            return .needsSetup("The Peekaboo \(Self.pinnedVersion) on this Mac is not the copy OpenBots checked, "
                + "so it will not run it.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The Peekaboo \(Self.pinnedVersion) on this Mac cannot be used as it is.")
        }
        var missing: [String] = []
        if !accessibilityTrusted() { missing.append("Accessibility") }
        if !screenRecordingAllowed() { missing.append("Screen Recording") }
        guard missing.isEmpty else {
            return .needsSetup("Turn on OpenBots Next in System Settings, Privacy & Security, "
                + missing.joined(separator: " and ") + ", then quit and reopen the app.")
        }
        return .ready
    }
}
