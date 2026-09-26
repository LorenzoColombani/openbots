import Foundation
import OpenBotsDomain

/// Where a journal reader takes its rows from.
///
/// `.live` asks SQLite for each row as a reader needs it, one narrow
/// statement at a time, which is right for the one record a claim or a
/// checkpoint touches. `.page` answers from rows read ahead for a whole
/// page of runs in a handful of statements, so a transcript's provenance no
/// longer costs ten statements per turn. Both hand the very same rows
/// to the very same decoders, so a record reads identically either way; a
/// row the page never covered is fetched live, never invented or skipped.
enum JournalRowSource {
    case live
    case page(JournalRowPage)
}

/// Rows read ahead for a page of runs, keyed by the persisted id strings the
/// rows carry, so a malformed id fails in the decoder exactly as it does on
/// a live read rather than in a lookup.
struct JournalRowPage {
    /// The runs whose rows were read. Any other run is answered live.
    let runIDs: Set<String>
    /// work_runs joined to run_journal_metadata, by run id.
    var runs: [String: SQLiteRow] = [:]
    /// Every run_input_receipts row of each run, in sequence order.
    var receipts: [String: [SQLiteRow]] = [:]
    /// The newest run_journal_entries row of each run.
    var lastEntries: [String: SQLiteRow] = [:]
    /// The controlled_memory_text_turns marker of each run that has one.
    var controlledMarkers: [String: SQLiteRow] = [:]
    /// The messages whose row and parts were read: the inputs the runs were
    /// journalled against. Any other message is answered live.
    var messageIDs: Set<String> = []
    var messages: [String: SQLiteRow] = [:]
    /// message_parts by message, in ordinal order.
    var messageParts: [String: [SQLiteRow]] = [:]
    /// The reply messages whose joined rows were read. Any other is live.
    var replyMessageIDs: Set<String> = []
    /// messages joined to message_parts by reply message, in ordinal order.
    var replyRows: [String: [SQLiteRow]] = [:]
}

extension SQLiteStore {
    // MARK: Reading a page ahead

    /// Reads, in six statements, every row the journal readers ask for over
    /// these runs: the run and its metadata, its input receipts, its newest
    /// journal entry, its controlled-memory marker, and the row and parts of
    /// the message each run was journalled against. Replies are added by
    /// `addTextTurnReplies` once the requests are decoded and name them.
    func journalRowPage(runIDs: [RunID]) throws -> JournalRowPage {
        let ids = runIDs.map(\.persistedValue)
        var page = JournalRowPage(runIDs: Set(ids))
        guard !ids.isEmpty else { return page }
        let bindings = ids.map { SQLiteBinding.text($0) }
        let list = Self.placeholders(ids.count)
        for row in try query(sql: """
            SELECT r.*,m.request_json,m.origin,m.revision,m.lease_generation,m.lease_owner_id,m.lease_token,m.lease_expires_at
            FROM work_runs r LEFT JOIN run_journal_metadata m ON m.run_id=r.id WHERE r.id IN (\(list));
            """, bindings: bindings) {
            page.runs[try row.text("id")] = row
        }
        for row in try query(sql: "SELECT * FROM run_input_receipts WHERE run_id IN (\(list)) ORDER BY run_id,sequence;",
                             bindings: bindings) {
            page.receipts[try row.text("run_id"), default: []].append(row)
        }
        for row in try query(sql: """
            SELECT e.* FROM run_journal_entries e WHERE e.run_id IN (\(list))
              AND e.sequence=(SELECT MAX(x.sequence) FROM run_journal_entries x WHERE x.run_id=e.run_id);
            """, bindings: bindings) {
            page.lastEntries[try row.text("run_id")] = row
        }
        for row in try query(sql: """
            SELECT run_id,policy_version,admission_token,publication_id,finish_revision
            FROM controlled_memory_text_turns WHERE run_id IN (\(list));
            """, bindings: bindings) {
            page.controlledMarkers[try row.text("run_id")] = row
        }
        // The input each run was journalled against is its initiating
        // message, named on the run row itself.
        let inputIDs = try page.runs.values.map { try $0.text("initiating_message_id") }
        page.messageIDs = Set(inputIDs)
        if !inputIDs.isEmpty {
            let messageBindings = inputIDs.map { SQLiteBinding.text($0) }
            let messageList = Self.placeholders(inputIDs.count)
            for row in try query(sql: """
                SELECT id,conversation_id,author_kind,author_teammate_id,output_class,created_at
                FROM messages WHERE id IN (\(messageList));
                """, bindings: messageBindings) {
                page.messages[try row.text("id")] = row
            }
            for row in try query(sql: """
                SELECT message_id,ordinal,kind,text_value,referenced_id FROM message_parts
                WHERE message_id IN (\(messageList)) ORDER BY message_id,ordinal;
                """, bindings: messageBindings) {
                page.messageParts[try row.text("message_id"), default: []].append(row)
            }
        }
        return page
    }

