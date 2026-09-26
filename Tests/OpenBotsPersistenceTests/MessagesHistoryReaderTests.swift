import CryptoKit
import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import Testing

/// The four tables the chat picker reads, as `.schema` printed them from a
/// real chat.db (definitions only; the server's
/// suite, `AppleMessagesScriptTests`, carries the same text and the message
/// table). Triggers are left out.
private let pickerSchema = """
PRAGMA journal_mode=WAL;
CREATE TABLE handle (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, id TEXT NOT NULL, country TEXT,
    service TEXT NOT NULL, uncanonicalized_id TEXT, person_centric_id TEXT, UNIQUE (id, service)
);
CREATE TABLE chat (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER,
    state INTEGER, account_id TEXT, properties BLOB, chat_identifier TEXT, service_name TEXT,
    room_name TEXT, account_login TEXT, is_archived INTEGER DEFAULT 0, last_addressed_handle TEXT,
    display_name TEXT, group_id TEXT, is_filtered INTEGER, successful_query INTEGER,
    engram_id TEXT, server_change_token TEXT, ck_sync_state INTEGER DEFAULT 0,
    original_group_id TEXT, last_read_message_timestamp INTEGER DEFAULT 0, cloudkit_record_id TEXT,
    last_addressed_sim_id TEXT, is_blackholed INTEGER DEFAULT 0,
    syndication_date INTEGER DEFAULT 0, syndication_type INTEGER DEFAULT 0,
    is_recovered INTEGER DEFAULT 0, is_deleting_incoming_messages INTEGER DEFAULT 0,
    is_pending_review INTEGER DEFAULT 0
);
CREATE TABLE chat_message_join (
    chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
    message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, message_date INTEGER DEFAULT 0,
    index_state INTEGER NOT NULL DEFAULT 0, filter_action INTEGER NOT NULL DEFAULT 0,
    filter_sub_action INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (chat_id, message_id)
);
CREATE TABLE chat_handle_join (
    chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
    handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE, UNIQUE(chat_id, handle_id)
);
"""

private func literal(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

/// Apple nanoseconds for a moment `secondsAgo` before now, as real messages are dated.
private func appleNanoseconds(_ secondsAgo: Double) -> Int64 {
    Int64((Date().timeIntervalSinceReferenceDate - secondsAgo) * 1_000_000_000)
}

private struct HistoryFixture {
    let root: URL
    let database: URL

    init(sql: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-messages-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appendingPathComponent("chat.db")
        try Self.run(database: database, sql: pickerSchema + sql)
    }

    static func run(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && complaint.isEmpty, Comment(rawValue: complaint))
    }

    func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func remove() {
        try? FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: database.path)
        try? FileManager().removeItem(at: root)
    }
}

