import Foundation
import OpenBotsDomain

extension SQLiteStore: ConversationRepository {
    public func conversation(id: ConversationID) async throws -> Conversation? {
        try conversationRows(
            whereClause: "c.id=?",
            bindings: [.text(id.persistedValue)]
        ).first
    }

    public func conversations(
        for teammateID: TeammateID,
        includingArchived: Bool
    ) async throws -> [Conversation] {
        let archivedClause = includingArchived ? "" : "AND c.lifecycle='active'"
        return try conversationRows(
            whereClause: """
            EXISTS (SELECT 1 FROM conversation_participants p
                    WHERE p.conversation_id=c.id AND p.teammate_id=? AND p.left_at IS NULL)
            \(archivedClause)
            """,
            bindings: [.text(teammateID.persistedValue)]
        )
    }

    public func insert(_ conversation: Conversation, participantIDs: Set<TeammateID>) async throws {
        try transaction {
            try insertConversationGraph(conversation, participantIDs: participantIDs)
        }
    }

    public func update(_ conversation: Conversation) async throws {
        let changes = try execute(
            sql: "UPDATE conversations SET title=?, lifecycle=?, updated_at=? WHERE id=?;",
            bindings: [
                conversation.title.map(SQLiteBinding.text) ?? .null,
                .text(conversation.lifecycle.rawValue), .real(conversation.updatedAt.timeIntervalSince1970),
                .text(conversation.id.persistedValue)
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.notFound(entity: "conversation", id: conversation.id.persistedValue)
        }
    }

    /// Inserts a conversation and its active participants. The caller owns the
    /// transaction so direct-chat provisioning can compose this graph with the
    /// teammate, optional greeting, and navigation selection.
    func insertConversationGraph(
        _ conversation: Conversation,
        participantIDs: Set<TeammateID>
    ) throws {
        if case let .direct(teammateID) = conversation.kind,
           !participantIDs.contains(teammateID) {
            throw DomainValidationError.invalid(
                field: "conversation participants",
                reason: "a direct conversation must include its teammate"
            )
        }

        let (kind, subjectID) = conversationKindColumns(conversation.kind)
        _ = try execute(
            sql: """
            INSERT INTO conversations(id,kind,subject_id,title,lifecycle,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?);
            """,
            bindings: [
                .text(conversation.id.persistedValue), .text(kind), .text(subjectID),
                conversation.title.map(SQLiteBinding.text) ?? .null,
                .text(conversation.lifecycle.rawValue),
                .real(conversation.createdAt.timeIntervalSince1970),
                .real(conversation.updatedAt.timeIntervalSince1970)
            ]
        )
        for teammateID in participantIDs.sorted(by: { $0.persistedValue < $1.persistedValue }) {
            _ = try execute(
                sql: "INSERT INTO conversation_participants(conversation_id,teammate_id,joined_at,left_at) VALUES (?,?,?,NULL);",
                bindings: [
                    .text(conversation.id.persistedValue), .text(teammateID.persistedValue),
                    .real(conversation.createdAt.timeIntervalSince1970)
                ]
            )
        }
    }

    private func conversationRows(
        whereClause: String,
        bindings: [SQLiteBinding]
    ) throws -> [Conversation] {
        try query(
            sql: """
            SELECT c.id,c.kind,c.subject_id,c.title,c.lifecycle,c.created_at,c.updated_at
            FROM conversations c WHERE \(whereClause)
            ORDER BY c.updated_at DESC,c.id;
            """,
            bindings: bindings
        ).map { row in
            let kindName = try row.text("kind")
            let subjectID = try row.text("subject_id")
            let kind: ConversationKind
            switch kindName {
            case "direct": kind = .direct(teammateID: try parseID(TeammateID.self, subjectID))
            case "project": kind = .project(projectID: try parseID(ProjectID.self, subjectID))
            case "team": kind = .team(teamID: try parseID(TeamID.self, subjectID))
            default: throw SQLiteStoreError.invalidRow(reason: "unknown conversation kind \(kindName)")
            }
            guard let lifecycle = ConversationLifecycle(rawValue: try row.text("lifecycle")) else {
                throw SQLiteStoreError.invalidRow(reason: "unknown conversation lifecycle")
            }
            return try Conversation(
                id: parseID(ConversationID.self, row.text("id")),
                kind: kind,
                title: row.optionalText("title"),
                lifecycle: lifecycle,
                createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
            )
        }
    }

    private func conversationKindColumns(_ kind: ConversationKind) -> (String, String) {
        switch kind {
        case let .direct(teammateID): ("direct", teammateID.persistedValue)
        case let .project(projectID): ("project", projectID.persistedValue)
        case let .team(teamID): ("team", teamID.persistedValue)
        }
    }
}

extension SQLiteStore: MessageRepository {
    public func append(_ message: Message, expectedPreviousSequence: Int64) async throws {
        try transaction {
            try appendMessageGraph(message, expectedPreviousSequence: expectedPreviousSequence)
        }
    }

