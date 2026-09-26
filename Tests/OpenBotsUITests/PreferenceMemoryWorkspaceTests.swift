import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsServices
import Testing
@testable import OpenBotsUI

/// Normal composer and production local services over disposable real SQLite and
/// Markdown roots. Reconstructs all workspace/service/store instances on reopen;
/// it does not launch Preview, contact Claude or claim physical quit/relaunch QA.
@MainActor
@Suite("Preference memory through normal workspace Send and reopen")
struct PreferenceMemoryWorkspaceTests {
    @Test("A remembered preference survives reopen, ordinary correction and another reopen")
    func rememberCorrectAndReopen() async throws {
        let fixture = try await PreferenceWorkspaceFixture()
        defer { fixture.remove() }
        let original = try await capture(fixture)
        let successor = try await recallAndCorrect(fixture, original: original)
        try await verifyReopenedCorrection(fixture, original: original, successor: successor)
        #expect(await fixture.fallback.calls == 0)
    }

    private func capture(_ f: PreferenceWorkspaceFixture) async throws -> MemoryClaimID {
        let db = try f.open()
        try await f.seed(db)
        let model = try await f.workspace(db)
        defer { model.finishShutdown() }
        let id = try await send("Remember that I prefer tea.", in: model, database: db)
        let operation = try #require(try await db.memoryLocalCorrection(userMessageID: id))
        #expect(operation.state == .acknowledged)
        #expect(try await db.memoryPublication(id: operation.request.operationID)?.state == .committed)
        let artifact = try await f.artifact(db, id: operation.request.documentID)
        let claim = try #require(artifact.claims.first)
        #expect(claim.body == "I prefer tea." && claim.assessment.level == .uncertain)
        #expect(model.conversation.messages.contains { $0.body == MemoryLocalCorrectionAcknowledgement.text })
        #expect(await model.flushForShutdown())
        return claim.id
    }

    private func recallAndCorrect(_ f: PreferenceWorkspaceFixture, original: MemoryClaimID) async throws -> MemoryClaimID {
        let db = try f.open()
        let model = try await f.workspace(db)
        defer { model.finishShutdown() }
        #expect(model.conversation.messages.contains { $0.body == "Remember that I prefer tea." })
        _ = try await send("What do you remember about me?", in: model, database: db)
        let overview = try #require(model.conversation.messages.last)
        #expect(overview.body.contains("I prefer tea."))
        #expect(overview.body.contains("Not established; it is only a possibility."))

        let id = try await send("Actually, I prefer coffee.", in: model, database: db)
        let operation = try #require(try await db.memoryLocalCorrection(userMessageID: id))
        #expect(operation.state == .acknowledged)
        #expect(operation.request.targetAnchor != nil)
        #expect(try await db.memoryPublication(id: operation.request.operationID)?.state == .committed)
        let artifact = try await f.artifact(db, id: operation.request.documentID)
        let old = try #require(artifact.claims.first { $0.id == original })
        let current = try #require(artifact.claims.first { $0.validity != .withdrawn })
        #expect(old.body == "I prefer tea." && old.validity == .withdrawn)
        #expect(current.id != original && current.body == "I prefer coffee.")
        #expect(current.changes.contains { $0.kind == .supersession && $0.previous.claimID == original })
        #expect(model.conversation.messages.last?.body == MemoryLocalCorrectionAcknowledgement.text)
        #expect(await model.flushForShutdown())
        return current.id
    }

