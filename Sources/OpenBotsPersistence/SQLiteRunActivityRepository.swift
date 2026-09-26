import Foundation
import OpenBotsDomain

extension SQLiteStore: RunActivityRepository {
    public func recordRunActivity(runID: RunID, line: String, at date: Date) async throws {
        let trimmed = String(line.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try transaction {
            let count = try query(sql: "SELECT COUNT(*) AS total, COALESCE(MAX(sequence),0) AS last FROM run_activity WHERE run_id=?;",
                                  bindings: [.text(runID.persistedValue)]).first
            let total = try count?.integer("total") ?? 0
            guard total < Int64(maximumRunActivityLines) else { return }
            let last = try count?.integer("last") ?? 0
            _ = try execute(sql: "INSERT INTO run_activity(run_id,sequence,recorded_at,line) VALUES (?,?,?,?);",
                bindings: [.text(runID.persistedValue), .integer(last + 1), .real(date.timeIntervalSince1970), .text(trimmed)])
        }
    }

    public func runActivity(runID: RunID) async throws -> [RunActivityLine] {
        try query(sql: """
            SELECT a.run_id, r.teammate_id, a.sequence, a.recorded_at, a.line
            FROM run_activity a JOIN work_runs r ON r.id=a.run_id
            WHERE a.run_id=? ORDER BY a.sequence LIMIT ?;
            """, bindings: [.text(runID.persistedValue), .integer(Int64(maximumRunActivityLines))]).map { row in
            RunActivityLine(runID: try parseID(RunID.self, row.text("run_id")),
                teammateID: try parseID(TeammateID.self, row.text("teammate_id")),
                sequence: try row.integer("sequence"),
                recordedAt: Date(timeIntervalSince1970: try row.real("recorded_at")),
                line: try row.text("line"))
        }
    }

    public func runActivity(conversationID: ConversationID, limit: Int) async throws -> [RunActivityLine] {
        guard (1...5_000).contains(limit) else { return [] }
        return try query(sql: """
            SELECT a.run_id, r.teammate_id, a.sequence, a.recorded_at, a.line
            FROM run_activity a JOIN work_runs r ON r.id=a.run_id
            WHERE r.conversation_id=? ORDER BY a.recorded_at, a.sequence LIMIT ?;
            """, bindings: [.text(conversationID.persistedValue), .integer(Int64(limit))]).map { row in
            RunActivityLine(runID: try parseID(RunID.self, row.text("run_id")),
                teammateID: try parseID(TeammateID.self, row.text("teammate_id")),
                sequence: try row.integer("sequence"),
                recordedAt: Date(timeIntervalSince1970: try row.real("recorded_at")),
                line: try row.text("line"))
        }
    }
}
