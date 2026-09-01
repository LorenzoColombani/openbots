import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
import Testing

@Suite("Durable attachment integration")
struct ConversationAttachmentIntegrationTests {
    @Test("Import, attachment-only send and true SQLite reopen retain verified immutable bytes")
    func importSendAndReopen() async throws {
        let fixture = try AttachmentIntegrationFixture()
        defer { fixture.remove() }
        let roots = try await fixture.bootstrap()
        let saved = try await prepareAndSend(fixture: fixture, roots: roots)
        #expect(saved.oldStore.value == nil)
        let reopened = try fixture.open()
        let attachments = fixture.service(store: reopened, roots: roots)
        let draft = try await attachments.draft(conversationID: saved.asset.conversationID)
        #expect(draft.attachments.isEmpty)
        let resolved = try await attachments.attachment(messageID: saved.message.id,
            partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
        #expect(resolved == saved.asset)
        let url = try await attachments.revealLocation(messageID: saved.message.id,
            partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
        #expect(try Data(contentsOf: url) == fixture.bytes)
        #expect(try await attachments.preview(messageID: saved.message.id,
            partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
            == .text(value: String(decoding: fixture.bytes, as: UTF8.self), isTruncated: false))
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.contentRoot.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: roots.ingest.url.path).isEmpty)
        await #expect(throws: ConversationAttachmentError.invalidMessageRoute) {
            try await attachments.revealLocation(messageID: saved.message.id,
                partID: MessagePartID(UUID()), attachmentID: saved.asset.id)
        }
    }

    private func prepareAndSend(fixture: AttachmentIntegrationFixture, roots: AttachmentIntegrationRoots) async throws
        -> (asset: AttachmentAsset, message: Message, oldStore: AttachmentWeakStore) {
        let store = try fixture.open()
        let service = fixture.service(store: store, roots: roots)
        let chat = fixture.chat(store: store, attachments: service)
        let created = try await chat.createTeammateAndDirectChat(fixture.teammate())
        let asset = try await service.importFile(fixture.source, operationID: UUID(), conversationID: created.conversation.id)
        #expect(try await service.draft(conversationID: created.conversation.id).attachments == [asset])
        let exchange = try await chat.sendMessageToLocalFixture(conversationID: created.conversation.id,
            teammateID: created.teammate.id, userMessageID: MessageID(UUID()), text: "", attachmentIDs: [asset.id])
        #expect(exchange.userMessage.parts.map(\.content) == [.attachment(asset.id)])
        #expect(exchange.fixtureReply.parts.contains { if case .text(let value) = $0.content { return value.contains("No Claude") }; return false })
        return (asset, exchange.userMessage, AttachmentWeakStore(store))
    }

    @Test("Corrupt owned bytes block send without consuming drafts or appending messages")
    func corruptCopyCannotBeSent() async throws {
        let fixture = try AttachmentIntegrationFixture()
        defer { fixture.remove() }
        let roots = try await fixture.bootstrap()
        let store = try fixture.open()
        let attachments = fixture.service(store: store, roots: roots)
        let chat = fixture.chat(store: store, attachments: attachments)
        let created = try await chat.createTeammateAndDirectChat(fixture.teammate())
        let asset = try await attachments.importFile(fixture.source, operationID: UUID(), conversationID: created.conversation.id)
        let content = AttachmentContentStore(root: roots.content)
        let owned = try await content.verifiedURL(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256)
        // Adversarial corruption of an exact test-owned file only.
        try Data(repeating: 0x58, count: fixture.bytes.count).write(to: owned)
        let messageID = MessageID(UUID())
        await #expect(throws: (any Error).self) {
            try await chat.sendMessageToLocalFixture(conversationID: created.conversation.id,
                teammateID: created.teammate.id, userMessageID: messageID,
                text: "Keep this draft", attachmentIDs: [asset.id])
        }
        #expect(try await store.message(id: messageID) == nil)
        #expect(try await attachments.draft(conversationID: created.conversation.id).attachments == [asset])
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        _ = try await attachments.remove(id: asset.id, conversationID: created.conversation.id)
        #expect(FileManager.default.fileExists(atPath: owned.path))
    }

    @Test("Saved-file preview rejects an invalid route or page before its renderer runs")
    func previewRouteIsExact() async throws {
        let fixture = try AttachmentIntegrationFixture()
        defer { fixture.remove() }
        let roots = try await fixture.bootstrap()
        let saved = try await prepareAndSend(fixture: fixture, roots: roots)
        let store = try fixture.open()
        let calls = AttachmentPreviewCalls()
        let service = ConversationAttachmentService(repository: store, messages: store,
            importer: { _, _ in throw ConversationAttachmentError.unavailable },
            verifier: { _ in }, location: { _ in throw ConversationAttachmentError.unavailable },
            previewer: { asset, page in
                await calls.record(asset.id, page: page)
                return .text(value: "Bounded preview", isTruncated: false)
            })
        let part = saved.message.parts[0].id
        await #expect(throws: ConversationAttachmentError.invalidMessageRoute) {
            try await service.preview(messageID: saved.message.id, partID: MessagePartID(UUID()),
                attachmentID: saved.asset.id)
        }
        await #expect(throws: ConversationAttachmentError.invalidMessageRoute) {
            try await service.preview(messageID: MessageID(UUID()), partID: part, attachmentID: saved.asset.id)
        }
        await #expect(throws: ConversationAttachmentError.invalidMessageRoute) {
            try await service.preview(messageID: saved.message.id, partID: part, attachmentID: AttachmentID(UUID()))
        }
        for page in [0, -1, 501, Int.max] {
            await #expect(throws: ConversationAttachmentError.invalidPreviewPage) {
                try await service.preview(messageID: saved.message.id, partID: part,
                    attachmentID: saved.asset.id, pageNumber: page)
            }
        }
        #expect(await calls.count == 0)
        #expect(try await service.preview(messageID: saved.message.id, partID: part, attachmentID: saved.asset.id)
            == .text(value: "Bounded preview", isTruncated: false))
        #expect(await calls.count == 1)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test("A corrupted saved copy cannot be previewed and leaves its message and original intact")
    func previewRejectsCorruptSavedCopy() async throws {
        let fixture = try AttachmentIntegrationFixture()
        defer { fixture.remove() }
        let roots = try await fixture.bootstrap()
        let saved = try await prepareAndSend(fixture: fixture, roots: roots)
        let store = try fixture.open()
        let persistedBefore = try #require(try await store.message(id: saved.message.id))
        let service = fixture.service(store: store, roots: roots)
        let owned = try await service.revealLocation(messageID: saved.message.id,
            partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
        try Data(repeating: 0x58, count: fixture.bytes.count).write(to: owned)
        await #expect(throws: (any Error).self) {
            try await service.preview(messageID: saved.message.id,
                partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
        }
        #expect(try await store.message(id: saved.message.id) == persistedBefore)
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test("Cancellation after renderer completion cannot publish a preview receipt")
    func previewCancellationFencesPublication() async throws {
        let fixture = try AttachmentIntegrationFixture()
        defer { fixture.remove() }
        let roots = try await fixture.bootstrap()
        let saved = try await prepareAndSend(fixture: fixture, roots: roots)
        let store = try fixture.open()
        // Compare durable state before/after the operation. The service's
        // pre-storage Date uses a different epoch representation from SQLite's
        // REAL seconds; exact Date equality is not this immutability contract.
        let persistedBefore = try #require(try await store.message(id: saved.message.id))
        #expect(persistedBefore.parts == saved.message.parts)
        #expect(persistedBefore.author == saved.message.author)
        #expect(persistedBefore.deliveryState == saved.message.deliveryState)
        let gate = AttachmentPreviewGate()
        let service = ConversationAttachmentService(repository: store, messages: store,
            importer: { _, _ in throw ConversationAttachmentError.unavailable },
            verifier: { _ in }, location: { _ in throw ConversationAttachmentError.unavailable },
            previewer: { _, _ in
                await gate.wait()
                return .text(value: "Late result", isTruncated: false)
            })
        let task = Task {
            try await service.preview(messageID: saved.message.id,
                partID: saved.message.parts[0].id, attachmentID: saved.asset.id)
        }
        for _ in 0..<500 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(2)) }
        let entered = await gate.entered
        task.cancel()
        await gate.release()
        try #require(entered)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.message(id: saved.message.id) == persistedBefore)
    }
}

