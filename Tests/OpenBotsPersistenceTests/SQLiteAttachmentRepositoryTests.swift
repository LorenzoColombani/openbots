import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsPersistence

@Suite("Durable conversation attachment storage")
struct SQLiteAttachmentRepositoryTests {
    @Test("Concurrent additive staging through separate connections cannot lose either attachment")
    func concurrentAdditions() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let firstStore = try fixture.open()
        let secondStore = try fixture.open()
        try await fixture.seed(firstStore)
        let first = try fixture.asset(name: "first.txt")
        let second = try fixture.asset(name: "second.txt")
        async let firstStage = firstStore.stage(first)
        async let secondStage = secondStore.stage(second)
        let outcomes = try await [firstStage, secondStage]
        #expect(Set(outcomes.map(\.revision)) == [1, 2])
        let result = try await firstStore.draft(conversationID: fixture.conversationID)
        #expect(result.revision == 2)
        #expect(Set(result.attachments.map(\.id)) == [first.id, second.id])
        #expect(try await secondStore.draft(conversationID: fixture.conversationID) == result)
    }

    @Test("Ordered attachment drafts survive reopen with exact immutable metadata and protected files")
    func reopenAndPermissions() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let first = try fixture.asset(name: "first.pdf")
        let second = try fixture.asset(name: "second.txt")
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            #expect(try await store.draft(conversationID: fixture.conversationID) == AttachmentDraftSnapshot(conversationID: fixture.conversationID, revision: 0, attachments: []))
            #expect(try await store.stage(first).revision == 1)
            let snapshot = try await store.stage(second)
            #expect(snapshot.revision == 2 && snapshot.attachments == [first, second])
            for suffix in ["", "-wal", "-shm"] {
                let attributes = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path + suffix)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
        }
        let reopened = try fixture.open()
        let snapshot = try await reopened.draft(conversationID: fixture.conversationID)
        #expect(snapshot.revision == 2 && snapshot.attachments == [first, second])
        #expect(try await reopened.attachment(id: first.id, conversationID: fixture.conversationID) == first)
        let columns = try await reopened.query(sql: "PRAGMA table_info(attachment_assets);")
        #expect(try columns.map { try $0.text("name") } == ["id", "conversation_id", "display_name", "type_identifier", "byte_count", "sha256", "created_at"])
    }

    @Test("Exact stage/remove retries are idempotent and never resurrect removed draft links")
    func idempotentReceipts() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        let staged = try await store.stage(asset)
        #expect(try await store.stage(asset) == staged)
        let collision = try fixture.asset(id: asset.id, name: "renamed.txt")
        await #expect(throws: AttachmentRepositoryError.assetCollision) { try await store.stage(collision) }
        let removed = try await store.removeDraftAttachment(id: asset.id, conversationID: fixture.conversationID)
        #expect(removed.revision == 2 && removed.attachments.isEmpty)
        #expect(try await store.removeDraftAttachment(id: asset.id, conversationID: fixture.conversationID) == removed)
        #expect(try await store.removeDraftAttachment(id: AttachmentID(UUID()), conversationID: fixture.conversationID) == removed)
        #expect(try await store.stage(asset) == removed)
        #expect(try await store.attachment(id: asset.id, conversationID: fixture.conversationID) == nil)
        #expect(try await store.query(sql: "SELECT count(*) AS count FROM attachment_assets;").first?.integer("count") == 1)
    }

    @Test("Sending a captured subset atomically preserves later additions and the text draft")
    func consumeCapturedOnly() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let first = try fixture.asset(name: "first.txt")
        let second = try fixture.asset(name: "second.txt")
        let later = try fixture.asset(name: "later.txt")
        _ = try await store.stage(first)
        _ = try await store.stage(second)
        let captured = [first.id, second.id]
        _ = try await store.stage(later)
        let draft = try await store.saveDraft(conversationID: fixture.conversationID, text: "newer untouched text", expectedRevision: 0, updatedAt: fixture.date)
        let pair = try fixture.exchange(ids: captured)
        try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: captured)
        let after = try await store.draft(conversationID: fixture.conversationID)
        #expect(after.revision == 4 && after.attachments == [later])
        #expect(try await store.message(id: pair.user.id) == pair.user)
        #expect(try await store.message(id: pair.reply.id) == pair.reply)
        #expect(try await store.attachment(id: first.id, conversationID: fixture.conversationID) == first)
        #expect(try await store.loadDraft(conversationID: fixture.conversationID) == draft)
        #expect(try await store.stage(first) == after)
        await #expect(throws: AttachmentRepositoryError.draftItemMissing) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: captured)
        }
        let reopened = try fixture.open()
        #expect(try await reopened.draft(conversationID: fixture.conversationID) == after)
        #expect(try await reopened.attachment(id: second.id, conversationID: fixture.conversationID) == second)
    }

    @Test("A failed reply append rolls back the user message, index updates and attachment consumption")
    func exchangeRollback() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        let before = try await store.stage(asset)
        let pair = try fixture.exchange(ids: [asset.id])
        _ = try await store.execute(sql: "CREATE TRIGGER reject_fixture_reply BEFORE INSERT ON messages WHEN NEW.sequence=2 BEGIN SELECT RAISE(ABORT,'injected reply failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        }
        #expect(try await store.message(id: pair.user.id) == nil)
        #expect(try await store.message(id: pair.reply.id) == nil)
        #expect(try await store.draft(conversationID: fixture.conversationID) == before)
        #expect(try await store.search(ConversationSearchRequest(query: "attachmentfixture")).messages.isEmpty)
    }

    @Test("A normal local save persists one user message and only consumes its captured attachments")
    func localMessageCommitAndReopen() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let first = try fixture.asset(name: "first.txt")
        let later = try fixture.asset(name: "later.txt")
        _ = try await store.stage(first)
        _ = try await store.stage(later)
        let textDraft = try await store.saveDraft(conversationID: fixture.conversationID,
            text: "newer unsent draft", expectedRevision: 0, updatedAt: fixture.date)
        let message = try fixture.exchange(ids: [first.id], attachmentOnly: true).user
        try await store.commitLocalMessage(userMessage: message, expectedPreviousSequence: 0, attachmentIDs: [first.id])

        let reopened = try fixture.open()
        let page = try await reopened.page(conversationID: fixture.conversationID, request: PageRequest(limit: 10))
        #expect(page.elements == [message])
        #expect(page.elements.allSatisfy { $0.author == .user && $0.deliveryState == .completed })
        #expect(try await reopened.draft(conversationID: fixture.conversationID).attachments == [later])
        #expect(try await reopened.attachment(id: first.id, conversationID: fixture.conversationID) == first)
        #expect(try await reopened.loadDraft(conversationID: fixture.conversationID) == textDraft)
        await #expect(throws: AttachmentRepositoryError.draftItemMissing) {
            try await reopened.commitLocalMessage(userMessage: message, expectedPreviousSequence: 0, attachmentIDs: [first.id])
        }
        #expect(try await reopened.page(conversationID: fixture.conversationID, request: PageRequest(limit: 10)).elements == [message])
    }

    @Test("A normal attachment-consumption failure rolls back its message, search row, and draft revision")
    func localMessageCommitRollback() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        let before = try await store.stage(asset)
        let message = try fixture.exchange(ids: [asset.id]).user
        _ = try await store.execute(sql: "CREATE TRIGGER reject_local_consumption BEFORE DELETE ON conversation_draft_attachment_links BEGIN SELECT RAISE(ABORT,'injected local link failure'); END;")
        await #expect(throws: SQLiteStoreError.self) {
            try await store.commitLocalMessage(userMessage: message, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        }
        #expect(try await store.message(id: message.id) == nil)
        #expect(try await store.draft(conversationID: fixture.conversationID) == before)
        #expect(try await store.search(ConversationSearchRequest(query: "attachmentfixture")).messages.isEmpty)
    }

    @Test("Normal local saves reject foreign, unknown, non-user, and exhausted inputs without mutation")
    func localMessageBoundaryValidation() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.seed(store, teammateID: fixture.otherTeammateID, conversationID: fixture.otherConversationID)
        let foreign = try fixture.asset(conversationID: fixture.otherConversationID)
        _ = try await store.stage(foreign)
        let foreignMessage = try fixture.exchange(ids: [foreign.id]).user
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) {
            try await store.commitLocalMessage(userMessage: foreignMessage, expectedPreviousSequence: 0, attachmentIDs: [foreign.id])
        }
        let unknownID = AttachmentID(UUID())
        let unknownMessage = try fixture.exchange(ids: [unknownID]).user
        await #expect(throws: AttachmentRepositoryError.assetNotFound) {
            try await store.commitLocalMessage(userMessage: unknownMessage, expectedPreviousSequence: 0, attachmentIDs: [unknownID])
        }
        let pair = try fixture.exchange(ids: [])
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalMessage(userMessage: pair.reply, expectedPreviousSequence: 1, attachmentIDs: [])
        }
        await #expect(throws: AttachmentRepositoryError.sequenceExhausted) {
            try await store.commitLocalMessage(userMessage: pair.user, expectedPreviousSequence: Int64.max, attachmentIDs: [])
        }
        #expect(try await store.page(conversationID: fixture.conversationID, request: PageRequest(limit: 10)).elements.isEmpty)
        #expect(try await store.draft(conversationID: fixture.otherConversationID).attachments == [foreign])
    }

    @Test("Failed link registration cannot leave metadata or advance the draft revision")
    func stageRollback() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.execute(sql: "CREATE TRIGGER reject_attachment_link BEFORE INSERT ON conversation_draft_attachment_links BEGIN SELECT RAISE(ABORT,'injected link failure'); END;")
        await #expect(throws: SQLiteStoreError.self) { try await store.stage(fixture.asset()) }
        #expect(try await store.draft(conversationID: fixture.conversationID).revision == 0)
        #expect(try await store.query(sql: "SELECT count(*) AS count FROM attachment_assets;").first?.integer("count") == 0)
    }

    @Test("Unknown or another conversation's attachment cannot be appended, read or consumed")
    func ownerValidation() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await fixture.seed(store, teammateID: fixture.otherTeammateID, conversationID: fixture.otherConversationID)
        let foreign = try fixture.asset(conversationID: fixture.otherConversationID)
        _ = try await store.stage(foreign)
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) { try await store.attachment(id: foreign.id, conversationID: fixture.conversationID) }
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) { try await store.removeDraftAttachment(id: foreign.id, conversationID: fixture.conversationID) }
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) { try await store.stage(fixture.asset(id: foreign.id)) }
        let pair = try fixture.exchange(ids: [foreign.id])
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) { try await store.append(pair.user, expectedPreviousSequence: 0) }
        await #expect(throws: AttachmentRepositoryError.assetOwnerMismatch) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [foreign.id])
        }
        let unknown = try fixture.exchange(ids: [AttachmentID(UUID())])
        await #expect(throws: AttachmentRepositoryError.assetNotFound) { try await store.append(unknown.user, expectedPreviousSequence: 0) }
        #expect(try await store.message(id: pair.user.id) == nil)
        #expect(try await store.draft(conversationID: fixture.otherConversationID).attachments == [foreign])
    }

    @Test("Captured removals, duplicate IDs and mismatched message parts never partially send")
    func capturedValidation() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let first = try fixture.asset()
        let second = try fixture.asset()
        _ = try await store.stage(first)
        _ = try await store.stage(second)
        let duplicate = try fixture.exchange(ids: [first.id, first.id])
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalFixtureExchange(userMessage: duplicate.user, fixtureReply: duplicate.reply, expectedPreviousSequence: 0, attachmentIDs: [first.id, first.id])
        }
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalMessage(userMessage: duplicate.user, expectedPreviousSequence: 0, attachmentIDs: [first.id, first.id])
        }
        let pair = try fixture.exchange(ids: [first.id, second.id])
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [first.id])
        }
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalMessage(userMessage: pair.user, expectedPreviousSequence: 0, attachmentIDs: [first.id])
        }
        _ = try await store.removeDraftAttachment(id: first.id, conversationID: fixture.conversationID)
        await #expect(throws: AttachmentRepositoryError.draftItemMissing) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [first.id, second.id])
        }
        await #expect(throws: AttachmentRepositoryError.draftItemMissing) {
            try await store.commitLocalMessage(userMessage: pair.user, expectedPreviousSequence: 0, attachmentIDs: [first.id, second.id])
        }
        #expect(try await store.message(id: pair.user.id) == nil)
        #expect(try await store.draft(conversationID: fixture.conversationID).attachments == [second])
    }

    @Test("Frozen visible attachment order wins over reversed import completion order")
    func frozenOrderIsMessageOrder() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let firstSelected = try fixture.asset(name: "first selected.txt")
        let secondSelected = try fixture.asset(name: "second selected.txt")
        _ = try await store.stage(secondSelected)
        _ = try await store.stage(firstSelected)
        #expect(try await store.draft(conversationID: fixture.conversationID).attachments == [secondSelected, firstSelected])
        let ids = [firstSelected.id, secondSelected.id]
        let pair = try fixture.exchange(ids: ids, attachmentOnly: true)
        try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply,
                                                   expectedPreviousSequence: 0, attachmentIDs: ids)
        #expect(try await store.message(id: pair.user.id)?.parts.map(\.content) == ids.map(MessagePartContent.attachment))
        #expect(try await store.draft(conversationID: fixture.conversationID).attachments.isEmpty)
    }

    @Test("An attachment-only user message is valid while wrong reply identities are refused")
    func attachmentOnlyAndReplyIdentity() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        _ = try await store.stage(asset)
        let wrong = try fixture.exchange(ids: [asset.id], attachmentOnly: true, replyAuthor: .user)
        await #expect(throws: AttachmentRepositoryError.invalidExchange) {
            try await store.commitLocalFixtureExchange(userMessage: wrong.user, fixtureReply: wrong.reply, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        }
        let pair = try fixture.exchange(ids: [asset.id], attachmentOnly: true)
        try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        #expect(try await store.message(id: pair.user.id)?.parts.map(\.content) == [.attachment(asset.id)])
        #expect(try await store.draft(conversationID: fixture.conversationID).attachments.isEmpty)
    }

    @Test("The draft cap and revision overflow fail without losing previously staged records")
    func capAndOverflow() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        var assets: [AttachmentAsset] = []
        for _ in 0..<24 {
            let asset = try fixture.asset()
            _ = try await store.stage(asset)
            assets.append(asset)
        }
        await #expect(throws: AttachmentRepositoryError.draftLimitReached) { try await store.stage(fixture.asset()) }
        #expect(try await store.stage(assets[0]).revision == 24)
        _ = try await store.removeDraftAttachment(id: assets[0].id, conversationID: fixture.conversationID)
        _ = try await store.execute(sql: "UPDATE conversation_attachment_drafts SET revision=? WHERE conversation_id=?;", bindings: [.integer(Int64.max), .text(fixture.conversationID.persistedValue)])
        await #expect(throws: AttachmentRepositoryError.invalidRevision) { try await store.stage(fixture.asset()) }
        await #expect(throws: AttachmentRepositoryError.invalidRevision) { try await store.removeDraftAttachment(id: assets[1].id, conversationID: fixture.conversationID) }
        let pair = try fixture.exchange(ids: [assets[1].id])
        await #expect(throws: AttachmentRepositoryError.invalidRevision) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [assets[1].id])
        }
        #expect(try await store.draft(conversationID: fixture.conversationID).attachments.count == 23)
        #expect(try await store.message(id: pair.user.id) == nil)
    }

    @Test("Sequence exhaustion is rejected without integer overflow in either append path")
    func sequenceOverflow() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let pair = try fixture.exchange(ids: [])
        await #expect(throws: AttachmentRepositoryError.sequenceExhausted) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: Int64.max, attachmentIDs: [])
        }
        try await store.append(pair.user, expectedPreviousSequence: 0)
        _ = try await store.execute(sql: "UPDATE messages SET sequence=? WHERE id=?;", bindings: [.integer(Int64.max), .text(pair.user.id.persistedValue)])
        await #expect(throws: AttachmentRepositoryError.sequenceExhausted) { try await store.append(pair.reply, expectedPreviousSequence: Int64.max) }
        #expect(try await store.message(id: pair.reply.id) == nil)
    }

    @Test("Archived or detached direct-chat ownership is rechecked before every operation", arguments: ["teammate", "conversation", "participant", "hidden"])
    func staleOwner(kind: String) async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        _ = try await store.stage(asset)
        switch kind {
        case "teammate": _ = try await store.execute(sql: "UPDATE teammates SET lifecycle='archived';")
        case "conversation": _ = try await store.execute(sql: "UPDATE conversations SET lifecycle='archived';")
        case "participant": _ = try await store.execute(sql: "UPDATE conversation_participants SET left_at=2000;")
        default: _ = try await store.execute(sql: "UPDATE teammates SET is_hidden=1;")
        }
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) { try await store.draft(conversationID: fixture.conversationID) }
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) { try await store.stage(fixture.asset()) }
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) { try await store.removeDraftAttachment(id: asset.id, conversationID: fixture.conversationID) }
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) { try await store.attachment(id: asset.id, conversationID: fixture.conversationID) }
        let pair = try fixture.exchange(ids: [asset.id])
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) {
            try await store.commitLocalFixtureExchange(userMessage: pair.user, fixtureReply: pair.reply, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        }
        await #expect(throws: AttachmentRepositoryError.conversationUnavailable) {
            try await store.commitLocalMessage(userMessage: pair.user, expectedPreviousSequence: 0, attachmentIDs: [asset.id])
        }
    }

    @Test("Malformed stored attachment metadata and draft revisions fail closed")
    func malformedRows() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let asset = try fixture.asset()
        _ = try await store.stage(asset)
        _ = try await store.execute(sql: "UPDATE attachment_assets SET display_name='../escape';")
        await #expect(throws: DomainValidationError.self) { try await store.draft(conversationID: fixture.conversationID) }
        await #expect(throws: DomainValidationError.self) { try await store.attachment(id: asset.id, conversationID: fixture.conversationID) }
        let pair = try fixture.exchange(ids: [asset.id])
        await #expect(throws: DomainValidationError.self) { try await store.append(pair.user, expectedPreviousSequence: 0) }
        _ = try await store.execute(sql: "UPDATE attachment_assets SET display_name='valid.txt',created_at=1e999;")
        await #expect(throws: DomainValidationError.self) { try await store.draft(conversationID: fixture.conversationID) }
        _ = try await store.execute(sql: "UPDATE attachment_assets SET created_at=1000;")
        _ = try await store.execute(sql: "PRAGMA ignore_check_constraints=ON;")
        _ = try await store.execute(sql: "UPDATE conversation_attachment_drafts SET revision=0;")
        await #expect(throws: AttachmentRepositoryError.invalidRevision) { try await store.draft(conversationID: fixture.conversationID) }
    }

    @Test("Migration ten preserves existing messages, search and composer text")
    func migrationPreservation() async throws {
        let fixture = try AttachmentStoreFixture()
        defer { fixture.remove() }
        let pair = try fixture.exchange(ids: [])
        var checksums: [String] = []
        do {
            let store = try fixture.open()
            try await fixture.seed(store)
            try await store.append(pair.user, expectedPreviousSequence: 0)
            _ = try await store.saveDraft(conversationID: fixture.conversationID, text: "unsent retained", expectedRevision: 0, updatedAt: fixture.date)
            checksums = try await store.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=9 ORDER BY version;").map { try $0.text("checksum") }
            for table in ["conversation_draft_attachment_links", "conversation_attachment_drafts", "attachment_assets"] {
                _ = try await store.execute(sql: "DROP TABLE \(table);")
            }
            _ = try await store.execute(sql: "DELETE FROM schema_migrations WHERE version=10;")
        }
        let reopened = try fixture.open()
        #expect(try await reopened.runtimeFacts().migrationCount == SQLiteStore.expectedMigrationCount)
        #expect(try await reopened.message(id: pair.user.id) == pair.user)
        #expect(try await reopened.search(ConversationSearchRequest(query: "attachmentfixture")).messages.map(\.id) == [pair.user.id])
        #expect(try await reopened.loadDraft(conversationID: fixture.conversationID)?.text == "unsent retained")
        #expect(try await reopened.query(sql: "SELECT checksum FROM schema_migrations WHERE version<=9 ORDER BY version;").map { try $0.text("checksum") } == checksums)
        #expect(try await reopened.draft(conversationID: fixture.conversationID).revision == 0)
    }
}

