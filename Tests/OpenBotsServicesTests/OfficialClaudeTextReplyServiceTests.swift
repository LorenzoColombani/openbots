import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("Official text replies with an inert runtime")
struct OfficialClaudeTextReplyServiceTests {
    @Test("Each bot freezes its own model, and a saved change applies only to its next launch")
    func perBotModelSelectionAndNextLaunch() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: "claude-haiku-4-5-20251001", contextWindow: "standard")
        let secondBot = TeammateID(UUID()), secondChat = ConversationID(UUID())
        try await f.seed(store, model: "claude-opus-5", effort: "low", teammateID: secondBot, conversationID: secondChat)
        let runner = TextReplyRunner(.success)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let service = f.service(store, prepare: prepare, runner: runner)
        let changed = TextReplyModelChangeGate()
        let first = await service.sendText(f.submission()) { event in
            if case .modelObserved = event, await changed.take() {
                do {
                    var bot = try #require(try await store.teammate(id: f.teammateID))
                    let oldRevision = bot.profile.revision
                    bot.claudeModel = "claude-fable-5"
                    bot.claudeEffort = "xhigh"
                    bot.claudeContextWindow = "long"
                    bot.profile = try bot.profile.revised()
                    bot.updatedAt = Date(timeIntervalSince1970: 4_101)
                    try await store.update(bot, expectedProfileRevision: oldRevision)
                } catch { Issue.record("Could not save next-run model: \(error)") }
            }
        }
        #expect(first.outcome == .completed)
        let second = await service.sendText(.init(conversationID: secondChat, teammateID: secondBot,
            userMessageID: MessageID(UUID()), text: "Second bot's independent request.")) { _ in }
        #expect(second.outcome == .completed)
        let next = await service.sendText(f.submission()) { _ in }
        #expect(next.outcome == .completed)
        let requests = await runner.requests
        #expect(requests.map(\.model) == ["claude-haiku-4-5-20251001", "claude-opus-5", "claude-fable-5"])
        #expect(requests.map(\.effort) == [nil, "low", "xhigh"])
        #expect(requests.map(\.contextWindow) == ["standard", "default", "long"])
        for request in requests {
            let arguments = ClaudeTextOnlyCommandBuilder.arguments(for: request)
            let index = try #require(arguments.firstIndex(of: "--model"))
            #expect(arguments[index + 1] == request.model)
        }
        #expect(await prepare.models == requests.map(\.model))
        #expect(await prepare.selections == requests.map(\.executionSelection))
        for request in requests {
            let run = try #require(try await store.run(id: RunID(request.runID)))
            #expect(run.request.textTurnIdentity?.executionRequest == request.executionRequest)
        }
        let firstRequest = try #require(requests.first)
        let firstRun = try #require(try await store.run(id: RunID(firstRequest.runID)))
        #expect(firstRun.request.profileRevision == 1)
        #expect(firstRun.request.textTurnIdentity?.executionRequest?.selection.contextWindow == "standard")
        #expect(try await store.teammate(id: secondBot)?.claudeModel == "claude-opus-5")
    }

    @Test("Unknown or retired saved models remain unchanged and never reach preparation or launch",
          arguments: ["opus", "claude-sonnet-retired", "unreviewed-model", "sonnet --tools Bash"])
    func unavailableSavedModelIsPreserved(_ model: String) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: model)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let runner = TextReplyRunner(.success)
        let service = f.service(store, prepare: prepare, runner: runner)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(.modelUnavailable))
        #expect(result.savedUserMessage == nil)
        #expect(await prepare.calls == 0)
        #expect(await runner.requests.isEmpty)
        #expect(try await store.teammate(id: f.teammateID)?.claudeModel == model)
        #expect(try await store.runs(conversationID: f.conversationID, limit: 10).isEmpty)
    }

    @Test("An incompatible saved effort remains unchanged and refuses before preparation",
          arguments: ["xhigh", "ultracode", "auto", "unrecognized"])
    func incompatibleEffortIsPreserved(_ effort: String) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: "claude-sonnet-4-6", effort: effort)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let runner = TextReplyRunner(.success)
        let result = await f.service(store, prepare: prepare, runner: runner).sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(.effortUnavailable))
        #expect(result.savedUserMessage == nil)
        #expect(await prepare.calls == 0)
        #expect(await runner.requests.isEmpty)
        #expect(try await store.teammate(id: f.teammateID)?.claudeEffort == effort)
    }

    @Test("The explicit Default effort is preserved in storage and omitted from the request")
    func defaultEffortIsNotAFlag() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: "claude-sonnet-5", effort: "default")
        let runner = TextReplyRunner(.success)
        let result = await f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
            .sendText(f.submission()) { _ in }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(request.effort == nil)
        #expect(!ClaudeTextOnlyCommandBuilder.arguments(for: request).contains("--effort"))
        #expect(try await store.teammate(id: f.teammateID)?.claudeEffort == "default")
    }

    @Test("Unsupported saved context remains intact and refuses before preparation",
          arguments: ["long", "unknown"])
    func unavailableContextWindowIsPreserved(_ contextWindow: String) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: "claude-haiku-4-5-20251001", contextWindow: contextWindow)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let runner = TextReplyRunner(.success)
        let result = await f.service(store, prepare: prepare, runner: runner).sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(.contextWindowUnavailable))
        #expect(result.savedUserMessage == nil)
        #expect(await prepare.calls == 0)
        #expect(await runner.requests.isEmpty)
        #expect(try await store.teammate(id: f.teammateID)?.claudeContextWindow == contextWindow)
    }

    @Test("Startup observation becomes confirmation only after acknowledged successful final persistence",
          arguments: [TextReplyRunner.Mode.success, .noAcknowledgment, .failure(.providerFailed)])
    private func modelFeedbackRequiresSavedSuccess(_ mode: TextReplyRunner.Mode) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(mode, confirmedModel: "claude-haiku-4-5-20251001")
        let progress = TextReplyProgressLog()
        let result = await f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
            .sendText(f.submission()) { await progress.append($0) }
        let events = await progress.events
        #expect(events.contains(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5")))
        let confirmation = ClaudeTextTurnProgress.modelConfirmed(requested: "sonnet", observed: "claude-haiku-4-5-20251001")
        #expect(events.contains(confirmation) == (mode == .success))
        if mode == .success {
            #expect(result.outcome == .completed)
            let reply = try #require(result.savedReplyMessage)
            let savedIndex = try #require(events.lastIndex(of: .assistantMessageSaved(reply)))
            let confirmedIndex = try #require(events.firstIndex(of: confirmation))
            #expect(confirmedIndex > savedIndex)
            #expect(try await store.runs(conversationID: f.conversationID, limit: 10).first?.state == .succeeded)
        }
        let request = try #require(await runner.requests.first)
        let evidence = try #require(try await store.textTurnExecutionEvidence(id: RunID(request.runID)))
        #expect(evidence.request == request.executionRequest)
        #expect(evidence.initializedModel == "claude-sonnet-5")
        #expect(evidence.resultModel == (mode == .success ? "claude-haiku-4-5-20251001" : nil))
        #expect(evidence.modelStatus == (mode == .success ? .resultDiffers : .startupObserved))
        let reopened = try f.open()
        #expect(try await reopened.textTurnExecutionEvidence(id: RunID(request.runID)) == evidence)
        #expect(try await store.teammate(id: f.teammateID)?.claudeModel == nil)
    }

    @Test("Successful matching model evidence survives reopen while effort and context stay requested selectors")
    func matchingExecutionEvidenceIsDurableWithoutInventedSettings() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store, model: "claude-sonnet-5", effort: "low", contextWindow: "standard")
        let runner = TextReplyRunner(.success, confirmedModel: "claude-sonnet-5")
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let progress = TextReplyProgressLog()
        let result = await f.service(store, prepare: prepare, runner: runner)
            .sendText(f.submission()) { event in
                await progress.append(event)
                if event == .stage(.saving) {
                    do {
                        let request = try #require(await runner.requests.first)
                        let before = try #require(try await store.textTurnExecutionEvidence(id: RunID(request.runID)))
                        #expect(before.modelStatus == .startupObserved && before.resultModel == nil)
                        #expect(try await store.run(id: RunID(request.runID))?.state != .succeeded)
                    } catch { Issue.record("Could not inspect pre-completion evidence: \(error)") }
                }
            }
        #expect(result.outcome == .completed)
        let request = try #require(await runner.requests.first)
        #expect(await prepare.selections == [request.executionSelection])
        let runID = RunID(request.runID)
        let evidence = try #require(try await store.textTurnExecutionEvidence(id: runID))
        #expect(evidence.request == request.executionRequest)
        #expect(evidence.modelStatus == .resultMatches)
        #expect(evidence.initializedModel == "claude-sonnet-5" && evidence.resultModel == "claude-sonnet-5")
        #expect(evidence.request.selection == ClaudeExecutionSelection(model: "claude-sonnet-5", effort: "low", contextWindow: "standard"))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(json.keys) == ["request", "initializedModel", "resultModel"])
        let reopened = try f.open()
        #expect(try await reopened.textTurnExecutionEvidence(id: runID) == evidence)
        let run = try #require(try await reopened.run(id: runID))
        #expect(run.state == .succeeded)
        #expect(run.request.textTurnIdentity?.executionRequest == request.executionRequest)
        let reply = try #require(result.savedReplyMessage)
        #expect(try await reopened.message(id: reply.id) == reply)
        let events = await progress.events
        let savedIndex = try #require(events.lastIndex(of: .assistantMessageSaved(reply)))
        let resultIndex = try #require(events.firstIndex(of: .modelConfirmed(requested: "claude-sonnet-5", observed: "claude-sonnet-5")))
        #expect(resultIndex > savedIndex)
    }

    @Test("Missing result-model evidence and failed final save cannot confirm initialization")
    func missingModelEvidenceOrFinalSaveFailure() async throws {
        for failSave in [false, true] {
            let f = try TextReplyServiceFixture()
            defer { f.remove() }
            let store = try f.open()
            try await f.seed(store)
            let runner = TextReplyRunner(.success, confirmedModel: failSave ? "claude-sonnet-5" : nil)
            let progress = TextReplyProgressLog()
            let result = await f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
                .sendText(f.submission()) { event in
                    await progress.append(event)
                    if failSave, event == .stage(.saving) {
                        do {
                            _ = try await store.execute(sql: """
                                CREATE TRIGGER refuse_model_test_completion BEFORE UPDATE OF state ON work_runs
                                WHEN NEW.state='succeeded' BEGIN SELECT RAISE(ABORT,'synthetic final save failure'); END;
                                """)
                        } catch { Issue.record("Could not install controlled save failure: \(error)") }
                    }
                }
            #expect(result.outcome == (failSave ? .failed(.persistenceFailed) : .completed))
            let events = await progress.events
            #expect(events.contains(.modelObserved(requested: "sonnet", observed: "claude-sonnet-5")))
            #expect(!events.contains { if case .modelConfirmed = $0 { return true }; return false })
            let request = try #require(await runner.requests.first)
            let reopened = try f.open()
            let evidence = try #require(try await reopened.textTurnExecutionEvidence(id: RunID(request.runID)))
            #expect(evidence.request == request.executionRequest)
            #expect(evidence.initializedModel == "claude-sonnet-5")
            #expect(evidence.resultModel == nil && evidence.modelStatus == .startupObserved)
            if failSave {
                let run = try #require(try await reopened.run(id: RunID(request.runID)))
                #expect(run.state != .succeeded)
            }
        }
    }

    @Test("Refused admission and attachments save nothing and never launch", arguments: [false, true])
    func preflightRefusal(attachments: Bool) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let prepare = TextReplyPreparer(.refused(.subscriptionNotVerified))
        let runner = TextReplyRunner(.success)
        let service = f.service(store, prepare: prepare, runner: runner)
        let result = await service.sendText(f.submission(attachments: attachments ? [AttachmentID(UUID())] : [])) { _ in }
        #expect(result.outcome == .failed(attachments ? .attachmentsNotSupported : .subscriptionNotVerified))
        #expect(result.savedUserMessage == nil && result.savedReplyMessage == nil)
        #expect(await prepare.calls == (attachments ? 0 : 1))
        #expect(await runner.requests.isEmpty)
        #expect(try await store.page(conversationID: f.conversationID, request: PageRequest(limit: 10)).elements.isEmpty)
        #expect(try await store.runs(conversationID: f.conversationID, limit: 10).isEmpty)
    }

    @Test("A real final reply is persisted after a prior local message without relabelling it as sent")
    func successAfterLocalMessage() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let local = try f.localMessage()
        try await store.append(local, expectedPreviousSequence: 0)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let runner = TextReplyRunner(.success)
        let progress = TextReplyProgressLog()
        let service = f.service(store, prepare: prepare, runner: runner)
        let submission = f.submission()
        let result = await service.sendText(submission) { await progress.append($0) }
        #expect(result.outcome == .completed)
        let user = try #require(result.savedUserMessage), reply = try #require(result.savedReplyMessage)
        #expect(user.id == submission.userMessageID && user.sequence == 2 && user.deliveryState == .completed)
        #expect(reply.sequence == 3 && reply.author == .teammate(f.teammateID) && reply.deliveryState == .completed)
        #expect(reply.parts.first?.content == .text(TextReplyRunner.finalText))
        let requests = await runner.requests
        #expect(requests.count == 1 && requests[0].text == submission.text && requests[0].messageID == user.id.rawValue)
        let run = try #require(try await store.runs(conversationID: f.conversationID, limit: 10).first)
        #expect(run.state == .succeeded && run.origin == .executor && run.request.initialInput.sequence == 1)
        #expect(try await service.messageProvenance(conversationID: f.conversationID, messageIDs: [local.id]).isEmpty)
        let provenance = try await service.messageProvenance(conversationID: f.conversationID, messageIDs: [user.id])
        #expect(provenance.count == 1 && provenance.first?.inputState == .acknowledged)
        #expect(try await store.message(id: local.id) == local)
        let events = await progress.events
        #expect(events.filter { if case .userMessageSaved = $0 { return true }; return false }.count == 1)
        #expect(events.contains(.assistantMessageSaved(reply)))
    }

    @Test("A committed user ID cannot launch or append a duplicate turn")
    func duplicateSubmission() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(.success)
        let service = f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
        let submission = f.submission()
        let first = await service.sendText(submission) { _ in }
        #expect(first.outcome == .completed)
        let duplicate = await service.sendText(submission) { _ in }
        #expect(duplicate.outcome == .failed(.persistenceFailed))
        #expect(await runner.requests.count == 1)
        let saved = try await store.page(conversationID: f.conversationID, request: PageRequest(limit: 10))
        #expect(saved.elements.count == 2 && saved.elements.filter { $0.id == submission.userMessageID }.count == 1)
        #expect(try await store.runs(conversationID: f.conversationID, limit: 10).count == 1)
    }

    @Test("No completion is fabricated for missing or out-of-order input evidence", arguments: [TextReplyRunner.Mode.noAcknowledgment, .earlyAcknowledgment])
    private func invalidInputEvidence(mode: TextReplyRunner.Mode) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(mode)
        let service = f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome != .completed)
        #expect(result.savedReplyMessage?.deliveryState != .completed)
        let run = try #require(try await store.runs(conversationID: f.conversationID, limit: 10).first)
        #expect(run.state == .failed)
        #expect(await runner.requests.count == 1)
    }

    @Test("Malformed stream and provider failure preserve partial text as failed", arguments: [ClaudeTextOnlyFailure.invalidStream, .providerFailed])
    func providerFailure(problem: ClaudeTextOnlyFailure) async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(.failure(problem))
        let service = f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
        let result = await service.sendText(f.submission()) { _ in }
        #expect(result.outcome == .failed(problem == .invalidStream ? .invalidResponse : .runtimeUnavailable))
        #expect(result.savedUserMessage?.deliveryState == .failed)
        #expect(result.savedReplyMessage?.deliveryState == .failed)
        #expect(result.savedReplyMessage?.parts.first?.content == .text(TextReplyRunner.partialText))
        let code: TextTurnDiagnosticCode = problem == .providerFailed ? .providerFailure : .invalidJSON
        #expect(result.savedReplyMessage?.parts.count == 2)
        #expect(result.savedReplyMessage?.parts.last?.content == .status("OpenBots diagnostic: \(code.rawValue)"))
        #expect(try await store.runs(conversationID: f.conversationID, limit: 10).first?.state == .failed)
    }

    @Test("Cancellation saves the received partial reply as interrupted after the fake child stops", .timeLimit(.minutes(1)))
    func cancellationPersistsPartial() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(.hold)
        let service = f.service(store, prepare: TextReplyPreparer(.ready(try f.target())), runner: runner)
        let submission = f.submission()
        let task = Task { await service.sendText(submission) { _ in } }
        await runner.waitForHeldProcess()
        let active = try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10)
        #expect(active.first?.replyText == TextReplyRunner.partialText)
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .stopped)
        #expect(await runner.cancellationObserved)
        #expect(result.savedReplyMessage?.parts.first?.content == .text(TextReplyRunner.partialText))
        #expect(result.savedReplyMessage?.deliveryState == .outcomeUnknown)
        #expect(result.savedUserMessage?.deliveryState == .outcomeUnknown)
        #expect(try await store.runs(conversationID: f.conversationID, limit: 10).first?.state == .interrupted)
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("An immediate partial is saved and displayed before a stalled turn ends even when the clock does not advance", .timeLimit(.minutes(1)))
    func immediatePartialIsDurableBeforeTermination() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = TextReplyRunner(.hold)
        let progress = TextReplyProgressLog()
        let service = f.service(store, prepare: TextReplyPreparer(.ready(try f.target())),
                                runner: runner, clock: TextReplyFixedClock())
        let task = Task { await service.sendText(f.submission()) { await progress.append($0) } }
        // The fixture emits init/submitted/ACK and one partial, then suspends
        // without a later token or terminal result to trigger another save.
        await runner.waitForHeldProcess()
        do {
            let active = try #require(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).first)
            #expect(active.run.state == .running)
            #expect(active.inputState == .acknowledged)
            #expect(active.replyText == TextReplyRunner.partialText)
            let replyID = try #require(active.run.request.textTurnIdentity?.replyMessageID)
            let saved = try #require(try await store.message(id: replyID))
            #expect(saved.deliveryState == .pending)
            #expect(saved.parts.first?.content == .text(TextReplyRunner.partialText))
            let events = await progress.events
            #expect(events.contains(.assistantMessageSaved(saved)))
            #expect(await runner.cancellationObserved == false)
        } catch {
            task.cancel()
            _ = await task.value
            throw error
        }
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .stopped)
        #expect(await runner.cancellationObserved)
        #expect(result.savedReplyMessage?.parts.first?.content == .text(TextReplyRunner.partialText))
        #expect(try await store.pendingTextTurns(appOwnerID: f.appOwner, limit: 10).isEmpty)
    }

    @Test("One bot refuses a concurrent send before another preflight or launch", .timeLimit(.minutes(1)))
    func sameBotConcurrency() async throws {
        let f = try TextReplyServiceFixture()
        defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let prepare = TextReplyPreparer(.ready(try f.target()))
        let runner = TextReplyRunner(.hold)
        let service = f.service(store, prepare: prepare, runner: runner)
        let first = Task { await service.sendText(f.submission()) { _ in } }
        await runner.waitForHeldProcess()
        let secondSubmission = f.submission()
        let second = await service.sendText(secondSubmission) { _ in }
        #expect(second.outcome == .failed(.busy) && second.savedUserMessage == nil)
        #expect(await prepare.calls == 1)
        #expect(await runner.requests.count == 1)
        #expect(try await store.message(id: secondSubmission.userMessageID) == nil)
        first.cancel()
        #expect(await first.value.outcome == .stopped)
    }
}

