import Foundation
import OpenBotsDomain

/// Persistence only. A lease fences mutations; it never starts a process or
/// proves that a provider accepted input. No token or message text enters the journal.
extension SQLiteStore: RunJournalRepository {
    public func interruptOwnedLocalFixtures(ids: [RunID], ownerID: UUID, now: Date) async throws -> [RunJournalRecord] {
        guard ids.count <= 256, Set(ids).count == ids.count else { throw RunJournalError.invalidLimit }
        try validateJournalDate(now)
        return try transaction {
            var changed: [RunJournalRecord] = []
            for id in ids {
                try Task.checkCancellation()
                guard let current = try readJournalRecord(id) else { continue }
                guard current.origin == .localFixture else { throw RunJournalError.invalidRequest }
                if journalTerminal(current.state) { continue }
                guard current.lease?.ownerID == ownerID || (current.state == .queued && current.lease == nil) else {
                    throw RunJournalError.leaseUnavailable
                }
                try validateJournalClock(now, current: current)
                try markJournalUncertain(id, now: now)
                changed.append(try updateJournal(current, state: .interrupted, lease: nil,
                    kind: .stateChanged, now: now))
            }
            return changed
        }
    }

    public func enqueueRun(_ request: WorkRequest, origin: RunOrigin) async throws -> RunJournalRecord {
        try validateJournalRequest(request)
        let frozen = try journalJSON(request, maximum: 8 * 1_024 * 1_024)
        return try transaction {
            try validateJournalContext(request)
            guard try query(sql: "SELECT 1 AS found FROM work_runs WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted') LIMIT 1;",
                            bindings: [.text(request.teammateID.persistedValue)]).isEmpty else {
                throw RunJournalError.conflictingActiveRun
            }
            guard try query(sql: "SELECT 1 AS found FROM work_runs WHERE id=?;", bindings: [.text(request.runID.persistedValue)]).isEmpty else {
                throw RunJournalError.invalidRequest
            }
            try validateJournalInput(request.initialInput, conversationID: request.conversationID, submittedAt: request.submittedAt)
            _ = try execute(sql: """
                INSERT INTO work_runs(id,teammate_id,conversation_id,initiating_message_id,selected_project_id,
                    profile_revision,state,created_at,updated_at) VALUES (?,?,?,?,?,?,'queued',?,?);
                """, bindings: [.text(request.runID.persistedValue), .text(request.teammateID.persistedValue),
                    .text(request.conversationID.persistedValue), .text(request.initiatingMessageID.persistedValue),
                    request.selectedProjectID.map { .text($0.persistedValue) } ?? .null,
                    .integer(Int64(request.profileRevision)), .real(request.submittedAt.timeIntervalSince1970),
                    .real(request.submittedAt.timeIntervalSince1970)])
            _ = try execute(sql: "INSERT INTO run_journal_metadata(run_id,request_json,origin,revision) VALUES (?,?,?,1);",
                bindings: [.text(request.runID.persistedValue), .text(frozen), .text(origin.rawValue)])
            try insertJournalInput(request.initialInput, runID: request.runID, submittedAt: request.submittedAt, now: request.submittedAt)
            try insertJournalEntry(id: request.runID, revision: 1, kind: .enqueued, state: .queued,
                                   messageID: request.initiatingMessageID, now: request.submittedAt)
            return try requiredJournalRecord(request.runID)
        }
    }

    public func run(id: RunID) async throws -> RunJournalRecord? {
        try transaction { try readJournalRecord(id) }
    }

    public func failUnclaimedLocalFixture(id: RunID, expectedRevision: Int64, now: Date) async throws -> RunJournalRecord {
        try transaction {
            let current = try journalCAS(id, revision: expectedRevision, now: now)
            guard current.origin == .localFixture, current.state == .queued, current.lease == nil else {
                throw RunJournalError.invalidTransition
            }
            return try updateJournal(current, state: .failed, lease: nil, kind: .stateChanged, now: now)
        }
    }

    public func runs(conversationID: ConversationID, limit: Int) async throws -> [RunJournalRecord] {
        try validateJournalLimit(limit)
        return try transaction {
            try query(sql: "SELECT id FROM work_runs WHERE conversation_id=? ORDER BY updated_at DESC,id LIMIT ?;",
                      bindings: [.text(conversationID.persistedValue), .integer(Int64(limit))])
                .map { try requiredJournalRecord(parseID(RunID.self, $0.text("id"))) }
        }
    }

