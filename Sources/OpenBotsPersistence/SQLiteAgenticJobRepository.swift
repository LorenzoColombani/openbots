import Foundation
import OpenBotsDomain

private struct StoredAgenticJobState: Codable {
    let schemaVersion: Int
    let teammateID: TeammateID
    let conversationID: ConversationID
    let state: AgenticJobState
}

extension SQLiteStore: AgenticJobRepository {
    public func createAgenticJob(request: WorkRequest) async throws -> AgenticJobRecord {
        try transaction {
            let journal = try enqueueJournalInTransaction(request, origin: .executor)
            let initial = AgenticJobState(runID: request.runID)
            try appendAgenticJobState(initial, journal: journal, revision: 1, now: request.submittedAt)
            return try requiredAgenticJob(request.runID)
        }
    }

    public func agenticJob(runID: RunID) async throws -> AgenticJobRecord? {
        try transaction { try readAgenticJob(runID) }
    }

    public func agenticJobs(conversationID: ConversationID, limit: Int) async throws -> [AgenticJobRecord] {
        try validateAgenticLimit(limit)
        return try transaction {
            try query(sql: """
                SELECT r.id,MAX(j.recorded_at) AS last_recorded FROM work_runs r
                JOIN agentic_job_states j ON j.run_id=r.id WHERE r.conversation_id=?
                GROUP BY r.id ORDER BY MAX(r.updated_at,MAX(j.recorded_at)) DESC,r.id LIMIT ?;
                """, bindings: [.text(conversationID.persistedValue), .integer(Int64(limit))])
                .map { try requiredAgenticJob(parseID(RunID.self, $0.text("id"))) }
        }
    }

    public func updateAgenticJob(runID: RunID, expectedRevision: Int64, leaseToken: UUID,
                                 state: AgenticJobState, now: Date) async throws -> AgenticJobRecord {
        try state.validate()
        guard state.runID == runID else { throw AgenticJobError.invalidState }
        return try transaction {
            let current = try requiredAgenticJob(runID)
            guard expectedRevision > 0, current.revision == expectedRevision else { throw AgenticJobError.staleRevision }
            guard expectedRevision < Int64.max else { throw AgenticJobError.revisionExhausted }
            // Metadata has its own CAS revision, but is always fenced by the
            // current logical run lease, including expiry and journal clock.
            _ = try leasedJournalCAS(runID, revision: current.journal.revision, token: leaseToken, now: now)
            guard now >= current.updatedAt else { throw RunJournalError.clockMovedBackwards }
            try state.validateTransition(from: current.state)
            if let session = state.sessionID {
                guard try query(sql: """
                    SELECT 1 AS found FROM agentic_job_states WHERE session_id=?
                    AND (run_id<>? OR conversation_generation<>?) LIMIT 1;
                    """, bindings: [.text(session.uuidString.lowercased()), .text(runID.persistedValue),
                        .integer(Int64(state.conversationGeneration))]).isEmpty else { throw AgenticJobError.staleGeneration }
            }
            try appendAgenticJobState(state, journal: current.journal, revision: expectedRevision + 1, now: now)
            return try requiredAgenticJob(runID)
        }
    }

    public func agenticJobUpdates(runID: RunID, afterRevision: Int64, limit: Int) async throws -> [AgenticJobUpdate] {
        try validateAgenticLimit(limit)
        guard afterRevision >= 0, afterRevision < Int64.max else { throw AgenticJobError.invalidLimit }
        return try transaction {
            let current = try requiredAgenticJob(runID)
            if afterRevision >= current.revision { return [] }
            var previous: AgenticJobUpdate?
            if afterRevision > 0 {
                guard let row = try query(sql: "SELECT * FROM agentic_job_states WHERE run_id=? AND revision=?;",
                    bindings: [.text(runID.persistedValue), .integer(afterRevision)]).first else { throw AgenticJobError.invalidState }
                previous = try decodeAgenticJobUpdate(row, journal: current.journal)
            }
            let rows = try query(sql: "SELECT * FROM agentic_job_states WHERE run_id=? AND revision>? ORDER BY revision LIMIT ?;",
                bindings: [.text(runID.persistedValue), .integer(afterRevision), .integer(Int64(limit))])
            var result: [AgenticJobUpdate] = []
            for row in rows {
                let update = try decodeAgenticJobUpdate(row, journal: current.journal)
                guard update.revision == (previous?.revision ?? 0) + 1 else { throw AgenticJobError.invalidState }
                if let previous { try validateAgenticHistory(update, after: previous) }
                result.append(update)
                previous = update
            }
            return result
        }
    }