private actor TextReplyPreparer: ClaudeTextLaunchPreparing {
    let result: ClaudeTextLaunchPreparation
    private(set) var calls = 0
    private(set) var models: [String] = []
    private(set) var selections: [ClaudeExecutionSelection] = []
    init(_ result: ClaudeTextLaunchPreparation) { self.result = result }
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { calls += 1; return result }
    func prepareTextLaunch(runID: UUID, model: String) async -> ClaudeTextLaunchPreparation {
        models.append(model)
        return await prepareTextLaunch(runID: runID)
    }
    /// Inert adapter for service tests, not native subscription/billing admission.
    /// Record the full frozen selection without invoking any external program.
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation {
        selections.append(selection)
        return await prepareTextLaunch(runID: runID, model: selection.model)
    }
}

private actor TextReplyModelChangeGate {
    private var available = true
    func take() -> Bool { defer { available = false }; return available }
}

private actor TextReplyProgressLog {
    private(set) var events: [ClaudeTextTurnProgress] = []
    func append(_ value: ClaudeTextTurnProgress) { events.append(value) }
}

private actor TextReplyRunner: ClaudeTextOnlyRunning {
    enum Mode: Equatable, Sendable {
        case success, noAcknowledgment, earlyAcknowledgment, hold
        case failure(ClaudeTextOnlyFailure)
    }
    static let partialText = "Actual provider"
    static let finalText = "Actual provider reply."
    let mode: Mode
    let confirmedModel: String?
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var cancellationObserved = false
    private var held = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<ClaudeTextOnlyResult, Never>?

    init(_ mode: Mode, confirmedModel: String? = nil) { self.mode = mode; self.confirmedModel = confirmedModel }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        if case .earlyAcknowledgment = mode {
            await onEvent(.inputAcknowledged(messageID: request.messageID))
        } else {
            await onEvent(.inputSubmitted(messageID: request.messageID))
            if case .noAcknowledgment = mode {} else {
                await onEvent(.inputAcknowledged(messageID: request.messageID))
            }
            await onEvent(.textSnapshot(Self.partialText))
        }
        switch mode {
        case .failure(let failure):
            await onEvent(.diagnostic(failure == .providerFailed ? .providerFailure : .invalidJSON))
            return .failed(failure)
        case .hold:
            held = true
            entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            return await withTaskCancellationHandler {
                if Task.isCancelled || cancellationObserved {
                    cancellationObserved = true
                    return .cancelled
                }
                return await withCheckedContinuation { completion = $0 }
            } onCancel: {
                Task { await self.cancelHeldProcess() }
            }
        default:
            return .success(ClaudeTextOnlyReply(sessionID: request.sessionID,
                actualModel: confirmedModel ?? request.expectedResolvedModel, text: Self.finalText,
                confirmedActualModel: confirmedModel))
        }
    }

    func waitForHeldProcess() async {
        if held { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    private func cancelHeldProcess() {
        cancellationObserved = true
        completion?.resume(returning: .cancelled)
        completion = nil
    }
}

private final class TextReplyStepClock: OpenBotsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 4_100
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        instant += 0.25
        return Date(timeIntervalSince1970: instant)
    }
}

