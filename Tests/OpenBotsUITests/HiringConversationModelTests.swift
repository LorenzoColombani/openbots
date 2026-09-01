import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsUI

private enum HiringFakeOperation: Hashable, Sendable {
    case load
    case submit
    case revise
    case cancel
    case confirm
}

private struct SensitiveHiringFailure: LocalizedError, Sendable {
    var errorDescription: String? {
        "Could not write /Users/example/private/hiring-draft.sqlite"
    }
}

private actor HiringConversationFakeService: HiringConversationServing {
    struct Calls: Sendable {
        var loadCount = 0
        var submittedTexts: [String] = []
        var revisions: [(HiringCandidateField, String)] = []
        var cancelCount = 0
        var confirmedAppearances: [AgentAppearance] = []
    }

    private let loadSnapshot: HiringConversationSnapshot
    private let submitSnapshot: HiringConversationSnapshot
    private let revisionSnapshot: HiringConversationSnapshot
    private let confirmation: DurableTeammateChatCreationSnapshot
    private let failures: Set<HiringFakeOperation>
    private var calls = Calls()

    init(
        loadSnapshot: HiringConversationSnapshot,
        submitSnapshot: HiringConversationSnapshot? = nil,
        revisionSnapshot: HiringConversationSnapshot? = nil,
        confirmation: DurableTeammateChatCreationSnapshot,
        failures: Set<HiringFakeOperation> = []
    ) {
        self.loadSnapshot = loadSnapshot
        self.submitSnapshot = submitSnapshot ?? loadSnapshot
        self.revisionSnapshot = revisionSnapshot ?? loadSnapshot
        self.confirmation = confirmation
        self.failures = failures
    }

    func loadOrStart() async throws -> HiringConversationSnapshot {
        calls.loadCount += 1
        if failures.contains(.load) { throw SensitiveHiringFailure() }
        return loadSnapshot
    }

    func submit(text: String) async throws -> HiringConversationSnapshot {
        calls.submittedTexts.append(text)
        if failures.contains(.submit) { throw SensitiveHiringFailure() }
        return submitSnapshot
    }

    func revise(
        field: HiringCandidateField,
        value: String
    ) async throws -> HiringConversationSnapshot {
        calls.revisions.append((field, value))
        if failures.contains(.revise) { throw SensitiveHiringFailure() }
        return revisionSnapshot
    }

    func cancel() async throws {
        calls.cancelCount += 1
        if failures.contains(.cancel) { throw SensitiveHiringFailure() }
    }

    func confirm(
        appearance: AgentAppearance
    ) async throws -> DurableTeammateChatCreationSnapshot {
        calls.confirmedAppearances.append(appearance)
        if failures.contains(.confirm) { throw SensitiveHiringFailure() }
        return confirmation
    }

    func recordedCalls() -> Calls { calls }
}

private let hiringDraftUUID = UUID(
    uuidString: "A1000000-0000-0000-0000-000000000001"
)!

private func hiringSnapshot(
    draftUUID: UUID = hiringDraftUUID,
    phase: HiringDraftPhase = .collecting,
    focusedField: HiringCandidateField? = .displayName,
    displayName: String? = nil,
    role: String? = nil,
    responsibilities: String? = nil,
    workingStyle: String? = nil,
    skills: String? = nil,
    permissionIntent: String? = nil,
    projectPlacement: String? = nil,
    teamPlacement: String? = nil,
    turns: [(HiringTurnAuthor, String)] = [
        (.guide, "Local guided hiring preview — no Claude runtime or tool ran. What should we call this teammate?")
    ]
) throws -> HiringConversationSnapshot {
    let createdAt = Date(timeIntervalSince1970: 10_000)
    let updatedAt = createdAt.addingTimeInterval(100)
    let draftID = HiringDraftID(draftUUID)
    let draft = try HiringDraft(
        id: draftID,
        phase: phase,
        displayName: displayName,
        role: role,
        responsibilities: responsibilities,
        workingStyle: workingStyle,
        skills: skills,
        permissionIntent: permissionIntent,
        projectPlacement: projectPlacement,
        teamPlacement: teamPlacement,
        revision: UInt64(max(1, turns.count)),
        createdAt: createdAt,
        updatedAt: updatedAt
    )
    let domainTurns = try turns.enumerated().map { offset, source in
        try HiringTurn(
            id: HiringTurnID(UUID()),
            draftID: draftID,
            sequence: Int64(offset + 1),
            author: source.0,
            text: source.1,
            createdAt: createdAt.addingTimeInterval(Double(offset + 1))
        )
    }
    return HiringConversationSnapshot(
        persisted: try HiringDraftSnapshot(draft: draft, turns: domainTurns),
        focusedField: focusedField
    )
}

