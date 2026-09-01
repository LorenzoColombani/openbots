import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Production local memory conversations with protected SQLite and artifacts")
struct MemoryLocalConversationIntegrationTests {
    @Test("Local memory overviews preserve uncertainty without entering provider preparation",
          arguments: ["What do you remember about me?", "What do you assume about me?", "What do you think about me?"])
    func overview(_ question: String) async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let retained = try await f.publish(store, root: root, body: "I prefer quiet libraries.")
        let original = try await store.message(id: retained.source.id)
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let submission = f.submission(question)
        let result = await service.sendText(submission) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        let text = try localMemoryText(reply)
        #expect(text.contains("I prefer quiet libraries."))
        #expect(text.contains("Not established; it is only a possibility."))
        #expect(text.contains("Its source is a checked user message."))
        #expect(text.contains("not a complete inventory"))
        #expect(reply.author == .system && reply.deliveryState == .completed)
        #expect(result.savedUserMessage?.id == submission.userMessageID)
        #expect(try await store.message(id: retained.source.id) == original)
        #expect(try await store.document(id: retained.record.intent.document.id) == retained.record.intent.document)
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }

    @Test("Linked why uses the saved projection receipt and remains exact after reopening")
    func linkedWhyAndReopen() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        _ = try await f.publish(store, root: root, body: "I prefer quiet libraries.")
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let overviewSubmission = f.submission("What do you remember about me?")
        let overview = await service.sendText(overviewSubmission) { await progress.append($0) }
        #expect(overview.outcome == .completed)
        let firstReply = try #require(overview.savedReplyMessage)
        let first = try #require(try await store.memoryConversationPublication(messageID: firstReply.id, conversationID: f.chat))
        let why = await service.sendText(f.submission("Why did you say that?")) { await progress.append($0) }
        #expect(why.outcome == .completed)
        let reply = try #require(why.savedReplyMessage), text = try localMemoryText(reply)
        #expect(text.contains("That reply drew on"))
        #expect(text.contains("The user explicitly asked to retain this as uncertain."))
        #expect(text.contains("Not established; it is only a possibility."))
        let record = try #require(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat))
        #expect(record.publication.receipt.lineage == .derived(receiptIDs: [first.publication.receipt.id]))
        #expect(record.publication.receipt.dependencies == first.publication.receipt.dependencies)
        let all = try await store.page(conversationID: f.chat, request: PageRequest(limit: 20)).elements
        let reopened = try f.open()
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 20)).elements == all)
        #expect(try await reopened.memoryConversationPublication(id: record.publication.receipt.id) == record)
        #expect(try await reopened.message(id: firstReply.id) == firstReply)
        let reopenedService = f.service(reopened, root: root, fallback: fallback)
        let retried = await reopenedService.sendText(overviewSubmission) { await progress.append($0) }
        #expect(retried == overview)
        let conflict = ClaudeTextTurnSubmission(conversationID: f.chat, teammateID: f.bot,
            userMessageID: overviewSubmission.userMessageID, text: "What do you assume about me?")
        let refused = await reopenedService.sendText(conflict) { await progress.append($0) }
        #expect(refused.outcome == .failed(.invalidInput))
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 20)).elements == all)
        try await f.assertLocalOnly(reopened, fallback: fallback, progress: progress)
    }

    @Test("Why without a publication link admits that limit and does not invent the model's reasoning")
    func missingWhyLink() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let old = try Message(id: MessageID(UUID()), conversationID: f.chat, sequence: 1, author: .teammate(f.bot),
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0,
                content: .text("Historical provider wording whose cause was not recorded."))], createdAt: f.date, updatedAt: f.date)
        try await store.append(old, expectedPreviousSequence: 0)
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let result = await f.service(store, root: root, fallback: fallback)
            .sendText(f.submission("Why did you say that?")) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        #expect(try localMemoryText(reply) == "I don't have a recorded link explaining that wording, so I can't reliably say why it was used.")
        let record = try #require(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat))
        #expect(record.publication.receipt.dependencies.isEmpty)
        #expect(try await store.message(id: old.id) == old)
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }

    @Test("Committed withdrawal is omitted from active overview and remains explicit private history")
    func withdrawalHistory() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let first = try await f.publish(store, root: root, body: "I live in SYNTHETIC-CEDAR.")
        let withdrawn = try await f.publish(store, root: root, body: first.artifact.claims[0].body,
            command: "Withdraw this memory: ", previous: first)
        #expect(withdrawn.artifact.claims.first?.validity == .withdrawn)
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let active = await service.sendText(f.submission("What do you remember about me?")) { await progress.append($0) }
        #expect(active.outcome == .completed)
        let activeText = try localMemoryText(try #require(active.savedReplyMessage))
        #expect(!activeText.contains("SYNTHETIC-CEDAR"))
        #expect(activeText.contains("No relevant memory"))
        let history = await service.sendText(f.submission("Show withdrawn memories")) { await progress.append($0) }
        #expect(history.outcome == .completed)
        let historyReply = try #require(history.savedReplyMessage)
        let historyText = try localMemoryText(historyReply)
        #expect(historyText.contains("SYNTHETIC-CEDAR"))
        #expect(historyText.contains("Historical information, not current guidance."))
        #expect(historyText.contains("withdrawn from active use"))
        let record = try #require(try await store.memoryConversationPublication(messageID: historyReply.id, conversationID: f.chat))
        #expect(record.publication.receipt.intent == .historyOverview)
        #expect(record.publication.receipt.dependencies.map(\.reference.documentID) == [withdrawn.record.intent.document.id])
        #expect(try await store.document(id: first.record.intent.document.id) == first.record.intent.document)
        let original = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: first.record.intent.document), inside: root)
        #expect(try Data(original.markdown.utf8) == MemoryClaimCodec().encode(first.artifact))
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }

    @Test("Other-bot and global memory stay excluded; selected-project claims require current membership")
    func scopeIsolation() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        _ = try await f.publish(store, root: root, body: "OWN-BOT-SENTINEL.")
        _ = try await f.publish(store, root: root, body: "OTHER-BOT-SENTINEL.", second: true)
        let global = try await f.globalCanary(store, root: root)
        try await f.selectProject(store, project: f.project)
        _ = try await f.publish(store, root: root, body: "SELECTED-PROJECT-SENTINEL.", project: true)
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let selected = await service.sendText(f.submission("What do you assume about me?")) { await progress.append($0) }
        #expect(selected.outcome == .completed)
        let selectedText = try localMemoryText(try #require(selected.savedReplyMessage))
        #expect(selectedText.contains("OWN-BOT-SENTINEL") && selectedText.contains("SELECTED-PROJECT-SENTINEL"))
        #expect(!selectedText.contains("OTHER-BOT-SENTINEL") && !selectedText.contains("GLOBAL-SECRET-SENTINEL"))
        try await f.selectProject(store, project: nil)
        let personal = await service.sendText(f.submission("What do you remember about me?")) { await progress.append($0) }
        #expect(personal.outcome == .completed)
        #expect(!(try localMemoryText(try #require(personal.savedReplyMessage))).contains("SELECTED-PROJECT-SENTINEL"))
        let other = await service.sendText(f.submission("What do you remember about me?", second: true)) { await progress.append($0) }
        #expect(other.outcome == .completed)
        let otherText = try localMemoryText(try #require(other.savedReplyMessage))
        #expect(otherText.contains("OTHER-BOT-SENTINEL") && !otherText.contains("OWN-BOT-SENTINEL"))
        #expect(!otherText.contains("GLOBAL-SECRET-SENTINEL") && !otherText.contains("SELECTED-PROJECT-SENTINEL"))
        #expect(try await store.document(id: global.id) == global)
        let globalBytes = try await AuthoritativeMarkdownStore().read(AuthoritativeMarkdownReference(document: global), inside: root)
        #expect(globalBytes.markdown == "GLOBAL-SECRET-SENTINEL must remain excluded.")
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
        #expect(try await store.runs(conversationID: f.secondChat, limit: 10).isEmpty)
    }

    @Test("Why explains unavailable sources without reviving a superseded claim; the exact limitation survives reopen")
    func staleHeadAndAtomicFailure() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let first = try await f.publish(store, root: root, body: "I live in SYNTHETIC-CEDAR.")
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { await progress.append($0) }
        #expect(overview.outcome == .completed)
        let originalReply = try #require(overview.savedReplyMessage)
        _ = try await f.publish(store, root: root, body: first.artifact.claims[0].body,
            command: "Withdraw this memory: ", previous: first)
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements
        let submission = f.submission("Why did you say that?")
        let stale = await service.sendText(submission) { await progress.append($0) }
        #expect(stale.outcome == .completed)
        let limitationReply = try #require(stale.savedReplyMessage)
        #expect(try localMemoryText(limitationReply) == MemoryExplanationLimitation.sourcesUnavailable.text)
        #expect(!(try localMemoryText(limitationReply)).contains("SYNTHETIC-CEDAR"))
        let limited = try #require(try await store.memoryConversationPublication(messageID: limitationReply.id, conversationID: f.chat))
        #expect(limited.publication.receipt.units == [.init(kind: .explanationSourcesUnavailable, references: [])])
        #expect(limited.publication.receipt.dependencies.isEmpty && limited.publication.receipt.lineage == .independent)
        #expect(limited.authority.memoryDocuments.isEmpty && limited.userSourceStamps.isEmpty)
        let after = try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements
        #expect(after.count == before.count + 2 && Array(after.prefix(before.count)) == before)
        #expect(try await store.message(id: originalReply.id) == originalReply)
        let failedProgress = LocalMemoryProgress()
        let failing = f.service(store, root: root, fallback: fallback, publications: LocalMemoryFailingPublications(base: store))
        let failed = await failing.sendText(f.submission("What do you remember about me?")) { await failedProgress.append($0) }
        #expect(failed.outcome == .failed(.persistenceFailed))
        #expect(failed.savedUserMessage == nil && failed.savedReplyMessage == nil)
        let failedEvents = await failedProgress.events
        #expect(!failedEvents.contains { if case .assistantMessageSaved = $0 { return true }; return false })
        let reopened = try f.open()
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements == after)
        let retried = await f.service(reopened, root: root, fallback: fallback).sendText(submission) { _ in }
        #expect(retried.savedReplyMessage == limitationReply && retried.outcome == .completed)
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements == after)
        try await f.assertLocalOnly(reopened, fallback: fallback, progress: progress)
    }

    @Test("A missing linked receipt produces a different local limitation from absent causal linkage")
    func missingLinkedReceiptLimitation() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        _ = try await f.publish(store, root: root, body: "PRIVATE-LINKED-SOURCE.")
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { _ in }
        #expect(overview.outcome == .completed)
        let priorReply = try #require(overview.savedReplyMessage)
        let prior = try #require(try await store.memoryConversationPublication(messageID: priorReply.id, conversationID: f.chat))
        let beforeFailure = try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements
        let failedLookup = LocalMemoryMissingLinkedPublication(base: store, unavailableID: prior.publication.receipt.id,
                                                               failLookup: true)
        let failedService = f.service(store, root: root, fallback: fallback, publications: failedLookup)
        let failed = await failedService.sendText(f.submission("Why did you say that?")) { _ in }
        #expect(failed.outcome == .failed(.persistenceFailed))
        #expect(failed.savedUserMessage == nil && failed.savedReplyMessage == nil)
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements == beforeFailure)
        let missing = LocalMemoryMissingLinkedPublication(base: store, unavailableID: prior.publication.receipt.id)
        let limitedService = f.service(store, root: root, fallback: fallback, publications: missing)
        let submission = f.submission("Why did you say that?")
        let result = await limitedService.sendText(submission) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        #expect(try localMemoryText(reply) == MemoryExplanationLimitation.lineageUnverifiable.text)
        #expect(!(try localMemoryText(reply)).contains("PRIVATE-LINKED-SOURCE"))
        #expect(!(try localMemoryText(reply)).contains(prior.publication.receipt.id.uuidString))
        let receipt = try #require(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat))
        #expect(receipt.publication.receipt.units == [.init(kind: .explanationLineageUnverifiable, references: [])])
        let reopened = try f.open()
        let retried = await f.service(reopened, root: root, fallback: fallback).sendText(submission) { _ in }
        #expect(retried.savedReplyMessage == reply)
        #expect(try await reopened.message(id: priorReply.id) == priorReply)
        try await f.assertLocalOnly(reopened, fallback: fallback, progress: progress)
    }

    @Test("A retained evidence message repository failure stays a failed why, never a saved limitation")
    func retainedEvidenceRepositoryFailure() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let retained = try await f.publish(store, root: root, body: "PRIVATE-RETAINED-EVIDENCE.")
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { _ in }
        #expect(overview.outcome == .completed)
        let oldReply = try #require(overview.savedReplyMessage)
        let oldPublication = try #require(try await store.memoryConversationPublication(messageID: oldReply.id, conversationID: f.chat))
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements
        let failingMessages = LocalMemoryEvidenceMessageFailure(base: store, sourceID: retained.source.id)
        let time = f.now
        let failing = MemoryLocalConversationService(fallback: fallback, memory: store, intents: store, contexts: store,
            selections: store, messages: failingMessages, teammates: store, publications: store,
            authority: root, clock: { time })
        let submission = f.submission("Why did you say that?")
        let result = await failing.sendText(submission) { await progress.append($0) }
        #expect(result.outcome == .failed(.persistenceFailed))
        #expect(result.savedUserMessage == nil && result.savedReplyMessage == nil)
        #expect(await failingMessages.failedEvidenceReads == 1)
        #expect(await failingMessages.pageReads > 0)
        #expect(try await store.message(id: submission.userMessageID) == nil)
        #expect(try await store.memoryConversationPublication(messageID: submission.userMessageID, conversationID: f.chat) == nil)
        let events = await progress.events
        #expect(!events.contains { if case .userMessageSaved = $0 { return true }; return false })
        #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
        let reopened = try f.open()
        #expect(try await reopened.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements == before)
        #expect(try await reopened.memoryConversationPublication(id: oldPublication.publication.receipt.id) == oldPublication)
        try await f.assertLocalOnly(reopened, fallback: fallback, progress: progress)
    }

    @Test("Why after leaving a project withholds its sources; invalid current authority still cannot publish a limitation")
    func explanationScopeLimitations() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        try await f.selectProject(store, project: f.project)
        _ = try await f.publish(store, root: root, body: "PRIVATE-OLD-PROJECT-SOURCE.", project: true)
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        _ = await service.sendText(f.submission("What do you assume about me?")) { _ in }
        try await f.selectProject(store, project: nil)
        let result = await service.sendText(f.submission("Why did you say that?")) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let reply = try #require(result.savedReplyMessage)
        #expect(try localMemoryText(reply) == MemoryExplanationLimitation.sourcesUnavailable.text)
        #expect(!(try localMemoryText(reply)).contains("PRIVATE-OLD-PROJECT-SOURCE"))
        try await f.selectProject(store, project: f.project)
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements
        let submission = f.submission("Why did you say that?")
        let refused = await service.sendText(submission) { event in
            if case .stage(.selectingContext) = event {
                do { try await store.setMembership(ProjectMembership(projectID: f.project, teammateID: f.bot,
                    joinedAt: f.date, revokedAt: f.now)) }
                catch { Issue.record("Synthetic explanation revocation failed") }
            }
        }
        #expect(refused.outcome == .failed(.contextChanged))
        #expect(refused.savedUserMessage == nil && refused.savedReplyMessage == nil)
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 30)).elements == before)
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }

    @Test("Attachments and missing storage fail locally, while unrelated chat preserves only the inert fallback route")
    func routeBoundaries() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let attached = ClaudeTextTurnSubmission(conversationID: f.chat, teammateID: f.bot, userMessageID: MessageID(UUID()),
            text: "What do you remember about me?", attachmentIDs: [AttachmentID(UUID())])
        let refusedAttachment = await service.sendText(attached) { await progress.append($0) }
        #expect(refusedAttachment.outcome == .failed(.attachmentsNotSupported))
        let missing = f.service(store, root: nil, fallback: fallback)
        let refusedStorage = await missing.sendText(f.submission("Show my memory history")) { await progress.append($0) }
        #expect(refusedStorage.outcome == .failed(.contextUnavailable))
        #expect(await fallback.calls == 0)
        let ordinary = f.submission("Explain a synthetic sorting example.")
        let forwarded = await service.sendText(ordinary) { await progress.append($0) }
        #expect(forwarded.outcome == .failed(.runtimeUnavailable))
        #expect(await fallback.calls == 1)
        #expect(await fallback.submissions == [ordinary])
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.isEmpty)
        #expect(try await store.runs(conversationID: f.chat, limit: 10).isEmpty)
    }

    @Test("An empty overview and successive why questions stay truthful local replies")
    func emptyOverviewWhyChain() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let overview = await service.sendText(f.submission("What do you remember about me?")) { await progress.append($0) }
        #expect(overview.outcome == .completed)
        #expect(try localMemoryText(try #require(overview.savedReplyMessage)).contains("No relevant memory"))
        for _ in 0..<2 {
            let why = await service.sendText(f.submission("Why did you say that?")) { await progress.append($0) }
            #expect(why.outcome == .completed)
            let reply = try #require(why.savedReplyMessage)
            #expect(try localMemoryText(reply).contains("no recorded memory-claim dependencies"))
            let record = try #require(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat))
            #expect(record.publication.receipt.dependencies.isEmpty)
        }
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements.count == 6)
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }

    @Test("Project revocation at context selection fails locally before a publication is admitted")
    func revokedDuringSelection() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let root = try await f.authority()
        try await f.selectProject(store, project: f.project)
        _ = try await f.publish(store, root: root, body: "SELECTED-PROJECT-SENTINEL.", project: true)
        let before = try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements
        let fallback = LocalMemoryInertFallback(), progress = LocalMemoryProgress()
        let service = f.service(store, root: root, fallback: fallback)
        let result = await service.sendText(f.submission("What do you assume about me?")) { event in
            await progress.append(event)
            if event == .stage(.selectingContext) {
                do { try await store.setMembership(ProjectMembership(projectID: f.project, teammateID: f.bot,
                    joinedAt: f.date, revokedAt: f.now)) }
                catch { Issue.record("Synthetic project revocation failed") }
            }
        }
        #expect(result.outcome == .failed(.contextChanged))
        #expect(result.savedUserMessage == nil && result.savedReplyMessage == nil)
        #expect(try await store.page(conversationID: f.chat, request: PageRequest(limit: 10)).elements == before)
        try await f.assertLocalOnly(store, fallback: fallback, progress: progress)
    }
}

