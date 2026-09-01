import Foundation
import OpenBotsDomain

public enum ConversationSearchServiceError: Error, Equatable, Sendable {
    case invalidRepositoryResponse
}

public protocol ConversationSearchServing: Sendable {
    func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage
    func resolveMessage(id: MessageID) async throws -> MessageSearchTarget?
}

/// A read-only boundary for bounded local search. It holds no transcript cache,
/// runtime, credential, or filesystem authority. Construction performs no work.
public actor ConversationSearchService: ConversationSearchServing {
    private let repository: any ConversationSearchRepository

    public init(repository: any ConversationSearchRepository) {
        self.repository = repository
    }

    public func search(_ request: ConversationSearchRequest) async throws -> ConversationSearchPage {
        try Task.checkCancellation()
        let page = try await repository.search(request)
        try Task.checkCancellation()
        try validate(page, limit: request.limit)
        return page
    }

    public func resolveMessage(id: MessageID) async throws -> MessageSearchTarget? {
        try Task.checkCancellation()
        // Search hits are not navigation authority. Resolve visibility and the
        // current target afresh even if this service returned a hit moments ago.
        let target = try await repository.resolveMessage(id: id)
        try Task.checkCancellation()
        guard let target else { return nil }
        guard target.id == id,
              target.sequence > 0, target.sequence < Int64.max,
              isDisplayLabel(target.currentTitle, maximum: 160) else {
            throw ConversationSearchServiceError.invalidRepositoryResponse
        }
        return target
    }

    private func validate(_ page: ConversationSearchPage, limit: Int) throws {
        guard page.teammates.count <= limit, page.messages.count <= limit,
              !page.hasMoreTeammates || page.teammates.count == limit,
              !page.hasMoreMessages || page.messages.count == limit else {
            throw ConversationSearchServiceError.invalidRepositoryResponse
        }

        var teammateIDs = Set<TeammateID>()
        var teammateConversationIDs = Set<ConversationID>()
        var conversationOwners: [ConversationID: TeammateID] = [:]
        for hit in page.teammates {
            let teammate = hit.teammate
            guard teammateIDs.insert(teammate.id).inserted,
                  teammateConversationIDs.insert(hit.conversationID).inserted,
                  teammate.lifecycle == .active, !teammate.isHidden,
                  isDisplayLabel(teammate.profile.displayName, maximum: 80),
                  teammate.createdAt.timeIntervalSince1970.isFinite,
                  teammate.updatedAt.timeIntervalSince1970.isFinite,
                  teammate.updatedAt >= teammate.createdAt else {
                throw ConversationSearchServiceError.invalidRepositoryResponse
            }
            conversationOwners[hit.conversationID] = teammate.id
        }

        var messageIDs = Set<MessageID>()
        var conversationSequences: [ConversationID: Set<Int64>] = [:]
        for hit in page.messages {
            guard messageIDs.insert(hit.id).inserted,
                  conversationSequences[hit.conversationID, default: []].insert(hit.sequence).inserted,
                  hit.sequence > 0, hit.sequence < Int64.max,
                  hit.createdAt.timeIntervalSince1970.isFinite,
                  isDisplayLabel(hit.teammateName, maximum: 80),
                  isDisplayLabel(hit.authorName, maximum: 80),
                  hit.snippet.count <= MessageSearchHit.maximumSnippetLength,
                  hit.author != .system,
                  conversationOwners[hit.conversationID].map({ $0 == hit.teammateID }) ?? true else {
                throw ConversationSearchServiceError.invalidRepositoryResponse
            }
            // The author may be another teammate (for example a handoff); the
            // direct conversation owner and message author are distinct roles.
            conversationOwners[hit.conversationID] = hit.teammateID
        }
    }

    private func isDisplayLabel(_ value: String, maximum: Int) -> Bool {
        value.count <= maximum && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