private func readyHiringSnapshot(
    draftUUID: UUID = hiringDraftUUID,
    responsibilities: String = "Research reliable sources and synthesize findings."
) throws -> HiringConversationSnapshot {
    try hiringSnapshot(
        draftUUID: draftUUID,
        phase: .readyForReview,
        focusedField: nil,
        displayName: "Ada",
        role: "Research lead",
        responsibilities: responsibilities,
        workingStyle: "Curious, direct, and source-conscious",
        skills: "Web research, synthesis, and document design",
        permissionIntent: "Read the selected research folder",
        projectPlacement: "Launch research",
        teamPlacement: "Editorial team",
        turns: [
            (.guide, HiringConversationModel.previewDisclosure),
            (.user, "Ada"),
            (.guide, "Review the exact local draft, then confirm the hire.")
        ]
    )
}

private func hiringConfirmation() throws -> DurableTeammateChatCreationSnapshot {
    let timestamp = Date(timeIntervalSince1970: 10_200)
    let teammateID = TeammateID(hiringDraftUUID)
    let appearance = try AgentAppearance(
        mode: .creature,
        grammarVersion: 1,
        deterministicSeed: 101,
        silhouette: "soft-arch",
        paletteToken: "violet-coral",
        eyeDialect: "round-alert",
        nonColorIdentityCue: "single brow notch",
        accessibleIdentityDescription: "Violet creature with a single brow notch",
        revision: 1
    )
    let teammate = try Teammate(
        id: teammateID,
        profile: TeammateProfile(displayName: "Ada", role: "Research lead"),
        appearance: appearance,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let conversation = try Conversation(
        id: ConversationID(UUID()),
        kind: .direct(teammateID: teammateID),
        title: "Ada",
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let greeting = try Message(
        id: MessageID(UUID()),
        conversationID: conversation.id,
        sequence: 1,
        author: .teammate(teammateID),
        deliveryState: .completed,
        parts: [
            try MessagePart(
                id: MessagePartID(UUID()),
                ordinal: 0,
                content: .text("Local guided hiring preview — no Claude runtime or tool ran.")
            )
        ],
        createdAt: timestamp,
        updatedAt: timestamp
    )
    return DurableTeammateChatCreationSnapshot(
        teammate: teammate,
        conversation: conversation,
        fixtureGreeting: greeting,
        selection: DurableChatSelectionSnapshot(
            teammate: teammate,
            conversation: conversation
        )
    )
}

@MainActor
private func waitForSubmission(_ model: HiringConversationModel) async {
    for _ in 0..<200 where model.isSubmitting {
        await Task.yield()
    }
}

@Test("Hiring model construction is inert and permanently identifies the local preview")
@MainActor
func hiringConstructionIsInert() async throws {
    let snapshot = try hiringSnapshot()
    let service = HiringConversationFakeService(
        loadSnapshot: snapshot,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)

    let calls = await service.recordedCalls()
    #expect(calls.loadCount == 0)
    #expect(calls.submittedTexts.isEmpty)
    #expect(model.displayRows.isEmpty)
    #expect(model.canSend == false)
    #expect(HiringConversationModel.previewDisclosure.contains("no Claude runtime or tool ran"))
    #expect(HiringConversationModel.previewDisclosure.lowercased().contains("api") == false)
}

@Test("Normal hiring identifies local setup while retaining the saved transcript")
@MainActor
func hiringLocalSetupDisclosure() async throws {
    let snapshot = try hiringSnapshot()
    let service = HiringConversationFakeService(loadSnapshot: snapshot, confirmation: try hiringConfirmation())
    let model = HiringConversationModel(service: service)
    #expect(model.mode == .localOnly)
    #expect(model.setupDisclosure.contains("Local teammate setup"))
    #expect(model.setupDisclosure.contains("Claude isn’t connected"))
    await model.load()
    #expect(model.displayRows.map(\.text) == snapshot.turns.map(\.text), "Existing saved hiring turns are preserved, even if they came from the review harness")
    #expect(model.composerSupportText.contains("focused candidate detail"))
    #expect(!model.composerSupportText.contains("preview"))
}

@Test("Loading resumes the ordered local transcript and candidate review exactly once")
@MainActor
func hiringLoadResumesLocalDraft() async throws {
    let snapshot = try hiringSnapshot(
        focusedField: .role,
        displayName: "Ada",
        turns: [
            (.guide, HiringConversationModel.previewDisclosure),
            (.user, "Ada"),
            (.guide, "What role should Ada have?")
        ]
    )
    let service = HiringConversationFakeService(
        loadSnapshot: snapshot,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)

    await model.load()
    await model.load()

    #expect(model.displayRows.map(\.text) == snapshot.turns.map(\.text))
    #expect(model.displayRows.map(\.author) == [.guide, .user, .guide])
    #expect(model.previewIdentity.id == hiringDraftUUID)
    #expect(model.previewIdentity.name == "Ada")
    #expect(model.reviewItems.first(where: { $0.field == .displayName })?.isComplete == true)
    #expect(model.focusedPrompt.contains("role"))
    #expect(model.conversationTitle == "Hiring Ada")
    #expect(model.acceptsConversationInput)
    #expect(model.lastReviewUpdate == nil)
    #expect(await service.recordedCalls().loadCount == 1)
}

@Test("Submitting shows an immediate pending row then adopts the durable service snapshot")
@MainActor
func hiringSubmitImmediateThenDurable() async throws {
    let initial = try hiringSnapshot()
    let exactAnswer = "  Ada the source scout  \n"
    let returned = try hiringSnapshot(
        focusedField: .role,
        displayName: "Ada the source scout",
        turns: [
            (.guide, initial.turns[0].text),
            (.user, exactAnswer),
            (.guide, "What role should Ada the source scout have?")
        ]
    )
    let service = HiringConversationFakeService(
        loadSnapshot: initial,
        submitSnapshot: returned,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)
    await model.load()
    model.composerText = exactAnswer
    let pendingID = UUID()

    model.submitCurrentText(
        messageID: pendingID,
        now: Date(timeIntervalSince1970: 10_300)
    )

    #expect(model.composerText.isEmpty)
    #expect(model.displayRows.last?.id == pendingID)
    #expect(model.displayRows.last?.text == exactAnswer)
    #expect(model.displayRows.last?.delivery == .pending)

    await waitForSubmission(model)
    #expect(await service.recordedCalls().submittedTexts == [exactAnswer])
    #expect(model.displayRows.map(\.text) == returned.turns.map(\.text))
    #expect(model.displayRows.last?.delivery == .saved)
    #expect(model.inlineError == nil)
    #expect(model.lastReviewUpdate?.fields == [.displayName])
    #expect(model.lastReviewUpdate?.fieldTitle == "Name")
    #expect(model.lastReviewUpdate?.displayValue == "Ada the source scout")
}

@Test("Submission failure stays row-local retryable and hides thrown diagnostics")
@MainActor
func hiringSubmitFailureIsSafe() async throws {
    let initial = try hiringSnapshot()
    let service = HiringConversationFakeService(
        loadSnapshot: initial,
        confirmation: try hiringConfirmation(),
        failures: [.submit]
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)
    await model.load()
    model.composerText = "Ada"

    model.submitCurrentText(messageID: UUID())
    #expect(model.displayRows.last?.delivery == .pending)
    await waitForSubmission(model)

    guard case .failed(let reason) = model.displayRows.last?.delivery else {
        Issue.record("Expected the pending hiring row to become failed")
        return
    }
    #expect(reason == HiringConversationModel.submitFailureMessage)
    #expect(reason.contains("/Users/") == false)
    #expect(model.inlineError == HiringConversationModel.submitFailureMessage)
    #expect(model.canSend == false)
    model.composerText = "Try Ada again"
    #expect(model.canSend)
}

@Test("Review exposes every required hiring dimension and keeps grants as intent")
@MainActor
func hiringReviewCompletenessAndSafety() async throws {
    let ready = try readyHiringSnapshot()
    let service = HiringConversationFakeService(
        loadSnapshot: ready,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)
    await model.load()

    #expect(model.reviewItems.map(\.field) == HiringCandidateField.allCases)
    #expect(model.reviewItems.count == 8)
    #expect(model.reviewItems.allSatisfy { $0.isComplete })
    #expect(model.readinessTitle == "Ready to hire")
    #expect(model.readinessDetail.contains("All 8 details"))
    #expect(model.canHire)
    #expect(model.canSend == false)
    #expect(model.acceptsConversationInput == false)
    #expect(model.composerSupportText.contains("explicitly choose Hire Teammate"))
    let permission = try #require(
        model.reviewItems.first(where: { $0.field == .permissionIntent })
    )
    #expect(permission.accessibilityDescription.contains("no permission is granted"))
    #expect(model.hireAccessibilityHint.contains("grant nothing"))
}

@Test("Secondary field revision uses the exact field and returned local authority")
@MainActor
func hiringStructuredRevisionIsSecondaryAndExact() async throws {
    let initial = try readyHiringSnapshot()
    let revisedText = "Research, source verification, and concise synthesis."
    let revised = try readyHiringSnapshot(responsibilities: revisedText)
    let service = HiringConversationFakeService(
        loadSnapshot: initial,
        revisionSnapshot: revised,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)
    await model.load()

    #expect(await model.revise(.responsibilities, text: revisedText))

    let calls = await service.recordedCalls()
    #expect(calls.revisions.count == 1)
    #expect(calls.revisions.first?.0 == .responsibilities)
    #expect(calls.revisions.first?.1 == revisedText)
    #expect(
        model.reviewItems.first(where: { $0.field == .responsibilities })?.rawValue
            == revisedText
    )
    #expect(model.lastReviewUpdate?.fields == [.responsibilities])
    #expect(model.lastReviewUpdate?.displayValue == revisedText)
}

