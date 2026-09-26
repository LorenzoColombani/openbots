import CryptoKit
import Foundation
import OpenBotsDomain

extension SQLiteStore: ReadContextRepository {
    public func loadReadContextCandidates(_ request: ReadContextRequest) async throws -> ReadContextSnapshot {
        try transaction {
            let authority = try readContextAuthority(conversationID: request.conversationID,
                teammateID: request.teammateID, profileRevision: request.profileRevision, selection: request.selection)
            // The window is the most recent rows whose authorship admission below
            // could accept: the user's messages, and this bot's (or a system) reply
            // that directly follows one. Another member's reply and a handoff brief
            // never pass admission, so in a team room they would otherwise burn the
            // twelve slots and push the user's request out of the bot's sight within
            // a few delegation rounds. A row of the right authorship that admission
            // still rejects (a failed turn, a local fixture) keeps occupying its
            // slot. The subquery caps how many stored rows are looked at.
            let recentRows = try query(sql: """
                SELECT m.id,m.sequence FROM (
                    SELECT id,sequence,author_kind,author_teammate_id FROM messages
                    WHERE conversation_id=? AND sequence<? ORDER BY sequence DESC LIMIT ?
                ) AS m
                WHERE ((m.author_kind='user' AND m.author_teammate_id IS NULL)
                       OR ((m.author_kind='system' OR (m.author_kind='teammate' AND m.author_teammate_id=?))
                           AND EXISTS(SELECT 1 FROM messages u WHERE u.conversation_id=? AND u.sequence=m.sequence-1
                                      AND u.author_kind='user' AND u.author_teammate_id IS NULL)))
                ORDER BY m.sequence DESC LIMIT ?;
                """, bindings: [.text(request.conversationID.persistedValue), .integer(request.beforeSequence),
                    .integer(Int64(ReadContextLimits.recentCandidateScan)),
                    .text(request.teammateID.persistedValue), .text(request.conversationID.persistedValue),
                    .integer(Int64(ReadContextLimits.recentMessages + 1))])
            // What the scan could not look at. The window above stops at a fixed
            // number of stored rows, so a room whose whole look-back is briefs
            // and other members' replies yields an empty window with nothing
            // recorded as excluded. Saying nothing was omitted there would have
            // the assembler vouch for a context that never reached the user's
            // request; one bounded count says the room runs deeper than the scan.
            let scanned = try query(sql: """
                SELECT COUNT(*) AS scanned FROM (
                    SELECT id FROM messages WHERE conversation_id=? AND sequence<?
                    ORDER BY sequence DESC LIMIT ?
                );
                """, bindings: [.text(request.conversationID.persistedValue), .integer(request.beforeSequence),
                    .integer(Int64(ReadContextLimits.recentCandidateScan + 1))])
            let lookBackWasFull = try (scanned.first?.integer("scanned") ?? 0) > Int64(ReadContextLimits.recentCandidateScan)
            var excludedMessages = 0
            var history = ReadContextHistoryValidation()
            var recent: [ReadContextMessage] = []
            for row in recentRows.prefix(ReadContextLimits.recentMessages) {
                if let message = try readContextMessage(id: parseID(MessageID.self, row.text("id")), authority: authority, history: &history) {
                    recent.append(message)
                } else { excludedMessages += 1 }
            }
            // A candidate of the right shape that admission still rejects occupies
            // its slot. Never walk the full transcript to fill a quota with
            // admitted bodies; the scan above is the only look back there is.
            let olderThan = try recentRows.prefix(ReadContextLimits.recentMessages).last?.integer("sequence") ?? request.beforeSequence
            var olderRows: [SQLiteRow] = []
            if !request.searchTerms.isEmpty {
                let match = request.searchTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    .joined(separator: " OR ")
                // The same authorship as the recent window: a row admission can
                // never accept (a new bot's opening question, another member's
                // reply, a brief) is not a candidate, so it is not counted as
                // left out either. Otherwise "tell me" in the user's first
                // answer matches the opening question and the reply says some
                // earlier messages were not included.
                olderRows = try query(sql: """
                    SELECT m.id,m.sequence FROM conversation_message_search
                    JOIN messages m ON m.rowid=conversation_message_search.rowid AND m.id=conversation_message_search.message_id
                    WHERE conversation_message_search MATCH ? AND m.conversation_id=? AND m.sequence<?
                      AND ((m.author_kind='user' AND m.author_teammate_id IS NULL)
                           OR ((m.author_kind='system' OR (m.author_kind='teammate' AND m.author_teammate_id=?))
                               AND EXISTS(SELECT 1 FROM messages u WHERE u.conversation_id=m.conversation_id
                                          AND u.sequence=m.sequence-1
                                          AND u.author_kind='user' AND u.author_teammate_id IS NULL)))
                    ORDER BY bm25(conversation_message_search),m.sequence DESC,m.id LIMIT ?;
                    """, bindings: [.text(match), .text(request.conversationID.persistedValue), .integer(olderThan),
                        .text(request.teammateID.persistedValue),
                        .integer(Int64(ReadContextLimits.olderMessages + 1))])
            }
            var older: [ReadContextMessage] = []
            for row in olderRows.prefix(ReadContextLimits.olderMessages) {
                if let message = try readContextMessage(id: parseID(MessageID.self, row.text("id")), authority: authority, history: &history) {
                    older.append(message)
                } else { excludedMessages += 1 }
            }

            try validateReadContextMemoryAuthority()
            var documents: [MemoryDocument] = []
            var excludedMemory = 0
            var moreMemory = false
            // No shared-memory enablement exists in this authority contract.
            // A project selection never grants access to global user memory.
            var scopes: [MemoryScope] = [.teammate(request.teammateID)]
            if let project = authority.selectedProjectID { scopes.append(.project(project)) }
            for scope in scopes {
                let rows = try readContextMemoryRows(scope: scope, limit: ReadContextLimits.memoryHeadsPerScope + 1)
                moreMemory = moreMemory || rows.count > ReadContextLimits.memoryHeadsPerScope
                for row in rows.prefix(ReadContextLimits.memoryHeadsPerScope) {
                    if let document = try decodeReadContextMemory(row),
                       try !memoryPublicationBlocksUseRow(documentID: document.id) { documents.append(document) }
                    else { excludedMemory += 1 }
                }
            }
            let messageReferences = (recent + older).map(\.reference)
            let memoryReferences = try documents.map(readContextMemoryReference)
            let receipt = readContextReceipt(authority, messages: messageReferences, memory: memoryReferences)
            return ReadContextSnapshot(receipt: receipt, recentMessages: Array(recent.reversed()), olderMessages: older,
                memoryDocuments: documents, omissions: ReadContextOmissions(excludedMessageLowerBound: excludedMessages,
                    recentWindowHasMore: recentRows.count > ReadContextLimits.recentMessages || lookBackWasFull,
                    olderWindowHasMore: olderRows.count > ReadContextLimits.olderMessages,
                    memoryWindowHasMore: moreMemory, excludedMemoryLowerBound: excludedMemory))
        }
    }

