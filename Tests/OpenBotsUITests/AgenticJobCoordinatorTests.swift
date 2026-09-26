import Foundation
import OpenBotsDomain
import OpenBotsServices
import Testing
@testable import OpenBotsPersistence
@testable import OpenBotsUI

@Suite("Native sample-folder job controls")
@MainActor
struct AgenticJobCoordinatorTests {
    /// The jobs switches are moved on the store here: nothing on screen sets
    /// them since the retired runner lost its switch, toggle and banner, and
    /// the model only reads them for the runner's admission.
    @Test("Both independent switches are required and a different bot gets no grant")
    func accessIntersection() async {
        let store = AgenticJobAccessStore(), first = TeammateID(UUID()), second = TeammateID(UUID())
        let model = AgenticJobAccessModel(store: store)
        model.selectTeammate(first); await model.refresh()
        #expect(!model.appEnabled && !model.botEnabled && !model.isEnabled)
        await store.setBotEnabled(true, teammateID: first); await model.refresh()
        #expect(model.botEnabled && !model.isEnabled)
        await store.setAppEnabled(true); await model.refresh()
        #expect(model.isEnabled)
        model.selectTeammate(second); await model.refresh()
        #expect(model.appEnabled && !model.botEnabled && !model.isEnabled)
        #expect(!(await store.current(teammateID: second)).botEnabled)
        await store.setAppEnabled(false); await model.refresh()
        #expect(!(await store.current(teammateID: first)).isEnabled)
    }

    @Test("Web search and Web fetch each need their own master switch and bot grant, and a different bot gets nothing")
    func webSwitchesAreIndependent() async {
        let store = AgenticJobAccessStore(), first = TeammateID(UUID()), second = TeammateID(UUID())
        let model = AgenticJobAccessModel(store: store)
        model.selectTeammate(first); await model.refresh()
        for capability in AgenticWebCapability.allCases {
            #expect(!model.webAppEnabled(capability) && !model.webBotEnabled(capability) && !model.webIsEnabled(capability))
        }
        await model.setWebBotEnabled(true, capability: .search)
        #expect(model.webBotEnabled(.search) && !model.webIsEnabled(.search))
        #expect(!model.webBotEnabled(.fetch))
        await model.setWebAppEnabled(true, capability: .search)
        #expect(model.webIsEnabled(.search) && !model.webIsEnabled(.fetch))
        #expect(!model.isEnabled, "web grants never turn sample-folder jobs on")
        #expect((await store.current(teammateID: first)).grantedWebCapabilities == [.search])
        // Fetch stays off until both of its own switches are on.
        await model.setWebAppEnabled(true, capability: .fetch)
        #expect(!model.webIsEnabled(.fetch))
        await model.setWebBotEnabled(true, capability: .fetch)
        #expect(model.webIsEnabled(.fetch))
        #expect((await store.current(teammateID: first)).grantedWebCapabilities == [.search, .fetch])
        // Another bot inherits the masters, never the grants.
        model.selectTeammate(second); await model.refresh()
        #expect(model.webAppEnabled(.search) && model.webAppEnabled(.fetch))
        #expect(!model.webBotEnabled(.search) && !model.webBotEnabled(.fetch))
        #expect((await store.current(teammateID: second)).grantedWebCapabilities.isEmpty)
        await model.setWebBotEnabled(true, capability: .fetch, teammateID: first)
        #expect(!(await store.current(teammateID: second)).webFetch.botEnabled, "a stale bot identity grants nothing")
        // Master off wins over an existing grant, for that capability only.
        await model.setWebAppEnabled(false, capability: .search)
        #expect((await store.current(teammateID: first)).grantedWebCapabilities == [.fetch])
        #expect((await store.current(teammateID: first)).webSearch.botEnabled)
    }

