import Foundation
import OpenBotsDomain

extension SQLiteStore: ActionProposalRepository {
    public func insertProposal(_ proposal: ActionProposal) async throws -> ActionProposalRecord {
        try proposal.validate()
        return try transaction {
            try validateProposalContext(proposal)
            guard try query(sql: "SELECT id FROM action_proposals WHERE id=?;", bindings: [.text(proposal.id.persistedValue)]).isEmpty else {
                throw ActionProposalError.staleReview
            }
            let fingerprint = try proposal.fingerprint()
            _ = try execute(sql: """
                INSERT INTO action_proposals(id,teammate_id,conversation_id,run_id,envelope_json,fingerprint,state,revision,updated_at)
                VALUES (?,?,?,?,?,?,'pending',1,?);
                """, bindings: [.text(proposal.id.persistedValue), .text(proposal.teammateID.persistedValue),
                    .text(proposal.conversationID.persistedValue), proposal.runID.map { .text($0.persistedValue) } ?? .null,
                    .text(String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)),
                    .text(fingerprint), .real(proposal.createdAt.timeIntervalSince1970)])
            try appendProposalEvent(id: proposal.id, revision: 1, state: .pending, now: proposal.createdAt)
            return try requiredProposal(proposal.id)
        }
    }

    public func proposals(conversationID: ConversationID, limit: Int) async throws -> [ActionProposalRecord] {
        guard (1...100).contains(limit) else { throw ActionProposalError.invalidLimit }
        return try transaction {
            try query(sql: "SELECT * FROM action_proposals WHERE conversation_id=? ORDER BY updated_at DESC,id LIMIT ?;",
                bindings: [.text(conversationID.persistedValue), .integer(Int64(limit))]).map(decodeProposal)
        }
    }

    public func decideProposal(_ review: ActionProposalRecord, decision: ActionProposalDecision,
                               now: Date) async throws -> ActionProposalRecord {
        guard now.timeIntervalSince1970.isFinite else { throw ActionProposalError.invalid }
        return try transaction {
            let current = try requiredProposal(review.id)
            // Exact bytes as well as the digest protect against a display/payload
            // substitution. A matching ID alone never resolves a proposal.
            guard current == review,
                  try current.proposal.canonicalData() == review.proposal.canonicalData(),
                  current.revision < Int64.max else { throw ActionProposalError.staleReview }
            guard now >= current.updatedAt else { throw ActionProposalError.clockMovedBackwards }
            let next: ActionProposalState
            switch (current.state, decision) {
            case (.pending, .approve):
                guard now < current.proposal.expiresAt else { throw ActionProposalError.expired }
                try validateProposalContext(current.proposal)
                next = .approved
            case (.pending, .deny): next = .denied
            case (.pending, .cancel), (.approved, .cancel): next = .cancelled
            case (.pending, .expire), (.approved, .expire):
                guard now >= current.proposal.expiresAt else { throw ActionProposalError.invalidTransition }
                next = .expired
            default: throw ActionProposalError.invalidTransition
            }
            let revision = current.revision + 1
            let changed = try execute(sql: "UPDATE action_proposals SET state=?,revision=?,updated_at=? WHERE id=? AND revision=? AND fingerprint=?;",
                bindings: [.text(next.rawValue), .integer(revision), .real(now.timeIntervalSince1970),
                    .text(current.id.persistedValue), .integer(current.revision), .text(current.fingerprint)])
            guard changed == 1 else { throw ActionProposalError.staleReview }
            try appendProposalEvent(id: current.id, revision: revision, state: next, now: now)
            return try requiredProposal(current.id)
        }
    }

    private func requiredProposal(_ id: ApprovalID) throws -> ActionProposalRecord {
        guard let row = try query(sql: "SELECT * FROM action_proposals WHERE id=?;", bindings: [.text(id.persistedValue)]).first else {
            throw ActionProposalError.unavailable
        }
        return try decodeProposal(row)
    }

    private func decodeProposal(_ row: SQLiteRow) throws -> ActionProposalRecord {
        let json = try row.text("envelope_json")
        guard json.utf8.count <= 64 * 1_024 else { throw ActionProposalError.invalid }
        let proposal = try JSONDecoder().decode(ActionProposal.self, from: Data(json.utf8))
        try proposal.validate()
        let fingerprint = try row.text("fingerprint")
        let revision = try row.integer("revision")
        let updatedAt = Date(timeIntervalSince1970: try row.real("updated_at"))
        guard proposal.id.persistedValue == (try row.text("id")),
              proposal.teammateID.persistedValue == (try row.text("teammate_id")),
              proposal.conversationID.persistedValue == (try row.text("conversation_id")),
              proposal.runID?.persistedValue == (try row.optionalText("run_id")),
              fingerprint == (try proposal.fingerprint()), revision > 0,
              let state = ActionProposalState(rawValue: try row.text("state")),
              updatedAt.timeIntervalSince1970.isFinite, updatedAt >= proposal.createdAt,
              (state == .pending) == (revision == 1),
              let event = try query(sql: "SELECT revision,state,recorded_at FROM action_proposal_events WHERE proposal_id=? ORDER BY revision DESC LIMIT 1;",
                  bindings: [.text(proposal.id.persistedValue)]).first,
              try event.integer("revision") == revision, try event.text("state") == state.rawValue,
              try event.real("recorded_at") == updatedAt.timeIntervalSince1970 else { throw ActionProposalError.invalid }
        return ActionProposalRecord(proposal: proposal, fingerprint: fingerprint, state: state, revision: revision, updatedAt: updatedAt)
    }

    private func appendProposalEvent(id: ApprovalID, revision: Int64, state: ActionProposalState, now: Date) throws {
        _ = try execute(sql: "INSERT INTO action_proposal_events(proposal_id,revision,state,recorded_at) VALUES (?,?,?,?);",
            bindings: [.text(id.persistedValue), .integer(revision), .text(state.rawValue), .real(now.timeIntervalSince1970)])
    }

    private func validateProposalContext(_ proposal: ActionProposal) throws {
        guard let row = try query(sql: """
            SELECT t.lifecycle,t.is_hidden,t.profile_revision,c.lifecycle AS conversation_lifecycle,
                   c.kind,c.subject_id,s.revision AS context_revision,s.teammate_id AS context_teammate,s.project_id,s.team_id,
                   EXISTS(SELECT 1 FROM conversation_participants cp WHERE cp.conversation_id=c.id
                          AND cp.teammate_id=t.id AND cp.left_at IS NULL) AS participant
            FROM teammates t
            JOIN conversations c ON c.id=?
            LEFT JOIN conversation_context_selections s ON s.conversation_id=c.id
            WHERE t.id=?;
            """, bindings: [.text(proposal.conversationID.persistedValue), .text(proposal.teammateID.persistedValue)]).first,
              try row.text("lifecycle") == "active", try row.integer("is_hidden") == 0,
              try row.text("conversation_lifecycle") == "active", try row.text("kind") == "direct",
              try row.text("subject_id") == proposal.teammateID.persistedValue,
              try row.integer("participant") == 1,
              try row.integer("profile_revision") == Int64(proposal.profileRevision),
              (try row.optionalInteger("context_revision") ?? 0) == Int64(proposal.contextRevision) else {
            throw ActionProposalError.contextChanged
        }
        if let contextTeammate = try row.optionalText("context_teammate"), contextTeammate != proposal.teammateID.persistedValue {
            throw ActionProposalError.contextChanged
        }
        for (column, table, memberships, foreignKey) in [
            ("project_id", "projects", "project_memberships", "project_id"),
            ("team_id", "teams", "team_memberships", "team_id")
        ] {
            if let id = try row.optionalText(column) {
                guard try !query(sql: "SELECT 1 AS allowed FROM \(table) t WHERE t.id=? AND t.lifecycle='active' AND EXISTS(SELECT 1 FROM \(memberships) m WHERE m.\(foreignKey)=t.id AND m.teammate_id=? AND m.revoked_at IS NULL);",
                    bindings: [.text(id), .text(proposal.teammateID.persistedValue)]).isEmpty else { throw ActionProposalError.contextChanged }
            }
        }
        if let runID = proposal.runID {
            guard try !query(sql: "SELECT 1 AS allowed FROM work_runs r JOIN run_journal_metadata m ON m.run_id=r.id WHERE r.id=? AND r.teammate_id=? AND r.conversation_id=? AND m.origin='localFixture' AND r.state NOT IN ('succeeded','failed','interrupted');",
                bindings: [.text(runID.persistedValue), .text(proposal.teammateID.persistedValue), .text(proposal.conversationID.persistedValue)]).isEmpty else {
                throw ActionProposalError.contextChanged
            }
        }
    }
}