    public func claimRun(id: RunID, expectedRevision: Int64, ownerID: UUID, token: UUID,
                         now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord {
        let expiry = try journalExpiry(now: now, duration: leaseDuration)
        return try transaction {
            let current = try journalCAS(id, revision: expectedRevision, now: now)
            guard current.state == .queued, current.lease == nil else { throw RunJournalError.leaseUnavailable }
            try validateJournalContext(current.request)
            let generation = try journalGeneration(id)
            guard generation < Int64.max else { throw RunJournalError.revisionExhausted }
            let lease = RunLease(ownerID: ownerID, token: token, generation: generation + 1, expiresAt: expiry)
            return try updateJournal(current, state: .starting, lease: lease, kind: .claimed, now: now)
        }
    }

    public func renewRunLease(id: RunID, expectedRevision: Int64, token: UUID,
                              now: Date, leaseDuration: TimeInterval) async throws -> RunJournalRecord {
        let expiry = try journalExpiry(now: now, duration: leaseDuration)
        return try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            let lease = try requireJournalLease(current, token: token, now: now)
            // Renewal never shortens a valid lease when a caller uses a shorter TTL.
            let renewed = RunLease(ownerID: lease.ownerID, token: lease.token, generation: lease.generation,
                                   expiresAt: max(lease.expiresAt, expiry))
            return try updateJournal(current, state: current.state, lease: renewed, kind: .leaseRenewed, now: now)
        }
    }

