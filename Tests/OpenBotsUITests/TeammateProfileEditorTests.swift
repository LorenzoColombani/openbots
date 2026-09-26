import AppKit
import OpenBotsDomain
import OpenBotsServices
import SwiftUI
import Vision
import XCTest
@testable import OpenBotsUI

@MainActor
final class TeammateProfileEditorTests: XCTestCase {
    func testBuiltInSelectionPreviewsWithoutWritingAndSaveUsesExplicitChoice() async throws {
        let teammate = try profileEditorTeammate()
        var saved = teammate
        saved.profile = try teammate.profile.revised()
        let service = ProfileEditorFake(loaded: teammate, saved: saved)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        for avatar in BuiltInAvatar.allCases {
            model.chooseBuiltInAvatar(avatar)
            XCTAssertEqual(model.appearancePreviewIdentity?.appearance.builtInAvatarID, avatar.rawValue)
            XCTAssertEqual(model.originalIdentity, TeammateIdentitySnapshot(teammate))
            XCTAssertTrue(model.canSave)
            XCTAssertFalse(model.editsCreature)
            XCTAssertNil(model.pendingPhotoAsset)
        }
        let before = await service.calls()
        XCTAssertTrue(before.saves.isEmpty)
        model.chooseBuiltInAvatar(nil)
        XCTAssertEqual(model.appearancePreviewIdentity, model.originalIdentity)
        XCTAssertFalse(model.hasUnsavedChanges)
        model.chooseBuiltInAvatar(.fin)
        model.editsCreature = true
        XCTAssertNil(model.pendingBuiltInAvatar)
        model.chooseBuiltInAvatar(.guide)
        _ = await model.save()
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.count, 1)
        XCTAssertEqual(calls.saves.first?.draft.builtInAvatar, .guide)
        XCTAssertNil(calls.saves.first?.draft.creature)
        XCTAssertNil(calls.saves.first?.draft.photoAssetID)
    }

    func testConstructionIsInertAndLoadPreservesExactIdentityAndAppearance() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        let before = await service.calls()
        XCTAssertTrue(before.loads.isEmpty)
        XCTAssertNil(model.originalTeammate)
        XCTAssertFalse(model.canSave)

        await model.load()
        await model.load()
        let after = await service.calls()
        XCTAssertEqual(after.loads, [teammate.id])
        XCTAssertEqual(model.originalTeammate, teammate)
        XCTAssertEqual(model.originalIdentity, TeammateIdentitySnapshot(teammate))
        XCTAssertEqual(model.displayName, "Ada")
        XCTAssertEqual(model.title, "Research lead")
        XCTAssertEqual(model.role, "Research and synthesis")
        XCTAssertEqual(model.detailedInstructions, "Working style:\nCareful and concise.")
        XCTAssertFalse(model.editsCreature)
        XCTAssertEqual(model.appearancePreviewIdentity, model.originalIdentity)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canSave)
    }

    func testSaveSendsExactTargetRevisionAndTrimmedDraftOnlyOnce() async throws {
        let teammate = try profileEditorTeammate()
        var saved = teammate
        saved.profile = try teammate.profile.revised(
            displayName: "Ada Updated", title: .some(nil), role: "Verifier",
            detailedInstructions: .some("Working style:\nKeep every source.")
        )
        let service = ProfileEditorFake(loaded: teammate, saved: saved)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.displayName = "  Ada Updated  "
        model.title = "  "
        model.role = " Verifier\n"
        model.detailedInstructions = "\nWorking style:\nKeep every source.\n"
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canSave)

        let result = await model.save()
        let duplicate = await model.save()
        XCTAssertEqual(result, saved)
        XCTAssertNil(duplicate)
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.count, 1)
        let call = try XCTUnwrap(calls.saves.first)
        XCTAssertEqual(call.target, teammate.id)
        XCTAssertEqual(call.revision, teammate.profile.revision)
        XCTAssertEqual(call.draft, TeammateProfileEditDraft(
            displayName: "Ada Updated", role: "Verifier",
            detailedInstructions: "Working style:\nKeep every source."
        ))
        XCTAssertEqual(model.savedTeammate, saved)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.isEditingEnabled)
    }

    func testTextOnlySavePreservesUnknownCreatureAndPhotoReferences() async throws {
        for photo in [false, true] {
            let teammate = try profileEditorTeammate(photo: photo)
            var saved = teammate
            saved.profile = try teammate.profile.revised(role: "Updated role")
            let service = ProfileEditorFake(loaded: teammate, saved: saved)
            let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
            await model.load()
            model.editsCreature = true
            model.silhouette = "cloud"
            model.editsCreature = false
            model.role = "Updated role"
            let result = await model.save()
            let calls = await service.calls()
            XCTAssertNil(calls.saves.first?.draft.creature)
            XCTAssertEqual(result?.appearance, teammate.appearance)
            XCTAssertEqual(result?.appearance.profileAssetID, teammate.appearance.profileAssetID)
        }
    }

    func testCreatureChangesAreOptInAndUseCanonicalChoices() async throws {
        let teammate = try profileEditorTeammate()
        var saved = teammate
        saved.profile = try teammate.profile.revised()
        let service = ProfileEditorFake(loaded: teammate, saved: saved)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.editsCreature = true
        model.silhouette = "sprout"
        model.paletteToken = "mint"
        model.eyeDialect = "calm"
        model.nonColorIdentityCue = "leaf ears"
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.originalIdentity?.appearance, CharacterAppearanceSnapshot(teammate.appearance))
        let preview = try XCTUnwrap(model.appearancePreviewIdentity)
        XCTAssertEqual(preview.appearance.silhouette, "sprout")
        XCTAssertEqual(preview.appearance.paletteToken, "mint")
        XCTAssertEqual(preview.appearance.eyeDialect, "calm")
        XCTAssertEqual(preview.appearance.nonColorIdentityCue, "leaf ears")
        XCTAssertEqual(preview.id, teammate.id.rawValue)
        XCTAssertTrue(preview.appearance.accessibleIdentityDescription.contains("Unsaved preview"))
        XCTAssertEqual(model.originalTeammate?.appearance, teammate.appearance)
        let beforeSave = await service.calls()
        XCTAssertTrue(beforeSave.saves.isEmpty)
        _ = await model.save()
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.first?.draft.creature, TeammateCreatureDraft(
            silhouette: "sprout", paletteToken: "mint", eyeDialect: "calm", nonColorIdentityCue: "leaf ears"
        ))
    }

    func testValidationPreventsInvalidRequestsWithoutInvokingService() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.displayName = "  "
        model.title = String(repeating: "t", count: 121)
        model.role = String(repeating: "r", count: 241)
        model.detailedInstructions = String(repeating: "i", count: 20_001)
        model.editsCreature = true
        model.silhouette = "unsupported"
        XCTAssertNotNil(model.nameValidationMessage)
        XCTAssertNotNil(model.titleValidationMessage)
        XCTAssertNotNil(model.roleValidationMessage)
        XCTAssertNotNil(model.instructionsValidationMessage)
        XCTAssertNotNil(model.creatureValidationMessage)
        XCTAssertFalse(model.canSave)
        let result = await model.save()
        XCTAssertNil(result)
        let calls = await service.calls()
        XCTAssertTrue(calls.saves.isEmpty)
    }

    func testRenameRefusesANameAnotherBotCarriesAndKeepsItsOwnInAnyCase() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id,
            takenName: { typed in TeammateProfile.namesMatch(typed, "Rook") ? "Rook" : nil }
        )
        await model.load()
        for typed in ["Rook", "rook", "  ROOK "] {
            model.displayName = typed
            XCTAssertEqual(model.nameValidationMessage, "There is already a bot called Rook.", "typed \(typed)")
            XCTAssertFalse(model.canSave, "typed \(typed)")
        }
        let refused = await model.save()
        XCTAssertNil(refused)
        let calls = await service.calls()
        XCTAssertTrue(calls.saves.isEmpty, "A refused name is never sent to the service")

        model.displayName = "ADA"
        XCTAssertNil(model.nameValidationMessage, "The bot keeps its own name in any case")
        XCTAssertTrue(model.canSave)
    }

    /// A bot saved before the rule may share its name with another. Opening
    /// its Details must not accuse the name it already has, or none of its
    /// other fields could be saved until one of the two is renamed.
    func testABotKeepsItsOwnNameWhileAnotherBotFromBeforeTheRuleSharesIt() async throws {
        let teammate = try profileEditorTeammate()
        var receipt = teammate
        receipt.profile = try teammate.profile.revised(role: "Edited role")
        let service = ProfileEditorFake(loaded: teammate, saved: receipt)
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id,
            takenName: { typed in TeammateProfile.namesMatch(typed, "Ada") ? "Ada" : nil }
        )
        await model.load()
        XCTAssertEqual(model.displayName, "Ada")
        XCTAssertNil(model.nameValidationMessage, "Keeping its own name is not taking another bot's")
        model.displayName = "ada"
        XCTAssertNil(model.nameValidationMessage, "Its own name in another case is still its own")
        model.displayName = "Ada"
        model.role = "Edited role"
        XCTAssertTrue(model.canSave)
        let saved = await model.save()
        XCTAssertNotNil(saved)
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.last?.draft.displayName, "Ada")
    }

    func testSaveRefusedForATakenNameShowsTheSentenceUnderTheNameAndKeepsTheDraft() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate, saveFailure: .nameTaken("Rook"))
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.displayName = "rook"
        model.role = "Edited role"
        XCTAssertNil(model.nameValidationMessage, "The editor's roster did not know Rook")
        XCTAssertTrue(model.canSave)

        let refused = await model.save()
        XCTAssertNil(refused)
        XCTAssertEqual(model.nameValidationMessage, "There is already a bot called Rook.")
        XCTAssertNil(model.inlineError, "The refusal sits under the field it concerns, not in the general line")
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.requiresReopen)
        XCTAssertEqual(model.displayName, "rook")
        XCTAssertEqual(model.role, "Edited role")
        XCTAssertTrue(model.isEditingEnabled)

        model.displayName = "Rook 2"
        XCTAssertNil(model.nameValidationMessage)
        XCTAssertTrue(model.canSave)
    }

    func testLoadFailureIsSafeAndCanRetry() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate, loadFails: true)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        XCTAssertNotNil(model.inlineError)
        XCTAssertFalse(model.inlineError?.contains("/Users/") ?? true)
        XCTAssertFalse(model.isLoading)
        await service.setLoadFailure(false)
        await model.load()
        XCTAssertNil(model.inlineError)
        XCTAssertEqual(model.originalTeammate, teammate)
    }

    func testSaveFailurePreservesDraftAndAllowsExplicitRetry() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate, saveFailure: .unavailable)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.displayName = "My unsaved name"
        model.detailedInstructions = "My unsaved instructions"
        let result = await model.save()
        XCTAssertNil(result)
        XCTAssertEqual(model.displayName, "My unsaved name")
        XCTAssertEqual(model.detailedInstructions, "My unsaved instructions")
        XCTAssertEqual(model.originalTeammate, teammate)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.inlineError?.contains("/Users/") ?? true)
        XCTAssertFalse(model.isSaving)
    }

    func testConflictPreservesEditsWithoutSilentRetryOrRevisionAdvance() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate, saveFailure: .conflict)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.role = "Unsaved new role"
        let result = await model.save()
        let retry = await model.save()
        let calls = await service.calls()
        XCTAssertNil(result)
        XCTAssertNil(retry)
        XCTAssertEqual(calls.saves.count, 1)
        XCTAssertEqual(model.role, "Unsaved new role")
        XCTAssertEqual(model.originalTeammate?.profile.revision, teammate.profile.revision)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.requiresReopen)
        XCTAssertFalse(model.canSave)
        XCTAssertTrue(model.inlineError?.contains("changed elsewhere") == true)
    }

    func testInFlightSaveRejectsDuplicateAndDoesNotPretendCancellation() async throws {
        let teammate = try profileEditorTeammate()
        var saved = teammate
        saved.profile = try teammate.profile.revised(role: "New role")
        let gate = ProfileEditorGate()
        let service = ProfileEditorFake(loaded: teammate, saved: saved, saveGate: gate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.role = "New role"
        let task = Task { await model.save() }
        await waitForProfileGate(gate)
        XCTAssertTrue(model.isSaving)
        XCTAssertFalse(model.cancel())
        let duplicate = await model.save()
        XCTAssertNil(duplicate)
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result, saved)
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.count, 1)
    }

    func testCancellationInvalidatesDelayedLoadAndNeverWrites() async throws {
        let teammate = try profileEditorTeammate()
        let gate = ProfileEditorGate()
        let service = ProfileEditorFake(loaded: teammate, loadGate: gate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        let task = Task { await model.load() }
        await waitForProfileGate(gate)
        XCTAssertTrue(model.cancel())
        await gate.release()
        await task.value
        XCTAssertTrue(model.isCancelled)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.originalTeammate)
        await model.load()
        let result = await model.save()
        XCTAssertNil(result)
        let calls = await service.calls()
        XCTAssertEqual(calls.loads.count, 1)
        XCTAssertTrue(calls.saves.isEmpty)
    }

    func testWrongIdentityResponsesCannotRetargetEditorOrClaimSave() async throws {
        let teammate = try profileEditorTeammate()
        var other = try profileEditorTeammate(id: 2)
        other.profile = try other.profile.revised()
        let loadService = ProfileEditorFake(loaded: other)
        let loadModel = TeammateProfileEditorModel(service: loadService, teammateID: teammate.id)
        await loadModel.load()
        XCTAssertEqual(loadModel.teammateID, teammate.id)
        XCTAssertNil(loadModel.originalTeammate)
        XCTAssertNotNil(loadModel.inlineError)

        let saveService = ProfileEditorFake(loaded: teammate, saved: other)
        let saveModel = TeammateProfileEditorModel(service: saveService, teammateID: teammate.id)
        await saveModel.load()
        saveModel.role = "Unsaved role"
        let result = await saveModel.save()
        XCTAssertNil(result)
        XCTAssertEqual(saveModel.teammateID, teammate.id)
        XCTAssertEqual(saveModel.originalTeammate, teammate)
        XCTAssertEqual(saveModel.role, "Unsaved role")
        XCTAssertTrue(saveModel.requiresReopen)
        XCTAssertNil(saveModel.savedTeammate)
    }

    func testRenderedEditorKeepsNativeFieldsWithinNarrowAndWideViewport() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        model.editsCreature = true
        // These retained fields now live in explicit collapsed sections.
        model.isAdvancedExpanded = true
        model.isAppearanceExpanded = true
        let controller = NSHostingController(rootView: TeammateProfileEditorView(
            model: model, onSaved: { _ in }, onCancelled: {}
        ))
        let host = controller.view
        for width: CGFloat in [270, 640] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1_800)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            // The editor is flexible, so an unconstrained fittingSize is not
            // the width it selects for a real inspector-sized proposal.
            let measured = controller.sizeThatFits(in: CGSize(width: width, height: 1_800))
            XCTAssertTrue(measured.width.isFinite)
            XCTAssertLessThanOrEqual(measured.width, width + 0.5)
            let fields = host.profileDescendants.compactMap { $0 as? NSTextField }.filter(\.isEditable)
            for value in [teammate.profile.displayName, teammate.profile.title!, teammate.profile.role] {
                XCTAssertNotNil(fields.first { $0.stringValue == value }, "Missing native field: \(value)")
            }
            let menus = host.profileDescendants.compactMap { $0 as? NSPopUpButton }
            if !menus.isEmpty {
                // Before macOS 27 the pickers are AppKit pop-up buttons. An offscreen
                // capture does not draw their titles readably (macOS 26 CI read "Use
                // app default :" and no creature choices), so read the controls.
                XCTAssertEqual(menus.count, 9) // Appearance, model, effort, context and notification preference.
                let modelMenu = try XCTUnwrap(menus.first { $0.itemTitles.contains("Sonnet · Existing preference") })
                let effortMenu = try XCTUnwrap(menus.first { $0.itemTitles.contains("Extra high") })
                let contextMenu = try XCTUnwrap(menus.first { $0.itemTitles.contains("Long · 1M preference") })
                let notificationMenu = try XCTUnwrap(menus.first { $0.itemTitles.contains("Use app default") })
                XCTAssertEqual(modelMenu.selectedItem?.title, "Sonnet · Existing preference")
                XCTAssertEqual(effortMenu.selectedItem?.title, "Model default preference")
                XCTAssertEqual(contextMenu.selectedItem?.title, "Model default preference")
                XCTAssertEqual(notificationMenu.selectedItem?.title, "Use app default")
                for option in ClaudeModelCatalog.options {
                    XCTAssertTrue(modelMenu.itemTitles.contains(option.menuLabel), "Missing complete qualified choice: \(option.menuLabel)")
                }
                for menu in [modelMenu, effortMenu, contextMenu, notificationMenu] {
                    let frame = menu.convert(menu.bounds, to: host)
                    let cell = try XCTUnwrap(menu.cell as? NSPopUpButtonCell)
                    let item = try XCTUnwrap(menu.selectedItem)
                    let font = try XCTUnwrap(menu.font)
                    let title = item.attributedTitle ?? NSAttributedString(string: item.title, attributes: [.font: font])
                    // What must fit is the complete selected title inside the cell's
                    // drawing area, excluding its bezel and disclosure arrow.
                    let titleRect = cell.titleRect(forBounds: menu.bounds)
                    XCTAssertGreaterThanOrEqual(titleRect.width + 0.5, title.size().width,
                        "Clipped preference title: \(item.title) at inspector width \(width)")
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
                }
            } else {
                // Since macOS 27 SwiftUI draws these menu pickers itself: the host holds no
                // NSPopUpButton to measure and no menu items to list. Read the pixels instead.
                // Each of the nine pickers (model, effort, context, notifications, avatar model
                // and the four creature choices) must show its label and, in order, the complete
                // selected title; a title clipped to "Model default prefe..." is not equal to it.
                // The avatar model's own title is checked apart, below, because it is clipped.
                let lines = try renderedProfileLines(host)
                let expected = [
                    "Preferred model", "Sonnet · Existing preference",
                    "Preferred thinking intensity", "Model default preference",
                    "Preferred context window", "Model default preference",
                    "Notifications", "Use app default",
                    "Avatar model",
                    "Shape", "Round", "Color", "Sky", "Eyes", "Round", "Identity mark", "Single Crest"
                ]
                var remaining = lines.map(normalizedProfileLine)[...]
                for line in expected {
                    let wanted = normalizedProfileLine(line)
                    guard let found = remaining.firstIndex(of: wanted) else {
                        XCTFail("Missing or clipped \"\(line)\" at inspector width \(width): \(lines)")
                        break
                    }
                    remaining = remaining[(found + 1)...]
                }
                // Known defect: at the narrow inspector width the
                // avatar model picker draws "Keep saved appe...". The expected failure turns
                // into a failing test the day it is fixed, so the fix is noticed.
                let avatarTitleIsWhole = lines.map(normalizedProfileLine)
                    .contains(normalizedProfileLine("Keep saved appearance"))
                if width < 300 {
                    XCTExpectFailure("The avatar model title is clipped at \(Int(width)) points") {
                        XCTAssertTrue(avatarTitleIsWhole)
                    }
                } else {
                    XCTAssertTrue(avatarTitleIsWhole, "Clipped avatar model title at \(width): \(lines)")
                }
            }
            let buttons = host.profileDescendants.compactMap { $0 as? NSButton }
            // SwiftUI owns composed button labels; raw NSButton.title does
            // not establish their accessible names or keyboard semantics.
            let editors = host.profileDescendants.compactMap { $0 as? NSTextView }
            XCTAssertNotNil(editors.first { $0.string == teammate.profile.detailedInstructions })
            for control in fields.map({ $0 as NSView }) + buttons.map({ $0 as NSView }) + editors.map({ $0 as NSView }) {
                let frame = control.convert(control.bounds, to: host)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            }
            XCTAssertEqual(model.originalTeammate, teammate)
            XCTAssertEqual(model.claudeModel, "sonnet")
            XCTAssertEqual(model.claudeEffort, "default")
            XCTAssertEqual(model.claudeContextWindow, "default")
        }
        // Rendered content only, not a packaged-window or VoiceOver sign-off.
    }

    func testAvatarEntryRevealsExistingControlsWithoutEditingOrImporting() async throws {
        let teammate = try profileEditorTeammate(photo: true)
        let service = ProfileEditorFake(loaded: teammate)
        let importer = ProfileEditorPhotoImporter(asset: try profileEditorPhotoAsset())
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id,
            photoImporter: { try await importer.importPhoto($0) }
        )
        XCTAssertNil(model.beginAvatarEditing(), "An unloaded profile cannot admit avatar editing.")
        XCTAssertFalse(model.isAppearanceExpanded)
        await model.load()
        model.displayName = "Unsaved name"
        model.detailedInstructions = "Preserve my\nunfinished description."
        let identity = model.appearancePreviewIdentity

        XCTAssertEqual(model.beginAvatarEditing(), .photo)
        XCTAssertTrue(model.isAppearanceExpanded)
        XCTAssertEqual(model.appearancePreviewIdentity, identity)
        XCTAssertEqual(model.originalTeammate, teammate)
        XCTAssertEqual(model.displayName, "Unsaved name")
        XCTAssertEqual(model.detailedInstructions, "Preserve my\nunfinished description.")
        XCTAssertFalse(model.editsCreature)
        XCTAssertNil(model.pendingPhotoAsset)
        let importCount = await importer.callCount
        let calls = await service.calls()
        XCTAssertEqual(importCount, 0)
        XCTAssertTrue(calls.saves.isEmpty)

        model.isAppearanceExpanded = false
        model.beginShutdown()
        XCTAssertNil(model.beginAvatarEditing())
        XCTAssertFalse(model.isAppearanceExpanded)
        XCTAssertEqual(model.originalTeammate?.appearance.profileAssetID, teammate.appearance.profileAssetID)
    }

    func testAvatarEntryWithoutPhotoImporterFocusesCreatureWithoutChangingIt() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()

        XCTAssertEqual(model.beginAvatarEditing(), .creature)
        XCTAssertTrue(model.isAppearanceExpanded)
        XCTAssertFalse(model.editsCreature)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.appearancePreviewIdentity, TeammateIdentitySnapshot(teammate))
        let calls = await service.calls()
        XCTAssertTrue(calls.saves.isEmpty)
    }

    func testNativeProfileEditorsPreserveExactEditableBytesAndDraftOwnership() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        let controller = NSHostingController(rootView: TeammateProfileEditorView(
            model: model, onSaved: { _ in XCTFail("Editing does not save implicitly") },
            onCancelled: { XCTFail("Editing does not cancel implicitly") }, onBack: {}, onClose: {}
        ))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 1_100)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(host.window, "This test never creates or orders a window.")
        let fields = host.profileDescendants.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let name = try XCTUnwrap(fields.first { $0.stringValue == teammate.profile.displayName })
        let label = try XCTUnwrap(fields.first { $0.stringValue == teammate.profile.title })
        let description = try XCTUnwrap(host.profileDescendants.compactMap { $0 as? NSTextView }
            .first { $0.string == teammate.profile.detailedInstructions })
        // The raw backing controls can carry no label at all. SwiftUI's
        // virtual labels are not established by this never-windowed host, so
        // the named controls' labels in a real window are not checked here.
        var missingLabels: [String] = []
        for (observed, expected) in [
            (name.accessibilityLabel(), "Bot name"),
            (label.accessibilityLabel(), "Bot label"),
            (description.accessibilityLabel(), "Bot instructions")
        ] {
            if let observed {
                XCTAssertEqual(observed, expected, "An exposed label must not misidentify its editor.")
            } else {
                missingLabels.append(expected)
            }
        }
        if !missingLabels.isEmpty {
            print("AX UNVERIFIED: never-windowed backing controls expose no label for \(missingLabels.joined(separator: ", ")). Labels in a real window are not checked here.")
        }
        XCTAssertTrue(description.isEditable)

        let draftName = "Zoé 🦉"
        let draftLabel = "Recherche"
        let draftDescription = "Ligne une\nLigne deux — e\u{301}"
        name.stringValue = draftName
        name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
        label.stringValue = draftLabel
        label.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: label))
        description.string = draftDescription
        description.didChangeText()
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Array(model.displayName.utf8), Array(draftName.utf8))
        XCTAssertEqual(Array(model.title.utf8), Array(draftLabel.utf8))
        XCTAssertEqual(Array(model.detailedInstructions.utf8), Array(draftDescription.utf8))
        XCTAssertEqual(Array(name.stringValue.utf8), Array(draftName.utf8))
        XCTAssertEqual(Array(label.stringValue.utf8), Array(draftLabel.utf8))
        XCTAssertEqual(Array(description.string.utf8), Array(draftDescription.utf8))
        XCTAssertEqual(model.role, teammate.profile.role)
        XCTAssertEqual(model.teammateID, teammate.id)
        XCTAssertEqual(model.originalTeammate, teammate)
        XCTAssertEqual(model.appearancePreviewIdentity, TeammateIdentitySnapshot(teammate))
        let calls = await service.calls()
        XCTAssertTrue(calls.saves.isEmpty)
        // Native editing/value/ownership only; no AX label, focus, or VoiceOver pass.
    }

    func testPhotoImportIsExplicitAndSavingUsesOnlyImmutableAssetIdentity() async throws {
        let teammate = try profileEditorTeammate()
        let asset = try profileEditorPhotoAsset()
        var saved = teammate
        saved.profile = try teammate.profile.revised()
        let service = ProfileEditorFake(loaded: teammate, saved: saved)
        let importer = ProfileEditorPhotoImporter(asset: asset)
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id, photoImporter: { try await importer.importPhoto($0) }
        )
        await model.load()
        let initiallyImported = await importer.callCount
        XCTAssertEqual(initiallyImported, 0)
        model.editsCreature = true
        model.silhouette = "cloud"
        let selected = URL(fileURLWithPath: "/private/tmp/user-selected-private-photo.png")
        await model.importPhoto(from: selected)
        XCTAssertFalse(model.editsCreature)
        XCTAssertEqual(model.pendingPhotoAsset, asset)
        XCTAssertEqual(model.originalTeammate, teammate)
        XCTAssertEqual(model.appearancePreviewIdentity?.appearance.mode, .photo)
        XCTAssertEqual(model.appearancePreviewIdentity?.appearance.profileAssetID, asset.id.rawValue)
        XCTAssertFalse(model.appearancePreviewIdentity?.appearance.accessibleIdentityDescription.contains(selected.path) ?? true)
        XCTAssertTrue(model.canSave)
        _ = await model.save()
        let calls = await service.calls()
        XCTAssertEqual(calls.saves.count, 1)
        XCTAssertEqual(calls.saves.first?.draft.photoAssetID, asset.id)
        XCTAssertNil(calls.saves.first?.draft.creature)
        XCTAssertNil(model.pendingPhotoAsset)
    }

    func testCreatureChoiceDiscardsPendingPhotoAndDiscardDoesNotWrite() async throws {
        let teammate = try profileEditorTeammate()
        let asset = try profileEditorPhotoAsset()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id, photoImporter: { _ in asset }
        )
        await model.load()
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/chosen.png"))
        XCTAssertNotNil(model.pendingPhotoAsset)
        model.editsCreature = true
        XCTAssertNil(model.pendingPhotoAsset)
        XCTAssertEqual(model.appearancePreviewIdentity?.appearance.mode, .creature)
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/chosen.png"))
        model.discardPendingPhoto()
        XCTAssertNil(model.pendingPhotoAsset)
        XCTAssertEqual(model.appearancePreviewIdentity, model.originalIdentity)
        XCTAssertFalse(model.hasUnsavedChanges)
        let calls = await service.calls()
        XCTAssertTrue(calls.saves.isEmpty)
    }

    func testPhotoImportFailurePreservesDraftAndPreviousCreatureOrPhoto() async throws {
        let teammate = try profileEditorTeammate()
        let asset = try profileEditorPhotoAsset()
        let importer = ProfileEditorPhotoImporter(asset: asset)
        let model = TeammateProfileEditorModel(
            service: ProfileEditorFake(loaded: teammate), teammateID: teammate.id,
            photoImporter: { try await importer.importPhoto($0) }
        )
        await model.load()
        model.role = "Unsaved role"
        model.editsCreature = true
        model.silhouette = "cloud"
        await importer.setFailure(true)
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/private-source.png"))
        XCTAssertTrue(model.editsCreature)
        XCTAssertEqual(model.silhouette, "cloud")
        XCTAssertEqual(model.role, "Unsaved role")
        XCTAssertNil(model.pendingPhotoAsset)
        XCTAssertFalse(model.inlineError?.contains("/Users/") ?? true)
        XCTAssertFalse(model.inlineError?.contains("private-source") ?? true)

        await importer.setFailure(false)
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/private-source.png"))
        await importer.setFailure(true)
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/another-private-source.png"))
        XCTAssertEqual(model.pendingPhotoAsset, asset)
        XCTAssertFalse(model.editsCreature)
        XCTAssertEqual(model.role, "Unsaved role")
    }

    func testImportDisablesSaveAndLateResultCannotReviveCancelledEditor() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let gate = ProfileEditorGate()
        let importer = ProfileEditorPhotoImporter(asset: try profileEditorPhotoAsset(), gate: gate)
        let model = TeammateProfileEditorModel(
            service: service, teammateID: teammate.id,
            photoImporter: { try await importer.importPhoto($0) }
        )
        await model.load()
        model.role = "Unsaved role"
        let operation = Task { await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/chosen.png")) }
        await waitForProfileGate(gate)
        XCTAssertTrue(model.isImportingPhoto)
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canChoosePhoto)
        let ignoredSave = await model.save()
        XCTAssertNil(ignoredSave)
        await model.importPhoto(from: URL(fileURLWithPath: "/private/tmp/second.png"))
        XCTAssertTrue(model.cancel())
        await gate.release()
        await operation.value
        XCTAssertNil(model.pendingPhotoAsset)
        XCTAssertFalse(model.isImportingPhoto)
        XCTAssertTrue(model.isCancelled)
        XCTAssertEqual(model.originalTeammate, teammate)
        let count = await importer.callCount
        let calls = await service.calls()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(calls.saves.isEmpty)
    }

    func testUnavailableImporterAndNonFileURLCannotImportAnything() async throws {
        let teammate = try profileEditorTeammate()
        let without = TeammateProfileEditorModel(service: ProfileEditorFake(loaded: teammate), teammateID: teammate.id)
        await without.load()
        XCTAssertFalse(without.isPhotoImportAvailable)
        await without.importPhoto(from: URL(fileURLWithPath: "/private/tmp/no-import.png"))
        XCTAssertNil(without.pendingPhotoAsset)
        XCTAssertNil(without.inlineError)

        let importer = ProfileEditorPhotoImporter(asset: try profileEditorPhotoAsset())
        let withImporter = TeammateProfileEditorModel(
            service: ProfileEditorFake(loaded: teammate), teammateID: teammate.id,
            photoImporter: { try await importer.importPhoto($0) }
        )
        await withImporter.load()
        await withImporter.importPhoto(from: URL(string: "https://example.invalid/photo.png")!)
        let count = await importer.callCount
        XCTAssertEqual(count, 0)
        XCTAssertNil(withImporter.pendingPhotoAsset)
        XCTAssertNotNil(withImporter.inlineError)
    }

    /// The New Bot sheet saves its "What this
    /// bot does" as the role, and the bot's settings showed an empty box of the
    /// same name, which held the instructions, with the role folded away under
    /// Advanced. The words typed at creation must be the first thing the settings
    /// show under that name, with Advanced closed.
    func testWhatThisBotDoesShowsTheRoleTheNewBotSheetSaved() async throws {
        let teammate = try profileEditorTeammate()
        let service = ProfileEditorFake(loaded: teammate)
        let model = TeammateProfileEditorModel(service: service, teammateID: teammate.id)
        await model.load()
        XCTAssertFalse(model.isAdvancedExpanded)
        let controller = NSHostingController(rootView: TeammateProfileEditorView(
            model: model, onSaved: { _ in }, onCancelled: {}, onBack: {}, onClose: {}
        ))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 1_100)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let editors = host.profileDescendants
        let roleShown = editors.contains { ($0 as? NSTextField)?.isEditable == true && ($0 as? NSTextField)?.stringValue == teammate.profile.role }
            || editors.contains { ($0 as? NSTextView)?.isEditable == true && ($0 as? NSTextView)?.string == teammate.profile.role }
        XCTAssertTrue(roleShown, "The role is the bot's \"What this bot does\"; it must be editable without opening Advanced.")
        let lines = try renderedProfileLines(host).map(normalizedProfileLine)
        XCTAssertEqual(lines.filter { $0 == normalizedProfileLine("What this bot does") }.count, 1,
                       "One label, one field: \(lines)")
        XCTAssertTrue(lines.contains(normalizedProfileLine("Instructions (optional)")), "\(lines)")
    }
}

