import Foundation
import OpenBotsDomain
import OpenBotsPersistence
import OpenBotsRuntime
import OpenBotsServices
@testable import OpenBotsUI
import Testing

/// Throwaway workers, on screen: a reply's worker
/// keeps its bot's face working after the reply, shows in Details and never
/// as a sidebar seat, holds Archive and Delete off while it runs, and its end
/// wakes the bot, whose answer lands in the chat. A quit leaves one line.
/// Over the real store and reply service, a CLI stand-in, and a worker runner
/// the test releases by hand.
@MainActor
@Suite("A background worker on screen")
struct WorkerWorkspaceTests {
    @Test("The worker runs after the reply with the bot's face working and a line in Details, no seat, Archive and Delete held; its end wakes the bot, whose answer lands")
    func theWorkerLoopOnScreen() async throws {
        let setup = try await WorkerWorkspaceSetup()
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        let rowsBefore = model.sidebar.rows.map(\.id)

        model.conversation.composerText = "Summarise the three PDFs in your folder while you draft the mail."
        model.conversation.sendCurrentText()
        try await eventually { model.conversation.messages.contains { $0.body == WorkerWorkspaceRunner.firstReply } }
        let note = "Kite started a background worker: local (\"\(WorkerWorkspaceRunner.brief)\")."
        try await eventually { model.conversation.messages.contains { $0.body == note } }
        let presented = try #require(model.conversation.messages.first { $0.body == note })
        #expect(presented.author == .system(label: "OpenBots"))
        #expect(presented.deliveryNotice == DurableWorkspaceModel.hireNoteNotice)

        // The worker is running: the reply has ended, the face still works.
        try await eventually { setup.workers.running == 1 }
        try await eventually { model.sidebar.rows.first { $0.id == setup.kite.rawValue }?.activity == .thinkingOrWorking }
        #expect(model.sidebar.workingAvatarByConversation[setup.kiteChat.rawValue]?.teammateID == setup.kite.rawValue)
        #expect(model.conversation.backgroundWorkerLines == ["Background worker running: \"\(WorkerWorkspaceRunner.brief)\""])
        #expect(model.sidebar.rows.map(\.id) == rowsBefore, "a worker is never a seat")

        // Archive and Delete wait for it.
        await model.archiveBot(id: setup.kite.rawValue)
        #expect(model.archiveModel?.errorMessage == ArchivePreparationError.workerRunning.message)
        #expect(try await setup.store.teammate(id: setup.kite)?.lifecycle == .active)
        model.archiveModel?.errorMessage = nil
        await model.prepareDeleteBot(id: setup.kite.rawValue)
        #expect(model.deleteErrorMessage == DurableWorkspaceModel.workerRunningDeleteMessage)
        #expect(model.deleteRequest == nil)

        // It ends: the bot is woken with the result and answers the person.
        setup.workers.release()
        try await eventually { model.conversation.messages.contains { $0.body == WorkerWorkspaceRunner.wakeReply } }
        #expect(setup.runner.wakeTexts.first?.contains(WorkerWorkspaceRunner.workerResult) == true)
        try await eventually { model.sidebar.rows.first { $0.id == setup.kite.rawValue }?.activity == .idle }
        #expect(model.conversation.backgroundWorkerLines.isEmpty)
        #expect(model.sidebar.workingAvatarByConversation[setup.kiteChat.rawValue] == nil)
        // The note the app wrote for the wake is the work channel, never a transcript row.
        #expect(!model.conversation.messages.contains { $0.body.contains("[From OpenBots]") })
        #expect(model.sidebar.rows.map(\.id) == rowsBefore)
    }

