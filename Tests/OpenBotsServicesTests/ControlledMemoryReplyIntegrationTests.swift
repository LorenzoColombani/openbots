import Foundation
import OpenBotsContent
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

@Suite("Controlled memory replies with real SQLite and protected artifacts")
struct ControlledMemoryReplyIntegrationTests {
    @Test("A private qualified reference becomes one atomic original-turn reply and survives reopening")
    func qualifiedReplyAndContinuity() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let authority = try await f.authority()
        let retained = try await f.publish(store, root: authority, body: "I prefer quiet libraries.")
        let other = try await f.publish(store, root: authority, body: "OTHER-BOT-PRIVATE-CANARY", second: true)
        let global = try await f.globalCanary(store, root: authority)
        let reference = try controlledReference(retained)
        let candidate = try controlledCandidate(reference)

        // An actual app-local overview is not provider history. The controlled
        // provider reply below has a different, explicit transport provenance.
        let fallback = ControlledUnexpectedFallback(), time = f.now
        let local = MemoryLocalConversationService(fallback: fallback, memory: store, intents: store,
            contexts: store, selections: store, messages: store, teammates: store, publications: store,
            authority: authority, clock: { time })
        let localResult = await local.sendText(f.submission("What do you remember about me?")) { _ in }
        #expect(localResult.outcome == .completed)
        let localReply = try #require(localResult.savedReplyMessage)
        #expect(await fallback.calls == 0)

        let progress = ControlledProgress()
        let runner = ControlledCandidateRunner(store: store, progress: progress, candidate: candidate)
        let submission = f.submission("Could quiet libraries be relevant here?")
        let service = try controlledService(f, store: store, authority: authority, runner: runner)
        let result = await service.sendText(submission) { event in
            await progress.append(event)
            if event == .stage(.saving) {
                await controlledAssertPending(store: store, runner: runner)
            }
        }
        #expect(result.outcome == .completed)
        #expect(await runner.requests.count == 1)
        #expect(await runner.privateSnapshotChecks == 2)
        let request = try #require(await runner.requests.first)
        #expect(request.text != submission.text)
        #expect(request.text.contains("I prefer quiet libraries."))
        #expect(!request.text.contains("OTHER-BOT-PRIVATE-CANARY"))
        #expect(!request.text.contains("GLOBAL-SECRET-SENTINEL"))
        #expect(request.systemPrompt.contains("controlled memory publication format"))

        let user = try #require(result.savedUserMessage)
        let reply = try #require(result.savedReplyMessage)
        let replyText = try controlledText(reply)
        #expect(user.id == submission.userMessageID && user.deliveryState == .completed)
        #expect(try controlledText(user) == submission.text)
        #expect(reply.author == .system && reply.deliveryState == .completed)
        #expect(reply.sequence == user.sequence + 1)
        #expect(replyText.contains("I may have this wrong:"))
        #expect(replyText.contains("I prefer quiet libraries."))
        #expect(replyText.contains("Does that apply here?"))
        #expect(replyText != candidate && !replyText.contains("\"references\""))

        let runID = RunID(request.runID)
        let run = try #require(try await store.run(id: runID))
        let identity = try #require(run.request.textTurnIdentity)
        #expect(run.state == .succeeded)
        #expect(run.request.initialInput.text == submission.text)
        #expect(run.request.initiatingMessageID == user.id && identity.replyMessageID == reply.id)
        #expect(identity.controlledMemoryPolicyVersion == 1)
        #expect(identity.executionRequest == request.executionRequest)
        let inputReceipt = try #require(run.request.readContextReceipt)
        #expect(inputReceipt.claimReferences == [reference])
        #expect(inputReceipt.memoryDocuments.map(\.documentID) == [retained.record.intent.document.id])
        let receiptJSON = String(decoding: try JSONEncoder().encode(inputReceipt), as: UTF8.self)
        #expect(!receiptJSON.contains(retained.artifact.claims[0].body))
        #expect(!receiptJSON.contains(retained.record.intent.document.relativePath))
        #expect(!receiptJSON.contains(f.root.path))

