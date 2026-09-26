import CryptoKit
import Darwin
import Foundation
import OpenBotsDomain

/// The Claude Desktop extensions installed on this Mac, listed beside the
/// connectors Claude Code configured and the ones the app ships.
///
/// Every extension Claude Desktop installed is a row, and each is unavailable
/// until this build has reviewed it: an extension is someone else's server
/// running as the user, so being installed for Claude Desktop is not a reason for a
/// bot to run it. A reviewed one runs only as the copy that was reviewed
/// (`ClaudeExtensionConnectorPreparation`).
///
/// Like the other catalogs this reads and never runs. A missing folder is an
/// empty list, not a failure; a folder whose name or manifest cannot be read
/// safely is one row left out and counted, never the whole list.
public struct ClaudeExtensionConnectorCatalog: ConnectorCatalogReading {
    /// Why an extension this build has not reviewed cannot be turned on, by
    /// folder. Anything not named here is not reviewed in this version yet.
    public static let notOffered: [String: String] = [
        "ant.dir.ant.anthropic.filesystem": "A bot's Work folders do this, with a card for every change.",
        "ant.dir.gh.k6l3.osascript": "It runs any AppleScript as you. Control this Mac does this, with cards.",
        // Deferred to a possible later version.
        "ant.dir.ant.anthropic.imessage": "Not in this version. The Messages connector reads the chats you choose "
            + "and sends on a card.",
    ]
    public static let notReviewedYet = "Not reviewed in this version of OpenBots Next yet."
    /// A reviewed extension this read could not make out: a file unreadable for
    /// a moment, a manifest that would not open, a folder that would not list.
    public static let couldNotReadNow = "This extension could not be read just now. A bot's switch for it is kept, "
        + "and it is read again next time."
    public static let pluginName = "Claude Desktop extension"
    static let maximumManifestBytes = 1_048_576

    private let preparation: ClaudeExtensionConnectorPreparation
    private let extensionsRootURL: URL
    private let ownerUID: uid_t

    public init(extensionsRootURL: URL, preparation: ClaudeExtensionConnectorPreparation,
                ownerUID: uid_t = getuid()) {
        self.extensionsRootURL = extensionsRootURL
        self.preparation = preparation
        self.ownerUID = ownerUID
    }

    public func loadConnectorCatalog() async throws -> ConnectorCatalogSnapshot {
        try Task.checkCancellation()
        // No folder is no extensions: Claude Desktop is not installed, or has
        // none. A folder that is there and will not list says nothing about
        // them, so the reviewed rows are held as they were rather than dropped,
        // which would switch every bot's grant off for good.
        var info = stat()
        guard lstat(extensionsRootURL.path, &info) == 0 else {
            return ConnectorCatalogSnapshot(connectors: [], excludedCount: 0)
        }
        guard let folders = try? FileManager().contentsOfDirectory(atPath: extensionsRootURL.path) else {
            return ConnectorCatalogSnapshot(connectors: preparation.knownReviews.compactMap { review in
                Self.serverName(forFolder: review.folder).flatMap { held(folder: review.folder, server: $0, review: review) }
            }, excludedCount: 0)
        }
        var connectors: [ConfiguredConnector] = []
        var excluded = 0
        for folder in folders.sorted() where !folder.hasPrefix(".") {
            try Task.checkCancellation()
            if let row = row(folder: folder) { connectors.append(row) } else { excluded += 1 }
        }
        return ConnectorCatalogSnapshot(connectors: connectors, excludedCount: excluded)
    }

    /// One extension's row, or nil when its folder or manifest cannot be read
    /// safely.
    func row(folder: String) -> ConfiguredConnector? {
        let root = extensionsRootURL.appendingPathComponent(folder, isDirectory: true)
        guard let server = Self.serverName(forFolder: folder) else { return nil }
        if let review = preparation.review(forFolder: folder) {
            return reviewedRow(folder: folder, server: server, review: review, root: root)
        }
        guard isOwnedDirectory(root.path), let manifest = readManifest(root.appendingPathComponent("manifest.json").path),
              let version = manifest["version"] as? String, Self.isPlainVersion(version) else { return nil }
        let title = Self.words(manifest["display_name"] as? String ?? manifest["name"] as? String, limit: 80) ?? folder
        let author = Self.words((manifest["author"] as? [String: Any])?["name"] as? String, limit: 60)
        let description = Self.words(manifest["description"] as? String, limit: 300)
        let summary = [description, "\(Self.pluginName)\(author.map { " by \($0)" } ?? "") · version \(version)"]
            .compactMap { $0 }.joined(separator: "\n")
        return connector(folder: folder, server: server, version: version, tree: nil, title: title, summary: summary,
                         availability: .unowned(Self.notOffered[folder] ?? Self.notReviewedYet))
    }

