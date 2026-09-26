import Foundation
import OpenBotsDomain

extension SQLiteStore: TeamProvisioningRepository, TeamConversationRepository {
    public func provisionTeam(_ team: Team, conversation: Conversation, selectConversation: Bool) async throws {
        guard conversation.kind == .team(teamID: team.id) else {
            throw DomainValidationError.invalid(
                field: "team conversation",
                reason: "must reference the team being provisioned"
            )
        }
        guard team.lifecycle == .active, conversation.lifecycle == .active else {
            throw DomainValidationError.invalid(
                field: "team provisioning",
                reason: "a new team and its conversation must be active"
            )
        }
        try transaction {
            try insertTeamGraph(team)
            try insertConversationGraph(conversation, participantIDs: team.memberIDs)
            if selectConversation {
                try writeSelectedConversationID(conversation.id, updatedAt: conversation.createdAt)
            }
        }
    }

    public func updateTeam(_ team: Team, conversation: Conversation, expectedUpdatedAt: Date) async throws {
        guard conversation.kind == .team(teamID: team.id) else {
            throw DomainValidationError.invalid(
                field: "team conversation",
                reason: "must reference the team being edited"
            )
        }
        guard team.lifecycle == .active, conversation.lifecycle == .active else {
            throw DomainValidationError.invalid(
                field: "team edit",
                reason: "an edited team and its conversation must stay active"
            )
        }
        try transaction {
            let joiningRows = try query(
                sql: "SELECT teammate_id FROM team_memberships WHERE team_id=? AND revoked_at IS NULL;",
                bindings: [.text(team.id.persistedValue)]
            )
            let held = try Set(joiningRows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
            // Only a member joining now must be active. One the team already
            // holds that has been archived since stays: archiving a bot does
            // not evict it from its teams, and an edit must not do so either.
            try requireActiveTeammates(team.memberIDs.subtracting(held).sorted { $0.persistedValue < $1.persistedValue })
            try updateTeamGraph(team, expectedUpdatedAt: expectedUpdatedAt)
            // The title is what conversation search and the export filenames
            // read, so a rename that stops at the team row leaves the old name
            // in both surfaces.
            let retitled = try execute(
                sql: """
                UPDATE conversations SET title=?,updated_at=?
                WHERE id=? AND kind='team' AND subject_id=? AND lifecycle='active';
                """,
                bindings: [
                    conversation.title.map(SQLiteBinding.text) ?? .null,
                    .real(conversation.updatedAt.timeIntervalSince1970),
                    .text(conversation.id.persistedValue), .text(team.id.persistedValue)
                ]
            )
            guard retitled == 1 else {
                throw RepositoryError.notFound(entity: "team conversation", id: conversation.id.persistedValue)
            }
            // The team's own edit instant, so a membership row and its
            // participant row carry the same joined/left timestamps. The
            // conversation keeps whatever recency the caller passed, so a
            // rename does not reorder the sidebar.
            try syncTeamParticipants(conversationID: conversation.id, memberIDs: team.memberIDs,
                                     at: team.updatedAt)
        }
    }

    /// Keeps exactly one unclosed participant row per member.
    ///
    /// A re-added member revives its newest row instead of inserting a second
    /// one: the primary key is `(conversation_id, teammate_id, joined_at)`, and
    /// the read-context authority refuses a teammate holding two unclosed rows
    /// exactly as it refuses one holding none.
    private func syncTeamParticipants(conversationID: ConversationID,
                                      memberIDs: Set<TeammateID>, at instant: Date) throws {
        let activeRows = try query(
            sql: "SELECT teammate_id FROM conversation_participants WHERE conversation_id=? AND left_at IS NULL;",
            bindings: [.text(conversationID.persistedValue)]
        )
        let active = try Set(activeRows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
        for teammateID in active.subtracting(memberIDs).sorted(by: { $0.persistedValue < $1.persistedValue }) {
            _ = try execute(
                sql: """
                UPDATE conversation_participants SET left_at=?
                WHERE conversation_id=? AND teammate_id=? AND left_at IS NULL;
                """,
                bindings: [
                    .real(instant.timeIntervalSince1970), .text(conversationID.persistedValue),
                    .text(teammateID.persistedValue)
                ]
            )
        }
        for teammateID in memberIDs.subtracting(active).sorted(by: { $0.persistedValue < $1.persistedValue }) {
            let revived = try execute(
                sql: """
                UPDATE conversation_participants SET left_at=NULL
                WHERE conversation_id=? AND teammate_id=? AND joined_at=(
                    SELECT MAX(joined_at) FROM conversation_participants
                    WHERE conversation_id=? AND teammate_id=?);
                """,
                bindings: [
                    .text(conversationID.persistedValue), .text(teammateID.persistedValue),
                    .text(conversationID.persistedValue), .text(teammateID.persistedValue)
                ]
            )
            guard revived == 0 else { continue }
            _ = try execute(
                sql: """
                INSERT INTO conversation_participants(conversation_id,teammate_id,joined_at,left_at)
                VALUES (?,?,?,NULL);
                """,
                bindings: [
                    .text(conversationID.persistedValue), .text(teammateID.persistedValue),
                    .real(instant.timeIntervalSince1970)
                ]
            )
        }
    }

    public func teamConversation(teamID: TeamID) async throws -> Conversation? {
        try conversationRows(
            whereClause: "c.kind='team' AND c.subject_id=? AND c.lifecycle='active'",
            bindings: [.text(teamID.persistedValue)]
        ).first
    }

    public func activeParticipantIDs(conversationID: ConversationID) async throws -> Set<TeammateID> {
        let rows = try query(
            sql: "SELECT teammate_id FROM conversation_participants WHERE conversation_id=? AND left_at IS NULL;",
            bindings: [.text(conversationID.persistedValue)]
        )
        return try Set(rows.map { try parseID(TeammateID.self, $0.text("teammate_id")) })
    }
}