        let saved = try #require(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat))
        #expect(saved.providerRunID == runID && saved.publication.receipt.runID == runID)
        #expect(saved.publication.receipt.messageID == reply.id)
        #expect(saved.userMessage == user && saved.replyMessage == reply)
        #expect(saved.publication.text == replyText)
        #expect(saved.publication.receipt.dependencies.map(\.reference) == [reference])
        #expect(saved.userSourceStamps.map(\.messageID) == [retained.source.id])
        let evidence = try #require(try await store.textTurnExecutionEvidence(id: runID))
        #expect(evidence.request == request.executionRequest && evidence.modelStatus == .resultMatches)
        #expect(evidence.initializedModel == request.expectedResolvedModel)
        #expect(evidence.resultModel == request.expectedResolvedModel)
        let provenance = try await store.textTurnProvenance(conversationID: f.chat, messageIDs: [user.id, reply.id])
        #expect(provenance.count == 1 && provenance.first?.inputState == .acknowledged)
        #expect(provenance.first?.state == .succeeded && provenance.first?.runID == runID)
        let events = await progress.events
        let savedEvents = events.compactMap { event -> Message? in
            if case .assistantMessageSaved(let message) = event { return message }; return nil
        }
        #expect(savedEvents == [reply])
        let savedIndex = try #require(events.firstIndex(of: .assistantMessageSaved(reply)))
        let confirmedIndex = try #require(events.firstIndex(of: .modelConfirmed(requested: request.model,
            observed: request.expectedResolvedModel)))
        #expect(savedIndex < confirmedIndex)

        let reopened = try f.open()
        #expect(try await reopened.run(id: runID) == run)
        #expect(try await reopened.memoryConversationPublication(id: saved.publication.receipt.id) == saved)
        #expect(try await reopened.textTurnExecutionEvidence(id: runID) == evidence)
        #expect(try await reopened.message(id: user.id) == user)
        #expect(try await reopened.message(id: reply.id) == reply)
        #expect(try await reopened.document(id: retained.record.intent.document.id) == retained.record.intent.document)
        let selection = try await reopened.loadContext(conversationID: f.chat)
        let history = try await reopened.loadReadContextCandidates(ReadContextRequest(conversationID: f.chat,
            teammateID: f.bot, profileRevision: 1, selection: selection, beforeSequence: reply.sequence + 1))
        let recentIDs = Set(history.recentMessages.map(\.id))
        #expect(recentIDs.contains(user.id) && recentIDs.contains(reply.id))
        #expect(!recentIDs.contains(localReply.id))
        #expect(history.recentMessages.first { $0.id == reply.id }?.reference.memoryQualificationRequired == true)
        #expect(!history.memoryDocuments.contains { $0.id == other.record.intent.document.id || $0.id == global.id })
        let otherSelection = try await reopened.loadContext(conversationID: f.secondChat)
        let otherHistory = try await reopened.loadReadContextCandidates(ReadContextRequest(conversationID: f.secondChat,
            teammateID: f.secondBot, profileRevision: 1, selection: otherSelection, beforeSequence: other.source.sequence + 1))
        #expect(!otherHistory.recentMessages.contains { $0.id == user.id || $0.id == reply.id })
        #expect(!otherHistory.memoryDocuments.contains { $0.id == retained.record.intent.document.id || $0.id == global.id })
    }

    @Test("Malformed, prose-bearing and foreign-reference candidates never become saved text or a retry",
          arguments: ControlledCandidateMutation.allCases)
    fileprivate func invalidCandidate(_ mutation: ControlledCandidateMutation) async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let authority = try await f.authority()
        let retained = try await f.publish(store, root: authority, body: "I prefer quiet libraries.")
        let other = try await f.publish(store, root: authority, body: "OTHER-BOT-PRIVATE-CANARY", second: true)
        let candidate: String
        switch mutation {
        case .malformed: candidate = "{PRIVATE-RAW-CANDIDATE-NOT-JSON"
        case .extraProse: candidate = try controlledCandidate(controlledReference(retained)) + "\nPRIVATE-RAW-PROSE"
        case .extraField:
            let valid = try controlledCandidate(controlledReference(retained))
            candidate = String(valid.dropLast()) + ",\"text\":\"PRIVATE-RAW-PROSE\"}"
        case .otherBot: candidate = try controlledCandidate(controlledReference(other))
        case .oversized: candidate = String(repeating: "PRIVATE-RAW-CANDIDATE", count: MemoryPublicationLimits.candidateBytes)
        }
        let progress = ControlledProgress()
        let runner = ControlledCandidateRunner(store: store, progress: progress, candidate: candidate)
        let result = await (try controlledService(f, store: store, authority: authority, runner: runner))
            .sendText(f.submission("Could quiet libraries be relevant here?")) { await progress.append($0) }
        #expect(result.outcome == .failed(.invalidResponse))
        try await controlledAssertWithheld(f, store: store, runner: runner, progress: progress, result: result)
        #expect(try await store.document(id: retained.record.intent.document.id) == retained.record.intent.document)
        #expect(try await store.document(id: other.record.intent.document.id) == other.record.intent.document)
        let request = try #require(await runner.requests.first)
        #expect(!request.text.contains("OTHER-BOT-PRIVATE-CANARY"))
        #expect(!request.systemPrompt.contains(other.artifact.claims[0].id.rawValue.uuidString.lowercased()))
    }

    @Test("A successful-looking candidate without exact input acknowledgment remains withheld")
    func missingAcknowledgment() async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let authority = try await f.authority()
        let retained = try await f.publish(store, root: authority, body: "I prefer quiet libraries.")
        let progress = ControlledProgress()
        let runner = ControlledCandidateRunner(store: store, progress: progress,
            candidate: try controlledCandidate(controlledReference(retained)), acknowledgesInput: false)
        let result = await (try controlledService(f, store: store, authority: authority, runner: runner))
            .sendText(f.submission("Could quiet libraries be relevant here?")) { await progress.append($0) }
        #expect(result.outcome == .failed(.invalidResponse))
        try await controlledAssertWithheld(f, store: store, runner: runner, progress: progress, result: result)
        let user = try #require(result.savedUserMessage)
        #expect(user.deliveryState == .failed)
        let provenance = try await store.textTurnProvenance(conversationID: f.chat, messageIDs: [user.id])
        #expect(provenance.first?.inputState == .outcomeUnknown)
    }

    @Test("Source, profile and context changes before publication withhold the candidate",
          arguments: ControlledAuthorityMutation.allCases)
    fileprivate func changedBeforeSave(_ mutation: ControlledAuthorityMutation) async throws {
        let f = try LocalMemoryFixture(); defer { f.remove() }
        let store = try f.open(); try await f.seed(store)
        let authority = try await f.authority()
        let retained = try await f.publish(store, root: authority, body: "I prefer quiet libraries.")
        let progress = ControlledProgress()
        let runner = ControlledCandidateRunner(store: store, progress: progress,
            candidate: try controlledCandidate(controlledReference(retained)))
        let result = await (try controlledService(f, store: store, authority: authority, runner: runner))
            .sendText(f.submission("Could quiet libraries be relevant here?")) { event in
                await progress.append(event)
                guard event == .stage(.saving) else { return }
                await controlledAssertPending(store: store, runner: runner)
                do {
                    switch mutation {
                    case .source:
                        // Exact disposable source mutation, not a fabricated verifier receipt.
                        let changed = try await store.execute(sql: "UPDATE message_parts SET text_value=? WHERE message_id=? AND ordinal=0;",
                            bindings: [.text("Remember as uncertain: Changed synthetic evidence."), .text(retained.source.id.persistedValue)])
                        #expect(changed == 1)
                    case .profile:
                        var bot = try #require(try await store.teammate(id: f.bot))
                        let revision = bot.profile.revision
                        bot.profile = try bot.profile.revised()
                        bot.updatedAt = f.now
                        try await store.update(bot, expectedProfileRevision: revision)
                    case .context: try await f.selectProject(store, project: f.project)
                    }
                } catch { Issue.record("Could not change synthetic authority before publication: \(error)") }
            }
        #expect(result.outcome == .failed(mutation == .source ? .invalidResponse : .contextChanged))
        try await controlledAssertWithheld(f, store: store, runner: runner, progress: progress, result: result)
    }
}

