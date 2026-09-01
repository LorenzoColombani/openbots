import Foundation
import OpenBotsDomain

extension SQLiteStore: TeamRepository {
    public func team(id: TeamID) async throws -> Team? {
        try teamRows(whereClause: "id=?", bindings: [.text(id.persistedValue)]).first
    }

    public func listTeams(includingArchived: Bool) async throws -> [Team] {
        try teamRows(
            whereClause: includingArchived ? "1=1" : "lifecycle='active'",
            bindings: []
        )
    }

    public func insert(_ team: Team) async throws {
        try transaction {
            let orderedMemberIDs = team.memberIDs.sorted {
                $0.persistedValue < $1.persistedValue
            }
            // The directory service validates first for useful domain errors,
            // then SQLite revalidates in the same transaction that publishes
            // the aggregate. This prevents an archive/delete race between the
            // application-service check and the first team write.
            for teammateID in orderedMemberIDs {
                guard let row = try query(
                    sql: "SELECT lifecycle FROM teammates WHERE id=?;",
                    bindings: [.text(teammateID.persistedValue)]
                ).first else {
                    throw RepositoryError.notFound(
                        entity: "teammate",
                        id: teammateID.persistedValue
                    )
                }
                guard try row.text("lifecycle") == TeammateLifecycle.active.rawValue else {
                    throw RepositoryError.unavailable(
                        reason: "Team members must be active teammates."
                    )
                }
            }
            _ = try execute(
                sql: """
                INSERT INTO teams(id,name,summary,lead_teammate_id,lifecycle,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?);
                """,
                bindings: [
                    .text(team.id.persistedValue), .text(team.name),
                    team.summary.map(SQLiteBinding.text) ?? .null,
                    .text(team.leadID.persistedValue), .text(team.lifecycle.rawValue),
                    .real(team.createdAt.timeIntervalSince1970), .real(team.updatedAt.timeIntervalSince1970)
                ]
            )
            for teammateID in orderedMemberIDs {
                _ = try execute(
                    sql: "INSERT INTO team_memberships(team_id,teammate_id,joined_at,revoked_at) VALUES (?,?,?,NULL);",
                    bindings: [
                        .text(team.id.persistedValue), .text(teammateID.persistedValue),
                        .real(team.createdAt.timeIntervalSince1970)
                    ]
                )
            }
        }
    }

