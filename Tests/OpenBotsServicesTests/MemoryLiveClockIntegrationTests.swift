import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsPersistence
import Testing
@testable import OpenBotsServices

@Suite("Memory timestamps at native Date precision")
struct MemoryLiveClockIntegrationTests {
    @Test("Capture, overview and exact retries survive both directions of SQLite epoch rounding",
          arguments: [NativeMemoryClockCase.roundsEarlier, .roundsLater])
    func nativePrecisionRoundTrip(_ sample: NativeMemoryClockCase) async throws {
        let native = sample.date
        let persisted = Date(timeIntervalSince1970: native.timeIntervalSince1970)
        // This is a deterministic native-Date precision boundary, not a whole-
        // second fixture or a probabilistic dependency on the wall clock.
        try #require(native != persisted)
        #expect(native.timeIntervalSince1970 == persisted.timeIntervalSince1970)
        switch sample {
        case .roundsEarlier: #expect(persisted < native)
        case .roundsLater: #expect(persisted > native)
        }

        let fixture = try NativeMemoryClockFixture(); defer { fixture.remove() }
        let database = try fixture.open(); try await fixture.seed(database)
        let authority = try await fixture.authority()
        let fallback = NativeMemoryClockFallback()
        let captureService = fixture.service(database, authority: authority, fallback: fallback, now: native)
        let capture = fixture.submission("Remember that I prefer quiet libraries, except on Fridays.")
        let captured = await captureService.sendText(capture) { _ in }
        #expect(captured.outcome == .completed)
        let actualUser = try #require(try await database.message(id: capture.userMessageID))
        #expect(actualUser.author == .user && actualUser.deliveryState == .completed)
        #expect(actualUser.parts.first?.content == .text(capture.text))
        let marker = try #require(try await database.memoryLocalCorrection(userMessageID: capture.userMessageID))
        #expect(marker.state == .acknowledged)
        #expect(marker.userMessage == actualUser)
        #expect(marker.acknowledgement?.author == .system)
        let publication = try #require(try await database.memoryPublication(id: marker.request.operationID))
        #expect(publication.state == .committed)
        let document = try #require(try await database.document(id: marker.request.documentID))
        let file = authority.url.appending(path: document.relativePath)
        let exactBytes = try Data(contentsOf: file)
        let artifact = try #require(MemoryClaimCodec().decode(exactBytes, expecting: document).artifact)
        #expect(artifact.claims.count == 1)
        #expect(artifact.claims[0].body == "I prefer quiet libraries, except on Fridays.")
        #expect(artifact.claims[0].assessment.level == .uncertain)

        let overviewSubmission = fixture.submission("What do you remember about me?")
        let overview = await fixture.service(database, authority: authority, fallback: fallback,
            now: native.addingTimeInterval(1)).sendText(overviewSubmission) { _ in }
        #expect(overview.outcome == .completed)
        let reply = try #require(overview.savedReplyMessage)
        guard case let .text(replyText) = reply.parts.first?.content else {
            Issue.record("The real memory overview did not return text"); return
        }
        #expect(reply.author == .system && reply.deliveryState == .completed)
        #expect(replyText.contains(artifact.claims[0].body))
        let projection = try #require(try await database.memoryConversationPublication(messageID: reply.id,
            conversationID: fixture.chat))
        #expect(projection.publication.receipt.dependencies.contains { $0.reference.claimID == artifact.claims[0].id })

        let reopened = try fixture.open()
        let reopenedService = fixture.service(reopened, authority: authority, fallback: fallback,
            now: native.addingTimeInterval(2))
        let captureRetry = await reopenedService.sendText(capture) { _ in }
        let overviewRetry = await reopenedService.sendText(overviewSubmission) { _ in }
        #expect(captureRetry == captured)
        #expect(overviewRetry == overview)
        #expect(try await reopened.memoryLocalCorrection(userMessageID: capture.userMessageID) == marker)
        #expect(try await reopened.memoryConversationPublication(messageID: reply.id, conversationID: fixture.chat) == projection)
        #expect(try await reopened.page(conversationID: fixture.chat, request: PageRequest(limit: 10)).elements.count == 4)
        #expect(try Data(contentsOf: file) == exactBytes)
        #expect(try await reopened.runs(conversationID: fixture.chat, limit: 10).isEmpty)
        #expect(await fallback.calls == 0)
    }
}