private enum ControlledCandidateMutation: CaseIterable, Sendable {
    case malformed, extraProse, extraField, otherBot, oversized
}
private enum ControlledAuthorityMutation: CaseIterable, Sendable { case source, profile, context }

private func controlledReference(_ retained: LocalMemoryFixture.Retained) throws -> MemoryClaimReference {
    try MemoryClaimCodec().reference(for: retained.artifact.claims[0], in: retained.artifact,
        contentDigest: retained.record.intent.document.contentDigest)
}

private func controlledCandidate(_ reference: MemoryClaimReference) throws -> String {
    struct Wire: Encodable { let version = 1; let units: [MemoryPublicationUnit] }
    return String(decoding: try MemoryClaimDigests.canonicalData(Wire(units: [
        .init(kind: .claim, references: [reference])
    ])), as: UTF8.self)
}

private func controlledService(_ f: LocalMemoryFixture, store: SQLiteStore,
    authority: VerifiedAuthoritativeMarkdownRoot, runner: ControlledCandidateRunner) throws -> OfficialClaudeTextReplyService {
    let target = try ClaudeConnectionTarget(executableURL: f.root.appending(path: "inert-claude"),
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        profileURL: f.root.appending(path: "CLIProfile"), workingDirectoryURL: f.root.appending(path: "Work"),
        temporaryDirectoryURL: f.root.appending(path: "Temp"), homeDirectoryURL: f.root.appending(path: "Home"))
    let time = f.now
    let preparation = ControlledMemoryReplyPreparation(memory: store, intents: store, contexts: store,
        publications: store, messages: store, teammates: store, authority: { authority }, clock: { time })
    return OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store,
        messages: store, preparer: ControlledInertPreparer(target: target), runner: runner,
        appOwnerID: runner.appOwnerID, clock: ControlledFixedClock(instant: time),
        context: store, contextReader: store, contextAssembler: ClaudeContextAssemblyService(memoryAuthority: authority),
        controlledMemory: preparation)
}