private actor AttachmentPreviewCalls {
    private(set) var count = 0
    func record(_ id: AttachmentID, page: Int) { count += 1 }
}

private actor AttachmentPreviewGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AttachmentWeakStore: @unchecked Sendable {
    weak var value: SQLiteStore?
    init(_ value: SQLiteStore) { self.value = value }
}

private struct AttachmentIntegrationRoots: Sendable {
    let ingest: VerifiedAttachmentIngestRoot
    let content: VerifiedAttachmentContentRoot
}

private struct AttachmentIntegrationAdmission: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        LocationObservation(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
            fileProviderStatus: .notManaged, volumeIdentifier: "attachment-test-volume")
    }
}

private struct AttachmentIntegrationFixture {
    let root: URL
    let layout: PreviewStorageLayout
    let source: URL
    let bytes = Data("attachment integration original\n".utf8)
    let decision: ProtectionDecisionReceipt

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsAttachmentIntegration-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home")
        let temporary = root.appending(path: "Temporary")
        for directory in [home.appending(path: "Library/Application Support"), home.appending(path: "Library/Caches"), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        source = root.appending(path: "original.txt")
        try bytes.write(to: source, options: .withoutOverwriting)
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        decision = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
    }

    func bootstrap() async throws -> AttachmentIntegrationRoots {
        let plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        let receipt = try await StorageBootstrapService(layout: layout, locationAdmission: AttachmentIntegrationAdmission()).bootstrap(using: plan)
        let support = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
        let cache = try #require(receipt.verifiedRoots.first { $0.kind == .caches })
        return try AttachmentIntegrationRoots(
            ingest: AttachmentIngestRootVerifier().verify(layout.attachmentIngestRoot, inside: cache),
            content: AttachmentContentRootProvisioner().prepare(inside: support))
    }

    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: layout.databaseURL, protection: .ordinarySQLite(decision: decision)))
    }

    func service(store: SQLiteStore, roots: AttachmentIntegrationRoots) -> ConversationAttachmentService {
        let content = AttachmentContentStore(root: roots.content)
        let ingestor = AttachmentIngestor()
        return ConversationAttachmentService(repository: store, messages: store,
            importer: { url, id in
                let receipt = try await ingestor.ingest(AttachmentIngestionRequest(sourceFileURL: url, ingestRoot: roots.ingest, operationID: id.rawValue))
                let result = try await content.publish(receipt: receipt, from: roots.ingest, id: id)
                try await ingestor.discard(receipt, inside: roots.ingest)
                return result
            },
            verifier: { try await content.verify(id: $0.id, byteCount: $0.byteCount, sha256: $0.sha256) },
            location: { try await content.verifiedURL(id: $0.id, byteCount: $0.byteCount, sha256: $0.sha256) },
            previewer: { asset, page in
                try await content.preview(id: asset.id, byteCount: asset.byteCount, sha256: asset.sha256,
                    displayName: asset.displayName, typeIdentifier: asset.typeIdentifier, pageNumber: page)
            })
    }

    func chat(store: SQLiteStore, attachments: ConversationAttachmentService) -> DurableTeammateChatService {
        DurableTeammateChatService(mode: .reviewFixture, teammateRepository: store, conversationRepository: store, messageRepository: store,
            provisioningRepository: store, selectionRepository: store, attachmentRepository: store, attachmentValidator: attachments)
    }

    func teammate() throws -> DurableTeammateDraft {
        DurableTeammateDraft(teammateID: TeammateID(UUID()), displayName: "Ada Attachment", role: "Local attachment review",
            appearance: try AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 91,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright",
                nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
