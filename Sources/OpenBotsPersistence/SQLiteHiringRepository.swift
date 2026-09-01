import Foundation
import OpenBotsDomain

extension SQLiteStore: HiringDraftRepository {
    public func latestHiringDraft() async throws -> HiringDraftSnapshot? {
        guard let row = try query(
            sql: "SELECT id FROM hiring_drafts ORDER BY updated_at DESC, id LIMIT 1;"
        ).first else { return nil }
        return try loadHiringDraftSnapshot(id: parseID(HiringDraftID.self, row.text("id")))
    }

    @discardableResult
    public func createHiringDraft(
        _ snapshot: HiringDraftSnapshot
    ) async throws -> HiringDraftSnapshot {
        guard snapshot.draft.revision == 1 else {
            throw DomainValidationError.invalid(
                field: "hiring draft revision",
                reason: "an initial draft must start at revision one"
            )
        }
        return try transaction {
            if try hiringDraftRevision(id: snapshot.draft.id) != nil {
                throw RepositoryError.alreadyExists(
                    entity: "hiring draft",
                    id: snapshot.draft.id.persistedValue
                )
            }
            try insertHiringDraft(snapshot.draft)
            for turn in snapshot.turns {
                try insertHiringTurn(turn)
            }
            return snapshot
        }
    }

    @discardableResult
    public func reviseHiringDraft(
        _ draft: HiringDraft,
        expectedRevision: UInt64,
        appending turns: [HiringTurn]
    ) async throws -> HiringDraftSnapshot {
        try transaction {
            guard let current = try loadHiringDraftSnapshot(id: draft.id) else {
                throw RepositoryError.notFound(
                    entity: "hiring draft",
                    id: draft.id.persistedValue
                )
            }
            guard current.draft.revision == expectedRevision,
                  expectedRevision < UInt64.max,
                  draft.revision == expectedRevision + 1 else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: draft.id.persistedValue
                )
            }
            guard draft.createdAt == current.draft.createdAt,
                  draft.updatedAt >= current.draft.updatedAt else {
                throw DomainValidationError.invalid(
                    field: "hiring draft revision",
                    reason: "must preserve createdAt and move updatedAt forward"
                )
            }

