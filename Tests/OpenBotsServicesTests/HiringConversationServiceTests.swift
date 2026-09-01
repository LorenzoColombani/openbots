import Foundation
import OpenBotsDomain
import Testing
@testable import OpenBotsServices

private struct HiringFixedClock: OpenBotsClock {
    let value: Date
    func now() -> Date { value }
}

private final class HiringSequenceUUIDGenerator: UUIDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64

    init(startingAt: UInt64 = 1) {
        nextValue = startingAt
    }

    func next() -> UUID {
        lock.lock()
        defer {
            nextValue += 1
            lock.unlock()
        }
        return hiringUUID(nextValue)
    }
}

private struct HiringRevisionCall: Equatable, Sendable {
    let draft: HiringDraft
    let expectedRevision: UInt64
    let turns: [HiringTurn]
}

private struct HiringCancellationCall: Equatable, Sendable {
    let id: HiringDraftID
    let expectedRevision: UInt64
}

private struct HiringConfirmationCall: Equatable, Sendable {
    let id: HiringDraftID
    let expectedRevision: UInt64
    let teammate: Teammate
    let conversation: Conversation
    let fixtureGreeting: Message?
    let selectConversation: Bool
}

private struct HiringRepositoryState: Equatable, Sendable {
    let latest: HiringDraftSnapshot?
    let createCount: Int
    let revisionCalls: [HiringRevisionCall]
    let cancellationCalls: [HiringCancellationCall]
    let confirmationCalls: [HiringConfirmationCall]
}

private enum HiringInterpreterFailure: Error, Equatable, Sendable {
    case injected
}

private actor HiringInterpreterFake: HiringCandidateInterpreting {
    nonisolated let openingGuideText =
        "Injected interpreter test fixture — no production runtime ran. Describe the teammate you need."
    private let result: Result<HiringCandidateInterpretation, HiringInterpreterFailure>
    private var requests: [HiringCandidateInterpretationRequest] = []

    init(
        result: Result<HiringCandidateInterpretation, HiringInterpreterFailure>
    ) {
        self.result = result
    }

    func interpret(
        _ request: HiringCandidateInterpretationRequest
    ) async throws -> HiringCandidateInterpretation {
        requests.append(request)
        return try result.get()
    }

    func recordedRequests() -> [HiringCandidateInterpretationRequest] {
        requests
    }
}