@Test("Free-form chat updates the focused review field without claiming semantic inference")
@MainActor
func hiringFreeFormMessageHasObservableBoundedInterpretation() async throws {
    let initial = try hiringSnapshot(
        focusedField: .workingStyle,
        displayName: "Ada",
        role: "Research lead",
        responsibilities: "Own the research brief.",
        turns: [
            (.guide, HiringConversationModel.previewDisclosure),
            (.guide, "How should Ada work and communicate?")
        ]
    )
    let naturalMessage =
        "I want her to challenge weak evidence gently, explain tradeoffs clearly, and stay concise."
    let returned = try hiringSnapshot(
        focusedField: .skills,
        displayName: "Ada",
        role: "Research lead",
        responsibilities: "Own the research brief.",
        workingStyle: naturalMessage,
        turns: [
            (.guide, HiringConversationModel.previewDisclosure),
            (.guide, "How should Ada work and communicate?"),
            (.user, naturalMessage),
            (.guide, "Which skills should Ada bring?")
        ]
    )
    let service = HiringConversationFakeService(
        loadSnapshot: initial,
        submitSnapshot: returned,
        confirmation: try hiringConfirmation()
    )
    let model = HiringConversationModel(service: service, mode: .reviewFixture)
    await model.load()
    model.composerText = naturalMessage

    model.submitCurrentText()
    await waitForSubmission(model)

    #expect(await service.recordedCalls().submittedTexts == [naturalMessage])
    #expect(model.lastReviewUpdate?.fields == [.workingStyle])
    #expect(model.lastReviewUpdate?.fieldTitle == "Personality and working style")
    #expect(model.lastReviewUpdate?.displayValue == naturalMessage)
    #expect(model.composerSupportText.contains("does not infer other details"))
    #expect(model.lastReviewUpdate?.accessibilityDescription.contains("Candidate review updated") == true)
}