private struct ControlledInertPreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
    func prepareTextLaunch(runID: UUID, selection: ClaudeExecutionSelection) async -> ClaudeTextLaunchPreparation { .ready(target) }
}
private struct ControlledFixedClock: OpenBotsClock {
    let instant: Date
    func now() -> Date { instant }
}
private actor ControlledProgress {
    private(set) var events: [ClaudeTextTurnProgress] = []
    func append(_ event: ClaudeTextTurnProgress) { events.append(event) }
}

private actor ControlledCandidateRunner: ClaudeTextOnlyRunning {
    nonisolated let appOwnerID = UUID()
    let store: SQLiteStore, progress: ControlledProgress, candidate: String
    let acknowledgesInput: Bool
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    private(set) var privateSnapshotChecks = 0

    init(store: SQLiteStore, progress: ControlledProgress, candidate: String, acknowledgesInput: Bool = true) {
        self.store = store; self.progress = progress; self.candidate = candidate
        self.acknowledgesInput = acknowledgesInput
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        if acknowledgesInput { await onEvent(.inputAcknowledged(messageID: request.messageID)) }
        for snapshot in [String(candidate.prefix(24)), candidate] {
            await onEvent(.textSnapshot(snapshot))
            // The oversized fixture deliberately trips runtime cancellation.
            // Its terminal assertions below inspect the uncancelled saved state.
            if Task.isCancelled { continue }
            do {
                let pending = try await store.pendingTextTurns(appOwnerID: appOwnerID, limit: 4)
                #expect(pending.count == 1 && pending.first?.replyText.isEmpty == true)
                let requestRecord = try #require(pending.first)
                let replyID = try #require(requestRecord.run.request.textTurnIdentity?.replyMessageID)
                let saved = try #require(try await store.message(id: replyID))
                #expect(saved.parts.allSatisfy { if case .text = $0.content { return false }; return true })
                #expect(try await store.memoryConversationPublication(messageID: replyID,
                    conversationID: requestRecord.run.request.conversationID) == nil)
                let events = await progress.events
                #expect(!events.contains { if case .assistantMessageSaved = $0 { return true }; return false })
                privateSnapshotChecks += 1
            } catch { Issue.record("Could not check private candidate snapshot: \(error)") }
        }
        // Even a synthetic successful result cannot override an oversized
        // snapshot, missing acknowledgment, invalid candidate or stale authority.
        return .success(.init(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: candidate, confirmedActualModel: request.expectedResolvedModel))
    }
}

