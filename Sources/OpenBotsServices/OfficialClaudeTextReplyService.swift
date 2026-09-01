import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// The narrow text adapter is separate from the general teammate executor.
/// Repositories own transactions; the runtime owns all child-process lifetime.
public actor OfficialClaudeTextReplyService: ClaudeTextReplyServing {
    private let repository: any TextTurnRepository
    private let teammates: any TeammateRepository
    private let conversations: any ConversationRepository
    private let messages: any MessageRepository
    private let context: (any ConversationContextRepository)?
    private let contextReader: (any ReadContextRepository)?
    private let contextAssembler: (any ClaudeContextAssembling)?
    private let controlledMemory: ControlledMemoryReplyPreparation?
    private let controlledRepository: (any ControlledMemoryTextTurnRepository)?
    private let executionRepository: (any ClaudeExecutionEvidenceRepository)?
    private let preparer: any ClaudeTextLaunchPreparing
    private let runner: any ClaudeTextOnlyRunning
    private let appOwnerID: UUID
    private let ownerID: UUID
    private let clock: any OpenBotsClock
    private var activeTeammates: Set<TeammateID> = []
    private var turns: [RunID: Turn] = [:]

    private struct Turn {
        var snapshot: TextTurnSnapshot
        let token: UUID
        let user: Message
        let requestedModel: String
        let sessionID: UUID
        var executionEvidence: ClaudeExecutionEvidence
        var isControlled: Bool { snapshot.run.request.textTurnIdentity?.controlledMemoryPolicyVersion != nil }
        var text = ""
        var diagnosticCode: TextTurnDiagnosticCode?
        var persistenceFailed = false
        var failureOverride: ClaudeTextTurnProblem?
        var process: Task<ClaudeTextOnlyResult, Never>?
    }

    public init(repository: any TextTurnRepository, teammates: any TeammateRepository,
                conversations: any ConversationRepository, messages: any MessageRepository,
                preparer: any ClaudeTextLaunchPreparing,
                runner: any ClaudeTextOnlyRunning = NativeClaudeTextOnlyRunner(),
                appOwnerID: UUID, ownerID: UUID = UUID(), clock: any OpenBotsClock = SystemClock(),
                context: (any ConversationContextRepository)? = nil,
                contextReader: (any ReadContextRepository)? = nil,
                contextAssembler: (any ClaudeContextAssembling)? = nil,
                controlledMemory: ControlledMemoryReplyPreparation? = nil) {
        self.repository = repository; self.teammates = teammates
        self.conversations = conversations; self.messages = messages
        self.preparer = preparer; self.runner = runner
        self.appOwnerID = appOwnerID; self.ownerID = ownerID; self.clock = clock
        self.context = context ?? (conversations as? any ConversationContextRepository)
        self.contextReader = contextReader; self.contextAssembler = contextAssembler
        self.controlledMemory = controlledMemory
        self.controlledRepository = repository as? any ControlledMemoryTextTurnRepository
        self.executionRepository = repository as? any ClaudeExecutionEvidenceRepository
    }

    public func messageProvenance(conversationID: ConversationID,
                                  messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        try await repository.textTurnProvenance(conversationID: conversationID, messageIDs: messageIDs)
    }

    public func sendText(_ submission: ClaudeTextTurnSubmission,
                         onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard !Task.isCancelled else { return .init(outcome: .stopped) }
        guard submission.attachmentIDs.isEmpty else { return failed(.attachmentsNotSupported) }
        guard !submission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submission.text.utf8.count <= 65_536, !submission.text.contains("\0") else {
            return failed(.invalidInput)
        }
        guard activeTeammates.insert(submission.teammateID).inserted else { return failed(.busy) }
        defer { activeTeammates.remove(submission.teammateID) }
        let runID = RunID(UUID())
        defer { turns.removeValue(forKey: runID) }
        do {
            guard let teammate = try await teammates.teammate(id: submission.teammateID),
                  teammate.lifecycle == .active,
                  let conversation = try await conversations.conversation(id: submission.conversationID),
                  conversation.lifecycle == .active,
                  conversation.kind == .direct(teammateID: teammate.id) else { return failed(.unavailable) }
            guard ClaudeTextOnlyRequest.supportedModels.contains(teammate.requestedClaudeModel) else {
                return failed(.modelUnavailable)
            }
            let effort = teammate.requestedClaudeEffort == "default" ? nil : teammate.requestedClaudeEffort
            if let effort, !ClaudeEffortPolicy.supportedValues(for: teammate.requestedClaudeModel).contains(effort) {
                return failed(.effortUnavailable)
            }
            guard ClaudeContextWindowPolicy.supportedValues(for: teammate.requestedClaudeModel)
                .contains(teammate.requestedClaudeContextWindow) else { return failed(.contextWindowUnavailable) }
            try Task.checkCancellation()
            let page = try await messages.page(conversationID: conversation.id, request: PageRequest(limit: 1))
            let selection = try await context?.loadContext(conversationID: conversation.id)
            let previous = page.elements.last?.sequence ?? 0
            guard previous < Int64.max - 1 else { return failed(.persistenceFailed) }
            let assembly: ClaudeContextAssembly?
            if let contextReader, let contextAssembler, let selection {
                await onProgress(.stage(.selectingContext))
                let candidates = try await contextReader.loadReadContextCandidates(
                    ReadContextRequest(conversationID: conversation.id, teammateID: teammate.id,
                        profileRevision: teammate.profile.revision, selection: selection,
                        beforeSequence: previous + 1,
                        searchTerms: ReadContextRequest.literalSearchTerms(from: submission.text)))
                assembly = try await contextAssembler.assemble(ClaudeContextAssemblyInput(
                    teammate: teammate, currentText: submission.text, snapshot: candidates))
            } else {
                // Inert adapters can retain their old profile-only seam. Production
                // supplies both dependencies; partial configuration never falls back.
                guard contextReader == nil, contextAssembler == nil else {
                    return failed(.contextUnavailable)
                }
                assembly = nil
            }
            let isControlled = assembly?.requiresControlledMemoryPublication == true
            var systemPrompt = assembly?.systemPrompt ?? Self.systemPrompt(for: teammate)
            if isControlled {
                guard controlledMemory != nil, controlledRepository != nil,
                      let receipt = assembly?.receipt else { return failed(.memoryPublicationNotReady) }
                do { systemPrompt += try ControlledMemoryReplyPreparation.instructions(for: receipt) }
                catch { return failed(.memoryPublicationNotReady) }
            }
            try Task.checkCancellation()
            await onProgress(.stage(.checkingReadiness))
            let executionSelection = ClaudeExecutionSelection(model: teammate.requestedClaudeModel,
                effort: teammate.requestedClaudeEffort, contextWindow: teammate.requestedClaudeContextWindow)
            let preparation = await preparer.prepareTextLaunch(runID: runID.rawValue, selection: executionSelection)
            try Task.checkCancellation()
            guard case .ready(let target) = preparation else {
                if case .refused(let problem) = preparation { return failed(problem) }
                return failed(.setupRequired)
            }
            try Task.checkCancellation()
            let now = clock.now()
            let runtimeRequest = try ClaudeTextOnlyRequest(target: target, runID: runID.rawValue,
                sessionID: UUID(), messageID: submission.userMessageID.rawValue,
                text: assembly?.inputText ?? submission.text, systemPrompt: systemPrompt,
                model: teammate.requestedClaudeModel, effort: effort, contextWindow: teammate.requestedClaudeContextWindow)
            let identity = TextTurnIdentity(appOwnerID: appOwnerID,
                replyMessageID: MessageID(UUID()), replyPartID: MessagePartID(UUID()),
                executionRequest: runtimeRequest.executionRequest,
                controlledMemoryPolicyVersion: isControlled ? 1 : nil)
            let user = try Message(id: submission.userMessageID, conversationID: conversation.id,
                sequence: previous + 1, author: .user, deliveryState: .pending,
                parts: [try MessagePart(id: MessagePartID(UUID()), ordinal: 0, content: .text(submission.text))],
                createdAt: now, updatedAt: now)
            let request = try WorkRequest(runID: runID, teammateID: teammate.id,
                conversationID: conversation.id, initiatingMessageID: user.id,
                selectedProjectID: selection?.projectID,
                profileRevision: teammate.profile.revision,
                initialInput: WorkInput(messageID: user.id, sequence: 1, text: submission.text),
                submittedAt: now, textTurnIdentity: identity,
                readContextReceipt: assembly?.receipt)
            let token = UUID()
            let snapshot: TextTurnSnapshot
            if isControlled, let controlledRepository {
                snapshot = try await controlledRepository.beginControlledMemoryTextTurn(request: request, userMessage: user,
                    expectedPreviousSequence: previous, ownerID: ownerID, token: token, now: now, leaseDuration: 180)
            } else {
                snapshot = try await repository.beginTextTurn(request: request, userMessage: user,
                    expectedPreviousSequence: previous, ownerID: ownerID, token: token, now: now, leaseDuration: 180)
            }
            turns[runID] = Turn(snapshot: snapshot, token: token, user: user,
                requestedModel: runtimeRequest.model, sessionID: runtimeRequest.sessionID,
                executionEvidence: .init(request: runtimeRequest.executionRequest, initializedModel: nil, resultModel: nil))
            await onProgress(.userMessageSaved(user))
            if Task.isCancelled { return await settle(runID, runtime: .cancelled, onProgress: onProgress) }
            if let assembly { await onProgress(.contextPrepared(assembly.disclosure)) }
            await onProgress(.stage(.starting))
            // Recheck after asynchronous presentation callbacks as well as inside
            // beginTextTurn. A stale selection never reaches the process runner.
            if let receipt = assembly?.receipt {
                try await contextReader?.revalidateReadContext(receipt)
            }
            try Task.checkCancellation()
            let runner = runner
            let process = Task {
                await runner.run(request: runtimeRequest) { event in
                    await self.receive(event, runID: runID, onProgress: onProgress)
                }
            }
            turns[runID]?.process = process
            let result = await withTaskCancellationHandler {
                await process.value
            } onCancel: { process.cancel() }
            // The transport has already killed/reaped its group before returning.
            return await settle(runID, runtime: result, onProgress: onProgress)
        } catch is CancellationError {
            if turns[runID] != nil { return await settle(runID, runtime: .cancelled, onProgress: onProgress) }
            return .init(outcome: .stopped)
        } catch is ClaudeTextOnlyRequestError {
            // Bounded request/profile validation happens before a durable turn
            // exists; it must not be reported as a database write failure.
            return failed(.invalidInput)
        } catch let error as ClaudeContextAssemblyError {
            return failed(error == .requiredContentTooLarge ? .contextTooLarge : .contextUnavailable)
        } catch let error as ReadContextError {
            let problem: ClaudeTextTurnProblem = error == .staleReferences ? .contextChanged : .contextUnavailable
            if turns[runID] != nil {
                turns[runID]?.failureOverride = problem
                return await settle(runID, runtime: .failed(.processFailed), onProgress: onProgress)
            }
            return failed(problem)
        } catch is ConversationContextError {
            return failed(.contextChanged)
        } catch {
            if turns[runID] != nil {
                turns[runID]?.persistenceFailed = true
                return await settle(runID, runtime: .failed(.processFailed), onProgress: onProgress)
            }
            if error as? RunJournalError == .conflictingActiveRun { return failed(.busy) }
            return failed(.persistenceFailed)
        }
    }

    private func receive(_ event: ClaudeTextOnlyEvent, runID: RunID,
                         onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async {
        guard var turn = turns[runID], !turn.persistenceFailed else { return }
        var evidence: TextTurnInputEvidence = .none
        switch event {
        case .diagnostic(let code):
            turn.diagnosticCode = code
            turns[runID] = turn
            return
        case .initialized(let sessionID, let actualModel):
            guard sessionID == turn.sessionID, turn.executionEvidence.initializedModel == nil else {
                rejectPersistence(runID); return
            }
            turn.executionEvidence = .init(request: turn.executionEvidence.request,
                initializedModel: actualModel, resultModel: nil)
            do {
                try turn.executionEvidence.validated()
                if turn.isControlled, let controlledRepository {
                    turn.snapshot = try await controlledRepository.checkpointControlledMemoryTextTurn(id: runID,
                        expectedRevision: turn.snapshot.run.revision, token: turn.token,
                        inputEvidence: .none, executionEvidence: turn.executionEvidence, now: clock.now())
                } else if let executionRepository {
                    turn.snapshot = try await executionRepository.recordTextTurnExecutionEvidence(id: runID,
                        expectedRevision: turn.snapshot.run.revision, token: turn.token,
                        evidence: turn.executionEvidence, now: clock.now())
                }
                turns[runID] = turn
            } catch { rejectPersistence(runID); return }
            await onProgress(.modelObserved(requested: turn.requestedModel, observed: actualModel))
            await onProgress(.stage(.responding))
            return
        case .inputSubmitted(let id):
            guard id == turn.user.id.rawValue else { rejectPersistence(runID); return }
            evidence = .submitted
        case .inputAcknowledged(let id):
            guard id == turn.user.id.rawValue else { rejectPersistence(runID); return }
            evidence = .acknowledged
        case .textSnapshot(let text):
            if turn.isControlled {
                guard text.utf8.count <= MemoryPublicationLimits.candidateBytes else {
                    turns[runID]?.failureOverride = .invalidResponse
                    turns[runID]?.process?.cancel()
                    return
                }
                // The candidate is private ephemeral state. Neither raw text nor
                // a partial qualified unit is sent to SQLite or presentation.
                turn.text = text
                turns[runID] = turn
                return
            }
            turn.text = text
            turns[runID] = turn
            // The transport coalesces snapshots and delivers them serially.
            // Persist every delivered snapshot, including a final partial before
            // silence; its independent process thread still enforces deadlines.
        }
        do {
            let now = clock.now()
            if turn.isControlled, let controlledRepository {
                turn.snapshot = try await controlledRepository.checkpointControlledMemoryTextTurn(id: runID,
                    expectedRevision: turn.snapshot.run.revision, token: turn.token,
                    inputEvidence: evidence, executionEvidence: nil, now: now)
            } else {
                turn.snapshot = try await repository.checkpointTextTurn(id: runID,
                    expectedRevision: turn.snapshot.run.revision, token: turn.token,
                    text: turn.text, inputEvidence: evidence, now: now)
            }
            turns[runID] = turn
            if !turn.isControlled, !turn.text.isEmpty,
               let id = turn.snapshot.run.request.textTurnIdentity?.replyMessageID,
               let reply = try await messages.message(id: id) {
                await onProgress(.assistantMessageSaved(reply))
            }
        } catch {
            // A cancelled transaction did not commit. Preserve its real in-memory
            // partial for the uncancelled terminal transaction after process exit.
            if !(error is CancellationError) && !Task.isCancelled { rejectPersistence(runID) }
        }
    }

    private func rejectPersistence(_ runID: RunID) {
        turns[runID]?.persistenceFailed = true
        turns[runID]?.process?.cancel()
    }

    private func settle(_ runID: RunID, runtime: ClaudeTextOnlyResult,
                        onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        guard let turn = turns[runID], let identity = turn.snapshot.run.request.textTurnIdentity else {
            return failed(.persistenceFailed)
        }
        let outcome: ClaudeTextTurnOutcome
        let durableOutcome: TextTurnOutcome
        let text: String
        if let failure = turn.failureOverride {
            outcome = .failed(failure); durableOutcome = .failed; text = turn.text
        } else if turn.persistenceFailed {
            outcome = .failed(.persistenceFailed); durableOutcome = .failed; text = turn.text
        } else {
            switch runtime {
            case .success(let reply):
                guard reply.sessionID == turn.sessionID, turn.snapshot.inputState == .acknowledged else {
                    return await settle(runID, runtime: .failed(.inputRejected), onProgress: onProgress)
                }
                outcome = .completed; durableOutcome = .succeeded; text = reply.text
            case .cancelled:
                outcome = .stopped; durableOutcome = .interrupted; text = turn.text
            case .failed(let problem):
                outcome = .failed(Self.problem(problem)); durableOutcome = .failed; text = turn.text
            }
        }
        await onProgress(.stage(.saving))
        let repository = repository, messages = messages, clock = clock
        let controlledRepository = controlledRepository, controlledMemory = controlledMemory
        let executionRepository = executionRepository
        // SQLite correctly refuses cancelled tasks. Cleanup is an awaited,
        // uncancelled transaction after process termination, not detached work
        // allowed to relaunch a provider or hold the app open indefinitely.
        let result = await Task.detached { () -> ClaudeTextTurnResult in
            do {
                let finalEvidence: ClaudeExecutionEvidence
                if durableOutcome == .succeeded, case .success(let reply) = runtime {
                    finalEvidence = .init(request: turn.executionEvidence.request,
                        initializedModel: turn.executionEvidence.initializedModel,
                        resultModel: reply.confirmedActualModel)
                } else { finalEvidence = turn.executionEvidence }
                var savedOutcome = outcome
                if turn.isControlled {
                    guard let controlledRepository, let controlledMemory else { throw ReadContextError.unavailable }
                    if durableOutcome == .succeeded {
                        let prepared: (MemoryConversationPublication, MemoryConversationPublicationValidation)
                        do { prepared = try await controlledMemory.prepare(candidateText: text, request: turn.snapshot.run.request) }
                        catch {
                            savedOutcome = .failed(error is ReadContextError ? .contextChanged : .invalidResponse)
                            _ = try await controlledRepository.failControlledMemoryTextTurn(id: runID,
                                expectedRevision: turn.snapshot.run.revision, token: turn.token,
                                outcome: .failed, diagnosticCode: nil, now: clock.now())
                            guard let user = try await messages.message(id: turn.user.id),
                                  let reply = try await messages.message(id: identity.replyMessageID) else {
                                throw ReadContextError.unavailable
                            }
                            return .init(outcome: savedOutcome, savedUserMessage: user, savedReplyMessage: reply)
                        }
                        _ = try await controlledRepository.finishControlledMemoryTextTurn(id: runID,
                            expectedRevision: turn.snapshot.run.revision, token: turn.token,
                            publication: prepared.0, validation: prepared.1,
                            executionEvidence: finalEvidence, now: clock.now())
                    } else {
                        _ = try await controlledRepository.failControlledMemoryTextTurn(id: runID,
                            expectedRevision: turn.snapshot.run.revision, token: turn.token,
                            outcome: durableOutcome,
                            diagnosticCode: durableOutcome == .failed ? turn.diagnosticCode : nil, now: clock.now())
                    }
                } else if let executionRepository {
                    _ = try await executionRepository.finishTextTurnWithExecutionEvidence(id: runID,
                        expectedRevision: turn.snapshot.run.revision, token: turn.token,
                        text: text, outcome: durableOutcome,
                        diagnosticCode: durableOutcome == .failed ? turn.diagnosticCode : nil,
                        evidence: finalEvidence, now: clock.now())
                } else {
                    _ = try await repository.finishTextTurn(id: runID,
                        expectedRevision: turn.snapshot.run.revision, token: turn.token,
                        text: text, outcome: durableOutcome,
                        diagnosticCode: durableOutcome == .failed ? turn.diagnosticCode : nil, now: clock.now())
                }
                guard let user = try await messages.message(id: turn.user.id),
                      let reply = try await messages.message(id: identity.replyMessageID) else {
                    return .init(outcome: .failed(.persistenceFailed), savedUserMessage: turn.user)
                }
                return .init(outcome: savedOutcome, savedUserMessage: user, savedReplyMessage: reply)
            } catch { return .init(outcome: .failed(.persistenceFailed), savedUserMessage: turn.user) }
        }.value
        if let reply = result.savedReplyMessage { await onProgress(.assistantMessageSaved(reply)) }
        if result.outcome == .completed, case .success(let reply) = runtime,
           let confirmed = reply.confirmedActualModel {
            await onProgress(.modelConfirmed(requested: turn.requestedModel, observed: confirmed))
        }
        return result
    }

    private static func systemPrompt(for teammate: Teammate) -> String {
        """
        You are \(teammate.profile.displayName), a named teammate in OpenBots.
        Role: \(teammate.profile.role)
        This session can only answer the current text message. No tools, file access,
        browser, connectors or prior conversation history are available. Do not claim
        to have performed actions outside this conversation. Do not invent earlier context.
        User-defined teammate instructions:
        \(teammate.profile.detailedInstructions ?? "None.")
        """
    }

    private static func problem(_ failure: ClaudeTextOnlyFailure) -> ClaudeTextTurnProblem {
        switch failure {
        case .timedOut: .timedOut
        case .launchRejected, .launchFailed: .runtimeUnavailable
        case .unsafeInitialization, .invalidStream, .inputRejected, .outputLimitExceeded: .invalidResponse
        case .providerFailed, .processFailed: .runtimeUnavailable
        }
    }

    private func failed(_ problem: ClaudeTextTurnProblem) -> ClaudeTextTurnResult { .init(outcome: .failed(problem)) }
}