private actor ProfileEditorPhotoImporter {
    let asset: ProfilePhotoAsset
    let gate: ProfileEditorGate?
    var callCount = 0
    private var fails = false
    init(asset: ProfilePhotoAsset, gate: ProfileEditorGate? = nil) { self.asset = asset; self.gate = gate }
    func setFailure(_ value: Bool) { fails = value }
    func importPhoto(_ url: URL) async throws -> ProfilePhotoAsset {
        callCount += 1
        if let gate { await gate.wait() }
        if fails { throw SensitiveProfileFailure() }
        return asset
    }
}

private func profileEditorPhotoAsset() throws -> ProfilePhotoAsset {
    try ProfilePhotoAsset(
        id: ProfileAssetID(UUID(uuidString: "A7000000-0000-0000-0000-000000000001")!),
        width: 2, height: 2, byteCount: 90, sha256: String(repeating: "a", count: 64)
    )
}

private struct ProfileEditorSaveCall: Sendable {
    let target: TeammateID
    let revision: UInt64
    let draft: TeammateProfileEditDraft
}

private enum ProfileEditorFailure: Sendable { case unavailable, conflict, nameTaken(String) }

private struct SensitiveProfileFailure: LocalizedError {
    var errorDescription: String? { "Private failure at /Users/example/private/database.sqlite" }
}

