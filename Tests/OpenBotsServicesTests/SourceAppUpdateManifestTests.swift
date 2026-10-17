import CryptoKit
import Foundation
import Testing
@testable import OpenBotsServices

@Suite("Signed source update manifest")
struct SourceAppUpdateManifestTests {
    private let key = Curve25519.Signing.PrivateKey()
    private let commit = String(repeating: "a", count: 40)
    private var configuration: SourceAppUpdateConfiguration {
        .init(feedURL: URL(string: "https://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json")!,
              publicKey: key.publicKey.rawRepresentation)
    }

    private func object() -> [String: Any] {
        ["schema": 1, "version": "1.1", "build": "3008", "sourceCommit": commit, "files": [
            ["path": "Scripts/build-source-update.sh", "sha256": String(repeating: "b", count: 64), "mode": "100755"],
            ["path": "Scripts/source-update-sign.py", "sha256": String(repeating: "e", count: 64), "mode": "100644"],
            ["path": "Scripts/swiftpm-public.sh", "sha256": String(repeating: "c", count: 64), "mode": "100755"]
        ]]
    }
    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func signed(_ value: [String: Any]) throws -> Data { try signedBytes(json(value)) }
    private func signedBytes(_ bytes: Data) throws -> Data {
        try json(["payload": bytes.base64EncodedString(), "signature": key.signature(for: bytes).base64EncodedString()])
    }

    @Test("Exact signed bytes authorize only a fixed immutable public commit archive")
    func validManifest() throws {
        let value = try SourceAppUpdateManifest.verify(signed(object()), configuration: configuration)
        #expect(value.version == "1.1")
        #expect(value.build == "3008")
        #expect(try SourceAppUpdateManifest.archiveURL(for: value, configuration: configuration).absoluteString
                == "https://codeload.github.com/LorenzoColombani/openbots/tar.gz/" + commit)
        #expect(try SourceAppUpdateManifest.isNewer(value.build, than: "3007"))
        #expect(try !SourceAppUpdateManifest.isNewer(value.build, than: "3008"))
    }

    @Test("Invalid signatures fail before malformed payload JSON is inspected")
    func authenticatesBeforeParsing() throws {
        let bytes = Data("not JSON".utf8)
        let other = Curve25519.Signing.PrivateKey()
        let envelope = try json(["payload": bytes.base64EncodedString(), "signature": other.signature(for: bytes).base64EncodedString()])
        #expect(throws: SourceAppUpdateError.invalidSignature) {
            try SourceAppUpdateManifest.verify(envelope, configuration: configuration)
        }
    }

    @Test("Unknown authority fields and malformed ordered versions fail closed", arguments: [
        "command", "archiveURL", "numericBuild", "leadingZero", "zero", "negative", "overflow", "boolSchema", "version", "commit"
    ])
    func malformedFields(_ kind: String) throws {
        var value = object()
        switch kind {
        case "numericBuild": value["build"] = 3008
        case "leadingZero": value["build"] = "03008"
        case "zero": value["build"] = "0"
        case "negative": value["build"] = "-1"
        case "overflow": value["build"] = String(repeating: "9", count: 30)
        case "boolSchema": value["schema"] = true
        case "version": value["version"] = "1.1;touch bad"
        case "commit": value["sourceCommit"] = "main"
        default: value[kind] = "https://example.invalid/source"
        }
        #expect(throws: SourceAppUpdateError.invalidManifest) {
            try SourceAppUpdateManifest.verify(signed(value), configuration: configuration)
        }
    }

    @Test("Signed duplicate keys and noncanonical encodings are rejected")
    func ambiguousJSON() throws {
        var bytes = try json(object())
        bytes.insert(contentsOf: Data("\"schema\":1,".utf8), at: 1)
        #expect(throws: SourceAppUpdateError.invalidManifest) {
            try SourceAppUpdateManifest.verify(signedBytes(bytes), configuration: configuration)
        }
        let whitespace = Data(" ".utf8) + (try json(object()))
        #expect(throws: SourceAppUpdateError.invalidManifest) {
            try SourceAppUpdateManifest.verify(signedBytes(whitespace), configuration: configuration)
        }
    }

    @Test("Inventory rejects traversal, aliases, metadata, parent files and executable ambiguity", arguments: [
        "../escape", "/escape", "Sources/../escape", "Sources\\escape", "Sources/a:b", ".git/config",
        ".build.noindex/secret", "Sources/A.swift", "Sources", "mode", "missingBuild", "duplicate", "hash"
    ])
    func unsafeFiles(_ kind: String) throws {
        var value = object()
        var files = value["files"] as! [[String: String]]
        files.append(["path": "Sources/a.swift", "sha256": String(repeating: "d", count: 64), "mode": "100644"])
        switch kind {
        case "mode": files[0]["mode"] = "100777"
        case "missingBuild": files.removeFirst()
        case "duplicate": files.append(files[0])
        case "hash": files[0]["sha256"] = String(repeating: "A", count: 64)
        default: files.append(["path": kind, "sha256": String(repeating: "e", count: 64), "mode": "100644"])
        }
        value["files"] = files
        #expect(throws: SourceAppUpdateError.unsafeInventory) {
            try SourceAppUpdateManifest.verify(signed(value), configuration: configuration)
        }
    }

    @Test("Configured repository and feed cannot become arbitrary download endpoints", arguments: [
        "http://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json",
        "https://user@raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json",
        "https://example.com/source-update.json",
        "https://raw.githubusercontent.com/LorenzoColombani/openbots/main/docs/updates/source-update.json?token=x"
    ])
    func unsafeFeed(_ url: String) throws {
        let config = SourceAppUpdateConfiguration(feedURL: URL(string: url)!, publicKey: key.publicKey.rawRepresentation)
        #expect(throws: SourceAppUpdateError.invalidConfiguration) {
            try SourceAppUpdateManifest.verify(signed(object()), configuration: config)
        }
    }

    @Test("A fabricated presentation value cannot authorize a build")
    func presentationIsNotAuthority() async throws {
        let service = SourceAppUpdateService(configuration: configuration,
            installedApplicationURL: URL(fileURLWithPath: "/nonexistent/OpenBots Next.app"), currentBuild: "3007",
            googleConfiguration: .init())
        let fabricated = VerifiedSourceAppUpdate(version: "1.1", build: "3008", sourceCommit: commit)
        await #expect(throws: SourceAppUpdateError.invalidManifest) {
            try await service.prepare(fabricated, progress: { _ in })
        }
    }
}