    /// Adds, in one statement, the joined reply rows `readTextTurnSnapshot`
    /// reads for each of these reply messages.
    func addTextTurnReplies(_ replyMessageIDs: [MessageID], to page: inout JournalRowPage) throws {
        let ids = replyMessageIDs.map(\.persistedValue)
        page.replyMessageIDs.formUnion(ids)
        guard !ids.isEmpty else { return }
        for row in try query(sql: """
            SELECT m.id AS reply_message_id,m.conversation_id,m.author_kind,m.author_teammate_id,m.output_class,m.delivery_state,
                p.id,p.ordinal,p.kind,p.text_value,p.referenced_id
            FROM messages m JOIN message_parts p ON p.message_id=m.id WHERE m.id IN (\(Self.placeholders(ids.count)))
            ORDER BY m.id,p.ordinal;
            """, bindings: ids.map { .text($0) }) {
            page.replyRows[try row.text("reply_message_id"), default: []].append(row)
        }
    }

    // MARK: One row at a time, from either source

    func journalRunRow(_ id: RunID, from source: JournalRowSource) throws -> SQLiteRow? {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return page.runs[id.persistedValue]
        }
        return try query(sql: "SELECT r.*,m.request_json,m.origin,m.revision,m.lease_generation,m.lease_owner_id,m.lease_token,m.lease_expires_at FROM work_runs r LEFT JOIN run_journal_metadata m ON m.run_id=r.id WHERE r.id=?;",
                         bindings: [.text(id.persistedValue)]).first
    }

    func journalInitialReceipt(_ id: RunID, from source: JournalRowSource) throws -> SQLiteRow? {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return try page.receipts[id.persistedValue]?.first { try $0.integer("sequence") == 1 }
        }
        return try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? AND sequence=1;", bindings: [.text(id.persistedValue)]).first
    }

    func journalReceiptExists(_ id: RunID, messageID: MessageID, from source: JournalRowSource) throws -> Bool {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return try page.receipts[id.persistedValue]?.contains { try $0.text("message_id") == messageID.persistedValue } ?? false
        }
        return try !query(sql: "SELECT 1 AS found FROM run_input_receipts WHERE run_id=? AND message_id=?;",
                          bindings: [.text(id.persistedValue), .text(messageID.persistedValue)]).isEmpty
    }

    /// At most two receipts: a text turn has exactly one, and the reader only
    /// needs to know whether that holds.
    func textTurnReceipts(_ id: RunID, from source: JournalRowSource) throws -> [SQLiteRow] {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return Array((page.receipts[id.persistedValue] ?? []).prefix(2))
        }
        return try query(sql: "SELECT * FROM run_input_receipts WHERE run_id=? LIMIT 2;", bindings: [.text(id.persistedValue)])
    }

    func journalLastEntry(_ id: RunID, from source: JournalRowSource) throws -> SQLiteRow? {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return page.lastEntries[id.persistedValue]
        }
        return try query(sql: "SELECT * FROM run_journal_entries WHERE run_id=? ORDER BY sequence DESC LIMIT 1;", bindings: [.text(id.persistedValue)]).first
    }

    func controlledTextMarker(_ id: RunID, from source: JournalRowSource = .live) throws -> SQLiteRow? {
        if case let .page(page) = source, page.runIDs.contains(id.persistedValue) {
            return page.controlledMarkers[id.persistedValue]
        }
        return try query(sql: "SELECT run_id,policy_version,admission_token,publication_id,finish_revision FROM controlled_memory_text_turns WHERE run_id=?;",
            bindings: [.text(id.persistedValue)]).first
    }

    func journalInputMessage(_ id: MessageID, from source: JournalRowSource) throws -> SQLiteRow? {
        if case let .page(page) = source, page.messageIDs.contains(id.persistedValue) {
            return page.messages[id.persistedValue]
        }
        return try query(sql: "SELECT conversation_id,author_kind,author_teammate_id,output_class,created_at FROM messages WHERE id=?;",
                         bindings: [.text(id.persistedValue)]).first
    }

    /// At most 101 parts, in ordinal order: an input has at most 100 and the
    /// reader only needs to know whether that holds.
    func journalInputParts(_ id: MessageID, from source: JournalRowSource) throws -> [SQLiteRow] {
        if case let .page(page) = source, page.messageIDs.contains(id.persistedValue) {
            return Array((page.messageParts[id.persistedValue] ?? []).prefix(101))
        }
        return try query(sql: "SELECT ordinal,kind,text_value,referenced_id FROM message_parts WHERE message_id=? ORDER BY ordinal LIMIT 101;",
                         bindings: [.text(id.persistedValue)])
    }

    /// At most 32 joined rows of the reply, in ordinal order: a reply has at
    /// most 28 parts and the reader only needs to know whether that holds.
    func textTurnReplyRows(_ id: MessageID, from source: JournalRowSource) throws -> [SQLiteRow] {
        if case let .page(page) = source, page.replyMessageIDs.contains(id.persistedValue) {
            return Array((page.replyRows[id.persistedValue] ?? []).prefix(32))
        }
        return try query(sql: """
            SELECT m.conversation_id,m.author_kind,m.author_teammate_id,m.output_class,m.delivery_state,
                p.id,p.ordinal,p.kind,p.text_value,p.referenced_id
            FROM messages m JOIN message_parts p ON p.message_id=m.id WHERE m.id=?
            ORDER BY p.ordinal LIMIT 32;
            """, bindings: [.text(id.persistedValue)])
    }
}
