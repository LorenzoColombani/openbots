import Foundation
import OpenBotsDomain

extension SQLiteStore: TeammateDeletionRepository {
    /// Leaves out a bot Delete kept only for its team chat history. Every
    /// list of bots and every lifecycle change reads through it; `teammate(id:)` does
    /// not, so the kept messages and handoffs still name their author, as "Deleted
    /// bot".
    static let notDeletedTeammate = "t.id NOT IN (SELECT teammate_id FROM deleted_teammates)"

    public func inventory(id: TeammateID) async throws -> TeammateDeleteInventory {
        try transaction {
            try buildInventory(id: id)
        }
    }

    public func deletedTeammateIDs() async throws -> Set<TeammateID> {
        Set(try query(sql: "SELECT teammate_id FROM deleted_teammates;")
            .map { try parseID(TeammateID.self, $0.text("teammate_id")) })
    }

    public func deleteTeammate(
        id: TeammateID, expectedProfileRevision: UInt64, now: Date
    ) async throws -> Teammate {
        guard now.timeIntervalSince1970.isFinite else { throw TeammateDeleteError.invalidDate }
        return try transaction {
            try Task.checkCancellation()
            guard let teammate = try teammateRows(whereClause: "t.id=? AND \(Self.notDeletedTeammate)",
                                                  bindings: [.text(id.persistedValue)]).first else {
                throw TeammateDeleteError.notFound
            }
            guard teammate.profile.revision == expectedProfileRevision else {
                throw TeammateDeleteError.staleRevision
            }

            if let leadTeam = try query(
                sql: """
                SELECT name FROM teams
                WHERE lead_teammate_id=?
                LIMIT 1;
                """,
                bindings: [.text(id.persistedValue)]
            ).first {
                throw TeammateDeleteError.isTeamLead(teamName: try leadTeam.text("name"))
            }

            let tid = id.persistedValue
            // The new statements name the bot as ?1, bound once however often it appears.
            let ownMessages = "SELECT id FROM messages WHERE author_teammate_id=?1"
            let ownChats = Self.ownDirectChats
            // Its publication intents, found by the documents of its own scope and
            // by the folder they write into. A document it wrote elsewhere may have
            // been revised by another writer, whose intent is not the bot's to remove.
            let scopeDocuments = "SELECT id FROM memory_documents WHERE scope_kind='teammate' AND scope_id=?1"
            let ownIntents = """
                predecessor_id IN (\(scopeDocuments)) OR document_id IN (\(scopeDocuments)) OR final_relative_path GLOB ?2
                """
            let ownFolder = SQLiteBinding.text("Documents/Teammates/\(tid)/*")

            // A card's approvals row is not read, as in Archive: a card lives
            // only inside its turn, which the run line covers, and the row
            // outlives the turn. The delete's cascade removes it.
            let unresolved = try query(sql: """
                SELECT 1 AS unresolved FROM work_runs
                WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted')
                UNION ALL SELECT 1 FROM action_proposals
                WHERE teammate_id=? AND state IN ('pending','approved') LIMIT 1;
                """, bindings: Array(repeating: .text(id.persistedValue), count: 2))
            // A memory publication still in flight is unfinished work too.
            let publishing = try query(
                sql: "SELECT 1 AS pending FROM memory_publication_intents WHERE state='pending' AND (\(ownIntents)) LIMIT 1;",
                bindings: [.text(tid), ownFolder]
            )
            guard unresolved.isEmpty, publishing.isEmpty else { throw TeammateDeleteError.unresolvedWork }

            // A bot that took part in a team chat is deleted, and its messages
            // there stay under the name "Deleted bot", with the handoffs it was
            // part of. Its row stays, emptied and marked, because those messages and
            // other bots' records built on them still name it. Everything else
            // of the bot goes as for any other Delete.
            let keepsTeamHistory = try hasTeamHistory(tid)

            if keepsTeamHistory {
                // Before its runs go, so a leg's run reads as it was.
                try endOpenHandoffs(tid, now: now)
            } else {
                _ = try execute(
                    sql: "DELETE FROM handoffs WHERE sender_teammate_id=? OR receiver_teammate_id=?;",
                    bindings: [.text(tid), .text(tid)]
                )
            }

            // The records of the bot's own runs and proposals do not cascade, so
            // they go first: a bot that had ever replied through Claude or run
            // Work could not be deleted. A run
            // a kept handoff reported through (a former lead's) stays with it.
            let ownRuns = """
                SELECT id FROM work_runs WHERE teammate_id=?1
                AND id NOT IN (SELECT report_run_id FROM handoffs WHERE report_run_id IS NOT NULL)
                """
            for table in ["claude_text_execution_evidence", "controlled_memory_text_turns", "agentic_job_states",
                          "read_context_turn_proofs"] {
                _ = try execute(sql: "DELETE FROM \(table) WHERE run_id IN (\(ownRuns));", bindings: [.text(tid)])
            }
            _ = try execute(
                sql: "DELETE FROM action_proposal_events WHERE proposal_id IN (SELECT id FROM action_proposals WHERE teammate_id=?);",
                bindings: [.text(tid)]
            )
            _ = try execute(sql: "DELETE FROM action_proposals WHERE teammate_id=?;", bindings: [.text(tid)])
            // work_runs hold RESTRICT refs to initiating messages — drop them first.
            _ = try execute(sql: "DELETE FROM work_runs WHERE id IN (\(ownRuns));", bindings: [.text(tid)])
            _ = try execute(sql: "DELETE FROM approvals WHERE teammate_id=?;", bindings: [.text(tid)])

            // Its own memory records point into its chat, its messages and its
            // documents without cascading, so a bot asked what it remembers
            // could not be deleted. The files go to
            // the Trash with its folders (TeammateDeletionService).
            _ = try execute(sql: """
                DELETE FROM memory_local_correction_clarifications
                WHERE reply_message_id IN (\(ownMessages)) OR user_message_id IN
                    (SELECT user_message_id FROM memory_local_corrections WHERE conversation_id IN (\(ownChats)));
                """, bindings: [.text(tid)])
            _ = try execute(sql: "DELETE FROM memory_local_corrections WHERE conversation_id IN (\(ownChats));",
                            bindings: [.text(tid)])
            _ = try execute(sql: """
                DELETE FROM memory_conversation_publications WHERE teammate_id=?1 OR conversation_id IN (\(ownChats));
                """, bindings: [.text(tid)])
            _ = try execute(sql: "DELETE FROM memory_publication_intents WHERE \(ownIntents);",
                            bindings: [.text(tid), ownFolder])

            // Its messages in team chats stay when its team history does.
            _ = try execute(
                sql: keepsTeamHistory
                    ? "DELETE FROM messages WHERE author_teammate_id=?1 AND conversation_id IN (SELECT id FROM conversations WHERE kind='direct');"
                    : "DELETE FROM messages WHERE author_teammate_id=?1;",
                bindings: [.text(tid)]
            )
            _ = try execute(
                sql: """
                DELETE FROM memory_documents
                WHERE author_teammate_id=? OR (scope_kind='teammate' AND scope_id=?);
                """,
                bindings: [.text(tid), .text(tid)]
            )

            let directIDs = try query(
                sql: """
                SELECT c.id AS id FROM conversations c
                INNER JOIN conversation_participants p
                    ON p.conversation_id=c.id AND p.teammate_id=? AND p.left_at IS NULL
                WHERE c.kind='direct';
                """,
                bindings: [.text(tid)]
            )
            for row in directIDs {
                let cid = try row.text("id")
                _ = try execute(
                    sql: """
                    UPDATE chat_navigation_state
                    SET selected_conversation_id=NULL, updated_at=?
                    WHERE selected_conversation_id=?;
                    """,
                    bindings: [.real(now.timeIntervalSince1970), .text(cid)]
                )
                _ = try execute(sql: "DELETE FROM conversations WHERE id=?;", bindings: [.text(cid)])
            }

            _ = try execute(sql: "DELETE FROM bot_sidebar_order WHERE teammate_id=?;", bindings: [.text(tid)])
            _ = try execute(
                sql: "DELETE FROM app_metadata WHERE key=?;",
                bindings: [.text("bot_workspace_v1.\(tid)")]
            )
            // A bot deleted while still waiting to set itself up takes the mark with it.
            try writePendingSelfSetup(teammateID: id, placeholderName: nil)
            // The bot's own switches go with it (an archived bot keeps them).
            // GLOB, not LIKE: a teammate id holds no glob character.
            _ = try execute(
                sql: "DELETE FROM app_metadata WHERE key GLOB ?;",
                bindings: [.text("agentic_web_switch_v1.bot.\(tid).*")]
            )

            let assetID = try query(
                sql: "SELECT profile_asset_id FROM agent_appearances WHERE teammate_id=?;",
                bindings: [.text(tid)]
            ).first.flatMap { try? $0.optionalText("profile_asset_id") } ?? nil

            if keepsTeamHistory {
                try keepEmptiedRow(teammate, now: now)
            } else {
                let changes = try execute(
                    sql: "DELETE FROM teammates WHERE id=? AND profile_revision=?;",
                    bindings: [.text(tid), .integer(Int64(teammate.profile.revision))]
                )
                guard changes == 1 else { throw TeammateDeleteError.staleRevision }
            }

            if let assetID, !assetID.isEmpty {
                let stillUsed = try query(
                    sql: "SELECT 1 AS hit FROM agent_appearances WHERE profile_asset_id=? LIMIT 1;",
                    bindings: [.text(assetID)]
                )
                if stillUsed.isEmpty {
                    _ = try execute(
                        sql: "DELETE FROM profile_photo_assets WHERE id=?;",
                        bindings: [.text(assetID)]
                    )
                }
            }

            return teammate
        }
    }