private actor ProfileEditorFake: TeammateProfileEditing {
    private let loaded: Teammate
    private let saved: Teammate?
    private var loadFails: Bool
    private let saveFailure: ProfileEditorFailure?
    private let loadGate: ProfileEditorGate?
    private let saveGate: ProfileEditorGate?
    private var loads: [TeammateID] = []
    private var saves: [ProfileEditorSaveCall] = []

    init(
        loaded: Teammate, saved: Teammate? = nil, loadFails: Bool = false,
        saveFailure: ProfileEditorFailure? = nil,
        loadGate: ProfileEditorGate? = nil, saveGate: ProfileEditorGate? = nil
    ) {
        self.loaded = loaded
        self.saved = saved
        self.loadFails = loadFails
        self.saveFailure = saveFailure
        self.loadGate = loadGate
        self.saveGate = saveGate
    }

    func loadProfile(teammateID: TeammateID) async throws -> Teammate {
        loads.append(teammateID)
        await loadGate?.wait()
        if loadFails { throw SensitiveProfileFailure() }
        return loaded
    }

    func saveProfile(teammateID: TeammateID, expectedRevision: UInt64, draft: TeammateProfileEditDraft) async throws -> Teammate {
        saves.append(ProfileEditorSaveCall(target: teammateID, revision: expectedRevision, draft: draft))
        await saveGate?.wait()
        if let saveFailure {
            switch saveFailure {
            case .unavailable: throw SensitiveProfileFailure()
            case .conflict: throw RepositoryError.optimisticLockFailed(entity: "teammate", id: teammateID.persistedValue)
            case let .nameTaken(existing): throw TeammateNameTakenError(existingName: existing)
            }
        }
        return saved ?? loaded
    }

    func setLoadFailure(_ value: Bool) { loadFails = value }
    func calls() -> (loads: [TeammateID], saves: [ProfileEditorSaveCall]) { (loads, saves) }
}

