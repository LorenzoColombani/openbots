import Foundation
import OpenBotsDomain

private let localSessionMetadataKey = "preview_local_session_v1"

extension SQLiteStore: LocalSessionRecoveryRepository {
    public func beginLocalSession(id: UUID, at: Date) async throws -> LocalSessionRecoveryRecord? {
        let next = try LocalSessionRecoveryRecord(id: id, startedAt: at, status: .open)
        let json = String(decoding: try next.encodedData(), as: UTF8.self)
        return try transaction {
            let prior = try localSessionMetadata()
            guard prior?.record.id != id else { throw LocalSessionRecoveryError.staleSession }
            let changed = try execute(sql: """
                INSERT INTO app_metadata(key,value) VALUES (?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value;
                """, bindings: [.text(localSessionMetadataKey), .text(json)])
            guard changed == 1 else { throw LocalSessionRecoveryError.staleSession }
            return prior?.record
        }
    }

    public func finishLocalSession(id: UUID, outcome: LocalSessionSaveOutcome, at: Date) async throws {
        guard outcome != .open else { throw LocalSessionRecoveryError.invalidTransition }
        try transaction {
            guard let current = try localSessionMetadata(), current.record.id == id, current.record.status == .open else {
                throw LocalSessionRecoveryError.staleSession
            }
            let finished = try LocalSessionRecoveryRecord(id: id, startedAt: current.record.startedAt, endedAt: at, status: outcome)
            let json = String(decoding: try finished.encodedData(), as: UTF8.self)
            let changed = try execute(sql: "UPDATE app_metadata SET value=? WHERE key=? AND value=?;",
                                      bindings: [.text(json), .text(localSessionMetadataKey), .text(current.json)])
            guard changed == 1 else { throw LocalSessionRecoveryError.staleSession }
        }
    }

    private func localSessionMetadata() throws -> (record: LocalSessionRecoveryRecord, json: String)? {
        // Length is checked inside SQLite before materializing an unexpectedly
        // large value. No other app_metadata key can enter this fixed policy.
        guard let row = try query(sql: """
            SELECT length(CAST(value AS BLOB)) AS byte_count,
                   CASE WHEN length(CAST(value AS BLOB))<=? THEN value ELSE NULL END AS bounded_value
            FROM app_metadata WHERE key=?;
            """, bindings: [.integer(Int64(LocalSessionRecoveryRecord.maximumEncodedByteCount)), .text(localSessionMetadataKey)]).first else {
            return nil
        }
        let count = try row.integer("byte_count")
        guard count > 0, count <= Int64(LocalSessionRecoveryRecord.maximumEncodedByteCount),
              let json = try row.optionalText("bounded_value") else { throw LocalSessionRecoveryError.invalidRecord }
        return (try LocalSessionRecoveryRecord.decode(Data(json.utf8)), json)
    }
}