    public func revalidateReadContext(_ receipt: ReadContextReceipt) async throws {
        try transaction { try validateReadContextReceipt(receipt) }
    }
}

extension SQLiteStore {
    /// Synchronous so beginTextTurn can validate inside the same admission transaction.
    /// Also call freshly immediately before dispatch. No transaction can retract bytes
    /// already delivered; the final DB-check-to-process-write race remains explicit.
    func validateReadContextReceipt(_ receipt: ReadContextReceipt,
                                    excludingMemoryPublicationID: UUID? = nil) throws {
        if let version = receipt.qualificationVersion {
            guard version == 1, let claims = receipt.claimReferences,
                  (try? receipt.qualifying(with: claims)) == receipt else { throw ReadContextError.invalidRequest }
        } else if receipt.claimReferences != nil { throw ReadContextError.invalidRequest }
        guard receipt.messages.count <= ReadContextLimits.recentMessages + ReadContextLimits.olderMessages,
              receipt.memoryDocuments.count <= 3 * ReadContextLimits.memoryHeadsPerScope,
              Set(receipt.messages.map(\.messageID)).count == receipt.messages.count,
              Set(receipt.memoryDocuments.map(\.documentID)).count == receipt.memoryDocuments.count else {
            throw ReadContextError.invalidRequest
        }
        let current = try readContextAuthority(conversationID: receipt.conversationID, teammateID: receipt.teammateID,
            profileRevision: receipt.profileRevision, selection: receipt.selection)
        guard readContextReceipt(receipt, messages: [], memory: []) == current else { throw ReadContextError.staleReferences }
        var history = ReadContextHistoryValidation(excludingMemoryPublicationID: excludingMemoryPublicationID)
        for reference in receipt.messages {
            guard let message = try readContextMessage(id: reference.messageID, authority: current, history: &history),
                  message.reference == reference else { throw ReadContextError.staleReferences }
        }
        try validateReadContextMemoryAuthority()
        for reference in receipt.memoryDocuments {
            guard readContextScopeIsEligible(reference.scope, authority: current),
                  try !memoryPublicationBlocksUseRow(documentID: reference.documentID,
                      excludingMemoryPublicationID: excludingMemoryPublicationID),
                  let row = try readContextMemoryRows(scope: reference.scope, limit: 1, id: reference.documentID).first,
                  let document = try decodeReadContextMemory(row),
                  try readContextMemoryReference(document) == reference else { throw ReadContextError.staleReferences }
        }
    }