    @Test("A quit while a worker runs stops it and leaves one line in the bot's chat, read back as the app's note after a relaunch")
    func aQuitLeavesALine() async throws {
        let setup = try await WorkerWorkspaceSetup()
        defer { setup.remove() }
        let model = setup.workspace()
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        _ = await model.flushForShutdown()
        model.finishShutdown()
        #expect(setup.workers.cancelled == 1)

        let reopened = setup.workspace()
        defer { reopened.finishShutdown() }
        try await reopened.loadInitialWorkspace()
        let line = "Kite's background worker (\"\(WorkerWorkspaceRunner.brief)\") was stopped when OpenBots quit. It never finished."
        let saved = try #require(reopened.conversation.messages.first { $0.body == line })
        #expect(saved.author == .system(label: "OpenBots"))
        #expect(saved.deliveryNotice == DurableWorkspaceModel.hireNoteNotice)
        #expect(setup.runner.wakeTexts.isEmpty, "a stopped worker wakes nobody")
    }
}

extension WorkerWorkspaceTests {
    /// A message typed while the result is being delivered must not stop the
    /// wake and drop the result for good.
    @Test("A message typed while the bot is answering its worker's result takes the chat, and the result is answered after it, not lost")
    func aMessageTypedDuringTheWakeDoesNotLoseTheResult() async throws {
        let setup = try await WorkerWorkspaceSetup(holdsFirstWake: true)
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        setup.workers.release()
        try await eventually { setup.runner.wakesBegun == 1 }
        model.conversation.composerText = "Thanks, and one more thing."
        model.conversation.sendCurrentText()
        try await eventually { model.conversation.messages.contains { $0.body == WorkerWorkspaceRunner.wakeReply } }
        #expect(setup.runner.wakesBegun == 2, "the stopped wake is delivered again once the chat is free")
        // The answer is drawn as it saves; the line goes when the wake has ended.
        try await eventually { model.conversation.backgroundWorkerLines.isEmpty }
    }

    /// Stop ends the chain, and that holds for a wake: only a Stop the user
    /// pressed drops the result.
    @Test("Stop pressed while the bot answers its worker's result ends it, and the result is not sent again")
    func aStopDuringTheWakeEndsIt() async throws {
        let setup = try await WorkerWorkspaceSetup(holdsFirstWake: true)
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        setup.workers.release()
        try await eventually { setup.runner.wakesBegun == 1 }
        try await eventually { model.conversation.textReplyPhase?.isBusy == true }
        model.conversation.stopCurrentTextReply()
        try await eventually { model.conversation.textReplyPhase?.isBusy == false }
        try await Task.sleep(for: .milliseconds(200))
        #expect(setup.runner.wakesBegun == 1)
        #expect(model.conversation.backgroundWorkerLines.isEmpty)
    }

    // A running worker must be stoppable without a quit, and its stopped end
    // must not wake the bot into speaking unasked.
    @Test("Stop beside a running worker in Details stops it, leaves one line, and wakes nobody")
    func stopInDetailsStopsTheWorker() async throws {
        let setup = try await WorkerWorkspaceSetup()
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        try await eventually { model.conversation.textReplyPhase?.isBusy != true }
        #expect(model.conversation.canStopBackgroundWorkers)
        model.conversation.stopBackgroundWorkers()
        let line = "Kite's background worker (\"\(WorkerWorkspaceRunner.brief)\") was stopped by you. It never finished."
        try await eventually { model.conversation.messages.contains { $0.body == line } }
        #expect(setup.workers.cancelled == 1)
        try await eventually { model.conversation.backgroundWorkerLines.isEmpty }
        #expect(!model.conversation.canStopBackgroundWorkers)
        try await Task.sleep(for: .milliseconds(200))
        #expect(setup.runner.wakeTexts.isEmpty, "a worker the user stopped wakes nobody")
        try await eventually { model.sidebar.rows.first { $0.id == setup.kite.rawValue }?.activity == .idle }
    }

