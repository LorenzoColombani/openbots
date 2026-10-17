import CryptoKit
import Foundation

public struct SourceAppUpdateConfiguration: Sendable {
    public let feedURL: URL
    public let publicKey: Data
    public let repository: String

    public init(feedURL: URL, publicKey: Data, repository: String = "LorenzoColombani/openbots") {
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.repository = repository
    }
}

public struct SourceAppUpdateFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let mode: String
    public init(path: String, sha256: String, mode: String) {
        self.path = path; self.sha256 = sha256; self.mode = mode
    }
}

public struct VerifiedSourceAppUpdate: Equatable, Sendable {
    public let version: String
    public let build: String
    public let sourceCommit: String
    public let files: [SourceAppUpdateFile]
    // A public initializer supports presentation fakes. The service independently
    // authenticates this envelope again before using any of these properties.
    let signedEnvelope: Data

    public init(version: String, build: String, sourceCommit: String,
                files: [SourceAppUpdateFile] = [], signedEnvelope: Data = Data()) {
        self.version = version; self.build = build; self.sourceCommit = sourceCommit
        self.files = files; self.signedEnvelope = signedEnvelope
    }
}

public enum SourceAppUpdateError: Error, Equatable, LocalizedError {
    case invalidConfiguration, invalidManifest, invalidSignature, unsafeInventory
    case busy, cancelled, cancellationIncomplete, invalidPreparation, workerUnavailable
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The source update channel is not configured correctly."
        case .invalidManifest: "The source update manifest is malformed or exceeds its limits."
        case .invalidSignature: "The source update signature could not be verified."
        case .unsafeInventory: "The source update contains an unsafe or incomplete file inventory."
        case .busy: "Another source update operation is still running."
        case .cancelled: "The source update was cancelled."
        case .cancellationIncomplete: "The update worker has not confirmed it stopped. Keep the app open and try again."
        case .invalidPreparation: "The prepared source update no longer matches this app. Prepare the update again."
        case .workerUnavailable: "Source updates need the Xcode command line Python runtime and the bundled update worker."
        case .operationFailed(let message): message
        }
    }
}

/// The only authority for downloaded source. Authentication precedes payload
/// parsing, and canonical JSON rejects duplicate keys or alternate spellings.
public enum SourceAppUpdateManifest {
    public static let maximumEnvelopeBytes = 8 * 1_024 * 1_024
    public static let maximumPayloadBytes = 5 * 1_024 * 1_024
    public static let maximumFiles = 20_000

    public static func verify(_ envelope: Data, configuration: SourceAppUpdateConfiguration) throws -> VerifiedSourceAppUpdate {
        try validate(configuration)
        guard envelope.count <= maximumEnvelopeBytes,
              let outer = try? canonicalObject(envelope), Set(outer.keys) == ["payload", "signature"],
              let payloadText = outer["payload"] as? String,
              let signatureText = outer["signature"] as? String,
              let payload = Data(base64Encoded: payloadText), payload.count <= maximumPayloadBytes,
              payload.base64EncodedString() == payloadText,
              let signature = Data(base64Encoded: signatureText), signature.count == 64,
              signature.base64EncodedString() == signatureText else { throw SourceAppUpdateError.invalidManifest }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: configuration.publicKey)
        guard key.isValidSignature(signature, for: payload) else { throw SourceAppUpdateError.invalidSignature }

        guard let object = try? canonicalObject(payload),
              Set(object.keys) == ["schema", "version", "build", "sourceCommit", "files"],
              let schema = object["schema"] as? NSNumber,
              ["s", "i", "l", "q"].contains(String(cString: schema.objCType)), schema.intValue == 1,
              let version = object["version"] as? String, validVersion(version),
              let build = object["build"] as? String, validBuild(build),
              let commit = object["sourceCommit"] as? String, hex(commit, count: 40),
              let entries = object["files"] as? [[String: Any]],
              !entries.isEmpty, entries.count <= maximumFiles else { throw SourceAppUpdateError.invalidManifest }

        var files: [SourceAppUpdateFile] = []
        var names = Set<String>()
        var spellings: [String: String] = [:]
        for entry in entries {
            guard Set(entry.keys) == ["path", "sha256", "mode"],
                  let path = entry["path"] as? String, safePath(path),
                  let hash = entry["sha256"] as? String, hex(hash, count: 64),
                  let mode = entry["mode"] as? String, ["100644", "100755"].contains(mode),
                  names.insert(path).inserted else { throw SourceAppUpdateError.unsafeInventory }
            let components = path.components(separatedBy: "/")
            // Git metadata and locally generated build/configuration state are
            // never part of a public source inventory.
            guard !components.contains(where: { $0 == ".git" || $0 == ".build" || $0.hasSuffix(".noindex") }) else {
                throw SourceAppUpdateError.unsafeInventory
            }
            for count in 1...components.count {
                let spelling = components.prefix(count).joined(separator: "/")
                let canonical = spelling.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = spellings[canonical], !previous.utf8.elementsEqual(spelling.utf8) {
                    throw SourceAppUpdateError.unsafeInventory
                }
                spellings[canonical] = spelling
            }
            files.append(.init(path: path, sha256: hash, mode: mode))
        }
        for path in names {
            let parts = path.components(separatedBy: "/")
            for length in 1..<parts.count where names.contains(parts.prefix(length).joined(separator: "/")) {
                throw SourceAppUpdateError.unsafeInventory
            }
        }
        guard names.contains("Scripts/build-source-update.sh"), names.contains("Scripts/source-update-sign.py"),
              names.contains("Scripts/swiftpm-public.sh") else {
            throw SourceAppUpdateError.unsafeInventory
        }
        return .init(version: version, build: build, sourceCommit: commit, files: files, signedEnvelope: envelope)
    }

    public static func archiveURL(for release: VerifiedSourceAppUpdate, configuration: SourceAppUpdateConfiguration) throws -> URL {
        try validate(configuration)
        guard hex(release.sourceCommit, count: 40),
              let url = URL(string: "https://codeload.github.com/\(configuration.repository)/tar.gz/\(release.sourceCommit)") else {
            throw SourceAppUpdateError.invalidManifest
        }
        return url
    }

    public static func isNewer(_ build: String, than current: String) throws -> Bool {
        guard validBuild(build), validBuild(current), let candidate = UInt64(build), let installed = UInt64(current) else {
            throw SourceAppUpdateError.invalidConfiguration
        }
        return candidate > installed
    }

    static func validate(_ configuration: SourceAppUpdateConfiguration) throws {
        let url = configuration.feedURL
        guard configuration.publicKey.count == 32,
              configuration.repository == "LorenzoColombani/openbots",
              url.scheme == "https", url.host == "raw.githubusercontent.com",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/\(configuration.repository)/main/docs/updates/source-update.json" else {
            throw SourceAppUpdateError.invalidConfiguration
        }
    }

    private static func canonicalObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) == data else {
            throw SourceAppUpdateError.invalidManifest
        }
        return object
    }

    static func hex(_ string: String, count: Int) -> Bool {
        string.utf8.count == count && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validBuild(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 18 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func validVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 6 && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    static func safePath(_ value: String) -> Bool {
        let parts = value.components(separatedBy: "/")
        return !value.isEmpty && value.utf8.count <= 1_024 && parts.count <= 64
            && !value.contains("\\") && !value.contains(":")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
}