    private func readAgenticJob(_ runID: RunID) throws -> AgenticJobRecord? {
        guard let row = try query(sql: "SELECT * FROM agentic_job_states WHERE run_id=? ORDER BY revision DESC LIMIT 1;",
            bindings: [.text(runID.persistedValue)]).first else { return nil }
        let journal = try requiredJournalRecord(runID)
        let latest = try decodeAgenticJobUpdate(row, journal: journal)
        guard let summary = try query(sql: "SELECT COUNT(*) AS count,MIN(revision) AS first FROM agentic_job_states WHERE run_id=?;",
            bindings: [.text(runID.persistedValue)]).first,
              try summary.integer("first") == 1, try summary.integer("count") == latest.revision else { throw AgenticJobError.invalidState }
        if latest.revision > 1 {
            guard let previous = try query(sql: "SELECT * FROM agentic_job_states WHERE run_id=? AND revision=?;",
                bindings: [.text(runID.persistedValue), .integer(latest.revision - 1)]).first else { throw AgenticJobError.invalidState }
            try validateAgenticHistory(latest, after: decodeAgenticJobUpdate(previous, journal: journal))
        }
        return AgenticJobRecord(journal: journal, revision: latest.revision, state: latest.state, updatedAt: latest.recordedAt)
    }

    private func requiredAgenticJob(_ runID: RunID) throws -> AgenticJobRecord {
        guard let record = try readAgenticJob(runID) else { throw AgenticJobError.unavailable }
        return record
    }

    private func appendAgenticJobState(_ state: AgenticJobState, journal: RunJournalRecord, revision: Int64, now: Date) throws {
        try state.validate()
        guard state.runID == journal.id, journal.origin == .executor, now.timeIntervalSince1970.isFinite,
              now >= journal.request.submittedAt else { throw AgenticJobError.invalidState }
        let envelope = StoredAgenticJobState(schemaVersion: 1, teammateID: journal.request.teammateID,
            conversationID: journal.request.conversationID, state: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= 65_536 else { throw AgenticJobError.invalidState }
        _ = try execute(sql: """
            INSERT INTO agentic_job_states(run_id,revision,conversation_generation,session_id,state_json,recorded_at)
            VALUES (?,?,?,?,?,?);
            """, bindings: [.text(state.runID.persistedValue), .integer(revision), .integer(Int64(state.conversationGeneration)),
                state.sessionID.map { .text($0.uuidString.lowercased()) } ?? .null,
                .text(String(decoding: bytes, as: UTF8.self)), .real(now.timeIntervalSince1970)])
    }

    private func decodeAgenticJobUpdate(_ row: SQLiteRow, journal: RunJournalRecord) throws -> AgenticJobUpdate {
        let text = try row.text("state_json")
        guard !text.isEmpty, text.utf8.count <= 65_536 else { throw AgenticJobError.invalidState }
        let value: StoredAgenticJobState
        do { value = try JSONDecoder().decode(StoredAgenticJobState.self, from: Data(text.utf8)) }
        catch { throw AgenticJobError.invalidState }
        try value.state.validate()
        let revision = try row.integer("revision"), timestamp = try row.real("recorded_at")
        guard value.schemaVersion == 1, journal.origin == .executor,
              value.teammateID == journal.request.teammateID, value.conversationID == journal.request.conversationID,
              value.state.runID == journal.id, try row.text("run_id") == journal.id.persistedValue,
              try row.integer("conversation_generation") == Int64(value.state.conversationGeneration),
              try row.optionalText("session_id") == value.state.sessionID?.uuidString.lowercased(),
              revision > 0, timestamp.isFinite, timestamp >= journal.request.submittedAt.timeIntervalSince1970 else {
            throw AgenticJobError.invalidState
        }
        if revision == 1 {
            guard value.state == AgenticJobState(runID: journal.id), timestamp == journal.request.submittedAt.timeIntervalSince1970 else {
                throw AgenticJobError.invalidState
            }
        }
        return AgenticJobUpdate(runID: journal.id, revision: revision, state: value.state,
            recordedAt: Date(timeIntervalSince1970: timestamp))
    }

    private func validateAgenticHistory(_ update: AgenticJobUpdate, after previous: AgenticJobUpdate) throws {
        guard previous.revision < Int64.max, update.revision == previous.revision + 1,
              update.recordedAt >= previous.recordedAt else { throw AgenticJobError.invalidState }
        try update.state.validateTransition(from: previous.state)
    }

    private func validateAgenticLimit(_ limit: Int) throws {
        guard (1...100).contains(limit) else { throw AgenticJobError.invalidLimit }
    }
}
