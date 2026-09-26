import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private struct FixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private struct FixedUUIDGenerator: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private actor TeammateRepositorySpy: TeammateRepository {
    private var values: [TeammateID: Teammate] = [:]

    func teammate(id: TeammateID) async throws -> Teammate? { values[id] }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        values.values
            .filter { includingArchived || $0.lifecycle != .archived }
            .sorted { $0.id.persistedValue < $1.id.persistedValue }
    }

    func insert(_ teammate: Teammate) async throws {
        guard values[teammate.id] == nil else {
            throw RepositoryError.alreadyExists(entity: "teammate", id: teammate.id.persistedValue)
        }
        values[teammate.id] = teammate
    }

    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        guard values[teammate.id]?.profile.revision == expectedProfileRevision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
        }
        values[teammate.id] = teammate
    }
}

@Test("Quick creation persists one stable teammate identity and functional creature profile")
func quickCreatePersistsTeammate() async throws {
    let repository = TeammateRepositorySpy()
    let uuid = UUID(uuidString: "85000000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 850)
    let service = TeammateProfileService(
        repository: repository,
        clock: FixedClock(value: now),
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )

    let teammate = try await service.createQuickTeammate(
        QuickTeammateDraft(displayName: " Ada ", role: " Research partner ")
    )

    #expect(teammate.id == TeammateID(uuid))
    #expect(teammate.profile.displayName == "Ada")
    #expect(teammate.profile.role == "Research partner")
    #expect(teammate.appearance.mode == .creature)
    #expect(!teammate.appearance.nonColorIdentityCue.isEmpty)
    #expect(teammate.createdAt == now)
    #expect(try await repository.teammate(id: teammate.id) == teammate)
}

@Test("Appearance generation is deterministic for the persistent UUID")
func deterministicAppearance() async throws {
    let uuid = UUID(uuidString: "85000000-0000-0000-0000-000000000002")!
    let firstRepository = TeammateRepositorySpy()
    let secondRepository = TeammateRepositorySpy()
    let first = TeammateProfileService(
        repository: firstRepository,
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )
    let second = TeammateProfileService(
        repository: secondRepository,
        uuidGenerator: FixedUUIDGenerator(value: uuid)
    )

    let firstTeammate = try await first.createQuickTeammate(
        QuickTeammateDraft(displayName: "Lin", role: "Builder")
    )
    let secondTeammate = try await second.createQuickTeammate(
        QuickTeammateDraft(displayName: "Lin", role: "Builder")
    )

    #expect(firstTeammate.appearance == secondTeammate.appearance)
}

@Test("Creation refuses a name a bot still carries, compared without case; an archived bot has given its name up")
func creationRefusesTakenName() async throws {
    let repository = TeammateRepositorySpy()
    let service = TeammateProfileService(repository: repository)
    let ada = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Ada", role: "Research partner"))

    for typed in ["Ada", "ada", "  ADA "] {
        await #expect(throws: TeammateNameTakenError(existingName: "Ada"), "typed \(typed)") {
            try await service.createQuickTeammate(QuickTeammateDraft(displayName: typed, role: "A second Ada"))
        }
    }
    #expect(try await repository.listTeammates(includingArchived: true) == [ada], "A refused name creates nothing")

    var archived = ada
    archived.lifecycle = .archived
    try await repository.update(archived, expectedProfileRevision: ada.profile.revision)
    let successor = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "ada", role: "Takes over"))
    #expect(successor.profile.displayName == "ada")
}

