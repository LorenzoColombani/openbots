import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing

@Suite("Google public configuration control metadata")
struct SQLiteGoogleWorkspacePublicConfigurationTests {
    @Test("One bounded row survives reopening and cannot replace an existing identity")
    func roundTrip() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.open()
        let before = try await first.query(sql: "SELECT key,value FROM app_metadata ORDER BY key;")
        #expect(try await first.loadGoogleWorkspacePublicConfiguration() == nil)
        let config = try GoogleWorkspacePublicConfiguration(clientID: "fixture.apps.googleusercontent.com")
        try await first.seedGoogleWorkspacePublicConfiguration(config)
        let reopened = try fixture.open()
        #expect(try await reopened.loadGoogleWorkspacePublicConfiguration() == config)
        await #expect(throws: GoogleWorkspacePublicConfigurationError.alreadyConfigured) {
            try await reopened.seedGoogleWorkspacePublicConfiguration(.init(clientID: "other.apps.googleusercontent.com"))
        }
        let after = try await reopened.query(sql: "SELECT key,value FROM app_metadata WHERE key<>? ORDER BY key;",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey)])
        #expect(try before.map { try $0.text("key") } == after.map { try $0.text("key") })
        #expect(try before.map { try $0.text("value") } == after.map { try $0.text("value") })
        #expect(try await first.loadGoogleWorkspacePublicConfiguration() == config)
    }

    @Test("Replacement swaps only the expected identity and leaves every other row alone")
    func compareAndSwap() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.open()
        let config = try GoogleWorkspacePublicConfiguration(clientID: "fixture.apps.googleusercontent.com")
        let rotated = try GoogleWorkspacePublicConfiguration(clientID: "rotated.apps.googleusercontent.com")
        // Absence is not the expected identity; replacement never inserts.
        await #expect(throws: GoogleWorkspacePublicConfigurationError.configurationChanged) {
            try await store.replaceGoogleWorkspacePublicConfiguration(config, with: rotated)
        }
        #expect(try await store.loadGoogleWorkspacePublicConfiguration() == nil)
        try await store.seedGoogleWorkspacePublicConfiguration(config)
        let before = try await store.query(sql: "SELECT key,value FROM app_metadata WHERE key<>? ORDER BY key;",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey)])
        try await store.replaceGoogleWorkspacePublicConfiguration(config, with: rotated)
        #expect(try await fixture.open().loadGoogleWorkspacePublicConfiguration() == rotated)
        // A stale expectation writes nothing.
        await #expect(throws: GoogleWorkspacePublicConfigurationError.configurationChanged) {
            try await store.replaceGoogleWorkspacePublicConfiguration(config, with: config)
        }
        #expect(try await store.loadGoogleWorkspacePublicConfiguration() == rotated)
        let after = try await store.query(sql: "SELECT key,value FROM app_metadata WHERE key<>? ORDER BY key;",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey)])
        #expect(try before.map { try $0.text("key") } == after.map { try $0.text("key") })
        #expect(try before.map { try $0.text("value") } == after.map { try $0.text("value") })
        #expect(try await store.query(sql: "SELECT count(*) AS n FROM app_metadata WHERE key=?;",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey)]).first?.integer("n") == 1)
    }

    @Test("Malformed, unsupported, empty and oversized values remain present and block seeding", arguments: [
        "", "not-json", "{}", "{\"version\":2,\"clientID\":\"fixture.apps.googleusercontent.com\"}",
        "{\"version\":1,\"clientID\":\" fixture.apps.googleusercontent.com\"}",
        "{\"version\":1,\"clientID\":\"fixture.apps.googleusercontent.com\",\"secret\":\"forbidden-field\"}",
        String(repeating: "x", count: GoogleWorkspacePublicConfiguration.maximumEncodedByteCount + 1)
    ])
    func malformed(value: String) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.open()
        _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?);",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey), .text(value)])
        await #expect(throws: GoogleWorkspacePublicConfigurationError.invalidRecord) {
            try await store.loadGoogleWorkspacePublicConfiguration()
        }
        await #expect(throws: GoogleWorkspacePublicConfigurationError.invalidRecord) {
            try await store.seedGoogleWorkspacePublicConfiguration(.init(clientID: "fixture.apps.googleusercontent.com"))
        }
        await #expect(throws: GoogleWorkspacePublicConfigurationError.invalidRecord) {
            try await store.replaceGoogleWorkspacePublicConfiguration(.init(clientID: "fixture.apps.googleusercontent.com"),
                with: .init(clientID: "rotated.apps.googleusercontent.com"))
        }
        #expect(try await store.query(sql: "SELECT value FROM app_metadata WHERE key=?;",
            bindings: [.text(GoogleWorkspacePublicConfiguration.metadataKey)]).first?.text("value") == value)
    }

    private struct Fixture {
        let root: URL
        let protection: ProtectionDecisionReceipt
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsGoogleConfiguration-\(UUID()).noindex")
            protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: .init(fileURL: root.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
        }
    }
}
