import Foundation
import OpenBotsDomain
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
    #expect(model.previewIdentity.name == "New Bot")
    #expect(model.previewIdentity.role.isEmpty)
    #expect(model.name.isEmpty)
    #expect(model.role.isEmpty)
}

@Test("Validation trims both fields, asks for each in plain words and enforces the documented maxima")
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
    #expect(model.nameValidationMessage == "Enter a name for this bot.")
    #expect(model.roleValidationMessage == "Say what this bot does.")

    model.name = String(repeating: "N", count: TeammateCreationModel.maximumNameLength + 1)
    model.role = String(repeating: "R", count: TeammateCreationModel.maximumRoleLength + 1)

    #expect(model.nameValidationMessage == "Keep the name to 80 characters or fewer.")
    #expect(model.roleValidationMessage == "Keep it to 240 characters or fewer.")
    #expect(model.canSubmit == false)

    model.name = "  Ada  "
    model.role = "  Reads the mail and drafts replies. \n"
    #expect(model.nameValidationMessage == nil)
    #expect(model.roleValidationMessage == nil)
    #expect(model.previewIdentity.name == "Ada")
    #expect(model.previewIdentity.role == "Reads the mail and drafts replies.")
    #expect(model.canSubmit)
}

@Test("A name an active bot already carries is refused inline, whatever its case or spacing")
@MainActor
func creationRefusesTakenName() async {
    let recorder = CreationRecorder()
    let model = TeammateCreationModel(
        identityID: UUID(),
        appearance: .fixture(seed: 86),
        takenName: { typed in typed.caseInsensitiveCompare("Ada") == .orderedSame ? "Ada" : nil },
        submit: { identity in await recorder.append(identity) }
    )
    model.role = "Reads the mail and drafts replies."

    model.name = "  ada "
    #expect(model.nameValidationMessage == "There is already a bot called Ada.")
    #expect(model.canSubmit == false)
    #expect(await model.submit() == false)
    #expect(await recorder.values().isEmpty)
    #expect(model.submissionError == nil)

    model.name = "Ada B"
    #expect(model.nameValidationMessage == nil)
    #expect(model.canSubmit)
    #expect(await model.submit())
    #expect(await recorder.values().map(\.name) == ["Ada B"])
}

@Test("A name taken between opening the sheet and Create is refused with the same sentence")
@MainActor
func creationRefusesNameTakenAtSubmit() async {
    let model = TeammateCreationModel(
        identityID: UUID(),
        appearance: .fixture(seed: 87),
        submit: { _ in throw TeammateNameTakenError(existingName: "Ada") }
    )
    model.name = "ada"
    model.role = "Reads the mail and drafts replies."
    #expect(model.canSubmit)

    #expect(await model.submit() == false)
    #expect(model.nameValidationMessage == "There is already a bot called Ada.")
    #expect(model.submissionError == nil)
    #expect(model.canSubmit == false)

    model.name = "Ada B"
    #expect(model.nameValidationMessage == nil)
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
    model.role = "\n Builds and checks the weekly report. "

    #expect(await model.submit())
    #expect(await model.submit() == false)

    let values = await recorder.values()
    #expect(values.count == 1)
    #expect(
        values.first == TeammateIdentitySnapshot(
            id: identityID,
            name: "Lin",
            role: "Builds and checks the weekly report.",
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
    model.role = "Researcher"

    #expect(await model.submit() == false)
    #expect(model.isSubmitting == false)
    #expect(model.canSubmit)
    #expect(model.submissionError == "Couldn’t create the bot. Nothing was saved.")
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
    model.role = "Researcher"
    _ = await model.submit()

    model.reset()

    #expect(model.name.isEmpty)
    #expect(model.role.isEmpty)
    #expect(model.submissionError == nil)
    #expect(model.hasAttemptedSubmit == false)
    #expect(model.previewIdentity.id == identityID)
    #expect(model.previewIdentity.appearance == appearance)
}
