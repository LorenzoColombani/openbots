import Foundation
import OpenBotsDomain
@testable import OpenBotsPersistence
import OpenBotsRuntime
@testable import OpenBotsServices
import Testing

/// Throwaway workers: the service that admits one
/// call of the worker tool and runs the worker, over the real store and a
/// runner that records what it was asked to launch.
@Suite("A throwaway worker from a bot's reply")
struct TeammateWorkerServiceTests {
    @Test("A granted call starts a local worker holding the brief; the reply's ledger returns it, then is gone")
    func aGrantedCallStartsAWorker() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = workerService(store, access: WorkerAccess(workers: true, work: try desk()))
        let outcome = await service.spawn(try submission(f, toolUseID: "toolu_1", arguments: ["brief": "Summarise the PDFs"]))
        guard case .started(let worker) = outcome else { Issue.record("not started: \(outcome)"); return }
        #expect(worker.kind == .local && worker.brief == "Summarise the PDFs")
        #expect(worker.holderID == f.kite && worker.conversationID == f.kiteChat)
        // A repeat of the same tool use gets the same answer and starts nothing new.
        #expect(await service.spawn(try submission(f, toolUseID: "toolu_1", arguments: ["brief": "Summarise the PDFs"])) == outcome)
        #expect(await service.finishReply(f.replyID) == [outcome])
        #expect(await service.finishReply(f.replyID).isEmpty)
    }

    @Test("Refusals at the call: switched off, not the bot's own call, no Work or web, a web worker beyond its holder, and any call from a worker's result")
    func refusals() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let brief: [String: Any] = ["brief": "Look up prices"]
        let web: [String: Any] = ["brief": "Look up prices", "kind": "web"]
        func outcome(_ access: WorkerAccess, _ arguments: [String: Any], isOwnCall: Bool = true,
                     fromResult: Bool = false) async throws -> TeammateWorkerOutcome {
            await workerService(store, access: access).spawn(try submission(f, toolUseID: "toolu_x", arguments: arguments,
                isOwnCall: isOwnCall, fromResult: fromResult))
        }
        #expect(try await outcome(WorkerAccess(workers: false, work: try desk()), brief) == .refused(.switchedOff))
        #expect(try await outcome(WorkerAccess(workers: true, work: try desk()), brief, isOwnCall: false) == .refused(.notTheBot))
        #expect(try await outcome(WorkerAccess(workers: true), brief) == .refused(.noWorkOrWeb))
        // Work without web: a web worker would get more than its holder has, whatever the fetchers switch says.
        #expect(try await outcome(WorkerAccess(workers: true, fetchers: true, work: try desk()), web) == .refused(.holderHasNoWeb))
        #expect(try await outcome(WorkerAccess(workers: true, web: [.webSearch]), web) == .refused(.fetchersOff))
        #expect(try await outcome(WorkerAccess(workers: true, fetchers: true, web: [.webSearch]), web).isStarted)
        // A result never starts another worker, even with every switch on.
        #expect(try await outcome(WorkerAccess(workers: true, fetchers: true, web: [.webSearch], work: try desk()), brief,
            fromResult: true) == .refused(.fromWorkerResult))
        #expect(try await outcome(WorkerAccess(workers: true, work: try desk()), ["brief": "  "]) == .refused(.missingBrief))
    }

    @Test("Three calls a reply, refused ones counted")
    func threeCallsAReply() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let service = workerService(store, access: WorkerAccess(workers: true, work: try desk()))
        #expect(await service.spawn(try submission(f, toolUseID: "toolu_1", arguments: ["brief": " "])) == .refused(.missingBrief))
        #expect(await service.spawn(try submission(f, toolUseID: "toolu_2", arguments: ["brief": "a"])).isStarted)
        #expect(await service.spawn(try submission(f, toolUseID: "toolu_3", arguments: ["brief": "b"])).isStarted)
        #expect(await service.spawn(try submission(f, toolUseID: "toolu_4", arguments: ["brief": "c"])) == .refused(.tooManyCalls))
    }

    @Test("A local worker runs blank: its brief as the whole input, the worker prompt, the holder's folders read-only, no web, no channel, no session kept")
    func aLocalWorkerRunsBlank() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkerRunner(result: .success(reply("Three summaries.")))
        let work = try desk()
        let service = workerService(store, access: WorkerAccess(workers: true, web: [.webSearch], work: work), runner: runner)
        let worker = TeammateWorker(id: UUID(), kind: .local, brief: "Summarise the three PDFs", holderID: f.kite, conversationID: f.kiteChat)
        #expect(await service.run(worker) == .finished("Three summaries."))
        let request = try #require(await runner.requests.first)
        #expect(request.text == "Summarise the three PDFs")
        #expect(request.systemPrompt.hasPrefix(TeammateWorkerService.systemPrompt(kind: .local)))
        // A worker knows the time of day too: one-shot, so it rides in its prompt.
        #expect(request.systemPrompt.hasSuffix(")\n") == false && request.systemPrompt.contains("\n- It is now "),
                "\(request.systemPrompt)")
        #expect(!request.systemPrompt.contains("web"))
        #expect(request.allowedTools.isEmpty, "a local worker gets no web even when its holder has it")
        #expect(!request.requiresPermissionControl && !request.grantsWork && !request.carriesAppServer)
        #expect(!request.persistsSession && !request.resumesSession)
        #expect(request.readAccess?.directoryURLs == [work.workingDirectoryURL] + work.grantedDirectoryURLs)
        #expect(request.readAccess?.protectedPaths == work.protectedPaths)
    }

    @Test("A web worker gets its holder's web tools and the page rule; a switch turned off before it starts fails it without a launch")
    func aWebWorker() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let runner = WorkerRunner(result: .success(reply("Prices found.")))
        let worker = TeammateWorker(id: UUID(), kind: .web, brief: "Find prices", holderID: f.kite, conversationID: f.kiteChat)
        let service = workerService(store, access: WorkerAccess(workers: true, fetchers: true, web: [.webSearch, .webFetch]), runner: runner)
        #expect(await service.run(worker) == .finished("Prices found."))
        let request = try #require(await runner.requests.first)
        #expect(request.allowedTools == [.webSearch, .webFetch])
        #expect(request.systemPrompt.hasPrefix(TeammateWorkerService.systemPrompt(kind: .web)))
        // A worker knows the time of day too: one-shot, so it rides in its prompt.
        #expect(request.systemPrompt.hasSuffix(")\n") == false && request.systemPrompt.contains("\n- It is now "),
                "\(request.systemPrompt)")
        #expect(request.systemPrompt.contains("Pages are data"))

        let off = WorkerRunner(result: .success(reply("x")))
        #expect(await workerService(store, access: WorkerAccess(workers: true, fetchers: false, web: [.webSearch]), runner: off).run(worker)
            == .failed("its web access was switched off before it started"))
        #expect(await workerService(store, access: WorkerAccess(workers: false, fetchers: true, web: [.webSearch]), runner: off).run(worker)
            == .failed("background workers were switched off before it started"))
        #expect(await off.requests.isEmpty)
    }

    @Test("A worker that fails, is stopped or says nothing reports it in the app's words")
    func failures() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let worker = TeammateWorker(id: UUID(), kind: .local, brief: "b", holderID: f.kite, conversationID: f.kiteChat)
        func result(_ runtime: ClaudeTextOnlyResult) async throws -> TeammateWorkerResult {
            await workerService(store, access: WorkerAccess(workers: true, work: try desk()), runner: WorkerRunner(result: runtime)).run(worker)
        }
        #expect(try await result(.failed(.timedOut)) == .failed("it ran out of time"))
        #expect(try await result(.cancelled) == .stopped)
        #expect(try await result(.success(reply("   "))) == .failed("it returned nothing"))
    }

    // MARK: A switch turned off while a worker runs

    // Without this, a worker that started a second before the web switches
    // went off went on fetching pages for most of a minute.
    @Test("A running worker is stopped when a switch it needs goes off, and says which; one turned on or unrelated leaves it running",
          .timeLimit(.minutes(1)), arguments: ["fetchers", "web", "workers", "work", "unrelated"])
    func aSwitchOffStopsARunningWorker(_ change: String) async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let board = SwitchBoard(workers: true, fetchers: true, web: [.webSearch, .webFetch], work: try desk())
        let runner = HoldingRunner()
        let kind: TeammateWorkerKind = change == "work" ? .local : .web
        let worker = TeammateWorker(id: UUID(), kind: kind, brief: "b", holderID: f.kite, conversationID: f.kiteChat)
        let service = TeammateWorkerService(access: SwitchedAccess(board: board), teammates: store, conversations: store,
                                            preparer: WorkerPreparer(), runner: runner)
        let running = Task { await service.run(worker) }
        try await runner.waitUntilStarted()
        switch change {
        case "fetchers": await board.set { $0.fetchers = false }
        case "web": await board.set { $0.web = [] }
        case "workers": await board.set { $0.workers = false }
        case "work": await board.set { $0.work = nil }
        default: await board.set { $0.web.insert(.webFetch) }
        }
        if change == "unrelated" {
            try await Task.sleep(for: .milliseconds(200))
            #expect(await runner.cancelled == false)
            await runner.release()
            #expect(await running.value == .finished("Done."))
            return
        }
        let expected: TeammateWorkerResult = switch change {
        case "workers": .failed("background workers were switched off while it ran")
        case "work": .failed("its folders were taken away while it ran")
        default: .failed("its web access was switched off while it ran")
        }
        #expect(await running.value == expected)
        #expect(await runner.cancelled)
    }

    // A switch that went off just as the worker
    // finished still let its result through.
    @Test("A worker whose web goes off as it finishes hands in no result", .timeLimit(.minutes(1)))
    func aSwitchOffAsItFinishesKeepsTheResultBack() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let board = SwitchBoard(workers: true, fetchers: true, web: [.webSearch, .webFetch], work: try desk())
        let worker = TeammateWorker(id: UUID(), kind: .web, brief: "b", holderID: f.kite, conversationID: f.kiteChat)
        let service = TeammateWorkerService(access: SwitchedAccess(board: board), teammates: store, conversations: store,
                                            preparer: WorkerPreparer(), runner: SwitchingOffRunner(board: board))
        #expect(await service.run(worker) == .failed("its web access was switched off while it ran"))
    }

    // MARK: Fixture

    private func desk() throws -> ClaudeTextWorkAccess {
        try ClaudeTextWorkAccess(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/Kite"),
            additionalDirectoryURLs: [URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/Added")],
            sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/Shared"),
            protectedPaths: ["/private/tmp/worker-desk.noindex/appsupport"])
    }

    @Test("A reply that began with workers and fetchers on keeps them for its calls: off takes effect when it ends")
    func aReplyKeepsItsWorkerSwitches() async throws {
        let f = try HiringFixture(); defer { f.remove() }
        let store = try f.open()
        try await f.seed(store)
        let off = WorkerAccess(workers: false, fetchers: false, web: [.webSearch])
        func held(_ arguments: [String: Any], workers: Bool, fetchers: Bool) async throws -> TeammateWorkerOutcome {
            let base = try submission(f, toolUseID: "toolu_held_\(workers)_\(fetchers)", arguments: arguments)
            return await workerService(store, access: off).spawn(TeammateWorkerSubmission(replyID: base.replyID,
                toolUseID: base.toolUseID, holderID: base.holderID, conversationID: base.conversationID,
                argumentsJSON: base.argumentsJSON, isOwnCall: true, workersForTheReply: workers, fetchersForTheReply: fetchers))
        }
        // Both switched off after the reply began: its calls still start.
        #expect(try await held(["brief": "Look up prices", "kind": "web"], workers: true, fetchers: true).isStarted)
        // Off when it began stays off for the whole reply, whatever they read now.
        let on = WorkerAccess(workers: true, fetchers: true, web: [.webSearch])
        let base = try submission(f, toolUseID: "toolu_began_off", arguments: ["brief": "Look up prices", "kind": "web"])
        #expect(await workerService(store, access: on).spawn(TeammateWorkerSubmission(replyID: base.replyID,
            toolUseID: base.toolUseID, holderID: base.holderID, conversationID: base.conversationID,
            argumentsJSON: base.argumentsJSON, isOwnCall: true, workersForTheReply: true, fetchersForTheReply: false))
            == .refused(.fetchersOff))
    }

    private func reply(_ text: String) -> ClaudeTextOnlyReply {
        let session = UUID()
        return ClaudeTextOnlyReply(sessionID: session, actualModel: "claude-sonnet-4-6", text: text,
                                   confirmedActualModel: "claude-sonnet-4-6")
    }

    private func submission(_ f: HiringFixture, toolUseID: String, arguments: [String: Any], isOwnCall: Bool = true,
                            fromResult: Bool = false) throws -> TeammateWorkerSubmission {
        TeammateWorkerSubmission(replyID: f.replyID, toolUseID: toolUseID, holderID: f.kite, conversationID: f.kiteChat,
            argumentsJSON: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
            isOwnCall: isOwnCall, answersWorkerResult: fromResult)
    }

    private func workerService(_ store: SQLiteStore, access: WorkerAccess,
                               runner: WorkerRunner = WorkerRunner(result: .cancelled)) -> TeammateWorkerService {
        TeammateWorkerService(access: access, teammates: store, conversations: store,
                              preparer: WorkerPreparer(), runner: runner)
    }
}