            let combined = try HiringDraftSnapshot(
                draft: draft,
                turns: current.turns + turns
            )
            let changes = try updateHiringDraft(draft, expectedRevision: expectedRevision)
            guard changes == 1 else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: draft.id.persistedValue
                )
            }
            for turn in turns {
                try insertHiringTurn(turn)
            }
            return combined
        }
    }

    public func cancelHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64
    ) async throws {
        try transaction {
            guard let actualRevision = try hiringDraftRevision(id: id) else {
                throw RepositoryError.notFound(entity: "hiring draft", id: id.persistedValue)
            }
            guard actualRevision == expectedRevision else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: id.persistedValue
                )
            }
            let changes = try execute(
                sql: "DELETE FROM hiring_drafts WHERE id=? AND revision=?;",
                bindings: [
                    .text(id.persistedValue),
                    .integer(try checkedInt64(expectedRevision, field: "expected hiring draft revision"))
                ]
            )
            guard changes == 1 else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: id.persistedValue
                )
            }
        }
    }

    public func confirmHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64,
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws {
        try transaction {
            guard let snapshot = try loadHiringDraftSnapshot(id: id) else {
                throw RepositoryError.notFound(entity: "hiring draft", id: id.persistedValue)
            }
            guard snapshot.draft.revision == expectedRevision else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: id.persistedValue
                )
            }
            try validateHiringConfirmation(
                draft: snapshot.draft,
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: fixtureGreeting
            )

            // These graph helpers do not suspend. Every row, including removal
            // of the provisional draft, belongs to this one SQLite transaction.
            try insertTeammateGraph(teammate)
            try insertConversationGraph(conversation, participantIDs: [teammate.id])
            try placeNewBotAtTopOfSidebarOrder(teammate.id)
            if let fixtureGreeting {
                try appendMessageGraph(fixtureGreeting, expectedPreviousSequence: 0)
            }
            if selectConversation {
                let selectionChanges = try execute(
                    sql: """
                    UPDATE chat_navigation_state
                    SET selected_conversation_id=?, updated_at=?
                    WHERE singleton_id=1;
                    """,
                    bindings: [
                        .text(conversation.id.persistedValue),
                        .real(max(teammate.updatedAt, conversation.updatedAt).timeIntervalSince1970)
                    ]
                )
                guard selectionChanges == 1 else {
                    throw RepositoryError.unavailable(
                        reason: "The chat navigation singleton is missing."
                    )
                }
            }
            let draftChanges = try execute(
                sql: "DELETE FROM hiring_drafts WHERE id=? AND revision=?;",
                bindings: [
                    .text(id.persistedValue),
                    .integer(try checkedInt64(expectedRevision, field: "expected hiring draft revision"))
                ]
            )
            guard draftChanges == 1 else {
                throw RepositoryError.optimisticLockFailed(
                    entity: "hiring draft",
                    id: id.persistedValue
                )
            }
        }
    }

    private func loadHiringDraftSnapshot(id: HiringDraftID) throws -> HiringDraftSnapshot? {
        guard let draftRow = try query(
            sql: "SELECT * FROM hiring_drafts WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        let draft = try decodeHiringDraft(draftRow)
        let turns = try query(
            sql: "SELECT * FROM hiring_turns WHERE draft_id=? ORDER BY sequence;",
            bindings: [.text(id.persistedValue)]
        ).map(decodeHiringTurn)
        return try HiringDraftSnapshot(draft: draft, turns: turns)
    }

    private func hiringDraftRevision(id: HiringDraftID) throws -> UInt64? {
        guard let row = try query(
            sql: "SELECT revision FROM hiring_drafts WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        return try checkedUInt64(row.integer("revision"), field: "hiring draft revision")
    }

    private func insertHiringDraft(_ draft: HiringDraft) throws {
        _ = try execute(
            sql: """
            INSERT INTO hiring_drafts(
                id,phase,display_name,role,responsibilities,working_style,skills,permission_intent,
                project_placement,team_placement,revision,created_at,updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            bindings: try hiringDraftBindings(draft, includingID: true)
        )
    }

    private func updateHiringDraft(
        _ draft: HiringDraft,
        expectedRevision: UInt64
    ) throws -> Int32 {
        try execute(
            sql: """
            UPDATE hiring_drafts SET
                phase=?,display_name=?,role=?,responsibilities=?,working_style=?,skills=?,permission_intent=?,
                project_placement=?,team_placement=?,revision=?,created_at=?,updated_at=?
            WHERE id=? AND revision=?;
            """,
            bindings: try hiringDraftBindings(draft, includingID: false) + [
                .text(draft.id.persistedValue),
                .integer(try checkedInt64(expectedRevision, field: "expected hiring draft revision"))
            ]
        )
    }

    private func hiringDraftBindings(
        _ draft: HiringDraft,
        includingID: Bool
    ) throws -> [SQLiteBinding] {
        let values: [SQLiteBinding] = [
            .text(draft.phase.rawValue),
            draft.displayName.map(SQLiteBinding.text) ?? .null,
            draft.role.map(SQLiteBinding.text) ?? .null,
            draft.responsibilities.map(SQLiteBinding.text) ?? .null,
            draft.workingStyle.map(SQLiteBinding.text) ?? .null,
            draft.skills.map(SQLiteBinding.text) ?? .null,
            draft.permissionIntent.map(SQLiteBinding.text) ?? .null,
            draft.projectPlacement.map(SQLiteBinding.text) ?? .null,
            draft.teamPlacement.map(SQLiteBinding.text) ?? .null,
            .integer(try checkedInt64(draft.revision, field: "hiring draft revision")),
            .real(draft.createdAt.timeIntervalSince1970),
            .real(draft.updatedAt.timeIntervalSince1970)
        ]
        return includingID ? [.text(draft.id.persistedValue)] + values : values
    }

    private func insertHiringTurn(_ turn: HiringTurn) throws {
        _ = try execute(
            sql: """
            INSERT INTO hiring_turns(id,draft_id,sequence,author,text,created_at)
            VALUES (?,?,?,?,?,?);
            """,
            bindings: [
                .text(turn.id.persistedValue),
                .text(turn.draftID.persistedValue),
                .integer(turn.sequence),
                .text(turn.author.rawValue),
                .text(turn.text),
                .real(turn.createdAt.timeIntervalSince1970)
            ]
        )
    }

    private func decodeHiringDraft(_ row: SQLiteRow) throws -> HiringDraft {
        guard let phase = HiringDraftPhase(rawValue: try row.text("phase")) else {
            throw SQLiteStoreError.invalidRow(reason: "unknown hiring draft phase")
        }
        return try HiringDraft(
            id: parseID(HiringDraftID.self, row.text("id")),
            phase: phase,
            displayName: row.optionalText("display_name"),
            role: row.optionalText("role"),
            responsibilities: row.optionalText("responsibilities"),
            workingStyle: row.optionalText("working_style"),
            skills: row.optionalText("skills"),
            permissionIntent: row.optionalText("permission_intent"),
            projectPlacement: row.optionalText("project_placement"),
            teamPlacement: row.optionalText("team_placement"),
            revision: try checkedUInt64(row.integer("revision"), field: "hiring draft revision"),
            createdAt: Date(timeIntervalSince1970: row.real("created_at")),
            updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
        )
    }

    private func decodeHiringTurn(_ row: SQLiteRow) throws -> HiringTurn {
        guard let author = HiringTurnAuthor(rawValue: try row.text("author")) else {
            throw SQLiteStoreError.invalidRow(reason: "unknown hiring turn author")
        }
        return try HiringTurn(
            id: parseID(HiringTurnID.self, row.text("id")),
            draftID: parseID(HiringDraftID.self, row.text("draft_id")),
            sequence: row.integer("sequence"),
            author: author,
            text: row.text("text"),
            createdAt: Date(timeIntervalSince1970: row.real("created_at"))
        )
    }

    private func validateHiringConfirmation(
        draft: HiringDraft,
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?
    ) throws {
        guard draft.phase == .readyForReview else {
            throw DomainValidationError.invalid(
                field: "hiring draft phase",
                reason: "must be ready for review before confirmation"
            )
        }
        guard teammate.profile.displayName == draft.displayName,
              teammate.profile.role == draft.role else {
            throw DomainValidationError.invalid(
                field: "confirmed teammate profile",
                reason: "name and role must match the reviewed hiring draft"
            )
        }
        guard case let .direct(teammateID) = conversation.kind,
              teammateID == teammate.id else {
            throw DomainValidationError.invalid(
                field: "direct conversation",
                reason: "must reference the teammate being provisioned"
            )
        }
        guard let fixtureGreeting else { return }
        guard fixtureGreeting.conversationID == conversation.id else {
            throw DomainValidationError.invalid(
                field: "fixture greeting conversation",
                reason: "must match the direct conversation being provisioned"
            )
        }
        guard fixtureGreeting.author == .teammate(teammate.id) else {
            throw DomainValidationError.invalid(
                field: "fixture greeting author",
                reason: "must be the teammate being provisioned"
            )
        }
        guard fixtureGreeting.sequence == 1 else {
            throw DomainValidationError.invalid(
                field: "fixture greeting sequence",
                reason: "must be the first message in the direct conversation"
            )
        }
    }
}
