import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// Turns one configured browser connector into a launch the turn can actually
/// run, without a package manager and without the shell.
///
/// The catalog reports what Claude Code is configured with, which for the
/// browser is `npx chrome-devtools-mcp@1.8.0`. Running that verbatim would put
/// an `npx` resolution — and, if the cache were ever pruned, a network fetch —
/// inside a turn, and would resolve through a `PATH` the child does not have.
/// So the configured spelling is treated as a *statement of which package*,
/// and this resolves that exact name and version to a copy already on the disk,
/// launched by an absolute interpreter. If the pinned version is not cached the
/// resolution fails closed and the connector reads "needs setup"; it never
/// falls back to `npx`, and it never fetches anything.
public struct BrowserConnectorPreparation: Sendable {
    /// The only server package this preparation knows how to prepare. Mail,
    /// calendar and Drive have preparations of their own.
    public static let browserPackageName = "chrome-devtools-mcp"

    public enum Failure: Error, Equatable, Sendable {
        /// The connector is configured, but not as the browser server.
        case notABrowserConnector
        /// Only a stdio server can be resolved to a local entry point.
        case unsupportedTransport
        /// The configured arguments name no `package@version`.
        case malformedPackageSpecification
        /// The pinned version is not on the disk. This is the "needs setup"
        /// state: recoverable by the user, never by a fetch inside a turn.
        case packageNotCached(version: String)
        /// The cached package is there but unusable, or not ours.
        case entryPointUnusable
        /// No absolute interpreter to run it with.
        case interpreterMissing
        /// The browser it would drive is not installed.
        case browserMissing
    }

    /// What the resolution found, kept so the digest can bind the launch that
    /// actually ran rather than the spelling that was configured.
    public struct ResolvedPackage: Equatable, Sendable {
        public let packageName: String
        public let version: String
        public let cacheDirectoryURL: URL
        public let entryPointURL: URL
        public let interpreterURL: URL
        public let browserURL: URL
    }

    private let npxCacheRootURL: URL
    private let interpreterCandidateURLs: [URL]
    private let browserCandidateURLs: [URL]
    private let ownerUID: uid_t

    /// Made per call: `FileManager` is not `Sendable`, and the existing
    /// connector catalog reads the disk the same way.
    private var fileManager: FileManager { FileManager() }

    /// The default locations, named once. They are candidates, not promises:
    /// each is checked before it is used, and an absent one is simply skipped.
    public static let defaultInterpreterURLs = [
        URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        URL(fileURLWithPath: "/usr/local/bin/node"),
    ]
    public static let defaultBrowserURLs = [
        URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    ]

    public init(npxCacheRootURL: URL,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                browserCandidateURLs: [URL] = BrowserConnectorPreparation.defaultBrowserURLs,
                ownerUID: uid_t = getuid()) {
        self.npxCacheRootURL = npxCacheRootURL
        self.interpreterCandidateURLs = interpreterCandidateURLs
        self.browserCandidateURLs = browserCandidateURLs
        self.ownerUID = ownerUID
    }