    public func transitionRun(id: RunID, expectedRevision: Int64, token: UUID,
                              event: WorkRunEvent, now: Date) async throws -> RunJournalRecord {
        try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            let state: WorkRunState
            do { state = try current.state.applying(event) }
            catch { throw RunJournalError.invalidTransition }
            if state == .failed || state == .interrupted { try markJournalUncertain(id, now: now) }
            return try updateJournal(current, state: state, lease: journalTerminal(state) ? nil : current.lease,
                                     kind: .stateChanged, now: now)
        }
    }

    public func queueRunInput(id: RunID, expectedRevision: Int64, token: UUID,
                              input: SteeringInput, now: Date) async throws -> RunJournalRecord {
        let workInput = try WorkInput(messageID: input.messageID, sequence: input.sequence,
                                     text: input.text, attachmentIDs: input.attachmentIDs)
        try validateJournalInputShape(workInput)
        try validateJournalDate(input.submittedAt)
        return try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            guard current.state == .running || current.state == .waitingForUser else { throw RunJournalError.invalidTransition }
            try validateJournalContext(current.request)
            guard input.submittedAt >= current.request.submittedAt, input.submittedAt <= now else { throw RunJournalError.invalidRequest }
            let maximum = try query(sql: "SELECT MAX(sequence) AS maximum FROM run_input_receipts WHERE run_id=?;",
                                    bindings: [.text(id.persistedValue)]).first?.optionalInteger("maximum") ?? 0
            guard maximum < Int64.max else { throw RunJournalError.revisionExhausted }
            guard input.sequence == maximum + 1 else { throw RunJournalError.inputMismatch }
            try validateJournalInput(workInput, conversationID: current.request.conversationID, submittedAt: input.submittedAt)
            try requireUnusedJournalMessage(input.messageID, runID: id)
            try insertJournalInput(workInput, runID: id, submittedAt: input.submittedAt, now: now)
            return try updateJournal(current, state: current.state, lease: current.lease,
                                     kind: .inputQueued, messageID: input.messageID, now: now)
        }
    }

    public func markRunInput(id: RunID, expectedRevision: Int64, token: UUID,
                             messageID: MessageID, sequence: Int64, state: RunInputState,
                             now: Date) async throws -> RunJournalRecord {
        try transaction {
            let current = try leasedJournalCAS(id, revision: expectedRevision, token: token, now: now)
            guard sequence > 0, let row = try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? AND message_id=? AND sequence=?;",
                bindings: [.text(id.persistedValue), .text(messageID.persistedValue), .integer(sequence)]).first else {
                throw RunJournalError.inputUnavailable
            }
            let existing = try decodeJournalInput(row, request: current.request)
            guard (existing.state == .queued && state == .submitted)
                    || (existing.state == .submitted && state == .acknowledged) else {
                throw RunJournalError.invalidInputTransition
            }
            if state == .submitted {
                guard current.state == .running || current.state == .waitingForUser else {
                    throw RunJournalError.invalidTransition
                }
            }
            _ = try execute(sql: "UPDATE run_input_receipts SET state=?,updated_at=? WHERE run_id=? AND message_id=? AND sequence=?;",
                bindings: [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(id.persistedValue),
                           .text(messageID.persistedValue), .integer(sequence)])
            return try updateJournal(current, state: current.state, lease: current.lease,
                kind: state == .submitted ? .inputSubmitted : .inputAcknowledged, messageID: messageID, now: now)
        }
    }

    public func runInputs(id: RunID, limit: Int) async throws -> [RunInputReceipt] {
        try validateJournalLimit(limit)
        return try transaction {
            let current = try requiredJournalRecord(id)
            let inputs = try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? ORDER BY sequence LIMIT ?;",
                                   bindings: [.text(id.persistedValue), .integer(Int64(limit))])
                .map { try decodeJournalInput($0, request: current.request) }
            guard !inputs.isEmpty, inputs.enumerated().allSatisfy({ $0.element.sequence == Int64($0.offset) + 1 }) else {
                throw RunJournalError.invalidRequest
            }
            return inputs
        }
    }

    public func runEntries(id: RunID, afterSequence: Int64, limit: Int) async throws -> [RunJournalEntry] {
        try validateJournalLimit(limit)
        guard afterSequence >= 0, afterSequence < Int64.max else { throw RunJournalError.invalidLimit }
        return try transaction {
            let current = try requiredJournalRecord(id)
            let entries = try query(sql: "SELECT * FROM run_journal_entries WHERE run_id=? AND sequence>? ORDER BY sequence LIMIT ?;",
                bindings: [.text(id.persistedValue), .integer(afterSequence), .integer(Int64(limit))])
                .map { try decodeJournalEntry($0, request: current.request) }
            for (index, entry) in entries.enumerated() {
                guard afterSequence <= Int64.max - Int64(index) - 1,
                      entry.sequence == afterSequence + Int64(index) + 1,
                      entry.sequence <= current.revision else { throw RunJournalError.invalidRequest }
            }
            return entries
        }
    }

    public func recoverExpiredLocalFixtures(conversationID: ConversationID, now: Date,
                                             limit: Int) async throws -> [RunJournalRecord] {
        try validateJournalLimit(limit)
        try validateJournalDate(now)
        return try transaction {
            let rows = try query(sql: """
                SELECT r.id FROM work_runs r JOIN run_journal_metadata m ON m.run_id=r.id
                WHERE r.conversation_id=? AND m.origin='localFixture'
                  AND r.state IN ('starting','running','waitingForUser','stopping') AND m.lease_expires_at<=?
                ORDER BY m.lease_expires_at,r.id LIMIT ?;
                """, bindings: [.text(conversationID.persistedValue), .real(now.timeIntervalSince1970), .integer(Int64(limit))])
            return try rows.map { row in
                let current = try requiredJournalRecord(parseID(RunID.self, row.text("id")))
                guard current.origin == .localFixture, let lease = current.lease, lease.expiresAt <= now else {
                    throw RunJournalError.leaseUnavailable
                }
                try validateJournalClock(now, current: current)
                try markJournalUncertain(current.id, now: now)
                return try updateJournal(current, state: .interrupted, lease: nil, kind: .recovered, now: now)
            }
        }
    }

    func validateJournalRequest(_ request: WorkRequest) throws {
        guard request.profileRevision > 0, request.profileRevision <= UInt64(Int64.max),
              request.initiatingMessageID == request.initialInput.messageID, request.initialInput.sequence == 1 else {
            throw RunJournalError.invalidRequest
        }
        try validateJournalDate(request.submittedAt)
        try validateJournalInputShape(request.initialInput)
    }

    private func validateJournalInputShape(_ input: WorkInput) throws {
        guard input.sequence > 0, input.text.utf8.count <= 1_024 * 1_024,
              !input.text.isEmpty || !input.attachmentIDs.isEmpty,
              input.attachmentIDs.count <= AttachmentDraftSnapshot.maximumAttachments,
              Set(input.attachmentIDs).count == input.attachmentIDs.count else { throw RunJournalError.inputMismatch }
    }

    func validateJournalContext(_ request: WorkRequest) throws {
        guard let owner = try query(sql: """
            SELECT t.profile_revision FROM conversations c JOIN teammates t ON t.id=c.subject_id
            WHERE c.id=? AND c.kind='direct' AND c.subject_id=? AND c.lifecycle='active'
              AND t.lifecycle='active' AND t.is_hidden=0
              AND EXISTS(SELECT 1 FROM conversation_participants p
                         WHERE p.conversation_id=c.id AND p.teammate_id=t.id AND p.left_at IS NULL);
            """, bindings: [.text(request.conversationID.persistedValue), .text(request.teammateID.persistedValue)]).first,
              try owner.integer("profile_revision") == Int64(request.profileRevision) else { throw RunJournalError.invalidRequest }
        let context = try query(sql: "SELECT teammate_id,project_id,team_id,revision FROM conversation_context_selections WHERE conversation_id=?;",
                                bindings: [.text(request.conversationID.persistedValue)]).first
        if let context {
            guard try context.text("teammate_id") == request.teammateID.persistedValue,
                  try context.integer("revision") > 0 else { throw RunJournalError.invalidRequest }
            if let team = try context.optionalText("team_id") {
                guard try !query(sql: "SELECT 1 AS allowed FROM teams t JOIN team_memberships m ON m.team_id=t.id WHERE t.id=? AND t.lifecycle='active' AND m.teammate_id=? AND m.revoked_at IS NULL LIMIT 1;",
                                 bindings: [.text(team), .text(request.teammateID.persistedValue)]).isEmpty else { throw RunJournalError.invalidRequest }
            }
        }
        guard try context?.optionalText("project_id") == request.selectedProjectID?.persistedValue else { throw RunJournalError.invalidRequest }
        if let project = request.selectedProjectID {
            guard try !query(sql: "SELECT 1 AS allowed FROM projects p JOIN project_memberships m ON m.project_id=p.id WHERE p.id=? AND p.lifecycle='active' AND m.teammate_id=? AND m.revoked_at IS NULL LIMIT 1;",
                             bindings: [.text(project.persistedValue), .text(request.teammateID.persistedValue)]).isEmpty else { throw RunJournalError.invalidRequest }
        }
    }

    func validateJournalInput(_ input: WorkInput, conversationID: ConversationID, submittedAt: Date) throws {
        try validateJournalInputShape(input)
        guard let message = try query(sql: "SELECT conversation_id,author_kind,output_class,created_at FROM messages WHERE id=?;",
                                      bindings: [.text(input.messageID.persistedValue)]).first,
              try message.text("conversation_id") == conversationID.persistedValue,
              try message.text("author_kind") == "user", try message.text("output_class") == "conversation" else {
            throw RunJournalError.inputMismatch
        }
        let created = try message.real("created_at")
        guard created.isFinite, created <= submittedAt.timeIntervalSince1970 else { throw RunJournalError.inputMismatch }
        let rows = try query(sql: "SELECT ordinal,kind,text_value,referenced_id FROM message_parts WHERE message_id=? ORDER BY ordinal LIMIT 101;",
                             bindings: [.text(input.messageID.persistedValue)])
        guard !rows.isEmpty, rows.count <= 100 else { throw RunJournalError.inputMismatch }
        var text = ""
        var attachments: [AttachmentID] = []
        for row in rows {
            guard try row.integer("ordinal") >= 0 else { throw RunJournalError.inputMismatch }
            switch try row.text("kind") {
            case "text":
                let part = try row.text("text_value")
                guard !part.isEmpty, part.utf8.count <= 1_024 * 1_024 - text.utf8.count else { throw RunJournalError.inputMismatch }
                text += part
            case "attachment":
                let id = try parseID(AttachmentID.self, row.text("referenced_id"))
                guard try !query(sql: "SELECT 1 AS found FROM attachment_assets WHERE id=? AND conversation_id=?;",
                                 bindings: [.text(id.persistedValue), .text(conversationID.persistedValue)]).isEmpty else { throw RunJournalError.inputMismatch }
                attachments.append(id)
            default: throw RunJournalError.inputMismatch
            }
        }
        guard text.utf8.elementsEqual(input.text.utf8), attachments == input.attachmentIDs else { throw RunJournalError.inputMismatch }
    }

    private func requireUnusedJournalMessage(_ messageID: MessageID, runID: RunID) throws {
        guard try query(sql: "SELECT 1 AS found FROM run_input_receipts WHERE run_id=? AND message_id=?;",
                        bindings: [.text(runID.persistedValue), .text(messageID.persistedValue)]).isEmpty else { throw RunJournalError.inputMismatch }
    }

    func insertJournalInput(_ input: WorkInput, runID: RunID, submittedAt: Date, now: Date) throws {
        _ = try execute(sql: "INSERT INTO run_input_receipts(run_id,message_id,sequence,state,input_text,attachment_ids_json,submitted_at,updated_at) VALUES (?,?,?,'queued',?,?,?,?);",
            bindings: [.text(runID.persistedValue), .text(input.messageID.persistedValue), .integer(input.sequence),
                .text(input.text), .text(try journalJSON(input.attachmentIDs, maximum: 2_048)),
                .real(submittedAt.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
    }

    func journalCAS(_ id: RunID, revision: Int64, now: Date) throws -> RunJournalRecord {
        let record = try requiredJournalRecord(id)
        guard revision > 0, record.revision == revision else { throw RunJournalError.staleRevision }
        guard revision < Int64.max else { throw RunJournalError.revisionExhausted }
        try validateJournalClock(now, current: record)
        return record
    }

    func leasedJournalCAS(_ id: RunID, revision: Int64, token: UUID, now: Date) throws -> RunJournalRecord {
        let record = try journalCAS(id, revision: revision, now: now)
        _ = try requireJournalLease(record, token: token, now: now)
        return record
    }

    private func requireJournalLease(_ record: RunJournalRecord, token: UUID, now: Date) throws -> RunLease {
        guard !journalTerminal(record.state), let lease = record.lease, lease.token == token else { throw RunJournalError.leaseUnavailable }
        guard lease.expiresAt > now else { throw RunJournalError.leaseExpired }
        return lease
    }

    func updateJournal(_ current: RunJournalRecord, state: WorkRunState, lease: RunLease?,
                               kind: RunJournalEntryKind, messageID: MessageID? = nil, now: Date) throws -> RunJournalRecord {
        guard current.revision > 0, current.revision < Int64.max else { throw RunJournalError.revisionExhausted }
        let next = current.revision + 1
        let changed = try execute(sql: """
            UPDATE run_journal_metadata SET revision=?,lease_owner_id=?,lease_token=?,lease_expires_at=?,
                lease_generation=COALESCE(?,lease_generation) WHERE run_id=? AND revision=?;
            """, bindings: [.integer(next), lease.map { .text($0.ownerID.uuidString.lowercased()) } ?? .null,
                lease.map { .text($0.token.uuidString.lowercased()) } ?? .null,
                lease.map { .real($0.expiresAt.timeIntervalSince1970) } ?? .null,
                lease.map { .integer($0.generation) } ?? .null, .text(current.id.persistedValue), .integer(current.revision)])
        guard changed == 1 else { throw RunJournalError.staleRevision }
        _ = try execute(sql: "UPDATE work_runs SET state=?,updated_at=? WHERE id=?;",
            bindings: [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(current.id.persistedValue)])
        try insertJournalEntry(id: current.id, revision: next, kind: kind, state: state, messageID: messageID, now: now)
        return try requiredJournalRecord(current.id)
    }

    func insertJournalEntry(id: RunID, revision: Int64, kind: RunJournalEntryKind,
                                    state: WorkRunState, messageID: MessageID?, now: Date) throws {
        _ = try execute(sql: "INSERT INTO run_journal_entries(run_id,sequence,kind,state,input_message_id,recorded_at) VALUES (?,?,?,?,?,?);",
            bindings: [.text(id.persistedValue), .integer(revision), .text(kind.rawValue), .text(state.rawValue),
                       messageID.map { .text($0.persistedValue) } ?? .null, .real(now.timeIntervalSince1970)])
    }

    private func markJournalUncertain(_ id: RunID, now: Date) throws {
        _ = try execute(sql: "UPDATE run_input_receipts SET state='outcomeUnknown',updated_at=? WHERE run_id=? AND state='submitted';",
                        bindings: [.real(now.timeIntervalSince1970), .text(id.persistedValue)])
    }

    func requiredJournalRecord(_ id: RunID) throws -> RunJournalRecord {
        guard let record = try readJournalRecord(id) else { throw RunJournalError.unavailable }
        return record
    }

    private func readJournalRecord(_ id: RunID) throws -> RunJournalRecord? {
        guard let row = try query(sql: "SELECT r.*,m.request_json,m.origin,m.revision,m.lease_generation,m.lease_owner_id,m.lease_token,m.lease_expires_at FROM work_runs r LEFT JOIN run_journal_metadata m ON m.run_id=r.id WHERE r.id=?;",
                                   bindings: [.text(id.persistedValue)]).first else { return nil }
        // Old raw work_runs carry no explicit origin; never silently adopt them as fixtures.
        guard let json = try row.optionalText("request_json") else { throw RunJournalError.unavailable }
        let request: WorkRequest = try decodeJournalJSON(json, maximum: 8 * 1_024 * 1_024)
        try validateJournalRequest(request)
        let revision = try row.integer("revision")
        let generation = try row.integer("lease_generation")
        let updated = try row.real("updated_at")
        guard request.runID == id, try row.text("teammate_id") == request.teammateID.persistedValue,
              try row.text("conversation_id") == request.conversationID.persistedValue,
              try row.text("initiating_message_id") == request.initiatingMessageID.persistedValue,
              try row.optionalText("selected_project_id") == request.selectedProjectID?.persistedValue,
              try row.integer("profile_revision") == Int64(request.profileRevision),
              try row.real("created_at") == request.submittedAt.timeIntervalSince1970,
              revision > 0, generation >= 0, updated.isFinite, updated >= request.submittedAt.timeIntervalSince1970,
              let state = WorkRunState(rawValue: try row.text("state")),
              let origin = RunOrigin(rawValue: try row.text("origin")) else { throw RunJournalError.invalidRequest }
        let owner = try row.optionalText("lease_owner_id")
        let token = try row.optionalText("lease_token")
        let expiry = try row.optionalReal("lease_expires_at")
        let lease: RunLease?
        if owner == nil, token == nil, expiry == nil {
            guard state == .queued || journalTerminal(state), state != .queued || generation == 0 else { throw RunJournalError.invalidRequest }
            lease = nil
        } else {
            guard let owner, let ownerID = UUID(uuidString: owner), let token, let tokenID = UUID(uuidString: token),
                  let expiry, expiry.isFinite, expiry > updated, generation > 0,
                  state != .queued, !journalTerminal(state) else { throw RunJournalError.invalidRequest }
            lease = RunLease(ownerID: ownerID, token: tokenID, generation: generation, expiresAt: Date(timeIntervalSince1970: expiry))
        }
        guard let initial = try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? AND sequence=1;", bindings: [.text(id.persistedValue)]).first else {
            throw RunJournalError.invalidRequest
        }
        _ = try decodeJournalInput(initial, request: request)
        guard let last = try query(sql: "SELECT * FROM run_journal_entries WHERE run_id=? ORDER BY sequence DESC LIMIT 1;", bindings: [.text(id.persistedValue)]).first else {
            throw RunJournalError.invalidRequest
        }
        let entry = try decodeJournalEntry(last, request: request)
        guard entry.sequence == revision, entry.state == state, entry.recordedAt.timeIntervalSince1970 == updated else { throw RunJournalError.invalidRequest }
        return RunJournalRecord(request: request, origin: origin, state: state, revision: revision, lease: lease,
                                updatedAt: Date(timeIntervalSince1970: updated))
    }

    func decodeJournalInput(_ row: SQLiteRow, request: WorkRequest) throws -> RunInputReceipt {
        let sequence = try row.integer("sequence")
        let messageID = try parseID(MessageID.self, row.text("message_id"))
        let text = try row.text("input_text")
        let ids: [AttachmentID] = try decodeJournalJSON(row.text("attachment_ids_json"), maximum: 2_048)
        let input = try WorkInput(messageID: messageID, sequence: sequence, text: text, attachmentIDs: ids)
        try validateJournalInputShape(input)
        let submitted = try row.real("submitted_at")
        let updated = try row.real("updated_at")
        guard try row.text("run_id") == request.runID.persistedValue, submitted.isFinite, updated.isFinite,
              submitted >= request.submittedAt.timeIntervalSince1970, updated >= submitted,
              let state = RunInputState(rawValue: try row.text("state")) else { throw RunJournalError.invalidRequest }
        if sequence == 1 {
            guard messageID == request.initiatingMessageID, text.utf8.elementsEqual(request.initialInput.text.utf8),
                  ids == request.initialInput.attachmentIDs, submitted == request.submittedAt.timeIntervalSince1970 else { throw RunJournalError.invalidRequest }
        }
        try validateJournalInput(input, conversationID: request.conversationID, submittedAt: Date(timeIntervalSince1970: submitted))
        return RunInputReceipt(runID: request.runID, messageID: messageID, sequence: sequence, state: state,
                               updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func decodeJournalEntry(_ row: SQLiteRow, request: WorkRequest) throws -> RunJournalEntry {
        let sequence = try row.integer("sequence")
        let time = try row.real("recorded_at")
        guard try row.text("run_id") == request.runID.persistedValue, sequence > 0,
              time.isFinite, time >= request.submittedAt.timeIntervalSince1970,
              let kind = RunJournalEntryKind(rawValue: try row.text("kind")),
              let state = WorkRunState(rawValue: try row.text("state")) else { throw RunJournalError.invalidRequest }
        let message = try row.optionalText("input_message_id").map { try parseID(MessageID.self, $0) }
        if [.enqueued, .inputQueued, .inputSubmitted, .inputAcknowledged].contains(kind) {
            guard let message, try !query(sql: "SELECT 1 AS found FROM run_input_receipts WHERE run_id=? AND message_id=?;",
                                          bindings: [.text(request.runID.persistedValue), .text(message.persistedValue)]).isEmpty else { throw RunJournalError.invalidRequest }
        } else if message != nil { throw RunJournalError.invalidRequest }
        if sequence == 1 {
            guard kind == .enqueued, state == .queued, message == request.initiatingMessageID else { throw RunJournalError.invalidRequest }
        }
        return RunJournalEntry(runID: request.runID, sequence: sequence, kind: kind, state: state,
                                inputMessageID: message, recordedAt: Date(timeIntervalSince1970: time))
    }

    private func journalGeneration(_ id: RunID) throws -> Int64 {
        guard let row = try query(sql: "SELECT lease_generation FROM run_journal_metadata WHERE run_id=?;", bindings: [.text(id.persistedValue)]).first else { throw RunJournalError.unavailable }
        return try row.integer("lease_generation")
    }

    func journalExpiry(now: Date, duration: TimeInterval) throws -> Date {
        try validateJournalDate(now)
        guard duration.isFinite, (1...300).contains(duration) else { throw RunJournalError.invalidLeaseDuration }
        let expiry = now.addingTimeInterval(duration)
        guard expiry.timeIntervalSince1970.isFinite, expiry > now else { throw RunJournalError.invalidLeaseDuration }
        return expiry
    }

    private func validateJournalClock(_ now: Date, current: RunJournalRecord) throws {
        try validateJournalDate(now)
        guard now >= current.updatedAt else { throw RunJournalError.clockMovedBackwards }
    }

    private func validateJournalDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw RunJournalError.invalidRequest }
    }

    private func validateJournalLimit(_ limit: Int) throws {
        guard (1...100).contains(limit) else { throw RunJournalError.invalidLimit }
    }

    func journalTerminal(_ state: WorkRunState) -> Bool { [.succeeded, .failed, .interrupted].contains(state) }

    func journalJSON<T: Encodable>(_ value: T, maximum: Int) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximum, let string = String(data: data, encoding: .utf8) else { throw RunJournalError.invalidRequest }
        return string
    }

    private func decodeJournalJSON<T: Decodable>(_ text: String, maximum: Int) throws -> T {
        guard text.utf8.count <= maximum else { throw RunJournalError.invalidRequest }
        do { return try JSONDecoder().decode(T.self, from: Data(text.utf8)) }
        catch { throw RunJournalError.invalidRequest }
    }
}
