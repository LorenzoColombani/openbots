import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
@testable import OpenBotsServices
import Testing

/// Session retention: a kept session leaves the CLI's transcript and history
/// lines under the app profile, so dropping a stored session removes those
/// files before its row goes. Archiving a bot drops every session it had.
@Suite("Saved Claude sessions dropped with the bot")
struct ClaudeSessionRetentionTests {
    @Test("Archiving a bot drops every saved session of that bot, files then rows, and leaves another bot's alone")
    func archiveDropsTheBotsSessions() async throws {
        let f = try RetentionFixture(); defer { f.remove() }
        let store = try f.open()
        let pillow = try await f.seedBot(store, name: "Pillow")
        let zed = try await f.seedBot(store, name: "Zed")
        let first = StoredClaudeSession(sessionID: UUID(), startedAt: f.date, lastUsedAt: f.at(10))
        let second = StoredClaudeSession(sessionID: UUID(), startedAt: f.at(20), lastUsedAt: f.at(30))
        let zeds = StoredClaudeSession(sessionID: UUID(), startedAt: f.at(40), lastUsedAt: f.at(50))
        let secondConversation = ConversationID(UUID())
        try await store.storeClaudeSession(first, conversationID: pillow.conversationID, teammateID: pillow.id)
        try await store.storeClaudeSession(second, conversationID: secondConversation, teammateID: pillow.id)
        try await store.storeClaudeSession(zeds, conversationID: zed.conversationID, teammateID: zed.id)
        try f.transcript(first.sessionID, in: "-Users-someone-Bots-Pillow")
        try f.transcript(second.sessionID, in: "-Users-someone-Bots-Pillow-Work-noindex")
        try f.transcript(zeds.sessionID, in: "-Users-someone-Bots-Zed")
        try f.writeHistory([f.historyLine(first.sessionID), f.historyLine(zeds.sessionID), f.historyLine(second.sessionID)])

        let service = TeammateArchiveService(repository: store, clock: RetentionClock(date: f.at(60)),
            sessionRetention: ClaudeSessionRetentionService(sessions: store, profileURL: f.profile))
        let archived = try await service.archiveTeammate(id: pillow.id, expectedProfileRevision: pillow.profileRevision)

        #expect(archived.lifecycle == .archived)
        #expect(try await store.storedClaudeSessions(teammateID: pillow.id).isEmpty)
        #expect(try await store.storedClaudeSession(conversationID: zed.conversationID, teammateID: zed.id) == zeds)
        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: f.profile, sessionID: first.sessionID))
        #expect(!ClaudeSessionTranscriptLocator.exists(profileURL: f.profile, sessionID: second.sessionID))
        #expect(ClaudeSessionTranscriptLocator.exists(profileURL: f.profile, sessionID: zeds.sessionID))
        #expect(try f.history() == [f.historyLine(zeds.sessionID)])
    }

    @Test("A session whose files cannot be removed keeps its row for a later drop; the archive still completes")
    func failedRemovalKeepsTheRow() async throws {
        let f = try RetentionFixture(); defer { f.remove() }
        let store = try f.open()
        let pillow = try await f.seedBot(store, name: "Pillow")
        let removable = StoredClaudeSession(sessionID: UUID(), startedAt: f.date, lastUsedAt: f.at(10))
        let stuck = StoredClaudeSession(sessionID: UUID(), startedAt: f.at(20), lastUsedAt: f.at(30))
        let stuckConversation = ConversationID(UUID())
        try await store.storeClaudeSession(removable, conversationID: pillow.conversationID, teammateID: pillow.id)
        try await store.storeClaudeSession(stuck, conversationID: stuckConversation, teammateID: pillow.id)
        let retention = ClaudeSessionRetentionService(sessions: store, profileURL: f.profile) { _, id in
            if id == stuck.sessionID { throw CocoaError(.fileWriteNoPermission) }
            return ClaudeSessionTranscriptRemoval(removedPaths: ["/fixture/\(id.uuidString.lowercased()).jsonl"], droppedHistoryLines: 1)
        }
        let report = try await retention.dropSessions(teammateID: pillow.id)
        #expect(report.dropped.map(\.record) == [StoredClaudeSessionRecord(conversationID: pillow.conversationID, session: removable)])
        #expect(report.dropped.map(\.removal.droppedHistoryLines) == [1])
        #expect(report.kept == [StoredClaudeSessionRecord(conversationID: stuckConversation, session: stuck)])
        #expect(try await store.storedClaudeSessions(teammateID: pillow.id)
            == [StoredClaudeSessionRecord(conversationID: stuckConversation, session: stuck)])

        let service = TeammateArchiveService(repository: store, clock: RetentionClock(date: f.at(60)), sessionRetention: retention)
        let archived = try await service.archiveTeammate(id: pillow.id, expectedProfileRevision: pillow.profileRevision)
        #expect(archived.lifecycle == .archived)
        #expect(try await store.storedClaudeSessions(teammateID: pillow.id)
            == [StoredClaudeSessionRecord(conversationID: stuckConversation, session: stuck)])
    }
}