    @Test("A web switch change while a job is active stops that job")
    func webSwitchChangeStopsActiveJob() async throws {
        let store = AgenticJobAccessStore(), service = NativeJobServiceSpy()
        let input = try jobInput("Create the report"), id = input.message.conversationID.rawValue
        await enable(store, bot: input.teammateID)
        let coordinator = AgenticJobCoordinator(service: service, access: store, changed: {})
        #expect(coordinator.reserve(conversationID: id, teammateID: input.teammateID, messageID: input.message.id.rawValue))
        await coordinator.submit(input)
        #expect(coordinator.presentation(for: id)?.phase == .working)
        await store.setAppEnabled(true, capability: .web(.fetch))
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.stopped.contains(ConversationID(id))), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.stopped.contains(ConversationID(id)))
        #expect(await service.inputs.count == 1)
        _ = await coordinator.flushForShutdown()
    }

    @Test("Switch changes after UI reservation prevent service dispatch")
    func freshAccessBeforeDispatch() async throws {
        let store = AgenticJobAccessStore(), service = NativeJobServiceSpy()
        let input = try jobInput("Create the report")
        await enable(store, bot: input.teammateID)
        let coordinator = AgenticJobCoordinator(service: service, access: store, changed: {})
        #expect(coordinator.reserve(conversationID: input.message.conversationID.rawValue,
            teammateID: input.teammateID, messageID: input.message.id.rawValue))
        await store.setAppEnabled(false)
        await coordinator.submit(input)
        #expect(await service.inputs.isEmpty)
        #expect(coordinator.presentation(for: input.message.conversationID.rawValue)?.description.contains("message was saved") == true)
        _ = await coordinator.flushForShutdown()
    }

    @Test("Corrections invalidate old callbacks and lower-generation approvals")
    func staleCorrectionCallbacks() async throws {
        let store = AgenticJobAccessStore(), service = NativeJobServiceSpy()
        let first = try jobInput("Create the report")
        await enable(store, bot: first.teammateID)
        let id = first.message.conversationID.rawValue
        let coordinator = AgenticJobCoordinator(service: service, access: store, changed: {})
        #expect(coordinator.reserve(conversationID: id, teammateID: first.teammateID, messageID: first.message.id.rawValue))
        await coordinator.submit(first)
        let second = try jobInput("Exclude test rows", bot: first.teammateID, conversation: first.message.conversationID, sequence: 2)
        #expect(coordinator.reserve(conversationID: id, teammateID: second.teammateID, messageID: second.message.id.rawValue))
        await coordinator.submit(second)
        let obsolete = await service.approval(generation: 1)
        await service.emit(index: 0, phase: .waitingForApproval, generation: 1, approval: obsolete)
        await service.emit(index: 1, phase: .waitingForApproval, generation: 1, approval: obsolete)
        #expect(coordinator.presentation(for: id)?.phase == .working)
        #expect(coordinator.presentation(for: id)?.approval == nil)
        await coordinator.decide(obsolete, allow: true, conversationID: id)
        #expect(await service.decisions.isEmpty)
        _ = await coordinator.flushForShutdown()
    }

    @Test("Stop removes approval immediately and shutdown joins owned service work")
    func stopInvalidatesApproval() async throws {
        let store = AgenticJobAccessStore(), service = NativeJobServiceSpy()
        let input = try jobInput("Create the report"), id = input.message.conversationID.rawValue
        await enable(store, bot: input.teammateID)
        let coordinator = AgenticJobCoordinator(service: service, access: store, changed: {})
        #expect(coordinator.reserve(conversationID: id, teammateID: input.teammateID, messageID: input.message.id.rawValue))
        await coordinator.submit(input)
        let approval = await service.approval(generation: 1)
        await service.emit(index: 0, phase: .waitingForApproval, generation: 1, approval: approval)
        #expect(coordinator.presentation(for: id)?.approval == approval)
        coordinator.stop(conversationID: id)
        #expect(coordinator.presentation(for: id)?.phase == .stopping)
        #expect(coordinator.presentation(for: id)?.approval == nil)
        await coordinator.decide(approval, allow: true, conversationID: id)
        #expect(await service.decisions.isEmpty)
        #expect(await coordinator.flushForShutdown())
        #expect(await service.didShutdown)
        #expect(await service.stopped.contains(ConversationID(id)))
    }

    @Test("One exact current review is decided once")
    func approveCurrentReviewOnce() async throws {
        let store = AgenticJobAccessStore(), service = NativeJobServiceSpy()
        let input = try jobInput("Create the report"), id = input.message.conversationID.rawValue
        await enable(store, bot: input.teammateID)
        let coordinator = AgenticJobCoordinator(service: service, access: store, changed: {})
        #expect(coordinator.reserve(conversationID: id, teammateID: input.teammateID, messageID: input.message.id.rawValue))
        await coordinator.submit(input)
        let approval = await service.approval(generation: 1)
        await service.emit(index: 0, phase: .waitingForApproval, generation: 1, approval: approval)
        await coordinator.decide(approval, allow: false, conversationID: id)
        await coordinator.decide(approval, allow: true, conversationID: id)
        #expect(await service.decisions == [false])
        _ = await coordinator.flushForShutdown()
    }

    @Test("Job state and the text reply phase are separate; Send stays live during a text turn")
    func composerUsesSeparateJobState() {
        let model = ConversationModel(conversationID: UUID(), composerText: "Exclude test rows",
            textRepliesEnabled: true, inputAvailability: .ready, submit: { _, _, _ in })
        model.setAgenticJob(enabled: true, presentation: .init(phase: .working, text: "",
            approval: nil, isSubmitting: false, isDeciding: false, observations: ["Web search: sample totals"]))
        #expect(model.canSend)
        #expect(model.agenticJobPresentation?.observations == ["Web search: sample totals"])
        model.setTextReplyPhase(.sending)
        #expect(model.canSend, "a text turn in flight never locks Send: the text is the correction")
        model.setTextReplyPhase(nil)
        model.setAgenticJob(enabled: true, presentation: .init(phase: .preparing, text: "",
            approval: nil, isSubmitting: true, isDeciding: false))
        #expect(!model.canSend)
        model.beginShutdown()
        #expect(!model.canSend)
    }

    @Test("Normal composer saves initial input and correction before native job dispatch")
    func workspacePersistsBeforeJobSubmit() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try fixture.open(), store = AgenticJobAccessStore()
        let jobs = NativeJobServiceSpy(messages: database)
        let workspace = DurableWorkspaceModel(mode: .localOnly, service: fixture.chatService(store: database),
            agenticJobService: jobs, agenticJobAccess: store, hiringService: ReferenceUnusedHiringService(),
            draftService: ConversationDraftService(repository: database, clock: AgenticWorkspaceTestClock()))
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        let teammate = try #require(workspace.selectedTeammate)
        await enable(store, bot: teammate.id)
        await workspace.agenticJobAccessModel?.refresh()
        // A fresh conversation's draft reports "saved" (empty equals empty) before
        // its load finishes, and Send is a no-op until the draft is loaded; wait
        // for the composer to be sendable, not only for the saved status.
        try await agenticWaitStep("draft loaded and sendable") {
            workspace.draftCoordinator?.activeDraft?.status == .saved && workspace.conversation.draftSubmissionAllowed
        }
        #expect(workspace.conversation.submissionActionTitle == "Send")
        workspace.conversation.composerText = "Create the sample report"
        #expect(workspace.conversation.canSend)
        workspace.conversation.sendCurrentText()
        do {
            try await agenticWaitStep("first job phase working") { workspace.conversation.agenticJobPresentation?.phase == .working
                && workspace.conversation.agenticJobPresentation?.isSubmitting == false }
        } catch {
            Issue.record("state: presentation=\(String(describing: workspace.conversation.agenticJobPresentation)) canSend=\(workspace.conversation.canSend) draftAllowed=\(workspace.conversation.draftSubmissionAllowed) messages=\(workspace.conversation.messages.map(\.body)) composer='\(workspace.conversation.composerText)'")
            throw error
        }
        workspace.conversation.composerText = "Exclude test rows"
        workspace.conversation.sendCurrentText()
        try await agenticWaitStep("correction accepted") { workspace.conversation.agenticJobPresentation?.text == "Input 2 accepted"
            && workspace.conversation.agenticJobPresentation?.isSubmitting == false }
        #expect(await jobs.inputs.map(\.text) == ["Create the sample report", "Exclude test rows"])
        #expect(await jobs.savedBeforeSubmit == [true, true])
        #expect(workspace.conversation.messages.filter { $0.author == .user }.map(\.body)
            == ["Create the sample report", "Exclude test rows"])
        workspace.beginShutdown()
        _ = await workspace.flushForShutdown()
        workspace.finishShutdown()
        #expect(await jobs.didShutdown)
    }

    /// The app composes the job service on every launch outside review
    /// fixtures, and the composer's delivery line and its tooltip used to
    /// switch to a sentence about sample-folder jobs whenever it was there,
    /// long after no control could turn a job on.
    @Test("A composed job service leaves the composer's delivery line alone: it never names the retired sample-folder jobs")
    func deliveryLineNamesNoRetiredJobs() async throws {
        let fixture = try ReferenceLocalWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try fixture.open()
        let workspace = DurableWorkspaceModel(mode: .localOnly, service: fixture.chatService(store: database),
            agenticJobService: NativeJobServiceSpy(messages: database), agenticJobAccess: AgenticJobAccessStore(),
            hiringService: ReferenceUnusedHiringService())
        try await workspace.loadInitialWorkspace()
        await workspace.createTeammateImmediately()
        #expect(workspace.conversation.readyDeliveryDescription == DurableWorkspaceModel.localDeliveryDescription)
        #expect(!workspace.conversation.readyDeliveryDescription.contains("job"))
        workspace.beginShutdown()
        _ = await workspace.flushForShutdown()
        workspace.finishShutdown()
    }

    private func enable(_ store: AgenticJobAccessStore, bot: TeammateID) async {
        await store.setAppEnabled(true); await store.setBotEnabled(true, teammateID: bot)
    }

    private func jobInput(_ text: String, bot: TeammateID = TeammateID(UUID()),
                          conversation: ConversationID = ConversationID(UUID()), sequence: Int64 = 1) throws -> AgenticJobInput {
        let now = Date()
        let message = try Message(id: MessageID(UUID()), conversationID: conversation, sequence: sequence,
            author: .user, deliveryState: .completed,
            parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(text))], createdAt: now, updatedAt: now)
        return AgenticJobInput(teammateID: bot, message: message, text: text)
    }
}