private struct AttachmentStoreFixture: Sendable {
    let directory: URL
    let receipt: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_000)
    let teammateID = TeammateID(UUID())
    let conversationID = ConversationID(UUID())
    let otherTeammateID = TeammateID(UUID())
    let otherConversationID = ConversationID(UUID())
    var databaseURL: URL { directory.appendingPathComponent("control.sqlite") }

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextAttachmentPersistence-\(UUID()).noindex", isDirectory: true)
        receipt = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: databaseURL, protection: .ordinarySQLite(decision: receipt)))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func asset(id: AttachmentID = AttachmentID(UUID()), conversationID: ConversationID? = nil, name: String = "notes.txt") throws -> AttachmentAsset {
        try AttachmentAsset(id: id, conversationID: conversationID ?? self.conversationID, displayName: name, typeIdentifier: "public.data", byteCount: 12, sha256: String(repeating: "a", count: 64), createdAt: date)
    }

    func seed(_ store: SQLiteStore, teammateID: TeammateID? = nil, conversationID: ConversationID? = nil) async throws {
        let id = teammateID ?? self.teammateID
        let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: "Attachment Partner", role: "Research"), appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"), createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate, conversation: Conversation(id: conversationID ?? self.conversationID, kind: .direct(teammateID: id), createdAt: date, updatedAt: date), fixtureGreeting: nil, selectConversation: false)
    }

    func exchange(ids: [AttachmentID], attachmentOnly: Bool = false, replyAuthor: MessageAuthor? = nil) throws -> (user: Message, reply: Message) {
        var contents: [MessagePartContent] = attachmentOnly ? [] : [.text("attachmentfixture user message")]
        contents += ids.map(MessagePartContent.attachment)
        let user = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: 1, author: .user, deliveryState: .completed, parts: contents.enumerated().map { try MessagePart(id: MessagePartID(UUID()), ordinal: $0.offset, content: $0.element) }, createdAt: date, updatedAt: date)
        let reply = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: 2, author: replyAuthor ?? .teammate(teammateID), deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Local fixture reply. No runtime executed."))], createdAt: date, updatedAt: date)
        return (user, reply)
    }
}