    public func message(id: MessageID) async throws -> Message? {
        guard let row = try query(
            sql: "SELECT * FROM messages WHERE id=?;",
            bindings: [.text(id.persistedValue)]
        ).first else { return nil }
        return try decodeMessage(row)
    }

    public func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message> {
        let boundary = request.beforeSequence ?? Int64.max
        let rows = try query(
            sql: """
            SELECT * FROM messages WHERE conversation_id=? AND sequence<?
            ORDER BY sequence DESC LIMIT ?;
            """,
            bindings: [
                .text(conversationID.persistedValue), .integer(boundary), .integer(Int64(request.limit + 1))
            ]
        )
        let hasMore = rows.count > request.limit
        let selected = rows.prefix(request.limit)
        let messages = try selected.map(decodeMessage).reversed()
        return Page(elements: Array(messages), hasMore: hasMore)
    }

    public func updateDeliveryState(
        messageID: MessageID,
        from expectedState: MessageDeliveryState,
        to newState: MessageDeliveryState,
        updatedAt: Date
    ) async throws {
        guard isLegalDeliveryTransition(from: expectedState, to: newState) else {
            throw LifecycleTransitionError.illegalTransition(
                entity: "message delivery",
                state: expectedState.rawValue,
                event: newState.rawValue
            )
        }
        let changes = try execute(
            sql: "UPDATE messages SET delivery_state=?,updated_at=? WHERE id=? AND delivery_state=?;",
            bindings: [
                .text(newState.rawValue), .real(updatedAt.timeIntervalSince1970),
                .text(messageID.persistedValue), .text(expectedState.rawValue)
            ]
        )
        guard changes == 1 else {
            throw RepositoryError.optimisticLockFailed(entity: "message", id: messageID.persistedValue)
        }
    }

    /// Inserts one message and its parts after an exact sequence check. The
    /// caller owns the transaction so a first fixture greeting can be part of
    /// the same direct-chat commit as its teammate and conversation.
    func appendMessageGraph(
        _ message: Message,
        expectedPreviousSequence: Int64
    ) throws {
        // A caller may have checked lifecycle before an async suspension.
        // Recheck direct-chat ownership inside the append transaction so a
        // concurrent archive cannot accept a new turn afterwards.
        if let owner = try query(sql: """
            SELECT t.lifecycle FROM conversations c JOIN teammates t ON t.id=c.subject_id
            WHERE c.id=? AND c.kind='direct';
            """, bindings: [.text(message.conversationID.persistedValue)]).first {
            guard try owner.text("lifecycle") == TeammateLifecycle.active.rawValue else {
                throw TeammateArchiveError.invalidTransition
            }
        }
        try validateAttachmentReferences(in: message)
        let row = try query(
            sql: "SELECT MAX(sequence) AS max_sequence FROM messages WHERE conversation_id=?;",
            bindings: [.text(message.conversationID.persistedValue)]
        ).first
        let actual = try row?.optionalInteger("max_sequence") ?? 0
        guard actual < Int64.max else { throw AttachmentRepositoryError.sequenceExhausted }
        guard actual == expectedPreviousSequence, message.sequence == actual + 1 else {
            throw RepositoryError.sequenceConflict(
                conversationID: message.conversationID,
                expected: expectedPreviousSequence,
                actual: actual
            )
        }
        let (authorKind, authorID) = messageAuthorColumns(message.author)
        _ = try execute(
            sql: """
            INSERT INTO messages(id,conversation_id,sequence,author_kind,author_teammate_id,output_class,
                delivery_state,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?);
            """,
            bindings: [
                .text(message.id.persistedValue), .text(message.conversationID.persistedValue),
                .integer(message.sequence), .text(authorKind), authorID.map(SQLiteBinding.text) ?? .null,
                .text(message.outputClass.rawValue), .text(message.deliveryState.rawValue),
                .real(message.createdAt.timeIntervalSince1970), .real(message.updatedAt.timeIntervalSince1970)
            ]
        )
        for part in message.parts {
            let columns = messagePartColumns(part.content)
            _ = try execute(
                sql: "INSERT INTO message_parts(id,message_id,ordinal,kind,text_value,referenced_id) VALUES (?,?,?,?,?,?);",
                bindings: [
                    .text(part.id.persistedValue), .text(message.id.persistedValue), .integer(Int64(part.ordinal)),
                    .text(columns.kind), columns.text.map(SQLiteBinding.text) ?? .null,
                    columns.reference.map(SQLiteBinding.text) ?? .null
                ]
            )
        }
        _ = try execute(
            sql: "UPDATE conversations SET updated_at=MAX(updated_at,?) WHERE id=?;",
            bindings: [.real(message.updatedAt.timeIntervalSince1970), .text(message.conversationID.persistedValue)]
        )
    }