    private func verifyReopenedCorrection(_ f: PreferenceWorkspaceFixture, original: MemoryClaimID,
                                          successor: MemoryClaimID) async throws {
        let db = try f.open()
        let model = try await f.workspace(db)
        defer { model.finishShutdown() }
        #expect(model.conversation.messages.contains { $0.body == "Actually, I prefer coffee." })
        _ = try await send("What do you remember about me?", in: model, database: db)
        let overview = try #require(model.conversation.messages.last)
        #expect(overview.body.contains("I prefer coffee."))
        #expect(!overview.body.contains("I prefer tea."))
        let publication = try #require(try await db.memoryConversationPublication(
            messageID: MessageID(overview.id), conversationID: f.chat))
        #expect(publication.publication.receipt.units.flatMap(\.references).contains { $0.claimID == successor })
        #expect(!publication.publication.receipt.units.flatMap(\.references).contains { $0.claimID == original })
        _ = try await send("Show my memory history", in: model, database: db)
        #expect(model.conversation.messages.last?.body.contains("I prefer tea.") == true)
        #expect(try await db.runs(conversationID: f.chat, limit: 20).isEmpty)
        #expect(await model.flushForShutdown())
    }

    @Test("Ambiguous preferences and unrelated claims ask for a target without changing saved memory",
          arguments: [["I prefer tea.", "I prefer quiet rooms."], ["I live in Paris."]])
    func unclearTargetDoesNotReplace(_ memories: [String]) async throws {
        let f = try await PreferenceWorkspaceFixture()
        defer { f.remove() }
        let db = try f.open()
        try await f.seed(db)
        let model = try await f.workspace(db)
        defer { model.finishShutdown() }
        for memory in memories { _ = try await send("Remember that " + memory, in: model, database: db) }
        _ = try await send("What do you remember about me?", in: model, database: db)
        let before = try await db.allDocuments()
        let id = try await send("Actually, I prefer coffee.", in: model, database: db)
        let operation = try #require(try await db.memoryLocalCorrection(userMessageID: id))
        #expect(operation.state == .failed && operation.failure == .contextUnavailable)
        #expect(operation.clarification != nil && operation.acknowledgement == nil)
        #expect(try await db.memoryPublication(id: operation.request.operationID) == nil)
        #expect(try await db.allDocuments() == before)
        #expect(model.conversation.messages.last?.body != MemoryLocalCorrectionAcknowledgement.text)
        #expect(await f.fallback.calls == 0)
        #expect(await model.flushForShutdown())
    }

    private func send(_ text: String, in model: DurableWorkspaceModel, database: SQLiteStore) async throws -> MessageID {
        let id = UUID()
        model.conversation.composerText = text
        try #require(model.conversation.canSend)
        model.conversation.sendCurrentText(messageID: id)
        #expect(await model.conversation.settleForShutdown())
        #expect(model.conversation.textReplyPhase == .completed)
        let saved = try #require(try await database.message(id: MessageID(id)))
        #expect(saved.parts.first?.content == .text(text))
        #expect(saved.author == .user && saved.deliveryState == .completed)
        return MessageID(id)
    }
}

private struct PreferenceWorkspaceFixture {
    let root: URL
    let layout: PreviewStorageLayout
    let plan: PreviewRootCreationPlan
    let protection: ProtectionDecisionReceipt
    let supportRoot: VerifiedOwnedRoot
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())
    let fallback = PreferenceInertProvider()

    init() async throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextPreference-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support"), home.appending(path: "Library/Caches"), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: date, rationaleVersion: 2)
        let receipt = try await StorageBootstrapService(layout: layout, locationAdmission: PreferenceLocalLocation()).bootstrap(using: plan)
        supportRoot = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: supportRoot)
    }
    func seed(_ db: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Preference Fixture", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
            createdAt: date, updatedAt: date)
        try await db.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: true)
    }
    @MainActor
    func workspace(_ db: SQLiteStore) async throws -> DurableWorkspaceModel {
        let root = try await authority(), time = date
        let correction = MemoryLocalCorrectionService(corrections: db, memory: db, intents: db, contexts: db,
            conversationContexts: db, teammates: db, messages: db, authority: root, publications: db, clock: { time })
        let local = MemoryLocalConversationService(fallback: fallback, corrections: correction,
            memory: db, intents: db, contexts: db, selections: db, messages: db, teammates: db,
            publications: db, authority: root, clock: { time })
        let model = DurableWorkspaceModel(mode: .localOnly,
            service: DurableTeammateChatService(teammateRepository: db, conversationRepository: db,
                messageRepository: db, provisioningRepository: db, selectionRepository: db),
            textReplyService: local, hiringService: HiringConversationService(repository: db))
        try await model.loadInitialWorkspace()
        #expect(model.conversation.conversationID == chat.rawValue)
        return model
    }
    func artifact(_ db: SQLiteStore, id: MemoryDocumentID) async throws -> MemoryClaimArtifact {
        let document = try #require(try await db.document(id: id))
        let read = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: document), inside: authority())
        return try #require(MemoryClaimCodec().decode(Data(read.markdown.utf8), expecting: document).artifact)
    }
}

private struct PreferenceLocalLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-preference-volume")
    }
}

private actor PreferenceInertProvider: ClaudeTextReplyServing {
    private(set) var calls = 0
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        calls += 1
        return .init(outcome: .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}