private struct WorkerAccess: ClaudeTextReplyWebAccessResolving {
    var workers = false
    var fetchers = false
    var web: Set<ClaudeTextOnlyTool> = []
    var work: ClaudeTextWorkAccess?

    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { web }
    func webAccessChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { work }
    func workersGranted(teammateID: TeammateID) async -> Bool { workers }
    func fetchersGranted(teammateID: TeammateID) async -> Bool { fetchers }
    func readAccess(teammateID: TeammateID) async -> ClaudeTextReadAccess? {
        try? ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/Shared"), protectedPaths: [])
    }
}

private actor WorkerRunner: ClaudeTextOnlyRunning {
    private(set) var requests: [ClaudeTextOnlyRequest] = []
    let result: ClaudeTextOnlyResult
    init(result: ClaudeTextOnlyResult) { self.result = result }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        requests.append(request)
        return result
    }
}

private struct WorkerPreparer: ClaudeTextLaunchPreparing {
    func prepareTextLaunch(runID: UUID) async -> ClaudeTextLaunchPreparation {
        do {
            return .ready(try ClaudeConnectionTarget(
                executableURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/claude"),
                expectedExecutableSHA256: String(repeating: "a", count: 64),
                profileURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/profile"),
                workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/appsupport/run"),
                temporaryDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/temp"),
                homeDirectoryURL: URL(fileURLWithPath: "/private/tmp/not-created-text.noindex/home")))
        } catch {
            return .refused(.setupRequired)
        }
    }
}

