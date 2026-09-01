import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence

struct SQLiteTeammateClaudeModelTests {
    @Test("Migration 15 preserves existing profile data, revisions, and prior migration checksums")
    func migrationPreservesExistingRows() async throws {
        let fixture = try ClaudeModelSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let checksums: [String]
        do {
            let store = try fixture.open()
            try await store.insert(original)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=14 ORDER BY version;")
                .map { try $0.text("checksum") }
            // Only this synthetic database is rolled back to the previous schema.
            _ = try await store.execute(sql: "ALTER TABLE teammates DROP COLUMN claude_model;")
            _ = try await store.execute(sql: "ALTER TABLE teammates DROP COLUMN claude_effort;")
            _ = try await store.execute(sql: "ALTER TABLE teammates DROP COLUMN claude_context_window;")
            _ = try await store.execute(sql: "ALTER TABLE teammate_profile_revisions DROP COLUMN claude_model;")
            _ = try await store.execute(sql: "ALTER TABLE teammate_profile_revisions DROP COLUMN claude_effort;")
            _ = try await store.execute(sql: "ALTER TABLE teammate_profile_revisions DROP COLUMN claude_context_window;")
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=15;")
        }
        let reopened = try fixture.open()
        let loaded = try #require(try await reopened.teammate(id: original.id))
        #expect(loaded == original)
        #expect(loaded.requestedClaudeModel == "sonnet")
        #expect(loaded.claudeEffort == nil)
        #expect(loaded.requestedClaudeEffort == "default")
        #expect(loaded.claudeContextWindow == nil)
        #expect(loaded.requestedClaudeContextWindow == "default")
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=14 ORDER BY version;")
            .map { try $0.text("checksum") } == checksums)
        let history = try await reopened.query(sql: "SELECT revision,claude_model,claude_effort,claude_context_window FROM teammate_profile_revisions;")
        #expect(history.count == 1)
        #expect(try history.first?.integer("revision") == 1)
        #expect(try history.first?.optionalText("claude_model") == nil)
        #expect(try history.first?.optionalText("claude_effort") == nil)
        #expect(try history.first?.optionalText("claude_context_window") == nil)
    }

    @Test("Unknown model values survive reopening, unrelated edits, search, and revision history")
    func unknownSelectionPersistsAcrossEveryProfileRead() async throws {
        let fixture = try ClaudeModelSQLiteFixture()
        defer { fixture.remove() }
        var original = try fixture.teammate()
        original.claudeModel = " Retired Model 🦉 "
        original.claudeEffort = " Retired Effort 🦉 "
        original.claudeContextWindow = " Retired Context 🦉 "
        do {
            let store = try fixture.open()
            try await store.insert(original)
            let conversation = try Conversation(id: ConversationID(UUID()), kind: .direct(teammateID: original.id),
                createdAt: original.createdAt, updatedAt: original.updatedAt)
            try await store.insert(conversation, participantIDs: [original.id])
            let service = TeammateProfileService(repository: store)
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "Model QA renamed", role: "Research"))
        }
        let reopened = try fixture.open()
        let loaded = try #require(try await reopened.teammate(id: original.id))
        #expect(loaded.claudeModel == original.claudeModel)
        #expect(loaded.claudeEffort == original.claudeEffort)
        #expect(loaded.claudeContextWindow == original.claudeContextWindow)
        #expect(loaded.profile.revision == 2)
        #expect(try await reopened.listTeammates(includingArchived: true).first?.claudeModel == original.claudeModel)
        #expect(try await reopened.listTeammates(includingArchived: true).first?.claudeEffort == original.claudeEffort)
        #expect(try await reopened.listTeammates(includingArchived: true).first?.claudeContextWindow == original.claudeContextWindow)
        let search = try await reopened.search(ConversationSearchRequest(query: "renamed"))
        #expect(search.teammates.first?.teammate.claudeModel == original.claudeModel)
        #expect(search.teammates.first?.teammate.claudeEffort == original.claudeEffort)
        #expect(search.teammates.first?.teammate.claudeContextWindow == original.claudeContextWindow)
        #expect(try await reopened.query(sql: "SELECT claude_model FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_model") } == [original.claudeModel, original.claudeModel])
        #expect(try await reopened.query(sql: "SELECT claude_effort FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_effort") } == [original.claudeEffort, original.claudeEffort])
        #expect(try await reopened.query(sql: "SELECT claude_context_window FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_context_window") } == [original.claudeContextWindow, original.claudeContextWindow])
    }

    @Test("Competing model edits use profile CAS and persist exactly one winning selection")
    func competingSelectionsPreserveWinner() async throws {
        let fixture = try ClaudeModelSQLiteFixture()
        defer { fixture.remove() }
        let original = try fixture.teammate()
        let first = try fixture.open()
        try await first.insert(original)
        let second = try fixture.open()
        var winning = original
        winning.claudeModel = "opus"
        winning.claudeEffort = "max"
        winning.claudeContextWindow = "long"
        winning.profile = try original.profile.revised()
        var stale = original
        stale.claudeModel = "haiku"
        stale.claudeEffort = "default"
        stale.claudeContextWindow = "standard"
        stale.profile = try original.profile.revised()
        try await first.update(winning, expectedProfileRevision: 1)
        await #expect(throws: RepositoryError.optimisticLockFailed(entity: "teammate", id: original.id.persistedValue)) {
            try await second.update(stale, expectedProfileRevision: 1)
        }
        let reopened = try fixture.open()
        #expect(try await reopened.teammate(id: original.id) == winning)
        #expect(try await reopened.query(sql: "SELECT claude_model FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_model") } == [nil, "opus"])
        #expect(try await reopened.query(sql: "SELECT claude_effort FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_effort") } == [nil, "max"])
        #expect(try await reopened.query(sql: "SELECT claude_context_window FROM teammate_profile_revisions ORDER BY revision;")
            .map { try $0.optionalText("claude_context_window") } == [nil, "long"])
    }

    @Test("Explicit effort reset persists per bot across reopen with its profile revision")
    func explicitEffortDefaultResetPersistsPerBot() async throws {
        let fixture = try ClaudeModelSQLiteFixture()
        defer { fixture.remove() }
        var original = try fixture.teammate()
        original.claudeEffort = "max"
        original.claudeContextWindow = "long"
        var other = try fixture.teammate()
        other.claudeEffort = "low"
        other.claudeContextWindow = "standard"
        do {
            let store = try fixture.open()
            try await store.insert(original)
            try await store.insert(other)
            let service = TeammateProfileService(repository: store)
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: original.profile.displayName,
                    role: original.profile.role, claudeModel: "claude-opus-5", claudeEffort: "default", claudeContextWindow: "default"))
        }
        let reopened = try fixture.open()
        let saved = try #require(try await reopened.teammate(id: original.id))
        #expect(saved.claudeModel == "claude-opus-5")
        #expect(saved.claudeEffort == "default")
        #expect(saved.claudeContextWindow == "default")
        #expect(saved.profile.revision == 2)
        #expect(try await reopened.teammate(id: other.id) == other)
        #expect(try await reopened.query(sql: "SELECT claude_effort FROM teammate_profile_revisions WHERE teammate_id=? ORDER BY revision;",
            bindings: [.text(original.id.persistedValue)]).map { try $0.optionalText("claude_effort") } == ["max", "default"])
        #expect(try await reopened.query(sql: "SELECT claude_context_window FROM teammate_profile_revisions WHERE teammate_id=? ORDER BY revision;",
            bindings: [.text(original.id.persistedValue)]).map { try $0.optionalText("claude_context_window") } == ["long", "default"])
    }
}

private struct ClaudeModelSQLiteFixture {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-choice-\(UUID().uuidString).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("OpenBots.sqlite"),
            protection: .ordinarySQLite(decision: receipt)))
    }
    func teammate() throws -> Teammate {
        let now = Date(timeIntervalSince1970: 1_000)
        return try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Model QA", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
                silhouette: "round", paletteToken: "sky", eyeDialect: "calm", nonColorIdentityCue: "crown",
                accessibleIdentityDescription: "Round creature"), createdAt: now, updatedAt: now)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