    @Test("Stop on a reply in the chat stops that chat's running worker too, and its end wakes nobody")
    func stopOnAReplyStopsTheWorker() async throws {
        let setup = try await WorkerWorkspaceSetup(holdsSecondUserTurn: true)
        defer { setup.remove() }
        let model = setup.workspace()
        defer { model.finishShutdown() }
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        try await eventually { model.conversation.textReplyPhase?.isBusy != true }
        model.conversation.composerText = "And while it runs, one more thing."
        model.conversation.sendCurrentText()
        try await eventually { model.conversation.textReplyPhase?.isBusy == true }
        model.conversation.stopCurrentTextReply()
        try await eventually { setup.workers.cancelled == 1 }
        try await eventually { model.conversation.textReplyPhase?.isBusy == false }
        try await Task.sleep(for: .milliseconds(200))
        #expect(setup.runner.wakeTexts.isEmpty, "the user's Stop is not undone by the worker's end")
        #expect(model.conversation.backgroundWorkerLines.isEmpty)
    }

    /// A quit during the wake must not write "quit before it could answer"
    /// beside the wake's own saved outcome.
    @Test("A quit while the bot is answering its worker's result leaves the wake's own record, and no quit line for that worker")
    func aQuitDuringTheWakeWritesNoQuitLine() async throws {
        let setup = try await WorkerWorkspaceSetup(holdsFirstWake: true)
        defer { setup.remove() }
        let model = setup.workspace()
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        setup.workers.release()
        try await eventually { setup.runner.wakesBegun == 1 }
        _ = await model.flushForShutdown()
        model.finishShutdown()

        let reopened = setup.workspace()
        defer { reopened.finishShutdown() }
        try await reopened.loadInitialWorkspace()
        #expect(!reopened.conversation.messages.contains { $0.body.contains("OpenBots quit before") })
    }
}

extension WorkerWorkspaceTests {
    /// A quit that catches a wake before it saved anything must still leave a
    /// line, or the result is lost without a word.
    @Test("A quit that stops a wake before it saved anything leaves the line that the bot never answered the result")
    func aQuitBeforeTheWakeSavedLeavesTheLine() async throws {
        let setup = try await WorkerWorkspaceSetup(holdsWakeBeforeSave: true)
        defer { setup.remove() }
        let model = setup.workspace()
        try await model.loadInitialWorkspace()
        model.conversation.composerText = "Summarise the three PDFs."
        model.conversation.sendCurrentText()
        try await eventually { setup.workers.running == 1 }
        setup.workers.release()
        let gate = try #require(setup.wakeGate)
        try await eventually { gate.begun }
        _ = await model.flushForShutdown()
        model.finishShutdown()

        let reopened = setup.workspace()
        defer { reopened.finishShutdown() }
        try await reopened.loadInitialWorkspace()
        let line = "Kite's background worker (\"\(WorkerWorkspaceRunner.brief)\") finished, but OpenBots quit before Kite could answer with its result."
        #expect(reopened.conversation.messages.contains { $0.body == line })
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition never held")
}

/// Kite, selected, with web search and both workers switches; a reply service
/// over the real store whose CLI stand-in asks for one worker on the person's
/// turn and answers the wake with the summary.
@MainActor
private struct WorkerWorkspaceSetup {
    let fixture: ReferenceLocalWorkspaceFixture
    let store: SQLiteStore
    let switches: AgenticJobAccessStore
    let runner: WorkerWorkspaceRunner
    let workers = GatedWorkers()
    let kite = TeammateID(UUID())
    let kiteChat = ConversationID(UUID())

    /// Set: the wake waits, before anything is saved, until it is cancelled.
    let wakeGate: WakeBeforeSaveGate?