    /// The bot's direct chats, naming the bot as ?1.
    private static let ownDirectChats = """
        SELECT c.id FROM conversations c
        INNER JOIN conversation_participants p
            ON p.conversation_id=c.id AND p.teammate_id=?1 AND p.left_at IS NULL
        WHERE c.kind='direct'
        """

    /// Whether the bot took part in a team chat: it wrote a message there, a
    /// handoff names it, or other bots' records are built on its words or its
    /// hops (a message of its started their run or fed their journal, or a
    /// handoff between them began in its chat, continues a hop it took part
    /// in, or reports through its run). Any other broken reference is a gap
    /// in Delete and fails as the error it is.
    private func hasTeamHistory(_ tid: String) throws -> Bool {
        let ownMessages = "SELECT id FROM messages WHERE author_teammate_id=?1"
        let ownHops = "SELECT id FROM handoffs WHERE sender_teammate_id=?1 OR receiver_teammate_id=?1"
        return try !query(sql: """
            SELECT 1 AS kept FROM messages m INNER JOIN conversations c ON c.id=m.conversation_id
            WHERE m.author_teammate_id=?1 AND c.kind!='direct'
            UNION ALL SELECT 1 FROM handoffs WHERE sender_teammate_id=?1 OR receiver_teammate_id=?1
            UNION ALL SELECT 1 FROM work_runs
            WHERE teammate_id!=?1 AND initiating_message_id IN (\(ownMessages))
            UNION ALL SELECT 1 FROM run_input_receipts i INNER JOIN work_runs r ON r.id=i.run_id
            WHERE r.teammate_id!=?1 AND i.message_id IN (\(ownMessages))
            UNION ALL SELECT 1 FROM run_journal_entries e INNER JOIN work_runs r ON r.id=e.run_id
            WHERE r.teammate_id!=?1 AND e.input_message_id IN (\(ownMessages))
            UNION ALL SELECT 1 FROM handoffs
            WHERE sender_teammate_id!=?1 AND receiver_teammate_id!=?1
              AND (original_user_message_id IN (SELECT id FROM messages WHERE conversation_id IN (\(Self.ownDirectChats)))
                   OR chain_id IN (\(ownHops)) OR parent_handoff_id IN (\(ownHops))
                   OR report_run_id IN (SELECT id FROM work_runs WHERE teammate_id=?1))
            LIMIT 1;
            """, bindings: [.text(tid)]).isEmpty
    }

