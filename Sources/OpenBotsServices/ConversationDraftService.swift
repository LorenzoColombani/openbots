import OpenBotsDomain

public enum ConversationDraftServiceError: Error, Equatable, Sendable {
    case invalidRepositoryResponse
}

public protocol ConversationDraftServing: Sendable {
    func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot?
    func save(
        conversationID: ConversationID,
        text: String,
        expectedRevision: UInt64
    ) async throws -> ConversationDraftSnapshot
}

/// Stores only the composer's exact text and revision. No send, runtime, outbox,
/// credentials, or filesystem authority is reachable from this service.
/// Constructing the actor does not read a repository or consult the clock.
public actor ConversationDraftService: ConversationDraftServing {
    private let repository: any ConversationDraftRepository
    private let clock: any OpenBotsClock

    public init(repository: any ConversationDraftRepository, clock: any OpenBotsClock = SystemClock()) {
        self.repository = repository
        self.clock = clock
    }

    public func load(conversationID: ConversationID) async throws -> ConversationDraftSnapshot? {
        guard let snapshot = try await repository.loadDraft(conversationID: conversationID) else { return nil }
        try validate(snapshot, conversationID: conversationID)
        return snapshot
    }

    public func save(
        conversationID: ConversationID,
        text: String,
        expectedRevision: UInt64
    ) async throws -> ConversationDraftSnapshot {
        try Task.checkCancellation()
        // Zero means absent, not an existing tombstone. Empty text still saves
        // a successor revision so an old editor cannot resurrect cleared text.
        guard expectedRevision < UInt64(Int64.max) else { throw ConversationDraftError.invalidRevision }
        let proposed = try ConversationDraftSnapshot(
            conversationID: conversationID, text: text,
            revision: expectedRevision + 1, updatedAt: clock.now()
        )
        let saved = try await repository.saveDraft(
            conversationID: conversationID, text: proposed.text,
            expectedRevision: expectedRevision, updatedAt: proposed.updatedAt
        )
        try validate(saved, conversationID: conversationID)
        guard saved.revision == proposed.revision,
              saved.text.utf8.elementsEqual(proposed.text.utf8),
              saved.updatedAt.timeIntervalSince1970 == proposed.updatedAt.timeIntervalSince1970 else {
            throw ConversationDraftServiceError.invalidRepositoryResponse
        }
        // Repository compare-and-swap failures deliberately escape unchanged;
        // neither a newer revision nor text is silently read/retried here.
        return saved
    }

    private func validate(_ snapshot: ConversationDraftSnapshot, conversationID: ConversationID) throws {
        guard snapshot.conversationID == conversationID,
              snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              snapshot.text.utf8.count <= ConversationDraftSnapshot.maximumUTF8ByteCount,
              snapshot.updatedAt.timeIntervalSince1970.isFinite else {
            throw ConversationDraftServiceError.invalidRepositoryResponse
        }
    }
}
