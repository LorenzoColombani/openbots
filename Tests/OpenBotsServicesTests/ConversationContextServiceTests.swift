import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("Conversation context service")
struct ConversationContextServiceTests {
    @Test("Load verifies the requested conversation and teammate")
    func identityValidation() async throws {
        let conversation = ConversationID(UUID())
        let teammate = TeammateID(UUID())
        let selection = ConversationContextSelection(conversationID: conversation, teammateID: teammate)
        let service = ConversationContextService(repository: ContextRepositoryDouble(selection: selection))
        #expect(try await service.load(conversationID: conversation, teammateID: teammate) == selection)
        await #expect(throws: ConversationContextError.teammateMismatch) {
            try await service.load(conversationID: conversation, teammateID: TeammateID(UUID()))
        }
        await #expect(throws: ConversationContextError.invalidRepositoryResponse) {
            try await service.load(conversationID: ConversationID(UUID()), teammateID: teammate)
        }
    }

    @Test("Save forwards exact IDs and expected revision; clear stays explicit")
    func saveAndClear() async throws {
        let conversation = ConversationID(UUID())
        let teammate = TeammateID(UUID())
        let project = ProjectID(UUID())
        let team = TeamID(UUID())
        let repository = ContextRepositoryDouble(selection: ConversationContextSelection(conversationID: conversation, teammateID: teammate))
        let service = ConversationContextService(repository: repository)
        let saved = try await service.save(conversationID: conversation, teammateID: teammate, projectID: project, teamID: team, expectedRevision: 0)
        #expect(saved == ConversationContextSelection(conversationID: conversation, teammateID: teammate, projectID: project, teamID: team, revision: 1))
        #expect(await repository.writes == [ConversationContextSelection(conversationID: conversation, teammateID: teammate, projectID: project, teamID: team)])
        let clear = try await service.save(conversationID: conversation, teammateID: teammate, projectID: nil, teamID: nil, expectedRevision: 1)
        #expect(clear.projectID == nil)
        #expect(clear.teamID == nil)
        #expect(clear.revision == 2)
    }

    @Test("Invalidation remains typed and carries no stale scope")
    func invalidatedRead() async throws {
        let conversation = ConversationID(UUID())
        let teammate = TeammateID(UUID())
        let repository = ContextRepositoryDouble(selection: ConversationContextSelection(conversationID: conversation, teammateID: teammate), loadError: .selectionInvalidated(revision: 7))
        let service = ConversationContextService(repository: repository)
        await #expect(throws: ConversationContextError.selectionInvalidated(revision: 7)) {
            try await service.load(conversationID: conversation, teammateID: teammate)
        }
        #expect(await repository.writes.isEmpty)
    }

    @Test("An absent selection cannot smuggle default scope through a repository response")
    func absentSelectionCannotContainScope() async throws {
        let conversation = ConversationID(UUID())
        let teammate = TeammateID(UUID())
        let repository = ContextRepositoryDouble(selection: ConversationContextSelection(
            conversationID: conversation, teammateID: teammate, projectID: ProjectID(UUID())
        ))
        let service = ConversationContextService(repository: repository)
        await #expect(throws: ConversationContextError.invalidRepositoryResponse) {
            try await service.load(conversationID: conversation, teammateID: teammate)
        }
    }

    @Test("Invalid revision is rejected before repository work; malformed save result fails closed")
    func malformedResponses() async throws {
        let conversation = ConversationID(UUID())
        let teammate = TeammateID(UUID())
        let repository = ContextRepositoryDouble(selection: ConversationContextSelection(conversationID: conversation, teammateID: teammate), returnMalformedSave: true)
        let service = ConversationContextService(repository: repository)
        await #expect(throws: ConversationContextError.invalidRevision) {
            try await service.save(conversationID: conversation, teammateID: teammate, projectID: nil, teamID: nil, expectedRevision: .max)
        }
        #expect(await repository.writes.isEmpty)
        await #expect(throws: ConversationContextError.invalidRepositoryResponse) {
            try await service.save(conversationID: conversation, teammateID: teammate, projectID: nil, teamID: nil, expectedRevision: 0)
        }
    }
}

private actor ContextRepositoryDouble: ConversationContextRepository {
    let selection: ConversationContextSelection
    let loadError: ConversationContextError?
    let returnMalformedSave: Bool
    private(set) var writes: [ConversationContextSelection] = []

    init(selection: ConversationContextSelection, loadError: ConversationContextError? = nil, returnMalformedSave: Bool = false) {
        self.selection = selection
        self.loadError = loadError
        self.returnMalformedSave = returnMalformedSave
    }

    func loadContext(conversationID: ConversationID) async throws -> ConversationContextSelection {
        if let loadError { throw loadError }
        return selection
    }

    func saveContext(_ selection: ConversationContextSelection) async throws -> ConversationContextSelection {
        writes.append(selection)
        if returnMalformedSave { return selection }
        return ConversationContextSelection(conversationID: selection.conversationID, teammateID: selection.teammateID, projectID: selection.projectID, teamID: selection.teamID, revision: selection.revision + 1)
    }
}
