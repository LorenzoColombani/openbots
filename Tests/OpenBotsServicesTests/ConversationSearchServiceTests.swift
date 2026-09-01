import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("ConversationSearchServiceTests")
struct ConversationSearchServiceTests {
    @Test("Construction is inert and empty search results cause no follow-up reads")
    func inertConstruction() async throws {
        let repository = SearchRepositoryDouble()
        let service = ConversationSearchService(repository: repository)
        #expect(await repository.searchRequests.isEmpty)
        #expect(await repository.resolvedIDs.isEmpty)
        let request = try ConversationSearchRequest(query: " Ada \"OR\"* ", limit: 2)
        let page = try await service.search(request)
        #expect(page == emptySearchPage())
        #expect(await repository.searchRequests == [request])
        #expect(await repository.resolvedIDs.isEmpty)
    }

    @Test("Valid pages preserve bounded receipts and another teammate may author a handoff")
    func validBoundedPage() async throws {
        let teammate = try searchTeammate()
        let conversationID = ConversationID(UUID())
        let message = searchMessage(
            conversationID: conversationID, teammateID: teammate.id,
            author: .teammate(TeammateID(UUID())), authorName: "Lin",
            snippet: "e\u{301}\u{0} exact local text"
        )
        let page = ConversationSearchPage(
            teammates: [TeammateSearchHit(teammate: teammate, conversationID: conversationID)],
            messages: [message], hasMoreTeammates: true, hasMoreMessages: true
        )
        let repository = SearchRepositoryDouble(page: page)
        let service = ConversationSearchService(repository: repository)
        let result = try await service.search(ConversationSearchRequest(query: "local", limit: 1))
        #expect(result == page)
        #expect(Array(result.messages[0].snippet.utf8) == Array(message.snippet.utf8))
        #expect(await repository.searchRequests.count == 1)
        #expect(await repository.resolvedIDs.isEmpty)
    }