    init(holdsFirstWake: Bool = false, holdsWakeBeforeSave: Bool = false, holdsSecondUserTurn: Bool = false) async throws {
        wakeGate = holdsWakeBeforeSave ? WakeBeforeSaveGate() : nil
        runner = WorkerWorkspaceRunner(holdsFirstWake: holdsFirstWake, holdsSecondUserTurn: holdsSecondUserTurn)
        fixture = try ReferenceLocalWorkspaceFixture()
        store = try fixture.open()
        let date = Date(timeIntervalSince1970: 9_000)
        let bot = try Teammate(id: kite, profile: TeammateProfile(displayName: "Kite", role: "Teammate"),
            appearance: try CreatureAllocation(id: kite.rawValue).appearance(), createdAt: date, updatedAt: date)
        try await store.provisionDirectChat(teammate: bot,
            conversation: Conversation(id: kiteChat, kind: .direct(teammateID: kite), title: "Kite", createdAt: date, updatedAt: date),
            fixtureGreeting: nil, selectConversation: true)
        switches = AgenticJobAccessStore(reportWriteFailure: { _ in })
        for capability in [AgenticCapability.workers, .web(.search)] {
            await switches.setAppEnabled(true, capability: capability)
            await switches.setBotEnabled(true, capability: capability, teammateID: kite)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: fixture.directory) }

    func workspace() -> DurableWorkspaceModel {
        let chats = fixture.chatService(store: store)
        let target = try! ClaudeConnectionTarget(executableURL: URL(fileURLWithPath: "/fixture/claude"),
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            profileURL: URL(fileURLWithPath: "/fixture/WorkerWorkspace.noindex/CLIProfile"),
            workingDirectoryURL: URL(fileURLWithPath: "/fixture/WorkerWorkspace.noindex/Work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/fixture/WorkerWorkspace.noindex/Temp"),
            homeDirectoryURL: URL(fileURLWithPath: "/fixture"))
        let preparer = WorkerWorkspacePreparer(target: target)
        let reply = OfficialClaudeTextReplyService(repository: store, teammates: store, conversations: store, messages: store,
            preparer: preparer, runner: runner, appOwnerID: UUID(), webAccess: switches, activity: store,
            workers: TeammateWorkerService(access: switches, teammates: store, conversations: store, preparer: preparer, runner: runner))
        let service: any ClaudeTextReplyServing = wakeGate.map { WakeHeldBeforeSave(inner: reply, gate: $0) } ?? reply
        return DurableWorkspaceModel(mode: .localOnly, service: chats, textReplyService: service, agenticJobAccess: switches,
            hiringService: ReferenceUnusedHiringService(), archiveService: TeammateArchiveService(repository: store),
            deletionService: TeammateDeletionService(repository: store), workerService: workers)
    }
}

/// Whether a wake has reached the service and is waiting there.
final class WakeBeforeSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _begun = false
    var begun: Bool { lock.withLock { _begun } }
    func begin() { lock.withLock { _begun = true } }
}

/// The real reply service, except that a wake waits before anything is saved
/// until its task is cancelled, and then saves nothing: the moment a quit can
/// catch a wake that has not yet written its note.
private struct WakeHeldBeforeSave: ClaudeTextReplyServing {
    let inner: OfficialClaudeTextReplyService
    let gate: WakeBeforeSaveGate
    func sendText(_ submission: ClaudeTextTurnSubmission,
                  onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        await inner.sendText(submission, onProgress: onProgress)
    }
    func messageProvenance(conversationID: ConversationID, messageIDs: [MessageID]) async throws -> [TextTurnMessageProvenance] {
        try await inner.messageProvenance(conversationID: conversationID, messageIDs: messageIDs)
    }
    func sendWorkerResult(_ submission: WorkerResultSubmission,
                          onProgress: @escaping @Sendable (ClaudeTextTurnProgress) async -> Void) async -> ClaudeTextTurnResult {
        gate.begin()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return .init(outcome: .stopped)
    }
    func saveWorkerLine(_ line: String, conversationID: ConversationID) async -> Bool {
        await inner.saveWorkerLine(line, conversationID: conversationID)
    }
}

private struct WorkerWorkspacePreparer: ClaudeTextLaunchPreparing {
    let target: ClaudeConnectionTarget
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation { .ready(target) }
}