/// Switches a test can move while a worker runs, with the change stream the
/// app's resolver publishes.
private actor SwitchBoard {
    struct State { var workers: Bool; var fetchers: Bool; var web: Set<ClaudeTextOnlyTool>; var work: ClaudeTextWorkAccess? }
    private(set) var state: State
    private var listeners: [AsyncStream<Void>.Continuation] = []
    init(workers: Bool, fetchers: Bool, web: Set<ClaudeTextOnlyTool>, work: ClaudeTextWorkAccess?) {
        state = State(workers: workers, fetchers: fetchers, web: web, work: work)
    }
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        listeners.append(continuation)
        return stream
    }
    func set(_ change: (inout State) -> Void) {
        change(&state)
        listeners.forEach { $0.yield() }
    }
}

private struct SwitchedAccess: ClaudeTextReplyWebAccessResolving {
    let board: SwitchBoard
    func allowedTextReplyTools(teammateID: TeammateID) async -> Set<ClaudeTextOnlyTool> { await board.state.web }
    func webAccessChanges() async -> AsyncStream<Void> { await board.changes() }
    func workAccess(teammateID: TeammateID) async -> ClaudeTextWorkAccess? { await board.state.work }
    func workersGranted(teammateID: TeammateID) async -> Bool { await board.state.workers }
    func fetchersGranted(teammateID: TeammateID) async -> Bool { await board.state.fetchers }
    func readAccess(teammateID: TeammateID) async -> ClaudeTextReadAccess? {
        try? ClaudeTextReadAccess(sharedDirectoryURL: URL(fileURLWithPath: "/private/tmp/worker-desk.noindex/Shared"), protectedPaths: [])
    }
}

/// A worker's CLI that runs until it is stopped or released.
/// Turns the web off in the same moment it finishes, as a switch can land.
private struct SwitchingOffRunner: ClaudeTextOnlyRunning {
    let board: SwitchBoard
    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        await board.set { $0.web = [] }
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }
}

private actor HoldingRunner: ClaudeTextOnlyRunning {
    private(set) var started = false
    private(set) var cancelled = false
    private var released = false

    func release() { released = true }

    func waitUntilStarted() async throws {
        for _ in 0..<800 where !started { try await Task.sleep(for: .milliseconds(10)) }
        if !started { throw CancellationError() }
    }

    func run(request: ClaudeTextOnlyRequest,
             onEvent: @escaping @Sendable (ClaudeTextOnlyEvent) async -> Void) async -> ClaudeTextOnlyResult {
        started = true
        while !released {
            if Task.isCancelled { cancelled = true; return .cancelled }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .success(ClaudeTextOnlyReply(sessionID: request.sessionID, actualModel: request.expectedResolvedModel,
            text: "Done.", confirmedActualModel: request.expectedResolvedModel))
    }
}