    /// The user's npx cache, where a `npx <package>@<version>` invocation has
    /// already put every version it has ever run.
    public static func defaultNPXCacheRootURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".npm/_npx", isDirectory: true)
    }

    // MARK: - Resolution

    /// The `package@version` the configured command names, with no opinion yet
    /// about whether it is on the disk.
    public static func packageSpecification(in launch: ConnectorLaunchConfiguration) throws -> (name: String, version: String) {
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard let command = launch.command, ["npx", "node"].contains(command) else {
            throw Failure.notABrowserConnector
        }
        // `npx -y name@version`, `npx name@version`: the first argument that is
        // not a flag is the specification.
        guard let specification = launch.arguments.first(where: { !$0.hasPrefix("-") }),
              let separator = specification.lastIndex(of: "@"), separator != specification.startIndex
        else { throw Failure.malformedPackageSpecification }
        let name = String(specification[specification.startIndex..<separator])
        let version = String(specification[specification.index(after: separator)...])
        guard name == browserPackageName else { throw Failure.notABrowserConnector }
        guard !version.isEmpty, version != "latest",
              version.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 })
        else { throw Failure.malformedPackageSpecification }
        return (name, version)
    }

    /// Finds the cached copy of that exact version.
    ///
    /// The cache holds one opaque hash directory per invocation — often several
    /// for this package, one per version ever run — so the version
    /// recorded in each copy's own `package.json` is the only safe key. A
    /// directory whose version does not match exactly is not a near miss; it is
    /// a different package.
    public func resolve(_ launch: ConnectorLaunchConfiguration) throws -> ResolvedPackage {
        let specification = try Self.packageSpecification(in: launch)
        let interpreterURL = try interpreterCandidateURLs.compactMap(usableTool).first
            .orThrow(Failure.interpreterMissing)
        let browserURL = try browserCandidateURLs.compactMap(usableTool).first
            .orThrow(Failure.browserMissing)

        let candidates = (try? fileManager.contentsOfDirectory(at: npxCacheRootURL,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for cacheDirectoryURL in candidates.sorted(by: { $0.path < $1.path }) {
            let packageRoot = cacheDirectoryURL
                .appendingPathComponent("node_modules", isDirectory: true)
                .appendingPathComponent(specification.name, isDirectory: true)
            guard let manifest = readManifest(at: packageRoot.appendingPathComponent("package.json")),
                  manifest["version"] as? String == specification.version else { continue }
            guard let relativeEntry = Self.binaryEntry(in: manifest, named: specification.name) else {
                throw Failure.entryPointUnusable
            }
            let entryPointURL = URL(fileURLWithPath: relativeEntry, relativeTo: packageRoot)
                .standardizedFileURL
            guard entryPointURL.path.hasPrefix(packageRoot.standardizedFileURL.path + "/"),
                  isUsableFile(entryPointURL) else { throw Failure.entryPointUnusable }
            return ResolvedPackage(packageName: specification.name, version: specification.version,
                cacheDirectoryURL: cacheDirectoryURL.standardizedFileURL, entryPointURL: entryPointURL,
                interpreterURL: interpreterURL, browserURL: browserURL)
        }
        throw Failure.packageNotCached(version: specification.version)
    }

    // MARK: - The launch

    /// The frozen launch for one turn.
    ///
    /// `profileURL` is this turn's own browser profile: fresh, app-owned, and
    /// deleted when the turn ends. It is
    /// also the ownership token — Chrome runs in its own process group, so the
    /// turn's group kill cannot reach it, and the only honest way to tell the
    /// app's Chrome from the user's is this path in its argument vector.
    /// `fence` is the app's own shim. A page's text is written by strangers,
    /// so the browser is never launched without it: no shim, no browser.
    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource = FenceProxyResource()) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        let role = ClaudeTextConnectorRole.browser
        return try ClaudeTextConnectorServer(
            name: launch.serverKey,
            role: role,
            program: try fence.fenced(.node(interpreterURL: resolved.interpreterURL,
                                            entryPointURL: resolved.entryPointURL),
                                      label: role.fenceLabel),
            options: [.headless, .userDataDirectory(profileURL), .executablePath(resolved.browserURL)],
            environment: [
                // The server's home, not Claude's: its cache and its profile
                // must never land in the login the turn authenticates with.
                "HOME": profileURL.deletingLastPathComponent().path,
                "TMPDIR": temporaryDirectoryURL.path,
                "LANG": "en_US.UTF-8",
                // Containment, not courtesy: without this the server spawns a
                // telemetry watchdog into its own process group, out of reach
                // of the turn's kill.
                "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1",
                // No update check means no network call at launch. The spelling
                // is plural; the singular one the earlier draft used is read by
                // nothing.
                "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1",
                "DO_NOT_TRACK": "1",
                "NO_UPDATE_NOTIFIER": "1",
            ])
    }

    // MARK: - Reading the disk

    private func readManifest(at url: URL) -> [String: Any]? {
        guard isUsableFile(url), let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// npm allows `bin` to be a string or a map of names to paths.
    static func binaryEntry(in manifest: [String: Any], named name: String) -> String? {
        if let single = manifest["bin"] as? String { return single }
        guard let map = manifest["bin"] as? [String: String] else { return nil }
        return map[name] ?? map.sorted(by: { $0.key < $1.key }).first?.value
    }

    /// Ours, a regular file, and not writable by anyone else — the same
    /// standard the connector catalog holds its own reads to. This is the
    /// stricter of the two: these files live in the user's own npm cache, where
    /// nothing but npm should ever be writing, so there is no ordinary
    /// installation that needs the looser rule.
    private func isUsableFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == ownerUID,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o022 == 0
        else { return false }
        return true
    }

    /// An installed tool this turn will run. The rule, and the two refusals
    /// that taught it, live in `InstalledToolResolution` — the mail reader is
    /// resolved by exactly the same standard.
    private func usableTool(_ url: URL) -> URL? { InstalledToolResolution(ownerUID: ownerUID).resolve(url) }
}

private extension Optional {
    func orThrow(_ error: some Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}