enum NativeMemoryClockCase: Sendable {
    case roundsEarlier, roundsLater
    var date: Date {
        let seconds = Double(810_000_000)
        switch self {
        case .roundsEarlier: return Date(timeIntervalSinceReferenceDate: seconds.nextUp)
        case .roundsLater: return Date(timeIntervalSinceReferenceDate: seconds.nextDown)
        }
    }
}

private struct NativeMemoryClockLocation: MacOSLocationAdmissionChecking {
    func observation(for url: URL) async throws -> LocationObservation {
        .init(isLocalVolume: true, isReadOnlyVolume: false, isUbiquitousItem: false,
              fileProviderStatus: .notManaged, volumeIdentifier: "synthetic-native-clock-volume")
    }
}

private struct NativeMemoryClockFixture: Sendable {
    let root: URL
    let layout: PreviewStorageLayout
    let plan: PreviewRootCreationPlan
    let protection: ProtectionDecisionReceipt
    let bot = TeammateID(UUID()), chat = ConversationID(UUID())
    let seedDate = Date(timeIntervalSinceReferenceDate: 809_999_990)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/OpenBotsNextNativeMemoryClock-\(UUID()).noindex", isDirectory: true)
        let home = root.appending(path: "Home", directoryHint: .isDirectory)
        let temporary = root.appending(path: "SystemTemporary", directoryHint: .isDirectory)
        for directory in [home.appending(path: "Library/Application Support", directoryHint: .isDirectory),
                          home.appending(path: "Library/Caches", directoryHint: .isDirectory), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        layout = PreviewStorageLayout(homeDirectory: home, systemTemporaryDirectory: temporary)
        plan = try PreviewRootCreationPlan(layout: layout, installationID: UUID(),
            rootIDs: [.applicationSupport: UUID(), .caches: UUID(), .temporary: UUID()])
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: seedDate, rationaleVersion: 2)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: root.appending(path: "control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func authority() async throws -> VerifiedAuthoritativeMarkdownRoot {
        let receipt = try await StorageBootstrapService(layout: layout,
            locationAdmission: NativeMemoryClockLocation()).bootstrap(using: plan)
        let verified = try #require(receipt.verifiedRoots.first { $0.kind == .applicationSupport })
        return try AuthoritativeMarkdownRootVerifier().verify(layout.internalMemoryRoot, inside: verified)
    }
    func seed(_ database: SQLiteStore) async throws {
        let teammate = try Teammate(id: bot, profile: TeammateProfile(displayName: "Clock Fixture", role: "Synthetic QA"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6,
                silhouette: "round", paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest",
                accessibleIdentityDescription: "Round creature"), createdAt: seedDate, updatedAt: seedDate)
        try await database.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chat, kind: .direct(teammateID: bot), createdAt: seedDate, updatedAt: seedDate),
            fixtureGreeting: nil, selectConversation: false)
    }
    func service(_ database: SQLiteStore, authority: VerifiedAuthoritativeMarkdownRoot,
                 fallback: NativeMemoryClockFallback, now: Date) -> MemoryLocalConversationService {
        let corrections = MemoryLocalCorrectionService(corrections: database, memory: database, intents: database,
            contexts: database, conversationContexts: database, teammates: database, messages: database,
            authority: authority, publications: database, clock: { now })
        return MemoryLocalConversationService(fallback: fallback, corrections: corrections, memory: database,
            intents: database, contexts: database, selections: database, messages: database, teammates: database,
            publications: database, authority: authority, clock: { now })
    }
    func submission(_ text: String) -> ClaudeTextTurnSubmission {
        .init(conversationID: chat, teammateID: bot, userMessageID: MessageID(UUID()), text: text)
    }
}

private actor NativeMemoryClockFallback: ClaudeTextReplyServing {
    private(set) var calls = 0
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        calls += 1
        return .init(outcome: .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}
