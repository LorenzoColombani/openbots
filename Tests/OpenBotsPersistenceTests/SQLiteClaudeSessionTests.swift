import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

/// One Claude session per bot and
/// conversation, kept in the app-owned database so a bot away for a day still
/// continues the same session, and dropped when the CLI no longer has it.
@Suite("Claude sessions kept in the app-owned database")
struct SQLiteClaudeSessionTests {
    @Test("A stored session comes back after a real reopen, is replaced whole, and clears without touching another")
    func roundTripThroughReopen() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClaudeSession-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(
                fileURL: directory.appendingPathComponent("control.sqlite"),
                protection: .ordinarySQLite(decision: protection)))
        }
        let conversation = ConversationID(UUID()), other = ConversationID(UUID()), bot = TeammateID(UUID())
        let first = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_000),
                                        lastUsedAt: Date(timeIntervalSince1970: 4_100))
        let elsewhere = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_200),
                                            lastUsedAt: Date(timeIntervalSince1970: 4_200))
        weak var closed: SQLiteStore?
        do {
            let store = try open(); closed = store
            #expect(try await store.storedClaudeSession(conversationID: conversation, teammateID: bot) == nil)
            try await store.storeClaudeSession(first, conversationID: conversation, teammateID: bot)
            try await store.storeClaudeSession(elsewhere, conversationID: other, teammateID: bot)
        }
        #expect(closed == nil)
        do {
            let reopened = try open(); closed = reopened
            #expect(try await reopened.storedClaudeSession(conversationID: conversation, teammateID: bot) == first)
            let touched = StoredClaudeSession(sessionID: first.sessionID, startedAt: first.startedAt,
                                              lastUsedAt: Date(timeIntervalSince1970: 9_000))
            try await reopened.storeClaudeSession(touched, conversationID: conversation, teammateID: bot)
            #expect(try await reopened.storedClaudeSession(conversationID: conversation, teammateID: bot) == touched)
            try await reopened.clearClaudeSession(conversationID: conversation, teammateID: bot)
            #expect(try await reopened.storedClaudeSession(conversationID: conversation, teammateID: bot) == nil)
            #expect(try await reopened.storedClaudeSession(conversationID: other, teammateID: bot) == elsewhere)
            // Clearing what is not there is not an error.
            try await reopened.clearClaudeSession(conversationID: conversation, teammateID: bot)
        }
        #expect(closed == nil)
    }

    /// The refused mark is kept
    /// through a reopen, and a row written before it existed reads as not
    /// refused rather than as no session.
    @Test("A refused session keeps its mark through a reopen, and a row written before the mark reads as not refused")
    func theRefusedMarkRoundTrips() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClaudeSessionMark-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(
                fileURL: directory.appendingPathComponent("control.sqlite"),
                protection: .ordinarySQLite(decision: protection)))
        }
        let conversation = ConversationID(UUID()), older = ConversationID(UUID()), bot = TeammateID(UUID())
        let refused = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_000),
                                          lastUsedAt: Date(timeIntervalSince1970: 4_100), isRefused: true)
        let olderID = UUID()
        do {
            let store = try open()
            try await store.storeClaudeSession(refused, conversationID: conversation, teammateID: bot)
            // Exactly what the build before the mark wrote.
            _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?);", bindings: [
                .text("claude_session_v1.\(older.persistedValue).\(bot.persistedValue)"),
                .text("{\"lastUsedAt\":4300,\"sessionID\":\"\(olderID.uuidString)\",\"startedAt\":4200}")])
        }
        let reopened = try open()
        #expect(try await reopened.storedClaudeSession(conversationID: conversation, teammateID: bot) == refused)
        let old = try #require(try await reopened.storedClaudeSession(conversationID: older, teammateID: bot))
        #expect(old.sessionID == olderID && !old.isRefused)
    }

    @Test("A bot's sessions list across its conversations, and never another bot's")
    func sessionsOfOneBot() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClaudeSessions-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        let store = try SQLiteStore(configuration: SQLiteStoreConfiguration(
            fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
        let bot = TeammateID(UUID()), otherBot = TeammateID(UUID())
        let chat = ConversationID(UUID()), team = ConversationID(UUID()), elsewhere = ConversationID(UUID())
        let inChat = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_000),
                                         lastUsedAt: Date(timeIntervalSince1970: 4_100))
        let inTeam = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_200),
                                         lastUsedAt: Date(timeIntervalSince1970: 4_300))
        let othersOwn = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_400),
                                            lastUsedAt: Date(timeIntervalSince1970: 4_500))
        #expect(try await store.storedClaudeSessions(teammateID: bot).isEmpty)
        try await store.storeClaudeSession(inChat, conversationID: chat, teammateID: bot)
        try await store.storeClaudeSession(inTeam, conversationID: team, teammateID: bot)
        try await store.storeClaudeSession(othersOwn, conversationID: elsewhere, teammateID: otherBot)
        let expected = [StoredClaudeSessionRecord(conversationID: chat, session: inChat),
                        StoredClaudeSessionRecord(conversationID: team, session: inTeam)]
        let listed = try await store.storedClaudeSessions(teammateID: bot)
        #expect(listed.sorted { $0.conversationID.persistedValue < $1.conversationID.persistedValue }
            == expected.sorted { $0.conversationID.persistedValue < $1.conversationID.persistedValue })
        #expect(try await store.storedClaudeSessions(teammateID: otherBot)
            == [StoredClaudeSessionRecord(conversationID: elsewhere, session: othersOwn)])
        #expect(try await store.storedClaudeSessions(teammateID: TeammateID(UUID())).isEmpty)
    }
@Test("The digest of the prompt a session started with comes back whole, and a row written before the digest reads as having none")
    func promptDigestRoundTripsAndOlderRowsHaveNone() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextClaudeSessionDigest-\(UUID()).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        func open() throws -> SQLiteStore {
            try SQLiteStore(configuration: SQLiteStoreConfiguration(
                fileURL: directory.appendingPathComponent("control.sqlite"),
                protection: .ordinarySQLite(decision: protection)))
        }
        let conversation = ConversationID(UUID()), older = ConversationID(UUID()), bot = TeammateID(UUID())
        // The CLI keeps the first turn's prompt for the whole session, so the
        // session remembers which prompt that was: SHA-256 hex.
        let digest = String(repeating: "7b", count: 32)
        let session = StoredClaudeSession(sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 4_000),
                                          lastUsedAt: Date(timeIntervalSince1970: 4_100), systemPromptDigest: digest)
        let olderID = UUID()
        do {
            let store = try open()
            try await store.storeClaudeSession(session, conversationID: conversation, teammateID: bot)
            // A row the build before this one wrote: the same JSON, no digest.
            _ = try await store.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?);", bindings: [
                .text("claude_session_v1.\(older.persistedValue).\(bot.persistedValue)"),
                .text("{\"lastUsedAt\":4100,\"sessionID\":\"\(olderID.uuidString)\",\"startedAt\":4000}")])
        }
        let reopened = try open()
        let read = try #require(try await reopened.storedClaudeSession(conversationID: conversation, teammateID: bot))
        #expect(read == session && read.systemPromptDigest == digest)
        let legacy = try #require(try await reopened.storedClaudeSession(conversationID: older, teammateID: bot))
        #expect(legacy.sessionID == olderID && legacy.systemPromptDigest == nil)
    }
}