@Test("A rename refuses another bot's name, compared without case, and a bot keeps its own name in any case")
func renameRefusesTakenName() async throws {
    let repository = TeammateRepositorySpy()
    let service = TeammateProfileService(repository: repository)
    let ada = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Ada", role: "Research partner"))
    let rook = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Rook", role: "Builder"))

    await #expect(throws: TeammateNameTakenError(existingName: "Ada")) {
        try await service.saveProfile(
            teammateID: rook.id, expectedRevision: rook.profile.revision,
            draft: TeammateProfileEditDraft(displayName: " ada ", role: rook.profile.role)
        )
    }
    #expect(try await repository.teammate(id: rook.id) == rook, "A refused rename writes nothing")

    let shouted = try await service.saveProfile(
        teammateID: rook.id, expectedRevision: rook.profile.revision,
        draft: TeammateProfileEditDraft(displayName: "ROOK", role: rook.profile.role)
    )
    #expect(shouted.profile.displayName == "ROOK")

    var archived = ada
    archived.lifecycle = .archived
    try await repository.update(archived, expectedProfileRevision: ada.profile.revision)
    let renamed = try await service.saveProfile(
        teammateID: rook.id, expectedRevision: shouted.profile.revision,
        draft: TeammateProfileEditDraft(displayName: "Ada", role: rook.profile.role)
    )
    #expect(renamed.profile.displayName == "Ada", "An archived bot's name is free to take")
}

/// Two bots saved with one name before the rule existed (the old one-call
/// New Bot named every bot "New Bot") must stay editable: the rule is about
/// giving a bot a name, and a save that keeps the bot's own name gives it none.
@Test("A save that keeps the bot's own name is never refused, even while a bot from before the rule shares it; a rename into that name still is")
func keepingItsOwnNameIsNeverRefused() async throws {
    let repository = TeammateRepositorySpy()
    let service = TeammateProfileService(repository: repository)
    let ada = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Ada", role: "Research partner"))
    let twin = try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Ada", role: "Saved before the rule"),
        appearance: ada.appearance, createdAt: ada.createdAt, updatedAt: ada.updatedAt)
    try await repository.insert(twin)
    let rook = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Rook", role: "Builder"))

    let edited = try await service.saveProfile(
        teammateID: twin.id, expectedRevision: twin.profile.revision,
        draft: TeammateProfileEditDraft(displayName: "Ada", role: "Changes its role only", claudeEffort: "low")
    )
    #expect(edited.profile.displayName == "Ada")
    #expect(edited.profile.role == "Changes its role only")
    #expect(edited.claudeEffort == "low")

    await #expect(throws: TeammateNameTakenError(existingName: "Ada")) {
        try await service.saveProfile(
            teammateID: rook.id, expectedRevision: rook.profile.revision,
            draft: TeammateProfileEditDraft(displayName: "ada", role: rook.profile.role)
        )
    }
    #expect(try await repository.teammate(id: rook.id) == rook, "A rename into a shared name is still refused")

    let shouted = try await service.saveProfile(
        teammateID: ada.id, expectedRevision: ada.profile.revision,
        draft: TeammateProfileEditDraft(displayName: "ADA", role: ada.profile.role)
    )
    #expect(shouted.profile.displayName == "ADA", "Its own name in another case is still its own")
}

/// A save must not clear the mark when only the model changed: the editor's
/// first fields are the model and the notifications while the role and the
/// instructions sit inside Advanced, collapsed, so picking a model for a new
/// hire would take the hirer's name off words the person had never seen.
@Test("Saving a hired bot's model leaves its hirer named as the author; saving its words takes the name off")
func savingOnlyAModelKeepsTheHirerAsAuthor() async throws {
    let repository = TeammateRepositorySpy()
    let service = TeammateProfileService(repository: repository)
    var hired = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "Ledgerkeep", role: "Keeps the receipts"))
    hired.profileWrittenByHirer = "Canobi"
    try await repository.update(hired, expectedProfileRevision: hired.profile.revision)

    let model = try await service.saveProfile(
        teammateID: hired.id, expectedRevision: hired.profile.revision,
        draft: TeammateProfileEditDraft(displayName: hired.profile.displayName, role: hired.profile.role,
                                        claudeModel: "claude-sonnet-5", claudeEffort: "high"))
    #expect(model.claudeModel == "claude-sonnet-5")
    #expect(model.profileWrittenByHirer == "Canobi", "the person changed no word of the profile")

    let reworded = try await service.saveProfile(
        teammateID: hired.id, expectedRevision: model.profile.revision,
        draft: TeammateProfileEditDraft(displayName: hired.profile.displayName, role: "Keeps the team's receipts, reworded"))
    #expect(reworded.profileWrittenByHirer == nil, "the person saved the words, so they are theirs")
}
