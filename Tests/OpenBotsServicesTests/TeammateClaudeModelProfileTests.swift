import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

struct TeammateClaudeModelProfileTests {
    @Test("Unrelated profile edits preserve even retired non-token model values")
    func unrelatedEditPreservesSavedModel() async throws {
        let (repository, service, original) = try await fixture(model: " Retired Model 🦉 ", effort: " Retired Effort 🦉 ", context: " Retired Context 🦉 ")
        let saved = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
            draft: TeammateProfileEditDraft(displayName: "New name", role: "Research"))
        #expect(saved.claudeModel == original.claudeModel)
        #expect(saved.claudeEffort == original.claudeEffort)
        #expect(saved.claudeContextWindow == original.claudeContextWindow)
        #expect(saved.profile.revision == 2)
        #expect(try await repository.teammate(id: original.id) == saved)
    }

    @Test("An explicit token changes only this bot and advances its profile revision", arguments: ["sonnet", "opus[1m]", "future-model-v9.2", String(repeating: "a", count: 200)])
    func explicitSelectionAdvancesRevision(model: String) async throws {
        let (repository, service, original) = try await fixture(model: nil)
        let other = try await service.createQuickTeammate(.init(displayName: "Other bot", role: "Writing"))
        let saved = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
            draft: TeammateProfileEditDraft(displayName: original.profile.displayName,
                role: original.profile.role, claudeModel: model))
        #expect(saved.claudeModel == model)
        #expect(saved.requestedClaudeModel == model)
        #expect(saved.profile.revision == 2)
        #expect(saved.appearance == original.appearance)
        #expect(try await repository.teammate(id: other.id) == other)
    }

    @Test("Malformed explicit choices reject without changing any stored profile", arguments: ["", " ", "sonnet\n", " sonnet", "--model", "foo/bar", "foo;bar", "🦉", "sonnet\0opus", String(repeating: "a", count: 201)])
    func invalidSelectionIsAtomic(model: String) async throws {
        let (repository, service, original) = try await fixture(model: "saved-future-model")
        await #expect(throws: DomainValidationError.self) {
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "Do not save", role: "Changed", claudeModel: model))
        }
        #expect(try await repository.teammate(id: original.id) == original)
    }

    @Test("Explicit effort including default reset advances only this bot's profile", arguments: ["low", "high", "max", "default", "future-effort"])
    func explicitEffortAdvancesRevision(effort: String) async throws {
        let (repository, service, original) = try await fixture(model: "sonnet", effort: "high")
        let other = try await service.createQuickTeammate(.init(displayName: "Other bot", role: "Writing"))
        let saved = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
            draft: TeammateProfileEditDraft(displayName: original.profile.displayName,
                role: original.profile.role, claudeEffort: effort))
        #expect(saved.claudeEffort == effort)
        #expect(saved.requestedClaudeEffort == effort)
        #expect(saved.claudeModel == original.claudeModel)
        #expect(saved.profile.revision == 2)
        #expect(try await repository.teammate(id: other.id) == other)
    }

    @Test("Invalid effort cannot publish a simultaneous valid model edit", arguments: ["", " high", "high\n", "--effort", "foo/bar", "🦉", "high\0max", String(repeating: "a", count: 201)])
    func invalidEffortIsAtomic(effort: String) async throws {
        let (repository, service, original) = try await fixture(model: "sonnet", effort: "low")
        await #expect(throws: DomainValidationError.self) {
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "Do not save", role: "Changed",
                    claudeModel: "claude-opus-5", claudeEffort: effort))
        }
        #expect(try await repository.teammate(id: original.id) == original)
    }

    @Test("Explicit context including default reset advances only this bot's profile", arguments: ["standard", "long", "default", "future-context"])
    func explicitContextAdvancesRevision(context: String) async throws {
        let (repository, service, original) = try await fixture(model: "sonnet", effort: "high", context: "long")
        let other = try await service.createQuickTeammate(.init(displayName: "Other bot", role: "Writing"))
        let saved = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
            draft: TeammateProfileEditDraft(displayName: original.profile.displayName,
                role: original.profile.role, claudeContextWindow: context))
        #expect(saved.claudeContextWindow == context)
        #expect(saved.requestedClaudeContextWindow == context)
        #expect(saved.claudeEffort == original.claudeEffort)
        #expect(saved.claudeModel == original.claudeModel)
        #expect(saved.profile.revision == 2)
        #expect(try await repository.teammate(id: other.id) == other)
    }

    @Test("Invalid context cannot publish simultaneous valid model and effort edits", arguments: ["", " long", "long\n", "--context", "foo/bar", "🦉", "long\0standard", String(repeating: "a", count: 201)])
    func invalidContextIsAtomic(context: String) async throws {
        let (repository, service, original) = try await fixture(model: "sonnet", effort: "low", context: "standard")
        await #expect(throws: DomainValidationError.self) {
            _ = try await service.saveProfile(teammateID: original.id, expectedRevision: 1,
                draft: TeammateProfileEditDraft(displayName: "Do not save", role: "Changed",
                    claudeModel: "claude-opus-5", claudeEffort: "high", claudeContextWindow: context))
        }
        #expect(try await repository.teammate(id: original.id) == original)
    }

    private func fixture(model: String?, effort: String? = nil, context: String? = nil) async throws -> (ClaudeModelProfileRepository, TeammateProfileService, Teammate) {
        let repository = ClaudeModelProfileRepository()
        let service = TeammateProfileService(repository: repository)
        var teammate = try await service.createQuickTeammate(.init(displayName: "Model QA", role: "Research"))
        teammate.claudeModel = model
        teammate.claudeEffort = effort
        teammate.claudeContextWindow = context
        try await repository.update(teammate, expectedProfileRevision: teammate.profile.revision)
        return (repository, service, teammate)
    }
}

private actor ClaudeModelProfileRepository: TeammateRepository {
    private var values: [TeammateID: Teammate] = [:]
    func teammate(id: TeammateID) async throws -> Teammate? { values[id] }
    func listTeammates(includingArchived: Bool) async throws -> [Teammate] { Array(values.values) }
    func insert(_ teammate: Teammate) async throws { values[teammate.id] = teammate }
    func update(_ teammate: Teammate, expectedProfileRevision: UInt64) async throws {
        guard values[teammate.id]?.profile.revision == expectedProfileRevision else {
            throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammate.id.persistedValue)
        }
        values[teammate.id] = teammate
    }
}
