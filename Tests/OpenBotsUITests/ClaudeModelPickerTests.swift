import Foundation
import OpenBotsDomain
import OpenBotsServices
import XCTest
@testable import OpenBotsUI

@MainActor
final class ClaudeModelPickerTests: XCTestCase {
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