    @Test("Each result category is independently bounded and has-more cannot invent a full page")
    func categoryBoundsAndHasMore() async throws {
        let first = TeammateSearchHit(teammate: try searchTeammate(), conversationID: ConversationID(UUID()))
        let second = TeammateSearchHit(teammate: try searchTeammate(), conversationID: ConversationID(UUID()))
        let pages = [
            ConversationSearchPage(teammates: [first, second], messages: [], hasMoreTeammates: false, hasMoreMessages: false),
            ConversationSearchPage(teammates: [], messages: [searchMessage(), searchMessage()], hasMoreTeammates: false, hasMoreMessages: false),
            ConversationSearchPage(teammates: [], messages: [], hasMoreTeammates: true, hasMoreMessages: false),
            ConversationSearchPage(teammates: [], messages: [], hasMoreTeammates: false, hasMoreMessages: true)
        ]
        for page in pages {
            let repository = SearchRepositoryDouble(page: page)
            let service = ConversationSearchService(repository: repository)
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.search(ConversationSearchRequest(query: "Ada", limit: 1))
            }
            #expect(await repository.searchRequests.count == 1)
            #expect(await repository.resolvedIDs.isEmpty)
        }
    }

    @Test("Duplicate teammate, conversation, message and per-conversation sequence identities are rejected")
    func duplicateIdentities() async throws {
        let teammate = try searchTeammate()
        let conversationID = ConversationID(UUID())
        let teammateHit = TeammateSearchHit(teammate: teammate, conversationID: conversationID)
        let message = searchMessage(conversationID: conversationID, teammateID: teammate.id)
        let pages = [
            ConversationSearchPage(
                teammates: [teammateHit, TeammateSearchHit(teammate: teammate, conversationID: ConversationID(UUID()))],
                messages: [], hasMoreTeammates: false, hasMoreMessages: false
            ),
            ConversationSearchPage(
                teammates: [teammateHit, TeammateSearchHit(teammate: try searchTeammate(), conversationID: conversationID)],
                messages: [], hasMoreTeammates: false, hasMoreMessages: false
            ),
            messagePage([message, searchMessage(id: message.id, sequence: 2)]),
            messagePage([message, searchMessage(conversationID: conversationID, teammateID: teammate.id)])
        ]
        for page in pages {
            let service = ConversationSearchService(repository: SearchRepositoryDouble(page: page))
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.search(ConversationSearchRequest(query: "Ada"))
            }
        }
    }

    @Test("A conversation cannot point to different teammates across one result page")
    func incoherentConversationOwner() async throws {
        let teammate = try searchTeammate()
        let conversationID = ConversationID(UUID())
        let pages = [
            ConversationSearchPage(
                teammates: [TeammateSearchHit(teammate: teammate, conversationID: conversationID)],
                messages: [searchMessage(conversationID: conversationID)],
                hasMoreTeammates: false, hasMoreMessages: false
            ),
            messagePage([
                searchMessage(conversationID: conversationID, teammateID: teammate.id),
                searchMessage(conversationID: conversationID, sequence: 2)
            ])
        ]
        for page in pages {
            let service = ConversationSearchService(repository: SearchRepositoryDouble(page: page))
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.search(ConversationSearchRequest(query: "Ada"))
            }
        }
    }

    @Test("Hidden, inactive and invalid-time teammate receipts never become visible results")
    func invalidTeammateReceipts() async throws {
        let valid = try searchTeammate()
        var hidden = valid
        hidden.isHidden = true
        var archived = valid
        archived.lifecycle = .archived
        var pending = valid
        pending.lifecycle = .archivePendingRunResolution
        var nonfinite = valid
        nonfinite.updatedAt = Date(timeIntervalSince1970: .infinity)
        var reversed = valid
        reversed.updatedAt = valid.createdAt.addingTimeInterval(-1)
        for teammate in [hidden, archived, pending, nonfinite, reversed] {
            let page = ConversationSearchPage(
                teammates: [TeammateSearchHit(teammate: teammate, conversationID: ConversationID(UUID()))],
                messages: [], hasMoreTeammates: false, hasMoreMessages: false
            )
            let service = ConversationSearchService(repository: SearchRepositoryDouble(page: page))
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.search(ConversationSearchRequest(query: "Ada"))
            }
        }
    }

    @Test("Message receipts require valid labels, positive sequence, finite time and a visible author class")
    func invalidMessageReceipts() async throws {
        let messages = [
            searchMessage(teammateName: " \n"),
            searchMessage(teammateName: String(repeating: "a", count: 81)),
            searchMessage(authorName: "\t"),
            searchMessage(authorName: String(repeating: "b", count: 81)),
            searchMessage(author: .system),
            searchMessage(sequence: 0),
            searchMessage(sequence: -1),
            searchMessage(sequence: Int64.max),
            searchMessage(createdAt: Date(timeIntervalSince1970: .infinity)),
            searchMessage(createdAt: Date(timeIntervalSince1970: .nan))
        ]
        for message in messages {
            let service = ConversationSearchService(repository: SearchRepositoryDouble(page: messagePage([message])))
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.search(ConversationSearchRequest(query: "private query"))
            }
        }
        #expect(String(describing: ConversationSearchServiceError.invalidRepositoryResponse) == "invalidRepositoryResponse")
    }

    @Test("The domain-bounded snippet passes through without reconstructing a full message")
    func snippetLimit() async throws {
        let message = searchMessage(snippet: String(repeating: "🙂", count: 501))
        #expect(message.snippet.count == MessageSearchHit.maximumSnippetLength)
        let repository = SearchRepositoryDouble(page: messagePage([message]))
        let result = try await ConversationSearchService(repository: repository).search(ConversationSearchRequest(query: "emoji"))
        #expect(result.messages[0].snippet == message.snippet)
        #expect(await repository.resolvedIDs.isEmpty)
    }

    @Test("Opening a search hit always re-resolves current visibility and title without caching")
    func freshTargetResolution() async throws {
        let hit = searchMessage()
        let repository = SearchRepositoryDouble(page: messagePage([hit]))
        let service = ConversationSearchService(repository: repository)
        _ = try await service.search(ConversationSearchRequest(query: "local"))
        let first = MessageSearchTarget(
            id: hit.id, conversationID: hit.conversationID, teammateID: hit.teammateID,
            sequence: hit.sequence, currentTitle: "Before rename"
        )
        await repository.setTarget(first, for: hit.id)
        #expect(try await service.resolveMessage(id: hit.id) == first)
        let current = MessageSearchTarget(
            id: hit.id, conversationID: hit.conversationID, teammateID: hit.teammateID,
            sequence: hit.sequence, currentTitle: "After rename"
        )
        await repository.setTarget(current, for: hit.id)
        #expect(try await service.resolveMessage(id: hit.id) == current)
        await repository.setTarget(nil, for: hit.id)
        #expect(try await service.resolveMessage(id: hit.id) == nil)
        #expect(await repository.resolvedIDs == [hit.id, hit.id, hit.id])
        #expect(await repository.searchRequests.count == 1)
    }

    @Test("Target receipts cannot substitute another message or invalid navigation metadata")
    func invalidTargets() async throws {
        let requestedID = MessageID(UUID())
        let conversationID = ConversationID(UUID())
        let teammateID = TeammateID(UUID())
        let targets = [
            MessageSearchTarget(id: MessageID(UUID()), conversationID: conversationID, teammateID: teammateID, sequence: 1, currentTitle: "Other private message"),
            MessageSearchTarget(id: requestedID, conversationID: conversationID, teammateID: teammateID, sequence: 0, currentTitle: "Ada"),
            MessageSearchTarget(id: requestedID, conversationID: conversationID, teammateID: teammateID, sequence: -1, currentTitle: "Ada"),
            MessageSearchTarget(id: requestedID, conversationID: conversationID, teammateID: teammateID, sequence: Int64.max, currentTitle: "Ada"),
            MessageSearchTarget(id: requestedID, conversationID: conversationID, teammateID: teammateID, sequence: 1, currentTitle: " \n"),
            MessageSearchTarget(id: requestedID, conversationID: conversationID, teammateID: teammateID, sequence: 1, currentTitle: String(repeating: "a", count: 161))
        ]
        for target in targets {
            let repository = SearchRepositoryDouble()
            await repository.setTarget(target, for: requestedID)
            let service = ConversationSearchService(repository: repository)
            await #expect(throws: ConversationSearchServiceError.invalidRepositoryResponse) {
                try await service.resolveMessage(id: requestedID)
            }
            #expect(await repository.resolvedIDs == [requestedID])
            #expect(await repository.searchRequests.isEmpty)
        }
    }

    @Test("Repository errors propagate without hidden retry or lookup")
    func readFailures() async throws {
        let repository = SearchRepositoryDouble(failure: .unavailable)
        let service = ConversationSearchService(repository: repository)
        await #expect(throws: SearchReadFailure.unavailable) {
            try await service.search(ConversationSearchRequest(query: "Ada"))
        }
        await #expect(throws: SearchReadFailure.unavailable) {
            try await service.resolveMessage(id: MessageID(UUID()))
        }
        #expect(await repository.searchRequests.count == 1)
        #expect(await repository.resolvedIDs.count == 1)
    }

    @Test("Already-cancelled callers do not invoke the repository")
    func cancelledBeforeRead() async throws {
        let repository = SearchRepositoryDouble()
        let service = ConversationSearchService(repository: repository)
        let request = try ConversationSearchRequest(query: "Ada")
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.search(request)
        }
        await #expect(throws: CancellationError.self) { try await search.value }
        let resolution = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resolveMessage(id: MessageID(UUID()))
        }
        await #expect(throws: CancellationError.self) { try await resolution.value }
        #expect(await repository.searchRequests.isEmpty)
        #expect(await repository.resolvedIDs.isEmpty)
    }

    @Test("Cancellation discards even a noncooperative repository's late search result")
    func cancelledDuringSearch() async throws {
        let suspension = SearchReadSuspension()
        let repository = SearchRepositoryDouble(suspension: suspension)
        let service = ConversationSearchService(repository: repository)
        let request = try ConversationSearchRequest(query: "Ada")
        let task = Task { try await service.search(request) }
        await suspension.waitUntilEntered()
        task.cancel()
        await suspension.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.searchRequests == [request])
    }

    @Test("Cancellation discards even a noncooperative repository's late absent target")
    func cancelledDuringResolution() async throws {
        let suspension = SearchReadSuspension()
        let repository = SearchRepositoryDouble(suspension: suspension)
        let service = ConversationSearchService(repository: repository)
        let id = MessageID(UUID())
        let task = Task { try await service.resolveMessage(id: id) }
        await suspension.waitUntilEntered()
        task.cancel()
        await suspension.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await repository.resolvedIDs == [id])
    }
}