@Suite("Listing the user's Messages conversations for the chat picker")
struct MessagesHistoryReaderTests {
    @Test("Every conversation, by its exact guid, newest message first, groups with their name and members")
    func everyConversationNewestFirst() throws {
        let fixture = try HistoryFixture(sql: """
            INSERT INTO handle(ROWID, id, service) VALUES (1, '+33612345678', 'iMessage'), (2, '+14155550100', 'iMessage'),
                (3, 'Carrier Info', 'SMS');
            INSERT INTO chat(ROWID, guid, chat_identifier, style, display_name, last_read_message_timestamp) VALUES
                (1, 'any;-;+33612345678', '+33612345678', 45, NULL, 0),
                (2, 'any;+;chat123456789012345678', 'chat123456789012345678', 43, 'Family', 0),
                (3, \(literal("any;-;Carrier Info")), 'Carrier Info', 45, '', 0),
                (4, \(literal("any;-;L'Atelier")), \(literal("L'Atelier")), 45, NULL, 900),
                (5, 'any;-;caf\u{E9}', 'caf\u{E9}', 45, NULL, 100);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (2, 1), (3, 3);
            INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES
                (1, 1, \(appleNanoseconds(300))), (2, 2, \(appleNanoseconds(60))), (2, 3, \(appleNanoseconds(600))),
                (3, 4, \(Int64(Date().timeIntervalSinceReferenceDate - 7_200)));
            """)
        defer { fixture.remove() }
        let listed = try MessagesHistoryReader.conversations(databaseURL: fixture.database)
        // Newest message first (the seconds-dated one last of those with a
        // message), then those with none by when they were last read.
        #expect(listed.map(\.guid) == ["any;+;chat123456789012345678", "any;-;+33612345678", "any;-;Carrier Info",
                                       "any;-;L'Atelier", "any;-;caf\u{E9}"])
        let family = try #require(listed.first)
        #expect(family.isGroup && family.displayName == "Family")
        #expect(family.memberAddresses == ["+14155550100", "+33612345678"])
        #expect(abs((family.lastMessageAt?.timeIntervalSinceNow ?? 0) + 60) < 5)
        let free = listed[2]
        #expect(!free.isGroup && free.displayName == nil && free.identifier == "Carrier Info")
        #expect(abs((free.lastMessageAt?.timeIntervalSinceNow ?? 0) + 7_200) < 5)
        #expect(listed[3].lastMessageAt == nil && listed[3].memberAddresses.isEmpty)
        #expect(listed.allSatisfy { AppleMessagesChatScope.isChoosable($0.guid) })
    }

    /// Messages writes to its history while the picker reads it, and the newest
    /// conversations sit in the write-ahead log until Messages checkpoints it.
    @Test("A conversation still in the write-ahead log of a history Messages holds open is listed")
    func aConversationInTheLiveLogIsListed() throws {
        let fixture = try HistoryFixture(sql: "")
        defer { fixture.remove() }
        var writer: SQLiteConnection?
        #expect(sqlite3_open_v2(fixture.database.path, &writer, sqliteOpenReadWrite, nil) == sqliteOK)
        defer { _ = sqlite3_close_v2(writer) }
        #expect(sqlite3_exec(writer, """
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO chat(guid, chat_identifier, style) VALUES ('any;-;+33700000001', '+33700000001', 45);
            """, nil, nil, nil) == sqliteOK)
        let log = fixture.database.path + "-wal"
        let logSize = (try FileManager().attributesOfItem(atPath: log)[.size] as? NSNumber)?.intValue ?? 0
        #expect(logSize > 0)
        let listed = try MessagesHistoryReader.conversations(databaseURL: fixture.database)
        #expect(listed.map(\.guid) == ["any;-;+33700000001"])
    }

    @Test("Listing writes nothing to the history")
    func listingWritesNothing() throws {
        let fixture = try HistoryFixture(sql: """
            INSERT INTO chat(guid, chat_identifier, style) VALUES ('any;-;+33612345678', '+33612345678', 45);
            """)
        defer { fixture.remove() }
        // The history and its log. The `-shm` is SQLite's shared index, where
        // every reader, the server's `sqlite3 -readonly` included, marks what it
        // is reading; Messages rewrites it all day.
        let files = ["", "-wal"].map { URL(fileURLWithPath: fixture.database.path + $0) }
        let before = try files.map(fixture.digest)
        _ = try MessagesHistoryReader.conversations(databaseURL: fixture.database)
        _ = try MessagesHistoryReader.conversations(databaseURL: fixture.database)
        #expect(try files.map(fixture.digest) == before)
        #expect(!FileManager().fileExists(atPath: fixture.database.path + "-journal"))
    }

    @Test("A history that is missing or refused is an error, never an empty list")
    func aRefusedHistoryIsAnError() throws {
        let fixture = try HistoryFixture(sql: "")
        defer { fixture.remove() }
        #expect(throws: MessagesHistoryReadError.self) {
            try MessagesHistoryReader.conversations(databaseURL: fixture.root.appendingPathComponent("absent.db"))
        }
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))],
                                        ofItemAtPath: fixture.database.path)
        #expect(throws: MessagesHistoryReadError.self) {
            try MessagesHistoryReader.conversations(databaseURL: fixture.database)
        }
    }
}
