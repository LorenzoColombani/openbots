import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("ConversationDraftServiceTests")
struct ConversationDraftServiceTests {
    @Test("Construction is inert and an absent draft remains absent")
    func inertConstructionAndAbsentLoad() async throws {
        let repository = DraftRepositoryDouble()
        let clock = DraftCountingClock()
        let service = ConversationDraftService(repository: repository, clock: clock)
        #expect(await repository.loadCalls == 0)
        #expect(await repository.saveCalls == 0)
        #expect(clock.calls == 0)
        #expect(try await service.load(conversationID: ConversationID(UUID())) == nil)
        #expect(await repository.loadCalls == 1)
        #expect(await repository.saveCalls == 0)
        #expect(clock.calls == 0)
    }

    @Test("Whitespace, Unicode byte representation, embedded NUL and empty tombstones round-trip unchanged")
    func exactTextAndTombstone() async throws {
        let repository = DraftRepositoryDouble()
        let clock = DraftCountingClock()
        let service = ConversationDraftService(repository: repository, clock: clock)
        let conversationID = ConversationID(UUID())
        let text = " \t\r\nA\u{0}e\u{301}🙂\n "
        let first = try await service.save(conversationID: conversationID, text: text, expectedRevision: 0)
        #expect(Array(first.text.utf8) == Array(text.utf8))
        #expect(first.conversationID == conversationID)
        #expect(first.revision == 1)
        #expect(first.updatedAt == clock.value)
        let loaded = try #require(await service.load(conversationID: conversationID))
        #expect(Array(loaded.text.utf8) == Array(text.utf8))
        let cleared = try await service.save(conversationID: conversationID, text: "", expectedRevision: 1)
        #expect(cleared.text.isEmpty)
        #expect(cleared.revision == 2)
        #expect(try await service.load(conversationID: conversationID) == cleared)
        await #expect(throws: ConversationDraftError.staleRevision) {
            try await service.save(conversationID: conversationID, text: text, expectedRevision: 1)
        }
        #expect(try await service.load(conversationID: conversationID) == cleared)
    }

    @Test("The limit applies to exact UTF-8 bytes, not character count")
    func byteBounds() async throws {
        let repository = DraftRepositoryDouble()
        let service = ConversationDraftService(repository: repository)
        let limit = ConversationDraftSnapshot.maximumUTF8ByteCount
        let conversationID = ConversationID(UUID())
        let text = String(repeating: "🙂", count: limit / 4)
        let saved = try await service.save(conversationID: conversationID, text: text, expectedRevision: 0)
        #expect(saved.text.utf8.count == limit)
        await #expect(throws: DomainValidationError.tooLong(field: "conversation draft UTF-8 bytes", maximum: limit)) {
            try await service.save(conversationID: conversationID, text: text + "x", expectedRevision: 1)
        }
        #expect(await repository.saveCalls == 1)
        #expect(try await service.load(conversationID: conversationID)?.revision == 1)
    }

    @Test("Wrong-conversation load receipts fail closed without writes")
    func wrongLoadReceipt() async throws {
        let wrong = try ConversationDraftSnapshot(conversationID: ConversationID(UUID()), text: "private other draft", revision: 1, updatedAt: Date())
        let repository = DraftRepositoryDouble(loadOverride: wrong)
        let service = ConversationDraftService(repository: repository)
        await #expect(throws: ConversationDraftServiceError.invalidRepositoryResponse) {
            try await service.load(conversationID: ConversationID(UUID()))
        }
        #expect(await repository.saveCalls == 0)
    }

    @Test("Save verifies conversation, revision, byte-exact text and timestamp receipts")
    func wrongSaveReceipts() async throws {
        for mutation in DraftReceiptMutation.allCases {
            let repository = DraftRepositoryDouble(mutation: mutation)
            let service = ConversationDraftService(repository: repository, clock: DraftCountingClock())
            await #expect(throws: ConversationDraftServiceError.invalidRepositoryResponse) {
                try await service.save(conversationID: ConversationID(UUID()), text: "e\u{301}", expectedRevision: 0)
            }
            #expect(await repository.saveCalls == 1)
            #expect(await repository.loadCalls == 0, "Bad receipts must not trigger a hidden read/retry.")
        }
    }

    @Test("Unrepresentable revisions and non-finite clocks fail before repository writes")
    func invalidRevisionAndTimestamp() async throws {
        let repository = DraftRepositoryDouble()
        let clock = DraftCountingClock()
        let service = ConversationDraftService(repository: repository, clock: clock)
        for revision in [UInt64(Int64.max), UInt64.max] {
            await #expect(throws: ConversationDraftError.invalidRevision) {
                try await service.save(conversationID: ConversationID(UUID()), text: "draft", expectedRevision: revision)
            }
        }
        #expect(clock.calls == 0)
        let invalidClock = DraftCountingClock(value: Date(timeIntervalSince1970: .infinity))
        let invalidService = ConversationDraftService(repository: repository, clock: invalidClock)
        await #expect(throws: ConversationDraftError.invalidTimestamp) {
            try await invalidService.save(conversationID: ConversationID(UUID()), text: "draft", expectedRevision: 0)
        }
        #expect(await repository.saveCalls == 0)
    }

    @Test("Repository failures propagate with no retry or extra read")
    func failurePropagation() async throws {
        for error in [ConversationDraftError.conversationNotFound, .conversationArchived, .staleRevision] {
            let repository = DraftRepositoryDouble(failure: error)
            let service = ConversationDraftService(repository: repository)
            await #expect(throws: error) {
                try await service.load(conversationID: ConversationID(UUID()))
            }
            await #expect(throws: error) {
                try await service.save(conversationID: ConversationID(UUID()), text: "unsaved text", expectedRevision: 0)
            }
            #expect(await repository.loadCalls == 1)
            #expect(await repository.saveCalls == 1)
        }
    }

    @Test("Concurrent stale editors have exactly one successful save")
    func concurrentCAS() async throws {
        let repository = DraftRepositoryDouble()
        let conversationID = ConversationID(UUID())
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let service = ConversationDraftService(repository: repository)
                    do {
                        _ = try await service.save(conversationID: conversationID, text: "Editor \(index)", expectedRevision: 0)
                        return true
                    } catch {
                        #expect(error as? ConversationDraftError == .staleRevision)
                        return false
                    }
                }
            }
            var count = 0
            for await saved in group where saved { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(await repository.saveCalls == 12)
        #expect(await repository.loadCalls == 0)
        #expect(try await ConversationDraftService(repository: repository).load(conversationID: conversationID)?.revision == 1)
    }
}

