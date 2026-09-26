import Foundation
import OpenBotsDomain

private let connectorAccessKey = "connector_access_v1"

extension SQLiteStore: ConnectorAccessRepository {
    public func loadConnectorAccess() async throws -> ConnectorAccessState {
        try transaction { try readConnectorAccess() }
    }

    public func saveConnectorAccess(_ state: ConnectorAccessState, expectedRevision: Int64) async throws {
        try state.validate()
        guard expectedRevision >= 0, expectedRevision < Int64.max,
              state.revision == expectedRevision + 1 else { throw ConnectorAccessError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= ConnectorAccessState.maximumEncodedBytes else { throw ConnectorAccessError.invalidState }
        try transaction {
            guard try readConnectorAccess().revision == expectedRevision else { throw ConnectorAccessError.staleRevision }
            _ = try execute(sql: """
                INSERT INTO app_metadata(key,value) VALUES (?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """, bindings: [.text(connectorAccessKey), .text(String(decoding: data, as: UTF8.self))])
        }
    }

    private func readConnectorAccess() throws -> ConnectorAccessState {
        guard let row = try query(sql: """
            SELECT length(CAST(value AS BLOB)) AS byte_count,
                   CASE WHEN length(CAST(value AS BLOB))<=? THEN value ELSE NULL END AS bounded_value
            FROM app_metadata WHERE key=?;
            """, bindings: [.integer(Int64(ConnectorAccessState.maximumEncodedBytes)), .text(connectorAccessKey)]).first else {
            return ConnectorAccessState()
        }
        let count = try row.integer("byte_count")
        guard count > 0, count <= ConnectorAccessState.maximumEncodedBytes,
              let json = try row.optionalText("bounded_value") else { throw ConnectorAccessError.invalidState }
        let state: ConnectorAccessState
        do { state = try JSONDecoder().decode(ConnectorAccessState.self, from: Data(json.utf8)) }
        catch { throw ConnectorAccessError.invalidState }
        try state.validate()
        return state
    }
}