    public func update(_ team: Team) async throws {
        try transaction {
            let existingRows = try query(
                sql: "SELECT teammate_id FROM team_memberships WHERE team_id=? AND revoked_at IS NULL;",
                bindings: [.text(team.id.persistedValue)]
            )
            let existing = try Set(existingRows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
            let changes = try execute(
                sql: "UPDATE teams SET name=?,summary=?,lead_teammate_id=?,lifecycle=?,updated_at=? WHERE id=?;",
                bindings: [
                    .text(team.name), team.summary.map(SQLiteBinding.text) ?? .null,
                    .text(team.leadID.persistedValue), .text(team.lifecycle.rawValue),
                    .real(team.updatedAt.timeIntervalSince1970), .text(team.id.persistedValue)
                ]
            )
            guard changes == 1 else {
                throw RepositoryError.notFound(entity: "team", id: team.id.persistedValue)
            }

            for teammateID in existing.subtracting(team.memberIDs) {
                _ = try execute(
                    sql: "UPDATE team_memberships SET revoked_at=? WHERE team_id=? AND teammate_id=? AND revoked_at IS NULL;",
                    bindings: [
                        .real(team.updatedAt.timeIntervalSince1970), .text(team.id.persistedValue),
                        .text(teammateID.persistedValue)
                    ]
                )
            }
            for teammateID in team.memberIDs.subtracting(existing) {
                _ = try execute(
                    sql: "INSERT INTO team_memberships(team_id,teammate_id,joined_at,revoked_at) VALUES (?,?,?,NULL);",
                    bindings: [
                        .text(team.id.persistedValue), .text(teammateID.persistedValue),
                        .real(team.updatedAt.timeIntervalSince1970)
                    ]
                )
            }
        }
    }

    private func teamRows(whereClause: String, bindings: [SQLiteBinding]) throws -> [Team] {
        let rows = try query(
            sql: "SELECT * FROM teams WHERE \(whereClause) ORDER BY updated_at DESC,id;",
            bindings: bindings
        )
        return try rows.map { row in
            let teamID = try parseID(TeamID.self, row.text("id"))
            let memberRows = try query(
                sql: "SELECT teammate_id FROM team_memberships WHERE team_id=? AND revoked_at IS NULL;",
                bindings: [.text(teamID.persistedValue)]
            )
            let members = try Set(memberRows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
            guard let lifecycle = DurableEntityLifecycle(rawValue: try row.text("lifecycle")) else {
                throw SQLiteStoreError.invalidRow(reason: "unknown team lifecycle")
            }
            return try Team(
                id: teamID,
                name: row.text("name"),
                summary: row.optionalText("summary"),
                leadID: parseID(TeammateID.self, row.text("lead_teammate_id")),
                memberIDs: members,
                lifecycle: lifecycle,
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
            )
        }
    }
}

extension SQLiteStore: CapabilityGrantRepository {
    public func activeGrants(teammateID: TeammateID) async throws -> [CapabilityGrant] {
        try query(
            sql: "SELECT * FROM capability_grants WHERE teammate_id=? AND status='active' ORDER BY granted_at,id;",
            bindings: [.text(teammateID.persistedValue)]
        ).map(decodeCapabilityGrant)
    }

    public func insert(_ grant: CapabilityGrant) async throws {
        guard grant.status == .active, grant.revokedAt == nil else {
            throw DomainValidationError.invalid(
                field: "capability grant insertion",
                reason: "new grants must begin active"
            )
        }
        _ = try execute(
            sql: """
            INSERT INTO capability_grants(id,teammate_id,capability,scope_json,status,granted_at,revoked_at)
            VALUES (?,?,?,?,?,?,NULL);
            """,
            bindings: [
                .text(grant.id.persistedValue), .text(grant.teammateID.persistedValue),
                .text(grant.capability.rawValue), .text(try encodeJSON(grant.scope)),
                .text(grant.status.rawValue), .real(grant.grantedAt.timeIntervalSince1970)
            ]
        )
    }

    public func update(_ grant: CapabilityGrant) async throws {
        guard grant.status == .revoked, let revokedAt = grant.revokedAt else {
            throw LifecycleTransitionError.illegalTransition(
                entity: "capability grant",
                state: grant.status.rawValue,
                event: "persist update"
            )
        }
        let changes = try execute(
            sql: """
            UPDATE capability_grants SET status='revoked',revoked_at=?
            WHERE id=? AND teammate_id=? AND status='active' AND capability=? AND scope_json=?;
            """,
            bindings: [
                .real(revokedAt.timeIntervalSince1970), .text(grant.id.persistedValue),
                .text(grant.teammateID.persistedValue), .text(grant.capability.rawValue),
                .text(try encodeJSON(grant.scope))
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.optimisticLockFailed(entity: "capability grant", id: grant.id.persistedValue)
        }
    }

    private func decodeCapabilityGrant(_ row: SQLiteRow) throws -> CapabilityGrant {
        guard let capability = CapabilityClass(rawValue: try row.text("capability")),
              let status = CapabilityGrantStatus(rawValue: try row.text("status")) else {
            throw SQLiteStoreError.invalidRow(reason: "capability grant enum is invalid")
        }
        return try CapabilityGrant(
            rehydrating: parseID(CapabilityGrantID.self, row.text("id")),
            teammateID: parseID(TeammateID.self, row.text("teammate_id")),
            capability: capability,
            scope: decodeJSON(CapabilityScope.self, row.text("scope_json")),
            status: status,
            grantedAt: Date(timeIntervalSince1970: row.real("granted_at")),
            revokedAt: try row.optionalReal("revoked_at").map(Date.init(timeIntervalSince1970:))
        )
    }
}

extension SQLiteStore: ApprovalRepository {
    public func approval(id: ApprovalID) async throws -> ApprovalRequest? {
        guard let row = try query(
            sql: "SELECT * FROM approvals WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        return try decodeApproval(row)
    }

    public func insert(_ approval: ApprovalRequest) async throws {
        guard approval.state == .pending, approval.resolvedAt == nil else {
            throw DomainValidationError.invalid(
                field: "approval insertion",
                reason: "new approvals must begin pending"
            )
        }
        try transaction {
            guard try !query(sql: "SELECT 1 AS active FROM teammates WHERE id=? AND lifecycle='active';",
                             bindings: [.text(approval.teammateID.persistedValue)]).isEmpty else {
                throw TeammateArchiveError.invalidTransition
            }
            _ = try execute(
                sql: """
                INSERT INTO approvals(id,teammate_id,conversation_id,action,exact_target_summary,
                    consequence_summary,fingerprint,state,requested_at,resolved_at)
                VALUES (?,?,?,?,?,?,?,?,?,NULL);
                """,
                bindings: [
                    .text(approval.id.persistedValue), .text(approval.teammateID.persistedValue),
                    .text(approval.conversationID.persistedValue), .text(approval.action.rawValue),
                    .text(approval.exactTargetSummary), .text(approval.consequenceSummary),
                    .text(approval.fingerprint.value), .text(approval.state.rawValue),
                    .real(approval.requestedAt.timeIntervalSince1970)
                ]
            )
        }
    }

    public func update(_ approval: ApprovalRequest, expectedState: ApprovalState) async throws {
        guard isLegalApprovalTransition(from: expectedState, to: approval.state) else {
            throw LifecycleTransitionError.illegalTransition(
                entity: "approval",
                state: expectedState.rawValue,
                event: approval.state.rawValue
            )
        }
        let changes = try execute(
            sql: """
            UPDATE approvals SET state=?,resolved_at=?
            WHERE id=? AND teammate_id=? AND conversation_id=? AND action=? AND fingerprint=? AND state=?;
            """,
            bindings: [
                .text(approval.state.rawValue),
                approval.resolvedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(approval.id.persistedValue), .text(approval.teammateID.persistedValue),
                .text(approval.conversationID.persistedValue), .text(approval.action.rawValue),
                .text(approval.fingerprint.value), .text(expectedState.rawValue)
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.optimisticLockFailed(entity: "approval", id: approval.id.persistedValue)
        }
    }

    private func decodeApproval(_ row: SQLiteRow) throws -> ApprovalRequest {
        guard let action = ConsequentialActionKind(rawValue: try row.text("action")),
              let state = ApprovalState(rawValue: try row.text("state")) else {
            throw SQLiteStoreError.invalidRow(reason: "approval enum is invalid")
        }
        return try ApprovalRequest(
            rehydrating: parseID(ApprovalID.self, row.text("id")),
            teammateID: parseID(TeammateID.self, row.text("teammate_id")),
            conversationID: parseID(ConversationID.self, row.text("conversation_id")),
            action: action,
            exactTargetSummary: row.text("exact_target_summary"),
            consequenceSummary: row.text("consequence_summary"),
            fingerprint: ApprovalFingerprint(row.text("fingerprint")),
            state: state,
            requestedAt: Date(timeIntervalSince1970: row.real("requested_at")),
            resolvedAt: try row.optionalReal("resolved_at").map(Date.init(timeIntervalSince1970:))
        )
    }

    private func isLegalApprovalTransition(from: ApprovalState, to: ApprovalState) -> Bool {
        switch (from, to) {
        case (.pending, .approved), (.pending, .denied), (.pending, .expired),
             (.approved, .executing), (.executing, .succeeded), (.executing, .failed):
            true
        default:
            false
        }
    }
}

private func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decodeJSON<Value: Decodable>(_ type: Value.Type, _ value: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(value.utf8))
}