    private func readContextAuthority(conversationID: ConversationID, teammateID: TeammateID,
                                      profileRevision: UInt64, selection: ConversationContextSelection) throws -> ReadContextReceipt {
        guard selection.conversationID == conversationID, selection.teammateID == teammateID,
              profileRevision > 0, profileRevision <= UInt64(Int64.max), selection.revision <= UInt64(Int64.max) else {
            throw ReadContextError.invalidRequest
        }
        // A hidden bot is refused only in its own chat; in its teams it keeps
        // its seat.
        let participants = try query(sql: """
            SELECT p.joined_at FROM conversations c JOIN teammates t ON t.id=?
            JOIN conversation_participants p ON p.conversation_id=c.id AND p.teammate_id=t.id AND p.left_at IS NULL
            WHERE c.id=? AND c.lifecycle='active' AND t.lifecycle='active' AND t.profile_revision=?
              AND ((c.kind='direct' AND c.subject_id=t.id AND t.is_hidden=0)
                   OR (c.kind='team' AND EXISTS(SELECT 1 FROM teams tm JOIN team_memberships m ON m.team_id=tm.id
                                                WHERE tm.id=c.subject_id AND tm.lifecycle='active'
                                                  AND m.teammate_id=t.id AND m.revoked_at IS NULL))) LIMIT 2;
            """, bindings: [.text(teammateID.persistedValue), .text(conversationID.persistedValue), .integer(Int64(profileRevision))])
        guard participants.count == 1, let participant = participants.first else { throw ReadContextError.unavailable }
        let joined = try participant.real("joined_at")
        guard joined.isFinite else { throw ReadContextError.invalidStoredRecord }
        let context = try query(sql: "SELECT teammate_id,project_id,team_id,revision FROM conversation_context_selections WHERE conversation_id=?;",
            bindings: [.text(conversationID.persistedValue)]).first
        if let context {
            guard try context.text("teammate_id") == teammateID.persistedValue,
                  try context.integer("revision") > 0,
                  try context.integer("revision") == Int64(selection.revision),
                  try context.optionalText("project_id") == selection.projectID?.persistedValue,
                  try context.optionalText("team_id") == selection.teamID?.persistedValue else { throw ReadContextError.staleReferences }
        } else if selection.revision != 0 || selection.projectID != nil || selection.teamID != nil {
            throw ReadContextError.staleReferences
        }
        let projectJoined = try selection.projectID.map {
            try readContextMembershipJoinedAt(kind: "project", scopeID: $0.persistedValue, teammateID: teammateID)
        }
        let teamJoined = try selection.teamID.map {
            try readContextMembershipJoinedAt(kind: "team", scopeID: $0.persistedValue, teammateID: teammateID)
        }
        return ReadContextReceipt(conversationID: conversationID, teammateID: teammateID, profileRevision: profileRevision,
            contextRevision: selection.revision, selectedProjectID: selection.projectID, selectedTeamID: selection.teamID,
            participantJoinedAt: Date(timeIntervalSince1970: joined), projectMembershipJoinedAt: projectJoined,
            teamMembershipJoinedAt: teamJoined, messages: [], memoryDocuments: [])
    }

    private func readContextMembershipJoinedAt(kind: String, scopeID: String, teammateID: TeammateID) throws -> Date {
        // The table/column fragments are selected only by the two literal call sites above.
        guard kind == "project" || kind == "team" else { throw ReadContextError.invalidRequest }
        let rows = try query(sql: """
            SELECT m.joined_at FROM \(kind)s s JOIN \(kind)_memberships m ON m.\(kind)_id=s.id
            WHERE s.id=? AND s.lifecycle='active' AND m.teammate_id=? AND m.revoked_at IS NULL LIMIT 2;
            """, bindings: [.text(scopeID), .text(teammateID.persistedValue)])
        guard rows.count == 1, let row = rows.first else { throw ReadContextError.unavailable }
        let joined = try row.real("joined_at")
        guard joined.isFinite else { throw ReadContextError.invalidStoredRecord }
        return Date(timeIntervalSince1970: joined)
    }

    private func readContextReceipt(_ base: ReadContextReceipt, messages: [ReadContextMessageReference],
                                    memory: [ReadContextMemoryReference]) -> ReadContextReceipt {
        ReadContextReceipt(conversationID: base.conversationID, teammateID: base.teammateID,
            profileRevision: base.profileRevision, contextRevision: base.contextRevision,
            selectedProjectID: base.selectedProjectID, selectedTeamID: base.selectedTeamID,
            participantJoinedAt: base.participantJoinedAt, projectMembershipJoinedAt: base.projectMembershipJoinedAt,
            teamMembershipJoinedAt: base.teamMembershipJoinedAt, messages: messages, memoryDocuments: memory)
    }

    private func readContextScopeIsEligible(_ scope: MemoryScope, authority: ReadContextReceipt) -> Bool {
        switch scope {
        case .user: false
        case let .teammate(id): id == authority.teammateID
        case let .project(id): id == authority.selectedProjectID && authority.projectMembershipJoinedAt != nil
        }
    }