    /// Every kept handoff to or from the bot that could still move ends the
    /// way Decline would end it: its card is drawn only
    /// for bots on the roster, so once the bot is gone nobody could send or
    /// decline it, and an open leg held its chain open for good, so the lead
    /// never got the chain's other results back. A staged or accepted leg
    /// ends, and a working one whose run has ended or is gone; a leg whose
    /// run still works finishes as it would, and a finished one stays.
    private func endOpenHandoffs(_ tid: String, now: Date) throws {
        let open = try handoffRows(whereClause: """
            (sender_teammate_id=?1 OR receiver_teammate_id=?1)
            AND (state IN ('staged','accepted') OR (state='working' AND (run_id IS NULL OR run_id NOT IN
                (SELECT id FROM work_runs WHERE state NOT IN ('succeeded','failed','interrupted')))))
            """, bindings: [.text(tid)])
        for var record in open {
            let previous = record.state
            // A leg never moves back in time, even on a clock set earlier.
            // The words say which end was deleted, by its role in the hop,
            // since its name is gone. A working leg to
            // it had been sent; a staged or accepted one had not.
            let userMessage: String
            if record.handoff.provenance.receiverID.persistedValue != tid {
                userMessage = "Not done: the bot that sent it was deleted."
            } else if previous == .working {
                userMessage = "Ended: the bot working on it was deleted before it reported. The lead can hand this off again."
            } else {
                userMessage = "Not done: the bot it was for was deleted. The lead can hand this off again."
            }
            try record.apply(.requireRecovery(HandoffRecovery(code: "bot-deleted", userMessage: userMessage,
                isRecoverable: false, occurredAt: max(now, record.handoff.lastTransitionAt))))
            try writeHandoffUpdate(record, expectedState: previous)
        }
    }

