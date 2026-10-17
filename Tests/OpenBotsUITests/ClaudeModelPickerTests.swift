import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

@MainActor
final class ClaudeModelPickerTests: XCTestCase {
    func testSavedAliasesAreAvailablePreferencesAndKeepTheirExactValues() async throws {
        for alias in ["sonnet", "opus", "haiku", "default"] {
            XCTAssertTrue(ClaudeModelCatalog.contains(alias, in: ClaudeModelPolicy.bundled))
            XCTAssertEqual(ClaudeModelCatalog.savedPreferenceLabel(for: alias, in: ClaudeModelPolicy.bundled),
                           "\(alias.capitalized) · Existing preference")
            var teammate = try modelPickerTeammate()
            teammate.claudeModel = alias
            let editor = TeammateProfileEditorModel(service: ModelPickerProfileService(teammate), teammateID: teammate.id)
            await editor.load()
            editor.title = "Updated label"
            let saved = await editor.save()
            XCTAssertEqual(saved?.claudeModel, alias)
        }
    }

    func testSavedPreferenceAvailabilityUsesTheCurrentCatalogIncludingAliases() throws {
        let catalog = try ClaudeModelCatalogSnapshot.parse(modelsJSON: Data("""
        [{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus"}]
        """.utf8), checkedAt: Date())
        XCTAssertTrue(ClaudeModelCatalog.contains("opus", in: catalog))
        XCTAssertTrue(ClaudeModelCatalog.contains("claude-opus-5-5", in: catalog))
        for unavailable in ["haiku", "retired-model", "claude-mythos-5-1"] {
            XCTAssertFalse(ClaudeModelCatalog.contains(unavailable, in: catalog))
            XCTAssertEqual(ClaudeModelCatalog.savedPreferenceLabel(for: unavailable, in: catalog),
                           "Saved preference: \(unavailable) (not in catalog)")
        }
    }

    func testLiveCatalogPresentationIsSanitizedAndLabelsItsSource() throws {
        let catalog = try ClaudeModelCatalogSnapshot.parse(modelsJSON: Data("""
        [{"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet","description":"$2/$10 per Mtok"}]
        """.utf8), checkedAt: Date())
        let options = ClaudeModelCatalog.options(in: catalog)
        XCTAssertEqual(options.map(\.id), ["claude-sonnet-5-5"])
        XCTAssertEqual(options.first?.menuLabel, "Sonnet 5.5")
        XCTAssertFalse(options.contains { $0.detail.contains("$") || $0.menuLabel.contains("1M") })
        XCTAssertTrue(ClaudeModelCatalog.availabilityNote(for: catalog).contains("from Claude Code"))
        XCTAssertTrue(ClaudeModelCatalog.availabilityNote(for: ClaudeModelPolicy.bundled).contains("bundled model list"))
    }

    func testMismatchNoticeNamesActualModelAndNormalizedAliasesDoNotWarn() {
        var presentation = ClaudeModelRunPresentation()
        presentation.confirmedRequest = "claude-sonnet-5-5"
        presentation.confirmedModel = "claude-opus-5-5"
        XCTAssertTrue(presentation.mismatchNotice?.contains("Opus 5.5") == true)
        XCTAssertTrue(presentation.mismatchNotice?.contains("unchanged") == true)
        presentation.confirmedRequest = "sonnet"
        presentation.confirmedModel = "claude-sonnet-5"
        XCTAssertNil(presentation.mismatchNotice)
        presentation.confirmedRequest = "claude-opus-4-6"
        presentation.confirmedModel = "claude-opus-4-6[1m]"
        XCTAssertNil(presentation.mismatchNotice)
    }