    private func readContextMessage(id: MessageID, authority: ReadContextReceipt,
                                    history: inout ReadContextHistoryValidation) throws -> ReadContextMessage? {
        guard let target = try query(sql: """
            SELECT id,sequence,author_kind,author_teammate_id FROM messages
            WHERE id=? AND conversation_id=? AND output_class='conversation' AND delivery_state IN ('completed','outcomeUnknown');
            """, bindings: [.text(id.persistedValue), .text(authority.conversationID.persistedValue)]).first else { return nil }
        let sequence = try target.integer("sequence")
        let authorKind = try target.text("author_kind")
        let authorTeammate = try target.optionalText("author_teammate_id")
        guard sequence > 0, sequence < Int64.max else { return nil }
        let userID: String
        if authorKind == "user", authorTeammate == nil {
            userID = id.persistedValue
        } else if (authorKind == "teammate" && authorTeammate == authority.teammateID.persistedValue)
                    || (authorKind == "system" && authorTeammate == nil),
                  let previous = try query(sql: "SELECT id FROM messages WHERE conversation_id=? AND sequence=? AND author_kind='user';",
                    bindings: [.text(authority.conversationID.persistedValue), .integer(sequence - 1)]).first {
            userID = try previous.text("id")
        } else { return nil }

        // IDs only, followed by an exact bounded scalar projection. No WorkRequest JSON
        // or unrelated message body crosses the repository boundary.
        let runs = try query(sql: """
            SELECT r.id FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            WHERE r.teammate_id=? AND r.conversation_id=? AND r.initiating_message_id=?
                AND \(Self.readContextAdmittedRunSQL) AND j.origin='executor' LIMIT 2;
            """, bindings: [.text(authority.teammateID.persistedValue), .text(authority.conversationID.persistedValue), .text(userID)])
        guard runs.count == 1, let run = runs.first else { return nil }
        let runID = try parseID(RunID.self, run.text("id"))
        let controlled = try controlledPublicationRow(runID: runID)
        if authorKind == "system" {
            guard let controlled, controlled.replyMessage.id == id,
                  controlled.providerRunID == runID else { return nil }
        }
        // A saved reply can carry an earlier global-memory excerpt even when its
        // own direct memory list is empty. Check its bounded receipt ancestry
        // before projecting any candidate body, including during revalidation.
        guard try readContextHistoryIsEligible(runID, authority: authority, validation: &history) else { return nil }
        let rows = try query(sql: Self.readContextCorrelatedMessageSQL,
            bindings: [.text(id.persistedValue), .text(runID.persistedValue), .text(authority.conversationID.persistedValue),
                .text(authority.teammateID.persistedValue), authority.selectedProjectID.map { .text($0.persistedValue) } ?? .null,
                .integer(Int64(ReadContextLimits.messageUTF8Bytes))])
        guard let row = rows.first else { return nil }
        let text = try row.text("body")
        guard !text.isEmpty, text.utf8.count <= ReadContextLimits.messageUTF8Bytes,
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              UUID(uuidString: try row.text("app_owner")) != nil else { return nil }
        let runRevision = try row.integer("run_revision"), updated = try row.real("message_updated_at")
        let runUpdated = try row.real("run_updated_at")
        guard runRevision > 0, updated.isFinite, runUpdated.isFinite else { return nil }
        let project = try row.optionalText("selected_project_id").map { try parseID(ProjectID.self, $0) }
        // The reply of a stopped pair is settled `outcomeUnknown`
        // (the admission SQL above ties that state to an interrupted run), and
        // what it holds is what the bot had written when the kill landed. It
        // is marked so the assembler can say so; the request beside it was
        // acknowledged whole, and every message of a finished turn is whole.
        let delivery = try row.text("delivery_state")
        let ending: ReadContextMessageEnding = authorKind != "user" && delivery == "outcomeUnknown" ? .stopped : .finished
        return ReadContextMessage(author: authorKind == "user" ? .user : (authorKind == "system" ? .system : .teammate(authority.teammateID)), text: text,
            reference: ReadContextMessageReference(messageID: id, runID: runID, runRevision: runRevision,
                runUpdatedAt: Date(timeIntervalSince1970: runUpdated), sequence: sequence,
                messageUpdatedAt: Date(timeIntervalSince1970: updated), selectedProjectID: project,
                contentDigest: Self.readContextDigest(Data(text.utf8)),
                memoryQualificationRequired: history.memoryQualificationRequired[runID] ?? true),
            ending: ending)
    }

    /// Memoization for one read or one check. Unknown ancestry omits optional
    /// context; it never enables shared memory or edits history.
    private struct ReadContextHistoryValidation {
        var excludingMemoryPublicationID: UUID? = nil
        var results: [RunID: Bool] = [:]
        var memoryQualificationRequired: [RunID: Bool] = [:]
        /// Each memory document's current reference, read once per read; nil
        /// when it is gone, superseded or held by a pending publication.
        var currentMemory: [MemoryDocumentID: ReadContextMemoryReference?] = [:]
    }

    /// What a turn's frozen receipt rests on, proved once and stored. It never says whether the turn itself may be quoted:
    /// that changes after the fact, as when a correction names an interrupted
    /// turn, so it is read at the time of use, like memory heads.
    struct ReadContextTurnProof: Equatable {
        let proven: Bool
        let memoryQualificationRequired: Bool
        let memory: [ReadContextMemoryReference]

        static let unproven = ReadContextTurnProof(proven: false, memoryQualificationRequired: false, memory: [])
    }

    /// A quoted turn may lend its messages when it is admitted and in scope
    /// now, its stored proof says proven, and every memory reference under it
    /// is still current. Proven once, a turn is never walked again: a read
    /// costs what it quotes, however long the conversation (walking every
    /// turn within a 1,024-turn ceiling instead would leave the newest turns
    /// out past the ceiling).
    private func readContextHistoryIsEligible(_ runID: RunID, authority: ReadContextReceipt,
                                              validation: inout ReadContextHistoryValidation) throws -> Bool {
        if let known = validation.results[runID] { return known }
        do {
            let eligible = try readContextTurnIsEligibleNow(runID, authority: authority, validation: &validation)
            validation.results[runID] = eligible
            return eligible
        } catch where Self.isUnreadableStoredRecord(error) {
            // A turn whose stored record cannot be read is unproven, and a
            // message resting on it is left out of context; a failing database
            // still ends the read, which may be the one that admits a turn.
            validation.results[runID] = false
            return false
        }
    }