    private func decodeMessage(_ row: SQLiteRow) throws -> Message {
        let messageID = try parseID(MessageID.self, row.text("id"))
        let authorKind = try row.text("author_kind")
        let authorID = try row.optionalText("author_teammate_id")
        let author: MessageAuthor
        switch (authorKind, authorID) {
        case ("user", nil): author = .user
        case ("system", nil): author = .system
        case let ("teammate", .some(id)): author = .teammate(try parseID(TeammateID.self, id))
        default: throw SQLiteStoreError.invalidRow(reason: "message author is inconsistent")
        }
        guard let outputClass = OutputClass(rawValue: try row.text("output_class")),
              let delivery = MessageDeliveryState(rawValue: try row.text("delivery_state")) else {
            throw SQLiteStoreError.invalidRow(reason: "message enum is invalid")
        }
        let partRows = try query(
            sql: "SELECT * FROM message_parts WHERE message_id=? ORDER BY ordinal;",
            bindings: [.text(messageID.persistedValue)]
        )
        let parts = try partRows.map { partRow -> MessagePart in
            let kind = try partRow.text("kind")
            let content: MessagePartContent
            switch kind {
            case "text": content = .text(try partRow.text("text_value"))
            case "status": content = .status(try partRow.text("text_value"))
            case "attachment": content = .attachment(try parseID(AttachmentID.self, partRow.text("referenced_id")))
            case "artifact": content = .artifact(try parseID(ArtifactID.self, partRow.text("referenced_id")))
            default: throw SQLiteStoreError.invalidRow(reason: "unknown message part kind")
            }
            return try MessagePart(
                id: parseID(MessagePartID.self, partRow.text("id")),
                ordinal: Int(partRow.integer("ordinal")),
                content: content
            )
        }
        return try Message(
            id: messageID,
            conversationID: parseID(ConversationID.self, row.text("conversation_id")),
            sequence: row.integer("sequence"),
            author: author,
            outputClass: outputClass,
            deliveryState: delivery,
            parts: parts,
            createdAt: Date(timeIntervalSince1970: row.real("created_at")),
            updatedAt: Date(timeIntervalSince1970: row.real("updated_at"))
        )
    }

    private func messageAuthorColumns(_ author: MessageAuthor) -> (String, String?) {
        switch author {
        case .user: ("user", nil)
        case let .teammate(id): ("teammate", id.persistedValue)
        case .system: ("system", nil)
        }
    }

    private func messagePartColumns(_ content: MessagePartContent) -> (kind: String, text: String?, reference: String?) {
        switch content {
        case let .text(text): ("text", text, nil)
        case let .status(text): ("status", text, nil)
        case let .attachment(id): ("attachment", nil, id.persistedValue)
        case let .artifact(id): ("artifact", nil, id.persistedValue)
        }
    }

    private func isLegalDeliveryTransition(from: MessageDeliveryState, to: MessageDeliveryState) -> Bool {
        MessageDeliveryEvent.allCases.contains { event in
            (try? from.applying(event)) == to
        }
    }
}

private extension MessageDeliveryEvent {
    static var allCases: [Self] {
        [.queue, .submit, .acknowledge, .markOutcomeUnknown, .complete, .fail]
    }
}