    func testMismatchNoticeWarnsWhenAnUnrequestedSubstituteCanBillCredits() {
        var presentation = ClaudeModelRunPresentation()
        presentation.confirmedRequest = "claude-sonnet-5-5"
        presentation.confirmedModel = "claude-fable-5-1"
        XCTAssertTrue(presentation.mismatchNotice?.contains("usage credits") == true)
        // A Fable request was already warned under the picker.
        presentation.confirmedRequest = "claude-fable-5-1"
        presentation.confirmedModel = "claude-opus-5-5"
        XCTAssertFalse(presentation.mismatchNotice?.contains("usage credits") ?? true)
        presentation.confirmedRequest = "claude-sonnet-5-5"
        presentation.confirmedModel = "claude-opus-5-5"
        XCTAssertFalse(presentation.mismatchNotice?.contains("usage credits") ?? true)
    }

    func testModelOnlyEditSavesForExactBotAndReopenedEditor() async throws {
        let teammate = try modelPickerTeammate()
        let service = ModelPickerProfileService(teammate)
        let editor = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await editor.load()
        XCTAssertEqual(editor.claudeModel, "sonnet")
        XCTAssertFalse(editor.hasUnsavedChanges)
        editor.claudeModel = "claude-opus-5"
        editor.claudeEffort = "max"
        editor.claudeContextWindow = "standard"
        XCTAssertTrue(editor.canSave)
        let saved = await editor.save()
        XCTAssertEqual(saved?.claudeModel, "claude-opus-5")
        XCTAssertEqual(saved?.claudeEffort, "max")
        XCTAssertEqual(saved?.claudeContextWindow, "standard")
        XCTAssertEqual(saved?.profile.revision, teammate.profile.revision + 1)
        let reopened = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await reopened.load()
        XCTAssertEqual(reopened.claudeModel, "claude-opus-5")
        XCTAssertEqual(reopened.claudeEffort, "max")
        XCTAssertEqual(reopened.claudeContextWindow, "standard")
        XCTAssertEqual(ClaudeModelCatalog.contextLabel(reopened.claudeContextWindow, model: reopened.claudeModel), "Standard · 200K preference")
        XCTAssertFalse(reopened.hasUnsavedChanges)
    }

