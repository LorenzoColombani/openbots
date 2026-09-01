import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

@Suite("TeammateProfileEditingTests")
struct TeammateProfileEditingTests {
    @Test("Built-in model choices preserve the saved grammar and change only the explicit appearance")
    func builtInModelsPreserveGeneratedIdentity() async throws {
        for avatar in BuiltInAvatar.allCases {
            let original = try profileEditingTeammate(photo: true)
            let repository = ProfileEditingRepository(original)
            let service = TeammateProfileService(repository: repository)
            let saved = try await service.saveProfile(
                teammateID: original.id, expectedRevision: original.profile.revision,
                draft: TeammateProfileEditDraft(
                    displayName: original.profile.displayName, title: original.profile.title,
                    role: original.profile.role, detailedInstructions: original.profile.detailedInstructions,
                    builtInAvatar: avatar
                )
            )
            let before = original.appearance
            #expect(saved.appearance == (try AgentAppearance(
                mode: .creature, grammarVersion: before.grammarVersion,
                deterministicSeed: before.deterministicSeed, silhouette: before.silhouette,
                paletteToken: before.paletteToken, eyeDialect: before.eyeDialect,
                nonColorIdentityCue: before.nonColorIdentityCue,
                accessibleIdentityDescription: before.accessibleIdentityDescription,
                builtInAvatarID: avatar.rawValue, revision: before.revision + 1
            )))
            #expect(saved.profile.displayName == original.profile.displayName)
            #expect(saved.profile.title == original.profile.title)
            #expect(saved.profile.role == original.profile.role)
            #expect(saved.profile.detailedInstructions == original.profile.detailedInstructions)
            #expect(saved.id == original.id)
            #expect(saved.lifecycle == original.lifecycle)
            #expect(saved.isHidden == original.isHidden)
            #expect(saved.isPinned == original.isPinned)
            #expect(saved.notificationPreference == original.notificationPreference)
            #expect(await repository.updateCount == 1)
            let textSaved = try await service.saveProfile(
                teammateID: saved.id, expectedRevision: saved.profile.revision,
                draft: TeammateProfileEditDraft(displayName: "New text", role: saved.profile.role)
            )
            #expect(textSaved.appearance == saved.appearance)
        }
    }

    @Test("A built-in model cannot be combined with another appearance write")
    func builtInChoiceConflictsAreAtomic() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let service = TeammateProfileService(repository: repository)
        for draft in [
            TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", creature: profileEditingCreature(), builtInAvatar: .guide),
            TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", photoAssetID: ProfileAssetID(UUID()), builtInAvatar: .fin)
        ] {
            await #expect(throws: ProfilePhotoServiceError.conflictingAppearanceChoices) {
                try await service.saveProfile(teammateID: original.id, expectedRevision: original.profile.revision, draft: draft)
            }
        }
        #expect(await repository.updateCount == 0)
    }

    @Test("A photo changes only explicit appearance fields after validating the owned asset")
    func photoAssignmentPreservesCreatureIdentity() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let validator = ProfileEditingPhotoValidator()
        let service = TeammateProfileService(repository: repository, photoValidator: validator)
        let photoID = ProfileAssetID(UUID())
        let saved = try await service.saveProfile(
            teammateID: original.id, expectedRevision: original.profile.revision,
            draft: TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", photoAssetID: photoID)
        )
        #expect(await validator.ids == [photoID])
        #expect(saved.appearance.mode == .photo)
        #expect(saved.appearance.profileAssetID == photoID)
        #expect(saved.appearance.revision == original.appearance.revision + 1)
        #expect(saved.appearance.deterministicSeed == original.appearance.deterministicSeed)
        #expect(saved.appearance.grammarVersion == original.appearance.grammarVersion)
        #expect(saved.appearance.silhouette == original.appearance.silhouette)
        #expect(saved.appearance.paletteToken == original.appearance.paletteToken)
        #expect(saved.appearance.eyeDialect == original.appearance.eyeDialect)
        #expect(saved.appearance.nonColorIdentityCue == original.appearance.nonColorIdentityCue)
        #expect(saved.appearance.accessibleIdentityDescription == original.appearance.accessibleIdentityDescription)
        #expect(saved.profile.revision == original.profile.revision + 1)
        #expect(saved.id == original.id)
        #expect(saved.lifecycle == original.lifecycle)
        #expect(saved.isHidden == original.isHidden)
        #expect(saved.isPinned == original.isPinned)
        #expect(saved.notificationPreference == original.notificationPreference)
    }

    @Test("No photo validator or rejected asset cannot persist a profile reference")
    func rejectedPhotoIsAtomic() async throws {
        for validator: ProfileEditingPhotoValidator? in [nil, ProfileEditingPhotoValidator(reject: true)] {
            let original = try profileEditingTeammate()
            let repository = ProfileEditingRepository(original)
            let service = TeammateProfileService(repository: repository, photoValidator: validator)
            await #expect(throws: ProfilePhotoServiceError.unavailable) {
                try await service.saveProfile(
                    teammateID: original.id, expectedRevision: original.profile.revision,
                    draft: TeammateProfileEditDraft(displayName: "Changed", role: "Changed", photoAssetID: ProfileAssetID(UUID()))
                )
            }
            #expect(await repository.updateCount == 0)
            #expect(try await service.loadProfile(teammateID: original.id) == original)
        }
    }

    @Test("Conflicting creature and photo choices fail before asset validation or profile writes")
    func conflictingAppearanceChoices() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let validator = ProfileEditingPhotoValidator()
        let service = TeammateProfileService(repository: repository, photoValidator: validator)
        await #expect(throws: ProfilePhotoServiceError.conflictingAppearanceChoices) {
            try await service.saveProfile(
                teammateID: original.id, expectedRevision: original.profile.revision,
                draft: TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", creature: profileEditingCreature(), photoAssetID: ProfileAssetID(UUID()))
            )
        }
        #expect(await validator.ids.isEmpty)
        #expect(await repository.updateCount == 0)
    }

    @Test("Loading is read-only and missing identities fail explicitly")
    func loadAndMissingIdentity() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let service: any TeammateProfileEditing = TeammateProfileService(repository: repository)
        #expect(try await service.loadProfile(teammateID: original.id) == original)
        let missingID = TeammateID(UUID())
        await #expect(throws: RepositoryError.notFound(entity: "teammate", id: missingID.persistedValue)) {
            try await service.loadProfile(teammateID: missingID)
        }
        #expect(await repository.updateCount == 0)
    }

    @Test("Text edits advance revision, clear optional text, and preserve appearance and unrelated settings")
    func textEditPreservesIdentityAndAppearance() async throws {
        let original = try profileEditingTeammate(photo: true)
        let repository = ProfileEditingRepository(original)
        let service = TeammateProfileService(repository: repository, clock: ProfileEditingClock())
        let saved = try await service.saveProfile(
            teammateID: original.id,
            expectedRevision: original.profile.revision,
            draft: TeammateProfileEditDraft(displayName: " Ada Revised ", role: " Research lead ")
        )
        #expect(saved.profile.displayName == "Ada Revised")
        #expect(saved.profile.role == "Research lead")
        #expect(saved.profile.title == nil)
        #expect(saved.profile.detailedInstructions == nil)
        #expect(saved.profile.revision == original.profile.revision + 1)
        #expect(saved.appearance == original.appearance)
        #expect(saved.id == original.id)
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.updatedAt == ProfileEditingClock().now())
        #expect(saved.lifecycle == original.lifecycle)
        #expect(saved.isPinned == original.isPinned)
        #expect(saved.isHidden == original.isHidden)
        #expect(saved.notificationPreference == original.notificationPreference)
        #expect(try await service.loadProfile(teammateID: saved.id) == saved)

        let repeated = try await service.saveProfile(
            teammateID: saved.id,
            expectedRevision: saved.profile.revision,
            draft: TeammateProfileEditDraft(displayName: saved.profile.displayName, role: saved.profile.role)
        )
        #expect(repeated.profile.revision == saved.profile.revision + 1)
        #expect(repeated.appearance == original.appearance)
    }

    @Test("Explicit creature changes preserve seed and grammar while revising the accessible identity")
    func canonicalCreatureChoicesAndPhotoConversion() async throws {
        let original = try profileEditingTeammate(photo: true)
        let repository = ProfileEditingRepository(original)
        let service = TeammateProfileService(repository: repository)
        var current = original
        for index in 0..<TeammateCreatureDraft.paletteTokens.count {
            let creature = TeammateCreatureDraft(
                silhouette: TeammateCreatureDraft.silhouettes[index % TeammateCreatureDraft.silhouettes.count],
                paletteToken: TeammateCreatureDraft.paletteTokens[index],
                eyeDialect: TeammateCreatureDraft.eyeDialects[index % TeammateCreatureDraft.eyeDialects.count],
                nonColorIdentityCue: TeammateCreatureDraft.nonColorIdentityCues[index % TeammateCreatureDraft.nonColorIdentityCues.count]
            )
            let saved = try await service.saveProfile(
                teammateID: current.id,
                expectedRevision: current.profile.revision,
                draft: TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", creature: creature)
            )
            #expect(saved.appearance.mode == .creature)
            #expect(saved.appearance.profileAssetID == nil)
            #expect(saved.appearance.grammarVersion == original.appearance.grammarVersion)
            #expect(saved.appearance.deterministicSeed == original.appearance.deterministicSeed)
            #expect(saved.appearance.revision == current.appearance.revision + 1)
            #expect(saved.appearance.silhouette == creature.silhouette)
            #expect(saved.appearance.paletteToken == creature.paletteToken)
            #expect(saved.appearance.eyeDialect == creature.eyeDialect)
            #expect(saved.appearance.nonColorIdentityCue == creature.nonColorIdentityCue)
            #expect(saved.appearance.accessibleIdentityDescription.contains(creature.nonColorIdentityCue))
            #expect(saved.appearance.accessibleIdentityDescription.contains(creature.eyeDialect))
            current = saved
        }
    }

    @Test("Invalid text or any unsupported creature token fails without a repository write")
    func invalidInputIsAtomic() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let service = TeammateProfileService(repository: repository)
        let invalidText = [
            TeammateProfileEditDraft(displayName: " ", role: "Researcher"),
            TeammateProfileEditDraft(displayName: String(repeating: "x", count: 81), role: "Researcher"),
            TeammateProfileEditDraft(displayName: "Ada", title: String(repeating: "x", count: 121), role: "Researcher"),
            TeammateProfileEditDraft(displayName: "Ada", role: " "),
            TeammateProfileEditDraft(displayName: "Ada", role: String(repeating: "x", count: 241)),
            TeammateProfileEditDraft(displayName: "Ada", role: "Researcher", detailedInstructions: String(repeating: "x", count: 20_001))
        ]
        let invalidCreatures = [
            TeammateCreatureDraft(silhouette: "../photo", paletteToken: "mint", eyeDialect: "calm", nonColorIdentityCue: "leaf ears"),
            TeammateCreatureDraft(silhouette: "round", paletteToken: "unknown", eyeDialect: "calm", nonColorIdentityCue: "leaf ears"),
            TeammateCreatureDraft(silhouette: "round", paletteToken: "mint", eyeDialect: "unknown", nonColorIdentityCue: "leaf ears"),
            TeammateCreatureDraft(silhouette: "round", paletteToken: "mint", eyeDialect: "calm", nonColorIdentityCue: ""),
            TeammateCreatureDraft(silhouette: "Round", paletteToken: "mint", eyeDialect: "calm", nonColorIdentityCue: "leaf ears")
        ]
        let drafts = invalidText + invalidCreatures.map {
            TeammateProfileEditDraft(displayName: "Changed", role: "Changed", creature: $0)
        }
        for draft in drafts {
            await #expect(throws: DomainValidationError.self) {
                try await service.saveProfile(teammateID: original.id, expectedRevision: original.profile.revision, draft: draft)
            }
            #expect(try await service.loadProfile(teammateID: original.id) == original)
        }
        #expect(await repository.updateCount == 0)
    }

    @Test("Competing editors get one winner and a stale draft never silently retries")
    func concurrentEditsHaveOneWinner() async throws {
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let service = TeammateProfileService(repository: repository)
                    do {
                        _ = try await service.saveProfile(
                            teammateID: original.id,
                            expectedRevision: original.profile.revision,
                            draft: TeammateProfileEditDraft(displayName: "Editor \(index)", role: "Researcher")
                        )
                        return true
                    } catch {
                        #expect(error as? RepositoryError == .optimisticLockFailed(entity: "teammate", id: original.id.persistedValue))
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(await repository.updateCount == 1)
        let service = TeammateProfileService(repository: repository)
        let winner = try await service.loadProfile(teammateID: original.id)
        #expect(winner.profile.revision == original.profile.revision + 1)
        await #expect(throws: RepositoryError.optimisticLockFailed(entity: "teammate", id: original.id.persistedValue)) {
            try await service.saveProfile(teammateID: original.id, expectedRevision: original.profile.revision, draft: TeammateProfileEditDraft(displayName: "Stale", role: "Researcher"))
        }
        #expect(try await service.loadProfile(teammateID: original.id) == winner)
    }

    @Test("Revision exhaustion fails before writes and a backward clock cannot regress timestamps")
    func revisionLimitsAndClock() async throws {
        for (profileRevision, appearanceRevision, creature) in [
            (UInt64.max, UInt64(1), Optional<TeammateCreatureDraft>.none),
            (UInt64(1), UInt64.max, Optional(profileEditingCreature()))
        ] {
            let original = try profileEditingTeammate(profileRevision: profileRevision, appearanceRevision: appearanceRevision)
            let repository = ProfileEditingRepository(original)
            let service = TeammateProfileService(repository: repository)
            await #expect(throws: DomainValidationError.self) {
                try await service.saveProfile(teammateID: original.id, expectedRevision: original.profile.revision, draft: TeammateProfileEditDraft(displayName: "Changed", role: "Researcher", creature: creature))
            }
            #expect(await repository.updateCount == 0)
            #expect(try await service.loadProfile(teammateID: original.id) == original)
        }
        let original = try profileEditingTeammate()
        let repository = ProfileEditingRepository(original)
        let service = TeammateProfileService(repository: repository, clock: ProfileEditingClock(value: Date(timeIntervalSince1970: 0)))
        let saved = try await service.saveProfile(teammateID: original.id, expectedRevision: original.profile.revision, draft: TeammateProfileEditDraft(displayName: "Ada", role: "Researcher"))
        #expect(saved.updatedAt == original.updatedAt)
    }
}

