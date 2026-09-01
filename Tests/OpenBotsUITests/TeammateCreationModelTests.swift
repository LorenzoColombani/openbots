import Foundation
import Testing
@testable import OpenBotsUI

private actor CreationRecorder {
    private var identities: [TeammateIdentitySnapshot] = []

    func append(_ identity: TeammateIdentitySnapshot) {
        identities.append(identity)
    }

    func values() -> [TeammateIdentitySnapshot] {
        identities
    }
}

private struct SensitiveCreationFailure: LocalizedError {
    var errorDescription: String? {
        "Could not write /Users/example/private-control.sqlite"
    }
}

@Test("Construction is inert and preserves its fixed identity")
@MainActor
func creationConstructionIsInert() async {
    let recorder = CreationRecorder()
    let identityID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    let appearance = CharacterAppearanceSnapshot.fixture(seed: 81)

    let model = TeammateCreationModel(
        identityID: identityID,
        appearance: appearance,
        submit: { identity in
            await recorder.append(identity)
        }
    )

    #expect(await recorder.values().isEmpty)
    #expect(model.id == identityID)
    #expect(model.previewIdentity.id == identityID)
    #expect(model.previewIdentity.appearance == appearance)
    #expect(model.name.isEmpty)
    #expect(model.shortRole.isEmpty)
}

@Test("Validation trims required fields and enforces documented maxima")
@MainActor
func creationValidation() async {
    let model = TeammateCreationModel(
        identityID: UUID(),
        appearance: .fixture(seed: 82),
        submit: { _ in }
    )

    #expect(model.canSubmit == false)
    #expect(model.nameValidationMessage == nil)
    #expect(model.roleValidationMessage == nil)

    #expect(await model.submit() == false)
    #expect(model.nameValidationMessage == "Enter a name for this teammate.")
    #expect(model.roleValidationMessage == "Add a short role so this teammate is easy to recognize.")

    model.name = String(repeating: "N", count: TeammateCreationModel.maximumNameLength + 1)
    model.shortRole = String(repeating: "R", count: TeammateCreationModel.maximumRoleLength + 1)

    #expect(model.nameValidationMessage?.contains("80") == true)
    #expect(model.roleValidationMessage?.contains("240") == true)
    #expect(model.canSubmit == false)

    model.name = "  Ada  "
    model.shortRole = "  Research and synthesis \n"
    #expect(model.canSubmit)
}

@Test("One valid submission carries the exact UUID, appearance, and trimmed profile")
@MainActor
func creationSubmitsExactIdentityOnce() async {
    let recorder = CreationRecorder()
    let identityID = UUID(uuidString: "81000000-0000-0000-0000-000000000002")!
    let appearance = CharacterAppearanceSnapshot.fixture(seed: 83)
    let model = TeammateCreationModel(
        identityID: identityID,
        appearance: appearance,
        submit: { identity in
            await recorder.append(identity)
        }
    )
    model.name = "  Lin  "
    model.shortRole = "\n Builder and verifier "

    #expect(await model.submit())
    #expect(await model.submit() == false)

    let values = await recorder.values()
    #expect(values.count == 1)
    #expect(
        values.first == TeammateIdentitySnapshot(
            id: identityID,
            name: "Lin",
            role: "Builder and verifier",
            appearance: appearance
        )
    )
}

@Test("Submission failure is inline, retryable, and does not expose thrown diagnostics")
@MainActor
func creationFailureIsSafe() async {
    let model = TeammateCreationModel(
        identityID: UUID(),
        appearance: .fixture(seed: 84),
        submit: { _ in throw SensitiveCreationFailure() }
    )
    model.name = "Ada"
    model.shortRole = "Researcher"

    #expect(await model.submit() == false)
    #expect(model.isSubmitting == false)
    #expect(model.canSubmit)
    #expect(model.submissionError == "OpenBots couldn’t create this teammate. Nothing was saved.")
    #expect(model.submissionError?.contains("/Users/") == false)
}

@Test("Reset clears mutable form state but never changes identity")
@MainActor
func creationResetPreservesIdentity() async {
    let identityID = UUID(uuidString: "81000000-0000-0000-0000-000000000003")!
    let appearance = CharacterAppearanceSnapshot.fixture(seed: 85)
    let model = TeammateCreationModel(
        identityID: identityID,
        appearance: appearance,
        submit: { _ in throw SensitiveCreationFailure() }
    )
    model.name = "Ada"
    model.shortRole = "Researcher"
    _ = await model.submit()

    model.reset()

    #expect(model.name.isEmpty)
    #expect(model.shortRole.isEmpty)
    #expect(model.submissionError == nil)
    #expect(model.hasAttemptedSubmit == false)
    #expect(model.previewIdentity.id == identityID)
    #expect(model.previewIdentity.appearance == appearance)
}