private func emptySearchPage() -> ConversationSearchPage { messagePage([]) }

private func messagePage(_ messages: [MessageSearchHit]) -> ConversationSearchPage {
    ConversationSearchPage(teammates: [], messages: messages, hasMoreTeammates: false, hasMoreMessages: false)
}

private func searchTeammate() throws -> Teammate {
    try Teammate(
        id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Ada", role: "Research partner"),
        appearance: AgentAppearance(
            mode: .creature, grammarVersion: 1, deterministicSeed: 1, silhouette: "round",
            paletteToken: "sky", eyeDialect: "round", nonColorIdentityCue: "single crest",
            accessibleIdentityDescription: "Round creature with one crest"
        ),
        createdAt: Date(timeIntervalSince1970: 10_000), updatedAt: Date(timeIntervalSince1970: 10_000)
    )
}

private func searchMessage(
    id: MessageID = MessageID(UUID()), conversationID: ConversationID = ConversationID(UUID()),
    teammateID: TeammateID = TeammateID(UUID()), teammateName: String = "Ada",
    author: MessageAuthor = .user, authorName: String = "You", snippet: String = "Local message",
    sequence: Int64 = 1, createdAt: Date = Date(timeIntervalSince1970: 10_000)
) -> MessageSearchHit {
    MessageSearchHit(
        id: id, conversationID: conversationID, teammateID: teammateID, teammateName: teammateName,
        author: author, authorName: authorName, snippet: snippet, sequence: sequence, createdAt: createdAt
    )
}