    /// What stays of a bot whose team history stays: its row, emptied of
    /// everything that was it (name, profile, seat, model, picture) and marked
    /// deleted, so its kept messages and handoffs still name an author, read
    /// as "Deleted bot". Its profile history goes, or the old name would
    /// survive in it. The row's cascades never run, so what they would have
    /// removed is removed here: its memberships, which also take it out of
    /// every team's roster and routing, and its other per-bot rows.
    private func keepEmptiedRow(_ teammate: Teammate, now: Date) throws {
        let tid = SQLiteBinding.text(teammate.id.persistedValue)
        for table in ["conversation_context_selections", "teammate_profile_revisions", "project_memberships",
                      "team_memberships", "conversation_participants", "capability_grants"] {
            _ = try execute(sql: "DELETE FROM \(table) WHERE teammate_id=?;", bindings: [tid])
        }
        let changes = try execute(sql: """
            UPDATE teammates SET display_name=?, title=NULL, role=?, detailed_instructions=NULL,
                seat_purview=NULL, seat_never=NULL, seat_interfaces=NULL, seat_escalate=NULL,
                profile_revision=profile_revision+1, lifecycle='archived', is_pinned=0, is_hidden=1,
                notification_preference='inherit', claude_model=NULL, claude_effort=NULL, claude_context_window=NULL,
                profile_written_by_hirer=NULL, updated_at=MAX(updated_at, ?)
            WHERE id=? AND profile_revision=?;
            """, bindings: [.text(DeletedTeammate.displayName), .text(DeletedTeammate.role),
                .real(now.timeIntervalSince1970), tid, .integer(Int64(teammate.profile.revision))])
        guard changes == 1 else { throw TeammateDeleteError.staleRevision }
        _ = try execute(sql: """
            UPDATE agent_appearances SET mode='creature', profile_asset_id=NULL, built_in_avatar_id=NULL,
                accessible_identity_description=?, revision=revision+1
            WHERE teammate_id=?;
            """, bindings: [.text(DeletedTeammate.displayName), tid])
        _ = try execute(sql: "INSERT INTO deleted_teammates(teammate_id,deleted_at) VALUES (?,?);",
                        bindings: [tid, .real(now.timeIntervalSince1970)])
    }

    private func buildInventory(id: TeammateID) throws -> TeammateDeleteInventory {
        guard let teammate = try teammateRows(whereClause: "t.id=? AND \(Self.notDeletedTeammate)",
                                              bindings: [.text(id.persistedValue)]).first else {
            throw TeammateDeleteError.notFound
        }
        let tid = id.persistedValue
        let conversations = try query(
            sql: """
            SELECT COUNT(*) AS n FROM conversations c
            INNER JOIN conversation_participants p
                ON p.conversation_id=c.id AND p.teammate_id=? AND p.left_at IS NULL
            WHERE c.kind='direct';
            """,
            bindings: [.text(tid)]
        ).first.map { try $0.integer("n") } ?? 0
        let memory = try query(
            sql: """
            SELECT COUNT(*) AS n FROM memory_documents
            WHERE author_teammate_id=? OR (scope_kind='teammate' AND scope_id=?);
            """,
            bindings: [.text(tid), .text(tid)]
        ).first.map { try $0.integer("n") } ?? 0
        let memberships = try query(
            sql: """
            SELECT COUNT(*) AS n FROM (
                SELECT 1 FROM team_memberships WHERE teammate_id=? AND revoked_at IS NULL
                UNION ALL
                SELECT 1 FROM project_memberships WHERE teammate_id=? AND revoked_at IS NULL
            );
            """,
            bindings: [.text(tid), .text(tid)]
        ).first.map { try $0.integer("n") } ?? 0
        let hasAsset = (try query(
            sql: "SELECT profile_asset_id FROM agent_appearances WHERE teammate_id=?;",
            bindings: [.text(tid)]
        ).first.flatMap { try? $0.optionalText("profile_asset_id") } ?? nil) != nil

        var home: String? = nil
        if let row = try query(
            sql: "SELECT value FROM app_metadata WHERE key=?;",
            bindings: [.text("bot_workspace_v1.\(tid)")]
        ).first,
           let text = try? row.text("value"),
           let data = text.data(using: .utf8),
           let record = try? JSONDecoder().decode(BotWorkspaceRecord.self, from: data) {
            home = record.homePath
        }

        var skills: String? = nil
        if let home {
            let homeURL = URL(fileURLWithPath: home)
            let name = homeURL.lastPathComponent
            // Bots/<name> lives under contentRoot/Bots; Skills/<name> is sibling of Bots.
            let skillsURL = homeURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Skills", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: skillsURL.path) {
                skills = skillsURL.path
            }
        }

        return TeammateDeleteInventory(
            displayName: teammate.profile.displayName,
            hasProfile: true,
            conversationCount: Int(conversations),
            memoryDocumentCount: Int(memory),
            membershipCount: Int(memberships),
            hasProfileAsset: hasAsset,
            botHomePath: home,
            skillsPath: skills,
            keepsTeamHistory: try hasTeamHistory(tid)
        )
    }
}