/// Runs each worker only once the test releases it, and counts the stopped ones.
@MainActor
private final class GatedWorkers: TeammateWorking {
    private(set) var running = 0
    private(set) var cancelled = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    nonisolated func spawn(_ submission: TeammateWorkerSubmission) async -> TeammateWorkerOutcome { .refused(.notStarted) }
    nonisolated func finishReply(_ replyID: UUID) async -> [TeammateWorkerOutcome] { [] }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    nonisolated func run(_ worker: TeammateWorker) async -> TeammateWorkerResult {
        await wait()
        return await MainActor.run { () -> TeammateWorkerResult in
            running -= 1
            if Task.isCancelled || !released { cancelled += 1; return .stopped }
            return .finished(WorkerWorkspaceRunner.workerResult)
        }
    }

    private func wait() async {
        running += 1
        guard !released else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate = $0 }
        } onCancel: {
            Task { @MainActor in self.gate?.resume(); self.gate = nil }
        }
    }
}

/// The CLI side: the person's turn asks for one worker and says so in a
/// line; the wake answers with the summary. The host's answer to the worker
/// call is not waited for, because this suite reads the screen, not the wire.
private final class WorkerWorkspaceRunner: ClaudeTextOnlyRunning, @unchecked Sendable {
    static let brief = "Summarise the three PDFs in the Kite folder"
    static let firstReply = "On it: a worker is summarising the PDFs while I draft the mail."
    static let workerResult = "harbour-report.pdf: 412 ships. orchard-notes.pdf: 9 apples. bicycle-log.pdf: 1,240 km."
    static let wakeReply = "The three PDFs: the harbour handled 412 ships, the orchard grew 9 apples, the club rode 1,240 km."
    private let lock = NSLock()
    private let holdsFirstWake: Bool
    private let holdsSecondUserTurn: Bool
    private var _wakeTexts: [String] = []
    private var _userTurns = 0
    init(holdsFirstWake: Bool = false, holdsSecondUserTurn: Bool = false) {
        self.holdsFirstWake = holdsFirstWake; self.holdsSecondUserTurn = holdsSecondUserTurn
    }
    var wakeTexts: [String] { lock.withLock { _wakeTexts } }
    var wakesBegun: Int { lock.withLock { _wakeTexts.count } }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await run(request: request, control: nil, onEvent: onEvent)
    }

    func run(request: ClaudeTextOnlyRequest, control: ClaudeTextTurnControl?,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await onEvent(.initialized(sessionID: request.sessionID, actualModel: request.expectedResolvedModel))
        await onEvent(.inputSubmitted(messageID: request.messageID))
        await onEvent(.inputAcknowledged(messageID: request.messageID))
        let text: String
        if request.text.contains("[From OpenBots]") {
            let first = lock.withLock { () -> Bool in _wakeTexts.append(request.text); return _wakeTexts.count == 1 }
            if first, holdsFirstWake {
                // A long answer, still going when the person types or quits.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .cancelled
            }
            text = Self.wakeReply
        } else {
            let turn = lock.withLock { () -> Int in _userTurns += 1; return _userTurns }
            if turn == 2, holdsSecondUserTurn {
                // A reply still going when the user presses Stop.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .cancelled
            }
            let firstUserTurn = turn == 1
            if firstUserTurn, request.grantsWorkers, control != nil {
                let input = (try? JSONSerialization.data(withJSONObject: ["brief": Self.brief], options: [.sortedKeys])) ?? Data()
                await onEvent(.toolUse(ClaudeTextToolUse(id: "toolu_w", toolName: ClaudeTextWorkerPolicy.qualifiedToolName, inputJSON: input)))
                await onEvent(.workerRequested(ClaudeTextWorkerCall(requestID: "call-1", toolUseID: "toolu_w",
                                                                    argumentsJSON: input, isOwnCall: true)))
                await onEvent(.toolFinished(toolUseID: "toolu_w", failed: false))
            }
            text = Self.firstReply
        }
        await onEvent(.textSnapshot(text))
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: text, confirmedActualModel: request.expectedResolvedModel))
    }
}