extension ClaudeSessionRetentionTests {
    /// End to end over the real locator: a project folder that cannot be read used to look empty, so the
    /// drop cleared the row and left the transcript with nothing naming it.
    @Test("A session whose project folder cannot be read keeps its row, over the real locator")
    func anUnreadableProjectFolderKeepsTheRow() async throws {
        let f = try RetentionFixture(); defer { f.remove() }
        let store = try f.open()
        let pillow = try await f.seedBot(store, name: "Pillow")
        let session = StoredClaudeSession(sessionID: UUID(), startedAt: f.date, lastUsedAt: f.at(10))
        try await store.storeClaudeSession(session, conversationID: pillow.conversationID, teammateID: pillow.id)
        try f.transcript(session.sessionID, in: "-Users-someone-Bots-Pillow")
        let folder = f.profile.appendingPathComponent("projects/-Users-someone-Bots-Pillow", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        let report = try await ClaudeSessionRetentionService(sessions: store, profileURL: f.profile)
            .dropSessions(teammateID: pillow.id)

        #expect(report.dropped.isEmpty)
        #expect(report.kept == [StoredClaudeSessionRecord(conversationID: pillow.conversationID, session: session)])
        #expect(try await store.storedClaudeSession(conversationID: pillow.conversationID, teammateID: pillow.id) == session)
    }
}

private struct RetentionClock: OpenBotsClock {
    let date: Date
    func now() -> Date { date }
}

private struct SeededBot {
    let id: TeammateID
    let conversationID: ConversationID
    let profileRevision: UInt64
}

private struct RetentionFixture: Sendable {
    let root: URL
    let profile: URL
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextSessionRetention-\(UUID()).noindex", isDirectory: true)
        profile = root.appendingPathComponent("CLIProfile", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func at(_ seconds: TimeInterval) -> Date { date.addingTimeInterval(seconds) }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }

    func seedBot(_ store: SQLiteStore, name: String) async throws -> SeededBot {
        let id = TeammateID(UUID()), conversationID = ConversationID(UUID())
        let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature with a crest"),
            createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: conversationID, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
        return SeededBot(id: id, conversationID: conversationID, profileRevision: teammate.profile.revision)
    }

    var historyURL: URL { profile.appendingPathComponent("history.jsonl") }

    func transcript(_ id: UUID, in slug: String) throws {
        let folder = profile.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = id.uuidString.lowercased()
        let line = "{\"type\":\"user\",\"sessionId\":\"\(session)\",\"cwd\":\"\(folder.path)\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}\n"
        try Data(line.utf8).write(to: folder.appendingPathComponent(session + ".jsonl"))
    }

    func historyLine(_ id: UUID) -> String {
        "{\"display\":\"Hello\",\"pastedContents\":{},\"timestamp\":1789440900000,\"project\":\"/Users/someone/Bots\",\"sessionId\":\"\(id.uuidString.lowercased())\"}"
    }

    func writeHistory(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: historyURL)
    }

    func history() throws -> [String] {
        try String(contentsOf: historyURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}