    /// One stored record this reader cannot make sense of, as against a database
    /// that is failing: a failing database must still end the read, because this
    /// check runs inside the transaction that admits a turn.
    private static func isUnreadableStoredRecord(_ error: Error) -> Bool {
        if let error = error as? SQLiteStoreError, case .invalidRow = error { return true }
        if let error = error as? MemoryPublicationError { return error == .notFound || error == .invalidStoredState }
        if let error = error as? ReadContextError { return error == .invalidStoredRecord }
        return false
    }

    private func readContextTurnIsEligibleNow(_ runID: RunID, authority: ReadContextReceipt,
                                              validation: inout ReadContextHistoryValidation) throws -> Bool {
        let rows = try query(sql: """
            SELECT u.sequence FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            JOIN messages u ON u.id=r.initiating_message_id AND u.conversation_id=r.conversation_id
            WHERE r.id=? AND r.conversation_id=? AND r.teammate_id=?
                AND \(Self.readContextAdmittedRunSQL) AND j.origin='executor'
                AND (r.selected_project_id IS NULL OR r.selected_project_id IS ?)
            LIMIT 1;
            """, bindings: [.text(runID.persistedValue), .text(authority.conversationID.persistedValue),
                .text(authority.teammateID.persistedValue), authority.selectedProjectID.map { .text($0.persistedValue) } ?? .null])
        guard let row = rows.first else { return false }
        var proof = try storedReadContextTurnProof(runID)
        if proof == nil {
            try storeReadContextTurnProofs(conversationID: authority.conversationID, teammateID: authority.teammateID,
                through: row.integer("sequence"))
            proof = try storedReadContextTurnProof(runID)
        }
        guard let proof, proof.proven else { return false }
        for reference in proof.memory {
            guard try readContextMemoryIsCurrent(reference, authority: authority, validation: &validation) else { return false }
        }
        validation.memoryQualificationRequired[runID] = proof.memoryQualificationRequired
        return true
    }

    /// A successful old reply is not an independent source: every memory
    /// document under it must still be current, pending corrections included,
    /// and in a scope this read may use. Unavailable or changed heads never
    /// revive through history.
    private func readContextMemoryIsCurrent(_ reference: ReadContextMemoryReference, authority: ReadContextReceipt,
                                            validation: inout ReadContextHistoryValidation) throws -> Bool {
        guard readContextScopeIsEligible(reference.scope, authority: authority) else { return false }
        if let known = validation.currentMemory[reference.documentID] { return known == reference }
        var current: ReadContextMemoryReference?
        if try !memoryPublicationBlocksUseRow(documentID: reference.documentID,
                   excludingMemoryPublicationID: validation.excludingMemoryPublicationID),
           let row = try readContextMemoryRows(scope: reference.scope, limit: 1, id: reference.documentID).first,
           let document = try decodeReadContextMemory(row) {
            current = try readContextMemoryReference(document)
        }
        validation.currentMemory[reference.documentID] = .some(current)
        return current == reference
    }

    private func storedReadContextTurnProof(_ runID: RunID) throws -> ReadContextTurnProof? {
        guard let row = try query(sql: """
            SELECT proven,memory_qualification_required,memory_references_json FROM read_context_turn_proofs WHERE run_id=?;
            """, bindings: [.text(runID.persistedValue)]).first else { return nil }
        guard try row.integer("proven") == 1 else { return .unproven }
        guard let memory = try? JSONDecoder().decode([ReadContextMemoryReference].self,
                  from: Data(try row.text("memory_references_json").utf8)) else {
            throw ReadContextError.invalidStoredRecord
        }
        return ReadContextTurnProof(proven: true,
            memoryQualificationRequired: try row.integer("memory_qualification_required") == 1, memory: memory)
    }