private struct TextReplyFixedClock: OpenBotsClock {
    func now() -> Date { Date(timeIntervalSince1970: 4_100) }
}

private struct TextReplyServiceFixture: Sendable {
    let directory: URL
    let protection: ProtectionDecisionReceipt
    let teammateID = TeammateID(UUID()), conversationID = ConversationID(UUID())
    let appOwner = UUID()
    let date = Date(timeIntervalSince1970: 4_000)

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/OpenBotsNextTextReplyService-\(UUID()).noindex", isDirectory: true)
        protection = try ProtectionDecisionReceipt(decisionID: UUID(), selectedAt: Date(), rationaleVersion: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> SQLiteStore {
        try SQLiteStore(configuration: SQLiteStoreConfiguration(fileURL: directory.appendingPathComponent("control.sqlite"),
            protection: .ordinarySQLite(decision: protection)))
    }
    func seed(_ store: SQLiteStore, model: String? = nil, effort: String? = nil, contextWindow: String? = nil,
              teammateID selectedTeammate: TeammateID? = nil, conversationID selectedConversation: ConversationID? = nil) async throws {
        let botID = selectedTeammate ?? teammateID, chatID = selectedConversation ?? conversationID
        let teammate = try Teammate(id: botID, profile: TeammateProfile(displayName: "Text Partner", role: "Research"),
            appearance: AgentAppearance(mode: .creature, grammarVersion: 1, deterministicSeed: 6, silhouette: "round",
                paletteToken: "sky", eyeDialect: "bright", nonColorIdentityCue: "single crest", accessibleIdentityDescription: "Round creature with a crest"),
            claudeModel: model, claudeEffort: effort, claudeContextWindow: contextWindow, createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: teammate,
            conversation: Conversation(id: chatID, kind: .direct(teammateID: botID), createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: false)
    }
    func localMessage() throws -> Message {
        try Message(id: MessageID(UUID()), conversationID: conversationID, sequence: 1, author: .user,
            deliveryState: .completed, parts: [MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text("Saved locally before runtime existed."))],
            createdAt: date, updatedAt: date)
    }
    func submission(attachments: [AttachmentID] = []) -> ClaudeTextTurnSubmission {
        ClaudeTextTurnSubmission(conversationID: conversationID, teammateID: teammateID,
            userMessageID: MessageID(UUID()), text: "An explicit new question.", attachmentIDs: attachments)
    }
    func target() throws -> ClaudeConnectionTarget {
        try ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/HighChurn.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
    }
    func service(_ store: SQLiteStore, prepare: any ClaudeTextLaunchPreparing,
                 runner: any ClaudeTextOnlyRunning,
                 clock: any OpenBotsClock = TextReplyStepClock()) -> OfficialClaudeTextReplyService {
        OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
            messages: store, preparer: prepare, runner: runner, appOwnerID: appOwner, clock: clock)
    }
}
