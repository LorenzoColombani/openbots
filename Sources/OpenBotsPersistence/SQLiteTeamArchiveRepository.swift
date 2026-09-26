import Foundation
import OpenBotsDomain

extension SQLiteStore: TeamArchiveRepository {
    public func archivedTeams() async throws -> [Team] {
        try await listTeams(includingArchived: true).filter { $0.lifecycle == .archived }
    }

    public func archiveTeam(id: TeamID, expectedUpdatedAt: Date, now: Date) async throws -> Team {
        try changeTeamLifecycle(id: id, expectedUpdatedAt: expectedUpdatedAt, from: .active, to: .archived, now: now)
    }

    public func restoreTeam(id: TeamID, expectedUpdatedAt: Date, now: Date) async throws -> Team {
        try changeTeamLifecycle(id: id, expectedUpdatedAt: expectedUpdatedAt, from: .archived, to: .active, now: now)
    }

    private func changeTeamLifecycle(
        id: TeamID, expectedUpdatedAt: Date,
        from previous: DurableEntityLifecycle, to next: DurableEntityLifecycle, now: Date
    ) throws -> Team {
        guard now.timeIntervalSince1970.isFinite else { throw TeamArchiveError.invalidDate }
        return try transaction {
            try Task.checkCancellation()
            let conversations = "SELECT id FROM conversations WHERE kind='team' AND subject_id=?"
            let row = try query(sql: "SELECT lifecycle, updated_at FROM teams WHERE id=?;",
                                bindings: [.text(id.persistedValue)]).first
            guard let row else { throw TeamArchiveError.notFound }
            guard try row.text("lifecycle") == previous.rawValue else { throw TeamArchiveError.invalidTransition }
            // The instant the caller read, bound the way the column is written.
            guard try row.real("updated_at") == expectedUpdatedAt.timeIntervalSince1970 else {
                throw TeamArchiveError.staleTeam
            }
            if next == .archived {
                // BEGIN IMMEDIATE keeps a new run from racing this check; a run
                // cannot start in an archived team (the run journal asks for an
                // active one), so nothing is left running behind the archive.
                // Action proposals live only in a bot's own chat (their context
                // check asks for kind='direct'), so a team's chat has none. A
                // handoff staged, accepted or working is live or waits for the
                // user's Send; one needing recovery can wait forever, so it does not
                // keep the team from being archived.
                let unresolved = try query(sql: """
                    SELECT 1 AS unresolved FROM work_runs
                    WHERE conversation_id IN (\(conversations)) AND state NOT IN ('succeeded','failed','interrupted')
                    UNION ALL SELECT 1 FROM handoffs
                    WHERE origin_conversation_id IN (\(conversations)) AND state IN ('staged','accepted','working') LIMIT 1;
                    """, bindings: Array(repeating: .text(id.persistedValue), count: 2))
                guard unresolved.isEmpty else { throw TeamArchiveError.unresolvedWork }
            }
            let updatedAt = max(try row.real("updated_at"), now.timeIntervalSince1970)
            let changed = try execute(sql: """
                UPDATE teams SET lifecycle=?, updated_at=? WHERE id=? AND lifecycle=? AND updated_at=?;
                """, bindings: [.text(next.rawValue), .real(updatedAt), .text(id.persistedValue),
                                .text(previous.rawValue), .real(expectedUpdatedAt.timeIntervalSince1970)])
            guard changed == 1 else { throw TeamArchiveError.staleTeam }
            if next == .archived {
                // The chat and its draft stay; only a selection of it is cleared.
                _ = try execute(sql: """
                    UPDATE chat_navigation_state SET selected_conversation_id=NULL, updated_at=?
                    WHERE singleton_id=1 AND selected_conversation_id IN (\(conversations));
                    """, bindings: [.real(updatedAt), .text(id.persistedValue)])
            }
            try Task.checkCancellation()
            guard let team = try teamRows(whereClause: "id=?", bindings: [.text(id.persistedValue)]).first else {
                throw TeamArchiveError.notFound
            }
            return team
        }
    }
}
