import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing

@Suite("CharacterDefaultBaselineTests")
struct CharacterDefaultBaselineTests {
    @Test("Controlled new UUIDs allocate all five models and legacy creatures, then load without rerolling")
    func newCreationIncludesAllModelFamilies() async throws {
        var observed: Set<String> = []
        for index in 0..<64 {
            let uuid = try #require(UUID(uuidString: String(format: "86000000-0000-0000-0000-%012x", index)))
            let repository = CharacterDefaultBaselineRepository()
            let service = TeammateProfileService(repository: repository,
                clock: CharacterDefaultBaselineClock(), uuidGenerator: CharacterDefaultBaselineUUID(value: uuid))
            let created = try await service.createQuickTeammate(QuickTeammateDraft(displayName: "New Bot", role: "Local test"))
            observed.insert(created.appearance.builtInAvatarID ?? "legacy")
            #expect(created.appearance.builtInAvatarID == BuiltInAvatar.allocatedForNewIdentity(seed: created.appearance.deterministicSeed)?.rawValue)
            #expect(try await service.loadProfile(teammateID: created.id) == created)
            #expect(try await service.loadProfile(teammateID: created.id) == created)
        }
        #expect(observed == Set(["pillow", "fin", "kite", "bean", "guide", "legacy"]))
    }

    @Test("Quick-created profiles persist the current literal appearance defaults for fixed identities")
    func quickCreationDefaultsKeepTheirSavedAppearanceBaseline() async throws {
        let cases: [(uuid: String, seed: UInt64, silhouette: String, palette: String, eyes: String, cue: String)] = [
            ("85000000-0000-0000-0000-000000000001", 13_131_098_911_377_550_037, "sprout", "coral", "bright", "leaf ears"),
            ("85000000-0000-0000-0000-000000000002", 13_131_095_612_842_665_404, "round", "mint", "wide", "two antennae")
        ]
        for expected in cases {
            let uuid = try #require(UUID(uuidString: expected.uuid))
            let repository = CharacterDefaultBaselineRepository()
            let service = TeammateProfileService(
                repository: repository,
                clock: CharacterDefaultBaselineClock(),
                uuidGenerator: CharacterDefaultBaselineUUID(value: uuid)
            )
            let teammate = try await service.createQuickTeammate(
                QuickTeammateDraft(displayName: "Compatibility fixture", role: "Local test")
            )
            #expect(teammate.id == TeammateID(uuid))
            #expect(teammate.appearance.mode == .creature)
            #expect(teammate.appearance.grammarVersion == 1)
            #expect(teammate.appearance.deterministicSeed == expected.seed)
            #expect(teammate.appearance.silhouette == expected.silhouette)
            #expect(teammate.appearance.paletteToken == expected.palette)
            #expect(teammate.appearance.eyeDialect == expected.eyes)
            #expect(teammate.appearance.nonColorIdentityCue == expected.cue)
            let saved = try await service.loadProfile(teammateID: teammate.id)
            #expect(saved.appearance == teammate.appearance)
        }
    }
}

private struct CharacterDefaultBaselineClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSince1970: 850) }
}

private struct CharacterDefaultBaselineUUID: UUIDGenerator {
    let value: UUID
    func next() -> UUID { value }
}

private actor CharacterDefaultBaselineRepository: TeammateRepository {
    private var value: Teammate?

    func teammate(id: TeammateID) async throws -> Teammate? { value?.id == id ? value : nil }

    func listTeammates(includingArchived: Bool) async throws -> [Teammate] {
        guard let value, includingArchived || value.lifecycle != .archived else { return [] }
        return [value]
    }

    func insert(_ teammate: Teammate) async throws {
        guard value == nil else { throw RepositoryError.alreadyExists(entity: "teammate", id: teammate.id.persistedValue) }
        value = teammate
    }

    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        // Creating and loading a default must never mutate an existing profile.
        throw CharacterDefaultBaselineError.unexpectedUpdate
    }
}

private enum CharacterDefaultBaselineError: Error { case unexpectedUpdate }