private func controlledAssertPending(store: SQLiteStore, runner: ControlledCandidateRunner) async {
    do {
        let request = try #require(await runner.requests.first)
        let runID = RunID(request.runID)
        let run = try #require(try await store.run(id: runID))
        let replyID = try #require(run.request.textTurnIdentity?.replyMessageID)
        #expect(run.state == .running)
        #expect(try await store.memoryConversationPublication(messageID: replyID,
            conversationID: run.request.conversationID) == nil)
        let evidence = try #require(try await store.textTurnExecutionEvidence(id: runID))
        #expect(evidence.modelStatus == .startupObserved && evidence.resultModel == nil)
        let pending = try await store.pendingTextTurns(appOwnerID: runner.appOwnerID, limit: 4)
        #expect(pending.first?.replyText.isEmpty == true)
    } catch { Issue.record("Could not inspect pre-publication state: \(error)") }
}

private func controlledAssertWithheld(_ f: LocalMemoryFixture, store: SQLiteStore,
    runner: ControlledCandidateRunner, progress: ControlledProgress, result: ClaudeTextTurnResult) async throws {
    #expect(await runner.requests.count == 1)
    let request = try #require(await runner.requests.first)
    let runID = RunID(request.runID)
    let run = try #require(try await store.run(id: runID))
    #expect(run.state == .failed)
    let user = try #require(result.savedUserMessage)
    let reply = try #require(result.savedReplyMessage)
    #expect(user.id == MessageID(request.messageID))
    #expect(reply.deliveryState == .failed)
    #expect(reply.parts.allSatisfy { if case .status = $0.content { return true }; return false })
    #expect(try await store.memoryConversationPublication(messageID: reply.id, conversationID: f.chat) == nil)
    let evidence = try #require(try await store.textTurnExecutionEvidence(id: runID))
    #expect(evidence.modelStatus == .startupObserved && evidence.resultModel == nil)
    let events = await progress.events
    #expect(!events.contains { if case .modelConfirmed = $0 { return true }; return false })
    for event in events {
        if case .assistantMessageSaved(let message) = event {
            #expect(message.parts.allSatisfy { if case .status = $0.content { return true }; return false })
        }
    }
    let reopened = try f.open()
    #expect(try await reopened.run(id: runID) == run)
    #expect(try await reopened.message(id: reply.id) == reply)
    #expect(try await reopened.textTurnExecutionEvidence(id: runID) == evidence)
    #expect(try await reopened.memoryConversationPublication(messageID: reply.id, conversationID: f.chat) == nil)
    #expect(try await reopened.runs(conversationID: f.chat, limit: 20).count == 1)
}

private func controlledText(_ message: Message) throws -> String {
    let part = try #require(message.parts.first)
    guard case .text(let text) = part.content else {
        Issue.record("Expected complete reconstructed text"); return ""
    }
    return text
}

private actor ControlledUnexpectedFallback: ClaudeTextReplyServing {
    private(set) var calls = 0
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        calls += 1
        return .init(outcome: .failed(.runtimeUnavailable))
    }
    func messageProvenance(conversationID: ConversationID,
                           messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] { [] }
}