private enum DraftReceiptMutation: CaseIterable, Sendable {
    case identity, revision, text, canonicalUnicode, timestamp
}

private actor DraftRepositoryDouble: ConversationDraftRepository {
    private var drafts: [ConversationID: ConversationDraftSnapshot] = [:]
    private let loadOverride: ConversationDraftSnapshot?
    private let mutation: DraftReceiptMutation?
    private let failure: ConversationDraftError?
    private(set) var loadCalls = 0
    private(set) var saveCalls = 0

    init(loadOverride: ConversationDraftSnapshot? = nil, mutation: DraftReceiptMutation? = nil, failure: ConversationDraftError? = nil) {
        self.loadOverride = loadOverride
        self.mutation = mutation
        self.failure = failure
    }

    func loadDraft(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        loadCalls += 1
        if let failure { throw failure }
        return loadOverride ?? drafts[conversationID]
    }

    func saveDraft(conversationID: ConversationID, text: String, expectedRevision: UInt64, updatedAt: Date) async throws -> ConversationDraftSnapshot {
        saveCalls += 1
        if let failure { throw failure }
        guard drafts[conversationID]?.revision ?? 0 == expectedRevision else { throw ConversationDraftError.staleRevision }
        let snapshot = try ConversationDraftSnapshot(
            conversationID: mutation == .identity ? ConversationID(UUID()) : conversationID,
            text: mutation == .text ? text + "changed" : mutation == .canonicalUnicode ? "é" : text,
            revision: expectedRevision + (mutation == .revision ? 2 : 1),
            updatedAt: mutation == .timestamp ? updatedAt.addingTimeInterval(1) : updatedAt
        )
        drafts[conversationID] = snapshot
        return snapshot
    }
}

private final class DraftCountingClock: OpenBotsClock, @unchecked Sendable {
    let value: Date
    private let lock = NSLock()
    private var readCount = 0
    var calls: Int { lock.withLock { readCount } }

    init(value: Date = Date(timeIntervalSince1970: 30_000)) { self.value = value }
    func now() -> Date { lock.withLock { readCount += 1 }; return value }
}