private actor HiringDraftRepositoryFake: HiringDraftRepository {
    private var latest: HiringDraftSnapshot?
    private var createCount = 0
    private var revisionCalls: [HiringRevisionCall] = []
    private var cancellationCalls: [HiringCancellationCall] = []
    private var confirmationCalls: [HiringConfirmationCall] = []
    private let latestFailure: RepositoryError?
    private let revisionFailure: RepositoryError?
    private let confirmationFailure: RepositoryError?

    init(
        latest: HiringDraftSnapshot? = nil,
        latestFailure: RepositoryError? = nil,
        revisionFailure: RepositoryError? = nil,
        confirmationFailure: RepositoryError? = nil
    ) {
        self.latest = latest
        self.latestFailure = latestFailure
        self.revisionFailure = revisionFailure
        self.confirmationFailure = confirmationFailure
    }

    func latestHiringDraft() async throws -> HiringDraftSnapshot? {
        if let latestFailure { throw latestFailure }
        return latest
    }

    func createHiringDraft(
        _ snapshot: HiringDraftSnapshot
    ) async throws -> HiringDraftSnapshot {
        createCount += 1
        guard latest == nil else {
            throw RepositoryError.alreadyExists(
                entity: "hiring draft",
                id: snapshot.draft.id.persistedValue
            )
        }
        latest = snapshot
        return snapshot
    }

    func reviseHiringDraft(
        _ draft: HiringDraft,
        expectedRevision: UInt64,
        appending turns: [HiringTurn]
    ) async throws -> HiringDraftSnapshot {
        revisionCalls.append(
            HiringRevisionCall(
                draft: draft,
                expectedRevision: expectedRevision,
                turns: turns
            )
        )
        if let revisionFailure { throw revisionFailure }
        guard let current = latest else {
            throw RepositoryError.notFound(
                entity: "hiring draft",
                id: draft.id.persistedValue
            )
        }
        guard current.draft.id == draft.id,
              current.draft.revision == expectedRevision,
              draft.revision == expectedRevision + 1 else {
            throw RepositoryError.optimisticLockFailed(
                entity: "hiring draft",
                id: draft.id.persistedValue
            )
        }
        let revised = try HiringDraftSnapshot(
            draft: draft,
            turns: current.turns + turns
        )
        latest = revised
        return revised
    }

    func cancelHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64
    ) async throws {
        cancellationCalls.append(
            HiringCancellationCall(id: id, expectedRevision: expectedRevision)
        )
        guard latest?.draft.id == id,
              latest?.draft.revision == expectedRevision else {
            throw RepositoryError.optimisticLockFailed(
                entity: "hiring draft",
                id: id.persistedValue
            )
        }
        latest = nil
    }

    func confirmHiringDraft(
        id: HiringDraftID,
        expectedRevision: UInt64,
        teammate: Teammate,
        conversation: Conversation,
        fixtureGreeting: Message?,
        selectConversation: Bool
    ) async throws {
        confirmationCalls.append(
            HiringConfirmationCall(
                id: id,
                expectedRevision: expectedRevision,
                teammate: teammate,
                conversation: conversation,
                fixtureGreeting: fixtureGreeting,
                selectConversation: selectConversation
            )
        )
        if let confirmationFailure { throw confirmationFailure }
        guard latest?.draft.id == id,
              latest?.draft.revision == expectedRevision else {
            throw RepositoryError.optimisticLockFailed(
                entity: "hiring draft",
                id: id.persistedValue
            )
        }
        latest = nil
    }

    func state() -> HiringRepositoryState {
        HiringRepositoryState(
            latest: latest,
            createCount: createCount,
            revisionCalls: revisionCalls,
            cancellationCalls: cancellationCalls,
            confirmationCalls: confirmationCalls
        )
    }
}

@Test("One natural hiring message can provisionally revise several fields in one atomic write")
func hiringInterpretationRevisesSeveralFieldsAtomically() async throws {
    let repository = HiringDraftRepositoryFake()
    let guideResponse = "I understood the role and core duties. How should Mira work and communicate?"
    let interpreter = HiringInterpreterFake(
        result: .success(
            HiringCandidateInterpretation(
                provisionalValues: [
                    .displayName: "Mira",
                    .role: "Research and artifact specialist",
                    .responsibilities: "Research reliable sources and produce verified artifacts"
                ],
                guideResponse: guideResponse
            )
        )
    )
    let service = makeHiringService(
        repository: repository,
        interpreter: interpreter
    )
    let started = try await service.loadOrStart()
    let naturalMessage =
        "I need Mira, a research and artifact specialist who researches reliable sources and produces verified artifacts."

    let revised = try await service.submit(text: naturalMessage)

    #expect(revised.draft.displayName == "Mira")
    #expect(revised.draft.role == "Research and artifact specialist")
    #expect(revised.draft.responsibilities == "Research reliable sources and produce verified artifacts")
    #expect(revised.draft.workingStyle == nil)
    #expect(revised.draft.revision == started.draft.revision + 1)
    #expect(revised.focusedField == .workingStyle)
    #expect(revised.turns.count == started.turns.count + 2)
    #expect(revised.turns.suffix(2).first?.author == .user)
    #expect(revised.turns.suffix(2).first?.text == naturalMessage)
    #expect(revised.turns.last?.author == .guide)
    #expect(revised.turns.last?.text == guideResponse)

    let requests = await interpreter.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.message == naturalMessage)
    #expect(requests.first?.draft == started.draft)
    #expect(requests.first?.focusedField == .displayName)

    let state = await repository.state()
    #expect(state.revisionCalls.count == 1)
    let call = try #require(state.revisionCalls.first)
    #expect(call.expectedRevision == started.draft.revision)
    #expect(call.draft == revised.draft)
    #expect(call.turns == Array(revised.turns.suffix(2)))
}

