import Darwin
import Foundation
import OpenBotsDomain

public enum MessagesHistoryReadError: Error, Equatable, Sendable {
    /// The history could not be opened: absent, or refused. Full Disk Access
    /// is the usual refusal, and macOS never asks for it.
    case openFailed(code: Int32)
    case queryFailed(message: String)
}

/// Lists the conversations in the user's Messages history for the Access
/// sheet's chat picker. Names only: which conversations
/// exist, who is in them, and when each last had a message. No message is read.
///
/// Opened read-only and never `immutable`: Messages keeps its history in WAL
/// mode and writes to it while this reads (a real history can carry a `-wal` of
/// several hundred KB), so an immutable open would miss the newest conversations
/// without any error. A read-only connection takes the existing `-shm` as it
/// finds it, which is also what `sqlite3 -readonly` does for the server.
public enum MessagesHistoryReader {
    static let busyTimeoutMilliseconds: Int32 = 2_000

    public static func conversations(databaseURL: URL) throws -> [MessagesConversation] {
        var opened: SQLiteConnection?
        let result = databaseURL.path.withCString {
            // No `NOFOLLOW`: the server opens the same path with `sqlite3
            // -readonly`, which follows links, and the two must read one file.
            sqlite3_open_v2($0, &opened, sqliteOpenReadOnly | sqliteOpenFullMutex, nil)
        }
        guard result == sqliteOK, let connection = opened else {
            if opened != nil { _ = sqlite3_close_v2(opened) }
            throw MessagesHistoryReadError.openFailed(code: result)
        }
        defer { _ = sqlite3_close_v2(connection) }
        _ = sqlite3_busy_timeout(connection, busyTimeoutMilliseconds)

        var members: [Int64: [String]] = [:]
        try each(connection, """
            SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id;
            """) { row in
            guard let address = text(row, 1) else { return }
            members[sqlite3_column_int64(row, 0), default: []].append(address)
        }
        var conversations: [MessagesConversation] = []
        // Newest message first; a conversation this Mac keeps no message of
        // comes after, by when it was last read, then newest first as filed.
        try each(connection, """
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style,
                   (SELECT max(j.message_date) FROM chat_message_join j WHERE j.chat_id = c.ROWID) AS last
            FROM chat c
            ORDER BY last IS NULL, last DESC, c.last_read_message_timestamp DESC, c.ROWID DESC;
            """) { row in
            guard let guid = text(row, 1) else { return }
            let name = text(row, 3).flatMap { $0.isEmpty ? nil : $0 }
            let last = sqlite3_column_type(row, 5) == sqliteNull ? nil : date(sqlite3_column_int64(row, 5))
            conversations.append(MessagesConversation(
                guid: guid, identifier: text(row, 2) ?? "", displayName: name,
                // 43 is how Messages files a group; 45 a conversation with one person.
                isGroup: sqlite3_column_int64(row, 4) == 43, lastMessageAt: last,
                memberAddresses: (members[sqlite3_column_int64(row, 0)] ?? []).sorted()))
        }
        return conversations
    }

    /// Messages writes dates as time since 1 January 2001, in nanoseconds on
    /// every recent macOS and in seconds on older ones; the two are told apart
    /// by size, as the server does.
    static func date(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? Double(value) / 1_000_000_000 : Double(value)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func text(_ row: SQLiteStatement, _ column: Int32) -> String? {
        guard sqlite3_column_type(row, column) != sqliteNull, let bytes = sqlite3_column_text(row, column) else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func each(_ connection: SQLiteConnection, _ sql: String,
                             _ body: (SQLiteStatement) throws -> Void) throws {
        var prepared: SQLiteStatement?
        guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == sqliteOK, let statement = prepared else {
            let message = sqlite3_errmsg(connection).map { String(cString: $0) } ?? "unknown error"
            if prepared != nil { _ = sqlite3_finalize(prepared) }
            throw MessagesHistoryReadError.queryFailed(message: message)
        }
        defer { _ = sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == sqliteDone { return }
            guard step == sqliteRow else {
                throw MessagesHistoryReadError.queryFailed(
                    message: sqlite3_errmsg(connection).map { String(cString: $0) } ?? "unknown error")
            }
            try body(statement)
        }
    }
}
