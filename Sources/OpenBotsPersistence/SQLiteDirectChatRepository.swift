import Foundation
import OpenBotsDomain

extension SQLiteStore: DirectChatProvisioningRepository, ChatSelectionRepository {
    public func provisionDirectChat(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws {
        try validateDirectChatAggregate(
            teammate: teammate,
            conversation: conversation,
            fixtureGreeting: fixtureGreeting
        )

        // No operation below suspends. The actor-isolated connection executes
        // exactly one BEGIN IMMEDIATE/COMMIT pair for the complete aggregate.
        try transaction {
            try insertTeammateGraph(teammate)
            try insertConversationGraph(conversation, participantIDs: [teammate.id])
            try placeNewBotAtTopOfSidebarOrder(teammate.id)
            if let fixtureGreeting {
                try appendMessageGraph(fixtureGreeting, expectedPreviousSequence: 0)
            }
            if selectConversation {
                try writeSelectedConversationID(
                    conversation.id,
                    updatedAt: max(teammate.updatedAt, conversation.updatedAt)
                )
            }
        }
    }

    public func selectedConversationID() async throws -> ConversationID? {
        let rows = try query(
            sql: """
            SELECT n.selected_conversation_id, c.kind AS selected_kind
            FROM chat_navigation_state n
            LEFT JOIN conversations c ON c.id=n.selected_conversation_id
            WHERE n.singleton_id=1;
            """
        )
        guard rows.count == 1, let row = rows.first else {
            throw RepositoryError.unavailable(
                reason: "The chat navigation singleton is missing or ambiguous."
            )
        }
        let selectedValue = try row.optionalText("selected_conversation_id")
        let selectedKind = try row.optionalText("selected_kind")
        switch (selectedValue, selectedKind) {
        case (nil, nil):
            return nil
        case let (.some(value), .some(kind)) where kind == "direct":
            return try parseID(ConversationID.self, value)
        default:
            throw RepositoryError.unavailable(
                reason: "The saved chat selection does not reference a direct conversation."
            )
        }
    }

    public func setSelectedConversationID(_ conversationID: ConversationID?) async throws {
        try Task.checkCancellation()
        try transaction {
            // BEGIN IMMEDIATE may have waited for another writer. Recheck on
            // entering its synchronous body, then before committing the write.
            try Task.checkCancellation()
            try writeSelectedConversationID(conversationID, updatedAt: Date())
            try Task.checkCancellation()
        }
    }

    private func validateDirectChatAggregate(
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?
    ) throws {
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

    private func writeSelectedConversationID(
        _ conversationID: ConversationID?,
        updatedAt: Date
    ) throws {
        if let conversationID {
            guard let row = try query(
                sql: "SELECT kind FROM conversations WHERE id=?;",
                bindings: [.text(conversationID.persistedValue)]
            ).first else {
                throw RepositoryError.notFound(
                    entity: "conversation",
                    id: conversationID.persistedValue
                )
            }
            guard try row.text("kind") == "direct" else {
                throw DomainValidationError.invalid(
                    field: "selected conversation",
                    reason: "must reference a direct conversation"
                )
            }
            guard try !query(sql: """
                SELECT 1 AS active FROM conversations c JOIN teammates t ON t.id=c.subject_id
                WHERE c.id=? AND c.lifecycle='active' AND t.lifecycle='active';
                """, bindings: [.text(conversationID.persistedValue)]).isEmpty else {
                throw TeammateArchiveError.invalidTransition
            }
        }

        let changes = try execute(
            sql: """
            UPDATE chat_navigation_state
            SET selected_conversation_id=?, updated_at=?
            WHERE singleton_id=1;
            """,
            bindings: [
                conversationID.map { .text($0.persistedValue) } ?? .null,
                .real(updatedAt.timeIntervalSince1970)
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.unavailable(
                reason: "The chat navigation singleton is missing or ambiguous."
            )
        }
    }
}