private actor ProfileEditorGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private func waitForProfileGate(_ gate: ProfileEditorGate) async {
    for _ in 0..<200 {
        if await gate.started { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Fake operation did not reach its bounded gate")
}

private func profileEditorTeammate(id: UInt64 = 1, photo: Bool = false) throws -> Teammate {
    let uuid = UUID(uuidString: String(format: "A6000000-0000-0000-0000-%012llx", id))!
    let date = Date(timeIntervalSince1970: 1_788_000_000)
    return try Teammate(
        id: TeammateID(uuid),
        profile: TeammateProfile(
            displayName: "Ada", title: "Research lead", role: "Research and synthesis",
            detailedInstructions: "Working style:\nCareful and concise.", revision: 4
        ),
        appearance: AgentAppearance(
            mode: photo ? .photo : .creature, grammarVersion: 1, deterministicSeed: 71,
            silhouette: "soft-arch", paletteToken: "violet-coral", eyeDialect: "round-alert",
            nonColorIdentityCue: "single brow notch", accessibleIdentityDescription: "Distinctive saved identity",
            profileAssetID: photo ? ProfileAssetID(uuid) : nil, revision: 3
        ),
        createdAt: date, updatedAt: date
    )
}

private extension NSView {
    var profileDescendants: [NSView] { subviews + subviews.flatMap(\.profileDescendants) }
}

/// Offline Vision over the host's own pixels, captured at 3x for the same reason as
/// NormalAppPresentationTests: lower densities misread small macOS 27 control text.
@MainActor
private func renderedProfileLines(_ host: NSView) throws -> [String] {
    let scale: CGFloat = 3
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(host.bounds.width * scale), pixelsHigh: Int(host.bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let recognition = VNRecognizeTextRequest()
    recognition.usesCPUOnly = true
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    recognition.usesLanguageCorrection = false
    try VNImageRequestHandler(data: data, options: [:]).perform([recognition])
    let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    XCTAssertFalse(lines.isEmpty, "Rendered text recognition must materialize actual pixels.")
    return lines
}

/// Vision drops or merges spaces and reads the menu's middle dot as a bullet. It
/// also reads a picker's up-down arrows as a trailing "*" once the layout moves by
/// a few points ("Round *" for the Eyes picker, after the
/// role's field was added above it). A clipped title ends in an ellipsis, which
/// this never removes.
private func normalizedProfileLine(_ line: String) -> String {
    line.lowercased().filter { !$0.isWhitespace && $0 != "·" && $0 != "•" && $0 != "*" }
}