@Test("A missing or ambiguous detail stays provisional and receives the interpreter's follow-up")
func hiringInterpretationCanAskAnAmbiguousFollowUp() async throws {
    let repository = HiringDraftRepositoryFake()
    let guideResponse = "Mira could be a researcher or a research lead. Which role do you mean?"
    let interpreter = HiringInterpreterFake(
        result: .success(
            HiringCandidateInterpretation(
                provisionalValues: [.displayName: "Mira"],
                guideResponse: guideResponse
            )
        )
    )
    let service = makeHiringService(
        repository: repository,
        interpreter: interpreter
    )
    _ = try await service.loadOrStart()

    let revised = try await service.submit(
        text: "I'd like Mira to handle our research."
    )

    #expect(revised.draft.displayName == "Mira")
    #expect(revised.draft.role == nil)
    #expect(revised.draft.phase == .collecting)
    #expect(revised.focusedField == .role)
    #expect(revised.turns.last?.text == guideResponse)
    let state = await repository.state()
    #expect(state.revisionCalls.count == 1)
    #expect(state.confirmationCalls.isEmpty)
}

@Test("Interpreter and repository failures leave the prior hiring draft unchanged")
func hiringInterpretationFailuresDoNotMutateTheDraft() async throws {
    let interpretationFailureRepository = HiringDraftRepositoryFake()
    let failingInterpreter = HiringInterpreterFake(result: .failure(.injected))
    let interpretationFailureService = makeHiringService(
        repository: interpretationFailureRepository,
        interpreter: failingInterpreter
    )
    let beforeInterpretationFailure = try await interpretationFailureService.loadOrStart()

    await #expect(throws: HiringInterpreterFailure.injected) {
        try await interpretationFailureService.submit(text: "Create Mira as a research lead")
    }

    let afterInterpretationFailure = await interpretationFailureRepository.state()
    #expect(afterInterpretationFailure.latest == beforeInterpretationFailure.persisted)
    #expect(afterInterpretationFailure.revisionCalls.isEmpty)

    let repositoryFailure = RepositoryError.unavailable(reason: "injected atomic write failure")
    let atomicFailureRepository = HiringDraftRepositoryFake(
        revisionFailure: repositoryFailure
    )
    let successfulInterpreter = HiringInterpreterFake(
        result: .success(
            HiringCandidateInterpretation(
                provisionalValues: [
                    .displayName: "Mira",
                    .role: "Research lead"
                ]
            )
        )
    )
    let atomicFailureService = makeHiringService(
        repository: atomicFailureRepository,
        interpreter: successfulInterpreter
    )
    let beforeAtomicFailure = try await atomicFailureService.loadOrStart()

    await #expect(throws: RepositoryError.self) {
        try await atomicFailureService.submit(text: "Create Mira as a research lead")
    }

    let afterAtomicFailure = await atomicFailureRepository.state()
    #expect(afterAtomicFailure.latest == beforeAtomicFailure.persisted)
    #expect(afterAtomicFailure.revisionCalls.count == 1)
    #expect(afterAtomicFailure.confirmationCalls.isEmpty)
}

@Test("Hiring starts once, resumes the same draft, and visibly discloses the local guide")
func hiringStartAndResume() async throws {
    let repository = HiringDraftRepositoryFake()
    let clock = HiringFixedClock(value: Date(timeIntervalSince1970: 9_100))
    let service = HiringConversationService(mode: .reviewFixture,
        repository: repository,
        clock: clock,
        uuidGenerator: HiringSequenceUUIDGenerator()
    )

    let created = try await service.loadOrStart()
    let resumed = try await service.loadOrStart()

    #expect(created == resumed)
    #expect(created.draft.id == HiringDraftID(hiringUUID(1)))
    #expect(created.focusedField == .displayName)
    #expect(created.turns.count == 1)
    #expect(created.turns[0].id == HiringTurnID(hiringUUID(2)))
    #expect(created.turns[0].author == .guide)
    #expect(created.turns[0].text.contains("Local guided hiring preview"))
    #expect(created.turns[0].text.contains("no Claude runtime or tool ran"))
    #expect(created.turns[0].text.contains("exact answer in the transcript"))
    #expect(created.turns[0].text.contains("without interpreting"))
    let state = await repository.state()
    #expect(state.createCount == 1)
    #expect(state.revisionCalls.isEmpty)
    #expect(state.confirmationCalls.isEmpty)
}