    /// A reviewed extension's row. What the disk says for certain decides it: the
    /// reviewed copy is ready, another version or a changed or unsafe copy is
    /// unavailable, and the digest in its identity turns a grant off with the
    /// "changed" line. A read that could not tell holds the row as it was.
    private func reviewedRow(folder: String, server: String, review: ClaudeExtensionConnectorPreparation.Review,
                             root: URL) -> ConfiguredConnector? {
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return nil }
        guard let manifest = readManifest(root.appendingPathComponent("manifest.json").path),
              let version = manifest["version"] as? String, Self.isPlainVersion(version) else {
            return held(folder: folder, server: server, review: review)
        }
        guard version == review.version else {
            return connector(folder: folder, server: server, version: version, tree: nil, title: review.title,
                             summary: review.summary, availability: .unavailable("This is version \(version); "
                                + "OpenBots Next checked version \(review.version), so it will not run it."))
        }
        let digest: String
        do {
            digest = try preparation.currentDigest(ofFolder: folder)
        } catch ClaudeExtensionConnectorPreparation.Failure.unsafeTree {
            return connector(folder: folder, server: server, version: version, tree: "unsafe", title: review.title,
                             summary: review.summary, availability: .unavailable(
                                "This extension cannot be read safely where Claude Desktop installed it."))
        } catch {
            return held(folder: folder, server: server, review: review)
        }
        return connector(folder: folder, server: server, version: version, tree: digest, title: review.title,
                         summary: review.summary, availability: digest == review.treeSHA256 ? .ready
                            : .unavailable("This copy is not the one OpenBots Next checked, so it will not run it."))
    }

    /// The row of a reviewed extension this read could not make out. Its
    /// identity is a placeholder the store swaps for the one it already holds.
    private func held(folder: String, server: String,
                      review: ClaudeExtensionConnectorPreparation.Review) -> ConfiguredConnector? {
        connector(folder: folder, server: server, version: review.version, tree: "unread", title: review.title,
                  summary: review.summary, availability: .unavailable(Self.couldNotReadNow), holdsPriorIdentity: true)
    }

    private func connector(folder: String, server: String, version: String, tree: String?, title: String,
                           summary: String, availability: ConnectorAvailability,
                           holdsPriorIdentity: Bool = false) -> ConfiguredConnector? {
        let id = "\(ConnectorSource.claudeExtension.rawValue):\(folder):\(server)"
        var canonical: [String: Any] = ["namespace": id, "type": "stdio",
                                        "command": ClaudeExtensionConnectorPreparation.command,
                                        "args": [folder], "package": "\(folder)@\(version)"]
        if let tree { canonical["tree"] = tree }
        guard let data = try? JSONSerialization.data(withJSONObject: canonical,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let identity = try? ConnectorIdentity(id: id, digest: Self.hash(data)) else { return nil }
        return ConfiguredConnector(
            definition: .init(identity: identity, serverName: server, pluginName: Self.pluginName,
                              transport: .stdio, title: title, summary: summary, availability: availability),
            launch: .init(serverKey: "openbots_" + Self.hash(Data(id.utf8)), transport: .stdio,
                          command: ClaudeExtensionConnectorPreparation.command, arguments: [folder],
                          pinnedPackage: "\(folder)@\(version)"),
            holdsPriorIdentity: holdsPriorIdentity)
    }

    /// The server segment of a row's identity: the last dot-separated part of
    /// the folder name (`notes`, `osascript`), or nil when the folder name is
    /// not one an identity can carry.
    static func serverName(forFolder folder: String) -> String? {
        let pattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"
        guard folder.utf8.count <= 100, folder.range(of: pattern, options: .regularExpression) != nil,
              let last = folder.split(separator: ".").last.map(String.init),
              last.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return last
    }

    /// Digits and dots, as every manifest seen so far writes one; anything else
    /// is a manifest this does not read.
    static func isPlainVersion(_ version: String) -> Bool {
        !version.isEmpty && version.utf8.count <= 32
            && version.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
    }

    /// A manifest's words, on one line and bounded, or nil when there are none.
    static func words(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let line = ClaudeTextAppleMailSendApprovalPolicy.fragment(value, limit)
        return line.isEmpty ? nil : line
    }

    private func isOwnedDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == ownerUID
            && info.st_mode & 0o022 == 0
    }

    private func readManifest(_ path: String) -> [String: Any]? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID,
              info.st_size <= Self.maximumManifestBytes,
              let data = FileManager().contents(atPath: path), data.count <= Self.maximumManifestBytes
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