    /// Proves and stores every turn of this bot in this conversation that has
    /// no proof yet, up to and including the one at `sequence`, oldest first,
    /// so each proof finds the turns it quotes already stored and goes one turn
    /// deep. Admission runs it for the turn it writes; a read runs it when a
    /// quoted turn was saved before proofs were stored, which happens once.
    func storeReadContextTurnProofs(conversationID: ConversationID, teammateID: TeammateID, through sequence: Int64) throws {
        let runs = try query(sql: """
            SELECT r.id FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            JOIN messages u ON u.id=r.initiating_message_id AND u.conversation_id=r.conversation_id
            WHERE r.conversation_id=? AND r.teammate_id=? AND j.origin='executor' AND u.sequence<=?
                AND NOT EXISTS (SELECT 1 FROM read_context_turn_proofs p WHERE p.run_id=r.id)
            ORDER BY u.sequence;
            """, bindings: [.text(conversationID.persistedValue), .text(teammateID.persistedValue), .integer(sequence)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for row in runs {
            // A row whose id cannot be read names no turn to prove, and no
            // receipt can quote it.
            guard let runID = try? parseID(RunID.self, row.text("id")) else { continue }
            let proof: ReadContextTurnProof
            do {
                proof = try readContextTurnProof(runID, conversationID: conversationID, teammateID: teammateID)
            } catch where Self.isUnreadableStoredRecord(error) {
                proof = .unproven
            }
            _ = try execute(sql: """
                INSERT INTO read_context_turn_proofs(run_id,proven,memory_qualification_required,memory_references_json)
                VALUES (?,?,?,?);
                """, bindings: [.text(runID.persistedValue), .integer(proof.proven ? 1 : 0),
                    .integer(proof.memoryQualificationRequired ? 1 : 0),
                    .text(String(decoding: try encoder.encode(proof.memory), as: UTF8.self))])
        }
    }

    /// What one turn's frozen receipt rests on. Only bounded, path- and
    /// body-free receipt metadata crosses into Swift. Nothing here depends on
    /// the reader's selection: the turn's own project bounds what it could
    /// quote, and the reader's is applied when the proof is used.
    private func readContextTurnProof(_ runID: RunID, conversationID: ConversationID,
                                      teammateID: TeammateID) throws -> ReadContextTurnProof {
        let rows = try query(sql: """
            SELECT r.profile_revision,r.selected_project_id,u.sequence,
                CASE WHEN json_valid(j.request_json) THEN
                    CASE WHEN json_type(j.request_json,'$.readContextReceipt') IS NULL
                               OR json_type(j.request_json,'$.readContextReceipt')='null' THEN 1
                         WHEN json_type(j.request_json,'$.readContextReceipt')='object' THEN 2
                         ELSE 0 END ELSE 0 END AS receipt_kind,
                CASE WHEN json_valid(j.request_json) THEN
                    CASE WHEN json_type(j.request_json,'$.readContextReceipt')='object'
                        AND length(CAST(json_extract(j.request_json,'$.readContextReceipt') AS BLOB))<=32768
                        THEN json_extract(j.request_json,'$.readContextReceipt') END END AS receipt
            FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            JOIN messages u ON u.id=r.initiating_message_id AND u.conversation_id=r.conversation_id
            WHERE r.id=? AND r.conversation_id=? AND r.teammate_id=? AND j.origin='executor'
            LIMIT 1;
            """, bindings: [.text(runID.persistedValue), .text(conversationID.persistedValue), .text(teammateID.persistedValue)])
        guard let row = rows.first else { return .unproven }
        // A nil receipt preserves proven turns from before context integration.
        if try row.integer("receipt_kind") == 1 {
            return ReadContextTurnProof(proven: true, memoryQualificationRequired: false, memory: [])
        }
        let project = try row.optionalText("selected_project_id").map { try parseID(ProjectID.self, $0) }
        guard try row.integer("receipt_kind") == 2, let encoded = try row.optionalText("receipt"),
              let receipt = try? JSONDecoder().decode(ReadContextReceipt.self, from: Data(encoded.utf8)),
              receipt.conversationID == conversationID, receipt.teammateID == teammateID,
              receipt.profileRevision <= UInt64(Int64.max),
              try Int64(receipt.profileRevision) == row.integer("profile_revision"),
              receipt.selectedProjectID == project,
              receipt.messages.count <= ReadContextLimits.recentMessages + ReadContextLimits.olderMessages,
              receipt.memoryDocuments.count <= 3 * ReadContextLimits.memoryHeadsPerScope,
              Set(receipt.messages.map(\.messageID)).count == receipt.messages.count,
              Set(receipt.memoryDocuments.map(\.documentID)).count == receipt.memoryDocuments.count,
              receipt.memoryDocuments.allSatisfy({
                  switch $0.scope {
                  case .user: false
                  case let .teammate(id): id == teammateID
                  case let .project(id): id == project
                  }
              }) else { return .unproven }
        let before = try row.integer("sequence")
        var memory = receipt.memoryDocuments
        var qualification = !receipt.memoryDocuments.isEmpty
        for reference in receipt.messages {
            // A quoted turn is this bot's, in this conversation, of no project
            // or the turn's own, still matching its stamps, and already proven.
            guard reference.sequence > 0, reference.sequence < before,
                  reference.selectedProjectID == nil || reference.selectedProjectID == project,
                  try readContextHistoryReferenceMatches(reference, conversationID: conversationID, teammateID: teammateID),
                  let quoted = try storedReadContextTurnProof(reference.runID), quoted.proven else { return .unproven }
            memory += quoted.memory
            qualification = qualification || quoted.memoryQualificationRequired
        }
        // One reference per document. Two different ones for the same
        // document can never both be current, so the turn can never be used.
        // The list stays small without a cap: admission quotes only turns whose
        // memory is current, so a turn stores no more than the memory heads of
        // its bot and project at that moment. A corrected memory is a new
        // document, and the turns resting on the old one stop being quotable,
        // so revisions do not pile up.
        var unique: [ReadContextMemoryReference] = []
        for reference in memory {
            if let seen = unique.first(where: { $0.documentID == reference.documentID }) {
                guard seen == reference else { return .unproven }
            } else { unique.append(reference) }
        }
        return ReadContextTurnProof(proven: true, memoryQualificationRequired: qualification, memory: unique)
    }

    private func readContextHistoryReferenceMatches(_ reference: ReadContextMessageReference,
                                                     conversationID: ConversationID, teammateID: TeammateID) throws -> Bool {
        // Correlate the metadata edge without loading the referenced message body.
        try !query(sql: """
            SELECT 1 AS matched FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
            JOIN messages m ON m.id=? AND m.conversation_id=r.conversation_id
            WHERE r.id=? AND r.conversation_id=? AND r.teammate_id=?
                AND \(Self.readContextAdmittedRunSQL) AND j.origin='executor'
                AND m.id IN (r.initiating_message_id,
                    CASE WHEN json_valid(j.request_json) THEN json_extract(j.request_json,'$.textTurnIdentity.replyMessageID') END)
                AND m.sequence=? AND m.updated_at=? AND j.revision=? AND r.updated_at=?
                AND r.selected_project_id IS ? AND m.delivery_state=\(Self.readContextAdmittedDeliverySQL) AND m.output_class='conversation'
            LIMIT 1;
            """, bindings: [.text(reference.messageID.persistedValue), .text(reference.runID.persistedValue),
                .text(conversationID.persistedValue), .text(teammateID.persistedValue),
                .integer(reference.sequence), .real(reference.messageUpdatedAt.timeIntervalSince1970),
                .integer(reference.runRevision), .real(reference.runUpdatedAt.timeIntervalSince1970),
                reference.selectedProjectID.map { .text($0.persistedValue) } ?? .null]).isEmpty
    }

    /// Which runs may lend their pair to history: every run that succeeded,
    /// and every run that ended interrupted, whether a correction stopped it
    /// or the user pressed Stop (the user saw that reply on screen, so the bot
    /// remembers it). The
    /// cut-off reply is marked as stopped where it is read, below.
    private static let readContextAdmittedRunSQL = """
        (r.state='succeeded' OR r.state='interrupted')
        """

    /// The delivery state each side of an admitted pair must carry: completed
    /// for a succeeded run; for a stopped one, `outcomeUnknown`, which is what
    /// an acknowledged request and its cut-off reply are settled with.
    private static let readContextAdmittedDeliverySQL = """
        CASE r.state WHEN 'succeeded' THEN 'completed' WHEN 'interrupted' THEN 'outcomeUnknown' END
        """

    private static let readContextCorrelatedMessageSQL = """
        SELECT target.id,j.revision AS run_revision,r.updated_at AS run_updated_at,
            target.updated_at AS message_updated_at,target.delivery_state,r.selected_project_id,tp.text_value AS body,
            CASE WHEN json_valid(j.request_json) THEN substr(json_extract(j.request_json,'$.textTurnIdentity.appOwnerID'),1,129) END AS app_owner
        FROM work_runs r JOIN run_journal_metadata j ON j.run_id=r.id
        JOIN messages u ON u.id=r.initiating_message_id
        JOIN messages a ON a.id=CASE WHEN json_valid(j.request_json) THEN json_extract(j.request_json,'$.textTurnIdentity.replyMessageID') END
        JOIN messages target ON target.id=? AND target.id IN (u.id,a.id)
        JOIN message_parts up ON up.message_id=u.id AND up.ordinal=0 AND up.kind='text'
        JOIN message_parts ap ON ap.message_id=a.id AND ap.ordinal=0 AND ap.kind IN ('text','status')
        JOIN message_parts tp ON tp.message_id=target.id AND tp.ordinal=0 AND tp.kind='text'
        JOIN run_input_receipts i ON i.run_id=r.id AND i.message_id=u.id AND i.sequence=1
        WHERE r.id=? AND r.conversation_id=? AND r.teammate_id=? AND \(readContextAdmittedRunSQL) AND j.origin='executor'
            AND (ap.kind='text' OR (r.state='interrupted' AND target.id=u.id))
            AND (r.selected_project_id IS NULL OR r.selected_project_id IS ?)
            AND j.lease_owner_id IS NULL AND j.lease_token IS NULL AND j.lease_expires_at IS NULL
            AND u.conversation_id=r.conversation_id AND a.conversation_id=r.conversation_id
            AND u.author_kind='user' AND u.author_teammate_id IS NULL
            AND ((a.author_kind='teammate' AND a.author_teammate_id=r.teammate_id
                  AND NOT EXISTS (SELECT 1 FROM controlled_memory_text_turns c WHERE c.run_id=r.id))
                OR (a.author_kind='system' AND a.author_teammate_id IS NULL
                    AND EXISTS (SELECT 1 FROM controlled_memory_text_turns c
                        WHERE c.run_id=r.id AND c.policy_version=1 AND c.publication_id IS NOT NULL)))
            AND u.output_class='conversation' AND a.output_class='conversation'
            AND u.delivery_state=\(readContextAdmittedDeliverySQL) AND a.delivery_state=\(readContextAdmittedDeliverySQL)
            AND a.sequence=u.sequence+1
            AND u.created_at=r.created_at AND a.created_at=r.created_at AND r.updated_at>=r.created_at
            AND u.updated_at>=u.created_at AND a.updated_at>=a.created_at
            AND length(CAST(tp.text_value AS BLOB)) BETWEEN 1 AND ?
            AND length(CAST(up.text_value AS BLOB)) BETWEEN 1 AND 1048576
            AND length(CAST(ap.text_value AS BLOB)) BETWEEN 1 AND 1048576
            AND up.referenced_id IS NULL AND ap.referenced_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM message_parts p WHERE p.message_id IN (u.id,a.id) AND p.ordinal!=0)
            AND i.state='acknowledged' AND i.input_text=up.text_value AND i.submitted_at=r.created_at
            AND CASE WHEN json_valid(i.attachment_ids_json) THEN json_type(i.attachment_ids_json)='array' AND json_array_length(i.attachment_ids_json)=0 ELSE 0 END
            AND NOT EXISTS (SELECT 1 FROM run_input_receipts other WHERE other.run_id=r.id AND other.sequence!=1)
            AND EXISTS (SELECT 1 FROM run_journal_entries e WHERE e.run_id=r.id AND e.sequence=j.revision AND e.state=r.state AND e.recorded_at=r.updated_at)
            AND CASE WHEN json_valid(j.request_json) THEN
                json_type(j.request_json,'$.textTurnIdentity')='object'
                AND json_type(j.request_json,'$.textTurnIdentity.appOwnerID')='text'
                AND json_extract(j.request_json,'$.runID')=r.id COLLATE NOCASE
                AND json_extract(j.request_json,'$.teammateID')=r.teammate_id COLLATE NOCASE
                AND json_extract(j.request_json,'$.conversationID')=r.conversation_id COLLATE NOCASE
                AND json_extract(j.request_json,'$.initiatingMessageID')=u.id COLLATE NOCASE
                AND json_extract(j.request_json,'$.selectedProjectID') IS r.selected_project_id
                AND json_extract(j.request_json,'$.profileRevision')=r.profile_revision
                AND json_extract(j.request_json,'$.textTurnIdentity.replyPartID')=ap.id COLLATE NOCASE
                AND json_extract(j.request_json,'$.initialInput.messageID')=u.id COLLATE NOCASE
                AND json_extract(j.request_json,'$.initialInput.sequence')=1
                AND json_type(j.request_json,'$.initialInput.text')='text'
                AND json_extract(j.request_json,'$.initialInput.text')=up.text_value
                AND json_type(j.request_json,'$.initialInput.attachmentIDs')='array'
                AND json_array_length(j.request_json,'$.initialInput.attachmentIDs')=0
                ELSE 0 END
        LIMIT 1;
        """

    private func validateReadContextMemoryAuthority() throws {
        let rows = try query(sql: "SELECT key,value FROM app_metadata WHERE key IN ('memory_authority_kind','memory_authority_format_version','memory_authority_relative_root');")
        let values = try Dictionary(uniqueKeysWithValues: rows.map { (try $0.text("key"), try $0.text("value")) })
        guard values["memory_authority_kind"] == "app-owned-markdown-tree", values["memory_authority_format_version"] == "1",
              values["memory_authority_relative_root"] == "HighChurn.noindex/Memory" else { throw ReadContextError.unavailable }
    }

    private func readContextMemoryRows(scope: MemoryScope, limit: Int, id: MemoryDocumentID? = nil) throws -> [SQLiteRow] {
        let kind: String, scopeID: String?
        switch scope {
        case .user: kind = "user"; scopeID = nil
        case let .teammate(value): kind = "teammate"; scopeID = value.persistedValue
        case let .project(value): kind = "project"; scopeID = value.persistedValue
        }
        let exactID = id == nil ? "" : "AND d.id=?"
        return try query(sql: """
            SELECT d.id,d.scope_kind,d.scope_id,d.author_kind,d.author_teammate_id,d.revision,d.supersedes_id,d.created_at,d.updated_at,
                CASE WHEN length(CAST(d.title AS BLOB))<=800 THEN d.title END AS title,
                CASE WHEN length(CAST(d.relative_path AS BLOB))<=4096 THEN d.relative_path END AS relative_path,
                CASE WHEN length(CAST(d.content_digest AS BLOB))<=512 THEN d.content_digest END AS content_digest
            FROM memory_documents d WHERE d.scope_kind=? AND d.scope_id IS ? \(exactID)
                AND NOT EXISTS(SELECT 1 FROM memory_documents child WHERE child.supersedes_id=d.id)
            ORDER BY d.updated_at DESC,d.id LIMIT ?;
            """, bindings: [.text(kind), scopeID.map(SQLiteBinding.text) ?? .null]
                + (id.map { [.text($0.persistedValue)] } ?? []) + [.integer(Int64(limit))])
    }

    private func decodeReadContextMemory(_ row: SQLiteRow) throws -> MemoryDocument? {
        guard let title = try row.optionalText("title"), let path = try row.optionalText("relative_path"),
              let digest = try row.optionalText("content_digest"),
              digest.count == 64, digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else { return nil }
        let scope: MemoryScope
        switch (try row.text("scope_kind"), try row.optionalText("scope_id")) {
        case ("user", nil): scope = .user
        case let ("teammate", .some(id)): scope = .teammate(try parseID(TeammateID.self, id))
        case let ("project", .some(id)): scope = .project(try parseID(ProjectID.self, id))
        default: return nil
        }
        let author: MemoryAuthor
        switch (try row.text("author_kind"), try row.optionalText("author_teammate_id")) {
        case ("user", nil): author = .user
        case ("system", nil): author = .system
        case let ("teammate", .some(id)): author = .teammate(try parseID(TeammateID.self, id))
        default: return nil
        }
        let revision = try row.integer("revision"), created = try row.real("created_at"), updated = try row.real("updated_at")
        guard revision > 0, created.isFinite, updated.isFinite, updated >= created else { return nil }
        return try? MemoryDocument(id: parseID(MemoryDocumentID.self, row.text("id")), scope: scope, author: author,
            title: title, relativePath: path, revision: UInt64(revision), contentDigest: digest,
            supersedes: row.optionalText("supersedes_id").map { try parseID(MemoryDocumentID.self, $0) },
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func readContextMemoryReference(_ document: MemoryDocument) throws -> ReadContextMemoryReference {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ReadContextMemoryReference(documentID: document.id, scope: document.scope, revision: document.revision,
            contentDigest: document.contentDigest, metadataDigest: Self.readContextDigest(try encoder.encode(document)))
    }

    private static func readContextDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