@Test("Focused collection stores exact user text without pretending semantic inference")
func hiringFocusedCollectionIsExact() async throws {
    let repository = HiringDraftRepositoryFake()
    let service = makeHiringService(repository: repository)
    _ = try await service.loadOrStart()

    let exactText = "Ada researches sources and uses browser tools"
    let afterName = try await service.submit(text: exactText)

    #expect(afterName.draft.displayName == exactText)
    #expect(afterName.draft.role == nil)
    #expect(afterName.focusedField == .role)
    #expect(afterName.turns[1].author == .user)
    #expect(afterName.turns[1].text == exactText)
    #expect(afterName.turns[2].author == .guide)
    #expect(afterName.turns[2].text.contains("What role"))

    let exactRole = " Research lead "
    let afterRole = try await service.submit(text: exactRole)
    #expect(afterRole.draft.role == "Research lead")
    #expect(afterRole.turns[3].text == exactRole)
    #expect(afterRole.focusedField == .responsibilities)
}

@Test("A named field correction preserves collection focus and exact audit text")
func hiringExplicitCorrection() async throws {
    let repository = HiringDraftRepositoryFake()
    let service = makeHiringService(repository: repository)
    _ = try await service.loadOrStart()
    _ = try await service.submit(text: "Ada")

    let corrected = try await service.revise(
        field: .displayName,
        value: "Grace"
    )

    #expect(corrected.draft.displayName == "Grace")
    #expect(corrected.draft.role == nil)
    #expect(corrected.focusedField == .role)
    #expect(corrected.turns.suffix(2).first?.author == .user)
    #expect(corrected.turns.suffix(2).first?.text == "Grace")
    #expect(corrected.turns.last?.text.contains("What role should Grace" ) == true)
}

@Test("Every review dimension is collected before the local draft becomes ready")
func hiringReadinessRequiresAllReviewDimensions() async throws {
    let repository = HiringDraftRepositoryFake()
    let service = makeHiringService(repository: repository)
    _ = try await service.loadOrStart()
    let values = hiringValues()

    for field in HiringCandidateField.allCases.dropLast() {
        let snapshot = try await service.submit(text: values[field]!)
        #expect(snapshot.draft.phase == .collecting)
        #expect(snapshot.focusedField != nil)
    }
    let ready = try await service.submit(
        text: values[.teamPlacement]!
    )

    #expect(ready.isReadyForReview)
    #expect(ready.focusedField == nil)
    #expect(ready.turns.count == 17)
    #expect(ready.turns.last?.author == .guide)
    #expect(ready.turns.last?.text.contains("no Claude runtime or tool ran") == true)
    #expect(ready.turns.last?.text.contains("nothing has been created or granted") == true)
    #expect(ready.turns.last?.text.contains("Permission intent") == true)
    let state = await repository.state()
    #expect(state.confirmationCalls.isEmpty)

    await #expect(throws: HiringConversationError.draftAlreadyReadyForReview) {
        try await service.submit(text: "This must not become another inferred field")
    }
}

@Test("Cancelling removes only the provisional draft and creates no teammate aggregate")
func hiringCancelHasNoTeammateSideEffect() async throws {
    let repository = HiringDraftRepositoryFake()
    let service = makeHiringService(repository: repository)
    let started = try await service.loadOrStart()
    _ = try await service.submit(text: "Ada")

    try await service.cancel()

    let state = await repository.state()
    #expect(state.latest == nil)
    #expect(state.cancellationCalls == [
        HiringCancellationCall(
            id: started.draft.id,
            expectedRevision: 2
        )
    ])
    #expect(state.confirmationCalls.isEmpty)
    await #expect(throws: HiringConversationError.draftUnavailable) {
        try await service.cancel()
    }
}