private enum SearchReadFailure: Error, Equatable, Sendable { case unavailable }

private actor SearchRepositoryDouble: ConversationSearchRepository {
    private let page: ConversationSearchPage
    private let failure: SearchReadFailure?
    private let suspension: SearchReadSuspension?
    private var targets: [MessageID: MessageSearchTarget] = [:]
    private(set) var searchRequests: [ConversationSearchRequest] = []
    private(set) var resolvedIDs: [MessageID] = []

    init(
        page: ConversationSearchPage = emptySearchPage(), failure: SearchReadFailure? = nil,
        suspension: SearchReadSuspension? = nil
    ) {
        self.page = page
        self.failure = failure
        self.suspension = suspension
    }

    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        searchRequests.append(request)
        if let failure { throw failure }
        if let suspension { await suspension.suspend() }
        return page
    }

    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? {
        resolvedIDs.append(id)
        if let failure { throw failure }
        if let suspension { await suspension.suspend() }
        return targets[id]
    }

    func setTarget(_ target: MessageSearchTarget?, for id: MessageID) { targets[id] = target }
}

/// A deliberately noncooperative fake read; cancellation must not publish its
/// eventual result. Tests explicitly release it, without polling or sleeps.
private actor SearchReadSuspension {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { readWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        readWaiter?.resume()
        readWaiter = nil
    }
}