private actor ProfileEditingPhotoValidator: ProfilePhotoValidating {
    let reject: Bool
    private(set) var ids: [ProfileAssetID] = []
    init(reject: Bool = false) { self.reject = reject }
    func validatePhoto(id: ProfileAssetID) async throws {
        ids.append(id)
        if reject { throw ProfilePhotoServiceError.unavailable }
    }
}

private struct ProfileEditingClock: OpenBotsClock {
    var value = Date(timeIntervalSince1970: 20_000)
    func now() -> Date { value }
}

private actor ProfileEditingRepository: TeammateRepository {
    private var teammateValue: Teammate
    private(set) var updateCount = 0

    init(_ teammate: Teammate) { teammateValue = teammate }

    func teammate(id: TeammateID) async throws -> Teammate? { id == teammateValue.id ? teammateValue : nil }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { [teammateValue] }
    func insert(_ teammate: Teammate) async throws { teammateValue = teammate }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        guard teammateValue.id == teammate.id, teammateValue.profile.revision == expectedProfileRevision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
        }
        teammateValue = teammate
        updateCount += 1
    }
}

private func profileEditingCreature() -> TeammateCreatureDraft {
    TeammateCreatureDraft(silhouette: "sprout", paletteToken: "mint", eyeDialect: "bright", nonColorIdentityCue: "leaf ears")
}

private func profileEditingTeammate(
    photo: Bool = false,
    profileRevision: UInt64 = 3,
    appearanceRevision: UInt64 = 4
) throws -> Teammate {
    try Teammate(
        id: TeammateID(UUID(uuidString: "92000000-0000-0000-0000-000000000001")!),
        profile: TeammateProfile(displayName: "Ada", title: "Partner", role: "Researcher", detailedInstructions: "Check sources", revision: profileRevision),
        appearance: AgentAppearance(
            mode: photo ? .photo : .creature,
            grammarVersion: 2,
            deterministicSeed: 42,
            silhouette: "round",
            paletteToken: "violet",
            eyeDialect: "calm",
            nonColorIdentityCue: "soft crown",
            accessibleIdentityDescription: "Round creature with soft crown",
            profileAssetID: photo ? ProfileAssetID(UUID(uuidString: "92000000-0000-0000-0000-000000000002")!) : nil,
            revision: appearanceRevision
        ),
        lifecycle: .archivePendingRunResolution,
        isPinned: true,
        isHidden: true,
        notificationPreference: .disabled,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )
}