struct LocalMemoryFixture: Sendable {
    let root: URL, layout: PreviewStorageLayout, plan: PreviewRootCreationPlan
    let protection: ProtectionDecisionReceipt
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    var now: Date { date.addingTimeInterval(10) }
    let bot = TeammateID(UUID()), secondBot = TeammateID(UUID()), chat = ConversationID(UUID()), secondChat = ConversationID(UUID())
    let project = ProjectID(UUID())

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextLocalMemory-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support", directoryHint: .isDirectory),
                          home.appending(path: "Library/Caches", directoryHint: .isDirectory), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: date, rationaleVersion: 2)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let receipt = try await StorageBootstrapService(layout: layout, locationAdmission: LocalMemoryLocation()).bootstrap(using: plan)
        let verified = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: verified)
    }
    func seed(_ store: SQLiteStore) async throws {
        for (id, conversationID, name) in [(bot, chat, "Local Memory"), (secondBot, secondChat, "Other Bot")] {
            let teammate = try Teammate(id: id, profile: TeammateProfile(displayName: name, role: "Synthetic QA"),
                appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                    paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature"),
                createdAt: date, updatedAt: date)
            try await store.provisionDirectChat(teammate: teammate,
                conversation: Conversation(id: conversationID, kind: .direct(teammateID: id), createdAt: date, updatedAt: date),
                fixtureGreeting: nil, selectConversation: false)
        }
        try await store.insert(Project(id: project, name: "Synthetic Project", createdAt: date, updatedAt: date))
        try await store.setMembership(ProjectMembership(projectID: project, teammateID: bot, joinedAt: date))
    }
    func selectProject(_ store: SQLiteStore, project: ProjectID?) async throws {
        let selected = try await store.loadContext(conversationID: chat)
        _ = try await store.saveContext(ConversationContextSelection(conversationID: chat, teammateID: bot,
            projectID: project, revision: selected.revision))
    }
    struct Retained: Sendable { let artifact: MemoryClaimArtifact; let record: MemoryPublicationIntentRecord; let source: Message }
    func publish(_ store: SQLiteStore, root: VerifiedAuthoritativeMarkdownRoot, body: String,
                 command: String = "Remember as uncertain: ", previous: Retained? = nil,
                 second: Bool = false, project selected: Bool = false) async throws -> Retained {
        let botID = second ? secondBot : bot, conversationID = second ? secondChat : chat
        let sequence = (try await store.page(conversationID: conversationID, request: PageRequest(limit: 1)).elements.last?.sequence ?? 0) + 1
        let source = try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: sequence,
            author: .user, deliveryState: .pending,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(command + body))], createdAt: now, updatedAt: now)
        try await store.append(source, expectedPreviousSequence: sequence - 1)
        let selection = try await store.loadContext(conversationID: conversationID)
        let snapshot = try await store.loadReadContextCandidates(ReadContextRequest(conversationID: conversationID, teammateID: botID,
            profileRevision: 1, selection: selection, beforeSequence: sequence + 1))
        let context = try snapshot.receipt.selecting(messageIDs: [],
            memoryDocumentIDs: previous.map { [$0.record.intent.document.id] } ?? [])
        let verifier = MemoryEvidenceVerifier(messages: store, teammates: store, contexts: store)
        let priorClaim = previous?.artifact.claims[0]
        let priorReference = try previous.map { try MemoryClaimCodec().reference(for: $0.artifact.claims[0],
            in: $0.artifact, contentDigest: $0.record.intent.document.contentDigest) }
        let scope = previous?.artifact.scope ?? (selected ? MemoryScope.project(project) : .teammate(botID))
        let claim = try await verifier.userProposal(messageID: source.id, claimID: priorClaim?.id ?? MemoryClaimID(UUID()),
            scope: scope, previous: priorClaim, previousReference: priorReference, authority: context, at: now)
        let artifact = MemoryClaimArtifact(documentID: MemoryDocumentID(UUID()),
            revision: (previous?.artifact.revision ?? 0) + 1, scope: scope, claims: [claim])
        let time = now
        let service = MemoryClaimAdmissionService(memory: store, intents: store, contexts: store,
            verifier: verifier, authority: root, clock: { time })
        let record = try await service.publish(operationID: UUID(), artifact: artifact, title: "Synthetic retained claim",
            expectedPredecessor: previous?.record.intent.document, actor: .user(messageID: source.id), context: context)
        #expect(record.state == .committed)
        return Retained(artifact: artifact, record: record, source: source)
    }
    func globalCanary(_ store: SQLiteStore, root: VerifiedAuthoritativeMarkdownRoot) async throws -> MemoryDocument {
        // Legacy global content is synthetic and intentionally lacks admission.
        // Neither the current read scope nor the resolver can promote it.
        let id = MemoryDocumentID(UUID()), text = "GLOBAL-SECRET-SENTINEL must remain excluded."
        let request = try AuthoritativeMarkdownPublicationRequest(documentID: id, scope: .user,
            revision: 1, markdown: text, authority: root)
        _ = try await AuthoritativeMarkdownStore().publish(request)
        let document = try MemoryDocument(id: id, scope: .user, author: .user, title: "Synthetic global canary",
            relativePath: AuthoritativeMarkdownPath.relativePath(documentID: id, scope: .user, revision: 1),
            revision: 1, contentDigest: MemoryClaimDigests.bytes(Data(text.utf8)), createdAt: now, updatedAt: now)
        try await store.insert(document)
        return document
    }
    func submission(_ text: String, second: Bool = false) -> ClaudeTextTurnSubmission {
        .init(conversationID: second ? secondChat : chat, teammateID: second ? secondBot : bot,
              userMessageID: MessageID(UUID()), text: text)
    }
    fileprivate func service(_ store: SQLiteStore, root: VerifiedAuthoritativeMarkdownRoot?, fallback: LocalMemoryInertFallback,
                 publications: (any MemoryConversationPublicationRepository)? = nil) -> MemoryLocalConversationService {
        let time = now
        return MemoryLocalConversationService(fallback: fallback, memory: store, intents: store, contexts: store,
            selections: store, messages: store, teammates: store, publications: publications ?? store,
            authority: root, clock: { time })
    }
    fileprivate func assertLocalOnly(_ store: SQLiteStore, fallback: LocalMemoryInertFallback, progress: LocalMemoryProgress) async throws {
        #expect(await fallback.calls == 0)
        #expect(try await store.runs(conversationID: chat, limit: 100).isEmpty)
        let events = await progress.events
        #expect(!events.contains(.stage(.checkingReadiness)))
        #expect(!events.contains(.stage(.starting)))
        #expect(!events.contains(.stage(.responding)))
        #expect(!events.contains { if case .modelObserved = $0 { return true }; return false })
        #expect(!events.contains { if case .modelConfirmed = $0 { return true }; return false })
    }
}

