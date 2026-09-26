import Foundation
import OpenBotsDomain

extension SQLiteStore: TeammateArchiveRepository {
    /// A bot Delete kept only for its team chat history is not an archived
    /// bot: it is not listed here, and it cannot be restored.
    public func archivedTeammates() async throws -> [Teammate] {
        try teammateRows(whereClause: "t.lifecycle='archived' AND \(Self.notDeletedTeammate)", bindings: [])
    }

    public func archiveTeammate(
        id: TeammateID, expectedProfileRevision: UInt64, now: Date
    ) async throws -> Teammate {
        try changeTeammateLifecycle(id: id, expectedProfileRevision: expectedProfileRevision,
                                    from: .active, to: .archived, now: now)
    }

    public func restoreTeammate(
        id: TeammateID, expectedProfileRevision: UInt64, now: Date
    ) async throws -> Teammate {
        try changeTeammateLifecycle(id: id, expectedProfileRevision: expectedProfileRevision,
                                    from: .archived, to: .active, now: now)
    }

    private func changeTeammateLifecycle(
        id: TeammateID, expectedProfileRevision: UInt64,
        from previous: TeammateLifecycle, to next: TeammateLifecycle, now: Date
    ) throws -> Teammate {
        guard now.timeIntervalSince1970.isFinite else { throw TeammateArchiveError.invalidDate }
        return try transaction {
            try Task.checkCancellation()
            guard var teammate = try teammateRows(whereClause: "t.id=? AND \(Self.notDeletedTeammate)",
                                                  bindings: [.text(id.persistedValue)]).first else {
                throw TeammateArchiveError.notFound
            }
            guard teammate.profile.revision == expectedProfileRevision else { throw TeammateArchiveError.staleRevision }
            guard teammate.lifecycle == previous else { throw TeammateArchiveError.invalidTransition }
            guard expectedProfileRevision < UInt64(Int64.max) else { throw TeammateArchiveError.revisionExhausted }
            if next == .archived {
                // BEGIN IMMEDIATE prevents a new run/proposal from racing this
                // check. Their insertion paths require an active teammate too.
                // A card's approvals row is not read: a card lives only inside
                // its turn, which the run line covers, and the row outlives the
                // turn (nothing moves it past `approved`; a quit leaves `pending`).
                let unresolved = try query(sql: """
                    SELECT 1 AS unresolved FROM work_runs
                    WHERE teammate_id=? AND state NOT IN ('succeeded','failed','interrupted')
                    UNION ALL SELECT 1 FROM action_proposals
                    WHERE teammate_id=? AND state IN ('pending','approved') LIMIT 1;
                    """, bindings: Array(repeating: .text(id.persistedValue), count: 2))
                guard unresolved.isEmpty else { throw TeammateArchiveError.unresolvedWork }
            }
            if next == .active {
                // The name may have been taken while the bot was archived.
                // Two bots never share one, so the restore is refused and
                // names the bot that has it; inside the same transaction, so
                // no create can slip in between the look and the change.
                let holders = try teammateRows(whereClause: "t.lifecycle<>'archived' AND t.id<>?",
                                               bindings: [.text(id.persistedValue)])
                if let holder = holders.activeBot(named: teammate.profile.displayName) {
                    throw TeammateNameTakenError(existingName: holder.profile.displayName)
                }
            }
            teammate.profile = try teammate.profile.revised()
            teammate.lifecycle = next
            teammate.updatedAt = max(teammate.updatedAt, now)
            let changed = try execute(sql: """
                UPDATE teammates SET lifecycle=?, profile_revision=?, updated_at=?
                WHERE id=? AND lifecycle=? AND profile_revision=?;
                """, bindings: [.text(next.rawValue), .integer(Int64(teammate.profile.revision)),
                    .real(teammate.updatedAt.timeIntervalSince1970), .text(id.persistedValue),
                    .text(previous.rawValue), .integer(Int64(expectedProfileRevision))])
            guard changed == 1 else { throw TeammateArchiveError.staleRevision }
            try insertProfileRevision(teammate)
            if next == .archived {
                // Keep the direct conversation and its draft alive; only its
                // obsolete active navigation selection is cleared.
                _ = try execute(sql: """
                    UPDATE chat_navigation_state SET selected_conversation_id=NULL, updated_at=?
                    WHERE singleton_id=1 AND selected_conversation_id IN (
                        SELECT id FROM conversations WHERE kind='direct' AND subject_id=?
                    );
                    """, bindings: [.real(teammate.updatedAt.timeIntervalSince1970), .text(id.persistedValue)])
            }
            try Task.checkCancellation()
            return teammate
        }
    }
}