@Test("Cancel and explicit Hire Teammate are separate terminal operations")
@MainActor
func hiringConfirmAndCancelSemantics() async throws {
    let ready = try readyHiringSnapshot()
    let confirmation = try hiringConfirmation()

    let cancelService = HiringConversationFakeService(
        loadSnapshot: ready,
        confirmation: confirmation
    )
    let cancelModel = HiringConversationModel(service: cancelService, mode: .reviewFixture)
    await cancelModel.load()
    #expect(await cancelModel.cancel())
    #expect(cancelModel.isCancelled)
    #expect(cancelModel.canHire == false)
    let cancelCalls = await cancelService.recordedCalls()
    #expect(cancelCalls.cancelCount == 1)
    #expect(cancelCalls.confirmedAppearances.isEmpty)

    let confirmService = HiringConversationFakeService(
        loadSnapshot: ready,
        confirmation: confirmation
    )
    let confirmModel = HiringConversationModel(service: confirmService, mode: .reviewFixture)
    await confirmModel.load()
    let previewAppearance = confirmModel.previewIdentity.appearance
    #expect(await confirmModel.confirmHire())
    #expect(confirmModel.confirmedCreation == confirmation)
    #expect(confirmModel.canHire == false)
    let confirmCalls = await confirmService.recordedCalls()
    #expect(confirmCalls.cancelCount == 0)
    #expect(confirmCalls.confirmedAppearances.count == 1)
    #expect(
        confirmCalls.confirmedAppearances.first.map(CharacterAppearanceSnapshot.init)
            == previewAppearance
    )
}

