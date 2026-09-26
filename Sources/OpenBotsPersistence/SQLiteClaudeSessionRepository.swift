import Foundation
import OpenBotsDomain

/// One `app_metadata` row per bot and conversation, keyed
/// `claude_session_v1.<conversation id>.<teammate id>`, holding the stored
/// session as JSON. Cleared once the CLI no longer knows the session and what
/// it kept of it is removed; while those files cannot be removed the row stays,
/// marked refused, so they can still be found.
private let claudeSessionKeyPrefix = "claude_session_v1"

extension SQLiteStore: ClaudeSessionRepository {
    private static func claudeSessionKey(conversationID: ConversationID, teammateID: TeammateID) -> String {
        "\(claudeSessionKeyPrefix).\(conversationID.persistedValue).\(teammateID.persistedValue)"
    }

    private static var claudeSessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var claudeSessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func storedClaudeSession(conversationID: ConversationID, teammateID: TeammateID) async throws -> StoredClaudeSession? {
        try Task.checkCancellation()
        let rows = try query(sql: "SELECT value FROM app_metadata WHERE key=?;",
                             bindings: [.text(Self.claudeSessionKey(conversationID: conversationID, teammateID: teammateID))])
        guard let row = rows.first else { return nil }
        // A row this build cannot read is no session: the next turn starts
        // fresh, and a turn that keeps its session writes its row over this
        // one. Whatever the unreadable row named cannot be identified, so
        // nothing of it is removed first.
        return try? Self.claudeSessionDecoder.decode(StoredClaudeSession.self, from: Data(try row.text("value").utf8))
    }

    public func storeClaudeSession(_ session: StoredClaudeSession, conversationID: ConversationID, teammateID: TeammateID) async throws {
        try Task.checkCancellation()
        let value = String(decoding: try Self.claudeSessionEncoder.encode(session), as: UTF8.self)
        _ = try execute(sql: """
            INSERT INTO app_metadata(key,value) VALUES (?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            """, bindings: [.text(Self.claudeSessionKey(conversationID: conversationID, teammateID: teammateID)), .text(value)])
    }

    public func clearClaudeSession(conversationID: ConversationID, teammateID: TeammateID) async throws {
        try Task.checkCancellation()
        _ = try execute(sql: "DELETE FROM app_metadata WHERE key=?;",
                        bindings: [.text(Self.claudeSessionKey(conversationID: conversationID, teammateID: teammateID))])
    }

    public func storedClaudeSessions(teammateID: TeammateID) async throws -> [StoredClaudeSessionRecord] {
        try Task.checkCancellation()
        // The prefix's underscores are escaped so LIKE reads them as letters,
        // and the key is split again after the query so a stray row with the
        // right suffix and the wrong shape is skipped, not misread.
        let pattern = claudeSessionKeyPrefix.replacingOccurrences(of: "_", with: "\\_") + ".%." + teammateID.persistedValue
        let rows = try query(sql: "SELECT key, value FROM app_metadata WHERE key LIKE ? ESCAPE '\\' ORDER BY key;",
                             bindings: [.text(pattern)])
        return try rows.compactMap { row in
            let parts = try row.text("key").split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == claudeSessionKeyPrefix, parts[2] == teammateID.persistedValue,
                  let conversation = UUID(uuidString: String(parts[1])),
                  // A row this build cannot read is no session, as in the single
                  // lookup, so it is never listed and never dropped: its files
                  // cannot be identified, and the row stays.
                  let session = try? Self.claudeSessionDecoder.decode(StoredClaudeSession.self, from: Data(try row.text("value").utf8))
            else { return nil }
            return StoredClaudeSessionRecord(conversationID: ConversationID(conversation), session: session)
        }
    }
}
