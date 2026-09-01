import Foundation
import OpenBotsDomain

extension SQLiteStore: TeammateRepository {
    public func teammate(id: TeammateID) async throws -> Teammate? {
        try teammateRows(whereClause: "t.id=?", bindings: [.text(id.persistedValue)]).first
    }

    public func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        let condition = includingArchived ? "1=1" : "t.lifecycle!='archived'"
        return try teammateRows(whereClause: condition, bindings: [])
    }

    public func insert(_ teammate: Teammate) async throws {
        try transaction {
            try insertTeammateGraph(teammate)
        }
    }

    public func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        guard teammate.profile.revision >= expectedProfileRevision,
              teammate.profile.revision - expectedProfileRevision <= 1 else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
        }
        try transaction {
            let changes = try execute(
                sql: """
                UPDATE teammates SET display_name=?, title=?, role=?, detailed_instructions=?, profile_revision=?,
                    lifecycle=?, is_pinned=?, is_hidden=?, notification_preference=?, claude_model=?, claude_effort=?, claude_context_window=?, updated_at=?
                WHERE id=? AND profile_revision=?;
                """,
                bindings: [
                    .text(teammate.profile.displayName),
                    teammate.profile.title.map(SQLiteBinding.text) ?? .null,
                    .text(teammate.profile.role),
                    teammate.profile.detailedInstructions.map(SQLiteBinding.text) ?? .null,
                    .integer(try checkedInt64(teammate.profile.revision, field: "profile revision")),
                    .text(teammate.lifecycle.rawValue),
                    .integer(teammate.isPinned ? 1 : 0),
                    .integer(teammate.isHidden ? 1 : 0),
                    .text(teammate.notificationPreference.rawValue),
                    teammate.claudeModel.map(SQLiteBinding.text) ?? .null,
                    teammate.claudeEffort.map(SQLiteBinding.text) ?? .null,
                    teammate.claudeContextWindow.map(SQLiteBinding.text) ?? .null,
                    .real(teammate.updatedAt.timeIntervalSince1970),
                    .text(teammate.id.persistedValue),
                    .integer(try checkedInt64(expectedProfileRevision, field: "expected profile revision"))
                ]
            )
            guard changes == 1 else {
                throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
            }
            if teammate.profile.revision > expectedProfileRevision {
                try insertProfileRevision(teammate)
            }
            _ = try execute(
                sql: """
                UPDATE agent_appearances SET mode=?, grammar_version=?, deterministic_seed=?, silhouette=?,
                    palette_token=?, eye_dialect=?, non_color_identity_cue=?, accessible_identity_description=?,
                    profile_asset_id=?, built_in_avatar_id=?, revision=? WHERE teammate_id=?;
                """,
                bindings: try appearanceBindings(teammate)
            )
        }
    }

    /// Inserts every row that makes one teammate durable. The caller owns the
    /// transaction so a larger aggregate can include this graph atomically.
    func insertTeammateGraph(_ teammate: Teammate) throws {
        try insertTeammateRow(teammate)
        try insertProfileRevision(teammate)
        try insertAppearance(teammate)
    }

    func teammateRows(
        whereClause: String,
        bindings: [SQLiteBinding]
    ) throws -> [Teammate] {
        try query(
            sql: """
            SELECT t.id, t.display_name, t.title, t.role, t.detailed_instructions, t.profile_revision,
                   t.lifecycle, t.is_pinned, t.is_hidden, t.notification_preference, t.claude_model, t.claude_effort, t.claude_context_window, t.created_at, t.updated_at,
                   a.mode, a.grammar_version, a.deterministic_seed, a.silhouette, a.palette_token,
                   a.eye_dialect, a.non_color_identity_cue, a.accessible_identity_description,
                   a.profile_asset_id, a.built_in_avatar_id, a.revision AS appearance_revision
            FROM teammates t JOIN agent_appearances a ON a.teammate_id=t.id
            WHERE \(whereClause)
            ORDER BY t.is_pinned DESC, t.updated_at DESC, t.id;
            """,
            bindings: bindings
        ).map(decodeTeammate)
    }

    func decodeTeammate(_ row: SQLiteRow) throws -> Teammate {
        let profile = try TeammateProfile(
            displayName: row.text("display_name"),
            title: row.optionalText("title"),
            role: row.text("role"),
            detailedInstructions: row.optionalText("detailed_instructions"),
            revision: try checkedUInt64(row.integer("profile_revision"), field: "profile revision")
        )
        guard let mode = AppearanceMode(rawValue: try row.text("mode")),
              let lifecycle = TeammateLifecycle(rawValue: try row.text("lifecycle")),
              let notification = NotificationPreference(rawValue: try row.text("notification_preference")),
              let seed = UInt64(try row.text("deterministic_seed")) else {
            throw SQLiteStoreError.invalidRow(reason: "teammate enum or seed is invalid")
        }
        let assetID = try row.optionalText("profile_asset_id").map { try parseID(ProfileAssetID.self, $0) }
        let appearance = try AgentAppearance(
            mode: mode,
            grammarVersion: try checkedUInt16(row.integer("grammar_version"), field: "grammar version"),
            deterministicSeed: seed,
            silhouette: row.text("silhouette"),
            paletteToken: row.text("palette_token"),
            eyeDialect: row.text("eye_dialect"),
            nonColorIdentityCue: row.text("non_color_identity_cue"),
            accessibleIdentityDescription: row.text("accessible_identity_description"),
            profileAssetID: assetID,
            builtInAvatarID: row.optionalText("built_in_avatar_id"),
            revision: try checkedUInt64(row.integer("appearance_revision"), field: "appearance revision")
        )
        return try Teammate(
            id: parseID(TeammateID.self, row.text("id")),
            profile: profile,
            appearance: appearance,
            lifecycle: lifecycle,
            isPinned: row.integer("is_pinned") == 1,
            isHidden: row.integer("is_hidden") == 1,
            notificationPreference: notification,
            claudeModel: row.optionalText("claude_model"),
            claudeEffort: row.optionalText("claude_effort"),
            claudeContextWindow: row.optionalText("claude_context_window"),
            createdAt: Date(timeIntervalSince1970: row.real("created_at")),
            updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
        )
    }

    private func insertTeammateRow(_ teammate: Teammate) throws {
        _ = try execute(
            sql: """
            INSERT INTO teammates(id,display_name,title,role,detailed_instructions,profile_revision,lifecycle,
                is_pinned,is_hidden,notification_preference,claude_model,claude_effort,claude_context_window,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            bindings: [
                .text(teammate.id.persistedValue), .text(teammate.profile.displayName),
                teammate.profile.title.map(SQLiteBinding.text) ?? .null, .text(teammate.profile.role),
                teammate.profile.detailedInstructions.map(SQLiteBinding.text) ?? .null,
                .integer(try checkedInt64(teammate.profile.revision, field: "profile revision")),
                .text(teammate.lifecycle.rawValue), .integer(teammate.isPinned ? 1 : 0),
                .integer(teammate.isHidden ? 1 : 0), .text(teammate.notificationPreference.rawValue),
                teammate.claudeModel.map(SQLiteBinding.text) ?? .null,
                teammate.claudeEffort.map(SQLiteBinding.text) ?? .null,
                teammate.claudeContextWindow.map(SQLiteBinding.text) ?? .null,
                .real(teammate.createdAt.timeIntervalSince1970), .real(teammate.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    func insertProfileRevision(_ teammate: Teammate) throws {
        _ = try execute(
            sql: """
            INSERT INTO teammate_profile_revisions(teammate_id,revision,display_name,title,role,detailed_instructions,claude_model,claude_effort,claude_context_window,recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """,
            bindings: [
                .text(teammate.id.persistedValue),
                .integer(try checkedInt64(teammate.profile.revision, field: "profile revision")),
                .text(teammate.profile.displayName), teammate.profile.title.map(SQLiteBinding.text) ?? .null,
                .text(teammate.profile.role),
                teammate.profile.detailedInstructions.map(SQLiteBinding.text) ?? .null,
                teammate.claudeModel.map(SQLiteBinding.text) ?? .null,
                teammate.claudeEffort.map(SQLiteBinding.text) ?? .null,
                teammate.claudeContextWindow.map(SQLiteBinding.text) ?? .null,
                .real(teammate.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func insertAppearance(_ teammate: Teammate) throws {
        _ = try execute(
            sql: """
            INSERT INTO agent_appearances(teammate_id,mode,grammar_version,deterministic_seed,silhouette,
                palette_token,eye_dialect,non_color_identity_cue,accessible_identity_description,
                profile_asset_id,built_in_avatar_id,revision) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """,
            bindings: [.text(teammate.id.persistedValue)] + Array(try appearanceBindings(teammate).dropLast())
        )
    }

    private func appearanceBindings(_ teammate: Teammate) throws -> [SQLiteBinding] {
        let appearance = teammate.appearance
        return [
            .text(appearance.mode.rawValue), .integer(Int64(appearance.grammarVersion)),
            .text(String(appearance.deterministicSeed)), .text(appearance.silhouette),
            .text(appearance.paletteToken), .text(appearance.eyeDialect),
            .text(appearance.nonColorIdentityCue), .text(appearance.accessibleIdentityDescription),
            appearance.profileAssetID.map { .text($0.persistedValue) } ?? .null,
            appearance.builtInAvatarID.map(SQLiteBinding.text) ?? .null,
            .integer(try checkedInt64(appearance.revision, field: "appearance revision")),
            .text(teammate.id.persistedValue)
        ]
    }
}

func parseID<T: OpenBotsIdentifier>(_ type: T.Type, _ value: String) throws -> T {
    guard let uuid = UUID(uuidString: value) else {
        throw SQLiteStoreError.invalidRow(reason: "\(T.self) contains an invalid UUID")
    }
    return T(uuid)
}

func checkedUInt64(_ value: Int64, field: String) throws -> UInt64 {
    guard value >= 0 else { throw SQLiteStoreError.invalidRow(reason: "\(field) is negative") }
    return UInt64(value)
}

func checkedUInt16(_ value: Int64, field: String) throws -> UInt16 {
    guard let checked = UInt16(exactly: value) else {
        throw SQLiteStoreError.invalidRow(reason: "\(field) exceeds UInt16")
    }
    return checked
}

func checkedInt64(_ value: UInt64, field: String) throws -> Int64 {
    guard let checked = Int64(exactly: value) else {
        throw SQLiteStoreError.invalidRow(reason: "\(field) exceeds SQLite INTEGER")
    }
    return checked
}