@Test("New hiring previews carry every eligible model unchanged through confirmation")
@MainActor
func hiringModelAllocationSurvivesConfirmation() async throws {
    var observed: Set<String> = []
    for index in 0..<64 {
        let uuid = try #require(UUID(uuidString: String(format: "A2000000-0000-0000-0000-%012x", index)))
        let ready = try readyHiringSnapshot(draftUUID: uuid)
        let service = HiringConversationFakeService(loadSnapshot: ready, confirmation: try hiringConfirmation())
        let model = HiringConversationModel(service: service, mode: .reviewFixture)
        await model.load()
        let preview = model.previewIdentity.appearance
        observed.insert(preview.builtInAvatarID ?? "legacy")
        #expect(await model.confirmHire())
        let calls = await service.recordedCalls()
        #expect(calls.confirmedAppearances.first.map(CharacterAppearanceSnapshot.init) == preview)
    }
    #expect(observed == Set(["pillow", "fin", "kite", "bean", "guide", "legacy"]))
}

@Test("Load and confirmation failures never claim a runtime or expose private paths")
@MainActor
func hiringFailuresRemainTruthful() async throws {
    let ready = try readyHiringSnapshot()
    let loadService = HiringConversationFakeService(
        loadSnapshot: ready,
        confirmation: try hiringConfirmation(),
        failures: [.load]
    )
    let loadModel = HiringConversationModel(service: loadService, mode: .reviewFixture)
    await loadModel.load()
    #expect(loadModel.inlineError == HiringConversationModel.loadFailureMessage)
    #expect(loadModel.inlineError?.contains("/Users/") == false)

    let confirmService = HiringConversationFakeService(
        loadSnapshot: ready,
        confirmation: try hiringConfirmation(),
        failures: [.confirm]
    )
    let confirmModel = HiringConversationModel(service: confirmService, mode: .reviewFixture)
    await confirmModel.load()
    #expect(await confirmModel.confirmHire() == false)
    #expect(confirmModel.inlineError == HiringConversationModel.confirmFailureMessage)
    #expect(confirmModel.inlineError?.contains("Claude") == false)
    #expect(HiringConversationModel.previewDisclosure.contains("no Claude runtime or tool ran"))
}