@Test("Unavailable storage and malformed answers fail without revising the draft")
func hiringUnavailableAndMalformedInput() async throws {
    let unavailable = RepositoryError.unavailable(reason: "injected offline store")
    let unavailableService = makeHiringService(
        repository: HiringDraftRepositoryFake(latestFailure: unavailable)
    )
    await #expect(throws: RepositoryError.self) {
        try await unavailableService.loadOrStart()
    }

    let repository = HiringDraftRepositoryFake()
    let service = makeHiringService(repository: repository)
    _ = try await service.loadOrStart()
    await #expect(throws: HiringConversationError.emptyCandidateValue(.displayName)) {
        try await service.submit(text: "  \n ")
    }
    await #expect(throws: DomainValidationError.self) {
        try await service.submit(text: String(repeating: "a", count: 81))
    }
    await #expect(
        throws: HiringConversationError.draftNotReadyForReview(
            missingFields: HiringCandidateField.allCases
        )
    ) {
        try await service.confirm(appearance: hiringAppearance())
    }
    let state = await repository.state()
    #expect(state.revisionCalls.isEmpty)
    #expect(state.confirmationCalls.isEmpty)
}

@Test("Confirmation supplies one exact atomic aggregate and derives identity only at that boundary")
func hiringExactAtomicConfirmationPayload() async throws {
    let draftID = HiringDraftID(
        UUID(uuidString: "94000000-0000-0000-0000-000000000099")!
    )
    let snapshot = try readyHiringSnapshot(id: draftID)
    let repository = HiringDraftRepositoryFake(latest: snapshot)
    let clock = HiringFixedClock(value: Date(timeIntervalSince1970: 9_499))
    let service = HiringConversationService(mode: .reviewFixture,
        repository: repository,
        clock: clock,
        uuidGenerator: HiringSequenceUUIDGenerator(startingAt: 90)
    )
    let appearance = try hiringAppearance()

    let result = try await service.confirm(appearance: appearance)

    let state = await repository.state()
    #expect(state.latest == nil)
    #expect(state.confirmationCalls.count == 1)
    let call = try #require(state.confirmationCalls.first)
    #expect(call.id == draftID)
    #expect(call.expectedRevision == snapshot.draft.revision)
    #expect(call.teammate.id == TeammateID(draftID.rawValue))
    #expect(call.teammate.appearance == appearance)
    #expect(call.teammate.createdAt == clock.value)
    #expect(call.teammate.profile.displayName == "Ada")
    #expect(call.teammate.profile.role == "Research lead")
    let instructions = try #require(call.teammate.profile.detailedInstructions)
    #expect(instructions.contains("Responsibilities:\nResearch across primary sources"))
    #expect(instructions.contains("Permission intent only — no grant was created:\nRead selected research folders"))
    #expect(instructions.contains("Project placement intent only — no membership was created:\nProduct research"))
    #expect(instructions.contains("Team placement intent only — no membership was created:\nResearch team"))
    #expect(call.conversation.id == ConversationID(hiringUUID(90)))
    #expect(call.conversation.kind == .direct(teammateID: call.teammate.id))
    #expect(call.fixtureGreeting?.id == MessageID(hiringUUID(91)))
    #expect(call.fixtureGreeting?.parts.first?.id == MessagePartID(hiringUUID(92)))
    #expect(call.fixtureGreeting?.text.contains("No Claude runtime or tool ran") == true)
    #expect(call.fixtureGreeting?.text.contains("no grant or membership was created") == true)
    #expect(call.selectConversation)
    #expect(result.teammate == call.teammate)
    #expect(result.conversation == call.conversation)
    #expect(result.fixtureGreeting == call.fixtureGreeting)
    #expect(result.selection.teammate == call.teammate)
    #expect(result.selection.conversation == call.conversation)
}

@Test("Atomic confirmation failure returns no fabricated success and leaves the draft available")
func hiringConfirmationFailureIsHonest() async throws {
    let snapshot = try readyHiringSnapshot(
        id: HiringDraftID(hiringUUID(70))
    )
    let failure = RepositoryError.unavailable(reason: "injected atomic failure")
    let repository = HiringDraftRepositoryFake(
        latest: snapshot,
        confirmationFailure: failure
    )
    let service = makeHiringService(repository: repository)

    await #expect(throws: RepositoryError.self) {
        try await service.confirm(appearance: hiringAppearance())
    }

    let state = await repository.state()
    #expect(state.latest == snapshot)
    #expect(state.confirmationCalls.count == 1)
}

