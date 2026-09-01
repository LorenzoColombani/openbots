import OpenBotsDomain

extension SQLiteStore: ConversationContextRepository {
    public func loadContext(
        conversationID: ConversationID
    ) async throws -> ConversationContextSelection {
        // One actor-isolated transaction prevents a second connection changing
        // membership between the identity check and returning the selection.
        try transaction {
            let teammateID = try contextTeammate(conversationID: conversationID)
            guard let row = try contextRow(conversationID: conversationID) else {
                return ConversationContextSelection(
                    conversationID: conversationID, teammateID: teammateID
                )
            }
            let revision = try contextRevision(row)
            guard try row.text("teammate_id") == teammateID.persistedValue else {
                throw ConversationContextError.teammateMismatch
            }
            let projectID = try row.optionalText("project_id").map { try parseID(ProjectID.self, $0) }
            let teamID = try row.optionalText("team_id").map { try parseID(TeamID.self, $0) }
            do {
                try validateContextScope(teammateID: teammateID, projectID: projectID, teamID: teamID)
            } catch ConversationContextError.projectUnavailable {
                throw ConversationContextError.selectionInvalidated(revision: revision)
            } catch ConversationContextError.teamUnavailable {
                throw ConversationContextError.selectionInvalidated(revision: revision)
            }
            return ConversationContextSelection(
                conversationID: conversationID, teammateID: teammateID,
                projectID: projectID, teamID: teamID, revision: revision
            )
        }
    }

    public func saveContext(
        _ selection: ConversationContextSelection
    ) async throws -> ConversationContextSelection {
        guard selection.revision < UInt64(Int64.max) else {
            throw ConversationContextError.invalidRevision
        }
        return try transaction {
            let teammateID = try contextTeammate(conversationID: selection.conversationID)
            guard teammateID == selection.teammateID else {
                throw ConversationContextError.teammateMismatch
            }
            let existing = try contextRow(conversationID: selection.conversationID)
            let currentRevision = try existing.map(contextRevision) ?? 0
            guard currentRevision == selection.revision else {
                throw ConversationContextError.staleRevision
            }
            if let existing,
               try existing.text("teammate_id") != teammateID.persistedValue {
                throw ConversationContextError.teammateMismatch
            }
            // Check the requested replacement, not the old scope: a revoked
            // selection remains recoverable by an explicit clear/replacement.
            try validateContextScope(
                teammateID: teammateID, projectID: selection.projectID, teamID: selection.teamID
            )
            let nextRevision = selection.revision + 1
            _ = try execute(
                sql: """
                INSERT INTO conversation_context_selections
                    (conversation_id,teammate_id,project_id,team_id,revision)
                VALUES (?,?,?,?,?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    project_id=excluded.project_id, team_id=excluded.team_id, revision=excluded.revision;
                """,
                bindings: [
                    .text(selection.conversationID.persistedValue), .text(teammateID.persistedValue),
                    selection.projectID.map { .text($0.persistedValue) } ?? .null,
                    selection.teamID.map { .text($0.persistedValue) } ?? .null,
                    .integer(Int64(nextRevision)),
                ]
            )
            return ConversationContextSelection(
                conversationID: selection.conversationID, teammateID: teammateID,
                projectID: selection.projectID, teamID: selection.teamID, revision: nextRevision
            )
        }
    }

    private func contextTeammate(conversationID: ConversationID) throws -> TeammateID {
        guard let row = try query(
            sql: """
            SELECT c.kind, c.subject_id, c.lifecycle, t.lifecycle AS teammate_lifecycle,
                   EXISTS(SELECT 1 FROM conversation_participants p
                          WHERE p.conversation_id=c.id AND p.teammate_id=c.subject_id
                          AND p.left_at IS NULL) AS is_participant
            FROM conversations c LEFT JOIN teammates t ON t.id=c.subject_id
            WHERE c.id=?;
            """,
            bindings: [.text(conversationID.persistedValue)]
        ).first else { throw ConversationContextError.conversationNotFound }
        guard try row.text("kind") == "direct",
              try row.text("lifecycle") == "active",
              try row.integer("is_participant") == 1 else {
            throw ConversationContextError.conversationUnavailable
        }
        guard try row.optionalText("teammate_lifecycle") == "active" else {
            throw ConversationContextError.teammateUnavailable
        }
        return try parseID(TeammateID.self, row.text("subject_id"))
    }

    private func validateContextScope(
        teammateID: TeammateID, projectID: ProjectID?, teamID: TeamID?
    ) throws {
        if let projectID {
            let rows = try query(
                sql: """
                SELECT 1 AS allowed FROM projects p
                WHERE p.id=? AND p.lifecycle='active'
                AND EXISTS(SELECT 1 FROM project_memberships m
                           WHERE m.project_id=p.id AND m.teammate_id=? AND m.revoked_at IS NULL);
                """,
                bindings: [.text(projectID.persistedValue), .text(teammateID.persistedValue)]
            )
            guard !rows.isEmpty else { throw ConversationContextError.projectUnavailable }
        }
        if let teamID {
            let rows = try query(
                sql: """
                SELECT 1 AS allowed FROM teams t
                WHERE t.id=? AND t.lifecycle='active'
                AND EXISTS(SELECT 1 FROM team_memberships m
                           WHERE m.team_id=t.id AND m.teammate_id=? AND m.revoked_at IS NULL);
                """,
                bindings: [.text(teamID.persistedValue), .text(teammateID.persistedValue)]
            )
            guard !rows.isEmpty else { throw ConversationContextError.teamUnavailable }
        }
    }

    private func contextRow(conversationID: ConversationID) throws -> SQLiteRow? {
        try query(
            sql: "SELECT teammate_id,project_id,team_id,revision FROM conversation_context_selections WHERE conversation_id=?;",
            bindings: [.text(conversationID.persistedValue)]
        ).first
    }

    private func contextRevision(_ row: SQLiteRow) throws -> UInt64 {
        let revision = try row.integer("revision")
        guard revision > 0 else { throw ConversationContextError.invalidRevision }
        return UInt64(revision)
    }
}