/// Names the wait that stalls, so a timeout in this long flow is diagnosable.
@MainActor
private func agenticWaitStep(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
    do { try await referenceWaitUntil(predicate) }
    catch { Issue.record("Wait for \(label) did not settle within the budget"); throw error }
}

private struct AgenticWorkspaceTestClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_788_000_000) }
}

private actor NativeJobServiceSpy: AgenticJobServing {
    let runID = RunID(UUID())
    private let messages: (any MessageRepository)?
    private var callbacks: [@Sendable (AgenticJobProgress) async -> Void] = []
    private(set) var inputs: [AgenticJobInput] = []
    private(set) var savedBeforeSubmit: [Bool] = []
    private(set) var decisions: [Bool] = []
    private(set) var stopped: [ConversationID] = []
    private(set) var didShutdown = false

    init(messages: (any MessageRepository)? = nil) { self.messages = messages }

    func submit(_ input: AgenticJobInput, progress: @escaping @Sendable (AgenticJobProgress) async -> Void) async throws -> RunID {
        if let messages { savedBeforeSubmit.append(try await messages.message(id: input.message.id) == input.message) }
        inputs.append(input); callbacks.append(progress)
        await emit(index: callbacks.count - 1, phase: .working, generation: UInt64(inputs.count))
        return runID
    }

    func approval(generation: UInt64) -> AgenticJobApproval {
        AgenticJobApproval(id: UUID(), runID: runID, conversationGeneration: generation,
            title: "Deliver the sample report", detail: "Create one new report containing the checked sample totals.",
            target: "/private/tmp/sample-output/report.json", expiresAt: Date().addingTimeInterval(60))
    }

    func emit(index: Int, phase: AgenticJobPhase, generation: UInt64, approval: AgenticJobApproval? = nil) async {
        await callbacks[index](AgenticJobProgress(runID: runID, conversationID: inputs[index].message.conversationID,
            phase: phase, text: "Input \(index + 1) accepted", approval: approval, conversationGeneration: generation))
    }

    func decide(_ approval: AgenticJobApproval, allow: Bool) async throws {
        decisions.append(allow)
        await emit(index: callbacks.count - 1, phase: .working, generation: approval.conversationGeneration)
    }

    func stop(conversationID: ConversationID) async {
        stopped.append(conversationID)
        if !callbacks.isEmpty { await emit(index: callbacks.count - 1, phase: .stopped, generation: UInt64(inputs.count)) }
    }
    func history(conversationID: ConversationID) async throws -> [AgenticJobRecord] { [] }
    func shutdown() async { didShutdown = true }
}
