import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing

@Suite("Atomic connector permission metadata")
struct SQLiteConnectorAccessRepositoryTests {
    @Test("Concurrent store revisions cannot overwrite each other or unrelated app metadata")
    func compareAndSwap() async throws {
        let f = try Fixture(); defer { f.remove() }
        let first = try f.open(), second = try f.open()
        _ = try await first.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('connector_fixture_unrelated','preserved');")
        #expect(try await first.loadConnectorAccess() == ConnectorAccessState())
        let next = ConnectorAccessState(revision: 1, appEnabled: true)
        try await first.saveConnectorAccess(next, expectedRevision: 0)
        await #expect(throws: ConnectorAccessError.staleRevision) {
            try await second.saveConnectorAccess(.init(revision: 1, appEnabled: false), expectedRevision: 0)
        }
        #expect(try await second.loadConnectorAccess() == next)
        try await second.saveConnectorAccess(.init(revision: 2, appEnabled: false), expectedRevision: 1)
        #expect(try await first.loadConnectorAccess().revision == 2)
        #expect(try await first.query(sql: "SELECT value FROM app_metadata WHERE key='connector_fixture_unrelated';").first?.text("value") == "preserved")
    }

    @Test("Invalid identity bindings, duplicate grants and revision jumps are refused before any write")
    func invalidStates() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.open(), bot = TeammateID(UUID())
        let identity = try ConnectorIdentity(id: "claude-plugin:docs@fixture:docs", digest: String(repeating: "a", count: 64))
        let grant = ConnectorBotGrant(teammateID: bot, identity: identity, enabled: true)
        for state in [ConnectorAccessState(revision: 1, grants: [grant]),
                      .init(revision: 1, catalog: [identity], grants: [grant, grant]),
                      .init(revision: 1, catalog: [identity, identity]),
                      .init(revision: 2)] {
            await #expect(throws: ConnectorAccessError.invalidState) {
                try await store.saveConnectorAccess(state, expectedRevision: 0)
            }
        }
        #expect(try await store.loadConnectorAccess() == ConnectorAccessState())
    }

    @Test("Corrupt and oversized records fail closed without being replaced by defaults")
    func corruptRecords() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.open()
        for payload in ["not json", "{\"revision\":-1,\"appEnabled\":true,\"catalog\":[],\"grants\":[]}",
                        String(repeating: "x", count: ConnectorAccessState.maximumEncodedBytes + 1)] {
            _ = try await store.execute(sql: "INSERT OR REPLACE INTO app_metadata(key,value) VALUES ('connector_access_v1',?);", bindings: [.text(payload)])
            await #expect(throws: ConnectorAccessError.invalidState) { try await store.loadConnectorAccess() }
            await #expect(throws: ConnectorAccessError.invalidState) {
                try await store.saveConnectorAccess(.init(revision: 1), expectedRevision: 0)
            }
        }
    }

    private struct Fixture {
        let root: URL
        let protection: ProtectionDecisionReceipt
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextConnectorPersistence-\(UUID()).noindex")
            protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: .init(fileURL: root.appending(path: "control.sqlite"), protection: .ordinarySQLite(decision: protection)))
        }
    }
}