    func testCatalogOffersOpus55AndFable51ButNotFable5() {
        // Offer both current model IDs and omit the superseded Fable 5 ID.
        let ids = ClaudeModelCatalog.options.map(\.id)
        XCTAssertTrue(ids.contains("claude-opus-5-5"))
        XCTAssertTrue(ids.contains("claude-fable-5-1"))
        XCTAssertFalse(ids.contains("claude-fable-5"))
        XCTAssertFalse(ids.contains { $0.contains("mythos") })
        XCTAssertEqual(ClaudeModelCatalog.label(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ClaudeModelCatalog.label(for: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertTrue(ClaudeModelCatalog.availabilityNote.contains("September 27, 2026"))
        XCTAssertTrue(ClaudeModelCatalog.matches(requested: "claude-opus-5-5", observed: "claude-opus-5-5"))
        XCTAssertFalse(ClaudeModelCatalog.matches(requested: "claude-opus-5-5", observed: "claude-opus-5"))
    }

    func testFable51CarriesTheCreditsWarningAndNoOtherChoiceDoes() {
        // A warning directly under the picker, so the charge is never hidden.
        let warning = try? XCTUnwrap(ClaudeModelCatalog.creditsWarning(for: "claude-fable-5-1"))
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("credits") == true)
        XCTAssertTrue(warning?.contains("allowance") == true)
        for option in ClaudeModelCatalog.options where option.id != "claude-fable-5-1" {
            XCTAssertNil(ClaudeModelCatalog.creditsWarning(for: option.id), option.id)
        }
        XCTAssertNil(ClaudeModelCatalog.creditsWarning(for: "sonnet"))
    }

    func testNewFableModelsAndAliasesKeepCreditsWarning() throws {
        let catalog = try ClaudeModelCatalogSnapshot.parse(modelsJSON: Data("""
        [{"value":"default","resolvedModel":"claude-fable-6","displayName":"Fable"},
         {"value":"sonnet","resolvedModel":"claude-fable-6","displayName":"Fable"},
         {"value":"fable","resolvedModel":"claude-fable-6","displayName":"Fable"},
         {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus"}]
        """.utf8), checkedAt: Date())
        for selection in ["claude-fable-6", "default", "sonnet", "fable"] {
            let warning = try XCTUnwrap(ClaudeModelCatalog.creditsWarning(for: selection, in: catalog), selection)
            XCTAssertTrue(warning.contains("credits"))
        }
        XCTAssertNil(ClaudeModelCatalog.creditsWarning(for: "opus", in: catalog))
        XCTAssertNil(ClaudeModelCatalog.creditsWarning(for: "claude-sonnet-5-5", in: catalog))
    }

    func testUnknownChoiceSurvivesUnrelatedEditAndDiscardDoesNotSave() async throws {
        var teammate = try modelPickerTeammate()
        teammate.claudeModel = "retired-model[1m]"
        teammate.claudeEffort = "future-intensity"
        teammate.claudeContextWindow = "future-window"
        let service = ModelPickerProfileService(teammate)
        let editor = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await editor.load()
        XCTAssertEqual(editor.claudeModel, "retired-model[1m]")
        editor.title = "Updated label"
        let saved = await editor.save()
        XCTAssertEqual(saved?.claudeModel, teammate.claudeModel)
        XCTAssertEqual(saved?.claudeEffort, teammate.claudeEffort)
        XCTAssertEqual(saved?.claudeContextWindow, teammate.claudeContextWindow)
        let draft = await service.lastDraft
        XCTAssertNil(draft?.claudeModel)
        XCTAssertNil(draft?.claudeEffort)
        XCTAssertNil(draft?.claudeContextWindow)
        let discarded = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await discarded.load()
        discarded.claudeModel = "claude-opus-5"
        XCTAssertTrue(discarded.cancel())
        let stored = try await service.loadProfile(teammateID: teammate.id)
        XCTAssertEqual(stored.claudeModel, teammate.claudeModel)
    }

    func testChangingModelDoesNotSilentlyRewriteIncompatibleSavedSettings() async throws {
        var teammate = try modelPickerTeammate()
        teammate.claudeEffort = "xhigh"
        teammate.claudeContextWindow = "long"
        let editor = TeammateProfileEditorModel(service: ModelPickerProfileService(teammate), teammateID: teammate.id)
        await editor.load()
        editor.claudeModel = "claude-haiku-4-5-20251001"
        XCTAssertEqual(editor.claudeEffort, "xhigh")
        XCTAssertEqual(editor.claudeContextWindow, "long")
        XCTAssertTrue(ClaudeEffortPolicy.supportedValues(for: editor.claudeModel).isEmpty)
        XCTAssertFalse(ClaudeContextWindowPolicy.supportedValues(for: editor.claudeModel).contains("long"))
        XCTAssertEqual(ClaudeModelCatalog.effortLabel(editor.claudeEffort, model: editor.claudeModel), "Saved: xhigh (not in catalog)")
        XCTAssertEqual(ClaudeModelCatalog.contextLabel(editor.claudeContextWindow, model: editor.claudeModel), "Saved: long (not in catalog)")
        editor.claudeEffort = "default"
        editor.claudeContextWindow = "default"
        XCTAssertEqual(ClaudeModelCatalog.effortLabel(editor.claudeEffort, model: editor.claudeModel), "Model default preference")
        XCTAssertEqual(ClaudeModelCatalog.contextLabel(editor.claudeContextWindow, model: editor.claudeModel), "Model default preference")
        let saved = await editor.save()
        XCTAssertEqual(saved?.claudeEffort, "default")
        XCTAssertEqual(saved?.claudeContextWindow, "default")
    }

    func testInitFailureCannotConfirmAndAnotherBotDoesNotInheritModelStatus() async {
        let service = ModelPickerReplyService(confirm: false)
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let submission = modelPickerSubmission()
        XCTAssertTrue(coordinator.reserve(conversationID: submission.conversationID.rawValue,
                                          messageID: submission.userMessageID.rawValue))
        _ = await coordinator.send(submission) { _ in }
        let status = coordinator.modelPresentation(for: submission.conversationID.rawValue)
        XCTAssertEqual(status?.observedAtStart, "claude-sonnet-5")
        XCTAssertNil(status?.confirmedModel)
        XCTAssertNil(coordinator.modelPresentation(for: UUID()))
    }

    func testConfirmedResultRemainsDistinctFromSavedNextChoiceAndNewApp() async {
        let service = ModelPickerReplyService(confirm: true)
        let coordinator = ClaudeTextReplyCoordinator(service: service, changed: {})
        let submission = modelPickerSubmission()
        XCTAssertTrue(coordinator.reserve(conversationID: submission.conversationID.rawValue,
                                          messageID: submission.userMessageID.rawValue))
        _ = await coordinator.send(submission) { _ in }
        let status = coordinator.modelPresentation(for: submission.conversationID.rawValue)
        XCTAssertEqual(status?.confirmedRequest, "sonnet")
        XCTAssertEqual(status?.confirmedModel, "claude-sonnet-5")
        XCTAssertTrue(ClaudeModelCatalog.matches(requested: "sonnet", observed: "claude-sonnet-5"))
        // The bundled expectation remains Sonnet 5; a 2.1.287 answer on 5.5
        // must remain a visible difference until a live catalog resolves the alias.
        XCTAssertFalse(ClaudeModelCatalog.matches(requested: "sonnet", observed: "claude-sonnet-5-5"))
        XCTAssertFalse(ClaudeModelCatalog.matches(requested: "claude-sonnet-5", observed: "claude-sonnet-5-5"))
        XCTAssertFalse(ClaudeModelCatalog.matches(requested: "sonnet", observed: "claude-sonnet-6"))
        XCTAssertFalse(ClaudeModelCatalog.matches(requested: "claude-opus-5", observed: "claude-sonnet-5"))
        let reopened = ClaudeTextReplyCoordinator(service: service, changed: {})
        XCTAssertNil(reopened.modelPresentation(for: submission.conversationID.rawValue))
    }
}

private actor ModelPickerProfileService: TeammateProfileEditing {
    var teammate: Teammate
    private(set) var lastDraft: TeammateProfileEditDraft?
    init(_ teammate: Teammate) { self.teammate = teammate }
    func loadProfile(teammateID: TeammateID) async throws -> Teammate {
        XCTAssertEqual(teammateID, teammate.id)
        return teammate
    }
    func saveProfile(teammateID: TeammateID, expectedRevision: UInt64,
                     draft: TeammateProfileEditDraft) async throws -> Teammate {
        XCTAssertEqual(teammateID, teammate.id)
        XCTAssertEqual(expectedRevision, teammate.profile.revision)
        lastDraft = draft
        teammate.profile = try teammate.profile.revised(title: .some(draft.title))
        if let model = draft.claudeModel { teammate.claudeModel = model }
        if let effort = draft.claudeEffort { teammate.claudeEffort = effort }
        if let window = draft.claudeContextWindow { teammate.claudeContextWindow = window }
        return teammate
    }
}

private struct ModelPickerReplyService: ClaudeTextReplyServing {
    let confirm: Bool
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        await onProgress(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5"))
        if confirm { await onProgress(.modelConfirmed(requested: "sonnet", observed: "claude-sonnet-5")) }
        return .init(outcome: confirm ? .completed : .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}

private func modelPickerSubmission() -> ClaudeTextTurnSubmission {
    .init(conversationID: ConversationID(UUID()), teammateID: TeammateID(UUID()),
          userMessageID: MessageID(UUID()), text: "Synthetic model selection test")
}

private func modelPickerTeammate() throws -> Teammate {
    try Teammate(id: TeammateID(UUID()), profile: TeammateProfile(displayName: "Model QA", role: "Synthetic testing"),
                 appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 1,
                    silhouette: "round", paletteToken: "sky", eyeDialect: "round", nonColorIdentityCue: "single crest",
                    accessibleIdentityDescription: "Synthetic creature"),
                 createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
}