@Test("Normal hiring retains every exact candidate field and confirms without a synthetic greeting")
func hiringLocalSetupWithoutSyntheticGreeting() async throws {
    let repository = HiringDraftRepositoryFake()
    let service = HiringConversationService(repository: repository)
    let started = try await service.loadOrStart()
    #expect(started.turns.first?.text.contains("Local teammate setup") == true)
    #expect(started.turns.first?.text.contains("Claude isn’t connected") == true)
    let values = hiringValues()
    var snapshot = started
    for field in HiringCandidateField.allCases {
        snapshot = try await service.submit(text: try #require(values[field]))
    }
    #expect(snapshot.isReadyForReview)
    #expect(snapshot.turns.filter { $0.author == .user }.map(\.text) == HiringCandidateField.allCases.compactMap { values[$0] })
    #expect(snapshot.turns.last?.text.contains("Local teammate setup") == true)
    #expect(snapshot.turns.last?.text.contains("nothing has been created or granted") == true)
    #expect(await repository.state().confirmationCalls.isEmpty)
    let confirmed = try await service.confirm(appearance: hiringAppearance())
    #expect(confirmed.fixtureGreeting == nil)
    let call = try #require(await repository.state().confirmationCalls.first)
    #expect(call.fixtureGreeting == nil)
    #expect(call.teammate.profile.displayName == values[.displayName])
    #expect(call.teammate.profile.detailedInstructions?.contains(values[.responsibilities]!) == true)
    #expect(call.selectConversation)
}

private func makeHiringService(
    repository: HiringDraftRepositoryFake,
    interpreter: any HiringCandidateInterpreting = ExactFocusedFieldHiringInterpreter(mode: .reviewFixture)
) -> HiringConversationService {
    HiringConversationService(mode: .reviewFixture,
        repository: repository,
        clock: HiringFixedClock(value: Date(timeIntervalSince1970: 9_200)),
        uuidGenerator: HiringSequenceUUIDGenerator(),
        interpreter: interpreter
    )
}

private func hiringValues() -> [HiringCandidateField: String] {
    [
        .displayName: "Ada",
        .role: "Research lead",
        .responsibilities: "Research across primary sources",
        .workingStyle: "Concise, careful, and collaborative",
        .skills: "Web research, synthesis, and artifact review",
        .permissionIntent: "Read selected research folders",
        .projectPlacement: "Product research",
        .teamPlacement: "Research team"
    ]
}

private func readyHiringSnapshot(
    id: HiringDraftID
) throws -> HiringDraftSnapshot {
    let timestamp = Date(timeIntervalSince1970: 9_400)
    let values = hiringValues()
    let draft = try HiringDraft(
        id: id,
        phase: .readyForReview,
        displayName: values[.displayName],
        role: values[.role],
        responsibilities: values[.responsibilities],
        workingStyle: values[.workingStyle],
        skills: values[.skills],
        permissionIntent: values[.permissionIntent],
        projectPlacement: values[.projectPlacement],
        teamPlacement: values[.teamPlacement],
        revision: 9,
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let turn = try HiringTurn(
        id: HiringTurnID(hiringUUID(60)),
        draftID: id,
        sequence: 1,
        author: .guide,
        text: HiringConversationService.previewDisclosure,
        createdAt: timestamp
    )
    return try HiringDraftSnapshot(draft: draft, turns: [turn])
}

private func hiringAppearance() throws -> AgentAppearance {
    try AgentAppearance(
        mode: .creature,
        grammarVersion: 1,
        deterministicSeed: 9_400,
        silhouette: "sprout",
        paletteToken: "mint",
        eyeDialect: "bright",
        nonColorIdentityCue: "leaf ears",
        accessibleIdentityDescription: "Mint sprout creature with leaf ears"
    )
}

private func hiringUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llx", value)
    return UUID(uuidString: "94000000-0000-0000-0000-\(suffix)")!
}

private extension Message {
    var text: String {
        parts.compactMap { part in
            guard case let .text(value) = part.content else { return nil }
            return value
        }.joined(separator: "\n")
    }
}