private struct LocalMemoryLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-local-memory-volume")
    }
}
private actor LocalMemoryInertFallback: ClaudeTextReplyServing {
    private(set) var submissions: [ClaudeTextTurnSubmission] = []
    var calls: Int { submissions.count }
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        submissions.append(submission)
        return .init(outcome: .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}
private actor LocalMemoryProgress {
    private(set) var events: [ClaudeTextTurnProgress] = []
    func append(_ event: ClaudeTextTurnProgress) { events.append(event) }
}
private struct LocalMemoryFailingPublications: MemoryConversationPublicationRepository {
    let base: SQLiteStore
    func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend, now: Date) async throws -> MemoryConversationPublicationRecord {
        throw MemoryConversationPublicationRepositoryError.invalidValidation
    }
    func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord? {
        try await base.memoryConversationPublication(id: id)
    }
    func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID) async throws -> MemoryConversationPublicationRecord? {
        try await base.memoryConversationPublication(messageID: messageID, conversationID: conversationID)
    }
}
private struct LocalMemoryMissingLinkedPublication: MemoryConversationPublicationRepository {
    let base: SQLiteStore
    let unavailableID: UUID
    var failLookup = false
    func appendMemoryConversationPublication(_ request: MemoryConversationPublicationAppend, now: Date) async throws -> MemoryConversationPublicationRecord {
        try await base.appendMemoryConversationPublication(request, now: now)
    }
    func memoryConversationPublication(id: UUID) async throws -> MemoryConversationPublicationRecord? {
        if id == unavailableID {
            if failLookup { throw LocalMemoryInjectedRepositoryFailure.unavailable }
            return nil
        }
        return try await base.memoryConversationPublication(id: id)
    }
    func memoryConversationPublication(messageID: MessageID, conversationID: ConversationID) async throws -> MemoryConversationPublicationRecord? {
        try await base.memoryConversationPublication(messageID: messageID, conversationID: conversationID)
    }
}
private enum LocalMemoryInjectedRepositoryFailure: Error { case unavailable }
private actor LocalMemoryEvidenceMessageFailure: MessageRepository {
    let base: SQLiteStore
    let sourceID: MessageID
    private(set) var failedEvidenceReads = 0
    private(set) var pageReads = 0
    init(base: SQLiteStore, sourceID: MessageID) { self.base = base; self.sourceID = sourceID }
    func message(id: MessageID) async throws -> Message? {
        if id == sourceID {
            failedEvidenceReads += 1
            throw LocalMemoryInjectedRepositoryFailure.unavailable
        }
        return try await base.message(id: id)
    }
    func page(conversationID: ConversationID, request: PageRequest) async throws -> Page<Message> {
        pageReads += 1
        return try await base.page(conversationID: conversationID, request: request)
    }
    func append(_ message: Message, expectedPreviousSequence: Int64) async throws {
        try await base.append(message, expectedPreviousSequence: expectedPreviousSequence)
    }
    func updateDeliveryState(messageID: MessageID, from expectedState: MessageDeliveryState,
                             to newState: MessageDeliveryState, updatedAt: Date) async throws {
        try await base.updateDeliveryState(messageID: messageID, from: expectedState, to: newState, updatedAt: updatedAt)
    }
}
private func localMemoryText(_ message: Message) throws -> String {
    let part = try #require(message.parts.first)
    guard message.parts.count == 1, case let .text(text) = part.content else {
        throw MemoryConversationPublicationRepositoryError.invalidStoredState
    }
    return text
}
